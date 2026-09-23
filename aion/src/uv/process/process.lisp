;;;; process.lisp --- spawning children, and reading how they ended.
;;;;
;;;; WHAT THIS IS FOR. `cons` runs build and test targets through uiop:run-program today,
;;;; which BLOCKS: a target's output arrives in a lump when it exits, so a five-minute
;;;; compile looks like five minutes of nothing followed by everything. uv_spawn with
;;;; piped stdio makes the output arrive as it is produced. That is the whole motivation,
;;;; and it is why the consumer is `cons` at DAG position 2 -- which is also why this
;;;; binding cannot live any further right.
;;;;
;;;; THE STDIO IS THE STREAM LAYER'S, NOT A SECOND ONE. A child's stdin/stdout/stderr are
;;;; uv_pipe_t, which is a uv_stream_t, so they are handed back as ordinary aion/uv/net
;;;; CONNECTIONs. START-READING, WRITE-BYTES, PIPE-INTO and the backpressure in
;;;; stream.lisp all apply with no additions -- which matters more than it sounds: a
;;;; child that writes faster than we consume is exactly the unbounded-buffer situation
;;;; that made Node rewrite its streams, and it is already solved one layer down.
;;;;
;;;; DIRECTION WORDS ARE FROM THE CHILD'S POINT OF VIEW, which is the single most
;;;; confusing thing in libuv's process API. The child READS its stdin, so that pipe is
;;;; UV_READABLE_PIPE and the PARENT writes to it. The child WRITES its stdout, so that
;;;; pipe is UV_WRITABLE_PIPE and the parent reads from it.
;;;;
;;;; HOW IT ENDED IS ONE FACT REPORTED AS TWO NUMBERS, and a process killed by a signal
;;;; has an exit status of zero -- so checking the status alone reports that a killed
;;;; build succeeded. TERMINATION and SUCCEEDED-P consult both; see types.lisp.

