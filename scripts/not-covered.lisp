;;;; not-covered.lisp --- the gate's NOT COVERED section, printed from arguments (#182)
;;;;
;;;; scripts/verify-tree.lisp ends every run with a NOT COVERED section: the optional axes
;;;; that did not run and why, and every suite whose Postgres checks were skipped under
;;;; OURANOS_ALLOW_NO_PG. It was wrong once already. Before #181 it printed "nothing
;;;; declined" on a run where praxeon/memory-db had skipped all of its Postgres checks.
;;;;
;;;; Split out of verify-tree.lisp and loaded by path, for the same reason as
;;;; failure-origin.lisp and fiveam-report.lisp: everything in that script runs at toplevel,
;;;; so a function defined there can only be exercised by running the whole gate. Here the
;;;; printer takes what it reports as arguments instead of reading the gate's state, so a
;;;; test can hand it known inputs and read what it prints. verify-tree.lisp's
;;;; REPORT-NOT-COVERED passes its own state. See cons/tests/not-covered-tests.lisp.

(defpackage #:ouranos-not-covered
  (:use #:cl)
  (:export #:print-not-covered))

(in-package #:ouranos-not-covered)

(defun print-not-covered (declined excused tag &optional (stream *standard-output*))
  "Print the NOT COVERED section to STREAM.

DECLINED is the list of optional-axis entries this run did not include, each
(name predicate disclose). DISCLOSE is called with NAME and prints that axis's own line or
lines, because each axis states its own cause (see +OPTIONAL-AXES+ in verify-tree.lisp).
EXCUSED is a list of (suite . reason), in the order the suites ran, for each suite whose
Postgres checks were skipped and excused by OURANOS_ALLOW_NO_PG. TAG is the axis
coordinate, such as \"base+uv+view\".

Printed ALWAYS, including when nothing was declined -- on the PLATFORM block's principle.
A block that appears only when there is bad news teaches readers that its absence means
nothing happened, and absence is precisely what they cannot distinguish from silence.

NOT \"caller's choice\" ANY MORE, which was the heading until pre-publication issue 410. `uv' is off only when
somebody chooses; `view' is off when a host has no C++ toolchain, when the 9 MB SDK fetch had
no network, or when the caller said skip -- three causes, one of them a choice. A heading
that named the cause was fine while there was one cause. Each entry now says its own.

A SKIPPED POSTGRES IS LISTED HERE TOO, when OURANOS_ALLOW_NO_PG excused it (#171). Without
the excuse the run fails, so this only happens on a run that passed. Until this was added,
such a run printed \"nothing declined\" here while suites that need Postgres had skipped
their checks, and the only sign was one NOTE line in the summary."
  (let ((*standard-output* stream))
    (format t "~%========== NOT COVERED ==========~%")
    (if (null declined)
        (if excused
            (format t "  every optional axis ran (~a), but Postgres did not:~%" tag)
            (format t "  nothing declined -- every optional axis ran (~a)~%" tag))
        (dolist (entry declined)
          (destructuring-bind (name pred disclose) entry
            (declare (ignore pred))
            (funcall disclose name))))
    (dolist (cell excused)
      (format t "  off     postgres in ~a~34t~a~%" (car cell) (cdr cell))
      (format t "          OURANOS_ALLOW_NO_PG excused it. Its Postgres checks did not run and are NOT in the total below.~%"))))
