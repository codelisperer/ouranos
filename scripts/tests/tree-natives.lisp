;;;; tree-natives.lisp --- what CARRY-TREE-NATIVES leaves in bin/, and how it decides a library
;;;; is the tree's own (#564)
;;;;
;;;; scripts/tree-natives.lisp is the code `cons bin' and build-desktop-app.lisp carry this tree's
;;;; libraries with. These tests load it by path, as both callers do. The last test builds a real
;;;; project twice with the cli template's build script, so it needs a built vendor/libgit2.

(in-package #:checkers/tests)

;;; FiveAM's current suite does not carry over from one file to the next (see dump-image.lisp).
(in-suite checkers)

;;; At compile time too: the tests below name the package it defines.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames "tree-natives.lisp" *scripts*)))

;;; --- one form of vendor/ for the check and the copy ----------------------------------------

(defun %link-directory (link target)
  "Make LINK a symbolic link to the directory TARGET. Unix only."
  (uiop:run-program (list "ln" "-s" (uiop:native-namestring (uiop:ensure-directory-pathname target))
                          (string-right-trim "/" (uiop:native-namestring link)))))

(test a-library-reached-through-a-linked-tree-is-the-tree-s-own
  "A tree reached through a symbolic link: *VENDOR* is spelled through the link, and a library's
resolved path is not. VENDORED-LIBRARY-P still says the library is the tree's. The comparison
the copy used to make, against *VENDOR* as spelled, says it is not, which is how the check and
the copy came to disagree (#564)."
  (if (uiop:os-windows-p)
      (skip "SBCL's TRUENAME does not resolve a junction on Windows, so both forms of vendor/ are the same there")
      (let* ((tree (%fresh-tree))
             (real (ensure-directories-exist (merge-pathnames "real/vendor/libx/lib/" tree)))
             (library (%bytes-file (merge-pathnames "libx.so.1" real) "library"))
             (link (merge-pathnames "linked" tree)))
        (unwind-protect
             (progn
               (%link-directory link (merge-pathnames "real/" tree))
               (let* ((ouranos-tree-natives:*vendor* (merge-pathnames "linked/vendor/" tree))
                      (resolved (truename (merge-pathnames "linked/vendor/libx/lib/libx.so.1" tree))))
                 (is (uiop:pathname-equal resolved (truename library))
                     "the library's resolved path is the real one: ~A" resolved)
                 (is-false (uiop:subpathp resolved ouranos-tree-natives:*vendor*)
                           "compared with vendor/ as spelled, it is outside, as the copy used to decide")
                 (is-true (ouranos-tree-natives:vendored-library-p resolved)
                          "and VENDORED-LIBRARY-P says it is the tree's")
                 (is-false (ouranos-tree-natives:vendored-library-p
                            (truename (%bytes-file (merge-pathnames "elsewhere/libx.so.1" tree) "other")))
                           "while a library outside vendor/ is not")))
          ;; The link first, without a trailing slash, so nothing follows it into real/.
          (uiop:run-program (list "rm" "-f" (string-right-trim "/" (uiop:native-namestring link)))
                            :ignore-error-status t)
          (aion/fs:delete-tree tree :if-does-not-exist :ignore)))))

;;; --- the carried list -----------------------------------------------------------------------

(test remove-previously-carried-deletes-what-the-list-names-and-nothing-else
  "The files the carried list names are deleted, with the list. A file the list does not name,
like one an app keeps in bin/, stays. A line naming a path outside the directory, absolute or
with .., is not acted on (#564)."
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (let* ((bin (ensure-directories-exist (merge-pathnames "bin/" tree)))
                (library (%bytes-file (merge-pathnames "libgit2.so.1.9" bin) "library"))
                (licence (%bytes-file (merge-pathnames "LICENSES/libgit2-COPYING" bin) "licence"))
                (source (%bytes-file (merge-pathnames "SOURCES/libgit2-1.9.7.tar.gz" bin) "source"))
                (kept (%bytes-file (merge-pathnames "app-data.txt" bin) "the app's"))
                (outside (%bytes-file (merge-pathnames "outside.txt" tree) "not bin's")))
           (%bytes-file (merge-pathnames ouranos-tree-natives:+carried-list-name+ bin)
                        (format nil "libgit2.so.1.9~%LICENSES/libgit2-COPYING~%SOURCES/libgit2-1.9.7.tar.gz~%../outside.txt~%~A~%~%"
                                (uiop:native-namestring outside)))
           (let ((deleted (ouranos-tree-natives:remove-previously-carried bin)))
             (is (= 3 (length deleted)) "three files deleted: ~S" deleted))
           (is-false (probe-file library) "the library is gone")
           (is-false (probe-file licence) "its licence is gone")
           (is-false (probe-file source) "its source is gone")
           (is-true (probe-file kept) "a file the list does not name stays")
           (is-true (probe-file outside) "a line naming a file outside bin/ is not acted on")
           (is-false (probe-file (merge-pathnames ouranos-tree-natives:+carried-list-name+ bin))
                     "the list itself is gone")
           (is (null (ouranos-tree-natives:remove-previously-carried bin))
               "with no list, nothing is deleted"))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

;;; --- a list that leads outside bin/ ------------------------------------------------------------

(defun %link-to-directory (link target)
  "Make LINK point at the directory TARGET: a junction on Windows, a symbolic link elsewhere."
  (let ((link (string-right-trim "/\\" (uiop:native-namestring link)))
        (target (string-right-trim "/\\" (uiop:native-namestring target))))
    (if (uiop:os-windows-p)
        (uiop:run-program (list "cmd" "/c" "mklink" "/J" link target) :output nil)
        (uiop:run-program (list "ln" "-s" target link)))))

(test a-carried-list-line-that-leads-outside-bin-is-refused
  "bin/.carried-natives is a plain file anyone can edit. A line naming a file through a directory
in bin/ that is a link (a junction on Windows, a symbolic link elsewhere), a line naming a link,
a line naming a directory, and a line with .. are each refused, and what they name is left. A
line naming a missing file is skipped. A file inside bin/ is still deleted (#564)."
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (let* ((bin (ensure-directories-exist (merge-pathnames "bin/" tree)))
                (outside (ensure-directories-exist (merge-pathnames "outside/" tree)))
                (victim (%bytes-file (merge-pathnames "victim.txt" outside) "not bin's"))
                (outside-file (%bytes-file (merge-pathnames "outside-file.txt" tree) "not bin's"))
                (licence (%bytes-file (merge-pathnames "LICENSES/libx-LICENSE" bin) "licence"))
                (inside (%bytes-file (merge-pathnames "libx.dll" bin) "library"))
                (unix (not (uiop:os-windows-p))))
           (%link-to-directory (merge-pathnames "linked" bin) outside)
           (when unix
             (uiop:run-program (list "ln" "-s" (uiop:native-namestring outside-file)
                                     (uiop:native-namestring (merge-pathnames "filelink" bin)))))
           (is-true (aion/fs:link-p (merge-pathnames "linked" bin)) "the fixture's link exists")
           (%bytes-file (merge-pathnames ouranos-tree-natives:+carried-list-name+ bin)
                        (format nil "linked/victim.txt~%LICENSES~%~:[~;filelink~%~]missing.dll~%../outside-file.txt~%libx.dll~%"
                                unix))
           (let* ((output (make-string-output-stream))
                  (deleted (let ((*standard-output* output))
                             (ouranos-tree-natives:remove-previously-carried bin)))
                  (said (get-output-stream-string output)))
             (is (equal (list (namestring inside)) (mapcar #'namestring deleted))
                 "only the file inside bin/ was deleted: ~S" deleted)
             (is-true (probe-file victim) "a file reached through a linked directory is left")
             (is (search "linked/victim.txt" said) "and that line is reported as refused: ~A" said)
             (is-true (probe-file licence) "a line naming a directory leaves the directory and its files")
             (is-true (probe-file outside-file) "a line with .. leaves the file it names")
             (when unix
               (is-true (aion/fs:link-p (merge-pathnames "filelink" bin))
                        "a line naming a symbolic link leaves the link")
               (is (search "filelink" said) "and that line is reported as refused: ~A" said))
             (is-false (probe-file inside) "the file inside bin/ is gone")))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

;;; --- two real builds --------------------------------------------------------------------------

(defun %write-gitbin-app (project &key (libgit t))
  "Write the gitbin app into PROJECT: one that loads aion/libgit when LIBGIT, and one that does
not otherwise."
  (%write (merge-pathnames "gitbin.asd" project)
          (format nil "(defsystem \"gitbin\" :depends-on (~:[~;\"aion/libgit\"~]) :components ((:file \"gitbin\")))"
                  libgit))
  (%write (merge-pathnames "gitbin.lisp" project)
          (if libgit
              (%lines "(defpackage #:gitbin (:use #:cl) (:export #:main))"
                      "(in-package #:gitbin)"
                      "(defun main () (format t \"~&LOADED ~A~%\" (aion/libgit:ensure-loaded)) (finish-output) (uiop:quit 0))")
              (%lines "(defpackage #:gitbin (:use #:cl) (:export #:main))"
                      "(in-package #:gitbin)"
                      "(defun main () (format t \"~&NO LIBGIT~%\") (finish-output) (uiop:quit 0))"))))

(defun %run-cons-bin-build (project)
  "Run PROJECT's scripts/build-gitbin.lisp in a fresh sbcl, in PROJECT's directory, as `cons bin'
