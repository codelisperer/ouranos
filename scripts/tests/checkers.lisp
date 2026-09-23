;;;; checkers.lisp --- can each gate checker detect what it exists to detect? (#459)
;;;;
;;;; THE QUESTION IS NOT "DO THE CHECKERS PASS ON THIS TREE". They do, every gate run, and
;;;; that establishes nothing about whether they would notice if the tree were broken. The
;;;; question is whether each one detects the specific thing it was written for, on a tree
;;;; constructed to break it.
;;;;
;;;; SO EVERY TEST BUILDS A TREE ON DISK AND RUNS THE REAL SCRIPT AGAINST IT.
;;;;
;;;; On disk because it is forced, not preferred. Every checker resolves its root from its
;;;; own `*load-truename*' and none is loadable as a library -- they end in `uiop:quit', so
;;;; LOADing one runs it and kills the image. There is no in-memory surface to call.
;;;;
;;;; The alternative was to give the checkers a `--root' argument so a test could point one
;;;; at a fixture. That was refused, and the reason still holds: a flag pointing a checker at
;;;; an arbitrary tree makes the wrong-tree write a supported operation rather than an
;;;; impossible one.
;;;;
;;;; CORRECTED (#450): this said `check-source-deps' is safe because "run from outside its
;;;; tree it errors rather than analysing the wrong one". It does not. Run from tree A with
;;;; tree B's copy it analyses B and reports B's findings, exit 1, no error -- measured. It
;;;; errors only when the copy sits somewhere with no .asd files beneath it at all, which is
;;;; a different case and the only one the claim was ever true of. `check-source-deps' own
;;;; header states it precisely ("a copy of this file somewhere else analyses whatever tree
;;;; sits around that copy"); the overstatement was here, and it travelled -- #450's fix was
;;;; described as "make the writer behave like check-source-deps", which would have shipped
;;;; the same defect with a comment saying otherwise.
;;;;
;;;; What actually makes a writer safe is below: resolve the tree from the CALLER's working
;;;; directory and refuse when that disagrees with the script's own. The readers still have
;;;; the behaviour described above, and two other WRITERS still root the old way --
;;;; `fetch-cldr-plurals.lisp --write' and `mbedtls-sources.lisp', both deriving *root* from
;;;; `*load-truename*' and writing into the tree. Reported on #450 rather than fixed here.
;;;;
;;;; It is also the better shape regardless: the test writes the artefact and the checker
;;;; reads it, which is a real producer/consumer split rather than a script checking its own
;;;; output, and it exercises the file the gate actually runs, rooting included.
;;;;
;;;; TWO RULES THE FIXTURES HOLD TO.
;;;;
;;;; A genuinely fresh directory per test, never a reused path cleaned up afterwards. A
;;;; fixture that cleans up is RELYING on cleanup, and that dependency is invisible on the
;;;; platform where cleanup happens to work.
;;;;
;;;; And every fixture is the real artefact -- a real `.pin', a real `.asd' -- never a
;;;; simplified stand-in. A fixture easier than production tests something easier than
;;;; production.

(defpackage #:checkers/tests
  (:use #:cl #:fiveam)
  (:export #:run-tests))

(in-package #:checkers/tests)

(def-suite checkers)
(in-suite checkers)

(defun run-tests () (run! 'checkers))

;;; --- the harness ------------------------------------------------------------

(defparameter td-root
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-parent-directory-pathname
    (uiop:pathname-directory-pathname
     (asdf:system-relative-pathname :checkers/tests "tests/"))))
  "This tree's ROOT -- where the real coalton.pin lives, for the control below.

Two parents, not one: `system-relative-pathname' lands in `scripts/tests/', so one parent is
`scripts/' and the root is the next one up. The first version stopped at `scripts/' and the
control errored on a missing file rather than reporting a wrong answer, which is the good
failure to have.")

(defparameter *scripts*
  (uiop:pathname-directory-pathname
   (uiop:pathname-parent-directory-pathname
    (asdf:system-relative-pathname :checkers/tests "tests/")))
  "This tree's `scripts/' directory -- where the checkers under test live.")

(defun %fresh-tree ()
  "A directory that has never existed before, for one test.

Fresh rather than cleaned: a fixture reusing a path and deleting afterwards passes because
the delete worked last time, which is a dependency nobody sees until the run where it did
not. The name carries the process id and a random suffix so two runs cannot collide even if
one left its directory behind."
  (let ((dir (merge-pathnames
              (format nil "ouranos-checkers-~36R-~36R/"
                      (random (expt 2 48) (make-random-state t))
                      (random (expt 2 48) (make-random-state t)))
              (uiop:temporary-directory))))
    (ensure-directories-exist dir)
    dir))

(defun %install-checker (tree name)
  "Copy checker NAME into TREE's scripts/ so its `*load-truename*' roots at TREE.

This is what makes the fixture work rather than a trick around it: the checkers locate their
tree from where the script file is, so a checker placed in the fixture analyses the fixture.

`tree-root.lisp' travels with it (#480). Four scripts LOAD it, so a fixture without it is a
fixture the script cannot run in -- and the ones that do not load it are unaffected by its
presence, which is cheaper than a per-checker list that would go stale."
  (let* ((scripts (merge-pathnames "scripts/" tree))
         (target (merge-pathnames name scripts)))
    (ensure-directories-exist scripts)
    (uiop:copy-file (merge-pathnames name *scripts*) target)
    (uiop:copy-file (merge-pathnames "tree-root.lisp" *scripts*)
                    (merge-pathnames "tree-root.lisp" scripts))
    target))

(defun %install-root-markers (tree)
  "Make TREE look like a checkout to `tree-root' -- the REAL marker files, copied.

The markers are `bootstrap.lisp' and `scripts/verify-tree.lisp' and these are those files,
not empty stand-ins: the resolver only probes for existence today, so a stub would pass, and
a fixture that passes for a reason the production path does not rely on is the fixture rule
this file opens with. If the resolver ever reads them, this fixture keeps telling the truth."
  (ensure-directories-exist (merge-pathnames "scripts/" tree))
  (uiop:copy-file (merge-pathnames "bootstrap.lisp" td-root)
                  (merge-pathnames "bootstrap.lisp" tree))
  (uiop:copy-file (merge-pathnames "verify-tree.lisp" *scripts*)
                  (merge-pathnames "scripts/verify-tree.lisp" tree))
  tree)

(defun %run (script &rest args)
  "Run SCRIPT as the gate runs it. Returns (values exit-code output)."
  (let ((out (make-string-output-stream)))
    (let ((code (nth-value 2 (uiop:run-program
                              (append (list (namestring sb-ext:*runtime-pathname*)
                                            "--script" (namestring script))
                                      args)
                              :output out :error-output out
                              :ignore-error-status t))))
      (values code (get-output-stream-string out)))))

(defun %write (path contents)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede
                          :external-format :utf-8)
    (write-string contents s))
  path)

(defun %without-line (text substring)
  "TEXT with any line containing SUBSTRING removed.

By line, not by character. An earlier version called REMOVE-IF on the string, which removes
matching CHARACTERS -- it would have produced a pin that was corrupt in a different way and
the test would have passed for the wrong reason."
  (with-output-to-string (out)
    (dolist (line (uiop:split-string text :separator '(#\Newline)))
      (unless (search substring line)
        (write-string line out)
        (terpri out)))))

;;; --- check-asd-collisions ---------------------------------------------------
;;;
;;; What it exists to detect: two .asd files defining the same system name. ASDF's
;;; `(:tree <root>)' registry resolves such a name to whichever file it finds first, and the
;;; loser's package is never defined -- which surfaces far away as "the name X does not
;;; designate any package" (#363, #364).

(test collisions-detects-one-name-defined-by-two-files
  "The thing the checker is for. Two .asd files, same system name, and it must say so."
  (let ((tree (%fresh-tree)))
    (%write (merge-pathnames "a/thing.asd" tree)
            "(defsystem \"thing\" :description \"one\" :version \"0.0.0\")
")
    (%write (merge-pathnames "b/other.asd" tree)
            "(defsystem \"thing\" :description \"two\" :version \"0.0.0\")
")
    (multiple-value-bind (code output)
        (%run (%install-checker tree "check-asd-collisions.lisp"))
      (is (= 1 code) "a collision must fail; exit was ~D~%~A" code output)
      (is (search "thing" output) "and the report must name the colliding system: ~A" output))))

(test collisions-passes-a-tree-with-no-collision
  "The control. Without it the test above passes identically on a checker that fails on
every tree, including a correct one."
  (let ((tree (%fresh-tree)))
    (%write (merge-pathnames "a/thing.asd" tree)
            "(defsystem \"thing\" :description \"one\" :version \"0.0.0\")
")
    (%write (merge-pathnames "b/other.asd" tree)
            "(defsystem \"other\" :description \"two\" :version \"0.0.0\")
")
    (multiple-value-bind (code output)
        (%run (%install-checker tree "check-asd-collisions.lisp"))
      (is (= 0 code) "distinct names must pass; exit was ~D~%~A" code output))))

(test collisions-searches-directories-a-git-listing-would-miss
  "The property its own docstring claims and nothing verified: it walks the FILESYSTEM, so
an .asd that is untracked or gitignored still counts. The fixture is not a git repository at
all, which is the strongest form of that -- `git ls-files' would report nothing here."
  (let ((tree (%fresh-tree)))
    (%write (merge-pathnames "vendor/thing.asd" tree)
            "(defsystem \"thing\" :description \"vendored\" :version \"0.0.0\")
")
    (%write (merge-pathnames "src/thing.asd" tree)
            "(defsystem \"thing\" :description \"real\" :version \"0.0.0\")
")
    (multiple-value-bind (code output)
        (%run (%install-checker tree "check-asd-collisions.lisp"))
      (is (= 1 code)
          "a collision inside vendor/ must still be found; exit was ~D~%~A" code output))))

;;; --- check-pins -------------------------------------------------------------
;;;
;;; What it exists to detect: a `.pin' that does not say where its security advisories come
;;; from, or when they were last reviewed. Such a pin compiles perfectly -- there is no
;;; second line of defence -- which is why the checker is the only thing standing between a
;;; stale pin and nobody noticing.

(defparameter +good-pin+
  "name = libuv
version = 1.48.0
sha256 = 0000000000000000000000000000000000000000000000000000000000000000
advisories = https://github.com/libuv/libuv/security/advisories
reviewed = 2026-09-01
")

(test pins-detects-a-pin-with-no-advisory-source
  "A pin that does not say where its advisories come from. The field is the only thing
distinguishing `no advisories affect us' from `nobody looked'."
  (let ((tree (%fresh-tree)))
    (%write (merge-pathnames "libuv.pin" tree) (%without-line +good-pin+ "advisories"))
    (multiple-value-bind (code output)
        (%run (%install-checker tree "check-pins.lisp"))
      (is (/= 0 code) "a pin missing `advisories' must fail; exit was ~D~%~A" code output))))

(test pins-passes-a-complete-pin
  "The control, and the one that proves the test above is about the missing field rather
than about the checker rejecting every fixture it is handed."
  (let ((tree (%fresh-tree)))
    (%write (merge-pathnames "libuv.pin" tree) +good-pin+)
    (multiple-value-bind (code output)
        (%run (%install-checker tree "check-pins.lisp"))
      (is (= 0 code) "a complete pin must pass; exit was ~D~%~A" code output))))

;;; --- the harness itself -----------------------------------------------------

(test the-harness-runs-the-real-script-in-the-fixture
  "If `%install-checker' silently failed, every test above would run nothing and report
whatever `uiop:run-program' does with a missing file. Assert the arrangement directly."
  (let* ((tree (%fresh-tree))
         (installed (%install-checker tree "check-asd-collisions.lisp")))
    (is-true (probe-file installed)
             "the checker is inside the fixture, so its *LOAD-TRUENAME* roots there")
    (is (search (namestring tree) (namestring installed))
        "and the copy is under the fixture, not the real tree: ~A" installed)))

(test two-fixtures-do-not-share-a-directory
  "The fixtures are fresh rather than cleaned. A reused path passes because the delete
worked last time, which is a dependency nobody sees until the run where it did not."
  (is (string/= (namestring (%fresh-tree)) (namestring (%fresh-tree)))
      "each fixture gets a directory that has never existed before"))

;;; --- check-assets -----------------------------------------------------------
;;;
;;; What it exists to detect: a vendored browser asset whose bytes no longer match
;;; `ASSETS.pin', and a URL fingerprint in `hyperion/src/assets.lisp' that has gone stale
;;; against the same pin. Neither has a second line of defence -- both compile and serve
;;; perfectly wrong.
;;;
;;; WHAT THESE TESTS DO NOT DETECT, measured rather than assumed. They catch a file whose
;;; bytes moved and a fingerprint that went stale. They do NOT catch a weakening of the
;;; comparison itself: with phase one changed to compare only the first eight hex characters
;;; of the hash, all of these still pass. The tamper alters the whole file, so the prefix
;;; changes too, so catching a truncation needs two files whose sha256 share the first eight
;;; hex characters.
;;;
;;; THAT IS A TRADE, NOT AN IMPOSSIBILITY, and an earlier version of this comment said it
;;; could not be constructed, which is false. Eight hex characters is 32 bits. Targeting a
;;; SPECIFIC prefix would be 2^32 work and absurd, but any collision will do, and by the
;;; birthday bound that is around 2^16 candidates -- seconds of hashing. Generate until two
;;; agree, pin one, tamper to the other.
;;;
;;; It is not done here because the cost lands on every gate run: tens of thousands of hashes
;;; and a probabilistic search with no bound, to close one property. Judged not worth the
;;; runtime -- which a future reader can revisit, where `cannot be done' would have closed the
;;; question wrongly and permanently.
;;;
;;; So: these attest that the checker LOOKS, not that it looks at the whole hash.
;;;
;;; IT HAS TWO PHASES AND THEY FAIL INDEPENDENTLY. Phase one hashes each file; phase two
;;; compares the first eight characters as written in the source. A checker that silently
;;; lost phase two would still report ok on every byte-level change, which is the plausible
;;; regression rather than a crash -- so both phases have their own detection test.

(defun %sha256-hex (path)
  "The file's sha256, COMPUTED. A hand-written hash in a fixture is a second copy of a fact,
and a test built on one checks that two hand-written things agree."
  (string-downcase
   (with-output-to-string (s)
     (loop for b across (ironclad:digest-file :sha256 path)
           do (format s "~2,'0x" b)))))

(defun %assets-tree (&key (body "console.log('x');") tamper stale-fingerprint)
  "A tree check-assets can run against: one vendored asset, its pin, and a source file.

TAMPER rewrites the asset AFTER the pin records its hash, which is the real-world shape --
the pin was right when written and the bytes moved. STALE-FINGERPRINT leaves the bytes and
the pin agreeing but writes a wrong eight-character fingerprint in the source, which is phase
two's case and invisible to phase one."
  (let* ((tree (%fresh-tree))
         (asset (merge-pathnames "hyperion/assets/vendor/thing.min.js" tree)))
    (%write asset body)
    (let ((sha (%sha256-hex asset)))
      (%write (merge-pathnames "hyperion/assets/vendor/ASSETS.pin" tree)
              (format nil "# fixture~%thing 1.0.0 sha256 ~A~%            file     thing.min.js~%"
                      sha))
      (%write (merge-pathnames "hyperion/src/assets.lisp" tree)
              (format nil "(defparameter *assets*~%  (list (asset :name \"thing\" :fingerprint \"~A\")))~%"
                      (if stale-fingerprint "deadbeef" (subseq sha 0 8))))
      (when tamper (%write asset (concatenate 'string body " // changed"))))
    tree))

(test assets-detects-bytes-that-no-longer-match-the-pin
  "Phase one. The pin was correct when written and the file moved underneath it."
  (let ((tree (%assets-tree :tamper t)))
    (multiple-value-bind (code output) (%run (%install-checker tree "check-assets.lisp"))
      (is (= 1 code) "tampered bytes must fail; exit was ~D~%~A" code output)
      (is (search "thing" output) "and the report names the asset: ~A" output))))

(test assets-passes-a-tree-whose-bytes-match
  "The control for phase one. Without it the test above passes identically on a checker that
fails on every tree it is handed."
  (let ((tree (%assets-tree)))
    (multiple-value-bind (code output) (%run (%install-checker tree "check-assets.lisp"))
      (is (= 0 code) "matching bytes must pass; exit was ~D~%~A" code output))))

(test assets-detects-a-stale-fingerprint-while-the-bytes-are-fine
  "Phase two, and the reason it needs its own test. The bytes match the pin here, so phase
one is green -- a checker that silently lost phase two would report ok on this tree, which is
a plausible regression rather than a crash and the kind a byte-level test cannot see."
  (let ((tree (%assets-tree :stale-fingerprint t)))
    (multiple-value-bind (code output) (%run (%install-checker tree "check-assets.lisp"))
      (is (= 1 code) "a stale source fingerprint must fail; exit was ~D~%~A" code output)
      (is (search "deadbeef" output)
          "and the report shows what the source claimed, so the author can find it: ~A" output))))

;;; --- check-coalton ----------------------------------------------------------
;;;
;;; What it exists to detect: the Coalton that actually LOADS is not the one `coalton.pin'
;;; declares -- a Quicklisp dist release or a second checkout on the source registry winning
;;; the name, or a stale fasl cache serving old code from the right directory.
;;;
;;; THE FIXTURE VARIES THE PIN, NOT THE COALTON. A fixture cannot install a different Coalton
;;; -- ASDF resolves `:coalton' from the environment's source registry, not from the tree
;;; under test -- so these run against whatever Coalton this machine has and change what the
;;; pin claims about it. That is the same comparison from the other side, and it is the side
;;; a fixture can move.
;;;
;;; The control copies the tree's REAL pin, so a passing control means the checker agreed with
;;; reality rather than agreeing with anything.
;;;
;;; WHAT THESE DO NOT REACH, and it is the half the checker was written for. This file gives
;;; check-coalton a wrong PIN and confirms it notices. It never gives it a wrong COALTON --
;;; the two cases named in the checker's own header, a Quicklisp dist release or a second
;;; checkout winning `:coalton' on the source registry, and a stale fasl cache serving old
;;; code from the right directory. Both need a second Coalton installed where ASDF will find
;;; it, which is an environment the fixture would have to build rather than a file it can
;;; write.
;;;
;;; The behavioural probe in the checker exists precisely for the stale-fasl case, and nothing
;;; here exercises it. So: these attest that the comparison RUNS and reports a mismatch, not
;;; that the checker would catch the substitutions it was written to catch.

(defun %coalton-tree (&key sha)
  "A tree whose coalton.pin declares SHA, or the real pin when SHA is NIL."
  (let ((tree (%fresh-tree)))
    (if sha
        (%write (merge-pathnames "coalton.pin" tree)
                (format nil "# fixture~%sha ~A~%" sha))
        (uiop:copy-file (merge-pathnames "coalton.pin" td-root)
                        (merge-pathnames "coalton.pin" tree)))
    tree))

(test coalton-detects-a-pin-that-does-not-match-what-loads
  "The thing the checker is for, from the side a fixture can move: the pin claims a commit
the loaded Coalton is not."
  (let ((tree (%coalton-tree :sha "0000000000000000000000000000000000000000")))
    (multiple-value-bind (code output) (%run (%install-checker tree "check-coalton.lisp"))
      (is (= 1 code) "a pin naming another commit must fail; exit was ~D~%~A" code output)
      (is (search "MISMATCH" output) "and the report says so: ~A" output))))

(test coalton-passes-against-the-real-pin
  "The control, and it is stronger than the usual shape: it uses THIS TREE's actual
coalton.pin, so passing means the checker agreed with reality rather than with a fixture
built to be agreeable."
  (let ((tree (%coalton-tree)))
    (multiple-value-bind (code output) (%run (%install-checker tree "check-coalton.lisp"))
      (is (= 0 code) "the real pin must pass; exit was ~D~%~A" code output))))

;;; --- check-deps -------------------------------------------------------------
;;;
;;; What it exists to detect: the `.asd' files and `docs/dependencies.md' disagreeing about
;;; which third-party systems this tree depends on.
;;;
;;; IT NEEDS TWO SCRIPTS IN THE FIXTURE, not one. check-deps loads `tree-deps.lisp' as a
;;; library, and that file resolves the tree from its OWN `*load-truename*' -- so a fixture
;;; with only the checker in it would enumerate the real tree's .asd files while reading the
;;; fixture's manifest, and report drift that is an artefact of the fixture.
;;;
;;; IT DETECTS ONE OF THE TWO DRIFTS ITS OWN HEADER NAMES. See
;;; `deps-does-not-detect-a-documented-dependency-nothing-uses' below.

(defun %deps-tree (&key (depends "alexandria") (documented '("alexandria")))
  "A tree whose one .asd depends on DEPENDS and whose manifest lists DOCUMENTED."
  (let ((tree (%fresh-tree)))
    (%install-checker tree "tree-deps.lisp")
    (%write (merge-pathnames "pkg/thing.asd" tree)
            (format nil "(defsystem \"thing\"~%  :description \"fixture\"~%  :version \"0.0.0\"~%  :depends-on (\"~A\"))~%"
                    depends))
    ;; UNDER A REAL SECTION HEADING. The first version of this fixture wrote a bare table
    ;; with no heading, which the old permissive parser accepted -- so the fixture was easier
    ;; than the artefact and stopped working the moment the parser was scoped (#474). A
    ;; manifest with no `## External deps by role' documents nothing, which is now correct.
    (%write (merge-pathnames "docs/dependencies.md" tree)
            (format nil "# Dependency manifest~%~%## External deps by role~%~%| Name | What |~%|---|---|~%~{| `~A` | fixture |~%~}"
                    documented))
    tree))

(test deps-reads-every-asd-not-only-the-first
  "THE REGRESSION tree-deps.lisp RECORDS AS HAVING HAPPENED (#358): it once constructed the
file list from a name list instead of discovering it, so seven files were read where the tree
carried thirteen, and any dependency the other six introduced was invisible. Its own comment
says nothing broke only because the unread files happened to depend on documented systems --
`luck, not a check'.

This is the check. The undocumented dependency is introduced by the SECOND .asd, so a
checker that reads one file reports IN SYNC and exits 0 -- a subtly wrong dependency set
rather than a crash, which is the shape a real regression has."
  (let ((tree (%deps-tree :documented '("alexandria"))))
    (%write (merge-pathnames "other/second.asd" tree)
            (format nil "(defsystem \"second\"~%  :description \"fixture\"~%  :version \"0.0.0\"~%  :depends-on (\"cl-ppcre\"))~%"))
    (multiple-value-bind (code output) (%run (%install-checker tree "check-deps.lisp"))
      (is (= 1 code)
          "a dependency introduced by a second .asd must still be found; exit was ~D~%~A" code output)
      (is (search "cl-ppcre" output) "and the report names it: ~A" output))))

(defun %deps-tree-sectioned (section)
  "A tree whose manifest documents `alexandria' ONLY under SECTION."
  (let ((tree (%fresh-tree)))
    (%install-checker tree "tree-deps.lisp")
    (%write (merge-pathnames "pkg/thing.asd" tree)
            (format nil "(defsystem \"thing\"~%  :description \"fixture\"~%  :version \"0.0.0\"~%  :depends-on (\"alexandria\"))~%"))
    (%write (merge-pathnames "docs/dependencies.md" tree)
            (format nil "# Dependency manifest~%~%## External deps by role~%~%| Name | What |~%|---|---|~%~%~A~%~%| Name | What |~%|---|---|~%| `alexandria` | fixture |~%"
                    section))
    tree))

(test deps-does-not-accept-a-version-snapshot-as-documentation
  "#474. `documented' once meant `appears in any table anywhere in the file', so a name in the
Versions snapshot satisfied the undocumented check while the externals table said nothing
about it. The manifest has twelve sections; three document dependencies."
  (let ((tree (%deps-tree-sectioned "## Versions (pinned) -- snapshot")))
    (multiple-value-bind (code output) (%run (%install-checker tree "check-deps.lisp"))
      (is (= 1 code)
          "a version row is not documentation; the externals table is empty so this must fail. exit ~D~%~A"
          code output))))

(test deps-does-not-accept-a-table-whose-heading-denies-it
  "The two clearest cases, and they are clearest because their own headings say so. The watch
list records dependencies we want to REMOVE; the vendored-assets heading says outright they
are not ASDF dependencies. Counting either as documentation lets an entry earn its keep by
being listed as a thing to delete."
  (dolist (section '("## Watch list -- conscious-minimum opportunities"
                     "## Vendored browser assets (not ASDF dependencies)"))
    (let ((tree (%deps-tree-sectioned section)))
      (multiple-value-bind (code output) (%run (%install-checker tree "check-deps.lisp"))
        (is (= 1 code) "~A must not document a dependency; exit ~D~%~A" section code output)))))

(test deps-accepts-the-externals-table
  "The control for all three above. Without it they pass identically on a parser that reads
no table at all -- which would fail every tree and look like a working scope."
  (let ((tree (%deps-tree-sectioned "## External deps by role")))
    (multiple-value-bind (code output) (%run (%install-checker tree "check-deps.lisp"))
      (is (= 0 code) "the externals table IS documentation; exit ~D~%~A" code output))))

(test deps-detects-a-dependency-the-manifest-never-recorded
  "The drift that matters: the tree grew a dependency without the conscious decision the
manifest exists to record, and a new user's install instructions are now wrong."
  (let ((tree (%deps-tree :documented '())))
    (multiple-value-bind (code output) (%run (%install-checker tree "check-deps.lisp"))
      (is (= 1 code) "an undocumented dependency must fail; exit was ~D~%~A" code output)
      (is (search "alexandria" output) "and the report names it: ~A" output))))

(test deps-passes-when-the-asd-and-the-manifest-agree
  "The control. Without it the test above passes identically on a checker that fails on
every tree it is handed."
  (let ((tree (%deps-tree)))
    (multiple-value-bind (code output) (%run (%install-checker tree "check-deps.lisp"))
      (is (= 0 code) "agreement must pass; exit was ~D~%~A" code output))))

(test deps-does-not-detect-a-documented-dependency-nothing-uses
  "ASSERTS A DEFECT, DELIBERATELY, so the gap is visible in the gate rather than in a comment.

check-deps' own header names two drifts and calls the second one a failure:

  STALE -- documented but no longer used. Harmless to a build, but it inflates the
  count we cite publicly, so it is still a failure.

It is not computed. `documented' appears only inside the expression that filters
`undocumented' (check-deps.lisp:93); the reverse direction is never taken. A manifest row for
a system no .asd depends on reports IN SYNC and exits 0.

This test passes on the CURRENT behaviour. When the stale check is implemented it will fail,
which is the point -- a failing test naming its own issue is a better handover than a comment
nobody greps."
  (let ((tree (%deps-tree :documented '("alexandria" "cl-ppcre"))))
    (multiple-value-bind (code output) (%run (%install-checker tree "check-deps.lisp"))
      (is (= 0 code)
          "TODAY a stale manifest row passes. If this now fails, the stale check has been implemented and this test should become its detection test.~%~A"
          output))))

;;; --- check-readme-counts: WHICH tree does a writer write to? (#450) --------
;;;
;;; The other checkers here are readers, and a reader that resolves the wrong tree returns a
;;; wrong answer. This one WRITES, so resolving the wrong tree edits a checkout the caller
;;; never named -- and reports success, because from the script's point of view everything
;;; went right. It dirtied the hub's tree exactly that way.
;;;
;;; TWO TREES, AND THE ONLY VARIABLE IS THE WORKING DIRECTORY. Both tests use the same
;;; fixture builder and the same log; one runs the script from inside its own tree and one
;;; runs it from the other. A control that differed in anything else could not attribute the
;;; difference to the thing under test.

(defun %run-in (dir script &rest args)
  "Like %RUN but with DIR as the working directory -- the variable under test here."
  (let ((out (make-string-output-stream)))
    (let ((code (nth-value 2 (uiop:run-program
                              (append (list (namestring sb-ext:*runtime-pathname*)
                                            "--script" (namestring script))
                                      args)
                              :output out :error-output out
                              :directory (namestring dir)
                              :ignore-error-status t))))
      (values code (get-output-stream-string out)))))

(defun %fixture-readme (aion cons-checks)
  "A README with the two things this checker reads: Status rows and the provenance clause.

The row shape is the real one, prose and all -- including an issue reference in the prose,
because %REPLACE-LAST-INTEGER exists to not be fooled by it. A row without one would be a
fixture easier than production."
  (format nil "# Fixture~%~%| framework | where it is | checks |~%|---|---|---|~%~
| **aion** | **mixed** -- `aion/log` and `aion/csv` are real; the collections core *(in progress)* (#172) | ~D |~%~
| **cons** | **alpha** -- the bootstrap seed and the task runner work | ~D |~%~%~
Counts above are from the Linux CI leg at `c5b7b0b`; each suite runs in its own image.~%"
          aion cons-checks))

(defun %fixture-log (aion cons-checks &key (host "linux") (sha "deadbee"))
  "A verify-tree log in the real shape: the lines the parser anchors on, and no others.

Built rather than captured because a captured log is 5000 lines of another tree's numbers,
and every line this checker reads is here. The formats are verify-tree's own -- `ok' suite
rows, the PLATFORM banner, the SUMMARY block and the verdict."
  (format nil "========== SUITES (each in its own image) ==========~%~
  ok      AION/TESTS              ~D checks~%~
  ok      CONS/TESTS              ~D checks~%~%~
========== PLATFORM (host: ~A) ==========~%~%~
========== SUMMARY ==========~%~
commit: ~A~%~
total checks executed: ~D (axes: base+uv+view)~%~
axes: base+uv+view~%~
axes-declined: none~%~%~
VERDICT: PASS~%"
          aion cons-checks host sha (+ aion cons-checks)))

(defun %readme-fixture-tree (aion cons-checks)
  "A fresh directory that looks like a checkout of this repo, with the checker installed."
  (let ((tree (%fresh-tree)))
    (%write (merge-pathnames "README.md" tree) (%fixture-readme aion cons-checks))
    (%install-root-markers tree)
    (%install-checker tree "check-readme-counts.lisp")
    tree))

(test readme-counts-refuses-to-write-to-a-checkout-the-caller-is-not-standing-in
  "#450. The root came from `*load-truename*' alone, so running one checkout's copy of this
script from another rewrote the SCRIPT's README and left the caller's alone -- reporting
`VERDICT: UPDATED', because nothing had gone wrong from where the script was sitting. The
caller's tree stays clean, which is the half that makes it hard to notice: there is no local
diff to look at.

Both READMEs are compared byte-for-byte afterwards. Asserting only the exit code would pass
against a script that refused AFTER writing, which is the failure this is about."
  (let* ((theirs (%readme-fixture-tree 1046 569))
         (ours (%readme-fixture-tree 1046 569))
         (log (%write (merge-pathnames "verify.log" ours) (%fixture-log 2000 3000)))
         (theirs-before (uiop:read-file-string (merge-pathnames "README.md" theirs)))
         (ours-before (uiop:read-file-string (merge-pathnames "README.md" ours))))
    (multiple-value-bind (code out)
        (%run-in ours (merge-pathnames "scripts/check-readme-counts.lisp" theirs)
                 "--from" (namestring log) "--update")
      (is (= 2 code) "must refuse, got exit ~D:~%~A" code out)
      (is (search "#450" out) "the refusal should name the ticket, got:~%~A" out)
      ;; `uiop:native-namestring', not `namestring'. The refusal being searched is printed
      ;; by tree-root.lisp:89-90, which formats both paths with native-namestring, and on
      ;; Windows those are different strings -- a backslash spelling against a forward-slash
      ;; one -- so the search never matched and these two assertions failed on every Windows
      ;; checkout (#502). The two functions return the same string on Linux and macOS, which
      ;; is why this was green on both legs that gate a pull request.
      ;; TRUENAME before comparing, and computed here rather than by calling tree-root's own
      ;; `shown' (#510). The fixture paths come from `uiop:temporary-directory', which keeps
      ;; whatever spelling TEMP is set to, while the script prints a truenamed path -- and on
      ;; a host whose TEMP is a Windows 8.3 alias those are two spellings of one directory.
      ;; Calling the producer's function to build the expected string would make both sides
      ;; move together and leave this unable to disagree with it.
      (is (search (uiop:native-namestring (truename ours)) out) "it must name the tree the caller is in:~%~A" out)
      (is (search (uiop:native-namestring (truename theirs)) out) "and the tree the script lives in:~%~A" out))
    (is (string= theirs-before (uiop:read-file-string (merge-pathnames "README.md" theirs)))
        "the SCRIPT's README must be untouched -- rewriting it is the defect")
    (is (string= ours-before (uiop:read-file-string (merge-pathnames "README.md" ours)))
        "and the caller's README must be untouched too: it refused, so it wrote nothing")))

(test readme-counts-still-writes-when-the-caller-is-in-its-own-tree
  "The other direction, and the one a guard like this usually breaks.

Same fixture and same log as the refusal above; the ONLY difference is the working
directory. A guard that refused here too would pass the test above while making the script
useless, and the exit code alone cannot tell those apart."
  (let* ((tree (%readme-fixture-tree 1046 569))
         (log (%write (merge-pathnames "verify.log" tree) (%fixture-log 2000 3000)))
         (readme (merge-pathnames "README.md" tree))
         (before (uiop:read-file-string readme)))
    (multiple-value-bind (code out)
        (%run-in tree (merge-pathnames "scripts/check-readme-counts.lisp" tree)
                 "--from" (namestring log) "--update")
      (is (= 0 code) "must write from inside its own tree, got exit ~D:~%~A" code out)
      (is (search "UPDATED" out) "and say so, got:~%~A" out))
    (let ((after (uiop:read-file-string readme)))
      (is (string/= before after) "the README must actually have changed")
      (is (search "| 2000 |" after) "aion's row must carry the gate's number, got:~%~A" after)
      (is (search "| 3000 |" after) "and cons's row too, got:~%~A" after)
      (is (search "(#172)" after)
          "the prose must survive byte-for-byte, issue reference included"))))

;;; --- the shared resolver, and the rest of the class (#480) -----------------
;;;
;;; #450 fixed one writer. Two more writers and a reader rooted the same way. They share one
;;; resolver now (scripts/tree-root.lisp), so these tests come in two layers rather than
;;; repeating one end-to-end test four times:
;;;
;;;   the RESOLVER is unit-tested for the admitting case, in-process, and
;;;   each SCRIPT is tested end-to-end for the refusing case, against its real target file.
;;;
;;; That split is deliberate. The refusal is the defect and has to be proved per script --
;;; a shared resolver nobody called would pass a resolver test and still write to the wrong
;;; tree. The admitting case is one function's behaviour and does not become truer for being
;;; asserted four times through four subprocesses.
;;;
;;; EXIT CODES CANNOT CARRY THESE TESTS. mbedtls-sources exits 2 for its own usage error and
;;; the root refusal exits 2 as well, so a test reading only the code would pass against a
;;; script that had refused for entirely the wrong reason. Every assertion below reads the
;;; message.

(defun %tree-root-fn (name)
  "Load scripts/tree-root.lisp into this image and return one of its functions.

By name at run time rather than by `tree-root:foo' in source: the package does not exist
when this file is compiled, and making the suite depend on load order to read is worse than
one indirection."
  (load (merge-pathnames "tree-root.lisp" *scripts*))
  (uiop:find-symbol* name :tree-root))

(test tree-root-finds-the-checkout-from-a-subdirectory
  "Walking up is what lets the gate run from a subdirectory of its own tree, which #480 says
to assert rather than assume. A resolver that only recognised its own root would refuse
every run from inside mnemosyne/ and take the gate with it."
  (let* ((tree (%install-root-markers (%fresh-tree)))
         (deep (merge-pathnames "a/b/c/" tree))
         (root (%tree-root-fn '#:checkout-root)))
    (ensure-directories-exist deep)
    (is (uiop:pathname-equal tree (funcall root tree))
        "the root itself must resolve to itself")
    (is (uiop:pathname-equal tree (funcall root deep))
        "and a directory three levels down must resolve to the same root")
    (is (null (funcall root (uiop:temporary-directory)))
        "somewhere with no markers above it is not a checkout")))

(test tree-root-does-not-mistake-a-framework-directory-for-a-root
  "THE MARKERS WERE WRONG ONCE AND THIS IS WHY THEY CHANGED.

`README.md' + `AGENTS.md' was the first choice. Twenty directories in this tree carry a
README and three carry an AGENTS.md, so klio/ and hermes/ both matched -- and a run from
inside either would have resolved to the framework directory, disagreed with the real root,
and been refused. A false positive in the guard breaks the gate from a subdirectory, which
is the one thing #480 says to assert. The markers are the seed and the gate, which exist
only at the root.

Measured against the REAL tree, not a fixture: the claim is about this repo's layout."
  (let ((root (%tree-root-fn '#:checkout-root)))
    (dolist (sub '("klio/" "hermes/" "mnemosyne/" "docs/" "scripts/"))
      (let ((dir (merge-pathnames sub td-root)))
        (when (probe-file dir)
          (is (uiop:pathname-equal td-root (funcall root dir))
              "~A must resolve to the tree root, not to itself" sub))))))

(defun %two-tree-fixture (name &rest files)
  "Two checkouts, each with the script NAME installed and each FILE pre-created.

Returns (values theirs ours). FILES are relative paths written with a sentinel, so the
refusal can be proved by comparing them afterwards rather than by trusting the exit code --
a code passes against a script that refuses AFTER writing, which is the shape of the defect."
  (let ((trees '()))
    (dotimes (i 2)
      (let ((tree (%install-root-markers (%fresh-tree))))
        (%write (merge-pathnames "README.md" tree) (%fixture-readme 1 1))
        (%install-checker tree name)
        (dolist (f files)
          (%write (merge-pathnames f tree) "SENTINEL -- must not be rewritten"))
        (push tree trees)))
    (values (first trees) (second trees))))

(defun %refuses-across-trees (script &rest files)
  "Run THEIRS's copy of SCRIPT from OURS and assert it refused without touching FILES."
  (multiple-value-bind (theirs ours) (apply #'%two-tree-fixture script files)
    (let ((before (mapcar (lambda (f) (uiop:read-file-string (merge-pathnames f theirs))) files)))
      (multiple-value-bind (code out)
          (%run-in ours (merge-pathnames (format nil "scripts/~A" script) theirs))
        (is (= 2 code) "~A must refuse with exit 2, got ~D:~%~A" script code out)
        (is (search "which tree" out) "~A must say the two answers disagree:~%~A" script out)
        ;; native-namestring, for the reason recorded in the readme-counts test above: the
        ;; producer here is also tree-root.lisp:89-90. Which function is correct depends on
        ;; WHICH producer's message is being searched, so read the producer before changing
        ;; one of these. The other path assertion in this file, in
        ;; check-source-deps-roots-at-the-callers-tree-inside-its-own-tree, must stay
        ;; `namestring': it matches tree-deps.lisp:141, which prints plain namestring.
        (is (search (uiop:native-namestring (truename ours)) out) "~A must name the tree the caller is in" script)
        (is (search (uiop:native-namestring (truename theirs)) out) "~A must name the tree it lives in" script))
      (loop for f in files for b in before
            do (is (string= b (uiop:read-file-string (merge-pathnames f theirs)))
                   "~A must not have rewritten ~A in the other checkout" script f)
               (is (string= b (uiop:read-file-string (merge-pathnames f ours)))
                   "~A must not have rewritten ~A in the caller's tree either" script f)))))

(test fetch-cldr-plurals-refuses-a-checkout-the-caller-is-not-in
  "#480's first writer, and it writes TWICE -- the vendored rules and the pin beside them.
Both are compared, because a guard that stopped one write and not the other would leave a
pin describing data it no longer matches, which is worse than either alone."
  (%refuses-across-trees "fetch-cldr-plurals.lisp"
                         "hyperion/src/vendor/cldr-plurals.lisp"
                         "hyperion/src/vendor/PLURALS.pin"))

(test mbedtls-sources-refuses-a-checkout-the-caller-is-not-in
  "#480's second writer. Its manifest records which upstream sources a pinned build uses, so
writing it into the wrong checkout puts one tree's answer into another tree's provenance."
  (%refuses-across-trees "mbedtls-sources.lisp" "mbedtls.sources"))

(test check-source-deps-refuses-a-checkout-the-caller-is-not-in
  "The READER, and the one the ticket's premise was wrong about: it did not error when run
from outside its tree, it analysed the tree its own copy sat in and reported those findings
as though they were about the tree you were standing in."
  (multiple-value-bind (theirs ours) (%two-tree-fixture "check-source-deps.lisp")
    (multiple-value-bind (code out)
        (%run-in ours (merge-pathnames "scripts/check-source-deps.lisp" theirs))
      (is (= 2 code) "must refuse with exit 2, got ~D:~%~A" code out)
      (is (search "which tree" out) "and say the two answers disagree:~%~A" out)
      (is (not (search "systems," out))
          "and must NOT report on a tree -- a findings line here is the defect:~%~A" out))))

(test mbedtls-sources-gets-past-the-guard-inside-its-own-tree
  "The control, and it cannot be read from the exit code: this script exits 2 for its own
usage error and the root refusal exits 2 too. A test reading only the code would pass
against a script that had refused for entirely the wrong reason -- so it reads the message."
  (let ((tree (%install-root-markers (%fresh-tree))))
    (%install-checker tree "mbedtls-sources.lisp")
    (multiple-value-bind (code out)
        (%run-in tree (merge-pathnames "scripts/mbedtls-sources.lisp" tree))
      (declare (ignore code))
      (is (search "usage:" out) "must reach its own argument handling, got:~%~A" out)
      (is (not (search "which tree" out))
          "and must not have refused on the root:~%~A" out))))

(test check-source-deps-roots-at-the-callers-tree-inside-its-own-tree
  "The reader's control, and it proves WHICH tree it rooted at rather than merely that it
ran. The fixture has the markers but no `.asd' files, so tree-deps refuses -- and its
refusal names the directory it searched. That name is the assertion: it is the fixture, so
the script got past the root guard and then looked in the caller's tree."
  (let ((tree (%install-root-markers (%fresh-tree))))
    (%install-checker tree "check-source-deps.lisp")
    (uiop:copy-file (merge-pathnames "tree-deps.lisp" *scripts*)
                    (merge-pathnames "scripts/tree-deps.lisp" tree))
    (multiple-value-bind (code out)
        (%run-in tree (merge-pathnames "scripts/check-source-deps.lisp" tree))
      (declare (ignore code))
      (is (not (search "which tree" out)) "must not refuse on the root:~%~A" out)
      (is (search "found no .asd files" out)
          "must reach tree-deps' own discovery guard, got:~%~A" out)
      (is (search (namestring tree) out)
          "and must have searched the FIXTURE, naming it:~%~A" out))))

;;; --- which DRIVE does a checker root at? (#482) -----------------------------
;;;
;;; What these exist to detect: a checker that resolves its root with `(make-pathname
;;; :directory (butlast ...))', which does not carry `:device'. On Windows a device-less
;;; pathname is resolved against the drive the PROCESS is standing on, not the drive the
;;; script lives on, so a checkout on one volume running against a fixture on another
;;; computed a root pointing at a place where the tree is not.
;;;
;;; THE WORKING DIRECTORY IS THE VARIABLE, which is why these use `%RUN-IN'. Every other
;;; test in this file runs the checker from wherever the suite happens to be, and on a host
;;; where that shares a volume with `uiop:temporary-directory' the defect is invisible --
;;; which is exactly how it survived: the suite was green on Windows for anyone whose
;;; checkout sat on C:, and red for anyone whose checkout sat on D:.
;;;
;;; TWO CHECKERS, BECAUSE ONE FAILURE IS LOUD AND THE OTHER IS SILENT. `check-assets' reads
;;; a named file, so a wrong root raises FILE-DOES-NOT-EXIST and somebody notices.
;;; `check-asd-collisions' walks for `.asd' files, so a wrong root finds ZERO and it reports
;;; `ok -- 0 .asd files, no system name defined twice' and exits 0. The exit code cannot tell
;;; that apart from a clean tree, so the collisions test below asserts the collision is still
;;; FOUND rather than that the run succeeded.

(defun %other-volume-directory (tree)
  "A directory on a different volume from TREE, or NIL when this host has only one.

NIL is the honest answer rather than a fallback, because the tests using this SKIP on it.
A second volume is the whole precondition of #482: without one the caller's drive cannot be
made to differ from the fixture's, and a test that quietly ran anyway would report a pass
for a condition it never created.

Drive letters from C, and `probe-file' guarded: A: and B: are floppy aliases that can block,
and a disconnected network mapping can error rather than return NIL."
  (declare (ignorable tree))
  #+win32
  (let ((ours (pathname-device tree)))
    (loop for letter across "CDEFGHIJKLMNOPQRSTUVWXYZ"
          for root = (ignore-errors (probe-file (pathname (format nil "~A:/" letter))))
          when (and root (not (equal (string letter) ours)))
            return root)))

(test assets-roots-at-its-own-drive-not-the-callers
  "#482. Run from a checkout on another volume, `check-assets' computed its root on THAT
volume and raised FILE-DOES-NOT-EXIST reading an asset that was present the whole time.

The tree here is the passing fixture -- bytes matching their pin, nothing wrong with it --
so the only thing that can make this fail is where the script looked. Run from the fixture's
own volume it passes with the defect present, and that is why the working directory has to
move for the test to mean anything."
  (let* ((tree (%assets-tree))
         (script (%install-checker tree "check-assets.lisp"))
         (elsewhere (%other-volume-directory tree)))
    (if (null elsewhere)
        (skip "this host has one volume, so the caller's drive cannot be made to differ from the fixture's and #482 is unreachable here")
        (multiple-value-bind (code out) (%run-in elsewhere script)
          (is (= 0 code)
              "a tree whose bytes match must pass when the caller stands on ~A; exit was ~D~%~A"
              elsewhere code out)
          (is (not (search "FILE-DOES-NOT-EXIST" out))
              "and it must not have looked on the caller's drive:~%~A" out)))))

(test collisions-roots-at-its-own-drive-not-the-callers
  "#482, and the half that does not announce itself. A root on the wrong volume contains no
`.asd' files, so this checker reported `ok -- 0 .asd files, no system name defined twice' and
exited 0 -- a gate checker passing because it read nothing at all.

So the assertion is that the collision is still DETECTED from another volume. Asserting the
exit code alone would be satisfied by the defect: zero is what it returned while looking at
an empty drive."
  (let ((tree (%fresh-tree)))
    (%write (merge-pathnames "a/thing.asd" tree)
            "(defsystem \"thing\" :description \"one\" :version \"0.0.0\")
")
    (%write (merge-pathnames "b/other.asd" tree)
            "(defsystem \"thing\" :description \"two\" :version \"0.0.0\")
")
    (let ((script (%install-checker tree "check-asd-collisions.lisp"))
          (elsewhere (%other-volume-directory tree)))
      (if (null elsewhere)
          (skip "this host has one volume, so the caller's drive cannot be made to differ from the fixture's and #482 is unreachable here")
          (multiple-value-bind (code out) (%run-in elsewhere script)
            (is (= 1 code)
                "the collision must still be found when the caller stands on ~A; exit was ~D~%~A"
                elsewhere code out)
            (is (not (search "0 .asd files" out))
                "and it must have read the fixture rather than an empty drive:~%~A" out))))))

;;; --- which SPELLING does the refusal print? (#510) --------------------------
;;;
;;; What this exists to detect: a refusal that names one directory two ways. `caller-root'
;;; is walked up from `uiop:getcwd', which preserves whatever spelling the caller used;
;;; `script-root' comes from `*load-truename*', and TRUENAME resolves a Windows 8.3 alias to
;;; the long name. On a host whose TEMP is the aliased spelling -- GitHub's Windows runners
;;; set exactly that -- the message printed `C:\Users\RUNNER~1\...' on one line and
;;; `C:\Users\runneradmin\...' on the next, for one directory.
;;;
;;; THE GUARD WAS NEVER WRONG, ONLY ITS MESSAGE. `same-directory-p' truenames both sides, so
;;; the refusal always fired on the right condition. But this text exists to tell a reader
;;; which two trees disagreed, and two spellings of one directory assert a disagreement that
;;; is not there -- pointing whoever reads it at a difference they cannot find. That is worse
;;; than saying nothing, and it is why a defect in a diagnostic earned a ticket.
;;;
;;; THIS TEST BUILDS ITS OWN ALIAS RATHER THAN WAITING FOR A HOST THAT HAS ONE. The four
;;; assertions above would also catch this, but only on a machine whose TEMP happens to be
;;; aliased, which is a property of GitHub's image rather than of this tree. When that image
;;; changes they go vacuous and nothing says so. Forcing the condition is the same rule the
;;; #482 tests follow by moving their own working directory.

(defun %another-name-for (dir)
  "A second, textually different name that resolves to DIR, or NIL if this platform has none.

Copied from `klio/tests/klio-tests.lisp', where it was written for #446. Copied rather than
depended on: `checkers' has no business loading klio, and a test helper is not a dependency
worth taking across the DAG for.

NIL RATHER THAN THE NAME WE WERE GIVEN. 8.3 generation is switched off on many volumes, and
there the short name comes back identical to the long one. Returning it would make the test
below pass while exercising nothing, which is the shape this file has a rule about. The
caller skips on NIL and says so."
  (let ((native (string-right-trim "\\/" (uiop:native-namestring dir))))
    (declare (ignorable native))
    #+win32
    (let ((short (ignore-errors
                  (uiop:run-program
                   (list "powershell" "-NoProfile" "-Command"
                         (format nil "(New-Object -ComObject Scripting.FileSystemObject).GetFolder('~A').ShortPath"
                                 native))
                   :output '(:string :stripped t) :error-output nil
                   :ignore-error-status t))))
      (when (and short (plusp (length short)) (string/= short native))
        (uiop:ensure-directory-pathname short)))
    #-win32
    (let ((link (concatenate 'string native "-by-another-name")))
      (when (zerop (nth-value 2 (uiop:run-program (list "ln" "-s" native link)
                                                  :output nil :error-output nil
                                                  :ignore-error-status t)))
        (uiop:ensure-directory-pathname link)))))

(defun %cwd-as-the-child-sees-it (dir)
  "What `uiop:getcwd' reports in a CHILD process started in DIR, or NIL if that could not be
determined.

A CHILD, NOT `uiop:with-current-directory', WHICH MEASURES SOMETHING ELSE. I assumed the two
were equivalent because `run-program :directory' performs the same chdir. They are not.
Measured at one commit against one alias, on Windows:

  in-process probe                C:\Users\bcalc\AppData\Local\Temp\ouranos-checkers-2R6UUSAB9I-NRN1TPSMS\
  child started in the same dir   C:\Users\bcalc\AppData\Local\Temp\OUC8DF~1\

The child is handed the spelling it was given; this image reports the canonical one. The
test runs the script under test in a child, through %RUN-IN, so the child is the thing to
ask -- an in-process probe reports a collapse that does not happen and skips a test that
could have run.

NIL ON ANY DOUBT, because the caller skips on NIL. `require :asdf' first, since UIOP is not
present in a bare image; a non-zero exit or empty output yields NIL rather than a string that
cannot match. An earlier version of this returned the empty string in those cases, which
never equals the canonical path, so the caller's guard could never fire and the test would
run and pass while exercising nothing. That is the defect this whole ticket is about,
rebuilt in the guard meant to prevent it."
  (multiple-value-bind (out err code)
      (uiop:run-program (list (namestring sb-ext:*runtime-pathname*)
                              "--noinform" "--non-interactive" "--eval"
                              "(progn (require :asdf) (write-string (uiop:native-namestring (uiop:getcwd))) (uiop:quit 0))")
                        :directory (namestring dir)
                        :output '(:string :stripped t)
                        :error-output nil
                        :ignore-error-status t)
    (declare (ignore err))
    (when (and (integerp code) (zerop code) (plusp (length out)))
      out)))

(test the-refusal-names-one-directory-one-way-whatever-spelling-the-caller-used
  "#510. The caller stands in an ALIAS of its own tree, so `uiop:getcwd' reports a spelling
that `*load-truename*' does not use. Before the fix the refusal printed the caller's tree in
the caller's spelling and the script's tree truenamed, and a reader comparing them saw two
directories where there was one.

Both paths in the message must be in the canonical spelling, so the assertion is against the
TRUENAME of each fixture -- built here rather than by calling tree-root's `shown', because a
test that used the producer's own function to compute what it expects could never disagree
with the producer."
  (multiple-value-bind (theirs ours)
      (%two-tree-fixture "mbedtls-sources.lisp" "mbedtls.sources")
    (let* ((alias (%another-name-for ours))
           (seen (and alias (%cwd-as-the-child-sees-it alias))))
      (cond
        ((null alias)
         (skip "this platform gave the directory no second name: 8.3 aliases may be off on this volume, or `ln -s' is unavailable"))
        ((null seen)
         (skip "could not determine what spelling a process standing in the second name reports, so whether this host creates the condition at all is unknown -- skipping rather than asserting against a precondition that was never confirmed"))
        ((string= seen (uiop:native-namestring (truename ours)))
         (skip "a child started in the second name reports the canonical one, so the two spellings collapse before the script sees them -- this is the Windows 8.3 case (#510) and only a host that hands the alias through exercises it"))
        (t
          (multiple-value-bind (code out)
              (%run-in alias (merge-pathnames "scripts/mbedtls-sources.lisp" theirs))
            (is (= 2 code) "it must still refuse when the caller used another spelling; exit was ~D~%~A" code out)
            (is (search (uiop:native-namestring (truename ours)) out)
                "the caller's tree must be named in its canonical spelling, not the alias the caller used:~%~A" out)
            (is (search (uiop:native-namestring (truename theirs)) out)
                "and the script's tree alongside it, in the same spelling:~%~A" out)))))))

;;; --- the private-name hooks (.githooks/private-names.sh) ------------------------
;;;
;;; What they exist to detect: a client or product name entering this repository through a
;;; commit message, an added line, a new file path, a branch name, or a commit that skipped
;;; the commit hooks on its way out.
;;;
;;; Each test builds a real git repository, installs THIS tree's hooks, and drives them
;;; through git rather than running the scripts directly. A hook then runs the way it runs for
;;; a lane: through the same git, with the same environment, and on Windows through the sh
;;; that git supplies.
;;;
;;; The names are invented and cannot occur in real text. Every fixture names its own list in
;;; its own repository config, or clears the setting with `-c ouranos.privateNames=', so no
;;; test depends on what the machine running it has configured globally.

(defparameter +invented-names+
  (format nil "# names invented for the hook tests~%~%zorbocorp~%quux-feathers~%")
  "A list in the real format: a comment, a blank line, and two entries.")

(defun %git (dir &rest args)
  "Run git in DIR. Returns (values exit-code output), with stdout and stderr together."
  (let ((out (make-string-output-stream)))
    (let ((code (nth-value 2 (uiop:run-program
                              (list* "git" "-C" (uiop:native-namestring dir) args)
                              :output out :error-output out :ignore-error-status t))))
      (values code (get-output-stream-string out)))))

(defun %git! (dir &rest args)
  "Run git in DIR for fixture setup, and signal if it fails.

Setup that fails quietly produces a fixture that is not what the test thinks it is."
  (multiple-value-bind (code out) (apply #'%git dir args)
    (unless (zerop code)
      (error "fixture setup failed: git ~{~a~^ ~} exited ~a~%~a" args code out))
    out))

(defun %hooked-repo (&key (names +invented-names+) (configure t))
  "A fresh repository on branch main with this tree's hooks installed and armed.

NAMES, when non-nil, becomes the repository's gitignored .private-names. CONFIGURE also points
ouranos.privateNames at that file in the repository's own config, which takes precedence over
the machine's global setting."
  (let ((dir (%fresh-tree)))
    (%git! dir "init" "-q" "-b" "main")
    (%git! dir "config" "user.name" "Hook Test")
    (%git! dir "config" "user.email" "hook-test@example.invalid")
    (%git! dir "config" "commit.gpgsign" "false")
    (%git! dir "config" "core.hooksPath" ".githooks")
    (dolist (name '("commit-msg" "pre-commit" "pre-push" "private-names.sh"))
      (let ((target (merge-pathnames (concatenate 'string ".githooks/" name) dir)))
        (ensure-directories-exist target)
        (uiop:copy-file (merge-pathnames (concatenate 'string ".githooks/" name) td-root) target)
        ;; A copied file loses its mode, and git skips a hook that is not executable.
        (unless (uiop:os-windows-p)
          (uiop:run-program (list "chmod" "755" (uiop:native-namestring target))))))
    (%write (merge-pathnames ".gitignore" dir) (format nil ".private-names~%"))
    (when names
      (let ((list-file (merge-pathnames ".private-names" dir)))
        (%write list-file names)
        (when configure
          (%git! dir "config" "ouranos.privateNames" (uiop:native-namestring list-file)))))
    dir))

(defun %stage (repo path contents)
  "Write CONTENTS to PATH under REPO, then stage everything."
  (%write (merge-pathnames path repo) contents)
  (%git! repo "add" "-A"))

(defun %commit-count (repo)
  "How many commits REPO's current branch has; 0 before the first."
  (multiple-value-bind (code out) (%git repo "rev-list" "--count" "HEAD")
    (if (zerop code) (or (parse-integer out :junk-allowed t) 0) 0)))

(defun %repeats-a-name-p (output)
  "Whether OUTPUT contains either invented name, in any case."
  (or (search "zorbocorp" output :test #'char-equal)
      (search "quux-feathers" output :test #'char-equal)))

(test name-check-passes-a-clean-commit
  ;; The control for every refusal below: a hook that refused everything would pass all of
  ;; them. It is also the first commit of a new repository, which the hub guard in pre-commit
  ;; used to refuse (it read the branch of a repository with no commits as two lines).
  (let ((repo (%hooked-repo)))
    (%stage repo "notes.md" (format nil "# Notes~%A consuming app asked for this.~%"))
    (multiple-value-bind (code out) (%git repo "commit" "-q" "-m" "Add notes")
      (is (zerop code) "a commit with no name in it was refused:~%~a" out)
      (is (= 1 (%commit-count repo))))))

(test name-check-refuses-a-name-in-the-commit-message
  (let ((repo (%hooked-repo)))
    (%stage repo "notes.md" (format nil "Notes~%"))
    (multiple-value-bind (code out) (%git repo "commit" "-q" "-m" "Notes for ZorboCorp")
      (is (not (zerop code)) "a name in the message was committed")
      (is (= 0 (%commit-count repo)))
      (is (search "Line 1 of the message" out) "the refusal does not say where:~%~a" out)
      (is (not (%repeats-a-name-p out)) "the refusal repeats the name"))))

(test name-check-refuses-a-name-on-an-added-line
  (let ((repo (%hooked-repo)))
    (%stage repo "docs/notes.md" (format nil "# Notes~%Built for Quux-Feathers.~%"))
    (multiple-value-bind (code out) (%git repo "commit" "-q" "-m" "Add notes")
      (is (not (zerop code)) "a name on an added line was committed")
      (is (= 0 (%commit-count repo)))
      (is (search "docs/notes.md:2" out) "the refusal does not give the path and line:~%~a" out)
      (is (not (%repeats-a-name-p out)) "the refusal repeats the name"))))

(test name-check-refuses-a-name-in-a-new-file-path
  ;; The path is counted, not printed, because printing it would print the name.
  (let ((repo (%hooked-repo)))
    (%stage repo "docs/zorbocorp-plan.md" (format nil "A plan.~%"))
    (multiple-value-bind (code out) (%git repo "commit" "-q" "-m" "Add a plan")
      (is (not (zerop code)) "a name in a file path was committed")
      (is (= 0 (%commit-count repo)))
      (is (not (%repeats-a-name-p out)) "the refusal printed the path, and the path is the name"))))

(test name-check-lets-a-commit-remove-a-name
  ;; Only ADDED lines are checked. The commit that removes a name is the fix, and a check that
  ;; refused it would make the fix impossible to commit.
  (let ((repo (%hooked-repo)))
    (%stage repo "notes.md" (format nil "one~%for ZORBOCORP~%three~%"))
    (%git! repo "commit" "-q" "--no-verify" "-m" "setup: a file that already has a name in it")
    (%stage repo "notes.md" (format nil "one~%three~%"))
    (multiple-value-bind (code out) (%git repo "commit" "-q" "-m" "Remove the name")
      (is (zerop code) "removing a name was refused:~%~a" out)
      (is (= 2 (%commit-count repo))))))

(test name-check-runs-in-a-linked-worktree
  ;; The case lanes are in. The list is untracked and sits in the MAIN checkout, so a linked
  ;; worktree does not have it, and the hooks have to find it through git's common directory.
  ;; `-c ouranos.privateNames=' clears the setting for these commands, which leaves that
  ;; lookup as the only way the list can be found.
  (let* ((repo (%hooked-repo :configure nil))
         (lane (merge-pathnames "lane/" (%fresh-tree))))
    (%stage repo "README.md" (format nil "x~%"))
    (%git! repo "-c" "ouranos.privateNames=" "commit" "-q" "-m" "first")
    (%git! repo "worktree" "add" "-q" "-b" "work/lane" (uiop:native-namestring lane))
    (is (not (probe-file (merge-pathnames ".private-names" lane)))
        "the fixture is wrong: the worktree has a list of its own")
    (%stage lane "lane.md" (format nil "for quux-feathers~%"))
    (multiple-value-bind (code out)
        (%git lane "-c" "ouranos.privateNames=" "commit" "-q" "-m" "lane work")
      (is (not (zerop code)) "a name was committed from a linked worktree:~%~a" out)
      (is (search "lane.md:1" out) "the refusal does not give the path and line:~%~a" out))))

(test name-check-refuses-everything-when-the-configured-list-is-missing
  ;; Configuring a list is how a machine says it needs the check. If the list has gone, a
  ;; commit must not look the same as one that was checked and found clean.
  (let ((repo (%hooked-repo :names nil)))
    (%git! repo "config" "ouranos.privateNames"
           (uiop:native-namestring (merge-pathnames "no-such-list" repo)))
    (%stage repo "notes.md" (format nil "nothing private here~%"))
    (multiple-value-bind (code out) (%git repo "commit" "-q" "-m" "Add notes")
      (is (not (zerop code)) "a machine configured for the check committed without it:~%~a" out)
      (is (= 0 (%commit-count repo)))
      (is (search "does not exist" out) "the refusal does not say the list is missing:~%~a" out))))

(test name-check-does-nothing-where-there-is-no-list
  ;; A contributor's clone: no list, and nothing configured. `-c ouranos.privateNames=' clears
  ;; any global setting on the machine running this test.
  (let ((repo (%hooked-repo :names nil)))
    (%stage repo "notes.md" (format nil "zorbocorp is not a private name to a contributor~%"))
    (multiple-value-bind (code out)
        (%git repo "-c" "ouranos.privateNames=" "commit" "-q" "-m" "Add notes")
      (is (zerop code) "a clone with no list refused a commit:~%~a" out)
      (is (= 1 (%commit-count repo))))))

(defun %bare-remote (repo)
  "A bare repository in its own fresh directory, added to REPO as `origin'."
  (let ((remote (merge-pathnames "remote.git/" (%fresh-tree))))
    (%git! repo "init" "-q" "--bare" (uiop:native-namestring remote))
    (%git! repo "remote" "add" "origin" (uiop:native-namestring remote))
    remote))

(defun %ref (repo ref)
  "The object REF names in REPO, or NIL if REF does not exist there."
  (multiple-value-bind (code out) (%git repo "rev-parse" "-q" "--verify" ref)
    (and (zerop code) (string-trim '(#\Newline #\Return #\Space) out))))

(test pre-push-refuses-a-commit-that-skipped-the-commit-hooks
  ;; `git am', cherry-pick, rebase and --no-verify all make commits without running pre-commit
  ;; or commit-msg. pre-push is the check such a commit cannot avoid on its way out, so this
  ;; makes one with --no-verify and tries to push it, after a clean push as the control.
  (let* ((repo (%hooked-repo))
         (remote (%bare-remote repo)))
    (%stage repo "a.md" (format nil "clean~%"))
    (%git! repo "commit" "-q" "-m" "clean")
    (multiple-value-bind (code out) (%git repo "push" "-q" "origin" "main")
      (is (zerop code) "a clean push was refused:~%~a" out))
    (let ((pushed (%ref remote "refs/heads/main")))
      (%stage repo "b.md" (format nil "for Quux-Feathers~%"))
      (%git! repo "commit" "-q" "--no-verify" "-m" "skipped the commit hooks")
      (multiple-value-bind (code out) (%git repo "push" "-q" "origin" "main")
        (is (not (zerop code)) "a commit carrying a name was pushed:~%~a" out)
        (is (search "b.md:1" out) "the refusal does not give the path and line:~%~a" out)
        (is (not (%repeats-a-name-p out)) "the refusal repeats the name")
        (is (equal pushed (%ref remote "refs/heads/main")) "the remote's main moved")))))

(test pre-push-refuses-a-branch-name-that-contains-a-name
  (let* ((repo (%hooked-repo))
         (remote (%bare-remote repo)))
    (%stage repo "a.md" (format nil "clean~%"))
    (%git! repo "commit" "-q" "-m" "clean")
    (multiple-value-bind (code out)
        (%git repo "push" "-q" "origin" "main:refs/heads/work/zorbocorp")
      (is (not (zerop code)) "a branch named after a client was pushed:~%~a" out)
      (is (null (%ref remote "refs/heads/work/zorbocorp")) "the branch exists on the remote"))))
