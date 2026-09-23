;;;; view-launcher-tests.lisp --- building the native webview launcher (#13; pre-publication issue 410)
;;;;
;;;; scripts/view-launcher.lisp is loaded by path by bootstrap.lisp and scripts/verify-tree.lisp.
;;;; Neither runs under a test harness, so a mistake in it would show up as a fresh clone that
;;;; cannot open a window, or as a gate ten checks short, with nothing pointing at this file.
;;;;
;;;; These tests compile no C++. The launcher build itself is exercised by the gate on every
;;;; host that can build it. What is tested here is the part that decides what runs and what
;;;; the result means: the file name, the command lines, the skip variable, and the state a
;;;; host without the build scripts ends up in.

(in-package #:cons/tests)

(def-suite view-launcher
  :description "scripts/view-launcher.lisp, shared by bootstrap and the gate (#13)." :in all)
(in-suite view-launcher)

(defun %tree-root ()
  "The monorepo root: the directory holding cons/."
  (merge-pathnames "../" (asdf:system-source-directory :cons)))

(defun %load-view-launcher ()
  "Load scripts/view-launcher.lisp -- the file bootstrap.lisp and verify-tree.lisp load by path."
  (let ((path (merge-pathnames "scripts/view-launcher.lisp" (%tree-root))))
    (is-true (probe-file path)
             "scripts/view-launcher.lisp must exist -- bootstrap.lisp loads it by path, so a rename breaks the seed, not just this test. Looked at ~A" path)
    (when (probe-file path) (load path))
    path))

(defmacro %vl (name &rest args)
  "Call an OURANOS-VIEW function by name at RUNTIME. The package does not exist until the file
is loaded, so a literal symbol would be resolved by the reader and take down the whole test
system on a tree where the file moved. Same reasoning as %PF and %FO."
  `(funcall (read-from-string
             ,(concatenate 'string "ouranos-view:" (string-downcase (string name))))
            ,@args))

(defun %file-text (path)
  (with-open-file (in path :external-format :utf-8)
    (let* ((buf (make-string (file-length in)))
           (n (read-sequence buf in)))
      (subseq buf 0 n))))

(test launcher-name-matches-what-the-build-scripts-write
  "The name here is the name build.sh and build.ps1 write by default. Read from the real
scripts, because a disagreement shows up as a launcher that was built and cannot be found."
  (%load-view-launcher)
  (is (string= "hyperion-view.exe" (%vl launcher-name t)))
  (is (string= "hyperion-view" (%vl launcher-name nil)))
  (let ((dir (merge-pathnames "hyperion/hyperion-view/" (%tree-root))))
    (is (search "out=\"$here/hyperion-view\"" (%file-text (merge-pathnames "build.sh" dir)))
        "build.sh no longer writes $here/hyperion-view; update scripts/view-launcher.lisp to match")
    (is (search "Join-Path $Here 'hyperion-view.exe'" (%file-text (merge-pathnames "build.ps1" dir)))
        "build.ps1 no longer writes hyperion-view.exe beside itself; update scripts/view-launcher.lisp to match")))

(test launcher-path-is-in-the-hyperion-view-directory
  (%load-view-launcher)
  (let ((root #p"/r/"))
    (is (equal #p"/r/hyperion/hyperion-view/hyperion-view.exe" (%vl launcher-path root t)))
    (is (equal #p"/r/hyperion/hyperion-view/hyperion-view" (%vl launcher-path root nil)))))

(test skip-build-p-reads-only-affirmative-values
  "`0' and `false' mean off. A check for \"is it set\" would read them as on."
  (%load-view-launcher)
  (dolist (v '("1" "true" "yes" "TRUE" " yes "))
    (is-true (%vl skip-build-p v) "~S should skip the build" v))
  (dolist (v '("0" "false" "no" "" "2"))
    (is-false (%vl skip-build-p v) "~S should not skip the build" v))
  (is-false (%vl skip-build-p nil) "an unset variable should not skip the build"))

(test build-command-runs-the-platforms-script
  "Windows runs build.ps1 through PowerShell; everything else runs build.sh through /bin/sh.
The check adds the script's own flag, which differs between the two."
  (%load-view-launcher)
  (let* ((root (%tree-root))
         (ps1 (uiop:native-namestring (merge-pathnames "hyperion/hyperion-view/build.ps1" root)))
         (sh  (uiop:native-namestring (merge-pathnames "hyperion/hyperion-view/build.sh" root))))
    (is (equal (list "pwsh" "-NoProfile" "-ExecutionPolicy" "Bypass" "-File" ps1)
               (%vl build-command root :windows t :shell "pwsh")))
    (is (equal (list "pwsh" "-NoProfile" "-ExecutionPolicy" "Bypass" "-File" ps1 "-Check")
               (%vl build-command root :windows t :shell "pwsh" :check t)))
    (is (equal (list "/bin/sh" sh) (%vl build-command root :windows nil)))
    (is (equal (list "/bin/sh" sh "--check") (%vl build-command root :windows nil :check t)))
    ;; The commands name files that exist, so the paths above are not only self-consistent.
    (is-true (probe-file ps1) "the Windows command names ~A, which does not exist" ps1)
    (is-true (probe-file sh) "the Unix command names ~A, which does not exist" sh)))

(test build-hint-names-the-check-and-the-build
  (%load-view-launcher)
  (let ((win (%vl build-hint t))
        (unix (%vl build-hint nil)))
    (is (search "build.ps1 -Check" win))
    (is (search "hyperion\\hyperion-view" win))
    (is (search "build.sh --check" unix))
    (is (search "hyperion/hyperion-view" unix))))

(test run-build-skipped-runs-nothing
  "With SKIP true nothing runs: the root below does not exist, and the result is still :skipped
rather than :unavailable."
  (%load-view-launcher)
  (let ((root (merge-pathnames (format nil "no-such-tree-~36R/" (random (expt 36 8) (make-random-state t)))
                               (uiop:temporary-directory))))
    (multiple-value-bind (state reason) (%vl run-build root :skip t)
      (is (eq :skipped state))
      (is (search "OURANOS_SKIP_VIEW_BUILD" reason)))))

(test run-build-without-the-scripts-is-unavailable
  "A root with no build scripts fails the prerequisite check, so the result is :unavailable
and nothing is built. The root is a fresh name that was never created, so no earlier run can
leave a script or a launcher behind in it. This is the path a host without a C++ toolchain
takes, reached without needing such a host."
  (%load-view-launcher)
  (let ((root (merge-pathnames (format nil "no-such-tree-~36R/" (random (expt 36 8) (make-random-state t)))
                               (uiop:temporary-directory))))
    (is-false (probe-file root) "the fixture root ~A already exists" root)
    (multiple-value-bind (state reason) (%vl run-build root :skip nil)
      (is (eq :unavailable state) "expected :unavailable, got ~S (~A)" state reason)
      (is (search (if (uiop:os-windows-p) "build.ps1 -Check" "build.sh --check") (or reason ""))))
    (is-false (probe-file (%vl launcher-path root)))))
