;;;; schedule.lisp --- aion/schedule: next due times, and the scheduler on a manual clock (#689).

(cl:defpackage #:aion/schedule/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:s #:aion/schedule)
                    (#:tz #:aion/tz)
                    (#:checks #:aion/schedule/store-checks)
                    (#:tt #:aion/test-threads))
  (:export #:run-tests))

(in-package #:aion/schedule/tests)

(def-suite schedule :description "aion/schedule: schedules, the lease, the run log.")
(in-suite schedule)

(defun run-tests ()
  (let ((results (run 'schedule)))
    (explain! results)
    (unless (results-status results) (error "aion/schedule tests failed"))))

(defun utc (y mo d h mi) (encode-universal-time 0 mi h d mo y 0))

(defun zones-p ()
  (and (tz:valid-zone-p "Europe/London") (tz:valid-zone-p "America/New_York")
       (handler-case (progn (tz:find-zone "Europe/London") (tz:find-zone "America/New_York") t)
         (error () nil))))

(defmacro with-zones (&body body)
  `(if (zones-p)
       (progn ,@body)
       (skip "this system has no Europe/London or America/New_York zone data")))

(defun wait-until (test &key (timeout 5))
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop (when (funcall test) (return t))
          (when (> (get-internal-real-time) deadline) (return nil))
          (sleep 0.005))))

;;; --- schedule forms and next-due -----------------------------------------------------------

(test check-schedule-refuses-what-it-cannot-run
  (dolist (form '((:every 0) (:every 1.5) (:daily (24 0)) (:daily (9 60)) (:daily 9)
                  (:weekly () (9 0)) (:weekly (:someday) (9 0)) (:hourly 5) (:once -1)
                  (:daily (9 0) :tz "UTC") nil "daily"))
    (signals s:invalid-schedule (s:check-schedule form) "~S" form))
  (dolist (form '((:every 60) (:daily (0 0)) (:weekly (:mon :sun) (23 59)) (:once 0)))
    (is (equal form (s:check-schedule form))))
  (with-zones
    (is-true (s:check-schedule '(:daily (9 0) :zone "Europe/London")))
    (signals error (s:check-schedule '(:daily (9 0) :zone "Nowhere/Not_A_Zone")))))

(test every-keeps-its-phase-and-skips-missed-slots
  (is (= 1060 (s:next-due '(:every 60) 1000)) "without a previous slot, AFTER plus the interval")
  (is (= 960 (s:next-due '(:every 60) 900 :previous 900)) "the slot after the one that ran")
  (is (= 1020 (s:next-due '(:every 60) 1000 :previous 900)) "strictly after AFTER, on the phase")
  (is (= 1560 (s:next-due '(:every 60) 1500 :previous 900))
      "ten missed slots give one next slot, not ten"))

(test once-is-due-once
  (is (= 500 (s:next-due '(:once 500) 100)))
  (is (null (s:next-due '(:once 500) 500)) "nothing is due after it"))

(test daily-and-weekly-in-utc
  (let ((thu (utc 2026 10 15 8 0)))
    (is (= 3 (nth-value 6 (decode-universal-time thu 0))) "2026-10-15 is a Thursday")
    (multiple-value-bind (ut date) (s:next-due '(:daily (9 0)) thu)
      (is (= (utc 2026 10 15 9 0) ut))
      (is (equal '(2026 10 15) date)))
    (is (= (utc 2026 10 16 9 0) (s:next-due '(:daily (9 0)) (utc 2026 10 15 9 0)))
        "strictly after: the slot at AFTER itself has run")
    (is (= (utc 2026 10 19 9 0) (s:next-due '(:weekly (:mon) (9 0)) thu)))
    (is (= (utc 2026 10 16 7 30) (s:next-due '(:weekly (:mon :fri) (7 30)) thu)))
    (is (= (utc 2026 10 22 9 0) (s:next-due '(:weekly (:thu) (9 0)) (utc 2026 10 15 9 0)))
        "a weekly schedule whose only day is today, with today's slot past, is a week on")))

(defun walk (form from n)
  "N successive slots of FORM after FROM, each with its local date."
  (loop repeat n
        for (ut date) = (multiple-value-list (s:next-due form from))
        do (setf from ut)
        collect (list ut date)))

(test london-across-both-changes
  (with-zones
    ;; 2026-03-29: 01:00 GMT becomes 02:00 BST, so 01:30 does not exist that day.
    (is (equal (list (list (utc 2026 3 28 1 30) '(2026 3 28))
                     (list (utc 2026 3 29 1 0) '(2026 3 29))
                     (list (utc 2026 3 30 0 30) '(2026 3 30)))
               (walk '(:daily (1 30) :zone "Europe/London") (utc 2026 3 28 0 0) 3))
        "a slot in the gap runs once, at the first instant after it")
    (is (equal (list (utc 2026 3 28 9 0) (utc 2026 3 29 8 0))
               (mapcar #'first (walk '(:daily (9 0) :zone "Europe/London")
                                     (utc 2026 3 28 0 0) 2)))
        "09:00 stays 09:00 local across the change")
    ;; 2026-10-25: 02:00 BST becomes 01:00 GMT, so 01:30 happens twice that day.
    (is (equal (list (list (utc 2026 10 24 0 30) '(2026 10 24))
                     (list (utc 2026 10 25 0 30) '(2026 10 25))
                     (list (utc 2026 10 26 1 30) '(2026 10 26)))
               (walk '(:daily (1 30) :zone "Europe/London") (utc 2026 10 24 0 0) 3))
        "a slot in the overlap runs once, at the earlier instant")))

(test new-york-across-both-changes
  (with-zones
    ;; 2026-03-08: 02:00 EST becomes 03:00 EDT.
    (is (equal (list (utc 2026 3 7 7 30) (utc 2026 3 8 7 0) (utc 2026 3 9 6 30))
               (mapcar #'first (walk '(:daily (2 30) :zone "America/New_York")
                                     (utc 2026 3 7 0 0) 3))))
    ;; 2026-11-01: 02:00 EDT becomes 01:00 EST.
    (is (equal (list (utc 2026 10 31 5 30) (utc 2026 11 1 5 30) (utc 2026 11 2 6 30))
               (mapcar #'first (walk '(:daily (1 30) :zone "America/New_York")
                                     (utc 2026 10 31 0 0) 3))))
    (is (equal '(2026 10 31)
               (second (multiple-value-list
                        (s:next-due '(:daily (23 0) :zone "America/New_York")
                                    (utc 2026 11 1 0 0)))))
        "the local date of 23:00 New York is the day before in UTC")))

;;; --- the store contract ---------------------------------------------------------------------

(test the-memory-store-keeps-the-store-contract
  (checks:check-store #'s:make-memory-job-store))

(test data-round-trips-and-refuses-what-it-cannot-write
  (is (null (s:write-data nil)))
  (is (equal '(:a "b" 1 (2.5d0)) (s:read-data (s:write-data '(:a "b" 1 (2.5d0))))))
  (signals error (s:write-data (list (make-hash-table))))
  (signals reader-error (s:read-data "#.(+ 1 2)") "READ-DATA does not evaluate")
  ;; A handler that PRIN1s the error where it is signalled, as fiveam does, can print it, rather
  ;; than getting PRINT-NOT-READABLE from WITH-STANDARD-IO-SYNTAX's *PRINT-READABLY*.
  (let ((printed nil))
    (handler-case
        (handler-bind ((reader-error
                         (lambda (e)
                           (setf printed (handler-case (prin1-to-string e)
                                           (print-not-readable () :print-not-readable))))))
          (s:read-data "(no-such-package-689::x)"))
      (reader-error () nil))
    (is (stringp printed))))

;;; --- the scheduler ----------------------------------------------------------------------------

(defparameter +t0+ 3990000000)

(defun capture ()
  "A dispatch function that keeps each run's thunk without running it, and the list it keeps."
  (let ((box (list '())))
    (values (lambda (thunk) (push thunk (car box)) t) box)))

(defun drain (box)
  (let ((thunks (reverse (car box))))
    (setf (car box) '())
    (mapc #'funcall thunks)))

(defmacro with-scheduler ((var store clock &rest keys) &body body)
  `(let ((,var (s:make-scheduler ,store :clock ,clock ,@keys)))
     (unwind-protect (progn ,@body) (s:stop ,var :timeout 5))))

(defun counter ()
  (let ((n (list 0)))
    (values (lambda (ctx &rest args) (declare (ignore ctx args)) (incf (car n)) nil) n)))

(defun outcomes (store key)
  (mapcar #'s:job-run-outcome (reverse (s:store-runs store key))))

(test a-slot-runs-once
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (f n) (counter)
      (with-scheduler (a store clock :dispatch :inline)
        (s:define-job a "j" f :schedule '(:every 60))
        (is (null (s:tick a)) "nothing is due at definition")
        (s:clock-advance clock 60)
        (is (= 1 (length (s:tick a))))
        (is (null (s:tick a)) "a second tick in the same slot starts nothing")
        (s:clock-advance clock 60)
        (s:tick a)
        (is (= 2 (car n)))
        (is (equal '(:completed :completed) (outcomes store "j")))
        (is (= (+ +t0+ 180) (s:stored-job-next-due (s:store-job store "j"))))))))

(test two-instances-run-a-slot-once
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (dispatch box) (capture)
      (multiple-value-bind (f n) (counter)
        (with-scheduler (a store clock :dispatch dispatch)
          (with-scheduler (b store clock :dispatch :inline)
            (s:define-job a "j" f :schedule '(:every 60))
            (s:define-job b "j" f :schedule '(:every 60))
            (s:clock-advance clock 60)
            (is (= 1 (length (s:tick a))))
            (is (null (s:tick b)) "while A's run holds the lease, B starts nothing")
            (drain box)
            (is (null (s:tick b)) "after it, B finds the slot already advanced")
            (is (= 1 (car n)))))))))

(test a-missed-slot-catches-up-once
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (f n) (counter)
      (with-scheduler (a store clock :dispatch :inline)
        (s:define-job a "j" f :schedule '(:every 60)))
      ;; Nothing ran for ten slots, as across a redeploy.
      (s:clock-advance clock 630)
      (with-scheduler (b store clock :dispatch :inline)
        (s:define-job b "j" f :schedule '(:every 60))
        (is (= (+ +t0+ 60) (s:stored-job-next-due (s:store-job store "j")))
            "the same schedule keeps the stored next due time")
        (s:tick b)
        (is (= 1 (car n)) "ten missed slots run once")
        (is (eq :catch-up (s:job-run-trigger (first (s:store-runs store "j")))))
        (is (= (+ +t0+ 660) (s:stored-job-next-due (s:store-job store "j"))))
        (s:clock-advance clock 30)
        (s:tick b)
        (is (eq :schedule (s:job-run-trigger (first (s:store-runs store "j"))))
            "the next slot is an ordinary one")))))

(test a-changed-schedule-starts-again-from-now
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (with-scheduler (a store clock :dispatch :inline)
      (s:define-job a "j" (counter) :schedule '(:every 60))
      (s:clock-advance clock 10)
      (s:define-job a "j" (counter) :schedule '(:every 120))
      (is (= (+ +t0+ 130) (s:stored-job-next-due (s:store-job store "j")))))))

(test a-dead-instance-run-is-abandoned-then-retried
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (dispatch box) (capture)
      (declare (ignorable box))
      (multiple-value-bind (f n) (counter)
        (let ((a (s:make-scheduler store :clock clock :dispatch dispatch :lease-seconds 30)))
          (s:define-job a "j" f :schedule '(:every 600))
          (s:clock-advance clock 600)
          (let ((first-run (first (s:tick a))))
            ;; A dies: its thunk never runs and it never ticks again.
            (with-scheduler (b store clock :dispatch :inline :lease-seconds 30)
              (s:define-job b "j" f :schedule '(:every 600))
              (s:clock-advance clock 30)
              (is (null (s:tick b)) "at the instant the lease ends it is still A's")
              (s:clock-advance clock 1)
              (is (= 1 (length (s:tick b))))
              (is (eq :abandoned (s:job-run-outcome (s:store-run store first-run))))
              (let ((retry (first (s:store-runs store "j"))))
                (is (eq :retry (s:job-run-trigger retry)))
                (is (eq :completed (s:job-run-outcome retry)))
                (is (= (+ +t0+ 600) (s:job-run-scheduled-for retry))
                    "the retry is of the abandoned run's slot"))
              (is (= (+ +t0+ 1200) (s:stored-job-next-due (s:store-job store "j")))
                  "a retry leaves the next due time alone")
              (is (= 1 (car n))))))))))

(test a-retry-whose-instance-dies-too-is-abandoned-and-not-retried
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (dispatch box) (capture)
      (declare (ignorable box))
      (multiple-value-bind (f n) (counter)
        ;; A starts the slot's run and dies; B retries it and dies too. Neither thunk runs.
        (let ((a (s:make-scheduler store :clock clock :dispatch dispatch :lease-seconds 30))
              (b (s:make-scheduler store :clock clock :dispatch dispatch :lease-seconds 30)))
          (s:define-job a "j" f :schedule '(:every 600))
          (s:define-job b "j" f :schedule '(:every 600))
          (s:clock-advance clock 600)
          (let ((first-run (first (s:tick a))))
            (s:clock-advance clock 31)
            (let ((retry (first (s:tick b))))
              (is-true retry "the first abandoned run is retried")
              (with-scheduler (c store clock :dispatch :inline :lease-seconds 30)
                (s:define-job c "j" f :schedule '(:every 600))
                (s:clock-advance clock 31)
                (is (null (s:tick c)) "the abandoned retry is not retried")
                (is (eq :abandoned (s:job-run-outcome (s:store-run store first-run))))
                (is (eq :abandoned (s:job-run-outcome (s:store-run store retry))))
                (is (= 2 (length (s:store-runs store "j"))) "no third run was started")
                (let ((job (s:store-job store "j")))
                  (is (null (s:stored-job-lease-holder job)) "the lease is freed")
                  (is (null (s:stored-job-current-run job)))
                  (is (= (+ +t0+ 1200) (s:stored-job-next-due job))
                      "the job waits for its next slot"))
                (is (null (s:tick c)) "and the next tick starts nothing either")
                (s:clock-set clock (+ +t0+ 1200))
                (is (= 1 (length (s:tick c))) "the next slot runs as usual")
                (is (= 1 (car n)))))))))))

(test a-live-instance-renews-its-lease
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (dispatch box) (capture)
      (with-scheduler (a store clock :dispatch dispatch :lease-seconds 30)
        (with-scheduler (b store clock :dispatch :inline :lease-seconds 30)
          (s:define-job a "j" (counter) :schedule '(:every 600))
          (s:define-job b "j" (counter) :schedule '(:every 600))
          (s:clock-advance clock 600)
          (s:tick a)
          (s:clock-advance clock 20)
          (s:tick a)
          (s:clock-advance clock 20)
          (is (null (s:tick b)) "A renewed at +20, so at +40 the run is still A's")
          (drain box)
          (is (equal '(:completed) (outcomes store "j"))))))))

(test a-slot-that-falls-due-during-a-local-run-is-skipped
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (dispatch box) (capture)
      (with-scheduler (a store clock :dispatch dispatch :lease-seconds 300)
        (s:define-job a "j" (counter) :schedule '(:every 60))
        (s:clock-advance clock 60)
        (s:tick a)
        (s:clock-advance clock 60)
        (is (null (s:tick a)) "no second run while the first is going")
        (is (equal '(:running :skipped) (outcomes store "j")))
        (is (= (+ +t0+ 180) (s:stored-job-next-due (s:store-job store "j"))))
        (drain box)
        (is (equal '(:completed :skipped) (outcomes store "j")))))))

(test how-a-run-ends
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (with-scheduler (a store clock :dispatch :inline)
      (s:define-job a "counts" (lambda (ctx) (declare (ignore ctx)) '(:sent 3 :failed 0))
                    :schedule '(:every 60))
      (s:define-job a "fails" (lambda (ctx) (declare (ignore ctx)) (error "it broke"))
                    :schedule '(:every 60))
      (s:define-job a "items" (lambda (ctx)
                                (s:note-item-error ctx "row 4: no address")
                                (s:note-item-error ctx "row 9: bounced")
                                '(:sent 8))
                    :schedule '(:every 60))
      (s:define-job a "odd" (lambda (ctx) (declare (ignore ctx)) "not a plist")
                    :schedule '(:every 60))
      (s:clock-advance clock 60)
      (is (= 4 (length (s:tick a))))
      (flet ((last-run (key) (first (s:store-runs store key))))
        (is (eq :completed (s:job-run-outcome (last-run "counts"))))
        (is (equal '(:sent 3 :failed 0) (s:job-run-counts (last-run "counts"))))
        (is (eq :failed (s:job-run-outcome (last-run "fails"))))
        (is (search "SIMPLE-ERROR" (s:job-run-error (last-run "fails"))))
        (is (search "it broke" (s:job-run-error (last-run "fails"))))
        (is (null (s:stored-job-lease-holder (s:store-job store "fails")))
            "a failed run releases its lease")
        (is (eq :completed-with-errors (s:job-run-outcome (last-run "items"))))
        (is (equal "2 item errors: row 4: no address; row 9: bounced"
                   (s:job-run-error (last-run "items"))))
        (is (equal '(:sent 8) (s:job-run-counts (last-run "items"))))
        (is (eq :completed (s:job-run-outcome (last-run "odd"))))
        (is (null (s:job-run-counts (last-run "odd"))) "a result that is not counts is not kept")))))

(test the-run-context-carries-the-slot
  (with-zones
    (let ((store (s:make-memory-job-store))
          (clock (s:make-manual-clock (utc 2026 11 1 0 0)))
          (seen (list nil)))
      (with-scheduler (a store clock :dispatch :inline)
        (s:define-job a "j" (lambda (ctx)
                              (setf (car seen) (list (s:run-trigger ctx) (s:run-scheduled-for ctx)
                                                     (s:run-local-date ctx) (s:run-key ctx)
                                                     (stringp (s:run-id ctx))))
                              nil)
                      :schedule '(:daily (23 0) :zone "America/New_York"))
        (s:clock-set clock (utc 2026 11 1 4 0))
        (s:tick a)
        (is (equal (list :schedule (utc 2026 11 1 3 0) '(2026 10 31) "j" t) (car seen)))))))

(test run-now-runs-off-schedule
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (dispatch box) (capture)
      (with-scheduler (a store clock :dispatch dispatch)
        (s:define-job a "j" (lambda (ctx &optional x) (declare (ignore ctx)) (list :x x))
                      :schedule '(:every 600))
        (multiple-value-bind (id status) (s:run-now a "j" :args '(7))
          (is (eq :started status))
          (multiple-value-bind (id2 status2) (s:run-now a "j")
            (is (eq :already-running status2))
            (is (equal id id2) "the second call names the run in progress"))
          (drain box)
          (let ((run (s:store-run store id)))
            (is (eq :run-now (s:job-run-trigger run)))
            (is (equal '(:x 7) (s:job-run-counts run)))))
        (is (= (+ +t0+ 600) (s:stored-job-next-due (s:store-job store "j")))
            "running now leaves the schedule alone")
        (let ((run (s:run-job a "j" :args '(9))))
          (is (eq :completed (s:job-run-outcome run)) "RUN-JOB returns the finished run")
          (is (equal '(:x 9) (s:job-run-counts run))))
        (signals s:unknown-job (s:run-now a "nope"))))))

(test a-stored-job-with-no-registered-function-is-left-alone
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (with-scheduler (a store clock :dispatch :inline)
      (s:define-job a "j" (counter) :schedule '(:every 60)))
    (with-scheduler (b store clock :dispatch :inline)
      (s:clock-advance clock 60)
      (is (null (s:tick b)))
      (is (null (s:tick b)))
      (is (null (s:stored-job-lease-holder (s:store-job store "j")))
          "an instance that cannot run it does not take its lease")
      (signals s:unknown-job (s:run-now b "j")))))

(test a-stored-job-that-cannot-be-read-is-left-alone-and-the-others-run
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (f n) (counter)
      (with-scheduler (a store clock :dispatch :inline :lease-seconds 300)
        (s:define-job a "j" f :schedule '(:every 60))
        ;; What a database store returns for a row whose arguments name a package that is gone.
        (s:store-put-job store (s:make-stored-job :key "bad" :function-name "j"
                                                  :schedule '(:every 60)
                                                  :next-due +t0+ :updated-at +t0+
                                                  :unreadable "READER-ERROR: no package"))
        (s:clock-advance clock 60)
        (is (= 1 (length (s:tick a))) "the readable job runs")
        (is (= 1 (car n)))
        (is (null (s:store-runs store "bad")) "the unreadable one does not")
        (is (null (s:stored-job-lease-holder (s:store-job store "bad"))))
        (is (= 60 (s:next-wake a)) "and does not make the driver tick every second")
        (signals s:unreadable-job (s:run-now a "bad"))))))

(test a-one-off-runs-once-and-is-removed
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)) (seen (list nil)))
    (with-scheduler (a store clock :dispatch :inline)
      (s:define-job a "send" (lambda (ctx &rest args) (declare (ignore ctx))
                               (push args (car seen)) nil))
      (s:define-job a "boom" (lambda (ctx) (declare (ignore ctx)) (error "no")))
      (let ((key (s:schedule-once a "send" :at (+ +t0+ 5) :args '(1 "two" :three)))
            (bad (s:schedule-once a "boom" :at (+ +t0+ 5))))
        (is (null (s:tick a)))
        (s:clock-advance clock 5)
        (s:tick a)
        (s:clock-advance clock 60)
        (s:tick a)
        (is (equal '((1 "two" :three)) (car seen)) "it ran once, with its arguments")
        (is (null (s:store-job store key)) "a completed one-off is removed")
        (is (equal '(:completed) (outcomes store key)) "and its run is kept")
        (is-true (s:store-job store bad) "a failed one-off stays")
        (is (null (s:stored-job-next-due (s:store-job store bad))) "with nothing due")
        (is (eq :failed (s:job-run-outcome (s:run-job a bad)))
            "and an operator can run it again by its key"))
      (signals s:unreadable-job-args
        (s:schedule-once a "send" :at +t0+ :args (list (make-hash-table))))
      (signals s:unknown-job (s:schedule-once a "nope" :at +t0+)))))

(test keep-runs-and-prune
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (with-scheduler (a store clock :dispatch :inline :keep-runs 2)
      (s:define-job a "j" (counter) :schedule '(:every 60))
      (dotimes (i 4) (s:clock-advance clock 60) (s:tick a))
      (is (= 2 (length (s:store-runs store "j"))) ":KEEP-RUNS keeps the newest two"))
    (with-scheduler (b store clock :dispatch :inline)
      (s:define-job b "j" (counter) :schedule '(:every 60))
      (s:clock-advance clock 60)
      (s:tick b)
      (is (= 3 (length (s:store-runs store "j"))) "without it, nothing is pruned")
      (is (= 3 (s:store-prune-runs store :before (1+ (s:scheduler-clock-now b))))))))

(test a-refused-run-fails-and-releases-the-lease
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (with-scheduler (a store clock :dispatch (lambda (thunk) (declare (ignore thunk)) nil))
      (s:define-job a "j" (counter) :schedule '(:every 60))
      (s:clock-advance clock 60)
      (s:tick a)
      (let ((run (first (s:store-runs store "j"))))
        (is (eq :failed (s:job-run-outcome run)))
        (is (equal "the worker pool refused the run" (s:job-run-error run))))
      (is (null (s:stored-job-lease-holder (s:store-job store "j")))))))

(test stop-waits-for-runs-and-then-refuses
  (let* ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+))
         (gate (sb-thread:make-semaphore)) (saw-stop (list nil))
         (a (s:make-scheduler store :clock clock)))
    (s:define-job a "slow" (lambda (ctx)
                             (sb-thread:wait-on-semaphore gate)
                             (setf (car saw-stop) (s:stop-requested-p ctx))
                             nil)
                  :schedule '(:every 60))
    (s:clock-advance clock 60)
    (is (= 1 (length (s:tick a))) "it runs on the scheduler's own pool")
    (multiple-value-bind (status keys) (s:stop a :timeout 0.2)
      (is (eq :timed-out status))
      (is (equal '("slow") keys)))
    (is (null (s:tick a)) "a stopping scheduler starts nothing")
    (signals s:scheduler-stopped (s:run-now a "slow"))
    (sb-thread:signal-semaphore gate)
    (is (eq :stopped (s:stop a :timeout 5)))
    (is-true (car saw-stop) "the job could see the stop")
    (is (equal '(:completed) (outcomes store "slow")))))

(test next-wake-is-the-earliest-due-time-capped-at-a-third-of-the-lease
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (with-scheduler (a store clock :dispatch :inline :lease-seconds 300)
      (is (= 100 (s:next-wake a)) "with no jobs, a third of the lease")
      (s:define-job a "j" (counter) :schedule '(:every 40))
      (is (= 40 (s:next-wake a)))
      (s:clock-advance clock 45)
      (is (= 1 (s:next-wake a)) "an overdue job wakes it at once"))))

(test next-wake-ignores-jobs-this-instance-cannot-run
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (with-scheduler (a store clock :dispatch :inline)
      (s:define-job a "j" (counter) :schedule '(:every 40)))
    (s:store-put-job store (s:make-stored-job :key "broken" :function-name "k"
                                              :schedule '(:every -5) :next-due +t0+
                                              :updated-at +t0+))
    (with-scheduler (b store clock :dispatch :inline :lease-seconds 300)
      ;; B runs "k" but not "j": "j" is overdue and unregistered here, "broken" is overdue and
      ;; registered with a schedule nobody can run.
      (s:define-job b "k" (counter))
      (s:clock-advance clock 45)
      (is (= 100 (s:next-wake b))
          "an overdue job with no registered function here, or an unusable schedule, does not wake it every second"))))

(test the-thread-driver-ticks-and-wakes
  (let* ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+))
         (a (s:make-scheduler store :clock clock)))
    (multiple-value-bind (f n) (counter)
      (unwind-protect
           (progn
             (s:define-job a "j" f :schedule '(:every 60))
             (s:start a)
             (let ((driver (find "aion/schedule driver" (sb-thread:list-all-threads)
                                 :key #'sb-thread:thread-name :test #'equal)))
               (is-true driver "START runs a thread")
               (s:clock-advance clock 60)
               (sleep 0.2)
               (is (= 0 (car n)) "the driver is asleep until the next wake")
               (funcall (s:scheduler-wake-function a))
               (is-true (wait-until (lambda () (= 1 (car n)))) "a wake makes it tick")
               (is-true (wait-until (lambda () (equal '(:completed) (outcomes store "j")))))
               (is (eq :stopped (s:stop a :timeout 5)))
               (is-true (wait-until (lambda () (not (sb-thread:thread-alive-p driver))))
                        "STOP ends the driver thread")))
        (s:stop a :timeout 5)))))

;;; --- review fixes on #692 ----------------------------------------------------------------

(defclass gated-store (s:memory-job-store)
  ((hold :initform nil :accessor hold)
   (entered :initform (sb-thread:make-semaphore) :reader entered)
   (gate :initform (sb-thread:make-semaphore) :reader gate))
  (:documentation "A memory store that, while HOLD names an operation, stops in it until GATE is
signalled, after signalling ENTERED."))

(defun %held (store operation)
  (when (eq operation (hold store))
    (setf (hold store) nil)
    (sb-thread:signal-semaphore (entered store))
    (sb-thread:wait-on-semaphore (gate store))))

(defmethod s:store-acquire :before ((store gated-store) key holder &key &allow-other-keys)
  (declare (ignore key holder))
  (%held store :acquire))

(defmethod s:store-jobs :before ((store gated-store))
  (%held store :jobs))

(defmethod s:store-renew :before ((store gated-store) key holder run-id until)
  (declare (ignore key holder run-id until))
  (%held store :renew))

(defun spawn (name function)
  ;; THREAD-LIFETIME: a test thread, joined by the test that starts it.
  (sb-thread:make-thread function :name name))

(defun elapsed-seconds (start)
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(test a-late-finish-does-not-remove-a-one-off-another-instance-is-retrying
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (da boxa) (capture)
      (multiple-value-bind (db boxb) (capture)
        (let ((a (s:make-scheduler store :clock clock :dispatch da :lease-seconds 30))
              (b (s:make-scheduler store :clock clock :dispatch db :lease-seconds 30)))
          (s:define-job a "send" (lambda (ctx) (declare (ignore ctx)) nil))
          (s:define-job b "send" (lambda (ctx) (declare (ignore ctx)) nil))
          (let ((key (s:schedule-once a "send" :at +t0+)))
            (s:tick a)
            (s:clock-advance clock 31)
            (let ((retry (first (s:tick b))))
              (is-true retry "B retries the run A abandoned")
              (drain boxa)
              (is (equal retry (s:stored-job-current-run (s:store-job store key)))
                  "A's late completion leaves the job and B's lease in place")
              (drain boxb)
              (is (null (s:store-job store key)) "B's completion removes it"))))))))

(test a-stale-read-of-an-abandoned-run-starts-no-second-retry
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)) (n (list 0)))
    (multiple-value-bind (da boxa) (capture)
      (declare (ignorable boxa))
      (let ((f (lambda (ctx) (declare (ignore ctx)) (incf (car n)) nil))
            (a (s:make-scheduler store :clock clock :dispatch da :lease-seconds 30)))
        (s:define-job a "j" f :schedule '(:every 600))
        (s:clock-advance clock 600)
        (s:tick a)
        (s:clock-advance clock 31)
        (with-scheduler (b store clock :dispatch :inline :lease-seconds 30)
          (with-scheduler (c store clock :dispatch :inline :lease-seconds 30)
            (s:define-job b "j" f :schedule '(:every 600))
            (s:define-job c "j" f :schedule '(:every 600))
            (let ((seen-by-c (s:store-job store "j")))
              (s:tick b)
              (is (= 1 (car n)) "B retried and finished")
              (is (null (aion/schedule::%consider c seen-by-c (s:clock-now clock)))
                  "C, acting on what it read before B's retry, starts nothing")
              (is (= 1 (car n))))))))))

(test a-retry-keeps-the-arguments-run-now-gave
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (da boxa) (capture)
      (declare (ignorable boxa))
      (let ((f (lambda (ctx &optional x) (declare (ignore ctx)) (list :x (or x 0))))
            (a (s:make-scheduler store :clock clock :dispatch da :lease-seconds 30)))
        (s:define-job a "j" f :schedule '(:every 600))
        (s:run-now a "j" :args '(7))
        (s:clock-advance clock 31)
        (with-scheduler (b store clock :dispatch :inline :lease-seconds 30)
          (s:define-job b "j" f :schedule '(:every 600))
          (s:tick b)
          (let ((retry (first (s:store-runs store "j"))))
            (is (eq :retry (s:job-run-trigger retry)))
            (is (equal '(:x 7) (s:job-run-counts retry)))))))))

(test a-dispatcher-that-signals-fails-the-run
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (with-scheduler (a store clock :dispatch (lambda (thunk) (declare (ignore thunk))
                                               (error "queue unavailable")))
      (s:define-job a "j" (counter) :schedule '(:every 60))
      (s:clock-advance clock 60)
      (s:tick a)
      (let ((run (first (s:store-runs store "j"))))
        (is (eq :failed (s:job-run-outcome run)))
        (is (search "queue unavailable" (s:job-run-error run))))
      (is (null (s:stored-job-lease-holder (s:store-job store "j"))))
      (is (eq :stopped (s:stop a :timeout 1)) "nothing is left running"))))

(test skipped-runs-are-pruned-too
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (dispatch box) (capture)
      (with-scheduler (a store clock :dispatch dispatch :keep-runs 2)
        (s:define-job a "j" (counter) :schedule '(:every 60))
        (dotimes (i 4) (s:clock-advance clock 60) (s:tick a))
        (is (equal '(:running :skipped :skipped) (outcomes store "j"))
            "the newest two finished runs, and the run still going")
        (drain box)))))

(test next-wake-includes-the-next-slot-of-a-job-running-here
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (dispatch box) (capture)
      (with-scheduler (a store clock :dispatch dispatch :lease-seconds 300)
        (s:define-job a "j" (counter) :schedule '(:every 40))
        (s:clock-advance clock 40)
        (s:tick a)
        (is (= 40 (s:next-wake a)) "the slot at +80 is skipped at +80, not after the run")
        (drain box)))))

(test stop-waits-for-a-run-that-was-admitted-before-it
  (let* ((store (make-instance 'gated-store)) (clock (s:make-manual-clock +t0+))
         (a (s:make-scheduler store :clock clock :dispatch :inline)))
    (s:define-job a "j" (counter) :schedule '(:every 600))
    (setf (hold store) :acquire)
    (let ((caller (spawn "run-now caller" (lambda () (s:run-now a "j")))))
      (sb-thread:wait-on-semaphore (entered store))
      (multiple-value-bind (status keys) (s:stop a :timeout 0.3)
        (is (eq :timed-out status) "a run between admission and its lease holds STOP")
        (is (null keys)))
      (sb-thread:signal-semaphore (gate store))
      (tt:join caller)
      (is (equal '(:completed) (outcomes store "j")))
      (is (eq :stopped (s:stop a :timeout 5))))))

(test stop-renews-the-leases-of-the-runs-it-waits-for
  (let* ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+))
         (gate (sb-thread:make-semaphore))
         (a (s:make-scheduler store :clock clock :lease-seconds 3)))
    (s:define-job a "slow" (lambda (ctx) (declare (ignore ctx))
                             (sb-thread:wait-on-semaphore gate) nil)
                  :schedule '(:every 600))
    (s:clock-advance clock 600)
    (s:tick a)
    (is (= (+ +t0+ 603) (s:stored-job-lease-until (s:store-job store "slow"))))
    (s:clock-advance clock 2)
    (is (eq :timed-out (s:stop a :timeout 1.5)))
    (is (= (+ +t0+ 605) (s:stored-job-lease-until (s:store-job store "slow")))
        "the drain renewed the lease from the clock's +602")
    (sb-thread:signal-semaphore gate)
    (is (eq :stopped (s:stop a :timeout 5)))))

(test stop-gives-up-on-a-driver-stuck-in-a-tick
  (let* ((store (make-instance 'gated-store)) (clock (s:make-manual-clock +t0+))
         (a (s:make-scheduler store :clock clock)))
    (s:start a)
    (setf (hold store) :jobs)
    (funcall (s:scheduler-wake-function a))
    (sb-thread:wait-on-semaphore (entered store))
    (let ((start (get-internal-real-time)))
      (is (eq :timed-out (s:stop a :timeout 0.3)))
      (is (< (elapsed-seconds start) 3) "STOP returned at its timeout"))
    (sb-thread:signal-semaphore (gate store))
    (is (eq :stopped (s:stop a :timeout 5)) "a later STOP finishes the job")))

;;; --- review fixes from train 46 (#702) ---------------------------------------------------

(defun driver-threads (name)
  (remove name (sb-thread:list-all-threads) :key #'sb-thread:thread-name :test-not #'equal))

(test a-one-off-replaced-by-a-recurring-job-while-it-runs-is-kept
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (dispatch box) (capture)
      (with-scheduler (a store clock :dispatch dispatch)
        (s:define-job a "j" (counter))
        (s:schedule-once a "j" :key "j" :at +t0+)
        (is (= 1 (length (s:tick a))) "the one-off starts")
        (s:define-job a "j" (counter) :schedule '(:every 60))
        (drain box)
        (let ((job (s:store-job store "j")))
          (is-true job "its completion does not remove the recurring job that replaced it")
          (when job
            (is (equal '(:every 60) (s:stored-job-schedule job)))
            (is (null (s:stored-job-lease-holder job)) "whose lease is free")))
        (is (equal '(:completed) (outcomes store "j")))))))

(test an-operator-call-does-not-start-a-second-run-of-a-job-still-running-here
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (multiple-value-bind (dispatch box) (capture)
      (with-scheduler (a store clock :dispatch dispatch :lease-seconds 30)
        (s:define-job a "j" (counter) :schedule '(:every 600))
        (s:clock-advance clock 600)
        (let ((first-run (first (s:tick a))))
          ;; The run outlives its lease: no tick renewed it.
          (s:clock-advance clock 31)
          (multiple-value-bind (id status) (s:run-now a "j")
            (is (eq :already-running status) "RUN-NOW finds the run still going here")
            (is (equal first-run id) "and names it"))
          (is (null (s:run-job a "j")) "RUN-JOB starts nothing either")
          (is (eq :running (s:job-run-outcome (s:store-run store first-run)))
              "the run is not marked abandoned")
          (is (= 1 (length (s:store-runs store "j"))) "and no second run was recorded")
          (drain box)
          (is (equal '(:completed) (outcomes store "j")))
          (is (eq :started (nth-value 1 (s:run-now a "j")))
              "once it has finished, an operator call runs it again")
          (drain box))))))

(test define-job-recovers-a-stored-job-that-could-not-be-read
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (with-scheduler (a store clock :dispatch :inline)
      ;; What a database store returns when only the arguments cannot be read: the schedule and
      ;; the function name are the ones DEFINE-JOB is about to give.
      (s:store-put-job store (s:make-stored-job :key "j" :function-name "j"
                                                :schedule '(:every 60) :next-due +t0+
                                                :updated-at +t0+
                                                :unreadable "args READER-ERROR: no package"))
      (s:define-job a "j" (counter) :schedule '(:every 60))
      (is (null (s:stored-job-unreadable (s:store-job store "j"))) "the job is readable again")
      (s:clock-advance clock 60)
      (is (= 1 (length (s:tick a))) "and runs"))))

(test schedule-once-with-a-key-that-exists-signals-unless-it-replaces
  (let ((store (s:make-memory-job-store)) (clock (s:make-manual-clock +t0+)))
    (with-scheduler (a store clock :dispatch :inline)
      (s:define-job a "send" (counter))
      (is (equal "k" (s:schedule-once a "send" :key "k" :at (+ +t0+ 5) :args '(1))))
      (signals s:job-exists (s:schedule-once a "send" :key "k" :at (+ +t0+ 9) :args '(2)))
      (is (equal '(1) (s:stored-job-args (s:store-job store "k"))) "the first one is kept")
      (is (equal "k" (s:schedule-once a "send" :key "k" :at (+ +t0+ 9) :args '(2) :replace t)))
      (let ((job (s:store-job store "k")))
        (is (equal '(2) (s:stored-job-args job)) ":REPLACE T replaces it")
        (is (= (+ +t0+ 9) (s:stored-job-next-due job))))
      (s:store-put-job store (s:make-stored-job :key "u" :function-name "send"
                                                :schedule (list :once +t0+) :next-due +t0+
                                                :updated-at +t0+
                                                :unreadable "args READER-ERROR: no package"))
      (s:schedule-once a "send" :key "u" :at +t0+ :replace t)
      (is (null (s:stored-job-unreadable (s:store-job store "u")))
          "and recovers a one-off that could not be read"))))

(test stop-skips-a-lease-renewal-once-its-timeout-has-passed
  (let* ((store (make-instance 'gated-store)) (clock (s:make-manual-clock +t0+))
         (gate (sb-thread:make-semaphore))
         (a (s:make-scheduler store :clock clock :lease-seconds 3)))
    (s:define-job a "slow" (lambda (ctx) (declare (ignore ctx))
                             (sb-thread:wait-on-semaphore gate) nil)
                  :schedule '(:every 600))
    (s:clock-advance clock 600)
    (s:tick a)
    (setf (hold store) :renew)
    ;; Lets a renewal that was held go after 4 seconds, so that the test ends either way.
    (let ((releaser (spawn "renewal releaser"
                           (lambda () (sleep 4) (sb-thread:signal-semaphore (gate store)) t))))
      (is (eq :timed-out (s:stop a :timeout 0.3)))
      (is (eq :renew (hold store)) "the wait used the whole timeout, and no renewal followed it")
      (setf (hold store) nil)
      (tt:join releaser :timeout 10))
    (sb-thread:signal-semaphore gate)
    (is (eq :stopped (s:stop a :timeout 5)))))

(test stop-gives-up-on-a-lease-renewal-at-its-timeout
  (let* ((store (make-instance 'gated-store)) (clock (s:make-manual-clock +t0+))
         (gate (sb-thread:make-semaphore))
         (a (s:make-scheduler store :clock clock :lease-seconds 3)))
    (s:define-job a "slow" (lambda (ctx) (declare (ignore ctx))
                             (sb-thread:wait-on-semaphore gate) nil)
                  :schedule '(:every 600))
    (s:clock-advance clock 600)
    (s:tick a)
    (setf (hold store) :renew)
    ;; Lets the renewal go after 4 seconds, so that a STOP that waits for it ends the test
    ;; instead of hanging it.
    (let ((releaser (spawn "renewal releaser"
                           (lambda () (sleep 4) (sb-thread:signal-semaphore (gate store)) t)))
          (start (get-internal-real-time)))
      ;; A third of the lease is 1 second: the drain waits 1 second, then renews.
      (is (eq :timed-out (s:stop a :timeout 1.5)))
      (is (< (elapsed-seconds start) 2.5) "STOP returned at its timeout, with the renewal held")
      (tt:join releaser :timeout 10))
    (sb-thread:signal-semaphore gate)
    (is (eq :stopped (s:stop a :timeout 5)))))

(test stop-during-start-s-first-tick-waits-for-start
  (let* ((store (make-instance 'gated-store)) (clock (s:make-manual-clock +t0+))
         (a (s:make-scheduler store :clock clock)))
    (setf (hold store) :jobs)
    (let ((starter (spawn "starter" (lambda () (s:start a) t))))
      (sb-thread:wait-on-semaphore (entered store))
      (let ((stopper (spawn "stopper" (lambda () (s:stop a :timeout 5)))))
        (sleep 0.3)
        (is-true (sb-thread:thread-alive-p stopper) "STOP waits for the start in progress")
        (sb-thread:signal-semaphore (gate store))
        (tt:join starter)
        (is (eq :stopped (tt:join stopper)) "then reports the scheduler stopped")
        (is-true (wait-until (lambda () (null (driver-threads "aion/schedule driver"))))
                 "with no driver thread left")))))

(test a-start-that-outlasts-a-timed-out-stop-starts-no-driver
  (let* ((store (make-instance 'gated-store)) (clock (s:make-manual-clock +t0+))
         (a (s:make-scheduler store :clock clock)))
    (setf (hold store) :jobs)
    (let ((starter (spawn "starter" (lambda () (s:start a) t))))
      (sb-thread:wait-on-semaphore (entered store))
      (is (eq :timed-out (s:stop a :timeout 0.3)) "the first tick is still going")
      (sb-thread:signal-semaphore (gate store))
      (tt:join starter)
      (sleep 0.2)
      (is (null (driver-threads "aion/schedule driver"))
          "START saw the stop after its tick and started no thread")
      (is (eq :stopped (s:stop a :timeout 5))))))
