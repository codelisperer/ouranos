# ADR-0020 — Keep Clack as the application interface; ship hyperion's own server as the default and as a Clack handler

**Status:** Accepted — 2026-09-29, the maintainer's decision. Supersedes decision points 1, 2
and 3 of [ADR-0015](0015-ring-calling-convention-without-clack.md) and keeps its point 4.
Schedules the removal of Woo and Hunchentoot that
[ADR-0017](0017-native-uv-server-as-default-backend.md) left for later. The work is tracked in
[#373](https://github.com/codelisperer/ouranos/issues/373).

## Context

ADR-0015 decided that hyperion would keep the Ring-shaped calling convention and drop the
Clack library. `hyperion/server-uv` would not implement a `clack.handler.*` backend, and
`clack` would leave `hyperion.asd` once the native server had been trusted in use. The
reasoning was that hyperion called Clack in two places only, `clack:clackup` and `clack:stop`,
so Clack was a third-party dependency kept for very little.

On 2026-09-29 the maintainer set a different goal:

> I want to support clack as the abstraction layer, so framework users can use whatever
> clack-compliant server they want/know. But I want to ship our own and remove the
> dependencies and limitations of woo and hunchentoot.

With that goal, Clack is the interface an application is written against, and it is what lets
an application run on a server that Ouranos did not write. That reverses most of ADR-0015.

## What is in the tree now

Measured at `3d67a34`, with Clack 2.1.0 (`clack-20250622-git`, from the pinned Quicklisp dist
`2026-01-01`):

- `hyperion` depends on `clack` and on no server. `hyperion/server:start` starts a Clack
  backend through `clack:clackup`. It starts `:uv` by calling `hyperion/server-uv:start`
  directly, looked up by name when the server starts, so that `hyperion` never depends on a
  system that needs libuv.
- `+backends+` in `hyperion/src/server.lisp` lists `:woo`, `:hunchentoot` and `:uv` in that
  order. When no server is named, `start` takes the first one whose package is loaded, so
  `:uv` loses to either of the others.
- No system in the tree declares Woo. Seven declare `clack-handler-hunchentoot`:
  `hyperion/tests`, `hyperion/assets/tests`, `hyperion/examples/active-search`,
  `hyperion/examples/active-search-db`, `hyperion/examples/coalton-repl`, `praxeon/elise` and
  `praxeon/web/tests`. The `cons init` web template (`cons/templates/web/template.lisp`) also
  gives every new app `clack-handler-hunchentoot`, and `cons/tests/init-tests.lisp` asserts
  that it does.
- The env that `hyperion/server-uv` builds (`%env`) has eight keys: `:request-method`,
  `:path-info`, `:query-string`, `:headers`, `:content-length`, `:content-type`, `:raw-body`
  and `:remote-addr`. Those are the keys hyperion reads; the ninth key hyperion reads is set by
  its own router. Clack's handler test suite (`src/test/suite.lisp` in Clack, run with
  `clack.test.suite:run-server-tests`) also checks `:server-name`, `:server-port`,
  `:server-protocol`, `:script-name`, `:remote-port`, `:request-uri` and `:url-scheme`.
- The parser, `hyperion/http1`, answers any request that has a `Transfer-Encoding` header
  with 501. Clack's handler test suite sends a chunked request body.

## Decision

1. **Clack stays the interface between an application and its server.** A hyperion
   application is a Clack application: a function that takes the Clack environment and returns
   `(status headers body)`. `clack` stays in the `:depends-on` of `hyperion`. An application
   runs on any Clack handler it loads, chosen with `:server` or `HYPERION_SERVER` as today.
   Documentation calls the env the Clack environment. This reverses ADR-0015's points 2 and 3.

