;;;; packages.lisp --- Mnemosyne blob-store package definitions.
;;;;
;;;; Package-per-module, as everywhere else in the tree:
;;;;   hermes/blob-key -- the typed, IO-free core (Coalton): what a KEY may be, and
;;;;                         whether a blob is private or public.
;;;;   hermes/blob     -- the effectful shell (CL): the neutral store protocol, the
;;;;                         filesystem and S3-compatible backends, and the sweep.
;;;;
;;;; These live in the `hermes/blob' AUX system rather than in mnemosyne core, so that
;;;; the S3 backend's HTTP dependency is not on the load path of every image that merely
;;;; touches a database. Same doctrine as core's refusal to depend on cl+ssl.

;;; --- the typed core (Coalton) --------------------------------------------
(cl:defpackage #:hermes/blob-key
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:str #:coalton-library/string)
                    (#:char #:coalton-library/char)
                    (#:list #:coalton-library/list)
                    (#:iter #:coalton-library/iterator))
  (:documentation
   "The IO-free core of the blob store: the KEY vocabulary and the private/public
    distinction. A key names a byte-range in someone else's storage and is very often
    built from user input, so what a key may be is a type question and not a matter of
    each backend's care. No IO -- put/get/delete live in the CL shell.")
  (:export
   ;; why a key was rejected -- an ADT, so the caller can branch on the reason
   #:Key-Fault #:Key-Empty #:Key-Too-Long #:Key-Absolute #:Key-Trailing-Slash
   #:Key-Dot-Segment #:Key-Empty-Segment #:Key-Backslash #:Key-Bad-Char
   #:key-fault-message #:max-key-length
   #:validate-blob-key
   ;; CL-facing boundary (monomorphic wrappers)
   #:blob-key-ok? #:blob-key-fault-message
   ;; visibility: an ADT rather than a boolean, because the two differ in what URL
   ;; they can produce, not merely in a flag
   #:Blob-Visibility #:Blob-Private #:Blob-Public
   #:blob-visibility-name #:blob-visibility-public? #:parse-blob-visibility
   #:blob-visibility-or-private))

;;; --- the effectful shell (CL) --------------------------------------------
(cl:defpackage #:hermes/blob
  (:use #:cl)
  (:local-nicknames (#:k #:hermes/blob-key)
                    (#:clock #:aion/clock)
                    (#:log #:aion/log))
  (:documentation
   "The neutral blob-store protocol and its backends. Bytes live in object storage; rows
    hold metadata and a storage key, never the bytes. STORE is a class, and PUT-BLOB /
    GET-BLOB / DELETE-BLOB / BLOB-EXISTS-P / BLOB-METADATA / BLOB-URL / LIST-BLOBS are
    generics over it, so a new provider is a new class and one REGISTER-STORE.")
  (:export
   ;; conditions -- the failure protocol
   #:blob-error #:blob-error-bucket #:blob-error-key
   #:blob-not-found #:blob-invalid-key #:blob-invalid-key-fault
   #:blob-backend-error #:blob-backend-error-status #:blob-backend-error-detail
   #:blob-configuration-error #:blob-configuration-error-missing
   #:blob-unsupported #:blob-unsupported-operation
   ;; the store protocol
   #:store #:store-name
   #:put-blob #:get-blob #:delete-blob #:blob-exists-p #:blob-metadata #:blob-url
   #:list-blobs #:with-blob-stream
   ;; blob metadata (what a row should hold)
   #:blob-meta #:make-blob-meta #:blob-meta-p
   #:blob-meta-key #:blob-meta-size #:blob-meta-content-type
   #:blob-meta-checksum #:blob-meta-last-modified
   ;; backend registry + environment selection
   #:register-store #:store-from-env #:*store*
   ;; orphan reconciliation
   #:sweep-orphans
   ;; the backends
   #:filesystem-store #:make-filesystem-store #:filesystem-store-root
   #:s3-store #:make-s3-store))
