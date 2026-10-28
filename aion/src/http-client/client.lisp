;;;; client.lisp --- an interceptor-shaped HTTP client around dexador.
;;;;
;;;; The "flipped" interceptor, for one outbound call: ENTER stages build the request, a
;;;; single dexador round-trip is the one effect at the edge, LEAVE stages process the
;;;; response, running in reverse so the outermost interceptor wraps everything.
;;;;
;;;; Moved out of hermes (pre-publication issue 202), where it was internal and unexported while praxeon
;;;; independently reimplemented it as three raw dex:post calls. Same argument as pre-publication issue 177: the
;;;; shape is request-response, not web, and a concept already reimplemented once is not
;;;; owned by whoever happened to hold it first.

(cl:in-package #:aion/http-client)

;;; --- failure --------------------------------------------------------------

(define-condition http-error (error)
  ((status :initarg :status :initform nil :reader http-error-status)
   (body :initarg :body :initform nil :reader http-error-body)
   (label :initarg :label :initform nil :reader http-error-label)
   (detail :initarg :detail :initform nil :reader http-error-detail)
   (retry-after :initarg :retry-after :initform nil :reader http-error-retry-after)
   (transport-phase :initarg :phase :initform nil :reader http-error-phase))
  (:report (lambda (c s)
             (format s "http~@[ ~A~]:~@[ ~A~]~@[ ~A~]"
                     (http-error-label c) (http-error-status c)
                     (or (http-error-detail c) (http-error-body c)))))
  (:documentation
   "An outbound HTTP call failed -- either at the transport, or with a status a stage
rejected.

The original signalled hermes' DELIVERY-FAILURE, which is why this client could not be
reused: a general HTTP client has no business asserting that a *delivery* failed. A caller
in a messaging context translates this into its own vocabulary at its own boundary, which is
where that meaning actually exists.

BODY IS PART OF THE CONTRACT, not a debugging convenience. A service explains its own
refusal in the response body -- which card was declined, which field was malformed -- and
that text is the single most useful thing a caller gets. It survives into this condition
rather than being discarded, so a caller may rely on it. The path this client replaced
discarded it, and the first consumer to adopt the client asked for the promise to be
written down before depending on it.

LABEL is free-form and is for the caller's benefit in a report -- a provider name, an
endpoint. It carries no semantics here.

RETRY-AFTER is the seconds the response's Retry-After header asked the caller to wait, read by
ENSURE-2XX with AION/RETRY:PARSE-RETRY-AFTER, or NIL (#79).

PHASE says how far a transport failure got, for AION/RETRY:TRANSIENCE (#79): :CONNECT when no
connection was made (refused, a connect timeout, a name that does not resolve), so the request
was not sent; :RESPONSE for a socket or stream failure after the connection was made, such as a
read timeout, after which the server may have acted on the request. It is NIL for a failure with
a status, for one this client raised itself before sending, such as a refused header, and for a
failure that is not of the socket or stream, such as a TLS failure (%TRANSPORT-PHASE)."))

(defparameter +transient-statuses+ '(408 425 429 503 529)
  "Statuses after which the request was not acted on and may succeed later: request timeout, too
early, too many requests, service unavailable, and 529, which Anthropic's API sends when it is
overloaded.")

(defparameter +unknown-statuses+ '(500 502 504)
  "Statuses that may be temporary, but after which the server may have acted on the request.")

(defmethod aion/retry:transience ((c http-error))
  "For HTTP-ERROR: :TRANSIENT for a status in +TRANSIENT-STATUSES+ or a failure in the :CONNECT
phase; :UNKNOWN for a status in +UNKNOWN-STATUSES+ or a failure in the :RESPONSE phase; NIL
otherwise, a 4xx such as 400, 401 or 404 included."
  (let ((status (http-error-status c)))
    (cond ((member status +transient-statuses+) :transient)
          ((member status +unknown-statuses+) :unknown)
          (status nil)
          ((eq (http-error-phase c) :connect) :transient)
          ((eq (http-error-phase c) :response) :unknown)
          (t nil))))

(defmethod aion/retry:retry-after ((c http-error))
  (http-error-retry-after c))

(define-condition response-too-large (http-error)
  ((limit :initarg :limit :reader response-too-large-limit))
  (:documentation "The response body was longer than the request's MAX-BODY-BYTES, or declared
so in Content-Length. The read stops at the limit, so the rest is never received."))

(define-condition pinned-connect-unsupported (http-error) ()
  (:documentation "A request set CONNECT-ADDRESS on a platform where this client cannot pin the
connection. Signalled instead of connecting without the pin. Since #536 every platform this tree
supports can pin, so nothing in the tree signals it; it stays so code that handles it still
compiles."))

(define-condition certificate-rejected (http-error)
  ((host :initarg :host :reader certificate-rejected-host)
   (verdict :initarg :verdict :reader certificate-rejected-verdict)
   (code :initarg :code :initform nil :reader certificate-rejected-code))
  (:report (lambda (c s)
             (format s "the TLS certificate of ~A was rejected (~(~A~)~@[, Windows error #x~8,'0X~])"
                     (certificate-rejected-host c) (certificate-rejected-verdict c)
                     (certificate-rejected-code c))))
  (:documentation "The operating system refused a TLS server's certificate on a pinned connection
(#536). VERDICT is the reason as a keyword and CODE the operating system's own error code. A
reason with its own subclass is signalled as that subclass; any other reason as this class."))

(define-condition certificate-expired (certificate-rejected) ()
  (:documentation "The server's certificate, or one in its chain, is outside its validity period."))
(define-condition certificate-untrusted-root (certificate-rejected) ()
  (:documentation "The server's chain does not end at a root this machine trusts."))
(define-condition certificate-name-mismatch (certificate-rejected) ()
  (:documentation "The server's certificate is not valid for the URL's host name."))
(define-condition certificate-revoked (certificate-rejected) ()
  (:documentation "A certificate in the chain is revoked. Revocation is not checked by default
(see aion/windows:verify-server-certificate-chain), so this comes only from a policy that did."))
(define-condition certificate-revocation-unknown (certificate-rejected) ()
  (:documentation "Revocation was checked and could not be decided, for instance offline."))
(define-condition certificate-distrusted (certificate-rejected) ()
  (:documentation "A certificate in the chain is in the machine's Disallowed store."))
(define-condition certificate-chain-incomplete (certificate-rejected) ()
  (:documentation "No chain could be built from the server's certificate to a root."))
(define-condition certificate-wrong-usage (certificate-rejected) ()
  (:documentation "The server's certificate is not valid for authenticating a TLS server."))

(defparameter +certificate-conditions+
  '((:expired . certificate-expired) (:untrusted-root . certificate-untrusted-root)
    (:name-mismatch . certificate-name-mismatch) (:revoked . certificate-revoked)
    (:revocation-unknown . certificate-revocation-unknown)
    (:distrusted . certificate-distrusted) (:chain-incomplete . certificate-chain-incomplete)
    (:wrong-usage . certificate-wrong-usage))
  "Each verdict a platform verifier gives, with the condition class it is signalled as.")

(defun certificate-condition-class (verdict)
  "The condition class for VERDICT: its own subclass, or CERTIFICATE-REJECTED."
  (or (cdr (assoc verdict +certificate-conditions+)) 'certificate-rejected))

(define-condition fetch-refused (http-error)
  ((url :initarg :url :reader fetch-refused-url)
   (host :initarg :host :initform nil :reader fetch-refused-host)
   (address :initarg :address :initform nil :reader fetch-refused-address)
   (reason :initarg :reason :reader fetch-refused-reason))
  (:report (lambda (c s)
             (format s "fetch-public refused ~A~@[ (host ~A~@[, address ~A~])~]: ~(~A~)"
                     (fetch-refused-url c) (fetch-refused-host c)
                     (let ((a (fetch-refused-address c))) (and a (address-string a)))
                     (fetch-refused-reason c))))
  (:documentation "FETCH-PUBLIC refused a URL before connecting. REASON is a keyword: :SCHEME
(not http or https), :NO-HOST, :UNRESOLVABLE, or the ADDRESS-CATEGORY of an address the host
resolved to (:LOOPBACK, :PRIVATE, :LINK-LOCAL and so on). ADDRESS is that address."))

(define-condition too-many-redirects (http-error)
  ((url :initarg :url :reader too-many-redirects-url)
   (limit :initarg :limit :reader too-many-redirects-limit))
  (:report (lambda (c s)
             (format s "fetch-public: more than ~D redirects, the last to ~A"
                     (too-many-redirects-limit c) (too-many-redirects-url c))))
  (:documentation "FETCH-PUBLIC was redirected more than its MAX-REDIRECTS times."))

(define-condition fetch-deadline-exceeded (http-error)
  ((url :initarg :url :reader fetch-deadline-exceeded-url)
   (deadline :initarg :deadline :reader fetch-deadline-exceeded-deadline))
  (:report (lambda (c s)
             (format s "fetch-public: ~A did not finish within its deadline of ~A seconds"
                     (fetch-deadline-exceeded-url c) (fetch-deadline-exceeded-deadline c))))
  (:documentation "FETCH-PUBLIC did not finish within its DEADLINE (#807). URL is the hop it was
on. A body cut short by the deadline is never returned as a response."))

;;; --- the values -----------------------------------------------------------

(defstruct (request (:constructor make-request (&key (method :get) url
                                                     (headers '()) content
                                                     connect-timeout read-timeout
                                                     (follow-redirects 5) max-body-bytes
                                                     connect-address ca-path)))
  "An outbound HTTP request being built. HEADERS is an alist of (name . value); CONTENT is a
JSON/string body or an alist (dexador form-encodes an alist).

TIMEOUTS are here rather than absent because the client's second consumer needed them and
its first did not: praxeon hand-rolled dexador partly because this client could not express
a read timeout, and an LLM call without one can hang for as long as a provider is willing to
hold the socket. NIL leaves dexador's own default in place.

For fetching a URL a user supplied (#295; FETCH-PUBLIC builds on all four):

FOLLOW-REDIRECTS  the most redirects to follow. NIL follows none, and a 3xx is the response.
                  The default, 5, is dexador's own, so a caller that sets nothing is unchanged.
MAX-BODY-BYTES    when set, the body is read as a stream and reading stops at this many bytes;
                  a longer body signals RESPONSE-TOO-LARGE. NIL reads the whole body.
CONNECT-ADDRESS   an IP address, as a string or an octet vector, to connect to instead of
                  resolving the URL's host. The Host header, TLS SNI and certificate
                  verification still use the URL's host name. On Windows, where dexador's
                  WinHTTP takes no caller's connection, the request goes over aion/tls and
                  Windows decides about the certificate (#536); see %REQUEST-PINNED.
CA-PATH           trust roots for certificate verification (a PEM file or a directory; on
                  Windows a PEM file only). NIL uses the system's."
  (method :get :type keyword)
  (url "" :type string)
  (headers (quote ()) :type list)
  (content nil)
  (connect-timeout nil)
  (read-timeout nil)
  (follow-redirects 5)
  (max-body-bytes nil)
  (connect-address nil)
  (ca-path nil))

(defparameter +no-bytes+
  (make-array 0 :element-type '(unsigned-byte 8))
  "The empty body. A constant so an absent body is still a vector, never NIL -- both
accessors below are total, and totality is the entire point of this shape.")

(defstruct (response (:constructor %make-response (status headers bytes))
                     (:predicate responsep))
  "An HTTP response. STATUS is the integer code.

WHAT THE BODY IS -- the contract, decided in pre-publication issue 223 rather than defaulted into. The response
carries the OCTETS THAT ARRIVED, exactly, and the string is DERIVED from them:

  RESPONSE-BYTES  what the server sent, byte for byte, never decoded or re-encoded
  RESPONSE-BODY   those bytes decoded as UTF-8

Both are total and neither is conditional, which is the property a `:binary' keyword could
not have given: it would have made BODY mean \"a string, unless\", and every consumer would
then have to know which call it was looking at.

The reason it is this way round: the client previously decoded every body to a string and
kept nothing else, so there was NO path to the octets. A signed update cannot go through
that -- the signature is over the exact bytes of a file, and a UTF-8 decode is precisely
the re-encoding that invalidates it, failing at a customer on a version bump months later.
An installer decoded as UTF-8 is simply mangled. Deriving the string loses nothing;
deriving the bytes is impossible."
  (status 0 :type integer)
  (headers nil)
  (bytes +no-bytes+ :type (vector (unsigned-byte 8)))
  ;; Memoized decode. Bodies are read more than once (a LEAVE stage, then the caller, then
  ;; an error report) and decoding a large body repeatedly is a cost nobody asked for.
  (%decoded nil))

(defun make-response (&key (status 0) headers body bytes)
  "Build a RESPONSE. Supply BYTES (the octets that arrived) or BODY (a string, or octets).

BODY still accepts a string so that every existing consumer, stub and test keeps working
unchanged -- a string is encoded to UTF-8 and stored as the bytes, which round-trips
exactly. BYTES is what the real transport supplies."
  (let ((octets (cond (bytes (%as-octets bytes))
                      (body  (%as-octets body))
                      (t     +no-bytes+))))
    (%make-response status headers octets)))

(defun %as-octets (x)
  "X as octets: a string is UTF-8 encoded, a byte vector is itself, NIL is empty."
  (etypecase x
    (null +no-bytes+)
    (string (sb-ext:string-to-octets x :external-format :utf-8))
    ((vector (unsigned-byte 8)) x)))

(defun response-body (response)
  "RESPONSE's bytes decoded as UTF-8, memoized.

TOTAL BY CONSTRUCTION, with a replacement character for anything that is not valid UTF-8.
That is not lenience for its own sake: ENSURE-2XX puts the body into the HTTP-ERROR it
signals, so a strict decode makes the ERROR PATH fail on exactly the responses one most
needs reported -- a proxy's binary error page would raise INVALID-UTF8-STARTER-BYTE
instead of the HTTP-ERROR describing the 502. Reach for RESPONSE-BYTES when the bytes are
what matter; this accessor's job is to always produce something printable."
  (or (response-%decoded response)
      (setf (response-%decoded response)
            (sb-ext:octets-to-string (response-bytes response)
                                     :external-format '(:utf-8 :replacement #\ufffd)))))

(defun %printable-url (url)
  "URL as a request prints it (#844): the scheme, host and path as given, a user and password
before the host replaced by <hidden>, and each query parameter's value replaced by <hidden>, its
name kept. A query value is often a key (?key=...), and a user part is a password."
  (if (not (stringp url))
      (princ-to-string url)
      (let* ((query-at (position #\? url))
             (base (subseq url 0 (or query-at (length url))))
             (scheme-end (search "://" base))
             (authority-start (if scheme-end (+ scheme-end 3) 0))
             (authority-end (or (position #\/ base :start authority-start) (length base)))
             (at (position #\@ base :start authority-start :end authority-end :from-end t))
             (base (if at
                       (concatenate 'string (subseq base 0 authority-start)
                                    "<hidden>" (subseq base at))
                       base)))
        (if (null query-at)
            base
            (format nil "~A?~{~A~^&~}" base
                    (loop for pair in (uiop:split-string (subseq url (1+ query-at)) :separator "&")
                          for eq = (position #\= pair)
                          when (plusp (length pair))
                            collect (if eq (format nil "~A=<hidden>" (subseq pair 0 eq)) pair)))))))

(defmethod print-object ((r request) stream)
  "The method, the URL with its secrets hidden, the header names with every value replaced by
<hidden>, and the body's size -- never a header value or the body (#844).

A request is on the stack while it is sent, so a backtrace or a debugger prints it whenever a
condition escapes then. Its headers carry credentials (authorization, x-goog-api-key, x-api-key,
cookie) and its body can hold one or the user's data, so the default structure printer put them
in every such backtrace. Every header's value is hidden, not a list of known names: a provider's
own key header is not on any list."
  (print-unreadable-object (r stream :type t)
    (format stream "~A ~A" (request-method r) (%printable-url (request-url r)))
    (when (request-headers r)
      (format stream " headers: ~{~A=<hidden>~^, ~}"
              (mapcar (lambda (h) (if (consp h) (car h) "?")) (request-headers r))))
    (let ((content (request-content r)))
      (cond ((null content))
            ((stringp content) (format stream " body: ~D character~:P" (length content)))
            ((vectorp content) (format stream " body: ~D byte~:P" (length content)))
            ((listp content) (format stream " body: ~D field~:P" (length content)))
            (t (format stream " body: a ~(~A~)" (type-of content)))))))

(defmethod print-object ((r response) stream)
  "Status and a byte COUNT -- never the body.

Now that a response can legitimately hold an installer, the default structure printer would
put megabytes of integers into any backtrace that unwound through a frame holding one. The
count is the useful part anyway."
  (print-unreadable-object (r stream :type t)
    (format stream "~D ~D byte~:P" (response-status r) (length (response-bytes r)))))

(defstruct (interceptor (:constructor make-interceptor (name &key (enter #'identity)
                                                              (leave #'identity))))
  "A pipeline stage: NAME, an ENTER (request->request) run forward, and a LEAVE
(response->response) run in reverse. Either defaults to identity."
  (name "" :type string)
  (enter #'identity :type function)
  (leave #'identity :type function))

;;; --- ready-made stages ----------------------------------------------------

(defun add-header (name value)
  "An ENTER stage that appends the header NAME: VALUE."
  (make-interceptor (format nil "header:~A" name)
                    :enter (lambda (req)
                             ;; A copy with one slot changed, so every other slot is carried
                             ;; as it is. Rebuilding the request slot by slot once reset the
                             ;; timeouts, and would reset any slot added later.
                             (let ((copy (copy-request req)))
                               (setf (request-headers copy)
                                     (cons (cons name value) (request-headers req)))
                               copy))))

(defun ensure-2xx (&optional label)
  "A LEAVE stage that turns a non-2xx response into an HTTP-ERROR carrying the status and the
body -- which is where a service explains its own refusal, and is the part a caller most
wants in the report.

LABEL is optional and free-form; it appears in the report so a failure names which call it
was."
  (make-interceptor "ensure-2xx"
                    :leave (lambda (resp)
                             (unless (<= 200 (response-status resp) 299)
                               (error 'http-error
                                      :label label
                                      :status (response-status resp)
                                      :body (response-body resp)
                                      :retry-after (aion/retry:parse-retry-after
                                                    (ignore-errors
                                                     (header-value (response-headers resp)
                                                                   "retry-after")))))
                             resp)))

;;; --- the runner (enter -> the one effect -> leave) ------------------------

(defun %content-length (headers)
  (let ((v (header-value headers "content-length")))
    (and (stringp v) (ignore-errors (parse-integer v)))))

;;; --- the deadline watch of FETCH-PUBLIC (#807) ---------------------------------

(defstruct (%watch (:constructor %make-watch ()))
  "The socket a FETCH-PUBLIC with a deadline is using, and whether its deadline has passed.
Every field is read and written with LOCK held."
  (lock (sb-thread:make-mutex :name "fetch-public deadline"))
  (socket nil)
  (fired nil))

(defvar *%watch* nil
  "The deadline watch of the FETCH-PUBLIC running in this thread, or NIL.")

(defun %lend-socket (socket)
  "Hand SOCKET to the running fetch's deadline watch, so the deadline can shut it down. When the
deadline has already passed, shut it down now; the fetch then reports the deadline."
  (let ((w *%watch*))
    (when w
      (sb-thread:with-mutex ((%watch-lock w))
        (if (%watch-fired w)
            (ignore-errors (usocket:socket-shutdown socket :io))
            (setf (%watch-socket w) socket))))))

(defun %take-back-socket ()
  "Take the socket away from the running fetch's deadline watch. Called before every close: a
closed socket keeps its descriptor number, and a shutdown after the close could reach whatever
reused that number."
  (let ((w *%watch*))
    (when w
      (sb-thread:with-mutex ((%watch-lock w))
        (setf (%watch-socket w) nil)))))

(defun %close-body (body)
  (%take-back-socket)
  (ignore-errors (close body)))

(defun %read-capped (body limit url)
  "BODY as octets, reading at most LIMIT of them. BODY is a stream (closed here) or a vector.
Signals RESPONSE-TOO-LARGE when there is more than LIMIT."
  (flet ((too-large ()
           (error 'response-too-large :limit limit
                                      :detail (format nil "the body of ~A is larger than ~D bytes"
                                                      url limit))))
    (if (streamp body)
        (unwind-protect
             (let* ((buffer (make-array (1+ limit) :element-type '(unsigned-byte 8)))
                    (end (read-sequence buffer body)))
               (when (> end limit) (too-large))
               (subseq buffer 0 end))
          (%close-body body))
        (let ((octets (%as-octets body)))
          (when (> (length octets) limit) (too-large))
          octets))))

(defun %multipart-octets-header-p (header)
  "Is HEADER, a (name . value) pair, a Content-Type whose value begins with \"multipart/\"?"
  (and (consp header)
       (string-equal (string (car header)) "content-type")
       (stringp (cdr header))
       (>= (length (cdr header)) 10)
       (string-equal "multipart/" (cdr header) :end2 10)))

(defun %dex-headers (req)
  "REQ's headers as dexador is given them.

A CENTRALIZED WORKAROUND, NOT A NATIVE SEND (#828). Dexador's usocket backend, which serves
Linux and macOS, sets MULTIPART-P when the Content-Type value's first ten characters are
string= \"multipart/\". It then writes its own Content-Type with a boundary of its own, and
builds the body from an alist of fields, failing with a TYPE-ERROR on a body of octets the caller
encoded itself (dexador-20260101, src/backend/usocket.lisp, lines 494-506 and 569-575). Its
loop over the caller's other headers skips content-type (lines 610-615), so there is no other
way to send the header. For a body of octets with a multipart/ type, the value is given here
with one leading space: dexador's check no longer matches, and it writes the header and the
octets as given. HTTP does not count whitespace before a field value as part of the value
(RFC 9110, section 5.5), so a server reads the type, boundary included, byte for byte. Nothing
is lost: dexador's multipart branch needs an alist, so it could never send these octets.

WinHTTP, dexador's Windows backend, sends the octets and the header as given, so this applies
only off Windows. The test MULTIPART-OCTETS-ARRIVE-AS-SENT sends such a body through the real
client to a local server and compares what arrives, so a dexador that checks the prefix another
way fails CI, not a provider call; upstream.sexp's Quicklisp entry points here too."
  (let ((headers (request-headers req)))
    #+os-windows headers
    #-os-windows
    (if (typep (request-content req) '(array (unsigned-byte 8) (*)))
        (mapcar (lambda (h)
                  (if (%multipart-octets-header-p h)
                      (cons (car h) (concatenate 'string " " (cdr h)))
                      h))
                headers)
        headers)))

(defun %dex-args (req)
  "The dexador keyword arguments REQ implies, apart from the URL and the stream."
  (append (list :method (request-method req)
                :headers (%dex-headers req)
                :content (request-content req)
                ;; ALWAYS binary (pre-publication issue 223). Left to itself dexador decides by
                ;; content-type and hands back a string for anything it considers text -- at
                ;; which point the octets are gone and no caller can get them back. Decoding is
                ;; this client's job now, and it happens in RESPONSE-BODY, once, from bytes that
                ;; are still there.
                :force-binary t
                :max-redirects (or (request-follow-redirects req) 0))
          (when (request-max-body-bytes req) (list :want-stream t))
          (when (request-ca-path req) (list :ca-path (request-ca-path req)))
          ;; Passed only when set, so an unset timeout means dexador's default rather than an
          ;; explicit NIL, which it treats differently.
          (when (request-connect-timeout req)
            (list :connect-timeout (request-connect-timeout req)))
          (when (request-read-timeout req)
            (list :read-timeout (request-read-timeout req)))))

(defvar *%connected* nil
  "Bound to NIL by %HTTP around one round trip, and set to T by the pinned path
(%REQUEST-PINNED) as soon as its USOCKET:SOCKET-CONNECT returns, so a transport failure there is
known to have happened before or after the connection was made (#79).")

(defun %io-failure-p (e)
  "Whether E is a failure of the socket or the stream: a usocket condition, a name that did not
resolve, or a stream error such as a read timeout (SB-SYS:IO-TIMEOUT) or an early end of file.
A TLS failure is not: cl+ssl's conditions are plain errors, and a refused certificate must never
be classed as something a retry could fix."
  (typep e '(or usocket:socket-condition usocket:ns-condition stream-error)))

(defun %dexador-connect-failure-p (e)
  "Whether E, from the dexador path, means no connection was made. Measured on Linux (#79):
dexador reports a refused connection and a connect timeout as USOCKET:TIMEOUT-ERROR, a name that
does not resolve as USOCKET:NS-HOST-NOT-FOUND-ERROR, and a read timeout as SB-SYS:IO-TIMEOUT.
Only types that can come from making the connection count; USOCKET:SOCKET-ERROR as a whole does
not, because a connection reset while reading the response is one too. Used only where the call
that failed is not known; the pinned path knows, see *%CONNECTED*."
  (typep e '(or usocket:timeout-error usocket:connection-refused-error
                usocket:host-unreachable-error usocket:network-unreachable-error
                usocket:ns-error)))

(defun %transport-phase (e pinned)
  "HTTP-ERROR-PHASE for E, a transport failure. On the pinned path, which makes the connection
itself, from where it failed: a socket failure before USOCKET:SOCKET-CONNECT returned is
:CONNECT, one after it :RESPONSE. On the dexador path, from E's type
(%DEXADOR-CONNECT-FAILURE-P). Anything that is not a socket or stream failure, a TLS failure
included, has no phase, so AION/RETRY does not retry it."
  (cond ((not (%io-failure-p e)) nil)
        (pinned (if *%connected* :response :connect))
        ((%dexador-connect-failure-p e) :connect)
        (t :response)))

(defun %http (req)
  "Perform the single dexador round-trip for REQ, returning a RESPONSE.

A non-2xx is captured as a RESPONSE rather than signalled -- dexador would signal, and that
would decide the meaning of a status before any LEAVE stage got to. A transport-level failure
has no response to hand back, so it signals HTTP-ERROR directly."
  (let ((limit (request-max-body-bytes req))
        (url (request-url req))
        (*%connected* nil))
    (flet ((response (status headers body)
             (let ((declared (and limit (%content-length headers))))
               (when (and declared (> declared limit))
                 (when (streamp body) (%close-body body))
                 (error 'response-too-large
                        :limit limit
                        :detail (format nil "~A declares a body of ~D bytes, over the limit of ~D"
                                        url declared limit))))
             (make-response :status status :headers headers
                            :bytes (if limit (%read-capped body limit url) (%as-octets body)))))
      (handler-case
          (multiple-value-bind (body status headers)
              (if (request-connect-address req)
                  (%request-pinned req)
                  (apply #'dex:request url (%dex-args req)))
            (response status headers body))
        (http-error (e) (error e))
        (dexador.error:http-request-failed (e)
          ;; No decode here, deliberately. This runs INSIDE a handler-case handler, so
          ;; anything it signals escapes the handler-case entirely -- and the old code decoded
          ;; here, strictly, meaning a non-2xx whose body was not valid UTF-8 raised a raw
          ;; INVALID-UTF8-STARTER-BYTE instead of the HTTP-ERROR that describes the failure.
          ;; Storing bytes cannot fail.
          (response (dexador.error:response-status e)
                    (ignore-errors (dexador.error:response-headers e))
                    (dexador.error:response-body e)))
        (error (e)
          (error 'http-error :detail (format nil "transport error: ~A" e)
                             :phase (%transport-phase e (request-connect-address req))))))))

(defun send-request (request interceptors &key (perform #'%http))
  "Run REQUEST through INTERCEPTORS around one HTTP round-trip and return the processed
RESPONSE. ENTER runs forward, the round-trip is the effect, LEAVE runs in reverse.

PERFORM is the effect, and is a parameter so a caller can substitute one -- which is how this
is tested without a network, and how a consumer stubs it. The default performs the real call."
  (let* ((entered (reduce (lambda (r ic) (funcall (interceptor-enter ic) r))
                          interceptors :initial-value request))
         (resp (funcall perform entered)))
    (reduce (lambda (r ic) (funcall (interceptor-leave ic) r))
            (reverse interceptors) :initial-value resp)))

;;; --- response helpers -----------------------------------------------------

(defun header-value (headers name)
  "Case-insensitive header lookup. HEADERS is dexador's hash-table (lowercased keys) or NIL."
  (when (hash-table-p headers)
    (gethash (string-downcase name) headers)))
