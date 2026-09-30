;;;; parser.lisp --- an HTTP/1.1 request head, parsed into a typed value (pre-publication issue 117, commit 1).
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
;;;;   Transfer-Encoding other than `chunked'    -> 501. Refused LOUDLY, never ignored:
;;;;                                                silently dropping it is how a body gets
;;;;                                                interpreted as a second request. Only the
;;;;                                                single coding `chunked' is decoded (#374).
;;;;   Transfer-Encoding in an HTTP/1.0 request  -> 400. RFC 9112 6.1: the framing is
;;;;                                                faulty, whatever else the message says.
;;;;   a chunk-size that is not hexadecimal,     -> 400. Each has been read differently by
;;;;   has more than 15 digits, or a chunk         two parsers in a chain; see CHUNKED
;;;;   not followed by CRLF                        BODIES below.
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
;;;;
;;;; CHUNKED BODIES (#374) are decoded a step at a time, because they arrive a piece at a time
;;;; and may be large. PARSE-CHUNK-SIZE-LINE reads one chunk-size line, PARSE-CHUNK-DATA-END
;;;; checks the CRLF after a chunk's data, and PARSE-TRAILERS reads the trailer section after
;;;; the last chunk. Each takes a short ISO-8859-1 view starting where the shell has got to, so
;;;; the shell never decodes the whole body to a string, and slices the data straight from its
;;;; octets. The size cap stays the shell's, as for Content-Length. Trailer fields are checked
;;;; like header fields and then discarded: nothing a peer sends after the body can change how
;;;; the request was framed or what its headers said.

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

BODY-CHUNKED is `Transfer-Encoding: chunked' and nothing else (#374). Any other coding is
refused with 501 before a Body-Spec exists, so no other coding is a state the server carries."
    Body-None
    (Body-Exact UFix)
    Body-Chunked)

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
    "Parse as much of INPUT as is a complete HTTP/1.1 request head, of at most
MAX-HEAD-OCTETS. PARSE-HEAD-LIMITED takes the limit as an argument."
    (parse-head-limited input max-head-octets))

  (declare parse-head-limited (String * UFix -> Head-Result))
  (define (parse-head-limited input limit)
    "Parse as much of INPUT as is a complete HTTP/1.1 request head of at most LIMIT octets,
terminator included (#375: the limit is the server's setting; MAX-HEAD-OCTETS is its default).

Total: every input is Incomplete, Complete or Rejected. It never signals, never blocks and
never consumes more than it reports."
    (match (str:substring-index crlfcrlf input)
      ;; No terminator yet. Incomplete ONLY while still inside the cap -- past it, a peer
      ;; that never terminates the head must be refused rather than buffered forever.
      ((None)
       (if (> (str:length input) limit)
           (Rejected 431 "request head exceeds the maximum size")
           Incomplete))
      ((Some end)
       (if (> (+ end 4) limit)
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

  (declare transfer-codings ((List String) -> (List String)))
  (define (transfer-codings values)
    "Every coding named across all Transfer-Encoding field lines, lowercased and trimmed, in
order. Two lines are one list (RFC 9110 5.3), so `chunked' split over two lines is still two."
    (list:concat (map comma-tokens values)))

  (declare body-spec (Version * (List (Tuple String String)) -> (Result (Tuple UFix String) Body-Spec)))
  (define (body-spec version headers)
    "Decide the body framing, or say why it cannot be decided. Order matters: the
both-present case is checked first, because it is the one that is dangerous rather than
merely unsupported.

Transfer-Encoding is accepted only as the single coding `chunked' (#374). `gzip, chunked',
`chunked, chunked' and `identity' are all 501: each is a framing another parser might read
differently, and none is needed. In HTTP/1.0 it is 400, whatever it says, because RFC 9112
6.1 says such a message's framing is faulty."
    (let ((cls (header-values "content-length" headers))
          (tes (header-values "transfer-encoding" headers)))
      (if (and (list:cons? cls) (list:cons? tes))
          (Err (Tuple 400 "Content-Length and Transfer-Encoding are both present"))
          (if (list:cons? tes)
              (match version
                ((Http-1-0) (Err (Tuple 400 "Transfer-Encoding in an HTTP/1.0 request")))
                ((Http-1-1)
                 (if (== (transfer-codings tes) (Cons "chunked" Nil))
                     (Ok Body-Chunked)
                     (Err (Tuple 501 "only the chunked transfer coding is supported")))))
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
          (match (body-spec version headers)
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

  ;;; --- chunked bodies (#374) ----------------------------------------------
  ;;;
  ;;; One step at a time, over a short view that starts where the shell has got to; see
  ;;; CHUNKED BODIES in the file header. Each step answers with a CHUNK-STEP.

  ;; The longest chunk-size line accepted, CRLF excluded: the size, and any extensions. Past
  ;; it the line is refused rather than buffered, for the reason MAX-HEAD-OCTETS gives.
  (declare max-chunk-line-octets UFix)
  (define max-chunk-line-octets 4096)

  ;; The most hex digits a chunk-size may have. Fifteen is 2^60 - 1, far past any body cap and
  ;; still a UFix; a sixteenth digit could not be represented, and a parser that wrapped it
  ;; would read a different size from one that did not.
  (declare max-chunk-size-digits UFix)
  (define max-chunk-size-digits 15)

  (define-type Chunk-Step
    "What one step of chunked decoding concluded from the view it was given.

  Step-Incomplete     not enough of the view yet, and still within its limit. Read more.
  Step-Ok value n     N octets of the view were this step's; VALUE is the chunk size for a
                      size line and 0 otherwise.
  Step-Rejected s why S is the HTTP status to send, as in HEAD-RESULT."
    Step-Incomplete
    (Step-Ok UFix UFix)
    (Step-Rejected UFix String))

  (declare hex-value (Char -> (Optional UFix)))
  (define (hex-value c)
    (let ((code (char:char-code c)))
      (cond
        ((and (>= code 48) (<= code 57)) (Some (- code 48)))
        ((and (>= code 97) (<= code 102)) (Some (- code 87)))
        ((and (>= code 65) (<= code 70)) (Some (- code 55)))
        (True None))))

  (declare hex-digits-from (String * UFix -> UFix))
  (define (hex-digits-from s i)
    "How many hex digits S has from I onward, stopping at the first that is not one."
    (match (str:ref s i)
      ((Some c) (match (hex-value c)
                  ((Some _) (+ 1 (hex-digits-from s (+ i 1))))
                  ((None) 0)))
      ((None) 0)))

  (declare hex-fold (String * UFix * UFix * UFix -> UFix))
  (define (hex-fold s i end acc)
    "The value of the hex digits of S from I to END, added to ACC. The caller has counted
them, so every character here is one."
    (if (>= i end)
        acc
        (hex-fold s (+ i 1) end
                  (+ (* acc 16)
                     (match (str:ref s i)
                       ((Some c) (match (hex-value c) ((Some v) v) ((None) 0)))
                       ((None) 0))))))

  (declare ext-char-ok? (Char -> Boolean))
  (define (ext-char-ok? c)
    "A character a chunk extension may hold: HTAB, or anything visible or a space, but no
control character and no DEL."
    (let ((code (char:char-code c)))
      (or (== code 9) (and (>= code 32) (not (== code 127))))))

  (declare ext-clean-from? (String * UFix -> Boolean))
  (define (ext-clean-from? s i)
    (match (str:ref s i)
      ((Some c) (and (ext-char-ok? c) (ext-clean-from? s (+ i 1))))
      ((None) True)))

  (declare chunk-ext-ok? (String -> Boolean))
  (define (chunk-ext-ok? rest)
    "What follows the chunk-size on its line: nothing, or optional whitespace then `;' and the
extensions (RFC 9112 7.1.1). The extensions are not interpreted -- nothing here uses one --
but they must be clean, so a line cannot carry a control character past this parser."
    (let ((trimmed (trim-start rest 0)))
      (or (== (str:length rest) 0)
          (and (char-at? trimmed 0 #\;) (ext-clean-from? trimmed 0)))))

  (declare parse-chunk-size-line (String -> Chunk-Step))
  (define (parse-chunk-size-line view)
    "Read the chunk-size line at the start of VIEW: 1*HEXDIG, then any extensions, then CRLF.
Step-Ok carries the size and the octets the line took, CRLF included. A size of 0 is the
last chunk; the trailer section follows it (PARSE-TRAILERS).

The view need hold no more than MAX-CHUNK-LINE-OCTETS + 2; past that without a CRLF, the line
is refused."
    (match (str:substring-index crlf view)
      ((None)
       (if (> (str:length view) max-chunk-line-octets)
           (Step-Rejected 400 "chunk-size line is too long")
           Step-Incomplete))
      ((Some end)
       (if (> end max-chunk-line-octets)
           (Step-Rejected 400 "chunk-size line is too long")
           (let ((line (str:substring view 0 end)))
             (if (not (line-clean? line))
                 (Step-Rejected 400 "bare CR or LF in a chunk-size line")
                 (let ((digits (hex-digits-from line 0)))
                   (cond
                     ((== digits 0) (Step-Rejected 400 "chunk-size is not hexadecimal"))
                     ((> digits max-chunk-size-digits)
                      (Step-Rejected 400 "chunk-size has too many digits"))
                     ((not (chunk-ext-ok? (str:substring line digits (str:length line))))
                      (Step-Rejected 400 "malformed chunk extension"))
                     (True (Step-Ok (hex-fold line 0 digits 0) (+ end 2)))))))))))

  (declare parse-chunk-data-end (String -> Chunk-Step))
  (define (parse-chunk-data-end view)
    "Check that VIEW, which starts right after a chunk's data, starts with CRLF. Anything else
means the chunk-size did not describe the data, which is the disagreement this refuses."
    (cond
      ((< (str:length view) 2)
       (if (or (== (str:length view) 0) (char-at? view 0 cr))
           Step-Incomplete
           (Step-Rejected 400 "chunk data is not followed by CRLF")))
      ((and (char-at? view 0 cr) (char-at? view 1 lf)) (Step-Ok 0 2))
      (True (Step-Rejected 400 "chunk data is not followed by CRLF"))))

  (declare parse-trailers (String * UFix -> Chunk-Step))
  (define (parse-trailers view limit)
    "Read the trailer section at the start of VIEW, which starts after the last chunk's line:
field lines, each ending in CRLF, then CRLF. Step-Ok carries the octets it took. The fields
are checked as header fields are, and at most LIMIT octets and MAX-HEADER-FIELDS of them are
accepted, as for the head; they are not returned (see CHUNKED BODIES)."
    (if (and (char-at? view 0 cr) (char-at? view 1 lf))
        (Step-Ok 0 2)
        (match (str:substring-index crlfcrlf view)
          ((None)
           (if (> (str:length view) limit)
               (Step-Rejected 431 "trailer section exceeds the maximum size")
               Step-Incomplete))
          ((Some end)
           (if (> (+ end 4) limit)
               (Step-Rejected 431 "trailer section exceeds the maximum size")
               (let ((lines (split-crlf (str:substring view 0 end))))
                 (if (> (list:length lines) max-header-fields)
                     (Step-Rejected 431 "too many trailer fields")
                     (match (parse-fields lines Nil)
                       ((Err e) (match e ((Tuple st why) (Step-Rejected st why))))
                       ((Ok _) (Step-Ok 0 (+ end 4)))))))))))

  (declare step-incomplete? (Chunk-Step -> Boolean))
  (define (step-incomplete? r) (match r ((Step-Incomplete) True) (_ False)))

  (declare step-ok? (Chunk-Step -> Boolean))
  (define (step-ok? r) (match r ((Step-Ok _ _) True) (_ False)))

  (declare step-rejected? (Chunk-Step -> Boolean))
  (define (step-rejected? r) (match r ((Step-Rejected _ _) True) (_ False)))

  (declare step-value (Chunk-Step -> UFix))
  (define (step-value r) (match r ((Step-Ok v _) v) (_ 0)))

  (declare step-consumed (Chunk-Step -> UFix))
  (define (step-consumed r) (match r ((Step-Ok _ n) n) (_ 0)))

  (declare step-status (Chunk-Step -> UFix))
  (define (step-status r) (match r ((Step-Rejected st _) st) (_ 0)))

  (declare step-reason (Chunk-Step -> String))
  (define (step-reason r) (match r ((Step-Rejected _ why) why) (_ "")))

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
    "Whether the request declares a body by Content-Length. A chunked body is not one of
these: see HEAD-CHUNKED?."
    (match (head-request h)
      ((Request _ _ _ _ b _) (match b ((Body-Exact _) True) (_ False)))))

  (declare head-chunked? (Head-Result -> Boolean))
  (define (head-chunked? h)
    "Whether the request's body is sent with Transfer-Encoding: chunked (#374)."
    (match (head-request h)
      ((Request _ _ _ _ b _) (match b ((Body-Chunked) True) (_ False)))))

  (declare head-body-length (Head-Result -> UFix))
  (define (head-body-length h)
    "The declared body length, 0 when there is none. The shell compares this against its own
configurable cap and answers 413 -- that limit is policy, so it is not decided here."
    (match (head-request h)
      ((Request _ _ _ _ b _) (match b ((Body-Exact n) n) (_ 0)))))

  (declare head-headers-flat (Head-Result -> (List String)))
  (define (head-headers-flat h)
    "Header fields as a FLAT name/value list -- (\"host\" \"x\" \"accept\" \"y\") -- so the CL
shell builds its hash table without touching a Tuple. Same convention as hyperion/path's
bindings."
    (match (head-request h)
      ((Request _ _ _ hs _ _)
       (list:concat (map (fn (p) (match p ((Tuple k v) (Cons k (Cons v Nil))))) hs))))))
