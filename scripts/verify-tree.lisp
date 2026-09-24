;;;; verify-tree.lisp --- load every Ouranos system, run every suite, and PROVE it ran.
;;;;
;;;;   sbcl --dynamic-space-size 4096 --script scripts/verify-tree.lisp
;;;;
;;;; Exit 0 only if every system loads, every suite passes, AND every suite actually
;;;; executed at least one check.
;;;;
;;;; That last clause is one of two things this script exists for. `asdf:test-system` on a
;;;; system with no `:perform (test-op ...)` loads the files, runs nothing, and returns
;;;; SUCCESSFULLY -- so a verifier that trusts the exit status reports green for a suite
;;;; that never ran. Not hypothetical: aion was reported green through the entire Coalton
;;;; 7915fad0 adoption while executing zero checks (pre-publication issue 116). **"Exited 0" is not "the tests
;;;; passed."** The check count is the evidence, so we parse it and demand it.
;;;;
;;;; EVERY SYSTEM AND EVERY SUITE RUNS IN ITS OWN FRESH SBCL. That is the second thing, and
;;;; it was added after this script produced a false green of exactly the kind it exists to
;;;; prevent.
;;;;
;;;; The earlier version loaded everything into ONE image: `+systems+` first, then
;;;; `+test-systems+`. `+systems+` contains `praxeon/web`, which declares
;;;; `clack-handler-woo` on non-Windows. `hyperion/tests` declared no HTTP backend at all
;;;; after pre-publication issue 139 -- but by the time it ran, praxeon/web had already pulled one into the same
;;;; image, so `available-servers` found one and the suite passed. `asdf:test-system
;;;; :hyperion` on its own failed outright with NO-SERVER-BACKEND, and this script reported
;;;; PASS for weeks. One image lets any system silently satisfy another's UNDECLARED
;;;; dependency, and the resulting green says nothing about whether the tree is actually
;;;; composed correctly.
;;;;
;;;; A child cannot borrow what a sibling loaded, so a missing `:depends-on` fails here
;;;; instead of on someone else's machine. Children also run `--no-userinit --no-sysinit`:
;;;; a personal `~/.sbclrc` is part of the developer's machine, not of the tree, and one
;;;; that loads Quicklisp or a pet library is another way for a dependency to appear that
;;;; was never declared.
;;;;
;;;; The cost is wall-clock -- one SBCL launch per system instead of one for all of them.
;;;; It is paid deliberately: this is the gate before committing, and a fast answer that
;;;; can be wrong is worth less than a slow one that cannot. Sequential and obvious beats
;;;; parallel and clever here; the thing that checks everything else is the last place to
;;;; put concurrency bugs.
;;;;
;;;; Suites that are legitimately empty must be listed in +KNOWN-EMPTY+ with a reason, so
;;;; that emptiness is a recorded decision rather than a silent gap.
;;;;
;;;; BACKEND COVERAGE is the third thing, and the same idea one level down (pre-publication issue 176). A suite
;;;; can execute thousands of checks and still say nothing about the storage engine the docs
;;;; tell you to deploy on: mnemosyne reported 2645 green checks on SQLite at the same commit
;;;; that silently corrupted a text column on Postgres. A total check count cannot see that,
;;;; because 40+40 and 80+0 sum identically.
;;;;
;;;; So a suite may report PER-BACKEND counts, as lines this script parses:
;;;;
;;;;   BACKEND-CHECKS sqlite 23
;;;;   BACKEND-CHECKS postgres 23
;;;;   BACKEND-CHECKS postgres SKIPPED (MNEMOSYNE_TEST_PG_URL is not set)
;;;;   BACKEND-CHECKS postgres UNREACHABLE (...)
;;;;
;;;; A SKIPPED or zero-count backend FAILS this gate. Set MNEMOSYNE_TEST_PG_URL (see
;;;; scripts/test-postgres.sh) so the backend actually runs -- or set OURANOS_ALLOW_NO_PG=1
;;;; to excuse it deliberately, which is the +KNOWN-EMPTY+ doctrine again: an exception
;;;; someone MADE and can be asked about, not one that accumulated. UNREACHABLE is never
;;;; excusable: it means a server was named and did not answer, which is a broken
;;;; environment rather than a choice.
;;;;
;;;; THE PLATFORM AXIS is the fourth thing, and the same idea one level further out (pre-publication issue 182).
;;;; A package that can only be compiled on ONE host is invisible to a total check count and
;;;; to per-backend coverage alike. Without an axis, a WINDOWS run that never loads
;;;; aion/windows reports PASS and says nothing whatever about the binding -- while a macOS
;;;; run reporting PASS is CORRECT to have skipped it. Same output, two meanings, and here
;;;; the blind spot is an entire platform.
;;;;
;;;; scripts/platform-packages.lisp holds the one answer to "which platform packages does
;;;; this host own", shared with bootstrap.lisp so the two cannot drift. Packages this host
;;;; owns and that are declared :required go through the same one-image-each machinery as
;;;; everything else; the PLATFORM block then reports the axis in five distinguishable
;;;; states, because "did not check" and "does not apply" must never print the same way:
;;;;
;;;;   covered   built and tested above
;;;;   planned   decided, not written yet -- named every run, deliberately not a failure
;;;;   STALE     present but the registry still says :planned -- FAILS, because the package
;;;;             is being carried with no gate over it
;;;;   MISSING   required on this host and not in the tree -- FAILS
;;;;   n/a       owned by another OS; printed so a PASS says what it does NOT cover
;;;;
;;;; THE OPTIONAL-COVERAGE AXIS is the fifth (pre-publication issue 385), and it is the platform axis's mirror.
;;;; PLATFORM reports what this host CANNOT answer; NOT COVERED reports what it CAN answer
;;;; and the caller declined -- `OURANOS_WITH_UV' unset, today. Both had been silences, and
;;;; the second is the worse one: a platform is a fact that stays true, a flag is a choice
;;;; the next reader of the number never sees. It cost 4065 and 4400 printed identically as
;;;; `total checks executed' on ONE commit, both PASS. So the total now carries the axes it
;;;; ran, the way it already carries its commit, and for the same reason.

(require :asdf)
(require :uiop)

