;;;; sse.lisp --- Server-Sent Events over a feed, at the rate a subscriber asked for.
;;;;
;;;; The consumer ADR-0016 was written for. A feed holds the LATEST value per key and a
;;;; subscription declares how often it wants to hear; this turns that into the wire format
;;;; a browser's EventSource speaks, and into an ordinary hyperion streaming response --
;;;; (200 headers (lambda (writer) ...)) -- so it runs on the native server and, through
;;;; WRAP-STREAMING-BODY, on the Clack backends too.
;;;;
;;;; THE BACK-PRESSURE POLICY IS NOT HERE, AND THAT IS THE POINT. A slow consumer gets FEWER
;;;; UPDATES, never a backlog, because the feed underneath coalesces per key and the
;;;; subscription's rate decides when to emit. This file adds no queue of its own. If it
;;;; did, ADR-0016 would have been decided and then quietly undone one layer up -- which is
;;;; how a rejected policy usually arrives.
;;;;
;;;; WHAT SSE ACTUALLY IS, since the format is deceptively forgiving: a stream of records
;;;; separated by BLANK LINES, each a set of `field: value' lines. A record with no blank
;;;; line after it has not been delivered -- the browser is still waiting for it. That is
;;;; the single most common way a hand-rolled SSE endpoint fails: everything looks right on
;;;; the wire and nothing ever fires, because the terminating newline is missing.
;;;;
;;;; FIELD INJECTION IS THE SECURITY SURFACE, and it is response splitting one layer up.
;;;; A newline inside an event NAME or an ID ends that field and starts another, so an id
;;;; taken from user input could inject `event: ' or `retry: ' -- or terminate the record
;;;; early and forge a second one. Refused rather than sanitised, for the reason the response
;;;; encoder gives: stripping leaves the caller shipping something subtly different from what
;;;; it asked for, and refusing makes it a visible error in development.
;;;;
;;;; DATA IS DIFFERENT and must not be refused: a newline inside data is legitimate and
;;;; MEANS something -- it is emitted as another `data:' line and the browser rejoins the
;;;; parts with a newline. Splitting is the encoding, not an escape.

(cl:in-package #:hyperion/sse)

(defparameter *keep-alive-seconds* 15
  "How long an idle stream may go silent before a comment is sent to hold it open.

Not decoration. An idle SSE connection is indistinguishable from a dead one to every proxy
between the server and the browser, and the usual timeout is 30-60 seconds, so a feed that
goes quiet gets its connection closed by an intermediary that believes it is helping. A
comment line -- `:' and a newline -- is the smallest legal thing that proves the stream is
alive; EventSource ignores it entirely.

FEED:TAKE already names the moment: it returns (nil t) for `the rate allowed an emission
and nothing had changed', which is exactly when this matters.")

(defparameter *idle-poll-ms* 25
  "How long the pump sleeps when the subscription's rate says `not yet'.

A bound on busy-waiting, not a rate. The subscription owns the rate; this only decides how
finely the pump asks. Small enough that a 4 Hz subscriber is not late by a visible fraction
of its own interval, large enough that an idle stream is not a spinning worker.")

