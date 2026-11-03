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
;;; The BUILT-FROM stamp's one format, shared with the scripts that write it (#977).
(load (merge-pathnames "built-from.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(defpackage #:ouranos-carry
  (:use #:cl)
  (:export #:declared-carries
           #:carry-arguments
           #:carry-declared-libraries
           #:carry-refused
           #:open-carried-libraries #:runtime-directory
           #:stamp-install-name #:relink-bundle #:*carried-origins*
           #:sqlite-file-name
           #:tree-sqlite-carry))

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

(defun %spec-file-names (lib)
  "The file names LIB's CFFI definition lists for this platform, with the platform's suffix
added to each (:default \"name\"). cl-sqlite's `(:or (:default \"libsqlite3\") (:default
\"sqlite3\"))' gives (\"libsqlite3.dll\" \"sqlite3.dll\") on Windows. FOREIGN-LIBRARY-SPEC and
DEFAULT-LIBRARY-SUFFIX are internal to CFFI, so they are looked up, and a missing one gives
no names."
  (let ((spec-fn (let ((s (find-symbol "FOREIGN-LIBRARY-SPEC" "CFFI"))) (and s (fboundp s) s)))
        (suffix-fn (let ((s (find-symbol "DEFAULT-LIBRARY-SUFFIX" "CFFI"))) (and s (fboundp s) s))))
    (when spec-fn
      (let ((suffix (or (and suffix-fn (ignore-errors (funcall suffix-fn))) ""))
            (names '()))
        (labels ((walk (x)
                   (cond ((stringp x) (push (file-namestring x) names))
                         ((and (consp x) (eq (first x) :default) (stringp (second x)))
                          (push (concatenate 'string (file-namestring (second x)) suffix) names))
                         ((consp x) (mapc #'walk (rest x))))))
          (walk (ignore-errors (funcall spec-fn lib))))
        (nreverse names)))))

(defun %matching-open-libraries (truename open)
  "The open libraries in OPEN that are the file TRUENAME, compared as resolved paths.

A library CFFI opened by bare name cannot be compared that way, because the OS loader found it
and did not say where. It matches when its name is TRUENAME's file name, or when its CFFI
definition lists TRUENAME's file name as one of its alternatives. The second case is
cl-sqlite on a machine where Ouranos's setup installed libsqlite3.dll: the image opened
libsqlite3.dll, the app carries its pinned sqlite3.dll, and both are names the definition asks
for. Unmatched, SBCL would reopen libsqlite3.dll by bare name when the app starts, from
wherever the user's search path leads."
  (let ((name (file-namestring truename)))
    (loop for (lib . resolved) in open
          when (or (if resolved
                       (equal resolved truename)
                       (let ((path (funcall (%cffi "FOREIGN-LIBRARY-PATHNAME") lib)))
                         (and path (%same-file-name-p (file-namestring path) name))))
                   (member name (%spec-file-names lib) :test #'%same-file-name-p))
            collect lib)))

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

(defvar *relink* t
  "Whether CARRY-DECLARED-LIBRARIES relinks carried Mach-O files to each other on macOS. Only a
test turns it off, as the control for the relink.")

(defun %run-tool (args)
  "Run ARGS, returning (values OUTPUT EXIT-CODE). Output includes standard error."
  (multiple-value-bind (out err code)
      (uiop:run-program args :output :string :error-output :string :ignore-error-status t)
    (values (concatenate 'string out err) code)))

(defun %macho-p (file)
  "Whether FILE starts with a Mach-O or universal (fat) header, read from its first four bytes,
so the answer does not depend on otool being installed."
  (with-open-file (in file :element-type '(unsigned-byte 8) :if-does-not-exist nil)
    (and in
         (let ((magic (make-array 4 :element-type '(unsigned-byte 8))))
           (and (= 4 (read-sequence magic in))
                (member (coerce magic 'list)
                        '((#xfe #xed #xfa #xce) (#xce #xfa #xed #xfe)
                          (#xfe #xed #xfa #xcf) (#xcf #xfa #xed #xfe)
                          (#xca #xfe #xba #xbe) (#xbe #xba #xfe #xca))
                        :test #'equal)
                t)))))

(defun %otool (flag file)
  "The output of `otool FLAG FILE'. Signals CARRY-REFUSED when FILE is a Mach-O and otool exits
non-zero. Without the Xcode Command Line Tools, /usr/bin/otool is a stub that does exactly that,
and reading its silence as \"nothing to change\" would ship the file unchanged (#958's review).
NIL for a file that is not a Mach-O and that otool cannot read."
  (multiple-value-bind (out code) (%run-tool (list "otool" flag (uiop:native-namestring file)))
    (cond ((eql code 0) out)
          ((%macho-p file)
           (error 'carry-refused
                  :path file
                  :reason (format nil "otool ~A exited ~A on it, so it cannot be checked or relinked. otool comes with the Xcode Command Line Tools (xcode-select --install): ~A"
                                  flag code (string-trim '(#\Newline #\Space) out)))))))

(defun %install-name (file)
  "FILE's own install name, as otool -D prints it, or NIL for a file that has none. Signals
CARRY-REFUSED when FILE is a Mach-O that otool cannot read (%OTOOL)."
  (let ((out (%otool "-D" file)))
    (and out
         (second (uiop:split-string (string-trim '(#\Newline) out) :separator '(#\Newline))))))

(defvar *stamp* t
  "Whether STAMP-INSTALL-NAME changes anything. Only a test turns it off, as the control for
the stamp.")

(defvar *carried-origins* '()
  "(DESTINATION INSTALL-NAME SOURCE) for each library STAMP-INSTALL-NAME was given, newest first:
the truename of the copy in the bundle, the copy's install name before the stamp changed it, and
the truename of the file it was copied from, or NIL when the caller did not say. RELINK-BUNDLE
reads it to find a library that another carry step copied under a different file name (#1130).")

(defun %record-origin (file source)
  "Record FILE, a library just copied into a bundle from SOURCE, in *CARRIED-ORIGINS*, with its
install name as it is now."
  (let ((dst (ignore-errors (truename file))))
    (when dst
      (push (list dst (%install-name file) (and source (ignore-errors (truename source))))
            *carried-origins*))))

(defun stamp-install-name (file &key (report *standard-output*) source)
  "On macOS, when FILE, a dylib just copied into a bundle, has an absolute install name, set it
to @executable_path/<file name> and re-sign FILE ad hoc (#957). Returns the new install name
when it changed FILE, otherwise NIL.

A dylib built outside a bundle keeps the path it was built at as its install name, such as the
tree's vendor/libuv/lib/libuv.1.dylib or a Homebrew prefix. Nothing loads a carried copy by that
name, but the shipped file would then carry a path from the build machine. @executable_path/ is
where the copy is, beside the executable, and the form the runtime's own load commands use
(ADR-0014). An install name that is already relative, such as ./libpdfium.dylib, names no
machine and is left as it is. Changing the install name invalidates the signature, and arm64
does not load an invalidly signed dylib, so FILE is re-signed with `codesign --force -s -'.

When install_name_tool cannot set the new name, FILE is left as it was, with its signature
intact, a warning naming the reason goes to REPORT, and this returns NIL. That happens when the
header has no room for the longer name, for a dylib linked with a short absolute install name
and without -headerpad_max_install_names. The stamp only removes a build-machine path that
nothing loads the copy by, so the bundle still works without it (#958's review).

Before anything changes, FILE's install name and SOURCE, the file it was copied from, are
recorded in *CARRIED-ORIGINS*, also when *STAMP* is NIL. Each carry step calls this for every
library it copies, so the record covers all of them, and RELINK-BUNDLE uses it after the last
step (#1130).

Signals CARRY-REFUSED when FILE is a Mach-O that otool cannot read (%OTOOL), and when codesign
cannot re-sign FILE after its install name changed."
  (when (uiop:os-macosx-p)
    (%record-origin file source))
  (when (and *stamp* (uiop:os-macosx-p))
    (let ((id (%install-name file))
          (path (uiop:native-namestring file)))
      (when (and id (plusp (length id)) (char= (char id 0) #\/))
        (let ((new (concatenate 'string "@executable_path/" (file-namestring file))))
          (multiple-value-bind (out code) (%run-tool (list "install_name_tool" "-id" new path))
            (cond
              ((eql code 0)
               (multiple-value-bind (out code) (%run-tool (list "codesign" "--force" "-s" "-" path))
                 (unless (eql code 0)
                   (error 'carry-refused :path file
                                         :reason (format nil "codesign could not re-sign it after its install name changed: ~A" out))))
               (format report "~&            install name is now ~A~%" new)
               new)
              (t
               (format report "~&            warning: install name left as ~A, because install_name_tool could not set it to ~A: ~A~%"
                       id new (string-trim '(#\Newline #\Space) out))
               nil))))))))

(defun %macho-dependencies (file)
  "The install names FILE's load commands name, as otool -L lists them, without FILE's own
install name (otool -D). NIL for a file that is not a Mach-O. Signals CARRY-REFUSED when FILE
is a Mach-O that otool cannot read (%OTOOL)."
  (let ((out (%otool "-L" file)))
    (when out
      (let ((own (%install-name file)))
        (loop for line in (rest (uiop:split-string out :separator '(#\Newline)))
              for trimmed = (string-trim '(#\Space #\Tab) line)
              for dep = (subseq trimmed 0 (or (position #\Space trimmed) (length trimmed)))
              unless (or (string= dep "") (equal dep own)) collect dep)))))

(defun %relink-carried (plan bundle report)
  "On macOS, point each carried Mach-O's load commands that name ANOTHER carried file at the
copy beside it, as @loader_path/<name>, and re-sign what changed ad hoc (#78, macOS).

Why: a dylib records each library it needs by that library's install name, which for a
Homebrew library is an absolute path under /opt/homebrew. The carried copies are reopened by
absolute path at startup (OPEN-CARRIED-LIBRARIES), but when one needs another, dyld looks for
the recorded path. That path is not there on a Mac without Homebrew, and dyld reuses an
already-open copy only when its install name is the same string, which for OpenSSL it is not:
libssl.3.dylib names .../Cellar/openssl@3/<version>/lib/libcrypto.3.dylib, while
libcrypto.3.dylib's own name is .../opt/openssl@3/lib/libcrypto.3.dylib. Measured on #334:
the app exited 3 on `Library not loaded' for libcrypto, and started once libssl was relinked.

A load command is rewritten only when it names another carried file, as %RELINK-TARGET
decides: by the file it resolves to from the dependent's source and rpaths, or, when it resolves
to no file on this machine, by install name or file name. System libraries are never touched.
Rewriting invalidates the signature, and arm64 will not load an invalidly signed dylib, so each
changed file is re-signed with `codesign --force -s -'."
  (%relink-files (mapcar #'second plan) (mapcar #'first plan) (mapcar #'second plan)
                 bundle report))

(defun %rpaths (file)
  "The paths of FILE's LC_RPATH load commands, as otool -l prints them, in order."
  (let ((lines (mapcar (lambda (l) (string-trim '(#\Space #\Tab) l))
                       (uiop:split-string (or (%otool "-l" file) "") :separator '(#\Newline)))))
    (loop for (line . rest) on lines
          when (string= line "cmd LC_RPATH")
            append (let ((path (find-if (lambda (l) (uiop:string-prefix-p "path " l)) rest)))
                     (and path
                          (list (subseq path 5 (or (search " (offset" path) (length path)))))))))

(defun %resolve-load-command (dep from rpaths)
  "The truename of the file DEP, a load command of a library copied from FROM, names on this
machine, or NIL. FROM is NIL when the copy's source is not known. @loader_path/ is FROM's
directory, and @rpath/ is tried with each of RPATHS, the library's LC_RPATH paths, in order, as
dyld tries them. @executable_path/ names the executable that loads the library, which is not
known here, so it resolves to NIL, as does any @ form that needs FROM when FROM is NIL."
  (labels ((probe (native) (ignore-errors (probe-file (uiop:parse-native-namestring native))))
           (under-loader (rest)
             (and from (probe (concatenate 'string
                                           (uiop:native-namestring
                                            (uiop:pathname-directory-pathname from))
                                           rest))))
           (expand (path)
             (cond ((uiop:string-prefix-p "@loader_path/" path)
                    (and from (concatenate 'string
                                           (uiop:native-namestring
                                            (uiop:pathname-directory-pathname from))
                                           (subseq path (length "@loader_path/")))))
                   ((string= path "@loader_path")
                    (and from (uiop:native-namestring (uiop:pathname-directory-pathname from))))
                   ((char= (char path 0) #\@) nil)
                   (t path))))
    (cond ((uiop:string-prefix-p "@loader_path/" dep)
           (under-loader (subseq dep (length "@loader_path/"))))
          ((uiop:string-prefix-p "@rpath/" dep)
           (let ((rest (subseq dep (length "@rpath/"))))
             (loop for r in rpaths
                   for dir = (expand r)
                   for found = (and dir (probe (concatenate 'string (string-right-trim "/" dir)
                                                            "/" rest)))
                   when found return found)))
          ((char= (char dep 0) #\@) nil)
          (t (probe dep)))))

(defun %relink-target (dep from rpaths truenames names origins)
  "The name in NAMES that the load command DEP, of a library copied from FROM with LC_RPATH
paths RPATHS, should point at, or NIL. When it is NIL, the second value is a carried name that
DEP shares only a file name or an install name with, or NIL.

DEP is first resolved to the file it names on this machine, as dyld would from FROM
(%RESOLVE-LOAD-COMMAND). When it resolves, it matches only the carried file whose source is
that file: by TRUENAMES, the carried files' sources in the same order as NAMES, or by the source
ORIGINS recorded. A carried file with the same file name or the same install name but another
source is a different library, and is not matched: two libraries can both have the install name
@rpath/libb.dylib, and the dependent's rpaths decide which one it loads (#1155's review). When
DEP resolves to no file, it matches the carried file whose install name ORIGINS recorded before
the stamp, and failing that, when DEP does not start with @, a carried file with its file name
(#1143)."
  (let* ((at (char= (char dep 0) #\@))
         (dep-true (%resolve-load-command dep from rpaths))
         (i (and dep-true truenames (position dep-true truenames :test #'equal)))
         (by-source (and dep-true (find dep-true origins :key #'third :test #'equal)))
         (by-id (find dep origins :key #'second :test #'equal))
         (by-name (and (not at) (find (file-namestring dep) names :test #'%same-file-name-p))))
    (flet ((carried (origin) (find (file-namestring (first origin)) names
                                   :test #'%same-file-name-p)))
      (cond (i (nth i names))
            (by-source (carried by-source))
            (dep-true (values nil (or (and by-id (carried by-id)) by-name)))
            (by-id (carried by-id))
            (by-name by-name)
            (t (values nil nil))))))

(defun %relink-files (files truenames names bundle report &optional origins)
  "Rewrite the load commands of each of FILES, file names in BUNDLE, that name one of NAMES,
the carried files' names, to @loader_path/<name>, and re-sign each file that changed, as
%RELINK-CARRIED describes. TRUENAMES, when given, are the files the carried ones were copied
from, in the same order as NAMES. ORIGINS are entries of *CARRIED-ORIGINS* for files in BUNDLE.
%RELINK-TARGET says which load commands match, resolving each one from the file the dependent
was copied from and the dependent's LC_RPATH paths. A load command that names a different file
with the same file name or install name as a carried one is left as it is, and a line saying so
goes to REPORT."
  (loop for name in files
        for dst = (merge-pathnames name bundle)
        for dst-true = (ignore-errors (truename dst))
        for from = (or (and truenames (let ((i (position name names :test #'equal)))
                                        (and i (nth i truenames))))
                       (third (find dst-true origins :key #'first :test #'equal)))
        for rpaths = (%rpaths dst)
        for changed = nil
        do (dolist (dep (%macho-dependencies dst))
             (unless (or (uiop:string-prefix-p "/usr/lib/" dep)
                         (uiop:string-prefix-p "/System/" dep))
               (multiple-value-bind (target same-name)
                   (%relink-target dep from rpaths truenames names origins)
                 (cond
                   ((and target (not (%same-file-name-p target name))
                         (not (equal dep (format nil "@loader_path/~A" target))))
                    (multiple-value-bind (out code)
                        (%run-tool (list "install_name_tool" "-change" dep
                                         (format nil "@loader_path/~A" target)
                                         (uiop:native-namestring dst)))
                      (unless (eql code 0)
                        (error 'carry-refused :path dst
                                              :reason (format nil "install_name_tool could not point it at the carried ~A: ~A" target out))))
                    (format report "~&            ~A now names @loader_path/~A~%" dep target)
                    (setf changed t))
                   (same-name
                    (format report "~&            ~A left as it is: it is a different file from the carried ~A, with the same name~%"
                            dep same-name))))))
           (when changed
             (multiple-value-bind (out code)
                 (%run-tool (list "codesign" "--force" "-s" "-" (uiop:native-namestring dst)))
               (unless (eql code 0)
                 (error 'carry-refused :path dst
                                       :reason (format nil "codesign could not re-sign it after relinking: ~A" out)))))))

(defun relink-bundle (bundle &key (report *standard-output*))
  "On macOS, relink every dylib directly in BUNDLE against every other one there, after all the
carry steps have run, as CARRY-DECLARED-LIBRARIES relinks the libraries of one --carry list.
Returns the list of dylib file names it read. Does nothing when *RELINK* is NIL.

Why: build-desktop-app.lisp carries in three steps, the app's --carry libraries, the tree's own
libraries and the libraries the runtime links against, and each step relinks only its own
files. A carried library from one step can need one from another: a --carry libarchive or
libcurl links Homebrew's libzstd, which the runtime step carries. Before #957 the carried
libzstd kept Homebrew's path as its install name, and dyld reused the copy already open by
that name (#334). STAMP-INSTALL-NAME now gives it @executable_path/libzstd.1.dylib, so the
names no longer match, and on a Mac without Homebrew dyld stops with `Library not loaded'
unless the load command is rewritten to the copy beside it (#958's review).

A load command is matched to a carried file by file name, and also by what *CARRIED-ORIGINS*
recorded when each step copied it: the file's install name before the stamp, and the file it
was copied from. A step can carry a library under another file name than the one a dependent
records: the runtime step names libzstd.1.dylib from its symbolic link, and a dependent can name
the versioned file or a path whose file name differs. Matching by file name alone left that
dependent naming the build machine's path (#1130). A load command that starts with @, such as
@rpath/libzstd.1.dylib, is resolved through the dependent's own source location and rpaths. A
load command that resolves to a file on this machine matches only the carried copy of that file,
never another carried file with the same file name or install name, because that is a different
library. One that resolves to no file is matched by the recorded install name, and failing that
by file name (#1143, #1155's review).

Signals CARRY-REFUSED as %RELINK-CARRIED does."
  (when (and *relink* (uiop:os-macosx-p))
    (let* ((names (loop for f in (uiop:directory-files bundle)
                        for name = (file-namestring f)
                        when (and (string-equal "dylib" (pathname-type f)) (%macho-p f))
                          collect name))
           (dir (ignore-errors (truename bundle)))
           (origins (remove-if-not (lambda (o)
                                     (and dir (equal (namestring
                                                      (uiop:pathname-directory-pathname (first o)))
                                                     (namestring dir))))
                                   *carried-origins*)))
      (%relink-files names nil names bundle report origins)
      names)))

(defun carry-declared-libraries (carries bundle &key vendor tree-carries
                                                     (report *standard-output*))
  "Copy each library in CARRIES into the directory BUNDLE, with its license text under
BUNDLE/LICENSES/, and arrange for the dumped image to open the copy at startup.

Each element of CARRIES is a library's path, or a list (PATH . LICENSES) as DECLARED-CARRIES
returns. LICENSES, when given, are the library's license texts; otherwise they are found by
%LICENSE-FILES. A license text can be a file or a directory of notices.

TREE-CARRIES are carried the same way, after CARRIES, and may be under VENDOR. They are the
tree's own libraries that are carried this way rather than by tree-natives.lisp, because the
image opens them at load time and must reopen them from the bundle: SQLite, from
TREE-SQLITE-CARRY (#899).

Signals CARRY-REFUSED, before copying anything, when a path or a named license does not exist,
when a path in CARRIES is under VENDOR (the tree's own libraries, which build-desktop-app.lisp
already carries), when two paths have the same file name, or when no license text is found
for a library.

Returns the list of carried file names that the image had open, which are the ones
OPEN-CARRIED-LIBRARIES opens at startup."
  (let* ((open (%open-libraries))
         (plan
           (loop for (tree . carry) in (append (mapcar (lambda (c) (cons nil c)) carries)
                                               (mapcar (lambda (c) (cons t c)) tree-carries))
                 for (path . named) = (if (consp carry) carry (list carry))
                 for truename = (probe-file path)
                 for name = (and truename (file-namestring truename))
                 do (cond
                      ((null truename)
                       (error 'carry-refused :path (pathname path) :reason "the file does not exist"))
                      ((and (not tree) vendor (probe-file vendor)
                            (uiop:subpathp truename (truename vendor)))
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
               (stamp-install-name dst :report report :source truename)
               (dolist (license licenses)
                 (%copy-license license (pathname-name name) bundle report))
               (cond
                 (libs
                  (dolist (lib libs) (funcall (%cffi "CLOSE-FOREIGN-LIBRARY") lib))
                  (push name opened)
                  (format report "~&            opened beside the executable when the app starts~%"))
                 (t
                  (format report "~&            not open in this image, so the app must open it itself, from beside sb-ext:*runtime-pathname*~%"))))
      (when (and *relink* (uiop:os-macosx-p))
        (%relink-carried plan bundle report))
      (setf opened (nreverse opened))
      (when opened
        (let ((names opened))
          (push (lambda () (open-carried-libraries names)) sb-ext:*init-hooks*)))
      opened)))

;;; --- SQLite, carried by default (#899) -------------------------------------------------------
;;;
;;; cl-sqlite opens libsqlite3 when it is loaded, by a bare name the OS loader resolves, so a
;;; bundle built without this carried nothing and used whatever SQLite the user's machine had:
;;; Apple's on macOS, none on stock Windows. An app that loads cl-sqlite now gets the tree's
;;; pinned build, from scripts/build-sqlite.lisp, through the same close-before-dump and
;;; reopen-at-startup as a --carry (ADR-0013's amendment of 2026-10-24).

(defun sqlite-file-name (&optional (platform (cond ((uiop:os-windows-p) :windows)
                                                    ((uiop:os-macosx-p) :macos)
                                                    (t :linux))))
  "The file name scripts/build-sqlite.lisp gives the library on PLATFORM."
  (ecase platform
    (:macos "libsqlite3.dylib")
    (:linux "libsqlite3.so.0")
    (:windows "sqlite3.dll")))

(defparameter *sqlite-file-names*
  '("libsqlite3.dylib" "libsqlite3.so.0" "libsqlite3.so" "libsqlite3.dll" "sqlite3.dll")
  "Every file name cl-sqlite's library definition asks for, on any platform. A --carry with
one of these names is the app carrying its own SQLite.")

(defun %sqlite-loaded-p ()
  "Whether cl-sqlite is loaded and has its library open in this image."
  (let* ((p (find-package "SQLITE-FFI"))
         (lib (and p (find-symbol "SQLITE3-LIB" p)))
         (loaded-p (%cffi "FOREIGN-LIBRARY-LOADED-P")))
    (and lib loaded-p (ignore-errors (funcall loaded-p lib)) t)))

;;; build-sqlite.lisp writes vendor/sqlite/BUILT-FROM with the version and sha256 it built
;;; from, in this form. A library whose stamp does not match sqlite.pin was built from another
;;; release, for example before a pin bump, and is not carried.

(defun %sqlite-built-from-pin-p (sqlite-dir root)
  "Whether SQLITE-DIR/BUILT-FROM names the version and sha256 in ROOT/sqlite.pin."
  (let* ((pin (merge-pathnames "sqlite.pin" root))
         (version (ouranos-built-from:pin-field pin "version"))
         (sha (ouranos-built-from:pin-field pin "sha256")))
    (and version sha (ouranos-built-from:stamp-matches-p sqlite-dir version sha))))

(defun tree-sqlite-carry (vendor carries &key (loaded (%sqlite-loaded-p)) platform)
  "What build-desktop-app.lisp carries for SQLite, as (values TREE-CARRIES NOTE).

TREE-CARRIES is NIL, or a list of one (LIBRARY LICENSE) entry for CARRY-DECLARED-LIBRARIES's
:TREE-CARRIES: VENDOR/sqlite/lib/<SQLITE-FILE-NAME> and VENDOR/sqlite/LICENSE. NOTE is a line
for the build's report, or NIL.

PLATFORM (:macos, :linux or :windows) is for tests; it defaults to this machine's.

- LOADED false (the app does not load cl-sqlite): nothing, and no note.
- CARRIES, the app's own --carry list, has a file cl-sqlite asks for: nothing, and a note
  saying the app carries its own SQLite. That was the way to ship SQLite before #899, and an
  app that does it keeps working.
- Otherwise the tree's build, which must exist and must have been built from the release
  sqlite.pin names. When the library or its LICENSE is missing, or vendor/sqlite/BUILT-FROM
  does not match the pin, signals CARRY-REFUSED naming the command that builds them. Not carrying would let the
  image reopen SQLite by bare name on the user's machine, which is what #899's probe exists to
  catch."
  (unless loaded (return-from tree-sqlite-carry (values nil nil)))
  (let ((own (find-if (lambda (c)
                        (member (file-namestring (if (consp c) (car c) c)) *sqlite-file-names*
                                :test #'%same-file-name-p))
                      carries)))
    (when own
      (return-from tree-sqlite-carry
        (values nil (format nil "SQLite: the app carries its own (--carry ~A), so the tree's pinned build is not carried"
                            (if (consp own) (car own) own))))))
  (let* ((dir (merge-pathnames "sqlite/" (uiop:ensure-directory-pathname vendor)))
         (library (merge-pathnames (concatenate 'string "lib/"
                                                (if platform
                                                    (sqlite-file-name platform)
                                                    (sqlite-file-name)))
                                   dir))
         (license (merge-pathnames "LICENSE" dir))
         (root (uiop:pathname-parent-directory-pathname (uiop:ensure-directory-pathname vendor)))
         (command (format nil "sbcl --script \"~A\""
                          (uiop:native-namestring
                           (merge-pathnames "scripts/build-sqlite.lisp" root))))
         (missing (find-if-not #'probe-file (list library license))))
    (when missing
      (error 'carry-refused
             :path missing
             :reason (format nil "the app loads cl-sqlite, and the tree's pinned SQLite has not been built, so the bundle would use whatever SQLite the user's machine has. Build it, then build the bundle again:~%  ~A"
                             command)))
    (unless (%sqlite-built-from-pin-p dir root)
      (error 'carry-refused
             :path library
             :reason (format nil "the app loads cl-sqlite, and the SQLite in vendor/sqlite was not built from the release sqlite.pin names (its BUILT-FROM stamp is missing or names another), so the bundle would carry another version. Rebuild it, then build the bundle again:~%  ~A"
                             command)))
    (values (list (list (uiop:native-namestring library) (uiop:native-namestring license)))
            nil)))

(defun runtime-directory (&optional (runtime sb-ext:*runtime-pathname*))
  "The directory of RUNTIME, the running executable. SBCL makes `sb-ext:*runtime-pathname*' a
pathname with SB-EXT:NATIVE-PATHNAME, so a directory named with [ or * in it is not wild, and
it is used as it is. A string is read the same way, as a native file name, never as a Lisp
namestring, which would make such a directory wild."
  (uiop:pathname-directory-pathname
   (if (stringp runtime) (uiop:parse-native-namestring runtime) runtime)))

(defun open-carried-libraries (names)
  "Open each file in NAMES from the directory of the running executable. Run from
`sb-ext:*init-hooks*' when a dumped app starts. A library that does not open ends the app
with exit code 3 and a message naming the file, because the app cannot run without it."
  (let ((dir (runtime-directory))
        (load-lib (%cffi "LOAD-FOREIGN-LIBRARY")))
    (dolist (name names)
      (let ((path (merge-pathnames name dir)))
        (handler-case (funcall load-lib path)
          (error (e)
            (format *error-output* "~&This app cannot open ~A, which it carries beside its executable:~%  ~A~%~A~%"
                    name (uiop:native-namestring path) e)
            (finish-output *error-output*)
            (sb-ext:exit :code 3 :abort t)))))))
