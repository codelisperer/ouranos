;;;; reduced.lisp --- early-termination sentinel for reducing functions.
;;;;
;;;; A tiny stand-in for Clojure's `reduced`. `fold-rows` (and, later, aion/xform's
;;;; `transduce`) treat a reducing function `(acc row) -> acc` as the unit of
;;;; composition; wrapping the accumulator in REDUCED signals "stop now, this is
;;;; the answer." Kept here so aion/xform can share the exact same protocol when
;;;; it lands -- CSV is its first real customer.

(in-package #:aion/csv)

(defstruct (reduced (:constructor reduced (value)) (:copier nil))
  "Wrapper marking a reduction result as final. Return `(reduced x)` from a
reducing function to stop iteration early with value X."
  value)

(declaim (inline unreduce ensure-reduced))

;; REDUCED-P is the predicate DEFSTRUCT already generated above -- it is exactly
;; `(typep x 'reduced)`. Redefining it here clobbered the structure predicate, which
;; SBCL reports as a full WARNING and ASDF escalates to a build failure. It went
;; unnoticed because `ql:quickload` does not escalate; a plain `asdf:load-system`
;; refuses to build. See docs/coalton-patterns.md 8a.

(defun unreduce (x)
  "Unwrap X if it is REDUCED, else return X unchanged."
  (if (reduced-p x) (reduced-value x) x))

(defun ensure-reduced (x)
  "Wrap X in REDUCED unless it already is one (idempotent)."
  (if (reduced-p x) x (reduced x)))
