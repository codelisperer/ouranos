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

- **praxeon: `generate-image` is refused once a turn has read a web page or search results**
  (#827). `praxeon/image:register` and `register-openai-image` now pass
  `:requires-user-intent t` to `register-means`, because each image costs money. When the model
  asks for an image after `read-web-page` or `web-search` returned in the same turn, the call is
  not run and the model is told the user can ask for it in their next message. To keep the old
  behaviour, pass `:requires-user-intent nil`.
- **praxeon: a means registered with `:confirm` is refused, not held, once a turn has read a web
  page or search results** (#827). `register-means`'s `:requires-user-intent` defaults to true
  when `:confirm` is given, and that includes tools granted by `praxeon/mcp:grant-tools` with
  `:confirm`. Such a call after `read-web-page` or `web-search` returned in the same turn no
  longer reaches the app's `:on-hold` policy. Pass `:requires-user-intent nil` to
  `register-means` to have it held as before. `grant-tools` has no such option, so a granted
  tool with `:confirm` is always refused after a read.
- **praxeon/mcp: a tool granted by `grant-tools` counts as untrusted content** (#827). After a
  granted tool has run in a turn, a means registered with `:requires-user-intent t` or with
  `:confirm`, including another granted tool held for confirmation, is refused for the rest of
  the turn. For a server the app fully controls, pass the new `grant-tools` key
  `:untrusted nil`.
- **praxeon: registering `read-web-page` without `:allow` logs a warning** (#827), naming the
  risk and `praxeon/web-page:user-or-search-urls`. Pass `:allow` to `register-read-web-page` or
  `praxeon/web-page:register` to silence it.
- **praxeon: `read-web-page` and `web-search` run at most 3 times in one turn by default**
  (#827). Later calls in the turn are not run, and the model is told the limit. Pass
  `:max-per-turn` to `praxeon/web-page:register`, `register-read-web-page` or
  `praxeon/web-search:register` to change it, or `:max-per-turn nil` for no limit. Both means
  are now registered with `:untrusted t`, so a means with `:requires-user-intent t` is refused
  after either one has run in the turn.

- **hermes/blob: `put-blob` refuses metadata named `sha256`, and malformed metadata, with the new
  condition `blob-invalid-metadata`** (#810). `sha256`, in any case, is reserved for the checksum
  the S3 store now records. Names and values become request headers on S3, so a name must be a
  non-empty HTTP header token (ASCII letters, digits and ``!#$%&'*+-.^_`|~``), a value must be
  printable ASCII, and two names that differ only in case are refused, because they would be
  the same header. S3 expects a non-ASCII value RFC 2047-encoded; hermes does not encode, so
  encode one yourself or keep it in your own row. `blob-invalid-metadata-name` names the
  offending entry. The check runs on every store,
  so an app that passed `("sha256" . ...)` in `:metadata` to keep its own checksum must rename
  that entry; the store's own checksum is in `blob-meta-checksum`.

- **Native: the pinned libuv is 1.53.0** (#739), released 2026-09-24, in place of 1.52.1.
  `libuv.pin` names it with its sha256, and `scripts/build-libuv.lisp` builds it. A tree whose
  `vendor/libuv/` was built from 1.52.1 keeps loading that copy until it is rebuilt: delete
  `vendor/libuv/` and run `sbcl --script scripts/build-libuv.lisp`. A desktop bundle that carries
  `libuv.dll`, `libuv.so.1` or `libuv.1.dylib` carries the rebuilt copy only once it is rebuilt.
  `aion/uv:version` returns the version that loaded. On Windows the build now also links
  `synchronization`, because 1.53.0's `src/win/pipe.c` calls `WaitOnAddress`. The public
  struct layouts `aion/uv` writes by hand (`uv_buf_t`, `uv_stat_t`, `uv_dirent_t`,
  `uv_timespec_t`, `uv_stdio_container_t`, `uv_process_options_t`) did not change, and request
  structs keep their size: `UV_REQ_FIELDS` gives up one reserved pointer to a union of the same
  size in the private fields.

- **The Stripe backend sends `Stripe-Version: 2026-09-30.endive` on every request** (#734),
  where it sent no `Stripe-Version` before and Stripe answered in the version the account was
  created with. `hermes/payments:+stripe-api-version+` names the version. A webhook payload
  comes in the version of the webhook endpoint instead, so when an event's `api_version`
  differs, `verify-webhook` logs the warning "stripe webhook api_version differs from the pinned
  version", with `event-api-version` and `pinned-api-version` fields, and still parses the
  event. Stripe cannot change an existing endpoint's API version, so to stop the warning the
  app creates a new webhook endpoint at `2026-09-30.endive` and then disables the old one;
  Stripe's guide "Handle webhook versioning" gives the steps. Create it through the API with
  `api_version=2026-09-30.endive`: the Dashboard creates an endpoint only at the latest
  version, and a later version also differs from the pin and gets the warning. Both readers take the newer shape and fall back to the older one: the period
  end from `items.data[].current_period_end`, else the subscription's `current_period_end`, and
  an invoice's subscription from `parent.subscription_details.subscription`, else its top-level
  `subscription`.
- **A Stripe subscription's `subscription-current-period-end` is the earliest period end among
  its items** (#734), when its items carry one, which they do from `2025-03-31.basil`. Before,
  it was read only from the subscription's own `current_period_end`. An account or webhook
  endpoint on `2025-03-31.basil` or later does not send that field, so the period end read as 0
  and `subscription-grants-access-p` granted access on the status alone. A
  subscription whose items renew on different dates now stops granting access when the first
  item's period ends, unless a newer event or `subscription-state` brings a later one.

- **Toolchain: the pinned Coalton is `024d0a17`** (#697), upstream `main` of 2026-10-12, in
  place of `7915fad0`. `coalton.pin` names it, and `scripts/setup.sh` and `scripts/setup.ps1`
  fetch it and check an existing checkout out at it. Re-run the setup script, or run
  `git fetch origin && git checkout 024d0a17` in the Coalton checkout, then clear
  `~/.cache/common-lisp` and rebuild `bin/cons`; `scripts/check-coalton.lisp` says which
  Coalton loads. The framework needed no change. An app's own Coalton code may:
  - A discarded `Result` is now a full warning, which fails an ASDF build: a non-final form
    of a body, or the last form of a `when` or `unless` body or of `protect`'s cleanup, whose
    value is a `Result`. Handle it, or bind it with `(let _ = …)`.
    `docs/coalton-patterns.md` §8a shows the message.
  - A toplevel list left open at the end of a file is an error, where before it silently
    swallowed every form after it.
  - `error` takes only a `String`. `Signalable` and `result:ok-or-error` are removed, as are
    the identity `Into`/`Iso` instances, the `Cell` to `String` conversion and the tuple-swap
    conversions.
  - `unwrap`, `expect` and `error` signal a `Panic` condition that prints the message as
    written; it is no longer used as a `format` control string.
  - `coalton` now exports `need`, `protect` and `handle`, which can collide with an app's
    own definitions of those names in a package that uses `coalton`.

  An app that pins Coalton in its own build moves that pin to `024d0a17`.

- **praxeon/mcp on Windows: a local server's command must name an `.exe` or `.com` program;
  a `.bat` or `.cmd` file is refused** (#700). Local MCP servers are now started by
  `aion/windows:spawn-in-job`, which starts the server suspended inside its kill-on-close job
  object and with no console window, then lets it run, so every process the server starts is
  in the job too. Before, `sb-ext:run-program` started it and it was put in the job afterwards,
  so a process it started in that moment could outlive it. `spawn-in-job` refuses batch files
  with `aion/windows:process-not-started`, because `cmd.exe` would read the arguments by rules
  the quoting does not follow; the client logs the failure and the request fails as not run. A
  bare name was never found as a batch file (`run-program`'s `:search` does not look for one
  either), so only an app that gave the full path of a `.bat` or `.cmd`, for example
  `C:\...\npx.cmd`, is affected. Name the program the batch file runs instead, for example
  `node` with the script's path as its first argument.

- **hyperion/http: an app that looked up a form or query field by its percent-encoded name
  must use the decoded name** (#715). `form-param`, `form-params`, `query-param`,
  `query-params` and `form-alist` now decode names, so `(form-param body "en%3Awho")` no
  longer finds a field a browser posted as `en%3Awho`; `(form-param body "en:who")` does. The
  fix itself is under Fixed.

- **praxeon: a failed model, embedding or rerank request signals
  `praxeon/conditions:provider-request-failed`, and the response body is on the condition,
  not in its report or the log** (#719). The new condition is a subclass of
  `deliberation-failure`, so a handler for that still receives it. Its readers are
  `provider-request-failed-status`, `-error-type`, `-error-code` (read from the service's
  error JSON when the body parses as one, otherwise NIL) and `-body`. The report and
  `deliberation-failure-detail` now give the status, the type and code, and the body's length
  instead of the body, and the `llm request failed` warn line logs `status`, `error-type`,
  `error-code` and `body-length` fields. An app that read the service's explanation from the
  report, the detail or the log line reads it from `provider-request-failed-body`.

- **hyperion/assets: the vendored htmx is 2.0.11 and Alpine.js is 3.17.4** (#717), up from
  htmx 1.9.12 and Alpine.js 3.14.1. `(hyperion/assets:url :htmx)` now serves
  `htmx-d6fdc75f.min.js` and `(hyperion/assets:url :alpine)` serves `alpine-23251939.min.js`.
  An app that vendors its own htmx can drop its copy and load this one with
  `(:script :src (hyperion/assets:url :htmx))`. Hyperion never adds its own htmx to an app's
  page, so a page loads htmx twice only if the app includes it twice. htmx 2 is a breaking
  release; see the [htmx 1 to 2 migration guide](https://htmx.org/migration-guide-htmx-1/).
  What an app's own templates may hit:
  - **`hx-delete` sends its parameters in the query string and no body.** In 1.9.12 they were a
    urlencoded body. A handler that reads a DELETE's parameters with `hyperion/http:form-param`
    on `body-string` gets NIL; read them from the query string instead, or set
    `htmx.config.methodsThatUseUrlParams` to `["get"]` to restore the 1.x behaviour.
  - **`hyperion/csrf` sends an `hx-delete` form's token in a header.** A form whose
    `:hx-delete` or `:data-hx-delete` has a value when it renders gets an `hx-headers`
    attribute carrying `X-CSRF-Token`. It has no hidden `_csrf` field, which htmx 2 would put
    in the URL, unless the form's own `:method` changes state: then the field stays for the
    browser's native submission without htmx, and `hx-params="not _csrf"` keeps it out of the
    DELETE. A form whose `:hx-delete` is NIL when it renders is treated as an ordinary form.
    These no longer compile: a form with `:hx-delete` and its own `:hx-headers` or
    `:data-hx-headers` (move those to an element around the form, since htmx merges
    `hx-headers` from enclosing elements), and a form with `:method`, `:hx-delete` and
    `:hx-params`. An `hx-delete` on an element that is not a form gets no token from the
    injector, as before; give it `:hx-headers (hyperion/csrf:token-headers)`. Do not put an
    `hx-delete` button inside a POST form, because htmx 2 would put that form's hidden `_csrf`
    field in the URL.
  - **`hyperion/http:body-string` returns NIL for a request with neither Content-Length nor
    Transfer-Encoding**, without reading the stream. Before, it read to the end of the stream,
    and under Hunchentoot a bodiless htmx 2 DELETE waited 20 seconds for the socket timeout.
  - **Requests to another origin are refused** (`htmx.config.selfRequestsOnly` is true). Set it
    to false in the app's own `htmx-config` meta tag if an `hx-get` or `hx-post` names another
    origin.
  - **htmx's own extensions are no longer in the core file**, including SSE (`hx-sse`) and
    WebSockets (`hx-ws`). Hyperion uses none of them. An app that does vendors the 2.x
    extension itself; `hyperion/sse` on the server side is unchanged.
  - **`hx-on="event: …"` is gone**; write `hx-on:event-name` (for example
    `hx-on:htmx:before-request`). Nothing in this tree used the old form.
  - **Scrolling after a swap is instant** (`htmx.config.scrollBehavior` is `'instant'`, was
    `'smooth'`).

  Unchanged, and checked in a real browser by the new smoke test in the `hyperion/assets`
  suite: `hx-get`, `hx-post`, `hx-target`, the `outerHTML` and `innerHTML` swaps,
  `hx-swap-oob`, the `load`, `revealed` and `every` triggers, and the `HX-Trigger` response
  header. The interval parser `hyperion/update-ui:*poll-interval*` relies on (ms, s, m) is the
  same in 2.0.11. The event names `htmx:beforeRequest`, `htmx:afterRequest`, `htmx:sendError`,
  `htmx:timeout`, `htmx:configRequest` and `htmx:afterSwap`, and the `hx-request` attribute,
  are unchanged.

- **praxeon: an unrecognised tool-choice value signals `praxeon/conditions:unknown-tool-choice`,
  and the value is on the condition, not in its report or the log** (#727). Before, the
  message was `unknown tool-choice` followed by the value, and the `llm request failed` warn
  line logged it; a forced tool's name can come from a prompt. The new condition is a subclass
  of `deliberation-failure`, so a handler for that still receives it. Its reader is
  `unknown-tool-choice-value`. The report and `deliberation-failure-detail` now say what kind of
  value it was and its length, for example `unknown tool-choice: a list of 2 elements`. An app
  that read the value from the report, the detail or the log line reads it from
  `unknown-tool-choice-value`.

- **praxeon: the report of `praxeon/conditions:tool-choice-unsupported` no longer prints the
  tool choice** (#727). `complete` signals it inside the handler that writes the `llm request
  failed` warn line, so with the meta impl a forced `(:tool "name")` reached the log. The report
  now says what kind of value it was and its length, for example `a list of 2 elements`. The
  value is still in `tool-choice-unsupported-requested`; an app that read it from the report
  reads it there.

- **praxeon: `provider-request-failed-error-type` and `-error-code` are NIL unless the value is
  1 to 64 letters, digits, underscores, dots or hyphens** (#727). Both are logged, and a proxy
  between praxeon and the service can answer with its own error JSON, so a value with other
  characters could be text of its own. The value is still in `provider-request-failed-body`.

- **Toolchain: the pinned SBCL is 2.6.9** (#696). `scripts/versions.env` sets
  `SBCL_VERSION=2.6.9` and new `SBCL_SHA256_X86_64_LINUX`, `SBCL_SHA256_X86_64_WINDOWS` and
  `SBCL_SHA256_ARM64_WINDOWS` values, so a fresh install by `scripts/setup.sh` or
  `scripts/setup.ps1` gets 2.6.9 and refuses a 2.6.8 download. The Linux binary still needs
  glibc 2.38. A machine that already has SBCL is not upgraded by every script:
  - Linux: re-running `scripts/setup.sh` installs 2.6.9 alongside the older one.
  - macOS: `setup.sh` leaves Homebrew's SBCL alone; run `brew upgrade sbcl`.
  - Windows: `setup.ps1` leaves an installed SBCL alone. Install the 2.6.9 MSI over it, or
    uninstall the old one and re-run `setup.ps1`.

  Then clear `~/.cache/common-lisp` and rebuild `bin/cons`, which refuses to run under an SBCL
  other than the one that built it. An app that pins SBCL in its own CI or Dockerfile moves
  that pin to 2.6.9 to build against the same compiler the framework is tested on.

- **praxeon/memory-db: make the store over a mnemosyne pool when the app also uses the
  database** (#653). `make-db-memory-store` now takes a pool as well as a connection. Over a
  pool each store operation borrows a connection, and reads take no lock. A write on Postgres
  takes the store's lock after the connection. A write on SQLite runs in a transaction that
  begins IMMEDIATE, or a savepoint inside one already open, and holds the database's write lock
  in place of the store's lock, so an observer that waits for an app's transaction to commit
  holds nothing the app's next store write needs. Inside an app's `conn:with-transaction` that
  has not written yet, that transaction began deferred, so the store's write takes the write
  lock only at its first write, and if the observer commits in between, the write can fail
  with `SQLITE_BUSY` instead of waiting. `praxeon/observe` writes on a thread of its own, so it
  gets a connection of its own. Over one connection shared with the app, an app that held a
  transaction open while the observer wrote had that transaction committed by the observer's
  COMMIT on Postgres, so its rollback undid nothing, and the observer's writes were refused on
  SQLite (#651). A store call the app makes on its own thread inside its
  `conn:with-connection` on the same pool uses that connection and is part of its transaction.
  A store over one connection keeps working when nothing else uses that connection. On SQLite
  the store's own transactions (a window's, `supersede`'s and `forget-subject`'s) begin
  IMMEDIATE, so behind an app's write transaction they wait for the write lock, within
  mnemosyne's busy timeout (5000 ms by default), instead of failing with SQLITE_BUSY at once.
  `forget` clears the predecessor's link and deletes the observation in one transaction, so a
  pooled reader never sees both as current. An embedding a transaction computed before taking
  the lock is used only by the store whose embedder computed it, and `supersede` inside the
  transaction uses it instead of embedding the text again.

- **hyperion/auth-db: `make-db-auth` refuses to start unless the users table has the column
  `email_confirmed_at` and the tables `hyperion_email_tokens` and `hyperion_email_events`
  exist** (#690). Without them it signals `missing-email-tables`, whose report names the
  migrations to add: `users-email-confirmed-ddl` (an `ALTER TABLE … ADD COLUMN`),
  `email-tokens-ddl`, `email-tokens-hash-index-ddl`, `email-tokens-user-index-ddl`,
  `email-events-ddl` and `email-events-index-ddl`, in that order. `docs/migrations.md` section 5
  lists them as `make-migration` steps. The column is not in `users-ddl`, so a new timeline adds
  it with the same `ALTER` step as an existing one. Existing accounts start unconfirmed; to mark
  them confirmed, add `UPDATE hyperion_users SET email_confirmed_at = created_at WHERE
  email_confirmed_at IS NULL` after the `ALTER`. An app that uses none of the new functions
  below can pass `:require-email-tables nil` instead. `:ensure t` and `ensure-schema` create
  all of it. A store with its own table names passes `:tokens-table` and `:email-events-table`.

- **hyperion/static: `file-response`'s body is an open file stream, not a pathname** (#314).
  `file-response` now opens the file, reads back the path the open handle refers to
  (`F_GETPATH` on macOS, `/proc/self/fd` on Linux, `GetFinalPathNameByHandleW` on Windows) and
  serves it only when that path is under the root. Before, it checked the path and returned a
  pathname that the server opened later, so a directory replaced by a symbolic link in between
  could serve a file outside the root. An app or middleware that reads the body of a static
  response and expects a pathname (for example to log it, or to call `probe-file` on it) gets
  an `sb-sys:fd-stream` with element type `(unsigned-byte 8)` instead, and if it consumes the
  stream it must close it. `hyperion/router`, when it answers `HEAD` from a GET route, closes
  a file-stream body as it removes it. On `:uv`, a file-stream body is written in bounded pieces like a
  pathname body was, with `Content-Length` from the stream, and a `HEAD` response closes it
  after sending the length. On Clack backends, `hyperion:wrap-streaming-body` writes the stream
  in 64 KiB pieces (`hyperion::*file-piece-octets*`): Hunchentoot sends `Content-Length`, and
  Woo sends the file chunked, without `Content-Length`. An app on Woo that relied on a
  `Content-Length` for static files no longer gets one.

- **praxeon/memory-db: `ensure-schema` creates an index on `subject`, `<table>_subject_idx`**
  (#482). It builds it without `CONCURRENTLY`, so on a large existing table the first start
  after upgrading blocks writes to the table while the index builds. To avoid that, build it
  before deploying: `CREATE INDEX CONCURRENTLY IF NOT EXISTS <table>_subject_idx ON <table>
  (subject)`, outside a transaction; `ensure-schema` then finds it. An app that does not call
  `ensure-schema` and runs its own migrations adds that statement as a migration. Without the
  index, the exact second query that `recall-similar` makes when its first comes up short reads
  the whole table. pgvector 0.8 or later is recommended: on an older one there is no iterative
  scan, so that second query is made more often. See `docs/migrations.md` and
  `docs/dependencies.md`.

- **hyperion/session-db: make the DB session store over the app's mnemosyne pool, or pass
  `:backend`** (#636). `make-db-store` now takes a pool as well as a connection. A store made
  over one connection kept it for the life of the process, so after Postgres ended it (SQLSTATE
  57P01, at a provider's maintenance or a restart) every request carrying a session cookie
  failed with "Connection to database server lost" until the process restarted, while requests
  without one, and so a health check, kept working. Over a pool, each operation borrows a
  connection and, when Postgres has ended it, runs once more on a new connection opened from the
  pool's backend. Over one connection, `:backend` lets the store reconnect once and retry. An
  app that makes the store over one connection and passes neither still fails after a
  disconnect, as before.

- **praxeon/memory: `remember`, `observations-of`, `recall` and `recall-similar` take
  `:thread`, and an app's own memory store must accept it** (#317). A method of a store written
  outside this tree that does not accept `:thread` is refused when it is added, at load time.
  `:thread` NIL, the default, means facts about the subject, which is what every observation has
  been so far, so a call that does not pass it behaves as before, and a misspelt keyword is
  still an error. Such a store must also keep a superseding observation in its predecessor's
  thread in `supersede`, or an accepted correction of a thread observation becomes a fact about
  the subject, and must erase thread observations in `forget-subject`. `recall` refuses
  `:thread :all` for every store; `recall-similar` has no shared method, so a store's own
  `recall-similar` must refuse `:all` itself, as both stores in this tree do.
- **praxeon/memory: an app's own memory store implements `thread-progress` and
  `record-thread-progress` before `praxeon/observe` can use it** (#317). They keep an observer's
  progress on a thread (how many messages it has finished with, and the windows it gave up on),
  and `forget-subject` must reduce each of the subject's records to its mark, with no skipped
  windows, when it erases the subject's observations. `thread-progress` must return the skipped
  windows as they were recorded, including the `:closed` after a closed one, and in the order
  given: the observer reads whether a window is closed from that record alone, so a store that
  drops `:closed` makes it retry a window it closed. A store without both is refused when
  `make-observer` is called.
- **praxeon/memory-db: `supersede` refuses an observation that is already superseded**, as the
  in-memory store always has. It checks and writes under the store's lock in one transaction, and
  its UPDATE changes the row only while it is still current, so two supersessions of one
  observation, in one process or two, no longer leave two current replacements. An app that
  superseded the same observation twice now gets a `praxeon-error` on the second call. The
  embedding is computed before the lock is taken, so a read does not wait for the model.
- **praxeon/memory-db: every read needs two new columns, and `ensure-schema` adds them** (#317):
  `thread` (TEXT) and `source_through` (BIGINT on Postgres, INTEGER on SQLite). A read of the
  subject's facts filters on `thread IS NULL`, so on a table made before them every read fails,
  not only a thread's. An app acts if it does not call `ensure-schema` at start: it adds the two
  columns in its own migration before it reads. Existing rows become facts about their subject,
  as they were. `ensure-schema` also creates a second table, the observations table's name with
  `_progress` appended: `id` (TEXT, the primary key, which `record-thread-progress` upserts on),
  `subject` and `thread` (TEXT, not null), `observed` (BIGINT on Postgres, INTEGER on SQLite, not
  null), `skipped` (TEXT) and `updated_at` (BIGINT or INTEGER). An app with its own migrations
  creates it before using `praxeon/observe`; `forget-subject` works without it.
- **klio: a content file or directory whose name starts with `_` or `.` is no longer a page.**
  `klio:content-files`, and so `load-tree`, the watcher, listings and `export-site`, skip it,
  with everything under such a directory, so an author can keep a README or notes in the content
  directory (#557). A site acts if it publishes a page from a file named like `_about.md` or
  from a directory like `_posts/`: rename it, or its page and URL disappear. A plain
  `README.md` is still a page; name it `_README.md` to keep it out.

- **hyperion/desktop: `run-app` on `:uv` runs handlers on 2 worker threads and one event loop
  by default.**
  `run-app`'s `:workers` defaulted to NIL, so on `:uv` every handler ran on the loop thread, and
  a handler that waits (a model call, a slow query, a large file) held up every other request,
  including the page's polling and server-to-client streams. Hunchentoot hid this with a thread
  per connection. An app acts if it runs `run-app` with `:server :uv` (or `HYPERION_SERVER=uv`)
  and relies on inline dispatch: pass `:workers nil`. `run-app` also takes `:loops` now, which
  defaults to 1 on `:uv`: with workers, `:uv`'s own default is one loop per core, up to 4, on
  macOS and Linux, and one person's window does not need more than one. Pass `:loops nil` for
  that default. Other backends keep `start`'s defaults for both. (#472)
- **An image dumped by `scripts/dump-image.lisp` exits on an unhandled error, whatever command
  line dumped it.** `ouranos-dump:dump-executable` and `ouranos-dump:dump-core` now turn SBCL's
  debugger off in the image, so an unhandled error prints its message and a backtrace to
  standard error and exits with code 1. Images dumped by `bootstrap.lisp` and
  `scripts/build-desktop-app.lisp` already behaved this way, because they are dumped from
  processes started with `--script`, which turns the debugger off, and the core keeps that; an
  image dumped from an interactive session did not, and waited at the debugger's prompt, which on
  Windows is a desktop app that never exits and shows nothing. An app acts if its dumped image
  relies on SBCL's debugger, for a REPL of its own for example: pass `:debugger t` to
  `dump-executable` or `dump-core`, or call `sb-ext:enable-debugger` where it needs it. (#495)
- **A desktop app no longer loads libuv or mbedTLS from the source tree it was built from.**
  `aion/uv` and `aion/tls` searched `vendor/libuv` and `vendor/mbedtls` of the tree, found
  through ASDF at run time, after the copy beside the image. In a desktop bundle that tree is the
  build machine's, so a bundle missing its carried library still loaded on the machine or CI
  runner that built it, and failed only on a user's machine: the desktop-release check that
  removes the carried `libuv.dll` saw the app serving, on the runner's
  `vendor\libuv\lib\libuv.dll` (#472). `scripts/build-desktop-app.lisp` now sets
  `aion/platform:*search-source-tree*` to NIL in the app's image, and then the loaders try only
  `AION_UV_LIBRARY` or `AION_TLS_LIBRARY`, the copy beside the image, and the operating system's
  own search. Everything else, `bin/cons` and the tools dumped from the tree included, keeps
  searching the tree as before. An app acts if its bundle worked only on the build machine:
  carry the library, which `build-desktop-app.lisp` does for libuv and mbedTLS when the app loads
  them, or point `AION_UV_LIBRARY` or `AION_TLS_LIBRARY` at a copy.
  `scripts/verify-bundle-windows.ps1`'s control now compares long paths, and prints every copy
  of a removed DLL that was loaded. (#472)
- **`cons init --template web` scaffolds an app on `hyperion/server-uv` instead of
  `clack-handler-hunchentoot`.** The generated `.asd` depends on `hyperion/server-uv`, and the
  generated `start` passes `:workers 2` to `hyperion/server:start` when the server is `:uv`, so a
  slow handler does not hold up other requests. A project generated this way needs libuv: run
  `sbcl --script scripts/build-libuv.lisp` in the Ouranos tree. A libuv installed on the system
  is enough to run the project from source, but `cons bin` needs the one the tree built: it
  copies that libuv beside the `bin/<name>` it dumps, and stops with exit code 3 if the app
  would load a system copy (#513, below).
  Projects generated before this are unchanged. To keep Hunchentoot in a new project, replace
  `hyperion/server-uv` with `clack-handler-hunchentoot` in its `.asd`. (#472)
- **aion/pool: `pool-queued` is exact only when the pool is quiet** (#466). It is now
  `outstanding - running`, two counts read without a lock, so while jobs are being submitted and
  taken it is a reading of two changing numbers. An app that reads it to decide something while
  the pool is busy, rather than to report it, should not rely on it being exact. In the tree, only
  `aion/pool`'s own tests read it, and only once the pool is quiet.
- **A Windows update installs the whole new version or none of it.** Both installers,
  `scripts/installers/windows.nsi` and `windows.iss`, used to write the new files over the
  install directory one at a time, so an update that stopped part-way left a launcher and a
  `sbcl.core` from different versions, which the launcher refuses (exit 126). They now extract
  to `<install>.new`, have the staged `<name>.exe` check the staged core
  (`OURANOS_LAUNCHER_CHECK_ONLY=1`), and rename `<install>` to `<install>.old` and
  `<install>.new` to `<install>`. The launcher deletes `<install>.old` after it starts the
  runtime, and the next installer run finishes or undoes a swap that stopped between its
  renames. `hyperion/update`'s `launch-installer` starts the installer in its staging directory.
  An app acts if something it starts keeps the install directory as its current directory, or a
  file there open, after the app exits: the installer waits 20 seconds for the directory, then
  fails without changing anything and exits 2, the NSIS installer and the Inno one alike. An
  app acts too if its packaging puts its
  own files into the install directory after the installer runs, or keeps anything in
  `<install>.old` or `<install>.new`: both names are now the installers'. A bundle with
  `sbcl.core` and no `sbcl-runtime.exe`, or the other way round, is refused by
  `scripts/build-installer.ps1` and by both installers, which used to install it to fail at
  launch. An uninstaller that cannot be copied (Inno) or written (NSIS) into `<install>.new`
  stops the update before the swap, with exit 2. Both installers' exit codes are now: 0, the new
  version is installed and, on a silent run, the app was started; 2, the update failed and the
  installed version is unchanged (or, if the previous version could not be put back, the checked
  new copy is kept in `<install>.new` for the next run to finish); 3, the new version is
  installed but the app could not be started. An app or script that runs an installer itself
  and treats any non-zero code as "not updated" acts on 3. (#98)
- **`cons build`, `cons test` and `cons --strict` fail on an undefined variable in the project's
  own code.** SBCL reports an undefined variable when the compilation unit ends, after
  `compile-file` has returned without a failure. This includes a special variable that a later
  file of the same system defines with `defvar`. `cons/run:load-system-strictly` printed that
  WARNING and still loaded the system, so the target exited 0. It now fails the load with an
  error that names the system and each variable. A full WARNING that one of the project's own
  files signals when its fasl loads, such as a toplevel `warn`, fails the load the same way. Libraries outside the project directory are
  still loaded with their warnings muffled, including a library that signals a WARNING when its
  fasl loads. An app acts if its code has such a warning, which now fails its build. An app that
  carries its own strict-build script to catch this case can use `cons --strict build` instead.
  (#525)
- **hyperion/markdown: with `:allow-html nil`, an app's own 3bmd code-block renderer receives a
  fenced block's text unescaped, so it must escape `<`, `>` and `&` itself** (#559). `render`
  used to escape the whole source before 3bmd parsed it, so a renderer an app registered for
  `3bmd-code-blocks:*renderer*` was handed text that was already escaped. The safe mode now
  hands every renderer other than `:nohighlight` and `:colorize` the block's text as the author
  wrote it, as `:pygments` and `:chroma` expect, and prints that renderer's output unchanged. An
  app whose renderer writes its input into the page without escaping it now lets a fenced block
  put raw HTML on the page, so that renderer must escape its input. The fixed entry for #559
  below describes the rest of the change.

- **klio: HTML comments are removed from a page when it is loaded; `search.json` can be turned
  off, and a page can stay out of search** (#556). klio renders Markdown with raw HTML escaped,
  so an HTML comment (`<!-- ... -->`) in a page's body was shown on the page as visible text,
  and `/search.json` and the search index carried it too. An author who kept private notes in
  comments has been publishing them on any site exported or served this way. `load-document` now
  removes every comment from the body before rendering or indexing it, so `document-body`,
  `document-html`, `search-json` and `content-tree-index` no longer contain them. A comment is
  kept only when klio's renderer shows all of it, from `<!--` through `-->`, inside one `<code>`
  element on the page, as in one code span, one fenced block or one indented block. klio decides
  this by rendering a copy of the body, so a block quote, a `~~~` fence or a list item that
  renders as text does not keep a comment, and neither does a comment that starts in code and
  ends outside it. A body that contains one of the Unicode noncharacters U+FDD2 to U+FDD5 or
  U+FDE0 to U+FDEF has every comment removed. `<!-->` and `<!--->` are whole comments, as
  CommonMark 0.31.2 defines them, so the text after them is kept. A comment that is never closed
  removes the rest of the body, and the load warns. HTML comments are removed from the body
  only; use YAML `#` comments in front matter, where a `<!-- -->` in a value is kept and
  published. `klio:strip-html-comments` does the removal; its `:render` argument names the
  renderer, `render-markdown` by default. `make-site-options`, and so `site-app` and
  `export-site`, take `:search-path nil` to have no `search.json`: the export does not write it
  and the app does not serve it. A front-matter `search: false` leaves a page out of
  `search.json` and the search index; only `search: true` or no `search` key keeps it in.
  `search` is now a core key, read with `content-meta-search` or `(document-field d "search")`.
  An app acts if a theme or a script relied on comments in `document-body`, or read `search`
  with `(extra meta "search")`, which now returns NIL. An author who relied on comments being
  hidden should check what was already published.

- **praxeon: a `:tool-result` event can have the outcome `:started`, and `actor:*tool-call-id*`
  is bound while a means runs** (#532). A means that starts work which finishes after the call
  returns, such as an MCP task, returns `(actor:started-result text)`: the model is told `text`,
  and the call's `:tool-result` event has outcome `:started`, not `:ok`, because the call has
  not produced its result yet. The result comes later in an event of the means' own that
  carries the same `:id`; for MCP that is `:task-finished`. `actor:*tool-call-id*` is the
  model's id for the call while its means runs, and NIL otherwise. An app whose usage ledger
  or progress display branches on `:tool-result` outcomes meets `:started` from MCP tools on a
  connection made with `:tasks t`, and records the call's result from `:task-finished`, joined
  by `:id`. Nothing produces `:started` unless a means returns `started-result`.
- **Desktop: a macOS app from `scripts/build-dmg.sh` says it needs macOS 15.0, and
  `desktop-release.yml` builds it on `macos-15`** (#763). `LSMinimumSystemVersion` in the app's
  `Info.plist` was 11.0, which was never true: the bundle carries Homebrew's `sbcl` and
  `libzstd`, which need at least the macOS they were built on, so an app built on `macos-14`
  needed macOS 14. `scripts/verify-bundle-macos.sh` now fails a `.app` that has a binary needing
  a later macOS than its `LSMinimumSystemVersion` (check 0), and prints the OpenSSL the app
  loaded. An app that builds its own `.app` with `build-dmg.sh` on a newer macOS than 15 will
  fail that check until it builds on `macos-15` or older.

- **praxeon: the default Anthropic model is `claude-sonnet-5-5`** (#764), in place of
  `claude-sonnet-5`, which Anthropic now lists as a legacy model. `praxeon/llm:*default-model*`
  holds it. An app that sets neither `PRAXEON_ANTHROPIC_MODEL` nor `PRAXEON_LLM_MODEL` and makes
  an `anthropic` provider without `:model` now sends `claude-sonnet-5-5`, so its answers, token
  counts and price per token can change. To keep the old model, set
  `PRAXEON_ANTHROPIC_MODEL=claude-sonnet-5` or pass `:model "claude-sonnet-5"`.
  `claude-sonnet-5-5` allows 128,000 output tokens, so `*default-max-tokens*` (8,192) is
  unchanged. The documentation's examples now name
  `claude-opus-5-5` where they named `claude-opus-4-8`.

### Added

- **hyperion: a shared link to an app's page can show a preview card**, through the new
  `hyperion/page-meta` (#821). A layout calls `meta-tags` inside its `(:head ...)` with the
  page's `:title`, `:description`, `:image` (with `:image-alt`, `:image-width`,
  `:image-height`), `:url` (canonical), `:type` (`:website` or `:article`), `:locale` and, for
  an article, `:published-time`, `:modified-time`, `:author` and `:section`, and a required
  `:visibility` (`:public`, `:noindex` or `:private`). It writes the
  Open Graph `og:*` tags, `twitter:card` (`summary_large_image` when there is an image) and
  `twitter:*`, `<meta name="description">` and `<link rel="canonical">`. `page-meta` returns
  the same tags as a list, and `meta-tags-string` returns them as a string.
  - The site's name, public origin, fallback image and Twitter account come from a `site`
    made with `make-site` and set in `*site*`. The origin defaults to the new environment
    variable `HYPERION_PUBLIC_ORIGIN`, and must be a bare https origin. Every URL is made
    absolute from it, never from the request's Host header, and an http URL signals
    `page-meta-error`. The canonical URL must be on the site's own origin, and its query and
    fragment are dropped unless the page passes `:keep-query t`.
  - Descriptions are plain text. Their whitespace, Unicode's included, is collapsed, and
    they are cut to 200 characters on a word boundary. An article time is a universal time
    or an ISO 8601 string. `og:locale` takes a locale as `hyperion/i18n` names it (`:en-gb` becomes
    `en_GB`).
  - `:visibility :private` (the page needs sign-in) or `:noindex` emits `robots noindex`
    and the site's name and fallback image only. A page's own `:site-name` is not used there.
  - An image URL presigned with an expiry (`expiring-url-p`: S3, Google Cloud Storage,
    CloudFront and Azure signatures), or one that cannot be parsed, is replaced by the site's
    fallback, with a warning, because crawlers cache a card longer than the URL lasts.

- **hermes/blob: `copy-blob` and `move-blob` copy or move a blob inside a store without the
  bytes passing through the app** (#804), so a verified upload leaves quarantine without being
  downloaded and uploaded again. `(copy-blob store src-bucket src-key dst-bucket dst-key
  &key content-type metadata if-match)` returns the destination's `blob-meta`; `move-blob` copies and
  then deletes the source. On S3 a copy is CopyObject up to 5 GiB and a multipart copy
  (UploadPartCopy) above it, every request conditional on the source's ETag, so a source
  replaced during the copy signals the new condition `blob-source-changed`, a
  `blob-backend-error` subclass. `:if-match` takes the ETag the app recorded when it checked the
  blob, so the copy happens only if the source is still that object (part of #826). On the
  filesystem store, `blob-meta-etag` is now the blob's SHA-256 checksum, where it was NIL, so
  `:if-match` works there too. The content type, the app's metadata and the checksum are kept
  unless `:content-type` or `:metadata` replace them. A copied object gets the bucket's default
  ACL, or `x-amz-acl: private` on a store made with `:upload-acl :private`. A move is not atomic on S3:
  if deleting the source fails, the destination exists and the delete's condition is
  signalled, and a delete S3 refuses with 403 is found by checking the source afterwards and
  signals `blob-backend-error` naming the source. A copy S3 refuses with 403, or a missing
  destination bucket, is `blob-backend-error` naming the destination. On the filesystem store a move is a rename. A missing source is `blob-not-found`
  naming it; a provider that cannot copy, or a store class that does not implement it, signals
  `blob-unsupported`. See "Leaving quarantine" in `hermes/docs/blob-direct-uploads.md`.

- **hermes: post to a Facebook Page the app's admins manage, through the Graph API, with a
  one-time connect flow** (#822). `hermes:post-to-page` (`page link &key message image-url
  provider`) returns the post id; a `hermes:facebook-post` from `make-facebook-post` is also sent
  by `hermes:send` or `deliver` to a `hermes:facebook` provider (`make-facebook`: `:app-id`,
  `:app-secret`, `:page-tokens`). Page tokens are looked up per Page id, by default from
  `FACEBOOK_PAGE_TOKEN_<page-id>` then `FACEBOOK_PAGE_TOKEN`, and sent in the POST body; every
  token and the app secret (`FACEBOOK_APP_SECRET`) is replaced by `<redacted>` in failure text,
  and reaches the code that signals a failure only as an `aion/secret` secret, so a logged
  backtrace does not show it. Reads send the token in an `Authorization: OAuth` header. Calls
  time out after 10 seconds to connect and 30 to answer; a post that timed out may still have
  been made.
  Failures are `facebook-reconnect-required`, `facebook-not-permitted`,
  `facebook-page-not-found`, `facebook-link-not-public` (Facebook could not see the link) and
  `delivery-rate-limited` (Graph codes 4, 17, 32, 613 and 80001, with the wait from the
  `X-Business-Use-Case-Usage` header); a target that names a Facebook Group signals
  `facebook-groups-unsupported`. `facebook-page-health` answers `:connected`, `:reconnect`,
  `:not-permitted`, `:wrong-page` (the stored token is another Page's), `:not-found` or
  `:not-connected`; a Page argument that is not a Page id signals `invalid-message`. The connect flow is
  `facebook-connect-state`, `facebook-connect-url` and `facebook-connect-pages`, which checks the
  state in constant time, exchanges the code server-side for a long-lived user token, and returns
  the admin's Pages as `facebook-page` values with their tokens; the app stores the chosen token.
  `HERMES_FACEBOOK_IMPL` picks the backend, default `facebook`; `HERMES_TRANSPORT=dev` renders
  posts, and `dev-last-facebook` reads the last one. Core `hermes` now loads `aion/random`.
  Meta's access rules and the one-time app setup are in `hermes/README.md`; upstream.sexp records
  Graph API v26.0.

- **praxeon: a turn can refuse calls that content the agent read may have asked for** (#827).
  `praxeon/actor:register-means` takes `:untrusted`, `:requires-user-intent`, `:allow` and
  `:max-per-turn`. A means with `:requires-user-intent t` is refused for the rest of a turn once
  a means with `:untrusted t` has run in it; a call whose `:allow` predicate returns false or
  signals is refused; and calls past `:max-per-turn` in one turn are refused. A refused call is
  not run, and the model is told why. `praxeon/web-page:user-or-search-urls` is a ready-made
  `:allow` for `register-read-web-page`: it allows only hosts the user wrote in the
  conversation, matched exactly with userinfo ignored, and URLs a web search returned in this
  turn before anything untrusted was read. `praxeon/actor:user-texts`, `turn-untrusted-p`,
  `turn-urls`, `note-turn-urls` and `mark-untrusted` let an app's own means and predicates use
  the same guard. `read-result` makes the turn untrusted when the stored result it reads came
  from an untrusted means. A task a coordinator delegates through `register-agent-as-means`
  never counts in the sub-agent's `user-texts`; the coordinator's user texts count instead, and
  the delegation means is `:untrusted` when the sub-agent has an untrusted means. A bare host
  ending in a file extension (`main.rs`, `README.md`) counts in `user-or-search-urls` only after
  `www.` or before a path. The new agent slot `taint-scope` (`agent-taint-scope`), `:turn` by
  default, can be set to `:conversation` to start every later turn untrusted while untrusted
  results remain in the history. The praxeon README's section "Content the agent reads can
  carry instructions" describes what this stops and what it does not.

- **hermes: `telegram-added-chats` lists the chats a Telegram bot was recently added to**
  (#794), so an app can find the id of a group or channel that operators share as a `t.me/+`
  invite link. It returns `telegram-added-chat` structures (`-id`, `-type`, `-title`, `-status`,
  `-date`) from the bot's `my_chat_member` updates. By default it leaves the updates pending;
  `:confirm t` confirms them. A bot with a webhook gets the new condition
  `telegram-webhook-active`. The dev transport returns no chats. With `:confirm t`, a page of
  updates that carries no `update_id`, or none newer than those already confirmed, ends the read
  instead of being asked for again, and the updates on that page stay pending (#805).
  The README says what happens when the app's own `getUpdates` poll runs at the same time, and
  when the bot's stored `allowed_updates` leaves out `my_chat_member`.

- **praxeon: an agent can read a web page the user gives it, through the new
  `read-web-page` means** (#757). It is in the opt-in system `praxeon/web-page`, registered
  with `register-read-web-page`.
  - It returns the page's main text, trimmed to `*budget*` characters, with its title and the
    URL it was read from after redirects.
  - The backend is Tavily's `/extract` when `TAVILY_API_KEY` is set. Otherwise the page is
    fetched with `aion/http-client:fetch-public` and its text extracted with plump. On Windows
    without a Tavily key nothing is registered, and the reason is logged.
  - A URL whose host is a private, loopback, link-local or other internal address is refused
    before any request.
  - A failure is the condition `web-page-unreadable`, a `tool-error-result`, so the turn goes
    on.
  - `status-line` turns the means' `:tool-call` event into "Reading example.com…".
  - When fetched, a page is decoded in the charset its `Content-Type` names, or, for HTML, the
    charset a `<meta>` in its first 1024 bytes names, else UTF-8. A response with no
    `Content-Type` is read when it is text. The whole read has a 30-second deadline
    (`make-public-fetch`'s `:deadline`), reported as the reason `:timeout`. Resolving the host
    and opening the connection are not interrupted, only checked when they return, so a read
    can end up to the resolver's timeout plus the 10-second connect timeout past it. A redirect to a
    URL that is not http or https is reported as `:invalid-url` (#807).
  - `make-public-fetch` and `make-tavily-extract` no longer take `:address-policy`; passing it
    is an error. The check that a page's host is a public address cannot be changed by an app
    (#807).
- **praxeon: `praxeon/source:quote-source`** wraps outside text, such as a fetched page or a
  retrieved document, between markers carrying a random nonce, after a sentence saying it is
  quoted material and not instructions (#757). `read-web-page` uses it, and
  `praxeon/retrieval` can.
- **aion/http-client: `fetch-public` returns the URL of the last hop as a second value**
  (#757). After a redirect this differs from the URL it was given. A caller that uses only
  the first value is unaffected.
- **aion/http-client: `fetch-public` takes `:deadline`, seconds for the whole fetch over every
  hop** (#807). When it passes, the socket in use is shut down and `fetch-public` signals the
  new condition `fetch-deadline-exceeded` (a subtype of `http-error`; readers
  `fetch-deadline-exceeded-url` and `-deadline`), so a server that sends a byte now and then
  can no longer hold the caller for as long as it likes. It covers the TLS handshake, the
  request, the headers and the body, but not resolving the host name or opening the TCP
  connection, which are checked when they return, so a fetch can end up to the resolver's own
  timeout plus `:connect-timeout` past the deadline; with `:connect-timeout nil` the operating
  system's connect limit applies, about 127 seconds on Linux. The default, `nil`, sets no
  deadline, so existing callers are unchanged.

- **hermes/blob: an S3 store can sign `x-amz-acl: private` into upload URLs, for a bucket that
  honours ACLs** (#796). `make-s3-store` takes `:upload-acl`, `:none` (the default) or `:private`,
  or reads `MNEMOSYNE_S3_UPLOAD_ACL` (`private` or `none`); any other value signals
  `blob-configuration-error` when the store is made. With `:private`, `upload-url` signs
  `x-amz-acl: private` and returns it in `upload-target-headers`, so a client that adds
  `x-amz-acl: public-read` or leaves the header out is refused (403 and 400 on MinIO). Set it for
  DigitalOcean Spaces and for AWS buckets with ACLs enabled. Leave it `:none` for an AWS bucket
  with ACLs disabled, the default for a new AWS bucket, which refuses an upload naming `private`
  with 400 `AccessControlListNotSupported`, and for Cloudflare R2, which does not implement the
  header. With the default nothing changes for an existing app. `put-bucket-cors` now allows
  `("Content-Type" "x-amz-acl")` by default, and `check-bucket-cors` by default checks the headers
  `upload-url` sends on that store. A bucket whose CORS rule allows only `Content-Type` needs
  `put-bucket-cors` again before switching its store to `:private`, or the browser blocks the
  upload. See `hermes/docs/blob-direct-uploads.md`.

- **hermes: Telegram groups and channels, through the Telegram Bot API** (#778). A
  `hermes:telegram-message`, built with `make-telegram-message` (`:chat` an integer chat id or
  `"@username"`, `:text`, `:parse-mode` `:html` or `:markdown-v2`, `:link-preview` `:show` or
  `:hide`, `:photo` a URL or file_id), is sent by `hermes:send` or by `deliver` to a
  `hermes:telegram` provider (`make-telegram`). The bot token is `TELEGRAM_BOT_TOKEN` or
  `:token`, held as an `aion/secret` secret, and replaced by `<redacted>` in the text of every
  failure the backend signals. `HERMES_TELEGRAM_IMPL` picks the backend, default `telegram`;
  `HERMES_TRANSPORT=dev` renders Telegram messages, and `dev-last-telegram` reads the last one.
  New with it:
  - `escape-markdown-v2` and `escape-telegram-html`, for text in those parse modes;
  - `edit-sent-message` (`:part :text` or `:caption`) and `delete-sent-message`, which take a
    `delivery-result`; the email and SMS backends signal `unsupported-message` for them;
  - `telegram-can-post`, which answers `:yes`, `:not-member` or `:not-permitted`;
  - the conditions `telegram-chat-unreachable`, `telegram-not-permitted` and
    `telegram-chat-migrated`, subtypes of `delivery-failure`. `telegram-chat-migrated` is a
    group that became a supergroup; `telegram-chat-migrated-migrate-to-chat-id` is the new
    chat id to send to;
  - `delivery-rate-limited`, a `delivery-failure` subtype for a provider's rate limit (HTTP
    429), whose `delivery-rate-limited-retry-after` is the number of seconds asked for, or
    NIL. hermes does not wait or retry; the hermes README shows a retry stored with
    `aion/schedule:schedule-once`. Only the Telegram backend signals it so far; SendGrid and
    Twilio still signal a plain `delivery-failure` for a 429;
  - `delivery-result-destination`, a new slot of `delivery-result`, NIL by default. Only the
    Telegram backend fills it, with the chat id.

  The log lines `hermes:send` writes are unchanged except that `hermes: sent` now carries
  `:channel` like `hermes: sending`; neither carries a message's text or recipient. Core
  `hermes` now loads `aion/secret`. upstream.sexp records Bot API 10.3.

- **hermes/blob: multipart uploads for files over 5 GB and for resuming a dropped upload** (#770).
  `start-multipart-upload` returns an upload id, `multipart-part-url` returns an `upload-target`
  for one part (part number and upload id signed, the size signed when given),
  `complete-multipart-upload` joins the parts from a list of `(part-number . etag)`,
  `abort-multipart-upload` frees them, and `list-multipart-parts` lists what has arrived, for
  resuming. A complete that S3 answers with an `<Error>` in a 200 signals `blob-backend-error`.
  `blob-upload-refused` gains the reasons `:bad-part-number`, `:bad-upload-id` and `:bad-parts`.
  The filesystem store signals `blob-unsupported`. `put-bucket-cors` takes `:expose-headers`;
  a browser completing a multipart upload needs `'("ETag")` there to read each part's ETag.
- **hermes/blob: `put-bucket-cors` sets the CORS rule a browser upload needs, and
  `check-bucket-cors` says why one would be blocked** (#770).
  `(put-bucket-cors store bucket :origins '("https://app.example.com"))` allows `PUT` with
  `Content-Type` from those origins (`:methods`, `:allowed-headers`, `:max-age-seconds` to
  change them). It replaces the bucket's whole CORS configuration, as the S3 API does.
  `(check-bucket-cors store bucket origin)` returns `:allowed`, `:no-cors-configuration`,
  `:origin-not-allowed`, `:method-not-allowed` or `:header-not-allowed`, for an upload that
  reached the app only as a network error. The filesystem store signals `blob-unsupported`.
- **hermes/blob: `upload-url` gives a client a presigned PUT for uploading straight to S3 or
  Spaces, and `read-blob-range` reads a blob's first bytes to check what arrived** (#770).
  `(upload-url store bucket key :expires-in :content-type :content-length :max-bytes)` returns
  an `upload-target` (`upload-target-url`, `-method`, `-headers`, `-expires-in`,
  `-content-length`). Content-Type and Content-Length are signed, so the store refuses another
  type or size. `:max-bytes` refuses to sign a declared size over it, or no declared size at all,
  with the new condition `blob-upload-refused` (`blob-upload-refused-reason`: `:too-large`,
  `:content-length-required`, `:bad-content-length`, `:bad-max-bytes`, `:bad-content-type`,
  `:bad-expiry`). A content type containing a control character, CR and LF included, is
  refused, and `upload-target-headers` returns the trimmed value that was signed. On S3 a
  declared size over 5 GiB, the single-PUT limit, is refused with `:too-large-for-single-put`.
  The app must still check the declared content type against its own allow-list: signing
  only binds the type the app passes in. The filesystem store, and any store class that does
  not implement `upload-url`, signals `blob-unsupported`, so a development app proxies through
  `put-blob`; a store class that does not implement `read-blob-range` reads the range through
  `get-blob`. `blob-meta-etag` carries S3's ETag from `blob-metadata`. The URL is never
  logged, and an `upload-target` prints without it. Usage, checking an upload and the
  security notes are in `hermes/docs/blob-direct-uploads.md`.
- **`scripts/build-installer.ps1` checks the WebView2 bootstrapper's signature, and takes
  `-RequireWebView2`** (#736). Before it embeds `MicrosoftEdgeWebview2Setup.exe`, the new
  `scripts/check-webview2-bootstrapper.ps1` requires a Valid Authenticode signature whose
  signer has the relative distinguished name `O=Microsoft Corporation`, compared exactly, on a
  cached copy as well as a fresh download, and prints the file's version and sha256. A copy that fails is deleted from `scripts/installers/.cache`. Without
  `-RequireWebView2` a failed download or check still builds the installer without the
  bootstrapper, with a warning, as before; with it, the build stops. An app that builds its own
  release installer should pass `-RequireWebView2`, as `desktop-release.yml` now does, so that
  a release never ships without a way to install the WebView2 runtime.

- **praxeon/image: `:image-usage` carries an estimated `:cost` for OpenAI's image models, from a
  pinned price table** (#758, part two). OpenAI reports token counts and no cost, so for a model
  in `praxeon/image:*openai-image-prices*` the event's `:cost` is computed from the reported
  tokens and OpenAI's published per-million-token prices, in US dollars as an exact rational,
  with `:estimated t`. `image-result-cost` is each image's share and
  `image-result-cost-estimated-p` is true. `praxeon/image:openai-image-cost` computes the same
  figure. The table covers `gpt-image-2`, `gpt-image-2.5-flare`, `gpt-image-2.5-sunburst`,
  `gpt-image-1.5`, `gpt-image-1-mini`, `gpt-image-1` and `chatgpt-image-latest`, and
  `upstream.sexp` records the date each row was read from OpenAI's pricing page ("OpenAI image
  prices: MODEL"). Where praxeon approximates (cached input, a token count the reply does not
  split), it uses the higher rate. For a model not in the table `:cost` is still absent. A
  model OpenAI has scheduled for shutdown keeps its row after the date, so a request made before
  it can still be priced; its entry's new `:retires` key holds the date, and
  `scripts/check-upstream.lisp --online` lists it under "Past its shutdown date" from that day.
  An app that kept its own per-image price list can compare it with this one.

- **praxeon/image: a `generate-image` means that creates images from a prompt, behind a neutral
  image protocol, with OpenAI's Image API as its first provider** (#758). Load
  `praxeon/image` and call `praxeon/image:register-openai-image` with `:on-image`, a function that
  receives each `image-result` (`image-result-octets`, `image-result-media-type`,
  `image-result-revised-prompt`, `image-result-size`, `image-result-quality`,
  `image-result-cost`) and returns a reference the model may see. It returns NIL and registers
  nothing when there is no key; the key is `:api-key` when given, otherwise
  `PRAXEON_IMAGE_API_KEY`, then `PRAXEON_OPENAI_API_KEY`; an `:api-key` of `""` is no key and is
  logged at warn. `:qualities` (for example `'(:low :medium)`), `:default-quality` and
  `:default-size` bound what an image can cost: the tool schema offers only the allowed qualities,
  and a call asking for another is refused before any request. A 429, a 5xx, or no answer within
  `:read-timeout` (default 120 seconds, `praxeon/image:*openai-images-read-timeout*`) signals
  `praxeon/image:image-request-failed` (`image-request-failed-kind` is `:rate-limited`,
  `:server-error` or `:no-answer`; `image-request-failed-retry-after` is the Retry-After seconds),
  a `provider-request-failed`; inside a turn the model is told to try again later and the turn
  goes on, with no automatic retry. A reply is read up to 24 MB per image
  (`praxeon/image:*max-bytes-per-image*`), and `:count` is 1 to 10. The default model is
  `gpt-image-2.5-flare` (`praxeon/image:*openai-image-model*`, or `PRAXEON_IMAGE_MODEL`). The bytes
  reach the app as the provider sent them, and the model never sees them. A content-policy
  refusal signals `praxeon/image:image-refused`, a `tool-error-result` with
  `image-refused-code`, `image-refused-stage` and `image-refused-categories`, so the agent is told
  and the turn goes on. **New event kind `:image-usage`**, one for each request that succeeds,
  with `:id`, `:principal` and `:agent` as on `:tool-result`, `:provider`, `:model`, `:count`,
  `:size` and `:quality`, and `:input-tokens`, `:output-tokens` and `:cost` only when the
  provider reports them (`:cost` is absent, never 0, when not reported). A refused or failed
  request emits no `:image-usage`. `generate-image` calls a provider outside a turn.
  `praxeon/llm` now exports `request-failure`, the #719 mapping of a failed HTTP request to
  `provider-request-failed`.

- **praxeon/image: edit an image, or make a variation of it, from reference images** (#758, part
  three). `praxeon/image:generate-image` takes `:references`, a list of up to 16
  `reference-image`s (`*max-references*`), and `:mask`. Make each with
  `praxeon/image:make-reference-image`, which reads the media type from the file's bytes and
  signals `praxeon/image:image-input-invalid` (a `tool-error-result`, outcome `:not-run`) for a
  file that is not PNG, JPEG or WebP, is empty, or is over 50 MB (`*max-reference-bytes*`). A
  mask must be a PNG with an alpha channel, the size of the first reference, which must be a PNG
  too; one that is not is refused before any request. With references the OpenAI provider posts
  `multipart/form-data` to `/images/edits`. A variation is an edit whose prompt asks for one,
  because `/images/variations` served only DALL-E. In a turn, `register` and
  `register-openai-image` take `:resolve-reference`, a function from a reference string the
  model gives to a `reference-image` or NIL, and `:max-references` (default 4); only then does
  the schema offer `reference_images`. A reference named twice is resolved and sent once. An
  unknown reference, too many, a resolver result that is not a `reference-image`, or a file that
  is not an image is a `:not-run` error result. One request's reference images and mask may come
  to at most 64 MB (`*max-reference-total-bytes*`). The provider is sent file names praxeon
  makes (`image-1.png`, `mask.png`); `reference-image-name` only labels refusals.
  `:image-usage` carries `:references`, the number of reference images, for an edit. New
  exports: `image-request-references`, `image-request-mask`, `reference-image-octets`,
  `reference-image-media-type`, `reference-image-name`, `*max-reference-total-bytes*`,
  `openai-image-edit-body`, `edit-body-fields`, `edit-body-files`.

- **hyperion/sidecar: dev sidecars, helper programs such as the Stripe CLI's webhook forwarder
  that start and stop with the dev server** (#700). Declare one with
  `hyperion/sidecar:define-sidecar` (`:command`, `:environment`, `:directory`, `:ready`,
  `:ready-timeout`, `:secret`, `:required`, `:restart`) and name it in the new `:sidecars`
  argument of `hyperion/dev:serve`, `hyperion/dev:watch` or `hyperion/desktop:run-app`. The
  sidecars start once the server has bound its port, with that port in place of `{port}` in the
  command, and stop when the dev session ends; a dev reload leaves them running.
  `hyperion/sidecar:token-after` makes a `:ready` function that captures a value from the
  sidecar's output, and `hyperion/sidecar:sidecar-value` returns it, as an `aion/secret` when
  the sidecar is declared `:secret t`. A program missing from PATH is logged as a warning, or
  signals `sidecar-not-started` when the sidecar is `:required t`; a sidecar that does not
  become ready signals `sidecar-not-ready`. A sidecar does not outlive an image that is killed:
  on Windows it runs in a kill-on-close job object, and one that cannot be put in a job is not
  started (`sidecar-not-started`, reason `:no-job`); on Linux it is started through
  `setpriv --pdeathsig KILL` when `setpriv` is installed, and on macOS, or Linux without
  `setpriv`, the next `start-sidecars` ends a sidecar left by an image that has exited, using
  state files under `~/.cache/hyperion-sidecars/`. `hyperion/server:serve-forever` takes no
  sidecars, and a shipped desktop image ignores them. `:environment` takes only string names and
  values; any other value, such as NIL from an unset variable, is an error at declaration. At
  debug level a sidecar's output lines are logged by length and stream, never by text. Core
  `hyperion` now depends on `hyperion/sidecar`, and through it on `aion/secret` and, on
  Windows, `aion/windows` and `cffi`. See `hyperion/docs/sidecars.md`.

- **hyperion/server: `handler-port` returns the port a running server listens on** (#700). On
  the native `:uv` server it is the port that was bound, which is the one the operating system
  chose when `start` was given port 0; on a Clack backend it is the port `start` was given.

- **aion/windows: `spawn-in-job` starts a process suspended inside a kill-on-close job
  object, with no console window, then lets it run** (#700). Every process the new process
  starts is in the job too, which `sb-ext:run-program` followed by `assign-process-to-job`
  could not ensure. Its standard input, output and error can each be a stream or the NUL
  device, and standard error can be appended to a file. It returns a `job-process`, read with
  `job-process-pid`, `job-process-input`, `job-process-output`, `job-process-error`,
  `job-process-alive-p`, `job-process-exit-code`, `job-process-status` and `job-process-wait`,
  and ended with `job-process-terminate` and `job-process-close`. `find-executable` finds an
  `.exe` or `.com` program on PATH, and `quote-windows-argument` and `windows-command-line`
  build a command line that the Microsoft C runtime splits back into the same arguments. A
  missing program or a batch file signals `process-not-started`.

- **praxeon: the tool-results benchmark reports the token counts the provider reported, and has
  two more configurations and a second task** (#319). `praxeon/bench/tool-results.lisp`'s
  `run-benchmark` now sums `:input`, `:output`, `:cache-read` and `:cache-write` from each
  step's `:usage` event and prints them beside its estimates; a count no step reported is NIL
  and printed as `-`. With a real provider, the estimated input is the sum of the
  `:estimated-input` of those events. Each figure taken from those events comes with the
  number of requests that reported it (`:reported-input-requests`, `:input-requests`, and so
  on), and the report marks a figure with `*` when fewer requests reported it than were made.
  Each row also gives the number of turns that signalled
  an error (the error text is not printed), the requests, and the clearing batches. New
  configurations `:clear-wide` (`:clear-budget 6000 :keep-recent 2`) and `:offload-and-clear`
  (`:threshold 500 :clear-budget 1200 :keep-recent 1`), and `:task :mixed`, where the
  even-numbered pages are under the offload threshold. `*scripted-usage*` makes the scripted
  model report usage, for tests. Offloading stays opt-in.

- **aion/schedule: a job scheduler, with `mnemosyne/jobs` to keep its jobs in Postgres or
  SQLite** (#689). An app registers a job function with `define-job`, with a schedule of
  `(:every seconds)`, `(:daily (hour minute) :zone "Europe/London")`,
  `(:weekly (:mon :fri) (hour minute) :zone ...)` or `(:once universal-time)`; a daily or
  weekly slot that falls in a daylight-saving gap runs at the first instant after it, and one
  that falls in an overlap runs once, at the earlier instant. `schedule-once` stores a one-off
  run with arguments; given a `:key` a stored job already has, it signals `job-exists` unless
  passed `:replace t`. Each instance of the app runs a `scheduler` over the same store, and a
  lease in the store means each slot runs once across all of them; a slot missed while no
  instance was running runs once when one starts (trigger `:catch-up`). Jobs run on an
  `aion/pool` pool the scheduler makes for itself, of two workers by default. Every run is
  recorded with its trigger, outcome (`:completed`, `:completed-with-errors`, `:failed`,
  `:skipped`, `:abandoned`), the counts plist the job returned, and an error text; a job calls
  `note-item-error` for an item that failed without failing the run. `run-now` and `run-job`
  run a job off its schedule, and start nothing while this instance is still running the job;
  when a run of the job is still starting here, `run-now` waits for it and returns its id. Each
  run gets its own copy of the job's arguments.
  `store-prune-runs` and `make-scheduler`'s `:keep-runs` limit the run log. Drive the
  scheduler with `start` (a thread) or `aion/schedule/uv:start` (a libuv timer), and end it
  with `stop`, which returns `:timed-out` while a lease renewal an earlier `stop` started is
  still using the store. **A job must tolerate running twice**: when an instance dies
  during a run, the run is marked `:abandoned` once its lease expires and another instance runs
  the job again (trigger `:retry`), once per slot: a retry that is abandoned too is not retried.
  A stored job that cannot be read back is returned with `stored-job-unreadable` set, logged
  once and left alone, and `run-now` on it signals `unreadable-job`; `define-job` or
  `schedule-once :replace t` rewrites it. A driver other than the two here calls
  `reserve-driver` before its first tick, so that a `stop` during that tick waits for it. A
  store's `store-finish` takes the stored job the run started from as `:remove-job`, and
  removes the job only when its definition is unchanged. Lease times come from each
  instance's own clock, which may differ from another's by up to about a third of
  `:lease-seconds` (100 seconds at the default of 300), so keep the instances' clocks
  synchronised. `mnemosyne/jobs:make-db-job-store` keeps
  jobs in the tables `aion_jobs` and `aion_job_runs`; it refuses to start with
  `missing-job-tables` until they exist, so add the statements from `jobs-ddl` to the app's
  migrations, or pass `:ensure t`. See `docs/scheduling.md`.

- **mnemosyne/conn: `with-transaction` takes `:immediate`** (#653). On SQLite an outermost
  transaction then begins with BEGIN IMMEDIATE and waits, within `*sqlite-busy-timeout-ms*`, for
  the database's write lock before it reads. A deferred transaction that reads first and then
  writes behind another connection's write transaction fails with SQLITE_BUSY at once, without
  the busy timeout. On Postgres, and for an inner transaction, it changes nothing.

- **praxeon/memory: `store-transactions-p`, `call-with-store-transaction` and
  `with-store-transaction`, for writes that take effect together or not at all** (#529). Both
  generics are optional: their default methods say a store has no transactions and call the
  thunk as it is, so a store an app wrote itself keeps working unchanged. The in-memory store
  implements them under its recursive lock, keeping a copy of the subject's observations and the
  thread's progress to put back on a non-local exit; `praxeon/memory-db` uses
  `conn:with-transaction` under its recursive lock, a savepoint inside an app's own
  transaction.

- **hyperion/auth-db: email confirmation, change of address and password reset** (#690).
  `issue-confirmation` and `confirm-email` confirm an account's address, and `email-confirmed-p`
  and `user-email-confirmed-at` report it. `request-email-change` (which requires the current
  password unless `:password :skip`), `confirm-email-change` and `revert-email-change` move an
  account to a new address, with a revert link to the old one that ends every session of the
  account. `set-email` is the operator path and requires `:actor`. `issue-password-reset` and
  `reset-password` reset a password. A change of address cancels the account's unused
  confirmation, change and reset tokens. Tokens are stored as SHA-256 hashes, and a failed one
  signals `invalid-token` with a reason. A user is sent at most 5 tokens of one purpose an hour
  (`too-many-tokens`); the limit and the lifetimes (24 hours, 1 hour for a reset, 7 days for a
  revert) are `make-db-auth` keys. `email-history` reads the log of confirmations and changes,
  and `prune-email-tokens` deletes expired tokens. The functions return the tokens and the app
  sends the mail.
- **hyperion/session: `end-sessions`** ends every session that holds a given value under a
  key, such as one user's sessions under `:user-id`, except the one named by `:except` (#690).

- **praxeon/llm: a `meta` impl for Meta's Model API (Muse Wonder)** (#678). Select it with
  `PRAXEON_LLM_IMPL=meta` or, for one role, `PRAXEON_<ROLE>_IMPL=meta`. It is an
  `openai-compatible` provider with `https://api.meta.ai/v1` as its default base URL and
  `muse-wonder-1.0` as its default model. The key is read from `PRAXEON_META_API_KEY` and is
  required: a role on `meta` with no key signals `missing-provider-key` at construction.
  Meta's API accepts only `tool_choice: "auto"`, so `supports-tool-choice-p` is false for
  `meta`, and a forced tool choice passed to `complete` signals `tool-choice-unsupported`
  before a request is sent. `generate-structured` works on `meta` through `response_format`
  (#680, below). `PRAXEON_META_MODEL` and `PRAXEON_META_BASE_URL` override the defaults.
- **praxeon/llm: `generate-structured` works on providers that take a schema as
  `response_format`, including `meta`** (#680). A new generic, `supports-response-format-p`
  (false by default), says whether a provider can be asked through the other new generic,
  `complete-with-schema`, for a reply whose text is a JSON object in a schema. `meta` says yes.
  `generate-structured` still forces a tool call wherever `supports-tool-choice-p` is true; it
  uses `response_format` only for a provider that cannot force one, and signals
  `tool-choice-unsupported` as before when neither is supported. A reply whose text is not a
  JSON object, or does not match the schema, is a rejected attempt with the same
  `structured-result-rejected`, `re-ask`, `structured-result-invalid` and
  `structured-result-truncated` as a bad tool argument; the reports of
  `structured-result-invalid` and `structured-result-truncated` now say "result" and "reply"
  rather than "call". A provider says which schemas it refuses through a third new generic,
  `response-format-schema-problem`; `meta` refuses a recursive one, and the refusal is
  signalled as the new condition `unsendable-schema` before anything is sent.
  `openai-request-body` takes a new `:response-format` argument.

- **klio: a collection name may not end in `.` or be a Windows device name** (#631).
  `make-site-options` refuses a `:collections` name with a segment that ends in `.`
  (Windows strips it, so `roles.` and `roles` would be one directory) or whose name before
  its first `.` is `CON`, `PRN`, `AUX`, `NUL`, `COM1` to `COM9` or `LPT1` to `LPT9`
  (`nul.txt`, `com1`), compared without regard to case. The rule applies on every operating
  system, so a site behaves the same everywhere. A space was already refused.
- **praxeon/mcp: on Windows, a local server and the processes it starts are ended together**
  (#599). Each server started for a `:command` connection is put in a job object that ends every
  process in it when the job is closed. `close-client`, a server that exits by itself, and the
  image's exit therefore also end what the server started, such as the program behind an `npx`
  or `.cmd` launcher. A server that exits by itself has its job closed within about 0.25
  seconds, by a thread that checks whether the server process is still running. A server that cannot be put in a job runs anyway, and the warning
  "local server is not in a job object" names its pid and the Win32 error code; such a server is
  ended alone with `TerminateProcess`, as before. A server ended through its job exits with
  code 1. `praxeon/mcp` now loads `aion/windows` on Windows.
- **aion/windows: job objects** (#599). `make-kill-on-close-job` creates a job that ends its
  processes when its handle is closed, `assign-process-to-job` puts a process in it by pid, and
  `terminate-job` ends its processes and leaves it open. Each signals `win32-error` when Windows
  refuses.

- **mnemosyne/conn: `connection-open-p` and `pool-backend`** (#636). `connection-open-p` tells,
  after a `db-error`, a connection Postgres has ended from a statement that failed on a working
  one: the first reads as closed, the second as open. It reads the client's state and sends
  nothing. `pool-backend` returns the backend a pool opens its connections from.

- **klio: a site can give a collection its own listing page, with `:collections`** (#557). Each
  collection named there gets a listing at `/<name>/`, paginated with `:per-page`, in the order
  the entry gives (`("roles" :sort-by "start" :order :descending :then-by "title")`), rendered by
  `:collection-theme` (default `klio:default-collection-theme`), with `klio:collection-url` for
  links. Off by default: without `:collections` nothing changes, and a hand-written listing
  document keeps working. A name is `/`-separated segments of letters, digits, `.`, `-` and `_`,
  none empty or starting with `.` or `_`. `make-site-options` refuses any other name, a name at
  or under the tag prefix, the page segment or another listed collection's page segment
  (`tags/lisp`, `page/2`), and a name given twice, without regard to case. `export-site` refuses
  two pages that cannot both be written, before anything is written: a listing and a document
  keyed `<name>/index`, or a collection named `one.html` and the document `one`.

- **praxeon/mcp: an ordinary call that asks for input can be answered, through an `:on-elicitation` handler** (#626).
  - `make-connection` takes `:on-elicitation`, a function of a plist (`:key`, `:mode`, `:message`, `:schema` or `:url`, `:method`, `:connection`, `:principal`) that returns `(values action content)`, and `:input-rounds`, the most retries one call makes, three by default. `:on-elicitation` needs `:elicitation`.
  - A `tools/call`, `resources/read` or `prompts/get` that answers `input_required` is sent again with the handler's answers in `inputResponses` and the result's `requestState` echoed exactly. Without a handler it still fails as not run.
  - A request the app cannot be asked (sampling, roots, an undeclared mode, a malformed elicitation), an answer that cannot be sent, a `requestState` that is not a string, or a server still asking after `:input-rounds` retries fails the call as not run. A handler that signals ends the call with its condition.

- **praxeon/mcp: a task can ask the user for input, and the app answers it** (#563).
  - `make-connection` takes `:elicitation`, a list of the modes `:form` and `:url`. It declares the elicitation client capability for them; sampling and roots are never declared. Without it nothing changes.
  - A task whose `tasks/get` says `input_required` with elicitation requests in declared modes sends a `:task-input-required` event per key not shown before, with `:input-key`, `:mode`, `:message`, `:schema` or `:url`, and `:task`. A request this client did not declare, or a malformed one (a form request without `requestedSchema`, a url request without `url`), still cancels the task with `:task-input-refused`.
  - `answer-task-input` sends the app's answer (`:accept` with content for a form-mode request, `:decline` or `:cancel`) with `tasks/update`, taking the task object the event carried. It checks with `tasks/get` that the key is still outstanding on the server first, and sends no answer otherwise. After an app restart, an unanswered key is not asked again; it is answered cancel when `:input-timeout` (ten minutes by default) passes, with a `:task-input-expired` event.
  - The task record has a new field, `task-inputs`, written by `task-to-json`; a record written before reads as having none.
  - An ordinary call that answers `input_required` can be answered too, through `:on-elicitation` (#626); see that entry.

- **aion/libgit: fetch, fast-forward pull and push** (#429). `set-remote` names a remote and
  `remote-url` reads one back. `fetch` updates `refs/remotes/<remote>/`. `pull` fetches, then
  fast-forwards HEAD's branch and checks it out, returning `:fast-forwarded` or `:up-to-date`
  with the commit id; given `:branch` in a repository with no commits yet, it moves HEAD onto
  that branch. `push-branch` pushes HEAD's branch, or `:branch`, to the branch of the same name.
  The credential is an argument: `:credentials` takes a `credential` from `make-credential`
  (a user name and a token, which may be an `aion/secret:secret`), or a function of the URL and
  user name that returns one. It is offered at most once, and a remote that refuses it signals
  `authentication-failed`. Other failures are conditions too: `not-fast-forward` and
  `checkout-conflict` from `pull`, which then change nothing but the remote-tracking branch,
  `push-rejected`, `detached-head` and `branch-not-checked-out`. `:follow-redirects` defaults
  to `:none`, so a redirect to another host is refused. libgit2 v1.9.5 fixed GHSA-2889-x8f6-mc4x
  (CVE-2026-53586) by asking the credentials callback with the redirected URL, but its own
  default still follows an offsite redirect on the first request, so the default here keeps a
  fixed credential from reaching another host. On Windows libgit2 does not follow a redirect to
  an http address at all. GHSA-h7gc-w2gg-p9xp (CVE-2026-53583, an inverted certificate IP check
  in the OpenSSL stream) was fixed in v1.9.5, and the pin is 1.9.7, so `aion/libgit` does
  nothing about it. Looking a credential up in `hades/credentials` is left to the caller until
  #357 lands.

- **klio: `export-site` takes `:assets`, a directory of the site's static files that is copied
  into the export** (#557). Every file is copied at its path relative to that directory, after
  `:clean t` has emptied the export, so a site no longer re-copies its stylesheet and images
  after each export. Dot-names are copied too, for `.well-known/`. `export-refused` is signalled,
  before anything is written, when the directory does not exist, when it holds or is inside the
  export directory (compared without regard to case on Windows and macOS), when it holds a link
  (a junction or symbolic link, which could lead outside it), when a file or directory name in it
  holds `*`, `?`, `[`, `]` or the escape character (`^` on Windows, `\` elsewhere), which a Lisp
  pathname reads as a wildcard, or when an asset and a page cannot both be written: the same path, or one under the other,
  such as `one.html/image.png` beside the page `one.html` (compared without regard to case). The
  returned list names the pages, then the assets.

- **klio: `klio:collection` and `klio:tree-collection` take `:then-by`, a second field that orders
  documents tied on `:sort-by`** (#557). It sorts in the same direction as `:order`, with a
  document lacking it last among the tie, and it also orders the documents that lack the
  `:sort-by` field. `:then-by` without `:sort-by` signals an error. Without it, ties keep
  ascending key order under both `:ascending` and `:descending`, as before. That rule is now in the README, so a site that worked around it can
  replace the workaround with `:then-by`.

- **praxeon/observe: running `distil` automatically over a conversation, off the request
  path, into observations of that conversation** (#317, step A). `make-observer` takes a
  provider, a store, a subject and a thread, and `observe-turn` is called with the thread's
  history after each turn and returns at once. When the messages past its mark reach `:step`
  estimated tokens (6,000 by default), it distils them on a thread of its own, one window at a
  time, writes each into the thread's scope with a provenance naming the conversation and the
  messages' range, and moves the mark past it. A window is whole exchanges up to `:step` tokens
  (`praxeon/prompt:exchanges`), so a tool call and its result are never in two windows.
  - The mark moves only past a window that was written, or given up on after `:max-attempts`
    failures (3 by default). A provider error, a store error part-way through the writes, or a
    failed support check is retried after `:retry-delay` seconds (2 by default), and each later
    retry waits twice as long. A retry does not store an observation twice, and it runs the
    window's promotion again. A window given up on is recorded in `observer-skipped` as
    `(from through tries)`, message positions counted from 1, and each later run tries it again
    until `:max-attempts` runs have given up on it. Every failure is counted in
    `observer-failures`, with the last in `observer-last-error`.
  - The mark and the skipped windows are kept in the store (`thread-progress`) after each
    window, and a new observer starts from them. So a restart neither distils the thread again
    nor passes a window that was given up on or that the process ended part-way through.
    Observations the app wrote into the thread itself do not move the mark, except at an erasure
    (below). A progress write that fails is made again at the next `observe-turn`, even one with
    no new message; until it is made, a stop, a restart or a new observer distils that window
    again. Progress is merged with the store's, never written over it: a run starts by merging,
    and each save merges again, so, through one store object in one process, the stored mark is
    never lowered and newer progress at an equal mark is kept. Up to the smaller of two records'
    marks, a message stays skipped only when both records hold a skipped window over it: for
    each pair of overlapping skipped windows the merge keeps their overlap, and a window of the
    further record that crosses the smaller mark is split there. A record that holds a skipped
    window past its own mark, as an observer made with a lower `:mark` does, counts as reaching
    that window's end. So where two observers cut the same messages into different windows no
    message is left undistilled and uncovered, and no message one of them has since distilled is
    put back to be retried. A run whose first read of the store's progress fails ends there.
  - One observer of a thread runs at a time in a process: `observe-turn` starts nothing while
    another observer of the same store object, subject and thread holds the thread, even when
    both are called at the same moment, so an app may make an observer per request.
    `running-observer` names the observer holding a thread. A refused call is logged and does
    nothing else; a refused `:flush` is not queued, so flush again once `running-observer`
    returns NIL. Observers of one thread through two store objects over one database, or in two
    processes, are not coordinated.
  - `forget-subject` refuses, with `observer-running` naming the thread, while an observer of the
    subject is running in this process through the same store object; stop it with
    `stop-observer` on `running-observer` and call it again. Observers through another store
    object over the same database, or in other processes, cannot be seen, and the app stops them
    first. On `praxeon/memory-db` the check and the erasure hold the store's lock together, and
    the erasure is one transaction, a savepoint inside a transaction the app opened with
    `conn:with-transaction`. A transaction begun with a raw `BEGIN` is not seen: on SQLite the
    call then signals and changes nothing, and on Postgres the call's `COMMIT` ends the app's
    transaction, so the app's earlier writes commit, and no error is raised.
  - `forget-subject` erases the subject's observations, as before, and leaves each of its
    threads' progress records as the mark alone: the subject's id, the thread's id and a count
    of messages, with no skipped windows and no content. The mark is at least the last message
    the thread's erased observations cited, counting only provenance that names the thread
    itself, so a progress write that failed before the erasure does not let erased content be
    distilled and written again; for the same reason a thread with observations and no record
    gets one. An app that writes observations into a thread cites the thread's message
    positions, counted from 1. Even then, a cited position past the observer's mark, such as a
    correction the app makes at a later message, raises the mark past messages that were never
    observed, and they are not observed afterwards. It does not erase
    the app's own transcript. Messages up to the mark are not observed again: an observer that
    held skipped windows from before drops the parts up to the mark at its next run and keeps
    the parts past it, which were never written, and a new observer starts at the mark. Later
    messages are observed normally. A conversation continued after an erasure with a shortened or
    replaced transcript uses a new thread id, because the stored mark wins over a lower `:mark`, and
    the transcript's first messages would otherwise never be observed.
  - A skipped window is retried only while no later window has been written to the thread, and
    then it is distilled and promoted as if it had never been skipped. Before a window's
    observations are first written, in a run or in a retry, every open skipped window before it
    is closed, whatever its tries, and the progress is saved. The progress is also saved there
    while the observer is unsaved and a closed skipped window lies before the window, because the
    store may lack that closure. If that save fails, the model's answer for the window is
    discarded and nothing of it is written; no try is counted, the mark stays where it was, and
    the run ends, so no later window in the same run can close the window that was not written.
    The window's line in the log has outcome `:unsaved`, and the next run asks the model again
    (#622). So while progress writes keep failing and a skipped window lies before the next
    window, each turn makes one model call whose answer is discarded, and no later window is
    written until a progress write succeeds. An observer with no skipped window before the next
    window keeps writing observations while progress writes fail. A closed window is never
    retried, and
    `observer-skipped` shows it as `(from through tries :closed)`. A window is closed this way
    even when the later window's write then fails. Whether a window is closed comes from the
    progress record alone, not from the thread's observations,
    so an observation the app writes into the thread closes nothing, and erasing a later
    window's observations reopens nothing. A window whose tries are spent, with no later window
    written, stays open and is not tried again.
  - `make-observer` refuses `:accept`, `:promote` or `:promote-accept` that is not a function or
    the name of one, including a symbol that names a macro or a special operator, such as
    `when`.
  - If the observer's thread cannot be made, `observe-turn` signals the error and gives back its
    claim on the conversation, so a later call can start a run. The claim, the thread and its
    recording are one step with interrupts deferred, so a deadline around the app's request
    neither gives back the claim while the thread runs nor keeps it with no thread. The thread
    unblocks interrupts as it starts, so after such a deadline `stop-observer` can still end it,
    and a timeout inside the provider's own call still fires.
  - `stop-observer` gives back the claim once the thread it ended has stopped, so
    `running-observer` no longer names the observer. When the thread has not stopped 5 seconds
    after `:timeout`, it returns NIL with the claim still held. `stop-observer :timeout 0` ends
    the run without waiting first and returns NIL, as for any timeout that passes, instead of
    signalling a `type-error`; `await-observer :timeout 0` only reports whether a run is going,
    and `:timeout nil` waits with no limit.
  - A proposed replacement is applied only when `:accept` allows it. A thread observation also
    becomes a fact about the subject only when `:promote` allows it, and by default nothing
    does. A fact the subject already holds is not stored again. A promoted observation is
    matched to the subject facts it descends from: those whose content is its own or that of any
    thread observation it corrects, through any chain of corrections, superseded facts included,
    whoever wrote them. When there are any and the observation corrects a thread observation, it
    replaces their current successor only when `:promote-accept` allows it; when it corrects
    nothing it restates an old value and is not promoted. Otherwise nothing is promoted, so the
    subject never holds a fact and its correction as two current facts. The chain is followed
    within one thread: a correction refused in one conversation can still reach the subject when
    another conversation states the corrected value with nothing to link it. A thread fact that
    contradicts a subject fact with no such link is promoted beside it; `:promote` has to judge
    that case. The subject then holds both as current facts, and when a later correction's chain
    reaches several current facts, only the first is replaced and the others stay current.
  - `:verify`, a provider, drops proposals the window does not support, judging their content,
    kind, date and any claim to replace an earlier observation.
  - `stop-observer` stops it at shutdown, `observer-stuck-p` reports a call running past
    `:window-timeout`, `observe-turn :flush t` distils the last messages below a step, and each
    window writes one `aion/log` line of counts.
  - `praxeon/memory` has a thread scope: an observation's `thread` is NIL for a fact about its
    subject and a thread's id for an observation of that thread, and `observations-of :thread
    :all` reads both. The in-memory store is now safe to share between threads.
  - A provenance can name a range of turns with `:through`.
  - `distil`'s tool takes an optional `applies_from` date, which becomes the observation's
    `valid-from`; `distil` takes `:today` to tell the model the date (the observer passes the
    time `observe-turn` was called, in UTC); a date that cannot be read drops only its own
    proposal, and so does an `applies_from` that is a number, an array, an object or `true`.
    JSON null, `false` (which jzon reads as NIL) and an empty string mean no date.
    `apply-distillation` takes `:thread`.
- **`scripts/build-installer.ps1` and `scripts/build-dmg.sh` read the bundle's `RELEASE` file,
  which `scripts/build-desktop-app.lisp` writes when given `--product`, `--display-name` or
  `--default-channel`** (#408).
  - Both refuse a bundle whose `RELEASE` names a product or version other than the one the
    bundle gives: the bundle directory's name for the installer, and the launcher's name and
    the `VERSION` file for the dmg script. An app packaged under another name registers under a
    key its updater does not read, so rebuild rather than rename a bundle directory.
  - `build-dmg.sh` names the `.app` after `RELEASE`'s `display-name` when `--display-name` is
    not given. A `--display-name` on the command line still wins. Either way, it refuses a
    display name that contains a slash or starts with a dot or a dash, which would name a
    directory outside `--out` or a hidden one, or reach `tar` as an option. It applies
    `build-desktop-app.lisp`'s rule for `--display-name` (1 to 128 characters, no control
    characters) to a name given on its own command line, and it XML-escapes the name in
    `Info.plist`, which a name with `&` or `<` used to make malformed. A `RELEASE` file saved
    with CRLF line endings is read correctly.
  - On Windows one name is still both the `HKCU\Software\<name>` key and every name the user
    sees. `RELEASE`'s `display-name` is not used there.
  - `build-installer.ps1 -Describe` and `build-dmg.sh --describe` check a bundle and print the
    product, version and executable or display name they would build with, without building
    anything. Neither needs a packager, and `--describe` does not need macOS.
  - A bundle without `RELEASE` is packaged as before.
- **praxeon/mcp: agents can use the tools of a local MCP server that the app starts as a child
  process and talks to over stdio** (#527, part 5).
  - `make-connection` is now a function, not only the structure's constructor, and takes
    `:command` (a list of strings: the program and its arguments) in place of `:url`, with
    `:directory`, `:environment`, `:stderr` and `:restart`. It refuses `:url` and `:command`
    together, and refuses `:token-source` and `:per-user` with `:command`, because a server over
    stdio takes its credentials from its environment. The accessors `connection-command`,
    `connection-directory`, `connection-environment`, `connection-stderr` and
    `connection-restart` are exported.
  - The server's process gets only the variables `+stdio-environment+` lists from the app's
    environment, plus the connection's `:environment` alist. The list is the MCP TypeScript
    SDK's `DEFAULT_INHERITED_ENV_VARS` (#604). On Linux and macOS that is `HOME`, `LOGNAME`,
    `PATH`, `SHELL`, `TERM` and `USER`, to which praxeon adds `LANG` and `TMPDIR`. On Windows
    it is 18 names, including `APPDATA`, `LOCALAPPDATA`, `PROGRAMDATA`, `SYSTEMROOT`, `TEMP`
    and `USERPROFILE`. A value that starts with `()`, an exported bash function, is not passed.
    `:environment :inherit` passes the whole environment.
  - The client finds the server's era with `server/discover` and falls back to `initialize` for
    a legacy server. A request that times out after it was written gets
    `notifications/cancelled`; one that times out while still queued fails as not run and is
    never sent. A line longer than `:max-body-bytes` octets, counted as received, is dropped.
    `client-era` and `client-protocol-version` describe the running server: once a request finds
    that it has exited, they are NIL until a new server's handshake succeeds (#610), and after
    `close-client` they are NIL (#601). The server's stderr is discarded, or appended to the
    `:stderr` file, and never logged.
  - With `:restart t`, the default, a server that exits is started again at the next request,
    at most 3 times in any 60 seconds. With `:restart nil`, every later request fails as not
    run until the app closes the client and makes another.
  - `close-client` (new) closes the server's stdin, waits `*stdio-close-seconds*` (5), sends
    SIGTERM, waits `*stdio-term-seconds*` (2), then sends SIGKILL, to the server's process
    group. Running servers are closed the same way when the image exits, so a client stays
    reachable until `close-client`. On Windows the server runs in a job object, and ending it
    ends the processes it started too (#599); see the entry under Added.
  - A server's pipes are closed only once its reader thread, its writer thread and the client's
    cleanup are all done. A writer still blocked 2 seconds after the server is finished,
    because a process the server started holds its stdin and does not read it, is ended, and
    that process is not signalled (#601). Ending the writer closes the server's stdin, so a
    process that also holds the server's stdout and waits for the end of stdin exits, and the
    reader thread ends with it (#628).
  - `list-tools`, `call-tool`, `grant-tools`, resources, prompts and tasks work over stdio
    unchanged. `praxeon/docs/mcp.md`, "Local servers over stdio".
- **praxeon/mcp: an app can add an MCP server's resources to an agent's context, and get its
  prompts** (#527, part 4).
  - `list-resources` and `list-resource-templates` follow pagination.
  - `expand-uri-template` expands RFC 6570 templates at levels 1 and 2, with variable names as
    section 2.3 defines them (dotted segments and percent-encoded octets), and refuses the rest.
  - The text of `sign-in-needed` says the connection's server needs a sign-in, not "this tool",
    since resources and prompts can need one too.
  - `read-resource` returns a resource's contents. Binary content is kept only as its length.
    A missing resource signals `resource-not-found`, and a reply with a malformed content fails
    whole rather than returning part of the resource. A resource is always read through its
    server, even when its URI is `https://`.
  - `add-resource` adds one context item per content. Each item's text starts with a line
    naming the resource and its connection, and saying the text is data from that server, not
    instructions. A second `add-resource` of the same resource replaces the first, and
    `remove-resource` takes it out. A content larger than the agent's context budget signals
    `resource-too-large`, and nothing is added. The items stay for every later turn whoever
    its principal is, so add a per-user resource only to an agent that serves that user.
  - `list-prompts` and `get-prompt` return a prompt's messages as `praxeon/llm` messages.
    `get-prompt` refuses a missing required argument before sending anything, and fails a reply
    with a malformed message rather than leaving the message out.
  - `prompt-input` turns a prompt whose messages are all the user's into the input of
    `run-turn`, and signals `prompt-has-assistant-messages` for a scripted exchange.
  - Only the app adds resources; the model cannot read one itself. Subscriptions, completions
    and caching are not supported. See `praxeon/docs/mcp.md`.

- **`build-desktop-app.lisp` sets the update settings in the image it dumps** (#408).
  - New options, in `scripts/release-settings.lisp`. Each sets its variable only when it is
    given, so a build without it keeps the value the app set in its own source:
    - `--product NAME` sets `hyperion/update:*app-name*`. For now it must equal `--name`,
      because the installer still takes its name from the bundle directory.
    - `--display-name TEXT` is written to the `RELEASE` file.
    - `--public-key-file PATH` sets `*public-key*`. With `--release` and no key file, the
      `OURANOS_PUBLIC_KEY` environment variable is read; without `--release` it is not. The key
      must have the form `scripts/update-manifest.lisp keygen` prints, and is checked with
      `aion/signature` before it is set.
    - `--update-source github=URL` and `--update-source s3=URL` set `*update-source*`. Given
      more than once, they are tried in the order given. The URL must be https.
    - `--default-channel NAME` sets `*default-channel*`.
    - `--release` refuses to build without a key and a source.
  - A bad option stops the build with exit code 2 before anything is built.
  - A release option given for an app that does not load `hyperion/update` stops it with exit
    code 3.
  - The bundle gets a `RELEASE` file with a `version` line and a `product`, `display-name` or
    `channel` line for each of those options given, written after the settings are set in the
    image. With none of those three given, there is no `RELEASE` file.
  - A key file may hold one key, until key rotation is decided.
  - New `hyperion/update:*default-channel*`, default "stable". `check-for-update` and
    `apply-update` use it when no `:channel` is given, and so does `update-router` when it is
    given no channel.
- **aion/fs: `make-temporary-directory` creates a new temporary directory that no other process
  is given** (#515). It is named after a prefix, the process id and a counter of the process's
  own, and it counts as made only when this call created it, so two processes started at the same
  moment never share one. The prefix must be one plain name: one with a path separator, a colon,
  a wildcard, or `.` or `..` alone is refused. The test fixtures in `hyperion/server-uv/tests`, `hyperion/tests` and
  `klio/tests` that made a directory by deleting a file from `uiop:tmpize-pathname`, or named it
  by the time and a counter, use it now; the first of those patterns failed when two suites
  started together on one machine.
- **praxeon: a means can require the user's confirmation before it runs** (#531, part of #64).
  `register-means :confirm` (T, or a function of the arguments returning an estimate plist) marks
  a means. `run-turn :on-hold` is the app's policy: NIL, the default, runs no held call and tells
  the model no confirmation was available; a function returns `:approve`, `:decline` or `:hold`;
  `:hold` ends the turn with `(values nil :held held-turn)`. The app stores the held turn
  as JSON text (`held-turn-to-json`, `held-turn-from-json`) and continues the turn with
  `continue-turn` and the user's decision, from any request or thread or after a restart. A
  decision is recorded once through the app's `:claim`, so an approved call runs once even when
  two decisions arrive together. `continue-turn` checks the principal (`wrong-principal`), the
  agent, and that the held turn's calls, their means, their order and their arguments are the
  ones in the history's model message (`held-turn-mismatch`). `run-turn` signals
  `held-turn-required` when the history ends with undecided held calls and no `:held` is given;
  `abandon-held-turn` closes one, and returns `(values nil :already-decided decision)` with the
  decision recorded first when the turn was decided before.
  The events `:tool-held` and `:tool-decided` record what was asked and decided, with the
  tool-call id under `:id` and the held turn's id under `:held`. Without `:claim`, decisions
  are kept in a table in the process that is never emptied, so a long-running server supplies
  its own. `run-turn-through` takes the same arguments and returns the held turn as a third value. A
  delegated sub-turn inherits a blocking `:on-hold`, not `:hold`. A turn with no principal holds
  nothing. A turn continued after a call held on its last step runs the decided calls and then
  signals `deliberation-failure`, as an ordinary turn does after its last step, without asking
  the model again. See `praxeon/docs/confirm.md`.
- **praxeon/mcp: `grant-tools :confirm`** (#531), a list of the server's tool names to hold, or
  `:all`. Such a tool is registered with `:confirm t`, and after a refused token it is not sent
  again: the token is refreshed and the call fails as not run, telling the model the user can
  ask again. `call-tool` takes `:held` for the same rule. Any other `:confirm` value, or a name
  that is not among the granted tools, signals an error and registers nothing, because a
  misspelt name would let the tool it meant run without confirmation.
- **aion/oauth: sign an app's users in to other services with OAuth 2.1** (#527, part 2). A new
  opt-in system, in aion so that hermes can use it too.
  - `make-broker` holds the app's settings and a store: `:redirect-uri`, `:client-name`,
    `:application-type`, `:client-metadata-url`, `:pre-registered`, `:timeout`,
    `:sign-in-lifetime`, `:metadata-lifetime` and `:metadata-grace`.
  - `start-sign-in` returns the URL to send a user's browser to, and the scopes it requests.
    `finish-sign-in` takes the parameters the browser came back with and the principal of the
    session it came back in; both refuse a NIL principal. `access-token` returns a principal's
    token for a connection, refreshing it when it has expired; `refresh` and `disconnect` do what
    they say, and both take `call-with-refresh-lock`, as does storing a new sign-in's tokens.
  - `discover`, `canonical-resource` and `parse-challenge` are exported for an app that needs
    them. `parse-challenge` reads the Bearer challenge only where a challenge starts, so the
    word bearer inside another challenge's quoted parameter is not taken for it. The conditions are `oauth-error`, and under it `unknown-sign-in`, `wrong-user`,
    `sign-in-failed`, `metadata-refused`, `url-refused`, `no-client` and `refresh-failed`.
  - The store protocol (`get-token`, `put-token`, `delete-token`, `get-client`, `put-client`,
    `delete-client`, `put-pending`, `take-pending`, `call-with-refresh-lock`) is implemented by
    the app, over its own storage. `delete-client` takes the client id and deletes only on a
    match, as one step. Every slot of `token-set` and `pending` is exported, with `make-token-set` and
    `make-pending`, so a store can keep both as strings. `memory-store` is for tests and
    one-process apps, and drops expired pending sign-ins.
  - It follows the MCP authorization specification, revision 2026-07-28. Metadata is checked;
    the resource URL and every URL from a server must be https, or http on a loopback host,
    and are fetched through `fetch-public` with no redirects; the `iss` response parameter is checked; a token response
    must say `token_type` Bearer; and the client id comes from a pre-registered client, a client
    ID metadata document at an https URL (`client-metadata-document`), or a dynamic
    registration. A token is sent only while the resource's metadata, cached for
    `:metadata-lifetime`, still names the issuer that issued it; a failed fetch never renews the
    cache. A refresh refused with `invalid_grant`, `invalid_client` or `unauthorized_client`
    deletes the tokens, and `invalid_client` also forgets a client registered dynamically, when
    it is the one those tokens were issued to, so the next sign-in registers a new one. See
    `aion/docs/oauth.md`.
  - Every request has an overall deadline, one second past the broker's `:timeout`, so a server
    that sends a byte now and then cannot hold a sign-in or a refresh, and its lock, for longer.
    A request given up at its deadline keeps running until the server finishes; when
    `aion/oauth::*max-abandoned-requests*` (8) of them are still running for one host, a new
    request to that host signals `oauth-error` without being sent. Other hosts are not affected.
  - Not on Windows yet: like `fetch-public`, it signals `pinned-connect-unsupported` there.
- **hyperion/oauth: the routes an app mounts for aion/oauth** (#527, part 2).
  `sign-in-return-handler` finishes a sign-in at the redirect URI, for the principal that
  `:principal-of` reads from the request's session. `client-metadata-handler` serves the app's
  client ID metadata document.
- **praxeon/mcp: MCP servers that require an OAuth sign-in** (#527, part 2).
  - A token source is now anything that implements `token-for`, as functions already do. An
    error from a token source, a plain function included, now fails the call with
    `request-failed` and outcome `:not-run`; before, it reached the caller.
  - A source may implement `token-refused`, so that a request the server refused with a 401
    or 403, the legacy `initialize` included, is sent once more with the token it returns. A
    `token-refused` that fails gives `:not-run`, not a request to sign in.
  - `oauth-token-source` gives each principal's tokens from an `aion/oauth` broker, refreshing
    them as needed.
- **praxeon/mcp: agents can use the tools an MCP server offers** (#527, part 1). A new system,
  `praxeon/mcp`, talks to MCP servers over Streamable HTTP, in the current revision of the
  specification (2026-07-28) or, when a server does not understand it, in the legacy
  revisions with their `initialize` handshake. `make-connection` describes a server: its name,
  URL, `:token-source` (a function of the connection and a principal that returns a bearer
  token), `:per-user`, `:timeout` and `:call-timeout` (seconds, 30 and 120), and
  `:max-body-bytes` (8 MiB). `make-client` makes the client that talks to it, and nothing is
  sent until it is first used. `list-tools` reads a server's tools and gives them to no agent,
  leaving out a tool whose `inputSchema` is not an object schema or is larger than
  `*max-schema-characters*` (20000), and failing a listing that goes past `*max-list-pages*`
  (1000) pages, or that has a page whose `tools` member is missing or is not a list. A tool's
  description is clipped to `*max-description-characters*` (2000).
  `call-tool` calls one directly. `means-name` gives the name a tool is granted under.
  `grant-tools` registers the tools the app names in its required `:only` (a list, or `:all`)
  as means named `<connection>__<tool>`, and
  refuses with `tool-name-conflict`, registering nothing, when a name is taken. `revoke-tools`
  removes them. Each call uses the token of the turn's principal. A failed call is reported
  to the model and the turn goes on: `tool-error` for a result with `isError`,
  `request-failed` for a failed request, and `sign-in-needed` when the user must sign in, which
  also signals `authorization-required` and emits a `:sign-in-required` event. A tool call that
  may have run is never sent twice. Every request has a deadline of its own, one second past its
  timeout, whatever the transport does; a request given up at it keeps running on a
  `praxeon/mcp request` thread until it ends, and logs how it ended. At
  `*max-abandoned-requests*` (8) such threads on a client, the client refuses new requests until
  some finish. See `praxeon/docs/mcp.md`. OAuth sign-in is part 2.
- **praxeon: the `:tool-call` and `:tool-result` events carry `:source`, `:principal`, `:agent`
  and `:conversation`, and `:tool-result` carries `:outcome` and `:ms`** (#527).
  `register-means` takes a `:source` plist, such as `(:connection "docs" :tool "search"
  :per-user t)` for an MCP tool, and `:outcome` is
  `:ok`, `:error`, `:not-run` or `:unknown`, from `tool-error-result-outcome`. This is what a
  usage ledger needs to record a call, until #493 settles the usage interface.
- **aion/test-http: the HTTP server aion/http-client's tests ran, as its own system** (#527), so
  other test suites can run a server in the test image. Test support only.
- **praxeon: a means can report an error to the model, and the turn goes on** (#527). A means
  that signals `praxeon/conditions:tool-error-result` with a `:text` gives the model a tool
  result marked as an error, carrying that text, and `run-turn` runs its next step. Any other
  error from a means still ends the turn as `means-failure`, with `act`'s restarts, as before.
  The `:tool-result` event carries `:is-error t` for such a result. The Anthropic adapter
  already sent `is_error`; the OpenAI-compatible adapter, whose format has no such field, now
  starts the content with `Error: `.
- **praxeon: `run-turn` and `run-turn-through` take a `:principal`, the user the turn runs for**
  (#527). It is bound for the turn as `praxeon/actor:*principal*`, which a means reads when it
  is called, so each call acts with that user's credentials. It does not separate
  conversations: an agent has one history, from which every request is built, so each user needs an agent,
  or at least a history, of their own. A turn without a principal keeps the principal of an
  enclosing turn, so a delegated sub-turn runs for the same user.
- **`cons bin` copies libuv, mbedTLS and libgit2 beside the binary it dumps, for each one the
  app loads, and libgit2's source with it.** The build script a `cons init` project gets
  (`scripts/build-<name>.lisp`, for the agent, cli and web templates) now loads the Ouranos
  tree's `scripts/tree-natives.lisp` before the dump. For each of those libraries that the app's
  image loads, it copies the library into `bin/` and its licence into `bin/LICENSES/`, and it
  sets `aion/platform:*search-source-tree*` to NIL in the image, so the binary uses the copy
  beside it rather than the tree's `vendor/`. For libgit2 (`aion/libgit`) it also copies the
  source tarball that `libgit2.pin` names into `bin/SOURCES/`, and `COPYING` into
  `bin/LICENSES/libgit2-COPYING`. **An app that distributes the binary has to ship
  `bin/SOURCES/` and `bin/LICENSES/` with it**, because libgit2's licence, the GPL version 2 with
  a linking exception, requires its source to be available wherever the binary is distributed
  (ADR-0013, amendment of 2026-10-04). A `bin/<name>` from the web template runs on a machine
  without the tree and without libuv; copy `bin/` as a whole. The build stops with exit code 3,
  and says why, if one of these libraries was loaded from somewhere other than the tree's
  `vendor/` (a system copy, or a path in `AION_UV_LIBRARY`, `AION_TLS_LIBRARY` or
  `AION_LIBGIT_LIBRARY`), if this machine has no built copy of one the app loads, or if
  libgit2's tarball is missing or its sha256 does not match `libgit2.pin`. Other libraries the
  app loads from the system, such as OpenSSL for an app that uses it, are listed in the build's
  output and not copied. A project generated before this change keeps its old build script:
  replace it with the template's, or add the two forms after
  `(ensure-directories-exist "bin/")`. `scripts/build-desktop-app.lisp` uses the same file.
  (#513, #524)
- **hyperion/desktop: `run-app :placement-file` reopens the window where it was last time, on
  Windows.** Pass a path in the app's data directory. hyperion-view, given
  `--placement-file PATH`, writes the window's position, size and maximised state there when a
  drag ends, on a maximise or restore, and on close, as one line (`hyperion-view-placement 1
  LEFT TOP RIGHT BOTTOM MAXIMIZED`), and at the next start puts the window back there if that
  rectangle still lies inside a monitor's work area, allowing for the window's invisible resize
  borders so that a snapped window counts as inside; otherwise it opens centred. When the saved
  rectangle is on a monitor with different scaling from the one the window opens on, the
  borders are converted to that monitor's frame width, and the rectangle is set a second time
  after Windows rescales the window; neither has been measured on two monitors yet. A move made
  without dragging or resizing, such as Win+Shift+Arrow, is saved only at the next of those.
  The default, NIL, keeps no file. `hyperion-view --saved-placement PATH WL WT WR WB [BL BT BR
  BB [FROM TO]]` prints whether a saved placement would be used, with optional border widths
  and the frame widths to convert them between. `hyperion-view --exercise-placement PATH` opens
  a window from the file, moves, maximises, restores, minimises and closes it, and prints the
  file after each step and how many times the move wrote it; it is for CI. Rebuild
  `hyperion-view` to get it: an older build refuses `--placement-file` and exits 2.
  macOS and Linux accept the option and ignore it. With `HYPERION_VIEW_NO_WINDOW=1` in its
  environment, hyperion-view exits 3 instead of creating a window, on every OS; the view tests
  set it, so a test that reaches a window by mistake fails instead of opening one. (#485)
- **`cons bin` removes from `bin/` the libraries an earlier build copied there, before copying
  this build's** (#564). `carry-tree-natives` in `scripts/tree-natives.lisp` keeps a list of
  the files it copies into `bin/` in `bin/.carried-natives`, one path per line, relative to
  `bin/`. Each file is added to the list just before it is copied, so a build that stops
  part-way, or a copy that fails, still names everything it started to write. If such a copy
  fails without writing anything, a file that was already at that path in `bin/` is deleted by
  the next build; a copy that succeeded would have replaced it anyway. The next
  build deletes the files on that list, then copies again. So a library the app no
  longer loads, with its `bin/LICENSES/` file and, for libgit2, its `bin/SOURCES/` tarball, is
  no longer left in `bin/` and shipped. Files the list does not name, such as anything else an
  app keeps in `bin/`, are not touched. A `bin/` built before this change has no list, so its
  old copies stay until it is emptied once by hand. If a listed file cannot be deleted, for
  example because a copy of the binary is running, the build stops with exit code 3 and names
  the file. A line naming a path outside `bin/`, a link, a path through a linked directory, or a
  directory is reported and left. A `bin/.carried-natives` that is itself a link, dangling or
  not, is refused before it is read or written: `carry-tree-natives` signals
  `carried-list-refused`, which `scripts/tree-natives.lisp` exports, and exits with code 3,
  naming it. The check that a library will be carried and the copy now decide whether it is under
  the tree's `vendor/` with the same function, `vendored-library-p`. Before, through a tree
  reached by a symbolic link, the check could pass a library that the copy then left out as a
  system library. `scripts/build-desktop-app.lisp` uses the same function.
- **aion/libgit: local git repositories, over a libgit2 this tree builds from source** (#429).
  A new opt-in system. `init-repository` and `open-repository` return a repository, and
  `with-repository` closes it. `stage` adds changed files to the index and removes deleted ones.
  `commit` commits the index with HEAD as its parent and returns the new commit id. Both re-read
  the index first if another process, such as `git add` or `git checkout`, changed it. `history`
  lists commits newest first as `git log` does; with `:path`, the commits `git log -- PATH`
  lists, including a change of mode alone and with git's default simplification at merges.
  `read-at-revision` returns a file's octets as they were at a revision, and `diff-text`
  returns the patch between two revisions as `git diff` prints it, renames included. A failed libgit2 call signals `git-error`, which
  carries libgit2's code, class and message. The library is libgit2 1.9.7, pinned in
  `libgit2.pin` and built by `scripts/build-libgit2.lisp` with a C compiler alone; it is
  GPLv2 with the linking exception. `aion/libgit` loads it from `AION_LIBGIT_LIBRARY`, beside
  the image, or `vendor/libgit2/lib/`, and refuses with `libgit2-mismatch` a library that is
  not 1.9, was built without threads or with experimental SHA-256, or whose functions resolve
  to another libgit2 already loaded in the process. Fetching and pushing are not in this step. The gate
  runs its suite when `OURANOS_WITH_LIBGIT=1`, which CI sets.
- **hyperion/i18n: `translation-exists-p`, whether a key has a translation** (#490).
  `(translation-exists-p source locale key &key count)` is true when `translate` (or, with
  `:count`, `translate-plural`) would return text from the source rather than its
  `"[section/key]"` marker, looking in the locale and then the source's default locale. A
  component that wants its own fallback asks this instead of comparing `translate`'s result
  with the marker, which reads a translation whose text looks like a marker as missing. It is
  a generic function on the translation-source protocol: an app's own source, such as a
  DB-backed one, should implement it beside its `translate` method.
- **hyperion/i18n: a current translation source for the request** (#491).
  `*translation-source*` is bound per request by the middleware `wrap-translation-source`,
  given a source or a function of the request's environment that returns one, and locally by
  `with-translation-source`. It is registered with `aion/dynamic`, so a thread the request
  spawns through `aion/dynamic:inheriting` sees it. `translate-current` and
  `translate-plural-current` call `translate` and `translate-plural` with it, and signal
  `no-translation-source` when none is bound. A streaming response body sees the same source
  as its handler. A component that defined its own source variable can use this one instead.
- **hyperion/calendar: a month grid and a strip of days, as Spinneret components** (#489).
  A new opt-in system. `month-grid` renders a Monday-first month with previous and next links,
  and `days-strip` renders N consecutive days from any date. The caller supplies what a day
  shows (`:render-day`) and where days and months link (`:href-for-day`, `:href-for-month`).
  Dates are `"YYYY-MM-DD"` and months `"YYYY-MM"` strings, with `add-days`, `weekday`,
  `month-step`, `month-dates`, `today` (optionally in a zone, through `aion/tz`) and the
  validators beside them. Month and weekday names are translated under the `calendar` section
  by the request's `hyperion/i18n:*translation-source*`, falling back to English. Its
  stylesheet is served by `hyperion/assets` as `:calendar`: link `(hyperion/assets:url
  :calendar)`. `hyperion/assets` gains `first-party-p` to tell the tree's own files from the
  vendored ones. See `hyperion/docs/calendar.md`.
- **aion/pool: submitting a job takes no pool mutex, so several server-uv loops no longer wait
  on each other** (#466). `try-submit` reserves a place with an atomic count and puts the job on
  `sb-concurrency`'s lock-free queue, and each worker sleeps on its own semaphore, which a
  submitter signals only when it claims that worker from the stack of idle ones. The pool's
  behaviour is unchanged: the queue limit and the 503 when it is full, the worker count,
  draining on `stop-pool`, and reporting a job that signals. On macOS in `hyperion/bench` with
  4 loops and 8 workers, `/tile` went from about 96,800 to about 110,700 requests/s, against
  about 111,100 with handlers run on the loops. See "An app may have to act" for `pool-queued`.
- **Desktop bundles carry libgit2 when the app loads `aion/libgit`, with its source and its
  licence** (#429). `scripts/build-desktop-app.lisp` wakes and carries libgit2 as it does libuv and
  mbedTLS. libgit2 is GPLv2 with a linking exception, so the bundle also carries the pinned
  source tarball under `SOURCES/` and `COPYING` under `LICENSES/`, as ADR-0013's amendment of
  2026-10-01 records. The bundler refuses to build a bundle whose tarball's sha256 is not the
  one `libgit2.pin` records. `scripts/check-bundle-sources.lisp BUNDLE` checks a built bundle, and
  the three verify-bundle scripts run it. In a bundle, `aion/libgit` no longer looks in the source
  tree's `vendor/libgit2`, as `aion/uv` and `aion/tls` already did not (#472). The bundler now
  also finds licence files named `COPYING*`, and those beside the library in `lib/`.

- **praxeon/mcp: a long-running tool call can finish after the turn that started it, through the
  MCP Tasks extension** (#532). `make-connection :tasks t` declares the extension, so a server
  on the current revision may answer `tools/call` with a task. The task is saved in the
  client's task store (`make-client :task-store`; `make-memory-task-store` is the default and
  keeps tasks in the process), the model is told the work has started, and a `:task-started`
  event is emitted. The app's job runner calls `poll-tasks` on a schedule. It polls each due
  task once, with a token fetched for the task's principal at that moment, and returns a
  `finished-task` for each one that ended, with outcome `:ok`, `:error`, `:cancelled`,
  `:expired` or `:unknown`; `task-report` gives text for a later turn. `cancel-task` sends
  `tasks/cancel`; it and `poll-task` refuse a task of another connection before sending
  anything. An app with its own store implements `save-task`, `update-task`, `finish-task`,
  `announce-task`, `due-tasks` and `remove-task`; `update-task` and `finish-task` change only a
  record that is still there and not finished, so a poller that read a task before another
  finished it cannot write it back, and `announce-task` marks a finished record once, so
  `:task-finished` is sent once. A finished task stays in the store until `poll-tasks` returns
  it, so when an observer fails on any event, no finished task is lost: the next `poll-tasks`
  returns each one, and sends `:task-finished` for any it was not yet sent for. A task is kept
  as JSON with `task-to-json` and `task-from-json`. A task without the fields the specification
  requires fails the call with outcome `:unknown`. The time-to-live counts from when the client
  received the task, and a task is polled once more at its deadline before it expires. A task
  whose `ttlMs` is null expires after the connection's `:task-lifetime`, one day by default.
  After a failed poll the wait doubles with each failure in a row, from the poll interval up to
  the connection's `:task-backoff-cap`, five minutes by default, and `:sign-in-required` is
  emitted once for each run of sign-in failures, not on every poll. A failed poll is recorded
  even when an observer of `:sign-in-required` signals or an app's handler of
  `authorization-required` exits. `make-connection` refuses a `:task-lifetime` or
  `:task-backoff-cap` that is not a positive integer, and `make-client` refuses a task store
  that lacks a method for one of the six functions. The client declares no sampling or roots,
  and declares elicitation only when the app passes `:elicitation` to `make-connection` (#563),
  so a server must not ask a task for any other input; a task that does is cancelled, with a
  `:task-input-refused` event naming the request methods. See `praxeon/docs/mcp.md`,
  "Long-running calls".

### Fixed

- **hermes: six corrections to the Telegram backend** (#788, follow-ups to #778).
  - A refusal whose `description` is not a string is reported with its class and the response
    body as detail. Before, it signalled a `type-error`.
  - `make-telegram-message` refuses an `@username` that ends with an underscore, as Telegram
    does.
  - `telegram-can-post` signals `telegram-chat-migrated` for a group that became a supergroup,
    as before; that is now documented and tested.
  - An error raised during the request whose report cannot be printed still arrives as a
    `delivery-failure`, whose detail names the error's type.
  - A serious condition that is not an error, such as a timeout, is signalled again unchanged
    after the request is unwound. Before, it propagated with the request, and so the token in
    its URL, in live frames, which hyperion's dev server prints for any serious condition.
  - The dev transport edits and deletes a result from the real Telegram backend instead of
    refusing it with `unsupported-message`.

- **hermes/blob: on the S3 store, `read-blob-range` with `:length 0` signals `blob-not-found`
  for a missing key** (#796), as the filesystem store does and as the docstring says. It returned
  an empty vector without asking the store; it now makes one HEAD request.

- **hermes/blob: on the S3 store, `read-blob-range` reads only the range when the store ignores
  `Range`** (#796). A store, or a proxy in front of it, that answers 200 with the whole object
  had its whole body read into memory and then cut down. The body is now read as a stream: the
  method skips to `:start`, reads `:length` bytes and closes the connection.

- **hermes/blob: `start-multipart-upload` refuses a content type that is empty or contains a
  control character** (#796), with `blob-upload-refused` reason `:bad-content-type`, before
  sending anything. This is the same check `upload-url` makes; a CR or LF in it would end up in a
  request header.

- **hermes/blob: on the S3 store, `blob-metadata` returns the checksum `put-blob` computed**
  (#810). `put-blob` now stores the SHA-256 as the object's `x-amz-meta-sha256`, which is where
  `blob-meta-checksum` is read from. Before, it was sent only as the payload hash, so
  `blob-metadata` returned NIL for the checksum of every blob on S3; `put-blob`'s own return value
  was always right. Objects stored before this change, and objects a client uploaded directly
  through `upload-url` or through a multipart upload started with `start-multipart-upload`, still
  report NIL, because their bytes never pass through hermes.

- **hermes/blob: on the S3 store, `list-multipart-parts` returns usable ETags from MinIO**. MinIO
  writes the quotes around an ETag in its XML as the numeric reference `&#34;`, and the S3
  store's XML reader decoded only the five named entities, so each ETag came back as
  `&#34;...&#34;`. Completing an upload with those ETags fails with 400, so resuming a multipart
  upload on MinIO did not work (#813). The reader now decodes numeric references (`&#34;`,
  `&#x22;`) in one pass, so an escaped reference such as `&amp;#34;` is decoded once, to
  `&#34;`. Only exact references are decoded: ASCII digits only, a lowercase `x` for hex, no
  sign, space or trailing characters, and not 0 or a surrogate code point, which XML does not
  allow. Anything else is kept as written, so a
  key that holds such text is listed as it is.

- **praxeon: `praxeon/conditions:value-shape` is exported** (follow-up to #760). It describes a
  value by its kind and length ("a string of 12 characters") without printing it, as the
  `unknown-tool-choice` detail does; it was the internal `%value-shape`.

- **hyperion/http: `form-param`, `form-params`, `query-param`, `query-params` and `form-alist`
  decode field names as well as values, with `+` as a space** (#715). A browser
  percent-encodes a field name when it submits a form, so a field named `en:who` arrives as
  `en%3Awho`, `items[0]` as `items%5B0%5D` and `a b` as `a+b`. Before this, those names were
  not decoded, so `(form-param body "en:who")` returned NIL and a handler read the field as
  not sent, with no error. An app that renamed its fields to avoid these characters can keep
  or undo that workaround. A name or value that does not decode, such as the truncated escape
  in `x%4=1`, is kept as it arrived instead of signalling `quri:url-decoding-error`, which a
  value already did before this change: a client could post such a body to make the CSRF
  check signal instead of answering 403. New `hyperion/http:form-urlencode` builds a
  urlencoded body from `(name . value)` pairs the way a browser does, for tests.

- **aion/schedule: `run-now` and `run-job` no longer start a second run when the run they
  waited for finished before they woke** (#723). A call that found a run of the same job still
  starting on this instance waited for it, as documented. If that run then started and
  finished before the waiting call took the scheduler's lock again, the call found the job
  free and started a second run. Now `run-now` returns `(values run-id :already-running)` with
  the id of the run it waited for, which may already have finished, and `run-job` returns
  NIL, as it does whenever another run holds the job. Either one tries to start a run itself
  only when the run it waited for did not start.

- **aion, elenchon, hyperion and mnemosyne: `scripts/setup.sh` and `scripts/setup.ps1` check
  that Coalton is at the commit `coalton.pin` names, and no longer clone it** (#751). Like
  praxeon's before #733, they ran `git clone --depth 1` on Coalton's latest commit when
  `~/common-lisp/coalton` was missing, and accepted any commit when it was present. All five
  frameworks' setup scripts now run the new `scripts/coalton-pin.sh` or
  `scripts/coalton-pin.ps1` at the monorepo root. It exits 0 when the checkout at `COALTON_DIR`
  (default `~/common-lisp/coalton`) is at the pinned commit, and otherwise names the checkout's
  commit (or "no commit") and the pinned one, says to run the root `scripts/setup.sh` or
  `scripts/setup.ps1`, and exits 1. It warns when the checkout's `origin` differs from the pin's
  `repo` line, as the root scripts do. The root setup scripts are now the only ones that clone
  Coalton.

- **praxeon: `praxeon/scripts/setup.sh` and `setup.ps1` check that Coalton is at the commit
  `coalton.pin` names, and no longer clone it** (#733). They ran `git clone --depth 1` on
  Coalton's latest commit when `~/common-lisp/coalton` was missing, and accepted any commit
  when it was present, so a machine set up through them could build against a Coalton the tree
  is not tested with. They now stop with an error naming the checkout's commit and the pinned
  one, and say to run the monorepo's `scripts/setup.sh` or `scripts/setup.ps1`, which clones
  Coalton and checks out the pinned commit. Both honour `COALTON_DIR`, as the root scripts do.

- **hyperion/dev: `watch` refuses to watch more files than `*watch-file-limit*` allows,
  100000 by default, and names the root that passed it** (#730). The watcher snapshots every
  file under its roots on every poll, and nothing limited that snapshot, so a root that was a
  very large tree, such as a home or temporary directory, filled the heap and ended in heap
  exhaustion with a backtrace that did not mention the watched path. `watch` now takes
  `:file-limit` (default `hyperion/dev:*watch-file-limit*`, `nil` for no limit), and past it
  signals `hyperion/dev:watch-too-large` (readers `watch-too-large-root`,
  `watch-too-large-count`, `watch-too-large-limit`) before the builder runs, so nothing is
  started, and a dev server that `watch` started earlier keeps running. It refuses rather than watching part of the tree, because a partial watch leaves some
  edits without a reload and gives no sign of which. If the roots grow past the limit while
  watching, the previous snapshot is kept and the condition is shown as the reload error, in the
  browser overlay, until they are back within it; an error it replaced, such as a Lisp file that
  still fails to compile, is shown again then. `hyperion/dev:serve` callers set the limit by
  binding `*watch-file-limit*`.

- **hyperion/session-db: `ensure-schema` and `make-db-store … :ensure t` create the table the
  store's `:table` names** (#638). They created `hyperion_sessions` whatever `:table` said, so a
  store made with another table name and `:ensure t` failed its first operation on a table that
  did not exist. `db-store-ddl` now builds the DDL under the store's table name, as
  `hyperion/auth-db` does since #378, and refuses a name that is not letters, digits and
  underscores. An app that made `hyperion_sessions` by hand because of this, while its store
  named another table, can drop it.

- **aion/schedule: `stop` starts no lease renewal when less than 50 ms of its timeout is left**
  (#728). A timed wait can return a little before its timeout, by a spurious wakeup or a coarse
  timer such as Windows' default one. `stop` then started a renewal with a few milliseconds left,
  which it could not wait for. That renewal kept using the store after `stop` returned, and the
  next `stop` had to wait for it.

- **praxeon/observe: on a store with transactions, a window's observations, its promotions and
  its progress are written in one transaction** (#529). When the progress write failed after
  the observations were written, the store held observations its progress did not cover, and
  after a stop, a restart or with a new observer the window was distilled again, so a model that
  worded its answer differently left a second copy. Now the failed progress write rolls the
  window's observations back, the attempt is retried, and the window is written once. Both
  stores in this tree have transactions; a store without them, such as one an app wrote itself,
  keeps the earlier behaviour, which the observe.lisp header describes. The window's embeddings
  are computed before the transaction takes the store's lock.
  - **A promotion that fails now loses the window's thread observations with it.** The
    transaction covers promotion, so when the app's `:promote` or `:promote-accept`, or the
    store's write of the promoted fact, signals, the window's thread observations are rolled
    back too, and the attempt is retried. Before, they stayed written and the next attempt only
    finished the promotion. A promotion callback that keeps signalling therefore leaves the
    window skipped with nothing in the thread, where before its thread observations were kept.

- **`aion/platform:shipped-image-p` is false inside `bin/cons`** (#703). `bin/cons` is one dumped
  file, so its runtime and core are the same file, and an app run under it (`cons test-app`, for
  example) read it as a shipped Linux build on every OS: `shipped-image-p` returned true and
  `shipped-image-directory` (and `hyperion/desktop:install-directory`) returned the tree's `bin/`.
  `bootstrap.lisp` now dumps `bin/cons` with `:development-runner t`, which puts
  `:ouranos-development-runner` on `*features*`, and `shipped-image-p` returns false while that
  feature is present. The new `aion/platform:development-runner-p` reports it, and
  `shipped-image-p` takes `:development-runner` to override it. `scripts/dump-image.lisp`'s
  `dump-executable` and `dump-core` take `:development-runner` and remove the feature for every
  other dump, so an app dumped from inside `bin/cons` still reads as shipped. Rebuild `bin/cons`
  (`sbcl --dynamic-space-size 4096 --script bootstrap.lisp`) to get the mark. An app that looks
  for its assets only in the source tree, because `shipped-image-p` was wrong under `cons`, can
  use `shipped-image-p` again.

- **`aion/http-client`: verified https requests work when the default libssl is OpenSSL 4**
  (#706). cl+ssl reads a certificate's names with `ASN1_STRING_data`, which OpenSSL 4 removed,
  so on a host whose default libcrypto is OpenSSL 4 every https request that verifies the
  server's host name failed: dexador's own requests, which call cl+ssl with `:verify` and
  `:hostname`, and those made with `:connect-address`. `aion/http-client` now points
  `cl+ssl::asn1-string-data` at `ASN1_STRING_get0_data`, which OpenSSL 1.1, 3 and 4 all have,
  in `aion/src/http-client/openssl.lisp`. The fix applies only in an image that loads
  `aion/http-client`; an image that uses dexador or cl+ssl without it is still affected. The
  patch is removed once the pinned cl+ssl contains cl-plus-ssl pull request 202, and this file
  will say so then.

- **hyperion/csrf: a protected form no longer shows a stray "T" after its hidden `_csrf`
  field** (#663). `token-field` returned `T`, and the `:form` deftag calls it inside the
  form's Spinneret body, which prints a body form's value, so every `post`, `put`, `patch`,
  `delete` or `hx-post` form rendered with a token read `<input type=hidden name=_csrf …>T`,
  visible on the page and read aloud by screen readers. `token-field` now returns no values.
  An app that calls `token-field` itself and read its return value, `T` when a field was
  written, now gets no value.

- **scripts/setup.ps1: moving to a new Coalton pin fetches it, instead of stopping** (#697).
  When the Coalton checkout did not contain the pinned commit yet, which is the usual state
  after `coalton.pin` changes, `git rev-parse` reported an unknown revision and Windows
  PowerShell treated that message as a terminating error, so `setup.ps1` exited 1 before it
  fetched. `setup.ps1 -Check` stopped the same way instead of reporting the pin as missing.
  Both now resolve the commit through `Resolve-GitCommit`, which returns nothing for a
  revision git cannot resolve. `scripts/setup.sh` was not affected.

- **praxeon/event: the list of events at the top of `praxeon/src/event.lisp` names every event
  praxeon emits** (#339). It left out eleven: `:usage`, `:tool-held`, `:tool-decided`,
  `:result-stored`, `:results-cleared`, `:context-trimmed`, `:context-overflow`, `:delegate`,
  `:workflow-start`, `:workflow-step` and `:workflow-end`. Each is now listed with its fields. A
  test fails when a praxeon source file emits an event type the list does not name, or the list
  names one nothing emits. No event changed.

- **praxeon/structured: `schema-recursion` no longer reads examples as references, and
  percent-decodes a reference's fragment** (#686). It found a `$ref` or `$anchor` anywhere in
  a schema, including inside `examples`, `default`, `const` and `enum`, whose values are data.
  A schema such as `{"type":"object","examples":[{"$ref":"#"}]}` was reported as recursive, so
  `generate-structured` on `meta` signalled `unsendable-schema` for a schema it could send. It
  now looks only in the parts of a schema that hold schemas. It also read a fragment such as
  `#/$defs/%6Eode` literally, so a schema that refers to itself that way was not reported as
  recursive: on `meta` it was sent, refused with HTTP 400, and signalled as
  `deliberation-failure` instead of `unsendable-schema`. The fragment is now percent-decoded
  before it is read as a JSON pointer or an anchor name.

- **mnemosyne/conn: `connection-open-p` reads a connection with no readable driver handle as
  closed** (#675). It used to read a connection as open when `dbi:connection-handle` returned
  NIL or signalled, so `hyperion`'s database session store, which calls it after a `db-error`,
  would have kept such a connection and used it again instead of replacing it. This case is not
  known to occur with today's drivers. A SQLite connection still reads as open, and a Postgres
  connection still reads its client-side state.

- **praxeon/conditions: `praxeon-error` keeps its `:detail` and prints it** (#505). Code
  throughout praxeon signals `praxeon-error` with `:detail` saying what went wrong, such as
  `make-observer`'s refusal of a bad `:step` or a `supersede` of an observation already
  superseded, but the condition had no slot, so the detail was dropped and the report read only
  "Condition PRAXEON-ERROR was signalled". It now has a `detail` slot, read with the new export
  `praxeon-error-detail`, and its report prints the type and the detail, for example
  `praxeon-error: :step must be a positive integer, not 0`. `praxeon/observe`'s
  `window-not-distilled` and `closing-not-saved` print their detail the same way.
  `deliberation-failure` keeps its own report, and `deliberation-failure-detail` reads the same
  slot. Every subclass is still a `praxeon-error`, so existing handlers catch the same conditions.

- **aion/libgit: `set-remote` also sets the remote's push URL, so a push goes to the new URL**
  (#641). For a remote that already existed, `set-remote` changed only `remote.<name>.url`.
  When the repository's git configuration also had `remote.<name>.pushurl`, `push-branch`
  went on sending commits, and the credential it was given, to that push URL. `set-remote` now
  sets `remote.<name>.pushurl` to the same URL, in the repository's own configuration, for new
  and existing remotes. A push URL set in the user's or the system's git configuration is
  overridden by it. Because the remote now has a push URL, a `url.<base>.pushInsteadOf` rule
  no longer rewrites its pushes; `url.<base>.insteadOf` still does. The two keys are written
  together under libgit2's configuration lock, so either both change or neither does. libgit2
  refuses to set `remote.<name>.url` or `remote.<name>.pushurl` when the repository's
  configuration has more than one value for it, or takes it from a file named by
  `include.path` or `includeIf`; `set-remote` then signals `git-error` and the configuration
  file is unchanged.

- **aion/oauth: the default `call-with-refresh-lock` no longer keeps a mutex for every
  principal and connection for the life of the process** (#542). The method on `store`, which
  `refresh`, `finish-sign-in` and `disconnect` use unless a store overrides it, added an entry
  to a process-wide table the first time a principal and connection took the lock, and never
  removed it. It now counts the calls holding or waiting for each entry's mutex and removes the
  entry when none is left. Two calls for one principal and connection still never run at once.
  A store that overrides `call-with-refresh-lock` is not affected.

- **praxeon/memory-db: `recall-similar` on Postgres returns as many observations as `:limit`
  asks for, when that many match, also when the HNSW index serves the query** (#482).
  pgvector's HNSW scan took the nearest `hnsw.ef_search` rows of the whole table (40 by
  default) and only then applied the subject, scope and supersession filter. Measured on
  pgvector 0.8.6: one subject with 20,050 current observations and `:limit 100` got 40; with the
  index used for a subject holding 50 of 20,051 rows, or 50 current observations beside 20,000
  superseded ones, it got none. `recall-similar` now runs its query with
  `hnsw.iterative_scan` set to `strict_order`, which needs pgvector 0.8 or later; on an older
  pgvector the query runs as before. An iterative scan still stops at `hnsw.max_scan_tuples` or
  its memory limit, so when the query returns fewer than `:limit` rows it runs again with
  `enable_indexscan` off and `enable_seqscan` and `enable_bitmapscan` on, which ranks every one
  of the subject's rows in scope. A subject with fewer than `:limit` observations in scope makes
  that second query on every similarity recall. Each setting is made for the store's own
  transaction, or for a savepoint inside the app's `conn:with-transaction`, and put back as it
  was afterwards, so the app's later queries in its transaction run with its own settings.
  `ensure-schema` also creates an index on `subject`, `<table>_subject_idx`, which that second
  query reads.

- **praxeon/observe: `observer-stuck-p` measures from the start of the current window attempt,
  not of the whole run** (#632). It compared the time with the start of the run, so a run that
  worked through several windows, or waited between retries, was reported stuck once its total
  time passed `:window-timeout`, even while the current model call was new, and `observe-turn`
  logged "memory observer stuck". Now each attempt, including a retry of a skipped window,
  records its start, and `observer-stuck-p` and that log line's `:seconds` measure from it.
  Between attempts, during the pause before a retry or the work between windows, the observer
  is not stuck.

- **praxeon/mcp: a task that asked for input is cancelled even when the cancel needs a
  sign-in** (#587). When `tasks/cancel` needed a sign-in and an observer of `:sign-in-required`
  signalled, or an app's handler of `authorization-required` exited, the task was never marked
  cancelled. Each later `poll-tasks` sent `tasks/cancel` again, told the app to sign in again,
  and stopped before the tasks due after it. The task is now marked `:cancelled` on the way out,
  and the next `poll-tasks` returns it with one `:task-finished`; `:task-input-refused` is not
  sent in that case. A store error while marking it is logged, and the app gets the condition
  that left the poll.
- **`build-desktop-app.lisp --update-source` refuses a URL with no host** (#588). The URL had
  only to start with `https://`, so `--update-source github=https://` was accepted, and it
  satisfied `--release`'s need for a source, giving a build that can never reach one. Now a URL
  is refused, and the build stops with exit code 2 naming the reason, when:
  - its host is empty, is longer than 253 characters, or is not a DNS name made of labels of 1
    to 63 letters, digits and dashes separated by single dots. A dotted IPv4 address is
    accepted; an IP address in brackets, such as `[::1]`, is not;
  - its port, when given, is not a number from 1 to 65535;
  - it has a query (`?`) or a fragment (`#`), which would have ended up in front of the `/` the
    build appends;
  - it contains a space, a control character or DEL anywhere. A percent-encoding such as `%00`
    is accepted and not decoded;
  - it carries credentials before an `@`, which would be built into the image. Such a URL is not
    printed in the refusal, only its kind, because the message goes to CI logs.
- **hyperion/update: an update can be applied when `*update-source*` is a list of sources**
  (#408). `fetch-manifest` already tried a list in order, but `fetch-artifact` had no method for
  one. So an app that set `*update-source*` to a list could report an update as available, and
  then fail with `NO-APPLICABLE-METHOD-ERROR` when the user applied it. `fetch-artifact` now
  tries the list in order, and passes over a source that cannot be reached, as `fetch-manifest`
  does.
- **klio: a fenced block's language could close the class attribute and add attributes to the
  page; now an invalid language renders with no class.** klio renders fenced blocks as
  `<pre class="LANG">`, and the info string after the opening fence reached that attribute with
  `<` and `>` escaped but not a double quote. `highlight-code-blocks` now keeps
  the class only when the language is made of letters, digits and `+ - _ . #`; any other block is
  written as plain `<pre><code>`, and is not highlighted. A block with a valid language, such as
  `lisp`, `python` or `c++`, is unchanged.
- **praxeon: after a means fails in the middle of a step, the agent's next turn starts**
  (#546). A step's calls are no longer left without results when a failure leaves the turn:
  `run-turn` writes a result for every call of the step before the failure goes on, and
  `act`'s restarts are still available to a handler. A call that finished keeps its result.
  The call whose means failed gets "the tool may have run; its outcome is unknown", outcome
  `:unknown`; a call whose `:tool-call` event failed before its means was applied gets "Not
  run: the turn ended before this call was run.", outcome `:not-run` (#553). A call to a
  means that is not registered, or that the permit does not allow, gets "Not run: no such
  tool is available." The calls after it, and a call the app's `:on-hold` function signalled
  while deciding, get "Not run: the turn ended before this call was run." Each gets a
  `:tool-result` event. This happens whenever the failure leaves the step, including when
  the app handles it with a `handler-case` around `run-turn`, and when the observer or the
  result store is what failed: the results are added to the history before their events are
  emitted and before they are stored. A call whose result was already known, or whose
  not-run text was already decided, keeps that text, or its stand-in when the store already
  offloaded it. Each call gets one `:tool-call` and one `:tool-result` event, even when the
  observer failed on one of them. A result is now kept in the agent's result store before
  its `:tool-result` event is emitted, so for an agent with a result store, `:result-stored`
  comes before `:tool-result` for the same call, where it used to come after. This holds for
  the results the cleanup writes too, and a result whose store was never tried, because an
  event before it failed, is stored by the cleanup. Before this, the next turn sent tool
  calls without results, which the providers refuse, and with #545 it signalled
  `held-turn-required` with no held turn to pass. A failure in the same step as a call held
  under `:on-hold :hold` wins: no held turn is returned, and the held call is written as not
  run with a `:tool-decided` event whose decision is `:turn-failed`. An approved call that
  fails inside `continue-turn` is written as may-have-run; an approved call after it gets
  the turn-ended text and `:turn-failed`, and a declined one keeps the declined text. **An
  app that edited `agent-history` after such a failure to let the next turn start, for
  example by removing the model's last message, should stop:** that edit now removes the
  step's results instead, and the next turn fails again.
- **praxeon: a context item's text cannot end the context block or pose as another item**
  (#527). `prompt:render-items` wrote each item's content verbatim between `<context>` and
  `</context>`, so a text containing `</context>` ended the block early, and what followed read
  as the user's own words. A line starting with `[note]` or `[system]` read as another item.
  This mattered once part 4 let an MCP server's resource become an item. `render-items` now
  writes the block's tags inside an item's text, in any letter case, with `&lt;`, taking their
  names from `*context-open*` and `*context-close*` when the block is rendered, so a tag an app
  sets is covered too; a tag not of the form `<name>` or `</name>` gets only the indentation.
  Every later line of the text is indented by two spaces, after LF, CR, CRLF, VT, FF, NEL, LS or
  PS, each written as one LF. A multi-line item's rendering changes for every app: its
  continuation lines are indented.

- **klio: `watch-site` no longer publishes a file read while it is being written.** A file saved
  in place is empty from the moment it is opened until the new text is written, and a poll that
  landed in that moment reloaded the empty file: the page was served with no title until the
  next poll. `watch-site` now reloads a change once two polls in a row have seen it, so an edit
  is served one `:interval` later than before. A write held open for longer than an interval can
  still be read while empty. (#534)
- **aion/http-client: `fetch-public` returns the body of a 4xx or 5xx response, and an empty
  response no longer fails** (#527). Over the pinned connection `fetch-public` uses, the
  connection was closed before the body of a non-2xx response was read. The body came back
  empty, and a response with no body at all, such as a 404, signalled
  `sb-int:closed-stream-error` instead of returning. An app that read an error's details from
  `fetch-public`'s response, or treated a closed-stream error from it as "not found", now gets
  the response itself. Windows is unaffected, because `fetch-public` does not pin a connection
  there.
- **aion/windows/com: a process that has started the STA apartment exits without waiting a
  minute.** The apartment thread waits in a foreign call SBCL cannot interrupt, so `sb-ext:exit`
  waited out the whole `sb-ext:*exit-timeout*` (60 s by default) for it, and a desktop app that
  had used COM looked hung for a minute after its window closed. `aion/windows/com` now puts
  `%stop-apartment-at-exit` on `sb-ext:*exit-hooks*`, which stops the apartment, waiting at most
  `*exit-stop-timeout*` (10 s) for its thread. An app that registered its own exit hook calling
  `stop-apartment` as a workaround can remove it; leaving it does no harm, because stopping a
  stopped apartment does nothing. (#484)
- **hyperion/server-uv: `:loops :auto` in a CPU-limited container on Linux follows the
  container's limit, not the host's cores** (#475). The count is now the smallest of the online
  CPUs, the CPUs in the process's affinity mask (`sched_getaffinity`), and the cgroup v2
  `cpu.max` quota over its period, rounded up, taking the tightest quota on the process's cgroup
  and its ancestors. A 1-vCPU container now runs one loop where it ran four. An app that set
  `HYPERION_LOOPS=1` to work around this no longer needs to. The "server-uv: listening" log
  line carries `:loops-from`: `sysconf`, `affinity` or `cgroup` for `:auto`, and otherwise
  `start-argument`, `setting`, `inline` or `platform`. macOS and Windows are unchanged.
- **hyperion/dev: a restart waits for its port, and no longer blames a sibling application.**
  When `reload!` restarted the server, the new server's port check ran 0.1 s after the old one
  was stopped, and failed if the old listener had not let go yet, with a message that sent the
  developer looking for another application on the port. The restart now retries the builder
  while it signals `hyperion/server:port-in-use`, for up to `hyperion/dev::*restart-port-wait*`
  (5 s). If the port still answers after that, it signals
  `hyperion/dev::restart-port-still-answering`, whose message says that this dev server's
  previous server, or code the reload ran, still holds the port, and gives any error from
  stopping the old server, which used to be discarded. (#492)
- **Desktop bundles carry mbedTLS when the app loads `aion/tls`** (#481). Before,
  `scripts/build-desktop-app.lisp` woke and carried only libuv, so a desktop app that used
  `aion/tls` shipped without the library and signalled `aion/tls:mbedtls-not-found` on the
  user's machine. The bundler now loads it from `vendor/mbedtls/lib/`, copies it beside the
  executable with its LICENSE under `LICENSES/`, and closes it before the dump. If the library
  is not built, the build stops and names `scripts/build-mbedtls.lisp`. The list of libraries
  the bundler carries is now `scripts/lazy-natives.lisp`.
- **hyperion-view on Windows opens the window centred in the work area of its monitor, and
  shrinks it to fit when it is larger.** It used to set only the size, so the window opened at
  Windows' cascade point, and on a 2560x1600 display at 150% scaling a 1280x860 window (1346
  physical pixels high with its frame, in a 1528-pixel work area) often opened partly below the
  work area. The size an app passes to `run-app` is unchanged; only a window that would not fit
  is made smaller. `hyperion-view --placement` prints the arithmetic for given numbers, and
  `hyperion-view --report-placement WIDTH HEIGHT` creates the window, places it, prints the
  rectangle Windows reports and exits; start it hidden. Rebuild
  `hyperion-view` (`hyperion/hyperion-view/build.ps1`) to get it. macOS already centred the
  window; Linux leaves placement to the window manager. (#485)
- **aion/pool: two jobs that call `stop-pool` at the same time both return, and a later
  `stop-pool` from outside the pool waits for every worker** (#520). With two or more workers,
  two jobs calling `stop-pool` at once used to wait for each other's worker and never returned;
  a call from a job now skips any worker whose own job is inside `stop-pool`. After a job had
  called `stop-pool`, a later call from outside returned at once, while that job's worker was
  still running the jobs queued behind it; it now joins every worker, so when it returns no job
  is running and none will start. `stop-pool`'s docstring now says that the calling job's
  worker runs the jobs queued behind it before it exits.
- **hyperion/markdown: with `:allow-html nil`, inline code, indented code, colourised fenced
  blocks and entities are escaped once** (#559). `render` escaped the whole source before 3bmd
  parsed it, and 3bmd escaped code again, so `(< a b)` in inline code reached the reader as
  `(&lt; a b)`, and the entity `&amp;` showed as the text `&amp;`. The safe mode now stands
  placeholder characters in for `<` and `>` while 3bmd parses, so raw HTML, HTML blocks and
  autolinks are still shown as text, and turns them back into `<` and `>` before printing, where
  3bmd escapes them once. `&` is left as written, so an entity renders as its character.
  `:allow-html t` is unchanged. In the safe mode, a fenced block's language that is not made of
  letters, digits and `+ - _ . #` is dropped, because some 3bmd renderers write it into a class
  attribute without escaping a double quote. The safe mode also turns off 3bmd's
  `*smart-quotes*`, `*generate-header-ids*` and `*render-code-spans*` for the call, because each
  makes 3bmd print text without escaping it; `:allow-html t` keeps an app's values. A fenced
  block under the `:pygments` or `:chroma` renderer is left for that program to escape. Every
  klio page changes the same way. An app that unescaped `render`'s output to work around this
  should stop.
- **praxeon/mcp: `get-prompt` and `read-resource` refuse malformed content with
  `request-failed`** (#569). `get-prompt` accepted a list of content blocks as a message's
  content, which every schema revision defines as one block, and accepted any object as a
  block, so `{"type":"text","text":42}` gave a message whose text was the integer 42. A message's
  content must now be one block of a known type (`text`, `image`, `audio`, `resource_link` or
  `resource`) with that type's required fields as strings; a session on protocol version
  2025-03-26, whose schema has no `resource_link`, refuses that type. `read-resource`, and so
  `add-resource`, accepted a content with neither a `text` nor a `blob`, which the schema
  requires, and showed it as `[no content]`; the reply now fails, and an earlier copy added with
  `add-resource` is kept.
- **hyperion/markdown: with `:allow-html nil`, `>` at the start of a line renders a block
  quote** (#574). Since #559 the safe mode hid every `>` from 3bmd, so `> quoted` rendered as a
  paragraph beginning with `&gt;`. A `>` with nothing before it on its line but spaces, tabs,
  other quote markers and list markers is now left for 3bmd to read, and renders a block quote
  where `:allow-html t` does: at the start of a line, in a nested quote, and inside a list item
  (`- > quoted`, `1. > quoted`, a continuation line `    > quoted`, and `> - > quoted`) (#584).
  3bmd does not treat an indented `>` as a quote in either mode, so `   > x` is still a
  paragraph. Raw HTML inside a quote is still shown as text,
  and a `>` in code is still escaped once. Every klio page changes the same way.

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
