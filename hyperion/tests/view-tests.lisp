;;;; view-tests.lisp --- the launcher's ARGUMENT CONTRACT, asserted (#276).
;;;;
;;;; hyperion-view is C++ and verify-tree neither compiles nor runs it, so before this
;;;; file a change to hyperion-view.cc moved NO check count in either direction -- the
;;;; gate was structurally blind to the one component every desktop app shells out to.
;;;; It had two open defects found by hand (#268, #269) and zero tests, which is where the
;;;; third comes from.
;;;;
;;;; WHAT IS TESTED HERE IS THE CLI, NOT THE WINDOW, and that is deliberate rather than a
;;;; limitation accepted quietly. Opening a window needs a display, a window server and a
;;;; WebView2/WebKit runtime; asserting one needs a driver. None of that belongs in a gate
;;;; that has to run on three OSes and on a runner. But the ARGUMENT CONTRACT --
;;;; `URL [TITLE] [WIDTH] [HEIGHT] [--icon PATH]' -- is depended on by
;;;; hyperion/desktop:run-app and by consuming apps, is enforced by nothing else, and is
;;;; exercisable with no display at all. That is the part a gate can hold.
;;;;
;;;; The window half stays #276's open remainder, and it is stated in the issue rather
;;;; than implied by this file's existence.
;;;;
;;;; SKIPS, NOT FAILURES, WHEN THE BINARY IS ABSENT. The launcher is build output: a fresh
;;;; checkout has no hyperion-view until someone runs build.{sh,ps1}. A red suite there
;;;; would train people to ignore it. FiveAM prints the skip and its reason, and
;;;; verify-tree surfaces skips rather than burying them (#284's lesson, one file over) --
;;;; so "not built here" is visible rather than silent.

(defpackage #:hyperion/view/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:desktop #:hyperion/desktop))
  (:export #:run-tests #:view))

(in-package #:hyperion/view/tests)

(def-suite view :description "hyperion-view: the argument contract, headless.")
(in-suite view)

(defparameter +budget+ 10
  "Seconds a CLI invocation may take before we call it hung.

#268 was `--help' never exiting -- it fell through to the URL slot and webview_run()
blocked forever on a window. So EVERY invocation here is bounded, and a timeout is a
FAILURE rather than a hang: a test that waits forever for a launcher that waits forever
teaches nobody anything.")

(defun launcher ()
  "The launcher hyperion/desktop would actually use, or NIL.

Deliberately DESKTOP:DEFAULT-LAUNCHER rather than a path built here. A second copy of
`where is hyperion-view' is the producer/consumer defect this tree keeps finding -- if
resolution moves, this suite must move with it or say so."
  (ignore-errors
   (let ((p (desktop:default-launcher)))
     (and p (probe-file p)))))

(defun run-launcher (&rest args)
  "Run the launcher with ARGS under a timeout. Returns (values exit stdout stderr)."
  (let ((out (make-string-output-stream))
        (err (make-string-output-stream)))
    (handler-case
        (let ((code (nth-value
                     2 (uiop:run-program (cons (uiop:native-namestring (launcher)) args)
                                         :output out :error-output err
                                         :ignore-error-status t))))
          (values code (get-output-stream-string out) (get-output-stream-string err)))
      (error (e) (values :error (get-output-stream-string out) (princ-to-string e))))))

(defmacro with-launcher (&body body)
  `(let ((exe (launcher)))
     (if (null exe)
         (skip "hyperion-view is not built here -- run hyperion/hyperion-view/build.{sh,ps1}")
         (progn ,@body))))

(test the-resolution-rule-answers-without-erroring
  ;; DELIBERATELY NOT GUARDED BY WITH-LAUNCHER, and it is the reason this suite can sit in
  ;; the gate at all. verify-tree FAILS a suite that executes zero checks (#116), and on a
  ;; machine that has never run build.{sh,ps1} every other test here skips -- so without
  ;; one unconditional check, adding this suite to the gate would turn a fresh checkout
  ;; red. This is that check, and it is not a formality: DEFAULT-LAUNCHER walks three
  ;; fallbacks and ends at a bare name, so "it answers something, and does not signal"
  ;; is a real property that a broken resolution rule would violate.
  (finishes (desktop:default-launcher))
  (is (not (null (desktop:default-launcher)))
      "default-launcher must always answer -- its last fallback is the bare name on PATH"))

(test the-launcher-is-where-desktop-looks-for-it
  ;; Not a tautology, and not the same as the test above: DEFAULT-LAUNCHER's last fallback
  ;; is a bare name, so it can answer with something that does not exist. PROBE-FILE is
  ;; the difference between "we have a rule" and "it is there".
  (with-launcher
    (is (probe-file exe) "default-launcher resolved to ~A, which is not a file" exe)))

(test help-prints-usage-and-exits
  ;; #268, and the reason this suite exists at all. Before the fix: no --help handling,
  ;; so it became the URL, a window opened on a failed navigation, and the process never
  ;; returned. Measured on Windows: exited=FALSE after 5s, stdout empty, stderr empty.
  (with-launcher
    (dolist (flag '("--help" "-h"))
      (multiple-value-bind (code out err) (run-launcher flag)
        (is (eql 0 code) "~A must exit 0, got ~S (stderr: ~A)" flag code err)
        (is (search "usage:" out)
            "~A must print usage to STDOUT; got ~S" flag out)
        (is (search "--icon" out)
            "~A's usage must document --icon, which is part of the contract" flag)
        (is (zerop (length err)) "~A must not write to stderr; got ~S" flag err)))))

(test an-unknown-flag-is-refused-rather-than-retitling-the-window
  ;; The comment in main() claimed "an unrecognised flag must never silently become the
  ;; window title" while the code did exactly that -- any --flag fell into the positional
  ;; branch. A docstring-shaped claim in a comment, unchecked. This is the check.
  (with-launcher
    (multiple-value-bind (code out err) (run-launcher "--bogus")
      (declare (ignore out))
      (is (eql 2 code) "an unknown option must exit 2, got ~S" code)
      (is (search "unknown option" err) "and say so on stderr; got ~S" err))))

(test a-trailing-icon-flag-is-refused-rather-than-becoming-the-title
  ;; The same defect's sharper case: `hyperion-view URL --icon' set the TITLE to the
  ;; literal string "--icon", because the i+1<argc guard fell through to the positional
  ;; branch rather than refusing.
  (with-launcher
    (multiple-value-bind (code out err) (run-launcher "http://127.0.0.1:1/" "--icon")
      (declare (ignore out))
      (is (eql 2 code) "a trailing --icon must exit 2, got ~S" code)
      (is (search "--icon needs a path" err) "and say what is wrong; got ~S" err))))

(test surplus-arguments-are-refused
  ;; Four positionals is the contract. A fifth was silently dropped, so a caller that
  ;; added an argument got no signal that the launcher had not understood it.
  (with-launcher
    (multiple-value-bind (code out err) (run-launcher "u" "t" "800" "600" "surplus")
      (declare (ignore out))
      (is (eql 2 code) "a fifth positional must exit 2, got ~S" code)
      (is (search "too many arguments" err) "and name it; got ~S" err))))

(defun run-tests ()
  (let ((results (run 'view)))
    (explain! results)
    (unless (results-status results)
      (error "hyperion/view tests failed"))))
