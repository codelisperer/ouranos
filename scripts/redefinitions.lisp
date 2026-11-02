;;;; redefinitions.lisp --- a definition in one file replaced by one in another (#577, #1121)
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
;;;; and prints one line, starting with +MARKER+, for each definition replaced from a different
;;;; source file, naming the kind of definition, its name and both files. The parent reads those
;;;; lines with REDEFINITIONS-IN and fails the system.
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
;;;; WHAT IT CATCHES. DEFUN, DEFMACRO, DEFGENERIC, and a DEFMETHOD with the same qualifiers and
;;;; specializers as a method from another file: SBCL signals SB-KERNEL:REDEFINITION-WARNING for
;;;; each (#1121 added the last three). A method on other specializers adds to the generic
;;;; function and is not a redefinition. Not caught: DEFPARAMETER, DEFVAR, DEFSTRUCT and
;;;; DEFCLASS, for which SBCL signals nothing of this kind, and a function replaced with
;;;; (SETF FDEFINITION) or (SETF SYMBOL-FUNCTION).
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
  "The start of each line a child prints for a definition replaced from another file.")

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

(defun %location-file (location)
  "The truename of the file a definition source LOCATION names, or NIL."
  (let ((name (and location (sb-c:definition-source-location-namestring location))))
    (and name (ignore-errors (probe-file name)))))

(defun %kind (c)
  "The definition form that signalled redefinition warning C, as a string."
  (typecase c
    (sb-kernel:redefinition-with-defun "defun")
    (sb-kernel:redefinition-with-defmacro "defmacro")
    (sb-kernel:redefinition-with-defgeneric "defgeneric")
    (sb-kernel:redefinition-with-defmethod "defmethod")
    (t nil)))

(defun %new-file (c)
  "The truename of the file the new definition in C comes from, or NIL. A DEFUN's condition
carries the new function, and its location slot is unbound; the others carry the location."
  (if (and (slot-exists-p c 'sb-kernel::new-function) (slot-boundp c 'sb-kernel::new-function))
      (%source-file (slot-value c 'sb-kernel::new-function))
      (and (slot-boundp c 'sb-kernel::new-location)
           (%location-file (slot-value c 'sb-kernel::new-location)))))

(defun %old-file (c name)
  "The truename of the file the definition C replaces comes from, or NIL. The handler runs
before the replacement, so the old definition is still in place."
  (typecase c
    (sb-kernel:redefinition-with-defmethod (%source-file (slot-value c 'sb-kernel::old-method)))
    (sb-kernel:redefinition-with-defmacro
     (and (symbolp name) (macro-function name) (%source-file (macro-function name))))
    (t (and (fboundp name) (%source-file (fdefinition name))))))

(defun cross-file-redefinition (c roots)
  "When redefinition warning C replaces a definition from a different source file, both files
under one of the directories ROOTS: (values KIND NAME NEW-FILE OLD-FILE), KIND a string such as
\"defun\". NIL otherwise, and for a kind of redefinition not handled here."
  (let ((kind (%kind c)))
    (when kind
      (let* ((name (slot-value c 'sb-kernel::name))
             (old (%old-file c name))
             (new (%new-file c)))
        (when (and old new (not (%same-file-p old new))
                   (%under-roots-p old roots) (%under-roots-p new roots))
          (values kind name new old))))))

(defun call-reporting-redefinitions (thunk &optional roots)
  "Call THUNK. Each time a DEFUN, DEFMACRO, DEFGENERIC or DEFMETHOD replaces a definition from a
different source file, both files under one of the directories ROOTS, print one line to standard
output: +MARKER+, the kind of definition, its name with its package, then the new and the old
source file. The line is printed as it happens, so it is in the output even if THUNK then fails.
The redefinition itself goes ahead, as it would without this."
  (handler-bind ((sb-kernel:redefinition-warning
                   (lambda (c)
                     (multiple-value-bind (kind name new old) (cross-file-redefinition c roots)
                       (when kind
                         (let ((*package* (find-package "KEYWORD")))
                           (format *standard-output* "~&~A~A ~S new ~A old ~A~%" +marker+ kind
                                   name (uiop:native-namestring new) (uiop:native-namestring old)))
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
  "The lines in OUTPUT that report a definition replaced from another file, each without
+MARKER+."
  (loop for line in (uiop:split-string output :separator '(#\Newline))
        for text = (string-right-trim '(#\Return) line)
        when (uiop:string-prefix-p +marker+ text)
          collect (subseq text (length +marker+))))
