;;;; tempdir-tests.lisp --- scratch directories are created, not chosen (#204).
;;;;
;;;; The interesting test here is not "does it make a directory". It is the SYMLINK case,
;;;; because that is the defect: the old idiom handed a guessable name to
;;;; ENSURE-DIRECTORIES-EXIST, which succeeds on a path that already exists and, on Unix,
;;;; follows a symlink to it. A test that only checked the happy path would have passed
;;;; against the broken version, which is the same shape as the smuggling test in
;;;; hyperion/server-uv that passed against a broken drain until it asserted the right field.

(in-package #:cons/tests)
(in-suite all)

(test a-temporary-directory-exists-and-is-ours
  (let ((dir (tempdir:make-temporary-directory "unit")))
    (unwind-protect
         (progn
           (is-true (uiop:directory-exists-p dir) "it must exist when the call returns")
           (is (search "cons-unit-" (namestring dir)) "the tag names it, for a human reading /tmp"))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(test two-temporary-directories-are-not-the-same-one
  ;; Not a randomness assertion -- a collision assertion. *NAME-STATE* is seeded per image
  ;; precisely because CL:*RANDOM-STATE* is not, so the old code produced the same suffix
  ;; sequence in every run and two concurrent `cons' processes collided constantly.
  (let ((a (tempdir:make-temporary-directory "unit"))
        (b (tempdir:make-temporary-directory "unit")))
    (unwind-protect
         (is (not (equal (namestring a) (namestring b))))
      (uiop:delete-directory-tree a :validate t :if-does-not-exist :ignore)
      (uiop:delete-directory-tree b :validate t :if-does-not-exist :ignore))))

(test with-temporary-directory-removes-the-tree
  (let ((seen nil))
    (tempdir:with-temporary-directory (dir "unit")
      (setf seen dir)
      (ensure-directories-exist (merge-pathnames "a/b/" dir))
      (with-open-file (out (merge-pathnames "a/b/f" dir) :direction :output)
        (write-string "x" out)))
    (is-false (uiop:directory-exists-p seen) "a non-empty tree must go too")))

(test with-temporary-directory-keeps-it-when-asked
  (let ((seen nil))
    (unwind-protect
         (progn
           (tempdir:with-temporary-directory (dir "unit" :keep t)
             (setf seen dir))
           (is-true (uiop:directory-exists-p seen)
                    ":keep is what you want the moment something failed inside it"))
      (when seen
        (uiop:delete-directory-tree seen :validate t :if-does-not-exist :ignore)))))

(test running-out-of-names-is-an-error-not-a-hang
  (let ((tempdir:*attempts* 0))
    (signals tempdir:temporary-directory-error (tempdir:make-temporary-directory "unit"))))

;;; --- the guard itself ------------------------------------------------------

(test an-occupied-name-is-refused-rather-than-adopted
  (tempdir:with-temporary-directory (scratch "unit")
    (let ((taken (merge-pathnames "taken/" scratch)))
      (ensure-directories-exist taken)
      (is-false (cons/tempdir::%create-exclusively taken)
                "an existing directory means NIL -- try another name, never adopt this one")
      (is-true (cons/tempdir::%create-exclusively (merge-pathnames "free/" scratch))
               "and the control: a free name is created"))))

#+unix
(test a-pre-placed-symlink-is-refused-not-followed
  "THE ATTACK, run. In a world-writable /tmp an attacker who can guess the name creates it
first as a link to somewhere they would like written to. ENSURE-DIRECTORIES-EXIST follows
it and reports success; MKDIR fails with EEXIST, because it does not resolve the final
component. This is the whole reason #204 is not fixed by a better random number."
  (tempdir:with-temporary-directory (scratch "unit")
    (let ((elsewhere (merge-pathnames "elsewhere/" scratch))
          (bait (merge-pathnames "bait" scratch)))
      (ensure-directories-exist elsewhere)
      (sb-posix:symlink (uiop:native-namestring elsewhere) (uiop:native-namestring bait))
      (is-false (cons/tempdir::%create-exclusively (uiop:ensure-directory-pathname bait))
                "mkdir onto a symlink must FAIL, not quietly succeed through it")
      ;; The half that makes the assertion mean something: the old idiom really would have
      ;; followed it. If this ever stops being true the test above is no longer a guard.
      (is-true (nth-value 0 (ensure-directories-exist
                             (uiop:ensure-directory-pathname bait)))
               "control: ENSURE-DIRECTORIES-EXIST does follow the link -- which is the bug")
      (is-false (uiop:directory-exists-p (merge-pathnames "bait-real/" scratch))
                "nothing was created beside the link"))))

#-unix
(test a-pre-placed-symlink-is-refused-not-followed
  (skip "symlink pre-placement is a shared-/tmp attack; %TEMP% on Windows is per-user"))

#+unix
(test a-scratch-directory-is-private
  "0700. Even a correctly created directory in a shared /tmp should not be readable by other
users while a project is generated inside it."
  (tempdir:with-temporary-directory (dir "unit")
    (is (= #o700 (logand #o777 (sb-posix:stat-mode
                                (sb-posix:stat (uiop:native-namestring dir))))))))

#+unix
(test a-real-failure-is-not-swallowed-as-a-collision
  "ENOENT is not EEXIST. Retrying 32 times on a full or missing temp directory would turn
one clear failure into a slow, confusing one -- so anything that is not `already there' is
re-signalled."
  (signals sb-posix:syscall-error
    (cons/tempdir::%create-exclusively #p"/nonexistent-parent-204/child/")))
