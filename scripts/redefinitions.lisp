;;;; redefinitions.lisp --- a function defined in one file and defined again in another (#577)
;;;;
;;;; Loaded by path by scripts/verify-tree.lisp and scripts/check-compile.lisp, and by the child
;;;; images they start, as compile-warnings.lisp is.
;;;;
;;;; CL lets a second DEFUN of a name replace the first without an error. When the two are in
;;;; different files, one of them is almost always a mistake, and the result depends on load
;;;; order. #568 defined a helper %PROBE-REPORT (BUNDLE) in scripts/tests/release-settings.lisp,
;;;; which loads after scripts/tests/windows-launcher.lisp, whose own %PROBE-REPORT (PROGRAM ARGS)
;;;; it replaced; four Windows launcher tests then failed with "invalid number of arguments: 2".
;;;; SBCL signals SB-KERNEL:REDEFINITION-WITH-DEFUN when that happens, but it is a STYLE-WARNING,
;;;; nothing failed on it, and the gate does not print a passing child's output.
;;;;
;;;; So the child's form runs inside CALL-REPORTING-REDEFINITIONS, which handles that condition
;;;; and prints one line, starting with +MARKER+, for each function redefined from a different
;;;; source file, naming the function and both files. The parent reads those lines with
;;;; REDEFINITIONS-IN and fails the system.
;;;;
;;;; ONLY THE CODE BEING CHECKED. Both files must lie under one of the ROOTS the caller gives: the
;;;; gate gives this tree; check-compile.lisp gives this tree and the checked system's own
;;;; directory. A test may write fixture files to a temporary directory and load them on purpose,
;;;; as hyperion's dev-reload tests do with two app.lisp files that both define DEV-492-PROBE, and
;;;; a dependency may redefine its own functions; neither is this tree's to fix.
;;;;
;;;; A redefinition within one file is not reported:
;;;; SBCL's compiler already gives the WARNING "Duplicate definition for X found in one file", and
;;;; the gate fails on that. Nor is one whose old or new source file SBCL cannot say. Two
;;;; spellings of one file, such as a relative and an absolute path, are compared by truename,
;;;; and on Windows without regard to case, so they are one file.
;;;;
;;;; WHAT IT DOES NOT CATCH. Only DEFUN: SB-KERNEL:REDEFINITION-WITH-DEFUN is the only condition
;;;; handled. A DEFMACRO, DEFGENERIC or DEFMETHOD that replaces one from another file is not
;;;; reported, nor is a function replaced with (SETF FDEFINITION) or (SETF SYMBOL-FUNCTION).
;;;;
;;;; SBCL-only, as the tree is: it reads the condition's NEW-FUNCTION slot and asks
;;;; sb-introspect where each definition came from.

(require :asdf)
(require :sb-introspect)

(defpackage #:ouranos-redefinitions
  (:use #:cl)
  (:export #:+marker+ #:call-reporting-redefinitions #:wrap-form #:redefinitions-in))

(in-package #:ouranos-redefinitions)

(defparameter +marker+ "OURANOS-REDEFINED "
  "The start of each line a child prints for a function defined in two files.")

(defun %source-file (function)
  "The truename of the source file FUNCTION was compiled from, or NIL when SBCL cannot say (a
function made by COMPILE, or one from the core) or the file no longer exists."
  (let ((path (ignore-errors
               (sb-introspect:definition-source-pathname
                (sb-introspect:find-definition-source function)))))
    (and path (ignore-errors (probe-file path)))))

(defun %same-file-p (a b)
  "Whether truenames A and B name one file. Windows file names are not case-sensitive, and
SBCL's truename keeps the case it was given."
  (funcall (if (uiop:os-windows-p) #'string-equal #'string=)
           (uiop:native-namestring a) (uiop:native-namestring b)))

(defun %under-roots-p (path roots)
  "Whether PATH, a truename, lies under one of the directories ROOTS."
  (some (lambda (root)
          (let ((dir (ignore-errors (truename (uiop:ensure-directory-pathname root)))))
            (and dir (uiop:subpathp path dir))))
        roots))

(defun call-reporting-redefinitions (thunk &optional roots)
  "Call THUNK. Each time a DEFUN replaces a function first defined in a different source file,
both files under one of the directories ROOTS, print one line to standard output: +MARKER+, the
function's name with its package, then the new and the old source file. The line is printed as
it happens, so it is in the output even if THUNK then fails. The redefinition itself goes ahead,
as it would without this."
  (handler-bind ((sb-kernel:redefinition-with-defun
                   (lambda (c)
                     (let* ((name (slot-value c 'sb-kernel::name))
                            (old (and (fboundp name) (%source-file (fdefinition name))))
                            (new (%source-file (slot-value c 'sb-kernel::new-function))))
                       (when (and old new (not (%same-file-p old new))
                                  (%under-roots-p old roots) (%under-roots-p new roots))
                         (let ((*package* (find-package "KEYWORD")))
                           (format *standard-output* "~&~A~S new ~A old ~A~%" +marker+ name
                                   (uiop:native-namestring new) (uiop:native-namestring old)))
                         (finish-output *standard-output*))))))
    (funcall thunk)))

(defparameter *this-file* (or *load-truename* *load-pathname*)
  "Where this file was loaded from, for WRAP-FORM, which is called after loading has finished.")

(defun wrap-form (form-string roots-form)
  "FORM-STRING, a form a child image is to evaluate, made to run inside
CALL-REPORTING-REDEFINITIONS. ROOTS-FORM is a form, as a string, that the child evaluates to get
the directories whose files count; it can name what only the child knows, such as a system's
source directory. The child loads this file by path first, so the wrapper names nothing it has
not defined; the symbol is looked up only when the form runs."
  (format nil "(progn (load ~S) (funcall (read-from-string \"ouranos-redefinitions:call-reporting-redefinitions\") (lambda () ~A) ~A))"
          (uiop:native-namestring
           (or *this-file* (error "redefinitions.lisp: WRAP-FORM needs the path this file was loaded from")))
          form-string roots-form))

(defun redefinitions-in (output)
  "The lines in OUTPUT that report a function defined in two files, each without +MARKER+."
  (loop for line in (uiop:split-string output :separator '(#\Newline))
        for text = (string-right-trim '(#\Return) line)
        when (uiop:string-prefix-p +marker+ text)
          collect (subseq text (length +marker+))))
