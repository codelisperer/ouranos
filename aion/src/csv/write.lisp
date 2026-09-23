;;;; write.lisp --- CSV writer (the inverse of the DFA).
;;;;
;;;; Quoting is a dialect policy: :MINIMAL quotes only fields that need it, :ALL
;;;; quotes every field, :NONE never quotes (caller's responsibility). Embedded
;;;; quotes are escaped by RFC-4180 doubling. Non-string fields are rendered with
;;;; PRINC-TO-STRING, so a row may hold numbers, symbols, etc.
;;;;
;;;; Conversion to other formats is just a different sink over the same row stream
;;;; (fold-rows + a JSON/EDN/Arrow writer); this file provides the CSV sink.

(in-package #:aion/csv)

(declaim (inline field->string))
(defun field->string (field)
  "Coerce a field cell to a string: strings pass through, everything else via
PRINC-TO-STRING."
  (if (stringp field) field (princ-to-string field)))

(defun needs-quoting-p (field dialect)
  "True if FIELD must be quoted under DIALECT: it contains the delimiter, the
quote char, or a line break. (NIL when the dialect has no quote character.)"
  (let ((q (dialect-quote dialect))
        (delim (dialect-delimiter dialect)))
    (and q
         (or (find delim field)
             (find q field)
             (find #\Newline field)
             (find #\Return field))
         t)))

(defun render-field (field dialect stream)
  "Write one already-stringified FIELD to STREAM, quoting/escaping per DIALECT."
  (let ((q (dialect-quote dialect))
        (quoting (dialect-quoting dialect)))
    (if (and q (or (eq quoting :all)
                   (and (eq quoting :minimal) (needs-quoting-p field dialect))))
        (progn
          (write-char q stream)
          (loop for c across field do
            (when (eql c q) (write-char q stream)) ; double embedded quotes
            (write-char c stream))
          (write-char q stream))
        (write-string field stream))))

(defun %newline-string (dialect)
  (ecase (dialect-newline dialect)
    (:lf   (string #\Newline))
    (:cr   (string #\Return))
    (:crlf (coerce (list #\Return #\Newline) 'string))))

(defun write-row (row stream &key (dialect +rfc4180+))
  "Write ROW (a list or vector of field cells) to STREAM as one CSV record,
terminated per DIALECT. Returns ROW."
  (let ((delim (dialect-delimiter dialect))
        (first t))
    (map nil (lambda (cell)
               (if first (setf first nil) (write-char delim stream))
               (render-field (field->string cell) dialect stream))
         row)
    (write-string (%newline-string dialect) stream))
  row)

(defun write-rows (rows stream &key (dialect +rfc4180+))
  "Write each row in ROWS (a list or vector of rows) to STREAM. Returns NIL."
  (map nil (lambda (row) (write-row row stream :dialect dialect)) rows))

(defun render-string (rows &key (dialect +rfc4180+))
  "Render ROWS to a CSV string."
  (with-output-to-string (s)
    (write-rows rows s :dialect dialect)))

(defun write-file (path rows &key (dialect +rfc4180+) (external-format :default)
                                  (if-exists :supersede))
  "Write ROWS as a CSV file at PATH. Returns PATH."
  (with-open-file (s path :direction :output
                          :element-type 'character
                          :external-format external-format
                          :if-exists if-exists
                          :if-does-not-exist :create)
    (write-rows rows s :dialect dialect))
  path)
