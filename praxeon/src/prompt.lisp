;;;; prompt.lisp --- what is SENT, as distinct from what is remembered (pre-publication issue 402)
;;;;
;;;; An agent's `history' slot is the RECORD of a conversation. It is not the
;;;; request. This module builds the request: it trims the history to a token
;;;; budget and places assembled context items where they belong, without
;;;; touching the record. Nothing here mutates an agent.
;;;;
;;;; THE DECISION THIS FILE IMPLEMENTS IS ADR-0001 (praxeon/docs/adr). Two
;;;; budgets, because there are two scarcities over two kinds of data:
;;;;
;;;;   praxeon/context  retrieved FACTS -- independent items, any subset in any
;;;;                    order is a valid prompt fragment, so they can be RANKED
;;;;                    by value density and the best ones kept (`ctx:assemble').
;;;;   praxeon/prompt   conversation HISTORY -- a sequence with invariants, so it
;;;;                    is TRIMMED: whole exchanges, oldest first, never through
;;;;                    the cacheable prefix.
;;;;
;;;; Three invariants make the trim safe, and each one is the reason a
;;;; value-ranked selection over history would not be:
;;;;
;;;; 1. A `tool_use' is never separated from its `tool_result'. Not by a check
;;;;    but BY CONSTRUCTION: the unit of trimming is an EXCHANGE (a user message
;;;;    and everything that answers it), so one half of a pair cannot be dropped
;;;;    while the other is kept. `llm::%part->json' serialises whatever list it
;;;;    is handed and validates nothing, so this invariant has no second line of
;;;;    defence -- an orphaned part becomes a malformed request.
;;;;
;;;; 2. The cacheable prefix (pre-publication issue 401) is PINNED. Every message up to and including
;;;;    the last one carrying a `:cache t' part survives every trim. A cached
;;;;    prefix is a saving only while its bytes do not change; trimming from the
;;;;    front would write a new cache entry at 1.25x every turn and read none.
;;;;
;;;; 3. The newest exchange is never dropped. If it does not fit even with
;;;;    everything else gone, it is sent anyway and `:context-overflow' says so.
;;;;    Dropping the user's actual question to respect an ESTIMATE would be
;;;;    obeying our own arithmetic in preference to the request.
;;;;
;;;; On the word ESTIMATE, which is load-bearing: `estimate-tokens' is a
;;;; character count divided by a constant. It is a CLAIM about what the provider
;;;; will count, and the provider's reported input tokens is the MEASUREMENT.
;;;; Both travel on the `:usage' event whenever the provider reported one, so the
;;;; drift between them is visible; a budget enforced against an estimate nobody
;;;; ever compares is how a bound silently stops bounding.

(cl:in-package #:praxeon/prompt)

;;; --------------------------------------------------------------------------
;;; Estimating
;;; --------------------------------------------------------------------------

(defparameter *chars-per-token* 4
  "Characters per token, the divisor in ESTIMATE-TOKENS. Four is the usual
English-prose approximation; code and non-Latin scripts run denser, so an
estimate can be LOW -- which is why the budget default leaves headroom and why
the provider's own count travels beside ours on the :usage event.")

(defparameter *message-overhead-tokens* 4
  "Tokens charged per message for its structure (role, block framing) over and
above its text. Part of the estimate, not a measurement.")

(defun estimate-tokens (string)
  "An ESTIMATE of STRING's token cost: characters over *CHARS-PER-TOKEN*,
rounded up. Named `estimate' rather than `count' because nothing here tokenizes
anything -- see the commentary at the top of this file."
  (ceiling (length string) *chars-per-token*))

