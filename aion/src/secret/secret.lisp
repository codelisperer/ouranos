;;;; secret.lisp --- an opaque credential wrapper: plaintext in, REVEAL out.
;;;;
;;;; The defect this exists to make unrepresentable (pre-publication issue 209): SBCL prints a structure by
;;;; printing its slots, and Coalton generates a printer for a DEFINE-TYPE that does the
;;;; same. So a credential stored as a bare STRING is rendered in full by anything that
;;;; prints the aggregate holding it -- most damagingly an unhandled condition's
;;;; backtrace, which is written to a deploy log precisely when a deployment is going
;;;; wrong. Nothing had to be wrong with the code for this to happen; printing is simply
;;;; not a path one thinks of when handling a password carefully. `cons` proves the
;;;; point: its DB-TARGET deliberately keeps the password out of argv AND carries a
;;;; separate redacted form for display, and still leaked it through the default
;;;; structure printer.
;;;;
;;;; Why a wrapper and not a PRINT-OBJECT on each holder: for a Coalton DEFINE-TYPE,
;;;; the representation is not promised across compilation modes (coalton-patterns.md
;;;; §7) -- PG-CONFIG is a STANDARD-CLASS in development and a STRUCTURE-CLASS in
;;;; release, and a multi-constructor type is not even named the same way in both. A
;;;; PRINT-OBJECT specializing on it is a representation dependency that compiles
;;;; happily in development and is wrong in release. This struct is OURS, so defining
;;;; its printer is ordinary CL, and it redacts no matter how the enclosing value is
;;;; represented or which mode built it.
;;;;
;;;; Deliberately NOT provided: a readable print form, an EQUAL that compares values, or
;;;; an accessor named for the slot. The single exit is called REVEAL so that
;;;; `grep -rn reveal` enumerates every place plaintext escapes -- the audit is a
;;;; command rather than a reading of the whole tree.

(in-package #:aion/secret)

(defstruct (secret (:constructor make-secret (%value))
                   (:copier nil)
                   (:predicate secretp))
  "An opaque credential. Construct with MAKE-SECRET, read with REVEAL; printing redacts.
The slot accessor is internal on purpose -- REVEAL is the only exported way out, so that
every disclosure is one greppable name."
  (%value "" :type string :read-only t))

(defmethod print-object ((s secret) stream)
  "Print as #<SECRET REDACTED>, for both ~S and ~A.

PRINT-UNREADABLE-OBJECT rather than a custom string for a second reason beyond the
value: it also removes the `#.` read syntax Coalton gives its own types, which invites
pasting a printed config straight back into a REPL. An unreadable object cannot be."
  (print-unreadable-object (s stream :type t)
    (write-string "REDACTED" stream)))

(defun reveal (s)
  "The plaintext inside S. THE disclosure point -- see this file's header."
  (secret-%value s))
