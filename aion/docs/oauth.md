# aion/oauth: signing an app's users in to other services

`aion/oauth` is an OAuth 2.1 client for an app whose users sign in to another service, so that the app can act for them. It was written for MCP servers that require a sign-in (#527), and it lives in aion so that hermes, which attaches at aion, can use it for the ad networks as well. It has no web-server dependency: `hyperion/oauth` provides the routes.

It follows the authorization section of the MCP specification, revision 2026-07-28, read at modelcontextprotocol.io on 2026-10-03.

## The parts an app supplies

```lisp
(defparameter *broker*
  (oauth:make-broker
   :store (my-app:oauth-store)                    ; implements the store protocol
   :redirect-uri "https://app.example/oauth/return"
   :client-name "Example"
   :application-type "web"                        ; "native" for a desktop app
   :client-metadata-url "https://app.example/oauth/client.json"))
```

- **A store.** The broker keeps three kinds of record behind generic functions, and the app implements them over its own storage, encrypted at rest:
  - `get-token`, `put-token` and `delete-token`, keyed by principal and connection name;
  - `get-client`, `put-client` and `delete-client`, for a client registered dynamically, keyed by issuer and redirect URI. A store must implement all three: after `invalid_client`, `refresh` calls `delete-client` before it deletes the tokens. `delete-client` takes the client id as well, and deletes only when the stored id is that one, in one step (`DELETE … WHERE client_id = ?`), so a client registered meanwhile by another sign-in is never forgotten in its place;
  - `put-pending` and `take-pending`, for a sign-in in progress, keyed by its `state`. `take-pending` removes what it returns, so a `state` works once.

  `call-with-refresh-lock` serialises refreshes of one token. Its default method locks within the process; a store shared by several instances overrides it with a lock they share, such as a database row lock.

  `memory-store` is for tests and for an app that runs as one process. An app with several instances cannot use it, because a sign-in started on one instance would not be found on another.
  Every slot of a `token-set` and of a `pending` sign-in is exported, with `make-token-set` and `make-pending`, so a store can save each as strings and rebuild it. A `pending` record's verifier and a token set's tokens are `aion/secret` values: save `aion/secret:reveal`'s text, encrypted at rest, and rebuild with `aion/secret:make-secret`. `memory-store` drops expired pending sign-ins when it stores a new one. The test suite has a store of strings written with exported symbols only.
- **Two routes**, from `hyperion/oauth`:
  - `sign-in-return-handler` at the redirect URI. It needs a `:principal-of` function that reads the signed-in user from the request's session.
  - `client-metadata-handler` at the client metadata URL, when the app publishes one.

## The flow

1. **The app finds out a sign-in is needed.** An MCP call answered 401 signals `praxeon/mcp:authorization-required`, carrying the `WWW-Authenticate` challenge.
2. **The user starts it, signed in to the app.** A sign-in needs a principal: `start-sign-in` refuses NIL, and `finish-sign-in` refuses a return with no session principal, using up the `state` either way. So a sign-in shared by everyone is not possible through `oauth-token-source`, which looks up each call's principal.
   From the app's settings page, and never from inside a conversation, the app calls `(oauth:start-sign-in broker principal connection resource-url :challenge challenge)`. It returns the URL to send the browser to, and the scopes it requests, so the app can show them first. Before it builds the URL, it:
   - discovers and checks the metadata;
   - gets a client id;
   - stores the PKCE verifier and the expected issuer under a new `state`.
3. **The browser comes back** to the redirect URI. The route calls `finish-sign-in`, which refuses before redeeming the code in any of these cases:
   - the `state` is unknown, expired or used (`unknown-sign-in`, whose message says the sign-in may have started on another instance);
   - the session's principal is not the one that started the sign-in (`wrong-user`);
   - the `iss` parameter does not match the expected issuer (`sign-in-failed`).

   Then it exchanges the code, with the verifier and `resource`, and stores the tokens.
4. **Calls use the token.** `praxeon/mcp:oauth-token-source` returns each principal's own access token. It refreshes the token when it has expired, and once more when the server refuses it; the refreshed token is sent only after the issuer check below. A refresh the server refuses with `invalid_grant`, `invalid_client` or `unauthorized_client` deletes the tokens, and the next call asks the user to sign in. After `invalid_client`, a client registered dynamically is forgotten as well (`delete-client`), when it is the client those tokens were issued to, so that sign-in registers a new one. A pre-registered client, or one identified by a client ID metadata document, is not stored and is not affected.
5. **Disconnecting.** `(oauth:disconnect broker principal connection)` revokes the refresh token at the authorization server when it offers a revocation endpoint, and deletes the tokens either way.

## What is checked

- **Discovery.**
  - The protected-resource metadata is found where the specification says: the `resource_metadata` URL in the challenge, or failing that the path-inserted well-known URL, then the root one. Its `resource` must be the connection's canonical URI.
  - The authorization server's metadata is looked for at the RFC 8414 URL, then the OpenID Connect ones. For an issuer with a path, the path goes after the well-known suffix. The document's `issuer` must be identical to the issuer it was fetched for.
  - The server must offer PKCE with `S256`.
- **URLs from servers.** Every URL a server supplies must be https, or http on a loopback address. It is fetched through `aion/http-client:fetch-public`, which refuses internal addresses and here follows no redirect. A request carrying a code, a refresh token or client metadata is therefore never forwarded to another host.
- **Not on Windows yet.** `fetch-public` cannot pin a connection on Windows, and #295 decided that it signals `pinned-connect-unsupported` there rather than connect without the check. `aion/oauth` keeps that rule for every request, so a sign-in on Windows signals it, until `aion/http-client` can pin a connection there (#536).
- **The client id.** It comes from the first of these that applies:
  1. a client pre-registered for the issuer (`:pre-registered`, an alist of issuer to client id);
  2. the app's client ID metadata document, when the server sets `client_id_metadata_document_supported`;
  3. a client registered earlier with the same issuer;
  4. a dynamic registration (RFC 7591), sending `application_type`.

  A registered client is never used with another issuer. The client id is recorded with each sign-in, and the code is redeemed with that client, so a sign-in finished on another instance of the app still works. The client store should be shared by an app's instances, so that the app registers one client per issuer, not one per instance.
- **Scopes.** The scopes come from the first source that has some: the caller's `:scopes`, the challenge's `scope`, then the protected resource's `scopes_supported`. The scopes of an earlier sign-in to the same connection are kept, so a step-up after an `insufficient_scope` 403 does not lose them. `offline_access` is added when the authorization server lists it.
- **Tokens.** A token is kept with the resource and the issuer it was issued for. `access-token` returns it only for that resource, and only while the resource's protected-resource metadata still names that issuer. The metadata is cached per metadata URL and resource for the broker's `:metadata-lifetime`, one hour by default, and read again after the server refuses a token and after a sign-in, so the check does not cost a request on every call. Only a 200 with a JSON object is an answer. When a fetch fails, an expired answer is used for `:metadata-grace` seconds more (60 by default) and never renewed; after that `access-token` signals `oauth-error`, which `praxeon/mcp` reports as a call not run, until a fetch succeeds. A connection whose URL changes under the same name therefore needs a new sign-in. Tokens and the verifier are `aion/secret` values, and nothing is logged but connection names, issuers and outcomes.

## Known limitations

- **An MCP reply stream left open after the reply** is read until the read timeout, because `aion/http-client` reads a whole body. The call then fails, with outcome `:unknown` for a tool call. The specification says a server's final response SHOULD end the stream.
