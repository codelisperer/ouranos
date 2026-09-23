;;;; encoder.lisp --- a response head, framed by what is actually there (#117, commit 2).
;;;;
;;;; The parser's mirror image, and it enforces the same rule in the other direction: NEVER
;;;; LET A HEADER DISAGREE WITH THE FRAMING. Inbound, that rule rejects Content-Length and
;;;; Transfer-Encoding together, because two framings that disagree are how a request gets
;;;; smuggled past one parser in a chain. Outbound, it means the Content-Length we write is
;;;; the byte count we COMPUTED, and any Content-Length a caller supplied is discarded rather
;;;; than trusted -- a handler that sets one and then returns a different number of bytes
;;;; would otherwise desync the connection for every request that follows on it.
;;;;
;;;; RESPONSE SPLITTING is the outbound twin of smuggling and the reason this refuses rather
;;;; than sanitises. A CR or LF inside a header value ends the header block early, and
;;;; everything after it is read by the client as more headers -- or as a second response.
;;;; The value usually comes from user input: a redirect Location built from a query
;;;; parameter, a cookie echoing a form field. Stripping the character quietly would leave a
;;;; handler shipping something subtly different from what it asked for; REFUSING makes it a
;;;; visible 500 in development, which is where you want to meet it.
;;;;
;;;; Same split as the parser: Coalton produces the HEAD as a String (ISO-8859-1, so one
;;;; character is one octet), and the CL shell concatenates head octets with body octets. The
;;;; body is never decoded and never copied through here.
;;;;
;;;; NO DATE HEADER, deliberately. RFC 9110 wants one on most responses, and it needs a clock
;;;; -- which is IO, which does not belong in Coalton. The shell adds it. Recorded here so it
;;;; reads as a decision rather than as an oversight.

(cl:in-package #:hyperion/http1)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;; NUL, built from its code point. Not #\Nul: Common Lisp reads that name, but Coalton
  ;; installs its own readtable and does not, so the character literal is a compile error
  ;; here even though it works one file over in plain CL. CODE-CHAR-UNCHECKED is partial by
  ;; name and total at 0, which is the whole domain it is used on.
  (declare nul Char)
  (define nul
    (match (char:code-char 0)
      ((Some c) c)
      ;; Unreachable -- 0 is a code point on every implementation -- but MATCH makes the
      ;; total function total instead of asserting it, and CODE-CHAR-UNCHECKED is internal
      ;; to coalton/char and cannot be reached from here anyway.
      ((None) #\Space)))

  (define-type Encode-Result
    "A response head, or the reason it will not be written.

  Encoded s   the full head, terminator included, ready to become octets.
  Refused why the response is malformed IN A WAY THAT WOULD BE DANGEROUS TO SEND. The
              caller turns this into a 500; it is never a response body on its own, since
              the reason may quote the very header that was rejected."
    (Encoded String)
    (Refused String))

  ;;; --- status lines ---------------------------------------------------------

  (declare reason-phrase (UFix -> String))
  (define (reason-phrase status)
    "The reason phrase for STATUS, or \"Unknown\".

Only the codes this server actually emits are spelled out. A reason phrase carries no
meaning to any client -- RFC 9110 says a client MUST NOT act on it -- so an unknown code is
served rather than refused, and the numeric status still means exactly what it means."
    (cond
      ((== status 100) "Continue")
      ((== status 200) "OK")
      ((== status 201) "Created")
      ((== status 204) "No Content")
      ((== status 301) "Moved Permanently")
      ((== status 302) "Found")
      ((== status 303) "See Other")
      ((== status 304) "Not Modified")
      ((== status 307) "Temporary Redirect")
      ((== status 308) "Permanent Redirect")
      ((== status 400) "Bad Request")
      ((== status 401) "Unauthorized")
      ((== status 403) "Forbidden")
      ((== status 404) "Not Found")
      ((== status 405) "Method Not Allowed")
      ((== status 408) "Request Timeout")
      ((== status 413) "Content Too Large")
      ((== status 414) "URI Too Long")
      ((== status 415) "Unsupported Media Type")
      ((== status 417) "Expectation Failed")
      ((== status 431) "Request Header Fields Too Large")
      ((== status 500) "Internal Server Error")
      ((== status 501) "Not Implemented")
      ((== status 503) "Service Unavailable")
      ((== status 505) "HTTP Version Not Supported")
      (True "Unknown")))

  (declare status-ok? (UFix -> Boolean))
  (define (status-ok? status)
    "Is STATUS a three-digit HTTP status? Bounded here so a caller cannot put an arbitrary
integer on the status line, which would make the rest of the message unparseable to the
client rather than merely wrong."
    (and (>= status 100) (<= status 599)))

  (declare status-line (UFix -> String))
  (define (status-line status)
    (<> "HTTP/1.1 "
        (<> (the String (into status))
            (<> " " (<> (reason-phrase status) crlf)))))

  ;;; --- header safety --------------------------------------------------------

  (declare header-value-safe? (String -> Boolean))
  (define (header-value-safe? v)
    "No CR, LF or NUL anywhere in the value.

An allow-everything-but-these check rather than a full field-value grammar: obs-text makes
most bytes legal in a value, and the three that end or truncate the header block are the
three that turn a value into a forged header."
    (and (not (contains-char? v cr))
         (and (not (contains-char? v lf))
              (not (contains-char? v nul)))))

  (declare framing-header? (String -> Boolean))
  (define (framing-header? name)
    "Is NAME a header this layer computes for itself? A caller-supplied one is DROPPED, not
merged and not honoured -- see the file header on why a supplied Content-Length is the
dangerous case."
    (or (== name "content-length")
        (or (== name "transfer-encoding")
            (== name "connection"))))

  (declare check-headers ((List (Tuple String String)) -> (Optional String)))
  (define (check-headers headers)
    "The reason the first unsafe header is unsafe, or None. Checked BEFORE anything is
rendered, so a refusal never leaves a half-written head."
    (match headers
      ((Nil) None)
      ((Cons h rest)
       (match h
         ((Tuple name value)
          (if (not (token? name))
              (Some (<> "header name is not a token: " name))
              (if (not (header-value-safe? value))
                  (Some (<> "CR, LF or NUL in the value of header " name))
                  (check-headers rest))))))))

  ;;; --- rendering ------------------------------------------------------------

  (declare render-headers ((List (Tuple String String)) -> String))
  (define (render-headers headers)
    (match headers
      ((Nil) "")
      ((Cons h rest)
       (match h
         ((Tuple name value)
          (if (framing-header? (str:downcase name))
              (render-headers rest)
              (<> (<> name (<> ": " (<> value crlf)))
                  (render-headers rest))))))))

  (declare encode-head (UFix * (List (Tuple String String)) * UFix * Boolean -> Encode-Result))
  (define (encode-head status headers body-length keep-alive)
    "The full response head for STATUS with HEADERS, framed for a body of exactly
BODY-LENGTH octets.

BODY-LENGTH is the number the caller MEASURED, not one it was told. Content-Length,
Transfer-Encoding and Connection are dropped from HEADERS and written from the arguments,
so the framing on the wire cannot disagree with the bytes that follow it."
    (if (not (status-ok? status))
        (Refused (<> "status is not a three-digit HTTP status: " (the String (into status))))
        (match (check-headers headers)
          ((Some why) (Refused why))
          ((None)
           (Encoded
            (<> (status-line status)
                (<> (render-headers headers)
                    (<> (<> "Content-Length: " (<> (the String (into body-length)) crlf))
                        (<> (<> "Connection: "
                                (<> (if keep-alive "keep-alive" "close") crlf))
                            crlf)))))))))

  (declare encode-interim (UFix -> Encode-Result))
  (define (encode-interim status)
    "An INTERIM (1xx) response: a status line and the blank line, and nothing else.

NO CONTENT-LENGTH, and that is the entire subtlety. RFC 9110 forbids a body on a 1xx, so a
client that has read one goes on to read the NEXT message as the final response. A
Content-Length here would tell it to consume that many octets first -- it would eat the
real response's head as a body and the connection would desynchronise, which is a framing
bug that looks like a hung client.

That is also why this cannot be ENCODE-HEAD with an empty body: ENCODE-HEAD always frames,
because for a final response framing is exactly what it is for."
    (if (and (>= status 100) (<= status 199))
        (Encoded (<> (status-line status) crlf))
        (Refused (<> "not an interim (1xx) status: " (the String (into status))))))

  ;;; --- chunked framing, for a body whose length is not known up front (M2) ---
  ;;;
  ;;; ENCODE-HEAD frames by counting the bytes, which is the right answer whenever the bytes
  ;;; exist. A streamed body's do not: SSE, a progress feed and a long export all produce
  ;;; their content while the response is already on the wire, so there is nothing to count.
  ;;; Chunked transfer-encoding is HTTP/1.1's answer -- each piece carries its own length, so
  ;;; the message can end without anyone having known in advance where.
  ;;;
  ;;; THE FRAMING RULE IS THE SAME ONE, and it is the reason these live here rather than in
  ;;; the shell as string concatenation. A chunk size that disagrees with the octets after it
  ;;; desynchronises the connection exactly as a wrong Content-Length does -- and worse, the
  ;;; boundary is now attacker-adjacent per chunk rather than once per response. So the size
  ;;; line is COMPUTED from the length the caller measured, in the one place that also refuses
  ;;; the cases that cannot be framed at all.
  ;;;
  ;;; NO TRAILERS and no chunk extensions. Both are legal and neither is wanted: extensions
  ;;; are a parsing surface with no consumer, and trailers move headers after the body, where
  ;;; every intermediary in the path has already made its decisions. Their absence is a
  ;;; decision, recorded here so the next reader does not take it for an oversight.

  (declare body-forbidden? (UFix -> Boolean))
  (define (body-forbidden? status)
    "Statuses that MUST NOT carry a body at all: 1xx, 204 and 304 (RFC 9110).

Framing one of these as chunked is not a style error, it is a desynchronisation: the client
knows these have no body, so it reads the next message immediately -- and what it finds is
our terminating chunk, parsed as a status line. Every response after it on the connection is
then off by one message."
    (or (and (>= status 100) (<= status 199))
        (or (== status 204) (== status 304))))

  (declare hex-digit (UFix -> String))
  (define (hex-digit n)
    "One LOWERCASE hex digit for N < 16. Total: anything at or above 15 reads as \"f\",
which TO-HEX never asks for because it only ever passes a remainder."
    (cond
      ((== n 0) "0") ((== n 1) "1") ((== n 2) "2") ((== n 3) "3")
      ((== n 4) "4") ((== n 5) "5") ((== n 6) "6") ((== n 7) "7")
      ((== n 8) "8") ((== n 9) "9") ((== n 10) "a") ((== n 11) "b")
      ((== n 12) "c") ((== n 13) "d") ((== n 14) "e")
      (True "f")))

  (declare to-hex (UFix -> String))
  (define (to-hex n)
    "N in lowercase hex, no prefix, NO LEADING ZEROES and no padding.

Each of those is a smuggling vector rather than a formatting preference. Chunk sizes are
where parsers in a chain disagree: a leading `0x', a padded width, or an over-long field are
read differently by different implementations, and a request that two proxies frame
differently is the whole mechanism of smuggling. The minimal form is the one nothing
disagrees about."
    (if (< n 16)
        (hex-digit n)
        (<> (to-hex (math:quot n 16)) (hex-digit (math:mod n 16)))))

  (declare encode-head-chunked (UFix * (List (Tuple String String)) * Boolean
                                -> Encode-Result))
  (define (encode-head-chunked status headers keep-alive)
    "The response head for a STREAMED body: Transfer-Encoding: chunked, no Content-Length.

The mirror of ENCODE-HEAD, and it takes no length precisely because there is not one to
take. Content-Length, Transfer-Encoding and Connection are dropped from HEADERS and written
from here, so a handler cannot set a length beside a framing that contradicts it -- which is
the same rule ENCODE-HEAD enforces, in the case where the caller has more room to get it
wrong.

REFUSED for a status that cannot carry a body. See BODY-FORBIDDEN?: the failure is a
desynchronised connection, not a malformed response, so it must not reach the wire."
    (if (not (status-ok? status))
        (Refused (<> "status is not a three-digit HTTP status: " (the String (into status))))
        (if (body-forbidden? status)
            (Refused (<> "status cannot carry a body, so it cannot be chunked: "
                         (the String (into status))))
            (match (check-headers headers)
              ((Some why) (Refused why))
              ((None)
               (Encoded
                (<> (status-line status)
                    (<> (render-headers headers)
                        (<> (<> "Transfer-Encoding: chunked" crlf)
                            (<> (<> "Connection: "
                                    (<> (if keep-alive "keep-alive" "close") crlf))
                                crlf))))))))))

  (declare encode-chunk-header (UFix -> Encode-Result))
  (define (encode-chunk-header n)
    "The size line introducing a chunk of exactly N octets: the hex length and CRLF.

The DATA does not pass through here. A chunk body is octets -- an image, a compressed
segment, a UTF-8 fragment that may split a character -- and decoding it to a String to
re-encode it would be both wasteful and lossy. The shell writes size-line, then the octets,
then CRLF. Same split as the response head.

N = 0 IS REFUSED, and this is the one that would otherwise be found in production. A
zero-length chunk is not an empty piece of data, it IS the message terminator: writing one
mid-stream ends the response while the server believes it is still streaming, and everything
it writes afterwards is read by the client as the next response. That is response smuggling
with the server supplying both halves -- the same failure the once-only response guard
exists to prevent, one layer down. A handler yielding an empty string is an ordinary thing
to do by accident, so the empty case is made UNAVAILABLE here rather than left to every
caller to remember. Ending the message is LAST-CHUNK, which says so by name."
    (if (== n 0)
        (Refused "a zero-length chunk is the terminator; use LAST-CHUNK to end the message")
        (Encoded (<> (to-hex n) crlf))))

  ;; The terminating zero-length chunk plus the empty trailer section that closes the
  ;; message. Written exactly once, after the final data chunk.
  ;;
  ;; Its absence is not a missing byte, it is a HUNG CLIENT: the message never ends, so the
  ;; peer waits for a chunk that never comes until something times out. That is the failure
  ;; mode this whole file is arranged to make impossible, arriving through the one piece
  ;; that is easy to forget because it carries no data.
  ;;
  ;; A comment rather than a docstring, and a `define' rather than a function, matching
  ;; MAX-HEAD-OCTETS: a Coalton toplevel `define' of a non-function compiles to a global
  ;; lexical, so the shell reads it as (coalton h1:last-chunk) rather than by calling it.
  (declare last-chunk String)
  (define last-chunk (<> "0" (<> crlf crlf)))

  (declare encode-head-chunked-flat (UFix * (List String) * Boolean -> Encode-Result))
  (define (encode-head-chunked-flat status flat keep-alive)
    "ENCODE-HEAD-CHUNKED taking headers as a flat (\"name\" \"value\" ...) list."
    (match (pairs-from-flat flat Nil)
      ((None) (Refused "header list has an odd number of elements"))
      ((Some pairs) (encode-head-chunked status pairs keep-alive))))

  (declare encode-error (UFix -> String))
  (define (encode-error status)
    "A complete, self-framed error response -- head AND body -- for a request that never
became one. All ASCII, so unlike a normal response it is a single String and the shell has
no body to append.

IT DOES NOT TAKE THE PARSER'S REASON, and that is the point rather than an omission. The
reason is developer-facing text about a malformed message; echoing it would hand an
attacker a description of what the parser noticed, one probe at a time. The caller LOGS it
and sends this. The body is the reason PHRASE, which the client already knows from the
status. (It was a parameter first, and Coalton refused to build the file with it unused --
which is the rule in AGENTS.md doing exactly its job.)

Always Connection: close. Once a message could not be parsed, the position of the next one
in the stream is unknown, so reusing the connection would be guessing."
    (let ((body (<> (the String (into status)) (<> " " (reason-phrase status)))))
      (<> (status-line status)
          (<> (<> "Content-Type: text/plain; charset=utf-8" crlf)
              (<> (<> "Content-Length: " (<> (the String (into (str:length body))) crlf))
                  (<> (<> "Connection: close" crlf)
                      (<> crlf body)))))))

  ;;; --- the CL-facing surface ------------------------------------------------
  ;;;
  ;;; The shell passes headers as a FLAT list of strings, never as Tuples -- the same
  ;;; convention HEAD-HEADERS-FLAT uses in the other direction, and for the same reason: a
  ;;; Coalton Tuple is not a CL cons, so CL code that builds one by hand gets a pattern-match
  ;;; failure at runtime rather than a type error at compile time. (Found exactly that way:
  ;;; the first encoder suite passed `(cons name value)' and every refusal test died on
  ;;; "Pattern match not exhaustive" instead of asserting anything.)

  (declare pairs-from-flat ((List String) * (List (Tuple String String))
                            -> (Optional (List (Tuple String String)))))
  (define (pairs-from-flat xs acc)
    "Pair up a flat name/value list. None when it has an odd length -- dropped silently, a
trailing name would send a response missing the header the caller believed it set."
    (match xs
      ((Nil) (Some (list:reverse acc)))
      ((Cons k (Cons v rest)) (pairs-from-flat rest (Cons (Tuple k v) acc)))
      ((Cons _ _) None)))

  (declare encode-head-flat (UFix * (List String) * UFix * Boolean -> Encode-Result))
  (define (encode-head-flat status flat body-length keep-alive)
    "ENCODE-HEAD taking headers as a flat (\"name\" \"value\" \"name\" \"value\") list."
    (match (pairs-from-flat flat Nil)
      ((None) (Refused "header list has an odd number of elements"))
      ((Some pairs) (encode-head status pairs body-length keep-alive))))


  (declare encode-ok? (Encode-Result -> Boolean))
  (define (encode-ok? r)
    (match r ((Encoded _) True) ((Refused _) False)))

  (declare encode-text (Encode-Result -> String))
  (define (encode-text r)
    "The head to write, or \"\" when the result was a refusal."
    (match r ((Encoded s) s) ((Refused _) "")))

  (declare encode-reason (Encode-Result -> String))
  (define (encode-reason r)
    "Why it was refused, or \"\" when it was not."
    (match r ((Encoded _) "") ((Refused why) why))))
