;;;; conditions-tests.lisp --- Win32 codes and HRESULTs become conditions, correctly.
;;;;
;;;; The subtle one is the SIGN. HRESULT is a signed 32-bit value and FAILED(hr) is hr < 0;
;;;; read as unsigned, every failure becomes a large positive number that tests as success.
;;;; That is a one-character mistake with no symptom until a failing call is treated as
;;;; having succeeded, so it is asserted directly.

(in-package #:aion/windows/tests)

(def-suite conditions :description "GetLastError and HRESULT decoding." :in all)
(in-suite conditions)

(test hresult-success-is-the-sign-bit
  "S_OK and S_FALSE are both successes; anything negative is a failure. If HRESULT were
declared unsigned anywhere on the path, the failing cases below would read as success."
  (is-true (w:hresult-succeeded-p 0))            ; S_OK
  (is-true (w:hresult-succeeded-p 1))            ; S_FALSE -- success, and not zero
  (is-false (w:hresult-succeeded-p -2147467263)) ; E_NOTIMPL as a signed int32
  (is-false (w:hresult-succeeded-p -1)))

(test check-hresult-passes-success-through
  (is (= 0 (w:check-hresult 0)))
  (is (= 1 (w:check-hresult 1))))

(test check-hresult-signals-the-named-subclass
  "A caller branching on E_ACCESSDENIED should not have to compare integers."
  (signals w:not-implemented   (w:check-hresult -2147467263))  ; 0x80004001
  (signals w:access-denied     (w:check-hresult -2147024891))  ; 0x80070005
  (signals w:invalid-argument  (w:check-hresult -2147024809))  ; 0x80070057
  (signals w:out-of-memory     (w:check-hresult -2147024882))) ; 0x8007000E

(test an-unnamed-failure-is-still-an-hresult-error
  "Naming only the handful worth branching on is deliberate; everything else must still
arrive as a condition carrying its code, never as a return value."
  (handler-case (progn (w:check-hresult -2147418113) nil)     ; E_UNEXPECTED
    (w:hresult-error (c)
      (is (= -2147418113 (w:hresult-error-hresult c)))
      (is-true (search "0x8000FFFF" (w:windows-error-code c))
               "the printed code should be the unsigned hex Windows documents, got ~S"
               (w:windows-error-code c)))))

(test the-condition-carries-the-operation
  "A bare `access denied' with no operation is the error message this tree exists not to
produce -- the report has to say what was being attempted."
  (handler-case (progn (w:check-hresult -2147024891 :operation :co-create-instance) nil)
    (w:hresult-error (c)
      (is (eq :co-create-instance (w:windows-error-operation c)))
      (is-true (search "CO-CREATE-INSTANCE" (princ-to-string c))
               "the printed condition should name the operation, got: ~A" c))))

(test format-message-returns-the-os-wording
  "Decoding goes through FormatMessage so the text is the OS's own, in the OS's language,
rather than a table we would have to maintain. ERROR_FILE_NOT_FOUND (2) is present on every
Windows install, so this is safe to pin."
  (let ((text (w:error-message-for 2)))
    (is-true (and text (plusp (length text)))
             "FormatMessage returned nothing for ERROR_FILE_NOT_FOUND")))

(test format-message-tolerates-an-unknown-code
  "Windows has nothing to say about most 32-bit integers, and that must be NIL rather than
a fault or an empty-but-present string."
  (finishes (w:error-message-for #x1FFFFFFF)))

(test check-win32-uses-the-callers-success-predicate
  "Win32 has no single success convention: most functions return zero for failure, some
return a count, some a sentinel handle. Guessing here would turn a successful call that
returned 0 into an error, which is the one failure mode this wrapper must not have."
  (is (= 5 (w:check-win32 5 :predicate (lambda (r) (not (zerop r))))))
  (is (= 0 (w:check-win32 0 :predicate #'integerp))
      "a predicate that accepts 0 must let 0 through"))

;;; --- handles ------------------------------------------------------------------

(def-suite handles :description "Handle lifetime and idempotent closing." :in all)
(in-suite handles)

(test a-null-handle-is-not-valid
  (is-false (w:handle-valid-p (w:wrap-handle (cffi:null-pointer) :kind :test))))

(test invalid-handle-value-is-not-valid-either
  "INVALID_HANDLE_VALUE is (HANDLE)-1, NOT null. Testing only for null accepts -1 as a live
handle and hands it to CloseHandle -- a genuine Win32 trap, since the file APIs return -1
where most of the API returns 0."
  (let ((minus-one (cffi:make-pointer (1- (expt 2 (* 8 (cffi:foreign-type-size :pointer)))))))
    (is-false (w:handle-valid-p (w:wrap-handle minus-one :kind :test)))))

(test closing-an-invalid-handle-is-a-no-op-not-a-fault
  "Closing something that was never open must not call CloseHandle at all -- the value may
by then name a DIFFERENT object that something else is still using."
  (is-false (w:close-handle (w:wrap-handle (cffi:null-pointer) :kind :test))))

(test a-real-handle-closes-once-and-only-once
  "The regression test for the review finding on STOP-APARTMENT: it kept a bare pointer and
hand-rolled an unchecked CloseHandle. Routing through a wrapped handle makes the second
close a no-op instead of a decrement against whatever now owns the slot."
  (let* ((raw (cffi:foreign-funcall "CreateEventW" :pointer (cffi:null-pointer)
                                    :int32 0 :int32 0 :pointer (cffi:null-pointer)
                                    :pointer))
         (h (w:wrap-handle raw :kind :test-event)))
    (is-true (w:handle-valid-p h))
    (is-true (w:close-handle h) "the first close should actually close")
    (is-false (w:handle-valid-p h))
    (is-false (w:close-handle h) "the second close must be a no-op, not another CloseHandle")))
