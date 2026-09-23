;;;; studio.lisp --- REPL introspection: making the live agent legible
;;;;
;;;; Praxeon's "studio" is the live image itself. These helpers render an agent,
;;;; its conversation, and a single turn's deliberate/act trace in a readable
;;;; form, so development and debugging happen by looking, not guessing. They
;;;; read only the provider-neutral vocabulary (messages, content parts, tool
;;;; specs), so they behave identically across every provider. A graphical view
;;;; can grow later; the REPL is the first studio.

(cl:in-package #:praxeon/studio)

(defun agent-summary (agent)
  "A structured (plist) summary of AGENT: :name, :provider (class), :model,
:context-budget, :history-budget, :history-length, :history-tokens, and :means (a
list of (:name :description) plists). This is the data behind DESCRIBE-AGENT and
the hook a future graphical/REST studio renders -- all provider-neutral.

IT USED TO REPORT ONE :BUDGET, taken from the context object, and that was the
false claim pre-publication issue 402 found: nothing was budgeted by it, and this is what someone reads
when they are already confused. There are two budgets over two kinds of data now
(ADR-0001), so there are two keys, each named for what it governs."
  (let ((provider (actor:agent-provider agent)))
    (list :name (actor:agent-name agent)
          :provider (and provider (class-name (class-of provider)))
          :model (and provider (llm:model-of provider))
          :context-budget (ctx:context-budget (actor:agent-context agent))
          :context-items (length (ctx:context-items (actor:agent-context agent)))
          :history-budget (actor:agent-history-budget agent)
          :history-length (length (actor:agent-history agent))
          :history-tokens (prompt:messages-tokens (actor:agent-history agent))
          :means (mapcar (lambda (m)
                           (list :name (llm:tool-spec-name m)
                                 :description (llm:tool-spec-description m)))
                         (actor:agent-tool-specs agent)))))

(defun describe-agent (agent &optional (stream *standard-output*))
  "Print a readable summary of AGENT (see AGENT-SUMMARY for the data form).
Returns AGENT."
  (let ((s (agent-summary agent)))
    (format stream "~&Agent ~S~%" (getf s :name))
    (format stream "  provider : ~A~@[ (~A)~]~%"
            (or (getf s :provider) "none") (getf s :model))
    (format stream "  context  : ~A-token budget for retrieved facts, ~A item(s) held~%"
            (getf s :context-budget) (getf s :context-items))
    (format stream "  history  : ~A message(s), ~A estimated token(s)~@[ against a ~A-token budget~]~%"
            (getf s :history-length) (getf s :history-tokens)
            (getf s :history-budget))
    (format stream "  means    : ~A~%" (length (getf s :means)))
    (dolist (m (getf s :means))
      (format stream "    - ~A : ~A~%" (getf m :name) (getf m :description))))
  agent)

(defun %args->string (input)
  "Render tool arguments (a hash-table, or NIL) as `k=v, k=v`."
  (cond ((null input) "")
        ((hash-table-p input)
         (with-output-to-string (s)
           (let ((first t))
             (maphash (lambda (k v)
                        (unless first (write-string ", " s))
                        (setf first nil)
                        (format s "~A=~A" k v))
                      input))))
        (t (princ-to-string input))))

(defun %render-part (part stream)
  (ecase (getf part :type)
    (:text (format stream "~A" (getf part :text)))
    (:tool-use (format stream "[call ~A=~A(~A)]"
                       (getf part :id) (getf part :name)
                       (%args->string (getf part :input))))
    (:tool-result (format stream "[result ~A: ~A]"
                          (getf part :tool-use-id) (getf part :content)))))

(defun render-message (message &optional (stream *standard-output*))
  "Render one neutral MESSAGE as `ROLE> ...` on STREAM."
  (let ((content (llm:content message)))
    (format stream "~&~A> " (string-upcase (llm:role message)))
    (if (stringp content)
        (format stream "~A~%" content)
        (progn
          (dolist (part content)
            (%render-part part stream)
            (write-char #\Space stream))
          (terpri stream))))
  message)

(defun show-transcript (agent &optional (stream *standard-output*))
  "Render AGENT's full conversation history as a readable transcript. Returns
AGENT."
  (dolist (m (actor:agent-history agent) agent)
    (render-message m stream)))

(defun trace-turn (agent input &optional (stream *standard-output*))
  "Run one turn on INPUT, then print the deliberate/act/answer steps it produced
\(read back from the newly recorded history). Returns the agent's final reply."
  (let ((start (length (actor:agent-history agent))))
    (let ((reply (actor:run-turn agent input)))
      (format stream "~&--- trace of turn ---~%")
      (dolist (m (nthcdr start (actor:agent-history agent)))
        (render-message m stream))
      (format stream "--- end trace ---~%")
      reply)))

;;; --------------------------------------------------------------------------
;;; Live progress reporting -- a ready-made CLI renderer for the event stream.
;;; --------------------------------------------------------------------------
(defun status-observer (&optional (stream *standard-output*))
  "Return an observer (a function of one progress event) for
PRAXEON/EVENT:WITH-OBSERVER that renders a turn's activity as concise CLI status
on STREAM: a transient \"thinking\" line while the model is called (erased when
the next event arrives, on an interactive stream), and a line per tool call and
result as they happen. It reads only the neutral event data, so a web client
would render the same events its own way."
  (let ((pending nil)
        (tty (interactive-stream-p stream)))
    (labels ((clear-pending ()
               (when pending
                 (if tty
                     (format stream "~C~C[K" #\Return #\Escape) ; CR + erase-to-EOL
                     (terpri stream))
                 (setf pending nil)))
             (line (fmt &rest args)
               (clear-pending)
               (apply #'format stream fmt args)
               (terpri stream)))
      (lambda (event)
        (case (evt:event-type event)
          (:deliberating
           (clear-pending)
           (write-string "  … thinking" stream)
           (setf pending t))
          (:tool-call
           (line "  → ~A(~A)"
                 (evt:event-get event :name)
                 (%args->string (evt:event-get event :arguments))))
          (:tool-result
           (line "  ← ~A" (evt:event-get event :content)))
          (:answer
           (clear-pending))            ; the client prints the answer itself
          (t (clear-pending)))
        (finish-output stream)))))
