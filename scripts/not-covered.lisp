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
  (:export #:print-not-covered #:missing-backend-reports #:unattributed-backend-reports))

(in-package #:ouranos-not-covered)

(defun print-not-covered (declined excused tag &optional (stream *standard-output*))
  "Print the NOT COVERED section to STREAM.

DECLINED is the list of optional-axis entries this run did not include, each
(name predicate disclose). DISCLOSE is called with NAME and prints that axis's own line or
lines, because each axis states its own cause (see +OPTIONAL-AXES+ in verify-tree.lisp).
EXCUSED is a list of (suite backend reason variable), in the order the suites ran, for each
suite whose checks of BACKEND were skipped and excused by VARIABLE: Postgres by
OURANOS_ALLOW_NO_PG, the credential store by OURANOS_ALLOW_NO_CREDENTIAL_STORE (#357). TAG is
the axis coordinate, such as \"base+uv+view\".

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
their checks, and the only sign was one NOTE line in the summary. A skipped credential store,
excused by OURANOS_ALLOW_NO_CREDENTIAL_STORE, is listed the same way (#357)."
  (let ((*standard-output* stream))
    (format t "~%========== NOT COVERED ==========~%")
    (if (null declined)
        (if excused
            (format t "  every optional axis ran (~a), but some backends did not:~%" tag)
            (format t "  nothing declined -- every optional axis ran (~a)~%" tag))
        (dolist (entry declined)
          (destructuring-bind (name pred disclose) entry
            (declare (ignore pred))
            (funcall disclose name))))
    (dolist (entry excused)
      (destructuring-bind (suite backend reason variable) entry
        (format t "  off     ~a in ~a~34t~a~%" backend suite reason)
        (format t "          ~a excused it. Its ~a checks did not run and are NOT in the total below.~%"
                variable backend)))))

(defun unattributed-backend-reports (coverage)
  "The problems with COVERAGE, an alist of (backend . value) from a suite's BACKEND-CHECKS
lines, whose backend name is NIL: checks a per-backend counter recorded with no backend
bound, one string for each. Such checks belong to no backend, so they are evidence for none,
and they mean an assertion ran outside the macro that names the backend. mnemosyne/tests
printed BACKEND-CHECKS NIL 2 for a SQLite-only test that used IS* outside WITH-EACH-BACKEND."
  (loop for (backend . value) in coverage
        when (string-equal backend "NIL")
          collect (format nil "printed BACKEND-CHECKS NIL ~a: ~a checks were counted under no backend, so an assertion ran outside the form that names its backend" value value)))

(defun missing-backend-reports (suite host coverage required)
  "The problems with SUITE, run on HOST, whose output gave COVERAGE (an alist of (backend . value)
from its BACKEND-CHECKS lines): one string for each backend REQUIRED says this suite must report
on this host and COVERAGE does not mention. REQUIRED is a list of (SUITE BACKEND &key HOSTS),
where HOSTS is a list of HOST values, such as :WINDOWS and :DARWIN, or absent for every host.

The per-backend rules judge a BACKEND-CHECKS line that is there. This catches the line that is
not: a suite that stops printing it, because a reader guard or its test-op changed, would
otherwise pass with none of that backend's checks run, and nothing would say so (#603)."
  (loop for (want-suite backend . options) in required
        for hosts = (getf options :hosts)
        when (and (eq suite want-suite)
                  (or (null hosts) (member host hosts))
                  (not (assoc backend coverage :test #'string=)))
          collect (format nil "printed no BACKEND-CHECKS ~a line, which it must on ~(~a~)"
                          backend (or host "this host"))))
