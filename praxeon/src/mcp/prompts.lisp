;;;; prompts.lisp --- an MCP server's prompts (#527, part 4).
;;;;
;;;; Prompts are chosen by the user, and a prompt's text goes in as the user's own turn: that
;;;; is what a prompt is. GET-PROMPT returns its messages; PROMPT-INPUT turns a prompt whose
;;;; messages are all the user's into the input of a RUN-TURN.

(cl:in-package #:praxeon/mcp)

(defstruct (prompt-argument (:constructor %make-prompt-argument))
  "An argument a prompt takes. REQUIRED is true when the prompt cannot be got without it."
  (name "" :type string)
  (description nil)
  (required nil))

(defstruct (prompt (:constructor %make-prompt))
  "A prompt a server lists. ARGUMENTS are PROMPT-ARGUMENT structs."
  (name "" :type string)
  (title nil)
  (description nil)
  (arguments '()))

(define-condition prompt-has-assistant-messages (mcp-error)
  ((prompt :initarg :prompt :reader prompt-has-assistant-messages-prompt))
  (:report (lambda (c s)
             (format s "praxeon/mcp: the prompt ~A has assistant messages, so it is a scripted exchange, not one user turn."
                     (prompt-name (prompt-has-assistant-messages-prompt c)))))
  (:documentation "PROMPT-INPUT was given the messages of a prompt that has assistant messages
as well as user messages. Such a prompt is a scripted exchange, and the app decides what to do
with it; GET-PROMPT's messages are still there to use."))

(defun %prompt-argument-from-json (object)
  (let ((name (gethash "name" object)))
    (and (stringp name)
         (%make-prompt-argument :name name
                                :description (%string-or-nil (gethash "description" object))
                                :required (eq t (gethash "required" object))))))

(defun %prompt-from-json (object)
  (let ((name (gethash "name" object)) (arguments (gethash "arguments" object)))
    (and (stringp name)
         (%make-prompt :name name
                       :title (%string-or-nil (gethash "title" object))
                       :description (%string-or-nil (gethash "description" object))
                       :arguments (and (vectorp arguments) (not (stringp arguments))
                                       (loop for a across arguments
                                             for argument = (and (hash-table-p a)
                                                                 (%prompt-argument-from-json a))
                                             when argument collect argument))))))

(defun list-prompts (client &key principal)
  "The prompts CLIENT's server lists, following each page's nextCursor. An entry without a
string name is left out. A page without a list of prompts signals REQUEST-FAILED."
  (multiple-value-bind (prompts pages)
      (%list-paged client "prompts/list" "prompts" "prompts" principal #'%prompt-from-json)
    (log:info "praxeon/mcp: prompts listed"
              :connection (connection-name (client-connection client))
              :count (length prompts) :pages pages)
    prompts))

(defun %prompt-message (client block role)
  "One message of a prompts/get result as a PRAXEON/LLM message, or a failed request."
  (unless (member role '("user" "assistant") :test #'equal)
    (%request-failed client "its prompt had a message whose role is not user or assistant." '()
                     :outcome :not-run))
  ;; A malformed message fails the reply rather than being left out: leaving one out could turn
  ;; a scripted exchange into what looks like a user-only prompt (#554).
  (let ((blocks (cond ((hash-table-p block) (list block))
                      ((and (vectorp block) (not (stringp block)) (every #'hash-table-p block))
                       (coerce block 'list))
                      (t (%request-failed client "its prompt had a message whose content is not a content block." '()
                                          :outcome :not-run)))))
    (llm:msg role (mapcar (lambda (b) (llm:text-part (%content-text b))) blocks))))

(defun get-prompt (client prompt &key arguments principal)
  "The messages of PROMPT, a PROMPT struct from LIST-PROMPTS, from CLIENT's server, filled in
with ARGUMENTS, an alist of (NAME . STRING). Returns the messages, as PRAXEON/LLM messages, and
the prompt's description.

A required argument that is missing, or a value that is not a string, signals REQUEST-FAILED
before anything is sent. Text content becomes a text part. Image and audio content, a resource
link and a binary embedded resource are described in a line, never included; an embedded text
resource becomes its text. A message that is not an object, whose content is not a content
block, or whose role is not user or assistant fails the call, rather than being left out."
  (check-type prompt prompt)
  (dolist (argument (prompt-arguments prompt))
    (when (and (prompt-argument-required argument)
               (not (assoc (prompt-argument-name argument) arguments :test #'equal)))
      (%request-failed client "the prompt ~A needs the argument ~A." (list (prompt-name prompt)
                                                                              (prompt-argument-name argument))
                       :outcome :not-run)))
  (dolist (pair arguments)
    (unless (and (stringp (car pair)) (stringp (cdr pair)))
      (%request-failed client "an argument of the prompt ~A is not a string." (list (prompt-name prompt))
                       :outcome :not-run)))
  (let* ((params (%object "name" (prompt-name prompt)))
         (table (make-hash-table :test #'equal)))
    (when arguments
      (dolist (pair arguments) (setf (gethash (car pair) table) (cdr pair)))
      (setf (gethash "arguments" params) table))
    (let* ((result (%request client "prompts/get" params :principal principal))
           (messages (gethash "messages" result)))
      (unless (and (vectorp messages) (not (stringp messages)))
        (%request-failed client "its prompt reply had no list of messages." '() :outcome :not-run))
      (unless (every #'hash-table-p messages)
        (%request-failed client "its prompt had a message that is not an object." '() :outcome :not-run))
      (let ((got (loop for m across messages
                       collect (%prompt-message client (gethash "content" m) (gethash "role" m)))))
        (log:info "praxeon/mcp: prompt got"
                  :connection (connection-name (client-connection client)) :messages (length got))
        (values got (%string-or-nil (gethash "description" result)))))))

(defun prompt-input (prompt messages)
  "The input for RUN-TURN from MESSAGES, the messages GET-PROMPT gave for PROMPT: the content
parts of its user messages, in order. A prompt with assistant messages is a scripted exchange,
not one user turn, and signals PROMPT-HAS-ASSISTANT-MESSAGES."
  (when (find "assistant" messages :key #'llm:role :test #'equal)
    (error 'prompt-has-assistant-messages :prompt prompt))
  (loop for m in messages
        for content = (llm:content m)
        append (if (listp content) (copy-list content) (list (llm:text-part content)))))
