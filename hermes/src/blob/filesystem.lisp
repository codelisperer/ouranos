;;;; filesystem.lisp --- the local-disk blob backend.
;;;;
;;;; The backend that needs no cloud account: the default, so a fresh checkout, the test
;;;; suite and `cons repl' all work with zero configuration. Also the right answer for a
;;;; single-box deployment.
;;;;
;;;; Layout, per bucket:
;;;;
;;;;   <root>/<bucket>/objects/<key>   the bytes
;;;;   <root>/<bucket>/meta/<key>      a sidecar naming content-type, size, checksum
;;;;   <root>/<bucket>/.tmp/<uuid>     partial writes, never visible under objects/
;;;;
;;;; Metadata lives in a PARALLEL TREE rather than in `<key>.meta' beside the object, so
;;;; that LIST-BLOBS -- and therefore SWEEP-ORPHANS -- walks only real objects. A sidecar
;;;; sharing the objects tree would be listed as a blob, found unclaimed, and deleted, and
;;;; the sweep would eat its own bookkeeping.

(cl:in-package #:hermes/blob)

(defclass filesystem-store (store)
  ((root :initarg :root :reader filesystem-store-root
         :documentation "Directory pathname under which every bucket lives.")
   (base-url :initarg :base-url :initform nil :reader filesystem-store-base-url
             :documentation
             "Public URL prefix this root is served from, or NIL if it is not served at
all. Only a store that HAS one can answer BLOB-URL."))
  (:documentation "A blob store backed by a directory on local disk."))

(defun make-filesystem-store (&key root base-url)
  "A FILESYSTEM-STORE under ROOT (default $MNEMOSYNE_BLOB_ROOT, else ./blobs/).

BASE-URL, if given, is the public prefix ROOT is served from -- without it the store
cannot produce a URL and says so, rather than guessing at one that 404s."
  (let ((root (or root (uiop:getenv "MNEMOSYNE_BLOB_ROOT") "blobs/")))
    (make-instance 'filesystem-store
                   :root (uiop:ensure-directory-pathname root)
                   :base-url (or base-url (uiop:getenv "MNEMOSYNE_BLOB_BASE_URL")))))

(register-store "filesystem" #'make-filesystem-store)

(defmethod store-name ((s filesystem-store)) "filesystem")

;;; --- paths -----------------------------------------------------------------

(defun %bucket-dir (store bucket subtree)
  (uiop:ensure-directory-pathname
   (merge-pathnames (format nil "~A/~A/" bucket subtree)
                    (filesystem-store-root store))))

(defun %blob-path (store bucket key subtree)
  "The absolute path for KEY under BUCKET's SUBTREE (\"objects\" or \"meta\").

KEY has already passed MNEMOSYNE/BLOB-KEY validation at the seam, so it cannot contain a
`..' segment. The containment assertion below is therefore redundant -- and stays anyway,
because it is the difference between a traversal bug being impossible and it being
impossible ONLY as long as two files agree. It costs one string compare per operation."
  (let* ((base (%bucket-dir store bucket subtree))
         (path (merge-pathnames (uiop:parse-unix-namestring key) base))
         (base-ns (namestring (uiop:ensure-absolute-pathname base *default-pathname-defaults*)))
         (path-ns (namestring (uiop:ensure-absolute-pathname path *default-pathname-defaults*))))
    (unless (and (>= (length path-ns) (length base-ns))
                 (string= base-ns path-ns :end2 (length base-ns)))
      (error 'blob-invalid-key :bucket bucket :key key
                               :fault "the key does not resolve inside its bucket"))
    path))

;;; --- the metadata sidecar --------------------------------------------------
;;; Deliberately a trivial `field: value' text file. It is written and read only here,
;;; it must survive being looked at with `cat' during an incident, and a serialization
;;; dependency for four fields would be a dependency we would then have to justify.

(defun %write-meta (path meta metadata)
  (uiop:ensure-all-directories-exist (list path))
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create :external-format :utf-8)
    (format out "content-type: ~A~%" (or (blob-meta-content-type meta) ""))
    (format out "size: ~D~%" (blob-meta-size meta))
    (format out "checksum: ~A~%" (or (blob-meta-checksum meta) ""))
    (format out "last-modified: ~D~%" (or (blob-meta-last-modified meta) 0))
    (loop for (mk . mv) in metadata
          do (format out "x-~A: ~A~%" mk mv))))

(defun %read-meta (path key)
  "The BLOB-META recorded at PATH, or NIL if there is no sidecar."
  (when (probe-file path)
    (let ((fields '()))
      (with-open-file (in path :external-format :utf-8)
        (loop for line = (read-line in nil nil)
              while line
              do (let ((colon (position #\: line)))
                   (when colon
                     (push (cons (subseq line 0 colon)
                                 (string-left-trim " " (subseq line (1+ colon))))
                           fields)))))
      (flet ((field (name) (cdr (assoc name fields :test #'string=))))
        (let ((ct (field "content-type"))
              (sum (field "checksum")))
          (make-blob-meta key
                          (or (ignore-errors (parse-integer (or (field "size") "0"))) 0)
                          (if (and ct (plusp (length ct))) ct nil)
                          (if (and sum (plusp (length sum))) sum nil)
                          (ignore-errors (parse-integer (or (field "last-modified") "0")))))))))

;;; --- operations ------------------------------------------------------------

(defmethod put-blob ((s filesystem-store) bucket key stream &key content-type metadata)
  (let* ((final (%blob-path s bucket key "objects"))
         (meta-path (%blob-path s bucket key "meta"))
         (tmp (merge-pathnames (format nil "~A" (clock:new-id)) (%bucket-dir s bucket ".tmp")))
         (size 0) (checksum nil) (committed nil))
    (uiop:ensure-all-directories-exist (list tmp final meta-path))
    ;; Write to .tmp and RENAME. A reader concurrent with an upload must see either the
    ;; old object or the new one, never a half-written one -- and a crash mid-upload must
    ;; leave nothing under objects/ for the sweep to find and puzzle over. Rename within
    ;; one filesystem is the only step here that is atomic, so it is the one that publishes.
    (unwind-protect
         (progn
           (with-open-file (out tmp :direction :output :element-type '(unsigned-byte 8)
                                    :if-exists :supersede :if-does-not-exist :create)
             (multiple-value-setq (size checksum)
               (%copy-stream-with-digest stream out)))
           (uiop:rename-file-overwriting-target tmp final)
           (setf committed t))
      (unless committed (uiop:delete-file-if-exists tmp)))
    (let ((meta (make-blob-meta key size content-type checksum (get-universal-time))))
      (%write-meta meta-path meta metadata)
      (log:debug "blob put" :backend "filesystem" :bucket bucket :bytes size)
      meta)))

(defmethod get-blob ((s filesystem-store) bucket key)
  (let ((path (%blob-path s bucket key "objects")))
    (unless (probe-file path)
      (error 'blob-not-found :bucket bucket :key key))
    (open path :element-type '(unsigned-byte 8))))

(defmethod delete-blob ((s filesystem-store) bucket key)
  ;; Idempotent by DELETE-IF-EXISTS: the caller wants the blob gone, and it being gone
  ;; already is that outcome, not a failure.
  (uiop:delete-file-if-exists (%blob-path s bucket key "objects"))
  (uiop:delete-file-if-exists (%blob-path s bucket key "meta"))
  t)

(defmethod blob-exists-p ((s filesystem-store) bucket key)
  (and (probe-file (%blob-path s bucket key "objects")) t))

(defmethod blob-metadata ((s filesystem-store) bucket key)
  (let ((path (%blob-path s bucket key "objects")))
    (unless (probe-file path)
      (error 'blob-not-found :bucket bucket :key key))
    (or (%read-meta (%blob-path s bucket key "meta") key)
        ;; No sidecar: the bytes are still perfectly good, so report what the filesystem
        ;; itself knows rather than pretending the blob is absent.
        (make-blob-meta key
                        (with-open-file (in path :element-type '(unsigned-byte 8))
                          (file-length in))
                        nil nil (file-write-date path)))))

(defmethod blob-url ((s filesystem-store) bucket key &key expires-in)
  (let ((base (filesystem-store-base-url s)))
    (when expires-in
      ;; A local directory has nothing that could VERIFY a signature -- whatever serves it
      ;; would have to, and that server is not this store. Returning an unsigned URL here
      ;; would silently turn a private blob public, which is the failure mode this whole
      ;; module exists to prevent.
      (error 'blob-unsupported :bucket bucket :key key
                               :operation "expiring URLs (the filesystem store cannot sign)"))
    (unless (and base (plusp (length base)))
      (error 'blob-unsupported :bucket bucket :key key
                               :operation "URLs (no :base-url configured for this store)"))
    (let ((sep (if (eql #\/ (char base (1- (length base)))) "" "/")))
      (format nil "~A~A~A/~A" base sep bucket key))))

(defmethod list-blobs ((s filesystem-store) bucket &key prefix)
  ;; A KEY IS PROTOCOL, not an implementation detail. S3 keys are `/'-separated by
  ;; definition, so a key this backend invents with a `\' would mean the two backends
  ;; disagree about what a key IS: the same app would produce different keys depending on
  ;; which store it points at, and a key written on Windows would not match one written on
  ;; Linux. That is a neutral-protocol violation, and it surfaced as a sweep bug.
  ;;
  ;; This used to slice the child's NAMESTRING at (length root-ns), which assumes the two
  ;; strings share a prefix. TWO ways that is false on Windows, and the second is not
  ;; obvious:
  ;;   - the separator differs (`a\orphan.txt' is not the key `a/orphan.txt'), and
  ;;   - the root and the listing can spell the SAME directory differently. A GitHub
  ;;     Windows runner sets TEMP to the 8.3 SHORT form (C:\Users\RUNNER~1\...) while
  ;;     DIRECTORY-FILES answers with the long one, so the slice happened at the wrong
  ;;     OFFSET and every key came back with a piece of the absolute path glued on.
  ;;
  ;; So: never subtract strings. PROBE-FILE gives the root's truename, which settles the
  ;; short/long spelling; ENOUGH-PATHNAME relativises structurally; UNIX-NAMESTRING renders
  ;; the one separator a key is allowed to contain.
  (let ((root (probe-file (%bucket-dir s bucket "objects")))
        (keys '()))
    (labels ((walk (dir)
               (dolist (f (uiop:directory-files dir))
                 (let ((rel (uiop:enough-pathname f root)))
                   ;; ENOUGH-PATHNAME returns F unchanged when it cannot relativise. That
                   ;; is an absolute path, never a key -- drop it rather than publish it.
                   (when (uiop:relative-pathname-p rel)
                     (push (uiop:unix-namestring rel) keys))))
               (dolist (d (uiop:subdirectories dir)) (walk d))))
      (when root (walk root)))
    (let ((keys (sort keys #'string<)))
      (if prefix
          (remove-if-not (lambda (key)
                           (and (>= (length key) (length prefix))
                                (string= prefix key :end2 (length prefix))))
                         keys)
          keys))))
