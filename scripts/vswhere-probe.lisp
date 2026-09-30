;;;; vswhere-probe.lisp --- what does the MSVC discovery in scripts/msvc.lisp see, right now?
;;;;
;;;;   sbcl --script scripts/vswhere-probe.lisp
;;;;
;;;; A few lines of output and no side effects. It exists because pre-publication issue 128's remaining claims are
;;;; about what `find-msvc' ANSWERS on machines this one is not -- a Build Tools-only box, a
;;;; box with no compiler at all -- and the only way to talk about those answers is to be
;;;; able to print the one in front of you.
;;;;
;;;; It loads scripts/msvc.lisp, which build-libuv.lisp and build-desktop-app.lisp use, rather than reimplementing it. A
;;;; second copy of "where is Visual Studio" would be the producer/consumer defect this tree
;;;; keeps finding (pre-publication issue 206, pre-publication issue 77), in a script whose whole purpose is to report faithfully.
;;;;
;;;; THE THREE LINES ARE THREE DIFFERENT QUESTIONS, and on a box with several installs they
;;;; do not have the same answer:
;;;;   find-vswhere           -- is the VS Installer here at all? (its absence IS the
;;;;                             no-toolchain case: no installer, no vswhere, no discovery)
;;;;   find-msvc-via-vswhere  -- which install does `-latest' pick?
;;;;   find-msvc              -- which install will the BUILD actually use, i.e. the above

(require :asdf)
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; how a path is printed (#168)
;;; The discovery functions are in their own file since #98, so this loads them rather than
;;; reading build-libuv.lisp form by form, as it had to while they lived in a script that
;;; builds when it is loaded.
(load (merge-pathnames "msvc.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(flet ((line (label value)
         ;; A found install is a pathname; a refusal is a sentence, printed as it is.
         (format t "~&~A : ~:[NOT FOUND~;~:*~A~]~%" label
                 (if (pathnamep value) (human-path:human-path value) value))))
  (let ((vswhere (ouranos-msvc:find-vswhere)))
    (line "find-vswhere         " vswhere)
    (line "find-msvc-via-vswhere" (and vswhere (ouranos-msvc:find-msvc-via-vswhere)))
    ;; `find-msvc' is what the build uses. Printed even when vswhere is absent, because
    ;; OURANOS_MSVC_PATH can answer where vswhere cannot -- which is the whole point of it.
    (line "find-msvc (the BUILD)"
          (handler-case (ouranos-msvc:find-msvc)
            ;; `msvc-override' refuses a path with no vcvarsall.bat rather than falling
            ;; back. That refusal is a RESULT here, not a crash: print it and keep the
            ;; exit status clean, since the probe reports state and decides nothing.
            (error (e) (format nil "REFUSED -- ~A" e))))
    (format t "OURANOS_MSVC_PATH    : ~:[(unset)~;~:*~A~]~%"
            (let ((raw (uiop:getenv "OURANOS_MSVC_PATH")))
              (and raw (plusp (length raw)) raw)))))
