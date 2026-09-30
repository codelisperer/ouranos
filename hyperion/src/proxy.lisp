;;;; proxy.lisp --- the client's address and scheme behind a trusted proxy (#381).
;;;;
;;;; Behind a reverse proxy or a CDN, the env's :REMOTE-ADDR is the proxy, not the client, so
;;;; every visitor shares one rate-limit bucket and one address in the logs. The proxy reports
;;;; the client in X-Forwarded-For, or in a header of its own such as CF-Connecting-IP, but a
;;;; client can send those headers too. Keying on the last X-Forwarded-For entry gets the
;;;; nearest proxy, which on a CDN changes with every request; keying on the first gets
;;;; whatever the client wrote. The right answer depends on which proxies the app trusts, so
;;;; the app says so once, in *TRUSTED-PROXY*, and everything that needs the client's address
;;;; asks CLIENT-ADDRESS.
;;;;
;;;; A FORWARDED HEADER COUNTS ONLY WHEN THE PEER IS A TRUSTED PROXY. With no setting, which is
;;;; the default, CLIENT-ADDRESS is :REMOTE-ADDR whatever the headers say, as before #381.
;;;;
;;;; ONE SETTING, TWO READERS. The same setting decides whether X-Forwarded-Proto is believed
;;;; (REQUEST-SCHEME), which is what #300's `:secure :auto' for session cookies needs.

