;;;; client.lisp --- an interceptor-shaped HTTP client around dexador.
;;;;
;;;; The "flipped" interceptor, for one outbound call: ENTER stages build the request, a
;;;; single dexador round-trip is the one effect at the edge, LEAVE stages process the
;;;; response, running in reverse so the outermost interceptor wraps everything.
;;;;
;;;; Moved out of hermes (#202), where it was internal and unexported while praxeon
;;;; independently reimplemented it as three raw dex:post calls. Same argument as #177: the
;;;; shape is request-response, not web, and a concept already reimplemented once is not
;;;; owned by whoever happened to hold it first.

(cl:in-package #:aion/http-client)

;;; --- failure --------------------------------------------------------------

(define-condition http-error (error)
  ((status :initarg :status :initform nil :reader http-error-status)
   (body :initarg :body :initform nil :reader http-error-body)
   (label :initarg :label :initform nil :reader http-error-label)
   (detail :initarg :detail :initform nil :reader http-error-detail))
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
endpoint. It carries no semantics here."))

;;; --- the values -----------------------------------------------------------

(defstruct (request (:constructor make-request (&key (method :get) url
                                                     (headers '()) content
                                                     connect-timeout read-timeout)))
  "An outbound HTTP request being built. HEADERS is an alist of (name . value); CONTENT is a
JSON/string body or an alist (dexador form-encodes an alist).

TIMEOUTS are here rather than absent because the client's second consumer needed them and
its first did not: praxeon hand-rolled dexador partly because this client could not express
a read timeout, and an LLM call without one can hang for as long as a provider is willing to
hold the socket. NIL leaves dexador's own default in place."
  (method :get :type keyword)
  (url "" :type string)
  (headers (quote ()) :type list)
  (content nil)
  (connect-timeout nil)
  (read-timeout nil))

(defparameter +no-bytes+
  (make-array 0 :element-type '(unsigned-byte 8))
  "The empty body. A constant so an absent body is still a vector, never NIL -- both
accessors below are total, and totality is the entire point of this shape.")

(defstruct (response (:constructor %make-response (status headers bytes))
                     (:predicate responsep))
  "An HTTP response. STATUS is the integer code.

WHAT THE BODY IS -- the contract, decided in #223 rather than defaulted into. The response
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
                             (make-request :method (request-method req)
                                           :url (request-url req)
                                           :headers (cons (cons name value)
                                                          (request-headers req))
                                           :content (request-content req)
                                           ;; carry the timeouts, or a header stage
                                           ;; would silently reset them
                                           :connect-timeout (request-connect-timeout req)
                                           :read-timeout (request-read-timeout req)))))

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
                                      :body (response-body resp)))
                             resp)))

;;; --- the runner (enter -> the one effect -> leave) ------------------------

(defun %http (req)
  "Perform the single dexador round-trip for REQ, returning a RESPONSE.

A non-2xx is captured as a RESPONSE rather than signalled -- dexador would signal, and that
would decide the meaning of a status before any LEAVE stage got to. A transport-level failure
has no response to hand back, so it signals HTTP-ERROR directly."
  (handler-case
      (multiple-value-bind (body status headers)
          (apply #'dex:request (request-url req)
                 :method (request-method req)
                 :headers (request-headers req)
                 :content (request-content req)
                 ;; ALWAYS binary (#223). Left to itself dexador decides by content-type
                 ;; and hands back a string for anything it considers text -- at which
                 ;; point the octets are gone and no caller can get them back. Decoding is
                 ;; this client's job now, and it happens in RESPONSE-BODY, once, from
                 ;; bytes that are still there.
                 :force-binary t
                 ;; Passed only when set, so an unset timeout means dexador's default
                 ;; rather than an explicit NIL, which it treats differently.
                 (append (when (request-connect-timeout req)
                           (list :connect-timeout (request-connect-timeout req)))
                         (when (request-read-timeout req)
                           (list :read-timeout (request-read-timeout req)))))
        (make-response :status status :headers headers :bytes (%as-octets body)))
    (dexador.error:http-request-failed (e)
      ;; No decode here, deliberately. This runs INSIDE a handler-case handler, so
      ;; anything it signals escapes the handler-case entirely -- and the old code decoded
      ;; here, strictly, meaning a non-2xx whose body was not valid UTF-8 raised a raw
      ;; INVALID-UTF8-STARTER-BYTE instead of the HTTP-ERROR that describes the failure.
      ;; Storing bytes cannot fail.
      (make-response :status (dexador.error:response-status e)
                     :headers (ignore-errors (dexador.error:response-headers e))
                     :bytes (%as-octets (dexador.error:response-body e))))
    (error (e)
      (error 'http-error :detail (format nil "transport error: ~A" e)))))

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
