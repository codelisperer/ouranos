;;;; chat-ui.lisp --- the chat widget's parts, shared by the full page and the embed panel (#67).
;;;;
;;;; praxeon/web serves a conversation as a full page (GET /) and, for another site's page, as a
;;;; panel in an iframe (GET /embed/panel), opened by the loader script it serves at /embed.js.
;;;; Both are made of the parts here: the stylesheet, the transcript bubbles, the composer, the
;;;; acknowledgment gate, and the scripts that keep the transcript up to date. praxeon/web keeps
;;;; the routes, the conversations and the turns, and composes the pages from these.
;;;;
;;;; THE EMBED HAND-OFF. The panel is served without a session, because a page in an iframe
;;;; cannot send a header on its own navigation and a third-party cookie is not sent. It holds
;;;; the composer, disabled, and the transport element in a <template>. Then:
;;;;   1. The panel posts {type: "praxeon:grant-needed"} to its parent. The message carries
;;;;      nothing secret, so it is posted to any origin.
;;;;   2. The loader, in the host page, checks that the message came from its own iframe and from
;;;;      the service's origin. It POSTs to the host's own grant URL (data-grant-url), which
;;;;      answers {"grant": TOKEN} for the signed-in viewer, and posts {type: "praxeon:grant",
;;;;      grant: TOKEN} to the iframe, addressed to the service's origin only.
;;;;   3. The panel accepts a grant only from its parent and only from an origin the app allows
;;;;      (:EMBED-ORIGINS). It exchanges it at POST /embed/session, keeps the session id in
;;;;      memory, sends it on every htmx request through the body's hx-headers, starts the
;;;;      transport and enables the composer.
;;;;   4. When a request is refused with 401, because the session ended, the panel asks for a new
;;;;      grant as in step 1, and the next session replaces the old one.
;;;; The grant never appears in a URL, so it cannot reach a log or a Referer header.
;;;;
;;;; Nothing here loads an AMD or UMD loader or assigns window.htmx: a host page whose htmx is
;;;; set by the time an AMD loader runs would lose it (the embedding requirement on #67).

(cl:defpackage #:praxeon/chat-ui
  (:use #:cl)
  (:local-nicknames (#:hjs #:hyperion/js)
                    (#:md #:hyperion/markdown)  ; safe Markdown -> HTML for bubbles
                    (#:out #:hyperion/output))
  ;; Parenscript matches its own macros by symbol identity, so these are the real ones.
  (:import-from #:parenscript #:chain #:@ #:create #:new)
  (:export #:*chat-css* #:chat-js #:events-js #:gate-modal #:user-bubble #:assistant-bubble
           #:composer #:embed-panel-js #:embed-loader-js))

(cl:in-package #:praxeon/chat-ui)

(defparameter *chat-css*
  "html,body{height:100%;margin:0}body{display:flex;flex-direction:column;background:#fff}.px-head{flex:0 0 auto;padding:.55rem 1rem;border-bottom:1px solid #e3e8ee;background:#f6f8fa}.px-head .title{margin-bottom:.1rem}#chat{flex:1 1 auto;overflow-y:auto;padding:1rem 1rem .35rem;background:#fff}.px-foot{flex:0 0 auto;padding:.6rem 1rem .8rem;border-top:1px solid #d7dee6;background:#e9edf2;box-shadow:0 -1px 5px rgba(12,22,44,.07)}#status{min-height:1.15em;margin:.15rem 0 .45rem}#msg{resize:vertical;min-height:2.6em;max-height:40vh}.message.px-user .message-header{background-color:#4a72b0}.message.px-user .message-body{background-color:#eef3fb;border-color:#c3d5ef}.message.px-assistant .message-header{background-color:#7a8699}.message.px-assistant .message-body{background-color:#f5f6f8;border-color:#d5dae2}"
  "Full-height chat layout: fixed header, scrolling transcript, fixed bottom input.")

(defun chat-js ()
  "The chat interaction JS, composed at render time from Hyperion's generic,
selector-parametrized Parenscript helpers (the CL->JS dogfood): keep #chat pinned
to the bottom, and make #msg an auto-growing box where Enter sends and Shift+Enter
inserts a newline. Generated per render (not baked at load) so it honors the
current output style -- pretty in dev, compact in prod. Each helper is its own
IIFE, joined with ';' so they run as separate statements."
  (format nil "~A;~%~A;~%~A;"
          (hjs:stick-to-bottom-js "#chat")
          (hjs:autogrow-textarea-js "#msg")
          (hjs:enter-submits-js "#msg")))

(defparameter *gate-js*
  "(function(){var g=document.getElementById('px-gate');if(!g)return;try{if(sessionStorage.getItem('px-gate-ack')==='1'){g.classList.remove('is-active');return;}}catch(e){}var b=document.getElementById('px-gate-accept');if(b)b.addEventListener('click',function(){try{sessionStorage.setItem('px-gate-ack','1');}catch(e){}g.classList.remove('is-active');var m=document.getElementById('msg');if(m)m.focus();});})();"
  "Entry-gate dismissal: on accept, remember in sessionStorage (per browser session)
and hide; on load, if already acknowledged this session, hide immediately.")

(defun gate-modal (gate)
  "An acknowledgment gate: a Bulma modal, active by default, the visitor must accept
before using the app. GATE is a plist (:title :body :accept). Active-by-default is
fail-safe -- with JS disabled it stays up, so the app is never used un-acknowledged."
  (spinneret:with-html-string
    (:div :id "px-gate" :class "modal is-active"
      (:div :class "modal-background")
      (:div :class "modal-card"
        (:header :class "modal-card-head"
          (:p :class "modal-card-title" (getf gate :title)))
        (:section :class "modal-card-body"
          (:p (getf gate :body)))
        (:footer :class "modal-card-foot is-justify-content-flex-end"
          (:button :id "px-gate-accept" :class "button is-primary"
                   (getf gate :accept)))))
    (:script :type "text/javascript" (:raw *gate-js*))))

(defun user-bubble (msg)
  (spinneret:with-html-string
    (:article :class "message px-user"
      (:div :class "message-header" (:p "you"))
      ;; Render as Markdown so paragraphs/blank lines and formatting are preserved
      ;; faithfully. Safe by default -- md:render escapes raw HTML in user input.
      (:div :class "message-body content" (:raw (md:render msg))))))

(defun assistant-bubble (name msg)
  ;; px-user / px-assistant are *neutral* style hooks with default colors in
  ;; *CHAT-CSS*; an app recolors them via its own :theme-css (see START), so
  ;; app-specific look stays at the app level -- this layer is app-agnostic.
  (spinneret:with-html-string
    (:article :class "message px-assistant"
      (:div :class "message-header" (:p name))
      ;; LLM replies are Markdown (lists, code fences, emphasis); render them.
      ;; Safe by default -- any raw HTML the model emits is escaped, not executed.
      (:div :class "message-body content" (:raw (md:render msg))))))

(defun events-js ()
  "The page's stream client, for a page with a #px-events element. It opens an EventSource on the
element's data-px-events URL, from the cursor in #px-cursor, and gives each event's data to
htmx.swap, which appends the items to #chat and makes the out-of-band swaps.

The browser reconnects a dropped stream by itself, sending Last-Event-ID. When the server refuses
the stream instead, which is what a spent ticket gets, the EventSource closes, and this opens a new
one after two seconds, from the cursor the page has reached. With data-px-ticket, the URL a stream
ticket is asked for, each stream first gets a ticket there, sending the hx-headers of the nearest
element that has them, and passes it as `ticket'; a ticket refused with 401 dispatches
`px-unauthorized' on the body.

It runs at load, and is also window.pxStartEvents, which the embed panel calls once it has a
session and has put #px-events in the page."
  (out:js-string
   '(funcall
     (lambda ()
      (let ((start
             (lambda ()
               (let ((el (chain document (get-element-by-id "px-events"))))
                 (when el
                   ;; LET* because the later bindings call the earlier ones: Parenscript renames a
                   ;; parallel LET's bindings.
                   (let* ((url (chain el (get-attribute "data-px-events")))
                          (ticket-url (chain el (get-attribute "data-px-ticket")))
                          (cursor (lambda ()
                                    (let ((c (chain document (get-element-by-id "px-cursor"))))
                                      (if c (@ c value) ""))))
                          (session-headers
                            (lambda ()
                              (let ((h (chain el (closest "[hx-headers]"))))
                                (if h
                                    (chain *json* (parse (chain h (get-attribute "hx-headers"))))
                                    (create)))))
                          (begin nil)
                          (connect
                            (lambda (ticket)
                              (let ((source (new (*event-source
                                                  (+ url "?after=" (encode-u-r-i-component (funcall cursor))
                                                     (if ticket
                                                         (+ "&ticket=" (encode-u-r-i-component ticket))
                                                         ""))))))
                                (setf (@ source onmessage)
                                      (lambda (e)
                                        (chain htmx (swap "#chat" (@ e data)
                                                          (create swap-style "beforeend")))))
                                (setf (@ source onerror)
                                      (lambda ()
                                        ;; 2 is CLOSED: the server refused the stream, so the browser
                                        ;; will not retry it.
                                        (when (= (@ source ready-state) 2)
                                          (set-timeout begin 2000))))))))
                     (setf begin
                           (lambda ()
                             (if ticket-url
                                 (chain (fetch ticket-url (create method "POST"
                                                                  headers (funcall session-headers)))
                                        (then (lambda (r)
                                                (if (@ r ok)
                                                    (chain r (json))
                                                    (chain *promise (reject r)))))
                                        (then (lambda (j) (funcall connect (@ j ticket))))
                                        (catch (lambda (r)
                                                 ;; A refused session: the embed panel asks its host
                                                 ;; for a new grant when it hears this.
                                                 (when (and r (= (@ r status) 401))
                                                   (chain document body
                                                          (dispatch-event
                                                           (new (*custom-event "px-unauthorized")))))
                                                 (set-timeout begin 5000))))
                                 (funcall connect nil))))
                     (funcall begin)))))))
        (setf (@ window px-start-events) start)
        (funcall start))))))

(defun composer (&key disabled)
  "The message form: a multiline box and a Send button, posting to /api/message. The message
comes back through the poll or the stream, like every other item, so the POST's own response
has nothing to swap. DISABLED renders both disabled, for the embed panel until it has a session."
  (spinneret:with-html-string
    (:form :hx-post "/api/message" :hx-swap "none"
           :onsubmit "setTimeout(() => this.reset(), 0)"
      (:div :class "field has-addons"
        (:div :class "control is-expanded"
          (:textarea :id "msg" :class "textarea" :name "message" :rows "1"
                     :placeholder "Say something…  (Enter to send · Shift+Enter for a newline)"
                     :autofocus (not disabled) :disabled disabled))
        (:div :class "control"
          (:button :id "px-send" :class "button is-primary" :disabled disabled "Send"))))))

(defun embed-panel-js ()
  "The embed panel's side of the hand-off in this file's header. It reads the allowed origins
(a JSON array) and the session URL from #px-embed's data-px-origins and data-px-session. On a
session it puts the contents of the <template> #px-live into the page, processes them with htmx,
starts the stream client if the page streams (window.pxStartEvents), and enables #msg and
#px-send."
  (out:js-string
   '(funcall
     (lambda ()
       (let ((cfg (chain document (get-element-by-id "px-embed"))))
         (when cfg
           (let* ((origins (chain *json* (parse (chain cfg (get-attribute "data-px-origins")))))
                  (session-url (chain cfg (get-attribute "data-px-session")))
                  (asking false)
                  (started false)
                  (ask (lambda ()
                         (unless asking
                           (setf asking true)
                           (chain window parent
                                  (post-message (create type "praxeon:grant-needed") "*")))))
                  (start (lambda ()
                           (let ((live (chain document (get-element-by-id "px-live"))))
                             (when live
                               (let ((box (@ live parent-node)))
                                 (chain box (append-child (chain live content (clone-node t))))
                                 (chain live (remove))
                                 (chain htmx (process box)))))
                           (when (@ window px-start-events)
                             (chain window (px-start-events)))
                           (dolist (id (list "msg" "px-send"))
                             (let ((el (chain document (get-element-by-id id))))
                               (when el (setf (@ el disabled) false))))))
                  (exchange
                    (lambda (grant)
                      (chain (fetch session-url
                                    (create method "POST"
                                            headers (create "Authorization" (+ "Grant " grant))))
                             (then (lambda (r)
                                     (if (@ r ok)
                                         (chain r (json))
                                         (chain *promise (reject r)))))
                             (then (lambda (j)
                                     (setf asking false)
                                     (chain document body
                                            (set-attribute "hx-headers"
                                                           (chain *json*
                                                                  (stringify
                                                                   (create "Authorization"
                                                                           (+ "Session "
                                                                              (@ j session)))))))
                                     (unless started
                                       (setf started true)
                                       (funcall start))))
                             (catch (lambda ()
                               ;; A grant that did not open a session: ask again later rather
                               ;; than at once, so a host that keeps sending a bad grant is not
                               ;; asked in a loop.
                               (set-timeout (lambda () (setf asking false) (funcall ask))
                                            5000)))))))
             (chain window
                    (add-event-listener
                     "message"
                     (lambda (e)
                       (let ((d (@ e data)))
                         (when (and (eql (@ e source) (@ window parent))
                                    (>= (chain origins (index-of (@ e origin))) 0)
                                    d
                                    (eql (@ d type) "praxeon:grant")
                                    (eql (typeof (@ d grant)) "string"))
                           (funcall exchange (@ d grant)))))))
             (chain document body
                    (add-event-listener "htmx:responseError"
                                        (lambda (e)
                                          (when (= (@ e detail xhr status) 401)
                                            (funcall ask)))))
             (chain document body (add-event-listener "px-unauthorized" ask))
             (funcall ask))))))))

(defparameter *embed-loader-css*
  ".praxeon-embed-launcher{position:fixed;bottom:1rem;z-index:2147483001;padding:.6rem 1.1rem;border:0;border-radius:999px;background:#3b5b8c;color:#fff;font:inherit;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,.25)}.praxeon-embed-panel{position:fixed;bottom:4.5rem;z-index:2147483000;width:380px;max-width:calc(100vw - 2rem);height:min(640px,75vh);background:#fff;border-radius:.5rem;box-shadow:0 4px 24px rgba(0,0,0,.25);overflow:hidden}.praxeon-embed-panel[hidden]{display:none}.praxeon-embed-right{right:1rem}.praxeon-embed-left{left:1rem}.praxeon-embed-frame{display:block;border:0;width:100%;height:100%}@media (max-width:600px){.praxeon-embed-panel{top:0;right:0;bottom:0;left:0;width:auto;max-width:none;height:auto;border-radius:0}.praxeon-embed-launcher.praxeon-embed-open{top:.5rem;bottom:auto}}"
  "The loader's styles in the host page. Every class starts with praxeon-embed-, so none can
match the host's own elements. On a screen 600px wide or less the open panel fills it.")

(defun embed-loader-js ()
  "The script served at /embed.js, which a host page on another origin includes with one
<script src> tag. It reads the tag's data attributes:
  data-grant-url  required: a URL on the host's own origin that answers a POST with
                  {\"grant\": TOKEN}, a grant for the signed-in viewer minted for this service
                  (`praxeon/ceiling:grant-token'). The request carries the host's cookies.
  data-container  a CSS selector of an element the host page already has: the panel's iframe
                  fills it, with no launcher and nothing laid over the page.
  data-position   without data-container, `left' or `right' (the default): the side of the
                  window where a launcher button and the panel it opens are docked.
  data-label      the launcher's text and the iframe's title, `Chat' by default.
The iframe shows /embed/panel from the origin the script was loaded from, and the script answers
its requests for a grant: see the hand-off in this file's header."
  (out:js-string
   `(funcall
     (lambda ()
       (let ((me (@ document current-script)))
         (when me
           (let* ((origin (@ (new (*u-r-l (@ me src))) origin))
                  (grant-url (chain me (get-attribute "data-grant-url")))
                  (container (chain me (get-attribute "data-container")))
                  (side (if (eql (chain me (get-attribute "data-position")) "left") "left" "right"))
                  (label (or (chain me (get-attribute "data-label")) "Chat"))
                  (frame nil)
                  (make-frame
                    (lambda ()
                      (setf frame (chain document (create-element "iframe")))
                      (setf (@ frame src) (+ origin "/embed/panel"))
                      (setf (@ frame title) label)
                      (setf (@ frame class-name) "praxeon-embed-frame")
                      frame))
                  (send-grant
                    (lambda ()
                      (chain (fetch grant-url (create method "POST" credentials "same-origin"
                                                      headers (create "Accept" "application/json")))
                             (then (lambda (r)
                                     (if (@ r ok)
                                         (chain r (json))
                                         (chain *promise (reject r)))))
                             (then (lambda (j)
                                     (when (and frame (eql (typeof (@ j grant)) "string"))
                                       (chain frame content-window
                                              (post-message (create type "praxeon:grant"
                                                                    grant (@ j grant))
                                                            origin)))))
                             (catch (lambda (e)
                                      (chain console (error "praxeon embed: no grant from data-grant-url" e))))))))
             (if (not grant-url)
                 (chain console (error "praxeon embed: the script tag needs data-grant-url"))
                 (progn
                   (chain window
                          (add-event-listener
                           "message"
                           (lambda (e)
                             (when (and frame
                                        (eql (@ e source) (@ frame content-window))
                                        (eql (@ e origin) origin)
                                        (@ e data)
                                        (eql (@ e data type) "praxeon:grant-needed"))
                               (funcall send-grant)))))
                   (if container
                       (let ((host (chain document (query-selector container))))
                         (if host
                             (chain host (append-child (funcall make-frame)))
                             (chain console (error "praxeon embed: no element matches data-container"))))
                       (let ((css (chain document (create-element "style")))
                             (button (chain document (create-element "button")))
                             (panel (chain document (create-element "div"))))
                         (setf (@ css text-content) ,*embed-loader-css*)
                         (chain document head (append-child css))
                         (setf (@ panel id) "praxeon-embed-panel")
                         (setf (@ panel class-name) (+ "praxeon-embed-panel praxeon-embed-" side))
                         (setf (@ panel hidden) t)
                         (setf (@ button type) "button")
                         (setf (@ button class-name) (+ "praxeon-embed-launcher praxeon-embed-" side))
                         (setf (@ button text-content) label)
                         (chain button (set-attribute "aria-controls" "praxeon-embed-panel"))
                         (chain button (set-attribute "aria-expanded" "false"))
                         (chain button
                                (add-event-listener
                                 "click"
                                 (lambda ()
                                   ;; The iframe is made on first open, so a page whose viewer
                                   ;; never opens the panel costs the service nothing.
                                   (unless frame (chain panel (append-child (funcall make-frame))))
                                   (setf (@ panel hidden) (not (@ panel hidden)))
                                   (chain button (set-attribute "aria-expanded"
                                                                (if (@ panel hidden) "false" "true")))
                                   (chain button class-list
                                          (toggle "praxeon-embed-open" (not (@ panel hidden)))))))
                         (chain document body (append-child panel))
                         (chain document body (append-child button)))))))))))))
