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
;;;; not.
;;;;
;;;; STATIC ASSETS (#557). With :ASSETS, a directory of the site's own files -- its CSS, images,
;;;; fonts, a .well-known/ -- is copied into the export after :CLEAN has emptied it, keeping
;;;; each file's path relative to that directory. Every file is copied, dot-names included,
;;;; because a static host reads .well-known/. An asset whose path is one the export writes a
;;;; page to is refused before anything is written, rather than one silently replacing the
;;;; other; the paths are compared without regard to case, because the file systems of Windows
;;;; and macOS would make them one file.

(in-package #:klio)

(define-condition export-refused (error)
  ((directory :initarg :directory :reader export-refused-directory)
   (reason :initarg :reason :reader export-refused-reason))
  (:report (lambda (c s)
             (format s "klio: refusing to export into ~A: ~A"
                     (export-refused-directory c) (export-refused-reason c))))
  (:documentation "Signalled by EXPORT-SITE before it writes anything."))

(defun %export-file (path layout document-keys)
  "The file, relative to the export directory, that the engine's page at PATH is written to."
  (cond ((string= path "") "index.html")
        ((char= #\/ (char path (1- (length path)))) (concatenate 'string path "index.html"))
        ((gethash path document-keys)
         (ecase layout
           (:file (concatenate 'string path ".html"))
           (:directory (concatenate 'string path "/index.html"))))
        (t path)))

(defun %render-site (site tree now layout)
  "Every file of the export as (relative-path . text), rendered from TREE through RESOLVE-PATH
for every path SITE-PATHS lists. Signals whatever a theme signals, before anything has been
written."
  (let* ((*request-tree* tree)
         (*request-now* now)
         (keys (let ((h (make-hash-table :test #'equal)))
                 (dolist (d (tree-readable-documents tree :now now) h)
                   (setf (gethash (document-key d) h) t)))))
    (cons (cons "404.html" (funcall (site-options-not-found *site-options*) site nil))
          (mapcar (lambda (path)
                    (cons (%export-file path layout keys)
                          (nth-value 1 (resolve-path site tree path :now now))))
                  (site-paths tree :now now)))))

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

(defun %asset-files (assets)
  "Every file under the directory ASSETS, recursively, as (relative-path . absolute-path) with
the relative path spelled with `/', sorted by relative path."
  (let ((root (uiop:ensure-directory-pathname assets))
        (files '()))
    (labels ((walk (dir)
               (dolist (f (uiop:directory-files dir))
                 (push (cons (substitute #\/ #\\ (%relative-namestring f root)) f) files))
               (dolist (sub (uiop:subdirectories dir))
                 (walk sub))))
      (walk root))
    (sort files #'string< :key #'car)))

(defun %resolved-directory (directory)
  "DIRECTORY's resolved name, also when it does not exist yet: the nearest existing ancestor is
resolved and the rest of the name appended.

An export directory usually does not exist yet, and the assets directory does. PROBE-FILE
resolves only the second, and the two then name the same place differently wherever a path
has two spellings: a Windows 8.3 alias in TEMP, as on CI runners (`RUNNER~1'), or macOS's
/var, which is /private/var. Measured on #615's first run: an export directory inside the
assets directory was not refused on Windows and macOS, and was on Linux."
  (let ((dir (uiop:ensure-directory-pathname directory)))
    (or (probe-file dir)
        (let ((parent (uiop:pathname-parent-directory-pathname dir)))
          (if (equal parent dir)
              dir
              (merge-pathnames (make-pathname :directory (list :relative
                                                               (car (last (pathname-directory dir)))))
                               (%resolved-directory parent)))))))

(defun %same-or-inside-p (inner outer)
  "Whether directory INNER is OUTER or lies under it, compared by resolved names."
  (let ((in (namestring (%resolved-directory inner)))
        (out (namestring (%resolved-directory outer))))
    (and (<= (length out) (length in))
         (string= out in :end2 (length out)))))

(defun %check-assets (assets directory page-files)
  "The asset files to copy, as %ASSET-FILES returns them, after checking that they can be:
signals EXPORT-REFUSED when ASSETS is not a directory, when it holds or is inside DIRECTORY
(where :CLEAN would delete it, or the copy would copy itself), or when an asset's path is one
in PAGE-FILES."
  (let ((assets (uiop:ensure-directory-pathname assets)))
    (unless (uiop:directory-exists-p assets)
      (error 'export-refused :directory directory
                             :reason (format nil "the :ASSETS directory ~A does not exist" assets)))
    (when (or (%same-or-inside-p assets directory) (%same-or-inside-p directory assets))
      (error 'export-refused :directory directory
                             :reason (format nil "the :ASSETS directory ~A holds it or is inside it" assets)))
    (let* ((files (%asset-files assets))
           (clash (find-if (lambda (f) (member (car f) page-files :test #'string-equal)) files)))
      (when clash
        (error 'export-refused :directory directory
                               :reason (format nil "the asset ~A would replace the page written to the same path" (car clash))))
      files)))

(defun export-site (site directory &rest options &key (layout :file) clean now assets
                                                    &allow-other-keys)
  "Render SITE's published content into DIRECTORY for a static host, with the same options
SITE-APP takes (MAKE-SITE-OPTIONS). Returns the list of files written, relative to DIRECTORY.

Writes 404.html and every page RESOLVE-PATH answers: the index and its pages, each tag's
listing and its pages, the feeds when BASE-URL is given, the search index unless SEARCH-PATH is
NIL, and one file per readable document. A listing at /tags/x/ is written to tags/x/index.html;
see the file header for LAYOUT, which applies to documents. NOW is the time visibility is judged
at, so a scheduled document is exported only once its time has come; NIL means now.

Nothing is written unless every page renders. DIRECTORY must be absent or empty, or CLEAN must
be true, in which case its contents are deleted first; otherwise EXPORT-REFUSED is signalled.
Signals EXPORT-REFUSED too when SITE has no published content (BOOT it first).

ASSETS, a directory, is copied into DIRECTORY after it is emptied, every file at its path
relative to ASSETS (see the file header). EXPORT-REFUSED is signalled, before anything is
written, when ASSETS does not exist, holds DIRECTORY or is inside it, or has a file whose path
is one a page is written to. The returned list names the pages, then the assets."
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
    (let ((files (let ((*site-options*
                         (apply #'make-site-options
                                (loop for (k v) on options by #'cddr
                                      unless (member k '(:layout :clean :now :assets))
                                        append (list k v)))))
                   (%render-site site tree now layout)))
          (asset-files nil))
      (when assets
        (setf asset-files (%check-assets assets directory (mapcar #'car files))))
      ;; AION/FS:DELETE-TREE, which removes a link inside the directory as a link and refuses a
      ;; directory that is itself one, as the rest of the tree does since #347.
      (when (uiop:directory-exists-p directory)
        (aion/fs:delete-tree directory))
      (dolist (file files)
        (let ((path (merge-pathnames (car file) directory)))
          (ensure-directories-exist path)
          (with-open-file (out path :direction :output :if-exists :supersede
                                    :external-format :utf-8)
            (write-string (cdr file) out))))
      (dolist (asset asset-files)
        (let ((path (merge-pathnames (car asset) directory)))
          (ensure-directories-exist path)
          (uiop:copy-file (cdr asset) path)))
      (append (mapcar #'car files) (mapcar #'car asset-files)))))
