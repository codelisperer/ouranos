;;;; types.lisp --- the typed core of aion/uv/net, in Coalton.
;;;;
;;;; Pure, like its sibling in aion/uv: numbers in, meanings out, no IO. Three decodings
;;;; live here, and they were chosen because each is a place where an untyped value is
;;;; ordinarily read wrong.
;;;;
;;;; 1. `nread`, THE MOST OVERLOADED NUMBER IN LIBUV. One signed integer delivered to
;;;;    every read callback, meaning four different things:
;;;;      n > 0        this many bytes are in the buffer
;;;;      n == 0       nothing was read, and that is NOT an error (the EAGAIN case)
;;;;      n == UV_EOF  the peer is finished; an ordinary, expected end
;;;;      n < 0 else   a real failure
;;;;    The classic bug is treating end-of-stream as a failure, because both are
;;;;    negative. A type makes the four cases unmergeable, and dispatch is on libuv's
;;;;    error NAME ("EOF") rather than its number, for the same reason the rest of the
;;;;    binding does: the numbers are platform errnos, the names are libuv's.
;;;;
;;;; 2. THE BACKPRESSURE DECISION. It is a pure function of two integers -- how much is
;;;;    queued, and how much is too much -- which is precisely why it is worth extracting
;;;;    rather than inlining as a comparison at each call site. Node left this advisory
;;;;    and rewrote its stream layer twice; the decision being a named, tested value is
;;;;    the difference between a policy and a habit.
;;;;
;;;; 3. WHICH ADDRESS FAMILY A LITERAL IS. Load-bearing rather than decorative: it picks
;;;;    uv_ip4_addr or uv_ip6_addr, and getting it wrong is a failed bind with a
;;;;    confusing message.

(cl:in-package #:aion/uv/net/types)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- what a read callback was actually told ---------------------------------

  (define-type ReadOutcome
    "What libuv's `nread` means, with the four cases kept apart."
    (Bytes Integer)
    NothingYet
    EndOfStream
    (ReadFailed String))

  (declare decode-read (Integer * String -> ReadOutcome))
  (define (decode-read nread name)
    "Decode a read callback's NREAD, with NAME being uv_err_name(nread) when it is
negative. The EAGAIN case (zero) is deliberately not an error and not an end: libuv
means 'nothing this time', and a caller that treats it as either will drop a
connection that is perfectly healthy."
    (cond
      ((> nread 0) (Bytes nread))
      ((== nread 0) NothingYet)
      ((== name "EOF") EndOfStream)
      (True (ReadFailed name))))

  (declare read-outcome->string (ReadOutcome -> String))
  (define (read-outcome->string o)
    (match o
      ((Bytes _) "bytes")
      ((NothingYet) "nothing-yet")
      ((EndOfStream) "end-of-stream")
      ((ReadFailed name) name)))

  (declare read-outcome-tag (Integer * String -> String))
  (define (read-outcome-tag nread name)
    "The CL-callable form: the two raw values in, the case name out. The byte count is
already in the caller's hands, so the tag is all the shell needs to branch on."
    (read-outcome->string (decode-read nread name)))

  ;;; --- whether the writer is keeping up ----------------------------------------

  (define-type FlowState
    "Whether a stream's write queue is within its budget."
    Flowing
    Saturated)

  (declare flow-state (Integer * Integer -> FlowState))
  (define (flow-state queued high-water)
    "Saturated once QUEUED reaches HIGH-WATER. At that point a producer must be paused,
not merely advised to slow down."
    (if (>= queued high-water) Saturated Flowing))

  (declare flow-state->string (FlowState -> String))
  (define (flow-state->string s)
    (match s
      ((Flowing) "flowing")
      ((Saturated) "saturated")))

  (declare saturated? (Integer * Integer -> Boolean))
  (define (saturated? queued high-water)
    "CL-callable: has the write queue reached the point where the producer must stop?"
    (match (flow-state queued high-water)
      ((Saturated) True)
      ((Flowing) False)))

  (declare drained? (Integer * Integer -> Boolean))
  (define (drained? queued low-water)
    "CL-callable: has the queue fallen far enough to restart a paused producer?

A separate, LOWER threshold on purpose. Resuming at the same level the producer was
paused at makes it pause again on the next write, so the pair oscillates and every
resume costs a syscall. The gap between the two marks is what makes it settle."
    (<= queued low-water))

  ;;; --- which family an address literal belongs to -------------------------------

  (define-type AddressFamily
    "The two families libuv can turn a literal into a sockaddr for."
    IPv4
    IPv6)

  (declare address-family (String -> AddressFamily))
  (define (address-family literal)
    "Classify an address literal. A colon can only appear in an IPv6 literal, never in
a dotted-quad, so this is exact rather than heuristic -- for LITERALS. A host NAME is
neither, and is not this function's business: names go through DNS first."
    (if (str:substring? ":" literal) IPv6 IPv4))

  (declare address-family->string (AddressFamily -> String))
  (define (address-family->string f)
    (match f
      ((IPv4) "ipv4")
      ((IPv6) "ipv6")))

  (declare address-family-name (String -> String))
  (define (address-family-name literal)
    "CL-callable: literal in, family name out."
    (address-family->string (address-family literal)))

  (declare ipv6-literal? (String -> Boolean))
  (define (ipv6-literal? literal)
    "CL-callable: the single bit the shell needs in order to pick uv_ip6_addr."
    (match (address-family literal)
      ((IPv6) True)
      ((IPv4) False))))
