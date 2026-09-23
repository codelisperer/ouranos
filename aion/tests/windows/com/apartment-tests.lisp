;;;; apartment-tests.lisp --- the STA thread behaves like one.
;;;;
;;;; cl-win32ole's second defect after VARIANT: CoInitialize ran once at load time on
;;;; whichever thread happened to load the file, so every other thread got
;;;; CO_E_NOTINITIALIZED. The apartment being a real, owned, restartable thing -- rather
;;;; than a side effect of load order -- is what these check.

(in-package #:aion/windows/com/tests)

(def-suite apartment :description "The dedicated STA thread and its pump." :in all)
(in-suite apartment)

(test apartment-starts-and-reports-running
  (com:start-apartment)
  (is-true (com:apartment-running-p)))

(test work-runs-on-the-apartment-thread-not-the-callers
  "The whole point: a COM object belongs to the apartment that created it, so the work has
to happen THERE. If this ran on the caller's thread the objects would belong to whichever
thread happened to ask."
  (com:start-apartment)
  (let ((caller sb-thread:*current-thread*)
        (ran-on (com:in-apartment () sb-thread:*current-thread*)))
    (is (not (eq caller ran-on))
        "the work ran on the caller's thread, so there is no apartment")))

(test the-apartment-thread-is-the-same-one-every-time
  "An apartment that moved between threads would be no apartment at all -- objects would be
stranded on whichever thread created them."
  (com:start-apartment)
  (let ((a (com:in-apartment () sb-thread:*current-thread*))
        (b (com:in-apartment () sb-thread:*current-thread*)))
    (is (eq a b))))

(test values-come-back-from-the-apartment
  (com:start-apartment)
  (is (= 7 (com:in-apartment () (+ 3 4))))
  (is (equal '(1 2) (multiple-value-list (com:in-apartment () (values 1 2))))))

(test an-error-in-the-apartment-is-resignalled-in-the-caller
  "It must not kill the apartment thread. If it did, the NEXT caller would block forever on
a semaphore nobody is left to signal -- a hang with no error anywhere, which is the worst
failure this design can have."
  (com:start-apartment)
  (signals simple-error (com:in-apartment () (error "deliberate")))
  (is-true (com:apartment-running-p))
  (is (= 5 (com:in-apartment () 5))
      "the apartment stopped serving after an error"))

(test calling-from-inside-the-apartment-does-not-deadlock
  "Re-entering must be a direct call. Queueing it would make the thread wait on a semaphore
only it could signal."
  (com:start-apartment)
  (is (= 9 (com:in-apartment () (com:in-apartment () 9)))))

(test the-apartment-restarts-after-being-stopped
  "Stop is not one-way. A REPL that stops the apartment and calls again should get one back
rather than a dead handle."
  (com:start-apartment)
  (com:stop-apartment)
  (is-false (com:apartment-running-p))
  (is (= 3 (com:in-apartment () 3)) "a call should start a fresh apartment")
  (is-true (com:apartment-running-p)))

(test stopping-twice-is-safe
  "The wakeup event is a real Windows HANDLE. Stopping twice used to run an unchecked
CloseHandle on a handle that was already closed -- which is not merely untidy: by then the
value may name a DIFFERENT object that something else in the image still holds."
  (com:start-apartment)
  (is-true (com:stop-apartment))
  (finishes (com:stop-apartment))
  (is-false (com:apartment-running-p))
  ;; and it still comes back afterwards
  (is (= 1 (com:in-apartment () 1))))

;;; --- the extension surface (pre-publication issue 201) ---------------------------------------------
;;;
;;; The finding these come from: the first external consumer of this binding -- a typelib
;;; spike -- could not get an interface pointer out of a COM-OBJECT without reaching into
;;; the package with `::'. Needing an internal symbol on day one is the signal.
;;;
;;; These tests use SINGLE-COLON references throughout, deliberately. That is the whole
;;; assertion: everything required to reach an interface this binding does not wrap yet is
;;; exported. A test written with `::' would pass while the gap remained.

(def-suite extension :description "Extending the binding without reaching into it." :in all)
(in-suite extension)

(test an-interface-pointer-is-reachable-from-outside
  "COM-OBJECT-POINTER is how a caller calls something not wrapped here yet."
  (com:with-com-object (o (com:create-object "Scripting.Dictionary"))
    (let ((p (com:com-object-pointer o)))
      (is-false (cffi:null-pointer-p p) "a live object should have a non-null interface"))))

(test a-caller-can-call-a-vtable-slot-it-was-not-given-a-wrapper-for
  "The real test of the extension surface: reach IDispatch::GetTypeInfo (slot 4), which this
binding does not wrap, using only exported symbols -- then adopt the result with
WRAP-INTERFACE and let the normal machinery release it.

NOTE THE SHAPE. The COM work happens inside IN-APARTMENT and the assertions happen OUT here,
because the apartment is a different THREAD and FiveAM keeps its current-test in a special
binding that exists only on the thread running the suite. An `is' inside the apartment fails
with an unbound IT.BESE.FIVEAM::CURRENT-TEST -- which looks like a COM fault and is not one.
Anything testing this binding has to be written this way."
  (com:with-com-object (o (com:create-object "Scripting.Dictionary"))
    (multiple-value-bind (hr adopted)
        (com:in-apartment ()
          (let ((this (com:com-object-pointer o)))
            (cffi:with-foreign-object (out :pointer)
              (setf (cffi:mem-ref out :pointer) (cffi:null-pointer))
              (let ((hr (cffi:foreign-funcall-pointer
                         (ffi:vtable-slot this 4) ()          ; IDispatch::GetTypeInfo
                         :pointer this :uint32 0 :uint32 0 :pointer out :int32)))
                (values hr (let ((ti (cffi:mem-ref out :pointer)))
                             (unless (cffi:null-pointer-p ti)
                               ;; WRAP-INTERFACE adopts the reference.
                               (com:wrap-interface ti))))))))
      (is-true (w:hresult-succeeded-p hr)
               "GetTypeInfo through the exported vtable accessor failed: ~8,'0X"
               (logand hr #xFFFFFFFF))
      (is-true (com:com-object-p adopted) "the returned interface should be adoptable")
      (when (com:com-object-p adopted)
        (is-true (com:release adopted) "the adopted interface should release once")
        (is-false (com:release adopted) "and only once")))))

(test wrap-interface-refuses-nothing-and-releases-cleanly
  "A null interface must not blow up in RELEASE -- adopting one is a caller error, not a fault."
  (let ((w (com:wrap-interface (cffi:null-pointer))))
    (is-true (com:com-object-p w))
    (is-false (com:release w) "releasing a null interface should be a no-op")))