(in-package #:hyperion/proxy)

;;; --- addresses ----------------------------------------------------------------------

(defun %parse-ipv4 (string)
  "STRING as a 32-bit integer when it is a dotted IPv4 address, else NIL."
  (let ((parts (uiop:split-string string :separator ".")))
    (when (= 4 (length parts))
      (let ((n 0))
        (dolist (part parts n)
          (unless (and (<= 1 (length part) 3) (every #'digit-char-p part))
            (return nil))
          (let ((octet (parse-integer part)))
            (when (> octet 255) (return nil))
            (setf n (+ (* n 256) octet))))))))

(defun %parse-hex-groups (string)
  "The 16-bit groups of STRING, a colon-separated run of IPv6 groups whose last may be a dotted
IPv4 address, as a list, or :INVALID."
  (if (zerop (length string))
      '()
      (let ((groups '())
            (parts (uiop:split-string string :separator ":")))
        (loop for (part . more) on parts
              do (cond ((and (null more) (find #\. part))
                        (let ((v4 (%parse-ipv4 part)))
                          (unless v4 (return-from %parse-hex-groups :invalid))
                          (push (ash v4 -16) groups)
                          (push (logand v4 #xffff) groups)))
                       ((and (<= 1 (length part) 4) (every (lambda (c) (digit-char-p c 16)) part))
                        (push (parse-integer part :radix 16) groups))
                       (t (return-from %parse-hex-groups :invalid))))
        (nreverse groups))))

(defun %parse-ipv6 (string)
  "STRING as a 128-bit integer when it is an IPv6 address (with :: compression, a zone id after
% ignored), else NIL."
  (let* ((string (subseq string 0 (or (position #\% string) (length string))))
         (gap (search "::" string)))
    (when (and (find #\: string) (or (null gap) (null (search "::" string :start2 (1+ gap)))))
      (let* ((head (%parse-hex-groups (if gap (subseq string 0 gap) string)))
             (tail (if gap (%parse-hex-groups (subseq string (+ gap 2))) '())))
        (unless (or (eq head :invalid) (eq tail :invalid))
          (let ((missing (- 8 (length head) (length tail))))
            (when (if gap (>= missing 1) (zerop missing))
              (reduce (lambda (n g) (+ (* n 65536) g))
                      (append head (make-list missing :initial-element 0) tail)
                      :initial-value 0))))))))

(defun parse-address (string)
  "STRING as (values INTEGER BITS), BITS being 32 for IPv4 and 128 for IPv6, or NIL when it is
not an address. An IPv4-mapped IPv6 address (::ffff:a.b.c.d) is its IPv4 address."
  (when (stringp string)
    (let ((v4 (%parse-ipv4 string)))
      (if v4
          (values v4 32)
          (let ((v6 (%parse-ipv6 string)))
            (cond ((null v6) nil)
                  ((= (ash v6 -32) #xffff) (values (logand v6 #xffffffff) 32))
                  (t (values v6 128))))))))

(defun %strip-port (entry)
  "ENTRY, an X-Forwarded-For entry, without a port or the brackets around an IPv6 address:
\"1.2.3.4:5678\" is \"1.2.3.4\", \"[2001:db8::1]:443\" is \"2001:db8::1\"."
  (let ((e (string-trim '(#\Space #\Tab #\") entry)))
    (cond ((and (plusp (length e)) (char= (char e 0) #\[))
           (subseq e 1 (or (position #\] e) (length e))))
          ((= 1 (count #\: e)) (subseq e 0 (position #\: e)))
          (t e))))

(defun %canonical (entry)
  "ENTRY as the client address to report: without its port or brackets, lowercased."
  (string-downcase (%strip-port entry)))

;;; --- ranges --------------------------------------------------------------------------

(defstruct (cidr (:constructor %make-cidr (text network bits prefix)))
  "An address range: TEXT as given, the NETWORK number, the family's BITS, and the PREFIX length."
  text network bits prefix)

(defun parse-cidr (string)
  "STRING, an address or an address/prefix range such as \"10.0.0.0/8\" or \"2400:cb00::/32\", as
a CIDR. Signals an error for anything else, since a trust setting that silently trusted nothing,
or everything, would be worse than a refused one."
  (let* ((slash (position #\/ string))
         (address (if slash (subseq string 0 slash) string)))
    (multiple-value-bind (n bits) (parse-address address)
      (unless n
        (error "hyperion/proxy: ~S is not an address or an address range" string))
      (let ((prefix (if slash
                        (let ((p (ignore-errors (parse-integer string :start (1+ slash)))))
                          (unless (and p (<= 0 p bits))
                            (error "hyperion/proxy: ~S has a prefix length outside 0 to ~D" string bits))
                          p)
                        bits)))
        (%make-cidr string (logand n (ash (1- (ash 1 prefix)) (- bits prefix))) bits prefix)))))

(defun cidr-contains-p (cidr address)
  "True when ADDRESS, a string, is an address in CIDR."
  (multiple-value-bind (n bits) (parse-address address)
    (and n (= bits (cidr-bits cidr))
         (= (ash n (- (cidr-prefix cidr) bits))
            (ash (cidr-network cidr) (- (cidr-prefix cidr) bits))))))

;;; --- the setting ---------------------------------------------------------------------

(defstruct (proxy-trust (:constructor %make-proxy-trust (hops cidrs header)))
  "Which proxies an app trusts. Made by MAKE-PROXY-TRUST."
  hops cidrs header)

(defun make-proxy-trust (&key hops cidrs header)
  "The proxies in front of the app, in one of two ways:

  :HOPS N         N proxies, the nearest of them the TCP peer. The client is the address N
                  entries from the right of X-Forwarded-For with the peer after it. Use it when
                  every request comes through the same N proxies.
  :CIDRS LIST     proxies are the peers whose address is in LIST, a list of address ranges
                  such as \"10.0.0.0/8\". The client is the rightmost address, from the peer
                  leftwards through X-Forwarded-For, that is not in LIST.
  :HEADER NAME    with :CIDRS, a header the platform sets to the client's address, such as
                  \"CF-Connecting-IP\". It is read only when the peer is in LIST, and
                  X-Forwarded-For is used when it is absent.

Signals an error for anything else, including both :HOPS and :CIDRS."
  (cond ((and hops cidrs) (error "hyperion/proxy: give :hops or :cidrs, not both"))
        ((and hops header) (error "hyperion/proxy: :header needs :cidrs, the proxies whose header is believed"))
        (hops (unless (typep hops '(integer 1))
                (error "hyperion/proxy: :hops must be a positive integer, not ~S" hops))
              (%make-proxy-trust hops nil nil))
        (cidrs (unless (and (listp cidrs) (every #'stringp cidrs))
                 (error "hyperion/proxy: :cidrs must be a list of address ranges, not ~S" cidrs))
               (unless (or (null header) (and (stringp header) (plusp (length header))))
                 (error "hyperion/proxy: :header must be a header name, not ~S" header))
               (%make-proxy-trust nil (mapcar #'parse-cidr cidrs)
                                  (and header (string-downcase header))))
        (t (error "hyperion/proxy: give :hops or :cidrs"))))

(defvar *trusted-proxy* nil
  "The app's PROXY-TRUST, from MAKE-PROXY-TRUST, or NIL, the default, when it trusts no proxy.
Read at each request by CLIENT-ADDRESS and REQUEST-SCHEME, and so by
HYPERION/RATELIMIT:BY-ADDRESS and the request log.")

;;; --- the readers ---------------------------------------------------------------------

(defun %header (env name)
  (let ((h (getf env :headers)))
    (and (hash-table-p h) (gethash name h))))

(defun %forwarded-chain (env peer)
  "The X-Forwarded-For entries of ENV, left to right, followed by PEER."
  (let ((xff (%header env "x-forwarded-for")))
    (append (and (stringp xff)
                 (remove "" (mapcar (lambda (e) (string-trim '(#\Space #\Tab) e))
                                    (uiop:split-string xff :separator ","))
                         :test #'string=))
            (list peer))))

(defun %in-cidrs-p (trust address)
  (some (lambda (c) (cidr-contains-p c (%strip-port address))) (proxy-trust-cidrs trust)))

(defun trusted-peer-p (env &key (trust *trusted-proxy*))
  "True when ENV's TCP peer is a proxy TRUST believes: always with :HOPS, and with :CIDRS when
the peer's address is in them. NIL with no TRUST."
  (let ((peer (getf env :remote-addr)))
    (cond ((null trust) nil)
          ((proxy-trust-hops trust) t)
          (t (and peer (%in-cidrs-p trust (princ-to-string peer)) t)))))

(defun client-address (env &key (trust *trusted-proxy*))
  "The address of the client that sent ENV, as a string without a port, or NIL when ENV has no
:REMOTE-ADDR (#381). With no TRUST it is :REMOTE-ADDR, whatever the headers say. Otherwise see
MAKE-PROXY-TRUST: forwarded headers are read only as far as TRUST vouches for who wrote them, so
a client that adds entries on the left of X-Forwarded-For changes nothing."
  (let ((peer (getf env :remote-addr)))
    (cond
      ((null peer) nil)
      ((null trust) (princ-to-string peer))
      ((proxy-trust-hops trust)
       (let* ((chain (%forwarded-chain env (princ-to-string peer)))
              (index (- (length chain) 1 (proxy-trust-hops trust))))
         ;; Fewer entries than hops: the leftmost is as far as the chain goes.
         (%canonical (nth (max 0 index) chain))))
      ((not (%in-cidrs-p trust (princ-to-string peer)))
       ;; The peer is not a trusted proxy, so nothing it forwards is believed.
       (%canonical (princ-to-string peer)))
      (t
       (let ((named (and (proxy-trust-header trust) (%header env (proxy-trust-header trust)))))
         (if (and (stringp named) (parse-address (%strip-port named)))
             (%canonical named)
             (let ((chain (%forwarded-chain env (princ-to-string peer))))
               (loop for rest on (reverse chain)
                     for entry = (first rest)
                     when (or (null (rest rest)) (not (%in-cidrs-p trust entry)))
                       return (%canonical entry)))))))))

(defun request-scheme (env &key (trust *trusted-proxy*))
  "The scheme the client used, :HTTPS or :HTTP. X-Forwarded-Proto decides it when ENV's peer is
a proxy TRUST believes (TRUSTED-PEER-P); otherwise the env's own :URL-SCHEME does. This is the
reader #300's `:secure :auto' needs."
  (let* ((forwarded (and (trusted-peer-p env :trust trust) (%header env "x-forwarded-proto")))
         (scheme (string-downcase
                  (string-trim " " (if (stringp forwarded)
                                       (first (uiop:split-string forwarded :separator ","))
                                       (princ-to-string (or (getf env :url-scheme) "http")))))))
    (if (string= scheme "https") :https :http)))
