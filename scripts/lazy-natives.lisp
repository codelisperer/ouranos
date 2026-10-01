;;;; lazy-natives.lisp --- the native libraries this tree builds, loads lazily, and carries in
;;;; a desktop bundle (ADR-0013).
;;;;
;;;; Its own file so that something other than build-desktop-app.lisp can read the list.
;;;; build-desktop-app.lisp ends in a dump and cannot be loaded by a test; this file can, and
;;;; scripts/tests/lazy-natives.lisp checks every entry against the module it names (#481).
;;;;
;;;; Each entry names a package, functions and variables as STRINGS, resolved when used,
;;;; because the bundler must keep working for an app that loads none of these systems. The
;;;; cost of strings is that a name which no longer matches the module resolves to nothing,
;;;; and the bundler reads "nothing" as "this app does not use the library" and carries
;;;; nothing. That is what the test above exists to catch.

(defpackage #:ouranos-lazy-natives
  (:use #:cl)
  (:export #:*lazy-natives* #:entry-package #:entry-loader #:entry-unloader
           #:entry-path-variable #:entry-names-variable #:entry-build-script
           #:entry-system
           #:release-all #:release-failed #:release-failed-package #:release-failed-cause))

(in-package #:ouranos-lazy-natives)

(defparameter *lazy-natives*
  '(("AION/UV/FFI" "LOAD-LIBUV" "UNLOAD-LIBUV" "*LIBUV-PATH*" "*LIBRARY-NAMES*"
     "build-libuv.lisp" "aion/uv")
    ;; mbedTLS was missing until #481, so a desktop app that loads aion/tls shipped without it.
    ;; aion/tls records the loaded path in its internal *PATH*; the exported MBEDTLS-PATH is a
    ;; function, and the bundler reads a variable.
    ("AION/TLS" "LOAD-MBEDTLS" "UNLOAD-MBEDTLS" "*PATH*" "*LIBRARY-NAMES*"
     "build-mbedtls.lisp" "aion/tls"))
  "Foreign libraries this tree loads LAZILY, and how to wake and release each one: (package
loader unloader path-variable names-variable build-script system), all strings. Lazy loading is
deliberate (ADR-0011: binding at load time is what made a missing library unloadable rather
than merely unavailable), but it means nothing is open yet when the bundler comes to look. So
the bundler asks each one to resolve itself, using the tree's OWN search order rather than
CFFI's, which is the only way it learns the vendored path instead of whatever the build
machine happens to have installed. BUILD-SCRIPT, under scripts/, is what builds the library
when it is missing. SYSTEM is the ASDF system that defines PACKAGE; the bundler does not need
it, and the test that checks this list loads it.")

(defun entry-package (entry) (first entry))
(defun entry-loader (entry) (second entry))
(defun entry-unloader (entry) (third entry))
(defun entry-path-variable (entry) (fourth entry))
(defun entry-names-variable (entry) (fifth entry))
(defun entry-build-script (entry) (sixth entry))
(defun entry-system (entry) (seventh entry))

(define-condition release-failed (error)
  ((package :initarg :package :reader release-failed-package)
   (cause :initarg :cause :reader release-failed-cause))
  (:report (lambda (c stream)
             (format stream "~A's unloader failed: ~A" (release-failed-package c)
                     (release-failed-cause c))))
  (:documentation "An unloader signalled, so its library may still be open."))

(defun release-all (&optional (entries *lazy-natives*))
  "Call the unloader of every entry in ENTRIES whose package is in this image, and signal
RELEASE-FAILED, naming the package, at the first that signals.

Not IGNORE-ERRORS, which the bundler used before #481's review. SBCL records the shared objects
an image has open and reopens them when the image starts, before main. A library whose unload
failed may still be open, and an image dumped then reopens the build machine's path on the
user's machine and stops there. The unloaders let their errors through for that reason, and so
must this."
  (dolist (entry entries)
    (let* ((p (find-package (entry-package entry)))
           (s (and p (find-symbol (entry-unloader entry) p))))
      (when (and s (fboundp s))
        (handler-case (funcall s)
          (error (e)
            (error 'release-failed :package (entry-package entry) :cause e)))))))
