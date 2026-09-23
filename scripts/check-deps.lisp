;;;; check-deps.lisp --- prove docs/dependencies.md still matches the .asd files.
;;;;
;;;;   sbcl --dynamic-space-size 4096 --script scripts/check-deps.lisp          # report + exit 1 on drift
;;;;   sbcl --dynamic-space-size 4096 --script scripts/check-deps.lisp --list   # just print the real set
;;;;
;;;; WHY THIS EXISTS: docs/dependencies.md is the manifest we hold the "few, cohesive,
;;;; house-owned" thesis to, and it says of itself "regenerate by re-reading the
;;;; :depends-on of all systems (a future `cons deps` command should own this)". A
;;;; hand-maintained inventory of a thing that changes silently is a claim with a
;;;; shelf life. This is the check; `cons deps` can call it later.
;;;;
;;;; It asks ASDF rather than grepping. A regex over .asd text picks up prose from
;;;; comments and misses reader-conditional and (:version ...) forms; ASDF has already
;;;; parsed all of that. The cost is that the systems must be loadable, which they are.
;;;;
;;;; The enumeration itself lives in scripts/tree-deps.lisp, because install-deps.lisp
;;;; needs the same answer for the opposite reason -- to INSTALL the set on a machine that
;;;; has never seen this tree. Two copies of "what does this tree depend on" is exactly the
;;;; drift this script exists to report.
;;;;
;;;; Drift in the two directions is not equally bad:
;;;;   UNDOCUMENTED -- a dependency in the code that nobody recorded. This is the one
;;;;     that matters. It means the tree grew a dependency without the conscious
;;;;     decision the thesis promises, and a new user's install instructions are wrong.
;;;;   STALE -- documented but no longer used. Harmless to a build, but it inflates the
;;;;     count we cite publicly, so it is still a failure.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defparameter *scripts*
  (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*)))

;;; AFTER the Quicklisp load above -- tree-deps.lisp pins the source registry to this tree,
;;; and Quicklisp reinitialises the registry when it loads.
(load (merge-pathnames "tree-deps.lisp" *scripts*))

(defparameter *root* tree-deps:*root*)

