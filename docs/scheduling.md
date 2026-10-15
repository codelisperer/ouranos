# Scheduled jobs — `aion/schedule` and `mnemosyne/jobs`

`aion/schedule` runs an app's named jobs on schedules. The schedules, each job's next due time,
a lease that lets only one instance run a slot, and a log of every run live in a job store, so
they survive a redeploy and every instance of the app shares them. `mnemosyne/jobs` is the
store for Postgres and SQLite; `make-memory-job-store` is the store for tests and single-process
apps. Design and the maintainer's rulings: issue #689.

## Defining and running jobs

```lisp
(defpackage #:my-app/jobs
  (:use #:cl)
  (:local-nicknames (#:sched #:aion/schedule) (#:jobs #:mnemosyne/jobs)))

(defun send-reminders (run)
  (let ((sent 0))
    (dolist (reminder (due-reminders (sched:run-local-date run)))
      (handler-case (progn (send reminder) (incf sent))
        (error (e)
          (sched:note-item-error run (format nil "reminder ~A: ~A" (id-of reminder) (type-of e))))))
    (list :sent sent)))

(let* ((store (jobs:make-db-job-store pool))
       (scheduler (sched:make-scheduler store :keep-runs 500)))
  (sched:define-job scheduler "send-reminders" #'send-reminders
                    :schedule '(:daily (7 30) :zone "Europe/London"))
  (sched:start scheduler))
```

A job function takes the run context and the job's arguments. It returns a plist of counts,
which the run log keeps, or NIL. It calls `note-item-error` for each item that failed; the run
then finishes `:completed-with-errors` with the summaries in its error text, instead of failing.
A long job may poll `stop-requested-p` and return early when the app is shutting down.

Schedules are data:

| Form | Runs |
|---|---|
| `(:every 300)` | every 300 seconds, counted from the previous slot |
| `(:daily (7 30) :zone "Europe/London")` | every day at 07:30 London time |
| `(:weekly (:mon :thu) (9 0) :zone "America/New_York")` | Mondays and Thursdays at 09:00 New York time |
| `(:once universal-time)` | once, at or after that instant |

Without `:zone`, the time is UTC. On the day the clocks go forward, a slot in the skipped hour
runs at the first instant after it; on the day they go back, a slot in the repeated hour runs
once, at the earlier instant. `run-local-date` is the slot's date in the schedule's zone.

`schedule-once` stores a one-off run of a registered job function with arguments, which must be
plain data (numbers, strings, symbols, lists) because they are stored. A one-off that completes
is removed from the store; one that fails stays, not due, for an operator to run again with
`run-job`.

`run-now` starts a job off its schedule on the pool and returns its run id, or the id of the run
already in progress; `run-job` runs it on the calling thread and returns the finished run. Both
leave the schedule alone.

`start` ticks once, then drives the scheduler from a thread; `aion/schedule/uv:start` drives it
from a libuv timer on a loop of its own. `stop` starts no more runs, stops the driver, and waits
for the runs in progress, renewing their leases while it waits, all within `:timeout` seconds. It
returns `:stopped`, or `:timed-out` with the keys of the jobs still running; a driver still busy in
a tick at the timeout is left in place, and a later `stop` waits for it again.

## Several instances

Each instance runs its own scheduler over the same store. When a slot falls due, every instance
asks the store for the job's lease; the store gives it to the first, and moves the next due time
in the same step, so the others find the job no longer due. A slot missed while no instance was
running (a deploy, an outage) runs once when an instance starts, with trigger `:catch-up`; ten
missed slots of an `:every` job still give one run.

While a run is in progress, its instance renews the lease every third of `:lease-seconds`
(default 300). A job that falls due again while its previous run on the same instance is still
going gets a `:skipped` run in the log instead of a second concurrent run.

## A job must tolerate running twice

When an instance dies during a run, its lease stops being renewed and expires. The next instance
to tick marks that run `:abandoned` and runs the job again, with trigger `:retry`, for the same
slot. The first run may have done part or all of its work before the instance died, so write a
job so that running it a second time does no harm: record what it has sent or changed, and skip
what is already done.

## Keep the instances' clocks synchronised

Lease times are written from each instance's own clock. An instance whose clock is ahead of
another's sees that instance's lease expire early, by the difference. Because the lease is
renewed every third of its length, a difference of up to about a third of `:lease-seconds` (100
seconds at the default) never lets a live run be taken over. Larger differences can start a
second run of a job while the first is still going. Run NTP or the platform's time service on
every host.

## The run log

`store-runs` lists a job's runs, newest first, each with its trigger (`:schedule`, `:catch-up`,
`:retry`, `:run-now`), outcome (`:running`, `:completed`, `:completed-with-errors`, `:failed`,
`:skipped`, `:abandoned`), counts, and error text (at most 1000 characters). The log grows by one
row per run. `make-scheduler`'s `:keep-runs n` keeps the newest n runs of each job after every
run; `store-prune-runs` with `:before` deletes runs older than an instant, for an app that would
rather prune from a job of its own. Neither deletes a run that is still `:running`.

## Tables

`mnemosyne/jobs` keeps jobs in `aion_jobs` and runs in `aion_job_runs`, with an index on
`(job_key, started_at)`. `jobs-ddl` returns the three statements, the same on Postgres and
SQLite, for the app's migrations (see [migrations.md](migrations.md) §5). Without `:ensure t`,
`make-db-job-store` reads both tables once and signals `missing-job-tables` when it cannot, so a
missing migration stops the app at start. Other table names are passed as `:jobs-table` and
`:runs-table`, to both `make-db-job-store` and `jobs-ddl`.
