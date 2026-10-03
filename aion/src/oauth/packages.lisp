;;;; packages.lisp --- aion/oauth: the OAuth sign-in a hosted MCP server, or any OAuth API, needs

(cl:defpackage #:aion/oauth
  (:use #:cl)
  (:local-nicknames (#:http #:aion/http-client)
                    (#:jzon #:com.inuoe.jzon)
                    (#:log #:aion/log)
                    (#:secret #:aion/secret)
                    (#:rnd #:aion/random))
  (:documentation
   "An OAuth 2.1 client for an app that signs its users in to other services (#527).

    It lives in aion so that hermes, which attaches at aion, can use it as well as praxeon.
    It needs no web server: START-SIGN-IN returns the URL to send a user's browser to, and
    FINISH-SIGN-IN takes the parameters the browser came back with. hyperion/oauth wraps
    FINISH-SIGN-IN as a route.

    Discovery follows the MCP authorization specification, revision 2026-07-28: protected
    resource metadata (RFC 9728), authorization server metadata (RFC 8414, or OpenID Connect
    Discovery), PKCE with S256, the resource parameter (RFC 8707), the iss check on the
    authorization response (RFC 9207), and a client that is pre-registered, identified by a
    client ID metadata document, or registered dynamically (RFC 7591).

    Tokens, registered clients and sign-ins in progress are kept behind the STORE protocol.
    MEMORY-STORE is for tests and for an app that runs as one process; an app with several
    instances implements the protocol over a store they share.

    Every URL a server supplies is untrusted. It must be https, or http on a loopback address,
    and it is fetched through aion/http-client:fetch-public, which refuses internal addresses
    and follows no redirects here, so no secret is sent anywhere it was not meant to go.")
  (:export
   ;; the broker
   #:broker #:make-broker #:broker-store #:broker-redirect-uri
   ;; the store protocol
   #:store #:memory-store #:make-memory-store
   #:get-token #:put-token #:delete-token
   #:get-client #:put-client
   #:put-pending #:take-pending
   #:call-with-refresh-lock
   #:token-set #:make-token-set #:token-set-access #:token-set-refresh #:token-set-expires-at
   #:token-set-scope #:token-set-resource #:token-set-issuer #:token-set-client-id
   #:token-set-token-endpoint #:token-set-revocation-endpoint
   #:pending #:pending-principal #:pending-connection #:pending-expires-at
   ;; the flow
   #:canonical-resource #:parse-challenge #:discover
   #:metadata #:metadata-issuer #:metadata-resource #:metadata-scopes
   #:start-sign-in #:finish-sign-in #:access-token #:refresh #:disconnect
   #:client-metadata-document
   ;; conditions
   #:oauth-error #:oauth-error-detail
   #:unknown-sign-in #:wrong-user #:sign-in-failed #:sign-in-failed-code
   #:metadata-refused #:url-refused #:no-client #:refresh-failed))
