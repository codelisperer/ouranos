;;;; field-shell.lisp --- the CL half of the field-type vocabulary (#334).
;;;;
;;;; ADR-0001 decided that `field-type-sql' returns whether a backend can carry a type, and
;;;; that the CL shell turns a refusal into a condition. This is that shell. It exists as its
;;;; own file because the typed half must stay IO-free and condition-free, and because all
;;;; three callers -- schema, ddl, introspect -- need the same two decisions made the same
;;;; way. Three copies of "what do we do when a backend cannot store this" is how the three
;;;; drift, and the one that drifts is discovered in a migration.

(in-package #:mnemosyne/field-shell)

(defparameter +dialects+
  (list mnemosyne/field:D-Sqlite mnemosyne/field:D-Postgres mnemosyne/field:D-Xtdb)
  "Every dialect, as typed values. THE tree-wide list (#432, ADR-0003).

It lives here rather than in each module because a per-module list is the defect this ADR
removes: MNEMOSYNE/QUERY kept `(:sqlite :postgres :xtdb)' and MNEMOSYNE/DDL kept the same
three words as strings, and the two could not disagree loudly -- only silently, by one of
them taking a branch meant for the other.")

(defparameter +dialect-names+
  (mapcar #'mnemosyne/field:dialect-name +dialects+)
  "The canonical spelling of each dialect, for messages. DERIVED from +DIALECTS+ rather than
written out again, because a hand-kept second list is how the two come to disagree.")

(define-condition unknown-dialect (error)
  ((name :initarg :name :reader unknown-dialect-name))
  (:report
   (lambda (c s)
     ;; The known names are READ FROM THE VOCABULARY, not written out again (#432). A
     ;; message listing its own copy of the three names is a fourth place for them to
     ;; disagree, and the one place a reader would most trust.
     ;;
     ;; No `~<newline>' continuations here: a CRLF checkout turns one into an illegal
     ;; `~<Return>' directive (CLAUDE.md), so the control strings stay folded onto one line.
     (format s "mnemosyne: unknown backend dialect ~S.~%~%" (unknown-dialect-name c))
     (format s "Known: ~{~A~^, ~}.~%" +dialect-names+)
     (format s "This used to be a String that quietly meant \"not postgres\", so a typo produced SQLite affinities against a Postgres database with no error anywhere (ADR-0001, #334).~%")
     (format s "Every module that branches on a dialect now refuses a spelling it does not recognise rather than treating it as the other one (ADR-0003, #432), and this is what the typo looks like.~%"))))

(define-condition unsupported-field-type (error)
  ((field :initarg :field :initform nil :reader unsupported-field-type-field)
   (type :initarg :type :reader unsupported-field-type-type)
   (backend :initarg :backend :reader unsupported-field-type-backend)
   (support :initarg :support :reader unsupported-field-type-support))
  (:report
   (lambda (c s)
     (format s "mnemosyne: backend ~A cannot store ~@[field ~A of ~]type ~A (~A).~%~%~
Refusing at migration time is the DEFAULT this protocol chose, because the alternative~%~
default is silence -- and silence is what the substrate gives: SQLite accepts a column type~%~
it has never heard of and stores it with NUMERIC affinity, so the app finds out never.~%~
~:[~;~%Emulation is opt-in at the declaration site and that opt-in is not implemented yet~%~
(#212); until it is, an emulated type is refused here rather than emulated silently.~%~]"
             (unsupported-field-type-backend c)
             (unsupported-field-type-field c)
             (unsupported-field-type-type c)
             (unsupported-field-type-support c)
             (string= (unsupported-field-type-support c) "emulated")))))

(defun dialect-for (dialect)
  "The typed Dialect for DIALECT, or signal UNKNOWN-DIALECT.

THE ONE NORMALISER (#432, ADR-0003). Every module that branches on a dialect calls this at
its entry point and branches on the value it returns, so that there is one answer tree-wide
to `is this a dialect, and which one'.

Accepts a DESIGNATOR -- an already-typed Dialect, a string, or a symbol/keyword -- because
the callers genuinely hold it in all three shapes: a keyword is what a Lisp caller writes,
a string is what a DATABASE_URL or a config file yields, and a typed value is what this
function itself returns. Accepting all three HERE is not the permissiveness the ticket
objected to; the objection was to each module accepting a different subset and treating the
rest as `the other dialect'.

IDEMPOTENT, so a caller that has already normalised can pass the result on without a second
vocabulary for `already checked'.

REFUSES EVERYTHING ELSE. The old version took `(string name)' on whatever it was handed,
which made the check a check about a string designator; a caller holding some other object
got a type error naming CL's STRING rather than a condition naming the dialect."
  (typecase dialect
    ;; Already typed. First, because a Coalton nullary constructor is an object and the
    ;; later clauses would otherwise have to guess what kind.
    (mnemosyne/field:Dialect dialect)
    ((or string symbol)
     (let ((n (string-downcase (string dialect))))
       ;; NOT `(or (dialect-from n) (error ...))'. Coalton's NONE is an object, and every
       ;; object is true in CL, so that form accepts the failure case and returns NONE as if
       ;; it were a dialect. The predicate is the only safe way to ask this from CL.
       (unless (mnemosyne/field:dialect-known? n)
         (error 'unknown-dialect :name dialect))
       (mnemosyne/field:dialect-required n)))
    (t (error 'unknown-dialect :name dialect))))

(defun dialect-name-of (dialect)
  "The canonical name of DIALECT (a designator), checked on the way through.

For the callers that need the SPELLING -- a message, a struct slot, a report -- and must not
get it by rendering an unchecked value with PRINC."
  (mnemosyne/field:dialect-name (dialect-for dialect)))

(defun dialect= (dialect other)
  "Is DIALECT (a designator) the dialect OTHER (a typed value)?

The comparison every module makes, in one place. A Coalton nullary constructor is a
singleton -- `(eq (dialect-for \"postgres\") D-Postgres)' is true -- so this is EQ on a
checked value rather than STRING= on an unchecked one, which is the substitution this ADR
is about."
  (eq (dialect-for dialect) other))

(defun column-sql (field-type dialect &key field-name)
  "The SQL column type for FIELD-TYPE under DIALECT, or signal UNSUPPORTED-FIELD-TYPE.

DIALECT is a designator -- string, symbol or typed Dialect -- and is normalised through
DIALECT-FOR, because the callers hold it in all three shapes and converting at each of them
is three chances to convert differently. An unrecognised one signals UNKNOWN-DIALECT here
rather than reaching Coalton, where it surfaced as `Pattern match not exhaustive' naming
neither the dialect nor the caller (#432).

REFUSES EMULATED AS WELL AS UNSUPPORTED, and that is deliberate rather than conservative:
ADR-0001 makes emulation opt-in at the declaration site precisely so it is never implicit,
and the opt-in does not exist yet. Accepting an emulated type here would be the implicit
degradation the ADR rejected, arriving through the door marked `not yet implemented'."
  (let* ((d (dialect-for dialect))
         (result (mnemosyne/field:field-type-sql field-type d))
         (tag (mnemosyne/field:sql-type-tag result)))
    (if (string= tag "native")
        (mnemosyne/field:sql-type-text result)
        (error 'unsupported-field-type
               :field field-name
               :type (mnemosyne/field:field-type-name field-type)
               :backend (mnemosyne/field:dialect-name d)
               :support tag))))

(defun field-type-supported-p (field-type dialect)
  "\"native\" | \"emulated\" | \"unsupported\" -- the predicate ADR-0001 asks for, so an app
can ask BEFORE declaring rather than discovering at migration time."
  (mnemosyne/field:field-type-support field-type (dialect-for dialect)))
