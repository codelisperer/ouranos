;;;; platform.lisp --- this system is Windows-exclusive, and says so at the door.
;;;;
;;;; ADR-0003 Consequences: "opt-in AND platform-exclusive -- a new category for this tree.
;;;; aion/uv is opt-in but cross-platform; aion/windows cannot load off-platform at all."
;;;;
;;;; So loading this on macOS or Linux is not a degraded mode to be tolerated, it is a
;;;; mistake to be reported. The alternative -- load quietly and fail at the first call --
;;;; is right for aion/uv and wrong here, and the difference is worth stating because the
;;;; two look similar:
;;;;
;;;;   aion/uv     is cross-platform code whose LIBRARY may be missing. A bundle shipped
;;;;               without libuv must still load, or the whole image dies on a user's
;;;;               machine over a feature they never called (hyperion ADR-0011, #74). So
;;;;               library.lisp there never signals at load.
;;;;
;;;;   aion/windows is code that cannot mean anything off Windows. There is no call to
;;;;               defer to and no degraded mode to offer. Loading it on Linux is a build
;;;;               error, and the sooner it is one the better.
;;;;
;;;; The gate already knows the difference: scripts/platform-packages.lisp (#182) says this
;;;; package is owned by :windows, so a macOS run reports `n/a' and never loads it, while a
;;;; Windows run that cannot load it fails. This file is the same fact enforced from inside.

(in-package #:aion/windows)

(define-condition unsupported-platform (error)
  ((got :initarg :got :initform nil :reader unsupported-platform-got))
  (:report
   (lambda (c stream)
     (format stream "aion/windows is Windows-only and this image is ~A.~%~%There is no degraded mode: every entry point here is a Win32 or COM call. If a caller needs portable files, sockets, timers or subprocesses, that is aion/uv, which is cross-platform by design (ADR-0003 s3 -- bind what is Windows-only, never re-bind portable ground)."
             (or (unsupported-platform-got c) "not Windows"))))
  (:documentation "Signalled when aion/windows is loaded somewhere it cannot work."))

(defun windows-p ()
  "True on Windows.

Reads :WIN32 from *FEATURES* -- SBCL's own, and the one ADR-0003 s1 records as the reason
this system is named `windows' rather than `win64': SBCL pushes :WIN32 and not :WIN64 on
x86-64 Windows, so every conditional in the tree reads #+win32 regardless of pointer width."
  (and (find :win32 *features*) t))

(defun check-windows ()
  "Signal UNSUPPORTED-PLATFORM unless this is Windows."
  (unless (windows-p)
    (error 'unsupported-platform
           :got (format nil "~A" (or (find :darwin *features*)
                                     (find :linux *features*)
                                     (lisp-implementation-type)))))
  t)

;;; Enforced at LOAD, not merely offered as a predicate. A system that can be half-loaded
;;; off-platform is a system someone will report a confusing error from.
(check-windows)
