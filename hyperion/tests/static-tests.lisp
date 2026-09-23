;;;; static-tests.lisp --- static file serving: content types, traversal, caching.
;;;;
;;;; The caching tests are the point: a second request carrying the validators the first
;;;; response handed out must come back 304 with no body. That round trip is what saves
;;;; the bandwidth, and it is easy to break silently, so it is asserted end to end
;;;; against real files in a temp directory.

(in-package #:hyperion/tests)

(def-suite static :description "Static file responses: types, safety, caching." :in hyperion)
(in-suite static)

(defvar *static-test-seq* 0
  "Counter making each temp root unique. Not tmpize-pathname: that CREATES a file, and we
need a directory of that name.")

(defmacro with-static-root ((root &rest files) &body body)
  "Bind ROOT to a fresh temp directory containing FILES -- each (relative-name contents)."
  (let ((dir (gensym)) (name (gensym)) (contents (gensym)))
    `(let ((,dir (uiop:ensure-directory-pathname
                  (merge-pathnames (format nil "hyperion-static-test-~D-~D/"
                                           (get-universal-time) (incf *static-test-seq*))
                                   (uiop:temporary-directory)))))
       (ensure-directories-exist ,dir)
       (unwind-protect
            (let ((,root ,dir))
              ,@(loop for (n c) in files
                      collect `(let ((,name (merge-pathnames ,n ,dir))
                                     (,contents ,c))
                                 (ensure-directories-exist ,name)
                                 (with-open-file (s ,name :direction :output
                                                          :if-exists :supersede)
                                   (write-string ,contents s))))
              ,@body)
         (ignore-errors (uiop:delete-directory-tree ,dir :validate t))))))

(defun %static-env (&rest headers)
  "A minimal Clack env carrying HEADERS (name value name value ...).
Named %STATIC-ENV, not %ENV: every *-tests.lisp shares the one HYPERION/TESTS package, and
session-tests.lisp already defines a different %ENV -- a plain %ENV here silently redefined
it and broke that suite."
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on headers by #'cddr
          do (setf (gethash (string-downcase k) h) v))
    (list :headers h :request-method :get)))

(defun %static-header (response name)
  (getf (second response) name))

;;; --- content type + traversal (pre-existing behaviour, now pinned) ---------

