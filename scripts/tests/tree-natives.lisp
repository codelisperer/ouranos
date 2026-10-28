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

(test a-carried-list-that-is-a-link-is-neither-read-nor-written
  "bin/.carried-natives as a link is refused with CARRIED-LIST-REFUSED before it is read, and before
a copied file is appended to it, so nothing outside bin/ is read as the list or written through it
(hub's review of #567). A link to a directory is a junction on Windows and a symbolic link
elsewhere; on Unix a dangling link and a link to a file outside bin/ are checked too."
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (let* ((bin (ensure-directories-exist (merge-pathnames "bin/" tree)))
                (outside (ensure-directories-exist (merge-pathnames "outside/" tree)))
                (list-file (merge-pathnames ouranos-tree-natives:+carried-list-name+ bin)))
           (flet ((refused-p (thunk)
                    (handler-case (progn (funcall thunk) nil)
                      (ouranos-tree-natives:carried-list-refused () t)))
                  (unlink ()
                    (if (uiop:os-windows-p)
                        (aion/fs:delete-link list-file)
                        (uiop:run-program (list "rm" "-f" (uiop:native-namestring list-file))))))
             (%link-to-directory list-file outside)
             (is-true (aion/fs:link-p list-file) "the fixture's link exists")
             (is-true (refused-p (lambda () (ouranos-tree-natives:remove-previously-carried bin)))
                      "a link to a directory is not read")
             (is-true (refused-p (lambda ()
                                   (let ((ouranos-tree-natives::*carried-list* list-file))
                                     (ouranos-tree-natives::%note-carried (merge-pathnames "libx.dll" bin)))))
                      "nor appended to")
             (is (null (uiop:directory-files outside)) "and nothing was written into the directory it names")
             (unlink)
             (unless (uiop:os-windows-p)
               (let ((target (%bytes-file (merge-pathnames "outside.txt" tree) "not bin's")))
                 (uiop:run-program (list "ln" "-s" (uiop:native-namestring (merge-pathnames "absent" tree))
                                         (uiop:native-namestring list-file)))
                 (is-true (refused-p (lambda () (ouranos-tree-natives:remove-previously-carried bin)))
                          "a dangling link is refused, not a backtrace")
                 (unlink)
                 (uiop:run-program (list "ln" "-s" (uiop:native-namestring target) (uiop:native-namestring list-file)))
                 (is-true (refused-p (lambda () (ouranos-tree-natives:remove-previously-carried bin)))
                          "a link to a file outside bin/ is not read")
                 (is-true (refused-p (lambda ()
                                       (let ((ouranos-tree-natives::*carried-list* list-file))
                                         (ouranos-tree-natives::%note-carried (merge-pathnames "libx.so" bin)))))
                          "nor appended to")
                 (is (equal "not bin's" (uiop:read-file-string target)) "and the file it names is unchanged")
                 (unlink)))))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

;;; --- two real builds --------------------------------------------------------------------------

(defun %write-gitbin-app (project &key (libgit t))
  "Write the gitbin app into PROJECT: one that loads aion/libgit when LIBGIT, and one that does
not otherwise.

The two versions are in source files with different names, gitbin.lisp and gitbin-plain.lisp.
With one name, the release-mode CI leg's second build loaded the fasl compiled from the first
version, which names AION/LIBGIT, and failed with a package error (run 38152773865). ASDF keeps
a fasl whose write date equals its source's, and dates have one-second resolution: the first
build wrote the fasl about a second before this test rewrote the source, so the two can fall in
the same second (#573). With two names, no earlier fasl can stand in for the second version."
  (let ((file (if libgit "gitbin" "gitbin-plain")))
    (%write (merge-pathnames "gitbin.asd" project)
            (format nil "(defsystem \"gitbin\" :depends-on (~:[~;\"aion/libgit\"~]) :components ((:file \"~A\")))"
                    libgit file))
    (%write (merge-pathnames (concatenate 'string file ".lisp") project)
            (if libgit
                (%lines "(defpackage #:gitbin (:use #:cl) (:export #:main))"
                        "(in-package #:gitbin)"
                        "(defun main () (format t \"~&LOADED ~A~%\" (aion/libgit:ensure-loaded)) (finish-output) (uiop:quit 0))")
                (%lines "(defpackage #:gitbin (:use #:cl) (:export #:main))"
                        "(in-package #:gitbin)"
                        "(defun main () (format t \"~&NO LIBGIT~%\") (finish-output) (uiop:quit 0))")))))

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
         (cons (%source-registry-variable project)
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


(test a-build-that-stops-after-a-copy-still-lists-what-it-copied
  "The first build copies libgit2 into bin/ and then fails, because bin/LICENSES is a file, so the
licence cannot be copied. The list still names libgit2, because each file is appended as it is
copied. A good build of the app without aion/libgit then removes it (hub's review of #567: the
list used to be written only after every copy, so a failed build left a library no list named,
which shipped again once the app dropped it)."
  (if (null (%built-libgit2))
      (skip "vendor/libgit2 is not built here; run scripts/build-libgit2.lisp")
      (let* ((tree (%fresh-tree))
             (project (ensure-directories-exist (merge-pathnames "gitbin/" tree)))
             (bin (ensure-directories-exist (merge-pathnames "bin/" project)))
             (library (merge-pathnames (file-namestring (%built-libgit2)) bin))
             (list-file (merge-pathnames ouranos-tree-natives:+carried-list-name+ bin)))
        (%write (merge-pathnames "scripts/build-gitbin.lisp" project)
                (uiop:frob-substrings (uiop:read-file-string *cons-bin-build-script*)
                                      '("{{name}}") "gitbin"))
        (unwind-protect
             (progn
               (%write-gitbin-app project :libgit t)
               (%bytes-file (merge-pathnames "LICENSES" bin) "a file where the licence directory goes")
               (multiple-value-bind (code out) (%run-cons-bin-build project)
                 (is (not (eql 0 code)) "the first build fails at the licence, got ~S:~%~A" code out))
               (is-true (probe-file library) "after copying the library")
               (let ((lines (and (probe-file list-file) (uiop:read-file-lines list-file))))
                 (is (member (file-namestring library) lines :test #'string=)
                     "and the list names it: ~S" lines))
               (delete-file (merge-pathnames "LICENSES" bin))
               (%write-gitbin-app project :libgit nil)
               (multiple-value-bind (code out) (%run-cons-bin-build project)
                 (is (eql 0 code) "the second build failed:~%~A" out))
               (is-false (probe-file library) "the second build removed the library the failed build left"))
          (aion/fs:delete-tree tree :if-does-not-exist :ignore)))))

(test a-copy-that-signals-is-still-listed
  "The list names each file before it is copied, so a copy that signals part-way still leaves
the file named, and the next build can remove what it wrote (hub's review of #567: the list was
appended after each copy, so a copy that failed, or a kill during it, left a file no list named).
Here libgit2's copy signals because its destination in bin/ is a directory."
  (if (null (%built-libgit2))
      (skip "vendor/libgit2 is not built here; run scripts/build-libgit2.lisp")
      (let* ((tree (%fresh-tree))
             (project (ensure-directories-exist (merge-pathnames "gitbin/" tree)))
             (bin (ensure-directories-exist (merge-pathnames "bin/" project)))
             (library (file-namestring (%built-libgit2)))
             (list-file (merge-pathnames ouranos-tree-natives:+carried-list-name+ bin)))
        (%write (merge-pathnames "scripts/build-gitbin.lisp" project)
                (uiop:frob-substrings (uiop:read-file-string *cons-bin-build-script*)
                                      '("{{name}}") "gitbin"))
        (unwind-protect
             (progn
               (%write-gitbin-app project :libgit t)
               (ensure-directories-exist (merge-pathnames (concatenate 'string library "/") bin))
               (multiple-value-bind (code out) (%run-cons-bin-build project)
                 (is (not (eql 0 code)) "the build fails at the library's copy, got ~S:~%~A" code out))
               (let ((lines (and (probe-file list-file) (uiop:read-file-lines list-file))))
                 (is (member library lines :test #'string=)
                     "and the list names the library whose copy signalled: ~S" lines)))
          (aion/fs:delete-tree tree :if-does-not-exist :ignore)))))

(test a-cons-bin-build-with-a-linked-carried-list-exits-3
  "A real build of a project whose bin/.carried-natives is a link to a directory outside bin/ (a
junction on Windows, a symbolic link elsewhere) stops with exit code 3 and names the list, and
writes nothing into the directory it points at (hub's review of #567). No library is needed."
  (let* ((tree (%fresh-tree))
         (project (ensure-directories-exist (merge-pathnames "gitbin/" tree)))
         (bin (ensure-directories-exist (merge-pathnames "bin/" project)))
         (outside (ensure-directories-exist (merge-pathnames "outside/" tree))))
    (%write (merge-pathnames "scripts/build-gitbin.lisp" project)
            (uiop:frob-substrings (uiop:read-file-string *cons-bin-build-script*)
                                  '("{{name}}") "gitbin"))
    (unwind-protect
         (progn
           (%write-gitbin-app project :libgit nil)
           (%link-to-directory (merge-pathnames ouranos-tree-natives:+carried-list-name+ bin) outside)
           (multiple-value-bind (code out) (%run-cons-bin-build project)
             (is (eql 3 code) "exit 3, got ~S:~%~A" code out)
             (is (and (search ouranos-tree-natives:+carried-list-name+ out) (search "is a link" out))
                 "naming the list as a link:~%~A" out))
           (is (null (uiop:directory-files outside)) "and nothing was written where the link points"))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

;;; --- the summary line counts what carry-natives.lisp carried for the tree (#912) ----------

(defun %carry-summary (already-carried)
  "The output of CARRY-NATIVE-LIBRARIES with ALREADY-CARRIED, run against an empty vendor/ and
bundle, with no lazily loaded libraries to release."
  (let ((tree (%fresh-tree)))
    (let ((ouranos-tree-natives:*vendor* (ensure-directories-exist (merge-pathnames "vendor/" tree)))
          (ouranos-tree-natives:*bundle* (ensure-directories-exist (merge-pathnames "bundle/" tree)))
          (ouranos-tree-natives::*carried-list* nil)
          (ouranos-tree-natives::*lazy-natives* nil)
          (ouranos-tree-natives::*label* "build-desktop-app")
          (ouranos-tree-natives::*product* "the bundle"))
      (with-output-to-string (*standard-output*)
        (ouranos-tree-natives:carry-native-libraries :already-carried already-carried)))))

(test the-summary-line-counts-the-tree-libraries-an-earlier-step-carried
  "build-desktop-app.lisp carries the tree's SQLite through carry-natives.lisp and closes it
before CARRY-NATIVE-LIBRARIES walks the open libraries, so the walk does not see it. The
summary line said 0 of the tree's libraries were carried when SQLite was (#912). It now adds
the number the earlier step passes in."
  (let ((one (%carry-summary 1))
        (none (%carry-summary 0)))
    (is (search "build-desktop-app: 1 of this tree's native library carried into the bundle." one)
        "with one carried earlier:~%~A" one)
    (is (search "build-desktop-app: 0 of this tree's native libraries carried into the bundle." none)
        "with none carried earlier:~%~A" none)))

;;; --- a carried tree library gets a relative install name on macOS (#957) ------------------

(defun %tree-carry-install-name (stamp)
  "Build the carry-natives fixture's dylibs under a fresh vendor/fix/lib/, then, in a child
image with CFFI, open libfixb.dylib from there and run CARRY-NATIVE-LIBRARIES with that vendor/
into a fresh bundle, with OURANOS-CARRY::*STAMP* bound to STAMP. Returns the carried copy's
install name and the child's output, or NIL when the fixture could not be built. A child image,
because CARRY-NATIVE-LIBRARIES carries what CFFI has open, and this suite does not load CFFI."
  (let* ((tree (%fresh-tree))
         (lib (ensure-directories-exist (merge-pathnames "vendor/fix/lib/" tree)))
         (bundle (ensure-directories-exist (merge-pathnames "bundle/" tree))))
    (unwind-protect
         (when (%dylib-pair lib)
           (let* ((forms
                    (list "(require :asdf)"
                          "(load (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))"
                          "(let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :cffi))"
                          (format nil "(load ~S)" (uiop:native-namestring
                                                   (merge-pathnames "tree-natives.lisp" *scripts*)))
                          (format nil "(setf ouranos-tree-natives:*vendor* (pathname ~S))"
                                  (uiop:native-namestring (merge-pathnames "vendor/" tree)))
                          (format nil "(cffi:load-foreign-library ~S)"
                                  (uiop:native-namestring (merge-pathnames "libfixb.dylib" lib)))
                          (format nil "(let ((ouranos-tree-natives:*bundle* (pathname ~S)) (ouranos-tree-natives::*carried-list* nil) (ouranos-tree-natives::*lazy-natives* nil) (ouranos-tree-natives::*label* \"test\") (ouranos-tree-natives::*product* \"the bundle\") (ouranos-carry::*stamp* ~S)) (ouranos-tree-natives:carry-native-libraries))"
                                  (uiop:native-namestring bundle) stamp)))
                  (out (uiop:run-program
                        (append (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                                      "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive")
                                (loop for f in forms append (list "--eval" f)))
                        :output :string :error-output :output :ignore-error-status t))
                  (carried (merge-pathnames "libfixb.dylib" bundle)))
             (values (and (probe-file carried)
                          (second (uiop:split-string
                                   (string-trim '(#\Newline)
                                                (uiop:run-program (list "otool" "-D" (uiop:native-namestring carried))
                                                                  :output :string :ignore-error-status t))
                                   :separator '(#\Newline))))
                     out)))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(test a-carried-tree-library-is-stamped-with-a-relative-install-name
  "#957: the tree's libuv was carried with the install name it was built with, an absolute path
under vendor/. CARRY-NATIVE-LIBRARIES now stamps a carried library @executable_path/<name>.
Control: with the stamp off, the carried copy keeps the path under the fixture's vendor/."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (progn
          (multiple-value-bind (name out) (%tree-carry-install-name t)
            (is (equal "@executable_path/libfixb.dylib" name) "install name ~S:~%~A" name out))
          (multiple-value-bind (name out) (%tree-carry-install-name nil)
            (is (and name (char= #\/ (char name 0)) (search "/vendor/fix/lib/libfixb.dylib" name))
                "control: without the stamp, the vendor/ path, got ~S:~%~A" name out))))))
