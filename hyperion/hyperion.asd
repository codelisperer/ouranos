;;;; hyperion.asd --- system definitions for Hyperion
;;;;
;;;; Hyperion: a full-stack web framework for Common Lisp -- HTMX-first, a live
;;;; hot-reload dev loop, Parenscript for JS (no Node), a CSS DSL, and a typed
;;;; core in Coalton with an effectful CLOS/Spinneret shell. Generic components
;;;; and industrial HTMX wiring only; never domain-specific components.

(defsystem "hyperion"
  :description "A full-stack, HTMX-first web framework for Common Lisp (Coalton core)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("coalton"
               "aion/log"                             ; neutral logging facade (leftward dep
               "aion/dynamic"   ; carries the request context across a thread (#158))
               "aion/interceptor"                     ; the typed pipeline (pre-publication issue 177; was a file here)
               "aion/random"                          ; CSPRNG for session ids (pre-publication issue 95) -- NOT cl:random
               "alexandria"
               "bordeaux-threads"                     ; hyperion/session store locks
               "clack"
               "spinneret"
               "parenscript"
               "quri"
               "com.inuoe.jzon"                       ; hyperion/http JSON
               "3bmd" "3bmd-ext-code-blocks"          ; hyperion/markdown
               ;; pre-publication issue 238: the port preflight connects rather than binds. An SBCL contrib,
               ;; so no external dependency -- but DECLARED, because it was reaching
               ;; hyperion only transitively through clack/usocket, and this tree has
               ;; already been bitten once by relying on that (flexi-streams).
               (:require "sb-bsd-sockets"))
  ;; NO HTTP BACKEND HERE, deliberately (pre-publication issue 139; ECOSYSTEM decisions log, 2026-08-05).
  ;;
  ;; This system used to depend on a CLACK HANDLER per platform -- clack-handler-woo on
  ;; Unix, clack-handler-hunchentoot on Windows. Woo binds libev through CFFI at LOAD time,
  ;; so every image that loaded hyperion held an open libev handle whether or not it ever
  ;; served a request; SBCL reopens recorded shared objects at startup, and every Linux
  ;; desktop bundle therefore died before `main` with `Error opening shared object
  ;; "libev.so.4"`. ADR-0011 decided against that a week before pre-publication issue 139 and was never
  ;; implemented at this level.
  ;;
  ;; The fix is not to swap in a different permanent third-party server. A framework does
  ;; not get to choose the application's HTTP server, so the APP declares the backend it
  ;; wants -- exactly like every other opt-in capability in this tree -- and
  ;; hyperion/server:default-server picks from what the image actually loaded. When the
  ;; native libuv server lands (pre-publication issue 117) it arrives as one more choice rather than as surgery
  ;; on this file.
  ;;
  ;; Apps: depend on the CLACK HANDLER system, not the bare server. `clackup` resolves
  ;; :woo / :hunchentoot through clack.handler.<name>, which lives in the handler system
  ;; (each pulls its server transitively); depending on the raw server leaves Clack to
  ;; lazy-load the handler at runtime, which fails with "... is unknown handler" wherever
  ;; that system was never fetched.
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "output")
                             (:file "htmx")     ; typed HTMX vocabulary (Coalton)
                             (:file "path")     ; path templates + matching (Coalton)
                             (:file "html")     ; rendering the vocabulary (CL)
                             (:file "logging")  ; request id + request logging
                             (:file "security-headers") ; default security headers (#119)
                             (:file "server")   ; configurable Clack backend
                             (:file "http")     ; request/response utils
                             (:file "router")   ; URL dispatch over the typed paths (CL)
                             (:file "session")  ; cookie-based HTTP sessions + store
                             (:file "csrf")     ; the CSRF refusal (ADR-0019, pre-publication issue 280)
                             (:file "channel")  ; broadcast log + per-reader cursors (fan-out)
                             (:file "feed")     ; latest-per-key at a subscriber's rate (ADR-0016)
                             (:file "sse")      ; feed -> EventSource, the ADR-0016 consumer
                             ;; The generated rules load BEFORE the evaluator that reads
                             ;; them: +CLDR-PLURAL-RULES+ is a defparameter, and a forward
                             ;; reference to it is a full WARNING, which the gate treats as
                             ;; a build failure.
                             (:module "vendor"
                              :components ((:file "cldr-plurals")))  ; GENERATED, pinned
                             (:file "plural")   ; CLDR operand model + rule evaluator
                             (:file "i18n")     ; locale dictionaries + negotiation
                             (:file "consent")  ; cookie/tracking consent (GDPR/ePrivacy)
                             (:file "static")   ; static asset serving
                             (:file "markdown") ; Markdown -> HTML (safe by default)
                             (:file "js")       ; Parenscript (poller + helpers)
                             (:file "dev")      ; hot-reload dev loop
                             (:file "hyperion"))))
  :in-order-to ((test-op (test-op "hyperion/tests"))))

