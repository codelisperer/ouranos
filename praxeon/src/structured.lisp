;;;; structured.lisp --- ask for a record and get a record (pre-publication issue 416).
;;;;
;;;; The problem this removes: the only way to get structured output before this was to
;;;; describe the shape in the system prompt and parse whatever text came back. That fails
;;;; two ways. The model returns prose around the JSON, and the model returns a field with
;;;; the right name and the wrong type. Neither is detectable without the schema, and the
;;;; caller already wrote the schema down when it built the tool-spec.
;;;;
;;;; So: force the named tool, take the arguments the model returned, and check them against
;;;; that spec before handing them back.
;;;;
;;;; NO PARTIAL RESULTS. A half-valid record is the failure this exists to remove, so a
;;;; result that fails validation is signalled rather than returned with the bad fields
;;;; dropped or defaulted. The caller can repair, re-ask, or give up; it cannot accidentally
;;;; store something that looks like a record and is not.

(in-package #:praxeon/llm)

(defparameter *default-structured-attempts* 3
  "How many times GENERATE-STRUCTURED will ask before giving up, counting the first.

Bounded because the repair loop asks a model to fix its own output, and a model that cannot
produce the shape will not start doing so on the fourth try. An unbounded loop against a
metered API is a bill rather than a retry.")

;;; --- validating the returned arguments --------------------------------------

(defun %schema-get (schema key)
  (and (hash-table-p schema) (gethash key schema)))

(defun %json-type-matches-p (value type)
  "Does VALUE satisfy the JSON-schema TYPE name?

Only the types a tool's arguments actually use. An unknown type name returns T rather than
refusing: this validates what it understands and does not pretend to be a JSON-schema
implementation, which would fail in a way a caller could not predict."
  (cond
    ((string= type "string") (stringp value))
    ((string= type "integer") (integerp value))
    ((string= type "number") (realp value))
    ((string= type "boolean") (or (eq value t) (eq value :false) (null value)))
    ((string= type "array") (or (listp value) (vectorp value)))
    ((string= type "object") (hash-table-p value))
    (t t)))

(defun validate-against-schema (schema arguments)
  "Problems with ARGUMENTS against SCHEMA, as a list of strings. Empty means acceptable.

Checks the two things that actually go wrong: a required property missing, and a property
present with the wrong type. It reports EVERY problem rather than the first, because the
repair prompt built from this is what the model has to act on -- handing it one problem at a
time turns one re-ask into four."
  (let ((problems '())
        (properties (%schema-get schema "properties"))
        (required (%schema-get schema "required")))
    (when (hash-table-p arguments)
      (when required
        (map nil (lambda (name)
                   (multiple-value-bind (value present) (gethash name arguments)
                     (declare (ignore value))
                     (unless present
                       (push (format nil "required property ~S is missing" name) problems))))
             required))
      (when (hash-table-p properties)
        (maphash (lambda (name value)
                   (let* ((spec (gethash name properties))
                          (type (and (hash-table-p spec) (gethash "type" spec))))
                     (when (and type (not (%json-type-matches-p value type)))
                       (push (format nil "property ~S should be of type ~A" name type)
                             problems))))
                 arguments)))
    (unless (hash-table-p arguments)
      (push "the tool was called with no argument object" problems))
    (nreverse problems)))

(defparameter +enforced-schema-keys+ '("type" "properties" "required" "description" "title")
  "The schema keys `validate-against-schema' reads. Everything else is decoration to it.

`type' and `description' are read per property; `properties' and `required' at the top level
only. `title' is never read and is here because it carries no constraint, so declaring it
promises nothing.")

(defun %unenforced-in (schema path)
  "Declarations in SCHEMA that `validate-against-schema' will not check, as strings."
  (let ((found '()))
    (when (hash-table-p schema)
      (maphash
       (lambda (key value)
         (cond
           ;; A nested object or array carries declarations one level down, and the
           ;; validator never goes there.
           ((and (string= key "properties") (string/= path ""))
            (push (format nil "~a.properties" path) found))
           ((string= key "items")
            (push (format nil "~a.items" path) found))
           ((member key +enforced-schema-keys+ :test #'string=)
            (when (and (string= key "properties") (hash-table-p value))
              (maphash (lambda (prop spec)
                         (setf found (append (%unenforced-in
                                              spec (if (string= path "")
                                                       prop
                                                       (format nil "~a.~a" path prop)))
                                             found)))
                       value)))
           (t (push (format nil "~a.~a" (if (string= path "") "(root)" path) key) found))))
       schema))
    found))

(defun unenforced-declarations (schema)
  "What SCHEMA declares that `validate-against-schema' does not check.

A list of dotted paths, empty when everything declared is also enforced. `enum', `minLength',
`pattern', an `items' schema and any nested `properties' all reach the provider -- the model
is shown them and may well comply -- and none of them is read when the reply comes back."
  (sort (remove-duplicates (%unenforced-in schema "") :test #'string=) #'string<))

(define-condition unenforceable-schema (praxeon/conditions:praxeon-error)
  ((tool :initarg :tool :reader unenforceable-schema-tool)
   (declarations :initarg :declarations :initform '() :reader unenforceable-schema-declarations))
  (:report
   (lambda (c s)
     (format s "~S declares constraints that nothing checks, and carries no validator:~%~{  - ~A~%~}~%~A"
             (unenforceable-schema-tool c)
             (unenforceable-schema-declarations c)
             "These reach the provider, so the model is shown them and may comply -- which is why the gap is invisible until it is not. VALIDATE-AGAINST-SCHEMA reads required properties and top-level types and nothing else. Either drop them from the schema, or add a function to the spec's TOOL-SPEC-VALIDATORS that checks what they promise.")))
  (:documentation "A tool-spec declares what it cannot enforce and supplies no validator.

REFUSING RATHER THAN DOCUMENTING. A schema declaration is not inert: it is sent to the
provider, so a model shown `enum: [a, b]' usually returns a or b, and a caller watching that
work concludes the constraint is enforced. It is the model's compliance doing the work, and
it holds until the day it does not. Silence was the defect (pre-publication issue 454), and a validator that
ignores half its input is not made safe by saying so in a docstring.

NOT A CLAIM THAT THE VALIDATOR IS CORRECT. This checks that a spec declaring something
unenforceable carries a validator at all -- that somebody took responsibility for the gap.
Whether that function actually checks the declaration is not decidable here and is not
claimed."))

(defun check-schema-enforceable (spec)
  "Signal `unenforceable-schema' when SPEC declares what nothing will check."
  (let ((declarations (unenforced-declarations (tool-spec-schema spec))))
    (when (and declarations (null (tool-spec-validators spec)))
      (error 'unenforceable-schema
             :tool (tool-spec-name spec)
             :declarations declarations))))

(defun validate-arguments (spec arguments)
  "Problems with ARGUMENTS for TOOL-SPEC, as a list of strings.

Schema first, then the caller's own validators. The order matters: a length validator that
runs against a missing field reports a confusing second problem, so the structural checks go
first and the caller's checks see arguments that are at least the right shape."
  (let ((problems (validate-against-schema (tool-spec-schema spec) arguments)))
    (if problems
        problems
        (loop for validator in (tool-spec-validators spec)
              for problem = (funcall validator arguments)
              when problem collect problem))))

;;; --- the conditions ---------------------------------------------------------

(define-condition structured-result-invalid (praxeon/conditions:praxeon-error)
  ((tool :initarg :tool :reader structured-result-invalid-tool)
   (problems :initarg :problems :initform '() :reader structured-result-invalid-problems)
   (arguments :initarg :arguments :initform nil :reader structured-result-invalid-arguments)
   (attempt :initarg :attempt :initform 1 :reader structured-result-invalid-attempt))
  (:report
   (lambda (c s)
     (format s "The model's call to ~S did not match its schema (attempt ~D):~%~{  - ~A~%~}"
             (structured-result-invalid-tool c)
             (structured-result-invalid-attempt c)
             (structured-result-invalid-problems c))))
  (:documentation "The forced tool was called with arguments that failed validation."))

(define-condition structured-result-rejected (condition)
  ((tool :initarg :tool :reader structured-result-rejected-tool)
   (problems :initarg :problems :initform '() :reader structured-result-rejected-problems)
   (arguments :initarg :arguments :initform nil :reader structured-result-rejected-arguments)
   (attempt :initarg :attempt :initform 1 :reader structured-result-rejected-attempt))
  (:report
   (lambda (c s)
     (format s "Attempt ~D at ~S was rejected:~%~{  - ~A~%~}"
             (structured-result-rejected-attempt c)
             (structured-result-rejected-tool c)
             (structured-result-rejected-problems c))))
  (:documentation
   "One attempt was rejected. NOT an error, and deliberately a different type from
STRUCTURED-RESULT-INVALID.

Using one type for both meant any handler for it -- including a test's `signals' -- caught
the FIRST rejection and took control, so the repair loop never ran and the bounded-attempts
behaviour could not be observed. `an attempt was rejected, you may intervene' and `this
failed' are different events and a caller needs to be able to handle one without the other."))

(define-condition structured-result-not-called (praxeon/conditions:praxeon-error)
  ((tool :initarg :tool :reader structured-result-not-called-tool))
  (:report
   (lambda (c s)
     (format s "The model did not call ~S, although it was required to.~%~%This is not the same failure as bad arguments: the provider accepted a forced tool choice and then returned something else, so either the provider did not honour it or the reply was not what it claimed. Returning the model's prose here would hand a caller expecting a record a paragraph instead."
             (structured-result-not-called-tool c))))
  (:documentation "A forced tool choice produced a reply with no call to that tool."))

;;; --- the loop ---------------------------------------------------------------

(defun %repair-message (problems)
  "The message appended when re-asking. Names every problem, in the model's own terms."
  (format nil "The previous call was rejected for these reasons:~%~{- ~A~%~}Call the tool again with corrected arguments. Change only what is listed."
          problems))

(defun %find-call (completion name)
  (find name (completion-tool-calls completion)
        :key #'tool-call-name :test #'string=))

(defun generate-structured (provider messages spec
                            &key system (max-tokens *default-max-tokens*) temperature
                                 (attempts *default-structured-attempts*))
  "Ask PROVIDER for one call to SPEC and return its validated arguments.

Forces the tool rather than describing the shape in a prompt, and validates what comes back
against SPEC's schema and SPEC's own validators.

ON A MISMATCH IT SIGNALS STRUCTURED-RESULT-REJECTED WITH A `RE-ASK' RESTART, using SIGNAL
so that a caller's handler runs first. When the attempts are exhausted it signals
STRUCTURED-RESULT-INVALID as an error -- a different type, so a caller can watch rejections
without catching the failure, or catch the failure without seeing every rejection. A caller can watch every rejected attempt, stop early by
transferring control with HANDLER-CASE, or invoke `re-ask' itself. When nobody takes control
the default applies: repair while attempts remain, counting the first, then signal the
condition as an error.

The order matters and is easy to get wrong. Handlers are searched innermost outward, so a
HANDLER-BIND established inside this function would run before the caller's and make the
caller's unreachable.

The re-ask appends the failed call and every problem with it, so the next attempt sees what
it did and what was wrong. Re-asking without that is asking the same question again.

Returns the arguments hash-table. Never returns a partial record: a result that fails
validation is signalled, not returned with bad fields dropped or defaulted, because a
half-valid record is the failure this exists to remove."
  (check-tool-choice provider (list :tool (tool-spec-name spec)))
  ;; BEFORE THE FIRST REQUEST, not after a reply comes back. A schema declaring what nothing
  ;; checks is wrong on every call, so failing on the first one costs no tokens and points at
  ;; the spec rather than at the model's answer (pre-publication issue 454).
  (check-schema-enforceable spec)
  (let ((conversation (copy-list messages))
        (attempt 0))
    (loop
      (incf attempt)
      (let* ((completion (complete provider conversation
                                   :system system
                                   :tools (list spec)
                                   :max-tokens max-tokens
                                   :temperature temperature
                                   :tool-choice (list :tool (tool-spec-name spec))))
             (call (%find-call completion (tool-spec-name spec))))
        (unless call
          (error 'structured-result-not-called :tool (tool-spec-name spec)))
        (let ((problems (validate-arguments spec (tool-call-arguments call))))
          (when (null problems)
            (return-from generate-structured (tool-call-arguments call)))
          ;; SIGNAL, not ERROR, so a caller's handler runs and can transfer control.
          ;; An inner HANDLER-BIND would run first -- handlers are searched innermost
          ;; outward -- so establishing the default repair here would make the caller's
          ;; handler unreachable, which is the opposite of what the restart is for.
          ;; SIGNAL returns when nobody transfers control, and the default applies then.
          ;; SIGNAL the per-attempt notification, not the error. SIGNAL returns when
          ;; nobody transfers control, and handlers are searched innermost outward -- so a
          ;; HANDLER-BIND established inside this function would run before the caller's and
          ;; make the caller's unreachable.
          (let ((retry nil))
            (restart-case
                (signal 'structured-result-rejected
                        :tool (tool-spec-name spec)
                        :problems problems
                        :arguments (tool-call-arguments call)
                        :attempt attempt)
              (re-ask ()
                :report "Ask again, appending the validation problems."
                (setf retry t)))
            ;; Nobody took control and nobody asked for a repair: repair while attempts
            ;; remain. Unbounded repair against a metered API is a bill rather than a retry.
            (when (and (not retry) (< attempt attempts))
              (setf retry t))
            (unless retry
              (error 'structured-result-invalid
                     :tool (tool-spec-name spec)
                     :problems problems
                     :arguments (tool-call-arguments call)
                     :attempt attempt))
            (unless retry (return))
            (setf conversation
                  (append conversation
                          ;; A message is a plist (:role R :content C) -- see the note at
                          ;; the top of llm.lisp. There is no message struct.
                          (list (list :role :assistant
                                      :content (format nil "Called ~A." (tool-spec-name spec)))
                                (list :role :user
                                      :content (%repair-message problems)))))))))))
