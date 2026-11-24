;;;; check-child-scripts.lisp --- a test's child script compiles without warnings (#1086).
;;;;
;;;; Run:  sbcl --script scripts/check-child-scripts.lisp
;;;;
;;;; A child script is a .lisp file under a tests/ directory that no system in this tree
;;;; compiles: a test starts it in a separate sbcl with --script or --load, as
;;;; hyperion/tests/drain-child.lisp and praxeon/tests/mcp-stdio-server.lisp are started.
;;;; check-compile and verify-tree judge what ASDF compiles, so they never see one, and an
;;;; undefined function in it fails only if the test reaches the call. #1076 and #1083 made the
;;;; compiled code fail on such a call; this does the same for the child scripts.
;;;;
;;;; HOW. Each child script is compiled with COMPILE-FILE inside one compilation unit, in a
;;;; fresh sbcl of its own. Every `undefined function:' STYLE-WARNING it signals is a failure,
;;;; and so is every full WARNING except an undefined variable (below), which covers a call
;;;; with the wrong number of arguments. COMPILE-FILE treats each DEFUN as a definition and
;;;; reports what is still undefined when the unit ends, so a call to a function defined
;;;; further down the file is not reported. One sbcl per script, because COMPILE-FILE records
;;;; the functions a file defines in the image, and a function one script defines would hide
;;;; an undefined call to it in the next.
;;;;
;;;; WHY A SEPARATE CHECKER RATHER THAN A CHECK INSIDE EACH CHILD, which #1086 proposed. A
;;;; child that loads its own body inside WITH-COMPILATION-UNIT with a HANDLER-BIND does see
;;;; undefined functions, forward references excepted, even under --script (measured on SBCL
;;;; 2.6.9 in the review of #1088). But these scripts end by calling QUIT, which aborts the
;;;; unit before it reports anything, and the check would run only when a test starts the
;;;; child. This checker runs on every leg of the gate and needs no change to the scripts.
;;;;
;;;; COMPILE-FILE runs a script's compile-time code (EVAL-WHEN :COMPILE-TOPLEVEL forms and
;;;; macro bodies) but not its other toplevel forms, so the REQUIREs in it do not happen. The
;;;; image loads asdf and sb-bsd-sockets first, which is every package the current scripts
;;;; name when they are read. A script that names another one is reported as a failure to
;;;; compile, never passed over. COMPILE-FILE handles a read error itself and returns, so the
;;;; condition is recorded by a handler as it is signalled. *READ-EVAL* is NIL, so a `#.' in
;;;; a script is a read error rather than code run by the check.
;;;;
;;;; An undefined VARIABLE is not judged: a child script may use a variable its test defines
;;;; with --eval before loading it, as server-uv-template-child.lisp uses
;;;; CL-USER::*PROJECT-ROOT*, which is an undefined-variable WARNING when compiled alone.
;;;;
;;;; A DATA FILE under tests/ must not end in .lisp. COMPILE-FILE would compile a fixture such
;;;; as `(:name "fixture")' as a call to :NAME and fail the gate; give it another extension,
;;;; such as .sexp.
;;;;
;;;; Which files are child scripts is found, not listed: every .lisp under a tests/ directory
;;;; whose path is not a component of a system some .asd in this tree defines. A directory
;;;; that holds a template.lisp is a cons template, checked by `cons template check', and
;;;; is skipped with everything below it.

(require :asdf)
(require :uiop)

(load (merge-pathnames "tree-root.lisp" (uiop:pathname-directory-pathname *load-truename*)))

