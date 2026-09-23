;;;; server-uv.lisp --- accept, parse, call the handler, write (#117, commit 3).
;;;;
;;;; The effectful half. hyperion/http1 decides what a message IS; this owns the socket, the
;;;; buffer, the env and the error boundary. No Clack, no Hunchentoot, no Woo anywhere on
;;;; the path -- see docs/adr/0015-ring-calling-convention-without-clack.md.
;;;;
;;;; PERSISTENT CONNECTIONS, pipelining and 100-continue all land here (commit 4); see the
;;;; commentary above %MAX-REQUESTS-PER-CONNECTION for the two limits persistence made
;;;; necessary. Chunked transfer-encoding is still refused with 501 by the parser for a
;;;; REQUEST; a chunked RESPONSE is how a streamed body is written -- see the streaming
;;;; section below.
;;;;
;;;; WHERE THE HANDLER RUNS -- the decision, made once, in the open. It runs ON THE LOOP
;;;; THREAD, behind *DISPATCH*. That is right for the desktop-first target (ADR-0002 §4) and
;;;; wrong for a busy server, and the difference is not subtle:
;;;;
;;;;   ONE SLOW HANDLER STALLS EVERY CONNECTION. There is one loop thread. A handler that
;;;;   blocks for a second blocks every other request for that second.
;;;;
;;;;   ANYTHING THAT RE-ENTERS THE LOOP FROM INSIDE A HANDLER DEADLOCKS. An outbound
;;;;   aion/uv HTTP call from a handler is the natural thing an app will eventually try,
;;;;   and it is the thing that will hang. Use a plain blocking client, or wait for M2.
;;;;
;;;; *DISPATCH* exists from this commit rather than being retrofitted in M2, because a
;;;; dispatch point added later is a rewrite of the request path and added now is a funcall.
;;;;
;;;; THE ERROR BOUNDARY IS NOT THE CALLBACK GUARD, and getting this backwards is the failure
;;;; that would be hardest to see. UV:WITH-CALLBACK-GUARD absorbs a condition and returns nil
;;;; -- correct for a binding, whose job is to never let a Lisp condition unwind into C. At a
;;;; REQUEST boundary it is exactly wrong: the guard swallows the error, no response is ever
;;;; written, and the client waits until it times out. A hung request is worse than a crash
;;;; because nothing anywhere says it happened. So this file installs its own HANDLER-CASE
;;;; INSIDE the callback and ABOVE the guard, turning any condition into a 500 with a correct
;;;; Content-Length. The guard stays the backstop it was designed to be.

(cl:defpackage #:hyperion/server-uv
  (:use #:cl)
  (:local-nicknames (#:h1  #:hyperion/http1)
                    (#:uv  #:aion/uv)
                    (#:pool #:aion/pool)
                    (#:net #:aion/uv/net)
                    (#:bt  #:bordeaux-threads)
                    (#:log #:aion/log))
  (:documentation
   "A native HTTP/1.1 server on aion/uv: no Clack, no Hunchentoot, no Woo (#117, ADR-0015).

    START an app -- an ordinary Ring handler, (lambda (env) -> (status headers body)) --
    and STOP the server it returns. The env is the same nine keys every other hyperion
    backend supplies, so a handler cannot tell which server it is running under; that is
    the whole point of keeping the calling convention while dropping the library.

    A STREAMED BODY is a FUNCTION in body position -- (status headers (lambda (writer) ...))
    -- answered with chunked transfer-encoding. The response stays a three-list, so no
    middleware and no interceptor learns that streaming exists, and hyperion/server adapts
    the same shape onto Clack so an application cannot tell which backend it is on.

    The handler runs behind *DISPATCH*: on the loop thread by default, on a worker pool
    with POOL-DISPATCH. A streaming app wants the pool -- the file header says why.")
  (:export #:start #:stop #:pool-dispatch #:*busy-response*
           #:stream-write-failed #:stream-write-failed-reason
           #:*stream-write-timeout-seconds*
           #:*file-chunk-bytes* #:*file-write-observer*
           #:server #:server-p #:server-host #:server-port
           #:*dispatch* #:*max-body-octets*
           #:*max-requests-per-connection* #:*keep-alive-timeout-ms* #:*inline-dispatch*))

(in-package #:hyperion/server-uv)

;;; --- the body, as a stream, without a temp file ----------------------------
;;;
;;; Hyperion's env contract says :RAW-BODY is a STREAM -- http:parse-multipart and
;;; http:body-octets both READ-SEQUENCE from it. The existing tests fake one with a temp
;;; file, which is fine for a test and unacceptable per request. A Gray stream over the
;;; octets we already hold costs nothing and adds no dependency.

(defclass octet-input-stream (sb-gray:fundamental-binary-input-stream)
  ((octets :initarg :octets :reader %stream-octets)
   (index  :initform 0 :accessor %stream-index))
  (:documentation "A read-once binary input stream over an octet vector we already have."))

(defmethod cl:stream-element-type ((s octet-input-stream))
  ;; CL:, not SB-GRAY:. SB-GRAY inherits this name from COMMON-LISP rather than exporting
  ;; its own, so `sb-gray:stream-element-type' is a READ error -- and a read error, unlike
  ;; the rest of this file, fails before anything is compiled.
  '(unsigned-byte 8))

(defmethod sb-gray:stream-read-byte ((s octet-input-stream))
  (let ((v (%stream-octets s)) (i (%stream-index s)))
    (if (>= i (length v))
        :eof
        (progn (setf (%stream-index s) (1+ i)) (aref v i)))))

(defmethod sb-gray:stream-read-sequence ((s octet-input-stream) seq &optional (start 0) end)
  ;; Defined as well as READ-BYTE: without it SBCL falls back to one generic call per octet,
  ;; and the body readers in hyperion/http are all READ-SEQUENCE.
  ;;
  ;; &OPTIONAL START END, which is SBCL's lambda list for this generic -- not the (start end
  ;; &key) some Gray implementations use. A mismatch is not a warning: DEFMETHOD signals at
  ;; LOAD time with "takes 2 required arguments", so it cannot reach a running server.
  (let* ((v (%stream-octets s))
         (i (%stream-index s))
         (n (min (- (or end (length seq)) start) (- (length v) i))))
    (replace seq v :start1 start :start2 i :end2 (+ i n))
    (setf (%stream-index s) (+ i n))
    (+ start n)))

(defun %body-stream (octets)
  (make-instance 'octet-input-stream :octets octets))

;;; --- the seam --------------------------------------------------------------

(defvar *inline-dispatch*
  (lambda (app env k)
    (funcall k (handler-case (funcall app env) (error (e) e))))
  "The default *DISPATCH*: run the handler inline, on the loop thread.

A NAMED value rather than an anonymous initform, so \"is the installed dispatcher the
inline one?\" is a question that can be asked. %STREAM-RESPONSE asks it, because an SSE
stream under this dispatcher is not a trade-off, it is a dead server -- see there.")

(defvar *dispatch* *inline-dispatch*
  "How a request reaches the handler: (funcall *dispatch* app env K).

CONTINUATION-PASSING, not a call that returns a response, and that is the whole of M2's
concurrency change. A dispatcher runs the handler however it likes and calls K exactly once
with either the response triple or the CONDITION the handler signalled. The default still
runs it inline on the loop thread, so this shape costs a closure and changes no behaviour
until something is threaded through it.

K MAY BE CALLED FROM ANY THREAD. It routes itself onto the loop thread, because
everything it reaches -- the write, the buffer, the timer -- is loop-owned and touching a
uv handle from a foreign thread does not signal, it corrupts. Requiring each dispatcher to
remember UV:SUBMIT would be a rule violated silently; this is a guarantee instead.

K IS CALLED EXACTLY ONCE. Twice would write two responses onto one request, which is
response smuggling with the server supplying both halves. %COMPLETE refuses the second
rather than trusting the dispatcher, because a dispatcher that both signals and calls back
is an easy thing to write by accident.")

(defparameter *busy-response*
  (list 503 (list :content-type "text/plain; charset=utf-8" :retry-after "1")
        (list "Server busy"))
  "What a POOL-DISPATCH answers when the pool refuses the work.

503 with Retry-After, because it is TRUE and it is ACTIONABLE: the server is over capacity
right now and the client may come back. The alternative -- queueing without bound until
something falls over -- turns a condition the operator could act on into latency nobody can
attribute, which is the failure ADR-0016 rejected for streams and aion/pool refuses here.")

(defun pool-dispatch (pool)
  "A *DISPATCH* that runs handlers on POOL instead of on the loop thread.

  (setf srv:*dispatch* (srv:pool-dispatch (pool:make-pool :size 8)))

THIS IS THE POINT OF M2's FIRST HALF. With the inline default, one slow handler blocks
every connection the loop owns, because there is one loop thread; with this, it occupies
one worker. The continuation routes itself back onto the loop thread, so nothing here
has to remember UV:SUBMIT.

A REFUSAL IS ANSWERED, NOT DROPPED. TRY-SUBMIT returning NIL means the pool is at capacity;
the request gets *BUSY-RESPONSE* immediately. Waiting for a slot would block the loop
thread, which is the exact defect the pool exists to remove -- reintroduced by the
mechanism meant to remove it."
  (lambda (app env k)
    (unless (pool:try-submit
             pool
             (lambda ()
               (funcall k (handler-case (funcall app env) (error (e) e)))))
      (funcall k *busy-response*))))

(defvar *max-body-octets* (* 10 1024 1024)
  "Largest request body accepted, before 413. Policy, therefore here and not in the parser,
which reports the declared length and takes no view on how big is too big.")

;;; --- env synthesis ---------------------------------------------------------
;;;
;;; The nine keys ADR-0015 enumerates. This is now a contract we own: previously Clack
;;; defined it and drift was impossible, and a missing key is our bug.

(defun %headers-table (flat)
  "The parser's flat name/value list as the hash table the env promises: lowercased string
keys, EQUAL test, because every reader in hyperion does (gethash (string-downcase name) h)."
  (let ((h (make-hash-table :test #'equal)))
    (loop for (name value) on flat by #'cddr
          do (setf (gethash name h)
                   ;; Repeated field: comma-join, which is what RFC 9110 says a recipient may
                   ;; do and what every reader here expects to see.
                   (let ((prior (gethash name h)))
                     (if prior (concatenate 'string prior ", " value) value))))
    h))

(defun %split-target (target)
  "TARGET into (values path query). The query string excludes the `?', and is NIL when there
is no `?' at all -- distinct from an empty query, which `/x?' really does have."
  (let ((q (position #\? target)))
    (if q
        (values (subseq target 0 q) (subseq target (1+ q)))
        (values target nil))))

(defun %env (head body-octets peer)
  "The Ring/Lack env for a parsed HEAD and its BODY-OCTETS."
  (multiple-value-bind (path query) (%split-target (h1:head-target head))
    (let ((headers (%headers-table (h1:head-headers-flat head))))
      (list :request-method (intern (string-upcase (h1:head-method head)) :keyword)
            :path-info path
            :query-string query
            :headers headers
            :content-length (if (h1:head-has-body? head) (h1:head-body-length head) nil)
            :content-type (gethash "content-type" headers)
            :raw-body (and body-octets (%body-stream body-octets))
            :remote-addr peer))))

;;; --- writing ---------------------------------------------------------------

(defun %latin1 (string)
  "STRING as octets, one character to one octet.

NOT net:write-bytes' own string path, which encodes UTF-8: a header value above U+007F would
silently become two octets and the Content-Length we just computed would be wrong. The head
is ISO-8859-1 by definition (RFC 9112), so this is the encoding that round-trips it."
  (sb-ext:string-to-octets string :external-format :latin-1))

(defun %body-octets (body)
  "A Ring response body as octets. A string is UTF-8 (what a handler means by a string); an
octet vector passes through; NIL is empty; a PATHNAME is read from disk.

A PATHNAME IS THE CLACK CONTRACT FOR A STATIC FILE (#273). HYPERION/STATIC returns one for
every file it serves and deliberately does NOT set Content-Length, because Woo and
Hunchentoot sendfile it and set the length themselves. Without a clause here every static
file was a type error and a 500 on :uv -- and it stayed invisible because HYPERION/ASSETS
returns an octet vector, so the embedded-asset path worked and nothing pointed at this.
It is an ADR-0017 precondition: static files are what an app hits first.

A BARE PATHNAME NO LONGER REACHES HERE (#313). %COMPLETE routes it to
%WRITE-FILE-RESPONSE, which declares Content-Length from the file and writes the body in
bounded pieces -- because this clause holds the whole file in memory once, and
%WRITE-RESPONSE then concatenates head and body, so a file of size N transiently costs about
2N. Fine for the stylesheets and images hyperion/static serves; not fine for a large
download.

What still arrives here is a pathname INSIDE A LIST -- a list body is a sequence of pieces
to concatenate under one length, so there is nothing to stream -- and any caller that
reduces a body to octets itself. Both want the whole thing, so the read stays.

ONLY THE BYTES ACTUALLY READ are returned. FILE-LENGTH is the size when the file was
opened, and a file being rewritten underneath us would otherwise pad the response with
whatever the buffer happened to hold -- the same defect this tree just fixed in
HYPERION/HTTP\'s BODY-STRING, where a short read decoded a tail of NULs and a truncated
body was indistinguishable from an absent one.

A FUNCTION never reaches here any more: %COMPLETE routes a function body to %STREAM-RESPONSE
before calling this. One nested INSIDE a list still signals, because a list body is a
sequence of pieces to concatenate and there is no meaningful length for a piece that has not
been produced yet -- the streaming shape is a function AS the body, not among them."
  (etypecase body
    (null (make-array 0 :element-type '(unsigned-byte 8)))
    (string (sb-ext:string-to-octets body :external-format :utf-8))
    ((vector (unsigned-byte 8)) body)
    (pathname
     (with-open-file (in body :element-type '(unsigned-byte 8) :if-does-not-exist nil)
       (unless in
         (error "hyperion/server-uv: the response body names a file that is not readable: ~A"
                body))
       (let* ((size (file-length in))
              (buf (make-array size :element-type '(unsigned-byte 8)))
              (got (read-sequence buf in)))
         (if (= got size) buf (subseq buf 0 got)))))
    (cons (apply #'concatenate '(vector (unsigned-byte 8))
                 (mapcar #'%body-octets body)))
    (function
     (error "hyperion/server-uv: a function inside a list body is not a stream. A streamed body is the function ITSELF: (status headers (lambda (writer) ...)). See #117."))))

(defun %ring-headers-flat (headers)
  "A Ring header plist -- (:content-type \"text/html\") -- as the flat name/value list of
STRINGS h1:ENCODE-HEAD-FLAT takes.

Two conversions, both load-bearing. A KEYWORD becomes its capitalised name, so
:CONTENT-TYPE is `Content-Type' and :X-REQUEST-ID is `X-Request-Id' -- the casing every
other backend puts on the wire, and a name the encoder's TOKEN? check accepts. And every
value is PRINC-TO-STRING'd, because a handler writing (:retry-after 30) means the header
rather than a type error.

THAT SECOND CONVERSION IS NOT COSMETIC, and this was measured rather than assumed. Passing
the Ring plist through unconverted -- keywords where the encoder expects Coalton Strings --
does not signal. With specializations enabled, H1:ENCODE-HEAD reaches COALTON/STRING:REF,
which compiles to an unchecked vector reference, and SBCL dies with a MEMORY FAULT and
`The integrity of this image is possibly compromised'. A crash inside a libuv callback, on
the loop thread, from a header a handler set. So the CL side owes the Coalton side its
promised representation; the boundary does not check, and the failure is not a type error.

Content-Length, Transfer-Encoding and Connection need no special case here: the encoder
drops them from HEADERS and writes them from the arguments, so the framing on the wire
cannot disagree with the bytes that follow."
  (loop for (name value) on headers by #'cddr
        collect (if (stringp name) name (string-capitalize (symbol-name name)))
        collect (if (stringp value) value (princ-to-string value))))

(defun %write-response (conn status headers body-octets keep-alive)
  "Encode the head, refuse it if it is dangerous, and write head+body as one buffer."
  (let ((encoded (h1:encode-head-flat status (%ring-headers-flat headers)
                                      (length body-octets) keep-alive)))
    (cond
      ((h1:encode-ok? encoded)
       (net:write-bytes conn (concatenate '(vector (unsigned-byte 8))
                                          (%latin1 (h1:encode-text encoded))
                                          body-octets))
       keep-alive)
      (t
       ;; The handler produced a header we will not put on the wire. That is a bug in the
       ;; application, reported as a 500 -- never sanitised, never sent. NIL, because
       ;; H1:ENCODE-ERROR says Connection: close and the socket has to agree with it.
       (log:warn "server-uv: response refused" :reason (h1:encode-reason encoded))
       (net:write-bytes conn (%latin1 (h1:encode-error 500)))
       nil))))

(defun %write-error (conn status)
  (net:write-bytes conn (%latin1 (h1:encode-error status))))

(defparameter +crlf-octets+
  (make-array 2 :element-type '(unsigned-byte 8) :initial-contents '(13 10))
  "CRLF as octets. The encoder's own CRLF is Coalton-internal and not exported; the chunk
terminator is the shell's to write, since the shell is what concatenates it with the body
octets the Coalton side never sees.")

;;; --- a streamed body -------------------------------------------------------
;;;
;;; A FUNCTION in body position is a stream: (200 headers (lambda (writer) ...)). The
;;; response stays a three-list, so every interceptor and every middleware keeps
;;; destructuring one shape and none of them learns that streaming exists. hyperion/server
;;; adapts the same shape onto Clack for the other backends, so an application never finds
;;; out which server it is running on -- see ADR-0015 and %STREAM-BODY there.
;;;
;;; THE HEAD IS THE LAST MOMENT ANYTHING CAN BE REFUSED. Once a chunked head is on the wire
;;; there is no status left to change: a handler that signals afterwards cannot be given a
;;; 500, because the client already has a 200. What it gets instead is a connection closed
;;; WITHOUT the terminating chunk -- a truncated message, which every HTTP client reports as
;;; an error. That is the only honest answer, and it is why %STREAM-FINISH distinguishes
;;; ending from aborting rather than treating both as "done".
;;;
;;; AN EMPTY CHUNK IS NEVER WRITTEN. h1:ENCODE-CHUNK-HEADER refuses a zero length because a
;;; zero-length chunk IS the terminator, so writing one mid-stream would end the response
;;; while we believed we were still streaming and everything after it would be read as the
;;; next message. The shell does not even ask: a handler writing "" or NIL is an ordinary
;;; accident and is silently a no-op here.
;;;
;;; BACKPRESSURE IS THE WRITER'S, NOT THE CALLER'S. net:WRITE-BYTES returns as soon as the
;;; write is QUEUED, so a handler looping over a fast source and a slow client would grow the
;;; queue without bound -- unbounded memory presenting as a slow browser, which is exactly
;;; the failure ADR-0016 rejected one layer up. When the connection is saturated the writer
;;; WAITS for the outstanding write to settle before returning, so a producer that never
;;; checks anything still cannot outrun its consumer. On the loop thread it cannot wait --
;;; the thread that would drain the queue is the one that would be blocked -- so it signals
;;; instead; see %STREAM-WAIT.

(defvar *stream-write-timeout-seconds* 30
  "How long a saturated writer waits for one write to settle before giving up on the peer.

A bound rather than a policy: without it a client that stops reading forever holds a worker
forever, which is the resource exhaustion the pool exists to prevent, reached through the
one path that does not go through the pool.")

(define-condition stream-write-failed (error)
  ((reason :initarg :reason :reader stream-write-failed-reason))
  (:report (lambda (c s)
             (format s "hyperion/server-uv: the response stream could not be written: ~A"
                     (stream-write-failed-reason c))))
  (:documentation
   "Signalled INSIDE a streaming body when its writer cannot proceed: the peer is gone, the
stream is already finished, or a saturated write did not settle in time.

An error rather than a return value, because the alternative is a writer whose result a
handler must remember to check -- and a rule that is violated silently is the shape of
failure this file spends most of its length avoiding. A handler that does not handle it
simply stops, which aborts the stream, which the client sees as a truncated message."))

(defstruct (stream-out (:constructor %make-stream-out) (:copier nil) (:conc-name so-))
  conn app state loop keep-alive
  (open t)          ; may more chunks be written?
  (settled nil))    ; a semaphore, while a saturated write is outstanding

(defun %chunk-octets (chunk)
  "A chunk as octets. A string is UTF-8 -- what a handler means by a string -- and an octet
vector passes through. NIL and empty are NIL, which callers read as `write nothing'."
  (let ((octets (etypecase chunk
                  (null nil)
                  (string (sb-ext:string-to-octets chunk :external-format :utf-8))
                  ((vector (unsigned-byte 8)) chunk))))
    (and octets (plusp (length octets)) octets)))

(defun %stream-emit (so octets)
  "Write one chunk: size line, the octets, CRLF. LOOP THREAD ONLY.

Three writes rather than one concatenation would be three small segments on the wire, and
the terminating one is exactly the write Nagle holds -- the 44 ms defect ADR-0011 measured.
One buffer per chunk instead."
  (let ((header (h1:encode-chunk-header (length octets))))
    (unless (h1:encode-ok? header)
      ;; Unreachable: %CHUNK-OCTETS has already refused the empty chunk, which is the only
      ;; thing ENCODE-CHUNK-HEADER rejects. Checked rather than assumed, because an
      ;; unframed write here desynchronises the connection instead of failing.
      (error 'stream-write-failed :reason (h1:encode-reason header)))
    (net:write-bytes (so-conn so)
                     (concatenate '(vector (unsigned-byte 8))
                                  (%latin1 (h1:encode-text header))
                                  octets
                                  +crlf-octets+)
                     :on-complete (lambda (&rest _) (declare (ignore _))
                                    (%stream-settle so))
                     :on-error (lambda (&rest _) (declare (ignore _))
                                 (%stream-settle so)))))

(defun %stream-settle (so)
  "One outstanding write finished, however it finished. Wakes a waiting producer."
  (let ((sem (so-settled so)))
    (when sem (bt:signal-semaphore sem))))

(defun %stream-wait (so)
  "Block the PRODUCER until the outstanding write settles, when the connection is saturated.

Called only off the loop thread. On the loop thread this cannot be done and must not be
faked: the thread that would drain the queue is the thread that would be waiting, so
waiting there is a deadlock rather than a delay. The loop-thread path lets the write queue
grow instead -- which is the inline dispatcher's documented cost, not a new one."
  (when (net:saturated-p (so-conn so))
    (let ((sem (so-settled so)))
      (unless (bt:wait-on-semaphore sem :timeout *stream-write-timeout-seconds*)
        (error 'stream-write-failed
               :reason "the peer stopped reading and a queued write did not settle")))))

(defun %on-loop (loop thunk what)
  "Run THUNK on LOOP\'s thread -- directly when already on it, by submitting otherwise.
Returns T if it ran or was queued, NIL if it was DROPPED because the loop is closing.

DROPPING IS A DECISION HERE, NOT AN ACCIDENT (#296). SUBMIT signals LOOP-CLOSED once
CLOSE-LOOP has claimed the loop, and the callers below are all finishing work for a
connection that is going away with it: a response completion, or the end of a streamed
body. There is nowhere to deliver them -- the socket dies with the loop -- so dropping is
correct and this is where that sentence lives.

It is a named function rather than a HANDLER-CASE at each site because an unhandled
condition that happens not to fire looks identical to a deliberate drop until the day it
fires. The suite currently passes WITHOUT any call site handling LOOP-CLOSED, which means
no test reaches a teardown-race submit -- the exact case that produced #291. So the drop is
written down and tested rather than left to be discovered.

NOT EVERY CALLER MAY DROP. %STREAM-WRITE pairs its submit with a semaphore it then waits
on, so a silent drop there would be a stall rather than a no-op; it converts the refusal
into STREAM-WRITE-FAILED instead. See there."
  (if (uv:loop-thread-p loop)
      (progn (funcall thunk) t)
      (handler-case (progn (uv:submit loop thunk) t)
        (uv:loop-closed ()
          (log:debug "server-uv: dropped work for a closing loop" :what what)
          nil))))

(defun %stream-write (so chunk)
  "The WRITER a streaming body is handed. Callable from whatever thread the body runs on."
  (let ((octets (%chunk-octets chunk)))
    (when octets
      (unless (so-open so)
        (error 'stream-write-failed :reason "the response stream is already finished"))
      (when (conn-state-done (so-state so))
        (setf (so-open so) nil)
        (error 'stream-write-failed :reason "the peer closed the connection"))
      (if (uv:loop-thread-p (so-loop so))
          (%stream-emit so octets)
          (progn
            (setf (so-settled so) (bt:make-semaphore))
            ;; NOT %ON-LOOP: this submit is paired with the semaphore wait below, so a
            ;; silent drop would leave the body blocked until the write timeout for a
            ;; settle that can never come. A refusal here means the server is going down
            ;; under an in-flight stream, which the body should be told about in its own
            ;; vocabulary rather than through a libuv condition.
            (handler-case
                (uv:submit (so-loop so)
                       (lambda ()
                         ;; DONE can become true between the check above and here -- the
                         ;; peer may disconnect while this is in the queue -- so it is
                         ;; re-tested on the thread that owns the answer.
                         (if (conn-state-done (so-state so))
                             (%stream-settle so)
                             (handler-case (%stream-emit so octets)
                               (error () (%stream-settle so))))))
              (uv:loop-closed ()
                (setf (so-open so) nil)
                (error 'stream-write-failed :reason "the server is shutting down")))
            (%stream-wait so))))
    (values)))

(defun %stream-finish (so ok)
  "End the stream. LOOP THREAD ONLY.

OK writes the terminating chunk and the connection may be reused. NOT OK closes WITHOUT it,
which is the whole point: a truncated chunked message is an error to every client, and it is
the only way left to say `this response is wrong' once its head is on the wire."
  (when (so-open so)
    (setf (so-open so) nil)
    (let ((conn (so-conn so)) (state (so-state so)))
      (cond
        ((conn-state-done state) nil)
        (ok
         (net:write-bytes conn (%latin1 (coalton:coalton h1:last-chunk)))
         (if (so-keep-alive so)
             (%resume conn (so-app so) state)
             (%close-after conn state)))
        (t
         (log:error "server-uv: streaming body failed after the head was written")
         (%close-after conn state))))))

(defun %sse-response-p (headers)
  "Does this response declare itself an SSE stream? A Content-Type of text/event-stream,
parameters and casing allowed for.

The media type is the ONLY reliable announcement an endless stream makes. A handler cannot
tell us its body never returns, and we cannot find out by asking -- but SSE says so in a
header, by definition, because that is what makes a browser hold the connection open."
  (loop for (name value) on headers by #'cddr
        for n = (if (stringp name) name (symbol-name name))
        when (string-equal "content-type" n)
          return (let ((v (princ-to-string value)))
                   (and (>= (length v) 17)
                        (string-equal "text/event-stream" v :end2 17)))))

(defun %stream-response (conn app state status headers body keep-alive)
  "Answer with a chunked response whose body is produced by BODY, a function of one
argument -- the writer.

The head is encoded and refused HERE, before anything is written, because it is the last
moment a refusal can still become a 500. After it, the only report available is a truncated
message."
  (let ((encoded (h1:encode-head-chunked-flat status (%ring-headers-flat headers)
                                              keep-alive)))
    (cond
      ;; AN SSE STREAM ON THE LOOP THREAD IS NOT A TRADE-OFF, IT IS A DEAD SERVER, and it
      ;; is the one streaming case that is never correct rather than merely costly. A
      ;; finite body on the loop thread stalls other connections for as long as it runs,
      ;; which is the documented M1 cost and is the author's call to make; an SSE body
      ;; never returns, so the loop stops accepting connections FOREVER -- and the symptom,
      ;; "the whole server went unresponsive", points nowhere near the handler that did it.
      ;;
      ;; Refused rather than documented, which is the same move as h1:ENCODE-CHUNK-HEADER
      ;; refusing a zero length: the always-wrong case is made unrepresentable and the
      ;; sometimes-fine one is left alone. Narrow on purpose -- only text/event-stream, and
      ;; only under the inline dispatcher. The condition names the fix, because an operator
      ;; meeting this needs POOL-DISPATCH and not a diagnosis.
      ((and (%sse-response-p headers) (eq *dispatch* *inline-dispatch*))
       (log:error "server-uv: refused an SSE stream on the loop thread"
                  :fix "set *DISPATCH* to (POOL-DISPATCH (POOL:MAKE-POOL ...))")
       (net:write-bytes conn (%latin1 (h1:encode-error 500)))
       nil)
      ((not (h1:encode-ok? encoded))
       (log:warn "server-uv: streaming response refused" :reason (h1:encode-reason encoded))
       (net:write-bytes conn (%latin1 (h1:encode-error 500)))
       nil)
      (t
       (net:write-bytes conn (%latin1 (h1:encode-text encoded)))
       (let* ((loop* (net:connection-loop conn))
              (so (%make-stream-out :conn conn :app app :state state :loop loop*
                                    :keep-alive keep-alive))
              (writer (lambda (chunk) (%stream-write so chunk))))
         ;; THE BODY IS APPLICATION CODE, so it goes through *DISPATCH* like the handler
         ;; did rather than running here on the loop thread. With a pool it occupies one
         ;; worker for the life of the stream; with the inline default it occupies the LOOP
         ;; THREAD for the life of the stream, which is fine for a short finite body and
         ;; fatal for an SSE stream that never ends. That is the M1 trade the file header
         ;; already names, at its sharpest -- a streaming app wants POOL-DISPATCH.
         (funcall *dispatch*
                  (lambda (ignored)
                    (declare (ignore ignored))
                    (funcall body writer))
                  nil
                  (lambda (result)
                    (let ((ok (not (typep result 'condition))))
                      (unless ok
                        (log:error "server-uv: streaming body signalled"
                                   :condition (princ-to-string result)))
                      (%on-loop loop* (lambda () (%stream-finish so ok))
                                "a streamed response's finish"))))
         ;; :STREAMING, not NIL. The connection is NOT free yet -- the stream owns it until
         ;; %STREAM-FINISH says otherwise -- and NIL would tell %COMPLETE to close it,
         ;; killing the response it had just begun. A third answer rather than a boolean,
         ;; because "keep it" and "close it" are both wrong here.
         :streaming)))))

;;; --- a file body: a known length, written in bounded pieces (#313) ----------
;;;
;;; THE THIRD RESPONSE PATH, and it exists because neither of the other two is right for a
;;; large static file.
;;;
;;;   %WRITE-RESPONSE reads the whole file (#273's pathname clause) and then CONCATENATES
;;;   head and body into one buffer, so a file of size N transiently costs about 2N. Right
;;;   for the stylesheets and images hyperion/static serves today; not right the first time
;;;   an app serves a video.
;;;
;;;   %STREAM-RESPONSE is bounded and CHUNKED, which drops Content-Length. A static file is
;;;   the one kind of response whose size is known before a byte is written -- losing it
;;;   costs the client its progress bar and forecloses range requests, and hyperion/static's
;;;   own comment says the backend sets the length precisely because the other backends
;;;   sendfile it.
;;;
;;; So this path is neither: the length from the file, the body copied to the socket in
;;; *FILE-CHUNK-BYTES* pieces, nothing held whole.
;;;
;;; THE PUMP IS DRIVEN BY WRITE COMPLETIONS, not by a producer loop, and that is what makes
;;; it bounded under BOTH dispatchers. A loop would have to wait for the queue to drain, and
;;; on the loop thread it cannot wait -- the thread that would drain the queue is the one
;;; that would be waiting (see %STREAM-WAIT). What the streaming path pays for that with is
;;; an unbounded write queue on the inline dispatcher, which for a file would put the whole
;;; thing in memory again in a different pocket. Here each piece is read only once its
;;; predecessor has left, so at most one piece is ever in flight, on the loop thread or off
;;; it.
;;;
;;; SENDFILE(2) IS THE FURTHER OPTIMISATION and is deliberately not this change: it removes
;;; the copy through user space, while this removes the unbounded memory. Different
;;; properties, and the second should not wait for the first.

(defparameter *file-chunk-bytes* 65536
  "How much of a file response is held in memory at once.

The bound this path exists to provide, so it is a parameter rather than a constant: an
operator serving very large files over fast links may want it larger, and the suite binds it
small to make the chunking observable. 64 KiB is comfortably above a TCP window and small
enough that a hundred concurrent downloads are megabytes rather than gigabytes.")

(defvar *file-write-observer* nil
  "NIL, or a function of one argument -- the octet count of each BODY piece written.

A diagnostic seam, and it is here because otherwise `this response does not hold the file in
memory' is a claim about the code's shape rather than about its behaviour. The largest count
this ever sees is the most the response ever held; on the whole-file path that number is the
file's size, and that is the difference a test can measure. Called on the loop thread, so
whatever it does should be quick.")

(defparameter +no-octets+ (make-array 0 :element-type '(unsigned-byte 8))
  "The empty body. A file of length zero still gets its head written.")

(defstruct (file-out (:constructor %make-file-out) (:copier nil) (:conc-name fo-))
  "One file response in progress: the connection it is being written to, the open stream it
is being read from, and the two numbers whose disagreement matters -- DECLARED, which is on
the wire already, and WRITTEN, which is the only measurement."
  conn app state stream keep-alive
  (declared 0 :type unsigned-byte)
  (written 0 :type unsigned-byte))

(defun %file-chunk (fo)
  "The next piece of the file: up to *FILE-CHUNK-BYTES* octets, never past the declared
length, or NIL when there is nothing left to send.

NEVER PAST THE DECLARED LENGTH, and that is not an optimisation. Content-Length is already
on the wire, so a file that GREW while we were writing it would put octets after the body
the client is counting -- and the client would read them as the beginning of the next
response. A short read is recoverable by closing the connection (see %FILE-FINISH); a long
one is response smuggling with the filesystem supplying the second half."
  (let ((want (min *file-chunk-bytes* (- (fo-declared fo) (fo-written fo)))))
    (when (plusp want)
      (let* ((buf (make-array want :element-type '(unsigned-byte 8)))
             (got (read-sequence buf (fo-stream fo))))
        (cond ((zerop got) nil)
              ((= got want) buf)
              ;; ONLY THE BYTES ACTUALLY READ. The declared length is somebody else's claim
              ;; about the file; READ-SEQUENCE's result is the measurement, and padding the
              ;; difference with whatever the buffer held is how a truncated body becomes
              ;; indistinguishable from a complete one.
              (t (subseq buf 0 got)))))))

(defun %file-emit (fo head-octets)
  "Write one piece and arrange for the next. LOOP THREAD ONLY.

HEAD-OCTETS, on the first call, is coalesced with the first piece into ONE write. Two small
writes would be two segments on the wire and the second is exactly the write Nagle holds --
the 44 ms defect ADR-0011 measured -- so a small file still costs one write, as it did when
the whole body was held in memory."
  (let ((chunk (%file-chunk fo)))
    (if (and (null chunk) (null head-octets))
        (%file-finish fo)
        (let* ((body (or chunk +no-octets+))
               (buffer (if head-octets
                           (concatenate '(vector (unsigned-byte 8)) head-octets body)
                           body)))
          (incf (fo-written fo) (length body))
          (when *file-write-observer*
            (funcall *file-write-observer* (length body)))
          (net:write-bytes (fo-conn fo) buffer
                           :on-complete (lambda (&rest _) (declare (ignore _))
                                          (%file-continue fo))
                           :on-error (lambda (&rest _) (declare (ignore _))
                                       (%file-finish fo)))))))

(defun %file-continue (fo)
  "One piece has settled; read and write the next. LOOP THREAD ONLY -- a write callback runs
there.

THE HANDLER-CASE IS NOT DECORATION. This runs inside a libuv callback, so a condition
escaping it reaches UV:WITH-CALLBACK-GUARD, which absorbs it -- leaving a half-written
response, an open file and a connection nobody finishes, with nothing anywhere saying so. A
read that fails mid-body ends the response the only way still available once a head is on
the wire: short, and with the connection closed."
  (handler-case
      (if (conn-state-done (fo-state fo))
          (%file-finish fo)
          (%file-emit fo nil))
    (error (e)
      (log:error "server-uv: a file body could not be read"
                 :condition (princ-to-string e))
      (%file-finish fo))))

(defun %file-outcome (fo)
  "What is to be done with the connection now this body is over: :SHORT, :KEEP or :CLOSE.

Its own function because :SHORT is the case a test cannot stage -- it needs a file to shrink
between two reads the server makes microseconds apart -- and a decision that is only
reachable through a filesystem race is a decision nothing checks. The ordering is the claim:
SHORT BEATS KEEP-ALIVE. A truncated message is not made reusable by the client having asked
for reuse."
  (cond ((< (fo-written fo) (fo-declared fo)) :short)
        ((fo-keep-alive fo) :keep)
        (t :close)))

(defun %file-finish (fo)
  "Close the file and settle the connection. LOOP THREAD ONLY, and at most once.

THE SHORT BODY IS THE CASE THIS EXISTS FOR. Content-Length came from FILE-LENGTH -- a claim
about the file at the moment it was opened, and the file belongs to whoever else has it open
too. What was actually sent is WRITTEN. When they disagree, the message we promised is not
the message we sent, so THE CONNECTION CANNOT BE REUSED: a client counting the declared
octets would read the next response's head as this body's tail. Closing is the only report
left, and it is what every client renders as a truncated response -- the same answer
%STREAM-FINISH gives when a chunked body fails after its head."
  (when (fo-stream fo)
    (ignore-errors (close (fo-stream fo)))
    (setf (fo-stream fo) nil)
    (let ((conn (fo-conn fo))
          (state (fo-state fo)))
      ;; The request is finally over -- cleared HERE and not in %COMPLETE, so that
      ;; everything between the head and the last piece is answered to nobody else. A
      ;; pipelined request that arrived meanwhile is in the buffer, and %RESUME below is
      ;; where it gets served.
      (setf (conn-state-in-flight state) nil)
      (if (conn-state-done state)
          nil
          (ecase (%file-outcome fo)
            (:short
             (log:error "server-uv: a file body came up short of its Content-Length"
                        :declared (fo-declared fo) :written (fo-written fo))
             (%close-after conn state))
            (:keep (%resume conn (fo-app fo) state))
            (:close (%close-after conn state)))))))

(defun %write-file-response (conn app state status headers path keep-alive)
  "Answer with the contents of PATH: Content-Length from the file, body in bounded pieces.

Returns :STREAMING -- the response has begun and this path owns the connection until
%FILE-FINISH settles it, exactly as %STREAM-RESPONSE does. %COMPLETE must neither resume nor
close it in the meantime.

The file is opened and the head encoded BEFORE anything is written, because that is the last
moment a refusal can still become a 500. An unreadable file signals here, where %COMPLETE's
handler turns it into a 500; after the head there is no status left to change."
  (let ((stream (open path :element-type '(unsigned-byte 8) :direction :input
                           :if-does-not-exist nil)))
    (unless stream
      (error "hyperion/server-uv: the response body names a file that is not readable: ~A"
             path))
    (let* ((size (file-length stream))
           (encoded (h1:encode-head-flat status (%ring-headers-flat headers)
                                         size keep-alive)))
      (cond
        ((not (h1:encode-ok? encoded))
         (close stream)
         ;; Same answer as %WRITE-RESPONSE: a header we will not put on the wire is an
         ;; application bug, reported as a 500 and never sanitised. NIL, because
         ;; H1:ENCODE-ERROR says Connection: close and the socket must agree.
         (log:warn "server-uv: response refused" :reason (h1:encode-reason encoded))
         (net:write-bytes conn (%latin1 (h1:encode-error 500)))
         nil)
        (t
         ;; THE REQUEST IS STILL IN FLIGHT, and saying so is what keeps a pipelined peer
         ;; from being answered into the middle of this body. %COMPLETE clears the flag
         ;; before it returns, and %RESUME serves the next buffered request as soon as it is
         ;; clear -- so without this the second of two pipelined requests has its head and
         ;; chunks queued BETWEEN this body's pieces. Measured before the fix: a 307200-octet
         ;; file came back with its first wrong octet at 4096, exactly one piece in, and the
         ;; connection then closed. %FILE-FINISH clears it, immediately before deciding what
         ;; becomes of the connection.
         (setf (conn-state-in-flight state) t)
         (let ((fo (%make-file-out :conn conn :app app :state state :stream stream
                                   :keep-alive keep-alive :declared size)))
           (%file-emit fo (%latin1 (h1:encode-text encoded)))
           :streaming))))))

;;; --- one connection --------------------------------------------------------
;;;
;;; KEEP-ALIVE, THE PIPELINE DRAIN AND 100-CONTINUE (commit 4). All three are the same
;;; question -- when does a connection end? -- and answering one without the others leaves a
;;; server that is subtly wrong rather than obviously incomplete.
;;;
;;; The buffer now OUTLIVES a request. That is the whole change, and it is where a keep-alive
;;; server gets dangerous: after responding we must discard EXACTLY the head and body we just
;;; served, because anything left behind is read as the beginning of the next request. That
;;; is request smuggling with the attacker supplying both halves, and it is why %DROP-CONSUMED
;;; takes a count computed by the parser rather than by searching the buffer for a terminator.
;;;
;;; TWO LIMITS EXIST BECAUSE PERSISTENCE REMOVED THE ONE THAT USED TO BE FREE. A connection
;;; that closed after one request could not be held open, could not be pipelined without
;;; bound, and could not be starved slowly. Now it can, so:
;;;
;;;   *MAX-REQUESTS-PER-CONNECTION* bounds reuse. Not a resource limit -- reuse is cheap --
;;;   but a liveness one: it returns the accept path to a peer that would otherwise keep a
;;;   worker's attention forever on one socket.
;;;
;;;   *KEEP-ALIVE-TIMEOUT-MS* bounds SILENCE, and is restarted on every chunk, so it is an
;;;   INACTIVITY timeout and not a deadline. A slow upload over a bad link is fine; a peer
;;;   that sends one octet a minute is not. The parser caps how BIG a head may be (431) and
;;;   nothing caps how LONG one may take, which is precisely the slowloris shape.

(defvar *max-requests-per-connection* 100
  "How many requests one connection may serve before we close it anyway.

Policy, and a deliberately unremarkable number. Its job is to guarantee the connection ends,
not to ration anything.")

(defvar *keep-alive-timeout-ms* 5000
  "How long a connection may go silent before we close it.

Restarted on every chunk, so this is inactivity, not a deadline on the request. Two very
different situations reach it, and they get different answers -- see %IDLE-EXPIRE.")

(defstruct (conn-state (:constructor %make-conn-state) (:copier nil))
  (buffer (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
  (requests 0)
  (continued nil)     ; have we already sent 100 Continue for the request being read?
  (timer nil)
  (done nil)
  ;; A REQUEST IS IN FLIGHT: dispatched, no response written yet. HTTP/1.1 requires
  ;; responses in request order, so while this is set no further request is started even
  ;; if the peer pipelined several -- they wait in the buffer.
  (in-flight nil)
  ;; %RESUME is running. A SYNCHRONOUS dispatcher completes inside %SERVE-ONE and calls
  ;; back into %RESUME, which without this would recurse once per pipelined request.
  (draining nil))

(defun %append-octets (state chunk)
  (let ((buf (conn-state-buffer state)))
    (loop for b across chunk do (vector-push-extend b buf))
    buf))

(defun %drop-consumed (state n)
  "Discard the first N octets of the buffer -- exactly one request -- and keep the rest.

EXACTLY N is the security-relevant part, and N comes from the parser (head length) plus the
declared body length. Anything left behind is read as the start of the next request, which
is request smuggling with the attacker supplying both halves; anything dropped that should
not have been silently truncates the pipelined request behind it.

REPLACE on a sequence with itself is defined to behave as if the source were copied first,
so the overlap here is safe rather than merely untested."
  (let* ((buf (conn-state-buffer state))
         (remaining (- (fill-pointer buf) n)))
    (replace buf buf :start2 n)
    (setf (fill-pointer buf) remaining)
    (setf (conn-state-continued state) nil)))

(defun %max-head-octets ()
  "H1:MAX-HEAD-OCTETS, read across the Coalton boundary.

A Coalton toplevel `define' of a NON-FUNCTION compiles to a global lexical, so the exported
symbol is neither FBOUNDP nor BOUNDP from CL and `(h1:max-head-octets)' is an undefined
function at run time -- an error the compiler cannot see, because the call is well-formed.
The COALTON macro evaluates the reference in Coalton's own environment, which is the
supported way to read one. Restating 65536 here instead would be the drift this avoids."
  (coalton:coalton h1:max-head-octets))

(defun %parse-view (buffer)
  "BUFFER decoded as ISO-8859-1, bounded to the largest head the parser will accept.

Bounded on purpose: decoding the whole buffer on every chunk would be quadratic in the body
size, and the parser cannot look past the head anyway. One octet is one character in
ISO-8859-1, so the bound is exact rather than approximate."
  (let ((n (min (length buffer) (+ (%max-head-octets) 4))))
    (sb-ext:octets-to-string (subseq buffer 0 n) :external-format :latin-1)))

(defun %header (head name)
  "The value of header NAME in HEAD, or NIL. NAME must be lowercase -- the parser has already
lowercased every field name, so this is a plain STRING= rather than a case-folding search."
  (loop for (k v) on (h1:head-headers-flat head) by #'cddr
        when (string= k name) return v))

(defun %expectation (head)
  "What the peer's Expect header asks of us: :CONTINUE, :UNKNOWN, or NIL for none.

RFC 9110 is unusually blunt here: a server that does not understand an expectation MUST
answer 417 rather than ignore it. Ignoring it is the tempting reading, and it deadlocks --
the peer is waiting for permission to send a body we are waiting to receive."
  (let ((v (%header head "expect")))
    (cond ((null v) nil)
          ((string-equal "100-continue" (string-trim " " v)) :continue)
          (t :unknown))))

;;; --- the idle clock --------------------------------------------------------

(defun %timer-release (state)
  "Close the connection's timer handle, once. A live timer handle holds the loop open."
  (let ((timer (conn-state-timer state)))
    (when timer
      (setf (conn-state-timer state) nil)
      (ignore-errors (uv:close-handle timer)))))

(defun %idle-cancel (state)
  (let ((timer (conn-state-timer state)))
    (when timer (ignore-errors (uv:stop-timer timer)))))

(defun %idle-arm (conn state)
  "Start, or restart, the inactivity clock. Called whenever we finish a chunk still waiting
for the peer -- mid-request or between requests, which %IDLE-EXPIRE tells apart."
  (unless (conn-state-done state)
    (let ((timer (or (conn-state-timer state)
                     (setf (conn-state-timer state)
                           (uv:make-timer (net:connection-loop conn)
                                          (lambda (tm)
                                            (declare (ignore tm))
                                            (%idle-expire conn state)))))))
      (ignore-errors (uv:start-timer timer :after *keep-alive-timeout-ms*)))))

(defun %idle-expire (conn state)
  "The clock ran out. What that MEANS depends on whether anything is half-read.

An EMPTY buffer is an idle keep-alive connection, which is the ordinary end of a persistent
connection: close it silently, because the peer did nothing wrong and a 408 racing its next
request would be answered against a request we never read.

A NON-EMPTY buffer is a request that started and stopped -- a slow link, or slowloris. 408
names that, and telling the peer beats leaving it to guess."
  (unless (conn-state-done state)
    (setf (conn-state-done state) t)
    (if (plusp (fill-pointer (conn-state-buffer state)))
        (progn
          (log:info "server-uv: request timed out mid-read"
                    :buffered (fill-pointer (conn-state-buffer state)))
          (%write-error conn 408))
        (log:debug "server-uv: idle connection closed"
                   :requests (conn-state-requests state)))
    (%timer-release state)
    (ignore-errors (net:shutdown-write conn))))

(defun %conn-end (state)
  "The peer finished. Release what the connection was holding."
  (setf (conn-state-done state) t)
  (%timer-release state))

;;; --- serving ---------------------------------------------------------------

(defun %close-after (conn state)
  (setf (conn-state-done state) t)
  (%timer-release state)
  (net:shutdown-write conn))

(defun %fail (conn state status reason)
  "Answer STATUS and close. Every rejection closes, and not as a convenience: H1:ENCODE-ERROR
always says Connection: close, because once a message could not be parsed the position of the
next one in the stream is unknown and reusing the connection would be guessing."
  (log:info "server-uv: request rejected" :status status :reason reason)
  (%write-error conn status)
  (%close-after conn state))

(defun %resume (conn app state)
  "Start requests from the front of the buffer until one is in flight or none is complete.

THE DRAINING GUARD IS NOT DEFENSIVE, it is load-bearing. With the default inline
dispatcher a request completes INSIDE %SERVE-ONE, and %COMPLETE calls back here; without
the guard that recurses once per pipelined request, so a peer choosing how deeply to
pipeline would be choosing this server's stack depth.

The idle timer is armed only when the connection is genuinely idle -- not while a request
is in flight, because a connection waiting on its own handler is not a peer that has gone
quiet, and closing it for inactivity would be closing it for being busy."
  (unless (conn-state-draining state)
    (setf (conn-state-draining state) t)
    (unwind-protect
         (loop while (and (not (conn-state-done state))
                          (not (conn-state-in-flight state))
                          (%serve-one conn app state)))
      (setf (conn-state-draining state) nil))
    (unless (or (conn-state-done state) (conn-state-in-flight state))
      (%idle-arm conn state))))

(defun %serve (conn app state chunk)
  "A chunk arrived. Start every COMPLETE request now in the buffer, then wait for more.

Draining is what makes pipelining work: a peer may put several requests in one segment, and
a server that handled the first and waited for another chunk would stall until the peer's
next write -- which never comes, because the peer is waiting for the responses."
  (unless (conn-state-done state)
    (%append-octets state chunk)
    (%idle-cancel state)
    (%resume conn app state)))

(defun %serve-one (conn app state)
  "Serve at most one request from the front of the buffer.

Returns T when it consumed one and the caller should look for another, NIL when there is
nothing more to do with what we hold -- either the request is incomplete or the connection
is finished."
  (let* ((buffer (conn-state-buffer state))
         (head (h1:parse-head (%parse-view buffer))))
    (cond
      ((h1:head-incomplete? head) nil)          ; read more; NOT an error
      ((h1:head-rejected? head)
       (%fail conn state (h1:head-status head) (h1:head-reason head))
       nil)
      ((eq :unknown (%expectation head))
       ;; MUST be 417, not silence: the peer is waiting for permission to send.
       (%fail conn state 417 "unsupported expectation in the Expect header")
       nil)
      (t
       (let* ((consumed (h1:head-consumed head))
              (declared (if (h1:head-has-body? head) (h1:head-body-length head) 0)))
         (cond
           ((> declared *max-body-octets*)
            (%fail conn state 413 "declared body exceeds the configured cap")
            nil)
           ((< (fill-pointer buffer) (+ consumed declared))
            ;; The body is still arriving. If the peer asked us to confirm before sending it,
            ;; now is the moment -- otherwise both ends wait for each other until something
            ;; times out. Once per request, hence the flag.
            (when (and (eq :continue (%expectation head))
                       (not (conn-state-continued state)))
              (setf (conn-state-continued state) t)
              (%write-interim conn 100))
            nil)
           (t
            (let ((body (subseq buffer consumed (+ consumed declared))))
              (%drop-consumed state (+ consumed declared))
              (incf (conn-state-requests state))
              (setf (conn-state-continued state) nil)
              (let ((wanted (and (h1:head-keep-alive? head)
                                 (< (conn-state-requests state)
                                    *max-requests-per-connection*))))
                ;; Hands off and returns T. Whether the connection survives is no longer
                ;; knowable here -- the handler has not run yet -- so %COMPLETE decides it
                ;; and %RESUME picks up any further pipelined requests. The caller's loop
                ;; stops on IN-FLIGHT rather than on this value.
                (%respond conn app state head body wanted)
                t)))))))))

(defun %write-interim (conn status)
  "Write a 1xx interim response. Refusal is impossible for the status we pass, but it is
checked rather than assumed -- an unframed string on the wire desynchronises the connection."
  (let ((encoded (h1:encode-interim status)))
    (when (h1:encode-ok? encoded)
      (net:write-bytes conn (%latin1 (h1:encode-text encoded))))))

(defun %complete (conn app state result keep-alive)
  "Write the response for the request in flight, then resume the connection.

RUNS ON THE LOOP THREAD, and exactly once per request. RESULT is either the response triple
or the CONDITION the handler signalled -- a list and a condition are never confusable, so
the discrimination needs no wrapper type.

THE ONCE-ONLY GUARD IS NOT PARANOIA. A dispatcher that both signals and calls back is easy
to write by accident, and the consequence is two responses written onto one request, which
is response smuggling with the server supplying both halves. Refusing the second here costs
one test of a flag and does not require every dispatcher to be correct.

Returning early when the connection is already DONE matters for the same reason in the
other direction: a peer that disconnected while its handler ran must not have a response
written into a closed socket."
  (when (conn-state-in-flight state)
    (setf (conn-state-in-flight state) nil)
    (unless (conn-state-done state)
      (let ((kept
              (if (typep result 'condition)
                  (progn
                    (log:error "server-uv: handler signalled"
                               :condition (princ-to-string result))
                    (%write-error conn 500)
                    nil)
                  (handler-case
                      (destructuring-bind (status headers body) result
                        (cond
                          ((functionp body)
                           (%stream-response conn app state status headers body keep-alive))
                          ;; A BARE PATHNAME IS A FILE, and it gets the bounded path (#313):
                          ;; a known Content-Length with the body written in pieces. A
                          ;; pathname INSIDE a list still goes through %BODY-OCTETS, because
                          ;; a list body is pieces to concatenate and there is one length for
                          ;; the lot -- hyperion/static returns the pathname itself, which is
                          ;; the case that matters.
                          ((pathnamep body)
                           (%write-file-response conn app state status headers body
                                                 keep-alive))
                          (t
                           (%write-response conn status headers (%body-octets body)
                                            keep-alive))))
                    (error (e)
                      ;; The RESPONSE was unusable -- a bad shape, a header we refuse to
                      ;; send, a body we cannot render. Same answer as a handler that
                      ;; signalled, because from the peer's side it is the same event.
                      (log:error "server-uv: response could not be written"
                                 :condition (princ-to-string e))
                      (%write-error conn 500)
                      nil)))))
        ;; THREE ANSWERS, not two. :STREAMING means the response has begun and the stream
        ;; owns the connection until %STREAM-FINISH ends it -- resuming would start the
        ;; next pipelined request underneath a response still being written, and closing
        ;; would truncate the one we just promised.
        (cond ((eq kept :streaming))
              (kept (%resume conn app state))
              (t (%close-after conn state)))))))

(defun %respond (conn app state head body-octets keep-alive)
  "Build the env and hand the request to *DISPATCH*; the response is written by %COMPLETE.

The request boundary described in the file header lives across these two functions now: the
HANDLER-CASE that turns an application error into a 500 has moved INTO the default
dispatcher (where the handler is actually called) and into %COMPLETE (which receives the
condition). It is still inside the callback and above uv's guard, which is the property
that matters -- the guard would swallow the condition and leave the client waiting for a
response that is never written.

The HANDLER-CASE here catches the DISPATCHER failing, not the handler: a pool that cannot
accept work, or a seam somebody rebound badly. Without it that condition escapes into the
callback guard and the request hangs -- the exact failure the boundary exists to prevent,
one level up."
  (setf (conn-state-in-flight state) t)
  (multiple-value-bind (host port) (ignore-errors (net:peer-address conn))
    (declare (ignorable port))
    (let* ((env (%env head (and (plusp (length body-octets)) body-octets) (or host "")))
           (loop* (net:connection-loop conn))
           ;; K ROUTES ITSELF ONTO THE LOOP THREAD, so a dispatcher may call it from
           ;; wherever the work finished. The alternative -- documenting that every
           ;; dispatcher must end with UV:SUBMIT -- is a rule, and a rule that is violated
           ;; silently: touching a uv handle from a foreign thread does not signal, it
           ;; corrupts. Making the continuation safe BY CONSTRUCTION is the same move as
           ;; wrap-session owning the Set-Cookie -- the wrong thing is unavailable rather
           ;; than discouraged. The loop-thread test keeps the inline default free of a
           ;; pointless async hop.
           (k (lambda (result)
                (%on-loop loop*
                          (lambda () (%complete conn app state result keep-alive))
                          "a response completion"))))
      (handler-case
          (funcall *dispatch* app env k)
        (error (e)
          (log:error "server-uv: dispatch failed" :condition (princ-to-string e))
          (funcall k e))))))

;;; --- lifecycle -------------------------------------------------------------

(defstruct (server (:constructor %make-server) (:copier nil))
  loop thread listener host port)

(defun start (app &key (host "127.0.0.1") (port 8080))
  "Serve APP -- a Ring handler, (lambda (env) -> (status headers body)) -- on HOST:PORT.

Returns a SERVER; STOP it. PORT 0 asks the OS to choose, and SERVER-PORT reports what it
chose, which is what makes a test able to run without a fixed port.

TCP_NODELAY is on for every accepted connection (aion/uv/net's default). That is the
structural fix for the residual p99 straggler ADR-0011 recorded and could not reach through
Clack -- owning the socket is what makes it available at all."
  (let* ((loop (uv:make-loop))
         (listener (net:listen-tcp
                    loop host port
                    :on-connection
                    (lambda (conn)
                      (let ((state (%make-conn-state)))
                        (net:start-reading
                         conn
                         (lambda (octets connection)
                           (%serve connection app state octets))
                         ;; A persistent connection owns a timer handle, and a live timer
                         ;; holds the loop open. Both ends of the connection's life have to
                         ;; release it or a server that ran for a day cannot be stopped.
                         :on-end (lambda (connection)
                                   (declare (ignore connection))
                                   (%conn-end state))
                         :on-error (lambda (e connection)
                                     (declare (ignore connection))
                                     (%conn-end state)
                                     (log:debug "server-uv: connection error"
                                                :condition (princ-to-string e)))))))))
    (multiple-value-bind (bound-host bound-port) (net:listener-address listener)
      (let ((thread (uv:start-loop-thread loop)))
        (log:info "server-uv: listening" :host bound-host :port bound-port)
        (%make-server :loop loop :thread thread :listener listener
                      :host bound-host :port bound-port)))))

(defun stop (server)
  "Stop SERVER and release its loop. Idempotent."
  (when (server-loop server)
    ;; A loop already closed by another route leaves nothing to close the listener ON --
    ;; and CLOSE-LOOP below is what frees it in that case. Refusing to stop because the
    ;; loop is already gone would make STOP fail exactly when it has least to do.
    (%on-loop (server-loop server)
              (lambda () (net:close-listener (server-listener server)))
              "the listener close")
    (uv:close-loop (server-loop server))
    (setf (server-loop server) nil))
  server)
