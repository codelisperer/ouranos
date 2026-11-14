;;;; ide.lisp --- the Ouranos IDE proof of concept: five windows in one SBCL image (#1218).
;;;;
;;;; A desktop (hyperion/desktop-ui) with these windows:
;;;;
;;;;   repl       a REPL. In Coalton mode an input goes to cons/coalton-repl, whose session keeps
;;;;              definitions between inputs. In Lisp mode an input is read and evaluated in
;;;;              this package, which is how a window is redefined while the desktop runs.
;;;;   clock      the time, which the page asks for again every second.
;;;;   chart      a bar chart of a SQLite query made through mnemosyne.
;;;;   agent      a praxeon agent. With no provider given it uses STUB-PROVIDER, which answers
;;;;              from the image and calls no model.
;;;;   inspector  hyperion/desktop-ui's inspector, which shows any window's record.
;;;;
;;;; It lives in praxeon because it needs praxeon, the rightmost framework it uses.
;;;;
;;;; Run it from a REPL:
;;;;   (asdf:load-system :praxeon/examples/ouranos-ide)
;;;;   (praxeon/examples/ouranos-ide:start)          ; then open http://127.0.0.1:27190/
;;;;   (praxeon/examples/ouranos-ide:stop)
;;;; or in a native window, which blocks until the window closes:
;;;;   (praxeon/examples/ouranos-ide:native-window)
;;;;
;;;; THIS EVALUATES WHAT THE PAGE SENDS. The REPL window runs code in this process, as any
;;;; REPL does. START binds 127.0.0.1 only and turns on hyperion's same-origin guard, so a page
;;;; from another site cannot post to it. It has no login. Do not bind it to another address.

(cl:defpackage #:praxeon/examples/ouranos-ide
  (:use #:cl)
  (:local-nicknames (#:ui #:hyperion/desktop-ui)
                    (#:srv #:hyperion/server)
                    (#:desk #:hyperion/desktop)
                    (#:repl #:cons/coalton-repl)
                    (#:be #:mnemosyne/backend)
                    (#:conn #:mnemosyne/conn)
                    (#:query #:mnemosyne/query)
                    (#:llm #:praxeon/llm)
                    (#:actor #:praxeon/actor)
                    (#:chat #:praxeon/chat-ui)
                    (#:spin #:spinneret))
  (:export #:*desktop* #:*port* #:make-app #:build-desktop #:start #:stop #:native-window
           #:stub-provider
           #:render-repl #:repl-eval #:render-clock #:render-chart #:render-agent #:agent-say
           #:chart-rows #:inspect-repl-entry))

(cl:in-package #:praxeon/examples/ouranos-ide)

;;; A window calls these through their symbols, so a DEFUN typed into the REPL window
;;; replaces them. NOTINLINE keeps the compiler from fixing a call to the old definition.
(declaim (notinline render-repl repl-eval render-clock render-chart render-agent agent-say
                    chart-rows inspect-repl-entry))

(defvar *desktop* (ui:make-desktop :title "Ouranos IDE")
  "The IDE's desktop. One per image.")

(defparameter *port* 27190
  "The port START listens on. Not a common development port.")

;;; --- the REPL window ---------------------------------------------------------------------

(defvar *session* (repl:make-session "OURANOS-IDE-REPL")
  "The Coalton session behind the REPL window. Its package keeps what an input defines.")

(defparameter *eval-time-limit* 20
  "Seconds a Coalton evaluation may run before cons/coalton-repl stops it.")

(defstruct (repl-entry (:constructor %make-repl-entry))
  "One input to the REPL window and what came of it. KIND is :value, :definition or :error."
  language input kind value type message)

(defun inspect-repl-entry (entry)
  "ENTRY as a property list, for the inspector, a REPL and the tests."
  (list :language (repl-entry-language entry) :input (repl-entry-input entry)
        :kind (repl-entry-kind entry) :value (repl-entry-value entry)
        :type (repl-entry-type entry) :message (repl-entry-message entry)))

(defun %coalton-entry (input)
  "Evaluate INPUT as Coalton in the session and describe the result."
  (let* ((result (repl:eval-input *session* input :time-limit *eval-time-limit*))
         (kind (repl:result-kind result)))
    (if (eq kind :exit-requested)
        (%make-repl-entry :language :coalton :input input :kind :error
                          :message "The input asks to end the process, and was not evaluated.")
        (%make-repl-entry :language :coalton :input input :kind kind
                          :value (repl:result-value result) :type (repl:result-type result)
                          :message (repl:result-message result)))))

(defun %lisp-entry (input)
  "Read every form of INPUT in this package, evaluate them in order, and describe the last
value. Output the forms print is put before the value. A form that would end the process is
refused, by the same test the Coalton engine uses."
  (let ((*package* (find-package '#:praxeon/examples/ouranos-ide)))
    (handler-case
        (let ((forms (with-input-from-string (in input)
                       (loop for form = (read in nil in)
                             until (eq form in)
                             collect form))))
          (if (repl:process-ending-p forms)
              (%make-repl-entry :language :lisp :input input :kind :error
                                :message "The input asks to end the process, and was not evaluated.")
              (let* ((value nil)
                     (printed (with-output-to-string (*standard-output*)
                                (dolist (form forms) (setf value (eval form))))))
                (%make-repl-entry :language :lisp :input input :kind :value
                                  :value (format nil "~A~S" printed value)
                                  :type (princ-to-string (type-of value))))))
      (error (e)
        (%make-repl-entry :language :lisp :input input :kind :error
                          :message (princ-to-string e))))))

(defun %entry-html (entry)
  (spin:with-html-string
    (:div :class "ide-entry"
      (:div (:span :class "ide-prompt" (if (eq (repl-entry-language entry) :lisp) "cl>" "λ"))
            (:code (repl-entry-input entry)))
      (ecase (repl-entry-kind entry)
        (:value
         (:div :class "ide-out"
           (:code (repl-entry-value entry))
           (when (repl-entry-type entry)
             (:span :class "ide-type" " : " (repl-entry-type entry)))))
        (:definition
         (:div :class "ide-out" "defined " (:code (repl-entry-message entry))))
        (:error
         (:pre :class "ou-error" (repl-entry-message entry)))))))

(defun repl-eval (window parameters)
  "The REPL window's action `eval'. The form field `input' is the source and `language' is
coalton or lisp. The entry is added to the window's transcript, and its HTML is the answer."
  (let* ((input (or (cdr (assoc "input" parameters :test #'string=)) ""))
         (lisp-p (equal "lisp" (cdr (assoc "language" parameters :test #'string=))))
         (entry (if lisp-p (%lisp-entry input) (%coalton-entry input))))
    (setf (ui:window-datum window :transcript)
          (append (ui:window-datum window :transcript) (list entry)))
    (%entry-html entry)))

(defun render-repl (window)
  "The REPL window's body: the transcript so far, then the input form."
  (let ((base (format nil "/window/~A" (ui:window-id window)))
        (entries (mapcar #'%entry-html (ui:window-datum window :transcript))))
    (spin:with-html-string
      (:div :id "ide-transcript" (dolist (html entries) (:raw html)))
      (:form :hx-post (format nil "~A/action/eval" base)
             :hx-target "#ide-transcript" :hx-swap "beforeend"
             :hx-on--after-request "this.reset()"
        (:select :name "language"
          (:option :value "coalton" "Coalton")
          (:option :value "lisp" "Lisp"))
        (:textarea :name "input" :rows 3 :spellcheck "false"
                   :placeholder "(+ 1 2)")
        (:button :type "submit" "Evaluate")))))

;;; --- the clock window --------------------------------------------------------------------

(defvar *now* 'get-universal-time
  "The function the clock reads the time from. A test binds it to a fixed time.")

(defun render-clock (window)
  "The clock window's body: the time and the date, in UTC."
  (declare (ignore window))
  (multiple-value-bind (second minute hour day month year) (decode-universal-time (funcall *now*) 0)
    (spin:with-html-string
      (:p :class "ide-clock" (format nil "~2,'0D:~2,'0D:~2,'0D" hour minute second))
      (:p :class "ide-date" (format nil "~4,'0D-~2,'0D-~2,'0D UTC" year month day)))))

;;; --- the chart window --------------------------------------------------------------------

(defvar *database-path* nil
  "The SQLite file the chart reads, or NIL before ENSURE-DATABASE has made one.")

(defparameter +frameworks+ '("aion" "cons" "mnemosyne" "elenchon" "hyperion" "praxeon")
  "The seed data: the six frameworks in dependency order. The chart shows the length of each name.")

(defun %backend () (be:make-sqlite *database-path*))

(defun ensure-database ()
  "Make a SQLite file in the temporary directory, with one table of the frameworks and the
length of each name, unless this image has made one already. Returns its path."
  (or *database-path*
      (let ((path (namestring
                   (merge-pathnames (format nil "ouranos-ide-~36R.db"
                                            (+ (* (get-universal-time) 1000000)
                                               (mod (get-internal-real-time) 1000000)))
                                    (uiop:temporary-directory)))))
        (setf *database-path* path)
        (conn:with-connection (c (%backend))
          (conn:exec c "CREATE TABLE frameworks (position INTEGER PRIMARY KEY, name TEXT NOT NULL, letters INTEGER NOT NULL)")
          (loop for name in +frameworks+
                for position from 1
                do (query:run c (list :insert-into "frameworks"
                                      :values (list (list :position position :name name
                                                          :letters (length name))))
                              :dialect :sqlite)))
        path)))

(defun delete-database ()
  "Delete the SQLite file ENSURE-DATABASE made, if any."
  (when *database-path*
    (ignore-errors (delete-file *database-path*))
    (setf *database-path* nil)))

(defun %column (row key)
  "The value of column KEY in ROW, a property list, whatever case the driver gave the name."
  (loop for (k v) on row by #'cddr
        when (string-equal (symbol-name k) (symbol-name key)) do (return v)))

(defun chart-rows ()
  "The chart's data: a list of (NAME . LETTERS), in dependency order, read from SQLite."
  (conn:with-connection (c (%backend))
    (mapcar (lambda (row) (cons (%column row :name) (%column row :letters)))
            (query:fetch c '(:select (:name :letters) :from ("frameworks") :order-by (:position))
                         :dialect :sqlite))))

(defun render-chart (window)
  "The chart window's body: one horizontal bar per row of CHART-ROWS, drawn as SVG."
  (declare (ignore window))
  (let* ((rows (chart-rows))
         (largest (max 1 (reduce #'max rows :key #'cdr :initial-value 0)))
         (row-height 24))
    (spin:with-html-string
      (:p :class "ide-caption" "Letters in each framework's name, from SQLite through mnemosyne.")
      (:raw
       (with-output-to-string (svg)
         (format svg "<svg class=\"ide-chart\" width=\"300\" height=\"~D\" role=\"img\">"
                 (* row-height (length rows)))
         (loop for (name . letters) in rows
               for y from 0 by row-height
               ;; NAME is escaped; the numbers are integers this function computed.
               do (format svg "<text x=\"0\" y=\"~D\">~A</text><rect x=\"90\" y=\"~D\" width=\"~D\" height=\"16\" fill=\"#4a72b0\"><title>~D</title></rect><text x=\"~D\" y=\"~D\">~D</text>"
                          (+ y 14) (spin:escape-string name) y
                          (round (* 180 letters) largest) letters
                          (+ 96 (round (* 180 letters) largest)) (+ y 14) letters))
         (format svg "</svg>"))))))

;;; --- the agent window --------------------------------------------------------------------

(defclass stub-provider (llm:provider)
  ((desktop :initarg :desktop :reader stub-desktop))
  (:documentation "A provider that calls no model. It answers from the image: it repeats what
was said and names the windows that are open. Used when START is given no provider."))

(defmethod llm:complete ((p stub-provider) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore system tools max-tokens temperature tool-choice))
  (let* ((last-content (llm:content (car (last messages))))
         (said (if (stringp last-content) last-content "something that was not text")))
    (llm:make-completion
     :stop-reason :end
     :text (format nil "This is the stub provider, so no model was called. You said: ~A. The windows shown are: ~{~A~^, ~}."
                   said (getf (ui:inspect-desktop (stub-desktop p)) :shown)))))

(defvar *agent* nil
  "The praxeon agent behind the agent window. BUILD-DESKTOP makes it.")

(defun %make-agent (desktop provider)
  "An agent on PROVIDER with one means, list_windows, which reports DESKTOP's windows."
  (let ((agent (actor:make-agent
                :name "ide" :provider provider
                :system-prompt "You are the assistant inside the Ouranos IDE, a desktop of windows running in one SBCL image. Answer briefly.")))
    (actor:register-means
     agent "list_windows" "Lists the ids of the IDE's windows, and which of them are shown."
     (lambda (arguments)
       (declare (ignore arguments))
       (let ((record (ui:inspect-desktop desktop)))
         (format nil "Windows: ~{~A~^, ~}. Shown: ~{~A~^, ~}."
                 (getf record :windows) (getf record :shown)))))
    agent))

(defun agent-say (window parameters)
  "The agent window's action `say': run one turn of the agent on the form field `text', add
both sides to the window's transcript, and answer with their HTML. An error in the turn is
shown as the agent's answer, so a provider that fails does not break the window."
  (let* ((text (or (cdr (assoc "text" parameters :test #'string=)) ""))
         (reply (handler-case (or (actor:run-turn *agent* text) "")
                  (error (e) (format nil "The turn failed: ~A" e))))
         (exchange (list (cons :user text) (cons :assistant reply))))
    (setf (ui:window-datum window :transcript)
          (append (ui:window-datum window :transcript) exchange))
    (%exchange-html exchange)))

(defun %exchange-html (messages)
  "The chat bubbles for MESSAGES, a list of (:user . TEXT) and (:assistant . TEXT)."
  (format nil "~{~A~}"
          (loop for (who . text) in messages
                collect (if (eq who :user)
                            (chat:user-bubble text)
                            (chat:assistant-bubble "ide" text)))))

(defun render-agent (window)
  "The agent window's body: the conversation so far, then the input form."
  (let ((bubbles (%exchange-html (ui:window-datum window :transcript))))
    (spin:with-html-string
      (:div :id "ide-chat" (:raw bubbles))
      (:form :hx-post (format nil "/window/~A/action/say" (ui:window-id window))
             :hx-target "#ide-chat" :hx-swap "beforeend"
             :hx-on--after-request "this.reset()"
        (:input :type "text" :name "text" :placeholder "Ask the agent" :autocomplete "off")
        (:button :type "submit" "Send")))))

;;; --- the desktop and the server ----------------------------------------------------------

(defparameter *css*
  ".ide-entry{margin-bottom:.6rem;font-family:ui-monospace,Consolas,monospace;font-size:12px}.ide-entry code{white-space:pre-wrap}.ide-prompt{color:#4a72b0;font-weight:600;margin-right:.4rem}.ide-out{margin-left:1.2rem}.ide-type{color:#57606a}.ou-body form{display:flex;gap:.4rem;align-items:flex-start;margin-top:.4rem}.ou-body textarea,.ou-body input[type=text]{flex:1;font:12px ui-monospace,Consolas,monospace}.ide-clock{font:600 34px ui-monospace,Consolas,monospace;margin:.2rem 0}.ide-date,.ide-caption{color:#57606a;margin:0 0 .4rem}.ide-chart text{font:12px ui-monospace,Consolas,monospace}.message{margin:0 0 .5rem;border:1px solid #d5dae2;border-radius:5px}.message-header{padding:.1rem .5rem;background:#7a8699;color:#fff;font-size:12px}.message-header p,.message-body p{margin:0}.message.px-user .message-header{background:#4a72b0}.message-body{padding:.3rem .5rem}"
  "The IDE windows' own styles, added to hyperion/desktop-ui's.")

(defun build-desktop (&key provider (desktop *desktop*))
  "Put the five windows on DESKTOP, replacing any with the same ids, make the database and
the agent, and return DESKTOP. PROVIDER is a praxeon/llm:provider for the agent; with none,
the agent uses STUB-PROVIDER and calls no model."
  (ensure-database)
  (setf *agent* (%make-agent desktop (or provider (make-instance 'stub-provider :desktop desktop))))
  (ui:open-window desktop "repl" :title "REPL" :render 'render-repl
                                 :actions '(("eval" . repl-eval))
                                 :x 20 :y 20 :width 460 :height 360)
  (ui:open-window desktop "clock" :title "Clock" :render 'render-clock :refresh 1
                                  :x 500 :y 20 :width 240 :height 130)
  (ui:open-window desktop "chart" :title "Chart" :render 'render-chart :refresh 5
                                  :x 500 :y 170 :width 340 :height 230)
  (ui:open-window desktop "agent" :title "Agent" :render 'render-agent
                                  :actions '(("say" . agent-say))
                                  :x 20 :y 400 :width 460 :height 300)
  (ui:open-inspector desktop :x 860 :y 20 :width 380 :height 460 :target "clock")
  desktop)

(defun make-app (&optional (desktop *desktop*))
  "DESKTOP as a Clack application, with the IDE's styles added to the desktop's. The styles
are bound around each request, because the page reads them when it is rendered."
  (let ((app (ui:make-app desktop)))
    (lambda (env)
      (let ((ui:*css* (concatenate 'string ui:*css* *css*)))
        (funcall app env)))))

(defvar *handler* nil "The running server, or NIL.")

(defun start (&key (port *port*) provider)
  "Build the desktop and serve it on 127.0.0.1:PORT. Returns the server's handler. Open
http://127.0.0.1:PORT/ in a browser to use it. PROVIDER is passed to BUILD-DESKTOP.

The server refuses a request whose Host is not this address, and a POST that did not come
from its own page, because the REPL window evaluates what it is sent."
  (when *handler* (stop))
  (build-desktop :provider provider)
  (setf *handler* (srv:start (make-app) :server :hunchentoot :port port :host "127.0.0.1"
                                        :request-guard :same-origin)))

(defun stop ()
  "Stop the server START started, and delete the chart's database file."
  (when *handler*
    (srv:stop *handler*)
    (setf *handler* nil))
  (delete-database)
  t)

(defun native-window (&key provider)
  "Build the desktop and show it in a native window through hyperion/desktop:run-app, which
blocks until the window is closed. The tests do not call this, because it opens a window."
  (build-desktop :provider provider)
  (unwind-protect
       (desk:run-app (make-app) :title "Ouranos IDE" :width 1280 :height 800
                                :server :hunchentoot)
    (delete-database)))
