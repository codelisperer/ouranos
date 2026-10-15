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
           #:sidecar-not-ready-exit-code
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
                       (t (sidecar-not-started-reason c))))))
  (:documentation "A sidecar could not be started. REASON is :NOT-FOUND, for a program that is not
on PATH and a sidecar declared :REQUIRED T; :UNDECLARED, for a name DEFINE-SIDECAR never declared;
or :NO-PORT."))

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
and string values added to the image's environment. DIRECTORY is the working directory, or NIL.
READY is NIL, for a sidecar that is ready once it has started, or a function of one line of its
standard output or standard error that returns NIL or the captured string; see TOKEN-AFTER.
READY-TIMEOUT is how many seconds START-SIDECARS waits for it. SECRET true holds the captured value
as an AION/SECRET. REQUIRED true makes a program missing from PATH an error rather than a warning.
RESTART true starts the sidecar again when it exits by itself, after 1 s, then 2, 4 and so on up
to 30 s, without limit, and reads its value again."
  (check-type name keyword)
  (unless (and (consp command) (every #'stringp command))
    (error "The :COMMAND of sidecar ~S must be a non-empty list of strings." name))
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

(defun %spawn (name path arguments environment directory)
  "Start PATH with ARGUMENTS. Returns the platform's process object, whose standard output and
standard error are character streams."
  #-win32 (declare (ignorable name))
  #+win32
  (multiple-value-bind (process failure)
      (aion/windows:spawn-in-job path arguments
                                 :environment environment :directory directory
                                 :output :stream :error :stream :element-type 'character
                                 :external-format '(:utf-8 :replacement #\?)
                                 :if-no-job :continue)
    (when failure
      (log:warn "hyperion/sidecar: sidecar is not in a job object, so it can outlive the image"
                :name name :pid (aion/windows:job-process-pid process)
                :error (type-of failure)))
    process)
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

(defun %end (p)
  "End P, and on Windows everything in its job: on Unix SIGTERM to its process group, then SIGKILL
after *STOP-SECONDS*; on Windows the job is terminated at once. Returns how it ended."
  #+win32 (progn (ignore-errors (aion/windows:job-process-terminate p 1))
                 (%wait-exit p *stop-seconds*)
                 :terminated)
  #-win32 (flet ((signal-group (sig)
                   (ignore-errors (sb-ext:process-kill p sig :process-group))))
            (signal-group 15)
            (cond ((%wait-exit p *stop-seconds*) :terminated)
                  (t (signal-group 9) (%wait-exit p 2) :killed))))

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

(defstruct (sidecar (:constructor %make-sidecar (spec owner)))
  spec
  owner
  (lock (sb-thread:make-mutex :name "hyperion/sidecar"))
  (changed (sb-thread:make-waitqueue))
  ;; :STARTING, :READY, :EXITED or :NOT-STARTED.
  (state :not-started)
  process
  captured
  exit-code
  port
  (stopping nil)
  (attempt 0)
  ready-at
  readers
  watcher
  state-file)

