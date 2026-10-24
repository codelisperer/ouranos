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
;;;; Which places the checker searches for a pin by itself, so that a pin there with no entry fails
;;;; the gate, is listed in the header of scripts/check-upstream.lisp: *.pin files,
;;;; scripts/versions.env, and the workflows' actions, runner images and env versions, compose
;;;; images and scripts' image= lines (#749). A version anywhere else, such as an API version or a
;;;; default model id in Lisp source, has no fixed shape to search for. Its entry's :WHERE is its
;;;; only coverage, and a new one with no entry here goes unreported.
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
;;;;   :retires   optional: the date (YYYY-MM-DD) the upstream says it stops serving what this
;;;;              entry pins, such as a model's shutdown date. The offline check only checks the
;;;;              date's form. From that day on, --online lists the entry under "Past its
;;;;              shutdown date", so someone removes it on purpose; nothing removes it by itself.

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
;;;
;;; A dist move also moves dexador. aion/http-client's %DEX-HEADERS works around dexador's
;;; multipart handling on Linux and macOS (#828), and depends on how dexador-20260101's usocket
;;; backend checks a Content-Type for "multipart/"; the test MULTIPART-OCTETS-ARRIVE-AS-SENT in
;;; aion/tests/http-client.lisp fails if a new dexador checks it another way.

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

(:name "OpenAI default image model" :category :api
 :where ((:text "praxeon/src/image.lisp" "(defparameter *openai-image-model* \"" "\""))
 :upstream (:manual "https://developers.openai.com/api/docs/guides/image-generation")
 :reviewed "2026-10-18")

(:name "OpenAI Image API version" :category :api
 :where ((:text "praxeon/src/image.lisp" "(defparameter *openai-images-base-url* \"https://api.openai.com/" "\""))
 :upstream (:manual "https://developers.openai.com/api/docs/guides/image-generation")
 :reviewed "2026-10-18")

;;; Each row of praxeon/image's *OPENAI-IMAGE-PRICES*, in US dollars per million tokens, as the
;;; pricing page's "Image generation models" table (Standard) lists them. The value is the row's
;;; prices, so a change to any of them shows here. #758. A :retires date is the model's shutdown
;;; date from https://developers.openai.com/api/docs/deprecations, read on 2026-10-20; the row
;;; keeps pricing requests made before it, and --online reports it once the date has passed.

(:name "OpenAI image prices: gpt-image-2" :category :api
 :where ((:text "praxeon/src/image.lisp" "(\"gpt-image-2\" " ")"))
 :upstream (:manual "https://developers.openai.com/api/docs/pricing")
 :reviewed "2026-10-20")

(:name "OpenAI image prices: gpt-image-2.5-flare" :category :api
 :where ((:text "praxeon/src/image.lisp" "(\"gpt-image-2.5-flare\" " ")"))
 :upstream (:manual "https://developers.openai.com/api/docs/pricing")
 :reviewed "2026-10-20")

(:name "OpenAI image prices: gpt-image-2.5-sunburst" :category :api
 :where ((:text "praxeon/src/image.lisp" "(\"gpt-image-2.5-sunburst\" " ")"))
 :upstream (:manual "https://developers.openai.com/api/docs/pricing")
 :reviewed "2026-10-20")

(:name "OpenAI image prices: gpt-image-1.5" :category :api
 :where ((:text "praxeon/src/image.lisp" "(\"gpt-image-1.5\" " ")"))
 :upstream (:manual "https://developers.openai.com/api/docs/pricing")
 :reviewed "2026-10-20"
 :retires "2026-12-01")

(:name "OpenAI image prices: gpt-image-1-mini" :category :api
 :where ((:text "praxeon/src/image.lisp" "(\"gpt-image-1-mini\" " ")"))
 :upstream (:manual "https://developers.openai.com/api/docs/pricing")
 :reviewed "2026-10-20"
 :retires "2026-12-01")

(:name "OpenAI image prices: gpt-image-1" :category :api
 :where ((:text "praxeon/src/image.lisp" "(\"gpt-image-1\" " ")"))
 :upstream (:manual "https://developers.openai.com/api/docs/pricing")
 :reviewed "2026-10-20"
 :retires "2026-10-23")

(:name "OpenAI image prices: chatgpt-image-latest" :category :api
 :where ((:text "praxeon/src/image.lisp" "(\"chatgpt-image-latest\" " ")"))
 :upstream (:manual "https://developers.openai.com/api/docs/pricing")
 :reviewed "2026-10-20"
 :retires "2026-12-01")

;;; praxeon/image's Google provider (#758). Its prices are per million tokens, from the paid
;;; tier's Standard column on https://ai.google.dev/gemini-api/docs/pricing ("Last updated
;;; 2026-10-22"), read on 2026-10-23.

(:name "Google default image model" :category :api
 :where ((:text "praxeon/src/image-google.lisp" "(defparameter *google-image-model* \"" "\""))
 :upstream (:manual "https://ai.google.dev/gemini-api/docs/image-generation")
 :reviewed "2026-10-23")

(:name "Gemini API version" :category :api
 :where ((:text "praxeon/src/image-google.lisp" "(defparameter *google-images-base-url* \"https://generativelanguage.googleapis.com/" "\""))
 :upstream (:manual "https://ai.google.dev/gemini-api/docs/generate-content/image-generation")
 :reviewed "2026-10-23")

(:name "Google image prices: gemini-nano-banana-2.1" :category :api
 :where ((:text "praxeon/src/image-google.lisp" "(\"gemini-nano-banana-2.1\" " ")"))
 :upstream (:manual "https://ai.google.dev/gemini-api/docs/pricing")
 :reviewed "2026-10-23")

(:name "Google image prices: gemini-3.1-flash-image" :category :api
 :where ((:text "praxeon/src/image-google.lisp" "(\"gemini-3.1-flash-image\" " ")"))
 :upstream (:manual "https://ai.google.dev/gemini-api/docs/pricing")
 :reviewed "2026-10-23")

(:name "Google image prices: gemini-3.1-flash-lite-image" :category :api
 :where ((:text "praxeon/src/image-google.lisp" "(\"gemini-3.1-flash-lite-image\" " ")"))
 :upstream (:manual "https://ai.google.dev/gemini-api/docs/pricing")
 :reviewed "2026-10-23")

(:name "Google image prices: gemini-3-pro-image" :category :api
 :where ((:text "praxeon/src/image-google.lisp" "(\"gemini-3-pro-image\" " ")"))
 :upstream (:manual "https://ai.google.dev/gemini-api/docs/pricing")
 :reviewed "2026-10-23")

(:name "Twilio API version" :category :api
 :where ((:text "hermes/src/twilio.lisp" "https://api.twilio.com/" "/"))
 :upstream (:manual "https://www.twilio.com/docs/usage/api")
 :reviewed "2026-10-17")

(:name "SendGrid API version" :category :api
 :where ((:text "hermes/src/sendgrid.lisp" "https://api.sendgrid.com/" "/"))
 :upstream (:manual "https://www.twilio.com/docs/sendgrid/api-reference")
 :reviewed "2026-10-17")

(:name "Telegram Bot API" :category :api
 :where ((:text "hermes/src/telegram.lisp" "(defparameter +telegram-bot-api-version+ \"" "\""))
 :upstream (:manual "https://core.telegram.org/bots/api-changelog")
 :reviewed "2026-10-18")

(:name "Facebook Graph API" :category :api
 :where ((:text "hermes/src/facebook.lisp" "(defparameter +facebook-graph-api-version+ \"" "\""))
 :upstream (:manual "https://developers.facebook.com/docs/graph-api/changelog/versions/")
 :reviewed "2026-10-23")

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
 :where ((:text ".github/workflows/verify.yml" "- os: ubuntu-" nil)
         (:text ".github/workflows/verify.yml" "runs-on: ubuntu-" nil)
         (:text ".github/workflows/desktop-release.yml" "- os: ubuntu-" nil)
         (:text ".github/workflows/desktop-release.yml" "runs-on: ubuntu-" nil)
         (:text ".github/workflows/upstream.yml" "runs-on: ubuntu-" nil))
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
 :where ((:text ".github/workflows/verify.yml" "- os: windows-" nil)
         (:text ".github/workflows/desktop-release.yml" "- os: windows-" nil))
 :upstream (:manual "https://github.com/actions/runner-images")
 :reviewed "2026-10-17")

