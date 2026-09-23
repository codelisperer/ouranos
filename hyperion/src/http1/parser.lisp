;;;; parser.lisp --- an HTTP/1.1 request head, parsed into a typed value (#117, commit 1).
;;;;
;;;; The boundary-decoder pattern at its most consequential: untyped bytes off a socket
;;;; become a checked Request, or a status code saying why they will not. Everything here is
;;;; total and pure -- no IO, no sockets, no conditions. The CL shell owns those.
;;;;
;;;; WHY COALTON, SPECIFICALLY. Hand-rolled HTTP parsers are where CVEs live. Nearly all of
;;;; them are a case someone did not consider: a header seen twice, a length that is not a
;;;; number, a line ending that is not the one expected. An ADT plus exhaustive MATCH turns
;;;; "did we consider it" from a review question into a compile-time one. ADR-0002 recorded
;;;; that obligation; this file is where it is discharged.
;;;;
;;;; STRINGS, NOT OCTETS, AND THAT IS THE SPEC'S DOING. RFC 9112 says the request line and
;;;; header fields are ISO-8859-1. That encoding is total and byte-for-byte round-trippable,
;;;; so one octet is one character and CONSUMED is a byte count as well as a character count
;;;; -- which is what lets the CL shell slice the body off the same buffer without re-scanning
;;;; it. The BODY is never decoded here; it stays octets in the shell, where it belongs.
;;;;
;;;; INCREMENTAL, BECAUSE A CHUNK BOUNDARY IS NOT A MESSAGE BOUNDARY. PARSE-HEAD is fed
;;;; whatever has arrived and answers Incomplete / Complete / Rejected. Incomplete is not an
;;;; error; it means read more. The one thing it must never do is block or guess.
;;;;
;;;; THE SECURITY FLOOR, and why each rule exists rather than merely what it is:
;;;;
;;;;   Content-Length AND Transfer-Encoding      -> 400. THE request-smuggling primitive: two
;;;;                                                framings disagreeing lets a proxy and an
;;;;                                                origin split one byte stream differently.
;;;;   duplicate Content-Length, differing       -> 400. Same disagreement, one header.
;;;;   non-digit / negative Content-Length       -> 400. "+5", " 5", "0x5" are read
;;;;                                                differently by different parsers.
;;;;   any Transfer-Encoding                     -> 501. Refused LOUDLY, never ignored:
;;;;                                                silently dropping it is how a body gets
;;;;                                                interpreted as a second request.
;;;;   bare LF as a line terminator              -> 400. Accepting bare LF where a peer
;;;;                                                requires CRLF is a smuggling desync.
;;;;   obs-fold (a header line starting SP/HTAB) -> 400. Obsolete since RFC 7230 and a
;;;;                                                reliable way to hide a header from one
;;;;                                                parser in a chain but not another.
;;;;   non-token character in a field name       -> 400. Covers NUL, CR, space and control
;;;;                                                characters in one rule.
;;;;   head > 64 KiB, or > 100 fields            -> 431. Bounded before it is parsed, so a
;;;;                                                slowloris cannot buy unbounded memory by
;;;;                                                never sending the terminator.
;;;;   version not HTTP/1.0 or HTTP/1.1          -> 505.
;;;;
;;;; A body-size cap (413) is deliberately NOT here: it is configurable and therefore the
;;;; server's decision. This layer reports the declared length; the shell compares it.

(cl:in-package #:hyperion/http1)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- limits ---------------------------------------------------------------

  ;; The largest request head accepted, terminator included. Exceeding it is 431 rather than
  ;; Incomplete -- that distinction IS the defence, since a peer that never sends the
  ;; terminator would otherwise buy unbounded memory one byte at a time.
  ;; (A comment, not a docstring: a Coalton value DEFINE takes no docstring -- the string
  ;; would be read as the value and fail to typecheck against UFix.)
  (declare max-head-octets UFix)
  (define max-head-octets 65536)

  ;; The most header fields accepted. A second bound because many small fields stay under
  ;; the octet cap while still costing a parse each.
  (declare max-header-fields UFix)
  (define max-header-fields 100)

  ;;; --- the vocabulary -------------------------------------------------------

  (define-type Version
    "The HTTP version on the request line. Only these two exist here: anything else is 505,
so an unsupported version can never reach the rest of the server as a default."
    Http-1-0
    Http-1-1)

  (declare version-name (Version -> String))
  (define (version-name v)
    (match v
      ((Http-1-0) "HTTP/1.0")
      ((Http-1-1) "HTTP/1.1")))

  (define-type Body-Spec
    "How this request's body is framed, once framing has been AGREED.

There is no Chunked variant on purpose. Transfer-Encoding is rejected at parse time with
501, so `chunked' never becomes a state the server has to carry -- a variant here would
spread one decision across two layers and invite a later branch that forgets it."
    Body-None
    (Body-Exact UFix))

  (define-type Request
    "A checked request head: method, target, version, header fields (names lowercased, values
verbatim), how the body is framed, and whether the connection is persistent."
    (Request String String Version (List (Tuple String String)) Body-Spec Boolean))

  (define-type Head-Result
    "What PARSE-HEAD concluded from the bytes it was given.

  Incomplete       no CRLFCRLF yet, and the input is still within limits. Read more.
  Complete r n     R is the head; N is how many octets of the input it consumed, so the
                   shell can slice the body from N onward without rescanning.
  Rejected s why   S is the HTTP status to send. Not a boolean, because every rejection is
                   still a response somebody has to write."
    Incomplete
    (Complete Request UFix)
    (Rejected UFix String))

  ;;; --- CRLF, built rather than written --------------------------------------
  ;;;
  ;;; NOT the literal "\r\n". Common Lisp string escapes are not C's: in CL a backslash
  ;;; escapes the NEXT CHARACTER and nothing more, so "\r\n" reads as the two characters
  ;;; `r' and `n'. A parser searching for that finds it in the word "learn" and never finds
  ;;; a line terminator. The type checker cannot help here -- both are String -- which is
  ;;; exactly why it is built from character literals, which CL does read correctly.

  (declare cr Char)
  (define cr #\Return)

  (declare lf Char)
  (define lf #\Newline)

  (declare crlf String)
  (define crlf (<> (the String (into cr)) (the String (into lf))))

  (declare crlfcrlf String)
  (define crlfcrlf (<> crlf crlf))

  ;;; --- small string helpers -------------------------------------------------
  ;;; Written out rather than pulled from a utility library: this system depends on nothing
  ;;; but Coalton on purpose (ADR-0015), and each is four lines.

  (declare char-at? (String * UFix * Char -> Boolean))
  (define (char-at? s i c)
    (match (str:ref s i)
      ((Some x) (== x c))
      ((None) False)))

  (declare index-of-char (String * Char * UFix -> (Optional UFix)))
  (define (index-of-char s c i)
    (if (>= i (str:length s))
        None
        (if (char-at? s i c)
            (Some i)
            (index-of-char s c (+ i 1)))))

  (declare contains-char? (String * Char -> Boolean))
  (define (contains-char? s c)
    (match (index-of-char s c 0)
      ((Some _) True)
      ((None) False)))

  (declare ows? (Char -> Boolean))
  (define (ows? c)
    "Optional whitespace, as RFC 9110 defines it: space or horizontal tab, and nothing else.
Notably NOT CR, LF or vertical tab -- treating those as trimmable is how a smuggled header
value gets normalised into something the next hop reads differently."
    (or (== c #\Space) (== c #\Tab)))

  (declare trim-start (String * UFix -> String))
  (define (trim-start s i)
    (if (>= i (str:length s))
        ""
        (if (match (str:ref s i) ((Some c) (ows? c)) ((None) False))
            (trim-start s (+ i 1))
            (str:substring s i (str:length s)))))

  (declare trim-end (String -> String))
  (define (trim-end s)
    (let ((n (str:length s)))
      (if (== n 0)
          ""
          (if (match (str:ref s (- n 1)) ((Some c) (ows? c)) ((None) False))
              (trim-end (str:substring s 0 (- n 1)))
              s))))

  (declare trim-ows (String -> String))
  (define (trim-ows s) (trim-end (trim-start s 0)))

  (declare split-crlf (String -> (List String)))
  (define (split-crlf s)
    "S split on CRLF. Only CRLF -- a bare LF is left inside a line, where LINE-CLEAN? finds
it and rejects. Splitting on LF and tolerating a stray CR would silently accept exactly the
line terminator this parser must refuse."
    (match (str:substring-index crlf s)
      ((None) (Cons s Nil))
      ((Some i)
       (Cons (str:substring s 0 i)
             (split-crlf (str:substring s (+ i 2) (str:length s)))))))

  (declare line-clean? (String -> Boolean))
  (define (line-clean? s)
    "No stray CR or LF survived the CRLF split, so the terminator really was CRLF."
    (and (not (contains-char? s cr))
         (not (contains-char? s lf))))

  (declare token-char? (Char -> Boolean))
  (define (token-char? c)
    "RFC 9110 tchar. Written as an allow-list, not a deny-list of control characters: a
deny-list is what lets NUL, DEL or a stray CR through when somebody forgets one."
    (or (char:ascii-alphanumeric? c)
        (or (== c #\!) (or (== c #\#) (or (== c #\$) (or (== c #\%)
        (or (== c #\&) (or (== c #\') (or (== c #\*) (or (== c #\+)
        (or (== c #\-) (or (== c #\.) (or (== c #\^) (or (== c #\_)
        (or (== c #\`) (or (== c #\|) (== c #\~)))))))))))))))))

  (declare token-from? (String * UFix -> Boolean))
  (define (token-from? s i)
    (if (>= i (str:length s))
        True
        (and (match (str:ref s i) ((Some c) (token-char? c)) ((None) False))
             (token-from? s (+ i 1)))))

  (declare token? (String -> Boolean))
  (define (token? s)
    (and (> (str:length s) 0) (token-from? s 0)))

  (declare all-digits-from? (String * UFix -> Boolean))
  (define (all-digits-from? s i)
    (if (>= i (str:length s))
        True
        (and (match (str:ref s i) ((Some c) (char:ascii-digit? c)) ((None) False))
             (all-digits-from? s (+ i 1)))))

  (declare all-digits? (String -> Boolean))
  (define (all-digits? s)
    "Every character is an ASCII digit, and there is at least one.

Stricter than PARSE-INT on purpose: parse-int would accept \"+5\", \"-5\" and leading
whitespace, and a Content-Length that different parsers read differently is the smuggling
bug this rule exists to stop."
    (and (> (str:length s) 0) (all-digits-from? s 0)))

  ;;; --- header lookup --------------------------------------------------------

  (declare header-values (String * (List (Tuple String String)) -> (List String)))
  (define (header-values name headers)
    "Every value for NAME, which must already be lowercase. A LIST because seeing a field
twice is the interesting case, not an error to be flattened away."
    (map (fn (h) (match h ((Tuple _ v) v)))
         (list:filter (fn (h) (match h ((Tuple k _) (== k name)))) headers)))

  (declare all-same? ((List String) -> Boolean))
  (define (all-same? xs)
    (match xs
      ((Nil) True)
      ((Cons x rest)
       (match rest
         ((Nil) True)
         ((Cons y _) (and (== x y) (all-same? rest)))))))

  (declare comma-tokens (String -> (List String)))
  (define (comma-tokens s)
    "A comma-separated field value split into lowercased, trimmed tokens -- `Connection' is
a list, and `close' inside `keep-alive, close' has to be found without a substring search
that would also match the word inside some other token."
    (map (fn (p) (trim-ows (str:downcase p))) (str:split #\, s)))

  (declare has-connection-token? (String * (List (Tuple String String)) -> Boolean))
  (define (has-connection-token? tok headers)
    (list:any (fn (v) (list:member tok (comma-tokens v)))
               (header-values "connection" headers)))

  ;;; --- the request line -----------------------------------------------------

  (declare parse-version (String -> (Optional Version)))
  (define (parse-version s)
    (cond
      ((== s "HTTP/1.1") (Some Http-1-1))
      ((== s "HTTP/1.0") (Some Http-1-0))
      (True None)))

  (declare target-ok? (String -> Boolean))
  (define (target-ok? s)
    "A request target is non-empty and contains no whitespace or control characters. Not a
full URI parse -- that is the router's job -- just the check that stops a target from
carrying a second request line inside it."
    (and (> (str:length s) 0) (target-clean-from? s 0)))

  (declare target-clean-from? (String * UFix -> Boolean))
  (define (target-clean-from? s i)
    (if (>= i (str:length s))
        True
        (and (match (str:ref s i)
               ((Some c) (and (> (char:char-code c) 32) (not (== (char:char-code c) 127))))
               ((None) False))
             (target-clean-from? s (+ i 1)))))

  ;;; --- the parse ------------------------------------------------------------

  (declare parse-head (String -> Head-Result))
  (define (parse-head input)
    "Parse as much of INPUT as is a complete HTTP/1.1 request head.

Total: every input is Incomplete, Complete or Rejected. It never signals, never blocks and
never consumes more than it reports."
    (match (str:substring-index crlfcrlf input)
      ;; No terminator yet. Incomplete ONLY while still inside the cap -- past it, a peer
      ;; that never terminates the head must be refused rather than buffered forever.
      ((None)
       (if (> (str:length input) max-head-octets)
           (Rejected 431 "request head exceeds the maximum size")
           Incomplete))
      ((Some end)
       (if (> (+ end 4) max-head-octets)
           (Rejected 431 "request head exceeds the maximum size")
           (parse-lines (split-crlf (str:substring input 0 end)) (+ end 4))))))

  (declare parse-lines ((List String) * UFix -> Head-Result))
  (define (parse-lines lines consumed)
    (match lines
      ((Nil) (Rejected 400 "empty request head"))
      ((Cons request-line field-lines)
       (if (not (line-clean? request-line))
           (Rejected 400 "bare CR or LF in the request line")
           (if (> (list:length field-lines) max-header-fields)
               (Rejected 431 "too many header fields")
               (match (parse-request-line request-line)
                 ((Rejected s why) (Rejected s why))
                 ((Incomplete) (Rejected 400 "malformed request line"))
                 ((Complete r _) (finish r field-lines consumed))))))))

  (declare parse-request-line (String -> Head-Result))
  (define (parse-request-line s)
    "METHOD SP TARGET SP VERSION, with exactly two spaces. Returns a Request carrying only
the three fields it can know; FINISH fills in the rest."
    (match (str:split #\Space s)
      ((Cons method (Cons target (Cons version (Nil))))
       (if (not (token? method))
           (Rejected 400 "method is not a token")
           (if (not (target-ok? target))
               (Rejected 400 "request target is empty or contains control characters")
               (match (parse-version version)
                 ((None) (Rejected 505 "only HTTP/1.0 and HTTP/1.1 are supported"))
                 ((Some v) (Complete (Request method target v Nil Body-None False) 0))))))
      (_ (Rejected 400 "request line is not METHOD SP TARGET SP VERSION"))))

  (declare parse-fields ((List String) * (List (Tuple String String))
                         -> (Result (Tuple UFix String) (List (Tuple String String)))))
  (define (parse-fields lines acc)
    "Fold the header lines into (lowercased-name . value) pairs, newest last. Err carries
the status and reason, so the first bad field decides the response."
    (match lines
      ((Nil) (Ok (list:reverse acc)))
      ((Cons l rest)
       (if (not (line-clean? l))
           (Err (Tuple 400 "bare CR or LF in a header field"))
           (if (match (str:ref l 0) ((Some c) (ows? c)) ((None) False))
               (Err (Tuple 400 "obsolete line folding is not accepted"))
               (match (index-of-char l #\: 0)
                 ((None) (Err (Tuple 400 "header field has no colon")))
                 ((Some i)
                  (let ((name (str:downcase (str:substring l 0 i)))
                        (value (trim-ows (str:substring l (+ i 1) (str:length l)))))
                    (if (not (token? name))
                        (Err (Tuple 400 "header field name is not a token"))
                        (parse-fields rest (Cons (Tuple name value) acc)))))))))))

  (declare body-spec ((List (Tuple String String)) -> (Result (Tuple UFix String) Body-Spec)))
  (define (body-spec headers)
    "Decide the body framing, or say why it cannot be decided. Order matters: the
both-present case is checked first, because it is the one that is dangerous rather than
merely unsupported."
    (let ((cls (header-values "content-length" headers))
          (tes (header-values "transfer-encoding" headers)))
      (if (and (list:cons? cls) (list:cons? tes))
          (Err (Tuple 400 "Content-Length and Transfer-Encoding are both present"))
          (if (list:cons? tes)
              (Err (Tuple 501 "Transfer-Encoding is not supported"))
              (match cls
                ((Nil) (Ok Body-None))
                ((Cons first _)
                 (if (not (all-same? cls))
                     (Err (Tuple 400 "Content-Length appears more than once with different values"))
                     (if (not (all-digits? first))
                         (Err (Tuple 400 "Content-Length is not a non-negative integer"))
                         (match (str:parse-int first)
                           ((None) (Err (Tuple 400 "Content-Length is not a non-negative integer")))
                           ((Some n) (Ok (Body-Exact (fromint n)))))))))))))

  (declare finish (Request * (List String) * UFix -> Head-Result))
  (define (finish r field-lines consumed)
    (match r
      ((Request method target version _ _ _)
       (match (parse-fields field-lines Nil)
         ((Err e) (match e ((Tuple s why) (Rejected s why))))
         ((Ok headers)
          (match (body-spec headers)
            ((Err e) (match e ((Tuple s why) (Rejected s why))))
            ((Ok body)
             (Complete (Request method target version headers body
                                (persistent? version headers))
                       consumed))))))))

  (declare persistent? (Version * (List (Tuple String String)) -> Boolean))
  (define (persistent? v headers)
    "HTTP/1.1 is persistent unless it says `close'; HTTP/1.0 is not unless it says
`keep-alive'. Both directions are explicit -- defaulting one of them would silently leak
connections or silently break pipelining."
    (match v
      ((Http-1-1) (not (has-connection-token? "close" headers)))
      ((Http-1-0) (has-connection-token? "keep-alive" headers))))

  ;;; --- the CL-facing surface ------------------------------------------------
  ;;;
  ;;; Total accessors over promised representations, so the shell never destructures an ADT.
  ;;; A wrong-variant read returns a harmless default; the shell branches on
  ;;; HEAD-COMPLETE? / HEAD-REJECTED? first, so those defaults are never actually consumed.
  ;;; Same doctrine as mnemosyne/backend's CL boundary.

  (declare head-incomplete? (Head-Result -> Boolean))
  (define (head-incomplete? h)
    (match h ((Incomplete) True) (_ False)))

  (declare head-complete? (Head-Result -> Boolean))
  (define (head-complete? h)
    (match h ((Complete _ _) True) (_ False)))

  (declare head-rejected? (Head-Result -> Boolean))
  (define (head-rejected? h)
    (match h ((Rejected _ _) True) (_ False)))

  (declare head-status (Head-Result -> UFix))
  (define (head-status h)
    "The status to send, or 0 when there is nothing to reject."
    (match h ((Rejected s _) s) (_ 0)))

  (declare head-reason (Head-Result -> String))
  (define (head-reason h)
    (match h ((Rejected _ why) why) (_ "")))

  (declare head-consumed (Head-Result -> UFix))
  (define (head-consumed h)
    "Octets of input the head occupied, terminator included; the body starts here."
    (match h ((Complete _ n) n) (_ 0)))

  (declare head-request (Head-Result -> Request))
  (define (head-request h)
    (match h
      ((Complete r _) r)
      (_ (Request "" "" Http-1-1 Nil Body-None False))))

  (declare head-method (Head-Result -> String))
  (define (head-method h)
    (match (head-request h) ((Request m _ _ _ _ _) m)))

  (declare head-target (Head-Result -> String))
  (define (head-target h)
    (match (head-request h) ((Request _ t _ _ _ _) t)))

  (declare head-version (Head-Result -> String))
  (define (head-version h)
    (match (head-request h) ((Request _ _ v _ _ _) (version-name v))))

  (declare head-keep-alive? (Head-Result -> Boolean))
  (define (head-keep-alive? h)
    (match (head-request h) ((Request _ _ _ _ _ k) k)))

  (declare head-has-body? (Head-Result -> Boolean))
  (define (head-has-body? h)
    (match (head-request h)
      ((Request _ _ _ _ b _) (match b ((Body-Exact _) True) ((Body-None) False)))))

  (declare head-body-length (Head-Result -> UFix))
  (define (head-body-length h)
    "The declared body length, 0 when there is none. The shell compares this against its own
configurable cap and answers 413 -- that limit is policy, so it is not decided here."
    (match (head-request h)
      ((Request _ _ _ _ b _) (match b ((Body-Exact n) n) ((Body-None) 0)))))

  (declare head-headers-flat (Head-Result -> (List String)))
  (define (head-headers-flat h)
    "Header fields as a FLAT name/value list -- (\"host\" \"x\" \"accept\" \"y\") -- so the CL
shell builds its hash table without touching a Tuple. Same convention as hyperion/path's
bindings."
    (match (head-request h)
      ((Request _ _ _ hs _ _)
       (list:concat (map (fn (p) (match p ((Tuple k v) (Cons k (Cons v Nil))))) hs))))))
