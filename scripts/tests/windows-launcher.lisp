;;;; windows-launcher.lisp --- the Windows launcher passes the heap and every argument (#98)
;;;;
;;;; A Windows desktop app is now <name>.exe (scripts/windows-launcher.c), sbcl-runtime.exe and
;;;; sbcl.core. A core dumped without its runtime cannot carry runtime options, so the launcher
;;;; exists to start the runtime with the build's heap and to end runtime-option processing
;;;; before the app's own arguments. These tests compile the launcher the way the build does
;;;; (scripts/windows-launcher.lisp), beside a copy of this SBCL's runtime and a probe core
;;;; that reports what it was given.
;;;;
;;;; THE CONTROL runs the same runtime and probe without the launcher. The runtime then takes
;;;; --dynamic-space-size for itself, which is the defect the launcher exists to prevent, so a
;;;; fixture that could not show it would let the first test pass for the wrong reason.
;;;;
;;;; Windows only, and only where MSVC is installed: the Windows CI legs have it, as does
;;;; every machine that builds a Windows desktop app.

(in-package #:checkers/tests)

;;; See dump-image.lisp: FiveAM's current suite does not carry over between files.
(in-suite checkers)

(defun %launcher-bundle (tree heap-mb)
  "Put a launcher compiled for HEAP-MB, a copy of this runtime as sbcl-runtime.exe, and a probe
sbcl.core into TREE. The probe core is dumped under a 1500 MB heap, so a launcher that did not
pass its own heap would show 1500 or the runtime's default instead of HEAP-MB. Returns (values
OK OUTPUT) from the compile."
  (load (merge-pathnames "windows-launcher.lisp" *scripts*))
  (uiop:copy-file sb-ext:*runtime-pathname* (merge-pathnames "sbcl-runtime.exe" tree))
  (uiop:run-program
   (list (uiop:native-namestring sb-ext:*runtime-pathname*)
         "--dynamic-space-size" "1500" "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
         "--eval" (format nil "(sb-ext:save-lisp-and-die ~S :toplevel (lambda () (format t \"ARGV ~~S~~%HEAP ~~D~~%RUNTIME ~~A~~%\" (rest sb-ext:*posix-argv*) (floor (sb-ext:dynamic-space-size) 1048576) (file-namestring sb-ext:*runtime-pathname*)) (finish-output) (sb-ext:exit :code 42)))"
                          (uiop:native-namestring (merge-pathnames "sbcl.core" tree))))
   :output nil :error-output nil)
  ;; The core's hash is computed here with ironclad, not by the build's own route, so the
  ;; launcher's check is compared with an independent answer (#98, step 2).
  (uiop:symbol-call :ouranos-windows-launcher :compile-launcher
                    (merge-pathnames "app.exe" tree) heap-mb (merge-pathnames "obj/" tree)
                    (%sha256-hex (merge-pathnames "sbcl.core" tree))))

(defun %probe-report (program args)
  "Run PROGRAM with ARGS; return (values EXIT-CODE ARGV HEAP RUNTIME-NAME) as the probe reported them."
  (multiple-value-bind (out err code)
      (uiop:run-program (cons (uiop:native-namestring program) args)
                        :output :string :error-output :string :ignore-error-status t)
    (declare (ignore err))
    (let ((lines (uiop:split-string out :separator '(#\Newline #\Return)))
          (argv nil) (heap nil) (runtime nil))
      (dolist (line lines)
        (cond ((uiop:string-prefix-p "ARGV " line) (setf argv (read-from-string line t nil :start 5)))
              ((uiop:string-prefix-p "HEAP " line) (setf heap (parse-integer line :start 5)))
              ((uiop:string-prefix-p "RUNTIME " line) (setf runtime (subseq line 8)))))
      (values code argv heap runtime))))

(test the-windows-launcher-passes-the-heap-and-every-argument
  #-win32 (skip "The Windows launcher is built and run on Windows only")
  #+win32
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (multiple-value-bind (ok output) (%launcher-bundle tree 777)
           (if (and (not ok) (search "no MSVC" output))
               (skip "No MSVC here: ~A" output)
               (progn
                 (is-true ok "the launcher compiled: ~A" output)
                 (let ((args '("--help" "--dynamic-space-size" "99" "a b" "c\"d" "--end-runtime-options")))
                   (multiple-value-bind (code argv heap runtime)
                       (%probe-report (merge-pathnames "app.exe" tree) args)
                     (is (eql 42 code) "the launcher exits with the runtime's exit code, got ~A" code)
                     (is (equal args argv) "every argument reaches the app unchanged: ~S" argv)
                     (is (eql 777 heap) "the heap is the launcher's, got ~A MB" heap)
                     (is (equalp "sbcl-runtime.exe" runtime) "the runtime beside the launcher ran: ~A" runtime))))))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(test without-the-launcher-the-runtime-takes-the-heap-option-for-itself
  "The control for the test above: the same runtime and probe core, started directly."
  #-win32 (skip "The Windows launcher is built and run on Windows only")
  #+win32
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (progn
           (%launcher-bundle tree 777)
           (multiple-value-bind (code argv heap)
               (%probe-report (merge-pathnames "sbcl-runtime.exe" tree)
                              (list "--core" (uiop:native-namestring (merge-pathnames "sbcl.core" tree))
                                    "--dynamic-space-size" "700" "--foo"))
             (is (eql 42 code))
             (is (equal '("--foo") argv) "the runtime took --dynamic-space-size for itself: ~S" argv)
             (is (eql 700 heap) "and used it as its own heap: ~A MB" heap)))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

;;; --- the launcher checks the core's SHA-256 (#98, step 2) ---------------------------------

(test a-core-changed-after-the-build-is-refused
  "A per-user install can be written by anything running as the user, and the core is data the
signature does not cover. The launcher is compiled with the core's hash and refuses a core that
differs, before starting the runtime."
  #-win32 (skip "The Windows launcher is built and run on Windows only")
  #+win32
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (multiple-value-bind (ok output) (%launcher-bundle tree 777)
           (if (and (not ok) (search "no MSVC" output))
               (skip "No MSVC here: ~A" output)
               (progn
                 (is-true ok "the launcher compiled: ~A" output)
                 (is (eql 42 (%probe-report (merge-pathnames "app.exe" tree) '("x")))
                     "the control: the core it was built with starts")
                 (with-open-file (s (merge-pathnames "sbcl.core" tree) :direction :output
                                    :if-exists :append :element-type '(unsigned-byte 8))
                   (write-byte 0 s))
                 (multiple-value-bind (out err code)
                     (uiop:run-program (list (uiop:native-namestring (merge-pathnames "app.exe" tree)) "x")
                                       :output :string :error-output :string :ignore-error-status t)
                   (is (eql 126 code) "a core one byte longer is refused with 126, got ~A" code)
                   (is (search "is not the file this app was built with" err) "stderr: ~A" err)
                   (is (null (search "ARGV" out)) "and the runtime was not started")))))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(test the-launcher-is-not-compiled-without-a-well-formed-hash
  (load (merge-pathnames "windows-launcher.lisp" *scripts*))
  (dolist (bad (list nil "" "abc" (make-string 64 :initial-element #\g)))
    (is-false (uiop:symbol-call :ouranos-windows-launcher :compile-launcher
                                "app.exe" 777 (uiop:temporary-directory) bad)
              "refused ~S" bad)))


;;; --- what the installers use: check only, and the previous version removed (#98, step 3) ---

(defun %launcher-run-check-only (exe)
  "Run EXE with OURANOS_LAUNCHER_CHECK_ONLY=1, set in a child shell rather than in this image.
Returns (values EXIT-CODE OUTPUT)."
  (multiple-value-bind (out err code)
      (uiop:run-program (format nil "set OURANOS_LAUNCHER_CHECK_ONLY=1&& \"~A\""
                                (uiop:native-namestring exe))
                        :force-shell t :output :string :error-output :string
                        :ignore-error-status t)
    (values code (concatenate 'string out err))))

(test the-launcher-checks-the-core-without-starting-it-when-asked
  "The installers run the staged launcher with OURANOS_LAUNCHER_CHECK_ONLY set to check the
staged core. It exits 0 or 126 and never starts the runtime, whose probe core would print ARGV
and exit 42."
  #-win32 (skip "The Windows launcher is built and run on Windows only")
  #+win32
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (multiple-value-bind (ok output) (%launcher-bundle tree 777)
           (if (and (not ok) (search "no MSVC" output))
               (skip "No MSVC here: ~A" output)
               (let ((exe (merge-pathnames "app.exe" tree)))
                 (multiple-value-bind (code out) (%launcher-run-check-only exe)
                   (is (eql 0 code) "the core it was built with passes: exit ~A" code)
                   (is (null (search "ARGV" out)) "and the runtime was not started: ~A" out))
                 (is (eql 42 (%probe-report exe '("x")))
                     "the control: without the variable, the same launcher starts the runtime")
                 (with-open-file (s (merge-pathnames "sbcl.core" tree) :direction :output
                                    :if-exists :append :element-type '(unsigned-byte 8))
                   (write-byte 0 s))
                 (multiple-value-bind (code out) (%launcher-run-check-only exe)
                   (is (eql 126 code) "a changed core fails with 126: exit ~A" code)
                   (is (null (search "ARGV" out)) "and the runtime was not started: ~A" out)))))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(defun %launcher-sibling (tree suffix)
  (uiop:ensure-directory-pathname
   (concatenate 'string (string-right-trim "\\" (uiop:native-namestring tree)) suffix)))

(test the-launcher-removes-the-previous-version-an-update-left
  "An installer's swap leaves the previous version as <install>.old. The launcher deletes it once
it has started the runtime. It deletes nothing else beside it, and a junction of that name is
removed as a link: what it points to is not touched."
  #-win32 (skip "The Windows launcher is built and run on Windows only")
  #+win32
  (let* ((tree (%fresh-tree))
         (old (%launcher-sibling tree ".old"))
         (older (%launcher-sibling tree ".older"))
         (target (%launcher-sibling tree ".target")))
    (unwind-protect
         (multiple-value-bind (ok output) (%launcher-bundle tree 777)
           (if (and (not ok) (search "no MSVC" output))
               (skip "No MSVC here: ~A" output)
               (let ((exe (merge-pathnames "app.exe" tree)))
                 (dolist (dir (list (merge-pathnames "sub/" old) older))
                   (ensure-directories-exist dir)
                   (with-open-file (s (merge-pathnames "file" dir) :direction :output)
                     (write-line "x" s)))
                 (is (eql 42 (%probe-report exe '("x"))) "the app started")
                 (is-false (uiop:directory-exists-p old) "<install>.old and what it held are gone")
                 (is-true (probe-file (merge-pathnames "file" older))
                          "<install>.older, which is not the installers', is untouched")
                 ;; A junction named .old, pointing at a directory with a file in it.
                 (ensure-directories-exist target)
                 (with-open-file (s (merge-pathnames "keep" target) :direction :output)
                   (write-line "x" s))
                 (uiop:run-program (list "cmd" "/c" "mklink" "/J"
                                         (string-right-trim "\\" (uiop:native-namestring old))
                                         (string-right-trim "\\" (uiop:native-namestring target)))
                                   :output nil :error-output nil :ignore-error-status t)
                 (is-true (probe-file (merge-pathnames "keep" old)) "the junction was made")
                 (is (eql 42 (%probe-report exe '("x"))) "the app started again")
                 (is-false (probe-file (merge-pathnames "keep" old)) "the junction is gone")
                 (is-true (probe-file (merge-pathnames "keep" target))
                          "and the directory it pointed to still has its file"))))
      (dolist (dir (list old older target))
        (ignore-errors
         (uiop:run-program (list "cmd" "/c" "rmdir" (string-right-trim "\\" (uiop:native-namestring dir)))
                           :output nil :error-output nil :ignore-error-status t))
        (aion/fs:delete-tree dir :if-does-not-exist :ignore))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))
