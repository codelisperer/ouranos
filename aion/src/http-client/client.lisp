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
overloaded. Exported so a caller that maps these statuses into its own conditions, as hermes
does, classifies them the same way rather than keeping a second copy of the list (#79).")

(defparameter +unknown-statuses+ '(500 502 504)
  "Statuses that may be temporary, but after which the server may have acted on the request.")

(defun status-transience (status phase)
  "The AION/RETRY:TRANSIENCE verdict for a failure with HTTP STATUS and transport PHASE, where
either may be NIL: :TRANSIENT for a status in +TRANSIENT-STATUSES+ or, with no status, the
:CONNECT phase; :UNKNOWN for a status in +UNKNOWN-STATUSES+ or the :RESPONSE phase; NIL
otherwise, a 4xx such as 400, 401 or 404 included.

Exported, and not only the two lists, so that a caller mapping these failures into its own
conditions reaches the same verdict by calling this rather than by repeating the COND. hermes
does that for DELIVERY-FAILURE: sharing the lists alone left the two COND forms as separate
copies that could be changed apart while both still passed their own tests (the review of
#1067)."
  (cond ((member status +transient-statuses+) :transient)
        ((member status +unknown-statuses+) :unknown)
        (status nil)
        ((eq phase :connect) :transient)
        ((eq phase :response) :unknown)
        (t nil)))

(defmethod aion/retry:transience ((c http-error))
  "For HTTP-ERROR: STATUS-TRANSIENCE of its status and phase."
  (status-transience (http-error-status c) (http-error-phase c)))

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
             ;; THE URL AS A REQUEST PRINTS IT, with a query value or a password hidden (#844),
             ;; because a report is what reaches a log. The reader still returns it as given
             ;; (Copilot's review of #1163).
             (format s "fetch-public: ~A did not finish within its deadline of ~A seconds"
                     (%printable-url (fetch-deadline-exceeded-url c))
                     (fetch-deadline-exceeded-deadline c))))
  (:documentation "FETCH-PUBLIC did not finish within its DEADLINE (#807). URL is the hop it was
on. A body cut short by the deadline is never returned as a response."))

(define-condition request-deadline-exceeded (fetch-deadline-exceeded) ()
  (:report (lambda (c s)
             (format s "send-request: ~A did not finish within its deadline of ~A seconds"
                     (%printable-url (fetch-deadline-exceeded-url c))
                     (fetch-deadline-exceeded-deadline c))))
  (:documentation "SEND-REQUEST did not finish within its DEADLINE (#1162). URL is the hop it was
on. A subclass of FETCH-DEADLINE-EXCEEDED, so one handler covers both, and it has the same two
readers. A body cut short by the deadline is never returned as a response."))

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
                  A request with CONNECT-ADDRESS follows none whatever this says: its 3xx is
                  the response, because a redirect's host would need an address of its own
                  (FETCH-PUBLIC checks each hop's address and follows redirects itself).
MAX-BODY-BYTES    when set, the body is read as a stream and reading stops at this many bytes;
                  a longer body signals RESPONSE-TOO-LARGE. NIL reads the whole body.
CONNECT-ADDRESS   an IP address, as a string or an octet vector, to connect to instead of
                  resolving the URL's host. The Host header, TLS SNI and certificate
                  verification still use the URL's host name. On every OS the request is then
                  written and its response read by this client's own HTTP/1.1 (http1.lisp,
                  #985), not by dexador; for https it goes over aion/tls on Windows, where
                  Windows decides about the certificate (#536), and over cl+ssl elsewhere. See
                  %REQUEST-PINNED.
CA-PATH           trust roots for certificate verification (a PEM file or a directory; on
                  Windows a PEM file only). NIL uses the system's.
There is no argument for the local-host proxy exemption, deliberately: see
*APPROVED-LOCAL-HOST*, which is not exported, because a keyword here let any caller assert an
approval for any host (#1091, and the re-review of #1134)."
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

(defvar *%pinned-body-stream* nil
  "True while %REQUEST-PINNED must hand back every body as a stream, capped or not, so that the
caller sees the status and headers before any of the body is read. %HTTP-UNDER-DEADLINE binds it:
a redirect it follows has its body closed unread, and before #1178 a 302 with a slow body held the
call, or failed it, before its Location was ever requested.")

(defun %read-to-end (body)
  "Every octet of BODY, a stream, which is closed here. No limit: for a caller that set none."
  (unwind-protect
       (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
             (buffer (make-array 8192 :element-type '(unsigned-byte 8))))
         (loop for end = (read-sequence buffer body)
               while (plusp end)
               do (loop for i below end do (vector-push-extend (aref buffer i) out))
               while (= end (length buffer)))
         (coerce out '(simple-array (unsigned-byte 8) (*))))
    (%close-body body)))

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

(defun %idempotent-method-p (method)
  "Whether METHOD may be sent twice with the same effect as once (RFC 9110 9.2.2)."
  (member method '(:get :head :options :trace :put :delete)))

(defun %pooled-p (req)
  "Whether dexador may send REQ on a connection it pooled from an earlier request.

A request that is not idempotent never is: %DEX-ARGS turns the pool and keep-alive off for it
(the hub's review of #974). Otherwise a POST could go out on a pooled connection, the server
could act on it and then drop the connection, dexador would reconnect inside its own retry, and
a refusal of that reconnect would look like a failure to connect, which WITH-RETRY's default
policy resends. Not used on Windows, where dexador's WinHTTP backend opens a new session for
every request, so no connection is reused."
  (%idempotent-method-p (request-method req)))

(defun %dex-args (req)
  "The dexador keyword arguments REQ implies, apart from the URL and the stream."
  (let ((local (proxy-arguments (request-url req))))
   (append (list :method (request-method req)
                :headers (%dex-headers req)
                :content (request-content req)
                ;; ALWAYS binary (pre-publication issue 223). Left to itself dexador decides by
                ;; content-type and hands back a string for anything it considers text -- at
                ;; which point the octets are gone and no caller can get them back. Decoding is
                ;; this client's job now, and it happens in RESPONSE-BODY, once, from bytes that
                ;; are still there.
                :force-binary t)
          ;; ONE DECISION, BOTH ARGUMENTS. A request exempted by a RECORDED APPROVAL gets
          ;; :MAX-REDIRECTS 0 from LOCAL as well -- see PROXY-ARGUMENTS for why a redirect must
          ;; not be followed under that exemption -- so this must not pass a second
          ;; :MAX-REDIRECTS in that case.
          ;;
          ;; THE TEST IS FOR :MAX-REDIRECTS IN LOCAL, NOT FOR LOCAL ITSELF. An exemption from the
          ;; literal rule carries no redirect cap, and asking whether LOCAL is non-empty dropped
          ;; this request's own cap for every plaintext request to an address: dexador then used
          ;; its own default of 5, so FOLLOW-REDIRECTS NIL followed redirects and a cap of 1
          ;; followed three hops. REDIRECTS-CAN-BE-REFUSED-CAPPED-OR-FOLLOWED caught it.
          local
          (unless (member :max-redirects local)
            (list :max-redirects (or (request-follow-redirects req) 0)))
          ;; A PLAINTEXT REQUEST TO A LOCAL HOST IS NOT SENT THROUGH A PROXY (#1091). The
          ;; decision is PROXY-ARGUMENTS, in fetch.lisp, because every caller that sends a
          ;; request has to make it the same way -- including hermes/blob's S3 backend, which
          ;; calls dexador directly and so never reaches this function. When this lived here,
          ;; that backend was not covered while a comment and the CHANGELOG said it was (the
          ;; review of #1094).
          (when (request-max-body-bytes req) (list :want-stream t))
          (when (request-ca-path req) (list :ca-path (request-ca-path req)))
          ;; Passed only when set, so an unset timeout means dexador's default rather than an
          ;; explicit NIL, which it treats differently.
          (when (request-connect-timeout req)
            (list :connect-timeout (request-connect-timeout req)))
          (when (request-read-timeout req)
            (list :read-timeout (request-read-timeout req)))
          ;; See %POOLED-P: a request that is not idempotent always gets a new connection.
          (unless (%pooled-p req)
            (list :use-connection-pool nil :keep-alive nil)))))

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
Measured on macOS (#974, CI run 40653707988): a refused connection is
USOCKET:INVALID-ARGUMENT-ERROR, which usocket signals for the EINVAL macOS returns when a
connect with a timeout has been refused. Only types that can come from making the connection
count; USOCKET:SOCKET-ERROR as a whole does not, because a connection reset while reading the
response is one too. Used only where the call that failed is not known; the pinned path knows,
see *%CONNECTED*."
  (typep e '(or usocket:timeout-error usocket:connection-refused-error
                usocket:host-unreachable-error usocket:network-unreachable-error
                usocket:invalid-argument-error usocket:ns-error)))

#+os-windows
(defun %winhttp-phase (e)
  "HTTP-ERROR-PHASE for E, a WINHTTP::WIN-ERROR, which is what dexador signals on Windows, where it
uses WinHTTP (#974; a refused connection measured as 12029). From the error code:
- 12029 (ERROR_WINHTTP_CANNOT_CONNECT) and 12007 (ERROR_WINHTTP_NAME_NOT_RESOLVED): no connection
  was made, so :CONNECT;
- 12002 (ERROR_WINHTTP_TIMEOUT), 12030 (ERROR_WINHTTP_CONNECTION_ERROR) and 12152
  (ERROR_WINHTTP_INVALID_SERVER_RESPONSE): :RESPONSE. 12002 is also the code for a connect
  timeout, but WinHTTP does not say which, so it is counted as the case that must not be resent;
- any other code, a TLS failure included: no phase."
  (case (winhttp::win-error-code e)
    ((12029 12007) :connect)
    ((12002 12030 12152) :response)
    (t nil)))

(defun %transport-error-class (e)
  "The HTTP-ERROR class for the transport failure E: MALFORMED-RESPONSE when WinHTTP reported
12152 (ERROR_WINHTTP_INVALID_SERVER_RESPONSE), the server's reply not being HTTP, as this
client's own reader reports it on the pinned path; HTTP-ERROR otherwise (the hub's review of
#979)."
  #+os-windows (if (and (typep e 'winhttp::win-error) (eql 12152 (winhttp::win-error-code e)))
                   'malformed-response
                   'http-error)
  #-os-windows (progn e 'http-error))

(defun %transport-phase (e pinned &key pooled)
  "HTTP-ERROR-PHASE for E, a transport failure. On the pinned path, which makes the connection
itself, from where it failed: a socket failure before USOCKET:SOCKET-CONNECT returned is
:CONNECT, one after it :RESPONSE. On the dexador path, from E's type
(%DEXADOR-CONNECT-FAILURE-P), but only for a request that could not have used a pooled
connection: with POOLED true, dexador may have sent the request on a pooled connection and then
failed to reconnect, so a failure to connect does not show the request was not acted on, and it
is :RESPONSE (%POOLED-P). On Windows, where dexador uses WinHTTP with a new session for every
request, from its error code (%WINHTTP-PHASE). Anything that is not a socket or stream failure,
a TLS failure included, has no phase, so AION/RETRY does not retry it."
  (cond #+os-windows ((and (not pinned) (typep e 'winhttp::win-error)) (%winhttp-phase e))
        ((not (%io-failure-p e)) nil)
        (pinned (if *%connected* :response :connect))
        ((and (not pooled) (%dexador-connect-failure-p e)) :connect)
        (t :response)))

(defun %port-of (uri)
  "URI's port, or its scheme's default when the URL gives none: QURI-PORT is NIL then."
  (or (quri:uri-port uri)
      (if (string-equal (quri:uri-scheme uri) "https") 443 80)))

(defun %origin (uri)
  "URI's origin -- scheme, host and port -- as a value two URIs can be compared on.

A PORT IS PART OF IT, and so is the scheme: https://api.example.com and http://api.example.com
are different origins, and so are the same host on two ports. That is what makes this the right
comparison for deciding whether a redirect may keep a credential (#1139)."
  (list (string-downcase (or (quri:uri-scheme uri) ""))
        (string-downcase (or (quri:uri-host uri) ""))
        (%port-of uri)))

(defparameter +credential-headers+
  '("authorization" "cookie" "x-api-key" "x-goog-api-key" "x-amz-security-token")
  "The header names whose value authenticates the caller rather than describing the request.

THESE ARE THE CREDENTIAL HEADERS THIS TREE SENDS. Anthropic's key goes in x-api-key (praxeon/src/llm.lisp) and Google's in x-goog-api-key
(praxeon/src/image-google.lisp), both through SEND-REQUEST, so a list of Authorization and Cookie
alone left two of this tree's four credential headers being forwarded across a cross-host
redirect (#1139, and the review of #1141). X-AMZ-SECURITY-TOKEN carries an AWS session token
beside an Authorization signature. hermes/blob sends it through its own dexador calls, not
through SEND-REQUEST, but an app sending an AWS request through SEND-REQUEST would otherwise lose
Authorization on a cross-origin redirect and still forward the token (#1156).

THIS LIST IS NOT A SECURITY BOUNDARY, and PRINT-OBJECT is the place that says why: a provider's
own key header is not on any list, so PRINT-OBJECT hides EVERY header value rather than these.
Here a list is unavoidable -- something has to decide which headers a redirect may carry -- so it
is written once and every name this tree sends is on it. A new provider with a header of its own
adds it here.")

(defun %without-credentials (headers)
  "HEADERS with the ones that authenticate the caller removed: +CREDENTIAL-HEADERS+."
  (remove-if (lambda (h) (member (string (car h)) +credential-headers+ :test #'string-equal))
             headers))

(defun %credential-bearing-p (headers)
  "Whether HEADERS carry something that authenticates the caller rather than describing the body.

THE SAME LIST %WITHOUT-CREDENTIALS REMOVES, read from +CREDENTIAL-HEADERS+ rather than written
again here: deciding the path from one list and stripping from another is how x-api-key and
x-goog-api-key came to be forwarded while Authorization was not (the review of #1141)."
  (and (listp headers)
       (some (lambda (h)
               (and (consp h)
                    (member (string (car h)) +credential-headers+ :test #'string-equal)))
             headers)
       t))

(defun %redirect-target (response url)
  "The absolute URL a 3xx RESPONSE sends this request to, or NIL when it is not a redirect or
names no Location.

THE LOCATION MAY BE RELATIVE, so it is merged with the URL it came from rather than used as it
stands: `/v2/x' from https://api.example.com/v1/x is https://api.example.com/v2/x."
  (when (member (response-status response) '(301 302 303 307 308))
    (let ((location (header-value (response-headers response) "location")))
      (when (and location (plusp (length location)))
        (ignore-errors
         (quri:render-uri (quri:merge-uris (quri:uri location) (quri:uri url))))))))

(defun %redirect-method (method status)
  "The method the next hop uses. 301, 302 and 303 turn anything but GET and HEAD into a GET,
which is what dexador does and what every browser does; 307 and 308 keep the method, which is
the whole reason those two codes exist."
  (if (and (member status '(301 302 303))
           (not (member method '(:get :head))))
      :get
      method))

(defun %http-following-redirects (req &key (hops (or (request-follow-redirects req) 0))
                                           (prepare #'identity))
  "Perform REQ, following redirects one hop at a time and DROPPING THE CREDENTIAL HEADERS on a
hop that changes origin (#1139).

WHY THIS CLIENT FOLLOWS THEM RATHER THAN DEXADOR, for this one kind of request. dexador follows a
cross-host redirect by recursing into its own REQUEST with the SAME arguments and the SAME
headers -- it prepends a new Host and keeps the rest, in the cross-host branch of
src/backend/usocket.lisp -- so an Authorization header built for api.example.com was delivered to
whatever a 307 named. Nothing in this tree would have noticed: the configuration checks in #1077,
#1092 and #1106 check the base a request is sent to, which is the right thing to check and is a
different thing from where a redirect then leads.

ONLY FOR A REQUEST THAT CARRIES A CREDENTIAL HEADER OR A BODY, and only when it is allowed to
follow redirects at all. A body is included because it can hold a credential no header list can
see, such as Facebook's access_token in a POST form, and such a request can now get a
cross-origin 3xx back instead of having it followed (see below). Every other request stays on
dexador's own path, unchanged, because the hazard is specific: a redirect that carries no
credential and no body costs the caller nothing. That is why
REDIRECTS-CAN-BE-REFUSED-CAPPED-OR-FOLLOWED still measures dexador's following.

SAME-ORIGIN REDIRECTS STILL CARRY THE HEADERS, which is the behaviour an API that moves a path
relies on. Origin is scheme, host and port, compared as %ORIGIN compares them; a change in any of
the three drops the headers. That is what browsers do, and the alternative considered -- refusing
to follow any redirect for a credential-bearing request -- would have broken an API that answers
301 for a renamed path while returning a 3xx the caller never asked to handle."
  (let ((current req))
    (loop
      (let* ((single (funcall prepare (copy-request current)))
             (from current)
             (budget hops)
             (next nil)
             (response (progn (setf (request-follow-redirects single) 0)
                              ;; THE DECISION IS MADE FROM THE STATUS AND HEADERS, BEFORE THE BODY
                              ;; IS READ. A hop this loop follows has its body closed unread, so
                              ;; MAX-BODY-BYTES is applied only to the response the caller gets.
                              ;; It used to be applied to every hop, so a request capped at 5 bytes
                              ;; failed with RESPONSE-TOO-LARGE on a 302 whose body was 10 bytes,
                              ;; where dexador had followed it (#1156).
                              (%http-once single
                                          (lambda (status headers)
                                            (setf next (and (plusp budget)
                                                            (%next-hop from status headers))))))))
        (unless next
          (return response))
        (decf hops)
        (setf current next)))))

(defun %next-hop (current status headers)
  "The request that follows CURRENT after a response with STATUS and HEADERS, or NIL when this
response is the answer: it is not a redirect, it names no usable Location, or following it would
send CURRENT's body to another origin.

It needs only the status and headers, not the body, so %HTTP-FOLLOWING-REDIRECTS can decide
before the body is read (#1156)."
  (let ((next (%redirect-target (make-response :status status :headers headers)
                                (request-url current))))
    (when next
      (let* ((from (quri:uri (request-url current)))
             (to (quri:uri next))
             (cross-origin (not (equal (%origin from) (%origin to))))
             (method (%redirect-method (request-method current) status))
             ;; THE BODY THE NEXT HOP WOULD ACTUALLY CARRY, worked out rather than inferred
             ;; from the status. The first version refused only a 307 or 308 with a body,
             ;; reasoning that 301, 302 and 303 discard the body -- but they discard it only by
             ;; changing the method to GET, and a request that was already a GET keeps its
             ;; method, so a GET carrying a body went to the other origin with it (Copilot's
             ;; review of #1141). The body goes only when the method changes to GET.
             (drops-the-body (and (eq method :get) (not (eq method (request-method current)))))
             (body (if drops-the-body nil (request-content current))))
        ;; A BODY IS NEVER RE-SENT TO ANOTHER ORIGIN, whatever the status: it may hold a
        ;; credential that no header list can see -- Facebook's POST carries access_token in
        ;; the form -- and there is no way to strip one from a body. The 3xx is the answer and
        ;; the caller decides.
        (unless (and cross-origin body)
          (let ((headers (if cross-origin
                             (%without-credentials (request-headers current))
                             (request-headers current)))
                (hop (copy-request current)))
            ;; A body dropped with a change to GET takes its Content-Type with it.
            (when drops-the-body
              (setf headers (remove-if (lambda (h)
                                         (string-equal (string (car h)) "content-type"))
                                       headers)))
            (setf (request-url hop) next
                  (request-method hop) method
                  (request-content hop) body
                  (request-headers hop) headers)
            hop))))))

(defvar *%deadline-hop* nil
  "Inside a SEND-REQUEST with a deadline, a cons whose car is the URL of the hop in progress.")

(defun %http-under-deadline (req)
  "Perform REQ, a request SEND-REQUEST is running under a DEADLINE, over connections this client
opens itself, one hop at a time (#1162).

THE SOCKET HAS TO BE ONE THIS CLIENT OPENED, because the deadline is FETCH-PUBLIC's watch (#807):
it wakes a read blocked on a socket by shutting the socket down, and it can only do that to a
socket that was lent to it. dexador opens its own sockets and lends nothing. So each hop is
pinned to the first address its host resolves to and sent by %REQUEST-PINNED, which lends its
socket. OPEN-RESPONSE-STREAM does the same for the same reason (#984).

Redirects are followed by %HTTP-FOLLOWING-REDIRECTS, the loop credential-bearing requests already
use, so a hop that changes origin drops the credential headers and never carries a body, and each
hop is resolved and pinned again. An approved-local request follows no redirect, as on every
other path (#1134).

A REQUEST THAT WOULD GO THROUGH A PROXY IS REFUSED. A pinned connection goes straight to the
address, so it would not go through the proxy dexador would have used, and sending a request
directly that the machine's configuration routes through a proxy is not this client's decision
to make. The refusal is an HTTP-ERROR before anything is sent."
  (flet ((pin (hop)
           (let* ((url (request-url hop))
                  (local (proxy-arguments url)))
             (when (and dexador.util:*default-proxy* (not (member :proxy local)))
               (error 'http-error
                      :detail (format nil "~A would be sent through the proxy ~A, and a deadline cannot be kept through a proxy: a request with a deadline goes over a connection this client opens directly, so it is refused rather than sent around the proxy" (%printable-url url) (%printable-url dexador.util:*default-proxy*))))
             ;; THE HOP'S URL IS RECORDED, so the condition names the hop the deadline found the
             ;; call on rather than the URL it started from (Copilot's review of #1163).
             (when *%deadline-hop* (setf (car *%deadline-hop*) url))
             (let* ((host (quri:uri-host (quri:uri url)))
                    (address (and host (first (resolve-host host)))))
               ;; CHECKED BETWEEN RESOLVING AND CONNECTING. Neither can be interrupted, so a
               ;; deadline that passed while the name was being resolved would otherwise add a
               ;; whole connect timeout to the wait (Copilot's review of #1163). Any error after
               ;; the deadline is reported as the deadline, by %CALL-WITH-DEADLINE.
               (when (%fired-p *%watch*)
                 (error 'http-error :detail "the deadline passed before the connection was opened"))
               (unless address
                 (error 'http-error :detail (format nil "~A does not resolve" host)))
               (setf (request-connect-address hop) address)
               hop))))
    ;; EVERY BODY COMES BACK AS A STREAM, so a followed redirect's body is closed unread and
    ;; the caller's MAX-BODY-BYTES, or none, applies only to the response returned (#1178).
    (let ((*%pinned-body-stream* t))
      (%http-following-redirects
       req
       :hops (if (eql 0 (getf (proxy-arguments (request-url req)) :max-redirects))
               0
               (or (request-follow-redirects req) 0))
       :prepare #'pin))))

(defun %http (req)
  "Perform REQ and return a RESPONSE, following redirects in whichever way is safe for it.

A REQUEST THAT CARRIES A CREDENTIAL HEADER OR A BODY HAS ITS REDIRECTS FOLLOWED HERE, by
%HTTP-FOLLOWING-REDIRECTS, so that a hop which changes origin takes neither the credential headers
nor the body with it (#1139). A request with a body may therefore get a cross-origin 3xx back
rather than have it followed. Every other request is handed to dexador as before, redirects
included.

The pinned path (CONNECT-ADDRESS) follows no redirects at all by design -- a redirect's host
would need an address of its own -- so it is already outside this question."
  (when (and *%watch* (not (request-connect-address req)))
    (return-from %http (%http-under-deadline req)))
  (if (and (or (%credential-bearing-p (request-headers req))
               ;; A BODY CAN CARRY A CREDENTIAL THAT NO HEADER LIST CAN SEE. Facebook's POST puts
               ;; access_token in the form and sends no credential header, so deciding by headers
               ;; alone sent it down dexador's own path -- and dexador re-sends the body on a
               ;; cross-origin 307 or 308, which delivered the token to whatever the redirect
               ;; named (Copilot's review of #1141). Any request with a body follows its
               ;; redirects here, where a body is never sent to another origin.
               (request-content req))
           (plusp (or (request-follow-redirects req) 0))
           (not (request-connect-address req))
           ;; AN APPROVED-LOCAL REQUEST FOLLOWS NOTHING, which is #1134's rule and was bypassed
           ;; by this loop: PROXY-ARGUMENTS answers :MAX-REDIRECTS 0 for such a request, dexador
           ;; obeyed it, and then the loop followed the 3xx itself. Sending it down the
           ;; single-shot path keeps the rule where it already is rather than restating it, so
           ;; the two cannot drift (the review of #1141).
           (not (eql 0 (getf (proxy-arguments (request-url req)) :max-redirects))))
      (%http-following-redirects req)
      (%http-once req)))

(defun %http-once (req &optional skip-body-p)
  "Perform the single dexador round-trip for REQ, returning a RESPONSE.

SKIP-BODY-P, when given, is called with the status and headers before the body is read. When it
returns true the body is closed unread, the response carries no bytes, and MAX-BODY-BYTES is not
applied: the caller is a redirect loop that will not use this body (#1156).

A non-2xx is captured as a RESPONSE rather than signalled -- dexador would signal, and that
would decide the meaning of a status before any LEAVE stage got to. A transport-level failure
has no response to hand back, so it signals HTTP-ERROR directly."
  (let ((limit (request-max-body-bytes req))
        (url (request-url req))
        (*%connected* nil))
    (flet ((response (status headers body)
             (when (and skip-body-p (funcall skip-body-p status headers))
               (when (streamp body) (%close-body body))
               (return-from %http-once
                 (make-response :status status :headers headers
                                :bytes (make-array 0 :element-type '(unsigned-byte 8)))))
             (let ((declared (and limit (%content-length headers))))
               (when (and declared (> declared limit))
                 (when (streamp body) (%close-body body))
                 (error 'response-too-large
                        :limit limit
                        :detail (format nil "~A declares a body of ~D bytes, over the limit of ~D"
                                        url declared limit))))
             (make-response :status status :headers headers
                            :bytes (cond (limit (%read-capped body limit url))
                                         ((streamp body) (%read-to-end body))
                                         (t (%as-octets body))))))
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
          (error (%transport-error-class e)
                 :detail (format nil "transport error: ~A" e)
                 :phase (%transport-phase e (request-connect-address req)
                                          :pooled (%pooled-p req))))))))

(defun %call-with-deadline (deadline url thunk)
  "Call THUNK with FETCH-PUBLIC's deadline watch running (#807), and signal
REQUEST-DEADLINE-EXCEEDED for URL if DEADLINE seconds pass first (#1162). The timer, the watch and
the rule that any failure after the deadline is the deadline's doing are FETCH-PUBLIC's, in the
same order."
  (let* ((watch (%make-watch))
         ;; THREAD-LIFETIME: a timer made with :THREAD T starts its thread only when it fires.
         ;; That thread runs %FIRE once, a socket shutdown under the watch's lock, and ends. A
         ;; call that finishes first unschedules the timer below, and then no thread is made.
         ;; INTERRUPTS: not needed -- SBCL makes the thread, which runs one shutdown and ends, as
         ;; for FETCH-PUBLIC's timer. Nothing interrupts it.
         (timer (sb-ext:make-timer (lambda () (%fire watch))
                                   :thread t :name "send-request deadline"))
         (*%watch* watch)
         (*%deadline-hop* (list url)))
    (flet ((check ()
             (when (%fired-p watch)
               (error 'request-deadline-exceeded :url (car *%deadline-hop*)
                                                 :deadline deadline))))
      (sb-ext:schedule-timer timer deadline)
      (unwind-protect
           (handler-bind ((error (lambda (e)
                                   (unless (typep e 'fetch-deadline-exceeded) (check)))))
             (prog1 (funcall thunk) (check)))
        ;; The socket is taken from the watch before the timer is unscheduled, so a timer that
        ;; fires in between finds nothing to shut down.
        (%take-back-socket)
        (sb-ext:unschedule-timer timer)))))

(defun send-request (request interceptors &key (perform #'%http) deadline)
  "Run REQUEST through INTERCEPTORS around one HTTP round-trip and return the processed
RESPONSE. ENTER runs forward, the round-trip is the effect, LEAVE runs in reverse.

PERFORM is the effect, and is a parameter so a caller can substitute one -- which is how this
is tested without a network, and how a consumer stubs it. The default performs the real call.

DEADLINE, in seconds, limits the round-trip as a whole, over every redirect (#1162). Without it a
call is bounded only by the connect timeout and the read timeout, and the read timer starts again
on every read, so a server that sends a few bytes at a time can hold the call indefinitely. When
the deadline passes, the socket in use is shut down and the call signals
REQUEST-DEADLINE-EXCEEDED, a subclass of FETCH-DEADLINE-EXCEEDED. This is FETCH-PUBLIC's deadline
(#807) and has its limits: it covers the TLS handshake, the request, the headers and the body, and
it does not interrupt resolving a host name or opening the TCP connection, which are checked when
they return. The interceptors run outside it.

WITH A DEADLINE THE REQUEST IS SENT OVER CONNECTIONS THIS CLIENT OPENS ITSELF, as FETCH-PUBLIC's
are, because only such a socket can be shut down when the deadline passes; see
%HTTP-UNDER-DEADLINE. Every hop's redirect is followed by this client, and a request that would go
through a proxy is refused. NIL, the default, sets no deadline and changes nothing.

A PERFORM other than the default is run under the deadline too, but only a socket lent to the
watch can be woken, so for a stub the deadline is checked when PERFORM returns."
  (let* ((entered (reduce (lambda (r ic) (funcall (interceptor-enter ic) r))
                          interceptors :initial-value request))
         (resp (if deadline
                   (%call-with-deadline deadline (request-url entered)
                                        (lambda () (funcall perform entered)))
                   (funcall perform entered))))
    (reduce (lambda (r ic) (funcall (interceptor-leave ic) r))
            (reverse interceptors) :initial-value resp)))

;;; --- response helpers -----------------------------------------------------

(defun header-value (headers name)
  "Case-insensitive header lookup. HEADERS is dexador's hash-table (lowercased keys) or NIL."
  (when (hash-table-p headers)
    (gethash (string-downcase name) headers)))
