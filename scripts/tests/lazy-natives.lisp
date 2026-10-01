;;;; lazy-natives.lisp --- every library the bundler wakes and carries resolves against the
;;;; module that loads it (#481)
;;;;
;;;; scripts/lazy-natives.lisp names each library's package, loader, unloader and variables as
;;;; strings. A string that no longer matches the module resolves to nothing, and the bundler
;;;; reads that as "this app does not use the library": it carries nothing and says so in one
;;;; line of a long build log. So for each entry, a child image loads the entry's system and
;;;; checks that every name resolves, that the loader opens a library under vendor/ by a name
;;;; the module's own search asks for, and that the unloader closes it again, which is what
;;;; the bundler needs before the dump (ADR-0013).
;;;;
;;;; THE CONTROL is the same check on an entry whose loader is misspelt. It must report the
;;;; name, and it needs no built library, so it runs on every host.
;;;;
;;;; A library this host has not built is skipped, and the skip names its build script.

(in-package #:checkers/tests)

;;; FiveAM's current suite does not carry over from one file to the next (see dump-image.lisp).
(in-suite checkers)

;;; At compile time too: the tests below name the package it defines.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames "lazy-natives.lisp" *scripts*)))

(defun %lazy-native-report (entry)
  "Run the check for ENTRY in a child image. Returns its output lines, each \"KEY value\"."
  (destructuring-bind (package loader unloader path-var names-var build-script system) entry
    (declare (ignore build-script))
    (let* ((out (make-string-output-stream))
           (form
             (format nil "(let* ((p (find-package ~S)) (sym (lambda (n) (and p (find-symbol n p)))) (loader (funcall sym ~S)) (unloader (funcall sym ~S)) (path-var (funcall sym ~S)) (names-var (funcall sym ~S))) (format t \"~~&PACKAGE ~~A~~%LOADER ~~A~~%UNLOADER ~~A~~%PATH-VARIABLE ~~A~~%NAMES-VARIABLE ~~A~~%\" (and p t) (and loader (fboundp loader) t) (and unloader (fboundp unloader) t) (and path-var (boundp path-var) t) (and names-var (boundp names-var) t)) (when (and loader (fboundp loader) unloader (fboundp unloader) path-var (boundp path-var) names-var (boundp names-var)) (handler-case (progn (funcall loader) (let* ((path (symbol-value path-var)) (open-p (lambda () (and (find-if (lambda (l) (let ((f (ignore-errors (truename (cffi:foreign-library-pathname l))))) (and f (equal f (ignore-errors (truename path)))))) (cffi:list-foreign-libraries :loaded-only t)) t)))) (format t \"~~&PATH ~~A~~%NAMES ~~{~~A~~^ ~~}~~%OPEN-BEFORE-UNLOAD ~~A~~%\" path (symbol-value names-var) (funcall open-p)) (funcall unloader) (format t \"~~&OPEN-AFTER-UNLOAD ~~A~~%\" (funcall open-p)))) (error (e) (format t \"~~&LOAD-ERROR ~~A~~%\" (type-of e))))) (finish-output))"
                     package loader unloader path-var names-var)))
      (uiop:run-program
       (list (uiop:native-namestring sb-ext:*runtime-pathname*)
             "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
             "--eval" "(require :asdf)"
             "--eval" "(load (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))"
             "--eval" (format nil "(asdf:load-system ~S)" system)
             "--eval" form)
       :output out :error-output out :ignore-error-status t)
      (uiop:split-string (get-output-stream-string out) :separator '(#\Newline)))))

(defun %report-value (lines key)
  (let ((line (find-if (lambda (l) (uiop:string-prefix-p (concatenate 'string key " ") l)) lines)))
    (and line (subseq line (1+ (length key))))))

(defun %lazy-native-problems (entry lines)
  "What is wrong with ENTRY according to its child's report LINES, as a list of strings."
  (let ((problems '()))
    (dolist (key '("PACKAGE" "LOADER" "UNLOADER" "PATH-VARIABLE" "NAMES-VARIABLE"))
      (unless (equal "T" (%report-value lines key))
        (push (format nil "~A ~A does not resolve in ~A" key
                      (nth (position key '("PACKAGE" "LOADER" "UNLOADER" "PATH-VARIABLE" "NAMES-VARIABLE")
                                     :test #'string=)
                           entry)
                      (first entry))
              problems)))
    (let ((path (%report-value lines "PATH"))
          (names (%report-value lines "NAMES")))
      (when path
        (unless (uiop:subpathp (ignore-errors (truename path))
                               (truename (merge-pathnames "vendor/" td-root)))
          (push (format nil "the loader opened ~A, outside vendor/" path) problems))
        (unless (member (file-namestring path) (uiop:split-string (or names "") :separator " ")
                        :test #'string=)
          (push (format nil "~A is not among the names the module searches for (~A)"
                        (file-namestring path) names)
                problems))
        ;; The file at the recorded path must be the one the loader opened. Without this, a
        ;; loader that opened a system copy while recording a vendored path passed every other
        ;; check, because the recorded path is then never open at all.
        (unless (equal "T" (%report-value lines "OPEN-BEFORE-UNLOAD"))
          (push (format nil "nothing is open at the recorded path ~A" path) problems))
        (unless (equal "NIL" (%report-value lines "OPEN-AFTER-UNLOAD"))
          (push "the unloader left the library open" problems))))
    (nreverse problems)))

(test every-lazy-native-resolves-loads-from-vendor-and-unloads
  "Each entry of scripts/lazy-natives.lisp, checked in a child image that loads its system."
  (dolist (entry ouranos-lazy-natives:*lazy-natives*)
    (let* ((lines (%lazy-native-report entry))
           (load-error (%report-value lines "LOAD-ERROR")))
      (if (and load-error (search "NOT-FOUND" load-error))
          (skip "~A: the library is not built here; run scripts/~A"
                (first entry) (ouranos-lazy-natives:entry-build-script entry))
          (progn
            (is (null load-error) "~A: the loader signalled ~A" (first entry) load-error)
            (is (%report-value lines "PATH") "~A: the loader recorded no path~%~{~A~%~}"
                (first entry) lines)
            (let ((problems (%lazy-native-problems entry lines)))
              (is (null problems) "~A: ~{~A~^; ~}" (first entry) problems)))))))

(test a-misspelt-lazy-native-name-is-reported
  "CONTROL: aion/uv's entry with its loader misspelt. The check must name the loader."
  (let* ((entry (copy-list (find "AION/UV/FFI" ouranos-lazy-natives:*lazy-natives*
                                 :key #'first :test #'string=)))
         (broken (list* (first entry) "LOAD-LIBUVV" (cddr entry)))
         (problems (%lazy-native-problems broken (%lazy-native-report broken))))
    (is (find-if (lambda (p) (search "LOADER LOAD-LIBUVV does not resolve" p)) problems)
        "problems reported: ~S" problems)))

(defpackage #:lazy-natives-release-fixture (:use #:cl))

(test a-failed-unload-stops-the-build
  "RELEASE-ALL signals RELEASE-FAILED, naming the package, when an unloader signals, so the
bundler stops instead of dumping an image that may still hold the library open. CONTROL: an
unloader that returns is called and nothing is signalled; an entry whose package is absent is
skipped."
  (let ((calls 0))
    (setf (fdefinition (intern "UNLOAD-FINE" '#:lazy-natives-release-fixture))
          (lambda () (incf calls))
          (fdefinition (intern "UNLOAD-FAILS" '#:lazy-natives-release-fixture))
          (lambda () (error "could not close")))
    (let ((fine (list "LAZY-NATIVES-RELEASE-FIXTURE" "LOAD-X" "UNLOAD-FINE" "*P*" "*N*" "build-x.lisp" "x"))
          (fails (list "LAZY-NATIVES-RELEASE-FIXTURE" "LOAD-X" "UNLOAD-FAILS" "*P*" "*N*" "build-x.lisp" "x"))
          (absent (list "NO-SUCH-PACKAGE-ANYWHERE" "LOAD-X" "UNLOAD-X" "*P*" "*N*" "build-x.lisp" "x")))
      (finishes (ouranos-lazy-natives:release-all (list fine absent)))
      (is (= 1 calls))
      (let ((c (handler-case (progn (ouranos-lazy-natives:release-all (list fine fails)) nil)
                 (ouranos-lazy-natives:release-failed (c) c))))
        (is (typep c 'ouranos-lazy-natives:release-failed))
        (is (equal "LAZY-NATIVES-RELEASE-FIXTURE"
                   (and c (ouranos-lazy-natives:release-failed-package c))))))))

;;; --- a bundle of an app that uses aion/tls (#481) -----------------------------------------
;;;
;;; The release workflow bundles coalton-repl, which does not load aion/tls, so nothing there
;;; can show a bundle that leaves mbedTLS out. This builds a bundle for a two-line app that
;;; does, with the real build-desktop-app.lisp, and runs it: the app makes a key, which needs
;;; the library, and prints the file aion/tls loaded. That file must be the copy in the
;;; bundle. The build machine's vendor/ is still there when the test runs it, so "the app
;;; worked" would not show the bundle carried anything; where the library came from does.
;;;
;;; THE CONTROL is the same bundle with the carried copy deleted. The app must then not load
;;; from the bundle, which shows the first run could tell the difference.

(defun %built-mbedtls ()
  "The mbedTLS this tree built under vendor/, or NIL."
  (loop for name in '("mbedtls.dll" "libmbedtls.so.1" "libmbedtls.1.dylib")
        for path = (probe-file (merge-pathnames (concatenate 'string "vendor/mbedtls/lib/" name) td-root))
        when path return path))

(defun %run-bundle (executable)
  "Run EXECUTABLE without AION_TLS_LIBRARY, and return its output."
  (let ((out (make-string-output-stream)))
    (uiop:run-program (list (uiop:native-namestring executable))
                      :output out :error-output out :ignore-error-status t
                      :environment (remove-if (lambda (e) (uiop:string-prefix-p "AION_TLS_LIBRARY=" e))
                                              (sb-ext:posix-environ)))
    (get-output-stream-string out)))

(test a-bundle-of-an-aion-tls-app-loads-mbedtls-from-the-bundle
  (if (null (%built-mbedtls))
      (skip "vendor/mbedtls is not built here; run scripts/build-mbedtls.lisp")
      (let* ((tree (%fresh-tree))
             (app (ensure-directories-exist (merge-pathnames "app/" tree)))
             (dist (merge-pathnames "dist/" tree))
             (build-out (make-string-output-stream)))
        (%write (merge-pathnames "tlsprobe.asd" app)
                "(defsystem \"tlsprobe\" :depends-on (\"aion/tls\") :components ((:file \"tlsprobe\")))")
        (%write (merge-pathnames "tlsprobe.lisp" app)
                (%lines "(defpackage #:tlsprobe (:use #:cl) (:export #:main))"
                        "(in-package #:tlsprobe)"
                        "(defun main ()"
                        "  (handler-case (let ((path (aion/tls:ensure-loaded)))"
                        "                  (aion/tls:generate-private-key)"
                        "                  (format t \"~&LOADED ~A~%KEY OK~%\" path))"
                        "    (error (e) (format t \"~&FAILED ~A~%\" e)))"
                        "  (finish-output)"
                        "  (uiop:quit 0))"))
        (let ((code (nth-value
                     2 (uiop:run-program
                        (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                              "--dynamic-space-size" "4096" "--script"
                              (uiop:native-namestring (merge-pathnames "build-desktop-app.lisp" *scripts*))
                              "--system" "tlsprobe" "--entry" "tlsprobe:main" "--name" "tlsprobe"
                              "--version" "0.0.1" "--out" (uiop:native-namestring dist))
                        :output build-out :error-output build-out :ignore-error-status t
                        :environment
                        (cons (format nil "CL_SOURCE_REGISTRY=~A//~A~A//"
                                      (uiop:native-namestring td-root)
                                      (if (uiop:os-windows-p) ";" ":")
                                      (uiop:native-namestring app))
                              (remove-if (lambda (e) (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e))
                                         (sb-ext:posix-environ)))))))
          (is (eql 0 code) "the build failed:~%~A" (get-output-stream-string build-out)))
        (let* ((bundle (first (uiop:subdirectories dist)))
               (executable (and bundle (merge-pathnames (if (uiop:os-windows-p) "tlsprobe.exe" "tlsprobe")
                                                        bundle)))
               (carried (and bundle (merge-pathnames (file-namestring (%built-mbedtls)) bundle))))
          (unwind-protect
               (when (is (and executable (probe-file executable)) "no executable in ~A" bundle)
                 (is (probe-file carried) "~A was not carried" (file-namestring carried))
                 (is (probe-file (merge-pathnames "LICENSES/mbedtls-LICENSE" bundle)))
                 (flet ((loaded-from-bundle-p (output)
                          (let* ((line (find-if (lambda (l) (uiop:string-prefix-p "LOADED " l))
                                                (uiop:split-string output :separator '(#\Newline))))
                                 (file (and line (ignore-errors
                                                  (truename (string-trim '(#\Return) (subseq line 7)))))))
                            (and file (uiop:pathname-equal (uiop:pathname-directory-pathname file)
                                                           (truename bundle))))))
                   (let ((run (%run-bundle executable)))
                     (is (search "KEY OK" run) "the app did not make a key:~%~A" run)
                     (is (loaded-from-bundle-p run) "not loaded from the bundle:~%~A" run))
                   ;; The control.
                   (delete-file carried)
                   (let ((run (%run-bundle executable)))
                     (is (not (loaded-from-bundle-p run))
                         "still loaded from the bundle with the copy deleted:~%~A" run))))
            (aion/fs:delete-tree tree :if-does-not-exist :ignore))))))