(in-package #:aion/uv/process)

(define-condition spawn-failed (uv:uv-error) ()
  (:documentation
   "uv_spawn refused to start the process -- most often ENOENT, meaning the program is
not on PATH. Distinct from a process that started and then failed, which is an ordinary
non-zero TERMINATION rather than a condition."))

(defstruct (process (:constructor %make-process))
  "A spawned child, its pipes, and how it ended once it has."
  pointer loop
  (pid 0)
  stdin stdout stderr
  exit-future
  (raw-exit-status nil)
  (raw-term-signal nil)
  on-exit
  (closed nil))

(defun process-running-p (process)
  "True until the exit callback has fired."
  (and (not (process-closed process))
       (null (process-raw-exit-status process))))

;;; ------------------------------------------------------------ how it ended

(defun exit-status (process)
  "The status the child passed to exit(), or NIL while it is still running.

MEANINGLESS ON ITS OWN if the child was killed -- see TERM-SIGNAL and SUCCEEDED-P."
  (process-raw-exit-status process))

(defun term-signal (process)
  "The number of the signal that killed the child, 0 if none did, NIL while running."
  (process-raw-term-signal process))

(defun termination (process)
  "How the child ended, rendered by the typed core: \"exited-0\", \"killed-SIGTERM\".
NIL while it is still running."
  (when (process-raw-exit-status process)
    (types:termination-tag (process-raw-exit-status process)
                           (process-raw-term-signal process))))

(defun succeeded-p (process)
  "True only if the child CHOSE to exit, with status zero.

A killed process is not a success however tidy its exit status looks, and its status is
zero, which is exactly the trap this function exists to close."
  (and (process-raw-exit-status process)
       (types:terminated-well? (process-raw-exit-status process)
                               (process-raw-term-signal process))))

(defun await-exit (process &key timeout)
  "Block until the child exits, then return it. The loop must be running elsewhere --
this waits on the future, it does not turn the loop."
  (uv:await (process-exit-future process) :timeout timeout)
  process)

;;; --------------------------------------------------------------- the callback

(cffi:defcallback %exit-callback :void
    ((handle :pointer) (exit-status :int64) (term-signal :int))
  (uv:with-callback-guard
    (let ((process (uv:lookup handle)))
      (when (process-p process)
        (setf (process-raw-exit-status process) exit-status
              (process-raw-term-signal process) term-signal)
        (uv:fulfill (process-exit-future process) process)
        (when (process-on-exit process)
          (funcall (process-on-exit process) process))))))

;;; ------------------------------------------------------------------ arguments

(defun %alloc-string-array (strings)
  "A NULL-terminated char** built from STRINGS. Freed by %FREE-STRING-ARRAY.

The strings need only survive the uv_spawn call: on unix libuv forks inside it, and on
Windows it converts them to UTF-16 before returning."
  (let* ((n (length strings))
         (array (cffi:foreign-alloc :pointer :count (1+ n))))
    (loop for s in strings
          for i from 0
          do (setf (cffi:mem-aref array :pointer i) (cffi:foreign-string-alloc s)))
    (setf (cffi:mem-aref array :pointer n) (cffi:null-pointer))
    array))

(defun %free-string-array (array count)
  (when (and array (not (cffi:null-pointer-p array)))
    (dotimes (i count)
      (let ((s (cffi:mem-aref array :pointer i)))
        (unless (cffi:null-pointer-p s) (cffi:foreign-string-free s))))
    (cffi:foreign-free array)))

(defun %environment-strings (env)
  "Render ENV -- an alist, a plist-free list of \"K=V\" strings, or NIL -- for libuv.
NIL means inherit the parent's environment, which is libuv's own default for a null
pointer and almost always what a build runner wants."
  (when env
    (mapcar (lambda (entry)
              (if (consp entry)
                  (format nil "~A=~A" (car entry) (cdr entry))
                  (string entry)))
            env)))

;;; ---------------------------------------------------------------------- stdio

(defun %fill-stdio (container mode fd connection)
  (let ((flags (cffi:foreign-slot-pointer container
                                          '(:struct ffi:uv-stdio-container-t) 'ffi::flags))
        (data (cffi:foreign-slot-pointer container
                                         '(:struct ffi:uv-stdio-container-t) 'ffi::data)))
    (ecase mode
      (:ignore
       (setf (cffi:mem-ref flags :int) ffi:+uv-ignore+))
      (:inherit
       ;; The child gets our own descriptor, so its output goes wherever ours does.
       (setf (cffi:mem-ref flags :int) ffi:+uv-inherit-fd+
             (cffi:mem-ref data :int) fd))
      (:pipe
       (setf (cffi:mem-ref flags :int)
             (logior ffi:+uv-create-pipe+
                     ;; From the CHILD's point of view: it reads fd 0 and writes 1 and 2.
                     (if (zerop fd) ffi:+uv-readable-pipe+ ffi:+uv-writable-pipe+))
             (cffi:mem-ref data :pointer) (net:connection-pointer connection))))))

;;; ------------------------------------------------------------------- spawning

(defun spawn (loop program &key arguments cwd env
                                (stdin :pipe) (stdout :pipe) (stderr :pipe)
                                on-exit detached)
  "Start PROGRAM with ARGUMENTS on LOOP, and return a PROCESS.

STDIN, STDOUT and STDERR are each :PIPE (default -- a CONNECTION you read or write),
:INHERIT (share ours) or :IGNORE. ON-EXIT is called with the process, on the loop thread.

DETACHED makes the child a process-group leader, so it outlives us and can be signalled
as a group with KILL-PID on a negative pid -- the only process-group semantics libuv
exposes portably.

ARGUMENTS excludes the program name: libuv wants argv[0] and we supply PROGRAM for it,
which is the convention that surprises people who have passed argv straight through."
  (uv:ensure-available)
  (let ((handle (cffi:foreign-alloc :char
                                    :count (uv-ffi:uv-handle-size uv-ffi:+uv-process+)))
        (argv nil) (argc 0) (envp nil) (envc 0)
        (in nil) (out nil) (err nil)
        (spawned nil))
    (unwind-protect
         (progn
           (when (eq stdin :pipe) (setf in (net:make-pipe-connection loop)))
           (when (eq stdout :pipe) (setf out (net:make-pipe-connection loop)))
           (when (eq stderr :pipe) (setf err (net:make-pipe-connection loop)))
           (let* ((args (cons (string program)
                              (mapcar #'princ-to-string arguments)))
                  (environment (%environment-strings env)))
             (setf argc (length args)
                   argv (%alloc-string-array args)
                   envc (length environment)
                   envp (when environment (%alloc-string-array environment)))
             (cffi:with-foreign-object (stdio '(:struct ffi:uv-stdio-container-t) 3)
               (%fill-stdio (cffi:mem-aptr stdio '(:struct ffi:uv-stdio-container-t) 0)
                            stdin 0 in)
               (%fill-stdio (cffi:mem-aptr stdio '(:struct ffi:uv-stdio-container-t) 1)
                            stdout 1 out)
               (%fill-stdio (cffi:mem-aptr stdio '(:struct ffi:uv-stdio-container-t) 2)
                            stderr 2 err)
               (cffi:with-foreign-object (options '(:struct ffi:uv-process-options-t))
                 (dotimes (i (cffi:foreign-type-size
                              '(:struct ffi:uv-process-options-t)))
                   (setf (cffi:mem-aref options :unsigned-char i) 0))
                 (cffi:with-foreign-string (file (string program))
                   (let ((cwd-pointer (if cwd
                                          (cffi:foreign-string-alloc (namestring cwd))
                                          (cffi:null-pointer))))
                     (unwind-protect
                          (progn
                            (cffi:with-foreign-slots
                                ((ffi::exit-cb ffi::file ffi::args ffi::env ffi::cwd
                                  ffi::flags ffi::stdio-count ffi::stdio)
                                 options (:struct ffi:uv-process-options-t))
                              (setf ffi::exit-cb (cffi:callback %exit-callback)
                                    ffi::file file
                                    ffi::args argv
                                    ffi::env (or envp (cffi:null-pointer))
                                    ffi::cwd cwd-pointer
                                    ffi::flags (if detached
                                                   ffi:+uv-process-detached+
                                                   0)
                                    ffi::stdio-count 3
                                    ffi::stdio stdio))
                            (let ((process (%make-process
                                            :pointer handle :loop loop
                                            :stdin in :stdout out :stderr err
                                            :exit-future (uv:make-future)
                                            :on-exit on-exit)))
                              ;; Registered BEFORE the spawn: on a fast-exiting child the
                              ;; callback can be queued immediately, and it looks the
                              ;; process up by handle pointer.
                              (uv:register handle process)
                              (push handle (uv:loop-owned loop))
                              (let ((code (ffi:uv-spawn (uv:loop-pointer loop)
                                                        handle options)))
                                (when (minusp code)
                                  (uv:deregister handle)
                                  (setf (uv:loop-owned loop)
                                        (remove handle (uv:loop-owned loop)))
                                  ;; uv_spawn initialises the handle before it can fail,
                                  ;; so it must be CLOSED, not freed.
                                  (uv:close-pointer handle)
                                  (error 'spawn-failed
                                         :code code :name (uv-ffi:uv-err-name code)
                                         :message (uv-ffi:uv-strerror code)
                                         :operation :spawn :path (string program)))
                                (setf (process-pid process)
                                      (ffi:uv-process-get-pid handle)
                                      spawned process)
                                process)))
                       (unless (cffi:null-pointer-p cwd-pointer)
                         (cffi:foreign-string-free cwd-pointer)))))))))
      ;; Whatever happened, the argv/envp copies have served their purpose; and if we did
      ;; NOT end up with a process, the pipes we made have no owner to close them.
      (%free-string-array argv argc)
      (when envp (%free-string-array envp envc))
      (unless spawned
        (dolist (connection (list in out err))
          (when connection (ignore-errors (uv:close-handle connection))))))))

;;; -------------------------------------------------------------------- control

(defun %signal-number (signal)
  (let ((n (if (integerp signal)
               signal
               (types:signal-number (string-downcase (string signal))))))
    (when (<= n 0)
      (error 'uv:uv-error
             :code 0 :name "EINVAL" :operation :signal
             :message (format nil "~S is not a signal this binding names; the portable set is :hup :int :quit :abrt :kill :pipe :alrm :term :winch, or pass a number" signal)))
    n))

(defun kill (process &optional (signal :term))
  "Send SIGNAL (a keyword like :TERM or :KILL, or a number) to the child."
  (uv:check (ffi:uv-process-kill (process-pointer process) (%signal-number signal))
            :operation :kill)
  process)

(defun kill-pid (pid &optional (signal :term))
  "Signal an arbitrary pid. A NEGATIVE pid addresses the process GROUP on unix, which is
what reaches the children of a child spawned with :DETACHED -- and is the only
process-group control libuv offers."
  (uv:check (ffi:uv-kill pid (%signal-number signal)) :operation :kill-pid))

(defun close-process (process)
  "Release the process handle and its stdio pipes. Idempotent.

Closing does not kill: a running child keeps running, having become someone else's
problem. KILL it first if that is not what you meant."
  (unless (process-closed process)
    (setf (process-closed process) t)
    (dolist (connection (list (process-stdin process)
                              (process-stdout process)
                              (process-stderr process)))
      (when connection (ignore-errors (uv:close-handle connection))))
    (let ((pointer (process-pointer process)))
      (when pointer
        (setf (uv:loop-owned (process-loop process))
              (remove pointer (uv:loop-owned (process-loop process))))
        (uv:close-pointer pointer)
        (setf (process-pointer process) nil))))
  process)

(defmethod uv:close-handle ((process process))
  (close-process process))
