;;;; parser-tests.lisp --- the HTTP/1.1 parser, mostly its refusals (pre-publication issue 117).
;;;;
;;;; A parser suite that only feeds it valid requests is testing the wrong half. Every
;;;; rejection in the security floor has a case here, and each one names the attack it is
;;;; there to stop rather than only the status code it returns -- a test called
;;;; `content-length-and-transfer-encoding-is-400' says what happens; one that says
;;;; SMUGGLING says why anyone should care if it ever goes red.
;;;;
;;;; The boundary cases are the interesting ones and they cut both ways: duplicate
;;;; Content-Length with the SAME value is legal and must still parse, while duplicate with
;;;; DIFFERENT values is the attack. A suite that only checked the rejection would pass just
;;;; as happily against a parser that refused every duplicate, which would be wrong.

(cl:defpackage #:hyperion/http1/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:h1 #:hyperion/http1))
  (:export #:run-tests))

(in-package #:hyperion/http1/tests)

(def-suite http1 :description "HTTP/1.1 request-head parsing (pre-publication issue 117).")
(in-suite http1)

(defun run-tests ()
  "Run the suite; return T on success (for asdf:test-system)."
  (run! 'http1))

;;; --- building requests without writing control characters by hand ----------
;;;
;;; CRLF is assembled from CODE-CHAR, never from a "\r\n" literal. In Common Lisp a
;;; backslash escapes the next character and nothing more, so "\r\n" is the two characters
;;; `r' and `n' -- which is a real bug this parser had before its first probe, and one no
;;; type checker can catch because both spellings are String.

