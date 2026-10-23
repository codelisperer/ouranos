;;;; process-tests.lisp --- SPAWN-IN-JOB: a process started suspended in a kill-on-close job (#700).
;;;;
;;;; The child in most tests is another SBCL, run with --eval, because it is the one program every
;;;; machine that runs these tests has. A grandchild is `ping -n 600 127.0.0.1', which runs for
;;;; about ten minutes and needs nothing; each test ends whatever it started before it returns.

(in-package #:aion/windows/tests)

(def-suite processes :description "Starting a process in a job." :in all)
(in-suite processes)

(defun %sbcl () (uiop:native-namestring sb-ext:*runtime-pathname*))

(defun %child-args (form)
  (list "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive" "--eval" form))

(defun %pid-alive-p (pid)
  (let ((out (uiop:run-program (list "tasklist" "/FI" (format nil "PID eq ~D" pid) "/NH")
                               :output :string :ignore-error-status t)))
    (and (search (format nil " ~D " pid) out) t)))

(defun %ends-within-p (pid seconds)
  (loop repeat (* seconds 4)
        while (%pid-alive-p pid)
        do (sleep 0.25))
  (not (%pid-alive-p pid)))

(defun %kill-pid (pid)
  (when (and pid (%pid-alive-p pid))
    (uiop:run-program (list "taskkill" "/PID" (princ-to-string pid) "/F")
                      :output nil :error-output nil :ignore-error-status t)))

(defmacro with-child ((var program arguments &rest keys) &body body)
  "Bind VAR to a JOB-PROCESS for BODY, and end and close it however BODY exits."
  `(let ((,var (w:spawn-in-job ,program ,arguments ,@keys)))
     (unwind-protect (progn ,@body)
       (ignore-errors (w:job-process-terminate ,var))
       (w:job-process-close ,var))))

(defparameter +grandchild-form+
  "(progn (let ((g (sb-ext:run-program \"ping\" (list \"-n\" \"600\" \"127.0.0.1\") :search t :wait nil :output nil))) (format t \"GRANDCHILD ~D~%\" (sb-ext:process-pid g))) (finish-output) (sleep 600))"
  "A child that starts a grandchild, prints its pid, and sleeps.")

(defun %read-grandchild-pid (process)
  (let ((line (read-line (w:job-process-output process))))
    (parse-integer line :start (length "GRANDCHILD "))))

;;; --- the command line ---------------------------------------------------------

(test arguments-reach-the-child-unchanged
  "Each argument is quoted so that the child's C runtime splits the command line back into the
same strings. The child prints its own argv, which is the measurement; the quoting function's
output is not compared with an expected string."
  (let ((arguments (list "plain" "" "two words" "a\"quote" "trailing\\" "dir with space\\"
                         "back\\\\\"slash" "tab	here" "é and ✓")))
    ;; SBCL removes the runtime options it consumes from *POSIX-ARGV*, so the arguments are
    ;; compared with its tail rather than found by position.
    (with-child (p (%sbcl) (append (%child-args "(let ((*print-pretty* nil)) (prin1 sb-ext:*posix-argv*) (terpri) (finish-output))")
                                   arguments)
                 :output :stream :external-format :utf-8)
      (let ((argv (read-from-string (read-line (w:job-process-output p)))))
        (is (equal arguments (last argv (length arguments))))))))

(test quoting-leaves-a-plain-argument-alone-and-quotes-the-rest
  (is (string= "plain" (w:quote-windows-argument "plain")))
  (is (string= "\"\"" (w:quote-windows-argument "")))
  (is (string= "\"a b\"" (w:quote-windows-argument "a b")))
  (is (string= "\"a\\\"b\"" (w:quote-windows-argument "a\"b")))
  (is (string= "\"x y\\\\\"" (w:quote-windows-argument "x y\\"))))

;;; --- streams, exit, environment, directory ----------------------------------------------

(test output-and-error-are-separate-streams-and-the-exit-code-is-read
  (with-child (p (%sbcl) (%child-args "(progn (format t \"out é~%\") (format *error-output* \"err~%\") (finish-output) (finish-output *error-output*) (sb-ext:exit :code 3))")
               :output :stream :error :stream)
    (is (string= "out é" (read-line (w:job-process-output p))))
    (is (string= "err" (read-line (w:job-process-error p))))
    (is-true (w:job-process-wait p 30))
    (is (eql 3 (w:job-process-exit-code p)))
    (is (eq :exited (w:job-process-status p)))))

