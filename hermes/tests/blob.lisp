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
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

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
at its source, rather than one call site at a time (#186)."
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
                       :secret-key "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"))))

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
