;;;; template.lisp --- the `web` template manifest.

;;;; The server is here, not implied by hyperion: the framework declares no HTTP server
;;;; (pre-publication issue 139), so an app that names none compiles and then fails at SRV:START with
;;;; NO-SERVER-BACKEND. hyperion/server-uv, the native server on libuv, because desktop apps
;;;; run on it on every platform (ADR-0017, #472), and a scaffolded app should start on the
;;;; server it will ship on. It needs a built libuv: the tree's scripts/build-libuv.lisp, or a
;;;; system libuv. The generated README says so. Woo and Hunchentoot remain an app's choice.

(:name :WEB
 :description "A minimal, runnable Hyperion web app."
 :target-kind :WEB
 :dependencies ("cons/env" "hyperion" "spinneret" "hyperion/server-uv"))
