# praxeon/mcp: agents that use MCP servers' tools, resources and prompts

`praxeon/mcp` connects Praxeon agents to MCP (Model Context Protocol) servers over Streamable
HTTP. It gives agents a server's tools, lets an app add a server's resources to an agent's
context, and gets a server's prompts (see "Resources and prompts" below).

- **Tokens.** A request's bearer token comes from the connection's token source:
  - a function the app supplies;
  - for a server that requires a sign-in, `oauth-token-source`, which gives each user the token from their `aion/oauth` sign-in ([`aion/docs/oauth.md`](../../aion/docs/oauth.md)) and refreshes it. It does not sign anyone in: when a user has no usable token, the call fails with `sign-in-needed`, and the app starts the sign-in (see "Tokens from an OAuth sign-in" below).
- **Confirmation.** `grant-tools :confirm` names the tools whose calls need the user's confirmation. The turn's `:on-hold` decides how the user is asked; with no `:on-hold`, such a call is not run ([`confirm.md`](confirm.md), #531).

This is parts 1, 2 and 4 of #527. Local servers over stdio are part 5.

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
(defparameter *docs-tools* (mcp:list-tools *docs-client* :principal "user-42"))

;; Gives an agent the tools the app chooses, as the means docs__search and docs__fetch.
;; The listing is passed on: on a :per-user connection, a listing with no principal is refused.
(mcp:grant-tools agent *docs-client* :tools *docs-tools* :only '("search" "fetch"))

;; Each tool call uses the token of the user this turn runs for.
(actor:run-turn agent "Find the release notes" :principal "user-42")
```

- **A connection is data:**
  - `name` prefixes the tool names an agent sees, and appears in logs.
  - `url` is the server's MCP endpoint.
  - `token-source` gives each request's bearer token. It is NIL for no token; a function of the connection and a principal that returns a token or NIL; or an object that implements `token-for`, such as `oauth-token-source`'s (see "Tokens from an OAuth sign-in" below).
  - `per-user` refuses a call that has no principal, before anything is sent.
  - `timeout` bounds every request, and `call-timeout` bounds a tool call.
  - `max-body-bytes` bounds a reply.
- **The principal is chosen for each call.** `run-turn :principal` binds `actor:*principal*` for the turn, and each MCP means reads it when it is called. Each call therefore uses the token of the user whose turn it is. The principal separates credentials, not conversations: an agent has one history, and every request is built from it, so each user needs an agent, or at least a history, of their own. A delegated sub-turn keeps the principal of the turn that delegated it.
- **A grant names its tools.** `:only` is required: a list of the server's tool names, or `:all`. No default grants every tool on a server.
- **A grant is fixed when the app makes it.** Nothing a server sends later changes which tools an agent has. A `notifications/tools/list_changed` from the server is not acted on. The app calls `grant-tools` or `revoke-tools` again.
- **Names.** A tool's means name is the connection's name, two underscores, and the tool's name. Characters outside `A-Z a-z 0-9 _ -` become `_`, and the whole is cut to 64 characters. A name that clashes with a means the agent already has, or with another tool in the same grant, signals `tool-name-conflict`, and nothing is registered.

## Tokens from an OAuth sign-in

A token source is anything that implements `token-for`: a function, NIL for no token, or an object. A source may also implement `token-refused`, which is called when the server answers 401 or 403 to the token it gave. When `token-refused` returns a different token, the request is sent once more with it. The server did not process the refused request, so this is the one retry a tool call gets.

`(mcp:oauth-token-source broker)` is the source for a server that requires an OAuth sign-in:
- It gives each principal's own token from an `aion/oauth` broker.
- It refreshes an expired token, and refreshes once more when the server refuses the token.
- After an `insufficient_scope` 403 it does not refresh, because only a new sign-in with more scope can help.

Sign-in is not available on Windows yet. `aion/oauth` fetches every URL a server supplies through `fetch-public`, which cannot pin a connection on Windows and refuses there (#295). A sign-in on Windows therefore signals `pinned-connect-unsupported`, until `aion/http-client` can pin a connection there (#536).

When there is no usable token, the call fails with `sign-in-needed`. The app then starts a sign-in with `oauth:start-sign-in` from the challenge that `authorization-required` carried.

```lisp
(defparameter *docs*
  (mcp:make-connection :name "docs" :url "https://example.com/mcp" :per-user t
                       :token-source (mcp:oauth-token-source *broker*)))
```

## What the model sees, and what the app sees

| What happened | The model is told | `:outcome` on the `:tool-result` event | The app |
|---|---|---|---|
| The tool answered | the result's text | `:ok` | |
| The tool answered with `isError` | the result's text, as an error result | `:error` | `tool-error` is the cause |
| The server answered a JSON-RPC error, or refused the version | that the connection failed, with the code | `:error` or `:not-run` | `request-failed` |
| A 401 or 403, or no principal for a per-user connection | that the user must sign in, with no URL | `:not-run` | `authorization-required` is signalled, and a `:sign-in-required` event is emitted |
| A timeout, a dropped connection, a 5xx, a reply that ends early, or a result that is not a JSON object, during `tools/call` | that the outcome is unknown, the tool may have run, and it should not be called again before checking with the user | `:unknown` | `request-failed` |
| A redirect or a 4xx such as 409, 413, 422 or 429; a header argument that does not have its declared type; or at `*max-abandoned-requests*` given-up requests still running | that the connection failed or refused the call | `:not-run` | `request-failed` |

All of these let the turn go on. They are subclasses of `praxeon/conditions:tool-error-result`, which a turn reports to the model as an error result.

- **No `tools/call` is sent twice.** The client retries a request only when the reply shows the server did not process it:
  - a current-revision request that a legacy server could not read;
  - a legacy request that a current server rejected with a current-revision error;
  - the legacy 404 for an ended session;
  - a 401 or 403 to a token that the token source then replaces, once, including on the legacy `initialize`. The server refused the request before processing it. A tool granted with `:confirm` (#531) is the exception: it is not sent again, the token is still refreshed for the next call, and the model is told the user can ask again. See [`confirm.md`](confirm.md).
- **Every request has a deadline of its own.** A request runs on its own thread and is given up one second after its timeout, whatever the transport does. Two cases need this:
  - On #530's Windows leg, dexador's WinHTTP backend let a request outlive its read timeout (#537).
  - On every platform, a server that sends a keep-alive line every so often keeps a read timeout from firing.

  A request given up this way is not sent again. Its thread keeps running, with the connection open, until the server finishes or the transport ends it, and it logs how the request ended. Each client counts those threads; the bound is per client. At `*max-abandoned-requests*` of them (8) still running, the client refuses new requests, as not run, until some finish. Calls made at the same moment can go a few past it. However a thread ends, it takes itself off the count, and its log line carries the caller's log context. The thread sees the global values of special variables, so dexador settings such as `dex:*default-proxy*` reach MCP requests only when they are set globally.
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
- `:not-run`: the call was refused before the tool could run. The client produces it in these cases:
  - a 401 or 403;
  - no usable token (`sign-in-needed`), or a token source that could not give or refresh one;
  - a tool held for confirmation whose token the server refused: it is not sent again (#531);
  - too many earlier requests to the server still running after their deadline (`*max-abandoned-requests*`);
  - a per-user connection called with no principal;
  - a header argument that cannot be encoded;
  - an `UnsupportedProtocolVersionError` or a `HeaderMismatch`;
  - a 4xx reply the client could not read;
  - an `input_required` result.
- `:unknown`: the tool may have run. This is a `tools/call` that timed out, lost its connection, got a 5xx, got a reply that ended before answering, or got a result whose content could not be read.

The turn loop gives these outcomes too, for any means. When a means fails in the middle of a step, the call it was on gets `:unknown` and the calls after it get `:not-run` (#546; see "When a means fails in the same step" in [`confirm.md`](confirm.md)). An approval that an earlier attempt recorded, whose result is missing, also gets `:unknown` (#531).

This holds until #493 settles the usage interface.

## The protocol

The client targets revision **2026-07-28** of the specification, read at modelcontextprotocol.io on 2026-10-03. That revision has no handshake. Every request carries:
- `params._meta`, holding `io.modelcontextprotocol/protocolVersion`, `io.modelcontextprotocol/clientInfo` and `io.modelcontextprotocol/clientCapabilities`;
- the headers `MCP-Protocol-Version`, `Mcp-Method`, and, for `tools/call`, `Mcp-Name`.

The client also speaks the legacy revisions 2025-11-25, 2025-06-18 and 2025-03-26, which open a session with `initialize`.

- **Finding the era.** The first request goes out in the current form.
  - A 400, 404 or 405 whose body is not a current-revision JSON-RPC error means a legacy server. Those errors are -32020, -32021 or -32022, or a 404 carrying -32601. The client then sends `initialize`, offering 2025-11-25, and keeps the `Mcp-Session-Id` for each principal.
  - The era is recorded only once the legacy request has gone through. A server on the current revision that answered one request badly, through a proxy's 404 or a header it would not take, answers the legacy `initialize` with a current-revision error; that one request then fails as not run, and the next request probes again.
  - A 401 or 403 says nothing about the era. The next request probes again.
  - The era is kept for the connection. When a request in the kept era gets the other era's answer, the client probes again, once.
- **Replies** are read as JSON or as an event stream. Notifications in the stream before the reply are counted in the log and dropped.
- **`x-mcp-header`.**
  - A tool parameter with this annotation is copied into an `Mcp-Param-{name}` header. A value that is not plain ASCII, or that has spaces at either end, or that looks like the encoded form, goes out as `=?base64?...?=`.
  - An integer outside JavaScript's safe range is refused before the call is sent.
  - A tool whose annotation breaks the specification's rules is left out of `list-tools`, with a warning in the log. Such an annotation is one reached through anything but `properties` keys, one on a type other than string, integer or boolean, one that is empty or not an HTTP token, or two that are equal ignoring case.
- **Settings an app may change.** `*max-abandoned-requests*` (8), `*max-list-pages*` (1000), `*max-schema-characters*` (20000) and `*max-description-characters*` (2000) are exported from `praxeon/mcp`.
- **Tool definitions.**
  - A tool whose `inputSchema` is not a JSON object schema, with `"type": "object"`, is left out of `list-tools`, with a warning in the log, since both providers take only an object schema.
  - So is a tool whose schema is longer than `*max-schema-characters*` (20000) as JSON, since the schema is sent with every request.
  - A listing that goes past `*max-list-pages*` (1000) pages without ending fails, so `:only :all` never grants part of a server's tools as though it were all of them.
- **Header arguments follow the declared type.** An `x-mcp-header` argument must have the type its property declares: a string, an integer, or a boolean. One that does not is refused before the call is sent, so the model gets an error it can correct. Header names must be ASCII HTTP tokens.
- **`resultType: "input_required"`.** This client offers no client capabilities, so it cannot answer an input request. Such a result fails the call without running it.
- **Where this client departs from the specification.**
  - On a `HeaderMismatch` (-32020), the specification says a client SHOULD list the tools again and retry. This client fails the call instead. A new listing could change a tool's schema without the app granting it again, and a grant is the app's decision. The app calls `revoke-tools`, then `grant-tools` again, since `grant-tools` refuses a name the agent already has.
  - `ttlMs` and `cacheScope` on list results are ignored, because a grant does not change by itself.
  - The deprecated HTTP+SSE transport from 2024-11-05 is not implemented.

## Resources and prompts

Part 4 of #527, from the 2026-07-28 pages for resources and prompts, read at modelcontextprotocol.io on 2026-10-05.

### Resources

Resources are chosen by the app. Nothing here gives the model a way to read a resource itself.

- `(mcp:list-resources client &key principal)` returns `resource` structs: `uri`, `name`, `title`, `description`, `mime-type`, `size` and `annotations`. `(mcp:list-resource-templates client &key principal)` returns `resource-template` structs, with a `uri-template`. Both follow `nextCursor` under `*max-list-pages*`, and a page without a list fails the listing.
- `(mcp:expand-uri-template template bindings)` expands an RFC 6570 template with an alist of strings. It supports levels 1 and 2 (`{var}`, `{+var}` and `{#var}`), and signals for any other expression rather than producing a wrong URI.
- `(mcp:read-resource client uri &key principal)` returns `resource-content` structs: `uri`, `mime-type`, and `text` or, for binary content, `blob-length`. Binary data is never decoded or kept. A resource the server says does not exist (`-32602`, or `-32002` from earlier revisions) signals `resource-not-found`. A resource whose URI is `https://` is still read through the server: the client never fetches a URL a server names.
- `(mcp:add-resource agent client uri &key principal (value 1))` reads the resource and adds one context item per content to the agent's context.
  - Each item's text starts with a line saying which resource it is, which connection it was read from, and that it is data from that server, not instructions from the user or the app.
  - Its role is `:resource` and its source `(:mcp <connection> :uri <uri>)`.
  - A second `add-resource` of the same URI on the same connection replaces the earlier items. `(mcp:remove-resource agent client uri)` removes them.
  - `value` is the item's importance. `ctx:assemble` sends the items with the highest value per token that fit the agent's context budget, so an item can be left out of a request when others fill the budget, and nothing says so. Every context item works this way.
  - Each content's tokens are estimated once, over the heading line and the text, and that number is the item's `tokens`. A content larger than the agent's context budget would never be sent, so `add-resource` signals `resource-too-large` and adds nothing. The check is made when the resource is added: a smaller budget set later can make an item too large to send.
  - **Per-user resources.** The items stay in the context for every later turn, whoever its principal is, as tool results in the history do. Add a resource read with one user's token only to an agent that serves that user alone, and remove it with `remove-resource` when the app forgets that user (#150).
- Text from a server cannot end the context block or pose as another item: `prompt:render-items` escapes `<context>` and `</context>` in an item's text and indents its later lines.

### Prompts

Prompts are chosen by the user, and a prompt's text goes in as the user's own turn.

- `(mcp:list-prompts client &key principal)` returns `prompt` structs: `name`, `title`, `description` and `arguments`, each a `prompt-argument` with `name`, `description` and `required`.
- `(mcp:get-prompt client prompt &key arguments principal)` takes a `prompt` from `list-prompts` and an alist of string arguments. It returns the messages, as `praxeon/llm` messages, and the description. A missing required argument, or a value that is not a string, signals `request-failed` before anything is sent. Text content becomes text. Image and audio content, a resource link and a binary embedded resource are described in a line. An embedded text resource becomes its text.
- `(mcp:prompt-input prompt messages)` gives the input for `run-turn` from a prompt whose messages are all the user's. A prompt with assistant messages is a scripted exchange, and `prompt-input` signals `prompt-has-assistant-messages`; the app decides what to do with it.

Not supported: subscriptions and the `list_changed` notifications, the completion API for arguments, and caching by `ttlMs`.

## Known limitations

- **A reply stream left open fails at the read timeout.** `aion/http-client` reads a whole body. A server that leaves its event stream open after its final reply is therefore read until the read timeout, and the call fails then, with outcome `:unknown` for a tool call. The specification says the final response SHOULD end the stream, so a server that conforms does not do this. A test records the behaviour.

## Logging

The client logs counts, ids and durations:
- the connection;
- the method;
- the HTTP status;
- the milliseconds a request took;
- the number of tools, resources, templates, prompts, contents or pages;
- of a resource's URI, only its scheme and host, because a URI can carry a user's data.

It never logs tool arguments, results, descriptions, resource contents, prompt arguments or tokens (`docs/logging.md`).
