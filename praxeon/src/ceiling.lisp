;;;; ceiling.lisp --- what a caller is allowed to spend, and refusing before it is spent.
;;;;
;;;; Praxeon had NO protection surface: no rate limit, no quota, no cost ceiling, no
;;;; metering (pre-publication issue 172). That was fine while the only consumer was one agent run locally by
;;;; its author. It is not fine for an endpoint anyone can reach, billed to one API key,
;;;; and `praxeon/docs/comparison.md` says so publicly: praxeon "cannot be recommended for
;;;; anything internet-facing until this exists."
;;;;
;;;; TWO CEILINGS, NOT ONE. The issue asks for two things that look like one problem:
;;;;
;;;;   "one person with curl and a loop spends real money"  -- a RUNAWAY, bounded per
;;;;   session, stopped completely by a cap that needs no truth beyond what the app
;;;;   already signed.
;;;;
;;;;   "tier margin, quota by membership tier"              -- a BILLING QUOTA, monthly,
;;;;   needing a ledger the application already owns.
;;;;
;;;; Solving both with one mechanism forced a false trade: assert the budget and it can go
;;;; stale, or look it up and the agent needs a database credential. Separated, neither
;;;; cost applies. THIS FILE IS THE FIRST ONE. The monthly quota is the app's, enforced at
;;;; mint time where the ledger is.
;;;;
;;;; WHY THE AGENT CANNOT MINT. The grant is signed by the application with an Ed25519
;;;; private key and verified here with the PUBLIC key. A shared secret (HMAC, which this
;;;; tree already uses for Twilio webhooks) would have been less work and would have put a
;;;; minting capability on the agent host -- so compromising the agent would yield
;;;; unlimited-budget grants, against a ceiling whose whole job is to bound what a
;;;; compromised endpoint can spend.
;;;;
;;;; WHY THE AGENT NEEDS NO DATABASE. Metering is a WRITE path whichever way the check
;;;; goes. It stays credential-free because usage is returned IN-BAND with the reply and
;;;; the application writes its own ledger. Had the agent written to a store, the
;;;; credential cost would have been paid anyway and the claim would have bought nothing.
;;;;
;;;; ENFORCEMENT IS AN ENTER STAGE, which is the whole reason pre-publication issue 130 came first. A guard that
;;;; halts on the way in SKIPS the effect, so a refusal costs nothing. Enforcement inline
;;;; in the completion path could only have refused AFTER spending, or appended a refusal
;;;; to an answer it had already paid for.

