;;;; sidecar.lisp --- dev sidecars: helper processes that run while a dev server runs (#700).
;;;;
;;;; A sidecar is a program an app needs running beside its development server, such as the
;;;; Stripe CLI's webhook forwarder, a mail catcher or a tunnel. An app declares it once with
;;;; DEFINE-SIDECAR and names it in the :SIDECARS argument of HYPERION/DEV:SERVE, HYPERION/DEV:WATCH
;;;; or HYPERION/DESKTOP:RUN-APP. Those start the named sidecars after the server has bound its
;;;; port and stop them when the dev session ends. HYPERION/SERVER:SERVE-FOREVER, the production
;;;; entry point, takes no :SIDECARS, so a production server cannot start one.
;;;;
;;;; A sidecar can print a value the app needs, such as the forwarder's webhook signing secret.
;;;; Its :READY function finds that value in a line of output, and SIDECAR-VALUE returns it.
;;;;
;;;; NO ORPHANS. A sidecar must not outlive the image that started it, even when the image is
;;;; killed and its exit hooks do not run.
;;;;   Windows  each sidecar is started suspended inside a kill-on-close job object
;;;;            (AION/WINDOWS:SPAWN-IN-JOB), so Windows ends it, and anything it started, when the
;;;;            image's last handle to the job closes, however the image ends.
;;;;   Linux    each sidecar is started through `setpriv --pdeathsig KILL', so the kernel sends it
;;;;            SIGKILL when its parent goes away. The kernel means the parent THREAD, so every
;;;;            sidecar of a set is started from that set's supervisor thread, which lives until
;;;;            the set is stopped. Without setpriv, a warning is logged and the state files below
;;;;            are relied on.
;;;;   macOS    has neither mechanism. Every sidecar's pid and command are written to a state file
;;;;            under the user's cache directory, and the next START-SIDECARS in any image ends a
;;;;            recorded sidecar whose image has died and that still runs the recorded program.
;;;;            Linux writes the state files too.
;;;;
;;;; SECRETS. A sidecar's output can contain secrets, so its lines are logged at debug level only,
;;;; never at info. A value declared :SECRET is held as an AION/SECRET. Conditions, log fields and
;;;; SIDECAR-STATUS never include a captured value or a sidecar's arguments.

(cl:defpackage #:hyperion/sidecar
  (:use #:cl)
  (:local-nicknames (#:log #:aion/log)
                    (#:secret #:aion/secret))
  (:documentation "Dev sidecars: helper processes started and stopped with a dev server (#700).")
  (:export #:define-sidecar #:register-sidecar #:find-sidecar #:token-after
           #:sidecar-uses-port-p
           #:start-sidecars #:stop-sidecars #:sidecar-set #:sidecar-set-p #:update-sidecar-port
           #:sidecar-value #:sidecar-status
           #:sidecar-not-started #:sidecar-not-started-name #:sidecar-not-started-reason
           #:sidecar-not-ready #:sidecar-not-ready-name #:sidecar-not-ready-reason
           #:sidecar-not-ready-exit-code #:sidecar-set-stopped
           #:*stop-seconds* #:*state-directory*))

(in-package #:hyperion/sidecar)

;;; --- conditions ---------------------------------------------------------------------------

(define-condition sidecar-not-started (error)
  ((name :initarg :name :reader sidecar-not-started-name)
   (reason :initarg :reason :reader sidecar-not-started-reason))
  (:report (lambda (c s)
             (format s "Sidecar ~S was not started: ~A" (sidecar-not-started-name c)
                     (case (sidecar-not-started-reason c)
                       (:not-found "its program was not found on PATH")
                       (:undeclared "no sidecar by that name has been declared")
                       (:no-port "its command uses {port}, and the server's bound port is not known")
                       (:no-job "Windows could not put it in a job object")
                       (:batch-file "its program is a batch file, which is not supported on Windows")
                       (:spawn-failed "its process could not be created")
                       (:no-state-file "its state file could not be written, and without setpriv nothing else would end it after a crash")
                       (t (sidecar-not-started-reason c))))))
  (:documentation "A sidecar could not be started. REASON is :NOT-FOUND, for a program that is not
on PATH and a sidecar declared :REQUIRED T; :UNDECLARED, for a name DEFINE-SIDECAR never declared;
:NO-PORT; :NO-JOB and :BATCH-FILE, on Windows; :SPAWN-FAILED; or :NO-STATE-FILE, on Unix without
setpriv."))

(define-condition sidecar-not-ready (error)
  ((name :initarg :name :reader sidecar-not-ready-name)
   (reason :initarg :reason :reader sidecar-not-ready-reason)
   (exit-code :initarg :exit-code :initform nil :reader sidecar-not-ready-exit-code))
  (:report (lambda (c s)
             (format s "Sidecar ~S did not become ready: ~A" (sidecar-not-ready-name c)
                     (ecase (sidecar-not-ready-reason c)
                       (:timeout "its readiness timeout passed")
                       (:exited (format nil "it exited first, with code ~A"
                                        (sidecar-not-ready-exit-code c)))))))
  (:documentation "A sidecar started but did not become ready. REASON is :TIMEOUT or :EXITED, and
EXIT-CODE is its exit code when it exited. The report never includes its output or arguments."))

;;; --- declarations -------------------------------------------------------------------------

(defstruct (declared-sidecar (:conc-name decl-) (:constructor make-declaration))
  name command environment directory ready ready-timeout secret required restart)

(defvar *declarations* (make-hash-table :test #'eq :synchronized t)
  "Each declared sidecar, by name.")

(defun register-sidecar (name &key command environment directory ready (ready-timeout 15)
                                   secret required restart)
  "Declare the sidecar NAME, a keyword, replacing any earlier declaration of it. DEFINE-SIDECAR is
the usual way to call this.

COMMAND is a list of strings, the program and its arguments. Each \"{port}\" in an argument is
replaced with the server's bound port when the sidecar starts. ENVIRONMENT is an alist of names
and values, all strings, added to the image's environment; anything else is an error. DIRECTORY
is the working directory, or NIL. READY is NIL, for a sidecar that is ready once it has started,
or a function of one line of its standard output or standard error that returns NIL or the
captured string; see TOKEN-AFTER.
READY-TIMEOUT is how many seconds START-SIDECARS waits for it. SECRET true holds the captured value
as an AION/SECRET. REQUIRED true makes a program missing from PATH an error rather than a warning.
RESTART true starts the sidecar again when it exits by itself, after 1 s, then 2, 4 and so on up
to 30 s, without limit, and reads its value again."
  (check-type name keyword)
  (unless (and (consp command) (every #'stringp command))
    (error "The :COMMAND of sidecar ~S must be a non-empty list of strings." name))
  (unless (and (listp environment)
               (every (lambda (e) (and (consp e) (stringp (car e)) (stringp (cdr e)))) environment))
    (error "The :ENVIRONMENT of sidecar ~S must be a list of (NAME . VALUE) pairs of strings. A value that is not a string, such as NIL from a variable that is not set, is refused." name))
  (setf (gethash name *declarations*)
        (make-declaration :name name :command command :environment environment
                          :directory directory :ready ready :ready-timeout ready-timeout
                          :secret secret :required required :restart restart))
  name)

(defmacro define-sidecar (name &rest options)
  "Declare the sidecar NAME. OPTIONS are REGISTER-SIDECAR's keyword arguments."
  `(register-sidecar ,name ,@options))

