;;;; built-from.lisp --- the BUILT-FROM stamp a vendored library's build writes (#977).
;;;;
;;;; A build script that compiles a library into vendor/<name>/ writes vendor/<name>/BUILT-FROM,
;;;; naming the version and the source tarball's sha256 it built from. A library already in
;;;; vendor/ is reused only when its stamp names the pin's current version and sha256. Without
;;;; it, "the library file exists" was taken as "the library is current": after a pin moved, a
;;;; checkout that still held the old build kept it, said "already built", and exited 0, and
;;;; bundles carried the old release (#977, libuv 1.52.1 after the pin moved to 1.53.0).
;;;;
;;;; One copy of the format, loaded by build-libuv.lisp, build-sqlite.lisp and carry-natives.lisp,
;;;; so the scripts that write a stamp and the code that reads it cannot disagree about it.

(defpackage #:ouranos-built-from
  (:use #:cl)
  (:export #:stamp-path #:stamp-text #:write-stamp #:stamp-matches-p #:stamp-state))

(in-package #:ouranos-built-from)

(defun stamp-path (vendor-dir)
  "The BUILT-FROM file in VENDOR-DIR, a library's directory under vendor/."
  (merge-pathnames "BUILT-FROM" (uiop:ensure-directory-pathname vendor-dir)))

(defun stamp-text (version sha256)
  "What a stamp holds: the version, then the tarball's sha256 in lower case, one per line."
  (format nil "version ~A~%sha256 ~A~%" version (string-downcase sha256)))

(defun write-stamp (vendor-dir version sha256)
  "Record that the library in VENDOR-DIR was built from VERSION, whose tarball has SHA256."
  (with-open-file (out (stamp-path vendor-dir) :direction :output :if-exists :supersede)
    (write-string (stamp-text version sha256) out)))

(defun stamp-state (vendor-dir version sha256)
  "Whether the library in VENDOR-DIR was built from VERSION with SHA256, as a keyword:
:CURRENT when its stamp names them; :STALE when it names something else; :MISSING when there is
no stamp, as for a build made before the stamp existed. Only :CURRENT may be reused."
  (let ((path (probe-file (stamp-path vendor-dir))))
    (cond ((null path) :missing)
          ((string= (uiop:read-file-string path) (stamp-text version sha256)) :current)
          (t :stale))))

(defun stamp-matches-p (vendor-dir version sha256)
  "Whether VENDOR-DIR's stamp names VERSION and SHA256."
  (eq :current (stamp-state vendor-dir version sha256)))
