;;;; tree-deps.lisp --- which third-party systems does this tree actually depend on?
;;;;
;;;; Not a script. LOAD it, after Quicklisp if the caller needs Quicklisp:
;;;;
;;;;   (load "scripts/tree-deps.lisp")
;;;;   (tree-deps:external-dependencies)   ; => ("alexandria" "log4cl" ...)
;;;;
;;;; Two callers want the same answer for opposite reasons: check-deps.lisp asks in order
;;;; to REPORT drift against docs/dependencies.md, and install-deps.lisp asks in order to
;;;; INSTALL the set on a machine that has never seen this tree. They were one function in
;;;; one script until CI needed the second; two copies of "what does this tree depend on"
;;;; is precisely the drift the first script exists to catch, so it lives here instead.
;;;;
;;;; It asks ASDF rather than grepping the text. A regex over .asd source picks up prose
;;;; from comments and misses reader-conditional and (:version ...) forms; ASDF has already
;;;; parsed all of that. Only the system NAMES are read from text, because ASDF cannot
;;;; enumerate the systems a file defines without being told what to look for.
;;;;
;;;; `asdf:find-system` READS a .asd and builds the system object. It does not compile or
;;;; load anything, which is what makes this usable as the step BEFORE a cold build.

(require :asdf)
(require :uiop)

(defpackage #:tree-deps
  (:use #:cl)
  (:export #:*root* #:*frameworks* #:in-tree-p #:dep-name-and-guard
           #:external-dependencies #:asd-files #:template-asd-files
           #:template-name-p #:system-names-in))

(in-package #:tree-deps)

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*)))
  "The repo root -- the parent of scripts/.")

