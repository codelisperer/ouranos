;;;; probe-sf.lisp --- the OTHER half: SIGTERM to a real serve-forever, per backend.
;;;;
;;;; probe-sigterm.lisp isolates the transport by reproducing everything EXCEPT
;;;; serve-forever. This one runs the actual production entry point, which is the row #37
;;;; depends on. FIRED here means a supervisor can stop a deployed app cleanly.
;;;;
;;;; PROBE_BACKEND=woo|hunchentoot|uv

(require :asdf)
(require :sb-bsd-sockets)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defvar *backend* (or (uiop:getenv "PROBE_BACKEND") "uv"))

(defun free-port ()
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
                (sb-bsd-sockets:socket-bind s #(127 0 0 1) 0)
                (nth-value 1 (sb-bsd-sockets:socket-name s)))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(defun app (env) (declare (ignore env)) (list 200 '(:content-type "text/plain") '("ok")))

(handler-case
    (progn
      (ql:quickload :hyperion :silent t)
      (cond ((string= *backend* "woo") (ql:quickload (list :clack :clack-handler-woo) :silent t))
            ((string= *backend* "hunchentoot")
             (ql:quickload (list :clack :clack-handler-hunchentoot) :silent t))
            ((string= *backend* "uv") (ql:quickload :hyperion/server-uv :silent t))))
  (error (e) (format t "~&PROBE-ERROR load ~A: ~A~%" *backend* e)
    (finish-output) (sb-ext:quit :unix-status 3)))

;; The watchdog. serve-forever BLOCKS; if the signal is lost it blocks forever, so the
;; TIMEOUT verdict has to come from somewhere other than the thread under test.
;; THREAD-LIFETIME: independent -- a benchmark probe's own thread, outside any request.
(sb-thread:make-thread
 (lambda ()
   (sleep 12)
   (format t "~&RESULT ~A serve-forever TIMEOUT~%" *backend*)
   (finish-output)
   (sb-ext:quit :unix-status 1 :abort t))
 :name "watchdog")

(let ((port (free-port)))
  (uiop:symbol-call
   :hyperion/server :serve-forever #'app
   :server (intern (string-upcase *backend*) :keyword)
   :port port :log nil :banner nil
   :on-ready (lambda (session)
               (declare (ignore session))
               (format t "~&READY ~A ~D~%" *backend* (sb-unix:unix-getpid))
               (finish-output))))

;; Reached only if serve-forever RETURNED, which it does only when the stop flag was set.
(format t "~&RESULT ~A serve-forever FIRED~%" *backend*)
(finish-output)
(sb-ext:quit :unix-status 0)
