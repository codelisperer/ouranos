;;;; update-client-tests.lisp --- the effectful half, against real signatures (pre-publication issue 76).
;;;;
;;;; WHY THIS SUITE EXISTS AT ALL. `AGENTS.md': a system that exports a surface must have a
;;;; suite that exercises it, and twice now a reusable piece has shipped exported,
;;;; documented and reused with zero coverage because the ENCLOSING system was green. The
;;;; typed core's 109 checks say nothing whatever about whether `check-for-update' calls it
;;;; correctly, or in the right order.
;;;;
;;;; THE ORDERING TEST IS THE ONE THAT MATTERS. `verification-precedes-interpretation'
;;;; hands the client a manifest that is BOTH unreadable-schema AND badly signed, and
;;;; asserts it reports the signature failure. If the schema gate ever runs first, that
;;;; test goes red -- and nothing else in this file would notice, because every other case
;;;; has a valid signature and would behave identically either way. The whole
;;;; denial-of-update argument rests on an ordering that exactly one test can see.
;;;;
;;;; REAL KEYS, REAL SIGNATURES, NO NETWORK. `aion/signature' generates a keypair per run
;;;; and the fake source serves bytes from memory. Nothing here stubs verification, because
;;;; a suite that stubs the check it exists to prove is the shape of defect this tree keeps
;;;; finding.

