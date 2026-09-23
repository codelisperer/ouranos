;;;; failure-origin-tests.lisp --- where did the gate's failure come from? (pre-publication issue 192)
;;;;
;;;; scripts/failure-origin.lisp decides whether a dead child image failed because THIS TREE
;;;; is broken or because a dependency outside the checkout is. That decision is printed in
;;;; the gate's verdict, so getting it wrong sends a reader to the wrong file -- which is the
;;;; entire defect pre-publication issue 192 is about, reintroduced one level up.
;;;;
;;;; The message below is the REAL one, pasted from the run that produced pre-publication issue 192, not a
;;;; plausible reconstruction. A classifier tested only against text someone invented while
;;;; writing the classifier tests whether the author is self-consistent.
;;;;
;;;; Tested from cons for the same reason platform-tests.lisp is: cons owns the build and
;;;; tooling surface, and this is tooling policy. Loaded BY PATH because verify-tree.lisp
;;;; reaches it that way and it belongs to no ASDF system.

(in-package #:cons/tests)

(def-suite failure-origin
  :description "Tree failure vs dependency failure, in the gate's own output (pre-publication issue 192)." :in all)
(in-suite failure-origin)

(defun %load-failure-origin ()
  "Load scripts/failure-origin.lisp -- the file scripts/verify-tree.lisp loads by path."
  (let ((path (merge-pathnames "scripts/failure-origin.lisp"
                               (asdf:system-source-directory :cons))))
    (unless (probe-file path)
      ;; cons/ is a framework directory inside the monorepo; the script lives at the ROOT.
      (setf path (merge-pathnames "../scripts/failure-origin.lisp"
                                  (asdf:system-source-directory :cons))))
    (is-true (probe-file path)
             "scripts/failure-origin.lisp must exist -- verify-tree.lisp loads it by path, so a rename breaks the gate, not just this test. Looked at ~A" path)
    (when (probe-file path) (load path))
    path))

(defmacro %fo (name &rest args)
  "Call an OURANOS-FAILURE-ORIGIN function by name at RUNTIME -- the package does not exist
until the file is loaded, so a literal symbol would be resolved by the READER and take the
whole test system down on a tree where the file moved. Same reasoning as %PF."
  `(funcall (read-from-string
             ,(concatenate 'string "ouranos-failure-origin:" (string-downcase (string name))))
            ,@args))

;;; The output that produced pre-publication issue 192, verbatim.
(defparameter +real-dependency-failure+
  "Unhandled LOAD-SYSTEM-DEFINITION-ERROR in thread #<SB-THREAD:THREAD tid=229851 \"main thread\" RUNNING {1200038003}>: Error while trying to load definition for system woo from pathname /home/bcalc/quicklisp/dists/quicklisp/software/woo-20241012-git/woo.asd: Couldn't load #P\"/home/bcalc/.cache/common-lisp/sbcl-2.6.7-linux-x64/home/bcalc/quicklisp/dists/quicklisp/software/cffi-20260101-git/toolchain/static-link.fasl\": file does not exist.
Backtrace for: #<SB-THREAD:THREAD tid=229851 \"main thread\" RUNNING {1200038003}>
0: (SB-DEBUG::DEBUGGER-DISABLED-HOOK #<LOAD-SYSTEM-DEFINITION-ERROR {120E8406F3}> #<unused argument> :QUIT T)
")

(defparameter +tree-root+ #p"/home/bcalc/projects/cl/ouranos-copilot/")

(defparameter +windows-tree-root+ "D:\\src\\ouranos\\"
  "A Windows checkout root, as a STRING.

Not a #p literal, and that is the point: SBCL on Unix cannot READ #p\"D:\\\\src\\\\...\"
-- the backslash is an escape character and the namestring parser rejects it -- so the one
host that could check the Windows path behaviour could not express the input. FOREIGN-ASDS
takes a string for exactly this reason.")

;;; --- the case that happened ------------------------------------------------

(test the-real-message-is-classified-as-a-dependency
  (%load-failure-origin)
  (multiple-value-bind (origin paths) (%fo classify +real-dependency-failure+ +tree-root+)
    (is (eq :dependency origin)
        "the woo.asd/cffi cold-cache failure is not praxeon/web's fault and must not be reported as it")
    (is (= 1 (length paths)) "exactly one .asd, and it is the foreign one: ~S" paths)
    (is (search "woo.asd" (first paths)))
    (is (not (search "ouranos-copilot" (first paths)))
        "the named path must be the DEPENDENCY's, not the tree's")))

(test the-fasl-in-the-message-is-not-mistaken-for-an-asd
  ;; The message names a .fasl as well as an .asd. Only the .asd identifies the system
  ;; definition that failed; collecting the fasl too would make the report noisier than the
  ;; raw error it replaces.
  (%load-failure-origin)
  (is (equal '("/home/bcalc/quicklisp/dists/quicklisp/software/woo-20241012-git/woo.asd")
             (%fo asd-paths +real-dependency-failure+))))

;;; --- and the case it must NOT swallow --------------------------------------

(test a-tree-system-that-fails-to-compile-stays-a-tree-failure
  (%load-failure-origin)
  (let ((text "Unhandled SB-INT:SIMPLE-PROGRAM-ERROR in thread #<SB-THREAD:THREAD>: invalid number of arguments: 2
0: (SB-DEBUG::DEBUGGER-DISABLED-HOOK ...)"))
    (is (eq :tree (%fo classify text +tree-root+))
        "a compile failure in tree code is the tree's, and must be reported as before")))

(test a-definition-error-inside-THIS-tree-is-still-the-trees-problem
  ;; A broken .asd in the checkout is exactly the failure the gate exists to catch. It is a
  ;; definition-load error like the dependency case, so ONLY the path can tell them apart --
  ;; which is why the path test is the load-bearing half of the classifier.
  (%load-failure-origin)
  (let ((text "Unhandled LOAD-SYSTEM-DEFINITION-ERROR: Error while trying to load definition for system praxeon from pathname /home/bcalc/projects/cl/ouranos-copilot/praxeon/praxeon.asd: end of file"))
    (is (eq :tree (%fo classify text +tree-root+))
        "an .asd INSIDE the checkout is the tree's own problem, however it failed")))

(test a-missing-component-is-not-reclassified
  ;; `Component "log4cl" not found` is a dependency the TREE names and does not have -- a
  ;; real finding, and one the gate caught before. It is not a definition-load error, so the
  ;; conservative classifier must leave it exactly where it was.
  (%load-failure-origin)
  (let ((text "Unhandled ASDF/FIND-COMPONENT:MISSING-DEPENDENCY: Component \"log4cl\" not found, required by #<SYSTEM \"hyperion\">"))
    (is (eq :tree (%fo classify text +tree-root+))
        "a dependency the tree NAMES and lacks is the tree's problem, not an excusable one")))

(test a-foreign-asd-without-a-definition-error-is-not-enough
  ;; Both halves are required. A stack trace can mention a third-party .asd for reasons that
  ;; have nothing to do with where the failure came from, and one loose signal is how a
  ;; classifier starts excusing real breakage.
  (%load-failure-origin)
  (let ((text "Unhandled SIMPLE-ERROR: something went wrong while reading /home/bcalc/quicklisp/software/woo/woo.asd for context"))
    (is (eq :tree (%fo classify text +tree-root+))
        "a foreign path alone must not earn :dependency")))

;;; --- the portability trap this would otherwise walk into -------------------

(test a-windows-tree-root-still-matches-its-own-paths
  ;; The tree root arrives as a pathname namestring and the message may spell separators the
  ;; other way. Comparing raw would make every path on Windows look foreign -- and would
  ;; therefore label every genuine tree failure on the Windows leg as somebody else's fault,
  ;; which is worse than the bug being fixed.
  (%load-failure-origin)
  (let ((text "Unhandled LOAD-SYSTEM-DEFINITION-ERROR: Error while trying to load definition for system praxeon from pathname D:/src/Ouranos/praxeon/praxeon.asd: oops"))
    (is (eq :tree (%fo classify text +windows-tree-root+))
        "backslash-vs-slash and case must not turn a tree path into a foreign one")))

(test classification-never-invents-a-failure
  ;; Clean output classifies as :tree with no paths -- the caller then falls back to its
  ;; original sentence. Nothing here can turn a passing run into a failing one.
  (%load-failure-origin)
  (multiple-value-bind (origin paths) (%fo classify "" +tree-root+)
    (is (eq :tree origin))
    (is (null paths))))

;;; --- the text a human actually reads ---------------------------------------
;;;
;;; The classifier being right is half of it. The gate prints a block beside the raw error,
;;; and THAT is what sends a reader to a file. Asserting on it here is the difference
;;; between "the function returns :dependency" and "the output stops blaming praxeon/web".

(test the-printed-block-names-the-dependency-and-clears-the-tree-system
  (%load-failure-origin)
  (let* ((summary nil)
         (printed (with-output-to-string (out)
                    (setf summary (%fo report-origin +real-dependency-failure+
                                       "PRAXEON/WEB" +tree-root+ out)))))
    (is (search "THIRD-PARTY" printed) "the block must say where it happened: ~S" printed)
    (is (search "woo.asd" printed) "and name the offending definition")
    (is (search "may be blameless" printed)
        "and say plainly that the named system may not be at fault")
    (is (search "pre-publication issue 192" printed) "and point at the ticket that explains it")
    ;; the summary line is what appears under VERDICT: FAIL
    (is (search "NOT tree code" summary) "the verdict line must carry it too: ~S" summary)
    (is (search "PRAXEON/WEB" summary)
        "while still naming the system, so the run is still traceable")))

(test a-tree-failure-prints-nothing-extra-and-keeps-the-old-wording
  ;; NIL is the contract: the caller falls back to its original sentence. If this returned a
  ;; string for a tree failure, every ordinary failure would gain a misleading paragraph.
  (%load-failure-origin)
  (let* ((summary nil)
         (printed (with-output-to-string (out)
                    (setf summary (%fo report-origin "Unhandled SB-INT:SIMPLE-ERROR: broken"
                                       "HYPERION" +tree-root+ out)))))
    (is (null summary) "a tree failure must not get a new sentence")
    (is (string= "" printed) "and must not print a block: ~S" printed)))
