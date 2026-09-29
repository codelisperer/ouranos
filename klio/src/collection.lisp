;;;; collection.lisp --- collections of documents, sorted by a field, for a site's theme (#353).
;;;;
;;;; A COLLECTION IS A DIRECTORY. The documents under `roles/' are the roles collection, and
;;;; nothing in the content has to say so. A document's key is its path under the content
;;;; directory, so a collection is exactly the documents whose key starts with its name and a
;;;; slash.
;;;;
;;;; THE FIRST CONSUMER IS A CV. The personal site renders every role, newest first, from each
;;;; role's structured front matter (bullets with metric maps, which `extra' already carries),
;;;; and its landing page picks particular metrics out of those bullets. The same data feeds
;;;; the site's generator of tailored CVs, so this is its data layer too.
;;;;
;;;; ONE TREE PER REQUEST, FOR THE THEME AS WELL AS THE HANDLER. A theme that renders the CV page
;;;; needs the rest of the tree, and before this file the only way to get it was to read the
;;;; site's tree slot again, which after a reload can be a different tree from the one the
;;;; handler found the page in. That is the mixture ADR-0001 rules out, reached from below the
;;;; handler. SITE-APP now binds *REQUEST-TREE* and *REQUEST-NOW* for the request, and the
;;;; functions here read them, so a theme sees the handler's snapshot without being handed it.

(in-package #:klio)

(defvar *request-tree* nil
  "The content tree the current request is being served from, bound by SITE-APP, or NIL outside
a request. See CURRENT-TREE.")

(defvar *request-now* nil
  "The time the current request is judged at for visibility, bound by SITE-APP, or NIL.")

(defun current-tree (site)
  "The tree a theme should read: the one the current request is being served from when there
is one, so a page and the collection beside it come from the same tree, and SITE's published
tree otherwise, as at a REPL or in a static export."
  (or *request-tree* (site-tree site)))

;;; --- fields -----------------------------------------------------------------

(defun document-field (document name)
  "The value of the front-matter field NAME in DOCUMENT: one of klio's core fields (title,
date, slug, tags, draft, publish-at) or else a top-level `extra' key. NIL when absent.

SLUG is the document's slug as klio resolved it, which is the front matter's `slug' or the
last segment of its key, because that is the one a URL uses."
  (let ((meta (document-meta document)))
    (cond ((string= name "title") (content-meta-title meta))
          ((string= name "date") (content-meta-date meta))
          ((string= name "slug") (document-slug document))
          ((string= name "tags") (content-meta-tags meta))
          ((string= name "draft") (content-meta-draft meta))
          ((string= name "publish-at") (content-meta-publish-at meta))
          (t (extra meta name)))))

(defun %field-before-p (a b)
  "Whether the field value A sorts before B. Numbers compare as numbers and everything else
as its printed text, so ISO dates such as 2024-05-01 sort by date. A number sorts before text,
so a collection that mixes the two still has one order."
  (cond ((and (realp a) (realp b)) (< a b))
        ((realp a) t)
        ((realp b) nil)
        (t (string< (princ-to-string a) (princ-to-string b)))))

;;; --- collections --------------------------------------------------------------

(defun %collection-prefix (name)
  (concatenate 'string (string-right-trim "/" name) "/"))

(defun tree-collection (tree name &key now sort-by (order :ascending))
  "The readable documents of TREE in the collection NAME, the directory `NAME/' under the
content directory, including its subdirectories.

Unsorted, they come in key order. With SORT-BY, a field name as DOCUMENT-FIELD takes it
(\"date\", \"title\", or an `extra' key), they are sorted by that field, ORDER :ASCENDING or
:DESCENDING, and ties keep key order. A document without the field goes last in either
order: a role with no date belongs at the end of the list, not at the top of it.

NOW is the time visibility is judged at, as in TREE-READABLE-DOCUMENTS."
  (check-type order (member :ascending :descending))
  (let* ((prefix (%collection-prefix name))
         (members (remove-if-not (lambda (d)
                                   (let ((key (document-key d)))
                                     (and (> (length key) (length prefix))
                                          (string= prefix key :end2 (length prefix)))))
                                 (tree-readable-documents tree :now now))))
    (if (null sort-by)
        members
        (let ((with (remove-if (lambda (d) (null (document-field d sort-by))) members))
              (without (remove-if-not (lambda (d) (null (document-field d sort-by))) members)))
          (append (stable-sort with
                               (if (eq order :ascending)
                                   #'%field-before-p
                                   (lambda (a b) (%field-before-p b a)))
                               :key (lambda (d) (document-field d sort-by)))
                  without)))))

(defun collection (site name &key sort-by (order :ascending) (now *request-now*))
  "TREE-COLLECTION over CURRENT-TREE: the collection NAME as the current request sees it. The
call a theme makes."
  (tree-collection (current-tree site) name :now now :sort-by sort-by :order order))

;;; --- looking one document up ----------------------------------------------------

(defun tree-document-by-slug (tree slug &key now)
  "The readable document of TREE whose slug is SLUG, or NIL. A draft or a scheduled document
is not found, so a theme that links to one cannot reveal that it exists."
  (find slug (tree-readable-documents tree :now now) :key #'document-slug :test #'string=))

(defun vocabulary-entries (site name)
  "The labels of the vocabulary NAME in CURRENT-TREE, in the order its source document lists
them, or NIL for a vocabulary the site did not declare (#353)."
  (let ((tree (current-tree site)))
    (and tree (gethash name (content-tree-vocabularies tree)))))

(defun vocabulary-entry-p (site name label)
  "Whether LABEL is an entry of the vocabulary NAME, matched exactly (#353)."
  (and (member label (vocabulary-entries site name) :test #'string=) t))

(defun document-by-slug (site slug &key (now *request-now*))
  "TREE-DOCUMENT-BY-SLUG over CURRENT-TREE. The call a theme makes."
  (tree-document-by-slug (current-tree site) slug :now now))
