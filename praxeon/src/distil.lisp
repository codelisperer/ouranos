;;;; distil.lisp --- turning a window of a transcript into observations
;;;;
;;;; The store (pre-publication issue 60) answers where an observation lives. This answers where one comes from
;;;; when nobody wrote it by hand.
;;;;
;;;; TWO CLAIMS, NOT ONE, AND THEY ARE NOT EQUALLY TRUSTWORTHY (pre-publication issue 452).
;;;;
;;;; Extracting an observation is a claim about CONTENT: the model read a window and says
;;;; what is in it. The window is right there to check it against.
;;;;
;;;; Saying that a new observation REPLACES an existing one is a claim about IDENTITY -- that
;;;; the two are about the same thing -- and the existing observation is not in the window.
;;;; The model has to be handed what is already believed and then judge sameness, which is
;;;; the judgement it is worst at and the one whose errors are least visible: a wrong
;;;; `remember' adds a bad fact, while a wrong `supersede' adds a bad fact AND removes a good
;;;; one from the current set, after which `recall' returns a shorter, cleaner, confidently
;;;; wrong answer.
;;;;
;;;; So this pass PROPOSES supersessions and the caller applies them. `apply-distillation'
;;;; remembers everything and supersedes nothing unless the caller says otherwise. Auto
;;;; applying proposals is a caller-side decision that needs no change here; widening this
;;;; surface later to take it back would not be.

