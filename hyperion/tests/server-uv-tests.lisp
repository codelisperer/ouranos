;;;; server-uv-tests.lisp --- the native libuv HTTP server, over a real socket (pre-publication issue 117).
;;;;
;;;; EVERY CHECK HERE GOES THROUGH A TCP SOCKET, on purpose. An in-image call to the handler
;;;; would prove the handler works and nothing about the server: framing, the head the peer
;;;; actually receives, what happens when a request arrives in two pieces, and whether a
;;;; failure produces a response at all are all invisible from inside. This suite is the
;;;; first consumer of hyperion/server-uv, and AGENTS.md is explicit that an exported
;;;; surface without one is how pre-publication issue 177 and pre-publication issue 202 shipped uncovered.
;;;;
;;;; SO THE HANG CASES ARE THE POINT. The file header of server-uv.lisp argues that a
;;;; swallowed condition is worse than a crash because the client just waits; two tests here
;;;; (a signalling handler, a streaming body) exist to make that argument falsifiable. They
;;;; read under a TIMEOUT, so if the server ever goes back to swallowing, the suite fails in
;;;; seconds instead of hanging the gate.

(cl:defpackage #:hyperion/server-uv/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:srv  #:hyperion/server-uv)
                    (#:sse  #:hyperion/sse)
                    (#:feed #:hyperion/feed)
                    (#:hsrv #:hyperion/server)      ; the seam commit 5 added
                    (#:sock #:sb-bsd-sockets)
                    (#:bt   #:bordeaux-threads)
                    (#:pool #:aion/pool)
                    (#:uv   #:aion/uv)
                    (#:static #:hyperion/static))
  (:export #:run-tests))

(in-package #:hyperion/server-uv/tests)

(def-suite server-uv :description "The native libuv HTTP/1.1 server (pre-publication issue 117).")
(in-suite server-uv)

(defun run-tests ()
  "Run the suite; return T on success (for asdf:test-system)."
  (run! 'server-uv))

;;; --- writing requests without writing control characters by hand -----------
;;;
;;; CRLF from CODE-CHAR, never a "\r\n" literal: in Common Lisp that string is the two
;;; characters `r' and `n', which is a bug the parser actually shipped with (see
;;; parser-tests.lisp) and which no type checker can catch.

(defparameter +cr+ (code-char 13))
(defparameter +lf+ (code-char 10))
(defparameter +crlf+ (coerce (list +cr+ +lf+) 'string))

(defun req (&rest lines)
  "LINES joined with CRLF and terminated by the blank line -- a complete request head."
  (format nil "~{~A~A~}~A" (loop for l in lines append (list l +crlf+)) +crlf+))

;;; --- the client ------------------------------------------------------------
;;;
;;; READ-TO-EOF DIED WITH COMMIT 4, and the reason is worth stating because it is the same
;;; mistake this server would make in the other direction. On a persistent connection there
;;; IS no EOF: the server answers and waits for the next request. A client that reads until
;;; the socket closes therefore blocks until the idle timeout, and would make every test in
;;; this file "pass" five seconds at a time.
;;;
;;; So the client FRAMES, exactly as a real one does: read the head, read Content-Length
;;; octets, stop. That also makes it able to read an interim 1xx (no Content-Length, no body)
;;; followed by the real response, which is what the 100-continue tests need.

(defparameter +io-timeout+ 10
  "Seconds a single exchange may take before the suite calls it a hang.

Generous for a loopback request that should finish in microseconds, and the only reason it
is not tighter is that a loaded CI box is slow in ways a hang is not. What matters is that
it is FINITE: the failure this suite most wants to catch is a request that never gets an
answer, and without a deadline that failure looks like a stuck test run.")

(defparameter +join-timeout+ 20
  "Seconds a test waits for a client thread it started to finish.

Longer than +IO-TIMEOUT+, because the thread's own request is bounded by that and should
always finish first. This is the bound for the case where it does not: a thread that never
returns.")

(defun %join-client (thread)
  "Wait for THREAD to finish and return its value, or signal an error after +JOIN-TIMEOUT+.

A plain join waits forever, so a thread that never finishes would stop the whole run until
CI kills the job, and the log would not say which test was waiting. An error here fails the
test that called it, by name, and the run continues."
  (multiple-value-bind (value outcome)
      (sb-thread:join-thread thread :timeout +join-timeout+ :default nil)
    (case outcome
      (:timeout (error "the client thread ~A did not finish within ~D seconds"
                       (sb-thread:thread-name thread) +join-timeout+))
      ;; An aborted thread has no value to return. A plain join signals an error here too.
      (:abort (error "the client thread ~A ended without returning a value"
                     (sb-thread:thread-name thread)))
      (t value))))

(defun %wait-until (predicate &key (seconds +io-timeout+))
  "Call PREDICATE every 5 ms until it returns true or SECONDS have passed. Returns its last value.

The budget is time, not a number of attempts. A fixed count of attempts is a time budget
that shrinks on a slow machine, because each attempt takes longer there."
  (loop with deadline = (+ (get-internal-real-time)
                           (* seconds internal-time-units-per-second))
        for result = (funcall predicate)
        until (or result (> (get-internal-real-time) deadline))
        do (sleep 0.005)
        finally (return result)))

(defparameter +crlfcrlf+ (concatenate 'string +crlf+ +crlf+))

(defun split-crlf (s)
  (loop with start = 0
        for i = (search +crlf+ s :start2 start)
        collect (subseq s start (or i (length s)))
        while i do (setf start (+ i 2))))

(defun header-of (response name)
  "The value of header NAME, or NIL. Case-insensitive on the name, as a client must be."
  (let ((head (subseq response 0 (or (search +crlfcrlf+ response) (length response)))))
    (dolist (line (rest (split-crlf head)))
      (let ((c (position #\: line)))
        (when (and c (string-equal name (subseq line 0 c)))
          (return (string-trim " " (subseq line (1+ c)))))))))

(defun status-of (response)
  "The status code from a response's start line, or NIL if it has no recognisable one."
  (let ((sp (position #\Space response)))
    (when sp (parse-integer response :start (1+ sp) :junk-allowed t))))

(defun body-of (response)
  "Everything after the blank line."
  (let ((end (search +crlfcrlf+ response)))
    (if end (subseq response (+ end 4)) "")))

(defun count-header (response name)
  "How many times NAME appears as a header. Duplicated framing is a wire bug, not a detail."
  (let ((head (subseq response 0 (or (search +crlfcrlf+ response) (length response)))))
    (count-if (lambda (line)
                (let ((c (position #\: line)))
                  (and c (string-equal name (subseq line 0 c)))))
              (rest (split-crlf head)))))

(defun %read-head (stream)
  "Octets up to and including CRLFCRLF, or NIL at end of stream. One byte at a time, which
is fine for a head and is the only way to stop exactly at the boundary without over-reading
into a body -- or into the NEXT response, on a pipelined connection."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop
      (let ((b (read-byte stream nil nil)))
        (unless b (return nil))
        (vector-push-extend b out)
        (let ((n (fill-pointer out)))
          (when (and (>= n 4)
                     (= 13 (aref out (- n 4))) (= 10 (aref out (- n 3)))
                     (= 13 (aref out (- n 2))) (= 10 (aref out (- n 1))))
            (return out)))))))

(defun read-response (stream)
  "One complete response -- head plus exactly Content-Length octets -- or NIL at end of
stream. A response with no Content-Length has no body, which is what makes this read a 1xx
interim response correctly rather than hanging on a body that is never coming."
  (let ((head (%read-head stream)))
    (when head
      (let* ((text (sb-ext:octets-to-string (coerce head '(vector (unsigned-byte 8)))
                                            :external-format :latin-1))
             (declared (header-of text "Content-Length"))
             (n (if declared (parse-integer declared) 0))
             (body (make-array n :element-type '(unsigned-byte 8))))
        (when (plusp n) (read-sequence body stream))
        (concatenate 'string text
                     (sb-ext:octets-to-string body :external-format :latin-1))))))

(defparameter +terminator+
  (coerce (list +cr+ +lf+ #\0 +cr+ +lf+ +cr+ +lf+) 'string)
  "CRLF 0 CRLF CRLF -- the end of a chunked message. The leading CRLF is the previous
chunk's, or the head's when there were no data chunks at all.")

(defun read-chunked-response (stream)
  "One CHUNKED response, read to its terminator OR to end of stream.

READ-RESPONSE cannot be used for these: it frames by Content-Length, which a chunked
response deliberately has none of, so it would return the head and none of the body -- a
harness that cannot see the thing under test. Reading to END OF STREAM as well as to the
terminator is what lets a test tell a TRUNCATED stream from a complete one, which is the
distinction the mid-stream failure path exists to produce."
  (let ((octets (make-array 0 :element-type '(unsigned-byte 8)
                              :adjustable t :fill-pointer 0)))
    (loop
      (let ((b (read-byte stream nil nil)))
        (unless b (return))                     ; the peer closed: truncated, or done
        (vector-push-extend b octets)
        (when (and (>= (fill-pointer octets) 7)
                   (string= +terminator+
                            (sb-ext:octets-to-string
                             (coerce (subseq octets (- (fill-pointer octets) 7))
                                     '(vector (unsigned-byte 8)))
                             :external-format :latin-1)))
          (return))))
    (sb-ext:octets-to-string (coerce octets '(vector (unsigned-byte 8)))
                             :external-format :latin-1)))

(defun stream-get (port &rest lines)
  "One request on its own connection, read as a chunked response."
  (let ((s (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (sb-ext:with-timeout +io-timeout+
           (sock:socket-connect s #(127 0 0 1) port)
           (let ((stream (sock:socket-make-stream s :input t :output t
                                                    :element-type '(unsigned-byte 8))))
             (write-sequence (sb-ext:string-to-octets (apply #'req lines)
                                                      :external-format :latin-1)
                             stream)
             (force-output stream)
             (read-chunked-response stream)))
      (ignore-errors (sock:socket-close s)))))

(defun peer-closed-p (stream)
  "Did the server close its end? Reads one octet, which must be the end of stream."
  (null (read-byte stream nil nil)))

(defun converse (port pieces &key (responses 1) (then nil))
  "Open ONE connection to PORT, write PIECES in order, read RESPONSES framed responses, and
optionally run THEN with the still-open stream before closing.

PIECES rather than one string so a test can split a request ACROSS TCP WRITES -- a chunk
boundary is not a message boundary, and that is precisely what a server gets wrong."
  (let ((s (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (sb-ext:with-timeout +io-timeout+
           (sock:socket-connect s #(127 0 0 1) port)
           (let ((stream (sock:socket-make-stream s :input t :output t
                                                    :element-type '(unsigned-byte 8))))
             (dolist (p pieces)
               (write-sequence (sb-ext:string-to-octets p :external-format :latin-1) stream)
               (force-output stream))
             (let ((got (loop repeat responses collect (read-response stream))))
               (if then (list got (funcall then stream)) got))))
      (ignore-errors (sock:socket-close s)))))

(defun get* (port &rest lines)
  "One request on its own connection, and the response to it."
  (first (converse port (list (apply #'req lines)))))

;;; --- the fixture -----------------------------------------------------------

(defmacro with-server ((port app) &body body)
  "Start APP on an ephemeral port, bind PORT to the one the OS chose, and always stop it."
  (let ((s (gensym "SERVER")))
    `(let ((,s (srv:start ,app :port 0)))
       (unwind-protect (let ((,port (srv:server-port ,s))) ,@body)
         (srv:stop ,s)))))

(defun const-app (status headers body)
  (lambda (env) (declare (ignore env)) (list status headers body)))

(defparameter +ok+ '(:content-type "text/plain; charset=utf-8"))

;;; --- lifecycle -------------------------------------------------------------

(test ephemeral-port-is-reported
  "PORT 0 asks the OS to choose, and the server says which -- the property that lets this
whole suite run without a fixed port and without a race against another test."
  (let ((a (srv:start (const-app 200 +ok+ '("hi")) :port 0))
        (b (srv:start (const-app 200 +ok+ '("hi")) :port 0)))
    (unwind-protect
         (progn
           (is (plusp (srv:server-port a)))
           (is (string= "127.0.0.1" (srv:server-host a))
               "server-host reports the address actually bound")
           (is (/= (srv:server-port a) (srv:server-port b))
               "two ephemeral servers get two ports -- which is what makes this suite safe
to run beside anything else"))
      (srv:stop a)
      (srv:stop b))))

(test stop-is-idempotent-and-actually-stops
  "STOP twice must not signal, and the port must stop answering. A `stop' that leaves the
listener open is the kind of leak a test suite creates thousands of."
  (let* ((server (srv:start (const-app 200 +ok+ '("hi")) :port 0))
         (port (srv:server-port server)))
    (is (string= "hi" (body-of (get* port "GET / HTTP/1.1" "Host: x"))))
    (srv:stop server)
    (finishes (srv:stop server))
    (let ((s (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
      (unwind-protect
           (is-false (handler-case (progn (sock:socket-connect s #(127 0 0 1) port) t)
                       (error () nil))
                     "a stopped server must not accept connections")
        (ignore-errors (sock:socket-close s))))))

;;; --- the round trip --------------------------------------------------------

(test get-round-trip
  "The whole path: octets in, parsed, handler called, framed response out."
  (with-server (port (const-app 200 +ok+ '("hello")))
    (let ((r (get* port "GET / HTTP/1.1" "Host: x")))
      (is (= 200 (status-of r)))
      (is (string= "hello" (body-of r)))
      (is (string= "5" (header-of r "Content-Length"))
          "Content-Length is MEASURED from the body, not taken on trust")
      (is (string= "keep-alive" (header-of r "Connection"))
          "HTTP/1.1 defaults to a persistent connection, and the response must say so"))))

(test response-header-names-are-capitalised
  "A Ring handler writes :CONTENT-TYPE; the wire must carry `Content-Type'. The keyword is
hyperion's calling convention and the capitalised token is HTTP's."
  (with-server (port (const-app 200 '(:content-type "text/plain" :x-request-id "abc") '("k")))
    (let ((r (get* port "GET / HTTP/1.1" "Host: x")))
      (is (string= "text/plain" (header-of r "Content-Type")))
      (is (search (concatenate 'string "X-Request-Id: abc" +crlf+) r)
          "a multi-word keyword capitalises every word: X-Request-Id"))))

(test non-string-header-values-are-printed
  "(:retry-after 30) means the header, not a type error -- and the encoder's safety check
takes a String, so an unconverted integer would fail a pattern match inside a callback."
  (with-server (port (const-app 503 '(:retry-after 30) '("later")))
    (let ((r (get* port "GET / HTTP/1.1" "Host: x")))
      (is (= 503 (status-of r)))
      (is (string= "30" (header-of r "Retry-After"))))))

(test handler-supplied-framing-headers-are-dropped
  "A handler that sets its own Content-Length must not produce two of them. Disagreeing
framing headers are request smuggling's other half, and the encoder drops them for exactly
that reason -- this proves the shell does not put them back."
  (with-server (port (const-app 200 '(:content-type "text/plain" :content-length "999")
                               '("hello")))
    (let ((r (get* port "GET / HTTP/1.1" "Host: x")))
      (is (= 1 (count-header r "Content-Length")))
      (is (string= "5" (header-of r "Content-Length"))
          "the measured length wins over the one the handler asserted"))))

;;; --- the env ---------------------------------------------------------------

(defun capturing-app (place)
  (lambda (env) (setf (car place) env) (list 200 +ok+ '("ok"))))

(test env-carries-the-ring-keys
  "The nine keys ADR-0015 enumerates. This contract used to be Clack's, so drift was
impossible; now it is ours and a missing key is our bug."
  (let ((seen (list nil)))
    (with-server (port (capturing-app seen))
      (get* port "GET /a/b?x=1&y=2 HTTP/1.1" "Host: example.test"
            "Content-Type: text/plain"))
    (let ((env (car seen)))
      (is (eq :GET (getf env :request-method)))
      (is (string= "/a/b" (getf env :path-info)) "the query is NOT part of path-info")
      (is (string= "x=1&y=2" (getf env :query-string)))
      (is (string= "example.test" (gethash "host" (getf env :headers)))
          "header keys are lowercased, which is what every reader in hyperion looks up")
      (is (string= "text/plain" (getf env :content-type)))
      (is (string= "127.0.0.1" (getf env :remote-addr))))))

(test query-string-distinguishes-absent-from-empty
  "`/x' has no query; `/x?' has an empty one. Collapsing the two loses a distinction a
handler is entitled to see."
  (let ((seen (list nil)))
    (with-server (port (capturing-app seen))
      (get* port "GET /x HTTP/1.1" "Host: h")
      (is-false (getf (car seen) :query-string) "no `?' at all means NIL")
      (get* port "GET /x? HTTP/1.1" "Host: h")
      (is (equal "" (getf (car seen) :query-string)) "a bare `?' means the empty query"))))

(test repeated-header-is-comma-joined
  "RFC 9110 lets a recipient combine repeated fields; the readers in hyperion expect one
value per key. Joining is the choice, and it is checked rather than assumed."
  (let ((seen (list nil)))
    (with-server (port (capturing-app seen))
      (get* port "GET / HTTP/1.1" "Host: h" "Accept: a" "Accept: b"))
    (is (string= "a, b" (gethash "accept" (getf (car seen) :headers))))))

(test post-body-is-a-readable-stream
  "RAW-BODY is a STREAM because http:parse-multipart and http:body-octets READ-SEQUENCE
from it. A vector here would typecheck everywhere and fail at the first upload."
  (let ((got (list nil)))
    (with-server (port (lambda (env)
                         (let* ((n (getf env :content-length))
                                (buf (make-array n :element-type '(unsigned-byte 8))))
                           (read-sequence buf (getf env :raw-body))
                           (setf (car got) (sb-ext:octets-to-string
                                            buf :external-format :utf-8))
                           (list 200 +ok+ (list (car got))))))
      (let ((r (first (converse port (list (concatenate 'string
                                              (req "POST /p HTTP/1.1" "Host: h"
                                                   "Content-Length: 5")
                                                     "abcde"))))))
        (is (string= "abcde" (car got)) "the handler read the body it was sent")
        (is (string= "abcde" (body-of r)))))))

(test a-request-split-across-writes-still-parses
  "A TCP chunk boundary is not a message boundary. Sent one write at a time, with the split
INSIDE the header block and again inside the body."
  (with-server (port (lambda (env)
                       (let* ((n (getf env :content-length))
                              (buf (make-array n :element-type '(unsigned-byte 8))))
                         (read-sequence buf (getf env :raw-body))
                         (list 200 +ok+ (list (sb-ext:octets-to-string
                                               buf :external-format :utf-8))))))
    (let ((r (first (converse port (list (concatenate 'string "POST /p HTTP/1.1" +crlf+ "Ho")
                               (concatenate 'string "st: h" +crlf+ "Content-Length: 5"
                                            +crlf+ +crlf+ "ab")
                                        "cde")))))
      (is (= 200 (status-of r)))
      (is (string= "abcde" (body-of r))))))

;;; --- the failures that must not hang ---------------------------------------

(test a-signalling-handler-answers-500
  "The file header's central claim, made falsifiable. UV:WITH-CALLBACK-GUARD would absorb
this condition and return NIL -- no response written, client waiting until it times out.
The request-boundary HANDLER-CASE is what turns it into an answer."
  (with-server (port (lambda (env) (declare (ignore env)) (error "boom")))
    (let ((r (get* port "GET / HTTP/1.1" "Host: x")))
      (is (= 500 (status-of r)))
      (is (string= (header-of r "Content-Length")
                   (princ-to-string (length (body-of r))))
          "even the error response must be correctly framed"))))

(test a-function-inside-a-list-body-is-still-refused
  "M1 refused every function body; M2 answers the STREAMING shape -- a function AS the body
-- and this is the case that stayed illegal. A list body is a sequence of pieces to
concatenate, and a piece that has not been produced yet has no length to contribute, so
accepting it would produce a wrong Content-Length rather than a stream."
  (with-server (port (const-app 200 +ok+ (list "a" (lambda (writer)
                                                     (declare (ignore writer)) nil))))
    (is (= 500 (status-of (get* port "GET / HTTP/1.1" "Host: x"))))))

(test a-header-we-refuse-to-send-becomes-500
  "A CR in a header value is response splitting. It is never sanitised and never sent: the
handler produced a bug, and a bug is a 500."
  (with-server (port (const-app 200 (list :x-evil (format nil "a~AbSet-Cookie: c=1" +cr+))
                                '("body")))
    (is (= 500 (status-of (get* port "GET / HTTP/1.1" "Host: x"))))))

;;; --- refusals, and where each status comes from ----------------------------

(test a-malformed-request-gets-the-parsers-status
  "Not just `an error' -- the status the PARSER chose has to reach the wire, or the security
floor is decided in one place and reported from another."
  (with-server (port (const-app 200 +ok+ '("never")))
    (is (= 400 (status-of (get* port "GET / HTTP/1.1" "Ho st: x")))
        "a space in a header name is 400")
    (is (= 505 (status-of (get* port "GET / HTTP/2.0" "Host: x")))
        "an unsupported version is 505, not 400")
    (is (= 501 (status-of (get* port "POST / HTTP/1.1" "Host: x"
                                "Transfer-Encoding: chunked")))
        "chunked is 501 in M1 -- and refusing beats reading the body as a second request")))

(test the-handler-never-runs-for-a-rejected-request
  "A rejection is decided before the application sees anything. If a malformed request could
reach a handler, the parser would be advice rather than a floor."
  (let ((calls (list 0)))
    (with-server (port (lambda (env) (declare (ignore env))
                         (incf (car calls)) (list 200 +ok+ '("x"))))
      (get* port "GET / HTTP/1.1" "Ho st: x")
      (is (= 0 (car calls))))))

(test an-oversized-body-is-413-before-it-is-read
  "The cap is POLICY and lives here, not in the parser. Answered on the declared length, so
the server never buffers the megabytes it is about to refuse."
  ;; SETF, not LET: the handler runs on the LOOP THREAD, and a dynamic binding in SBCL is
  ;; thread-local. A `let' here would rebind it in the test's own thread and the server
  ;; would go on reading the global value -- a test that passes for the wrong reason, or
  ;; more often fails while the code is right.
  (let ((saved srv:*max-body-octets*))
    (unwind-protect
         (progn
           (setf srv:*max-body-octets* 10)
           (with-server (port (const-app 200 +ok+ '("never")))
             (is (= 413 (status-of (get* port "POST /p HTTP/1.1" "Host: h"
                                                 "Content-Length: 100"))))))
      (setf srv:*max-body-octets* saved))))

;;; --- the seam --------------------------------------------------------------

(test dispatch-is-the-seam-it-claims-to-be
  "*DISPATCH* exists from this commit so that M2's worker pool is a rebinding rather than a
rewrite of the request path. A seam nothing has ever been threaded through is a comment."
  (let ((saved srv:*dispatch*)
        (seen (list 0)))
    (unwind-protect
         (progn
           (setf srv:*dispatch*
                 (lambda (app env k) (incf (car seen)) (funcall k (funcall app env))))
           (with-server (port (const-app 200 +ok+ '("through")))
             (is (string= "through" (body-of (get* port "GET / HTTP/1.1" "Host: x"))))
             (is (= 1 (car seen)) "the request went through *DISPATCH*, not around it")))
      (setf srv:*dispatch* saved))))

;;; --- persistence, pipelining and 100-continue (commit 4) -------------------

(defun exchange (port requests)
  "Send REQUESTS one at a time on ONE connection, reading each response before sending the
next. Sequential keep-alive, the way a browser does it -- deliberately distinct from
pipelining, which writes them all before reading anything. The two exercise different halves
of the drain loop and only one of them is what real clients mostly do."
  (let ((s (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (sb-ext:with-timeout +io-timeout+
           (sock:socket-connect s #(127 0 0 1) port)
           (let ((stream (sock:socket-make-stream s :input t :output t
                                                    :element-type '(unsigned-byte 8))))
             (loop for r in requests
                   do (write-sequence (sb-ext:string-to-octets r :external-format :latin-1)
                                      stream)
                      (force-output stream)
                   collect (read-response stream))))
      (ignore-errors (sock:socket-close s)))))

(defun echo-path-app ()
  (lambda (env) (list 200 +ok+ (list (getf env :path-info)))))

(test two-requests-on-one-connection
  "The point of keep-alive. Sequential, and each answer must belong to its own request --
a server that got the drain wrong answers the second with the first one's body."
  (with-server (port (echo-path-app))
    (let ((rs (exchange port (list (req "GET /one HTTP/1.1" "Host: h")
                                   (req "GET /two HTTP/1.1" "Host: h")))))
      (is (= 2 (length rs)))
      (is (= 200 (status-of (first rs))))
      (is (string= "/one" (body-of (first rs))))
      (is (= 200 (status-of (second rs))))
      (is (string= "/two" (body-of (second rs)))))))

(test pipelined-requests-in-one-write-are-both-answered
  "Both requests in ONE segment. This is what the drain loop is for: a server that handled
the first and went back to waiting for a chunk would stall forever, because the peer is
waiting for responses and has nothing left to send."
  (with-server (port (echo-path-app))
    (let ((rs (converse port (list (concatenate 'string
                                                (req "GET /a HTTP/1.1" "Host: h")
                                                (req "GET /b HTTP/1.1" "Host: h")))
                        :responses 2)))
      (is (string= "/a" (body-of (first rs))))
      (is (string= "/b" (body-of (second rs)))))))

(test a-body-does-not-leak-into-the-next-request
  "The smuggling guard. A POST body and the request behind it arrive in one segment; if the
drain discarded anything but exactly head+body, the second request is parsed starting from
the wrong octet -- and an attacker supplies both halves.

IT ASSERTS THE METHOD, and that is the whole test rather than a detail. A control run with
the drain deliberately broken -- discarding the head but not the body -- PASSED an earlier
version of this test that checked only the status and the path. Left in the buffer, `abcde'
glues onto the front of the next request line, `abcdeGET /second HTTP/1.1' splits into three
parts exactly like a real one, and `abcdeGET' is a perfectly legal method token. So the
smuggled request parses, succeeds, and answers the right path. The METHOD is where the
injected octets actually land, and nothing else in the exchange looks wrong."
  (with-server (port (lambda (env)
                       (list 200 +ok+
                             (list (format nil "~A|~A|~A"
                                           (getf env :request-method)
                                           (getf env :path-info)
                                           (or (getf env :content-length) 0))))))
    (let ((rs (converse port (list (concatenate 'string
                                                (req "POST /first HTTP/1.1" "Host: h"
                                                     "Content-Length: 5")
                                                "abcde"
                                                (req "GET /second HTTP/1.1" "Host: h")))
                        :responses 2)))
      (is (string= "POST|/first|5" (body-of (first rs))))
      (is (= 200 (status-of (second rs)))
          "the request after a body must parse, not be read from the middle of one")
      (is (string= "GET|/second|0" (body-of (second rs)))
          "GET, not ABCDEGET: the body must not have survived into the next request line"))))

(test connection-close-is-honoured
  "A peer that says close gets close, and gets it on the wire as well as on the socket."
  (with-server (port (const-app 200 +ok+ '("bye")))
    (destructuring-bind (responses closed)
        (converse port (list (req "GET / HTTP/1.1" "Host: h" "Connection: close"))
                  :then #'peer-closed-p)
      (is (string= "close" (header-of (first responses) "Connection")))
      (is-true closed "the server must actually close, not merely say so"))))

(test http-1-0-is-not-persistent-unless-it-asks
  "HTTP/1.0's default is the opposite of HTTP/1.1's. Getting this backwards leaves a 1.0
client waiting for a close that never comes."
  (with-server (port (const-app 200 +ok+ '("x")))
    (is (string= "close" (header-of (get* port "GET / HTTP/1.0" "Host: h") "Connection")))
    (is (string= "keep-alive"
                 (header-of (get* port "GET / HTTP/1.0" "Host: h" "Connection: keep-alive")
                            "Connection"))
        "a 1.0 client that asks for persistence gets it")))

(test the-request-cap-ends-the-connection
  ;; SETF, not LET: the server reads this on the LOOP THREAD and a dynamic binding in SBCL
  ;; is thread-local, so a LET here would rebind it in the test's thread only.
  (let ((saved srv:*max-requests-per-connection*))
    (unwind-protect
         (progn
           (setf srv:*max-requests-per-connection* 2)
           (with-server (port (echo-path-app))
             (destructuring-bind (responses closed)
                 (converse port (list (concatenate 'string
                                                   (req "GET /a HTTP/1.1" "Host: h")
                                                   (req "GET /b HTTP/1.1" "Host: h")))
                           :responses 2 :then #'peer-closed-p)
               (is (string= "keep-alive" (header-of (first responses) "Connection")))
               (is (string= "close" (header-of (second responses) "Connection"))
                   "the request that reaches the cap says so rather than closing silently")
               (is-true closed))))
      (setf srv:*max-requests-per-connection* saved))))

;;; The two clock cases. They are separate tests because they are separate answers, and a
;;; server that gives one of them in both situations is wrong in a way a single test hides.

(defmacro with-short-idle-clock ((ms) &body body)
  `(let ((saved srv:*keep-alive-timeout-ms*))
     (unwind-protect (progn (setf srv:*keep-alive-timeout-ms* ,ms) ,@body)
       (setf srv:*keep-alive-timeout-ms* saved))))

(test an-idle-connection-is-closed-silently
  "The ordinary end of a persistent connection. The peer did nothing wrong, so it gets no
status -- and a 408 here would race whatever request it is about to send, answering a
request the server never read."
  (with-short-idle-clock (300)
    (with-server (port (const-app 200 +ok+ '("hi")))
      (destructuring-bind (responses after)
          (converse port (list (req "GET / HTTP/1.1" "Host: h"))
                    :then (lambda (stream) (read-response stream)))
        (is (= 200 (status-of (first responses))))
        (is-false after "an idle timeout sends nothing at all -- not even a 408")))))

(test a-half-sent-request-times-out-with-408
  "The slowloris shape: a head that starts and stops. The parser caps how BIG a head may be
and nothing caps how LONG one may take, so the clock is the only thing standing here."
  (with-short-idle-clock (300)
    (with-server (port (const-app 200 +ok+ '("never")))
      (let ((r (first (converse port (list (concatenate 'string
                                                        "GET / HTTP/1.1" +crlf+
                                                        "Host: h" +crlf+))))))
        (is (= 408 (status-of r))
            "a request left half-sent is told, rather than dropped without explanation")))))

(defun echo-body-app ()
  (lambda (env)
    (let* ((n (getf env :content-length))
           (buf (make-array n :element-type '(unsigned-byte 8))))
      (read-sequence buf (getf env :raw-body))
      (list 200 +ok+ (list (sb-ext:octets-to-string buf :external-format :utf-8))))))

(test expect-100-continue-gets-an-interim-then-the-response
  "The peer is waiting for permission to send its body. Answering only after the body
arrives is a deadlock: it waits for us, we wait for it.

EXCHANGE, not CONVERSE, and that distinction is the test. A client that writes the head and
the body together never needs an interim -- writing both and then looking for a 100 tests
nothing, which is exactly the mistake the first version of this test made."
  (with-server (port (echo-body-app))
    (let ((rs (exchange port (list (req "POST /p HTTP/1.1" "Host: h"
                                        "Content-Length: 5" "Expect: 100-continue")
                                   "abcde"))))
      (is (= 100 (status-of (first rs))))
      (is-false (header-of (first rs) "Content-Length")
                "a 1xx carries no Content-Length -- one here would make the client read the real response's head as a body")
      (is (= 200 (status-of (second rs))))
      (is (string= "abcde" (body-of (second rs)))))))

(test no-interim-when-the-body-already-arrived
  "A client that did not wait gets no 100, and that is correct rather than a shortcut: the
interim exists to unblock a peer, and this peer was never blocked. Sending one anyway would
be a spare message the client must be prepared to skip.

Found by getting the test above wrong, which is the only reason it is pinned here."
  (with-server (port (echo-body-app))
    (let ((rs (converse port (list (concatenate 'string
                                                (req "POST /p HTTP/1.1" "Host: h"
                                                     "Content-Length: 5"
                                                     "Expect: 100-continue")
                                                "abcde"))
                        :responses 1)))
      (is (= 200 (status-of (first rs)))
          "the first message back is the real response, not an interim")
      (is (string= "abcde" (body-of (first rs)))))))

(test an-unknown-expectation-is-417
  "RFC 9110 is blunt: an expectation we do not understand MUST be refused, not ignored.
Ignoring it is the tempting reading and it deadlocks the peer."
  (with-server (port (const-app 200 +ok+ '("never")))
    (is (= 417 (status-of (get* port "POST /p HTTP/1.1" "Host: h"
                                "Content-Length: 5" "Expect: the-moon"))))))

;;; --- chosen through hyperion/server (commit 5) -----------------------------
;;;
;;; Everything above tests the server directly. This section tests the JOIN: that
;;; hyperion/server can choose this backend, start it, and stop it, without hyperion core
;;; depending on it. That join is the whole of commit 5, and it is invisible from either
;;; side alone -- which is why this suite loads both systems while the SOURCE still loads
;;; neither the other way round.

(defmacro with-hyperion-server ((port &rest start-args) &body body)
  "Start through HYPERION/SERVER (not SRV:START) and always stop through it."
  (let ((h (gensym "HANDLER")))
    `(let ((,h (hsrv:start ,@start-args :server :uv :port 0)))
       (unwind-protect (let ((,port (srv:server-port ,h))) ,@body)
         (hsrv:stop ,h)))))

(test default-server-picks-uv-when-it-is-the-only-one-loaded
  "The selection rule, exercised rather than reasoned about. This image loads hyperion (so
`clack' is present) but NO Clack handler, and hyperion/server-uv. Package presence is the
test, so the native server must be both the only option and the chosen one."
  (is (equal '(:uv) (hsrv:available-servers))
      "no Clack HANDLER is loaded here -- clack itself being present must not count")
  (is (eq :uv (hsrv:default-server))))

(test hyperion-server-start-runs-the-native-backend
  "Chosen, started and served through the framework's own entry point."
  (with-hyperion-server (port (const-app 200 +ok+ '("via hyperion/server")) :log nil)
    (let ((r (get* port "GET / HTTP/1.1" "Host: h")))
      (is (= 200 (status-of r)))
      (is (string= "via hyperion/server" (body-of r))))))

(test the-native-path-frames-without-wrap-content-length
  "START deliberately does NOT apply WRAP-CONTENT-LENGTH for a native backend: that wrapper
exists because a Clack handler with no length header falls back to chunked and meets the
delayed-ACK timer (44 ms a request, ADR-0011). The native encoder measures the body itself.
This is the check that makes skipping it safe rather than merely cheaper."
  (with-hyperion-server (port (const-app 200 +ok+ '("hello")) :log nil)
    (let ((r (get* port "GET / HTTP/1.1" "Host: h")))
      (is (string= "5" (header-of r "Content-Length")))
      (is (= 1 (count-header r "Content-Length"))))))

(test the-logging-wrapper-composes-with-the-native-env
  "HYPERION/LOGGING:WRAP is ON by default and reads the env. Our env is now ours rather than
Clack's, so `it works under the other backend' is not evidence about this one."
  (with-hyperion-server (port (const-app 200 +ok+ '("logged")) :log t)
    (let ((r (get* port "GET /some/path?q=1 HTTP/1.1" "Host: h")))
      (is (= 200 (status-of r)))
      (is (string= "logged" (body-of r))))))

(test stop-through-hyperion-server-actually-stops-it
  "STOP dispatches on the handler, because the handler is what callers hold. If it guessed
Clack it would signal here rather than stopping anything."
  (let* ((h (hsrv:start (const-app 200 +ok+ '("x")) :server :uv :port 0 :log nil))
         (port (srv:server-port h)))
    (is (= 200 (status-of (get* port "GET / HTTP/1.1" "Host: h"))))
    (finishes (hsrv:stop h))
    (let ((s (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
      (unwind-protect
           (is-false (handler-case (progn (sock:socket-connect s #(127 0 0 1) port) t)
                       (error () nil))
                     "stopped through hyperion/server means actually stopped")
        (ignore-errors (sock:socket-close s))))))

(test debug-is-refused-out-loud-rather-than-ignored
  "There is no debugger to drop into inside a loop callback, so :debug t cannot be honoured.
Accepting it silently would let an operator believe it did something."
  (let ((warned nil) (handler nil))
    (unwind-protect
         (progn
           (handler-bind ((warning (lambda (c) (setf warned t) (muffle-warning c))))
             (setf handler (hsrv:start (const-app 200 +ok+ '("x"))
                                       :server :uv :port 0 :log nil :debug t)))
           (is-true warned ":debug t must warn on a native backend"))
      (when handler (hsrv:stop handler)))))

;;; --- the dispatch seam is asynchronous now (M2) ---------------------------
;;;
;;; *DISPATCH* takes a continuation rather than returning a response, which is what lets a
;;; handler run somewhere other than the loop thread. These assert the new contract; that
;;; the REFACTOR changed no behaviour is asserted by every test above still passing
;;; untouched, which is the stronger claim and the reason none of them were edited.

(defun read-all (stream)
  "Everything remaining on STREAM, to end of stream, as latin-1 text."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop for b = (read-byte stream nil nil) while b do (vector-push-extend b out))
    (sb-ext:octets-to-string (coerce out '(vector (unsigned-byte 8)))
                             :external-format :latin-1)))

(defun count-status-lines (text)
  "How many HTTP status lines are in TEXT. Counting on the WIRE rather than trusting a
framed read, because the defect being looked for is a second response nobody asked for."
  (loop with n = 0 with start = 0
        for i = (search "HTTP/1.1 " text :start2 start)
        while i do (incf n) (setf start (+ i 9))
        finally (return n)))

(defmacro with-dispatch ((fn) &body body)
  "Run BODY with *DISPATCH* bound to FN, restoring it however BODY leaves."
  (let ((saved (gensym "SAVED")))
    `(let ((,saved srv:*dispatch*))
       (unwind-protect (progn (setf srv:*dispatch* ,fn) ,@body)
         (setf srv:*dispatch* ,saved)))))

(defun threaded-dispatch (&key (delay 0.0))
  "A dispatcher that answers from ANOTHER THREAD after DELAY -- the thing the continuation
exists to make possible, and the thing that was impossible before M2."
  (lambda (app env k)
    (bt:make-thread
     (lambda ()
       (when (plusp delay) (sleep delay))
       (funcall k (handler-case (funcall app env) (error (e) e)))))))

(test a-deferred-dispatcher-still-answers
  ;; K is called long after *DISPATCH* returned, from a thread that is not the loop's, and
  ;; the response still reaches the client. K routes itself; the dispatcher does not have
  ;; to remember UV:SUBMIT, which is a rule that would fail silently by corrupting rather
  ;; than by signalling.
  (with-dispatch ((threaded-dispatch :delay 0.05))
    (with-server (port (const-app 200 +ok+ (list "deferred")))
      (is (string= "deferred" (body-of (get* port "GET / HTTP/1.1" "Host: x")))))))

(test a-deferred-dispatcher-keeps-pipelined-responses-in-order
  ;; HTTP/1.1 has no request ids: responses are matched to requests BY ORDER. A server that
  ;; answered out of order would not merely reorder replies, it would hand each client
  ;; someone else's. So this dispatcher answers with a DECREASING delay, which inverts
  ;; completion order -- if anything but arrival order decided the wire, this would fail.
  (let ((remaining (list 3)))
    (with-dispatch ((lambda (app env k)
                      (let ((delay (* 0.05 (decf (car remaining)))))
                        (bt:make-thread
                         (lambda ()
                           (when (plusp delay) (sleep delay))
                           (funcall k (handler-case (funcall app env) (error (e) e))))))))
      (with-server (port (echo-path-app))
        (let ((rs (converse port (list (concatenate 'string
                                                    (req "GET /a HTTP/1.1" "Host: h")
                                                    (req "GET /b HTTP/1.1" "Host: h")
                                                    (req "GET /c HTTP/1.1" "Host: h")))
                            :responses 3)))
          (is (equal '("/a" "/b" "/c") (mapcar #'body-of rs))
              "answered in ARRIVAL order, not completion order"))))))

(test a-dispatcher-that-calls-back-twice-writes-one-response
  ;; Two responses on one request is response smuggling with the server supplying both
  ;; halves. The guard lives in %COMPLETE rather than in a documented rule, because a
  ;; dispatcher that both signals and calls back is easy to write by accident.
  (with-dispatch ((lambda (app env k)
                    (let ((r (handler-case (funcall app env) (error (e) e))))
                      (funcall k r)
                      (funcall k r))))
    (with-server (port (const-app 200 +ok+ (list "once")))
      (let ((raw (second (converse port (list (req "GET / HTTP/1.1" "Host: x"
                                                   "Connection: close"))
                                   :responses 0 :then #'read-all))))
        (is (= 1 (count-status-lines raw))
            "exactly one status line reached the wire")))))

(test a-dispatcher-that-signals-becomes-a-500
  ;; The DISPATCHER failing is not the handler failing -- a pool that cannot accept work,
  ;; or a seam somebody rebound badly. Without its own boundary that condition escapes into
  ;; uv's callback guard, which absorbs it, and the request hangs until the client gives up.
  (with-dispatch ((lambda (app env k)
                    (declare (ignore app env k))
                    (error "the dispatcher itself is broken")))
    (with-server (port (const-app 200 +ok+ (list "unreached")))
      (is (= 500 (status-of (get* port "GET / HTTP/1.1" "Host: x")))))))

;;; --- the worker pool as a dispatcher (M2) ---------------------------------

(test pool-dispatch-runs-handlers-off-the-loop-thread
  ;; The point of M2's first half. Recorded by the handler itself rather than inferred:
  ;; the thread it ran on must not be the one the loop owns.
  (let ((p (pool:make-pool :size 2 :name "test-pool"))
        (threads (list nil)))
    (unwind-protect
         (with-dispatch ((srv:pool-dispatch p))
           (with-server (port (lambda (env)
                                (declare (ignore env))
                                (push sb-thread:*current-thread* (car threads))
                                (list 200 +ok+ (list "worked"))))
             (is (string= "worked" (body-of (get* port "GET / HTTP/1.1" "Host: x"))))
             (is (search "test-pool" (sb-thread:thread-name (first (car threads))))
                 "it ran on a POOL thread, not on the loop")))
      (pool:stop-pool p))))

(test a-slow-handler-no-longer-blocks-other-connections
  ;; The defect M2 exists to fix, as a test. With the inline dispatcher there is one loop
  ;; thread, so a handler that blocks blocks EVERY connection; with a pool it occupies one
  ;; worker. The gate makes the first request block until the second has been answered --
  ;; which can only happen if the two are not sharing a thread.
  (let ((p (pool:make-pool :size 4 :name "slow-pool"))
        (gate (sb-thread:make-semaphore)))
    (unwind-protect
         (with-dispatch ((srv:pool-dispatch p))
           (with-server (port (lambda (env)
                                (if (string= "/slow" (getf env :path-info))
                                    (progn (sb-thread:wait-on-semaphore gate :timeout 10)
                                           (list 200 +ok+ (list "slow")))
                                    (list 200 +ok+ (list "fast")))))
             (let ((slow (bt:make-thread
                          (lambda () (get* port "GET /slow HTTP/1.1" "Host: x")))))
               ;; the fast request must be answerable while /slow is still parked
               (is (string= "fast" (body-of (get* port "GET /fast HTTP/1.1" "Host: x")))
                   "answered while a handler was blocked -- impossible on one loop thread")
               (sb-thread:signal-semaphore gate)
               (is (string= "slow" (body-of (%join-client slow)))))))
      (sb-thread:signal-semaphore gate 10)
      (pool:stop-pool p))))

(test a-full-pool-answers-503-rather-than-queueing-forever
  ;; A refusal is answered, not dropped and not waited for. Waiting for a slot would block
  ;; the loop thread, which is the defect the pool removes, reintroduced by the pool.
  (let ((p (pool:make-pool :size 1 :queue-limit 0 :name "tiny-pool"))
        (gate (sb-thread:make-semaphore)))
    (unwind-protect
         (with-dispatch ((srv:pool-dispatch p))
           (with-server (port (lambda (env)
                                (declare (ignore env))
                                (sb-thread:wait-on-semaphore gate :timeout 10)
                                (list 200 +ok+ (list "eventually"))))
             (let ((parked (bt:make-thread
                            (lambda () (get* port "GET /a HTTP/1.1" "Host: x")))))
               ;; wait until the single worker is genuinely occupied
               (%wait-until (lambda () (= 1 (pool:pool-busy p))))
               (is (= 1 (pool:pool-busy p)))
               (let ((r (get* port "GET /b HTTP/1.1" "Host: x")))
                 (is (= 503 (status-of r)))
                 (is (string= "1" (header-of r "Retry-After"))
                     "and it says when to come back"))
               (sb-thread:signal-semaphore gate)
               (is (= 200 (status-of (%join-client parked)))))))
      (sb-thread:signal-semaphore gate 10)
      (pool:stop-pool p))))

;;; --- a streamed body (pre-publication issue 117 M2) ---------------------------------------------
;;;
;;; The framing assertions matter more here than anywhere else in this file. A fixed-length
;;; response that is wrong is one wrong response; a chunked one that is wrong DESYNCHRONISES
;;; the connection, so every request after it is answered against garbage. And the failure
;;; is invisible in a single exchange -- which is why these read the wire rather than the
;;; parsed body, and assert the terminator explicitly.

(defun stream-app (&rest chunks)
  "An app whose body is a FUNCTION -- hyperion's streaming shape."
  (lambda (env)
    (declare (ignore env))
    (list 200 (list :content-type "text/plain; charset=utf-8")
          (lambda (writer) (dolist (c chunks) (funcall writer c))))))

(defun chunk-sizes (response)
  "The declared size of each chunk, in order, read off the wire as hex."
  (let ((body (body-of response)) (sizes '()) (i 0))
    (loop
      (let ((eol (search +crlf+ body :start2 i)))
        (unless eol (return))
        (let ((n (parse-integer body :start i :end eol :radix 16 :junk-allowed t)))
          (unless n (return))
          (push n sizes)
          (when (zerop n) (return))
          (setf i (+ eol 2 n 2)))))
    (nreverse sizes)))

(test a-streamed-body-is-chunked-and-carries-no-length
  (with-server (port (stream-app "alpha" "beta"))
    (let ((r (stream-get port "GET / HTTP/1.1" "Host: x")))
      (is (= 200 (status-of r)))
      (is (string-equal "chunked" (header-of r "Transfer-Encoding")))
      (is-false (header-of r "Content-Length")
                "a length beside chunked framing is two framings that disagree"))))

(test each-chunk-declares-the-length-that-follows-it
  "The invariant ENCODE-HEAD enforces once per response, now once per chunk. Read off the
wire rather than trusted: a size that disagrees with its octets desynchronises everything
after it on the connection."
  (with-server (port (stream-app "alpha" "bb" "0123456789012345"))
    (let ((r (stream-get port "GET / HTTP/1.1" "Host: x")))
      (is (equal '(5 2 16 0) (chunk-sizes r))
          "three chunks of the right sizes, then the terminator"))))

(test a-streamed-body-ends-with-the-terminating-chunk
  "Its absence is not a missing byte, it is a hung client: the peer waits for a chunk that
never comes."
  (with-server (port (stream-app "x"))
    (let ((r (stream-get port "GET / HTTP/1.1" "Host: x")))
      (is-true (search (concatenate 'string +crlf+ "0" +crlf+ +crlf+) (body-of r))
               "the zero-length chunk and the empty trailer section"))))

(test an-empty-write-is-a-no-op-and-not-the-end-of-the-stream
  "THE ONE THAT WOULD BE FOUND IN PRODUCTION. A handler yielding an empty string is an
ordinary accident; writing it as a chunk would end the response while the server believed it
was still streaming, and everything after would be read as the next message."
  (with-server (port (stream-app "a" "" "b" nil "c"))
    (let ((r (stream-get port "GET / HTTP/1.1" "Host: x")))
      (is (equal '(1 1 1 0) (chunk-sizes r))
          "the empty and NIL writes produced no chunk at all, and did not terminate")
      (is-true (search "a" (body-of r)))
      (is-true (search "c" (body-of r)) "the stream continued past the empty write"))))

(test a-multibyte-chunk-declares-its-OCTET-length-not-its-character-count
  "A size in characters would be short by the continuation bytes, and the client would read
the next chunk's size line out of the middle of this one's data."
  (with-server (port (stream-app "n" (string (code-char 233))))
    (let ((r (stream-get port "GET / HTTP/1.1" "Host: x")))
      (is (equal '(1 2 0) (chunk-sizes r))
          "U+00E9 is two octets in UTF-8, and the size line has to say two"))))

(test a-body-that-signals-midstream-truncates-rather-than-completing
  "Once a 200 is on the wire there is no status left to change: the only honest report is a
message that never ends properly. Completing it would tell the client the response was
whole, which is the failure -- a silent truncation the application believes it delivered."
  (with-server (port (lambda (env)
                       (declare (ignore env))
                       (list 200 +ok+ (lambda (writer)
                                        (funcall writer "partial")
                                        (error "boom")))))
    (let ((r (stream-get port "GET / HTTP/1.1" "Host: x")))
      (is (= 200 (status-of r)) "the head was already written; it cannot become a 500")
      (is-true (search "partial" (body-of r)))
      (is-false (search (concatenate 'string +crlf+ "0" +crlf+ +crlf+) (body-of r))
                "NO terminator -- the client must see this as truncated, not complete"))))

(test a-streamed-response-refuses-a-header-it-would-not-send
  "Response splitting does not become safe because the body is streamed, and refusing is
still possible HERE -- the head has not been written yet, so it can still become a 500."
  (with-server (port (lambda (env)
                       (declare (ignore env))
                       (list 200 (list :x-evil (format nil "a~AbSet-Cookie: c=1" +cr+))
                             (lambda (writer) (funcall writer "never")))))
    (let ((r (get* port "GET / HTTP/1.1" "Host: x")))
      (is (= 500 (status-of r)))
      (is-false (search "never" r) "and nothing the body would have written reached the wire"))))

(test a-connection-survives-a-stream-and-serves-the-next-request
  "The stream owns the connection until it ends, and then gives it back. Getting this wrong
in either direction is invisible in a single exchange: resuming early interleaves the next
response into this one, closing early truncates a stream that was fine."
  (with-server (port (lambda (env)
                       (if (string= "/stream" (getf env :path-info))
                           (list 200 +ok+ (lambda (writer) (funcall writer "streamed")))
                           (list 200 +ok+ '("plain")))))
    ;; Sequential rather than pipelined, and read with two DIFFERENT framings -- the first
    ;; response has no Content-Length to frame by and the second has no terminator. A
    ;; harness that used one reader for both could not tell a correct connection from a
    ;; desynchronised one, which is the only thing this test is for.
    (let ((sock (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
      (unwind-protect
           (sb-ext:with-timeout +io-timeout+
             (sock:socket-connect sock #(127 0 0 1) port)
             (let ((st (sock:socket-make-stream sock :input t :output t
                                                     :element-type '(unsigned-byte 8))))
               (flet ((send (line)
                        (write-sequence (sb-ext:string-to-octets
                                         (req line "Host: x") :external-format :latin-1)
                                        st)
                        (force-output st)))
                 (send "GET /stream HTTP/1.1")
                 (let ((first* (read-chunked-response st)))
                   (is-true (search "streamed" first*))
                   (is-true (search (concatenate 'string +crlf+ "0" +crlf+ +crlf+) first*)
                            "the stream ended properly, so the connection is ours again"))
                 (send "GET /plain HTTP/1.1")
                 (let ((second* (read-response st)))
                   (is (= 200 (status-of second*)))
                   (is (string= "plain" (body-of second*))
                       "the second response is the second request's, whole -- not a
fragment of the first, and not offset by a terminator nobody consumed")))))
        (ignore-errors (sock:socket-close sock))))))

;;; --- the one streaming case that is never correct --------------------------

(defun sse-app ()
  (lambda (env)
    (declare (ignore env))
    (list 200 (list :content-type "text/event-stream")
          (lambda (writer) (funcall writer "data: x")))))

(test an-sse-stream-is-refused-on-the-loop-thread
  "A finite body on the loop thread is a documented cost and the author's call. An SSE body
NEVER RETURNS, so under the inline dispatcher the loop stops accepting connections forever
-- and the symptom, `the whole server went unresponsive', points nowhere near the handler
that did it. So the always-wrong case is refused rather than documented, exactly as a
zero-length chunk is."
  (with-server (port (sse-app))
    (is (= 500 (status-of (get* port "GET / HTTP/1.1" "Host: x")))
        "refused BEFORE the head, so it can still be a status rather than a truncation")))

(test the-same-sse-stream-is-served-once-a-pool-is-dispatching
  "The refusal is about WHERE the body runs, not about SSE -- so it must lift when that
changes. Without this the previous test is satisfied by a server that never streams SSE at
all, which is a different and much worse thing to have built."
  ;; SETF-and-restore, not a dynamic binding. The server runs on its own loop thread, which
  ;; would not see a LET of a special made in this one -- the binding would be invisible
  ;; exactly where it is read, and the test would report the refusal it was written to
  ;; disprove. (It did, once: a false NEGATIVE that looks exactly like a true positive, in a
  ;; test whose whole job is to tell those apart. It would have "confirmed" the guard while
  ;; proving nothing about it.)
  ;;
  ;; %SRV-WITH-GLOBALS in hyperion/tests/server-tests.lisp exists for this same reason and
  ;; says so; this suite has no equivalent, which is why the trap was still here to fall
  ;; into.
  (let ((pool (pool:make-pool :size 2))
        (previous srv:*dispatch*))
    (unwind-protect
         (progn
           (setf srv:*dispatch* (srv:pool-dispatch pool))
           (with-server (port (sse-app))
             (let ((r (stream-get port "GET / HTTP/1.1" "Host: x")))
               (is (= 200 (status-of r)))
               (is-true (search "data: x" r) "~S" r))))
      (setf srv:*dispatch* previous)
      (pool:stop-pool pool))))

(test a-finite-stream-is-still-served-on-the-loop-thread
  "The refusal is narrow ON PURPOSE. A streamed body that ends is legitimate under the
inline dispatcher and must stay that way, or the guard has quietly outlawed streaming."
  (with-server (port (stream-app "a" "b"))
    (is (= 200 (status-of (stream-get port "GET / HTTP/1.1" "Host: x"))))))

;;; --- SSE end to end: feed -> records -> chunks -> socket -------------------

(defun read-until (stream marker &key (limit 4096))
  "Read from STREAM until MARKER has been seen COUNT times or LIMIT octets have arrived.

An SSE stream NEVER ENDS, so no framing rule can tell a test when to stop -- it has to stop
on what it came to see. LIMIT is the guard that turns a hung server into a failed assertion
instead of a suite that never returns."
  (let ((seen (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)))
    (dotimes (i limit)
      (let ((b (read-byte stream nil nil)))
        (unless b (return))
        (vector-push-extend (code-char b) seen)
        (when (search marker seen) (return))))
    (coerce seen 'string)))

(test an-sse-feed-reaches-the-socket-as-chunked-records
  "The whole path in one test: a feed coalescing per key, a subscription's rate, SSE records,
chunked framing, a real socket. Each layer is tested on its own; this is the one that fails
if two of them disagree about who writes what."
  (let ((pool (pool:make-pool :size 2))
        (previous srv:*dispatch*)
        (prices (feed:make-feed)))
    (unwind-protect
         (progn
           (setf srv:*dispatch* (srv:pool-dispatch pool))
           (feed:publish prices :acme 101)
           (with-server (port (lambda (env)
                                (declare (ignore env))
                                (sse:sse-response
                                 (feed:subscribe prices :hz 50)
                                 :event "price"
                                 :render (lambda (p) (format nil "~A=~A" (car p) (cdr p))))))
             (let ((sock (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
               (unwind-protect
                    (sb-ext:with-timeout +io-timeout+
                      (sock:socket-connect sock #(127 0 0 1) port)
                      (let ((st (sock:socket-make-stream sock :input t :output t
                                                              :element-type '(unsigned-byte 8))))
                        (write-sequence (sb-ext:string-to-octets
                                         (req "GET /events HTTP/1.1" "Host: x")
                                         :external-format :latin-1)
                                        st)
                        (force-output st)
                        (let ((got (read-until st "ACME=101")))
                          (is-true (search "text/event-stream" got) "~S" got)
                          (is-true (search "Transfer-Encoding: chunked" got))
                          (is-false (search "Content-Length" got))
                          (is-true (search "event: price" got)
                                   "the record reached the wire, fields and all")
                          (is-true (search "ACME=101" got)))))
                 (ignore-errors (sock:socket-close sock))))))
      (setf srv:*dispatch* previous)
      (pool:stop-pool pool))))


;;; --- work submitted to a loop that is going away (pre-publication issue 296) --------------------
;;;
;;; THE SUITE PASSED WITHOUT ANY OF THIS, which was the finding. No call site handled
;;; LOOP-CLOSED and every test still went green -- meaning nothing here reached a
;;; teardown-race submit, the exact case that produced the modal assertion in pre-publication issue 291. A
;;; refusal nothing reaches is indistinguishable from a refusal that does not work.
;;;
;;; These reach it deterministically rather than by racing: close the loop first, THEN
;;; submit. The race itself is not tested here and should not be -- a green run of a race
;;; proves nothing, and the five-run evidence for the fix belongs with the fix (pre-publication PR 297).

(test on-loop-drops-work-for-a-loop-that-is-closing
  (let ((loop (uv:make-loop))
        (ran nil))
    (uv:close-loop loop)
    (is (null (srv::%on-loop loop (lambda () (setf ran t)) "a test thunk"))
        "a closed loop must report the drop as NIL rather than signalling")
    (is (null ran)
        "and the thunk must not have run -- a drop that runs the work anyway is not a drop")))

(test on-loop-runs-work-for-a-loop-that-is-alive
  ;; THE CONTROL. Without it, an %ON-LOOP that refused everything unconditionally would
  ;; pass the test above.
  (let ((loop (uv:make-loop)))
    (unwind-protect
         (progn
           (uv:start-loop-thread loop)
           (let ((done (bt:make-semaphore)))
             (is (eq t (srv::%on-loop loop (lambda () (bt:signal-semaphore done))
                                      "a test thunk"))
                 "a live loop must accept the work")
             (is-true (bt:wait-on-semaphore done :timeout 5)
                      "and the thunk must actually run on the loop thread")))
      (uv:close-loop loop))))

(test stop-survives-a-loop-that-is-already-closed
  ;; STOP submits the listener close. Once SUBMIT signals on a closed loop, a STOP that
  ;; did not expect it would fail exactly when it has least left to do -- and STOP's own
  ;; docstring claims it is idempotent.
  (let ((server (srv:start (const-app 200 +ok+ (list "x")) :port 0)))
    (uv:close-loop (srv::server-loop server))     ; close it out from under STOP
    (finishes (srv:stop server))
    (finishes (srv:stop server))))
;;; --- a static file, which is a PATHNAME body (pre-publication issue 273) ------------------------
;;;
;;; hyperion/static returns a PATHNAME for every file it serves -- its own comment calls
;;; that "the Clack contract for static files", because Woo and Hunchentoot sendfile it and
;;; set Content-Length themselves. %BODY-OCTETS had no pathname clause, so on :uv every
;;; static file was a type error and a 500. It stayed invisible because hyperion/assets
;;; returns an octet vector, so the embedded-asset path works and nobody noticed.
;;;
;;; An ADR-0017 precondition: static files are what an app hits FIRST on :uv, so this is
;;; the difference between the flip working and every stylesheet 500ing on page load.

(defmacro %with-static-dir ((dir file content) &body forms)
  "A real directory holding a real FILE with CONTENT, deleted afterwards."
  (let ((stamp (gensym "STAMP")))
    `(let* ((,stamp (uiop:tmpize-pathname
                     (merge-pathnames "uv-static" (uiop:temporary-directory))))
            (,dir (uiop:ensure-directory-pathname ,stamp)))
       (ignore-errors (delete-file ,stamp))
       (ensure-directories-exist ,dir)
       (let ((,file (merge-pathnames "hello.txt" ,dir)))
         (with-open-file (out ,file :direction :output :if-exists :supersede)
           (write-string ,content out))
         (unwind-protect (progn ,@forms)
           (ignore-errors (delete-file ,file))
           (ignore-errors (uiop:delete-empty-directory ,dir)))))))

(test a-static-file-is-served-with-its-bytes
  (let ((content "Hello from a real file on disk, served by the native server."))
    (%with-static-dir (dir file content)
      (is (uiop:file-exists-p file)
          "precondition: the fixture wrote a real file to disk")
      (with-server (port (lambda (env)
                           (or (static:file-response dir (getf env :path-info) :env env)
                               (list 404 +ok+ (list "not found")))))
        (let ((r (get* port "GET /hello.txt HTTP/1.1" "Host: x")))
          (is (= 200 (status-of r))
              "a static file must not 500 on :uv -- got ~S" (status-of r))
          ;; THE BYTES, not the status. A 200 with an empty body passes a status-only
          ;; test and is exactly the shape a pathname clause gets wrong.
          (is (string= content (body-of r))
              "the file's bytes must arrive; got ~S" (body-of r))
          (is (string= (princ-to-string (length content))
                       (or (header-of r "Content-Length") ""))
              "Content-Length must be the file's length -- static does not set it, the
backend does"))))))

(test a-static-binary-file-arrives-byte-for-byte
  ;; The clause reads OCTETS. A text-mode read would mangle every byte above 127, and this
  ;; serves images -- where the corruption is invisible in a status code and obvious to a
  ;; browser. All 256 values, so no encoding can round-trip it by accident.
  (let* ((stamp (uiop:tmpize-pathname (merge-pathnames "uv-bin" (uiop:temporary-directory))))
         (dir (uiop:ensure-directory-pathname stamp))
         (bytes (make-array 256 :element-type '(unsigned-byte 8))))
    (ignore-errors (delete-file stamp))
    (ensure-directories-exist dir)
    (dotimes (i 256) (setf (aref bytes i) i))
    (let ((file (merge-pathnames "blob.bin" dir)))
      (with-open-file (out file :direction :output :element-type '(unsigned-byte 8)
                                :if-exists :supersede)
        (write-sequence bytes out))
      (unwind-protect
           (with-server (port (lambda (env)
                                (or (static:file-response dir (getf env :path-info) :env env)
                                    (list 404 +ok+ (list "not found")))))
             (let* ((r (get* port "GET /blob.bin HTTP/1.1" "Host: x"))
                    (got (body-of r)))
               (is (= 200 (status-of r)))
               (is (= 256 (length got)) "every byte must arrive, got ~D" (length got))
               ;; The client reads latin-1, so octet N is character code N exactly.
               (is (loop for i below 256 always (= i (char-code (char got i))))
                   "the bytes must arrive unchanged, in order")))
        (ignore-errors (delete-file file))
        (ignore-errors (uiop:delete-empty-directory dir))))))

;;; --- a large static file, in bounded pieces (pre-publication issue 313) --------------------------
;;;
;;; pre-publication issue 273 gave %BODY-OCTETS its pathname clause, which is what makes static files work on
;;; :uv at all. It reads the file WHOLE, and %WRITE-RESPONSE then concatenates head and body
;;; into one buffer, so a file of size N transiently costs about 2N. pre-publication issue 273 said so at the
;;; time and said this half was not covered, which is why it is a separate ticket rather
;;; than a regression.
;;;
;;; The bounded path has to keep the two properties the chunked path would have cost:
;;; Content-Length is still there (a static file is the one response whose size is known
;;; before a byte is written), and the bytes still arrive unchanged. What it adds is that
;;; memory does not scale with the file -- which is a claim about BEHAVIOUR, so it is
;;; measured through *FILE-WRITE-OBSERVER* rather than argued from the shape of the code.

(defmacro with-file-knobs ((&key chunk observer) &body forms)
  "Set *FILE-CHUNK-BYTES* / *FILE-WRITE-OBSERVER* for FORMS, restoring both afterwards.

SETF, NOT LET, and the difference decides whether these tests test anything. The server
reads both of these ON ITS OWN THREAD -- a write callback runs on the loop thread -- and a
dynamic binding established here is visible only to this one. Every assertion below would
have passed against the defaults, which is the shape of a test that cannot fail."
  (let ((old-chunk (gensym "OLD-CHUNK")) (old-observer (gensym "OLD-OBSERVER")))
    `(let ((,old-chunk srv:*file-chunk-bytes*)
           (,old-observer srv:*file-write-observer*))
       (unwind-protect
            (progn
              ,@(when chunk `((setf srv:*file-chunk-bytes* ,chunk)))
              ,@(when observer `((setf srv:*file-write-observer* ,observer)))
              ,@forms)
         (setf srv:*file-chunk-bytes* ,old-chunk
               srv:*file-write-observer* ,old-observer)))))

(defmacro with-file-of-size ((dir file size &key (name "big.bin")) &body forms)
  "A real directory holding a real FILE of SIZE octets, byte N being (mod N 251) -- a prime
so no run of 256 repeats and a swapped or duplicated block is visible. Deleted afterwards."
  (let ((stamp (gensym "STAMP")) (out (gensym "OUT")) (i (gensym "I")))
    `(let* ((,stamp (uiop:tmpize-pathname
                     (merge-pathnames "uv-bigfile" (uiop:temporary-directory))))
            (,dir (uiop:ensure-directory-pathname ,stamp)))
       (ignore-errors (delete-file ,stamp))
       (ensure-directories-exist ,dir)
       (let ((,file (merge-pathnames ,name ,dir)))
         (declare (ignorable ,file))
         (with-open-file (,out ,file :direction :output :element-type '(unsigned-byte 8)
                                     :if-exists :supersede)
           (let ((buf (make-array ,size :element-type '(unsigned-byte 8))))
             (dotimes (,i ,size) (setf (aref buf ,i) (mod ,i 251)))
             (write-sequence buf ,out)))
         (unwind-protect (progn ,@forms)
           (ignore-errors (delete-file ,file))
           (ignore-errors (uiop:delete-empty-directory ,dir)))))))

(defun static-app (dir)
  (lambda (env)
    (or (static:file-response dir (getf env :path-info) :env env)
        (list 404 +ok+ (list "not found")))))

(defun octets-received (port request)
  "Send REQUEST on its own connection. Returns (values head-text body-octet-count body-octets
peer-closed-p).

Reads the body ONE OCTET AT A TIME until Content-Length is satisfied or the peer closes,
and returns the count it actually read. READ-SEQUENCE would leave the rest of the buffer
holding whatever it held, so a body that came up SHORT would be indistinguishable from a
complete one -- the defect this file's own client comment warns about, in the one test that
is about exactly that difference."
  (let ((s (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (sb-ext:with-timeout +io-timeout+
           (sock:socket-connect s #(127 0 0 1) port)
           (let ((stream (sock:socket-make-stream s :input t :output t
                                                    :element-type '(unsigned-byte 8))))
             (write-sequence (sb-ext:string-to-octets request :external-format :latin-1)
                             stream)
             (force-output stream)
             (let* ((head (%read-head stream))
                    (text (sb-ext:octets-to-string
                           (coerce head '(vector (unsigned-byte 8)))
                           :external-format :latin-1))
                    (declared (header-of text "Content-Length"))
                    (n (if declared (parse-integer declared) 0))
                    (body (make-array 0 :element-type '(unsigned-byte 8)
                                        :adjustable t :fill-pointer 0))
                    (closed nil))
               (loop repeat n
                     for b = (read-byte stream nil nil)
                     do (if b (vector-push-extend b body) (progn (setf closed t) (return))))
               (values text (fill-pointer body) body closed))))
      (ignore-errors (sock:socket-close s)))))

(test a-large-static-file-arrives-whole-with-its-length
  "The two properties the chunked path would have cost: every byte, and Content-Length."
  (let ((size (+ (* 1024 1024) 12345)))     ; not a multiple of the chunk size
    (with-file-of-size (dir file size)
      (is (= size (with-open-file (in file :element-type '(unsigned-byte 8))
                    (file-length in)))
          "precondition: the fixture wrote a file of the size it claims")
      (with-server (port (static-app dir))
        (multiple-value-bind (head got body closed)
            (octets-received port (req "GET /big.bin HTTP/1.1" "Host: x"))
          (is (= 200 (status-of head)))
          (is (string= (princ-to-string size) (or (header-of head "Content-Length") ""))
              "Content-Length must still be the file's length -- keeping it is the whole
reason this is not the chunked path")
          (is-false closed "the body must arrive in full, not end in a closed socket")
          (is (= size got) "every declared octet must arrive; got ~D of ~D" got size)
          (is (loop for i below size always (= (mod i 251) (aref body i)))
              "and the bytes must be the file's, in order"))))))

(test a-large-static-file-is-never-held-whole-in-memory
  "The point of pre-publication issue 313. Measured, not argued: the largest piece the response ever put in
flight, against the size of the file it served."
  (let ((size (* 512 1024))
        (chunk 8192)
        (pieces '()))
    (with-file-of-size (dir file size)
      (with-file-knobs (:chunk chunk :observer (lambda (n) (push n pieces)))
        (with-server (port (static-app dir))
          (multiple-value-bind (head got) (octets-received port (req "GET /big.bin HTTP/1.1"
                                                                    "Host: x"))
            (is (= 200 (status-of head)))
            (is (= size got) "the file still arrives whole"))))
      (let ((largest (reduce #'max pieces :initial-value 0))
            (total (reduce #'+ pieces :initial-value 0)))
        (is (= size total) "the pieces must account for exactly the file: ~D of ~D"
            total size)
        (is (<= largest chunk)
            "no piece may exceed the chunk bound; largest was ~D against ~D" largest chunk)
        (is (>= (/ size largest) 50)
            "memory must not scale with the file: ~D octets served, ~D held at once"
            size largest)
        ;; THE CONTROL. The same measurement on the path this replaces returns the file's
        ;; SIZE, so the instrument above can see the failure it is asserting the absence of
        ;; -- without this line, "largest <= chunk" is satisfied by an observer nobody calls.
        (is (= size (length (hyperion/server-uv::%body-octets file)))
            "the whole-file path holds the whole file, which is what makes the number above
a measurement rather than a shape")))))

(test a-small-static-file-is-still-exactly-one-write
  "Head and first piece are coalesced, so a stylesheet costs one write as it did before.
Two small writes would be two segments, and the second is the write Nagle holds -- the 44 ms
defect ADR-0011 measured."
  (let ((writes 0))
    (with-file-of-size (dir file 64 :name "small.css")
      (with-file-knobs (:observer (lambda (n) (declare (ignore n)) (incf writes)))
        (with-server (port (static-app dir))
          (multiple-value-bind (head got) (octets-received port (req "GET /small.css HTTP/1.1"
                                                                    "Host: x"))
            (is (= 200 (status-of head)))
            (is (= 64 got))))))
    (is (= 1 writes) "one body write for a file that fits in one piece; got ~D" writes)))

(test a-static-file-leaves-the-connection-reusable
  "The file path owns the connection until its last piece settles, then resumes it. If it
resumed early the second request would be answered underneath the first response; if it
never resumed, this would hang until the idle timeout."
  (let ((size (* 300 1024)))
    (with-file-of-size (dir file size)
      (with-file-knobs (:chunk 4096)
        (with-server (port (static-app dir))
          (let ((responses (converse port (list (req "GET /big.bin HTTP/1.1" "Host: x")
                                                (req "GET /big.bin HTTP/1.1" "Host: x"))
                                     :responses 2)))
            (is (= 2 (length responses)))
            (is (every (lambda (r) (= 200 (status-of r))) responses)
                "both requests on one connection must be answered")
            (is (every (lambda (r) (= size (length (body-of r)))) responses)
                "and each with the whole file")
            ;; THE BYTES, not the length, and this is the assertion that catches the defect
            ;; this test found: with the second request served mid-body, the first response
            ;; was still 307200 octets long and its 4097th octet was the second response's
            ;; head. A length-only check passes against a body that has been overwritten.
            (is (every (lambda (r)
                         (let ((b (body-of r)))
                           (loop for i below (length b)
                                 always (= (mod i 251) (char-code (char b i))))))
                       responses)
                "and the bytes of each must be the file's, not another response's")))))))

(test a-file-that-grows-under-us-never-sends-more-than-it-declared
  "Content-Length is a claim made when the file was opened, and the file belongs to whoever
else has it open too. A file that GROWS mid-response must not put the extra octets after the
body -- the client is counting, so it would read them as the next response's head. That is
response smuggling with the filesystem supplying the second half."
  (let* ((size (* 256 1024))
         (grown nil))
    (with-file-of-size (dir file size)
      (with-file-knobs
          (:chunk 4096
           :observer (lambda (n)
                       (declare (ignore n))
                       (unless grown
                         (setf grown t)
                         ;; APPEND, so it is the same inode the server has open -- a
                         ;; :supersede would write a new file and leave the server reading
                         ;; the original, and the test would pass without testing anything.
                         (with-open-file (out file :direction :output
                                                   :element-type '(unsigned-byte 8)
                                                   :if-exists :append)
                           (write-sequence (make-array (* 64 1024)
                                                       :element-type '(unsigned-byte 8)
                                                       :initial-element 255)
                                           out)))))
        (with-server (port (static-app dir))
          ;; Two requests on ONE connection: the second is the assertion that nothing extra
          ;; was left on the wire. A stray octet after the first body would be parsed as the
          ;; start of the second request and the answer would not be a 200.
          (let ((responses (converse port (list (req "GET /big.bin HTTP/1.1" "Host: x")
                                                (req "GET /big.bin HTTP/1.1" "Host: x"))
                                     :responses 2)))
            (is-true grown "control: the file really did grow while the response was running")
            (is (= size (length (body-of (first responses))))
                "exactly the declared octets, not the file's new length")
            (is (= 200 (status-of (second responses)))
                "and the connection is still synchronised: the next request gets a response,
which it could not if extra octets had been written after the body")))))
    (is-true grown)))

(test a-short-file-body-closes-the-connection-rather-than-lying
  "The other direction, and the one a test cannot stage over a socket: a file that SHRANK
leaves the body short of the Content-Length already on the wire. The message we promised is
not the message we sent, so the connection cannot be reused -- a client counting the declared
octets would read the next response's head as this body's tail. %FILE-OUTCOME is the
decision, separated out so the case is reachable without staging a filesystem race; the
socket-level answer to :SHORT is %CLOSE-AFTER, the same close an aborted chunked body gets."
  (let ((short (hyperion/server-uv::%make-file-out :declared 1000 :written 400
                                                   :keep-alive t))
        (whole-keep (hyperion/server-uv::%make-file-out :declared 1000 :written 1000
                                                        :keep-alive t))
        (whole-close (hyperion/server-uv::%make-file-out :declared 1000 :written 1000
                                                         :keep-alive nil)))
    (is (eq :short (hyperion/server-uv::%file-outcome short))
        "a short body is short even when keep-alive was granted -- the truncation decides")
    (is (eq :keep (hyperion/server-uv::%file-outcome whole-keep))
        "a complete body on a keep-alive connection keeps it")
    (is (eq :close (hyperion/server-uv::%file-outcome whole-close))
        "and a complete body on a closing connection closes it")))
