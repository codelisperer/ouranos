;;;; library.lisp --- find and load our libgit2, and check it is a build this code can use.
;;;;
;;;; Search order, most specific first, the same as aion/uv's and aion/tls's (hyperion
;;;; ADR-0013):
;;;;   1. AION_LIBGIT_LIBRARY     -- an explicit path. Always wins.
;;;;   2. beside the running image -- how a shipped bundle carries its own copy.
;;;;   3. vendor/libgit2/lib/...  -- what scripts/build-libgit2.lisp produced. Not in a desktop
;;;;                                 bundle, which never searches the tree it was built from
;;;;                                 (AION/PLATFORM:*SEARCH-SOURCE-TREE*, #472).
;;;;   4. the bare soname          -- left to the OS loader.
;;;;
;;;; After loading, a library is refused with LIBGIT2-MISMATCH, naming the file, unless:
;;;;   - every function FFI.LISP binds resolves to this library. On SBCL a foreign call is
;;;;     looked up across the whole process, not in one library, so if something loaded
;;;;     another libgit2 first, the calls would run that copy while LIBGIT2-PATH named this
;;;;     one. Each name is looked up in this library's own handle and compared with the
;;;;     address the process-wide lookup gives.
;;;;   - it reports version 1.9, because FFI.LISP's struct layouts are 1.9's;
;;;;   - it was built with threads, because a repository per thread is how this code uses it;
;;;;   - it was built without experimental SHA-256. That build's git_oid is a type byte and 32
;;;;     bytes, and this code allocates 20, so libgit2 would write past every id buffer.
;;;;     libgit2's own build names such a library libgit2-experimental, which none of the
;;;;     names below finds, but AION_LIBGIT_LIBRARY can name one, so its feature bit is checked.
;;;;
;;;; LOADING NEVER HAPPENS AT LOAD TIME, as in aion/uv (ADR-0011's lesson). The first call
;;;; that needs the library loads it.

(in-package #:aion/libgit)

(defparameter *library-names*
  #+darwin  '("libgit2.1.9.dylib")
  #+windows '("git2.dll")
  #-(or darwin windows) '("libgit2.so.1.9")
  "The file build-libgit2.lisp writes on this platform.")

(defvar *library* nil "The CFFI library object, or NIL. What UNLOAD-LIBGIT2 closes.")
(defvar *path* nil "The namestring of the loaded library, or NIL.")
(defvar *version* nil "The loaded library's version, as a list (major minor revision).")
(defvar *load-lock* (sb-thread:make-mutex :name "aion/libgit load"))

(define-condition libgit2-not-found (error)
  ((searched :initarg :searched :reader libgit2-not-found-searched)
   (reason :initarg :reason :initform nil :reader libgit2-not-found-reason))
  (:report
   (lambda (c stream)
     (format stream "Could not load the libgit2 library aion/libgit needs.~%~%Searched:~%")
     (dolist (place (libgit2-not-found-searched c)) (format stream "  ~A~%" place))
     (when (libgit2-not-found-reason c)
       (format stream "~%Last error: ~A~%" (libgit2-not-found-reason c)))
     (format stream "~%Build it from libgit2.pin (needs only a C compiler):~%  sbcl --script scripts/build-libgit2.lisp~%~%Or point AION_LIBGIT_LIBRARY at one.~%")))
  (:documentation "Signalled on first use when no candidate library could be loaded."))

(define-condition libgit2-mismatch (error)
  ((path :initarg :path :reader libgit2-mismatch-path)
   (reason :initarg :reason :reader libgit2-mismatch-reason))
  (:report
   (lambda (c stream)
     (format stream "The library at ~A loaded, but it is not one aion/libgit can use: ~A~%Rebuild it with sbcl --script scripts/build-libgit2.lisp --force."
             (libgit2-mismatch-path c) (libgit2-mismatch-reason c))))
  (:documentation "Signalled when a library loads but is not a build this code can use."))

(defun %image-directory ()
  "The directory of the running executable. The same duplication ADR-0013 records for
aion/uv and aion/tls."
  (flet ((dir-of (p)
           (when p
             (uiop:pathname-directory-pathname
              (uiop:ensure-absolute-pathname p #'uiop:getcwd nil)))))
    (or (ignore-errors (dir-of sb-ext:*runtime-pathname*))
        (ignore-errors (dir-of (uiop:argv0))))))

(defun %candidates ()
  "Every path LOAD-LIBGIT2 tries, in order."
  (let ((explicit (uiop:getenv "AION_LIBGIT_LIBRARY"))
        (image (%image-directory))
        ;; Not in a desktop bundle: it never consults the tree it was built from. The override
        ;; and the OS's own search still apply (AION/PLATFORM:*SEARCH-SOURCE-TREE*, #472).
        (root (and aion/platform:*search-source-tree*
                   (ignore-errors
                    (uiop:pathname-parent-directory-pathname
                     (asdf:system-source-directory :aion))))))
    (append (when (and explicit (plusp (length explicit))) (list explicit))
            (when image
              (mapcar (lambda (n) (namestring (merge-pathnames n image))) *library-names*))
            (when root
              (mapcar (lambda (n)
                        (namestring (merge-pathnames (concatenate 'string "vendor/libgit2/lib/" n)
                                                     root)))
                      *library-names*))
            *library-names*)))

(defun %read-version ()
  "The loaded library's version, as a list (major minor revision)."
  (cffi:with-foreign-objects ((major :int) (minor :int) (rev :int))
    (%version major minor rev)
    (list (cffi:mem-ref major :int) (cffi:mem-ref minor :int) (cffi:mem-ref rev :int))))

(defun %build-mismatch (version features)
  "NIL if a library reporting VERSION, a list (major minor revision), and FEATURES, the
git_libgit2_features bits, is one this code can use, else a sentence saying why not."
  (cond ((not (and (= (first version) 1) (= (second version) 9)))
         (format nil "it is libgit2 ~{~D~^.~}, and this code is written against 1.9" version))
        ((zerop (logand features +feature-threads+))
         "it was built without threads, so it is not safe to use from two threads")
        ((plusp (logand features +feature-sha256+))
         "it was built with experimental SHA-256, whose object ids are 33 bytes, and this code allocates 20")))

(defun %sb-alien (name)
  "The SB-ALIEN internal NAME, looked up when called and never written as a symbol, for the
reason aion/tls's %SB-ALIEN gives: a Windows SBCL has no SB-ALIEN::DLSYM, and reading the
symbol fails there."
  (or (find-symbol name "SB-ALIEN")
      (error "aion/libgit: this SBCL has no SB-ALIEN::~A, which the library check needs" name)))

(defun %address-in-library (path name)
  "The address of NAME in the shared library loaded from PATH itself, as an integer, or NIL.
Asks that library's handle (dlsym, or GetProcAddress on Windows), as aion/tls's
%LIBRARY-DEFINES-P does, because CFFI:FOREIGN-SYMBOL-POINTER on SBCL searches every loaded
library."
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

(defun load-libgit2 ()
  "Load our libgit2, trying each candidate in turn, check it, and initialise it. Returns the
path loaded. Signals LIBGIT2-NOT-FOUND if nothing loads, and LIBGIT2-MISMATCH if what loads
first is not a build this code can use.

As in aion/tls, a library is recorded as loaded only once it has been checked and
initialised, and once loaded it is never reloaded: every repository points into it. To use
another library, call UNLOAD-LIBGIT2 first, with no repository still open."
  (sb-thread:with-recursive-lock (*load-lock*)
    (when *library*
      (return-from load-libgit2 *path*))
    (let ((tried '()) (last-error nil))
      (dolist (candidate (%candidates))
        (push candidate tried)
        (when (let ((path-like (or (find #\/ candidate) (find #\\ candidate))))
                (or (not path-like) (probe-file candidate)))
          (let ((library (handler-case (cffi:load-foreign-library candidate)
                           (error (e) (setf last-error e) nil))))
            (when library
              (let ((version nil))
                (handler-bind ((error (lambda (e)
                                        (declare (ignore e))
                                        (ignore-errors (cffi:close-foreign-library library)))))
                  (let ((reason (%foreign-resolution-mismatch candidate)))
                    (when reason
                      (error 'libgit2-mismatch :path candidate :reason reason)))
                  (setf version (%read-version))
                  (let ((reason (%build-mismatch version (%features))))
                    (when reason
                      (error 'libgit2-mismatch :path candidate :reason reason)))
                  (let ((status (%init)))
                    (when (minusp status)
                      (error 'libgit2-mismatch :path candidate
                                               :reason (format nil "git_libgit2_init returned ~D" status)))))
                (setf *library* library *path* candidate *version* version))
              (return-from load-libgit2 candidate)))))
      (error 'libgit2-not-found :searched (nreverse tried) :reason last-error))))

(defun unload-libgit2 ()
  "Shut libgit2 down and close the library, so a dumped image opens its own carried copy
instead of reopening the build machine's path at startup (ADR-0013). For the bundler, with
no repository still open."
  (sb-thread:with-recursive-lock (*load-lock*)
    (when *library*
      (%shutdown)
      (cffi:close-foreign-library *library*)
      (setf *library* nil *path* nil *version* nil)))
  (values))

(defun libgit2-loaded-p () (and *library* t))
(defun libgit2-path () *path*)

(defun libgit2-version ()
  "The loaded library's version as a string, such as \"1.9.7\". Loads the library first."
  (ensure-loaded)
  (format nil "~{~D~^.~}" *version*))

(defun ensure-loaded ()
  "Load the library on first use. Every entry point calls this."
  (or *path* (load-libgit2)))
