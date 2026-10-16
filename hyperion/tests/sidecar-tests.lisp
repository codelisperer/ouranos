;;;; sidecar-tests.lisp --- dev sidecars start, report a value, and stop with the server (#700).
;;;;
;;;; Every sidecar here is a child SBCL started with --eval, because it is the one program every
;;;; machine running these tests has. Each test stops what it started before it returns.

(cl:defpackage #:hyperion/sidecar/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:sc #:hyperion/sidecar)
                    (#:dev #:hyperion/dev)
                    (#:srv #:hyperion/server)
                    (#:ports #:hyperion/test-ports))
  (:export #:run-tests))

(in-package #:hyperion/sidecar/tests)

(def-suite sidecars :description "hyperion/sidecar (#700).")
(in-suite sidecars)

(defun run-tests ()
  (aion/log:level! :warn)
  (fiveam:run! 'sidecars))

;;; --- helpers ------------------------------------------------------------------------------

(defun %sbcl () (uiop:native-namestring sb-ext:*runtime-pathname*))

(defun %command (form &rest extra)
  "A sidecar command that runs FORM in a fresh SBCL. EXTRA arguments come after it, where FORM can
read them from SB-EXT:*POSIX-ARGV*."
  (append (list (%sbcl) "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                "--eval" form)
          extra))

(defparameter +ready-form+
  "(progn (format t \"starting~%ready token=tok-~D~%\" (random 1000000000 (make-random-state t))) (finish-output) (sleep 600))"
  "A sidecar that prints a token made from its pid, then sleeps.")

(defun %pid-alive-p (pid)
  #+win32 (let ((out (uiop:run-program (list "tasklist" "/FI" (format nil "PID eq ~D" pid) "/NH")
                                       :output :string :ignore-error-status t)))
            (and (search (format nil " ~D " pid) out) t))
  #-win32 (eql 0 (sb-unix:unix-kill pid 0)))

(defun %ends-within-p (pid seconds)
  (loop repeat (* seconds 4) while (%pid-alive-p pid) do (sleep 0.25))
  (not (%pid-alive-p pid)))

(defun %kill-pid (pid)
  (when (and pid (%pid-alive-p pid))
    #+win32 (uiop:run-program (list "taskkill" "/PID" (princ-to-string pid) "/F")
                              :output nil :error-output nil :ignore-error-status t)
    #-win32 (sb-unix:unix-kill pid 9)))

(defun %fresh-directory (prefix)
  "A directory pathname under the temporary directory that does not exist yet."
  (loop for candidate = (merge-pathnames (format nil "~A-~36R/" prefix (random (expt 36 8) (make-random-state t)))
                                         (uiop:temporary-directory))
        unless (probe-file candidate) return candidate))

(defun %pid-of (name)
  (let ((s (gethash name sc::*running*)))
    (and s (sc::sidecar-process s) (sc::%pid (sc::sidecar-process s)))))

(defmacro with-sidecars ((set names &rest keys) &body body)
  `(let ((,set (sc:start-sidecars ,names ,@keys)))
     (unwind-protect (progn ,@body)
       (sc:stop-sidecars ,set))))

(defmacro with-captured-log ((stream &key (log-level :info)) &body body)
  "Run BODY with the log at LOG-LEVEL going to STREAM, then put back what was there."
  (let ((appenders (gensym)) (level (gensym)) (layout (gensym)))
    `(let ((,appenders (copy-list (log4cl:logger-appenders log4cl:*root-logger*)))
           (,level (log4cl:logger-log-level log4cl:*root-logger*))
           (,layout aion/log:*layout*))
       (unwind-protect
            (progn (aion/log:setup :env :dev :level ,log-level :stream ,stream)
                   ,@body)
         (log4cl:remove-all-appenders log4cl:*root-logger*)
         (dolist (a ,appenders) (log4cl:add-appender log4cl:*root-logger* a))
         (log4cl:set-log-level log4cl:*root-logger* ,level)
         (setf aion/log:*layout* ,layout)))))

;;; --- declaring --------------------------------------------------------------------------

(test token-after-takes-the-text-after-the-marker-up-to-a-space
  (let ((f (sc:token-after "secret is ")))
    (is (equal "whsec_abc" (funcall f "> Your webhook signing secret is whsec_abc (^C to quit)")))
    (is (null (funcall f "nothing here")))
    (is (null (funcall f "secret is ")))))

(test a-command-must-be-a-list-of-strings
  (signals error (sc:register-sidecar :test-bad :command "not a list"))
  (signals error (sc:register-sidecar :test-bad :command '())))

(test an-environment-value-must-be-a-string
  (signals error (sc:register-sidecar :test-bad :command '("x") :environment '(("A" . :inherit))))
  (signals error (sc:register-sidecar :test-bad :command '("x") :environment '(("A" . nil))))
  (signals error (sc:register-sidecar :test-bad :command '("x") :environment '((:a . "v"))))
  (signals error (sc:register-sidecar :test-bad :command '("x") :environment :inherit))
  (is (eq :test-good (sc:register-sidecar :test-good :command '("x") :environment '(("A" . "v"))))))

;;; --- starting, reading the value, stopping ------------------------------------------------

(test the-value-is-captured-and-stopping-ends-the-sidecar
  (sc:define-sidecar :test-plain :command (%command +ready-form+) :ready (sc:token-after "token="))
  (let (pid)
    (with-sidecars (set '(:test-plain))
      (setf pid (%pid-of :test-plain))
      (is-true (%pid-alive-p pid))
      (is (eq :ready (sc:sidecar-status :test-plain)))
      (is (stringp (sc:sidecar-value :test-plain)))
      (is (uiop:string-prefix-p "tok-" (sc:sidecar-value :test-plain))))
    (is-true (%ends-within-p pid 5) "the sidecar ~D is still running after STOP-SIDECARS" pid)
    (is (null (sc:sidecar-value :test-plain)))
    (is (eq :not-started (sc:sidecar-status :test-plain)))))

(test a-secret-value-is-held-as-a-secret
  (sc:define-sidecar :test-secret :command (%command +ready-form+) :ready (sc:token-after "token=")
                     :secret t)
  (with-sidecars (set '(:test-secret))
    (let ((v (sc:sidecar-value :test-secret)))
      (is-true (aion/secret:secretp v))
      (is (uiop:string-prefix-p "tok-" (aion/secret:reveal v)))
      (is-false (search "tok-" (princ-to-string v))))))

(test a-debug-log-of-the-output-never-contains-the-captured-value
  "Every output line is logged at debug level, including the one :READY captures the secret from,
so the log records each line's length and never its text."
  (sc:define-sidecar :test-debug-log :command (%command +ready-form+) :ready (sc:token-after "token=")
                     :secret t)
  (let* ((value nil)
         (log (with-output-to-string (out)
                (with-captured-log (out :log-level :debug)
                  (with-sidecars (set '(:test-debug-log))
                    (setf value (aion/secret:reveal (sc:sidecar-value :test-debug-log))))))))
    (is (uiop:string-prefix-p "tok-" value))
    (is-true (search "hyperion/sidecar: output" log) "no output line was logged at debug level")
    (is-false (search value log) "the captured value ~S is in the debug log" value)))

(test a-sidecar-with-no-ready-function-is-ready-once-started
  (sc:define-sidecar :test-noready :command (%command "(sleep 600)"))
  (with-sidecars (set '(:test-noready))
    (is (eq :ready (sc:sidecar-status :test-noready)))
    (is (null (sc:sidecar-value :test-noready)))))

(test port-is-substituted-into-the-command
  (sc:define-sidecar :test-port
                     :command (%command "(progn (format t \"port=~A~%\" (car (last sb-ext:*posix-argv*))) (finish-output) (sleep 600))"
                                        "--forward-to" "localhost:{port}/hooks")
                     :ready (sc:token-after "port="))
  (with-sidecars (set '(:test-port) :port 43210)
    (is (equal "localhost:43210/hooks" (sc:sidecar-value :test-port)))))

(test a-port-placeholder-without-a-port-is-refused
  (sc:define-sidecar :test-port-missing :command (%command "(sleep 1)" "{port}"))
  (handler-case (progn (sc:start-sidecars '(:test-port-missing)) (fail "it started"))
    (sc:sidecar-not-started (c)
      (is (eq :no-port (sc:sidecar-not-started-reason c))))))

(test the-environment-is-added-to-the-images
  (sc:define-sidecar :test-env
                     :command (%command "(progn (format t \"env=~A~%\" (sb-ext:posix-getenv \"HYPERION_SIDECAR_TEST\")) (finish-output) (sleep 600))")
                     :environment '(("HYPERION_SIDECAR_TEST" . "from-declaration"))
                     :ready (sc:token-after "env="))
  (with-sidecars (set '(:test-env))
    (is (equal "from-declaration" (sc:sidecar-value :test-env)))))

;;; --- failing to start ---------------------------------------------------------------------

(test readiness-that-times-out-signals-and-leaves-nothing-running
  (sc:define-sidecar :test-slow :command (%command "(progn (format t \"pid=~D~%\" (funcall (intern \"UNIX-GETPID\" \"SB-UNIX\"))) (finish-output) (sleep 600))")
                     :ready (sc:token-after "never-printed=") :ready-timeout 3)
  (let ((c (handler-case (progn (sc:start-sidecars '(:test-slow)) nil)
             (sc:sidecar-not-ready (c) c))))
    (is-true c "no SIDECAR-NOT-READY was signalled")
    (when c
      (is (eq :test-slow (sc:sidecar-not-ready-name c)))
      (is (eq :timeout (sc:sidecar-not-ready-reason c)))))
  (is (eq :not-started (sc:sidecar-status :test-slow))))

(test a-sidecar-that-exits-before-it-is-ready-signals-with-its-exit-code
  (sc:define-sidecar :test-exits :command (%command "(sb-ext:exit :code 3)")
                     :ready (sc:token-after "never=") :ready-timeout 30)
  (handler-case (progn (sc:start-sidecars '(:test-exits)) (fail "it started"))
    (sc:sidecar-not-ready (c)
      (is (eq :exited (sc:sidecar-not-ready-reason c)))
      (is (eql 3 (sc:sidecar-not-ready-exit-code c))))))

(test a-missing-program-is-a-warning-unless-required
  (sc:define-sidecar :test-missing :command '("hyperion-no-such-program-xyz" "secret-arg"))
  (let ((log (make-string-output-stream)))
    (with-captured-log (log)
      (with-sidecars (set '(:test-missing))
        (is (eq :not-started (sc:sidecar-status :test-missing)))))
    (let ((logged (get-output-stream-string log)))
      (is-true (search "sidecar :test-missing not started: hyperion-no-such-program-xyz not found on PATH"
                       logged)
               "the log said ~S" logged)
      (is-false (search "secret-arg" logged))))
  (sc:define-sidecar :test-missing-required :command '("hyperion-no-such-program-xyz")
                     :required t)
  (handler-case (progn (sc:start-sidecars '(:test-missing-required)) (fail "it started"))
    (sc:sidecar-not-started (c)
      (is (eq :not-found (sc:sidecar-not-started-reason c))))))

(test a-failure-stops-the-sidecars-started-before-it
  (sc:define-sidecar :test-first :command (%command +ready-form+) :ready (sc:token-after "token="))
  (sc:define-sidecar :test-second :command (%command "(sb-ext:exit :code 2)")
                     :ready (sc:token-after "never=") :ready-timeout 30)
  (let ((first-pid nil))
    (handler-case
        (handler-bind ((sc:sidecar-not-ready
                         (lambda (c) (declare (ignore c)) (setf first-pid (%pid-of :test-first)))))
          (sc:start-sidecars '(:test-first :test-second))
          (fail "it started"))
      (sc:sidecar-not-ready () nil))
    (is-true first-pid)
    (when first-pid
      (is-true (%ends-within-p first-pid 5) "the first sidecar ~D is still running" first-pid))))

(test reports-and-status-carry-neither-the-value-nor-the-arguments
  (sc:define-sidecar :test-quiet
                     :command (%command "(progn (format t \"token=topsecretvalue~%\") (finish-output) (sb-ext:exit :code 5))"
                                        "argument-secret")
                     :ready (sc:token-after "never=") :ready-timeout 30)
  (handler-case (progn (sc:start-sidecars '(:test-quiet)) (fail "it started"))
    (sc:sidecar-not-ready (c)
      (let ((text (princ-to-string c)))
        (is-false (search "topsecretvalue" text))
        (is-false (search "argument-secret" text)))))
  (is-false (search "topsecretvalue" (format nil "~S" (multiple-value-list (sc:sidecar-status :test-quiet))))))

;;; --- restarting ---------------------------------------------------------------------------

(test restarts-wait-1-second-then-double-up-to-30
  "Launch 2 is the first restart."
  (is (equal '(1 2 4 8 16 30 30) (mapcar #'sc::%restart-delay '(2 3 4 5 6 7 8)))))

(test a-restarting-sidecar-comes-back-and-its-value-is-read-again
  (sc:define-sidecar :test-restart :command (%command +ready-form+) :ready (sc:token-after "token=")
                     :restart t)
  (with-sidecars (set '(:test-restart))
    (let ((pid (%pid-of :test-restart))
          (value (sc:sidecar-value :test-restart)))
      (%kill-pid pid)
      (is-true (%ends-within-p pid 5))
      ;; The first restart waits 1 s.
      (let ((new (loop repeat 120
                       for v = (sc:sidecar-value :test-restart)
                       when (and v (not (equal v value))) return v
                       do (sleep 0.25))))
        (is-true new "the sidecar did not come back with a new value")
        (is (not (eql pid (%pid-of :test-restart))))))))

;;; --- the dev server ----------------------------------------------------------------------

(test a-dev-reload-keeps-the-sidecar-and-unwatch-ends-it
  (sc:define-sidecar :test-dev :command (%command +ready-form+ "{port}")
                     :ready (sc:token-after "token="))
  (let* ((root (%fresh-directory "hyperion-sidecar-dev"))
         (asset (merge-pathnames "style.css" root))
         (d nil) (pid nil))
    (ensure-directories-exist root)
    (with-open-file (out asset :direction :output :if-exists :supersede) (write-line "a{}" out))
    (unwind-protect
         (progn
           (setf d (ports:call-with-port
                    (lambda (port)
                      (dev:watch (lambda () (srv:start (lambda (env) (declare (ignore env))
                                                         '(200 (:content-type "text/plain") ("ok")))
                                                       :port port :server :hunchentoot))
                                 :paths (list root) :sidecars '(:test-dev)))))
           (setf pid (%pid-of :test-dev))
           (is-true (%pid-alive-p pid))
           ;; File write dates have a resolution of one second.
           (sleep 1.1)
           (let ((epoch dev:*reload-epoch*))
             (with-open-file (out asset :direction :output :if-exists :supersede) (write-line "b{}" out))
             ;; The watcher thread polls every half second and may reload before this call
             ;; does, in which case this call returns :NO-CHANGE. Either way the server must
             ;; have been rebuilt, and a successful rebuild bumps the reload epoch.
             (dev:reload! d)
             (is (> dev:*reload-epoch* epoch) "changing a watched file did not reload the server"))
           (is (eql pid (%pid-of :test-dev)) "the reload restarted the sidecar")
           (is-true (%pid-alive-p pid))
           (dev:unwatch d)
           (setf d nil)
           (is-true (%ends-within-p pid 5) "UNWATCH left the sidecar ~D running" pid))
      (when d (dev:unwatch d))
      (%kill-pid pid)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test a-sidecar-that-cannot-start-stops-the-dev-server
  (sc:define-sidecar :test-dev-fails :command (%command "(sb-ext:exit :code 1)")
                     :ready (sc:token-after "never=") :ready-timeout 30)
  ;; Watch an empty directory of its own. WATCH snapshots every file under its paths, and the
  ;; whole temporary directory of a developer's machine can be large enough to exhaust the heap.
  (let ((port nil)
        (root (%fresh-directory "hyperion-sidecar-dev-fails")))
    (ensure-directories-exist root)
    (unwind-protect
         (handler-case
             (ports:call-with-port
              (lambda (p)
                (setf port p)
                (dev:watch (lambda () (srv:start (lambda (env) (declare (ignore env))
                                                   '(200 (:content-type "text/plain") ("ok")))
                                                 :port p :server :hunchentoot))
                           :paths (list root) :sidecars '(:test-dev-fails))
                (fail "WATCH returned")))
           (sc:sidecar-not-ready () nil))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))
    (is (null dev::*dev*))
    (is-true (ports:await-released port) "the server on ~D is still listening" port)))

;;; --- the cases #708's review raised -------------------------------------------------------

(defparameter +grandchild-ready-form+
  "(progn (let ((g (sb-ext:run-program #+win32 \"ping\" #-win32 \"sleep\" #+win32 (list \"-n\" \"600\" \"127.0.0.1\") #-win32 (list \"600\") :search t :wait nil :output nil))) (format t \"ready grandchild=~D~%\" (sb-ext:process-pid g))) (finish-output) (sleep 600))"
  "A sidecar that starts a process of its own before it prints its ready line, which captures
that process's pid.")

(test stopping-a-sidecar-ends-the-process-it-started
  "On Unix the sidecar's process group is signalled, on Windows its job is terminated, so a
process the sidecar started does not outlive the stop."
  ;; On Unix the grandchild is a shell's background job, which stays in the sidecar's process
  ;; group. A child that makes its own group, as SB-EXT:RUN-PROGRAM's children do, is not
  ;; reached by a group signal; hyperion/docs/sidecars.md says so.
  (sc:define-sidecar :test-grandchild
                     :command #+win32 (%command +grandchild-ready-form+)
                              #-win32 (list "/bin/sh" "-c" "sleep 600 & echo \"ready grandchild=$!\"; wait")
                     :ready (sc:token-after "grandchild="))
  (let ((grandchild nil))
    (unwind-protect
         (progn
           (with-sidecars (set '(:test-grandchild))
             (setf grandchild (parse-integer (sc:sidecar-value :test-grandchild)))
             (is-true (%pid-alive-p grandchild)))
           (is-true (%ends-within-p grandchild 5)
                    "the sidecar's own process ~D outlived STOP-SIDECARS" grandchild))
      (%kill-pid grandchild))))

(test work-on-a-stopped-set-is-refused-rather-than-waited-for
  (sc:define-sidecar :test-noready-2 :command (%command "(sleep 600)"))
  (let ((set (sc:start-sidecars '(:test-noready-2))))
    (sc:stop-sidecars set)
    (signals sc:sidecar-set-stopped (sc::%on-supervisor set (lambda () :ran)))
    (is (null (sc:stop-sidecars set)) "a second STOP-SIDECARS is not a no-op")))

(test a-port-change-whose-replacement-fails-signals-and-is-tried-again
  "The replacement exits when it is given port 2. That signals SIDECAR-NOT-READY, as at start, and
the next port change starts it again."
  (sc:define-sidecar :test-port-change
                     :command (%command "(let ((port (car (last sb-ext:*posix-argv*)))) (when (string= port \"2\") (sb-ext:exit :code 4)) (format t \"port=~A~%\" port) (finish-output) (sleep 600))"
                                        "{port}")
                     :ready (sc:token-after "port=") :ready-timeout 30)
  (with-sidecars (set '(:test-port-change) :port 1)
    (is (equal "1" (sc:sidecar-value :test-port-change)))
    (handler-case (progn (sc:update-sidecar-port set 2) (fail "the failed replacement was not reported"))
      (sc:sidecar-not-ready (c)
        (is (eq :exited (sc:sidecar-not-ready-reason c)))
        (is (eql 4 (sc:sidecar-not-ready-exit-code c)))))
    (is (equal '(:test-port-change) (sc:update-sidecar-port set 3)))
    (is (equal "3" (sc:sidecar-value :test-port-change)))))

#+win32
(test on-windows-a-sidecar-that-cannot-be-put-in-a-job-is-not-started
  "In a job or not at all: the job is what ends a sidecar after the image is killed. The process the
job function saw is ended before it runs."
  (sc:define-sidecar :test-no-job :command (%command "(sleep 600)"))
  (let* ((seen nil)
         (sc::*job-function* (lambda (pid)
                               (setf seen pid)
                               (error 'aion/windows:win32-error :code 5 :message "Access is denied."
                                                                :operation :assign-process-to-job-object))))
    (handler-case (progn (sc:start-sidecars '(:test-no-job)) (fail "it started"))
      (sc:sidecar-not-started (c)
        (is (eq :no-job (sc:sidecar-not-started-reason c)))))
    (is-true seen)
    (when seen (is-true (%ends-within-p seen 5) "the refused sidecar ~D is still running" seen))))

#+win32
(test on-windows-a-process-that-cannot-be-created-is-a-spawn-failure-not-a-job-failure
  "CreateProcessW fails for a working directory that does not exist. That is reported as
:SPAWN-FAILED, and the job function is never called."
  (let ((missing (merge-pathnames (format nil "hyperion-sidecar-missing-~36R/" (random (expt 36 8)))
                                  (uiop:temporary-directory))))
    (sc:define-sidecar :test-no-create :command (%command "(sleep 600)") :directory missing)
    (let* ((seen nil)
           (sc::*job-function* (lambda (pid) (setf seen pid) (aion/windows:default-job-function pid))))
      (is-false (probe-file missing))
      (handler-case (progn (sc:start-sidecars '(:test-no-create)) (fail "it started"))
        (sc:sidecar-not-started (c)
          (is (eq :spawn-failed (sc:sidecar-not-started-reason c)))))
      (is-false seen "the job function was called for a process that was never created"))))

#-win32
(test without-setpriv-a-sidecar-that-cannot-be-recorded-is-not-started
  "Without setpriv the state file is the only thing that ends a sidecar after a crash. A state
directory that cannot be created, because a file has its name, stops the sidecar."
  (sc:define-sidecar :test-no-record :command (%command "(progn (format t \"pid=~D~%\" (sb-unix:unix-getpid)) (finish-output) (sleep 600))"))
  (let* ((blocker (uiop:tmpize-pathname (merge-pathnames "hyperion-sidecar-blocker" (uiop:temporary-directory))))
         (sc:*state-directory* (uiop:ensure-directory-pathname blocker))
         (sc::*setpriv* nil))
    (unwind-protect
         (handler-case (progn (sc:start-sidecars '(:test-no-record)) (fail "it started"))
           (sc:sidecar-not-started (c)
             (is (eq :no-state-file (sc:sidecar-not-started-reason c)))))
      (ignore-errors (delete-file blocker)))))

;;; --- the image dying ----------------------------------------------------------------------

(defun %tree-registry ()
  (let ((tree (uiop:pathname-parent-directory-pathname (asdf:system-source-directory :hyperion))))
    (format nil "~A//~A" (substitute #\/ #\\ (string-right-trim "/\\" (uiop:native-namestring tree)))
            (if (uiop:os-windows-p) ";" ":"))))

(defun %image-with-sidecar ()
  "Start an SBCL image that loads hyperion/sidecar and starts one sidecar, which starts a
grandchild. Returns (values IMAGE SIDECAR-PID GRANDCHILD-PID LOG) once the image reports both."
  (let* ((log (uiop:tmpize-pathname (merge-pathnames "hyperion-sidecar-image.txt" (uiop:temporary-directory))))
         (form (format nil "(progn (hyperion/sidecar:define-sidecar :child :command (list ~{~S~^ ~}) :ready (hyperion/sidecar:token-after \"grandchild=\")) (hyperion/sidecar:start-sidecars '(:child)) (format t \"SIDECAR ~~D~~%GRANDCHILD ~~A~~%\" (hyperion/sidecar::%pid (hyperion/sidecar::sidecar-process (gethash :child hyperion/sidecar::*running*))) (hyperion/sidecar:sidecar-value :child)) (finish-output) (sleep 600))"
                       (%command +grandchild-ready-form+)))
         (image (uiop:launch-program
                 (list (%sbcl) "--dynamic-space-size" "1024" "--noinform" "--no-userinit" "--no-sysinit"
                       "--non-interactive"
                       "--eval" "(require :asdf)"
                       "--eval" (format nil "(load ~S)" (uiop:native-namestring
                                                         (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
                       "--eval" "(let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :hyperion/sidecar))"
                       "--eval" form)
                 :output log :error-output :output :if-output-exists :supersede
                 :environment (cons (format nil "CL_SOURCE_REGISTRY=~A" (%tree-registry))
                                    (remove-if (lambda (e) (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e))
                                               (sb-ext:posix-environ))))))
    (flet ((after (prefix lines)
             (let ((line (find-if (lambda (l) (uiop:string-prefix-p prefix l)) lines)))
               (and line (parse-integer line :start (length prefix) :junk-allowed t)))))
      (loop repeat 480
            for lines = (ignore-errors (uiop:read-file-lines log))
            for sidecar = (after "SIDECAR " lines)
            for grandchild = (after "GRANDCHILD " lines)
            when (and sidecar grandchild)
              do (return-from %image-with-sidecar (values image sidecar grandchild log))
            while (uiop:process-alive-p image)
            do (sleep 0.25))
      (values image nil nil log))))

(defun %kill-image (image)
  #+win32 (uiop:run-program (list "taskkill" "/PID" (princ-to-string (uiop:process-info-pid image)) "/F")
                            :output nil :error-output nil :ignore-error-status t)
  #-win32 (sb-unix:unix-kill (uiop:process-info-pid image) 9)
  (ignore-errors (uiop:wait-process image)))

#+(or win32 linux)
(test killing-the-image-ends-its-sidecar-and-what-the-sidecar-started
  "The image is killed, so no exit hook runs. On Windows the job object ends the sidecar and its
grandchild. On Linux the parent-death signal ends the sidecar; its grandchild is not covered there."
  (if #+linux (null (sc::%find-program "setpriv")) #-linux nil
      (skip "setpriv is not installed")
  (multiple-value-bind (image sidecar grandchild log) (%image-with-sidecar)
    (unwind-protect
         (progn
           (is-true sidecar "the image did not report its sidecar: ~S" (ignore-errors (uiop:read-file-lines log)))
           (when sidecar
             (%kill-image image)
             (is-true (%ends-within-p sidecar 5) "the sidecar ~D outlived the image" sidecar)
             #+win32 (is-true (%ends-within-p grandchild 5) "the grandchild ~D outlived the image" grandchild)))
      (when (uiop:process-alive-p image) (%kill-image image))
      (%kill-pid sidecar)
      (%kill-pid grandchild)
      (ignore-errors (delete-file log))))))

#-win32
(test the-next-start-ends-a-sidecar-left-by-a-dead-image
  "On Unix a state file records each sidecar. A record whose image has exited and whose process
still runs the recorded program is ended; a record whose image still runs is left alone."
  (let* ((sc:*state-directory* (%fresh-directory "hyperion-sidecar-state"))
         (sleep-path (sc::%find-program "sleep"))
         (orphan (sb-ext:run-program sleep-path '("600") :wait nil))
         (kept (sb-ext:run-program sleep-path '("600") :wait nil))
         (dead-owner (let ((p (sb-ext:run-program "/bin/sh" '("-c" "exit 0") :wait t)))
                       (sb-ext:process-pid p))))
    (unwind-protect
         (progn
           (ensure-directories-exist sc:*state-directory*)
           (flet ((record (owner process)
                    (with-open-file (out (merge-pathnames (format nil "~D-~D.sidecar" owner (sb-ext:process-pid process))
                                                          sc:*state-directory*)
                                         :direction :output :if-exists :supersede)
                      (with-standard-io-syntax
                        (prin1 (list :owner owner :pid (sb-ext:process-pid process) :program sleep-path) out)))))
             (record dead-owner orphan)
             (record (sb-unix:unix-getpid) kept))
           (sc::%reap-leftovers)
           ;; Both are this image's children, so a killed one stays a zombie until it is reaped,
           ;; and kill(pid, 0) still finds it. PROCESS-ALIVE-P reaps.
           (is-true (loop repeat 20 while (sb-ext:process-alive-p orphan) do (sleep 0.25)
                          finally (return (not (sb-ext:process-alive-p orphan))))
                    "the orphan is still running")
           (is-true (sb-ext:process-alive-p kept) "a sidecar of a running image was ended"))
      (dolist (p (list orphan kept))
        (ignore-errors (sb-ext:process-kill p 9))
        (ignore-errors (sb-ext:process-wait p))
        (ignore-errors (sb-ext:process-close p)))
      (uiop:delete-directory-tree sc:*state-directory* :validate t :if-does-not-exist :ignore))))