(cl:defpackage #:hyperion/update/client-tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:up #:hyperion/update)
                    (#:sig #:aion/signature)
                    (#:platform #:aion/platform)
                    (#:base64 #:cl-base64))
  (:export #:run-tests))

(in-package #:hyperion/update/client-tests)

(def-suite hyperion-update-client
  :description "The updater's effectful half: fetch, verify, interpret."
  :in hyperion/update/tests::hyperion-update)

(defun run-tests () (run! 'hyperion-update-client))

(in-suite hyperion-update-client)

;;; --- a source that serves bytes from memory --------------------------------

(defclass fixed-source ()
  ((body :initarg :body :reader source-body)
   (signature :initarg :signature :reader source-signature)
   (artifacts :initarg :artifacts :initform (make-hash-table :test #'equal)
              :reader source-artifacts))
  (:documentation
   "Serves one manifest, its signature, and any artifacts, all as bytes from memory."))

(defmethod up:fetch-manifest ((source fixed-source) channel)
  (declare (ignore channel))
  (values (source-body source) (source-signature source)))

(defmethod up:fetch-artifact ((source fixed-source) url)
  (let ((bytes (gethash url (source-artifacts source))))
    (or bytes
        (error 'up:update-source-error :detail (format nil "no artifact at ~A" url)))))

(defclass broken-source () ()
  (:documentation "A source that cannot be reached, for the fallback test."))

(defmethod up:fetch-manifest ((source broken-source) channel)
  (declare (ignore channel))
  (error 'up:update-source-error :detail "host is down"))

;;; --- fixtures ---------------------------------------------------------------

(defvar *private-key* nil)
(defvar *public-text* nil)

(defun ensure-keys ()
  (unless *private-key*
    (multiple-value-bind (private public) (sig:generate-key-pair)
      (setf *private-key* private
            *public-text* (sig:encode-key public))))
  (values *private-key* *public-text*))

(defun utf8 (string) (sb-ext:string-to-octets string :external-format :utf-8))

(defun detached-signature (private bytes)
  "The signature over BYTES *as a source actually serves it*: base64 text, trailing newline.

EXACTLY WHAT `scripts/update-manifest.lisp's SIGN-FILE writes, and the reason this exists
instead of a bare `sig:sign'. Serving raw 64 bytes from memory made every test in this file
satisfy a precondition no real source satisfies, and hid a client that refused every release
the tree's own generator can produce -- an 89-byte base64 line handed to a verifier that
requires exactly 64 bytes. A fixture easier than reality is not a fixture."
  (utf8 (format nil "~A~%" (base64:usb8-array-to-base64-string (sig:sign private bytes)))))

(defun manifest-json (&key (schema 1) (product "testapp") (channel "stable")
                           (version "2.0.0") (published "2026-06-01T00:00:00Z")
                           (minimum nil) (platform-key (platform:platform-key))
                           (payload-url "https://example.test/app-2.0.0-setup.exe")
                           (installer "same") (format-name "nsis"))
  "A manifest in the shape section 3 specifies. PLATFORM-KEY defaults to this host's, so
the artifact lookup is the real one rather than a hard-coded guess."
  (with-output-to-string (s)
    (format s "{~%  \"schema\": ~D,~%" schema)
    (format s "  \"product\": ~S,~%" product)
    (format s "  \"channel\": ~S,~%" channel)
    (format s "  \"version\": ~S,~%" version)
    (when published (format s "  \"published\": ~S,~%" published))
    (when minimum (format s "  \"minimum_version\": ~S,~%" minimum))
    (format s "  \"platforms\": {~%")
    (when platform-key
      (format s "    ~S: { \"format\": ~S, \"payload\": { \"url\": ~S }, \"installer\": ~S }~%"
              platform-key format-name payload-url installer))
    (format s "  }~%}~%")))

(defun signed-source (json)
  "A source serving JSON with a VALID signature over its exact bytes."
  (multiple-value-bind (private public-text) (ensure-keys)
    (declare (ignore public-text))
    (let ((bytes (utf8 json)))
      (make-instance 'fixed-source :body bytes :signature (detached-signature private bytes)))))

(defmacro with-client ((&key (installed "1.0.0") (installed-published nil)) &body body)
  "Run BODY with a build that knows what it is and carries the test's public key."
  `(multiple-value-bind (private public-text) (ensure-keys)
     (declare (ignore private))
     (let ((up:*installed-version* ,installed)
           (up:*installed-published* ,installed-published)
           (up:*public-key* public-text)
           (up:*download-url* "https://permanent.test/App-Setup.exe")
           (up:*update-source* (make-instance 'up:null-source)))
       ,@body)))

(defun status-of (source &key (channel "stable") (product "testapp") (installed "1.0.0")
                              (installed-published nil))
  (with-client (:installed installed :installed-published installed-published)
    (up:check-for-update :source source :channel channel :product product)))

(defun field (status key) (getf status key))

;;; --- the default source -----------------------------------------------------

(test the-default-source-answers-honestly-rather-than-pretending
  ;; A working-tree build has no channel, and "nothing to offer" is the TRUE answer. This
  ;; is also what keeps the no-update path exercised daily, so the banner's absence is a
  ;; tested state rather than an assumption.
  (with-client ()
    (let ((status (up:check-for-update :source (make-instance 'up:null-source))))
      (is (string= "up-to-date" (field status :status))))))

(test before-any-check-the-status-is-unchecked-not-up-to-date
  ;; "Up to date" is a claim; before a check nothing has established it.
  (let ((up::*update-state* nil))
    (is (string= "unchecked" (field (up:update-status) :status)))))

;;; --- verification -----------------------------------------------------------

(test a-validly-signed-newer-manifest-is-offered
  (let ((status (status-of (signed-source (manifest-json :version "2.0.0")))))
    (is (string= "available" (field status :status)))
    (is (string= "2.0.0" (field status :version)))))

(test a-tampered-manifest-is-refused
  ;; The signature is over exact bytes, so changing one character must break it. Without
  ;; this the whole module is decoration.
  (multiple-value-bind (private public-text) (ensure-keys)
    (declare (ignore public-text))
    (let* ((json (manifest-json :version "2.0.0"))
           (bytes (utf8 json))
           (signature (detached-signature private bytes))
           (tampered (utf8 (manifest-json :version "9.9.9")))
           (source (make-instance 'fixed-source :body tampered :signature signature)))
      (let ((status (status-of source)))
        (is (string= "blocked" (field status :status)))
        (is (string= "bad-signature" (field status :block)))))))

(test an-unsigned-manifest-is-refused-rather-than-merely-noted
  ;; Exactly what an attacker able to serve us bytes would produce. Fail closed.
  (let* ((source (make-instance 'fixed-source :body (utf8 (manifest-json)) :signature nil))
         (status (status-of source)))
    (is (string= "blocked" (field status :status)))
    (is (string= "bad-signature" (field status :block)))))

(test a-build-with-no-key-refuses-instead-of-skipping-verification
  ;; No key means NO updates, never unverified ones. A deployment mistake must not read as
  ;; permission to install anything.
  (let ((up:*installed-version* "1.0.0")
        (up:*public-key* nil))
    (let ((status (up:check-for-update :source (signed-source (manifest-json)))))
      (is (string= "unreachable" (field status :status)))
      (is (search "signing key" (field status :detail))))))

(test verification-precedes-interpretation
  ;; THE ORDERING TEST. This manifest is BOTH unreadable (schema 99) and badly signed. If
  ;; verification runs first -- as it must -- the answer is bad-signature. If the schema
  ;; gate ran first, the answer would be unsupported-schema, and an attacker able to serve
  ;; bytes could stop this client updating with garbage it never had to sign.
  ;;
  ;; Nothing else in this file can see that ordering: every other case is validly signed
  ;; and behaves identically whichever order runs.
  (let* ((source (make-instance 'fixed-source
                                :body (utf8 (manifest-json :schema 99))
                                :signature (utf8 "not a signature at all")))
         (status (status-of source)))
    (is (string= "bad-signature" (field status :block))
        "expected the signature failure to be reported before the schema was read, got ~S"
        (field status :block))))

;;; --- interpretation, all of it after verification ---------------------------

(test a-schema-from-the-future-is-refused-calmly-and-links-the-installer
  (let ((status (status-of (signed-source (manifest-json :schema 99)))))
    (is (string= "unsupported-schema" (field status :block)))
    (is (search "99" (field status :detail)))
    ;; The escape hatch: the one failure an updater cannot fix by updating.
    (is (search "https://permanent.test/" (field status :detail)))))

(test the-schema-refusal-does-not-read-the-manifest-it-just-refused
  ;; A build cannot coherently say "I do not understand this document" and then read a
  ;; field out of it. In a schema this build does not know, `installer' may not be a URL,
  ;; may not be at that path, or may not mean what this build assumes.
  ;;
  ;; This manifest is schema 99 AND carries a per-release installer URL. The refusal must
  ;; quote the PERMANENT link this build was configured with and must not have gone
  ;; looking in the manifest for one.
  (let ((status (status-of (signed-source
                            (manifest-json :schema 99
                                           :payload-url "https://from-the-manifest.test/x.exe")))))
    (is (string= "unsupported-schema" (field status :block)))
    (is (search "https://permanent.test/" (field status :detail)))
    (is (not (search "from-the-manifest.test" (field status :detail)))
        "the schema refusal read a URL out of the manifest whose schema it cannot read")))

(test the-schema-refusal-still-says-something-with-no-download-url
  ;; An application need not configure a permanent link. The schema number must still be
  ;; reported, because "you cannot update, and here is why" beats silence even without
  ;; somewhere to click.
  (multiple-value-bind (private public-text) (ensure-keys)
    (declare (ignore private))
    (let ((up:*installed-version* "1.0.0")
          (up:*public-key* public-text)
          (up:*download-url* nil))
      (let ((status (up:check-for-update :source (signed-source (manifest-json :schema 99))
                                         :product "testapp")))
        (is (string= "unsupported-schema" (field status :block)))
        (is (search "99" (field status :detail)))))))

(test a-manifest-for-another-product-is-a-substitution
  ;; Correctly signed and still not addressed to us.
  (let ((status (status-of (signed-source (manifest-json :product "someone-elses-app")))))
    (is (string= "manifest-mismatch" (field status :block)))))

(test a-manifest-for-another-channel-is-a-substitution
  (let ((status (status-of (signed-source (manifest-json :channel "beta"))
                           :channel "stable")))
    (is (string= "manifest-mismatch" (field status :block)))))

(test a-version-that-is-not-one-is-a-release-process-bug-not-an-attack
  (let ((status (status-of (signed-source (manifest-json :version "not-a-version")))))
    (is (string= "malformed-manifest" (field status :block)))))

(test a-malformed-timestamp-does-not-inherit-the-fail-open-that-absence-gets
  ;; Absence is tolerated by design. A present-but-unreadable value must NOT be passed
  ;; through as absence, or mangling the field does what stripping it cannot.
  (let ((status (status-of (signed-source
                            (manifest-json :published "2026-06-01T00:00:00.500Z")))))
    (is (string= "malformed-manifest" (field status :block)))
    (is (search "YYYY-MM-DDTHH:MM:SSZ" (field status :detail)))))

(test an-absent-timestamp-is-tolerated
  (let ((status (status-of (signed-source (manifest-json :published nil)))))
    (is (string= "available" (field status :status)))))

(test no-artifact-for-this-platform-is-its-own-state
  ;; The pre-publication issue 206 shape: a client that cannot find its own row must not report itself current.
  (let ((status (status-of (signed-source (manifest-json :platform-key nil)))))
    (is (string= "no-artifact" (field status :status)))))

(test a-newer-version-published-earlier-is-refused
  ;; Anti-rollback's second half, end to end through a real signature.
  (let ((status (status-of (signed-source (manifest-json :version "2.0.0"
                                                         :published "2026-01-01T00:00:00Z"))
                           :installed-published "2026-06-01T00:00:00Z")))
    (is (string= "stale-manifest" (field status :block)))))

(test below-the-minimum-version-a-reinstall-is-demanded-with-a-link
  (let ((status (status-of (signed-source (manifest-json :version "3.0.0"
                                                         :minimum "2.0.0"))
                           :installed "1.0.0")))
    (is (string= "needs-reinstall" (field status :block)))
    (is (search "https://example.test/" (field status :detail)))))

(test a-build-that-does-not-know-its-version-blocks-rather-than-assuming-current
  (let ((status (status-of (signed-source (manifest-json)) :installed nil)))
    (is (string= "unknown-version" (field status :block)))))

;;; --- sources ----------------------------------------------------------------

(test a-list-of-sources-is-tried-in-order
  ;; Design section 5: a useful fallback when one host is down.
  (let ((status (status-of (list (make-instance 'broken-source)
                                 (signed-source (manifest-json :version "2.0.0"))))))
    (is (string= "available" (field status :status)))
    (is (string= "2.0.0" (field status :version)))))

(test when-every-source-is-down-the-report-is-quiet
  ;; A failed check is background noise. The network is down; the user is on a plane.
  (let ((status (status-of (list (make-instance 'broken-source)
                                 (make-instance 'broken-source)))))
    (is (string= "unreachable" (field status :status)))
    (is (string= "" (field status :block)))))

(test the-check-never-signals
  ;; An updater must not be able to take an application down by failing.
  (finishes (status-of (make-instance 'broken-source)))
  (finishes (status-of (make-instance 'fixed-source :body (utf8 "{not json")
                                                    :signature nil))))


;;; --- the directory backend (pre-publication issue 77) --------------------------------------------
;;;
;;; It exists so a release can be checked BY THE CLIENT before it is uploaded --
;;; `scripts/verify-release-as-client.lisp'. That gate is worth nothing if this backend
;;; disagrees with the HTTP one about where things live, because then it would agree with a
;;; producer the real client disagrees with: the failure it exists to detect, reproduced
;;; inside the detector. So the file NAMES are what these tests are about.

(defun write-bytes-to (path bytes)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :element-type '(unsigned-byte 8)
                          :if-exists :supersede)
    (write-sequence bytes s))
  path)

(defmacro with-published-directory ((var &key (channel "stable") (version "2.0.0")
                                          (payload-url "https://example.test/app-2.0.0-setup.exe")
                                          (write-payload t))
                                    &body body)
  "A directory holding a signed manifest and its payload, laid out as a real dist/ is."
  `(let ((,var (merge-pathnames (format nil "ouranos-dist-test-~D/" (random 100000))
                                (uiop:temporary-directory))))
     (ensure-directories-exist ,var)
     (unwind-protect
          (multiple-value-bind (private public-text) (ensure-keys)
            (let* ((json (manifest-json :version ,version :channel ,channel
                                        :payload-url ,payload-url))
                   (bytes (utf8 json))
                   (payload (payload-bytes))
                   (name (subseq ,payload-url (1+ (position #\/ ,payload-url :from-end t)))))
              (write-bytes-to (merge-pathnames (format nil "~A.json" ,channel) ,var) bytes)
              (write-bytes-to (merge-pathnames (format nil "~A.json.sig" ,channel) ,var)
                              (detached-signature private bytes))
              (when ,write-payload
                (write-bytes-to (merge-pathnames name ,var) payload)
                (write-bytes-to (merge-pathnames (format nil "~A.sig" name) ,var)
                                (detached-signature private payload)))
              (let ((up:*public-key* public-text)
                    (up:*installed-version* "1.0.0")
                    (up:*installed-published* nil))
                ,@body)))
       (ignore-errors (uiop:delete-directory-tree ,var :validate t)))))

(test a-published-directory-reads-exactly-as-a-served-one-does
  (with-published-directory (dist)
    (let ((status (up:check-for-update :source (make-instance 'up:directory-source :path dist)
                                       :product "testapp")))
      (is (string= "available" (getf status :status))
          "the client could not read a directory it will be asked to read before every release")
      (is (string= "2.0.0" (getf status :version))))))

(test the-channel-names-the-file-and-nothing-else-does
  ;; THE ONE THAT MATTERS. `<channel>.json' is what the HTTP backend asks a host for, and
  ;; the generator wrote `latest.json' until pre-publication issue 77 -- one document, two names, in two files
  ;; that cannot see each other. If this backend ever accepted some other name, the gate
  ;; would pass a release the real client cannot find, which is worse than no gate.
  (with-published-directory (dist :channel "beta")
    (let ((source (make-instance 'up:directory-source :path dist)))
      (is (string= "available"
                   (getf (up:check-for-update :source source :channel "beta" :product "testapp")
                         :status)))
      ;; And the same directory says nothing at all about a channel it does not carry --
      ;; quietly, because an unpublished channel is an answer and not a failure.
      (let ((status (up:check-for-update :source source :channel "stable" :product "testapp")))
        (is (string= "up-to-date" (getf status :status))
            "a channel with no manifest should be quiet, not an error")))))

(test an-artifact-is-found-by-the-name-the-url-would-have-served-it-as
  (with-published-directory (dist)
    (let* ((source (make-instance 'up:directory-source :path dist))
           (bytes (up:fetch-artifact source "https://example.test/app-2.0.0-setup.exe")))
      (is (equalp (payload-bytes) bytes))
      ;; A path with more segments resolves to the same file: only the last segment can
      ;; mean anything on disk, and the manifest's URLs are absolute for the real host.
      (is (equalp (payload-bytes)
                  (up:fetch-artifact source "https://cdn.example.test/v/2/app-2.0.0-setup.exe"))))))

(test a-manifest-that-names-a-payload-the-directory-does-not-hold-fails-loudly
  ;; The release-process bug this backend is for: a manifest published without its
  ;; artifact. It must not be a quiet "nothing for you" -- the manifest says there IS
  ;; something, and the file is missing.
  (with-published-directory (dist :write-payload nil)
    (let ((source (make-instance 'up:directory-source :path dist)))
      (handler-case
          (progn (up:fetch-artifact source "https://example.test/app-2.0.0-setup.exe")
                 (fail "a missing artifact was not reported"))
        (up:update-source-error (e)
          (is (search "app-2.0.0-setup.exe" (up:update-source-error-detail e))
              "the error should name the file that was missing"))))))

;;; --- the shape of a `.sig' on the wire -------------------------------------
;;;
;;; The contract this file previously stated wrongly in both halves at once. Everything
;;; above serves signatures the way a REAL source serves them because of this test.

(test a-signature-in-the-form-the-generator-writes-is-the-form-the-client-accepts
  ;; `scripts/update-manifest.lisp' writes `<artifact>.sig' as base64 text with a trailing
  ;; newline, and reads it back the same way. The client fetches those exact bytes. Until
  ;; this test existed they went straight to a verifier that requires 64 RAW bytes, so an
  ;; 89-byte base64 line failed -- every time, for every artifact, on every machine. The
  ;; consequence is pre-publication issue 206's: every installed client refuses every real release, silently
  ;; and permanently, and a refused update against a security fix IS the attack.
  ;;
  ;; It was invisible because every fixture in this file served raw bytes from memory. A
  ;; suite that always satisfies a precondition cannot test the absence of that
  ;; precondition, and no test here had ever read a `.sig' the generator wrote.
  (multiple-value-bind (private public-text) (ensure-keys)
    (let ((up:*public-key* public-text)
          (payload (sb-ext:string-to-octets "MZ pretend installer")))
      (is-true (up::%verified-p payload (detached-signature private payload))
               "the client refused a signature written the way the generator writes one")
      ;; It is really verifying, not merely decoding: the same encoding over other bytes
      ;; is refused. Without this line a client that accepted anything base64 would pass.
      (is-false (up::%verified-p payload
                                 (detached-signature private (sb-ext:string-to-octets "other")))
                "a signature over different bytes was accepted")
      ;; And the ENCODING is what is being asserted, not merely that something verified:
      ;; the identical signature in the other form is refused. One named format, decided
      ;; here and in the generator, rather than a client that takes whatever arrives --
      ;; the same reasoning `%format-keyword' applies to packaging.
      (is-false (up::%verified-p payload (sig:sign private payload))
                "raw 64 bytes were accepted, so the .sig encoding is not being decoded")
      (is-false (up::%verified-p payload (utf8 "not base64 at all !!!"))
                "rubbish in a .sig must be a verification failure, not an error")
      (is-false (up::%verified-p payload nil)))))

;;; --- applying ---------------------------------------------------------------
;;;
;;; WHAT THESE PROVE AND WHAT THEY DO NOT. `*launch-installer*' and
;;; `*exit-after-handoff*' are substituted, so everything up to the irreversible step is
;;; genuinely exercised: the re-check, the writability gate, the payload download, the
;;; PAYLOAD signature check, the shutdown hook, and the exact arguments handed to NSIS.
;;; What is NOT exercised is NSIS actually running. The installer is built now (by
;;; desktop-release.yml); what is missing is a test that runs it, which needs a machine
;;; willing to have software installed on it.
;;;
;;; THE THREE TESTS THAT MATTER ARE THE ONES ASSERTING THE INSTALLER WAS *NOT* LAUNCHED.
;;; A bad payload, a per-machine install, and an application that is not ready to stop are
;;; each a path where launching anyway is the actual harm, and a test that only checks the
;;; reported state would pass while the installer ran.
;;;
;;; WHY EVERY ONE OF THEM IS `#+win32'. `apply-update' REFUSES on macOS and Linux -- their
;;; apply strategies, `app-targz' and `appimage', are not written, so there is nothing to launch --
;;; and the refusal is a READER CONDITIONAL, resolved before any behaviour these tests
;;; describe. Without the guard every test below would signal `update-not-implemented' on
;;; two of the three platforms, and this suite would arrive RED in the Mac and Linux lanes
;;; as a side effect of a Windows feature landing. The non-Windows claim is a real one and
;;; is asserted directly instead, immediately below.

(defun staging-directories ()
  "Every staging directory currently in the temp directory, as namestrings."
  (remove-if-not (lambda (d)
                   (let ((name (car (last (pathname-directory d)))))
                     (and (stringp name) (up::%staging-name-time name))))
                 (ignore-errors (uiop:subdirectories (uiop:temporary-directory)))))

(defvar *launched* nil "What the stubbed launcher was asked to run, or NIL.")
(defvar *exited* nil "Whether the handoff exit was reached.")

(defun payload-bytes () (sb-ext:string-to-octets "MZ this is a pretend NSIS installer"))

(defun apply-source (&key (payload-url "https://example.test/app-2.0.0-setup.exe")
                          (sign-payload t) (version "2.0.0") (format-name "nsis"))
  "A source serving a valid manifest AND the payload it names."
  (multiple-value-bind (private public-text) (ensure-keys)
    (declare (ignore public-text))
    (let* ((json (manifest-json :version version :payload-url payload-url
                                :format-name format-name))
           (bytes (utf8 json))
           (artifacts (make-hash-table :test #'equal))
           (payload (payload-bytes)))
      (setf (gethash payload-url artifacts) payload
            (gethash (concatenate 'string payload-url ".sig") artifacts)
            (if sign-payload
                (detached-signature private payload)
                ;; A signature over the WRONG bytes: well-formed, verifiable in shape,
                ;; and not a signature over this payload.
                (detached-signature private (sb-ext:string-to-octets "different bytes entirely"))))
      (make-instance 'fixed-source :body bytes :signature (detached-signature private bytes)
                                   :artifacts artifacts))))

(defmacro with-apply ((&key (writable t) (before-apply nil) (app-name "testapp")) &body body)
  "Run BODY with the irreversible step stubbed and a real, writable install directory.

APP-NAME is a parameter because `*app-name*' is what a `~/.<appname>' path is computed
from (design section 1), and the #111 fixtures need a name unique per run rather than a
shared literal that could collide with a real directory in somebody's home."
  `(let* ((dir (merge-pathnames (format nil "ouranos-apply-test-~D/" (random 100000))
                                (uiop:temporary-directory))))
     (ensure-directories-exist dir)
     ;; WHAT THIS BODY STAGED, by difference. The successful path CANNOT be cleaned up by
     ;; the client -- it hands the installer to a detached process and exits -- so the
     ;; suite has to, or it leaks exactly what pre-publication issue 257 is about: roughly two directories per
     ;; whole-tree run, the suite committing in miniature the defect it is testing.
     ;;
     ;; By difference rather than from the stub launcher, because a path that stages and
     ;; then REFUSES never reaches the launcher and was leaking too.
     (let ((before (staging-directories)))
       (unwind-protect
          (multiple-value-bind (private public-text) (ensure-keys)
            (declare (ignore private))
            (let ((*launched* nil)
                  (*exited* nil)
                  (up:*installed-version* "1.0.0")
                  (up:*public-key* public-text)
                  (up:*app-name* ,app-name)
                  (up:*install-directory* (if ,writable
                                              (namestring dir)
                                              "Z:\\definitely\\not\\writable"))
                  (up:*before-apply* ,before-apply)
                  (up:*launch-installer*
                    (lambda (strategy installer install-dir)
                      (setf *launched* (list strategy installer install-dir))))
                  (up:*exit-after-handoff* (lambda () (setf *exited* t))))
              ,@body))
         (ignore-errors (uiop:delete-directory-tree dir :validate t))
         (dolist (d (set-difference (staging-directories) before :test #'equal))
           (ignore-errors (uiop:delete-directory-tree d :validate t)))))))

#-win32
(test on-a-platform-with-no-apply-strategy-apply-refuses-and-says-which-platform
  ;; The other side of the guard, and not a placeholder: "macOS and Linux refuse" is a
  ;; DECISION (neither apply strategy is written, #251), and a decision nothing asserts is
  ;; how a half-built apply path ships. The detail names the platform key, so the refusal
  ;; a user or a log sees says WHICH platform is unbuilt rather than merely that one is.
  (with-apply ()
    (handler-case
        (progn (up:apply-update :source (apply-source) :product "testapp")
               (fail "apply-update proceeded on a platform with no apply strategy"))
      (up:update-not-implemented (e)
        (is (search (platform:platform-key) (up:update-not-implemented-detail e))
            "the refusal did not say which platform it was refusing for")))
    (is-false *launched* "an installer was launched on a platform with no strategy")
    (is-false *exited*)))

#+win32
(test a-verified-payload-is-handed-to-the-installer-and-the-app-exits
  (with-apply ()
    (let ((status (up:apply-update :source (apply-source) :product "testapp")))
      (is (string= "applying" (getf status :status)))
      (is (string= "2.0.0" (getf status :version)))
      (is-true *launched* "the installer was never launched")
      (is-true *exited* "the application did not exit after handing off"))))

#+win32
(test the-installer-is-launched-against-the-install-directory
  ;; /D= must name where the app actually IS. Guess wrong and NSIS installs a second copy
  ;; elsewhere, leaves the running one untouched, and the user sees an update that
  ;; silently did nothing.
  (with-apply ()
    (up:apply-update :source (apply-source) :product "testapp")
    (destructuring-bind (strategy installer install-dir) *launched*
      (declare (ignore strategy))
      (is (search "setup.exe" installer))
      (is (string= (up:install-directory) install-dir)))))

#+win32
(test a-payload-whose-signature-does-not-verify-is-never-launched
  ;; THE ONE THAT MATTERS. Verifying the manifest says nothing about the payload: they are
  ;; separate artifacts with separate signatures, and a host that can serve one can serve
  ;; the other. Reporting an error while having already run the installer would be worse
  ;; than not checking at all.
  (with-apply ()
    (handler-case
        (progn (up:apply-update :source (apply-source :sign-payload nil) :product "testapp")
               (fail "a payload with a bad signature was accepted"))
      (up:update-source-error (e)
        (is (search "did not verify" (up:update-source-error-detail e)))))
    (is-false *launched* "an unverified payload was handed to the installer")
    (is-false *exited*)))

#+win32
(test a-per-machine-install-is-a-state-and-launches-nothing
  ;; "Ask whoever installed this", not a stack trace at a user who cannot act on it.
  (with-apply (:writable nil)
    (let ((status (up:apply-update :source (apply-source) :product "testapp")))
      (is (string= "blocked" (getf status :status)))
      (is (string= "not-writable" (getf status :block)))
      (is-false *launched* "an update was applied to a directory we cannot write")
      (is-false *exited*))))

#+win32
(test an-application-that-is-not-ready-abandons-the-update
  ;; The app drives the shutdown. A non-NIL answer means ABANDON -- not proceed and hope.
  ;; A webview child still holding the bundle is exactly this case, and proceeding would
  ;; fail the replace on Windows for reasons invisible to the updater.
  (with-apply (:before-apply (lambda () "a document has unsaved changes"))
    (let ((status (up:apply-update :source (apply-source) :product "testapp")))
      (is (string= "blocked" (getf status :status)))
      (is (string= "not-ready" (getf status :block)))
      (is (search "unsaved" (getf status :detail)))
      (is-false *launched* "the update proceeded despite the application refusing")
      (is-false *exited*))))

#+win32
(test a-ready-application-does-not-block-the-update
  ;; The control for the case above: NIL means ready, and the update proceeds.
  (with-apply (:before-apply (lambda () nil))
    (let ((status (up:apply-update :source (apply-source) :product "testapp")))
      (is (string= "applying" (getf status :status)))
      (is-true *launched*))))

(test apply-refuses-when-the-check-says-there-is-nothing-to-apply
  ;; Applying something the check refused would make the check decorative.
  (with-apply ()
    (handler-case
        (progn (up:apply-update :source (make-instance 'up:null-source) :product "testapp")
               (fail "apply-update proceeded with nothing on offer"))
      (up:update-not-implemented (e)
        (is (search "up-to-date" (up:update-not-implemented-detail e)))))
    (is-false *launched*)))

#+win32
(test the-payload-is-staged-outside-the-install-directory
  ;; Stage then swap: never write into the live bundle. The staged installer must not be
  ;; sitting in the directory it is about to replace the contents of.
  (with-apply ()
    (up:apply-update :source (apply-source) :product "testapp")
    (let ((installer (second *launched*))
          (install-dir (namestring (truename (up:install-directory)))))
      (is (not (search install-dir (namestring (truename installer))))
          "the payload was staged inside the live install directory"))))

;;; --- one strategy per format (section 7) ------------------------------------
;;;
;;; `format' is in the manifest so a product can change packaging WITHOUT shipping a new
;;; client first (section 3). That only works if the client actually reads it -- and until
;;; this landed, `platform-format' was defined, exported and had ZERO call sites while the
;;; apply path launched NSIS unconditionally. A manifest declaring any other packaging
;;; would have been handed to NSIS with NSIS's flags, which installs nothing and exits 0.

#+win32
(test the-declared-format-selects-the-strategy
  (with-apply ()
    (up:apply-update :source (apply-source :format-name "nsis") :product "testapp")
    (is (eq :nsis (first *launched*))))
  (with-apply ()
    (up:apply-update :source (apply-source :format-name "inno") :product "testapp")
    (is (eq :inno (first *launched*)))))

#+win32
(test the-format-is-read-from-the-manifest-not-from-the-host-os
  ;; Both of these run on this same Windows host. If the strategy came from the OS they
  ;; would be identical; they are not, and that difference is the whole point of the field.
  (let (a b)
    (with-apply ()
      (up:apply-update :source (apply-source :format-name "nsis") :product "testapp")
      (setf a (first *launched*)))
    (with-apply ()
      (up:apply-update :source (apply-source :format-name "inno") :product "testapp")
      (setf b (first *launched*)))
    (is (not (eq a b)) "the host OS, not the manifest, chose the strategy")))

#+win32
(test an-unrecognised-format-refuses-and-launches-nothing
  ;; An OLD client will meet a format it has never heard of -- that is what the field is
  ;; for. Falling back to a default would run an installer with the wrong flags against a
  ;; user's machine, silently. Refuse, exactly as for a schema from the future.
  (with-apply ()
    (handler-case
        (progn (up:apply-update :source (apply-source :format-name "some-future-packaging")
                                :product "testapp")
               (fail "an unknown payload format was accepted"))
      (up:unknown-payload-format (e)
        ;; The condition names what the MANIFEST declared, so the message can say what it
        ;; did not understand rather than merely that it did not understand.
        (is (equal "some-future-packaging" (up:unknown-payload-format-name e)))))
    (is-false *launched* "an unknown format was handed to a launcher")
    (is-false *exited*)))

#+win32
(test a-manifest-with-no-format-at-all-refuses
  ;; Absent is not "assume nsis". The same reasoning: guessing runs the wrong installer.
  (multiple-value-bind (private public-text) (ensure-keys)
    (declare (ignore public-text))
    (let* ((json (with-output-to-string (out)
                   (format out "{\"schema\": 1, \"product\": \"testapp\", \"channel\": \"stable\",")
                   (format out "\"version\": \"2.0.0\", \"published\": \"2026-06-01T00:00:00Z\",")
                   (format out "\"platforms\": { ~S: { \"payload\": { \"url\": \"https://example.test/x.exe\" } } } }"
                           (platform:platform-key))))
           (bytes (utf8 json))
           (artifacts (make-hash-table :test #'equal))
           (payload (payload-bytes)))
      (setf (gethash "https://example.test/x.exe" artifacts) payload
            (gethash "https://example.test/x.exe.sig" artifacts) (detached-signature private payload))
      (let ((source (make-instance 'fixed-source :body bytes :signature (detached-signature private bytes)
                                                 :artifacts artifacts)))
        (with-apply ()
          (handler-case
              (progn (up:apply-update :source source :product "testapp")
                     (fail "a manifest with no format was accepted"))
            (up:unknown-payload-format (e)
              (is (null (up:unknown-payload-format-name e))
                  "an absent format should be reported as absent, not as some default")))
          (is-false *launched* "a formatless manifest was handed to a launcher"))))))

;;; The launcher argument lists, without launching anything: they are a contract with two
;;; different installers, and getting either wrong installs nothing while exiting 0.

(test nsis-and-inno-do-not-share-an-argument-vocabulary
  ;; Documented rather than merely believed: /S vs /VERYSILENT, /D= vs /DIR=, and NSIS
  ;; requires its directory flag last and unquoted while Inno does not care. Handing one
  ;; the other's flags is the failure that exits 0 and installs nothing.
  (is (eq :nsis (up::%format-keyword "nsis")))
  (is (eq :inno (up::%format-keyword "inno")))
  (is (eq :inno (up::%format-keyword "INNO")) "format matching must not be case-fragile")
  (is (null (up::%format-keyword "nsis2")))
  (is (null (up::%format-keyword nil))))

;;; The argument vectors themselves. `%nsis-arguments' and `%inno-arguments' exist apart
;;; from the launch precisely so these can be read without running an installer -- the
;;; comment above this section used to claim they were "asserted by capturing what UIOP
;;; would be asked to run", and nothing captured anything.

(test no-installer-argument-carries-a-quote-it-added-itself
  ;; THE ONE THAT WOULD HAVE CAUGHT IT. `uiop:launch-program' given a LIST builds the
  ;; Windows command line and quotes what needs quoting; an argument that arrives already
  ;; quoted gets a second layer and the installer sees a literal `"' inside the value.
  ;; The Inno strategy was `(format nil "/DIR=~S" dir)' -- which reads like "quote it" and
  ;; is not, `~S' being the Lisp printer -- and it exited 3 and installed nothing. NSIS
  ;; never showed the fault because `/D=' takes no quotes: the same defect was invisible
  ;; in the packaging that had been run and fatal in the one that had not.
  ;;
  ;; A path WITH A SPACE, because that is the case the quoting was reaching for and the
  ;; reason a fix that simply deletes it has to be shown to survive.
  (let* ((dir "C:\\Program Files\\App")
         (nsis (up::%nsis-arguments "C:\\stage\\setup.exe" dir))
         (inno (up::%inno-arguments "C:\\stage\\setup.exe" dir)))
    (dolist (a (append nsis inno))
      (is (not (find #\" a)) "~S carries a quote; the spawner will add another" a))
    ;; And the path arrives WHOLE and unescaped -- no doubled backslashes either, which is
    ;; the other half of what `~S' did to it.
    (is (string= (format nil "/D=~A" dir) (car (last nsis))))
    (is (member (format nil "/DIR=~A" dir) inno :test #'string=))))

(test the-nsis-directory-flag-is-last-and-the-inno-one-need-not-be
  ;; NSIS treats everything after /D= as part of the path, so nothing may follow it. That
  ;; is its parser, not a style choice, and it is the difference that makes the two
  ;; vocabularies non-interchangeable rather than merely different.
  (let ((nsis (up::%nsis-arguments "setup.exe" "C:\\App"))
        (inno (up::%inno-arguments "setup.exe" "C:\\App")))
    (is (string= "setup.exe" (first nsis)))
    (is (string= "setup.exe" (first inno)))
    (is (uiop:string-prefix-p "/D=" (car (last nsis)))
        "NSIS's /D= must be the last argument")
    (is (equal '("setup.exe" "/S" "/D=C:\\App") nsis))
    (is (equal '("setup.exe" "/VERYSILENT" "/SUPPRESSMSGBOXES" "/NORESTART" "/DIR=C:\\App")
               inno))
    ;; Hand one the other's flags and it installs nothing while exiting 0. Asserted rather
    ;; than asserted-in-a-comment: the two vectors share only the installer path itself.
    (is (null (intersection (rest nsis) (rest inno) :test #'string=))
        "the two packagings were given overlapping flags")))

;;; --- the application's own data survives an update (#111) -------------------
;;;
;;; `hyperion/docs/desktop-distribution-design.md' section 1, on `~/.<appname>':
;;;
;;;     Orthogonal to the bundle and NEVER TOUCHED BY AN UPDATE ... the update path must
;;;     guarantee it survives.
;;;
;;; Decided, and until this landed asserted nowhere. It is the one failure on the update
;;; path that is silent, permanent, and has no version to roll back TO, because the data
;;; is gone.
;;;
;;; WHAT THIS HALF PROVES AND WHAT IT CANNOT. `*launch-installer*' is substituted, so what
;;; runs here is the CLIENT: the re-check, the writability probe (which really does write a
;;; file, into the install directory), the staging, the shutdown hook, and every refusal
;;; path. It says NOTHING about what NSIS or Inno do once launched -- and the installer is
;;; the half that can actually delete a directory. That half is
;;; `scripts/verify-appdata-survives.ps1', which runs a real installer against a real
;;; populated `~/.<appname>' on a real Windows machine. The seam between the two is exactly
;;; the launch, and neither half is evidence about the other.
;;;
;;; THE DIRECTORY IS AT THE REAL CONVENTION PATH, `~/.<app-name>', and not somewhere in
;;; temp. A cleanup step added in the future would compute that path from `*app-name*' and
;;; would find precisely this directory -- which is the only way a test could ever catch
;;; it. A fixture parked under a random temp name is invisible to the bug it exists for.
;;;
;;; THE POPULATION IS AS MUCH THE TEST AS THE ASSERTION. An EMPTY directory passes for an
;;; implementation that deletes everything in it, so the fixture carries the files a
;;; plausible mistake takes with it: a config file; a binary database, whose loss is the
;;; least recoverable; two files whose names look like build output, because an
;;; implementation that "cleans up" by pattern is the one that passes every other version
;;; of this test; a `dist/' subdirectory holding a file named exactly like the update
;;; payload; and an `uninstall.exe', a name the BUNDLE owns, so an implementation tidying
;;; away "its own" files by name reaches into the wrong tree entirely.

(defun file-octets (path)
  "PATH's contents, trimmed to what READ-SEQUENCE actually returned.

A declared length is a claim by someone else; the count returned is the only measurement.
That matters most for the staged-installer checks below, where the writer we are defending
against is precisely the party whose FILE-LENGTH we would otherwise be trusting."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let* ((buf (make-array (file-length in) :element-type '(unsigned-byte 8)))
           (n (read-sequence buf in)))
      (subseq buf 0 n))))

(defun snapshot-tree (root)
  "Every file under ROOT as (RELATIVE-NAME CONTENT WRITE-DATE), plus every subdirectory.

THE WHOLE CONTENT, not a digest of it. A digest can only report THAT something changed;
the failure message here has to be able to say WHICH file, or a red run teaches the next
reader nothing. Directories are entries too, so removing an empty one is still a
difference -- `never touched' is a claim about the tree, not only about bytes in it."
  (let ((root (uiop:ensure-directory-pathname root))
        (out '()))
    (labels ((walk (dir)
               (dolist (f (uiop:directory-files dir))
                 (push (list (enough-namestring f root) (file-octets f) (file-write-date f))
                       out))
               (dolist (d (uiop:subdirectories dir))
                 (push (list (enough-namestring d root) :directory nil) out)
                 (walk d))))
      (walk root))
    (sort out #'string< :key #'first)))

(defun tree-differences (before after)
  "What changed between two snapshots, each difference named. NIL when nothing did."
  (let ((diffs '()))
    (dolist (b before)
      (let ((a (assoc (first b) after :test #'string=)))
        (cond ((null a) (push (format nil "VANISHED ~A" (first b)) diffs))
              ((not (equalp (second b) (second a)))
               (push (format nil "MODIFIED ~A" (first b)) diffs))
              ;; A rewrite with identical bytes is still a touch, and section 1 says NEVER
              ;; TOUCHED. Reported under its own word so the message says which it was.
              ((not (eql (third b) (third a)))
               (push (format nil "RESTAMPED ~A" (first b)) diffs)))))
    (dolist (a after)
      (unless (assoc (first a) before :test #'string=)
        (push (format nil "APPEARED ~A" (first a)) diffs)))
    (sort diffs #'string<)))

(defun populate-app-data (app-name)
  "Create `~/.<APP-NAME>' and fill it the way a real one is filled. Returns the directory."
  (let ((dir (merge-pathnames (format nil ".~A/" app-name) (user-homedir-pathname))))
    (ensure-directories-exist dir)
    (flet ((text (relative content)
             (let ((path (merge-pathnames relative dir)))
               (ensure-directories-exist path)
               (with-open-file (s path :direction :output :if-exists :supersede
                                       :external-format :utf-8)
                 (write-string content s))))
           (binary (relative bytes)
             (let ((path (merge-pathnames relative dir)))
               (ensure-directories-exist path)
               (with-open-file (s path :direction :output :if-exists :supersede
                                       :element-type '(unsigned-byte 8))
                 (write-sequence bytes s)))))
      (text "config.toml" (format nil "config_version = 3~%theme = \"dark\"~%"))
      ;; A real SQLite file starts with exactly these bytes, so an implementation that
      ;; classifies by CONTENT rather than by name also sees a database sitting here.
      (binary "app.db" (concatenate '(vector (unsigned-byte 8))
                                    (sb-ext:string-to-octets "SQLite format 3")
                                    (make-array 241 :element-type '(unsigned-byte 8)
                                                    :initial-element 0)))
      (text "cache.fasl" "named like build output on purpose")
      (text "build.log" "and so is this")
      (text "uninstall.exe" "a name the BUNDLE owns, in the tree it must never reach into")
      (text "dist/app-2.0.0-setup.exe" "named exactly like the update payload itself")
      (text "exports/2026-09-01.csv" (format nil "id,amount~%1,42~%")))
    dir))

(defmacro with-app-data ((var &key (writable t) (before-apply nil)) &body body)
  "Run BODY with a POPULATED `~/.<app-name>' on disk and VAR bound to that directory.

The app name is unique per run because the directory is created in the REAL home
directory: the whole point is that a future cleanup step computing `~/.<appname>' would
find it. A shared literal there could collide with something a developer cares about."
  (let ((app (gensym "APP")))
    `(let* ((,app (format nil "ouranos-appdata-test-~D" (random 1000000)))
            (,var (populate-app-data ,app)))
       (unwind-protect
            (with-apply (:writable ,writable :before-apply ,before-apply :app-name ,app)
              ,@body)
         (ignore-errors (uiop:delete-directory-tree ,var :validate t))))))

(defmacro is-untouched (data before)
  "Assert the app-data tree is byte-identical to BEFORE, naming what changed if it is not."
  `(let ((diffs (tree-differences ,before (snapshot-tree ,data))))
     (is (null diffs) "the update touched ~~/.<appname>: ~{~A~^; ~}" diffs)))

;;; THE CONTROL, and it comes first because everything below it is worthless without it.
;;; An assertion that cannot fail is not an assertion, and "the directory was untouched"
;;; is exactly the claim a broken comparison reports most convincingly.
(test the-survival-comparison-detects-every-way-the-data-could-be-lost
  (let* ((before (list (list "config.toml" (sb-ext:string-to-octets "a") 100)
                       (list "app.db" (sb-ext:string-to-octets "b") 100)
                       (list "exports/" :directory nil)))
         (modified (list (list "config.toml" (sb-ext:string-to-octets "CHANGED") 100)
                         (list "app.db" (sb-ext:string-to-octets "b") 100)
                         (list "exports/" :directory nil)))
         (deleted (list (list "config.toml" (sb-ext:string-to-octets "a") 100)
                        (list "exports/" :directory nil)))
         (dir-gone (list (list "config.toml" (sb-ext:string-to-octets "a") 100)
                         (list "app.db" (sb-ext:string-to-octets "b") 100)))
         (added (append before (list (list "stray.tmp" (sb-ext:string-to-octets "c") 100))))
         (restamped (list (list "config.toml" (sb-ext:string-to-octets "a") 100)
                          (list "app.db" (sb-ext:string-to-octets "b") 999)
                          (list "exports/" :directory nil))))
    (is (null (tree-differences before before)) "an unchanged tree was reported as changed")
    (is (equal '("MODIFIED config.toml") (tree-differences before modified)))
    (is (equal '("VANISHED app.db") (tree-differences before deleted)))
    (is (equal '("VANISHED exports/") (tree-differences before dir-gone)))
    (is (equal '("APPEARED stray.tmp") (tree-differences before added)))
    (is (equal '("RESTAMPED app.db") (tree-differences before restamped)))))

(test the-fixture-really-is-populated-and-really-is-at-the-convention-path
  ;; A test against an empty directory passes for an implementation that deletes
  ;; everything in it -- so what the fixture CONTAINS is asserted rather than assumed. If
  ;; this ever goes red the survival tests below have quietly stopped testing anything and
  ;; would still be green, which is the failure this repo keeps finding.
  (with-app-data (data)
    (let ((names (mapcar #'first (snapshot-tree data))))
      (is (= 9 (length names)) "the fixture holds ~D entries, not 9: ~S" (length names) names)
      (dolist (expected '("config.toml" "app.db" "cache.fasl" "build.log" "uninstall.exe"))
        (is (member expected names :test #'string=) "the fixture is missing ~A" expected))
      (is (some (lambda (n) (search "setup.exe" n)) names)
          "the fixture no longer holds a file named like the update payload"))
    ;; And it is where `~/.<appname>' says it is, so a cleanup step computing that path
    ;; from `*app-name*' would find exactly this directory.
    (is (string= (namestring (truename data))
                 (namestring (truename (merge-pathnames (format nil ".~A/" up:*app-name*)
                                                        (user-homedir-pathname))))))
    ;; Neither directory contains the other. If they overlapped, every assertion below
    ;; would be about the install directory instead, and would still be green.
    (let ((install (namestring (truename (up:install-directory))))
          (home (namestring (truename data))))
      (is (not (search install home)) "the app data lives inside the install directory")
      (is (not (search home install)) "the install directory lives inside the app data"))))

#+win32
(test an-applied-update-does-not-touch-the-applications-own-data
  ;; The whole client apply path runs -- re-check, writability probe, download, payload
  ;; signature check, shutdown hook, handoff -- against a populated `~/.<appname>'.
  (with-app-data (data)
    (let ((before (snapshot-tree data)))
      (let ((status (up:apply-update :source (apply-source) :product "testapp")))
        (is (string= "applying" (getf status :status))))
      (is-true *launched* "nothing was applied, so this proved nothing")
      (is-untouched data before))))

(test a-refused-update-does-not-touch-the-applications-own-data
  ;; The refusal paths matter as much as the success path and are easier to get wrong: a
  ;; half-finished apply that tidies up after itself is the shape that eats a directory.
  ;; This refusal happens before the platform branch, so it runs on every platform.
  (with-app-data (data)
    (let ((before (snapshot-tree data)))
      (handler-case
          (progn (up:apply-update :source (make-instance 'up:null-source) :product "testapp")
                 (fail "apply-update proceeded with nothing on offer"))
        (up:update-not-implemented () t))
      (is-false *launched*)
      (is-untouched data before))))

#+win32
(test a-payload-that-does-not-verify-does-not-touch-the-applications-own-data
  ;; The worst moment to start cleaning up: an update that got as far as a downloaded
  ;; payload and then discarded it. Nothing about that discard involves the user's data.
  (with-app-data (data)
    (let ((before (snapshot-tree data)))
      (handler-case
          (progn (up:apply-update :source (apply-source :sign-payload nil) :product "testapp")
                 (fail "a payload with a bad signature was accepted"))
        (up:update-source-error () t))
      (is-false *launched*)
      (is-untouched data before))))

#+win32
(test an-application-that-refuses-to-stop-does-not-lose-its-data-either
  ;; Abandoning an update mid-flight is a normal outcome (`*before-apply*' said no), and
  ;; an abandoned update has even less business touching anything than a completed one.
  (with-app-data (data :before-apply (lambda () "a document has unsaved changes"))
    (let ((before (snapshot-tree data)))
      (let ((status (up:apply-update :source (apply-source) :product "testapp")))
        (is (string= "not-ready" (getf status :block))))
      (is-false *launched*)
      (is-untouched data before))))

#+win32
(test a-per-machine-install-refuses-without-touching-the-applications-own-data
  ;; `Not-Writable' means "ask whoever installed this". The install directory being
  ;; unwritable says nothing whatever about the user's own data, which is per-user and
  ;; always writable -- so this is the path where a confused implementation could still
  ;; reach for it.
  (with-app-data (data :writable nil)
    (let ((before (snapshot-tree data)))
      (let ((status (up:apply-update :source (apply-source) :product "testapp")))
        (is (string= "not-writable" (getf status :block))))
      (is-false *launched*)
      (is-untouched data before))))

;;; --- the staging directory does not accumulate (pre-publication issue 257) -----------------------
;;;
;;; MEASURED BEFORE IT WAS FIXED: 113 MB across 48 directories on one machine in a day --
;;; twelve full installers from real updates, the rest from this suite. Nothing crashed and
;;; nobody would have reported it. It surfaces months later as an application that fills a
;;; disk, with no way to connect it to updating.
;;;
;;; The sweep runs when a directory is CREATED and not when one is finished with, because
;;; there is no finished-with: `apply-update' hands off to a detached installer and exits,
;;; so the moment after a successful stage is the one moment this code never reaches.

(defmacro with-temp-directories ((&rest names) &body body)
  "Create directories NAMES under the temp directory, and remove any survivors afterwards."
  (let ((paths (gensym "PATHS")))
    `(let ((,paths (mapcar (lambda (n)
                             (let ((d (merge-pathnames (concatenate 'string n "/")
                                                       (uiop:temporary-directory))))
                               (ensure-directories-exist d)
                               d))
                           (list ,@names))))
       (unwind-protect (progn ,@body)
         (dolist (d ,paths) (ignore-errors (uiop:delete-directory-tree d :validate t)))))))

(defun temp-subdirectory-exists-p (name)
  (and (probe-file (merge-pathnames (concatenate 'string name "/")
                                    (uiop:temporary-directory)))
       t))

(test a-staging-directory-name-carries-a-time-this-code-can-read-back
  ;; The sweep decides what to delete from the NAME, so the two have to agree. They are in
  ;; one file and could still drift; this is the cheapest place to notice.
  (is (eql 100 (up::%staging-name-time "ouranos-update-100")))
  (is (eql 100 (up::%staging-name-time "ouranos-update-100-abc123")))
  ;; And NIL for anything this code did not name. A sweep that deletes what it cannot parse
  ;; is a sweep that deletes somebody else's directory.
  (is (null (up::%staging-name-time "ouranos-update-")))
  (is (null (up::%staging-name-time "ouranos-update-notatime")))
  (is (null (up::%staging-name-time "ouranos-updates-100")))
  (is (null (up::%staging-name-time "something-else-100"))))

(test two-staging-directories-made-in-the-same-second-are-still-two
  ;; `get-universal-time' has one-second resolution, and the old name was nothing but that.
  ;; Not hypothetical: one whole-tree run produced ...-3997370989 and ...-3997370990 a
  ;; second apart, the second holding two payloads from two tests that shared a second.
  (let ((dirs (loop repeat 8 collect (up::%staging-directory))))
    (unwind-protect
         (is (= 8 (length (remove-duplicates (mapcar #'namestring dirs) :test #'string=)))
             "staging directories collided: ~S" (mapcar #'file-namestring dirs))
      (dolist (d dirs) (ignore-errors (uiop:delete-directory-tree d :validate t))))))

(test an-old-staging-directory-is-swept-and-a-recent-one-is-not
  ;; THE CONTROL IS THE SECOND HALF. A sweep that simply deleted everything would pass the
  ;; first assertion perfectly -- and would delete the installer a second copy of the
  ;; application was, at that moment, about to run.
  (let* ((old-name (format nil "ouranos-update-~D-old~D" 100 (random 100000)))
         (new-name (format nil "ouranos-update-~D-new~D" (get-universal-time) (random 100000))))
    (with-temp-directories (old-name new-name)
      (is-true (temp-subdirectory-exists-p old-name) "the fixture did not create anything")
      (is-true (temp-subdirectory-exists-p new-name))
      (up::%sweep-staging)
      (is-false (temp-subdirectory-exists-p old-name) "an old staging directory survived")
      (is-true (temp-subdirectory-exists-p new-name)
               "a staging directory younger than the retention window was deleted"))))

(test the-sweep-leaves-alone-anything-it-did-not-name
  ;; The temp directory belongs to the whole machine. Recognise, or do not touch.
  (let ((mine (format nil "ouranos-update-~D-x~D" 100 (random 100000)))
        (theirs (format nil "ouranos-update~D" (random 100000)))
        (unrelated (format nil "not-ouranos-100-~D" (random 100000))))
    (with-temp-directories (mine theirs unrelated)
      (up::%sweep-staging)
      (is-false (temp-subdirectory-exists-p mine) "the sweep did not remove its own")
      (is-true (temp-subdirectory-exists-p theirs)
               "a directory with a similar name but no parseable stamp was deleted")
      (is-true (temp-subdirectory-exists-p unrelated)
               "an unrelated temp directory was deleted"))))

(test the-retention-window-is-what-decides-and-it-is-an-hour
  ;; Asserted against the parameter rather than a literal, so the number and the behaviour
  ;; cannot drift apart -- and asserted from BOTH sides of the boundary.
  (let ((name (format nil "ouranos-update-~D-w~D" 1000 (random 100000))))
    (with-temp-directories (name)
      ;; One second inside the window: kept.
      (up::%sweep-staging (+ 1000 up::+staging-retention-seconds+))
      (is-true (temp-subdirectory-exists-p name)
               "swept at exactly the retention boundary, which is inside the window")
      ;; One second past it: gone.
      (up::%sweep-staging (+ 1001 up::+staging-retention-seconds+))
      (is-false (temp-subdirectory-exists-p name) "not swept one second past the window"))))

#+win32
(test applying-an-update-sweeps-what-an-earlier-apply-left-behind
  ;; The whole point, end to end: the leak was on the APPLY path, so the fix has to be
  ;; observable there rather than only in the function that names directories.
  (let ((stale (format nil "ouranos-update-~D-stale~D" 100 (random 100000))))
    (with-temp-directories (stale)
      (with-apply ()
        (is-true (temp-subdirectory-exists-p stale) "the fixture did not create anything")
        (up:apply-update :source (apply-source) :product "testapp")
        (is-true *launched* "nothing was applied, so this proved nothing")
        (is-false (temp-subdirectory-exists-p stale)
                  "an applied update left an earlier apply's staging directory behind")))))

#+win32
(test a-refusal-after-staging-discards-the-payload-and-a-handoff-does-not
  ;; TWO HALVES OF ONE DECISION, and the second is the control that makes the first mean
  ;; something. `apply-update' stages BEFORE it checks the declared format, so an
  ;; unrecognised format downloads a full installer and then refuses -- and until pre-publication issue 257 it
  ;; left it there. A refusal has an afterwards and must clean up.
  ;;
  ;; A HAND-OFF DOES NOT. The installer is about to run and this process is about to exit,
  ;; so the staged payload MUST survive; `%sweep-staging' collects it on the next apply.
  ;; Asserted here so that "the refusal cleaned up" cannot be satisfied by code that simply
  ;; deletes the staging directory unconditionally -- which would break every real update.
  (with-apply ()
    (let ((before (staging-directories)))
      (handler-case
          (progn (up:apply-update :source (apply-source :format-name "some-future-packaging")
                                  :product "testapp")
                 (fail "an unknown payload format was accepted"))
        (up:unknown-payload-format () t))
      (is (null (set-difference (staging-directories) before :test #'equal))
          "a refusal after staging left its downloaded payload in the temp directory")))
  (with-apply (:before-apply (lambda () "a document has unsaved changes"))
    (let ((before (staging-directories)))
      (up:apply-update :source (apply-source) :product "testapp")
      (is (null (set-difference (staging-directories) before :test #'equal))
          "an abandoned update left its downloaded payload in the temp directory")))
  ;; THE CONTROL.
  (with-apply ()
    (let ((before (staging-directories)))
      (up:apply-update :source (apply-source) :product "testapp")
      (is-true *launched*)
      (is (= 1 (length (set-difference (staging-directories) before :test #'equal)))
          "a handed-off installer must survive -- the installer is about to run it"))))


;;; --- the HTTP backend, against a socket that actually answers (pre-publication issue 332) ---------
;;;
;;; EVERY TEST ABOVE REACHES THE CLIENT THROUGH A CLOS STUB -- `fixed-source',
;;; `broken-source', `directory-source'. All three return what the protocol says to return,
;;; which is exactly why none of them could see the defect this section exists for:
;;; `%fetch-bytes' documents a 404 as the ordinary "nothing published on this channel yet"
;;; answer and maps it to `(values nil nil)', and `dex:request' SIGNALS on a 404 rather
;;; than returning it. The branch was dead from the day it was written, and the stubs --
;;; being easier than the thing they stood in for -- reported it green.
;;;
;;; So these tests are not "HTTP coverage" for its own sake. The contract under test is the
;;; one between `hyperion/update' and DEXADOR, and nothing that substitutes for Dexador can
;;; state it. A socket speaking a canned HTTP/1.1 response is the smallest fixture that is
;;; not easier than reality: Dexador parses a real status line and signals, or does not, on
;;; its own judgement.

(defun ascii-string (bytes)
  (map 'string #'code-char bytes))

(defun read-crlf-line (stream)
  "One CRLF-terminated line off STREAM as a string, or NIL at end of input."
  (let ((bytes (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer t)))
    (loop for b = (read-byte stream nil nil)
          do (cond ((null b) (return (and (plusp (length bytes)) (ascii-string bytes))))
                   ((= b 10) (return (ascii-string bytes)))
                   ((= b 13))                    ; CR dropped; CRLF is the delimiter
                   (t (vector-push-extend b bytes))))))

(defun read-http-request (stream)
  "Consume one request's start line and headers; return the PATH it asked for."
  (let ((path nil))
    (loop for line = (read-crlf-line stream)
          while line
          do (when (null path)
               (let* ((sp1 (position #\Space line))
                      (sp2 (and sp1 (position #\Space line :start (1+ sp1)))))
                 (setf path (if (and sp1 sp2) (subseq line (1+ sp1) sp2) ""))))
             (when (string= line "") (return)))
    path))

(defun write-http-response (stream status body)
  (flet ((line (control &rest args)
           (let ((text (apply #'format nil control args)))
             (loop for ch across text do (write-byte (char-code ch) stream))
             (write-byte 13 stream)
             (write-byte 10 stream))))
    (line "HTTP/1.1 ~D ~A" status
          (case status (200 "OK") (404 "Not Found") (500 "Internal Server Error") (t "Status")))
    (line "Content-Type: application/octet-stream")
    (line "Content-Length: ~D" (length body))
    ;; Forces a fresh connection per request, so a pooled socket cannot make one test's
    ;; response answer the next test's question.
    (line "Connection: close")
    (line ""))
  (write-sequence body stream)
  (finish-output stream))

(defun start-canned-http (responder)
  "Serve canned HTTP/1.1 responses on an ephemeral loopback port.

RESPONDER is called with the requested path and returns (VALUES status body-octets).
Returns (VALUES base-url stop-function)."
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
        (stopping nil))
    (setf (sb-bsd-sockets:sockopt-reuse-address socket) t)
    (sb-bsd-sockets:socket-bind socket #(127 0 0 1) 0)
    (sb-bsd-sockets:socket-listen socket 8)
    (multiple-value-bind (address port) (sb-bsd-sockets:socket-name socket)
      (declare (ignore address))
      (let ((thread (sb-thread:make-thread
                     (lambda ()
                       (loop until stopping
                             do (let ((conn (ignore-errors (sb-bsd-sockets:socket-accept socket))))
                                  (when (null conn) (return))
                                  (unwind-protect
                                       (unless stopping
                                         (ignore-errors
                                          (let ((stream (sb-bsd-sockets:socket-make-stream
                                                         conn :input t :output t
                                                         :element-type '(unsigned-byte 8))))
                                            (multiple-value-bind (status body)
                                                (funcall responder (read-http-request stream))
                                              (write-http-response stream status body)))))
                                    (ignore-errors (sb-bsd-sockets:socket-close conn))))))
                     :name "canned-http")))
        (values
         (format nil "http://127.0.0.1:~D/" port)
         (lambda ()
           (setf stopping t)
           ;; ACCEPT blocks, and closing the listener under it is not portable. One
           ;; throwaway connection wakes it to notice STOPPING instead.
           (ignore-errors
            (let ((waker (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
              (sb-bsd-sockets:socket-connect waker #(127 0 0 1) port)
              (sb-bsd-sockets:socket-close waker)))
           (ignore-errors (sb-thread:join-thread thread :timeout 5))
           (ignore-errors (sb-bsd-sockets:socket-close socket))))))))

(defmacro with-canned-http ((base-url responder) &body body)
  (let ((stop (gensym "STOP")))
    `(multiple-value-bind (,base-url ,stop) (start-canned-http ,responder)
       (unwind-protect (progn ,@body)
         (funcall ,stop)))))

(defun always (status &optional (body (make-array 0 :element-type '(unsigned-byte 8))))
  (lambda (path) (declare (ignore path)) (values status body)))

(defun a-dead-port ()
  "A loopback port with nothing listening on it: connection refused, not a 404."
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-bind socket #(127 0 0 1) 0)
    (multiple-value-bind (address port) (sb-bsd-sockets:socket-name socket)
      (declare (ignore address))
      (sb-bsd-sockets:socket-close socket)
      (format nil "http://127.0.0.1:~D/" port))))

(test http-404-is-a-channel-with-nothing-published
  ;; THE REGRESSION. Before the fix this signalled `update-source-error', so a brand-new
  ;; install pointed at a channel with no release reported the source as unreachable --
  ;; and, in a source LIST, kept trying and finally raised instead of stopping at an
  ;; answer. "Nothing published yet" is a state, and it is this one.
  (with-canned-http (base (always 404 (sb-ext:string-to-octets "{\"error\":\"Not Found\"}")))
    (let ((source (make-instance 'up:github-release-source :base-url base)))
      (multiple-value-bind (bytes signature) (up:fetch-manifest source "stable")
        (is (null bytes) "a 404 must read as nothing published, not as a failure")
        (is (null signature))))))

(test http-500-is-a-source-that-is-misbehaving
  ;; THE CONTROL, and the half that keeps the fix honest: the repair turns a signalled
  ;; status back into a response, so it could just as easily have swallowed EVERY non-2xx
  ;; into `(values nil nil)'. A 500 is not an empty channel and must still signal.
  (with-canned-http (base (always 500))
    (let ((source (make-instance 'up:github-release-source :base-url base)))
      (signals up:update-source-error (up:fetch-manifest source "stable")))))

(test http-carries-bytes-through-undecoded
  ;; The manifest signature is over the EXACT bytes, so a decode-and-re-encode round trip
  ;; invalidates it, and an installer decoded as text is not an installer (pre-publication issue 223). Served
  ;; here with octets that are not valid UTF-8, because that is the input on which a decode
  ;; would either corrupt the body or signal -- and either one is the failure.
  (let ((doc (coerce #(255 254 0 123 34 97 34 58 49 125) '(vector (unsigned-byte 8))))
        (sig (coerce #(1 2 3 250 251 252) '(vector (unsigned-byte 8)))))
    (with-canned-http (base (lambda (path)
                              (values 200 (if (search ".sig" path) sig doc))))
      (let ((source (make-instance 'up:s3-source :base-url base)))
        (multiple-value-bind (bytes signature) (up:fetch-manifest source "stable")
          (is (equalp doc bytes) "the manifest came back re-encoded rather than verbatim")
          (is (equalp sig signature)))))))

(test http-asks-for-the-channel-by-name
  ;; The filename IS the contract (design section 2), and it is named once in the generator
  ;; and once in the client, in files that cannot see each other -- the drift that produced
  ;; `latest.json' against a client asking for `stable.json' (pre-publication issue 77). Asserted against the
  ;; path a server actually received, which is the only place the two meet.
  (let ((asked '()))
    (with-canned-http (base (lambda (path) (push path asked) (values 404 nil)))
      (let ((source (make-instance 'up:github-release-source :base-url base)))
        (up:fetch-manifest source "beta")))
    (is (member "/beta.json" asked :test #'string=)
        "the client did not ask for <channel>.json")
    (is (member "/beta.json.sig" asked :test #'string=)
        "the client did not ask for the detached signature beside it")))

(test an-unreachable-source-falls-through-to-the-next
  ;; Design section 5, over real sockets rather than a stub that merely promises to fail.
  ;; Connection refused is NOT an answer, so the list must keep going.
  (let ((doc (sb-ext:string-to-octets "{\"schema\":1}"))
        (sig (sb-ext:string-to-octets "signature")))
    (with-canned-http (base (lambda (path) (values 200 (if (search ".sig" path) sig doc))))
      (let ((sources (list (make-instance 'up:github-release-source :base-url (a-dead-port))
                           (make-instance 'up:s3-source :base-url base))))
        (multiple-value-bind (bytes signature) (up:fetch-manifest sources "stable")
          (is (equalp doc bytes))
          (is (equalp sig signature)))))))

(test an-empty-source-stops-the-search
  ;; The other direction, and the one the 404 defect had made untestable. An EMPTY source
  ;; is an ANSWER: the list must stop there rather than fall through to a mirror that would
  ;; have served an older release. This is the anti-rollback argument one layer down.
  (let ((reached nil))
    (with-canned-http (empty (always 404))
      (with-canned-http (mirror (lambda (path)
                                  (declare (ignore path))
                                  (setf reached t)
                                  (values 200 (sb-ext:string-to-octets "{}"))))
        (let ((sources (list (make-instance 'up:github-release-source :base-url empty)
                             (make-instance 'up:s3-source :base-url mirror))))
          (multiple-value-bind (bytes signature) (up:fetch-manifest sources "stable")
            (is (null bytes))
            (is (null signature))
            (is-false reached "the search continued past a source that had answered")))))))

;;; --- pre-publication issue 264: the window between the write and the launch ---------------------
;;;
;;; `stage-payload' verifies the payload's signature over the bytes it holds IN MEMORY,
;;; writes them, and hands the launcher a PATH. These three tests are about the gap, and the
;;; adversarial one has to SWAP THE BYTES rather than assert that verification happened --
;;; an assertion that the signature was checked cannot distinguish "checked the right file"
;;; from "checked a file".
;;;
;;; `*before-apply*' is the injection point, and it is not a hole cut for the test: it is a
;;; production hook that runs at exactly the moment under test -- after `stage-payload' has
;;; written and verified, before the format refusal and the hand-off. Returning NIL from it
;;; means "ready", so the apply proceeds into the window with the file already replaced.

(defun staged-payload-file (before)
  "The payload file in the staging directory this apply created. FOUND ON DISK.

By difference against BEFORE, and read out of the filesystem rather than taken from an
argument. A fixture handed the path would be exercising a path the test already knew; the
substitution has to land on the same file the client will hand to the launcher, which means
discovering it the way an attacker would."
  (let ((new (set-difference (staging-directories) before :test #'equal)))
    (unless (= 1 (length new))
      (error "expected exactly 1 new staging directory, found ~D" (length new)))
    (let ((files (uiop:directory-files (first new))))
      (unless (= 1 (length files))
        (error "expected exactly 1 staged file, found ~D" (length files)))
      (first files))))

#+win32
(test a-staged-installer-substituted-before-the-launch-is-refused-and-never-runs
  (let* ((before (staging-directories))
         (substitute (sb-ext:string-to-octets "not the installer you verified"))
         (bytes-as-staged nil)
         (bytes-after-swap nil)
         (staging-dir nil))
    (with-apply (:before-apply
                 (lambda ()
                   (let ((staged (staged-payload-file before)))
                     (setf staging-dir (uiop:pathname-directory-pathname staged)
                           bytes-as-staged (file-octets staged))
                     (with-open-file (out staged :direction :output
                                                 :element-type '(unsigned-byte 8)
                                                 :if-exists :supersede)
                       (write-sequence substitute out))
                     ;; CAPTURED HERE, NOT AFTER. A refusal runs `%discard-staged', which
                     ;; deletes the directory -- so the evidence and the thing it evidences
                     ;; would be destroyed together, and the assertion would be
                     ;; unfalsifiable the moment the file was gone.
                     (setf bytes-after-swap (file-octets staged)))
                   nil))
      (handler-case
          (progn (up:apply-update :source (apply-source) :product "testapp")
                 (fail "apply-update launched an installer that had been substituted"))
        (up:update-source-error (e)
          (is (search "no longer matches its signature"
                      (up:update-source-error-detail e)))))
      ;; THE SWAP ACTUALLY HAPPENED. Without these two the test would pass just as well if
      ;; the hook had never run and something else entirely had refused -- which is the
      ;; failure mode of every "assert it was checked" test.
      (is (equalp (payload-bytes) bytes-as-staged)
          "the file staged before the swap was not the verified payload")
      (is (equalp substitute bytes-after-swap)
          "the swap did not reach the staged file")
      (is-false *launched* "a substituted installer was handed to the launcher")
      (is-false *exited* "the process exited as though it had handed off")
      ;; A refusal after staging has an afterwards, and pre-publication issue 257 is what happens when it leaks.
      (is-false (probe-file staging-dir)
                "the refusal left the substituted installer on disk"))))

#+win32
(test an-unmodified-staged-installer-still-reaches-the-launcher
  ;; The other direction, and not a formality: a guard that fails closed on the happy path
  ;; is a broken updater rather than a safe one. Same hook, same discovery of the same file
  ;; by the same means -- the ONLY difference from the test above is that nothing is written.
  (let* ((before (staging-directories))
         (bytes-as-staged nil))
    (with-apply (:before-apply
                 (lambda ()
                   (setf bytes-as-staged (file-octets (staged-payload-file before)))
                   nil))
      (let ((status (up:apply-update :source (apply-source) :product "testapp")))
        (is (string= "applying" (getf status :status)))
        (is (equalp (payload-bytes) bytes-as-staged)
            "the staged bytes were not the verified payload")
        (is-true *launched* "an unmodified installer was not launched")))))

#+win32
(test a-staged-installer-truncated-before-the-launch-is-refused
  ;; The short-read direction, which is the one a declared length gets wrong. A substitute
  ;; SHORTER than the original leaves `file-length' describing a file that no longer exists
  ;; at that size; `%read-staged-bytes' trims to what `read-sequence' actually returned, so
  ;; what gets verified is the bytes read rather than a verified prefix plus a tail of
  ;; whatever the buffer happened to hold.
  (let* ((before (staging-directories))
         (shortened nil))
    (with-apply (:before-apply
                 (lambda ()
                   (let ((staged (staged-payload-file before)))
                     (with-open-file (out staged :direction :output
                                                 :element-type '(unsigned-byte 8)
                                                 :if-exists :supersede)
                       (write-sequence (subseq (payload-bytes) 0 10) out))
                     (setf shortened (length (file-octets staged))))
                   nil))
      (handler-case
          (progn (up:apply-update :source (apply-source) :product "testapp")
                 (fail "apply-update launched a truncated installer"))
        (up:update-source-error (e)
          (is (search "no longer matches its signature"
                      (up:update-source-error-detail e)))))
      (is (= 10 shortened) "the truncation did not reach the staged file")
      (is-false *launched* "a truncated installer was handed to the launcher"))))

;;; --- pre-publication issue 264: the staging directory's permissions -----------------------------
;;;
;;; The ticket called TEMP "world-writable"; measured, it is not, and the whole point of
;;; these tests is that the property held BY INHERITANCE and nothing checked it. So they
;;; assert the DACL rather than asserting that a directory exists, and the adversarial one
;;; GRANTS A REAL PRINCIPAL REAL WRITE ACCESS rather than simulating a bad ACL -- a fixture
;;; that merely fed a made-up SDDL string to the parser would test the parser, and the
;;; parser is not the thing that could be wrong here.

#+win32
(defun icacls-grants (path)
  "What icacls says about PATH, as one string, for use in a failure message."
  (or (ignore-errors
       (uiop:run-program (list "icacls" (string-right-trim '(#\\ #\/)
                                                           (uiop:native-namestring path)))
                         :output '(:string :stripped t) :error-output nil
                         :ignore-error-status t))
      ""))

#+win32
(defun principal-sids-of (principals)
  "PRINCIPALS with every alias replaced by the SID it denotes, and anything unresolvable
left as it was."
  (let ((resolved (up::%principal-sids principals)))
    (mapcar (lambda (p) (or (cdr (assoc p resolved :test #'string-equal)) p)) principals)))

#+win32
(test a-staging-directory-is-given-its-own-dacl-not-an-inherited-one
  ;; The positive direction, and it is about PROVENANCE of the permissions rather than their
  ;; presence: an inherited DACL and an established one can grant identical rights today and
  ;; differ entirely the moment TEMP is redirected. `P' in the SDDL is the protected flag --
  ;; it is what says "these ACEs are ours, not the parent's".
  (let ((dir (up::%staging-directory)))
    (unwind-protect
         (let ((principals (up::%staging-dacl dir)))
           (is (not (null principals))
               "the staging directory's DACL could not be read at all")
           ;; Nobody outside {this user, SYSTEM, Administrators}.
           (is (null (up::%unexpected-acl-principals dir (up::%current-user-sid)))
               "the staging directory grants access to an unexpected principal: ~A"
               (icacls-grants dir))
           (is (member "SY" principals :test #'string-equal)
               "LocalSystem is not on the staging directory's DACL")
           ;; IN SIDS, because the DACL does not have to spell it as one. This assertion
           ;; read `(member (%current-user-sid) principals)' until pre-publication issue 446, which is false on
           ;; any account SDDL abbreviates -- it was failing on the CI runner beside the
           ;; refusal it was supposed to be the control for.
           (is (member (up::%current-user-sid) (principal-sids-of principals)
                       :test #'string-equal)
               "the user this process runs as is not on its own staging directory's DACL: ~S"
               principals))
      (ignore-errors (uiop:delete-directory-tree dir :validate t)))))

#+win32
(defun rid-500-sid ()
  "This machine's built-in Administrator SID, or NIL when it cannot be read.

READ FROM THE SAM, not from the SDDL resolution this fixture is here to check. A helper that
built the expected answer with the code under test would make the adversarial case come out
right for the same reason the common one does, and the test would pass while asserting
nothing. `Get-LocalUser' is a different lookup against a different store."
  (let ((out (up::%run-capture
              "powershell"
              '("-NoProfile" "-Command"
                "(Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-21-*-500' } | Select-Object -First 1).SID.Value"))))
    (let ((sid (and out (string-trim '(#\Space #\Return #\Newline #\Tab) out))))
      (when (and sid (uiop:string-prefix-p "S-1-5-21-" sid)) sid))))

#+win32
(test a-grant-to-this-process-is-not-a-stranger-because-sddl-abbreviated-it
  ;; pre-publication issue 446. `%current-user-sid' answers in SIDs; `icacls /save' answers in SDDL, which
  ;; abbreviates some accounts -- the built-in Administrator is `LA'. Comparing the two
  ;; directly told a process running as such an account that its OWN staging directory
  ;; belonged to somebody else, and the refusal is not a warning: it aborts the update.
  ;;
  ;; The grant is real and is made the way the client makes its own -- by full SID, through
  ;; icacls, on a real directory -- and then read back through the same path. The account is
  ;; the one the CI runner happens to run as, which is why this had been failing on the
  ;; Windows leg from the commit the check landed in (pre-publication issue 264) and on no other leg ever.
  (let ((admin (rid-500-sid)))
    (if (null admin)
        (skip "this host would not name its built-in Administrator account, so there is no aliased SID to grant")
        (let ((dir (uiop:ensure-directory-pathname
                    (merge-pathnames (format nil "ouranos-acl-alias-~A"
                                             (aion/random:random-hex 32))
                                     (uiop:temporary-directory)))))
          (ensure-directories-exist dir)
          (unwind-protect
               (let ((path (up::%acl-path dir)))
                 (up::%run-capture "icacls" (list path "/inheritance:r"
                                                  "/grant:r" (format nil "*~A:(OI)(CI)F" admin)
                                                  "/grant:r" "*S-1-5-18:(OI)(CI)F"
                                                  "/grant:r" "*S-1-5-32-544:(OI)(CI)F"))
                 (let ((principals (up::%staging-dacl dir)))
                   (is (not (null principals)) "the DACL just written could not be read back")
                   (cond
                     ((member admin principals :test #'string-equal)
                      ;; No alias, no bug to see. Saying so beats a green that means nothing.
                      (skip "this host's icacls spelled the account as a SID, so nothing here is abbreviated"))
                     (t
                      ;; THE PRECONDITION IS ASSERTED, NOT ASSUMED: the abbreviation has to
                      ;; be in the DACL before its mishandling can be tested.
                      (is (member "LA" principals :test #'string-equal)
                          "granting the built-in Administrator did not produce an alias to resolve: ~S"
                          principals)
                      (is (equal admin (cdr (assoc "LA" (up::%principal-sids '("LA"))
                                                   :test #'string-equal)))
                          "LA did not resolve to the account the SAM calls RID 500")
                      (is (null (up::%unexpected-acl-principals dir admin))
                          "the account that was granted is reported as a stranger: ~S~%~A"
                          (up::%unexpected-acl-principals dir admin) (icacls-grants dir))
                      ;; THE ADVERSARIAL DIRECTION, in the same directory. A helper that
                      ;; makes the user's own grant resolve would make Everyone's resolve
                      ;; too, and Everyone has to keep being refused.
                      (up::%run-capture "icacls" (list path "/grant" "*S-1-1-0:(OI)(CI)F"))
                      (let ((unexpected (up::%unexpected-acl-principals dir admin)))
                        (is (member "WD" unexpected :test #'string-equal)
                            "Everyone stopped being unexpected once aliases resolve: ~S~%~A"
                            unexpected (icacls-grants dir)))))))
            (ignore-errors (uiop:delete-directory-tree dir :validate t)))))))

#+win32
(test a-staging-directory-writable-by-others-is-refused-and-names-the-principal
  ;; THE ADVERSARIAL DIRECTION, and the grant is real: `*S-1-1-0' is Everyone, added to a
  ;; real directory with the real tool, and then read back through the same code path the
  ;; client uses. Nothing here is a simulated ACL.
  (let ((dir (up::%staging-directory)))
    (unwind-protect
         (progn
           ;; Control first: as created, it is clean. Without this the refusal below could
           ;; be the directory having been bad all along rather than the grant doing it.
           (is (null (up::%unexpected-acl-principals dir (up::%current-user-sid)))
               "the directory was already writable by others before the test granted it")
           (uiop:run-program (list "icacls" (string-right-trim '(#\\ #\/)
                                                               (uiop:native-namestring dir))
                                   "/grant" "*S-1-1-0:(OI)(CI)F")
                             :output nil :error-output nil :ignore-error-status t)
           (let ((unexpected (up::%unexpected-acl-principals dir (up::%current-user-sid))))
             ;; THE GRANT LANDED. An assertion that the check refuses is worth nothing if
             ;; the thing it was supposed to refuse never got there.
             (is (member "WD" unexpected :test #'string-equal)
                 "granting Everyone did not show up in the DACL: ~A" (icacls-grants dir)))
           ;; And the refusal NAMES it -- "writable by others" is unactionable to whoever
           ;; reads this without the code in front of them.
           (handler-case
               (progn (up::%harden-staging-directory dir)
                      (fail "a directory writable by Everyone was accepted for staging"))
             (up:update-source-error (e)
               (let ((detail (up:update-source-error-detail e)))
                 (is (search "WD" detail)
                     "the refusal did not name the principal that holds write access")
                 (is (search "OURANOS_ALLOW_UNSAFE_STAGING" detail)
                     "the refusal did not say how to proceed deliberately")))))
      (ignore-errors (uiop:delete-directory-tree dir :validate t)))))

#+win32
(test the-staging-permission-refusal-can-be-overridden-affirmatively-and-only-so
  ;; The override is affirmative-only for the reason the docstring gives: a check written as
  ;; "is it set to anything" turns OURANOS_ALLOW_UNSAFE_STAGING=0 -- which somebody typed
  ;; meaning to turn it OFF -- into permission. Both directions, because only one of them
  ;; is the mistake worth having a test for.
  (let ((saved (uiop:getenv "OURANOS_ALLOW_UNSAFE_STAGING")))
    (unwind-protect
         (flet ((set-to (v) (setf (uiop:getenv "OURANOS_ALLOW_UNSAFE_STAGING") v)))
           (set-to "1")
           (is-true (up::%unsafe-staging-allowed-p) "1 did not enable the override")
           (set-to "yes")
           (is-true (up::%unsafe-staging-allowed-p) "yes did not enable the override")
           (set-to "0")
           (is-false (up::%unsafe-staging-allowed-p) "0 was read as permission")
           (set-to "false")
           (is-false (up::%unsafe-staging-allowed-p) "false was read as permission")
           (set-to "")
           (is-false (up::%unsafe-staging-allowed-p) "an empty value was read as permission"))
      (setf (uiop:getenv "OURANOS_ALLOW_UNSAFE_STAGING") (or saved "")))))

#+win32
(test the-sddl-parser-reads-the-dacl-and-not-the-audit-section
  ;; The one genuinely unit-level check here, and it earns its place: an S: (audit) section
  ;; says who is WATCHED, not who may write. Reading it as a DACL would refuse any machine
  ;; with auditing configured -- a refusal nobody could act on, on a correctly set up host.
  (let ((principals (up::%sddl-dacl-principals
                     "D:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)S:AI(AU;OICISAFA;FA;;;WD)")))
    (is (equal '("BA" "SY") principals)
        "the audit section leaked into the DACL principals: ~S" principals)))
