;;;; chunked-tests.lisp --- chunked request bodies, a step at a time (#374).
;;;;
;;;; The three steps the shell calls, each fed the view it would be given. As in
;;;; parser-tests.lisp, the refusals are the point, and each says what it stops: a chunk-size
;;;; two parsers could read differently, a line that hides a control character, and a chunk
;;;; whose data is not the length its size said.

(in-package #:hyperion/http1/tests)
(in-suite http1)

(defun crlf-join (&rest parts)
  "PARTS concatenated, each followed by CRLF."
  (format nil "~{~A~A~}" (loop for p in parts append (list p +crlf+))))

(defun size-line (view) (h1:parse-chunk-size-line view))

;; The parser's limits, read in Coalton's environment: a Coalton value DEFINE is not a CL
;; variable (see %MAX-HEAD-OCTETS in server-uv.lisp).
(defun max-head () (coalton:coalton h1:max-head-octets))
(defun max-fields () (coalton:coalton h1:max-header-fields))
(defun max-chunk-line () (coalton:coalton h1:max-chunk-line-octets))

(defmacro is-step (form &key ok incomplete rejected value consumed why)
  "FORM's step is Step-Ok with VALUE and CONSUMED, Step-Incomplete, or Step-Rejected with the
status REJECTED."
  (let ((r (gensym "R")))
    `(let ((,r ,form))
       ,@(cond
           (ok `((is-true (h1:step-ok? ,r) "~@[~A: ~]~S: expected Step-Ok, got ~S ~S" ,why ',form
                          (h1:step-status ,r) (h1:step-reason ,r))
                 ,@(when value `((is (= ,value (h1:step-value ,r)))))
                 ,@(when consumed `((is (= ,consumed (h1:step-consumed ,r)))))))
           (incomplete `((is-true (h1:step-incomplete? ,r) "~@[~A: ~]~S: expected Step-Incomplete" ,why ',form)))
           (rejected `((is-true (and (h1:step-rejected? ,r) (= ,rejected (h1:step-status ,r)))
                                "~@[~A: ~]~S: expected ~D, got ~D (~A)" ,why ',form ,rejected
                                (h1:step-status ,r) (h1:step-reason ,r))))))))

;;; --- the chunk-size line --------------------------------------------------

