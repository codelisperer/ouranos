;;;; packages.lisp --- aion/retry: retry policy as data, and a runner built on restarts (#79).

(cl:defpackage #:aion/retry
  (:use #:cl)
  (:local-nicknames (#:log #:aion/log))
  (:documentation
   "Bounded attempts with exponential backoff and jitter, for calls to services that fail for a
    while and then recover (#79).

    A RETRY-POLICY is plain data: how many attempts, the backoff schedule, the jitter, an
    optional deadline, and which conditions are worth another attempt. RETRY-DELAY is the
    schedule as a pure function, with the random value passed in. WITH-RETRY runs a body under a
    policy. Each attempt runs inside a RETRY restart, a RETRY-SCHEDULED condition is signalled
    before each wait so an outer handler can GIVE-UP or RETRY-NOW, and when the policy allows no
    more attempts the original condition propagates unchanged.

    Which conditions are transient is a protocol, TRANSIENCE, with a method per condition type
    written where the condition is defined: aion/http-client has the methods for HTTP-ERROR. A
    server's request to wait, such as an HTTP Retry-After header, is the protocol RETRY-AFTER.")
  (:export #:retry-policy #:make-retry-policy #:retry-policy-p
           #:retry-policy-name #:retry-policy-max-attempts #:retry-policy-base-delay
           #:retry-policy-multiplier #:retry-policy-max-delay #:retry-policy-jitter
           #:retry-policy-deadline #:retry-policy-retryable
           #:retry-delay
           #:with-retry #:call-with-retry
           #:retry #:retry-now #:give-up
           #:retry-scheduled #:retry-scheduled-condition #:retry-scheduled-attempt
           #:retry-scheduled-delay #:retry-scheduled-policy
           #:retry-would-block #:retry-would-block-reason
           #:transience #:transient-p #:transient-or-unknown-p
           #:retry-after #:parse-retry-after))
