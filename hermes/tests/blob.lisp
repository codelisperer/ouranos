;;;; tests/blob.lisp --- fiveam suite for the blob store.
;;;;
;;;; What is actually worth pinning here, in the order the module is layered:
;;;;
;;;;   1. THE KEY VOCABULARY (Coalton). A key is the one value in this module that routinely
;;;;      comes from user input, and on the filesystem backend a bad one is a traversal
;;;;      rather than a 404. Every fault is asserted by CONSTRUCTOR, not by message text --
;;;;      the whole point of the ADT is that a caller branches on which fault it was.
;;;;   2. THE SEAM. Validation lives in :BEFORE methods on the base class, so the test that
;;;;      matters is that EVERY operation rejects a bad key, not that one of them does.
;;;;   3. THE FILESYSTEM BACKEND, end to end -- including the two cases a happy-path test
;;;;      would miss: an overwrite, and a blob whose sidecar is gone.
;;;;   4. THE SWEEP. It deletes user media, so its dry-run, its prefix scoping and its
;;;;      behaviour when the app's predicate ERRORS are all load-bearing.
;;;;   5. THE S3 BACKEND's pure half -- SigV4 string work, addressing, the XML scan. No
;;;;      network: everything here is a function of its arguments.
;;;;
;;;; Not covered, deliberately and worth knowing: there is no end-to-end SigV4 assertion
;;;; against AWS's published example signature, because BLOB-URL calls %AMZ-DATES itself
;;;; and cannot be given a fixed clock. The signature is checked for shape and determinism
;;;; only; the real check is a round trip against MinIO, which needs a container and belongs
;;;; in an integration suite rather than here.

;;; --- Coalton support: the typed core's ADTs, reachable from CL -------------
;;; VALIDATE-BLOB-KEY returns a `Result Key-Fault String', and a Result is awkward to take
;;; apart from CL. Rather than assert on the human-readable message (which would make the
;;; message text load-bearing and the fault vocabulary untested), collapse each fault to a
;;; short tag HERE, in Coalton, where the match is exhaustive and the compiler checks it.

(cl:defpackage #:hermes/blob/tests-key
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:k #:hermes/blob-key))
  (:export #:fault-tag #:visibility-parses? #:visibility-tag #:visibility-public?))
(cl:in-package #:hermes/blob/tests-key)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  (declare fault-tag (String -> String))
  (define (fault-tag s)
    "A short tag naming the fault that rejects S, or \"ok\" if S is a well-formed key.
The match is exhaustive, so a new Key-Fault constructor makes this fail to compile rather
than quietly fall through to a default."
    (match (k:validate-blob-key s)
      ((Ok _) "ok")
      ((Err f)
       (match f
         ((k:Key-Empty) "empty")
         ((k:Key-Too-Long) "too-long")
         ((k:Key-Absolute) "absolute")
         ((k:Key-Trailing-Slash) "trailing-slash")
         ((k:Key-Dot-Segment) "dot-segment")
         ((k:Key-Empty-Segment) "empty-segment")
         ((k:Key-Backslash) "backslash")
         ((k:Key-Bad-Char) "bad-char")))))

  (declare visibility-parses? (String -> Boolean))
  (define (visibility-parses? s)
    "Does S name a visibility at all? (As distinct from defaulting to private.)"
    (match (k:parse-blob-visibility s)
      ((Some _) True)
      ((None) False)))

  (declare visibility-tag (String -> String))
  (define (visibility-tag s)
    "The name of the visibility S decodes to, defaulting to private."
    (k:blob-visibility-name (k:blob-visibility-or-private s)))

  (declare visibility-public? (String -> Boolean))
  (define (visibility-public? s)
    "Does S decode to a visibility that permits an unsigned, non-expiring URL?"
    (k:blob-visibility-public? (k:blob-visibility-or-private s))))

;;; --- the suite proper (CL) -------------------------------------------------

(cl:defpackage #:hermes/blob/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:b #:hermes/blob)
                    (#:k #:hermes/blob-key)
                    (#:tk #:hermes/blob/tests-key))
  (:export #:run-tests))

(in-package #:hermes/blob/tests)

(def-suite hermes-blob :description "Neutral blob store.")
(in-suite hermes-blob)

(defun run-tests ()
  "Run the whole blob suite; return T on success (for `asdf:test-system`)."
  (aion/log:level! :warn)
  (run! 'hermes-blob))

;;; --- helpers ---------------------------------------------------------------

(defvar *root* nil "The temporary directory the current filesystem-store test runs under.")

(defun octets (string)
  (sb-ext:string-to-octets string :external-format :utf-8))

(defun call-with-temp-store (fn &key base-url)
  "Call FN with a fresh FILESYSTEM-STORE under a temporary root, removing the root after."
  (let ((root (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "hermes-blob-test-~A/" (aion/clock:new-id))
                                (uiop:temporary-directory)))))
    (uiop:ensure-all-directories-exist (list root))
    (unwind-protect
         (let ((*root* root))
           (funcall fn (b:make-filesystem-store :root root :base-url base-url)))
      (aion/fs:delete-tree root :if-does-not-exist :ignore))))

(defmacro with-temp-store ((var &key base-url) &body body)
  `(call-with-temp-store (lambda (,var) ,@body) :base-url ,base-url))

