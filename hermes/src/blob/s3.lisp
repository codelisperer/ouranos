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
   (public-base-url :initarg :public-base-url :initform nil :reader s3-public-base-url))
  (:documentation "A blob store on any S3-compatible object store."))

(defun %require-setting (value name)
  (if (and value (plusp (length value)))
      value
      (error 'blob-configuration-error :missing name)))

(defun make-s3-store (&key endpoint region access-key secret-key session-token
                           (secure t) path-style public-base-url)
  "An S3-STORE, defaulting every setting from the environment.

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
                                        (uiop:getenv "MNEMOSYNE_S3_PUBLIC_BASE_URL")))))

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
            (let ((status (dex:response-status e)))
              (if (member status '(403 404))
                  ;; 403 is folded into NOT-FOUND deliberately: a bucket configured to
                  ;; deny listing answers a missing key with 403, and a caller asking
                  ;; "is this photo there" must not have to know which policy the bucket
                  ;; happens to run to read the answer.
                  (error 'blob-not-found :bucket bucket :key key)
                  (error 'blob-backend-error :bucket bucket :key key :status status
                                             :detail (dex:response-body e)))))
          (error (e)
            (error 'blob-backend-error :bucket bucket :key key
                                       :detail (princ-to-string e))))
      (values body status resp-headers))))

;;; --- operations ------------------------------------------------------------

(defmethod put-blob ((s s3-store) bucket key stream &key content-type metadata)
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
                            (loop for (mk . mv) in metadata
                                  collect (cons (format nil "x-amz-meta-~A" (string-downcase mk))
                                                mv)))
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

(defmethod blob-metadata ((s s3-store) bucket key)
  (multiple-value-bind (body status headers) (%s3-request s bucket key :head)
    (declare (ignore body status))
    (flet ((hdr (name) (gethash name headers)))
      (make-blob-meta key
                      (or (ignore-errors (parse-integer (or (hdr "content-length") "0"))) 0)
                      (hdr "content-type")
                      ;; The ETag is the MD5 for a single-part upload and something else
                      ;; entirely for a multipart one, so it is NOT our SHA-256 checksum.
                      ;; Report the checksum we recorded at PUT time, or nothing.
                      (hdr "x-amz-meta-sha256")
                      nil))))

(defmethod blob-url ((s s3-store) bucket key &key expires-in)
  (if (null expires-in)
      (let ((base (s3-public-base-url s)))
        (unless (and base (plusp (length base)))
          (error 'blob-unsupported :bucket bucket :key key
                                   :operation "unsigned URLs (no public base URL configured)"))
        (let ((sep (if (eql #\/ (char base (1- (length base)))) "" "/")))
          (format nil "~A~A~A" base sep (%uri-encode key :encode-slash nil))))
      (multiple-value-bind (amz-date date) (%amz-dates)
        (let* ((scope (%credential-scope date (s3-region s)))
               (host (%s3-host s bucket))
               (path (%s3-path s bucket key))
               (params (append (list (cons "X-Amz-Algorithm" "AWS4-HMAC-SHA256")
                                     (cons "X-Amz-Credential"
                                           (format nil "~A/~A" (s3-access-key s) scope))
                                     (cons "X-Amz-Date" amz-date)
                                     (cons "X-Amz-Expires" (princ-to-string expires-in))
                                     (cons "X-Amz-SignedHeaders" "host"))
                               (when (s3-session-token s)
                                 (list (cons "X-Amz-Security-Token" (s3-session-token s))))))
               (query (%canonical-query params))
               (canonical-request
                 (format nil "GET~%~A~%~A~%host:~A~%~%host~%UNSIGNED-PAYLOAD" path query host))
               (signature (ironclad:byte-array-to-hex-string
                           (%hmac-sha256 (%signing-key (s3-secret-key s) date (s3-region s))
                                         (%string-to-sign amz-date scope canonical-request)))))
          (format nil "~A://~A~A?~A&X-Amz-Signature=~A"
                  (if (s3-secure-p s) "https" "http") host path query signature)))))

;;; --- listing ---------------------------------------------------------------

(defun %xml-decode (string)
  "Decode the five XML predefined entities. Keys we write cannot contain them (the key
alphabet excludes `&' and `<'), but a bucket may hold objects written by something else,
and the sweep must not mistake a mis-decoded key for an orphan."
  (let ((s string))
    (dolist (pair '(("&lt;" . "<") ("&gt;" . ">") ("&quot;" . "\"")
                    ("&apos;" . "'") ("&amp;" . "&"))
                  s)
      (setf s (%replace-all s (car pair) (cdr pair))))))

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
