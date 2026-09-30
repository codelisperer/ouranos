;;;; desktop-window-tests.lisp --- the window ends with its backend, and an app can close itself (#355).
;;;;
;;;; A stand-in window is a second SBCL that sleeps: RUN-APP only needs a process to wait on,
;;;; and a real hyperion-view would open a window on the machine running the tests.

(in-package #:hyperion/tests)

(def-suite desktop-window :description "hyperion/desktop: the window's lifetime (#355)." :in hyperion)
(in-suite desktop-window)

(defun %sbcl ()
  (uiop:native-namestring sb-ext:*runtime-pathname*))

(defun %stand-in-window (&optional (seconds 120))
  "A process to stand in for the launcher: an SBCL that sleeps for SECONDS."
  (uiop:launch-program (list (%sbcl) "--noinform" "--no-userinit" "--no-sysinit"
                             "--non-interactive" "--eval" (format nil "(sleep ~D)" seconds))))

(defun %pid-alive-p (pid)
  (if (uiop:os-windows-p)
      (search (format nil " ~D " pid)
              (uiop:run-program (list "tasklist" "/FI" (format nil "PID eq ~D" pid) "/NH")
                                :output :string :ignore-error-status t))
      (zerop (nth-value 2 (uiop:run-program (list "kill" "-0" (princ-to-string pid))
                                            :ignore-error-status t)))))

(defun %kill-pid (pid)
  (if (uiop:os-windows-p)
      (uiop:run-program (list "taskkill" "/F" "/PID" (princ-to-string pid))
                        :ignore-error-status t :output nil :error-output nil)
      (uiop:run-program (list "kill" "-9" (princ-to-string pid))
                        :ignore-error-status t :output nil :error-output nil)))

(test request-close-closes-the-window-and-the-wait-returns
  (let* ((window (%stand-in-window))
         (thread (sb-thread:make-thread
                  (lambda () (hyperion/desktop::%wait-for-window window) :returned))))
    (unwind-protect
         (progn
           (loop repeat 100 until hyperion/desktop::*window* do (sleep 0.05))
           (is (eq window hyperion/desktop::*window*) "the wait records the window it waits on")
           (is-true (hyperion/desktop:request-close))
           (is (eq :returned (sb-thread:join-thread thread :default :still-waiting :timeout 10))
               "the wait returns once the window is closed")
           (is-false (uiop:process-alive-p window))
           (is (null hyperion/desktop::*window*))
           (is-false (hyperion/desktop:request-close) "with no window, there is nothing to close"))
      (when (uiop:process-alive-p window) (uiop:terminate-process window :urgent t)))))

(test leaving-the-wait-another-way-stops-the-window
  (let ((window (%stand-in-window)))
    (unwind-protect
         (progn
           (catch 'left
             (let ((me sb-thread:*current-thread*))
               (sb-thread:make-thread
                (lambda ()
                  (sleep 0.5)
                  (sb-thread:interrupt-thread me (lambda () (throw 'left nil)))))
               (hyperion/desktop::%wait-for-window window)))
           (is-false (uiop:process-alive-p window)
                     "a throw out of the wait must not leave the window running"))
      (when (uiop:process-alive-p window) (uiop:terminate-process window :urgent t)))))

(defun %exit-from-another-thread (wait-form)
  "Run a child SBCL that starts a stand-in window, calls SB-EXT:EXIT from a second thread one
second later, and meanwhile runs WAIT-FORM, a string, on its main thread with W bound to the
window. Returns (values WINDOW-PID SECONDS-FROM-EXIT-TO-END). Output goes to a file, not a
pipe, because the window inherits the child's output and would hold a pipe open."
  (let* ((tree (uiop:pathname-parent-directory-pathname
                (asdf:system-source-directory :hyperion)))
         (sep (if (uiop:os-windows-p) ";" ":"))
         ;; `//' makes the entry a whole tree. Forward slashes on every OS: ASDF reads them on
         ;; Windows too, and a backslash before `//' would be read as part of the name.
         (registry (format nil "~A//~A"
                           (substitute #\/ #\\ (string-right-trim "/\\" (uiop:native-namestring tree)))
                           sep))
         (log (uiop:tmpize-pathname (merge-pathnames "hyperion-exit-child.txt"
                                                     (uiop:temporary-directory)))))
    (unwind-protect
         (progn
           (uiop:run-program
            (list (%sbcl) "--dynamic-space-size" "4096" "--noinform" "--no-userinit"
                  "--no-sysinit" "--non-interactive"
                  "--eval" "(require :asdf)"
                  "--eval" (format nil "(load ~S)" (uiop:native-namestring
                                                    (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
                  "--eval" "(let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :hyperion/desktop))"
                  "--eval" "(setf sb-ext:*exit-timeout* 3)"
                  "--eval" (format nil "(let ((w (uiop:launch-program (list ~S \"--noinform\" \"--no-userinit\" \"--no-sysinit\" \"--non-interactive\" \"--eval\" \"(sleep 120)\")))) (format t \"WINDOW-PID ~~D~~%\" (uiop:process-info-pid w)) (finish-output) (sb-thread:make-thread (lambda () (sleep 1) (format t \"EXIT-AT ~~D~~%\" (get-universal-time)) (finish-output) (sb-ext:exit :code 0))) ~A)"
                                   (%sbcl) wait-form))
            :output log :error-output :output :if-output-exists :supersede
            :ignore-error-status t
            :environment (cons (format nil "CL_SOURCE_REGISTRY=~A" registry)
                               (remove-if (lambda (e) (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e))
                                          (sb-ext:posix-environ))))
           (let* ((ended (get-universal-time))
                  (lines (uiop:read-file-lines log))
                  (pid-line (find-if (lambda (l) (uiop:string-prefix-p "WINDOW-PID " l)) lines))
                  (exit-line (find-if (lambda (l) (uiop:string-prefix-p "EXIT-AT " l)) lines)))
             (values (and pid-line (parse-integer pid-line :start 11))
                     (and exit-line (- ended (parse-integer exit-line :start 8)))
                     lines)))
      (ignore-errors (delete-file log)))))

(test exiting-from-another-thread-ends-the-window-with-the-process
  ;; The window outlived its backend: on Windows the main thread, blocked waiting on the
  ;; launcher, could not be interrupted to unwind, and SBCL waited out *EXIT-TIMEOUT* before
  ;; ending the process without it. The control runs the same child with that blocking wait.
  (multiple-value-bind (pid seconds lines)
      (%exit-from-another-thread "(hyperion/desktop::%wait-for-window w)")
    (unwind-protect
         (progn
           (is (integerp pid) "the child reported its window: ~S" lines)
           (is (and seconds (< seconds 3))
               "the process ended ~A s after the exit, which is at least *EXIT-TIMEOUT* (3 s) if the main thread could not unwind"
               seconds)
           (is (and pid (not (%pid-alive-p pid))) "the window must end with the process"))
      (when (and pid (%pid-alive-p pid)) (%kill-pid pid))))
  (let ((pid (%exit-from-another-thread "(uiop:wait-process w)")))
    (unwind-protect
         (is (and pid (%pid-alive-p pid))
             "the control: with a blocking wait, the window outlives the process")
      (when (and pid (%pid-alive-p pid)) (%kill-pid pid)))))
