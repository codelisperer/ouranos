;;;; drain-child.lisp --- a serve-forever on :uv for server-uv-tests' SIGTERM test (#388).
;;;;
;;;; Not a system component: the test starts it as a child process with `sbcl --script', sends
;;;; it SIGTERM and watches what it does. /slow answers after CHILD_SLOW seconds, /health is
;;;; the readiness path, and anything else answers at once. The drain's timings come from
;;;; HYPERION_DRAIN_SECONDS and HYPERION_DRAIN_TIMEOUT_SECONDS, as in a deployment.

(require :asdf)
(require :sb-bsd-sockets)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defvar *slow* (let ((*read-eval* nil)) (read-from-string (or (uiop:getenv "CHILD_SLOW") "2"))))

(handler-case
    (let ((*standard-output* (make-broadcast-stream)) (*error-output* (make-broadcast-stream)))
      (asdf:load-system "hyperion")
      (asdf:load-system "hyperion/server-uv"))
  (error (e) (format t "~&CHILD-ERROR load: ~A~%" e) (finish-output) (sb-ext:quit :unix-status 3)))

(defun free-port ()
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
                (sb-bsd-sockets:socket-bind s #(127 0 0 1) 0)
                (nth-value 1 (sb-bsd-sockets:socket-name s)))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(defun app (env)
  (let ((path (getf env :path-info)))
    (cond ((string= path "/slow")
           (sleep *slow*)
           (list 200 '(:content-type "text/plain") '("slow")))
          ((string= path "/health") (list 200 '(:content-type "text/plain") '("healthy")))
          (t (list 200 '(:content-type "text/plain") '("fast"))))))

;; THREAD-LIFETIME: independent -- the child's own watchdog. If SIGTERM were lost, the test
;; would otherwise wait on a process that never ends.
(sb-thread:make-thread (lambda () (sleep 60) (sb-ext:quit :unix-status 2 :abort t))
                       :name "drain-child watchdog")

(let ((port (free-port)))
  (uiop:symbol-call
   :hyperion/server :serve-forever #'app
   :server :uv :port port :log nil :banner nil :workers 4 :readiness-path "/health"
   :on-ready (lambda (session)
               (declare (ignore session))
               (format t "~&READY ~D ~D~%" (sb-unix:unix-getpid) port)
               (finish-output))))

(format t "~&RETURNED~%")
(finish-output)
(sb-ext:quit :unix-status 0)
