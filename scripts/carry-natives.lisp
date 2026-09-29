;;;; carry-natives.lisp --- carry an app's own native libraries into its desktop bundle (#78)
;;;;
;;;; Loaded by path by scripts/build-desktop-app.lisp, which passes it each `--carry <path>'
;;;; on its command line, and by the checkers suite, which dumps a small image with it.
;;;;
;;;; build-desktop-app.lisp carries the libraries this tree builds, the ones under vendor/
;;;; (ADR-0013). An app can also depend on native libraries of its own, such as a PDF
;;;; renderer kept in the app's repository or a pinned sqlite3.dll: stock Windows has only
;;;; winsqlite3.dll, which is a different name. Before this file, the bundler reported those
;;;; as "system ... not ours to carry" and left them out, so the installed app started and
;;;; then failed the first time it called the library.
;;;;
;;;; Copying the file beside the executable is not enough on its own. SBCL records every
;;;; shared object that is open when the image is dumped, and opens each one again by the
;;;; same path when the image starts. A library the app loaded by absolute path is reopened
;;;; from the build machine's path, which does not exist on the user's machine, and the app
;;;; stops before `main'. So for each declared library that the image has open, this file
;;;;
;;;;   1. copies it beside the executable, with its license text under LICENSES/;
;;;;   2. closes it before the dump, so SBCL does not record the build machine's path;
;;;;   3. adds a function to `sb-ext:*init-hooks*' that opens the copy beside the running
;;;;      executable (`sb-ext:*runtime-pathname*') when the image starts, before `main'.
;;;;
;;;; This is the same rule ADR-0013 uses for libuv: the library is found by absolute path in
;;;; the executable's own directory, which works unchanged on Linux, macOS and Windows,
;;;; inside an AppImage or a .app.
;;;;
;;;; A declared library that the image does not have open when the bundle is built is still
;;;; copied, and the report says the app must open it itself. That is the case for a library
;;;; the app loads on first use: it should look beside `sb-ext:*runtime-pathname*'.
;;;;
;;;; CFFI is reached through symbols looked up at run time, so this file loads in an image
;;;; that has no CFFI. Such an image has no foreign libraries open, and every declared
;;;; library is then reported as not open.

(require :asdf)

(defpackage #:ouranos-carry
  (:use #:cl)
  (:export #:declared-carries
           #:carry-arguments
           #:carry-declared-libraries
           #:carry-refused
           #:open-carried-libraries))

(in-package #:ouranos-carry)

(define-condition carry-refused (error)
  ((path :initarg :path :reader carry-refused-path)
   (reason :initarg :reason :reader carry-refused-reason))
  (:report (lambda (c s)
             (format s "cannot carry ~A: ~A"
                     (uiop:native-namestring (carry-refused-path c))
                     (carry-refused-reason c))))
  (:documentation "A library named with --carry that cannot go into the bundle. The bundle
is not built: a bundle missing a library the app declared would start on the build machine
and fail on a user's."))

(defun declared-carries (argv)
  "The libraries ARGV declares, in order, as a list of (PATH . LICENSES). PATH is the value
after a `--carry'. LICENSES are the values of any `--carry-license' flags that follow it
before the next `--carry'; they name the library's license text when no file beside it or in
the directory above does, as for SQLite, which is public domain and ships none. A
`--carry-license' before any `--carry' signals CARRY-REFUSED."
  (let ((carries '()))
    (loop for (flag value) on argv
          do (cond
               ((and (string= flag "--carry") value)
                (push (list value) carries))
               ((and (string= flag "--carry-license") value)
                (if carries
                    (setf (cdr (first carries)) (append (cdr (first carries)) (list value)))
                    (error 'carry-refused :path (pathname value)
                                          :reason "--carry-license names the license of the --carry before it, and there is none")))))
    (nreverse carries)))

(defun carry-arguments (carries)
  "CARRIES, as returned by DECLARED-CARRIES, as command-line arguments again."
  (loop for (path . licenses) in carries
        append (list "--carry" path)
        append (loop for l in licenses append (list "--carry-license" l))))

(defun %cffi (name)
  "The function CFFI:NAME, or NIL when CFFI is not loaded."
  (let* ((p (find-package "CFFI"))
         (s (and p (find-symbol name p))))
    (and s (fboundp s) (fdefinition s))))

(defun %open-libraries ()
  "((library . truename-or-nil) ...) for every foreign library CFFI has open."
  (let ((list-libs (%cffi "LIST-FOREIGN-LIBRARIES"))
        (lib-path (%cffi "FOREIGN-LIBRARY-PATHNAME")))
    (when (and list-libs lib-path)
      (loop for lib in (funcall list-libs :loaded-only t)
            for path = (funcall lib-path lib)
            collect (cons lib (and path
                                   (or (find #\/ (namestring path)) (find #\\ (namestring path)))
                                   (ignore-errors (truename path))))))))

(defun %same-file-name-p (a b)
  "True when file names A and B are the same, ignoring case on Windows, where the file
system does."
  (if (uiop:os-windows-p) (string-equal a b) (string= a b)))

(defun %matching-open-libraries (truename open)
  "The open libraries in OPEN that are the file TRUENAME, compared as resolved paths. A
library CFFI opened by bare name is matched by file name, because the OS loader found it and
did not say where."
  (loop for (lib . resolved) in open
        when (if resolved
                 (equal resolved truename)
                 (let ((path (funcall (%cffi "FOREIGN-LIBRARY-PATHNAME") lib)))
                   (and path (%same-file-name-p (file-namestring path) (file-namestring truename)))))
          collect lib))

(defun %license-files (truename)
  "License texts for the library at TRUENAME: files and directories whose names start with
LICENSE, COPYING or NOTICE, in any case, in its directory, or else in the directory above it
(win-x64/LICENSE and win-x64/licenses/ for win-x64/bin/pdfium.dll). A directory holds
third-party notices and is carried whole. Names are compared ignoring case because a pattern
given to DIRECTORY is not: it missed a directory named licenses/."
  (flet ((licensep (name)
           (some (lambda (prefix) (and (>= (length name) (length prefix))
                                       (string-equal prefix name :end2 (length prefix))))
                 '("LICENSE" "COPYING" "NOTICE")))
         (dir-name (d) (car (last (pathname-directory d)))))
    (flet ((in (dir)
             (append (remove-if-not (lambda (f) (licensep (file-namestring f)))
                                    (uiop:directory-files dir))
                     (remove-if-not (lambda (d) (licensep (dir-name d)))
                                    (uiop:subdirectories dir)))))
      (let ((dir (uiop:pathname-directory-pathname truename)))
        (or (in dir) (in (uiop:pathname-parent-directory-pathname dir)))))))

(defun %copy-license (license lib-name bundle report)
  "Copy LICENSE, a file or a directory of notices, to BUNDLE/LICENSES/<lib-name>-<its name>."
  (if (uiop:directory-pathname-p license)
      (let ((root (car (last (pathname-directory license)))))
        (dolist (file (directory (merge-pathnames "**/*.*" license)))
          (unless (uiop:directory-pathname-p file)
            (let ((dst (merge-pathnames (uiop:enough-pathname file license)
                                        (merge-pathnames (format nil "LICENSES/~A-~A/" lib-name root)
                                                         bundle))))
              (ensure-directories-exist dst)
              (uiop:copy-file file dst))))
        (format report "~&            + LICENSES/~A-~A/~%" lib-name root))
      (let ((dst (merge-pathnames (format nil "LICENSES/~A-~A" lib-name (file-namestring license))
                                  bundle)))
        (ensure-directories-exist dst)
        (uiop:copy-file license dst)
        (format report "~&            + LICENSES/~A~%" (file-namestring dst)))))

(defun carry-declared-libraries (carries bundle &key vendor (report *standard-output*))
  "Copy each library in CARRIES into the directory BUNDLE, with its license text under
BUNDLE/LICENSES/, and arrange for the dumped image to open the copy at startup.

Each element of CARRIES is a library's path, or a list (PATH . LICENSES) as DECLARED-CARRIES
returns. LICENSES, when given, are the library's license texts; otherwise they are found by
%LICENSE-FILES. A license text can be a file or a directory of notices.

Signals CARRY-REFUSED, before copying anything, when a path or a named license does not exist,
when a path is under VENDOR (the tree's own libraries, which build-desktop-app.lisp already
carries), when two paths have the same file name, or when no license text is found for a
library.

Returns the list of carried file names that the image had open, which are the ones
OPEN-CARRIED-LIBRARIES opens at startup."
  (let* ((open (%open-libraries))
         (plan
           (loop for carry in carries
                 for (path . named) = (if (consp carry) carry (list carry))
                 for truename = (probe-file path)
                 for name = (and truename (file-namestring truename))
                 do (cond
                      ((null truename)
                       (error 'carry-refused :path (pathname path) :reason "the file does not exist"))
                      ((and vendor (probe-file vendor) (uiop:subpathp truename (truename vendor)))
                       (error 'carry-refused :path truename
                                             :reason "it is under vendor/, and the bundler already carries the tree's own libraries")))
                    (dolist (l named)
                      (unless (probe-file l)
                        (error 'carry-refused :path (pathname l)
                                              :reason (format nil "it is named by --carry-license for ~A and does not exist" name))))
                 collect (list truename name
                               (if named (mapcar #'probe-file named) (%license-files truename))
                               (%matching-open-libraries truename open)))))
    (loop for (entry . rest) on plan
          for (truename name) = entry
          when (find name rest :key #'second :test #'%same-file-name-p)
            do (error 'carry-refused :path truename
                                     :reason "another --carry has the same file name, and both would be copied to the same place"))
    (loop for (truename nil licenses) in plan
          unless licenses
            do (error 'carry-refused :path truename
                                     :reason "no LICENSE*, COPYING* or NOTICE* file is beside it or in the directory above it, and no --carry-license names one. The bundle carries a library's license text with its code"))
    (let ((opened '()))
      (loop for (truename name licenses libs) in plan
            for dst = (merge-pathnames name bundle)
            do (ensure-directories-exist dst)
               (uiop:copy-file truename dst)
               (unless (uiop:os-windows-p)
                 (uiop:run-program (list "chmod" "+x" (uiop:native-namestring dst)) :ignore-error-status t))
               (format report "~&  carry     ~A  <- ~A~%" name (uiop:native-namestring truename))
               (dolist (license licenses)
                 (%copy-license license (pathname-name name) bundle report))
               (cond
                 (libs
                  (dolist (lib libs) (funcall (%cffi "CLOSE-FOREIGN-LIBRARY") lib))
                  (push name opened)
                  (format report "~&            opened beside the executable when the app starts~%"))
                 (t
                  (format report "~&            not open in this image, so the app must open it itself, from beside sb-ext:*runtime-pathname*~%"))))
      (setf opened (nreverse opened))
      (when opened
        (let ((names opened))
          (push (lambda () (open-carried-libraries names)) sb-ext:*init-hooks*)))
      opened)))

(defun open-carried-libraries (names)
  "Open each file in NAMES from the directory of the running executable. Run from
`sb-ext:*init-hooks*' when a dumped app starts. A library that does not open ends the app
with exit code 3 and a message naming the file, because the app cannot run without it."
  (let ((dir (uiop:pathname-directory-pathname sb-ext:*runtime-pathname*))
        (load-lib (%cffi "LOAD-FOREIGN-LIBRARY")))
    (dolist (name names)
      (let ((path (merge-pathnames name dir)))
        (handler-case (funcall load-lib path)
          (error (e)
            (format *error-output* "~&This app cannot open ~A, which it carries beside its executable:~%  ~A~%~A~%"
                    name (uiop:native-namestring path) e)
            (finish-output *error-output*)
            (sb-ext:exit :code 3 :abort t)))))))
