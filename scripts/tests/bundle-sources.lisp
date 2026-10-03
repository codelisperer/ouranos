;;;; bundle-sources.lisp --- a bundle that carries libgit2 carries its source and its licence
;;;; (ADR-0013's amendment of 2026-10-01, #429)
;;;;
;;;; The rules live in scripts/bundle-sources.lisp, which the bundler and
;;;; scripts/check-bundle-sources.lisp both load. These tests run them against fixture trees and
;;;; bundles made here, with a pin and a tarball of their own, so they need no built libgit2.
;;;; The last test builds a real bundle for an app that loads aion/libgit and runs it.

(in-package #:checkers/tests)

;;; FiveAM's current suite does not carry over from one file to the next (see dump-image.lisp).
(in-suite checkers)

;;; At compile time too: the tests below name the package it defines.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames "bundle-sources.lisp" *scripts*)))

(defun %bytes-file (path text)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede)
    (write-string text out))
  path)

(defun %fixture-source-tree (&key (tarball-text "pretend libgit2 source") (pin-sha :right))
  "A fresh tree with libgit2.pin naming version 9.9.9 and a tarball under vendor/libgit2/src/.
PIN-SHA is :RIGHT for the tarball's real sha256, or a string to pin instead."
  (let* ((tree (%fresh-tree))
         (tarball (%bytes-file (merge-pathnames "vendor/libgit2/src/libgit2-9.9.9.tar.gz" tree)
                               tarball-text)))
    (%bytes-file (merge-pathnames "libgit2.pin" tree)
                 (format nil "# fixture~%version 9.9.9~%sha256  ~A~%"
                         (if (eq pin-sha :right) (ouranos-bundle-sources:sha256-of tarball) pin-sha)))
    tree))

(defun %fixture-bundle (tree &key (library t) (source t) (licence t))
  "A fresh bundle directory under TREE, with the parts asked for."
  (let ((bundle (ensure-directories-exist (merge-pathnames "bundle/" tree))))
    (when library (%bytes-file (merge-pathnames "libgit2.1.9.dylib" bundle) "library"))
    (when source
      (uiop:copy-file (merge-pathnames "vendor/libgit2/src/libgit2-9.9.9.tar.gz" tree)
                      (ensure-directories-exist (merge-pathnames "SOURCES/libgit2-9.9.9.tar.gz" bundle))))
    (when licence (%bytes-file (merge-pathnames "LICENSES/libgit2-COPYING" bundle) "GPLv2"))
    bundle))

