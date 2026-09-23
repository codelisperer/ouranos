;;;; encoder-tests.lisp --- the response head, and what it refuses to write (#117, commit 2).
;;;;
;;;; The parser's suite is mostly refusals because a request arrives from a stranger. This
;;;; one is mostly refusals for a different reason: the dangerous values arrive from OUR OWN
;;;; handler, having come from a stranger one layer earlier -- a Location built from a query
;;;; parameter, a cookie echoing a form field. Response splitting is smuggling in the other
;;;; direction, and it is a bug in code we wrote rather than in a message we received.
;;;;
;;;; The framing tests are the other half: Content-Length must be the number of bytes that
;;;; actually follow, never a number a handler asserted. A response whose framing disagrees
;;;; with its body desyncs every request after it on a keep-alive connection, so the failure
;;;; is not "one wrong response" but "the connection quietly starts lying".

(in-package #:hyperion/http1/tests)

(def-suite http1-encoder
  :description "HTTP/1.1 response head encoding and framing (#117)." :in http1)
(in-suite http1-encoder)

(defun enc (status headers body-length keep-alive)
  "HEADERS is a FLAT list -- (\"Name\" \"value\" ...) -- because a Coalton Tuple is not a CL
cons and building one from CL yields a runtime pattern-match failure, not a type error."
  (h1:encode-head-flat status headers body-length keep-alive))

(defun text-of (r) (h1:encode-text r))

(defun has-line (r line)
  "Does the encoded head contain LINE as a whole CRLF-terminated line?"
  (search (concatenate 'string line +crlf+) (text-of r)))

;;; --- it writes what it should ---------------------------------------------

(test a-plain-response-head
  (let ((r (enc 200 (list "Content-Type" "text/html") 12 t)))
    (is-true (h1:encode-ok? r) "~A" (h1:encode-reason r))
    (is-true (search (concatenate 'string "HTTP/1.1 200 OK" +crlf+) (text-of r)))
    (is-true (has-line r "Content-Type: text/html"))
    (is-true (has-line r "Content-Length: 12"))
    (is-true (has-line r "Connection: keep-alive"))))

(test the-head-ends-with-a-blank-line
  ;; Without the terminating CRLFCRLF the client waits forever for more headers. Cheap to
  ;; get wrong by one CRLF and invisible in any test that only searches for substrings.
  (let ((r (enc 204 nil 0 nil)))
    (is-true (h1:encode-ok? r))
    (let ((s (text-of r)))
      (is (string= (concatenate 'string +crlf+ +crlf+)
                   (subseq s (- (length s) 4)))
          "head must end with exactly one blank line"))))

(test connection-follows-the-keep-alive-argument
  (is-true (has-line (enc 200 nil 0 t) "Connection: keep-alive"))
  (is-true (has-line (enc 200 nil 0 nil) "Connection: close")))

(test unknown-statuses-are-served-not-refused
  ;; A reason phrase carries no meaning -- RFC 9110 says a client MUST NOT act on it -- so an
  ;; unrecognised code still gets a correct message rather than a 500.
  (let ((r (enc 418 nil 0 nil)))
    (is-true (h1:encode-ok? r))
    (is-true (search "HTTP/1.1 418 Unknown" (text-of r)))))

;;; --- framing: the number must be the bytes ---------------------------------

(test a-caller-supplied-content-length-is-discarded
  ;; THE framing rule, outbound. A handler that sets Content-Length and then returns a
  ;; different number of bytes would desync every request after it on the connection, so the
  ;; header is written from the measured length and the supplied one never reaches the wire.
  (let ((r (enc 200 (list "Content-Length" "999") 12 t)))
    (is-true (h1:encode-ok? r))
    (is-true (has-line r "Content-Length: 12"))
    (is-false (search "999" (text-of r)) "the asserted length must not appear at all")))

(test transfer-encoding-and-connection-cannot-be-set-by-a-caller
  ;; Same rule: framing headers belong to this layer. A handler adding Transfer-Encoding
  ;; would produce exactly the Content-Length + Transfer-Encoding pair the PARSER rejects as
  ;; a smuggling primitive -- emitting it would be shipping the attack rather than blocking it.
  (let ((r (enc 200 (list "Transfer-Encoding" "chunked"
                          "Connection" "close")
                5 t)))
    (is-true (h1:encode-ok? r))
    (is-false (search "chunked" (text-of r)))
    (is-true (has-line r "Connection: keep-alive")
             "the argument wins over the header the caller supplied")))

(test framing-headers-are-matched-case-insensitively
  ;; `content-length' and `Content-Length' are the same header. Matching only the canonical
  ;; spelling would let the lowercase one through and produce two of them on the wire.
  (let ((r (enc 200 (list "content-length" "999" "CONTENT-LENGTH" "42") 7 nil)))
    (is-true (h1:encode-ok? r))
    (is-true (has-line r "Content-Length: 7"))
    (is-false (search "999" (text-of r)))
    (is-false (search "42" (text-of r)))))

;;; --- response splitting: refuse, never sanitise ---------------------------

(test a-header-value-with-cr-or-lf-is-refused
  ;; The injected value ends the header block early and everything after it is read as more
  ;; headers, or as a second response. Refusing makes it a visible 500 in development;
  ;; stripping would ship something subtly different from what the handler asked for.
  (dolist (evil (list (concatenate 'string "/ok" +crlf+ "X-Injected: yes")
                      (concatenate 'string "/ok" (string +cr+))
                      (concatenate 'string "/ok" (string +lf+))))
    (let ((r (enc 302 (list "Location" evil) 0 nil)))
      (is-false (h1:encode-ok? r) "must refuse ~S" evil)
      (is-true (search "Location" (h1:encode-reason r))
               "the refusal must name the offending header"))))

(test a-header-value-with-nul-is-refused
  (let ((r (enc 200 (list "X-Thing" (concatenate 'string "a" (string (code-char 0)) "b"))
                0 nil)))
    (is-false (h1:encode-ok? r))))

(test a-header-name-that-is-not-a-token-is-refused
  (dolist (bad '("X Thing" "X:Thing" "" "X\"Thing"))
    (is-false (h1:encode-ok? (enc 200 (list bad "v") 0 nil))
              "must refuse the name ~S" bad)))

(test a-refusal-writes-nothing-at-all
  ;; A half-written head is worse than none: the client would consume it and then block. The
  ;; check runs before anything is rendered, and this pins that.
  (let ((r (enc 200 (list "Good" "fine"
                          "Bad" (concatenate 'string "x" +crlf+ "Y: z"))
                0 nil)))
    (is-false (h1:encode-ok? r))
    (is (string= "" (text-of r)) "a refusal must yield no text, not a partial head")))

(test an-out-of-range-status-is-refused
  (dolist (bad '(0 99 600 1000))
    (is-false (h1:encode-ok? (enc bad nil 0 nil)) "must refuse status ~D" bad)))

;;; --- the canned error response --------------------------------------------

(test an-error-response-is-complete-and-self-framed
  ;; It carries its own body, so its Content-Length must match that body exactly -- this is
  ;; the response sent when parsing FAILED, which is precisely when the connection state is
  ;; least understood and a wrong length is least recoverable.
  (let* ((s (h1:encode-error 400))
         (sep (search (concatenate 'string +crlf+ +crlf+) s))
         (body (subseq s (+ sep 4))))
    (is-true (search "HTTP/1.1 400 Bad Request" s))
    (is (string= "400 Bad Request" body))
    (is-true (search (format nil "Content-Length: ~D" (length body)) s)
             "declared length must equal the body actually present")))

(test an-error-response-always-closes-the-connection
  ;; Once a message could not be parsed, where the next one starts is unknown. Reusing the
  ;; connection would be guessing, so every parse failure is terminal for it.
  (dolist (status '(400 431 501 505))
    (is-true (search "Connection: close" (h1:encode-error status))
             "~D must close" status)))

(test an-error-response-never-echoes-what-the-parser-noticed
  ;; The reason is developer-facing and describes what an attacker's probe achieved. It goes
  ;; to the log; the body says only the reason phrase, which the status already implied.
  (let ((s (h1:encode-error 400)))
    (is-false (search "Transfer-Encoding" s))
    (is-false (search "smuggl" s))
    (is-false (search "Content-Length appears" s))))

(test every-status-the-parser-can-return-has-a-reason-phrase
  ;; The two halves must agree: a rejection the parser can produce and the encoder cannot
  ;; name would go out as "Unknown", which is a worse bug report than the status alone.
  (dolist (status '(400 431 501 505 413 500))
    (is-false (string= "Unknown" (h1:reason-phrase status))
              "status ~D is produced by the parser or the server and needs a phrase" status)))

;;; --- interim (1xx) responses (commit 4) ------------------------------------
;;;
;;; A 1xx is the one response that must NOT be framed, which makes it the exact inverse of
;;; everything above and the reason it gets its own function rather than a flag on
;;; ENCODE-HEAD. The failure it prevents is invisible in a single exchange: a Content-Length
;;; on a 100 tells the client to consume that many octets before the next message, so it
;;; eats the real response's head as a body and every subsequent request on the connection
;;; is answered against garbage.

(test interim-100-is-a-status-line-and-nothing-else
  (let ((r (h1:encode-interim 100)))
    (is-true (h1:encode-ok? r) "~A" (h1:encode-reason r))
    (is (string= (concatenate 'string "HTTP/1.1 100 Continue" +crlf+ +crlf+) (text-of r)))))

(test interim-carries-no-framing-headers
  "Not merely absent by accident -- asserted, because adding one later would look harmless."
  (let ((s (text-of (h1:encode-interim 100))))
    (is-false (search "Content-Length" s))
    (is-false (search "Connection" s))
    (is-false (search "Transfer-Encoding" s))))

(test interim-refuses-a-final-status
  "ENCODE-INTERIM must not be a second way to write a real response: one written without
Content-Length would leave the client reading the body until the connection closed."
  (dolist (status '(200 204 301 400 500))
    (is-false (h1:encode-ok? (h1:encode-interim status))
              "must refuse the final status ~D" status))
  (is-true (h1:encode-ok? (h1:encode-interim 103)) "103 Early Hints is a legitimate 1xx"))

(test the-statuses-commit-4-added-have-reason-phrases
  "100 and 417 are emitted by the server now, and a status the encoder cannot name would go
out as `Unknown' -- harmless to a client, and a sign the two files disagree about what this
server answers."
  (is (string= "Continue" (h1:reason-phrase 100)))
  (is (string= "Expectation Failed" (h1:reason-phrase 417))))

;;; --- chunked framing (M2, streaming) --------------------------------------
;;;
;;; ENCODE-HEAD's tests assert that Content-Length is the number of bytes that actually
;;; follow. These assert the same property for a body nobody could count in advance: each
;;; chunk carries its own length, so the invariant moves from once per response to once per
;;; chunk -- more places to be wrong, in a stream that is often long-lived and often carries
;;; values that came from a stranger.
;;;
;;; Two refusals here are not tidiness. A body-forbidden status framed as chunked, and a
;;; zero-length data chunk, both DESYNCHRONISE the connection rather than producing a
;;; malformed response: the client goes on reading, and what it reads next is our bytes
;;; interpreted as a different message.

(defun chunked (status headers keep-alive)
  (h1:encode-head-chunked-flat status headers keep-alive))

(test to-hex-is-minimal-lowercase-and-unpadded
  "Each of those is a smuggling vector rather than a formatting preference: a padded, prefixed
or upper-case size is where two parsers in a chain read one stream differently."
  (is (string= "0"    (coalton:coalton (h1:to-hex 0))))
  (is (string= "f"    (coalton:coalton (h1:to-hex 15))))
  (is (string= "10"   (coalton:coalton (h1:to-hex 16))))
  (is (string= "ff"   (coalton:coalton (h1:to-hex 255))))
  (is (string= "1000" (coalton:coalton (h1:to-hex 4096))))
  (is (string= "2000" (coalton:coalton (h1:to-hex 8192)))
      "a realistic chunk size, not only the boundary values"))

(test a-chunked-head-frames-with-transfer-encoding-and-no-length
  (let ((r (chunked 200 (list "Content-Type" "text/event-stream") t)))
    (is-true (h1:encode-ok? r) "~A" (h1:encode-reason r))
    (is-true (search (concatenate 'string "HTTP/1.1 200 OK" +crlf+) (text-of r)))
    (is-true (has-line r "Content-Type: text/event-stream"))
    (is-true (has-line r "Transfer-Encoding: chunked"))
    (is-true (has-line r "Connection: keep-alive"))
    (is-false (search "Content-Length" (text-of r))
              "a length beside chunked framing is two framings that disagree")))

(test a-caller-supplied-content-length-is-dropped-from-a-chunked-head
  "The dangerous case, and the reason FRAMING-HEADER? is shared with ENCODE-HEAD: a handler
that streams while also setting a length would put both framings on the wire, which is
precisely the disagreement a smuggling chain needs."
  (let ((r (chunked 200 (list "Content-Length" "42" "Transfer-Encoding" "gzip") t)))
    (is-true (h1:encode-ok? r) "~A" (h1:encode-reason r))
    (is-false (search "Content-Length" (text-of r)))
    (is-false (search "gzip" (text-of r)))
    (is-true (has-line r "Transfer-Encoding: chunked"))))

(test a-chunked-head-refuses-a-status-that-cannot-carry-a-body
  "1xx, 204 and 304 have no body BY DEFINITION, so the client reads the next message
immediately -- and finds our terminating chunk, parsed as a status line. Every response
after it on that connection is off by one."
  (dolist (status '(100 101 103 204 304))
    (is-false (h1:encode-ok? (chunked status nil t))
              "must refuse to chunk ~D" status))
  (is-true (h1:encode-ok? (chunked 200 nil t)))
  (is-true (h1:encode-ok? (chunked 500 nil nil))
      "a status that MAY have a body is still chunkable, including an error"))

(test a-chunked-head-refuses-what-encode-head-refuses
  "Response splitting does not become safe because the body is streamed. Same check, and
asserted here rather than assumed from the shared helper -- a future refactor could give
this path its own."
  (is-false (h1:encode-ok? (chunked 200 (list "X-Note" (format nil "a~Cb" +cr+)) t)))
  (is-false (h1:encode-ok? (chunked 200 (list "Bad Name" "v") t)))
  (is-false (h1:encode-ok? (chunked 200 (list "odd") t))
            "an odd-length flat list would silently drop the value of a header"))

(test a-chunk-header-is-the-hex-length-and-nothing-else
  (let ((r (h1:encode-chunk-header 5)))
    (is-true (h1:encode-ok? r) "~A" (h1:encode-reason r))
    (is (string= (concatenate 'string "5" +crlf+) (text-of r))))
  (is (string= (concatenate 'string "400" +crlf+) (text-of (h1:encode-chunk-header 1024)))))

(test a-zero-length-chunk-is-refused-because-it-would-end-the-message
  "THE ONE THAT WOULD BE FOUND IN PRODUCTION. A handler yielding an empty string is ordinary;
writing it as a chunk ends the response while the server believes it is still streaming, and
everything after it is read as the next response -- response smuggling with the server
supplying both halves. Ending the message is LAST-CHUNK, which says so by name."
  (is-false (h1:encode-ok? (h1:encode-chunk-header 0)))
  (is-true (search "terminator" (h1:encode-reason (h1:encode-chunk-header 0)))
           "and the refusal says why, since the caller has to choose LAST-CHUNK instead"))

(test the-last-chunk-terminates-the-message
  "Its absence is not a missing byte, it is a hung client: the peer waits for a chunk that
never comes. Asserted exactly, including the empty trailer section -- a single CRLF here
would leave the message unterminated in a way no single response reveals."
  (is (string= (concatenate 'string "0" +crlf+ +crlf+)
               (coalton:coalton h1:last-chunk))))