(test a-chunk-size-is-hexadecimal
  (is-step (size-line (crlf-join "1a")) :ok t :value 26 :consumed 4)
  (is-step (size-line (crlf-join "1A")) :ok t :value 26)
  (is-step (size-line (crlf-join "000A")) :ok t :value 10 :consumed 6)
  (is-step (size-line (crlf-join "0")) :ok t :value 0 :consumed 3)
  (is-step (size-line (concatenate 'string (crlf-join "5") "hello")) :ok t :value 5 :consumed 3
           :why "only the line is consumed, not the data after it"))

(test a-chunk-size-that-two-parsers-could-read-differently-is-refused
  ;; Each of these has been parsed as a size by one implementation and refused by another,
  ;; which is how one body is split into two requests.
  (dolist (bad '("" "0x1a" "+1a" "-1" " 1a" "g" "1 a"))
    (is-step (size-line (crlf-join bad)) :rejected 400)))

(test a-chunk-size-with-too-many-digits-is-refused
  ;; Sixteen hex digits cannot be a UFix; a parser that wrapped it would read another size.
  (is-step (size-line (crlf-join (make-string 15 :initial-element #\f))) :ok t
           :value (1- (expt 2 60)))
  (is-step (size-line (crlf-join (make-string 16 :initial-element #\f))) :rejected 400)
  (is-step (size-line (crlf-join (make-string 16 :initial-element #\0))) :rejected 400 :why "leading zeros count, so the rule is about the text, not the value"))

(test chunk-extensions-are-accepted-and-must-be-clean
  (is-step (size-line (crlf-join "5;name=value")) :ok t :value 5 :consumed 14)
  (is-step (size-line (crlf-join "5 ; name")) :ok t :value 5)
  (is-step (size-line (crlf-join (format nil "5~C;x" (code-char 9)))) :ok t :value 5)
  (is-step (size-line (crlf-join "5 name")) :rejected 400 :why "text after the size must start with ;")
  (is-step (size-line (crlf-join (format nil "5;a~Cb" (code-char 0)))) :rejected 400 :why "no control character in an extension")
  (is-step (size-line (crlf-join (format nil "5;a~Cb" (code-char 127)))) :rejected 400))

(test a-chunk-size-line-ends-in-crlf-only
  (is-step (size-line (format nil "5~Ahello" +lf+)) :incomplete t)
  (is-step (size-line (format nil "5~A~A" +lf+ +crlf+)) :rejected 400 :why "a bare LF inside the line is refused once the line ends")
  (is-step (size-line (format nil "5~Ax~A" +cr+ +crlf+)) :rejected 400))

(test an-unfinished-chunk-size-line-is-incomplete-until-the-limit
  (is-step (size-line "") :incomplete t)
  (is-step (size-line "1a") :incomplete t)
  (is-step (size-line (format nil "1a~A" +cr+)) :incomplete t)
  (let ((limit (max-chunk-line)))
    (is-step (size-line (concatenate 'string "5;" (make-string (- limit 2) :initial-element #\a)))
             :incomplete t)
    (is-step (size-line (concatenate 'string "5;" (make-string (- limit 1) :initial-element #\a)))
             :rejected 400 :why "past the limit without a CRLF, the line is refused, not buffered")
    (is-step (size-line (crlf-join (concatenate 'string "5;" (make-string (- limit 1) :initial-element #\a))))
             :rejected 400 :why "a complete line over the limit is refused too")))

;;; --- the CRLF after a chunk's data ----------------------------------------

(test chunk-data-must-be-followed-by-crlf
  ;; Anything else means the chunk-size did not describe the data.
  (is-step (h1:parse-chunk-data-end (crlf-join "")) :ok t :consumed 2)
  (is-step (h1:parse-chunk-data-end (concatenate 'string +crlf+ "0")) :ok t :consumed 2)
  (is-step (h1:parse-chunk-data-end "") :incomplete t)
  (is-step (h1:parse-chunk-data-end (string +cr+)) :incomplete t)
  (is-step (h1:parse-chunk-data-end "x") :rejected 400)
  (is-step (h1:parse-chunk-data-end (string +lf+)) :rejected 400 :why "a bare LF is not CRLF")
  (is-step (h1:parse-chunk-data-end (format nil "~Ax" +cr+)) :rejected 400))

;;; --- the trailer section --------------------------------------------------

(test an-empty-trailer-section-is-one-crlf
  (is-step (h1:parse-trailers +crlf+ (max-head)) :ok t :consumed 2)
  (is-step (h1:parse-trailers (concatenate 'string +crlf+ "GET / HTTP/1.1") (max-head))
           :ok t :consumed 2 :why "a pipelined request after the body is not the trailer's"))

(test trailer-fields-are-checked-like-header-fields
  (is-step (h1:parse-trailers (concatenate 'string (crlf-join "X-Checksum: abc" "X-B: 1") +crlf+)
                              (max-head))
           :ok t :consumed 27)
  (is-step (h1:parse-trailers (concatenate 'string (crlf-join "Bad Name: x") +crlf+) (max-head))
           :rejected 400)
  (is-step (h1:parse-trailers (concatenate 'string (crlf-join "X: a" " folded") +crlf+) (max-head))
           :rejected 400 :why "no obs-fold in a trailer either"))

(test a-trailer-section-is-bounded
  (is-step (h1:parse-trailers (crlf-join "X-A: 1") (max-head)) :incomplete t)
  (is-step (h1:parse-trailers (make-string 101 :initial-element #\a) 100) :rejected 431 :why "unterminated past the limit is refused, not buffered")
  (is-step (h1:parse-trailers
            (concatenate 'string
                         (apply #'crlf-join (loop for i below (1+ (max-fields))
                                                  collect (format nil "X-~D: v" i)))
                         +crlf+)
            (max-head))
           :rejected 431))
