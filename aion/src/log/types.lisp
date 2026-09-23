;;;; types.lisp --- the typed core of aion/log, in Coalton.
;;;;
;;;; Logging crosses a boundary in keywords: :info, :warn, :pretty, :json, and a plist of
;;;; whatever the caller had lying around. Keywords are where silent bugs live -- nothing
;;;; stops a typo'd :warm from compiling, nothing orders :debug against :error except a
;;;; hand-written table, and nothing complains when a third layout is added and one ECASE
;;;; somewhere still knows about two. This layer turns each of those keywords into a type,
;;;; once, at the boundary (see ../../docs/coalton-story.md; aion/uv/types.lisp is the
;;;; worked reference this follows).
;;;;
;;;; It is pure, and it can afford to be: RENDER was already a pure function of
;;;; (level, category, message, fields) -> String, which is exactly why aion/log is the
;;;; easiest genuinely-typed lift in aion. The effects stay next door in the CL shell --
;;;; log4cl gating, the appender, the clock. Nothing here does IO.
;;;;
;;;; What the types buy, concretely:
;;;;
;;;;   Level with an Ord instance   gating is `>=`, and a level that does not exist is a
;;;;                               compile error rather than a silently-never-logged call
;;;;   Layout as Pretty | Json      RENDER is exhaustive by construction; adding a third
;;;;                               layout fails to compile until every branch handles it
;;;;   Event / Field                the shape of a log line is a value, not four positional
;;;;                               arguments that drift apart
;;;;
;;;; Boundary rule (docs/coalton-patterns.md §7): only Coalton's PROMISED representations
;;;; cross to CL -- String, Boolean, Integer, List and the other scalars. A define-type's
;;;; representation is mode-dependent, so the CL shell never constructs or inspects a
;;;; Level, Layout, Field or Event directly; it calls the monomorphic wrappers at the foot
;;;; of this file, which take and return promised types only.

