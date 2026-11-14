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
;;;; Not here: saving the layout between runs, and any limit on what a window's code may do.

(cl:defpackage #:hyperion/desktop-ui
  (:use #:cl)
  (:local-nicknames (#:state #:hyperion/desktop-ui/state)
                    (#:router #:hyperion/router)
                    (#:http #:hyperion/http)
                    (#:out #:hyperion/output)
                    (#:assets #:hyperion/assets)
                    (#:spin #:spinneret))
  ;; Parenscript matches its own macros by symbol identity, so these are the real ones.
  (:import-from #:parenscript #:chain #:@ #:create)
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
           #:routes #:make-app #:*css* #:client-js #:*event-history*))

(cl:in-package #:hyperion/desktop-ui)

;;; The functions a request calls, and so the ones a REPL may replace while the server runs.
(declaim (notinline render-page render-window render-window-body render-dock
                    dispatch-event run-action event-from-parameters
                    inspect-window inspect-event inspect-desktop
                    render-inspector inspector-select inspector-record))

;;; --- the records -------------------------------------------------------------------------

(defparameter *event-history* 12
  "How many of a window's most recent events it keeps for the inspector.")

(defclass desktop ()
  ((title :initarg :title :initform "Desktop" :accessor desktop-title)
   (windows :initform '() :accessor %windows
            :documentation "The windows, oldest first.")
   (lock :initform (sb-thread:make-mutex :name "desktop-ui desktop") :reader %lock
         :documentation "Held for every read or write of a window's state, data and events."))
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
            :documentation "NIL, or the number of seconds between the page's requests for a fresh body.")
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
picked up. REFRESH is NIL or a number of seconds: the page then asks for the body again that
often. DATA is the window's initial property list."
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
      window)))

(defun remove-window (desktop id)
  "Take the window ID out of DESKTOP altogether. Closing a window on the page only hides it."
  (%with-desktop (desktop)
    (setf (%windows desktop)
          (remove id (%windows desktop) :key #'window-id :test #'string=)))
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
in the window's history, and return the window. Signals UNKNOWN-WINDOW when there is none."
  (%with-desktop (desktop)
    (let ((window (or (find-window desktop id) (error 'unknown-window :id id))))
      (setf (window-state window) (state:apply-event event (window-state window)))
      (push event (%events window))
      (when (> (length (%events window)) *event-history*)
        (setf (%events window) (subseq (%events window) 0 *event-history*)))
      window)))

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

(defun client-js ()
  "The page's script, compiled from Parenscript. It listens on the document, so a window the
server adds later needs no setup. Pressing anywhere in a window raises it; dragging the title
bar moves it; releasing after a resize reports the new size. Each of those posts one event
to /window/ID/event. The source uses no comparison operators, so the output has no angle
bracket and can sit inside a script element."
  (out:js-string
   '(funcall
     (lambda ()
       (let ((drag nil))
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
                                         "&height=" (@ el offset-height))))))))))))))))

;;; --- rendering ---------------------------------------------------------------------------

(defun %element-id (window) (format nil "win-~A" (window-id window)))

(defun %style (window)
  (let ((s (window-state window)))
    (format nil "left:~Dpx;top:~Dpx;width:~Dpx;height:~Dpx;z-index:~D"
            (state:state-x s) (state:state-y s)
            (state:state-width s) (state:state-height s) (state:state-z s))))

(defun render-window-body (window)
  "The HTML of WINDOW's body: what its render function returns. An error in the render
function is shown in the window, so a mistake made while redefining one window at a REPL
leaves the rest of the desktop working."
  (handler-case
      (let ((render (window-render window)))
        (if render
            (or (funcall render window) "")
            ""))
    (error (e)
      (spin:with-html-string
        (:pre :class "ou-error"
          (format nil "This window's render function signalled an error:~%~A" e))))))

(defun render-window (window)
  "The HTML of WINDOW with its frame: the title bar, the close button and the body. A window
with a refresh interval asks for its body again that often."
  (let* ((id (window-id window))
         (element (%element-id window))
         (body-url (format nil "/window/~A/body" id))
         (s (window-state window))
         (refresh (window-refresh window))
         (body (render-window-body window)))
    (spin:with-html-string
      (:section :class "ou-window" :id element :style (%style window)
                :data-window id
                :data-size (format nil "~Dx~D" (state:state-width s) (state:state-height s))
        (:header :class "ou-titlebar"
          (:span :class "ou-title" (window-title window))
          (:button :class "ou-close" :type "button" :title "Close"
                   :hx-post (format nil "/window/~A/event" id)
                   :hx-vals "{\"type\": \"close\"}"
                   :hx-target (format nil "#~A" element) :hx-swap "outerHTML"
                   "x"))
        (if refresh
            (:div :class "ou-body" :id (format nil "~A-body" element)
                  :hx-get body-url :hx-trigger (format nil "every ~Ds" refresh)
                  :hx-swap "innerHTML"
              (:raw body))
            (:div :class "ou-body" :id (format nil "~A-body" element)
              (:raw body)))))))

(defun render-dock (desktop)
  "The HTML of the dock's contents: the desktop's title and one button per window. The button
of a hidden window opens it again."
  (let ((windows (desktop-windows desktop)))
    (spin:with-html-string
      (:span :class "ou-name" (desktop-title desktop))
      (dolist (w windows)
        (if (state:state-shown? (window-state w))
            (:button :type "button" :disabled t (window-title w))
            (:button :type "button" :class "ou-hidden"
                     :hx-post (format nil "/window/~A/event" (window-id w))
                     :hx-vals "{\"type\": \"open\"}"
                     :hx-target "#ou-desktop" :hx-swap "beforeend"
                     (window-title w)))))))

(defun render-page (desktop)
  "The whole page: the dock, every shown window, htmx and the script."
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
          (:style (:raw *css*)))
        (:body
          ;; A close or an open answers with the HX-Trigger header `ou-dock', which htmx
          ;; raises on the body, and the dock then fetches itself again.
          (:div :id "ou-dock" :hx-get "/dock" :hx-trigger "ou-dock from:body"
                :hx-swap "innerHTML"
            (:raw dock))
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
The page asks for it once a second, so a move or a redefinition shows without a reload."
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
      (:div :id record-id :hx-post (format nil "~A/record" base)
            :hx-trigger "every 1s" :hx-swap "innerHTML"
        (:raw record)))))

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
  "POST /window/:id/event. A close answers with an empty body, which the page swaps over
the window's element, and an open answers with the window's HTML, which the page appends to
the desktop; both ask the dock to fetch itself again. A raise answers with the new z as
text. A move or a resize answers 204."
  (handler-case
      (let* ((event (event-from-parameters desktop (%parameters env)))
             (window (dispatch-event desktop (or (router:path-param env "id") "") event))
             (name (state:event-name event)))
        (cond ((string= name "close") (%html "" :hx-trigger "ou-dock"))
              ((string= name "open") (%html (render-window window) :hx-trigger "ou-dock"))
              ((string= name "raise")
               (%plain 200 (format nil "~D" (state:state-z (window-state window)))))
              (t (list 204 '() '()))))
    (unknown-window () (%plain 404 "There is no such window."))
    (bad-event (c) (%plain 400 (princ-to-string c)))))

(defun routes (desktop)
  "DESKTOP's route table, with the vendored htmx mounted:
  GET  /                          the page
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
hyperion/desktop-ui declares none."
  (let ((table (routes desktop)))
    (lambda (env)
      (out:with-output-style ()
        (router:dispatch table env)))))
