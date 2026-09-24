;;;; appdata-survival-probe.lisp --- dump the throwaway application #111's harness installs.
;;;;
;;;;     sbcl --script scripts/appdata-survival-probe.lisp --out dist/probe/app.exe
;;;;
;;;; A REAL EXECUTABLE, NOT A PLACEHOLDER FILE. `scripts/verify-appdata-survives.ps1' runs
;;;; a real NSIS or Inno installer, and both do things to the installed binary that only a
;;;; binary can be on the receiving end of: NSIS deletes `$INSTDIR\<exe>' as its
;;;; is-the-app-gone-yet probe, and both relaunch it after a silent install. A zero-byte
;;;; stand-in would make the install succeed while proving nothing about either.
;;;;
;;;; NOT `build-desktop-app.lisp'. That script builds a Hyperion desktop app -- the whole
;;;; DAG, a native webview beside it, vendored libraries. #111 is a claim about a
;;;; DIRECTORY, and every one of those parts would be a way for the harness to fail for a
;;;; reason that has nothing to do with the claim. This is a bare SBCL image with no
;;;; dependency on the tree at all, which is why it can be built in a fresh worktree that
;;;; has never run `scripts/build-libuv.lisp'.
;;;;
;;;; WHAT IT DOES WHEN IT RUNS. Appends one line to the file named by
;;;; `OURANOS_PROBE_MARKER', reporting the version it read from the `VERSION' file beside
;;;; itself, then exits. Two things fall out of that:
;;;;
;;;;   - the marker proves the app was RELAUNCHED after the silent install (design §7), so
;;;;     the harness also witnesses the property pre-publication issue 76 measured for Inno;
;;;;   - the marker is written OUTSIDE `~/.<appname>', deliberately. The one thing this
;;;;     application must not do while the harness is watching is touch its own data
;;;;     directory -- so it does not have one.

(require :asdf)
(require :uiop)
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; how a path is printed (#168)

(defun argv-value (name &optional default)
  (let ((tail (member name (rest sb-ext:*posix-argv*) :test #'string=)))
    (or (second tail) default)))

(defparameter *out* (or (argv-value "--out")
                        (error "appdata-survival-probe: --out is required")))

(defun probe-main ()
  ;; `*runtime-pathname*' is where THIS binary is, which after an update is the install
  ;; directory the installer wrote into -- so the version reported is the installed one
  ;; rather than anything baked in at dump time.
  (let* ((dir (uiop:pathname-directory-pathname sb-ext:*runtime-pathname*))
         (version (or (ignore-errors
                       (string-trim '(#\Space #\Tab #\Return #\Newline)
                                    (uiop:read-file-string (merge-pathnames "VERSION" dir))))
                      "unknown"))
         (marker (uiop:getenv "OURANOS_PROBE_MARKER")))
    (when (and marker (plusp (length marker)))
      (ignore-errors
       (with-open-file (s marker :direction :output :external-format :utf-8
                                 :if-exists :append :if-does-not-exist :create)
         (format s "launched version=~A from=~A~%" version (human-path:human-path dir)))))
    (sb-ext:quit :unix-status 0)))

(ensure-directories-exist *out*)
(format *error-output* "~&dumping the probe application to ~A~%" *out*)
(finish-output *error-output*)
(sb-ext:save-lisp-and-die *out* :executable t :toplevel #'probe-main
                                :save-runtime-options t)