(defpackage #:check-child-scripts (:use #:cl))
(in-package #:check-child-scripts)

;;; TRUENAME, because the files below are found by walking the directory and ASDF gives their
;;; truenames. On a Windows runner TEMP is the 8.3 alias `C:\Users\RUNNER~1\...' and TRUENAME
;;; gives the long name (pre-publication issue 510); with the alias here, no system's directory
;;; was under the root, so every file in a fixture's tests/ was reported as a child script.
(defvar *root* (truename (tree-root:resolve-or-die *load-truename* "check-child-scripts")))

;;; This tree only. With the machine's registry inherited, ASDF resolves a system to another
;;; checkout that defines the same name, and that checkout's files are the ones it reports as
;;; compiled, so every test file here looked like a child script (measured in a worktree).
(asdf:initialize-source-registry
 `(:source-registry (:tree ,*root*) :ignore-inherited-configuration))

(defparameter +skipped-directories+ '(".git" "vendor" "dist" "_build")
  "Directory names the walk does not enter: git's own, and build output.")

(defun %template-directory-p (dir)
  (probe-file (merge-pathnames "template.lisp" dir)))

(defun %files (dir type)
  "Every file of TYPE under DIR, outside skipped and template directories."
  (unless (or (member (car (last (pathname-directory dir))) +skipped-directories+
                      :test #'equal)
              (%template-directory-p dir))
    (append (remove-if-not (lambda (p) (equal (pathname-type p) type))
                           (uiop:directory-files dir))
            (loop for sub in (uiop:subdirectories dir) append (%files sub type)))))

(defun %compiled-files ()
  "The truenames of every source file a system in this tree's .asd files names. The .asd
files are loaded, which defines their systems and loads nothing else."
  (let ((compiled (make-hash-table :test #'equal)))
    (dolist (asd (%files *root* "asd"))
      (unless (search "{{" (namestring asd))
        (asdf:load-asd asd)))
    (labels ((walk (component)
               (typecase component
                 (asdf:cl-source-file
                  (let ((path (probe-file (asdf:component-pathname component))))
                    (when path (setf (gethash (namestring path) compiled) t))))
                 (asdf:parent-component
                  (mapc #'walk (asdf:component-children component))))))
      (asdf:map-systems
       (lambda (system)
         (let ((dir (asdf:system-source-directory system)))
           (when (and dir (uiop:subpathp dir *root*))
             (walk system))))))
    compiled))

(defun child-scripts ()
  "Every .lisp under a tests/ directory that no system in this tree compiles, sorted."
  (let ((compiled (%compiled-files)))
    (sort (remove-if (lambda (file)
                       ;; Relative to the root: a checkout under a directory named tests/
                       ;; would otherwise make every uncompiled file qualify (#1088 review).
                       (or (not (member "tests" (pathname-directory
                                                 (uiop:enough-pathname file *root*))
                                        :test #'equal))
                           (gethash (namestring (truename file)) compiled)))
                     (%files *root* "lisp"))
          #'string< :key #'namestring)))

(defparameter +child-program+
  "(progn
  (let ((file (second (member \"--\" sb-ext:*posix-argv* :test (function string=))))
        (fasl (uiop:tmpize-pathname
               (uiop:merge-pathnames* \"check-child-scripts.fasl\" (uiop:temporary-directory))))
        (found '())
        (errors '()))
    (handler-case
        (unwind-protect
             (handler-bind (((or error sb-c:compiler-error)
                              (lambda (e)
                                (push (substitute #\\Space #\\Newline (princ-to-string e)) errors)))
                            (warning
                              (lambda (w)
                                (let ((text (substitute #\\Space #\\Newline (princ-to-string w))))
                                  (cond ((typep w 'style-warning)
                                         (when (uiop:string-prefix-p \"undefined function: \" text)
                                           (push text found)))
                                        ((not (uiop:string-prefix-p \"undefined variable: \" text))
                                         (push (concatenate 'string \"WARNING: \" text) found))))
                                (muffle-warning w))))
               (with-compilation-unit (:override t)
                 (let ((*standard-output* (make-broadcast-stream))
                       (*error-output* (make-broadcast-stream))
                       (*read-eval* nil))
                   (compile-file file :output-file fasl))))
          (uiop:delete-file-if-exists fasl))
      (error (e)
        (format t \"~&COMPILE-ERROR ~A~%\" (substitute #\\Space #\\Newline (princ-to-string e)))
        (uiop:quit 1)))
    (when errors
      (format t \"~&COMPILE-ERROR ~A~%\" (first (last errors)))
      (uiop:quit 1))
    (dolist (text (reverse found)) (format t \"~&UNDEFINED ~A~%\" text))
    (format t \"~&COMPILED~%\")
    (uiop:quit 0)))"
  "What the fresh sbcl runs on one child script, which follows `--' on its command line, after
two --eval forms that load asdf and sb-bsd-sockets: this form is read before it runs, so the
packages it names must exist by then. It is read in CL-USER, so it names only CL, UIOP, SB-EXT
and SB-C symbols. SB-C:COMPILER-ERROR, which COMPILE-FILE signals for a read error, is not an
ERROR. It prints an UNDEFINED line per undefined function and per full WARNING other than an
undefined variable, then COMPILED; a script it cannot compile prints COMPILE-ERROR.")

(defun check-script (file)
  "Compile FILE in a fresh sbcl. (values UNDEFINED-LINES PROBLEM), where PROBLEM is NIL or why
the compile could not be judged."
  (let* ((output (nth-value 0 (uiop:run-program
                               (list (namestring sb-ext:*runtime-pathname*)
                                     "--noinform" "--non-interactive" "--no-sysinit"
                                     "--no-userinit"
                                     "--eval" "(require :asdf)"
                                     "--eval" "(require :sb-bsd-sockets)"
                                     "--eval" +child-program+
                                     "--" (namestring file))
                               :output :string :error-output :output
                               :ignore-error-status t)))
         (lines (uiop:split-string output :separator '(#\Newline)))
         (undefined (loop for line in lines
                          when (uiop:string-prefix-p "UNDEFINED " line)
                            collect (subseq line (length "UNDEFINED "))))
         (error-line (find-if (lambda (line) (uiop:string-prefix-p "COMPILE-ERROR " line))
                              lines)))
    (values undefined
            (cond (error-line (subseq error-line (length "COMPILE-ERROR ")))
                  ((not (find "COMPILED" lines :test #'string=))
                   (format nil "the compile did not finish: ~A"
                           (string-trim '(#\Newline) output)))))))

(defun main ()
  (let ((scripts (child-scripts))
        (failed 0))
    ;; A walk that found nothing has checked nothing, and would print the same ok line as one
    ;; that checked everything.
    (when (null scripts)
      (format t "check-child-scripts: FAIL -- found no child script under a tests/ directory~%")
      (uiop:quit 1))
    (dolist (file scripts)
      (let ((name (enough-namestring file *root*)))
        (multiple-value-bind (undefined problem) (check-script file)
          (cond (problem
                 (incf failed)
                 (format t "  FAIL    ~A~%          could not be compiled: ~A~%" name problem))
                (undefined
                 (incf failed)
                 (format t "  FAIL    ~A~%~{          ~A~%~}" name undefined))
                (t (format t "  ok      ~A~%" name))))))
    (cond ((zerop failed)
           (format t "check-child-scripts: ok -- ~D child script~:P, ~A~%"
                   (length scripts) "no undefined function and no compiler warning")
           (uiop:quit 0))
          (t
           (format t "check-child-scripts: FAIL -- ~D of ~D child script~:P~%"
                   failed (length scripts))
           (format t "Correct each function or warning named above. A child script~%")
           (format t "runs in a separate sbcl, so check-compile and the gate's LOADING never~%")
           (format t "compile it.~%")
           (uiop:quit 1)))))

(main)
