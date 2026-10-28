;;;; web.lisp --- a Clack-based web + REST surface for Praxeon agents.
;;;;
;;;; Any Praxeon client app can serve an agent over HTTP with one call:
;;;;   - GET  /            an HTMX + Bulma chat page (server renders HTML
;;;;                       fragments; HTMX swaps them -- no SPA, no compile-to-JS)
;;;;   - POST /api/message send a message. For HTMX, the message is published to the
;;;;                       conversation's transcript, the turn runs on a background
;;;;                       thread, and the response is empty with an HX-Trigger that
;;;;                       makes the page poll at once; a JSON client (Accept:
;;;;                       application/json) blocks for a synchronous {"reply": ...}.
;;;;   - GET  /api/progress the live-progress poll: the transcript items after the
;;;;                       page's cursor, the cursor moved past them, and the current
;;;;                       "… thinking / → tool" status (OOB). Same praxeon/event data
;;;;                       the CLI status-observer shows.
;;;;
;;;; Why polling, not SSE? The server backend is CONFIGURABLE via Clack, and the
;;;; default on Unix/macOS is Woo -- a single-threaded async (libev) server. Woo's
;;;; socket can only be written from its own event-loop thread and must never be
;;;; blocked, so long-lived SSE streams don't fit it. Polling keeps every handler
;;;; quick and the LLM turn on a background thread, so it works identically on Woo
;;;; and on Hunchentoot (the Windows default, thread-per-connection). The event
;;;; contract is transport-neutral, so an SSE renderer can be added for threaded
;;;; backends later without touching the agent loop.

