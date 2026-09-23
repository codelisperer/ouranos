;;;; packages.lisp --- aion/secret package.
;;;;
;;;; A credential that cannot be printed by accident. A password, API key or token
;;;; held as a bare STRING inside any slot-printing aggregate -- a CL DEFSTRUCT, or a
;;;; Coalton DEFINE-TYPE, whose generated printer renders every field -- lands in
;;;; plaintext in a backtrace the first time anything unwinds through a frame holding
;;;; it. That is how a production database password reached a deploy log (#209).
;;;;
;;;; No Coalton dependency here on purpose, for the same reason as aion/csv: this must
;;;; be loadable by `cons`, whose core stays Coalton-free and trivial to install. The
;;;; typed view of the same struct is the opt-in `aion/secret/types`.

(cl:defpackage #:aion/secret
  (:use #:cl)
  (:documentation
   "An opaque wrapper for a credential. MAKE-SECRET takes plaintext in; REVEAL is the
    only way out. Printing -- ~S, ~A, a backtrace frame, a nested struct -- yields
    #<SECRET REDACTED> and never the value.")
  (:export
   #:secret
   #:secretp
   #:make-secret
   #:reveal))
