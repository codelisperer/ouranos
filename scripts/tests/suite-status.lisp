;;;; suite-status.lisp --- the failing items a leg records, and the comparison with an earlier run (#199).
;;;;
;;;; scripts/suite-status.lisp runs as CI runs it, in a child sbcl. The logs below are the end of
;;;; real gate logs: the first is macOS run 44296565093's, whose DOKIMASIA/HYPERION/TESTS failed
;;;; (#1308); the others change only what each test is about.

(in-package #:checkers/tests)

;;; FiveAM's current suite does not carry over from one file to the next (see dump-image.lisp).
(in-suite checkers)

(defparameter +gate-tail-failing+
  (list "total checks executed: 22667 (axes: base+uv+tls+libgit+view)"
        "caught ERROR (#263): 0 in 0 child images"
        "axes: base+uv+tls+libgit+view"
        "axes-declined: none"
        "elapsed: 1982.4 s across 179 isolated images"
        ""
        "VERDICT: FAIL"
        "  - DOKIMASIA/HYPERION/TESTS had failing checks")
  "The end of macOS run 44296565093's verify.log.")

(defun %status-of (log-lines &key crlf)
  "Write LOG-LINES as a verify.log (with CRLF endings when CRLF), run `write' on it, and return
(values exit-code output status-file-text)."
  (let* ((dir (%fresh-tree))
         (log (merge-pathnames "verify.log" dir))
         (out (merge-pathnames "status/suite-status.txt" dir)))
    (%write log (format nil (if crlf "~{~A~C~C~}" "~{~A~*~*~%~}")
                        (loop for l in log-lines append (list l #\Return #\Newline))))
    (multiple-value-bind (code output)
        (%run (merge-pathnames "suite-status.lisp" *scripts*) "write" (namestring log)
              (namestring out) "platform=macos-arm64" "commit=8a389b032ebe2e32de35818b45e5b131850737ed"
              "run=44296565093" "event=workflow_dispatch")
      (values code output (and (probe-file out) (uiop:read-file-string out))))))

(defun %diff-of (current baseline)
  "Write CURRENT and BASELINE (strings, or NIL for a missing file) and run `diff' on them.
Returns (values exit-code output)."
  (let* ((dir (%fresh-tree))
         (c (merge-pathnames "current.txt" dir))
         (b (merge-pathnames "baseline.txt" dir)))
    (when current (%write c current))
    (when baseline (%write b baseline))
    (%run (merge-pathnames "suite-status.lisp" *scripts*) "diff" (namestring c) (namestring b))))

(defun %status-text (gate &rest failing)
  (format nil "platform: macos-arm64~%commit: 0123456789abcdef0123~%run: 42~%event: push~%gate: ~A~%~{failing: ~A~%~}"
          gate failing))

(test suite-status-records-the-gate-s-failure-reasons
  (multiple-value-bind (code output text) (%status-of +gate-tail-failing+)
    (is (= 0 code) "~A" output)
    (is (equal (format nil "platform: macos-arm64~%commit: 8a389b032ebe2e32de35818b45e5b131850737ed~%run: 44296565093~%event: workflow_dispatch~%gate: fail~%failing: DOKIMASIA/HYPERION/TESTS had failing checks~%")
               text)
        "~A" text)))

(test suite-status-reads-a-windows-log-and-writes-numbers-on-their-own-as-n
  "The Windows leg's log has CRLF endings, and a reason that carries a count must be the same
item in two runs whose counts differ. A number inside a name is kept."
  (multiple-value-bind (code output text)
      (%status-of (append (butlast +gate-tail-failing+)
                          (list "  - AION/IPV6/TESTS compiled with 3 warnings"
                                "  - DOKIMASIA/HYPERION/TESTS had failing checks"
                                "##[error]Process completed with exit code 1."))
                  :crlf t)
    (is (= 0 code) "~A" output)
    (is (search (format nil "gate: fail~%failing: AION/IPV6/TESTS compiled with N warnings~%failing: DOKIMASIA/HYPERION/TESTS had failing checks~%")
                text)
        "~S" text)
    (is (not (find #\Return text)) "~S" text)
    (is (not (search "##[error]" text)) "a line after the reasons is not a reason: ~S" text)))

(test suite-status-says-when-the-gate-did-not-finish
  "Control for the two tests above: the same log without its verdict is unfinished, and lists
nothing, although a reason-shaped line is present."
  (multiple-value-bind (code output text)
      (%status-of (remove "VERDICT: FAIL" +gate-tail-failing+ :test #'string=))
    (is (= 0 code) "~A" output)
    (is (search "gate: unfinished" text) "~S" text)
    (is (not (search "failing:" text)) "~S" text))
  (multiple-value-bind (code output text) (%status-of (list "VERDICT: PASS"))
    (is (= 0 code) "~A" output)
    (is (search "gate: pass" text) "~S" text)))

(test suite-status-diff-names-newly-failing-and-recovered-items-and-the-baseline
  (multiple-value-bind (code output)
      (%diff-of (%status-text "fail" "B had failing checks" "C had failing checks")
                (%status-text "fail" "A had failing checks" "C had failing checks"))
    (is (= 0 code) "~A" output)
    (is (search "Compared with run 42 on main at 01234567** (macos-arm64, push)" output) "~A" output)
    (is (search (format nil "**Newly failing** (1):~%~%```~%B had failing checks~%```") output)
        "~A" output)
    (is (search (format nil "**Recovered** (1):~%~%```~%A had failing checks~%```") output)
        "~A" output)
    (is (search (format nil "**Still failing** (1):~%~%```~%C had failing checks~%```") output)
        "~A" output)))

(test suite-status-diff-of-two-green-runs-is-one-line
  (multiple-value-bind (code output) (%diff-of (%status-text "pass") (%status-text "pass"))
    (is (= 0 code) "~A" output)
    (is (search "the same, no failing items in either run." output) "~A" output)
    (is (not (search "Newly failing" output)) "~A" output)))

(test suite-status-diff-says-why-it-did-not-compare-and-exits-0
  "Whatever the baseline is, the comparison exits 0 and says in one line why it compared nothing."
  (dolist (case (list (list nil "no baseline file at")
                      (list (format nil "unavailable: listing main's runs failed: HTTP 403~%")
                            "no earlier run's status could be read: listing main's runs failed: HTTP 403")
                      (list (format nil "<html>not a status</html>~%") "is not a suite-status file")
                      (list (%status-text "unfinished") "the gate of run 42 at 01234567 did not finish")))
    (destructuring-bind (baseline expected) case
      (multiple-value-bind (code output) (%diff-of (%status-text "fail" "B had failing checks") baseline)
        (is (= 0 code) "~A" output)
        (is (search "not compared, because" output) "~A" output)
        (is (search expected output) "expected ~S in: ~A" expected output)
        (is (not (search "Newly failing" output)) "~A" output)))))

(test suite-status-diff-prints-the-baseline-note
  (multiple-value-bind (code output)
      (%diff-of (%status-text "pass")
                (concatenate 'string (%status-text "pass")
                             (format nil "baseline-note: no run on main of this pull request's base commit abc had a usable status, so this is the newest one that did.~%")))
    (is (= 0 code) "~A" output)
    (is (search "base commit abc had a usable status" output) "~A" output)))
