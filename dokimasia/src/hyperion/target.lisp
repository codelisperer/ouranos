;;;; target.lisp --- HYPERION-TARGET: a hyperion app that dokimasia starts on a free port with a
;;;; scratch database (#1028, dokimasia ADR-0001, point 2, "Aux systems that reach right").
;;;;
;;;; The target makes a new SQLite file in a new temporary directory, hands its mnemosyne backend
;;;; to the app's setup and seeding functions and to the function that makes the app, and starts
;;;; the app with hyperion/server on a port hyperion/test-ports finds. After the run it stops the
;;;; server and deletes the directory with the database in it.
;;;;
;;;; Its settle check adds htmx to the core's network check: a listener installed in every page
;;;; with Page.addScriptToEvaluateOnNewDocument counts htmx requests in flight and swaps not yet
;;;; settled, and the check waits until both are zero.
;;;;
;;;; With :SIGN-IN :SESSION, a case's user is signed in by adding a session to the app's store
;;;; and setting its cookie with Network.setCookie, rather than through the sign-in form.

(in-package #:dokimasia/hyperion)

(defclass hyperion-target (d:target)
  ((app :initarg :app :reader %app)
   (setup :initarg :setup :reader %setup)
   (seed :initarg :seed :reader %seed)
   (teardown :initarg :teardown :reader %teardown)
   (server :initarg :server :reader %server)
   (sign-in :initarg :sign-in :reader %sign-in)
   (session-store :initarg :session-store :reader %session-store)
   (session-data :initarg :session-data :reader %session-data)
   (cookie-name :initarg :cookie-name :reader %cookie-name)
   (directory :initform nil :accessor %directory)
   (database :initform nil :accessor target-database)
   (handler :initform nil :accessor %handler)
   (port :initform nil :accessor %port))
  (:documentation "A hyperion app that dokimasia starts on a free port with a scratch SQLite
database. See HYPERION-TARGET."))

(setf (documentation 'target-database 'function)
      "The mnemosyne backend of TARGET's scratch database while the run is going, or NIL.")

(defun %function-p (f)
  (or (functionp f) (and f (symbolp f) (fboundp f))))

(defun %invalid (control &rest args)
  (error 'd:invalid-definition :reason (apply #'format nil control args)))

(defun hyperion-target (&key app setup seed teardown users server (sign-in :form)
                             session-store session-data (cookie-name session:*cookie-name*))
  "A target for a hyperion app that the run starts and stops.

APP is a function of one argument, the mnemosyne backend of a new scratch SQLite database, that
returns the app's Ring handler. Before it is called, SETUP, if given, is called with the backend
to create the app's tables (by running its migrations, for example), and then SEED, if given, is
called with the backend and USERS to store the users a case signs in as. USERS are plists with a
:NAME, as for every target. TEARDOWN, if given, is called with no arguments after the server
stops, to close what APP opened, such as a pool, before the database is deleted. SERVER is the
hyperion/server backend, such as :HUNCHENTOOT or :UV; NIL means HYPERION/SERVER's default.

SIGN-IN is :FORM, the default, to sign in through the suite's :SIGN-IN steps, or :SESSION to add a
session for the user to the app's store and set its cookie, which is faster for cases that do not
test signing in. With :SESSION, SESSION-STORE is the app's session store, or a function of no
arguments that returns it, and SESSION-DATA is a function of the user's plist and the backend that
returns the session's data as an alist, such as ((:USER-ID . 42)). COOKIE-NAME is the name the app
gave WRAP-SESSION, by default HYPERION/SESSION:*COOKIE-NAME*.

A probe's local form runs against this target. CURRENT-DATABASE gives a probe the backend of the
running target's database."
  (unless (%function-p app)
    (%invalid "a hyperion target's :APP is a function of the database backend that returns the app; got ~S" app))
  (loop for (name value) on (list :setup setup :seed seed :teardown teardown) by #'cddr
        unless (or (null value) (%function-p value))
          do (%invalid "a hyperion target's ~S is a function; got ~S" name value))
  (unless (member sign-in '(:form :session))
    (%invalid "a hyperion target's :SIGN-IN is :FORM or :SESSION; got ~S" sign-in))
  (when (eq sign-in :session)
    (unless session-store
      (%invalid "a hyperion target with :SIGN-IN :SESSION needs :SESSION-STORE, the app's session store or a function that returns it"))
    (unless (%function-p session-data)
      (%invalid "a hyperion target with :SIGN-IN :SESSION needs :SESSION-DATA, a function of the user and the database that returns the session's data")))
  (unless (and (stringp cookie-name) (plusp (length cookie-name)))
    (%invalid "a hyperion target's :COOKIE-NAME is a non-empty string; got ~S" cookie-name))
  ;; The core's own check of a target's users.
  (d::%check-users users)
  (make-instance 'hyperion-target :app app :setup setup :seed seed :teardown teardown
                                  :users users :server server :sign-in sign-in
                                  :session-store session-store :session-data session-data
                                  :cookie-name cookie-name))

(defun current-database ()
  "The mnemosyne backend of the database of the hyperion target the current row runs against,
for a probe's :SOURCE: (dokimasia/mnemosyne:define-row-probe ... :source #'current-database)."
  (let ((target (and d:*row* (d:row-target d:*row*))))
    (unless (typep target 'hyperion-target)
      (error "CURRENT-DATABASE is called while a row runs against a hyperion target; the row's target is ~S"
             target))
    (target-database target)))

;;; --- starting and stopping -----------------------------------------------------------------

(defun %release (target)
  "Stop the server, call the app's teardown, and delete the scratch database, each step even
when an earlier one fails."
  (unwind-protect
       (unwind-protect
            (when (%handler target)
              (srv:stop (%handler target)))
         (setf (%handler target) nil)
         (when (%teardown target)
           (funcall (%teardown target))))
    (when (%directory target)
      (fs:delete-tree (%directory target))
      (setf (%directory target) nil
            (target-database target) nil))))

(defmethod d:target-start ((target hyperion-target))
  (let ((ok nil))
    (unwind-protect
         (let* ((dir (fs:make-temporary-directory "dokimasia-hyperion"))
                (backend (progn (setf (%directory target) dir)
                                (be:make-sqlite (uiop:native-namestring
                                                 (merge-pathnames "app.db" dir))))))
           (setf (target-database target) backend)
           (when (%setup target) (funcall (%setup target) backend))
           (when (%seed target) (funcall (%seed target) backend (d:target-users target)))
           (let ((app (funcall (%app target) backend)))
             (setf (%handler target)
                   (ports:call-with-port
                    (lambda (port)
                      (prog1 (apply #'srv:start app :port port :host "127.0.0.1" :log nil
                                    (when (%server target) (list :server (%server target))))
                        (setf (%port target) port))))))
           (setf ok t)
           (d:target-base-url target))
      (unless ok (%release target)))))

(defmethod d:target-stop ((target hyperion-target))
  (%release target))

(defmethod d:target-base-url ((target hyperion-target))
  (and (%port target) (format nil "http://127.0.0.1:~D" (%port target))))

(defmethod d:target-runs-local-probes-p ((target hyperion-target)) t)

;;; --- the htmx settle check -----------------------------------------------------------------

(defparameter +htmx-listener+
  "(() => {
  if (window.__dokimasiaHtmx) return;
  const s = window.__dokimasiaHtmx = {inFlight: 0, settling: 0};
  const on = (name, f) => document.addEventListener(name, f, true);
  on('htmx:beforeRequest', () => { s.inFlight++; });
  on('htmx:afterRequest', () => { s.inFlight = Math.max(0, s.inFlight - 1); });
  on('htmx:afterSwap', () => { s.settling++; });
  on('htmx:afterSettle', () => { s.settling = Math.max(0, s.settling - 1); });
})();"
  "The script installed in every page of a hyperion target before the page's own scripts run. It
counts htmx requests in flight (htmx:beforeRequest to htmx:afterRequest, which htmx fires on
success, error, abort and timeout alike) and swaps not yet settled (htmx:afterSwap to
htmx:afterSettle).")

(defparameter +htmx-busy+
  "(() => { const s = window.__dokimasiaHtmx;
  if (!s || !window.htmx) return null;
  const pending = document.querySelector('.htmx-request, .htmx-swapping, .htmx-settling');
  return (s.inFlight > 0 || s.settling > 0 || pending)
    ? ('htmx has ' + s.inFlight + ' request(s) in flight and ' + s.settling + ' swap(s) not settled') : null; })()"
  "An expression that is NIL when htmx is idle or not on the page, and otherwise says what htmx is
still doing. The class check also covers a swap held back by a swap delay, which starts after
htmx:afterRequest.")

(defmethod d:target-prepare-page ((target hyperion-target) page)
  (cdp:send page "Page.addScriptToEvaluateOnNewDocument"
            :params (cdp:json-object "source" +htmx-listener+)
            :timeout d:*step-timeout*))

(defmethod d:target-settle ((target hyperion-target) page timeout)
  (let ((deadline (+ (get-internal-real-time) (round (* timeout internal-time-units-per-second)))))
    (or (call-next-method)
        (loop
          (let ((busy (cdp:evaluate page +htmx-busy+ :timeout timeout)))
            (cond ((null busy) (return nil))
                  ((> (get-internal-real-time) deadline)
                   (return (format nil "the page did not settle within ~A seconds: ~A" timeout busy)))
                  (t (sleep 0.02))))))))

;;; --- signing in with a session -------------------------------------------------------------

(defmethod d:target-sign-in ((target hyperion-target) page user)
  (when (eq (%sign-in target) :session)
    (let* ((source (%session-store target))
           (store (if (%function-p source) (funcall source) source))
           (now (get-universal-time))
           (data (funcall (%session-data target) user (target-database target)))
           (s (session:restore-session (session:new-id) :created now :accessed now :data data)))
      (session:store-add store s)
      (cdp:send page "Network.setCookie"
                :params (cdp:json-object "name" (%cookie-name target)
                                         "value" (session:session-id s)
                                         "url" (d:target-base-url target)
                                         "path" "/"
                                         "httpOnly" t
                                         "sameSite" "Lax")
                :timeout d:*step-timeout*)
      (format nil "a session for ~(~A~) in the app's store" (getf user :name)))))
