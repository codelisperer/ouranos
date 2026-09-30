;;;; windows-launcher.lisp --- compile scripts/windows-launcher.c with MSVC (#98).
;;;;
;;;; Loaded by path by scripts/build-desktop-app.lisp, which puts the launcher into every
;;;; Windows bundle, and by checkers/tests, which compiles it the same way to check what it
;;;; passes to the runtime. One function, so the build and the test cannot compile it
;;;; differently.

(require :asdf)
(load (merge-pathnames "msvc.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(defpackage #:ouranos-windows-launcher
  (:use #:cl)
  (:export #:compile-launcher))

(in-package #:ouranos-windows-launcher)

(defparameter +source+
  (merge-pathnames "windows-launcher.c"
                   (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*)))
  "scripts/windows-launcher.c.")

(defun compile-launcher (target heap-mb object-directory)
  "Compile scripts/windows-launcher.c to TARGET, an .exe that starts the runtime beside it with
HEAP-MB megabytes of heap. The object file goes into OBJECT-DIRECTORY. Returns (values T
OUTPUT) when it compiled, and (values NIL OUTPUT) when it did not, OUTPUT saying why; NIL
also when no MSVC is installed."
  (unless (ignore-errors (ouranos-msvc:find-msvc))
    (return-from compile-launcher
      (values nil "no MSVC installation was found (vswhere, or OURANOS_MSVC_PATH)")))
  (ensure-directories-exist object-directory)
  (multiple-value-bind (out err code)
      (uiop:run-program
       (ouranos-msvc:msvc-command
        ;; /Fo names the object FILE, not its directory: a directory ends in a backslash,
        ;; which before the closing quote escapes it, and cl then reports the source file
        ;; missing (D8003).
        (format nil "cl /nologo /O2 /W4 /DOURANOS_HEAP_MB=~D /Fo\"~A\" /Fe\"~A\" \"~A\""
                heap-mb
                (uiop:native-namestring (merge-pathnames "windows-launcher.obj" object-directory))
                (uiop:native-namestring target)
                (uiop:native-namestring +source+)))
       :output :string :error-output :string :ignore-error-status t)
    (values (eql code 0) (format nil "cl exited ~A~%~A~A" code out err))))
