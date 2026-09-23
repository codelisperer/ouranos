;;;; packages.lisp --- aion/signature: Ed25519 over bytes, and nothing else.
;;;;
;;;; THREE CONSUMERS, THREE POINTS IN THE DAG, NO NATURAL OWNER (#208). praxeon's spend
;;;; ceiling verifies signed grants; the desktop updater must verify a release artifact
;;;; before applying it; marketplace items may travel between users later. Same primitive
;;;; each time -- verify a detached signature over bytes -- with a different envelope around
;;;; it. praxeon cannot own it (the build scripts are not to its right) and hermes cannot
;;;; (two of the three consumers are outside it), so it lives leftmost, where everything can
;;;; reach it.
;;;;
;;;; THE NARROWNESS IS THE DESIGN, NOT A FIRST CUT. Key management, key rotation, trust
;;;; policy and where a key lives are deliberately absent, because they differ per consumer
;;;; in ways that matter: the updater's key ships inside the bundle and is exactly as
;;;; trusted as the installer that placed it, while praxeon's is configuration supplied by
;;;; the application minting grants. A shared module with an opinion about trust would be
;;;; wrong for at least one of them.
;;;;
;;;; And the general hazard, which is the reason to keep saying no: a crypto helper that
;;;; over-generalises grows options, and OPTIONS IN A VERIFICATION PATH ARE WHERE MISTAKES
;;;; HIDE. Each consumer owns its envelope and its trust decision. This owns the primitive.
;;;;
;;;; No new dependency: ironclad is already the tree's crypto library in four places.

(cl:defpackage #:aion/signature
  (:use #:common-lisp)
  (:documentation "Ed25519 detached signatures over byte vectors.")
  (:export
   ;; keys
   #:public-key #:private-key #:public-key-p #:private-key-p
   #:generate-key-pair #:public-key-of
   #:public-key-bytes #:private-key-bytes
   #:public-key-from-bytes #:private-key-from-bytes
   #:encode-key #:decode-public-key #:decode-private-key
   ;; the primitive
   #:sign #:verify
   #:+signature-length+ #:+key-length+
   ;; conditions
   #:signature-error #:malformed-key #:malformed-key-detail))
