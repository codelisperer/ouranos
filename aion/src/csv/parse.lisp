;;;; parse.lisp --- the portable backend: a scalar-DFA CSV reader.
;;;;
;;;; A small, correct finite-state machine over a character stream. Not the fast
;;;; path -- byte-level SIMD (sb-simd) and embedded engines (zsv, duckdb) are the
;;;; throughput backends (docs/csv-design.md). This is the reference: dependency-
;;;; free, RFC-4180-faithful, and the oracle the fast backends are tested against.
;;;;
;;;; The reader yields rows as SIMPLE-VECTORs of field strings. Field and row
;;;; buffers are reused across records; each row is a fresh copy, so callers may
;;;; retain it. Higher-level entry points build on one primitive, READ-ROW:
;;;;   read-row  -- pull one record
;;;;   map-rows / do-rows -- iterate for effect
;;;;   fold-rows -- reduce with early-termination (the aion/xform seam)
;;;;   read-all / parse-string / read-file -- materialize

(in-package #:aion/csv)

(defstruct (reader (:constructor %make-reader) (:copier nil))
  "Stateful pull-parser over a character STREAM under DIALECT. Tracks 1-based
source position (LINE/COLUMN) for error reporting. FIELD and FIELDS are reused
scratch buffers -- do not touch them."
  (stream  nil :read-only t)
  (dialect +rfc4180+ :type dialect :read-only t)
  (line    1 :type fixnum)
  (column  0 :type fixnum)
  (field   (make-array 32 :element-type 'character :adjustable t :fill-pointer 0))
  (fields  (make-array 16 :adjustable t :fill-pointer 0)))

(defun make-reader (stream &key (dialect +rfc4180+))
  "Wrap character STREAM in a CSV READER using DIALECT."
  (%make-reader :stream stream :dialect dialect))

(defun read-row (reader)
  "Read one CSV record from READER.

Returns (values ROW PRESENT-P): ROW is a SIMPLE-VECTOR of field strings, and
PRESENT-P is NIL at end of input (ROW is then NIL). Signals CSV-PARSE-ERROR on
malformed input (e.g. an unterminated quoted field)."
  (let* ((stream     (reader-stream reader))
         (d          (reader-dialect reader))
         (delim      (dialect-delimiter d))
         (q          (dialect-quote d))
         (esc        (dialect-escape d))
         (comment    (dialect-comment d))
         (trim       (dialect-trim d))
         (skip-blank (dialect-skip-blank-lines d))
         (buf        (reader-field reader))
         (fields     (reader-fields reader))
         (state      :start)
         (field-quoted nil)
         (seen         nil))
    (setf (fill-pointer buf) 0
          (fill-pointer fields) 0)
    (labels ((getc ()
               (let ((c (read-char stream nil :eof)))
                 (unless (eq c :eof) (incf (reader-column reader)))
                 c))
             (add (c) (vector-push-extend c buf))
             (bump-line () (incf (reader-line reader)) (setf (reader-column reader) 0))
             (maybe-lf ()
               (when (eql (peek-char nil stream nil :eof) #\Newline)
                 (read-char stream nil nil)))
             (emit-field ()
               (let ((s (subseq buf 0 (fill-pointer buf))))
                 (when (and trim (not field-quoted))
                   (setf s (string-trim '(#\Space #\Tab) s)))
                 (vector-push-extend s fields))
               (setf (fill-pointer buf) 0 field-quoted nil))
             (skip-line ()
               (loop for c = (read-char stream nil :eof)
                     until (or (eq c :eof) (eql c #\Newline) (eql c #\Return))
                     finally (when (eql c #\Return) (maybe-lf))
                             (unless (eq c :eof) (bump-line))))
             (finish ()
               (emit-field)
               (return-from read-row (values (coerce fields 'simple-vector) t)))
             (parse-error (msg)
               (error 'csv-parse-error :line (reader-line reader)
                                       :column (reader-column reader)
                                       :message msg)))
      (loop
        (let ((c (getc)))
          (ecase state
            (:start
             ;; Start of a field. When nothing has been SEEN yet this is also the
             ;; start of a record -- where comments and blank-line skipping apply.
             (cond
               ((eq c :eof) (if seen (finish) (return-from read-row (values nil nil))))
               ((and comment (not seen) (eql c comment)) (skip-line))
               ((and q (eql c q)) (setf seen t field-quoted t state :quoted))
               ((eql c delim) (setf seen t) (emit-field))
               ((eql c #\Newline)
                (if (and skip-blank (not seen)) (bump-line)
                    (progn (bump-line) (finish))))
               ((eql c #\Return)
                (maybe-lf)
                (if (and skip-blank (not seen)) (bump-line)
                    (progn (bump-line) (finish))))
               (t (setf seen t state :unquoted) (add c))))
            (:unquoted
             (cond
               ((eq c :eof) (finish))
               ((and esc (eql c esc)) (let ((n (getc))) (unless (eq n :eof) (add n))))
               ((eql c delim) (emit-field) (setf state :start))
               ((eql c #\Newline) (bump-line) (finish))
               ((eql c #\Return) (maybe-lf) (bump-line) (finish))
               (t (add c))))
            (:quoted
             (cond
               ((eq c :eof) (parse-error "Unterminated quoted field"))
               ((and esc (eql c esc))
                (let ((n (getc)))
                  (if (eq n :eof) (parse-error "Unterminated escape in quoted field")
                      (add n))))
               ((eql c q) (setf state :quote-end))
               ((eql c #\Newline) (bump-line) (add c))
               (t (add c))))
            (:quote-end
             ;; Just consumed a closing quote inside a quoted field.
             (cond
               ((eq c :eof) (finish))
               ((and q (eql c q)) (add q) (setf state :quoted)) ; doubled -> literal quote
               ((eql c delim) (emit-field) (setf state :start))
               ((eql c #\Newline) (bump-line) (finish))
               ((eql c #\Return) (maybe-lf) (bump-line) (finish))
               ;; Lenient: text after a closing quote continues the field unquoted.
               (t (add c) (setf state :unquoted))))))))))

(defun map-rows (fn reader)
  "Call FN on each row (a SIMPLE-VECTOR) from READER, for effect. Returns NIL."
  (loop (multiple-value-bind (row present) (read-row reader)
          (unless present (return))
          (funcall fn row))))

(defmacro do-rows ((row reader &optional result) &body body)
  "Iterate ROW over the records of READER, evaluating BODY for effect. Returns
RESULT (default NIL). A LOOP/RETURN escape hatch for the reducing-style FOLD-ROWS."
  (let ((rd (gensym "READER")) (present (gensym "PRESENT")))
    `(let ((,rd ,reader))
       (loop (multiple-value-bind (,row ,present) (read-row ,rd)
               (unless ,present (return ,result))
               ,@body)))))

(defun fold-rows (fn seed reader)
  "Reduce over the rows of READER. FN is a reducing function (acc row) -> acc.
Wrap a return value in REDUCED to stop early. This is the seam aion/xform's
`transduce` will plug into -- rows are a reducible source."
  (let ((acc seed))
    (do-rows (row reader acc)
      (setf acc (funcall fn acc row))
      (when (reduced-p acc) (return (unreduce acc))))))

(defun read-all (reader)
  "Read every remaining record from READER into a fresh list of rows."
  (let ((rows '()))
    (map-rows (lambda (r) (push r rows)) reader)
    (nreverse rows)))

(defun parse-string (string &key (dialect +rfc4180+))
  "Parse CSV text STRING into a list of rows."
  (with-input-from-string (s string)
    (read-all (make-reader s :dialect dialect))))

(defun call-with-input (source fn &key (dialect +rfc4180+) (external-format :default))
  "Call FN with a READER over SOURCE. SOURCE is an open character STREAM (used
as-is) or a pathname/namestring (opened for the duration, then closed)."
  (etypecase source
    (stream (funcall fn (make-reader source :dialect dialect)))
    ((or pathname string)
     (with-open-file (s source :direction :input
                               :element-type 'character
                               :external-format external-format)
       (funcall fn (make-reader s :dialect dialect))))))

(defmacro with-input ((reader source &rest opts) &body body)
  "Bind READER to a CSV reader over SOURCE (stream or path) for the extent of
BODY, closing the file afterward if one was opened. OPTS: :dialect, :external-format."
  `(call-with-input ,source (lambda (,reader) ,@body) ,@opts))

(defun read-file (path &key (dialect +rfc4180+) (external-format :default))
  "Read the CSV file at PATH into a list of rows."
  (call-with-input (pathname path) #'read-all
                   :dialect dialect :external-format external-format))
