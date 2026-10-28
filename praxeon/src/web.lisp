;;;; web.lisp --- a Clack-based web + REST surface for Praxeon agents.
;;;;
;;;; Any Praxeon client app can serve an agent over HTTP with one call:
;;;;   - GET  /            an HTMX + Bulma chat page (server renders HTML
;;;;                       fragments; HTMX swaps them -- no SPA, no compile-to-JS)
;;;;   - POST /api/message send a message. HTMX gets the user's bubble back
;;;;                       immediately and the turn runs on a background thread;
;;;;                       a JSON client (Accept: application/json) blocks for a
;;;;                       synchronous {"reply": ...}.
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
  ;; HOW THIS APP RENDERS, carried rather than read from a global (pre-publication issue 469). The style is a
  ;; property of an app, not of the image: praxeon/web can be started as a SECOND server
  ;; inside a host app's image, and assigning `hyperion/output:*output-style*' there would
  ;; change how the host renders for the rest of the process.
  ;;
  ;; The turn thread no longer renders: it publishes items, and the request that reads them
  ;; renders them inside MAKE-APP's WITH-OUTPUT-STYLE (#67). Before that, `%assistant-bubble'
  ;; ran on the turn thread, which a binding made at the request boundary does not reach.
  (output-style :compact))

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
;;;   (:kind :user :text TEXT)                          a message from the viewer
;;;   (:kind :assistant :text TEXT)                     the reply, as shown
;;;   (:kind :turn-ended :outcome :ok)                  the turn finished
;;;   (:kind :turn-ended :outcome :error :message TEXT) the turn signalled an error
;;;
;;; Every turn ends with exactly one :TURN-ENDED item, so a reader can tell that a
;;; turn is over without inferring it from the status line.
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
                                           locale locales gate (cursor 0))
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
these, so an agent that arrives with a history shows it."
  (when agent
    (loop for m in (actor:agent-history agent)
          for role = (llm:role m)
          for content = (llm:content m)
          ;; a real user turn is a plain string; tool-result messages are parts lists
          append (cond ((and (string= role "user") (stringp content))
                        (list (list :kind :user :text content)))
                       ((string= role "assistant")
                        (let ((text (%text-of content)))
                          (when (plusp (length text))
                            (list (list :kind :assistant :text text)))))))))

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

(defun %cursor-input (index &optional oob)
  "The hidden field the poll sends as `after': the index of the first transcript item this page
has not shown. A poll response replaces it out of band (OOB true) with the index past what it
returned."
  (spinneret:with-html-string
    (:input :type "hidden" :id "px-cursor" :name "after" :value (princ-to-string index)
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

(defun %turn (conv message locale &key published)
  "Run one turn of CONV on this thread, after publishing MESSAGE unless PUBLISHED says the
caller already did, and publish how it went: the reply as shown and then a :TURN-ENDED item.
Returns (values REPLY NIL), or (values NIL ERROR)
when the responder signalled ERROR. Turns are serialized by CONV's turn lock; the progress
observer records the status and token count while the turn runs."
  (unless published (%publish conv (list :kind :user :text message)))
  (unwind-protect
       (handler-case
           (let ((reply (sb-thread:with-mutex ((conversation-turn-lock conv))
                          (evt:with-observer ((%progress-observer conv))
                            (funcall (conversation-responder conv)
                                     (conversation-agent conv) message locale)))))
             (%publish conv (list :kind :assistant :text (%shown-reply reply)))
             (%publish conv (list :kind :turn-ended :outcome :ok))
             (values reply nil))
         (error (e)
           (%publish conv (list :kind :turn-ended :outcome :error
                                :message (princ-to-string e)))
           (values nil e)))
    (%set-status conv "")))

(defun %run-turn-async (conv message locale)
  "Run one turn on a background thread so the web server's event loop stays free
(critical on Woo). See %TURN. LOCALE is the resolved request locale, handed to the
responder (e.g. for Elise's translator)."
  ;; The user's message is published here, on the request thread, and not by the turn
  ;; thread, so the poll that HX-Trigger asks for finds it even if the thread has not run yet.
  (%publish conv (list :kind :user :text message))
  ;; THREAD-LIFETIME: continues -- this thread runs ONE turn of the request that spawned it,
  ;; so it carries the caller's dynamic context (#158). Without the wrapper every line the
  ;; turn logs -- including the LLM request and response lines -- is missing the request-id
  ;; that hyperion/logging bound around the request, because a LET binding does not cross a
  ;; thread. The field is simply absent and nothing reports it.
  (sb-thread:make-thread
   (aion/dynamic:inheriting
    (lambda ()
      (aion/dynamic:unblock-interrupts)
      (%turn conv message locale :published t)
      nil))
   :name "praxeon-web-turn"))

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
  "The `after' index the poll sent, or NIL when it sent none or one that is not a non-negative
integer."
  (let* ((raw (http:query-param env "after"))
         (n (and raw (ignore-errors (parse-integer raw)))))
    (and (integerp n) (>= n 0) n)))

(defun %progress-fragment (conv after)
  "The poll response: the transcript items from AFTER on, appended to #chat; the cursor moved
past them; and the status line and token count, out of band. With no AFTER, which is what a page
loaded before the cursor existed sends, no items are returned and the cursor is moved to the
newest item, so that page carries on from there instead of repeating the transcript."
  (multiple-value-bind (items next)
      (if after
          (%items-since conv after)
          (values nil (chan:channel-length (conversation-events conv))))
    (with-output-to-string (s)
      (write-string (%items-html conv items) s)
      (write-string (%cursor-input next t) s)
      (write-string (%status-oob (%get-status conv)) s)
      (write-string (%tokens-oob (%get-turn-tokens conv) (%get-tokens conv)) s))))

(defun %handle-message (env conv dictionary)
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
       (multiple-value-bind (reply e) (%turn conv message locale)
         (if e
             (list 500 '(:content-type "application/json")
                   (list (http:json (list "error" (format nil "~A" e)))))
             (list 200 '(:content-type "application/json")
                   (list (http:json (list "reply" reply)))))))
      ;; HTMX client: run the turn in the background, and ask the page to poll now. The
      ;; user's message reaches the page through that poll, so every tab gets it the same way.
      (t
       (%run-turn-async conv message locale)
       (list 200 '(:content-type "text/html; charset=utf-8" :hx-trigger "px-poll")
             (list ""))))))

