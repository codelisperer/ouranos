;;;; packages.lisp --- praxeon/mcp: agents that use the tools an MCP server offers (#527).

(cl:defpackage #:praxeon/mcp
  (:use #:cl)
  (:local-nicknames (#:http #:aion/http-client)
                    (#:jzon #:com.inuoe.jzon)
                    (#:log #:aion/log)
                    (#:actor #:praxeon/actor)
                    (#:cnd #:praxeon/conditions)
                    (#:evt #:praxeon/event)
                    (#:oauth #:aion/oauth))
  (:documentation
   "A client for MCP (Model Context Protocol) servers, and the bridge that gives their tools to
    Praxeon agents as means (#527).

    A CONNECTION is data: a name, a URL, and how to get a token. A CLIENT talks to one
    connection's server. LIST-TOOLS reads what the server offers and gives it to nobody;
    GRANT-TOOLS gives an agent the tools the app chooses, under names prefixed by the
    connection's name.

    Both eras of the protocol are spoken over Streamable HTTP. The current revision,
    2026-07-28, has no handshake: every request carries its protocol version and the client's
    identity. The legacy revisions, 2025-03-26 to 2025-11-25, open a session with
    `initialize'. The client tries the current form first, falls back when the server's reply
    says it does not understand it, and remembers the answer for the connection.

    Text from a server is untrusted. Descriptions and results reach the model; nothing a
    server sends changes which tools an agent has.")
  (:export
   ;; connections and clients
   #:connection #:make-connection #:connection-name #:connection-url
   #:connection-token-source #:connection-per-user #:connection-timeout
   #:connection-call-timeout
   #:client #:make-client #:client-connection #:client-era #:client-protocol-version
   #:+protocol-version+ #:+legacy-protocol-versions+
   ;; limits an app may set
   #:*max-abandoned-requests* #:*max-list-pages* #:*max-schema-characters*
   #:*max-description-characters*

   ;; token sources
   #:token-for #:token-refused #:oauth-token-source
   ;; tools
   #:tool #:tool-name #:tool-title #:tool-description #:tool-input-schema #:tool-annotations
   #:list-tools #:call-tool #:grant-tools #:revoke-tools #:means-name
   ;; conditions
   #:mcp-error #:request-failed #:request-failed-code #:tool-error
   #:authorization-required #:authorization-required-connection
   #:authorization-required-principal #:authorization-required-challenge
   #:sign-in-needed
   #:tool-name-conflict #:tool-name-conflict-names))
