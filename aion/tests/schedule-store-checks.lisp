;;;; schedule-store-checks.lisp --- the job store protocol's contract, as checks (#689).
;;;;
;;;; CHECK-STORE runs every check here against stores made by a constructor it is given. The
;;;; in-memory store's suite calls it, and so does mnemosyne/jobs/tests, against SQLite and
;;;; Postgres, so the database store is held to the same contract as the in-memory one rather
;;;; than to a copy of it. Call it inside a fiveam TEST.

(cl:defpackage #:aion/schedule/store-checks
  (:use #:cl #:fiveam)
  (:local-nicknames (#:s #:aion/schedule))
  (:export #:check-store))

(in-package #:aion/schedule/store-checks)

(defparameter +t0+ 3990000000)

(defun %job (key &key (schedule '(:every 60)) (next-due (+ +t0+ 60)) args (function-name key))
  (s:make-stored-job :key key :function-name function-name :schedule schedule :args args
                     :next-due next-due :updated-at +t0+))

(defun %acquire (store key holder now &key (expected-due :any) (expected-run :any)
                                          (next-due :keep) (run-id "r1") (trigger :schedule)
                                          scheduled-for (lease 30) args)
  (s:store-acquire store key holder :now now :until (+ now lease) :expected-due expected-due
                                    :expected-run expected-run :next-due next-due
                                    :run-id run-id :trigger trigger :scheduled-for scheduled-for
                                    :args args))

(defun %check-put (store)
  (is (null (s:store-job store "a")) "no job before one is put")
  (is-true (s:store-put-job store (%job "a")) "a new job is written")
  (is (null (s:store-put-job store (%job "a" :schedule '(:every 5))))
      "without REPLACE, an existing job is not written")
  (is (equal '(:every 60) (s:stored-job-schedule (s:store-job store "a")))
      "and keeps its schedule")
  (%acquire store "a" "h1" +t0+)
  (is-true (s:store-put-job store (%job "a" :schedule '(:every 5) :next-due 7) :replace t))
  (let ((job (s:store-job store "a")))
    (is (equal '(:every 5) (s:stored-job-schedule job)) "REPLACE writes the schedule")
    (is (eql 7 (s:stored-job-next-due job)) "and the next due time")
    (is (equal "h1" (s:stored-job-lease-holder job)) "and leaves the lease alone"))
  (is (equal '("a") (mapcar #'s:stored-job-key (s:store-jobs store)))))

(defun %check-data (store)
  (let ((args '(1 "two" :three (4.5d0 nil "six")))
        (schedule '(:weekly (:mon :fri) (9 30) :zone "Europe/London")))
    (s:store-put-job store (%job "d" :schedule schedule :args args :next-due nil))
    (let ((job (s:store-job store "d")))
      (is (equal args (s:stored-job-args job)) "arguments come back EQUAL")
      (is (equal schedule (s:stored-job-schedule job)) "a schedule with a zone comes back EQUAL")
      (is (null (s:stored-job-next-due job)) "a job with nothing due has no next due time"))))

(defun %check-acquire (store)
  (s:store-put-job store (%job "j"))
  (is (null (%acquire store "j" "h1" +t0+ :expected-due 999 :next-due 1))
      "a stale next due time takes nothing")
  (let ((run (%acquire store "j" "h1" (+ +t0+ 60) :expected-due (+ +t0+ 60)
                                                  :next-due (+ +t0+ 120) :run-id "r1"
                                                  :scheduled-for (+ +t0+ 60))))
    (is-true run "a free lease with the expected due time is taken")
    (is (equal "r1" (s:job-run-id run)))
    (is (eq :running (s:job-run-outcome run)))
    (is (eq :schedule (s:job-run-trigger run)))
    (is (eql (+ +t0+ 60) (s:job-run-scheduled-for run)))
    (is (equal "h1" (s:job-run-holder run))))
  (let ((job (s:store-job store "j")))
    (is (eql (+ +t0+ 120) (s:stored-job-next-due job)) "the next due time moved in the same step")
    (is (equal "h1" (s:stored-job-lease-holder job)))
    (is (eql (+ +t0+ 90) (s:stored-job-lease-until job)))
    (is (equal "r1" (s:stored-job-current-run job))))
  (is (null (%acquire store "j" "h2" (+ +t0+ 61) :run-id "r2"))
      "a lease that has not expired is not taken, even with :ANY")
  (is (null (%acquire store "j" "h2" (+ +t0+ 90) :run-id "r2"))
      "nor at the instant it expires")
  (is (null (s:store-run store "r2")) "and a refused acquire records no run"))

(defun %check-renew-and-finish (store)
  (s:store-put-job store (%job "j"))
  (%acquire store "j" "h1" +t0+ :run-id "r1")
  (is (null (s:store-renew store "j" "h2" "r1" (+ +t0+ 100))) "another holder cannot renew")
  (is (null (s:store-renew store "j" "h1" "r9" (+ +t0+ 100))) "nor another run")
  (is-true (s:store-renew store "j" "h1" "r1" (+ +t0+ 100)))
  (is (eql (+ +t0+ 100) (s:stored-job-lease-until (s:store-job store "j"))))
  (is-true (s:store-finish store "j" "h1" "r1" :now (+ +t0+ 5) :outcome :completed
                                               :counts '(:sent 3 :skipped 1) :error nil)
           "finishing the lease's own run releases it")
  (let ((job (s:store-job store "j"))
        (run (s:store-run store "r1")))
    (is (null (s:stored-job-lease-holder job)))
    (is (null (s:stored-job-current-run job)))
    (is (eq :completed (s:job-run-outcome run)))
    (is (eql (+ +t0+ 5) (s:job-run-finished-at run)))
    (is (equal '(:sent 3 :skipped 1) (s:job-run-counts run)) "counts come back EQUAL")))

(defun %check-takeover (store)
  (s:store-put-job store (%job "j"))
  (%acquire store "j" "h1" +t0+ :run-id "r1" :scheduled-for 77 :args '(7 "seven"))
  (is (equal '(7 "seven") (s:job-run-args (s:store-run store "r1")))
      "a run keeps the arguments it was started with")
  (is (null (%acquire store "j" "h2" (+ +t0+ 31) :run-id "r2" :expected-run "r-other"))
      "an expired lease is not taken when its run is not the one the caller read")
  (is (null (%acquire store "j" "h2" (+ +t0+ 31) :run-id "r2" :expected-run nil))
      "nor when the caller read no run")
  (let ((run (%acquire store "j" "h2" (+ +t0+ 31) :run-id "r2" :trigger :retry
                                                  :expected-run "r1"
                                                  :expected-due (+ +t0+ 60) :next-due :keep)))
    (is-true run "an expired lease is taken")
    (is (eq :retry (s:job-run-trigger run))))
  (let ((old (s:store-run store "r1")))
    (is (eq :abandoned (s:job-run-outcome old)) "the run the dead lease named is abandoned")
    (is (eql (+ +t0+ 31) (s:job-run-finished-at old))))
  (is (eql (+ +t0+ 60) (s:stored-job-next-due (s:store-job store "j")))
      ":KEEP leaves the next due time alone")
  (is (null (s:store-finish store "j" "h1" "r1" :now (+ +t0+ 40) :outcome :completed))
      "the late finish of the abandoned run does not release the new lease")
  (is (eq :completed (s:job-run-outcome (s:store-run store "r1")))
      "but it does record how the run ended")
  (is (equal "h2" (s:stored-job-lease-holder (s:store-job store "j")))))

(defun %check-remove-on-finish (store)
  (s:store-put-job store (%job "once" :schedule (list :once (+ +t0+ 5))))
  (%acquire store "once" "h1" +t0+ :run-id "r1")
  (%acquire store "once" "h2" (+ +t0+ 31) :run-id "r2" :expected-run "r1")
  (is (null (s:store-finish store "once" "h1" "r1" :now (+ +t0+ 32) :outcome :completed
                                                   :remove-job t))
      "a late finish with REMOVE-JOB does not own the lease")
  (is (equal "r2" (s:stored-job-current-run (s:store-job store "once")))
      "and leaves the job, and the run now holding it, alone")
  (is-true (s:store-finish store "once" "h2" "r2" :now (+ +t0+ 33) :outcome :completed
                                                  :remove-job t))
  (is (null (s:store-job store "once")) "the run that holds the lease removes the job")
  (is (eq :completed (s:job-run-outcome (s:store-run store "r2")))))

(defun %check-abandon (store)
  (s:store-put-job store (%job "j"))
  (%acquire store "j" "h1" +t0+ :run-id "r1")
  (is (null (s:store-abandon store "j" :now (+ +t0+ 10) :expected-run "r1"))
      "a live lease is not abandoned")
  (is (null (s:store-abandon store "j" :now (+ +t0+ 31) :expected-run "r-other"))
      "nor an expired one whose run is not the one the caller read")
  (is (null (s:store-abandon store "j" :now (+ +t0+ 31) :expected-run nil))
      "nor when the caller read no run")
  (is-true (s:store-abandon store "j" :now (+ +t0+ 31) :expected-run "r1"))
  (let ((run (s:store-run store "r1")))
    (is (eq :abandoned (s:job-run-outcome run)))
    (is (eql (+ +t0+ 31) (s:job-run-finished-at run))))
  (let ((job (s:store-job store "j")))
    (is (null (s:stored-job-lease-holder job)) "the lease is freed")
    (is (null (s:stored-job-current-run job)))
    (is (eql (+ +t0+ 60) (s:stored-job-next-due job)) "the next due time is left alone"))
  (is (eql 1 (length (s:store-runs store "j"))) "no run is started")
  (is (null (s:store-abandon store "j" :now (+ +t0+ 32) :expected-run "r1"))
      "a second abandon changes nothing"))

(defun %check-advance (store)
  (s:store-put-job store (%job "j"))
  (is (null (s:store-advance store "j" :expected-due 5 :next-due 6)))
  (is-true (s:store-advance store "j" :expected-due (+ +t0+ 60) :next-due (+ +t0+ 180)))
  (is (eql (+ +t0+ 180) (s:stored-job-next-due (s:store-job store "j")))))

(defun %finished-run (id key started &optional (outcome :completed))
  (s:make-job-run :id id :job-key key :holder "h" :trigger :schedule :started-at started
                  :finished-at started :outcome outcome))

(defun %check-runs-and-prune (store)
  (s:store-put-job store (%job "j"))
  (s:store-put-job store (%job "k"))
  (loop for i from 1 to 4
        do (s:store-record-run store (%finished-run (format nil "j~D" i) "j" (+ +t0+ i))))
  (s:store-record-run store (%finished-run "k1" "k" +t0+))
  (s:store-record-run store (%finished-run "j0" "j" (- +t0+ 10) :running))
  (is (equal '("j4" "j3" "j2" "j1" "j0") (mapcar #'s:job-run-id (s:store-runs store "j")))
      "runs come newest first")
  (is (equal '("j4" "j3") (mapcar #'s:job-run-id (s:store-runs store "j" :limit 2))))
  (is (eql 2 (s:store-prune-runs store :key "j" :keep 2))
      "KEEP deletes the finished runs beyond the newest two, and never a running one")
  (is (equal '("j4" "j3" "j0") (mapcar #'s:job-run-id (s:store-runs store "j"))))
  (is (eql 1 (length (s:store-runs store "k"))) "KEY limited the pruning to one job")
  (is (eql 1 (s:store-prune-runs store :before (+ +t0+ 3)))
      "BEFORE deletes older finished runs of every job, here k's")
  (is (equal '("j4" "j3" "j0") (mapcar #'s:job-run-id (s:store-runs store "j"))))
  (is (null (s:store-runs store "k")))
  (is-true (s:store-remove-job store "j"))
  (is (null (s:store-job store "j")))
  (is (eql 3 (length (s:store-runs store "j"))) "removing a job keeps its runs"))

(defun check-store (make-store)
  "Run the store protocol's checks, each against a fresh store from MAKE-STORE, a function of no
arguments."
  (dolist (check (list #'%check-put #'%check-data #'%check-acquire #'%check-renew-and-finish
                       #'%check-takeover #'%check-remove-on-finish #'%check-abandon #'%check-advance
                       #'%check-runs-and-prune))
    (funcall check (funcall make-store))))
