;;;; desktop.lisp --- turn a Hyperion app into a native desktop window.
;;;;
;;;; The CL half of the desktop capability (ADR-0008): boot Hyperion in-process on a
;;;; free port on 127.0.0.1, then launch a small OUT-OF-PROCESS native webview pointed at
;;;; it (a `webview.h` launcher built per-OS -- see hyperion-view/). HTMX-over-HTTP
;;;; means no in-process JS<->native bridge, so the webview owns its own GUI main thread
;;;; in its own process and the SBCL main-thread/ldb hazard never arises.
;;;;
;;;; Desktop is one UX surface among several (ADR-0009): the embedded local server is the
;;;; DEFAULT, not a hardcode -- :backend (:remote URL) points the webview at a remote
;;;; Hyperion backend instead (the GitHub-Desktop model). SBCL-only (sb-bsd-sockets).

(cl:defpackage #:hyperion/desktop
  (:use #:cl)
  (:local-nicknames (#:platform #:aion/platform)
                    (#:csrf #:hyperion/csrf)
                    (#:log #:aion/log))
  (:documentation
   "Run a Hyperion app as a native desktop window: boot the server in-process on a free
    port on 127.0.0.1, then launch an out-of-process native webview at it (ADR-0008). The
    embedded server is the default; :backend (:remote URL) points at a remote backend
    instead (ADR-0009). SBCL-only.")
  (:export #:run-app #:request-close #:free-port #:wait-until-listening
           #:*launcher* #:default-launcher #:image-directory #:bundled-window-icon
           ;; is this a shipped build, and where is it installed (#416)
           #:shipped-image-p #:install-directory
           #:launcher-not-found #:*remote-backend*))

(in-package #:hyperion/desktop)

;;; --- ports + readiness (sb-bsd-sockets; no extra dependency) ----------------

(defun free-port ()
  "Ask the OS for an unused loopback TCP port: bind to 0, read the assignment, close.
A tiny TOCTOU window remains before the real server binds it -- acceptable for a
local desktop app."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn
           (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
           (sb-bsd-sockets:socket-bind s #(127 0 0 1) 0)
           (nth-value 1 (sb-bsd-sockets:socket-name s)))
      (sb-bsd-sockets:socket-close s))))

(defun wait-until-listening (port &key (timeout 15) (interval 0.05))
  "Poll a TCP connect to 127.0.0.1:PORT until it succeeds (server is up) or TIMEOUT
seconds elapse. Returns T on success, NIL on timeout. Closes the launch race so the
webview never points at a not-yet-listening server."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
        (handler-case
            (progn (sb-bsd-sockets:socket-connect s #(127 0 0 1) port)
                   (sb-bsd-sockets:socket-close s)
                   (return t))
          (error ()
            (ignore-errors (sb-bsd-sockets:socket-close s))
            (when (> (get-internal-real-time) deadline) (return nil))
            (sleep interval)))))))

;;; --- the launcher binary ----------------------------------------------------

(defvar *launcher* nil
  "Explicit path to the hyperion-view binary; NIL lets DEFAULT-LAUNCHER resolve it.")

(defun image-directory ()
  "The directory the RUNNING executable lives in, as an absolute pathname (or NIL).

`aion/platform:executable-directory' is the implementation; this name is kept because it is
exported and because a desktop reader looks for it here. It was MOVED rather than copied
(pre-publication issue 335): hyperion/update needs the same answer to say where a build is installed, and
ADR-0014's packaging argument -- \"there is nothing here that can disagree with the
resolver\" -- holds only while there is one resolver. Two would have drifted in the dark,
since the consumer that breaks is a shipped bundle on a user's machine.

Why not (uiop:argv0), and why sb-ext:*runtime-pathname* is the right question, are recorded
at the implementation."
  (platform:executable-directory))

(defun shipped-image-p ()
  "True when this image is a shipped build of an app, and NIL in a developer's REPL (#416).

A shipped build is one dumped file on Linux; on macOS, a launcher, the runtime `sbcl' and
`sbcl.core' in `<name>.app/Contents/MacOS'; on Windows, `<name>.exe', `sbcl-runtime.exe' and
`sbcl.core'. On macOS and Windows the core is a file of its own, so comparing
SB-EXT:*CORE-PATHNAME* with SB-EXT:*RUNTIME-PATHNAME*, the test for a one-file image, answers
NIL inside a real bundle. The rule is aion/platform:shipped-image-p, which hyperion/update uses
too."
  (platform:shipped-image-p))

(defun install-directory ()
  "Where this shipped build is, as an absolute directory pathname, or NIL when SHIPPED-IMAGE-P is
false (#416): the `.app' on macOS, otherwise the directory the app's files are in.

It is derived from the running image. hyperion/update:install-directory answers the updater's
question instead, and on Windows it reads the installer's registry record first; the two agree
for an installed app that has not been moved."
  (platform:shipped-image-directory))

(defun default-launcher ()
  "Resolve the native webview launcher: *LAUNCHER* if set, else `hyperion-view[.exe]`
beside the running image (how a dumped app ships it), else the copy built in the hyperion
source tree (dev -- run hyperion-view/build.sh once), else the bare name on PATH."
  (or *launcher*
      (let ((exe (if (uiop:os-windows-p) "hyperion-view.exe" "hyperion-view")))
        (or ;; beside the running image -- a shipped/bundled app. MUST win over the dev
            ;; copy below: a distributed bundle has no source tree, and preferring the
            ;; sibling is the whole contract build-desktop-app.lisp relies on.
            (let ((beside (when (image-directory)
                            (merge-pathnames exe (image-directory)))))
              (and beside (probe-file beside) beside))
            ;; dev: the launcher built in-tree (hyperion/hyperion-view/)
            (ignore-errors
              (let ((dev (merge-pathnames
                          (format nil "hyperion-view/~A" exe)
                          (asdf:system-source-directory :hyperion))))
                (and (probe-file dev) dev)))
            ;; last resort: bare name on PATH
            exe))))

(defparameter +window-icon-types+ '("ico" "png" "icns")
  "The extensions BUNDLED-WINDOW-ICON looks for, as scripts/build-desktop-app.lisp names the
copy it carries: `window-icon.<type>'.")

(defun %readable-file (path)
  "PATH's truename when a file can be opened there, or NIL. PROBE-FILE alone is not enough: for
a symbolic link whose target is missing, SBCL returns the link's own path. A macOS bundle keeps
the window icon in Contents/Resources behind such a link, so a bundle that lost the file would
otherwise pass a path hyperion-view cannot read (#74)."
  (let ((found (probe-file path)))
    (and found
         (ignore-errors
          (with-open-file (in found :element-type '(unsigned-byte 8))
            (declare (ignore in))
            t))
         found)))

(defun bundled-window-icon (&optional (dir (image-directory)))
  "The window icon a shipped bundle carries beside its executable, or NIL (#74).

scripts/build-desktop-app.lisp --window-icon copies the icon into the bundle as
`window-icon.<type>'. An app usually names its icon by its path in the source tree, which in
a dumped image is the build machine's path; on anyone else's machine that file does not
exist, and the window got hyperion-view's default icon without any message. The carried copy
is found from the running image's own directory, so it is there wherever the bundle is."
  (and dir
       (some (lambda (type)
               (%readable-file (merge-pathnames (format nil "window-icon.~A" type) dir)))
             +window-icon-types+)))

(defun %icon-arguments (icon &optional (bundled (bundled-window-icon)))
  "The --icon arguments RUN-APP passes the launcher: BUNDLED if a bundle carries one, else ICON
if it names a file that exists, else none.

The bundled copy wins because in a shipped app ICON is usually the build machine's path: it
exists only on the machine that built the app, so preferring it would make the icon depend
on which machine the app runs on. In development there is no bundled copy, and ICON is used."
  (let ((path (or bundled (and icon (%readable-file icon)))))
    (when path (list "--icon" (uiop:native-namestring path)))))

(defun %placement-arguments (placement-file)
  "The --placement-file arguments RUN-APP passes the launcher for PLACEMENT-FILE, or none when it
is NIL (#485). The file's directory is created first: the launcher writes the file, and does not
create directories."
  (when placement-file
    (let ((path (merge-pathnames placement-file)))
      (ensure-directories-exist path)
      (list "--placement-file" (uiop:native-namestring path)))))

(define-condition launcher-not-found (error)
  ((path :initarg :path :reader launcher-not-found-path))
  ;; NB: no FORMAT ~<newline> continuations anywhere -- see the root CLAUDE.md gotcha.
  (:report
   (lambda (c s)
     (format s "hyperion/desktop: the native webview launcher (~A) was not found.~%" (launcher-not-found-path c))
     (format s "It is a per-machine build artifact -- build it once, from hyperion/hyperion-view/:~%")
     (format s "  Windows      .\\build.ps1     (-Check first: reports missing compiler/SDK/runtime)~%")
     (format s "  Linux/macOS  ./build.sh      (--check for the same report)~%")
     (format s "Then retry. Set hyperion/desktop:*launcher* to use a copy from elsewhere, or pass ")
     (format s ":shell :browser to run in the default browser instead.")))
  (:documentation
   "Signalled by RUN-APP before starting anything when :shell :webview is requested but the
    launcher binary cannot be found -- the fresh-machine case (hyperion-view/ not built yet)."))

(defun %program-on-path-p (name)
  "True if NAME resolves on PATH (where/command -v). Used only to turn a missing launcher
into a helpful error instead of an obscure launch failure."
  (ignore-errors
   (zerop (nth-value 2
                     (uiop:run-program
                      (if (uiop:os-windows-p)
                          (list "where" name)
                          (list "sh" "-c" (format nil "command -v ~A" name)))
                      :ignore-error-status t :output nil :error-output nil)))))

(defun %check-launcher (launcher)
  "Signal LAUNCHER-NOT-FOUND unless LAUNCHER exists (as a path, or on PATH). Called up
front so a fresh machine fails with build instructions rather than after booting a server."
  (let ((s (namestring launcher)))
    (unless (or (probe-file s)
                (and (null (pathname-directory (pathname s)))
                     (%program-on-path-p s)))
      (error 'launcher-not-found :path s))
    launcher))

;;; --- shells: native webview, or the default browser (dev) -------------------

(defun open-in-browser (url)
  "Open URL in the OS default browser (the :browser dev shell). Detached -- returns
immediately."
  (cond ((uiop:os-windows-p) (uiop:launch-program (list "cmd" "/c" "start" "" url)))
        ((uiop:os-macosx-p)  (uiop:launch-program (list "open" url)))
        (t                   (uiop:launch-program (list "xdg-open" url)))))

(defun %wait-for-interrupt ()
  "Block until Ctrl-C -- keeps an embedded server alive under the detached :browser shell."
  (handler-case (loop (sleep 3600))
    #+sbcl (sb-sys:interactive-interrupt () nil)))

;;; --- the window's lifetime (#355) -------------------------------------------

(defvar *window* nil
  "The launcher process RUN-APP is waiting on, or NIL. Set globally rather than bound, so that
REQUEST-CLOSE sees it from a server's request thread.")

(defparameter *window-poll-seconds* 0.1
  "How often RUN-APP checks whether the window has closed.")

(defun %end-window (process)
  "Stop the launcher PROCESS if it is still running."
  (when (and process (uiop:process-alive-p process))
    (ignore-errors (uiop:terminate-process process :urgent t))))

(defun %wait-for-window (process)
  "Return when the launcher PROCESS exits. If this is left any other way -- a throw, an error,
or the process exiting from another thread -- the launcher is stopped on the way out, so the
window never outlives its backend.

It polls rather than calling UIOP:WAIT-PROCESS, because a thread blocked in that call cannot
be interrupted. When code on another thread calls SB-EXT:EXIT, SBCL interrupts the main
thread to unwind it and waits up to SB-EXT:*EXIT-TIMEOUT* (60 seconds) for that. Blocked in
the wait, the main thread took the whole 60 seconds on Windows, with the server no longer
answering, and the window stayed open after the process had gone (#355)."
  (setf *window* process)
  (unwind-protect
       (loop while (uiop:process-alive-p process)
             do (sleep *window-poll-seconds*))
    (setf *window* nil)
    (%end-window process)
    (ignore-errors (uiop:wait-process process))))

(defun request-close ()
  "Close the window RUN-APP is showing, so that RUN-APP stops the server and returns. Callable
from any thread, including a request handler, which is how an app closes itself: the desktop
Coalton REPL calls it when the user types (exit). Returns T if there was a window to close."
  (let ((window *window*))
    (when (and window (uiop:process-alive-p window))
      (%end-window window)
      t)))

;;; --- lifecycle --------------------------------------------------------------

(defvar *remote-backend* nil
  "Under :backend (:hybrid URL), the remote data-API base URL the app calls out to
(ADR-0009). The local surface still runs embedded; the app reads this to reach the
remote contract.")

(defun %guard (app origin request-guard)
  "APP wrapped in the CSRF defence REQUEST-GUARD names, for an app served from ORIGIN.

:SAME-ORIGIN (the default) is HYPERION/CSRF:WRAP-SAME-ORIGIN (#293). A desktop app usually
has no session, so the session-token check cannot protect it, and without this any web page
the user visits could post to the app's local routes, or read them after a DNS rebinding.
:NONE installs nothing, for an app that does its own checking, and says so in the log once,
because an unprotected local server is otherwise invisible."
  (ecase request-guard
    (:same-origin (csrf:wrap-same-origin app :origins (list origin)))
    (:none
     (log:warn "desktop: request-guard is :none -- the local server has no CSRF defence"
               :origin origin)
     app)))

(defun %start-embedded (app port server &optional (request-guard :same-origin) workers loops)
  "Start APP on a free (or given) loopback port, behind REQUEST-GUARD (see %GUARD); wait
until it listens. Returns (values URL HANDLER). Signals if the server never comes up.
WORKERS and LOOPS are passed to HYPERION/SERVER:START.

The guard is applied here rather than by the caller because the origin it checks against
includes the port, and the port is not known until this function picks it."
  (let* ((p (if (eq port :auto) (free-port) port))
         (origin (format nil "http://127.0.0.1:~D" p))
         (handler (hyperion/server:start (%guard app origin request-guard)
                                         :port p :host "127.0.0.1" :server server
                                         :workers workers :loops loops)))
    (unless (wait-until-listening p)
      (ignore-errors (hyperion/server:stop handler))
      (error "hyperion/desktop: server did not start listening on 127.0.0.1:~D" p))
    (values (format nil "~A/" origin) handler)))

(defun %app-workers (server workers workers-p)
  "The :WORKERS RUN-APP starts its embedded server with (#472): WORKERS when given, even NIL;
otherwise 2 on the native :uv backend, which without workers runs every handler on its loop
thread, and NIL on the others, which keeps their own default."
  (cond (workers-p workers)
        ((eq server :uv) 2)
        (t nil)))

(defun %app-loops (server loops loops-p)
  "The :LOOPS RUN-APP starts its embedded server with (#472): LOOPS when given, even NIL;
otherwise 1 on the native :uv backend, and NIL on the others, which run one event loop
anyway and would warn about being given a count."
  (cond (loops-p loops)
        ((eq server :uv) 1)
        (t nil)))

(defun run-app (app &key (title "App") (width 1200) (height 800)
                         (backend :embedded)
                         (port :auto)
                         (server (hyperion/server:default-server))
                         (shell :webview)
                         (request-guard :same-origin)
                         (launcher (default-launcher))
                         icon placement-file (workers nil workers-p) (loops nil loops-p)
                         on-ready on-close)
  "Run a Hyperion APP as a native desktop window, blocking until the window closes.
See hyperion/docs/desktop.md.

BACKEND -- where the UI is served:
  :embedded        (default) start APP in-process on a free port on 127.0.0.1 (one-off app);
  (:remote URL)    no local server: point the shell straight at a remote Hyperion backend
                   (APP may be NIL) -- the GitHub-Desktop model;
  (:hybrid URL)    embedded local surface + *REMOTE-BACKEND* bound to URL for the app.
SHELL -- :webview (the native launcher) or :browser (default browser; dev/hot-reload).
REQUEST-GUARD -- the CSRF defence put in front of an embedded or hybrid APP (#293):
  :same-origin (default) refuses a request whose Host is not 127.0.0.1:PORT, and an unsafe
  request that did not come from the app's own page (hyperion/csrf:wrap-same-origin);
  :none installs nothing and logs a warning. Ignored under (:remote URL), where no local
  server runs.
ICON -- a pathname/string for the WINDOW icon, passed to the launcher as --icon (#74):
  `.ico` on Windows, `.png` on Linux, anything NSImage reads on macOS. A caller supplying
  one format for every OS gets an icon on one of them, so pick per platform. Ignored by
  the :browser shell, which has no window of its own. It is NOT the executable's icon on
  Windows, nor a bundled .app's icon on macOS -- both come from elsewhere. A shipped bundle
  built with --window-icon carries its own copy, and that copy is used instead
  (BUNDLED-WINDOW-ICON), because ICON is usually a path on the machine that built the app.
PLACEMENT-FILE -- a pathname for the file where the window's position, size and maximised state
  are kept between runs (#485). NIL, the default, keeps none, and the window opens centred in
  the work area each time. With a file, the window opens where it was last time if that still
  fits a monitor, and centred otherwise; the file is rewritten after every move or resize. Put
  it in the app's own data directory, for example (merge-pathnames \"window-placement\"
  data-dir). Its directory is created if needed. Windows only for now: elsewhere the launcher
  accepts it and ignores it. It needs a hyperion-view built with this change; an older one
  refuses the option and exits 2.
WORKERS -- the number of threads that run the embedded server's handlers, passed to
  HYPERION/SERVER:START. It defaults to 2 when SERVER is :uv (#472): without workers, :uv runs
  every handler on its loop thread, so a handler that waits -- a model call, a slow query, a
  large file -- holds up every other request, including the page's polling and streams.
  Pass :WORKERS NIL to get that inline dispatch anyway. On other servers it defaults to NIL,
  which keeps the server's own. An app whose page makes a second request while a slow one
  runs, such as a cancel button, needs at least 2 on Woo.
LOOPS -- the number of event loops the embedded server runs, passed to HYPERION/SERVER:START.
  It defaults to 1 when SERVER is :uv (#472). With workers, :uv's own default runs one loop per
  core, up to 4, on macOS and Linux, and a window used by one person never needs more than one.
  Pass :LOOPS NIL for :uv's own default. Windows runs one loop whatever is asked. On other
  servers it defaults to NIL.
ON-READY is called with the URL before the shell launches; ON-CLOSE after it exits.

The window and the server end together. REQUEST-CLOSE, from any thread, closes the window,
and RUN-APP then stops the server and returns. If RUN-APP is left any other way, including the
process exiting from another thread, it stops the launcher on the way out (#355)."
  ;; Fail before booting anything if the native half was never built on this machine.
  (when (eq shell :webview) (%check-launcher launcher))
  (setf workers (%app-workers server workers workers-p)
        loops (%app-loops server loops loops-p))
  (multiple-value-bind (url handler)
      (cond
        ((eq backend :embedded) (%start-embedded app port server request-guard workers loops))
        ((and (consp backend) (eq (first backend) :remote))
         (values (second backend) nil))
        ((and (consp backend) (eq (first backend) :hybrid))
         (setf *remote-backend* (second backend))
         (%start-embedded app port server request-guard workers loops))
        (t (error "hyperion/desktop: unrecognized :backend ~S" backend)))
    (unwind-protect
         (progn
           (when on-ready (funcall on-ready url))
           (ecase shell
             (:webview
              (%wait-for-window
               (uiop:launch-program
                (append (list (namestring launcher) url title
                              (princ-to-string width)
                              (princ-to-string height))
                        ;; Only when it exists: an older launcher build treats an unknown
                        ;; trailing argument as noise, but a --icon pointing at nothing
                        ;; would still cost a silent failed load on every start. A bundle's
                        ;; own copy comes first (#74); see %ICON-ARGUMENTS.
                        (%icon-arguments icon)
                        (%placement-arguments placement-file)))))
             (:browser
              (open-in-browser url)
              (%wait-for-interrupt))))
      (when on-close (funcall on-close))
      (when handler (ignore-errors (hyperion/server:stop handler))))
    url))