(defun %no-conversation ()
  (list 403 '(:content-type "text/plain; charset=utf-8")
        (list "praxeon/web: this request has no conversation.")))

(defun make-app (&key agent (agent-name "Praxeon") (title "Praxeon")
                      (responder #'%default-responder) intro footer dev theme-css
                      dictionary gate conversation-key make-agent)
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
key is NIL is answered 403. Conversations are kept for the app's lifetime. Pass AGENT or
CONVERSATION-KEY with MAKE-AGENT, not both: an agent holds one conversation's history, so one
agent cannot serve several keys."
  (cond ((and conversation-key (not make-agent))
         (error "praxeon/web: :CONVERSATION-KEY needs :MAKE-AGENT, a function of a key that returns that conversation's agent."))
        ((and make-agent (not conversation-key))
         (error "praxeon/web: :MAKE-AGENT is used only with :CONVERSATION-KEY, which says which conversation a request belongs to."))
        ((and conversation-key agent)
         (error "praxeon/web: pass :AGENT or :CONVERSATION-KEY with :MAKE-AGENT, not both. An agent holds one conversation's history, so it cannot serve several keys.")))
  (let* ((style (if dev :pretty :compact))  ; dev renders pretty (readable view-source); prod compacts
         (new-conversation
           (lambda (key agent)
             (let ((conv (make-conversation :key key :agent agent :agent-name agent-name
                                            :responder responder :output-style style)))
               (dolist (item (%history-items agent)) (%publish conv item))
               conv)))
         (shared (unless conversation-key (funcall new-conversation nil agent)))
         (table (make-hash-table :test 'equal))
         (table-lock (sb-thread:make-mutex :name "praxeon-web-conversations"))
         (conversation-for
           (if conversation-key
               (lambda (env)
                 (let ((key (funcall conversation-key env)))
                   (when key
                     ;; MAKE-AGENT runs under the lock, so two first requests with one key
                     ;; make one conversation, not two with one of them lost.
                     (sb-thread:with-mutex (table-lock)
                       (or (gethash key table)
                           (setf (gethash key table)
                                 (funcall new-conversation key (funcall make-agent key))))))))
               (lambda (env) (declare (ignore env)) shared)))
         ;; The route table -- DATA, built once. `(hyperion/router:describe-routes …)`
         ;; prints what this surface answers; the `cond` this replaces could not be
         ;; enumerated by anything, including its author. The vendored assets arrive
         ;; as a MOUNT, so praxeon never names their paths.
         (routes
           (router:router
            (assets:mount)
            (router:route :get "/"
                          (lambda (env)
                            (let ((conv (funcall conversation-for env)))
                              (if (null conv)
                                  (%no-conversation)
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
                                                         next))))))))
                          :name :chat)
            (router:route :get "/api/progress"
                          (lambda (env)
                            (let ((conv (funcall conversation-for env)))
                              (if (null conv)
                                  (%no-conversation)
                                  (list 200 '(:content-type "text/html; charset=utf-8")
                                        (list (%progress-fragment conv (%request-cursor env)))))))
                          :name :progress)
            (router:route :get "/api/reload-epoch"
                          (lambda (env)
                            (declare (ignore env))
                            (list 200 '(:content-type "text/plain" :cache-control "no-store")
                                  (list (princ-to-string dev:*reload-epoch*))))
                          :name :reload-epoch)
            (router:route :get "/api/dev-error"
                          (lambda (env)
                            (declare (ignore env))
                            (list 200 '(:content-type "text/plain" :cache-control "no-store")
                                  (list (or (dev:dev-error) ""))))
                          :name :dev-error)
            (router:route :post "/api/message"
                          (lambda (env)
                            (let ((conv (funcall conversation-for env)))
                              (if (null conv)
                                  (%no-conversation)
                                  (%handle-message env conv dictionary))))
                          :name :message))))
    (lambda (env)
      ;; Render every response within the app's output style: dev = pretty HTML+JS
      ;; for readable "view source"; prod = compact/minified. Binds the Spinneret
      ;; and Parenscript formatting vars for the whole request (see hyperion/output).
      (out:with-output-style (style)
        (router:dispatch routes env)))))

