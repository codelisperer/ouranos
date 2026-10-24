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

(defun %in-a-deferred-step (thunk)
  "Call THUNK inside SB-SYS:WITHOUT-INTERRUPTS with an interrupt to this thread deferred, the
state in which a thread made by THUNK inherits a blocked mask on a build without safepoints (#541).
As in aion/dynamic's tests: another thread interrupts this one, and the interrupt waits for the
step to end."
  (sb-sys:without-interrupts
    (let ((me sb-thread:*current-thread*))
      (sb-thread:join-thread
       ;; THREAD-LIFETIME: scoped -- it sends one interrupt and is joined here.
       ;; INTERRUPTS: not needed -- it only sends an interrupt, and is joined at once.
       (sb-thread:make-thread (lambda () (sb-thread:interrupt-thread me (lambda () nil)))
                              :name "deferred-step interrupter"))
      (sleep 0.2))
    (funcall thunk)))

(test an-apartment-started-while-an-interrupt-is-deferred-can-be-interrupted
  "#896. The apartment thread unblocks interrupts first, so it can be interrupted even when it was
started inside a step while an interrupt to the starter was deferred.

This system runs only on Windows, whose SBCL is a :SB-SAFEPOINT build: there a new thread does
not take its creator's mask, so this passes with or without the call, and the call is there so the
thread is correct on any build. The interrupt is sent while the thread runs Lisp, inside a call
that loops until the interrupt sets a flag. On a :SB-SAFEPOINT build an interrupt is delivered
only when a thread returns from foreign code, and between calls the apartment thread waits in
MsgWaitForMultipleObjects, so an interrupt sent then would wait for the next call or message, as
in aion/uv's loop-thread test."
  (com:stop-apartment)
  (%in-a-deferred-step #'com:start-apartment)
  (let* ((sta (com::apartment-thread com::*apartment*))
         (inside (sb-thread:make-semaphore))
         (flag nil)
         (result nil)
         ;; THREAD-LIFETIME: scoped -- it makes one call into the apartment and is joined below.
         ;; INTERRUPTS: not needed -- nothing interrupts it, and it is joined in this test.
         (caller (sb-thread:make-thread
                  (lambda ()
                    (setf result (com:in-apartment ()
                                   (sb-thread:signal-semaphore inside)
                                   (loop until flag do (sleep 0.01))
                                   :interrupted)))
                  :name "apartment caller")))
    (is-true (sb-thread:wait-on-semaphore inside :timeout 10) "the call did not reach the apartment")
    (sb-thread:interrupt-thread sta (lambda () (setf flag t)))
    (is-true (sb-thread:join-thread caller :default nil :timeout 5)
             "the interrupt did not reach the apartment thread")
    (unless flag (setf flag t))
    (sb-thread:join-thread caller :default nil :timeout 10)
    (is (eq :interrupted result))))

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

;;; --- exit (#484) ------------------------------------------------------------------
;;;
;;; The STA thread waits in a foreign call SBCL cannot interrupt, so a process that had started
;;; an apartment used to wait out the whole of SB-EXT:*EXIT-TIMEOUT* when it exited. These run a
;;; child image, with the timeout set to 5 s so the control is quick, and time it from the
;;; moment it is about to exit to the moment it has ended.

(defun %exit-seconds (&key keep-hook)
  "Start a child image that loads aion/windows/com, starts the apartment and exits, and return
(values SECONDS EXIT-CODE): the seconds from its last line of output to the end of the process,
and its exit status, so that a child the hook made end quickly by crashing does not pass for one
that exited cleanly. Unless KEEP-HOOK, the child first removes the exit hook #484 added, which is
the code before #484."
  (let ((process (uiop:launch-program
                  (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                        "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                        "--eval" "(require :asdf)"
                        "--eval" (format nil "(load ~S)"
                                         (uiop:native-namestring
                                          (merge-pathnames "quicklisp/setup.lisp"
                                                           (user-homedir-pathname))))
                        "--eval" "(let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :aion/windows/com))"
                        "--eval" "(setf sb-ext:*exit-timeout* 5)"
                        "--eval" (if keep-hook
                                     "nil"
                                     "(setf sb-ext:*exit-hooks* (remove 'aion/windows/com::%stop-apartment-at-exit sb-ext:*exit-hooks*))")
                        "--eval" "(aion/windows/com:start-apartment)"
                        "--eval" "(progn (format t \"EXITING~%\") (finish-output) (sb-ext:exit :code 0))")
                  :output :stream :error-output nil)))
    (unwind-protect
         (progn
           (loop for line = (read-line (uiop:process-info-output process) nil)
                 until (or (null line) (search "EXITING" line)))
           (let* ((start (get-internal-real-time))
                  (code (uiop:wait-process process)))
             (values (/ (- (get-internal-real-time) start) internal-time-units-per-second 1.0)
                     code)))
      (when (uiop:process-alive-p process) (uiop:terminate-process process :urgent t)))))

(test a-process-that-started-an-apartment-exits-without-waiting-for-it
  "The exit hook stops the apartment before SBCL waits for its threads. The control is the same
child with the hook removed: it waits out the 5 s *EXIT-TIMEOUT*."
  (multiple-value-bind (with-hook with-code) (%exit-seconds :keep-hook t)
    (multiple-value-bind (without without-code) (%exit-seconds)
      (is (eql 0 with-code) "with the exit hook, the child exited with status ~A" with-code)
      (is (< with-hook 3) "with the exit hook, exit took ~,1F s" with-hook)
      (is (eql 0 without-code) "control: without the hook, the child exited with status ~A"
          without-code)
      (is (>= without 4.5) "control: without the hook, exit took ~,1F s" without))))
