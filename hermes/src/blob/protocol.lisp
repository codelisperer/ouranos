;;;; protocol.lisp --- the neutral blob-store protocol.
;;;;
;;;; The seam. A STORE is a class; the operations are generics over it, so adding a
;;;; provider is a new class plus one REGISTER-STORE -- never a new API. Same shape as
;;;; hermes' PROVIDER/DELIVER and mnemosyne's own backend split.
;;;;
;;;; Two things are deliberately implemented HERE rather than per backend, because "every
;;;; backend remembers to do it" is not a property a protocol can have:
;;;;
;;;;   1. KEY VALIDATION, in :BEFORE methods on the base class. A backend cannot forget
;;;;      it, and the filesystem backend -- where a `..' is a traversal rather than a
;;;;      404 -- cannot be the only one that checks.
;;;;   2. STREAMING + DIGEST, in %COPY-STREAM-WITH-DIGEST. Every backend needs the same
;;;;      "never hold the whole file in memory, and checksum it on the way past" loop,
;;;;      and a second copy of it is a second chance to buffer the lot by accident.

(cl:in-package #:hermes/blob)

;;; --- what a row should hold ------------------------------------------------

(defstruct (blob-meta (:constructor make-blob-meta (key size content-type checksum
                                                   &optional last-modified)))
  "Everything about a blob EXCEPT its bytes -- i.e. exactly what belongs in a database
row. The bytes are referenced by (bucket, KEY) and never embedded.

CHECKSUM is the lowercase hex SHA-256 of the content, computed on the way past during
PUT-BLOB, so it costs nothing extra and is available to store alongside the row."
  (key nil :type (or null string))
  (size 0 :type (or null integer))
  (content-type nil :type (or null string))
  (checksum nil :type (or null string))
  (last-modified nil :type (or null integer)))

;;; --- the store protocol ----------------------------------------------------

(defclass store () ()
  (:documentation "Abstract base for anything that can hold blobs."))

(defgeneric store-name (store)
  (:documentation "A short backend name, for logs and errors."))

(defgeneric put-blob (store bucket key stream &key content-type metadata)
  (:documentation
   "Stream the bytes of STREAM (an octet input stream) into STORE at BUCKET/KEY.

Returns a BLOB-META describing what was written. Overwrites an existing blob. METADATA is
an alist of string->string carried alongside the object where the backend supports it.

The stream is consumed but NOT closed -- the caller opened it and owns it."))

(defgeneric get-blob (store bucket key)
  (:documentation
   "An octet input stream over the blob at BUCKET/KEY. The CALLER MUST CLOSE IT; prefer
WITH-BLOB-STREAM, which cannot leak it. Signals BLOB-NOT-FOUND if there is no such blob."))

(defgeneric delete-blob (store bucket key)
  (:documentation
   "Remove the blob at BUCKET/KEY. Idempotent: deleting a blob that is not there
succeeds, because the caller's intent -- that it not be there -- already holds."))

(defgeneric blob-exists-p (store bucket key)
  (:documentation "True if a blob exists at BUCKET/KEY."))

(defgeneric blob-metadata (store bucket key)
  (:documentation
   "The BLOB-META for BUCKET/KEY without fetching the bytes. Signals BLOB-NOT-FOUND."))

(defgeneric blob-url (store bucket key &key expires-in)
  (:documentation
   "A URL for BUCKET/KEY.

EXPIRES-IN is seconds; when non-NIL the URL is SIGNED and stops working when it expires.
When NIL the store must be configured public, and the URL is permanent and unauthenticated
-- so NIL is a decision about the blob, not a convenience default, and a store with no
public base URL signals BLOB-UNSUPPORTED rather than inventing one."))

(defgeneric list-blobs (store bucket &key prefix)
  (:documentation
   "The keys under PREFIX in BUCKET, as a list of strings. Used by SWEEP-ORPHANS.

Backends page internally; the whole list is returned. A bucket large enough for that to
matter wants a streaming variant, which is a later problem and a different signature."))

;;; --- validation at the seam ------------------------------------------------
;;;
;;; :BEFORE on the base class, so every current and future backend inherits it. This is
;;; the whole reason key validation lives in the shared Coalton core rather than in the
;;; filesystem backend that needs it most.

(defun %check-bucket (bucket)
  "Signal unless BUCKET is a usable bucket name."
  (unless (and (stringp bucket) (plusp (length bucket))
               (not (find #\/ bucket)) (not (find #\\ bucket)))
    (error 'blob-invalid-key :bucket bucket
                             :fault "a bucket name may not be empty or contain a separator")))

(defun %check-key (bucket key)
  "Signal BLOB-INVALID-KEY unless KEY is well-formed. The single gate every operation
passes through."
  (%check-bucket bucket)
  (unless (and (stringp key) (k:blob-key-ok? key))
    (error 'blob-invalid-key
           :bucket bucket :key key
           :fault (if (stringp key)
                      (k:blob-key-fault-message key)
                      "a blob key must be a string"))))

(defmethod put-blob :before ((s store) bucket key stream &key content-type metadata)
  (declare (ignore stream content-type metadata))
  (%check-key bucket key))

(defmethod get-blob :before ((s store) bucket key) (%check-key bucket key))
(defmethod delete-blob :before ((s store) bucket key) (%check-key bucket key))
(defmethod blob-exists-p :before ((s store) bucket key) (%check-key bucket key))
(defmethod blob-metadata :before ((s store) bucket key) (%check-key bucket key))

(defmethod blob-url :before ((s store) bucket key &key expires-in)
  (declare (ignore expires-in))
  (%check-key bucket key))

(defmethod list-blobs :before ((s store) bucket &key prefix)
  (declare (ignore prefix))
  (%check-bucket bucket))

;;; --- streaming + digest, implemented once ----------------------------------

(defconstant +copy-buffer-size+ 65536
  "Bytes per read. Large enough that syscall overhead is irrelevant, small enough that a
concurrent upload burst does not decide the image's heap size.")

(defun %copy-stream-with-digest (in out)
  "Copy IN to OUT in bounded chunks, returning (values byte-count hex-sha256).

OUT may be NIL, in which case the bytes are digested and discarded -- which is how a
backend that must know the length and checksum BEFORE it can send (S3 signs the payload
hash) spools without ever holding the object in memory.

The point of this function is that no backend is ever tempted to write the obvious
READ-SEQUENCE-the-whole-thing version."
  (let ((buf (make-array +copy-buffer-size+ :element-type '(unsigned-byte 8)))
        (digest (ironclad:make-digest :sha256))
        (total 0))
    (loop for n = (read-sequence buf in)
          while (plusp n)
          do (ironclad:update-digest digest buf :start 0 :end n)
             (when out (write-sequence buf out :start 0 :end n))
             (incf total n))
    (values total (ironclad:byte-array-to-hex-string
                   (ironclad:produce-digest digest)))))

(defmacro with-blob-stream ((var store bucket key) &body body)
  "Bind VAR to an octet input stream over BUCKET/KEY for the duration of BODY, closing it
however BODY leaves.

GET-BLOB hands back a live stream, and an app that forgets to close it leaks a file
descriptor per view -- which shows up as a server that dies under load rather than as a
bug at the call site. Prefer this."
  (let ((s (gensym "STREAM")))
    `(let ((,s (get-blob ,store ,bucket ,key)))
       (unwind-protect (let ((,var ,s)) ,@body)
         (close ,s)))))

