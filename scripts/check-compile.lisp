;;;; check-compile.lisp --- does this system compile the way the gate requires? (#117)
;;;;
;;;;   sbcl --script scripts/check-compile.lisp                 systems with changed files
;;;;   sbcl --script scripts/check-compile.lisp cons hyperion   those systems
;;;;
;;;; A SUITE CAN PASS WHILE ITS COMPILE PRINTS WARNINGS THE GATE FAILS ON. Measured on #117
;;;; with an unescaped quote in one docstring in cons: `(asdf:test-system :cons)' printed four
;;;; `caught WARNING' lines and then `Did 635 checks. Fail: 0', and run a second time, with the
;;;; fasls warm, it printed nothing at all. verify-tree.lisp fails the same tree, because it
;;;; loads each system in a fresh image and reads the compiler's output. That takes minutes
;;;; for the whole tree; this does the same for the systems you name, or the systems your
;;;; change touches, in seconds each.
;;;;
;;;; THE SAME JUDGEMENT AS THE GATE, NOT A SECOND ONE. For each system: a fresh SBCL image
;;;; runs `(asdf:load-system SYSTEM)', exactly as verify-tree.lisp's load phase does, and its
;;;; output is judged by the gate's own functions, loaded from the same files:
;;;; WARNINGS-IN with +KNOWN-WARNINGS+ (compile-warnings.lisp) and ERRORS-IN
;;;; (caught-errors.lisp). A system passes only if the child exits 0 and both find nothing.
;;;;
;;;; COLD FOR THIS TREE, EVERY RUN. The fasls of this tree's files, and of the checked system's
;;;; own directory if it lies elsewhere, go to a new temporary directory, so a warm cache
;;;; cannot hide a warning (the second run above). Quicklisp's own fasl cache is used as it
;;;; is, so dependencies are not recompiled.
;;;;
;;;; WITH NO ARGUMENTS it compares the working tree, including uncommitted and untracked
;;;; files, with the merge base of HEAD and origin/main, and checks every system that
;;;; contains a changed .lisp file or is defined in a changed .asd file. It prints both SHAs,
;;;; the files that belong to no system, and each system it ran with its time, so an empty or
;;;; stale run shows as one. `origin/main' is only as fresh as your last `git fetch'.
;;;;
;;;; The tree is the checkout you are standing in (tree-root.lisp). A CL_SOURCE_REGISTRY in
;;;; your environment is appended after this tree, never before it.
;;;;
;;;; Exit 0 when every system passes, 1 when any fails, 2 when the check cannot run.

(require :asdf)

(defparameter *script* (or *load-truename* *load-pathname*))
(defparameter *scripts* (uiop:pathname-directory-pathname *script*))
(load (merge-pathnames "tree-root.lisp" *scripts*))
(load (merge-pathnames "compile-warnings.lisp" *scripts*))
(load (merge-pathnames "caught-errors.lisp" *scripts*))

(defparameter *root* (tree-root:resolve-or-die *script* "check-compile"))
(defparameter *quicklisp* (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defun die (fmt &rest args)
  (format *error-output* "~&check-compile: ~?~%" fmt args)
  (uiop:quit 2))

(defun git (&rest args)
  "ARGS run in the tree; stdout as lines, or NIL if git failed."
  (multiple-value-bind (out err code)
      (uiop:run-program (list* "git" "-C" (uiop:native-namestring *root*) args)
                        :output :string :error-output :string :ignore-error-status t)
    (declare (ignore err))
    (when (zerop code)
      (remove "" (uiop:split-string (string-right-trim '(#\Newline #\Return) out)
                                    :separator '(#\Newline))
              :test #'string=))))

;;; --- which systems ----------------------------------------------------------------

(defun changed-files ()
  "(values FILES BASE HEAD): every file that differs from the merge base, untracked included."
  (let ((head (first (git "rev-parse" "HEAD")))
        (base (first (git "merge-base" "HEAD" "origin/main"))))
    (unless base (die "no merge base with origin/main -- is there an `origin' remote, and has it been fetched?"))
    (values (remove-duplicates
             (append (git "diff" "--name-only" base)
                     (git "ls-files" "--others" "--exclude-standard"))
             :test #'string=)
            base head)))

(defun component-files (component)
  "Every source file under COMPONENT, as truenames."
  (if (typep component 'asdf:parent-component)
      (mapcan #'component-files (asdf:component-children component))
      (let ((p (asdf:component-pathname component)))
        (and p (probe-file p) (list (truename p))))))

(defun tree-systems ()
  "(NAME . SYSTEM) for every system defined in an .asd file of this tree."
  (dolist (asd (git "ls-files" "*.asd"))
    (handler-case (asdf:load-asd (merge-pathnames asd *root*))
      (error (e) (format t "  note    could not read ~A: ~A~%" asd e))))
  (loop for name in (asdf:registered-systems)
        for system = (asdf:find-system name nil)
        for asd = (and system (asdf:system-source-file system))
        when (and asd (uiop:subpathp (truename asd) *root*))
          collect (cons name system)))

(defun systems-for (files)
  "(values SYSTEM-NAMES UNCLAIMED-FILES) for FILES, relative paths in this tree."
  (let* ((systems (tree-systems))
         (paths (mapcar (lambda (f) (cons f (probe-file (merge-pathnames f *root*)))) files))
         (chosen '())
         (claimed '()))
    (dolist (entry systems)
      (destructuring-bind (name . system) entry
        (let ((sources (component-files system))
              (asd (truename (asdf:system-source-file system))))
          (dolist (p paths)
            (when (and (cdr p)
                       (or (equal (cdr p) asd)
                           (member (cdr p) sources :test #'equal)))
              (pushnew name chosen :test #'string=)
              (pushnew (car p) claimed :test #'string=))))))
    (values (sort chosen #'string<)
            (sort (remove-if (lambda (f) (member f claimed :test #'string=)) files) #'string<))))

;;; --- one system, the gate's way -----------------------------------------------------

(defun child-registry ()
  (let ((sep (uiop:inter-directory-separator))
        (caller (uiop:getenv "CL_SOURCE_REGISTRY")))
    (format nil "~A//~A~@[~A~]" (uiop:native-namestring *root*) sep
            (and caller (plusp (length caller)) caller))))

(defun check-system (name fasls)
  "Load NAME in a fresh image with this tree's fasls under FASLS. (values OK LINES SECONDS)."
  (let* ((start (get-internal-real-time))
                  ;; Two translations into the new directory: this tree, and the directory of the
         ;; system being checked, which may lie outside it (the control in cons/tests does).
         ;; The system's own entry comes first, because the first match wins.
         (form (format nil "(let ((d (asdf:system-source-directory ~S))) (asdf:initialize-output-translations `(:output-translations ((,d :**/ :*.*.*) (~S :**/ :*.*.*)) ((~S :**/ :*.*.*) (~S :**/ :*.*.*)) :inherit-configuration)) (asdf:load-system ~S))"
                       name
                       (namestring (merge-pathnames "system/" fasls))
                       (namestring *root*) (namestring (merge-pathnames "tree/" fasls))
                       name))
         (out (make-string-output-stream))
         (code (nth-value 2 (uiop:run-program
                             (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                                   "--dynamic-space-size" "4096"
                                   "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                                   "--eval" "(require :asdf)"
                                   "--eval" (format nil "(load ~S)" (uiop:native-namestring *quicklisp*))
                                   "--eval" form)
                             :output out :error-output out :ignore-error-status t
                             :environment (cons (format nil "CL_SOURCE_REGISTRY=~A" (child-registry))
                                                (remove-if (lambda (e) (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e))
                                                           (sb-ext:posix-environ))))))
         (text (get-output-stream-string out))
         (warned (ouranos-compile-warnings:warnings-in text))
         (errors (ouranos-caught-errors:errors-in text))
         (seconds (/ (- (get-internal-real-time) start) internal-time-units-per-second))
         (lines '()))
    (unless (zerop code)
      (let ((all (uiop:split-string text :separator '(#\Newline))))
        ;; The first lines and the last few: SBCL states the error first and prints the
        ;; backtrace after it, so the lines that say why are at the top.
        (push (format nil "the image exited ~D; its output:" code) lines)
        (dolist (l (if (<= (length all) 12)
                       all
                       (append (subseq all 0 8) (list "...") (last all 3))))
          (push (format nil "  | ~A" (string-right-trim '(#\Return) l)) lines))))
    (when warned
      ;; No count: WARNINGS-IN returns each warning with the lines around it, and two warnings
      ;; close together share lines, so counting markers here would count some twice.
      (push "caught WARNINGs the gate fails on (as WARNINGS-IN reports them):" lines)
      (dolist (l warned) (push (format nil "  | ~A" (string-right-trim '(#\Return) l)) lines)))
    (when errors
      (push (format nil "~D caught ERROR~:P:" (length errors)) lines)
      (dolist (e errors) (dolist (l e) (push (format nil "  | ~A" l) lines))))
    (values (and (zerop code) (null warned) (null errors)) (nreverse lines) seconds)))

;;; --- main ---------------------------------------------------------------------------

(defun main (args)
  (load *quicklisp*)
  (asdf:initialize-source-registry `(:source-registry (:tree ,*root*) :inherit-configuration))
  (format t "~&check-compile: tree ~A~%" (uiop:native-namestring *root*))
  (let ((systems args))
    (if args
        (format t "  systems named on the command line~%")
        (multiple-value-bind (files base head) (changed-files)
          (format t "  compared  ~A  (merge base of HEAD and origin/main)~%" base)
          (format t "  with      ~A  (HEAD) plus uncommitted and untracked files~%" head)
          (format t "  ~D changed file~:P~%" (length files))
          (multiple-value-bind (chosen unclaimed) (systems-for files)
            (setf systems chosen)
            (dolist (f unclaimed) (format t "  not in any system: ~A~%" f)))))
    (when (null systems)
      (format t "~&check-compile: no changed file belongs to a system, so nothing was compiled.~%")
      (uiop:quit 0))
    (let ((fasls (uiop:ensure-directory-pathname
                  (merge-pathnames (format nil "ouranos-check-compile-~36R/" (random (expt 36 8) (make-random-state t)))
                                   (uiop:temporary-directory))))
          (failed 0))
      (format t "  fasls of this tree go to ~A (new, so every file here is recompiled)~%~%"
              (uiop:native-namestring fasls))
      (unwind-protect
           (dolist (s systems)
             (multiple-value-bind (ok lines seconds) (check-system s fasls)
               (format t "  ~:[FAIL~;ok  ~]    ~A~40T~,1Fs~%" ok s seconds)
               (dolist (l lines) (format t "          ~A~%" l))
               (unless ok (incf failed))
               (finish-output)))
        (uiop:delete-directory-tree fasls :validate t :if-does-not-exist :ignore))
      (format t "~&check-compile: ~D system~:P checked, ~D failed.~%" (length systems) failed)
      (uiop:quit (if (zerop failed) 0 1)))))

(main (rest sb-ext:*posix-argv*))
