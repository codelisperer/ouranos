;;;; upstream.sexp --- every pinned version of an external dependency or API, and where its
;;;; latest release is published (#716).
;;;;
;;;; An entry says WHERE a version is written, not what it is: `scripts/check-upstream.lisp'
;;;; reads the value out of the file that holds it, so this file cannot disagree with a pin.
;;;; The checker fails the gate when a pin in the tree has no entry here, when an entry's
;;;; WHERE no longer finds its pin, or when two places an entry names disagree. With
;;;; `--online' it compares each pin with its upstream release (the second step of #716).
;;;;
;;;; Read with *READ-EVAL* off. Each entry is a plist:
;;;;
;;;;   :name      a string, unique in this file
;;;;   :category  :toolchain :quicklisp :native :asset :api :ci :container
;;;;   :where     a list of places the pinned value is written; every one must give the same
;;;;              value. A place is one of
;;;;                (:env FILE KEY)            the value of KEY=value in FILE
;;;;                (:field FILE NAME)         the second word of the line whose first word
;;;;                                           is NAME, in a .pin-style file
;;;;                (:text FILE BEFORE AFTER)  the text after each occurrence of BEFORE, up
;;;;                                           to AFTER, or to the end of the line when AFTER
;;;;                                           is NIL; every occurrence must agree
;;;;                (:concat SEPARATOR PLACE...) the values of the PLACEs joined by SEPARATOR
;;;;   :upstream  where the latest release is published:
;;;;                (:github-release "owner/repo") (:github-commit "owner/repo")
;;;;                (:github-tag "owner/repo" "prefix") (:npm "package") (:nuget "package")
;;;;                (:quicklisp-dist) (:docker "image" [suffix]) (:manual "url")
;;;;              A :github-tag considers only tags starting with prefix that carry a version
;;;;              number. A :docker entry considers only tags shaped like the pin, and, with a
;;;;              suffix, only those ending in it (".04" for Ubuntu's long-term releases).
;;;;   :reviewed  for :manual entries only: the date (YYYY-MM-DD) somebody last read the URL,
;;;;              or :never
;;;;   :held      optional: (:reason "why this pin is not on the latest release" :issue N)

;;; --- toolchain ---------------------------------------------------------------------------

(:name "SBCL" :category :toolchain
 :where ((:env "scripts/versions.env" "SBCL_VERSION"))
 :upstream (:github-tag "sbcl/sbcl" "sbcl-"))

(:name "Coalton" :category :toolchain
 :where ((:field "coalton.pin" "sha"))
 :upstream (:github-commit "coalton-lang/coalton"))

(:name "appimagetool" :category :toolchain
 :where ((:env "scripts/versions.env" "APPIMAGETOOL_VERSION"))
 :upstream (:github-tag "AppImage/appimagetool" ""))

(:name "WebView2 SDK" :category :toolchain
 :where ((:env "scripts/versions.env" "WEBVIEW2_SDK_VERSION"))
 :upstream (:nuget "Microsoft.Web.WebView2"))

;;; --- Quicklisp ---------------------------------------------------------------------------

(:name "Quicklisp dist" :category :quicklisp
 :where ((:env "scripts/versions.env" "QUICKLISP_DIST"))
 :upstream (:quicklisp-dist)
 :held (:reason "aion/src/http-client/openssl.lisp patches cl+ssl for OpenSSL 4 until a dist includes cl-plus-ssl PR 202; a dist move is checked against that patch"
        :issue 706))

;;; --- native libraries --------------------------------------------------------------------

(:name "libuv" :category :native
 :where ((:field "libuv.pin" "version")
         (:text "libuv.pin" "url     https://dist.libuv.org/dist/v" "/"))
 :upstream (:github-release "libuv/libuv"))

(:name "mbedTLS" :category :native
 :where ((:field "mbedtls.pin" "version"))
 :upstream (:github-release "Mbed-TLS/mbedtls"))

(:name "libgit2" :category :native
 :where ((:field "libgit2.pin" "version"))
 :upstream (:github-release "libgit2/libgit2"))

(:name "SQLite (Windows)" :category :native
 :where ((:env "scripts/versions.env" "SQLITE_VERSION"))
 :upstream (:manual "https://sqlite.org/download.html")
 :reviewed "2026-10-17")

(:name "webview (hyperion-view)" :category :native
 :where ((:concat "."
                  (:text "hyperion/hyperion-view/webview.h" "#define WEBVIEW_VERSION_MAJOR " nil)
                  (:text "hyperion/hyperion-view/webview.h" "#define WEBVIEW_VERSION_MINOR " nil)
                  (:text "hyperion/hyperion-view/webview.h" "#define WEBVIEW_VERSION_PATCH " nil))
         (:text "hyperion/hyperion-view/README.md" "webview/webview **v" "**"))
 :upstream (:github-tag "webview/webview" ""))

(:name "CLDR plural rules" :category :native
 :where ((:field "hyperion/src/vendor/PLURALS.pin" "version")
         (:text "scripts/fetch-cldr-plurals.lisp" "(defparameter *cldr-version* \"" "\""))
 :upstream (:github-release "unicode-org/cldr-json"))

;;; --- vendored browser assets -------------------------------------------------------------

(:name "htmx" :category :asset
 :where ((:field "hyperion/assets/vendor/ASSETS.pin" "htmx")
         (:text "hyperion/src/assets.lisp" "(%asset :key :htmx :version \"" "\""))
 :upstream (:npm "htmx.org"))

(:name "Alpine.js" :category :asset
 :where ((:field "hyperion/assets/vendor/ASSETS.pin" "alpinejs")
         (:text "hyperion/src/assets.lisp" "(%asset :key :alpine :version \"" "\""))
 :upstream (:npm "alpinejs"))

(:name "Bulma" :category :asset
 :where ((:field "hyperion/assets/vendor/ASSETS.pin" "bulma")
         (:text "hyperion/src/assets.lisp" "(%asset :key :bulma :version \"" "\""))
 :upstream (:npm "bulma"))

;;; --- external APIs -----------------------------------------------------------------------

(:name "Anthropic API version" :category :api
 :where ((:text "praxeon/src/llm.lisp" "(version :initarg :version :initform \"" "\""))
 :upstream (:manual "https://platform.claude.com/docs/en/api/versioning")
 :reviewed "2026-10-17")

(:name "Anthropic default model" :category :api
 :where ((:text "praxeon/src/llm.lisp" "(defparameter *default-model* \"" "\""))
 :upstream (:manual "https://platform.claude.com/docs/en/models/overview")
 :reviewed "2026-10-17")

(:name "MCP protocol revision" :category :api
 :where ((:text "praxeon/src/mcp/client.lisp" "(defparameter +protocol-version+ \"" "\""))
 :upstream (:manual "https://modelcontextprotocol.io/specification")
 :reviewed "2026-10-03")

(:name "Voyage default embedding model" :category :api
 :where ((:text "praxeon/src/embedding.lisp" "((model :initform \"" "\""))
 :upstream (:manual "https://docs.voyageai.com/docs/embeddings")
 :reviewed "2026-10-17")

(:name "OpenAI-compatible default embedding model" :category :api
 :where ((:text "praxeon/src/embedding.lisp" "(%getenv \"PRAXEON_EMBED_MODEL\") \"" "\""))
 :upstream (:manual "https://developers.openai.com/api/docs/models")
 :reviewed "2026-10-17")

(:name "Twilio API version" :category :api
 :where ((:text "hermes/src/twilio.lisp" "https://api.twilio.com/" "/"))
 :upstream (:manual "https://www.twilio.com/docs/usage/api")
 :reviewed "2026-10-17")

(:name "SendGrid API version" :category :api
 :where ((:text "hermes/src/sendgrid.lisp" "https://api.sendgrid.com/" "/"))
 :upstream (:manual "https://www.twilio.com/docs/sendgrid/api-reference")
 :reviewed "2026-10-17")

(:name "Stripe API version" :category :api
 :where ((:text "hermes/src/payments/stripe.lisp" "(defparameter +stripe-api-version+ \"" "\""))
 :upstream (:manual "https://docs.stripe.com/upgrades")
 :reviewed "2026-10-18")

;;; --- CI ----------------------------------------------------------------------------------

(:name "actions/checkout" :category :ci
 :where ((:text ".github/workflows/verify.yml" "uses: actions/checkout@" nil)
         (:text ".github/workflows/desktop-release.yml" "uses: actions/checkout@" nil)
         (:text ".github/workflows/windows-arm64-probe.yml" "uses: actions/checkout@" nil)
         (:text ".github/workflows/upstream.yml" "uses: actions/checkout@" nil))
 :upstream (:github-release "actions/checkout"))

(:name "actions/cache" :category :ci
 :where ((:text ".github/workflows/verify.yml" "uses: actions/cache@" nil)
         (:text ".github/workflows/desktop-release.yml" "uses: actions/cache@" nil)
         (:text ".github/workflows/windows-arm64-probe.yml" "uses: actions/cache@" nil)
         (:text ".github/workflows/upstream.yml" "uses: actions/cache@" nil))
 :upstream (:github-release "actions/cache"))

(:name "actions/upload-artifact" :category :ci
 :where ((:text ".github/workflows/desktop-release.yml" "uses: actions/upload-artifact@" nil)
         (:text ".github/workflows/windows-arm64-probe.yml" "uses: actions/upload-artifact@" nil))
 :upstream (:github-release "actions/upload-artifact"))

(:name "actions/download-artifact" :category :ci
 :where ((:text ".github/workflows/desktop-release.yml" "uses: actions/download-artifact@" nil))
 :upstream (:github-release "actions/download-artifact"))

(:name "Linux runner image" :category :ci
 :where ((:text ".github/workflows/verify.yml" "- os: ubuntu-" nil))
 :upstream (:manual "https://github.com/actions/runner-images")
 :reviewed "2026-10-17")

(:name "macOS runner image" :category :ci
 :where ((:text ".github/workflows/verify.yml" "- os: macos-" nil))
 :upstream (:manual "https://github.com/actions/runner-images")
 :reviewed "2026-10-18")

(:name "macOS desktop build image" :category :ci
 :where ((:text ".github/workflows/desktop-release.yml" "- os: macos-" nil))
 :upstream (:manual "https://github.com/actions/runner-images")
 :reviewed "2026-10-18"
 :held (:reason "the macOS app needs the macOS of its build image or later, because Homebrew's sbcl and libzstd in the bundle target it; the maintainer chose macos-15 so the app runs on macOS 15, while verify.yml tests on macos-26"
        :issue 763))

(:name "Windows runner image" :category :ci
 :where ((:text ".github/workflows/verify.yml" "- os: windows-" nil))
 :upstream (:manual "https://github.com/actions/runner-images")
 :reviewed "2026-10-17")

(:name "pgvector (Windows CI)" :category :ci
 :where ((:text ".github/workflows/verify.yml" "PGVECTOR_VERSION: \"" "\""))
 :upstream (:github-tag "pgvector/pgvector" "v"))

;;; --- containers --------------------------------------------------------------------------

(:name "pgvector test image" :category :container
 :where ((:text "docker-compose.test.yml" "image: pgvector/pgvector:" "@"))
 :upstream (:docker "pgvector/pgvector"))

(:name "clean-machine base image" :category :container
 :where ((:text "scripts/verify-clean-machine.sh" "image=ubuntu:" nil))
 :upstream (:docker "library/ubuntu" ".04"))
