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

- **aion/libgit: local git repositories, over a libgit2 this tree builds from source** (#429).
  A new opt-in system. `init-repository` and `open-repository` return a repository, and
  `with-repository` closes it. `stage` adds changed files to the index and removes deleted ones.
  `commit` commits the index with HEAD as its parent and returns the new commit id. `history`
  lists commits newest first, optionally only those that changed one path. `read-at-revision`
  returns a file's octets as they were at a revision, and `diff-text` returns the patch between
  two revisions as `git diff` prints it. A failed libgit2 call signals `git-error`, which
  carries libgit2's code, class and message. The library is libgit2 1.9.7, pinned in
  `libgit2.pin` and built by `scripts/build-libgit2.lisp` with a C compiler alone; it is
  GPLv2 with the linking exception. `aion/libgit` loads it from `AION_LIBGIT_LIBRARY`, beside
  the image, or `vendor/libgit2/lib/`. Fetching and pushing are not in this step. The gate
  runs its suite when `OURANOS_WITH_LIBGIT=1`, which CI sets.

## v0.1.7 — 2026-09-30

### An app may have to act

- **hyperion/dev: `serve` on loopback refuses a request whose Host is not `127.0.0.1:PORT` or
  `localhost:PORT`, and a cross-site POST.** It now starts its server with
  `:request-guard :same-origin`, the guard `run-app` has had since #302, because a development
  server holds real data on the developer's machine and a web page they visit could post to it,
  or read from it after a DNS rebinding. An app acts if its developers reach the dev server by
  another name: a hosts-file entry, a LAN address from a phone, or a proxy. Pass
  `:request-guard (:same-origin "http://NAME:PORT" ...)` with those origins, or
  `:request-guard :none`. On a host that is not loopback, `serve` stays unguarded and warns once.
  (#304)
- **hyperion/desktop: `shipped-image-p` and `install-directory` say whether this image is a
  shipped build and where it is, on every platform.** The rule was private to `hyperion/update`,
  so an app without the updater compared `sb-ext:*core-pathname*` with
  `sb-ext:*runtime-pathname*`. That is the test for a one-file image, and it answers "not
  shipped" inside a real macOS bundle (`sbcl` and `sbcl.core` in `<name>.app/Contents/MacOS`) or
  Windows bundle (`sbcl-runtime.exe` and `sbcl.core` beside `<name>.exe`). An app acts if it
  makes that comparison: call `hyperion/desktop:shipped-image-p` instead, and
  `hyperion/desktop:install-directory` for the `.app` on macOS or the app's directory elsewhere
  (NIL in a development image). The same answers are in `aion/platform` as `shipped-image-p` and
  `shipped-image-directory`, for code that does not load `hyperion/desktop`; `hyperion/update`
  now uses them and its private copy is gone. (#416)
- **hyperion/dev: `serve` on `:uv` runs handlers on 2 worker threads by default.** It passes
  `:server` and `:workers` to `hyperion/server:start` now (#432). Without workers, `:uv` runs
  every handler on its loop thread, and a handler that re-enters the loop, as a streaming one
  does, deadlocks there, so development behaved differently from a production entry point that
  passes `:workers`. An app acts if it develops on `:uv` (`HYPERION_SERVER=uv`) and relies on
  inline dispatch: pass `:workers nil`. Other backends keep `start`'s default. (#432)
- **A Windows desktop app refuses to start a `sbcl.core` that is not the one it was built
  with.** `<name>.exe`, the launcher, is compiled with the SHA-256 of the core built beside it
  and checks it before starting `sbcl-runtime.exe`. On a mismatch it exits with code 126 and says
  the file is not the one the app was built with: on standard error, or in a message box when it
  has no console. This is what makes a per-user install safe to sign: anything running as the
  user can write the install directory, and Authenticode does not cover the core. The check
  costs about 0.1 s at each start for a 100 MB core (measured on Windows 11). To have the hash,
  `scripts/build-desktop-app.lisp` on Windows now loads the app and dumps the core in a child
  process, and compiles the launcher afterwards. An app acts if its packaging changes
  `sbcl.core` after the build: rebuild instead, or the launcher refuses the result. (#98)
- **praxeon/translate: a translation cut off at the output limit signals
  `praxeon/conditions:translation-truncated` instead of being returned as the translation.**
  `translate`'s `:max-tokens` now defaults to NIL, which sizes the limit from the text:
  `translation-max-tokens` is twice the text's UTF-8 bytes plus 256, at least 1,024 and at most
  `praxeon/llm:*default-max-tokens*`. Before, the limit was a fixed 2,048, and a translation that
  reached it was returned cut off with nothing to say so. That became more likely once #326
  allowed a turn's reply of up to 8,192 tokens. The condition is a `deliberation-failure`, so an
  app's handler for a failed translation receives it, and it offers `retry-with-max-tokens` and
  `accept-truncated`; after `accept-truncated`, `translate` returns the cut-off translation with
  a second value, `:truncated`. With no handler, an app that translates `run-turn`'s reply now
  gets an error where it used to show part of a reply, so such an app adds one. `praxeon/elise` asks once
  more at twice the limit, and if that is cut off too, shows the whole English reply. The
  `translate` means that `register` installs fails rather than handing the agent part of a
  translation. The v0.1.4 note that `translate` is limited to 2,048 tokens and returns a
  cut-off translation without signalling no longer applies. (#338)
- **praxeon: `generate-structured` signals `structured-result-truncated` when the reply stopped
  at the output limit.** It is a `structured-result-invalid`, so an existing handler for an
  unusable result receives it. Before, a reply cut off before the tool call was reported as
  `structured-result-not-called`, and one cut off inside it was re-asked at the same limit
  until `:attempts` ran out. `retry-with-max-tokens` asks again with a larger limit without
  counting an attempt, and `accept-truncated` returns the cut-off arguments with a second value,
  `:truncated`. `structured-result-invalid-arguments` is now exported. (#338)
- **hyperion/server-uv: a server started with `:workers` now runs one event loop per core, up
  to 4.** Before, every server ran one loop. Handlers already ran on the workers, so what
  changes is that accepting, reading, parsing and writing use more than one thread, and the
  process has up to four loop threads instead of one. `:loops 1`, or `HYPERION_LOOPS=1` for
  `serve-forever`, keeps one loop. A server without `:workers` still runs one loop. (#463)

### Added

- **hyperion/server: `start` and `serve-forever` take `:request-guard`.** `:same-origin` puts
  `hyperion/csrf:wrap-same-origin` in front of the app, accepting `127.0.0.1:PORT` and
  `localhost:PORT` on loopback; `(:same-origin ORIGIN ...)` names the origins. The default,
  `:none`, is unchanged, because behind a reverse proxy on the same machine the guard would refuse
  every request. Turn it on for a desktop app's UI or a user's data served headless on 127.0.0.1.
  In `serve-forever`, the `:readiness-path` is exempt from the request guard, both its Host and
  its Origin check, so a health checker is never refused. When the server is not draining, a
  request for that path reaches the app's own handler unguarded, so an app must serve nothing
  there but a status: a DNS-rebinding page can read whatever that path returns.
  `hyperion/server:loopback-host-p` is exported. `hyperion/docs/middleware-security.md` has a
  table of which entry point is guarded by default. (#304)
- **aion/uv/net: `write-bytes` takes a list of octet vectors and strings, written in order as
  one write.** Each piece is copied straight into the write's buffer, so a caller with a head
  and a body no longer joins them into a new vector first. The future and `:on-complete`
  report the total octet count. `write-bytes` also copies its input in one bulk copy instead
  of one octet at a time. hyperion/server-uv uses the list form for every response, chunk and
  file head, and writes a list response body piece by piece instead of joining it first.
  Together with faster header checks in hyperion/http1 and asking a connection's peer address
  once instead of per request, this cut the server-uv loop thread's time per `/tile` request
  in `hyperion/bench` on macOS from about 61 µs to about 39 µs, and `/tile` went from about
  15,400 to about 22,800 requests/s. (#430)
- **praxeon/memory-db: a store on SQLite** (#425). `make-db-memory-store` takes
  `:dialect :sqlite` with a SQLite connection, so a desktop app can keep observations and
  recall them by similarity with no Postgres. The embedding is stored as text and
  `recall-similar` ranks the subject's current observations by cosine distance in Lisp; there
  is no index and no extension. `:dialect` other than `:postgres` or `:sqlite` is refused.
  `praxeon/llm` gains the pure functions both stores use for that: `vector-text`,
  `parse-vector-text` and `cosine-distance`.
- **praxeon/retrieval: a chunk store on SQLite** (#369). `make-chunk-store` takes a SQLite
  connection as well as a Postgres one, so an app can search its documents with no Postgres,
  offline for example. Every function behaves the same; the differences are listed in
  `praxeon/docs/user-guide.md` §12 under "On SQLite". The embedding is stored as text and
  similarity and BM25 are computed in Lisp; `retrieve-exact` folds the case of ASCII letters
  only; and syncs from two processes are serialised by SQLite's write lock, not per corpus.
  The retrieval suite runs every test on both backends, and prints a `BACKEND-CHECKS sqlite`
  line beside the Postgres one.
- **hyperion/server-uv with `:workers` encodes each plain response on the worker that ran its
  handler.** The event loop's thread then only writes it. A response whose body is a string, an
  octet vector or a list of them is encoded on the worker. A streamed body, a file, a HEAD
  request, a body on a status that carries none, and a header that is refused all take the
  loop's path as before. If a drain turns keep-alive off while the handler runs, the loop encodes
  the response again so that it says the connection closes. Inline dispatch, with no
  `:workers`, is unchanged. On macOS in `hyperion/bench` with 8 workers, the loop's time per
  request fell from about 33 µs to about 23.5 µs, and `/tile` went from about 29,000 to about
  41,000 requests/s. (#430)
- **hyperion/dev: `serve` takes `:server`, `:workers` and `:watch-framework`.** `:server` and
  `:workers` are passed to `hyperion/server:start`, so development can use the backend and
  handler threads production uses (#432). `:watch-framework nil` stops watching hyperion's own
  `src/`, for an app whose framework clone is pulled rather than edited; the default, `t`, is
  unchanged. (#438)
- **praxeon/conditions: `output-limit-reached`, the parent of every condition for a result cut
  off at the output limit**: `output-truncated` from `run-turn`, and the new
  `translation-truncated` and `praxeon/llm:structured-result-truncated`. Each is signalled inside
  `retry-with-max-tokens` and `accept-truncated`, so one handler on `output-limit-reached` can
  raise the limit or accept the cut-off result in all three. (#338)
- **praxeon/claude-code: a report on how much of a Claude Code session's reading comes from large
  tool outputs, and a PostToolUse hook that replaces a large search output with a checked
  summary.** (#452) `praxeon/scripts/build-claude-code.lisp` builds `bin/praxeon-claude-code`.
  - `praxeon-claude-code report [--days N] [--threshold TOKENS]` reads
    `~/.claude/projects/*/*.jsonl` and subagent transcripts and prints counts only: model calls
    and their token usage, tool results by category with how often each was read again, how
    many the hook would replace, and an upper bound on the saving.
  - `praxeon-claude-code hook` replaces the output of `rg`, `grep`, `find`, `fd` and MCP tools
    above 3,500 tokens with a list of facts from a second model, after checking that every path,
    identifier and number in the list occurs in the output; otherwise it prints nothing and the
    original passes through. It never replaces reads, diffs, failed commands, credential-shaped
    text in the output or the command, outputs Claude Code already saved to a file, or output
    carrying SHAs or run ids. The raw output is archived 0600 under the user's cache directory.
    Settings, all environment variables: `PRAXEON_CC_BACKEND` (`claude`, the default, for the
    `claude` CLI, or `praxeon` for a `praxeon/llm` provider with the role `compressor`),
    `PRAXEON_CC_MODEL`, `PRAXEON_CC_EFFORT`, `PRAXEON_CC_CLAUDE`, `PRAXEON_CC_THRESHOLD`,
    `PRAXEON_CC_SUMMARY_BUDGET`, `PRAXEON_CC_TIMEOUT`, `PRAXEON_CC_ARCHIVE_DAYS` and
    `PRAXEON_CC_CACHE_DIR`. Installing it is described in `praxeon/docs/claude-code-hook.md`.
- **hyperion/server-uv: `:loops`, the number of event loops a server runs, each on its own
  thread.** It is a keyword of server-uv's `start`, of `hyperion/server`'s `start` and
  `serve-forever` (which read `HYPERION_LOOPS`), and of `clack.handler.uv`'s `run`. Its default
  is `*default-loops*`, `:auto`: one loop when handlers run inline, otherwise the online cores,
  at most 4. Four because nothing measured more: on a 10-core Mac, 6 and 8 loops served no more
  than 4, and the 4-core Linux host could not run more loops than cores. More than one loop needs `:workers` or a pool `*dispatch*`; with the inline
  dispatcher, `start` refuses. How new connections reach the loops is `:scheme`
  (`*default-scheme*`): `:reuseport`, one SO_REUSEPORT listener per loop, the default on Linux;
  `:handoff`, where the first loop accepts and hands connections to the loops in turn, the
  default on macOS and other Unix; or `:shared`, a copy of one listening socket on every loop. Windows always runs one loop. `server-loops` and
  `server-loop-connections` report the loops and how many connections each has taken. On a
  4-core Linux host with 8 workers, `/tile` in `hyperion/bench` went from 31,724 requests/s on
  one loop to 119,501 on four. `aion/uv/net` gains `listen-tcp`'s `:reuseport`, and
  `listen-copy`, `detach-socket` and `adopt-tcp-socket`, which move sockets between loops on
  Unix. (#463)

### Fixed

- **`scripts/build-mbedtls.lisp` honours `OURANOS_MSVC_PATH`.** It had its own copy of the MSVC
  discovery, which asked vswhere for the newest install only, so on a machine with several Visual
  Studio installs the variable chose the toolchain for libuv and the Windows launcher but not for
  mbedTLS. It now uses `scripts/msvc.lisp`, as `build-libuv.lisp` and `build-desktop-app.lisp` do,
  and a path that is not an installation is refused before anything is downloaded. (#410)
- **aion/pool: a job finishing no longer wakes every idle worker.** `%finish-job` broadcast on
  the pool's waitqueue after every job, and the only threads waiting there are idle workers,
  so each completion woke all of them to find nothing to do. With hyperion/server-uv's
  `:workers`, that made the event loop wait for the pool's lock on every request. On macOS in
  `hyperion/bench`, `/ping` with 8 workers went from about 24,000 to about 30,400 requests/s
  and the server from 2.2 to 1.16 cores. (#430)
- **hyperion/html: `autocomplete` on `<textarea>` compiles without a WARNING.** It is valid HTML,
  but Spinneret's attribute table does not list it there and signals a full WARNING while
  compiling the template. That failed an ASDF build and, under `hyperion/dev`, the reload of the
  whole file. Hyperion now exempts it, as it already exempts `hx-` and the other client-framework
  prefixes (`*spinneret-missing-attributes*`), so an app that passed it through `:attrs`, or
  pushed it onto `spinneret:*unvalidated-attribute-prefixes*` itself, can stop. (#439)
- **`clack:stop` on a `:server :uv` handler stops the server even when it is called as soon as
  the port listens.** The port listens before server-uv's `start` returns, and `clack:stop`
  kills the thread that `run` blocks in. A kill that landed after the server started and
  before `run` could stop it on the way out left the server listening for as long as the image
  ran. `run` now starts the server with interrupts deferred, inside the cleanup that stops it.
  (#444)
- **hyperion/server-uv sent the handler's body in responses to HEAD requests; it now sends the
  status line and headers only, with the Content-Length a GET would get.** On a kept-alive
  connection the extra octets were read as the start of the next response. A streamed body's
  function is no longer called for HEAD, and a file body is not read. Hyperion's router already
  stripped the body for routes it serves, so this affects Clack apps on `:server :uv` and
  handlers that do not go through the router. (#449)
- **hyperion/dev: a failed reload stays in the browser until the file loads, and says what
  happened.** A Lisp file whose compile ended with a full `WARNING` failed its reload, and the
  error reached the browser overlay, but the next change, such as a stylesheet, found no Lisp to
  compile, cleared the error and refreshed the page. The failed file was not tried again until
  it was edited, so from the browser hot reload looked broken and the file's changes never
  loaded. A failed file is now retried with every later change, and the overlay keeps its error
  until it compiles; other changes still refresh the page. The message names the file and says
  that the running code is the version from before the change. When a structure's layout
  changed, which a running image cannot load, for example after pulling the framework clone
  under a running dev server, the message starts with "RESTART NEEDED". (#438)

## v0.1.6 — 2026-09-30

Changes since `v0.1.5`. The tag is on `905d80f`.

### An app may have to act

- **hyperion/update: `check-for-update` and `apply-update` check the manifest's product against
  `*app-name*` by default.** Before, `:product` defaulted to NIL and the product was not checked
  unless a caller passed it. An app whose `*app-name*` is not the `product` its manifests carry
  now gets the `manifest-mismatch` block. Set `*app-name*` to the manifest's product, which is
  also the name the Windows installer registers under `HKCU\Software\<name>`. (#301)
- **praxeon/retrieval: `ensure-schema` adds six more columns to the chunk table and creates a
  corpora table** (#316): `section_index`, `document_fingerprint`, `context`, `context_deriver`,
  `context_document_fingerprint` and `input_fingerprint`, and `<table>_corpora`, one row per
  corpus with its size and strategy. They are created the same way, with `IF NOT EXISTS`.
  Embeddings made before them stay current. Until a document is synced again, `retrieve-whole`
  orders its sections by section id. A test or tool that drops the chunk table drops
  `<table>_corpora` too.
- **praxeon/retrieval: `retrieve` on a corpus made with no `:strategy` returns the whole corpus
  while it is below 200,000 estimated tokens.** `make-corpus` defaults to `:auto` (see Added).
  An app that wants search at every size makes the corpus with `:strategy :hybrid`. (#316)
- **cons/coalton-repl: `eval-input` can return a result of kind `:exit-requested`, and runs
  each evaluation on a thread of its own.** An input that asks to end the process, `(exit)`
  or `(quit)` or a `lisp` escape naming `sb-ext:exit`, `sb-ext:quit` or `uiop:quit`, is not
  evaluated; `process-ending-p` is the test. An app that dispatches on `result-kind` with
  `ecase` adds a clause for `:exit-requested` and decides what it means: the desktop example
  closes, and a REPL served to other people refuses. Because the evaluation runs on its own
  thread, a dynamic binding the caller made around `eval-input` is not seen by the code being
  evaluated; set the global value instead. A second input that arrives while one is running
  gets an `:error` result at once. (#355)
- **hyperion/update-ui: `*poll-interval*` defaults to `"360m"`, and a value htmx would misread
  is refused.** The default was `"6h"`. The htmx this tree ships (1.9.12) reads only `ms`, `s`
  and `m`, and reads anything else with `parseFloat`, so `"6h"` meant 6 milliseconds: every page
  with the update banner asked `/_hyperion/update/status` for its status many times a second.
  `update-mount` and `update-banner` now check the value each time they render the trigger
  (`checked-poll-interval`). They signal `invalid-poll-interval` for anything that is not a
  number followed by `ms`, `s` or `m`, such as `"6h"`, `"1d"` or a bare `"5000"`, and for
  anything shorter than 1 second.

  An app acts if it sets `*poll-interval*`: write hours as minutes (`"360m"`, not `"6h"`) and
  give a unit, or the first page that renders the banner signals the error. An app that kept
  the default needs no change; it stops flooding its status route. (#422)
- **hyperion/server, hyperion/server-uv: `serve-forever` drains on SIGTERM instead of refusing
  requests at once** (#388). A rolling deploy sends SIGTERM while the platform may still route
  requests to the old instance. Until now every backend stopped accepting at once and cut off
  requests in flight, and on Woo the process never exited at all. Now, on SIGTERM:
  - for `:drain-seconds` (`HYPERION_DRAIN_SECONDS`, default 5) the server keeps accepting and
    answering, and `:readiness-path`, when given, answers 503;
  - on `:uv`, it then stops accepting and waits up to `:drain-timeout`
    (`HYPERION_DRAIN_TIMEOUT_SECONDS`, default 20) for requests in flight to finish;
  - whatever is left is closed.
  Each phase is logged once. An app acts by keeping `drain-seconds + drain-timeout` below its
  platform's termination grace period, and by pointing the platform's health check at
  `:readiness-path` if it wants the instance taken out of rotation during the grace period.
  SIGTERM now takes up to 25 seconds by default where it took about 2. Ctrl-C, SIGINT and
  `request-shutdown` still stop at once. Hunchentoot gets the grace period and then stops as
  before; Woo still does not see SIGTERM, and is still ended by SIGKILL. `hyperion/server-uv`
  gains `begin-drain`, `draining-p` and `stop :drain-timeout`; a plain `stop` is unchanged. See
  `hyperion/docs/signals-and-shutdown.md`, "Draining on SIGTERM".
- **A Windows desktop app is now three files: `<name>.exe`, `sbcl-runtime.exe` and
  `sbcl.core`, and building one needs MSVC.** `scripts/build-desktop-app.lisp` no longer dumps
  one executable on Windows. `<name>.exe` is a launcher compiled from
  `scripts/windows-launcher.c` with `cl.exe`. It starts `sbcl-runtime.exe`, a copy of the SBCL
  runtime, with `sbcl.core` beside it, the heap the build used, and the app's own arguments
  unchanged, and it exits with the app's exit code. This is the shape a code signature can
  cover: Authenticode appends its signature where a dumped image keeps its core, so a signed
  dumped image did not start (#98).

  An app acts if its packaging copies only `<name>.exe` (the installers in `scripts/installers/`
  copy the whole bundle and need no change), or if it signs, hashes or inspects that one file:
  the runtime is `sbcl-runtime.exe` beside it, and Task Manager shows that process under that
  name. A machine that builds a Windows desktop app needs the Visual Studio Build Tools with the
  C++ workload, as a Mac needs `cc`; without them the build exits with code 3 and says so.
  `--icon` goes into both executables. `hyperion/update` recognises the new shape as a shipped
  build (`%shipped-image-p`). `verify-bundle-windows.ps1` treats `sbcl-runtime.exe` as a helper
  and traces it as the launcher's child. Linux builds are unchanged. (#98)

### Added

- **hyperion/session: `wrap-session :secure :auto`, or a function, decides the cookie's
  Secure attribute per request.** (#300) `:auto` sets it when the request came over https: the
  env's `:url-scheme`, or `X-Forwarded-Proto` when it came through a proxy the app trusts,
  read through `hyperion/proxy:request-scheme` and the same `*trusted-proxy*` setting that
  `client-address` reads (#381). A function of the env decides it too. `t` and `nil` are
  unchanged. One middleware then serves a site that runs on plain http in development and
  behind a TLS proxy in production, which SoloFlow's website does today by building the
  middleware twice.
- **praxeon: a reranker, and reranked hybrid search.** (#316)
  - `praxeon/llm:reranker` is a protocol of its own, like `embedding-provider`: `rerank` returns
    each document's index and score, best first, and refuses a reply that does not score every
    document once. `voyage-reranker` is the first backend (`rerank-2.5` by default), and
    `make-reranker-from-env` chooses one from `PRAXEON_[<ROLE>_]RERANK_IMPL`; with none set it
    signals `praxeon/conditions:no-reranker`.
  - `retrieve-hybrid`, `retrieve` and `register-corpus-search` take `:reranker`, which reorders
    the first `*rerank-candidates*` (150) merged candidates before the limit is taken.
    `evaluate-retrieval :reranker` reports a `:reranked` configuration as well.
- **praxeon/retrieval: a context for each chunk, and a strategy chosen by the corpus's size.**
  (#316)
  - `make-corpus` takes `:strategy` (`:auto`, the default, `:whole` or `:hybrid`),
    `:whole-limit` (`*whole-limit*`, 200,000 estimated tokens), `:expected-tokens`,
    `:contextualizer` and `:backfill` (`:automatic` or `:explicit`).
  - `retrieve-whole` returns every chunk in the order the app handed the sections in.
    `corpus-size` estimates a corpus's tokens, and a sync reports it in `sync-report-size` with
    `sync-report-strategy`. `corpus-effective-strategy` says which strategy `retrieve` follows.
    When an `:auto` corpus changes strategy, the sync logs it once through `aion/log`.
  - `make-contextualizer` takes a chat provider. `contextualize-pending` asks it for one or two
    sentences placing each chunk in its document, with the document before the prompt-cache
    marker, and writes them, so the chunk's embedding and BM25 terms cover the context and the
    text. `passage-context` is the context; `passage-text` is still the chunk's own text. A
    context is written again when anything in its document changes, or when the provider,
    model, instruction or answer limit does. It does nothing while the corpus is `:whole`.
  - `contextualize-pending :ledger` charges each call to a `praxeon/ceiling` ledger and signals
    `budget-exhausted` before a call the ledger cannot afford, keeping the contexts written.
    A context that stops at the contextualizer's answer limit signals `deliberation-failure`
    rather than being stored cut off. `start-backfill` releases the backfill of a corpus made
    with `:backfill :explicit`.
  - `ingest` now also calls `contextualize-pending`, before `embed-pending`, and takes `:ledger`.
  - `retrieve` follows the corpus's strategy: every chunk in document order for a `:whole`
    corpus, and `retrieve-hybrid` with a default `:limit` of 20 for a `:hybrid` one
    (`retrieve-keyword` when the embedder is NIL). The v0.1.5 entry for `retrieve`, which
    describes it as `retrieve-similar` for every corpus, no longer applies.
- **cons/coalton-repl: `eval-input` takes `:time-limit`, in seconds, and `cancel-evaluation`
  stops a running evaluation from another thread.** Either way the result is an `:error`
  saying why, and the session can evaluate again. The stop is signalled as a
  `serious-condition`, so `ignore-errors` in the user's own code does not swallow it. (#355)
- **hyperion/desktop: `request-close` closes the window `run-app` is showing, from any
  thread**, and `run-app` then stops the server and returns. `run-app` takes `:workers`,
  passed to `hyperion/server:start`: an app whose page makes a second request while a slow one
  runs, such as a cancel button, needs at least 2 on Woo. (#355)

### Fixed

- **aion/fs: on Windows, `delete-tree` retries a delete that another process blocks for a
  moment.** A file can stay open briefly after the process that used it exits, for example
  while antivirus scans an executable that has just run, and the delete then failed at once
  with a sharing violation (error 32), which made a CHECKERS/TESTS run fail on Windows. A
  delete that fails with error 5, 32 or 145 is now tried again for up to 3 seconds
  (`aion/fs::*transient-retry-seconds*`) before `delete-tree-error` is signalled. What
  `delete-tree` refuses is unchanged: a link is still removed as a link, and a root that is a
  link is still refused at once. (#402)
- **mnemosyne: a SQLite transaction whose `COMMIT` is refused is rolled back** (#400). SQLite
  refuses a `COMMIT` with `BUSY` while another connection holds a read lock, and keeps the
  transaction open so the `COMMIT` can be retried. `with-transaction` did not roll it back, so the
  connection stayed inside that transaction: its later statements were never committed, and its
  write lock made every other connection's writes fail with "database is locked" until it was
  closed. `with-transaction` now rolls the transaction back and signals the refusal as a
  `mnemosyne/conn:db-error`; it used to reach the caller as a `sqlite:sqlite-error`.
- **hyperion/update-ui: `update-router` takes `:channel` and `:product` and passes them to both the
  status and the apply route.** Each is a string or a function of the request env. Before, both
  routes used the stable channel and no product, so an app that checked on beta and mounted the
  router with `:check nil` had Apply re-check against stable. The apply path's second manifest
  fetch now also refuses a manifest for another channel. (#301)
- **hyperion/auth-db: `make-db-auth … :ensure t` creates the store's own table names.** (#378)
  It created `hyperion_users` and `hyperion_role_events` whatever `:table` and `:events-table`
  said, while every query used the store's names, so a store made with other names failed at
  its first statement on a table that did not exist. `users-ddl` and `role-events-ddl` now take
  `:table`, as the two index helpers already did, and every one of the four refuses a name
  that is not letters, digits and underscores.
- **hyperion/desktop: the window closes when the app's process exits, and an exit from another
  thread takes a second instead of a minute on Windows.** `run-app` blocked in
  `uiop:wait-process` on the launcher, where the main thread cannot be interrupted. When code
  on another thread called `sb-ext:exit`, SBCL waited `sb-ext:*exit-timeout*` (60 seconds) for
  the main thread, with the server no longer answering, and the process then ended with the
  window still open. `run-app` now polls, and stops the launcher whenever it is left other than
  by the window closing. (#355)
- **The desktop Coalton REPL example: `(exit)` and `(quit)` close it, an evaluation stops after
  30 seconds or when its stop button is pressed, and the page says so when the backend stops
  answering.** Served with `serve` or `dev`, `(exit)` is refused instead. (#355)

## v0.1.5 — 2026-09-30

Changes since `v0.1.4`. The tag is on `f3fdf1a`.

### An app may have to act

- **praxeon/retrieval: `ensure-schema` adds two columns to the chunk table and creates a terms
  table.** The chunk table gains `term_count` and `terms_tokenizer`, and `<table>_terms` holds
  each chunk's terms for keyword search (#316). Both are created with `IF NOT EXISTS` the next
  time the app calls `ensure-schema`, or makes the store with `:ensure t`; the app's role needs
  the right to alter its own table and create one next to it. Chunks synced before then count
  as not indexed for keyword and hybrid search until `index-pending` (or `ingest`) writes their
  terms. Similarity and exact search are unaffected. A test or tool that drops the chunk table
  drops `<table>_terms` too.
- **hyperion/auth-db: a `make-db-auth` store over one connection is safe to share between
  request threads, and `make-db-auth` takes a pool.** (#371)
  - **The hazard.** Only a store's writes (`create-user`, `grant-role`, `revoke-role`,
    `set-password`) took its lock. Its reads (`find-user-by-id`, `find-user-by-email`,
    `authenticate`, `users-with-role`, `role-history`) used its one connection unlocked, so two
    request threads could send statements on it at once. On Postgres one of them failed with
    "This connection is still processing another query": 9 of 60 concurrent page loads in a
    consuming app that had turned on `:workers`, and 56 of 60 concurrent lookups in this
    change's test. The v0.1.4 note that an app sharing one connection uses `wrap-connection`
    before turning on `:workers` did not cover this: the store holds a connection of its own,
    which `wrap-connection` does not replace. An app on Hunchentoot, which runs each connection
    on its own thread, had the same hazard before v0.1.4.
  - **The workaround, until an app has this change.** Make a store for each pooled connection
    and use the one for the request's connection, as the app that found this does (180 of 180
    concurrent requests answered).
  - **The fix.** Every operation now takes the store's lock over one connection, reads
    included. And `make-db-auth` accepts a mnemosyne pool in place of a connection: each
    operation then borrows a connection, which inside `wrap-connection` on the same pool is the
    request's own, so reads on different threads run at once. An app serving with `:workers`
    passes its pool: `(make-db-auth pool :dialect :postgres)`. An app that keeps passing one
    connection needs no change and is now safe, with its lookups taking turns.
- **cons: `cons build`, `cons test` and every `:load` or `:test` target fail on a full compile
  `WARNING` in the project's own code, and print it.** They loaded through `ql:quickload`, whose
  quiet mode muffles every warning, so such code built and tested with exit 0. An app whose own
  code has a full `WARNING` will now fail; fix the warning. `STYLE-WARNING`s still do not fail.
  Libraries, and the framework, are still loaded with warnings muffled. The same applies under
  `cons --fresh` and to `:isolate` targets. (#303)

- **hyperion/update: on Linux, update staging directories are made in
  `<XDG_CACHE_HOME>/ouranos-update/`, normally `~/.cache/ouranos-update/` (mode 700), not in the
  temp directory.** On Windows and macOS they stay in the per-user temp directory. The sweep that
  removes old `ouranos-update-<time>-<hex>` directories looks in the same place, and removes only
  real directories this user owns. An app that cleans up after the updater, or looks for a
  staged installer, looks in the new place on Linux. (#347)
- **hyperion/server-uv: a request body sent with `Transfer-Encoding: chunked` reaches the
  handler, where it used to be refused with 501** (#374). The handler gets the decoded body as
  `:raw-body` and `:content-length` NIL, as under Hunchentoot and Woo. An app acts if a handler
  sizes its read of `:raw-body` by `:content-length`: it now meets NIL for such a request, and
  reads to the end of the stream instead. Only the single coding `chunked` is decoded; any
  other `Transfer-Encoding` is still 501, one in an HTTP/1.0 request is 400, and one alongside
  `Content-Length` is 400 as before. The decoded body counts against `*max-body-octets*`, and
  the chunk framing against the new `*max-chunk-overhead-octets*` (1 MiB); either answers 413.
  Trailer fields are checked and discarded. `hyperion/http1` gains `Body-Chunked`,
  `head-chunked?` and the step functions `parse-chunk-size-line`, `parse-chunk-data-end` and
  `parse-trailers`.
- **klio: a scheduled document is no longer published before its `publish-at`.** `site-app`
  judged visibility with no clock unless given `:now`, which skipped the schedule, so a
  document with a future `publish-at` was served at once (#359). Each request is now judged at
  its own time, and so is any caller of `tree-readable-documents` that passes no `:now`.
  `publish-at` is parsed at load as an ISO 8601 date (`2030-01-01`, midnight UTC) or date and
  time (`2030-01-01T09:00:00Z`, or with an offset such as `+02:00`), and a value that is not
  one fails the load, naming the file, instead of publishing. A site whose pages carry a future
  `publish-at` will see them disappear until that time. `content-meta-publish-at` is now a
  universal time. A `date` that is not ISO 8601 is a load warning, and the page is left out of
  the feeds.

### Added

- **praxeon/retrieval: keyword search by BM25, hybrid search, and a way to measure them.**
  (#316)
  - `retrieve-keyword` ranks a corpus's chunks by BM25 (`*bm25-k1*` 1.2, `*bm25-b*` 0.75),
    computed in one SQL statement, so it needs no Postgres extension. `passage-score` is the
    score.
  - `tokenize` and `term-counts` are the tokenizer, and `register-stop-words` adds a language's
    stop words (English is built in). `index-pending` writes the terms of chunks that have none
    from the current tokenizer. The result reason `:not-indexed` counts them.
  - `retrieve-hybrid` merges up to `*hybrid-candidates*` (150) results from similarity and from
    BM25 by reciprocal rank fusion (`*rrf-k*` 60), and returns each chunk once. The merge is
    `praxeon/retrieval/fusion`, in Coalton.
  - `evaluate-retrieval` reports, for `:similar`, `:keyword` and `:hybrid`, how often the section
    that answers each `make-eval-question` is in the top `:k`.
  - `ingest` now also calls `index-pending`.
- **hyperion/ratelimit: a limit that counts only failed attempts, and a limiter an app can
  call inside its own bindings.** (#323)
  - `make-limit` takes `:count-when`, a function of the env and the response. Before the
    handler, such a limit refuses only when its bucket is already empty. After the handler, it
    takes a token only when `:count-when` returns true, and always when the handler signals.
    `(unless-status 303)` counts every response that is not a 303.
  - A successful sign-in then costs nothing and restores nothing, so members signing in
    together from one address are not refused. An app that called `reset-limit` on the address
    limit after a successful sign-in, as a workaround, should stop: the recipe advises against
    it. `hyperion/docs/rate-limit.md` now counts sign-in failures per address this way.
  - `call-with-rate-limit` and `with-rate-limit` run the limiter as a function, so its
    `:on-limited` refusal is built inside whatever bindings the app has made. `wrap-rate-limit`
    is now that function as middleware, with no change in behaviour.
  - The store protocol gains `check-token` and `debit-token`, next to `take-token` and
    `forget-bucket`. A store written for the old protocol still serves limits without
    `:count-when`. `memory-store` implements all four.
- **praxeon/retrieval: `paragraph-chunker`, which cuts a long section at blank lines.** Pass it as
  `(make-corpus store name :chunker (make-instance 'paragraph-chunker))`. A section of up to
  `:long-section` characters (default 1500) stays one chunk with boundary `:whole-section`, as with
  `section-chunker`. A longer one becomes runs of whole paragraphs of up to about `:target`
  characters (default 900), with boundary `:whole-paragraph` and sub-locators `"part 1"`,
  `"part 2"` and so on. A paragraph is never split. A line holding only spaces, tabs or a
  carriage return counts as blank. `chunker-id` includes both settings, so changing either one
  re-chunks the corpus on its next `sync-corpus`. An app that wrote its own chunker for long
  sections can use this one instead. (#322)
- **praxeon/retrieval: an agent can search a corpus.** `(register-corpus-search agent corpus
  embedder render)` registers a means, `"search-documents"` unless `:name` says otherwise. The
  model passes a `query`, and a `match` of `"meaning"` or `"words"`; with a NIL `embedder` only
  `"words"` is offered. It reads each passage as `render` writes it, through `passage->ctx-item`,
  in the order the search returned them, and a sentence when the result is truncated.
  `:on-result` receives the query and the `retrieval-result`, so an app can keep what it will
  cite. `:description`, `:limit` and `:capability` are optional. (#138)
- **praxeon/retrieval: `retrieve`**, the call an agent's search makes. For a corpus it is
  `retrieve-similar` with a default `:limit` of 20; a later version will follow the corpus's
  retrieval strategy (#316) with no change for callers. (#138)
- **cons: `--strict` recompiles the project's own systems before a target runs**, so a warning
  in a fasl that is already current is seen. Use `cons --strict test` in CI. The loader is
  exported as `cons/run:load-system-strictly` for a script that needs the same rule. An app whose
  CI added its own strict-build step as a workaround, such as `scripts/build-strict.lisp`, can
  replace it with `cons --strict test`. (#303)
- **aion/fs: `delete-tree`, a directory-tree delete that never follows a link out of the tree.**
  A Windows junction or other reparse point, or a symbolic link, inside the tree is removed as a
  link, and what it points to is left alone; a root that is a link signals `link-root-refused`.
  `delete-link` removes a link and nothing else, and `link-p` sees Windows junctions, which
  `truename` does not. It needs only UIOP, and `sb-posix` on Unix. An app that removes directory
  trees with `uiop:delete-directory-tree` can use it instead. (#347)
- **aion/fs: `file-attributes`, a file's Windows attributes asked of Windows.** It returns keywords
  such as `:read-only`, `:hidden`, `:directory` and `:reparse-point` through `GetFileAttributesW`,
  with the path passed as UTF-16, so non-ASCII names and names with `[ ]` work; a string is used
  as the native path without being parsed. It signals `file-attributes-error` with the Windows
  error code when Windows cannot answer, and signals on other systems. `aion/windows` re-exports
  it. An app that parses `attrib.exe` for a read-only check can call this instead: `attrib.exe`'s
  output did not decode for a non-ASCII path, and the check answered "not read-only". (#349)
- **hyperion/proxy: the client's address behind a trusted proxy, and one setting for it.**
  (#381) `hyperion/proxy:*trusted-proxy*`, made with `make-proxy-trust` (`:hops N`, or
  `:cidrs` with an optional platform `:header` such as `CF-Connecting-IP`), says which proxies
  the app trusts. `client-address` then reads `X-Forwarded-For`, or the platform's header, only
  as far as those proxies vouch for it, so a forged leftmost entry changes nothing.
  `hyperion/ratelimit:by-address` and the request log's `remote` field use it, so rate limits
  count each real client behind a proxy. `request-scheme` reads `X-Forwarded-Proto` under the
  same setting, for #300. With no setting, the default, nothing changes: the address is
  `:remote-addr`.
- **praxeon: large tool results can be kept out of the prompt and read back by handle, and
  older results cleared in batches.** (#319)
  - `praxeon/actor:offload-tool-results` keeps an agent's tool results in a
    `praxeon/results:result-store` (`make-memory-result-store`, or `praxeon/results-db`'s
    `make-db-result-store` over a mnemosyne connection or pool). A result over `:threshold`
    estimated tokens goes into the conversation as a stand-in naming the tool, its arguments,
    its size, its first lines and a handle.
  - The agent gets a `read-result` means: a range of lines or characters, or the lines holding
    a string, returned exactly as stored.
  - `:clear-budget` replaces older results by short stand-ins in what is sent, in batches that
    take the messages down to `:clear-target`, keeping the last `:keep-recent` results and
    those of the means in `:never-clear`. The history keeps them, and the start of the prompt
    changes only when a batch is cleared.
  - `forget-agent-results` erases a conversation's stored results.
  - Nothing is on by default. `praxeon/bench/tool-results.lisp` measures task success, input
    tokens and the cacheable share under each configuration, with a scripted model or a real one.
- **hermes: email attachments, so an invitation can carry a calendar file.** (#366)
  `make-email` takes `:attachments`, a list of `make-attachment` values: `:filename`,
  `:content-type` with its parameters (`"text/calendar; charset=utf-8; method=REQUEST"`),
  `:content` as a string (sent as UTF-8) or an octet vector, and `:disposition` (`:attachment`,
  or `:inline` with a `:content-id`). SendGrid gets each one base64-encoded in its
  `attachments` array. The dev transport prints each attachment's name, type and size, and
  `dev-last-email` returns the last email it was given, so a test can check that an `.ics` went
  out. A value that cannot be sent signals `invalid-message` when it is made. An email without
  attachments is sent exactly as before.
- **hyperion/server-uv: `*max-head-octets*`, the largest request head accepted before 431.**
  The default is 65,536, the limit the parser has always applied. An app whose clients send
  larger headers can raise it; each connection may then hold that much memory before its
  request is complete. `hyperion/http1:parse-head-limited` takes the limit as an argument, and
  `parse-head` still uses the default. Clack's handler suite sends a 96,000-octet header
  value, which is refused at the default (#375).
- **hyperion/clack-handler-uv: hyperion's own server as a Clack handler.** Load the system,
  then `(clack:clackup app :server :uv)` runs any Clack app on `hyperion/server-uv`, and
  `clack:stop` stops it. The env is Clack's whole environment, including `:script-name`,
  `:request-uri`, `:url-scheme`, `:server-name`, `:server-port`, `:server-protocol` and
  `:remote-port`, with `:path-info` percent-decoded as UTF-8. The response may be a list of
  strings, an octet vector, a pathname, or a delayed response whose responder returns a writer
  taking `(data &key start end close)`; a header whose value is NIL is not sent. `:workers`, or
  `:worker-num` as Woo's handler takes it, sets the worker pool, 16 by default. Clack's own
  handler cases, from Clack 2.1.0, are ported to FiveAM and pass, the streaming case included.
  server-uv's env gains `:server-protocol` and `:remote-port`. (#373)
- **scripts/build-desktop-app.lisp: `--carry <path>` carries a native library of the app's own
  into the bundle.** Give it once per library, for example a PDF renderer in the app's
  repository or a pinned `sqlite3.dll`, which stock Windows does not have. The file is copied
  beside the executable with its license text under `LICENSES/`: the files and directories named
  `LICENSE*`, `COPYING*` or `NOTICE*` beside it or in the directory above, or, for a library that
  ships none, such as public-domain SQLite, the files named by `--carry-license <file>` after its
  `--carry`. If the image has the library open, the app opens the
  copy beside its executable when it starts, and stops with exit code 3 naming the file if the
  copy is missing. An app that added its own post-build copy step for such a library can
  remove it. The build refuses a path with no license text, a path under the tree's `vendor/`,
  and two paths with one file name. (#78)

  On macOS, a carried library that needs another carried library is relinked to the copy beside
  it (`@loader_path/<name>`) and re-signed ad hoc, so carrying Homebrew's `libssl.3.dylib` and
  `libcrypto.3.dylib` works on a Mac without Homebrew; without it the app stopped with "Library
  not loaded" for `libcrypto`. System libraries are never touched. (#78)
- **klio: collections for a site's theme, and a static export.** (#353)
  - `collection` returns the readable documents under a content subdirectory, such as
    `roles/`, sorted by a field with `:sort-by` (a core field such as `date`, or an `extra` key
    such as `start`) and `:order`. A document without the field goes last.
  - `document-field` reads a core field or an `extra` key, with nested values intact, and
    `document-by-slug` finds a readable page by its slug. `tree-collection` and
    `tree-document-by-slug` do the same on a tree.
  - `site-app` binds the tree it serves a request from (`*request-tree*`, `*request-now*`), and
    these functions read it through `current-tree`. A theme that lists a collection therefore
    sees the same tree as the page it is rendering, even when a reload lands mid-request.
  - `export-site` renders every readable page, `index.html` and `404.html` through the site's
    theme functions into a directory for a static host. `:layout` is `:file` (`roles/a.html`)
    or `:directory` (`roles/a/index.html`). It writes nothing unless every page renders. It
    signals `export-refused` for a non-empty directory without `:clean t`, for the content
    directory or one containing it, and for a site that has not booted.
- **klio: a controlled vocabulary checked at load, and a reload on change for development.**
  (#353)
  - `make-vocabulary` declares a list held in one document, such as the skills in `groups`,
    and the paths in other documents that refer to it, such as `skills` on a page or on a
    bullet. `make-site` and `load-tree` take `:vocabularies`. A reference to a label that is not
    in the list, matched exactly, is a load failure naming the referring file and the list's
    file, so boot refuses to start and reload keeps the last good tree. A missing list document
    is a failure too. `vocabulary-entries` and `vocabulary-entry-p` are the lookups for a theme.
  - `watch-site` reloads a site whenever a file in its content directory is edited, added or
    removed, checking every `:interval` seconds, and keeps serving the last good content when
    an edit breaks a file. `stop-watching` stops it. It is for development; how a production
    server is told to reload is recorded, not built, in klio's ADR-0002.
- **klio: RSS and Atom feeds, tag pages, pagination and a search index.** (#353)
  - `site-app` and `export-site` take the same options, from `make-site-options`.
  - `:base-url` turns on `/feed.xml` (RSS 2.0) and `/atom.xml`, with absolute links, newest
    first, for the readable documents that have a `date` (`:feed-collection` limits them to one
    collection, and `:feed-limit` caps them at 20).
  - Each tag has a page at `/tags/<slug>/` (`tag-slug`: `C#` is `c-sharp`, `C++` is
    `c-plus-plus`), through the site's `:tag-theme`.
  - `:per-page` paginates the index and each tag's listing at `/page/2/` and
    `/tags/<slug>/page/2/`; a listing theme gets `*page-number*`, `*page-count*`, `page-url` and
    `tag-url`.
  - `/search.json` lists every readable page (url, title, tags, date, text) for a search box.
  - Every path is an option. `resolve-path` answers them all, for the handler and for the
    export, which now writes each listing, tag page, feed and the search index as well.
- **aion/tz: a zone's UTC offset at an instant, and wall-clock time to UTC, from the system's
  TZif files.** (#367) `(aion/tz:offset "Europe/Kyiv" universal-time)` returns seconds east of
  UTC and the abbreviation. `(aion/tz:local-to-universal zone y mo d h mi)` returns the
  instant of a wall-clock time, and a second value, `:unique`, `:gap` or `:overlap`: a time in
  a spring-forward gap gives the instant of the change, and one in a fall-back overlap gives the
  earlier instant, with the later as a third value. `valid-zone-p` and `zone-names` list what
  the system has. Rules come from `$TZDIR` or `/usr/share/zoneinfo`, including the footer rule
  for instants after a file's last transition, so **a deployment image needs the tzdata
  package**; Windows has no zone directory, and there an app sets `TZDIR`. `parse-tzif`,
  `zone-offset-at` and `zone-local-to-universal` are pure, for use on any TZif bytes.
- **hades/single-instance: a lock that keeps a second copy of a desktop app off the same data
  directory.** `(hades/single-instance:with-single-instance ("app" :on-busy ...) ...)` runs its
  body holding the lock, or calls `:on-busy` when another copy holds it;
  `acquire-single-instance` returns a lock or `:busy`, and `release-single-instance` releases
  it. The operating system releases the lock when the process ends, so a crash does not lock the
  app out. It is scoped to the app's per-user data directory, or `:directory`. An app that wrote
  its own lock for this, with `CreateFileW` share mode 0 or `flock`, can use this instead. It is
  the first code in hades; an app depends on `hades/single-instance` alongside the frameworks.
  (#305)
- **aion/windows/ffi: `create-file-w`** and the constants `+generic-read+`, `+generic-write+`,
  `+open-always+`, `+file-attribute-normal+` and `+error-sharing-violation+`. (#305)
- **hades/credentials: a credential store over the operating system's own.**
  `(store-credential service account secret)`, `(fetch-credential service account)` and
  `(delete-credential service account)` keep a secret by name for the current user; `secret` goes
  in and comes out as an `aion/secret`. A missing item signals `credential-not-found`. On Windows
  the store is Credential Manager. On macOS it is the login Keychain, one generic-password item
  per credential with the item's service and account set to `service` and `account`. Linux
  signals `credential-store-unavailable` until its backend is written, and nothing is written to a
  file instead. A value over 2560 bytes of UTF-8 signals `credential-too-large` on both Windows and
  macOS. An app keeping an API key or password in a file or a setting can move it here. (#357)
- **aion/windows/ffi: Credential Manager bindings**: `cred-write-w`, `cred-read-w`, `cred-delete-w`,
  `cred-free`, the `credential-w` struct and its constants. (#357)
- **aion/darwin: a macOS binding over CoreFoundation and Security.framework** (aion ADR-0004).
  `make-cf-string`, `make-cf-data`, `make-cf-dictionary`, `cf-string-to-lisp`, `cf-data-octets`,
  `cf-constant`, `with-cf` (releases what it binds on every exit), and `osstatus-error` with
  `check-osstatus`. The raw `SecItemAdd`, `SecItemUpdate`, `SecItemCopyMatching` and
  `SecItemDelete` calls are in `aion/darwin/ffi`. macOS only; it uses cffi and the frameworks
  every macOS ships, and adds no dependency. (#357)

### Fixed

- **Directory trees the framework removes are removed without following links.** `cons`'s
  `with-temporary-directory`, `cons` templates, hyperion/update's staging, the build scripts and
  the test fixtures used `uiop:delete-directory-tree`, which on Windows follows a junction inside
  the tree and deletes files outside it. They use `aion/fs:delete-tree` now. (#347)
- **hyperion/server: on Woo, a response with status 429 reaches the client as 429, with its
  headers and body, instead of as an empty 500.** Woo writes a status line from its own table of
  reason phrases, which has no entry for 429 or for the other registered codes 103, 104, 425,
  428, 431 and 511, and it failed to write a response with any of them (#372). So
  `hyperion/ratelimit:wrap-rate-limit`'s refusals, and any handler returning one of those codes,
  reached a client on Woo as `HTTP/1.1 500` with an empty body and no `Retry-After`.
  `hyperion/server:start` now adds a line to Woo's table, before it starts a Woo server, for
  every code from 100 to 599 that has none (`complete-woo-status-lines`). Lines Woo already had
  are unchanged. An app on Woo needs no change. An app that starts Woo without
  `hyperion/server:start` calls `(hyperion/server:complete-woo-status-lines)` once after Woo
  is loaded. Hunchentoot was not affected. A new system, `hyperion/woo`, exists only for its
  suite, `hyperion/woo/tests`, which serves requests through a real Woo server; the gate runs it
  on Linux. It is not for an app: an app that wants Woo declares `clack-handler-woo` itself.
- **hyperion/http1: `reason-phrase` names every registered status code, and gives a code the
  registry does not name an empty phrase instead of "Unknown".** It is now the one table in
  hyperion: the native `:uv` server writes it, so a 429 there goes out as
  `HTTP/1.1 429 Too Many Requests` rather than `HTTP/1.1 429 Unknown`, and the Woo fix above
  takes its lines from it. An empty reason phrase is allowed by HTTP/1.1, and no client acts on
  the phrase. Hyperion core now depends on `hyperion/http1`, which is Coalton only. (#372)
- **aion/secret: `describe` no longer prints a secret's value.** It printed the structure's slot,
  `%VALUE = "..."`, because `describe` does not go through `print-object`. An editor's describe
  command reached it too. (#357)

- **cons conform: the commit-msg hook refuses an AI assistant's identity, not a human whose
  name contains an assistant's name.** `Co-Authored-By: Claude Smith <claude.smith@example.com>`
  was refused. The hook now refuses a name that is an assistant's name alone or followed only by
  model and version words (`Claude`, `Claude Opus 5.5 (1M context)`, `GPT-5`, `Cursor Agent`),
  an address at anthropic.com or openai.com, a `[bot]` account, an assistant's GitHub noreply
  address, and the generated-with footer. The pattern is the `ai_trailer=` line in
  `.githooks/commit-msg`. An app that copied the hook, from `cons conform` or from this tree,
  copies it again. (#311)

- **hyperion/server-uv: a 1xx, 204 or 304 response has no Content-Length and no body.** It
  used to be sent with `Content-Length: 0`, which on a 304 says the resource is empty (RFC 9110
  allows Content-Length on a 304 only as the full response's length). A body a handler returns
  with one of these statuses is now dropped, with the warning `server-uv: dropped the body of a
  response whose status carries none`, instead of being written after the head, where a client
  would read it as the next response. Found by Clack's handler suite (#373).

## v0.1.4 — 2026-09-29

Changes since `v0.1.3`. The tag is on `b68ccd4`.

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
