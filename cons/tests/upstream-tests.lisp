;;;; upstream-tests.lisp --- is the framework checkout behind? (pre-publication issue 240)
;;;;
;;;; The advisory's whole value is that it distinguishes three states the suggested
;;;; one-liner collapses into one number, so the matrix is what is tested -- and the
;;;; middle row is the reason this module exists rather than a `git rev-list --count`.

(in-package #:cons/tests)

;; :IN ALL is not decoration. Without it RUN-TESTS never reaches this suite: the file
;; compiles, the tests exist, and the run reports success having executed none of them --
;; the exact non-evidence AGENTS.md opens with. It was missing on the first pass here, and
;; what caught it was the check COUNT not moving, not the exit status.
(def-suite upstream :description "Framework-checkout drift advisory (pre-publication issue 240)." :in all)
(in-suite upstream)

;;; --- the matrix, pure -------------------------------------------------------

(test behind-says-how-far-and-which-packages
  (let ((lines (cons/upstream:drift-lines :behind 22 :fetch-age 60
                                          :packages '("hyperion" "mnemosyne"))))
    (is-true lines)
    (let ((text (format nil "~{~A~%~}" lines)))
      (is (search "22 commits behind" text))
      (is (search "hyperion" text) "a bare count is less actionable than a name: ~S" text)
      (is (search "mnemosyne" text)))))

(test one-commit-behind-is-not-pluralised-wrongly
  (is (search "1 commit behind"
              (format nil "~{~A~%~}" (cons/upstream:drift-lines :behind 1 :fetch-age 60)))))

(test never-fetched-does-not-report-up-to-date
  ;; THE correction to pre-publication issue 240's suggested fix. `git rev-list --count HEAD..@{u}' compares
  ;; against the last fetch, so a consumer who never fetches -- precisely the consumer this
  ;; exists for -- is told 0. Measured on a real pair of repositories: the check said
  ;; "0 commits behind" while the consumer was 3 behind, with no FETCH_HEAD at all.
  (let ((lines (cons/upstream:drift-lines :behind 0 :fetch-age nil)))
    (is-true lines "a checkout that has never fetched must not pass silently")
    (is (search "never been fetched" (format nil "~{~A~%~}" lines)))))

(test a-stale-fetch-is-reported-as-stale
  (let ((lines (cons/upstream:drift-lines
                :behind 0 :fetch-age (* 9 24 60 60))))
    (is-true lines)
    (is (search "9 days ago" (format nil "~{~A~%~}" lines)))))

(test a-current-checkout-says-nothing
  ;; Silence has to be EARNED, or the advisory becomes noise that gets tuned out -- which
  ;; is how the capability in pre-publication issue 207 went unnoticed in the first place.
  (is (null (cons/upstream:drift-lines :behind 0 :fetch-age 60))))

(test the-boundary-between-fresh-and-stale-is-the-documented-one
  (is (null (cons/upstream:drift-lines
             :behind 0 :fetch-age (1- cons/upstream:*stale-fetch-seconds*))))
  (is-true (cons/upstream:drift-lines
            :behind 0 :fetch-age (1+ cons/upstream:*stale-fetch-seconds*))))

(test packages-touched-names-frameworks-in-dag-order-without-duplicates
  (is (equal '("aion" "hyperion")
             (cons/upstream:packages-touched
              '("hyperion/src/session.lisp" "aion/src/log/log.lisp"
                "hyperion/tests/x.lisp"))))
  ;; Paths that are not a framework must not invent one.
  (is (null (cons/upstream:packages-touched '("docs/x.md" "README.md" ".github/w.yml")))))

;;; --- against real repositories ----------------------------------------------

(defun %git! (args &key dir)
  "Run git (optionally -C DIR) and SIGNAL on a non-zero exit.

A fixture whose setup fails silently does not produce a failing test -- it produces a WRONG
one. That is exactly what pre-publication issue 284 was: a `git clone' into a leftover directory exits 128, the
old fixture passed :ignore-error-status t, and the test then ran against the PREVIOUS run's
consumer, which had already fetched. The assertion demanding \"never fetched\" saw a real
distance and reported a defect in code that was fine. Measured: exit 128, and the advisory
came back \"3 commits behind\" where the test required \"never been fetched\".

So every git invocation in this fixture is checked. If the setup cannot be built, the test
errors saying which command failed, rather than quietly measuring something else."
  (multiple-value-bind (out err code)
      (uiop:run-program (append (list "git")
                                (when dir (list "-C" (uiop:native-namestring dir)))
                                args)
                        :output '(:string :stripped t)
                        :error-output '(:string :stripped t)
                        :ignore-error-status t)
    (declare (ignore out))
    (unless (zerop code)
      (error "fixture: `git ~{~A~^ ~}~@[ (in ~A)~]' exited ~D~@[: ~A~]"
             args (and dir (uiop:native-namestring dir)) code
             (and (plusp (length err)) err)))
    t))

(defun %fresh-temp-dir (prefix)
  "A temp directory that DID NOT EXIST a moment ago, claimed rather than hoped for.

`(random n)' in a fresh SBCL image is DETERMINISTIC -- three separate images return the
same 113500 -- and verify-tree gives every suite a fresh image, so a path built from it is
not unique, it is a constant that collides with the previous run. On POSIX the cleanup
below hides that; on Windows `delete-directory-tree' raises on git's read-only object store
and the corpse persists, so the suite passes once per machine and fails forever after (pre-publication issue 284).

Two defences, because entropy alone was what failed: the name is seeded from a random state
built at RUNTIME (`make-random-state t'), and the directory is only used if it did not
already exist. Cleanup is therefore best-effort rather than load-bearing -- a leftover from
a crashed run can no longer poison the next one."
  (loop repeat 100
        for name = (format nil "~A-~D-~D/" prefix (get-universal-time)
                           (random 1000000 (make-random-state t)))
        for path = (merge-pathnames name (uiop:temporary-directory))
        unless (probe-file path)
          do (ensure-directories-exist path)
             (return path)
        finally (error "fixture: could not claim a fresh temp directory under ~A"
                       (uiop:temporary-directory))))

(defun %drift-scenario ()
  "Build the reported incident from scratch and assert the advisory on it: the framework
moves, the consumer never fetches, and nothing tells it.

A FUNCTION rather than a test body so it can be run TWICE IN ONE IMAGE -- which is the
control pre-publication issue 284 asked for and the one the old fixture could not express. A test that only ever
runs once per image cannot detect that it poisons the next run."
  (let* ((root (%fresh-temp-dir "cons-drift"))
         (up (merge-pathnames "upstream.git/" root))
         (author (merge-pathnames "author/" root))
         (consumer (merge-pathnames "consumer/" root)))
    (unwind-protect
         (progn
           ;; --initial-branch=main is NOT optional. Without it the bare repo's HEAD comes
           ;; from init.defaultBranch -- `main' on a Mac with Xcode installed (its bundled
           ;; gitconfig sets it) and UNSET on a CI runner, where git still defaults to
           ;; `master'. The push below targets refs/heads/main explicitly, so on a runner
           ;; HEAD pointed at a branch that never existed, the consumer's clone had no
           ;; upstream, and the assertions had nothing to match. Identity is pinned below
           ;; for the same reason: a runner has none.
           (%git! (list "init" "-q" "--bare" "--initial-branch=main"
                        (uiop:native-namestring up)))
           (%git! (list "clone" "-q" (uiop:native-namestring up)
                        (uiop:native-namestring author)))
           (%git! '("config" "user.email" "a@b.c") :dir author)
           (%git! '("config" "user.name" "A") :dir author)
           (with-open-file (s (merge-pathnames "hyperion" author) :direction :output
                                                                  :if-exists :supersede)
             (write-string "v1" s))
           (%git! '("add" "-A") :dir author)
           (%git! '("commit" "-qm" "v1") :dir author)
           (%git! '("push" "-q" "origin" "HEAD:refs/heads/main") :dir author)
           (%git! (list "clone" "-q" (uiop:native-namestring up)
                        (uiop:native-namestring consumer)))
           ;; The framework moves on; the consumer does not fetch.
           (dotimes (i 3)
             (with-open-file (s (merge-pathnames "hyperion" author) :direction :output
                                                                    :if-exists :supersede)
               (format s "v~D" (+ 2 i)))
             (%git! (list "commit" "-qam" (format nil "v~D" (+ 2 i))) :dir author))
           (%git! '("push" "-q") :dir author)

           (let ((text (format nil "~{~A~%~}" (cons/upstream:checkout-advisory consumer))))
             (is (plusp (length text))
                 "a consumer three commits behind, having never fetched, was told nothing")
             (is (search "never been fetched" text)
                 "it must not claim currency it cannot check; got: ~S" text))

           ;; ...and once it HAS fetched, the count becomes real and names the package.
           (%git! '("fetch" "-q") :dir consumer)
           (let ((text (format nil "~{~A~%~}" (cons/upstream:checkout-advisory consumer))))
             (is (search "3 commits behind" text) "after fetching, got: ~S" text)
             (is (search "hyperion" text) "and it should name what moved: ~S" text)))
      ;; Best-effort, and deliberately NOT load-bearing: the path above is fresh per run, so
      ;; a leftover cannot poison the next one. On Windows this raises on git's read-only
      ;; object store, which is how pre-publication issue 284 survived -- the error was swallowed and the corpse
      ;; persisted. Swallowing it is fine now; relying on it was not.
      (ignore-errors (uiop:delete-directory-tree root :validate t)))))

(test a-consumer-that-never-fetched-is-told-so-and-then-told-how-far-behind
  (%drift-scenario))

(test the-scenario-does-not-poison-its-own-next-run
  ;; THE CONTROL pre-publication issue 284 ASKED FOR, and the one the old fixture structurally could not run.
  ;; pre-publication issue 284 was not a Windows bug: the temp path came from `(random)', which is deterministic
  ;; in a fresh image, so every run used the same directory. POSIX cleanup hid it; Windows
  ;; cleanup failed silently and the second run measured the FIRST run's consumer -- which
  ;; had already fetched -- and reported a defect in working code.
  ;;
  ;; Running the scenario twice in one image is what makes that impossible to reintroduce:
  ;; a fixture that collides with itself fails here, on every platform, immediately.
  (%drift-scenario)
  (%drift-scenario))

(test a-directory-that-is-not-a-repository-is-silent-not-an-error
  ;; Fail-open is a requirement, not a nicety: this runs before every target, and a
  ;; consumer building from a tarball must not have their build interrupted by it.
  (let ((dir (uiop:temporary-directory)))
    (is (null (cons/upstream:checkout-advisory dir))
        "a non-repository must produce silence")))
