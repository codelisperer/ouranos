;;;; packages.lisp --- klio package definitions.

(cl:defpackage #:klio
  (:use #:cl)
  (:local-nicknames (#:spin #:spinneret))
  (:documentation "klio -- a git-backed content engine for hyperion sites.

A LIBRARY, not an application. A site instantiates it with a theme, a content directory and
a config; klio owns loading, rendering, feeds, search and hot reload. The site owns its
server, its port, its .env and its MAIN -- which is why nothing here starts anything.")
  (:export #:version
           ;; visibility -- request-time scheduling
           #:visibility #:visible-p
           ;; front-matter -- splitting only; what the keys mean is #359 Q1
           #:split-front-matter #:parse-front-matter #:parse-front-matter-data
           #:unterminated-front-matter #:unsupported-front-matter
           #:content-meta #:content-meta-title #:content-meta-date #:content-meta-slug
           #:content-meta-tags #:content-meta-draft #:content-meta-publish-at
           #:content-meta-extra #:content-meta-warnings #:extra #:+core-keys+
           ;; search -- tokenised, field-weighted, built at load
           #:tokenize #:make-search-index #:index-document #:search-index-query
           #:*field-weights*
           ;; rendering -- one path into 3bmd, via hyperion/markdown
           #:render-markdown
           ;; highlighting -- a small CL highlighter, at load time (#359 Q3)
           #:highlight-lisp #:highlight-code-blocks
           #:*lisp-languages* #:*highlight-classes*
           ;; dev mode -- preview is a flag, not a URL
           #:*dev-mode* #:dev-mode-p #:with-dev-mode #:readable-p
           ;; content -- loading a tree, and publishing it all at once (ADR-0001)
           #:document #:document-key #:document-path #:document-slug #:document-meta
           #:document-body #:document-html
           #:content-tree #:content-tree-source #:content-tree-loaded-at
           #:content-tree-warnings #:content-tree-index
           #:load-failure #:load-failure-file #:load-failure-reason
           #:content-load-failed #:content-load-failed-failures
           #:content-load-failed-source #:content-load-failed-phase
           #:content-files #:load-document #:load-tree
           #:tree-document #:tree-documents #:tree-readable-documents
           #:site #:make-site #:site-directory #:site-tree #:site-known-extra
           #:publish #:boot #:reload #:reload-or-fail
           #:*content-extension*
           ;; serving -- the tree as a hyperion application; the look is the site's
           #:site-app #:default-page-theme #:default-index-theme #:default-not-found))
