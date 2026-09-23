;;;; csv.lisp --- conformance tests for aion/csv (the portable backend).
;;;;
;;;; These pin the reference semantics every faster backend must match: RFC 4180
;;;; basics, quoting/escaping edge cases, dialect variants, and reader<->writer
;;;; round-tripping. Run: (asdf:test-system :aion/csv).

(defpackage #:aion/csv/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:csv #:aion/csv))
  (:export #:run-tests #:csv))

(in-package #:aion/csv/tests)

(def-suite csv :description "aion/csv portable-backend conformance.")
(in-suite csv)

(defun rows (string &rest dialect-args)
  "Parse STRING and return its rows as a list of lists (for easy EQUAL checks)."
  (mapcar (lambda (v) (coerce v 'list))
          (apply #'csv:parse-string string dialect-args)))

;;; --- reading: RFC 4180 basics ------------------------------------------------

(test simple-fields
  (is (equal '(("a" "b" "c")) (rows "a,b,c"))))

(test multiple-records
  (is (equal '(("a" "b") ("c" "d")) (rows (format nil "a,b~%c,d")))))

(test empty-fields
  (is (equal '(("" "" "")) (rows ",,")))
  (is (equal '(("a" "")) (rows "a,")))
  (is (equal '(("" "b")) (rows ",b"))))

(test trailing-newline-no-extra-row
  (is (equal '(("a" "b")) (rows (format nil "a,b~%")))))

(test crlf-terminator
  (is (equal '(("a" "b") ("c" "d"))
             (rows (concatenate 'string "a,b" '(#\Return #\Newline) "c,d")))))

;;; --- reading: quoting --------------------------------------------------------

(test quoted-delimiter
  (is (equal '(("a,b" "c")) (rows "\"a,b\",c"))))

(test doubled-quote-is-literal
  (is (equal '(("she said \"hi\"" "x")) (rows "\"she said \"\"hi\"\"\",x"))))

(test embedded-newline-in-quotes
  (is (equal '((#.(format nil "line1~%line2") "b"))
             (rows "\"line1
line2\",b"))))

(test quoted-empty-field
  (is (equal '(("" "a")) (rows "\"\",a"))))

(test unterminated-quote-signals
  (signals csv:csv-parse-error (csv:parse-string "\"oops,no close")))

;;; --- reading: dialects & options --------------------------------------------

(test tsv-dialect
  (is (equal '(("a" "b" "c")) (rows (format nil "a~Cb~Cc" #\Tab #\Tab)
                                    :dialect csv:+tsv+))))

(test comment-lines-skipped
  (let ((d (csv:dialect-with csv:+unix+ :comment #\#)))
    (is (equal '(("a" "b"))
               (rows (format nil "# a header comment~%a,b") :dialect d)))))

(test skip-blank-lines
  (let ((d (csv:dialect-with csv:+unix+ :skip-blank-lines t)))
    (is (equal '(("a") ("b"))
               (rows (format nil "a~%~%b") :dialect d)))))

(test blank-line-is-single-empty-field-by-default
  (is (equal '(("a") ("") ("b")) (rows (format nil "a~%~%b")))))

(test trim-unquoted-only
  (let ((d (csv:dialect-with csv:+unix+ :trim t)))
    ;; unquoted trimmed, quoted preserved
    (is (equal '(("a" "b c")) (rows "  a  ,\"b c\"" :dialect d)))))

(test escape-char-dialect
  (let ((d (csv:dialect-with csv:+unix+ :escape #\\)))
    (is (equal '(("a,b" "c")) (rows "a\\,b,c" :dialect d)))))

;;; --- writing -----------------------------------------------------------------

(test write-minimal-quoting
  (is (string= "a,\"b,c\",d"
               (string-right-trim '(#\Return #\Newline)
                                  (csv:render-string '(("a" "b,c" "d"))
                                                     :dialect csv:+unix+)))))

(test write-quote-all
  (let ((d (csv:dialect-with csv:+unix+ :quoting :all)))
    (is (string= "\"a\",\"b\""
                 (string-right-trim '(#\Return #\Newline)
                                    (csv:render-string '(("a" "b")) :dialect d))))))

(test write-non-string-cells
  (is (string= "1,2.5,X" ; (princ-to-string :x) upcases the symbol name
               (string-right-trim '(#\Return #\Newline)
                                  (csv:render-string '((1 2.5 :x)) :dialect csv:+unix+)))))

;;; --- round-trip (the key conformance property) -------------------------------

(test round-trip
  (let* ((data '(("id" "note")
                 ("1" "plain")
                 ("2" "has, comma")
                 ("3" #.(format nil "has~%newline"))
                 ("4" "has \"quotes\"")))
         (text (csv:render-string data :dialect csv:+unix+)))
    (is (equal data (mapcar (lambda (v) (coerce v 'list))
                            (csv:parse-string text :dialect csv:+unix+))))))

;;; --- reducible seam (foreshadows aion/xform) --------------------------------

(test fold-rows-counts
  (with-input-from-string (s (format nil "a,b~%c,d~%e,f"))
    (let ((r (csv:make-reader s :dialect csv:+unix+)))
      (is (= 3 (csv:fold-rows (lambda (n row) (declare (ignore row)) (1+ n)) 0 r))))))

(test fold-rows-early-termination
  (with-input-from-string (s (format nil "1~%2~%3~%4"))
    (let ((r (csv:make-reader s :dialect csv:+unix+)))
      ;; stop after collecting two rows
      (is (= 2 (length
                (csv:fold-rows
                 (lambda (acc row)
                   (let ((acc (cons row acc)))
                     (if (>= (length acc) 2) (csv:reduced acc) acc)))
                 '() r)))))))

(defun run-tests ()
  (run! 'csv))
