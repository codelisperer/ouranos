;;;; desktop.lisp --- turn a Hyperion app into a native desktop window.
;;;;
;;;; The CL half of the desktop capability (ADR-0008): boot Hyperion in-process on a
;;;; free localhost port, then launch a small OUT-OF-PROCESS native webview pointed at
;;;; it (a `webview.h` launcher built per-OS -- see hyperion-view/). HTMX-over-HTTP
;;;; means no in-process JS<->native bridge, so the webview owns its own GUI main thread
;;;; in its own process and the SBCL main-thread/ldb hazard never arises.
;;;;
;;;; Desktop is one UX surface among several (ADR-0009): the embedded local server is the
;;;; DEFAULT, not a hardcode -- :backend (:remote URL) points the webview at a remote
;;;; Hyperion backend instead (the GitHub-Desktop model). SBCL-only (sb-bsd-sockets).

(cl:defpackage #:hyperion/desktop
  (:use #:cl)
  (:local-nicknames (#:platform #:aion/platform))
  (:documentation
   "Run a Hyperion app as a native desktop window: boot the server in-process on a free
    localhost port, then launch an out-of-process native webview at it (ADR-0008). The
    embedded server is the default; :backend (:remote URL) points at a remote backend
    instead (ADR-0009). SBCL-only.")
  (:export #:run-app #:free-port #:wait-until-listening
           #:*launcher* #:default-launcher #:image-directory
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
(#335): hyperion/update needs the same answer to say where a build is installed, and
ADR-0014's packaging argument -- \"there is nothing here that can disagree with the
resolver\" -- holds only while there is one resolver. Two would have drifted in the dark,
since the consumer that breaks is a shipped bundle on a user's machine.

Why not (uiop:argv0), and why sb-ext:*runtime-pathname* is the right question, are recorded
at the implementation."
  (platform:executable-directory))

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

;;; --- lifecycle --------------------------------------------------------------

(defvar *remote-backend* nil
  "Under :backend (:hybrid URL), the remote data-API base URL the app calls out to
(ADR-0009). The local surface still runs embedded; the app reads this to reach the
remote contract.")

(defun %start-embedded (app port server)
  "Start APP on a free (or given) loopback port; wait until it listens. Returns
(values URL HANDLER). Signals if the server never comes up."
  (let* ((p (if (eq port :auto) (free-port) port))
         (handler (hyperion/server:start app :port p :host "127.0.0.1" :server server)))
    (unless (wait-until-listening p)
      (ignore-errors (hyperion/server:stop handler))
      (error "hyperion/desktop: server did not start listening on 127.0.0.1:~D" p))
    (values (format nil "http://127.0.0.1:~D/" p) handler)))

(defun run-app (app &key (title "App") (width 1200) (height 800)
                         (backend :embedded)
                         (port :auto)
                         (server (hyperion/server:default-server))
                         (shell :webview)
                         (launcher (default-launcher))
                         icon
                         on-ready on-close)
  "Run a Hyperion APP as a native desktop window, blocking until the window closes.
See hyperion/docs/desktop.md.

BACKEND -- where the UI is served:
  :embedded        (default) start APP in-process on a free localhost port (one-off app);
  (:remote URL)    no local server: point the shell straight at a remote Hyperion backend
                   (APP may be NIL) -- the GitHub-Desktop model;
  (:hybrid URL)    embedded local surface + *REMOTE-BACKEND* bound to URL for the app.
SHELL -- :webview (the native launcher) or :browser (default browser; dev/hot-reload).
ICON -- a pathname/string for the WINDOW icon, passed to the launcher as --icon (#79):
  `.ico` on Windows, `.png` on Linux, anything NSImage reads on macOS. A caller supplying
  one format for every OS gets an icon on one of them, so pick per platform. Ignored by
  the :browser shell, which has no window of its own. It is NOT the executable's icon on
  Windows, nor a bundled .app's icon on macOS -- both come from elsewhere.
ON-READY is called with the URL before the shell launches; ON-CLOSE after it exits."
  ;; Fail before booting anything if the native half was never built on this machine.
  (when (eq shell :webview) (%check-launcher launcher))
  (multiple-value-bind (url handler)
      (cond
        ((eq backend :embedded) (%start-embedded app port server))
        ((and (consp backend) (eq (first backend) :remote))
         (values (second backend) nil))
        ((and (consp backend) (eq (first backend) :hybrid))
         (setf *remote-backend* (second backend))
         (%start-embedded app port server))
        (t (error "hyperion/desktop: unrecognized :backend ~S" backend)))
    (unwind-protect
         (progn
           (when on-ready (funcall on-ready url))
           (ecase shell
             (:webview
              (uiop:wait-process
               (uiop:launch-program
                (append (list (namestring launcher) url title
                              (princ-to-string width)
                              (princ-to-string height))
                        ;; Only when it exists: an older launcher build treats an unknown
                        ;; trailing argument as noise, but a --icon pointing at nothing
                        ;; would still cost a silent failed load on every start.
                        (let ((path (and icon (probe-file icon))))
                          (when path (list "--icon" (namestring path))))))))
             (:browser
              (open-in-browser url)
              (%wait-for-interrupt))))
      (when on-close (funcall on-close))
      (when handler (ignore-errors (hyperion/server:stop handler))))
    url))
