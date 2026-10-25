;;;; template.lisp --- the `web` template manifest.

;;;; The server is here, not implied by hyperion: the framework declares no HTTP server
;;;; (pre-publication issue 139), so an app that names none compiles and then fails at SRV:START with
;;;; NO-SERVER-BACKEND. hyperion/server-uv, the native server on libuv, because desktop apps
;;;; run on it on every platform (ADR-0017, #472), and a scaffolded app should start on the
;;;; server it will ship on. It needs a built libuv: the tree's scripts/build-libuv.lisp, or a
;;;; system libuv. The generated README says so. Woo and Hunchentoot remain an app's choice.
;;;; aion/uv is named too, because the app's START asks hyperion/server:DEFAULT-SERVER, which
;;;; skips :uv with a reason when libuv does not load, and logs that reason with aion/log (#711).

(:name :WEB
 :description "A minimal, runnable Hyperion web app."
 :target-kind :WEB
 :dependencies ("cons/env" "hyperion" "spinneret" "hyperion/server-uv" "aion/uv" "aion/log")
 ;; `cons init NAME --template web --db sqlite|postgres` (#711): one mnemosyne pool from
 ;; DATABASE_URL, given to the session store, the user store and WRAP-CONNECTION. The files
 ;; under options/db/ are added to files/, and replace the files there at the same path.
 :options ((:db
            (:sqlite
             :dependencies ("mnemosyne" "hyperion/db-connection" "hyperion/session-db"
                            "hyperion/auth-db")
             :files "options/db/"
             :markers (("{{db-dialect}}" . ":sqlite")
                       ("{{db-default-url}}" . "\"sqlite://data/{{name}}.db\"")
                       ("{{db-env-line}}" . "DATABASE_URL=sqlite://data/{{name}}.db")))
            (:postgres
             :dependencies ("mnemosyne" "hyperion/db-connection" "hyperion/session-db"
                            "hyperion/auth-db")
             :files "options/db/"
             :markers (("{{db-dialect}}" . ":postgres")
                       ("{{db-default-url}}" . "nil")
                       ("{{db-env-line}}" . "# DATABASE_URL=postgres://user:REPLACE_ME@localhost:5432/{{name}}"))))))
