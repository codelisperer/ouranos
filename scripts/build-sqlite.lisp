;;;; build-sqlite.lisp --- fetch, verify and build the pinned SQLite from source (#899).
;;;;
;;;;     sbcl --script scripts/build-sqlite.lisp            # build if missing
;;;;     sbcl --script scripts/build-sqlite.lisp --force    # rebuild unconditionally
;;;;     sbcl --script scripts/build-sqlite.lisp --clean    # remove vendor/sqlite entirely
;;;;     sbcl --script scripts/build-sqlite.lisp --where    # print the library path, build nothing
;;;;
;;;; Exit 0 on success, 1 on failure. Produces vendor/sqlite/lib/<name>, under the file name
;;;; cl-sqlite's library definition asks for on each platform (libsqlite3.dylib on macOS,
;;;; libsqlite3.so.0 on Linux, sqlite3.dll on Windows), and vendor/sqlite/LICENSE.
;;;;
;;;; WHO USES IT. Desktop bundles only. When an app loads cl-sqlite, build-desktop-app.lisp
;;;; carries this library beside the executable and opens it from there when the app starts,
;;;; and it refuses to build the bundle when this library has not been built
;;;; (carry-natives.lisp, TREE-SQLITE-CARRY; ADR-0013's amendment of 2026-10-24). The tree's
;;;; own suites and REPLs keep loading the system copy, as before.
;;;;
;;;; Same doctrine as build-libuv.lisp: a native dependency we do not build is one we cannot
;;;; bundle (ADR-0011). sqlite.pin names a version and a sha256, and this script compiles
;;;; SQLite's amalgamation, one C file, with the platform's own compiler: cc on Linux and
;;;; macOS, MSVC on Windows. No make, no configure.
;;;;
;;;; THE COMPILE OPTIONS, and why:
;;;;   SQLITE_THREADSAFE=1           serialized, SQLite's default. A connection may be used
;;;;                                 from more than one thread. Apple's copy is THREADSAFE=2.
;;;;   SQLITE_OMIT_LOAD_EXTENSION    no run-time loading of extensions. Apple's copy omits it
;;;;                                 too; #425 recommends against needing an extension, and
;;;;                                 nothing in the tree loads one. Adopting sqlite-vec later
;;;;                                 means removing this define.
;;;;   SQLITE_ENABLE_MATH_FUNCTIONS  the SQL math functions (ln, exp, ...), which Apple's copy
;;;;                                 and sqlite.org's Windows DLL both have, so the carried
;;;;                                 copy is no narrower than either.
;;;;   No FTS5, as #899 asks: praxeon's SQLite retrieval scores BM25 in Lisp.
;;;;
;;;; On Windows the build is /MT, so the DLL needs no VC++ runtime (build-libuv.lisp explains
;;;; why), and SQLITE_API is __declspec(dllexport), because MSVC exports nothing by default.
;;;;
;;;; THE LICENCE. SQLite is in the public domain and its tarball has no LICENSE file. A bundle
;;;; carries every library's licence text (ADR-0013, decision 4), so this script writes
;;;; vendor/sqlite/LICENSE from the dedication at the head of sqlite3.c's own source, with
;;;; the version and a pointer to https://sqlite.org/copyright.html.

(require :asdf)
(require :uiop)
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; how a path is printed (#168)
(load (merge-pathnames "fs.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; aion/fs:delete-tree (#347)
;;; Finding MSVC and running a command inside its environment, shared with the other build
;;; scripts (#410). Loaded before any form below is read, because those forms name
;;; FIND-MSVC and MSVC-COMMAND.
(load (merge-pathnames "msvc.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))
(use-package :ouranos-msvc)

(defparameter *root* (uiop:pathname-parent-directory-pathname
                      (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))
(defparameter *vendor* (merge-pathnames "vendor/sqlite/" *root*))

(defparameter *defines*
  '("SQLITE_THREADSAFE=1" "SQLITE_OMIT_LOAD_EXTENSION" "SQLITE_ENABLE_MATH_FUNCTIONS")
  "The compile options; the header says why each one.")

(defparameter *required-symbols*
  '("sqlite3_open" "sqlite3_close" "sqlite3_errmsg" "sqlite3_busy_timeout"
    "sqlite3_prepare_v2" "sqlite3_finalize" "sqlite3_step" "sqlite3_reset"
    "sqlite3_clear_bindings" "sqlite3_column_count" "sqlite3_column_type"
    "sqlite3_column_text" "sqlite3_column_int64" "sqlite3_column_double"
    "sqlite3_column_bytes" "sqlite3_column_blob" "sqlite3_column_name"
    "sqlite3_bind_parameter_count" "sqlite3_bind_parameter_name"
    "sqlite3_bind_parameter_index" "sqlite3_bind_double" "sqlite3_bind_int64"
    "sqlite3_bind_null" "sqlite3_bind_text" "sqlite3_bind_blob" "sqlite3_last_insert_rowid"
    "sqlite3_libversion" "sqlite3_get_autocommit")
  "Every entry point cl-sqlite (sqlite-ffi.lisp in cl-sqlite-20190813-git) and
mnemosyne/sqlite-library bind. VERIFY-BUILT refuses a library missing any of them.")

(defparameter *refused-symbols*
  '("sqlite3_load_extension" "sqlite3_enable_load_extension")
  "Entry points that SQLITE_OMIT_LOAD_EXTENSION removes. VERIFY-BUILT refuses a library that
exports either, because then the define did not take effect.")

(defun pin-field (name)
  "The value of NAME in sqlite.pin, or NIL. Lines are `name value', # comments."
  (with-open-file (in (merge-pathnames "sqlite.pin" *root*) :if-does-not-exist nil)
    (when in
      (loop for line = (read-line in nil nil)
            while line
            for tr = (string-trim '(#\Space #\Tab #\Return) line)
            unless (or (zerop (length tr)) (char= #\# (char tr 0)))
              do (let ((sp (position-if (lambda (c) (member c '(#\Space #\Tab))) tr)))
                   (when (and sp (string= name (subseq tr 0 sp)))
                     (return (string-trim '(#\Space #\Tab) (subseq tr sp)))))))))

;;; -------------------------------------------------------------------- helpers
;;;
;;; The same as build-libgit2.lisp's; the build scripts are self-contained on purpose, so each
;;; can be run alone on a bare machine.

(defparameter *command-timeout* 600
  "Seconds any external command may run before it is stopped, unless its call gives its own
limit, so a hung command fails naming itself rather than at CI's job limit.")

(defun %describe (command)
  (let ((text (if (stringp command) command (format nil "~{~A~^ ~}" command))))
    (if (> (length text) 160) (concatenate 'string (subseq text 0 160) " ...") text)))

(defun %run-bounded (command &key directory capture (timeout *command-timeout*)
                                  ignore-error-status)
  "Run COMMAND, a list or a string cmd.exe runs, and return (values OUTPUT CODE). Signals on a
non-zero exit unless IGNORE-ERROR-STATUS, and after TIMEOUT seconds, having stopped it."
  (uiop:with-temporary-file (:pathname out :type "txt")
    (let ((process (uiop:launch-program command :directory directory :input nil
                                                :output (if capture out :interactive)
                                                :if-output-exists :supersede
                                                :error-output :interactive))
          (deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
      (loop while (uiop:process-alive-p process)
            do (when (> (get-internal-real-time) deadline)
                 (ignore-errors (uiop:terminate-process process :urgent t))
                 (error "This command did not finish within ~D seconds and was stopped:~%  ~A"
                        timeout (%describe command)))
               (sleep 0.05))
      (let ((code (uiop:wait-process process)))
        (unless (or ignore-error-status (eql code 0))
          (error "This command exited with code ~A:~%  ~A" code (%describe command)))
        (values (when capture
                  (string-right-trim '(#\Space #\Tab #\Return #\Newline)
                                     (uiop:read-file-string out :external-format :latin-1)))
                code)))))

(defun which (&rest candidates)
  "First of CANDIDATES on PATH, or NIL."
  (dolist (c candidates)
    (let ((found (ignore-errors
                  (%run-bounded (if (uiop:os-windows-p)
                                    (list "where" c)
                                    (list "sh" "-c" (format nil "command -v ~A" c)))
                                :capture t :ignore-error-status t :timeout 30))))
      (when (and found (plusp (length found))) (return c)))))

(defun run (program args &key (timeout *command-timeout*))
  (format t "~&  ~A ~{~A~^ ~}~%" program (if (> (length args) 6)
                                             (append (subseq args 0 6) (list "...")) args))
  (finish-output)
  (%run-bounded (cons program args) :timeout timeout))

(defun sha256-of (file)
  (flet ((first-word (s) (subseq s 0 (or (position #\Space s) (length s)))))
    (cond
      ((which "sha256sum")
       (first-word (%run-bounded (list "sha256sum" (namestring file)) :capture t :timeout 120)))
      ((which "shasum")
       (first-word (%run-bounded (list "shasum" "-a" "256" (namestring file))
                                 :capture t :timeout 120)))
      ((and (uiop:os-windows-p) (which "certutil"))
       (let* ((out (%run-bounded (list "certutil" "-hashfile" (namestring file) "SHA256")
                                 :capture t :timeout 120))
              (lines (uiop:split-string out :separator '(#\Newline))))
         (string-downcase (remove #\Space (or (second lines) "")))))
      (t (error "No sha256 tool found (looked for sha256sum, shasum, certutil).")))))

(defun platform ()
  (cond ((uiop:os-windows-p) :windows)
        ((uiop:os-macosx-p) :macos)
        (t :linux)))

(defun toolchain ()
  (if (uiop:os-windows-p) :msvc :cc))

(defun output-name ()
  "The file name cl-sqlite's library definition asks for on this platform. On Windows it asks
for libsqlite3.dll first and sqlite3.dll second; the bundle opens its copy by absolute path,
so either name works, and sqlite3.dll is sqlite.org's own."
  (ecase (platform)
    (:linux "libsqlite3.so.0")
    (:macos "libsqlite3.dylib")
    (:windows "sqlite3.dll")))

(defun library-path ()
  (merge-pathnames (concatenate 'string "lib/" (output-name)) *vendor*))

(defun tar-program ()
  (if (uiop:os-windows-p)
      (let ((system32 (merge-pathnames "System32/tar.exe"
                                       (uiop:ensure-directory-pathname
                                        (or (uiop:getenv "SystemRoot") "C:\\Windows")))))
        (if (probe-file system32) (uiop:native-namestring system32) "tar"))
      "tar"))

;;; ------------------------------------------------------------------ the source

(defun source-directory-name (url)
  "sqlite-autoconf-3540100 for .../sqlite-autoconf-3540100.tar.gz: the directory the tarball
unpacks into."
  (let ((file (subseq url (1+ (position #\/ url :from-end t)))))
    (subseq file 0 (search ".tar.gz" file))))

(defun ensure-source (url expected-sha)
  "The unpacked source directory, fetching and verifying the tarball if needed."
  (let* ((name (source-directory-name url))
         (tarball (merge-pathnames (format nil "src/~A.tar.gz" name) *vendor*))
         (srcdir (merge-pathnames (format nil "src/~A/" name) *vendor*)))
    (ensure-directories-exist tarball)
    (unless (probe-file tarball)
      (format t "~&Fetching ~A~%" url)
      (let ((fetcher (which "curl" "wget")))
        (unless fetcher (error "Need curl or wget to fetch the SQLite source."))
        (if (string= fetcher "curl")
            ;; https only, redirects included; the sha256 below is the real check.
            (run "curl" (list "-sSL" "--fail" "--proto" "=https" "--proto-redir" "=https"
                              "-o" (uiop:native-namestring tarball) url))
            (run "wget" (list "-q" "--https-only" "-O" (uiop:native-namestring tarball) url)))))
    ;; Verified every time, including a tarball already here.
    (let ((actual (sha256-of tarball)))
      (unless (string-equal actual expected-sha)
        (delete-file tarball)
        (error "SQLite tarball checksum mismatch.~%  expected ~A~%  actual   ~A~%The tarball has been deleted. Either upstream was substituted, or sqlite.pin is stale."
               expected-sha actual)))
    (format t "~&  sha256 ok~%")
    (unless (probe-file (merge-pathnames "sqlite3.c" srcdir))
      (run (tar-program) (list "-xzf" (uiop:native-namestring tarball) "-C"
                               (uiop:native-namestring (merge-pathnames "src/" *vendor*)))
           :timeout 300))
    srcdir))

(defun header-version (srcdir)
  "The version sqlite3.h declares: the string in `#define SQLITE_VERSION \"3.54.1\"'."
  (with-open-file (in (merge-pathnames "sqlite3.h" srcdir) :external-format :latin-1)
    (loop for line = (read-line in nil nil)
          while line
          do (let ((at (search "#define SQLITE_VERSION " line)))
               (when (eql at 0)
                 (let* ((open (position #\" line))
                        (close (and open (position #\" line :start (1+ open)))))
                   (when close (return (subseq line (1+ open) close)))))))))

(defun verify-source (srcdir version)
  "The unpacked source is the version sqlite.pin names."
  (let ((declared (header-version srcdir)))
    (unless (equal declared version)
      (error "sqlite3.h declares version ~S, and sqlite.pin names ~S." declared version))
    (format t "~&  sqlite3.h declares ~A~%" declared)))

;;; ------------------------------------------------------------------ the compile

(defun compile-with-cc (srcdir)
  (let* ((cc (or (which "cc" "gcc" "clang")
                 (error "No C compiler found (looked for cc, gcc, clang).")))
         (libdir (merge-pathnames "lib/" *vendor*))
         (out (merge-pathnames (output-name) libdir)))
    (ensure-directories-exist libdir)
    (run cc (append (ecase (platform)
                      ;; The install name is relative, so it never equals the system copy's
                      ;; /usr/lib/libsqlite3.dylib; the bundle opens this file by its path.
                      (:macos (list "-dynamiclib" "-install_name"
                                    (concatenate 'string "@rpath/" (output-name))))
                      (:linux (list "-shared" (format nil "-Wl,-soname,~A" (output-name)))))
                    (list "-O2" "-fPIC" "-w" "-o" (namestring out))
                    (mapcar (lambda (d) (format nil "-D~A" d)) *defines*)
                    (list (namestring (merge-pathnames "sqlite3.c" srcdir)))
                    ;; -lm for SQLITE_ENABLE_MATH_FUNCTIONS; macOS has both in libSystem.
                    (ecase (platform)
                      (:macos '())
                      (:linux (list "-lpthread" "-lm"))))
         :timeout 600)
    out))

(defun no-msvc-error ()
  (error "No MSVC C++ toolchain found.~%Install the Build Tools (about 2 GB, no IDE):~%  winget install --id Microsoft.VisualStudio.2022.BuildTools --override \"--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended\"~%MSYS2/MinGW is deliberately NOT used here (ECOSYSTEM decisions log)."))

(defun %msvc-run (inner &key capture (timeout *command-timeout*))
  (%run-bounded (msvc-command inner) :directory *vendor* :capture capture
                                     :ignore-error-status t :timeout timeout))

(defun compile-with-msvc (srcdir)
  "One cl.exe invocation, its arguments in a response file. Paths relative to *VENDOR*,
where the compile runs, so none needs quoting."
  (unless (find-msvc) (no-msvc-error))
  (let ((libdir (merge-pathnames "lib/" *vendor*))
        (objdir (merge-pathnames "obj/" *vendor*))
        (rsp (merge-pathnames "msvc-args.rsp" *vendor*)))
    (ensure-directories-exist libdir)
    (ensure-directories-exist objdir)
    (with-open-file (out rsp :direction :output :if-exists :supersede
                             :external-format :latin-1)
      (dolist (line (append (list "/nologo" "/O2" "/MT" "/LD" "/w"
                                  (format nil "/Fe:lib\\~A" (output-name))
                                  "/Foobj\\"
                                  "/DSQLITE_API=__declspec(dllexport)")
                            (mapcar (lambda (d) (format nil "/D~A" d)) *defines*)
                            (list (format nil "\"~A\""
                                          (uiop:native-namestring
                                           (merge-pathnames "sqlite3.c" srcdir))))))
        (write-line line out)))
    (format t "~&  compiling sqlite3.c with MSVC cl.exe (~A)~%" (vcvarsall-arch))
    (finish-output)
    (let ((code (nth-value 1 (%msvc-run "cl @msvc-args.rsp" :timeout 1200))))
      (unless (zerop code)
        (error "cl.exe failed with exit code ~D (arguments in vendor/sqlite/msvc-args.rsp)."
               code)))
    (merge-pathnames (output-name) libdir)))

(defun require-toolchain ()
  "Refuse NOW if this machine cannot compile, before anything is downloaded."
  (ecase (toolchain)
    (:cc (unless (which "cc" "gcc" "clang")
           (error "No C compiler found (looked for cc, gcc, clang).")))
    (:msvc (unless (find-msvc) (no-msvc-error)))))

(defun compile-library (srcdir)
  (ecase (toolchain)
    (:cc (compile-with-cc srcdir))
    (:msvc (compile-with-msvc srcdir))))

;;; ------------------------------------------------------------------ verification

(defun %exported-symbols (library)
  "The names LIBRARY exports, undecorated, or NIL if the platform's tool is unavailable."
  (flet ((lines (argv)
           ;; An argument list, not a shell command, so a path with spaces or a ";" in it is
           ;; one argument.
           (let ((out (ignore-errors
                       (%run-bounded argv :capture t :ignore-error-status t :timeout 120))))
             (when out (uiop:split-string out :separator '(#\Newline))))))
    (ecase (platform)
      (:linux
       (loop for l in (lines (list "nm" "-D" "--defined-only" (uiop:native-namestring library)))
             for name = (car (last (uiop:split-string (string-trim '(#\Space #\Tab #\Return) l))))
             when (and name (plusp (length name))) collect name))
      (:macos
       (loop for l in (lines (list "nm" "-gU" (uiop:native-namestring library)))
             for name = (car (last (uiop:split-string (string-trim '(#\Space #\Tab #\Return) l))))
             when (and name (plusp (length name)))
               collect (if (char= #\_ (char name 0)) (subseq name 1) name)))
      (:windows
       (let ((out (%msvc-run (format nil "dumpbin /nologo /exports \"~A\""
                                     (uiop:native-namestring library))
                             :capture t :timeout 300)))
         (when out
           (loop for l in (uiop:split-string out :separator '(#\Newline))
                 for fields = (remove "" (uiop:split-string (string-trim '(#\Space #\Tab #\Return) l))
                                      :test #'string=)
                 for name = (car (last fields))
                 when (and name (= 4 (length fields)) (uiop:string-prefix-p "sqlite3_" name))
                   collect name)))))))

(defun verify-built (library)
  "The library is usable, not merely present: plausible size, the soname the loader will ask
for on Linux, every entry point cl-sqlite binds, no extension loading, and on Windows no
dependency on the VC++ runtime."
  (format t "~&~%Verifying ~A~%" (human-path:human-path library))
  (let ((size (with-open-file (s library :element-type '(unsigned-byte 8)) (file-length s))))
    (format t "  size ~:D bytes~%" size)
    (when (< size 500000)
      (error "The built library is implausibly small (~:D bytes)." size)))
  (when (eq (platform) :linux)
    (let* ((dynamic (ignore-errors
                     (%run-bounded (list "readelf" "-d" (uiop:native-namestring library))
                                   :capture t :ignore-error-status t :timeout 60)))
           (soname (and dynamic
                        (find-if (lambda (l) (search "SONAME" (string-upcase l)))
                                 (uiop:split-string dynamic :separator '(#\Newline))))))
      (unless soname
        (error "readelf found no SONAME in ~A." (file-namestring library)))
      (format t "  ~A~%" (string-trim '(#\Space #\Tab) soname))
      (unless (search (output-name) soname)
        (error "SONAME does not name ~A." (output-name)))))
  (let ((exports (%exported-symbols library)))
    (when (null exports)
      (error "Could not read any exported symbol from ~A." (file-namestring library)))
    (format t "  exports ~:D symbols~%" (length exports))
    (dolist (sym *required-symbols*)
      (unless (member sym exports :test #'string=)
        (error "The built library does not export ~A." sym)))
    (format t "  exports all ~D entry points cl-sqlite binds~%" (length *required-symbols*))
    (dolist (sym *refused-symbols*)
      (when (member sym exports :test #'string=)
        (error "The built library exports ~A: SQLITE_OMIT_LOAD_EXTENSION did not take effect."
               sym)))
    (format t "  no extension loading (~{~A~^, ~} absent)~%" *refused-symbols*))
  (when (eq (toolchain) :msvc)
    (let ((deps (%msvc-run (format nil "dumpbin /nologo /dependents \"~A\""
                                   (uiop:native-namestring library))
                           :capture t :timeout 300)))
      (when deps
        (if (search "VCRUNTIME" (string-upcase deps))
            (error "The DLL depends on the VC++ runtime: /MT did not take effect. It would fail on a clean machine.")
            (format t "  self-contained: no VC++ redistributable needed~%")))))
  library)

;;; ------------------------------------------------------------------ the licence

(defun dedication (srcdir)
  "The public-domain dedication from the first file header in sqlite3.c, from `The author
disclaims copyright' to the end of the blessing, without the comment markers."
  (with-open-file (in (merge-pathnames "sqlite3.c" srcdir) :external-format :latin-1)
    (let ((lines '()) (in-it nil))
      (loop for line = (read-line in nil nil)
            for count from 0
            while (and line (< count 200))
            do (let ((text (string-right-trim '(#\Return #\Space)
                                              (string-left-trim "*" (string-left-trim " " line)))))
                 (when (search "The author disclaims copyright" text) (setf in-it t))
                 (when in-it
                   (push (string-left-trim " " text) lines)
                   (when (search "never taking more than you give" text)
                     (return)))))
      (unless (and lines (search "never taking more than you give" (first lines)))
        (error "Could not find SQLite's public-domain dedication at the head of sqlite3.c."))
      (nreverse lines))))

(defun install-licence (srcdir version)
  "Write vendor/sqlite/LICENSE, where build-desktop-app.lisp takes it from (TREE-SQLITE-CARRY in
carry-natives.lisp) and where tree-natives.lisp's LICENSE-FILES would find it."
  (let ((dst (merge-pathnames "LICENSE" *vendor*)))
    (with-open-file (out dst :direction :output :if-exists :supersede
                             :external-format :utf-8)
      (format out "SQLite ~A~%~%" version)
      (format out "SQLite is in the public domain. It ships no licence file; this file was~%")
      (format out "written by scripts/build-sqlite.lisp from the dedication at the head of~%")
      (format out "SQLite's own source, sqlite3.c, which reads:~%~%")
      (dolist (line (dedication srcdir))
        (format out "~:[  ~A~;~*~]~%" (zerop (length line)) line))
      (format out "~%See https://sqlite.org/copyright.html.~%"))
    (format t "  licence: ~A~%" (human-path:human-path dst))))

;;; ------------------------------------------------------------------- the stamp
;;;
;;; vendor/sqlite/BUILT-FROM records the version and tarball sha256 a build used. A library
;;; already in vendor/ is reused only when its stamp names the pin's current version and sha256,
;;; so after a pin bump a checkout that still holds the old build rebuilds it instead of
;;; carrying the old version into bundles.

(defun stamp-path () (merge-pathnames "BUILT-FROM" *vendor*))

(defun stamp-text (version sha)
  (format nil "version ~A~%sha256 ~A~%" version (string-downcase sha)))

(defun write-stamp (version sha)
  (with-open-file (out (stamp-path) :direction :output :if-exists :supersede)
    (write-string (stamp-text version sha) out)))

(defun stamp-matches-p (version sha)
  (let ((path (probe-file (stamp-path))))
    (and path (string= (uiop:read-file-string path) (stamp-text version sha)))))

;;; ------------------------------------------------------------------------- main

(defun main ()
  (let ((args (uiop:command-line-arguments)))
    (when (member "--where" args :test #'string=)
      (format t "~A~%" (human-path:human-path (library-path)))
      (uiop:quit 0))
    (when (member "--clean" args :test #'string=)
      (format t "~&removing ~A~%" (human-path:human-path *vendor*))
      (aion/fs:delete-tree *vendor* :if-does-not-exist :ignore)
      (uiop:quit 0))
    (let ((version (pin-field "version"))
          (url (pin-field "url"))
          (sha (pin-field "sha256"))
          (force (member "--force" args :test #'string=)))
      (unless (and version url sha)
        (format *error-output* "build-sqlite: sqlite.pin is missing version, url or sha256.~%")
        (uiop:quit 1))
      (format t "~&SQLite ~A (~A) -> ~A~%" version (platform) (human-path:human-path *vendor*))
      ;; An existing library is verified, not trusted: its stamp names this pin, it passes
      ;; VERIFY-BUILT, and its licence is there, or it is rebuilt.
      (when (and (probe-file (library-path)) (not force))
        (handler-case
            (progn (unless (stamp-matches-p version sha)
                     (error "vendor/sqlite/BUILT-FROM does not name SQLite ~A with sqlite.pin's sha256, so the library there was built from another release."
                            version))
                   (verify-built (library-path))
                   (unless (probe-file (merge-pathnames "LICENSE" *vendor*))
                     (error "vendor/sqlite/LICENSE is missing."))
                   (format t "~&  already built: ~A~%  (--force to rebuild)~%"
                           (human-path:human-path (library-path)))
                   (uiop:quit 0))
          (error (e)
            (format t "~&  the library already there fails verification, so it is rebuilt:~%  ~A~%" e))))
      (handler-case
          (progn
            (require-toolchain)
            (let ((srcdir (ensure-source url sha)))
              (verify-source srcdir version)
              (verify-built (compile-library srcdir))
              (install-licence srcdir version)
              (write-stamp version sha)
              (format t "~&~%Built vendor/sqlite/lib/~A~%" (output-name))
              (uiop:quit 0)))
        (error (e)
          (format *error-output* "~&build-sqlite: ~A~%" e)
          (uiop:quit 1))))))

(main)