2. **`hyperion/server-uv` also becomes a Clack handler, `clack.handler.uv`.**
   `(clack:clackup app :server :uv)` then runs any Clack application on it, not only a
   hyperion one. This reverses ADR-0015's point 1. To be a Clack handler it has to:
   - build the whole Clack environment, including the seven keys listed above that `%env`
     does not build today;
   - accept every Clack response: a list of strings, an octet vector, a pathname, and a
     delayed response, `(lambda (responder) ...)`, whose responder returns a writer that takes
     `(chunk &key close)`;
   - accept a chunked request body. Only the `chunked` coding is accepted. Any other transfer
     coding is still answered with 501, and a request that carries both `Transfer-Encoding`
     and `Content-Length` is refused with 400, so the parser's protection against request
     smuggling stays as strict as it is now;
   - stop the server when the thread running it is destroyed, because that is how
     `clack:stop` ends a handler that `clackup` started on a thread.

   Conformance is measured with Clack's own handler test cases, copied into a fiveam suite in
   the tree, each case naming the Clack test it came from. They are copied rather than loaded
   through the `clack-test` system for two reasons: `clack-test` depends on
   `clack-handler-hunchentoot`, `rove` and `dexador`; and its streaming test runs only for
   handlers on a fixed list (`:hunchentoot`, `:toot`, `:wookie`, `:woo`), so it would skip
   `:uv`.

