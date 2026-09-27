;;;; packages.lisp --- aion/http-client.

(cl:defpackage #:aion/http-client
  (:use #:cl)
  (:documentation
   "An interceptor-shaped HTTP client for one outbound call (pre-publication issue 202).

    ENTER stages build the request (auth, content type), a single dexador round-trip is the
    one effect at the edge, LEAVE stages process the response in reverse so the outermost
    stage wraps everything. The same shape as `aion/interceptor`, in CL rather than Coalton
    because the stages here are effectful by nature.

    It lives in aion for the reason `aion/interceptor` does (pre-publication issue 177): the shape is
    request-response, not web. It had already been reimplemented twice before it moved --
    once inside hermes as an internal, once as three raw `dex:post` calls in praxeon with
    hand-rolled error decoding -- which is the same evidence that settled where the
    interceptor pipeline belonged.

    WHAT CHANGED IN THE MOVE, and why it could not be verbatim: the original signalled
    hermes' DELIVERY-FAILURE, a *messaging* condition, from a general HTTP client. That
    vocabulary in its failure path is precisely what made it unreusable, so it signals
    HTTP-ERROR here and a messaging caller translates at its own boundary.

    REDIRECTS are dexador's, capped by the request's FOLLOW-REDIRECTS (NIL follows none). A
    URL a user supplied goes through FETCH-PUBLIC instead, which follows redirects itself and
    checks every hop's address (#295).

    NOT YET: retry. Re-running the effect is the hard part of an interceptor client, and it is
    a correctness question rather than a convenience -- a retried POST that creates a second
    charge is the failure mode -- so it is designed alongside idempotency keys rather than
    bolted on.")
  (:export #:request #:make-request #:request-p
           #:request-method #:request-url #:request-headers #:request-content
           #:request-connect-timeout #:request-read-timeout
           #:request-follow-redirects #:request-max-body-bytes
           #:request-connect-address #:request-ca-path
           #:response #:make-response #:response-p
           #:response-status #:response-headers #:response-body #:response-bytes
           #:responsep
           #:interceptor #:make-interceptor #:interceptor-name
           #:interceptor-enter #:interceptor-leave
           #:add-header #:ensure-2xx
           #:send-request #:header-value
           #:http-error #:http-error-status #:http-error-body #:http-error-label
           #:http-error-detail
           ;; fetching a URL a user supplied (#295)
           #:fetch-public #:*fetch-public-max-body-bytes*
           #:address-category #:parse-address #:address-string #:resolve-host
           #:response-too-large #:response-too-large-limit
           #:pinned-connect-unsupported
           #:fetch-refused #:fetch-refused-url #:fetch-refused-host #:fetch-refused-address
           #:fetch-refused-reason
           #:too-many-redirects #:too-many-redirects-url #:too-many-redirects-limit))