(test the-exit-code-is-still-read-after-closing
  (let ((p (w:spawn-in-job (%sbcl) (%child-args "(sb-ext:exit :code 4)"))))
    (is-true (w:job-process-wait p 30))
    (w:job-process-close p)
    (is-false (w:job-process-alive-p p))
    (is (eql 4 (w:job-process-exit-code p)))))

(test input-is-a-stream-the-child-reads
  (with-child (p (%sbcl) (%child-args "(progn (format t \"got ~A~%\" (read-line)) (finish-output))")
               :input :stream :output :stream)
    (write-line "hello" (w:job-process-input p))
    (finish-output (w:job-process-input p))
    (is (string= "got hello" (read-line (w:job-process-output p))))))

(test with-no-input-the-child-reads-end-of-file
  (with-child (p (%sbcl) (%child-args "(progn (prin1 (read-line *standard-input* nil :eof)) (terpri) (finish-output))")
               :output :stream)
    (is (string= ":EOF" (read-line (w:job-process-output p))))))

(test the-environment-given-replaces-the-images
  (with-child (p (%sbcl) (%child-args "(progn (prin1 (list (sb-ext:posix-getenv \"AION_SPAWN_TEST\") (sb-ext:posix-getenv \"PATH\"))) (terpri) (finish-output))")
               :output :stream
               :environment (list "AION_SPAWN_TEST=yes é" "SYSTEMROOT=C:\\Windows"))
    (is (equal '("yes é" nil) (read-from-string (read-line (w:job-process-output p)))))))

(test the-child-runs-in-the-directory-given
  (let ((dir (uiop:temporary-directory)))
    (with-child (p (%sbcl) (%child-args "(progn (prin1 (namestring (truename *default-pathname-defaults*))) (terpri) (finish-output))")
                 :output :stream :directory dir)
      (is (equal (namestring (truename dir))
                 (read-from-string (read-line (w:job-process-output p))))))))

(test standard-error-can-be-appended-to-a-file
  (let ((file (uiop:tmpize-pathname (merge-pathnames "aion-spawn-stderr.txt"
                                                     (uiop:temporary-directory)))))
    (unwind-protect
         (progn
           (with-open-file (out file :direction :output :if-exists :supersede)
             (write-line "before" out))
           (with-child (p (%sbcl) (%child-args "(progn (format *error-output* \"from child~%\") (finish-output *error-output*))")
                        :error file)
             (is-true (w:job-process-wait p 30)))
           (is (equal '("before" "from child") (uiop:read-file-lines file))))
      (ignore-errors (delete-file file)))))

(test the-child-has-no-console-window
  "CREATE_NO_WINDOW: the child is a console program with no console, so GetConsoleWindow returns
NULL in it."
  (with-child (p (%sbcl) (%child-args "(progn (prin1 (sb-alien:alien-funcall (sb-alien:extern-alien \"GetConsoleWindow\" (function sb-alien:unsigned-long)))) (terpri) (finish-output))")
               :output :stream)
    (is (eql 0 (read-from-string (read-line (w:job-process-output p)))))))

;;; --- refusals --------------------------------------------------------------------------

(test a-program-that-is-not-found-is-not-started
  (handler-case (progn (w:spawn-in-job "aion-no-such-program-at-all" '("secret-argument"))
                       (fail "it returned"))
    (w:process-not-started (c)
      (is (eq :not-found (w:process-not-started-reason c)))
      (is-false (search "secret-argument" (princ-to-string c))))))

(test a-batch-file-is-refused
  (let ((file (uiop:tmpize-pathname (merge-pathnames "aion-spawn.cmd" (uiop:temporary-directory)))))
    (unwind-protect
         (progn
           (with-open-file (out file :direction :output :if-exists :supersede)
             (write-line "@echo hello" out))
           (handler-case (progn (w:spawn-in-job (uiop:native-namestring file) nil)
                                (fail "it returned"))
             (w:process-not-started (c)
               (is (eq :batch-file (w:process-not-started-reason c))))))
      (ignore-errors (delete-file file)))))

(test find-executable-adds-exe-and-searches-the-path-given
  (let ((dir (uiop:pathname-directory-pathname sb-ext:*runtime-pathname*)))
    (is (equal (uiop:native-namestring (truename sb-ext:*runtime-pathname*))
               (w:find-executable "sbcl" :path (uiop:native-namestring dir))))
    (is (null (w:find-executable "sbcl" :path "C:\\aion-no-such-directory")))))

;;; --- the job ---------------------------------------------------------------------------

(test terminating-ends-the-process-and-the-process-it-started
  (let ((grandchild nil))
    (unwind-protect
         (with-child (p (%sbcl) (%child-args +grandchild-form+) :output :stream)
           (setf grandchild (%read-grandchild-pid p))
           (is-true (%pid-alive-p grandchild))
           (is-true (w:job-process-job p))
           (w:job-process-terminate p 7)
           (is-true (w:job-process-wait p 10))
           (is (eql 7 (w:job-process-exit-code p)))
           (is-true (%ends-within-p grandchild 5) "the grandchild ~D is still running" grandchild))
      (%kill-pid grandchild))))

(test closing-ends-the-process-and-the-process-it-started
  (let ((grandchild nil) (pid nil))
    (unwind-protect
         (let ((p (w:spawn-in-job (%sbcl) (%child-args +grandchild-form+) :output :stream)))
           (setf pid (w:job-process-pid p)
                 grandchild (%read-grandchild-pid p))
           (w:job-process-close p)
           (is-false (w:job-process-alive-p p))
           (is-true (%ends-within-p pid 5) "the child ~D is still running" pid)
           (is-true (%ends-within-p grandchild 5) "the grandchild ~D is still running" grandchild))
      (%kill-pid pid)
      (%kill-pid grandchild))))

(defun %refusing-job-function (pid)
  (declare (ignore pid))
  (error 'w:win32-error :code 5 :message "Access is denied." :operation :assign-process-to-job-object))

(test without-a-job-the-process-it-started-outlives-it
  "The control for the two tests above: with IF-NO-JOB :CONTINUE and a job function that fails,
the child runs outside any job, terminating it ends it alone, and the grandchild keeps running."
  (let ((grandchild nil))
    (unwind-protect
         (multiple-value-bind (p failure)
             (w:spawn-in-job (%sbcl) (%child-args +grandchild-form+) :output :stream
                             :job-function '%refusing-job-function :if-no-job :continue)
           (unwind-protect
                (progn
                  (is (typep failure 'w:win32-error))
                  (is (null (w:job-process-job p)))
                  (setf grandchild (%read-grandchild-pid p))
                  (w:job-process-terminate p)
                  (is-true (w:job-process-wait p 10))
                  (sleep 1)
                  (is-true (%pid-alive-p grandchild) "the grandchild ended without a job to end it"))
             (w:job-process-close p)))
      (%kill-pid grandchild))))

(test a-job-failure-with-if-no-job-error-leaves-no-process-running
  "The process is ended before it has run, so the pid the job function saw is gone."
  (let ((seen nil))
    (handler-case
        (progn (w:spawn-in-job (%sbcl) (%child-args "(sleep 600)")
                               :job-function (lambda (pid) (setf seen pid)
                                               (%refusing-job-function pid)))
               (fail "it returned"))
      (w:win32-error (e)
        (is (eql 5 (w:windows-error-code e)))))
    (is-true seen)
    (is-true (%ends-within-p seen 5) "the refused process ~D is still running" seen)))

;;; --- the image dying -------------------------------------------------------------------

(defun %tree-registry ()
  "A CL_SOURCE_REGISTRY entry naming this tree, so a child image loads the same aion/windows."
  (let ((tree (uiop:pathname-parent-directory-pathname (asdf:system-source-directory :aion))))
    (format nil "~A//;" (substitute #\/ #\\ (string-right-trim "/\\" (uiop:native-namestring tree))))))

(defun %image-with-child (job-keys)
  "Start an SBCL image that loads aion/windows, starts a child with SPAWN-IN-JOB and JOB-KEYS, a
string of extra keyword arguments, and sleeps. Returns (values IMAGE CHILD-PID GRANDCHILD-PID)
once the image has printed both pids. Its output goes to a file, which it returns fourth."
  (let* ((log (uiop:tmpize-pathname (merge-pathnames "aion-spawn-image.txt" (uiop:temporary-directory))))
         (form (format nil "(let ((p (aion/windows:spawn-in-job ~S (list ~{~S~^ ~}) :output :stream ~A))) (format t \"CHILD ~~D~~%\" (aion/windows:job-process-pid p)) (format t \"~~A~~%\" (read-line (aion/windows:job-process-output p))) (finish-output) (sleep 600))"
                       (%sbcl) (%child-args +grandchild-form+) job-keys))
         (image (uiop:launch-program
                 (list (%sbcl) "--dynamic-space-size" "1024" "--noinform" "--no-userinit" "--no-sysinit"
                       "--non-interactive"
                       "--eval" "(require :asdf)"
                       "--eval" (format nil "(load ~S)" (uiop:native-namestring
                                                         (merge-pathnames "quicklisp/setup.lisp"
                                                                          (user-homedir-pathname))))
                       "--eval" "(let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :aion/windows))"
                       "--eval" "(defun %refuse (pid) (declare (ignore pid)) (error \"no job\"))"
                       "--eval" form)
                 :output log :error-output :output :if-output-exists :supersede
                 :environment (cons (format nil "CL_SOURCE_REGISTRY=~A" (%tree-registry))
                                    (remove-if (lambda (e) (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e))
                                               (sb-ext:posix-environ))))))
    (flet ((pid-after (prefix lines)
             (let ((line (find-if (lambda (l) (uiop:string-prefix-p prefix l)) lines)))
               (and line (parse-integer line :start (length prefix))))))
      (loop repeat 480
            for lines = (ignore-errors (uiop:read-file-lines log))
            for child = (pid-after "CHILD " lines)
            for grandchild = (pid-after "GRANDCHILD " lines)
            when (and child grandchild) do (return-from %image-with-child (values image child grandchild log))
            while (uiop:process-alive-p image)
            do (sleep 0.25))
      (values image nil nil log))))

(defun %end-image (image log &rest pids)
  (when (uiop:process-alive-p image) (uiop:terminate-process image :urgent t))
  (ignore-errors (uiop:wait-process image))
  (dolist (pid pids) (%kill-pid pid))
  (ignore-errors (delete-file log)))

(test killing-the-image-ends-the-child-and-the-process-it-started
  "#700: the image holding the job is ended with taskkill /F, so no exit hook runs. Windows closes
the job's last handle as the image ends, and that ends both."
  (multiple-value-bind (image child grandchild log) (%image-with-child "")
    (unwind-protect
         (progn
           (is-true child "the image did not report its child: ~S"
                    (ignore-errors (uiop:read-file-lines log)))
           (when child
             (is-true (%pid-alive-p grandchild))
             (uiop:run-program (list "taskkill" "/PID" (princ-to-string (uiop:process-info-pid image)) "/F")
                               :output nil :error-output nil :ignore-error-status t)
             (is-true (%ends-within-p child 5) "the child ~D outlived the image" child)
             (is-true (%ends-within-p grandchild 5) "the grandchild ~D outlived the image" grandchild)))
      (%end-image image log child grandchild))))

(test killing-the-image-leaves-a-child-outside-a-job-running
  "The control for the test above: the same image, with the child outside any job."
  (multiple-value-bind (image child grandchild log)
      (%image-with-child ":job-function '%refuse :if-no-job :continue")
    (unwind-protect
         (progn
           (is-true child "the image did not report its child: ~S"
                    (ignore-errors (uiop:read-file-lines log)))
           (when child
             (uiop:run-program (list "taskkill" "/PID" (princ-to-string (uiop:process-info-pid image)) "/F")
                               :output nil :error-output nil :ignore-error-status t)
             (sleep 2)
             (is-true (%pid-alive-p child) "the child ended without a job to end it")
             (is-true (%pid-alive-p grandchild) "the grandchild ended without a job to end it")))
      (%end-image image log child grandchild))))