;;; --------------------------------------------------------------------------
;;; Lifecycle
;;; --------------------------------------------------------------------------
(defun %build-app (agent agent-name title responder intro footer dev theme-css
                   dictionary gate conversation-key make-agent)
  "MAKE-APP, plus the output-style knob that goes with choosing an entry point.

BOTH ENTRY POINTS GO THROUGH HERE. START and SERVE-FOREVER differ in how they BLOCK, not
in what they serve, and the argument list that defines the surface is long enough that two
copies of it would drift -- silently, and in whichever copy nobody drives interactively.

Positional rather than keyword on purpose: the only callers are the two entry points below,
both of which must pass all of it, so keywords here would buy nothing but the chance to
forget one."
  ;; NO GLOBAL ASSIGNMENT (pre-publication issue 469). The style travels on the conversation MAKE-APP builds, so
  ;; starting this surface as a second server inside a host image leaves the host's rendering
  ;; alone. `dev' still decides it; it is simply carried rather than published.
  (make-app :agent agent :agent-name agent-name :title title
            :responder responder :intro intro :footer footer
            :dev dev :theme-css theme-css :dictionary dictionary :gate gate
            :conversation-key conversation-key :make-agent make-agent))

(defun start (&key agent (agent-name "Praxeon") (title "Praxeon")
                   (responder #'actor:run-turn) intro footer dev theme-css
                   dictionary gate conversation-key make-agent
                   (server (default-server)) (port *default-port*)
                   (host "127.0.0.1") debug)
  "Start a web server exposing AGENT and return a handler; stop it with STOP.
Builds the agent/chat Clack app and hands it to hyperion/server:start. SERVER is
the Clack backend (DEFAULT-SERVER, re-exported from Hyperion). RESPONDER, INTRO,
FOOTER, THEME-CSS, DICTIONARY, CONVERSATION-KEY, MAKE-AGENT and DEV pass through to MAKE-APP -- DICTIONARY turns
on per-request locale negotiation (title/intro/footer may be locale functions); DEV
t embeds the hot-reload poller so the page auto-refreshes on (MARK-RELOADED).

RETURNS IMMEDIATELY, which is what makes it the REPL entry. A binary's `main' wants
SERVE-FOREVER instead."
  (srv:start (%build-app agent agent-name title responder intro footer dev theme-css
                         dictionary gate conversation-key make-agent)
             :server server :port port :host host :debug debug))

(defun serve-forever (&key agent (agent-name "Praxeon") (title "Praxeon")
                           (responder #'actor:run-turn) intro footer dev theme-css
                           dictionary gate conversation-key make-agent
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
MAKE-APP, and then remember the output-style knob -- which START sets, and which therefore
is not part of the app but part of the entry point. That is three things to get right in
order to do the ordinary thing.

Elise did not reach past it. It hand-rolled `(loop (sleep 3600))' guarded by an
interactive-interrupt handler, which answers Ctrl-C and nothing else: no shutdown hooks, no
restored handlers, and a supervisor's stop signal could only be answered by killing the
process. The gap was one layer above where it showed, which is the argument for closing it
here rather than porting the symptom."
  (srv:serve-forever (%build-app agent agent-name title responder intro footer dev
                                 theme-css dictionary gate conversation-key make-agent)
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
