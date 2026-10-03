# praxeon/mcp: agents that use MCP servers' tools

`praxeon/mcp` connects Praxeon agents to MCP (Model Context Protocol) servers over Streamable
HTTP. It is part 1 of #527:
- tools only;
- a bearer token that the app supplies through a function.

OAuth sign-in, resources and prompts, and local servers over stdio are parts 2, 4 and 5.

## Using it

```lisp
(defparameter *docs*
  (mcp:make-connection :name "docs"
                       :url "https://example.com/mcp"
                       :per-user t
                       :token-source (lambda (connection principal)
                                       (declare (ignore connection))
                                       (my-app:token-for principal "docs"))))

(defparameter *docs-client* (mcp:make-client *docs*))

;; Reads what the server offers. Gives it to no agent.
(mcp:list-tools *docs-client* :principal "user-42")

;; Gives an agent the tools the app chooses, as the means docs__search and docs__fetch.
(mcp:grant-tools agent *docs-client* :only '("search" "fetch"))

;; Each tool call uses the token of the user this turn runs for.
(actor:run-turn agent "Find the release notes" :principal "user-42")
```

- **A connection is data:**
  - `name` prefixes the tool names an agent sees, and appears in logs.
  - `url` is the server's MCP endpoint.
  - `token-source` is a function of the connection and a principal that returns a bearer token or NIL.
  - `per-user` refuses a call that has no principal, before anything is sent.
  - `timeout` bounds every request, and `call-timeout` bounds a tool call.
  - `max-body-bytes` bounds a reply.
- **The principal is chosen for each call.** `run-turn :principal` binds `actor:*principal*` for the turn, and each MCP means reads it when it is called. One agent can therefore serve several users, and each call uses the token of the user whose turn it is. A delegated sub-turn keeps the principal of the turn that delegated it.
- **A grant names its tools.** `:only` is required: a list of the server's tool names, or `:all`. No default grants every tool on a server.
- **A grant is fixed when the app makes it.** Nothing a server sends later changes which tools an agent has. A `notifications/tools/list_changed` from the server is not acted on. The app calls `grant-tools` or `revoke-tools` again.
- **Names.** A tool's means name is the connection's name, two underscores, and the tool's name. Characters outside `A-Z a-z 0-9 _ -` become `_`, and the whole is cut to 64 characters. A name that clashes with a means the agent already has, or with another tool in the same grant, signals `tool-name-conflict`, and nothing is registered.

## What the model sees, and what the app sees

| What happened | The model is told | `:outcome` on the `:tool-result` event | The app |
|---|---|---|---|
| The tool answered | the result's text | `:ok` | |
| The tool answered with `isError` | the result's text, as an error result | `:error` | `tool-error` is the cause |
| The server answered a JSON-RPC error, or refused the version | that the connection failed, with the code | `:error` or `:not-run` | `request-failed` |
| A 401 or 403, or no principal for a per-user connection | that the user must sign in, with no URL | `:not-run` | `authorization-required` is signalled, and a `:sign-in-required` event is emitted |
| A timeout, a dropped connection, a 5xx, or a reply that ends early, during `tools/call` | that the outcome is unknown, the tool may have run, and it should not be called again before checking with the user | `:unknown` | `request-failed` |

All of these let the turn go on. They are subclasses of `praxeon/conditions:tool-error-result`, which a turn reports to the model as an error result.

- **No `tools/call` is sent twice.** The client retries a request only when the reply shows the server did not process it:
  - a current-revision request that a legacy server could not read;
  - a legacy request that a current server rejected with a current-revision error;
  - the legacy 404 for an ended session.
- **No secret follows a redirect.** Requests are sent with redirects off, so a token is never forwarded to another host. A 3xx fails the request.

### Handlers stay on the thread that set them

`authorization-required` is signalled with `signal` in the thread where the tool call runs. An app's `handler-bind` around `run-turn` sees it only when the turn runs on that same thread.

