;;;; packages.lisp --- aion/schedule: named jobs on schedules, with a lease and a run log (#689).

(cl:defpackage #:aion/schedule
  (:use #:cl)
  (:local-nicknames (#:tz #:aion/tz)
                    (#:pool #:aion/pool)
                    (#:log #:aion/log)
                    (#:clock #:aion/clock))
  (:documentation
   "A job scheduler. An app registers job functions by name with DEFINE-JOB, and the scheduler
    runs each stored job when it falls due, on an aion/pool worker pool. The schedule, the next
    due time, a single-runner lease and a run log live in a JOB-STORE, so they survive a
    redeploy and several instances share them: MEMORY-JOB-STORE here, and mnemosyne/jobs for a
    database. The scheduler itself is driven by TICK; START runs a plain thread that ticks, and
    aion/schedule/uv drives it from a libuv timer instead. Design and rulings: issue #689.")
  (:export
   ;; schedule forms
   #:check-schedule #:next-due #:invalid-schedule #:invalid-schedule-form
   #:invalid-schedule-reason
   ;; clocks
   #:manual-clock #:make-manual-clock #:clock-now #:clock-advance #:clock-set
   ;; stored jobs and runs
   #:stored-job #:make-stored-job #:copy-stored-job #:stored-job-key
   #:stored-job-function-name #:stored-job-schedule #:stored-job-args #:stored-job-next-due
   #:stored-job-lease-holder #:stored-job-lease-until #:stored-job-current-run
   #:stored-job-updated-at
   #:job-run #:make-job-run #:copy-job-run #:job-run-id #:job-run-job-key #:job-run-holder
   #:job-run-trigger #:job-run-scheduled-for #:job-run-started-at #:job-run-finished-at
   #:job-run-outcome #:job-run-counts #:job-run-error
   ;; the store protocol
   #:job-store #:store-jobs #:store-job #:store-put-job #:store-remove-job #:store-acquire
   #:store-advance #:store-renew #:store-finish #:store-record-run #:store-runs #:store-run
   #:store-prune-runs
   #:memory-job-store #:make-memory-job-store
   #:write-data #:read-data
   ;; the scheduler
   #:scheduler #:make-scheduler #:scheduler-store #:scheduler-holder #:scheduler-lease-seconds
   #:define-job #:schedule-once #:tick #:run-now #:run-job #:start #:stop #:next-wake
   #:scheduler-stopped #:unknown-job #:unknown-job-key #:unreadable-job-args
   ;; the run context a job function receives
   #:run-context #:run-id #:run-key #:run-trigger #:run-scheduled-for #:run-local-date
   #:run-args #:note-item-error #:stop-requested-p
   ;; for drivers
   #:scheduler-wake-function #:scheduler-driver-stop #:scheduler-clock-now))
