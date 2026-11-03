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
      ;; A dotted IPv4 part may only be the last 32 bits of the address.
      (let* ((all (append (first groups) (second groups)))
             (dotted (position-if (lambda (p) (find #\. p)) all)))
        (when (and dotted (/= dotted (1- (length all))))
          (return-from %parse-ipv6 nil))
        (when (and dotted double (null (second groups)))
          ;; "1.2.3.4::" puts the dotted part before the zeros, so it is not the last 32 bits.
          (return-from %parse-ipv6 nil)))
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
  ;; Anything that is not a string or a vector is not an address either, so it gives NIL
  ;; rather than a type error.
  (typecase x
    (string (let ((s (string-trim "[]" x)))
              (or (%parse-ipv4 s) (%parse-ipv6 s))))
    ((vector (unsigned-byte 8)) (and (member (length x) '(4 16)) x))
    (vector (and (member (length x) '(4 16)) (every (lambda (n) (typep n '(unsigned-byte 8))) x)
                 (coerce x '(vector (unsigned-byte 8)))))
    (t nil)))

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

(defun %6to4-p (address)
  "Whether ADDRESS is a 6to4 address, 2002::/16. Such an address carries an IPv4 address, and
ADDRESS-CATEGORY classifies it by that inner address, so 2002:7f00:1:: reports :LOOPBACK. That
is the conservative answer for a guard deciding whether a destination may be reached at all,
which is what ADDRESS-CATEGORY is for. It is the WRONG answer for a decision about whether a
destination is local, because 6to4 traffic reaches its destination through a public relay, so
LOCAL-HOST-P excludes these (#1082, the review of #1084)."
  (let ((a (parse-address address)))
    (and a (= 16 (length a)) (%in-prefix-p a #(32 2 0 0 0 0 0 0 0 0 0 0 0 0 0 0) 16) t)))

(defun url-host (url)
  "URL's host, without brackets and without a port: \"http://[::1]:9000/x\" gives \"::1\". NIL when
URL has no host or cannot be parsed.

QURI is used because it is the parser dexador parses a request URL with, so a caller asking this
asks the same question of the same parser rather than of one of its own. It returns an IPv6 host
with its brackets, as the URL carries them, and every caller wants the address itself, because
that is what PARSE-ADDRESS and ADDRESS-CATEGORY read.

Both hermes core and hermes/blob had written this, and both had holes: see #1089 and the review
of #1084. It is here because it belongs next to the primitives it feeds, and because one copy
can be fixed once."
  (let* ((uri (ignore-errors (quri:uri url)))
         (host (and uri (quri:uri-host uri))))
    (if (and host (> (length host) 1)
             (char= #\[ (char host 0))
             (char= #\] (char host (1- (length host)))))
        (subseq host 1 (1- (length host)))
        host)))

(defun %nat64-p (address)
  "Whether ADDRESS is NAT64: the well-known prefix 64:ff9b::/96, or the local-use 64:ff9b:1::/48
of RFC 8215. Such an address carries an IPv4 address and ADDRESS-CATEGORY reports it by that, so
64:ff9b::7f00:1 reads :LOOPBACK.

EXCLUDED FROM LOCAL-HOST-P for the same reason as 6to4: reaching the IPv4 address means going
through a NAT64 gateway, which is frequently the carrier's rather than this network's, so the
bytes leave the machine and the network whatever the inner address says (#1082, the review of
#1094). ADDRESS-CATEGORY is left alone, because a guard deciding whether a destination may be
reached at all wants the conservative answer."
  (let ((a (parse-address address)))
    (and a (= 16 (length a))
         (or (%in-prefix-p a #(0 100 255 155 0 0 0 0 0 0 0 0 0 0 0 0) 96)
             (%in-prefix-p a #(0 100 255 155 0 1 0 0 0 0 0 0 0 0 0 0) 48))
         t)))

(defun %leading-zero-quad-p (host)
  "Whether HOST is dotted-quad IPv4 with a leading zero in an octet, such as \"010.0.0.1\".

REFUSED BY LOCAL-HOST-P, because this is the one IPv4 spelling where PARSE-ADDRESS and the
system resolver can disagree: PARSE-ADDRESS reads 010.8.8.8 as 10.8.8.8 and calls it private,
while a resolver reading the leading zero as octal gets something else, and the connection
follows the resolver. Rather than decide which reading is right, a host spelled this way is not
local (#1082, the review of #1094).

THE OTHER NON-CANONICAL SPELLINGS ARE DELIBERATELY NOT REFUSED. \"127.1\", \"0x7f.0.0.1\" and
\"2130706433\" all fail PARSE-ADDRESS, so LOCAL-HOST-P hands them to RESOLVE-HOST -- the same
system resolver the connection will use -- and takes the answer it gives. There is no
disagreement to guard against there, because only one parser is involved."
  (and (stringp host)
       (let ((parts '()) (start 0))
         (loop for dot = (position #\. host :start start)
               do (push (subseq host start (or dot (length host))) parts)
                  (unless dot (return))
                  (setf start (1+ dot)))
         (let ((parts (nreverse parts)))
           (and (= 4 (length parts))
                (every (lambda (p) (and (plusp (length p)) (every #'digit-char-p p))) parts)
                (some (lambda (p) (and (> (length p) 1) (char= #\0 (char p 0)))) parts))))))

(defun %local-address-p (address)
  "Whether ADDRESS, an octet vector or text, is one this machine or this network reaches by
itself: loopback, private or link-local, and neither 6to4 nor NAT64."
  (and (not (%6to4-p address))
       (not (%nat64-p address))
       (member (address-category address) '(:loopback :private :link-local))
       t))

(defun local-host-p (host)
  "Whether HOST names something only this machine or this network can reach, so sending it
requests in plaintext does not put them on the public internet. HOST is a name or an IP address
in text, without brackets or a port -- see URL-HOST.

\"localhost\" counts, without a lookup. An IP address counts when ADDRESS-CATEGORY says
:LOOPBACK, :PRIVATE or :LINK-LOCAL, except for a 6to4 (%6TO4-P) or NAT64 (%NAT64-P) address,
each of which reaches its destination through a gateway or relay that need not be this
network's, whatever IPv4 address it carries. A host spelled as dotted-quad IPv4 with a leading
zero is refused outright (%LEADING-ZERO-QUAD-P), and so is an empty or blank HOST, whose
meaning to a resolver is platform-dependent. Any other name is resolved,
and counts only when it resolves and EVERY address it resolves to is one of those, so a Docker
Compose service name works while a name pointing at the internet does not. A name that does not
resolve does not count: a host that cannot be reached is not a host known to be local.

THE NAME IS RESOLVED HERE AND NOW, once. A caller that asks this when it is configured, as
hermes and hermes/blob do, has an answer about that moment and not a standing guarantee.

WHY THIS IS IN AION RATHER THAN IN EACH CALLER. hermes core wrote it for a Twilio API base and
hermes/blob for an S3 endpoint, and the two copies acquired different holes -- a bracketed IPv6
userinfo got past one, a scheme in the endpoint got past the other, and a bucket label in front
of the host got past both (#1089, the review of #1084). A rule that decides whether credentials
may travel in the clear is the last rule that should exist twice (#1082)."
  (and host
       ;; A HOST HAS TO BE A HOST. An empty or blank string is refused before anything resolves
       ;; it, because what a resolver makes of one differs by platform: on Linux
       ;; usocket:get-hosts-by-name "" signals NS-HOST-NOT-FOUND-ERROR, so this answered NIL,
       ;; while on Windows getaddrinfo resolves an empty node name to the loopback address, so
       ;; this answered T -- truthfully about where Windows would connect, and wrongly about
       ;; whether a caller has a host at all. Measured: the Windows leg of run 41388319932
       ;; failed exactly this check while the other three legs passed (#1082).
       (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return) host)))
       (not (%leading-zero-quad-p host))
       (or (string-equal host "localhost")
           (let ((literal (parse-address host)))
             (if literal
                 (%local-address-p literal)
                 (let ((addresses (ignore-errors (resolve-host host))))
                   (and addresses (every #'%local-address-p addresses) t)))))))

(defun credential-url-refusal (value &key setting example credential
                                          (carried-in
                                           "every request carries them in an Authorization header")
                                          appends-path)
  "NIL when VALUE is a URL a framework may send CREDENTIAL to, and otherwise the sentence to
refuse it with (#1106). Second value: the parsed URI, or NIL when it did not parse. Third value:
the host approved as LOCAL, or NIL.

IT RETURNS A REASON RATHER THAN SIGNALLING, so each caller signals its own condition -- hermes
signals CONFIGURATION-ERROR, hermes/blob signals BLOB-CONFIGURATION-ERROR -- and this function
needs to know about neither. That is what lets the rule live here, beside LOCAL-HOST-P, with
nothing new in anyone's :DEPENDS-ON: hermes/blob does not depend on hermes core and must not
start to, and both already depend on aion/http-client.

WHY THE RULE IS IN ONE PLACE. It was written twice -- once in hermes for a Twilio API base, once
in hermes/blob for an S3 endpoint -- and the two copies acquired three different holes between
them, each a case the other's fix had already closed: a bracketed IPv6 address in the userinfo, a
scheme inside the endpoint, and a bucket label in front of the host (#1089, and the reviews of
#1084 and #1090). Every one was found by someone running the check rather than reading it. Four
more call sites deciding for themselves would have been the same bet four more times (#1106).

SETTING names the value in the message (`Twilio API-BASE'), EXAMPLE is a URL that would be
accepted, CREDENTIAL says what would travel (`the account SID and auth token', `the API key'),
CARRIED-IN is the whole clause after `because', so a caller can say how its own credential
travels in a sentence that reads correctly, and APPENDS-PATH says whether the caller appends a
path to VALUE. It is the clause rather than a noun phrase because the default read
`every request carries them in an Authorization header', and Telegram substituting into the tail
of that produced `carries them in the path of every request' -- a plural pronoun for one token,
and `every request' twice. Reading the output is what showed it.

CARRIED-IN EXISTS BECAUSE NOT EVERY CREDENTIAL IS A HEADER. Telegram's bot token is in the PATH
of every request, so a refusal reading `in an Authorization header' would tell the reader
something false about their own configuration -- and a token in a path is the more exposed of the
two, because it reaches any access log along the way.

NO REFUSAL REPEATS VALUE, OR QURI'S ERROR TEXT. The value may carry a password -- that is one of
the things refused -- and these reports reach logs and terminals. An earlier version printed it in
every branch, and its parse-failure branch also appended quri's error, which quotes the URI
again, so a password appeared twice (the review of #1084).

What is refused, and why each is here rather than only the obvious one:

  - anything QURI cannot parse. QURI is used because it is the parser dexador parses the request
    URL with, so this asks the same question of the same parser;
  - a scheme that is not http or https. Refusing only plaintext is not enough: for
    `evil.example://127.0.0.1' quri reads the scheme `evil.example' and the host 127.0.0.1, which
    a check looking for `http' lets through;
  - any userinfo, whatever the scheme and host, including over https and including when the host
    is local. No API here uses it, and its only effects are to hide the real host from a reader
    and to defeat this check;
  - no host;
  - a query or a fragment, but only when APPENDS-PATH: the request's path would land inside them.
    A caller that sends VALUE as it stands has no such problem, and refusing a query there would
    turn away a legitimate local mock;
  - a bracketed IPv6 host, which cannot be connected to -- usocket:socket-connect answers
    NS-HOST-NOT-FOUND-ERROR for `[::1]' while `::1' resolves;
  - plaintext http to a host this machine or this network cannot reach by itself, which is
    LOCAL-HOST-P. That function also refuses a leading-zero IPv4 spelling, where its parser and
    the system resolver can disagree.

The host is resolved at the moment this runs, once. A provider made while a name resolved locally
is not re-checked if that name later resolves elsewhere.

THE THIRD VALUE COSTS NO SECOND LOOKUP, because it is already known here: a plaintext URL this
function accepts is one whose host LOCAL-HOST-P approved, since the only other way out of that
branch is a refusal. A caller records it and binds it around the send, so the plaintext request is
not given to a proxy and does not follow redirects. It is NIL for an https URL, whose host is
never resolved here, which matches PROXY-ARGUMENTS: the proxy decision is only made for
plaintext. It is the host rather than T so that a recorded verdict cannot be read against a URL
it was not about."
  ;; CONTROL CHARACTERS ARE REFUSED FIRST, before the value is parsed. A newline in a URL is the
  ;; shape of a header injection, and although the credential would still have gone only to the
  ;; local host, a value that cannot appear in a URL has no reading worth arguing about. Refusing
  ;; it removes the question rather than answering it (the review of #1104).
  (when (and (stringp value)
             (some (lambda (c) (let ((n (char-code c))) (or (< n 32) (= n 127)))) value))
    (return-from credential-url-refusal
      (format nil "a ~A without control characters in it. The value contains at least one, and it is not repeated here because it may contain a password"
              setting)))
  (let ((uri (ignore-errors (quri:uri value))))
    (unless uri
      (return-from credential-url-refusal
        (format nil "a ~A that parses as a URL. The value given does not, and it is not repeated here because it may contain a password"
                setting)))
    (let ((scheme (quri:uri-scheme uri))
          (host (quri:uri-host uri)))
      (flet ((refuse (why)
               (return-from credential-url-refusal
                 (values (format nil "a ~A such as ~A. ~A" setting example why) uri nil))))
        (when (quri:uri-userinfo uri)
          (refuse (format nil "The value carries a user name or password before an at-sign, which this API does not use and which hides the host a request would reach. That host is ~S." host)))
        (unless (and scheme (or (string-equal scheme "https") (string-equal scheme "http")))
          (refuse (format nil "The scheme is ~S. Only http and https are sent, and another scheme means the host this check reads is not the host a request would reach." scheme)))
        (unless host
          (refuse "The value has no host."))
        (when (and appends-path (or (quri:uri-query uri) (quri:uri-fragment uri)))
          (refuse "The value carries a query or a fragment, and the rest of each request's path is appended to it, so the path would end up inside them."))
        (when (and (plusp (length host)) (char= #\[ (char host 0)))
          (refuse (format nil "The host ~S is a bracketed IPv6 address, which cannot be connected to: it is looked up as a name and no such name exists. Use a name that resolves to the address, or an IPv4 address. Writing the address without brackets is not a fix: an S3 endpoint in hermes/blob refuses that spelling too." host)))
        (when (and (string-equal scheme "http") (not (local-host-p host)))
          (refuse (format nil "The host ~S would receive ~A in the clear, because ~A. Use https, or a host only this machine or this network can reach."
                          host credential carried-in))))
      (values nil uri (and scheme (string-equal scheme "http") host)))))

(defvar *approved-local-host* nil
  "The host a configuration step resolved and approved as LOCAL, bound around a send by the code
that holds that verdict (#1091).

NOT EXPORTED, AND NOT AN ARGUMENT TO ANYTHING EXPORTED, which is the point of it. It was a
:APPROVED-LOCAL keyword on MAKE-REQUEST and on PROXY-ARGUMENTS, both exported, so any caller
could assert an approval for any host:

  (make-request :url \"http://public.example/x\" :approved-local \"public.example\"
                :headers <an Authorization header>)

got :PROXY NIL and :MAX-REDIRECTS 0 for a public host -- the same door that was closed by taking
the initarg off hermes/blob's slot, left open one layer down (the re-review of #1134). The
exported surface can no longer express an approval at all; what a caller builds its own request
with is the rule for an address or \"localhost\" and nothing else.

Bound with CALL-WITH-APPROVED-LOCAL-HOST, by hermes's providers and hermes/blob's S3 backend.
Reaching this symbol from outside takes a double-colon, which is the line this codebase draws
around anything a caller is not meant to use.

A DYNAMIC BINDING IS SAFE HERE BECAUSE OF THE HOST COMPARISON. The binding covers everything the
send does, including an interceptor that issues a request of its own, but PROXY-ARGUMENTS grants
nothing unless the URL's host equals this value, so the approval cannot spread to another host.")

(defun call-with-approved-local-host (host thunk)
  "Call THUNK with HOST bound as the approved local host (#1091). Not exported: see
*APPROVED-LOCAL-HOST*."
  (let ((*approved-local-host* host))
    (funcall thunk)))

(defun proxy-arguments (url)
  "The dexador keyword arguments that say how URL is to be proxied: (:PROXY NIL) for a plaintext
request to a host this machine reaches by itself, and no arguments otherwise (#1091).

*APPROVED-LOCAL-HOST* IS THE HOST a configuration step resolved and approved as local -- the
string, not a boolean -- and it grants the exemption only when it equals URL's host. A boolean
said only that somebody had approved something, which is not a statement about the request being
sent: a provider
whose URL had moved on, or a verdict recorded for one host and read while another was in the
slot, would have exempted a request to a host nothing had approved. Pass it from a recorded
verdict, not from a resolution made now; see below for why that distinction is the whole point.

AN APPROVED-LOCAL REQUEST ALSO STOPS FOLLOWING REDIRECTS, which is why :MAX-REDIRECTS 0 comes
back with the exemption in that case. dexador follows a redirect to a DIFFERENT host by recursing
with the same arguments and the same headers -- it prepends a new Host and keeps the rest
(src/backend/usocket.lisp, the cross-host branch of its redirect handling) -- so a 307 from the
approved host to http://public.example/ would be fetched with :PROXY NIL and with the
Authorization header built for the approved host. That is the credential leaving the machine, not
only a proxy being skipped. A 3xx is the response for such a request instead (the review of
#1134).

ONLY FOR AN APPROVED-LOCAL REQUEST, not for one exempted by the literal rule. The literal rule
has the same hazard in principle, and the same cause, which is dexador carrying headers across a
cross-host redirect; but it is the rule every caller of this client gets, redirect following to a
local server is behaviour this client documents and tests, and turning it off here broke
REDIRECTS-CAN-BE-REFUSED-CAPPED-OR-FOLLOWED, which follows redirects on a test server at
127.0.0.1. APPROVED-LOCAL is passed only by a configuration step that is about to send a
credential, and none of those three callers follows redirects, so the restriction costs them
nothing. The general case is dexador's behaviour rather than this rule's and is filed separately.

EVERY CALLER THAT SENDS A REQUEST MUST USE THIS, including one that calls dexador directly.
dexador sets *DEFAULT-PROXY* from HTTPS_PROXY or HTTP_PROXY when it loads and honours no
NO_PROXY, so a caller that has checked its destination is local can still have its credentials
carried off the machine in the clear, because the bytes go to the proxy rather than to the host
that was checked. The first version of this lived inside %DEX-ARGS, which meant hermes/blob's
S3 backend was NOT covered -- it calls dexador directly -- while the CHANGELOG and a comment
both said it was (the review of #1094).

NO NAME IS RESOLVED HERE, in either case. Without APPROVED-LOCAL the decision is made for
\"localhost\" and for IP literals only, and a DNS name keeps whatever proxy is configured. Two
reasons. A lookup on this path would be a blocking resolution on every plaintext request, which
CONNECT-TIMEOUT does not cover. And a name that answers private now can answer public at connect
time, which would mean skipping a configured egress proxy on the strength of a resolution that no
longer holds.

THAT IS WHY APPROVED-LOCAL IS A RECORDED VERDICT RATHER THAN A LOOKUP. \"This host was approved as
local when the configuration was built\" is a statement about the past, and it stays true; \"this
name resolves locally right now\" is a guess about the present, made on the send path, and it is
the thing the paragraph above refuses to do. A caller that has no configuration step passes
nothing and gets the literal rule.

Until a caller passed APPROVED-LOCAL the two answers disagreed for the same destination: a
plaintext store or provider at a NAME that resolves to a loopback address was approved for
plaintext at configuration time and then still sent its credentials to HTTP_PROXY in the clear,
because this function would not decide by name. Measured on Linux before the fix, with a name
/etc/hosts maps to a loopback address:

  <a local name>  local-host-p=T  proxy-arguments=NIL
  localhost       local-host-p=T  proxy-arguments=(:PROXY NIL)"
  (let* ((uri (ignore-errors (quri:uri url)))
         (scheme (and uri (quri:uri-scheme uri)))
         (host (and uri (url-host url))))
    (let ((approved (and (stringp *approved-local-host*) host
                         (string-equal *approved-local-host* host)
                         (and scheme (string-equal scheme "http")))))
      (cond (approved (list :proxy nil :max-redirects 0))
            ((and scheme (string-equal scheme "http") host
                  (or (string-equal host "localhost")
                      (let ((literal (parse-address host)))
                        (and literal (not (%leading-zero-quad-p host))
                             (%local-address-p literal)))))
             (list :proxy nil))
            (t '())))))

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

(defun %tls-names (host)
  "Two values for a TLS handshake to the URL host HOST: the name to send as SNI, and the name to
verify the server's certificate against.

For a host name, HOST both times. For an IP address (#915), NIL and the address as text: RFC 6066
allows no IP address in SNI, so none is sent, and a URL's IPv6 host carries brackets, [::1],
which are not part of the address. The text is usocket's rendering of the parsed address, which
is how cl+ssl writes a certificate's iPAddress entries before it compares them, so ::1 and
0:0:0:0:0:0:0:1 in a URL both match a certificate for ::1."
  (let ((address (parse-address host)))
    (if address
        (values nil (usocket:host-to-hostname address))
        (values host host))))

#-os-windows
(defun %verify-peer-name (stream name)
  "Verify the certificate the server on STREAM presented against NAME, and free it. Signals
HTTP-ERROR when the certificate does not name NAME.

THE SUBJECT ALTERNATIVE NAMES FIRST (#917). When the certificate has any dNSName or iPAddress
alternative name, NAME must match one of them, and its common name is not consulted, as RFC 6125
section 6.4.4 requires. Only a certificate with no such name is checked against its common name.
cl+ssl's own check, CL+SSL:VERIFY-HOSTNAME, falls back to the common name in both cases, so a
certificate for other names whose common name is NAME passed it.

Called for every pinned https connection: for a host name after cl+ssl's own check in the
handshake, which this narrows, and for an IP address (#915) as the only check, since no SNI name
was sent and cl+ssl verified the chain but not a name. Names are matched with cl+ssl's matcher,
so case and wildcards are treated as there. cl+ssl gives dNSName and iPAddress entries as one
list of text, so an address can match a dNSName entry that is the same text.

ONLY THE PINNED PATH (:CONNECT-ADDRESS, which FETCH-PUBLIC always uses). A request without
CONNECT-ADDRESS goes through dexador, where cl+ssl's own check is the only one, and a common name
is still accepted on a certificate with alternative names. Changing that would mean patching
cl+ssl for the whole image (#917)."
  (let ((certificate (cl+ssl:ssl-stream-x509-certificate stream)))
    (when (cffi:null-pointer-p certificate)
      (error 'http-error :detail "the server presented no certificate"))
    (unwind-protect
         ;; Entries of other kinds, such as an email address, come back as NIL and do not count.
         (let ((alternative-names (remove nil (cl+ssl::certificate-dns-alt-names certificate))))
           (unless (if alternative-names
                       (cl+ssl::try-match-hostnames alternative-names name)
                       (ignore-errors (cl+ssl:verify-hostname certificate name)))
             (error 'http-error
                    :detail (format nil "the server's certificate does not name ~A" name))))
      (cl+ssl:x509-free certificate))))

#-os-windows
(defun %request-pinned (req)
  "Run REQ over a connection to its CONNECT-ADDRESS, returning (values BODY STATUS HEADERS).

The socket is opened here, to that address and nowhere else. For https the TLS handshake uses
the URL's host name, so the server is asked for that name (SNI) and its certificate is verified
against that name, not against the address. When the URL's host is itself an IP address, no SNI
is sent and the certificate is verified against the address without its brackets (%TLS-NAMES,
#915). In both cases a certificate with alternative names must match one of them; its common
name counts only when it has none (%VERIFY-PEER-NAME, #917).

The request is written and the response read by http1.lisp, as on Windows (#536), whose limits
apply, and the Host header is the URL's. Until #985 this handed the connection to DEX:REQUEST,
which after any failure on it reconnected by resolving the URL's host and sent the request
again: a second connection that bypassed CONNECT-ADDRESS, and a request sent twice. Now a
failure is signalled from the one connection, and no request is sent twice.

The socket is lent to FETCH-PUBLIC's deadline watch, and the read timeout is the socket's
receive timeout. A body read as a stream (MAX-BODY-BYTES) keeps the connection, and closing the
body closes it; otherwise the body is read here and the connection closed. A non-2xx is returned
like any other response, while the connection is open, so its body is kept (#527)."
  (let* ((uri (quri:uri (request-url req)))
         (host (quri:uri-host uri))
         (address (or (parse-address (request-connect-address req))
                      (error 'http-error
                             :detail (format nil "connect-address ~S is not an IP address"
                                             (request-connect-address req)))))
         (socket (prog1 (usocket:socket-connect address (%port-of uri)
                                                :element-type '(unsigned-byte 8)
                                                :timeout (request-connect-timeout req))
                   ;; From here on a failure happened after the connection was made (#79).
                   (setf *%connected* t)))
         (stream nil)
         (body-owns-connection nil))
    (%lend-socket socket)
    (flet ((close-connection ()
             (%take-back-socket)
             (when stream (ignore-errors (close stream)))
             (ignore-errors (usocket:socket-close socket))))
      (unwind-protect
           (progn
             (setf stream (usocket:socket-stream socket))
             (when (request-read-timeout req)
               (setf (usocket:socket-option socket :receive-timeout) (request-read-timeout req)))
             (when (string-equal (quri:uri-scheme uri) "https")
               (cl+ssl:ensure-initialized)
               (let ((context (cl+ssl:make-context
                               :verify-mode cl+ssl:+ssl-verify-peer+
                               :verify-location (if (request-ca-path req)
                                                    (uiop:native-namestring (request-ca-path req))
                                                    :default))))
                 (multiple-value-bind (sni name) (%tls-names host)
                   (cl+ssl:with-global-context (context :auto-free-p t)
                     ;; With no SNI name, cl+ssl verifies the chain but not a name. Either way the
                     ;; name is verified here, alternative names first (#917).
                     (setf stream (cl+ssl:make-ssl-client-stream stream :hostname sni
                                                                        :verify :required))
                     (%verify-peer-name stream name)))))
             (multiple-value-bind (body status headers)
                 (http1-exchange stream (request-method req) uri (request-headers req)
                                 (request-content req) :closer #'close-connection)
               (if (request-max-body-bytes req)
                   (progn (setf body-owns-connection t)
                          (values body status headers))
                   (let ((octets (let ((out (make-array 0 :element-type '(unsigned-byte 8)
                                                          :adjustable t :fill-pointer 0)))
                                   (loop for b = (read-byte body nil nil)
                                         while b do (vector-push-extend b out))
                                   (coerce out '(simple-array (unsigned-byte 8) (*))))))
                     (values octets status headers)))))
        (unless body-owns-connection (close-connection))))))

#+os-windows
(defvar *server-certificate-verifier* 'aion/windows:verify-server-certificate-chain
  "The function that decides about a pinned connection's server certificate on Windows: called
with the chain, DER and leaf first, and the URL's host, it returns (values VERDICT CODE) as
AION/WINDOWS:VERIFY-SERVER-CERTIFICATE-CHAIN does. A test binds it; nothing else should.")

#+os-windows
(defvar *%verifying-config* nil
  "The aion/tls client config whose verifier is the one above, made once on first use.")
#+os-windows
(defvar *%verifying-config-lock* (sb-thread:make-mutex :name "aion/http-client tls config"))

#+os-windows
(defun %verifying-config ()
  (sb-thread:with-mutex (*%verifying-config-lock*)
    (or *%verifying-config*
        (setf *%verifying-config*
              (aion/tls:make-verifying-client-config
               (lambda (chain host)
                 (multiple-value-bind (verdict code) (funcall *server-certificate-verifier* chain host)
                   (if (eq verdict :trusted)
                       t
                       (error (certificate-condition-class verdict)
                              :host host :verdict verdict :code code)))))))))

#+os-windows
(defun %ca-path-config (path)
  "A client config that trusts the CA certificates in the PEM file PATH, as cl+ssl's
:VERIFY-LOCATION does on the other platforms, and the certificate chain it holds: (values CONFIG
CHAIN), both for the caller to free. A directory is refused: aion/tls reads one file."
  (when (uiop:directory-exists-p path)
    (error 'http-error :detail (format nil "ca-path ~A is a directory; on Windows give one PEM file" path)))
  (let ((octets (with-open-file (in path :element-type '(unsigned-byte 8))
                  (let* ((buffer (make-array (file-length in) :element-type '(unsigned-byte 8)))
                         (n (read-sequence buffer in)))
                    (subseq buffer 0 n)))))
    (let ((chain (aion/tls:make-certificate-chain octets)))
      (handler-bind ((error (lambda (e) (declare (ignore e))
                              (aion/tls:free-certificate-chain chain))))
        (values (aion/tls:make-client-config chain) chain)))))

;;; --- the read timeout on Windows (#985) ------------------------------------------------
;;;
;;; On Windows neither the socket's receive timeout (SO_RCVTIMEO, which USOCKET:SOCKET-OPTION
;;; :RECEIVE-TIMEOUT sets) nor SBCL's fd-stream timeout ends a read from a socket that receives
;;; nothing: measured, a read with a timeout of one second was still waiting after twenty. So a
;;; pinned request's read timeout is kept here instead: when a read has waited longer than the
;;; timeout, a timer closes the socket, which wakes the read, and the read signals
;;; SB-SYS:IO-TIMEOUT. It closes rather than shuts down: on Windows a shutdown from another thread
;;; did not wake a blocked read within ten seconds, and a close woke it at once (measured, #985).
;;; A read that does not have to wait (LISTEN is true) costs no timer.

#+os-windows
(defclass %idle-watched-stream (sb-gray:fundamental-binary-input-stream
                                sb-gray:fundamental-binary-output-stream)
  ((inner :initarg :inner :reader %inner)
   (socket :initarg :socket :reader %watched-socket)
   (seconds :initarg :seconds :reader %watch-seconds)
   (timed-out :initform nil :accessor %timed-out)))

#+os-windows
(defun %watch-fire (s state)
  "What %CALL-WATCHED's timer does when it fires: when STATE, a cons whose car is the read's
state, is still :READING, claim it as :FIRED, mark S timed out and close its socket. When the
read has already claimed it as :DONE, do nothing, so a timer that fires between the read's
return and its unscheduling cannot end a read that finished (#1063)."
  (when (eq :reading (sb-ext:compare-and-swap (car state) :reading :fired))
    (setf (%timed-out s) t)
    (ignore-errors (usocket:socket-close (%watched-socket s)))))

#+os-windows
(defun %call-watched (s thunk)
  "Call THUNK, a read from S's inner stream. When the read would wait, a timer closes S's socket
after S's seconds; a read woken that way signals SB-SYS:IO-TIMEOUT.

A read that returns is never reported as a timeout (#1063). The read and the timer each try to
move one state from :READING, with COMPARE-AND-SWAP, and only the one that moves it acts: a
read that finishes first leaves the timer nothing to do, even if it fires before it is
unscheduled; a timer that fires first closes the socket. When the read still returns after
that, its result is returned, and the closed socket makes the next read signal the timeout."
  (if (listen (%inner s))
      (funcall thunk)
      (let* ((state (list :reading))
             ;; THREAD-LIFETIME: a timer made with :THREAD T starts its thread only when it
             ;; fires. That thread claims the state, closes the socket and ends. A read that
             ;; finishes first unschedules the timer below, and then no thread is made.
             ;; INTERRUPTS: not needed -- SBCL makes the thread, which runs one socket close and
             ;; ends.
             (timer (sb-ext:make-timer (lambda () (%watch-fire s state))
                                       :thread t :name "aion/http-client read timeout")))
        (sb-ext:schedule-timer timer (%watch-seconds s))
        (multiple-value-bind (result returned)
            (unwind-protect (%unless-timed-out s thunk)
              (sb-ext:compare-and-swap (car state) :reading :done)
              (sb-ext:unschedule-timer timer))
          (unless returned
            (error 'sb-sys:io-timeout :stream s :direction :input :seconds (%watch-seconds s)))
          result))))

#+os-windows
(defun %unless-timed-out (s thunk)
  "Call THUNK and return (VALUES its-value T). When it fails because the timer closed the socket,
on this read or an earlier one, return (VALUES NIL NIL), so the caller signals the timeout
instead of whatever the closed socket reported."
  (handler-case (values (funcall thunk) t)
    (error (e) (if (%timed-out s) (values nil nil) (error e)))))

#+os-windows
(defmethod sb-gray:stream-read-byte ((s %idle-watched-stream))
  (or (%call-watched s (lambda () (read-byte (%inner s) nil nil))) :eof))

#+os-windows
(defmethod sb-gray:stream-read-sequence ((s %idle-watched-stream) seq &optional (start 0) end)
  (%call-watched s (lambda () (read-sequence seq (%inner s) :start start :end end))))

#+os-windows
(defmethod sb-gray:stream-listen ((s %idle-watched-stream))
  (listen (%inner s)))

#+os-windows
(defmethod sb-gray:stream-write-byte ((s %idle-watched-stream) byte)
  (write-byte byte (%inner s)))

#+os-windows
(defmethod sb-gray:stream-write-sequence ((s %idle-watched-stream) seq &optional (start 0) end)
  (write-sequence seq (%inner s) :start start :end end)
  seq)

#+os-windows
(defmethod sb-gray:stream-force-output ((s %idle-watched-stream))
  (force-output (%inner s)))

#+os-windows
(defmethod sb-gray:stream-finish-output ((s %idle-watched-stream))
  (finish-output (%inner s)))

#+os-windows
(defmethod stream-element-type ((s %idle-watched-stream))
  '(unsigned-byte 8))

#+os-windows
(defmethod close ((s %idle-watched-stream) &key abort)
  (close (%inner s) :abort abort)
  (call-next-method))

#+os-windows
(defun %watch-reads (socket seconds)
  "SOCKET's stream, with reads ended after SECONDS of waiting, or the stream itself when SECONDS
is NIL."
  (let ((stream (usocket:socket-stream socket)))
    (if seconds
        (make-instance '%idle-watched-stream :inner stream :socket socket :seconds seconds)
        stream)))

#+os-windows
(defun %request-pinned (req)
  "Run REQ over a connection to its CONNECT-ADDRESS, returning (values BODY STATUS HEADERS) as
DEX:REQUEST does (#536).

The socket is opened here, to that address and nowhere else. For https, aion/tls does the
handshake with the URL's host name, so the server is asked for that name (SNI), and Windows
decides whether to trust the certificate, for that name, through *SERVER-CERTIFICATE-VERIFIER*:
a refusal is a CERTIFICATE-REJECTED of the matching subclass. With the request's CA-PATH, the CA
certificates in that file decide instead. The request is written and the response read by
http1.lisp, whose limits apply, and the Host header is the URL's.

The socket is lent to FETCH-PUBLIC's deadline watch. The read timeout is kept by
%IDLE-WATCHED-STREAM, because Windows ignores the socket's receive timeout. A body read as a
stream (MAX-BODY-BYTES) keeps the connection, and closing the body closes it; otherwise the body
is read here and the connection closed."
  (let* ((uri (quri:uri (request-url req)))
         (host (quri:uri-host uri))
         (address (or (parse-address (request-connect-address req))
                      (error 'http-error
                             :detail (format nil "connect-address ~S is not an IP address"
                                             (request-connect-address req)))))
         (socket (prog1 (usocket:socket-connect address (%port-of uri)
                                                :element-type '(unsigned-byte 8)
                                                :timeout (request-connect-timeout req))
                   ;; From here on a failure happened after the connection was made (#79).
                   (setf *%connected* t)))
         (stream nil)
         (own-config nil)
         (own-chain nil)
         (body-owns-connection nil))
    (%lend-socket socket)
    (flet ((close-connection ()
             (%take-back-socket)
             (when stream (ignore-errors (close stream)))
             (ignore-errors (usocket:socket-close socket))
             ;; A CA-PATH config is this connection's own; the verifying one is shared.
             (when own-config (ignore-errors (aion/tls:free-config own-config)))
             (when own-chain (ignore-errors (aion/tls:free-certificate-chain own-chain)))))
      (unwind-protect
           (progn
             (setf stream (%watch-reads socket (request-read-timeout req)))
             (when (string-equal (quri:uri-scheme uri) "https")
               (when (request-ca-path req)
                 (multiple-value-setq (own-config own-chain) (%ca-path-config (request-ca-path req))))
               ;; The name the certificate is judged for, and the one aion/tls decides SNI from:
               ;; %TLS-NAMES's second value, as on Linux and macOS. For an IP address that is the
               ;; address without the brackets QURI keeps, in one canonical form, so
               ;; [0:0:0:0:0:0:0:1] is judged as ::1 on every platform (#921).
               (setf stream (aion/tls:make-tls-stream stream (or own-config (%verifying-config))
                                                      :hostname (nth-value 1 (%tls-names host)))))
             (multiple-value-bind (body status headers)
                 (http1-exchange stream (request-method req) uri (request-headers req)
                                 (request-content req) :closer #'close-connection)
               (if (request-max-body-bytes req)
                   (progn (setf body-owns-connection t)
                          (values body status headers))
                   (let ((octets (let ((out (make-array 0 :element-type '(unsigned-byte 8)
                                                          :adjustable t :fill-pointer 0)))
                                   (loop for b = (read-byte body nil nil)
                                         while b do (vector-push-extend b out))
                                   (coerce out '(simple-array (unsigned-byte 8) (*))))))
                     (values octets status headers)))))
        (unless body-owns-connection (close-connection))))))

;;; --- fetch-public ------------------------------------------------------------------

(defparameter *fetch-public-max-body-bytes* (* 10 1024 1024)
  "FETCH-PUBLIC's default body limit: 10 MiB.")

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

(defun %fire (watch)
  "The deadline has passed: record it, and wake a read or write blocked on the socket the fetch
is using. Elsewhere the socket is shut down. On Windows it is closed, because a shutdown from
another thread did not wake a blocked read there: measured, a FETCH-PUBLIC with :DEADLINE 2 to a
server that never answered was still waiting after 20 seconds (#985)."
  (sb-thread:with-mutex ((%watch-lock watch))
    (setf (%watch-fired watch) t)
    (let ((socket (%watch-socket watch)))
      (when socket
        #+os-windows (ignore-errors (usocket:socket-close socket))
        #-os-windows (ignore-errors (usocket:socket-shutdown socket :io))))))

(defun %fired-p (watch)
  (and watch (sb-thread:with-mutex ((%watch-lock watch)) (%watch-fired watch))))

(defun fetch-public (url &key (method :get) headers content
                           (max-redirects 5)
                           (max-body-bytes *fetch-public-max-body-bytes*)
                           connect-timeout read-timeout deadline ca-path
                           (resolve #'resolve-host)
                           (address-policy #'address-category)
                           (perform #'%http))
  "Fetch URL, which a user supplied, and return the RESPONSE of the last hop, and as a second
value the URL of that hop, which differs from URL after a redirect (#757). Any status is
returned as a response; apply ENSURE-2XX or similar to it as usual.

Before each connection, including each redirect, the host is resolved (RESOLVE), and if any of
its addresses is not :PUBLIC under ADDRESS-POLICY (ADDRESS-CATEGORY by default), the fetch
signals FETCH-REFUSED without connecting. Otherwise the connection is pinned to the checked
address (CONNECT-ADDRESS), so the host cannot resolve somewhere else in between.

Redirects are followed here, never by dexador: at most MAX-REDIRECTS, then
TOO-MANY-REDIRECTS. A redirect to another origin drops the Authorization and Cookie headers,
and a 301, 302 or 303 turns any method but GET or HEAD into a GET without a body. The body of
each response is limited to MAX-BODY-BYTES (RESPONSE-TOO-LARGE past it).

CONNECT-TIMEOUT and READ-TIMEOUT are seconds for each connect and each socket read. DEADLINE,
in seconds, limits the whole fetch over every hop (#807): when it passes, the socket in use is
shut down and the fetch signals FETCH-DEADLINE-EXCEEDED, so a server that sends a byte now and
then cannot hold the caller past it. It covers the TLS handshake, the request, the headers and
the body. It does not interrupt resolving a host name (RESOLVE) or opening the TCP connection:
those are checked against the deadline when they return, so they can overrun it by up to the
resolver's own time and CONNECT-TIMEOUT. With CONNECT-TIMEOUT NIL the operating system's own
connect limit applies, about 127 seconds on Linux. NIL, the default, sets no deadline.

On Windows the pinned connection goes over aion/tls, and Windows decides whether to trust the
server's certificate; a refusal is a subclass of CERTIFICATE-REJECTED (#536).

RESOLVE, ADDRESS-POLICY and PERFORM are for tests. ADDRESS-POLICY decides which addresses count
as public, so a policy other than the default turns off the check that keeps this from reaching
internal addresses. Never pass one derived from a setting or from user input."
  (let* ((current url)
         (watch (and deadline (%make-watch)))
         ;; THREAD-LIFETIME: a timer made with :THREAD T starts its thread only when it fires.
         ;; That thread runs %FIRE once, a socket shutdown under the watch's lock, and ends. A
         ;; fetch that finishes first unschedules the timer below, and then no thread is made.
         ;; INTERRUPTS: not needed -- SBCL makes the thread, which runs one shutdown and ends.
         (timer (and watch (sb-ext:make-timer (lambda () (%fire watch))
                                              :thread t :name "fetch-public deadline")))
         (*%watch* watch))
    (flet ((check (&optional (hop current))
             (setf current hop)
             (when (%fired-p watch)
               (error 'fetch-deadline-exceeded :url hop :deadline deadline))))
      (when timer (sb-ext:schedule-timer timer deadline))
      (unwind-protect
           ;; After the deadline, any failure is the deadline's doing (a read on a shut-down
           ;; socket fails, or ends early), so it is reported as the deadline.
           (handler-bind ((error (lambda (e)
                                   (unless (typep e 'fetch-deadline-exceeded) (check)))))
             (%fetch-hops url method headers content max-redirects max-body-bytes
                          connect-timeout read-timeout ca-path resolve address-policy perform
                          #'check))
        ;; The socket is taken from the watch before the timer is unscheduled, so a timer that
        ;; fires in between finds nothing to shut down.
        (when watch (%take-back-socket))
        (when timer (sb-ext:unschedule-timer timer))))))

(defun %encoded-url (url)
  "URL with its path and query percent-encoded by %ENCODE-TARGET, so a space, a control
character or a character beyond ASCII in a URL a user or a redirect supplied cannot reach a
request line as it is, on any platform. QURI keeps them as they are when it parses a URL or
merges a redirect's Location (the hub's review of #913)."
  (let ((uri (quri:uri url)))
    (setf (quri:uri-path uri) (and (quri:uri-path uri) (%encode-target (quri:uri-path uri)))
          (quri:uri-query uri) (and (quri:uri-query uri) (%encode-target (quri:uri-query uri))))
    (quri:render-uri uri)))

(defun %fetch-hops (url method headers content max-redirects max-body-bytes
                    connect-timeout read-timeout ca-path resolve address-policy perform check)
  "FETCH-PUBLIC's redirect loop. CHECK is called with the hop's URL after each step, and
signals when the deadline has passed."
  (let ((hops 0))
    (loop
      (setf url (%encoded-url url))
      (let* ((uri (quri:uri url))
             (address (prog1 (%checked-address url uri resolve address-policy)
                        (funcall check url)))
             (response (funcall perform
                                (make-request :method method :url url :headers headers
                                              :content content
                                              :connect-timeout connect-timeout
                                              :read-timeout read-timeout
                                              :follow-redirects nil
                                              :max-body-bytes max-body-bytes
                                              :connect-address address
                                              :ca-path ca-path)))
             (status (progn (funcall check url) (response-status response)))
             (location (and (member status '(301 302 303 307 308))
                            (header-value (response-headers response) "location"))))
        (unless location (return (values response url)))
        (when (>= hops max-redirects)
          (error 'too-many-redirects :url url :limit max-redirects))
        (let ((next (quri:merge-uris (quri:uri location) uri)))
          (unless (equal (%origin next) (%origin uri))
            (setf headers (%without-credentials headers)))
          (when (and (member status '(301 302 303)) (not (member method '(:get :head))))
            (setf method :get content nil))
          (setf url (quri:render-uri next))
          (incf hops))))))
