;;;; changeset.lisp --- Ecto-style changesets: cast + validate + bridge to queries (CL).
;;;;
;;;; The safe funnel for external data (form posts, JSON) into the database. CAST takes a
;;;; schema, a bag of raw params, and the fields you permit; it casts each permitted param
;;;; to its field's type and records a cast error on failure. A pipeline of VALIDATE-*
;;;; functions then threads the changeset, accumulating errors immutably. When valid, the
;;;; accumulated CHANGES compile straight into a mnemosyne/query INSERT/UPDATE -- so raw
;;;; params never reach SQL uncast, and a controller does mass-assignment safely (only the
;;;; permitted fields move). Errors are the condition system's job only at the edge
;;;; (INSERT!/UPDATE! signal CHANGESET-INVALID); validation itself is pure data.

(in-package #:mnemosyne/changeset)

(defstruct (changeset (:constructor %make-changeset) (:copier nil))
  "An in-flight change: the SCHEMA, the cast CHANGES (a plist field->value), and ERRORS
(an alist (field . message), most-recent first). Immutable -- validators return a fresh one."
  schema
  (changes nil :type list)
  (errors nil :type list))

(defun changeset-valid-p (cs) (null (changeset-errors cs)))

;;; --- reading params / changes ---------------------------------------------
(defun %param-get (params fname)
  "Look up field FNAME (keyword) in PARAMS -- a plist, an alist, or a hash-table -- matching
either the keyword :email or the string \"email\" (case-insensitive). (VALUES raw present-p)."
  (let ((sname (string-downcase (symbol-name fname))))
    (flet ((k= (k) (or (eq k fname)
                       (and (stringp k) (string-equal k sname))
                       (and (symbolp k) (string-equal (symbol-name k) sname)))))
      (typecase params
        (hash-table
         (multiple-value-bind (v p) (gethash fname params)
           (if p (values v t) (gethash sname params))))
        (cons
         (if (consp (car params))                    ; alist of (key . value)
             (let ((cell (find-if (lambda (c) (k= (car c))) params)))
               (if cell (values (cdr cell) t) (values nil nil)))
             (loop for (k v) on params by #'cddr      ; plist
                   when (k= k) do (return-from %param-get (values v t))
                   finally (return (values nil nil)))))
        (t (values nil nil))))))

(defun get-change (cs field)
  "(VALUES value present-p) for FIELD in the changeset's CHANGES."
  (loop for (k v) on (changeset-changes cs) by #'cddr
        when (eq k field) do (return-from get-change (values v t)))
  (values nil nil))

(defun apply-changes (cs)
  "The changeset's CHANGES as a plain plist (Ecto's apply_changes)."
  (copy-list (changeset-changes cs)))

;;; --- casting raw values by field type -------------------------------------
(defun %to-int (raw)
  (etypecase raw
    (integer raw)
    (real (truncate raw))
    (string (parse-integer (string-trim '(#\Space #\Tab) raw)))))

(defun %to-float (raw)
  (etypecase raw
    (real (coerce raw 'double-float))
    (string (let ((v (let ((*read-eval* nil))
                       (read-from-string (string-trim '(#\Space #\Tab) raw)))))
              (if (realp v) (coerce v 'double-float) (error "not a number"))))))

(defun %to-bool (raw)
  "Cast to a portable 1/0 (both SQLite INTEGER-boolean and Postgres boolean accept it).
(VALUES 1-or-0 ok-p)."
  (cond ((member raw '(t :true)) (values 1 t))
        ((null raw) (values 0 t))
        ((integerp raw) (values (if (zerop raw) 0 1) t))
        ((stringp raw)
         (let ((s (string-downcase (string-trim '(#\Space #\Tab) raw))))
           (cond ((member s '("true" "t" "1" "yes" "on") :test #'string=) (values 1 t))
                 ((member s '("false" "f" "0" "no" "off" "") :test #'string=) (values 0 t))
                 (t (values nil nil)))))
        (t (values nil nil))))

(defun %uuid-string-p (s)
  (and (stringp s) (= (length s) 36)
       (loop for c across s for i from 0
             always (if (member i '(8 13 18 23)) (char= c #\-)
                        (digit-char-p c 16)))))

(defun %octets-p (x)
  "True if X is a vector of (UNSIGNED-BYTE 8).

SUBTYPEP on the array's element type rather than TYPEP on the object, so a displaced or
adjustable octet vector counts. A general vector holding small integers does NOT: its
element type is T, and accepting it would let a list of numbers become a blob."
  (and (vectorp x)
       (subtypep (array-element-type x) '(unsigned-byte 8))))

(defun %float-text (x)
  "X as a decimal a Postgres float accepts.

~F RATHER THAN ~A, and this is the one that bites: a double-float prints as `1.0d0' under ~A,
and Postgres answers `invalid input syntax for type vector'. Embeddings arrive as
double-floats from any JSON reader, so ~A would have worked in a unit test written with
single-float literals and failed on every real embedding."
  (format nil "~F" x))

(defun %vector-literal (seq)
  "SEQ (reals) as pgvector's text form, `[1.0,0.5,0.0]'.

RENDERED HERE BECAUSE A BOUND LIST DOES NOT WORK, which was measured rather than assumed: a
Lisp list bound as a parameter reaches Postgres as `{1.0,0.0,0.0}' -- array syntax -- and is
refused with `invalid input syntax for type vector'. The text form binds fine. So something
has to render it, and cast is where external input becomes a storable value; leaving it to
every application would put the same string-building in each of them, differently."
  (format nil "[~{~A~^,~}]" (map 'list #'%float-text seq)))

(defun %vector-literal-values (s)
  "The values in a pgvector literal S, or NIL if S is not one. (VALUES list ok-p)."
  (let ((text (string-trim '(#\Space #\Tab) s)))
    (if (or (< (length text) 2)
            (char/= (char text 0) #\[)
            (char/= (char text (1- (length text))) #\]))
        (values nil nil)
        (let ((inner (string-trim '(#\Space #\Tab) (subseq text 1 (1- (length text))))))
          (if (zerop (length inner))
              (values '() t)
              (let ((parts (uiop:split-string inner :separator ",")))
                (values parts
                        (every (lambda (part)
                                 (let ((v (string-trim '(#\Space #\Tab) part)))
                                   (and (plusp (length v))
                                        (every (lambda (c) (find c "0123456789+-.eE")) v))))
                               parts))))))))

(defun %cast-vector (raw width)
  "Cast RAW to a vector value for a column of WIDTH. (VALUES value ok-p reason).

ACCEPTS A SEQUENCE OF REALS, which is what an embedding is in Lisp, and refuses a
wrong-length one HERE -- at cast time, where the error can name the schema's width -- rather
than at insert time, where it is a Postgres error about a column (#258).

ALSO ACCEPTS A WELL-FORMED LITERAL of the right width, and that is not leniency: `[1,0.5,0]'
is exactly what Postgres RETURNS for a vector column (measured), so refusing it would make
read-modify-write impossible -- an app would have to parse the string itself to hand it back.
Anything else is refused rather than coerced, the same call this file already makes for
binary: choosing a representation for the caller is a guess that becomes invisible once the
row is written."
  (cond
    ((stringp raw)
     (multiple-value-bind (values ok) (%vector-literal-values raw)
       (cond ((not ok)
              (values nil nil "is not a vector literal (expected [1,2,3] or a sequence of numbers)"))
             ((/= (length values) width)
              (values nil nil (format nil "has ~D value~:P, and the column declares ~D"
                                      (length values) width)))
             (t (values raw t nil)))))
    ((or (listp raw) (and (vectorp raw) (not (stringp raw))))
     (let ((n (length raw)))
       (cond ((not (every #'realp (coerce raw 'list)))
              (values nil nil "has a value that is not a number"))
             ((/= n width)
              (values nil nil (format nil "has ~D value~:P, and the column declares ~D"
                                      n width)))
             (t (values (%vector-literal raw) t nil)))))
    (t (values nil nil "is not a sequence of numbers"))))

(defun %cast-value (type-name raw &key (width 0))
  "Cast RAW to TYPE-NAME's Lisp value. (VALUES value ok-p reason); a failed cast is
(VALUES nil nil [reason]).

WIDTH is the declared width of a vector column and is ignored by every other type. The third
value is a REASON for the types that can say something more useful than `is invalid' -- a
vector of the wrong length being the case that matters, because `is invalid (expected
vector)' is what a correct-but-wrong-width embedding used to get, and it is indistinguishable
from the type not being supported at all."
  (handler-case
      (ecase type-name
        ((:vector) (%cast-vector raw width))
        ((:string :text) (values (if (stringp raw) raw (princ-to-string raw)) t))
        ((:integer :int) (values (%to-int raw) t))
        ((:float) (values (%to-float raw) t))
        ((:boolean :bool) (%to-bool raw))
        ((:uuid) (if (%uuid-string-p raw) (values raw t) (values nil nil)))
        ((:timestamp :date) (values (if (stringp raw) raw (princ-to-string raw)) t))
        ;; BYTES IN, BYTES OUT, AND NOTHING ELSE (#142). A string is refused rather than
        ;; encoded: choosing an encoding here would be this function guessing what the
        ;; caller meant, and the guess is invisible once the row is written. An app that
        ;; wants to store text as bytes encodes it itself, where the choice is readable.
        ((:binary :blob) (if (%octets-p raw) (values raw t) (values nil nil))))
    (error () (values nil nil))))

(defun cast (schema-name params allowed)
  "Begin a changeset for SCHEMA-NAME: for each field in ALLOWED that is present in PARAMS,
cast its raw value to the field's type. A failed cast records an error; missing fields are
simply absent (use VALIDATE-REQUIRED to demand them). Mass-assignment is safe -- only
ALLOWED fields are ever taken from PARAMS."
  (let* ((schema (mnemosyne/schema:find-schema schema-name))
         (pairs '()) (errors '()))         ; pairs: list of (field value), reverse ALLOWED order
    (dolist (fname allowed)
      (multiple-value-bind (raw present) (%param-get params fname)
        (when present
          (let ((field (mnemosyne/schema:schema-field schema fname)))
            (multiple-value-bind (val ok reason)
                (%cast-value (mnemosyne/schema:field-type-name field) raw
                             :width (mnemosyne/field:field-type-width
                                     (mnemosyne/schema:field-type field)))
              (if ok
                  (push (list fname val) pairs)
                  (push (cons fname
                              (or reason
                                  (format nil "is invalid (expected ~(~A~))"
                                          (mnemosyne/schema:field-type-name field))))
                        errors)))))))
    (%make-changeset :schema schema
                     :changes (loop for p in (nreverse pairs) nconc p)  ; flatten in ALLOWED order
                     :errors errors)))

;;; --- validation (immutable pipeline) --------------------------------------
(defun add-error (cs field message)
  "Return a copy of CS with (FIELD . MESSAGE) prepended to its errors."
  (%make-changeset :schema (changeset-schema cs)
                   :changes (changeset-changes cs)
                   :errors (cons (cons field message) (changeset-errors cs))))

(defun %blank-p (v)
  (or (null v)
      (and (stringp v) (every (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return))) v))))

(defun validate-required (cs fields &key (message "can't be blank"))
  "Error on each of FIELDS whose change is absent or blank."
  (reduce (lambda (c f)
            (multiple-value-bind (v present) (get-change c f)
              (if (and present (not (%blank-p v))) c (add-error c f message))))
          fields :initial-value cs))

(defun validate-change (cs field predicate message)
  "General validator: if FIELD has a change and PREDICATE of its value is false, add an
error. Absent fields pass (use VALIDATE-REQUIRED to demand presence)."
  (multiple-value-bind (v present) (get-change cs field)
    (if (and present (not (funcall predicate v))) (add-error cs field message) cs)))

(defun validate-format (cs field predicate &key (message "has invalid format"))
  "PREDICATE is a function of the (string) value -- true if the format is acceptable. Kept
dep-free: pass e.g. an email predicate, or (lambda (s) (cl-ppcre:scan re s)) if ppcre is
loaded."
  (validate-change cs field (lambda (v) (and (stringp v) (funcall predicate v))) message))

(defun validate-length (cs field &key min max
                                       (message (format nil "must be ~@[at least ~A~]~:[~; and ~]~@[at most ~A~] characters"
                                                        min (and min max) max)))
  "Bound the length of a string change by MIN/MAX (inclusive)."
  (validate-change cs field
                   (lambda (v) (let ((n (length (string v))))
                                 (and (or (null min) (>= n min)) (or (null max) (<= n max)))))
                   message))

(defun validate-number (cs field &key gt gte lt lte equal
                                       (message "is out of range"))
  "Bound a numeric change: GT/GTE/LT/LTE (strict/inclusive) and EQUAL."
  (validate-change cs field
                   (lambda (v) (and (realp v)
                                    (or (null gt) (> v gt)) (or (null gte) (>= v gte))
                                    (or (null lt) (< v lt)) (or (null lte) (<= v lte))
                                    (or (null equal) (= v equal))))
                   message))

(defun validate-inclusion (cs field members &key (test #'equal)
                                                 (message "is not a valid option"))
  "Require FIELD's change to be one of MEMBERS."
  (validate-change cs field (lambda (v) (member v members :test test)) message))

(defun validate-exclusion (cs field members &key (test #'equal)
                                                 (message "is reserved"))
  "Require FIELD's change to be none of MEMBERS."
  (validate-change cs field (lambda (v) (not (member v members :test test))) message))

;;; --- bridge to mnemosyne/query --------------------------------------------
(define-condition changeset-invalid (error)
  ((changeset :initarg :changeset :reader changeset-invalid-changeset))
  (:report (lambda (c s)
             (format s "mnemosyne/changeset: invalid changeset~{~%  ~(~A~): ~A~}"
                     (loop for (f . m) in (changeset-errors (changeset-invalid-changeset c))
                           nconc (list f m)))))
  (:documentation "Signalled by TO-INSERT/TO-UPDATE/INSERT!/UPDATE! on an invalid changeset."))

(defun %ensure-valid (cs)
  (unless (changeset-valid-p cs) (error 'changeset-invalid :changeset cs))
  cs)

(defun %table (cs) (mnemosyne/schema:schema-table (changeset-schema cs)))

(defun to-insert (cs)
  "The changeset as an INSERT query plist (for mnemosyne/query). Signals if invalid."
  (%ensure-valid cs)
  (list :insert-into (%table cs) :values (list (changeset-changes cs))))

(defun to-update (cs where)
  "The changeset as an UPDATE query plist with WHERE (an s-expr predicate). Signals if invalid."
  (%ensure-valid cs)
  (list :update (%table cs) :set (changeset-changes cs) :where where))

(defun insert! (cs connection &key (dialect mnemosyne/query:*dialect*))
  "Compile TO-INSERT and run it on CONNECTION (affected-row count). Signals if invalid."
  (mnemosyne/query:run connection (to-insert cs) :dialect dialect))

(defun update! (cs connection where &key (dialect mnemosyne/query:*dialect*))
  "Compile TO-UPDATE and run it on CONNECTION. Signals if invalid."
  (mnemosyne/query:run connection (to-update cs where) :dialect dialect))
