;;;; derived.lisp --- when a value derived from a row's text has gone stale (ADR-0002).
;;;;
;;;; A row holds text and a value DERIVED from it -- an embedding today, a translation or a
;;;; summary tomorrow. The text changes; nothing about the derived value changes, and nothing
;;;; anywhere says it is now wrong. Retrieval then serves a well-formed vector for a paragraph
;;;; somebody rewrote last week, which is silent in every layer.
;;;;
;;;; THE FINGERPRINT COVERS EXACTLY THE INPUTS TO THE DERIVED VALUE. That sentence is the whole
;;;; convention (ADR-0002). An embedding over title and body means a fingerprint over title and
;;;; body -- not the row, not everything convenient. Wider reports staleness that is not there,
;;;; which is the version stamp's defect reached by another road; narrower misses real
;;;; staleness, which is what this exists to prevent.
;;;;
;;;; A STAMP IS A DIFFERENT QUESTION AND ALREADY HAS AN ANSWER. `mnemosyne/id:touch!' stamps a
;;;; row's `vid' and modified time, and that answers `did this row change'. This answers `did
;;;; the text this value was derived from change'. A row carrying a `structure' column -- layout
;;;; and ordering, everything that is not words -- makes the difference concrete: reorder one
;;;; block and every row below it bumps its version with no text changed. Nobody should unify
;;;; the two later.
;;;;
;;;; THE HASH IS THE CALLER'S. This file frames the inputs and compares the results; it does not
;;;; choose a digest and does not ask the database for one. A default fingerprint function would
;;;; be a compatibility promise nobody made -- two consumers that disagree about the hash
;;;; disagree about staleness, silently -- and a hash computed in SQL would be backend-dependent
;;;; (`sha256()' on Postgres, absent on SQLite), which is exactly what ADR-0001 says the
;;;; framework does not do.

(in-package #:mnemosyne/derived)

(define-condition no-fingerprint-hash (error)
  ()
  (:report (lambda (c s)
             (declare (ignore c))
             (format s "mnemosyne/derived: CONTENT-FINGERPRINT needs a :HASH function.~%~
There is deliberately no default: a fingerprint function is a compatibility promise, and two ~
consumers that disagree about the hash disagree about staleness without either noticing. Pass ~
your own -- ironclad's sha256 over the framed octets is the usual choice (ADR-0002).")))
  (:documentation
   "Signalled when CONTENT-FINGERPRINT is called without a hash function. Its own condition
rather than a program error, because the absence is a decision a reader needs explained."))

(defun %input-text (value)
  "VALUE as the text that goes into a fingerprint.

NIL IS THE EMPTY STRING, not the word \"NIL\": a column holding the letters N-I-L is content
and a null column is not, so printing NIL would make them fingerprint alike -- which is the
one confusion that matters here.

NULL AND EMPTY DO fingerprint alike, and that is correct rather than a limitation: both
contribute no text to the derived value, so a column going from NULL to the empty string
changes nothing the value was computed from and is not staleness. (An earlier version of this
docstring claimed the length prefix distinguished them. It does not -- both frame as `0:\' --
and the claim was wrong rather than the behaviour.)"
  (cond ((null value) "")
        ((stringp value) value)
        (t (princ-to-string value))))

(defun frame-inputs (values)
  "VALUES framed into one string, unambiguously.

LENGTH-PREFIXED, NOT JOINED ON A SEPARATOR. `(\"ab\" \"c\")' and `(\"a\" \"bc\")' are different
content and must not produce one fingerprint, and any separator -- a newline, a NUL, a private
sentinel -- can occur in prose. Each input contributes its length in characters, a colon, and
its text, so the framing is injective without reserving a character."
  (with-output-to-string (out)
    (dolist (v values)
      (let ((text (%input-text v)))
        (format out "~D:~A" (length text) text)))))

(defun content-fingerprint (values &key hash)
  "The fingerprint of VALUES -- the inputs to a derived value, in declaration order.

HASH is required and is the caller's: a function of one string returning the fingerprint
\(usually a hex string). See the commentary above for why there is no default.

ORDER MATTERS AND IS THE SCHEMA'S. Pass the values in the order the declaration names them --
`derived-inputs' returns that order for exactly this purpose -- so two consumers of one schema
compute one fingerprint."
  (unless hash (error 'no-fingerprint-hash))
  (funcall hash (frame-inputs values)))

(defun derived-stale-p (stored current &key stored-deriver current-deriver)
  "Is a derived value stale? STORED is the fingerprint in the row; CURRENT is the fingerprint of
the row's text now. STORED-DERIVER and CURRENT-DERIVER are the same question for what PRODUCED
the value -- a model id, a version.

STALENESS IS THE DISJUNCTION, and this function takes both pairs so that it cannot be checked
by halves. The two columns can disagree, and each disagreement alone is staleness:

  fingerprint differs, deriver matches -> the text was edited
  fingerprint matches, deriver differs -> the model or its dimension changed
  both differ                          -> both happened

A caller who compares only the fingerprint misses every row that needs re-deriving after a
model change, which is the bulk case the deriver column exists for; one who compares only the
deriver misses every edit. The derivers are compared only when supplied, so a consumer that does
not version its deriver is unaffected.

A NULL STORED FINGERPRINT IS STALE, which is the case that matters on the day the convention
arrives: every row that existed before it has no fingerprint, and treating `we have never
recorded one' as `up to date' would leave exactly those rows unre-derived forever. Comparison
is on strings, because a fingerprint is whatever the caller's hash returned and this file does
not interpret it."
  (flet ((differs (a b) (not (string= (%input-text a) (%input-text b)))))
    (or (null stored)
        (null current)
        (differs stored current)
        ;; Only when the caller supplied both: a consumer that does not record a deriver is
        ;; asking the fingerprint question alone, and answering a question it did not ask
        ;; would report every row stale forever.
        (and stored-deriver current-deriver (differs stored-deriver current-deriver)))))

;;; --- the columns the convention adds ----------------------------------------

(defun fingerprint-column (field-name)
  "The companion column recording the fingerprint of FIELD-NAME's inputs."
  (intern (format nil "~A_FINGERPRINT" (symbol-name field-name)) :keyword))

(defun deriver-column (field-name)
  "The companion column recording WHAT produced FIELD-NAME's value -- a model id, a version.

A SECOND COLUMN RATHER THAN PART OF THE FINGERPRINT, for an operational reason rather than a
conceptual one (ADR-0002): a model or dimension change has to drive a BULK re-derive, and

  (:select (:id) :from (\"chunks\") :where (:<> :embedding_deriver \"text-embedding-3-small\"))

is one predicate against a bind parameter, where a fingerprint that mixed the model in would
need every row read and rehashed to find the same set."
  (intern (format nil "~A_DERIVER" (symbol-name field-name)) :keyword))
