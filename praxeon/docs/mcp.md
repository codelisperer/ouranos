# praxeon/mcp: agents that use MCP servers' tools, resources and prompts

`praxeon/mcp` connects Praxeon agents to MCP (Model Context Protocol) servers over Streamable
HTTP, and to local servers it starts as child processes and talks to over stdio (see "Local
servers over stdio" below). It gives agents a server's tools, lets an app add a server's resources to an agent's
context, and gets a server's prompts (see "Resources and prompts" below).

- **Tokens.** A request's bearer token comes from the connection's token source:
  - a function the app supplies;
  - for a server that requires a sign-in, `oauth-token-source`, which gives each user the token from their `aion/oauth` sign-in ([`aion/docs/oauth.md`](../../aion/docs/oauth.md)) and refreshes it. It does not sign anyone in: when a user has no usable token, the call fails with `sign-in-needed`, and the app starts the sign-in (see "Tokens from an OAuth sign-in" below).
- **Long-running calls.** On a connection made with `:tasks t`, a server may answer a tool call with a task that finishes later. The app polls it with `poll-tasks` (see "Long-running calls" below, #532).
- **Confirmation.** `grant-tools :confirm` names the tools whose calls need the user's confirmation. The turn's `:on-hold` decides how the user is asked; with no `:on-hold`, such a call is not run ([`confirm.md`](confirm.md), #531).

This is parts 1, 2, 4 and 5 of #527.

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
| The server answered with a task, on a connection made with `:tasks t` | that the tool started a background task whose result will be reported when it finishes, and not to call the tool again for this request | `:started` | `:task-started` is emitted; the result arrives later with `:task-finished` (see "Long-running calls") |
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

`:outcome` is one of five values:
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
- `:unknown`: the tool may have run. This is a `tools/call` that timed out, lost its connection, got a 5xx, got a reply that ended before answering, or got a result whose content could not be read. It is also a task the client did not ask for, or one it could not record.
- `:started`: the server answered with a task (#532). The call has no result yet. The `:task-finished` event with the same `:id` carries the outcome when the task ends; record the call's result from that.

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
- **`resultType: "input_required"`.** This client declares no elicitation, sampling or roots, so it cannot answer an input request. Such a result fails the call without running it.
- **Where this client departs from the specification.**
  - On a `HeaderMismatch` (-32020), the specification says a client SHOULD list the tools again and retry. This client fails the call instead. A new listing could change a tool's schema without the app granting it again, and a grant is the app's decision. The app calls `revoke-tools`, then `grant-tools` again, since `grant-tools` refuses a name the agent already has.
  - `ttlMs` and `cacheScope` on list results are ignored, because a grant does not change by itself.
  - The deprecated HTTP+SSE transport from 2024-11-05 is not implemented.

## Local servers over stdio

Part 5 of #527, from the 2026-07-28 pages "Transports" and "stdio", read at modelcontextprotocol.io on 2026-10-12.

```lisp
(defparameter *files*
  (mcp:make-connection :name "files"
                       :command '("npx" "-y" "some-mcp-server" "/srv/shared")
                       :environment '(("SOME_API_KEY" . "…"))
                       :stderr #p"/var/log/my-app/files-mcp.log"))

(defparameter *files-client* (mcp:make-client *files*))
;; list-tools, call-tool, grant-tools, resources, prompts and tasks work as over HTTP.
(mcp:close-client *files-client*)
```

- **Starting.** A connection made with `:command` instead of `:url` is a local server. `:command` is a list of strings: the program, found on `PATH`, and its arguments. The client starts the server at the first request, with `:directory` as its working directory when given, and writes one JSON-RPC message per line to its stdin and reads one per line from its stdout.
- **Environment.** The server's process does not get this process's environment. It gets only these variables from it, as `+stdio-environment+` lists them:
  - on Linux and macOS: `HOME`, `LOGNAME`, `PATH`, `SHELL`, `TERM` and `USER`, plus `LANG` and `TMPDIR`;
  - on Windows: `APPDATA`, `COMSPEC`, `HOMEDRIVE`, `HOMEPATH`, `LOCALAPPDATA`, `PATH`, `PATHEXT`, `PROCESSOR_ARCHITECTURE`, `PROGRAMDATA`, `PROGRAMFILES`, `PROGRAMFILES(X86)`, `PROGRAMW6432`, `SYSTEMDRIVE`, `SYSTEMROOT`, `TEMP`, `USERNAME`, `USERPROFILE` and `WINDIR`.

  Apart from `LANG` and `TMPDIR`, these are the lists the MCP TypeScript SDK passes to the servers it starts (`DEFAULT_INHERITED_ENV_VARS` in `packages/client/src/client/stdio.ts`, read at commit `b022522089a0c8b632595c6e7b536453945ed5a9`), so a Node or Python server written for that SDK finds the variables it expects, such as `HOME` or `LOCALAPPDATA` (#604). `LANG` and `TMPDIR` are kept as well. Neither holds a secret, and on macOS `TMPDIR` is the only place a process learns its per-user temporary directory. A value that starts with `()` is an exported bash function and is not passed, as the SDK does not pass it.

  To these the client adds the connection's `:environment`, an alist of `(name . value)` strings, which wins for a name in both. A local server is often someone else's code, and an app's process may hold keys for other services, so a variable the server needs, such as its API key, is passed by name. `:environment :inherit` gives the server this process's whole environment instead.
- **Credentials.** The specification says a server over stdio takes its credentials from its environment, so `:token-source` and `:per-user` are refused with `:command`. One process serves every principal; an app that needs a server process per user makes a connection per user.
- **The era.** The first request is preceded by `server/discover`, as the stdio page's "Backward Compatibility" says. A `DiscoverResult` whose `supportedVersions` holds 2026-07-28 means the current revision. Any other `DiscoverResult`, including one with no `supportedVersions`, or an error with a current-revision code (-32020, -32021 or -32022), means a server on the current era that does not support 2026-07-28. Any other error, or no answer within the connection's `:timeout`, means a legacy server, and the client sends `initialize`, offering 2025-11-25, then `notifications/initialized`; a legacy server whose `initialize` names a revision this client does not speak is unsupported too. Requests to an unsupported server fail as not run. A legacy server's `ping` is answered. `client-era` and `client-protocol-version` describe the server that is running: once a request finds that the server has exited, both are NIL until a new server's handshake succeeds, including when the server is not started again, and they stay NIL for an unsupported server. After `close-client` both are NIL. If the handshake fails, through a timeout or the server's exit, the request fails and the server is stopped; the next request starts it again, which counts toward the restart limit below. With `:restart nil` it is not started again.
- **Replies.** Requests may be in flight together; each reply is matched to its request by id. A line that is not a JSON object, a line longer than `:max-body-bytes` in octets as received (counted before decoding, so malformed UTF-8 cannot make a line look shorter), a notification, a reply nobody is waiting for, and a request from a server on the current era are dropped, and counted in the log under `not-json`, `too-long`, `notifications`, `late` and `requests`. A byte that is not UTF-8 is read as `?`, so it cannot end the reading of the server's output.
- **Timeouts.** A request that gets no answer within its timeout fails.
  - If it had been written to the server, the client sends `notifications/cancelled` for it with the reason `"timeout"`, and a tool call has the outcome `:unknown`.
  - If it was still queued, because the server had stopped reading its stdin, it fails as not run and is taken out of the queue, so it is never sent. An app can retry it without running it twice.
- **stderr.** With `:stderr nil`, the default, what the server writes to stderr is discarded. With a pathname, it is appended to that file. The client never reads it, and it never reaches the log, because a server may write anything there.
- **When the server exits.** The client notices when the server's stdout ends, and then requests waiting on it fail; a tool call has the outcome `:unknown`. A process the server started can keep its stdout open after the server exits. Then the requests waiting on it fail only at their timeouts, and the next request finds that the server's process has exited and starts it again. Such a process can also hold the server's stdin without reading it, so a write to it can stay blocked after the server exits. The client closes an exited server's pipes only once the threads that read and write them have finished, so a later server's pipe, which may get the same descriptor numbers, is never read or written by the old server's threads (#601). When the client finishes an exited server and its writer thread is still blocked 2 seconds later, it ends that thread. The pipes are closed then if the reader thread has also finished; if a process the server started still holds its stdout, they stay open until that output ends. The process holding stdin is not signalled, because once the server has exited the client cannot check that a saved process group id still belongs to the server's group; that process keeps running and reads end-of-file. Ending a blocked write this way is tested on Linux and macOS. The test is not built on Windows, so how a blocked write there responds is unknown.
  - With `:restart t`, the default, the next request starts the server again and finds its era again. A server that exits a fourth time within 60 seconds is not started again: requests fail as not run until a minute has passed since the earliest of the last three restarts.
  - With `:restart nil`, every later request fails as not run, until the app closes the client and makes another.
- **Closing.** `close-client` closes the server's stdin and waits `*stdio-close-seconds*` (5) for it to exit, then sends SIGTERM and waits `*stdio-term-seconds*` (2), then sends SIGKILL, as the stdio page's "Shutdown" says. Requests made with the client after that fail as not run. For an HTTP connection `close-client` does nothing. Clients whose server is still running are closed the same way when the image exits. For that, a client is kept in a list from its server's first start until `close-client`, so a client the app drops without closing it is never collected, and its server keeps running until the image exits.
- **Which processes are signalled.** On Linux and macOS, `sb-ext:run-program` makes the server the leader of a new process group, so the signals go to that group, which holds the server and any process it started. Before signalling, the client checks that the group's id equals the server's pid, and otherwise signals only the server, so no process of the app's is reached. On Windows the server is ended with `TerminateProcess`, which ends the server process alone (see "Known limitations").

## Resources and prompts

Part 4 of #527, from the 2026-07-28 pages for resources and prompts, read at modelcontextprotocol.io on 2026-10-05.

### Resources

Resources are chosen by the app. Nothing here gives the model a way to read a resource itself.

- `(mcp:list-resources client &key principal)` returns `resource` structs: `uri`, `name`, `title`, `description`, `mime-type`, `size` and `annotations`. `(mcp:list-resource-templates client &key principal)` returns `resource-template` structs, with a `uri-template`. Both follow `nextCursor` under `*max-list-pages*`, and a page without a list fails the listing.
- `(mcp:expand-uri-template template bindings)` expands an RFC 6570 template with an alist of strings. It supports levels 1 and 2 (`{var}`, `{+var}` and `{#var}`), with variable names as RFC 6570 section 2.3 defines them, and signals for any other expression rather than producing a wrong URI.
- `(mcp:read-resource client uri &key principal)` returns `resource-content` structs: `uri`, `mime-type`, and `text` or, for binary content, `blob-length`. Binary data is never decoded or kept. A resource the server says does not exist (`-32602`, or `-32002` from earlier revisions) signals `resource-not-found`. A reply with a content that is not an object, has no string `uri`, or has neither a string `text` nor a string `blob`, fails whole, so `add-resource` never installs part of a resource, and an earlier copy stays. A resource whose URI is `https://` is still read through the server: the client never fetches a URL a server names.
- `(mcp:add-resource agent client uri &key principal (value 1))` reads the resource and adds one context item per content to the agent's context.
  - Each item's text starts with a line saying which resource it is, which connection it was read from, and that it is data from that server, not instructions from the user or the app.
  - Its role is `:resource` and its source `(:mcp <connection> :uri <uri>)`.
  - A second `add-resource` of the same URI on the same connection replaces the earlier items. `(mcp:remove-resource agent client uri)` removes them.
  - `value` is the item's importance. `ctx:assemble` sends the items with the highest value per token that fit the agent's context budget, so an item can be left out of a request when others fill the budget, and nothing says so. Every context item works this way.
  - Each content's tokens are estimated once, over the heading line and the text, and that number is the item's `tokens`. A content larger than the agent's context budget would never be sent, so `add-resource` signals `resource-too-large` and adds nothing. The check is made when the resource is added: a smaller budget set later can make an item too large to send.
  - **Per-user resources.** The items stay in the context for every later turn, whoever its principal is, as tool results in the history do. Add a resource read with one user's token only to an agent that serves that user alone, and remove it with `remove-resource` when the app forgets that user (#150).
- Text from a server cannot end the context block or pose as another item. `prompt:render-items` escapes the block's tags in an item's text, taking their names from `prompt:*context-open*` and `prompt:*context-close*` when they have the form `<name>` and `</name>`. It indents every later line of the text, after any of the characters Unicode defines as line breaks: LF, CR, CRLF, VT, FF, NEL, LS or PS.

### Prompts

Prompts are chosen by the user, and a prompt's text goes in as the user's own turn.

- `(mcp:list-prompts client &key principal)` returns `prompt` structs: `name`, `title`, `description` and `arguments`, each a `prompt-argument` with `name`, `description` and `required`.
- `(mcp:get-prompt client prompt &key arguments principal)` takes a `prompt` from `list-prompts` and an alist of string arguments. It returns the messages, as `praxeon/llm` messages, and the description. A missing required argument, or a value that is not a string, signals `request-failed` before anything is sent. A reply with a message that is not an object, or whose content is not one content block of a known type (`text`, `image`, `audio`, `resource_link`, `resource`) with that type's required fields, fails whole rather than leaving the message out. A session on 2025-03-26 refuses `resource_link`, which that revision's schema does not have. Text content becomes text. Image and audio content, a resource link and a binary embedded resource are described in a line. An embedded text resource becomes its text.
- `(mcp:prompt-input prompt messages)` gives the input for `run-turn` from a prompt whose messages are all the user's. A prompt with assistant messages is a scripted exchange, and `prompt-input` signals `prompt-has-assistant-messages`; the app decides what to do with it.

Not supported: subscriptions and the `list_changed` notifications, the completion API for arguments, and caching by `ttlMs`.

## Long-running calls

A tool call that takes minutes can finish after the turn that started it, through the MCP Tasks extension, `io.modelcontextprotocol/tasks` (#532). This client follows the extension's specification for revision 2026-07-28, read in modelcontextprotocol/ext-tasks at commit 899c1bb.

```lisp
(defparameter *jobs*
  (mcp:make-connection :name "jobs" :url "https://example.com/mcp" :per-user t :tasks t
                       :token-source (mcp:oauth-token-source *broker*)))

(defparameter *jobs-client* (mcp:make-client *jobs* :task-store (my-app:task-store)))

;; In the app's job runner, every few seconds:
(dolist (finished (mcp:poll-tasks *jobs-client*))
  (my-app:deliver finished))   ; for example, a later run-turn with (mcp:task-report finished)
```

- **Opting in.** `:tasks t` declares the extension in every current-revision request. The server then decides, call by call, whether to answer with a task. Without the option nothing is declared; a server that sends a task anyway has broken the specification, and the call fails with outcome `:unknown`, because the work may have started. Legacy sessions declare nothing.
- **When a call becomes a task.** The task is saved in the client's task store before the call returns. The model is told that the tool started a background task whose result will be reported when it finishes, and not to call the tool again for this request. The call's `:tool-result` event has outcome `:started`, and a `:task-started` event is emitted. If the store cannot save it, or the task lacks what the specification requires of one (a known `status`, `createdAt`, `lastUpdatedAt`, and a `ttlMs` that is a number or null), the call fails with outcome `:unknown`, because the work may have started.
- **The task id stays between the client and the server.** The specification lets a server use it as the bearer of the task's state, so it is sent only to the server, in `params.taskId` and the `Mcp-Name` header. The model, events and logs see `task-key`, the client's own id for the record.
- **The task store.** It is a protocol of six generic functions. `save-task` writes a record once, when the task starts. After that, `update-task` (after a poll that did not finish the task) and `finish-task` (when it finished) replace the record only while it is still there and has no outcome, and return true when they did. For a database each is `UPDATE ... WHERE key = ? AND outcome IS NULL` and a check that one row changed. So when several pollers share the store, a poll that read a task before another poller finished it cannot write it back, and only the poller whose `finish-task` returned true reports it. `announce-task` sets a finished record's `task-announced-at` only when it has none, and returns true only for the call that set it; that call sends `:task-finished`. For a database it is `UPDATE ... WHERE key = ? AND outcome IS NOT NULL AND announced_at IS NULL`. `due-tasks` returns copies of the due records, and `remove-task` deletes one. `make-memory-task-store`, the default, keeps tasks in the process, so they are lost when it ends. An app whose tasks must survive a restart supplies a store backed by its database, and can keep each task as JSON text with `task-to-json` and `task-from-json`. `make-client` refuses a store that has no primary method of its own for one of the six functions, and names the missing ones; a method on `t`, or only an `:around`, `:before` or `:after` method, does not count.
- **Polling.** `poll-tasks` polls each task of the client's connection whose next poll is due, once, and returns the tasks that finished. praxeon starts no thread for this; the app's job runner calls it. Each poll sends `tasks/get` for the task's own principal, with a token fetched at that moment, so an OAuth token is refreshed when it needs to be. The next poll is due after the server's latest `pollIntervalMs`, rounded up to whole seconds and never less than 1, or `*default-poll-seconds*` (5) when the server gives none. The next poll is never due later than the task's deadline. A poll that fails, through a timeout, a 5xx or a missing sign-in, leaves the task due again later. The wait after the first failure in a row is the poll interval, and it doubles with each further failure, up to the connection's `task-backoff-cap` (`make-connection :task-backoff-cap`, in seconds, five minutes by default); a poll that succeeds goes back to the interval. While a task's principal has to sign in, `:sign-in-required` is emitted, and `authorization-required` signalled, once, on the first failed poll of the run, not on every poll. A poll that succeeds, or that fails for another reason, ends the run, and the next sign-in failure tells the app again. When an observer of `:sign-in-required` signals, or an app's handler of `authorization-required` exits, `poll-tasks` is left at that point, and the failed poll is still recorded first: the task waits before its next poll and is not polled again at once. A poll left this way at the task's deadline marks the task `:expired`, and the next `poll-tasks` returns it. If the store fails while recording either, its error is logged and the caller gets the condition that left the poll. `make-connection` refuses a `:task-lifetime` or `:task-backoff-cap` that is not a positive integer. The task record keeps the run in `task-failures` and `task-failure`, so an app's store has to keep them too; `task-to-json` writes them. `poll-task` and `cancel-task` signal an error, and send nothing, for a task of another connection than the client's, because its id and principal would go to a server that did not issue them.
- **When a task ends.** Its outcome and text are written to its record with `finish-task`, the record is marked announced with `announce-task`, and a `:task-finished` event is emitted. The record is removed only when `poll-tasks` is about to return it, as a `finished-task`. When an observer signals on any event, `poll-tasks` returns nothing, and every task that finished in that call stays in the store, due at once. The next `poll-tasks` returns each of them without polling the server, and sends `:task-finished` only for one it was not yet sent for, such as a task whose `:task-input-refused` event the observer failed on. No event is sent twice. The outcomes:
  - `:ok`: completed. The text is the result's text, as for a call that answered at once.
  - `:error`: completed with `isError`, or failed with a JSON-RPC error. The text names the error code and never repeats the server's message.
  - `:cancelled`: cancelled by the server, by `cancel-task`, or because it asked for input (below).
  - `:expired`: still not finished when polled at its deadline, or no longer known to the server (-32602). The deadline is `ttlMs` after the client received the task. When the server sends a `ttlMs` of null, which means no limit, the deadline is the connection's `task-lifetime` after the client received the task: `make-connection :task-lifetime`, in seconds, one day by default. Without it, a task whose polls keep failing, for example while its user has not signed in again, would be polled, and `:sign-in-required` emitted, every few seconds for as long as the process runs. The specification counts from the server's `createdAt`, which is earlier and on the server's clock; counting from receipt never gives a task up before the server may, and a server that discarded it earlier answers -32602. A `ttlMs` of 0 is a deadline of that moment, and the task is still polled once.
  - `:unknown`: completed with a result the client could not read.
- **Getting the result to the conversation is the app's decision**, because it depends on whether the user is present. `task-report` gives text for a later turn that names the tool and says that what follows is the tool's output, not something the user said. The output comes from the server and is untrusted, as any tool result is.
- **Input requests are refused.** The 2026-07-28 revision's "Multi Round-Trip Requests" page, server requirement 7, says: "Servers **MUST NOT** send an `inputRequests` that the client has not declared support for in its capabilities." This client declares no elicitation, sampling or roots, so a server should never ask a task for input. A task that asks anyway is cancelled with `tasks/cancel`, which is sent, and the task marked finished, before `:task-input-refused` and `:task-finished`, so an observer that fails on either cannot leave the task waiting. When `tasks/cancel` needs a sign-in and an observer of `:sign-in-required` signals, or an app's handler of `authorization-required` exits, the task is still marked cancelled, and the next `poll-tasks` returns it without sending `tasks/cancel` again; `:task-input-refused` is not sent in that case (#587). That is the only refusal the specification allows, because an input response is the result of the request's own kind and has no error form. A `:task-input-refused` event names each request's method, and the task finishes as `:cancelled`, with text naming the kinds the specification defines. Answering elicitations is #563.
- **Cancelling.** `cancel-task` sends `tasks/cancel`, then removes the task and reports it as `:cancelled`. The server may finish the work anyway.
- **Not supported.** Task status notifications on a `subscriptions/listen` stream (polling is the default), and the legacy revisions' experimental tasks.

### Events

| Event | When | Fields |
|---|---|---|
| `:task-started` | a call became a task | `:id` (the tool call's id), `:key`, `:connection`, `:tool`, `:source`, `:principal`, `:agent`, `:conversation` |
| `:task-input-refused` | a task asked for input and is being cancelled | the same, and `:methods` |
| `:task-finished` | a task ended | the same, and `:outcome`, and `:ms`, the milliseconds since the call started, measured to the second |

`:id` is `actor:*tool-call-id*` at the time of the call, so a ledger joins a task's events to the call's `:tool-call` and `:tool-result` events.

## Known limitations

- **On Windows, a process a local server started can outlive it.** `close-client` ends the server with `TerminateProcess`, which does not end the processes the server started. A server started through a launcher such as `npx` or a `.cmd` file can therefore keep running after the client is closed. Putting the server in a Job Object would end them together; that is #599.
- **A reply stream left open fails at the read timeout.** `aion/http-client` reads a whole body. A server that leaves its event stream open after its final reply is therefore read until the read timeout, and the call fails then, with outcome `:unknown` for a tool call. The specification says the final response SHOULD end the stream, so a server that conforms does not do this. A test records the behaviour.

## Logging

The client logs counts, ids and durations:
- the connection;
- the method;
- the HTTP status;
- the milliseconds a request took;
- the number of tools, resources, templates, prompts, contents or pages;
- of a resource's URI, only its scheme and host, because a URI can carry a user's data;
- for a local server, its pid, its era, how it was stopped, its exit status and code, and the numbers of notifications, dropped lines and late replies it sent. A server that could not be started is logged with the error's type only, since the message can name the command.

It never logs tool arguments, results, descriptions, resource contents, prompt arguments or tokens, nor a local server's command, environment or stderr (`docs/logging.md`).
