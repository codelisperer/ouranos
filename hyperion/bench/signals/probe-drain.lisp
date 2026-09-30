;;;; probe-drain.lisp --- what a backend does with requests when SIGTERM arrives (#388).
;;;;
;;;; A real serve-forever, one backend, two routes: /slow answers after SLOW seconds and /fast
;;;; at once. drain.lisp starts this as a child process, starts a /slow request, sends the
;;;; child SIGTERM, and then asks /fast, which is the measurement: whether the in-flight
;;;; request completes, whether new connections are still answered, and when the process exits.
;;;;
;;;; PROBE_BACKEND=woo|hunchentoot|uv   PROBE_SLOW=seconds (default 3)

(require :asdf)
(require :sb-bsd-sockets)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defvar *backend* (or (uiop:getenv "PROBE_BACKEND") "uv"))
(defvar *slow* (parse-integer (or (uiop:getenv "PROBE_SLOW") "3")))

(defun free-port ()
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
                (sb-bsd-sockets:socket-bind s #(127 0 0 1) 0)
                (nth-value 1 (sb-bsd-sockets:socket-name s)))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(defun app (env)
  (if (string= "/slow" (getf env :path-info))
      (progn (sleep *slow*) (list 200 '(:content-type "text/plain") '("slow done")))
      (list 200 '(:content-type "text/plain") '("fast"))))

(handler-case
    (progn
      (ql:quickload :hyperion :silent t)
      (cond ((string= *backend* "woo") (ql:quickload (list :clack :clack-handler-woo) :silent t))
            ((string= *backend* "hunchentoot")
             (ql:quickload (list :clack :clack-handler-hunchentoot) :silent t))
            ((string= *backend* "uv") (ql:quickload :hyperion/server-uv :silent t))))
  (error (e) (format t "~&PROBE-ERROR load ~A: ~A~%" *backend* e)
    (finish-output) (sb-ext:quit :unix-status 3)))

;; THREAD-LIFETIME: independent -- a benchmark probe's own watchdog, outside any request. A
;; backend that loses SIGTERM never returns from serve-forever; this ends the probe instead.
(sb-thread:make-thread
 (lambda ()
   (sleep (+ 20 *slow*))
   (format t "~&RESULT ~A TIMEOUT~%" *backend*)
   (finish-output)
   (sb-ext:quit :unix-status 1 :abort t))
 :name "watchdog")

(let ((port (free-port)))
  (uiop:symbol-call
   :hyperion/server :serve-forever #'app
   :server (intern (string-upcase *backend*) :keyword)
   :port port :log nil :banner nil :workers 4
   :on-ready (lambda (session)
               (declare (ignore session))
               (format t "~&READY ~A ~D ~D~%" *backend* (sb-unix:unix-getpid) port)
               (finish-output))))

(format t "~&RESULT ~A RETURNED~%" *backend*)
(finish-output)
(sb-ext:quit :unix-status 0)
