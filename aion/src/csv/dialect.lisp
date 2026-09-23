;;;; dialect.lisp --- CSV dialect: policy as an immutable value.
;;;;
;;;; Every format difference (delimiter, quoting, escaping, line ending, comments,
;;;; trimming) is captured in one immutable DIALECT value. Nothing else in the
;;;; parser or writer branches on "which flavour of CSV" -- they read the dialect.
;;;; This is the neutral policy object all backends share: the portable DFA, and
;;;; later sb-simd / zsv / duckdb, must interpret a dialect identically (that is
;;;; what the conformance suite pins down).

(in-package #:aion/csv)

(defstruct (dialect (:constructor make-dialect) (:copier copy-dialect))
  "An immutable description of a CSV flavour.

READ-relevant slots:
  DELIMITER        field separator (default #\\,)
  QUOTE            quote character, or NIL to disable quoting (default #\\\")
  ESCAPE           escape character; NIL means RFC-4180 quote-doubling (default NIL)
  COMMENT          if non-NIL, lines beginning with this char are skipped
  TRIM             trim spaces/tabs around *unquoted* fields
  SKIP-BLANK-LINES drop wholly empty lines instead of yielding #(\"\")

WRITE-relevant slots:
  NEWLINE          record terminator: :CRLF (default), :LF, or :CR
  QUOTING          :MINIMAL (quote only when needed, default), :ALL, or :NONE"
  (delimiter        #\,     :type character)
  (quote            #\"     :type (or null character))
  (escape           nil     :type (or null character))
  (comment          nil     :type (or null character))
  (trim             nil     :type boolean)
  (skip-blank-lines nil     :type boolean)
  (newline          :crlf   :type (member :crlf :lf :cr))
  (quoting          :minimal :type (member :minimal :all :none)))

(defun dialect-with (base &rest overrides
                     &key delimiter quote escape comment trim skip-blank-lines
                          newline quoting)
  "Return a copy of BASE with the given slots overridden. Keeps dialects as
values you derive rather than mutate, e.g. (dialect-with +tsv+ :comment #\\#)."
  (declare (ignore delimiter quote escape comment trim skip-blank-lines
                   newline quoting))
  (let ((d (copy-dialect base)))
    (loop for (key val) on overrides by #'cddr do
      (ecase key
        (:delimiter        (setf (dialect-delimiter d) val))
        (:quote            (setf (dialect-quote d) val))
        (:escape           (setf (dialect-escape d) val))
        (:comment          (setf (dialect-comment d) val))
        (:trim             (setf (dialect-trim d) val))
        (:skip-blank-lines (setf (dialect-skip-blank-lines d) val))
        (:newline          (setf (dialect-newline d) val))
        (:quoting          (setf (dialect-quoting d) val))))
    d))

(defparameter +rfc4180+
  (make-dialect :delimiter #\, :quote #\" :newline :crlf)
  "RFC 4180: comma-separated, double-quoted, quote-doubling, CRLF terminator.")

(defparameter +excel+
  (make-dialect :delimiter #\, :quote #\" :newline :crlf)
  "Excel's dialect -- effectively RFC 4180.")

(defparameter +unix+
  (make-dialect :delimiter #\, :quote #\" :newline :lf)
  "RFC 4180 with a bare LF terminator (Unix line endings).")

(defparameter +tsv+
  (make-dialect :delimiter #\Tab :quote #\" :newline :lf)
  "Tab-separated values, LF terminator.")

(defparameter +pipe+
  (make-dialect :delimiter #\| :quote #\" :newline :lf)
  "Pipe-delimited, LF terminator.")
