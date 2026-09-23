;;;; http.lisp --- raw-Clack request/response utilities.
;;;;
;;;; Small, domain-neutral helpers over the raw Clack env: decode the request
;;;; body, pull a form param, negotiate JSON, and encode/decode JSON. SBCL octet
;;;; decoding, no extra deps beyond jzon. Extracted from praxeon/src/web.lisp
;;;; (%body-string/%form-param/%wants-json/%json); %request-message stays with the
;;;; caller -- Hyperion offers JSON-OBJECT and the caller extracts its own key.

(in-package #:hyperion/http)

(defconstant +body-string-key+ :hyperion.http/body-string
  "ENV key holding an already-read request body, installed by CACHE-BODY-STRING.

The request body is a STREAM, so it can be read exactly once: whoever reads it first gets
it and every reader after gets NIL. A middleware that needs to look inside the body -- the
CSRF check reading its _csrf field, for one -- would otherwise break every handler
downstream of it while testing perfectly green itself.")

(defun cache-body-string (env string)
  "ENV with STRING installed as its already-read body, for BODY-STRING to return instead of
touching the stream. Returns a NEW plist; ENV is not modified."
  (list* +body-string-key+ string env))

(defconstant +multipart-parts-key+ :hyperion.http/multipart-parts
  "ENV key holding already-parsed multipart PARTs, installed by CACHE-MULTIPART-PARTS.

The multipart counterpart of +BODY-STRING-KEY+ and for the same reason: the body is a
stream, so it parses exactly once. A middleware that must look inside a multipart body --
the CSRF check reading its _csrf field -- would otherwise consume it and leave the handler's
own PARSE-MULTIPART scanning for an opening boundary that is already gone.")

(defun cache-multipart-parts (env parts)
  "ENV with PARTS installed as its already-parsed multipart body. Returns a NEW plist.

OWNERSHIP IS UNCHANGED BY CACHING: whoever would have called DELETE-PARTS still calls it.
See WRAP-CSRF for the one asymmetry this creates."
  (list* +multipart-parts-key+ parts env))

(defvar *max-body-size* (* 20 1024 1024)
  "Largest request body accepted, in bytes, for ANY content type. Default 20 MB.

ON BY DEFAULT deliberately, and it governs every body reader rather than only the multipart
one. A limit an application has to remember to set is one that is not set on the day it
matters -- and a ceiling on one reader while its neighbour has none is worse than no ceiling
at all, because the presence of a limit reads as the question having been asked (#211).")

(define-condition body-too-large (error)
  ((limit :initarg :limit :reader body-too-large-limit)
   (claimed :initarg :claimed :initform nil :reader body-too-large-claimed))
  (:report (lambda (c s)
             (format s "hyperion/http: request body exceeds ~:D bytes~@[ (Content-Length claimed ~:D)~]"
                     (body-too-large-limit c) (body-too-large-claimed c))))
  (:documentation "The request body is larger than *MAX-BODY-SIZE*, or claims to be."))

(defun %read-bounded (stream limit &key claimed)
  "Read STREAM into an octet vector, refusing past LIMIT bytes.

READS IN CHUNKS RATHER THAN ALLOCATING CONTENT-LENGTH, which is the whole point. Trusting
the header for the allocation size means a client that claims twenty megabytes and sends one
byte still costs twenty megabytes -- so the cheapest possible request buys the largest
possible allocation. Here the cost is proportional to what was actually sent, and a liar gets
nothing for the lie.

CLAIMED is carried into the condition for the report only; it is never trusted for sizing."
  (let ((out (make-array (min 8192 (max 1 (or claimed 8192)))
                         :element-type '(unsigned-byte 8)
                         :adjustable t :fill-pointer 0))
        (chunk (make-array 8192 :element-type '(unsigned-byte 8))))
    (loop
      (let ((n (read-sequence chunk stream)))
        (when (zerop n) (return))
        (when (> (+ (fill-pointer out) n) limit)
          (error 'body-too-large :limit limit :claimed claimed))
        (let ((start (fill-pointer out)))
          (adjust-array out (+ start n) :fill-pointer (+ start n))
          (replace out chunk :start1 start :end2 n))
        (when (< n (length chunk)) (return))))
    out))

(defun body-string (env &key (max-size *max-body-size*))
  "The request body of the Clack ENV as a decoded UTF-8 string, or NIL.

For TEXT bodies -- urlencoded forms, JSON. Decoding a multipart body this way corrupts
every non-text byte in it before anything can parse it; see PARSE-MULTIPART.

Returns the CACHED body when one has been installed (see +BODY-STRING-KEY+), and otherwise
reads the stream. Without a cache this is single-use by construction: the stream is spent by
the first reader, and the second call gets NIL. That is a property of the request, not a bug
here, but it is the reason the cache exists.

BOUNDED BY MAX-SIZE, and this is a denial-of-service fix rather than tidiness (#211). The
previous version allocated exactly what Content-Length claimed, before reading a byte -- so
an unauthenticated request consisting of a header and no body at all could allocate
arbitrarily much. On a default SBCL image that is fatal rather than merely wasteful: the
allocation may succeed under memory overcommit, and the process then dies as the pages are
touched.

The bound is checked only on the STREAM path. A cached body was read through this function
already and was bounded then; re-checking it would charge a caller twice for one read and,
worse, could refuse a body that has already been handed to a middleware.

ONLY THE BYTES ACTUALLY READ ARE DECODED. Content-Length is what the client CLAIMS, and a
short read -- a spent stream, a truncated upload, a client that lied -- used to leave the
rest of the buffer at zero and decode it, yielding a same-length string of NUL characters.
That is worse than NIL by some way: FORM-PARAM finds no field in it and returns NIL, so a
truncated body is indistinguishable from an absent one at every call site.

Signals BODY-TOO-LARGE rather than truncating. A truncated JSON body is a parse error at
best and a silently different request at worst, and neither is a thing to hand an
application without telling it."
  (let ((cached (getf env +body-string-key+ :%unread)))
    (if (not (eq cached :%unread))
        cached
        (let ((stream (getf env :raw-body))
              (len (getf env :content-length)))
          (when stream
            ;; Refuse on the CLAIM before touching the stream: a header alone is the cheap
            ;; attack, so rejecting it should be the cheap defence.
            (when (and len (integerp len) (> len max-size))
              (error 'body-too-large :limit max-size :claimed len))
            (when (or (null len) (plusp len))
              (let ((buf (%read-bounded stream max-size :claimed len)))
                (when (plusp (length buf))
                  (sb-ext:octets-to-string buf :external-format :utf-8)))))))))

;;; --- urlencoded pairs: one parser, three readers ---------------------------
;;;
;;; A name can legally REPEAT. An HTML checkbox group posts one pair per ticked box
;;; (community=alpha&community=beta), and so do <select multiple>, repeated tag inputs and
;;; query strings like ?tag=a&tag=b. Reading only the first value is not a rounding error:
;;; it is a plausible answer that happens to be one element of the real one, with no error
;;; and no empty value to notice, so a form that records one of three choices looks like a
;;; working form until somebody checks the data weeks later (#136).

(defun form-alist (body)
  "Every name/value pair of a urlencoded BODY, in order, url-decoded: ((name . value) ...).

URLENCODED ONLY. A multipart/form-data body is a different format entirely and yields
nothing here; use MULTIPART-P and PARSE-MULTIPART for that.

The single parser the readers below share. Also the one to call when a handler wants
several fields: it walks the body ONCE, where N calls to FORM-PARAM re-split the whole body
N times.

A pair with no `=` is skipped, which is what this module has always done -- a bare `?debug`
reads as absent rather than as the empty string. Preserved deliberately: changing it would
silently flip every `(when (query-param env \"debug\") ...)` in existing code from false to
true, which is a bigger change than it looks and is not what #136 is about."
  (when body
    (loop for pair in (uiop:split-string body :separator "&")
          for eq = (position #\= pair)
          when eq
            collect (cons (subseq pair 0 eq)
                          (quri:url-decode (subseq pair (1+ eq)) :lenient t)))))

(defun form-params (body name)
  "EVERY url-decoded value of form field NAME in a urlencoded BODY string, in order, as a
list. NIL when the field is absent.

This is the accessor for anything that can repeat -- a checkbox group, <select multiple>,
repeated tag or file inputs. If you are not certain a field cannot repeat, use this one."
  (loop for (k . v) in (form-alist body) when (string= k name) collect v))

(defun form-param (body name)
  "The FIRST url-decoded value of form field NAME in a urlencoded BODY string, or NIL.

DOES NOT HANDLE MULTIPART. A form containing a file input posts multipart/form-data, and
this returns NIL for every field of it -- which reads exactly like \"the field was absent\"
and is why it is said here rather than left to be discovered. Branch on MULTIPART-P and use
PARSE-MULTIPART + MULTIPART-PARAM when a form can carry a file.

FIRST, not only: a repeated field yields its remaining values to FORM-PARAMS, which is the
accessor to use when a field can occur more than once.

Why this still takes the first rather than signalling on a repeat, which would have turned
#136's silent loss into a loud error: the body is CLIENT-supplied. Anyone can post
`name=a&name=b` to any handler, so a reader that signalled on a repeated name would hand
every form in every app a remote way to raise an unhandled condition. A request parser has
to be total over whatever arrives. So the guarantee moved into the name and the docstring,
and FORM-PARAMS is where correctness lives."
  (first (form-params body name)))

(defun query-params (env name)
  "EVERY url-decoded value of query-string param NAME in the Clack ENV, as a list.
Repeated query keys (?tag=a&tag=b) are as legal as repeated form fields."
  (form-params (getf env :query-string) name))

(defun query-param (env name)
  "The FIRST url-decoded value of query-string param NAME in the Clack ENV, or NIL.
The query string uses the same k=v&k=v form as a urlencoded body; see FORM-PARAM on why
this is first-wins rather than an error."
  (form-param (getf env :query-string) name))

(defun request-header (env name)
  "Request header NAME (case-insensitive) from the Clack ENV, or NIL."
  (let ((h (getf env :headers)))
    (and h (gethash (string-downcase name) h))))

(defun cookie (env name)
  "The value of cookie NAME from the request's Cookie header, or NIL."
  (let ((raw (request-header env "cookie")))
    (when raw
      (dolist (pair (uiop:split-string raw :separator ";"))
        (let* ((kv (string-trim " " pair))
               (eq (position #\= kv)))
          (when (and eq (string= (subseq kv 0 eq) name))
            (return (subseq kv (1+ eq)))))))))

(defun wants-json (env)
  "True when the client asks for JSON via Accept or Content-Type."
  (let ((accept (gethash "accept" (getf env :headers) ""))
        (ct (or (getf env :content-type) "")))
    (or (search "application/json" accept)
        (search "application/json" ct))))

(defun json-object (body)
  "Parse a JSON BODY string into a hash-table, or NIL on error. The caller pulls
its own keys -- keeps this domain-neutral."
  (when body
    (ignore-errors (jzon:parse body))))

(defun json (plist)
  "Encode a flat PLIST as a JSON object string (keys and values via jzon)."
  (with-output-to-string (s)
    (write-char #\{ s)
    (loop for (k v) on plist by #'cddr
          for first = t then nil
          do (unless first (write-char #\, s))
             (format s "~A:~A" (jzon:stringify k) (jzon:stringify v)))
    (write-char #\} s)))

;;; ===========================================================================
;;; multipart/form-data (RFC 7578)
;;; ===========================================================================
;;;
;;; A file upload is the one request shape this module could not express at all (#143).
;;; BODY-STRING decodes the body as UTF-8, which corrupts every non-text byte before any
;;; parsing could begin, and nothing understood a boundary, a part header or a filename.
;;; So `<input type="file">` was not "awkward" -- the bytes were already damaged by the
;;; time app code saw them.
;;;
;;; Three things here are security decisions rather than conveniences, and each is a
;;; default rather than an option, because a ceiling nobody sets is not a ceiling:
;;;
;;;   1. The body is BOUNDED (*MAX-BODY-SIZE*) and so is the part count (*MAX-PARTS*).
;;;      A request with no Content-Length and an endless stream is the obvious attack; a
;;;      thousand tiny parts is the same attack wearing a different hat, and a byte
;;;      ceiling alone does not stop it.
;;;   2. Content is STREAMED, and a part over *MEMORY-THRESHOLD* spills to a temp file, so
;;;      no upload is held whole in memory at any point.
;;;   3. FILENAME is attacker-controlled and is returned BOTH ways -- PART-FILENAME is
;;;      exactly what arrived, PART-SAFE-FILENAME is sanitised. Both are present because
;;;      apps reach for whichever is nearest, so the nearest one had better be safe, and
;;;      the raw one had better be clearly labelled.

(define-condition multipart-error (error)
  ((detail :initarg :detail :initform nil :reader multipart-error-detail))
  (:report (lambda (c s) (format s "hyperion/http: malformed multipart request~@[ -- ~A~]"
                                 (multipart-error-detail c))))
  (:documentation "The request did not parse as multipart/form-data."))

(define-condition multipart-too-large (multipart-error)
  ((limit :initarg :limit :reader multipart-error-limit))
  (:report (lambda (c s) (format s "hyperion/http: request body exceeds ~:D bytes"
                                 (multipart-error-limit c)))))

(define-condition multipart-too-many-parts (multipart-error)
  ((limit :initarg :limit :reader multipart-error-limit))
  (:report (lambda (c s) (format s "hyperion/http: more than ~:D parts in one request"
                                 (multipart-error-limit c)))))

(defvar *max-parts* 256
  "Largest number of parts accepted in one multipart body. A thousand tiny parts exhausts
the same resources as one enormous one while staying under any byte ceiling.")

(defvar *memory-threshold* (* 1024 1024)
  "A part larger than this many bytes spills to a temp file instead of being kept in
memory. Default 1 MB -- comfortably above a form field, well below anything worth holding.")

(defstruct (part (:constructor %make-part) (:copier nil))
  "One part of a multipart body.

NAME is the form field name. FILENAME is the RAW client-supplied filename -- attacker
controlled, and NIL for an ordinary field. SAFE-FILENAME is that value sanitised (see
SANITIZE-FILENAME) and is the one to use when writing to disk. CONTENT-TYPE is what the
client CLAIMED the part is; it is not evidence -- an app deciding \"this is an image\"
from it has an upload vulnerability, since anyone can send image/png over anything.

Content is in BYTES when small, or spilled to the file at PATH when large; SIZE is the
byte count either way."
  (name "" :type string)
  (filename nil)
  (safe-filename nil)
  (content-type nil)
  (headers '())
  (bytes nil)
  (path nil)
  (size 0 :type unsigned-byte))

(defun part-file-p (part)
  "True when PART came from a file input (it carried a filename), whether or not its
content spilled to disk. Distinct from PART-PATH, which asks where the bytes are."
  (and (part-filename part) t))

(defun part-text (part &key (external-format :utf-8))
  "PART's content as a string. For ordinary form fields; a spilled part is read back from
disk. Returns NIL rather than signalling if the bytes are not valid in EXTERNAL-FORMAT --
a client can send anything, and a decode error on a text field should not take a handler
down when the field can simply be rejected as invalid."
  (handler-case
      (let ((octets (or (part-bytes part)
                        (and (part-path part)
                             (with-open-file (s (part-path part) :element-type '(unsigned-byte 8))
                               (let ((buf (make-array (file-length s)
                                                      :element-type '(unsigned-byte 8))))
                                 (read-sequence buf s)
                                 buf))))))
        (and octets (sb-ext:octets-to-string octets :external-format external-format)))
    (error () nil)))

;;; --- filenames -------------------------------------------------------------

(defparameter +windows-reserved-names+
  '("con" "prn" "aux" "nul"
    "com1" "com2" "com3" "com4" "com5" "com6" "com7" "com8" "com9"
    "lpt1" "lpt2" "lpt3" "lpt4" "lpt5" "lpt6" "lpt7" "lpt8" "lpt9")
  "Device names Windows resolves BEFORE looking at the directory, so a file called `con`
is not a file. Checked without the extension, because `con.txt` is also the device.")

(defun sanitize-filename (name)
  "A filename safe to write to disk, from an arbitrary client-supplied NAME, or NIL if
nothing usable remains.

What it defends against, in order: a path (`../../etc/passwd`, `C:\\windows\\x`, or a
mixture) by keeping only the last segment after either separator; NUL and control bytes,
which truncate a path in C and confuse everything downstream; `.` and `..`, which are
directories rather than names; trailing dots and spaces, which Windows silently strips so
`evil.exe. ` becomes `evil.exe` after your check ran; and the Windows device names, which
resolve before the filesystem is consulted.

Returns NIL rather than a fallback like \"upload\" so the caller decides what an unusable
name means -- a generated name is the app's policy and often its primary key."
  (when name
    (let* ((base (let ((cut (position-if (lambda (c) (or (char= c #\/) (char= c #\\)))
                                         name :from-end t)))
                   (if cut (subseq name (1+ cut)) name)))
           (clean (remove-if (lambda (c) (let ((n (char-code c)))
                                           (or (< n 32) (= n 127))))
                             base))
           (trimmed (string-right-trim '(#\Space #\.) (string-trim " " clean))))
      (cond
        ((zerop (length trimmed)) nil)
        ((member trimmed '("." "..") :test #'string=) nil)
        ((member (let ((dot (position #\. trimmed)))
                   (string-downcase (if dot (subseq trimmed 0 dot) trimmed)))
                 +windows-reserved-names+ :test #'string=)
         (concatenate 'string "_" trimmed))
        (t trimmed)))))

;;; --- the streaming scanner -------------------------------------------------
;;;
;;; The body is consumed in chunks and never assembled whole. A delimiter can straddle a
;;; chunk boundary, so the scanner HOLDS BACK the last (1- delimiter-length) bytes before
;;; emitting: those bytes might be the start of a delimiter whose tail has not arrived. It
;;; is the one subtlety in the algorithm and the one that a test with a large chunk size
;;; will never catch, which is why the tests set it to 1.

(defstruct (scanner (:constructor %make-scanner) (:copier nil))
  (stream nil)
  (buffer (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
  (chunk 8192 :type fixnum)
  (eof nil)
  (consumed 0 :type unsigned-byte)
  (limit most-positive-fixnum :type unsigned-byte))

(defun %fill-scanner (sc)
  "Pull one chunk from the stream into the buffer. Returns NIL at end of input."
  (if (scanner-eof sc)
      nil
      (let* ((buf (scanner-buffer sc))
             (start (fill-pointer buf))
             (want (scanner-chunk sc)))
        (adjust-array buf (+ start want) :fill-pointer (+ start want))
        (let ((got (read-sequence buf (scanner-stream sc) :start start)))
          (setf (fill-pointer buf) got)
          (when (< got (+ start want)) (setf (scanner-eof sc) t))
          (incf (scanner-consumed sc) (- got start))
          ;; The ceiling is enforced HERE, as bytes arrive, not after the fact -- a body
          ;; with no Content-Length has no "after the fact".
          (when (> (scanner-consumed sc) (scanner-limit sc))
            (error 'multipart-too-large :limit (scanner-limit sc)))
          (> got start)))))

(defun %search-octets (needle haystack &key (start 0) (end (length haystack)))
  (search needle haystack :start2 start :end2 end))

(defun %scan-until (sc delim sink)
  "Feed bytes to SINK until DELIM is found; consume DELIM. Returns T, or NIL at end of
input without finding it."
  (let ((dlen (length delim)))
    (loop
      (let* ((buf (scanner-buffer sc))
             (hit (%search-octets delim buf)))
        (cond
          (hit
           (funcall sink buf 0 hit)
           (replace buf buf :start2 (+ hit dlen))
           (decf (fill-pointer buf) (+ hit dlen))
           (return t))
          (t
           ;; Emit everything that cannot be the head of a delimiter, keep the rest.
           (let ((safe (max 0 (- (fill-pointer buf) (1- dlen)))))
             (when (plusp safe)
               (funcall sink buf 0 safe)
               (replace buf buf :start2 safe)
               (decf (fill-pointer buf) safe)))
           (unless (%fill-scanner sc)
             (return nil))))))))

;;; --- where a part's bytes go ----------------------------------------------

(defstruct (sink (:constructor %make-sink) (:copier nil))
  (threshold 0 :type unsigned-byte)
  (memory (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
  (path nil)
  (stream nil)
  (size 0 :type unsigned-byte))

(defun %sink-write (sk buf start end)
  "Append BUF[START:END) to SK, spilling to a temp file once it outgrows the threshold."
  (let ((n (- end start)))
    (when (plusp n)
      (incf (sink-size sk) n)
      (cond
        ((sink-stream sk) (write-sequence buf (sink-stream sk) :start start :end end))
        ((<= (sink-size sk) (sink-threshold sk))
         (let ((mem (sink-memory sk)))
           (loop for i from start below end do (vector-push-extend (aref buf i) mem))))
        (t
         ;; Crossed the line: move what is already buffered to disk, then continue there.
         (let* ((path (uiop:tmpize-pathname
                       (merge-pathnames "hyperion-upload" (uiop:temporary-directory))))
                (out (open path :direction :output :element-type '(unsigned-byte 8)
                                :if-exists :supersede)))
           (setf (sink-path sk) path (sink-stream sk) out)
           (write-sequence (sink-memory sk) out)
           (setf (sink-memory sk) (make-array 0 :element-type '(unsigned-byte 8)
                                                :adjustable t :fill-pointer 0))
           (write-sequence buf out :start start :end end)))))))

(defun %sink-finish (sk)
  "Close SK. Returns (values bytes path size) -- one of bytes/path is NIL."
  (when (sink-stream sk) (close (sink-stream sk)) (setf (sink-stream sk) nil))
  (values (and (null (sink-path sk))
               (coerce (sink-memory sk) '(simple-array (unsigned-byte 8) (*))))
          (sink-path sk)
          (sink-size sk)))

;;; --- headers and the public entry -----------------------------------------

(defun %octets (string) (sb-ext:string-to-octets string :external-format :utf-8))

(defun %header-value-attribute (header attribute)
  "The value of ATTRIBUTE in a header like `form-data; name=\"x\"; filename=\"y.png\"`.
Handles the quoted and bare forms; returns NIL if absent."
  (let* ((needle (concatenate 'string attribute "="))
         (at (search needle header :test #'char-equal)))
    (when at
      (let ((rest (subseq header (+ at (length needle)))))
        (if (and (plusp (length rest)) (char= #\" (char rest 0)))
            (let ((close (position #\" rest :start 1)))
              (and close (subseq rest 1 close)))
            (subseq rest 0 (or (position #\; rest) (length rest))))))))

(defun %parse-part-headers (text)
  "The CRLF-separated header block of one part -> an alist of (name . value)."
  (loop for line in (uiop:split-string text :separator (list #\Newline))
        for clean = (string-right-trim '(#\Return) line)
        for colon = (position #\: clean)
        when (and colon (plusp (length clean)))
          collect (cons (string-downcase (string-trim " " (subseq clean 0 colon)))
                        (string-trim " " (subseq clean (1+ colon))))))

(defun multipart-p (env)
  "True when the Clack ENV is a multipart/form-data request carrying a boundary.
Check this before PARSE-MULTIPART; a urlencoded body is still FORM-ALIST's job."
  (let ((ct (or (getf env :content-type) "")))
    (and (search "multipart/form-data" ct :test #'char-equal)
         (%header-value-attribute ct "boundary")
         t)))

(defun delete-parts (parts)
  "Delete every temp file backing PARTS. Call it when done with an upload.

PARSE-MULTIPART already cleans up when it fails; this is for the successful case, where
the framework cannot know when the app has finished reading."
  (dolist (p parts parts)
    (when (part-path p)
      (ignore-errors (delete-file (part-path p)))
      (setf (part-path p) nil))))

(defun parse-multipart (env &key (max-size *max-body-size*) (max-parts *max-parts*)
                                 (memory-threshold *memory-threshold*)
                                 (chunk-size 8192))
  "Parse a multipart/form-data request body into a list of PARTs, in order.

Signals MULTIPART-TOO-LARGE past MAX-SIZE bytes, MULTIPART-TOO-MANY-PARTS past MAX-PARTS,
and MULTIPART-ERROR on a body that does not parse. All three ceilings default ON.

Streams: no part is held whole in memory, and a part over MEMORY-THRESHOLD spills to a temp
file (PART-PATH). CALL DELETE-PARTS when finished -- on failure this cleans up after itself,
but on success the app owns the files, because only the app knows when it has read them.

CHUNK-SIZE is exposed for tests: a delimiter straddling a chunk boundary is the one case
worth forcing, and a chunk size of 1 forces it everywhere.

RETURNS THE CACHED PARTS when a middleware has already parsed this body (see
+MULTIPART-PARTS-KEY+), in which case the ceilings above are NOT re-applied -- the parse
that produced them applied its own, and there is no second body to measure. A handler calls
this the same way whether or not anything upstream looked inside the body first."
  (let ((cached (getf env +multipart-parts-key+ :%unparsed)))
    (unless (eq cached :%unparsed)
      (return-from parse-multipart cached)))
  (let* ((ct (or (getf env :content-type) ""))
         (boundary (or (%header-value-attribute ct "boundary")
                       (error 'multipart-error :detail "no boundary in Content-Type")))
         (stream (or (getf env :raw-body)
                     (error 'multipart-error :detail "no request body")))
         (delim (%octets (concatenate 'string (string #\Return) (string #\Newline)
                                      "--" boundary)))
         (sc (%make-scanner :stream stream :chunk chunk-size :limit max-size))
         (parts '())
         ;; The part being streamed when something fails is NOT yet in PARTS, so cleaning
         ;; up PARTS alone orphans exactly the file most likely to exist: the big one that
         ;; spilled, in the upload that broke. Tracked separately for that reason.
         (in-flight nil)
         (ok nil))
    (unwind-protect
         (progn
           ;; The first boundary has no leading CRLF, so scan to "--boundary" and let the
           ;; loop below treat every subsequent one uniformly.
           (unless (%scan-until sc (%octets (concatenate 'string "--" boundary))
                                (lambda (b s e) (declare (ignore b s e))))
             (error 'multipart-error :detail "no opening boundary"))
           (loop
             (let ((buf (scanner-buffer sc)))
               ;; After a boundary: "--" ends the body, CRLF starts another part.
               (loop while (< (fill-pointer buf) 2)
                     do (unless (%fill-scanner sc)
                          (error 'multipart-error :detail "truncated after boundary")))
               (when (and (= (aref buf 0) (char-code #\-)) (= (aref buf 1) (char-code #\-)))
                 (return))
               (replace buf buf :start2 2)      ; drop the CRLF
               (decf (fill-pointer buf) 2))
             (when (>= (length parts) max-parts)
               (error 'multipart-too-many-parts :limit max-parts))
             ;; headers, then content up to the next delimiter
             (let ((head (make-array 0 :element-type '(unsigned-byte 8)
                                       :adjustable t :fill-pointer 0)))
               (unless (%scan-until sc (%octets (format nil "~C~C~C~C" #\Return #\Newline
                                                        #\Return #\Newline))
                                    (lambda (b s e)
                                      (loop for i from s below e
                                            do (vector-push-extend (aref b i) head))))
                 (error 'multipart-error :detail "truncated part headers"))
               (let* ((headers (%parse-part-headers
                                (sb-ext:octets-to-string
                                 (coerce head '(simple-array (unsigned-byte 8) (*)))
                                 :external-format :utf-8)))
                      (disposition (or (cdr (assoc "content-disposition" headers :test #'string=))
                                       ""))
                      (name (or (%header-value-attribute disposition "name")
                                (error 'multipart-error :detail "part without a name")))
                      (filename (%header-value-attribute disposition "filename"))
                      (sink (%make-sink :threshold memory-threshold)))
                 (setf in-flight sink)
                 (unless (%scan-until sc delim (lambda (b s e) (%sink-write sink b s e)))
                   (error 'multipart-error :detail "truncated part content"))
                 (setf in-flight nil)
                 (multiple-value-bind (bytes path size) (%sink-finish sink)
                   (push (%make-part :name name
                                     :filename filename
                                     :safe-filename (sanitize-filename filename)
                                     :content-type (cdr (assoc "content-type" headers
                                                               :test #'string=))
                                     :headers headers
                                     :bytes bytes :path path :size size)
                         parts)))))
           (setf ok t)
           (nreverse parts))
      ;; The error path. Anything already spilled is orphaned otherwise -- a temp file per
      ;; failed upload is a slow disk-fill that nobody attributes to uploads.
      (unless ok
        (when in-flight
          (ignore-errors (when (sink-stream in-flight) (close (sink-stream in-flight))))
          (ignore-errors (when (sink-path in-flight) (delete-file (sink-path in-flight)))))
        (delete-parts parts)))))

;;; --- reading parts the way a handler already reads fields -------------------

(defun find-parts (parts name)
  "Every part named NAME, in order. The multipart counterpart of FORM-PARAMS -- a file
input can repeat too (`<input type=file multiple>`)."
  (remove-if-not (lambda (p) (string= (part-name p) name)) parts))

(defun find-part (parts name)
  "The first part named NAME, or NIL."
  (first (find-parts parts name)))

(defun multipart-param (parts name)
  "The text of the first ordinary (non-file) field named NAME, or NIL.

The multipart counterpart of FORM-PARAM, so a handler mixing text fields and an upload
reads both the same way."
  (let ((p (find-if (lambda (p) (and (string= (part-name p) name) (not (part-file-p p))))
                    parts)))
    (and p (part-text p))))
