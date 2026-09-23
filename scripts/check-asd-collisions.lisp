;;;; check-asd-collisions.lisp --- two .asd files defining ONE system name (#364).
;;;;
;;;; Run:  sbcl --script scripts/check-asd-collisions.lisp
;;;;
;;;; The source registry is `(:tree <root>)', so ASDF resolves a system name to whichever
;;;; matching `.asd' it happens to find FIRST. `mnemosyne/examples/contacts/contacts.asd'
;;;; defines a system called `contacts' -- a short, ordinary word -- because being a
;;;; standalone scaffolded project is the property that example exists to demonstrate
;;;; (#357 ruled on this deliberately, and the ruling still looks right).
;;;;
;;;; WHAT THIS COSTS, and why the cost is worth a checker rather than a comment: on
;;;; 2026-09-16 a scaffolded project was committed at the repo root (2168d69, reverted by
;;;; #363). It also defined `contacts'. ASDF resolved to the root one, and the suite died
;;;; with "The name MNEMOSYNE/EXAMPLES/CONTACTS does not designate any package" -- an error
;;;; three steps from its cause, naming a package nobody had touched.
;;;;
;;;; That one was COMMITTED, so it broke for everyone at once and was found within the
;;;; hour. The case this checker is actually for is the UNCOMMITTED one: `cons init
;;;; contacts' in the repo root, a demo left behind, a scratch scaffold. That shadows the
;;;; example for ONE developer, the gate fails on their machine and passes everywhere else,
;;;; and nothing in the diff explains it.
;;;;
;;;; SO IT WALKS THE FILESYSTEM, NOT GIT, AND THAT IS THE WHOLE POINT. `git ls-files' is
;;;; the right answer to "which .asd files does this repo carry" and the WRONG answer to
;;;; "which .asd files will ASDF find", because an untracked scaffold is invisible to it.
;;;; Measured rather than assumed: with an untracked contacts.asd present, `git ls-files'
;;;; reports 0 and a filesystem walk reports 1. A checker built on git would run, pass, and
;;;; be blind to the only case it exists for -- which is the same defect as the bug.
;;;;
;;;; EXCLUSIONS COME FROM ASDF ITSELF (`*default-source-registry-exclusions*' plus the
;;;; `.nosearch' marker) rather than from a list written here. The question this answers is
;;;; "what will ASDF find", so any list of our own would be a different question that
;;;; happens to agree today.
;;;;
;;;; TEMPLATE `.asd' FILES ARE SKIPPED BY NAME, and the check for `{{' happens BEFORE any
;;;; resolution, which is the #358 trap: a template `.asd' is perfectly valid Lisp, so
;;;; anything that resolves first gets a system genuinely named `{{name}}' and no error.
;;;; The four `cons/templates/*/files/{{name}}.asd' are the ONLY duplicate names in the
;;;; tracked tree, so a checker that did not skip them would fire on a clean tree on day
;;;; one -- and a checker that cries wolf on a clean tree gets switched off.
;;;;
;;;; It reads the files as TEXT and never loads them. Loading a `.asd' to find out what it
;;;; defines runs code from an untracked directory that arrived by unknown means, which is
;;;; a poor trade for a check whose entire job is to notice that the directory is there.

(require :asdf)
(require :uiop)

(defpackage #:check-asd-collisions (:use #:cl))
(in-package #:check-asd-collisions)

(defvar *root*
  ;; Device-preserving, for the reason recorded in check-assets.lisp: `(make-pathname
  ;; :directory (butlast ...))' drops `:device' and Windows then resolves the result against
  ;; the process's current drive (#482). The consequence here was quieter than a crash and
  ;; worse for it -- a root on a drive where the tree is not contains no .asd files at all,
  ;; so this script reported `ok -- 0 .asd files, no system name defined twice' and exited 0
  ;; having read nothing. A checker that passes because it found no input is the failure this
  ;; suite exists to catch.
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))

(defparameter *exclusions*
  asdf/source-registry:*default-source-registry-exclusions*
  "ASDF's own list, VERBATIM and not added to. Anything this skips that ASDF searches is a
false negative, so a directory omitted here for being obviously uninteresting would be a
guess placed exactly where a guess costs the most. Verified against ASDF rather than
assumed from the variable name: with a colliding .asd planted in each, `_build' and
`debian' are skipped and `vendor/' and `dist/' ARE searched -- gitignored means nothing to
ASDF, which reads the filesystem.")

(defun excluded-p (dir)
  (let ((name (car (last (pathname-directory dir)))))
    (and (stringp name) (member name *exclusions* :test #'string=))))

(defun asd-files (&optional (dir *root*))
  "Every .asd under DIR that ASDF would consider, depth-first.

NO `.nosearch' HANDLING, and that absence is load-bearing. An earlier draft honoured it and
advertised it as the fix, which was wrong twice over: measured against this tree's actual
registry, a `.nosearch' stops ASDF from finding NEITHER an .asd beside it nor one in a
subdirectory below it -- not under `CL_SOURCE_REGISTRY=<root>//:' and not under the
`(:tree <root>)' drop-in `scripts/setup.sh' writes. So honouring it here would have made
this checker report ok on a tree ASDF was still resolving to the wrong file: green,
earned honestly, and blind to the one thing it exists to see."
  (unless (excluded-p dir)
    (append (remove-if-not (lambda (p) (equal (pathname-type p) "asd"))
                           (uiop:directory-files dir))
            (loop for sub in (uiop:subdirectories dir) append (asd-files sub)))))

(defun system-names-in (file)
  "The system names FILE defines, lowercased, by reading it as TEXT.

Deliberately forgiving about the form -- `(defsystem \"x\")', `#:x', `:x' and a package
prefix all appear in the wild, and this has to be right about a scaffold that came from
somewhere else, not only about the twelve .asd files in this tree."
  (let ((names '()))
    (with-open-file (in file :external-format :utf-8 :if-does-not-exist nil)
      (when in
        (loop for line = (read-line in nil)
              while line
              do (let* ((trimmed (string-left-trim '(#\Space #\Tab) line))
                        (pos (search "defsystem" trimmed :test #'char-equal)))
                   ;; Anchored at the head of the line so a `defsystem' mentioned inside a
                   ;; docstring or comment is not read as a definition.
                   (when (and pos (< pos 10) (find #\( (subseq trimmed 0 (1+ pos))))
                     (let* ((rest (string-left-trim
                                   '(#\Space #\Tab)
                                   (subseq trimmed (+ pos (length "defsystem")))))
                            (rest (string-left-trim '(#\# #\: #\") rest))
                            (end (or (position-if (lambda (c)
                                                    (member c '(#\Space #\Tab #\" #\) #\Return)))
                                                  rest)
                                     (length rest))))
                       (when (plusp end)
                         (push (string-downcase (subseq rest 0 end)) names))))))))
    (nreverse names)))

(defun template-name-p (name)
  "A name from a TEMPLATE .asd, checked before anything resolves it (#358)."
  (search "{{" name))

(defun main ()
  (let ((table (make-hash-table :test #'equal))
        (collisions '()))
    (dolist (file (asd-files))
      (dolist (name (system-names-in file))
        (unless (template-name-p name)
          (pushnew (uiop:native-namestring file) (gethash name table) :test #'string=))))
    (maphash (lambda (name files)
               (when (> (length files) 1)
                 (push (cons name (sort files #'string<)) collisions)))
             table)
    (setf collisions (sort collisions #'string< :key #'car))
    (cond
      ((null collisions)
       (format t "check-asd-collisions: ok -- ~D .asd file~:P, no system name defined twice~%"
               (length (asd-files)))
       (uiop:quit 0))
      (t
       (format t "check-asd-collisions: ~D system name~:P defined by more than one .asd file.~%~%"
               (length collisions))
       (dolist (c collisions)
         (format t "  ~a~%" (car c))
         (dolist (f (cdr c)) (format t "      ~a~%" f))
         (format t "~%"))
       ;; The message says what to DO, because the person reading it is most likely someone
       ;; whose own untracked scaffold is shadowing a tree system, and the fix is theirs and
       ;; is one command. Naming both paths is the whole improvement over the package error.
       (format t "The source registry is (:tree <root>), so ASDF resolves each of these names to~%")
       (format t "whichever file it finds FIRST, and the loser's package never gets defined -- which~%")
       (format t "surfaces far away, as `the name X does not designate any package' (#363, #364).~%")
       (format t "If one of the paths above is a scaffold of your own, MOVE IT OUTSIDE THE TREE.~%")
       (format t "A .nosearch file does not work here -- measured, not assumed: ASDF still resolves~%")
       (format t "the name to it, both beside the marker and below it. Untracked and gitignored~%")
       (format t "files both count: ASDF reads the filesystem, not the index.~%")
       (uiop:quit 1)))))

(main)
