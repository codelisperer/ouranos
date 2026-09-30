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

(defun %sha256-hex-p (s)
  (and (stringp s) (= 64 (length s)) (every (lambda (c) (digit-char-p c 16)) s)))

(defun compile-launcher (target heap-mb object-directory core-sha256)
  "Compile scripts/windows-launcher.c to TARGET, an .exe that starts the runtime beside it with
HEAP-MB megabytes of heap, after checking that sbcl.core beside it has CORE-SHA256, 64 hex
digits (#98, step 2). The object file goes into OBJECT-DIRECTORY. Returns (values T OUTPUT)
when it compiled, and (values NIL OUTPUT) when it did not, OUTPUT saying why; NIL also when
no MSVC is installed or CORE-SHA256 is not 64 hex digits."
  (unless (%sha256-hex-p core-sha256)
    (return-from compile-launcher
      (values nil (format nil "the core's SHA-256 must be 64 hex digits, not ~S" core-sha256))))
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
        (format nil "cl /nologo /O2 /W4 /DOURANOS_HEAP_MB=~D /DOURANOS_CORE_SHA256=~A /Fo\"~A\" /Fe\"~A\" \"~A\""
                heap-mb (string-downcase core-sha256)
                (uiop:native-namestring (merge-pathnames "windows-launcher.obj" object-directory))
                (uiop:native-namestring target)
                (uiop:native-namestring +source+)))
       :output :string :error-output :string :ignore-error-status t)
    (values (eql code 0) (format nil "cl exited ~A~%~A~A" code out err))))