(test content-type-by-extension
  (is (string= "text/css" (static:content-type-for #p"a/b/site.css")))
  (is (string= "image/png" (static:content-type-for #p"logo.PNG")))          ; case-insensitive
  (is (string= "application/octet-stream" (static:content-type-for #p"blob.unknown")))
  (is (string= "application/octet-stream" (static:content-type-for #p"noext"))))

(test traversal-is-refused
  (with-static-root (root ("ok.txt" "fine"))
    (is (null (static:file-response root "/../etc/passwd")))
    (is (null (static:file-response root "/")))
    (is (null (static:file-response root "")))
    (is (null (static:file-response root "/missing.txt")))))

(test serves-an-existing-file-as-a-pathname
  (with-static-root (root ("ok.txt" "fine"))
    (let ((r (static:file-response root "/ok.txt")))
      (is (= 200 (first r)))
      (is (pathnamep (third r)))                                  ; streamed, not slurped
      (is (string= "text/plain; charset=utf-8" (%static-header r :content-type))))))

;;; --- caching headers -------------------------------------------------------

(test emits-validators-and-cache-control
  (with-static-root (root ("app.css" "body{}"))
    (let ((r (static:file-response root "/app.css")))
      (is (= 200 (first r)))
      (is (stringp (%static-header r :etag)))
      (is (char= #\" (char (%static-header r :etag) 0)))              ; quoted per the grammar
      (is (stringp (%static-header r :last-modified)))
      (is (search "GMT" (%static-header r :last-modified)))
      ;; `public` is what lets a CDN store it despite a platform default of `private`
      (is (search "public" (%static-header r :cache-control))))))

(test cache-control-is-configurable-and-omittable
  (with-static-root (root ("app.css" "body{}"))
    (is (string= static:*immutable-cache-control*
                 (%static-header (static:file-response root "/app.css"
                                                   :cache-control static:*immutable-cache-control*)
                             :cache-control)))
    (is (null (%static-header (static:file-response root "/app.css" :cache-control nil)
                          :cache-control)))))

(test etag-round-trip-yields-304-with-no-body
  ;; The behaviour the issue asked for, asserted end to end.
  (with-static-root (root ("app.css" "body{}"))
    (let* ((first (static:file-response root "/app.css"))
           (etag (%static-header first :etag))
           (second (static:file-response root "/app.css" :env (%static-env "If-None-Match" etag))))
      (is (= 200 (first first)))
      (is (= 304 (first second)))
      (is (null (third second)))                                   ; no body -- the savings
      (is (string= etag (%static-header second :etag)))                ; validators repeat
      (is (stringp (%static-header second :cache-control))))))

(test if-modified-since-round-trip-yields-304
  (with-static-root (root ("app.css" "body{}"))
    (let* ((r (static:file-response root "/app.css"))
           (lm (%static-header r :last-modified)))
      (is (= 304 (first (static:file-response root "/app.css"
                                              :env (%static-env "If-Modified-Since" lm))))))))

(test stale-validators-serve-the-file
  (with-static-root (root ("app.css" "body{}"))
    (is (= 200 (first (static:file-response root "/app.css"
                                            :env (%static-env "If-None-Match" "\"not-the-tag\"")))))
    (is (= 200 (first (static:file-response
                       root "/app.css"
                       :env (%static-env "If-Modified-Since"
                                  (static:http-date (- (get-universal-time) 86400)))))))))

(test etag-wins-over-a-stale-date
  ;; RFC 9110: If-None-Match takes precedence. A date has one-second resolution and cannot
  ;; see two writes in the same second, so a stale date must not defeat a matching tag --
  ;; nor a fresh date rescue a non-matching one.
  (with-static-root (root ("app.css" "body{}"))
    (let* ((r (static:file-response root "/app.css"))
           (etag (%static-header r :etag))
           (old (static:http-date (- (get-universal-time) 86400))))
      (is (= 304 (first (static:file-response
                         root "/app.css"
                         :env (%static-env "If-None-Match" etag "If-Modified-Since" old)))))
      (is (= 200 (first (static:file-response
                         root "/app.css"
                         :env (%static-env "If-None-Match" "\"nope\""
                                    "If-Modified-Since" (%static-header r :last-modified)))))))))

(test etag-matching-handles-lists-weak-tags-and-star
  (with-static-root (root ("app.css" "body{}"))
    (let* ((r (static:file-response root "/app.css"))
           (etag (%static-header r :etag)))
      (flet ((status (inm) (first (static:file-response root "/app.css"
                                                        :env (%static-env "If-None-Match" inm)))))
        (is (= 304 (status "*")))
        (is (= 304 (status (format nil "\"other\", ~A" etag))))    ; a list, ours second
        (is (= 304 (status (format nil "W/~A" etag))))             ; weak comparison
        (is (= 200 (status "\"a\", \"b\"")))))))

(test etag-changes-when-the-bytes-change
  (with-static-root (root ("app.css" "body{}"))
    (let ((before (%static-header (static:file-response root "/app.css") :etag)))
      ;; rewrite with different content; size differs, so the tag must differ
      (with-open-file (s (merge-pathnames "app.css" root) :direction :output
                                                          :if-exists :supersede)
        (write-string "body{color:red}" s))
      (let ((after (%static-header (static:file-response root "/app.css") :etag)))
        (is (not (string= before after)))
        ;; and a client holding the old tag must now get the file, not a 304
        (is (= 200 (first (static:file-response root "/app.css"
                                                :env (%static-env "If-None-Match" before)))))))))

;;; --- HTTP date handling ----------------------------------------------------

(test http-date-round-trips
  (let ((now (get-universal-time)))
    (is (= now (static:parse-http-date (static:http-date now)))))
  ;; a known value, to pin the format itself (RFC 9110's own example)
  (is (string= "Sun, 06 Nov 1994 08:49:37 GMT"
               (static:http-date (encode-universal-time 37 49 8 6 11 1994 0)))))

(test parse-http-date-rejects-junk
  (is (null (static:parse-http-date nil)))
  (is (null (static:parse-http-date "")))
  (is (null (static:parse-http-date "not a date")))
  (is (null (static:parse-http-date "Sun, 06 Zzz 1994 08:49:37 GMT"))))
