;;;; serve.lisp --- a content tree as a hyperion application.
;;;;
;;;; WHERE THE ENGINE STOPS AND THE SITE STARTS, which is the only interesting decision in
;;;; this file. klio owns the URL-to-document mapping, visibility, the 404, and the guarantee
;;;; that one request sees one tree. The SITE owns what a page looks like: its layout, its
;;;; wordmark, its navigation, how it words a date, which documents it puts on its front page.
;;;; None of that is content-engine work, and a default theme that grew those things would be
;;;; a site nobody chose, shipped inside the library.
;;;;
;;;; So a theme here is a FUNCTION -- (site document) -> an HTML string -- and the defaults
;;;; are deliberately plain: a valid, readable page with nothing branded on it, so that a new
;;;; site serves its content on the first day and replaces the look on the second.
;;;;
;;;; THE TREE IS READ ONCE PER REQUEST, at the top of the handler, and passed down. That is
;;;; the consuming half of ADR-0001's atomicity guarantee: publishing is one SETF of one slot,
;;;; so a request that reads the slot once holds a consistent snapshot even if a reload
;;;; publishes underneath it. A handler that read (SITE-TREE SITE) twice -- once to find the
;;;; document and once to render the index beside it -- could show two different trees on one
;;;; page, which is the mixture the ADR exists to prevent, reintroduced below the level it
;;;; was decided at.

(cl:in-package #:klio)

;;; --- themes ------------------------------------------------------------------

(defun %page-html (title body-html)
  "A minimal, valid HTML document: the least a browser needs and nothing a site would want
to keep."
  (spin:with-html-string
    (:doctype)
    (:html :lang "en"
           (:head (:meta :charset "utf-8")
                  (:meta :name "viewport" :content "width=device-width, initial-scale=1")
                  (:title (or title "")))
           (:body (:main (:raw body-html))))))

(defun default-page-theme (site document)
  "The default look of one document: its rendered markdown, in a bare page.

RAW, and that is safe because it is the only place it can be: HYPERION/MARKDOWN escapes HTML
in content by default (a site that trusts its authors opts in), so what arrives here has
already been through that policy. Escaping it again would print the tags."
  (declare (ignore site))
  (%page-html (content-meta-title (document-meta document))
              (document-html document)))

(defun default-index-theme (site documents)
  "The default front page: every readable document, by title, in tree order.

A LIST OF LINKS IS NOT A FRONT PAGE and is not meant to be one. It is what a site has before
it has decided, and it is honest about that: no wordmark, no tagline, no copy the engine
invented on the site's behalf."
  (declare (ignore site))
  (%page-html
   "Contents"
   (spin:with-html-string
     (:ul
      (dolist (d documents)
        (:li (:a :href (format nil "/~A" (document-key d))
                 (or (content-meta-title (document-meta d)) (document-key d)))))))))

(defun default-not-found (site key)
  "The default 404 body. KEY is what was asked for."
  (declare (ignore site))
  (%page-html "Not found"
              (spin:with-html-string (:p "No such page: " (:code (or key ""))))))

;;; --- responses ---------------------------------------------------------------

(defparameter +html-headers+ '(:content-type "text/html; charset=utf-8")
  "The one content type this file serves. A content engine that answered several would be
guessing at what a document is from its extension, and every document here is markdown.")

(defun %html-response (status html)
  (list status +html-headers+ (list html)))

(defun %request-key (env)
  "The document key a request asks for: the path without its leading slash.

A key and a path differ by exactly that slash, so this is the whole of the URL-to-document
mapping. Nothing is decoded, rewritten or guessed at -- a request for a key that does not
exist is a 404, not an approximate match, because a content engine that serves a page the
author did not write is worse than one that says it has none."
  (let ((path (or (getf env :path-info) "/")))
    (string-left-trim "/" path)))

;;; --- the application ---------------------------------------------------------

(defun site-app (site &key (page-theme #'default-page-theme)
                        (index-theme #'default-index-theme)
                        (not-found #'default-not-found)
                        now)
  "SITE as a Clack/Ring handler: (env -> response), ready for HYPERION/SERVER:START.

PAGE-THEME, INDEX-THEME and NOT-FOUND are the site's, and the defaults are plain on purpose
(see the commentary at the top of this file). NOW is a clock for tests, threaded into the
same request-time visibility rule READABLE-P states, so a scheduled document is hidden by the
request that asks for it rather than by the load that read it.

A HANDLER, not a server. klio starts nothing: the site owns its server, its port and its
main, which is also why this system declares no HTTP backend (#139, ADR-0011)."
  (lambda (env)
    ;; ONE READ, at the top, for the whole request. See the file header: this is the
    ;; consuming half of ADR-0001's atomicity guarantee.
    (let* ((tree (site-tree site))
           (key (%request-key env))
           (readable (tree-readable-documents tree :now now)))
      (cond
        ((string= "" key)
         (%html-response 200 (funcall index-theme site readable)))
        (t
         (let ((document (find key readable :key #'document-key :test #'string=)))
           (if document
               (%html-response 200 (funcall page-theme site document))
               ;; A document that exists but is not readable yet is a 404 and not a 403:
               ;; that a draft EXISTS is itself unpublished information, and the two answers
               ;; are distinguishable from outside.
               (%html-response 404 (funcall not-found site key)))))))))