(defun put-string (store bucket key string &rest args)
  "PUT-BLOB the UTF-8 bytes of STRING. The blob API takes a STREAM by design (nothing is
ever held whole in memory), so a test that wants to store a literal has to spool it."
  (let ((tmp (merge-pathnames "test-input.bin" *root*)))
    (with-open-file (out tmp :direction :output :element-type '(unsigned-byte 8)
                             :if-exists :supersede :if-does-not-exist :create)
      (write-sequence (octets string) out))
    (with-open-file (in tmp :element-type '(unsigned-byte 8))
      (apply #'b:put-blob store bucket key in args))))

(defun get-string (store bucket key)
  "The blob's bytes, decoded as UTF-8."
  (b:with-blob-stream (in store bucket key)
    (let ((buf (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
      (loop for byte = (read-byte in nil nil)
            while byte do (vector-push-extend byte buf))
      (sb-ext:octets-to-string (coerce buf '(vector (unsigned-byte 8)))
                               :external-format :utf-8))))

;; Published SHA-256 vectors, used to check that the digest computed on the way past during
;; PUT-BLOB is the real thing and not merely self-consistent.
(defparameter +sha256-empty+
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
(defparameter +sha256-hello+
  "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
(defparameter +sha256-abc+
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

;;; === 1. the key vocabulary (Coalton core) =================================

(test key-accepts-ordinary-keys
  "The keys a real app builds must all pass -- a validator that rejects the normal case is
worse than none, because it gets loosened under pressure."
  (dolist (key '("a"
                 "photos/2026/08/portrait.jpg"
                 "members/01H8XYZ/avatar.png"
                 "a.b.c"
                 "base64ish=="
                 "A-Z_a-z-0-9./="))
    (is (string= "ok" (tk:fault-tag key)) "~S should be a valid key" key)
    (is-true (k:blob-key-ok? key) "~S should be a valid key" key)
    (is (string= "" (k:blob-key-fault-message key)))))

(test key-length-boundary
  "MAX-KEY-LENGTH is inclusive: 1024 passes, 1025 does not."
  (is (string= "ok" (tk:fault-tag (make-string 1024 :initial-element #\a))))
  (is (string= "too-long" (tk:fault-tag (make-string 1025 :initial-element #\a)))))

(test key-rejects-by-fault
  "Each malformed key is rejected with the RIGHT fault. Asserting the constructor and not
the message is the point of the ADT: a caller turning a rejection into an HTTP status
branches on this, and a message it has to re-parse is not an answer."
  (let ((cases '(("" . "empty")
                 ("/photos/a.jpg" . "absolute")
                 ("/" . "absolute")
                 ("photos/" . "trailing-slash")
                 ("photos/../../etc/passwd" . "dot-segment")
                 ("photos/./a.jpg" . "dot-segment")
                 (".." . "dot-segment")
                 ("." . "dot-segment")
                 ("photos//a.jpg" . "empty-segment")
                 ("photos\\a.jpg" . "backslash")
                 ("..\\..\\windows\\system32" . "backslash")
                 ("photos/my photo.jpg" . "bad-char")
                 ("photos/a%2Fb.jpg" . "bad-char")
                 ("photos/a?b" . "bad-char")
                 ("photos/a#b" . "bad-char"))))
    (dolist (case (cons
                   ;; Non-ASCII, built rather than written as a literal: the app's job is to
                   ;; encode into the safe alphabet before the key gets here.
                   (cons (concatenate 'string "photos/caf" (string (code-char 233)) ".jpg")
                         "bad-char")
                   cases))
      (destructuring-bind (key . expected) case
        (is (string= expected (tk:fault-tag key)) "~S should be rejected as ~A" key expected)
        (is-false (k:blob-key-ok? key) "~S should be rejected" key)
        (is (plusp (length (k:blob-key-fault-message key))))))))

(test key-fault-message-never-echoes-the-key
  "The report describes the SHAPE that was wrong. A key is very often user-supplied, can
carry a member id, and this text lands in logs."
  (let* ((key "members/12345/my secret photo.jpg")
         (msg (k:blob-key-fault-message key)))
    (is (plusp (length msg)))
    (is-false (search "12345" msg))
    (is-false (search "secret" msg))
    (is-false (search key msg))))

;;; === 2. visibility =========================================================

(test visibility-parses-the-two-tokens
  (is-true (tk:visibility-parses? "private"))
  (is-true (tk:visibility-parses? "public"))
  (is (string= "private" (tk:visibility-tag "private")))
  (is (string= "public" (tk:visibility-tag "public")))
  (is-false (tk:visibility-public? "private"))
  (is-true (tk:visibility-public? "public")))

(test visibility-defaults-to-private
  "A misspelling must not publish user media. Every token that is not exactly `public'
decodes to private -- including a differently-cased one, since the parser documents that
its input is already normalised."
  (dolist (token '("" "Public" "PUBLIC" "pubic" "yes" "true" "world-readable"))
    (is (string= "private" (tk:visibility-tag token)) "~S must not decode to public" token)
    (is-false (tk:visibility-public? token) "~S must not decode to public" token)))

;;; === 3. the seam: every operation validates =================================

(test seam-rejects-a-bad-key-on-every-operation
  "Validation is a :BEFORE on the base class precisely so no backend can forget it, so the
assertion is that ALL of them reject -- one operation missing the check is the bug."
  (with-temp-store (s :base-url "https://cdn.example.com")
    (let ((bad "../../etc/passwd"))
      (signals b:blob-invalid-key (b:get-blob s "media" bad))
      (signals b:blob-invalid-key (b:delete-blob s "media" bad))
      (signals b:blob-invalid-key (b:blob-exists-p s "media" bad))
      (signals b:blob-invalid-key (b:blob-metadata s "media" bad))
      (signals b:blob-invalid-key (b:blob-url s "media" bad))
      (signals b:blob-invalid-key (put-string s "media" bad "pwned")))))

(test seam-rejects-a-bad-bucket
  (with-temp-store (s)
    (dolist (bucket '("" "media/nested" "media\\nested"))
      (signals b:blob-invalid-key (b:list-blobs s bucket))
      (signals b:blob-invalid-key (b:get-blob s bucket "a.txt")))
    (signals b:blob-invalid-key (b:list-blobs s 42))))

(test seam-rejection-writes-nothing
  "A rejected put must not have created the directory tree on its way to being refused."
  (with-temp-store (s)
    (signals b:blob-invalid-key (put-string s "media" "../escape.txt" "x"))
    (is-false (probe-file (merge-pathnames "media/" *root*)))))

(test containment-guard-is-independent-of-the-seam
  "%BLOB-PATH re-checks containment even though the seam already made it impossible. The
guard is the difference between a traversal bug being impossible and being impossible only
as long as two files agree, so it is tested on its own."
  (with-temp-store (s)
    (signals b:blob-invalid-key (b::%blob-path s "media" "../../escape.txt" "objects"))))

;;; === 4. the filesystem backend, end to end =================================

(test filesystem-round-trip
  (with-temp-store (s)
    (let ((meta (put-string s "media" "greetings/en.txt" "hello" :content-type "text/plain")))
      (is (string= "greetings/en.txt" (b:blob-meta-key meta)))
      (is (= 5 (b:blob-meta-size meta)))
      (is (string= "text/plain" (b:blob-meta-content-type meta)))
      (is (string= +sha256-hello+ (b:blob-meta-checksum meta))))
    (is-true (b:blob-exists-p s "media" "greetings/en.txt"))
    (is (string= "hello" (get-string s "media" "greetings/en.txt")))
    (let ((meta (b:blob-metadata s "media" "greetings/en.txt")))
      (is (= 5 (b:blob-meta-size meta)))
      (is (string= "text/plain" (b:blob-meta-content-type meta)))
      (is (string= +sha256-hello+ (b:blob-meta-checksum meta)))
      (is (integerp (b:blob-meta-last-modified meta))))
    (is (equal '("greetings/en.txt") (b:list-blobs s "media")))))

(test filesystem-checksums-are-the-real-sha256
  "Checked against published vectors rather than against the module's own earlier answer --
a digest that is merely self-consistent is not evidence of anything."
  (with-temp-store (s)
    (is (string= +sha256-empty+ (b:blob-meta-checksum (put-string s "m" "empty" ""))))
    (is (string= +sha256-abc+ (b:blob-meta-checksum (put-string s "m" "abc" "abc"))))
    (is (= 0 (b:blob-meta-size (b:blob-metadata s "m" "empty"))))
    (is (string= "" (get-string s "m" "empty")))))

(test filesystem-overwrite-replaces-bytes-and-metadata
  (with-temp-store (s)
    (put-string s "media" "a.txt" "hello" :content-type "text/plain")
    (put-string s "media" "a.txt" "abc" :content-type "application/octet-stream")
    (is (string= "abc" (get-string s "media" "a.txt")))
    (let ((meta (b:blob-metadata s "media" "a.txt")))
      (is (= 3 (b:blob-meta-size meta)))
      (is (string= +sha256-abc+ (b:blob-meta-checksum meta)))
      (is (string= "application/octet-stream" (b:blob-meta-content-type meta))))
    ;; And the overwrite did not leave a second object behind.
    (is (equal '("a.txt") (b:list-blobs s "media")))))

(test filesystem-delete-is-idempotent
  (with-temp-store (s)
    (put-string s "media" "a.txt" "hello")
    (is-true (b:delete-blob s "media" "a.txt"))
    (is-false (b:blob-exists-p s "media" "a.txt"))
    ;; Deleting what is already gone is the caller's intent already holding, not a failure.
    (is-true (b:delete-blob s "media" "a.txt"))
    (signals b:blob-not-found (b:get-blob s "media" "a.txt"))
    (signals b:blob-not-found (b:blob-metadata s "media" "a.txt"))
    (is-false (b:blob-exists-p s "media" "never-existed.txt"))
    (is (null (b:list-blobs s "media")))))

(test filesystem-delete-removes-the-sidecar-too
  "A left-behind sidecar would resurrect stale metadata under a later key of the same name."
  (with-temp-store (s)
    (put-string s "media" "a.txt" "hello" :content-type "text/plain")
    (b:delete-blob s "media" "a.txt")
    (is-false (probe-file (b::%blob-path s "media" "a.txt" "meta")))
    (put-string s "media" "a.txt" "abc")
    (is-false (b:blob-meta-content-type (b:blob-metadata s "media" "a.txt")))))

(test filesystem-metadata-survives-a-missing-sidecar
  "The bytes are still perfectly good, so report what the filesystem itself knows rather
than pretending the blob is absent."
  (with-temp-store (s)
    (put-string s "media" "a.txt" "hello" :content-type "text/plain")
    (uiop:delete-file-if-exists (b::%blob-path s "media" "a.txt" "meta"))
    (let ((meta (b:blob-metadata s "media" "a.txt")))
      (is (= 5 (b:blob-meta-size meta)))
      (is-false (b:blob-meta-content-type meta))
      (is-false (b:blob-meta-checksum meta))
      (is (integerp (b:blob-meta-last-modified meta))))
    (is-true (b:blob-exists-p s "media" "a.txt"))))

(test filesystem-listing-is-sorted-recursive-and-excludes-bookkeeping
  "The sidecars live in a PARALLEL tree so that LIST-BLOBS -- and therefore the sweep --
walks only real objects. If a `meta' entry ever showed up here the sweep would find it
unclaimed and eat its own bookkeeping."
  (with-temp-store (s)
    (dolist (key '("b/2.txt" "a/1.txt" "a/deep/3.txt" "top.txt"))
      (put-string s "media" key "hello" :content-type "text/plain"))
    (is (equal '("a/1.txt" "a/deep/3.txt" "b/2.txt" "top.txt") (b:list-blobs s "media")))
    (is (equal '("a/1.txt" "a/deep/3.txt") (b:list-blobs s "media" :prefix "a/")))
    (is (equal '("top.txt") (b:list-blobs s "media" :prefix "top")))
    (is (null (b:list-blobs s "media" :prefix "nothing/")))
    (is (null (b:list-blobs s "empty-bucket")))))

(test filesystem-buckets-are-isolated
  (with-temp-store (s)
    (put-string s "media" "a.txt" "hello")
    (put-string s "backups" "a.txt" "abc")
    (is (string= "hello" (get-string s "media" "a.txt")))
    (is (string= "abc" (get-string s "backups" "a.txt")))
    (b:delete-blob s "media" "a.txt")
    (is-true (b:blob-exists-p s "backups" "a.txt"))))

(test with-blob-stream-closes-the-stream
  "GET-BLOB hands back a live stream; an app that forgets to close it leaks a descriptor
per view, which shows up as a server that dies under load rather than as a bug at the call
site. The macro must close it however the body leaves -- including by unwinding."
  (with-temp-store (s)
    (put-string s "media" "a.txt" "hello")
    (let ((captured nil))
      (b:with-blob-stream (in s "media" "a.txt")
        (setf captured in))
      (is-false (open-stream-p captured)))
    (let ((captured nil))
      (ignore-errors
       (b:with-blob-stream (in s "media" "a.txt")
         (setf captured in)
         (error "boom")))
      (is-false (open-stream-p captured)))))

;;; === 5. URLs ===============================================================

(test filesystem-url-requires-a-configured-base
  "A store with no public base URL says so rather than inventing one that 404s."
  (with-temp-store (s)
    (put-string s "media" "a.txt" "hello")
    (signals b:blob-unsupported (b:blob-url s "media" "a.txt"))))

(test filesystem-url-joins-without-a-double-slash
  (with-temp-store (s :base-url "https://cdn.example.com")
    (is (string= "https://cdn.example.com/media/photos/a.jpg"
                 (b:blob-url s "media" "photos/a.jpg"))))
  (with-temp-store (s :base-url "https://cdn.example.com/")
    (is (string= "https://cdn.example.com/media/photos/a.jpg"
                 (b:blob-url s "media" "photos/a.jpg")))))

(test filesystem-refuses-to-fake-an-expiring-url
  "The load-bearing one. A local directory has nothing that could VERIFY a signature, so
returning an unsigned URL for an :EXPIRES-IN request would silently turn a private blob
public -- which is the failure this whole module exists to prevent."
  (with-temp-store (s :base-url "https://cdn.example.com")
    (signals b:blob-unsupported (b:blob-url s "media" "a.txt" :expires-in 3600))))

;;; === 6. orphan reconciliation ==============================================

(defun setup-sweep-fixture (s)
  (dolist (key '("a/claimed-1.txt" "a/orphan-1.txt" "a/claimed-2.txt" "b/orphan-2.txt"))
    (put-string s "media" key "hello"))
  (lambda (key) (search "claimed" key)))

(test sweep-dry-run-deletes-nothing
  "Run it this way first -- so it had better be honest about what it would do AND leave
every byte in place."
  (with-temp-store (s)
    (let ((claimed-p (setup-sweep-fixture s)))
      (multiple-value-bind (deleted examined)
          (b:sweep-orphans s "media" claimed-p :dry-run t)
        (is (= 4 examined))
        (is (equal '("a/orphan-1.txt" "b/orphan-2.txt") deleted)))
      (is (= 4 (length (b:list-blobs s "media")))))))

(test sweep-deletes-only-the-unclaimed
  (with-temp-store (s)
    (let ((claimed-p (setup-sweep-fixture s)))
      (multiple-value-bind (deleted examined) (b:sweep-orphans s "media" claimed-p)
        (is (= 4 examined))
        (is (equal '("a/orphan-1.txt" "b/orphan-2.txt") deleted)))
      (is (equal '("a/claimed-1.txt" "a/claimed-2.txt") (b:list-blobs s "media")))
      ;; Idempotent: a second sweep finds nothing left to do.
      (multiple-value-bind (deleted examined) (b:sweep-orphans s "media" claimed-p)
        (is (= 2 examined))
        (is (null deleted))))))

(test sweep-is-scoped-by-prefix
  "A prefix bounds what the sweep may DELETE, so a prefix that silently matches too much is
a data-loss bug, not a filtering bug. Every assertion says what it saw: this test failed on
a Windows runner reporting only its own name, which told nobody which of the three broke."
  (with-temp-store (s)
    (let ((claimed-p (setup-sweep-fixture s)))
      (multiple-value-bind (deleted examined)
          (b:sweep-orphans s "media" claimed-p :prefix "a/")
        (is (= 3 examined)
            "prefix a/ should bound the sweep to the 3 blobs under it, but it examined ~D. All keys: ~S"
            examined (b:list-blobs s "media"))
        (is (equal '("a/orphan-1.txt") deleted)
            "only the unclaimed blob under a/ should be deleted, got ~S" deleted))
      ;; The blob under b/ was never examined, so it is still there.
      (is-true (b:blob-exists-p s "media" "b/orphan-2.txt")
               "b/orphan-2.txt is outside the prefix and must survive; it is gone. Remaining: ~S"
               (b:list-blobs s "media")))))

(test filesystem-keys-are-always-slash-separated
  "A KEY IS PROTOCOL. S3 keys are `/'-separated by definition, so a filesystem backend that
returns a `\\' has made the two backends disagree about what a key IS -- the same app would
produce different keys depending on which store it points at, and a key written on Windows
would not match one written on Linux. Asserting the SHAPE of every key catches that class
at its source, rather than one call site at a time (pre-publication issue 186)."
  (with-temp-store (s)
    (dolist (key '("a/1.txt" "a/deep/nested/3.txt" "top.txt"))
      (put-string s "media" key "hello"))
    (let ((keys (b:list-blobs s "media")))
      (is (= 3 (length keys)) "expected 3 keys, got ~S" keys)
      (dolist (key keys)
        (is (null (find #\\ key))
            "key ~S contains a backslash -- an S3 store would never produce this" key)
        (is (not (uiop:absolute-pathname-p (uiop:parse-unix-namestring key)))
            "key ~S is absolute -- a key is always relative to its bucket" key))
      ;; And the keys are exactly what was PUT, not merely slash-shaped.
      (is (equal '("a/1.txt" "a/deep/nested/3.txt" "top.txt") keys)
          "keys should round-trip unchanged, got ~S" keys))))

(test sweep-stops-when-the-predicate-errors
  "An error from the app's predicate must NOT be read as `unclaimed'. Deleting user media
because a lookup timed out is exactly the failure this sweep exists to avoid causing."
  (with-temp-store (s)
    (setup-sweep-fixture s)
    (signals error
      (b:sweep-orphans s "media" (lambda (key)
                                   (declare (ignore key))
                                   (error "the database is down"))))
    ;; It propagated on the FIRST key, so nothing was deleted.
    (is (= 4 (length (b:list-blobs s "media"))))))

(test sweep-requires-its-predicate-positionally
  "CLAIMED-P is positional so that the dangerous call cannot be the short one: as a keyword
it could be omitted, and an absent predicate means `nothing is claimed', which is
`delete the entire bucket'."
  (with-temp-store (s)
    (setup-sweep-fixture s)
    (signals error (b:sweep-orphans s "media" "not a function"))
    (is (= 4 (length (b:list-blobs s "media"))))))

;;; === 7. the registry =======================================================

(test registry-holds-both-backends
  (is (functionp (gethash "filesystem" b::*stores*)))
  (is (functionp (gethash "s3" b::*stores*)))
  (is (typep (funcall (gethash "filesystem" b::*stores*)) 'b:filesystem-store)))

(test store-from-env-prefers-an-explicitly-bound-store
  (with-temp-store (s)
    (let ((b:*store* s))
      (is (eq s (b:store-from-env))))))

(test store-from-env-names-the-variable-when-nothing-is-registered
  "A misconfigured deploy must fail with the setting to change, not with a NIL somewhere
downstream."
  (let ((b::*stores* (make-hash-table :test #'equal))
        (b:*store* nil))
    (signals b:blob-configuration-error (b:store-from-env))
    (handler-case (b:store-from-env)
      (b:blob-configuration-error (c)
        (is (search "MNEMOSYNE_BLOB_IMPL" (b:blob-configuration-error-missing c)))))))

(test register-store-returns-its-name-and-takes-effect
  (let ((b::*stores* (make-hash-table :test #'equal)))
    (is (string= "Fake" (b:register-store "Fake" (lambda () :a-fake-store))))
    ;; Registered case-insensitively, since MNEMOSYNE_BLOB_IMPL is human-typed.
    (is (eq :a-fake-store (funcall (gethash "fake" b::*stores*))))))

;;; === 8. conditions =========================================================

(test conditions-report-without-leaking-the-key
  (let ((c (make-condition 'b:blob-invalid-key :bucket "media"
                                               :key "members/12345/secret.jpg"
                                               :fault "a blob key may not be empty")))
    (let ((report (princ-to-string c)))
      (is (search "media" report))
      (is (search "may not be empty" report))
      ;; The key stays in the slot, reachable by a handler that has somewhere safe for it.
      (is-false (search "12345" report))
      (is (string= "members/12345/secret.jpg" (b:blob-error-key c)))))
  (is (search "no blob at media/a.txt"
              (princ-to-string (make-condition 'b:blob-not-found :bucket "media" :key "a.txt"))))
  (is (search "HTTP 503"
              (princ-to-string (make-condition 'b:blob-backend-error :status 503))))
  ;; Same rule for the provider's error body. S3 quotes the key back in its XML, and the
  ;; report is what ends up in a log line, so DETAIL is reachable but never printed.
  (let ((c (make-condition 'b:blob-backend-error :bucket "media"
                                                 :key "members/12345/secret.jpg" :status 500
                                                 :detail "<Error><Key>members/12345/secret.jpg</Key></Error>")))
    (let ((report (princ-to-string c)))
      (is (search "HTTP 500" report))
      (is-false (search "12345" report))
      (is-false (search "<Error>" report))
      (is (search "12345" (b:blob-backend-error-detail c))))))

(test every-blob-condition-is-a-blob-error
  "One handler can catch the lot -- the distinction is for callers that want it, not a tax
on callers that do not."
  (dolist (type '(b:blob-not-found b:blob-invalid-key b:blob-backend-error
                  b:blob-configuration-error b:blob-unsupported))
    (is-true (subtypep type 'b:blob-error) "~S should be a BLOB-ERROR" type)))

;;; === 9. the S3 backend's pure half =========================================

(defun test-s3-store (&rest args)
  "An S3-STORE with every setting supplied, so no assertion here depends on what happens to
be in the developer's environment.

ARGS are prepended, not appended: in a keyword argument list the LEFTMOST occurrence is the
one that binds, so defaults have to come last for a caller's override to take effect."
  (apply #'b:make-s3-store
         (append args
                 (list :endpoint "s3.amazonaws.com"
                       :region "us-east-1"
                       :access-key "AKIAIOSFODNN7EXAMPLE"
                       :secret-key "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
                       ;; Explicit, so MNEMOSYNE_S3_UPLOAD_ACL in a developer's environment
                       ;; cannot change what these tests see.
                       :upload-acl :none))))

(defun configuration-error-missing (thunk)
  "The MISSING slot of the BLOB-CONFIGURATION-ERROR that THUNK signals, or NIL if it does
not signal one. Returning the slot rather than asserting inside a handler means a test
cannot pass by never entering the handler at all."
  (handler-case (progn (funcall thunk) nil)
    (b:blob-configuration-error (c) (b:blob-configuration-error-missing c))))

(test s3-store-checks-credentials-at-construction
  "So a deploy missing a secret dies at boot with the variable's name, instead of on the
first upload a member attempts. Each case asserts WHICH setting was named, not merely that
something was signalled -- the name is the whole value of failing at boot."
  (is (string= "MNEMOSYNE_S3_ACCESS_KEY"
               (configuration-error-missing (lambda () (test-s3-store :access-key "")))))
  (is (string= "MNEMOSYNE_S3_SECRET_KEY"
               (configuration-error-missing (lambda () (test-s3-store :secret-key "")))))
  (is (string= "MNEMOSYNE_S3_ENDPOINT"
               (configuration-error-missing (lambda () (test-s3-store :endpoint "")))))
  (is (null (configuration-error-missing (lambda () (test-s3-store))))
      "a fully configured store must not signal")
  (is (typep (test-s3-store) 'b:s3-store))
  (is (string= "s3" (b:store-name (test-s3-store)))))

(test s3-uri-encoding-follows-aws-rules
  "NOT generic URL encoding, and the difference is the classic signature-mismatch bug:
space is %20 and never `+', hex is UPPERCASE, and `~' is left alone."
  (is (string= "a%20b" (b::%uri-encode "a b")))
  (is (string= "a%2Bb" (b::%uri-encode "a+b")))
  (is (string= "-_.~" (b::%uri-encode "-_.~")))
  (is (string= "a%2Fb" (b::%uri-encode "a/b")))
  (is (string= "a/b" (b::%uri-encode "a/b" :encode-slash nil)))
  (is (string= "abcXYZ019" (b::%uri-encode "abcXYZ019")))
  ;; Multi-byte input is encoded per UTF-8 BYTE, not per character.
  (is (string= "%C3%A9" (b::%uri-encode (string (code-char 233)))))
  (is (string= "%2A" (b::%uri-encode "*"))))

(test s3-canonical-query-is-sorted-and-encoded
  (is (string= "a=1%202&b=2" (b::%canonical-query '(("b" . "2") ("a" . "1 2")))))
  (is (string= "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=3600"
               (b::%canonical-query '(("X-Amz-Expires" . "3600")
                                      ("X-Amz-Algorithm" . "AWS4-HMAC-SHA256")))))
  (is (string= "" (b::%canonical-query '()))))

(test s3-addressing-covers-both-styles
  "Virtual-host style for AWS, path style for MinIO and most local test doubles."
  (let ((virtual (test-s3-store))
        (path (test-s3-store :path-style t))
        (plain (test-s3-store :secure nil)))
    (is (string= "media.s3.amazonaws.com" (b::%s3-host virtual "media")))
    (is (string= "s3.amazonaws.com" (b::%s3-host path "media")))
    (is (string= "/photos/a.jpg" (b::%s3-path virtual "media" "photos/a.jpg")))
    (is (string= "/media/photos/a.jpg" (b::%s3-path path "media" "photos/a.jpg")))
    (is (string= "https://media.s3.amazonaws.com/photos/a.jpg"
                 (b::%s3-url virtual "media" "photos/a.jpg")))
    (is (string= "http://media.s3.amazonaws.com/photos/a.jpg"
                 (b::%s3-url plain "media" "photos/a.jpg")))
    ;; A bucket-level request (ListObjectsV2) has no key.
    (is (string= "https://media.s3.amazonaws.com/?list-type=2"
                 (b::%s3-url virtual "media" nil "list-type=2")))
    (is (string= "https://s3.amazonaws.com/media?list-type=2"
                 (b::%s3-url path "media" nil "list-type=2")))))

(test s3-digests-match-published-vectors
  (is (string= +sha256-empty+ (b::%sha256-hex "")))
  (is (string= +sha256-abc+ (b::%sha256-hex "abc")))
  (is (string= +sha256-hello+ (b::%sha256-hex "hello")))
  ;; Bytes and the string that encodes them must digest identically.
  (is (string= (b::%sha256-hex "abc") (b::%sha256-hex (octets "abc")))))

(test s3-signing-key-is-derived-deterministically
  (let ((a (b::%signing-key "secret" "20260815" "us-east-1"))
        (b1 (b::%signing-key "secret" "20260815" "us-east-1"))
        (other-secret (b::%signing-key "secret2" "20260815" "us-east-1"))
        (other-date (b::%signing-key "secret" "20260816" "us-east-1"))
        (other-region (b::%signing-key "secret" "20260815" "eu-west-1")))
    (is (= 32 (length a)) "HMAC-SHA256 output is 32 bytes")
    (is (equalp a b1) "the same inputs must derive the same key")
    (dolist (different (list other-secret other-date other-region))
      (is-false (equalp a different)
                "changing any input must change the derived key"))))

(test s3-credential-scope-and-string-to-sign
  (is (string= "20260815/us-east-1/s3/aws4_request" (b::%credential-scope "20260815" "us-east-1")))
  (let ((sts (b::%string-to-sign "20260815T120000Z" "20260815/us-east-1/s3/aws4_request" "CANONICAL")))
    (let ((lines (uiop:split-string sts :separator '(#\Newline))))
      (is (= 4 (length lines)))
      (is (string= "AWS4-HMAC-SHA256" (first lines)))
      (is (string= "20260815T120000Z" (second lines)))
      (is (string= "20260815/us-east-1/s3/aws4_request" (third lines)))
      (is (string= (b::%sha256-hex "CANONICAL") (fourth lines))))))

(test s3-amz-dates-format-in-utc
  "Fixed clock, so this is a real assertion rather than a tautology. 2013-05-24T00:00:00Z is
AWS's own documented example instant."
  (multiple-value-bind (amz-date date)
      (b::%amz-dates (encode-universal-time 0 0 0 24 5 2013 0))
    (is (string= "20130524T000000Z" amz-date))
    (is (string= "20130524" date)))
  (multiple-value-bind (amz-date date)
      (b::%amz-dates (encode-universal-time 7 6 5 9 1 2026 0))
    (is (string= "20260109T050607Z" amz-date))
    (is (string= "20260109" date))))

(test s3-presigned-url-carries-every-required-parameter
  "No published-vector assertion here -- BLOB-URL reads the clock itself. What is checked is
that the URL is well-formed, signed, expiring, and that the signature actually depends on
the secret."
  (let* ((s (test-s3-store))
         (url (b:blob-url s "media" "photos/a.jpg" :expires-in 3600)))
    (is (eql 0 (search "https://media.s3.amazonaws.com/photos/a.jpg?" url)))
    (dolist (param '("X-Amz-Algorithm=AWS4-HMAC-SHA256" "X-Amz-Credential=" "X-Amz-Date="
                     "X-Amz-Expires=3600" "X-Amz-SignedHeaders=host" "X-Amz-Signature="))
      (is (search param url) "presigned URL should carry ~A" param))
    (let ((sig (subseq url (+ (search "X-Amz-Signature=" url) (length "X-Amz-Signature=")))))
      (is (= 64 (length sig)) "a SigV4 signature is 64 hex characters")
      (is (every (lambda (c) (find c "0123456789abcdef")) sig)))
    ;; A different secret must produce a different signature -- i.e. the key is really used.
    (is-false (string= url (b:blob-url (test-s3-store :secret-key "a-different-secret")
                                       "media" "photos/a.jpg" :expires-in 3600)))))

(test s3-unsigned-url-requires-a-public-base
  (signals b:blob-unsupported (b:blob-url (test-s3-store) "media" "photos/a.jpg"))
  (let ((s (test-s3-store :public-base-url "https://cdn.example.com")))
    (is (string= "https://cdn.example.com/photos/a.jpg" (b:blob-url s "media" "photos/a.jpg"))))
  (let ((s (test-s3-store :public-base-url "https://cdn.example.com/")))
    (is (string= "https://cdn.example.com/photos/a.jpg" (b:blob-url s "media" "photos/a.jpg")))))

(test s3-list-response-scanning
  "The four-line XML scanner, on a response shaped like the real ListObjectsV2."
  (let ((body "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<ListBucketResult><Name>media</Name><IsTruncated>true</IsTruncated>
<NextContinuationToken>1ueGcx</NextContinuationToken>
<Contents><Key>a/1.txt</Key><Size>5</Size></Contents>
<Contents><Key>a/2.txt</Key><Size>6</Size></Contents>
</ListBucketResult>"))
    (is (equal '("a/1.txt" "a/2.txt") (b::%xml-values body "Key")))
    (is (equal '("true") (b::%xml-values body "IsTruncated")))
    (is (equal '("1ueGcx") (b::%xml-values body "NextContinuationToken")))
    (is (null (b::%xml-values body "Missing"))))
  ;; A bucket may hold objects written by something else, and the sweep must not mistake a
  ;; mis-decoded key for an orphan.
  (is (equal '("a&b<c>d\"e'f")
             (b::%xml-values "<Key>a&amp;b&lt;c&gt;d&quot;e&apos;f</Key>" "Key")))
  (is (string= "a-b-c" (b::%replace-all "a.b.c" "." "-")))
  (is (string= "abc" (b::%replace-all "abc" "z" "-")))
  (is (string= "" (b::%replace-all "" "z" "-"))))

;;; --- the paging loop -------------------------------------------------------
;;;
;;; LIST-BLOBS is the only part of the S3 backend with real control flow -- it pages,
;;; accumulates and orders -- and it is the one SWEEP-ORPHANS depends on to be complete.
;;; Substituting %S3-REQUEST, the single function that touches the network, is what makes
;;; it reachable at all; everything above that seam is the real code under test.

(defun s3-list-page (keys &optional next-token)
  "A ListObjectsV2 body carrying KEYS, truncated when NEXT-TOKEN is given."
  (format nil "<?xml version=\"1.0\"?><ListBucketResult><IsTruncated>~A</IsTruncated>~@[<NextContinuationToken>~A</NextContinuationToken>~]~{<Contents><Key>~A</Key><Size>5</Size></Contents>~}</ListBucketResult>"
          (if next-token "true" "false") next-token keys))

(defun call-with-stubbed-s3-request (pages fn)
  "Call FN with %S3-REQUEST answering from PAGES in turn. Returns (values result queries),
QUERIES being the query string of each request in call order -- so a test can assert that
paging was actually FOLLOWED, not merely that the keys came out right."
  (let ((remaining pages)
        (queries '())
        (original (fdefinition 'b::%s3-request)))
    (unwind-protect
         (progn
           (setf (fdefinition 'b::%s3-request)
                 (lambda (store bucket key method &key query &allow-other-keys)
                   (declare (ignore store bucket key method))
                   (push query queries)
                   (or (pop remaining)
                       (error "LIST-BLOBS asked for more pages than this test supplies"))))
           (values (funcall fn) (nreverse queries)))
      (setf (fdefinition 'b::%s3-request) original))))

(test s3-list-blobs-pages-to-the-end-in-order
  "Three pages spliced in order, each continuation token carried into the next request.

The accumulation is a tail pointer rather than (APPEND KEYS PAGE), which was quadratic in
the object count -- and SWEEP-ORPHANS, whose whole job is to walk an entire bucket, is the
caller that meets the big ones."
  (multiple-value-bind (keys queries)
      (call-with-stubbed-s3-request
       (list (s3-list-page '("a/1.txt" "a/2.txt") "tok-1")
             (s3-list-page '("a/3.txt") "tok-2")
             (s3-list-page '("a/4.txt" "a/5.txt")))
       (lambda () (b:list-blobs (test-s3-store) "media" :prefix "a/")))
    (is (equal '("a/1.txt" "a/2.txt" "a/3.txt" "a/4.txt" "a/5.txt") keys))
    (is (= 3 (length queries)))
    (is (search "prefix=a%2F" (first queries)))
    (is-false (search "continuation-token" (first queries)))
    (is (search "continuation-token=tok-1" (second queries)))
    (is (search "continuation-token=tok-2" (third queries)))))

(test s3-list-blobs-handles-empty-pages
  "An empty page must neither end the walk early nor break the splice -- the tail pointer
is still NIL when the second page arrives, which is the case a naive (SETF (CDR TAIL) …)
gets wrong."
  (is (null (call-with-stubbed-s3-request (list (s3-list-page '()))
                                          (lambda () (b:list-blobs (test-s3-store) "media")))))
  (is (equal '("b/1.txt")
             (call-with-stubbed-s3-request
              (list (s3-list-page '() "tok-1") (s3-list-page '("b/1.txt")))
              (lambda () (b:list-blobs (test-s3-store) "media")))))
  ;; And a truncated LAST page with no token stops rather than looping forever asking for
  ;; a page the provider never named.
  (is (equal '("c/1.txt")
             (call-with-stubbed-s3-request
              (list (s3-list-page '("c/1.txt") nil))
              (lambda () (b:list-blobs (test-s3-store) "media"))))))

;;; === 10. direct uploads from a client (#770) =================================
;;;
;;; The signature is checked against AWS's PUBLISHED example, now that %PRESIGN takes the
;;; clock as an argument: "Authenticating Requests: Using Query Parameters (AWS Signature
;;; Version 4)", which presigns GET examplebucket/test.txt at 20130524T000000Z for 86400 s with
;;; AWS's documentation credentials. That closes the gap section 5 of this file's header names.

(defparameter +aws-example-signature+
  "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  "The signature AWS publishes for its query-auth example.")

(defun aws-example-store (&rest args)
  (apply #'b:make-s3-store
         (append args (list :endpoint "s3.amazonaws.com" :region "us-east-1"
                            :access-key "AKIAIOSFODNN7EXAMPLE"
                            :secret-key "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"))))

(defparameter +aws-example-time+ (encode-universal-time 0 0 0 24 5 2013 0)
  "2013-05-24T00:00:00Z, the moment AWS's example is signed at.")

(test s3-presign-matches-aws-published-query-auth-example
  (multiple-value-bind (path-and-query canonical)
      (b::%presign :method "GET" :host "examplebucket.s3.amazonaws.com" :path "/test.txt"
                   :access-key "AKIAIOSFODNN7EXAMPLE"
                   :secret-key "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
                   :region "us-east-1" :amz-date "20130524T000000Z" :date "20130524"
                   :expires-in 86400)
    (is (string= (format nil "/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=~A" +aws-example-signature+)
                 path-and-query)
        "~A" path-and-query)
    (is (string= (format nil "GET~%/test.txt~%X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host~%host:examplebucket.s3.amazonaws.com~%~%host~%UNSIGNED-PAYLOAD")
                 canonical)
        "the canonical request is AWS's, line for line")))

(test s3-presigned-get-url-is-the-aws-example-through-the-store
  "BLOB-URL's signing path, %PRESIGNED-URL, given AWS's moment and store: the published URL,
addressing and scheme included."
  (is (string= (format nil "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=~A" +aws-example-signature+)
               (b::%presigned-url (aws-example-store) "examplebucket" "test.txt" "GET" 86400
                                  :universal-time +aws-example-time+))))

(defun upload-canonical (&key (content-type "video/mp4") (content-length 1234))
  "The canonical request and URL UPLOAD-URL's signing produces at AWS's moment."
  (b::%presign :method "PUT" :host "media.s3.amazonaws.com" :path "/uploads/a.mp4"
               :access-key "AKIAIOSFODNN7EXAMPLE"
               :secret-key "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
               :region "us-east-1" :amz-date "20130524T000000Z" :date "20130524"
               :expires-in 900
               :headers (append (when content-type (list (cons "Content-Type" content-type)))
                                (when content-length (list (cons "Content-Length" (princ-to-string content-length)))))))

(test s3-upload-url-signs-the-content-type-and-the-content-length
  "A presigned PUT signs both headers, so S3 refuses a request that sends another type or
another size. The canonical request carries them, lower-cased and sorted with host."
  (multiple-value-bind (url canonical) (upload-canonical)
    (is (search "X-Amz-SignedHeaders=content-length%3Bcontent-type%3Bhost" url) "~A" url)
    (is (search (format nil "PUT~%/uploads/a.mp4~%") canonical) "~A" canonical)
    (is (search (format nil "content-length:1234~%content-type:video/mp4~%host:media.s3.amazonaws.com~%~%content-length;content-type;host~%UNSIGNED-PAYLOAD") canonical)
        "~A" canonical))
  (flet ((signature (url) (subseq url (+ (search "X-Amz-Signature=" url) 16))))
    (let ((base (signature (upload-canonical))))
      (is (string/= base (signature (upload-canonical :content-type "text/html")))
          "another content type is another signature")
      (is (string/= base (signature (upload-canonical :content-length 1235)))
          "another size is another signature"))))

(test s3-upload-url-returns-a-target-with-the-headers-the-client-must-send
  (let ((target (b:upload-url (test-s3-store) "media" "uploads/a.mp4"
                              :expires-in 900 :content-type "video/mp4"
                              :content-length 1234 :max-bytes 400000000)))
    (is (typep target 'b:upload-target))
    (is (string= "PUT" (b:upload-target-method target)))
    (is (equal '(("Content-Type" . "video/mp4")) (b:upload-target-headers target)))
    (is (= 900 (b:upload-target-expires-in target)))
    (is (= 1234 (b:upload-target-content-length target)))
    (is (eql 0 (search "https://media.s3.amazonaws.com/uploads/a.mp4?X-Amz-Algorithm=AWS4-HMAC-SHA256&"
                       (b:upload-target-url target)))
        "~A" (b:upload-target-url target))
    (is (search "X-Amz-Expires=900" (b:upload-target-url target)))))

(defun upload-refusal (&rest args)
  "The REASON of the BLOB-UPLOAD-REFUSED that UPLOAD-URL signals for ARGS, or NIL."
  (handler-case (progn (apply #'b:upload-url (test-s3-store) "media" "uploads/a.mp4" args) nil)
    (b:blob-upload-refused (c) (b:blob-upload-refused-reason c))))

(test s3-upload-url-refuses-instead-of-signing
  "The size cap is checked before anything is signed: a declared size over MAX-BYTES, or a
MAX-BYTES with no declared size, gets no URL at all. So does an expiry SigV4 would reject."
  (is (eq :too-large (upload-refusal :expires-in 900 :content-length 400000001 :max-bytes 400000000)))
  (is (eq :content-length-required (upload-refusal :expires-in 900 :max-bytes 400000000)))
  (is (eq :bad-expiry (upload-refusal)))
  (is (eq :bad-expiry (upload-refusal :expires-in 0)))
  (is (eq :bad-expiry (upload-refusal :expires-in 604801)))
  (is (eq :bad-content-length (upload-refusal :expires-in 900 :content-length -1)))
  (is (null (upload-refusal :expires-in 900 :content-length 400000000 :max-bytes 400000000))
      "the limit itself is allowed")
  (is (null (upload-refusal :expires-in 604800)) "seven days is allowed")
  (signals b:blob-invalid-key (b:upload-url (test-s3-store) "media" "../etc/passwd" :expires-in 900)))

(defmacro with-captured-log ((stream) &body body)
  "Run BODY with the log at :INFO going to STREAM, then put back the appenders, level and layout
that were there before."
  (let ((appenders (gensym "APPENDERS")) (level (gensym "LEVEL")) (layout (gensym "LAYOUT")))
    `(let ((,appenders (copy-list (log4cl:logger-appenders log4cl:*root-logger*)))
           (,level (log4cl:logger-log-level log4cl:*root-logger*))
           (,layout aion/log:*layout*))
       (unwind-protect
            (progn (aion/log:setup :env :dev :level :info :stream ,stream)
                   ,@body)
         (log4cl:remove-all-appenders log4cl:*root-logger*)
         (dolist (appender ,appenders)
           (log4cl:add-appender log4cl:*root-logger* appender))
         (log4cl:set-log-level log4cl:*root-logger* ,level)
         (setf aion/log:*layout* ,layout)))))

(test s3-upload-url-logs-the-key-expiry-and-cap-but-never-the-url
  "A presigned URL is a credential, so neither it nor its signature may reach a log (#770)."
  (let* ((log (make-string-output-stream))
         (target (with-captured-log (log)
                   (b:upload-url (test-s3-store) "media" "uploads/a.mp4"
                                 :expires-in 900 :content-length 1234 :max-bytes 400000000)))
         (text (get-output-stream-string log))
         (url (b:upload-target-url target))
         (signature (subseq url (+ (search "X-Amz-Signature=" url) 16))))
    (is (search "blob upload URL issued" text) "the issue is logged: ~A" text)
    (is (search "uploads/a.mp4" text) "with the key: ~A" text)
    (is (search "900" text) "the expiry: ~A" text)
    (is (search "400000000" text) "and the cap: ~A" text)
    (is (not (search signature text)) "never the signature: ~A" text)
    (is (not (search "X-Amz-" text)) "and no part of the query string: ~A" text)))

(defclass counting-octet-stream (sb-gray:fundamental-binary-input-stream)
  ((data :initarg :data :reader counting-data)
   (position :initform 0 :accessor counting-position))
  (:documentation "An octet input stream over a vector that records how many bytes were read,
standing in for a response body: a test can see that a reader stopped early."))

(defmethod stream-element-type ((s counting-octet-stream)) '(unsigned-byte 8))

(defmethod sb-gray:stream-read-byte ((s counting-octet-stream))
  (if (< (counting-position s) (length (counting-data s)))
      (prog1 (aref (counting-data s) (counting-position s)) (incf (counting-position s)))
      :eof))

(defmethod sb-gray:stream-read-sequence ((s counting-octet-stream) seq &optional (start 0) end)
  (let* ((end (or end (length seq)))
         (n (min (- end start) (- (length (counting-data s)) (counting-position s)))))
    (replace seq (counting-data s) :start1 start :end1 (+ start n) :start2 (counting-position s))
    (incf (counting-position s) n)
    (+ start n)))

(defun call-with-ranged-s3 (answer fn)
  "Call FN with %S3-REQUEST answering ANSWER: a list (body status), where BODY is served as a
COUNTING-OCTET-STREAM; a status to signal as BLOB-BACKEND-ERROR; or :NOT-FOUND.
Returns (values result range-header body-stream methods) so a test sees the Range that was
signed, how much of the body was read, and which requests were made."
  (let ((original (fdefinition 'b::%s3-request))
        (range nil) (stream nil) (methods '()))
    (unwind-protect
         (progn
           (setf (fdefinition 'b::%s3-request)
                 (lambda (store bucket key method &key extra-headers &allow-other-keys)
                   (declare (ignore store))
                   (push method methods)
                   (setf range (cdr (assoc "range" extra-headers :test #'string-equal)))
                   (cond ((eq answer :not-found) (error 'b:blob-not-found :bucket bucket :key key))
                         ((integerp answer)
                          (error 'b:blob-backend-error :bucket bucket :key key :status answer))
                         (t (setf stream (make-instance 'counting-octet-stream :data (first answer)))
                            (values stream (second answer) (make-hash-table :test #'equal))))))
           (values (funcall fn) range stream (reverse methods)))
      (setf (fdefinition 'b::%s3-request) original))))

(test s3-read-blob-range-asks-for-the-range-and-handles-the-edges
  (multiple-value-bind (bytes range)
      (call-with-ranged-s3 (list (octets "fLaC") 206)
                           (lambda () (b:read-blob-range (test-s3-store) "media" "a.flac" :start 0 :length 4)))
    (is (equalp (octets "fLaC") bytes))
    (is (string= "bytes=0-3" range)))
  (is (equalp (octets "cd")
              (call-with-ranged-s3 (list (octets "abcdef") 200)
                                   (lambda () (b:read-blob-range (test-s3-store) "media" "a" :start 2 :length 2))))
      "a store that ignores Range and answers 200 is cut down to the range")
  (is (equalp #() (call-with-ranged-s3 416 (lambda () (b:read-blob-range (test-s3-store) "media" "a" :start 99))))
      "416, a start past the end, is no bytes")
  (signals b:blob-backend-error
    (call-with-ranged-s3 500 (lambda () (b:read-blob-range (test-s3-store) "media" "a")))))

(test s3-read-blob-range-reads-only-the-range-when-the-store-ignores-range
  "A store or proxy that ignores Range answers 200 with the whole object. Only START + LENGTH
bytes of it are read, and the body is closed, so a large object is never held in memory (#796)."
  (let ((object (make-array 1000000 :element-type '(unsigned-byte 8) :initial-element 7)))
    (setf (aref object 10) 1 (aref object 11) 2)
    (multiple-value-bind (bytes range body)
        (call-with-ranged-s3 (list object 200)
                             (lambda () (b:read-blob-range (test-s3-store) "media" "big" :start 10 :length 2)))
      (is (equalp #(1 2) bytes))
      (is (string= "bytes=10-11" range))
      (is (= 12 (counting-position body)) "read ~D bytes of a 1000000-byte body" (counting-position body))
      (is (not (open-stream-p body)) "the body is closed")))
  (multiple-value-bind (bytes range body)
      (call-with-ranged-s3 (list (octets "abcdef") 206)
                           (lambda () (b:read-blob-range (test-s3-store) "media" "a" :start 2 :length 2)))
    (declare (ignore range))
    (is (equalp (octets "ab") bytes) "a 206 body is the range itself, read from its first byte")
    (is (not (open-stream-p body)))))

(test s3-zero-length-read-blob-range-still-reports-a-missing-blob
  "No Range header can ask for zero bytes, so a zero-length read asks whether the blob exists,
and a missing one signals BLOB-NOT-FOUND as it does on the filesystem store (#796)."
  (multiple-value-bind (bytes range body methods)
      (call-with-ranged-s3 (list (octets "") 200)
                           (lambda () (b:read-blob-range (test-s3-store) "media" "a" :length 0)))
    (declare (ignore range body))
    (is (equalp #() bytes))
    (is (equal '(:head) methods) "one HEAD request, no GET"))
  (signals b:blob-not-found
    (call-with-ranged-s3 :not-found (lambda () (b:read-blob-range (test-s3-store) "media" "missing" :length 0)))))

(test filesystem-upload-url-is-unsupported-so-the-app-proxies
  (with-temp-store (store)
    (is (search "presigned uploads"
                (handler-case (progn (b:upload-url store "media" "a.mp4" :expires-in 900) nil)
                  (b:blob-unsupported (c) (b:blob-unsupported-operation c)))))))

(test filesystem-read-blob-range-reads-what-is-there
  (with-temp-store (store)
    (put-string store "media" "a.txt" "abcdef")
    (is (equalp (octets "abc") (b:read-blob-range store "media" "a.txt" :length 3)))
    (is (equalp (octets "def") (b:read-blob-range store "media" "a.txt" :start 3 :length 10))
        "shorter when the blob ends sooner")
    (is (equalp #() (b:read-blob-range store "media" "a.txt" :start 6)) "empty at the end")
    (is (equalp #() (b:read-blob-range store "media" "a.txt" :start 100)) "and past it")
    (signals b:blob-not-found (b:read-blob-range store "media" "missing.txt"))))

(test blob-meta-carries-an-etag-and-old-constructor-calls-still-work
  (is (null (b:blob-meta-etag (b:make-blob-meta "k" 1 "text/plain" nil))))
  (is (string= "abc" (b:blob-meta-etag (b:make-blob-meta "k" 1 "text/plain" nil nil "abc")))))

;;; --- review fixes to #772 ---------------------------------------------------

(test upload-target-prints-without-its-url
  "A target printed into a log line, an error message or a backtrace must not carry the
presigned URL or its signature."
  (let ((target (b:upload-url (test-s3-store) "media" "uploads/a.mp4"
                              :expires-in 900 :content-type "video/mp4" :content-length 1234)))
    (is (search "X-Amz-Signature" (b:upload-target-url target)) "the URL itself is signed")
    (dolist (printed (list (prin1-to-string target) (princ-to-string target)
                           (format nil "~A ~S" target target)))
      (is (not (search "X-Amz-Signature" printed)) "~A" printed)
      (is (not (search "amazonaws" printed)) "~A" printed))
    (is (search "expires-in 900" (princ-to-string target)) "~A" target)))

(defclass get-only-store (b:store)
  ((inner :initarg :inner :reader get-only-inner))
  (:documentation "A store an app might define, implementing GET-BLOB and nothing for #770."))

(defmethod b:get-blob ((s get-only-store) bucket key)
  (b:get-blob (get-only-inner s) bucket key))

(test a-store-without-the-new-methods-gets-the-documented-defaults
  "UPLOAD-URL signals BLOB-UNSUPPORTED and READ-BLOB-RANGE reads through GET-BLOB, rather than
NO-APPLICABLE-METHOD, on a store class that implements neither."
  (with-temp-store (inner)
    (put-string inner "media" "a.txt" "abcdef")
    (let ((store (make-instance 'get-only-store :inner inner)))
      (signals b:blob-unsupported (b:upload-url store "media" "a.mp4" :expires-in 900))
      (is (equalp (octets "abc") (b:read-blob-range store "media" "a.txt" :length 3)))
      (is (equalp (octets "def") (b:read-blob-range store "media" "a.txt" :start 3 :length 10))
          "shorter when the blob ends sooner")
      (is (equalp #() (b:read-blob-range store "media" "a.txt" :start 100)) "empty past the end")
      (signals b:blob-not-found (b:read-blob-range store "media" "missing.txt")))))

(test s3-upload-url-refuses-a-bad-content-type-max-bytes-or-oversized-put
  (dolist (bad (list (format nil "text/html~C~CX-Evil: 1" #\Return #\Linefeed)
                     (format nil "video/mp4~C" #\Linefeed)
                     (format nil "video/mp4~Cx" #\Tab)
                     "" "   " :video))
    (is (eq :bad-content-type (upload-refusal :expires-in 900 :content-type bad)) "~S" bad))
  (is (eq :bad-max-bytes (upload-refusal :expires-in 900 :content-length 10 :max-bytes -1)))
  (is (eq :bad-max-bytes (upload-refusal :expires-in 900 :content-length 10 :max-bytes "100")))
  (let ((five-gib (* 5 1024 1024 1024)))
    (is (null (upload-refusal :expires-in 900 :content-length five-gib)) "5 GiB itself is allowed")
    (is (eq :too-large-for-single-put (upload-refusal :expires-in 900 :content-length (1+ five-gib))))))

(test s3-upload-url-returns-the-content-type-it-signed
  "Spaces around the content type are trimmed before signing, and the header the client is told
to send is the trimmed value, so the client sends exactly what was signed."
  (let ((target (b:upload-url (test-s3-store) "media" "uploads/a.mp4"
                              :expires-in 900 :content-type "  video/mp4 ")))
    (is (equal '(("Content-Type" . "video/mp4")) (b:upload-target-headers target)))))

;;; === 11. bucket CORS for browser uploads (#770) ===============================

(test s3-base64-matches-rfc-4648-vectors
  "RFC 4648 section 10's test vectors, and the MD5 of nothing as S3's Content-MD5 sees it."
  (loop for (in out) in '(("" "") ("f" "Zg==") ("fo" "Zm8=") ("foo" "Zm9v") ("foob" "Zm9vYg==")
                          ("fooba" "Zm9vYmE=") ("foobar" "Zm9vYmFy"))
        do (is (string= out (b::%base64 (octets in))) "~S" in))
  (is (string= "1B2M2Y8AsgTpgAmY7PhCfg==" (b::%base64 (ironclad:digest-sequence :md5 (octets ""))))))

(test s3-cors-document-is-one-escaped-rule
  (is (string= "<CORSConfiguration><CORSRule><AllowedOrigin>https://app.example.com</AllowedOrigin><AllowedOrigin>https://a&amp;b.example</AllowedOrigin><AllowedMethod>PUT</AllowedMethod><AllowedHeader>Content-Type</AllowedHeader><MaxAgeSeconds>3000</MaxAgeSeconds></CORSRule></CORSConfiguration>"
               (b::%cors-xml '("https://app.example.com" "https://a&b.example") '("PUT") '("Content-Type") 3000))))

(defun call-with-recorded-s3 (answer fn)
  "Call FN with %S3-REQUEST recording each call's arguments and answering ANSWER (a body, or
:NOT-FOUND to signal BLOB-NOT-FOUND). Returns (values result calls)."
  (let ((original (fdefinition 'b::%s3-request))
        (calls '()))
    (unwind-protect
         (progn
           (setf (fdefinition 'b::%s3-request)
                 (lambda (store bucket key method &rest args)
                   (declare (ignore store))
                   (push (list* :bucket bucket :key key :method method args) calls)
                   (if (eq answer :not-found)
                       (error 'b:blob-not-found :bucket bucket :key key)
                       (values answer 200 (make-hash-table :test #'equal)))))
           (values (funcall fn) (nreverse calls)))
      (setf (fdefinition 'b::%s3-request) original))))

(test s3-cors-document-exposes-headers-when-asked
  "A browser completing a multipart upload reads each part's ETag, which it can only do when the
rule exposes it (#770)."
  (is (search "<AllowedHeader>Content-Type</AllowedHeader><ExposeHeader>ETag</ExposeHeader><MaxAgeSeconds>"
              (b::%cors-xml '("https://app.example.com") '("PUT") '("Content-Type") 3000 '("ETag")))))

(test s3-put-bucket-cors-sends-the-rule-with-its-content-md5
  (multiple-value-bind (result calls)
      (call-with-recorded-s3 "" (lambda () (b:put-bucket-cors (test-s3-store) "media" :origins '("https://app.example.com"))))
    (is (eq t result))
    (is (= 1 (length calls)))
    (let* ((call (first calls))
           (body (getf call :content)))
      (is (eq :put (getf call :method)))
      (is (null (getf call :key)) "a bucket-level request")
      (is (string= "cors=" (getf call :query)))
      (is (string= "application/xml" (getf call :content-type)))
      (is (string= (b::%cors-xml '("https://app.example.com") '("PUT") '("Content-Type" "x-amz-acl") 3000)
                   (sb-ext:octets-to-string body :external-format :utf-8))
          "the default allows the headers UPLOAD-URL's target carries")
      (is (string= (b::%base64 (ironclad:digest-sequence :md5 body))
                   (cdr (assoc "content-md5" (getf call :extra-headers) :test #'string=)))
          "Content-MD5 is the body's, which PutBucketCors requires"))))

(test s3-cors-wildcards-match-as-s3-does
  (is (b::%wildcard-match-p "https://app.example.com" "https://app.example.com"))
  (is (not (b::%wildcard-match-p "https://app.example.com" "https://evil.example.com")))
  (is (b::%wildcard-match-p "*" "https://anything.example"))
  (is (b::%wildcard-match-p "https://*.example.com" "https://app.example.com"))
  (is (not (b::%wildcard-match-p "https://*.example.com" "https://example.org")))
  (is (not (b::%wildcard-match-p "https://*.example.com" "http://app.example.com")))
  (is (b::%wildcard-match-p "content-type" "Content-Type" :case-insensitive t))
  (is (not (b::%wildcard-match-p "content-type" "Content-Type"))))

(test s3-cors-verdict-names-the-first-test-no-rule-passes
  (let ((rule '(:origins ("https://app.example.com") :methods ("PUT") :headers ("Content-Type"))))
    (is (eq :allowed (b::%cors-verdict (list rule) "https://app.example.com" "PUT" '("Content-Type"))))
    (is (eq :allowed (b::%cors-verdict (list rule) "https://app.example.com" "PUT" '("content-type")))
        "header names are compared without case")
    (is (eq :no-cors-configuration (b::%cors-verdict '() "https://app.example.com" "PUT" '("Content-Type"))))
    (is (eq :origin-not-allowed (b::%cors-verdict (list rule) "https://other.example" "PUT" '("Content-Type"))))
    (is (eq :method-not-allowed (b::%cors-verdict (list rule) "https://app.example.com" "POST" '("Content-Type"))))
    (is (eq :header-not-allowed (b::%cors-verdict (list rule) "https://app.example.com" "PUT" '("Content-Type" "X-Extra"))))
    (is (eq :allowed (b::%cors-verdict (list '(:origins ("*") :methods ("GET")) rule)
                                       "https://app.example.com" "PUT" '("Content-Type")))
        "any one rule that passes every test is enough")))

(test s3-check-bucket-cors-reads-the-bucket-rules
  (let ((xml "<CORSConfiguration><CORSRule><AllowedOrigin>https://app.example.com</AllowedOrigin><AllowedMethod>PUT</AllowedMethod><AllowedHeader>*</AllowedHeader></CORSRule></CORSConfiguration>"))
    (multiple-value-bind (verdict calls)
        (call-with-recorded-s3 (octets xml) (lambda () (b:check-bucket-cors (test-s3-store) "media" "https://app.example.com")))
      (is (eq :allowed verdict))
      (is (string= "cors=" (getf (first calls) :query)))
      (is (eq :get (getf (first calls) :method))))
    (is (eq :origin-not-allowed
            (call-with-recorded-s3 (octets xml) (lambda () (b:check-bucket-cors (test-s3-store) "media" "https://evil.example"))))))
  (is (eq :no-cors-configuration
          (call-with-recorded-s3 :not-found (lambda () (b:check-bucket-cors (test-s3-store) "media" "https://app.example.com"))))
      "NoSuchCORSConfiguration, a 404, is no configuration"))

(test cors-on-the-filesystem-store-is-unsupported-and-arguments-are-checked
  (with-temp-store (store)
    (signals b:blob-unsupported (b:put-bucket-cors store "media" :origins '("https://app.example.com")))
    (signals b:blob-unsupported (b:check-bucket-cors store "media" "https://app.example.com")))
  (signals type-error (b:put-bucket-cors (test-s3-store) "media" :origins '()))
  (signals type-error (b:put-bucket-cors (test-s3-store) "media" :origins '("")))
  (signals b:blob-invalid-key (b:put-bucket-cors (test-s3-store) "a/b" :origins '("https://x"))))

;;; === 12. multipart uploads (#770) =============================================

(defun call-with-answering-s3 (answers fn)
  "Call FN with %S3-REQUEST answering from ANSWERS in turn (a body string, or :NOT-FOUND), and
recording each call. Returns (values result calls)."
  (let ((original (fdefinition 'b::%s3-request))
        (remaining answers)
        (calls '()))
    (unwind-protect
         (progn
           (setf (fdefinition 'b::%s3-request)
                 (lambda (store bucket key method &rest args)
                   (declare (ignore store))
                   (push (list* :bucket bucket :key key :method method args) calls)
                   (let ((answer (if remaining (pop remaining) (error "more S3 requests than this test answers"))))
                     (if (eq answer :not-found)
                         (error 'b:blob-not-found :bucket bucket :key key)
                         (values (octets answer) 200 (make-hash-table :test #'equal))))))
           (values (funcall fn) (nreverse calls)))
      (setf (fdefinition 'b::%s3-request) original))))

(test s3-multipart-part-url-signs-the-part-number-and-the-upload-id
  (flet ((presign (part)
           (b::%presign :method "PUT" :host "media.s3.amazonaws.com" :path "/big.mp4"
                        :access-key "AKIAIOSFODNN7EXAMPLE" :secret-key "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
                        :region "us-east-1" :amz-date "20130524T000000Z" :date "20130524" :expires-in 900
                        :query-params (list (cons "partNumber" (princ-to-string part)) (cons "uploadId" "u-1")))))
    (multiple-value-bind (url canonical) (presign 3)
      (is (search "partNumber=3" url) "~A" url)
      (is (search "uploadId=u-1" url) "~A" url)
      (is (search "partNumber=3&uploadId=u-1" canonical) "the canonical query carries both: ~A" canonical))
    (is (string/= (subseq (presign 3) (search "X-Amz-Signature=" (presign 3)))
                  (subseq (presign 4) (search "X-Amz-Signature=" (presign 4))))
        "another part is another signature"))
  (let ((target (b:multipart-part-url (test-s3-store) "media" "big.mp4" "u-1" 7 :expires-in 900 :content-length 5242880)))
    (is (string= "PUT" (b:upload-target-method target)))
    (is (= 5242880 (b:upload-target-content-length target)))
    (is (search "partNumber=7" (b:upload-target-url target)))
    (is (search "content-length%3Bhost" (b:upload-target-url target)) "the part's size is signed")))

(defun multipart-refusal (thunk)
  (handler-case (progn (funcall thunk) nil)
    (b:blob-upload-refused (c) (b:blob-upload-refused-reason c))))

(test s3-multipart-calls-refuse-bad-arguments
  (let ((s (test-s3-store)))
    (is (eq :bad-part-number (multipart-refusal (lambda () (b:multipart-part-url s "media" "big.mp4" "u-1" 0 :expires-in 900)))))
    (is (eq :bad-part-number (multipart-refusal (lambda () (b:multipart-part-url s "media" "big.mp4" "u-1" 10001 :expires-in 900)))))
    (is (eq :bad-upload-id (multipart-refusal (lambda () (b:multipart-part-url s "media" "big.mp4" "" 1 :expires-in 900)))))
    (is (eq :bad-expiry (multipart-refusal (lambda () (b:multipart-part-url s "media" "big.mp4" "u-1" 1)))))
    (is (eq :bad-parts (multipart-refusal (lambda () (b:complete-multipart-upload s "media" "big.mp4" "u-1" '())))))
    (is (eq :bad-parts (multipart-refusal (lambda () (b:complete-multipart-upload s "media" "big.mp4" "u-1" '((1 . "")))))))
    (is (null (multipart-refusal (lambda () (b:multipart-part-url s "media" "big.mp4" "u-1" 10000 :expires-in 900))))
        "part 10000 is allowed")))

(test s3-start-multipart-upload-returns-the-upload-id
  (multiple-value-bind (id calls)
      (call-with-answering-s3 (list "<InitiateMultipartUploadResult><Bucket>media</Bucket><Key>big.mp4</Key><UploadId>VXBsb2FkIElE</UploadId></InitiateMultipartUploadResult>")
                              (lambda () (b:start-multipart-upload (test-s3-store) "media" "big.mp4" :content-type "video/mp4")))
    (is (string= "VXBsb2FkIElE" id))
    (is (eq :post (getf (first calls) :method)))
    (is (string= "uploads=" (getf (first calls) :query)))
    (is (string= "video/mp4" (getf (first calls) :content-type))))
  (signals b:blob-backend-error
    (call-with-answering-s3 (list "<InitiateMultipartUploadResult></InitiateMultipartUploadResult>")
                            (lambda () (b:start-multipart-upload (test-s3-store) "media" "big.mp4")))))

(test s3-complete-multipart-upload-sends-the-parts-in-order-and-reads-an-error-in-a-200
  (is (string= "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>&quot;a&quot;</ETag></Part><Part><PartNumber>2</PartNumber><ETag>&quot;b&quot;</ETag></Part></CompleteMultipartUpload>"
               (b::%complete-xml '((2 . "\"b\"") (1 . "\"a\""))))
      "ascending part numbers, ETags escaped")
  (multiple-value-bind (result calls)
      (call-with-answering-s3 (list "<CompleteMultipartUploadResult><ETag>\"x-2\"</ETag></CompleteMultipartUploadResult>")
                              (lambda () (b:complete-multipart-upload (test-s3-store) "media" "big.mp4" "u-1" '((1 . "\"a\"") (2 . "\"b\"")))))
    (is (eq t result))
    (is (eq :post (getf (first calls) :method)))
    (is (string= "uploadId=u-1" (getf (first calls) :query))))
  (is (string= "InvalidPart"
               (handler-case
                   (progn (call-with-answering-s3 (list "<Error><Code>InvalidPart</Code><Message>m</Message></Error>")
                                                  (lambda () (b:complete-multipart-upload (test-s3-store) "media" "big.mp4" "u-1" '((1 . "\"a\"")))))
                          nil)
                 (b:blob-backend-error (c) (b:blob-backend-error-detail c))))
      "a 200 whose body is an <Error> is a failure"))

(test s3-abort-multipart-upload-is-idempotent
  (multiple-value-bind (result calls)
      (call-with-answering-s3 (list "") (lambda () (b:abort-multipart-upload (test-s3-store) "media" "big.mp4" "u-1")))
    (is (eq t result))
    (is (eq :delete (getf (first calls) :method)))
    (is (string= "uploadId=u-1" (getf (first calls) :query))))
  (is (eq t (call-with-answering-s3 (list :not-found) (lambda () (b:abort-multipart-upload (test-s3-store) "media" "big.mp4" "u-1"))))
      "NoSuchUpload is aborted"))

(test s3-list-multipart-parts-follows-the-pages
  (multiple-value-bind (parts calls)
      (call-with-answering-s3
       (list "<ListPartsResult><IsTruncated>true</IsTruncated><NextPartNumberMarker>2</NextPartNumberMarker><Part><PartNumber>2</PartNumber><ETag>\"b\"</ETag><Size>5242880</Size></Part><Part><PartNumber>1</PartNumber><ETag>\"a\"</ETag><Size>5242880</Size></Part></ListPartsResult>"
             "<ListPartsResult><IsTruncated>false</IsTruncated><Part><PartNumber>3</PartNumber><ETag>\"c\"</ETag><Size>100</Size></Part></ListPartsResult>")
       (lambda () (b:list-multipart-parts (test-s3-store) "media" "big.mp4" "u-1")))
    (is (equal '((1 "\"a\"" 5242880) (2 "\"b\"" 5242880) (3 "\"c\"" 100)) parts))
    (is (= 2 (length calls)))
    (is (string= "uploadId=u-1" (getf (first calls) :query)))
    (is (string= "part-number-marker=2&uploadId=u-1" (getf (second calls) :query)) "the marker is followed")))

(test multipart-on-the-filesystem-store-is-unsupported
  (with-temp-store (store)
    (signals b:blob-unsupported (b:start-multipart-upload store "media" "a"))
    (signals b:blob-unsupported (b:multipart-part-url store "media" "a" "u" 1 :expires-in 900))
    (signals b:blob-unsupported (b:complete-multipart-upload store "media" "a" "u" '((1 . "e"))))
    (signals b:blob-unsupported (b:abort-multipart-upload store "media" "a" "u"))
    (signals b:blob-unsupported (b:list-multipart-parts store "media" "a" "u"))))

;;; === 13. the upload's ACL, a setting on the S3 store (#796) =====================
;;;
;;; Measured on MinIO in #796: an unsigned x-amz-acl: public-read added by the client is accepted,
;;; and with x-amz-acl: private signed, public-read is refused (403) and so is leaving it out (400).
;;; The maintainer ruled that signing it is a store setting, off by default, because an AWS bucket
;;; with ACLs disabled (the AWS default) refuses an upload naming `private'.

(defun signed-headers-of (url)
  "The X-Amz-SignedHeaders value of a presigned URL, still percent-encoded."
  (let* ((start (+ (search "X-Amz-SignedHeaders=" url) 20))
         (end (or (position #\& url :start start) (length url))))
    (subseq url start end)))

(test s3-upload-url-signs-no-acl-by-default
  "The control for the test below: a store made without :UPLOAD-ACL signs no ACL and tells the
client to send no ACL header."
  (let ((target (b:upload-url (test-s3-store) "media" "uploads/a.mp4"
                              :expires-in 900 :content-type "video/mp4" :content-length 1234)))
    (is (eq :none (b::s3-upload-acl (test-s3-store))))
    (is (string= "content-length%3Bcontent-type%3Bhost" (signed-headers-of (b:upload-target-url target))))
    (is (null (assoc "x-amz-acl" (b:upload-target-headers target) :test #'string-equal)))))

(test s3-upload-url-signs-a-private-acl-when-the-store-is-set-to
  (let ((target (b:upload-url (test-s3-store :upload-acl :private) "media" "uploads/a.mp4"
                              :expires-in 900 :content-type "video/mp4" :content-length 1234)))
    (is (string= "content-length%3Bcontent-type%3Bhost%3Bx-amz-acl"
                 (signed-headers-of (b:upload-target-url target))))
    (is (equal '(("Content-Type" . "video/mp4") ("x-amz-acl" . "private")) (b:upload-target-headers target))
        "the client is told to send the header that was signed"))
  (let ((target (b:upload-url (test-s3-store :upload-acl :private) "media" "uploads/a.bin" :expires-in 900)))
    (is (string= "host%3Bx-amz-acl" (signed-headers-of (b:upload-target-url target))))
    (is (equal '(("x-amz-acl" . "private")) (b:upload-target-headers target))
        "signed with no content type or size given as well")))

(defmacro with-environment-variable ((name value) &body body)
  "Run BODY with the environment variable NAME set to VALUE, then restore it. NIL sets it to the
empty string, which MAKE-S3-STORE reads as unset, so no unsetenv (and no sb-posix) is needed."
  (let ((old (gensym "OLD")))
    `(let ((,old (uiop:getenv ,name)))
       (unwind-protect
            (progn (setf (uiop:getenv ,name) (or ,value ""))
                   ,@body)
         (setf (uiop:getenv ,name) (or ,old ""))))))

(test s3-upload-acl-setting-comes-from-the-argument-or-the-environment
  (flet ((store-acl (&rest args)
           (b::s3-upload-acl (apply #'b:make-s3-store :endpoint "s3.amazonaws.com"
                                    :access-key "AKIAIOSFODNN7EXAMPLE" :secret-key "x" args))))
    (with-environment-variable ("MNEMOSYNE_S3_UPLOAD_ACL" nil)
      (is (eq :none (store-acl)) "unset is no ACL")
      (is (eq :private (store-acl :upload-acl :private))))
    (with-environment-variable ("MNEMOSYNE_S3_UPLOAD_ACL" "private")
      (is (eq :private (store-acl)))
      (is (eq :none (store-acl :upload-acl :none)) "the argument wins over the environment"))
    (with-environment-variable ("MNEMOSYNE_S3_UPLOAD_ACL" "None")
      (is (eq :none (store-acl)) "case does not matter"))
    (with-environment-variable ("MNEMOSYNE_S3_UPLOAD_ACL" "public-read")
      (signals b:blob-configuration-error (store-acl)))
    (signals b:blob-configuration-error (store-acl :upload-acl :public-read))
    (signals b:blob-configuration-error (store-acl :upload-acl "private"))))

(test s3-check-bucket-cors-by-default-checks-the-headers-this-store-sends
  "A rule that allows only Content-Type is enough for a store that signs no ACL, and blocks the
upload on a store that signs one, because the browser then sends x-amz-acl as well."
  (let ((old-rule "<CORSConfiguration><CORSRule><AllowedOrigin>https://app.example.com</AllowedOrigin><AllowedMethod>PUT</AllowedMethod><AllowedHeader>Content-Type</AllowedHeader></CORSRule></CORSConfiguration>")
        (new-rule "<CORSConfiguration><CORSRule><AllowedOrigin>https://app.example.com</AllowedOrigin><AllowedMethod>PUT</AllowedMethod><AllowedHeader>Content-Type</AllowedHeader><AllowedHeader>x-amz-acl</AllowedHeader></CORSRule></CORSConfiguration>"))
    (flet ((verdict (rule store)
             (call-with-recorded-s3 (octets rule)
                                    (lambda () (b:check-bucket-cors store "media" "https://app.example.com")))))
      (is (eq :allowed (verdict old-rule (test-s3-store))))
      (is (eq :header-not-allowed (verdict old-rule (test-s3-store :upload-acl :private))))
      (is (eq :allowed (verdict new-rule (test-s3-store :upload-acl :private)))))))

;;; === 14. follow-ups from the #772 review (#796) ===============================

(test start-multipart-upload-refuses-a-bad-content-type-before-any-request
  "The content type goes into the CreateMultipartUpload request's headers, so it gets the same
check as UPLOAD-URL's: no request is made for one that is empty or holds a control character."
  (dolist (bad (list (format nil "video/mp4~C~CX-Evil: 1" #\Return #\Linefeed)
                     (format nil "video/mp4~C" #\Tab) "" "  " :video))
    (multiple-value-bind (reason calls)
        (call-with-recorded-s3 ""
                               (lambda ()
                                 (handler-case
                                     (progn (b:start-multipart-upload (test-s3-store) "media" "big.mp4"
                                                                      :content-type bad)
                                            nil)
                                   (b:blob-upload-refused (c) (b:blob-upload-refused-reason c)))))
      (is (eq :bad-content-type reason) "~S" bad)
      (is (null calls) "no request was made for ~S" bad))))

;;; Presigned PUT vectors from botocore 1.35.99, AWS's own Python signer, with its clock pinned to
;;; 2013-05-24T00:00:00Z and AWS's documentation credentials. Generated in a python:3.12-slim
;;; container by patching botocore.auth.datetime.datetime.utcnow and calling
;;; S3SigV4QueryAuth(credentials, "s3", "us-east-1", expires=900).add_auth on an AWSRequest
;;; for PUT with Content-Type video/mp4, Content-Length 1234 and x-amz-acl private: the headers
;;; UPLOAD-URL's default signs. AWS publishes no PUT vector; these pin the PUT, path-style and
;;; session-token paths to an independent implementation (#796).

(defparameter +botocore-put-signatures+
  '((:virtual-host "458e4480ce3a901ad28655b98ef309a86746c9c1068b319187a6ea36ea88676a")
    (:path-style "53bdb0e487678243d2e84ab2a006748c3363a13e3a7fd37f45e2acaecb21e471")
    (:session-token "0c4143cef561c5460d2550ff74d9acaaa1c0e27cadcd117b1c5b43c19d40de8b"))
  "X-Amz-Signature for each botocore vector.")

(defun botocore-vector-url (&rest store-args)
  (b::%presigned-url (apply #'aws-example-store store-args) "examplebucket" "uploads/a.mp4" "PUT" 900
                     :headers '(("content-type" . "video/mp4") ("content-length" . "1234")
                                ("x-amz-acl" . "private"))
                     :universal-time +aws-example-time+))

(defun url-signature (url) (subseq url (+ (search "X-Amz-Signature=" url) 16)))

(test s3-presigned-put-matches-botocore
  (let ((url (botocore-vector-url)))
    (is (string= (second (assoc :virtual-host +botocore-put-signatures+)) (url-signature url)) "~A" url)
    (is (eql 0 (search "https://examplebucket.s3.amazonaws.com/uploads/a.mp4?" url)))
    (is (string= "content-length%3Bcontent-type%3Bhost%3Bx-amz-acl" (signed-headers-of url)))))

(test s3-presigned-put-path-style-matches-botocore
  (let ((url (botocore-vector-url :path-style t)))
    (is (string= (second (assoc :path-style +botocore-put-signatures+)) (url-signature url)) "~A" url)
    (is (eql 0 (search "https://s3.amazonaws.com/examplebucket/uploads/a.mp4?" url))
        "the bucket is in the path, not the host")))

(test s3-presigned-put-with-a-session-token-matches-botocore
  "The token is in the query and inside the signature. Its `/', `+' and `=' are percent-encoded
the way botocore encodes them, or the signatures would differ."
  (let ((url (botocore-vector-url :session-token "IQoJb3JpZ2luX2VjEXAMPLETOKEN/with+slash==")))
    (is (string= (second (assoc :session-token +botocore-put-signatures+)) (url-signature url)) "~A" url)
    (is (search "X-Amz-Security-Token=IQoJb3JpZ2luX2VjEXAMPLETOKEN%2Fwith%2Bslash%3D%3D&" url) "~A" url)))

(defun url-signature-from-auth (auth) (subseq auth (+ (search "Signature=" auth :from-end t) 10)))

(defun count-occurrences (needle haystack)
  (loop with start = 0 for pos = (search needle haystack :start2 start)
        while pos count t do (setf start (1+ pos))))

(test s3-range-header-is-signed
  "READ-BLOB-RANGE sends its Range as an extra header. %SIGNED-HEADERS signs every extra header, so
a proxy that rewrote the range would break the signature."
  (let* ((headers (b::%signed-headers (test-s3-store) "media" "a.flac" "GET"
                                      :extra-headers '(("range" . "bytes=0-3"))))
         (auth (cdr (assoc "Authorization" headers :test #'string=))))
    (is (search "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," auth) "~A" auth)
    (is (string/= (url-signature-from-auth auth)
                  (url-signature-from-auth
                   (cdr (assoc "Authorization"
                               (b::%signed-headers (test-s3-store) "media" "a.flac" "GET"
                                                   :extra-headers '(("range" . "bytes=0-4")))
                               :test #'string=))))
        "another range is another signature")))

(test s3-upload-url-log-line-holds-no-url-or-credential-material
  "The issue line is logged once, with the key, expiry, size and ACL setting, and nothing from the
URL: no query parameter, no credential scope, no access key id and no signature."
  (let* ((log (make-string-output-stream))
         (target (with-captured-log (log)
                   (b:upload-url (test-s3-store) "media" "uploads/a.mp4"
                                 :expires-in 900 :content-type "video/mp4" :content-length 1234)))
         (text (get-output-stream-string log))
         (url (b:upload-target-url target))
         (query (subseq url (1+ (position #\? url)))))
    (is (= 1 (count-occurrences "blob upload URL issued" text)) "~A" text)
    (is (search "upload-acl" text :test #'char-equal) "the store's ACL setting is logged: ~A" text)
    (is (not (search query text)))
    (is (not (search "?" (subseq text (search "blob upload URL issued" text)))) "no query string at all: ~A" text)
    (is (not (search (b::s3-access-key (test-s3-store)) text)) "no access key id: ~A" text)
    (is (not (search "aws4_request" text)) "no credential scope: ~A" text)
    (is (not (search (url-signature url) text)))
    (is (not (search "X-Amz-" text)))))

(test s3-error-body-is-read-bounded-and-closed
  "An error response's body is kept as DETAIL. A streamed one is read up to 64 KiB and closed, so
it does not hold the connection; anything else passes through (#796)."
  (is (equalp (octets "<Error/>") (b::%error-body (octets "<Error/>"))))
  (is (string= "<Error/>" (b::%error-body "<Error/>")) "a string body passes through as it is")
  (is (null (b::%error-body nil)))
  (let ((small (make-instance 'counting-octet-stream :data (octets "<Error><Code>InvalidRange</Code></Error>"))))
    (is (equalp (octets "<Error><Code>InvalidRange</Code></Error>") (b::%error-body small)))
    (is (not (open-stream-p small))))
  (let ((large (make-instance 'counting-octet-stream
                              :data (make-array 200000 :element-type '(unsigned-byte 8) :initial-element 32))))
    (is (= 65536 (length (b::%error-body large))))
    (is (= 65536 (counting-position large)) "read no further than the bound")
    (is (not (open-stream-p large)))))

(test s3-ranged-read-past-the-end-closes-the-error-stream
  "A ranged read past the end answers 416. With the body streamed, the error carries an open
stream; %S3-REQUEST closes it, and READ-BLOB-RANGE returns no bytes."
  (let ((original (fdefinition 'dex:request))
        (body (make-instance 'counting-octet-stream :data (octets "<Error><Code>InvalidRange</Code></Error>"))))
    (is (open-stream-p body) "precondition: the stub's body starts open")
    (unwind-protect
         (progn
           (setf (fdefinition 'dex:request)
                 (lambda (url &rest args)
                   (declare (ignore args))
                   (error 'dex:http-request-failed :body body :status 416 :headers (make-hash-table)
                                                   :uri url :method :get)))
           (is (equalp #() (b:read-blob-range (test-s3-store) "media" "a" :start 99 :length 4))))
      (setf (fdefinition 'dex:request) original))
    (is (not (open-stream-p body)) "the 416 body is closed")))

(defclass failing-octet-stream (sb-gray:fundamental-binary-input-stream) ()
  (:documentation "An octet input stream whose every read signals, standing in for a connection
that drops while an error response's body is being read."))

(defmethod stream-element-type ((s failing-octet-stream)) '(unsigned-byte 8))
(defmethod sb-gray:stream-read-sequence ((s failing-octet-stream) seq &optional start end)
  (declare (ignore seq start end))
  (error "connection reset"))

(test s3-unreadable-error-body-is-still-a-backend-error
  "%ERROR-BODY runs inside %S3-REQUEST's handler clause, which the sibling ERROR clause does not
cover. A body that fails to read must still surface as BLOB-BACKEND-ERROR with its status, not as
the stream's own error (#796)."
  (let ((body (make-instance 'failing-octet-stream)))
    (let ((detail (b::%error-body body)))
      (is (stringp detail))
      (is (search "could not be read" detail) "~A" detail))
    (is (not (open-stream-p body)) "and the stream is closed"))
  (let ((original (fdefinition 'dex:request)))
    (unwind-protect
         (progn
           (setf (fdefinition 'dex:request)
                 (lambda (url &rest args)
                   (declare (ignore args))
                   (error 'dex:http-request-failed :body (make-instance 'failing-octet-stream) :status 500
                                                   :headers (make-hash-table) :uri url :method :get)))
           (let ((c (handler-case (progn (b:read-blob-range (test-s3-store) "media" "a") nil)
                      (b:blob-backend-error (c) c)
                      (error (e) e))))
             (is (typep c 'b:blob-backend-error) "got ~S" (and c (type-of c)))
             (is (eql 500 (and (typep c 'b:blob-backend-error) (b:blob-backend-error-status c))))))
      (setf (fdefinition 'dex:request) original))))

;;; === 15. the S3 store keeps its checksum (#810) ===============================

(test s3-put-blob-stores-its-checksum-as-object-metadata
  "PUT-BLOB sends the SHA-256 it computed as x-amz-meta-sha256, which is where BLOB-METADATA reads
it. Before #810 it was sent only as the payload hash, and BLOB-METADATA returned NIL on S3."
  (with-temp-store (fs)
    (declare (ignore fs))
    (multiple-value-bind (meta calls)
        (call-with-recorded-s3 "" (lambda () (put-string (test-s3-store) "media" "a.txt" "hello"
                                                         :metadata '(("Owner" . "42")))))
      (let ((headers (getf (first calls) :extra-headers))
            (sum "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
        (is (string= sum (b:blob-meta-checksum meta)) "the SHA-256 of \"hello\"")
        (is (equal sum (cdr (assoc "x-amz-meta-sha256" headers :test #'string=))) "~S" headers)
        (is (equal sum (getf (first calls) :payload-hash)) "still the payload hash as well")
        (is (equal "42" (cdr (assoc "x-amz-meta-owner" headers :test #'string=)))
            "the app's own metadata is still sent")
        (is (= 1 (count "x-amz-meta-sha256" headers :key #'car :test #'string-equal)))))))

(test s3-blob-metadata-reports-the-stored-checksum
  (let ((headers (make-hash-table :test #'equal)))
    (setf (gethash "content-length" headers) "5"
          (gethash "x-amz-meta-sha256" headers) "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    (let ((original (fdefinition 'b::%s3-request)))
      (unwind-protect
           (progn (setf (fdefinition 'b::%s3-request)
                        (lambda (&rest args) (declare (ignore args)) (values "" 200 headers)))
                  (is (string= "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                               (b:blob-meta-checksum (b:blob-metadata (test-s3-store) "media" "a.txt")))))
        (setf (fdefinition 'b::%s3-request) original)))))

(defun metadata-refusal (store metadata)
  "The NAME of the BLOB-INVALID-METADATA that PUT-BLOB signals for METADATA, :NO-NAME when it
names none, or NIL when PUT-BLOB accepts it."
  (handler-case (progn (put-string store "media" "m.txt" "x" :metadata metadata) nil)
    (b:blob-invalid-metadata (c) (or (b:blob-invalid-metadata-name c) :no-name))))

(test put-blob-refuses-reserved-or-malformed-metadata-on-every-store
  "\"sha256\" is reserved for the checksum in any case, and names and values go into request headers
on S3. The refusal is in PUT-BLOB's :BEFORE method, so the filesystem store refuses the same input
(#810)."
  (with-temp-store (fs)
    (dolist (store (list fs (test-s3-store)))
      (call-with-recorded-s3
       ""
       (lambda ()
         (is (equal "sha256" (metadata-refusal store '(("sha256" . "abc")))) "~A" (b:store-name store))
         (is (equal "SHA256" (metadata-refusal store '(("SHA256" . "abc")))))
         (is (equal "Sha256" (metadata-refusal store '(("owner" . "1") ("Sha256" . "abc")))))
         (is (equal "" (metadata-refusal store '(("" . "x")))))
         (is (equal "a:b" (metadata-refusal store '(("a:b" . "x")))))
         (is (equal (format nil "a~Cb" #\Linefeed) (metadata-refusal store (list (cons (format nil "a~Cb" #\Linefeed) "x")))))
         (is (equal "owner" (metadata-refusal store (list (cons "owner" (format nil "1~C~CX-Evil: 2" #\Return #\Linefeed))))))
         (is (eq :no-name (metadata-refusal store '(("owner" . 42)))))
         (is (eq :no-name (metadata-refusal store '("owner"))))
         (is (equal "my owner" (metadata-refusal store '(("my owner" . "x")))) "a space is not a header token")
         (is (equal (format nil "propri~Ctaire" (code-char 233))
                    (metadata-refusal store (list (cons (format nil "propri~Ctaire" (code-char 233)) "x")))))
         (is (equal "owner" (metadata-refusal store (list (cons "owner" (format nil "Ren~C" (code-char 233))))))
             "a non-ASCII value")
         (is (equal "owner" (metadata-refusal store '(("Owner" . "1") ("owner" . "2"))))
             "two names that differ only in case are one header")
         (is (null (metadata-refusal store '(("owner" . "42") ("sha256-of-thumbnail" . "x"))))
             "the control: ordinary names, and one that only starts with sha256, are accepted")
         (is (null (metadata-refusal store '(("x-thumb.v2_a~b" . "A value, with spaces & symbols!"))))
             "every token character in a name, and any printable ASCII in a value"))))))

(test s3-blob-metadata-without-a-stored-checksum-reports-nil
  "An object stored before #810, or uploaded directly by a client, has no x-amz-meta-sha256.
BLOB-METADATA reports NIL for its checksum rather than signalling."
  (let ((headers (make-hash-table :test #'equal)))
    (setf (gethash "content-length" headers) "5" (gethash "content-type" headers) "text/plain")
    (let ((original (fdefinition 'b::%s3-request)))
      (unwind-protect
           (progn (setf (fdefinition 'b::%s3-request)
                        (lambda (&rest args) (declare (ignore args)) (values "" 200 headers)))
                  (let ((meta (b:blob-metadata (test-s3-store) "media" "old.txt")))
                    (is (null (b:blob-meta-checksum meta)))
                    (is (= 5 (b:blob-meta-size meta)) "the rest of the metadata is still read")))
        (setf (fdefinition 'b::%s3-request) original)))))

;;; === 16. XML numeric character references ======================================

(test s3-xml-decode-reads-numeric-references-in-one-pass
  "MinIO writes an ETag's quotes as &#34; (measured on MinIO 2025-04-22). Read without decoding
it, a part's ETag is not the ETag, and completing the upload fails with 400."
  (is (string= "\"abc\"" (b::%xml-decode "&#34;abc&#34;")))
  (is (string= "\"abc\"" (b::%xml-decode "&#x22;abc&#x22;")))
  (is (string= "<>\"'&" (b::%xml-decode "&lt;&gt;&quot;&apos;&amp;")))
  (is (string= "&#34;" (b::%xml-decode "&amp;#34;"))
      "one pass: an escaped reference is decoded once")
  (is (string= "a & b &unknown; &#zz;" (b::%xml-decode "a & b &unknown; &#zz;"))
      "anything else is kept")
  (is (string= "plain" (b::%xml-decode "plain"))))

(test s3-xml-decode-keeps-anything-that-is-not-exactly-a-reference
  "Only `#' and decimal digits, or `#x' and hex digits, between `&' and `;'. A sign, a space,
trailing junk, or no `;' near enough keeps the text as written, so a key that holds such text is
listed as it is (#813). Each case sits beside the control it differs from."
  (dolist (pair `(("&#34;" . "\"")
                  ("&#-1;" . "&#-1;") ("&#x-1;" . "&#x-1;") ("&#+34;" . "&#+34;")
                  ("&# 34;" . "&# 34;")
                  ("&#34abc;" . "&#34abc;") ("&#x22zz;" . "&#x22zz;")
                  ("&#34 abc; tail" . "&#34 abc; tail")
                  ("&#;" . "&#;") ("&#x;" . "&#x;")
                  ("&#x22;" . "\"") ("&#X22;" . "&#X22;") ("&#xAB;" . ,(string (code-char #xAB)))))
    (is (string= (cdr pair) (b::%xml-decode (car pair))) "~S" (car pair))))

(test s3-xml-decode-reads-only-ascii-digits
  "On SBCL DIGIT-CHAR-P and PARSE-INTEGER accept any Unicode decimal digit, so Arabic-Indic or
fullwidth digits for 3 and 4 would read as 34, a quote (#813). XML allows only ASCII digits, so
such text is kept as written. The ASCII form beside it is the control."
  (let ((arabic (format nil "&#~C~C;" (code-char #x0663) (code-char #x0664)))
        (fullwidth (format nil "&#~C~C;" (code-char #xFF13) (code-char #xFF14))))
    (is (string= arabic (b::%xml-decode arabic)))
    (is (string= fullwidth (b::%xml-decode fullwidth)))
    (is (string= "\"" (b::%xml-decode "&#34;")) "the control")))

(test s3-xml-decode-keeps-code-points-xml-does-not-allow
  "0 and the surrogates D800-DFFF are kept as written: XML allows neither, a surrogate has no
UTF-8 encoding, and a NUL in a key would break the request that names it (#813). The code points
on either side of the surrogate range are the controls."
  (dolist (kept '("&#0;" "&#x0;" "&#xD800;" "&#xDFFF;" "&#55296;" "&#x110000;"))
    (is (string= kept (b::%xml-decode kept)) "~S" kept))
  (is (equal (string (code-char #xD7FF)) (b::%xml-decode "&#xD7FF;")))
  (is (equal (string (code-char #xE000)) (b::%xml-decode "&#xE000;")))
  (is (equal (string (code-char 1)) (b::%xml-decode "&#1;"))))

(test s3-xml-decode-is-linear-in-ampersands-without-semicolons
  "The `;' is looked for only a few characters after each `&', so a long string of `&' with a `;'
at the very end decodes as written, without scanning to the end once per `&'."
  (let ((input (concatenate 'string (make-string 200000 :initial-element #\&) ";")))
    (is (string= input (b::%xml-decode input)))))

(test s3-list-multipart-parts-reads-minio-etags
  (is (equal '((1 "\"e1\"" 5242880))
             (call-with-recorded-s3
              (octets (concatenate 'string
                                   "<ListPartsResult><Part><PartNumber>1</PartNumber>"
                                   "<ETag>&#34;e1&#34;</ETag><Size>5242880</Size></Part>"
                                   "<IsTruncated>false</IsTruncated></ListPartsResult>"))
              (lambda () (b:list-multipart-parts (test-s3-store) "media" "big.bin" "u-1"))))))

;;; === 17. server-side copy and move (#804) ====================================

(defun header-table (&rest pairs)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (name value) on pairs by #'cddr do (setf (gethash name h) value))
    h))

(defparameter +copy-source-headers+
  (header-table "content-length" "10" "etag" "\"src-etag\"" "content-type" "text/plain"
                "x-amz-meta-sha256" "0123abcd" "x-amz-meta-owner" "42")
  "What a HEAD of the source answers in the copy tests.")

(defun call-with-scripted-s3 (answer fn)
  "Call FN with %S3-REQUEST answered by ANSWER, a function of (method key query) returning a list
(body status headers), or signalling. Returns (values result calls), each call a plist."
  (let ((original (fdefinition 'b::%s3-request))
        (calls '()))
    (unwind-protect
         (progn
           (setf (fdefinition 'b::%s3-request)
                 (lambda (store bucket key method &rest args)
                   (declare (ignore store))
                   (push (list* :bucket bucket :key key :method method args) calls)
                   (values-list (funcall answer method key (getf args :query)))))
           (values (funcall fn) (nreverse calls)))
      (setf (fdefinition 'b::%s3-request) original))))

(defun copy-answer (&key (put '("<CopyObjectResult><ETag>\"new\"</ETag></CopyObjectResult>" 200)))
  "An ANSWER for a single-part copy of src.txt: the source and destination HEADs, and PUT answering
PUT (a list, or a function to call)."
  (lambda (method key query)
    (declare (ignore query))
    (case method
      (:head (if (equal key "src.txt")
                 (list "" 200 +copy-source-headers+)
                 (list "" 200 (header-table "content-length" "10" "content-type" "text/plain"))))
      (:put (if (functionp put) (funcall put) put))
      (t (list "" 200 (header-table))))))

(defun extra (call name) (cdr (assoc name (getf call :extra-headers) :test #'string-equal)))
(defun calls-of (calls method) (remove method calls :key (lambda (c) (getf c :method)) :test-not #'eq))

(test s3-copy-source-is-percent-encoded-and-signed
  "x-amz-copy-source is /bucket/key with the key encoded as a canonical URI: a space, a plus, a
percent sign and non-ASCII are percent-encoded, a slash is kept. It is signed like every extra
header."
  (let ((key (format nil "a b+c/d%e/~C.txt" (code-char 233))))
    (is (string= "/media/a%20b%2Bc/d%25e/%C3%A9.txt" (b::%copy-source "media" key)))
    (let* ((headers (b::%signed-headers (test-s3-store) "media" "dst.txt" "PUT"
                                        :extra-headers (list (cons "x-amz-copy-source" (b::%copy-source "media" key)))))
           (auth (cdr (assoc "Authorization" headers :test #'string=))))
      (is (search "SignedHeaders=host;x-amz-content-sha256;x-amz-copy-source;x-amz-date," auth) "~A" auth))))

(test s3-copy-blob-keeps-the-source-metadata-with-the-copy-directive
  (multiple-value-bind (meta calls)
      (call-with-scripted-s3 (copy-answer)
                             (lambda () (b:copy-blob (test-s3-store) "media" "src.txt" "media" "dst.txt")))
    (is (equal '(:head :put :head) (mapcar (lambda (c) (getf c :method)) calls)) "HEAD source, copy, HEAD copy")
    (let ((put (first (calls-of calls :put))))
      (is (equal "dst.txt" (getf put :key)))
      (is (equal "/media/src.txt" (extra put "x-amz-copy-source")))
      (is (equal "\"src-etag\"" (extra put "x-amz-copy-source-if-match")) "conditional on the ETag read")
      (is (equal "COPY" (extra put "x-amz-metadata-directive")))
      (is (null (getf put :content-type)))
      (is (notany (lambda (h) (search "x-amz-meta-" (car h))) (getf put :extra-headers)) "COPY sends no metadata")
      (is (null (extra put "x-amz-acl")) "a default store sends no ACL"))
    (is (equal "dst.txt" (b:blob-meta-key meta)) "the destination's metadata is returned")))

(test s3-copy-blob-sends-the-acl-on-a-private-store
  (multiple-value-bind (meta calls)
      (call-with-scripted-s3 (copy-answer)
                             (lambda () (b:copy-blob (test-s3-store :upload-acl :private) "media" "src.txt" "media" "dst.txt")))
    (declare (ignore meta))
    (is (equal "private" (extra (first (calls-of calls :put)) "x-amz-acl")))))

(test s3-copy-blob-with-changes-replaces-and-keeps-the-checksum
  (multiple-value-bind (meta calls)
      (call-with-scripted-s3 (copy-answer)
                             (lambda () (b:copy-blob (test-s3-store) "media" "src.txt" "media" "dst.txt"
                                                     :content-type "video/mp4")))
    (declare (ignore meta))
    (let ((put (first (calls-of calls :put))))
      (is (equal "REPLACE" (extra put "x-amz-metadata-directive")))
      (is (equal "video/mp4" (getf put :content-type)))
      (is (equal "0123abcd" (extra put "x-amz-meta-sha256")) "the source's checksum is sent again")
      (is (equal "42" (extra put "x-amz-meta-owner")) "with only the type changed, the app's metadata is kept")))
  (multiple-value-bind (meta calls)
      (call-with-scripted-s3 (copy-answer)
                             (lambda () (b:copy-blob (test-s3-store) "media" "src.txt" "media" "dst.txt"
                                                     :metadata '(("stage" . "verified")))))
    (declare (ignore meta))
    (let ((put (first (calls-of calls :put))))
      (is (equal "REPLACE" (extra put "x-amz-metadata-directive")))
      (is (equal "text/plain" (getf put :content-type)) "the type is kept")
      (is (equal "verified" (extra put "x-amz-meta-stage")))
      (is (null (extra put "x-amz-meta-owner")) "METADATA replaces the app's metadata")
      (is (equal "0123abcd" (extra put "x-amz-meta-sha256")) "and the checksum is still kept"))))

(test copy-and-move-refuse-reserved-metadata-before-any-request
  (with-temp-store (fs)
    (dolist (store (list fs (test-s3-store)))
      (dolist (op (list #'b:copy-blob #'b:move-blob))
        (multiple-value-bind (result calls)
            (call-with-scripted-s3 (copy-answer)
                                   (lambda ()
                                     (handler-case (funcall op store "media" "src.txt" "media" "dst.txt"
                                                            :metadata '(("SHA256" . "forged")))
                                       (b:blob-invalid-metadata (c) (b:blob-invalid-metadata-name c)))))
          (is (equal "SHA256" result) "~A" (b:store-name store))
          (is (null calls) "no request was made"))))))

(test s3-copy-to-the-same-location
  "With no changes: the blob's metadata, from one HEAD and nothing else. With a change: a REPLACE
copy of the object onto itself."
  (multiple-value-bind (meta calls)
      (call-with-scripted-s3 (copy-answer)
                             (lambda () (b:copy-blob (test-s3-store) "media" "src.txt" "media" "src.txt")))
    (is (equal "src.txt" (b:blob-meta-key meta)))
    (is (equal '(:head) (mapcar (lambda (c) (getf c :method)) calls))))
  (multiple-value-bind (meta calls)
      (call-with-scripted-s3 (copy-answer)
                             (lambda () (b:copy-blob (test-s3-store) "media" "src.txt" "media" "src.txt"
                                                     :content-type "text/markdown")))
    (declare (ignore meta))
    (let ((put (first (calls-of calls :put))))
      (is (equal "src.txt" (getf put :key)))
      (is (equal "/media/src.txt" (extra put "x-amz-copy-source")))
      (is (equal "REPLACE" (extra put "x-amz-metadata-directive"))))))

(defun copy-failure (put)
  "The condition COPY-BLOB signals when the copy's PUT answers PUT, or NIL."
  (handler-case (progn (call-with-scripted-s3 (copy-answer :put put)
                                              (lambda () (b:copy-blob (test-s3-store) "media" "src.txt" "media" "dst.txt")))
                       nil)
    (error (c) c)))

(test s3-copy-blob-failures-are-typed
  (let ((c (copy-failure (lambda () (error 'b:blob-backend-error :bucket "media" :key "dst.txt" :status 412)))))
    (is (typep c 'b:blob-source-changed) "412 is the source changing: ~S" c)
    (is (typep c 'b:blob-backend-error) "and a backend error, so existing handlers catch it")
    (is (and (typep c 'b:blob-error) (equal "src.txt" (b:blob-error-key c))) "naming the source")
    (is (eql 412 (and (typep c 'b:blob-backend-error) (b:blob-backend-error-status c)))))
  (is (typep (copy-failure '("<Error><Code>PreconditionFailed</Code></Error>" 200)) 'b:blob-source-changed)
      "the same as a 200 with an <Error>")
  (let ((c (copy-failure '("<Error><Code>InternalError</Code></Error>" 200))))
    (is (and (typep c 'b:blob-backend-error) (not (typep c 'b:blob-source-changed))))
    (is (equal "InternalError" (and (typep c 'b:blob-backend-error) (b:blob-backend-error-detail c)))))
  (is (typep (copy-failure (lambda () (error 'b:blob-backend-error :bucket "media" :key "dst.txt" :status 501)))
             'b:blob-unsupported)
      "501 means the provider cannot copy, so the app falls back")
  (is (typep (copy-failure '("<CopyObjectResult/>" 200)) 'null) "the control: a copy that succeeds"))

(test s3-copy-blob-names-the-missing-object
  "A missing source is BLOB-NOT-FOUND naming it, before any copy is sent. A 404 on the copy itself
names the source if it has gone since, and otherwise the destination, whose bucket is missing."
  (multiple-value-bind (c calls)
      (call-with-scripted-s3 (lambda (method key query)
                               (declare (ignore method query))
                               (error 'b:blob-not-found :bucket "media" :key key))
                             (lambda ()
                               (handler-case (b:copy-blob (test-s3-store) "media" "src.txt" "media" "dst.txt")
                                 (b:blob-not-found (c) c))))
    (is (equal "src.txt" (b:blob-error-key c)))
    (is (equal '(:head) (mapcar (lambda (c) (getf c :method)) calls)) "no copy was sent"))
  (let ((heads 0))
    (flet ((answer (source-still-there)
             (lambda (method key query)
               (declare (ignore query))
               (case method
                 (:head (incf heads)
                  (if (or (= heads 1) source-still-there)
                      (list "" 200 +copy-source-headers+)
                      (error 'b:blob-not-found :bucket "media" :key key)))
                 (:put (error 'b:blob-not-found :bucket "other" :key "dst.txt"))))))
      (is (equal "src.txt" (b:blob-error-key (handler-case (call-with-scripted-s3 (answer nil) (lambda () (b:copy-blob (test-s3-store) "media" "src.txt" "other" "dst.txt")))
                                                (b:blob-not-found (c) c)))))
      (setf heads 0)
      (is (equal "dst.txt" (b:blob-error-key (handler-case (call-with-scripted-s3 (answer t) (lambda () (b:copy-blob (test-s3-store) "media" "src.txt" "other" "dst.txt")))
                                                (b:blob-not-found (c) c))))))))

(test s3-copy-part-ranges-cover-the-object
  (is (equal '((0 . 3) (4 . 7) (8 . 9)) (b::%copy-part-ranges 10 4)))
  (let* ((size (* 12 1024 1024 1024)) (ranges (b::%copy-part-ranges size (* 512 1024 1024))))
    (is (= 24 (length ranges)))
    (is (= 0 (car (first ranges))))
    (is (= (1- size) (cdr (car (last ranges)))))
    (is (loop for (a b) on ranges while b always (= (1+ (cdr a)) (car b))) "contiguous"))
  (let ((ranges (b::%copy-part-ranges (* 5 1024 1024 1024 1024) (* 512 1024 1024))))
    (is (<= (length ranges) 10000) "a 5 TiB object needs no more than 10000 parts: ~D" (length ranges))))

(defun multipart-copy-answer (&key fail-part)
  (lambda (method key query)
    (cond ((eq method :head)
           (list "" 200 (if (equal key "src.txt") +copy-source-headers+ (header-table "content-length" "10"))))
          ((and (eq method :post) (equal query "uploads="))
           (list "<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>" 200))
          ((eq method :put)
           (let ((n (parse-integer (subseq query (+ (search "partNumber=" query) 11)) :junk-allowed t)))
             (if (eql n fail-part)
                 (error 'b:blob-backend-error :bucket "media" :key key :status 500)
                 (list (format nil "<CopyPartResult><ETag>&quot;e~D&quot;</ETag></CopyPartResult>" n) 200))))
          ((eq method :post) (list "<CompleteMultipartUploadResult/>" 200))
          ((eq method :delete) (list "" 204))
          (t (error "unexpected ~S" method)))))

(test s3-copy-blob-above-the-threshold-copies-in-parts
  (let ((b::*%copy-multipart-threshold* 5) (b::*%copy-part-size* 4))
    (multiple-value-bind (meta calls)
        (call-with-scripted-s3 (multipart-copy-answer)
                               (lambda () (b:copy-blob (test-s3-store) "media" "src.txt" "media" "dst.txt")))
      (declare (ignore meta))
      (let ((create (find "uploads=" calls :key (lambda (c) (getf c :query)) :test #'equal))
            (parts (calls-of calls :put))
            (complete (find-if (lambda (c) (and (eq :post (getf c :method)) (search "uploadId" (or (getf c :query) "")))) calls)))
        (is (equal "text/plain" (getf create :content-type)))
        (is (equal "0123abcd" (extra create "x-amz-meta-sha256")) "the checksum is set on the new object")
        (is (equal "42" (extra create "x-amz-meta-owner")))
        (is (equal '("bytes=0-3" "bytes=4-7" "bytes=8-9") (mapcar (lambda (c) (extra c "x-amz-copy-source-range")) parts)))
        (is (every (lambda (c) (equal "\"src-etag\"" (extra c "x-amz-copy-source-if-match"))) parts)
            "every part is conditional on the same source ETag")
        (is (every (lambda (c) (search "uploadId=u-1" (getf c :query))) parts))
        (is (search "<Part><PartNumber>3</PartNumber><ETag>&quot;e3&quot;</ETag></Part>"
                    (sb-ext:octets-to-string (getf complete :content) :external-format :utf-8))
            "completed with the ETags the parts returned")
        (is (null (calls-of calls :delete)) "nothing aborted")))))

(test s3-multipart-copy-aborts-when-a-part-fails
  "A part that fails leaves no upload behind to be billed: the copy aborts it, then signals."
  (let ((b::*%copy-multipart-threshold* 5) (b::*%copy-part-size* 4) (calls '()))
    (is (typep (handler-case
                   (progn (call-with-scripted-s3 (let ((answer (multipart-copy-answer :fail-part 2)))
                                                   (lambda (method key query)
                                                     (push (list :method method :query query) calls)
                                                     (funcall answer method key query)))
                                                 (lambda () (b:copy-blob (test-s3-store) "media" "src.txt" "media" "dst.txt")))
                          nil)
                 (b:blob-backend-error (c) c))
               'b:blob-backend-error))
    (let ((delete (find :delete calls :key (lambda (c) (getf c :method)))))
      (is (not (null delete)) "the upload was aborted")
      (is (search "uploadId=u-1" (or (getf delete :query) ""))))
    (is (notany (lambda (c) (and (eq :post (getf c :method)) (search "uploadId" (or (getf c :query) "")))) calls)
        "and never completed")))

(test s3-move-blob-copies-then-deletes-the-source
  (multiple-value-bind (meta calls)
      (call-with-scripted-s3 (copy-answer)
                             (lambda () (b:move-blob (test-s3-store) "media" "src.txt" "media" "dst.txt")))
    (is (equal "dst.txt" (b:blob-meta-key meta)))
    (is (equal '(:head :put :head :delete) (mapcar (lambda (c) (getf c :method)) calls)))
    (is (equal "src.txt" (getf (car (last calls)) :key)) "the source is deleted, last"))
  (multiple-value-bind (meta calls)
      (call-with-scripted-s3 (copy-answer)
                             (lambda () (b:move-blob (test-s3-store) "media" "src.txt" "media" "src.txt")))
    (declare (ignore meta))
    (is (null (calls-of calls :delete)) "a move to the same location deletes nothing"))
  (multiple-value-bind (c calls)
      (call-with-scripted-s3 (let ((copy (copy-answer)))
                               (lambda (method key query)
                                 (if (eq method :delete)
                                     (error 'b:blob-backend-error :bucket "media" :key key :status 503)
                                     (funcall copy method key query))))
                             (lambda () (handler-case (b:move-blob (test-s3-store) "media" "src.txt" "media" "dst.txt")
                                          (b:blob-backend-error (c) c))))
    (is (and (typep c 'b:blob-backend-error) (equal "src.txt" (b:blob-error-key c)) (eql 503 (b:blob-backend-error-status c)))
        "a failed delete signals its own condition, naming the source")
    (is (calls-of calls :put) "and the copy had been made")))

(test filesystem-copy-blob-copies-bytes-type-metadata-and-checksum
  (with-temp-store (store)
    (let ((src (put-string store "media" "quarantine/a.txt" "hello" :content-type "text/plain"
                           :metadata '(("owner" . "42")))))
      (let ((copy (b:copy-blob store "media" "quarantine/a.txt" "final" "a.txt")))
        (is (string= "hello" (get-string store "final" "a.txt")))
        (is (string= "text/plain" (b:blob-meta-content-type copy)))
        (is (string= (b:blob-meta-checksum src) (b:blob-meta-checksum copy)) "the checksum of the same bytes")
        (is (equal '(("owner" . "42")) (b::%read-user-metadata (b::%blob-path store "final" "a.txt" "meta"))))
        (is (string= "hello" (get-string store "media" "quarantine/a.txt")) "the source is untouched"))
      (let ((copy (b:copy-blob store "media" "quarantine/a.txt" "final" "b.txt"
                               :content-type "text/markdown" :metadata '(("stage" . "verified")))))
        (is (string= "text/markdown" (b:blob-meta-content-type copy)))
        (is (equal '(("stage" . "verified")) (b::%read-user-metadata (b::%blob-path store "final" "b.txt" "meta"))))))
    (handler-case (progn (b:copy-blob store "media" "missing.txt" "final" "c.txt") (is nil "no condition"))
      (b:blob-not-found (c) (is (equal "missing.txt" (b:blob-error-key c)) "names the source")))
    (is (not (b:blob-exists-p store "final" "c.txt")))))

(test filesystem-copy-blob-to-the-same-location
  (with-temp-store (store)
    (put-string store "media" "a.txt" "hello" :content-type "text/plain")
    (let ((before (b:blob-metadata store "media" "a.txt")))
      (is (equalp before (b:copy-blob store "media" "a.txt" "media" "a.txt")) "no change, nothing written")
      (let ((after (b:copy-blob store "media" "a.txt" "media" "a.txt" :content-type "text/markdown")))
        (is (string= "text/markdown" (b:blob-meta-content-type after)))
        (is (string= (b:blob-meta-checksum before) (b:blob-meta-checksum after)))
        (is (string= "hello" (get-string store "media" "a.txt")))))))

(test filesystem-move-blob-renames-and-keeps-metadata
  (with-temp-store (store)
    (let ((src (put-string store "media" "quarantine/a.txt" "hello" :content-type "text/plain"
                           :metadata '(("owner" . "42")))))
      (let ((moved (b:move-blob store "media" "quarantine/a.txt" "final" "a.txt")))
        (is (string= "hello" (get-string store "final" "a.txt")))
        (is (string= (b:blob-meta-checksum src) (b:blob-meta-checksum moved)))
        (is (string= "text/plain" (b:blob-meta-content-type moved)))
        (is (equal '(("owner" . "42")) (b::%read-user-metadata (b::%blob-path store "final" "a.txt" "meta"))))
        (is (not (b:blob-exists-p store "media" "quarantine/a.txt")) "the source is gone")
        (is (not (probe-file (b::%blob-path store "media" "quarantine/a.txt" "meta"))) "and so is its sidecar")))
    (put-string store "media" "same.txt" "x")
    (b:move-blob store "media" "same.txt" "media" "same.txt")
    (is (string= "x" (get-string store "media" "same.txt")) "a move to the same location deletes nothing")
    (signals b:blob-not-found (b:move-blob store "media" "missing.txt" "final" "m.txt"))))

(test a-store-without-copy-signals-unsupported-for-copy-and-move
  "The default methods: an app's own store class gets BLOB-UNSUPPORTED, so it can fall back to
GET-BLOB and PUT-BLOB, and a move deletes nothing."
  (with-temp-store (inner)
    (put-string inner "media" "a.txt" "x")
    (let ((store (make-instance 'get-only-store :inner inner)))
      (signals b:blob-unsupported (b:copy-blob store "media" "a.txt" "media" "b.txt"))
      (signals b:blob-unsupported (b:move-blob store "media" "a.txt" "media" "b.txt"))
      (is (b:blob-exists-p inner "media" "a.txt") "the move deleted nothing"))))
