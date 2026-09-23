;;;; dev-serve-tests.lisp --- SERVE's :BLOCK, which was exported with no suite (#336).
;;;;
;;;; SERVE gained :BLOCK in 6903485 (PR #250). The same commit's other three fixes all got
;;;; suites; this one did not, and it is the one whose failure mode is a process that exits
;;;; after printing that it is listening. Two consuming apps lost an afternoon to exactly
;;;; that: SERVE was the last form of a build-tool target, it returned, the process ended,
;;;; and it took the server with it AFTER the success banner.
;;;;
;;;; WHY THIS IS ITS OWN FILE, which #336 asks to have answered before the test is written.
;;;; `dev-tests.lisp' states its own scope in its header -- the watcher's FILE SELECTION --
;;;; and says plainly that "driving the whole watcher would mean starting a server and
;;;; sleeping through poll intervals to assert on something these say precisely". That
;;;; claim is true and should stay true, so the tests that do start a server go elsewhere
;;;; rather than falsifying a header.
;;;;
;;;; There is a mechanical reason pointing the same way, and it is the stronger one:
;;;; `dev-tests' loads BEFORE `server-tests' in hyperion.asd, and the port helpers this
;;;; needs -- %SRV-FREE-PORT, %SRV-LISTENING-P, %SRV-AWAIT -- are defined in the latter.
;;;; Reusing them means loading after them. The alternative was a second copy of each under
;;;; a %DEV- prefix, which is the duplicated-fact defect this tree has now found three
;;;; times in one day (AGENTS.md: a check that exists is not a check that runs).
;;;;
;;;; THE FIXTURE IS NOT EASIER THAN REALITY, per #336. Every test here starts a REAL server
;;;; on a REAL free port through SERVE itself, and waits for the port to accept a connection
;;;; before asserting anything. A fixture that stubbed the server would be testing a
;;;; different thing than the one that cost those afternoons.
;;;;
;;;; THE CONTROL IS THE FIRST TEST AND IT IS NOT OPTIONAL. :BLOCK's entire content is
;;;; "does this call return or not", and a call that never returns is indistinguishable
;;;; from a call that is merely slow unless something shows the other branch returning
;;;; promptly under otherwise identical conditions. Without
;;;; `serve-without-block-returns-while-the-server-is-still-up', a green
;;;; `...-does-not-return-...' would prove only that SERVE takes longer than the timeout.
;;;;
;;;; THE TWO BLOCKING TESTS ARE A PINCER, AND THE TIMINGS ARE THE ARGUMENT -- so they are
;;;; not free to be tuned for speed. Asserting "UNWATCH ended the block" is hard on its own:
;;;; a SERVE that ignored UNWATCH and simply returned on a timer of its own would satisfy
;;;; it, and the test could not tell the two apart. The first draft of this file had exactly
;;;; that hole.
;;;;
;;;; So +BLOCK-HOLDS+ (how long `...-does-not-return-...' waits, having done nothing) is
;;;; deliberately LONGER than the whole elapsed time of `unwatch-...-ends-the-block'. Any
;;;; SERVE that releases itself without being asked must either release inside +BLOCK-HOLDS+
;;;; -- failing the first test -- or not release within +RELEASE-WINDOW+ of the UNWATCH,
;;;; failing the second. There is no timer it can carry that satisfies both. The real
;;;; latency is bounded by the poll interval, which is why the window can be this tight.

(in-package #:hyperion/tests)

(def-suite dev-serve
  :description "SERVE's :BLOCK: that it blocks, that UNWATCH ends it, and that it returns without it."
  :in hyperion)
(in-suite dev-serve)

;;; --- fixtures ---------------------------------------------------------------

(defvar *dev-serve-seq* 0)

(defparameter +block-holds+ 5
  "Seconds `serve-with-block-does-not-return-while-the-watcher-runs' waits, having asked for
nothing. Must stay LONGER than the total elapsed time of the UNWATCH test below -- see the
pincer note in this file's header. Shortening it for suite speed removes the discrimination
and leaves two tests that a self-releasing SERVE would pass.")

(defparameter +release-window+ 2
  "Seconds UNWATCH is given to release the blocked call. Bounded by the watcher's poll
interval (0.2 s here) plus one tree walk, so this is generous rather than tight -- but it
must stay well under +BLOCK-HOLDS+ for the pincer to close.")

(defun %dev-serve-root ()
  "A temp directory holding one .lisp file.

The file is not decoration. WATCH warns when a watched root contains no Lisp (#237), and a
suite that prints warnings on every run teaches its readers to scroll past warnings -- which
is the habit the warning exists to defeat."
  (let ((root (merge-pathnames (format nil "hyperion-dev-serve-~D-~D/"
                                       (sb-unix:unix-getpid) (incf *dev-serve-seq*))
                               (uiop:temporary-directory))))
    (ensure-directories-exist root)
    (with-open-file (out (merge-pathnames "app.lisp" root)
                         :direction :output :if-exists :supersede)
      (write-line ";; a watched source file" out))
    root))

(defun %dev-serve-thread (root port &key block)
  "Run SERVE on a background thread and return the thread.

On a thread even without :BLOCK, so both directions are observed through exactly the same
instrument -- a test that called SERVE directly in one branch and on a thread in the other
would be comparing two measurements, not two behaviours.

The banner goes to a broadcast stream: SERVE prints where it is watching, and that is the
developer's output, not the suite's."
  (sb-thread:make-thread
   (lambda ()
     (let ((*standard-output* (make-broadcast-stream)))
       (hyperion/dev:serve #'%srv-ok-app
                           :paths (list root)
                           :port port
                           :host "127.0.0.1"
                           :interval 0.2
                           :block block)))
   :name "dev-serve-test"))

(defmacro %with-dev-serve ((thread port &key block) &body body)
  "Bind THREAD and PORT around a real SERVE, and always tear it down.

Cleanup is unconditional and deliberately belt-and-braces: UNWATCH stops the watcher and
the server it manages. A suite that leaks a listening socket fails somewhere else, later, for
reasons that look nothing like this file.

CORRECTED (#433): this used to say the JOIN was \"what makes the NEXT test's free port
genuinely free\". It is not, and that claim was the defect rather than a description of it.
The join is on the thread that called SERVE; the socket is held by the backend's acceptor,
which gives it back a moment later. So the port could still be accepting when this returned,
and the next test -- handed that number by `%srv-free-port', which releases what it probes --
would meet the old listener. `%srv-await-released' is the check the claim needed."
  (let ((root (gensym "ROOT")))
    `(let* ((,root (%dev-serve-root))
            (,port (%srv-free-port))
            (,thread (%dev-serve-thread ,root ,port :block ,block)))
       (unwind-protect (progn ,@body)
         (ignore-errors (hyperion/dev:unwatch))
         (ignore-errors (sb-thread:join-thread ,thread :timeout 10 :default nil))
         (is (%srv-await-released ,port)
             "the port was still accepting after teardown -- the next test's free port is not free")
         (ignore-errors (uiop:delete-directory-tree ,root :validate t
                                                          :if-does-not-exist :ignore))))))

(defun %dev-serve-returned-p (thread &key (timeout 5))
  "Did THREAD's SERVE call return within TIMEOUT? T or NIL, never a hang."
  (not (eq :still-running
           (sb-thread:join-thread thread :timeout timeout :default :still-running))))

;;; --- the control ------------------------------------------------------------

(test serve-without-block-returns-while-the-server-is-still-up
  "THE CONTROL FOR EVERY TEST BELOW, and the reported failure stated as an assertion.

SERVE returns, and the server it started is STILL LISTENING when it does -- which is
precisely why a command-line entry point that ends there kills a working server. Both
halves matter: that it returned, and that returning was not the server stopping.

Without this, a green `does-not-return' test below would be satisfied by a SERVE that is
simply slower than the timeout."
  (%with-dev-serve (thread port :block nil)
    (is (%srv-await (lambda () (%srv-listening-p port)))
        "the server never came up, so nothing below is about :BLOCK")
    (is (%dev-serve-returned-p thread)
        "SERVE without :BLOCK must return rather than park the caller")
    (is (%srv-listening-p port)
        "SERVE returned and the server stopped with it -- then :BLOCK is not what the caller needs")))

;;; --- it blocks --------------------------------------------------------------

(test serve-with-block-does-not-return-while-the-watcher-runs
  "The direction the docstring promises: BLOCK parks the calling thread, and KEEPS it parked
for as long as nobody asks otherwise.

The wait is +BLOCK-HOLDS+ rather than something brisk because this is half of the pincer
described in the header: it is what rules out a SERVE that releases itself on a timer and
would otherwise make the UNWATCH test below pass for the wrong reason."
  (%with-dev-serve (thread port :block t)
    (is (%srv-await (lambda () (%srv-listening-p port)))
        "the server never came up")
    (is (not (%dev-serve-returned-p thread :timeout +block-holds+))
        "SERVE :BLOCK T returned on its own while the watcher was still running")
    ;; Still serving while parked -- blocking that wedged the server would satisfy the
    ;; assertion above and be useless.
    (is (%srv-listening-p port)
        "the call blocked but the server is not answering")))

;;; --- and stops blocking -----------------------------------------------------

(test unwatch-from-another-thread-ends-the-block
  "THE DIRECTION THAT MATTERS, and the one the docstring makes a specific claim about:
`UNWATCH from another thread (or the REPL) ends this wait too.'

:BLOCK joins the watcher thread rather than sleeping, so this is the difference between a
parked process that can be stopped and one that can only be killed. UNWATCH is called with
no argument on purpose -- that is the REPL spelling the docstring offers, and it resolves
through *DEV*, so this also asserts SERVE published its handle there."
  (%with-dev-serve (thread port :block t)
    (is (%srv-await (lambda () (%srv-listening-p port))) "the server never came up")
    (is (not (%dev-serve-returned-p thread :timeout 1)) "it was not blocking to begin with")
    (is (hyperion/dev:unwatch) "UNWATCH with no argument found no active watcher in *DEV*")
    (is (%dev-serve-returned-p thread :timeout +release-window+)
        "UNWATCH did not release the blocked SERVE -- the process can now only be killed")))

(test the-unblocked-call-leaves-no-listener-behind
  "SERVE's UNWIND-PROTECT claims that leaving the blocking wait stops the server rather
than leaving an orphan holding the port. Asserted on the ordinary exit, which is the half
reachable without sending a signal: after UNWATCH releases the block, nothing is listening.

The signal case -- a Ctrl-C out of a blocking entry point -- is the same UNWIND-PROTECT and
is NOT covered here; asserting it needs a signal this suite should not raise in-process."
  (%with-dev-serve (thread port :block t)
    (is (%srv-await (lambda () (%srv-listening-p port))) "the server never came up")
    (hyperion/dev:unwatch)
    (is (%dev-serve-returned-p thread :timeout +release-window+)
        "the blocked call never returned")
    (is (%srv-await (lambda () (not (%srv-listening-p port))))
        "the port is still held after the blocking call returned")))
