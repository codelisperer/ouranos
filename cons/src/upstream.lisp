;;;; upstream.lisp --- is the framework checkout you are building against current? (pre-publication issue 240)
;;;;
;;;; A capability shipped and two consuming applications went on hand-rolling around it for
;;;; three days, because nothing told them their framework checkout was behind. Both had
;;;; assembled the same four-call session rotation before HYPERION/SESSION:ROTATE-SESSION
;;;; existed; it existed by the time they were still maintaining the workaround. Session
;;;; fixation defence is a security control, so two apps maintaining a hand-rolled version
;;;; of one the framework now provides correctly is the bad outcome, not a wasted afternoon.
;;;;
;;;; This is TOOLING, not discipline. A consuming app has no reason to fetch a tree it did
;;;; not change and is not working in, and the tree is often shared with another session
;;;; mid-task, so pulling it is not always the consumer's call. What the consumer needs is
;;;; not "pull this" -- it is "what you are building against is N commits old".
;;;;
;;;; WHY THIS IS NOT THE ONE-LINER THE ISSUE SUGGESTED. `git rev-list --count HEAD..@{u}'
;;;; compares against the LOCAL copy of the remote ref, which only moves on fetch. A
;;;; consumer who never fetches -- exactly the consumer this exists for -- gets:
;;;;
;;;;     consumer HEAD:        db8ee5c
;;;;     suggested check says: 0 commits behind
;;;;     reality:              3 commits behind
;;;;     last fetch:           NEVER FETCHED -- no FETCH_HEAD
;;;;
;;;; So the literal one-liner would have reported "up to date" in the very situation it was
;;;; filed to prevent. A count that cannot distinguish CURRENT from NEVER ASKED is the same
;;;; class of non-evidence as a suite that runs no checks: the number is real, and it is an
;;;; answer to a different question.
;;;;
;;;; Hence: report the count AND the age of the comparison, and say so plainly when the
;;;; comparison is too old to mean anything. Never a gate -- a consumer may be pinned for
;;;; perfectly good reasons, and this must not fail a build or touch the network.

(in-package #:cons/upstream)

(defparameter *stale-fetch-seconds* (* 24 60 60)
  "Older than this, a fetch is not evidence of anything and the advisory says so.")

(defparameter *framework-directories*
  '("aion" "cons" "mnemosyne" "elenchon" "hyperion" "praxeon" "hermes")
  "Top-level directories that name a framework, so the advisory can say WHICH one moved --
\"hyperion is 22 commits behind\" being considerably more actionable than a bare count.")

;;; --- the pure half --------------------------------------------------------

(defun drift-lines (&key behind fetch-age packages)
  "The advisory for a checkout that is BEHIND commits, whose last fetch was FETCH-AGE
seconds ago (NIL = never), touching PACKAGES. Returns a list of lines, or NIL when there
is nothing worth saying.

Pure, and separate from the git calls for the usual reason: the interesting behaviour is a
small matrix of cases and testing it should not mean constructing repositories.

The matrix, and the middle row is the point:

  behind > 0                     say how far behind, and which packages moved
  behind = 0, fetch stale/never  say the comparison is too old to be meaningful
  behind = 0, fetch recent       say nothing -- silence here is earned"
  (cond
    ((and behind (plusp behind))
     (list (format nil "framework checkout is ~D commit~:P behind its remote~@[ (~{~A~^, ~})~]"
                   behind packages)
           (format nil "  it may already have what you are about to hand-roll; `git -C <framework> pull` to catch up")))
    ((null fetch-age)
     (list "framework checkout has never been fetched, so \"up to date\" cannot be checked"
           "  `git -C <framework> fetch` to find out where it actually stands"))
    ((> fetch-age *stale-fetch-seconds*)
     (list (format nil "framework checkout last fetched ~D day~:P ago, so \"up to date\" reflects that moment, not now"
                   (floor fetch-age 86400))
           "  `git -C <framework> fetch` before trusting it"))
    (t nil)))

(defun packages-touched (paths)
  "Which frameworks the changed PATHS belong to, in DAG order and without duplicates."
  (let ((seen '()))
    (dolist (p paths)
      (let* ((slash (position #\/ p))
             (top (if slash (subseq p 0 slash) p)))
        (when (and (member top *framework-directories* :test #'string=)
                   (not (member top seen :test #'string=)))
          (push top seen))))
    (sort (nreverse seen)
          (lambda (a b) (< (or (position a *framework-directories* :test #'string=) 99)
                           (or (position b *framework-directories* :test #'string=) 99))))))

;;; --- the IO half ----------------------------------------------------------

(defun %git (dir &rest args)
  "Run git in DIR, returning trimmed stdout, or NIL on any failure.

Fail-open throughout: this is advisory. A checkout with no remote, a detached HEAD, no git
on PATH, or a directory that is not a repository at all must produce silence, never an
error and never a delay in somebody's build."
  (handler-case
      (multiple-value-bind (out err code)
          (uiop:run-program (append (list "git" "-C" (uiop:native-namestring dir)) args)
                            :output '(:string :stripped t)
                            :error-output nil
                            :ignore-error-status t)
        (declare (ignore err))
        (when (and (zerop code) (plusp (length out))) out))
    (error () nil)))

(defun %fetch-age (dir)
  "Seconds since this repository last fetched, or NIL if it never has.

BOTH candidate locations are checked, and the worktree case is why. `git rev-parse
--git-path FETCH_HEAD' returns the PER-WORKTREE path --
.git/worktrees/<name>/FETCH_HEAD -- which does not exist, because fetch writes FETCH_HEAD
into the COMMON dir shared by every worktree. Asking only the obvious one reports \"never
fetched\" for every worktree in this repo, which is where all the lane work happens. (I
had written the opposite in this docstring before measuring it.)"
  (let ((stamps
          (loop for path in (list (%git dir "rev-parse" "--git-path" "FETCH_HEAD")
                                  (let ((common (%git dir "rev-parse" "--git-common-dir")))
                                    (when common
                                      (uiop:native-namestring
                                       (merge-pathnames "FETCH_HEAD"
                                                        (uiop:ensure-directory-pathname common))))))
                when path
                  append (let* ((abs (if (uiop:absolute-pathname-p (pathname path))
                                         (pathname path)
                                         (merge-pathnames
                                          path (uiop:ensure-directory-pathname dir))))
                                (stamp (ignore-errors (file-write-date abs))))
                           (when stamp (list stamp))))))
    (when stamps (max 0 (- (get-universal-time) (reduce #'max stamps))))))

(defun framework-directory ()
  "The framework checkout cons itself was loaded from -- which is the tree a consuming app
is building against, since it is running this copy of cons."
  (ignore-errors (asdf:system-source-directory "cons")))

(defun %comparable-p (dir)
  "Is DIR a work tree WITH an upstream to compare against?

Both halves are load-bearing, and the first was found by a test rather than by reading.
Without the work-tree check a plain directory produces the never-fetched advisory, because
\"not a repository\" and \"a repository that has never fetched\" both look like an absent
FETCH_HEAD -- so a consumer building from a tarball would be told to fetch something that
does not exist. Without the upstream check, a detached or remoteless checkout gets the same
false advice for the same reason: there is nothing it could be behind."
  (and (%git dir "rev-parse" "--is-inside-work-tree")
       (%git dir "rev-parse" "--abbrev-ref" "--symbolic-full-name" "@{u}")
       t))

(defun checkout-advisory (&optional (dir (framework-directory)))
  "The advisory lines for DIR, or NIL when there is nothing to say."
  (when (and dir (%comparable-p dir))
    (let ((behind (let ((n (%git dir "rev-list" "--count" "HEAD..@{u}")))
                    (and n (ignore-errors (parse-integer n))))))
      (drift-lines :behind behind
                   :fetch-age (%fetch-age dir)
                   :packages (when (and behind (plusp behind))
                               (packages-touched
                                (let ((out (%git dir "diff" "--name-only" "HEAD..@{u}")))
                                  (when out
                                    (uiop:split-string out :separator '(#\Newline))))))))))

(defun report (&optional (stream *error-output*))
  "Print the advisory, if any, to STREAM. Never signals, never gates, never fetches."
  (handler-case
      (let ((lines (checkout-advisory)))
        (when lines
          (format stream "~&~{[cons] ~A~%~}" lines)
          (finish-output stream)))
    (error () nil))
  (values))
