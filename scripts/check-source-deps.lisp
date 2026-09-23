;;;; check-source-deps.lisp --- does every system declare what its source actually uses?
;;;;
;;;;   sbcl --dynamic-space-size 4096 --script scripts/check-source-deps.lisp
;;;;   sbcl --dynamic-space-size 4096 --script scripts/check-source-deps.lisp --list
;;;;
;;;; WHY THIS EXISTS, and why check-deps.lisp does not already answer it (#162).
;;;;
;;;; check-deps.lisp compares the .asd files against docs/dependencies.md. Both are
;;;; DECLARATIONS. When they agree it has established that two statements of intent match
;;;; each other, which is a real thing to know and is not this thing: nothing compares
;;;; either of them against what the source code actually uses.
;;;;
;;;; The instance that exposed it: praxeon/src/web.lisp and praxeon/src/workflow.lisp both
;;;; use `aion/dynamic:' directly. praxeon.asd does not list `aion/dynamic'. It builds,
;;;; because `aion/log' lists it and praxeon lists `aion/log'. check-deps passes, because
;;;; the .asd and the manifest agree -- neither mentions it. The dependency is real,
;;;; undeclared, and load-bearing at a distance: the day aion/log stops needing
;;;; aion/dynamic, praxeon breaks in a file nobody was editing.
;;;;
;;;; HOW IT READS THE SOURCE, and the property that makes it possible.
;;;;
;;;; Every cross-package reference in this tree is QUALIFIED -- `llm:complete',
;;;; `aion/dynamic:inheriting' -- because the house style is package-per-module with
;;;; :local-nicknames rather than :use. Measured across 189 defpackage forms, the only
;;;; things any package :uses are cl, common-lisp, fiveam, coalton and coalton-prelude. No
;;;; project package is :used by another one anywhere.
;;;;
;;;; That is what makes a text scan complete rather than approximate. A package that :uses
;;;; a sibling inherits its symbols, and the source then refers to them with NO PREFIX --
;;;; invisible here, and the dependency would be real. So this check tests that condition
;;;; and says when it stops holding, rather than carrying it as a caveat in a comment. See
;;;; `enabling-condition-violations'. A check whose coverage can shrink silently is the
;;;; defect this file exists to remove.
;;;;
;;;; IT DOES NOT LOAD THE TREE. `asdf:find-system' reads a .asd and builds the system
;;;; object without compiling anything, so this runs before a cold build and costs seconds.
;;;;
;;;; RUN IT FROM INSIDE THE TREE IT IS CHECKING. It locates the tree from its own
;;;; `*load-truename*', through scripts/tree-deps.lisp, so a copy of this file somewhere
;;;; else analyses whatever tree sits around that copy. Run from a scratch directory it
;;;; errors rather than reporting on the wrong tree. Note what that does and does not cover:
;;;; a scratch directory with no .asd files beneath it errors, and a copy sitting in ANOTHER
;;;; CHECKOUT analyses that checkout without complaint. For a reader the second case is a
;;;; wrong report; for a writer it was pre-publication issue 450 -- check-readme-counts.lisp resolved its README
;;;; the same way, reported success, and had written to a different checkout than the
;;;; caller's. That script now takes its root from the caller's working directory and refuses
;;;; when the two disagree; this one still roots the way described above.

(require :asdf)
(require :uiop)

(defparameter *script* (or *load-truename* *load-pathname*))
(defparameter *scripts* (uiop:pathname-directory-pathname *script*))

;;; THE READER IS GUARDED TOO (pre-publication issue 480). "A wrong report is recoverable, you can read it twice"
;;; does not survive contact with how a green checker is actually treated, which is that
;;; nobody reads it at all. Run from another checkout this used to report on ITS tree and
;;; exit 0 or 1 as though the answer were about the tree you are standing in.
;;;
;;; BEFORE tree-deps.lisp, which initialises a source registry rooted at the tree: resolving
;;; after that would point ASDF at one tree and then refuse on account of another.
(load (merge-pathnames "tree-root.lisp" *scripts*))
(tree-root:resolve-or-die *script* "check-source-deps")

(load (merge-pathnames "tree-deps.lisp" *scripts*))

(defpackage #:check-source-deps
  (:use #:cl)
  (:local-nicknames (#:td #:tree-deps))
  (:export #:main))

(in-package #:check-source-deps)

(defparameter +always-available+
  '("cl" "common-lisp" "keyword" "uiop" "asdf" "cl-user" "common-lisp-user")
  "Packages every SBCL image has before any system is loaded, so using them declares
nothing. `sb-' prefixed packages are handled by `implementation-package-p' rather than
listed, because the set is long and stable and SBCL owns it.")

(defun implementation-package-p (name)
  (or (member name +always-available+ :test #'string-equal)
      (and (> (length name) 3) (string-equal "sb-" (subseq name 0 3)))))

;;; --- reading the declarations ------------------------------------------------

(defun %forms-in (path)
  "The top-level forms in PATH that could be read, stopping at the first that could not.

STOPPING RATHER THAN SKIPPING. A form that fails to read is usually a reader macro, and
everything after it in that file is being read in a state this function does not understand.
Continuing would produce forms that look right and are not. `defpackage' forms sit at the
top of a file, which is the part this reads successfully."
  (with-open-file (in path :external-format :utf-8 :if-does-not-exist nil)
    (when in
      (let ((*read-eval* nil)
            (*package* (find-package :cl-user))
            (forms '()))
        (loop
          (let ((form (handler-case (read in nil :eof)
                        (error () :eof)
                        (storage-condition () :eof))))
            (when (eq form :eof) (return))
            (push form forms)))
        (nreverse forms)))))

(defun %defpackage-p (form)
  (and (consp form)
       (symbolp (car form))
       (string-equal "DEFPACKAGE" (symbol-name (car form)))))

(defun %name-of (designator)
  "DESIGNATOR as a string, for the `#:foo' / `\"foo\"' / `:foo' spellings a defpackage uses."
  (typecase designator
    (string designator)
    (symbol (symbol-name designator))
    (t (princ-to-string designator))))

(defun %clause (form key)
  "The clause of FORM whose head names KEY, or NIL."
  (find-if (lambda (c) (and (consp c) (symbolp (car c))
                            (string-equal key (symbol-name (car c)))))
           (cddr form)))

(defstruct (pkg (:constructor make-pkg))
  (name "" :type string)
  (nicknames '() :type list)      ; (nick . real) as strings
  (uses '() :type list)           ; package names as strings
  (file nil))

(defun %read-package (form path)
  (make-pkg
   :name (%name-of (second form))
   :file path
   :uses (mapcar #'%name-of (rest (%clause form "USE")))
   :nicknames (loop for entry in (rest (%clause form "LOCAL-NICKNAMES"))
                    when (and (consp entry) (cdr entry))
                      collect (cons (%name-of (first entry))
                                    (%name-of (second entry))))))

;;; --- which system owns which file --------------------------------------------

(defun %source-files (system)
  "Every source file SYSTEM lists, walking its module tree."
  (let ((files '()))
    (labels ((walk (component)
               (typecase component
                 (asdf:cl-source-file
                  (let ((p (asdf:component-pathname component)))
                    (when p (push (truename* p) files))))
                 (asdf:parent-component
                  (mapc #'walk (asdf:component-children component))))))
      (handler-case (walk system)
        (error () nil)))
    (remove nil files)))

(defun truename* (path)
  (handler-case (truename path) (error () nil)))

(defun in-tree-systems ()
  "Every system this tree defines, as (name . system-object). Templates are excluded: they
are source for GENERATED projects and are not built here."
  (let ((out '()))
    (dolist (asd (td:asd-files) (nreverse out))
      (dolist (name (td:system-names-in asd))
        (unless (td:template-name-p name)
          (let ((sys (handler-case (asdf:find-system name nil) (error () nil))))
            (when sys (push (cons name sys) out))))))))

;;; --- scanning the source for qualified references -----------------------------

(defun %strip-noise (text)
  "TEXT with comments and string contents blanked out, preserving length and line breaks.

WHY THIS IS NOT OPTIONAL. Without it, this check reported that aion/uv uses
hyperion/desktop -- from a docstring whose sentence says that a function here duplicates
hyperion/desktop:image-directory deliberately. That is a sentence ABOUT a dependency, not a
dependency, and aion cannot depend on hyperion at all: the DAG forbids it and ASDF would
refuse. The first run produced 58 findings with an unknown fraction of that kind, and that
is not a safe direction to over-report in. A reader who cannot separate the real findings
from prose stops reading the report, and a check nobody acts on is the thing this ticket is
about.

Blanks rather than deletes, so every position still matches the real file.

Handles line comments, nested block comments, string literals with escapes, and the
character literals for semicolon and double-quote, which otherwise look like the start of
a comment or a string."
  (let* ((n (length text))
         (out (make-string n :initial-element #\Space))
         (i 0))
    (flet ((keep (j) (setf (char out j) (char text j))))
      (loop while (< i n)
            do (let ((c (char text i)))
                 (cond
                   ;; character literal: #\x -- copy it whole, it cannot open anything
                   ((and (char= c #\#) (< (1+ i) n) (char= (char text (1+ i)) #\\))
                    (dotimes (k (min 3 (- n i))) (keep (+ i k)))
                    (incf i 3))
                   ;; block comment, nesting
                   ((and (char= c #\#) (< (1+ i) n) (char= (char text (1+ i)) #\|))
                    (let ((depth 1))
                      (incf i 2)
                      (loop while (and (< i n) (plusp depth))
                            do (cond ((and (char= (char text i) #\#) (< (1+ i) n)
                                           (char= (char text (1+ i)) #\|))
                                      (incf depth) (incf i 2))
                                     ((and (char= (char text i) #\|) (< (1+ i) n)
                                           (char= (char text (1+ i)) #\#))
                                      (decf depth) (incf i 2))
                                     (t (when (char= (char text i) #\Newline)
                                          (keep i))
                                        (incf i))))))
                   ;; line comment
                   ((char= c #\;)
                    (loop while (and (< i n) (char/= (char text i) #\Newline))
                          do (incf i)))
                   ;; string literal
                   ((char= c #\")
                    (incf i)
                    (loop while (< i n)
                          do (let ((d (char text i)))
                               (cond ((char= d #\\) (incf i 2))
                                     ((char= d #\") (incf i) (return))
                                     (t (when (char= d #\Newline) (keep i))
                                        (incf i))))))
                   (t (keep i) (incf i))))))
    out))

(defun %qualified-prefixes (text)
  "Every PACKAGE in a `package:symbol' or `package::symbol' reference in TEXT.

Text, not `read'. Reading would intern symbols in packages that may not exist yet and would
fail on the first reader macro. This over-reports into strings and comments, which is the
safe direction: a false hit names a package that is either already declared -- in which case
nothing is reported -- or genuinely undeclared and worth a human look."
  (let ((found '())
        (n (length text))
        (i 0))
    (flet ((token-char-p (c)
             (or (alphanumericp c) (find c "-/*+<>=!?%&_."))))
      (loop while (< i n)
            do (let ((c (char text i)))
                 (cond
                   ((char= c #\:)
                    ;; Walk back over the token before the colon.
                    (let ((end i) (start i))
                      (loop while (and (> start 0) (token-char-p (char text (1- start))))
                            do (decf start))
                      (let ((after (let ((j i))
                                     (loop while (and (< j n) (char= (char text j) #\:))
                                           do (incf j))
                                     j)))
                        (when (and (> end start)
                                   ;; not a keyword (:foo), not #:foo, not ::foo at a start
                                   (or (zerop start)
                                       (not (find (char text (1- start)) "#:")))
                                   (< after n)
                                   (token-char-p (char text after)))
                          (push (string-downcase (subseq text start end)) found))
                        (setf i after))))
                   (t (incf i))))))
    (remove-duplicates found :test #'string=)))

(defun %in-package-of (forms)
  (let ((form (find-if (lambda (f)
                         (and (consp f) (symbolp (car f))
                              (string-equal "IN-PACKAGE" (symbol-name (car f)))))
                       forms)))
    (and form (%name-of (second form)))))

(defun %file-text (path)
  (handler-case
      (with-open-file (in path :external-format :utf-8)
        (let ((s (make-string (file-length in))))
          ;; READ-SEQUENCE's RESULT, not FILE-LENGTH. On a UTF-8 file with any multi-byte
          ;; character the byte length exceeds the character count, and the tail of the
          ;; string would be uninitialised.
          (subseq s 0 (read-sequence s in))))
    (error () "")))

;;; --- the enabling condition ---------------------------------------------------

(defun enabling-condition-violations (packages)
  "Project packages that :use another project package.

THIS CHECK IS COMPLETE ONLY WHILE THIS LIST IS EMPTY. A package that :uses a sibling
inherits its symbols, and the source then names them with no prefix -- so the reference is
invisible to `%qualified-prefixes' and the dependency it implies is never reported. That is
not a caveat to put in a docstring: it is a silent reduction in what this check covers,
caused by a legitimate choice somebody makes in a different file for good reasons. So it is
reported, and the report says the results are now partial."
  (let ((project (mapcar #'pkg-name packages)))
    (loop for p in packages
          append (loop for used in (pkg-uses p)
                       when (member used project :test #'string-equal)
                         collect (cons (pkg-name p) used)))))

;;; --- the check -----------------------------------------------------------------

(defun analyse ()
  "Returns (values findings packages package-owner), findings as plists."
  (let ((packages '())
        (owner (make-hash-table :test #'equalp))   ; package name -> system name
        (file-system (make-hash-table :test #'equalp))
        (file-forms (make-hash-table :test #'equalp))
        (systems (in-tree-systems)))
    ;; Pass one: who owns which file, and what packages does each file define?
    (dolist (entry systems)
      (dolist (path (%source-files (cdr entry)))
        (setf (gethash path file-system) (car entry))
        (let ((forms (or (gethash path file-forms)
                         (setf (gethash path file-forms) (%forms-in path)))))
          (dolist (form forms)
            (when (%defpackage-p form)
              (let ((p (%read-package form path)))
                (push p packages)
                (setf (gethash (pkg-name p) owner) (car entry))))))))
    ;; Pass two: what does each file reference, and is its owner declared?
    (let ((findings '()))
      (dolist (entry systems)
        (let* ((name (car entry))
               (declared (mapcar (lambda (d) (string-downcase (or (td:dep-name-and-guard d) "")))
                                 (asdf:system-depends-on (cdr entry)))))
          (dolist (path (%source-files (cdr entry)))
            (let* ((forms (gethash path file-forms))
                   (current (%in-package-of forms))
                   (self (find current packages :key #'pkg-name :test #'string-equal))
                   (text (%strip-noise (%file-text path))))
              (dolist (prefix (%qualified-prefixes text))
                (let* ((resolved (or (cdr (assoc prefix (and self (pkg-nicknames self))
                                                 :test #'string-equal))
                                     prefix))
                       (owning (gethash resolved owner)))
                  (when (and owning
                             (not (string-equal owning name))
                             (not (implementation-package-p resolved))
                             (not (member owning declared :test #'string-equal)))
                    (pushnew (list :system name :uses owning :package resolved
                                   :file (enough-namestring path td:*root*))
                             findings :test #'equal))))))))
      (values (nreverse findings) packages owner))))

(defun main ()
  (multiple-value-bind (findings packages) (analyse)
    (let ((violations (enabling-condition-violations packages)))
      (format t "~&check-source-deps: ~D system~:P, ~D package~:P~%"
              (length (in-tree-systems)) (length packages))
      (when violations
        (format t "~%INCOMPLETE. These packages :use another project package, so their~%")
        (format t "unqualified references are invisible to this check and any dependency~%")
        (format t "they imply is NOT reported:~%")
        (dolist (v violations)
          (format t "  ~A :uses ~A~%" (car v) (cdr v))))
      (cond
        (findings
         (format t "~%USED BUT NOT DECLARED -- the source names a package whose system is~%")
         (format t "not in that system's :depends-on. It builds today only because something~%")
         (format t "else pulls it in.~%~%")
         (dolist (f findings)
           (format t "  ~A~%    uses ~A (package ~A)~%    in ~A~%"
                   (getf f :system) (getf f :uses) (getf f :package) (getf f :file)))
         (format t "~%~D finding~:P.~%" (length findings)))
        (t (format t "~%Every system declares what its source uses.~%")))
      (if (or findings violations) 1 0))))

;;; --- self-test -----------------------------------------------------------------

(defvar *failures* 0)

(defun expect (ok label)
  (if ok
      (format t "  ok    ~A~%" label)
      (progn (incf *failures*) (format t "  FAIL  ~A~%" label))))

(defun self-test ()
  "Check the scanner against inputs whose answer is known.

WHY THIS EXISTS. Nothing in the tree tests the checker scripts, and this one has already
been wrong twice: it assumed package names map to system names, and it read a docstring
mentioning a dependency as the dependency itself. Both were found by running it against the
whole tree and reading the output, which only works while somebody is reading. These are the
two failures written down as inputs, plus the cases a scanner like this usually gets wrong."
  (format t "~&check-source-deps --self-test~%")
  ;; The exact false positive that produced finding number one on the first run.
  (let ((stripped (%strip-noise
                   (format nil "(defun f ()~%  \"This duplicates hyperion/desktop:image-directory.\"~%  (real/pkg:call))"))))
    (expect (null (member "hyperion/desktop" (%qualified-prefixes stripped) :test #'string=))
            "a package named inside a docstring is not a reference")
    (expect (member "real/pkg" (%qualified-prefixes stripped) :test #'string=)
            "and a real reference in the same file still is"))
  ;; The control for the control: without stripping, the docstring DOES look like a use.
  (expect (member "hyperion/desktop"
                  (%qualified-prefixes "  \"duplicates hyperion/desktop:image-directory.\"")
                  :test #'string=)
          "the stripper is doing the work -- unstripped, the docstring reads as a use")
  (expect (null (member "hyperion/desktop"
                        (%qualified-prefixes (%strip-noise ";; see hyperion/desktop:thing~%"))
                        :test #'string=))
          "a line comment is not a reference either")
  ;; Things that look like qualified references and are not.
  (expect (null (%qualified-prefixes ":keyword :another"))
          "a keyword is not a package reference")
  (expect (null (%qualified-prefixes "#:uninterned"))
          "an uninterned symbol in a defpackage is not a package reference")
  (expect (member "pkg" (%qualified-prefixes "(pkg::internal)") :test #'string=)
          "a double-colon reference counts -- reaching an internal symbol is still a use")
  ;; The enabling condition, both directions.
  (let ((clean (list (make-pkg :name "a" :uses '("cl"))
                     (make-pkg :name "b" :uses '("cl" "fiveam")))))
    (expect (null (enabling-condition-violations clean))
            "no project package :uses another -- results are complete"))
  (let ((dirty (list (make-pkg :name "a" :uses '("cl"))
                     (make-pkg :name "b" :uses '("cl" "a")))))
    (expect (equal '(("b" . "a")) (enabling-condition-violations dirty))
            "a project package :using another is reported, because it makes this check partial"))
  (format t "~%~[all self-tests passed~:;~:*~D self-test failure~:P~]~%" *failures*)
  (if (plusp *failures*) 1 0))

(uiop:quit
 (if (member "--self-test" (uiop:command-line-arguments) :test #'string=)
     (self-test)
     (main)))
