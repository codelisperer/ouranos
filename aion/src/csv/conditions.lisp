;;;; conditions.lisp --- CSV error hierarchy.
;;;;
;;;; Error *policy* is the consumer's to choose; Aion supplies the vocabulary.
;;;; v1 signals `csv-parse-error` (with source position) on malformed input.
;;;; Restart-based policies (skip-row / use-value / replace-field) are a planned
;;;; extension -- see docs/csv-design.md; they belong here rather than as flags on
;;;; the reader.

(in-package #:aion/csv)

(define-condition csv-error (error) ()
  (:documentation "Root of the aion/csv condition hierarchy."))

(define-condition csv-parse-error (csv-error)
  ((line    :initarg :line    :initform nil :reader csv-error-line)
   (column  :initarg :column  :initform nil :reader csv-error-column)
   (message :initarg :message :initform "CSV parse error" :reader csv-error-message))
  (:report (lambda (c stream)
             (format stream "~A (line ~A, column ~A)"
                     (csv-error-message c)
                     (or (csv-error-line c) "?")
                     (or (csv-error-column c) "?"))))
  (:documentation "Signalled on malformed CSV input, carrying 1-based source
LINE and COLUMN when known."))
