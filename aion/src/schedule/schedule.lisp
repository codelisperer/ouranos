;;;; schedule.lisp --- schedule forms, the next due time, and clocks (#689).
;;;;
;;;; A schedule is plain data, so the store can keep it as text and read it back after a
;;;; redeploy:
;;;;
;;;;   (:every SECONDS)                            every SECONDS, counted from the previous slot
;;;;   (:daily (HOUR MINUTE) [:zone NAME])         every day at that local time
;;;;   (:weekly (DAY ...) (HOUR MINUTE) [:zone NAME])  those weekdays at that local time
;;;;   (:once UNIVERSAL-TIME)                      one run, at or after that instant
;;;;
;;;; DAY is one of :MON :TUE :WED :THU :FRI :SAT :SUN. NAME is an aion/tz zone name; without
;;;; one, the time is UTC. Times are CL universal time, integer seconds, as in the rest of the
;;;; tree. Everything here is a pure function of its arguments.

(in-package #:aion/schedule)

(define-condition invalid-schedule (error)
  ((form :initarg :form :reader invalid-schedule-form)
   (reason :initarg :reason :reader invalid-schedule-reason))
  (:report (lambda (c s)
             (format s "aion/schedule: ~S is not a schedule: ~A"
                     (invalid-schedule-form c) (invalid-schedule-reason c)))))

(defparameter +weekdays+ '(:mon :tue :wed :thu :fri :sat :sun)
  "In the order DECODE-UNIVERSAL-TIME numbers them, Monday first.")

(defun %bad (form reason &rest args)
  (error 'invalid-schedule :form form :reason (apply #'format nil reason args)))

(defun %check-time-of-day (form time)
  (unless (and (consp time) (= 2 (length time))
               (typep (first time) '(integer 0 23)) (typep (second time) '(integer 0 59)))
    (%bad form "the time of day must be (HOUR MINUTE), with HOUR 0-23 and MINUTE 0-59, not ~S"
          time)))

(defun %check-zone (form zone)
  (when zone
    (unless (stringp zone)
      (%bad form "a zone is a zone name such as \"Europe/London\", not ~S" zone))
    ;; Signals aion/tz's own condition for a zone this system does not have: at definition,
    ;; not at the moment the job would have run.
    (tz:find-zone zone)))

(defun check-schedule (form)
  "Return FORM when it is a schedule this file understands; otherwise signal INVALID-SCHEDULE.
A zone this system does not have signals aion/tz's UNKNOWN-ZONE."
  (unless (and (consp form) (keywordp (first form)))
    (%bad form "a schedule is a list that starts with :EVERY, :DAILY, :WEEKLY or :ONCE"))
  (case (first form)
    (:every
     (unless (and (= 2 (length form)) (typep (second form) '(integer 1)))
       (%bad form "(:EVERY SECONDS) takes a positive integer number of seconds")))
    (:daily
     (unless (member (length form) '(2 4))
       (%bad form "(:DAILY (HOUR MINUTE)) takes a time of day and an optional :ZONE"))
     (%check-time-of-day form (second form))
     (when (= 4 (length form))
       (unless (eq :zone (third form)) (%bad form "the only option is :ZONE"))
       (%check-zone form (fourth form))))
    (:weekly
     (unless (member (length form) '(3 5))
       (%bad form "(:WEEKLY (DAY ...) (HOUR MINUTE)) takes days, a time of day and an optional :ZONE"))
     (let ((days (second form)))
       (unless (and (consp days) (every (lambda (d) (member d +weekdays+)) days))
         (%bad form "the days must be a non-empty list of ~{~S~^ ~}" +weekdays+)))
     (%check-time-of-day form (third form))
     (when (= 5 (length form))
       (unless (eq :zone (fourth form)) (%bad form "the only option is :ZONE"))
       (%check-zone form (fifth form))))
    (:once
     (unless (and (= 2 (length form)) (typep (second form) '(integer 0)))
       (%bad form "(:ONCE UNIVERSAL-TIME) takes a universal time")))
    (t (%bad form "unknown schedule kind ~S" (first form))))
  form)

(defun %zone-of (form)
  (getf (case (first form) (:daily (cddr form)) (:weekly (cdddr form))) :zone))

(defun %local-date (ut zone)
  "The local (YEAR MONTH DAY) of the instant UT in ZONE (UTC when ZONE is NIL), and the
weekday index, Monday 0."
  (let ((offset (if zone (tz:offset zone ut) 0)))
    (multiple-value-bind (s mi h d mo y dow) (decode-universal-time (+ ut offset) 0)
      (declare (ignore s mi h))
      (values (list y mo d) dow))))

(defun %local-instant (zone y mo d h mi)
  "The instant of local time Y-MO-D H:MI in ZONE. A local time that does not exist (the clocks
went forward over it) is the first instant after the change; one that happens twice (the clocks
went back) is the earlier of the two, so a daily slot happens once on either day."
  (if zone
      (values (tz:local-to-universal zone y mo d h mi 0))
      (encode-universal-time 0 mi h d mo y 0)))

(defun %slot-on-or-after-date (form after)
  "The first local-time slot of FORM strictly after AFTER, and its local date."
  (destructuring-bind (days time) (if (eq (first form) :daily)
                                      (list +weekdays+ (second form))
                                      (list (second form) (third form)))
    (let ((zone (%zone-of form)))
      (multiple-value-bind (date) (%local-date after zone)
        (destructuring-bind (y mo d) date
          ;; Noon UTC on the start date, then whole days: noon keeps every step on the right
          ;; calendar day whatever the zone's offset. Eight days cover a weekly schedule whose
          ;; only day is today, with today's slot already past.
          (let ((noon (encode-universal-time 0 0 12 d mo y 0)))
            (loop for i from 0 to 8
                  do (multiple-value-bind (s mi h dd mm yy dow)
                         (decode-universal-time (+ noon (* i 86400)) 0)
                       (declare (ignore s mi h))
                       (when (member (nth dow +weekdays+) days)
                         (let ((ut (%local-instant zone yy mm dd (first time) (second time))))
                           (when (> ut after)
                             (return-from %slot-on-or-after-date
                               (values ut (list yy mm dd))))))))
            (error "aion/schedule: no slot of ~S within eight days of ~D" form after)))))))

(defun next-due (form after &key previous)
  "The first slot of the schedule FORM strictly after the instant AFTER, or NIL when FORM has
none left. The second value is the slot's local (YEAR MONTH DAY) in the schedule's zone.

For (:EVERY N), PREVIOUS is the slot the interval counts from: the result is PREVIOUS + k*N for
the smallest k that is after AFTER, so missed slots are skipped, not queued, and the interval
keeps its phase. Without PREVIOUS it is AFTER + N. For (:ONCE T), it is T when T is after AFTER,
else NIL."
  (ecase (first form)
    (:every
     (let ((n (second form)))
       (values (if previous
                   (+ previous (* n (1+ (floor (max 0 (- after previous)) n))))
                   (+ after n))
               nil)))
    ((:daily :weekly) (%slot-on-or-after-date form after))
    (:once (let ((at (second form))) (values (and (> at after) at) nil)))))

(defun %local-date-of-slot (form ut)
  "The local (YEAR MONTH DAY) of the slot UT under FORM's zone (UTC when it has none)."
  (values (%local-date ut (and (member (first form) '(:daily :weekly)) (%zone-of form)))))

;;; --- clocks -----------------------------------------------------------------------------
;;;
;;; A clock is a function of no arguments returning universal time, or a MANUAL-CLOCK, which a
;;; test moves by hand. The scheduler reads time only through CLOCK-NOW.

(defstruct (manual-clock (:constructor make-manual-clock (&optional (now 3990000000))))
  "A clock that says NOW until a test changes it."
  (now 0 :type integer))

(defun clock-now (clock)
  (etypecase clock
    (manual-clock (manual-clock-now clock))
    (function (funcall clock))
    (symbol (funcall clock))))

(defun clock-advance (clock seconds)
  "Move CLOCK forward by SECONDS. Returns its new time."
  (incf (manual-clock-now clock) seconds))

(defun clock-set (clock ut)
  "Set CLOCK to UT. Returns UT."
  (setf (manual-clock-now clock) ut))
