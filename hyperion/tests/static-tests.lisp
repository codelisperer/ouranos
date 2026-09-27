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

;;; --- what is not served (#296) ---------------------------------------------------

(defmacro with-deny-root ((root) &body body)
  `(with-static-root (,root ("app.css" "body{}")
                            ("img/logo.png" "png")
                            (".env" "SECRET=1")
                            (".git/config" "[core]")
                            ("seed/users.json" "[]")
                            ("db/schema.sql" "create table t ();")
                            ("notes.txt~" "draft")
                            ("data/public.json" "{}")
                            ("data/private.json" "{}"))
     ,@body))

(defun %served-p (root path &rest keys)
  (let ((r (apply #'static:file-response root path keys)))
    (and r (= 200 (first r)))))

(test dotfiles-and-well-known-private-names-are-not-served
  "#296: a file under the static root is not public by accident. The defaults refuse
dotfiles, dot-directories, SQL and backup copies. Control: an ordinary asset is served, in the
root and in a subdirectory."
  (with-deny-root (root)
    (dolist (path '("/.env" "/.git/config" "/db/schema.sql" "/notes.txt~"))
      (is-false (%served-p root path) "~A was served" path))
    (is-true (%served-p root "/app.css"))
    (is-true (%served-p root "/img/logo.png"))
    (is-true (%served-p root "/seed/users.json") "not denied by default")))

(test well-known-is-public-but-a-dotfile-inside-it-is-not
  "/.well-known/ is public by definition (RFC 8615): ACME challenges and security.txt are
served from it, so the dotfile rule does not refuse it. A dotfile inside it is still refused,
and so is a .well-known directory anywhere but the root."
  (with-static-root (root (".well-known/security.txt" "Contact: x")
                          (".well-known/.secret" "x")
                          (".well-known/debug.log" "x")
                          ("a/.well-known/x.txt" "x"))
    (is-true (%served-p root "/.well-known/security.txt"))
    ;; review of #313: only the dotfile rule spares the directory; other patterns still apply
    (is-false (%served-p root "/.well-known/debug.log"))
    (is-false (%served-p root "/.well-known/security.txt" :deny '("*.txt")))
    (is-false (%served-p root "/.well-known/.secret"))
    (is-false (%served-p root "/a/.well-known/x.txt"))))

(test an-app-denied-prefix-is-not-served-and-the-defaults-still-apply
  "The app's :DENY adds to the defaults rather than replacing them."
  (with-deny-root (root)
    (let ((deny '("seed/" "data/private.json")))
      (is-false (%served-p root "/seed/users.json" :deny deny))
      (is-false (%served-p root "/data/private.json" :deny deny))
      (is-false (%served-p root "/.env" :deny deny) "the defaults still apply")
      (is-true (%served-p root "/data/public.json" :deny deny))
      (is-true (%served-p root "/app.css" :deny deny)))))

(test a-denied-path-cannot-be-reached-by-case-or-a-trailing-dot
  "macOS and Windows file systems ignore case, and Windows opens `schema.sql.' as `schema.sql',
so neither may be a way past a pattern. Checked by the matcher, since whether the file opens
under those names depends on the host's file system."
  (dolist (path '("DB/SCHEMA.SQL" "db/schema.sql." "db/schema.sql " "SEED/users.json"
                  ".ENV" "a/.GIT/config" "db/schema.sql::$DATA"))
    (is (static:denied-by path (append static:*default-deny* '("seed/")))
        "~S was not denied" path))
  (is (null (static:denied-by "img/logo.png" (append static:*default-deny* '("seed/")))))
  (is (null (static:denied-by "seedling/a.png" '("seed/")))
      "a prefix matches a whole directory name, not the start of one"))

(test allow-serves-only-the-listed-prefixes
  "With :ALLOW, only paths under those prefixes are served, and the deny patterns still apply
inside them."
  (with-deny-root (root)
    (is-true (%served-p root "/img/logo.png" :allow '("img/")))
    (is-false (%served-p root "/app.css" :allow '("img/")))
    (is-false (%served-p root "/data/public.json" :allow '("img/")))
    (is (eq :outside-allow (static:denied-by "imgs/x.png" '() :allow '("img/"))))))

(test a-symbolic-link-out-of-the-root-is-not-served
  "A link under the root may point anywhere; what is served must resolve under the root.
Control: a link to a file inside the root is served."
  #+os-windows (skip "symbolic links need a privilege on Windows")
  #-os-windows
  (with-static-root (root ("app.css" "body{}"))
    (with-static-root (outside ("secret.txt" "outside the root"))
      (uiop:run-program (list "ln" "-s" (namestring (merge-pathnames "secret.txt" outside))
                              (namestring (merge-pathnames "leak.txt" root))))
      (uiop:run-program (list "ln" "-s" (namestring (merge-pathnames "app.css" root))
                              (namestring (merge-pathnames "alias.css" root))))
      (is-false (%served-p root "/leak.txt"))
      (is-true (%served-p root "/alias.css")))))

(test the-static-handler-logs-its-rules-once-and-serves-through-them
  "The effective rules are logged once, when the handler is made, and not per request."
  (with-deny-root (root)
    (let (handler)
      (let ((out (%log-capture :info
                               (lambda ()
                                 (setf handler (static:make-static-handler root :deny '("seed/")))
                                 (funcall handler (list :path-info "/app.css"))
                                 (funcall handler (list :path-info "/.env"))))))
        (is (= 1 (count-matches "static: serving files" out)) "~A" out)
        (is (search "seed/" out))
        (is (search ".*" out)))
      (is (= 200 (first (funcall handler (list :path-info "/app.css")))))
      ;; review of #313: defaults bound only around construction are the ones enforced later
      (let ((narrow (let ((static:*default-deny* '("*.css"))) (static:make-static-handler root))))
        (is (null (funcall narrow (list :path-info "/app.css"))))
        (is (= 200 (first (funcall narrow (list :path-info "/.env"))))
            "the narrowed defaults replaced the usual ones for this handler"))
      (is (null (funcall handler (list :path-info "/seed/users.json"))))
      (is (null (funcall handler (list :path-info "/.env")))))))

(defun count-matches (needle haystack)
  (loop with start = 0
        for at = (search needle haystack :start2 start)
        while at count t do (setf start (1+ at))))
