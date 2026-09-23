;;;; conditions.lisp --- the blob store's failure protocol.
;;;;
;;;; Recoverable failure via the condition system, not return codes (house style). The
;;;; distinction that matters to a caller is not "did it work" but WHICH of four
;;;; different things went wrong, because each has a different correct response:
;;;;
;;;;   BLOB-NOT-FOUND            -> a 404. Routine, not an error in the app.
;;;;   BLOB-INVALID-KEY          -> a 400. The caller built a bad key; retrying won't help.
;;;;   BLOB-BACKEND-ERROR        -> a 502/503. The provider failed; a retry might work.
;;;;   BLOB-CONFIGURATION-ERROR  -> a crash at boot. A credential is missing.
;;;;
;;;; Collapsing those into NIL (as a return-code design must) forces every caller to
;;;; re-derive the difference from context it does not have.

(cl:in-package #:hermes/blob)

(define-condition blob-error (error)
  ((bucket :initarg :bucket :initform nil :reader blob-error-bucket)
   (key    :initarg :key    :initform nil :reader blob-error-key))
  (:documentation "Base of every blob-store failure. BUCKET and KEY locate it."))

(define-condition blob-not-found (blob-error) ()
  (:report (lambda (c s)
             (format s "no blob at ~A/~A" (or (blob-error-bucket c) "?")
                     (or (blob-error-key c) "?"))))
  (:documentation
   "Nothing is stored under this bucket/key. Expected in normal operation -- a deleted
photo whose row still points at it is this, not a bug."))

(define-condition blob-invalid-key (blob-error)
  ((fault :initarg :fault :initform "" :reader blob-invalid-key-fault))
  (:report (lambda (c s)
             ;; The key itself is deliberately NOT in the report. It is very often
             ;; user-supplied, it can carry a member id, and this text lands in logs --
             ;; so the report names the SHAPE that was wrong and the key stays in the
             ;; slot, reachable by a handler that has somewhere safe to put it.
             (format s "invalid blob key for bucket ~A: ~A"
                     (or (blob-error-bucket c) "?") (blob-invalid-key-fault c))))
  (:documentation
   "The key is not well-formed -- see MNEMOSYNE/BLOB-KEY:KEY-FAULT for the vocabulary.
Signalled at the protocol seam, before any backend sees it."))

(define-condition blob-backend-error (blob-error)
  ((status :initarg :status :initform nil :reader blob-backend-error-status)
   (detail :initarg :detail :initform nil :reader blob-backend-error-detail))
  (:report (lambda (c s)
             ;; DETAIL is NOT in the report, for the same reason the key is not in
             ;; BLOB-INVALID-KEY's: it is the provider's raw error body, it routinely
             ;; quotes the object key back at you, and this text lands in logs -- which
             ;; is precisely what "structured fields, never payloads" forbids. It can
             ;; also be a kilobyte of XML. The status is the part a reader can act on;
             ;; DETAIL stays in the slot for a handler with somewhere safe to put it.
             (format s "blob backend failed~@[ (HTTP ~A)~]"
                     (blob-backend-error-status c))))
  (:documentation
   "The storage provider rejected or failed the request. STATUS is the HTTP status for an
S3-compatible backend and NIL for the filesystem."))

(define-condition blob-configuration-error (blob-error)
  ((missing :initarg :missing :initform nil :reader blob-configuration-error-missing))
  (:report (lambda (c s)
             (format s "blob store is not configured: ~A"
                     (or (blob-configuration-error-missing c) "unknown setting"))))
  (:documentation
   "A credential or setting the backend cannot run without. Signalled when the store is
constructed, not at first use, so a misconfigured deploy fails at boot."))

(define-condition blob-unsupported (blob-error)
  ((operation :initarg :operation :initform nil :reader blob-unsupported-operation))
  (:report (lambda (c s)
             (format s "this blob store does not support ~A"
                     (or (blob-unsupported-operation c) "that operation"))))
  (:documentation
   "The backend cannot do this at all -- e.g. a filesystem store asked for a presigned
URL when no public base URL was configured."))
