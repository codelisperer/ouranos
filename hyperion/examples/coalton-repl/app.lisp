;;;; app.lisp --- a typed Coalton REPL as a native desktop app.
;;;;
;;;; The M1 capstone of Hyperion's desktop capability (docs/desktop.md, ADR-0008): a real
;;;; app running in a native OS webview, served by an in-process Common Lisp server -- no
;;;; Electron, no Tauri. The REPL ENGINE is cons/coalton-repl (eval + inferred type;
;;;; ADR-0009 splits the engine [cons's share] from the visual front-end [hyperion]); this
;;;; file is the HTMX/Spinneret front-end plus the run-app desktop entry.
;;;;
;;;; Enter a Coalton expression -> its value AND its inferred type; a definition
;;;; (define / define-type / ...) persists for later inputs. Input is MULTI-LINE: Enter
;;;; evaluates a balanced form and opens the next line inside an unbalanced one, so a
;;;; definition can be typed as it is written. "Balanced" is cons/coalton-repl's
;;;; INPUT-COMPLETE-P -- the engine owns that rule so a CLI REPL answers it identically;
;;;; the keydown handler below only mirrors it. Run it:
;;;;   (hyperion/examples/coalton-repl:desktop)   ; the native window (M1)
;;;;   (hyperion/examples/coalton-repl:dev)       ; hot-reload web dev at :8080
;;;;   (hyperion/examples/coalton-repl:serve)     ; plain web server

(cl:defpackage #:hyperion/examples/coalton-repl
  (:use #:cl)
  (:local-nicknames (#:srv  #:hyperion/server)
                    (#:http #:hyperion/http)
                    (#:out  #:hyperion/output)
                    (#:dev  #:hyperion/dev)
                    (#:hjs  #:hyperion/js)
                    (#:desk #:hyperion/desktop)
                    (#:assets #:hyperion/assets)
                    (#:router #:hyperion/router)
                    (#:repl #:cons/coalton-repl)
                    (#:spin #:spinneret))
  ;; Parenscript matches its own macros (chain / @ / regex) by symbol identity -- import the
  ;; reals. A same-named symbol from another package compiles to a bare `chain(...)` /
  ;; `regex(...)` function call in the emitted JS instead of the intended construct.
  (:import-from #:parenscript #:chain #:@ #:regex)
  (:export #:make-app #:start #:stop #:dev #:serve #:desktop #:main #:*port*))
(cl:in-package #:hyperion/examples/coalton-repl)

;; Spinneret validates attributes at COMPILE time against a table that is missing a few
;; legal HTML5 ones -- `autocomplete` on <textarea> among them. Its complaint is a full
;; WARNING, and ASDF escalates a WARNING to a build failure, so the app would not build
;; under `asdf:load-system` (it did under `ql:quickload`, which does not escalate --
;; docs/coalton-patterns.md 8a). `*unvalidated-attribute-prefixes*` is Spinneret's own
;; escape hatch; extending it beats deleting correct markup to satisfy a library gap.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (pushnew "autocomplete" spinneret:*unvalidated-attribute-prefixes* :test #'string=))

;;; --- session (one per process; a single-user desktop app) ------------------

(defvar *session* (repl:make-session)
  "The REPL session backing this app. One global session is right for a single-user
desktop app; a multi-user server would key a session per HTTP session.")

;;; --- styling + client behavior ---------------------------------------------

(defparameter *examples*
  '("(+ 1 2)"
    "(<> \"hello, \" \"world\")"
    "(define (square x) (* x x))"
    "(square 9)"
    "(map square (make-list 1 2 3 4))")
  "Starter inputs, rendered as clickable chips.")

;; CSS generated from CL via LASS (no raw stylesheet; the house CSS-DSL, ADR-0003/§4).
(defparameter *css*
  (lass:compile-and-write
   '(":root" :color-scheme "dark")
   '("*" :box-sizing "border-box")
   ;; The app-shell layout: the BODY is exactly one viewport tall and never scrolls, so
   ;; the header and the input form stay put and only #transcript scrolls between them.
   ;; `min-height 100vh` would let the body grow past the viewport instead, scrolling the
   ;; form off the bottom of the window -- the bug this replaces.
   '(body :margin 0 :background "#0d1117" :color "#c9d1d9" :height "100vh" :overflow "hidden"
          :display "flex" :flex-direction "column" :font-size "14px" :line-height "1.5"
          :font-family "ui-monospace, 'Cascadia Code', 'JetBrains Mono', Consolas, monospace")
   '(header :flex "none" :padding "1rem 1.25rem .55rem" :border-bottom "1px solid #21262d")
   '("header h1" :margin "0 0 .15rem" :font-size "1.1rem" :color "#e6edf3")
   '("header p" :margin 0 :color "#8b949e" :font-size ".82rem")
   ;; `min-height 0` is load-bearing: a flex item's default min-height is auto, which
   ;; refuses to shrink below its content -- so the transcript would grow the body
   ;; instead of scrolling inside it, and `overflow-y auto` would never engage.
   '("#transcript" :flex 1 :min-height 0 :padding "1rem 1.25rem" :overflow-y "auto")
   '(.entry :margin-bottom ".85rem")
   '(.prompt :color "#58a6ff" :margin-right ".5rem" :font-weight 600)
   ;; `pre-wrap` so a multi-line form echoes in the transcript as it was typed -- HTML
   ;; would otherwise collapse the newlines and indentation into one long line.
   '(".in code" :color "#e6edf3" :white-space "pre-wrap")
   '(.out :margin ".15rem 0 0 1.4rem")
   '(.val :color "#7ee787")
   '(.ty :color "#79c0ff")
   '(.def :margin ".15rem 0 0 1.4rem" :color "#d2a8ff")
   '(.err :margin ".2rem 0 0 1.4rem" :color "#ff7b72" :white-space "pre-wrap" :font-size ".82rem")
   ;; The busy cue, under the echoed input while the server evaluates. `steps(4)` walks the
   ;; ellipsis one dot at a time (content is set from the pseudo-element, so no JS timer),
   ;; and the pulse is what proves the window is alive rather than hung.
   '(:keyframes "pulse" ("0%" :opacity ".35") ("50%" :opacity 1) ("100%" :opacity ".35"))
   '(:keyframes "ellipsis" ("0%" :content "''") ("25%" :content "'.'")
                           ("50%" :content "'..'") ("75%" :content "'...'"))
   '(.working :margin ".2rem 0 0 1.4rem" :color "#8b949e" :font-size ".82rem"
              :animation "pulse 1.2s ease-in-out infinite")
   '(".working::after" :content "'...'" :animation "ellipsis 1.2s steps(1) infinite")
   ;; htmx puts `htmx-request` on the requesting element for the life of the request, so
   ;; the input dims itself while ENTER is refused -- no JS needed for the state.
   '("form.htmx-request #in" :opacity ".45" :caret-color "transparent")
   '(".hint p" :margin "0 0 .4rem" :color "#8b949e")
   '(.ex :display "inline-block" :margin ".15rem .3rem .15rem 0" :padding ".1rem .45rem"
         :background "#161b22" :border "1px solid #30363d" :border-radius "5px" :cursor "pointer")
   '(".ex:hover" :border-color "#58a6ff")
   ;; `flex-start`, not `center`: the λ stays on the FIRST line of a multi-line form
   ;; instead of drifting to the vertical middle of a box that is several lines tall.
   '(form :flex "none" :display "flex" :align-items "flex-start" :gap ".5rem"
          :padding ".75rem 1.25rem" :border-top "1px solid #21262d" :background "#010409")
   '("form .prompt" :font-size "1rem")
   ;; A TEXTAREA (multi-line forms), sized by hyperion/js:autogrow-textarea-js. `max-height
   ;; 40vh` is the CSS half of that helper's own :max-vh limit -- keep the two in step, or
   ;; the box grows past where it starts scrolling. `resize none` retires the OS grip,
   ;; which would otherwise fight the automatic sizing.
   '("#in" :flex 1 :background "transparent" :border "none" :outline "none"
           :color "#e6edf3" :font "inherit" :resize "none" :overflow-y "auto"
           :max-height "40vh" :padding 0)))

;; Client glue authored in Lisp, compiled to JS by Parenscript (no Node; ADR-0004). One
;; closure, because the three behaviours share state: the multi-line ENTER rule, the
;; in-flight lock, and the pending transcript entry all read the same BUSY flag. Keeping the
;; transcript at the bottom is hyperion/js:stick-to-bottom-js's job (added in %PAGE) -- the
;; body no longer scrolls, so scrolling the WINDOW here would do nothing.
(defparameter *client-js*
  (out:js-string
   `(funcall
     (lambda ()
       (let ((ta (chain document (get-element-by-id "in")))
             (tr (chain document (get-element-by-id "transcript")))
             (busy false)
             (pending nil))
         (labels
             ;; ENTER evaluates a BALANCED form; inside an unbalanced one it opens the next
             ;; line (Shift+Enter always does, as the escape hatch). This paren scan MIRRORS
             ;; cons/coalton-repl:INPUT-COMPLETE-P, which is the real rule -- a browser
             ;; cannot call the CL reader on a keystroke. The mirror only decides WHEN to
             ;; submit, so a disagreement degrades to "submits, and the reader explains"
             ;; -- never to a wrong evaluation. Teach the engine first, then this.
             ;; Strings, #\char literals and ; comments are blanked before counting, so a
             ;; paren inside "a)b" or #\( cannot fool it. Depth is tested through Math.sign
             ;; to keep < and > out of an inlined script (hyperion/src/js.lisp's header). A
             ;; NEGATIVE depth (a stray close paren) counts as balanced: it submits and the
             ;; reader explains, rather than leaving the box permanently un-sendable.
             ((depth (s)
                (let ((bare (chain s
                                   (replace (regex "/#\\|[\\s\\S]*?\\|#/g") " ")
                                   (replace (regex "/#\\\\./g") " ")
                                   (replace (regex "/\"(?:[^\"\\\\]|\\\\.)*\"/g") " ")
                                   (replace (regex "/;[^\\n]*/g") " "))))
                  ;; A `#|` with no `|#` survived the first pass, so the text is still
                  ;; inside a block comment: open, whatever the parens say.
                  (if (eq -1 (chain bare (index-of "#|")))
                      (- (@ (chain bare (split "(")) length)
                         (@ (chain bare (split ")")) length))
                      1)))
              ;; `cls`, not `class`: Parenscript passes parameter names through, and a
              ;; JS reserved word there is a SyntaxError that kills the whole inlined
              ;; script -- every handler on the page silently fails to install.
              (el (parent tag cls text)
                (let ((n (chain document (create-element tag))))
                  (when cls (setf (@ n class-name) cls))
                  ;; textContent, never innerHTML: this renders text the user typed, and
                  ;; the server-side transcript escapes it (Spinneret) for the same reason.
                  (when text (setf (@ n text-content) text))
                  (chain parent (append-child n))
                  n))
              (show-pending (text)
                ;; Echo the submitted form immediately, with a moving cue beneath it. The
                ;; webview and the Lisp image are separate processes, so this keeps
                ;; animating while the server evaluates -- which is the whole point: it
                ;; distinguishes "working" from "hung", where a static label cannot.
                (let ((entry (el tr "div" "entry pending" nil)))
                  (let ((line (el entry "div" "in" nil)))
                    (el line "span" "prompt" "λ")
                    (el line "code" nil text))
                  (el entry "div" "working" "evaluating")
                  (setf pending entry)))
              (clear-pending ()
                (when pending
                  (chain pending (remove))
                  (setf pending nil))))
           (when ta
             (chain ta
                    (add-event-listener
                     "keydown"
                     (lambda (e)
                       (when (and (equal (@ e key) "Enter") (not (@ e shift-key)))
                         (cond
                           ;; An evaluation is in flight: refuse, quietly. The session is a
                           ;; single package in one image -- a second form must not race the
                           ;; first through the Coalton compiler.
                           (busy (chain e (prevent-default)))
                           ;; Nothing typed: swallow it. A blank entry in the transcript is
                           ;; noise, and a newline in an empty box is worse.
                           ((not (@ (chain ta value (trim)) length))
                            (chain e (prevent-default)))
                           ;; Still open: fall through to the browser's own newline.
                           ((eq 1 (chain -math (sign (depth (@ ta value))))) nil)
                           (t (chain e (prevent-default))
                              (when (@ ta form) (chain ta form (request-submit))))))))))
           ;; Scoped to the FORM, not document.body: in dev mode the hot-reload poller is
           ;; also making requests, and they must not raise the busy flag or clear the cue.
           (let ((f (chain document (get-element-by-id "form"))))
             (when f
               (chain f (add-event-listener
                         "htmx:beforeRequest"
                         (lambda ()
                           (setf busy true)
                           (show-pending (@ ta value)))))
               (chain f (add-event-listener
                         "htmx:afterRequest"
                         (lambda ()
                           (setf busy false)
                           ;; Also the error path: a non-2xx response never swaps, so
                           ;; without this the cue would spin forever.
                           (clear-pending)
                           (chain f (reset))
                           ;; `reset` restores the VALUE, not the inline height autogrow
                           ;; set -- without this the box stays as tall as the form sent.
                           (setf (@ ta style height) "auto")
                           (chain ta (focus)))))))
           (chain document
                  (add-event-listener
                   "click"
                   (lambda (e)
                     (when (chain (@ e target class-list) (contains "ex"))
                       (setf (@ ta value) (@ e target text-content))
                       ;; autogrow listens for `input`, which assigning .value never fires.
                       (chain ta (dispatch-event (new (-event "input"))))
                       (chain ta (focus))))))))))))

;;; --- rendering (Spinneret) -------------------------------------------------

(defun %entry (r)
  "Render one evaluation RESULT as a transcript entry -- the HTMX swap payload, shared by
the page's initial render and the /eval fragment."
  (spin:with-html-string
    (:div :class "entry"
      (:div :class "in" (:span :class "prompt" "λ") (:code (repl:result-input r)))
      (ecase (repl:result-kind r)
        (:value
         (:div :class "out"
           (:code :class "val" (repl:result-value r))
           (when (repl:result-type r)
             (:span :class "ty" " : " (repl:result-type r)))))
        (:definition
         (:div :class "def" "defined " (:code (repl:result-message r))))
        (:error
         (:pre :class "err" (repl:result-message r)))))))

(defun %page ()
  (spin:with-html-string
    (:doctype)
    (:html :lang "en"
      (:head
        (:meta :charset "utf-8")
        (:meta :name "viewport" :content "width=device-width, initial-scale=1")
        (:title "Coalton REPL")
        ;; Vendored and embedded in the image, not fetched from a CDN. This app ships as
        ;; a native installer; loading htmx over the network meant it rendered nothing
        ;; offline (#123).
        (:script :src (assets:url :htmx) :defer t)
        (:style (:raw *css*)))
      (:body
        (:header
          (:h1 "Coalton REPL")
          (:p "A " (:strong "typed") " REPL — every expression shows its value "
              (:em "and") " its inferred type — served by Common Lisp, in a native window."))
        (:div :id "transcript"
          (:div :class "hint"
            (:p "Try one of these, then edit and re-enter:")
            (dolist (ex *examples*)
              (:code :class "ex" ex))))
        (:form :id "form" :hx-post "/eval" :hx-target "#transcript" :hx-swap "beforeend"
          (:span :class "prompt" "λ")
          ;; A textarea, one row tall until it needs more: an unbalanced form keeps typing
          ;; on the next line, so a definition can be entered the way it is written.
          ;; `autocomplete` IS valid on <textarea> (WHATWG lists it among the
          ;; autocomplete-supporting elements); Spinneret's attribute table just does
          ;; not know that, and warns at compile time. The warning is a full WARNING,
          ;; which ASDF escalates to a build failure -- see the eval-time push above.
          (:textarea :id "in" :name "input" :rows 1 :autocomplete "off"
                     :spellcheck "false" :autofocus t
                     :placeholder "(+ 1 2)   —   Enter evaluates; an unclosed ( keeps typing"))
        (:script (:raw *client-js*))
        (:script (:raw (hjs:autogrow-textarea-js "#in")))
        (:script (:raw (hjs:stick-to-bottom-js "#transcript")))))))

;;; --- the Clack app ---------------------------------------------------------

(defun %handle-eval (env)
  (let ((input (or (http:form-param (http:body-string env) "input") "")))
    (list 200 '(:content-type "text/html; charset=utf-8")
          (list (%entry (repl:eval-input *session* input))))))

(defun %handle-home ()
  (lambda (env)
    (declare (ignore env))
    (list 200 '(:content-type "text/html; charset=utf-8") (list (%page)))))

(defun %routes ()
  "This app's route table -- DATA. htmx arrives as a MOUNT from hyperion/assets, so
the desktop build carries it and this file never names its path.

There is no dev wiring here on purpose: hyperion/dev:serve wraps the app in DEV:WRAP-DEV,
which serves the reload endpoints and injects the poller script itself (#132). An app that
declares them again gets the boilerplate back and loses WRAP-DEV's REGISTER-QUIET-PATH,
which is what keeps poller traffic out of the developer's own REPL output."
  (router:router
   (assets:mount)
   (router:route :get "/" (%handle-home) :name :home)
   (router:route :post "/eval" #'%handle-eval :name :eval)))

(defun make-app ()
  "The route table above as a Clack handler, wrapped in this app's output style."
  (let ((routes (%routes)))
    (lambda (env)
      (out:with-output-style ()
        (router:dispatch routes env)))))

;;; --- lifecycle -------------------------------------------------------------

(defparameter *port* 27182
  "Fixed port for the `serve`/`dev` WEB modes. Deliberately NOT 8080 (or another common
dev port): 27182 (⌊e·10⁴⌋, mnemonic) is uncommon and sits below every OS's ephemeral
auto-assign range (Win 49152+, Linux 32768+), so it neither clashes with 8080-class
defaults nor gets handed out to some other process. The DESKTOP path doesn't use this at
all -- `run-app :port :auto` grabs an OS-assigned ephemeral port, which never conflicts.")

(defun %sources ()
  "This example's source directory -- what DEV watches. The examples live in hyperion's
tree rather than in systems of their own, so there is no `src/` for DEV:SERVE's :SYSTEM to
resolve and the root is named directly."
  (list (asdf:system-relative-pathname :hyperion "examples/coalton-repl/")))

(defun start (&key (port *port*) (host "127.0.0.1") dev (server (srv:default-server)) debug)
  "Build the app and start the server; return the handler (stop with STOP).

DEV now selects only the pretty-vs-compact output style: the reload endpoints and the
poller script come from DEV:WRAP-DEV, so nothing about the app itself differs."
  (setf out:*output-style* (if dev :pretty :compact))
  (srv:start (make-app) :server server :port port :host host :debug debug))

(defun stop (handler) (srv:stop handler))

(defun dev (&key (port *port*) (host "127.0.0.1"))
  "Hot-reload web dev: edit app.lisp, save, and the browser refreshes. http://HOST:PORT."
  (setf out:*output-style* :pretty)
  (dev:serve #'make-app :port port :host host :paths (%sources)))

(defun serve (&key (port *port*) (host "127.0.0.1"))
  "Start a plain web server and BLOCK until interrupted."
  (setf out:*output-style* :compact)
  (srv:serve-forever (make-app) :port port :host host :name "Coalton REPL"))

(defun %icon ()
  "The window icon for this OS, or NIL if it is not next to the source (a dumped binary
run from elsewhere). Windows wants .ico; GdkPixbuf and NSImage both read .png -- one file
per format, because a single one would only work on one platform. Both are generated by
assets/make-icon.ps1, which is the editable source for them."
  (ignore-errors
   (asdf:system-relative-pathname
    :hyperion (if (uiop:os-windows-p)
                  "examples/coalton-repl/assets/lambda.ico"
                  "examples/coalton-repl/assets/lambda.png"))))

(defun desktop (&key (title "Coalton REPL") (icon (%icon)))
  "Run the REPL as a NATIVE DESKTOP WINDOW (the M1 capstone): an in-process Hyperion
server + an out-of-process OS webview (hyperion/desktop:run-app). Blocks until closed."
  (desk:run-app (make-app) :title title :width 920 :height 660 :shell :webview :icon icon))

(defun main ()
  "Native-binary entry: open the REPL desktop window, then quit when it closes."
  (desktop)
  (uiop:quit 0))
