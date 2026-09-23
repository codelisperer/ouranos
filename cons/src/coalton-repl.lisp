;;;; coalton-repl.lisp --- a headless Coalton eval + type-introspection engine.
;;;;
;;;; The lean, front-end-agnostic CORE of the visual Coalton REPL (cons roadmap §6;
;;;; hyperion ADR-0009 splits the engine [cons's share] from the visual front-end
;;;; [a hyperion side-project]). It reads a user's Coalton SOURCE STRING in a per-session
;;;; package that :uses COALTON + COALTON-PRELUDE, decides expression vs. definition, and
;;;; evaluates it in the live image:
;;;;   - an EXPRESSION  -> its value AND its inferred type scheme (coalton:type-of);
;;;;   - a DEFINITION   (define / define-type / declare / ...) -> registered so later
;;;;     inputs see it.
;;;;
;;;; Reading happens with *package* bound to the session package, at RUN time -- never a
;;;; compile/read-time reference to the coalton package (that fails before load; see
;;;; docs/coalton-patterns.md §6). This is an OPTIONAL cons system: it pulls Coalton, so
;;;; it is deliberately NOT part of cons core, which stays Coalton-free and lean.

(cl:defpackage #:cons/coalton-repl
  (:use #:cl)
  (:documentation
   "Headless Coalton eval + type-introspection engine: MAKE-SESSION creates an isolated
    session (its own package, so definitions persist and sessions don't collide);
    EVAL-INPUT evaluates one Coalton form string and returns a RESULT (value + inferred
    type, a definition, or an error). The visual front-end (hyperion) renders RESULTs.")
  (:export #:make-session #:session #:session-package-name #:reset-session
           #:eval-input #:input-complete-p
           #:result #:result-p #:result-kind #:result-input
           #:result-value #:result-type #:result-message))
(cl:in-package #:cons/coalton-repl)

;;; --- session ---------------------------------------------------------------

(defstruct (session (:constructor %make-session) (:copier nil))
  "A REPL session. PACKAGE is its own package (uses COALTON + COALTON-PRELUDE) in which
inputs are read and toplevel definitions land -- so definitions persist across inputs and
independent sessions don't collide."
  package)

(defun session-package-name (session)
  "The name of SESSION's package (handy for display/reset)."
  (package-name (session-package session)))

(defvar *session-counter* 0)

(defun make-session (&optional name)
  "Create a fresh REPL session with its own package (NAME or a generated one) that
:uses COALTON + COALTON-PRELUDE, exactly as a hand-written Coalton user package would."
  (let* ((pname (or name (format nil "COALTON-REPL-SESSION-~D" (incf *session-counter*))))
         (pkg (or (find-package pname)
                  (make-package pname :use '("COALTON" "COALTON-PRELUDE")))))
    (%make-session :package pkg)))

(defun reset-session (session)
  "Forget SESSION's definitions: delete and recreate its package. Returns SESSION."
  (let ((name (session-package-name session)))
    (ignore-errors (delete-package (session-package session)))
    (setf (session-package session)
          (make-package name :use '("COALTON" "COALTON-PRELUDE"))))
  session)

;;; --- result ----------------------------------------------------------------

(defstruct (result (:constructor %make-result) (:copier nil))
  "One evaluation outcome. KIND is :VALUE | :DEFINITION | :ERROR.
INPUT   -- the source string as entered;
VALUE   -- (:value) the printed result value;
TYPE    -- (:value) the inferred type scheme string, or NIL if unavailable;
MESSAGE -- (:definition) the defined name; (:error) the error text."
  kind input value type message)

;;; --- classification --------------------------------------------------------

(defparameter *definition-heads*
  '("DEFINE" "DEFINE-TYPE" "DEFINE-CLASS" "DEFINE-INSTANCE" "DECLARE"
    "DEFINE-STRUCT" "REPR" "SPECIALIZE" "DEFINE-ALIAS")
  "Coalton toplevel operators that DEFINE (go in coalton-toplevel) rather than evaluate
to a value. Compared case-insensitively (Coalton/CL symbols are upcased).")

(defun %definition-p (form)
  "True when FORM is a Coalton toplevel definition (see *DEFINITION-HEADS*)."
  (and (consp form) (symbolp (car form))
       (member (symbol-name (car form)) *definition-heads* :test #'string-equal)))

(defun %definition-name (form)
  "A display label for a definition FORM -- the defined name, best effort.
`(define (f x) ...)` -> \"f\"; `(define pi ...)` / `(define-type Foo ...)` -> the name."
  (let ((target (second form)))
    (princ-to-string (if (consp target) (car target) target))))

(defun %blankp (string)
  (zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return #\Page) string))))

(defun %definition-names (forms)
  "The display names of definition FORMS, in order, without repeats -- a `declare` and the
`define` it annotates name the same thing and should be reported once."
  (remove-duplicates (mapcar #'%definition-name forms)
                     :test #'string-equal :from-end t))

(defun %read-forms (input)
  "Every form in INPUT, in order. Signals END-OF-FILE when the text ends part-way through a
form -- which is exactly what INPUT-COMPLETE-P listens for. (CLHS: reaching EOF *within* an
object signals, regardless of EOF-ERROR-P; the NIL only covers ending cleanly between them.)"
  (let ((eof '#:eof))
    (loop with pos = 0
          for (form next) = (multiple-value-list
                             (read-from-string input nil eof :start pos))
          until (eq form eof)
          do (setf pos next)
          collect form)))

;;; --- input completeness (the multi-line rule) -------------------------------

(defun input-complete-p (input &optional session)
  "True when EVERY form in INPUT is complete -- the rule a MULTI-LINE front end uses to
decide whether ENTER evaluates or just opens another line. It belongs HERE, not in a front
end, so the desktop input box and any CLI REPL cons grows agree about what \"finished\"
means.

It reads to the END of the text, not just the first form: an input may hold several forms
(a `declare` and its `define`, say), and stopping at the first would submit
`(declare f (Integer -> Integer))` the moment its own paren closed, with the `define` below
it still half-typed.

The READER is the authority, which is what makes this cheap and exact: an unterminated
form, string, or block comment signals END-OF-FILE -> incomplete, keep collecting. ANY
OTHER read error means the text is complete and merely wrong -- EVAL-INPUT's job to report.
Returning NIL there would trap the user in an input that can never be submitted, so a
malformed-but-finished form is deliberately \"complete\". Blank input is complete too:
there is no unfinished form in it.

SESSION, when given, supplies the package to read in, so symbols intern exactly as
EVAL-INPUT would. *READ-EVAL* is bound off for the probe: this runs on a keystroke, before
the user has committed to evaluating anything, and `#.` in a half-typed form should not
fire. Its reader-error counts as complete, and EVAL-INPUT then reads it for real."
  (or (%blankp input)
      (let ((*package* (if session (session-package session) *package*))
            (*read-eval* nil))
        (handler-case (progn (%read-forms input) t)
          (end-of-file () nil)
          (error () t)))))

;;; --- evaluation ------------------------------------------------------------

(defun %eval-forms (forms)
  "Evaluate FORMS in order, returning (values LAST-EXPRESSION-FORM ITS-VALUE ANY-EXPRESSION-P
DEFINED-NAMES).

Each CONTIGUOUS RUN of definitions is compiled as ONE `coalton-toplevel`. That grouping is
the whole point: Coalton requires a `declare` to share a toplevel with the `define` it
annotates, so compiling forms one at a time makes type annotations impossible to write
(\"Orphan declaration\") and every REPL definition silently polymorphic -- which costs
roughly 47x on arithmetic-heavy code against the same function annotated. Contiguous rather
than \"all definitions first\", so evaluation order still reads top to bottom."
  (let ((defined '()) (last-form nil) (last-value nil) (any-expression nil))
    (loop with rest = forms
          while rest
          do (let ((run (loop for f in rest while (%definition-p f) collect f)))
               (cond
                 (run
                  (eval `(coalton:coalton-toplevel ,@run))
                  (setf defined (append defined (%definition-names run))
                        rest (nthcdr (length run) rest)))
                 (t
                  (let ((form (pop rest)))
                    (setf last-form form
                          last-value (eval `(coalton:coalton ,form))
                          any-expression t))))))
    (values last-form last-value any-expression defined)))

(defun eval-input (session input)
  "Evaluate INPUT (Coalton source: one form, or several) in SESSION; return a RESULT.
The LAST expression yields the value and inferred type; definitions are registered; any
error (read, type, or codegen) is captured as an :ERROR result rather than signalled.

Several forms per input is what makes a `declare` writable at all -- see %EVAL-FORMS. An
input that is only definitions reports the names it defined; otherwise the last expression's
value is the result, since that is the one a reader is asking about."
  (let ((*package* (session-package session)))
    (if (%blankp input)
        (%make-result :kind :value :input input :value "")
        (handler-case
            (multiple-value-bind (last-form value any-expression defined)
                (%eval-forms (%read-forms input))
              (cond
                (any-expression
                 ;; (Best effort) infer the type scheme of the expression whose value we are
                 ;; showing. type-of can fail (ambiguous types) -> NIL type. It does NOT
                 ;; re-run the expression: it compiles to a quoted scheme.
                 (let ((type (ignore-errors
                               (princ-to-string
                                (eval `(coalton:coalton (coalton:type-of ,last-form)))))))
                   (%make-result :kind :value :input input
                                 :value (prin1-to-string value)
                                 :type type)))
                (defined
                 (%make-result :kind :definition :input input
                               :message (format nil "~{~A~^, ~}" defined)))
                ;; Readable, but nothing in it: whitespace-only input never reaches here
                ;; (%BLANKP catches it), so this is a comment-only input.
                (t (%make-result :kind :value :input input :value ""))))
          (error (e)
            (%make-result :kind :error :input input
                          :message (princ-to-string e)))))))