3. **Hyperion's `start` keeps starting `:uv` directly, not through Clack.** `server-uv`'s
   `stop` closes the listener and every open connection on the loop thread before it closes
   the loop (#262). Hyperion stops a Clack backend by terminating the thread it runs on, which
   would skip that. Both paths run the same server. The conformance suite covers the Clack
   path, and `hyperion/server-uv/tests` covers the direct one.

4. **`:uv` becomes the default, as ADR-0017 decided, once ADR-0017's remaining precondition is
   confirmed:** a bundle built by hand on a machine that has a system libuv must still carry
   libuv. ADR-0017 stays Proposed until then and is Accepted when the default changes. Because
   hyperion declares no server (pre-publication issue 139), "the default" means three
   specific changes:
   - `:uv` moves to the head of `+backends+`, so an image with several backends loaded starts
     `:uv` when none is named;
   - every system in the tree that starts a server, and the `cons init` web template, declares
     `hyperion/server-uv` instead of `clack-handler-hunchentoot`;
   - desktop bundles run on `:uv` on every platform.

   `hyperion` itself still does not depend on `hyperion/server-uv`, because that system needs
   libuv and `hyperion` has to load without it.

5. **Woo and Hunchentoot leave every `:depends-on` in the tree**, test and example systems
   included. This lands in a later release than the default change in point 4, so that for
   one release the tree's suites still run the Clack path on Hunchentoot while applications
   move to `:uv`. An application that wants Woo or Hunchentoot adds the handler system to its
   own `:depends-on` and names it with `:server` or `HYPERION_SERVER`.

6. **ADR-0015's point 4 stands.** The HTTP/1.1 parser stays its own pure system,
   `hyperion/http1`, for the reason ADR-0015 gives: that keeps it inside what
   `scripts/verify-tree.lisp` checks. Decoding a chunked request body (point 2) goes in that
   system for the same reason.

## Consequences

- **Applications do not change.** A handler written for hyperion runs on `:uv`, Woo,
  Hunchentoot, or any other Clack handler the application loads.
- **Clack's own dependencies stay in every image that loads hyperion**, as they are today.
  `clack` 2.1.0 depends on `lack`, `lack-middleware-backtrace`, `lack-util`,
  `bordeaux-threads`, `usocket`, `swank`, `alexandria` and `uiop`. ADR-0015 would have
  removed them from hyperion; this decision keeps them.
- **Naming a server that is not loaded stops `start`** with `no-server-backend`, whose report
  lists the systems to add. A consuming app planning a trial of `:uv` found that setting
  `HYPERION_SERVER=uv` is not enough on its own. The app also has to add `hyperion/server-uv`
  to its `:depends-on`, and its runtime image has to contain libuv (on Debian, the `libuv1`
  package), in the same way a Woo deployment needs libev. The report says only "needs a built
  libuv". When the default changes, the report also says what a deployment needs at run time,
  and so does the CHANGELOG entry for the change.
- **Hyperion's code for Woo and Hunchentoot stays, and after point 5 nothing in the tree runs
  it.** Applications can still choose those servers, so `hyperion/server` keeps its refusal
  to start a second Woo server in one image (#198), its warning that Hunchentoot ignores
  `:workers`, and the handling in `%clack-start` of a failed Hunchentoot bind. What still
  runs is hyperion's Clack path against `clack.handler.uv`, and `clack.handler.uv` against
  test cases that Clack's authors wrote. No suite then runs hyperion on a server that Ouranos
  did not write.
- **Chunked request bodies are part of the Clack handler work (point 2), not a later
  limitation.** They change the parser, which is the most security-sensitive code in the tree,
  and they have to meet the rules against request smuggling in pre-publication issue 117 §4.
- **`:hunchentoot-no-ssl` stays pushed** at the top of `hyperion.asd` and `praxeon.asd`, so an
  application that adds Hunchentoot still gets it without OpenSSL (#343). When no system in
  those files depends on Hunchentoot any more, the comment above each push is changed to say
  that this is what the push is for.
- **The limitations an application on Woo or Hunchentoot may rely on each get an issue before
  point 5.** One is TLS termination in `server-uv` (#125). `aion/tls`, over the mbedTLS the
  tree builds, exists as an opt-in system, and `server-uv` does not use it yet. The other is
  WebSockets. `websocket-driver-server` depends on Clack's `clack-socket` protocol, which the
  Woo and Hunchentoot handlers implement, so `clack.handler.uv` has to implement it too before
  `websocket-driver` works on `:uv`.
- **A comparison with Woo is recorded on #373 before the default changes**: requests per
  second, latency percentiles, memory, and many open connections, on Linux. That measures
  what switching costs an application that runs on Woo today.

## Alternatives considered

- **Remove Clack, as ADR-0015 planned.** Rejected by the maintainer. An application could
  then run only on servers hyperion supports itself, each needing its own adapter in hyperion.
  Other Common Lisp web libraries, such as Lack middleware and `websocket-driver`, are also
  written against the Clack environment.
- **Keep Hunchentoot as a test-only dependency**, so that one suite still runs hyperion on a
  server Ouranos did not write. Not chosen: the maintainer's direction is that no system in
  the tree depends on Woo or Hunchentoot. What that costs is stated under Consequences.
- **Start `:uv` through Clack in `start` as well, so there is one path.** Rejected because of
  how Clack backends are stopped (point 3).
- **Load `clack-test` for conformance.** Rejected because of its dependencies and its
  streaming test (point 2).

## What this decision does not rest on

**Performance**, for the reasons ADR-0015 and ADR-0017 give. The case is the list of
limitations Ouranos has had to work around. Woo binds libev when it is loaded, aborts the
process when a second Woo server starts in the same image (#198), and sends a 429 as an empty
500 (#372). Hunchentoot reports a failed streamed response to the client as a complete one,
and brings in OpenSSL unless told not to (#343). A server that hyperion owns can be fixed in
the tree when it has a problem like these.

## Provenance

The maintainer made the decision in the hub session on 2026-09-29, after asking how far the
native server was from replacing Woo on every platform, Windows included.

Two findings made while writing this ADR changed the plan first filed on #373. That plan
said conformance would be measured with the `clack-test` system; reading it showed that it
depends on Hunchentoot and skips the streaming test for handlers not on its list, so its test
cases are copied instead. And Clack's suite sends a chunked request body, which moved chunked
request bodies out of the list of later limitations and into the Clack handler work.

What an application needs to try `:uv` (the dependency, and libuv in its runtime image) was
found by a consuming app's session while it planned a staging trial.
