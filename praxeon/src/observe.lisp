;;;; observe.lisp --- running distil automatically over a thread, off the request path (#317).
;;;;
;;;; `praxeon/distil' turns a window of a transcript into observations, and nothing called it.
;;;; An OBSERVER is what calls it. It is told a thread's history after each turn, and it keeps
;;;; the thread's OBSERVED MARK, the first message not yet distilled. When the messages past the
;;;; mark reach STEP estimated tokens, it distils them on a thread of its own, one window at a
;;;; time, writes the result into the thread's scope, and moves the mark. The call that tells it
;;;; about the turn returns at once, so a member's request never waits for a distillation
;;;; (#317's first acceptance item).
;;;;
;;;; A WINDOW IS WHOLE EXCHANGES (`praxeon/prompt:exchanges'): a user message and everything
;;;; that answers it, up to STEP estimated tokens and at least one exchange. Cutting by tokens
;;;; alone could end a window on a tool call and start the next with its result, and a window
;;;; holding half of that pair is a malformed request (#462's second review).
;;;;
;;;; THE MARK MOVES ONLY PAST A WINDOW THAT WAS WRITTEN, OR ONE GIVEN UP ON. A provider error, a
;;;; store error part-way through the writes, or a failed support check leaves the mark where it
;;;; was, and the window is tried again after a pause that doubles each time, up to MAX-ATTEMPTS
;;;; times. A retry does not store an observation twice: what an earlier attempt already wrote,
;;;; with the same content and the same message range, is not written again, and its promotion
;;;; is run again. The match is on exact content, so a retry whose answer words an observation
;;;; differently stores both wordings. A window still failing is given up on: it goes into
;;;; OBSERVER-SKIPPED, so the prompt can keep those messages raw (#317, step C) rather than lose
;;;; them, the mark moves past it, and each later run tries it again in the same way, until
;;;; MAX-ATTEMPTS runs have given up on it. A skipped window still due starts a run by itself, so
;;;; a new observer retries it even when no new message has arrived.
;;;;
;;;; A SKIPPED WINDOW IS RETRIED ONLY WHILE NO LATER WINDOW HAS BEEN WRITTEN TO THE THREAD (#462's
;;;; fifth review). Until then a retry distils and promotes it exactly as if it had never been
;;;; skipped. When a later window is written, by a run or by a retry, every open skipped window
;;;; before it is closed at once, whatever its tries: marked :CLOSED in OBSERVER-SKIPPED, never
;;;; retried, and its messages stay raw in the prompt (#317, step C). A window still open when an
;;;; observation from a later window is found in the thread, as one left by an earlier run, is
;;;; closed by the next run. So within a thread nothing older is written over or beside anything
;;;; newer, and a window with nothing after it keeps its facts, with one exception: a progress
;;;; write that fails while another observer of the thread runs lets that observer distil older
;;;; windows after newer ones (see the store being behind, below; #462's eighth review). Across
;;;; a subject's threads it does not hold; see %MAYBE-PROMOTE.
;;;;
;;;; THE MARK AND THE SKIPPED WINDOWS ARE KEPT IN THE STORE (`praxeon/memory:thread-progress'),
;;;; written after each window, and a new observer starts from them. So an app that makes an
;;;; observer per request, or restarts, neither distils the thread again from the start nor
;;;; passes a window that was given up on or written only part-way. They are not worked out from
;;;; the thread's observations, which would count observations the app wrote itself. A WRITE
;;;; THAT FAILS leaves the observer unsaved, and the next OBSERVE-TURN starts a run to make it,
;;;; even with no new message. Until it is made the store is behind: after a stop, a restart or
;;;; with a new observer, the window it covers is distilled again, and a model that words its
;;;; answer differently leaves both wordings. The same can happen with long-lived observers: one
;;;; whose write failed, followed by another observer's turn before the first writes it, lets
;;;; the second distil the window again.
;;;;
;;;; ONE OBSERVER OF A THREAD RUNS AT A TIME IN A PROCESS, FOR ONE STORE OBJECT. OBSERVE-TURN
;;;; starts nothing while another observer of the same store object, subject and thread holds
;;;; the thread. Progress is merged, never replaced (%MERGE-PROGRESS): a run starts by merging
;;;; its own with the store's, and each save merges again before writing, so, through one store
;;;; object in one process, the stored mark is never lowered and newer progress at an equal mark
;;;; is never overwritten. A run whose first read of the store fails ends there.
;;;; RUNNING-OBSERVER names the observer holding a thread. A refused call logs that another
;;;; observer is running (a warning when that one is stuck) and does nothing else: a refused
;;;; :FLUSH is not queued, so an app that makes an observer per request flushes again once
;;;; RUNNING-OBSERVER is NIL. Observers of one thread through two store objects over one
;;;; database, or in two processes, are not coordinated.
;;;;
;;;; ERASURE. `praxeon/memory:forget-subject' refuses while an observer of the subject is running
;;;; in this process through the same store object, so such a run cannot write after the
;;;; erasure: stop it (STOP-OBSERVER on RUNNING-OBSERVER) and try again. Observers through another
;;;; store object over the same database, or in other processes, are stopped first by the app.
;;;; The erasure leaves each thread's progress as its mark alone, the subject's id, the thread's
;;;; id and a count, with no skipped windows and no content (the maintainer's ruling). The mark
;;;; is at least the last message the thread's erased observations cited, so a progress write
;;;; that failed before the erasure does not let those messages be distilled again (#462's
;;;; eighth review). An observer that held skipped windows from before merges with that record
;;;; at its next run: it drops the ones up to the kept mark, since the record holds no window
;;;; overlapping them, and keeps any past it, which it then tries as usual. Nothing from those
;;;; was stored before the erasure, since a window past the mark was never written. A new
;;;; observer starts at the mark. So the messages up to the mark are not observed again, later
;;;; ones are observed normally, and the app's transcript, which this does not erase, is not
;;;; distilled again up to the mark. A
;;;; conversation continued with a shortened or replaced transcript uses a new thread id: the
;;;; merge keeps the larger mark, so an explicit :MARK below it is overridden, and the first
;;;; messages of such a transcript would never be observed.
;;;;
;;;; WHAT IT WRITES, AND WHAT IT DOES NOT.
;;;;
;;;;   - Every proposal becomes an observation of the THREAD, never a fact about the subject.
;;;;   - A proposal that claims to replace an existing thread observation replaces it only when
;;;;     the app's ACCEPT says so, as `apply-distillation' already requires.
;;;;   - A thread observation also becomes a fact about the subject only when the app's PROMOTE
;;;;     says so, and by default nothing is promoted, because a wrong fact about a person is then
;;;;     recalled in every conversation with them. A fact the subject already holds is not stored
;;;;     again. When a promoted thread observation corrects one whose content the subject holds
;;;;     as a current fact, whoever wrote that fact (this conversation, another one, or the app),
;;;;     the fact is superseded only when PROMOTE-ACCEPT also says so; otherwise the correction
;;;;     is not promoted, so the subject never holds a fact and its correction as two current
;;;;     beliefs.
;;;;   - With a VERIFY provider, each window's proposals are checked against the window first:
;;;;     the content, the kind, the date and, above all, a claim to replace an earlier
;;;;     observation. The ones it does not support are dropped. It is a model call per window,
;;;;     so it is a setting, off by default; #317's benchmark measures what it buys.
;;;;
;;;; TURN NUMBERS ARE THE THREAD'S MESSAGE POSITIONS, counted from 1. An observation's provenance
;;;; names the conversation, the first message of its window as TURN, and the last as THROUGH;
;;;; a skipped window is (FROM THROUGH TRIES) in the same numbering.
;;;;
;;;; A THREAD OBSERVER SHARES ITS STORE WITH THE APP. `praxeon/memory''s in-memory store locks
;;;; every operation for that reason. The SQL store holds its lock around each write and around
;;;; a supersession's check and writes, and computes embeddings before taking it, so a request's
;;;; read does not wait for the embedding model.

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
   (retry-delay :initarg :retry-delay :reader observer-retry-delay)
   (window-timeout :initarg :window-timeout :reader observer-window-timeout)
   (mark :initarg :mark :accessor observer-mark)
   (skipped :initarg :skipped :accessor observer-skipped)
   ;; True when the last progress write failed, so the store is behind this observer.
   (unsaved :initform nil :accessor observer-unsaved)
   (failures :initform 0 :accessor observer-failures)
   (last-error :initform nil :accessor observer-last-error)
   (worker :initform nil :accessor observer-worker)
   (started :initform nil :accessor observer-started)
   (stopping :initform nil :accessor observer-stopping)
   (lock :initform (bt:make-lock "praxeon-observer") :reader observer-lock))
  (:documentation "Distils one thread's messages into the thread's observations, a window at a time."))

(defvar *running* (make-hash-table :test #'equal)
  "(STORE SUBJECT THREAD) -> the observer running on that thread in this process.")

(defvar *running-lock* (bt:make-lock "praxeon-observers"))

(defun %claim (observer)
  "Make OBSERVER the one running on its store, subject and thread in this process, until
%RELEASE. NIL when another observer of the same thread holds it.

THE CLAIM ITSELF HOLDS THE THREAD, not the other observer's worker being alive (#462's fourth
review): the worker is made after the claim, so two OBSERVE-TURN calls arriving together would
otherwise both find no live worker and both run."
  (let ((key (list (observer-store observer) (observer-subject observer) (observer-thread observer))))
    (bt:with-lock-held (*running-lock*)
      (let ((other (gethash key *running*)))
        (cond ((or (null other) (eq other observer))
               (setf (gethash key *running*) observer))
              (t (if (observer-stuck-p other)
                     (log:warn "memory observer not started: the thread's running observer is stuck"
                               :thread (observer-thread observer))
                     (log:debug "memory observer not started: another observer of the thread is running"
                                :thread (observer-thread observer)))
                 nil))))))

(define-condition observer-running (praxeon/conditions:praxeon-error)
  ((subject :initarg :subject :reader observer-running-subject)
   (thread :initarg :thread :reader observer-running-thread))
  (:report (lambda (c stream)
             (format stream "Cannot forget ~A: an observer of thread ~A is running. Stop it (stop-observer on running-observer) and try again."
                     (observer-running-subject c) (observer-running-thread c))))
  (:documentation "FORGET-SUBJECT was called while an observer of the subject is running in this
process. A slot of its own for the thread, since PRAXEON-ERROR carries no detail (#505)."))

(defmethod mem:forget-subject :before ((store mem:memory-store) subject)
  "Refuse to erase SUBJECT while an observer of it is running in this process: that run could
write after the erasure (#462, the maintainer's ruling)."
  (let ((running (bt:with-lock-held (*running-lock*)
                   (loop for key being the hash-keys of *running*
                         when (and (eq (first key) store) (string= (second key) subject))
                           collect (third key)))))
    (when running
      (error 'observer-running :subject subject :thread (first running)))))

(defun running-observer (store subject thread)
  "The observer running on THREAD about SUBJECT in STORE in this process, or NIL. An app that
makes an observer per request uses it to stop the running one (STOP-OBSERVER), for instance
before `praxeon/memory:forget-subject'."
  (bt:with-lock-held (*running-lock*)
    (values (gethash (list store subject thread) *running*))))

(defun %release (observer)
  (let ((key (list (observer-store observer) (observer-subject observer) (observer-thread observer))))
    (bt:with-lock-held (*running-lock*)
      (when (eq (gethash key *running*) observer)
        (remhash key *running*)))))

(defun stored-mark (store subject thread)
  "The mark an observer of THREAD about SUBJECT resumes from: what STORE records of its progress
(`praxeon/memory:thread-progress'), or 0 when nothing is recorded."
  (or (mem:thread-progress store subject thread) 0))

(defun make-observer (provider store subject thread
                      &key (step *step-tokens*) (accept (constantly nil)) (promote (constantly nil))
                           (promote-accept (constantly nil)) verify distil-options
                           (max-attempts 3) (retry-delay 2) (window-timeout 300) mark)
  "An observer of THREAD (a string, usually the conversation's id) about SUBJECT, distilling
with PROVIDER into STORE, a PRAXEON/MEMORY:MEMORY-STORE.

STEP is the estimated tokens of unobserved messages that start a distillation, and the most one
window holds unless a single exchange is larger. ACCEPT is `apply-distillation''s: called with a
proposal and the thread observation it claims to replace, true to replace it. PROMOTE is called
with each new thread observation, true to also record it as a fact about SUBJECT. PROMOTE-ACCEPT
is called with a promoted correction and the subject's fact it would replace, true to supersede
that fact. VERIFY, a provider or NIL, checks each window's proposals against the window first.
DISTIL-OPTIONS is a plist passed to `distil', such as (:max-tokens 2048).

MAX-ATTEMPTS is how many times a window that fails is tried before it is given up on, and how
many later runs try a window given up on. RETRY-DELAY is the seconds before the second attempt;
each later one waits twice as long as the one before. WINDOW-TIMEOUT is how many seconds a
window may take before OBSERVER-STUCK-P says so. MARK, when given, is where to start; by default
it is what STORE records (STORED-MARK), and the skipped windows always come from there. Either
way, a run starts by merging its progress with the store's (%MERGE-PROGRESS), so it continues
from wherever the two records together have reached.

ACCEPT, PROMOTE and PROMOTE-ACCEPT must be functions, or names of functions: NIL is refused here
rather than failing every window later."
  (check-type thread string)
  (unless (and (integerp step) (plusp step))
    (error 'praxeon/conditions:praxeon-error :detail (format nil ":step must be a positive integer, not ~S" step)))
  (unless (and (integerp max-attempts) (plusp max-attempts))
    (error 'praxeon/conditions:praxeon-error :detail (format nil ":max-attempts must be a positive integer, not ~S" max-attempts)))
  (loop for (name value) on (list :accept accept :promote promote :promote-accept promote-accept) by #'cddr
        unless (or (functionp value) (and value (symbolp value) (fboundp value)))
          do (error 'praxeon/conditions:praxeon-error
                    :detail (format nil "~S must be a function, not ~S" name value)))
  (unless (and (realp retry-delay) (not (minusp retry-delay)))
    (error 'praxeon/conditions:praxeon-error :detail (format nil ":retry-delay must be a number of seconds, not ~S" retry-delay)))
  ;; BOTH PROGRESS GENERICS, checked here: a store with only the reader would be accepted and
  ;; then fail on every save.
  (loop for (generic . arguments) in (list (list #'mem:thread-progress store subject thread)
                                           (list #'mem:record-thread-progress store subject thread 0 '()))
        unless (compute-applicable-methods generic arguments)
          do (error 'praxeon/conditions:praxeon-error
                    :detail (format nil "~A has no method for ~A, which the observer keeps its progress with"
                                    (type-of store) (sb-mop:generic-function-name generic))))
  (multiple-value-bind (stored skipped) (mem:thread-progress store subject thread)
    (make-instance 'observer :provider provider :store store :subject subject :thread thread
                             :step step :accept accept :promote promote :promote-accept promote-accept
                             :verify verify :distil-options distil-options
                             :max-attempts max-attempts :retry-delay retry-delay
                             :window-timeout window-timeout
                             :mark (or mark stored 0) :skipped skipped)))

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
  "The end (exclusive) of the window from START in HISTORY: whole exchanges until they reach
STEP estimated tokens, and always at least one."
  (let ((tokens 0) (end start))
    (loop for exchange in (prompt:exchanges (nthcdr start history))
          do (incf tokens (prompt:messages-tokens exchange))
             (incf end (length exchange))
          until (>= tokens step))
    end))

(defun %open-p (entry)
  "Whether a skipped window ENTRY may still be retried: not closed because a later window was
written."
  (not (eq (fourth entry) :closed)))

(defun %retry-due-p (observer history)
  "Whether a skipped window of HISTORY is due a run: another try, or, when its tries are spent,
closing because a later window has been written. The second needs a read of the thread, made
only for such a window."
  (some (lambda (s) (and (%open-p s)
                         (<= (second s) (length history))
                         (or (< (third s) (observer-max-attempts observer))
                             (%later-window-written-p/request observer (second s)))))
        (observer-skipped observer)))

(defun %later-window-written-p/request (observer through)
  "%LATER-WINDOW-WRITTEN-P for OBSERVE-TURN, which runs on the app's request thread: a store
that fails the read is logged and the window treated as not due, so a memory store failure
cannot fail the app's request (#462's sixth review)."
  (handler-case (%later-window-written-p observer through)
    (error (e)
      (log:warn "memory observer could not read the thread" :thread (observer-thread observer)
                                                            :condition (string-downcase (princ-to-string (type-of e))))
      nil)))

(defun observe-turn (observer history &key flush)
  "Tell OBSERVER the thread's HISTORY, a list of praxeon/llm messages, after a turn. Returns at
once: T when it started a distillation, NIL otherwise.

It starts one when no distillation is running and the messages past the mark reach
OBSERVER-STEP estimated tokens, or, with FLUSH, when there is any message past the mark: FLUSH
is for the end of a conversation, whose last messages would otherwise never reach a step. A run
also tries again each skipped window still due. Two runs start with no new message: one that
writes progress a failed write left unsaved, and one that closes an exhausted skipped window
once a later window is in the thread. Deciding the second reads the thread; a failed read is
logged and starts nothing, so a store failure does not fail the caller. The history is copied
here, and today's date taken here, so messages the app adds later are the next call's."
  (let ((snapshot (copy-list history))
        (today (get-universal-time)))
    (bt:with-lock-held ((observer-lock observer))
      (cond
        ((observer-stuck-p observer)
         (log:warn "memory observer stuck" :thread (observer-thread observer)
                                           :seconds (- (get-universal-time) (observer-started observer)))
         nil)
        ((observer-busy-p observer) nil)
        ((and (or (let ((window (unobserved observer snapshot)))
               (and window (or flush (>= (prompt:messages-tokens window) (observer-step observer)))))
                  (%retry-due-p observer snapshot)
                  ;; A progress write that failed is made again at the next turn, even one with
                  ;; no new message (Copilot's review of #462).
                  (observer-unsaved observer))
              ;; ONE RUNNING OBSERVER PER THREAD in this process, so an observer made per
              ;; request does not distil a window another one is distilling (#462's third review).
              (%claim observer))
         (setf (observer-started observer) (get-universal-time)
               (observer-stopping observer) nil)
         ;; A thread that cannot be made gives the claim back, or the thread would stay taken.
         (setf (observer-worker observer)
               (handler-bind ((error (lambda (e) (declare (ignore e)) (%release observer))))
                 (%start-worker observer snapshot flush today)))
         t)
        (t nil)))))

(defun %start-worker (observer history flush today)
  ;; THREAD-LIFETIME: continues the turn's unit of work, on its own thread so the turn does not
  ;; wait. It runs a praxeon model call, which reads praxeon's registered dynamic bindings
  ;; (#158), so it carries them. AWAIT-OBSERVER and STOP-OBSERVER join it.
  (bt:make-thread (aion/dynamic:inheriting (lambda () (%run observer history flush today)))
                  :name "praxeon-observer"))

(defun await-observer (observer &key (timeout 300))
  "Join OBSERVER's running distillation, waiting at most TIMEOUT seconds. Returns T when none is
running afterwards."
  (let ((w (observer-worker observer)))
    (when (and w (bt:thread-alive-p w))
      (sb-thread:join-thread w :default nil :timeout timeout))
    (not (observer-busy-p observer))))

(defun stop-observer (observer &key (timeout 30))
  "Stop OBSERVER at shutdown: it finishes the attempt it is on, waits for no retry, and starts no
other window. Waits at most TIMEOUT seconds, then ends its thread. Returns T when it stopped in
time. When it returns NIL the thread is ended asynchronously, so RUNNING-OBSERVER can still name
OBSERVER for a moment afterwards. A window it stopped during is not given up on. It is not
written either, unless the stop came after the window's observations were written and before
its progress was: then the next observer of the thread distils it again (#462's eighth
review)."
  (setf (observer-stopping observer) t)
  (or (await-observer observer :timeout timeout)
      (let ((w (observer-worker observer)))
        (when (and w (bt:thread-alive-p w)) (ignore-errors (bt:destroy-thread w)))
        nil)))

;;; --- the windows ------------------------------------------------------------------------

(defun %run (observer history flush today)
  "Try again the skipped windows still due, then distil HISTORY past the mark, one window at a
time, until what is left is below a step (or, with FLUSH, nothing is left), or the observer is
stopped. An error here is recorded and logged, never raised: an error no handler takes in this
thread would end the process."
  (unwind-protect
       (handler-case
           (progn (%reconcile-progress observer)
                  (%retry-skipped observer history today)
                  (%run-windows observer history flush today))
         (error (e)
           (incf (observer-failures observer))
           (setf (observer-last-error observer) e)
           (log:error "memory observer stopped" :thread (observer-thread observer)
                                                :condition (string-downcase (princ-to-string (type-of e))))))
    (%release observer)))

(defun %same-window-p (x y) (and (= (first x) (first y)) (= (second x) (second y))))

(defun %overlap-p (x y) (and (<= (first x) (second y)) (<= (first y) (second x))))

(defun %merge-progress (mark-a skipped-a mark-b skipped-b)
  "Two records of one thread's progress, merged. Returns the merged mark and skipped windows.

The mark is the larger. Past the smaller mark, skipped windows come from the record that reached
it. Up to the smaller mark, each record has distilled every message it holds no skipped window
for, so a message is still undistilled only when both records hold a skipped window over it.
For each pair of overlapping skipped windows, one from each record, only their overlap is kept,
with the larger tries, and :CLOSED when either is closed (#462's eighth review). A window only
one record holds is dropped, and so is the part of a window the other record distilled. Each
overlap starts at some window's start and ends at some window's end, so it is still whole
exchanges.

The result is the same whichever record is A, and no message both records left undistilled is
lost. When neither record holds two overlapping windows, which is true of every record an
observer or this merge writes (the overlaps of two sets of disjoint windows are disjoint), the
result holds none either, and merging it again with either record or with itself changes
nothing. Up to the smaller mark it is not associative: three records merged in two orders can
keep different windows, but in each order every message that all of them left undistilled is
kept."
  (let* ((low (min mark-a mark-b))
         (high-skipped (cond ((> mark-a mark-b) skipped-a)
                             ((> mark-b mark-a) skipped-b)
                             (t '())))
         (kept '()))
    (flet ((keep (entry) (unless (find-if (lambda (k) (%same-window-p k entry)) kept) (push entry kept))))
      (dolist (a skipped-a)
        (when (<= (second a) low)
          (dolist (b skipped-b)
            (when (and (<= (second b) low) (%overlap-p a b))
              (keep (append (list (max (first a) (first b)) (min (second a) (second b))
                                  (max (third a) (third b)))
                            (unless (and (%open-p a) (%open-p b)) (list :closed))))))))
      (dolist (e high-skipped)
        (when (> (second e) low) (keep e))))
    (values (max mark-a mark-b)
            (sort kept (lambda (x y) (or (< (first x) (first y))
                                         (and (= (first x) (first y)) (< (second x) (second y)))))))))

(defun %note-unsaved (observer e)
  (setf (observer-unsaved observer) t)
  (incf (observer-failures observer))
  (setf (observer-last-error observer) e)
  (log:warn "memory observer progress not saved" :thread (observer-thread observer)
                                                 :condition (string-downcase (princ-to-string (type-of e)))))

(defun %sync-progress (observer &key (read-failure :record))
  "Read the store's progress, merge OBSERVER's own into it (%MERGE-PROGRESS), take the result,
and write it when it differs from what is stored. The stored mark is never lowered, and newer
progress at an equal mark is never overwritten, through one store object in one process. A failed write marks OBSERVER unsaved. A failed
read does the same with READ-FAILURE :RECORD, and with :SIGNAL it is signalled, which ends the
run that is reconciling."
  (let ((stored nil) (skipped nil))
    (handler-case (multiple-value-setq (stored skipped)
                    (mem:thread-progress (observer-store observer) (observer-subject observer)
                                         (observer-thread observer)))
      (error (e)
        (when (eq read-failure :signal) (error e))
        (%note-unsaved observer e)
        (return-from %sync-progress nil)))
    (multiple-value-bind (mark merged)
        (bt:with-lock-held ((observer-lock observer))
          (multiple-value-bind (mark merged)
              (%merge-progress (observer-mark observer) (observer-skipped observer) (or stored 0) skipped)
            (setf (observer-mark observer) mark
                  (observer-skipped observer) merged)
            (values mark (copy-tree merged))))
      (handler-case
          (progn
            ;; Nothing recorded is the same as mark 0 with nothing skipped.
            (unless (and (= (or stored 0) mark) (equal skipped merged))
              (mem:record-thread-progress (observer-store observer) (observer-subject observer)
                                          (observer-thread observer) mark merged))
            (setf (observer-unsaved observer) nil))
        (error (e) (%note-unsaved observer e))))))

(defun %reconcile-progress (observer)
  "At the start of a run, which holds the thread's claim: merge OBSERVER's progress with the
store's and write the result if it differs (%SYNC-PROGRESS). An observer made before another one
ran, or one whose last write failed, so neither retries a window the other handled nor writes
older progress over newer. A failed read ends the run, rather than letting it continue from a
mark the store may have passed."
  (%sync-progress observer :read-failure :signal))

(defun %close-before (observer start)
  "Close every open skipped window that ends at or before START: a window after it was written
(Copilot's review of #462). Logs each one."
  (let ((closed '()))
    (bt:with-lock-held ((observer-lock observer))
      (setf (observer-skipped observer)
            (mapcar (lambda (e) (if (and (%open-p e) (<= (second e) start))
                                    (progn (push e closed)
                                           (list (first e) (second e) (third e) :closed))
                                    e))
                    (observer-skipped observer))))
    (dolist (e closed)
      (log:info "memory observer window closed" :thread (observer-thread observer)
                                                :from (first e) :through (second e)))))

(defun %run-windows (observer history flush today)
  (loop
    (let* ((start (observer-mark observer))
           (left (nthcdr start history)))
      (when (or (null left) (observer-stopping observer)
                (and (not flush) (< (prompt:messages-tokens left) (observer-step observer))))
        (return))
      (let* ((end (%window-end history start (observer-step observer)))
             (outcome (%observe-window observer (subseq history start end) start end today)))
        (bt:with-lock-held ((observer-lock observer))
          (case outcome
            (:skipped (setf (observer-skipped observer)
                            (append (observer-skipped observer) (list (list (1+ start) end 1))))
                      (setf (observer-mark observer) (max (observer-mark observer) end)))
            (:written (setf (observer-mark observer) (max (observer-mark observer) end)))))
        ;; A WINDOW WRITTEN CLOSES EVERY OPEN SKIPPED WINDOW BEFORE IT, at once and whatever its
        ;; tries, rather than at a later run (Copilot's review of #462).
        (when (eq outcome :written) (%close-before observer start))
        (when (eq outcome :stopped) (return))
        (%save-progress observer)))))

(defun %later-window-written-p (observer through)
  "Whether the thread holds an observation, current or superseded, from a window after message
THROUGH."
  (let ((thread (observer-thread observer)))
    (some (lambda (o)
            (let ((p (mem:observation-provenance o)))
              (and (string= (mem:provenance-conversation p) thread)
                   (> (mem:provenance-turn p) through))))
          (mem:observations-of (observer-store observer) (observer-subject observer)
                               :thread thread :include-superseded t))))

(defun %retry-skipped (observer history today)
  "Try once more each open skipped window of HISTORY that fewer than MAX-ATTEMPTS runs have tried,
distilled and promoted as any window is. One with a later window written after it is closed
instead, and not tried. A window written now leaves OBSERVER-SKIPPED; one that fails again
counts the try."
  (dolist (entry (copy-list (observer-skipped observer)))
    (destructuring-bind (from through tries &optional status) entry
      (declare (ignore status))
      ;; CLOSURE IS DECIDED WHATEVER THE TRIES, so an exhausted window with a later window
      ;; written is closed rather than left open with nothing to close it.
      (when (and (%open-p entry) (<= through (length history)) (not (observer-stopping observer))
                 (or (< tries (observer-max-attempts observer))
                     (%later-window-written-p observer through)))
        (if (%later-window-written-p observer through)
            (progn
              (bt:with-lock-held ((observer-lock observer))
                (setf (observer-skipped observer)
                      (substitute (list from through tries :closed) entry (observer-skipped observer)
                                  :test #'equal)))
              (log:info "memory observer window closed" :thread (observer-thread observer)
                                                        :from from :through through)
              (%save-progress observer))
            (let ((outcome (%observe-window observer (subseq history (1- from) through) (1- from) through today)))
              (unless (eq outcome :stopped)
                (bt:with-lock-held ((observer-lock observer))
                  (setf (observer-skipped observer)
                        (if (eq outcome :written)
                            (remove entry (observer-skipped observer) :test #'equal)
                            (substitute (list from through (1+ tries)) entry (observer-skipped observer)
                                        :test #'equal))))
                ;; A retried window written closes the open windows before it, as any window
                ;; written does (#462's sixth review).
                (when (eq outcome :written) (%close-before observer (1- from)))
                (%save-progress observer))))))))

(defun %save-progress (observer)
  "Record OBSERVER's progress in its store, merged with what is there (%SYNC-PROGRESS). A failure
is counted and logged, and marks the progress unsaved: the next window's save carries the same
state again, and when there is no next window, OBSERVE-TURN starts a run at the next turn to make
the write."
  (%sync-progress observer :read-failure :record))

(defun %pause (observer seconds)
  "Wait SECONDS, or less if OBSERVER is being stopped."
  (let ((until (+ (get-internal-real-time) (* seconds internal-time-units-per-second))))
    (loop while (and (< (get-internal-real-time) until) (not (observer-stopping observer)))
          do (sleep 0.05))))

(defun %observe-window (observer window start end today)
  "Distil WINDOW, the messages from position START (from 0) to END, and write what it yields,
trying up to OBSERVER-MAX-ATTEMPTS times with a pause before each retry. Returns :WRITTEN,
:SKIPPED when every attempt failed, or :STOPPED when the observer was stopped before the window
was written. Never raises: this runs on a thread of its own."
  (let ((began (get-internal-real-time)) (written 0) (outcome :skipped))
    (loop for attempt from 1 to (observer-max-attempts observer)
          do (when (> attempt 1)
               (%pause observer (* (observer-retry-delay observer) (expt 2 (- attempt 2)))))
             (when (observer-stopping observer)
               (setf outcome :stopped)
               (return))
             (handler-case
                 (progn (setf written (%distil-and-write observer window start end today))
                        (setf outcome :written)
                        (return))
               (error (e)
                 (incf (observer-failures observer))
                 (setf (observer-last-error observer) e))))
    (log:info "memory observer window" :thread (observer-thread observer)
                                       :from (1+ start) :through end :outcome outcome :written written
                                       :failures (observer-failures observer)
                                       :ms (round (* 1000 (- (get-internal-real-time) began))
                                                  internal-time-units-per-second))
    outcome))

(define-condition window-not-distilled (praxeon/conditions:praxeon-error) ()
  (:documentation "distil could not read the model's answer for a window; carries its reason."))

(defun %window-observations (store subject thread start end)
  "The current observations of THREAD written from the window START (from 0) to END."
  (remove-if-not (lambda (o)
                   (let ((p (mem:observation-provenance o)))
                     (and (string= (mem:provenance-conversation p) thread)
                          (= (mem:provenance-turn p) (1+ start))
                          (eql (mem:provenance-through p) end))))
                 (mem:observations-of store subject :thread thread)))

(defun %distil-and-write (observer window start end today)
  "One attempt at a window. Returns how many observations it wrote, or signals."
  (let* ((store (observer-store observer))
         (subject (observer-subject observer))
         (thread (observer-thread observer))
         (known (mem:observations-of store subject :thread thread))
         (provenance (mem:make-provenance thread (1+ start) :through end)))
    (multiple-value-bind (distillation condition)
        (apply #'distil:distil (observer-provider observer) subject window
               :known known :today today (observer-distil-options observer))
      (unless distillation
        (error 'window-not-distilled
               :detail (format nil "the model's answer could not be read: ~A" condition)))
      (let* ((checked (if (and (observer-verify observer) (distil:distillation-proposals distillation))
                          (supported-proposals (observer-verify observer) window distillation :known known)
                          distillation))
             ;; WHAT AN EARLIER ATTEMPT AT THIS WINDOW ALREADY WROTE is not written again: an
             ;; observation of this thread with the same content and the same message range,
             ;; superseded or not.
             (done (remove-if-not (lambda (o)
                                    (let ((p (mem:observation-provenance o)))
                                      (and (string= (mem:provenance-conversation p) thread)
                                           (= (mem:provenance-turn p) (1+ start))
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
        ;; PROMOTION RUNS OVER EVERY CURRENT OBSERVATION OF THE WINDOW, not only this attempt's
        ;; writes, so an attempt that failed during promotion is finished by the next one.
        ;; %MAYBE-PROMOTE leaves alone a fact the subject already holds, so running it again
        ;; changes nothing that was done.
        (dolist (o (%window-observations store subject thread start end))
          (%maybe-promote observer o provenance))
        (length written)))))

(defun %current-fact (store subject content)
  "SUBJECT's current fact whose content is CONTENT, whoever wrote it."
  (find content (mem:observations-of store subject) :key #'mem:observation-content :test #'string=))

(defun %lineage-contents (observation thread-observations)
  "OBSERVATION's content and the content of every thread observation it descends from through
SUPERSEDES, nearest first. THREAD-OBSERVATIONS includes superseded ones."
  (let ((seen '()))
    (loop for o = observation then (and (mem:observation-supersedes o)
                                        (find (mem:observation-supersedes o) thread-observations
                                              :key #'mem:observation-id :test #'string=))
          while (and o (not (member (mem:observation-id o) seen :test #'string=)))
          do (push (mem:observation-id o) seen)
          collect (mem:observation-content o))))

(defun %current-successor (fact facts)
  "The current fact FACT was superseded into, following SUPERSEDED-BY through FACTS; FACT itself
when it is current; NIL when the chain ends in an observation no longer stored."
  ;; A cycle written into the stored links ends the walk rather than looping.
  (let ((seen '()))
    (loop for f = fact then (find (mem:observation-superseded-by f) facts
                                  :key #'mem:observation-id :test #'string=)
          while (and f (not (member (mem:observation-id f) seen :test #'string=)))
          do (push (mem:observation-id f) seen)
          when (mem:observation-current-p f) return f)))

(defun %maybe-promote (observer observation provenance)
  "Record OBSERVATION, a thread observation, as a fact about the subject when PROMOTE says so.

Not twice: when the subject already holds a current fact with its content, nothing is done.

NEVER BESIDE A FACT IT REPLACES (#462's reviews). The subject facts OBSERVATION is about are
those whose content is OBSERVATION's own or that of any thread observation it descends from
through a chain of corrections, superseded facts included, whoever wrote them. When there are
any, OBSERVATION replaces their current successor only when PROMOTE-ACCEPT says so, and
otherwise nothing is promoted. So a chain Porto, Lisbon, Faro, a correction of a fact the app
or another conversation has already corrected, and an old fact observed again all end with one
current fact. A thread fact that contradicts a subject fact with no such link between them is
promoted beside it; telling those apart is PROMOTE's judgement.

ONLY A CORRECTION REACHES PROMOTE-ACCEPT: an observation that replaces a thread observation. One
that replaces nothing but matches a superseded subject fact restates an old value, and is not
promoted. The chain is followed within this observer's thread only, so a correction refused
here can still reach the subject when another conversation states the corrected value plainly
with nothing to link it. When the chain reaches several current subject facts, which needs an
unlinked contradiction first, only the first is replaced."
  (let* ((store (observer-store observer))
         (subject (observer-subject observer)))
    (when (and (funcall (observer-promote observer) observation)
               (not (%current-fact store subject (mem:observation-content observation))))
      (let* ((contents (%lineage-contents observation
                                          (mem:observations-of store subject :thread (observer-thread observer)
                                                                             :include-superseded t)))
             (facts (mem:observations-of store subject :include-superseded t))
             (heads (remove-duplicates
                     (remove nil (mapcar (lambda (f) (%current-successor f facts))
                                         (remove-if-not (lambda (f) (member (mem:observation-content f) contents
                                                                            :test #'string=))
                                                        facts)))))
             (head (first heads)))
        (cond
          ;; ONLY A CORRECTION REACHES PROMOTE-ACCEPT (#462's fourth review). An observation that
          ;; replaces nothing in the thread but matches a superseded subject fact is a
          ;; restatement of an old value, and it does not replace the current one.
          ((and head (null (mem:observation-supersedes observation)))
           nil)
          (head
           (when (funcall (observer-promote-accept observer) observation head)
             (mem:supersede store head (mem:observation-content observation)
                            :provenance provenance :kind (mem:observation-kind observation)
                            :valid-from (mem:observation-valid-from observation))))
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
            (and (distil:proposal-applies-from p) (distil:date-string (distil:proposal-applies-from p)))
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
