;;;; static-tests.lisp --- static file serving: content types, traversal, caching.
;;;;
;;;; The caching tests are the point: a second request carrying the validators the first
;;;; response handed out must come back 304 with no body. That round trip is what saves
;;;; the bandwidth, and it is easy to break silently, so it is asserted end to end
;;;; against real files in a temp directory.

(in-package #:hyperion/tests)

(def-suite static :description "Static file responses: types, safety, caching." :in hyperion)
(in-suite static)

(defmacro with-static-root ((root &rest files) &body body)
  "Bind ROOT to a fresh temp directory containing FILES -- each (relative-name contents)."
  (let ((dir (gensym)) (name (gensym)) (contents (gensym)))
    ;; Not the time and a counter: two processes started in the same second share those, and
    ;; would share the directory (#515).
    `(let ((,dir (aion/fs:make-temporary-directory "hyperion-static-test")))
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
         (ignore-errors (aion/fs:delete-tree ,dir))))))

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

(defun %body-text (body)
  "The octets of a static response's BODY, as a latin-1 string: a function is called with a
writer that collects them, a stream is read to its end and closed."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (etypecase body
      (function (funcall body (lambda (chunk)
                                (loop for octet across chunk do (vector-push-extend octet out)))))
      (stream (unwind-protect
                   (loop for octet = (read-byte body nil) while octet
                         do (vector-push-extend octet out))
                (close body))))
    (map 'string #'code-char out)))

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

(test serves-an-existing-file-as-its-open-stream
  "The body is the open octet stream of the file that was checked (#314), not a pathname for
the server to open again, and it holds the file's bytes."
  (with-static-root (root ("ok.txt" "fine"))
    (let ((r (static:file-response root "/ok.txt")))
      (is (= 200 (first r)))
      (is (typep (third r) 'file-stream))                         ; streamed, not slurped
      (is (equal '(unsigned-byte 8) (stream-element-type (third r))))
      (is (string= "fine" (%body-text (third r))))
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

(defun %backslash-sibling (root)
  "A new directory beside ROOT whose native name is ROOT's followed by a backslash and
\"outside\", holding page.txt. On Linux and macOS a backslash is a filename character, so
this directory is outside ROOT although its name starts with ROOT's."
  (let ((dir (sb-ext:parse-native-namestring
              (concatenate 'string (string-right-trim "/" (sb-ext:native-namestring root))
                           "\\outside/"))))
    (ensure-directories-exist dir)
    (with-open-file (s (merge-pathnames "page.txt" dir) :direction :output :if-exists :supersede)
      (write-string "outside the root" s))
    dir))

(test a-directory-swapped-for-a-link-after-the-check-is-not-followed
  "#314. The path is checked, then a directory on it is replaced by a link to a directory
outside the root, then the file is opened. The file opened is outside the root, so nothing is
served. The swap is made between the check and the open by wrapping %OPEN-INSIDE, which is
where the file is opened. Two outside directories: one elsewhere, and one beside the root whose
name is the root's followed by a backslash, which a check that took a backslash for a separator
read as inside (Copilot's review of #684). Control: with the check of the opened handle made
to accept anything, the same swap serves the outside file, so the test can see the gap it
closes."
  #+os-windows (skip "symbolic links need a privilege on Windows")
  #-os-windows
  (flet ((swap-then (root outside)
           ;; sub/ becomes a link to OUTSIDE, which has a file of the same name.
           (let ((sub (merge-pathnames "sub/" root)))
             (when (probe-file (merge-pathnames "sub/page.txt" root))
               (rename-file (merge-pathnames "sub/page.txt" root)
                            (merge-pathnames "moved-page.txt" root))
               (uiop:delete-empty-directory sub)
               (uiop:run-program (list "ln" "-s"
                                       (string-right-trim "/" (sb-ext:native-namestring outside))
                                       (string-right-trim "/" (namestring sub))))))))
    (dolist (sibling '(nil t))
      (dolist (control '(nil t))
        (with-static-root (root ("sub/page.txt" "inside the root"))
          (with-static-root (elsewhere ("page.txt" "outside the root"))
            (let ((outside (if sibling (%backslash-sibling root) elsewhere))
                  (open-inside (fdefinition 'static::%open-inside))
                  (path-inside-p (fdefinition 'static::%path-inside-p)))
              (unwind-protect
                   (progn
                     (setf (fdefinition 'static::%open-inside)
                           (lambda (file root-real)
                             (swap-then root outside)
                             (funcall open-inside file root-real)))
                     (when control
                       (setf (fdefinition 'static::%path-inside-p) (constantly t)))
                     (let ((r (static:file-response root "/sub/page.txt")))
                       (if control
                           (is (and r (string= "outside the root" (%body-text (third r))))
                               "control (~:[elsewhere~;backslash sibling~]): without the handle check the outside file is served"
                               sibling)
                           (is (null r) "a file outside the root (~:[elsewhere~;backslash sibling~]) was served: ~S"
                               sibling (and r (%body-text (third r)))))))
                (setf (fdefinition 'static::%open-inside) open-inside
                      (fdefinition 'static::%path-inside-p) path-inside-p)
                (when sibling
                  (ignore-errors (delete-file (merge-pathnames "page.txt" outside)))
                  (ignore-errors (uiop:delete-empty-directory outside)))))))))))

(test a-backslash-is-a-separator-only-on-windows
  "Copilot's review of #684. On Linux and macOS a backslash is a filename character, so a path
that continues ROOT's name with a backslash is a sibling of ROOT, not inside it. On Windows it
is a separator. Control: a path continuing with / is inside on every platform."
  (is-true (static::%path-inside-p "/srv/public/page.txt" "/srv/public"))
  (is-true (static::%path-inside-p "/srv/public/page.txt" "/srv/public/"))
  #-win32 (is-false (static::%path-inside-p "/srv/public\\outside/page.txt" "/srv/public"))
  #+win32 (is-true (static::%path-inside-p "C:\\srv\\public\\page.txt" "C:\\srv\\public\\")))

(test a-static-file-is-served-on-hunchentoot-with-its-length
  "#314. A static file's body is an open stream, which no Clack backend takes. Through the
shim, Hunchentoot sends its bytes with the Content-Length measured from the stream."
  (with-static-root (root ("ok.txt" "fine, from disk"))
    (let* ((app (lambda (env)
                  (or (static:file-response root (getf env :path-info) :env env)
                      (list 404 nil (list "not found")))))
           (port nil)
           (handler (ports:call-with-port
                     (lambda (p)
                       (prog1 (srv:start app :port p :server :hunchentoot)
                         (setf port p))))))
      (unwind-protect
           (progn
             (is-true (%srv-await (lambda () (ports:listening-p port))) "backend came up")
             (let ((r (%srv-http-get port "/ok.txt")))
               (is-true (search "200" r) "~S" r)
               (is-true (search (format nil "Content-Length: 15~C~C" #\Return #\Linefeed) r)
                        "~S" r)
               (is (string= "fine, from disk"
                            (subseq r (+ 4 (search (format nil "~C~C~C~C" #\Return #\Linefeed
                                                           #\Return #\Linefeed)
                                                   r)))))))
        (ignore-errors (srv:stop handler))))))

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
