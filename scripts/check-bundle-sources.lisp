;;;; check-bundle-sources.lisp --- a built bundle carries the source and licence of every library
;;;; that needs them (ADR-0013's amendment of 2026-10-01, #429).
;;;;
;;;;     sbcl --script scripts/check-bundle-sources.lisp BUNDLE-DIRECTORY
;;;;
;;;; Exit 0 when every library in scripts/bundle-sources.lisp's *CARRIED-SOURCES* that the bundle
;;;; carries has its pinned tarball under SOURCES/ and its licence under LICENSES/, or when the
;;;; bundle carries none of them; exit 1, naming each problem, otherwise. The verify-bundle
;;;; scripts for all three platforms run it.

(require :asdf)
(load (merge-pathnames "bundle-sources.lisp"
                       (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(let* ((root (uiop:pathname-parent-directory-pathname
              (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))
       (bundle (second sb-ext:*posix-argv*)))
  (unless (and bundle (probe-file (uiop:ensure-directory-pathname bundle)))
    (format *error-output* "usage: sbcl --script scripts/check-bundle-sources.lisp BUNDLE-DIRECTORY~%")
    (sb-ext:exit :code 2))
  (let ((problems (handler-case (ouranos-bundle-sources:check-bundle bundle root)
                    (ouranos-bundle-sources:source-refused (e) (list (princ-to-string e))))))
    (cond (problems
           (dolist (p problems) (format t "check-bundle-sources: FAIL ~A~%" p))
           (sb-ext:exit :code 1))
          (t
           (format t "check-bundle-sources: ok, every carried library that needs its source has it~%")
           (sb-ext:exit :code 0)))))
