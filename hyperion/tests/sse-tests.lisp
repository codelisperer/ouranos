;;;; sse-tests.lisp --- the wire format, and the two ways it silently does nothing (pre-publication issue 117 M2).
;;;;
;;;; SSE is deceptively forgiving to write and unforgiving in exactly two places, and both
;;;; failures look like "the endpoint does nothing" rather than like an error:
;;;;
;;;;   THE TERMINATING BLANK LINE IS THE DELIVERY. A record without one is held by the
;;;;   browser, waiting for more fields. Every byte on the wire is correct and nothing ever
;;;;   fires.
;;;;
;;;;   AN IDLE STREAM IS INDISTINGUISHABLE FROM A DEAD ONE to every proxy in the path, so a
;;;;   feed that goes quiet has its connection closed by an intermediary that believes it is
;;;;   helping.
;;;;
;;;; ENCODE-EVENT is a pure function precisely so the first of those is a thing a test can
;;;; assert rather than a thing a person has to notice in a browser.

(in-package #:hyperion/tests)

(def-suite sse :description "Server-Sent Events over a feed (ADR-0016, pre-publication issue 117 M2)." :in hyperion)
(in-suite sse)

(defun %sse-lines (record) (uiop:split-string record :separator (string #\Newline)))

;;; --- the wire format -------------------------------------------------------

(test a-record-ends-with-a-blank-line
  "THE most common way a hand-rolled SSE endpoint fails, and it is invisible: without the
blank line the browser holds the record and the endpoint appears to do nothing."
  (let ((r (sse:encode-event "hello")))
    (is (string= (format nil "data: hello~%~%") r))
    (is-true (and (> (length r) 1)
                  (char= #\Newline (char r (1- (length r))))
                  (char= #\Newline (char r (- (length r) 2))))
             "the record is terminated, not merely newline-ended")))

(test multi-line-data-becomes-one-data-line-each
  "A newline in DATA is legitimate and MEANS something -- the browser rejoins the parts. So
it is split rather than refused: the splitting IS the encoding, not an escape."
  (let ((r (sse:encode-event (format nil "one~%two~%three"))))
    (is (equal '("data: one" "data: two" "data: three" "" "") (%sse-lines r)))))

(test the-optional-fields-are-written-in-the-order-a-parser-expects
  (let ((r (sse:encode-event "v" :event "tick" :id "7" :retry 3000)))
    (is (equal '("event: tick" "id: 7" "retry: 3000" "data: v" "" "") (%sse-lines r)))))

(test empty-data-still-gets-its-data-line
  "A record of only an ID is legal and means `set Last-Event-ID and fire nothing' -- which is
never what a caller passing data meant."
  (is (string= (format nil "data:~%~%") (sse:encode-event ""))))

;;; --- field injection, which is response splitting one layer up -------------

(test a-newline-in-an-event-name-or-id-is-refused
  "These fields are single-line BY DEFINITION, so a newline ends one and starts another: an
id built from user input could inject `event:' or terminate the record and forge a second
one. Refused, never stripped -- stripping leaves the caller shipping something subtly
different from what it asked for."
  (signals sse:sse-field-unsafe
    (sse:encode-event "v" :event (format nil "a~%event: forged")))
  (signals sse:sse-field-unsafe
    (sse:encode-event "v" :id (format nil "1~%data: forged")))
  (signals sse:sse-field-unsafe
    (sse:encode-event "v" :id (format nil "1~Ax" (code-char 13))))
  (signals sse:sse-field-unsafe
    (sse:encode-event "v" :id (format nil "1~Ax" (code-char 0)))))

(test the-same-newline-in-DATA-is-not-refused
  "The control, and the point of the distinction: refusing here would break the format."
  (finishes (sse:encode-event (format nil "a~%b"))))

(test a-comment-is-a-legal-record-that-fires-nothing
  (is (string= (format nil ": ~%~%") (sse:comment)))
  (is (string= (format nil ": ping~%~%") (sse:comment "ping")))
  (signals sse:sse-field-unsafe (sse:comment (format nil "a~%data: forged"))))

;;; --- the response ----------------------------------------------------------

(test an-sse-response-is-an-ordinary-three-list-with-a-streaming-body
  "The whole reason the streaming convention keeps the response shape: every interceptor and
middleware in the tree handles this without knowing what it is."
  (let* ((f (feed:make-feed))
         (r (sse:sse-response (feed:subscribe f :hz 10))))
    (is (= 3 (length r)))
    (is (= 200 (first r)))
    (is-true (functionp (third r)) "the body is a stream, not a sequence")
    (is (string= "text/event-stream; charset=utf-8" (getf (second r) :content-type)))
    (is (string= "no-cache" (getf (second r) :cache-control)))
    (is-false (getf (second r) :content-length)
              "a length beside a stream is two framings that disagree")))

(test the-response-headers-are-copied-not-shared
  "A handler that pushed onto the returned plist would otherwise edit every future SSE
response in the image."
  (let* ((f (feed:make-feed))
         (a (second (sse:sse-response (feed:subscribe f :hz 10))))
         (b (second (sse:sse-response (feed:subscribe f :hz 10)))))
    (is-false (eq a b))))

;;; --- the pump --------------------------------------------------------------
;;;
;;; The body loops until the peer goes away, which the writer reports by signalling. These
;;; drive it with a writer that collects N chunks and then throws, which is the same shape
;;; the real one has and is what makes an endless loop testable at all.

(define-condition %sse-enough (error) ())

(defun %sse-collect (n)
  "A writer that collects up to N chunks and then ends the stream the way a departed peer
would."
  (let ((got '()) (left n))
    (values (lambda (chunk)
              (push chunk got)
              (when (<= (decf left) 0) (error '%sse-enough)))
            (lambda () (nreverse got)))))

(test one-event-per-changed-key-not-one-per-take
  "EventSource dispatches per RECORD, so a client handed a batch would be reimplementing the
framing. The coalescing already happened in the feed; this is only how the survivors are
written."
  (let* ((f (feed:make-feed))
         (sub (feed:subscribe f :hz 1000)))
    (feed:publish f :a 1)
    (feed:publish f :b 2)
    (multiple-value-bind (writer result) (%sse-collect 2)
      (handler-case (funcall (sse:events sub :render (lambda (p) (format nil "~A=~A" (car p) (cdr p))))
                             writer)
        (%sse-enough () nil))
      (let ((records (funcall result)))
        (is (= 2 (length records)) "two keys changed, so two records")
        (is-true (every (lambda (r) (search (format nil "~%~%") r)) records)
                 "and each one is terminated, or the browser fires none of them")))))

(test a-superseded-value-is-never-sent-twice
  "The ADR-0016 property, asserted at this layer rather than assumed from the one below:
publishing a key twice before an emission sends the SECOND value, once."
  (let* ((f (feed:make-feed))
         (sub (feed:subscribe f :hz 1000)))
    (feed:publish f :k "old")
    (feed:publish f :k "new")
    (multiple-value-bind (writer result) (%sse-collect 1)
      (handler-case (funcall (sse:events sub) writer) (%sse-enough () nil))
      (let ((records (funcall result)))
        (is (= 1 (length records)) "one record, not two -- coalesced, not queued")
        (is-true (search "data: new" (first records)))
        (is-false (search "old" (first records)))))))

(test an-idle-stream-sends-a-keep-alive-comment
  "An idle connection is indistinguishable from a dead one to every proxy in the path, and
the usual timeout is well under a minute. FEED:TAKE names the moment -- (nil t), allowed but
nothing changed -- and this is the only point at which a keep-alive is both needed and
harmless."
  (let* ((f (feed:make-feed))
         (sub (feed:subscribe f :hz 1000))
         (sse:*keep-alive-seconds* 0))
    (multiple-value-bind (writer result) (%sse-collect 1)
      (handler-case (funcall (sse:events sub) writer) (%sse-enough () nil))
      (let ((records (funcall result)))
        (is (= 1 (length records)))
        (is-true (char= #\: (char (first records) 0))
                 "a comment: ignored by EventSource, and the smallest thing that proves the
stream is alive")))))
