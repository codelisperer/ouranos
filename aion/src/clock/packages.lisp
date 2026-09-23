;;;; packages.lisp --- the aion/clock package.

(cl:defpackage #:aion/clock
  (:use #:cl)
  (:local-nicknames (#:rnd #:aion/random))   ; 62 unpredictable bits per v6 id (#95)
  (:documentation
   "A monotonic Gregorian-100ns clock, and time-ordered v6 identities built on it.

    NEXT-VID returns a strictly-increasing 100-ns tick -- a locked counter that bumps by
    one within a coarse real-clock tick, so two calls never return the same value even
    under concurrent burst generation. NEW-ID mints an RFC-9562 v6 UUID whose embedded
    60-bit timestamp IS that tick, which is what makes the id sortable: v6 puts the
    timestamp most-significant, so lexical order is time order.

    This lives in aion because a monotonic clock is a floor primitive rather than a
    persistence concern -- `a v6 UUID can signify more than the identity of a database
    row'. Everything that wants one sits to aion's right in the DAG or, like hermes, may
    depend on aion and nothing else. It was extracted from mnemosyne/id (issue #96);
    mnemosyne keeps TOUCH! and the entity-stamping convention, which are about rows.

    Dependency-free on purpose: pure bit-work plus SBCL's own mutex and clock. frugal-uuid
    was not adopted because its default v6 does not carry this guarantee -- its timestamp
    field collides en masse -- and the guarantee is the entire point.

    Clocks are IO, so this is the CL shell and not Coalton.")
  (:export #:next-vid
           #:new-id
           #:vid->instant))
