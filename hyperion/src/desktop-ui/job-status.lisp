;;;; job-status.lisp --- the typed core of the job runner: a job's status, the events that
;;;; change it, and the function that applies one event to one status (#1218).
;;;;
;;;; Everything here is pure. The CL shell (jobs.lisp) runs the threads. When something happens
;;;; to a job it takes one of the event values below, calls NEXT-STATUS, and stores the status
;;;; it returns. The shell never looks inside a status: it reads it through STATUS-NAME and
;;;; STATUS-ENDED? (docs/coalton-patterns.md, section 7).

(cl:defpackage #:hyperion/desktop-ui/job-status
  (:use #:coalton #:coalton-prelude)
  (:documentation
   "A job's status, the events that change it, and NEXT-STATUS, the pure function from an
    event and a status to the next status.")
  (:export #:Job-Status #:Job-Event
           #:initial-status #:next-status
           #:return-event #:error-event #:cancel-event #:time-limit-event
           #:status-name #:status-ended?))

(cl:in-package #:hyperion/desktop-ui/job-status)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;; Where a job is. Running is the only status a job leaves; the other four are final.
  (define-type Job-Status
    Running      ; its function has not returned yet
    Done         ; its function returned
    Failed       ; its function signalled a serious condition, or left without returning
    Cancelled    ; CANCEL-JOB stopped it
    TimedOut)    ; it ran for longer than its time limit

  ;; What can happen to a running job.
  (define-type Job-Event
    Returned
    Errored
    CancelRequested
    LimitReached)

  (declare next-status (Job-Event * Job-Status -> Job-Status))
  (define (next-status event status)
    "The status a job has after EVENT. Only a running job changes. A job that has ended keeps
its status, so when a cancel and a return arrive close together, the one applied first decides."
    (match status
      ((Running)
       (match event
         ((Returned) Done)
         ((Errored) Failed)
         ((CancelRequested) Cancelled)
         ((LimitReached) TimedOut)))
      (_ status)))

  ;; --- values the CL shell uses ---

  (declare initial-status Job-Status)
  (define initial-status Running)

  (declare return-event Job-Event)
  (define return-event Returned)

  (declare error-event Job-Event)
  (define error-event Errored)

  (declare cancel-event Job-Event)
  (define cancel-event CancelRequested)

  (declare time-limit-event Job-Event)
  (define time-limit-event LimitReached)

  ;; --- accessors the CL shell calls ---

  (declare status-name (Job-Status -> String))
  (define (status-name status)
    "The word for STATUS that the shell turns into a keyword and the inspector shows."
    (match status
      ((Running) "running")
      ((Done) "done")
      ((Failed) "failed")
      ((Cancelled) "cancelled")
      ((TimedOut) "timed-out")))

  (declare status-ended? (Job-Status -> Boolean))
  (define (status-ended? status)
    "True for every status but Running."
    (match status
      ((Running) False)
      (_ True))))
