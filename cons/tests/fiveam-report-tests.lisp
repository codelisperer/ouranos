;;;; fiveam-report-tests.lisp --- the gate must carry out ALL of the finding (pre-publication issue 448)
;;;;
;;;; scripts/fiveam-report.lisp parses the text a child image prints, which is the only
;;;; artefact that survives the child. It used to read the failure block "while the lines are
;;;; not blank", and FiveAM's default reason for an `is' check with no reason string BEGINS
;;;; with a blank line -- so the first such failure printed nothing and hid every failure
;;;; after it in that suite. A Windows run of KLIO/TESTS showed two failing tests; twelve
;;;; were failing (pre-publication issue 446).
;;;;
;;;; +REAL-REPORT+ IS REAL FIVEAM OUTPUT, captured from a suite made to fail on purpose and
;;;; pasted here byte for byte -- same rule as failure-origin-tests.lisp. A parser tested
;;;; against text invented by whoever wrote the parser tests whether that person is
;;;; self-consistent, and every interesting character here (the trailing space after `]:',
;;;; the indented empty line, the blank lines inside one reason) is a character nobody would
;;;; have thought to invent.
;;;;
;;;; IT IS PASTED RATHER THAN GENERATED, and that is a correction rather than the easy
;;;; choice. The first version of this file defined a deliberately-failing suite and ran it
;;;; to produce the report live. It worked, and it made the gate's own check count depend on
;;;; the fasl cache: 538 checks warm, 556 cold, because on a cold pass the suite registered
;;;; and ran twice. A test file that changes the tree's headline number according to whether
;;;; a cache was warm is worse than the defect it was written for.
;;;;
;;;; Tested from cons for the same reason failure-origin-tests.lisp is: cons owns the build
;;;; and tooling surface. Loaded BY PATH because verify-tree.lisp reaches it that way and it
;;;; belongs to no ASDF system.

(in-package #:cons/tests)

(def-suite fiveam-report
  :description "Reading FiveAM's report without losing half of it (pre-publication issue 448)." :in all)
(in-suite fiveam-report)

(defparameter +real-report+
  (format nil "~{~A~%~}"
          '(" Did 2 checks."
            "    Pass: 0 ( 0%)"
            "    Skip: 0 ( 0%)"
            "    Fail: 2 (100%)"
            ""
            " Failure Details:"
            " --------------------------------"
            " A-FAILING-IS-WITH-A-REASON in DEMO []: "
            "      this one was given a reason string"
            " --------------------------------"
            " --------------------------------"
            " A-BARE-IS-FAILING in DEMO []: "
            ;; Here is the whole defect, in one line of somebody else's format string: the
            ;; reason opens with `~2&', so what follows the header is an indented EMPTY line.
            "      "
            "404"
            ""
            " evaluated to "
            ""
            "404"
            ""
            " which is not "
            ""
            "="
            ""
            " to "
            ""
            "200"
            ""
            ""
            " --------------------------------"
            ""))
  "FiveAM's own report for two failing checks, one of them a bare `is'.

Captured from `(explain! (run 'demo))' against fiveam-20241012-git, the version this tree
pins, with one test written `(is (= 200 404))' and the other `(is (= 1 2) \"...\")'.")

(defun %load-fiveam-report ()
  "Load scripts/fiveam-report.lisp -- the file scripts/verify-tree.lisp loads by path."
  (let ((path (merge-pathnames "scripts/fiveam-report.lisp"
                               (asdf:system-source-directory :cons))))
    (unless (probe-file path)
      ;; cons/ is a framework directory inside the monorepo; the script lives at the ROOT.
      (setf path (merge-pathnames "../scripts/fiveam-report.lisp"
                                  (asdf:system-source-directory :cons))))
    (is-true (probe-file path)
             "scripts/fiveam-report.lisp must exist -- verify-tree.lisp loads it by path, so a rename breaks the gate, not just this test. Looked at ~A" path)
    (when (probe-file path) (load path))
    path))

