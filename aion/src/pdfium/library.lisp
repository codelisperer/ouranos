;;;; library.lisp --- find and load our pdfium, and check it is the library this code binds (#997).
;;;;
;;;; Search order, most specific first, the same as aion/libgit's, aion/uv's and aion/tls's
;;;; (hyperion ADR-0013):
;;;;   1. AION_PDFIUM_LIBRARY     -- an explicit path. Always wins.
;;;;   2. beside the running image -- how a shipped bundle carries its own copy.
;;;;   3. vendor/pdfium/lib/...    -- what scripts/fetch-pdfium.lisp unpacked. Not in a desktop
;;;;                                 bundle, which never searches the tree it was built from
;;;;                                 (AION/PLATFORM:*SEARCH-SOURCE-TREE*, #472).
;;;;   4. the bare file name       -- left to the OS loader.
;;;;
;;;; After loading, a library is refused with PDFIUM-MISMATCH unless every function FFI.LISP
;;;; binds resolves to it: on SBCL a foreign call is looked up across the whole process, so a
;;;; second pdfium loaded first would otherwise take the calls while PDFIUM-PATH named this one.
;;;;
;;;; LOADING NEVER HAPPENS AT LOAD TIME. The first call that needs the library loads it.
;;;;
;;;; PDFIUM IS NOT THREAD-SAFE. Every call into it here holds *PDFIUM-LOCK*.

(in-package #:aion/pdfium)

(defparameter *library-names*
  #+darwin  '("libpdfium.dylib")
  #+windows '("pdfium.dll")
  #-(or darwin windows) '("libpdfium.so")
  "The file fetch-pdfium.lisp unpacks on this platform.")

(defvar *library* nil "The CFFI library object, or NIL. What UNLOAD-PDFIUM closes.")
(defvar *path* nil "The namestring of the loaded library, or NIL.")
(defvar *pdfium-lock* (sb-thread:make-mutex :name "aion/pdfium")
  "Held around loading the library and around every call into it: pdfium is not thread-safe.")

;; pdfium does floating-point arithmetic that SBCL's default traps turn into Lisp errors (an
;; invalid operation while it renders), so every call into it runs with the traps masked.
(defmacro with-pdfium (&body body)
  "Run BODY, which calls into pdfium, holding *PDFIUM-LOCK* and with floating-point traps masked."
  `(sb-thread:with-recursive-lock (*pdfium-lock*)
     (sb-int:with-float-traps-masked (:invalid :divide-by-zero :overflow :underflow :inexact)
       ,@body)))

(define-condition pdfium-not-found (error)
  ((searched :initarg :searched :reader pdfium-not-found-searched)
   (reason :initarg :reason :initform nil :reader pdfium-not-found-reason))
  (:report
   (lambda (c stream)
     (format stream "Could not load the pdfium library aion/pdfium needs.~%~%Searched:~%")
     (dolist (place (pdfium-not-found-searched c)) (format stream "  ~A~%" place))
     (when (pdfium-not-found-reason c)
       (format stream "~%Last error: ~A~%" (pdfium-not-found-reason c)))
     (format stream "~%Fetch the pinned one (pdfium.pin):~%  sbcl --script scripts/fetch-pdfium.lisp~%~%Or point AION_PDFIUM_LIBRARY at one.~%")))
  (:documentation "Signalled on first use when no candidate library could be loaded."))

(define-condition pdfium-mismatch (error)
  ((path :initarg :path :reader pdfium-mismatch-path)
   (reason :initarg :reason :reader pdfium-mismatch-reason))
  (:report
   (lambda (c stream)
     (format stream "The library at ~A loaded, but it is not one aion/pdfium can use: ~A~%Fetch it again with sbcl --script scripts/fetch-pdfium.lisp --force."
             (pdfium-mismatch-path c) (pdfium-mismatch-reason c))))
  (:documentation "Signalled when a library loads but does not define what FFI.LISP binds."))

(defun %image-directory ()
  "The directory of the running executable, as aion/libgit's %IMAGE-DIRECTORY."
  (flet ((dir-of (p)
           (when p
             (uiop:pathname-directory-pathname
              (uiop:ensure-absolute-pathname p #'uiop:getcwd nil)))))
    (or (ignore-errors (dir-of sb-ext:*runtime-pathname*))
        (ignore-errors (dir-of (uiop:argv0))))))

(defun %candidates ()
  "Every path LOAD-PDFIUM tries, in order."
  (let ((explicit (uiop:getenv "AION_PDFIUM_LIBRARY"))
        (image (%image-directory))
        (root (and aion/platform:*search-source-tree*
                   (ignore-errors
                    (uiop:pathname-parent-directory-pathname
                     (asdf:system-source-directory :aion))))))
    (append (when (and explicit (plusp (length explicit))) (list explicit))
            (when image
              (mapcar (lambda (n) (namestring (merge-pathnames n image))) *library-names*))
            (when root
              (mapcar (lambda (n)
                        (namestring (merge-pathnames (concatenate 'string "vendor/pdfium/lib/" n)
                                                     root)))
                      *library-names*))
            *library-names*)))

(defun %sb-alien (name)
  "The SB-ALIEN internal NAME, looked up when called, as aion/libgit's %SB-ALIEN."
  (or (find-symbol name "SB-ALIEN")
      (error "aion/pdfium: this SBCL has no SB-ALIEN::~A, which the library check needs" name)))

(defun %address-in-library (path name)
  "The address of NAME in the shared library loaded from PATH itself, or NIL, as aion/libgit's
%ADDRESS-IN-LIBRARY."
  (let* ((truename (ignore-errors (truename path)))
         (namestring-of (%sb-alien "SHARED-OBJECT-NAMESTRING"))
         (object (find-if (lambda (o)
                            (let ((file (ignore-errors (truename (funcall namestring-of o)))))
                              (if truename
                                  (equal file truename)
                                  (equal (funcall namestring-of o) path))))
                          (symbol-value (%sb-alien "*SHARED-OBJECTS*"))))
         (raw (and object (funcall (%sb-alien "SHARED-OBJECT-HANDLE") object)))
         (handle (if (integerp raw) (sb-sys:int-sap raw) raw))
         (address (and handle
                       #+windows (cffi:foreign-funcall "GetProcAddress" :pointer handle
                                                       :string name :pointer)
                       #-windows (funcall (%sb-alien "DLSYM") handle name))))
    (and address (not (zerop (sb-sys:sap-int address))) (sb-sys:sap-int address))))

(defun %foreign-resolution-mismatch (path)
  "NIL if every function FFI.LISP binds resolves, process-wide, to the library loaded from
PATH, else a sentence naming the first that does not."
  (dolist (name (sort (copy-list *entry-points*) #'string<))
    (let ((own (%address-in-library path name))
          (process (let ((p (cffi:foreign-symbol-pointer name)))
                     (and p (cffi:pointer-address p)))))
      (cond ((null own)
             (return (format nil "it does not define ~A" name)))
            ((not (eql own process))
             (return (format nil "~A resolves to another library already loaded in this process, so calls would not reach this one" name)))))))

(defun load-pdfium ()
  "Load our pdfium, trying each candidate in turn, check it, and initialise it. Returns the path
loaded. Signals PDFIUM-NOT-FOUND if nothing loads, and PDFIUM-MISMATCH if what loads first does
not define every function this code binds. Once loaded it is not reloaded; to use another,
call UNLOAD-PDFIUM first, with no document open."
  (with-pdfium
    (when *library*
      (return-from load-pdfium *path*))
    (let ((tried '()) (last-error nil))
      (dolist (candidate (%candidates))
        (push candidate tried)
        (when (let ((path-like (or (find #\/ candidate) (find #\\ candidate))))
                (or (not path-like) (probe-file candidate)))
          (let ((library (handler-case (cffi:load-foreign-library candidate)
                           (error (e) (setf last-error e) nil))))
            (when library
              (handler-bind ((error (lambda (e)
                                      (declare (ignore e))
                                      (ignore-errors (cffi:close-foreign-library library)))))
                (let ((reason (%foreign-resolution-mismatch candidate)))
                  (when reason
                    (error 'pdfium-mismatch :path candidate :reason reason)))
                (%init-library))
              (setf *library* library *path* candidate)
              (return-from load-pdfium candidate)))))
      (error 'pdfium-not-found :searched (nreverse tried) :reason last-error))))

(defun unload-pdfium ()
  "Shut pdfium down and close the library, so a dumped image opens its own carried copy instead
of reopening the build machine's path at startup (ADR-0013). For the bundler, with no document
still open."
  (with-pdfium
    (when *library*
      (%destroy-library)
      (cffi:close-foreign-library *library*)
      (setf *library* nil *path* nil)))
  (values))

(defun pdfium-loaded-p () (and *library* t))
(defun pdfium-path () *path*)

(defun ensure-loaded ()
  "Load the library on first use. Every entry point calls this."
  (or *path* (load-pdfium)))
