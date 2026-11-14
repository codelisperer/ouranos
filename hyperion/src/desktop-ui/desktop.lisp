;;;; desktop.lisp --- a desktop of floating windows on one page: the CL shell (#1218).
;;;;
;;;; A proof of concept. A DESKTOP holds WINDOWs. Each window is an ordinary object in the
;;;; image with a position (a value of the Coalton type in state.lisp), a function that renders
;;;; its body, a table of named actions, and a property list of its own data. The page shows
;;;; each window as an absolutely positioned element that can be dragged, resized, raised and
;;;; closed; each of those posts an event here, and APPLY-EVENT in state.lisp computes the
;;;; next state.
;;;;
;;;; WHAT CAN BE REDEFINED WHILE IT RUNS. A window names its render function and its actions
;;;; by SYMBOL, and they are called through the symbol on every request, so a DEFUN typed at a
;;;; REPL changes what the next request returns. The functions of this file that a request
;;;; calls are declared NOTINLINE for the same reason: a redefinition of RENDER-WINDOW must
;;;; reach the callers compiled before it. WINDOW and DESKTOP are CLOS classes, so redefining
;;;; one updates the instances that already exist.
;;;;
;;;; INSPECTING. INSPECT-WINDOW, INSPECT-EVENT and INSPECT-DESKTOP return property lists of
;;;; numbers, strings and symbols. The inspector window, a REPL and the tests all read those.
;;;;
;;;; TELLING THE PAGE. The page opens GET /events once, a Server-Sent Events stream over the
;;;; desktop's hyperion/feed, and changes what it shows when an event arrives. It does not ask
;;;; again on a timer. OPEN-WINDOW, REMOVE-WINDOW, DISPATCH-EVENT and WINDOW-CHANGED publish on
;;;; the feed, and a timer thread publishes for each window that has a refresh interval while a
;;;; page is connected. STOP-DESKTOP ends the streams and the timer.
;;;;
;;;; Not here: saving the layout between runs, and any limit on what a window's code may do.

(cl:defpackage #:hyperion/desktop-ui
  (:use #:cl)
  (:local-nicknames (#:state #:hyperion/desktop-ui/state)
                    (#:router #:hyperion/router)
                    (#:http #:hyperion/http)
                    (#:out #:hyperion/output)
                    (#:feed #:hyperion/feed)
                    (#:sse #:hyperion/sse)
                    (#:assets #:hyperion/assets)
                    (#:spin #:spinneret))
  ;; Parenscript matches its own macros by symbol identity, so these are the real ones.
  (:import-from #:parenscript #:chain #:@ #:create #:new #:getprop #:try)
  (:documentation
   "A desktop of floating windows served as one page. MAKE-DESKTOP and OPEN-WINDOW build it,
    MAKE-APP serves it, DISPATCH-EVENT changes a window, and the INSPECT- functions describe
    every structure as plain data.")
  (:export #:desktop #:make-desktop #:desktop-title #:desktop-windows
           #:window #:open-window #:find-window #:remove-window
           #:window-id #:window-title #:window-state #:window-render #:window-actions
           #:window-refresh #:window-desktop #:window-events #:window-data #:window-datum
           #:dispatch-event #:run-action #:event-from-parameters
           #:unknown-window #:unknown-window-id #:bad-event #:bad-event-reason
           #:render-page #:render-window #:render-window-body #:render-dock
           #:inspect-window #:inspect-event #:inspect-desktop
           #:open-inspector #:render-inspector #:inspector-select #:inspector-record
           #:routes #:make-app #:*css* #:*page-scripts* #:client-js #:*event-history*
           #:window-changed #:stop-desktop #:desktop-subscribers #:event-data
           #:*events-hz* #:*timer-step*))

(cl:in-package #:hyperion/desktop-ui)

;;; The functions a request calls, and so the ones a REPL may replace while the server runs.
(declaim (notinline render-page render-window render-window-body render-dock
                    dispatch-event run-action event-from-parameters
                    inspect-window inspect-event inspect-desktop
                    render-inspector inspector-select inspector-record
                    window-changed event-data))

;;; --- the records -------------------------------------------------------------------------

(defparameter *event-history* 12
  "How many of a window's most recent events it keeps for the inspector.")

(defclass desktop ()
  ((title :initarg :title :initform "Desktop" :accessor desktop-title)
   (windows :initform '() :accessor %windows
            :documentation "The windows, oldest first.")
   (lock :initform (sb-thread:make-mutex :name "desktop-ui desktop") :reader %lock
         :documentation "Held for every read or write of a window's state, data and events.")
   (feed :initform (feed:make-feed) :reader %feed
         :documentation "What changed, for the pages reading GET /events. A key is (KIND . ID); see EVENT-DATA.")
   (subscribers :initform 0 :accessor %subscribers
                :documentation "How many GET /events streams are being written now.")
   (epoch :initform 0 :accessor %epoch
          :documentation "Raised by STOP-DESKTOP. A stream or a timer that started under an earlier value ends.")
   (timer :initform nil :accessor %timer
          :documentation "The thread that publishes for windows with a refresh interval, or NIL. It runs only while a page is connected."))
  (:documentation "A set of windows served as one page."))

(defclass window ()
  ((id :initarg :id :reader window-id
       :documentation "Lower-case letters, digits and hyphens. Used in URLs and element ids.")
   (title :initarg :title :accessor window-title)
   (state :initarg :state :accessor window-state
          :documentation "A hyperion/desktop-ui/state:Win-State. Read it with that package's accessors.")
   (render :initarg :render :accessor window-render
           :documentation "A function designator called with the window; it returns the body's HTML as a string. Give a symbol, so that redefining the function changes the window.")
   (actions :initarg :actions :initform '() :accessor window-actions
            :documentation "An alist of (NAME . FUNCTION-DESIGNATOR). POST /window/ID/action/NAME calls the function with the window and the form's alist, and answers with the HTML string it returns.")
   (refresh :initarg :refresh :initform nil :accessor window-refresh
            :documentation "NIL, or the number of seconds between pushes of a fresh body to the connected pages.")
   (desktop :initarg :desktop :reader window-desktop)
   (data :initarg :data :initform '() :accessor %data
         :documentation "The window's own property list. Read and write it with WINDOW-DATUM.")
   (events :initform '() :accessor %events
           :documentation "The most recent events applied, newest first, at most *EVENT-HISTORY*."))
  (:documentation "One floating window: where it is, how its body is rendered, and its own data."))

(defmethod print-object ((w window) stream)
  (print-unreadable-object (w stream :type t)
    (format stream "~A" (window-id w))))

(define-condition unknown-window (error)
  ((id :initarg :id :reader unknown-window-id))
  (:report (lambda (c s) (format s "There is no window with the id ~S." (unknown-window-id c)))))

(define-condition bad-event (error)
  ((reason :initarg :reason :reader bad-event-reason))
  (:report (lambda (c s) (format s "The event was not understood: ~A" (bad-event-reason c)))))

(defmacro %with-desktop ((desktop) &body body)
  `(sb-thread:with-recursive-lock ((%lock ,desktop)) ,@body))

(defun make-desktop (&key (title "Desktop"))
  "An empty desktop."
  (make-instance 'desktop :title title))

(defun desktop-windows (desktop)
  "A fresh list of DESKTOP's windows, oldest first."
  (%with-desktop (desktop) (copy-list (%windows desktop))))

(defun find-window (desktop id)
  "The window of DESKTOP with the id ID, or NIL."
  (%with-desktop (desktop)
    (find id (%windows desktop) :key #'window-id :test #'string=)))

(defun %valid-id-p (id)
  (and (stringp id) (plusp (length id))
       (every (lambda (ch) (or (char<= #\a ch #\z) (digit-char-p ch) (char= ch #\-))) id)))

(defun %top-z (desktop)
  "The highest z among DESKTOP's windows, or 0 with none."
  (reduce #'max (%windows desktop) :key (lambda (w) (state:state-z (window-state w)))
                                   :initial-value 0))

(defun open-window (desktop id &key (title id) render actions refresh data
                                    (x 40) (y 40) (width 360) (height 240))
  "Add a window to DESKTOP and return it. It is placed above every window already there. A
window with the same ID is replaced, which is what re-evaluating a definition at a REPL
should do.

RENDER is called with the window and returns the body's HTML as a string. ACTIONS is an alist
of (NAME . FUNCTION); see the WINDOW class. Pass symbols for both, so a redefinition is
picked up. REFRESH is NIL or a number of seconds: the body is then rendered again and pushed
to the connected pages that often, by the desktop's timer. DATA is the window's initial
property list.

A page that is connected shows the new window without a reload."
  (unless (%valid-id-p id)
    (error "A window id is lower-case letters, digits and hyphens, not ~S." id))
  (%with-desktop (desktop)
    (let ((window (make-instance 'window
                                 :id id :title title :render render :actions actions
                                 :refresh refresh :desktop desktop :data (copy-list data)
                                 :state (state:make-state x y width height
                                                          (1+ (%top-z desktop))))))
      (setf (%windows desktop)
            (append (remove id (%windows desktop) :key #'window-id :test #'string=)
                    (list window)))
      (%publish desktop :window id)
      (%publish desktop :body id)
      (%publish desktop :dock)
      (%publish-watchers desktop id)
      window)))

(defun remove-window (desktop id)
  "Take the window ID out of DESKTOP altogether. Closing a window on the page only hides it.
A page that is connected removes it without a reload."
  (%with-desktop (desktop)
    (setf (%windows desktop)
          (remove id (%windows desktop) :key #'window-id :test #'string=))
    (%publish desktop :window id)
    (%publish desktop :dock)
    (%publish-watchers desktop id))
  desktop)

(defun window-datum (window key &optional default)
  "The value under KEY in WINDOW's own property list."
  (%with-desktop ((window-desktop window))
    (getf (%data window) key default)))

(defun (setf window-datum) (value window key &optional default)
  (declare (ignore default))
  (%with-desktop ((window-desktop window))
    (setf (getf (%data window) key) value)))

(defun window-data (window)
  "A copy of WINDOW's own property list."
  (%with-desktop ((window-desktop window)) (copy-list (%data window))))

(defun window-events (window)
  "WINDOW's most recent events, newest first, as hyperion/desktop-ui/state:Win-Event values."
  (%with-desktop ((window-desktop window)) (copy-list (%events window))))

;;; --- events ------------------------------------------------------------------------------

(defun %integer-parameter (parameters name)
  "The integer the form field NAME holds. A browser reports a fractional size on some
displays, so a decimal part is dropped."
  (let* ((text (cdr (assoc name parameters :test #'string=)))
         (whole (and text (subseq text 0 (or (position #\. text) (length text)))))
         (value (and whole (plusp (length whole))
                     (ignore-errors (parse-integer whole)))))
    (or value
        (error 'bad-event :reason (format nil "the field ~S is ~S, not a whole number" name text)))))

(defun event-from-parameters (desktop parameters)
  "The event a posted form describes. PARAMETERS is the form's alist: `type' is one of move,
resize, raise, close and open; move takes x and y, resize takes width and height. A raise is
given a z above every window DESKTOP has. Signals BAD-EVENT for anything else."
  (let ((type (cdr (assoc "type" parameters :test #'string=))))
    (cond ((equal type "move")
           (state:move-event (%integer-parameter parameters "x")
                             (%integer-parameter parameters "y")))
          ((equal type "resize")
           (state:resize-event (%integer-parameter parameters "width")
                               (%integer-parameter parameters "height")))
          ((equal type "raise")
           (%with-desktop (desktop) (state:raise-event (1+ (%top-z desktop)))))
          ((equal type "close") state:close-event)
          ((equal type "open") state:open-event)
          (t (error 'bad-event :reason (format nil "the type is ~S" type))))))

(defun dispatch-event (desktop id event)
  "Apply EVENT, a hyperion/desktop-ui/state:Win-Event, to the window ID of DESKTOP, record it
in the window's history, and return the window. Signals UNKNOWN-WINDOW when there is none.
The connected pages are told the window's new state, and the dock's when the event closed or
opened the window."
  (%with-desktop (desktop)
    (let ((window (or (find-window desktop id) (error 'unknown-window :id id))))
      (setf (window-state window) (state:apply-event event (window-state window)))
      (push event (%events window))
      (when (> (length (%events window)) *event-history*)
        (setf (%events window) (subseq (%events window) 0 *event-history*)))
      (%publish desktop :window id)
      (when (member (state:event-name event) '("close" "open") :test #'string=)
        (%publish desktop :dock))
      (%publish-watchers desktop id)
      window)))

;;; --- telling the page that something changed (#1218) -------------------------------------
;;;
;;; The desktop has one hyperion/feed. A key on it is (KIND . ID) and says what changed; the
;;; value is not used. The feed keeps one entry per key, so a window that changes a thousand
;;; times between two emissions is written to a page once. The HTML is rendered when an event
;;; is written to a page, by EVENT-DATA, and not when the change is published. Publishing is
;;; therefore cheap enough to do from any thread, nothing is rendered while no page is
;;; connected, and a page always receives the body as it is at that moment.

(defparameter *events-hz* 20
  "How many times a second, at most, GET /events writes the changes to one page.")

(defparameter *timer-step* 0.1
  "Seconds the desktop's timer sleeps between looks at the refresh intervals. A refresh
interval shorter than this is served at this rate, and STOP-DESKTOP waits about this long for
the timer.")

(defun %publish (desktop kind &optional id)
  "Record on DESKTOP's feed that the thing (KIND . ID) changed. Returns NIL."
  (feed:publish (%feed desktop) (cons kind id) t)
  nil)

(defun %publish-watchers (desktop id)
  "Publish the record of every window of DESKTOP that is watching the window ID. A window
watches another when its own data holds :TARGET with that window's id, and watches the whole
desktop when :TARGET is the empty string. The inspector is such a window."
  (%with-desktop (desktop)
    (dolist (w (%windows desktop))
      (let ((target (getf (%data w) :target)))
        (when (and (stringp target) (or (string= target "") (string= target id)))
          (%publish desktop :record (window-id w)))))))

(defun window-changed (window)
  "Say that WINDOW's body, state or data changed outside a request from the page, for example
when a job writes output or the agent finishes a turn. Code that changes a window calls this
after the change. Every connected page is then sent the window's body and position, and the
record of every inspector looking at the window. It may be called from any thread and as
often as the caller likes: calls made between two writes to a page become one event. It
renders nothing itself. Returns NIL."
  (let ((desktop (window-desktop window))
        (id (window-id window)))
    (%publish desktop :body id)
    (%publish desktop :window id)
    (%publish-watchers desktop id)
    nil))

(defun %shown-window (desktop id)
  "The window ID of DESKTOP when there is one and it is shown, else NIL."
  (%with-desktop (desktop)
    (let ((window (find-window desktop id)))
      (and window (state:state-shown? (window-state window)) window))))

(defun %one-line-safe (text)
  "TEXT without carriage returns, which Server-Sent Events read as the end of a line."
  (remove #\Return text))

(defun event-data (desktop key)
  "The data of the Server-Sent Event that tells a page about KEY, a key of DESKTOP's feed. The
first line says what to do and the lines after it are HTML:

  html ELEMENT-ID      put the HTML inside the element with that id
  window ID WxH STYLE  the window ID is shown, with that size and that style attribute; a page
                       that does not have it fetches /window/ID and adds it
  remove ID            the window ID is hidden or gone; take its element away
  skip                 nothing to do, because the window the key names is hidden or gone
  stop                 STOP-DESKTOP was called at some time; nothing to do

The keys are (:body . ID) for a window's body, (:window . ID) for its state, (:record . ID)
for the record an inspector shows, (:dock) and (:stop). The HTML is rendered here, when the
event is written, so it is the window as it is now."
  (out:with-output-style ()
    (destructuring-bind (kind . id) key
      (%one-line-safe
       (handler-case
           (ecase kind
             (:body
              (let ((window (%shown-window desktop id)))
                (if window
                    (format nil "html ~A-body~%~A" (%element-id window) (render-window-body window))
                    "skip")))
             (:window
              (let ((window (%shown-window desktop id)))
                (if window
                    (let ((s (window-state window)))
                      (format nil "window ~A ~Dx~D ~A" id
                              (state:state-width s) (state:state-height s) (%style window)))
                    (format nil "remove ~A" id))))
             (:record
              (let* ((window (%shown-window desktop id))
                     (html (and window (run-action window "record" '()))))
                (if html
                    (format nil "html ~A-record~%~A" (%element-id window) html)
                    "skip")))
             (:dock (format nil "html ou-dock~%~A" (render-dock desktop)))
             (:stop "stop"))
         (error () "skip"))))))

;;; The timer. One thread per desktop, alive only while a page is connected.

(defun %tick (desktop due now)
  "Publish the body of each shown window of DESKTOP whose refresh interval has passed. DUE is
a table from window id to the time its next push is due, and NOW is the time, both in
internal time units. A window seen for the first time is due one interval from NOW."
  (dolist (window (desktop-windows desktop))
    (let ((refresh (window-refresh window))
          (id (window-id window)))
      (when (and (realp refresh) (plusp refresh)
                 (state:state-shown? (window-state window)))
        (let ((step (max 1 (round (* refresh internal-time-units-per-second))))
              (at (gethash id due)))
          (cond ((null at) (setf (gethash id due) (+ now step)))
                ((>= now at)
                 (%publish desktop :body id)
                 (setf (gethash id due) (+ now step)))))))))

(defun %run-timer (desktop epoch)
  "The timer thread's function. It ends when no page is connected or STOP-DESKTOP was called."
  (let ((due (make-hash-table :test 'equal)))
    (loop
      (sleep *timer-step*)
      (when (%with-desktop (desktop)
              (when (or (/= epoch (%epoch desktop)) (zerop (%subscribers desktop)))
                (when (eq (%timer desktop) sb-thread:*current-thread*)
                  (setf (%timer desktop) nil))
                t))
        (return))
      (ignore-errors (%tick desktop due (get-internal-real-time))))))

(defun %connect (desktop)
  "Count one more page reading DESKTOP's events, start the timer when it is not running, and
return the desktop's epoch."
  (%with-desktop (desktop)
    (incf (%subscribers desktop))
    (unless (%timer desktop)
      (let ((epoch (%epoch desktop)))
        ;; THREAD-LIFETIME: scoped -- %RUN-TIMER returns once no page is connected or
        ;; STOP-DESKTOP has changed the epoch.
        (setf (%timer desktop)
              (sb-thread:make-thread (lambda ()
                                       (aion/dynamic:unblock-interrupts)
                                       (%run-timer desktop epoch))
                                     :name (format nil "desktop-ui timer: ~A"
                                                   (desktop-title desktop))))))
    (%epoch desktop)))

(defun %disconnect (desktop)
  (%with-desktop (desktop) (decf (%subscribers desktop))))

(defun desktop-subscribers (desktop)
  "How many GET /events streams of DESKTOP are being written now."
  (%with-desktop (desktop) (%subscribers desktop)))

(defun %events-response (desktop)
  "GET /events: the desktop's changes as Server-Sent Events, through hyperion/sse. A new
stream is first sent everything published so far, which brings a page that connected a
moment after it was rendered, or connected again after a break, up to date. The stream ends
when the page goes away or STOP-DESKTOP is called. A page that went away is found out when a
write to it fails, and the writer's error then leaves this function as it does any other
streaming body."
  (let ((pump (sse:events (feed:subscribe (%feed desktop) :hz *events-hz* :from :start)
                          :render (lambda (pair) (event-data desktop (car pair))))))
    (list 200 (copy-list sse:*headers*)
          (lambda (writer)
            (let ((epoch (%connect desktop)))
              (unwind-protect
                   (catch '%stream-ended
                     (flet ((write-chunk (chunk)
                              (unless (= epoch (%epoch desktop))
                                (throw '%stream-ended nil))
                              (funcall writer chunk)))
                       (write-chunk (sse:comment "connected"))
                       (funcall pump #'write-chunk)))
                (%disconnect desktop)))))))

(defun stop-desktop (desktop &key (timeout 5))
  "End every GET /events stream of DESKTOP and stop its timer thread. Call it when the server
that serves the desktop stops. Waits up to TIMEOUT seconds and returns true when no stream and
no timer is left. The desktop and its windows are unchanged, and it can be served again."
  (let ((timer nil)
        (deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (%with-desktop (desktop)
      (incf (%epoch desktop))
      (setf timer (%timer desktop)
            (%timer desktop) nil))
    ;; A stream looks at the epoch when it writes, so give each one something to write.
    (%publish desktop :stop)
    (when (and timer (not (eq timer sb-thread:*current-thread*)))
      (sb-thread:join-thread timer :default nil :timeout timeout))
    (loop until (or (zerop (desktop-subscribers desktop))
                    (> (get-internal-real-time) deadline))
          do (sleep 0.02))
    (and (zerop (desktop-subscribers desktop))
         (or (null timer) (not (sb-thread:thread-alive-p timer))))))

(defun run-action (window name parameters)
  "Call WINDOW's action NAME with the window and PARAMETERS, the posted form's alist, and
return the HTML string it returns. NIL when the window has no action of that name. The
desktop's lock is not held, so an action may take as long as it needs."
  (let ((action (cdr (assoc name (window-actions window) :test #'string=))))
    (and action (funcall action window parameters))))

;;; --- inspecting --------------------------------------------------------------------------

(defun inspect-event (event)
  "EVENT, a hyperion/desktop-ui/state:Win-Event, as a property list: (:name \"move\" :arguments (10 20))."
  (list :name (state:event-name event) :arguments (state:event-arguments event)))

(defun %designator-name (thing)
  "How a function designator is shown: a symbol with its package, anything else by its type."
  (cond ((null thing) nil)
        ((symbolp thing) (format nil "~A::~A" (package-name (symbol-package thing)) thing))
        (t (format nil "an object of type ~A" (type-of thing)))))

(defun %summary (value &optional (depth 0))
  "VALUE as something safe and short to show: numbers, symbols and short strings as they
are, a long string cut, a list summarised element by element to a small depth, and any other
object by its type alone. An object's slots are never printed, because a window's data may
hold something that must not appear on a page, such as a provider holding a credential."
  (typecase value
    ((or number symbol character) value)
    (string (if (> (length value) 120)
                (concatenate 'string (subseq value 0 120) "...")
                value))
    (cons (if (>= depth 2)
              "(...)"
              (loop for rest = value then (cdr rest)
                    for count from 0
                    while (consp rest)
                    when (= count 8) collect "..." and do (loop-finish)
                    collect (%summary (car rest) (1+ depth)))))
    (t (format nil "an object of type ~A" (type-of value)))))

(defun inspect-window (window)
  "WINDOW as a property list of plain values: its id and title, the fields of its state, the
names of its render function and actions, its refresh interval, a summary of its own data
(see %SUMMARY for what is left out), and its recent events, newest first."
  (%with-desktop ((window-desktop window))
    (let ((s (window-state window)))
      (list :id (window-id window)
            :title (window-title window)
            :x (state:state-x s) :y (state:state-y s)
            :width (state:state-width s) :height (state:state-height s)
            :z (state:state-z s)
            :visibility (if (state:state-shown? s) :shown :hidden)
            :render (%designator-name (window-render window))
            :actions (loop for (name . function) in (window-actions window)
                           collect (cons name (%designator-name function)))
            :refresh (window-refresh window)
            :data (loop for (key value) on (%data window) by #'cddr
                        collect key collect (%summary value))
            :events (mapcar #'inspect-event (%events window))))))

(defun inspect-desktop (desktop)
  "DESKTOP as a property list: its title, its windows' ids oldest first, the ids of the
windows that are shown, and the highest z in use."
  (%with-desktop (desktop)
    (list :title (desktop-title desktop)
          :windows (mapcar #'window-id (%windows desktop))
          :shown (loop for w in (%windows desktop)
                       when (state:state-shown? (window-state w)) collect (window-id w))
          :top-z (%top-z desktop))))

;;; --- the page's stylesheet and script ----------------------------------------------------

(defparameter *css*
  "html,body{height:100%;margin:0}body{background:#1b2230;color:#1c2330;font:14px/1.45 system-ui,sans-serif;overflow:hidden}#ou-dock{position:fixed;left:0;right:0;top:0;height:34px;display:flex;align-items:center;gap:.4rem;padding:0 .6rem;background:#0f141d;color:#c9d1d9;z-index:100000}#ou-dock .ou-name{font-weight:600;margin-right:.6rem}#ou-dock button{font:inherit;padding:.1rem .55rem;border:1px solid #3b4658;border-radius:4px;background:#1b2230;color:#c9d1d9;cursor:pointer}#ou-dock button.ou-hidden{opacity:.55}#ou-desktop{position:absolute;left:0;right:0;top:34px;bottom:0;overflow:hidden}.ou-window{position:absolute;display:flex;flex-direction:column;background:#fff;border:1px solid #3b4658;border-radius:6px;box-shadow:0 6px 22px rgba(0,0,0,.45);overflow:hidden;resize:both;min-width:120px;min-height:60px}.ou-titlebar{flex:none;display:flex;align-items:center;justify-content:space-between;padding:.25rem .5rem;background:#2c3850;color:#fff;cursor:move;user-select:none;touch-action:none}.ou-close{font:inherit;border:none;background:transparent;color:#fff;cursor:pointer;padding:0 .3rem}.ou-body{flex:1;min-height:0;overflow:auto;padding:.6rem}.ou-error{color:#a40e26;white-space:pre-wrap;margin:0}.ou-record{border-collapse:collapse;width:100%}.ou-record th{text-align:left;vertical-align:top;padding:.1rem .6rem .1rem 0;color:#57606a;font-weight:500}.ou-record td{font-family:ui-monospace,Consolas,monospace;font-size:12px;word-break:break-word}"
  "The desktop's stylesheet: the dock along the top, the desktop under it, and the window frame.")

(defparameter *page-scripts* '()
  "URLs of scripts the page loads after htmx, in this order, each with a deferred script
element in the page's head. Empty by default. An application binds it around a request, as it
binds *CSS*, to add a script of its own, such as a code editor. The application serves the
script itself.")

(defun client-js ()
  "The page's script, compiled from Parenscript. It listens on the document, so a window the
server adds later needs no setup. Pressing anywhere in a window raises it; dragging the title
bar moves it; releasing after a resize reports the new size. Each of those posts one event
to /window/ID/event.

Once the page has loaded, the script opens GET /events with EventSource and does what each
event's first line says; EVENT-DATA lists them. An event about the position of the window the
pointer is holding is left out, so a drag or a resize in progress is not undone by it. The
browser connects again by itself when the stream ends.

When an event replaces a window's body, an element in the old body that has both an id and
the attribute data-ou-preserve is kept: the same node is put back in place of the new element
with that id, so its value is kept, and when it or an element inside it had the focus, that
element gets the focus back, with the same selection when it is an input field. An input field
the user is typing into is marked this way, so a push of the body while the user types does not
lose what was typed. So is the element a code editor is built in, whose own editable element is
inside it.

The source uses no comparison operators, so the output has no angle bracket and can sit
inside a script element."
  (out:js-string
   '(funcall
     (lambda ()
       (let ((drag nil)
             (held nil)
             (pending (create)))
         (flet ((window-of (target)
                  (and target (@ target closest) (chain target (closest ".ou-window"))))
                (post (el body)
                  (chain window
                         (fetch (+ "/window/" (@ el dataset window) "/event")
                                (create "method" "POST"
                                        "headers" (create "Content-Type"
                                                          "application/x-www-form-urlencoded")
                                        "body" body)))))
           (chain document
                  (add-event-listener
                   "pointerdown"
                   (lambda (e)
                     (let ((el (window-of (@ e target))))
                       (setf held el)
                       (when el
                         (chain (post el "type=raise")
                                (then (lambda (response) (chain response (text))))
                                (then (lambda (z) (setf (@ el style z-index) z))))
                         (when (and (chain e target (closest ".ou-titlebar"))
                                    (not (chain e target (closest "button"))))
                           (setf drag (create "el" el
                                              "dx" (- (@ e client-x) (@ el offset-left))
                                              "dy" (- (@ e client-y) (@ el offset-top))))
                           (chain e (prevent-default))))))))
           (chain document
                  (add-event-listener
                   "pointermove"
                   (lambda (e)
                     (when drag
                       (setf (@ drag el style left)
                             (+ (chain -math (max 0 (- (@ e client-x) (@ drag dx)))) "px"))
                       (setf (@ drag el style top)
                             (+ (chain -math (max 0 (- (@ e client-y) (@ drag dy)))) "px"))))))
           (chain document
                  (add-event-listener
                   "pointerup"
                   (lambda (e)
                     (setf held nil)
                     (when drag
                       (post (@ drag el) (+ "type=move&x=" (@ drag el offset-left)
                                            "&y=" (@ drag el offset-top)))
                       (setf drag nil))
                     (let ((el (window-of (@ e target))))
                       (when el
                         (let ((size (+ (@ el offset-width) "x" (@ el offset-height))))
                           (unless (equal size (@ el dataset size))
                             (setf (@ el dataset size) size)
                             (post el (+ "type=resize&width=" (@ el offset-width)
                                         "&height=" (@ el offset-height))))))))))
           (flet ((element (id) (chain document (get-element-by-id id)))
                  (process (el)
                    (when (and el (@ window htmx)) (chain window htmx (process el))))
                  (replace-body (el html)
                    ;; An element under EL with an id and data-ou-preserve is kept: the same
                    ;; node goes back in place of the new one with that id, so what is typed
                    ;; in it, its focus and its caret survive the push.
                    (let ((kept (create))
                          (active (@ document active-element))
                          (focused nil)
                          (start nil)
                          (end nil))
                      (chain el (query-selector-all "[id][data-ou-preserve]")
                             (for-each (lambda (old)
                                         (setf (getprop kept (@ old id)) old)
                                         ;; The focus may be on an element inside the
                                         ;; kept one, as in a code editor.
                                         (when (and active (chain old (contains active)))
                                           (setf focused active)
                                           (try (setf start (@ active selection-start)
                                                      end (@ active selection-end))
                                                (:catch (err) (setf start nil)))))))
                      (setf (@ el inner-h-t-m-l) html)
                      (chain el (query-selector-all "[id][data-ou-preserve]")
                             (for-each (lambda (fresh)
                                         (let ((old (getprop kept (@ fresh id))))
                                           (when old (chain fresh (replace-with old)))))))
                      (when (and focused (@ focused is-connected))
                        (chain focused (focus))
                        (unless (equal start nil)
                          (try (chain focused (set-selection-range start end))
                               (:catch (err) nil)))))))
             (flet ((add-window (id)
                      ;; One request for a window the page does not have, however many
                      ;; events name it before the answer arrives.
                      (unless (getprop pending id)
                        (setf (getprop pending id) t)
                        (chain window
                               (fetch (+ "/window/" id))
                               (then (lambda (response)
                                       (if (@ response ok) (chain response (text)) "")))
                               (then (lambda (html)
                                       (setf (getprop pending id) nil)
                                       (unless (element (+ "win-" id))
                                         (let ((desk (element "ou-desktop")))
                                           (chain desk (insert-adjacent-h-t-m-l "beforeend" html))
                                           (process (@ desk last-element-child)))))
                                     (lambda () (setf (getprop pending id) nil)))))))
               (chain document
                      (add-event-listener
                       "DOMContentLoaded"
                       (lambda ()
                         (let ((source (new (-event-source "/events"))))
                           (setf (@ source onmessage)
                                 (lambda (e)
                                   (let* ((data (@ e data))
                                          (cut (chain data (index-of (chain -string (from-char-code 10)))))
                                          (head (if (= cut -1) data (chain data (slice 0 cut))))
                                          (html (if (= cut -1) "" (chain data (slice (+ cut 1)))))
                                          (words (chain head (split " ")))
                                          (kind (aref words 0))
                                          (id (aref words 1)))
                                     (cond ((equal kind "html")
                                            (let ((el (element id)))
                                              (when el
                                                (replace-body el html)
                                                (process el))))
                                           ((equal kind "window")
                                            (let ((el (element (+ "win-" id))))
                                              (cond ((not el) (add-window id))
                                                    ((not (equal el held))
                                                     (setf (@ el style css-text) (aref words 3))
                                                     (setf (@ el dataset size) (aref words 2))))))
                                           ((equal kind "remove")
                                            (let ((el (element (+ "win-" id))))
                                              (when el (chain el (remove)))))))))))))))))))))

;;; --- rendering ---------------------------------------------------------------------------

(defun %element-id (window) (format nil "win-~A" (window-id window)))

(defun %style (window)
  (let ((s (window-state window)))
    (format nil "left:~Dpx;top:~Dpx;width:~Dpx;height:~Dpx;z-index:~D"
            (state:state-x s) (state:state-y s)
            (state:state-width s) (state:state-height s) (state:state-z s))))

(defun render-window-body (window)
  "The HTML of WINDOW's body: what its render function returns. A serious condition in the
render function is shown in the window, so a mistake made while redefining one window at a
REPL leaves the rest of the desktop working. That includes running out of stack, which is a
STORAGE-CONDITION and not an ERROR."
  (handler-case
      (let ((render (window-render window)))
        (if render
            (or (funcall render window) "")
            ""))
    (serious-condition (e)
      (spin:with-html-string
        (:pre :class "ou-error"
          (format nil "This window's render function signalled an error:~%~A" e))))))

(defun render-window (window)
  "The HTML of WINDOW with its frame: the title bar, the close button and the body. Nothing in
it asks again on a timer: the page is sent a new body through GET /events. The close button
posts the event and swaps nothing, because the page removes the window when the event stream
says it is hidden."
  (let* ((id (window-id window))
         (element (%element-id window))
         (s (window-state window))
         (body (render-window-body window)))
    (spin:with-html-string
      (:section :class "ou-window" :id element :style (%style window)
                :data-window id
                :data-size (format nil "~Dx~D" (state:state-width s) (state:state-height s))
        (:header :class "ou-titlebar"
          (:span :class "ou-title" (window-title window))
          (:button :class "ou-close" :type "button" :title "Close"
                   :hx-post (format nil "/window/~A/event" id)
                   :hx-vals "{\"type\": \"close\"}" :hx-swap "none"
                   "x"))
        (:div :class "ou-body" :id (format nil "~A-body" element)
          (:raw body))))))

(defun render-dock (desktop)
  "The HTML of the dock's contents: the desktop's title and one button per window. The button
of a hidden window opens it again: it posts the event and swaps nothing, because the page adds
the window when the event stream says it is shown."
  (let ((windows (desktop-windows desktop)))
    (spin:with-html-string
      (:span :class "ou-name" (desktop-title desktop))
      (dolist (w windows)
        (if (state:state-shown? (window-state w))
            (:button :type "button" :disabled t (window-title w))
            (:button :type "button" :class "ou-hidden"
                     :hx-post (format nil "/window/~A/event" (window-id w))
                     :hx-vals "{\"type\": \"open\"}" :hx-swap "none"
                     (window-title w)))))))

(defun render-page (desktop)
  "The whole page: the dock, every shown window, htmx and the script. The script opens
GET /events, and the page is changed by what arrives there."
  (let ((dock (render-dock desktop))
        (windows (loop for w in (desktop-windows desktop)
                       when (state:state-shown? (window-state w))
                         collect (render-window w))))
    (spin:with-html-string
      (:doctype)
      (:html :lang "en"
        (:head
          (:meta :charset "utf-8")
          (:meta :name "viewport" :content "width=device-width, initial-scale=1")
          (:title (desktop-title desktop))
          (:script :src (assets:url :htmx) :defer t)
          (dolist (url *page-scripts*)
            (:script :src url :defer t))
          (:style (:raw *css*)))
        (:body
          ;; The event stream sends the dock's contents again when a window is opened,
          ;; closed, added or removed.
          (:div :id "ou-dock" (:raw dock))
          (:main :id "ou-desktop"
            (dolist (html windows) (:raw html)))
          (:script (:raw (client-js))))))))

;;; --- the inspector window ----------------------------------------------------------------

(defun %record-table (plist)
  "A two-column table of PLIST, each value printed as the Lisp reader would show it."
  (spin:with-html-string
    (:table :class "ou-record"
      (loop for (key value) on plist by #'cddr
            do (:tr (:th (string-downcase (symbol-name key)))
                    (:td (let ((*print-pretty* nil)) (prin1-to-string value))))))))

(defun inspector-record (window parameters)
  "The inspector's action `record': the record of the window it is looking at, as a table.
The connected pages are sent it again when that window changes: on an event, on
WINDOW-CHANGED, and when it is opened or removed. Looking at the desktop, any window's change
sends it."
  (declare (ignore parameters))
  (let* ((desktop (window-desktop window))
         (target (find-window desktop (window-datum window :target ""))))
    (if target
        (%record-table (inspect-window target))
        (%record-table (inspect-desktop desktop)))))

(defun inspector-select (window parameters)
  "The inspector's action `select': look at the window the form field `target' names, or at
the desktop itself when it names none, and answer with that record."
  (setf (window-datum window :target)
        (or (cdr (assoc "target" parameters :test #'string=)) ""))
  (inspector-record window parameters))

(defun render-inspector (window)
  "The inspector's body: a list of the desktop's windows to choose from, and the chosen
window's record under it."
  (let* ((desktop (window-desktop window))
         (target (window-datum window :target ""))
         (base (format nil "/window/~A/action" (window-id window)))
         (record-id (format nil "~A-record" (%element-id window)))
         (record (inspector-record window '())))
    (spin:with-html-string
      (:form :hx-post (format nil "~A/select" base) :hx-trigger "change"
             :hx-target (format nil "#~A" record-id) :hx-swap "innerHTML"
        (:label "Inspect "
          (:select :name "target"
            (:option :value "" :selected (string= target "") "the desktop")
            (dolist (w (desktop-windows desktop))
              (:option :value (window-id w) :selected (string= target (window-id w))
                       (window-title w))))))
      (:div :id record-id (:raw record)))))

(defun open-inspector (desktop &key (id "inspector") (title "Inspector") (target "")
                                    (x 420) (y 60) (width 380) (height 420))
  "Add an inspector window to DESKTOP, looking at the window TARGET names, or at the desktop
when TARGET is the empty string."
  (open-window desktop id :title title :render 'render-inspector
                          :actions '(("select" . inspector-select)
                                     ("record" . inspector-record))
                          :data (list :target target)
                          :x x :y y :width width :height height))

;;; --- routes ------------------------------------------------------------------------------

(defun %html (body &rest headers)
  (list 200 (list* :content-type "text/html; charset=utf-8" headers) (list body)))

(defun %plain (status text)
  (list status '(:content-type "text/plain; charset=utf-8") (list text)))

(defun %parameters (env)
  (http:form-alist (or (http:body-string env) "")))

(defun %call-with-window (desktop env function)
  "Call FUNCTION with the window the path's :id names, or answer 404."
  (let ((window (find-window desktop (or (router:path-param env "id") ""))))
    (if window
        (funcall function window)
        (%plain 404 "There is no such window."))))

(defun %handle-event (desktop env)
  "POST /window/:id/event. A raise answers with the new z as text, which the page applies at
once. Every other event answers 204: the page learns what a close, an open, a move or a
resize did from GET /events, as every other connected page does."
  (handler-case
      (let* ((event (event-from-parameters desktop (%parameters env)))
             (window (dispatch-event desktop (or (router:path-param env "id") "") event))
             (name (state:event-name event)))
        (if (string= name "raise")
            (%plain 200 (format nil "~D" (state:state-z (window-state window))))
            (list 204 '() '())))
    (unknown-window () (%plain 404 "There is no such window."))
    (bad-event (c) (%plain 400 (princ-to-string c)))))

(defun routes (desktop)
  "DESKTOP's route table, with the vendored htmx mounted:
  GET  /                          the page
  GET  /events                    what changed, as Server-Sent Events; the page opens it once
  GET  /dock                      the dock's contents
  GET  /window/:id                one window with its frame
  GET  /window/:id/body           one window's body
  POST /window/:id/event          move, resize, raise, close or open it
  POST /window/:id/action/:name   call one of its actions
The handlers look the window up on each request, so windows added later are served."
  (router:router
   (assets:mount)
   (router:route :get "/" (lambda (env) (declare (ignore env)) (%html (render-page desktop)))
                 :name :desktop)
   (router:route :get "/dock" (lambda (env) (declare (ignore env)) (%html (render-dock desktop)))
                 :name :dock)
   (router:route :get "/events" (lambda (env) (declare (ignore env)) (%events-response desktop))
                 :name :events)
   (router:route :get "/window/:id"
                 (lambda (env)
                   (%call-with-window desktop env (lambda (w) (%html (render-window w)))))
                 :name :window)
   (router:route :get "/window/:id/body"
                 (lambda (env)
                   (%call-with-window desktop env (lambda (w) (%html (render-window-body w)))))
                 :name :window-body)
   (router:route :post "/window/:id/event" (lambda (env) (%handle-event desktop env))
                 :name :window-event)
   (router:route :post "/window/:id/action/:name"
                 (lambda (env)
                   (%call-with-window
                    desktop env
                    (lambda (w)
                      (let ((html (run-action w (or (router:path-param env "name") "")
                                              (%parameters env))))
                        (if html
                            (%html html)
                            (%plain 404 "This window has no such action."))))))
                 :name :window-action)))

(defun make-app (desktop)
  "DESKTOP as a Clack application. The application declares the HTTP server it wants;
hyperion/desktop-ui declares none. GET /events is a stream that stays open, so the server
must run each request on a thread of its own or on a pool: Hunchentoot does, and the :uv
server does when it has workers. Call STOP-DESKTOP when the server stops."
  (let ((table (routes desktop)))
    (lambda (env)
      (out:with-output-style ()
        (router:dispatch table env)))))
