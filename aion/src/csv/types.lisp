;;;; types.lisp --- the typed core of aion/csv, in Coalton.
;;;;
;;;; CSV's untyped vocabulary is CHARACTERS, and the parser's own state is four bare
;;;; keywords in an ECASE (aion/src/csv/parse.lisp). Both are where silent bugs live: a
;;;; fifth state added to the ECASE without a clause falls through to an error at the worst
;;;; possible moment, and a `cond` chain that forgets one character class simply does the
;;;; wrong thing quietly. This layer makes the machine a type: four states, eight input
;;;; classes, and a transition the compiler checks is total (docs/coalton-story.md;
;;;; aion/uv/types.lisp is the worked reference).
;;;;
;;;; WHY THIS IS A SEPARATE SYSTEM, and not simply added to aion/csv:
;;;;
;;;; aion/csv is dependency-free ON PURPOSE -- `:depends-on ()`, so the portable backend
;;;; loads on bare SBCL/CCL/ECL/ABCL with no toolchain and no Coalton compile, and
;;;; csv-design.md L4 promises a CL face with "no Coalton required." Making the shipping
;;;; parser depend on Coalton would take that away, and on the three non-SBCL
;;;; implementations it would not load at all. So the typed core is OPT-IN: aion/csv does
;;;; not depend on this, and never will.
;;;;
;;;; WHAT KEEPS IT FROM BEING DECORATIVE. A type nothing executes is a comment with
;;;; syntax highlighting. The answer is not to force the hot loop through it -- that is the
;;;; open measurement question of coalton-story.md §4, and §8 says any number measured in
;;;; development mode says nothing about release. The answer is that this file is a
;;;; REFERENCE IMPLEMENTATION: PARSE below is a complete RFC-4180 parser built from the
;;;; typed transition, and the conformance test drives the same corpus through it and
;;;; through the shipping CL parser and asserts they agree, character for character. Two
;;;; independent implementations that must produce identical output is a real check; if
;;;; someone edits the ECASE and breaks a rule, this catches it.
;;;;
;;;; That also fits what aion/csv already is. csv-design.md calls the portable backend
;;;; "the oracle the fast backends are tested against" -- this gives the oracle itself a
;;;; typed specification.
;;;;
;;;; Pure, as always: no streams, no IO. PARSE takes a String and returns rows.

