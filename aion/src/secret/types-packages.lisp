;;;; types-packages.lisp --- aion/secret/types package.
;;;;
;;;; The typed view of AION/SECRET:SECRET, so a Coalton DEFINE-TYPE can hold a
;;;; credential in a field without that credential being a STRING the generated printer
;;;; will render. A SEPARATE, OPT-IN system for the same reason aion/csv/types is:
;;;; aion/secret above must stay Coalton-free so `cons` can load it.

(cl:defpackage #:aion/secret/types
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:s #:aion/secret))
  (:documentation
   "SECRET as a Coalton type: an opaque field type for credentials. MAKE-SECRET wraps,
    REVEAL unwraps, and a DEFINE-TYPE holding one prints it as #<SECRET REDACTED>.")
  (:export
   #:Secret
   #:make-secret
   #:reveal))