(cl:defpackage #:praxeon/web
  (:use #:cl)
  (:local-nicknames (#:actor #:praxeon/actor)
                    (#:evt #:praxeon/event)
                    (#:llm #:praxeon/llm)
                    (#:chan #:hyperion/channel)  ; the per-conversation transcript
                    (#:ceiling #:praxeon/ceiling)  ; grants: the embed surface's auth (#67)
                    (#:ws #:praxeon/web-session)
                    ;; Hyperion provides the generic web machinery (extracted
                    ;; from this file); praxeon/web keeps only the agent/chat UI.
                    (#:srv #:hyperion/server)
                    (#:dev #:hyperion/dev)
                    (#:http #:hyperion/http)
                    (#:hjs #:hyperion/js)
                    (#:hh #:hyperion/html)
                    (#:out #:hyperion/output)   ; dev-pretty / prod-compact knob
                    (#:md #:hyperion/markdown)  ; safe Markdown -> HTML for bubbles
                    (#:i18n #:hyperion/i18n)    ; per-request locale (optional dict)
                    (#:assets #:hyperion/assets)
                    (#:router #:hyperion/router))
  ;; Re-export the pieces that are now pure Hyperion, so consumers (elise) that
  ;; call praxeon/web:stop/default-server/mark-reloaded/unwatch/reload! are unchanged.
  ;; REQUEST-SHUTDOWN comes with SERVE-FOREVER: it is how the thing that blocked is asked to
  ;; stop, so an app that has one and not the other still has to reach past this layer.
  (:import-from #:hyperion/server #:stop #:default-server #:request-shutdown)
  (:import-from #:hyperion/dev #:mark-reloaded #:unwatch #:reload!)
  (:export #:start #:serve-forever #:stop #:request-shutdown
           #:make-app #:default-server #:*default-port*
           #:mark-reloaded
           #:watch #:unwatch #:reload!))

(cl:in-package #:praxeon/web)

(defparameter *default-port* 8080)
(defparameter *poll-interval-ms* 700
  "How often the browser polls /api/progress for live updates.")

;;; Dev hot-reload (*reload-epoch*/mark-reloaded) and backend selection
;;; (default-server) now come from Hyperion (hyperion/dev, hyperion/server) and
;;; are re-exported via the package's :import-from above. A :dev page polls
;;; /api/reload-epoch and reloads itself when the epoch changes.

;;; --------------------------------------------------------------------------
;;; The CONVERSATION: the persistent context an agent deliberates over.
;;;
;;; Two identities, deliberately distinct, and named apart because both are in
;;; scope in this file:
;;;
;;;   conversation id -- the PERSISTENT context: the transcript, its accumulated
;;;                      token cost, and (later) whatever Kairos remembers of it.
;;;                      It outlives any browser, and it is the thing worth
;;;                      persisting. Praxeon's concern; see src/context.lisp.
;;;   session id      -- expressly a WEB APP session: one browser's attachment to
;;;                      a conversation, carried in a cookie. Transient by nature.
;;;                      hyperion/session's concern, not this file's.
;;;
;;; The relation is therefore MANY sessions to ONE conversation -- N browsers
;;; watching the same context, which is what makes per-viewer rendering (each
;;; viewer's own locale) a coherent idea rather than a contradiction.
;;;
;;; MAKE-APP keeps one conversation per KEY. The key comes from the app's
;;; :CONVERSATION-KEY function, which reads it from the request -- normally the
;;; signed-in principal. Without that function there is one conversation, shared
;;; by every browser, as before (#67).
;;;
;;; Each conversation publishes its transcript to a hyperion/channel, and every
;;; reader keeps its own index into it: the page carries it in a hidden field
;;; that each poll sends and each poll response moves on. So two tabs on one
;;; conversation both see every item. The mailbox this replaced gave each bubble
;;; to whichever poll arrived first. Per-viewer state such as a locale is #96.
;;; --------------------------------------------------------------------------
(defun %default-responder (agent message locale)
  "The default turn: the raw agent loop, ignoring LOCALE. A responder is
(agent message locale) -> reply string; LOCALE is the resolved request locale (NIL
when the app has no dictionary) so a client can localize the turn -- e.g. Elise's
translator agent, or a locale-aware guardrail. Overridable via :responder."
  (declare (ignore locale))
  (actor:run-turn agent message))

(defstruct conversation
  (key nil)                         ; what :CONVERSATION-KEY returned for it; NIL when shared
  (agent nil)
  (agent-name "Praxeon")
  (responder #'%default-responder)  ; (agent message locale) -> reply; client-overridable
  (turn-lock (sb-thread:make-mutex :name "praxeon-web-turn"))  ; serialize turns
  (state-lock (sb-thread:make-mutex :name "praxeon-web-state"))
  (events (chan:make-channel))                                  ; the transcript, as items
  (status "")                                                   ; latest status line
  (tokens 0)                                                    ; cumulative conversation cost
  (turn-tokens 0)                                               ; the last turn's cost
  (turns 0)                                                     ; turn ids given out so far
  ;; Which conversation a page's cursor belongs to. A key's conversation can expire and be
  ;; replaced, and an index into the old transcript means nothing in the new one.
  (epoch (aion/random:random-hex 64))
  ;; With grants: the capabilities and caps the agent was made from (%GRANT-TERMS), and how to
  ;; make the principal's agent from another grant.
  (built-with nil)
  (rebuild nil))

(defun %next-turn (conv)
  "A new turn id for CONV: 1 for its first turn, then 2, and so on."
  (sb-thread:with-mutex ((conversation-state-lock conv))
    (incf (conversation-turns conv))))

(defun %set-status (conv text)
  (sb-thread:with-mutex ((conversation-state-lock conv))
    (setf (conversation-status conv) text)))

(defun %get-status (conv)
  (sb-thread:with-mutex ((conversation-state-lock conv))
    (conversation-status conv)))

(defun %add-tokens (conv n turn-total)
  "Add N to the cumulative conversation cost; record TURN-TOTAL as this turn's cost."
  (sb-thread:with-mutex ((conversation-state-lock conv))
    (incf (conversation-tokens conv) n)
    (setf (conversation-turn-tokens conv) turn-total)))

(defun %get-tokens (conv)
  (sb-thread:with-mutex ((conversation-state-lock conv))
    (conversation-tokens conv)))

(defun %get-turn-tokens (conv)
  (sb-thread:with-mutex ((conversation-state-lock conv))
    (conversation-turn-tokens conv)))

;;; --------------------------------------------------------------------------
;;; The transcript. A conversation publishes what a viewer sees to its channel as
;;; data, and whoever reads the channel renders it, so the HTML poll here and an
;;; SSE or JSON reader later read the same items. An item is a plist:
;;;
;;;   (:kind :user :turn N :text TEXT)                          a message from the viewer
;;;   (:kind :assistant :turn N :text TEXT)                     the reply, as shown
;;;   (:kind :turn-ended :turn N :outcome :ok)                  the turn finished
;;;   (:kind :turn-ended :turn N :outcome :error :message TEXT) the turn signalled an error
;;;
;;; N is the turn the item belongs to, numbered from 1 in each conversation. Every turn
;;; ends with exactly one :TURN-ENDED item, so a reader can tell that a turn is over
;;; without inferring it from the status line, and which turn it was: with two tabs on
;;; one conversation, a second message can be published while the first turn still runs.
;;; The reply and the :TURN-ENDED item are published while the turn holds the turn lock,
;;; so a turn's items come before the next turn's reply.
;;; --------------------------------------------------------------------------
(defun %publish (conv item)
  "Append ITEM to CONV's transcript; return the index just past it."
  (chan:publish (conversation-events conv) item))

(defun %items-since (conv index)
  "Return (values ITEMS NEXT): CONV's transcript items at or after INDEX, and the index just past
them. A negative INDEX reads from the oldest item still held. A reader whose INDEX has left the
channel's window (more than `hyperion/channel:*default-capacity*' items behind) is moved to the
oldest item still held, so a tab that was away that long shows what is left and carries on."
  (handler-bind ((chan:cursor-behind-window
                   (lambda (c) (declare (ignore c)) (invoke-restart 'chan:resync))))
    (chan:since (conversation-events conv) index)))

;;; --------------------------------------------------------------------------
;;; HTML (Spinneret -- Hiccup for CL). Override %PAGE for a domain-specific UI.
;;; --------------------------------------------------------------------------
;;; The hot-reload poller is now hyperion/js:dev-reload-js (Parenscript, generated
;;; per-request; see the :dev branch of %PAGE). It was praxeon's *dev-reload-js*.

(defparameter *chat-css*
  "html,body{height:100%;margin:0}body{display:flex;flex-direction:column;background:#fff}.px-head{flex:0 0 auto;padding:.55rem 1rem;border-bottom:1px solid #e3e8ee;background:#f6f8fa}.px-head .title{margin-bottom:.1rem}#chat{flex:1 1 auto;overflow-y:auto;padding:1rem 1rem .35rem;background:#fff}.px-foot{flex:0 0 auto;padding:.6rem 1rem .8rem;border-top:1px solid #d7dee6;background:#e9edf2;box-shadow:0 -1px 5px rgba(12,22,44,.07)}#status{min-height:1.15em;margin:.15rem 0 .45rem}#msg{resize:vertical;min-height:2.6em;max-height:40vh}.message.px-user .message-header{background-color:#4a72b0}.message.px-user .message-body{background-color:#eef3fb;border-color:#c3d5ef}.message.px-assistant .message-header{background-color:#7a8699}.message.px-assistant .message-body{background-color:#f5f6f8;border-color:#d5dae2}"
  "Full-height chat layout: fixed header, scrolling transcript, fixed bottom input.")

(defun %chat-js ()
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

(defun %agent-model-label (agent)
  "A provider-neutral \"model · vendor\" label for AGENT, or NIL. The vendor is the
provider's class name; the model id comes from llm:model-of -- so this reads only
the neutral protocol and works for any provider."
  (let ((provider (and agent (actor:agent-provider agent))))
    (when provider
      (let ((model (llm:model-of provider))
            (vendor (string-downcase (symbol-name (class-name (class-of provider))))))
        (format nil "~@[~A · ~]~A" model vendor)))))

(defun %resolve-content (content locale)
  "Content passed to the page is either a plain string (used as-is) or a function
of the request LOCALE -- (locale -> string) -- so an app can localize the title,
intro, and footer without this layer knowing its dictionary. NIL stays NIL."
  (cond ((functionp content) (funcall content locale))
        (t content)))

(defun %negotiate-locale (env dictionary)
  "Resolve the request locale against an app-supplied DICTIONARY, and decide whether
to persist an explicit choice. Returns (values LOCALE SET-COOKIE-or-NIL). Without a
DICTIONARY the app isn't localized: (values NIL NIL) and content strings pass
through unchanged. Mirrors a consuming app's web layer -- ?lang= > cookie >
Accept-Language > default; an explicit ?lang= is written back to the lang cookie."
  (if dictionary
      (let* ((param (http:query-param env "lang"))
             ;; Call the low-level NEGOTIATE-LOCALE directly (?lang= > cookie >
             ;; Accept-Language > default): this web layer manages the lang cookie
             ;; itself, so it does not use the higher-level RESOLVE-LOCALE, whose
             ;; store/read-locale protocol reads the cookie for you (and whose lambda
             ;; list -- (source store request &key param) -- no longer takes :cookie).
             (locale (or (i18n:negotiate-locale
                          (i18n:supported-locales dictionary)
                          :param param
                          :cookie (http:cookie env "lang")
                          :accept-language (http:request-header env "accept-language"))
                         (i18n:default-locale dictionary))))
        (values locale (and param (i18n:lang-cookie locale))))
      (values nil nil)))

(defun %lang-switcher (locale locales)
  "A tiny inline language switcher (`EN · ES`) when more than one locale is on
offer; the current one is bold, the others link to /?lang=xx. Nothing when an app
is single-language (LOCALES is NIL or a singleton)."
  (when (and locale (cdr locales))
    (spinneret:with-html
      (:p :class "is-size-7 mt-1"
        (dolist (loc locales)
          (let ((label (string-upcase (symbol-name loc))))
            (if (eq loc locale)
                (:span :class "has-text-weight-bold mr-2" label)
                (:a :class "mr-2"
                    :href (format nil "/?lang=~(~A~)" (symbol-name loc)) label))))))))

(defparameter *gate-js*
  "(function(){var g=document.getElementById('px-gate');if(!g)return;try{if(sessionStorage.getItem('px-gate-ack')==='1'){g.classList.remove('is-active');return;}}catch(e){}var b=document.getElementById('px-gate-accept');if(b)b.addEventListener('click',function(){try{sessionStorage.setItem('px-gate-ack','1');}catch(e){}g.classList.remove('is-active');var m=document.getElementById('msg');if(m)m.focus();});})();"
  "Entry-gate dismissal: on accept, remember in sessionStorage (per browser session)
and hide; on load, if already acknowledged this session, hide immediately.")

(defun %gate-modal (gate)
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

(defun %page (title intro footer &optional dev model chat-html theme-css
                                           locale locales gate (cursor "0"))
  "The chat page: a full-height chat window -- fixed header, a transcript that
scrolls and auto-sticks to the bottom, and an input bar pinned at the bottom with
an auto-growing multiline box (Enter sends, Shift+Enter for a newline). Bulma-
styled, HTMX-driven, live progress via a small poller. INTRO shows atop the
transcript; FOOTER (a disclaimer / crisis resources) and MODEL (which model is
answering) show in the footer bar. When DEV, embed the hot-reload poller (see
*RELOAD-EPOCH*). CHAT-HTML is pre-rendered bubbles injected into #chat so a reload
restores the transcript, and CURSOR is the index of the first transcript item they do not
include, which the first poll sends. THEME-CSS is an app-supplied CSS string appended after
the base stylesheet -- the app's hook to recolor .px-user/.px-assistant etc."
  (spinneret:with-html-string
    (:doctype)
    (:html
     (:head
      (:meta :charset "utf-8")
      (:meta :name "viewport" :content "width=device-width, initial-scale=1")
      (:title title)
      ;; Vendored and embedded in the image (pre-publication issue 123). This is FRAMEWORK code, not an
      ;; example: every app built on praxeon/web inherited the CDN fetch, so the fix
      ;; matters more here than anywhere else it appeared.
      (:link :rel "stylesheet" :href (assets:url :bulma))
      (:script :src (assets:url :htmx))
      ;; (:raw ...) is REQUIRED: Spinneret escapes tag content, and entities inside
      ;; <style>/<script> are NOT decoded by the browser -- escaping would break them.
      (:style (:raw *chat-css*))
      (when theme-css (:style (:raw theme-css))))   ; app theme overrides the base
     (:body
      ;; header: title + which model is answering
      (:div :class "px-head"
        (:h1 :class "title is-4" title)
        (when intro (:p :class "is-size-6 has-text-grey mb-1" intro))  ; fixed description
        (:p :class "is-size-7"
            (when model (:span :class "has-text-info has-text-weight-medium"
                               (format nil "🤖 ~A  " model)))
            (:span :id "tokens" :class "has-text-grey-light"))  ; per-turn + conversation cost (OOB)
        (%lang-switcher locale locales))                        ; EN · ES, when localized
      ;; transcript -- scrolls; *chat-js* keeps it pinned to the bottom
      (:div :id "chat" :class "content"
        (when chat-html (:raw chat-html)))   ; rehydrate prior transcript
      ;; fixed bottom bar: status, the poller, the multiline input, the footer note
      (:div :class "px-foot"
        (:div :id "status" :class "has-text-grey is-italic is-size-7")
        ;; hx-trigger / hx-swap via Hyperion's typed HTMX vocabulary: the poll
        ;; interval is a real Duration (":every-ms N" -> "every Nms"), the swap a
        ;; checked Swap (:before-end -> "beforeend") -- no hand-rolled strings.
        ;; The poll also runs at once on `px-poll', which POST /api/message asks for
        ;; through HX-Trigger, so the user's own message appears without waiting for
        ;; the interval. `queue last' keeps that poll and the timed one from running
        ;; together: both would send the same cursor and append the same items twice.
        (:raw (%cursor-input cursor))
        (:div :hx-get "/api/progress"
              :hx-trigger (format nil "~A, px-poll from:body"
                                  (hh:trigger-string (list :every-ms *poll-interval-ms*)))
              :hx-include "#px-cursor" :hx-sync "this:queue last"
              :hx-target "#chat" :hx-swap (hh:swap-string :before-end))
        ;; The message comes back through the poll, like every other item, so the
        ;; POST's own response has nothing to swap.
        (:form :hx-post "/api/message" :hx-swap "none"
               :onsubmit "setTimeout(() => this.reset(), 0)"
          (:div :class "field has-addons"
            (:div :class "control is-expanded"
              (:textarea :id "msg" :class "textarea" :name "message" :rows "1"
                         :placeholder "Say something…  (Enter to send · Shift+Enter for a newline)"
                         :autofocus t))
            (:div :class "control"
              (:button :class "button is-primary" "Send"))))
        (when footer
          (:p :class "has-text-grey-dark is-size-7 mt-2" footer)))
      ;; the acknowledgment gate (modal, active by default) -- shown until accepted
      (when gate (:raw (%gate-modal gate)))
      ;; scripts at end of body so #chat / #msg exist when they run
      (:script (:raw (%chat-js)))
      (when dev (:script :type "text/javascript" (:raw (hjs:dev-reload-js))))))))

(defun %user-bubble (msg)
  (spinneret:with-html-string
    (:article :class "message px-user"
      (:div :class "message-header" (:p "you"))
      ;; Render as Markdown so paragraphs/blank lines and formatting are preserved
      ;; faithfully. Safe by default -- md:render escapes raw HTML in user input.
      (:div :class "message-body content" (:raw (md:render msg))))))

(defun %assistant-bubble (name msg)
  ;; px-user / px-assistant are *neutral* style hooks with default colors in
  ;; *chat-css*; an app recolors them via its own :theme-css (see START), so
  ;; app-specific look stays at the app level -- this layer is app-agnostic.
  (spinneret:with-html-string
    (:article :class "message px-assistant"
      (:div :class "message-header" (:p name))
      ;; LLM replies are Markdown (lists, code fences, emphasis); render them.
      ;; Safe by default -- any raw HTML the model emits is escaped, not executed.
      (:div :class "message-body content" (:raw (md:render msg))))))

(defun %text-of (content)
  "The plain text of a neutral message CONTENT -- a string, or the text parts of a
parts list (tool-use/tool-result parts are skipped)."
  (if (stringp content)
      content
      (with-output-to-string (s)
        (dolist (part content)
          (when (eq (getf part :type) :text)
            (write-string (getf part :text) s))))))

(defun %history-items (agent)
  "AGENT's conversation as transcript items: the user's messages and the assistant's replies,
without the tool calls and results between them. A new conversation starts its channel with
these, so an agent that arrives with a history shows it. Each user message starts a turn,
numbered from 1; a reply before the first user message is turn 0."
  (when agent
    (let ((turn 0))
      (loop for m in (actor:agent-history agent)
            for role = (llm:role m)
            for content = (llm:content m)
            ;; a real user turn is a plain string; tool-result messages are parts lists
            append (cond ((and (string= role "user") (stringp content))
                          (list (list :kind :user :turn (incf turn) :text content)))
                         ((string= role "assistant")
                          (let ((text (%text-of content)))
                            (when (plusp (length text))
                              (list (list :kind :assistant :turn turn :text text))))))))))

(defun %item-html (conv item)
  "ITEM as the chat page shows it. A turn that ended normally shows nothing, because its reply
is an item of its own. One that ended in an error shows the error in the agent's bubble, as the
page did before items existed."
  (ecase (getf item :kind)
    (:user (%user-bubble (getf item :text)))
    (:assistant (%assistant-bubble (conversation-agent-name conv) (getf item :text)))
    (:turn-ended (if (eq (getf item :outcome) :error)
                     (%assistant-bubble (conversation-agent-name conv)
                                        (format nil "error: ~A" (getf item :message)))
                     ""))))

(defun %items-html (conv items)
  (with-output-to-string (s)
    (dolist (item items) (write-string (%item-html conv item) s))))

(defun %cursor-value (conv index)
  "The cursor a page holds for CONV: its epoch and INDEX, the first transcript item the page has
not shown, as \"EPOCH:INDEX\"."
  (format nil "~A:~D" (conversation-epoch conv) index))

(defun %cursor-input (value &optional oob)
  "The hidden field the poll sends as `after', holding VALUE (%CURSOR-VALUE). A poll response
replaces it out of band (OOB true) with the cursor past what it returned."
  (spinneret:with-html-string
    (:input :type "hidden" :id "px-cursor" :name "after" :value value
            :hx-swap-oob (when oob (hh:oob)))))

(defun %status-oob (status)
  "An out-of-band swap that replaces #status -- how the poll updates the status
line without disturbing the appended chat bubbles."
  (spinneret:with-html-string
    (:div :id "status" :class "has-text-grey is-italic is-size-7"
          :hx-swap-oob (hh:oob)
          (when (plusp (length status)) status))))

(defun %tokens-oob (turn total)
  "An OOB swap for #tokens -- this turn's cost and TOTAL, the conversation's
cumulative cost (empty until >0). Both are token COUNTS, not a conversation:
making the scarce resource visible is economic calculation over means. (The
total resets if the server is rebuilt, e.g. a dev reload.)"
  (spinneret:with-html-string
    (:span :id "tokens" :class "has-text-grey-light" :hx-swap-oob (hh:oob)
           (when (plusp total)
             (format nil "· ~:D this turn · ~:D total" turn total)))))

;;; --------------------------------------------------------------------------
;;; The progress observer: praxeon/event -> conversation state (status + bubbles)
;;; --------------------------------------------------------------------------
(defun %arg-summary (args)
  "A short one-line rendering of tool ARGS (a hash-table) -- a \"query\" if present,
else the first value -- for a precise status like `-> web-search: \"…\"`."
  (when (hash-table-p args)
    (let ((v (or (gethash "query" args)
                 (block first
                   (maphash (lambda (k val) (declare (ignore k)) (return-from first val))
                            args)
                   nil))))
      (when v
        (let ((s (princ-to-string v)))
          (if (> (length s) 64) (concatenate 'string (subseq s 0 64) "…") s))))))

(defun %progress-observer (conv)
  "An observer (for praxeon/event) that records a *precise* transient status into
CONV as the model works, plus the running token cost (the scarce resource).
Statuses are made **sticky** across the poll interval: a tool call keeps showing
`→ tool: query` during the call, and the *following* deliberation shows
`reviewing <tool> results…` (a long window) -- so a fast tool call is still
visible even if its own window slips between polls. The reply item comes from
the responder's return value (see %TURN), not the :answer event, so a client's
post-processing (Elise's crisis guardrail) is reflected."
  (let ((last-tool nil)   ; most recent tool used this turn, for the review status
        (turn-sum 0))     ; running token total for this turn
    (lambda (event)
      (case (evt:event-type event)
        (:deliberating
         (%set-status conv (if last-tool
                               (format nil "reviewing ~A results…" last-tool)
                               "thinking…")))
        (:tool-call
         (let ((name (evt:event-get event :name))
               (detail (%arg-summary (evt:event-get event :arguments))))
           (setf last-tool name)
           (%set-status conv (if detail
                                 (format nil "→ ~A: ~A" name detail)
                                 (format nil "→ using ~A" name)))))
        ;; :tool-result -- leave the `→ tool` status up (the next :deliberating
        ;; switches it to `reviewing …`); a bare "reading…" would be microseconds.
        ;; ALL FOUR COUNTS (part of #161). The display is a token count, not a price, so a
        ;; token the model processed counts whether or not it came from the prompt cache.
        ;; Anthropic reports cached input separately from `input_tokens', so summing only
        ;; :input and :output showed a turn served mostly from the cache as nearly free.
        ;; A count the provider did not report adds nothing, as before.
        (:usage
         (let ((n (+ (or (evt:event-get event :input) 0)
                     (or (evt:event-get event :output) 0)
                     (or (evt:event-get event :cache-read) 0)
                     (or (evt:event-get event :cache-write) 0))))
           (incf turn-sum n)
           (%add-tokens conv n turn-sum)))))))

(defun %shown-reply (reply)
  "REPLY as the page shows it. A blank reply (a translator handoff that came back empty, or a
model that returned no text) would look like \"thinking… then nothing\", so it is shown as a
note instead."
  (if (or (not (stringp reply))
          (zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return) reply))))
      "*(no response — the model returned no text)*"
      reply))

(defun %publish-message (conv message)
  "Give MESSAGE a new turn id, publish it to CONV's transcript, and return the id."
  (let ((turn (%next-turn conv)))
    (%publish conv (list :kind :user :turn turn :text message))
    turn))

(defun %grant-terms (grant)
  "What of GRANT an agent is built from: its capabilities, as a sorted list, and its token and
call caps. Two grants with the same terms make the same agent."
  (list (sort (copy-list (ceiling:grant-capabilities grant)) #'string<)
        (ceiling:grant-token-cap grant)
        (ceiling:grant-call-cap grant)))

(defun %apply-grant (conv grant)
  "When GRANT's terms differ from those CONV's agent was made from, make the agent again from
GRANT and move the conversation onto it (`praxeon/actor:move-conversation'), so a grant with fewer
capabilities or a lower cap takes effect at the next turn. Caller holds CONV's turn lock."
  (when (and grant (conversation-rebuild conv))
    (let ((terms (%grant-terms grant)))
      (unless (equal terms (conversation-built-with conv))
        (let ((agent (funcall (conversation-rebuild conv) grant)))
          (actor:move-conversation (conversation-agent conv) agent)
          (setf (conversation-agent conv) agent
                (conversation-built-with conv) terms))))))

(defun %turn (conv message locale &key turn grant)
  "Run one turn of CONV on this thread and publish how it went: the reply as shown and then a
:TURN-ENDED item. TURN is the id %PUBLISH-MESSAGE gave MESSAGE when the caller published it;
without it, MESSAGE is published here. GRANT is the grant of the session that sent MESSAGE, when
the app takes grants; the turn runs on an agent made from it (%APPLY-GRANT). Returns
(values REPLY NIL), or (values NIL ERROR) when the responder signalled ERROR.

Turns are serialized by CONV's turn lock, which is held until the turn's last item is published
and its status line cleared, so a turn queued behind this one neither has its status cleared by
this one nor publishes its reply first. Turns run in the order they take the lock, which is not
always the order their messages were published in, because an SBCL mutex is not first-come,
first-served. TURN says which message each item belongs to; it does not say which turn ran
first. The progress observer records the status and token count while the turn runs."
  (let ((turn (or turn (%publish-message conv message))))
    (sb-thread:with-mutex ((conversation-turn-lock conv))
      (unwind-protect
           (handler-case
               (let ((reply (evt:with-observer ((%progress-observer conv))
                              (%apply-grant conv grant)
                              (funcall (conversation-responder conv)
                                       (conversation-agent conv) message locale))))
                 (%publish conv (list :kind :assistant :turn turn :text (%shown-reply reply)))
                 (%publish conv (list :kind :turn-ended :turn turn :outcome :ok))
                 (values reply nil))
             (error (e)
               (%publish conv (list :kind :turn-ended :turn turn :outcome :error
                                    :message (princ-to-string e)))
               (values nil e)))
        (%set-status conv "")))))

(defun %run-turn-async (conv message locale &optional grant)
  "Run one turn on a background thread so the web server's event loop stays free
(critical on Woo). See %TURN. LOCALE is the resolved request locale, handed to the
responder (e.g. for Elise's translator)."
  ;; The user's message is published here, on the request thread, and not by the turn
  ;; thread, so the poll that HX-Trigger asks for finds it even if the thread has not run yet.
  (let ((turn (%publish-message conv message)))
    ;; THREAD-LIFETIME: continues -- this thread runs ONE turn of the request that spawned it,
    ;; so it carries the caller's dynamic context (#158). Without the wrapper every line the
    ;; turn logs -- including the LLM request and response lines -- is missing the request-id
    ;; that hyperion/logging bound around the request, because a LET binding does not cross a
    ;; thread. The field is simply absent and nothing reports it.
    (sb-thread:make-thread
     (aion/dynamic:inheriting
      (lambda ()
        (aion/dynamic:unblock-interrupts)
        (%turn conv message locale :turn turn :grant grant)
        nil))
     :name "praxeon-web-turn")))

;;; --------------------------------------------------------------------------
;;; Request parsing -- the raw-Clack utilities (body-string/form-param/wants-json/
;;; json) are now hyperion/http; only the agent-specific "pull the message" stays.
;;; --------------------------------------------------------------------------
(defun %request-message (env)
  (let ((body (http:body-string env))
        (ct (or (getf env :content-type) "")))
    (if (search "application/json" ct)
        (let ((obj (http:json-object body)))
          (and obj (gethash "message" obj)))
        (http:form-param body "message"))))

;;; --------------------------------------------------------------------------
;;; The Clack app
;;; --------------------------------------------------------------------------
(defun %request-cursor (env)
  "The cursor the poll sent as `after', as (values INDEX EPOCH). INDEX is NIL when the poll sent
no cursor, or one whose index is not a non-negative integer. EPOCH is NIL for a bare index, which
is what a page rendered before cursors had epochs sends."
  (let* ((raw (http:query-param env "after"))
         (colon (and raw (position #\: raw :from-end t)))
         (n (and raw (ignore-errors (parse-integer raw :start (if colon (1+ colon) 0))))))
    (if (and (integerp n) (>= n 0))
        (values n (and colon (subseq raw 0 colon)))
        (values nil nil))))

(defparameter *conversation-restarted-notice*
  "The earlier conversation ended because it was not used for a while. This is a new conversation."
  "What the page shows at the top of the transcript when its conversation was replaced.")

(defun %progress-fragment (conv after &optional epoch)
  "The poll response: the transcript items from AFTER on, appended to #chat; the cursor moved
past them; and the status line and token count, out of band. With no AFTER, which is what a page
loaded before the cursor existed sends, no items are returned and the cursor is moved to the
newest item, so that page carries on from there instead of repeating the transcript.

When EPOCH is not CONV's, the page's cursor belongs to a conversation that has since been
replaced, so its index means nothing here. The response then replaces the whole of #chat, out of
band, with a notice that a new conversation has started and CONV's transcript so far."
  (let ((reset (and after epoch (string/= epoch (conversation-epoch conv)))))
    (multiple-value-bind (items next)
        (cond (reset (%items-since conv -1))
              (after (%items-since conv after))
              (t (values nil (chan:channel-length (conversation-events conv)))))
      (with-output-to-string (s)
        (if reset
            (write-string (spinneret:with-html-string
                            (:div :hx-swap-oob "innerHTML:#chat"
                              (:div :class "notification is-light px-notice"
                                *conversation-restarted-notice*)
                              (:raw (%items-html conv items))))
                          s)
            (write-string (%items-html conv items) s))
        (write-string (%cursor-input (%cursor-value conv next) t) s)
        (write-string (%status-oob (%get-status conv)) s)
        (write-string (%tokens-oob (%get-turn-tokens conv) (%get-tokens conv)) s)))))

(defun %handle-message (env conv dictionary &optional grant)
  (let ((message (%request-message env))
        ;; The POST carries no ?lang=; the locale rides the lang cookie set on GET
        ;; (or Accept-Language). NIL when the app has no dictionary.
        (locale (%negotiate-locale env dictionary)))
    (cond
      ((or (null message) (string= message ""))
       (list 400 '(:content-type "text/plain") (list "missing 'message'")))
      ;; REST client: synchronous JSON (blocks this request for the turn). The turn is
      ;; published like any other, so a page open on the same conversation shows it.
      ((http:wants-json env)
       (multiple-value-bind (reply e) (%turn conv message locale :grant grant)
         (if e
             (list 500 '(:content-type "application/json")
                   (list (http:json (list "error" (format nil "~A" e)))))
             (list 200 '(:content-type "application/json")
                   (list (http:json (list "reply" reply)))))))
      ;; HTMX client: run the turn in the background, and ask the page to poll now. The
      ;; user's message reaches the page through that poll, so every tab gets it the same way.
      (t
       (%run-turn-async conv message locale grant)
       (list 200 '(:content-type "text/html; charset=utf-8" :hx-trigger "px-poll")
             (list ""))))))

(defun %new-conversation (key agent agent-name responder &key built-with rebuild)
  "A conversation over AGENT, for KEY, whose transcript starts with AGENT's history. Its next turn
is numbered after the history's last. BUILT-WITH and REBUILD are set with grants: see the
CONVERSATION slots."
  (let ((conv (make-conversation :key key :agent agent :agent-name agent-name
                                 :responder responder :built-with built-with
                                 :rebuild rebuild))
        (history (%history-items agent)))
    (dolist (item history) (%publish conv item))
    (setf (conversation-turns conv)
          (count :user history :key (lambda (item) (getf item :kind))))
    conv))

(defstruct (%entry (:constructor %make-entry ()))
  "A key's place in MAKE-APP's table of conversations. LOCK is held while the key's agent is
made, so the table's own lock is not; CONVERSATION is NIL until then. USED-AT is when a request
last reached it."
  (lock (sb-thread:make-mutex :name "praxeon-web-conversation-entry"))
  (conversation nil)
  (used-at 0 :type integer))

(defun %entry-stale-p (entry now idle-seconds)
  "Whether no request has reached ENTRY for IDLE-SECONDS by NOW, and none of its turns is running."
  (and (>= (- now (%entry-used-at entry)) idle-seconds)
       (let ((conv (%entry-conversation entry)))
         (not (and conv (sb-thread:mutex-owner (conversation-turn-lock conv)))))))

(defun %expire-conversations (table now idle-seconds)
  "Remove from TABLE, MAKE-APP's table of entries by key, every stale entry (%ENTRY-STALE-P).
Caller holds the table's lock."
  (loop for key being the hash-keys of table using (hash-value entry)
        when (%entry-stale-p entry now idle-seconds)
          collect key into gone
        finally (dolist (k gone) (remhash k table))))

(defun %no-conversation ()
  (list 403 '(:content-type "text/plain; charset=utf-8")
        (list "praxeon/web: this request has no conversation.")))

(defun %unauthenticated (reason)
  (list 401 '(:content-type "application/json" :www-authenticate "Session")
        (list (http:json (list "error" reason)))))

(defun %authorization (env scheme)
  "The credential after SCHEME (\"Grant\" or \"Session\", compared without case) in ENV's
Authorization header, or NIL."
  (let* ((value (http:request-header env "authorization"))
         (space (and value (position #\Space value))))
    (when (and space (string-equal scheme (subseq value 0 space)))
      (let ((credential (string-trim " " (subseq value space))))
        (and (plusp (length credential)) credential)))))

(defun %open-session (env verifier audience sessions)
  "POST /embed/session: verify the grant in ENV's `Authorization: Grant <token>' header and
answer a session id for it, or 401 with the reason."
  (let ((token (%authorization env "Grant")))
    (if (null token)
        (%unauthenticated "send the grant as: Authorization: Grant <token>")
        (handler-case
            (let ((grant (multiple-value-bind (payload signature)
                             (ceiling:decode-grant-token token)
                           (ceiling:verify-grant verifier payload signature))))
              ;; The audience is checked here as well as by the verifier, because a verifier an
              ;; app supplies need not check it, and a grant for another service must not open
              ;; a session on this one.
              (cond ((string/= audience (ceiling:grant-audience grant))
                     (%unauthenticated (format nil "the grant is for audience ~S, not ~S"
                                               (ceiling:grant-audience grant) audience)))
                    ((zerop (length (ceiling:grant-principal grant)))
                     (%unauthenticated "the grant names no principal"))
                    (t
                     (list 200 '(:content-type "application/json" :cache-control "no-store")
                           (list (http:json
                                  (list "session" (ws:open-session sessions grant)
                                        "idle_seconds" (ws:session-table-idle-seconds sessions)
                                        "max_seconds" (ws:session-table-max-seconds sessions))))))))
          (ceiling:grant-invalid (e)
            (%unauthenticated (ceiling:grant-invalid-reason e)))))))

(defun make-app (&key agent (agent-name "Praxeon") (title "Praxeon")
                      (responder #'%default-responder) intro footer dev theme-css
                      dictionary gate conversation-key make-agent
                      grant-verifier audience (sessions (ws:make-session-table))
                      (conversation-idle-seconds 1800) (clock #'get-universal-time))
  "A Clack app exposing an agent: GET / (chat page), POST /api/message (HTMX or JSON),
GET /api/progress (live-progress poll). One agent holds one conversation, so turns
are serialized; the HTMX turn runs on a background thread so no handler blocks.
RESPONDER is how a turn is run -- (agent message locale) -> reply string -- defaulting
to the raw agent loop (LOCALE ignored); a client overrides it to wrap the turn (e.g. a
guardrail, or Elise's translator that converses in the request LOCALE).
INTRO/FOOTER (and TITLE) are either plain strings or functions of the request
locale -- (locale -> string) -- for i18n. DICTIONARY, when supplied (a
hyperion/i18n dictionary), turns on per-request locale negotiation (?lang= > cookie
> Accept-Language) + a language switcher; without it the app is single-language.

WHICH CONVERSATION A REQUEST BELONGS TO (#67). Without CONVERSATION-KEY there is one
conversation, over AGENT, shared by every request. With it, CONVERSATION-KEY is a function
of the Clack env that returns the request's key, normally the signed-in principal's id, and
MAKE-AGENT is a function of a key that returns a fresh agent for it. The first request with a
key makes that key's conversation; later requests with an EQUAL key share it. A request whose
key is NIL is answered 403. A key's conversation, and its agent, are dropped once no request
has reached them for CONVERSATION-IDLE-SECONDS (30 minutes by default, the same as a session's
idle limit) and no turn of theirs is running. The key's next request finds it stale and starts a
new one, and every request sweeps out all stale conversations if a minute (or the idle limit, if
that is shorter) has passed since the last sweep. A page still open on a dropped conversation
holds a cursor from it; its next poll replaces the page's transcript with the new conversation's
and a notice that a new conversation has started. CLOCK returns the time in seconds; a test
passes its own. Pass AGENT or
CONVERSATION-KEY with MAKE-AGENT, not both: an agent holds one conversation's history, so one
agent cannot serve several keys.

SIGNED GRANTS (#67, #90). With GRANT-VERIFIER (a `praxeon/ceiling' verifier) and AUDIENCE (the
name this service is minted for), a request is authenticated by a session:
  - POST /embed/session with `Authorization: Grant <token>' verifies the grant (see
    `praxeon/ceiling:decode-grant-token') and answers {\"session\": ID, \"idle_seconds\": N,
    \"max_seconds\": N}. The grant must be for AUDIENCE and name a principal.
  - Every other route needs `Authorization: Session <ID>', and is answered 401 without a
    session that is open in SESSIONS (a `praxeon/web-session' table).
  - The conversation is the session's principal's. MAKE-AGENT is called with the principal and
    a grant, so the agent's means can be built from the grant's capabilities. A turn runs on an
    agent made from the grant of the session that sent the message: when that grant's
    capabilities, token cap or call cap differ from those of the grant the agent was made from,
    MAKE-AGENT is called again and the conversation is moved onto the new agent
    (`praxeon/actor:move-conversation'). So a grant with fewer capabilities takes effect at the
    next turn, and the transcript goes on.
  - A grant can be exchanged for sessions any number of times until it expires: nothing records
    that a grant has been used. Keep grants short-lived for that reason.
AUDIENCE is required, because a grant minted for another service must not open a session on
this one. GRANT-VERIFIER goes with MAKE-AGENT, and not with AGENT or CONVERSATION-KEY.

GET /api/reload-epoch and GET /api/dev-error, which the hot-reload poller reads, exist only when
DEV is true, and need no session.

Returns the Clack app, and as a second value a function of no arguments that returns how many
conversations the app holds."
  (cond ((and conversation-key (not make-agent))
         (error "praxeon/web: :CONVERSATION-KEY needs :MAKE-AGENT, a function of a key that returns that conversation's agent."))
        ((and make-agent (not conversation-key) (not grant-verifier))
         (error "praxeon/web: :MAKE-AGENT is used only with :CONVERSATION-KEY or :GRANT-VERIFIER, which say which conversation a request belongs to."))
        ((and conversation-key agent)
         (error "praxeon/web: pass :AGENT or :CONVERSATION-KEY with :MAKE-AGENT, not both. An agent holds one conversation's history, so it cannot serve several keys."))
        ((and grant-verifier (not (and (stringp audience) (plusp (length audience)))))
         (error "praxeon/web: :GRANT-VERIFIER needs :AUDIENCE, the name grants for this service are minted with. Without it a grant minted for another service would open a session here."))
        ((not (typep conversation-idle-seconds '(integer 1)))
         (error "praxeon/web: :CONVERSATION-IDLE-SECONDS must be a whole number of seconds, at least 1, not ~S." conversation-idle-seconds))
        ((and grant-verifier (or agent conversation-key (not make-agent)))
         (error "praxeon/web: :GRANT-VERIFIER takes :MAKE-AGENT, a function of a principal and its grant, and not :AGENT or :CONVERSATION-KEY: the conversation is the session's principal's.")))
  ;; dev renders pretty (readable view-source); prod compacts. The style is bound around each
  ;; request below and never assigned globally (pre-publication issue 469): praxeon/web can be
  ;; started as a second server inside a host app's image, and assigning
  ;; `hyperion/output:*output-style*' there would change how the host renders. The turn thread
  ;; does not render; it publishes items, and the poll that reads them renders them here.
  (let* ((style (if dev :pretty :compact))
         (new-conversation
           (lambda (key agent) (%new-conversation key agent agent-name responder)))
         (shared (unless (or conversation-key grant-verifier) (funcall new-conversation nil agent)))
         (table (make-hash-table :test 'equal))  ; key -> %ENTRY
         (table-lock (sb-thread:make-mutex :name "praxeon-web-conversations"))
         ;; Stale entries are swept at most once in this many seconds, on whichever request
         ;; comes, so memory is reclaimed without waiting for a new key.
         (sweep-seconds (min 60 conversation-idle-seconds))
         (swept-at nil)
         (keyed
           (lambda (key make)
             ;; The table's lock is held only to find or add KEY's entry, and to sweep. MAKE,
             ;; which returns KEY's new conversation, runs under the entry's own lock, so a slow
             ;; MAKE-AGENT holds up only the requests with its key: they wait for it and then
             ;; share the conversation it made, so two first requests make one agent.
             (let ((entry (sb-thread:with-mutex (table-lock)
                            (let ((now (funcall clock)))
                              (when (or (null swept-at) (>= (- now swept-at) sweep-seconds))
                                (%expire-conversations table now conversation-idle-seconds)
                                (setf swept-at now))
                              (let ((e (gethash key table)))
                                ;; A returning key's stale entry is replaced here, whether or not
                                ;; the sweep has run since it went stale.
                                (when (or (null e) (%entry-stale-p e now conversation-idle-seconds))
                                  (setf e (setf (gethash key table) (%make-entry))))
                                ;; Set under the table's lock, so an expiry cannot remove an
                                ;; entry between this request finding it and using it.
                                (setf (%entry-used-at e) now)
                                e)))))
               (sb-thread:with-mutex ((%entry-lock entry))
                 (or (%entry-conversation entry)
                     (setf (%entry-conversation entry) (funcall make)))))))
         (conversation-count
           (lambda ()
             (if shared
                 1
                 (sb-thread:with-mutex (table-lock) (hash-table-count table)))))
         ;; CONVERSATION-FOR returns the request's conversation, or the response that refuses it,
         ;; and with grants the session's grant as a second value.
         (conversation-for
           (cond
             (grant-verifier
              (lambda (env)
                (let ((grant (ws:session-grant sessions (%authorization env "Session"))))
                  (if (null grant)
                      (%unauthenticated "send an open session as: Authorization: Session <id>")
                      (let* ((principal (ceiling:grant-principal grant))
                             (rebuild (lambda (g) (funcall make-agent principal g))))
                        (values (funcall keyed principal
                                         (lambda ()
                                           (%new-conversation principal (funcall rebuild grant)
                                                              agent-name responder
                                                              :built-with (%grant-terms grant)
                                                              :rebuild rebuild)))
                                grant))))))
             (conversation-key
              (lambda (env)
                (let ((key (funcall conversation-key env)))
                  (if (null key)
                      (%no-conversation)
                      (funcall keyed key
                               (lambda ()
                                 (funcall new-conversation key (funcall make-agent key))))))))
             (t (lambda (env) (declare (ignore env)) shared))))
         ;; The route table -- DATA, built once. `(hyperion/router:describe-routes …)`
         ;; prints what this surface answers; the `cond` this replaces could not be
         ;; enumerated by anything, including its author. The vendored assets arrive
         ;; as a MOUNT, so praxeon never names their paths.
         (routes
           (apply
            #'router:router
            (remove
             nil
             (list
              ;; The session exchange exists only on a service that takes grants.
              (when grant-verifier
                (router:route :post "/embed/session"
                              (lambda (env) (%open-session env grant-verifier audience sessions))
                              :name :embed-session))
              (assets:mount)
              (router:route :get "/"
                            (lambda (env)
                              (let ((conv (funcall conversation-for env)))
                                (if (not (conversation-p conv))
                                    conv
                                    (multiple-value-bind (locale set-cookie)
                                        (%negotiate-locale env dictionary)
                                      ;; The bubbles and the cursor come from one read of the
                                      ;; channel, so an item published while the page renders is
                                      ;; either in the page or after its cursor, never both.
                                      (multiple-value-bind (items next) (%items-since conv -1)
                                        (list 200
                                              (append '(:content-type "text/html; charset=utf-8")
                                                      (when set-cookie (list :set-cookie set-cookie)))
                                              (list (%page (%resolve-content title locale)
                                                           (%resolve-content intro locale)
                                                           (%resolve-content footer locale)
                                                           dev
                                                           (%agent-model-label (conversation-agent conv))
                                                           (%items-html conv items)
                                                           theme-css
                                                           locale
                                                           (and dictionary (i18n:supported-locales dictionary))
                                                           (and gate (if (functionp gate)
                                                                         (funcall gate locale)
                                                                         gate))
                                                           (%cursor-value conv next)))))))))
                            :name :chat)
              (router:route :get "/api/progress"
                            (lambda (env)
                              (let ((conv (funcall conversation-for env)))
                                (if (not (conversation-p conv))
                                    conv
                                    (multiple-value-bind (after epoch) (%request-cursor env)
                                      (list 200 '(:content-type "text/html; charset=utf-8")
                                            (list (%progress-fragment conv after epoch)))))))
                            :name :progress)
              ;; The dev page's poller reads these two, and only a dev app has them.
              (when dev
                (router:route :get "/api/reload-epoch"
                              (lambda (env)
                                (declare (ignore env))
                                (list 200 '(:content-type "text/plain" :cache-control "no-store")
                                      (list (princ-to-string dev:*reload-epoch*))))
                              :name :reload-epoch))
              (when dev
                (router:route :get "/api/dev-error"
                              (lambda (env)
                                (declare (ignore env))
                                (list 200 '(:content-type "text/plain" :cache-control "no-store")
                                      (list (or (dev:dev-error) ""))))
                              :name :dev-error))
              (router:route :post "/api/message"
                            (lambda (env)
                              (multiple-value-bind (conv grant) (funcall conversation-for env)
                                (if (not (conversation-p conv))
                                    conv
                                    (%handle-message env conv dictionary grant))))
                          :name :message))))))
    (values
     (lambda (env)
       ;; Render every response within the app's output style: dev = pretty HTML+JS
       ;; for readable "view source"; prod = compact/minified. Binds the Spinneret
       ;; and Parenscript formatting vars for the whole request (see hyperion/output).
       (out:with-output-style (style)
         (router:dispatch routes env)))
     conversation-count)))

;;; --------------------------------------------------------------------------
;;; Lifecycle
;;; --------------------------------------------------------------------------
(defun %build-app (agent agent-name title responder intro footer dev theme-css
                   dictionary gate conversation-key make-agent
                   grant-verifier audience sessions conversation-idle-seconds)
  "The app START and SERVE-FOREVER serve: MAKE-APP, called with the arguments they share.

BOTH ENTRY POINTS GO THROUGH HERE. START and SERVE-FOREVER differ in how they BLOCK, not
in what they serve, and the argument list that defines the surface is long enough that two
copies of it would drift -- silently, and in whichever copy nobody drives interactively.

Positional rather than keyword on purpose: the only callers are the two entry points below,
both of which must pass all of it, so keywords here would buy nothing but the chance to
forget one."
  (make-app :agent agent :agent-name agent-name :title title
            :responder responder :intro intro :footer footer
            :dev dev :theme-css theme-css :dictionary dictionary :gate gate
            :conversation-key conversation-key :make-agent make-agent
            :grant-verifier grant-verifier :audience audience
            :sessions (or sessions (ws:make-session-table))
            :conversation-idle-seconds (or conversation-idle-seconds 1800)))

(defun start (&key agent (agent-name "Praxeon") (title "Praxeon")
                   (responder #'actor:run-turn) intro footer dev theme-css
                   dictionary gate conversation-key make-agent
                   grant-verifier audience sessions conversation-idle-seconds
                   (server (default-server)) (port *default-port*)
                   (host "127.0.0.1") debug)
  "Start a web server exposing AGENT and return a handler; stop it with STOP.
Builds the agent/chat Clack app and hands it to hyperion/server:start. SERVER is
the Clack backend (DEFAULT-SERVER, re-exported from Hyperion). RESPONDER, INTRO,
FOOTER, THEME-CSS, DICTIONARY, CONVERSATION-KEY, MAKE-AGENT, GRANT-VERIFIER, AUDIENCE,
SESSIONS, CONVERSATION-IDLE-SECONDS and DEV pass through to MAKE-APP -- DICTIONARY turns
on per-request locale negotiation (title/intro/footer may be locale functions); DEV
t embeds the hot-reload poller so the page auto-refreshes on (MARK-RELOADED).

RETURNS IMMEDIATELY, which is what makes it the REPL entry. A binary's `main' wants
SERVE-FOREVER instead."
  (srv:start (%build-app agent agent-name title responder intro footer dev theme-css
                         dictionary gate conversation-key make-agent
                         grant-verifier audience sessions conversation-idle-seconds)
             :server server :port port :host host :debug debug))

(defun serve-forever (&key agent (agent-name "Praxeon") (title "Praxeon")
                           (responder #'actor:run-turn) intro footer dev theme-css
                           dictionary gate conversation-key make-agent
                           grant-verifier audience sessions conversation-idle-seconds
                           (server (default-server)) (port *default-port*)
                           (host "127.0.0.1") debug (log t)
                           (name agent-name) (banner :derive) (signals t) on-ready)
  "Start a web server exposing AGENT and BLOCK until interrupted. Returns NIL.

The blocking counterpart to START, and what a binary's `main' should call. Everything that
makes a foreground server behave -- the banner, Ctrl-C, the shutdown hooks, restoring the
previous signal handlers -- belongs to `hyperion/server:serve-forever' and is simply
delegated to. NAME titles the derived banner and defaults to AGENT-NAME, since that is the
name the app already answers to.

WHY IT LIVES HERE RATHER THAN IN EACH APP (pre-publication issue 151). A praxeon app that wants to block used to
have to reach past praxeon/web into hyperion/server, build the Clack app itself with
MAKE-APP, and then remember the output-style knob -- which START set at the time, and which
therefore was not part of the app but part of the entry point. That is three things to get right in
order to do the ordinary thing.

Elise did not reach past it. It hand-rolled `(loop (sleep 3600))' guarded by an
interactive-interrupt handler, which answers Ctrl-C and nothing else: no shutdown hooks, no
restored handlers, and a supervisor's stop signal could only be answered by killing the
process. The gap was one layer above where it showed, which is the argument for closing it
here rather than porting the symptom."
  (srv:serve-forever (%build-app agent agent-name title responder intro footer dev
                                 theme-css dictionary gate conversation-key make-agent
                                 grant-verifier audience sessions conversation-idle-seconds)
                     :server server :port port :host host :debug debug :log log
                     :name name :banner banner :signals signals :on-ready on-ready))

;;; STOP is re-exported straight from hyperion/server (see :import-from above).

;;; --------------------------------------------------------------------------
;;; Hot-reload dev loop -- now hyperion/dev ("Figwheel for CL"). The whole
;;; watcher (snapshot/recompile/restart-around-persistent-state + the compile-
;;; error overlay) lives in Hyperion; UNWATCH / RELOAD! / MARK-RELOADED are
;;; re-exported straight from there (see the package :import-from). WATCH stays a
;;; thin wrapper only to preserve Praxeon's historical convenience of defaulting
;;; to Praxeon's src/.
;;; --------------------------------------------------------------------------
(defun watch (builder &key paths systems (interval 0.5))
  "Start a hot-reload dev server (see hyperion/dev:watch). BUILDER is a thunk
returning a fresh Clack handler, reusing a *persistent* agent so the conversation
survives reloads. PATHS default to Praxeon's src/; SYSTEMS lists extra ASDF systems
whose src/ to also watch (e.g. '(\"hyperion\") to co-develop the framework).
Returns the dev handle; stop with UNWATCH."
  (dev:watch builder :paths paths
                     :system (unless (or paths systems) "praxeon")
                     :systems systems
                     :interval interval))
