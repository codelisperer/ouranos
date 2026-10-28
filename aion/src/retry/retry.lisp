;;;; retry.lisp --- aion/retry: the policy, its schedule, and the runner (#79).
;;;;
;;;; THE POLICY IS DATA AND THE SCHEDULE IS PURE. RETRY-DELAY takes the random value it uses as
;;;; an argument, so a test gives it a fixed one and the hand-written schedules elsewhere in the
;;;; tree can call it with :JITTER :NONE and get exactly the numbers they compute today.
;;;;
;;;; THE RUNNER IS RESTARTS, NOT A HIDDEN LOOP. Each attempt runs inside a RETRY restart. On a
;;;; condition the policy finds retryable, the runner first SIGNALs RETRY-SCHEDULED, inside the
;;;; restarts GIVE-UP and RETRY-NOW, so a handler outside can stop the retrying or skip the wait;
;;;; then it waits and invokes RETRY. When the policy allows no more attempts, the runner's
;;;; handler declines and the original condition carries on to the caller's handlers, unchanged,
;;;; with the RETRY restart still there for a handler or the debugger to take by hand.
;;;;
;;;; THE WAIT BLOCKS ITS THREAD. A thread that serves other work, such as an aion/uv loop, binds
;;;; AION/DYNAMIC:*BLOCKING-FORBIDDEN*, and the runner refuses to start there.

(in-package #:aion/retry)

;;; --- which conditions are worth another attempt ------------------------------------------

(defgeneric transience (condition)
  (:documentation "Whether CONDITION is worth another attempt, and how safe that attempt is:

  :TRANSIENT  the failure is temporary and the request was not acted on, so sending it again is
              safe for any request. A 429, or a connection that was refused.
  :UNKNOWN    the failure may be temporary, but the server may already have acted on the
              request, so only a request that is safe to send twice should be sent again. A 502,
              or a read timeout after the request was sent.
  NIL         the failure is not temporary, or nothing is known about it.

A method belongs with the condition type, in the system that defines it. The default is NIL.")
  (:method ((condition condition)) nil))

(defun transient-p (condition)
  "True when TRANSIENCE of CONDITION is :TRANSIENT: a failure after which sending the request
again is safe whatever the request does. For aion/http-client's HTTP-ERROR that is a status of
408, 425, 429, 503 or 529, or a connection that failed before the request was sent. The default
RETRYABLE of MAKE-RETRY-POLICY."
  (eq (transience condition) :transient))

(defun transient-or-unknown-p (condition)
  "True when TRANSIENCE of CONDITION is :TRANSIENT or :UNKNOWN. For aion/http-client's HTTP-ERROR
that adds 500, 502 and 504, and a failure after the request was sent, such as a read timeout. Use
it only for a request that is safe to send twice: a GET, or a request with an idempotency key."
  (and (member (transience condition) '(:transient :unknown)) t))

(defgeneric retry-after (condition)
  (:documentation "The seconds the server asked the caller to wait before trying again, as a
non-negative real, or NIL when it said nothing. The runner waits at least this long, and does not
retry when it is longer than the policy's MAX-DELAY or would end past its DEADLINE. A method
belongs with the condition type; the default is NIL.")
  (:method ((condition condition)) nil))

(defparameter +months+ '("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(defun %parse-http-date (string)
  "The universal time of STRING in HTTP's preferred date format (RFC 9110's IMF-fixdate, as in
\"Sun, 06 Nov 1994 08:49:37 GMT\"), or NIL when it is not one."
  (let ((parts (uiop:split-string string :separator " ")))
    (when (and (= 6 (length parts)) (string= "GMT" (sixth parts)))
      (let* ((day (ignore-errors (parse-integer (second parts))))
             (month (position (third parts) +months+ :test #'string=))
             ;; Four digits: IMF-fixdate has no two-digit year, which ENCODE-UNIVERSAL-TIME would
             ;; otherwise read as a year within 50 of now.
             (year (and (= 4 (length (fourth parts)))
                        (ignore-errors (parse-integer (fourth parts)))))
             (clock (uiop:split-string (fifth parts) :separator ":"))
             (hms (and (= 3 (length clock))
                       (mapcar (lambda (p) (ignore-errors (parse-integer p))) clock))))
        (when (and day month year hms (every #'integerp hms)
                   (<= 1 day 31) (<= 0 (first hms) 23) (<= 0 (second hms) 59)
                   (<= 0 (third hms) 60))
          (ignore-errors
           (encode-universal-time (min 59 (third hms)) (second hms) (first hms)
                                  day (1+ month) year 0)))))))

(defun parse-retry-after (value &optional (now (get-universal-time)))
  "The seconds an HTTP Retry-After header VALUE asks the caller to wait, or NIL.

VALUE is delay-seconds (\"120\") or an HTTP-date in the preferred format (\"Sun, 06 Nov 1994
08:49:37 GMT\"), which is read relative to NOW, a universal time, and gives 0 when it has passed.
NIL, an empty string, a negative number, the two obsolete date formats and anything else give
NIL, which the runner treats as no request to wait."
  (when (and (stringp value) (plusp (length value)))
    (let ((v (string-trim '(#\Space #\Tab) value)))
      (cond ((and (plusp (length v)) (every #'digit-char-p v))
             (parse-integer v))
            (t (let ((time (%parse-http-date v)))
                 (and time (max 0 (- time now)))))))))

;;; --- the policy -------------------------------------------------------------------------

(defstruct (retry-policy (:constructor %make-retry-policy) (:copier nil) (:predicate retry-policy-p))
  "How to retry: see MAKE-RETRY-POLICY. Every slot is read-only."
  (name nil :read-only t)
  (max-attempts 3 :read-only t)
  (base-delay 0.5 :read-only t)
  (multiplier 2 :read-only t)
  (max-delay 30 :read-only t)
  (jitter :full :read-only t)
  (deadline nil :read-only t)
  (retryable #'transient-p :read-only t))

(defmethod print-object ((policy retry-policy) stream)
  (print-unreadable-object (policy stream :type t :identity t)
    (format stream "~@[~S ~]~D attempt~:P" (retry-policy-name policy)
            (retry-policy-max-attempts policy))))

(defun make-retry-policy (&key name (max-attempts 3) (base-delay 0.5) (multiplier 2)
                               (max-delay 30) (jitter :full) deadline (retryable #'transient-p))
  "A RETRY-POLICY, checked.

  NAME          a string naming the policy in log lines, or NIL.
  MAX-ATTEMPTS  attempts in all, the first included: a positive integer. 1 means no retry.
  BASE-DELAY    seconds before the second attempt, before jitter: a non-negative real.
  MULTIPLIER    each later delay is the previous one times this: a real of at least 1.
  MAX-DELAY     no computed delay is longer than this, in seconds; a server's Retry-After that
                is longer stops the retrying instead (see RETRY-AFTER).
  JITTER        :FULL, a random delay from 0 up to the computed one (the default); :EQUAL, half
                the computed delay plus a random part of the other half; or :NONE.
  DEADLINE      seconds from the start of the first attempt after which no retry starts, or NIL
                for none. It does not cut short an attempt that is running; that is the call's
                own timeout's job.
  RETRYABLE     which conditions are retried: a function of the condition, or a list of
                condition type specifiers. The default is TRANSIENT-P, which retries only
                failures after which sending the request again is safe for any request.

Signals TYPE-ERROR for a value outside these."
  (check-type name (or null string))
  (check-type max-attempts (integer 1))
  (check-type base-delay (real 0))
  (check-type multiplier (real 1))
  (check-type max-delay (real 0))
  (check-type jitter (member :full :equal :none))
  (check-type deadline (or null (real (0))))
  (check-type retryable (or function symbol list))
  (%make-retry-policy :name name :max-attempts max-attempts :base-delay base-delay
                      :multiplier multiplier :max-delay max-delay :jitter jitter
                      :deadline deadline :retryable retryable))

(defun retry-delay (policy attempt random)
  "The seconds to wait before attempt number ATTEMPT under POLICY, where 2 is the first retry,
given RANDOM, a real in [0, 1) that the jitter uses. Pure: the same arguments give the same
delay. The computed delay is BASE-DELAY times MULTIPLIER to the power ATTEMPT minus 2, capped at
MAX-DELAY, and then:

  :NONE   that delay;
  :FULL   that delay times RANDOM;
  :EQUAL  half that delay plus half of it times RANDOM."
  (check-type attempt (integer 2))
  (let* ((d (min (retry-policy-max-delay policy)
                 (* (retry-policy-base-delay policy)
                    ;; Stop multiplying once past the cap, so a large ATTEMPT does not compute a
                    ;; huge power only to throw it away.
                    (loop with factor = 1
                          repeat (- attempt 2)
                          while (< (* (retry-policy-base-delay policy) factor)
                                   (retry-policy-max-delay policy))
                          do (setf factor (* factor (retry-policy-multiplier policy)))
                          finally (return factor))))))
    (ecase (retry-policy-jitter policy)
      (:none d)
      (:full (* d random))
      (:equal (+ (/ d 2) (* (/ d 2) random))))))

(defun %retryable-p (policy condition)
  (let ((r (retry-policy-retryable policy)))
    (if (listp r)
        (some (lambda (type) (typep condition type)) r)
        (funcall r condition))))

;;; --- the runner -------------------------------------------------------------------------

(define-condition retry-scheduled (condition)
  ((failure :initarg :condition :reader retry-scheduled-condition)
   (attempt :initarg :attempt :reader retry-scheduled-attempt)
   (delay :initarg :delay :reader retry-scheduled-delay)
   (policy :initarg :policy :reader retry-scheduled-policy))
  (:report (lambda (c s)
             (format s "attempt ~D failed with ~S; retrying in ~,3F s"
                     (1- (retry-scheduled-attempt c)) (type-of (retry-scheduled-condition c))
                     (retry-scheduled-delay c))))
  (:documentation "Signalled, with SIGNAL, before the runner waits and tries again. CONDITION is
the failure, ATTEMPT the number of the attempt about to start, DELAY the seconds it will wait.
Not an error: ignoring it lets the retry go ahead. A handler can take the restart GIVE-UP, after
which CONDITION carries on as if there were no policy, or RETRY-NOW, which skips the wait."))

(define-condition retry-would-block (error)
  ((reason :initarg :reason :reader retry-would-block-reason))
  (:report (lambda (c s)
             (format s "WITH-RETRY would wait between attempts on ~A, which must not block; run the retrying call on another thread"
                     (retry-would-block-reason c))))
  (:documentation "Signalled by WITH-RETRY, before the first attempt, when the current thread
must not block (AION/DYNAMIC:*BLOCKING-FORBIDDEN*, which aion/uv binds on its loop threads) and
the policy allows a retry."))

(defvar *random-lock* (sb-thread:make-mutex :name "aion/retry random"))
(defvar *random-state-for-jitter* nil
  "The state the jitter draws from, or NIL until the first draw in this process seeds it. Jitter
needs spread, not secrecy, so this is CL:RANDOM and not aion/random, which would put a crypto
library on every retrying system's load path.

Seeded on first use, not when the system loads, and reset to NIL whenever an image starts
(%FORGET-RANDOM-STATE in SB-EXT:*INIT-HOOKS*). A state made at load time would be saved into an
image built with SAVE-LISP-AND-DIE, and every process started from that image would then draw
the same jitter, so two replicas refused together would retry together.")

(defun %forget-random-state ()
  "Drop the jitter's random state, so the next draw seeds a new one. Run when an image starts."
  (sb-thread:with-mutex (*random-lock*)
    (setf *random-state-for-jitter* nil)))

(pushnew '%forget-random-state sb-ext:*init-hooks*)

(defun %random-unit ()
  (sb-thread:with-mutex (*random-lock*)
    (random 1d0 (or *random-state-for-jitter*
                    (setf *random-state-for-jitter* (make-random-state t))))))

(defvar *random-function* #'%random-unit
  "A function of no arguments returning a real in [0, 1), for the jitter. Tests bind it.")

(defvar *sleep-function* #'sleep
  "A function of one argument, the seconds to wait. Tests bind it.")

(defun %ms (seconds) (round (* 1000 seconds)))

(defun %elapsed (start)
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(defun %type-name (condition)
  (string-downcase (prin1-to-string (type-of condition))))

(defun %next-wait (policy condition attempt start)
  "The seconds to wait before the attempt after ATTEMPT, or NIL when the policy allows no retry
for CONDITION, logging why at :info when the reason is the policy's limits."
  (let ((next (1+ attempt)))
    (cond
      ((not (%retryable-p policy condition)) nil)
      ((> next (retry-policy-max-attempts policy))
       (log:info "retry not taken" :reason "attempts" :policy (retry-policy-name policy)
                                   :attempt attempt :condition (%type-name condition)
                                   :max-attempts (retry-policy-max-attempts policy))
       nil)
      (t
       (let* ((computed (retry-delay policy next (funcall *random-function*)))
              (asked (retry-after condition))
              (deadline (retry-policy-deadline policy)))
         (cond
           ((and asked (> asked (retry-policy-max-delay policy)))
            (log:info "retry not taken" :reason "retry-after longer than max-delay"
                                        :policy (retry-policy-name policy) :attempt attempt
                                        :condition (%type-name condition)
                                        :retry-after-s asked
                                        :max-delay-s (retry-policy-max-delay policy))
            nil)
           (t
            (let ((wait (if asked (max computed asked) computed)))
              (cond ((and deadline (> (+ (%elapsed start) wait) deadline))
                     (log:info "retry not taken" :reason "deadline"
                                                 :policy (retry-policy-name policy)
                                                 :attempt attempt
                                                 :condition (%type-name condition)
                                                 :wait-ms (%ms wait) :deadline-s deadline
                                                 :retry-after-s asked)
                     nil)
                    (t wait))))))))))

(defun %on-failure (policy condition attempt start retry)
  "The runner's handler: wait and invoke RETRY, or return, which declines the condition."
  (let ((wait (%next-wait policy condition attempt start)))
    (when wait
      (restart-case
          (signal 'retry-scheduled :condition condition :attempt (1+ attempt) :delay wait
                                   :policy policy)
        (give-up ()
          :report "Stop retrying, and let the failure carry on."
          (return-from %on-failure nil))
        (retry-now ()
          :report "Try again now, without waiting."
          (setf wait 0)))
      (log:info "retrying" :policy (retry-policy-name policy) :attempt (1+ attempt)
                           :condition (%type-name condition) :wait-ms (%ms wait))
      (when (plusp wait) (funcall *sleep-function* wait))
      (invoke-restart retry))))

(defun call-with-retry (policy thunk)
  "THUNK's values, calling it again under POLICY while it fails with a retryable condition.
See WITH-RETRY."
  (check-type policy retry-policy)
  (when (and aion/dynamic:*blocking-forbidden* (> (retry-policy-max-attempts policy) 1))
    (error 'retry-would-block :reason aion/dynamic:*blocking-forbidden*))
  (let ((start (get-internal-real-time))
        (attempt 0))
    (loop
      (incf attempt)
      (let ((results
              (restart-case
                  ;; This attempt's own RETRY restart, found before THUNK runs, so a RETRY that
                  ;; THUNK establishes itself, such as a nested WITH-RETRY's, is never taken by
                  ;; mistake.
                  (let ((retry (find-restart 'retry))
                        (this-attempt attempt))
                    (handler-bind ((error (lambda (c)
                                            (%on-failure policy c this-attempt start retry))))
                      (cons :done (multiple-value-list (funcall thunk)))))
                (retry ()
                  :report "Run the body again now."
                  :again))))
        (when (consp results)
          (return (values-list (rest results))))))))

(defmacro with-retry ((policy) &body body)
  "Run BODY, and run it again under POLICY (a RETRY-POLICY) while it signals an error POLICY
finds retryable. Returns BODY's values.

Before each retry it signals RETRY-SCHEDULED, inside the restarts GIVE-UP and RETRY-NOW, then
waits RETRY-DELAY, or at least the condition's RETRY-AFTER, and logs the retry at :info. When
POLICY allows no further attempt, because the condition is not retryable, the attempts are used,
the server's Retry-After is longer than MAX-DELAY or the wait would end past DEADLINE, the
condition is not caught: it reaches the caller's handlers unchanged, and the restart RETRY is
still available to run BODY once more by hand. The last three reasons are logged at :info.

BODY must be safe to run again after a failure. With the default RETRYABLE, TRANSIENT-P, only
failures after which the request was not acted on are retried.

THE WAIT BLOCKS THE THREAD. Do not use it on a thread other work waits for, such as an aion/uv
loop thread or a handler that hyperion's :uv server runs on its loop: there it signals
RETRY-WOULD-BLOCK before the first attempt, when POLICY allows a retry."
  `(call-with-retry ,policy (lambda () ,@body)))
