;;;; observe.lisp --- running distil automatically over a thread, off the request path (#317).
;;;;
;;;; `praxeon/distil' turns a window of a transcript into observations, and nothing called it.
;;;; An OBSERVER is what calls it. It is told a thread's history after each turn, and it keeps
;;;; the thread's OBSERVED MARK, the first message not yet distilled. When the messages past the
;;;; mark reach STEP estimated tokens, it distils them on a thread of its own, one STEP-sized
;;;; window at a time, writes the result into the thread's scope, and moves the mark. The call
;;;; that tells it about the turn returns at once, so a member's request never waits for a
;;;; distillation (#317's first acceptance item).
;;;;
;;;; THE MARK MOVES ONLY PAST A WINDOW THAT WAS WRITTEN, OR ONE GIVEN UP ON (#462's review). A
;;;; provider error, a store error part-way through the writes, or a failed support check leaves
;;;; the mark where it was, and the window is tried again, up to MAX-ATTEMPTS times. A retry does
;;;; not store an observation twice: what an earlier attempt already wrote, with the same
;;;; content and the same message range, is not written again. A window still failing after
;;;; MAX-ATTEMPTS is given up on: its range goes into OBSERVER-SKIPPED, so the prompt keeps those
;;;; messages raw (#317, step C) rather than losing them, and the mark moves past it.
;;;;
;;;; THE MARK SURVIVES A RESTART. A new observer takes it from the store: the last message the
;;;; thread's observations cite (their provenance's THROUGH). So an app that makes an observer
;;;; per request, or restarts, does not distil the thread again from the start.
;;;;
;;;; WHAT IT WRITES, AND WHAT IT DOES NOT.
;;;;
;;;;   - Every proposal becomes an observation of the THREAD, never a fact about the subject.
;;;;   - A proposal that claims to replace an existing thread observation replaces it only when
;;;;     the app's ACCEPT says so, as `apply-distillation' already requires.
;;;;   - A thread observation also becomes a fact about the subject only when the app's PROMOTE
;;;;     says so, and by default nothing is promoted, because a wrong fact about a person is then
;;;;     recalled in every conversation with them. A promoted fact is not stored twice. When a
;;;;     thread observation that was promoted is later corrected in the thread, the subject's
;;;;     fact is superseded by the correction only when PROMOTE-ACCEPT also says so; otherwise the
;;;;     correction is not promoted, so the subject never holds a fact and its correction as two
;;;;     current beliefs.
;;;;   - With a VERIFY provider, each window's proposals are checked against the window first:
;;;;     the content, the kind, the date and, above all, a claim to replace an earlier
;;;;     observation. The ones it does not support are dropped. It is a model call per window,
;;;;     so it is a setting, off by default; #317's benchmark measures what it buys.
;;;;
;;;; TURN NUMBERS ARE THE THREAD'S MESSAGE POSITIONS, counted from 1. An observation's provenance
;;;; names the conversation, the first message of its window as TURN, and the last as THROUGH.
;;;;
;;;; A THREAD OBSERVER SHARES ITS STORE WITH THE APP. `praxeon/memory''s in-memory store locks
;;;; every operation for that reason, and the SQL store holds a lock around each statement.

(in-package #:praxeon/observe)

(defparameter *step-tokens* 6000
  "How many estimated tokens of unobserved messages start a distillation, and the size of each
window, Mastra's step.")

(defclass observer ()
  ((provider :initarg :provider :reader observer-provider)
   (store :initarg :store :reader observer-store)
   (subject :initarg :subject :reader observer-subject)
   (thread :initarg :thread :reader observer-thread)
   (step :initarg :step :reader observer-step)
   (accept :initarg :accept :reader observer-accept)
   (promote :initarg :promote :reader observer-promote)
   (promote-accept :initarg :promote-accept :reader observer-promote-accept)
   (verify :initarg :verify :reader observer-verify)
   (distil-options :initarg :distil-options :reader observer-distil-options)
   (max-attempts :initarg :max-attempts :reader observer-max-attempts)
   (window-timeout :initarg :window-timeout :reader observer-window-timeout)
   (mark :initarg :mark :accessor observer-mark)
   (skipped :initform '() :accessor observer-skipped)
   (failures :initform 0 :accessor observer-failures)
   (last-error :initform nil :accessor observer-last-error)
   (worker :initform nil :accessor observer-worker)
   (started :initform nil :accessor observer-started)
   (stopping :initform nil :accessor observer-stopping)
   (lock :initform (bt:make-lock "praxeon-observer") :reader observer-lock))
  (:documentation "Distils one thread's messages into the thread's observations, a step at a time."))

(defun stored-mark (store subject thread)
  "The last message THREAD's observations about SUBJECT cite, superseded ones included: the mark
an observer resumes from. 0 when the thread has none."
  (reduce #'max (mem:observations-of store subject :thread thread :include-superseded t)
          :key (lambda (o) (let ((p (mem:observation-provenance o)))
                             (or (mem:provenance-through p) (mem:provenance-turn p))))
          :initial-value 0))

(defun make-observer (provider store subject thread
                      &key (step *step-tokens*) (accept (constantly nil)) (promote (constantly nil))
                           (promote-accept (constantly nil)) verify distil-options
                           (max-attempts 3) (window-timeout 300) mark)
  "An observer of THREAD (a string, usually the conversation's id) about SUBJECT, distilling
with PROVIDER into STORE, a PRAXEON/MEMORY:MEMORY-STORE.

STEP is the estimated tokens of unobserved messages that start a distillation, and the most one
window holds. ACCEPT is `apply-distillation''s: called with a proposal and the thread
observation it claims to replace, true to replace it. PROMOTE is called with each new thread
observation, true to also record it as a fact about SUBJECT. PROMOTE-ACCEPT is called with a
promoted correction and the subject's fact it would replace, true to supersede that fact.
VERIFY, a provider or NIL, checks each window's proposals against the window first.
DISTIL-OPTIONS is a plist passed to `distil', such as (:max-tokens 2048).

MAX-ATTEMPTS is how many times a window that fails is tried before it is given up on.
WINDOW-TIMEOUT is how many seconds a window may take before OBSERVER-STUCK-P says so. MARK, when
given, is where to start; by default it is taken from the store (STORED-MARK)."
  (check-type thread string)
  (unless (and (integerp step) (plusp step))
    (error 'praxeon/conditions:praxeon-error :detail (format nil ":step must be a positive integer, not ~S" step)))
  (unless (and (integerp max-attempts) (plusp max-attempts))
    (error 'praxeon/conditions:praxeon-error :detail (format nil ":max-attempts must be a positive integer, not ~S" max-attempts)))
  (make-instance 'observer :provider provider :store store :subject subject :thread thread
                           :step step :accept accept :promote promote :promote-accept promote-accept
                           :verify verify :distil-options distil-options
                           :max-attempts max-attempts :window-timeout window-timeout
                           :mark (or mark (stored-mark store subject thread))))

(defun unobserved (observer history)
  "The messages of HISTORY past OBSERVER's mark."
  (nthcdr (min (observer-mark observer) (length history)) history))

(defun observer-busy-p (observer)
  "Whether a distillation is running."
  (let ((w (observer-worker observer)))
    (and w (bt:thread-alive-p w))))

(defun observer-stuck-p (observer)
  "Whether a distillation has been running longer than OBSERVER-WINDOW-TIMEOUT seconds: a
provider call that does not return. While it is, OBSERVE-TURN starts nothing, and says so in
the log."
  (and (observer-busy-p observer)
       (observer-started observer)
       (> (- (get-universal-time) (observer-started observer)) (observer-window-timeout observer))))

(defun %window-end (history start step)
  "The end (exclusive) of the window from START in HISTORY: messages until they reach STEP
estimated tokens, and always at least one."
  (let ((tokens 0) (end start))
    (loop for m in (nthcdr start history)
          do (incf tokens (prompt:message-tokens m)) (incf end)
          until (>= tokens step))
    end))

(defun observe-turn (observer history &key flush)
  "Tell OBSERVER the thread's HISTORY, a list of praxeon/llm messages, after a turn. Returns at
once: T when it started a distillation, NIL otherwise.

It starts one when no distillation is running and the messages past the mark reach
OBSERVER-STEP estimated tokens, or, with FLUSH, when there is any message past the mark: FLUSH
is for the end of a conversation, whose last messages would otherwise never reach a step. The
history is copied here, so messages the app adds later are the next call's."
  (let ((snapshot (copy-list history)))
    (bt:with-lock-held ((observer-lock observer))
      (cond
        ((observer-stuck-p observer)
         (log:warn "memory observer stuck" :thread (observer-thread observer)
                                           :seconds (- (get-universal-time) (observer-started observer)))
         nil)
        ((observer-busy-p observer) nil)
        ((let ((window (unobserved observer snapshot)))
           (and window (or flush (>= (prompt:messages-tokens window) (observer-step observer)))))
         (setf (observer-started observer) (get-universal-time)
               (observer-stopping observer) nil)
         ;; THREAD-LIFETIME: continues the turn's unit of work, on its own thread so the turn
         ;; does not wait. It runs a praxeon model call, which reads praxeon's registered
         ;; dynamic bindings (#158), so it carries them. AWAIT-OBSERVER and STOP-OBSERVER join it.
         (setf (observer-worker observer)
               (bt:make-thread
                (aion/dynamic:inheriting (lambda () (%run observer snapshot flush)))
                :name "praxeon-observer"))
         t)
        (t nil)))))

(defun await-observer (observer &key (timeout 300))
  "Join OBSERVER's running distillation, waiting at most TIMEOUT seconds. Returns T when none is
running afterwards."
  (let ((w (observer-worker observer)))
    (when (and w (bt:thread-alive-p w))
      (sb-thread:join-thread w :default nil :timeout timeout))
    (not (observer-busy-p observer))))

(defun stop-observer (observer &key (timeout 30))
  "Stop OBSERVER at shutdown: it finishes the window it is on and starts no other. Waits at most
TIMEOUT seconds, then ends its thread. Returns T when it stopped in time."
  (setf (observer-stopping observer) t)
  (or (await-observer observer :timeout timeout)
      (let ((w (observer-worker observer)))
        (when (and w (bt:thread-alive-p w)) (ignore-errors (bt:destroy-thread w)))
        nil)))

;;; --- the windows ------------------------------------------------------------------------

(defun %run (observer history flush)
  "Distil HISTORY past the mark, one step-sized window at a time, until what is left is below a
step (or, with FLUSH, nothing is left), or the observer is stopped. An error here is recorded
and logged, never raised: an error no handler takes in this thread would end the process."
  (handler-case (%run-windows observer history flush)
    (error (e)
      (incf (observer-failures observer))
      (setf (observer-last-error observer) e)
      (log:error "memory observer stopped" :thread (observer-thread observer)
                                           :condition (string-downcase (princ-to-string (type-of e)))))))

(defun %run-windows (observer history flush)
  (loop
    (let* ((start (observer-mark observer))
           (left (nthcdr start history)))
      (when (or (null left) (observer-stopping observer)
                (and (not flush) (< (prompt:messages-tokens left) (observer-step observer))))
        (return))
      (let ((end (%window-end history start (observer-step observer))))
        (setf (observer-started observer) (get-universal-time))
        (%observe-window observer (subseq history start end) start end)))))

(defun %observe-window (observer window start end)
  "Distil WINDOW, the messages from position START (from 0) to END, and write what it yields,
trying up to OBSERVER-MAX-ATTEMPTS times. Moves the mark to END when it is written or given up
on. Never raises: this runs on a thread of its own."
  (let ((began (get-internal-real-time)) (written 0) (outcome :written))
    (loop for attempt from 1 to (observer-max-attempts observer)
          do (handler-case
                 (progn (setf written (%distil-and-write observer window start end))
                        (setf outcome :written)
                        (return))
               (error (e)
                 (incf (observer-failures observer))
                 (setf (observer-last-error observer) e
                       outcome :skipped))))
    (bt:with-lock-held ((observer-lock observer))
      (when (eq outcome :skipped)
        (push (cons start end) (observer-skipped observer)))
      (setf (observer-mark observer) (max (observer-mark observer) end)))
    (log:info "memory observer window" :thread (observer-thread observer)
                                       :from (1+ start) :through end :outcome outcome :written written
                                       :failures (observer-failures observer)
                                       :ms (round (* 1000 (- (get-internal-real-time) began))
                                                  internal-time-units-per-second))))

(define-condition window-not-distilled (praxeon/conditions:praxeon-error) ()
  (:documentation "distil could not read the model's answer for a window; carries its reason."))

(defun %distil-and-write (observer window start end)
  "One attempt at a window. Returns how many observations it wrote, or signals."
  (let* ((store (observer-store observer))
         (subject (observer-subject observer))
         (thread (observer-thread observer))
         (known (mem:observations-of store subject :thread thread))
         (provenance (mem:make-provenance thread (1+ start) :through end)))
    (multiple-value-bind (distillation condition)
        (apply #'distil:distil (observer-provider observer) subject window
               :known known :today (get-universal-time) (observer-distil-options observer))
      (unless distillation
        (error 'window-not-distilled
               :detail (format nil "the model's answer could not be read: ~A" condition)))
      (let* ((checked (if (and (observer-verify observer) (distil:distillation-proposals distillation))
                          (supported-proposals (observer-verify observer) window distillation :known known)
                          distillation))
             ;; WHAT AN EARLIER ATTEMPT AT THIS WINDOW ALREADY WROTE is not written again: an
             ;; observation of this thread with the same content and the same message range.
             (done (remove-if-not (lambda (o)
                                    (let ((p (mem:observation-provenance o)))
                                      (and (= (mem:provenance-turn p) (1+ start))
                                           (eql (mem:provenance-through p) end))))
                                  (mem:observations-of store subject :thread thread :include-superseded t)))
             (fresh (distil:make-distillation
                     subject
                     (remove-if (lambda (p) (find (distil:proposal-content p) done
                                                  :key #'mem:observation-content :test #'string=))
                                (distil:distillation-proposals checked))))
             (written (distil:apply-distillation store fresh :provenance provenance
                                                             :accept (observer-accept observer)
                                                             :thread thread)))
        (dolist (o written) (%maybe-promote observer o provenance))
        (length written)))))

(defun %promoted-fact (store subject thread-observation)
  "The current fact about SUBJECT promoted from THREAD-OBSERVATION: one with its content and its
provenance's conversation and range, which promotion copies."
  (let ((p (mem:observation-provenance thread-observation)))
    (find-if (lambda (f)
               (let ((q (mem:observation-provenance f)))
                 (and (string= (mem:observation-content f) (mem:observation-content thread-observation))
                      (string= (mem:provenance-conversation q) (mem:provenance-conversation p))
                      (= (mem:provenance-turn q) (mem:provenance-turn p))
                      (eql (mem:provenance-through q) (mem:provenance-through p)))))
             (mem:observations-of store subject))))

(defun %maybe-promote (observer observation provenance)
  "Record OBSERVATION, a new thread observation, as a fact about the subject when PROMOTE says so.
Not twice: an identical current fact already there is left alone. When OBSERVATION corrects a
thread observation that was promoted, the subject's fact is superseded only when PROMOTE-ACCEPT
also says so; otherwise nothing is promoted."
  (let* ((store (observer-store observer))
         (subject (observer-subject observer)))
    (when (funcall (observer-promote observer) observation)
      (let* ((replaced-id (mem:observation-supersedes observation))
             (replaced (and replaced-id
                            (find replaced-id (mem:observations-of store subject :thread (observer-thread observer)
                                                                                 :include-superseded t)
                                  :key #'mem:observation-id :test #'string=)))
             (old-fact (and replaced (%promoted-fact store subject replaced))))
        (cond
          (old-fact
           (when (funcall (observer-promote-accept observer) observation old-fact)
             (mem:supersede store old-fact (mem:observation-content observation)
                            :provenance provenance :kind (mem:observation-kind observation)
                            :valid-from (mem:observation-valid-from observation))))
          ((find (mem:observation-content observation) (mem:observations-of store subject)
                 :key #'mem:observation-content :test #'string=))
          (t (mem:remember store subject (mem:observation-content observation)
                           :provenance provenance
                           :kind (mem:observation-kind observation)
                           :valid-from (mem:observation-valid-from observation))))))))

;;; --- the support check -------------------------------------------------------------------

(defun %support-spec ()
  (llm:make-tool-spec
   :name "record_supported"
   :description "Record which numbered observations the conversation supports."
   :schema (jzon:parse "{\"type\":\"object\",\"properties\":{\"supported\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"},\"description\":\"The numbers of the observations the conversation supports.\"}},\"required\":[\"supported\"]}")
   ;; ITEMS IS DECLARED BECAUSE SOME PROVIDERS REFUSE AN ARRAY PARAMETER WITHOUT IT (OpenAI's and
   ;; Gemini's function calling), and praxeon's schema check does not read it, so this validator
   ;; is what holds the answer to it; without one, GENERATE-STRUCTURED refuses the spec.
   :validators (list (lambda (arguments)
                       (let ((numbers (and (hash-table-p arguments) (gethash "supported" arguments))))
                         (unless (and (vectorp numbers) (not (stringp numbers)) (every #'integerp numbers))
                           "`supported' must be an array of whole numbers"))))))

(defparameter *support-instructions*
  "Above is part of a conversation. Below are observations another pass drew from it, numbered. Record the numbers of the ones the conversation supports. An observation is supported only if the conversation states or clearly implies its content, its kind is right, any date it gives is the one the conversation gives, and, when it says it replaces an earlier observation, the conversation shows that the earlier one no longer holds. Leave out any that adds details, names, dates or numbers the conversation does not contain."
  "What the support check asks of its provider.")

(defun %describe-proposal (p index known)
  (let ((replaced (and (distil:proposal-replaces p)
                       (find (distil:proposal-replaces p) known :key #'mem:observation-id :test #'equal))))
    (format nil "~D. [~(~A~)] ~A~@[ (applies from ~A)~]~@[ (replaces the earlier observation: ~A)~]"
            index (distil:proposal-kind p) (distil:proposal-content p)
            (and (distil:proposal-applies-from p) (distil::%date-string (distil:proposal-applies-from p)))
            (and replaced (mem:observation-content replaced)))))

(defun supported-proposals (provider window distillation &key known)
  "DISTILLATION with only the proposals PROVIDER finds WINDOW supports, in their own order.
KNOWN is the observations a proposal may claim to replace, so the check can judge that claim.
Signals when the check itself fails, so the window is tried again rather than written
unchecked."
  (let* ((proposals (distil:distillation-proposals distillation))
         (listing (format nil "~{~A~%~}"
                          (loop for p in proposals for i from 1 collect (%describe-proposal p i known))))
         (arguments (llm:generate-structured
                     provider
                     (append window (list (llm:msg "user" (format nil "~A~%~%~A" *support-instructions* listing))))
                     (%support-spec)))
         (numbers (coerce (gethash "supported" arguments) 'list)))
    (distil:make-distillation
     (distil:distillation-subject distillation)
     (loop for p in proposals for i from 1
           when (member i numbers) collect p))))
