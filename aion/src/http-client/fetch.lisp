;;;; fetch.lisp --- fetching a URL a user supplied (#295).
;;;;
;;;; An admin pastes a URL and the app fetches it. Without care that is a server-side request
;;;; forgery: the URL can name the app's own loopback interface, a private address, or the cloud
;;;; metadata service at 169.254.169.254, and a redirect can lead there from a URL that looked
;;;; public. A host name can also resolve to a public address when it is checked and a private
;;;; one when the client connects (DNS rebinding), so checking the name is not enough.
;;;;
;;;; FETCH-PUBLIC therefore resolves the host itself, refuses it if any address is not public,
;;;; and connects to the address it checked (CONNECT-ADDRESS), keeping the host name for the
;;;; Host header and for TLS. It follows redirects itself, one hop at a time, and checks each
;;;; hop the same way. The body is capped.

(cl:in-package #:aion/http-client)

;;; --- addresses ---------------------------------------------------------------------

(defun %parse-ipv4 (string)
  "STRING as a 4-octet vector if it is a dotted IPv4 address, else NIL."
  (let ((parts (uiop:split-string string :separator ".")))
    (when (= 4 (length parts))
      (let ((octets (mapcar (lambda (p)
                              (and (plusp (length p)) (<= (length p) 3)
                                   (every #'digit-char-p p)
                                   (let ((n (parse-integer p))) (and (<= n 255) n))))
                            parts)))
        (when (every #'integerp octets)
          (coerce octets '(vector (unsigned-byte 8))))))))

(defun %parse-ipv6 (string)
  "STRING as a 16-octet vector if it is a textual IPv6 address, else NIL. Accepts :: and a
trailing dotted IPv4 part."
  (when (and (find #\: string) (every (lambda (c) (or (digit-char-p c 16) (member c '(#\: #\.))))
                                       string))
    (let* ((double (search "::" string))
           (groups
             (flet ((split (s) (if (string= s "") '() (uiop:split-string s :separator ":"))))
               (if double
                   (list (split (subseq string 0 double)) (split (subseq string (+ double 2))))
                   (list (split string) nil))))
           (words '()))
      (when (and double (search "::" string :start2 (1+ double))) (return-from %parse-ipv6 nil))
      (flet ((words-of (parts)
               (loop for p in parts
                     append (cond ((find #\. p)
                                   (let ((v4 (%parse-ipv4 p)))
                                     (unless v4 (return-from %parse-ipv6 nil))
                                     (list (+ (* 256 (aref v4 0)) (aref v4 1))
                                           (+ (* 256 (aref v4 2)) (aref v4 3)))))
                                  ((and (plusp (length p)) (<= (length p) 4))
                                   (list (parse-integer p :radix 16)))
                                  (t (return-from %parse-ipv6 nil))))))
        (let* ((head (words-of (first groups)))
               (tail (words-of (second groups)))
               (missing (- 8 (length head) (length tail))))
          (cond ((and double (>= missing 1)) (setf words (append head (make-list missing :initial-element 0) tail)))
                ((and (not double) (= missing 0)) (setf words head))
                (t (return-from %parse-ipv6 nil)))))
      (let ((v (make-array 16 :element-type '(unsigned-byte 8))))
        (loop for w in words for i from 0 by 2
              do (setf (aref v i) (ash w -8) (aref v (1+ i)) (logand w #xff)))
        v))))

(defun parse-address (x)
  "X as an octet vector of 4 or 16 elements: X may already be one, or an IPv4 or IPv6 address
in text, with or without the brackets a URL puts around IPv6. NIL if X is not an address."
  ;; STRING FIRST: a string is a vector, so a VECTOR clause before it would take every string.
  (etypecase x
    (string (let ((s (string-trim "[]" x)))
              (or (%parse-ipv4 s) (%parse-ipv6 s))))
    ((vector (unsigned-byte 8)) (and (member (length x) '(4 16)) x))
    (vector (and (member (length x) '(4 16)) (every (lambda (n) (typep n '(unsigned-byte 8))) x)
                 (coerce x '(vector (unsigned-byte 8)))))))

(defun address-string (address)
  "ADDRESS (an octet vector) as text."
  (if (= 4 (length address))
      (format nil "~{~D~^.~}" (coerce address 'list))
      (format nil "~{~(~X~)~^:~}"
              (loop for i below 16 by 2
                    collect (+ (* 256 (aref address i)) (aref address (1+ i)))))))

(defun %in-prefix-p (address prefix bits)
  "Is ADDRESS inside PREFIX/BITS? Both are octet vectors of the same length."
  (loop for bit below bits
        always (let ((i (floor bit 8)) (mask (ash #x80 (- (mod bit 8)))))
                 (= (logand (aref address i) mask) (logand (aref prefix i) mask)))))

(defparameter +ipv4-ranges+
  ;; Most specific first where ranges nest: 255.255.255.255 before 240/4.
  '((#(255 255 255 255) 32 :broadcast)
    (#(0 0 0 0)         8  :unspecified)   ; "this network"
    (#(10 0 0 0)        8  :private)
    (#(100 64 0 0)      10 :shared)        ; carrier-grade NAT
    (#(127 0 0 0)       8  :loopback)
    (#(169 254 0 0)     16 :link-local)    ; includes the metadata service, 169.254.169.254
    (#(172 16 0 0)      12 :private)
    (#(192 0 0 0)       24 :reserved)      ; IETF protocol assignments
    (#(192 0 2 0)       24 :documentation)
    (#(192 88 99 0)     24 :reserved)      ; the retired 6to4 relay anycast
    (#(192 168 0 0)     16 :private)
    (#(198 18 0 0)      15 :benchmarking)
    (#(198 51 100 0)    24 :documentation)
    (#(203 0 113 0)     24 :documentation)
    (#(224 0 0 0)       4  :multicast)
    (#(240 0 0 0)       4  :reserved))
  "IPv4 ranges that are not public: (prefix bits category).")

(defparameter +ipv6-ranges+
  '((#(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0) 128 :unspecified)
    (#(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1) 128 :loopback)
    (#(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0) 96  :reserved)      ; the deprecated IPv4-compatible form
    (#(1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0) 64  :reserved)      ; discard-only
    (#(32 1 13 184 0 0 0 0 0 0 0 0 0 0 0 0) 32 :documentation) ; 2001:db8::/32
    (#(32 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0) 23 :reserved)      ; IETF protocol assignments, Teredo
    (#(252 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0) 7 :private)       ; fc00::/7, unique local
    (#(254 128 0 0 0 0 0 0 0 0 0 0 0 0 0 0) 10 :link-local) ; fe80::/10
    (#(254 192 0 0 0 0 0 0 0 0 0 0 0 0 0 0) 10 :reserved)   ; fec0::/10, retired site-local
    (#(255 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0) 8 :multicast))
  "IPv6 ranges that are not public: (prefix bits category).")

(defun %embedded-ipv4 (address)
  "The IPv4 address an IPv6 ADDRESS carries, for the forms that carry one: IPv4-mapped
(::ffff:0:0/96), NAT64 (64:ff9b::/96) and 6to4 (2002::/16). NIL otherwise."
  (flet ((octets (start) (subseq address start (+ start 4))))
    (cond ((%in-prefix-p address #(0 0 0 0 0 0 0 0 0 0 255 255 0 0 0 0) 96) (octets 12))
          ((%in-prefix-p address #(0 100 255 155 0 0 0 0 0 0 0 0 0 0 0 0) 96) (octets 12))
          ((%in-prefix-p address #(32 2 0 0 0 0 0 0 0 0 0 0 0 0 0 0) 16) (octets 2)))))

(defun address-category (address)
  "What ADDRESS is: :PUBLIC, or the reason it is not -- :LOOPBACK, :PRIVATE, :LINK-LOCAL,
:UNSPECIFIED, :MULTICAST, :BROADCAST, :SHARED, :DOCUMENTATION, :BENCHMARKING or :RESERVED.
ADDRESS is an octet vector or text (see PARSE-ADDRESS). An IPv6 address that carries an IPv4
address (IPv4-mapped, NAT64, 6to4) is classified by the IPv4 address it carries, so
::ffff:127.0.0.1 is :LOOPBACK."
  (let ((a (or (parse-address address)
               (error "aion/http-client: ~S is not an IP address" address))))
    (if (= 4 (length a))
        (or (loop for (prefix bits category) in +ipv4-ranges+
                  when (%in-prefix-p a prefix bits) return category)
            :public)
        (let ((inner (%embedded-ipv4 a)))
          (if inner
              (address-category inner)
              (or (loop for (prefix bits category) in +ipv6-ranges+
                        when (%in-prefix-p a prefix bits) return category)
                  :public))))))

(defun resolve-host (host)
  "The addresses HOST resolves to, as octet vectors; NIL when it does not resolve. A host that is
an IP address in text resolves to itself."
  (let ((literal (parse-address host)))
    (if literal
        (list literal)
        (handler-case
            (mapcar #'parse-address (usocket:get-hosts-by-name host))
          (error () nil)))))

;;; --- a connection to a chosen address ------------------------------------------------

#-windows
(defun %request-pinned (req)
  "Run REQ over a connection to its CONNECT-ADDRESS, returning what DEX:REQUEST returns.

The socket is opened here, to that address. For https the TLS handshake uses the URL's host
name, so the server is asked for that name (SNI) and its certificate is verified against that
name, not against the address. DEX:REQUEST then writes the request on this connection, so the
Host header is the URL's too."
  (let* ((uri (quri:uri (request-url req)))
         (host (quri:uri-host uri))
         (address (or (parse-address (request-connect-address req))
                      (error 'http-error
                             :detail (format nil "connect-address ~S is not an IP address"
                                             (request-connect-address req)))))
         (socket (usocket:socket-connect address (quri:uri-port uri)
                                         :element-type '(unsigned-byte 8)
                                         :timeout (request-connect-timeout req)))
         (body-owns-connection nil))
    (unwind-protect
         (let ((stream (usocket:socket-stream socket)))
           (when (request-read-timeout req)
             (setf (usocket:socket-option socket :receive-timeout) (request-read-timeout req)))
           (when (string-equal (quri:uri-scheme uri) "https")
             (cl+ssl:ensure-initialized)
             (let ((context (cl+ssl:make-context
                             :verify-mode cl+ssl:+ssl-verify-peer+
                             :verify-location (if (request-ca-path req)
                                                  (uiop:native-namestring (request-ca-path req))
                                                  :default))))
               (cl+ssl:with-global-context (context :auto-free-p t)
                 (setf stream (cl+ssl:make-ssl-client-stream stream :hostname host
                                                                    :verify :required)))))
           (multiple-value-bind (body status headers)
               (apply #'dex:request (request-url req) :stream stream
                      :use-connection-pool nil :keep-alive nil (%dex-args req))
             ;; A streamed body (MAX-BODY-BYTES) still needs the connection, and
             ;; %READ-CAPPED closes it when it has read enough. Otherwise the connection is
             ;; finished with here.
             (setf body-owns-connection (streamp body))
             (values body status headers)))
      (unless body-owns-connection
        (ignore-errors (usocket:socket-close socket))))))

#+windows
(defun %request-pinned (req)
  (error 'pinned-connect-unsupported
         :detail (format nil "cannot connect ~A to ~A: on Windows dexador uses WinHTTP, which does not accept a connection opened by the caller"
                         (request-url req) (request-connect-address req))))

;;; --- fetch-public ------------------------------------------------------------------

(defparameter *fetch-public-max-body-bytes* (* 10 1024 1024)
  "FETCH-PUBLIC's default body limit: 10 MiB.")

(defun %origin (uri)
  (list (string-downcase (or (quri:uri-scheme uri) ""))
        (string-downcase (or (quri:uri-host uri) ""))
        (quri:uri-port uri)))

(defun %without-credentials (headers)
  (remove-if (lambda (h) (member (string (car h)) '("authorization" "cookie")
                                 :test #'string-equal))
             headers))

(defun %checked-address (url uri resolve address-policy)
  "The address to connect to for URI, after refusing anything FETCH-PUBLIC must not reach."
  (let ((host (quri:uri-host uri)))
    (unless (member (quri:uri-scheme uri) '("http" "https") :test #'equalp)
      (error 'fetch-refused :url url :reason :scheme))
    (unless (and host (plusp (length host)))
      (error 'fetch-refused :url url :reason :no-host))
    (let ((addresses (funcall resolve host)))
      (unless addresses
        (error 'fetch-refused :url url :host host :reason :unresolvable))
      ;; Every address, not only the one connected to: the same name may resolve to a
      ;; different one of them for the next caller, or the next hop.
      (dolist (a addresses)
        (let ((category (funcall address-policy a)))
          (unless (eq category :public)
            (error 'fetch-refused :url url :host host :address a :reason category))))
      (first addresses))))

(defun fetch-public (url &key (method :get) headers content
                           (max-redirects 5)
                           (max-body-bytes *fetch-public-max-body-bytes*)
                           connect-timeout read-timeout ca-path
                           (resolve #'resolve-host)
                           (address-policy #'address-category)
                           (perform #'%http))
  "Fetch URL, which a user supplied, and return the RESPONSE of the last hop. Any status is
returned as a response; apply ENSURE-2XX or similar to it as usual.

Before each connection, including each redirect, the host is resolved (RESOLVE), and if any of
its addresses is not :PUBLIC under ADDRESS-POLICY (ADDRESS-CATEGORY by default), the fetch
signals FETCH-REFUSED without connecting. Otherwise the connection is pinned to the checked
address (CONNECT-ADDRESS), so the host cannot resolve somewhere else in between.

Redirects are followed here, never by dexador: at most MAX-REDIRECTS, then
TOO-MANY-REDIRECTS. A redirect to another origin drops the Authorization and Cookie headers,
and a 301, 302 or 303 turns any method but GET or HEAD into a GET without a body. The body of
each response is limited to MAX-BODY-BYTES (RESPONSE-TOO-LARGE past it).

On Windows the pinned connection is not available and this signals
PINNED-CONNECT-UNSUPPORTED. RESOLVE, ADDRESS-POLICY and PERFORM are parameters for tests."
  (let ((hops 0))
    (loop
      (let* ((uri (quri:uri url))
             (address (%checked-address url uri resolve address-policy))
             (response (funcall perform
                                (make-request :method method :url url :headers headers
                                              :content content
                                              :connect-timeout connect-timeout
                                              :read-timeout read-timeout
                                              :follow-redirects nil
                                              :max-body-bytes max-body-bytes
                                              :connect-address address
                                              :ca-path ca-path)))
             (status (response-status response))
             (location (and (member status '(301 302 303 307 308))
                            (header-value (response-headers response) "location"))))
        (unless location (return response))
        (when (>= hops max-redirects)
          (error 'too-many-redirects :url url :limit max-redirects))
        (let ((next (quri:merge-uris (quri:uri location) uri)))
          (unless (equal (%origin next) (%origin uri))
            (setf headers (%without-credentials headers)))
          (when (and (member status '(301 302 303)) (not (member method '(:get :head))))
            (setf method :get content nil))
          (setf url (quri:render-uri next))
          (incf hops))))))
