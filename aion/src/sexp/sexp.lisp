;;;; sexp.lisp --- a safe reader and writer for s-expression data (#972).
;;;;
;;;; Apps keep data as s-expressions and used to read it back with CL:READ and *READ-EVAL*
;;;; bound to NIL. On input that comes from outside, that still builds any struct (#S),
;;;; interns any symbol, including package-qualified ones, allocates a huge object from a few
;;;; characters (#1000000(0)), and exhausts the control stack on deep nesting, which is a
;;;; STORAGE-CONDITION rather than an error a caller can handle.
;;;;
;;;; READ-DATA is therefore a parser of its own, not CL:READ with a restricted readtable: the
;;;; Lisp reader interns a symbol token before anything can look at it, and recurses on
;;;; nesting. This one accepts plain data only, interns nothing, keeps its own stack, and
;;;; checks every limit as it goes, signalling UNSAFE-DATA for anything else. WRITE-DATA writes
;;;; only what READ-DATA accepts.

(defpackage #:aion/sexp
  (:use #:cl)
  (:export #:read-data #:write-data #:write-data-to-string
           #:unsafe-data #:unsafe-data-reason #:unsafe-data-position #:unsafe-data-detail
           #:*max-depth* #:*max-elements* #:*max-string-length* #:*max-number-digits*
           #:*max-input*))

(in-package #:aion/sexp)

;;; --- the condition and the limits ---------------------------------------------------------

(define-condition unsafe-data (error)
  ((reason :initarg :reason :reader unsafe-data-reason)
   (position :initarg :position :initform nil :reader unsafe-data-position)
   (detail :initarg :detail :initform nil :reader unsafe-data-detail))
  (:report (lambda (c s)
             (format s "unsafe s-expression data (~(~A~))~@[ at character ~D~]~@[: ~A~]"
                     (unsafe-data-reason c) (unsafe-data-position c) (unsafe-data-detail c))))
  (:documentation "READ-DATA was given input, or WRITE-DATA a datum, outside what this module
accepts. REASON is a keyword: :DISPATCH-MACRO, :READER-MACRO, :ESCAPED-SYMBOL, :COMMENT,
:UNKNOWN-SYMBOL, :PACKAGE-PREFIX, :TOO-DEEP, :TOO-MANY-ELEMENTS, :STRING-TOO-LONG,
:NUMBER-TOO-LONG, :NUMBER-OUT-OF-RANGE, :DIVISION-BY-ZERO, :INPUT-TOO-LONG, :SYNTAX,
:END-OF-INPUT or, from WRITE-DATA, :UNWRITABLE. POSITION is the character offset in the input,
or NIL from WRITE-DATA. DETAIL quotes at most the first 40 characters of the offending
token."))

(defparameter *max-depth* 64 "The deepest nesting of lists accepted.")
(defparameter *max-elements* 100000 "The most conses and atoms in one datum.")
(defparameter *max-string-length* 65536 "The longest string, or symbol name, accepted.")
(defparameter *max-number-digits* 100
  "The most digits in an integer, in each part of a ratio, and in a float's digits. A float's
exponent is bounded separately, by the range of a double float.")
(defparameter *max-input* 1048576 "The most characters READ-DATA reads for one datum.")

(defun %unsafe (reason position &optional detail &rest args)
  (error 'unsafe-data :reason reason :position position
                      :detail (and detail (apply #'format nil detail args))))

(defun %clip (string)
  (if (> (length string) 40) (concatenate 'string (subseq string 0 40) "...") string))

;;; --- characters -----------------------------------------------------------------------------

(defun %whitespace-p (c)
  (member c '(#\Space #\Tab #\Newline #\Return #\Page #\Linefeed)))

(defun %constituent-p (c)
  "A character a symbol or number token may hold."
  (or (alphanumericp c) (find c "-+*/<>=!?%&_.^~$@")))

(defun %delimiter-p (c)
  (or (%whitespace-p c) (find c "()\"';`,#|\\")))

;;; --- reading --------------------------------------------------------------------------------

(defstruct (%reader (:conc-name %r-))
  stream (position 0) (elements 0) symbols intern-keywords
  max-depth max-elements max-string-length max-number-digits max-input)

(defun %peek (r)
  (peek-char nil (%r-stream r) nil nil))

(defun %next (r)
  (let ((c (read-char (%r-stream r) nil nil)))
    (when c
      (when (>= (%r-position r) (%r-max-input r))
        (%unsafe :input-too-long (%r-position r) "more than ~D characters" (%r-max-input r)))
      (incf (%r-position r)))
    c))

(defun %count-element (r)
  (when (> (incf (%r-elements r)) (%r-max-elements r))
    (%unsafe :too-many-elements (%r-position r) "more than ~D elements" (%r-max-elements r))))

(defun %skip-whitespace (r)
  (loop for c = (%peek r) while (and c (%whitespace-p c)) do (%next r)))

(defun %refuse-character (r c)
  "Signal UNSAFE-DATA for C, a character that cannot start a datum here."
  (let ((at (%r-position r)))
    (case c
      (#\# (%unsafe :dispatch-macro at "a # form is not data"))
      ((#\' #\` #\,) (%unsafe :reader-macro at "~C is not data" c))
      ((#\| #\\) (%unsafe :escaped-symbol at "an escaped symbol is not accepted"))
      (#\; (%unsafe :comment at "comments are not accepted"))
      (t (%unsafe :syntax at "unexpected ~S" c)))))

(defun %read-string (r)
  "The string whose opening quote has just been read."
  (let ((out (make-string-output-stream)) (length 0) (start (%r-position r)))
    (loop
      (let ((c (%next r)))
        (cond ((null c) (%unsafe :end-of-input start "a string is not closed"))
              ((char= c #\") (return (get-output-stream-string out)))
              ((char= c #\\)
               (let ((escaped (%next r)))
                 (unless (and escaped (find escaped "\\\""))
                   (%unsafe :syntax (%r-position r) "only \\\\ and \\\" are escapes in a string"))
                 (setf c escaped))))
        (when (> (incf length) (%r-max-string-length r))
          (%unsafe :string-too-long start "longer than ~D characters" (%r-max-string-length r)))
        (write-char c out)))))

(defun %read-token (r)
  "The text of the symbol or number token starting at the next character."
  (let ((out (make-string-output-stream)) (length 0) (start (%r-position r)))
    (loop for c = (%peek r)
          while (and c (not (%delimiter-p c)) (not (%whitespace-p c)))
          do (unless (or (%constituent-p c) (char= c #\:))
               (%unsafe :syntax (%r-position r) "~S cannot be part of a token" c))
             (when (> (incf length) (max (%r-max-string-length r) (+ 40 (* 3 (%r-max-number-digits r)))))
               (%unsafe :string-too-long start "a token longer than the limit"))
             (write-char (%next r) out))
    (get-output-stream-string out)))

(defun %digits-p (string &key (start 0) end)
  (let ((end (or end (length string))))
    (and (< start end) (every #'digit-char-p (subseq string start end)))))

(defun %parse-integer-token (token r start)
  "TOKEN as an integer, or NIL when it is not one: an optional sign and decimal digits, and
optionally a trailing decimal point, which the standard reader also reads as an integer (1.)."
  (let* ((digits (if (find (char token 0) "+-") 1 0))
         (end (if (and (> (length token) (1+ digits)) (char= #\. (char token (1- (length token)))))
                  (1- (length token))
                  (length token))))
    (when (%digits-p token :start digits :end end)
      (when (> (- end digits) (%r-max-number-digits r))
        (%unsafe :number-too-long start "more than ~D digits" (%r-max-number-digits r)))
      (parse-integer token :end end))))

(defun %parse-ratio-token (token r start)
  "TOKEN as a ratio N/D, or NIL when it is not one."
  (let ((slash (position #\/ token)))
    (when slash
      (let ((sign (if (find (char token 0) "+-") 1 0)))
        (when (and (%digits-p token :start sign :end slash)
                   (%digits-p token :start (1+ slash)))
          (when (or (> (- slash sign) (%r-max-number-digits r))
                    (> (- (length token) slash 1) (%r-max-number-digits r)))
            (%unsafe :number-too-long start "more than ~D digits in a ratio part" (%r-max-number-digits r)))
          (let ((n (parse-integer token :end slash))
                (d (parse-integer token :start (1+ slash))))
            (when (zerop d)
              (%unsafe :division-by-zero start "~A" (%clip token)))
            (/ n d)))))))

(defparameter +double-exponent-limit+ 400
  "Beyond a decimal exponent of this size, either way, no double float holds the value, so
the exponent is refused before any arithmetic: 1d99999 would otherwise build a 99999-digit
integer first.")

(defun %parse-float-token (token r start)
  "TOKEN as a float, or NIL when it is not one: an optional sign, digits with a decimal point,
or digits and an exponent, or both. THE EXPONENT MARKER DECIDES THE TYPE, whatever the caller's
*READ-DEFAULT-FLOAT-FORMAT*: E, F and S, and no marker, give a SINGLE-FLOAT; D and L give a
DOUBLE-FLOAT. The value is computed exactly as a rational and then converted, so an exponent
past the type's range is UNSAFE-DATA :NUMBER-OUT-OF-RANGE, never a FLOATING-POINT-OVERFLOW."
  (let* ((i (if (find (char token 0) "+-") 1 0))
         (negative (char= (char token 0) #\-))
         (marker (position-if (lambda (c) (find c "eEfFsSdDlL")) token :start i))
         (mantissa-end (or marker (length token)))
         (dot (position #\. token :start i :end mantissa-end))
         (int-part (subseq token i (or dot mantissa-end)))
         (frac-part (if dot (subseq token (1+ dot) mantissa-end) "")))
    (when (and (or dot marker)
               (or (plusp (length int-part)) (plusp (length frac-part)))
               (every #'digit-char-p int-part) (every #'digit-char-p frac-part))
      (let* ((exponent-text (and marker (subseq token (1+ marker))))
             (exponent-sign (if (and exponent-text (plusp (length exponent-text))
                                     (find (char exponent-text 0) "+-"))
                                1 0)))
        (when (and marker (not (%digits-p exponent-text :start exponent-sign)))
          (return-from %parse-float-token nil))
        (when (> (+ (length int-part) (length frac-part)) (%r-max-number-digits r))
          (%unsafe :number-too-long start "more than ~D digits" (%r-max-number-digits r)))
        (let* ((type (if (and marker (find (char token marker) "dDlL")) 'double-float 'single-float))
               (exponent (if marker
                             (if (> (- (length exponent-text) exponent-sign) 6)
                                 (%unsafe :number-out-of-range start "~A" (%clip token))
                                 (parse-integer exponent-text))
                             0))
               (digits (concatenate 'string int-part frac-part))
               (scale (- exponent (length frac-part))))
          (when (> (abs (+ scale (length digits))) +double-exponent-limit+)
            (%unsafe :number-out-of-range start "~A" (%clip token)))
          (let* ((mantissa (if (plusp (length digits)) (parse-integer digits) 0))
                 (value (* mantissa (expt 10 scale)))
                 (float (handler-case (coerce value type)
                          (arithmetic-error ()
                            (%unsafe :number-out-of-range start "~A" (%clip token))))))
            (when (or (sb-ext:float-infinity-p float) (sb-ext:float-nan-p float))
              (%unsafe :number-out-of-range start "~A" (%clip token)))
            (if negative (- float) float)))))))

(defun %symbol-name-p (name)
  (and (plusp (length name))
       (every #'%constituent-p name)
       (not (every (lambda (c) (char= c #\.)) name))))

(defun %resolve-symbol (token r start)
  "The symbol TOKEN names, looked up and never created. Case is folded to upper case, as the
standard reader does: foo, Foo and FOO all name the symbol whose name is \"FOO\"."
  (let ((colon (position #\: token)))
    (cond
      ((null colon)
       (unless (%symbol-name-p token)
         (%unsafe :syntax start "~S is not a symbol" (%clip token)))
       (let ((name (string-upcase token)))
         (cond ((string= name "NIL") nil)
               ((string= name "T") t)
               ((find name (%r-symbols r) :key #'symbol-name :test #'string=))
               (t (%unsafe :unknown-symbol start "~A is not an allowed symbol" (%clip token))))))
      ((and (zerop colon) (= 1 (count #\: token)) (%symbol-name-p (subseq token 1)))
       (let ((name (string-upcase (subseq token 1))))
         (multiple-value-bind (symbol status) (find-symbol name "KEYWORD")
           (cond (status symbol)
                 ((%r-intern-keywords r) (intern name "KEYWORD"))
                 (t (%unsafe :unknown-symbol start "the keyword ~A does not exist" (%clip token)))))))
      (t (%unsafe :package-prefix start "~A names a package" (%clip token))))))

(defun %token-value (token r start)
  "The datum TOKEN, read from character START, stands for: an integer, a ratio, a float, or a
symbol."
  (let (value)
    (cond ((setf value (%parse-integer-token token r start)) value)
          ((setf value (%parse-ratio-token token r start)) value)
          ((setf value (%parse-float-token token r start)) value)
          (t (%resolve-symbol token r start)))))

(defun %read-atom (r)
  (let* ((start (%r-position r))
         (token (%read-token r)))
    (when (zerop (length token))
      (%refuse-character r (%peek r)))
    (%token-value token r start)))

(defun %read (r)
  "One datum, read with an explicit stack: each frame is (ITEMS . DOT-STATE), where ITEMS is the
list read so far, newest first, and DOT-STATE is NIL, :TAIL after a dot, or :DONE once the tail
is read."
  (let ((stack '()))
    (flet ((finish (value)
             ;; Give VALUE to the innermost open list, or return it when no list is open.
             (if (null stack)
                 (return-from %read value)
                 (let ((frame (first stack)))
                   (ecase (cdr frame)
                     ((nil) (push value (car frame)))
                     (:tail (setf (car frame) (cons value (car frame))
                                  (cdr frame) :done))
                     (:done (%unsafe :syntax (%r-position r) "more than one datum after a dot")))))))
      (loop
        (%skip-whitespace r)
        (let ((c (%peek r)))
          (cond
            ((null c) (%unsafe :end-of-input (%r-position r)
                               (if stack "a list is not closed" "no datum")))
            ((char= c #\()
             (%next r)
             (when (>= (length stack) (%r-max-depth r))
               (%unsafe :too-deep (%r-position r) "nested deeper than ~D" (%r-max-depth r)))
             (push (cons '() nil) stack))
            ((char= c #\))
             (%next r)
             (when (null stack) (%unsafe :syntax (%r-position r) "an unmatched )"))
             (let ((frame (pop stack)))
               (when (eq (cdr frame) :tail)
                 (%unsafe :syntax (%r-position r) "nothing after a dot"))
               (finish (if (eq (cdr frame) :done)
                           (let ((tail (first (car frame))) (items (rest (car frame))))
                             (let ((list tail))
                               (dolist (item items list) (setf list (cons item list)))))
                           (reverse (car frame))))))
            ((char= c #\")
             (%next r)
             (%count-element r)
             (finish (%read-string r)))
            ((and (char= c #\.) stack)
             ;; A lone dot inside a list marks the tail. Any other token starting with a dot,
             ;; such as .5, is an atom.
             (let* ((start (%r-position r))
                    (token (%read-token r)))
               (cond ((string= token ".")
                      (let ((frame (first stack)))
                        (when (or (null (car frame)) (cdr frame))
                          (%unsafe :syntax start "a dot in the wrong place"))
                        (setf (cdr frame) :tail)))
                     (t (%count-element r)
                        (finish (%token-value token r start))))))
            ((%delimiter-p c) (%refuse-character r c))
            (t (%count-element r)
               (finish (%read-atom r)))))))))

(defun read-data (source &key symbols intern-keywords
                              (max-depth *max-depth*) (max-elements *max-elements*)
                              (max-string-length *max-string-length*)
                              (max-number-digits *max-number-digits*) (max-input *max-input*))
  "Read one datum from SOURCE, a string or a character input stream, accepting plain data only.
Returns the datum and the number of characters read. Signals UNSAFE-DATA for anything else.

Accepted: proper and dotted lists; strings, whose only escapes are \\\\ and \\\"; integers;
ratios; floats (see below); T and NIL; keywords that already exist; and the symbols in SYMBOLS,
a list. Nothing is interned unless INTERN-KEYWORDS is true, which allows new keywords, still
bounded by MAX-ELEMENTS. SYMBOL CASE: a symbol or keyword token is folded to upper case, as the
standard reader folds it, so foo and FOO both name the symbol whose name is \"FOO\".

FLOATS: the exponent marker decides the type whatever *READ-DEFAULT-FLOAT-FORMAT* is: E, F and
S, and no marker, give a single float; D and L a double float.

Refused, each with its reason: every # form (#S, #., #+, #-, #P, #A, #n=, #(, #\\ and the rest),
quote, backquote and comma, |escaped| symbols, package prefixes, comments, a symbol that is not
allowed, and input past a limit. The limits are the keyword arguments, defaulting to the
variables of the same names.

For a string, text after the datum other than whitespace is refused; for a stream, the stream
is left just after the datum."
  (let* ((stream (if (stringp source) (make-string-input-stream source) source))
         (r (make-%reader :stream stream :symbols symbols :intern-keywords intern-keywords
                          :max-depth max-depth :max-elements max-elements
                          :max-string-length max-string-length
                          :max-number-digits max-number-digits :max-input max-input))
         (datum (%read r)))
    (when (stringp source)
      (%skip-whitespace r)
      (when (%peek r)
        (%unsafe :syntax (%r-position r) "text after the datum")))
    (values datum (%r-position r))))

;;; --- writing --------------------------------------------------------------------------------

(defun %write-atom (x stream symbols)
  (typecase x
    (null (write-string "NIL" stream))
    ((eql t) (write-string "T" stream))
    (keyword
     (let ((name (symbol-name x)))
       (unless (and (%symbol-name-p name) (string= name (string-upcase name)))
         (%unsafe :unwritable nil "the keyword ~S would not read back" x))
       (write-char #\: stream) (write-string name stream)))
    (symbol
     (let ((name (symbol-name x)))
       (unless (member x symbols)
         (%unsafe :unwritable nil "~A is not an allowed symbol" (%clip name)))
       (unless (and (%symbol-name-p name) (string= name (string-upcase name)))
         (%unsafe :unwritable nil "the symbol ~A would not read back" (%clip name)))
       (write-string name stream)))
    (string
     (write-char #\" stream)
     (loop for c across x
           do (when (find c "\\\"") (write-char #\\ stream))
              (write-char c stream))
     (write-char #\" stream))
    ((or integer ratio)
     (let ((*print-base* 10) (*print-radix* nil)) (prin1 x stream)))
    ((or single-float double-float)
     (when (or (sb-ext:float-infinity-p x) (sb-ext:float-nan-p x))
       (%unsafe :unwritable nil "~A is not finite" x))
     ;; Printed with single float as the default format, so a single float prints with no
     ;; marker or with E, and a double float with D: the markers READ-DATA reads back as the
     ;; same types, whatever the caller's default.
     (let ((*read-default-float-format* 'single-float)) (prin1 x stream)))
    (t (%unsafe :unwritable nil "a ~A is not data" (type-of x)))))

(defun write-data (datum &optional (stream *standard-output*)
                   &key symbols (max-depth *max-depth*) (max-elements *max-elements*)
                     (max-string-length *max-string-length*)
                     (max-number-digits *max-number-digits*))
  "Write DATUM to STREAM so that READ-DATA, given the same SYMBOLS and limits, reads back a datum
EQUAL to it. Signals UNSAFE-DATA :UNWRITABLE, before writing anything, for a datum READ-DATA
would refuse: a struct, a vector or another object that is not data, a symbol not in SYMBOLS or
whose name would not read back as itself, a float that is not finite, and a datum past a
limit, which includes a circular list. Returns DATUM."
  (let ((elements 0))
    (labels ((check (x depth)
               (when (> (incf elements) max-elements)
                 (%unsafe :unwritable nil "more than ~D elements" max-elements))
               (cond ((consp x)
                      (when (> depth max-depth)
                        (%unsafe :unwritable nil "nested deeper than ~D" max-depth))
                      (loop for tail = x then (cdr tail)
                            while (consp tail)
                            do (check (car tail) (1+ depth))
                               (when (> (incf elements) max-elements)
                                 (%unsafe :unwritable nil "more than ~D elements" max-elements))
                            finally (when tail (check tail (1+ depth)))))
                     ((stringp x)
                      (when (> (length x) max-string-length)
                        (%unsafe :unwritable nil "a string longer than ~D" max-string-length)))
                     ((integerp x)
                      (when (> (length (princ-to-string (abs x))) max-number-digits)
                        (%unsafe :unwritable nil "an integer longer than ~D digits" max-number-digits)))
                     ((typep x 'ratio)
                      (when (> (max (length (princ-to-string (abs (numerator x))))
                                    (length (princ-to-string (denominator x))))
                               max-number-digits)
                        (%unsafe :unwritable nil "a ratio part longer than ~D digits" max-number-digits)))
                     (t (%write-atom x (make-broadcast-stream) symbols))))
             (emit (x)
               (cond ((consp x)
                      (write-char #\( stream)
                      (loop for tail = x then (cdr tail)
                            for first = t then nil
                            while (consp tail)
                            do (unless first (write-char #\Space stream))
                               (emit (car tail))
                            finally (when tail
                                      (write-string " . " stream)
                                      (emit tail)))
                      (write-char #\) stream))
                     (t (%write-atom x stream symbols)))))
      ;; The whole datum is checked before a character is written, so a refusal leaves STREAM
      ;; untouched.
      (check datum 1)
      (emit datum)
      datum)))

(defun write-data-to-string (datum &rest keys &key &allow-other-keys)
  "WRITE-DATA to a fresh string, returned."
  (with-output-to-string (s)
    (apply #'write-data datum s keys)))