(in-package #:praxeon/ceiling)

;;; --- the grant ------------------------------------------------------------

(defstruct (grant (:constructor %make-grant) (:copier nil))
  "What one caller is permitted, as asserted by the application that signed it.

PRINCIPAL and GROUP are the attribution pair -- a user may belong to several groups and
spend must be attributable to the pair, because tier quota is allocated by membership and
a group operator will eventually ask what its members consumed. CAPABILITIES is the tool
vocabulary this caller may reach. TOKEN-CAP and CALL-CAP bound one session. EXPIRES-AT and
AUDIENCE bound the grant itself."
  (principal "" :type string)
  (group "" :type string)
  (capabilities '() :type list)
  (token-cap 0 :type integer)
  (call-cap 0 :type integer)
  (expires-at 0 :type integer)
  (audience "" :type string))

(define-condition grant-invalid (cnd:praxeon-error)
  ((reason :initarg :reason :reader grant-invalid-reason))
  (:report (lambda (c s)
             (format s "praxeon/ceiling: grant rejected: ~A" (grant-invalid-reason c))))
  (:documentation "Signalled when a grant fails verification. Carries WHY, because a
caller debugging a rejected token needs to know whether it was the signature, the clock or
the audience -- and because an opaque rejection is the kind of thing people work around by
turning verification off."))

(define-condition budget-exhausted (cnd:praxeon-error)
  ((principal :initarg :principal :reader budget-exhausted-principal)
   (requested :initarg :requested :reader budget-exhausted-requested)
   (remaining :initarg :remaining :reader budget-exhausted-remaining))
  (:report (lambda (c s)
             (format s "praxeon/ceiling: budget exhausted for ~A: needed ~A, ~A remaining"
                     (budget-exhausted-principal c)
                     (budget-exhausted-requested c)
                     (budget-exhausted-remaining c))))
  (:documentation "Signalled when a caller asks for more than its grant allows. A HARD
refusal by design: silently switching to a cheaper model would be worse than refusing,
because unpredictable output quality is a compliance problem and not merely a UX one."))

;;; --- verification, behind a protocol --------------------------------------

(defgeneric verify-grant (verifier payload signature)
  (:documentation
   "Return a GRANT for PAYLOAD if SIGNATURE is valid under VERIFIER, or signal
GRANT-INVALID. A protocol, so an application already issuing JWTs or HMAC tokens can supply
a backend rather than adopting this one's format."))

(defstruct (ed25519-verifier (:constructor make-ed25519-verifier (public-key &key audience)))
  "Verifies grants signed with the application's Ed25519 private key.

Holds a PUBLIC key only: this component can check a grant and cannot issue one."
  public-key
  (audience "" :type string))

(defun %now () (get-universal-time))

(defun %parse-payload (payload)
  "PAYLOAD is the signed JSON. Returns a GRANT with no validity checking of its own."
  (let ((o (jzon:parse payload)))
    (flet ((s (k) (or (gethash k o) ""))
           (i (k) (let ((v (gethash k o))) (if (integerp v) v 0))))
      (%make-grant :principal (s "principal") :group (s "group")
                   :capabilities (coerce (or (gethash "capabilities" o) #()) 'list)
                   :token-cap (i "token_cap") :call-cap (i "call_cap")
                   :expires-at (i "expires_at") :audience (s "audience")))))

(defmethod verify-grant ((v ed25519-verifier) payload signature)
  "Signature first, then claims. Order matters: nothing in an unverified payload is worth
reading, including its expiry."
  (let ((bytes (sb-ext:string-to-octets payload :external-format :utf-8)))
    (unless (ignore-errors
             (ironclad:verify-signature (ed25519-verifier-public-key v) bytes signature))
      (error 'grant-invalid :reason "signature does not verify")))
  (let ((g (%parse-payload payload)))
    (when (<= (grant-expires-at g) (%now))
      (error 'grant-invalid :reason "grant has expired"))
    (let ((want (ed25519-verifier-audience v)))
      (when (and (plusp (length want)) (not (string= want (grant-audience g))))
        (error 'grant-invalid :reason (format nil "grant is for audience ~S, not ~S"
                                              (grant-audience g) want))))
    g))

;;; --- the session ledger ---------------------------------------------------

(defstruct (ledger (:constructor %make-ledger) (:copier nil))
  "What one session has spent so far, against the grant that permits it.

In-memory and per-session ON PURPOSE. This bounds a runaway; it is not the billing record.
The billing record is the application's, written from the usage this returns in-band."
  grant
  (tokens 0 :type integer)
  (calls 0 :type integer)
  (usage '() :type list)
  (lock (bt:make-lock "praxeon-ceiling") :read-only t))

(defun make-ledger (grant) (%make-ledger :grant grant))

(defun remaining-tokens (ledger)
  "Tokens left in this session's grant. READABLE BEFORE THE CALL, which is requirement 4:
a UI renders \"you have N left\" from this rather than discovering the ceiling by hitting it."
  (bt:with-lock-held ((ledger-lock ledger))
    (max 0 (- (grant-token-cap (ledger-grant ledger)) (ledger-tokens ledger)))))

(defun remaining-calls (ledger)
  "Calls left in this session's grant. The `curl` in a loop is bounded by this even when
each individual call is small."
  (bt:with-lock-held ((ledger-lock ledger))
    (max 0 (- (grant-call-cap (ledger-grant ledger)) (ledger-calls ledger)))))

(defun affordable-p (ledger estimated-tokens)
  "True when ESTIMATED-TOKENS fits and a call remains. Asked BEFORE the model call."
  (and (plusp (remaining-calls ledger))
       (<= estimated-tokens (remaining-tokens ledger))))

;;; --- what the guard charges (pre-publication issue 417) ----------------------------------------
;;;
;;; FOUR COUNTS, NOT TWO. A provider reports base input, output, tokens READ from a cached
;;; prefix, and tokens WRITTEN to one. pre-publication issue 401 made the last two visible on a COMPLETION and
;;; the ledger never received them, so a turn served from cache cost the guard nothing:
;;; measured on f725afd, a turn reporting input 10 / output 40 / cache-read 5000 charged 50,
;;; and ten such turns against a 1000-token cap left the guard still permitting more after
;;; the session had reported 50500. The drift grew with how well the workload used the cache
;;; and it ran in the direction that reads as headroom.
;;;
;;; THE DECISION, stated rather than left in the arithmetic: ALL FOUR COUNT AT PARITY by
;;; default. One token charged per token reported, whatever kind it was.
;;;
;;; Why parity, when the four are not priced alike -- a cache read is around a TENTH of base
;;; input and a cache write around 1.25x:
;;;
;;;   The cap is denominated in TOKENS. `token_cap' is a claim in a signed grant and the
;;;   thing this module bounds is a RUNAWAY, not a bill (see the LEDGER docstring: "this
;;;   bounds a runaway; it is not the billing record"). A token cap that silently means
;;;   "tokens, except the cheap ones, which count as a tenth" is a cap whose units depend on
;;;   a provider's price list.
;;;
;;;   A guard should err toward REFUSING. Parity over-counts a cache read against its price,
;;;   which stops a session early; price-weighting would let a cache-heavy workload run ten
;;;   times longer than its cap suggests. Today's behaviour is the extreme of that error and
;;;   is what pre-publication issue 417 is about.
;;;
;;;   Price weights are a PROVIDER FACT THAT CHANGES. Baked in as the default they rot
;;;   silently, and the failure is invisible: a stale weight shows up as a cap that is not
;;;   the cap anyone set.
;;;
;;; A host that wants cost-shaped accounting binds *TOKEN-WEIGHTS*. The vendor ratios are
;;; recorded in its docstring WITH THEIR DATE AND SOURCE, because a number copied out of a
;;; price list without either is a number nobody can re-check.

(defparameter *token-weights*
  '((:input . 1) (:output . 1) (:cache-read . 1) (:cache-write . 1))
  "How many chargeable tokens each reported token counts as. PARITY by default -- see the
commentary above for why, and note that changing these changes what a signed grant's
`token_cap' means, which is a decision about the contract and not a tuning knob.

FOR COST-SHAPED ACCOUNTING, a host may bind this to the provider's price ratios. Anthropic's,
read 2026-09-20 from the vendor's prompt-caching pricing as recorded in praxeon/llm's pre-publication issue 401
commentary (`a cache read is roughly a tenth', `a cache entry is written at 1.25x'):

  '((:input . 1) (:output . 1) (:cache-read . 1/10) (:cache-write . 5/4))

Those are PRICE ratios, not token counts, and they are a provider fact with a date on it.
They also differ per model and per vendor, so a host binding them owns keeping them true.
Output is listed at 1 in both tables and that is already a simplification: output is priced
several times input everywhere, and a ledger that bounded spend rather than tokens would
have to say so. It bounds tokens.")

(defun %weight (kind)
  (or (cdr (assoc kind *token-weights*)) 1))

(defun chargeable-tokens (&key input output cache-read cache-write)
  "The chargeable total for one completion's four counts, under *TOKEN-WEIGHTS*.

THE ONE PLACE THE ARITHMETIC LIVES, so that what the guard charges cannot disagree with what
the report explains. NIL means the provider reported nothing for that kind and contributes
nothing; it is not the same answer as 0, which is why the two are kept apart in the usage
line and collapsed only here, where a sum has to be a number."
  (round (+ (* (%weight :input) (or input 0))
            (* (%weight :output) (or output 0))
            (* (%weight :cache-read) (or cache-read 0))
            (* (%weight :cache-write) (or cache-write 0)))))

(defun record-usage (ledger &key (input 0) (output 0) cache-read cache-write
                                 (model "") (means ""))
  "Charge one completion's tokens to LEDGER and record the line. Returns the usage line.

ALL FOUR COUNTS ARE RECORDED SEPARATELY and none is folded into another. A report that added
a cache read into `input' could still bound a runaway and could not explain a bill, and the
distinction pre-publication issue 401 paid for -- NIL means the provider said nothing, 0 means it reported a miss
-- would be destroyed at exactly the boundary where someone starts trusting the numbers.

CACHE-READ and CACHE-WRITE DEFAULT TO NIL, not 0, for that reason: a caller that does not
know is recorded as not knowing. INPUT and OUTPUT keep their 0 defaults, which is the
existing contract and is what a caller who passes neither means.

What is CHARGED is CHARGEABLE-TOKENS under *TOKEN-WEIGHTS* -- parity by default; see the
commentary above.

Per model, and carrying MEANS when a caller knows it, because the question that decides
what a pricing tier includes is which capability is expensive -- a ceiling that only knows
how to say no leaves that unanswerable."
  (bt:with-lock-held ((ledger-lock ledger))
    (let ((line (list :principal (grant-principal (ledger-grant ledger))
                      :group (grant-group (ledger-grant ledger))
                      :model model :means means
                      :input input :output output
                      :cache-read cache-read :cache-write cache-write
                      :charged (chargeable-tokens :input input :output output
                                                  :cache-read cache-read
                                                  :cache-write cache-write)
                      :at (%now))))
      ;; :CHARGED is on the line as well as the four raw counts, because the weights are
      ;; rebindable: a line that recorded only the counts could not be reconciled against
      ;; the cap it was charged to if anything ever rebinds them.
      (incf (ledger-tokens ledger) (getf line :charged))
      (incf (ledger-calls ledger))
      (push line (ledger-usage ledger))
      line)))

(defun usage-report (ledger)
  "Every usage line for this session, oldest first -- what the caller returns IN-BAND for
the application to write into its own ledger. This is what keeps the agent free of a
database credential."
  (reverse (ledger-usage ledger)))

(defun grant-permits-p (grant capability)
  "True when GRANT carries CAPABILITY."
  (and (member capability (grant-capabilities grant) :test #'equal) t))

(defun grant-permit-fn (grant)
  "GRANT as a PERMIT predicate for PRAXEON/ACTOR:AGENT-TOOL-SPECS and ACT (#90).

The bridge, and the only place the two ideas meet: this module knows what a grant is and
how one is verified; praxeon/actor knows what a means is. Handing across a closure means
the tool catalogue never learns about tokens, signatures or principals, and a host that
authorises some other way can supply its own predicate.

Until this existed the claim above was only a claim. GRANT-PERMITS-P's docstring used to
say means were `assembled from this rather than filtered by prompt, so a capability a
caller lacks is absent from the tool table entirely' -- and nothing assembled anything:
AGENT-TOOL-SPECS advertised every registered means, and CAPABILITY-GUARD gated a whole
TURN rather than a means. A security property asserted in a docstring and implemented
nowhere is the shape AGENTS.md warns about: the code read correctly and the guard was
decorative."
  (lambda (capability) (grant-permits-p grant capability)))

;;; --- the stages -----------------------------------------------------------
;;;
;;; This is where the ceiling becomes enforcement rather than arithmetic, and it is why
;;; pre-publication issue 130 had to land first. The guard is an ENTER stage, so a refusal halts before the
;;; effect and the model call never happens. The meter is a LEAVE stage, so it sees a turn
;;; that actually completed.

(defun budget-guard (ledger &key (estimate 1000))
  "An enter stage that refuses when LEDGER cannot afford the turn.

ESTIMATE is what a turn is assumed to cost before it runs; a caller that can predict better
should pass its own. Refusing on an estimate is deliberate -- the alternative is to discover
the ceiling after paying, which is the behaviour this exists to remove.

SINCE pre-publication issue 417 THE ESTIMATE HAS TO INCLUDE THE CACHED PREFIX the turn intends to read, because
that prefix is now charged. The 1000 default was written when a cached read cost the ledger
nothing; for a workload of short turns against a large shared prefix it is wrong by the size
of the prefix, and wrong in the permitting direction -- which is the same defect pre-publication issue 417 fixed,
one step earlier in the turn. A caller with a marked prefix (PRAXEON/LLM, `:cache t') knows
its size and should pass it.

The refusal is HARD and legible: the turn is halted with a reason, so a caller can tell a
refusal from an answer without parsing text, and the panel can say so in the user's own
language while the rest of the page keeps working. It does NOT quietly downgrade to a
cheaper model -- unpredictable output quality is a compliance problem, not a UX one."
  (turn:guard-stage
   "budget"
   (lambda (tn)
     (cond
       ((not (plusp (remaining-calls ledger)))
        (turn:halt-with tn (format nil "call limit reached for this session (~A used)"
                                   (ledger-calls ledger))))
       ((not (affordable-p ledger estimate))
        (turn:halt-with tn (format nil "insufficient budget: ~A needed, ~A remaining"
                                   estimate (remaining-tokens ledger))))
       (t tn)))))

(defun capability-guard (ledger capability)
  "An enter stage that refuses a turn whose grant does not carry CAPABILITY."
  (turn:guard-stage
   "capability"
   (lambda (tn)
     (if (grant-permits-p (ledger-grant ledger) capability)
         tn
         (turn:halt-with tn (format nil "grant does not permit ~A" capability))))))

(defun meter (ledger &key (model "") (means "")
                          input-fn output-fn cache-read-fn cache-write-fn)
  "A leave stage that charges the turn's usage to LEDGER.

The four functions are read at leave time -- the CL shell knows what the provider reported,
and the turn context deliberately does not carry it, because token counts are a property of
the completion rather than of the conversation. Their obvious sources are
PRAXEON/LLM:COMPLETION-INPUT-TOKENS, -OUTPUT-TOKENS, -CACHE-READ-TOKENS and
-CACHE-WRITE-TOKENS; this module takes functions rather than a completion so that it stays
free of the provider vocabulary, which is the same seam GRANT-PERMIT-FN uses for capabilities.

A FUNCTION THAT IS NOT SUPPLIED CONTRIBUTES NOTHING, and the two cases are still different
in the record: a missing INPUT-FN records 0, because that is the existing contract, while a
missing CACHE-READ-FN records NIL -- we were not told rather than told zero. Anything that
omits the two cache readers is charged exactly what it was charged before this change, which
is the one compatibility promise here and also the reason pre-publication issue 417 was invisible: the defaults
read as complete."
  (turn:leave-stage
   "meter"
   (lambda (tn)
     (unless (turn:turn-halted tn)
       (record-usage ledger
                     :input (if input-fn (funcall input-fn) 0)
                     :output (if output-fn (funcall output-fn) 0)
                     :cache-read (and cache-read-fn (funcall cache-read-fn))
                     :cache-write (and cache-write-fn (funcall cache-write-fn))
                     :model model :means means))
     tn)))