(defparameter +cr+ (code-char 13))
(defparameter +lf+ (code-char 10))
(defparameter +crlf+ (coerce (list +cr+ +lf+) 'string))

(defun req (&rest lines)
  "LINES joined with CRLF and terminated with a blank line -- a complete request head."
  (format nil "~{~A~A~}~A" (loop for l in lines append (list l +crlf+)) +crlf+))

(defun parse (s) (h1:parse-head s))

(defun rejected-with (status s)
  "Is S rejected with STATUS? Returns the actual status so a failure message can show it."
  (let ((r (parse s)))
    (values (and (h1:head-rejected? r) (= status (h1:head-status r)))
            (h1:head-status r)
            (h1:head-reason r))))

(defmacro is-rejected (status form &optional why)
  "IS-TRUE, not IS: fiveam's IS destructures its argument as (predicate . args) and
evaluates each part to build a failure report, so a bare variable is a compile-time error
-- \"Argument to IS must be a list\". IS-TRUE takes a value."
  `(multiple-value-bind (ok got reason) (rejected-with ,status ,form)
     (declare (ignorable got reason))
     (is-true ok "~@[~A: ~]expected ~D, got ~D (~A)" ,why ,status got reason)))

;;; --- it parses what it should ----------------------------------------------

(test a-plain-request-parses
  (let ((r (parse (req "GET /a?b=1 HTTP/1.1" "Host: example.org" "Accept:  text/html  "))))
    (is (h1:head-complete? r))
    (is (string= "GET" (h1:head-method r)))
    (is (string= "/a?b=1" (h1:head-target r)))
    (is (string= "HTTP/1.1" (h1:head-version r)))
    (is (not (h1:head-has-body? r)))
    (is (= 0 (h1:head-status r)) "a complete parse has no status to send")))

(test header-names-are-lowercased-and-values-trimmed
  ;; Hyperion's env promises a hash table with LOWERCASED string keys, so the parser owes
  ;; that; and OWS around a value is not part of it (RFC 9110 field-value).
  (let ((r (parse (req "GET / HTTP/1.1" "HOST: example.org" "X-Thing:   spaced   "))))
    (is (equal '("host" "example.org" "x-thing" "spaced") (h1:head-headers-flat r)))))

(test a-content-length-body-is-reported-but-not-consumed
  ;; The head parser reports the DECLARED length; the body stays octets in the CL shell.
  (let ((r (parse (req "POST /x HTTP/1.1" "Content-Length: 27"))))
    (is (h1:head-complete? r))
    (is (h1:head-has-body? r))
    (is (= 27 (h1:head-body-length r)))))

(test consumed-points-exactly-at-the-next-byte
  ;; The property pipelining rests on: two requests in one buffer, and the first parse must
  ;; say precisely where the second begins. Off by one here corrupts every later request on
  ;; the connection rather than failing cleanly, which is why it is asserted on bytes.
  (let* ((one (req "GET /first HTTP/1.1" "Host: x"))
         (two (req "GET /second HTTP/1.1" "Host: x"))
         (r (parse (concatenate 'string one two))))
    (is (= (length one) (h1:head-consumed r)))
    (let ((rest (parse (subseq (concatenate 'string one two) (h1:head-consumed r)))))
      (is (h1:head-complete? rest))
      (is (string= "/second" (h1:head-target rest))))))

(test a-partial-head-is-incomplete-not-an-error
  ;; A chunk boundary is not a message boundary. Incomplete must mean "read more", and it
  ;; must not be confused with a rejection -- 0 is not a status anyone can send.
  (let ((r (parse (concatenate 'string "GET / HTTP/1.1" +crlf+ "Host: x"))))
    (is (h1:head-incomplete? r))
    (is (not (h1:head-rejected? r)))
    (is (= 0 (h1:head-status r)))))

(test the-head-is-parsed-once-it-is-whole
  ;; The same bytes, one CRLF later, must complete -- proving Incomplete was about the input
  ;; and not about something the parser could never accept.
  (let ((r (parse (concatenate 'string "GET / HTTP/1.1" +crlf+ "Host: x" +crlf+ +crlf+))))
    (is (h1:head-complete? r))
    (is (string= "/" (h1:head-target r)))))

;;; --- keep-alive, in both directions ---------------------------------------

(test http-1-1-is-persistent-unless-it-says-close
  (is (h1:head-keep-alive? (parse (req "GET / HTTP/1.1" "Host: x"))))
  (is (not (h1:head-keep-alive? (parse (req "GET / HTTP/1.1" "Connection: close"))))))

(test http-1-0-is-not-persistent-unless-it-asks
  (is (not (h1:head-keep-alive? (parse (req "GET / HTTP/1.0" "Host: x")))))
  (is (h1:head-keep-alive? (parse (req "GET / HTTP/1.0" "Connection: keep-alive")))))

(test connection-is-a-comma-list-not-a-substring-search
  ;; `close' has to be found as a TOKEN. A substring search would also fire on a header
  ;; value that merely contains the letters, and would miss nothing here -- so this is the
  ;; test that stops the cheaper implementation from looking correct.
  (is (not (h1:head-keep-alive? (parse (req "GET / HTTP/1.1" "Connection: keep-alive, close")))))
  (is (h1:head-keep-alive? (parse (req "GET / HTTP/1.1" "Connection: enclosure")))
      "a token that merely CONTAINS \"close\" must not close the connection"))

;;; --- request smuggling: the reason this is Coalton -------------------------

(test smuggling-content-length-and-transfer-encoding-together
  ;; The classic desync: two framings that disagree let a proxy and an origin split one byte
  ;; stream into different requests.
  (is-rejected 400 (req "POST / HTTP/1.1" "Content-Length: 5" "Transfer-Encoding: chunked")
               "CL+TE"))

(test smuggling-duplicate-content-length-with-different-values
  (is-rejected 400 (req "POST / HTTP/1.1" "Content-Length: 5" "Content-Length: 6")))

(test duplicate-content-length-with-the-SAME-value-is-legal
  ;; The boundary that keeps the rule above honest.
  (let ((r (parse (req "POST / HTTP/1.1" "Content-Length: 5" "Content-Length: 5"))))
    (is (h1:head-complete? r))
    (is (= 5 (h1:head-body-length r)))))

(test content-length-must-be-plain-digits
  ;; "+5" and "0x5" are read differently by different parsers, which is the same desync one
  ;; layer down. PARSE-INT alone would accept the first.
  ;;
  ;; Note what is NOT in this list: "5 " and " 5". Surrounding whitespace is not part of a
  ;; field value at all -- RFC 9110 requires parsers to exclude OWS before the first and
  ;; after the last non-whitespace octet -- so those ARE 5, and rejecting them would be
  ;; refusing a legal request. They were in this list when it was first written and the
  ;; parser was right and the test was wrong; see OWS-AROUND-A-FIELD-VALUE-IS-NOT-PART-OF-IT.
  ;; Internal whitespace is a different thing entirely and stays rejected.
  (dolist (bad '("+5" "-5" "0x5" "five" "" "5.0" "5 5" "5,5"))
    (is-rejected 400 (req "POST / HTTP/1.1" (format nil "Content-Length: ~A" bad)) bad)))

(test ows-around-a-field-value-is-not-part-of-it
  ;; The rule the case above leans on, pinned in its own right so that neither can drift.
  (dolist (spelling (list "Content-Length: 5"
                          "Content-Length:5"
                          "Content-Length:   5   "
                          (format nil "Content-Length:~A5~A" (code-char 9) (code-char 9))))
    (let ((r (parse (req "POST / HTTP/1.1" spelling))))
      (is-true (h1:head-complete? r) "~S must parse" spelling)
      (is (= 5 (h1:head-body-length r)) "~S must mean 5" spelling))))

(test transfer-encoding-is-refused-loudly-never-ignored
  ;; 501, not "ignore it": silently dropping the header is how a body gets read as a second
  ;; request. Any coding, not only chunked.
  (is-rejected 501 (req "POST / HTTP/1.1" "Transfer-Encoding: chunked"))
  (is-rejected 501 (req "POST / HTTP/1.1" "Transfer-Encoding: gzip")))

(test bare-lf-is-not-a-line-terminator
  ;; Accepting bare LF where a peer requires CRLF is a smuggling desync. The head here IS
  ;; properly terminated -- only the inner line ending is wrong -- so this cannot pass by
  ;; being mistaken for an incomplete read.
  (is-rejected 400 (concatenate 'string "GET / HTTP/1.1" (string +lf+) "Host: x" +crlf+ +crlf+)))

(test obsolete-line-folding-is-refused
  ;; Obsolete since RFC 7230, and a reliable way to hide a header from one parser in a chain
  ;; but not another.
  (is-rejected 400 (req "GET / HTTP/1.1" "Host: x" "    continued")))

;;; --- malformed input -------------------------------------------------------

(test a-field-name-must-be-a-token
  (is-rejected 400 (req "GET / HTTP/1.1" "Ho st: x") "space")
  (is-rejected 400 (req "GET / HTTP/1.1" (format nil "Ho~At: x" (code-char 0))) "NUL")
  (is-rejected 400 (req "GET / HTTP/1.1" ": x") "empty name")
  (is-rejected 400 (req "GET / HTTP/1.1" "Host x") "no colon"))

(test the-request-line-must-have-three-parts
  (is-rejected 400 (req "GET /") "two parts")
  (is-rejected 400 (req "GET / HTTP/1.1 extra") "four parts")
  (is-rejected 400 (req "") "empty request line"))

(test the-method-must-be-a-token
  (is-rejected 400 (req "GE T / HTTP/1.1") "space makes it four parts")
  (is-rejected 400 (req (format nil "G~AT / HTTP/1.1" (code-char 0))) "NUL in method"))

(test the-target-must-not-be-empty-or-hold-control-characters
  (is-rejected 400 (req (format nil "GET /a~Ab HTTP/1.1" (code-char 0))) "NUL in target")
  (is-rejected 400 (req (format nil "GET /a~Ab HTTP/1.1" (code-char 127))) "DEL in target"))

(test only-http-1-0-and-1-1-are-supported
  (is-rejected 505 (req "GET / HTTP/2.0"))
  (is-rejected 505 (req "GET / HTTP/0.9"))
  (is-rejected 505 (req "GET / HTTP/1.2"))
  (is-rejected 505 (req "GET / http/1.1") "the version token is case-sensitive"))

;;; --- resource bounds -------------------------------------------------------

(test an-oversized-head-is-refused-rather-than-buffered
  ;; 431 rather than Incomplete is the whole defence: a peer that never sends the terminator
  ;; would otherwise buy unbounded memory one byte at a time.
  (is-rejected 431 (req "GET / HTTP/1.1"
                        (format nil "X-Big: ~A" (make-string 70000 :initial-element #\a)))))

(test an-unterminated-head-past-the-cap-is-refused-not-incomplete
  ;; The slowloris shape specifically: no CRLFCRLF at all, just bytes.
  (let ((r (parse (concatenate 'string "GET / HTTP/1.1" +crlf+
                               (make-string 70000 :initial-element #\a)))))
    (is (h1:head-rejected? r) "an unterminated oversized head must not stay Incomplete")
    (is (= 431 (h1:head-status r)))))

(test too-many-header-fields-is-refused
  ;; A second bound, because many small fields stay under the octet cap.
  (is-rejected 431 (apply #'req "GET / HTTP/1.1"
                          (loop for i below 101 collect (format nil "X-~D: v" i)))))

(test exactly-the-field-limit-still-parses
  ;; The boundary, so the check is `>' and not `>='.
  (let ((r (parse (apply #'req "GET / HTTP/1.1"
                         (loop for i below 100 collect (format nil "X-~D: v" i))))))
    (is (h1:head-complete? r))))
