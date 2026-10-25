;;;; {{name}}.lisp --- a minimal Hyperion web app with a database (src/db.lisp).
;;;;
;;;; `cons serve` runs SERVE (blocks until Ctrl-C); `cons dev` runs START (non-blocking)
;;;; then drops into a REPL. Edit APP and reload to grow it into your real handler.

(cl:in-package #:{{name}})

(defparameter +version+ "0.0.0" "{{name}} version.")
(defun version () "Return the {{name}} version string." +version+)

(defun app (env)
  "A Clack app: render one HTML page, counting this browser's visits in its session, which the
session store keeps in the database."
  (let* ((s (session:request-session env))
         (visits (1+ (session:session-get s :visits 0))))
    (session:session-set s :visits visits)
    (list 200
          '(:content-type "text/html; charset=utf-8")
          (list (spinneret:with-html-string
                  (:doctype)
                  (:html
                   (:head (:title "{{name}}")
                          (:meta :name "viewport"
                                 :content "width=device-width, initial-scale=1"))
                   (:body
                    (:h1 "{{name}} is running")
                    (:p "A minimal Hyperion app scaffolded by " (:code "cons")
                        ". Edit " (:code "src/{{name}}.lisp") " and reload.")
                    (:p :id "visits" (format nil "Visits from this browser: ~D" visits)))))))))

(defvar *handler* nil "The running server handler, or NIL.")

(defparameter *dev-port* {{dev-port}}
  "This project's development port, derived from its NAME when it was generated (pre-publication issue 238).

Not shared with any other project made from this template, which is the point: a literal in
a template guarantees every app made from it wants the same port, and the second window
then shows the FIRST app -- its title, its routes, a 404 for everything yours added. That
reads as a broken build, not a collision. Shipped builds take an OS-assigned ephemeral port
and cannot collide at all; only development uses a fixed one, so this is the risky path and
the guarded one.")

(defun start (&key (host "127.0.0.1") (port *dev-port*))
  "Start the app on a background thread; return the handler (non-blocking).

Every path into this app -- `cons serve`, `cons dev`, the dumped binary -- arrives here,
which is why the .env load is at the top of it rather than in MAIN alone."
  ;; FIRST, before anything reads the environment. A .env loaded lazily -- wherever the
  ;; first consumer happens to sit -- is a .env that was not loaded for whatever ran
  ;; before it, and that failure blames the library rather than this ordering.
  (env:load-project-env :{{name}})
  (when *handler*
    (error "{{name}}: already running on port ~D. Call STOP first."
           (srv:handler-port *handler*)))
  ;; A pool opened here is closed again if the server does not start, so a failed START
  ;; leaves no connections open. A pool already opened, at the REPL say, is used and kept.
  (let ((opened (not *pool*))
        (started nil))
    (when opened (open-database))
    (unwind-protect
         ;; DEFAULT-SERVER chooses :uv when libuv loads, and otherwise the next server this
         ;; app loads, and says why. HYPERION_SERVER, when set, decides. On :uv, START runs
         ;; handlers on two worker threads, so one slow request does not hold up the others.
         (multiple-value-bind (server reason detail) (srv:default-server)
           (log:info "{{name}}: server chosen" :server server :reason reason :detail detail)
           (setf *handler* (srv:start (app-with-database #'app)
                                      :host host :port port :server server)
                 started t))
      (when (and opened (not started)) (close-database))))
  (format t "~&{{name}} serving at http://~A:~D/~%" host (srv:handler-port *handler*))
  (finish-output)
  *handler*)

(defun stop ()
  "Stop the running server, if any, and close the database."
  (when *handler* (srv:stop *handler*) (setf *handler* nil))
  (close-database))

(defun serve (&key (host "127.0.0.1") (port *dev-port*))
  "Start the app and BLOCK until interrupted (Ctrl-C) -- the `cons serve` entry."
  (start :host host :port port)
  (unwind-protect
       (handler-case (loop (sleep 3600))
         #+sbcl (sb-sys:interactive-interrupt () (format t "~&Shutting down.~%")))
    (stop)))

(defun main ()
  "Executable entry point: serve the web app."
  (serve))