(defun find-sidecar (name)
  "The declaration of the sidecar NAME, or NIL."
  (gethash name *declarations*))

(defun token-after (marker)
  "A :READY function that finds MARKER in a line and returns the text after it up to the next
space or tab, or NIL when MARKER is not in the line or nothing follows it."
  (check-type marker string)
  (lambda (line)
    (let ((at (search marker line)))
      (when at
        (let* ((start (+ at (length marker)))
               (end (or (position-if (lambda (c) (member c '(#\Space #\Tab #\Return))) line
                                     :start start)
                        (length line))))
          (when (> end start) (subseq line start end)))))))

(defun sidecar-uses-port-p (name)
  "Whether the declared sidecar NAME has \"{port}\" in its command."
  (let ((d (find-sidecar name)))
    (and d (some (lambda (a) (search "{port}" a)) (decl-command d)) t)))

(defun %substitute-port (argument port)
  (let ((at (search "{port}" argument)))
    (if at
        (concatenate 'string (subseq argument 0 at) (princ-to-string port)
                     (%substitute-port (subseq argument (+ at 6)) port))
        argument)))

;;; --- the process, on each platform -------------------------------------------------------

(defun %find-program (name)
  "The native namestring of the program NAME, or NIL."
  #+win32 (aion/windows:find-executable name)
  #-win32 (flet ((ok (p) (let ((f (probe-file p))) (and f (pathname-name f) (uiop:native-namestring f)))))
            (if (find #\/ name)
                (ok name)
                (loop for dir in (uiop:split-string (or (uiop:getenv "PATH") "") :separator ":")
                      thereis (and (plusp (length dir))
                                   (ok (concatenate 'string (string-right-trim "/" dir) "/" name)))))))

(defun %environment (alist)
  "The child's environment as \"NAME=VALUE\" strings: this image's, with ALIST's entries added and
replacing any of the same name. NIL, meaning inherit it unchanged, when ALIST is empty."
  (when alist
    (let ((names (mapcar #'car alist)))
      (append (remove-if (lambda (entry)
                           (let ((name (subseq entry 0 (or (position #\= entry) (length entry)))))
                             (member name names :test #+win32 #'string-equal #-win32 #'string=)))
                         (sb-ext:posix-environ))
              (mapcar (lambda (e) (format nil "~A=~A" (car e) (cdr e))) alist)))))

#-win32
(defvar *setpriv* :unknown
  "The path of setpriv on Linux, NIL when it is not installed, :UNKNOWN until first looked for.")

#-win32
(defun %setpriv ()
  (when (eq *setpriv* :unknown)
    (setf *setpriv* (and (string-equal (software-type) "Linux") (%find-program "setpriv")))
    (when (and (string-equal (software-type) "Linux") (null *setpriv*))
      (log:warn "hyperion/sidecar: setpriv is not installed, so a sidecar can outlive an image that is killed; the next start ends it"
                :package "util-linux")))
  *setpriv*)

#+win32
(define-condition no-job (error)
  ((cause :initarg :cause :reader no-job-cause))
  (:documentation "The job function failed, so the sidecar was ended before it ran. CAUSE is the
condition it signalled. Kept apart from every other Windows error, which means the process could
not be created at all."))

#+win32
(defvar *job-function* 'aion/windows:default-job-function
  "The function of a pid that puts a sidecar in its job object, while the sidecar is still
suspended. The tests bind it to one that fails.")

(defun %spawn (name path arguments environment directory)
  "Start PATH with ARGUMENTS. Returns the platform's process object, whose standard output and
standard error are character streams."
  (declare (ignorable name))
  ;; In a job or not at all. On Windows the job is the only thing that ends a sidecar after the
  ;; image is killed, so one that cannot be put in a job is ended before it runs, and %LAUNCH
  ;; reports :NO-JOB.
  #+win32
  (aion/windows:spawn-in-job path arguments
                             :environment environment :directory directory
                             :output :stream :error :stream :element-type 'character
                             :external-format '(:utf-8 :replacement #\?)
                             :job-function (let ((job-function *job-function*))
                                             (lambda (pid)
                                               (handler-case (funcall job-function pid)
                                                 (error (e) (error 'no-job :cause e)))))
                             :if-no-job :error)
  #-win32
  (let* ((setpriv (%setpriv))
         (program (or setpriv path))
         (args (if setpriv (list* "--pdeathsig" "KILL" "--" path arguments) arguments)))
    (apply #'sb-ext:run-program program args
           :wait nil :input nil :output :stream :error :stream
           :external-format '(:utf-8 :replacement #\?)
           :directory (and directory (uiop:native-namestring directory))
           (and environment (list :environment environment)))))

(defun %pid (p)
  #+win32 (aion/windows:job-process-pid p)
  #-win32 (sb-ext:process-pid p))

(defun %output (p)
  #+win32 (aion/windows:job-process-output p)
  #-win32 (sb-ext:process-output p))

(defun %error-stream (p)
  #+win32 (aion/windows:job-process-error p)
  #-win32 (sb-ext:process-error p))

(defun %alive-p (p)
  #+win32 (aion/windows:job-process-alive-p p)
  #-win32 (sb-ext:process-alive-p p))

(defun %exit-code (p)
  #+win32 (aion/windows:job-process-exit-code p)
  #-win32 (sb-ext:process-exit-code p))

(defun %close (p)
  #+win32 (aion/windows:job-process-close p)
  #-win32 (sb-ext:process-close p))

(defun %wait-exit (p seconds)
  (loop with deadline = (+ (get-internal-real-time) (* seconds internal-time-units-per-second))
        while (%alive-p p)
        do (when (> (get-internal-real-time) deadline) (return nil))
           (sleep 0.02)
        finally (return t)))

(defvar *stop-seconds* 2
  "How long STOP-SIDECARS waits for a sidecar to exit after asking it to, before killing it.")

;;; --- state files: the next start ends a sidecar left by a dead image (Unix) -----------------

(defvar *state-directory* nil
  "The directory of sidecar state files, or NIL for hyperion-sidecars/ under the user's cache
directory. On Windows none are written.")

(defun %state-directory ()
  (or *state-directory* (uiop:xdg-cache-home "hyperion-sidecars/")))

#-win32
(defun %image-pid ()
  (sb-unix:unix-getpid))

#-win32
(defun %pid-alive-p (pid)
  "Whether a process PID exists. SB-UNIX:UNIX-KILL returns 0 when it does and -1 when it does not,
and both are true in Lisp, so the result is compared with 0."
  (and (plusp pid) (eql 0 (sb-unix:unix-kill pid 0))))

#-win32
(defun %command-of (pid)
  (string-trim '(#\Space #\Newline #\Return)
               (uiop:run-program (list "ps" "-o" "command=" "-p" (princ-to-string pid))
                                 :output :string :ignore-error-status t)))

#-win32
(defun %state-file (owner child)
  (merge-pathnames (format nil "~D-~D.sidecar" owner child) (%state-directory)))

#-win32
(defun %write-state (child-pid path)
  (let ((file (%state-file (%image-pid) child-pid)))
    (ensure-directories-exist file)
    (with-open-file (out file :direction :output :if-exists :supersede)
      (with-standard-io-syntax
        (prin1 (list :owner (%image-pid) :pid child-pid :program path) out)))
    file))

#-win32
(defun %reap-leftovers ()
  "End each sidecar recorded by an image that is no longer running, when it still runs the program
it was recorded with, and delete the record. A record whose image still runs is left alone."
  (dolist (file (ignore-errors (directory (merge-pathnames "*.sidecar" (%state-directory)))))
    (let ((record (ignore-errors
                   (with-open-file (in file)
                     (with-standard-io-syntax (let ((*read-eval* nil)) (read in)))))))
      (destructuring-bind (&key owner pid program) (if (listp record) record '())
        (cond ((not (and (integerp owner) (integerp pid) (stringp program)))
               (ignore-errors (delete-file file)))
              ((%pid-alive-p owner))
              (t
               (when (and (%pid-alive-p pid) (search program (%command-of pid)))
                 (log:warn "hyperion/sidecar: ending a sidecar left running by an image that has exited"
                           :pid pid :image owner)
                 ;; Its own group, as RUN-PROGRAM made it; then the process alone, in case not.
                 (sb-unix:unix-kill (- pid) 9)
                 (sb-unix:unix-kill pid 9))
               (ignore-errors (delete-file file))))))))

(defun %timed-wait (queue mutex seconds)
  "CONDITION-WAIT on QUEUE for up to SECONDS, holding MUTEX again when it returns. SBCL returns from
a wait that timed out without the mutex, so a loop that waits again would wait without it."
  (sb-thread:condition-wait queue mutex :timeout seconds)
  (unless (sb-thread:holding-mutex-p mutex)
    (sb-thread:grab-mutex mutex)))

;;; --- one running sidecar ------------------------------------------------------------------
;;;
;;; GENERATIONS. Each launch and each deliberate stop of a sidecar's process increments its
;;; GENERATION. A reader thread, a watcher thread and a scheduled restart each carry the
;;; generation they were made for, and do nothing once it is not the current one. This is what
;;; keeps a readiness line read from a process that has since exited, or a restart scheduled
;;; before a port change, from acting on the process that replaced it. The restart backoff has
;;; its own counter, ATTEMPT, which goes back to the first restart's delay after a long run.
;;;
;;; Every launch and every stop runs on the set's supervisor thread, so two of them never run at
;;; once for one sidecar, and on Linux the thread a sidecar's parent-death signal is tied to is
;;; the one that started it.

(defstruct (sidecar (:constructor %make-sidecar (spec owner)))
  spec
  owner
  (lock (sb-thread:make-mutex :name "hyperion/sidecar"))
  (changed (sb-thread:make-waitqueue))
  ;; :STARTING, :READY, :EXITED or :NOT-STARTED.
  (state :not-started)
  process
  ;; On Unix, true when the process leads its own process group, so the group is signalled.
  (group-p nil)
  captured
  exit-code
  port
  (stopping nil)
  (generation 0)
  (attempt 1)
  ready-at
  readers
  watcher
  state-file)

(defvar *running* (make-hash-table :test #'eq :synchronized t)
  "The running SIDECAR for each name, which SIDECAR-VALUE reads.")

(defun %name (s) (decl-name (sidecar-spec s)))

(defun %current-p (s generation)
  "Whether GENERATION is still S's current one and S is not being stopped. Called with S's lock
held."
  (and (= generation (sidecar-generation s)) (not (sidecar-stopping s))))

(defun %read-lines (s stream which generation)
  "Read STREAM line by line until it ends. Each line's length is logged at debug level, never its
text, which can be the secret the :READY function captures. Each line is offered to the :READY
function while the sidecar is starting. The value is published under S's lock, and only
while GENERATION is current, so a line from a process that has since exited is not published."
  (let ((ready (decl-ready (sidecar-spec s))))
    (handler-case
        (loop for line = (read-line stream nil nil)
              while line
              do (log:debug "hyperion/sidecar: output" :name (%name s) :stream which
                                                        :length (length line))
                 (when (and ready (eq (sidecar-state s) :starting))
                   (let ((value (ignore-errors (funcall ready line))))
                     (when (and value
                                (sb-thread:with-mutex ((sidecar-lock s))
                                  (when (and (%current-p s generation)
                                             (eq (sidecar-state s) :starting))
                                    (setf (sidecar-state s) :ready
                                          (sidecar-captured s)
                                          (if (decl-secret (sidecar-spec s))
                                              (secret:make-secret value)
                                              value)
                                          (sidecar-ready-at s) (get-universal-time))
                                    (sb-thread:condition-broadcast (sidecar-changed s))
                                    t)))
                       (log:info "hyperion/sidecar: ready" :name (%name s) :captured t)))))
      (error () nil))))

(defun %restart-delay (attempt)
  "Seconds to wait before launch number ATTEMPT, where 1 is the first launch and 2 the first
restart: 1 s before the first restart, doubling to at most 30 s."
  (min 30 (expt 2 (max 0 (- attempt 2)))))

(defun %watch (s process generation)
  "Wait for PROCESS to exit. While GENERATION is current, record its exit code and, for a sidecar
declared :RESTART, schedule a launch that checks the generation again before it runs."
  (loop while (%alive-p process) do (sleep 0.1))
  (let ((code (%exit-code process))
        (restart nil))
    (sb-thread:with-mutex ((sidecar-lock s))
      (when (%current-p s generation)
        (setf (sidecar-state s) :exited
              (sidecar-exit-code s) code
              (sidecar-captured s) nil)
        (sb-thread:condition-broadcast (sidecar-changed s))
        (when (decl-restart (sidecar-spec s))
          ;; Back to the first restart's delay after a run that stayed up for a minute.
          (let ((ready-at (sidecar-ready-at s)))
            (setf (sidecar-attempt s)
                  (if (and ready-at (> (- (get-universal-time) ready-at) 60))
                      2
                      (1+ (sidecar-attempt s)))
                  restart (sidecar-attempt s))))))
    (when (sb-thread:with-mutex ((sidecar-lock s)) (= generation (sidecar-generation s)))
      (log:info "hyperion/sidecar: exited" :name (%name s) :pid (%pid process) :code code))
    (when restart
      (let ((delay (%restart-delay restart)))
        (log:warn "hyperion/sidecar: restarting" :name (%name s) :attempt restart :delay delay)
        (%schedule (sidecar-owner s) delay
                   (lambda ()
                     (when (sb-thread:with-mutex ((sidecar-lock s)) (%current-p s generation))
                       (let ((result (%launch s)))
                         (unless (eq result :started)
                           (log:warn "hyperion/sidecar: restart failed" :name (%name s)
                                     :reason result))))))))))

(defun %release (s process)
  "Join S's threads for PROCESS, which has exited, close it and delete its state file."
  (dolist (th (shiftf (sidecar-readers s) nil))
    (sb-thread:join-thread th :default nil :timeout 2))
  (let ((w (shiftf (sidecar-watcher s) nil)))
    (when (and w (not (eq w sb-thread:*current-thread*)))
      (sb-thread:join-thread w :default nil :timeout 2)))
  (ignore-errors (%close process))
  (let ((file (shiftf (sidecar-state-file s) nil)))
    (when file (ignore-errors (delete-file file)))))

(defun %end-group (s process)
  "End PROCESS, and on Windows everything in its job: on Unix SIGTERM, then SIGKILL after
*STOP-SECONDS*, each to its process group when it leads one, so processes it started go too, and
the group is sent SIGKILL once more if any of it is left after the leader exits. On Windows the
job is terminated. Returns how it ended."
  #+win32 (progn s
                 (ignore-errors (aion/windows:job-process-terminate process 1))
                 (%wait-exit process *stop-seconds*)
                 :terminated)
  #-win32 (let ((pid (%pid process)) (group (sidecar-group-p s)))
            (flet ((send (sig)
                     (when group (sb-unix:unix-kill (- pid) sig))
                     (ignore-errors (sb-ext:process-kill process sig))))
              (send 15)
              (prog1 (cond ((%wait-exit process *stop-seconds*) :terminated)
                           (t (send 9) (%wait-exit process 2) :killed))
                ;; A process the leader started can outlive it in the group.
                (when (and group (eql 0 (sb-unix:unix-kill (- pid) 0)))
                  (sb-unix:unix-kill (- pid) 9))))))

(defun %stop-process (s)
  "Stop S's current process, if any, and make every reader, watcher and scheduled restart for it
stale. Runs on the supervisor thread. Returns how it ended, or NIL when there was none."
  (let ((process (sb-thread:with-mutex ((sidecar-lock s))
                   (incf (sidecar-generation s))
                   (sidecar-process s))))
    (when process
      (let ((how (if (%alive-p process) (%end-group s process) :exited)))
        (%release s process)
        (sb-thread:with-mutex ((sidecar-lock s))
          (setf (sidecar-process s) nil
                (sidecar-state s) :exited
                (sidecar-captured s) nil)
          (sb-thread:condition-broadcast (sidecar-changed s)))
        (log:info "hyperion/sidecar: stopped" :name (%name s) :pid (%pid process) :how how
                  :code (%exit-code process))
        how))))

(defun %launch (s)
  "Start S's process, with its reader and watcher threads. Runs on the supervisor thread. Returns
:STARTED, or a reason it was not started: :NOT-FOUND, :NO-JOB, :BATCH-FILE, :SPAWN-FAILED or
:NO-STATE-FILE."
  (let* ((d (sidecar-spec s))
         (command (mapcar (lambda (a) (%substitute-port a (sidecar-port s))) (decl-command d)))
         (path (%find-program (first command))))
    (when (sidecar-process s) (%stop-process s))
    (unless path
      (sb-thread:with-mutex ((sidecar-lock s)) (setf (sidecar-state s) :not-started))
      (return-from %launch :not-found))
    (let ((process (handler-case
                       (%spawn (decl-name d) path (rest command)
                               (%environment (decl-environment d)) (decl-directory d))
                     (error (e)
                       ;; The condition's type only: its text can carry the command line.
                       (log:warn "hyperion/sidecar: sidecar could not be started" :name (decl-name d)
                                 :error (type-of #+win32 (if (typep e 'no-job) (no-job-cause e) e)
                                                 #-win32 e))
                       (sb-thread:with-mutex ((sidecar-lock s)) (setf (sidecar-state s) :not-started))
                       (return-from %launch
                         (typecase e
                           #+win32 (aion/windows:process-not-started
                                    (if (eq (aion/windows:process-not-started-reason e) :batch-file)
                                        :batch-file
                                        :not-found))
                           #+win32 (no-job :no-job)
                           (t :spawn-failed)))))))
      #-win32
      (let ((pid (%pid process)))
        (setf (sidecar-group-p s)
              (eql pid (sb-alien:alien-funcall
                        (sb-alien:extern-alien "getpgid" (function sb-alien:int sb-alien:int))
                        pid)))
        ;; Without setpriv the state file is the only thing that ends this sidecar after a crash,
        ;; so a sidecar that cannot be recorded is not left running.
        (let ((file (ignore-errors (%write-state pid path))))
          (setf (sidecar-state-file s) file)
          (when (and (null file) (null (%setpriv)))
            (log:warn "hyperion/sidecar: no state file could be written, so the sidecar is stopped"
                      :name (decl-name d) :directory (namestring (%state-directory)))
            (sb-ext:process-kill process 9)
            (%wait-exit process 2)
            (ignore-errors (%close process))
            (sb-thread:with-mutex ((sidecar-lock s)) (setf (sidecar-state s) :not-started))
            (return-from %launch :no-state-file))))
      (let ((generation (sb-thread:with-mutex ((sidecar-lock s))
                          (setf (sidecar-process s) process
                                (sidecar-state s) (if (decl-ready d) :starting :ready)
                                (sidecar-captured s) nil
                                (sidecar-exit-code s) nil
                                (sidecar-ready-at s) (unless (decl-ready d) (get-universal-time)))
                          (sb-thread:condition-broadcast (sidecar-changed s))
                          (incf (sidecar-generation s)))))
        (log:info "hyperion/sidecar: started" :name (decl-name d) :pid (%pid process)
                  :attempt (sidecar-attempt s))
        (setf (sidecar-readers s)
              ;; THREAD-LIFETIME: scoped -- each reads one of this process's streams until it
              ;; ends, which it does once the process and anything holding the pipe have ended;
              ;; %RELEASE joins them.
              (list (sb-thread:make-thread
                     (lambda () (aion/dynamic:unblock-interrupts) (%read-lines s (%output process) :stdout generation))
                     :name "hyperion/sidecar stdout")
                    ;; THREAD-LIFETIME: scoped -- the same, for standard error.
                    (sb-thread:make-thread
                     (lambda () (aion/dynamic:unblock-interrupts) (%read-lines s (%error-stream process) :stderr generation))
                     :name "hyperion/sidecar stderr"))
              (sidecar-watcher s)
              ;; THREAD-LIFETIME: scoped -- it ends when this process has exited; %RELEASE joins it.
              (sb-thread:make-thread (lambda () (aion/dynamic:unblock-interrupts) (%watch s process generation))
                                     :name "hyperion/sidecar watcher"))
        :started))))

(defun %wait-ready (s timeout)
  "Wait until S is ready, has exited, or TIMEOUT seconds pass. Returns its state then, or :TIMEOUT."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (sb-thread:with-mutex ((sidecar-lock s))
      (loop
        (let ((state (sidecar-state s)))
          (unless (eq state :starting) (return state)))
        (let ((left (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)))
          (when (<= left 0) (return :timeout))
          (%timed-wait (sidecar-changed s) (sidecar-lock s) left))))))

(defun %stop-one (s)
  "Stop S for good: no restart, no further launch. Runs on the supervisor thread."
  (sb-thread:with-mutex ((sidecar-lock s)) (setf (sidecar-stopping s) t))
  (%stop-process s)
  (when (eq (gethash (%name s) *running*) s)
    (remhash (%name s) *running*)))

;;; --- a set of sidecars and its supervisor -------------------------------------------------
;;;
;;; A set is :RUNNING, then :CLOSING while STOP-SIDECARS stops its sidecars, then :STOPPED. Work
;;; scheduled on a set that is not :RUNNING is refused: a scheduled restart is dropped, and a
;;; synchronous request (%ON-SUPERVISOR) signals SIDECAR-SET-STOPPED rather than waiting for a
;;; thunk that will never run. STOP-SIDECARS stops the sidecars on the supervisor thread while
;;; it still runs, then lets it exit, because on Linux that thread exiting sends each sidecar its
;;; parent-death SIGKILL, which would skip the SIGTERM.

(define-condition sidecar-set-stopped (error) ()
  (:report "The sidecar set has been stopped, so no more work can be run on it."))

(defstruct (sidecar-set (:constructor %make-set ()))
  "The sidecars one START-SIDECARS started, and the supervisor thread that starts each of them."
  (sidecars '())
  (lock (sb-thread:make-mutex :name "hyperion/sidecar set"))
  (changed (sb-thread:make-waitqueue))
  (queue '())                           ; (due-internal-time . thunk), sorted by due time
  (state :running)
  ;; The semaphores of synchronous requests not yet answered, woken when the set closes.
  (waiting '())
  supervisor)

(defun %enqueue (set seconds thunk)
  "Add THUNK to SET's queue, due in SECONDS. Called with SET's lock held."
  (setf (sidecar-set-queue set)
        (merge 'list (sidecar-set-queue set)
               (list (cons (+ (get-internal-real-time)
                              (round (* seconds internal-time-units-per-second)))
                           thunk))
               #'< :key #'car))
  (sb-thread:condition-broadcast (sidecar-set-changed set)))

(defun %schedule (set seconds thunk)
  "Run THUNK on SET's supervisor thread in SECONDS. Returns NIL, and drops THUNK, when SET is not
:RUNNING."
  (sb-thread:with-mutex ((sidecar-set-lock set))
    (when (eq (sidecar-set-state set) :running)
      (%enqueue set seconds thunk)
      t)))

(defun %supervise (set)
  "Run each scheduled thunk when it falls due, until SET is :STOPPED."
  (loop
    (let ((thunk
            (sb-thread:with-mutex ((sidecar-set-lock set))
              (loop
                (when (eq (sidecar-set-state set) :stopped) (return-from %supervise))
                (let ((next (first (sidecar-set-queue set))))
                  (if (and next (<= (car next) (get-internal-real-time)))
                      (return (cdr (pop (sidecar-set-queue set))))
                      (%timed-wait (sidecar-set-changed set) (sidecar-set-lock set)
                                   (if next
                                       (max 0.01 (/ (- (car next) (get-internal-real-time))
                                                    internal-time-units-per-second))
                                       1))))))))
      (handler-case (funcall thunk)
        (error (e) (log:warn "hyperion/sidecar: supervisor step failed" :error (type-of e)))))))

(defun %on-supervisor (set thunk &key closing)
  "Run THUNK on SET's supervisor thread and return its value, or signal what it signalled. Signals
SIDECAR-SET-STOPPED when SET is not :RUNNING, or stops before THUNK runs. CLOSING true lets
STOP-SIDECARS run its own work while SET is :CLOSING."
  (let ((done (sb-thread:make-semaphore :name "hyperion/sidecar request"))
        (result nil) (failure nil) (ran nil))
    (sb-thread:with-mutex ((sidecar-set-lock set))
      (unless (or (eq (sidecar-set-state set) :running)
                  (and closing (eq (sidecar-set-state set) :closing)))
        (error 'sidecar-set-stopped))
      (push done (sidecar-set-waiting set))
      (%enqueue set 0 (lambda ()
                        (handler-case (setf result (funcall thunk))
                          (error (e) (setf failure e)))
                        (setf ran t)
                        (sb-thread:signal-semaphore done))))
    (sb-thread:wait-on-semaphore done)
    (sb-thread:with-mutex ((sidecar-set-lock set))
      (setf (sidecar-set-waiting set) (remove done (sidecar-set-waiting set))))
    (cond (failure (error failure))
          ((not ran) (error 'sidecar-set-stopped))
          (t result))))

(defvar *live-sets* '() "Every set not yet stopped, so the image's exit stops them.")
(defvar *live-sets-lock* (sb-thread:make-mutex :name "hyperion/sidecar live sets"))

(defun %not-started (name reason)
  (error 'sidecar-not-started :name name :reason reason))

(defun %start-one (set s)
  "Launch S on SET's supervisor and wait for it to be ready. Signals the sidecar condition when it
does not start or does not become ready; a sidecar that is not :REQUIRED and whose program is not
found is logged instead."
  (let* ((d (sidecar-spec s))
         (name (decl-name d))
         (result (%on-supervisor set (lambda () (%launch s)))))
    (case result
      (:started
       (setf (gethash name *running*) s)
       (ecase (%wait-ready s (decl-ready-timeout d))
         (:ready)
         (:timeout (error 'sidecar-not-ready :name name :reason :timeout))
         ((:exited :not-started)
          (error 'sidecar-not-ready :name name :reason :exited :exit-code (sidecar-exit-code s)))))
      (:not-found
       (if (decl-required d)
           (%not-started name :not-found)
           (log:warn (format nil "hyperion/sidecar: sidecar ~(~S~) not started: ~A not found on PATH"
                             name (first (decl-command d)))
                     :name name)))
      (t (%not-started name result)))))

(defun start-sidecars (names &key port)
  "Start the declared sidecars NAMES, with PORT, the server's bound port, for \"{port}\", and wait
until each is ready. Returns a SIDECAR-SET for STOP-SIDECARS.

A sidecar whose program is not on PATH is skipped with a warning, unless it is declared :REQUIRED,
when SIDECAR-NOT-STARTED is signalled. SIDECAR-NOT-STARTED is also signalled when a sidecar cannot
be started at all, for example because Windows could not put it in a job object. A sidecar that
has not become ready by its :READY-TIMEOUT, or exits first, signals SIDECAR-NOT-READY. Before any
of these is signalled, every sidecar this call started is stopped."
  (let ((set (%make-set)) (ok nil))
    (dolist (name names)
      (unless (find-sidecar name)
        (%not-started name :undeclared))
      (when (and (null port) (sidecar-uses-port-p name))
        (%not-started name :no-port)))
    #-win32 (%reap-leftovers)
    (setf (sidecar-set-supervisor set)
          ;; The settings in force when START-SIDECARS is called are the ones its launches and
          ;; stops use, so they are bound again in the supervisor thread, where those run.
          (let ((state-directory *state-directory*)
                (stop-seconds *stop-seconds*)
                #+win32 (job-function *job-function*)
                #-win32 (setpriv *setpriv*))
            ;; THREAD-LIFETIME: independent -- it lives as long as the set, because on Linux each
            ;; sidecar's parent-death signal is tied to the thread that started it; STOP-SIDECARS
            ;; ends and joins it.
            (sb-thread:make-thread (lambda ()
                                     (aion/dynamic:unblock-interrupts)
                                     (let ((*state-directory* state-directory)
                                           (*stop-seconds* stop-seconds)
                                           #+win32 (*job-function* job-function)
                                           #-win32 (*setpriv* setpriv))
                                       (%supervise set)))
                                   :name "hyperion/sidecar supervisor")))
    (sb-thread:with-mutex (*live-sets-lock*) (push set *live-sets*))
    (unwind-protect
         (progn
           (dolist (name names)
             (let ((s (%make-sidecar (find-sidecar name) set)))
               (setf (sidecar-port s) port)
               (sb-thread:with-mutex ((sidecar-set-lock set))
                 (push s (sidecar-set-sidecars set)))
               (%start-one set s)))
           (setf ok t)
           set)
      (unless ok (stop-sidecars set)))))

(defun stop-sidecars (set)
  "Stop every sidecar in SET and its supervisor. Idempotent. Returns NIL.

SET is closed first, so no restart or other work starts, and a caller waiting for work on it is
told SIDECAR-SET-STOPPED. The sidecars are then stopped on the supervisor thread, which exits only
after that."
  (when (sidecar-set-p set)
    (let ((waiting '()) (closed-now nil))
      (sb-thread:with-mutex ((sidecar-set-lock set))
        (when (eq (sidecar-set-state set) :running)
          (setf (sidecar-set-state set) :closing
                (sidecar-set-queue set) '()
                waiting (sidecar-set-waiting set)
                closed-now t)))
      ;; Their thunks were dropped with the queue, so they are woken here and see that.
      (dolist (sem waiting) (sb-thread:signal-semaphore sem))
      (when closed-now
        (let* ((sup (sidecar-set-supervisor set))
               (stop-all (lambda ()
                           (dolist (s (sidecar-set-sidecars set))
                             (ignore-errors (%stop-one s))))))
          (if (and sup (sb-thread:thread-alive-p sup) (not (eq sup sb-thread:*current-thread*)))
              (handler-case (%on-supervisor set stop-all :closing t)
                (error () (funcall stop-all)))
              (funcall stop-all))
          (sb-thread:with-mutex ((sidecar-set-lock set))
            (setf (sidecar-set-state set) :stopped)
            (sb-thread:condition-broadcast (sidecar-set-changed set)))
          (when (and sup (not (eq sup sb-thread:*current-thread*)))
            (sb-thread:join-thread sup :default nil :timeout 5))
          (sb-thread:with-mutex (*live-sets-lock*)
            (setf *live-sets* (remove set *live-sets*)))))))
  nil)

(defun update-sidecar-port (set port)
  "After the server was restarted on PORT, restart each sidecar in SET whose command uses {port}
and was started with a different port, and wait until it is ready. Returns the names restarted.

A replacement that does not start or become ready is stopped, its port is forgotten so the next
call tries it again, and the sidecar's condition is signalled, as at START-SIDECARS."
  (when (sidecar-set-p set)
    (loop for s in (sidecar-set-sidecars set)
          when (and (sidecar-uses-port-p (%name s)) (not (eql port (sidecar-port s))))
            do (setf (sidecar-port s) port)
               (handler-bind ((error (lambda (e)
                                       (declare (ignore e))
                                       (setf (sidecar-port s) nil)
                                       (ignore-errors
                                        (%on-supervisor set (lambda () (%stop-process s)))))))
                 (%start-one set s))
            and collect (%name s))))

(defun %stop-live-sets ()
  (dolist (set (sb-thread:with-mutex (*live-sets-lock*) (copy-list *live-sets*)))
    (ignore-errors (let ((*stop-seconds* 1)) (stop-sidecars set)))))

(pushnew '%stop-live-sets sb-ext:*exit-hooks*)

;;; --- reading them -------------------------------------------------------------------------

(defun sidecar-value (name)
  "The value the running sidecar NAME captured: an AION/SECRET when it is declared :SECRET, else a
string. NIL while it is not running or not yet ready."
  (let ((s (gethash name *running*)))
    (and s (eq (sidecar-state s) :ready) (sidecar-captured s))))

(defun sidecar-status (name)
  "The state of the sidecar NAME, one of :STARTING, :READY, :EXITED and :NOT-STARTED, and as a
second value its exit code once it has exited. Never its captured value."
  (let ((s (gethash name *running*)))
    (if s
        (values (sidecar-state s) (sidecar-exit-code s))
        (values :not-started nil))))
