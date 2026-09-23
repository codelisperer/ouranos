;;;; library.lisp --- find and load libuv, and prove it is the library we think it is.
;;;;
;;;; Search order, most specific first:
;;;;   1. AION_UV_LIBRARY        -- an explicit path. Always wins.
;;;;   2. beside the running image -- how a SHIPPED BUNDLE carries its own copy. The
;;;;                                dumped executable and the library sit in one directory
;;;;                                and we hand the loader an absolute path, so no rpath,
;;;;                                no LD_LIBRARY_PATH and no wrapper script is involved.
;;;;                                See hyperion ADR-0013.
;;;;   3. vendor/libuv/lib/...   -- what scripts/build-libuv.lisp produced from libuv.pin.
;;;;                                Preferred over the system copy so the whole tree agrees
;;;;                                on ONE libuv version regardless of what apt/brew carry.
;;;;   4. the system library     -- libuv.so.1 / libuv.1.dylib / libuv.dll, if installed.
;;;;
;;;; LOADING NEVER SIGNALS AT LOAD TIME. That is deliberate, and it is ADR-0011's lesson
;;;; paid forward: Woo bound libev while the file was being LOADED, so a missing .so did
;;;; not produce a bad feature -- it produced a system that could not be loaded at all,
;;;; and every desktop bundle died on a clean machine. Here, a missing libuv leaves the
;;;; system loaded and inert; the first actual call signals UV-ERROR with instructions.
;;;; You can always compile, load and inspect aion/uv without libuv present.

