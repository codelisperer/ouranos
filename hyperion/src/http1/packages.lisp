;;;; packages.lisp --- hyperion/http1: the HTTP/1.1 message parser (Coalton core).
;;;;
;;;; Its own system, and its own package, deliberately kept free of every hyperion
;;;; dependency -- see docs/adr/0015-ring-calling-convention-without-clack.md. The reason is
;;;; evidence, not tidiness: scripts/verify-tree.lisp EXCLUDES aion/uv* because those systems
;;;; need a C toolchain and a built vendor/libuv. A parser living inside the transport system
;;;; would put the most security-critical code in the tree outside the checker AGENTS.md names
;;;; as the standard of evidence. Pure and separate puts it back inside.

(cl:defpackage #:hyperion/http1
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:str #:coalton/string)
                    (#:list #:coalton/list)
                    (#:char #:coalton/char)
                    ;; QUOT and MOD are NOT in coalton-prelude -- they live in the Integral
                    ;; class and must be nicknamed in. TO-HEX is the only user; without this
                    ;; the failure is "unknown variable QUOT" at macroexpansion, which reads
                    ;; like a typo rather than a missing import.
                    (#:math #:coalton/math/integral))
  (:documentation
   "HTTP/1.1 request-head parsing as a total function over bytes-as-ISO-8859-1.

    PARSE-HEAD is INCREMENTAL: it is fed whatever has arrived so far and answers
    Incomplete / Complete / Rejected, because a TCP chunk boundary is not a message
    boundary. It parses the request line and header block ONLY -- the body stays octets in
    the CL shell, which is the layer that owns sockets and byte vectors.

    Rejection carries a STATUS CODE, not a boolean, because every rejection here is a
    response the server still has to write. The security floor (request smuggling,
    oversized heads, malformed framing) is enforced at parse time and is not optional; see
    the file header for the individual rules and why each one is there.

    The CL-facing surface traffics only in PROMISED representations -- Boolean, UFix,
    String, a flat (List String) of header name/value pairs -- so a caller never
    destructures a Coalton ADT. Same convention as hyperion/path, and the accessors are
    TOTAL: a wrong-variant read returns a harmless default rather than signalling, because
    the shell branches on HEAD-COMPLETE? / HEAD-REJECTED? first.")
  (:export
   ;; the types
   #:Version #:Http-1-0 #:Http-1-1
   #:Body-Spec #:Body-None #:Body-Exact
   #:Request #:Head-Result #:Incomplete #:Complete #:Rejected
   ;; the parser
   #:parse-head
   ;; limits, exported so the shell can name them in an error
   #:max-head-octets #:max-header-fields
   ;; CL-facing, total accessors
   #:head-incomplete? #:head-complete? #:head-rejected?
   #:head-status #:head-reason #:head-consumed
   #:head-method #:head-target #:head-version #:head-keep-alive?
   #:head-has-body? #:head-body-length #:head-headers-flat
   ;; the response encoder (commit 2)
   #:Encode-Result #:Encoded #:Refused
   #:encode-head #:encode-head-flat #:encode-error #:encode-interim #:reason-phrase
   #:encode-ok? #:encode-text #:encode-reason
   ;; chunked framing, for a streamed body whose length is not known up front (M2)
   #:encode-head-chunked #:encode-head-chunked-flat #:encode-chunk-header #:last-chunk
   #:to-hex #:body-forbidden?))