(cl:in-package #:aion/csv/types)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- What the machine is looking at ---------------------------------------
  ;;;
  ;;; The parser never branches on a character directly -- it branches on what the
  ;;; character MEANS under the dialect, which is a different and much smaller thing.
  ;;; Naming those meanings is what makes the transition table finite and checkable.

  (define-type CharClass
    "What a character means to the parser, under some dialect."
    ClDelimiter
    ClQuote
    ClEscape
    ClComment
    ClNewline
    ClReturn
    ClOther
    ClEof)

  (declare char-class->string (CharClass -> String))
  (define (char-class->string c)
    (match c
      ((ClDelimiter) "delimiter")
      ((ClQuote) "quote")
      ((ClEscape) "escape")
      ((ClComment) "comment")
      ((ClNewline) "newline")
      ((ClReturn) "return")
      ((ClOther) "other")
      ((ClEof) "eof")))

  ;;; --- Where the machine is -------------------------------------------------

  (define-type ParseState
    "The four states of the CSV reader. These are the keywords aion/csv's ECASE uses,
made a type so a fifth cannot be added without every transition being revisited."
    StStart      ; between fields: the start of a field, and possibly of a record
    StUnquoted   ; inside a bare field
    StQuoted     ; inside a quoted field
    StQuoteEnd)  ; just consumed a quote while inside a quoted field

  (declare parse-state->string (ParseState -> String))
  (define (parse-state->string s)
    (match s
      ((StStart) "start")
      ((StUnquoted) "unquoted")
      ((StQuoted) "quoted")
      ((StQuoteEnd) "quote-end")))

  ;;; --- What the machine does ------------------------------------------------
  ;;;
  ;;; Separating the ACTION from the next state is what makes the table checkable. The
  ;;; CL parser interleaves them -- (emit-field) here, (add c) there, a return-from
  ;;; somewhere else -- so no reader can see the whole matrix at once, and nothing
  ;;; verifies that every cell is filled.

  (define-type Action
    "What the reader does on a transition, besides changing state."
    AcNothing         ; consume the character, change state only
    AcAdd             ; append this character to the field
    AcAddQuote        ; append a literal quote (the doubled-quote case)
    AcTakeEscaped     ; consume the NEXT character literally
    AcEmitField       ; end the current field, stay in this record
    AcFinishRow       ; end the field AND the record
    AcSkipLine        ; a comment: discard through end of line
    AcEndInput        ; end of input with nothing pending -- no record
    AcFail)           ; malformed input

  (declare action->string (Action -> String))
  (define (action->string a)
    (match a
      ((AcNothing) "nothing")
      ((AcAdd) "add")
      ((AcAddQuote) "add-quote")
      ((AcTakeEscaped) "take-escaped")
      ((AcEmitField) "emit-field")
      ((AcFinishRow) "finish-row")
      ((AcSkipLine) "skip-line")
      ((AcEndInput) "end-input")
      ((AcFail) "fail")))

  ;; NB the function below is TRANSITION, not `step`: Coalton is case-insensitive, so a
  ;; function named `step` would be this very constructor and every (Step ...) call would
  ;; resolve to it -- "Function call has 2 positional arguments but inferred type ... takes
  ;; 4" (coalton-patterns.md §4).
  (define-type Step
    "A transition's result: what to do, and where to go next."
    (Step Action ParseState))

  (declare step-action (Step -> Action))
  (define (step-action s) (match s ((Step a _) a)))

  (declare step-next (Step -> ParseState))
  (define (step-next s) (match s ((Step _ n) n)))

  ;;; --- The transition -------------------------------------------------------

  (declare transition (ParseState * CharClass * Boolean * Boolean -> Step))
  (define (transition state class seen? skip-blank?)
    "The whole state machine, in one place.

SEEN? is whether anything has been consumed in the current record; it distinguishes an
end-of-input that must still emit a final row from one that must report exhaustion, and a
blank line that may be skipped from one that is an empty record. SKIP-BLANK? is the
dialect's policy for the latter.

Every (state, class) pair is answered. That is the property the ECASE in parse.lisp cannot
state and the compiler here enforces: add a fifth ParseState or a ninth CharClass and this
function stops compiling until the new cases are decided, rather than falling through at
runtime on the one input nobody tried."
    (match state

      ;; Start of a field -- and, when nothing has been seen, of a record.
      ((StStart)
       (match class
         ((ClEof) (if seen? (Step AcFinishRow StStart) (Step AcEndInput StStart)))
         ((ClComment) (if seen? (Step AcAdd StUnquoted) (Step AcSkipLine StStart)))
         ((ClQuote) (Step AcNothing StQuoted))
         ((ClDelimiter) (Step AcEmitField StStart))
         ((ClNewline) (if (and skip-blank? (not seen?))
                          (Step AcNothing StStart)
                          (Step AcFinishRow StStart)))
         ((ClReturn) (if (and skip-blank? (not seen?))
                         (Step AcNothing StStart)
                         (Step AcFinishRow StStart)))
         ((ClEscape) (Step AcTakeEscaped StUnquoted))
         ((ClOther) (Step AcAdd StUnquoted))))

      ;; Inside a bare field.
      ((StUnquoted)
       (match class
         ((ClEof) (Step AcFinishRow StStart))
         ((ClEscape) (Step AcTakeEscaped StUnquoted))
         ((ClDelimiter) (Step AcEmitField StStart))
         ((ClNewline) (Step AcFinishRow StStart))
         ((ClReturn) (Step AcFinishRow StStart))
         ;; A quote or a comment character mid-field is just text -- RFC 4180 only gives
         ;; a quote meaning at the START of a field.
         ((ClQuote) (Step AcAdd StUnquoted))
         ((ClComment) (Step AcAdd StUnquoted))
         ((ClOther) (Step AcAdd StUnquoted))))

      ;; Inside a quoted field: almost everything is literal, including newlines.
      ((StQuoted)
       (match class
         ;; The one genuinely malformed input: input ended mid-quote.
         ((ClEof) (Step AcFail StQuoted))
         ((ClEscape) (Step AcTakeEscaped StQuoted))
         ((ClQuote) (Step AcNothing StQuoteEnd))
         ((ClNewline) (Step AcAdd StQuoted))
         ((ClReturn) (Step AcAdd StQuoted))
         ((ClDelimiter) (Step AcAdd StQuoted))
         ((ClComment) (Step AcAdd StQuoted))
         ((ClOther) (Step AcAdd StQuoted))))

      ;; Just consumed a quote inside a quoted field: closing, or a doubled literal?
      ((StQuoteEnd)
       (match class
         ((ClEof) (Step AcFinishRow StStart))
         ((ClQuote) (Step AcAddQuote StQuoted))
         ((ClDelimiter) (Step AcEmitField StStart))
         ((ClNewline) (Step AcFinishRow StStart))
         ((ClReturn) (Step AcFinishRow StStart))
         ;; Lenient, matching the shipping parser: text after a closing quote continues
         ;; the field unquoted rather than being an error.
         ((ClEscape) (Step AcTakeEscaped StUnquoted))
         ((ClComment) (Step AcAdd StUnquoted))
         ((ClOther) (Step AcAdd StUnquoted))))))

  ;;; --- Dialect --------------------------------------------------------------

  (define-type Dialect
    "The read-relevant half of a CSV dialect: delimiter, quote, escape, comment, and the
blank-line policy. A character that is disabled is None rather than a sentinel."
    (Dialect Char (Optional Char) (Optional Char) (Optional Char) Boolean))

  (declare dialect-delimiter (Dialect -> Char))
  (define (dialect-delimiter d) (match d ((Dialect x _ _ _ _) x)))

  (declare dialect-quote (Dialect -> (Optional Char)))
  (define (dialect-quote d) (match d ((Dialect _ x _ _ _) x)))

  (declare dialect-escape (Dialect -> (Optional Char)))
  (define (dialect-escape d) (match d ((Dialect _ _ x _ _) x)))

  (declare dialect-comment (Dialect -> (Optional Char)))
  (define (dialect-comment d) (match d ((Dialect _ _ _ x _) x)))

  (declare dialect-skip-blank? (Dialect -> Boolean))
  (define (dialect-skip-blank? d) (match d ((Dialect _ _ _ _ x) x)))

  (declare rfc4180 Dialect)
  (define rfc4180 (Dialect #\, (Some #\") None None False))

  (declare tsv Dialect)
  (define tsv (Dialect #\tab (Some #\") None None False))

  (declare distinct-or-absent? (Char * (Optional Char) -> Boolean))
  (define (distinct-or-absent? c o)
    (match o ((None) True) ((Some x) (not (== c x)))))

  (declare dialect-ok? (Dialect -> Boolean))
  (define (dialect-ok? d)
    "True when a dialect's special characters are all distinct.

A delimiter equal to its quote character is not a dialect, it is an ambiguity: the same
byte would both end a field and begin a quoted one, and the parser's behaviour would
depend on clause order. The CL DEFSTRUCT cannot express this -- every slot is
independently typed and nothing relates them -- so today it is constructible and simply
misbehaves."
    (let ((delim (dialect-delimiter d))
          (q (dialect-quote d))
          (esc (dialect-escape d))
          (cmt (dialect-comment d)))
      (and (distinct-or-absent? delim q)
           (and (distinct-or-absent? delim esc)
                (and (distinct-or-absent? delim cmt)
                     (match (Tuple q esc)
                       ((Tuple (Some a) (Some b)) (not (== a b)))
                       (_ True)))))))

  (declare classify (Dialect * Char -> CharClass))
  (define (classify d c)
    "Which class a character falls into under DIALECT.

Order matters and is the dialect's, not the alphabet's: the delimiter is checked first, so
a dialect whose comment character is also its delimiter still parses fields (rather than
silently eating lines). DIALECT-OK? rejects that dialect up front anyway; this keeps the
function total if one is built regardless."
    (cond
      ((== c (dialect-delimiter d)) ClDelimiter)
      ((match (dialect-quote d) ((Some q) (== c q)) ((None) False)) ClQuote)
      ((match (dialect-escape d) ((Some e) (== c e)) ((None) False)) ClEscape)
      ((match (dialect-comment d) ((Some k) (== c k)) ((None) False)) ClComment)
      ((== c #\newline) ClNewline)
      ((== c #\return) ClReturn)
      (True ClOther)))

  ;;; --- The reference parser -------------------------------------------------
  ;;;
  ;;; Built ONLY from `transition`, so it inherits its totality. This is what makes the
  ;;; transition load-bearing: the conformance test runs a corpus through this and
  ;;; through aion/csv's shipping parser and requires identical output.

  (define-type Acc
    "Parser accumulator: finished rows (reversed), the current row's fields (reversed),
the current field's characters (reversed), the state, and whether the record has begun."
    (Acc (List (List String)) (List String) (List Char) ParseState Boolean))

  (declare emit-field-into (Acc -> Acc))
  (define (emit-field-into a)
    (match a
      ((Acc rows fields chars st seen?)
       (Acc rows (Cons (into (lst:reverse chars)) fields) Nil st seen?))))

  (declare finish-row-into (Acc -> Acc))
  (define (finish-row-into a)
    (match (emit-field-into a)
      ((Acc rows fields _ _ _)
       (Acc (Cons (lst:reverse fields) rows) Nil Nil StStart False))))

  (declare apply-step (Acc * Action * ParseState * Char -> Acc))
  (define (apply-step a action next c)
    (match a
      ((Acc rows fields chars _ seen?)
       (let ((seen2 (match action ((AcEndInput) seen?) ((AcSkipLine) seen?) (_ True))))
         (match action
           ((AcNothing) (Acc rows fields chars next seen2))
           ((AcAdd) (Acc rows fields (Cons c chars) next seen2))
           ((AcAddQuote) (Acc rows fields (Cons c chars) next seen2))
           ((AcTakeEscaped) (Acc rows fields chars next seen2))
           ((AcEmitField) (match (emit-field-into (Acc rows fields chars next seen2))
                            ((Acc r f ch _ s) (Acc r f ch next s))))
           ((AcFinishRow) (finish-row-into (Acc rows fields chars next seen2)))
           ((AcSkipLine) (Acc rows fields chars next seen2))
           ((AcEndInput) (Acc rows fields chars next seen2))
           ((AcFail) (Acc rows fields chars next seen2)))))))

  (declare parse-chars (Dialect * (List Char) * Acc * Boolean -> (Optional (List (List String)))))
  (define (parse-chars d cs a escaped?)
    "Fold the transition over the input. None means malformed (an unterminated quote)."
    (match cs
      ;; End of input: one final transition with ClEof decides whether a row is pending.
      ((Nil)
       (match a
         ((Acc rows fields chars st seen?)
          (let ((s (transition st ClEof seen? (dialect-skip-blank? d))))
            (match (step-action s)
              ((AcFail) None)
              ((AcEndInput) (Some (lst:reverse rows)))
              ((AcFinishRow)
               (match (finish-row-into (Acc rows fields chars st seen?))
                 ((Acc r _ _ _ _) (Some (lst:reverse r)))))
              (_ (Some (lst:reverse rows))))))))
      ((Cons c rest)
       (if escaped?
           ;; The previous transition asked for the next character literally.
           (match a
             ;; seen? is rebuilt as True below rather than read, so it is bound-unused --
             ;; and an unused variable is a full WARNING in Coalton, which ASDF escalates
             ;; to a COMPILE-FILE-ERROR. Prefixing with _ is the documented way to say
             ;; "deliberately ignored".
             ((Acc rows fields chars st _seen?)
              (parse-chars d rest (Acc rows fields (Cons c chars) st True) False)))
           (match a
             ((Acc _ _ _ st seen?)
              (let ((s (transition st (classify d c) seen? (dialect-skip-blank? d))))
                (match (step-action s)
                  ((AcFail) None)
                  ((AcSkipLine) (parse-chars d (drop-through-newline rest) a False))
                  ((AcTakeEscaped)
                   (parse-chars d rest (apply-step a AcTakeEscaped (step-next s) c) True))
                  (_ (parse-chars d
                                  (if (== c #\return) (drop-lf rest) rest)
                                  (apply-step a (step-action s) (step-next s) c)
                                  False))))))))))

  (declare drop-lf ((List Char) -> (List Char)))
  (define (drop-lf cs)
    "Consume a newline directly after a carriage return, so CRLF is ONE terminator.

Without this a \r\n file yields a spurious empty record between every pair of real ones:
the \r finishes the row, and the \n then arrives at the start of a fresh record and
finishes that too. The shipping parser handles it with MAYBE-LF; this is the same rule."
    (match cs
      ((Cons c rest) (if (== c #\newline) rest cs))
      ((Nil) Nil)))

  (declare drop-through-newline ((List Char) -> (List Char)))
  (define (drop-through-newline cs)
    (match cs
      ((Nil) Nil)
      ((Cons c rest) (if (or (== c #\newline) (== c #\return)) rest
                         (drop-through-newline rest)))))

  (declare parse (Dialect * String -> (Optional (List (List String)))))
  (define (parse d s)
    "Parse S under D into rows of fields. None on malformed input.

The reference implementation: every decision comes from `transition`, so anything this parser
does is something the typed transition said to do."
    (parse-chars d (into s) (Acc Nil Nil Nil StStart False) False))

  ;;; --- The CL boundary ------------------------------------------------------
  ;;; Promised representations only (String, Boolean, List) -- CL never touches a
  ;;; ParseState, Action, Step or Dialect (coalton-patterns.md §7).

  (declare step-names (String * String * Boolean * Boolean -> (List String)))
  (define (step-names state-name class-name seen? skip-blank?)
    "(action next-state) for a transition, by name. Returns Nil if either name is unknown.
The CL-callable form of the transition table, used by the totality test. CL-callable."
    (match (Tuple (parse-state-named state-name) (char-class-named class-name))
      ((Tuple (Some st) (Some cl))
       (let ((s (transition st cl seen? skip-blank?)))
         (Cons (action->string (step-action s))
               (Cons (parse-state->string (step-next s)) Nil))))
      (_ Nil)))

  (declare parse-state-named (String -> (Optional ParseState)))
  (define (parse-state-named s)
    (cond ((== s "start") (Some StStart))
          ((== s "unquoted") (Some StUnquoted))
          ((== s "quoted") (Some StQuoted))
          ((== s "quote-end") (Some StQuoteEnd))
          (True None)))

  (declare char-class-named (String -> (Optional CharClass)))
  (define (char-class-named s)
    (cond ((== s "delimiter") (Some ClDelimiter))
          ((== s "quote") (Some ClQuote))
          ((== s "escape") (Some ClEscape))
          ((== s "comment") (Some ClComment))
          ((== s "newline") (Some ClNewline))
          ((== s "return") (Some ClReturn))
          ((== s "other") (Some ClOther))
          ((== s "eof") (Some ClEof))
          (True None)))

  (declare state-names (List String))
  (define state-names
    (Cons "start" (Cons "unquoted" (Cons "quoted" (Cons "quote-end" Nil)))))

  (declare class-names (List String))
  (define class-names
    (Cons "delimiter" (Cons "quote" (Cons "escape" (Cons "comment"
      (Cons "newline" (Cons "return" (Cons "other" (Cons "eof" Nil)))))))))

  (declare dialect-chars-ok? (Char * Char -> Boolean))
  (define (dialect-chars-ok? delim q)
    "True when a delimiter and quote character can coexist in one dialect. CL-callable --
the invariant the CL DEFSTRUCT cannot express."
    (dialect-ok? (Dialect delim (Some q) None None False)))

  (declare parse-rfc4180-rows (String -> (List (List String))))
  (define (parse-rfc4180-rows s)
    "Parse S as RFC-4180 and return its rows. Nil for malformed input -- which is also what
an empty document returns, so a caller that cares uses PARSE-RFC4180-OK? to tell them
apart. CL-callable: List is a promised representation at both levels, so a list of lists of
strings crosses the boundary as itself (coalton-patterns.md §7)."
    (match (parse rfc4180 s)
      ((None) Nil)
      ((Some rows) rows)))

  (declare parse-rfc4180-ok? (String -> Boolean))
  (define (parse-rfc4180-ok? s)
    "False when S is malformed under RFC-4180 (an unterminated quoted field). CL-callable."
    (match (parse rfc4180 s) ((Some _) True) ((None) False))))