;;; HTML -> Spinneret converter (a dev-time porting aid). Standalone: it only needs
;;; Plump, so `(ql:quickload :hyperion/import)` is fast and doesn't compile the whole
;;; framework just to convert a snippet.
(defsystem "hyperion/import"
  :description "Convert HTML snippets to Spinneret s-expressions (porting aid)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("plump")
  :serial t
  :components ((:file "src/import")))

;;; Vendored browser assets -- htmx, Alpine.js and Bulma -- compiled INTO the fasl as
;;; literal octet vectors and served from memory, so a desktop bundle works with no
;;; network and no files to copy beside the binary (pre-publication issue 123, ADR-0013). Opt-in: ~770K of
;;; literals is not a cost to impose on an app that ships its own CSS.
;;;
;;; The vendored files are listed as static-file components in SERIAL order, before the
;;; source that embeds them, so touching one recompiles the embedding instead of leaving
;;; a stale literal in the fasl. `scripts/check-assets.lisp` proves the bytes still match
;;; `assets/vendor/ASSETS.pin`.
;;; --- http1: the HTTP/1.1 parser, pure and dependency-free ------------------
;;;
;;; Its own system, depending on NOTHING but coalton -- not even on `hyperion'. That is what
;;; keeps it inside scripts/verify-tree.lisp, which deliberately excludes aion/uv* because
;;; those need a C toolchain. The most security-critical code in the tree must sit inside the
;;; checker AGENTS.md names as the standard of evidence, so the parser cannot live in the
;;; transport system. See docs/adr/0015-ring-calling-convention-without-clack.md.

(defsystem "hyperion/http1"
  :description "HTTP/1.1 request-head parsing as a total function (Coalton core)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("coalton")
  :serial t
  :components ((:module "src/http1"
                :serial t
                :components ((:file "packages")
                             (:file "parser")
                             (:file "encoder"))))
  :in-order-to ((test-op (test-op "hyperion/http1/tests"))))

(defsystem "hyperion/http1/tests"
  :description "Test suite for hyperion/http1."
  :depends-on ("hyperion/http1" "fiveam")
  :serial t
  :components ((:module "tests/http1"
                :serial t
                :components ((:file "parser-tests")
                             (:file "encoder-tests"))))
  :perform (test-op (o c) (uiop:symbol-call :hyperion/http1/tests :run-tests)))

;;; --- server-uv: the native HTTP server, on aion/uv ------------------------
;;;
;;; NOT :depends-on "hyperion", and that is the point rather than an oversight. This system
;;; needs the parser, the socket and the logger -- nothing from hyperion core -- and core
;;; still declares `clack'. Depending on it would drag Clack into the one system whose
;;; reason to exist is not needing it, so the native path could never be proven Clack-free.
;;; Selection (hyperion/server:default-server preferring this backend when the image has
;;; loaded it) is a later commit and belongs on the SERVER side of that seam, where the
;;; other backends are already chosen the same way (pre-publication issue 139).
;;;
;;; Native: needs a built vendor/libuv (scripts/build-libuv.lisp), so it is opt-in and sits
;;; in verify-tree's +UV-SYSTEMS+ rather than +SYSTEMS+ -- see the commentary there.