(cl:in-package #:aion/log/types)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- Severity --------------------------------------------------------------
  ;;;
  ;;; Named LvTrace/LvError rather than Trace/Error: Coalton is case-insensitive, and
  ;;; coalton-prelude already exports both `trace` and `error`. A constructor named Error
  ;;; would BE the prelude's error (coalton-patterns.md §4).

  (define-type Level
    "How severe an event is. Ordered: LvTrace < LvDebug < LvInfo < LvWarn < LvError < LvFatal."
    LvTrace
    LvDebug
    LvInfo
    LvWarn
    LvError
    LvFatal)

  (declare level-rank (Level -> Integer))
  (define (level-rank l)
    "The severity ordinal. The single place the order is written down; Eq and Ord below
both derive from it, so they cannot disagree with each other."
    (match l
      ((LvTrace) 0)
      ((LvDebug) 1)
      ((LvInfo) 2)
      ((LvWarn) 3)
      ((LvError) 4)
      ((LvFatal) 5)))

  (define-instance (Eq Level)
    (define (== a b) (== (level-rank a) (level-rank b))))

  (define-instance (Ord Level)
    (define (<=> a b) (<=> (level-rank a) (level-rank b))))

  (declare level->string (Level -> String))
  (define (level->string l)
    (match l
      ((LvTrace) "trace")
      ((LvDebug) "debug")
      ((LvInfo) "info")
      ((LvWarn) "warn")
      ((LvError) "error")
      ((LvFatal) "fatal")))

  (declare level->padded (Level -> String))
  (define (level->padded l)
    "The upper-case name padded to five columns, so pretty output aligns. Written out
rather than computed: every level name is four or five characters, and a padding routine
would be more code than the six literals it replaces."
    (match l
      ((LvTrace) "TRACE")
      ((LvDebug) "DEBUG")
      ((LvInfo) "INFO ")
      ((LvWarn) "WARN ")
      ((LvError) "ERROR")
      ((LvFatal) "FATAL")))

  (declare parse-level (String -> (Optional Level)))
  (define (parse-level s)
    "Decode a level name. None for anything else -- this is the boundary where a typo'd
\"warm\" stops being a runtime surprise and becomes a value the caller must handle."
    (cond
      ((== s "trace") (Some LvTrace))
      ((== s "debug") (Some LvDebug))
      ((== s "info") (Some LvInfo))
      ((== s "warn") (Some LvWarn))
      ((== s "error") (Some LvError))
      ((== s "fatal") (Some LvFatal))
      (True None)))

  (declare level-enabled? (Level * Level -> Boolean))
  (define (level-enabled? event threshold)
    "Would an event at EVENT be emitted when the logger is set to THRESHOLD?

This is the whole point of the Ord instance: gating is `>=` over a type, not a lookup in a
keyword table that a sixth level could be left out of."
    (>= (level-rank event) (level-rank threshold)))

  ;;; --- How a line renders ----------------------------------------------------

  (define-type Layout
    "How an event is rendered: human-readable, or one JSON object per line."
    Pretty
    Json)

  (declare layout->string (Layout -> String))
  (define (layout->string l)
    (match l
      ((Pretty) "pretty")
      ((Json) "json")))

  (declare parse-layout (String -> (Optional Layout)))
  (define (parse-layout s)
    (cond
      ((== s "pretty") (Some Pretty))
      ((== s "json") (Some Json))
      (True None)))

  ;;; --- The event -------------------------------------------------------------
  ;;;
  ;;; A field's VALUE arrives from CL as anything at all. The CL shell decides, once, at
  ;;; the boundary, whether it is a JSON string or a JSON literal (a number, true/false),
  ;;; and tags it. That decision is exactly the "decode once, at the edge" rule: the shell
  ;;; knows CL's type universe, this layer knows what JSON allows, and neither guesses.

  (define-type FieldValue
    "A field's value, classified for rendering."
    (FStr String)   ; render as a quoted, escaped JSON string
    (FRaw String))  ; already a valid JSON literal (number, true, false) -- emit verbatim

  (declare field-value->string (FieldValue -> String))
  (define (field-value->string v)
    "The bare text of a value, for the pretty layout (which quotes nothing)."
    (match v
      ((FStr s) s)
      ((FRaw s) s)))

  (define-type Field
    "One structured key/value pair on an event."
    (Field String FieldValue))

  (declare field-key (Field -> String))
  (define (field-key f) (match f ((Field k _) k)))

  (declare field-value (Field -> FieldValue))
  (define (field-value f) (match f ((Field _ v) v)))

  (define-type Event
    "Everything a rendered log line is made of: severity, source category, the message,
the timestamp (a String -- reading a clock is IO, so the CL shell supplies it), and the
structured fields."
    (Event Level String String String (List Field)))

  (declare event-level (Event -> Level))
  (define (event-level e) (match e ((Event l _ _ _ _) l)))

  (declare event-category (Event -> String))
  (define (event-category e) (match e ((Event _ c _ _ _) c)))

  (declare event-message (Event -> String))
  (define (event-message e) (match e ((Event _ _ m _ _) m)))

  (declare event-timestamp (Event -> String))
  (define (event-timestamp e) (match e ((Event _ _ _ ts _) ts)))

  (declare event-fields (Event -> (List Field)))
  (define (event-fields e) (match e ((Event _ _ _ _ fs) fs)))

  ;;; --- Field selection -------------------------------------------------------

  (declare visible-fields ((List String) * (List Field) -> (List Field)))
  (define (visible-fields reserved fields)
    "FIELDS in order, keeping the FIRST occurrence of each key and dropping any key in
RESERVED.

Two rules the CL facade has always had, now in one place: a per-call field beats an
ambient context field of the same name (first wins, because the shell conses per-call
fields on the front), and neither can clobber a core key such as ts or level."
    (lst:reverse
     (fst
      (fold (fn (acc f)
              (match acc
                ((Tuple kept seen)
                 (if (lst:member (field-key f) seen)
                     acc
                     (Tuple (Cons f kept) (Cons (field-key f) seen))))))
            (Tuple Nil reserved)
            fields))))

  ;;; --- Rendering -------------------------------------------------------------

  (declare json-string (String -> String))
  (define (json-string s)
    "S as a quoted, fully-escaped JSON string literal.

Delegated to jzon rather than hand-rolled: correct escaping means quotes, backslashes AND
every control character below U+0020, and getting that subtly wrong produces a log line
that silently breaks a downstream parser. This is a String -> String function of a
promised representation (coalton-patterns.md §7), and jzon:stringify allocates a string --
it performs no IO, so the no-IO-in-Coalton rule holds."
    (lisp (-> String) (s)
      (com.inuoe.jzon:stringify s)))

  (declare render-field-json (Field -> String))
  (define (render-field-json f)
    (<> (json-string (field-key f))
        (<> ":"
            (match (field-value f)
              ((FStr s) (json-string s))
              ((FRaw s) s)))))

  (declare render-field-pretty (Field -> String))
  (define (render-field-pretty f)
    (<> " " (<> (field-key f) (<> "=" (field-value->string (field-value f))))))

  (declare render-pretty (Event -> String))
  (define (render-pretty e)
    "TS LEVEL [CAT] MESSAGE k=v k=v ..."
    (fold (fn (acc f) (<> acc (render-field-pretty f)))
          (<> (event-timestamp e)
              (<> " "
                  (<> (level->padded (event-level e))
                      (<> " ["
                          (<> (event-category e)
                              (<> "] " (event-message e)))))))
          (visible-fields Nil (event-fields e))))

  (declare render-json (Event -> String))
  (define (render-json e)
    "One JSON object: the four core keys, then the structured fields.

The core keys are passed to VISIBLE-FIELDS as reserved, so a field called \"level\" cannot
overwrite the severity -- the same protection the CL renderer had, now stated once."
    (<> (fold (fn (acc f) (<> acc (<> "," (render-field-json f))))
              (<> "{"
                  (<> (render-field-json (Field "ts" (FStr (event-timestamp e))))
                      (<> "," (<> (render-field-json
                                   (Field "level" (FStr (level->string (event-level e)))))
                                  (<> "," (<> (render-field-json
                                               (Field "cat" (FStr (event-category e))))
                                              (<> "," (render-field-json
                                                       (Field "msg" (FStr (event-message e)))))))))))
              (visible-fields (Cons "ts" (Cons "level" (Cons "cat" (Cons "msg" Nil))))
                              (event-fields e)))
        "}"))

  (declare render (Event * Layout -> String))
  (define (render e layout)
    "Render EVENT under LAYOUT.

Exhaustive by construction: adding a third Layout constructor makes this match incomplete
and the compiler says so, which is the property an ECASE over keywords could never give."
    (match layout
      ((Pretty) (render-pretty e))
      ((Json) (render-json e))))

  ;;; --- The CL boundary -------------------------------------------------------
  ;;;
  ;;; Everything below takes and returns PROMISED representations only (String, Boolean,
  ;;; Integer, List), so the CL shell never touches a define-type's representation --
  ;;; which Coalton guarantees nothing about across compilation modes (§7). The Field and
  ;;; Event values CL holds are opaque: built here, passed straight back here, never
  ;;; inspected there.

  (declare valid-level-name? (String -> Boolean))
  (define (valid-level-name? s)
    "True when S names a level. The check that turns a typo'd \"warm\" into an error the
shell can signal, instead of a call that quietly never logs. CL-callable."
    (match (parse-level s) ((Some _) True) ((None) False)))

  (declare valid-layout-name? (String -> Boolean))
  (define (valid-layout-name? s)
    "True when S names a layout. CL-callable."
    (match (parse-layout s) ((Some _) True) ((None) False)))

  (declare level-name-rank (String -> Integer))
  (define (level-name-rank s)
    "The severity ordinal of a level name, or -1 if it is not a level. CL-callable."
    (match (parse-level s) ((Some l) (level-rank l)) ((None) -1)))

  (declare level-name-enabled? (String * String -> Boolean))
  (define (level-name-enabled? event threshold)
    "Would an event at level EVENT be emitted at THRESHOLD? False if either name is not a
level -- an unknown level is not silently treated as maximally severe. CL-callable."
    (match (Tuple (parse-level event) (parse-level threshold))
      ((Tuple (Some e) (Some t)) (level-enabled? e t))
      (_ False)))

  (declare mk-field-string (String * String -> Field))
  (define (mk-field-string k v)
    "A field whose value renders as a quoted JSON string. CL-callable; the result is
opaque to CL and is only ever handed back to RENDER-LINE."
    (Field k (FStr v)))

  (declare mk-field-raw (String * String -> Field))
  (define (mk-field-raw k v)
    "A field whose value is ALREADY a valid JSON literal -- a number, or true/false. The
CL shell decides which of CL's types qualify; this layer only records the decision.
CL-callable, opaque result."
    (Field k (FRaw v)))

  (declare render-event-line
           (String * String * String * String * String * (List Field) -> String))
  (define (render-event-line layout-name level-name category message timestamp fields)
    "Render one log line from promised scalars plus a list of opaque Fields. The single
entry point the CL facade calls.

An unrecognised layout or level name falls back to pretty / info rather than signalling:
this runs on the emission path, where refusing to log because a level was misspelled would
lose the very event someone is trying to read. VALID-LEVEL-NAME? is how a caller checks
deliberately, at configuration time. CL-callable."
    (let ((layout (with-default Pretty (parse-layout layout-name)))
          (level (with-default LvInfo (parse-level level-name))))
      (render (Event level category message timestamp fields) layout))))
