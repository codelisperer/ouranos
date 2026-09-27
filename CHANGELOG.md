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

### Added

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
  the other document's rows. (#310, review of #306)
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
