;;;; listing.lisp --- feeds, tag pages, pagination and the search index, and the one place that
;;;; says which of the engine's pages lives at which path (#353).
;;;;
;;;; ONE RESOLVER, TWO USES. RESOLVE-PATH maps a request path to a response for every page the
;;;; engine makes: the index and its pages, a tag's page and its pages, the two feeds, the search
;;;; index and each document. SITE-APP calls it for each request, and EXPORT-SITE calls it for
;;;; every path SITE-PATHS lists and writes what comes back. So the hosted site and the exported
;;;; one cannot disagree about what lives where.
;;;;
;;;; THE URLS ARE DEFAULTS A SITE CAN CHANGE, in SITE-OPTIONS: /tags/<tag>/, /page/2/,
;;;; /feed.xml, /atom.xml and /search.json. A listing's first page is its bare URL, and page N is
;;;; that URL plus page/N/.
;;;;
;;;; FEEDS NEED A BASE URL. RSS and Atom require absolute links, and only the site knows its own
;;;; address, so a site without :BASE-URL has no feeds and no feed paths, rather than feeds with
;;;; relative links that a reader cannot follow.

(in-package #:klio)

;;; --- options ---------------------------------------------------------------------

(defstruct (site-options (:constructor %make-site-options) (:copier nil))
  "Everything SITE-APP and EXPORT-SITE take besides the site. Made by %OPTIONS from their
keyword arguments."
  page-theme index-theme not-found tag-theme
  per-page base-url feed-title feed-collection (feed-limit 20)
  (tags-prefix "tags") (page-segment "page")
  (rss-path "feed.xml") (atom-path "atom.xml") (search-path "search.json"))

(defvar *site-options* nil
  "The SITE-OPTIONS of the request or export in progress. PAGE-URL, TAG-URL and the pagination
specials read it.")

(defvar *page-number* 1 "In a listing theme, which page of the listing is being rendered.")
(defvar *page-count* 1 "In a listing theme, how many pages the listing has.")

;;; --- tags and pages --------------------------------------------------------------

(defun tag-slug (tag)
  "TAG as it appears in a URL. Lowercased; # and + become the words sharp and plus, so C#, C++
and C stay three tags; and every run of other characters that are not letters or digits becomes
one hyphen, with none at either end. `Common Lisp' is common-lisp, `C#' is c-sharp, `C++' is
c-plus-plus and `.NET' is net. Two tags with the same slug share a page."
  (let ((out (make-string-output-stream))
        (pending nil))
    (flet ((word (w)
             (when (and pending (plusp (file-position out))) (write-char #\- out))
             (setf pending nil)
             (write-string w out)))
      (loop for ch across (string-downcase tag)
            do (cond ((alphanumericp ch) (word (string ch)))
                     ((char= ch #\#) (setf pending t) (word "sharp") (setf pending t))
                     ((char= ch #\+) (setf pending t) (word "plus") (setf pending t))
                     (t (setf pending t)))))
    (get-output-stream-string out)))

(defun tree-tags (tree &key now)
  "The tags of TREE's readable documents, as an alist of (slug . documents) sorted by slug,
each list of documents in key order."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (d (tree-readable-documents tree :now now))
      (dolist (tag (remove-duplicates (mapcar #'tag-slug (content-meta-tags (document-meta d)))
                                      :test #'string=))
        (when (plusp (length tag))
          (push d (gethash tag table)))))
    (sort (loop for tag being the hash-keys of table using (hash-value docs)
                collect (cons tag (reverse docs)))
          #'string< :key #'car)))

(defun %page-count (count per-page)
  (if (and per-page (plusp count)) (ceiling count per-page) 1))

(defun %page-of (documents per-page page)
  (if per-page
      (subseq documents (min (length documents) (* per-page (1- page)))
              (min (length documents) (* per-page page)))
      documents))

(defun %listing-path (base page)
  "BASE, a listing's path without slashes (\"\" for the index), for page PAGE."
  (let ((prefix (if (string= "" base) "" (concatenate 'string base "/"))))
    (if (= page 1)
        prefix
        (format nil "~A~A/~D/" prefix (site-options-page-segment *site-options*) page))))

(defun page-url (page &optional (tag nil))
  "The URL of page PAGE of the index, or of TAG's listing when TAG (a tag or its slug) is given,
under the current SITE-OPTIONS. For a theme's previous and next links."
  (concatenate 'string "/"
               (%listing-path (if tag
                                  (format nil "~A/~A" (site-options-tags-prefix *site-options*)
                                          (tag-slug tag))
                                  "")
                              page)))

(defun tag-url (tag)
  "The URL of TAG's listing, its first page."
  (page-url 1 tag))

;;; --- feeds -----------------------------------------------------------------------

(defun %xml-escape (text)
  (with-output-to-string (s)
    (loop for ch across (or text "")
          do (case ch
               (#\& (write-string "&amp;" s))
               (#\< (write-string "&lt;" s))
               (#\> (write-string "&gt;" s))
               (#\" (write-string "&quot;" s))
               (t (write-char ch s))))))

(defun %absolute (path)
  (concatenate 'string (string-right-trim "/" (site-options-base-url *site-options*)) path))

(defun feed-entries (tree &key now)
  "The documents the feeds list: the readable documents of the feed collection (every readable
document when the site names none) that have a date, newest first, at most FEED-LIMIT."
  (let* ((collection (site-options-feed-collection *site-options*))
         (documents (if collection
                        (tree-collection tree collection :now now)
                        (tree-readable-documents tree :now now)))
         (dated (remove-if-not (lambda (d) (content-meta-timestamp (document-meta d))) documents))
         (sorted (stable-sort (copy-list dated) #'>
                              :key (lambda (d) (content-meta-timestamp (document-meta d))))))
    (subseq sorted 0 (min (length sorted) (site-options-feed-limit *site-options*)))))

(defun %title-of (document)
  (or (content-meta-title (document-meta document)) (document-key document)))

(defun rss-feed (tree &key now)
  "An RSS 2.0 feed of FEED-ENTRIES, with absolute links."
  (let ((entries (feed-entries tree :now now))
        (title (or (site-options-feed-title *site-options*) (site-options-base-url *site-options*))))
    (with-output-to-string (s)
      (format s "<?xml version=\"1.0\" encoding=\"utf-8\"?>~%")
      (format s "<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\"><channel>~%")
      (format s "<title>~A</title>~%<link>~A</link>~%<description>~A</description>~%"
              (%xml-escape title) (%xml-escape (%absolute "/")) (%xml-escape title))
      (format s "<atom:link href=\"~A\" rel=\"self\" type=\"application/rss+xml\"/>~%"
              (%xml-escape (%absolute (concatenate 'string "/" (site-options-rss-path *site-options*)))))
      (when entries
        (format s "<lastBuildDate>~A</lastBuildDate>~%"
                (rfc-822-date (content-meta-timestamp (document-meta (first entries))))))
      (dolist (d entries)
        (let ((link (%absolute (concatenate 'string "/" (document-key d)))))
          (format s "<item><title>~A</title><link>~A</link><guid isPermaLink=\"true\">~A</guid><pubDate>~A</pubDate><description>~A</description></item>~%"
                  (%xml-escape (%title-of d)) (%xml-escape link) (%xml-escape link)
                  (rfc-822-date (content-meta-timestamp (document-meta d)))
                  (%xml-escape (document-html d)))))
      (format s "</channel></rss>~%"))))

(defun atom-feed (tree &key now)
  "An Atom feed of FEED-ENTRIES, with absolute links. Its updated date is the newest entry's, or
the time the tree was loaded when there are none."
  (let* ((entries (feed-entries tree :now now))
         (title (or (site-options-feed-title *site-options*) (site-options-base-url *site-options*)))
         (self (%absolute (concatenate 'string "/" (site-options-atom-path *site-options*))))
         (updated (if entries
                      (content-meta-timestamp (document-meta (first entries)))
                      (content-tree-loaded-at tree))))
    (with-output-to-string (s)
      (format s "<?xml version=\"1.0\" encoding=\"utf-8\"?>~%")
      (format s "<feed xmlns=\"http://www.w3.org/2005/Atom\">~%")
      (format s "<title>~A</title>~%<id>~A</id>~%<updated>~A</updated>~%"
              (%xml-escape title) (%xml-escape (%absolute "/")) (rfc-3339-date updated))
      (format s "<link href=\"~A\"/>~%<link rel=\"self\" href=\"~A\"/>~%"
              (%xml-escape (%absolute "/")) (%xml-escape self))
      (format s "<author><name>~A</name></author>~%" (%xml-escape title))
      (dolist (d entries)
        (let ((link (%absolute (concatenate 'string "/" (document-key d)))))
          (format s "<entry><title>~A</title><id>~A</id><link href=\"~A\"/><updated>~A</updated><content type=\"html\">~A</content></entry>~%"
                  (%xml-escape (%title-of d)) (%xml-escape link) (%xml-escape link)
                  (rfc-3339-date (content-meta-timestamp (document-meta d)))
                  (%xml-escape (document-html d)))))
      (format s "</feed>~%"))))

;;; --- the search index ------------------------------------------------------------

(defun search-json (tree &key now)
  "Every readable document as a JSON array of objects with url, title, tags, date and text (the
Markdown body), for a search box that fetches the file once and searches in the page. Readable
only: a draft is not in it."
  (com.inuoe.jzon:stringify
   (coerce (loop for d in (tree-readable-documents tree :now now)
                 for meta = (document-meta d)
                 collect (let ((h (make-hash-table :test #'equal)))
                           (setf (gethash "url" h) (concatenate 'string "/" (document-key d))
                                 (gethash "title" h) (or (content-meta-title meta) 'null)
                                 (gethash "tags" h) (coerce (content-meta-tags meta) 'vector)
                                 (gethash "date" h) (or (content-meta-date meta) 'null)
                                 (gethash "text" h) (document-body d))
                           h))
           'vector)))

;;; --- the resolver ----------------------------------------------------------------

(defparameter +content-types+
  '((:html . "text/html; charset=utf-8")
    (:rss . "application/rss+xml; charset=utf-8")
    (:atom . "application/atom+xml; charset=utf-8")
    (:json . "application/json; charset=utf-8")))

(defun %parse-listing (rest)
  "REST, a path under a listing's base, as a page number: \"\" is page 1 and \"page/N/\" is
page N for N of 2 or more. NIL for anything else."
  (let ((segment (concatenate 'string (site-options-page-segment *site-options*) "/")))
    (cond ((string= rest "") 1)
          ((and (> (length rest) (length segment))
                (string= segment rest :end2 (length segment))
                (char= #\/ (char rest (1- (length rest)))))
           (let ((n (ignore-errors (parse-integer rest :start (length segment)
                                                       :end (1- (length rest))))))
             (and n (>= n 2) n))))))

(defun %listing (site documents page theme &rest theme-args)
  "Page PAGE of DOCUMENTS through THEME, or NIL when there is no such page."
  (let* ((per-page (site-options-per-page *site-options*))
         (count (%page-count (length documents) per-page)))
    (when (<= 1 page count)
      (let ((*page-number* page) (*page-count* count))
        (apply theme site (append theme-args (list (%page-of documents per-page page))))))))

(defun resolve-path (site tree path &key now)
  "The engine's page at PATH (without its leading slash) in TREE: (values KIND BODY), KIND one
of :HTML, :RSS, :ATOM or :JSON, or NIL when there is none. Reads *SITE-OPTIONS*."
  (let* ((o *site-options*)
         (readable (tree-readable-documents tree :now now))
         (tags-base (concatenate 'string (site-options-tags-prefix o) "/"))
         (index-page (%parse-listing path)))
    (cond
      ((and (site-options-base-url o) (string= path (site-options-rss-path o)))
       (values :rss (rss-feed tree :now now)))
      ((and (site-options-base-url o) (string= path (site-options-atom-path o)))
       (values :atom (atom-feed tree :now now)))
      ((string= path (site-options-search-path o))
       (values :json (search-json tree :now now)))
      (index-page
       (let ((html (%listing site readable index-page (site-options-index-theme o))))
         (and html (values :html html))))
      ((and (> (length path) (length tags-base)) (string= tags-base path :end2 (length tags-base)))
       (let* ((rest (subseq path (length tags-base)))
              (slash (position #\/ rest))
              (slug (and slash (subseq rest 0 slash)))
              (page (and slash (%parse-listing (subseq rest (1+ slash)))))
              (entry (and slug (assoc slug (tree-tags tree :now now) :test #'string=))))
         (if (and entry page)
             (let ((html (%listing site (cdr entry) page (site-options-tag-theme o) (car entry))))
               (and html (values :html html)))
             (%document-at site readable path))))
      (t (%document-at site readable path)))))

(defun %document-at (site readable path)
  (let ((document (find path readable :key #'document-key :test #'string=)))
    (and document (values :html (funcall (site-options-page-theme *site-options*) site document)))))

(defun site-paths (tree &key now)
  "Every path RESOLVE-PATH answers for TREE, which is what EXPORT-SITE writes."
  (let* ((o *site-options*)
         (readable (tree-readable-documents tree :now now))
         (per-page (site-options-per-page o)))
    (append
     (loop for page from 1 to (%page-count (length readable) per-page)
           collect (%listing-path "" page))
     (loop for (slug . documents) in (tree-tags tree :now now)
           append (loop for page from 1 to (%page-count (length documents) per-page)
                        collect (%listing-path (format nil "~A/~A" (site-options-tags-prefix o) slug)
                                               page)))
     (when (site-options-base-url o)
       (list (site-options-rss-path o) (site-options-atom-path o)))
     (list (site-options-search-path o))
     (mapcar #'document-key readable))))