(define-condition sse-field-unsafe (error)
  ((field :initarg :field :reader sse-field-unsafe-field)
   (value :initarg :value :reader sse-field-unsafe-value))
  (:report
   (lambda (c s)
     (format s "hyperion/sse: a newline or NUL in the ~A field would forge a second record: ~S"
             (sse-field-unsafe-field c) (sse-field-unsafe-value c))))
  (:documentation
   "Signalled when an event NAME or ID contains CR, LF or NUL.

Response splitting, one layer up from the header encoder's version of it. These fields are
single-line by definition, so a newline in one ends it and begins another -- an id built
from user input could inject `event:' or terminate the record and forge a whole second
event. Refused, never stripped: see the file header."))

(defun %single-line-safe (field value)
  "VALUE as a single-line field value, or signal. CR, LF and NUL are the three characters
that end or truncate a field, which is the same set the response encoder refuses."
  (let ((s (princ-to-string value)))
    (when (find-if (lambda (c) (member (char-code c) '(0 10 13))) s)
      (error 'sse-field-unsafe :field field :value s))
    s))

(defun encode-event (data &key event id retry)
  "One SSE record as a string, terminated by the blank line that DELIVERS it.

DATA is split on newlines into one `data:' line each, because that is how the format carries
a multi-line payload -- the browser rejoins them with a newline. EVENT and ID are
single-line by definition and are REFUSED if they are not; see SSE-FIELD-UNSAFE.

A pure function of its arguments, so the wire format is testable without a socket, a server
or a browser -- which is what makes the format's one unforgiving rule (the terminating blank
line) something a test can assert rather than something a person has to notice."
  (with-output-to-string (out)
    (when event (format out "event: ~A~%" (%single-line-safe "event" event)))
    (when id (format out "id: ~A~%" (%single-line-safe "id" id)))
    (when retry (format out "retry: ~D~%" (round retry)))
    (let ((s (princ-to-string data)))
      ;; An EMPTY data payload still needs its `data:' line: a record of only an id is legal
      ;; and means "set the last-event-id and fire nothing", which is not what a caller
      ;; passing data ever means.
      (if (zerop (length s))
          (format out "data:~%")
          (let ((start 0))
            (loop for nl = (position #\Newline s :start start)
                  do (format out "data: ~A~%" (subseq s start (or nl (length s))))
                     (if nl (setf start (1+ nl)) (return))))))
    ;; THE BLANK LINE IS THE DELIVERY. Without it the browser holds the record, waiting for
    ;; more fields, and the endpoint appears to do nothing at all.
    (format out "~%")))

(defun comment (&optional (text ""))
  "A comment line: ignored by every EventSource, and the smallest legal keep-alive."
  (format nil ": ~A~%~%" (%single-line-safe "comment" text)))

(defparameter *headers*
  (list :content-type "text/event-stream; charset=utf-8"
        :cache-control "no-cache"
        ;; nginx buffers proxied responses by default, which for a stream means the browser
        ;; receives nothing until the buffer fills -- an endpoint that works locally and is
        ;; silent behind the reverse proxy it is deployed under. The header is nginx's own
        ;; opt-out and is ignored by everything else, which is a cheap price for the one
        ;; deployment failure this surface reliably produces.
        :x-accel-buffering "no")
  "The headers every SSE response needs.

No Connection and no Content-Length: the response encoder writes the framing itself and
DROPS a caller-supplied one, precisely so the header block cannot disagree with the bytes.")

(defun events (subscription &key event id-for retry (render #'cdr))
  "A streaming BODY -- (lambda (writer) ...) -- that emits SUBSCRIPTION's changes as SSE.

Returns the body function; pair it with *HEADERS* or use SSE-RESPONSE. It runs until the
peer goes away, which the writer reports by signalling: a stream ends when its reader
leaves, and there is nothing else for it to wait for.

ONE EVENT PER CHANGED KEY, not one per TAKE. A coalesced change set of thirty symbols is
thirty records, because EventSource dispatches per record and a client that had to unpack a
batch would be reimplementing the framing. The COALESCING already happened in the feed --
this is only how the survivors are written.

RENDER turns a (key . value) pair into the data payload; the default sends the value.
ID-FOR, if given, is called on the pair for the event's id -- which is what makes
Last-Event-ID work, and is the caller's because only the application knows what its ids
mean. EVENT names every record; RETRY sets the browser's reconnection delay once, on the
first record, since it is a property of the stream rather than of an event."
  (lambda (writer)
    (let ((deadline (+ (get-universal-time) *keep-alive-seconds*))
          (first t))
      (loop
        (multiple-value-bind (changes ready) (feed:take subscription)
          (cond
            (changes
             (dolist (pair changes)
               (funcall writer
                        (encode-event (funcall render pair)
                                      :event event
                                      :id (and id-for (funcall id-for pair))
                                      :retry (and first retry)))
               (setf first nil))
             (setf deadline (+ (get-universal-time) *keep-alive-seconds*)))
            ;; READY and no changes is the idle case FEED:TAKE names, and the only moment a
            ;; keep-alive is both needed and harmless.
            ((and ready (>= (get-universal-time) deadline))
             (funcall writer (comment))
             (setf deadline (+ (get-universal-time) *keep-alive-seconds*)))
            (t (sleep (/ *idle-poll-ms* 1000.0)))))))))

(defun sse-response (subscription &rest args &key event id-for retry render)
  "A complete hyperion response streaming SUBSCRIPTION as SSE:

  (sse:sse-response (feed:subscribe prices :hz 4))

An ordinary three-list, so every interceptor and middleware in the tree handles it without
knowing what it is -- the whole reason the streaming convention keeps the response shape.

A STREAMING APP NEEDS A WORKER POOL. server-uv REFUSES a text/event-stream response under
the inline dispatcher, because an SSE body never returns and would own the loop thread
forever. That refusal names POOL-DISPATCH, and it is the reason this cannot be started by
accident on a server that would be killed by it."
  (declare (ignore event id-for retry render))
  (list 200 (copy-list *headers*) (apply #'events subscription args)))