(defvar *running* (make-hash-table :test #'eq :synchronized t)
  "The running SIDECAR for each name, which SIDECAR-VALUE reads.")

(defun %set-state (s state &rest more)
  (sb-thread:with-mutex ((sidecar-lock s))
    (setf (sidecar-state s) state)
    (loop for (slot value) on more by #'cddr
          do (ecase slot
               (:captured (setf (sidecar-captured s) value))
               (:exit-code (setf (sidecar-exit-code s) value))
               (:ready-at (setf (sidecar-ready-at s) value))))
    (sb-thread:condition-broadcast (sidecar-changed s))))

(defun %name (s) (decl-name (sidecar-spec s)))

(defun %read-lines (s stream which generation)
  "Read STREAM line by line until it ends. Each line is logged at debug level, and offered to the
:READY function while the sidecar is starting."
  (let ((ready (decl-ready (sidecar-spec s))))
    (handler-case
        (loop for line = (read-line stream nil nil)
              while line
              do (log:debug "hyperion/sidecar: output" :name (%name s) :stream which :line line)
                 (when (and ready (eq (sidecar-state s) :starting)
                            (= generation (sidecar-attempt s)))
                   (let ((value (ignore-errors (funcall ready line))))
                     (when value
                       (%set-state s :ready
                                   :captured (if (decl-secret (sidecar-spec s))
                                              (secret:make-secret value)
                                              value)
                                   :ready-at (get-universal-time))
                       (log:info "hyperion/sidecar: ready" :name (%name s)
                                 :pid (%pid (sidecar-process s)) :captured t)))))
      (error () nil))))

(defun %restart-delay (attempt)
  "Seconds to wait before launch number ATTEMPT, where 1 is the first launch and 2 the first
restart: 1 s before the first restart, doubling to at most 30 s."
  (min 30 (expt 2 (max 0 (- attempt 2)))))

(defun %watch (s process generation)
  "Wait for PROCESS to exit, record its exit code, and schedule a restart when the sidecar is
declared :RESTART and is not being stopped."
  (loop while (%alive-p process) do (sleep 0.1))
  (let ((code (%exit-code process)))
    (%set-state s :exited :exit-code code :captured nil)
    (unless (sidecar-stopping s)
      (log:info "hyperion/sidecar: exited" :name (%name s) :pid (%pid process) :code code)
      (when (and (decl-restart (sidecar-spec s))
                 (= generation (sidecar-attempt s)))
        ;; Back to the first restart's delay after a run that stayed up for a minute.
        (let* ((ready-at (sidecar-ready-at s))
               (attempt (if (and ready-at (> (- (get-universal-time) ready-at) 60))
                            2
                            (1+ generation)))
               (delay (%restart-delay attempt)))
          (log:warn "hyperion/sidecar: restarting" :name (%name s) :attempt attempt :delay delay)
          (%schedule (sidecar-owner s) delay
                     (lambda () (unless (sidecar-stopping s) (%launch s :attempt attempt)))))))))

(defun %launch (s &key (attempt 1))
  "Start S's process, on its set's supervisor thread, with its reader and watcher threads. Returns
:STARTED, or :NOT-FOUND when its program is not on PATH."
  (let* ((d (sidecar-spec s))
         (command (mapcar (lambda (a) (%substitute-port a (sidecar-port s))) (decl-command d)))
         (path (%find-program (first command))))
    (unless path
      (%set-state s :not-started)
      (return-from %launch :not-found))
    (let ((old (sidecar-process s)))
      (when old (%release s old)))
    (let ((process (%spawn (decl-name d) path (rest command) (%environment (decl-environment d))
                           (decl-directory d))))
      (sb-thread:with-mutex ((sidecar-lock s))
        (setf (sidecar-process s) process
              (sidecar-attempt s) attempt
              (sidecar-state s) (if (decl-ready d) :starting :ready)
              (sidecar-captured s) nil
              (sidecar-exit-code s) nil
              (sidecar-ready-at s) (unless (decl-ready d) (get-universal-time)))
        (sb-thread:condition-broadcast (sidecar-changed s)))
      #-win32 (setf (sidecar-state-file s) (ignore-errors (%write-state (%pid process) path)))
      (log:info "hyperion/sidecar: started" :name (decl-name d) :pid (%pid process)
                :attempt attempt)
      (setf (sidecar-readers s)
            ;; THREAD-LIFETIME: scoped -- each reads one of this process's streams until it
            ;; ends, which it does once the process and anything holding the pipe have ended;
            ;; %RELEASE joins them.
            (list (sb-thread:make-thread (lambda () (%read-lines s (%output process) :stdout attempt))
                                         :name "hyperion/sidecar stdout")
                  (sb-thread:make-thread (lambda () (%read-lines s (%error-stream process) :stderr attempt))
                                         :name "hyperion/sidecar stderr"))
            (sidecar-watcher s)
            ;; THREAD-LIFETIME: scoped -- it ends when this process has exited; %RELEASE joins it.
            (sb-thread:make-thread (lambda () (%watch s process attempt))
                                   :name "hyperion/sidecar watcher"))
      :started)))

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

(defun %wait-ready (s timeout)
  "Wait until S is ready, has exited, or TIMEOUT seconds pass. Returns its state then."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (sb-thread:with-mutex ((sidecar-lock s))
      (loop
        (let ((state (sidecar-state s)))
          (unless (eq state :starting) (return state)))
        (let ((left (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)))
          (when (<= left 0) (return :timeout))
          (%timed-wait (sidecar-changed s) (sidecar-lock s) left))))))

