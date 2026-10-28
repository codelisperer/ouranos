;;;; http1.lisp --- one HTTP/1.1 exchange over a stream this client opened (#536).
;;;;
;;;; On Linux and macOS a pinned request hands its connection to dexador, which writes the
;;;; request and reads the response. On Windows dexador has no backend that takes a caller's
;;;; connection (its usocket backend is not loaded there), so the pinned path writes the request
;;;; and reads the response itself, with this file. It is compiled everywhere, so its tests run on
;;;; every platform, but only Windows' %REQUEST-PINNED uses it.
;;;;
;;;; THE RESPONSE IS UNTRUSTED INPUT. It comes from a server a user named, so every part of it is
;;;; read under a limit, and anything outside HTTP/1.1's grammar is refused with
;;;; MALFORMED-RESPONSE rather than guessed at:
;;;;   - the status line and each header line: at most +MAX-LINE-OCTETS+ (64 KiB: GitHub's
;;;;     Content-Security-Policy alone is longer than 8 KiB, and curl allows 100 KiB);
;;;;   - the whole head: at most +MAX-HEAD-OCTETS+ and +MAX-HEADER-FIELDS+ fields; no folded lines;
;;;;   - at most +MAX-INTERIM-RESPONSES+ 1xx responses before the real one;
;;;;   - framing: Transfer-Encoding must be exactly chunked; Transfer-Encoding together with
;;;;     Content-Length is refused, and so are Content-Length values that disagree or are not
;;;;     digits, since a response a proxy could frame two ways is how requests are smuggled;
;;;;   - a chunk size: hexadecimal, at most +MAX-CHUNK-SIZE-DIGITS+ digits, nothing but an
;;;;     extension after it; the trailer is limited like the head.
;;;; The body's total is limited by the caller, through %READ-CAPPED and MAX-BODY-BYTES, and a
;;;; read waits at most the socket's receive timeout, which the caller sets.
;;;;
;;;; The request asks for what this reader can read: Connection: close, so the body may end at
;;;; the close, and Accept-Encoding: identity, so nothing is compressed.

(in-package #:aion/http-client)

(define-condition malformed-response (http-error) ()
  (:documentation "A response that does not follow HTTP/1.1's grammar, or that passed one of
http1.lisp's limits, read on a pinned connection where this client reads the response itself."))

(defconstant +max-line-octets+ (* 64 1024)
  "The longest status line, header line or trailer line accepted, CRLF included.")
(defconstant +max-chunk-line-octets+ 1024
  "The longest chunk-size line accepted, CRLF and any extension included.")
(defconstant +max-head-octets+ (* 256 1024) "The most octets a response head may take.")
(defconstant +max-header-fields+ 256 "The most header fields one response head may carry.")
(defconstant +max-interim-responses+ 5 "The most 1xx responses read before the final one.")
(defconstant +max-chunk-size-digits+ 15
  "The most hexadecimal digits in a chunk size: 15 is below 2^60, so a size cannot overflow.")

(defun %malformed (fmt &rest args)
  (error 'malformed-response :detail (apply #'format nil fmt args)))

(defun %ended (fmt &rest args)
  "Signal MALFORMED-RESPONSE for a connection that ended before the response did, with phase
:RESPONSE. It ended after the connection was made and the request sent, so the server may have
acted on the request, and AION/RETRY must not resend it as if no connection had been made. On
Windows a read timeout on the socket also arrives here, as the end of the stream (#974)."
  (error 'malformed-response :detail (apply #'format nil fmt args) :phase :response))

;;; --- reading lines -------------------------------------------------------------------

(defun %read-line-octets (stream budget what)
  "One line from STREAM as a string of its octets (ISO-8859-1), without the line end. A line
ends with CRLF; a lone LF is accepted, as RFC 9112 allows a recipient to. Signals
MALFORMED-RESPONSE when the stream ends first, when a CR is not followed by LF, or when the
line is longer than BUDGET octets. Returns (values LINE OCTETS-READ)."
  (let ((line (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
        (n 0))
    (loop
      (let ((b (read-byte stream nil nil)))
        (unless b (%ended "the connection ended inside the ~A" what))
        (incf n)
        (when (> n budget) (%malformed "the ~A is longer than ~D octets" what budget))
        (cond ((= b 10) (return (values (coerce line 'simple-string) n)))
              ((= b 13)
               (let ((next (read-byte stream nil nil)))
                 (incf n)
                 (unless (eql next 10) (%malformed "a CR in the ~A is not followed by LF" what))
                 (return (values (coerce line 'simple-string) n))))
              (t (vector-push-extend (code-char b) line)))))))

(defun %token-char-p (c)
  "A tchar of RFC 9110: the characters a field name may hold. ASCII only: ALPHANUMERICP would
also accept letters such as an accented e, which a field name may not hold."
  (or (char<= #\a c #\z) (char<= #\A c #\Z) (char<= #\0 c #\9) (find c "!#$%&'*+-.^_`|~")))

(defun %parse-status-line (line)
  "The status code of the status line LINE, \"HTTP/1.x SSS reason\"."
  (unless (and (>= (length line) 12)
               (string= "HTTP/1." line :end2 7)
               (digit-char-p (char line 7))
               (char= #\Space (char line 8))
               (every #'digit-char-p (subseq line 9 12))
               (or (= (length line) 12) (char= #\Space (char line 12))))
    (%malformed "not an HTTP/1.x status line: ~S" (subseq line 0 (min 80 (length line)))))
  (parse-integer line :start 9 :end 12))

(defun %parse-field (line)
  "LINE, a header line, as (values NAME VALUE): NAME lowercased, VALUE without surrounding
spaces and tabs."
  (let ((colon (position #\: line)))
    (unless (and colon (plusp colon) (every #'%token-char-p (subseq line 0 colon)))
      (%malformed "not a header field: ~S" (subseq line 0 (min 80 (length line)))))
    (let ((value (string-trim '(#\Space #\Tab) (subseq line (1+ colon)))))
      ;; RFC 9110 field-vchar and obs-text: no control character but HTAB, and no DEL.
      (when (find-if (lambda (c) (let ((code (char-code c)))
                                   (or (and (< code 32) (char/= c #\Tab)) (= code 127))))
                     value)
        (%malformed "a header field's value holds a control character"))
      (values (string-downcase (subseq line 0 colon)) value))))

(defun %read-fields (stream what)
  "Header fields up to the empty line that ends them, as a hash table of lowercased names to
values, several values of one name joined with \", \" as dexador does. Limited to
+MAX-HEAD-OCTETS+ and +MAX-HEADER-FIELDS+."
  (let ((fields (make-hash-table :test 'equal))
        (count 0)
        (used 0))
    (loop
      (multiple-value-bind (line n)
          (%read-line-octets stream (min +max-line-octets+ (- +max-head-octets+ used)) what)
        (incf used n)
        (when (zerop (length line)) (return fields))
        (when (member (char line 0) '(#\Space #\Tab))
          (%malformed "a folded header line (obsolete line folding is refused)"))
        (when (> (incf count) +max-header-fields+)
          (%malformed "more than ~D header fields" +max-header-fields+))
        (multiple-value-bind (name value) (%parse-field line)
          (let ((old (gethash name fields)))
            (setf (gethash name fields) (if old (format nil "~A, ~A" old value) value))))))))

(defun read-response-head (stream)
  "Read a response's status line and header fields from STREAM, skipping up to
+MAX-INTERIM-RESPONSES+ 1xx responses. Returns (values STATUS FIELDS)."
  (loop repeat (1+ +max-interim-responses+)
        do (let ((status (%parse-status-line (%read-line-octets stream +max-line-octets+
                                                                "status line")))
                 (fields (%read-fields stream "response head")))
             (unless (<= 100 status 199)
               (return-from read-response-head (values status fields)))))
  (%malformed "more than ~D interim (1xx) responses" +max-interim-responses+))

;;; --- framing -------------------------------------------------------------------------

(defun %content-length-of (value)
  "The length a Content-Length field VALUE gives, or MALFORMED-RESPONSE. Several values, as
\"5, 5\" when the field was sent twice, must all be the same."
  (let ((parts (mapcar (lambda (s) (string-trim '(#\Space #\Tab) s))
                       (uiop:split-string value :separator ","))))
    (dolist (p parts)
      (unless (and (plusp (length p)) (<= (length p) 18) (every #'digit-char-p p))
        (%malformed "a Content-Length that is not a number: ~S" value)))
    (let ((lengths (remove-duplicates (mapcar #'parse-integer parts))))
      (when (rest lengths) (%malformed "Content-Length values that disagree: ~S" value))
      (first lengths))))

(defun response-framing (method status fields)
  "How the body of a response to METHOD with STATUS and FIELDS is delimited: :NONE, (:LENGTH n),
:CHUNKED or :CLOSE. Refuses what a recipient must not guess at (see the file's header)."
  (let ((te (gethash "transfer-encoding" fields))
        (cl (gethash "content-length" fields)))
    (when (and te cl)
      (%malformed "both Transfer-Encoding and Content-Length (a response framed two ways)"))
    (cond ((or (eq method :head) (= status 204) (= status 304)) :none)
          (te (unless (string-equal (string-trim '(#\Space #\Tab) te) "chunked")
                (%malformed "a Transfer-Encoding other than chunked: ~S" te))
              :chunked)
          (cl (list :length (%content-length-of cl)))
          (t :close))))

;;; --- the body as a stream ------------------------------------------------------------

(defclass %body-stream (sb-gray:fundamental-binary-input-stream)
  ((source :initarg :source :reader %source)
   (closer :initarg :closer :reader %closer)
   (closed :initform nil :accessor %closed))
  (:documentation "A response body read from SOURCE as it is framed. CLOSE runs CLOSER, which
closes the connection."))

(defmethod stream-element-type ((s %body-stream)) '(unsigned-byte 8))

(defmethod close ((s %body-stream) &key abort)
  (declare (ignore abort))
  (unless (%closed s)
    (setf (%closed s) t)
    (funcall (%closer s)))
  t)

(defclass %length-body (%body-stream)
  ((left :initarg :left :accessor %left)))

(defmethod sb-gray:stream-read-byte ((s %length-body))
  (if (zerop (%left s))
      :eof
      (let ((b (read-byte (%source s) nil nil)))
        (unless b (%ended "the connection ended ~D octets before the Content-Length" (%left s)))
        (decf (%left s))
        b)))

(defclass %close-body (%body-stream) ())

(defmethod sb-gray:stream-read-byte ((s %close-body))
  (or (read-byte (%source s) nil nil) :eof))

(defclass %chunked-body (%body-stream)
  ((left :initform 0 :accessor %left)
   (done :initform nil :accessor %done)
   (started :initform nil :accessor %started)))

(defun %chunk-size (line)
  "The size a chunk-size LINE gives: hexadecimal digits, then nothing or a ;extension."
  (let* ((end (or (position #\; line) (length line)))
         (digits (string-right-trim '(#\Space #\Tab) (subseq line 0 end))))
    (unless (and (plusp (length digits))
                 (<= (length digits) +max-chunk-size-digits+)
                 (every (lambda (c) (digit-char-p c 16)) digits))
      (%malformed "not a chunk size: ~S" (subseq line 0 (min 40 (length line)))))
    (parse-integer digits :radix 16)))

(defun %next-chunk (s)
  "Read the next chunk-size line, after the previous chunk's CRLF. At the last chunk, read the
trailer and mark S done."
  (let ((src (%source s)))
    (when (%started s)
      (let ((line (%read-line-octets src 2 "chunk")))
        (unless (zerop (length line)) (%malformed "a chunk is longer than its size says"))))
    (setf (%started s) t)
    (let ((size (%chunk-size (%read-line-octets src +max-chunk-line-octets+ "chunk-size line"))))
      (if (zerop size)
          (progn (%read-fields src "chunked trailer") (setf (%done s) t))
          (setf (%left s) size)))))

(defmethod sb-gray:stream-read-byte ((s %chunked-body))
  (loop
    (when (%done s) (return :eof))
    (when (plusp (%left s))
      (let ((b (read-byte (%source s) nil nil)))
        (unless b (%ended "the connection ended inside a chunk"))
        (decf (%left s))
        (return b)))
    (%next-chunk s)))

(defun response-body-stream (source framing closer)
  "A binary input stream of the body framed by FRAMING (see RESPONSE-FRAMING) on SOURCE. Its
CLOSE calls CLOSER."
  (etypecase framing
    ((eql :none) (make-instance '%length-body :source source :closer closer :left 0))
    ((eql :close) (make-instance '%close-body :source source :closer closer))
    ((eql :chunked) (make-instance '%chunked-body :source source :closer closer))
    (cons (make-instance '%length-body :source source :closer closer :left (second framing)))))

;;; --- writing the request -------------------------------------------------------------

(defun %field-safe (string what)
  (when (find-if (lambda (c) (or (char= c #\Return) (char= c #\Newline) (char= c (code-char 0))))
                 string)
    (error 'http-error :detail (format nil "the request's ~A holds a CR, LF or NUL" what)))
  string)

(defun %content-octets (content)
  "CONTENT as (values OCTETS DEFAULT-CONTENT-TYPE): a string as UTF-8, octets as they are, and
an alist form-encoded, as dexador does."
  (etypecase content
    (null (values nil nil))
    (string (values (sb-ext:string-to-octets content :external-format :utf-8) nil))
    ((array (unsigned-byte 8) (*)) (values (coerce content '(simple-array (unsigned-byte 8) (*))) nil))
    (list (values (sb-ext:string-to-octets (quri:url-encode-params content) :external-format :utf-8)
                  "application/x-www-form-urlencoded"))))

(defun %encode-target (string)
  "STRING with every character outside 0x21-0x7E percent-encoded as its UTF-8 octets: a space,
a TAB, a control character, DEL and anything beyond ASCII. A URL from a server or a redirect can
hold any of them, and written as it is a space splits the request line for a proxy, octets
0x80-0xFF go out as raw Latin-1, and a character above U+00FF cannot be written at all (the hub's
review of #913). Characters already percent-encoded, and every other printable ASCII character,
are left as they are."
  (with-output-to-string (out)
    (loop for c across string
          for code = (char-code c)
          do (if (<= #x21 code #x7E)
                 (write-char c out)
                 (loop for b across (sb-ext:string-to-octets (string c) :external-format :utf-8)
                       do (format out "%~2,'0X" b))))))

(defun %host-safe (host)
  "HOST, refused unless every character is printable ASCII (0x21-0x7E). A host name is ASCII
(an internationalised one is sent in its A-label form), so anything else is not a host."
  (unless (and (plusp (length host)) (every (lambda (c) (<= #x21 (char-code c) #x7E)) host))
    (error 'http-error :detail (format nil "not a host name for the Host field: ~S" host)))
  host)

(defun write-request (stream method uri headers content)
  "Write an HTTP/1.1 request for METHOD on URI (a QURI:URI) with HEADERS, an alist, and CONTENT
to the binary STREAM, and force it out. Host is the URI's host (and port when it is not the
scheme's default). Connection: close and Accept-Encoding: identity are always sent, and a
caller's own values for those, for Host and for Content-Length are not."
  (multiple-value-bind (body default-type) (%content-octets content)
    (let* ((path (let ((p (or (quri:uri-path uri) "")) (q (quri:uri-query uri)))
                   (%encode-target (format nil "~A~@[?~A~]" (if (string= p "") "/" p) q))))
           (port (quri:uri-port uri))
           (default-port (if (string-equal (quri:uri-scheme uri) "https") 443 80))
           (host (if (and port (/= port default-port))
                     (format nil "~A:~D" (quri:uri-host uri) port)
                     (quri:uri-host uri)))
           (skip '("host" "connection" "accept-encoding" "content-length" "transfer-encoding"))
           ;; Newest first, and reversed when written: the request line comes out first.
           (lines (list (format nil "Host: ~A" (%host-safe host))
                        (format nil "~A ~A HTTP/1.1" (string-upcase (symbol-name method))
                                (%field-safe path "path")))))
      (dolist (h headers)
        (let ((name (string (car h))))
          (unless (member name skip :test #'string-equal)
            (unless (and (plusp (length name)) (every #'%token-char-p name))
              (error 'http-error :detail (format nil "not a header name: ~S" name)))
            (push (format nil "~A: ~A" name (%field-safe (princ-to-string (cdr h)) name)) lines))))
      (when (and default-type
                 (not (find "content-type" headers :key (lambda (h) (string (car h)))
                                                   :test #'string-equal)))
        (push (format nil "Content-Type: ~A" default-type) lines))
      (when body (push (format nil "Content-Length: ~D" (length body)) lines))
      (push "Connection: close" lines)
      (push "Accept-Encoding: identity" lines)
      (let ((head (format nil "~{~A~C~C~}~C~C"
                          (loop for l in (reverse lines) append (list l #\Return #\Newline))
                          #\Return #\Newline)))
        (write-sequence (sb-ext:string-to-octets head :external-format :latin-1) stream))
      (when body (write-sequence body stream))
      (force-output stream))))

(defun http1-exchange (stream method uri headers content &key closer)
  "Send one request on the binary STREAM and read the response head. Returns (values BODY STATUS
FIELDS): BODY is a binary input stream of the body, framed as the response says, whose CLOSE
calls CLOSER; FIELDS is a hash table as dexador returns."
  (write-request stream method uri headers content)
  (multiple-value-bind (status fields) (read-response-head stream)
    (values (response-body-stream stream (response-framing method status fields)
                                  (or closer (lambda () nil)))
            status fields)))