(defsystem "hyperion/server-uv"
  :description "A native HTTP/1.1 server for Ring handlers, on aion/uv (no Clack)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("hyperion/http1" "aion/uv/net" "aion/log" "aion/pool"
               "aion/uv")   ; server-uv.lisp calls uv: directly, not only through uv/net
  :serial t
  :components ((:file "src/server-uv"))
  :in-order-to ((test-op (test-op "hyperion/server-uv/tests"))))

(defsystem "hyperion/server-uv/tests"
  :description "Tests for the native libuv HTTP server -- over a real socket, end to end."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  ;; sb-bsd-sockets is the CLIENT. Testing an HTTP server with an in-image call proves
  ;; nothing about framing, so every check here writes octets to a real TCP socket and
  ;; reads octets back.
  ;;
  ;; "hyperion" is here and deliberately NOT in hyperion/server-uv itself. The asymmetry is
  ;; the point: the SOURCE must not depend on core (core declares clack, and the native
  ;; path exists to not need it), while the SUITE must, because the thing commit 5 added is
  ;; precisely the seam BETWEEN them -- hyperion/server:start choosing and starting this
  ;; backend. A suite that could not load both could not test the join.
  :depends-on ("hyperion/server-uv" "hyperion" "aion/pool" "aion/uv"  ; server-uv-tests.lisp calls pool: and uv:
               "fiveam" "aion/test-threads" (:require "sb-bsd-sockets"))
  :serial t
  :components ((:file "tests/server-uv-tests"))
  :perform (test-op (o c) (uiop:symbol-call :hyperion/server-uv/tests :run-tests)))

(defsystem "hyperion/assets"
  :description "Vendored htmx / Alpine.js / Bulma, embedded in the image, plus Bulma theming."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("hyperion")
  :serial t
  :components ((:module "assets/vendor"
                :components ((:static-file "ASSETS.pin")
                             (:static-file "htmx.min.js")
                             (:static-file "alpine.min.js")
                             (:static-file "bulma.min.css")))
               (:file "src/assets"))
  :in-order-to ((test-op (test-op "hyperion/assets/tests"))))

