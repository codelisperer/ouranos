# Hyperion — User Guide

> **Pre-alpha (0.0.0).** Grows with the framework. Plan: the
> [Roadmap board](https://github.com/orgs/codelisperer/projects/1) (`label:pkg:hyperion`);
> design narrative: [`../../docs/wiki/Framework-Hyperion.md`](../../docs/wiki/Framework-Hyperion.md);
> open questions: `docs/hyperion-vision.md`; decisions: `docs/adr/`; design notes:
> `docs/i18n-design.md`, `docs/dynamic-resources.md`, `docs/middleware-security.md`.

## Prerequisites

- **SBCL** + **Quicklisp** + **Coalton** — the last a *pinned git checkout*, not a
  Quicklisp system; `scripts/setup.sh` installs all three (see `coalton.pin`). (Hyperion's
  typed core is written in Coalton; pinning a checkout is a later hardening item).
- **No native library** — Hyperion itself declares no HTTP server, so nothing to install.
  An app that chooses `clack-handler-woo` needs **`libev`** (macOS `brew install libev`,
  Debian/Ubuntu `sudo apt-get install libev-dev`) and cannot be shipped as a desktop bundle
  without carrying it; `clack-handler-hunchentoot` is pure CL and needs nothing (pre-publication issue 139).

## Getting started

Hyperion is one of six core frameworks in the [Ouranos monorepo](../../README.md) —
plus `hermes`, a satellite leaf-lib for external integrations (email/SMS, later
payments) — and you build the whole tree, not this directory alone.

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons
```

`bootstrap.lisp` points ASDF at the whole tree and writes a source-registry drop-in,
so every REPL can find the frameworks with no symlinking. From any SBCL REPL:

```lisp
(ql:quickload :hyperion)    ; first load compiles Coalton (~minutes; cached after)
(hyperion:version)          ; => "0.0.0"
```

`bin/cons build | test | serve | run` is the intended one-command interface (in
progress; today `cons` implements `init` / `setup` / `conform` / `env` / `db-repl` / `db-url` / `template check` / `version`).

## What's here now

A working web core (much of it extracted from `../praxeon/src/web.lisp`).
Package-per-module:

| Module | What |
|---|---|
| `hyperion/server` | the Clack backend behind a neutral protocol — **your app declares the handler** (`clack-handler-hunchentoot` or `clack-handler-woo`); `default-server` picks from what is loaded, `HYPERION_SERVER` overrides, and no backend at all is a clear error rather than a guess — plus `start`/`stop`. |
| `hyperion/http` | request/response utilities over the raw Clack env: body, form/query params, cookies, headers, JSON. |
| `hyperion/session` | cookie-based **HTTP sessions**: a `store` protocol + in-memory backend, `wrap-session` middleware (owns the `Set-Cookie` so an app cannot drop it), `rotate-session` for the privilege boundary, a thread-safe per-session key/value bag, and **REPL/dev management** (list/inspect/reset/kill). |
| `hyperion/channel` | a **broadcast channel** (fan-out): an append-only log many readers consume by cursor, non-destructively — `publish`, `since` (stateless, for pollers), `subscribe`/`poll` (in-process). Transport-agnostic — the substrate for live updates (polling now, WebSockets/SSE later). |
| `hyperion/dev` | the **hot-reload loop** (`watch`/`reload!`/`mark-reloaded`/`unwatch` + a compile-error browser overlay). |
| `hyperion/output` | one knob for output formatting — dev **pretty**, prod **compact** — for HTML *and* JS. |
| `hyperion/htmx` (Coalton) + `hyperion/html` | typed HTMX vocabulary (`Swap`/`Verb`/`Trigger`/`Target`/`Duration`) + a CL render bridge and a generic OOB combinator. |
| `hyperion/js` | Parenscript helpers (no Node): the hot-reload poller + generic, selector-parametrized interaction helpers. |
| `hyperion/i18n` | locale dictionaries (per-locale JSON), flat `:section/key` lookup, `{named}` interpolation, `resolve-locale` + a cookie language switch, and **per-locale text direction** (RTL) for the page shell and switcher. |
| `hyperion/static` | static file serving (content-type by extension, `..`-traversal-guarded, cross-platform) with **HTTP caching** — `ETag`/`Last-Modified`/`Cache-Control` and `304` on conditional requests. |
| `hyperion/markdown` | Markdown → HTML, **safe by default** (raw HTML in the source is escaped). |

**Planned** (see the [board](https://github.com/orgs/codelisperer/projects/1),
`label:pkg:hyperion`): a routing helper, the CSS DSL, a generic
component library, **auth** + security middleware (HTTP sessions now shipped — see
`hyperion/session` above, and the fan-out primitive next), dynamic-resource
hot-reload, and the desktop story.

## Project tooling — `cons`, not Hyperion

Hyperion is a **library**. Creating, building, and running Hyperion apps is the job
of **`cons`**, the ecosystem's project & dev tooling ("cargo for Lisp") — Hyperion
supplies the web-app *template*, `cons` supplies the machinery.

| Command | Status |
|---|---|
| `cons init NAME --template web` | scaffold a new project — **works** |
| `cons setup` | write the project's ASDF source-registry `(:tree)` drop-in (per-OS) — **not** prereq provisioning, which is `scripts/setup.sh` |
| `cons version` | prints the version — **works** |
| `cons build` / `test` / `serve` / `run` / `add` | the intended surface — **planned / in progress** |

See the `cons` project for details.

## The hot-reload dev loop (the signature feature)

Hyperion's headline. Your app starts a loop with a **builder thunk** that returns
a fresh Clack handler, closing over *persistent state* so rebuilding the server
never touches it:

```lisp
(hyperion/dev:watch
  (lambda () (my-app:start-web :dev t))   ; builder -> a fresh Clack handler
  :system "my-app")                       ; watch my-app's src/
```

Now **edit a source file and save**: the changed file recompiles, the server
rebuilds via the builder (state survives), and `:dev` browser tabs refresh
themselves (they poll a reload epoch). A **compile error becomes a red browser
overlay**, not just a REPL message. Stop with `(hyperion/dev:unwatch)`.

### What auto-reloads — and what needs a reload/restart

- **Function edits (the everyday case): automatic.** Save → recompiled and live;
  render functions are resolved by symbol, so the next request uses them.
- **Structural changes — a new file, package, or dependency: need a `ql:quickload`
  or a restart.** The watcher does per-file `compile-file`+`load` and can't reorder
  for a newly introduced package/component. After such a change, run
  `(ql:quickload :my-app)` in the REPL (or cold-restart).
- **A wedged image:** cold restart.

### Watching multiple systems

`watch` takes `:systems` — a list of ASDF systems whose `src/` to watch — for an
app split across several systems, or for **co-developing a framework alongside your
app**:

```lisp
(hyperion/dev:watch builder :systems '("my-app" "hyperion"))
```

The **common case stays zero-config**: a single app watches its own `src/` (via
`:system "my-app"`), and Hyperion is a stable dependency you don't watch.

### Reloading into a running image (the ordering gotcha)

When you reload systems by hand, do it in **dependency order** — reload a
dependency *before* its dependents. Otherwise you hit
`The name "X" does not designate a package`: a dependent's `defpackage` references
a local-nickname whose package hasn't been created yet. So reload `hyperion`
before an app that depends on it:

```lisp
(ql:quickload :hyperion)      ; dependency first
(ql:quickload :my-app)        ; then dependents
```

If ASDF holds a stale view and a `quickload` seems to do nothing, force it:
`(asdf:load-system :hyperion :force t)`.

## Output style — dev pretty / prod compact

`hyperion/output:*output-style*` (`:pretty` | `:compact`) controls HTML *and* JS
formatting from one place. Render inside `hyperion/output:with-output-style` at the
request boundary so every response obeys it:

```lisp
(hyperion/output:with-output-style ()
  ;; ... render page / fragments / JS here ...
  )
```

Convention: **dev = `:pretty`** (readable view-source), **prod = `:compact`**
(whitespace-minimal). Drive it off your dev/prod signal (e.g. a `:dev` flag sets
the global once). Note: style-sensitive JS should be **generated at render time**,
not baked into a `defparameter` at load, so it honors the current style.

## Internationalization (i18n) — 1..n languages, drop a file

`hyperion/i18n` gives an app any number of languages with per-request locale
resolution. **Adding a language is dropping a file** — no code change.

1. **Translations** live as `resources/i18n/<code>.json`, nested
   `section → key → string` objects (`en.json`, `ru.json`, `es.json`, …). The set
   of files present *is* the set of supported locales.
2. **Load** once into a dictionary:
   ```lisp
   (defvar *dict*
     (i18n:load-dictionary
      (asdf:system-relative-pathname :myapp "resources/i18n/") :default :en))
   ```
3. **Look up** by a flat `:section/key` with an explicit locale; `{named}`
   placeholders interpolate from keyword args:
   ```lisp
   (i18n:translate *dict* :ru :home/join-the)          ; => "Присоединяйтесь к"
   (i18n:translate *dict* :en :cart/total :count 3)     ; "You have {count} items"
   ```
   HTML-bearing values render with Spinneret's `(:raw …)`; everything else is
   escaped by default.
4. **Resolve the locale per request** at the boundary — the middleware seam.
   Priority: explicit `?lang=` > cookie > user preference > `Accept-Language` >
   default. Persist an explicit choice to a cookie:
   ```lisp
   (let ((locale (i18n:resolve-locale *dict*
                   :param (http:query-param env "lang")
                   :cookie (http:cookie env "lang")
                   :accept-language (http:request-header env "accept-language"))))
     ;; ... render in LOCALE ...
     ;; on an explicit ?lang=, add (:set-cookie (i18n:lang-cookie locale)) to headers
     )
   ```

`i18n:supported-locales` drives a language switcher; `i18n:locale-supported-p`
guards. The dictionary is the seam toward DB-backed/AI-assisted translation later —
the lookup surface (`translate`) stays the same. See `docs/i18n-design.md`, ADR-0006.

### Counted strings — `translate-plural`

`"You have {count} items"` above is fine in English at 3 and wrong at 1, and English is the
easy case: Russian needs three forms, Arabic six, and which form applies is not "is it 1?"
— in Russian 21 takes the same form as 1 while 11 does not. So a counted string uses
`translate-plural` rather than `translate`:

```lisp
(i18n:translate-plural *dict* :en :cart/items 1)   ; => "You have 1 item"
(i18n:translate-plural *dict* :en :cart/items 3)   ; => "You have 3 items"
(i18n:translate-plural *dict* :ru :cart/items 21)  ; => "У вас 21 товар"
```

Authoring is one flat key per form, suffixed with the CLDR category:

```json
{ "cart": { "items.one":   "You have {count} item",
            "items.other": "You have {count} items" } }
```

`{count}` interpolates automatically — it is the one argument every counted string has, so
you don't pass it twice. Extra `{named}` placeholders still take keyword args as usual.

Which suffixes a language needs is `(hyperion/plural:categories-for :ru)` →
`(:one :few :many :other)`. Supply what it asks for; a form you haven't written yet falls
back to `.other`, then to the bare key, **within that language** before any fallback to the
default locale — a partly-pluralised German dictionary reads as German, not as English.

The rules cover **all 224 CLDR locales**, generated and pinned rather than hand-written
(`src/vendor/PLURALS.pin`, regenerated by `scripts/fetch-cldr-plurals.lisp`), so a locale
nobody anticipated is already correct. `translate` is unchanged and still has no idea
plural suffixes exist — existing calls behave exactly as before.

## HTTP sessions (`hyperion/session`)

Cookie-based sessions. A `session` is an id + a thread-safe key/value bag that's
**opaque to Hyperion** — store whatever the app needs (e.g. which conversation a
browser is attached to). Backends sit behind a small `store` protocol;
`make-memory-store` is the in-memory default and `hyperion/session-db` is the DB-backed one.
Nickname it: `(:local-nicknames (#:session #:hyperion/session))`.

**Changes are written back by `wrap-session`.** A DB-backed store hands out a fresh copy of the
session on every request, so `wrap-session` writes the session back through `store-save`
after the handler: every change to the data bag (`session-set`, `session-del`,
`reset-session`, `sign-in!`), and `accessed` at most once per `*accessed-save-interval*`
seconds (default 60). `store-save` only updates a session that is still in the store, so a
session the handler removed with `kill-session` stays removed. Code that resolves a session
with `ensure-session` directly, outside `wrap-session`, must call `store-save` itself after
changing it. A store written before `store-save` existed keeps working: the default method
writes through `store-add`, after checking with `store-ref` that the session is still there.

**Wrap the app once; the middleware owns the cookie.**

```lisp
(defvar *store* (session:make-memory-store))

(defun app ()
  ;; any (env -> response) handler: a bare function, or a router's TO-APP
  (session:wrap-session #'handle-request *store* :secure t))

;; in a handler: the session is already there
(defun show (env)
  (let ((sess (session:request-session env)))
    (session:session-set sess :conversation "conv-42")   ; arbitrary app keys
    (session:session-get sess :conversation)             ; => "conv-42"
    (list 200 '(:content-type "text/html; charset=utf-8") (list "…"))))
```

`wrap-session` resolves the browser's session (minting one, with a 128-bit CSPRNG
id, when there is none), puts it on the env where `request-session` reads it, and
attaches the `Set-Cookie` the response owes — including after a `rotate-session`
anywhere inside the handler. **The header is never the application's to emit, so it
cannot be dropped.**

### Sign in with `sign-in!`

```lisp
(defun sign-in (env)
  (session:sign-in! *store* env :user-id (authenticate env))   ; rotates the id, then stores
  (list 200 () (list "welcome")))
```

`sign-in!` is the whole privilege change in one call. It gives the request's session a new
id, discards the keys registered in `session:*privilege-scoped-keys*`, and stores the pairs
you pass. It always rotates, including when the request carried no session, so no path through
a sign-in keeps the id the visitor arrived with.

Why the rotation matters: an id that existed before the visitor authenticated may be one an
attacker holds. This store only honours ids it minted, so an invented cookie is ignored, but an
attacker can sign in as themselves to get a real id, give that cookie to the victim, and wait.
If the victim's sign-in keeps the id, the attacker's cookie is now signed in as the victim.
`hyperion/tests/session-tests.lisp` shows both directions: the test
`the-shipped-pattern-leaves-a-donated-id-alive-and-authenticated` and the test
`sign-in-kills-the-donated-id`.

> **Do not sign in with `ensure-session`.** It returns the session the request already has,
> so the id a visitor held before signing in is the id they hold after. That reads correctly,
> works, passes ordinary tests, and is the session-fixation bug above. A consuming app shipped
> exactly this.

### Other privilege changes: `rotate-session`

For a privilege change that is not a sign-in, such as granting a role or a step-up
authentication, call `rotate-session`:

```lisp
(session:rotate-session *store* (session:request-session env))   ; NEW id, same data, same object
```

It gives the session a fresh id, keeps its data bag, re-keys it in the store (new key in
before old key out, so a concurrent lookup never finds a hole) and mutates the session **in
place**, so the env and anything else already holding it stay live.

`rotate-session` followed by `session-set` is **not** the same as `sign-in!`: it keeps every
key in the data bag, including the ones in `*privilege-scoped-keys*`. `hyperion/csrf` registers
its token there, so after a sign-in done by hand the CSRF token minted before the visitor
authenticated is still valid (ADR-0019, decision 6). Use `sign-in!` for sign-in.

> **`reset-session` is not rotation either.** It wipes the data bag and **keeps the id**,
> which is a restart of app state for a browser that stays attached. At a sign-in it reads
> exactly like session-fixation defence and provides none of it.

### The lower-level seam

`ensure-session` returns the session named by the request cookie, or mints a fresh
one plus a `Set-Cookie` **as a second value that you must emit yourself**. Prefer
`wrap-session`: drop that second value and every request mints a new session —
nothing persists, sign-in does nothing, and each handler still reads correctly on
its own. Pass `:create nil` to look up without minting.

**REPL / dev management** — inspect and manage live sessions:

```lisp
(session:describe-sessions *store*)   ; a table of active sessions (id/created/accessed/keys)
(session:sessions *store*)            ; the session objects
(session:session-summary s)           ; => (:id … :created … :accessed … :keys …)  (data/render split)
(session:reset-session s)             ; keep the id, wipe the data bag — a dev restart, NOT rotation
(session:kill-session  *store* s)     ; evict one (by session object or id)
(session:kill-sessions *store*)       ; evict all
(session:kill-sessions *store* (lambda (s) (null (session:session-get s :keep))))  ; by predicate
```

This is the **HTTP layer** of a two-layer session design: the agent/conversation
session — where *many* browsers attach to *one* conversation — lives in Praxeon and
is built on top of this. Generic infra: the same module is what an app uses for
**auth/login**. Session ids are 128 bits from the OS CSPRNG (`aion/random`), not
`cl:random`.

## Identity and roles (`hyperion/auth-db`)

An aux system, so Hyperion core stays database-free. It holds users (email + optional phone),
PBKDF2 passwords, a temp-password flag for forced-change-at-first-login, and a role list.

```lisp
(defvar *auth* (auth:make-db-auth *db-connection* :dialect :postgres :ensure t))

(auth:create-user *auth* :email "ada@example.com" :password "pw" :roles '(:member))
(auth:authenticate *auth* "ada@example.com" "pw")     ; => USER or NIL
```

### Changing roles after the account exists

Roles are not decided once at sign-up. Promoting a moderator, appointing a second
administrator, and revoking either are the normal life of an account:

```lisp
(auth:grant-role  *auth* user-id :moderator)   ; => T
(auth:revoke-role *auth* user-id :moderator)   ; => T
```

Both are **idempotent** — granting a role already held, or revoking one not held, succeeds
and writes nothing — and both leave the user's other roles alone. There is deliberately no
`set-roles`: writing a whole list back forces the read-modify-write into your handler, where
two administrators editing one account in the same window silently lose an edit. `grant` and
`revoke` keep that window inside the store, where it is closed by the row's `vid` — an update
that lost the race affects no rows and is retried against the new state, so a second app
process or a second box behind a load balancer cannot clobber an edit either.

**None of this authorises the caller.** `grant-role` does exactly what it is told to the id
it is given and has no opinion about who is asking — as `set-password` does not either.
Checking that the *current* user may act on another is your handler's job.

### The last-administrator problem

Revoke the only administrator and nobody can administer anything, which is usually
unrecoverable through the app's own UI. The store will not stop you, and cannot: roles are
arbitrary keywords, so it has no way to know `:super-admin` outranks `:moderator`, and
teaching it would mean the framework inventing your vocabulary. It gives you the count
instead, so the guard is one line where the knowledge actually lives:

```lisp
(when (and (eq role :super-admin)
           (= 1 (length (auth:users-with-role *auth* :super-admin))))
  (error 'last-administrator))
```

### Catching role typos

By default any keyword is a role, so `:moderater` is stored happily and grants nothing. Give
the store a vocabulary and that becomes an error where the mistake is:

```lisp
(auth:make-db-auth conn :known-roles '(:member :moderator :super-admin))
;; (grant-role ... :moderater) now signals AUTH:UNKNOWN-ROLE
```

Opt-in, so existing code is unaffected. Checked on `create-user`, `grant-role` **and**
`revoke-role` — a typo on the way out is the worse direction, since you believe you removed
a role and did not.

## Request logging (`hyperion/logging`)

`server:start` wraps your app in request logging by default (`:log nil` opts out). Each
request gets a correlation id — adopted from an upstream `X-Request-Id` when the edge
already set one, else minted — bound into the `aion/log` context, so **everything** logged
during that request (hyperion, mnemosyne, praxeon, your own handlers) carries the same
`request_id`, and echoed back on the response.

One line per request at `:info`; arrival at `:debug`; errors via `log:exception` with a
backtrace, **re-signalled** so Clack still decides what the client sees.

For routes polled on a timer — health checks, metrics scrapes — mark them quiet:

```lisp
(hyperion/logging:register-quiet-path "/health")
```

Quiet requests log at `:trace` (not `:debug` — a dev REPL runs at `:debug`), so they stay
out of the way without being discarded. Errors are never quieted. The dev hot-reload
poller's own endpoints are registered automatically by `wrap-dev`.

See [`docs/logging.md`](../../docs/logging.md) for the house pattern.


### Right-to-left languages

Direction ships with the locale, so adding Arabic or Hebrew needs no per-app RTL list:

```lisp
(multiple-value-bind (lang dir) (i18n:lang-attributes locale)
  (spin:with-html (:html :lang lang :dir dir ...)))     ; both, or neither
```

`ar he fa ur ps sd yi dv ckb ug` (and regional tags like `ar-EG`) are RTL out of the box;
everything else defaults to `ltr`. `language-switcher` already marks each option with its
own `lang`/`dir`, so endonyms in other scripts render correctly inside your page. Use
`i18n:locale-direction` / `i18n:rtl-p` where you need the value directly, and
`register-locale-display ... :direction :rtl` to add or correct one.

Your CSS still owns layout mirroring — prefer logical properties (`margin-inline-start`,
`padding-inline`, `text-align: start`) over `left`/`right` and it follows `dir` for free.
See [`docs/i18n-design.md`](i18n-design.md) §10.

## Static files + HTTP caching (`hyperion/static`)

`file-response` maps a URL path onto a file under a root directory, refusing `..`
traversal and inferring the content type from the extension. The body is a **pathname**,
which is the Clack contract for a file, and `file-response` deliberately sets no
`Content-Length` — the backend does, because the backend is what knows how it will send the
file.

**What each backend does with it differs, and it is worth knowing which you are on.** Woo and
Hunchentoot `sendfile(2)` it. The native `:uv` server declares `Content-Length` from the file
and copies it to the socket in bounded pieces (`hyperion/server-uv:*file-chunk-bytes*`,
64 KiB), so a large download costs one piece of memory rather than the whole file — it does
not hold the file in the image, and it does not use `sendfile` either (pre-publication issue 313; `sendfile` on
`:uv` removes the copy through user space and is PLANNED, a separate change from the bounded
memory).

```lisp
(static:file-response #p"/srv/app/resources/public/" (getf env :path-info))
;; => (200 (:content-type "text/css" :etag "\"8f3e9a1-4d2\""
;;          :last-modified "Sun, 26 Jul 2026 21:14:03 GMT"
;;          :cache-control "public, max-age=3600")
;;     #P"/srv/app/resources/public/app.css")
```

Every response carries **cache validators** and a **policy**, because without them a
browser cannot revalidate and refetches every asset on every navigation — and an edge/CDN
that sees no explicit policy falls back to the platform default (often `private`) and
caches nothing. The default `public, max-age=3600` is deliberately `public` so it
*overrides* such a default.

Pass the request `env` and conditional requests are answered properly:

```lisp
(static:file-response root path :env env)
;; client sent If-None-Match / If-Modified-Since and is still current
;; => (304 (:etag … :last-modified … :cache-control …) nil)   ; no body
```

That 304 is where the bandwidth is actually saved. `If-None-Match` wins over
`If-Modified-Since` when both are present (RFC 9110): an ETag is an exact identity check,
while a date has one-second resolution and cannot distinguish two writes in the same second.

Tuning the policy per route:

```lisp
;; long-lived, never revalidated — ONLY for content-addressed URLs, where the
;; filename carries a hash of the bytes, so a change is a different URL
(static:file-response root path :env env
                      :cache-control static:*immutable-cache-control*)  ; 1 year, immutable

(static:file-response root path :env env :cache-control "no-cache")     ; always revalidate
(static:file-response root path :env env :cache-control nil)            ; emit no header
```

Rebind `static:*cache-control*` to change the app-wide default. The ETag is derived from
mtime + size, so it changes whenever the bytes are rewritten without hashing file contents
on every request. *(Fingerprinted asset URLs — generating the hashed names — belong to the
asset-pipeline work on the board; the `immutable` policy above is the half that exists.)*

## Interceptors, reimagined — the request→response cycle as a typed value

Hyperion's pipeline (`hyperion/interceptor`) is **Pedestal's idea** — middleware is
just data in the request→response cycle — made a **compile-time-checked, parametric
Coalton value**. One pipeline shape serves HTTP *and* agentic-AI contexts; a
mis-wired chain doesn't type-check. (Depth + the design rationale:
`docs/interceptors-design.md` and the vision doc's "Interceptors, reimagined.")

**The pieces.**
- `Flow` — a stage's outcome over a context `:c`: `(Proceed c)`, `(Halt c)` (stop
  entering; unwind now), `(Failure msg c)`.
- `Interceptor` — a named pair of stage functions over `:c`: `enter` (forward),
  `leave` (reverse). Build one with `on-enter` / `on-leave` (the missing side is the
  identity), or the 3-arg `Interceptor` constructor.
- `execute chain ctx` — run `enter` forward, then `leave` in reverse, threading the
  context and short-circuiting on `Halt`/`Failure`. **Pure.**

```lisp
;; a context is any type; here a checked HTTP/agent/whatever record :c
(interceptor:execute
  (list (interceptor:on-enter "locale" #'resolve-locale-stage)
        (interceptor:on-enter "auth"   #'require-session)
        secure-headers)                 ; an Interceptor with both enter & leave
  ctx0)
```

**Effects at the edge** — `execute-effect chain effect ctx`. Real stages want to
*do IO* (call an LLM, hit a DB, sign a JWT). Keep the pipeline pure and put the one
impure pivot **between the phases**: run `enter`; if it Proceeds, perform `effect`
(a `:c -> :c` supplied by the CL shell); then unwind `leave`. A `Halt`/`Failure` in
`enter` **skips the effect** — a guard that rejects the request never spends it.

```lisp
;; Elise's crisis guardrail as a chain around the LLM turn (the edge effect):
;;   enter  "non-blank" : Halt on empty input (skip the LLM entirely)
;;   EFFECT            : run the agent turn (input -> reply)   <- the impure pivot
;;   leave  "annotate" : on the crisis flag, append resources to the reply
(interceptor:execute-effect chain
                            (fn (turn) (with-reply turn (run-turn (turn-input turn))))
                            (make-turn input ""))
```

The same chain runs pure (`execute`) or effectful (`execute-effect`) — the effect is
a parameter, so it's equally the **server handler** and the **client round-trip**;
only *where the middle is* differs. The context is a plain value threaded through
(every stage returns a new one), which is exactly where **aion's persistent data
structures** slot in later without changing anything above the context type.

## Porting HTML → Spinneret

Have HTML written for HTML proper — a Bulma template, a component from a CSS kit —
and want it in Hyperion's all-Spinneret world? `hyperion/import` converts a snippet
to Spinneret s-expressions you paste into a `spinneret:with-html`. It's a **separate,
Plump-only system** (no framework load just to convert markup):

```lisp
(ql:quickload :hyperion/import)

(princ (hyperion/import:html->spinneret
        "<div class=\"box\"><button class=\"button is-primary\"
                                    hx-post=\"/ui/go\">Send</button></div>"))
;; =>
;; (:div :class "box"
;;  (:button :class "button is-primary" :hx-post "/ui/go" "Send"))
```

- `html->spinneret` returns pasteable **source** (pretty-printed, lowercase);
  `html->spinneret-forms` returns the raw **forms** for programmatic use.
- Elements → `(:tag :attr "v" … children)`; text → strings (insignificant whitespace
  dropped — pass `:whitespace :preserve` to keep it); boolean attrs (`autofocus`) →
  `:attr t`; `<script>`/`<style>` content → `(:raw "…")` (never escaped);
  `<!doctype>` → `(:doctype)`; comments dropped.
- **Limitations:** attribute order is normalized (class/id first); exotic attribute
  names (`@click`, `:class`, `hx-on:click` — Alpine/Vue) emit as escaped keywords and
  may want a hand touch-up. Treat the output as a faithful starting point, not a
  style-perfect transcription — then wire in `(li18n:t* …)` for copy and the typed
  HTMX helpers where it earns it.

## Framework attributes (`hx-`, `x-`, `@`, `_`) — no Spinneret warnings

Spinneret validates attribute names against the HTML spec **while macroexpanding** and
warns on anything it doesn't recognize (`HX-POST is not a valid attribute for <INPUT>`).
Its escape hatch is a prefix allow-list, and Hyperion registers the client-framework
prefixes for you when it loads — so HTMX, Alpine, and hyperscript attributes just work:

| prefix | for |
| --- | --- |
| `hx-` | HTMX core |
| `ws-`, `sse-` | HTMX websocket / SSE extensions |
| `x-` | Alpine.js (`:x-data`, `:x-model`, `:x-text`) |
| `@` | Alpine/Vue event shorthand (`:@click.away`) |
| `_` | _hyperscript |
| `data-`, `aria-` | (Spinneret defaults) |

Using another client framework? Add its prefix — **at compile time**, since validation
happens during macroexpansion, so the call must be evaluated before the templates that
need it are compiled:

```lisp
(eval-when (:compile-toplevel :load-toplevel :execute)
  (hyperion/html:allow-attribute-prefix "ng-"))   ; matching is case-insensitive
```

The full set lives in `hyperion/html:*client-attribute-prefixes*`; it is pushed onto
`spinneret:*unvalidated-attribute-prefixes*`.

## See also

- `docs/editor-setup.md` — editor/REPL setup.
- [Roadmap board](https://github.com/orgs/codelisperer/projects/1) /
  [`label:pkg:hyperion`](https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Ahyperion%22)
  — current status and planned work.
- [`../../docs/wiki/Framework-Hyperion.md`](../../docs/wiki/Framework-Hyperion.md) — the
  design narrative and open questions.
- `docs/adr/` — architecture decisions; `docs/*-design.md` — design notes.
- `CLAUDE.md` — the project constitution.
