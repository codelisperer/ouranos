;;;; cf-tests.lisp --- aion/darwin, without touching the keychain (ADR-0004).
;;;;
;;;; These only convert values and decode codes. Nothing here reads or writes a keychain, so the
;;;; suite never raises a dialog and needs no permission from the person at the machine.

(defpackage #:aion/darwin/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:d #:aion/darwin) (#:ffi #:aion/darwin/ffi))
  (:export #:run-tests))

(in-package #:aion/darwin/tests)

(def-suite darwin :description "aion/darwin: CoreFoundation conversions and OSStatus.")
(in-suite darwin)

(defun run-tests ()
  (let ((results (run 'darwin)))
    (explain! results)
    (results-status results)))

(test strings-round-trip-through-cfstring
  (dolist (s (list "plain ascii"
                   (coerce (list (code-char #xE9) (code-char #x6587) (code-char #x1F642)) 'string)
                   ""))
    (d:with-cf ((ref (d:make-cf-string s)))
      (is (string= s (d:cf-string-to-lisp ref)) "~S did not come back intact" s)))
  ;; CFString counts UTF-16 units: e-acute and the CJK character are one each, the emoji two.
  (d:with-cf ((ref (d:make-cf-string (coerce (list (code-char #xE9) (code-char #x6587) (code-char #x1F642)) 'string))))
    (is (= 4 (ffi:cf-string-get-length ref)))))

(test octets-round-trip-through-cfdata
  (let ((octets (coerce '(0 1 2 254 255 0 128) '(vector (unsigned-byte 8)))))
    (d:with-cf ((ref (d:make-cf-data octets)))
      (is (equalp octets (d:cf-data-octets ref)))))
  (d:with-cf ((ref (d:make-cf-data (make-array 0 :element-type '(unsigned-byte 8)))))
    (is (equalp #() (d:cf-data-octets ref)))))

(test a-dictionary-holds-what-it-was-given
  (d:with-cf ((key (d:make-cf-string "k"))
              (value (d:make-cf-data (coerce '(7 8 9) '(vector (unsigned-byte 8)))))
              (dict (d:make-cf-dictionary (list (cons key value)))))
    (is (= 1 (ffi:cf-dictionary-get-count dict)))
    (is (equalp #(7 8 9) (d:cf-data-octets (ffi:cf-dictionary-get-value dict key))))))

(test with-cf-releases-on-a-non-local-exit
  ;; One extra reference is taken, then WITH-CF is left by THROW. If it released as it must, the
  ;; count is back where it was. A 64-byte CFData, not a short string: macOS stores a short
  ;; ASCII CFString as a tagged pointer, whose retain count never changes, and the first version
  ;; of this test passed with the release removed.
  (let ((s (d:make-cf-data (make-array 64 :element-type '(unsigned-byte 8) :initial-element 7))))
    (unwind-protect
         (let ((before (ffi:cf-get-retain-count s)))
           (catch 'out
             (d:with-cf ((ref (d:cf-retain s)))
               (is (cffi:pointer-eq s ref) "CFRetain returns the object it retained")
               (throw 'out nil)))
           (is (= before (ffi:cf-get-retain-count s)) "the extra reference was not released"))
      (d:cf-release s))))

(test a-failing-osstatus-is-a-condition-with-the-os-wording
  (is (eql 0 (d:check-osstatus 0 :probe)))
  (let ((e (handler-case (progn (d:check-osstatus ffi:+err-sec-item-not-found+ :probe) nil)
             (d:osstatus-error (e) e))))
    (is (typep e 'd:osstatus-error))
    (is (eql -25300 (and e (d:darwin-error-code e))))
    (is (search "could not be found" (or (and e (d:darwin-error-message e)) "") :test #'char-equal)
        "expected macOS's wording, got ~S" (and e (d:darwin-error-message e)))
    (is (search "PROBE" (princ-to-string e)) "the report names the operation")))

(test framework-constants-are-read-from-the-framework
  (is (string= "genp" (d:cf-string-to-lisp (d:cf-constant "kSecClassGenericPassword"))))
  (signals d:darwin-error (d:cf-constant "kNoSuchConstantInAnyFramework")))
