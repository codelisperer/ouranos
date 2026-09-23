# How the frameworks log

The house pattern for observability across the tree. The facade is **`aion/log`** — a thin
neutral surface over log4cl — and every framework that logs uses it, so an app configures
logging **once** and sees its own events and the frameworks' in one stream.

## The rule that makes logs useful: correlate, don't just record

A line that says `db query rows=3 ms=41` is nearly worthless on its own. The same line with
`request_id=ab12cd34` is evidence: it joins the SQL to the HTTP request that caused it, the
LLM call that request made, and the error it ended in.

So the pattern is **one id, bound once, at the outermost seam**:

```lisp
(log:with-context (:request-id id)
  ...)          ; every event logged anywhere inside carries request_id
```

`hyperion/logging:wrap` does this for HTTP — and `hyperion/server:start` applies it by
default, so an app gets correlation without writing any code. It **adopts an upstream
`X-Request-Id`** when the edge/proxy already minted one (joining their trace instead of
starting a rival one) and echoes the id back on the response, so a user reporting a problem
can quote something you can search for.

Anything that owns a unit of work should do the same: a background job binds `:job-id`, an
agent turn binds `:conversation-id`.

## Levels — what belongs where

The test is: **would you want this line in production, forever?**

| Level | For | Examples in the tree |
|---|---|---|
| `:trace` | Machine traffic on a timer — available on demand, invisible by default (see **Quiet paths** below). | the dev hot-reload poller; health checks |
| `:info` | One line per meaningful unit of work. Readable at a glance in prod. | one line per HTTP request (method, path, status, ms); a migration applied |
| `:debug` | The detail you turn on to diagnose something. Off by default. | each SQL statement + row count + ms; LLM request/response metadata; connect/disconnect |
| `:warn` | Recoverable, but somebody should know. | an LLM provider call failed (the caller may retry or fail over); a rollback target missing from the known set |
| `:error` | Use `log:exception` — it attaches the condition report **and a backtrace**. | an unhandled error in a request |

Two habits that keep this honest: don't log at `:info` inside a loop, and don't log the same
event twice at two layers — the outer seam usually owns it.

## Structured fields, not string interpolation

```lisp
(log:info "request" :method method :path path :status status :ms elapsed)   ; yes
(log:info (format nil "~A ~A -> ~A" method path status))                    ; no
```

Fields survive the trip into a log aggregator as *queryable data* (`status=500`,
`ms>1000`); an interpolated sentence has to be re-parsed with a regex to answer the same
question. The message stays a short constant so events of one kind group together.

The **category is automatic** — `aion/log` derives it from the call-site package, so
`hyperion/logging`, `mnemosyne/conn`, and `praxeon/llm` are already distinguishable, and
`log:level!` can raise or lower one of them alone:

```lisp
(log:level! :debug "mnemosyne")   ; just the SQL, leave everything else at :info
```

## Quiet paths — machine traffic on a timer

Some routes are polled forever by a machine: the dev hot-reload poller, a load balancer's
health check, a metrics scrape. One line per request is right for a person navigating; for
something hitting the server every second it is noise that drowns the lines you wanted.

```lisp
(hlog:register-quiet-path "/health")                       ; exact path
(hlog:register-quiet-path (lambda (p) (prefixp "/health/" p)))   ; or a predicate
```

A quiet path's successful requests log at **`:trace`**, not `:debug`. That distinction is
load-bearing: a dev REPL habitually runs *at* `:debug`, so demoting to `:debug` would leave
the flood untouched in the session where it hurts most. `:trace` keeps the events available
to anyone who explicitly asks for everything, and invisible otherwise.

**Errors are never quieted.** A failing health check is exactly the thing you need to see,
so `log:exception` fires on a quiet path just as it does anywhere else.

Middleware registers **its own** routes — `hyperion/dev:wrap-dev` marks
`/api/reload-epoch` and `/api/dev-error` quiet when it is built. The logger has no business
knowing what the dev loop happens to serve, and that keeps the dependency pointing the
right way.

## Never log content

Log **counts, sizes, ids, and durations** — never the payload.

- `mnemosyne` logs the SQL text but **never the bind parameters**: parameters are the user
  data (emails, tokens, password hashes).
- `praxeon` logs message *counts*, token usage, model and stop reason — **never the
  prompt, the system prompt, or the completion text**. Prompts contain whatever the user
  typed and whatever context was retrieved for them.

This is not a style preference. Logs get shipped to third-party aggregators, kept far
longer than any request, and read by people who never had access to the original data.

## No IO in Coalton

Logging is IO, so it lives in the **CL shell** only. A typed Coalton core returns values;
the CL code that calls it decides what to record. No `aion/log` call belongs inside
`coalton-toplevel`.

## Configuring it (the app's job, once)

```lisp
(log:setup :env :prod :level :info)   ; :json layout to stdout — the platform captures it
(log:setup :env :dev)                 ; pretty, human-readable, for the REPL
(log:level! :debug)                   ; turn it up at runtime, no restart
```

`:prod`/`:staging` select **one-line JSON on stdout**; anything else is the pretty layout.
Frameworks never call `setup` — a library that configures logging on load steals a decision
that belongs to the application.

## Tests stay quiet

Framework suites call `(log:level! :warn)` before running, so per-request and per-query
lines don't bury CI output. A test that wants to assert on logging raises the level itself.
