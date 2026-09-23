;;;; env-tests.lisp --- cons/env .env parsing (relocated from praxeon/config).

(in-package #:cons/tests)
(in-suite all)

(test dotenv-strips-inline-comments
  "cons/env drops a trailing `# ...` on an unquoted value, but keeps a # that is
quoted or mid-token."
  (flet ((val (line) (nth-value 1 (cons/env::%parse-line line))))
    (is (string= "anthropic" (val "APP_IMPL=anthropic # openrouter")))
    (is (string= "api-key"   (val "APP_AUTH=api-key")))
    (is (string= "a#b"       (val "K=\"a#b\"")))          ; quoted # kept
    (is (string= "ab#cd"     (val "K=ab#cd")))            ; mid-token # kept
    (is (string= "http://localhost:11434/v1"
                 (val "APP_BASE_URL=http://localhost:11434/v1 # ollama")))))

(test dotenv-tolerates-export-and-quotes
  "An `export ` prefix is tolerated, surrounding quotes are stripped, and
blank/comment lines yield no key."
  (labels ((k (line) (nth-value 0 (cons/env::%parse-line line))))
    (is (string= "K" (k "export K=v")))
    (is (string= "K" (k "K='v'")))
    (is (string= "K" (k "K=\"v\"")))
    (is (null (k "# a comment")))
    (is (null (k "   ")))))

;;; --- LOAD-PROJECT-ENV: the entry-point form (pre-publication issue 120) -------------------------
;;;
;;; The bug this closes was an ORDERING bug, not a parsing one. A consuming app called
;;; `load-dotenv` while building its web handler -- but its start path opened the database
;;; and ran a seed that sent mail BEFORE the handler was constructed, so that work ran
;;; against a bare environment. One symptom was loud and accused the wrong component (a
;;; provider raised "missing required configuration: <KEY>" for a key sitting in .env); one
;;; was silent (a database path fell back to its default and a stray database appeared in
;;; the wrong directory).
;;;
;;; So what is tested here is what makes the correct call POSSIBLE TO WRITE without
;;; thinking: resolution against the app's own system rather than the current directory,
;;; and idempotence, so `main` can call it unconditionally.

(defun %write-env-file (dir contents)
  (let ((path (merge-pathnames ".env" dir)))
    (ensure-directories-exist path)
    (with-open-file (o path :direction :output :if-exists :supersede)
      (write-string contents o))
    path))

(defvar *fake-system-counter* 0
  "Distinguishes temp directories created inside the same second.")

(defmacro with-fake-system ((system-var dir-var) &body body)
  "A throwaway ASDF system object rooted at a temp directory, so LOAD-PROJECT-ENV's
system-relative resolution is exercised the way a real app uses it.

The system is never REGISTERED -- an ASDF system object is itself a valid designator, so
passing the instance exercises the same path a name would without leaving anything behind
in the registry for the next test to trip over."
  (let ((counter (gensym)))
    `(let* ((,counter (incf *fake-system-counter*))
            (,dir-var (merge-pathnames (format nil "cons-env-test-~D-~D/"
                                               (get-universal-time) ,counter)
                                       (uiop:temporary-directory)))
            (,system-var (make-instance 'asdf:system
                                        :name "cons-env-test-app"
                                        :source-file (merge-pathnames "cons-env-test-app.asd"
                                                                      ,dir-var))))
       (declare (ignorable ,dir-var))
       (ensure-directories-exist ,dir-var)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree ,dir-var :validate t))))))

(test load-project-env-resolves-against-the-system-not-the-current-directory
  ;; The property that makes it correct for a BUILT BINARY, which is normally run from a
  ;; directory with nothing to do with the source tree.
  (if (not (env-writable-p))
      (skip "this build cannot mutate the C environment that uiop:getenv reads")
      (with-fake-system (sys dir)
        (%write-env-file dir "CONS_TEST_ORDERING=from-dotenv")
        (unset-env "CONS_TEST_ORDERING")
        (let ((cons/env:*loaded-from* '()))
          ;; run from somewhere else entirely -- the current directory must not matter
          (let ((*default-pathname-defaults* (uiop:temporary-directory)))
            (multiple-value-bind (keys path) (cons/env:load-project-env sys)
              (is (member "CONS_TEST_ORDERING" keys :test #'string=))
              (is (equal (probe-file (merge-pathnames ".env" dir)) path))))
          (is (string= "from-dotenv" (uiop:getenv "CONS_TEST_ORDERING"))))
        (unset-env "CONS_TEST_ORDERING"))))

(test load-project-env-is-idempotent-so-main-can-call-it-unconditionally
  ;; `main` must not have to know whether a REPL session, a test fixture or `cons run`
  ;; already loaded the file. A second call is a no-op that still reports the path.
  (if (not (env-writable-p))
      (skip "this build cannot mutate the C environment that uiop:getenv reads")
      (with-fake-system (sys dir)
        (%write-env-file dir "CONS_TEST_ONCE=first")
        (unset-env "CONS_TEST_ONCE")
        (let ((cons/env:*loaded-from* '()))
          (is (member "CONS_TEST_ONCE" (cons/env:load-project-env sys) :test #'string=))
          ;; second call applies nothing ...
          (multiple-value-bind (keys path) (cons/env:load-project-env sys)
            (is (null keys) "a repeat load must apply nothing")
            (is (not (null path)) "but must still say which file it would have read"))
          ;; ... and the record names what was read, which is otherwise a guess
          (is (= 1 (length cons/env:*loaded-from*))))
        (unset-env "CONS_TEST_ONCE"))))

(test the-host-environment-still-wins-over-the-file
  ;; Production sets real variables and ships no .env; a scaffolded entry point calling
  ;; this unconditionally must not clobber them.
  (if (not (env-writable-p))
      (skip "this build cannot mutate the C environment that uiop:getenv reads")
      (with-fake-system (sys dir)
        (%write-env-file dir "CONS_TEST_WINS=from-dotenv")
        (set-env "CONS_TEST_WINS" "from-host")
        (let ((cons/env:*loaded-from* '()))
          (cons/env:load-project-env sys)
          (is (string= "from-host" (uiop:getenv "CONS_TEST_WINS"))))
        ;; ... unless asked
        (let ((cons/env:*loaded-from* '()))
          (cons/env:load-project-env sys :override t)
          (is (string= "from-dotenv" (uiop:getenv "CONS_TEST_WINS"))))
        (unset-env "CONS_TEST_WINS"))))

(test a-missing-dotenv-is-normal-and-not-an-error
  ;; Production ships no .env at all. An entry point that calls this unconditionally must
  ;; survive that without a condition.
  (with-fake-system (sys dir)
    (let ((cons/env:*loaded-from* '()))
      (multiple-value-bind (keys path) (cons/env:load-project-env sys)
        (is (null keys))
        (is (null path))))))

(test dotenv-path-names-the-file-beside-the-systems-asd
  ;; Compared as NAMESTRINGS, not with EQUAL. ASDF parses ".env" through
  ;; UIOP:PARSE-UNIX-NAMESTRING, which yields type :UNSPECIFIC where CL's MERGE-PATHNAMES
  ;; yields type NIL -- the same file, two pathname objects that print identically and are
  ;; not EQUAL. Asserting on the object would be asserting on ASDF's internals.
  (with-fake-system (sys dir)
    (is (string= (namestring (merge-pathnames ".env" dir))
                 (namestring (cons/env:dotenv-path sys))))
    (is (string= (namestring (merge-pathnames ".env.local" dir))
                 (namestring (cons/env:dotenv-path sys :name ".env.local"))))))