;;; The platform registry (pre-publication issue 182) -- the SAME file bootstrap.lisp loads, so the two cannot
;;; drift about which packages this host owns. Loaded by path because it is deliberately not
;;; a member of any ASDF system: bootstrap consumes it before `cons' exists.
(load (merge-pathnames "platform-packages.lisp"
                       (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

;;; Where a failure CAME FROM (pre-publication issue 192) -- tree code, or a dependency outside this checkout.
;;; Split out of this script for the same reason as the registry above: everything here runs
;;; at toplevel, so a helper defined inline can only be exercised by running the whole gate.
;;; See cons/tests/failure-origin-tests.lisp.
(load (merge-pathnames "failure-origin.lisp"
                       (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

;;; Reading FiveAM's own report (pre-publication issue 448). Split out for the same reason, and because the defect
;;; it fixes was one the gate could not see about itself: it reported a prefix of each
;;; suite's failures and nothing about the output said so.
(load (merge-pathnames "fiveam-report.lisp"
                       (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

;;; The NOT COVERED section (#182). Split out for the same reason as the two above, so a test
;;; can hand the printer known inputs; REPORT-NOT-COVERED below passes it this run's state.
(load (merge-pathnames "not-covered.lisp"
                       (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

;;; Building the native webview launcher (pre-publication issue 410, #13). Shared with bootstrap.lisp, which builds
;;; the launcher too, so there is one copy of how it is built and where the binary goes.
(load (merge-pathnames "view-launcher.lisp"
                       (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(defparameter +systems+
  '(;; core
    :aion :aion/csv :aion/platform :aion/clock :aion/log :aion/boundary :aion/dynamic :aion/pool :aion/interceptor :aion/signature :aion/http-client :cons :mnemosyne :elenchon :hyperion :praxeon
    :hermes
    :klio
    ;; aux systems -- these hold real code and were previously never compiled here,
    ;; so a change to any of them could break unnoticed. praxeon/web is the case that
    ;; exposed it: a refactor landed in praxeon/src/web.lisp and a green run of this
    ;; script did not touch the file.
    :cons/env :cons/cli :cons/coalton-repl
    :hermes/blob
    :hermes/payments
    :hyperion/import :hyperion/desktop :hyperion/update :hyperion/update-ui :hyperion/assets :hyperion/session-db
    :hyperion/auth-db :hyperion/cli
    :aion/random
    ;; The credential wrapper (pre-publication issue 209) and its Coalton view. Two systems because
    ;; aion/secret must stay Coalton-free for cons; both belong in the gate, since a
    ;; break here silently un-redacts a password in three frameworks at once.
    :aion/secret :aion/secret/types
    :hyperion/http1
    :praxeon/translate :praxeon/web :praxeon/web-search :praxeon/memory-db
    ;; example apps -- they are the launch artifacts and the first thing a reader runs
    :praxeon/elise :praxeon/chat-rbt
    :hyperion/examples/active-search :hyperion/examples/active-search-db
    :hyperion/examples/coalton-repl
    ;; The mnemosyne example was absent from this list while three hyperion examples were
    ;; in it, so nothing here ever compiled it (#94). It is the example the conformance
    ;; pack ships beside, which makes it the one a reader is most likely to copy.
    :contacts)
  "Every system that must LOAD, each in its own image. Opt-in aux systems with native
dependencies (aion/uv, aion/uv/net, aion/uv/process) are deliberately absent: they need
scripts/build-libuv.lisp first, so their absence here is not evidence of anything.
Build libuv, then set OURANOS_WITH_UV=1 to fold them in -- see +UV-SYSTEMS+ below.")

(defparameter +test-systems+
  '(:aion/tests :aion/boundary/tests :aion/dynamic/tests :aion/test-threads/tests :aion/platform/tests :aion/pool/tests :aion/interceptor/tests :aion/signature/tests :aion/http-client/tests :cons/tests :mnemosyne/tests :hyperion/tests :praxeon/tests :hermes/tests :hermes/payments/tests
    :elenchon/tests :klio/tests
    ;; aux suites that existed but were never run from here
    :cons/coalton-repl/tests :hyperion/session-db/tests :hyperion/auth-db/tests
    :hyperion/assets/tests :hermes/blob/tests
    ;; praxeon/web's own suite (pre-publication issue 151) -- THE GAP THIS FILE ALREADY NAMES. Two entries below,
    ;; `hyperion/update/tests' is justified as "invisible to this checker until someone
    ;; looked, which is the praxeon/web gap exactly", and the praxeon/web gap was still open
    ;; when that was written. `+systems+' LOADED praxeon/web, so a refactor there compiled;
    ;; nothing EXERCISED it, so elise hand-rolled a sleep loop around a blocking entry that
    ;; did not exist and no check count ever moved. The suite declares a Clack handler, which
    ;; is safe here only because every suite now gets its own fresh SBCL (see the header).
    :praxeon/web/tests
    ;; Observational memory in a real database (#138). Registered in the same commit that
    ;; adds it: an unregistered suite, an unrun suite and a passing suite are identical at
    ;; the exit code, and this one would be the easiest of the three to leave that way --
    ;; it needs Postgres, so it is also the easiest to believe is "just skipping".
    :praxeon/memory-db/tests
    ;; The gate's own checkers, tested against trees built to break them (#163). Here
    ;; rather than in the +CHECKERS+ block because that block must not move the check
    ;; count, and a fix for "nothing attests these work" that produces no number would be
    ;; attested only by its presence.
    :checkers/tests
    ;; hyperion-view's ARGUMENT CONTRACT (pre-publication issue 276). The launcher is C++, and before this entry a
    ;; change to hyperion-view.cc moved no check count in either direction. The suite tests
    ;; the CLI, not the window -- and it carries one UNCONDITIONAL check so that a checkout
    ;; which has never built the launcher skips loudly here rather than reporting zero and
    ;; failing the gate.
    ;;
    ;; THIS GATE NOW COMPILES IT (pre-publication issue 410) -- `build-view-launcher', before LOADING. It did not
    ;; when this entry was written, and the five assertions that need the binary therefore
    ;; skipped on every local run while CI built it and ran them: ten checks, two honest
    ;; totals, one PASS each. When the build is not possible the `view' axis is DECLINED and
    ;; said so, rather than skipping in silence.
    :hyperion/view/tests
    ;; The desktop self-updater (pre-publication issue 76). It verifies a signature and then decides whether to
    ;; replace a binary on a user's machine, so it belongs inside the gate for the same
    ;; reason aion/random and hyperion/http1 do -- and it was invisible to this checker
    ;; until someone looked, which is the praxeon/web gap exactly.
    :hyperion/update/tests
    ;; The updater's VISIBLE half (pre-publication issue 333). Its own entry because its own system: the typed
    ;; core being green said nothing about whether a route existed, which is how a P0 sat
    ;; In Review for weeks with no UI at all. Review cannot see an absence; a suite can.
    :hyperion/update-ui/tests
    ;; The CSPRNG behind session ids (pre-publication issue 95). A security primitive belongs inside the gate.
    :aion/random/tests
    ;; Credential redaction (pre-publication issue 209) -- same argument as the CSPRNG above.
    :aion/secret/tests :aion/secret/types/tests
    ;; The HTTP parser (pre-publication issue 117). PURE and dependency-free precisely so it can live here --
    ;; aion/uv* is excluded from this checker for needing a C toolchain, and the most
    ;; security-critical code in the tree must not sit outside it. See ADR-0015.
    :hyperion/http1/tests
    ;; The contacts example's changeset path (#94). Its test system existed with an empty
    ;; component list and no :perform -- declared, loadable, and asserting nothing. Named
    ;; under its parent so its checks land in mnemosyne's README row (pre-publication issue 357).
    :mnemosyne/examples/contacts/tests)
  "Every suite that must RUN, and run at least one check -- each in its own image.

`mnemosyne/examples/contacts/tests' is the FIRST EXAMPLE SUITE here, and it is here on
purpose (#94). Tests the gate never ran would be an unregistered suite, and this file's own
rule is that an unregistered suite, an unrun suite and a passing suite are identical at the
exit code. It matters more for an example than for a framework: when a framework rots, code
breaks; when the example that teaches the mandated doctrine rots, it teaches the wrong
thing, which is what pre-publication issue 353 is about.

ITS NAME IS LOAD-BEARING, not cosmetic (pre-publication issue 357). `check-readme-counts.lisp' attributes a suite
to a framework by the segment before the first slash. Named `contacts/tests' -- which is
what it was -- it answered `contacts', a framework with no README row, so its checks reached
the headline total without reaching any row and the table stopped summing to itself. Under
this name it answers `mnemosyne'. The APP system is still plain `contacts' in its own
contacts.asd, deliberately, because standalone-with-its-own-asd is what that example
demonstrates.")

(defparameter +known-warnings+
  '(("undefined variable: PARENSCRIPT:*JS-TARGET-VERSION*"
     . "Parenscript's own symbol, reached through a MACROEXPANSION -- it appears in no
source file of ours. Deferred to the end of the compilation unit, so SBCL attributes it to
whichever file finished last rather than to the form that caused it, and it surfaces only
on a FULLY cold build. Harmless at run time: the symbol is external and bound once
Parenscript is loaded. Listed rather than tolerated silently, because a gate that ignores
warnings by category would have hidden the docstring bug this one exists to catch.")
    ("undefined variable: CL-POSTGRES::*UNIX-SOCKET-DIR*"
     . "An upstream cl-postgres read-conditional asymmetry, and WINDOWS-ONLY. In
cl-postgres/public.lisp the DEFPARAMETER is guarded `#+(and (or ...sbcl-available ccl
allegro) unix)`, so on Windows the variable is never defined -- but the reference to it
(the `:unix` branch of INITIATE-CONNECTION) is guarded only by the implementation half,
`#+(or allegro ...sbcl-available ccl)`, with no `unix`. So the reference compiles on
Windows SBCL while the definition does not exist. Unreachable at run time: that branch
calls `(assert-unix)` FIRST, which is `#-unix (error \"Unix sockets only available on Unix
(really)\")`, so the unbound variable is never evaluated -- and Windows has no Unix domain
sockets to connect to in the first place. Not fixable from here; it is in the dependency's
own source. Surfaced by the COLD build, not by the SBCL roll that found it -- the warm fasl
had hidden it on this platform indefinitely."))
  "Warnings the gate accepts, each with the reason it is not ours to fix.

The same doctrine as +KNOWN-EMPTY+: an exception someone MADE, not one that accumulated.
A third-party library's cold-compile warning must not red the whole tree -- but the
allowance is a recorded line with a justification, so it can be re-examined when the
dependency moves, rather than a blanket `ignore warnings from dependencies` that would
also swallow ours.")

(defparameter +known-empty+
  '()
  "Suites allowed to execute zero checks, each with the reason. Being on this list is a
decision someone made, not an accident -- which is the difference that matters.")

;;; --- the libuv systems, opt-in (pre-publication issue 87) ---------------------------------------

(defparameter +uv-systems+
  '(:aion/uv :aion/uv/net :aion/uv/process
    ;; The native HTTP server (pre-publication issue 117). It is a hyperion system, but it is HERE and not in
    ;; +SYSTEMS+ for the same reason as the three above: it opens sockets through libuv and
    ;; cannot load without a built vendor/libuv. Its PARSER is separate and pure precisely
    ;; so the security-critical half stays in +TEST-SYSTEMS+ where every run reaches it --
    ;; see ADR-0015 and the commentary in hyperion/src/http1/packages.lisp.
    :hyperion/server-uv)
  "The libuv-backed systems. Absent from +SYSTEMS+ because they need
scripts/build-libuv.lisp to have run first, so on a machine without it their absence is
not evidence of anything.")

(defparameter +uv-test-systems+
  '(:aion/uv/tests :aion/uv/net/tests :aion/uv/process/tests
    :hyperion/server-uv/tests)
  "Their suites -- real checks over a real libuv, verified by nothing automatic until CI.")

(defun with-uv-p ()
  "Should this run include the libuv systems? OURANOS_WITH_UV=1 says yes.

An OPT-IN rather than a probe for vendor/libuv/, because those two say different things.
A probe would make the gate quietly cover less on a machine that never built libuv, which
is the shape of every false green in this file's history: coverage that changes with the
environment and reports the same PASS either way. The flag makes the caller state the
claim, and CI states it on every platform -- which is also the only cross-platform proof
that the pinned libuv builds at all."
  (let ((v (uiop:getenv "OURANOS_WITH_UV")))
    (and v (member (string-trim " " v) '("1" "true" "yes") :test #'string-equal) t)))

;;; --- the optional-coverage axis (pre-publication issue 385) --------------------------------------
;;;
;;; `with-uv-p' above lets a caller run a smaller tree. That is legitimate and the file's
;;; own guidance recommends it between edits. What was NOT legitimate is that the smaller
;;; run printed its total under the same label as a full one, so the two could be compared:
;;; the Linux lane measured 4065 and 4400 on ONE commit, one host, libuv present in the
;;; tree both times, and both said `VERDICT: PASS'. Grepping the 4065 run's entire output
;;; for `uv' returned nothing -- not in LOADING, not in SUITES, not in SUMMARY.
;;;
;;; The PLATFORM block had solved this already, one axis over, and said so at line 82: n/a
;;; is "printed so a PASS says what it does NOT cover". This is that, for the axis the
;;; caller chooses rather than the one the OS chooses -- and the distinction matters:
;;;
;;;   aion/windows on Linux   the host CANNOT answer         a fact about the machine
;;;   aion/uv, flag unset     the host CAN answer, caller declined   a choice
;;;
;;; The second is the more dangerous of the two, because a fact stays true and a choice is
;;; forgotten by the next reader of the number. So it is named every run.
;;;
;;; NOT A FAIL when vendor/libuv/lib is populated and the flag is unset, though that would
;;; have caught the incident immediately. Ruled out deliberately: it is a probe wearing a
;;; different hat. It would make the gate's VERDICT depend on whether someone happened to
;;; run build-libuv.lisp, so two checkouts of one commit would gate differently -- the same
;;; defect the opt-in exists to prevent, sign flipped. Hub ruling on pre-publication issue 385.
;;;
;;; NO CHECK COUNT on these lines, also deliberately. The run does not know what it did not
;;; run, and a remembered figure would be a claim it cannot support -- worse than silence,
;;; because it would look measured.

(defparameter +optional-axes+
  '(("uv" with-uv-p report-uv-declined)
    ("view" view-covered-p report-view-uncovered))
  "(name predicate-symbol disclosure-symbol) for each axis this run may not cover.

A registry rather than an `if' at each site, so adding an axis cannot add one that the
summary forgets to disclose -- which is the defect this exists to close, and it would be
a poor joke to reintroduce it one axis later.

EACH AXIS OWNS ITS DISCLOSURE TEXT, and that is pre-publication issue 410's correction rather than tidying. The
first version held (name predicate env-var systems build-hint) and ONE printer rendered
every entry as \"the caller declined -- set <env> to 1 to include them\". That shape encodes
two assumptions the `view' axis breaks:

  OFF MEANS BY CHOICE     -- view can be off because this host has no C++ toolchain, and
                             telling that reader to set an environment variable points them
                             away from the actual cause.
  MISSING MEANS SYSTEMS   -- uv's absence means four systems never loaded. view's means one
                             system loaded and five assertions INSIDE it skipped. Rendering
                             the second as the first would be a false claim in the block
                             whose entire job is to prevent false claims.

SYMBOLS rather than #', so an axis's functions may live anywhere in this file instead of
necessarily above this form. `funcall' resolves a symbol at call time and every call site
here runs long after load.")

(defun axes-included ()
  "Names of the optional axes this run DID include. `base' is always present."
  (cons "base" (loop for (name pred) in +optional-axes+
                     when (funcall pred) collect name)))

(defun axes-declined ()
  "The axis entries this run did NOT include."
  (loop for entry in +optional-axes+
        unless (funcall (second entry)) collect entry))

(defun axes-tag ()
  "The axis coordinate, for the SUMMARY. Quoted WITH the count, for the same reason the
commit is (AGENTS.md): a total whose coverage is unstated is a rumour that happens to have
a number attached. One function, so the human line and the machine line cannot drift."
  (format nil "~{~a~^+~}" (axes-included)))

(defun %git-line (&rest args)
  "The first line of `git ARGS', trimmed, or NIL. Never signals and never fails the gate:
this is context for a reader, and a checkout with no upstream configured is a legitimate
state rather than a defect."
  (let ((out (ignore-errors
               (uiop:run-program (cons "git" args) :output :string :ignore-error-status t))))
    (when out
      (let ((line (string-trim '(#\Newline #\Space #\Return)
                               (subseq out 0 (or (position #\Newline out) (length out))))))
        (when (plusp (length line)) line)))))

(defun report-checkout-freshness ()
  "How far behind its upstream this checkout is, and when the clone last fetched (pre-publication issue 391).

PRINTED EVERY RUN, INCLUDING WHEN CURRENT, for the same reason as the block above: a line
that appears only on bad news teaches readers that its absence means nothing happened, and
absence here cannot be told apart from the line never having been wired.

WHY THE GATE, of all places: it already prints `commit:' because a count without one is a
rumour, and this is the next question a reader asks when a figure surprises them -- is this
tree even current? It is also the call site that would have caught the hub running a
pre-publication check from a checkout sixteen commits behind, getting a FAIL naming a
scaffold that had already been deleted.

IT NEVER FETCHES. `origin/main' is a local ref and FETCH_HEAD is a local stat, so this
costs nothing and cannot hang; a stale ref reported honestly beside its age is nearly all
of the value. Deliberately duplicated from scripts/staleness.sh rather than shelling out to
it: the gate runs on Windows through `sbcl --script' with no shell assumed, and calling git
directly is what every other line of this file already does."
  (let* ((upstream (or (%git-line "rev-parse" "--abbrev-ref" "--symbolic-full-name" "@{upstream}")
                       "origin/main"))
         (known (%git-line "rev-parse" "--verify" "--quiet" upstream)))
    (cond
      ((null known)
       (format t "checkout: no upstream ref (~a) -- cannot say whether this tree is current~%" upstream))
      (t
       ;; AHEAD is reported too, and not folded into "current". A branch one commit ahead of
       ;; main is not missing anything from upstream, but printing that as `current with
       ;; origin/main' invites the reader to hear "identical to main" -- which is how a
       ;; figure measured on a feature branch gets quoted as main's. Two counts, two facts.
       (let ((behind (%git-line "rev-list" "--count" (format nil "HEAD..~a" upstream)))
             (ahead  (%git-line "rev-list" "--count" (format nil "~a..HEAD" upstream))))
         (cond
           ((and (equal behind "0") (equal ahead "0"))
            (format t "checkout: current with ~a~%" upstream))
           ((equal behind "0")
            (format t "checkout: nothing missing from ~a, and ~a commit(s) ahead of it~%"
                    upstream (or ahead "?")))
           (t
            (format t "checkout: ~a commit(s) BEHIND ~a -- this tree is not what ~a says now~%"
                    (or behind "?") upstream upstream))))))))

(defvar *postgres-excused* '()
  "(suite . reason) for each suite whose Postgres checks were skipped and excused by
OURANOS_ALLOW_NO_PG. Filled while the suites run; REPORT-NOT-COVERED lists them.")

(defun report-not-covered ()
  "What this run could have covered and did not: this run's state, printed by
OURANOS-NOT-COVERED:PRINT-NOT-COVERED (scripts/not-covered.lisp), whose docstring says what
the section reports and why."
  (ouranos-not-covered:print-not-covered (axes-declined) (reverse *postgres-excused*) (axes-tag)))

(defun report-uv-declined (name)
  "The uv axis is off. One cause only: the caller did not ask for it."
  (format t "  off     ~a axis~34tthis host CAN answer these; the caller declined~%" name)
  (dolist (s '(:aion/uv :aion/uv/net :aion/uv/process :hyperion/server-uv))
    (format t "          ~(~a~)~%" s))
  (format t "          OURANOS_WITH_UV is unset. Set it to 1 to include them (needs scripts/build-libuv.lisp to have run).~%")
  (format t "          Their checks are NOT in the total below, and no figure here says how many.~%"))

;;; --- the platform axis (pre-publication issue 182) ----------------------------------------------
;;;
;;; ADR-0003 predicted this gap: without a platform axis, a WINDOWS run that never loads
;;; aion/windows reports PASS and says nothing whatever about the binding -- while a macOS
;;; run reporting PASS is CORRECT to have skipped it. Same output, two meanings. That is
;;; pre-publication issue 116 and the praxeon/web coverage gap again, with the blind spot being an entire
;;; platform.
;;;
;;; So the packages this host OWNS go through the same one-image-each machinery as
;;; everything else (nothing special about how they are built), and the summary reports the
;;; axis explicitly -- including, on the machines that cannot answer, WHAT it did not cover.

(defun platform-required-systems ()
  "Platform systems this host owns that are declared :required -- these must load."
  (loop for entry in (ouranos-platform:entries-here)
        when (ouranos-platform:required-p entry)
          collect (intern (string-upcase (ouranos-platform:entry-system entry)) :keyword)))

(defun platform-required-test-systems ()
  "Their suites, where the tree actually declares one.

FIND-SYSTEM rather than a naming assumption: a platform package need not ship `/tests', and
inventing a suite name that does not exist would fail the gate for the wrong reason."
  (loop for entry in (ouranos-platform:entries-here)
        when (ouranos-platform:required-p entry)
          append (let ((name (concatenate 'string (ouranos-platform:entry-system entry) "/tests")))
                   (when (asdf:find-system name nil)
                     (list (intern (string-upcase name) :keyword))))))

(defun all-systems ()
  (append (if (with-uv-p) (append +systems+ +uv-systems+) +systems+)
          (platform-required-systems)))

(defun all-test-systems ()
  (append (if (with-uv-p) (append +test-systems+ +uv-test-systems+) +test-systems+)
          (platform-required-test-systems)))

;;; --- the child image --------------------------------------------------------

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*)))
  "The repo root -- the parent of scripts/.")

(defparameter *quicklisp*
  (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defun child-environment ()
  "The child's environment, with CL_SOURCE_REGISTRY pinned to THIS tree.

Passed explicitly rather than relying on the ASDF drop-in bootstrap.lisp writes: the
drop-in is global machine state that can point at a different checkout, and a verifier
that silently verifies the wrong tree is the failure this script is meant to make
impossible. (That exact mistake was made once by hand during a review -- the registry was
set before Quicklisp loaded and Quicklisp reinitialised it, so a branch was 'verified'
against main.) The trailing `//` means recurse; the empty entry inherits the defaults, so
Quicklisp's own systems still resolve.

The entry separator is `:` on Unix but `;` on Windows -- a colon there would be read as
part of the `d:` drive letter, which is why UIOP varies it. Hardcoding `:` made every one
of the 36 children fail to resolve ANY system on Windows, so the whole tree reported FAIL
with zero checks executed. Ask UIOP rather than assuming."
  (cons (format nil "CL_SOURCE_REGISTRY=~A//~A"
                (namestring *root*) (uiop:inter-directory-separator))
        (remove-if (lambda (e) (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e))
                   (sb-ext:posix-environ))))

(defun signal-death-p (code)
  "Was the child killed by a signal rather than exiting on its own?

A shell reports a signal death as 128+N, so 137 is SIGKILL. That is not a statement about
the code under test: on a loaded machine macOS will kill the largest process, and 36
sequential SBCL images each reserving a big heap is exactly the shape that attracts it.
Reporting it as a failing suite is the false RED that mirrors the false green this script
was rewritten to stop -- and an instrument that cries wolf gets ignored, which costs more
than the occasional wasted minute of a retry."
  (>= code 128))

(defun run-in-fresh-image (form-string)
  "Evaluate FORM-STRING in a NEW sbcl. Returns (values exit-code combined-output).

--no-userinit/--no-sysinit on purpose: a personal ~/.sbclrc belongs to the developer, not
to the tree, and one that loads Quicklisp or a pet library is one more way for an
undeclared dependency to look declared."
  (let ((out (make-string-output-stream)))
    (let ((code (nth-value
                 2 (uiop:run-program
                    (list (namestring sb-ext:*runtime-pathname*)
                          "--dynamic-space-size" "4096"
                          "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                          "--eval" "(require :asdf)"
                          "--eval" (format nil "(load ~S)" (namestring *quicklisp*))
                          "--eval" form-string)
                    :output out :error-output out
                    :environment (child-environment)
                    :ignore-error-status t))))
      (values code (get-output-stream-string out)))))

(defun run-checked (form-string label)
  "RUN-IN-FRESH-IMAGE, retried ONCE if the child was killed by a signal.

Retried rather than tolerated: if it dies twice it is reported, so a genuine runaway still
surfaces -- it just is not confused with a failing test."
  (multiple-value-bind (code out) (run-in-fresh-image form-string)
    (if (signal-death-p code)
        (progn
          (format t "  ~a was killed by a signal (~d) -- retrying once~%" label code)
          (finish-output)
          (multiple-value-bind (code2 out2) (run-in-fresh-image form-string)
            (if (signal-death-p code2)
                (values code2 out2 :killed-twice)
                (values code2 out2 :retried))))
        (values code out nil))))

;;; --- provenance checkers (pre-publication issue 346) --------------------------------------------
;;;
;;; FOUR CHECKS THAT EXISTED AND THIS GATE DID NOT RUN. Each answers a question about
;;; PROVENANCE -- are the bytes and versions we build from the ones we declared -- and each
;;; ran only in .github/workflows/verify.yml. Meanwhile AGENTS.md names THIS script as the
;;; thing to run cold before claiming anything works, and ends its pre-proposal checklist
;;; with it. Someone following the documented procedure exactly got no pin check at all.
;;;
;;; THE ASYMMETRY IS THE FINDING, not the coverage. check-coalton sits one step above
;;; check-pins in the same CI job and was equally absent -- but a wrong Coalton FAILS TO
;;; COMPILE THE TREE, which this gate does do, so it was caught by accident. A pin whose
;;; `advisories'/`reviewed' fields have gone missing compiles perfectly, and so does an
;;; asset whose bytes no longer match ASSETS.pin. The checks with a second line of defence
;;; were the ones that had one.
;;;
;;; THEY MUST NOT CONTRIBUTE TO THE CHECK COUNT, and that is deliberate rather than
;;; incidental. `total checks executed' means "assertions the suites ran"; it is the figure
;;; every issue in this repo quotes at every other, and a gate check silently inflating it
;;; would corrupt the one number the tree reasons with. So this block reports pass/fail in
;;; its own section and touches `grand' nowhere -- same shape as the PLATFORM block.
;;;
;;; WHY NOT check-readme-counts.lisp: it CONSUMES a gate log. Running it inside the gate
;;; that produces the log is circular, and it is host-specific besides. It runs after, on
;;; the canonical leg, which is where it already runs.
;;;
;;; Cost, measured on this tree rather than estimated: pins 0.03 s, deps 0.33 s, assets
;;; 0.42 s, coalton 0.92 s. Under two seconds against a gate that takes ninety.

(defparameter +checkers+
  '(("check-pins.lisp" ("--report") nil
     "every pin declares an advisory source and a review date")
    ("check-coalton.lisp" () t
     "the Coalton that LOADS is the pinned one")
    ("check-assets.lisp" () nil
     "vendored browser assets still hash to ASSETS.pin")
    ("check-deps.lisp" () t
     "docs/dependencies.md's rows and Headline counts match the .asd files (#118)")
    ("check-asd-collisions.lisp" () nil
     "no system name is defined by two .asd files")
    ("check-format-continuations.lisp" () nil
     "no string literal holds a FORMAT ~<newline> continuation (#146)")
    ("check-source-deps.lisp" () t
     "every system declares the packages its source names (#166)")
    ("check-source-deps.lisp" ("--self-test") t
     "check-source-deps' scanner still reads its known inputs correctly (#163)"))
  "(script args big-heap-p what-it-answers). BIG-HEAP-P is for the two that load systems;
the others read files and need no room to do it.

The description is what the checker ANSWERS, not what it is called. A line reading `ok
check-pins' tells a reader nothing about what passing means, and the whole argument for
this block is that a check nobody can interpret is a check nobody acts on.")

(defun run-checker (script args big-heap-p)
  "Run scripts/SCRIPT in a fresh image. Returns (values exit-code output).

A MISSING CHECKER IS A FAILURE, not a skip. A guard that is absent and a guard that passes
are identical at the exit code, which is the defect this whole block is about -- so the
absence is reported as one rather than stepped over."
  (let ((path (merge-pathnames (format nil "scripts/~A" script) *root*)))
    (if (not (probe-file path))
        (values :missing "")
        (let ((out (make-string-output-stream)))
          (let ((code (nth-value
                       2 (uiop:run-program
                          (append (list (namestring sb-ext:*runtime-pathname*))
                                  (when big-heap-p (list "--dynamic-space-size" "4096"))
                                  (list "--script" (namestring path))
                                  args)
                          :output out :error-output out
                          :environment (child-environment)
                          :ignore-error-status t))))
            (values code (get-output-stream-string out)))))))

(defun report-checkers ()
  "Run every provenance checker and report it. Returns nothing; failures go through FAIL."
  (format t "~%========== PROVENANCE (not counted as checks) ==========~%")
  (dolist (entry +checkers+)
    (destructuring-bind (script args big-heap-p answers) entry
      (let ((label (pathname-name script)))
        (multiple-value-bind (code out) (run-checker script args big-heap-p)
          (cond
            ((eq code :missing)
             (format t "  MISSING ~a~24t~a~%" label answers)
             (fail "scripts/~a is missing -- the check it carries verifies nothing" script))
            ((zerop code)
             (format t "  ok      ~a~24t~a~%" label answers))
            (t
             (format t "  FAIL    ~a~24t~a~%" label answers)
             ;; Unmuffled, because a verdict with the evidence stripped off is the thing
             ;; this tree keeps refusing to accept from anyone else.
             (dolist (line (last (uiop:split-string (string-right-trim '(#\Newline) out)
                                                    :separator '(#\Newline))
                                 12))
               (format t "          ~a~%" line))
             (fail "scripts/~a exited ~d -- ~a" script code answers))))))))

;;; --- backend coverage (pre-publication issue 176) ----------------------------------------------

(defparameter +required-backends+ '("postgres")
  "Backends that must actually execute checks when a suite reports per-backend coverage.

SQLite is not listed: it needs no server, so it cannot silently fail to run, and demanding
it would only produce a rule that never fires. Postgres is the one that quietly does not
run, which is the whole reason this exists.")

(defun allow-no-pg-p ()
  (let ((v (uiop:getenv "OURANOS_ALLOW_NO_PG")))
    (and v (member (string-trim " " v) '("1" "true" "yes") :test #'string-equal) t)))

(defun backend-coverage (output)
  "Parse `BACKEND-CHECKS <name> <rest>` lines from OUTPUT into an alist of (name . rest).

Returns NIL when the suite reported none, which is not a failure -- most suites touch no
storage engine and have nothing to say here."
  (let ((out '()))
    (dolist (line (uiop:split-string output :separator '(#\Newline)) (nreverse out))
      (let* ((trimmed (string-trim '(#\Space #\Tab #\Return) line))
             (marker "BACKEND-CHECKS "))
        (when (uiop:string-prefix-p marker trimmed)
          (let* ((rest (subseq trimmed (length marker)))
                 (sp (position #\Space rest)))
            (when sp
              (push (cons (subseq rest 0 sp) (string-trim " " (subseq rest (1+ sp))))
                    out))))))))

(defun sqlite-library-line (output)
  "The rest of the `SQLITE-LIBRARY ' line in OUTPUT (\"<version> <path>\" or \"UNKNOWN
(<reason>)\"), or NIL if there is none. mnemosyne/tests prints it with its coverage banner."
  (dolist (line (uiop:split-string output :separator '(#\Newline)) nil)
    (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line))
          (marker "SQLITE-LIBRARY "))
      (when (uiop:string-prefix-p marker trimmed)
        (return (subseq trimmed (length marker)))))))

(defun coverage-problems (coverage)
  "The reasons COVERAGE is not acceptable, as a list of strings. Empty means fine."
  (let ((problems '()))
    (dolist (want +required-backends+ (nreverse problems))
      (let* ((cell (assoc want coverage :test #'string=))
             (value (cdr cell)))
        (cond
          ;; A suite that reports coverage at all must account for every required backend.
          ((null cell)
           (push (format nil "~a reported per-backend coverage but never mentioned ~a"
                         "the suite" want)
                 problems))
          ((uiop:string-prefix-p "UNREACHABLE" value)
           (push (format nil "~a was configured but UNREACHABLE -- ~a" want value) problems))
          ((uiop:string-prefix-p "SKIPPED" value)
           (unless (allow-no-pg-p)
             (push (format nil "~a did not run (~a); set MNEMOSYNE_TEST_PG_URL, or OURANOS_ALLOW_NO_PG=1 to excuse it"
                           want value)
                   problems)))
          ((and (every #'digit-char-p value) (plusp (length value)))
           (when (zerop (parse-integer value))
             (push (format nil "~a executed ZERO checks" want) problems)))
          (t (push (format nil "~a reported an unparseable coverage value ~s" want value)
                   problems)))))))

;;; --- counting -------------------------------------------------------------

(defun count-checks (output)
  "Sum every `Did N checks.` FiveAM emits in OUTPUT. Returns NIL if it emitted none at
all -- which means the suite never ran, not that it ran and found nothing."
  (let ((total nil) (start 0))
    (loop
      (let ((p (search "Did " output :start2 start)))
        (unless p (return))
        (let* ((numstart (+ p 4))
               (numend (position-if-not #'digit-char-p output :start numstart)))
          (when (and numend (> numend numstart)
                     (string= " checks" output :start2 numend
                                               :end2 (min (length output) (+ numend 7))))
            (setf total (+ (or total 0)
                           (parse-integer output :start numstart :end numend)))))
        (setf start (1+ p))))
    total))

(defun count-skips (output)
  "Sum every `Skip: N` FiveAM emits in OUTPUT; 0 if none.

A skipped check is a check that DID NOT RUN, and the whole point of this script is that a
green signal must say what produced it. A platform-guarded test is legitimate -- Windows
cannot make a symlink -- but a suite that silently drops two checks on one platform reads as
identical coverage everywhere, and the gap then shows up only as an unexplained difference
in a total (pre-publication issue 168)."
  (let ((total 0) (start 0))
    (loop
      (let ((p (search "Skip: " output :start2 start)))
        (unless p (return))
        (let* ((numstart (+ p 6))
               (numend (position-if-not #'digit-char-p output :start numstart)))
          (when (and numend (> numend numstart))
            (incf total (parse-integer output :start numstart :end numend))))
        (setf start (1+ p))))
    total))

;;; Reading FiveAM's report lives in scripts/fiveam-report.lisp, loaded at the top of this
;;; file, for the reason pre-publication issue 448 makes plain: parsing it "to the first blank line" reported only
;;; the failures before the first bare `is` and gave no sign that it had stopped. A helper
;;; defined inline here can only be exercised by running the whole gate, which is how that
;;; survived being written, reviewed and relied on.
;;;
;;; Added originally because a Windows CI leg reported `CONS/TESTS 294 checks, some failing`
;;; and stopped there. The suite ran in a child image whose output this script had already
;;; discarded, so the one machine that could see the failure was the one that threw the
;;; detail away. A gate whose job is to say what to fix must carry the finding out with it --
;;; all of it.

(defun failure-details (output)
  "WHICH checks failed, not merely that some did. See scripts/fiveam-report.lisp."
  (ouranos-fiveam-report:failure-details output))

(defun skip-reasons (output)
  "The reasons under FiveAM's `Skip Details:` block, so the gate can say WHAT did not run
rather than only how much. See scripts/fiveam-report.lisp."
  (ouranos-fiveam-report:skip-reasons output))

;;; --- run ------------------------------------------------------------------

(defvar *failures* '())
(defun fail (fmt &rest args) (push (apply #'format nil fmt args) *failures*))

(defun tail-lines (text n)
  "The last N non-blank lines of TEXT, indented -- enough to see why a child died."
  (let ((lines (remove-if (lambda (l) (string= "" (string-trim " " l)))
                          (uiop:split-string text :separator '(#\Newline)))))
    (format nil "~{          ~a~^~%~}"
            (last lines (min n (length lines))))))

(defun failure-excerpt (text n)
  "The part of a dead child's output that says WHAT went wrong.

TAIL-LINES alone was actively misleading here, and CI is what made it obvious. SBCL prints
an unhandled condition at the TOP of its error output and the backtrace BELOW it, so the
last N lines are the deepest stack frames -- SB-IMPL::%START-LISP and friends -- followed
by `unhandled condition in --disable-debugger mode, quitting`. Every one of 23 failing
systems in the first CI run reported that identical, contentless tail. The actual cause,
`Component \"log4cl\" not found`, was in the output the whole time and never shown.

So: lead with the `Unhandled ...` block when there is one, and keep the tail as the
fallback for a child that died without printing a condition at all."
  (let* ((lines (remove-if (lambda (l) (string= "" (string-trim " " l)))
                           (uiop:split-string text :separator '(#\Newline))))
         (at (position-if (lambda (l) (search "Unhandled " l)) lines)))
    (if at
        (format nil "~{          ~a~^~%~}"
                (subseq lines at (min (length lines) (+ at n))))
        (tail-lines text n))))

(defun warnings-in (output)
  "The `caught WARNING:` lines SBCL printed in OUTPUT, if any.

Scanned from the child's output rather than trapped with HANDLER-BIND, because the
warning that motivated this is DEFERRED: SBCL reports an undefined variable at the end of
the compilation unit, past the point ASDF inspects compile-file's failure flag -- so
`asdf:load-system` returns cleanly and the child exits 0. That is not a corner case, it is
how an unescaped quote in a docstring emitted a warning on every cold build of hyperion
for a week while this script reported PASS.

STYLE-WARNINGs are deliberately not matched: they are advisory, they are noisy in Coalton
code we do not own, and a gate that cries wolf gets switched off."
  (let ((lines (uiop:split-string output :separator '(#\Newline)))
        (out '()))
    ;; Report the marker line AND the lines around it. SBCL prints the offending form
    ;; and the file above `caught WARNING:`, and the message itself BELOW it -- so the
    ;; marker alone says only "something warned", which is nearly useless in a gate
    ;; whose whole job is to tell you what to fix. Learned by hitting it: an SBCL bump
    ;; produced a cold-build-only warning that this function reported as
    ;; "compiled with 1 warning" and nothing more, and it did not reproduce warm.
    (loop for tail on lines
          for l = (car tail)
          when (search "caught WARNING" l)
            do (let ((context (subseq tail 0 (min 5 (length tail)))))
                 ;; Excused only if a KNOWN pattern appears in this warning's own context,
                 ;; not merely somewhere in the output -- otherwise one excused warning
                 ;; would excuse every other warning in the same build.
                 (unless (some (lambda (known)
                                 (some (lambda (cl) (search (car known) cl)) context))
                               +known-warnings+)
                   (setf out (append out context)))))
    out))


;;; --- the native launcher axis (pre-publication issue 410) ---------------------------------------
;;;
;;; pre-publication PR 395 moved the hyperion-view build OUT of this gate and INTO verify.yml. The SUITE stayed
;;; here, and five of its assertions skip unless the binary exists -- so a cold local gate
;;; covered ten checks fewer than CI on the same commit, both printed `VERDICT: PASS', and the
;;; axes line read `base+uv' in both cases because the launcher was not an axis when pre-publication issue 385 was
;;; written. Measured on Windows at 4cc4564, both directions:
;;;
;;;   launcher present : 17 checks, 0 skipped
;;;   launcher absent  :  7 checks, 5 skipped      <- the ten, independently of pre-publication issue 410's Linux
;;;                                                   figures, on the other platform
;;;
;;; TWO THINGS ARE DONE ABOUT IT AND NEITHER IS SUFFICIENT ALONE.
;;;
;;; 1. THE GATE BUILDS IT, so the canonical leg can compute the canonical number again. pre-publication PR 395
;;;    did not only change a total: it removed a capability, because the Linux lane had been
;;;    producing README figures from its own gate log and silently could not any more. Cost,
;;;    MEASURED rather than estimated -- Windows, MSVC, this machine:
;;;
;;;      prerequisite check                          3.3 s
;;;      cold: SDK fetch (9 MB, NuGet) + compile     5.5 s
;;;      SDK already cached                          3.4 s
;;;
;;;    Cheap enough to be unconditional, which is what makes this option viable at all. pre-publication issue 410
;;;    records 3 s compile plus ~26 s of apt for a bare Linux runner.
;;;
;;; 2. AND THE AXIS IS DISCLOSED, because the build can fail for reasons that are nobody's
;;;    choice. Three are real and all three are reachable:
;;;
;;;      no C++ toolchain            pre-publication issue 382 measured this host class directly: a Windows box
;;;                                  with only Build Tools, and one with no MSVC at all.
;;;      no network                  the Windows SDK fetch is 9 MB from NuGet, and the cache
;;;                                  is gitignored and PER-WORKTREE -- so every cold gate in
;;;                                  a fresh detached worktree pays it, which is precisely
;;;                                  the run AGENTS.md requires before claiming anything
;;;                                  works. Three copies already existed on the machine this
;;;                                  was written on.
;;;      OURANOS_SKIP_VIEW_BUILD=1   the caller's choice, for a slow or offline machine.
;;;
;;; NOT A FAIL when the launcher is absent, for the reason pre-publication issue 385 gives for the same question
;;; one axis over: a gate whose VERDICT depends on whether a C++ toolchain happens to be
;;; installed would gate two checkouts of one commit differently. It is disclosed instead.

;;; The launcher's name is stated in three places -- scripts/view-launcher.lisp,
;;; build.{sh,ps1}'s default output, and `hyperion/desktop:default-launcher' -- and this file
;;; cannot load hyperion to ask, because the gate loads each system in a child. So the
;;; duplication is a CHECKED invariant: when the build reports success and the path does not
;;; then exist, `ouranos-view:run-build' returns :misplaced and the gate FAILS.

(defparameter *view-state* :not-attempted
  "What happened to the launcher build: :built, :skipped, :unavailable, :failed, or
:not-attempted. Set once, by `build-view-launcher'.")

(defparameter *view-reason* nil
  "Why `*view-state*' is not :built -- the sentence the NOT COVERED block prints.")

(defun view-launcher-path ()
  (ouranos-view:launcher-path *root*))

(defun view-covered-p ()
  "Does the launcher exist, so the five launcher assertions can run?

A PROBE, where the uv axis deliberately refuses to be one. The difference is real rather
than convenient: `with-uv-p' is a flag because a probe there would let COVERAGE CHANGE
SILENTLY, and pre-publication issue 385's whole argument is against unreported variance -- not against variance.
This axis reports itself either way, in the tag, in NOT COVERED, and on the machine-readable
`axes-declined' line. And the probe is the only honest predicate available here, because the
assertions run if and only if the binary is present, whatever anyone intended: a flag would
let this run claim `view' while the five assertions skipped."
  (and (probe-file (view-launcher-path)) t))

(defun report-view-uncovered (name)
  "The view axis is off. THREE possible causes, and the reader is told which one."
  (format t "  off     ~a axis~34tthe native webview launcher was not built~%" name)
  (format t "          ~a~%" (or *view-reason* "reason unrecorded -- the build step did not run"))
  ;; NOT a list of systems: hyperion/view/tests DID run. Saying otherwise would be exactly
  ;; the false claim this block exists to prevent.
  (format t "          hyperion/view/tests still ran; FIVE assertions inside it skipped~%")
  (format t "          (the launcher's argv handling, flag refusal and surplus arguments).~%")
  (format t "          Measured at +10 checks when present, so a total from this run is TEN~%")
  (format t "          BELOW a run that built it -- which is what CI does. Build it with~%")
  (format t "          hyperion/hyperion-view/build.~a and re-run to close the gap.~%"
          (if (uiop:os-windows-p) "ps1" "sh")))

(defun build-view-launcher ()
  "Build the native webview launcher, best effort, recording WHY when it does not happen."
  (format t "~%========== NATIVE LAUNCHER (pre-publication issue 410) ==========~%")
  ;; PREREQUISITES FIRST, inside run-build, so a host with no C++ toolchain DECLINES the axis
  ;; instead of failing the gate. That host is measured, not hypothetical (pre-publication issue 382).
  (let ((start (get-internal-real-time)))
    (multiple-value-bind (state reason out err)
        (ouranos-view:run-build *root* :output '(:string :stripped t))
      (setf *view-state* state
            *view-reason* reason)
      (ecase state
        (:skipped
         (format t "  off     skipped: OURANOS_SKIP_VIEW_BUILD is set~%"))
        (:unavailable
         (format t "  off     prerequisites missing on this host~%"))
        (:failed
         ;; STDERR *AND* STDOUT. build.ps1 prints cl.exe's diagnostics on STDOUT, so an
         ;; excerpt taken from stderr alone came back EMPTY -- measured, by corrupting
         ;; hyperion-view.cc and watching this branch report a failure with nothing under it.
         ;; A failure whose excerpt is blank is the reason someone re-runs the build by hand
         ;; to find out what happened.
         (format t "  off     ~a~%~a~%" reason
                 (let ((text (if (plusp (length (or err ""))) err out)))
                   (failure-excerpt (or text "") 6))))
        (:misplaced
         ;; A build that reports success while the path this file probes stays empty means
         ;; the gate and the build script disagree about where the binary goes. Without this
         ;; the symptom would be a silently declined axis: ten missing checks reported as a
         ;; disclosure rather than as the defect it is.
         (fail "~a" reason))
        (:built
         (format t "  ok      built in ~,1F s~%" (seconds-since start))))))
  *view-state*)
(defun seconds-since (start)
  (/ (float (- (get-internal-real-time) start)) internal-time-units-per-second))

(let ((t0 (get-internal-real-time)))

  ;; BEFORE the suites, because HYPERION/VIEW/TESTS skips five assertions when the binary is
  ;; absent and a gate that builds it afterwards would have measured the tree without it
  ;; (pre-publication issue 410). Best effort: a host that cannot build declines the axis and says so, rather than
  ;; failing a gate over a C++ toolchain.
  (build-view-launcher)

  (format t "~%========== LOADING (each in its own image) ==========~%")
  (dolist (s (all-systems))
    ;; asdf:load-system, NOT ql:quickload. quickload does not escalate a compile-time
    ;; WARNING to a failure, so a system that `asdf` refuses to build loads clean under it
    ;; -- and the warm fasl it leaves then hides the same warning from the test phase
    ;; below. That is not hypothetical: hyperion/src/path.lisp shipped a Coalton "pattern
    ;; variable matches constructor name" warning that quickload passed and a consuming
    ;; app's plain ASDF build rejected. See docs/coalton-patterns.md 8a/8b.
    (multiple-value-bind (code out)
        (run-checked (format nil "(asdf:load-system :~(~a~))" s) s)
      (let ((warned (warnings-in out)))
        (cond
          ((not (zerop code))
           (format t "  FAIL    ~a~%~a~%" s (failure-excerpt out 6))
           (fail "~a" (or (ouranos-failure-origin:report-origin out s *root*)
                          (format nil "~a failed to load in a clean image" s))))
          (warned
           (format t "  WARN    ~a~%~{          ~a~%~}" s warned)
           (fail "~a compiled with ~D warning~:P" s (length warned)))
          (t (format t "  ok      ~a~%" s))))))

  (format t "~%========== SUITES (each in its own image) ==========~%")
  (let ((grand 0))
    (dolist (s (all-test-systems))
      (multiple-value-bind (code text)
          (run-checked (format nil "(asdf:test-system :~(~a~))" s) s)
        (let ((n (count-checks text))
              (empty-reason (cdr (assoc s +known-empty+))))
          (cond
            ((not (zerop code))
             (format t "  FAIL    ~a  (child exited ~a)~%~a~%" s code (failure-excerpt text 6))
             (fail "~a" (or (ouranos-failure-origin:report-origin text s *root*)
                            (format nil "~a errored in a clean image" s))))
            ((null n)
             (format t "  NO-RUN  ~a  -- exited 0 but emitted no check count~%" s)
             (fail "~a ran ZERO checks (missing :perform, or an empty suite)" s))
            ((zerop n)
             (if empty-reason
                 (format t "  empty   ~a  -- known: ~a~%" s empty-reason)
                 (progn (format t "  NO-RUN  ~a  -- 0 checks~%" s)
                        (fail "~a ran ZERO checks" s))))
            ((and (search "Fail: 0 ( 0%)" text) (warnings-in text))
             (incf grand n)
             (format t "  WARN    ~a~34t~a checks~%~{          ~a~%~}" s n (warnings-in text))
             (fail "~a compiled with ~D warning~:P" s (length (warnings-in text))))
            ((search "Fail: 0 ( 0%)" text)
             (incf grand n)
             (let ((skipped (count-skips text)))
               (if (zerop skipped)
                   (format t "  ok      ~a~34t~a checks~%" s n)
                   ;; Named, not buried: a skip is coverage this run does NOT have.
                   (format t "  ok      ~a~34t~a checks (~D skipped)~%~{          skip: ~a~%~}"
                           s n skipped (skip-reasons text)))))
            (t (incf grand n)
               (let ((details (failure-details text)))
                 (format t "  FAIL    ~a~34t~a checks, some failing~%~{          ~a~%~}"
                         s n details)
                 (unless details
                   (format t "~a~%" (failure-excerpt text 8))))
               (fail "~a had failing checks" s))))
        ;; Per-backend coverage, INDEPENDENT of pass/fail above (pre-publication issue 176). A suite can be
        ;; entirely green and still have exercised one storage engine -- that is the exact
        ;; shape of the defect this clause exists to catch, so it is checked separately
        ;; rather than folded into the cond, where the `Fail: 0` branch would swallow it.
        (let ((coverage (backend-coverage text)))
          (when coverage
            (dolist (cell coverage)
              (format t "          backend ~a: ~a~%" (car cell) (cdr cell)))
            ;; Which SQLite library those checks ran on (#129). Reported, never judged: the
            ;; pinned version is provisioned only on Windows, and elsewhere the OS copy is the
            ;; expected one, so there is no single right answer for the gate to enforce. What
            ;; it prevents is a leg whose SQLite nobody can name. Only for a suite that ran
            ;; SQLite checks: praxeon/memory-db reports Postgres coverage alone and has no
            ;; SQLite to name.
            (when (assoc "sqlite" coverage :test #'string=)
              (format t "          sqlite library: ~a~%"
                      (or (sqlite-library-line text)
                          "NOT REPORTED (the suite ran SQLite checks and printed no SQLITE-LIBRARY line)")))
            ;; An excused skip is not a problem for the verdict, but it is a gap in what the
            ;; run covered, so NOT COVERED names it (#171).
            (let ((pg (assoc "postgres" coverage :test #'string=)))
              (when (and pg (allow-no-pg-p) (uiop:string-prefix-p "SKIPPED" (cdr pg)))
                (push (cons s (cdr pg)) *postgres-excused*)))
            (dolist (problem (coverage-problems coverage))
              (format t "  COVER   ~a -- ~a~%" s problem)
              (fail "~a: ~a" s problem))))))

    ;; --- the platform axis (pre-publication issue 182) ------------------------------------------
    ;; Printed as its own block, ALWAYS, on every OS -- including the ones that own
    ;; nothing. A reader of a macOS PASS has to be able to see what that PASS does not
    ;; cover, and silence cannot carry that.
    (format t "~%========== PLATFORM (host: ~(~a~)) ==========~%" (or (ouranos-platform:host-os) "unknown"))
    (let ((entries (ouranos-platform:entries-here)))
      (if (null entries)
          (format t "  this host owns no platform packages~%")
          (dolist (entry entries)
            (let* ((system   (ouranos-platform:entry-system entry))
                   (issue    (ouranos-platform:entry-issue entry))
                   (findable (asdf:find-system system nil)))
              (cond
                ;; Decided but unwritten. Named every run so it cannot quietly become
                ;; permanent, but not a failure -- a gate that reds for work that has not
                ;; started gets switched off, and a switched-off gate is what this defends.
                ((and (ouranos-platform:planned-p entry) (not findable))
                 (format t "  planned ~a~34tnot in the tree yet (~a)~%" system issue))
                ;; It landed and the registry did not notice. This one IS a failure: the
                ;; package is now being carried with no gate over it, which is exactly the
                ;; silence pre-publication issue 182 exists to remove.
                ((ouranos-platform:planned-p entry)
                 (format t "  STALE   ~a~34tPRESENT but registry says :planned (~a)~%" system issue)
                 (fail "~a is in the tree but scripts/platform-packages.lisp still marks it :planned -- flip it to :required so the gate covers it" system))
                ;; Required and simply not there.
                ((not findable)
                 (format t "  MISSING ~a~34trequired on this host, ASDF cannot find it (~a)~%" system issue)
                 (fail "~a is required on ~(~a~) and is not in the tree" system (ouranos-platform:host-os)))
                ;; Required and present: it went through the loops above, in its own image,
                ;; like every other system. Its pass or failure is already recorded there;
                ;; this line exists so the axis is legible in one place.
                (t
                 (format t "  covered ~a~34tbuilt and tested above~%" system)))))))
    ;; What this host CANNOT answer. `aion/windows was not checked' and `aion/windows does
    ;; not apply here' are the same silence otherwise.
    (dolist (pair (ouranos-platform:not-applicable-here))
      (format t "  n/a     ~a~34tnot applicable on this host (owned by ~(~a~))~%"
              (ouranos-platform:entry-system (cdr pair)) (car pair)))

    ;; The hub guard, and whether it is actually armed (#204-adjacent, found by the
    ;; Windows lane). `.githooks/pre-commit' refuses a commit on a non-main branch in a
    ;; MAIN checkout -- but `core.hooksPath' is per-clone, is not carried by git, and is
    ;; set by bootstrap.lisp. So on any clone that has not re-run bootstrap since the hook
    ;; landed, the guard is SILENTLY INERT: it exists, it reads correctly, and it would
    ;; refuse nothing. An unarmed guard and an armed one look identical until the moment
    ;; one matters, which is the whole reason the gate has to ask.
    ;;
    ;; THREE hooks are checked. `pre-push' refuses to push a commit, a branch name or a tag
    ;; that carries a private name (.githooks/private-names.sh); it is the one check that a
    ;; commit made by `git am', `cherry-pick', `rebase' or --no-verify cannot skip.
    ;;
    ;; `commit-msg' refuses a Co-Authored-By trailer naming
    ;; an AI assistant -- a rule every harness in use here actively instructs the model to
    ;; break, in the same breath as telling it to follow the repo's conventions. It held in
    ;; this tree for six weeks on review discipline and then broke in a satellite repo that
    ;; had no hook, so "it has not happened yet" is not the evidence it looks like. A
    ;; MISSING hook is as inert as an unarmed one and is reported separately, because the
    ;; two have different fixes.
    (let* ((root (namestring *root*))
           (hooks '(".githooks/pre-commit" ".githooks/commit-msg" ".githooks/pre-push"))
           (main-checkout-p (probe-file (merge-pathnames ".git/HEAD" *root*)))
           (present (remove-if-not (lambda (h) (probe-file (merge-pathnames h *root*))) hooks))
           (configured (string-trim '(#\Space #\Newline #\Return)
                                    (with-output-to-string (out)
                                      (uiop:run-program
                                       (list "git" "-C" root "config" "--get" "core.hooksPath")
                                       :output out :ignore-error-status t)))))
      (when main-checkout-p
        (dolist (h hooks)
          (unless (member h present :test #'string=)
            (fail "~a is MISSING from a main checkout -- the guard it carries refuses nothing" h)))
        (cond
          ((null present))
          ((string= configured "")
           (fail "the hub guards are NOT armed: ~{~a~^, ~} exist but core.hooksPath is unset. Run bootstrap.lisp, or: git config core.hooksPath .githooks"
                 present))
          (t
           (format t "~%  hub guards armed -> core.hooksPath=~a (~{~a~^, ~})~%"
                   configured (mapcar #'pathname-name (mapcar #'pathname present)))
           ;; Armed and executable are different properties, and git enforces the second
           ;; silently: it SKIPS a hook without the bit rather than reporting one. The mode
           ;; asked for here is GIT'S, not the filesystem's -- `ls-files -s' reports what
           ;; the index carries, which is what every other clone will receive. A hook that
           ;; is executable on this machine but committed 100644 works for the person who
           ;; wrote it and for nobody else, and that is the failure a cross-machine rule
           ;; actually has. Reading git also keeps this off the sb-posix platform axis.
           (dolist (h present)
             (let ((entry (with-output-to-string (out)
                            (uiop:run-program (list "git" "-C" root "ls-files" "-s" h)
                                              :output out :ignore-error-status t))))
               (unless (search "100755" entry)
                 (fail "~a is not executable IN GIT (~a) -- git skips it silently on a fresh clone, so it refuses nothing there. Fix: git update-index --chmod=+x ~a"
                       h (string-trim '(#\Space #\Newline #\Return) entry) h))))))))

    (report-checkers)
    (report-not-covered)

    (format t "~%========== SUMMARY ==========~%")
    ;; The commit travels WITH the count, because a count without one is a rumour
    ;; (AGENTS.md): a reader whose figure differs cannot otherwise tell whether the cause is
    ;; the host, the tree, or a real defect. It matters most where the number outlives this
    ;; process -- check-readme-counts.lisp reads a CI log from another machine and another
    ;; commit, and without this line it can only stamp the commit of whoever runs it.
    (let ((sha (ignore-errors
                 (string-trim '(#\Newline #\Space #\Return)
                              (uiop:run-program '("git" "rev-parse" "--short" "HEAD")
                                                :output :string :ignore-error-status t)))))
      (format t "commit: ~a~%" (if (and sha (plusp (length sha))) sha "unknown")))
    (report-checkout-freshness)
    ;; The axis coordinate travels WITH the count, exactly as the commit does above and for
    ;; the same reason (pre-publication issue 385). A total from a run that declined an axis must not be
    ;; printable as the same kind of number as a full one -- 4065 and 4400 were both true
    ;; of d0547d1 and only one of them is the tree's count. The suffix is after the digits,
    ;; so check-readme-counts.lisp's `%labelled-integer' still parses it.
    (format t "total checks executed: ~a (axes: ~a)~%" grand (axes-tag))
    ;; The same fact on lines of their own, from the same functions, for a consumer that
    ;; should not have to parse a parenthetical out of a human sentence.
    ;;
    ;; What was DECLINED is reported as well as what ran, and the consumer keys on that one.
    ;; It is the difference between "this log says base+uv" -- which a consumer can only
    ;; check against a list of axes it has to be told about, and will therefore be wrong
    ;; about the day an axis is added -- and "this log declined nothing", which stays true
    ;; without anyone maintaining it. A new axis blocks publication by existing.
    (format t "axes: ~a~%" (axes-tag))
    (format t "axes-declined: ~a~%"
            (let ((d (axes-declined)))
              (if (null d) "none" (format nil "~{~a~^ ~}" (mapcar #'first d)))))
    (when (allow-no-pg-p)
      (format t "NOTE: OURANOS_ALLOW_NO_PG is set -- a skipped Postgres was EXCUSED, not passed.~%"))
    ;; The checkers each run in their own child too, so they are in this count -- a
    ;; number that says how many images ran has to be about how many images ran.
    (format t "elapsed: ~,1F s across ~D isolated images~%"
            (seconds-since t0)
            (+ (length (all-systems)) (length (all-test-systems)) (length +checkers+)))
    (if *failures*
        (progn (format t "~%VERDICT: FAIL~%")
               (dolist (f (reverse *failures*)) (format t "  - ~a~%" f))
               (uiop:quit 1))
        (progn (format t "VERDICT: PASS~%") (uiop:quit 0)))))
