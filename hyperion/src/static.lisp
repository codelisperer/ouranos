;;;; static.lisp --- serving static files from a directory.
;;;;
;;;; A small helper that turns a URL path into a Clack file response, with the
;;;; content-type inferred from the extension and `..` traversal refused. Pathname-
;;;; based (uiop:parse-unix-namestring) so the same code serves files on Windows
;;;; and Unix. The caller maps a URL prefix to a root dir and falls through to a
;;;; 404 when FILE-RESPONSE returns NIL.
;;;;
;;;; Caching. A static response carries validators (`ETag`, `Last-Modified`) and a
;;;; `Cache-Control` so browsers can revalidate and a CDN can store the bytes. Without
;;;; them every asset is refetched on every navigation, and an edge that sees no
;;;; explicit policy falls back to the platform default (often `private`), which
;;;; bypasses the cache entirely. Pass the request ENV and FILE-RESPONSE also answers
;;;; conditional requests -- `If-None-Match` / `If-Modified-Since` -> `304` with no body,
;;;; which is where the bandwidth actually goes.
;;;;
;;;; Dates are formatted/parsed here (RFC 9110 IMF-fixdate) rather than pulling in a
;;;; time library: one fixed-width format, both directions, no dependency.

(in-package #:hyperion/static)

(defparameter *content-types*
  '(("html" . "text/html; charset=utf-8")
    ("css"  . "text/css")
    ("js"   . "application/javascript")
    ("mjs"  . "application/javascript")
    ("json" . "application/json")
    ("map"  . "application/json")
    ("svg"  . "image/svg+xml")
    ("png"  . "image/png")
    ("jpg"  . "image/jpeg")
    ("jpeg" . "image/jpeg")
    ("gif"  . "image/gif")
    ("ico"  . "image/x-icon")
    ("webp" . "image/webp")
    ("woff" . "font/woff")
    ("woff2" . "font/woff2")
    ("ttf"  . "font/ttf")
    ("txt"  . "text/plain; charset=utf-8"))
  "Extension (lowercase, no dot) -> Content-Type.")

