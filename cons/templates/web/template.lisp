;;;; template.lisp --- the `web` template manifest.

;;;; The Clack handler is here, not implied by hyperion: the framework declares no HTTP
;;;; server (pre-publication issue 139), so an app that names none compiles and then fails at SRV:START with
;;;; NO-SERVER-BACKEND. Hunchentoot because a scaffolded app must run on all three
;;;; platforms with nothing to install -- Woo is a deliberate opt-in, not a default.

(:name :WEB
 :description "A minimal, runnable Hyperion web app."
 :target-kind :WEB
 :dependencies ("cons/env" "hyperion" "spinneret" "clack-handler-hunchentoot"))
