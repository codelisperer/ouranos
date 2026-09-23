;;;; packages.lisp --- aion/windows/registry.

(cl:defpackage #:aion/windows/registry
  (:use #:common-lisp)
  (:local-nicknames (#:w #:aion/windows))
  (:documentation "Reading one registry value, in a named bitness view (#319). Read-only by
design: see registry.lisp's header for why the view is a required argument and why this is
not a general registry API.")
  (:export
   #:registry-view
   #:key-default-value #:class-inproc-server #:prog-id-clsid
   #:+reg-sz+ #:+reg-expand-sz+))
