;;;; packages.lisp --- Hyperion package definitions.
;;;;
;;;; Package-per-module; use :local-nicknames rather than long prefixes. As the
;;;; framework grows, expect packages like:
;;;;   hyperion/output   -- one knob for rendered HTML+JS formatting (pretty/compact)
;;;;   hyperion/htmx     -- typed HTMX vocabulary (Coalton): Swap/Trigger/Verb/...
;;;;   hyperion/html     -- rendering the typed vocabulary (CL + Spinneret); OOB
;;;;   hyperion/server   -- the configurable Clack server (Woo/Hunchentoot)
;;;;   hyperion/http     -- raw-Clack request/response utilities
;;;;   hyperion/js       -- Parenscript helpers (CL -> JS, no Node)
;;;;   hyperion/dev      -- the hot-reload watcher (the Figwheel engine)
;;;;   hyperion/css      -- the CSS DSL
;;;; Much of this is extracted from praxeon/src/web.lisp.

(cl:defpackage #:hyperion/output
  (:use #:cl)
  (:local-nicknames (#:ps #:parenscript)
                    (#:spin #:spinneret))
  (:documentation
   "The single place to configure how rendered output is formatted. Spinneret
    (HTML) and Parenscript (JS) both drive formatting off dynamic variables;
    this module funnels all of them through one style knob so a call site -- or
    the whole app -- chooses pretty vs compact once and both renderers agree.")
  (:export #:output-style
           #:*output-style*
           #:*pretty-indent*
           #:*fill-column*
           #:prettyp
           #:with-output-style
           #:html-string
           #:js-string))

;;; --- Typed HTMX vocabulary (Coalton core) -------------------------------
;;; Coalton owns the checked value; a bad combo can't be spelled. IO-free.
(cl:defpackage #:hyperion/htmx
  (:use #:coalton #:coalton-prelude)
  (:documentation
   "The typed HTMX vocabulary, in Coalton: Swap, Verb, Trigger, Target, and a
    real Duration so \"700ms\" is unspellable-wrong. Pure -- renders each value
    to its attribute string; no IO. The CL/Spinneret side (hyperion/html)
    consumes these renderers at the boundary.")
  (:export #:Duration #:Millis #:Seconds #:duration->string
           #:Swap #:InnerHTML #:OuterHTML #:BeforeBegin #:AfterBegin
           #:BeforeEnd #:AfterEnd #:DeleteSwap #:NoSwap #:swap->string
           #:Verb #:Get #:Post #:Put #:Patch #:Delete #:verb->attr #:verb->method
           #:Trigger #:OnEvent #:Every #:Load #:Revealed #:trigger->string
           #:Target #:CssTarget #:ThisElement #:target->string
           ;; CL-callable scalar render helpers (take CL fixnums, return strings)
           #:render-millis #:render-seconds
           #:render-every-millis #:render-every-seconds))

;;; --- Typed interceptor pipeline: MOVED to `aion/interceptor` (pre-publication issue 177) ------
;;; Pedestal's idea (middleware as data in the request->response cycle) made a
;;; compile-time-checked value, parametric over the context type. It lives in aion now
;;; because the shape is request-response rather than web: hyperion uses it inbound,
;;; hermes hand-rolls the outbound form in CL, and praxeon needs it for agent turns --
;;; three positions in the DAG, one of them a web layer. See docs/interceptors-design.md.

;;; --- Path templates + matching (Coalton core) ---------------------------
;;; The half of routing that is logic: parse "/contacts/:id" into a checked value and
;;; match a request path against it, yielding bindings. No IO, no handlers, no Clack.
(cl:defpackage #:hyperion/path
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:str #:coalton/string))
  (:documentation
   "Path templates as checked values: a Segment is a Literal, a Param (`:id`) or
    Rest (`*`); a Pattern is their ordered list. PARSE-PATTERN builds one,
    PATH-MATCHES? and PATH-BINDINGS match a request path against it. The CL-facing
    surface traffics only in PROMISED representations (Boolean, List String) so a
    caller never destructures a Coalton ADT -- bindings come back as a flat
    name/value list, not a list of Tuples. Pure; hyperion/router is its CL shell.")
  (:export #:Segment #:Literal #:Param #:Rest
           #:Pattern #:pattern-segments
           #:parse-pattern #:pattern-params #:pattern-valid?
           #:path-matches? #:path-bindings #:normalize-path))

;;; --- Rendering the typed vocabulary (CL shell) --------------------------
(cl:defpackage #:hyperion/html
  (:use #:cl)
  (:local-nicknames (#:htmx #:hyperion/htmx)
                    (#:out  #:hyperion/output))
  (:documentation
   "The CL/Spinneret side of HTMX rendering: thin accessors that call the typed
    Coalton renderers (hyperion/htmx) from CL, plus a generic OOB combinator.
    Seed of \"CLOS + Spinneret own rendering; runtime-open.\"")
  (:export #:swap-string #:verb-attr #:trigger-string #:target-string
           #:millis #:seconds #:oob
           ;; Spinneret attribute-validation exemptions (hx-/x-/@/_ ...)
           #:*client-attribute-prefixes* #:allow-attribute-prefix))

;;; --- The configurable Clack server backend ------------------------------
(cl:defpackage #:hyperion/server
  (:use #:cl)
  (:documentation
   "The web-server backend behind a neutral protocol. Hyperion declares NO backend
    (pre-publication issue 139): the application depends on the one it wants, and DEFAULT-SERVER picks from
    what the image actually loaded -- by PACKAGE presence, which is what lets the native
    server (hyperion/server-uv, pre-publication issue 117) be offered without core depending on libuv.
    HYPERION_SERVER overrides. START takes an already-built Ring app so app construction
    stays with the caller, and STOP takes whichever handler START returned.")
  (:export #:default-server #:available-servers #:no-server-backend
           #:native-backend-p
           #:*default-port* #:start #:stop
           ;; the blocking, production entry point (pre-publication issue 124) + its interrupt seam
           #:serve-forever #:request-shutdown #:request-shutdown-from-signal
           ;; pre-publication issue 238: the preflight, and the condition a caller may handle.
           #:port-answering-p #:port-in-use #:port-in-use-host #:port-in-use-port
           #:port-in-use-cause #:server-start-timeout #:server-start-timeout-host
           #:server-start-timeout-port #:server-start-timeout-seconds #:*start-timeout*
           #:server-session #:server-session-p #:server-session-handler
           #:*shutdown-poll-interval*
           #:*install-signal-handlers* #:*shutdown-hooks*
           ;; Exported so an app that clacks up its own handler can apply it too --
           ;; without it, every response on a keep-alive connection stalls ~44 ms (ADR-0011).
           #:wrap-content-length #:wrap-streaming-body #:utf-8-length))

;;; --- Raw-Clack request/response utilities -------------------------------
(cl:defpackage #:hyperion/http
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:documentation
   "Small utilities over the raw Clack env: read/decode the body, pull a form or
    query param, read a request header or cookie, negotiate JSON, and
    encode/decode JSON. Domain-neutral -- the caller supplies its own keys.")
  (:export #:body-string #:form-alist #:form-param #:form-params
           ;; a body is a stream and is read once; a middleware that must look
           ;; inside it caches the result here rather than spending it (pre-publication issue 280)
           #:+body-string-key+ #:cache-body-string
           ;; and the same one level up, for a multipart body (pre-publication issue 280)
           #:+multipart-parts-key+ #:cache-multipart-parts
           #:query-param #:query-params #:request-header #:cookie
           ;; multipart/form-data (pre-publication issue 143): ceilings on by default, content streamed
           #:multipart-p #:parse-multipart #:delete-parts #:sanitize-filename
           #:part #:part-p #:part-name #:part-filename #:part-safe-filename
           #:part-content-type #:part-headers #:part-bytes #:part-path #:part-size
           #:part-file-p #:part-text
           #:find-part #:find-parts #:multipart-param
           #:body-too-large #:body-too-large-limit #:body-too-large-claimed
           #:multipart-error #:multipart-too-large #:multipart-too-many-parts
           #:multipart-error-detail #:multipart-error-limit
           #:*max-body-size* #:*max-parts* #:*memory-threshold*
           #:wants-json #:json-object #:json))

;;; --- Routing: the CL shell over the typed path core ---------------------
(cl:defpackage #:hyperion/router
  (:use #:cl)
  (:local-nicknames (#:path #:hyperion/path)
                    (#:htmx #:hyperion/htmx))
  (:documentation
   "URL dispatch: an ORDERED, INTROSPECTABLE route table over hyperion/path's typed
    patterns. ROUTE declares one (method + template + handler), ROUTER collects them,
    MOUNT nests a sub-router under a prefix, and TO-APP turns the table into a Clack
    app. First match wins.

    Because matching asks the path and the method separately, 405 falls out of the
    structure rather than app-side care: a path that matched under other methods
    answers 405 with a computed `Allow:`, and only a path no route claims is a 404.
    HEAD is answered by the GET route with the body dropped, and OPTIONS is answered
    from the same Allow set -- neither is declarable, both are derived, so they cannot
    drift from the routes they describe.

    Handlers keep the plain Clack (env -> response) shape; bindings ride the env, so
    an existing handler needs no change to be routed. PATH-PARAM reads one.")
  (:export #:route #:router #:mount #:routes #:route-p #:mount-p
           #:route-method #:route-template #:route-params #:route-handler #:route-name
           #:mount-prefix #:mount-router
           #:dispatch #:to-app #:describe-routes
           #:path-param #:path-params #:+params-key+
           #:route-error #:route-error-message
           #:*not-found* #:*method-not-allowed*))

;;; --- HTTP sessions ------------------------------------------------------
(cl:defpackage #:hyperion/session
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads)
                    (#:rnd #:aion/random)          ; session ids are a bearer credential (pre-publication issue 95)
                    (#:http #:hyperion/http))
  (:documentation
   "Cookie-based HTTP sessions: a session is an id + a thread-safe key/value bag
    (opaque to Hyperion -- the app stores whatever, e.g. which agent/conversation
    this browser is attached to). Backends live behind a small STORE protocol
    (in-memory now; a mnemosyne-backed store later). ENSURE-SESSION is the request
    seam: resolve the browser's session from its cookie, minting one (+ a Set-Cookie)
    when absent -- and WRAP-SESSION is the middleware that owns that cookie so an
    application cannot drop it. ROTATE-SESSION changes a session's id at a privilege
    boundary; RESET-SESSION deliberately does not, and says so. Generic web infra --
    what a consuming app needs for auth, and what lets many browsers attach to one
    agent/conversation session (praxeon). App-neutral.")
  (:export #:session #:session-p #:session-id #:session-created #:session-accessed
           #:session-get #:session-set #:session-del #:session-keys #:reset-session
           #:restore-session #:session-alist
           #:store-ref #:store-add #:store-del #:store-count #:store-list
           #:memory-store #:make-memory-store
           #:ensure-session #:rotate-session #:new-id #:set-cookie-header
           ;; the privilege change, rotation included by construction (#120)
           #:sign-in! #:*privilege-scoped-keys*
           #:*cookie-name* #:*cookie-max-age* #:*id-bits*
           ;; the middleware that owns the cookie, so a handler cannot drop it (pre-publication issue 207)
           #:wrap-session #:request-session #:+session-key+
           #:session-cookie-not-attachable #:session-cookie-not-attachable-response
           ;; dev/REPL session management
           #:sessions #:session-summary #:describe-sessions
           #:kill-session #:kill-sessions))

(cl:defpackage #:hyperion/csrf
  (:use #:cl)
  (:local-nicknames (#:session #:hyperion/session)
                    (#:http #:hyperion/http)
                    (#:rnd #:aion/random)          ; a CSRF token is a bearer credential too
                    (#:log #:aion/log)
                    (#:spin #:spinneret))    ; the injector is a deftag on :form
  (:documentation
   "Cross-site request forgery: the refusal. A token in the session, compared against
    one the request carries -- ONE mechanism pre- and post-authentication alike, which
    is what keeps the sign-in page, where a mistake is worst, on the same code path as
    everything else (ADR-0019).

    WRAP-CSRF refuses a state-changing request before routing, so no handler can bypass
    it and none needs to know it exists. It goes INSIDE WRAP-SESSION, whose session it
    reads. The other half -- putting a token into every rendered form -- is a Spinneret
    deftag and lands separately; this half is what makes that half's known holes
    survivable, because a form that missed injection is refused loudly rather than
    served unprotected in silence.

    CHECK is exported separately from WRAP-CSRF so the refusal can be exercised by a
    request built by hand, with no injector in the image.")
  (:export
   ;; vocabulary
   #:*field-name* #:*header-name* #:*token-bits* #:*safe-methods* #:+token-key+
   ;; the token
   #:token #:ensure-token #:rotate-token
   ;; comparison
   #:constant-time-string=
   ;; request side
   #:request-token #:safe-method-p #:with-cached-body
   ;; the refusal
   #:check #:wrap-csrf #:forbidden
   ;; the injector (ADR-0019): a deftag on :form, plus the seam it reads
   #:*token-thunk* #:current-token #:token-field
   #:csrf-failure #:csrf-failure-reason #:csrf-failure-method #:csrf-failure-path))

;;; --- Request logging + correlation --------------------------------------
;;; Clack middleware binding a request id into aion/log's ambient context, so a single
;;; request's events -- here, in mnemosyne, in praxeon, in the app -- share one field.
(cl:defpackage #:hyperion/logging
  (:use #:cl)
  (:local-nicknames (#:log #:aion/log)
                    (#:rnd #:aion/random)          ; not a credential; see NEW-REQUEST-ID (pre-publication issue 95)
                    (#:bt  #:bordeaux-threads))
  (:documentation
   "Request logging: WRAP is Clack middleware that assigns (or adopts, from an upstream
    X-Request-Id) a request id, binds it into the aion/log context so every framework's
    events correlate, echoes it back on the response, and logs arrival, outcome, status
    and latency. Errors are logged with a backtrace and re-signalled, never swallowed.")
  (:export #:wrap #:request-id #:new-request-id #:*request-id*
           #:*request-id-header* #:*echo-request-id* #:*id-bits*
           ;; quiet paths: machine traffic on a timer (dev poller, health checks)
           #:*quiet-paths* #:register-quiet-path #:quiet-path-p))

;;; --- Broadcast channel (fan-out to many readers) ------------------------
(cl:defpackage #:hyperion/channel
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:documentation
   "A broadcast channel: an append-only log many independent readers consume by
    cursor, NON-destructively -- so N subscribers each see every item (no
    'stealing', unlike a shared queue drained once). PUBLISH appends; SINCE returns
    items after a given index (stateless -- for HTTP pollers carrying their own
    index); SUBSCRIBE returns a stateful CURSOR (in-process readers) that POLL
    advances. The fan-out substrate for live updates -- e.g. many browsers on one
    praxeon conversation each receiving every bubble.

    THE WINDOW IS BOUNDED and chosen at construction (pre-publication issue 231): MAKE-CHANNEL retains
    *DEFAULT-CAPACITY* items unless told otherwise, and `:capacity nil' asks for the
    unbounded log deliberately rather than by default. A reader whose index has been
    evicted gets CURSOR-BEHIND-WINDOW and a RESYNC restart -- never a silent gap, which
    in an every-message-in-order primitive would be the worst possible failure.")
  (:export #:channel #:channel-p #:make-channel #:publish #:channel-length #:since
           #:cursor #:cursor-p #:subscribe #:poll #:cursor-at #:reset-cursor
           ;; the window, and what happens when a reader falls out of it (pre-publication issue 231)
           #:*default-capacity* #:channel-earliest #:channel-window #:channel-retained
           #:cursor-behind-window #:cursor-behind-window-requested
           #:cursor-behind-window-earliest #:cursor-behind-window-channel
           ;; the restart is API: a caller cannot INVOKE-RESTART a symbol it cannot name
           #:resync))

;;; --- Coalescing feed (latest value per key, at a subscriber's rate) -----
(cl:defpackage #:hyperion/feed
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:documentation
   "The latest value per key, delivered no more often than a subscriber asked for --
    the back-pressure primitive for server->client streams (ADR-0016). PUBLISH sets a
    key's current value, replacing any previous one; SUBSCRIBE takes a required :HZ;
    TAKE returns the coalesced change set, or says the rate refused it. A slow consumer
    gets FEWER UPDATES, never a backlog, and memory is the number of distinct KEYS
    rather than the publish rate.

    Not HYPERION/CHANNEL, which is the append-only log where every reader must see
    EVERY item. Prices, progress and presence want this; a transcript wants that.")
  (:export #:feed #:feed-p #:make-feed #:publish
           #:feed-ref #:feed-count #:feed-alist #:feed-version-now
           #:subscription #:subscription-p #:subscribe #:take
           #:subscription-hz #:rate-required
           #:*clock-ms*))

;;; --- Server-Sent Events, over a feed (ADR-0016, pre-publication issue 117 M2) -----------------

(cl:defpackage #:hyperion/sse
  (:use #:cl)
  (:local-nicknames (#:feed #:hyperion/feed))
  (:documentation
   "Server-Sent Events over a hyperion/feed subscription.

    ENCODE-EVENT is the wire format as a pure function -- testable without a socket, which
    matters because the format's one unforgiving rule is a terminating BLANK LINE whose
    absence makes a correct-looking endpoint fire nothing at all.

    SSE-RESPONSE is the whole answer: an ordinary (status headers body) three-list whose
    body is a streaming function, so it runs on the native server and, through
    WRAP-STREAMING-BODY, on the Clack backends.

    THE BACK-PRESSURE POLICY LIVES IN THE FEED, not here. A slow consumer gets fewer
    updates and never a backlog, because the feed coalesces per key and the subscription
    owns the rate. This module adds no queue of its own -- one here would undo ADR-0016
    one layer above where it was decided.")
  (:export #:encode-event #:comment #:events #:sse-response
           #:sse-field-unsafe #:sse-field-unsafe-field #:sse-field-unsafe-value
           #:*headers* #:*keep-alive-seconds* #:*idle-poll-ms*))

;;; --- Internationalization (i18n) ----------------------------------------
(cl:defpackage #:hyperion/plural
  (:use #:cl)
  (:documentation
   "CLDR plural categories. The RULES are generated for all 224 locales into
    vendor/cldr-plurals.lisp and pinned by CLDR version + sha256 (PLURALS.pin); what lives
    here is the OPERAND MODEL (n i v w f t c) every rule is expressed over, and a small
    evaluator for the generated AST. PLURAL-CATEGORY is the whole public surface: a locale
    and a number in, one of :ZERO :ONE :TWO :FEW :MANY :OTHER out, with :OTHER as the
    always-safe answer for a locale CLDR does not know.")
  (:export #:plural-category #:categories-for #:supported-locale-p #:supported-locales #:rules-for
           #:operands-for #:operands-n #:operands-i #:operands-v #:operands-w
           #:operands-f #:operands-tt #:operands-c
           #:+categories+ #:+cldr-version+))

(cl:defpackage #:hyperion/i18n
  (:use #:cl)
  (:local-nicknames (#:jzon   #:com.inuoe.jzon)
                    (#:http   #:hyperion/http)
                    (#:spin   #:spinneret)
                    (#:plural #:hyperion/plural))
  (:documentation
   "Pluggable locale machinery: a TRANSLATION-SOURCE protocol (built-in JSON
    dictionary; a DB source app-supplied later), a LOCALE-STORE protocol (cookie
    now; session/DB later), request RESOLVE-LOCALE (?lang= > store > Accept-Language
    > default; xx-YY -> xx; q-weight), and an HTMX-first LANGUAGE-SWITCHER with an
    app-overridable locale display reference. The app supplies which languages, the
    translations, and the store. See docs/i18n-design.md, ADR-0006,
    docs/i18n-pluggable-spec.md.")
  (:export
   ;; translation source
   #:translate #:translate-plural #:plural-key #:supported-locales #:default-locale
   #:make-json-source #:load-dictionary #:make-dictionary
   #:dictionary #:dictionary-p #:interpolate #:locale-supported-p #:*default-locale*
   ;; locale store
   #:read-locale #:persist-locale #:cookie-store #:make-cookie-store #:lang-cookie
   ;; resolution
   #:resolve-locale #:negotiate-locale
   ;; display + switcher
   #:*locale-display* #:register-locale-display #:locale-endonym #:locale-flag
   #:language-switcher
   ;; text direction (RTL): a property of the LANGUAGE, so it lives beside the
   ;; endonym/flag rather than being re-derived in every consuming app
   #:locale-direction #:rtl-p #:dir-attribute #:lang-attributes
   #:locale-display #:locale-display-p #:locale-display-endonym
   #:locale-display-flag #:locale-display-direction #:+rtl-languages+))

;;; --- Cookie / tracking consent (GDPR / ePrivacy) ------------------------
(cl:defpackage #:hyperion/consent
  (:use #:cl)
  (:local-nicknames (#:http #:hyperion/http)
                    (#:spin #:spinneret))
  (:documentation
   "Pluggable consent machinery for cookie/tracking compliance (GDPR, ePrivacy,
    CCPA). A CONSENT taxonomy (necessary + optional categories; necessary is exempt
    from opt-in), a CONSENT-STORE protocol (cookie now; a mnemosyne-backed consent
    LOG later -- accountability needs an audit trail), request seams (READ-CONSENT,
    CONSENT-DECIDED-P, RESOLVE-CONSENT, CONSENT-ALLOWS-P), and an HTMX-first
    CONSENT-BANNER. Optional categories default to OFF until explicit opt-in; a
    version bump re-prompts everyone. The app supplies copy, routes, look, and the
    store; the framework owns the taxonomy, persistence seam, and wiring. See
    docs/compliance-design.md.")
  (:export
   ;; taxonomy
   #:*consent-categories* #:*necessary-categories* #:*consent-version*
   #:consent-category-p #:optional-categories
   ;; consent values
   #:consent-allows-p #:normalize-consent
   ;; store protocol + cookie backend
   #:read-consent #:persist-consent #:consent-store
   #:cookie-consent-store #:make-cookie-consent-store
   #:*consent-cookie-name* #:*consent-max-age*
   ;; request seam
   #:consent-decided-p #:resolve-consent
   ;; component
   #:consent-banner))

;;; --- Static asset serving -----------------------------------------------
(cl:defpackage #:hyperion/static
  (:use #:cl)
  (:documentation
   "Serve files from a root directory as Clack responses, with content-type by
    extension and .. traversal guarded. Pathname-based so it works on Windows and
    Unix alike. Responses carry cache validators (ETag / Last-Modified) and a
    Cache-Control policy; pass the request env and conditional requests
    (If-None-Match / If-Modified-Since) are answered with 304 and no body.")
  (:export #:file-response #:content-type-for
           #:*cache-control* #:*immutable-cache-control*
           #:file-etag #:not-modified-p #:http-date #:parse-http-date))

;;; --- Markdown -> HTML ----------------------------------------------------
(cl:defpackage #:hyperion/markdown
  (:use #:cl)
  (:documentation
   "Markdown -> HTML (via 3bmd). SAFE by default: raw HTML in the source is escaped
    so user/untrusted content cannot inject markup; pass :allow-html t only for
    trusted content. Fenced code blocks (```lang) are supported. Used by chat
    bubbles, CMS content, and anywhere user-authored prose becomes HTML.")
  (:export #:render #:escape-html))

;;; --- Parenscript helpers (CL -> JS, no Node) ----------------------------
(cl:defpackage #:hyperion/js
  (:use #:cl)
  (:local-nicknames (#:out #:hyperion/output)
                    (#:ps  #:parenscript))
  ;; Parenscript recognizes CL-package operators by name, but its OWN macros are
  ;; matched by symbol identity -- so chain/@/new/create must be the real
  ;; parenscript symbols, not fresh ones interned in this package. Import them.
  (:import-from #:parenscript #:chain #:@ #:new #:create)
  (:documentation
   "Client JS authored in Lisp and compiled with Parenscript (no Node). The
    hot-reload poller is the dogfood target; the interaction helpers are generic,
    selector-parametrized building blocks. All compiled through hyperion/output
    so they honor *output-style*.")
  (:export #:dev-reload-js #:*dev-reload-interval-ms* #:*dev-error-element-id*
           #:stick-to-bottom-js #:autogrow-textarea-js #:enter-submits-js
           #:sticky-solidify-js))

;;; --- The hot-reload dev loop (Figwheel for CL) --------------------------
(cl:defpackage #:hyperion/dev
  (:use #:cl)
  (:local-nicknames (#:srv  #:hyperion/server)
                    (#:hjs  #:hyperion/js)
                    (#:hlog #:hyperion/logging))
  (:documentation
   "The signature dev loop: watch source roots, recompile changed files into the
    running image, rebuild the server around preserved state via a builder thunk,
    and refresh :dev browser tabs. A compile error becomes a browser overlay
    string rather than only a REPL message. WATCH is the engine; SERVE is the
    turnkey entry any hyperion app uses -- it wraps the app for browser
    auto-refresh (WRAP-DEV) and always watches hyperion's own src/ too.")
  (:export #:*reload-epoch* #:mark-reloaded
           ;; what the watcher watches (pre-publication issue 134): a denylist, pruning directories
           #:*watch-excluded-directories* #:*watch-excluded-types*
           #:watch #:unwatch #:reload! #:dev-error
           #:serve #:wrap-dev
           ;; pre-publication issue 235: the guard is only useful if a caller can name what it signals.
           #:invalid-builder #:invalid-builder-got #:invalid-builder-arity))

(cl:defpackage #:hyperion
  (:use #:cl)
  (:documentation "Hyperion: a full-stack, HTMX-first web framework for Common Lisp.")
  (:export #:version))