(defvar *unresolved* '()
  "(system-name . file) for every .asd DISCOVERY FOUND AND ASDF COULD NOT READ.

Not a skip. A file we found, could not parse, and therefore did not check is worse than one
we never found, because it looks like coverage -- and before pre-publication issue 358 it was swallowed by an
IGNORE-ERRORS and contributed nothing, silently.")

(defun actual-externals ()
  "Every third-party system any system in this tree depends on, and who depends on it.

The floor guard in TREE-DEPS:ASD-FILES signals when discovery comes up short, and it is
caught HERE so the operator gets the sentence rather than a backtrace. The message is the
whole value of that guard -- a stack trace under it says `something broke', where the text
says which file was missed and what was found instead. Exit 1 either way; only the reading
experience differs, and a gate nobody can read is a gate nobody acts on."
  (handler-case
      (multiple-value-bind (table unresolved) (tree-deps:external-dependencies :table t)
        (setf *unresolved* unresolved)
        table)
    (error (e)
      (format t "~&~%=== discovery ===~%")
      (format t "  ~A~%" e)
      (format t "~%  Nothing was compared. A short discovery would make every answer below~%")
      (format t "  an absence rather than a result, so this refuses instead of reporting~%")
      (format t "  that the tree is clean.~%")
      (format t "~%VERDICT: DISCOVERY FAILED~%")
      (uiop:quit 1))))

;;; --- what the manifest claims ---------------------------------------------

(defparameter +source-of-truth-sections+
  '("external deps by role" "sbcl contrib" "hermes")
  "Headings whose tables DOCUMENT a dependency. Matched as a case-folded prefix.

THE FILE HAS TWELVE SECTIONS AND THIS READS THREE (pre-publication issue 474). An earlier version read every table
row in the file, so `documented' meant `appears in any table anywhere': a name in the
Versions (pinned) snapshot satisfied the undocumented check while the externals table said
nothing about it, and twelve names that are not external ASDF dependencies looked documented.

What is out, and why each:

  Native (non-Lisp) dependencies, Vendored browser assets -- `actual-externals' reads .asd
    files and can never see either. A CHECKER THAT CANNOT OBSERVE A CATEGORY MUST NOT JUDGE
    IT, and the vendored heading says outright they are not ASDF dependencies.
  Watch list -- records dependencies we want to REMOVE. Counting it as documentation lets an
    entry earn its keep by being listed as a thing to delete.
  Per-framework footprint, Shipped into generated projects -- DERIVED VIEWS. Neither carries
    a name absent from the externals table, and treating a derived view as a source lets a
    name survive there after being removed from the source.
  Versions (pinned) -- a snapshot, and the table that made the hole visible.

`hermes' is in: its section documents real dependencies of a real system that
`actual-externals' reads, and excluding it would report every hermes dependency as
undocumented.

SBCL contrib is in PROVISIONALLY, question referred up. Those are declarable in an .asd and
so visible, but the file groups them apart because they arrive with the implementation.
Whether they count for a conscious-minimum discipline is a question about what that
discipline is for. Treated as a source until answered -- the conservative direction, since it
can only produce a missed failure, which is the status quo, rather than a false one.")

(defun %section-documents-p (heading)
  (and heading
       (some (lambda (allowed)
               (and (>= (length heading) (length allowed))
                    (string-equal allowed heading :end2 (length allowed))))
             +source-of-truth-sections+)))

(defun documented-externals ()
  "Names in the leading name column of the tables that DOCUMENT dependencies.

Scoped by section -- see +SOURCE-OF-TRUTH-SECTIONS+ for which, and why the rest are not."
  (let ((names '())
        (documenting nil)
        (lines (uiop:split-string
                (uiop:read-file-string (merge-pathnames "docs/dependencies.md" *root*))
                :separator '(#\Newline))))
    (dolist (line lines (nreverse names))
      ;; A heading at ANY level replaces the current section: `### Native (non-Lisp)
      ;; dependencies' sits under `## External deps by role' and must not inherit it.
      (when (and (plusp (length line)) (char= (char line 0) #\#))
        (setf documenting (%section-documents-p (string-left-trim "# " line))))
      (when documenting
        (let ((tick1 (and (> (length line) 2)
                          (char= (char line 0) #\|)
                          (position #\` line))))
          (when (and tick1 (< tick1 4))
            (let ((tick2 (position #\` line :start (1+ tick1))))
              (when tick2
                (let ((n (string-downcase (subseq line (1+ tick1) tick2))))
                  (pushnew n names :test #'string=))))))))))


(let* ((list-only (member "--list" (uiop:command-line-arguments) :test #'string=))
       (actual (actual-externals))
       (documented (documented-externals))
       (actual-names (sort (loop for k being the hash-keys of actual collect k) #'string<))
       (undocumented (remove-if (lambda (n) (member n documented :test #'string=)) actual-names)))

  (format t "~&~%=== external dependencies declared in the .asd files (~D) ===~%"
          (length actual-names))
  (dolist (n actual-names)
    (format t "  ~24A ~{~A~^ ~}~%" n (sort (gethash n actual) #'string<)))

  (when list-only (uiop:quit 0))

  ;; Scaffolding, named rather than dropped (pre-publication issue 361). Printing them is the difference
  ;; between "we do not check these" being a statement and being an absence.
  (let ((templates (tree-deps:template-asd-files)))
    (when templates
      (format t "~%=== templates, not checked (~D) ===~%" (length templates))
      (dolist (f templates)
        (format t "  ~A~%" (enough-namestring f *root*)))
      (format t "  Placeholder system names; the real dependency surface is~%")
      (format t "  cons/templates/<t>/template.lisp, substituted at scaffold time. See pre-publication issue 361.~%")))

  (format t "~%=== drift ===~%")
  (cond
    ;; FIRST, because it invalidates everything below it. A .asd that could not be read
    ;; contributed no dependencies, so a clean drift report beneath an unreadable file is
    ;; an answer about the files that happened to parse.
    (*unresolved*
     (format t "  UNREADABLE -- discovered, and ASDF could not build the system:~%")
     (dolist (u *unresolved*)
       (format t "    ~24A in ~A~%" (car u) (cdr u)))
     (format t "~%  These contributed no dependencies, so the report above is incomplete~%")
     (format t "  by exactly whatever they declare. A file found and not read is worse~%")
     (format t "  than one never found: it looks like coverage.~%")
     (format t "~%VERDICT: UNREADABLE~%")
     (uiop:quit 1))
    (undocumented
     (format t "  UNDOCUMENTED -- in the code, absent from docs/dependencies.md:~%")
     (dolist (n undocumented)
       (format t "    ~24A used by: ~{~A~^ ~}~%" n (sort (gethash n actual) #'string<)))
     (format t "~%  A dependency nobody recorded means the tree grew one without the~%")
     (format t "  conscious decision the thesis promises -- and a new user's install~%")
     (format t "  instructions are now wrong. Update docs/dependencies.md.~%")
     (format t "~%VERDICT: DRIFT~%")
     (uiop:quit 1))
    (t
     (format t "  none -- every external dependency in the code is documented.~%")
     (format t "~%VERDICT: IN SYNC~%")
     (uiop:quit 0))))
