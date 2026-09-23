;;;; view-launcher.lisp --- build the native webview launcher (hyperion-view) for this host.
;;;;
;;;; Loaded by path by bootstrap.lisp and by scripts/verify-tree.lisp. Both build the launcher,
;;;; and before this file the gate had the only copy of the code that does it: finding
;;;; PowerShell, running the build script's prerequisite check, running the build, and
;;;; checking that the binary landed where hyperion/desktop looks for it.
;;;;
;;;; bootstrap.lisp builds it because a fresh clone could not open a desktop window (#13). The
;;;; launcher is build output that hyperion/hyperion-view/.gitignore ignores, so a clone never
;;;; has it, and nothing reported that it was missing until a window failed to open.
;;;;
;;;; Not a member of any ASDF system, for the same reason as platform-packages.lisp:
;;;; bootstrap.lisp consumes it before `cons' exists. Unlike that file it uses UIOP, which both
;;;; callers have loaded (they `(require :asdf)' first). cons/tests loads it by path and tests
;;;; it; see cons/tests/view-launcher-tests.lisp.

(defpackage #:ouranos-view
  (:use #:common-lisp)
  (:export #:launcher-name #:launcher-path #:script-name #:check-flag
           #:skip-build-p #:powershell #:build-command #:build-hint #:run-build))

(in-package #:ouranos-view)

(defun launcher-name (&optional (windows (uiop:os-windows-p)))
  "The launcher's file name. The same name is the default output of build.sh and build.ps1
and what `hyperion/desktop:default-launcher' looks for; cons/tests checks the two scripts."
  (if windows "hyperion-view.exe" "hyperion-view"))

(defun launcher-dir (root)
  (merge-pathnames "hyperion/hyperion-view/" root))

(defun launcher-path (root &optional (windows (uiop:os-windows-p)))
  "Where the launcher is built in the tree rooted at ROOT."
  (merge-pathnames (launcher-name windows) (launcher-dir root)))

(defun script-name (&optional (windows (uiop:os-windows-p)))
  (if windows "build.ps1" "build.sh"))

(defun check-flag (&optional (windows (uiop:os-windows-p)))
  (if windows "-Check" "--check"))

(defun skip-build-p (&optional (value (uiop:getenv "OURANOS_SKIP_VIEW_BUILD")))
  "True only when VALUE (by default OURANOS_SKIP_VIEW_BUILD) is 1, true or yes. `0' and
`false' are what somebody types to turn a thing off, so a check for \"is it set\" would read
them as on."
  (and value
       (member (string-trim " " value) '("1" "true" "yes") :test #'string-equal)
       t))

(defun powershell ()
  "pwsh when it runs on this machine, else the stock Windows PowerShell."
  (or (ignore-errors
       (and (zerop (nth-value 2 (uiop:run-program '("pwsh" "-NoProfile" "-Command" "exit 0")
                                                  :output nil :error-output nil
                                                  :ignore-error-status t)))
            "pwsh"))
      "powershell"))

(defun build-command (root &key check (windows (uiop:os-windows-p)) (shell "powershell"))
  "The argument list that runs the build script under ROOT, or only its prerequisite check
when CHECK is true. SHELL is the PowerShell to use on Windows."
  (let ((script (uiop:native-namestring (merge-pathnames (script-name windows)
                                                         (launcher-dir root)))))
    (append (if windows
                (list shell "-NoProfile" "-ExecutionPolicy" "Bypass" "-File" script)
                (list "/bin/sh" script))
            (when check (list (check-flag windows))))))

(defun build-hint (&optional (windows (uiop:os-windows-p)))
  "The commands a person runs from the tree root to check for and build the launcher."
  (if windows
      "cd hyperion\\hyperion-view; .\\build.ps1 -Check   (then .\\build.ps1 to build)"
      "cd hyperion/hyperion-view && ./build.sh --check   (then ./build.sh to build)"))

(defun run-build (root &key (skip (skip-build-p)) (output nil) (check-output nil)
                            (windows (uiop:os-windows-p)))
  "Run the prerequisite check, then the build if the check passed. Never signals.

OUTPUT and CHECK-OUTPUT go to `uiop:run-program' for the build and the check: NIL discards,
:INTERACTIVE shows it, and '(:string :stripped t) captures it.

Returns (values STATE REASON BUILD-STDOUT BUILD-STDERR), STATE being one of
  :skipped      SKIP was true; nothing ran
  :unavailable  the check failed, so this host lacks a prerequisite; nothing was built
  :failed       the build ran and exited non-zero
  :misplaced    the build exited 0 and the launcher is not at `launcher-path', which means
                this file and the build script disagree about where the binary goes
  :built        the launcher is at `launcher-path'
REASON is a sentence saying why STATE is not :built, or NIL."
  (let ((shell (if windows (powershell) "powershell")))
    (flet ((cmd (check) (build-command root :check check :windows windows :shell shell)))
      (cond
        (skip
         (values :skipped "OURANOS_SKIP_VIEW_BUILD is set -- the caller declined the build"))
        ((not (zerop (nth-value 2 (uiop:run-program (cmd t)
                                                    :output check-output
                                                    :error-output check-output
                                                    :ignore-error-status t))))
         (values :unavailable
                 (format nil "the prerequisite check failed -- hyperion/hyperion-view/~a ~a reports which prerequisite is missing"
                         (script-name windows) (check-flag windows))))
        (t
         (multiple-value-bind (out err code)
             (uiop:run-program (cmd nil) :output output :error-output output
                                         :ignore-error-status t)
           (cond
             ((not (zerop code))
              (values :failed (format nil "the launcher build FAILED (exit ~D)" code) out err))
             ((not (probe-file (launcher-path root windows)))
              (values :misplaced
                      (format nil "the launcher build reported success but ~a does not exist -- scripts/view-launcher.lisp and hyperion-view/~a disagree about where the binary goes"
                              (uiop:native-namestring (launcher-path root windows))
                              (script-name windows))
                      out err))
             (t (values :built nil out err)))))))))
