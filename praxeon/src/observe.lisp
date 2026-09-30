;;;; observe.lisp --- running distil automatically over a thread, off the request path (#317).
;;;;
;;;; `praxeon/distil' turns a window of a transcript into observations, and nothing called it.
;;;; An OBSERVER is what calls it. It is told a thread's history after each turn, and it keeps
;;;; the thread's OBSERVED MARK, the first message not yet distilled. When the messages past the
;;;; mark pass STEP estimated tokens, it distils them on a thread of its own, writes the result
;;;; into the thread's scope, and moves the mark. The call that tells it about the turn returns
;;;; at once, so a member's request never waits for a distillation (#317's first acceptance
;;;; item).
;;;;
;;;; WHY IN STEPS. Mastra's observer works ahead of its threshold in small steps, so the notes
;;;; are ready when the prompt needs them. A step here is that unit: the prompt's use of the
;;;; observations (#317, step 4) is a separate threshold, and by the time a thread reaches it,
;;;; its messages have already been observed a step at a time.
;;;;
;;;; WHAT IT WRITES, AND WHAT IT DOES NOT.
;;;;
;;;;   - Every proposal becomes an observation of the THREAD, never a fact about the subject.
;;;;     A thread observation stands in for that thread's old messages and nothing else.
;;;;   - A proposal that claims to replace an existing thread observation replaces it only when
;;;;     the app's ACCEPT says so, as `apply-distillation' already requires.
;;;;   - A thread observation also becomes a fact about the subject only when the app's PROMOTE
;;;;     says so. By default nothing is promoted, because a wrong fact about a person is then
;;;;     recalled in every conversation with them.
;;;;   - With a VERIFY provider, each window's proposals are first checked against the window,
;;;;     and the ones it does not support are dropped. That is a model call per window, so it is
;;;;     a setting, off by default; #317's benchmark measures what it buys.
;;;;
;;;; TURN NUMBERS ARE THE THREAD'S MESSAGE POSITIONS, counted from 1. An observation's provenance
;;;; names the conversation, the first message of its window as TURN, and the last as THROUGH.
;;;;
;;;; A WINDOW THAT CANNOT BE DISTILLED IS SKIPPED, not retried: `distil' returns NIL for it, the
;;;; mark still moves, and the failure is counted in OBSERVER-FAILURES. Retrying the same window
;;;; would pay for the same failure every step.

(in-package #:praxeon/observe)

(defparameter *step-tokens* 6000
  "How many estimated tokens of unobserved messages start a distillation, Mastra's step.")

(defclass observer ()
  ((provider :initarg :provider :reader observer-provider)
   (store :initarg :store :reader observer-store)
   (subject :initarg :subject :reader observer-subject)
   (thread :initarg :thread :reader observer-thread)
   (step :initarg :step :reader observer-step)
   (accept :initarg :accept :reader observer-accept)
   (promote :initarg :promote :reader observer-promote)
   (verify :initarg :verify :reader observer-verify)
   (distil-options :initarg :distil-options :reader observer-distil-options)
   (mark :initform 0 :accessor observer-mark)
   (failures :initform 0 :accessor observer-failures)
   (last-error :initform nil :accessor observer-last-error)
   (worker :initform nil :accessor observer-worker)
   (lock :initform (bt:make-lock "praxeon-observer") :reader observer-lock))
  (:documentation "Distils one thread's messages into the thread's observations, a step at a time."))

(defun make-observer (provider store subject thread
                      &key (step *step-tokens*) (accept (constantly nil)) (promote (constantly nil))
                           verify distil-options)
  "An observer of THREAD (a string, usually the conversation's id) about SUBJECT, distilling
with PROVIDER into STORE, a PRAXEON/MEMORY:MEMORY-STORE.

STEP is the estimated tokens of unobserved messages that start a distillation. ACCEPT is
`apply-distillation''s: called with a proposal and the thread observation it claims to replace,
true to replace it. PROMOTE is called with each new thread observation, true to also record it
as a fact about SUBJECT. VERIFY, a provider or NIL, checks each window's proposals against the
window first. DISTIL-OPTIONS is a plist passed to `distil', such as (:max-tokens 2048)."
  (check-type thread string)
  (make-instance 'observer :provider provider :store store :subject subject :thread thread
                           :step step :accept accept :promote promote :verify verify
                           :distil-options distil-options))

(defun unobserved (observer history)
  "The messages of HISTORY past OBSERVER's mark."
  (nthcdr (min (observer-mark observer) (length history)) history))

(defun observer-busy-p (observer)
  "Whether a distillation is running."
  (let ((w (observer-worker observer)))
    (and w (bt:thread-alive-p w))))

(defun observe-turn (observer history)
  "Tell OBSERVER the thread's HISTORY, a list of praxeon/llm messages, after a turn. Returns at
once: T when it started a distillation, NIL otherwise.

It starts one when no distillation is running and the messages past the mark are at least
OBSERVER-STEP estimated tokens. The window is those messages as they are now; messages added
while it runs are the next window's."
  (bt:with-lock-held ((observer-lock observer))
    (let* ((start (observer-mark observer))
           (window (unobserved observer history))
           (end (+ start (length window))))
      (when (and window
                 (not (observer-busy-p observer))
                 (>= (prompt:messages-tokens window) (observer-step observer)))
        ;; THREAD-LIFETIME: continues the turn's unit of work, on its own thread so the turn
        ;; does not wait. It runs a praxeon model call, which reads praxeon's registered
        ;; dynamic bindings (#158), so it carries them. AWAIT-OBSERVER joins it.
        (setf (observer-worker observer)
              (bt:make-thread
               (aion/dynamic:inheriting
                (lambda () (%observe-window observer (copy-list window) start end)))
               :name "praxeon-observer"))
        t))))

(defun await-observer (observer &key (timeout 300))
  "Wait for OBSERVER's running distillation to finish, at most TIMEOUT seconds. Returns T when
none is running afterwards. For shutdown and for tests."
  (let ((w (observer-worker observer)))
    (when w
      (let ((deadline (+ (get-universal-time) timeout)))
        (loop while (and (bt:thread-alive-p w) (< (get-universal-time) deadline))
              do (sleep 0.02))))
    (not (observer-busy-p observer))))

;;; --- one window ------------------------------------------------------------------------

(defun %observe-window (observer window start end)
  "Distil WINDOW, the messages from position START (from 0) to END, write what it yields, and
move the mark to END. Any error is recorded, not raised: this runs on a thread of its own."
  (handler-case
      (let* ((store (observer-store observer))
             (subject (observer-subject observer))
             (thread (observer-thread observer))
             (known (mem:observations-of store subject :thread thread))
             (distillation (apply #'distil:distil (observer-provider observer) subject window
                                  :known known (observer-distil-options observer))))
        (if (null distillation)
            (incf (observer-failures observer))
            (let* ((checked (if (observer-verify observer)
                                (supported-proposals (observer-verify observer) window distillation)
                                distillation))
                   (provenance (mem:make-provenance thread (1+ start) :through end))
                   (written (distil:apply-distillation store checked
                                                      :provenance provenance
                                                      :accept (observer-accept observer)
                                                      :thread thread)))
              (dolist (o written)
                (when (funcall (observer-promote observer) o)
                  (mem:remember store subject (mem:observation-content o)
                                :provenance provenance
                                :kind (mem:observation-kind o)
                                :valid-from (mem:observation-valid-from o)))))))
    (error (e)
      (incf (observer-failures observer))
      (setf (observer-last-error observer) e)))
  (bt:with-lock-held ((observer-lock observer))
    (setf (observer-mark observer) (max (observer-mark observer) end))))

;;; --- the support check -------------------------------------------------------------------

(defun %support-spec ()
  (llm:make-tool-spec
   :name "record_supported"
   :description "Record which numbered observations the conversation supports."
   :schema (let ((h (make-hash-table :test #'equal))
                 (props (make-hash-table :test #'equal))
                 (arr (make-hash-table :test #'equal)))
             (setf (gethash "type" arr) "array"
                   (gethash "description" arr) "The numbers of the observations the conversation states or clearly implies."
                   (gethash "supported" props) arr
                   (gethash "type" h) "object"
                   (gethash "properties" h) props
                   (gethash "required" h) (vector "supported"))
             h)))

(defparameter *support-instructions*
  "Above is part of a conversation. Below are observations another pass drew from it, numbered. Record the numbers of the ones the conversation states or clearly implies. Leave out any it does not support, including any that add details, names, dates or numbers the conversation does not contain."
  "What the support check asks of its provider.")

(defun supported-proposals (provider window distillation)
  "DISTILLATION with only the proposals PROVIDER finds WINDOW supports. When the check itself
fails, no proposal is kept: an unchecked proposal is what the check exists to keep out."
  (let* ((proposals (distil:distillation-proposals distillation))
         (listing (with-output-to-string (s)
                    (loop for p in proposals for i from 1
                          do (format s "~D. ~A~%" i (distil:proposal-content p)))))
         (arguments (ignore-errors
                     (llm:generate-structured
                      provider
                      (append window (list (llm:msg "user" (format nil "~A~%~%~A" *support-instructions* listing))))
                      (%support-spec))))
         (numbers (and (hash-table-p arguments) (gethash "supported" arguments)))
         (keep (and (or (listp numbers) (vectorp numbers))
                    (loop for n in (coerce numbers 'list)
                          when (and (integerp n) (<= 1 n (length proposals)))
                            collect (nth (1- n) proposals)))))
    (distil::%make-distillation :subject (distil:distillation-subject distillation)
                                :proposals (remove-duplicates keep))))