(:name "Windows on Arm runner image" :category :ci
 :where ((:text ".github/workflows/windows-arm64-probe.yml" "runs-on: windows-" nil))
 ;; Listed in actions/runner-images as "Windows 11 Arm64 ... windows-11-arm" (read 2026-10-23).
 ;; actions/partner-runner-images, which listed it before, is archived.
 :upstream (:manual "https://github.com/actions/runner-images")
 :reviewed "2026-10-23")

(:name "pgvector (Windows CI)" :category :ci
 :where ((:text ".github/workflows/verify.yml" "PGVECTOR_VERSION: \"" "\""))
 :upstream (:github-tag "pgvector/pgvector" "v"))

;; The commit the Windows leg checks out for PGVECTOR_VERSION's tag. It must be that tag's commit:
;; on 2026-10-23, v0.8.6 pointed at 8ee86c96f0fd72390f890aa8a336fda6d3ab4c6c, which is the pin.
;; Moving PGVECTOR_VERSION means moving this too, and reviewing it.
(:name "pgvector commit (Windows CI)" :category :ci
 :where ((:text ".github/workflows/verify.yml" "PGVECTOR_COMMIT: \"" "\""))
 :upstream (:manual "https://github.com/pgvector/pgvector/tags")
 :reviewed "2026-10-23")

;;; --- containers --------------------------------------------------------------------------

(:name "pgvector test image" :category :container
 :where ((:text "docker-compose.test.yml" "image: pgvector/pgvector:" "@"))
 :upstream (:docker "pgvector/pgvector"))

(:name "clean-machine base image" :category :container
 :where ((:text "scripts/verify-clean-machine.sh" "image=ubuntu:" nil))
 :upstream (:docker "library/ubuntu" ".04"))
