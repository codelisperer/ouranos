;;;; upstream.sexp --- this app's own pinned versions, and where each one's newest release is
;;;; published. `cons outdated' checks it, as Ouranos checks its own (#716).
;;;;
;;;; Add an entry for each version this app pins that the framework does not: an external API's
;;;; version, a default model id, a native library, a CI action. One plist per entry, read with
;;;; *READ-EVAL* off:
;;;;
;;;;   (:name "Some API version" :category :api
;;;;    :where ((:text "src/client.lisp" "(defparameter +api-version+ \"" "\""))
;;;;    :upstream (:manual "https://example.com/changelog")
;;;;    :reviewed "2026-11-24")
;;;;
;;;; The fields and the kinds of :where and :upstream are documented at the top of the Ouranos
;;;; tree's own upstream.sexp. Until an entry is added, `cons outdated' notes that this file lists
;;;; nothing and checks nothing of the app's own.
