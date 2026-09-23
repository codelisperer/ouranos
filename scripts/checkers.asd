;;;; checkers.asd --- tests for the gate's checker scripts (#459).
;;;;
;;;; NOT A FRAMEWORK. `scripts/' holds the guards `verify-tree.lisp' runs -- check-pins,
;;;; check-deps, check-asd-collisions and the rest -- and until this system existed nothing
;;;; attested that any of them could detect the thing it exists to detect. Their only
;;;; exercise was running against the real tree during a gate, which tests them in the state
;;;; the tree happens to be in; a guard's interesting behaviour is what it does when
;;;; something is wrong, and the tree is almost never wrong.
;;;;
;;;; WHY THIS IS AN ASDF SYSTEM AND NOT ANOTHER CHECKER. `verify-tree.lisp' states that the
;;;; checker block "must not contribute to the check count" -- `total checks executed' means
;;;; assertions the suites ran, and a gate check inflating it would corrupt the one number
;;;; this tree reasons with. So a checker that tested the checkers would produce no number,
;;;; and #459 exists precisely because nothing attests that these work. Closing an
;;;; invisibility problem with an invisible solution is no closure: an unregistered suite,
;;;; an unrun suite and a passing suite are identical at the exit code.
;;;;
;;;; As a suite it gets a count, a README row, and every rule the tree already has.

(defsystem "checkers"
  :description "The gate's checker scripts. A marker system; the scripts are not loadable."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :components ()
  :long-description
  "NO COMPONENTS, AND THAT IS NOT AN OVERSIGHT. The checkers are standalone scripts that end
in `uiop:quit' -- LOADing one runs it and kills the image, so none can be an ASDF component.
This system exists because ASDF requires the primary system of `checkers/tests' to be
defined, and naming it for what it covers is better than naming the test system something
that hides which scripts it is about.")

(defsystem "checkers/tests"
  :description "Can each gate checker detect what it exists to detect? Tested against trees built to break it."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; NOT "uiop". It arrives with ASDF, which arrives with SBCL, so no system in this tree
  ;; declares it and docs/dependencies.md does not list it -- that manifest records the
  ;; external dependencies the tree consciously chose, and putting uiop there would claim a
  ;; choice nobody made. `check-source-deps' treats it the same way, in +ALWAYS-AVAILABLE+.
  :depends-on ("fiveam"
               ;; To COMPUTE a fixture's sha256 rather than hand-write one. A hand-written
               ;; hash is a second copy of a fact, and the test would then be checking that
               ;; two hand-written things agree (#466).
               "ironclad")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "checkers"))))
  :perform (test-op (o c) (symbol-call :checkers/tests '#:run-tests)))
