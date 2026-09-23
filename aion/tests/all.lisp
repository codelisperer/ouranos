;;;; all.lisp --- the aion umbrella suite.
;;;;
;;;; `aion/tests` is the system `cons test` and `asdf:test-system` reach for. Core aion has
;;;; no tests of its own yet (it is still a version stub), so this runs the suites of the
;;;; opt-in aux systems -- aion/csv, aion/csv/types, aion/clock and aion/log -- which is
;;;; where aion's real coverage lives today. When core aion grows, its suite is added here.
;;;;
;;;; Why this file exists at all: `aion/tests` previously declared `:components ()` and no
;;;; `:perform (test-op ...)`, so `asdf:test-system :aion/tests` loaded nothing, ran nothing,
;;;; and exited SUCCESSFULLY -- reporting a green aion that had executed zero checks. See
;;;; issue #116. `aion/cons.lisp`'s `test` target also called `aion/tests:run-tests`, a
;;;; function that did not exist.

(cl:defpackage #:aion/tests
  (:use #:cl)
  (:local-nicknames (#:csv   #:aion/csv/tests)
                    (#:ctypes #:aion/csv/types/tests)
                    (#:clock #:aion/clock/tests)
                    (#:log   #:aion/log/tests))
  (:documentation
   "Umbrella suite for aion: runs every aion sub-suite and reports one verdict.")
  (:export #:run-tests))
(in-package #:aion/tests)

(defun run-tests ()
  "Run every aion sub-suite; return T only if all of them pass.

Both suites are run BEFORE the verdict is computed -- binding first rather than using a
short-circuiting AND -- because a run that stops at the first failing suite hides whatever
the later ones would have found, which is the opposite of what a test command is for."
  (let ((csv-ok (csv:run-tests))
        (ctypes-ok (ctypes:run-tests))
        (clock-ok (clock:run-tests))
        (log-ok (log:run-tests)))
    (and csv-ok ctypes-ok clock-ok log-ok)))
