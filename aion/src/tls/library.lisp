;;;; library.lisp --- find and load our mbedTLS, and prove it is the library this code was
;;;; written against.
;;;;
;;;; Search order, most specific first, the same as aion/uv's (hyperion ADR-0013):
;;;;   1. AION_TLS_LIBRARY        -- an explicit path. Always wins.
;;;;   2. beside the running image -- how a shipped bundle carries its own copy.
;;;;   3. vendor/mbedtls/lib/...  -- what scripts/build-mbedtls.lisp produced.
;;;;   4. the bare soname          -- left to the OS loader.
;;;;
;;;; A LIBRARY THAT LOADS IS NOT YET THE RIGHT LIBRARY. A system mbedTLS found at step 4
;;;; loads, and has none of our C; one built before ouranos_tls.c changed has an older
;;;; version of it; one built without ouranos_tls_config.h has threading off, which makes
;;;; PSA unsafe from two threads. So after loading, the shim's version and threading kind
;;;; are checked, and a library that fails either is refused with MBEDTLS-MISMATCH, naming
;;;; the file.
;;;;
;;;; LOADING NEVER HAPPENS AT LOAD TIME, as in aion/uv (ADR-0011's lesson). The first call
;;;; that needs the library loads it.

(in-package #:aion/tls)

(defconstant +shim-version+ 2
  "The version of aion/src/tls/c/ouranos_tls.c this code was written against. The loaded
library's ouranos_tls_shim_version must return exactly this.")

(defparameter *library-names*
  #+darwin  '("libmbedtls.1.dylib")
  #+windows '("mbedtls.dll")
  #-(or darwin windows) '("libmbedtls.so.1")
  "The file build-mbedtls.lisp writes on this platform. One name, because the library we
build is one file carrying mbedTLS, its crypto and our C together.")

(defvar *library* nil "The CFFI library object, or NIL. What UNLOAD-MBEDTLS closes.")
(defvar *path* nil "The namestring of the loaded library, or NIL.")
(defvar *load-lock* (sb-thread:make-mutex :name "aion/tls load"))

(define-condition mbedtls-not-found (error)
  ((searched :initarg :searched :reader mbedtls-not-found-searched)
   (reason :initarg :reason :initform nil :reader mbedtls-not-found-reason))
  (:report
   (lambda (c stream)
     (format stream "Could not load the mbedTLS library aion/tls needs.~%~%Searched:~%")
     (dolist (place (mbedtls-not-found-searched c)) (format stream "  ~A~%" place))
     (when (mbedtls-not-found-reason c)
       (format stream "~%Last error: ~A~%" (mbedtls-not-found-reason c)))
     (format stream "~%Build it from mbedtls.pin (needs only a C compiler):~%  sbcl --script scripts/build-mbedtls.lisp~%~%Or point AION_TLS_LIBRARY at one.~%")))
  (:documentation "Signalled on first use when no candidate library could be loaded."))

(define-condition mbedtls-mismatch (error)
  ((path :initarg :path :reader mbedtls-mismatch-path)
   (reason :initarg :reason :reader mbedtls-mismatch-reason))
  (:report
   (lambda (c stream)
     (format stream "The library at ~A loaded, but it is not one aion/tls can use: ~A~%Rebuild it with sbcl --script scripts/build-mbedtls.lisp --force."
             (mbedtls-mismatch-path c) (mbedtls-mismatch-reason c))))
  (:documentation "Signalled when a library loads but is not the build this code expects."))

(defun %image-directory ()
  "The directory of the running executable, from SB-EXT:*RUNTIME-PATHNAME* (see aion/uv's
%IMAGE-DIRECTORY for why not argv0). The same duplication ADR-0013 records for aion/uv."
  (flet ((dir-of (p)
           (when p
             (uiop:pathname-directory-pathname
              (uiop:ensure-absolute-pathname p #'uiop:getcwd nil)))))
    (or (ignore-errors (dir-of sb-ext:*runtime-pathname*))
        (ignore-errors (dir-of (uiop:argv0))))))

(defun %candidates ()
  "Every path LOAD-MBEDTLS tries, in order."
  (let ((explicit (uiop:getenv "AION_TLS_LIBRARY"))
        (image (%image-directory))
        (root (ignore-errors
               (uiop:pathname-parent-directory-pathname
                (asdf:system-source-directory :aion)))))
    (append (when (and explicit (plusp (length explicit))) (list explicit))
            (when image
              (mapcar (lambda (n) (namestring (merge-pathnames n image))) *library-names*))
            (when root
              (mapcar (lambda (n)
                        (namestring (merge-pathnames (concatenate 'string "vendor/mbedtls/lib/" n)
                                                     root)))
                      *library-names*))
            *library-names*)))

(defun %library-defines-p (path name)
  "Whether the shared library loaded from PATH itself defines the symbol NAME.

Not CFFI:FOREIGN-SYMBOL-POINTER, which on SBCL ignores its library argument and searches
every loaded library (cffi-sbcl.lisp's %FOREIGN-SYMBOL-POINTER). With our mbedTLS already
in the process, it would find our symbol and pass a system mbedTLS that has none, which is
the case this check exists for. So this asks the one library, through SBCL's handle for it:
dlsym on Linux and macOS, GetProcAddress on Windows, which is what SB-ALIEN::DLSYM calls."
  (let* ((truename (ignore-errors (truename path)))
         (object (find-if (lambda (o)
                            (let ((file (ignore-errors (truename (sb-alien::shared-object-namestring o)))))
                              (if truename
                                  (equal file truename)
                                  (equal (sb-alien::shared-object-namestring o) path))))
                          sb-alien::*shared-objects*))
         (handle (and object (sb-alien::shared-object-handle object)))
         (address (and handle (sb-alien::dlsym handle name))))
    (and address (not (zerop (sb-sys:sap-int address))))))

(defun %check-build (path)
  "Refuse the library just loaded from PATH unless it is our build, then initialise it.
The order is mbedTLS's own: ouranos_tls_setup, which registers the Windows threading
functions, before any other mbedTLS call, and psa_crypto_init before any TLS or crypto."
  (flet ((refuse (reason)
           (ignore-errors (cffi:close-foreign-library *library*))
           (setf *library* nil *path* nil)
           (error 'mbedtls-mismatch :path path :reason reason)))
    (unless (%library-defines-p path "ouranos_tls_shim_version")
      (refuse "it has no ouranos_tls_shim_version, so it was not built by scripts/build-mbedtls.lisp"))
    (let ((version (%shim-version)))
      (unless (= version +shim-version+)
        (refuse (format nil "its C shim is version ~D and this code needs version ~D"
                        version +shim-version+))))
    (when (zerop (%threading-kind))
      (refuse "it was built with threading off, so its crypto is not safe to use from two threads"))
    (%setup)
    (let ((status (%psa-crypto-init)))
      (unless (zerop status)
        (refuse (format nil "psa_crypto_init returned ~D" status))))))

(defun load-mbedtls (&key force)
  "Load our mbedTLS, trying each candidate in turn, check it, and initialise it. Returns
the path loaded. Signals MBEDTLS-NOT-FOUND if nothing loads, and MBEDTLS-MISMATCH if what
loads is not our build. Idempotent unless FORCE."
  (sb-thread:with-recursive-lock (*load-lock*)
    (when (and *library* (not force))
      (return-from load-mbedtls *path*))
    (let ((tried '()) (last-error nil))
      (dolist (candidate (%candidates))
        (push candidate tried)
        (when (let ((path-like (or (find #\/ candidate) (find #\\ candidate))))
                (or (not path-like) (probe-file candidate)))
          (let ((library (handler-case (cffi:load-foreign-library candidate)
                           (error (e) (setf last-error e) nil))))
            (when library
              (setf *library* library *path* candidate)
              (%check-build candidate)
              (return-from load-mbedtls candidate)))))
      (error 'mbedtls-not-found :searched (nreverse tried) :reason last-error))))

(defun unload-mbedtls ()
  "Close the library, so a dumped image opens its own carried copy instead of reopening the
build machine's path at startup (ADR-0013). For the bundler; errors are not suppressed, for
the reason aion/uv's UNLOAD-LIBUV gives."
  (sb-thread:with-recursive-lock (*load-lock*)
    (when *library*
      (cffi:close-foreign-library *library*)
      (setf *library* nil *path* nil)))
  (values))

(defun mbedtls-loaded-p () (and *library* t))
(defun mbedtls-path () *path*)

(defun ensure-loaded ()
  "Load the library on first use. Every entry point calls this."
  (or *path* (load-mbedtls)))