(defun %stop-one (s)
  (setf (sidecar-stopping s) t)
  (let ((process (sidecar-process s)))
    (when process
      (let ((how (if (%alive-p process) (%end process) :exited)))
        (%release s process)
        (log:info "hyperion/sidecar: stopped" :name (%name s) :pid (%pid process) :how how
                  :code (%exit-code process)))))
  (%set-state s :exited :captured nil)
  (when (eq (gethash (%name s) *running*) s)
    (remhash (%name s) *running*)))

;;; --- a set of sidecars and its supervisor -------------------------------------------------

(defstruct (sidecar-set (:constructor %make-set ()))
  "The sidecars one START-SIDECARS started, and the supervisor thread that starts each of them."
  (sidecars '())
  (lock (sb-thread:make-mutex :name "hyperion/sidecar set"))
  (changed (sb-thread:make-waitqueue))
  (queue '())                           ; (due-internal-time . thunk), sorted by due time
  (stopping nil)
  supervisor)

(defun %schedule (set seconds thunk)
  (sb-thread:with-mutex ((sidecar-set-lock set))
    (unless (sidecar-set-stopping set)
      (setf (sidecar-set-queue set)
            (merge 'list (sidecar-set-queue set)
                   (list (cons (+ (get-internal-real-time)
                                  (round (* seconds internal-time-units-per-second)))
                               thunk))
                   #'< :key #'car))
      (sb-thread:condition-broadcast (sidecar-set-changed set)))))

(defun %supervise (set)
  "Run each scheduled thunk when it falls due, until SET is stopping."
  (loop
    (let ((thunk
            (sb-thread:with-mutex ((sidecar-set-lock set))
              (loop
                (when (sidecar-set-stopping set) (return-from %supervise))
                (let ((next (first (sidecar-set-queue set))))
                  (if (and next (<= (car next) (get-internal-real-time)))
                      (return (cdr (pop (sidecar-set-queue set))))
                      (%timed-wait
                       (sidecar-set-changed set) (sidecar-set-lock set)
                       (if next
                                    (max 0.01 (/ (- (car next) (get-internal-real-time))
                                                 internal-time-units-per-second))
                                    1))))))))
      (handler-case (funcall thunk)
        (error (e) (log:warn "hyperion/sidecar: supervisor step failed" :error (type-of e)))))))

(defun %on-supervisor (set thunk)
  "Run THUNK on SET's supervisor thread and return its value, or signal what it signalled."
  (let ((done (sb-thread:make-semaphore)) (result nil) (failure nil))
    (%schedule set 0 (lambda ()
                       (handler-case (setf result (funcall thunk))
                         (error (e) (setf failure e)))
                       (sb-thread:signal-semaphore done)))
    (sb-thread:wait-on-semaphore done)
    (if failure (error failure) result)))

(defvar *live-sets* '() "Every set not yet stopped, so the image's exit stops them.")
(defvar *live-sets-lock* (sb-thread:make-mutex :name "hyperion/sidecar live sets"))

(defun start-sidecars (names &key port)
  "Start the declared sidecars NAMES, with PORT, the server's bound port, for \"{port}\", and wait
until each is ready. Returns a SIDECAR-SET for STOP-SIDECARS.

A sidecar whose program is not on PATH is skipped with a warning, unless it is declared :REQUIRED,
when SIDECAR-NOT-STARTED is signalled. A sidecar that has not become ready by its :READY-TIMEOUT,
or exits first, signals SIDECAR-NOT-READY. Before either is signalled, every sidecar this call
started is stopped."
  (let ((set (%make-set)) (ok nil))
    (dolist (name names)
      (unless (find-sidecar name)
        (error 'sidecar-not-started :name name :reason :undeclared))
      (when (and (null port) (sidecar-uses-port-p name))
        (error 'sidecar-not-started :name name :reason :no-port)))
    #-win32 (%reap-leftovers)
    (setf (sidecar-set-supervisor set)
          ;; THREAD-LIFETIME: independent -- it lives as long as the set, because on Linux each
          ;; sidecar's parent-death signal is tied to the thread that started it; STOP-SIDECARS
          ;; ends and joins it.
          (sb-thread:make-thread (lambda () (%supervise set)) :name "hyperion/sidecar supervisor"))
    (sb-thread:with-mutex (*live-sets-lock*) (push set *live-sets*))
    (unwind-protect
         (progn
           (dolist (name names)
             (let* ((d (find-sidecar name))
                    (s (%make-sidecar d set)))
               (setf (sidecar-port s) port)
               (push s (sidecar-set-sidecars set))
               (case (%on-supervisor set (lambda () (%launch s)))
                 (:not-found
                  (if (decl-required d)
                      (error 'sidecar-not-started :name name :reason :not-found)
                      (log:warn (format nil "hyperion/sidecar: sidecar ~(~S~) not started: ~A not found on PATH"
                                        name (first (decl-command d)))
                                :name name)))
                 (:started
                  (setf (gethash name *running*) s)
                  (ecase (%wait-ready s (decl-ready-timeout d))
                    (:ready)
                    (:timeout (error 'sidecar-not-ready :name name :reason :timeout))
                    ((:exited :not-started)
                     (error 'sidecar-not-ready :name name :reason :exited
                                               :exit-code (sidecar-exit-code s))))))))
           (setf ok t)
           set)
      (unless ok (stop-sidecars set)))))

(defun stop-sidecars (set)
  "Stop every sidecar in SET and its supervisor. Idempotent. Returns NIL."
  (when (sidecar-set-p set)
    (sb-thread:with-mutex ((sidecar-set-lock set))
      (setf (sidecar-set-stopping set) t
            (sidecar-set-queue set) '())
      (sb-thread:condition-broadcast (sidecar-set-changed set)))
    (let ((sup (sidecar-set-supervisor set)))
      (when (and sup (not (eq sup sb-thread:*current-thread*)))
        (sb-thread:join-thread sup :default nil :timeout 5)))
    (dolist (s (sidecar-set-sidecars set))
      (ignore-errors (%stop-one s)))
    (sb-thread:with-mutex (*live-sets-lock*)
      (setf *live-sets* (remove set *live-sets*))))
  nil)

(defun update-sidecar-port (set port)
  "After the server was restarted on PORT, restart each sidecar in SET whose command uses {port}
and was started with a different port. Returns the names restarted."
  (when (sidecar-set-p set)
    (loop for s in (sidecar-set-sidecars set)
          when (and (sidecar-uses-port-p (%name s)) (not (eql port (sidecar-port s)))
                    (sidecar-process s))
            do (let ((process (sidecar-process s)))
                 (setf (sidecar-stopping s) t)
                 (when (%alive-p process) (%end process))
                 (%release s process)
                 (setf (sidecar-port s) port
                       (sidecar-stopping s) nil)
                 (%on-supervisor set (lambda () (%launch s)))
                 (%wait-ready s (decl-ready-timeout (sidecar-spec s))))
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
