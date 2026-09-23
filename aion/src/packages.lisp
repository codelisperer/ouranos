;;;; packages.lisp --- Aion package definitions.
;;;;
;;;; Package-per-module; :local-nicknames over long prefixes. As the library
;;;; grows, expect packages like:
;;;;   aion/seq       -- a consistent sequence/collection protocol (the "ISeq for CL")
;;;;   aion/set       -- persistent hash-set / ordered-set (Coalton lacks sets)
;;;;   aion/xform     -- transducers
;;;;   aion/optics    -- lenses / prisms / traversals
;;;;   aion/lazy      -- memoized lazy sequences
;;;;   aion/thread    -- threading macros (-> ->> some-> cond->)
;;;;   aion/cl        -- the pure-CL face (exposes the above to non-Coalton users)
;;;; Much of the persistent-collection substrate already exists in Coalton
;;;; (Seq/hashmap/ordmap) -- see docs/coalton-gap-analysis.md.

(cl:defpackage #:aion
  (:use #:cl)
  (:documentation "Aion: a Coalton-first functional standard library for Common Lisp.")
  (:export #:version))
