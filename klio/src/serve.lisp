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

(defun default-tag-theme (site tag documents)
  "The default page for one tag: the documents that carry it, by title, in key order. TAG is
the tag's slug."
  (declare (ignore site))
  (%page-html
   tag
   (spin:with-html-string
     (:h1 tag)
     (:ul
      (dolist (d documents)
        (:li (:a :href (format nil "/~A" (document-key d))
                 (or (content-meta-title (document-meta d)) (document-key d)))))))))

(defun default-collection-theme (site name documents)
  "The default listing page for one collection: its documents, by title, in the collection's
order. NAME is the collection's name (#557)."
  (declare (ignore site))
  (%page-html
   name
   (spin:with-html-string
     (:h1 name)
     (:ul
      (dolist (d documents)
        (:li (:a :href (format nil "/~A" (document-key d))
                 (or (content-meta-title (document-meta d)) (document-key d)))))))))

(defparameter +windows-device-names+
  '("CON" "PRN" "AUX" "NUL"
    "COM1" "COM2" "COM3" "COM4" "COM5" "COM6" "COM7" "COM8" "COM9"
    "LPT1" "LPT2" "LPT3" "LPT4" "LPT5" "LPT6" "LPT7" "LPT8" "LPT9")
  "The names Windows reserves for devices. A file or directory named one of them, with or
