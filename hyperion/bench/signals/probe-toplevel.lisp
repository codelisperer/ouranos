;;;; probe-sigterm.lisp --- the empty cell of hyperion/docs/signals-and-shutdown.md.
;;;;
;;;; Does a SIGTERM from an EXTERNAL PROCESS reach an SBCL handler while a server is
;;;; running and the main thread is parked -- OUTSIDE serve-forever?
;;;;
;;;; Deliberately NOT serve-forever: the whole question is whether the fault is in the
;;;; transport or in serve-forever, so this reproduces everything except serve-forever.
;;;; Same handler shape as %INSTALL-POSIX-SIGNAL-HANDLERS, same poll-over-SLEEP wait.
;;;;
;;;; PROBE_BACKEND=none|woo|hunchentoot|uv

(require :asdf)
(require :sb-bsd-sockets)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defvar *backend* (or (uiop:getenv "PROBE_BACKEND") "none"))
(defvar *fired* nil)
(defvar *handler-thread* nil)

(defun free-port ()
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
                (sb-bsd-sockets:socket-bind s #(127 0 0 1) 0)
                (nth-value 1 (sb-bsd-sockets:socket-name s)))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(defun app (env) (declare (ignore env)) (list 200 '(:content-type "text/plain") '("ok")))

;; The handler, installed BEFORE the server starts -- one of the ruled-out hypotheses was
;; ordering, so the probe keeps the order the real code uses.
(sb-sys:enable-interrupt sb-unix:sigterm
                         (lambda (&rest _)
                           (declare (ignore _))
                           (setf *handler-thread*
                                 (sb-thread:thread-name sb-thread:*current-thread*))
                           (setf *fired* t)))

(let ((port (free-port)) (server nil))
  (handler-case
      (cond
        ((string= *backend* "none") nil)
        ((string= *backend* "woo")
         (ql:quickload (list :clack :clack-handler-woo) :silent t)
         (setf server (uiop:symbol-call :clack :clackup #'app :server :woo
                                        :port port :address "127.0.0.1" :use-thread t)))
        ((string= *backend* "hunchentoot")
         (ql:quickload (list :clack :clack-handler-hunchentoot) :silent t)
         (setf server (uiop:symbol-call :clack :clackup #'app :server :hunchentoot
                                        :port port :address "127.0.0.1" :use-thread t)))
        ((string= *backend* "uv")
         (ql:quickload :hyperion/server-uv :silent t)
         (ql:quickload :hyperion :silent t)
         (setf server (uiop:symbol-call :hyperion/server :start #'app
                                        :server :uv :port port :log nil)))
        (t (format t "~&PROBE-ERROR unknown backend ~A~%" *backend*)
           (finish-output) (sb-ext:quit :unix-status 3)))
    (error (e)
      (format t "~&PROBE-ERROR could not start ~A: ~A~%" *backend* e)
      (finish-output)
      (sb-ext:quit :unix-status 3)))

  ;; READY is the contract with the driver: it holds the pid, and it is flushed, because a
  ;; block-buffered pipe would leave the driver waiting for a line that was already written.
  (format t "~&READY ~A ~D~%" *backend* (sb-unix:unix-getpid))
  (finish-output)

  ;; Poll over SLEEP -- the same wait serve-forever uses, and the one measured to be
  ;; interruptible. 10 seconds is far longer than delivery could plausibly take.
  (let ((deadline (+ (get-universal-time) 10)))
    (loop until (or *fired* (> (get-universal-time) deadline))
          do (sleep 0.1)))

  (format t "~&RESULT ~A ~A thread=~A~%"
          *backend* (if *fired* "FIRED" "TIMEOUT") (or *handler-thread* "-"))
  (finish-output)
  (ignore-errors
    (when server
      (if (string= *backend* "uv")
          (uiop:symbol-call :hyperion/server :stop server)
          (uiop:symbol-call :clack :stop server))))
  (sb-ext:quit :unix-status (if *fired* 0 1)))