(defmacro %fr (name &rest args)
  "Call an OURANOS-FIVEAM-REPORT function by name at RUNTIME -- the package does not exist
until the file is loaded, so a literal symbol would be resolved by the READER and take the
whole test system down on a tree where the file moved. Same reasoning as %FO."
  `(funcall (read-from-string
             ,(concatenate 'string "ouranos-fiveam-report:" (string-downcase (string name))))
            ,@args))

(defun %entries (lines)
  "How many failure entries LINES holds: FiveAM wraps each in a rule, so a complete block has
two rules per entry.

THE COUNT IS THE MEASUREMENT. `The output is not empty' was true of the truncated block too
-- it held the first entry -- which is exactly how this passed for as long as it did."
  (floor (count-if (lambda (l) (%fr rule-line-p l)) lines) 2))

(defun %to-first-blank-line (output header)
  "The parse this replaced: the lines under HEADER while they are not blank.

KEPT AS THE CONTROL, not as history. An assertion that the new reader finds both entries says
little on its own; what makes it evidence is that the old one demonstrably found fewer from
the very same bytes."
  (let ((at (search header output)))
    (when at
      (let ((lines (uiop:split-string (subseq output at) :separator '(#\Newline))))
        (loop for line in (rest lines)
              for trimmed = (string-trim " " line)
              while (plusp (length trimmed))
              collect trimmed)))))

(test every-failing-check-is-reported-not-only-those-before-the-first-bare-is
  "pre-publication issue 448, in both directions on one input. The old reader stopped at the indented empty line
that opens a generated reason; the new one reads to the rules FiveAM prints, so a blank line
inside an entry is content and a blank line outside one is the end."
  (%load-fiveam-report)
  (let ((old (%to-first-blank-line +real-report+ "Failure Details:"))
        (new (%fr failure-details +real-report+)))
    (is (= 1 (%entries old))
        "the control does not reproduce the defect -- the old reader found ~D entries, so this input no longer demonstrates anything"
        (%entries old))
    (is (= 2 (%entries new))
        "expected both failures; recovered ~D from~%~{  ~A~%~}" (%entries new) new)
    ;; THE EXACT SYMPTOM, reproduced: the old reader keeps the second entry's HEADER -- it
    ;; stops on the indented empty line that comes after it -- and loses the reason under it
    ;; and every entry behind it. That is what the Windows leg printed for
    ;; THE-LOOK-BELONGS-TO-THE-SITE: a test name, a colon, and nothing.
    (is-true (some (lambda (l) (search "A-BARE-IS-FAILING" l)) old)
             "the control no longer reproduces the shape it is here to reproduce")
    (is-false (some (lambda (l) (search "which is not" l)) old)
              "the old reader was supposed to lose the generated reason and did not")
    (is-true (some (lambda (l) (search "which is not" l)) new)
             "the reason under the bare `is' is still missing from the report")
    (is-true (some (lambda (l) (search "this one was given a reason string" l)) new)
             "a reason that WAS supplied stopped surviving the parse")))

(test a-blank-line-inside-a-reason-is-content-and-one-after-an-entry-is-the-end
  "The two kinds of blank line mean opposite things, and telling them apart is the whole of
the fix. A reader that kept every blank line would swallow the rest of the output; one that
stopped at any of them is what shipped."
  (%load-fiveam-report)
  (let ((lines (%fr failure-details +real-report+)))
    (is-true (some (lambda (l) (string= "200" l)) lines)
             "the generated reason's last value sits behind five blank lines and was dropped")
    (is-true (some (lambda (l) (search "which is not" l)) lines)
             "the middle of the generated reason was dropped")
    (is-false (some (lambda (l) (search "Did 2 checks" l)) lines)
              "the parse ran past the end of the failure block: ~{~A / ~}" lines)))

(test the-report-stops-at-its-own-end-rather-than-consuming-what-follows
  "A reader that simply ran to end-of-output would satisfy every assertion above and would
put unrelated gate output inside a failure report. The block ends where FiveAM ends it."
  (%load-fiveam-report)
  (let* ((text (concatenate 'string +real-report+
                            (format nil " Skip Details:~% SOMETHING-ELSE []: ~%    a later block~%")))
         (lines (%fr failure-details text)))
    (is-false (some (lambda (l) (search "SOMETHING-ELSE" l)) lines)
              "a block printed after the failures was swallowed into them: ~{~A / ~}" lines)
    (is (= 2 (%entries lines))
        "and the two entries were still recovered whole")))

(test a-green-report-yields-nothing-rather-than-guessing
  "There is no `Failure Details:' header in a passing report, and that absence has to read as
absence -- a reader that returned the rest of the output here would give every green suite
something to say."
  (%load-fiveam-report)
  (is (null (%fr failure-details (format nil " Did 3 checks.~%    Pass: 3 (100%)~%")))
      "a green report produced failure detail out of nothing"))

(test the-skip-block-still-reports-what-did-not-run
  "Skips are read to a blank line, which is right for them rather than an oversight carried
over: FiveAM prints no rules around skip entries, and a skip reason is the author's own
string, not a generated one, so it does not open with the blank line `is' emits."
  (%load-fiveam-report)
  (let ((lines (%fr skip-reasons
                    (format nil " Skip Details:~% SOME-TEST []: ~%    the reason it did not run~%~% Did 1 check.~%"))))
    (is (= 2 (length lines)) "expected the header and its reason, got ~S" lines)
    (is-true (some (lambda (l) (search "the reason it did not run" l)) lines))
    (is-false (some (lambda (l) (search "Did 1 check" l)) lines)
              "the skip block ran past its end")))

;;; --- every report must pass, not one of them (#605) -----------------------------------------
;;;
;;; The gate passed a suite when "Fail: 0 ( 0%)" appeared anywhere in its output. A test op that
;;; prints more than one report, and exits 0, could fail one and pass another and be reported
;;; ok. The outputs below join two real reports: +REAL-REPORT+ above, and a passing one.

(defparameter +real-passing-report+
  (format nil "~{~A~%~}"
          '(" Did 2 checks."
            "    Pass: 2 (100%)"
            "    Skip: 0 ( 0%)"
            "    Fail: 0 ( 0%)"))
  "FiveAM's report for two passing checks, from hades/credentials/tests run on 2026-10-12.")

(test a-passing-report-and-a-failing-one-are-not-a-pass
  "In either order. The control is the rule this replaced: it finds `Fail: 0 ( 0%)' in the same
text, which is how such a suite was reported ok."
  (%load-fiveam-report)
  (dolist (out (list (concatenate 'string +real-passing-report+ +real-report+)
                     (concatenate 'string +real-report+ +real-passing-report+)))
    (is (= 2 (length (%fr fail-counts out))) "two reports, two Fail lines: ~S" (%fr fail-counts out))
    (is-false (%fr every-report-passed-p out) "a failing report was read as a pass")
    (is-true (search "Fail: 0 ( 0%)" out) "the control: the old rule would have passed this")))

(test two-passing-reports-are-a-pass
  (%load-fiveam-report)
  (let ((out (concatenate 'string +real-passing-report+ +real-passing-report+)))
    (is (equal '(0 0) (%fr fail-counts out)))
    (is-true (%fr every-report-passed-p out))))

(test an-output-with-no-report-is-not-a-pass
  "No `Fail:' line at all, as when a test op printed nothing of FiveAM's. The gate reports such
a suite as NO-RUN before it asks this; here it is not a pass either."
  (%load-fiveam-report)
  (let ((out (format nil "; compiling file \"x.lisp\"~%; wrote x.fasl~%")))
    (is (null (%fr fail-counts out)))
    (is-false (%fr every-report-passed-p out))))

(test a-child-that-signalled-after-its-checks-still-shows-which-failed
  "A test op that signals when a report failed, as aion/tests does since #605, ends its child
with an error, and the gate reports it in the exit-code branch. That branch must still print
which checks failed, from the report before the error."
  (%load-fiveam-report)
  (let* ((out (concatenate 'string +real-report+
                           (format nil "Unhandled SIMPLE-ERROR in thread #<SB-THREAD:THREAD \"main thread\" RUNNING {1}>:~%  aion/tests: a sub-suite failed; the FiveAM reports above say which~%")))
         (printed (make-string-output-stream))
         (n (%fr print-failure-details out printed))
         (text (get-output-stream-string printed)))
    (is (plusp n) "no failure details were found before the error")
    (is (search "A-FAILING-IS-WITH-A-REASON" text) "the first failing check is not printed:~%~A" text)
    (is (search "A-BARE-IS-FAILING" text) "the second failing check is not printed:~%~A" text)))

(test print-failure-details-prints-nothing-when-no-check-failed
  (%load-fiveam-report)
  (let ((printed (make-string-output-stream)))
    (is (zerop (%fr print-failure-details
                    (concatenate 'string +real-passing-report+ (format nil "Unhandled SIMPLE-ERROR~%"))
                    printed)))
    (is (string= "" (get-output-stream-string printed)))))
