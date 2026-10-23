;;;; s3.lisp --- the S3-compatible blob backend.
;;;;
;;;; ONE backend covers every managed provider an app is likely to meet -- AWS S3,
;;;; DigitalOcean Spaces, Cloudflare R2, Backblaze B2, Wasabi, and MinIO locally -- because
;;;; they all speak the same REST dialect and the same SigV4 signature. What differs is the
;;;; endpoint, the region string and whether the bucket is a subdomain or a path prefix,
;;;; and those are configuration rather than code.
;;;;
;;;; Signing is implemented here in CL and not in the Coalton core. It is pure string work
;;;; and the temptation to type it is real, but mnemosyne's own precedent settles it: the
;;;; SQL builder (query.lisp), the DDL emitter (ddl.lisp) and the SQL parser (parse.lisp)
;;;; are all CL, because serializing to somebody else's wire format is shell work. What
;;;; belongs in the typed core is the VOCABULARY -- which is why the key rules and the
;;;; private/public distinction are in blob-key.lisp and this file has neither.

(cl:in-package #:hermes/blob)

(defclass s3-store (store)
  ((endpoint :initarg :endpoint :reader s3-endpoint
             :documentation "Host, no scheme -- e.g. \"s3.amazonaws.com\", \"nyc3.digitaloceanspaces.com\".")
   (region :initarg :region :initform "us-east-1" :reader s3-region)
   (access-key :initarg :access-key :reader s3-access-key)
   (secret-key :initarg :secret-key :reader s3-secret-key)
   (session-token :initarg :session-token :initform nil :reader s3-session-token)
   (secure :initarg :secure :initform t :reader s3-secure-p)
   (path-style :initarg :path-style :initform nil :reader s3-path-style-p
               :documentation
               "Address the bucket as a PATH (endpoint/bucket/key) rather than as a
subdomain (bucket.endpoint/key). MinIO and most local test doubles need this; AWS prefers
virtual-host style.")
   (public-base-url :initarg :public-base-url :initform nil :reader s3-public-base-url)
   (upload-acl :initarg :upload-acl :initform :none :reader s3-upload-acl
               :documentation
               ":NONE or :PRIVATE: whether UPLOAD-URL signs `x-amz-acl: private' (#796). See
MAKE-S3-STORE."))
  (:documentation "A blob store on any S3-compatible object store."))

(defun %require-setting (value name)
  (if (and value (plusp (length value)))
      value
      (error 'blob-configuration-error :missing name)))

(defun make-s3-store (&key endpoint region access-key secret-key session-token
                           (secure t) path-style public-base-url upload-acl)
  "An S3-STORE, defaulting every setting from the environment.

ENDPOINT is MNEMOSYNE_S3_ENDPOINT (default \"s3.amazonaws.com\"), REGION is MNEMOSYNE_S3_REGION
(default \"us-east-1\"), ACCESS-KEY and SECRET-KEY are MNEMOSYNE_S3_ACCESS_KEY and
MNEMOSYNE_S3_SECRET_KEY, SESSION-TOKEN is MNEMOSYNE_S3_SESSION_TOKEN, PATH-STYLE is
MNEMOSYNE_S3_PATH_STYLE=true and PUBLIC-BASE-URL is MNEMOSYNE_S3_PUBLIC_BASE_URL.
UPLOAD-ACL is :NONE (the default) or :PRIVATE, or MNEMOSYNE_S3_UPLOAD_ACL: whether UPLOAD-URL
signs `x-amz-acl: private'. Set :PRIVATE for a bucket that honours ACLs, such as DigitalOcean
Spaces or an AWS bucket with ACLs enabled, and leave :NONE for an AWS bucket with ACLs disabled
or Cloudflare R2; see %UPLOAD-ACL-SETTING (#796).

Credentials are checked HERE rather than at first use, so a deploy missing a secret dies
at boot with the variable's name instead of on the first upload a member attempts."
  (let ((endpoint (or endpoint (uiop:getenv "MNEMOSYNE_S3_ENDPOINT") "s3.amazonaws.com"))
        (region (or region (uiop:getenv "MNEMOSYNE_S3_REGION") "us-east-1"))
        (access-key (or access-key (uiop:getenv "MNEMOSYNE_S3_ACCESS_KEY")))
        (secret-key (or secret-key (uiop:getenv "MNEMOSYNE_S3_SECRET_KEY"))))
    (make-instance 's3-store
                   :endpoint (%require-setting endpoint "MNEMOSYNE_S3_ENDPOINT")
                   :region region
                   :access-key (%require-setting access-key "MNEMOSYNE_S3_ACCESS_KEY")
                   :secret-key (%require-setting secret-key "MNEMOSYNE_S3_SECRET_KEY")
                   :session-token (or session-token (uiop:getenv "MNEMOSYNE_S3_SESSION_TOKEN"))
                   :secure secure
                   :path-style (or path-style
                                   (let ((v (uiop:getenv "MNEMOSYNE_S3_PATH_STYLE")))
                                     (and v (string-equal v "true"))))
                   :public-base-url (or public-base-url
                                        (uiop:getenv "MNEMOSYNE_S3_PUBLIC_BASE_URL"))
                   :upload-acl (%upload-acl-setting upload-acl))))

(defun %upload-acl-setting (value)
  "The store's UPLOAD-ACL: VALUE when given, else MNEMOSYNE_S3_UPLOAD_ACL, else :NONE.

:PRIVATE makes UPLOAD-URL sign `x-amz-acl: private', so a client cannot ask for a public
object. Set it for a bucket that honours ACLs, such as DigitalOcean Spaces or an AWS bucket
with ACLs enabled. Leave it :NONE for an AWS bucket with ACLs disabled, the default for a new
AWS bucket, which refuses an upload naming `private' with 400 AccessControlListNotSupported,
and for Cloudflare R2, which does not implement the header (the maintainer's ruling on #796)."
  (let ((value (or value
                   (let ((v (uiop:getenv "MNEMOSYNE_S3_UPLOAD_ACL")))
                     (and v (plusp (length v))
                          (cond ((string-equal v "private") :private)
                                ((string-equal v "none") :none)
                                (t v))))
                   :none)))
    (unless (member value '(:none :private))
      (error 'blob-configuration-error
             :missing (format nil "MNEMOSYNE_S3_UPLOAD_ACL or :upload-acl must be private or none, not ~S"
                              value)))
    value))

(register-store "s3" #'make-s3-store)

(defmethod store-name ((s s3-store)) "s3")

;;; --- SigV4 primitives ------------------------------------------------------

(defun %octets (string)
  (sb-ext:string-to-octets string :external-format :utf-8))

(defun %sha256-hex (data)
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence :sha256 (if (stringp data) (%octets data) data))))

(defun %hmac-sha256 (key data)
  (let ((h (ironclad:make-hmac key :sha256)))
    (ironclad:update-hmac h (if (stringp data) (%octets data) data))
    (ironclad:hmac-digest h)))

(defun %uri-encode (string &key (encode-slash t))
  "Percent-encode STRING per AWS's rules.

NOT the same as generic URL encoding, and the difference is the classic source of
signature-mismatch bugs: AWS leaves `-' `_' `.' and `~' alone, encodes EVERYTHING else
including space (as %20, never `+'), and uses UPPERCASE hex. ENCODE-SLASH is NIL for the
canonical URI, where path separators must survive, and T for query values."
  (with-output-to-string (out)
    (loop for byte across (%octets string)
          for ch = (code-char byte)
          do (cond ((or (char<= #\A ch #\Z) (char<= #\a ch #\z) (char<= #\0 ch #\9)
                        (find ch "-_.~"))
                    (write-char ch out))
                   ((and (eql ch #\/) (not encode-slash))
                    (write-char ch out))
                   (t (format out "%~2,'0X" byte))))))

(defun %amz-dates (&optional (universal-time (get-universal-time)))
  "(values \"YYYYMMDDTHHMMSSZ\" \"YYYYMMDD\") in UTC."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time universal-time 0)
    (values (format nil "~4,'0D~2,'0D~2,'0DT~2,'0D~2,'0D~2,'0DZ" year month day hour min sec)
            (format nil "~4,'0D~2,'0D~2,'0D" year month day))))

(defun %credential-scope (date region)
  (format nil "~A/~A/s3/aws4_request" date region))

(defun %signing-key (secret date region)
  "The derived key: HMAC chained over date, region, service, terminator."
  (let* ((k (%hmac-sha256 (%octets (concatenate 'string "AWS4" secret)) date))
         (k (%hmac-sha256 k region))
         (k (%hmac-sha256 k "s3")))
    (%hmac-sha256 k "aws4_request")))

(defun %canonical-query (params)
  "PARAMS (an alist of string.string) encoded and sorted by key, as SigV4 requires."
  (let ((sorted (sort (copy-list params) #'string< :key #'car)))
    (format nil "~{~A~^&~}"
            (mapcar (lambda (p) (format nil "~A=~A" (%uri-encode (car p)) (%uri-encode (cdr p))))
                    sorted))))

(defun %string-to-sign (amz-date scope canonical-request)
  (format nil "AWS4-HMAC-SHA256~%~A~%~A~%~A" amz-date scope (%sha256-hex canonical-request)))

;;; --- addressing ------------------------------------------------------------

(defun %s3-host (store bucket)
  (if (s3-path-style-p store)
      (s3-endpoint store)
      (format nil "~A.~A" bucket (s3-endpoint store))))

(defun %s3-path (store bucket key)
  "The canonical URI path -- always starting with `/', with the key encoded but its
separators intact."
  (if (s3-path-style-p store)
      (format nil "/~A/~A" bucket (%uri-encode key :encode-slash nil))
      (format nil "/~A" (%uri-encode key :encode-slash nil))))

(defun %s3-url (store bucket key &optional query)
  (format nil "~A://~A~A~@[?~A~]"
          (if (s3-secure-p store) "https" "http")
          (%s3-host store bucket)
          (if (and (null key) (s3-path-style-p store))
              (format nil "/~A" bucket)
              (if (null key) "/" (%s3-path store bucket key)))
          query))

;;; --- signed requests -------------------------------------------------------

(defun %signed-headers (store bucket key method &key (payload-hash "UNSIGNED-PAYLOAD")
                                                     (query "") extra-headers)
  "The header alist for a signed request, Authorization included.

Payload hash defaults to UNSIGNED-PAYLOAD: over HTTPS the transport already protects the
body, and requiring a hash would mean reading the whole object before sending a byte of
it. PUT-BLOB passes the real hash anyway, because it has spooled the object and therefore
knows it for free."
  (multiple-value-bind (amz-date date) (%amz-dates)
    (let* ((host (%s3-host store bucket))
           (path (if key (%s3-path store bucket key)
                     (if (s3-path-style-p store) (format nil "/~A" bucket) "/")))
           (base-headers (append (list (cons "host" host)
                                       (cons "x-amz-content-sha256" payload-hash)
                                       (cons "x-amz-date" amz-date))
                                 (when (s3-session-token store)
                                   (list (cons "x-amz-security-token"
                                               (s3-session-token store))))
                                 extra-headers))
           (sorted (sort (copy-list base-headers) #'string< :key #'car))
           (canonical-headers (format nil "~{~A~}"
                                      (mapcar (lambda (h)
                                                (format nil "~A:~A~%"
                                                        (string-downcase (car h))
                                                        (string-trim " " (cdr h))))
                                              sorted)))
           (signed-list (format nil "~{~A~^;~}"
                                (mapcar (lambda (h) (string-downcase (car h))) sorted)))
           (canonical-request (format nil "~A~%~A~%~A~%~A~%~A~%~A"
                                      method path query canonical-headers
                                      signed-list payload-hash))
           (scope (%credential-scope date (s3-region store)))
           (signature (ironclad:byte-array-to-hex-string
                       (%hmac-sha256 (%signing-key (s3-secret-key store) date
                                                   (s3-region store))
                                     (%string-to-sign amz-date scope canonical-request)))))
      (append base-headers
              (list (cons "Authorization"
                          (format nil "AWS4-HMAC-SHA256 Credential=~A/~A, SignedHeaders=~A, Signature=~A"
                                  (s3-access-key store) scope signed-list signature)))))))

(defconstant +max-error-body-bytes+ 65536
  "The most of an error response's body kept as a condition's DETAIL. An S3 error document is a
few hundred bytes; this bounds what a misbehaving store or proxy can make the image hold.")

(defun %error-body (body)
  "BODY as an error response's DETAIL. A stream is read up to +MAX-ERROR-BODY-BYTES+ and closed;
anything else is returned as it is.

Never signals. It runs inside %S3-REQUEST's handler for an HTTP error, where an error from
reading or closing the stream would escape as itself rather than as BLOB-BACKEND-ERROR, so a
body that cannot be read becomes a DETAIL saying so (#796)."
  (if (streamp body)
      (handler-case
          (unwind-protect
               (let* ((buffer (make-array +max-error-body-bytes+ :element-type '(unsigned-byte 8)))
                      (n (read-sequence buffer body)))
                 (subseq buffer 0 n))
            (ignore-errors (close body :abort t)))
        (error (e)
          (format nil "the error response's body could not be read: ~A" e)))
      body))

(defun %s3-request (store bucket key method &key content content-type query
                                                 payload-hash extra-headers want-stream)
  "Perform a signed S3 request, translating transport failure into the blob protocol."
  (let* ((headers (%signed-headers store bucket key method
                                   :payload-hash (or payload-hash "UNSIGNED-PAYLOAD")
                                   :query (or query "")
                                   :extra-headers
                                   (append (when content-type
                                             (list (cons "content-type" content-type)))
                                           extra-headers)))
         (url (%s3-url store bucket key (and query (plusp (length query)) query))))
    (multiple-value-bind (body status resp-headers)
        (handler-case
            (dex:request url :method method :headers headers :content content
                             :want-stream want-stream :force-binary t
                             :keep-alive nil)
          (dex:http-request-failed (e)
            (let ((status (dex:response-status e))
                  ;; With WANT-STREAM the error's body is an open stream on the connection.
                  ;; Read what is needed of it and close it here, or a ranged read past the end
                  ;; (416) holds its socket until the stream is garbage-collected (#796).
                  (detail (%error-body (dex:response-body e))))
              (if (member status '(403 404))
                  ;; 403 is folded into NOT-FOUND deliberately: a bucket configured to
                  ;; deny listing answers a missing key with 403, and a caller asking
                  ;; "is this photo there" must not have to know which policy the bucket
                  ;; happens to run to read the answer.
                  (error 'blob-not-found :bucket bucket :key key)
                  (error 'blob-backend-error :bucket bucket :key key :status status
                                             :detail detail))))
          (error (e)
            (error 'blob-backend-error :bucket bucket :key key
                                       :detail (princ-to-string e))))
      (values body status resp-headers))))

;;; --- operations ------------------------------------------------------------

(defmethod put-blob ((s s3-store) bucket key stream &key content-type metadata cache-control)
  ;; Spool to a temp file first. S3 needs Content-Length and (for a signed payload) the
  ;; body's SHA-256 BEFORE the first byte goes out, and neither is knowable from a stream
  ;; without reading it. Spooling is how we get both while still never holding the object
  ;; in memory -- the alternative, buffering it into a vector, is the exact failure this
  ;; module exists to avoid.
  ;; Default the type ONCE, and report the same value we sent. Defaulting at the request
  ;; and returning the caller's raw argument made the BLOB-META a lie whenever CONTENT-TYPE
  ;; was NIL -- it said "unknown" while the stored object was octet-stream, so the meta a
  ;; caller wrote into a row disagreed with what a later BLOB-METADATA would read back.
  (let ((content-type (or content-type "application/octet-stream")))
    (uiop:with-temporary-file (:stream out :pathname tmp :element-type '(unsigned-byte 8)
                               :direction :output :keep t)
      (multiple-value-bind (size checksum) (%copy-stream-with-digest stream out)
        (finish-output out)
        (close out)
        (unwind-protect
             (progn
               (%s3-request s bucket key :put
                            :content tmp
                            :content-type content-type
                            :payload-hash checksum
                            :extra-headers
                            ;; The checksum is stored with the object, so BLOB-METADATA can report
                            ;; it later. Before #810 it was only sent as the payload hash, and
                            ;; BLOB-METADATA returned NIL for every blob. "sha256" is reserved, so
                            ;; the app's METADATA cannot send a second one.
                            (append
                             (list (cons "x-amz-meta-sha256" checksum))
                             (when cache-control (list (cons "cache-control" cache-control)))
                             (loop for (mk . mv) in metadata
                                   collect (cons (format nil "x-amz-meta-~A" (string-downcase mk))
                                                 mv))))
               (log:debug "blob put" :backend "s3" :bucket bucket :bytes size)
               (make-blob-meta key size content-type checksum (get-universal-time)))
          (uiop:delete-file-if-exists tmp))))))

(defmethod get-blob ((s s3-store) bucket key)
  ;; VALUES of one, deliberately. %S3-REQUEST also returns the status and the response
  ;; headers, and letting them through here would make the S3 backend's GET-BLOB a
  ;; different function from the filesystem's -- a caller doing (values (get-blob ...))
  ;; or passing it on would silently get extra values from one backend and not the other.
  ;; The protocol says "an octet input stream"; that is what comes back.
  (values (%s3-request s bucket key :get :want-stream t)))

(defmethod delete-blob ((s s3-store) bucket key)
  ;; S3 answers 204 for a key that was never there, so this is already idempotent; the
  ;; handler covers a bucket policy that turns the same case into a 404.
  (handler-case (progn (%s3-request s bucket key :delete) t)
    (blob-not-found () t)))

(defmethod blob-exists-p ((s s3-store) bucket key)
  (handler-case (progn (%s3-request s bucket key :head) t)
    (blob-not-found () nil)))

(defparameter +http-months+
  '("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")
  "Month names as an HTTP date writes them.")

(defun %parse-http-date (text)
  "An HTTP date as S3 sends Last-Modified (\"Wed, 21 Oct 2015 07:28:00 GMT\", RFC 7231's
IMF-fixdate) as a universal time, or NIL when TEXT is not one."
  (ignore-errors
   (let* ((parts (remove "" (uiop:split-string text :separator " ") :test #'string=))
          (day (parse-integer (second parts)))
          (month (1+ (position (third parts) +http-months+ :test #'string=)))
          (year (parse-integer (fourth parts)))
          (hms (mapcar #'parse-integer (uiop:split-string (fifth parts) :separator ":"))))
     (and (= 6 (length parts)) (string= "GMT" (sixth parts)) (= 3 (length hms))
          (encode-universal-time (third hms) (second hms) (first hms) day month year 0)))))

(defun %meta-from-headers (key headers)
  "The BLOB-META a HEAD or GET of KEY answered with HEADERS describes (#826)."
  (flet ((hdr (name) (gethash name headers)))
    (make-blob-meta key
                    (or (ignore-errors (parse-integer (or (hdr "content-length") "0"))) 0)
                    (hdr "content-type")
                    ;; The ETag is the MD5 for a single-part upload and something else
                    ;; entirely for a multipart one, so it is NOT our SHA-256 checksum.
                    ;; Report the checksum PUT-BLOB recorded, or nothing: an object stored
                    ;; before #810, or uploaded directly by a client, has none.
                    (hdr "x-amz-meta-sha256")
                    (let ((lm (hdr "last-modified"))) (and (stringp lm) (%parse-http-date lm)))
                    (let ((etag (hdr "etag"))) (and etag (string-trim "\"" etag))))))

(defmethod blob-metadata ((s s3-store) bucket key)
  (multiple-value-bind (body status headers) (%s3-request s bucket key :head)
    (declare (ignore body status))
    (%meta-from-headers key headers)))

(defun %if-match-headers (if-match)
  "The If-Match header for IF-MATCH, an ETag with or without its quotes, or NIL."
  (when if-match
    (list (cons "if-match" (format nil "\"~A\"" (string-trim "\"" if-match))))))

(defmethod open-blob ((s s3-store) bucket key &key if-match)
  ;; One GET carrying If-Match, so the check and the read are the same request: S3 answers 412,
  ;; and sends nothing, when the object's ETag is not IF-MATCH.
  (multiple-value-bind (body status headers)
      (handler-case (%s3-request s bucket key :get :want-stream t
                                                   :extra-headers (%if-match-headers if-match))
        (blob-backend-error (e)
          (if (eql 412 (blob-backend-error-status e))
              (error 'blob-precondition-failed :bucket bucket :key key)
              (error e))))
    (declare (ignore status))
    (values body (%meta-from-headers key headers))))

(defun %presign (&key method host path access-key secret-key session-token region
                      amz-date date expires-in headers query-params)
  "A query-signed SigV4 URL's path and query, as (values path-and-query canonical-request).

PURE: every input is an argument, the clock included (AMZ-DATE and DATE), so it can be checked
against AWS's published example rather than only for shape (#770). HEADERS is an alist of the
headers the client will send besides host, such as content-type and content-length; each one
is signed, so the provider refuses the request if the client sends a different value.
QUERY-PARAMS is an alist of further query parameters, signed with the rest: a multipart part's
partNumber and uploadId, so a part URL cannot be pointed at another part or upload."
  (let* ((scope (%credential-scope date region))
         (all-headers (sort (cons (cons "host" host)
                                  (mapcar (lambda (h) (cons (string-downcase (car h)) (cdr h))) headers))
                            #'string< :key #'car))
         (signed-list (format nil "~{~A~^;~}" (mapcar #'car all-headers)))
         (params (append (list (cons "X-Amz-Algorithm" "AWS4-HMAC-SHA256")
                               (cons "X-Amz-Credential" (format nil "~A/~A" access-key scope))
                               (cons "X-Amz-Date" amz-date)
                               (cons "X-Amz-Expires" (princ-to-string expires-in))
                               (cons "X-Amz-SignedHeaders" signed-list))
                         (when session-token
                           (list (cons "X-Amz-Security-Token" session-token)))
                         query-params))
         (query (%canonical-query params))
         (canonical-headers (format nil "~{~A~}"
                                    (mapcar (lambda (h) (format nil "~A:~A~%" (car h) (string-trim " " (cdr h))))
                                            all-headers)))
         (canonical-request (format nil "~A~%~A~%~A~%~A~%~A~%UNSIGNED-PAYLOAD"
                                    method path query canonical-headers signed-list))
         (signature (ironclad:byte-array-to-hex-string
                     (%hmac-sha256 (%signing-key secret-key date region)
                                   (%string-to-sign amz-date scope canonical-request)))))
    (values (format nil "~A?~A&X-Amz-Signature=~A" path query signature)
            canonical-request)))

(defun %presigned-url (store bucket key method expires-in &key headers query-params
                                                                 (universal-time (get-universal-time)))
  "A presigned URL for METHOD on BUCKET/KEY, valid for EXPIRES-IN seconds from UNIVERSAL-TIME."
  (multiple-value-bind (amz-date date) (%amz-dates universal-time)
    (format nil "~A://~A~A"
            (if (s3-secure-p store) "https" "http")
            (%s3-host store bucket)
            (%presign :method method :host (%s3-host store bucket) :path (%s3-path store bucket key)
                      :access-key (s3-access-key store) :secret-key (s3-secret-key store)
                      :session-token (s3-session-token store) :region (s3-region store)
                      :amz-date amz-date :date date :expires-in expires-in :headers headers
                      :query-params query-params))))

(defmethod blob-url ((s s3-store) bucket key &key expires-in)
  (if (null expires-in)
      (let ((base (s3-public-base-url s)))
        (unless (and base (plusp (length base)))
          (error 'blob-unsupported :bucket bucket :key key
                                   :operation "unsigned URLs (no public base URL configured)"))
        (let ((sep (if (eql #\/ (char base (1- (length base)))) "" "/")))
          (format nil "~A~A~A" base sep (%uri-encode key :encode-slash nil))))
      (%presigned-url s bucket key "GET" expires-in)))

(defconstant +max-single-put-bytes+ (* 5 1024 1024 1024)
  "5 GiB, the largest object S3 accepts in a single PUT. Larger files need a multipart upload.")

(defun %upload-acl-headers (store)
  "The x-amz-acl header UPLOAD-URL signs on STORE, as an alist: one entry or none."
  (when (eq (s3-upload-acl store) :private)
    (list (cons "x-amz-acl" "private"))))

(defmethod upload-url ((s s3-store) bucket key &key expires-in content-type content-length max-bytes)
  ;; A presigned PUT. Content-Type and Content-Length are SIGNED when given, so S3 refuses a
  ;; request whose values differ: the type cannot be swapped, and with the length signed the
  ;; size cap checked in the :BEFORE method holds for the bytes that arrive (#770).
  (when (and content-length (> content-length +max-single-put-bytes+))
    (error 'blob-upload-refused :bucket bucket :key key :reason :too-large-for-single-put
                                :size content-length :limit +max-single-put-bytes+))
  ;; Trimmed here, once, so the value returned in the target's headers is the value signed:
  ;; %PRESIGN trims spaces when it builds the canonical request.
  ;; On a store made with :UPLOAD-ACL :PRIVATE, x-amz-acl: private is signed too, so a client
  ;; cannot add x-amz-acl: public-read to a bucket that honours ACLs. Measured on MinIO (#796):
  ;; with the header signed, public-read is refused with 403 and a missing header with 400.
  (let* ((content-type (and content-type (string-trim " " content-type)))
         (acl-header (%upload-acl-headers s))
         (headers (append (when content-type (list (cons "content-type" content-type)))
                          (when content-length (list (cons "content-length" (princ-to-string content-length))))
                          acl-header))
         (url (%presigned-url s bucket key "PUT" expires-in :headers headers)))
    ;; The URL is a credential: never logged. The key is the server's own (the docs require
    ;; it), so it is logged with the expiry and the cap.
    (log:info "blob upload URL issued" :backend "s3" :bucket bucket :key key
                                       :expires-in expires-in :content-length content-length
                                       :max-bytes max-bytes :upload-acl (s3-upload-acl s))
    (make-upload-target url "PUT"
                        (append (when content-type (list (cons "Content-Type" content-type)))
                                acl-header)
                        expires-in content-length)))

(defmethod read-blob-range ((s s3-store) bucket key &key (start 0) (length 512) if-match)
  (if (zerop length)
      ;; No range asks for zero bytes, so ask whether the blob exists instead: a missing key
      ;; signals BLOB-NOT-FOUND here as it does on every other store (#796). With IF-MATCH the
      ;; HEAD's ETag is compared too (#826).
      (if if-match
          (progn (%check-if-match bucket key if-match (blob-meta-etag (blob-metadata s bucket key))
                                  'blob-precondition-failed)
                 (make-array 0 :element-type '(unsigned-byte 8)))
          (if (blob-exists-p s bucket key)
              (make-array 0 :element-type '(unsigned-byte 8))
              (error 'blob-not-found :bucket bucket :key key)))
      (handler-case
          (multiple-value-bind (body status)
              (%s3-request s bucket key :get :want-stream t
                           :extra-headers
                           (cons (cons "range" (format nil "bytes=~D-~D" start (+ start length -1)))
                                 (%if-match-headers if-match)))
            ;; 206 is the range. 200 means the store, or a proxy in front of it, ignored Range
            ;; and is sending the whole object, so skip to START and read only LENGTH bytes;
            ;; closing the stream then drops the rest unread (#796).
            (unwind-protect (%read-range body (if (= status 206) 0 start) length)
              (close body)))
        (blob-backend-error (e)
          (case (blob-backend-error-status e)
            ;; 416: START is at or past the end, including any START on an empty object.
            (416 (make-array 0 :element-type '(unsigned-byte 8)))
            ;; 412: the object no longer has the ETag IF-MATCH named (#826).
            (412 (error 'blob-precondition-failed :bucket bucket :key key))
            (t (error e)))))))

;;; --- listing ---------------------------------------------------------------

(defconstant +max-entity-name-length+ 12
  "The longest text between `&' and `;' that %XML-DECODE reads as an entity. The longest name it
decodes is `#x10FFFF' plus a few leading zeros; a `;' further away cannot close an entity, and
not looking further keeps decoding linear in a string with many `&' and no `;'.")

(defun %numeric-reference (name)
  "The character the numeric reference NAME stands for (NAME is the text between `&' and `;',
starting with `#'), or NIL. Only `#' and ASCII decimal digits, or `#x' (a lowercase x, as XML
requires) and ASCII hex digits, with no sign and no space, and only a code point XML allows:
not 0, not a surrogate (D800-DFFF), which has no UTF-8 encoding, and not beyond the last code
point (#813)."
  (let* ((hex (and (>= (length name) 2) (char= #\x (char name 1))))
         (radix (if hex 16 10))
         (digits (subseq name (if hex 2 1))))
    ;; ASCII digits only: on SBCL DIGIT-CHAR-P and PARSE-INTEGER also accept other Unicode
    ;; decimal digits, such as Arabic-Indic ones, which XML does not.
    (when (and (plusp (length digits))
               (every (lambda (c) (find c (if hex "0123456789abcdefABCDEF" "0123456789"))) digits))
      (let ((code (parse-integer digits :radix radix)))
        (when (and (< 0 code char-code-limit) (not (<= #xD800 code #xDFFF)))
          (code-char code))))))

(defun %xml-decode (string)
  "Decode the five XML predefined entities and numeric character references (&#34; and &#x22;),
in one pass, so an escaped reference such as `&amp;#34;' is decoded once, to `&#34;'. Anything
that is not exactly one of those is kept as written. Keys we write cannot contain them (the
key alphabet excludes `&' and `<'), but a bucket may hold objects written by something else,
and the sweep must not mistake a mis-decoded key for an orphan. MinIO writes the quotes around
an ETag as `&#34;' (measured on MinIO 2025-04-22), so an ETag read without this is not the ETag."
  (with-output-to-string (out)
    (loop with i = 0
          while (< i (length string))
          do (let* ((amp (position #\& string :start i))
                    (window (and amp (min (length string) (+ amp 2 +max-entity-name-length+))))
                    (semi (and amp (position #\; string :start amp :end window))))
               (write-string string out :start i :end (or amp (length string)))
               (unless amp (return))
               (let* ((name (and semi (subseq string (1+ amp) semi)))
                      (char (cond ((null name) nil)
                                  ((string= name "lt") #\<) ((string= name "gt") #\>)
                                  ((string= name "quot") #\") ((string= name "apos") #\')
                                  ((string= name "amp") #\&)
                                  ((and (plusp (length name)) (char= #\# (char name 0)))
                                   (%numeric-reference name)))))
                 (if char
                     (progn (write-char char out) (setf i (1+ semi)))
                     ;; Not an entity we decode: keep the `&' as it is and go on after it.
                     (progn (write-char #\& out) (setf i (1+ amp)))))))))

(defun %replace-all (string part replacement)
  (with-output-to-string (out)
    (loop with part-length = (length part)
          for old-pos = 0 then (+ pos part-length)
          for pos = (search part string :start2 old-pos)
          do (write-string string out :start old-pos :end (or pos (length string)))
             (when pos (write-string replacement out))
          while pos)))

(defun %xml-values (body tag)
  "Every <TAG>…</TAG> text node in BODY, in order.

A deliberate four-line scanner rather than an XML dependency: ListObjectsV2 is the only
XML this module ever reads, we need exactly two element names from it, and the shape is
fixed by the S3 API. A parser would be a dependency to justify in docs/dependencies.md
for no behaviour we would gain."
  (let ((open (format nil "<~A>" tag))
        (close (format nil "</~A>" tag))
        (out '())
        (pos 0))
    (loop for start = (search open body :start2 pos)
          while start
          do (let ((end (search close body :start2 (+ start (length open)))))
               (unless end (return))
               (push (%xml-decode (subseq body (+ start (length open)) end)) out)
               (setf pos (+ end (length close)))))
    (nreverse out)))

(defmethod list-blobs ((s s3-store) bucket &key prefix)
  (let ((keys '())
        (tail nil)
        (token nil))
    (loop
      (let* ((params (append (list (cons "list-type" "2"))
                             (when prefix (list (cons "prefix" prefix)))
                             (when token (list (cons "continuation-token" token)))))
             (query (%canonical-query params))
             (body (%s3-request s bucket nil :get :query query))
             (text (if (stringp body) body (sb-ext:octets-to-string body :external-format :utf-8))))
        ;; Splice each page onto a TAIL POINTER. (APPEND KEYS PAGE) copies everything
        ;; accumulated so far on every page, so listing a bucket was quadratic in the
        ;; object count -- and SWEEP-ORPHANS is the caller, i.e. the one that meets the
        ;; big buckets by definition. NCONC is not the fix either; it walks KEYS just
        ;; the same. The page lists are freshly consed by %XML-VALUES, so splicing them
        ;; destructively is safe -- nothing else holds a reference.
        (let ((page (%xml-values text "Key")))
          (when page
            (if tail (setf (cdr tail) page) (setf keys page))
            (setf tail (last page))))
        (let ((truncated (first (%xml-values text "IsTruncated")))
              (next (first (%xml-values text "NextContinuationToken"))))
          ;; Paging is followed to the end rather than capped. A silent top-N here would
          ;; make SWEEP-ORPHANS delete only what it happened to see and report success.
          (if (and truncated (string-equal truncated "true") next)
              (setf token next)
              (return)))))
    keys))

;;; --- CORS (#770) -----------------------------------------------------------
;;;
;;; A browser upload to a bucket is a cross-origin PUT, so the bucket needs a CORS rule naming
;;; the app's origin. Without one the browser stops the request and the app sees a network
;;; error and nothing else, which is why CHECK-BUCKET-CORS exists.

(defun %base64 (octets)
  "OCTETS in standard base64 with padding (RFC 4648 section 4). S3's Content-MD5 needs it, and
this module declares no base64 dependency for one call."
  (let ((alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"))
    (with-output-to-string (out)
      (loop for i from 0 below (length octets) by 3
            for n = (- (length octets) i)
            for b0 = (aref octets i)
            for b1 = (if (> n 1) (aref octets (+ i 1)) 0)
            for b2 = (if (> n 2) (aref octets (+ i 2)) 0)
            for triple = (logior (ash b0 16) (ash b1 8) b2)
            do (write-char (char alphabet (ldb (byte 6 18) triple)) out)
               (write-char (char alphabet (ldb (byte 6 12) triple)) out)
               (write-char (if (> n 1) (char alphabet (ldb (byte 6 6) triple)) #\=) out)
               (write-char (if (> n 2) (char alphabet (ldb (byte 6 0) triple)) #\=) out)))))

(defun %xml-escape (string)
  (%replace-all (%replace-all (%replace-all (%replace-all (%replace-all string "&" "&amp;") "<" "&lt;")
                                            ">" "&gt;") "\"" "&quot;") "'" "&apos;"))

(defun %cors-xml (origins methods allowed-headers max-age-seconds &optional expose-headers)
  "The CORSConfiguration document for one rule."
  (with-output-to-string (out)
    (format out "<CORSConfiguration><CORSRule>")
    (dolist (o origins) (format out "<AllowedOrigin>~A</AllowedOrigin>" (%xml-escape o)))
    (dolist (m methods) (format out "<AllowedMethod>~A</AllowedMethod>" (%xml-escape m)))
    (dolist (h allowed-headers) (format out "<AllowedHeader>~A</AllowedHeader>" (%xml-escape h)))
    (dolist (h expose-headers) (format out "<ExposeHeader>~A</ExposeHeader>" (%xml-escape h)))
    (format out "<MaxAgeSeconds>~D</MaxAgeSeconds></CORSRule></CORSConfiguration>" max-age-seconds)))

(defmethod put-bucket-cors ((s s3-store) bucket &key origins (methods '("PUT"))
                                                      (allowed-headers '("Content-Type" "x-amz-acl"))
                                                      (max-age-seconds 3000) expose-headers)
  (let* ((body (%octets (%cors-xml origins methods allowed-headers max-age-seconds expose-headers)))
         (md5 (%base64 (ironclad:digest-sequence :md5 body))))
    ;; PutBucketCors requires Content-MD5 (or an x-amz-checksum header) over the body.
    (%s3-request s bucket nil :put :query "cors=" :content body :content-type "application/xml"
                                   :payload-hash (%sha256-hex body)
                                   :extra-headers (list (cons "content-md5" md5)))
    (log:info "bucket CORS rule set" :backend "s3" :bucket bucket :origins (length origins))
    t))

(defun %wildcard-match-p (pattern string &key case-insensitive)
  "Does STRING match PATTERN, where PATTERN may hold one `*' standing for any run of characters,
as S3 allows in AllowedOrigin and AllowedHeader?"
  (let* ((test (if case-insensitive #'char-equal #'char=))
         (star (position #\* pattern)))
    (if (null star)
        (and (= (length pattern) (length string)) (every test pattern string))
        (let ((head (subseq pattern 0 star))
              (tail (subseq pattern (1+ star))))
          (and (>= (length string) (+ (length head) (length tail)))
               (every test head (subseq string 0 (length head)))
               (every test tail (subseq string (- (length string) (length tail)))))))))

(defun %cors-rules (xml)
  "Each <CORSRule> in XML as a plist (:origins :methods :headers)."
  (loop for rule in (%xml-values xml "CORSRule")
        collect (list :origins (%xml-values rule "AllowedOrigin")
                      :methods (%xml-values rule "AllowedMethod")
                      :headers (%xml-values rule "AllowedHeader"))))

(defun %cors-verdict (rules origin method headers)
  "The CHECK-BUCKET-CORS answer for parsed RULES. Pure, so each verdict is tested directly."
  (flet ((origin-ok (r) (some (lambda (p) (%wildcard-match-p p origin)) (getf r :origins)))
         (method-ok (r) (member method (getf r :methods) :test #'string=))
         (headers-ok (r) (every (lambda (h) (some (lambda (p) (%wildcard-match-p p h :case-insensitive t))
                                                  (getf r :headers)))
                                headers)))
    (cond ((null rules) :no-cors-configuration)
          ((some (lambda (r) (and (origin-ok r) (method-ok r) (headers-ok r))) rules) :allowed)
          ((notany #'origin-ok rules) :origin-not-allowed)
          ((notany (lambda (r) (and (origin-ok r) (method-ok r))) rules) :method-not-allowed)
          (t :header-not-allowed))))

(defmethod check-bucket-cors ((s s3-store) bucket origin
                              &key (method "PUT")
                                   ;; The headers UPLOAD-URL's target carries on this store.
                                   (headers (cons "Content-Type" (mapcar #'car (%upload-acl-headers s)))))
  (let ((xml (handler-case
                 (let ((body (%s3-request s bucket nil :get :query "cors=")))
                   (if (stringp body) body (sb-ext:octets-to-string body :external-format :utf-8)))
               ;; A bucket with no CORS configuration answers 404 NoSuchCORSConfiguration,
               ;; which %S3-REQUEST reports as BLOB-NOT-FOUND.
               (blob-not-found () ""))))
    (%cors-verdict (%cors-rules xml) origin method headers)))

;;; --- multipart uploads (#770) ----------------------------------------------

(defun %body-text (body)
  (if (stringp body) body (sb-ext:octets-to-string body :external-format :utf-8)))

(defun %create-multipart-upload (s bucket key content-type &optional extra-headers)
  "CreateMultipartUpload for BUCKET/KEY, returning the upload id. EXTRA-HEADERS carry the object's
metadata and ACL when a multipart copy sets them (#804)."
  (let* ((text (%body-text (%s3-request s bucket key :post :query "uploads="
                                        :content (make-array 0 :element-type '(unsigned-byte 8))
                                        :content-type content-type
                                        :payload-hash (%sha256-hex "")
                                        :extra-headers extra-headers)))
         (upload-id (first (%xml-values text "UploadId"))))
    (unless upload-id
      (error 'blob-backend-error :bucket bucket :key key :detail "CreateMultipartUpload returned no UploadId"))
    upload-id))

(defmethod start-multipart-upload ((s s3-store) bucket key &key (content-type "application/octet-stream"))
  (let ((upload-id (%create-multipart-upload s bucket key content-type)))
    (log:info "multipart upload started" :backend "s3" :bucket bucket :key key)
    upload-id))

(defmethod multipart-part-url ((s s3-store) bucket key upload-id part-number &key expires-in content-length)
  ;; partNumber and uploadId are SIGNED query parameters, so this URL carries this part of this
  ;; upload and nothing else. As for UPLOAD-URL, the URL itself is never logged.
  (let ((url (%presigned-url s bucket key "PUT" expires-in
                             :headers (when content-length
                                        (list (cons "content-length" (princ-to-string content-length))))
                             :query-params (list (cons "partNumber" (princ-to-string part-number))
                                                 (cons "uploadId" upload-id)))))
    (log:debug "multipart part URL issued" :backend "s3" :bucket bucket :key key
                                           :part part-number :expires-in expires-in
                                           :content-length content-length)
    (make-upload-target url "PUT" nil expires-in content-length)))

(defun %complete-xml (parts)
  "The CompleteMultipartUpload document, parts in ascending order as S3 requires."
  (with-output-to-string (out)
    (format out "<CompleteMultipartUpload>")
    (dolist (p (sort (copy-list parts) #'< :key #'car))
      (format out "<Part><PartNumber>~D</PartNumber><ETag>~A</ETag></Part>" (car p) (%xml-escape (cdr p))))
    (format out "</CompleteMultipartUpload>")))

(defmethod complete-multipart-upload ((s s3-store) bucket key upload-id parts)
  (let* ((body (%octets (%complete-xml parts)))
         (text (%body-text (%s3-request s bucket key :post
                                        :query (%canonical-query (list (cons "uploadId" upload-id)))
                                        :content body :content-type "application/xml"
                                        :payload-hash (%sha256-hex body)))))
    ;; CompleteMultipartUpload can answer 200 and still fail, with an <Error> document as the body
    ;; (a part too small, a wrong ETag). A 200 is not success until the body says so.
    (when (search "<Error>" text)
      (error 'blob-backend-error :bucket bucket :key key :status 200
                                 :detail (first (%xml-values text "Code"))))
    (log:info "multipart upload completed" :backend "s3" :bucket bucket :key key :parts (length parts))
    t))

(defmethod abort-multipart-upload ((s s3-store) bucket key upload-id)
  (handler-case (progn (%s3-request s bucket key :delete
                                    :query (%canonical-query (list (cons "uploadId" upload-id))))
                       t)
    ;; NoSuchUpload: already completed or aborted, which is the outcome asked for.
    (blob-not-found () t)))

(defmethod list-multipart-parts ((s s3-store) bucket key upload-id)
  (let ((parts '()) (marker nil))
    (loop
      (let* ((text (%body-text (%s3-request s bucket key :get
                                            :query (%canonical-query
                                                    (append (list (cons "uploadId" upload-id))
                                                            (when marker (list (cons "part-number-marker" marker))))))))
             (truncated (first (%xml-values text "IsTruncated")))
             (next (first (%xml-values text "NextPartNumberMarker"))))
        (dolist (part (%xml-values text "Part"))
          (push (list (parse-integer (first (%xml-values part "PartNumber")))
                      (first (%xml-values part "ETag"))
                      (parse-integer (first (%xml-values part "Size"))))
                parts))
        (if (and truncated (string-equal truncated "true") next (not (equal next marker)))
            (setf marker next)
            (return))))
    (sort (nreverse parts) #'< :key #'first)))

;;; --- server-side copy (#804) ------------------------------------------------
;;;
;;; CopyObject up to 5 GiB, a multipart copy (UploadPartCopy) above it. Every request is
;;; conditional on the source's ETag as read at the start, so a source replaced between the app's
;;; verification and the copy, or partway through a multipart copy, fails with 412
;;; (BLOB-SOURCE-CHANGED) rather than copying, or mixing in, a different object.

(defvar *%copy-multipart-threshold* +max-single-put-bytes+
  "TEST-ONLY. A source larger than this many bytes is copied in parts. It is S3's CopyObject
limit; a test binds it lower to exercise the multipart path on a small object.")

(defvar *%copy-part-size* (* 512 1024 1024)
  "TEST-ONLY. The smallest part a multipart copy uses; parts grow so that no copy needs more
than 10000. S3 requires 5 MiB to 5 GiB per part. A test binds it lower, never below 5 MiB on a
real store.")

(defun %copy-source (bucket key)
  "The x-amz-copy-source value: /BUCKET/KEY, the key percent-encoded with its slashes kept."
  (format nil "/~A/~A" bucket (%uri-encode key :encode-slash nil)))

(defun %source-head (s bucket key)
  "The source's (values size etag content-type user-metadata checksum) from one HEAD request.
USER-METADATA is the app's x-amz-meta-* entries, without the store's own sha256."
  (multiple-value-bind (body status headers) (%s3-request s bucket key :head)
    (declare (ignore body status))
    (flet ((hdr (name) (gethash name headers)))
      (values (or (ignore-errors (parse-integer (or (hdr "content-length") "0"))) 0)
              (hdr "etag")
              (hdr "content-type")
              (let ((user '()))
                (maphash (lambda (name value)
                           (when (and (> (length name) 11)
                                      (string-equal "x-amz-meta-" name :end2 11)
                                      (not (string-equal name "x-amz-meta-sha256")))
                             (push (cons (subseq name 11) value) user)))
                         headers)
                (sort user #'string< :key #'car))
              (hdr "x-amz-meta-sha256")))))

(defun %object-headers (s user-metadata checksum)
  "The x-amz-meta-* and x-amz-acl headers an object is created with by a copy that sets them."
  (append (loop for (name . value) in user-metadata
                collect (cons (format nil "x-amz-meta-~A" (string-downcase name)) value))
          (when checksum (list (cons "x-amz-meta-sha256" checksum)))
          (%upload-acl-headers s)))

(defun %copy-request (s src-bucket src-key dst-bucket dst-key &rest args)
  "%S3-REQUEST for a CopyObject or UploadPartCopy into DST-BUCKET/DST-KEY, with its failures read
as a copy's: 412 is BLOB-SOURCE-CHANGED, 501 is BLOB-UNSUPPORTED, and a 404 names the source when
the source is gone (else the destination, whose bucket is then missing). A 200 whose body is an
<Error> document is a failure too. Returns the body as text."
  (let ((text (handler-case (%body-text (apply #'%s3-request s dst-bucket dst-key :put args))
                (blob-backend-error (e)
                  (case (blob-backend-error-status e)
                    (412 (error 'blob-source-changed :bucket src-bucket :key src-key))
                    (501 (error 'blob-unsupported
                                :bucket src-bucket :key src-key
                                :operation "server-side copy (copy through get-blob and put-blob)"))
                    (t (error e))))
                (blob-not-found ()
                  ;; %S3-REQUEST folds 403 into BLOB-NOT-FOUND. With the source still there, the
                  ;; copy was refused (missing GetObject or PutObject, a KMS denial) or the
                  ;; destination bucket is missing; reporting the destination as not found would
                  ;; read as "the upload vanished" to a quarantine flow.
                  (if (blob-exists-p s src-bucket src-key)
                      (error 'blob-backend-error
                             :bucket dst-bucket :key dst-key
                             :detail "copy refused (403) or destination bucket missing")
                      (error 'blob-not-found :bucket src-bucket :key src-key))))))
    ;; CopyObject and UploadPartCopy can answer 200 with an <Error> document as the body.
    (when (search "<Error>" text)
      (let ((code (first (%xml-values text "Code"))))
        (if (equal code "PreconditionFailed")
            (error 'blob-source-changed :bucket src-bucket :key src-key :status 200)
            (error 'blob-backend-error :bucket dst-bucket :key dst-key :status 200 :detail code))))
    text))

(defun %copy-part-ranges (size part-size)
  "The inclusive byte ranges (first . last) a multipart copy of SIZE bytes uses: parts of at least
PART-SIZE, grown so there are no more than 10000, the last one shorter."
  (let ((part (max part-size (ceiling size 10000))))
    (loop for first from 0 below size by part
          collect (cons first (1- (min size (+ first part)))))))

(defun %copy-single (s src-bucket src-key dst-bucket dst-key source replace
                     new-type new-user checksum)
  "CopyObject. COPY keeps the source's type, metadata and checksum as they are; REPLACE sends the
new ones, with the source's checksum sent again."
  (%copy-request s src-bucket src-key dst-bucket dst-key
                 :content (make-array 0 :element-type '(unsigned-byte 8))
                 :payload-hash (%sha256-hex "")
                 :content-type (when replace new-type)
                 :extra-headers
                 (append source
                         (list (cons "x-amz-metadata-directive" (if replace "REPLACE" "COPY")))
                         (if replace
                             (%object-headers s new-user checksum)
                             (%upload-acl-headers s)))))

(defun %copy-part (s src-bucket src-key dst-bucket dst-key source upload-id number range)
  "UploadPartCopy of the source's bytes RANGE, (first . last), as part NUMBER. Returns its ETag."
  (let ((text (%copy-request s src-bucket src-key dst-bucket dst-key
                             :content (make-array 0 :element-type '(unsigned-byte 8))
                             :payload-hash (%sha256-hex "")
                             :query (%canonical-query
                                     (list (cons "partNumber" (princ-to-string number))
                                           (cons "uploadId" upload-id)))
                             :extra-headers
                             (append source
                                     (list (cons "x-amz-copy-source-range"
                                                 (format nil "bytes=~D-~D"
                                                         (car range) (cdr range))))))))
    (first (%xml-values text "ETag"))))

(defun %copy-multipart (s src-bucket src-key dst-bucket dst-key source ranges
                        new-type new-user checksum)
  "A multipart copy of RANGES. It creates the object afresh, so it always sets the type,
metadata, checksum and ACL itself, and it aborts the upload on any failure, so no parts are left
behind to be billed."
  (let ((upload-id (%create-multipart-upload s dst-bucket dst-key new-type
                                             (%object-headers s new-user checksum)))
        (completed nil))
    (unwind-protect
         (let ((parts (loop for range in ranges
                            for number from 1
                            collect (cons number (%copy-part s src-bucket src-key dst-bucket dst-key
                                                             source upload-id number range)))))
           (complete-multipart-upload s dst-bucket dst-key upload-id parts)
           (setf completed t))
      (unless completed
        (ignore-errors (abort-multipart-upload s dst-bucket dst-key upload-id))))))

(defmethod copy-blob ((s s3-store) src-bucket src-key dst-bucket dst-key
                      &key content-type metadata if-match)
  (let ((same (%same-location-p src-bucket src-key dst-bucket dst-key)))
    (if (and same (not content-type) (not metadata))
        ;; Nothing to copy and nothing to change: one HEAD, which also reports a missing blob.
        (let ((meta (blob-metadata s src-bucket src-key)))
          (%check-if-match src-bucket src-key if-match (blob-meta-etag meta))
          meta)
        (multiple-value-bind (size etag src-type src-user checksum)
            (%source-head s src-bucket src-key)
          ;; Every copy request is conditional on the source's ETag, so a store that answers the
          ;; HEAD without one cannot be copied from safely; without this check the header would
          ;; read "NIL" and every copy would fail as BLOB-SOURCE-CHANGED.
          (unless (and etag (plusp (length etag)))
            (error 'blob-backend-error
                   :bucket src-bucket :key src-key
                   :detail "the source has no ETag, so the copy cannot be made conditional on it"))
          ;; The app's IF-MATCH is checked against the HEAD's ETag before anything is sent, and
          ;; every copy request is conditional on that same ETag, so the copy is of the checked
          ;; bytes.
          (%check-if-match src-bucket src-key if-match etag)
          (let* ((replace (or content-type metadata same))
                 (new-type (or content-type src-type "application/octet-stream"))
                 (new-user (or metadata src-user))
                 (source (list (cons "x-amz-copy-source" (%copy-source src-bucket src-key))
                               (cons "x-amz-copy-source-if-match" etag)))
                 (ranges (when (> size *%copy-multipart-threshold*)
                           (%copy-part-ranges size *%copy-part-size*))))
            (if ranges
                (%copy-multipart s src-bucket src-key dst-bucket dst-key source ranges
                                 new-type new-user checksum)
                (%copy-single s src-bucket src-key dst-bucket dst-key source replace
                              new-type new-user checksum))
            (log:info "blob copied" :backend "s3" :src-bucket src-bucket :dst-bucket dst-bucket
                                    :bytes size :mode (if ranges :multipart :single)
                                    :parts (if ranges (length ranges) 1)
                                    :metadata-directive (if replace :replace :copy))
            (blob-metadata s dst-bucket dst-key))))))