(in-package #:aion/uv/ffi)

;;; ------------------------------------------------------------------ locating

(defparameter *library-names*
  #+darwin  '("libuv.1.dylib" "libuv.dylib")
  #+windows '("libuv.dll")
  #-(or darwin windows) '("libuv.so.1" "libuv.so")
  "Platform sonames, most specific first. The versioned name is tried first because it
is what the linker records as the SONAME and what a system install actually provides.")

(defvar *libuv-path* nil
  "Namestring of the libuv actually loaded, or NIL. Set by LOAD-LIBUV.")

(defvar *libuv-library* nil
  "The CFFI library object LOAD-LIBUV opened, or NIL -- the only thing UNLOAD-LIBUV can
close it by.")

(define-condition libuv-not-found (error)
  ((searched :initarg :searched :reader libuv-not-found-searched)
   (reason :initarg :reason :initform nil :reader libuv-not-found-reason))
  (:report
   (lambda (c stream)
     (format stream "Could not load libuv.~%~%Searched:~%")
     (dolist (place (libuv-not-found-searched c))
       (format stream "  ~A~%" place))
     (when (libuv-not-found-reason c)
       (format stream "~%Last error: ~A~%" (libuv-not-found-reason c)))
     (format stream "~%Build the pinned libuv (needs only a C compiler):~%")
     (format stream "  sbcl --script scripts/build-libuv.lisp~%~%")
     (format stream "Or point AION_UV_LIBRARY at an existing one.~%")))
  (:documentation "Signalled on first use when no libuv could be loaded."))

(defun %image-directory ()
  "The directory the RUNNING executable lives in, as an absolute pathname (or NIL).

Not (uiop:argv0): argv0 is whatever the OS handed us and routinely carries no directory
component, and merging a bare name in a DUMPED image resolves it against the build
machine's *DEFAULT-PATHNAME-DEFAULTS* -- a path that does not exist on the user's machine.
sb-ext:*runtime-pathname* is the runtime's own absolute path, resolved by the C runtime at
startup. SBCL-only, which this stack already is.

This duplicates hyperion/desktop:image-directory, deliberately and not by oversight:
aion/uv sits far to the left of hyperion in the DAG and does not depend even on aion core,
so it cannot call it. Recorded in ADR-0013; the shared home is issue #125's runtime module."
  (flet ((dir-of (p)
           (when p
             (uiop:pathname-directory-pathname
              (uiop:ensure-absolute-pathname p #'uiop:getcwd nil)))))
    (or (ignore-errors (dir-of sb-ext:*runtime-pathname*))
        (ignore-errors (dir-of (uiop:argv0))))))

(defun %beside-image-candidates ()
  "The paths a shipped bundle would have carried its libuv to -- one per platform soname,
in the directory the running executable lives in."
  (let ((dir (%image-directory)))
    (when dir
      (mapcar (lambda (name) (namestring (merge-pathnames name dir)))
              *library-names*))))

(defun %vendored-candidates ()
  "The paths scripts/build-libuv.lisp would have written to, if aion is loadable."
  (let ((root (ignore-errors
               (uiop:pathname-parent-directory-pathname
                (asdf:system-source-directory :aion)))))
    (when root
      (mapcar (lambda (name)
                (namestring (merge-pathnames (concatenate 'string "vendor/libuv/lib/" name)
                                             root)))
              *library-names*))))

(defun %candidates ()
  "Every path LOAD-LIBUV will try, in order."
  (let ((explicit (uiop:getenv "AION_UV_LIBRARY")))
    (append (when (and explicit (plusp (length explicit))) (list explicit))
            ;; A shipped bundle FIRST: it carries the libuv it was built against, and must
            ;; use that one even on a machine that happens to have another installed.
            (%beside-image-candidates)
            (%vendored-candidates)
            ;; Bare names: hand them to the OS loader and let it search its own paths.
            *library-names*)))

;;; ------------------------------------------------------------------- loading

(defvar *loaded* nil)

(defun libuv-loaded-p () *loaded*)

(defun load-libuv (&key force)
  "Load libuv, trying each candidate in turn. Returns the loaded path.
Signals LIBUV-NOT-FOUND if none worked. Idempotent unless FORCE."
  (when (and *loaded* (not force))
    (return-from load-libuv *libuv-path*))
  (let ((tried '())
        (last-error nil))
    (dolist (candidate (%candidates))
      (push candidate tried)
      ;; A PATH that is not there is not worth handing to the loader; a bare soname has
      ;; no path to probe, so it always goes to the OS to resolve however it likes.
      (when (let ((path-like (or (find #\/ candidate) (find #\\ candidate))))
              (or (not path-like) (probe-file candidate)))
        (handler-case
            (progn
              ;; Keep the library OBJECT, not just the path. CFFI names a library loaded by
              ;; path with a generated symbol (LIBUV.SO.1-459), so the path is not a handle
              ;; you can close it by -- and UNLOAD-LIBUV has to be able to close it.
              (setf *libuv-library* (cffi:load-foreign-library candidate)
                    *loaded* t
                    *libuv-path* candidate)
              (return-from load-libuv candidate))
          (error (e) (setf last-error e)))))
    (error 'libuv-not-found :searched (nreverse tried) :reason last-error)))

(defun unload-libuv ()
  "Close libuv and forget it, so the next ENSURE-LOADED resolves from scratch.

This exists for the BUNDLER (ADR-0013). It loads libuv on the build machine to learn which
file to carry, and must then release it before `save-lisp-and-die`: SBCL records every open
shared object and reopens it at image startup, so a dumped image that still held this handle
would try to reopen the BUILD machine's path -- which is exactly the path the user does not
have. Releasing it here means the shipped image opens its own carried copy, lazily, on first
use.

Errors are NOT suppressed. A close that quietly fails produces a bundle that dies at
startup on the user's machine with a path from the build machine in the message -- which is
precisely what an earlier version of this function shipped, because it passed the path
string (CFFI cannot close a library by path) inside an IGNORE-ERRORS."
  (when *loaded*
    (cffi:close-foreign-library *libuv-library*)
    (setf *loaded* nil
          *libuv-path* nil
          *libuv-library* nil))
  (values))

(defun ensure-loaded ()
  "Load libuv on first use. Every entry point in aion/uv calls this."
  (or *loaded* (load-libuv)))
