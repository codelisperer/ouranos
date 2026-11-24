;;;; openssl-reopen.lisp --- aion/http-client: a saved image starts without OpenSSL (#1173).

(in-package #:aion/http-client)

;;; A SAVED IMAGE THAT NEVER USES TLS STARTS WITHOUT OpenSSL. cl+ssl opens libssl and libcrypto
;;; when it loads, and SBCL reopens every shared object an image had open when it was saved,
;;; before any of the program runs. So an image with cl+ssl in it used to exit at startup, in
;;; SB-SYS:REOPEN-SHARED-OBJECTS, on a machine without the OpenSSL it was built against, even
;;; when it only ever made plain-http requests (#1173).
;;;
;;; Three hooks change that, in an image that has cl+ssl loaded (Linux and the other Unixes;
;;; Windows and macOS do not load cl+ssl):
;;;
;;;   1. When the image is saved, cl+ssl's two shared objects are marked dont-save, so SBCL does
;;;      not reopen them at startup.
;;;   2. When the saved image starts, it tries to reopen them with CL+SSL:RELOAD, inside a
;;;      handler. Where OpenSSL is present, the image behaves as before. Where it is missing, the
;;;      error is kept and the image goes on starting.
;;;   3. cl+ssl calls ENSURE-INITIALIZED before it uses OpenSSL. In an image whose reopen failed,
;;;      that call tries once more, and when OpenSSL is still missing it signals HTTP-ERROR
;;;      naming the library that could not be opened. So the first TLS request fails with that
;;;      error, rather than with SBCL's "undefined alien function", and plain-http requests are
;;;      unaffected.
;;;
;;; cl+ssl's symbols are looked up by name at run time, so this file reads and compiles on a
;;; platform where cl+ssl is not loaded, and does nothing there.

(defvar *%openssl-reopen-failure* nil
  "In a saved image that started without reopening cl+ssl's OpenSSL, the error CL+SSL:RELOAD
signalled at startup; otherwise NIL.")

(defvar *%openssl-reopen-lock* (sb-thread:make-mutex :name "aion/http-client openssl reopen"))

(defun %cl+ssl-function (name)
  (fdefinition (find-symbol name "CL+SSL")))

(defun %openssl-shared-objects ()
  "The shared objects SBCL holds open for cl+ssl's libssl and libcrypto: those whose pathname is
the one CFFI recorded for those two libraries when it opened them."
  (let ((paths (loop for name in '("LIBSSL" "LIBCRYPTO")
                     for library = (cffi::get-foreign-library (find-symbol name "CL+SSL"))
                     for path = (and (cffi:foreign-library-loaded-p library)
                                     (cffi:foreign-library-pathname library))
                     when path collect path)))
    (remove-if-not (lambda (object) (member (sb-alien::shared-object-pathname object) paths
                                            :test #'equal))
                   sb-sys:*shared-objects*)))

(defun %openssl-dont-save ()
  "SB-EXT:*SAVE-HOOKS*: keep SBCL from reopening cl+ssl's OpenSSL when the saved image starts."
  (dolist (object (%openssl-shared-objects))
    (setf (sb-alien::shared-object-dont-save object) t)))

(defun %reopen-openssl ()
  "Open cl+ssl's OpenSSL again, the way cl+ssl documents for a saved image (CL+SSL:RELOAD).
Returns NIL, or the error when it could not be opened."
  (handler-case (progn (funcall (%cl+ssl-function "RELOAD")) nil)
    (error (condition) condition)))

(defun %openssl-reopen-at-startup ()
  "SB-EXT:*INIT-HOOKS*: reopen cl+ssl's OpenSSL, and keep the error if that fails."
  (setf *%openssl-reopen-failure* (%reopen-openssl)))

(defun %ensure-openssl-reopened ()
  "Signal HTTP-ERROR naming the missing library if this image started without OpenSSL and it is
still missing; otherwise return."
  (when *%openssl-reopen-failure*
    (sb-thread:with-recursive-lock (*%openssl-reopen-lock*)
      (when *%openssl-reopen-failure*
        (setf *%openssl-reopen-failure* (%reopen-openssl))
        (when *%openssl-reopen-failure*
          (error 'http-error
                 :detail (format nil "OpenSSL, which https needs here, could not be opened: ~A"
                                 ;; One line: CFFI puts the path it tried on a line of its own.
                                 (substitute-if #\Space (lambda (c) (member c '(#\Newline #\Return)))
                                                (princ-to-string *%openssl-reopen-failure*)))))))))

(defvar *%cl+ssl-own-ensure-initialized*
  (and (find-package "CL+SSL") (%cl+ssl-function "ENSURE-INITIALIZED"))
  "cl+ssl's own ENSURE-INITIALIZED, kept when this file first loads, so that loading it again
does not wrap the wrapper.")

(defun %ensure-initialized (&rest arguments)
  "CL+SSL:ENSURE-INITIALIZED in this image: reopen OpenSSL if the image started without it."
  (%ensure-openssl-reopened)
  (apply *%cl+ssl-own-ensure-initialized* arguments))

(when (find-package "CL+SSL")
  (setf (fdefinition (find-symbol "ENSURE-INITIALIZED" "CL+SSL")) #'%ensure-initialized)
  (pushnew '%openssl-dont-save sb-ext:*save-hooks*)
  (pushnew '%openssl-reopen-at-startup sb-ext:*init-hooks*))
