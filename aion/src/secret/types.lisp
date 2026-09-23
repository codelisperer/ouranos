;;;; types.lisp --- SECRET as an opaque Coalton type.
;;;;
;;;; `repr :native' rather than a DEFINE-TYPE wrapping a String, and this is the whole
;;;; point: a native type IS the CL struct, so the redacting printer travels with the
;;;; value into any Coalton aggregate that holds it, in either compilation mode. A
;;;; Coalton-side wrapper would be a DEFINE-TYPE like any other -- printed field by
;;;; field, with the String inside rendered in full, which is the bug (#209).
;;;;
;;;; The `lisp' blocks here traffic only in a native type and String, both promised
;;;; representations, so they respect the §7 rule rather than sidestepping it.

(in-package #:aion/secret/types)

(coalton-toplevel
  (repr :native s:secret)
  (define-type Secret
    "An opaque credential. A field of this type prints as #<SECRET REDACTED> wherever the
value holding it is printed.")

  (declare make-secret (String -> Secret))
  (define (make-secret plaintext)
    "Wrap PLAINTEXT. The one-way valve's inlet: credentials arrive as strings from an
environment variable or a URL, so taking a String here is unavoidable -- what matters is
that getting one back out is the named, greppable act below."
    (lisp (-> Secret) (plaintext) (s:make-secret plaintext)))

  (declare reveal (Secret -> String))
  (define (reveal x)
    "The plaintext inside X -- the disclosure point. See aion/src/secret/secret.lisp."
    (lisp (-> String) (x) (s:reveal x))))