(test a-bundle-carrying-libgit2-needs-its-pinned-source-and-its-licence
  "Complete, it passes. CONTROLS: without the tarball, with a tarball that is not the pinned
one, and without the licence, it fails and says which; a bundle without libgit2 needs neither."
  (let ((tree (%fixture-source-tree)))
    (unwind-protect
         (flet ((problems (&rest parts)
                  (aion/fs:delete-tree (merge-pathnames "bundle/" tree) :if-does-not-exist :ignore)
                  (ouranos-bundle-sources:check-bundle (apply #'%fixture-bundle tree parts) tree)))
           (is (null (problems)))
           (is (search "not its source" (format nil "~{~A~}" (problems :source nil))))
           (is (search "not its licence" (format nil "~{~A~}" (problems :licence nil))))
           (is (null (problems :library nil :source nil :licence nil))
               "a bundle without libgit2 needs neither")
           (let ((bundle (%fixture-bundle tree)))
             (%bytes-file (merge-pathnames "SOURCES/libgit2-9.9.9.tar.gz" bundle) "something else")
             (is (search "not the pinned source"
                         (format nil "~{~A~}" (ouranos-bundle-sources:check-bundle bundle tree))))))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(test the-bundler-refuses-a-source-tarball-that-is-not-the-pinned-one
  "CARRY-SOURCE, which the bundler calls, copies the tarball into SOURCES/ when its sha256 is
the pin's. CONTROL: with another sha256 pinned it signals SOURCE-REFUSED and copies nothing."
  (let ((entry (ouranos-bundle-sources:source-for-package "libgit2")))
    (let ((tree (%fixture-source-tree)))
      (unwind-protect
           (let* ((bundle (ensure-directories-exist (merge-pathnames "bundle/" tree)))
                  (copy (ouranos-bundle-sources:carry-source entry tree bundle)))
             (is (probe-file copy))
             (is (string= "libgit2-9.9.9.tar.gz" (file-namestring copy))))
        (aion/fs:delete-tree tree :if-does-not-exist :ignore)))
    (let ((tree (%fixture-source-tree :pin-sha (make-string 64 :initial-element #\0))))
      (unwind-protect
           (let ((bundle (ensure-directories-exist (merge-pathnames "bundle/" tree))))
             (signals ouranos-bundle-sources:source-refused
               (ouranos-bundle-sources:carry-source entry tree bundle))
             (is (null (probe-file (merge-pathnames "SOURCES/libgit2-9.9.9.tar.gz" bundle)))))
        (aion/fs:delete-tree tree :if-does-not-exist :ignore)))))

(test check-bundle-sources-exits-1-on-a-bundle-missing-its-source
  "The script the verify-bundle scripts run: exit 0 on a complete bundle, 1 on one without its
source. It reads the pin at the tree it lives in, so the fixture is a copy of scripts/ with its
own pin and tarball."
  (let ((tree (%fixture-source-tree)))
    (unwind-protect
         (progn
           (dolist (name '("bundle-sources.lisp" "check-bundle-sources.lisp"))
             (uiop:copy-file (merge-pathnames name *scripts*)
                             (ensure-directories-exist (merge-pathnames (concatenate 'string "scripts/" name) tree))))
           (flet ((run-check (bundle)
                    (nth-value 2 (uiop:run-program
                                  (list (uiop:native-namestring sb-ext:*runtime-pathname*) "--script"
                                        (uiop:native-namestring (merge-pathnames "scripts/check-bundle-sources.lisp" tree))
                                        (uiop:native-namestring bundle))
                                  :input nil :output nil :error-output nil :ignore-error-status t))))
             (is (eql 0 (run-check (%fixture-bundle tree))))
             (aion/fs:delete-tree (merge-pathnames "bundle/" tree))
             (is (eql 1 (run-check (%fixture-bundle tree :source nil))))))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

;;; --- a real bundle of an app that uses aion/libgit -------------------------------------

(defun %built-libgit2 ()
  "The libgit2 this tree built under vendor/, or NIL."
  (loop for name in '("git2.dll" "libgit2.so.1.9" "libgit2.1.9.dylib")
        for path = (probe-file (merge-pathnames (concatenate 'string "vendor/libgit2/lib/" name) td-root))
        when path return path))

(test a-bundle-of-an-aion-libgit-app-carries-libgit2-with-its-source
  "Built with the real build-desktop-app.lisp: the bundle carries libgit2, its pinned source
and its licence, and check-bundle-sources passes on it. Run, the app loads libgit2 from the
bundle. CONTROL: with the carried copy deleted the app does not load it, because a bundle does
not search the tree it was built from (#472)."
  (if (null (%built-libgit2))
      (skip "vendor/libgit2 is not built here; run scripts/build-libgit2.lisp")
      (let* ((tree (%fresh-tree))
             (app (ensure-directories-exist (merge-pathnames "app/" tree)))
             (dist (merge-pathnames "dist/" tree))
             (build-out (make-string-output-stream)))
        (%write (merge-pathnames "gitprobe.asd" app)
                "(defsystem \"gitprobe\" :depends-on (\"aion/libgit\") :components ((:file \"gitprobe\")))")
        (%write (merge-pathnames "gitprobe.lisp" app)
                (%lines "(defpackage #:gitprobe (:use #:cl) (:export #:main))"
                        "(in-package #:gitprobe)"
                        "(defun main ()"
                        "  (handler-case (format t \"~&LOADED ~A~%VERSION ~A~%\" (aion/libgit:ensure-loaded) (aion/libgit:libgit2-version))"
                        "    (error (e) (format t \"~&FAILED ~A~%\" (type-of e))))"
                        "  (finish-output)"
                        "  (uiop:quit 0))"))
        (unwind-protect
             (progn
               (let ((code (nth-value
                            2 (uiop:run-program
                               (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                                     "--dynamic-space-size" "4096" "--script"
                                     (uiop:native-namestring (merge-pathnames "build-desktop-app.lisp" *scripts*))
                                     "--system" "gitprobe" "--entry" "gitprobe:main" "--name" "gitprobe"
                                     "--version" "0.0.1" "--out" (uiop:native-namestring dist))
                               :input nil :output build-out :error-output build-out :ignore-error-status t
                               :environment
                               (cons (format nil "CL_SOURCE_REGISTRY=~A//~A~A//"
                                             (uiop:native-namestring td-root)
                                             (if (uiop:os-windows-p) ";" ":")
                                             (uiop:native-namestring app))
                                     (remove-if (lambda (e) (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e))
                                                (sb-ext:posix-environ)))))))
                 (is (eql 0 code) "the build failed:~%~A" (get-output-stream-string build-out)))
               (let* ((bundle (find-if (lambda (d) (uiop:string-prefix-p
                                                    "gitprobe-" (car (last (pathname-directory d)))))
                                       (uiop:subdirectories dist)))
                      (executable (and bundle (merge-pathnames (if (uiop:os-windows-p) "gitprobe.exe" "gitprobe")
                                                               bundle)))
                      (carried (and bundle (merge-pathnames (file-namestring (%built-libgit2)) bundle))))
                 (when (is (and executable (probe-file executable)) "no executable in ~A" bundle)
                   (is (probe-file carried) "~A was not carried" (file-namestring carried))
                   (is (probe-file (merge-pathnames "LICENSES/libgit2-COPYING" bundle)))
                   (is (directory (merge-pathnames "SOURCES/libgit2-*.tar.gz" bundle)))
                   (is (null (ouranos-bundle-sources:check-bundle bundle td-root)))
                   (flet ((run-app ()
                            (let ((out (make-string-output-stream)))
                              (let ((code (nth-value 2 (uiop:run-program
                                                        (list (uiop:native-namestring executable))
                                                        :input nil :output out :error-output out
                                                        :ignore-error-status t
                                                        :environment
                                                        (remove-if (lambda (e) (uiop:string-prefix-p "AION_LIBGIT_LIBRARY=" e))
                                                                   (sb-ext:posix-environ))))))
                                (values (get-output-stream-string out) code))))
                          (loaded-from-bundle-p (output)
                            (let* ((line (find-if (lambda (l) (uiop:string-prefix-p "LOADED " l))
                                                  (uiop:split-string output :separator '(#\Newline))))
                                   (file (and line (ignore-errors
                                                    (truename (string-trim '(#\Return) (subseq line 7)))))))
                              (and file (uiop:pathname-equal (uiop:pathname-directory-pathname file)
                                                             (truename bundle))))))
                     (multiple-value-bind (out code) (run-app)
                       (is (eql 0 code) "the app exited with ~A:~%~A" code out)
                       (is (loaded-from-bundle-p out) "not loaded from the bundle:~%~A" out))
                     ;; The control.
                     (delete-file carried)
                     (multiple-value-bind (out code) (run-app)
                       (is (eql 0 code) "the app exited with ~A:~%~A" code out)
                       (is (search "FAILED" out) "with its copy deleted the app still loaded libgit2:~%~A" out))))))
          (aion/fs:delete-tree tree :if-does-not-exist :ignore)))))

(test the-digest-is-read-from-every-sha256-tool-s-output
  "sha256sum from Git for Windows puts a backslash before the digest when the path has one, and
certutil may space its digest out. The digest is the 64 hex digits, wherever they are. The first
word, which the first version took, failed #518's Windows run on the backslash."
  (let ((digest "1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7"))
    (is (string= digest (ouranos-bundle-sources::%hex-digest
                         (format nil "\\~A *D:\\a\\ouranos\\vendor\\libgit2-1.9.7.tar.gz~%" digest))))
    (is (string= digest (ouranos-bundle-sources::%hex-digest
                         (format nil "~A  vendor/libgit2-1.9.7.tar.gz~%" (string-upcase digest)))))
    (is (string= digest (ouranos-bundle-sources::%hex-digest
                         (format nil "SHA256 hash of x:~%~A~%CertUtil: -hashfile command completed successfully.~%"
                                 digest))))
    (is (null (ouranos-bundle-sources::%hex-digest "no digest here")))))

(test sha256-of-agrees-with-ironclad
  "The digest this platform's sha256 tool gives, as SHA256-OF reads it, is the one ironclad
computes for the same file: a second reading by different code, on every CI leg."
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (let ((file (%bytes-file (merge-pathnames "sample.bin" tree) "the bytes a tarball would have")))
           (is (string= (%sha256-hex file) (ouranos-bundle-sources:sha256-of file))))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))
