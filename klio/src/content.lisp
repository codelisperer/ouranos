;;;; content.lisp --- loading a content tree, and publishing it all at once (ADR-0001).
;;;;
;;;; ADR-0001 decided what happens when a content file fails to load, and this file is that
;;;; decision in code. ONE RULE: validate the whole candidate tree; if any file fails, do not
;;;; swap, and report every file that failed. The two outcomes follow from the situation
;;;; rather than from a second policy --
;;;;
;;;;   at BOOT there is no previous tree, so "do not swap" means refusing to start;
;;;;   at RELOAD it means the site keeps serving the last good tree and stays up;
;;;;   in DEV MODE the bad file is skipped, reported, and the rest is published.
;;;;
;;;; A deploy cannot fall through a gap between two policies because there is only one. That
;;;; matters because a deploy IS a reload under the deployment model the design doc leans to:
;;;; the image is long-lived, publishing is a pull plus a reload, and any policy written for
;;;; "boot" never runs when content is published.
;;;;
;;;; ATOMICITY IS A POINTER SWAP OF AN IMMUTABLE VALUE, and that is the whole mechanism. A
;;;; CONTENT-TREE is built completely before it is published and never mutated afterwards;
;;;; publishing is one SETF of one slot. A request reads that slot ONCE, at the start, and
;;;; uses the tree it got -- so it sees the old tree or the new one and never a mixture, with
;;;; no lock on the read path. Two concurrent reloads are safe in the sense that matters:
;;;; each publishes a whole tree, so the loser's work is replaced rather than interleaved.
;;;;
;;;; A RELOAD THAT REPORTS ERRORS HAS TO BE A FAILED DEPLOY -- ADR-0001's first consequence,
;;;; and the reason RELOAD-OR-FAIL exists beside RELOAD. A deploy script that pulls, reloads,
;;;; prints the error and exits zero brings the silent partial deploy back in a different
;;;; place. RELOAD returns an outcome a caller must look at; RELOAD-OR-FAIL signals, which a
;;;; script cannot ignore by forgetting to check something.

