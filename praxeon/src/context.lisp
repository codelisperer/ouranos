;;;; context.lisp --- budgeted, bitemporal context assembly
;;;;
;;;; In praxeological terms the scarce resource an agent economizes is not gold
;;;; but the CONTEXT WINDOW: a fixed token budget that must be allocated among
;;;; competing items (system prompt, history, retrieved facts, tool results).
;;;;
;;;; Each item carries two timestamps -- VALID-TIME (when the fact was true in
;;;; the world) and TX-TIME (when the system learned it). That bitemporal stamp
;;;; is the seed of *Kairos*, the dedicated bitemporal KNOWLEDGE-GRAPH store built
;;;; on the DB abstractions of *Mnemosyne* (the general bitemporal data layer --
;;;; XTDB 2 / Postgres wire). Here it is a plain in-memory list; it graduates onto
;;;; Kairos. This file is Praxeon's *praxeological* layer: it LEVERAGES Kairos for
;;;; recall and adds the context-budget economics (value-density assembly under the
;;;; scarce context window). The stack: Mnemosyne (DB) -> Kairos (bitemporal graph
;;;; on it) -> Praxeon (recall + budget economics on Kairos). (Aion = time,
;;;; Kairos = the opportune moment, Mnemosyne = memory.)

(cl:in-package #:praxeon/context)

(defun now ()
  "Current universal time; stand-in for a real transaction clock."
  (get-universal-time))

(defstruct (ctx-item (:constructor make-ctx-item))
  "A single unit of context competing for space in the window."
  (content "" :type string)
  (tokens 0 :type fixnum)          ; estimated token cost
  (role :note :type keyword)       ; :system :user :assistant :tool :note
  (value 0 :type real)             ; imputed importance (see praxeology Valued)
  (valid-time (now) :type integer) ; when true in the world
  (tx-time (now) :type integer)    ; when the system learned it
  ;; WHERE THIS ITEM CAME FROM, so a persona can say it (#150). Untyped on purpose: this
  ;; file loads before `praxeon/memory' and must not know what an observation is. Context
  ;; CARRIES the citation; it does not interpret it.
  ;;
  ;; NIL MEANS `NOT FROM A CITABLE PRODUCER' AND NOTHING ELSE. It cannot also mean "from
  ;; memory, source unknown", because #150 made provenance mandatory on the write path and
  ;; `praxeon/memory:observation->ctx-item' is the only route from an observation to an
  ;; item -- so a memory item without a citation cannot be built. That is deliberate: a
  ;; slot where NIL means two things is the absent-versus-NULL defect (pre-publication issue 489, pre-publication issue 444, #150)
  ;; rebuilt in a struct.
  (source nil))

(defstruct (context (:constructor make-context))
  "A budgeted collection of context items."
  (budget 8000 :type fixnum)
  (items '() :type list))

(defun add-item (context item)
  "Add ITEM to CONTEXT (most-recent-first). Returns CONTEXT."
  (push item (context-items context))
  context)

(defun context-tokens (items)
  "Total estimated token cost of ITEMS."
  (reduce #'+ items :key #'ctx-item-tokens :initial-value 0))

(defun assemble (context)
  "Select the highest-value items that fit within CONTEXT's budget.

WHAT THIS IS FOR, because the answer is architectural and was undocumented until
pre-publication issue 402 asked (ADR-0001): RETRIEVED FACTS. The ranking has a precondition -- items
must be INDEPENDENT, so that any subset of them, in any order, is a valid prompt
fragment. A retrieved fact satisfies that. A conversation turn does not: an
assistant `tool_use' must stay with its `tool_result', order carries meaning, and
the cacheable prefix (pre-publication issue 401) must not move. So conversation history is NOT assembled
here; it is trimmed by `praxeon/prompt:trim-history', which drops whole exchanges
from the oldest end and pins the prefix. Two budgets, two kinds of data.

Greedy by value-density (value per token), a defensible first cut; a later
version can pose this as the knapsack it really is, or fold in recency/validity
decay from the bitemporal stamps. Returns the chosen items, oldest-first, ready
to render into a prompt.

STABLE-SORT, not SORT, in both passes. `valid-time' comes from a one-second clock,
so ties are common; CL does not require SORT to be stable, which made the order of
same-second items arbitrary and the outcome intermittent."
  (let* ((budget (context-budget context))
         (ranked (stable-sort (copy-list (context-items context))
                              #'>
                              :key (lambda (i)
                                     (/ (ctx-item-value i)
                                        (max 1 (ctx-item-tokens i))))))
         (chosen '())
         (spent 0))
    (dolist (i ranked)
      (when (<= (+ spent (ctx-item-tokens i)) budget)
        (push i chosen)
        (incf spent (ctx-item-tokens i))))
    ;; chosen is currently value-desc; return in chronological order
    (stable-sort chosen #'< :key #'ctx-item-valid-time)))
