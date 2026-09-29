;;;; export.lisp --- a site rendered to static files, for a static host (#353).
;;;;
;;;; The personal site starts on a static host, and its stopgap build script turns Markdown into
;;;; HTML. EXPORT-SITE replaces that script: every readable document, the index and the 404
;;;; page, rendered through the SAME theme functions SITE-APP takes, into a directory.
;;;;
;;;; ONE TREE, AS IN A REQUEST. The export reads the site's published tree once and binds it
;;;; as *REQUEST-TREE*, so a theme that asks for a collection gets the tree being exported, and
;;;; everything written comes from one tree.
;;;;
;;;; NOTHING IS WRITTEN UNTIL EVERYTHING HAS RENDERED. A theme that signals on one page would
;;;; otherwise leave a directory with half a site in it, which is the partial deploy ADR-0001
;;;; exists to prevent, moved from the running image to the files. So every page is rendered
;;;; to a string first, and the files are written only after the last one succeeded.
;;;;
;;;; A DIRECTORY THAT ALREADY HOLDS FILES IS REFUSED unless the caller says :CLEAN T. Writing
;;;; over an earlier export would leave the page of a deleted document in place, served for as
;;;; long as nobody notices it; the caller decides whether the directory may be emptied.
;;;;
;;;; URLS MATCH SITE-APP. The document with key `roles/a' is served at /roles/a. :LAYOUT :FILE
;;;; (the default) writes roles/a.html, which the common static hosts serve at /roles/a;
;;;; :LAYOUT :DIRECTORY writes roles/a/index.html, served at /roles/a/, for a host that does
;;;; not. Static assets such as the site's CSS are the site's to copy.

(in-package #:klio)

(define-condition export-refused (error)
  ((directory :initarg :directory :reader export-refused-directory)
   (reason :initarg :reason :reader export-refused-reason))
  (:report (lambda (c s)
             (format s "klio: refusing to export into ~A: ~A"
                     (export-refused-directory c) (export-refused-reason c))))
  (:documentation "Signalled by EXPORT-SITE before it writes anything."))

(defun %export-path (key layout)
  "The file, relative to the export directory, that the document KEY is written to."
  (ecase layout
    (:file (concatenate 'string key ".html"))
    (:directory (concatenate 'string key "/index.html"))))

(defun %render-site (site tree now page-theme index-theme not-found layout)
  "Every file of the export as (relative-path . html), rendered from TREE. Signals whatever a
theme signals, before anything has been written."
  (let* ((*request-tree* tree)
         (*request-now* now)
         (readable (tree-readable-documents tree :now now)))
    (append (list (cons "index.html" (funcall index-theme site readable))
                  (cons "404.html" (funcall not-found site nil)))
            (mapcar (lambda (d)
                      (cons (%export-path (document-key d) layout) (funcall page-theme site d)))
                    readable))))

(defun %holds-content-p (directory content)
  "Whether DIRECTORY is CONTENT or one of its ancestors, compared by resolved name where both
exist, so a relative or aliased spelling is not a way around the check."
  (let ((dir (namestring (or (probe-file directory) directory)))
        (con (namestring (or (probe-file (uiop:ensure-directory-pathname content))
                             (uiop:ensure-directory-pathname content)))))
    (and (<= (length dir) (length con))
         (string= dir con :end2 (length dir)))))

(defun %directory-empty-p (directory)
  (and (null (uiop:directory-files directory))
       (null (uiop:subdirectories directory))))

(defun export-site (site directory &key (page-theme #'default-page-theme)
                                        (index-theme #'default-index-theme)
                                        (not-found #'default-not-found)
                                        (layout :file) clean now)
  "Render SITE's published content into DIRECTORY for a static host, through the same theme
functions SITE-APP takes. Returns the list of files written, relative to DIRECTORY.

Writes index.html, 404.html and one file per readable document; see the file header for
LAYOUT. NOW is the time visibility is judged at, so a scheduled document is exported only once
its time has come; NIL means now.

Nothing is written unless every page renders. DIRECTORY must be absent or empty, or CLEAN must
be true, in which case its contents are deleted first; otherwise EXPORT-REFUSED is signalled.
Signals EXPORT-REFUSED too when SITE has no published content (BOOT it first)."
  (check-type layout (member :file :directory))
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (tree (site-tree site))
         (now (or now (get-universal-time))))
    (unless tree
      (error 'export-refused :directory directory
                             :reason "the site has no published content; call BOOT first"))
    (when (%holds-content-p directory (site-directory site))
      (error 'export-refused :directory directory
                             :reason "it is, or contains, the site's content directory, which :CLEAN would delete"))
    (when (and (uiop:directory-exists-p directory)
               (not (%directory-empty-p directory))
               (not clean))
      (error 'export-refused :directory directory
                             :reason "it already holds files, and an earlier export's pages would be left behind; pass :CLEAN T to empty it first"))
    (let ((files (%render-site site tree now page-theme index-theme not-found layout)))
      (when (uiop:directory-exists-p directory)
        (uiop:delete-directory-tree directory :validate t))
      (dolist (file files)
        (let ((path (merge-pathnames (car file) directory)))
          (ensure-directories-exist path)
          (with-open-file (out path :direction :output :if-exists :supersede
                                    :external-format :utf-8)
            (write-string (cdr file) out))))
      (mapcar #'car files))))
