;;;; suite.lisp --- the root test suite + entry point.

(in-package #:hyperion/tests)

(def-suite hyperion
  :description "All Hyperion tests.")

(defun run-tests ()
  "Run the whole Hyperion suite; return T on success (for `asdf:test-system`).
Named RUN-TESTS, not RUN -- FiveAM already exports RUN.

Logging is turned down to :warn first: the request middleware logs a line per request at
:info, which would bury the test output in CI. A test that wants to assert on logging can
raise the level itself."
  (aion/log:level! :warn)
  (run! 'hyperion))
