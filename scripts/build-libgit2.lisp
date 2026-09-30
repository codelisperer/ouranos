;;;; build-libgit2.lisp --- fetch, verify and build the pinned libgit2 from source (#429).
;;;;
;;;;     sbcl --script scripts/build-libgit2.lisp            # build if missing
;;;;     sbcl --script scripts/build-libgit2.lisp --force    # rebuild unconditionally
;;;;     sbcl --script scripts/build-libgit2.lisp --clean    # remove vendor/libgit2 entirely
;;;;     sbcl --script scripts/build-libgit2.lisp --where    # print the library path, build nothing
;;;;
;;;; Exit 0 on success, 1 on failure. Produces vendor/libgit2/lib/<the platform soname>, which
;;;; aion/libgit loads and the desktop bundler carries, with COPYING beside it.
;;;;
;;;; Same doctrine as build-libuv.lisp and build-mbedtls.lisp: a native dependency we do not
;;;; build is one we cannot bundle (ADR-0011), so libgit2.pin names a version and a sha256 and
;;;; this script builds it with a C compiler alone. NO CMAKE, NO MAKE, NO PYTHON: `sbcl
;;;; --script' is the only build driver.
;;;;
;;;; WHAT CMAKE WOULD HAVE DONE, done here instead:
;;;;
;;;;   - It GENERATES three headers, from templates in the tarball: src/util/git2_features.h
;;;;     (which features are on), src/libgit2/experimental.h (SHA-256 repositories, off) and
;;;;     deps/pcre2's config.h. This script writes all three, per platform (FEATURES-HEADER,
;;;;     PCRE2-CONFIG). The feature names are 1.9.7's; they differ from libgit2's main branch,
;;;;     so a version bump must compare them with the new git2_features.h.in (libgit2.pin).
;;;;   - It GLOBS the sources per directory and gives some directories their own definitions:
;;;;     zlib, pcre2 and the SHA-1 collision detector each need defines the rest must not see.
;;;;     So the sources are compiled in GROUPS (SOURCE-GROUPS), one per directory with its own
;;;;     flags, each into its own object directory, and linked once. Separate object
;;;;     directories because two directories hold files of the same name (errors.c is in both
;;;;     src/util and src/libgit2).
;;;;
;;;; THE FEATURES, and why:
;;;;   - HTTPS through the platform: SecureTransport on macOS, WinHTTP on Windows, and on Linux
;;;;     OpenSSL LOADED AT RUN TIME (GIT_OPENSSL_DYNAMIC), so the build needs no OpenSSL headers
;;;;     and a machine without OpenSSL still does every local operation. Approved on #429.
;;;;   - No SSH, no NTLM, no Negotiate: not in #429's scope.
;;;;   - zlib, pcre2 and llhttp from libgit2's own deps/, compiled into the one library, so the
;;;;     library depends on nothing a clean machine lacks.
;;;;   - SHA-1 with collision detection and SHA-256, libgit2's own implementations.
;;;;
;;;; EXPORTS. libgit2 marks its API itself (GIT_EXTERN in include/git2/common.h): visibility
;;;; default under gcc and clang, __declspec(dllexport) under MSVC. So the Unix compile uses
;;;; -fvisibility=hidden, as upstream does, and exports the API and nothing else, and Windows
;;;; needs no .def file, unlike build-mbedtls.lisp. PCRE2_EXPORT is defined empty (and
;;;; PCRE2_STATIC on Windows), so the bundled pcre2 exports nothing.
;;;;
;;;; PLATFORM STATUS. Three platforms are not claimed from one.
;;;;   MACOS    PROVEN: 217 sources, a 1.55 MB dylib exporting 954 symbols, linked
;;;;            against Security, CoreFoundation, libiconv and libSystem only; loaded through
;;;;            CFFI, git_libgit2_version reported 1.9.7 (#429).
;;;;   LINUX    BUILT IN CI: libgit2.so.1.9, 1,996,880 bytes, exporting 954 symbols, on
;;;;            the ubuntu runner of #469's run 36772461452. Features and flags follow libgit2's
;;;;            cmake for glibc. aion/libgit's suite (#429, step 2) is what loads and tests it.
;;;;   WINDOWS  BUILT IN CI: git2.dll, 1,598,464 bytes, exporting 954 symbols, with MSVC on
;;;;            the windows runner of #469's run 36780302839. Features and flags follow
;;;;            libgit2's cmake for MSVC. aion/libgit's suite (#429, step 2) is what loads and
;;;;            tests it.

(require :asdf)
(require :uiop)
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; how a path is printed (#168)
(load (merge-pathnames "fs.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; aion/fs:delete-tree (#347)
;;; Finding MSVC and running a command inside its environment, shared with the other build
;;; scripts (#410). Loaded before any form below is read, because those forms name
;;; NO-TRAILING-SEPARATOR and FIND-MSVC.
(load (merge-pathnames "msvc.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))
(use-package :ouranos-msvc)

(defparameter *root* (uiop:pathname-parent-directory-pathname
                      (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))
(defparameter *vendor* (merge-pathnames "vendor/libgit2/" *root*))

(defparameter *required-symbols*
  '("git_libgit2_init" "git_libgit2_shutdown" "git_libgit2_version" "git_libgit2_features"
    "git_error_last"
    "git_repository_init" "git_repository_open" "git_repository_free" "git_repository_index"
    "git_index_add_bypath" "git_index_write" "git_index_write_tree" "git_index_free"
    "git_signature_new" "git_signature_free"
    "git_commit_create" "git_commit_lookup" "git_commit_free" "git_commit_tree"
    "git_revwalk_new" "git_revwalk_push_head" "git_revwalk_next" "git_revwalk_free"
    "git_diff_tree_to_tree" "git_diff_print" "git_diff_free"
    "git_tree_entry_bypath" "git_blob_lookup" "git_blob_rawcontent" "git_blob_rawsize")
  "Entry points aion/libgit binds. VERIFY-BUILT refuses a library missing any of them.")

(defun pin-field (name)
  "The value of NAME in libgit2.pin, or NIL. Lines are `name value', # comments."
  (with-open-file (in (merge-pathnames "libgit2.pin" *root*) :if-does-not-exist nil)
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
;;; The same as build-mbedtls.lisp's, which explains each; the build scripts are
;;; self-contained on purpose, so each can be run alone on a bare machine.

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

(defun sha256-of-string (text)
  "The sha256 of TEXT's UTF-8 octets, through a temporary file and SHA256-OF."
  (uiop:with-temporary-file (:pathname tmp :type "txt")
    (with-open-file (out tmp :direction :output :if-exists :supersede
                             :external-format :utf-8)
      (write-string text out))
    (sha256-of tmp)))

(defun platform ()
  (cond ((uiop:os-windows-p) :windows)
        ((uiop:os-macosx-p) :macos)
        (t :linux)))

(defun toolchain ()
  (if (uiop:os-windows-p) :msvc :cc))

(defun output-name ()
  (ecase (platform)
    (:linux "libgit2.so.1.9")
    (:macos "libgit2.1.9.dylib")
    (:windows "git2.dll")))

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

(defun ensure-source (version url expected-sha)
  "The unpacked tree for VERSION, fetching and verifying the tarball if needed. The tarball is
kept in vendor/libgit2/src/: it is the source a bundle that carries the library must ship."
  (let* ((srcdir (merge-pathnames (format nil "src/libgit2-~A/" version) *vendor*))
         (tarball (tarball-path version)))
    (ensure-directories-exist tarball)
    (unless (probe-file tarball)
      (format t "~&Fetching ~A~%" url)
      (let ((fetcher (which "curl" "wget")))
        (unless fetcher (error "Need curl or wget to fetch the libgit2 source."))
        (if (string= fetcher "curl")
            (run "curl" (list "-sSL" "--fail" "-o" (namestring tarball) url))
            (run "wget" (list "-q" "-O" (namestring tarball) url)))))
    ;; TRUST-ON-FIRST-USE, VERIFIED EVERY TIME AFTER, including a tarball already here.
    (let ((actual (sha256-of tarball)))
      (unless (string-equal actual expected-sha)
        (delete-file tarball)
        (error "libgit2 tarball checksum mismatch.~%  expected ~A~%  actual   ~A~%The tarball has been deleted. Either upstream was substituted, or libgit2.pin is stale."
               expected-sha actual)))
    (format t "~&  sha256 ok~%")
    (unless (probe-file (merge-pathnames "src/libgit2/repository.c" srcdir))
      ;; A .tar.gz: every tar this script meets (GNU tar, bsdtar on macOS and on Windows'
      ;; System32) decompresses gzip itself.
      ;;
      ;; WITHOUT tests/ AND fuzzers/: 11,158 of the tarball's 11,907 files, none of them
      ;; compiled or in the candidate set. The tree lives under vendor/, inside the checkout,
      ;; and verify-tree gives every image it starts CL_SOURCE_REGISTRY=<tree>//, so every
      ;; image walks every file here looking for .asd files. With them, one scan of this tree
      ;; took 0.7-0.9 s on macOS against 0.15 s without, and the Windows leg of #469's first
      ;; run ran past its 40-minute limit, where other runs that hour took 24-26 minutes.
      ;; Leaving them out changes nothing that is built: VERIFY-SOURCES still checks the
      ;; candidate set against libgit2.pin.
      (run (tar-program) (list (format nil "--exclude=libgit2-~A/tests" version)
                               (format nil "--exclude=libgit2-~A/fuzzers" version)
                               "-xzf" (uiop:native-namestring tarball) "-C"
                               (uiop:native-namestring (merge-pathnames "src/" *vendor*)))
           :timeout 600))
    srcdir))

(defun tarball-path (version)
  (merge-pathnames (format nil "src/libgit2-~A.tar.gz" version) *vendor*))

(defun %relative (file srcdir)
  (substitute #\/ #\\ (enough-namestring file srcdir)))

(defun %c-files (dir &key recursive)
  "The .c files in DIR, or under it when RECURSIVE."
  (sort (mapcar #'namestring
                (directory (merge-pathnames (if recursive "**/*.c" "*.c") dir)))
        #'string<))

(defun candidate-sources (srcdir)
  "Every .c file the build could compile on any platform: libgit2.pin's candidate set."
  (flet ((d (rel) (merge-pathnames rel srcdir)))
    (sort (remove-duplicates
           (append (%c-files (d "src/util/") :recursive t)
                   (%c-files (d "src/libgit2/"))
                   (%c-files (d "src/libgit2/streams/"))
                   (%c-files (d "src/libgit2/transports/"))
                   (%c-files (d "deps/zlib/"))
                   (%c-files (d "deps/llhttp/"))
                   (%c-files (d "deps/pcre2/"))
                   (%c-files (d "deps/xdiff/")))
           :test #'string=)
          #'string<)))

(defun verify-sources (srcdir)
  "Refuse a tree whose candidate source set is not the one libgit2.pin records: a new version
that adds, moves or drops a file must fail here, not build something nobody reviewed."
  (let* ((files (mapcar (lambda (f) (%relative f srcdir)) (candidate-sources srcdir)))
         (count (length files))
         (digest (sha256-of-string (format nil "~{~A~%~}" files)))
         (want-count (ignore-errors (parse-integer (pin-field "sources-count"))))
         (want-digest (pin-field "sources-digest")))
    (format t "~&  candidate sources: ~D, digest ~A~%" count digest)
    (unless (and (eql count want-count) (string-equal digest want-digest))
      (error "The libgit2 source set is not the one libgit2.pin records.~%  pin:   ~A files, ~A~%  here:  ~D files, ~A~%Read what changed before updating the pin."
             want-count want-digest count digest))))

;;; ---------------------------------------------------------- the generated headers

(defun features-header ()
  "src/util/git2_features.h for this platform. The names are libgit2 1.9.7's."
  (let ((on (append
             '("GIT_THREADS" "GIT_ARCH_64" "GIT_USE_NSEC" "GIT_REGEX_BUILTIN" "GIT_HTTPS"
               "GIT_HTTPPARSER_BUILTIN" "GIT_SHA1_COLLISIONDETECT" "GIT_SHA256_BUILTIN"
               "GIT_COMPRESSION_BUILTIN")
             (ecase (platform)
               ;; macOS declares getentropy in <sys/random.h>, not <unistd.h> where
               ;; libgit2's cmake looks, so upstream's own macOS build leaves it off too.
               (:macos '("GIT_USE_ICONV" "GIT_USE_STAT_MTIMESPEC" "GIT_USE_FUTIMENS"
                         "GIT_QSORT_BSD" "GIT_SECURE_TRANSPORT" "GIT_RAND_GETLOADAVG"
                         "GIT_IO_POLL"))
               (:linux '("GIT_USE_STAT_MTIM" "GIT_USE_FUTIMENS" "GIT_QSORT_GNU"
                         "GIT_OPENSSL" "GIT_OPENSSL_DYNAMIC" "GIT_RAND_GETENTROPY"
                         "GIT_RAND_GETLOADAVG" "GIT_IO_POLL"))
               (:windows '("GIT_QSORT_MSC" "GIT_WINHTTP" "GIT_IO_WSAPOLL"))))))
    (format nil "/* Written by scripts/build-libgit2.lisp in place of cmake's configure_file. */~%#ifndef INCLUDE_features_h__~%#define INCLUDE_features_h__~%~{#define ~A 1~%~}#endif~%"
            on)))

(defun experimental-header ()
  "src/libgit2/experimental.h: SHA-256 repositories stay off."
  (format nil "#ifndef INCLUDE_experimental_h__~%#define INCLUDE_experimental_h__~%#endif~%"))

(defun pcre2-config ()
  "deps/pcre2's config.h: the values libgit2's deps/pcre2/CMakeLists.txt sets, and the header
checks it would find on this platform."
  (format nil "~{#define ~A~%~}"
          (append
           (if (eq (platform) :windows)
               '("HAVE_ASSERT_H 1" "HAVE_SYS_STAT_H 1" "HAVE_SYS_TYPES_H 1" "HAVE_WINDOWS_H 1")
               '("HAVE_ASSERT_H 1" "HAVE_DIRENT_H 1" "HAVE_SYS_STAT_H 1" "HAVE_SYS_TYPES_H 1"
                 "HAVE_UNISTD_H 1" "HAVE_BUILTIN_MUL_OVERFLOW 1" "HAVE_BUILTIN_UNREACHABLE 1"))
           '("SUPPORT_PCRE2_8 1" "SUPPORT_UNICODE 1" "LINK_SIZE 2" "HEAP_LIMIT 20000000"
             "MATCH_LIMIT 10000000" "MATCH_LIMIT_DEPTH MATCH_LIMIT" "MAX_VARLOOKBEHIND 255"
             "NEWLINE_DEFAULT 2" "PARENS_NEST_LIMIT 250" "PCRE2GREP_BUFSIZE 20480"
             "PCRE2GREP_MAX_BUFSIZE 1048576" "MAX_NAME_SIZE 128" "MAX_NAME_COUNT 10000"))))

(defun gen-dir () (merge-pathnames "gen/" *vendor*))

(defun write-generated-headers ()
  (let ((gen (gen-dir)))
    (ensure-directories-exist (merge-pathnames "pcre2/" gen))
    (flet ((put (name text)
             (with-open-file (out (merge-pathnames name gen) :direction :output
                                                            :if-exists :supersede)
               (write-string text out))))
      (put "git2_features.h" (features-header))
      (put "experimental.h" (experimental-header))
      (put "pcre2/config.h" (pcre2-config)))))

;;; ------------------------------------------------------------------ the groups

(defparameter *pcre2-sources*
  '("auto_possess" "chartables" "chkdint" "compile" "compile_cgroup" "compile_class" "config"
    "context" "convert" "dfa_match" "error" "extuni" "find_bracket" "maketables" "match"
    "match_data" "match_next" "newline" "ord2utf" "pattern_info" "script_run" "serialize"
    "string_utils" "study" "substitute" "substring" "tables" "ucd" "valid_utf" "xclass")
  "The pcre2 sources deps/pcre2/CMakeLists.txt compiles: every .c file there but
pcre2_fuzzsupport.c, a fuzzing harness.")

(defun source-groups (srcdir)
  "(NAME DEFINES FILES) for each group, this platform's. DEFINES are NAME or NAME=VALUE."
  (flet ((d (rel) (merge-pathnames rel srcdir))
         (f (rel) (namestring (merge-pathnames rel srcdir))))
    (let ((sha1dc '("SHA1DC_NO_STANDARD_INCLUDES=1"
                    "SHA1DC_CUSTOM_INCLUDE_SHA1_C=\"git2_util.h\""
                    "SHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C=\"git2_util.h\""))
          ;; What deps/zlib/CMakeLists.txt defines everywhere. Its large-file defines are for
          ;; MinGW and MSYS only; on macOS they name an off64_t that does not exist.
          (zlib '("NO_VIZ" "STDC" "NO_GZIP" "HAVE_SYS_TYPES_H" "HAVE_STDINT_H" "HAVE_STDDEF_H")))
      (list
       (list "util" sha1dc (%c-files (d "src/util/")))
       (list "util-allocators" '() (%c-files (d "src/util/allocators/")))
       (list "util-os" '() (%c-files (d (if (eq (platform) :windows)
                                            "src/util/win32/"
                                            "src/util/unix/"))))
       (list "util-sha1" sha1dc (cons (f "src/util/hash/collisiondetect.c")
                                      (%c-files (d "src/util/hash/sha1dc/"))))
       (list "util-sha256" '() (cons (f "src/util/hash/builtin.c")
                                     (%c-files (d "src/util/hash/rfc6234/"))))
       (list "git2" '() (%c-files (d "src/libgit2/")))
       (list "git2-streams" '() (%c-files (d "src/libgit2/streams/")))
       (list "git2-transports" '() (%c-files (d "src/libgit2/transports/")))
       (list "xdiff" '() (%c-files (d "deps/xdiff/")))
       (list "llhttp" '() (%c-files (d "deps/llhttp/")))
       (list "zlib" zlib (%c-files (d "deps/zlib/")))
       (list "pcre2" '("HAVE_CONFIG_H" "PCRE2_CODE_UNIT_WIDTH=8")
             (mapcar (lambda (n) (f (format nil "deps/pcre2/pcre2_~A.c" n))) *pcre2-sources*))))))

(defun common-defines ()
  (append (list "PCRE2_EXPORT=")
          (if (eq (platform) :windows)
              '("WIN32" "_WIN32_WINNT=0x0600" "_CRT_SECURE_NO_DEPRECATE"
                "_CRT_NONSTDC_NO_DEPRECATE" "_SCL_SECURE_NO_WARNINGS" "PCRE2_STATIC")
              '("_GNU_SOURCE"))))

(defun include-dirs (srcdir)
  "In this order: the generated headers first, so gen/git2_features.h is the one found."
  (list* (no-trailing-separator (uiop:native-namestring (gen-dir)))
         (mapcar (lambda (rel)
                   (no-trailing-separator
                    (uiop:native-namestring (merge-pathnames rel srcdir))))
                 '("include/" "src/util/" "src/libgit2/" "deps/llhttp/" "deps/pcre2/"
                   "deps/xdiff/" "deps/zlib/"))))

;;; -------------------------------------------------------------- the Unix compile

(defun compile-with-cc (srcdir)
  (let* ((cc (or (which "cc" "gcc" "clang")
                 (error "No C compiler found (looked for cc, gcc, clang).")))
         (libdir (merge-pathnames "lib/" *vendor*))
         (out (merge-pathnames (output-name) libdir))
         (includes (mapcar (lambda (d) (format nil "-I~A" d)) (include-dirs srcdir)))
         (pcre2-include (format nil "-I~A" (no-trailing-separator
                                            (uiop:native-namestring
                                             (merge-pathnames "pcre2/" (gen-dir))))))
         (objects '())
         (total 0))
    (ensure-directories-exist libdir)
    (dolist (group (source-groups srcdir))
      (destructuring-bind (name defines files) group
        (let ((objdir (merge-pathnames (format nil "obj/~A/" name) *vendor*)))
          (ensure-directories-exist objdir)
          (dolist (file files)
            (let ((obj (namestring (merge-pathnames (concatenate 'string (pathname-name file) ".o")
                                                    objdir))))
              ;; -w: this is someone else's code at their chosen warning level; a warning here
              ;; is theirs to fix, and the build's product is checked by VERIFY-BUILT.
              (%run-bounded (append (list cc "-O2" "-fPIC" "-fvisibility=hidden" "-w" "-c"
                                          file "-o" obj)
                                    (when (string= name "pcre2") (list pcre2-include))
                                    (mapcar (lambda (d) (format nil "-D~A" d))
                                            (append (common-defines) defines))
                                    includes)
                            :timeout 300)
              (push obj objects)
              (incf total)))
          (format t "~&  ~A: ~D files~%" name (length files))
          (finish-output))))
    (format t "~&  linking ~D objects with ~A~%" total cc)
    (run cc (append (ecase (platform)
                      (:macos (list "-dynamiclib" "-o" (namestring out)
                                    ;; The built file IS the install name the loader asks for.
                                    "-install_name" (concatenate 'string "@rpath/" (output-name))))
                      (:linux (list "-shared" "-o" (namestring out)
                                    (format nil "-Wl,-soname,~A" (output-name)))))
                    (reverse objects)
                    (ecase (platform)
                      (:macos (list "-framework" "Security" "-framework" "CoreFoundation"
                                    "-liconv"))
                      ;; -ldl for the run-time load of OpenSSL (GIT_OPENSSL_DYNAMIC).
                      (:linux (list "-lpthread" "-ldl")))))
    out))

;;; ------------------------------------------------------------- the MSVC compile

(defparameter *windows-libs*
  '("winhttp.lib" "rpcrt4.lib" "crypt32.lib" "ole32.lib" "ws2_32.lib" "secur32.lib"
    "advapi32.lib")
  "What libgit2's cmake links on Windows for WinHTTP with the built-in hashes.")

(defun no-msvc-error ()
  (error "No MSVC C++ toolchain found.~%Install the Build Tools (about 2 GB, no IDE):~%  winget install --id Microsoft.VisualStudio.2022.BuildTools --override \"--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended\"~%MSYS2/MinGW is deliberately NOT used here (ECOSYSTEM decisions log)."))

(defun %msvc-run (inner &key capture (timeout *command-timeout*))
  (%run-bounded (msvc-command inner) :directory *vendor* :capture capture
                                     :ignore-error-status t :timeout timeout))

(defun %write-response-file (path lines)
  "A response file: a group's paths and flags run to kilobytes, and cmd.exe truncates at
8191 characters."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :external-format :latin-1)
    (dolist (l lines) (write-line l out)))
  path)

(defun compile-with-msvc (srcdir)
  (unless (find-msvc) (no-msvc-error))
  (let ((libdir (merge-pathnames "lib/" *vendor*))
        (includes (mapcar (lambda (d) (format nil "/I\"~A\"" d)) (include-dirs srcdir))))
    (ensure-directories-exist libdir)
    (dolist (group (source-groups srcdir))
      (destructuring-bind (name defines files) group
        (let ((objdir (merge-pathnames (format nil "obj/~A/" name) *vendor*))
              (rsp (merge-pathnames (format nil "msvc-~A.rsp" name) *vendor*)))
          (ensure-directories-exist objdir)
          (%write-response-file
           rsp
           (append (list "/nologo" "/O2" "/MT" "/c" "/MP" "/w"
                         (format nil "/Foobj\\~A\\" name))
                   (when (string= name "pcre2")
                     (list (format nil "/I\"~A\"" (no-trailing-separator
                                                   (uiop:native-namestring
                                                    (merge-pathnames "pcre2/" (gen-dir)))))))
                   ;; The quotes inside a define's value (the SHA1DC includes) are escaped for
                   ;; cl.exe's own parsing of a response file.
                   (mapcar (lambda (d) (format nil "/D~A" (uiop:frob-substrings d '("\"") "\\\"")))
                           (append (common-defines) defines))
                   includes
                   (mapcar (lambda (s) (format nil "\"~A\"" (uiop:native-namestring s))) files)))
          (format t "~&  ~A: ~D files~%" name (length files))
          (finish-output)
          (let ((code (nth-value 1 (%msvc-run (format nil "cl @~A" (file-namestring rsp))
                                              :timeout 1800))))
            (unless (zerop code)
              (error "cl.exe failed on the ~A group with exit code ~D (arguments in vendor/libgit2/~A)."
                     name code (file-namestring rsp)))))))
    (%write-response-file
     (merge-pathnames "msvc-link.rsp" *vendor*)
     (append (list "/nologo" "/DLL" (format nil "/OUT:lib\\~A" (output-name)))
             (mapcar (lambda (g) (format nil "obj\\~A\\*.obj" (first g))) (source-groups srcdir))
             *windows-libs*))
    (let ((code (nth-value 1 (%msvc-run "link @msvc-link.rsp"))))
      (unless (zerop code)
        (error "link.exe failed with exit code ~D (arguments in vendor/libgit2/msvc-link.rsp)."
               code)))
    (merge-pathnames (output-name) libdir)))

(defun require-toolchain ()
  "Refuse NOW if this machine cannot compile, before anything is downloaded."
  (ecase (toolchain)
    (:cc (unless (which "cc" "gcc" "clang")
           (error "No C compiler found (looked for cc, gcc, clang).")))
    (:msvc (unless (find-msvc) (no-msvc-error)))))

(defun compile-library (srcdir)
  (write-generated-headers)
  (ecase (toolchain)
    (:cc (compile-with-cc srcdir))
    (:msvc (compile-with-msvc srcdir))))

;;; ------------------------------------------------------------------ verification

(defun %exported-symbols (library)
  "The names LIBRARY exports, undecorated, or NIL if the platform's tool is unavailable."
  (flet ((lines (cmd)
           (let ((out (ignore-errors
                       (%run-bounded (list "sh" "-c" cmd)
                                     :capture t :ignore-error-status t :timeout 120))))
             (when out (uiop:split-string out :separator '(#\Newline))))))
    (ecase (platform)
      (:linux
       (loop for l in (lines (format nil "nm -D --defined-only ~A" (uiop:native-namestring library)))
             for name = (car (last (uiop:split-string (string-trim '(#\Space #\Tab #\Return) l))))
             when (and name (plusp (length name))) collect name))
      (:macos
       (loop for l in (lines (format nil "nm -gU ~A" (uiop:native-namestring library)))
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
                 when (and name (= 4 (length fields))
                           (or (uiop:string-prefix-p "git_" name) (uiop:string-prefix-p "giterr_" name)))
                   collect name)))))))

(defun verify-built (library)
  "The library is usable, not merely present: plausible size, the soname the loader will ask
for, every entry point aion/libgit binds, nothing but libgit2's API exported, and on Windows
no dependency on the VC++ runtime."
  (format t "~&~%Verifying ~A~%" (human-path:human-path library))
  (let ((size (with-open-file (s library :element-type '(unsigned-byte 8)) (file-length s))))
    (format t "  size ~:D bytes~%" size)
    (when (< size 500000)
      (error "The built library is implausibly small (~:D bytes)." size)))
  (when (eq (platform) :linux)
    (let ((soname (ignore-errors
                   (%run-bounded (list "sh" "-c" (format nil "readelf -d ~A | grep -i soname"
                                                         (uiop:native-namestring library)))
                                 :capture t :ignore-error-status t :timeout 60))))
      (when (and soname (plusp (length soname)))
        (format t "  ~A~%" (string-trim '(#\Space #\Tab) soname))
        (unless (search (output-name) soname)
          (error "SONAME does not name ~A." (output-name))))))
  (let ((exports (%exported-symbols library)))
    (when (null exports)
      (error "Could not read any exported symbol from ~A." (file-namestring library)))
    (format t "  exports ~:D symbols~%" (length exports))
    ;; ONLY libgit2's API. -fvisibility=hidden and an empty PCRE2_EXPORT keep the bundled
    ;; zlib, pcre2 and llhttp internal; a pcre2_ or inflate symbol here would mean they did
    ;; not, and could clash with another copy of the same library in the process.
    (let ((foreign (remove-if (lambda (n) (or (uiop:string-prefix-p "git_" n)
                                              (uiop:string-prefix-p "giterr_" n)))
                              exports)))
      (when (and foreign (not (eq (platform) :windows)))
        (error "The library exports ~D symbols that are not libgit2's API, for example ~{~A~^, ~}."
               (length foreign) (subseq foreign 0 (min 5 (length foreign))))))
    (dolist (sym *required-symbols*)
      (unless (member sym exports :test #'string=)
        (error "The built library does not export ~A." sym)))
    (format t "  exports all ~D entry points aion/libgit binds~%" (length *required-symbols*)))
  (when (eq (toolchain) :msvc)
    (let ((deps (%msvc-run (format nil "dumpbin /nologo /dependents \"~A\""
                                   (uiop:native-namestring library))
                           :capture t :timeout 300)))
      (when deps
        (if (search "VCRUNTIME" (string-upcase deps))
            (error "The DLL depends on the VC++ runtime: /MT did not take effect. It would fail on a clean machine.")
            (format t "  self-contained: no VC++ redistributable needed~%")))))
  library)

(defun install-licence (srcdir)
  "COPYING beside the library, where the desktop bundler looks for licence texts
(carry-natives.lisp's %LICENSE-FILES): the library is GPLv2 with the linking exception."
  (let ((dst (merge-pathnames "lib/COPYING" *vendor*)))
    (uiop:copy-file (merge-pathnames "COPYING" srcdir) dst)
    (format t "  licence: ~A~%" (human-path:human-path dst))))

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
        (format *error-output* "build-libgit2: libgit2.pin is missing version, url or sha256.~%")
        (uiop:quit 1))
      (format t "~&libgit2 ~A (~A) -> ~A~%" version (platform) (human-path:human-path *vendor*))
      ;; AN EXISTING LIBRARY IS VERIFIED, NOT TRUSTED: it passes VERIFY-BUILT or it is rebuilt.
      (when (and (probe-file (library-path)) (not force))
        (handler-case
            (progn (verify-built (library-path))
                   (format t "~&  already built: ~A~%  (--force to rebuild)~%"
                           (human-path:human-path (library-path)))
                   (uiop:quit 0))
          (error (e)
            (format t "~&  the library already there fails verification, so it is rebuilt:~%  ~A~%" e))))
      (handler-case
          (progn
            (require-toolchain)
            (let ((srcdir (ensure-source version url sha)))
              (verify-sources srcdir)
              (when force (aion/fs:delete-tree (merge-pathnames "obj/" *vendor*)
                                               :if-does-not-exist :ignore))
              (verify-built (compile-library srcdir))
              (install-licence srcdir)
              (format t "~&~%Built vendor/libgit2/lib/~A~%" (output-name))
              (uiop:quit 0)))
        (error (e)
          (format *error-output* "~&build-libgit2: ~A~%" e)
          (uiop:quit 1))))))

(main)