(cl:in-package #:klio)

;;; --- what a loaded file is --------------------------------------------------

(defstruct (document (:constructor %make-document) (:copier nil))
  "One content file, loaded.

KEY is the tree-relative path without its extension (`roles/2024-softcraft-solutions'), which
is what the tree is addressed by and what a failure report names. SLUG is the front-matter's
`slug' when it has one and KEY's last segment otherwise -- the URL-facing name, which is the
one that must be unique. BODY is the markdown source and HTML is it rendered."
  (key "" :type string)
  (path nil)
  (slug "" :type string)
  (meta nil)
  (body "" :type string)
  (html "" :type string))

(defstruct (content-tree (:constructor %make-content-tree) (:copier nil))
  "A whole tree of loaded content, complete and immutable.

Immutable is not decoration: it is what makes publishing a pointer swap rather than a
critical section. Nothing in here is modified after PUBLISH, so a request holding one of
these holds a consistent snapshot for as long as it needs it."
  (documents (make-hash-table :test #'equal))
  (order '() :type list)              ; keys, sorted, so listing is deterministic
  (index nil)
  (source nil)
  (loaded-at 0)
  (warnings '() :type list))

(defstruct (load-failure (:constructor %make-load-failure) (:copier nil))
  "One file that could not be loaded, and why. A REASON is the condition's report text: the
author reading it needs the sentence, not the class."
  (file "" :type string)
  (reason "" :type string))

(define-condition content-load-failed (error)
  ((failures :initarg :failures :initform '() :reader content-load-failed-failures)
   (source :initarg :source :initform nil :reader content-load-failed-source)
   (phase :initarg :phase :initform :load :reader content-load-failed-phase))
  (:report
   (lambda (c s)
     (let ((failures (content-load-failed-failures c)))
       (format s "klio: ~D content file~:P failed to load~@[ under ~A~]; ~A.~%"
               (length failures)
               (content-load-failed-source c)
               (ecase (content-load-failed-phase c)
                 (:boot "refusing to start")
                 (:reload "the previous content is still being served")
                 (:load "nothing was published")))
       ;; EVERY failing file, never the first. ADR-0001 says so plainly, and the reason is
       ;; the loop it puts an author in otherwise: fix one file, re-run, find the next.
       (dolist (f failures)
         (format s "~&  ~A: ~A" (load-failure-file f) (load-failure-reason f))))))
  (:documentation
   "Signalled when a candidate tree could not be published. PHASE distinguishes the two
outcomes of ADR-0001's single rule -- :BOOT, where there is no previous tree and this means
refusing to start, and :RELOAD, where the site keeps serving what it had."))

;;; --- reading the tree -------------------------------------------------------

(defparameter *content-extension* "md"
  "The extension a content file has. One type, deliberately: a tree where some files are
content and others are anyone's guess is a tree whose failures are unattributable.")

(defun content-files (directory)
  "Every content file under DIRECTORY, recursively, in a deterministic order.

Sorted because a report that names files in filesystem order names them differently on two
machines, and because a duplicate-slug failure should blame the same file twice running
rather than whichever the OS happened to hand back first."
  (let ((files '()))
    (labels ((walk (dir)
               (dolist (f (uiop:directory-files dir))
                 (when (string-equal *content-extension* (pathname-type f))
                   (push f files)))
               (dolist (sub (uiop:subdirectories dir))
                 (walk sub))))
      (walk (uiop:ensure-directory-pathname directory)))
    (sort files #'string< :key #'namestring)))

(defun %relative-namestring (path directory)
  "PATH spelled relative to DIRECTORY, or NIL when it cannot be.

`enough-namestring' SUBTRACTS ONE NAMESTRING FROM ANOTHER, so it only answers when the two
were spelled the same way. That is not a given: a directory has more than one name, and the
walk and the caller can each be holding a different one.

WHERE THIS WAS MEASURED (#446). Windows keeps an 8.3 alias for a long file name, so
`C:\\Users\\runneradmin' is also `C:\\Users\\RUNNER~1', and CI runners set TEMP to the second
form. The walk resolves the alias and returns the long name; DIRECTORY stays as the caller
spelled it; nothing is subtracted, and every document ends up keyed by its whole absolute
path. The tree loads CLEAN -- zero failures, every file parsed and rendered -- and then
answers NIL to every key anybody asks for. Measured on Windows 11 / SBCL 2.6.7: a suite that
passes 168/168 under an ordinary TEMP fails 22 checks across 12 tests under an 8.3 one.

So: try the names as given, and only if that fails resolve BOTH ENDS and try again. The order
matters and is not belt-and-braces. Resolving first would follow symlinks too, and a content
tree assembled out of symlinks -- a real way to build one -- has files whose resolved name is
outside the directory's. Those key correctly today, by subtraction, and would stop keying at
all. The fallback runs only where the direct answer was already wrong."
  (flet ((relative-or-nil (p dir)
           (let ((sub (enough-namestring p dir)))
             ;; `enough-namestring' RETURNS THE WHOLE NAMESTRING when it cannot subtract --
             ;; it does not signal and does not answer NIL, which is exactly why this was
             ;; invisible for as long as it was. An absolute result means it gave up.
             (unless (eq :absolute (first (pathname-directory (parse-namestring sub))))
               sub))))
    (or (relative-or-nil path directory)
        ;; `probe-file' rather than `truename': it answers NIL for something that is not
        ;; there rather than signalling, and deriving a key is not where a tree should
        ;; discover that a file it just walked has gone.
        (let ((real-path (probe-file path))
              (real-dir (probe-file directory)))
          (when (and real-path real-dir)
            (relative-or-nil real-path real-dir))))))

(defun %key-for (path directory)
  "PATH's key: its path relative to DIRECTORY, without the extension, with `/' separators.

`%key-for' rather than `document-key', which is the DOCUMENT accessor -- defining a function
of that name in this file clobbered the accessor and every caller then passed one argument to
a two-argument function. Caught by the compiler here; the same collision one file away is
silent, which is why AGENTS.md says to grep a name before defining it."
  (let* ((directory (uiop:ensure-directory-pathname directory))
         ;; FALLS BACK TO THE FULL NAMESTRING rather than signalling: a key that is wrong is
         ;; a 404, and a key that signals is a tree that will not load at all. A file
         ;; genuinely outside DIRECTORY is a caller's bug, not a reader's.
         (relative (or (%relative-namestring path directory)
                       (enough-namestring path directory)))
         (dot (position #\. relative :from-end t)))
    (substitute #\/ #\\ (if dot (subseq relative 0 dot) relative))))

(defun %slug-of (key meta)
  "The document's URL-facing name: front-matter `slug' when given, else KEY's last segment."
  (or (content-meta-slug meta)
      (let ((slash (position #\/ key :from-end t)))
        (if slash (subseq key (1+ slash)) key))))

(defun load-document (path &key key known-extra)
  "Load one content file into a DOCUMENT. Signals on anything that makes it unloadable.

Signals rather than returns a failure, because this is the one-file operation and the caller
that wants every failure rather than the first is LOAD-TREE, which is where the collecting
belongs."
  (let* ((key (or key (pathname-name path)))
         (text (uiop:read-file-string path))
         (meta nil)
         (body ""))
    (multiple-value-bind (front rest) (split-front-matter text :file key)
      (setf body (or rest ""))
      (setf meta (if front
                     (parse-front-matter front :file key :known-extra known-extra)
                     (%make-content-meta))))
    (%make-document :key key :path path :slug (%slug-of key meta)
                    :meta meta :body body
                    ;; Rendered HERE, at load, not per request. Q3's highlighter runs at
                    ;; content-load time for the same reason, and it means a body that cannot
                    ;; be rendered is a LOAD failure -- caught by the validation pass, where
                    ;; the all-or-nothing rule can still act on it -- rather than a 500 on
                    ;; one page long after the tree was published.
                    :html (render-markdown body))))

(defun %duplicate-slug-failures (documents)
  "Failures for any two documents claiming the same slug.

A TREE-level check, and the clearest argument for validating the tree rather than each file:
neither file is wrong on its own, the conflict exists only between them, and the symptom
without this check is one page silently shadowing another."
  (let ((by-slug (make-hash-table :test #'equal))
        (failures '()))
    (dolist (d documents)
      (push d (gethash (document-slug d) by-slug)))
    (maphash (lambda (slug docs)
               (when (rest docs)
                 (let ((keys (sort (mapcar #'document-key docs) #'string<)))
                   (dolist (k keys)
                     (push (%make-load-failure
                            :file k
                            :reason (format nil "the slug `~A' is claimed by ~{~A~^, ~}"
                                            slug keys))
                           failures)))))
             by-slug)
    failures))

(defun %mapping-p (value)
  "True when VALUE is the front-matter parser's shape for a MAPPING: a proper list of
(string . anything) pairs.

The distinction this draws is the one that makes the walk below correct. A mapping entry
like (text . a-string) has a KEY the author chose; a sequence like (Python Rust) -- both
elements quoted strings in the file -- has no key at all, only words the document says. Both
are lists whose first element has a string in it, and telling them apart by looking at the
first element alone gets one of them wrong."
  (and (consp value)
       (listp (cdr value))
       (every (lambda (entry) (and (consp entry) (stringp (car entry)))) value)))

(defun %leaf-strings (value)
  "Every string leaf of VALUE, with mapping KEYS left out -- a key is a name the author
chose, not a word the document says.

Numbers are skipped too: a metric of 75 is a fact about a bullet rather than a term anybody
types into a search box."
  (cond
    ((stringp value) (list value))
    ((not (consp value)) '())
    ((%mapping-p value) (loop for (nil . v) in value append (%leaf-strings v)))
    ;; a lone (key . scalar) pair, which is what a mapping's entry looks like on its own
    ((and (stringp (car value)) (not (listp (cdr value)))) (%leaf-strings (cdr value)))
    (t (loop for item in value append (%leaf-strings item)))))

(defun %extra-text (extra keys)
  "The searchable text inside a document's structured front-matter.

KEYS is T for all of it, NIL for none, or a list of top-level `extra' keys. A key names a
top-level entry and nothing deeper: `bullets' is a key, not a path, and nobody should have to
write one."
  (let ((entries (cond ((null keys) '())
                       ((eq keys t) extra)
                       (t (remove-if-not (lambda (entry)
                                           (member (car entry) keys :test #'string=))
                                         extra)))))
    (format nil "~{~A~^ ~}" (loop for (nil . v) in entries append (%leaf-strings v)))))

(defun %build-index (documents index-extra)
  "A search index over DOCUMENTS, built at load -- which is the only time the whole tree is
in hand and the last time before anyone can ask it a question."
  (let ((index (make-search-index)))
    (dolist (d documents index)
      (let* ((meta (document-meta d))
             (extra (%extra-text (content-meta-extra meta) index-extra)))
        (index-document index (document-key d)
                        :title (content-meta-title meta)
                        :tags (content-meta-tags meta)
                        :body (if (plusp (length extra))
                                  (concatenate 'string (document-body d) " " extra)
                                  (document-body d)))))))

(defun load-tree (directory &key known-extra (index-extra t) (dev (dev-mode-p)))
  "Load DIRECTORY into a candidate CONTENT-TREE. Returns (values TREE FAILURES).

TREE is NIL when FAILURES is non-empty and DEV is false -- a candidate tree with a failure in
it is not a tree, and returning a partial one would put the all-or-nothing decision at the
call site where every caller would have to make it again.

INDEX-EXTRA says how much of each document's structured front-matter is searchable: T for
every string leaf (the default), NIL for none, or a list of `extra' keys. The default is
everything because of what the first real content tree measured -- see %EXTRA-TEXT above: a body-only index returned zero hits for words that were in the
document, in front-matter, where this content keeps its prose.

DEV is ADR-0001's documented exception: the bad file is skipped, its failure is still
reported, and the rest is published. Someone editing wants to see the rest of the page they
are working on, and no reader is affected. It defaults to the dev-mode flag rather than
taking a separate one, so there is one answer to `am I in dev' in this system.

NOTHING IS PUBLISHED HERE. This function reads and validates; PUBLISH is what makes a tree
live, and keeping them apart is what makes the swap atomic."
  (let ((documents '())
        (failures '()))
    (dolist (path (content-files directory))
      (let ((key (%key-for path directory)))
        (handler-case (push (load-document path :key key :known-extra known-extra) documents)
          (error (e)
            (push (%make-load-failure :file key
                                      :reason (princ-to-string e))
                  failures)))))
    (setf documents (nreverse documents)
          failures (nreverse failures))
    ;; The tree-level pass. It runs over what LOADED, so in dev mode it validates what dev
    ;; mode would publish rather than what it skipped.
    (setf failures (append failures (%duplicate-slug-failures documents)))
    (if (and failures (not dev))
        (values nil failures)
        (let ((tree (%make-content-tree
                     :source (uiop:ensure-directory-pathname directory)
                     :order (mapcar #'document-key documents)
                     :index (%build-index documents index-extra)
                     :loaded-at (get-universal-time)
                     :warnings (append (loop for d in documents
                                             append (content-meta-warnings (document-meta d)))
                                       (loop for f in failures
                                             collect (format nil "~A: ~A (skipped: dev mode)"
                                                             (load-failure-file f)
                                                             (load-failure-reason f)))))))
          (dolist (d documents)
            (setf (gethash (document-key d) (content-tree-documents tree)) d))
          (values tree failures)))))

;;; --- reading a published tree -----------------------------------------------

(defun tree-document (tree key)
  "The document KEY names, or NIL."
  (and tree (gethash key (content-tree-documents tree))))

(defun tree-documents (tree)
  "Every document, in key order. Deterministic, because a listing that reorders itself
between two reloads of the same content is a diff nobody made."
  (if (null tree)
      '()
      (loop for key in (content-tree-order tree)
            collect (gethash key (content-tree-documents tree)))))

(defun tree-readable-documents (tree &key now)
  "The documents a reader may see: drafts and future-dated posts filtered by the same
request-time rule VISIBILITY states, so scheduling stays a property of the request rather
than of the load."
  (remove-if-not (lambda (d)
                   (let ((meta (document-meta d)))
                     (readable-p :draft (content-meta-draft meta)
                                 :publish-at (content-meta-publish-at meta)
                                 :now now)))
                 (tree-documents tree)))

;;; --- the live site ----------------------------------------------------------

(defstruct (site (:constructor %make-site) (:copier nil))
  "A live content site: where its content is, and which tree is currently published.

The TREE slot is the only mutable thing in this file, and it holds a whole immutable tree.
That is the atomicity guarantee: one SETF publishes, one read consumes."
  (directory nil)
  (tree nil)
  (known-extra '() :type list))

(defun make-site (directory &key known-extra)
  "A site over DIRECTORY, with nothing published yet.

KNOWN-EXTRA names the front-matter keys this site expects outside klio's typed core. A key
outside both is reported as a warning naming the file and the key -- so a site declares its
own vocabulary once, here, instead of every document's `organisation' being reported as a
surprise on every load."
  (%make-site :directory directory :known-extra known-extra))

(defun publish (site tree)
  "Make TREE the site's published content. One SETF; returns TREE."
  (setf (site-tree site) tree))

(defun boot (site)
  "Load and publish SITE's content for the first time.

Signals CONTENT-LOAD-FAILED with phase :BOOT if any file fails -- which is ADR-0001's rule at
boot, where `do not swap' has only one meaning because there is nothing to keep serving.
Refusing to start is louder than starting without a page, and at boot someone is watching."
  (multiple-value-bind (tree failures)
      (load-tree (site-directory site) :known-extra (site-known-extra site))
    (when (and failures (null tree))
      (error 'content-load-failed :failures failures :phase :boot
                                  :source (site-directory site)))
    (publish site tree)
    tree))

(defun reload (site)
  "Reload SITE's content. Returns (values OUTCOME REPORT).

OUTCOME is :PUBLISHED or :REFUSED, a keyword rather than a boolean because the two are
different events and a caller reading `NIL' has to go and find out which one it had. On
:REFUSED the site keeps serving the tree it already had -- untouched, because the swap is the
last step and it does not happen.

REPORT is the list of LOAD-FAILUREs, which is what a deploy prints.

IT RETURNS RATHER THAN SIGNALS, so a long-running server can reload on a file-watch without a
handler at every site. THAT IS ALSO ITS HAZARD: a caller who ignores the outcome has built
the silent partial deploy ADR-0001 exists to prevent, one level up. A deploy path should call
RELOAD-OR-FAIL."
  (multiple-value-bind (tree failures)
      (load-tree (site-directory site) :known-extra (site-known-extra site))
    (cond ((and failures (null tree))
           (values :refused failures))
          (t
           (publish site tree)
           (values :published failures)))))

(defun reload-or-fail (site)
  "RELOAD, signalling CONTENT-LOAD-FAILED (phase :RELOAD) when the tree was refused.

THE ENTRY POINT A DEPLOY CALLS, and the reason it exists is ADR-0001's first consequence: a
reload that reports errors has to be a FAILED DEPLOY. A script that pulls, reloads, prints
the error and exits zero has reintroduced the silent partial deploy somewhere the ADR cannot
see. A returned value can be dropped by forgetting to check it; an unhandled condition exits
non-zero on its own, which is the behaviour a deploy script gets for free rather than the one
it has to remember."
  (multiple-value-bind (outcome report) (reload site)
    (when (eq outcome :refused)
      (error 'content-load-failed :failures report :phase :reload
                                  :source (site-directory site)))
    (values outcome report)))
