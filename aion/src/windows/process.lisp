;;;; process.lisp --- starting a process inside a kill-on-close job, with no console window (#700).
;;;;
;;;; SB-EXT:RUN-PROGRAM starts a process running, so it can be put in a job object only after it
;;;; has started, and anything it starts in that window is outside the job and outlives it
;;;; (job.lisp). RUN-PROGRAM also cannot pass CREATE_NO_WINDOW, so a console program started from
;;;; an image with no console of its own opens a console window.
;;;;
;;;; SPAWN-IN-JOB calls CreateProcessW itself. The process is created suspended and with
;;;; CREATE_NO_WINDOW, put in its job, and only then resumed, so every process it starts is in
;;;; the job too. Its standard input, output and error are pipes made with SB-UNIX:UNIX-PIPE, the
;;;; same pipes RUN-PROGRAM makes, and the image's ends are SBCL fd-streams. On Windows an SBCL
;;;; fd-stream's descriptor is the Windows handle itself, so no C runtime descriptor is involved.
;;;;
;;;; The child inherits only its three standard handles. They are named in a
;;;; PROC_THREAD_ATTRIBUTE_HANDLE_LIST, so a pipe end that another thread has made inheritable
;;;; for its own child at the same moment is not inherited here. The reverse case is not covered:
;;;; a RUN-PROGRAM call in another thread, between a pipe end being made inheritable here and
;;;; CreateProcessW returning, inherits that end, because RUN-PROGRAM passes no list. The pipe
;;;; then stays open until that other process exits.
;;;;
;;;; Batch files are refused. CreateProcessW runs a .bat or .cmd file through cmd.exe, which
;;;; parses the command line by different rules from the ones QUOTE-WINDOWS-ARGUMENT follows, so
;;;; an argument could be read as a command. SB-EXT:RUN-PROGRAM's :SEARCH does not find batch
;;;; files either.

(in-package #:aion/windows)

;;; --- conditions -------------------------------------------------------------

(define-condition process-not-started (error)
  ((program :initarg :program :reader process-not-started-program)
   (reason :initarg :reason :reader process-not-started-reason))
  (:report (lambda (c s)
             (format s "~A was not started: ~A" (process-not-started-program c)
                     (ecase (process-not-started-reason c)
                       (:not-found "no executable by that name was found")
                       (:batch-file "it is a batch file, which is not supported")))))
  (:documentation "SPAWN-IN-JOB could not start PROGRAM. REASON is :NOT-FOUND, when no .exe or .com
file by that name exists on PATH or at the path given, or :BATCH-FILE. The report names the
program and never its arguments, which can carry a secret."))

;;; --- the command line -------------------------------------------------------

(defun quote-windows-argument (argument)
  "ARGUMENT quoted so that a program that parses its command line by the Microsoft C runtime's
rules, as CommandLineToArgvW does, reads it back unchanged. An argument with no space, tab,
newline, vertical tab or double quote, and not empty, is returned as it is. Otherwise it is put in
double quotes, a double quote in it is preceded by a backslash, and each run of backslashes that
comes before a double quote or the end is doubled."
  (if (and (plusp (length argument))
           (not (find-if (lambda (c) (member c '(#\Space #\Tab #\Newline #\Vt #\")))
                         argument)))
      argument
      (with-output-to-string (out)
        (write-char #\" out)
        (let ((backslashes 0))
          (loop for c across argument
                do (case c
                     (#\\ (incf backslashes))
                     (#\" (loop repeat (1+ (* 2 backslashes)) do (write-char #\\ out))
                          (setf backslashes 0)
                          (write-char #\" out))
                     (t (loop repeat backslashes do (write-char #\\ out))
                        (setf backslashes 0)
                        (write-char c out))))
          (loop repeat (* 2 backslashes) do (write-char #\\ out)))
        (write-char #\" out))))

(defun windows-command-line (program arguments)
  "The command line CreateProcessW is given for PROGRAM and the list of strings ARGUMENTS: each
quoted by QUOTE-WINDOWS-ARGUMENT and separated by one space."
  (format nil "~{~A~^ ~}" (mapcar #'quote-windows-argument (cons program arguments))))

;;; --- finding the program ----------------------------------------------------

(defun %executable-type-p (type)
  (and type (member type '("exe" "com") :test #'string-equal)))

(defun %batch-type-p (type)
  (and type (member type '("bat" "cmd") :test #'string-equal)))

(defun %candidates (name)
  "NAME as given when it has an extension, otherwise NAME with .exe and then .com."
  (if (pathname-type (pathname name))
      (list name)
      (list (concatenate 'string name ".exe") (concatenate 'string name ".com"))))

(defun find-executable (name &key (path (uiop:getenv "PATH")))
  "The native namestring of the .exe or .com file NAME names, or NIL. A NAME with a directory in
it is looked for there. A bare NAME is looked for in each directory of PATH in turn. A NAME
without an extension is tried with .exe and then .com. Batch files are not looked for, and a NAME
that ends in .bat or .cmd is returned as it is found, for SPAWN-IN-JOB to refuse."
  (flet ((existing (candidate)
           (let ((found (probe-file candidate)))
             (and found
                  (pathname-name found)
                  (or (%executable-type-p (pathname-type found))
                      (%batch-type-p (pathname-type found)))
                  (uiop:native-namestring found)))))
    (if (or (find #\\ name) (find #\/ name) (find #\: name))
        (some #'existing (%candidates name))
        (loop for directory in (uiop:split-string (or path "") :separator ";")
              for dir = (string-right-trim "\\/" directory)
              thereis (and (plusp (length dir))
                           (some (lambda (c) (existing (concatenate 'string dir "\\" c)))
                                 (%candidates name)))))))

;;; --- the process ------------------------------------------------------------

(defstruct (job-process (:constructor %make-job-process))
  "A process started by SPAWN-IN-JOB. INPUT, OUTPUT and ERROR are the image's ends of the
process's standard streams, or NIL for one that was not :STREAM. JOB is the kill-on-close job
the process is in, or NIL when it could not be put in one. The process handle is kept open until
JOB-PROCESS-CLOSE, so PID cannot be given to another process before then."
  (pid 0 :type integer :read-only t)
  (handle nil :read-only t)
  (job nil)
  (input nil)
  (output nil)
  (error nil)
  ;; Read when JOB-PROCESS-CLOSE closes the handle, so the exit code stays readable after it.
  (closed-exit-code nil)
  (lock (sb-thread:make-mutex :name "aion/windows job-process")))

(defun %process-pointer (process)
  (let ((h (job-process-handle process)))
    (and (handle-valid-p h) (handle-pointer h))))

(defun job-process-alive-p (process)
  "Whether PROCESS is still running. False once JOB-PROCESS-CLOSE has closed it."
  (let ((p (%process-pointer process)))
    (and p (= (ffi:wait-for-single-object p 0) ffi:+wait-timeout+))))

(defun %read-exit-code (pointer)
  (when (= (ffi:wait-for-single-object pointer 0) ffi:+wait-object-0+)
    (cffi:with-foreign-object (code 'ffi:dword)
      (check-win32 (ffi:get-exit-code-process pointer code)
                   :operation :get-exit-code-process :predicate #'%true-p)
      (cffi:mem-ref code 'ffi:dword))))

(defun job-process-exit-code (process)
  "PROCESS's exit code once it has exited, or NIL while it runs. After JOB-PROCESS-CLOSE, the exit
code it had when it was closed, which is NIL if it was still running then."
  (let ((p (%process-pointer process)))
    (if p
        (%read-exit-code p)
        (job-process-closed-exit-code process))))

(defun job-process-status (process)
  ":RUNNING or :EXITED. A closed PROCESS is :EXITED."
  (if (job-process-alive-p process) :running :exited))

(defun job-process-wait (process &optional seconds)
  "Wait for PROCESS to exit, up to SECONDS, or for as long as it runs when SECONDS is NIL. Returns
whether it has exited. The wait is made in slices of 50 ms, so the waiting thread can still be
interrupted."
  (let ((deadline (and seconds (+ (get-internal-real-time)
                                  (round (* seconds internal-time-units-per-second))))))
    (loop
      (let ((p (%process-pointer process)))
        (when (or (null p) (= (ffi:wait-for-single-object p 50) ffi:+wait-object-0+))
          (return t)))
      (when (and deadline (> (get-internal-real-time) deadline))
        (return nil)))))

(defun job-process-terminate (process &optional (exit-code 1))
  "End PROCESS with EXIT-CODE. When it is in a job, the job is terminated, which ends every process
started inside it too. When it is not, TerminateProcess ends it alone. Returns T, or NIL when it
had already been closed. Signals WIN32-ERROR when Windows refuses."
  (sb-thread:with-mutex ((job-process-lock process))
    (let ((job (job-process-job process))
          (p (%process-pointer process)))
      (cond ((and job (handle-valid-p job)) (terminate-job job exit-code))
            (p (check-win32 (ffi:terminate-process p exit-code)
                            :operation :terminate-process :predicate #'%true-p)
               t)
            (t nil)))))

(defun job-process-close (process)
  "Close PROCESS's streams, its process handle and its job, if it still holds one. Closing the job
ends every process still in it. Idempotent. A caller that wants the job to outlive this takes it
first with (SHIFTF (JOB-PROCESS-JOB PROCESS) NIL), and closes it itself."
  (let ((streams '()) (job nil))
    (sb-thread:with-mutex ((job-process-lock process))
      (setf streams (list (shiftf (job-process-input process) nil)
                          (shiftf (job-process-output process) nil)
                          (shiftf (job-process-error process) nil))
            job (shiftf (job-process-job process) nil)))
    (dolist (s streams)
      (when s (ignore-errors (close s :abort t))))
    (when job (close-handle job))
    (sb-thread:with-mutex ((job-process-lock process))
      (let ((p (%process-pointer process)))
        (when p
          (setf (job-process-closed-exit-code process) (ignore-errors (%read-exit-code p)))
          (close-handle (job-process-handle process)))))
    nil))

;;; --- spawning ---------------------------------------------------------------

(defun default-job-function (pid)
  "A new kill-on-close job with the process PID in it. No handle is left open when either step
signals."
  (let ((job (make-kill-on-close-job)))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (close-handle job))))
      (assign-process-to-job job pid))
    job))

(defun %set-inheritable (raw inheritable)
  (check-win32 (ffi:set-handle-information (cffi:make-pointer raw) ffi:+handle-flag-inherit+
                                           (if inheritable ffi:+handle-flag-inherit+ 0))
               :operation :set-handle-information :predicate #'%true-p))

(defun %open-inheritable (namestring access)
  "A raw inheritable handle on the file NAMESTRING, created if missing, for ACCESS."
  (cffi:with-foreign-object (sa '(:struct ffi:security-attributes))
    (setf (cffi:foreign-slot-value sa '(:struct ffi:security-attributes) 'ffi:n-length)
          (cffi:foreign-type-size '(:struct ffi:security-attributes))
          (cffi:foreign-slot-value sa '(:struct ffi:security-attributes) 'ffi:lp-security-descriptor)
          (cffi:null-pointer)
          (cffi:foreign-slot-value sa '(:struct ffi:security-attributes) 'ffi:b-inherit-handle)
          1)
    (with-wide-string (name namestring)
      (let ((h (ffi:create-file-w name access
                                  (logior ffi:+file-share-read+ ffi:+file-share-write+)
                                  sa ffi:+open-always+ ffi:+file-attribute-normal+
                                  (cffi:null-pointer))))
        (when (or (cffi:null-pointer-p h) (cffi:pointer-eq h (%invalid-handle-value)))
          (check-win32 nil :operation :create-file :predicate #'identity))
        (cffi:pointer-address h)))))

(defun %close-raw (raw)
  (ffi::%close-handle (cffi:make-pointer raw)))

(defun %environment-block (environment)
  "A foreign UTF-16LE environment block for the list of \"NAME=VALUE\" strings ENVIRONMENT: each
string followed by a NUL, and one more NUL at the end. Freed with CFFI:FOREIGN-STRING-FREE."
  (cffi:foreign-string-alloc
   (format nil "~{~A~C~}" (loop for e in environment collect e collect (code-char 0)))
   :encoding :utf-16le))

(defun spawn-in-job (program arguments &key environment directory
                                            (input nil) (output nil) (error nil)
                                            (element-type :default)
                                            (external-format :utf-8)
                                            (job-function 'default-job-function)
                                            (if-no-job :error))
  "Start PROGRAM with the list of strings ARGUMENTS, suspended and with no console window, put it
in a job made by JOB-FUNCTION, then let it run. Return a JOB-PROCESS, and as a second value NIL,
or the condition JOB-FUNCTION signalled when IF-NO-JOB is :CONTINUE.

PROGRAM is found by FIND-EXECUTABLE. PROCESS-NOT-STARTED is signalled when it is not found or is
a batch file. ENVIRONMENT is a list of \"NAME=VALUE\" strings that replaces this image's
environment, or NIL to inherit it. DIRECTORY is the working directory, or NIL for this image's.

INPUT and OUTPUT are :STREAM, for a pipe whose other end becomes JOB-PROCESS-INPUT or
JOB-PROCESS-OUTPUT, or NIL, for the NUL device. ERROR is :STREAM, NIL, or a pathname or string
naming a file the process's standard error is appended to. The streams are SBCL fd-streams with
ELEMENT-TYPE and EXTERNAL-FORMAT; the default ELEMENT-TYPE, :DEFAULT, reads both characters and
octets.

JOB-FUNCTION is called with the suspended process's pid and returns a job HANDLE. When it signals
and IF-NO-JOB is :ERROR, the process is ended before it has run and the condition is resignalled.
When IF-NO-JOB is :CONTINUE, the process runs outside any job."
  (let* ((path (or (find-executable program)
                   (cl:error 'process-not-started :program program :reason :not-found)))
         (child-ends '())                 ; raw handles the child inherits, closed here after
         (parent-ends (list :input nil :output nil :error nil))
         (process nil) (job nil) (job-error nil) (thread nil)
         (done nil))
    (when (%batch-type-p (pathname-type (pathname path)))
      (cl:error 'process-not-started :program program :reason :batch-file))
    (flet ((pipe (slot child-reads)
             (multiple-value-bind (r w) (sb-unix:unix-pipe)
               (let ((child (if child-reads r w)) (parent (if child-reads w r)))
                 (setf (getf parent-ends slot) parent)
                 (push child child-ends)
                 (%set-inheritable parent nil)
                 (%set-inheritable child t)
                 child)))
           (nul (access) (let ((h (%open-inheritable "NUL" access))) (push h child-ends) h))
           (file (spec)
             (let ((h (%open-inheritable (uiop:native-namestring (pathname spec))
                                         ffi:+file-append-data+)))
               (push h child-ends)
               h)))
      (unwind-protect
           (let ((stdin (ecase input
                          (:stream (pipe :input t))
                          ((nil) (nul ffi:+generic-read+))))
                 (stdout (ecase output
                           (:stream (pipe :output nil))
                           ((nil) (nul ffi:+generic-write+))))
                 (stderr (cond ((eq error :stream) (pipe :error nil))
                               ((null error) (nul ffi:+generic-write+))
                               (t (file error)))))
             (multiple-value-setq (process thread)
               (%create-suspended path (windows-command-line path arguments)
                                  environment directory (list stdin stdout stderr)))
             (dolist (h child-ends) (%close-raw h))
             (setf child-ends '())
             (handler-case (setf job (funcall job-function (job-process-pid process)))
               (cl:error (e)
                 (when (eq if-no-job :error)
                   (ffi:terminate-process (handle-pointer (job-process-handle process)) 1)
                   (cl:error e))
                 (setf job-error e)))
             (setf (job-process-job process) job)
             (when (= (ffi:resume-thread (handle-pointer thread)) #xFFFFFFFF)
               (check-win32 nil :operation :resume-thread))
             (flet ((stream-for (slot direction)
                      (let ((raw (getf parent-ends slot)))
                        (when raw
                          (setf (getf parent-ends slot) nil)
                          (sb-sys:make-fd-stream raw direction t
                                                 :element-type element-type
                                                 :external-format external-format
                                                 :buffering :full :auto-close t)))))
               (setf (job-process-input process) (stream-for :input :output)
                     (job-process-output process) (stream-for :output :input)
                     (job-process-error process) (stream-for :error :input)))
             (setf done t)
             (values process job-error))
        (when thread (close-handle thread))
        (dolist (h child-ends) (%close-raw h))
        (unless done
          (loop for (nil raw) on parent-ends by #'cddr when raw do (%close-raw raw))
          (when process
            (ignore-errors (ffi:terminate-process (handle-pointer (job-process-handle process)) 1))
            (job-process-close process))
          (when job (close-handle job)))))))

(defun %create-suspended (path command-line environment directory std-handles)
  "CreateProcessW for PATH, suspended and with no console window, inheriting only STD-HANDLES, the
raw stdin, stdout and stderr handles. Returns a JOB-PROCESS with no job or streams yet, and the
HANDLE of its main thread."
  (cffi:with-foreign-objects ((size :size)
                              (info '(:struct ffi:startupinfoex-w))
                              (pi-out '(:struct ffi:process-information))
                              (handles :pointer 3))
    ;; The first call fails by design and only reports the size.
    (setf (cffi:mem-ref size :size) 0)
    (ffi:initialize-proc-thread-attribute-list (cffi:null-pointer) 1 0 size)
    (let ((attributes (cffi:foreign-alloc :uint8 :count (cffi:mem-ref size :size)))
          (initialized nil)
          (command (cffi:foreign-string-alloc command-line :encoding :utf-16le))
          (app (lisp-to-wide-string path))
          (env (and environment (%environment-block environment)))
          (cwd (and directory (lisp-to-wide-string (uiop:native-namestring directory)))))
      (unwind-protect
           (progn
             (check-win32 (ffi:initialize-proc-thread-attribute-list attributes 1 0 size)
                          :operation :initialize-proc-thread-attribute-list :predicate #'%true-p)
             (setf initialized t)
             (loop for raw in std-handles for i from 0
                   do (setf (cffi:mem-aref handles :pointer i) (cffi:make-pointer raw)))
             (check-win32 (ffi:update-proc-thread-attribute
                           attributes 0 ffi:+proc-thread-attribute-handle-list+ handles
                           (* 3 (cffi:foreign-type-size :pointer))
                           (cffi:null-pointer) (cffi:null-pointer))
                          :operation :update-proc-thread-attribute :predicate #'%true-p)
             (dotimes (i (cffi:foreign-type-size '(:struct ffi:startupinfoex-w)))
               (setf (cffi:mem-aref info :uint8 i) 0))
             (let ((si (cffi:foreign-slot-pointer info '(:struct ffi:startupinfoex-w)
                                                  'ffi:startup-info)))
               (setf (cffi:foreign-slot-value si '(:struct ffi:startupinfo-w) 'ffi:cb)
                     (cffi:foreign-type-size '(:struct ffi:startupinfoex-w))
                     (cffi:foreign-slot-value si '(:struct ffi:startupinfo-w) 'ffi:dw-flags)
                     ffi:+startf-usestdhandles+
                     (cffi:foreign-slot-value si '(:struct ffi:startupinfo-w) 'ffi:h-std-input)
                     (cffi:make-pointer (first std-handles))
                     (cffi:foreign-slot-value si '(:struct ffi:startupinfo-w) 'ffi:h-std-output)
                     (cffi:make-pointer (second std-handles))
                     (cffi:foreign-slot-value si '(:struct ffi:startupinfo-w) 'ffi:h-std-error)
                     (cffi:make-pointer (third std-handles))))
             (setf (cffi:foreign-slot-value info '(:struct ffi:startupinfoex-w)
                                            'ffi:lp-attribute-list)
                   attributes)
             (check-win32 (ffi:create-process-w
                           app command (cffi:null-pointer) (cffi:null-pointer) 1
                           (logior ffi:+create-suspended+ ffi:+create-no-window+
                                   ffi:+extended-startupinfo-present+
                                   (if env ffi:+create-unicode-environment+ 0))
                           (or env (cffi:null-pointer)) (or cwd (cffi:null-pointer))
                           info pi-out)
                          :operation :create-process :predicate #'%true-p)
             (flet ((slot (name)
                      (cffi:foreign-slot-value pi-out '(:struct ffi:process-information) name)))
               (values (%make-job-process :pid (slot 'ffi:dw-process-id)
                                          :handle (wrap-handle (slot 'ffi:h-process)
                                                               :kind :process))
                       (wrap-handle (slot 'ffi:h-thread) :kind :thread))))
        (when initialized (ffi:delete-proc-thread-attribute-list attributes))
        (cffi:foreign-free attributes)
        (cffi:foreign-string-free command)
        (free-wide-string app)
        (when env (cffi:foreign-string-free env))
        (when cwd (free-wide-string cwd))))))