(defun content-type-for (path)
  "Content-Type for PATH by extension, defaulting to application/octet-stream."
  (let ((type (pathname-type path)))
    (or (and type (cdr (assoc (string-downcase type) *content-types* :test #'string=)))
        "application/octet-stream")))

(defparameter *cache-control* "public, max-age=3600"
  "Default `Cache-Control` for static responses. `public` is deliberate: it overrides a
platform/edge default of `private`, which otherwise makes a CDN report a cache BYPASS and
store nothing. An hour is a safe default for assets served under their own name -- the
validators below make revalidation cheap (a 304, no body). Bind or pass :CACHE-CONTROL to
change it; NIL emits no header at all.")

(defparameter *immutable-cache-control* "public, max-age=31536000, immutable"
  "`Cache-Control` for content-addressed (fingerprinted) URLs -- a year, never revalidated.
Only safe when the URL changes whenever the bytes change, i.e. the filename carries a hash
of its content. Pass it explicitly for a fingerprinted asset route.")

;;; --- HTTP dates (RFC 9110 IMF-fixdate) -------------------------------------
;;; "Sun, 06 Nov 1994 08:49:37 GMT" -- fixed width, GMT only, English names by spec
;;; (never locale-dependent).

(defparameter +day-names+ #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))
(defparameter +month-names+ #("Jan" "Feb" "Mar" "Apr" "May" "Jun"
                              "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(defun http-date (universal-time)
  "UNIVERSAL-TIME -> an IMF-fixdate string in GMT."
  (multiple-value-bind (sec min hour date month year day)
      (decode-universal-time universal-time 0)
    (format nil "~A, ~2,'0D ~A ~D ~2,'0D:~2,'0D:~2,'0D GMT"
            (aref +day-names+ day) date (aref +month-names+ (1- month)) year
            hour min sec)))

(defun parse-http-date (string)
  "IMF-fixdate STRING -> universal time, or NIL if it is not one. Browsers echo back
exactly what we sent, so only the fixed-width form is accepted; anything else is treated
as absent (the request is simply not conditional) rather than signalled."
  (let ((s (string-trim " " (or string ""))))
    (when (>= (length s) 29)
      (ignore-errors
        (let ((date  (parse-integer s :start 5  :end 7))
              (month (position (subseq s 8 11) +month-names+ :test #'string-equal))
              (year  (parse-integer s :start 12 :end 16))
              (hour  (parse-integer s :start 17 :end 19))
              (min   (parse-integer s :start 20 :end 22))
              (sec   (parse-integer s :start 23 :end 25)))
          (when month
            (encode-universal-time sec min hour date (1+ month) year 0)))))))

;;; --- validators ------------------------------------------------------------

(defun file-etag (file)
  "A cheap, strong ETag for FILE: modification time + size, hex. Both change whenever the
bytes are rewritten, so this distinguishes versions without hashing the content on every
request. Returns a quoted string per the grammar, or NIL if FILE cannot be measured."
  (let ((mtime (ignore-errors (file-write-date file)))
        (size  (ignore-errors (with-open-file (s file :element-type '(unsigned-byte 8))
                                (file-length s)))))
    (when (and mtime size)
      (format nil "\"~(~X~)-~(~X~)\"" mtime size))))

(defun %header (env name)
  "Request header NAME (case-insensitive) from a Clack ENV, or NIL."
  (let ((h (and env (getf env :headers))))
    (and h (gethash (string-downcase name) h))))

(defun %etag-match-p (if-none-match etag)
  "True if IF-NONE-MATCH (a header value) matches ETAG. Handles `*`, comma-separated
lists, and the weak prefix -- `If-None-Match` uses weak comparison, so `W/\"x\"` and
`\"x\"` are the same entity."
  (let ((candidates (or if-none-match "")))
    (flet ((normalize (tag)
             (let ((tag (string-trim " " tag)))
               (if (and (> (length tag) 2) (string= "W/" (subseq tag 0 2)))
                   (subseq tag 2)
                   tag))))
      (or (string= "*" (string-trim " " candidates))
          (and etag
               (loop for start = 0 then (1+ comma)
                     for comma = (position #\, candidates :start start)
                     for piece = (subseq candidates start (or comma (length candidates)))
                     thereis (string= (normalize piece) (normalize etag))
                     while comma))))))

(defun not-modified-p (env etag last-modified)
  "True when ENV's conditional headers say the client's copy is still current.
Per RFC 9110 `If-None-Match` wins outright when present -- an ETag is an exact identity
check, while a date has one-second resolution and cannot see two writes in the same
second, so a stale date must not override a fresh tag."
  (let ((inm (%header env "if-none-match")))
    (if inm
        (%etag-match-p inm etag)
        (let ((since (parse-http-date (%header env "if-modified-since"))))
          (and since last-modified (<= last-modified since))))))

;;; --- serving ---------------------------------------------------------------

(defun %safe-relative (path-info)
  "URL PATH-INFO -> a safe relative pathname, or NIL if empty or escaping (`..`)."
  (let ((clean (string-left-trim "/" path-info)))
    (when (and (plusp (length clean))
               (not (search ".." clean)))
      (ignore-errors (uiop:parse-unix-namestring clean)))))

(defun file-response (root path-info &key env (cache-control *cache-control*))
  "Serve the file under ROOT (a directory) named by URL PATH-INFO. Returns a Clack
response list, or NIL if PATH-INFO does not resolve to a readable regular file within
ROOT (so the caller can fall through to a 404).

The response carries `ETag`, `Last-Modified`, and `Cache-Control` (CACHE-CONTROL, default
*CACHE-CONTROL*; NIL omits it -- pass *IMMUTABLE-CACHE-CONTROL* for fingerprinted URLs).

Pass ENV -- the Clack request plist -- to honor conditional requests: when the client's
validators still match, the result is `304` with no body. Called without ENV the behaviour
is unchanged apart from the new headers, so existing two-argument callers keep working."
  (let ((rel (%safe-relative path-info)))
    (when rel
      (let ((file (merge-pathnames rel (truename root))))
        (when (and (uiop:file-exists-p file)
                   (not (uiop:directory-exists-p file)))
          (let* ((file (truename file))
                 (mtime (ignore-errors (file-write-date file)))
                 (etag (file-etag file))
                 (headers (append (when etag (list :etag etag))
                                  (when mtime (list :last-modified (http-date mtime)))
                                  (when cache-control (list :cache-control cache-control)))))
            (if (not-modified-p env etag mtime)
                ;; 304 repeats the validators and the policy, and carries no body --
                ;; that is the entire point of the exchange.
                (list 304 headers nil)
                ;; A *pathname* body is the Clack contract for static files: every
                ;; handler (Woo, Hunchentoot) streams it (sendfile) and sets
                ;; Content-Length itself -- no reading the whole file into the image.
                (list 200
                      (list* :content-type (content-type-for file) headers)
                      file))))))))