When a turn continues on another thread, `aion/dynamic` carries `actor:*principal*` and the event observer to it, but not handler bindings. That happens with `aion/dynamic:inheriting`, or with `praxeon/web`'s background turn. An app that runs turns that way should watch for the `:sign-in-required` event, which carries the connection and the principal. The model is still told that a sign-in is needed. A test checks that the event reaches the app from another thread while the handler on the first thread sees nothing.

### For a usage ledger

The `:tool-call` and `:tool-result` events carry what a ledger needs to record a call:
- `:source`, which is `(:connection "docs" :tool "search" :per-user t)` for an MCP tool;
- `:principal`;
- `:agent`, the agent's name, and `:conversation`;
- `:outcome` on the result;
- `:ms`, the call's duration, on the result.

`:outcome` is one of four values:
- `:ok`: the means returned a result.
- `:error`: the tool ran and reported an error. For MCP this is a result with `isError` set, or a JSON-RPC error answer from the server.
- `:not-run`: the call was refused before the tool could run. Part 1 produces it in these cases:
  - a 401 or 403;
  - a per-user connection called with no principal;
  - a header argument that cannot be encoded;
  - an `UnsupportedProtocolVersionError` or a `HeaderMismatch`;
  - a 4xx reply the client could not read;
  - an `input_required` result.
- `:unknown`: the tool may have run. This is a `tools/call` that timed out, lost its connection, got a 5xx, or got a reply that ended before answering.

This holds until #493 settles the usage interface.

## The protocol

The client targets revision **2026-07-28** of the specification, read at modelcontextprotocol.io on 2026-10-03. That revision has no handshake. Every request carries:
- `params._meta`, holding `io.modelcontextprotocol/protocolVersion`, `io.modelcontextprotocol/clientInfo` and `io.modelcontextprotocol/clientCapabilities`;
- the headers `MCP-Protocol-Version`, `Mcp-Method`, and, for `tools/call`, `Mcp-Name`.

The client also speaks the legacy revisions 2025-11-25, 2025-06-18 and 2025-03-26, which open a session with `initialize`.

- **Finding the era.** The first request goes out in the current form.
  - A 400, 404 or 405 whose body is not a current-revision JSON-RPC error means a legacy server. Those errors are -32020, -32021 or -32022, or a 404 carrying -32601. The client then sends `initialize`, offering 2025-11-25, and keeps the `Mcp-Session-Id` for each principal.
  - A 401 or 403 says nothing about the era. The next request probes again.
  - The era is kept for the connection. When a request in the kept era gets the other era's answer, the client probes again, once.
- **Replies** are read as JSON or as an event stream. Notifications in the stream before the reply are counted in the log and dropped.
- **`x-mcp-header`.**
  - A tool parameter with this annotation is copied into an `Mcp-Param-{name}` header. A value that is not plain ASCII, or that has spaces at either end, or that looks like the encoded form, goes out as `=?base64?...?=`.
  - An integer outside JavaScript's safe range is refused before the call is sent.
  - A tool whose annotation breaks the specification's rules is left out of `list-tools`, with a warning in the log. Such an annotation is one reached through anything but `properties` keys, one on a type other than string, integer or boolean, one that is empty or not an HTTP token, or two that are equal ignoring case.
- **`resultType: "input_required"`.** This client offers no client capabilities, so it cannot answer an input request. Such a result fails the call without running it.
- **Where this client departs from the specification.**
  - On a `HeaderMismatch` (-32020), the specification says a client SHOULD list the tools again and retry. This client fails the call instead. A new listing could change a tool's schema without the app granting it again, and a grant is the app's decision. The app grants the tool again.
  - `ttlMs` and `cacheScope` on list results are ignored, because a grant does not change by itself.
  - The deprecated HTTP+SSE transport from 2024-11-05 is not implemented.

## Logging

The client logs counts, ids and durations:
- the connection;
- the method;
- the HTTP status;
- the milliseconds a request took;
- the number of tools and pages.

It never logs tool arguments, results, descriptions or tokens (`docs/logging.md`).
