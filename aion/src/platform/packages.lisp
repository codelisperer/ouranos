;;;; packages.lisp --- aion/platform: the platform key, in one place (pre-publication issue 206).
;;;;
;;;; THE CONTRACT HAS TWO HALVES AND ONLY ONE OF THEM WAS IN A LIBRARY. The build script
;;;; names the artifact; the update client looks it up. They must agree EXACTLY or no update
;;;; is ever delivered -- and a consuming app cannot load a build script, so it wrote a
;;;; second copy, with nothing comparing them.
;;;;
;;;; The failure is silent and permanent. A client that derives its own key naively computes
;;;; `windows-x64' against a manifest keyed `windows-x86-64', the lookup misses, and the
;;;; application reports itself UP TO DATE FOREVER. No error, no log line, and nobody
;;;; reports that something did not happen -- the app keeps working, it simply never updates
;;;; again, including past a security fix.
;;;;
;;;; NO DEPENDENCIES, deliberately: only UIOP, which arrives with ASDF. That is what lets the
;;;; build script load this before Quicklisp exists in its image, so the producer and the
;;;; consumer can share one implementation rather than one implementation and one copy.

(cl:defpackage #:aion/platform
  (:use #:common-lisp)
  (:documentation "The platform key that names a build artifact, and who may produce one.")
  (:export #:normalize-arch #:platform-key #:host-os-name
           #:*verified-platforms* #:verified-platform-p
           #:executable-directory #:macos-app-bundle))
