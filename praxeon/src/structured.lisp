;;;; structured.lisp --- ask for a record and get a record (pre-publication issue 416).
;;;;
;;;; The problem this removes: the only way to get structured output before this was to
;;;; describe the shape in the system prompt and parse whatever text came back. That fails
;;;; two ways. The model returns prose around the JSON, and the model returns a field with
;;;; the right name and the wrong type. Neither is detectable without the schema, and the
;;;; caller already wrote the schema down when it built the tool-spec.
;;;;
;;;; So: force the named tool, take the arguments the model returned, and check them against
;;;; that spec before handing them back. A provider that cannot force a tool but takes a schema
;;;; as response_format is asked that way instead, and the JSON object in its reply's text is
;;;; checked the same way (#680).
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

;;; --- a schema sent as response_format (#680) --------------------------------
;;;
;;; A provider may refuse some schemas in response_format, and says which through
;;; RESPONSE-FORMAT-SCHEMA-PROBLEM, which llm.lisp defines with the rest of the provider
;;; protocol. SCHEMA-RECURSION finds a recursive schema: one whose $ref chain leads back to a
;;; schema it started from. A provider that refuses recursive schemas calls it from its method.

(defparameter +data-keywords+ '("examples" "default" "const" "enum")
  "Schema keywords whose values are JSON data, not schemas. A $ref or $anchor inside one is
part of an example or a constant and refers to nothing (#686).")

(defparameter +named-schema-keywords+
  '("properties" "patternProperties" "$defs" "definitions" "dependentSchemas")
  "Schema keywords whose value is an object of names to schemas. Its keys are names, so a
property called \"default\" is a schema like any other property.")

(defun %walk-schemas (fn node)
  "Call FN on every schema object inside NODE, NODE included when it is one, without entering
the values of +DATA-KEYWORDS+. A keyword not named in either list is read as holding schemas,
so an unfamiliar one is checked rather than skipped."
  (labels ((schema (node)
             (cond ((hash-table-p node)
                    (funcall fn node)
                    (maphash (lambda (key value)
                               (cond ((member key +data-keywords+ :test #'equal))
                                     ((and (member key +named-schema-keywords+ :test #'equal)
                                           (hash-table-p value))
                                      (maphash (lambda (name sub) (declare (ignore name))
                                                 (schema sub))
                                               value))
                                     (t (schema value))))
                             node))
                   ((and (vectorp node) (not (stringp node))) (map nil #'schema node))
                   ((consp node) (map nil #'schema node)))))
    (schema node)))

(defun %anchor-target (root name)
  "The schema inside ROOT whose $anchor is NAME, or NIL."
  (%walk-schemas (lambda (node)
                   (when (equal (gethash "$anchor" node) name)
                     (return-from %anchor-target node)))
                 root)
  nil)

(defun %percent-decode (text)
  "TEXT with each %XX replaced by the octet it encodes, the octets read as UTF-8, or NIL when
TEXT has a malformed escape or the octets are not UTF-8. A $ref is a URI, so a fragment such
as #/$defs/%6Eode names the definition node (#686)."
  (if (not (find #\% text))
      text
      (let ((octets (make-array (length text) :element-type '(unsigned-byte 8) :fill-pointer 0)))
        (loop with i = 0
              while (< i (length text))
              do (let ((c (char text i)))
                   (cond ((char/= c #\%)
                          (loop for o across (sb-ext:string-to-octets (string c)
                                                                       :external-format :utf-8)
                                do (vector-push o octets))
                          (incf i))
                         ((and (<= (+ i 3) (length text))
                               (digit-char-p (char text (+ i 1)) 16)
                               (digit-char-p (char text (+ i 2)) 16))
                          (vector-push (parse-integer text :start (1+ i) :end (+ i 3) :radix 16)
                                       octets)
                          (incf i 3))
                         (t (return-from %percent-decode nil)))))
        (handler-case (sb-ext:octets-to-string (coerce octets '(vector (unsigned-byte 8)))
                                               :external-format '(:utf-8 :replacement nil))
          (error () nil)))))

(defun %pointer-target (root ref)
  "The schema REF names inside ROOT, or NIL when REF is not local or names nothing. A local
reference is \"#\" (the root), a JSON pointer \"#/a/b\", or \"#name\", the schema whose
$anchor is name. The fragment is percent-decoded first, because a $ref is a URI; a pointer is
then split into tokens, and each token's escapes are read as JSON pointer defines them (~1 is
/, ~0 is ~)."
  (let ((fragment (and (stringp ref) (plusp (length ref)) (char= (char ref 0) #\#)
                       (%percent-decode (subseq ref 1)))))
    (cond
      ((null fragment) nil)
      ((string= fragment "") root)
      ((char/= (char fragment 0) #\/) (%anchor-target root fragment))
      (t
        (let ((node root))
          (dolist (token (rest (uiop:split-string fragment :separator "/")) node)
            (let ((key (%unescape-pointer-token token)))
              (setf node (cond ((hash-table-p node) (gethash key node))
                               ((and (vectorp node) (not (stringp node))
                                     (every #'digit-char-p key) (plusp (length key))
                                     (< (parse-integer key) (length node)))
                                (aref node (parse-integer key)))
                               (t (return nil)))))))))))

(defun %unescape-pointer-token (token)
  (with-output-to-string (out)
    (loop with i = 0
          while (< i (length token))
          do (let ((c (char token i)))
               (if (and (char= c #\~) (< (1+ i) (length token))
                        (member (char token (1+ i)) '(#\0 #\1)))
                   (progn (write-char (if (char= (char token (1+ i)) #\1) #\/ #\~) out)
                          (incf i 2))
                   (progn (write-char c out) (incf i)))))))

(defun %refs-in (schema)
  "Every $ref string in a schema inside SCHEMA, in the order found. A $ref inside an example,
a default, a const or an enum value is data and is not collected."
  (let ((refs '()))
    (%walk-schemas (lambda (node)
                     (let ((ref (gethash "$ref" node)))
                       (when (stringp ref) (push ref refs))))
                   schema)
    (nreverse refs)))

(defun schema-recursion (schema)
  "A list of the references that lead from a schema inside SCHEMA back to itself, or NIL when
there is no such chain. Only local references (\"#...\") are followed; any other cannot be
resolved here and is ignored."
  (let ((state (make-hash-table :test #'eq))) ; node -> :visiting or :done
    (labels ((visit (node path)
               (case (gethash node state)
                 (:visiting (return-from schema-recursion (reverse path)))
                 (:done nil)
                 (t (setf (gethash node state) :visiting)
                    (dolist (ref (%refs-in node))
                      (let ((target (%pointer-target schema ref)))
                        (when (hash-table-p target)
                          (visit target (cons ref path)))))
                    (setf (gethash node state) :done)))))
      (when (hash-table-p schema)
        (visit schema '())
        ;; A definition nothing refers to is still sent, so it is checked as well.
        (dolist (key '("$defs" "definitions"))
          (let ((defs (gethash key schema)))
            (when (hash-table-p defs)
              (maphash (lambda (name def)
                         (when (hash-table-p def)
                           (visit def (list (format nil "#/~A/~A" key name)))))
                       defs))))
        nil))))

(define-condition unsendable-schema (praxeon/conditions:praxeon-error)
  ((tool :initarg :tool :reader unsendable-schema-tool)
   (reason :initarg :reason :reader unsendable-schema-reason))
  (:report
   (lambda (c s)
     (format s "The schema of ~S cannot be sent as response_format: ~A. Nothing was sent."
             (unsendable-schema-tool c) (unsendable-schema-reason c))))
  (:documentation "GENERATE-STRUCTURED would send a tool-spec's schema as response_format, and the
provider has said it refuses that schema (RESPONSE-FORMAT-SCHEMA-PROBLEM). Signalled before any
request (#680). REASON says why."))

(defun check-schema-sendable (provider spec)
  "Signal UNSENDABLE-SCHEMA when PROVIDER cannot be sent SPEC's schema as response_format."
  (let ((reason (response-format-schema-problem provider (tool-spec-schema spec))))
    (when reason
      (error 'unsendable-schema :tool (tool-spec-name spec) :reason reason))))

(defun %reply-object (text)
  "The JSON object TEXT holds, or NIL and a problem saying why there is none."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) (or text ""))))
    (if (zerop (length trimmed))
        (values nil "the reply was empty, not a JSON object")
        (let ((value (handler-case (jzon:parse trimmed)
                       (error () (return-from %reply-object
                                   (values nil "the reply was not valid JSON"))))))
          (if (hash-table-p value)
              (values value nil)
              (values nil "the reply was JSON but not an object"))))))

;;; --- the conditions ---------------------------------------------------------

(define-condition structured-result-invalid (praxeon/conditions:praxeon-error)
  ((tool :initarg :tool :reader structured-result-invalid-tool)
   (problems :initarg :problems :initform '() :reader structured-result-invalid-problems)
   (arguments :initarg :arguments :initform nil :reader structured-result-invalid-arguments)
   (attempt :initarg :attempt :initform 1 :reader structured-result-invalid-attempt))
  (:report
   (lambda (c s)
     (format s "The model's result for ~S did not match its schema (attempt ~D):~%~{  - ~A~%~}"
             (structured-result-invalid-tool c)
             (structured-result-invalid-attempt c)
             (structured-result-invalid-problems c))))
  (:documentation "The structured result failed validation: the arguments of the forced tool call,
or, on the response_format path, the reply's text, which was not a JSON object or was one that
did not match the schema (#680)."))

(define-condition structured-result-truncated (structured-result-invalid
                                               praxeon/conditions:output-limit-reached)
  ()
  (:report
   (lambda (c s)
     (format s "The model's reply for ~S reached the output limit of ~D tokens before the model had finished (attempt ~D), so its result may be incomplete (#338).~%~%A handler can ask again with a larger limit (RETRY-WITH-MAX-TOKENS) or take the cut-off arguments (ACCEPT-TRUNCATED). GENERATE-STRUCTURED's :max-tokens sets the limit."
             (structured-result-invalid-tool c)
             (praxeon/conditions:output-limit-reached-max-tokens c)
             (structured-result-invalid-attempt c))))
  (:documentation "Signalled by GENERATE-STRUCTURED when the completion stopped at the output limit
\(stop reason :MAX-TOKENS), whether or not a result came back (#338). ARGUMENTS are what could be
parsed from the cut-off output: the forced call's arguments, or the JSON object in the reply's
text on the response_format path, or NIL when there was none (#680).

A subtype of STRUCTURED-RESULT-INVALID, so a handler an app already has for a result it cannot
use also receives this, and of OUTPUT-LIMIT-REACHED. Signalled with ERROR inside the restarts
RETRY-WITH-MAX-TOKENS and ACCEPT-TRUNCATED. It is not repaired by asking again at the same
limit, which would be cut off again."))

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

(defun %repair-message (problems &optional (strategy :tool-call))
  "The message appended when re-asking. Names every problem, in the model's own terms."
  (ecase strategy
    (:tool-call
     (format nil "The previous call was rejected for these reasons:~%~{- ~A~%~}Call the tool again with corrected arguments. Change only what is listed."
             problems))
    (:response-format
     (format nil "The previous reply was rejected for these reasons:~%~{- ~A~%~}Reply again with one corrected JSON object and nothing else. Change only what is listed."
             problems))))

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
half-valid record is the failure this exists to remove.

A REPLY CUT OFF AT THE OUTPUT LIMIT signals STRUCTURED-RESULT-TRUNCATED (#338), inside the
restarts RETRY-WITH-MAX-TOKENS, which asks again with a larger MAX-TOKENS without counting an
attempt, and ACCEPT-TRUNCATED, which returns the cut-off arguments (NIL when there was no call)
with a second value, :TRUNCATED. That is the one way this returns an unvalidated record, and it
takes a handler that asked for it.

TWO WAYS TO ASK (#680). A provider that can force a tool call (SUPPORTS-TOOL-CHOICE-P) is asked
that way, as above. One that cannot, and takes a schema as response_format instead
(SUPPORTS-RESPONSE-FORMAT-P), is asked through COMPLETE-WITH-SCHEMA, and the JSON object in its
reply's text is the record. That reply is checked the same way: text that is not a JSON object,
or an object that fails validation, is a rejected attempt with the same conditions and restarts
as a bad tool argument, and the re-ask shows the model its reply. A schema the provider refuses
(RESPONSE-FORMAT-SCHEMA-PROBLEM) is refused with UNSENDABLE-SCHEMA before anything is sent. A
provider that can do neither signals TOOL-CHOICE-UNSUPPORTED, as before."
  (let ((strategy (cond ((supports-tool-choice-p provider) :tool-call)
                        ((supports-response-format-p provider) :response-format)
                        (t (check-tool-choice provider (list :tool (tool-spec-name spec)))))))
    ;; BEFORE THE FIRST REQUEST, not after a reply comes back. A schema declaring what nothing
    ;; checks is wrong on every call, so failing on the first one costs no tokens and points at
    ;; the spec rather than at the model's answer (pre-publication issue 454).
    (check-schema-enforceable spec)
    (when (eq strategy :response-format)
      (check-schema-sendable provider spec))
    (%generate-structured strategy provider messages spec system max-tokens temperature attempts)))

(defun %generate-structured (strategy provider messages spec system max-tokens temperature attempts)
  "GENERATE-STRUCTURED's loop, once STRATEGY (:TOOL-CALL or :RESPONSE-FORMAT) is chosen."
  (let ((conversation (copy-list messages))
        (attempt 0))
    (loop
      (incf attempt)
      (let* ((completion (ecase strategy
                           (:tool-call
                            (complete provider conversation
                                      :system system
                                      :tools (list spec)
                                      :max-tokens max-tokens
                                      :temperature temperature
                                      :tool-choice (list :tool (tool-spec-name spec))))
                           (:response-format
                            (complete-with-schema provider conversation spec
                                                  :system system
                                                  :max-tokens max-tokens
                                                  :temperature temperature))))
             (call (and (eq strategy :tool-call) (%find-call completion (tool-spec-name spec))))
             (arguments nil)
             (reply-problem nil)
             (retried nil))
        (ecase strategy
          (:tool-call (setf arguments (and call (tool-call-arguments call))))
          (:response-format (multiple-value-setq (arguments reply-problem)
                              (%reply-object (completion-text completion)))))
        ;; A reply cut off at the output limit is checked before anything else. Its call may be
        ;; missing or its arguments incomplete, and neither is the model's mistake to repair at
        ;; the same limit (#338).
        (when (eq (completion-stop-reason completion) :max-tokens)
          (restart-case (error 'structured-result-truncated
                               :tool (tool-spec-name spec)
                               :problems (list (format nil "the output reached the limit of ~D tokens"
                                                       max-tokens))
                               :arguments arguments
                               :attempt attempt
                               :max-tokens max-tokens)
            (praxeon/conditions:retry-with-max-tokens (new-limit)
              :report "Ask again with a larger output limit."
              :interactive (lambda ()
                             (format *query-io* "~&New output limit, in tokens: ")
                             (finish-output *query-io*)
                             (list (parse-integer (read-line *query-io*))))
              (check-type new-limit (integer 1))
              ;; The same attempt again: a limit too small is not the model's error.
              (setf max-tokens new-limit
                    retried t)
              (decf attempt))
            (praxeon/conditions:accept-truncated ()
              :report "Return the cut-off arguments, marked as truncated."
              (return-from %generate-structured (values arguments :truncated)))))
        (unless retried
          (when (and (eq strategy :tool-call) (null call))
            (error 'structured-result-not-called :tool (tool-spec-name spec)))
          (let ((problems (if reply-problem
                              (list reply-problem)
                              (validate-arguments spec arguments))))
            (when (null problems)
              (return-from %generate-structured arguments))
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
                          :arguments arguments
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
                       :arguments arguments
                       :attempt attempt))
              (unless retry (return))
              (setf conversation
                    (append conversation
                            ;; A message is a plist (:role R :content C) -- see the note at
                            ;; the top of llm.lisp. There is no message struct.
                            (list (list :role :assistant
                                        :content (ecase strategy
                                                   (:tool-call
                                                    (format nil "Called ~A." (tool-spec-name spec)))
                                                   ;; The reply itself, so the model sees what
                                                   ;; it wrote. Never empty: a provider may
                                                   ;; refuse an empty assistant message.
                                                   (:response-format
                                                    (let ((text (completion-text completion)))
                                                      (if (plusp (length text)) text "(empty reply)")))))
                                  (list :role :user
                                        :content (%repair-message problems strategy))))))))))))