(defsystem "hyperion/test-ports"
  :description "Test support: a candidate port for a test server, and a retry when it is taken."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  ;; Shared by hyperion/tests and hyperion/assets/tests, which each had an identical copy
  ;; of the helper (#159). Depends on hyperion for the PORT-IN-USE condition it handles.
  :depends-on ("hyperion" (:require "sb-bsd-sockets"))
  :components ((:file "tests/ports")))

(defsystem "hyperion/assets/tests"
  :description "Tests for the vendored-asset embedding and Bulma theming."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  ;; ironclad is a TEST-time dependency only -- it is what lets the suite prove the
  ;; embedded bytes hash to the pinned sha256. hyperion/assets itself ships no crypto.
  ;; clack-handler-hunchentoot likewise: pre-publication issue 148's regression test serves the assets over a
  ;; real socket, because the bug was invisible to every in-image check. Hunchentoot
  ;; rather than Woo so the suite needs no libev (ADR-0011, and pre-publication issue 139 left the backend to
  ;; the consumer -- here the consumer is the test).
  :depends-on ("hyperion/assets" "hyperion"   ; assets-tests.lisp calls router: and server:
               "hyperion/test-ports" "fiveam" "ironclad" "clack-handler-hunchentoot"
               (:require "sb-bsd-sockets"))
  :serial t
  :components ((:file "tests/assets-tests"))
  :perform (test-op (o c) (uiop:symbol-call :hyperion/assets/tests :run-tests)))

;;; Durable session store, backed by mnemosyne. A separate system so hyperion core keeps
;;; no database dependency; this aux system depends on mnemosyne (a leftward dep in the DAG:
;;; mnemosyne is left of hyperion). `(ql:quickload :hyperion/session-db)` to use it.
;;; Desktop capability: run a Hyperion app as a native OS-webview window (ADR-0008). Its
;;; own aux system so hyperion core stays webview-free -- only a desktop app pulls it. Pure
;;; CL here (sb-bsd-sockets for the free port + readiness); the native launcher is an
;;; out-of-process C binary built separately (see hyperion-view/). `(ql:quickload
;;; :hyperion/desktop)` to use it.
(defsystem "hyperion/view/tests"
  :description "hyperion-view's argument contract, asserted headlessly (pre-publication issue 276)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  ;; DEPENDS ON hyperion/desktop, not on nothing: the suite resolves the launcher through
  ;; desktop:default-launcher rather than rebuilding that logic, so if resolution moves
  ;; the suite moves with it instead of quietly testing a path nobody uses.
  :depends-on ("hyperion/desktop" "fiveam")
  :serial t
  :components ((:file "tests/view-tests"))
  :perform (test-op (o c) (uiop:symbol-call :hyperion/view/tests :run-tests)))

(defsystem "hyperion/desktop"
  :description "Run a Hyperion app as a native desktop window (out-of-process OS webview)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("hyperion" "aion/platform" (:require "sb-bsd-sockets"))
  :serial t
  :components ((:file "src/desktop")))

;;; The desktop self-updater (ADR-0010, pre-publication issue 76). An aux system: only a desktop app pulls it,
;;; and hyperion core stays free of crypto and of an HTTP client.
;;;
;;; PROMOTED from the client half of a consuming app that ships an updater to real users,
;;; rather than written fresh -- so the shape is one that has met a production release
;;; cycle. What changed on the way in is recorded in src/update/packages.lisp.
;;;
;;; `(ql:quickload :hyperion/update)` to use it.
(defsystem "hyperion/update"
  :description "Desktop self-update: signed manifest, anti-rollback, stage-and-swap."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; aion/signature for Ed25519 (pre-publication issue 75/pre-publication issue 208), aion/platform for the manifest key (pre-publication issue 206 --
  ;; the client must look artifacts up under exactly the name the build script filed them
  ;; under), aion/http-client for the one outbound call, jzon for the manifest. NO NEW
  ;; EXTERNAL DEPENDENCY: every one of these is already in the tree.
  ;; cl-base64 because a detached `.sig' is base64 TEXT, not raw bytes -- the format
  ;; `scripts/update-manifest.lisp' writes. Already in the tree (aion/signature encodes
  ;; keys with it), so this widens where it is used rather than what is pulled in.
  ;; aion/random because the staging directory's name must be UNGUESSABLE, not merely
  ;; unique: a verified installer is written there and then executed from there, so anyone
  ;; who can predict the path can create it first. pre-publication issue 95's guard over hyperion/src forbids
  ;; cl:random for exactly this reason and caught the first version of it. No new external
  ;; dependency -- ironclad already arrives with aion/signature.
  :depends-on ("coalton" "aion/signature" "aion/platform" "aion/http-client"
               ;; dexador is GONE from this line (pre-publication issue 332). It was here for the local
               ;; transport this file used to carry; pre-publication issue 223 (0c65c72) moved that
               ;; contract into `aion/http-client', so the HTTP call is now made
               ;; through the shared client and nothing here names dexador. It still
               ;; arrives transitively, which is the point: declared where it is used.
               "aion/random" "com.inuoe.jzon" "cl-base64")
  :serial t
  :components ((:module "src/update"
                :serial t
                :components ((:file "packages")
                             (:file "version")
                             (:file "state")
                             (:file "client"))))
  :in-order-to ((test-op (test-op "hyperion/update/tests"))))

(defsystem "hyperion/update/tests"
  :description "The updater's typed core: version algebra and the update decision."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  ;; aion/signature is a TEST-time dependency for the client suite: it generates a real
  ;; keypair per run and signs real bytes, because a suite that stubs the verification it
  ;; exists to prove is the shape of defect this tree keeps finding.
  ;; sb-bsd-sockets so the HTTP backend can be tested against a socket that actually
  ;; answers. The contract under test there is between this client and DEXADOR -- a
  ;; 404 is a status Dexador SIGNALS rather than returns -- and no CLOS stub standing
  ;; in for a source can state it (pre-publication issue 332). An SBCL contrib, so nothing new is pulled in.
  :depends-on ("hyperion/update" "aion/platform"   ; update-client-tests.lisp calls platform:
               "aion/random"   ; ...and aion/random:random-hex, for a fresh ACL test directory (#166)
               "fiveam" "aion/signature" "cl-base64"
               (:require "sb-bsd-sockets"))
  :serial t
  :components ((:file "tests/update-tests")
               (:file "tests/update-client-tests"))
  :perform (test-op (o c) (uiop:symbol-call :hyperion/update/tests :run-tests)))

(defsystem "hyperion/update-ui"
  :description "The updater's visible half: the poll, the banner and its two controls (pre-publication issue 333)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; BOTH, and that is why this is its own system rather than files added to either.
  ;; `hyperion/update' deliberately does not depend on `hyperion': the check is usable from
  ;; a CLI or a headless service, and folding routes and Spinneret into it would put a web
  ;; framework on the load path of every consumer that only wanted to know whether a newer
  ;; build exists. Folding the updater into `hyperion' would be worse in the other
  ;; direction -- dexador and jzon for every app that renders a page. No new external
  ;; dependency either way; nothing in the tree depends on this system.
  :depends-on ("hyperion" "hyperion/update")
  :serial t
  :components ((:file "src/update-ui"))
  :in-order-to ((test-op (test-op "hyperion/update-ui/tests"))))

(defsystem "hyperion/update-ui/tests"
  :description "The update surface: the routes exist, the banner renders, and the poll survives."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("hyperion/update-ui" "hyperion" "hyperion/update" "fiveam")  ; update-ui-tests.lisp calls both
  :serial t
  :components ((:file "tests/update-ui-tests"))
  :perform (test-op (o c) (uiop:symbol-call :hyperion/update-ui/tests :run-tests)))

(defsystem "hyperion/session-db"
  :description "A mnemosyne-backed backend for hyperion/session's STORE protocol (durable sessions)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("hyperion" "mnemosyne")
  :serial t
  :components ((:file "src/session-db"))
  :in-order-to ((test-op (test-op "hyperion/session-db/tests"))))

(defsystem "hyperion/session-db/tests"
  :description "Integration tests for the mnemosyne-backed session store (in-memory SQLite)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("hyperion/session-db" "hyperion" "mnemosyne" "fiveam")  ; session-db-tests.lisp calls both
  :serial t
  :components ((:file "tests/session-db-tests"))
  :perform (test-op (o c) (uiop:symbol-call :hyperion/session-db/tests :run-tests)))

;;; Mnemosyne-backed identity store (users + password auth). Aux system so hyperion core
;;; keeps no DB dependency (same pattern as session-db); depends on mnemosyne + ironclad.
(defsystem "hyperion/auth-db"
  :description "A mnemosyne-backed identity store: users, PBKDF2 passwords, temp-password flag, roles."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("hyperion" "mnemosyne" "ironclad")
  :serial t
  :components ((:file "src/auth-db"))
  :in-order-to ((test-op (test-op "hyperion/auth-db/tests"))))

(defsystem "hyperion/auth-db/tests"
  :description "Integration tests for the identity store (in-memory SQLite)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("hyperion/auth-db" "mnemosyne" "fiveam" "bordeaux-threads" "aion/test-threads")  ; auth-db-tests.lisp calls mnemosyne: directly
  :serial t
  :components ((:file "tests/auth-db-tests"))
  :perform (test-op (o c) (uiop:symbol-call :hyperion/auth-db/tests :run-tests)))

;;; Example apps (like praxeon's elise/chat-rbt) -- each a runnable, buildable proof
;;; of a roadmap milestone. Own systems so they never load unless asked.
;;; #1 active-search: Bulma + HTMX + Alpine + Parenscript (compiled JS), no Node.
(defsystem "hyperion/examples/active-search"
  :description "Example: Bulma + HTMX + Alpine + Parenscript, server-rendered (no Node)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  ;; The app declares its own HTTP backend (pre-publication issue 139). Hunchentoot: pure CL, identical on all
  ;; three platforms, and indistinguishable from Woo on this workload once Content-Length
  ;; is set (ADR-0011 measured it). An example that cannot be run on Windows is not one.
  :depends-on ("hyperion" "hyperion/assets" "spinneret" "clack-handler-hunchentoot")
  :serial t
  :components ((:module "examples/active-search"
                :serial t
                :components ((:file "app")))))

;;; #1b active-search, DB-backed: the same HTMX UI, but sourced from SQLite via a mnemosyne
;;; migration + query (depends leftward on mnemosyne). Shows the whole stack end to end.
(defsystem "hyperion/examples/active-search-db"
  :description "Example: active-search over a mnemosyne migration (SQLite + data-driven query)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("hyperion" "hyperion/assets" "mnemosyne" "spinneret"
               "clack-handler-hunchentoot")
  :serial t
  :components ((:module "examples/active-search-db"
                :serial t
                :components ((:file "app")))))

;;; #2 coalton-repl: a TYPED Coalton REPL as a native DESKTOP app -- the M1 capstone of
;;; the desktop capability (docs/desktop.md). Front-end here (HTMX/Spinneret); the eval +
;;; type-introspection engine is cons/coalton-repl (leftward dep: cons is left of hyperion).
;;; `(ql:quickload :hyperion/examples/coalton-repl)` then `(…:desktop)`.
(defsystem "hyperion/examples/coalton-repl"
  :description "Example: a typed Coalton REPL in a native desktop window (no Electron/Tauri)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  ;; Hunchentoot, and for this app it is load-bearing rather than a preference: Woo binds
  ;; libev at LOAD time, so a desktop bundle built against it dies before `main` on any
  ;; machine without libev (pre-publication issue 139, ADR-0011). Pure CL is what makes the artifact shippable.
  :depends-on ("hyperion" "hyperion/desktop" "hyperion/assets" "cons/coalton-repl"
               "spinneret" "lass" "clack-handler-hunchentoot")
  :serial t
  :components ((:module "examples/coalton-repl"
                :serial t
                :components ((:file "app")))))

;;; INTERIM; project tooling moves to `cons` (see docs/adr/0007). Retire this system
;;; once `cons build|serve` reach parity -- Hyperion is a library, not a CLI.
;;; The `hyperion` command-line tool (cargo-for-Lisp). A separate system so the
;;; library never pulls the CLI deps (clingon). Build a binary with `make cli`.
(defsystem "hyperion/cli"
  :description "The hyperion command-line tool: init/repl/build/test/... (cargo-for-Lisp)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("hyperion" "clingon")
  :serial t
  :components ((:file "src/cli")))

(defsystem "hyperion/tests"
  :description "Test suite for Hyperion."
  :depends-on ("hyperion" "hyperion/import" "aion/log"   ; suite, csrf and logging tests call log:
               "fiveam" "aion/test-threads" "hyperion/test-ports"
               "sb-bsd-sockets"    ; server-tests: a free port, and "is it listening?"
               ;; TEST-ONLY: an in-memory octet input stream, to hand BODY-STRING a body
               ;; without a socket (pre-publication issue 211). Already present transitively via clack --
               ;; declared because relying on that is how a dependency vanishes when
               ;; somebody else's changes.
               "flexi-streams"
               ;; A backend, because pre-publication issue 139 made hyperion declare none: an app (or a suite)
               ;; that actually starts a server picks its own, and server-tests starts real
               ;; ones. Without this the suite dies on NO-SERVER-BACKEND -- correctly, since
               ;; refusing to start beats answering on a server nobody chose.
               "clack-handler-hunchentoot")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "packages")
                             (:file "suite")
                             (:file "dev-tests")
                             (:file "http-tests")
                             (:file "multipart-tests")
                             (:file "i18n-tests")
                             (:file "plural-tests")
                             (:file "router-tests")
                             (:file "server-tests")
                             (:file "security-headers-tests") ; uses server-tests' helpers (#119)
                             ;; AFTER server-tests, which is not alphabetical and not an
                             ;; accident: it reuses that file's %SRV-OK-APP and %SRV-AWAIT
                             ;; rather than keeping a second copy of them (pre-publication issue 336). The port
                             ;; helpers are in hyperion/test-ports (#159).
                             (:file "dev-serve-tests")
                             (:file "backend-tests")
                             (:file "session-tests")
                             (:file "csrf-tests")
                             (:file "entropy-tests")
                             (:file "channel-tests")
                             (:file "feed-tests")
                             (:file "sse-tests")
                             (:file "static-tests")
                             (:file "logging-tests")
                             (:file "import-tests")
                             (:file "markdown-tests"))))
  :perform (test-op (op c) (uiop:symbol-call :hyperion/tests :run-tests)))
