;;;; check-coalton.lisp --- prove which Coalton actually LOADS, not merely which is checked out.
;;;;
;;;;     sbcl --dynamic-space-size 4096 --script scripts/check-coalton.lisp
;;;;
;;;; Exit 0 if the loaded Coalton matches the repo-root coalton.pin, 1 otherwise.
;;;;
;;;; Three things can disagree, and only the last one is what you actually run:
;;;;   1. what coalton.pin declares,
;;;;   2. what the checkout's HEAD is,
;;;;   3. which directory ASDF RESOLVES :coalton to -- a Quicklisp dist release or a second
;;;;      checkout elsewhere on the source-registry will silently win,
;;;; and even with (2) == (3), the running image can be built from STALE FASLS compiled
;;;; before the checkout moved. So this checks provenance AND probes behaviour that only
;;;; exists at/after the pinned commit.

(require :asdf)
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; how a path is printed (#168)

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(defun pin-sha ()
  "The sha declared by coalton.pin, or NIL."
  (with-open-file (in (merge-pathnames "coalton.pin" *root*) :if-does-not-exist nil)
    (when in
      (loop for line = (read-line in nil)
            while line
            do (let ((trimmed (string-left-trim " " line)))
                 (when (and (> (length trimmed) 4) (string= "sha" trimmed :end2 3))
                   (let ((rest (string-trim " " (subseq trimmed 3))))
                     (return (subseq rest 0 (or (position #\Space rest) (length rest)))))))))))

(defun git-head (dir)
  (let ((out (ignore-errors
              (uiop:run-program (list "git" "-C" (namestring dir) "rev-parse" "HEAD")
                                :output '(:string :stripped t) :ignore-error-status t))))
    (and out (plusp (length out)) out)))

(asdf:initialize-source-registry
 `(:source-registry (:tree ,*root*) :inherit-configuration))
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(format t "~&pin (coalton.pin) : ~A~%" (or (pin-sha) "MISSING"))
(finish-output)

(handler-case (funcall (read-from-string "ql:quickload") :coalton :silent t)
  (error (e) (format t "~&FAILED to load coalton: ~A~%" e) (uiop:quit 1)))

(let* ((dir (asdf:system-source-directory :coalton))
       (head (git-head dir))
       (pin (pin-sha))
       (ok t))
  (format t "~&ASDF resolves to  : ~A~%" (human-path:human-path dir))
  (format t "~&that checkout HEAD: ~A~%" (or head "NOT A GIT CHECKOUT (a Quicklisp release?)"))
  ;; A short pin must match a prefix of the full HEAD sha, not equal it.
  (cond ((null pin) (format t "~&VERDICT: no pin to compare against.~%") (setf ok nil))
        ((null head)
         (format t "~&VERDICT: MISMATCH -- ASDF is loading a non-git Coalton, so the pin cannot apply.~%")
         (setf ok nil))
        ((string= pin (subseq head 0 (min (length pin) (length head))))
         (format t "~&VERDICT: the Coalton that LOADS is the pinned one.~%"))
        (t (format t "~&VERDICT: MISMATCH -- loading ~A, pin says ~A.~%" head pin)
           (setf ok nil)))

  ;; Behavioural probe: this commit ("Add Optional & Result instances for Foldable") is the
  ;; first where Foldable has an Optional instance. Compiling this fails on anything older,
  ;; which catches the case provenance cannot see -- a stale fasl cache serving old code
  ;; from the right directory.
  (format t "~&probe (Foldable Optional, added by the pinned commit): ")
  (finish-output)
  (handler-case
      ;; fold IS the Foldable method, so this fails to typecheck without the instance --
      ;; a narrower probe than reaching for a derived function that may not exist.
      (progn (eval (read-from-string
                    "(coalton:coalton-toplevel
                       (coalton:declare %pin-probe ((coalton-prelude:Optional coalton:Integer)
                                                    coalton:-> coalton:Integer))
                       (coalton:define (%pin-probe o) (coalton-prelude:fold coalton-prelude:+ 0 o)))"))
             (format t "compiles~%"))
    (error (e)
      (format t "FAILED~%  ~A~%" e)
      (format t "~&  (an old Coalton, or a stale fasl cache -- try clearing ~~/.cache/common-lisp)~%")
      (setf ok nil)))

  (uiop:quit (if ok 0 1)))
