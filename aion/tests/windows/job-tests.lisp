;;;; job-tests.lisp --- a kill-on-close job ends its processes when it is closed (#599).
;;;;
;;;; Each test starts its own `ping -n 600 127.0.0.1', a process that runs for about ten
;;;; minutes and needs nothing, and ends whatever it started before it returns. A process that
;;;; is not in the job is the control: it is still running after the job is closed.

(in-package #:aion/windows/tests)

(def-suite jobs :description "Job objects." :in all)
(in-suite jobs)

(defun %start-ping ()
  (sb-ext:run-program "ping" '("-n" "600" "127.0.0.1")
                      :search t :wait nil :input nil :output nil :error nil))

(defun %exited-within-p (process seconds)
  (loop repeat (* seconds 50)
        while (sb-ext:process-alive-p process)
        do (sleep 0.02))
  (not (sb-ext:process-alive-p process)))

(defun %end (process)
  (when (sb-ext:process-alive-p process)
    (sb-ext:process-kill process 9))
  (sb-ext:process-wait process)
  (sb-ext:process-close process))

(test closing-a-job-ends-the-process-in-it-and-not-one-outside-it
  (let ((inside (%start-ping))
        (outside (%start-ping)))
    (unwind-protect
         (let ((job (w:make-kill-on-close-job)))
           (is (w:handle-valid-p job))
           (is-true (w:assign-process-to-job job (sb-ext:process-pid inside)))
           (is-true (sb-ext:process-alive-p inside) "assigning the process ended it")
           (is-true (w:close-handle job))
           (is-true (%exited-within-p inside 5) "the process in the job is still running")
           (is-true (sb-ext:process-alive-p outside)
                    "the process outside the job ended too, so the test cannot tell the job did it"))
      (%end inside)
      (%end outside))))

(test a-process-already-in-a-job-can-be-put-in-a-second-one-which-ends-it
  "#599: the app may itself run in a job, as under some CI runners and terminals, and then the
server is in two. Windows 8 and later allow this. The process is put in an outer job first, and
closing the inner, kill-on-close job ends it while the outer job is still open."
  (let ((process (%start-ping)))
    (unwind-protect
         (w:with-handle (outer (w:make-kill-on-close-job))
           (w:assign-process-to-job outer (sb-ext:process-pid process))
           (let ((inner (w:make-kill-on-close-job)))
             (is-true (w:assign-process-to-job inner (sb-ext:process-pid process)))
             (is-true (sb-ext:process-alive-p process))
             (w:close-handle inner))
           (is-true (%exited-within-p process 5) "closing the inner job did not end the process")
           (is (w:handle-valid-p outer)))
      (%end process))))

(test terminating-a-job-ends-its-process-and-leaves-the-job-open
  (let ((process (%start-ping)))
    (unwind-protect
         (w:with-handle (job (w:make-kill-on-close-job))
           (w:assign-process-to-job job (sb-ext:process-pid process))
           (is-true (w:terminate-job job 7))
           (is-true (%exited-within-p process 5))
           (is (eql 7 (sb-ext:process-exit-code process)))
           (is (w:handle-valid-p job)))
      (%end process))))

(test assigning-a-process-that-cannot-be-opened-signals-win32-error
  "OpenProcess refuses pid 0, the System Idle Process, with ERROR_INVALID_PARAMETER."
  (w:with-handle (job (w:make-kill-on-close-job))
    (handler-case (progn (w:assign-process-to-job job 0)
                         (fail "assigning pid 0 returned"))
      (w:win32-error (e)
        (is (eql 87 (w:windows-error-code e)))
        (is (eq :open-process (w:windows-error-operation e)))))))