;;; Pinned to THIS tree, and deliberately AFTER any Quicklisp load the caller performed:
;;; Quicklisp reinitialises the source registry when it loads, so a registry set before it
;;; is silently discarded. That exact mistake once "verified" a branch against main.
(asdf:initialize-source-registry
 `(:source-registry (:tree ,*root*) :inherit-configuration))

(defparameter *frameworks*
  '("aion" "cons" "mnemosyne" "elenchon" "hyperion" "praxeon" "hermes")
  "Every framework that owns a .asd file. hermes is outside the DAG but is still ours.

THIS LIST ALSO CHOOSES WHICH .asd FILES ARE READ (see EXTERNAL-DEPENDENCIES, which opens
`<fw>/<fw>.asd' for each entry), and it is STALE in that role: `klio' owns klio/klio.asd and
is not here, so no system it declares is scanned and no dependency it introduces would be
reported. Nothing is wrong today because klio depends only on systems already documented --
which is luck, not a check. Tracked separately; IN-TREE-P no longer relies on this list, so
the remaining exposure is enumeration rather than classification.")

(defun in-tree-p (name)
  "True if NAME is one of our own systems rather than a third-party dependency.

ASKS ASDF WHERE THE SYSTEM LIVES, and falls back to the name list only when ASDF cannot
find it. The name test alone was wrong for any system whose name does not begin with a
framework: `contacts' -- the mnemosyne example, which keeps its own contacts.asd because
being a standalone project is the thing it demonstrates (#357) -- was reported as an
UNDOCUMENTED EXTERNAL DEPENDENCY the moment anything in the tree depended on it. It is a
directory away from the file making the claim.

The location is a measurement; the list is a claim someone has to maintain. Preferring the
measurement is the same correction made three times elsewhere in this tree today.

The fallback matters and is not belt-and-braces: a dependency ASDF cannot resolve is one we
genuinely cannot place, and for those the name is the only evidence there is. It also keeps
this working if the source registry is ever narrower than the tree."
  (let* ((sys (ignore-errors (asdf:find-system name nil)))
         (dir (and sys (ignore-errors (asdf:system-source-directory sys)))))
    (if dir
        (and (uiop:subpathp dir *root*) t)
        (let ((base (subseq name 0 (or (position #\/ name) (length name)))))
          (and (member base *frameworks* :test #'string-equal) t)))))

(defun %git-asd-files ()
  "Every .asd file the REPOSITORY TRACKS, or NIL if git cannot answer.

`git ls-files' is the precise answer to \"which .asd files does this repo carry\": it
excludes build output, vendored trees and anything ignored, without a denylist that would
itself go stale. NIL rather than an error when git is absent -- `install-deps.lisp' loads
this file and can run where git is not installed, and the caller has a fallback."
  (let* ((out (ignore-errors
               (uiop:run-program (list "git" "-C" (uiop:native-namestring *root*)
                                       "ls-files" "*.asd")
                                 :output '(:string :stripped t)
                                 :ignore-error-status t)))
         (lines (and out (plusp (length out))
                     (remove "" (uiop:split-string out :separator '(#\Newline))
                             :test #'string=))))
    (mapcar (lambda (rel) (merge-pathnames rel *root*)) lines)))

(defun %walked-asd-files ()
  "Every .asd under *ROOT*, by walking the filesystem. The fallback for a tree that is not
a git checkout -- an unpacked tarball, or a container that copied the sources in."
  (remove-if (lambda (f)
               (let ((n (namestring f)))
                 (or (search "/.git/" n) (search "/vendor/" n)
                     (search "/dist/" n) (search "/.cache/" n))))
             (directory (merge-pathnames "**/*.asd" *root*))))

(defun asd-files ()
  "Every .asd file in this tree, DISCOVERED rather than constructed.

WHY NOT `<fw>/<fw>.asd' FOR EACH NAME IN *FRAMEWORKS*, which is what this replaced (#358):
that made two assumptions and both were false. The list of names was incomplete -- klio
owns klio/klio.asd and was never in it -- and not every .asd sits at `<name>/<name>.asd',
which mnemosyne/examples/contacts/contacts.asd does not. Seven files were read where the
tree carries thirteen, so any dependency the other six introduced was invisible.

Nothing was broken by that, and the reason was luck: the unread files happened to depend
only on systems already documented. Converting luck into a check is the point.

THE FLOOR, and it is the part that makes discovery safe to rely on. Enumeration fails
DIFFERENTLY from classification: a wrong answer to \"is this system ours\" is a wrong
verdict, which someone sees; a wrong answer to \"what exists\" is silence, which reads
exactly like a clean tree. A discovery returning nothing would make EXTERNAL-DEPENDENCIES
return NIL, and check-deps would report `none -- every external dependency is documented'
while having examined no file at all: a false green produced by the fix for a false green.

So *FRAMEWORKS* stops being the definition of what to read and becomes a FLOOR that any
discovered set must clear. It keeps its only real value -- naming what must be there -- and
loses its only real danger, which was being silently incomplete."
  (let ((found (or (%git-asd-files) (%walked-asd-files))))
    (dolist (fw *frameworks*)
      (let ((required (merge-pathnames (format nil "~A/~A.asd" fw fw) *root*)))
        (when (and (probe-file required)
                   (not (find (truename required) found
                              :key (lambda (f) (ignore-errors (truename f)))
                              :test #'equal)))
          ;; One FORMAT directive per line, never a `~<newline>' continuation: on a CRLF
          ;; checkout the character after `~' is #\Return, an illegal directive that fails
          ;; at COMPILE time (AGENTS.md). Written wrong here first, which is why the note
          ;; is here rather than assumed known.
          (error "tree-deps: discovery missed ~A/~A.asd, which is present on disk. Discovery is broken, so every answer below it would be an absence rather than a result. Found ~D file~:P: ~{~A~^, ~}"
                 fw fw (length found)
                 (mapcar #'file-namestring found)))))
    (when (null found)
      (error "tree-deps: found no .asd files at all under ~A." (namestring *root*)))
    found))

(defun template-name-p (name)
  "True if NAME is a scaffolding placeholder rather than a system, e.g. `{{name}}'.

A PROPERTY, NOT A PATH. Excluding `cons/templates/' by location would be a second
hand-maintained claim about where things live -- the shape this whole change removes. A
name carrying `{{' cannot be a system under any layout.

These files are NOT checked, and that is #361's subject rather than an oversight: the real
template dependency surface is `cons/templates/<t>/template.lisp', whose `:dependencies'
are substituted for `{{deps}}' at scaffold time, so it is not a .asd file at all and no
amount of .asd enumeration reaches it."
  (search "{{" name))

(defun system-names-in (asd)
  "Every system NAME defined in ASD. Only the names are read from text -- the
dependencies come from ASDF, which has already handled reader conditionals."
  (let ((names '()) (text (uiop:read-file-string asd)) (pos 0))
    (loop
      (let ((p (search "(defsystem " text :start2 pos)))
        (unless p (return))
        (let* ((q1 (position #\" text :start (+ p 11)))
               (q2 (and q1 (position #\" text :start (1+ q1)))))
          (when q2 (push (subseq text (1+ q1) q2) names)))
        (setf pos (1+ p))))
    (nreverse names)))

(defun dep-name-and-guard (dep)
  "The system NAME a :depends-on entry refers to, and the feature expression guarding it.

Returns (values NAME GUARD), where GUARD is T for an unconditional dependency.

The guard is returned rather than discarded because the two callers need opposite things
from it, and collapsing them cost a red Windows CI leg. praxeon/web declares

  (:feature (:not :windows) \"clack-handler-woo\")
  (:feature :windows \"clack-handler-hunchentoot\")

because Woo binds libev, which does not build on Windows. A DRIFT REPORT wants both names
-- they are both part of this tree's dependency surface and both belong in
docs/dependencies.md. An INSTALLER wants only the one this platform can actually load;
asking Quicklisp for the other is asking for a system that cannot exist here."
  (typecase dep
    (string (values dep t))
    (symbol (values (string-downcase (symbol-name dep)) t))
    (cons (case (first dep)
            (:version (dep-name-and-guard (second dep)))
            (:require (dep-name-and-guard (second dep)))
            (:feature (values (nth-value 0 (dep-name-and-guard (third dep)))
                              (second dep)))
            (t (values nil t))))
    (t (values nil t))))

(defun external-dependencies (&key (table nil) (applicable-only nil))
  "Every third-party system any system in this tree depends on.

Returns a sorted list of names. With :TABLE, returns the hash-table mapping each name to
the list of OUR systems that ask for it -- which is what a drift report needs in order to
say who is responsible for a dependency.

With :APPLICABLE-ONLY, drops dependencies whose `(:feature ...)` guard this platform does
not satisfy. That is what an installer wants and what a drift report must NOT have: see
DEP-NAME-AND-GUARD."
  (let ((seen (make-hash-table :test #'equal))
        (unresolved '()))
    (dolist (asd (asd-files))
      (dolist (name (system-names-in asd))
        ;; IGNORE-ERRORS because a system may be guarded by a feature this platform does
        ;; not have; that is a fact about the platform, not a drift finding.
        (cond
          ;; FIRST, BEFORE RESOLUTION, and that ordering is a finding rather than a
          ;; preference. A template .asd is valid Lisp, so ASDF reads it happily and
          ;; returns a system literally named `{{name}}' whose :depends-on is the symbol
          ;; `{{deps}}'. Resolving first therefore SUCCEEDS and reports `{{deps}}' as an
          ;; undocumented third-party dependency -- which is what this did on its first
          ;; run. A placeholder is scaffolding whether or not ASDF can build something
          ;; out of it (#361).
          ((template-name-p name))
          (t
           (let ((sys (ignore-errors (asdf:find-system name nil))))
          (cond
            (sys
             (dolist (dep (asdf:system-depends-on sys))
               (multiple-value-bind (d guard) (dep-name-and-guard dep)
                 (when (and d (not (in-tree-p d))
                            (or (not applicable-only)
                                (eq guard t)
                                (uiop:featurep guard)))
                   (pushnew name (gethash (string-downcase d) seen)
                            :test #'string=)))))
            ;; A FILE WE FOUND AND COULD NOT READ IS WORSE THAN ONE WE NEVER FOUND,
            ;; because it looks like coverage. Before this, the IGNORE-ERRORS above
            ;; swallowed it and the system contributed nothing, silently -- which is the
            ;; false green the floor guard exists to prevent, arriving through a different
            ;; door. Collected and raised by the caller, so one bad file names itself
            ;; instead of aborting the scan of the other twelve.
            (t (push (cons name (enough-namestring asd *root*)) unresolved))))))))
    (values (if table
                seen
                (sort (loop for k being the hash-keys of seen collect k) #'string<))
            (nreverse unresolved))))

(defun template-asd-files ()
  "The .asd files whose systems are all placeholders -- scaffolding, not systems (#361).

Reported by `check-deps.lisp' rather than silently dropped, so that `we do not check these'
is a visible statement each run rather than an absence a reader has to infer."
  (remove-if-not (lambda (asd)
                   (let ((names (system-names-in asd)))
                     (and names (every #'template-name-p names))))
                 (asd-files)))
