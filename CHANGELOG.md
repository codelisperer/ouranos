# Changelog

This file lists what changed in Ouranos that an app built on it can see. Each entry names the
behaviour, plus the symbols, settings, tables and files an app would search its own code and notes
for. That way an app can find the workaround or the note that a change retires, not only learn that
something changed (#145). Changes to the gate, CI and this repository's own documentation are not
listed.

A pull request that changes behaviour an app can see adds its entry under **Unreleased**. When a
release is tagged, the Unreleased entries become that release's section. An app can pin a release by
its tag.

## Unreleased

### An app may have to act

- **mnemosyne: `sslmode=prefer` to another machine refuses to connect when the app has not
  loaded cl+ssl, instead of connecting in plaintext** (#341). mnemosyne uses TLS only if the app
  has loaded cl+ssl. Without it, `prefer`, which is also what a `DATABASE_URL` with no `sslmode`
  means, used to log `db tls unavailable, connecting in plaintext` and connect in plaintext to
  any host. It now does that only for this machine: `localhost`, `127.0.0.1`, `::1` and a Unix
  socket. To any other host it signals `mnemosyne/conn:db-error`: "sslmode=prefer to HOST, which
  is not this machine, needs TLS, and CL+SSL is not loaded in this image. Add "cl+ssl" to your
  application's :depends-on, or set sslmode=disable if a plaintext connection to that host is
  really what you want." `require`, `verify-ca` and `verify-full` refused already.

  An app acts if it connects to a Postgres on another machine, has no `cl+ssl` in its image, and
  relied on `prefer` falling back: it adds `"cl+ssl"` to its `:depends-on`. This departs from
  libpq, whose `prefer` connects in plaintext when the client has no SSL support; the
  maintainer chose to refuse, because #337 removed the cl+ssl that Hunchentoot used to load into
  every macOS and Linux app, and a deployed app would otherwise have lost TLS to its database
  with only a warning.

- **hyperion, praxeon: Hunchentoot is built without SSL on every platform, so it no longer
  loads cl+ssl on macOS and Linux.** `hyperion.asd` and `praxeon.asd` push
  `:hunchentoot-no-ssl` on every platform; it was Windows-only (#337). A macOS desktop app
  that loaded OpenSSL through Hunchentoot exited at startup on a Mac without Homebrew (#332),
  and nothing in the tree serves HTTPS through Hunchentoot.

  **An app acts if it connects to Postgres over TLS through mnemosyne and has no other source
  of cl+ssl.** mnemosyne does not depend on cl+ssl; it uses TLS only if the app has loaded
  it, and until now Hunchentoot loaded it for every macOS and Linux app. After this change,
  such an app sees:
  - with `sslmode=prefer`, `DATABASE_URL`'s default, and a Postgres on this machine
    (`localhost`, `127.0.0.1`, `::1` or a Unix socket): the warning `db tls unavailable,
    connecting in plaintext requested=prefer`, and a plaintext connection, or the server's
    refusal if it only accepts TLS;
  - with `sslmode=prefer` and any other host: the connection is refused with
    "sslmode=prefer to HOST, which is not this machine, needs TLS, and CL+SSL is not loaded in
    this image" (#341);
  - with `sslmode=require`, `verify-ca` or `verify-full`: the connection is refused with
    "sslmode=require needs TLS, and CL+SSL is not loaded in this image".

  The fix is to add `"cl+ssl"` to the app's own `:depends-on`, as mnemosyne's design already
  says. Measured on macOS against a Postgres with SSL enabled on 127.0.0.1: before this change both modes
  connected over TLS; after it, `prefer` connected in plaintext and `require` was refused;
  with the app declaring `cl+ssl`, both connected over TLS again. An app that loads
  `aion/http-client` (the updater, praxeon's LLM calls) still has cl+ssl through it. An app
  that wants Hunchentoot's own SSL acceptor removes `:hunchentoot-no-ssl` from `*features*`
  before `hunchentoot.asd` is read.

- **hyperion/desktop: a shipped app's window icon is carried in its bundle, so it shows on
  other machines.** `run-app :icon` is usually a path in the app's source tree, which in a
  dumped image is the build machine's path. On anyone else's machine `run-app` found no file
  there and passed no icon, so the window and taskbar showed hyperion-view's default icon
  (#74). `scripts/build-desktop-app.lisp` takes `--window-icon <file>` and copies it into the
  bundle as `window-icon.<type>`; `run-app` now passes that copy before the caller's path
  (`hyperion/desktop:bundled-window-icon`, new). **An app acts by adding `--window-icon` to its
  build command**: a `.ico` on Windows, a `.png` on Linux and macOS. Its `run-app :icon`
  argument can stay as it is for development. `--icon` still sets only the `.exe`'s icon on
  Windows.

- **praxeon: a step of a turn that the output limit cuts off ends the turn with
  `output-truncated` instead of passing as finished.** When a completion's stop reason is
  `:max-tokens`, `run-turn` no longer returns its text as the answer and no longer runs the tool
  calls parsed from it, and nothing from the step goes into `agent-history`. It emits a
  `:truncated` event and signals `praxeon/conditions:output-truncated`. That condition is a
  subtype of `deliberation-failure`, so an app's existing handler for `deliberation-failure` or
  `praxeon-error` receives it. With no handler the turn ends at that step with the error; in
  `praxeon/web` the reply shows the error's message. Before, a cut-off answer was returned as
  though it were complete, and a cut-off tool call was run and the model asked again until
  `max-steps` ran out. An app that still wants the cut-off text handles the condition with
  `accept-truncated`. (#326)
- **praxeon: a model whose maximum output is below 8,192 tokens needs a limit set.** The default
  limit is now 8,192 (see Added), and a provider can refuse a request whose limit is above the
  model's maximum. An app on such a model passes `:max-tokens`, sets the agent's `max-tokens`,
  or binds `praxeon/llm:*default-max-tokens*`. (#326)
- **praxeon/translate: a translation is still limited to 2,048 tokens, and a turn's reply can
  now be longer.** `translate` has its own `:max-tokens`, which defaults to 2,048 and did not
  change, and it returns a cut-off translation without signalling, as before. While replies were
  capped at 1,024 tokens, 2,048 left room for the translation; with replies of up to 8,192 it may
  not. An app that translates `run-turn`'s reply, as `praxeon/elise` does, passes `translate` a
  `:max-tokens` large enough for its longest replies. (#326)
- **aion/tls: a `tls-stream` whose transport ends without `close_notify` signals
  `aion/tls:tls-truncated`, a `tls-error`.** It used to return end of file, so data cut short by
  a dropped connection or an attacker read as complete. A caller whose protocol frames its own
  messages can accept it with the `treat-as-end-of-file` restart:
  `(handler-bind ((aion/tls:tls-truncated #'aion/tls:treat-as-end-of-file)) ...)`. (#282 review)

- **A macOS desktop app is now three files and is signed ad hoc, so a friend can open a
  downloaded copy from System Settings.** `scripts/build-desktop-app.lisp` no longer dumps one
  executable on macOS. The bundle directory holds `<name>`, a small launcher compiled from
  `scripts/macos-launcher.c` with `cc`; `sbcl`, the SBCL runtime; and `sbcl.core`, the app's
  core. `scripts/build-dmg.sh` signs the whole `.app` with `codesign --force --deep -s -`, fails
  unless `codesign --verify --deep --strict` passes on the `.app` and on the unpacked
  `.app.tar.gz` update payload, and moves every file in `Contents/MacOS` that is not a Mach-O
  (`sbcl.core`, `VERSION`, `LICENSES/`) to `Contents/Resources`, leaving a symlink.

  On another Mac a downloaded copy used to be reported as damaged, with no way past it but
  `xattr -dr com.apple.quarantine` in a terminal. Now it gets the "Not Opened ... Apple could
  not verify" prompt; after Done, System Settings > Privacy & Security offers **Open Anyway**
  (#332). It is still not notarized.

  An app acts if it packages its own macOS bundle, copies the one executable, or runs
  `codesign` or `otool` on it: the executable is now the launcher, and the runtime is `sbcl`
  beside it. `build-dmg.sh` refuses a bundle built before this change, with the reason. The
  app's arguments reach it unchanged, and the heap is the build's (4096 MB unless the build
  was run with another `--dynamic-space-size`). Linux and Windows builds are unchanged. The
  updater recognises the new shape (`%shipped-image-p` in `hyperion/update`).

  An app that loads OpenSSL (through `aion/http-client`, for example the updater) still exits
  at startup on a Mac without Homebrew, whichever shape it has; that is #78 and #334.

### Added

- **praxeon/retrieval: `paragraph-chunker`, which cuts a long section at blank lines.** Pass it as
  `(make-corpus store name :chunker (make-instance 'paragraph-chunker))`. A section of up to
  `:long-section` characters (default 1500) stays one chunk with boundary `:whole-section`, as with
  `section-chunker`. A longer one becomes runs of whole paragraphs of up to about `:target`
  characters (default 900), with boundary `:whole-paragraph` and sub-locators `"part 1"`,
  `"part 2"` and so on. A paragraph is never split. A line holding only spaces, tabs or a
  carriage return counts as blank. `chunker-id` includes both settings, so changing either one
  re-chunks the corpus on its next `sync-corpus`. An app that wrote its own chunker for long
  sections can use this one instead. (#322)

- **praxeon: an output limit per agent and per turn.** `make-agent` takes `:max-tokens`
  (`agent-max-tokens`), and `run-turn`, `run-turn-through` and `deliberate` take `:max-tokens`.
  The argument overrides the slot. With neither, `praxeon/llm:*default-max-tokens*` applies,
  read when the turn starts. An app that binds `*default-max-tokens*` around
  `run-turn` can stop and set one of these instead; the binding keeps working until it does.
  (#326)
- **praxeon: `praxeon/llm:*default-max-tokens*` is 8,192, up from 1,024.** 1,024 cut off
  ordinary agent turns: the text, a tool call's arguments and a thinking model's thinking all
  count against the limit. It applies to every call made without `:max-tokens`, including
  `generate-structured` and `distil`. The limit is a ceiling, not a charge: providers bill the
  tokens a model generates. `claude-sonnet-5` (`*default-model*`) and `claude-opus-4-8` accept up
  to 128,000, and `qwen2.5` (the `openai-compatible` default model) generates up to 8,192. A long
  reply can take longer than `*read-timeout*` (120 s) to arrive; bind that higher if it does.
  (#326)
- **praxeon/conditions: `output-truncated` and three restarts for it.** The readers are
  `output-truncated-step`, `output-truncated-max-tokens`, `output-truncated-text` and
  `output-truncated-tool-calls`. The restarts, each invoked by the function of the same name:
  `retry-with-max-tokens` asks the model again with a larger limit for the rest of the turn, and
  the retry counts against `max-steps`; `accept-truncated` makes `run-turn` return the cut-off
  text with a second value, `:truncated`; `abandon-turn` makes it return NIL and `:abandoned`.
  `run-turn-through` returns the same keyword as its second value. (#326)
- **praxeon/event: the `:truncated` event**, with `:step`, `:max-tokens` and `:tool-calls`, the
  names of the tool calls that were not run. The `:answer` event for text kept with
  `accept-truncated` carries `:truncated t`. (#326)
- **mnemosyne/conn: a connection pool, so an app can serve requests from more than one
  thread.** `make-pool` takes a backend and `:size` (default 10), and opens connections only
  when they are needed. `with-connection` now takes a pool as well as a backend: with a pool
  it lends one connection for the extent of its body, and a `with-connection` on the same
  pool nested inside it, on the same thread, gets the same connection. `close-pool` closes
  the pool.
  - Before a connection is lent again, a transaction the body left open is rolled back. On
    Postgres the session is then reset as `DISCARD ALL` resets it, except that prepared
    statements are kept: settings, role, advisory locks, temporary tables, `LISTEN`
    registrations and open cursors. A session-level advisory lock, such as
    praxeon/retrieval's per-corpus lock, therefore never passes to the next borrower.
  - A body that exits with an error has its connection closed instead of returned.
  - A checkout that finds every connection lent waits up to `:checkout-timeout` seconds
    (`*checkout-timeout-seconds*`, 30) and then signals `pool-exhausted`, a `db-error`.
  - A connection idle for longer than `:idle-check` seconds (`*idle-check-seconds*`, 30) is
    pinged before it is lent and replaced if the server has closed it.
  - Also new: `call-with-connection`, `pool-open-count`, `pool-idle-count` and `pool-closed`.
    (#325)
- **hyperion/db-connection: `wrap-connection`, for an app that keeps its connection in a
  global.** `(wrap-connection app pool '*db*)`, where `pool` must be a pool, not a backend, binds `*db*` to a connection from the pool for
  each request, so handlers that read `*db*` keep working when the server runs several
  requests at once.
  - When no connection becomes free in time, the answer is 503 with `Retry-After`
    (`*busy-response*`).
  - Inside a streaming body, `*db*` is unbound: the body runs after the request's connection
    has gone back, so it takes one with `with-connection` if it needs one.

  A new system: add `"hyperion/db-connection"` to `:depends-on`. (#325)
- **hyperion/server: `start` and `serve-forever` take `:workers`, the number of threads that
  run handlers**, so one slow handler no longer holds up every other request.
  - On Woo it is passed as `:worker-num`. On the native `:uv` server, the server runs
    handlers on its own `aion/pool` of that size and stops it in `stop`, and
    `server-uv:start` takes `:workers` too. Hunchentoot ignores it, with a warning, because
    Hunchentoot already runs each connection on its own thread.
  - The default, NIL, keeps today's behaviour: one thread for handlers on Woo and on `:uv`.
  - An app that shares one connection across handlers wraps itself in `wrap-connection`
    before it turns this on. The same applies to an app on Hunchentoot today. (#324)

### Fixed

- **hyperion/csrf: `wrap-same-origin` accepts an app on a default port.** An origin configured as
  `http://127.0.0.1:80` refused the app's own requests, because a browser sends
  `Origin: http://127.0.0.1` without the default port. Origins are compared after
  `normalise-origin`, which drops `:80` for http and `:443` for https, and the Host check accepts
  the host with or without the default port. (#302 review)


## v0.1.3 — 2026-09-27

Changes since `v0.1.2`. The tag is on `5c8fd25`.

### An app may have to act

- **hyperion/static: `file-response` no longer serves every file under the root.** It refuses
  what `*default-deny*` matches:
  - dotfiles and dot-directories (`.env`, `.git/`), except `/.well-known/` at the root;
  - editor and backup copies (`*~`, `*.bak`, `*.swp`, `*.orig`);
  - SQL and database files (`*.sql`, `*.sqlite`, `*.sqlite3`, `*.db`);
  - `*.pem`, `*.key` and `*.log`.

  It also refuses a path whose file resolves outside the root through a symbolic link, and a
  path part containing a colon. A refused path returns NIL, as a missing file does, so the
  caller's 404 applies. An app that meant to publish one of these files moves it, or binds
  `*default-deny*`. Matching ignores case and trailing dots and spaces, so `SCHEMA.SQL` and
  `schema.sql.` are refused too. (#296)

### Added

- **hyperion/static: `:deny` and `:allow` on `file-response`, and `make-static-handler`.**
  `:deny` adds patterns to the defaults: `"seed/"` for a directory, `"*.csv"` for a name
  anywhere, `"data/*.json"` for a path. `:allow` serves only paths under the listed prefixes.
  `make-static-handler` returns a handler for a root and logs its effective rules once, when it
  is made. `denied-by` says why a path is refused. (#296)
- **aion/http-client: fetching a URL a user supplied.**
  - `fetch-public` resolves the host itself and refuses the URL, with `fetch-refused` naming the
    reason, when any address it resolves to is loopback, private, link-local (which includes the
    metadata service at 169.254.169.254), or otherwise not public. It connects to the address it
    checked, follows redirects itself (checking every hop the same way, and dropping
    `Authorization` and `Cookie` on a redirect to another origin), and caps the body at
    `*fetch-public-max-body-bytes*` (10 MiB) unless told otherwise.
  - Requests gain `:follow-redirects` (NIL follows none; the default stays 5), `:max-body-bytes`
    (`response-too-large` past it), `:connect-address` (connect to this IP, keeping the URL's
    host name for the Host header, SNI and certificate verification) and `:ca-path`.
  - `address-category` classifies an address. `too-many-redirects` is signalled after
    `:max-redirects` hops.
  - Not on Windows: there dexador uses WinHTTP, and `:connect-address` and `fetch-public` signal
    `pinned-connect-unsupported` rather than connect without the pin. (#295)
- **hyperion/ratelimit: `wrap-rate-limit`, a rate limiter for sign-in, password reset and
  sign-up.** A request is refused with 429 and `Retry-After` once a limit's token bucket for it is
  empty. `make-limit` takes `:capacity`, `:per` (seconds), `:paths`, `:methods` (default POST
  only) and `:key`: `by-address` for the client address, or `by-form-field` for a submitted
  identifier such as the email address, trimmed and lowercased. An account-keyed limit never
  reads the account store, so it does not reveal whether an account exists. `reset-limit` gives
  a key a full bucket, for after a successful sign-in. Buckets are kept by `make-memory-store`,
  one process, at most `:max-keys` of them; a shared store implements `take-token` and
  `forget-bucket`. `*clock-ms*` can be rebound in tests. The recipe for guarding `auth-db`'s
  routes is `hyperion/docs/rate-limit.md`. (#297)

### Fixed

- **praxeon/retrieval: a section is identified by its document, its id and its locale.** Two
  documents may use the same section id, and `sync-document` never touches another document's
  rows. A translation's `:derived-from` names a section in its own document. Before this, two
  documents using the same id were refused by `sync-corpus`, and `sync-document` could delete
  the other document's rows. A chunk's `id` is now computed from its document as well. A chunk
  table made under v0.1.2 needs no change: a chunk keeps its old `id` until its section changes
  and is written again. (#310, review of #306)
- **praxeon/retrieval: `retrieve-similar` reads its candidates and its count of chunks not yet
  embedded in one snapshot**, so an `embed-pending` committing in between can no longer make a
  result that left a chunk out read as `complete`. (#310, review of #306)
- **praxeon/retrieval: `embed-pending` refuses a `:batch-size` that is not a positive integer**
  instead of embedding nothing and returning 0. (#310, review of #306)
- **praxeon: a directly made `openai-compatible` reads the settings of the backend it is for.**
  It has an `:impl`, which defaults to the backend `PRAXEON_LLM_IMPL` names when that is
  `openai`, `ollama` or `openrouter`, so with `PRAXEON_LLM_IMPL=openrouter` it reads
  `PRAXEON_LLM_*` and OpenRouter's URL again. After #291 it always read the `openai` settings.
  (#310, review of #291)

## v0.1.2 — 2026-09-27

Changes since `v0.1.1`. The tag is on `7cf8d72`.

### An app may have to act

- **praxeon/memory-db: `ensure-schema` no longer creates the `vector` extension.** It checks
  `pg_extension` and signals `praxeon/conditions:vector-extension-missing`, naming the database,
  when the extension is absent. On a managed Postgres the app's role usually cannot create it.
  Install it once per database as a role that can: `CREATE EXTENSION vector;`. (#138)
- **praxeon: the shared `PRAXEON_LLM_*` settings apply only to the backend `PRAXEON_LLM_IMPL`
  names.** A role that selects a different backend (`PRAXEON_<ROLE>_IMPL`) takes its settings from
  `PRAXEON_<ROLE>_*` or `PRAXEON_<IMPL>_*` only.
  - If that backend is `anthropic` or `openrouter` and neither `PRAXEON_<ROLE>_API_KEY` nor
    `PRAXEON_<IMPL>_API_KEY` is set, `make-provider-from-env` signals
    `praxeon/conditions:missing-provider-key`, which names both variables.
  - An app whose roles relied on `PRAXEON_LLM_API_KEY` for another backend sets one of those
    variables.
  - The `anthropic` and `openai-compatible` initforms follow the same rule.
  - An empty variable now counts as unset. (#291)
- **praxeon: embedding providers read only embedding variables, and there is no default embedding
  provider.**
  - Each setting comes from `PRAXEON_<ROLE>_EMBED_<SETTING>`, then `PRAXEON_EMBED_<SETTING>`, then
    the backend's own variable, then the backend's default.
  - The backend's own variables are `PRAXEON_<X>_API_KEY` and `PRAXEON_<X>_BASE_URL` for the key
    and the endpoint, and `PRAXEON_<X>_EMBED_MODEL` and `PRAXEON_<X>_EMBED_DIMENSIONS` for the
    model and the width.
  - `PRAXEON_<ROLE>_*` and `PRAXEON_LLM_*` are never read, including by the
    `openai-compatible-embeddings` initforms.
  - `make-embedding-provider-from-env` signals `praxeon/conditions:no-embedding-provider` before
    any request unless `PRAXEON_<ROLE>_EMBED_IMPL` or `PRAXEON_EMBED_IMPL` is set. It used to fall
    back to `openai` at `http://localhost:11434/v1`.
  - An app that embeds sets `PRAXEON_EMBED_IMPL`. An app that can work without embeddings
    handles the condition and uses exact search. (#291)
- **hyperion/desktop: `run-app` refuses cross-site and DNS-rebinding requests by default.** It
  puts `hyperion/csrf:wrap-same-origin` in front of an `:embedded` or `:hybrid` app. A request
  whose `Host` header is not `127.0.0.1:<port>` gets a 403, whatever its method, and so does an
  unsafe request (anything but GET, HEAD, OPTIONS, TRACE) unless `Sec-Fetch-Site` is
  `same-origin` or `none`, or, when that header is absent, `Origin` is
  `http://127.0.0.1:<port>`. The app's own pages, forms and HTMX requests pass unchanged. An app
  that reaches its local server under another name (such as `localhost`) or posts to it from
  another origin will now be refused; pass `:request-guard :none` to turn the check off, which
  logs a warning. (#293)

### Added

- **praxeon/retrieval: document retrieval over an app's corpora.** Load `praxeon/retrieval`.
  Postgres with pgvector only.
  - `make-chunk-store` (one table, `praxeon_chunks` by default, for every corpus) and
    `make-corpus`. A corpus is a name, so an app creates corpora at runtime without DDL.
  - `make-section` builds the record an app hands in. `sync-corpus` (at boot) and
    `sync-document` (on write) make a corpus hold exactly those sections, without an embedding
    provider. `embed-pending` embeds what has no embedding from the current model; `ingest` does
    both.
  - `retrieve-exact` (case-insensitive, never touches embeddings) and `retrieve-similar` (cosine,
    an exact scan of one corpus) return a `retrieval-result` whose completeness is `complete` or
    `truncated`, and passages carrying their `provenance`, including whether a translation was
    made from the current original. `passage->ctx-item` takes a required render function.
  - Syncs and `embed-pending` on one corpus are serialised across processes by a Postgres
    advisory lock.
  - `ensure-schema` signals `praxeon/conditions:vector-extension-missing` when the extension is
    absent, and `embedding-width-changed`, with a `recreate-embedding-column` restart, when the
    configured width differs from the table's. (#138)
- **mnemosyne/query: `:ilike`**, rendered as `ILIKE` on Postgres and refused on SQLite and
  XTDB, whose case rules differ. (#138)
- **praxeon: `voyage-embeddings`, a Voyage AI embedding provider**, registered as `voyage`.
  - Configuration: `PRAXEON_EMBED_IMPL=voyage` and `PRAXEON_VOYAGE_API_KEY`. The key is required;
    without one, `missing-provider-key` is signalled.
  - Defaults: base URL `https://api.voyageai.com/v1`, model `voyage-4`, width 1024. Override with
    `PRAXEON_VOYAGE_BASE_URL`, `PRAXEON_VOYAGE_EMBED_MODEL` and
    `PRAXEON_VOYAGE_EMBED_DIMENSIONS`, or the `PRAXEON_EMBED_*` variables.
  - Every request sends `truncation: false`, so an over-long text is an error rather than a vector
    for its beginning. (#292, #286)
- **praxeon: `embed-documents` and `embed-query`.** Every embedding provider answers both. Use
  `embed-documents` for text that is stored and searched, and `embed-query` for a search. Voyage
  sends `input_type` `document` or `query` accordingly; the OpenAI-compatible provider sends the
  same request for both. `db-memory-store`'s `remember` now embeds through `embed-documents`.
  (#292, #286)
- **praxeon: embedding calls are split into requests within each service's limits.**
  `embedding-max-texts` and `embedding-max-tokens` state them:
  - Voyage: 1,000 texts, and 320K tokens for `voyage-4`, 120K for `voyage-4-large`, 1M for
    `voyage-4-lite`.
  - OpenAI-compatible: 2,048 texts and 300K tokens.

  Results keep input order. A reply that carries a different number of vectors than texts sent
  signals `deliberation-failure`. (#292, #286)
- **praxeon: `remote-embedding-provider`**, the base class for an embedding service reached over
  HTTP. A new kind supplies `embedding-request-body` and its limits. `praxeon/llm:env-setting`
  resolves a chat setting by the same rules as `make-provider-from-env`. (#292, #291)
- **hyperion/csrf: `wrap-same-origin`, a CSRF defence for an app with no session.**
  `wrap-csrf` needs a session to hold its token; `wrap-same-origin` checks `Host`,
  `Sec-Fetch-Site` and `Origin` instead. Takes `:origins` (such as `"http://127.0.0.1:5000"`),
  `:hosts`, `:exempt` (skips the origin check only, never the Host check) and `:on-failure`.
  `check-host` and `check-same-origin` are exported for requests built by hand. A refusal is a
  `csrf-failure` with reason `:no-host`, `:host-mismatch`, `:cross-site`, `:no-origin` or
  `:origin-mismatch`. (#293)

### Fixed

- **mnemosyne/schema: `make-schema` adds the companion columns of a `:derived-from` field**
  (`<name>_fingerprint`, `<name>_deriver`), as `defschema` always did. A runtime schema with a
  derived field had no columns to record staleness in. (#138)
- **praxeon: `make-translator` with `:model` builds its provider.** It passed an `:auth` initarg
  that `anthropic` does not accept, so it always signalled an error. Its key now resolves as
  `PRAXEON_<ROLE>_API_KEY`, then `PRAXEON_ANTHROPIC_API_KEY`, then `PRAXEON_LLM_API_KEY` only when
  `PRAXEON_LLM_IMPL` is anthropic. (#291)

## v0.1.1 — 2026-09-27

Changes since `v0.1.0`.

### An app may have to act

- **hyperion/auth-db: by default, `make-db-auth` refuses to start unless the role-event log
  table exists.** An app that owns its migrations creates the table before upgrading; the
  migration is in `docs/migrations.md`. With `:ensure t`, `make-db-auth` creates it. With
  `:require-role-log nil`, the check is skipped. (#220)
- **hyperion/auth-db: one account per email address.** `create-user` refuses a duplicate it can see,
  but only a unique index holds when two processes insert at once, so an app should add it.
  `docs/migrations.md` adds the index (`20260729_002_index_users_email`, or
  `users-email-index-ddl`). Creating that index fails if the table already holds two accounts with
  the same email. (#224)
- **hyperion sessions expire on the server.** A session ends after `*session-idle-timeout*` without
  a request (default 86400 seconds, one day), and after `*session-absolute-timeout*` in total
  (default 604800 seconds, seven days). The session cookie's Max-Age now defaults to the absolute
  limit, and `ensure-session` records each access itself. An app that expected sessions to last
  indefinitely should set both limits. (#233, #256)
- **hyperion sends default security headers on every response.** Each header can be overridden. An
  app that sets the same headers itself, or that is embedded in another site's frame, should check
  the defaults. (#229)
- **On Windows, Hunchentoot is built with `:hunchentoot-no-ssl`.** An app on Windows cannot serve
  HTTPS from Hunchentoot itself; put TLS in front of it. Nothing loads OpenSSL on Windows when no
  TLS is used. (#259)
- **Dumped images run UIOP's image dump and restore hooks.** This covers `bin/cons`, desktop apps
  and new `cons` projects. `TEMP`, the user cache and ASDF's output translations now come from the
  machine the image runs on. Before this, a desktop app built on CI could not stage a self-update
  on a user's Windows machine.
  - A desktop app built with `scripts/build-desktop-app.lisp` gets the fix when it rebuilds.
  - An app whose own build script calls `save-lisp-and-die` needs two additions. This includes
    every project generated by `cons init` before this release. Add `(uiop:call-image-dump-hook)`
    before the dump, and `(uiop:call-image-restore-hook)` first in its toplevel. (#285)
- **`cons` templates ship their system definition as `{{name}}.asd.tmpl`.** This matters only to
  someone who wrote their own template by copying a built-in one. (#240)

### Added

- **aion/tls**, TLS over the pinned mbedTLS, with a memory-buffer engine and a blocking stream.
  This is step 2 of #125. Step 1 made the pinned mbedTLS and its C shim build on Linux, macOS and
  Windows. (#282, #273)
- **aion/boundary: `check-elements` and `check-optional`.** They check list elements and `Optional`
  values before CL code passes them into Coalton. (#242)
- **aion/windows/com.**
  - Records where each COM object came from, and names every reference still held
    (`describe-com-objects`). (#260)
  - Reads OLE dates before 1899-12-30 correctly, keeps the sub-second remainder, and gains a
    lossless date accessor. (#202)
- **mnemosyne reports which SQLite library file it loaded, and its version.** (#238)
- **praxeon token counts.** The `:usage` event carries all four token counts, and praxeon/web's
  token counter counts cache tokens too. (#179, #186)
- **Desktop releases.**
  - Windows desktop apps and their installers carry the app icon. (#248)
  - `desktop-release` builds the macOS `.app.tar.gz` update payload, and a release declares all
    three platforms. (#192)
- **On Linux the updater replaces the AppImage file.** (#276)

### Fixed

- **mnemosyne SQLite connections wait for another connection's write lock** instead of failing at
  once. They wait up to `*sqlite-busy-timeout-ms*`, which defaults to 5000. (#228)
- **hyperion writes sessions back after the handler runs**, so a database session store keeps
  sign-in, sign-out and CSRF state. (#231)
- **hyperion/markdown refuses script URLs in links and images**, and escapes every URL it writes.
  (#214)
- **hyperion/server `start` reports failures in the caller.** A port that is already taken, and a
  second live Woo server, are now signalled there instead of letting libev abort the process.
  (#188, #205)
- **hyperion's server-uv closes a finished connection's handle** on every path that ends the
  connection. (#265)
- **hyperion-view reads its command line as UTF-16 on Windows**, so non-ASCII window titles and
  icon paths survive. (#184)
- **The request's log context reaches lines logged from a turn thread and from parallel
  children.** (#226)
- **hyperion/dev warns once when no watched root holds Lisp.** (#217)
- **aion/test-threads names a thread that ran out of time**, and does not mistake its return values
  for a timeout. (#261)

### Setup

- **Pinned downloads are verified before use.** `setup.sh` and `setup.ps1` check SBCL and
  `quicklisp.lisp` against pinned SHA-256 sums. `hyperion/hyperion-view/build.ps1` checks the
  WebView2 SDK against the sum pinned in `scripts/versions.env`. (#212, #227, #176)
- **`setup.ps1` provisions SQLite differently.**
  - It installs the pinned SQLite as both `libsqlite3.dll` and `sqlite3.dll`, and its downloads
    survive an unreachable certificate-revocation server. (#247, #277)
  - `-Check` reports the SQLite library that a 64-bit SBCL actually loads. (#207, #279)
- **Setup installs Coalton's Quicklisp dependencies before anything loads Coalton**, and bootstrap
  builds the native webview launcher on a fresh clone. (#172, #174)
