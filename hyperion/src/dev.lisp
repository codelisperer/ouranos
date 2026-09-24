;;;; dev.lisp --- the hot-reload dev loop ("Figwheel for CL").
;;;;
;;;; Hyperion's signature feature. WATCH takes a BUILDER thunk that returns a
;;;; fresh Clack handler; the builder closes over *persistent* state, so rebuilding
;;;; the server never touches it -- edit a source file, save, and the watcher
;;;; recompiles it and rebuilds the server around the SAME state, then refreshes
;;;; :dev browser tabs (they poll *reload-epoch* via mark-reloaded). A compile
;;;; error becomes a browser overlay string (served via dev-error) rather than
;;;; only a REPL message. State != server.
;;;;
;;;; Extracted from praxeon/src/web.lisp; generalized so WATCH is framework-neutral
;;;; (the caller supplies :paths, or a :system whose src/ to watch, else cwd).

(in-package #:hyperion/dev)

;;; --- Dev reload epoch (browser auto-refresh) ------------------------------
;;; A page started with :dev polls /api/reload-epoch and reloads itself when the
;;; epoch changes. defvar: survives reloading this file into a live image.
(defvar *reload-epoch* 0)

(defun mark-reloaded ()
  "Bump the dev reload epoch; dev pages (started with :dev) auto-refresh.
Call this after you recompile render/handler code into a running server."
  (incf *reload-epoch*))

;;; --- The watcher ----------------------------------------------------------
(defvar *dev* nil "The active dev watcher, if any (see WATCH).")

(defvar *watch-excluded-directories*
  '(".git" ".hg" ".svn" "vendor" "dist" "node_modules" ".cache" "target" ".vscode")
  "Directory NAMES pruned from the watch walk, at any depth. Pruning a subtree is the
poller's biggest saving, and these are the ones that are large, machine-written, or both.")

(defvar *watch-excluded-types*
  '("fasl" "fas" "lib" "o" "so" "dylib" "dll" "a" "log" "db" "sqlite" "sqlite3")
  "Pathname TYPES (extensions, no dot, lowercase) that never trigger a reload.

`fasl` is the load-bearing entry: it is our own compiler output, written beside the source,
and watching it makes the reload loop feed itself.")

(defstruct (dev (:conc-name dev-))
  builder                                   ; thunk -> a fresh Clack handler
  handler                                   ; the current handler
  paths                                     ; watched source roots (truenames)
  (excluded-dirs *watch-excluded-directories*)   ; pruned subtrees
  (excluded-types *watch-excluded-types*)        ; never-reload extensions
  (interval 0.5)                            ; poll seconds
  snapshot                                  ; namestring -> file-write-date
  thread
  (lock (sb-thread:make-mutex :name "hyperion-dev-reload"))
  (running t)
  last-error)                               ; last compile error string, or NIL

;;; --- what is watched ------------------------------------------------------
;;;
;;; The watcher used to glob **/*.lisp, so editing a stylesheet, a template or a data file
;;; refreshed nothing and the page silently went stale (pre-publication issue 134). It now watches EVERYTHING
;;; under the roots and excludes by denylist, because an allowlist re-breaks the day
;;; somebody introduces a file type -- and it re-breaks silently, which is the same failure
;;; the original glob had.
;;;
;;; The exclusions are mostly DIRECTORIES on purpose. This is a poller: its cost is walking
;;; and stat-ing the tree every interval, so pruning a subtree is worth far more than
;;; skipping a suffix, and vendor/ or .git/ can be larger than the source it is next to.
;;;
;;; ONE EXCLUSION IS FOR TERMINATION, NOT TIDINESS. compile-file writes its fasl beside the
;;; source, so watching everything means watching our own output: an edit triggers a
;;; recompile, the recompile writes a fasl, the fasl is a change, and that triggers another
;;; reload. A loop that feeds itself, and one that presents as a hot-reload bug rather than
;;; a watcher bug. Compiled output must stay excluded.

(defun %editor-noise-p (name)
  "True for the scratch files editors leave beside a real one. They appear and vanish on
every save, so watching them means reloading twice per keystroke-flush."
  (let ((n (file-namestring name)))
    (or (string= n ".DS_Store")
        (and (plusp (length n)) (char= #\~ (char n (1- (length n)))))          ; foo.lisp~
        (and (> (length n) 2) (string= ".#" (subseq n 0 2)))                    ; .#foo.lisp
        (and (> (length n) 2) (char= #\# (char n 0))
             (char= #\# (char n (1- (length n))))))))                          ; #foo.lisp#

(defun %excluded-file-p (path types)
  (let ((type (pathname-type path)))
    (or (and type (member (string-downcase type) types :test #'string=) t)
        (%editor-noise-p path))))

(defun %walk-files (root excluded-dirs excluded-types)
  "Every file under ROOT, recursively, pruning excluded directories and files.

Walks with uiop:subdirectories rather than a `**/*.*` glob precisely so a directory can be
PRUNED: a glob visits everything and then filters, which does the expensive part first."
  (let ((out '()))
    (labels ((walk (dir)
               (dolist (f (ignore-errors (uiop:directory-files dir)))
                 (unless (%excluded-file-p f excluded-types)
                   (push (namestring f) out)))
               (dolist (sub (ignore-errors (uiop:subdirectories dir)))
                 (let ((name (car (last (pathname-directory sub)))))
                   (unless (and (stringp name)
                                (member name excluded-dirs :test #'string-equal))
                     (walk sub))))))
      (walk root))
    out))

(defun %watched-files (roots &key (excluded-dirs *watch-excluded-directories*)
                                  (excluded-types *watch-excluded-types*))
  "All watched files (recursively) under ROOTS, as namestrings."
  (let ((files '()))
    (dolist (root roots (delete-duplicates files :test #'equal))
      (when (probe-file root)
        (setf files (nconc (%walk-files (truename root) excluded-dirs excluded-types)
                           files))))))

(defun %lisp-file-p (path)
  "True when PATH is Lisp source -- the only thing COMPILE-FILE should ever be handed."
  (let ((type (pathname-type path)))
    (and type (member (string-downcase type) '("lisp" "lsp" "cl") :test #'string=) t)))

(defun %snapshot (roots &key (excluded-dirs *watch-excluded-directories*)
                             (excluded-types *watch-excluded-types*))
  (let ((h (make-hash-table :test 'equal)))
    (dolist (f (%watched-files roots :excluded-dirs excluded-dirs
                                     :excluded-types excluded-types)
             h)
      (let ((d (ignore-errors (file-write-date f))))
        (when d (setf (gethash f h) d))))))

(defun %changed-files (old new)
  "Files in NEW that are new or newer than in OLD."
  (let ((changed '()))
    (maphash (lambda (f date)
               (let ((prev (and old (gethash f old))))
                 (when (or (null prev) (> date prev)) (push f changed))))
             new)
    changed))

(defparameter +layout-change-marker+ "change in instance length"
  "The text SBCL puts in the warning it signals when a DEFSTRUCT / DEFCLASS is redefined
with a different instance layout.

Matching on wording is ordinarily a bad idea; here it is the best available signal and the
tree is SBCL-exclusive by design, so there is exactly one wording to track. It also fails
OPEN -- if SBCL ever rephrases this, detection stops and nothing else breaks. The test that
triggers a real incompatible redefinition is what keeps that from happening silently.")

(defun %redefined-type-name (condition)
  "The class name from a layout-change warning, or NIL if CONDITION is not one.
SBCL's text reads: \"change in instance length of class VIEW: ...\"."
  (let ((text (princ-to-string condition)))
    (when (search +layout-change-marker+ text)
      (let ((p (search "of class " text)))
        (if p
            (let* ((start (+ p (length "of class ")))
                   (end (or (position-if (lambda (c) (member c '(#\: #\Space #\Newline)))
                                         text :start start)
                            (length text))))
              (subseq text start end))
            "a type")))))

(defun %recompile (files)
  "Compile+load FILES (sorted). Return (VALUES ERROR-STRING REDEFINED-TYPES): ERROR-STRING
is NIL on success, else the compiler's own diagnostics -- so the browser overlay shows what
is actually wrong, not just which file. Diagnostics still echo to the REPL.

REDEFINED-TYPES names any type whose instance layout CHANGED during this recompile (pre-publication issue 234).
That matters because WATCH recompiles the files that changed and nothing else, so every
unchanged file holding code compiled against the OLD layout is left alone and the image now
holds two incompatible versions of one type. The symptom reads as a contradiction --

    The value #S(APP:VIEW :ID :SUBMISSIONS ...) is not of type APP:VIEW

-- routes through the stale half answer 500 while the code compiles cleanly and the suite
passes, because a fresh image only ever has one layout and cannot reproduce it. Worse, it
SELF-HEALS once the last dependent is recompiled, so an unrelated edit minutes later clears
it and the whole thing reads as intermittent. That is what costs the afternoon, not the
error message. Detecting it turns all of that into one line."
  (let ((redefined '()))
    (values
     (handler-case
      (dolist (f (sort (copy-list files) #'string<) nil)
        (let ((diag (make-string-output-stream)))
          (multiple-value-bind (out warnp failp)
              (let ((*error-output* (make-broadcast-stream *error-output* diag))
                    (*standard-output* (make-broadcast-stream *standard-output* diag)))
                (compile-file f :verbose nil :print nil))
            (declare (ignore warnp))
            (when (or (null out) failp)
              (let ((text (string-trim '(#\Space #\Newline #\Return)
                                       (get-output-stream-string diag))))
                (error "~A" (if (plusp (length text)) text
                                (format nil "compilation failed: ~A" f)))))
            ;; The layout-change warning is signalled by LOAD, not by COMPILE-FILE: it is
            ;; the moment the new definition replaces the old one in the image.
            (handler-bind ((warning
                             (lambda (c)
                               (let ((name (%redefined-type-name c)))
                                 (when name (pushnew name redefined :test #'string=))))))
              (load out)))))
    (serious-condition (c) (princ-to-string c)))
     (nreverse redefined))))

(defun reload! (&optional (d *dev*))
  "Recompile changed watched files; on success rebuild the server via the builder
(reusing persistent state) and refresh :dev tabs. On failure keep the running
server and record the error. Returns :reloaded / :no-change / :error."
  (when d
    (sb-thread:with-mutex ((dev-lock d))
      (let* ((new (%snapshot (dev-paths d)
                             :excluded-dirs (dev-excluded-dirs d)
                             :excluded-types (dev-excluded-types d)))
             (changed (%changed-files (dev-snapshot d) new))
             ;; Only Lisp is compiled. Everything else -- a stylesheet, a template, a JSON
             ;; fixture -- still rebuilds the server and refreshes the browser, but handing
             ;; it to COMPILE-FILE would put a compile error in the overlay every time
             ;; somebody edited a CSS file, which is a worse bug than the one being fixed.
             (source (remove-if-not #'%lisp-file-p changed))
             (assets (remove-if #'%lisp-file-p changed)))
        (setf (dev-snapshot d) new)
        (cond
          ((null changed) :no-change)
          (t
           (multiple-value-bind (err redefined)
               (if source (%recompile source) (values nil nil))
             ;; pre-publication issue 234: say so, loudly, at the moment it happens. The developer is looking at
             ;; the REPL that just printed the reload line; the alternative is that they
             ;; meet "X is not of type X" with nothing to connect it to.
             (when redefined
               (format *error-output*
                       "~&[dev] REDEFINED TYPE~P: ~{~A~^ ~}~%[dev]   dependents were NOT recompiled -- this image now holds two layouts for the same type.~%[dev]   if you see \"the value #S(...) is not of type ...\", that is this: restart, or ql:quickload the system.~%[dev]   it also SELF-HEALS once the last dependent is recompiled, which is why it looks intermittent.~%"
                       (length redefined) redefined)
               (finish-output *error-output*))
             (cond
               (err
                (setf (dev-last-error d) err)
                (format *error-output* "~&[dev] compile failed:~%~A~%" err)
                :error)
               (t
                (setf (dev-last-error d) nil)
                (when (dev-handler d) (ignore-errors (srv:stop (dev-handler d))))
                (sleep 0.1)
                (handler-case (setf (dev-handler d) (funcall (dev-builder d)))
                  (error (e)
                    (setf (dev-last-error d) (princ-to-string e))
                    (format *error-output* "~&[dev] restart failed: ~A~%" e)
                    (return-from reload! :error)))
                (mark-reloaded)
                (format *error-output* "~&[dev] reloaded~@[ ~{~A~^ ~}~]~@[ (assets: ~{~A~^ ~})~]~%"
                        (mapcar #'file-namestring source)
                        (mapcar #'file-namestring assets))
                :reloaded)))))))))

(defun %watch-loop (d)
  ;; Surface reload errors (don't swallow them -- silent failures are the worst),
  ;; and keep the thread alive across a bad reload. If the loop itself dies, say so.
  (handler-case
      (loop while (dev-running d)
            do (sleep (dev-interval d))
               (when (dev-running d)
                 (handler-case (reload! d)
                   (error (e)
                     (format *error-output* "~&[dev] reload error: ~A~%" e)
                     (finish-output *error-output*)))))
    (error (e)
      (format *error-output* "~&[dev] watcher thread stopped: ~A~%" e)
      (finish-output *error-output*))))

(define-condition invalid-builder (error)
  ((got :initarg :got :reader invalid-builder-got)
   (arity :initarg :arity :initform nil :reader invalid-builder-arity)
   (parameter :initarg :parameter :initform "BUILDER" :reader invalid-builder-parameter))
  (:report
   (lambda (c s)
     (format s "hyperion/dev: ~A must be a THUNK returning a fresh Clack app"
             (invalid-builder-parameter c))
     (when (invalid-builder-arity c)
       (format s ", but got a function of ~D argument~:P" (invalid-builder-arity c))
       (format s " -- which is almost certainly the app itself.")
       (format s "~%~%  wrong:  (serve (make-app) ...)      ; calls it, passes the app")
       (format s "~%  right:  (serve 'make-app ...)       ; passes the builder")
       (format s "~%~%The dev server calls this after every recompile, which is how a rebuilt")
       (format s "~%route table reaches the running server -- so it needs the function, not")
       (format s "~%one result of it."))))
  (:documentation
   "Signalled when SERVE or WATCH is handed something that cannot be a builder (pre-publication issue 235).

Two independent consuming apps wrote `(serve (make-app) ...)', got a bare
\"invalid number of arguments: 0\" from deep inside the watcher, and at least one
concluded that hot reload did not support their kind of app. The framework's own
examples are correct, so nothing was missing -- but a parameter named MAKE-APP, in
applications that conventionally define a function called MAKE-APP, invites exactly that
substitution. Two teams making the identical mistake is an affordance problem, not two
careless readings, which is why this is a guard and not a docstring."))

(defun %required-arg-count (f)
  "How many REQUIRED parameters F takes, or NIL if that cannot be determined.
&optional / &rest / &key are not required, so a builder declaring only those is callable
with zero arguments and is fine."
  (handler-case
      (let ((ll (sb-kernel:%fun-lambda-list f)))
        (if (listp ll)
            (loop for x in ll
                  until (and (symbolp x) (member x lambda-list-keywords))
                  count t)
            nil))
    (error () nil)))

(defun %normalize-builder (builder &optional (parameter "BUILDER"))
  "Validate BUILDER and return the form to keep, fixing two defects in one place because
they are two spellings of one parameter.

pre-publication issue 157 -- a NAMED function object is coerced back to its symbol. `#'build-app' is what the
phrase \"a thunk\" invites and is the obvious thing to write, but it captures the function
object existing at that instant; recompiling the file that defines BUILD-APP makes a NEW
object while the watcher still holds the old one, so every later rebuild is performed by
the pre-edit builder. Only edits to the builder's own BODY are invisible -- everything it
calls by name resolves fresh -- and in a Clack app that body is the dispatcher, so the
symptom is \"everything hot-reloads except adding a route\". FUNCALL on a SYMBOL re-resolves
the current definition every time, which is the behaviour the caller plainly meant.

pre-publication issue 235 -- a function of one or more REQUIRED arguments is refused, because it is the app.

An anonymous thunk passes through untouched: it has no name to re-resolve, and a caller
who wrote one is not describing a definition that can be recompiled."
  (let ((required (and (functionp builder) (%required-arg-count builder))))
    (when (and required (plusp required))
      (error 'invalid-builder :got builder :arity required :parameter parameter)))
  (or (and (functionp builder)
           (let ((name (nth-value 2 (function-lambda-expression builder))))
             (and (symbolp name) name (fboundp name) name)))
      builder))

(defun watch (builder &key paths system systems (interval 0.5)
                           (exclude-directories *watch-excluded-directories*)
                           (exclude-types *watch-excluded-types*))
  "Start a hot-reload dev server. BUILDER is a thunk returning a fresh Clack
handler -- call hyperion/server:start (or an app's start-web) inside it, reusing
*persistent* state so it survives reloads. Watched source roots come from PATHS,
plus SYSTEM's src/ and each of SYSTEMS' src/ (ASDF system names). SYSTEMS is for a
multi-system app -- or for co-developing an app together with a framework (e.g.
watch both your app and \"hyperion\"). With none given, the current directory. On
save, changed files recompile and the server is rebuilt via BUILDER, keeping
state; :dev tabs then refresh.

EVERY file under the roots is watched, not just .lisp -- editing a stylesheet, a template
or a data file rebuilds and refreshes too (pre-publication issue 134). Only Lisp is COMPILED; anything else
rebuilds the server and refreshes the browser without going near the compiler.

EXCLUDE-DIRECTORIES prunes subtrees by name and EXCLUDE-TYPES skips extensions, defaulting
to *WATCH-EXCLUDED-DIRECTORIES* and *WATCH-EXCLUDED-TYPES* (set the specials once for a
project, pass the keyword for one call). Compiled output must stay excluded whatever else
you change: fasls are written beside their sources, so watching them makes a reload trigger
the next reload, forever.

Per-file recompile covers the common case (editing a function). A *structural* change --
adding a file, package, or dependency -- still needs a `ql:quickload` or restart.

REDEFINING A TYPE is the case worth knowing about, and this docstring used to call it \"a
rare framework-hacking move, not everyday app dev\". That was wrong, and the wording was
part of why it went unsuspected: a struct describing a UI element gains a slot routinely,
and one consuming app hit this twice in a single afternoon doing ordinary product work
(pre-publication issue 234). Only the changed file is recompiled, so every unchanged dependent still holds code
compiled against the old layout, and the image ends up with two versions of one type:

    The value #S(APP:VIEW :ID :SUBMISSIONS ...) is not of type APP:VIEW

A VIEW that is not a VIEW. It compiles cleanly, the suite passes (a fresh image has only
one layout), and it SELF-HEALS once the last dependent is recompiled -- so an unrelated
edit clears it and the whole thing reads as intermittent. WATCH now detects the
redefinition and says all of this on the spot; restart or `ql:quickload' when you see it.

Returns the dev handle; stop with UNWATCH."
  (unwatch)
  (setf builder (%normalize-builder builder "BUILDER"))
  (flet ((system-src (s) (merge-pathnames "src/" (asdf:system-source-directory s))))
    (let* ((roots (mapcar #'truename
                          (append paths
                                  (when system (list (system-src system)))
                                  (mapcar #'system-src systems)
                                  (unless (or paths system systems)
                                    (list (uiop:getcwd))))))
           (d (make-dev :builder builder :paths roots :interval interval
                        :excluded-dirs exclude-directories
                        :excluded-types exclude-types)))
      (setf (dev-snapshot d) (%snapshot roots :excluded-dirs exclude-directories
                                              :excluded-types exclude-types))
      ;; *DEV* IS SET BEFORE THE BUILDER RUNS (#159). HYPERION/SERVER:START now returns only
      ;; once the port is listening, so the port can answer a moment before the builder
      ;; returns. Set afterwards, an UNWATCH arriving in that moment found *DEV* NIL and did
      ;; nothing, and a blocking SERVE then never returned. Set first, that UNWATCH clears
      ;; DEV-RUNNING, the watcher below exits at once, and SERVE's cleanup stops the server.
      ;; If the builder fails, *DEV* is put back to what it was, so it does not name a
      ;; server that never ran.
      (let ((previous *dev*) (built nil))
        (setf *dev* d)
        (unwind-protect (progn (setf (dev-handler d) (funcall builder))
                               (setf built t))
          (unless built
            (when (eq *dev* d) (setf *dev* previous)))))
      (setf (dev-thread d)
            ;; THREAD-LIFETIME: independent -- the watcher runs for the life of the dev
            ;; server, not for the call that started it (#158).
            (sb-thread:make-thread (lambda () (%watch-loop d)) :name "hyperion-dev-watch"))
      (format t "~&[dev] watching ~{~A~^ ~} — save any watched file to hot-reload~%"
              (mapcar #'namestring roots))
      ;; pre-publication issue 237: a root with no Lisp under it is almost always a mistake -- :SYSTEM resolved
      ;; somewhere the developer does not work. Cheap to notice, and the watcher would
      ;; otherwise run, print this banner, poll happily, and never fire.
      ;;
      ;; NOTE, because it matters for what this does NOT catch: the reported case was a
      ;; repo whose .asd sits at the root with a POPULATED src/ holding a shared core,
      ;; while the surface being edited lived in desktop/src/. That root has Lisp in it, so
      ;; this warning is silent there. It catches the empty-root case only; the docstring
      ;; below is what addresses the reported one.
      (dolist (r roots)
        (unless (some #'%lisp-file-p
                      (%watched-files (list r) :excluded-dirs exclude-directories
                                               :excluded-types exclude-types))
          (warn "hyperion/dev: watching ~A, which contains no .lisp files.~%If your sources are elsewhere, pass :PATHS -- the watcher will otherwise run and never fire." (namestring r))))
      d)))

(defun unwatch (&optional (d *dev*))
  "Stop the watcher thread and the server it manages."
  (when d
    (setf (dev-running d) nil)
    (when (dev-handler d) (ignore-errors (srv:stop (dev-handler d))))
    (when (eq d *dev*) (setf *dev* nil))
    d))

(defun dev-error ()
  "The current dev reload error string (served at /api/dev-error for the browser
overlay), or NIL when the last reload compiled cleanly."
  (and *dev* (dev-last-error *dev*)))

;;; --- Turnkey dev server: hot-reload as a feature any hyperion app gets -----
;;; WATCH (above) is the engine (recompile-on-save, rebuild around persistent
;;; state). SERVE makes hot-reload *automatic*: it wraps the app so the browser
;;; auto-refreshes with no app-side wiring (WRAP-DEV serves the reload endpoints
;;; and injects the poller <script> into HTML responses), and it ALWAYS watches
;;; hyperion's own src/ in addition to the app's -- so framework edits hot-reload
;;; too. An app's whole dev command becomes (hyperion/dev:serve #'make-app :system
;;; :my-app). Effects (the recompile + the network) stay at this edge; page
;;; rendering is untouched.

(defun %poller-script ()
  "The hot-reload poller as an inline <script> string (compiled once by WRAP-DEV)."
  (format nil "<script>~A</script>" (hjs:dev-reload-js)))

(defun %html-response-p (headers)
  "True when a Clack response HEADERS plist declares an HTML content-type."
  (let ((ct (getf headers :content-type)))
    (and (stringp ct) (search "text/html" ct) t)))

(defun %without-key (plist key)
  "PLIST without KEY (used to drop a now-wrong :content-length after injection)."
  (loop for (k v) on plist by #'cddr unless (eq k key) append (list k v)))

(defun %inject-before-body-close (html script)
  "Insert SCRIPT just before the last </body> in HTML (case-insensitive); append if
there is no </body>."
  (let ((pos (search "</body>" html :from-end t :test #'char-equal)))
    (if pos
        (concatenate 'string (subseq html 0 pos) script (subseq html pos))
        (concatenate 'string html script))))

(defun %maybe-inject (response script)
  "Inject the poller SCRIPT into a Clack RESPONSE that is HTML with a single-string
body; pass anything else (static files, JSON, streamed bodies) through unchanged."
  (if (and (consp response) (consp (cdr response)) (consp (cddr response)))
      (destructuring-bind (status headers body &rest more) response
        (declare (ignore more))
        (if (and (%html-response-p headers)
                 (consp body) (stringp (first body)) (null (rest body)))
            (list status (%without-key headers :content-length)
                  (list (%inject-before-body-close (first body) script)))
            response))
      response))

(defun %escape-html (text)
  "TEXT with the four characters that could break out of the error page escaped."
  (with-output-to-string (o)
    (loop for c across text
          do (case c
               (#\& (write-string "&amp;" o))
               (#\< (write-string "&lt;" o))
               (#\> (write-string "&gt;" o))
               (#\" (write-string "&quot;" o))
               (t (write-char c o))))))

(defun %backtrace-string (&optional (count 25))
  "A backtrace as a string, captured while the stack is still live."
  (handler-case
      (with-output-to-string (s) (sb-debug:print-backtrace :stream s :count count))
    (serious-condition () "")))

(defun %runtime-error-page (condition trace script)
  "A dev error page for an unhandled APPLICATION error -- with the poller in it.

This is the fix for pre-publication issue 233, and the mechanism is not the one the report assumed. The report
read the defect as \"the poller is injected into HTML responses, and a 500 is not one\".
It is not that: %MAYBE-INJECT never looks at the status, so an app that RETURNS a 500 with
an HTML body already gets the poller today. The real case is an app that SIGNALS -- which
is what the compile-error loop actually produces -- and then the condition unwinds straight
PAST WRAP-DEV. There is no response to inject into, the backend renders its own error page,
and hyperion never sees it. So the loop is closed by CATCHING the condition and rendering
the page here, which also means the page can carry a backtrace.

Without this, the first error disconnects that tab from hot reload permanently: the page
has no poller, so it cannot ask whether to reload, so it cannot ever show the recovery. The
server heals, the epoch advances, and the window sits on an error until somebody refreshes
by hand -- which reads as \"hot reload cannot recover from errors\" when in fact it recovers
fine and had no way to say so."
  (list 500
        '(:content-type "text/html; charset=utf-8")
        (list
         (format nil "<!doctype html><html><head><meta charset=\"utf-8\"><title>Application error (dev)</title><style>body{font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;margin:0;padding:2rem;background:#1c1b22;color:#e8e6e3}h1{font-size:1rem;color:#ff7b72;margin:0 0 1rem}pre{white-space:pre-wrap;word-break:break-word;background:#26252d;padding:1rem;border-radius:6px;overflow-x:auto}p{color:#9b9aa3}</style></head><body><h1>~A</h1><pre>~A</pre>~@[<pre>~A</pre>~]<p>hyperion/dev — this page polls for reloads, so fixing the error refreshes it.</p>~A</body></html>"
                 (%escape-html (string (type-of condition)))
                 (%escape-html (princ-to-string condition))
                 (and trace (plusp (length trace)) (%escape-html trace))
                 script))))

(defun %call-app (app env script)
  "Call APP, injecting the poller -- and turning an unhandled condition into a dev error
page that also carries the poller, rather than letting it unwind past WRAP-DEV (pre-publication issue 233).

HANDLER-BIND first, purely to capture the backtrace while the stack is still live;
HANDLER-CASE then does the actual transfer of control. The error is echoed to
*ERROR-OUTPUT* as well, because a browser page is not a log and this must not be the only
place the failure appears."
  (let ((trace nil))
    (handler-case
        (handler-bind ((serious-condition
                         (lambda (c) (declare (ignore c))
                           (setf trace (%backtrace-string)))))
          (%maybe-inject (funcall app env) script))
      (serious-condition (c)
        (format *error-output* "~&[dev] request failed: ~A~%~A~%" c (or trace ""))
        (finish-output *error-output*)
        (%runtime-error-page c trace script)))))

(defparameter +reload-epoch-path+ "/api/reload-epoch"
  "Path the dev poller hits for the reload epoch.")
(defparameter +dev-error-path+ "/api/dev-error"
  "Path the dev poller hits for the last compile error.")

(defun wrap-dev (app)
  "Wrap a Clack APP for dev browser auto-refresh: serve GET /api/reload-epoch and
GET /api/dev-error, and inject the hot-reload poller <script> into HTML responses.
Returns a new Clack app; the app renders nothing special. The poller is compiled
once, here.

These two endpoints are registered as QUIET with hyperion/logging: they are the
framework polling itself on a timer, and at the :debug level a dev REPL normally runs at,
logging them buries the developer's own output -- which is the REPL-driven loop this
framework exists to make pleasant. The dev middleware declares its own routes rather than
the logger hardcoding knowledge of them."
  (hlog:register-quiet-path +reload-epoch-path+)
  (hlog:register-quiet-path +dev-error-path+)
  (let ((script (%poller-script)))
    (lambda (env)
      (let ((path (getf env :path-info)))
        (cond
          ((string= path +reload-epoch-path+)
           (list 200 '(:content-type "text/plain; charset=utf-8")
                 (list (princ-to-string *reload-epoch*))))
          ((string= path +dev-error-path+)
           (list 200 '(:content-type "text/plain; charset=utf-8")
                 (list (or (dev-error) ""))))
          (t (%call-app app env script)))))))

(defun serve (make-app &key paths system systems (port srv:*default-port*)
                            (host "127.0.0.1") (interval 0.5) block)
  "Turnkey hot-reload dev server -- the framework feature. MAKE-APP is a thunk
returning a fresh Clack app (a handler lambda). SERVE wraps it (WRAP-DEV: reload
endpoints + poller injection, so the browser auto-refreshes with no app wiring),
starts the server on PORT/HOST, and watches SYSTEM's src/ AND hyperion's OWN src/
(plus any extra SYSTEMS) -- so app *and* framework edits recompile into the running
image and refresh the page. Returns the dev handle; stop with UNWATCH.

PATHS names extra roots to watch directly, and is passed through to WATCH unchanged. It
exists because SYSTEM resolves to that system's `src/`, which is the right answer for an
app laid out as its own ASDF system and the wrong one for anything else -- notably the
in-tree examples, whose sources sit in `examples/<name>/` with no `src/` beneath them.
Without it those apps cannot adopt SERVE at all and are pushed back to hand-rolling WATCH,
which is the boilerplate SERVE exists to delete (pre-publication issue 132).

:SYSTEM resolves to that system's `src/`. If your sources are NOT there -- a repo whose
.asd sits at the root with surfaces in `desktop/src/` and `web/src/`, say -- :SYSTEM
watches the wrong tree and hot reload appears to work: the watcher starts, the banner
prints, the poller runs, and it never fires for the files you are editing. Use :PATHS.
Read the banner: it names every root, and the roots it names are the whole truth (pre-publication issue 237).

BLOCK parks the calling thread until the watcher stops, and exists because SERVE otherwise
RETURNS -- which is right for the REPL these examples are driven from and a trap for a
command-line entry point. Both consuming apps called SERVE as the last form of a build-tool
target; the function returned, the process exited, and it took the server with it AFTER
printing that it was listening. It printed success. Pass :BLOCK T from any entry point that
is not a REPL form (pre-publication issue 236).

Returns the dev handle -- or, with :BLOCK T, only when the watcher stops."
  (let ((d (watch (let ((make-app (%normalize-builder make-app "MAKE-APP")))
                    (lambda () (srv:start (wrap-dev (funcall make-app))
                                          :port port :host host)))
                  :paths paths
                  :system system
                  :systems (adjoin "hyperion" systems :test #'equal)
                  :interval interval)))
    (when block
      ;; Join the watcher rather than sleeping in a loop: the thread already owns the
      ;; lifetime, so UNWATCH from another thread (or the REPL) ends this wait too. The
      ;; UNWIND-PROTECT means a Ctrl-C out of a blocking entry point still stops the
      ;; server rather than leaving an orphan holding the port.
      (unwind-protect
           (when (dev-thread d) (ignore-errors (sb-thread:join-thread (dev-thread d))))
        (unwatch d)))
    d))
