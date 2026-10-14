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
;;;;
;;;; What is not served (#296). Everything under the root used to be public apart from `..'.
;;;; An app that kept a seed file, a SQL dump or a `.env' beside its assets published it. Now
;;;; a path is refused when any pattern in *DEFAULT-DENY*, or in the app's own :DENY, matches
;;;; it, and when :ALLOW is given, a path outside those prefixes is refused too. Matching
;;;; ignores case, because the file systems of macOS and Windows do, and it trims trailing
;;;; dots and spaces from each part of the path, because Windows opens `schema.sql.' as
;;;; `schema.sql'. A path whose file resolves outside the root, through a symbolic link, is
;;;; refused as well. A refused path gives NIL, like a missing file, so the caller's 404 does
;;;; not tell the client that the file exists.
;;;;
;;;; The file that is checked is the file that is sent (#314). FILE-RESPONSE opens the file,
;;;; reads the real path of what it opened from the open handle, refuses it unless that path
;;;; is inside the root, and returns a body that streams from the same handle. Checking the
;;;; path and letting the server open it later left a gap: a link swapped in between the two
;;;; got the server to send whatever the link pointed to. So the body is the open stream, not
;;;; a pathname: the native server writes it in bounded pieces with its length measured from
;;;; the handle, and hyperion/server's adapter writes it to the Clack backends.

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

;;; --- what is not served (#296) ----------------------------------------------

(defparameter *default-deny*
  '(".*"                                  ; dotfiles and dot-directories: .env, .git/, .htpasswd
    "*~" "*.bak" "*.swp" "*.orig"         ; editor and backup copies
    "*.sql" "*.sqlite" "*.sqlite3" "*.db" ; SQL and database files
    "*.pem" "*.key"                       ; keys and certificates with keys
    "*.log")
  "Patterns FILE-RESPONSE refuses in addition to an app's own :DENY. A pattern without a slash
is matched against every part of the path, so \".*\" refuses \".env\" and \"a/.git/config\".
A pattern ending in a slash refuses that directory under the root and everything in it
(\"seed/\"). Any other pattern is matched against the whole path relative to the root
(\"data/*.json\"). `*' matches any run of characters other than a slash. Matching ignores
case. The directory /.well-known/ at the root is the one exception to matching every part:
it is public by definition (RFC 8615), so \".*\" does not refuse it, though it refuses a
dotfile inside it.")

(defun %glob-match-p (pattern string)
  "Does STRING match PATTERN, where `*' matches any run of characters other than a slash?
Case is ignored."
  (labels ((m (p i)
             (cond ((= p (length pattern)) (= i (length string)))
                   ((char= (char pattern p) #\*)
                    (loop for k from i to (length string)
                          thereis (m (1+ p) k)
                          until (and (< k (length string)) (char= (char string k) #\/))))
                   ((= i (length string)) nil)
                   ((char-equal (char pattern p) (char string i)) (m (1+ p) (1+ i)))
                   (t nil))))
    (m 0 0)))

(defun %path-parts (relative)
  "RELATIVE (a path with forward slashes) as its parts, each with trailing dots and spaces
trimmed, since Windows opens `x.sql.' and `x.sql ' as `x.sql'."
  (mapcar (lambda (part) (string-right-trim ". " part))
          (remove "" (uiop:split-string relative :separator "/") :test #'string=)))

(defun denied-by (relative patterns &key allow)
  "The reason RELATIVE, a path under the static root such as \"seed/users.json\", is not
served: the first of PATTERNS that matches it, :OUTSIDE-ALLOW when ALLOW (a list of directory
prefixes such as \"assets/\") is given and it is under none of them, or :STREAM-NAME when a part
contains a colon (on Windows, a name for an alternate data stream of a file). NIL when it may be
served."
  (let* ((parts (%path-parts relative))
         (joined (format nil "~{~A~^/~}" parts)))
    (cond
      ((some (lambda (part) (find #\: part)) parts) :stream-name)
      ((and allow
            (notany (lambda (prefix)
                      (let ((p (string-right-trim "/" prefix)))
                        (and (> (length joined) (length p))
                             (string-equal p joined :end2 (length p))
                             (char= #\/ (char joined (length p))))))
                    allow))
       :outside-allow)
      (t
       (find-if (lambda (pattern)
                  (cond ((and (plusp (length pattern))
                              (char= #\/ (char pattern (1- (length pattern)))))
                         (let ((p (subseq pattern 0 (1- (length pattern)))))
                           (and (> (length joined) (length p))
                                (string-equal p joined :end2 (length p))
                                (char= #\/ (char joined (length p))))))
                        ((find #\/ pattern) (%glob-match-p pattern joined))
                        (t (some (lambda (part) (%glob-match-p pattern part))
                                 ;; /.well-known/ at the root is public by definition (RFC
                                 ;; 8615: ACME challenges, security.txt), so the dotfile rule
                                 ;; does not refuse that one directory name. Every other
                                 ;; pattern still applies to it, and the dotfile rule still
                                 ;; applies to its files.
                                 (if (and parts (string= pattern ".*")
                                          (string-equal (first parts) ".well-known"))
                                     (rest parts)
                                     parts)))))
                patterns)))))

;;; --- the file that was opened (#314) ----------------------------------------

#+darwin
(defconstant +f-getpath+ 50
  "fcntl's F_GETPATH on macOS: the path of the file an open descriptor refers to.")

(defun %fd-path (fd)
  "The real path of the file that FD, an open descriptor (a HANDLE on Windows), refers to, as a
native namestring; NIL when it cannot be read. Links are already resolved, because it describes
the file that was opened rather than the name it was opened by.

Linux reads /proc/self/fd/FD, macOS asks fcntl with F_GETPATH, and Windows asks
GetFinalPathNameByHandleW. On any other system it is NIL, so nothing is served."
  #+linux
  (sb-unix:unix-readlink (format nil "/proc/self/fd/~D" fd))
  #+darwin
  (sb-alien:with-alien ((buf (array (sb-alien:unsigned 8) 1024)))
    (when (/= -1 (sb-alien:alien-funcall
                  (sb-alien:extern-alien "fcntl"
                                         (function sb-alien:int sb-alien:int sb-alien:int
                                                   &optional (* (array (sb-alien:unsigned 8) 1024))))
                  fd +f-getpath+ (sb-alien:addr buf)))
      (let ((end (or (loop for i below 1024 when (zerop (sb-alien:deref buf i)) return i) 1024)))
        (sb-ext:octets-to-string
         (let ((octets (make-array end :element-type '(unsigned-byte 8))))
           (dotimes (i end octets) (setf (aref octets i) (sb-alien:deref buf i))))
         :external-format :utf-8))))
  #+win32
  (sb-alien:with-alien ((buf (array (sb-alien:unsigned 16) 1024)))
    (let ((n (sb-alien:alien-funcall
              (sb-alien:extern-alien "GetFinalPathNameByHandleW"
                                     (function (sb-alien:unsigned 32) (sb-alien:signed 64)
                                               (* (array (sb-alien:unsigned 16) 1024))
                                               (sb-alien:unsigned 32) (sb-alien:unsigned 32)))
              fd (sb-alien:addr buf) 1024 0)))
      (when (< 0 n 1024)
        (let* ((octets (make-array (* 2 n) :element-type '(unsigned-byte 8)))
               (path (progn
                       (dotimes (i n)
                         (let ((unit (sb-alien:deref buf i)))
                           (setf (aref octets (* 2 i)) (ldb (byte 8 0) unit)
                                 (aref octets (1+ (* 2 i))) (ldb (byte 8 8) unit))))
                       (sb-ext:octets-to-string octets :external-format :utf-16le))))
          ;; The answer is in the \\?\ form: \\?\C:\dir\file, or \\?\UNC\server\share\file
          ;; for a network path. Without the prefix it reads as a NATIVE-NAMESTRING does.
          (cond ((eql 0 (search "\\\\?\\UNC\\" path)) (concatenate 'string "\\\\" (subseq path 8)))
                ((eql 0 (search "\\\\?\\" path)) (subseq path 4))
                (t path))))))
  #-(or linux darwin win32)
  (progn fd nil))

(defun %root-real-path (base)
  "The real path of the directory BASE (a truename), as %FD-PATH would give it for a file
inside, so the two compare. On Linux and macOS it is read from an open descriptor of the
directory, so a difference in letter case or in Unicode normalisation between the name the app
gave and the name on disk cannot make a file inside read as outside. On Windows a directory
cannot be opened without other flags, so it is BASE's native namestring, and the comparison
ignores letter case there."
  #+(or linux darwin)
  (let ((fd (sb-unix:unix-open (sb-ext:native-namestring base) sb-unix:o_rdonly 0)))
    (when fd
      (unwind-protect (%fd-path fd)
        (sb-unix:unix-close fd))))
  #-(or linux darwin)
  (sb-ext:native-namestring base))

(defparameter +path-separators+ #+win32 "/\\" #-win32 "/"
  "The characters that separate directories in a native namestring. Only / on Linux and
macOS, where a backslash is an ordinary filename character: /srv/public\\outside is a sibling
of /srv/public, not a file inside it.")

(defun %path-inside-p (path root)
  "Whether the native namestring PATH names something inside the directory ROOT (a native
namestring, with or without a trailing separator), and is not ROOT itself. The character after
ROOT must be one of +PATH-SEPARATORS+."
  (let ((dir (string-right-trim +path-separators+ root)))
    (and (> (length path) (1+ (length dir)))
         (#+win32 string-equal #-win32 string= dir path :end2 (length dir))
         (find (char path (length dir)) +path-separators+))))

(defun %open-inside (file root-real)
  "FILE opened for reading octets, and the real path of what was opened, when that path is
inside ROOT-REAL; otherwise NIL, with nothing left open."
  (let ((stream (ignore-errors
                 (open file :element-type '(unsigned-byte 8) :if-does-not-exist nil))))
    (when stream
      (let ((real (ignore-errors (%fd-path (sb-sys:fd-stream-fd stream)))))
        (if (and real root-real (%path-inside-p real root-real))
            (values stream real)
            (progn (close stream) nil))))))

(defun %etag-of (mtime size)
  (format nil "\"~(~X~)-~(~X~)\"" mtime size))

;;; --- serving ---------------------------------------------------------------

(defun %safe-relative (path-info)
  "URL PATH-INFO -> a safe relative pathname, or NIL if empty or escaping (`..`)."
  (let ((clean (string-left-trim "/" path-info)))
    (when (and (plusp (length clean))
               (not (search ".." clean)))
      (ignore-errors (uiop:parse-unix-namestring clean)))))

(defun file-response (root path-info &key env (cache-control *cache-control*) deny allow)
  "Serve the file under ROOT (a directory) named by URL PATH-INFO. Returns a Clack
response list, or NIL if PATH-INFO does not resolve to a readable regular file within
ROOT (so the caller can fall through to a 404).

NIL too when the path is not to be served (#296): when a pattern in *DEFAULT-DENY* or in DENY
matches it, when ALLOW is given and it is under none of those prefixes, or when its file
resolves outside ROOT. See DENIED-BY for the patterns.

The body is the file's open octet input stream, the handle that was checked (#314). The file
is opened here and the real path of what was opened is checked against ROOT, so a link
swapped in after the path was resolved is not followed. The server measures the length from
the stream and closes it once written; a stream nobody writes is closed when it is garbage
collected, by the finalizer SBCL's OPEN registers. A 304 closes it at once.

The response carries `ETag`, `Last-Modified`, and `Cache-Control` (CACHE-CONTROL, default
*CACHE-CONTROL*; NIL omits it -- pass *IMMUTABLE-CACHE-CONTROL* for fingerprinted URLs).

Pass ENV -- the Clack request plist -- to honor conditional requests: when the client's
validators still match, the result is `304` with no body. Called without ENV the behaviour
is unchanged apart from the new headers, so existing two-argument callers keep working."
  (let ((rel (%safe-relative path-info)))
    (when (and rel
               (not (denied-by (string-left-trim "/" path-info)
                               (append *default-deny* deny) :allow allow)))
      (let* ((base (truename root))
             (file (merge-pathnames rel base)))
        (when (and (uiop:file-exists-p file)
                   (not (uiop:directory-exists-p file))
                   ;; Resolved, the file must still be under the root: a symbolic link
                   ;; under it may point anywhere. This refuses before anything is opened;
                   ;; %OPEN-INSIDE checks again what was actually opened.
                   (uiop:subpathp (truename file) base))
          (multiple-value-bind (stream real) (%open-inside (truename file) (%root-real-path base))
            (when stream
              (let* ((size (file-length stream))
                     (mtime (ignore-errors (file-write-date (sb-ext:parse-native-namestring real))))
                     (etag (and mtime (%etag-of mtime size)))
                     (headers (append (when etag (list :etag etag))
                                      (when mtime (list :last-modified (http-date mtime)))
                                      (when cache-control (list :cache-control cache-control)))))
                (cond
                  ((not-modified-p env etag mtime)
                   (close stream)
                   ;; 304 repeats the validators and the policy, and carries no body --
                   ;; that is the entire point of the exchange.
                   (list 304 headers nil))
                  (t
                   ;; The open stream is the body, so what is sent is what was checked.
                   ;; No Content-Length here: each server measures it from the stream.
                   (list 200
                         (list* :content-type (content-type-for file) headers)
                         stream)))))))))))

(defun make-static-handler (root &key deny allow (cache-control *cache-control*))
  "A function of a Clack env that serves ROOT's files by the env's PATH-INFO through
FILE-RESPONSE with DENY, ALLOW and CACHE-CONTROL, and returns NIL for anything not served, so
the caller falls through to its 404.

It logs the effective rules once, here, the way CSRF exemptions are logged (#296): the root,
every pattern refused (the defaults and DENY), and ALLOW when given."
  ;; The defaults are captured here, once, so the rules this logs are the rules it enforces
  ;; even when the caller bound *DEFAULT-DENY* only around this call.
  (let* ((defaults *default-deny*)
         (patterns (append defaults deny))
         (allow (copy-list allow)))
    (log:info "static: serving files" :root (namestring (truename root))
                                      :deny patterns :allow allow)
    (lambda (env)
      (let ((*default-deny* defaults))
        (file-response root (or (getf env :path-info) "") :env env :cache-control cache-control
                                                           :deny deny :allow allow)))))