(cl:in-package #:praxeon/distil)

;;; --- what a window yields ---------------------------------------------------

(defstruct (proposal (:constructor %make-proposal))
  "One observation the pass extracted, and its optional claim to replace another.

REPLACES is the id of an existing observation, or NIL. BECAUSE is the model's stated reason
for that pairing.

BECAUSE IS NOT DECORATION. A proposal is reviewable only if a reviewer can see what the
pairing rests on; a bare list of id pairs is rubber-stampable, which is applying them
automatically with extra steps. `distil' drops any proposed replacement that arrives without
a reason rather than presenting an unreviewable one."
  (content "" :type string)
  (kind :observation :type keyword)
  (replaces nil)
  (because nil)
  ;; APPLIES-FROM is when the fact holds from, as a universal time, when the window says so
  ;; ("from next Monday", "since March"), or NIL (#317). It becomes the observation's
  ;; VALID-FROM; questions about time are where summaries most often go wrong.
  (applies-from nil :type (or null integer)))

(defstruct (distillation (:constructor %make-distillation))
  "What one window yielded. NOTHING HERE IS STORED. `apply-distillation' writes."
  (subject "" :type string)
  (proposals '() :type list))

(defun make-distillation (subject proposals)
  "A DISTILLATION of PROPOSALS about SUBJECT, for a caller that filters another one's proposals,
as the observer's support check does."
  (%make-distillation :subject subject :proposals proposals))

(defun distillation-replacements (distillation)
  "The proposals in DISTILLATION that claim to replace an existing observation."
  (remove-if-not #'proposal-replaces (distillation-proposals distillation)))

;;; --- the tool ---------------------------------------------------------------

(defparameter +kinds+ '("correction" "preference" "fact" "observation")
  "The kinds an extracted observation may carry, matching `praxeon/memory''s.

Named here as strings because this is what the model is told; the keyword conversion is
`%kind' and it refuses anything else rather than defaulting, so a kind the model invented
does not silently become :OBSERVATION.")

(defun %kind (name)
  "NAME as an observation kind keyword, or NIL when it is not one of `+kinds+'."
  (and (stringp name)
       (find name +kinds+ :test #'string-equal)
       (intern (string-upcase name) :keyword)))

(defun %hash (&rest pairs)
  (let ((ht (make-hash-table :test #'equal)))
    (loop for (k v) on pairs by #'cddr do (setf (gethash k ht) v))
    ht))

(defun %schema ()
  "The tool's JSON schema.

DELIBERATELY SHALLOW AT THE TOP AND CHECKED PROPERLY IN A VALIDATOR.
`llm:validate-against-schema' checks required top-level properties and top-level
types; it does not descend into array items, and it says so. Declaring per-item structure
here would look like validation and not be any. The per-observation checks are in
`%validate-observations' below, which is what `tool-spec-validators' exists for."
  (%hash "type" "object"
         "properties"
         (%hash "observations"
                (%hash "type" "array"
                       "description"
                       "The few things from this window worth remembering. Empty when there is nothing."
                       "items"
                       (%hash "type" "object"
                              "properties"
                              (%hash "content" (%hash "type" "string"
                                                      "description" "The observation, as one self-contained sentence.")
                                     "kind" (%hash "type" "string"
                                                   "enum" (coerce +kinds+ 'vector)
                                                   "description" "Why this is being recorded.")
                                     "replaces" (%hash "type" "string"
                                                       "description"
                                                       "The id of an existing observation this corrects. Omit unless it is the same thing.")
                                     "because" (%hash "type" "string"
                                                      "description"
                                                      "Required with `replaces': why the two are about the same thing.")
                                     "applies_from" (%hash "type" "string"
                                                           "description"
                                                           "The date this holds from, as YYYY-MM-DD, only when the conversation states one. Omit otherwise."))
                              "required" (vector "content" "kind"))))
         "required" (vector "observations")))

(defun parse-date (string)
  "The universal time at midnight UTC of STRING, a date written YYYY-MM-DD, or NIL when STRING
is not one. An impossible date is not one: 2026-02-30 is refused rather than read as March 2,
and a year before 1900, which ENCODE-UNIVERSAL-TIME would read as a two-digit year, is refused
too. The date is decoded again and must come back as written."
  (and (stringp string) (= (length string) 10)
       (char= (char string 4) #\-) (char= (char string 7) #\-)
       ;; Each digit position checked by itself: "2026-1--02" has seven digits and the two
       ;; dashes in place, and its month field "1-" is not a number (#462's second review).
       (loop for i in '(0 1 2 3 5 6 8 9) always (digit-char-p (char string i)))
       (let ((year (parse-integer string :start 0 :end 4))
             (month (parse-integer string :start 5 :end 7))
             (day (parse-integer string :start 8 :end 10)))
         (and (>= year 1900) (<= 1 month 12) (<= 1 day 31)
              (let ((time (ignore-errors (encode-universal-time 0 0 0 day month year 0))))
                (and time
                     (multiple-value-bind (s m h d mo y) (decode-universal-time time 0)
                       (declare (ignore s m h))
                       (and (= d day) (= mo month) (= y year)))
                     time))))))

(defun %date-given-p (value)
  "Whether VALUE, an applies_from field as parsed, says a date at all: NIL, JSON null and an
empty string say none."
  (and value (stringp value) (plusp (length value))))

(defun %items (arguments)
  "The observations array from ARGUMENTS as a list, or NIL when it is absent or not a sequence."
  (let ((raw (and (hash-table-p arguments) (gethash "observations" arguments))))
    (cond ((listp raw) raw)
          ((vectorp raw) (coerce raw 'list))
          (t nil))))

(defun %validate-observations (arguments)
  "Problems with the observations array, as one string, or NIL.

This is the check the schema cannot do. It reports the index with each problem, because the
repair prompt is what the model has to act on and `content is missing' over an array of six
does not say which one."
  (let ((raw (and (hash-table-p arguments) (gethash "observations" arguments)))
        (problems '()))
    (unless (or (listp raw) (vectorp raw))
      (return-from %validate-observations "`observations' must be an array"))
    (loop for item in (%items arguments)
          for i from 0
          do (cond
               ((not (hash-table-p item))
                (push (format nil "observation ~D is not an object" i) problems))
               (t
                (let ((content (gethash "content" item))
                      (kind (gethash "kind" item))
                      (replaces (gethash "replaces" item))
                      (because (gethash "because" item)))
                  (unless (and (stringp content) (plusp (length content)))
                    (push (format nil "observation ~D has no `content'" i) problems))
                  (unless (%kind kind)
                    (push (format nil "observation ~D has kind ~S, which is not one of ~{~A~^, ~}"
                                  i kind +kinds+)
                          problems))
                  ;; A replacement without a reason is refused HERE rather than dropped
                  ;; silently later, so the model is told and can repair it on the next
                  ;; attempt. Dropping it would hide a claim the model actually made.
                  (when (and (stringp replaces) (plusp (length replaces))
                             (not (and (stringp because) (plusp (length because)))))
                    (push (format nil "observation ~D claims to replace ~A with no `because'" i replaces)
                          problems))
                  ;; A date that cannot be read is NOT a problem here: refusing it would lose
                  ;; the whole window for one field. DISTIL drops that one proposal instead.
                  ))))
    (when problems
      (format nil "~{~A~^; ~}" (nreverse problems)))))

(defun observation-tool ()
  "The tool-spec the pass forces."
  (llm:make-tool-spec
   :name "record_observations"
   :description
   "Record the few things from this conversation worth remembering about the person, and nothing else."
   :schema (%schema)
   :validators (list #'%validate-observations)))

;;; --- the prompt -------------------------------------------------------------

(defparameter *system-prompt*
  "You are extracting durable facts about a person from part of a conversation.

Record only what would still be worth knowing weeks from now: preferences, corrections, and
stable facts about them. Do not record what was merely discussed, what you inferred without
being told, or anything about you.

Each observation must be one self-contained sentence that makes sense with no other context.

You may be shown what is already believed about this person. If one of your observations
corrects one of those, set `replaces' to its id and say in `because' why the two are about
the same thing. Only do that when they are the same thing -- a new fact that sits alongside
an old one is not a correction. If you are unsure, leave `replaces' out and record it as a
new observation."
  "The extraction instruction. Separate from the code so a caller can replace it, and worth
reading next to `+kinds+': the two have to agree about what a kind means.")

(defun %known-block (known)
  "KNOWN observations rendered for the prompt, or NIL when there are none."
  (when known
    (format nil "Already believed about this person:~%~{~A~%~}"
            (mapcar (lambda (o)
                      (format nil "  [~A] ~A"
                              (mem:observation-id o)
                              (mem:observation-content o)))
                    known))))

;;; --- the pass ---------------------------------------------------------------

(defun date-string (time)
  "TIME, a universal time, as the date YYYY-MM-DD in UTC."
  (multiple-value-bind (s m h d mo y) (decode-universal-time time 0)
    (declare (ignore s m h))
    (format nil "~4,'0D-~2,'0D-~2,'0D" y mo d)))

(defun distil (provider subject window &key known (system *system-prompt*)
                                            max-tokens attempts today)
  "Extract observations about SUBJECT from WINDOW. Returns a DISTILLATION, or NIL.

WINDOW is the messages to read. KNOWN is the observations already held, offered so the model
can propose a replacement; without it every result is a new observation. TODAY, a universal
time, is the date the model is told the window was written on, so that \"from next Monday\" or
\"since March\" can become an APPLIES-FROM date; without it the model is told no date and
should give none.

A PROPOSAL WHOSE APPLIES-FROM CANNOT BE READ IS DROPPED, alone (#317's review): the rest of the
window is kept. A null or empty APPLIES-FROM is no date, and the proposal is kept without one.

RETURNS TWO VALUES: the distillation and NIL, or NIL and the condition that stopped it.

A WINDOW THAT CANNOT BE DISTILLED YIELDS NOTHING. Not a low-confidence observation, not a
flagged one. An output the model could not fit to the schema still reads plausibly, and
whatever doubt attached to it is gone the moment it is a row like any other. Skipping a
window loses information that was never reliable; recording it damages a store whose whole
value is that recall can be trusted.

BOTH FAILURES ARE CAUGHT, WHICH IS TWO CONDITIONS AND NOT ONE.
`structured-result-invalid' is the model failing to match the schema. `structured-result-not-called'
is the provider accepting a forced tool choice and returning prose anyway. They are separate
types in praxeon/llm and only the first is about the model's arguments, so a handler for that
one alone leaves the other to reach the caller as an unhandled error from a pass documented
to skip.

This function is the caller that skips, so the HANDLER-CASE belongs here and not inside
`generate-structured'. Handlers are searched innermost outward: one established within that
function's extent would preempt every caller's."
  (let* ((block (%known-block known))
         (dated (when today
                  (format nil "Today is ~A. Write any applies_from date against that." (date-string today))))
         (preface (format nil "~@[~A~%~%~]~@[~A~]" dated block))
         (messages (append (when (plusp (length preface)) (list (llm:msg "user" preface)))
                           window)))
    (handler-case
        (let ((arguments (apply #'llm:generate-structured
                                provider messages (observation-tool)
                                :system system
                                (append (when max-tokens (list :max-tokens max-tokens))
                                        (when attempts (list :attempts attempts))))))
          (values (%make-distillation
                   :subject subject
                   :proposals (loop for item in (%items arguments)
                                    for replaces = (gethash "replaces" item)
                                    for because = (gethash "because" item)
                                    for date = (gethash "applies_from" item)
                                    ;; One unreadable date loses its own proposal, not the window.
                                    unless (and (%date-given-p date) (not (parse-date date)))
                                    collect (%make-proposal
                                             :content (gethash "content" item)
                                             :kind (%kind (gethash "kind" item))
                                             ;; Both or neither. The validator already
                                             ;; refuses a replacement with no reason, so
                                             ;; reaching here without one means the field
                                             ;; was blank rather than missing.
                                             :replaces (when (and (stringp replaces)
                                                                  (plusp (length replaces))
                                                                  (stringp because)
                                                                  (plusp (length because)))
                                                         replaces)
                                             :because (when (stringp because) because)
                                             :applies-from (and (%date-given-p date) (parse-date date)))))
                  nil))
      ((or llm:structured-result-invalid
           llm:structured-result-not-called) (c)
        (values nil c)))))

(defun apply-distillation (store distillation &key provenance (accept (constantly nil)) thread)
  "Write DISTILLATION into STORE. Returns the observations written.

PROVENANCE IS REQUIRED AND BELONGS TO THE WINDOW, NOT TO THIS CALL (#150). A distillation
pass reads a conversation that already happened, so the source of everything it writes is
that conversation and its turn -- not the moment the pass ran. Passing it in rather than
manufacturing one here is what keeps `when did they tell us this' answerable: the caller is
the only party that knows which window this was, and a pass that invented a source would
produce observations citing a turn nobody had.

REMEMBERS EVERYTHING AND SUPERSEDES NOTHING, unless ACCEPT says otherwise. ACCEPT is called
with the proposal and the existing observation it claims to replace, and returns true to
apply the replacement. The default refuses every one, so a caller that has not thought about
supersession gets the safe behaviour rather than the convenient one.

A REFUSED PROPOSAL STILL RECORDS ITS CONTENT, as an ordinary observation. Only the identity
claim is dropped -- the model's reading of the window is the half that was checkable, and
throwing it away because the pairing was rejected would discard a good claim along with a
doubtful one.

A proposal naming an id that is not in the store is recorded as an ordinary observation too.
That is a proposal about something this store cannot show anyone, so there is nothing to
review and nothing to replace.

THREAD, when given, writes the observations into that thread's scope, and looks for the
observation a proposal replaces only there (#317). A proposal's APPLIES-FROM becomes its
observation's valid-from."
  (let ((written '()))
    (dolist (p (distillation-proposals distillation) (nreverse written))
      (let* ((target (and (proposal-replaces p)
                          (find (proposal-replaces p)
                                (mem:observations-of
                                 store (distillation-subject distillation) :thread thread)
                                :key #'mem:observation-id
                                :test #'equal)))
             (replace-p (and target
                             (mem:observation-current-p target)
                             (funcall accept p target))))
        (push (if replace-p
                  (mem:supersede store target (proposal-content p)
                                            :provenance provenance
                                            :kind (proposal-kind p)
                                            :valid-from (proposal-applies-from p))
                  (mem:remember store (distillation-subject distillation)
                                           (proposal-content p)
                                           :provenance provenance
                                           :kind (proposal-kind p)
                                           :valid-from (proposal-applies-from p)
                                           :thread thread))
              written)))))
