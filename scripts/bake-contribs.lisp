;;;; bake-contribs.lisp --- load the SBCL contribs a dumped image carries, or stop (#1099).
;;;;
;;;; A dumped executable loads a contrib it does not carry from SBCL_HOME's contrib/ directory
;;;; when something first requires it, and on macOS and Linux SBCL_HOME is usually not set in
;;;; the environment bin/cons runs in, so it has no contrib directory at all (#701, review of
;;;; #1097). So the contribs the framework tree loads on demand are loaded into the image
;;;; before it is dumped: Coalton needs sb-cltl2, the web stack's sockets sb-bsd-sockets,
;;;; ironclad sb-rotate-byte and sb-md5, and so on.
;;;;
;;;; THIS USED TO BE `(ignore-errors (require contrib))'. A contrib that failed to load left
;;;; no trace, the dump went ahead, and the image failed much later, at the first REQUIRE of
;;;; that contrib, far from the cause. #701 saw `Don't know how to REQUIRE sb-posix.' from a
;;;; Windows bin/cons.exe, and sb-posix is in the list below, which is what a contrib that was
;;;; never loaded at bootstrap would give. Now each one must load and appear on *MODULES*, or
;;;; the caller stops with the contrib, the error and where SBCL looked.
;;;;
;;;; SHARED by bootstrap.lisp (bin/cons) and scripts/build-desktop-app.lisp, which had the
;;;; same list and the same IGNORE-ERRORS. Plain CL, not part of any ASDF system, loaded with
;;;; LOAD, for the reason scripts/heap-guard.lisp gives: bootstrap uses it before cons exists.

(defpackage #:ouranos-bake
  (:use #:common-lisp)
  (:export #:+contribs+ #:bake-contribs #:bake-contribs-or-die))

(in-package #:ouranos-bake)

(defparameter +contribs+
  '(:sb-cltl2 :sb-bsd-sockets :sb-posix :sb-rotate-byte :sb-md5 :sb-introspect :sb-concurrency)
  "The contribs every dumped image in this tree carries.")

(defun %loaded-p (contrib)
  (and (member (string contrib) *modules* :test #'string-equal) t))

(defun bake-contribs (&optional (contribs +contribs+))
  "REQUIRE each of CONTRIBS. Returns a list of (CONTRIB . REASON) for each one that signalled
an error or did not appear on *MODULES* afterwards; NIL when every one loaded."
  (loop for contrib in contribs
        for reason = (handler-case (progn (require contrib)
                                          (unless (%loaded-p contrib)
                                            "REQUIRE returned, but it is not on *MODULES*"))
                       (error (e) (substitute #\Space #\Newline (princ-to-string e))))
        when reason collect (cons contrib reason)))

(defun bake-contribs-or-die (prefix image &optional (contribs +contribs+))
  "Bake CONTRIBS into this image, which will be dumped as IMAGE, or print each failure, each
line starting with PREFIX, and exit 1. Prints the SBCL home and SBCL_HOME, since a contrib that cannot be found usually
means SBCL is looking in the wrong place."
  (let ((failed (bake-contribs contribs)))
    (when failed
      (format t "~&~A: cannot dump ~A: ~D SBCL contrib~:P it must carry did not load.~%"
              prefix image (length failed))
      (loop for (contrib . reason) in failed
            do (format t "~A:   ~(~A~): ~A~%" prefix contrib reason))
      (format t "~A: SBCL ~A looks for contribs in ~A (SBCL_HOME is ~A; SBCL ignores it unless it holds a contrib/ directory).~%"
              prefix (lisp-implementation-version)
              (let ((home (ignore-errors (sb-int:sbcl-homedir-pathname))))
                (if home (merge-pathnames "contrib/" home) "no directory"))
              (or (sb-ext:posix-getenv "SBCL_HOME") "not set"))
      (format t "~A: An image dumped now would fail at the first REQUIRE of each one. Repair or reinstall SBCL, then run this again.~%"
              prefix)
      (finish-output)
      (sb-ext:exit :code 1 :abort t))
    t))
