;;;; vswhere-probe.lisp --- what does build-libuv.lisp's MSVC discovery see, right now?
;;;;
;;;;   sbcl --script scripts/vswhere-probe.lisp
;;;;
;;;; A few lines of output and no side effects. It exists because pre-publication issue 128's remaining claims are
;;;; about what `find-msvc' ANSWERS on machines this one is not -- a Build Tools-only box, a
;;;; box with no compiler at all -- and the only way to talk about those answers is to be
;;;; able to print the one in front of you.
;;;;
;;;; It loads `build-libuv.lisp's discovery functions rather than reimplementing them. A
;;;; second copy of "where is Visual Studio" would be the producer/consumer defect this tree
;;;; keeps finding (pre-publication issue 206, pre-publication issue 77), in a script whose whole purpose is to report faithfully.
;;;;
;;;; THE THREE LINES ARE THREE DIFFERENT QUESTIONS, and on a box with several installs they
;;;; do not have the same answer:
;;;;   find-vswhere           -- is the VS Installer here at all? (its absence IS the
;;;;                             no-toolchain case: no installer, no vswhere, no discovery)
;;;;   find-msvc-via-vswhere  -- which install does `-latest' pick?
;;;;   find-msvc              -- which install will the BUILD actually use, i.e. the above
;;;;                             unless OURANOS_MSVC_PATH overrides it (pre-publication issue 382)

(require :asdf)
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; how a path is printed (#168)

(defparameter *build-libuv*
  (merge-pathnames "build-libuv.lisp"
                   (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

;;; `build-libuv.lisp' BUILDS when it is loaded, so it cannot simply be LOADed here. Read it
;;; form by form and evaluate only the definitions -- which is why this file names them.
;;;
;;; NAMING THEM MEANS THIS LIST IS A CLAIM ABOUT build-libuv.lisp's CALL GRAPH, and nothing
;;; but a run checks it. `find-msvc' acquiring a new callee (`msvc-override', and the
;;; variable it consults) does not break the arity check below -- both wanted names are
;;; still found -- it breaks at the CALL, with an undefined-function error from a script
;;; whose one job is to report faithfully. Hence the smoke test at the bottom: every form
;;; this probe prints is evaluated, so a missing callee fails here rather than on the
;;; machine being diagnosed. Adding a helper to the MSVC path means adding it here.
(defparameter *wanted*
  '(find-vswhere find-msvc-via-vswhere msvc-override find-msvc *msvc-override-announced*))

(let ((*package* (find-package :cl-user))
      (defined '()))
  (with-open-file (in *build-libuv* :external-format :utf-8)
    (loop for form = (handler-case (read in nil :eof) (error () :eof))
          until (eq form :eof)
          do (when (and (consp form)
                        ;; defparameter as well as defun: `msvc-override' reads a global,
                        ;; and a probe that evaluated only the functions would load a
                        ;; function whose free variable is unbound.
                        (member (first form) '(defun defparameter))
                        (member (second form) *wanted*))
               (eval form)
               (push (second form) defined))))
  (unless (= (length defined) (length *wanted*))
    (format *error-output* "~&vswhere-probe: could not find ~S in ~A -- it has been renamed~%"
            (set-difference *wanted* defined) (human-path:human-path *build-libuv*))
    (finish-output *error-output*)
    (sb-ext:quit :unix-status 2)))

(flet ((line (label value)
         ;; A found install is a pathname; a refusal is a sentence, printed as it is.
         (format t "~&~A : ~:[NOT FOUND~;~:*~A~]~%" label
                 (if (pathnamep value) (human-path:human-path value) value))))
  (let ((vswhere (funcall (read-from-string "cl-user::find-vswhere"))))
    (line "find-vswhere         " vswhere)
    (line "find-msvc-via-vswhere"
          (and vswhere (funcall (read-from-string "cl-user::find-msvc-via-vswhere"))))
    ;; `find-msvc' is what the build uses. Printed even when vswhere is absent, because
    ;; OURANOS_MSVC_PATH can answer where vswhere cannot -- which is the whole point of it.
    (line "find-msvc (the BUILD)"
          (handler-case (funcall (read-from-string "cl-user::find-msvc"))
            ;; `msvc-override' refuses a path with no vcvarsall.bat rather than falling
            ;; back. That refusal is a RESULT here, not a crash: print it and keep the
            ;; exit status clean, since the probe reports state and decides nothing.
            (error (e) (format nil "REFUSED -- ~A" e))))
    (format t "OURANOS_MSVC_PATH    : ~:[(unset)~;~:*~A~]~%"
            (let ((raw (uiop:getenv "OURANOS_MSVC_PATH")))
              (and raw (plusp (length raw)) raw)))))