without an extension, cannot be made on Windows (#631).")

(defun %windows-device-name-p (segment)
  "Whether SEGMENT's name before its first `.' is a Windows device name, compared without regard
to case: CON, nul.txt and com1 are."
  (member (subseq segment 0 (or (position #\. segment) (length segment)))
          +windows-device-names+ :test #'string-equal))

(defun %safe-collection-name-p (name)
  "Whether NAME, without slashes at either end, is safe as both a URL path and a path under the
export directory: segments separated by `/', each non-empty, made only of letters, digits, `.',
`-' and `_', not starting with `.' or `_', which also rules out `.' and `..', not ending in `.',
and not a Windows device name (%WINDOWS-DEVICE-NAME-P).

Copilot's review of #619: `../outside' would have been written outside the export directory, and
characters such as `*', `:' or a backslash mean something to a Lisp or Windows pathname. A
segment starting with `_' or `.' is one CONTENT-FILES skips (#557), so its listing would always
be empty.

#631: Windows strips a trailing `.', so `roles.' and `roles' would be one directory there while
%COLLIDING-PATHS took them for two, and it cannot make a file or directory named for a device.
Both are refused on every operating system, so a site behaves the same everywhere. A space is
not one of the characters allowed, so a trailing space is refused already."
  (let ((segments (uiop:split-string name :separator "/")))
    (and segments
         (every (lambda (segment)
                  (and (plusp (length segment))
                       (not (find (char segment 0) "._"))
                       (char/= #\. (char segment (1- (length segment))))
                       (not (%windows-device-name-p segment))
                       (every (lambda (c) (or (alphanumericp c) (find c ".-_"))) segment)))
                segments))))

(defun %at-or-under-p (path base)
  "Whether PATH is BASE or lies under it, as `/'-separated paths, without regard to case: on
Windows and macOS `Tags/' and `tags/' are one directory, and refusing the pair on Linux too
costs nothing."
  (or (string-equal path base)
      (and (> (length path) (length base))
           (string-equal base path :end2 (length base))
           (char= #\/ (char path (length base))))))

(defun %check-collections (collections tags-prefix page-segment)
  "Signal an error unless COLLECTIONS is a list of entries MAKE-SITE-OPTIONS accepts: each a safe
name (%SAFE-COLLECTION-NAME-P), or a name with only :SORT-BY, :ORDER and :THEN-BY, no name given
twice, and no name whose listing a route resolved first would hide or replace. A name at or under
the tags prefix would replace a tag's page (`tags/lisp'); one at or under the page segment would
be taken for the index's pages (`page/2'); and one at or under another listed collection's page
segment (`roles/page') would be taken for that collection's pages."
  (unless (listp collections)
    (error "klio: :collections must be a list of collection names, got ~S" collections))
  (let ((names '()))
    (dolist (entry collections)
      (let ((name (if (consp entry) (first entry) entry)))
        (unless (and (stringp name) (plusp (length (string-trim "/" name))))
          (error "klio: a :collections entry must be a name or (name :sort-by ...), got ~S" entry))
        (when (consp entry)
          (let ((options (rest entry)))
            (unless (and (evenp (length options))
                         (loop for (k nil) on options by #'cddr
                               always (member k '(:sort-by :order :then-by))))
              (error "klio: the :collections entry ~S may give only :sort-by, :order and :then-by"
                     entry))))
        (let ((name (string-trim "/" name)))
          (unless (%safe-collection-name-p name)
            (error "klio: the collection name ~S must be /-separated segments of letters, digits, . - and _, none empty, starting with . or _, ending in ., or a Windows device name such as CON, NUL or COM1"
                   name))
          (when (member name names :test #'string-equal)
            (error "klio: the collection ~S is named twice in :collections" name))
          (push name names))))
    (dolist (name names)
      (let ((clash (or (and (%at-or-under-p name (string-trim "/" tags-prefix)) "the tag pages")
                       (and (%at-or-under-p name page-segment) "the index's pages")
                       (let ((other (find-if
                                     (lambda (o)
                                       (%at-or-under-p name (format nil "~A/~A" o page-segment)))
                                     names)))
                         (and other (format nil "the pages of the collection ~S" other))))))
        (when clash
          (error "klio: the collection ~S would share its listing's URL with ~A; rename it"
                 name clash))))))

(defun make-site-options (&key (page-theme #'default-page-theme)
                               (index-theme #'default-index-theme)
                               (not-found #'default-not-found)
                               (tag-theme #'default-tag-theme)
                               (collection-theme #'default-collection-theme)
                               collections
                               per-page base-url feed-title feed-collection (feed-limit 20)
                               (tags-prefix "tags") (page-segment "page")
                               (rss-path "feed.xml") (atom-path "atom.xml")
                               (search-path "search.json"))
  "The options SITE-APP and EXPORT-SITE share; each takes these as keyword arguments.

The themes are functions of the site and what they render: PAGE-THEME (site document),
INDEX-THEME (site documents), TAG-THEME (site tag documents), COLLECTION-THEME (site name
documents), NOT-FOUND (site key). A listing theme runs with *PAGE-NUMBER* and *PAGE-COUNT*
bound, and PAGE-URL, TAG-URL and COLLECTION-URL give it links.

COLLECTIONS turns on a listing page for each collection it names, at /<name>/ (#557). Without
it, a collection has no listing page of its own. An entry is a name, \"roles\", or a name with
the ordering COLLECTION takes, (\"roles\" :sort-by \"start\" :order :descending :then-by
\"title\"). A name is `/'-separated segments of letters, digits, `.', `-' and `_', none empty or
starting with `.' or `_' (%SAFE-COLLECTION-NAME-P). Any other name is an error, and so is a name
at or under the tags prefix, the page segment or another listed collection's page segment, or a
name given twice, compared without regard to case (%CHECK-COLLECTIONS).

PER-PAGE, when given, paginates the index, each tag's listing and each collection's listing:
page 1 is the listing's own URL, page N adds PAGE-SEGMENT/N/. Without it, a listing is one page.

BASE-URL, such as \"https://example.org\", turns the feeds on. RSS and Atom need absolute
links, so without it there are no feeds. FEED-COLLECTION limits them to one collection, such as
\"posts\"; FEED-LIMIT caps the entries, newest first; FEED-TITLE names the feed.

TAGS-PREFIX, RSS-PATH, ATOM-PATH and SEARCH-PATH are the defaults /tags/<tag>/, /feed.xml,
/atom.xml and /search.json, without their leading slash. SEARCH-PATH NIL turns search.json off:
the export does not write it and SITE-APP does not serve it (#556). search.json carries each
readable document's Markdown body; front-matter `search: false' leaves a document out."
  (check-type per-page (or null (integer 1)))
  (check-type search-path (or null string))
  (check-type feed-limit (integer 1))
  (%check-collections collections tags-prefix page-segment)
  (%make-site-options :page-theme page-theme :index-theme index-theme :not-found not-found
                      :tag-theme tag-theme :collection-theme collection-theme
                      :collections (copy-list collections) :per-page per-page :base-url base-url
                      :feed-title feed-title :feed-collection feed-collection
                      :feed-limit feed-limit :tags-prefix tags-prefix :page-segment page-segment
                      :rss-path rss-path :atom-path atom-path :search-path search-path))

(defun site-app (site &rest options &key now &allow-other-keys)
  "SITE as a Clack/Ring handler: (env -> response), ready for HYPERION/SERVER:START.

OPTIONS are MAKE-SITE-OPTIONS's: the themes, pagination, feeds and the URLs of the engine's
own pages. The defaults are plain on purpose (see the commentary at the top of this file).
Which page answers which path is RESOLVE-PATH's, shared with EXPORT-SITE.

NOW is a clock for tests. Without it each request is judged at the time it arrives, so a
scheduled document appears when its time comes (#359).

A HANDLER, not a server. klio starts nothing: the site owns its server, its port and its
main, which is also why this system declares no HTTP backend (pre-publication issue 139, ADR-0011)."
  (let ((options (apply #'make-site-options
                        (loop for (k v) on options by #'cddr
                              unless (eq k :now) append (list k v)))))
    (lambda (env)
      ;; ONE READ, at the top, for the whole request. See the file header: this is the
      ;; consuming half of ADR-0001's atomicity guarantee. The theme reads the same tree,
      ;; through CURRENT-TREE and COLLECTION, rather than the site's slot (#353).
      (let* ((tree (site-tree site))
             (key (%request-key env))
             (*request-now* (or now (get-universal-time)))
             (*request-tree* tree)
             (*site-options* options))
        (multiple-value-bind (kind body) (resolve-path site tree key :now *request-now*)
          (if kind
              (list 200 (list :content-type (cdr (assoc kind +content-types+))) (list body))
              ;; A document that exists but is not readable yet is a 404 and not a 403:
              ;; that a draft EXISTS is itself unpublished information, and the two answers
              ;; are distinguishable from outside.
              (%html-response 404 (funcall (site-options-not-found options) site key))))))))
