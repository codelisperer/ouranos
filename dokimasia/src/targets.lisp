;;;; targets.lisp --- what a run is run against (#1028, dokimasia ADR-0001, point 2).
;;;;
;;;; A target says how to reach the app (its base URL), who can sign in to it (its users), how
;;;; to tell that a page has settled, and how to start and stop the app if the harness starts it.
;;;; The core has two: URL-TARGET for a deployed app, and PROCESS-TARGET for an app the harness
;;;; starts with functions the caller gives. An aux system adds its own by subclassing TARGET,
;;;; as dokimasia/hyperion does for a hyperion app on a scratch database.

(in-package #:dokimasia)

(defclass target ()
  ((users :initarg :users :initform '() :reader target-users
          :documentation "The users a case can sign in as: a list of plists, each with :NAME and
the values the suite's sign-in steps read with (:USER key). A value may be an AION/SECRET:SECRET,
revealed only when a step types it."))
  (:documentation "What a run is run against. See TARGET-START, TARGET-STOP, TARGET-BASE-URL,
TARGET-RUNS-LOCAL-PROBES-P and TARGET-SETTLE."))

(defgeneric target-start (target)
  (:documentation "Make TARGET ready and return its base URL. Called once, before any case."))

(defgeneric target-stop (target)
  (:documentation "Release what TARGET-START made. Called once after the run, however the run
ends, and only when TARGET-START returned.")
  (:method ((target target)) nil))

(defgeneric target-base-url (target)
  (:documentation "TARGET's base URL, once started."))

(defgeneric target-runs-local-probes-p (target)
  (:documentation "Whether a probe's LOCAL form, which reads the app's store from the test image,
checks the store TARGET uses. True only when the harness started the app in a way that makes it
so.")
  (:method ((target target)) nil))

(defgeneric target-settle (target page timeout)
  (:documentation "Wait until PAGE has settled after an action, for at most TIMEOUT seconds.
Return NIL when it has, or a string saying why it has not. The method for TARGET waits until no
network request has been in flight for *QUIET-PERIOD* seconds. A subclass can add a check of its
own, for example that a client library has no request queued, and call CALL-NEXT-METHOD for the
network one."))

(defun %check-users (users)
  (unless (and (listp users)
               (every (lambda (u)
                        (and (listp u) (evenp (length u)) (getf u :name)
                             (or (symbolp (getf u :name)) (stringp (getf u :name)))))
                      users))
    (%invalid "a target's :USERS is a list of plists, each with a :NAME; got ~S" users))
  users)

(defun %check-base-url (url)
  (unless (and (stringp url)
               (or (uiop:string-prefix-p "http://" url) (uiop:string-prefix-p "https://" url)))
    (%invalid "a base URL starts with http:// or https://; got ~S" url))
  (string-right-trim "/" url))

;;; --- a deployed app ------------------------------------------------------------------------

(defclass url-target (target)
  ((base-url :initarg :base-url :reader target-base-url))
  (:documentation "An app already running at a base URL, such as staging after a deploy."))

(defun url-target (base-url &key users)
  "A target for the app at BASE-URL. USERS are the users a case can sign in as; keep their
passwords in AION/SECRET:SECRET values. A probe's LOCAL form does not run against this target,
because the test image cannot see the deployed app's store."
  (make-instance 'url-target :base-url (%check-base-url base-url) :users (%check-users users)))

(defmethod target-start ((target url-target)) (target-base-url target))

;;; --- an app the harness starts -------------------------------------------------------------

(defclass process-target (target)
  ((start :initarg :start :reader %process-start)
   (stop :initarg :stop :reader %process-stop)
   (base-url :initform nil :accessor %process-base-url))
  (:documentation "An app the harness starts and stops with functions the caller gives, whatever
the app is written in."))

(defun process-target (&key start stop users)
  "A target that START, a function of no arguments, starts, returning its base URL, and that STOP,
a function of no arguments, stops. STOP is called after the run, even when a case fails. USERS
are the users a case can sign in as. A probe's LOCAL form runs against this target."
  (unless (functionp start) (%invalid "a process target's :START is a function; got ~S" start))
  (unless (or (null stop) (functionp stop))
    (%invalid "a process target's :STOP is a function; got ~S" stop))
  (make-instance 'process-target :start start :stop stop :users (%check-users users)))

(defmethod target-start ((target process-target))
  (setf (%process-base-url target) (%check-base-url (funcall (%process-start target)))))

(defmethod target-stop ((target process-target))
  (when (%process-stop target) (funcall (%process-stop target))))

(defmethod target-base-url ((target process-target)) (%process-base-url target))

(defmethod target-runs-local-probes-p ((target process-target)) t)

(defun %find-user (target name)
  (find-if (lambda (u) (string-equal (%name-string (getf u :name)) name)) (target-users target)))
