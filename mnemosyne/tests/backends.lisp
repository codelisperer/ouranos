;;;; tests/backends.lisp --- which backends the suite runs against, and saying so LOUDLY (pre-publication issue 176).
;;;;
;;;; mnemosyne's whole claim is a NEUTRAL protocol over interchangeable backends. Until this
;;;; file, every check it had ever reported green ran against SQLite alone -- the one backend
;;;; the docs do not tell you to deploy on. A neutral protocol verified against one backend is
;;;; an unverified claim, not a verified one.
;;;;
;;;; pre-publication issue 165 is the receipt: 2645 checks green on SQLite at the same commit that silently stored
;;;; the four characters "false" in a Postgres text column. The bug was found by a consuming
;;;; app standing up a real server -- not by the suite, not by review.
;;;;
;;;; THE CONTRACT IS AN ENVIRONMENT VARIABLE, NOT A CONTAINER.
;;;;
;;;;   MNEMOSYNE_TEST_PG_URL=postgres://user:pw@host:port/db?sslmode=disable
;;;;
;;;; Set it and the portability-sensitive suites run against Postgres too. `scripts/test-postgres.sh`
;;;; is ONE way to provide that server and a Postgres you already run is another; nothing here
;;;; depends on Docker, and no container is on the load path of anything.
;;;;
;;;; THREE STATES, DELIBERATELY DISTINGUISHED -- this is the part that matters:
;;;;
;;;;   set + reachable    -> Postgres runs, and its check count is reported.
;;;;   set + UNREACHABLE  -> HARD ERROR. You told us where the server is and it was not there.
;;;;                         Degrading that to a skip is how a CI matrix reports green for a
;;;;                         service container that never came up.
;;;;   unset              -> Postgres is SKIPPED, said so in the output, and reported to
;;;;                         scripts/verify-tree.lisp as a skip rather than as a pass.
;;;;
;;;; The gate is the strict half: verify-tree FAILS on a skip unless OURANOS_ALLOW_NO_PG=1
;;;; excuses it, on the same doctrine as +KNOWN-EMPTY+ -- an exception someone MADE, recorded,
;;;; rather than one that accumulated. The suite itself only reports, so that a developer with
;;;; no server can still run `cons test` and get a useful answer.