;;; --- the registry + environment selection ----------------------------------
;;;
;;; MNEMOSYNE_BLOB_IMPL picks the backend (default "filesystem" -- the one that needs no
;;; cloud account, so a fresh checkout and the test suite work with no configuration).

(defvar *stores* (make-hash-table :test #'equal)
  "Map of backend name -> a thunk returning a fresh STORE.")

(defvar *store* nil
  "The process-wide store, if the app has chosen to bind one. STORE-FROM-ENV consults it
first, so a test can bind it and an app can set it at boot without threading a store
through every call.")

(defun register-store (name constructor)
  "Register CONSTRUCTOR (a thunk returning a fresh STORE) under NAME. Returns NAME."
  (setf (gethash (string-downcase name) *stores*) constructor)
  name)

(defun store-from-env ()
  "The store named by MNEMOSYNE_BLOB_IMPL (default \"filesystem\"), or *STORE* if bound."
  (or *store*
      (let* ((name (string-downcase (or (uiop:getenv "MNEMOSYNE_BLOB_IMPL") "filesystem")))
             (ctor (gethash name *stores*)))
        (unless ctor
          (error 'blob-configuration-error
                 :missing (format nil "no blob store registered under ~S (set MNEMOSYNE_BLOB_IMPL)"
                                  name)))
        (funcall ctor))))

;;; --- orphan reconciliation -------------------------------------------------

(defun sweep-orphans (store bucket claimed-p &key prefix dry-run)
  "Delete every blob under PREFIX in BUCKET that CLAIMED-P does not claim.

Bytes live outside the database transaction, so they can always outlive the row that
referenced them (a failed insert after a successful upload) or predate one (an upload
whose request died). That is inherent to storing bytes anywhere but in the row, not a flaw
in a particular backend -- so the reconciliation belongs here, once, rather than in every
app that will otherwise invent it badly.

CLAIMED-P is called with one key and returns true if something still references it. It is
a REQUIRED POSITIONAL argument, deliberately: as a keyword it could be omitted, and an
absent predicate would mean `nothing is claimed', which deletes the entire bucket. The
dangerous call must not be the short one.

Returns (values deleted-keys examined-count). With DRY-RUN, reports what it would delete
and deletes nothing -- run it that way first."
  (check-type claimed-p (or function symbol))
  (let ((keys (list-blobs store bucket :prefix prefix))
        (deleted '()))
    (dolist (key keys)
      ;; An error from the app's predicate must not be read as "unclaimed". Deleting user
      ;; media because a lookup timed out is exactly the failure this sweep exists to
      ;; avoid causing, so it propagates and the sweep stops.
      (unless (funcall claimed-p key)
        (unless dry-run (delete-blob store bucket key))
        (push key deleted)))
    (let ((deleted (nreverse deleted)))
      (log:info "blob sweep" :backend (store-name store) :bucket bucket
                             :examined (length keys) :orphans (length deleted)
                             :dry-run (and dry-run t))
      (values deleted (length keys)))))