does. Returns (values EXIT-CODE OUTPUT)."
  (let ((out (make-string-output-stream)))
    (values
     (nth-value
      2 (uiop:run-program
         (list (uiop:native-namestring sb-ext:*runtime-pathname*)
               "--dynamic-space-size" "4096" "--non-interactive" "--no-sysinit" "--no-userinit" "--load"
               (uiop:native-namestring (merge-pathnames "scripts/build-gitbin.lisp" project)))
         :directory project :input nil :output out :error-output out :ignore-error-status t
         :environment
         (cons (format nil "CL_SOURCE_REGISTRY=~A//~A~A//"
                       (uiop:native-namestring td-root)
                       (if (uiop:os-windows-p) ";" ":")
                       (uiop:native-namestring project))
               (remove-if (lambda (e) (or (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e)
                                          (uiop:string-prefix-p "AION_LIBGIT_LIBRARY=" e)))
                          (sb-ext:posix-environ)))))
     (get-output-stream-string out))))

(test a-second-cons-bin-build-without-aion-libgit-leaves-no-libgit2-in-bin
  "Build bin/ for an app that loads aion/libgit, so libgit2, its licence and its source are
carried. Change the app so it no longer loads aion/libgit and build again: libgit2, its licence
and its source are gone from bin/, and a file the app keeps in bin/ is still there (#564). Before
this, the second build left all three, and the docs say to ship bin/ as a whole."
  (if (null (%built-libgit2))
      (skip "vendor/libgit2 is not built here; run scripts/build-libgit2.lisp")
      (let* ((tree (%fresh-tree))
             (project (ensure-directories-exist (merge-pathnames "gitbin/" tree)))
             (bin (merge-pathnames "bin/" project))
             (library (file-namestring (%built-libgit2))))
        (%write (merge-pathnames "scripts/build-gitbin.lisp" project)
                (uiop:frob-substrings (uiop:read-file-string *cons-bin-build-script*)
                                      '("{{name}}") "gitbin"))
        (flet ((libgit2-files ()
                 ;; By name prefix, over each directory's files: a wildcard pathname such as
                 ;; libgit2-* matches only files with no extension, and the tarball has one.
                 (flet ((named (dir test)
                          (remove-if-not (lambda (f) (funcall test (file-namestring f)))
                                         (uiop:directory-files (merge-pathnames dir bin)))))
                   (append (named "" (lambda (n) (string= n library)))
                           (named "LICENSES/" (lambda (n) (uiop:string-prefix-p "libgit2-" n)))
                           (named "SOURCES/" (lambda (n) (uiop:string-prefix-p "libgit2-" n)))))))
          (unwind-protect
               (progn
                 (%write-gitbin-app project :libgit t)
                 (multiple-value-bind (code out) (%run-cons-bin-build project)
                   (is (eql 0 code) "the first build failed:~%~A" out))
                 (is (= 3 (length (libgit2-files)))
                     "the first build carried libgit2, its licence and its source: ~S" (libgit2-files))
                 (%bytes-file (merge-pathnames "app-data.txt" bin) "the app's own file")
                 (%write-gitbin-app project :libgit nil)
                 (multiple-value-bind (code out) (%run-cons-bin-build project)
                   (is (eql 0 code) "the second build failed:~%~A" out)
                   (is (search "removed 3 files an earlier build copied" out)
                       "and said it removed the three files:~%~A" out))
                 (is (null (libgit2-files))
                     "the second build left no libgit2 file in bin/: ~S" (libgit2-files))
                 (is-true (probe-file (merge-pathnames "app-data.txt" bin))
                          "and left the app's own file"))
            (aion/fs:delete-tree tree :if-does-not-exist :ignore))))))