(cl:in-package #:mnemosyne/tests)

(in-suite mnemosyne)

(defparameter +pg-url-var+ "MNEMOSYNE_TEST_PG_URL"
  "The environment variable naming a Postgres the suite may create tables in.

Its own variable rather than DATABASE_URL, and not PGHOST/PGUSER either: those name the
database an application uses, and this suite CREATEs and DROPs tables. A developer who
exported DATABASE_URL for their app must never discover that running the tests reshaped it.")

(defvar *backend-checks* '()
  "Alist of (backend-name . assertions-executed), accumulated by IS*.

Counted explicitly rather than read out of fiveam, because fiveam counts globally and the
question this file exists to answer is per-backend. `Did N checks.` summed over both
backends cannot distinguish 40+40 from 80+0, and 80+0 is precisely the failure being
guarded against.")

(defvar *current-backend* nil
  "The name of the backend the enclosing WITH-EACH-BACKEND body is running against.")

(defvar *current-dialect* :sqlite
  "The MNEMOSYNE/QUERY dialect matching *CURRENT-BACKEND*.

Bound by WITH-EACH-BACKEND so a parameterised test never hardcodes `:dialect :sqlite` --
which, in a test whose purpose is to prove portability, would generate SQLite SQL and send
it to Postgres, testing neither backend properly.")

(defun backend-dialect (name)
  "The query dialect for a backend NAME."
  (cond ((string= name "sqlite") :sqlite)
        ((string= name "postgres") :postgres)
        (t (error "no dialect known for backend ~S" name))))

(defvar *pg-skip-reason* nil
  "Why Postgres did not run, or NIL if it did. Reported in the coverage banner.")

(defvar *pg-unreachable* nil
  "The error from probing a CONFIGURED Postgres, or NIL.

Distinct from *PG-SKIP-REASON* because the two are different verdicts and the gate must
tell them apart: not configured is a choice, configured-but-dead is a broken environment.")

(defvar *backends-cache* :unresolved
  "ACTIVE-BACKENDS memoised for the duration of one RUN-TESTS.

Resolved once rather than per test: without this a dead server is probed once per
parameterised test, paying a TCP timeout each time and printing the same paragraph eight
times. RUN-TESTS resets it, so a REPL that starts a server between runs is not stuck with
the previous verdict.")

(defun test-pg-url ()
  "The Postgres URL to test against, or NIL. Blank is treated as unset -- an empty
environment variable is how a CI matrix expresses 'no service here', and reading it as a
URL would produce a confusing parse error instead of an honest skip."
  (let ((v (uiop:getenv +pg-url-var+)))
    (when (and v (plusp (length (string-trim '(#\Space #\Tab) v))))
      (string-trim '(#\Space #\Tab) v))))

(defun %pg-backend ()
  "The Postgres BACKEND from the environment, or NIL when unset.

Built through MNEMOSYNE/URL:BACKEND-FROM-URL rather than MAKE-POSTGRES so that the URL
parser is itself on the path every backend-parameterised test exercises -- it is the way a
deployed application actually names its database, so it is the way the suite should."
  (let ((url (test-pg-url)))
    (when url (mnemosyne/url:backend-from-url url))))

(defun %probe (backend)
  "Connect to BACKEND and immediately disconnect. Returns T, or signals.

Done ONCE up front rather than letting each test discover the server is missing on its own:
a dead server would otherwise surface as a dozen indistinguishable failures in the middle of
the run instead of one sentence at the top saying the server is not there."
  (let ((c (mnemosyne/conn:connect backend)))
    (mnemosyne/conn:disconnect c)
    t))

(defun %resolve-backends ()
  "Work out which backends this run exercises. Called once; see *BACKENDS-CACHE*."
  (let ((out (list (cons "sqlite" (mnemosyne/backend:make-sqlite ":memory:"))))
        (pg (%pg-backend)))
    (setf *pg-skip-reason* nil
          *pg-unreachable* nil)
    (cond
      ((null pg)
       (setf *pg-skip-reason* (format nil "~A is not set" +pg-url-var+)))
      (t
       (handler-case (progn (%probe pg)
                            (setf out (append out (list (cons "postgres" pg)))))
         (error (e)
           ;; Recorded, NOT signalled here. The operator named a server and it did not
           ;; answer: that is a broken environment, and every parameterised test must go
           ;; red for it -- which WITH-EACH-BACKEND does, after running SQLite. That
           ;; ordering is deliberate: a dead Postgres must not also destroy the SQLite
           ;; evidence, so the run distinguishes "we tested one backend" from "we tested
           ;; nothing", and the gate gets a parseable line either way.
           (setf *pg-unreachable* (princ-to-string e))))))
    out))

(defun active-backends ()
  "The backends this run exercises: an alist of (name . backend).

SQLite is always present -- it needs no server and it is the zero-ops local story. Postgres
is present when +PG-URL-VAR+ names a REACHABLE one.

A CONFIGURED but unreachable Postgres is NOT in the returned list -- WITH-EACH-BACKEND
signals for it after running the backends that do work, so the suite goes red AND SQLite
still reports a count. Reporting a dead service container as \"Postgres was not configured\"
is exactly the false green this ticket is about."
  (when (eq *backends-cache* :unresolved)
    (setf *backends-cache* (%resolve-backends)))
  *backends-cache*)

(defun signal-unreachable-backend ()
  "Signal if a CONFIGURED Postgres could not be reached. Called at the END of
WITH-EACH-BACKEND, so the reachable backends have already run and been counted -- a dead
Postgres must not also cost the SQLite evidence."
  (when *pg-unreachable*
    ;; Folded onto one line rather than split with `~<newline>`: that continuation becomes
    ;; an illegal `~<Return>` on a CRLF checkout (CLAUDE.md).
    (error "~A is set to ~S but that server could not be reached: ~A~%Start one (scripts/test-postgres.sh up), fix the URL, or unset the variable to skip Postgres explicitly."
           +pg-url-var+ (test-pg-url) *pg-unreachable*)))

(defmacro is* (form &rest reason)
  "IS, plus a per-backend tally.

Every assertion inside WITH-EACH-BACKEND must use this rather than IS, or the coverage
banner under-reports and the gate's whole premise -- that a per-backend count is evidence --
stops holding."
  `(progn
     (let ((cell (assoc *current-backend* *backend-checks* :test #'equal)))
       (if cell
           (incf (cdr cell))
           (push (cons *current-backend* 1) *backend-checks*)))
     (is ,form ,@reason)))

(defmacro with-each-backend ((conn-var) &body body)
  "Run BODY once per active backend, with CONN-VAR bound to a fresh connection each time.

The connection is per-backend and per-test: SQLite's is `:memory:`, which is empty at every
connect, and Postgres' is a real server that is NOT, so BODY must create what it needs. The
%FRESH-TABLE helper drops first for exactly that reason.

A failure names the backend it happened on. Without that, a red run on a two-backend matrix
tells you a thing is broken but not where, which is half of a bug report."
  (let ((entry (gensym "ENTRY")) (name (gensym "NAME")) (backend (gensym "BACKEND")))
    ;; ONE backquoted form. The dolist and the unreachable check must both be inside the
    ;; expansion: written as two top-level forms in the macro body, the second becomes the
    ;; macro's return value and the loop is discarded -- which expanded to NIL and made
    ;; every parameterised test pass having asserted nothing. A vacuous green, in the file
    ;; whose entire purpose is to stop vacuous greens.
    `(progn
       (dolist (,entry (active-backends))
         (let* ((,name (car ,entry))
                (,backend (cdr ,entry))
                (*current-backend* ,name)
                (*current-dialect* (backend-dialect ,name))
                (,conn-var (mnemosyne/conn:connect ,backend)))
           (unwind-protect
                (handler-bind
                    ((error (lambda (e)
                              (format *error-output*
                                      "~&    [backend ~A] error: ~A~%" ,name e))))
                  ,@body)
             (mnemosyne/conn:disconnect ,conn-var))))
       ;; AFTER the working backends, never instead of them.
       (signal-unreachable-backend))))

;;; --- the coverage banner ---------------------------------------------------
;;;
;;; Machine-readable on purpose. scripts/verify-tree.lisp parses these lines, because the
;;; thing it must be able to conclude -- "Postgres executed a non-zero number of checks" --
;;; is not visible anywhere in fiveam's own output.

(defun report-backend-coverage (stream)
  "Print one BACKEND-CHECKS line per backend, plus a skip line if Postgres did not run."
  (format stream "~&~%========== BACKEND COVERAGE ==========~%")
  (dolist (cell (sort (copy-list *backend-checks*) #'string< :key #'car))
    (format stream "BACKEND-CHECKS ~A ~D~%" (car cell) (cdr cell)))
  (when *pg-unreachable*
    (format stream "BACKEND-CHECKS postgres UNREACHABLE (~A)~%" *pg-unreachable*)
    (format stream "  ~A named a server that did not answer. This is a broken~%" +pg-url-var+)
    (format stream "  environment, not an absent one -- the suite is RED, not skipped.~%"))
  (when *pg-skip-reason*
    (format stream "BACKEND-CHECKS postgres SKIPPED (~A)~%" *pg-skip-reason*)
    (format stream "  Postgres was NOT exercised. This run says nothing about the backend~%")
    (format stream "  the docs tell you to deploy on. Set ~A to change that.~%"
            +pg-url-var+))
  ;; Which SQLite file the SQLite checks above ran against, and its version (#129). Printed
  ;; on every run, including when it is the expected one: on Windows another program's
  ;; sqlite3.dll once carried these checks for months, and nothing in the output said so.
  ;; scripts/verify-tree.lisp repeats this line under the suite's result.
  (format stream "SQLITE-LIBRARY ~A~%" (mnemosyne/sqlite-library:describe-loaded-library))
  (finish-output stream))

;;; --- the runner ------------------------------------------------------------

(defun run-tests ()
  "Run the whole Mnemosyne suite; return T on success (for `asdf:test-system`).

Logging is turned down to :warn first so the per-query :debug lines do not bury CI output.

Defined HERE rather than beside the suite definition because it must print the per-backend
coverage banner, and a forward reference to that from tests/query.lisp would be an undefined
function at compile time -- a style-warning the tree would rightly rather not carry."
  (aion/log:level! :warn)
  (setf *backend-checks* '()
        *pg-skip-reason* nil
        *pg-unreachable* nil
        *backends-cache* :unresolved)
  (let ((ok (run! 'mnemosyne)))
    (report-backend-coverage *standard-output*)
    ok))