(defun %data-tokens (value)
  "Estimate the token cost of a tool argument VALUE -- a string, a
jzon-style hash-table, a list or vector of the same, or anything else (via its
printed representation). Walks the structure rather than printing a
hash-table, because `#<HASH-TABLE ...>' is a constant-size lie about a payload
that can be arbitrarily large."
  (typecase value
    (null 0)
    (string (estimate-tokens value))
    (hash-table
     (let ((n 0))
       (maphash (lambda (k v)
                  ;; +2 for the key/value punctuation the JSON encoding adds.
                  (incf n (+ (%data-tokens k) (%data-tokens v) 2)))
                value)
       n))
    (cons (reduce #'+ value :key #'%data-tokens :initial-value 0))
    (vector (reduce #'+ value :key #'%data-tokens :initial-value 0))
    (t (estimate-tokens (princ-to-string value)))))

(defun part-tokens (part)
  "Estimated token cost of one content PART (see PRAXEON/LLM)."
  (ecase (getf part :type)
    (:text (estimate-tokens (or (getf part :text) "")))
    (:tool-use (+ (estimate-tokens (or (getf part :name) ""))
                  (%data-tokens (getf part :input))))
    (:tool-result (%data-tokens (getf part :content)))))

(defun message-tokens (message)
  "Estimated token cost of MESSAGE, including *MESSAGE-OVERHEAD-TOKENS*."
  (let ((content (llm:content message)))
    (+ *message-overhead-tokens*
       (if (stringp content)
           (estimate-tokens content)
           (reduce #'+ content :key #'part-tokens :initial-value 0)))))

(defun messages-tokens (messages)
  "Estimated token cost of MESSAGES."
  (reduce #'+ messages :key #'message-tokens :initial-value 0))

;;; --------------------------------------------------------------------------
;;; Exchanges -- the unit of trimming
;;; --------------------------------------------------------------------------

(defun %parts (message)
  "MESSAGE's content as a list of parts, or NIL when it is a plain string."
  (let ((content (llm:content message)))
    (and (listp content) content)))

(defun tool-result-message-p (message)
  "True when MESSAGE carries any :tool-result part.

Such a message has role \"user\" but is not a new user TURN -- it is the answer
to the assistant's tool call, and belongs to the exchange already in progress.
Treating it as the start of a new exchange is exactly how a `tool_use' gets
separated from its `tool_result'."
  (and (some (lambda (p) (eq (getf p :type) :tool-result)) (%parts message)) t))

(defun cache-boundary-message-p (message)
  "True when MESSAGE carries a part marking the end of the cacheable prefix (pre-publication issue 401)."
  (and (some #'llm:cache-boundary-p (%parts message)) t))

(defun %opens-exchange-p (message)
  "True when MESSAGE begins a new exchange: a user message that is not a
tool-result message."
  (and (string-equal "user" (llm:role message))
       (not (tool-result-message-p message))))

(defun exchanges (messages)
  "Group MESSAGES into a list of EXCHANGES, each a list of messages, in order.

An exchange is the indivisible unit of trimming: a user message and everything
that answers it -- the assistant's reply, its tool calls, the tool results fed
back, further assistant turns -- up to the next genuine user message. Grouping
first is what makes tool pairing a structural property of the trim rather than a
rule someone has to remember at each call site."
  (let ((groups '())
        (current '()))
    (dolist (m messages)
      (when (and current (%opens-exchange-p m))
        (push (nreverse current) groups)
        (setf current '()))
      (push m current))
    (when current
      (push (nreverse current) groups))
    (nreverse groups)))

(defun pinned-exchange-count (groups)
  "How many leading exchanges of GROUPS are pinned by the cacheable prefix (pre-publication issue 401).

The prefix ends at the LAST `:cache t' part, so every exchange up to and
including the one containing it is pinned -- rounded out to the exchange
boundary, because a half-pinned exchange is the pairing hazard again. 0 when
nothing is marked, which is the case for an agent that has not asked for
caching."
  (let ((n 0))
    (loop for g in groups
          for i from 1
          when (some #'cache-boundary-message-p g)
            do (setf n i))
    n))

;;; --------------------------------------------------------------------------
;;; Trimming
;;; --------------------------------------------------------------------------

(defun %group-tokens (group)
  (reduce #'+ group :key #'message-tokens :initial-value 0))

(defun trim-history (messages budget)
  "The suffix of MESSAGES that fits an estimated token BUDGET, with the pinned
prefix kept. Returns a fresh list; MESSAGES is untouched.

BUDGET NIL means send everything -- for a caller that bounds its own context and
does not want ours. Otherwise: keep the pinned exchanges (pre-publication issue 401), then the newest
exchanges that fit, stopping at the first that does not so what is sent is a
contiguous tail rather than a conversation with a hole in it. The newest exchange
is kept whatever it costs.

Emits :context-trimmed when anything was dropped, and :context-overflow when the
kept minimum exceeds BUDGET. Both carry the estimate and the budget, because a
trim nobody can see is indistinguishable from a trim that never fired."
  (if (or (null budget) (null messages))
      messages
      (let* ((groups (exchanges messages))
             (pinned-n (pinned-exchange-count groups))
             (pinned (subseq groups 0 pinned-n))
             (tail (subseq groups pinned-n))
             (spent (reduce #'+ pinned :key #'%group-tokens :initial-value 0))
             (kept '())
             (newest t))
        (dolist (g (reverse tail))
          (let ((cost (%group-tokens g)))
            (cond ((or newest (<= (+ spent cost) budget))
                   (push g kept)
                   (incf spent cost)
                   (setf newest nil))
                  (t (return)))))
        (let* ((chosen (append pinned kept))
               (dropped (- (length groups) (length chosen)))
               (result (loop for g in chosen append g)))
          (when (plusp dropped)
            (evt:emit :context-trimmed
                      :dropped-exchanges dropped
                      :kept-exchanges (length chosen)
                      :pinned-exchanges pinned-n
                      :estimated-tokens spent
                      :budget budget))
          (when (> spent budget)
            ;; The pinned prefix plus the newest exchange does not fit. Say so and send
            ;; it: refusing here would turn our own estimate into a limit the provider
            ;; never imposed, and truncating the live question is worse than a 400 that
            ;; names the real ceiling.
            (evt:emit :context-overflow
                      :estimated-tokens spent
                      :budget budget
                      :kept-exchanges (length chosen)))
          result))))

;;; --------------------------------------------------------------------------
;;; Placing retrieved facts
;;; --------------------------------------------------------------------------

(defparameter *context-open* "<context>"
  "Opening delimiter of the retrieved-context block. A tag rather than prose so a
model can tell a retrieved fact from something the user said.")

(defparameter *context-close* "</context>"
  "Closing delimiter of the retrieved-context block.")

(defun render-items (items)
  "Render assembled PRAXEON/CONTEXT items as one text block, or NIL for none.

Deliberately minimal -- role and content, in the order `ctx:assemble' returned.
What a retrieved fact should actually carry (which document, which version, which
clause, which language) is #138's question, and this is the seam that answers it
once #138 lands. An item's `content' is a bare string today, so a bare string is
what this can render."
  (when items
    (with-output-to-string (s)
      (write-string *context-open* s)
      (dolist (i items)
        (format s "~&[~(~A~)] ~A" (ctx:ctx-item-role i) (ctx:ctx-item-content i)))
      (format s "~&~A" *context-close*))))

(defun attach-context (messages text)
  "MESSAGES with TEXT attached as a trailing text part of the last user message.

AFTER the cacheable prefix, always, and that is the point: retrieved facts change
every turn, so placing them in the cached region would invalidate the cache on
every request -- the same mistake as trimming through the prefix, arriving from
the other side. The last message is the newest, so appending there is after
everything any breakpoint could have marked.

When MESSAGES is empty, or its last message is not a user message (which the turn
loop never produces -- it deliberates only after appending a user message), TEXT
becomes its own trailing user message rather than being attached to an
assistant's words."
  (let ((last (car (last messages))))
    (cond ((null text) messages)
          ((or (null last) (not (string-equal "user" (llm:role last))))
           (append messages (list (llm:msg "user" (list (llm:text-part text))))))
          (t
           (let* ((content (llm:content last))
                  (parts (if (stringp content)
                             (list (llm:text-part content))
                             (copy-list content))))
             (append (butlast messages)
                     (list (llm:msg (llm:role last)
                                    (append parts (list (llm:text-part text)))))))))))
