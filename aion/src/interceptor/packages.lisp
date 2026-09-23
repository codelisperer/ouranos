;;;; packages.lisp --- aion/interceptor.

(cl:defpackage #:aion/interceptor
  (:use #:coalton #:coalton-prelude)
  (:documentation
   "A typed, Pedestal-style interceptor pipeline in Coalton. An Interceptor is a named
    pair of stage functions over a context :c (enter forward, leave in reverse); execute
    runs a chain, short-circuiting on Halt/Failure via the Flow ADT.

    Lives in aion, not in a framework, because the shape is not a web shape: it is
    request-response, and any such protocol can use it. The tree had already discovered
    that twice over before this moved -- hyperion for inbound HTTP, hermes for outbound
    calls (hand-rolled in CL), and praxeon for agent turns. Three call sites at three
    positions in the DAG, only one of which is a web layer.")
  (:export #:Flow #:Proceed #:Halt #:Failure #:flow-context
           #:Interceptor #:on-enter #:on-leave
           #:name #:enter-of #:leave-of #:execute #:execute-effect))
