;;;; key.lisp --- what a blob key may be, and who may see it (Coalton core).
;;;;
;;;; A blob key is the one value in this module that routinely comes from user input: an
;;;; upload's filename, a slug, a member id pasted into a path. On the S3 backend a bad
;;;; key is merely a 404; on the FILESYSTEM backend a key containing `..' escapes the
;;;; store root and reads or overwrites an arbitrary file. That difference is exactly why
;;;; validation belongs HERE, in the shared typed core, rather than in each backend where
;;;; it would be the filesystem backend's private responsibility to remember.
;;;;
;;;; No IO. The effectful shell (hermes/blob) validates at the protocol seam, so every
;;;; backend inherits the same answer.

(cl:in-package #:hermes/blob-key)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- why a key was rejected ---------------------------------------------
  ;;;
  ;;; An ADT rather than a boolean or a string: the caller that wants to turn a rejection
  ;;; into an HTTP status cares WHICH fault it was (a too-long key is a 413-shaped
  ;;; problem, a dot segment is a 400-shaped one), and a message it has to re-parse is
  ;;; not an answer.
  (define-type Key-Fault
    "Why a candidate blob key is not a blob key.

  KEY-EMPTY           the empty string names nothing.
  KEY-TOO-LONG        longer than MAX-KEY-LENGTH bytes.
  KEY-ABSOLUTE        begins with `/' -- a key is always relative to its bucket.
  KEY-TRAILING-SLASH  ends with `/' -- that names a prefix, not an object.
  KEY-DOT-SEGMENT     contains a `.' or `..' segment -- the traversal case.
  KEY-EMPTY-SEGMENT   contains `//' -- two different keys would name one object.
  KEY-BACKSLASH       contains `\\' -- a path separator on Windows, so a key that is
                      inert on Linux is a traversal there.
  KEY-BAD-CHAR        contains a character outside the safe set (see KEY-CHAR-OK?)."
    Key-Empty
    Key-Too-Long
    Key-Absolute
    Key-Trailing-Slash
    Key-Dot-Segment
    Key-Empty-Segment
    Key-Backslash
    Key-Bad-Char)

  (declare max-key-length UFix)
  (define max-key-length
    "The longest key we accept. S3's own limit is 1024 UTF-8 bytes, and a filesystem
backend is bounded well below that by PATH_MAX -- so this is the smaller of two ceilings
we do not control, applied uniformly rather than discovered per backend."
    1024)

  (declare key-fault-message (Key-Fault -> String))
  (define (key-fault-message f)
    "A human-readable reason for F, for a condition report. Deliberately describes the
SHAPE that was wrong and never echoes the key: a key can carry a member id or a filename,
and this text ends up in logs."
    (match f
      ((Key-Empty) "a blob key may not be empty")
      ((Key-Too-Long) "a blob key may not exceed 1024 characters")
      ((Key-Absolute) "a blob key may not begin with '/'")
      ((Key-Trailing-Slash) "a blob key may not end with '/'")
      ((Key-Dot-Segment) "a blob key may not contain a '.' or '..' segment")
      ((Key-Empty-Segment) "a blob key may not contain an empty segment ('//')")
      ((Key-Backslash) "a blob key may not contain a backslash")
      ((Key-Bad-Char)
       "a blob key may contain only letters, digits, '-', '_', '.', '/' and '='")))

  (declare key-char-ok? (Char -> Boolean))
  (define (key-char-ok? c)
    "Is C allowed in a blob key?

An allowlist, not a denylist. The safe set is what survives a URL path, a filesystem path
and an S3 key unchanged, so that the SAME key means the same object on every backend and
no round-trip has to re-encode it. Anything else -- spaces, quotes, `%', control
characters, non-ASCII -- is the app's to encode into this alphabet before it gets here,
which is a decision it can make correctly and we cannot."
    (or (char:ascii-alphanumeric? c)
        (or (== c #\-)
            (or (== c #\_)
                (or (== c #\.)
                    (or (== c #\/)
                        (== c #\=)))))))

  (declare segment-ok? (String -> Boolean))
  (define (segment-ok? s)
    "Is S a usable path segment -- non-empty and not a dot segment?"
    (and (not (== s ""))
         (and (not (== s "."))
              (not (== s "..")))))

  (declare validate-blob-key (String -> (Result Key-Fault String)))
  (define (validate-blob-key s)
    "S if it is a well-formed blob key, else the first fault that rejects it.

Order matters only for which message a caller sees; every check is independent."
    (let ((len (str:length s)))
      (cond
        ((== len 0) (Err Key-Empty))
        ((> len max-key-length) (Err Key-Too-Long))
        ((== (str:ref s 0) (Some #\/)) (Err Key-Absolute))
        ((== (str:ref s (- len 1)) (Some #\/)) (Err Key-Trailing-Slash))
        ((str:substring? "\\" s) (Err Key-Backslash))
        ((str:substring? "//" s) (Err Key-Empty-Segment))
        ((not (list:all segment-ok? (str:split #\/ s))) (Err Key-Dot-Segment))
        ((not (iter:every! key-char-ok? (str:chars s))) (Err Key-Bad-Char))
        (True (Ok s)))))

  ;;; --- the CL boundary -----------------------------------------------------
  ;;; Monomorphic wrappers: a `Result' is awkward to consume from CL, and the shell only
  ;;; ever asks two things of it.

  (declare blob-key-ok? (String -> Boolean))
  (define (blob-key-ok? s)
    "Is S a well-formed blob key? The predicate half, for the CL shell."
    (match (validate-blob-key s)
      ((Ok _) True)
      ((Err _) False)))

  (declare blob-key-fault-message (String -> String))
  (define (blob-key-fault-message s)
    "Why S is not a blob key, or the empty string if it is one. The reporting half: the
shell pairs this with BLOB-KEY-OK? rather than re-deriving the reason."
    (match (validate-blob-key s)
      ((Ok _) "")
      ((Err f) (key-fault-message f))))

  ;;; --- visibility ----------------------------------------------------------

  (define-type Blob-Visibility
    "Who may fetch a blob by URL.

  BLOB-PRIVATE  reachable only through a signed URL that EXPIRES. The default, and the
                right answer for anything attached to members-only content.
  BLOB-PUBLIC   reachable by anyone holding the URL, forever, and cacheable by a CDN.

These are not two settings of one flag: they produce different URLs by different
mechanisms, and a private blob served from a public bucket is a permanent unauthenticated
link that outlives the membership, the post, and any later decision to unpublish."
    Blob-Private
    Blob-Public)

  (declare blob-visibility-name (Blob-Visibility -> String))
  (define (blob-visibility-name v)
    "The spelling used in configuration and in MNEMOSYNE_BLOB_VISIBILITY."
    (match v
      ((Blob-Private) "private")
      ((Blob-Public) "public")))

  (declare blob-visibility-public? (Blob-Visibility -> Boolean))
  (define (blob-visibility-public? v)
    "Does V permit an unsigned, non-expiring URL?"
    (match v
      ((Blob-Private) False)
      ((Blob-Public) True)))

  (declare parse-blob-visibility (String -> (Optional Blob-Visibility)))
  (define (parse-blob-visibility s)
    "Decode a visibility token. S must already be lowercased and trimmed."
    (match s
      ("private" (Some Blob-Private))
      ("public" (Some Blob-Public))
      (_ None)))

  (declare blob-visibility-or-private (String -> Blob-Visibility))
  (define (blob-visibility-or-private s)
    "PARSE-BLOB-VISIBILITY, defaulting to BLOB-PRIVATE.

The default is deliberately the restrictive one. A misspelled visibility that quietly
meant `public' would publish user media, and the failure would be silent and permanent;
misreading it as private fails loudly the first time someone opens the link."
    (match (parse-blob-visibility s)
      ((Some v) v)
      ((None) Blob-Private))))
