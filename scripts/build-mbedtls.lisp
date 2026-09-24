;;;; build-mbedtls.lisp --- fetch, verify and build the pinned mbedTLS from source.
;;;;
;;;;     sbcl --script scripts/build-mbedtls.lisp            # build if missing
;;;;     sbcl --script scripts/build-mbedtls.lisp --force    # rebuild unconditionally
;;;;     sbcl --script scripts/build-mbedtls.lisp --clean    # remove vendor/mbedtls entirely
;;;;     sbcl --script scripts/build-mbedtls.lisp --where    # print the library path, build nothing
;;;;
;;;; Exit 0 on success, 1 on failure. Produces vendor/mbedtls/lib/<the platform soname>,
;;;; which is what aion/tls loads and what the desktop bundler carries.
;;;;
;;;; Same doctrine as build-libuv.lisp, and for the same reason: a native dependency we do
;;;; not build is a native dependency we cannot bundle. ADR-0011's libev story is the whole
;;;; argument -- Woo bound it at load time and every desktop bundle died on a clean machine
;;;; with "libev.so.4: cannot open shared object file". Two .asd files already refuse cl+ssl
;;;; in those words (mnemosyne.asd:26, aion.asd:492), so `aion/tls' being an OPT-IN aux
;;;; system built from a vendored source is precedent being applied, not a new decision.
;;;;
;;;; ONE LIBRARY, NOT THREE. Upstream builds libmbedtls, libmbedx509 and libmbedcrypto. We
;;;; link all 110 sources into a single shared object, because the bundler carries FILES and
;;;; three files is three chances to lose one -- and because there is no configuration in
;;;; which we want the TLS half without the crypto half.
;;;;
;;;; NO CMAKE, NO MAKE, NO PYTHON. The house rule is that `sbcl --script' is the only build
;;;; driver, and mbedTLS 4.1.1 permits it: every generated artifact ships pre-generated in
;;;; the release tarball, so the python/jinja generators are needed only to REgenerate.
;;;;
;;;; ---------------------------------------------------------------------------------
;;;; PLATFORM STATUS. Read this before trusting the file. Three platforms are not claimed
;;;; from one.
;;;;
;;;;   LINUX    PROVEN, cold. From an empty vendor/: fetch -> sha256 -> unpack -> source-set
;;;;            check -> link 110 sources -> SONAME and five exported symbols asserted.
;;;;            x86-64 Linux (WSL2, gcc), mbedTLS 4.1.1, 12s, 1,025,688 bytes.
;;;;   MACOS    UNVERIFIED, and the same `cc' invocation as Linux with -install_name in
;;;;            place of -soname -- exactly build-libuv.lisp's split. The only macOS-
;;;;            specific code here is the nm flag, because Apple's nm has neither -D nor
;;;;            --defined-only, and Mach-O prefixes C symbols with an underscore.
;;;;   WINDOWS  UNVERIFIED, and **NOT** A MIRROR OF build-libuv.lisp. The mechanism is
;;;;            different; assuming it mirrored is the mistake the next block exists to
;;;;            stop.
;;;;
;;;; WHY WINDOWS IS NOT A MIRROR, which is the finding of this commit.
;;;;
;;;; build-libuv.lisp's Windows half rests on one define: BUILDING_UV_SHARED makes libuv's
;;;; UV_EXTERN expand to __declspec(dllexport), and without it the DLL links cleanly and
;;;; exports NOTHING. mbedTLS HAS NO SUCH MACRO. Measured against the 4.1.1 tarball:
;;;;
;;;;   grep -rn 'dllexport\|dllimport' include/ tf-psa-crypto/include/  -> 0 hits
;;;;   find . -name '*.def'                                            -> 0 hits
;;;;   grep -rn 'WINDOWS_EXPORT_ALL_SYMBOLS' .                         -> 0 hits
;;;;
;;;; So there is no define to set and no module-definition file to point at. Upstream's own
;;;; Windows DLL gets its exports from CMake, which generates a .def by reading the object
;;;; files' symbol tables. That is the mechanism reproduced below: compile to objects, read
;;;; `dumpbin /symbols', write a .def, link with /DEF:.
;;;;
;;;; THE CODE BELOW MARKED MSVC HAS NEVER EXECUTED. It is a design, not a result. What a
;;;; Windows lane should expect to have to check:
;;;;   1. dumpbin /symbols column layout. The parse wants `External' and `SECTn' (defined)
;;;;      and must reject `UNDEF'; the name is the last field after the `|'.
;;;;   2. Name decoration. x64 C symbols are undecorated; a 32-bit build prefixes `_' and
;;;;      the .def wants it stripped. `vcvarsall-arch' decides which you get, and this
;;;;      tree's SBCL is x64, so x64 is the case that matters first.
;;;;   3. Whether 110 objects plus flags fit the link line. They go in a response file for
;;;;      the same reason build-libuv.lisp uses one -- cmd.exe truncates at 8191 characters
;;;;      and the failure is a syntax error deep in the arguments, not an honest "too long".
;;;;
;;;; What makes this safe to land unverified: `verify-built' on Windows COUNTS the exports
;;;; and insists on the symbols aion/tls will bind. A wrong .def produces a DLL
;;;; exporting nothing, and that is the one failure this script must not be silent about --
;;;; the same guard build-libuv.lisp grew, for the same reason.
;;;; ---------------------------------------------------------------------------------
;;;;
;;;; THE FILE WE PRODUCE **IS** THE SONAME, as in build-libuv.lisp, and that is what makes
;;;; pre-publication issue 329's hazard structurally absent here rather than avoided by care. pre-publication issue 329 is about two
;;;; bundler functions disagreeing over whether to name a copied library from the symlink or
;;;; from its target. Here there is no symlink to disagree about: we never run `make
;;;; install', so nothing creates the libmbedtls.so -> libmbedtls.so.1 chain an install step
;;;; would. Measured on the built tree:
;;;;
;;;;   find vendor/mbedtls/lib -type l  ->  0
;;;;   find vendor/mbedtls/lib -type f  ->  libmbedtls.so.1, the only file
;;;;   readelf -d                       ->  SONAME libmbedtls.so.1
;;;;
;;;; The loader asks for the name that landed. (The unpacked SOURCE tree does hold 147
;;;; symlinks, every one under tf-psa-crypto/drivers/pqcp/mldsa-native/examples/. None is
;;;; compiled, none is in mbedtls.sources, and the bundler copies from lib/, not src/.)

(require :uiop)

(defparameter *root* (uiop:pathname-parent-directory-pathname
                      (uiop:pathname-directory-pathname *load-truename*)))
(defparameter *vendor* (merge-pathnames "vendor/mbedtls/" *root*))

(defparameter *include-dirs*
  '("include"
    "library"
    "tf-psa-crypto/include"
    "tf-psa-crypto/core"
    "tf-psa-crypto/dispatch"
    "tf-psa-crypto/extras"
    "tf-psa-crypto/platform"
    "tf-psa-crypto/utilities"
    "tf-psa-crypto/drivers/builtin/include"
    "tf-psa-crypto/drivers/builtin/src")
  "Every -I the build needs. Two of these are not guessable from the source layout and cost
a failed compile each to discover:

  tf-psa-crypto/dispatch  holds the GENERATED header psa_crypto_driver_wrappers_no_static.h
                          while its matching .c ships in core/. TWO HALVES OF ONE GENERATED
                          PAIR, IN DIFFERENT DIRECTORIES -- so confirming that the .c ships
                          pre-generated, correctly, tells you nothing about the .h.
  tf-psa-crypto/extras    holds pk_wrap.h and pk_internal.h, which library/ includes.

The rest follow the source dirs. Obvious once and invisible afterwards, which is why they
are written down rather than left to the next failed build.")

(defparameter *required-symbols*
  '("mbedtls_ssl_handshake" "mbedtls_ssl_set_bio" "mbedtls_ssl_conf_own_cert"
    "psa_crypto_init" "mbedtls_x509_crt_parse_file"
    ;; Ours, from aion/src/tls/c/ouranos_tls.c (#125). One per reason the file exists:
    ;; allocation, inline wrappers, threading. A .def that dropped the ouranos_tls_ prefix
    ;; would build a DLL missing all of them, which is the failure this list is for.
    "ouranos_tls_shim_version" "ouranos_tls_threading_kind" "ouranos_tls_setup"
    "ouranos_tls_ssl_new" "ouranos_tls_conf_version_range"
    ;; Exported only when MBEDTLS_THREADING_C is on, so its presence shows that
    ;; ouranos_tls_config.h reached the compile.
    "mbedtls_mutex_init")
  "The entry points aion/tls binds. Asserting these rather than `the file exists' is
what distinguishes a library from a file of the right size: on Windows a missing export
table is the expected failure mode, not an exotic one.")

(defparameter *export-prefixes* '("mbedtls_" "psa_" "ouranos_tls_")
  "The prefixes of the names the library exports: mbedTLS's own, and ours. The Windows .def
is written from these, so a name with any other prefix is not exported there.")

(defun %exported-name-p (name)
  (some (lambda (prefix) (eql 0 (search prefix name))) *export-prefixes*))

(defparameter *shim-dir*
  (merge-pathnames "aion/src/tls/c/" *root*)
  "Our C (#125): ouranos_tls.c, compiled into the library, and the two headers it and
mbedTLS read. ouranos_tls_config.h switches on threading; threading_alt.h declares the
Windows threading types.")

(defparameter *config-define* "TF_PSA_CRYPTO_USER_CONFIG_FILE=<ouranos_tls_config.h>"
  "How ouranos_tls_config.h reaches every mbedTLS source. Angle brackets rather than quotes
so the value needs no escaping on either toolchain; the file is found through the -I to
*SHIM-DIR*.")

(defun shim-source ()
  (namestring (merge-pathnames "ouranos_tls.c" *shim-dir*)))

(defparameter *windows-libs* '("ws2_32.lib" "bcrypt.lib" "advapi32.lib")
  "Transcribed from tf-psa-crypto/core/CMakeLists.txt:79 -- `if(WIN32) set(libs ${libs}
ws2_32 bcrypt)'. advapi32 is added because library/net_sockets.c and the entropy path
reach for it; it is present on every Windows and costs nothing if unused.")

;;; ------------------------------------------------------------------- the pin

(defun pin-field (name)
  "The value of NAME in mbedtls.pin, or NIL. Lines are `name value', # comments."
  (with-open-file (in (merge-pathnames "mbedtls.pin" *root*) :if-does-not-exist nil)
    (when in
      (loop for line = (read-line in nil nil)
            while line
            for tr = (string-trim '(#\Space #\Tab #\Return) line)
            unless (or (zerop (length tr)) (char= #\# (char tr 0)))
              do (let ((sp (position-if (lambda (c) (member c '(#\Space #\Tab))) tr)))
                   (when (and sp (string= name (subseq tr 0 sp)))
                     (return (string-trim '(#\Space #\Tab) (subseq tr sp)))))))))

;;; -------------------------------------------------------------------- helpers

(defparameter *command-timeout* 600
  "Seconds any external command may run before it is stopped, unless its call gives its own
limit. A command that hangs then fails in minutes, naming itself, rather than as a CI job
cancelled at its own limit with nothing said about which command it was waiting for. That
is what #273's first Windows run did: tar ran for 38 minutes until the job's 40-minute limit
killed everything.")

(defun %describe (command)
  "COMMAND for a message: its first few words, whether it is a list or a cmd.exe string."
  (let ((text (if (stringp command) command (format nil "~{~A~^ ~}" command))))
    (if (> (length text) 160) (concatenate 'string (subseq text 0 160) " ...") text)))

(defun %run-bounded (command &key directory capture (timeout *command-timeout*)
                                  ignore-error-status)
  "Run COMMAND -- a list, or a string that cmd.exe runs -- and return (values OUTPUT CODE).
OUTPUT is its standard output as a string when CAPTURE is true, trailing whitespace removed,
and NIL otherwise, when the output goes straight to ours. Signals if it exits non-zero, unless
IGNORE-ERROR-STATUS, and if it has not finished within TIMEOUT seconds, after stopping it.

Captured output goes through a temporary file, not a pipe, so the wait below cannot deadlock
against a child blocked on a full pipe. Standard input is the null device, so a child that
reads it gets end-of-file rather than waiting. On Windows, stopping a cmd.exe string stops
cmd.exe; a child it started may outlive it, but the build has already failed by then."
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
               (sleep 0.1))
      (let ((code (uiop:wait-process process)))
        (unless (or ignore-error-status (eql code 0))
          (error "This command exited with code ~A:~%  ~A" code (%describe command)))
        (values (when capture
                  (string-right-trim '(#\Space #\Tab #\Return #\Newline)
                                     (uiop:read-file-string out :external-format :latin-1)))
                code)))))

(defun which (&rest candidates)
  "First of CANDIDATES on PATH, or NIL. `where' on Windows, `command -v' elsewhere --
there is no sh on a stock Windows, which is the same split build-libuv.lisp makes."
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
       ;; certutil prints a banner, the hex on line 2, then a trailer.
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
  (ecase (platform)
    (:linux "libmbedtls.so.1")
    (:macos "libmbedtls.1.dylib")
    (:windows "mbedtls.dll")))

(defun library-path ()
  (merge-pathnames (concatenate 'string "lib/" (output-name)) *vendor*))

(defun no-trailing-separator (namestring)
  "NAMESTRING without a trailing separator: `/I\"C:\\x\\inc\\\"' would have the backslash
escape the closing quote, which is how a path with a space in it silently becomes garbage."
  (string-right-trim '(#\\ #\/) namestring))

;;; ------------------------------------------------------------------ the source

(defun ensure-source (version url expected-sha)
  "The unpacked tree for VERSION, fetching and verifying the tarball if needed."
  (let* ((srcdir (merge-pathnames (format nil "src/mbedtls-~A/" version) *vendor*))
         (tarball (merge-pathnames (format nil "src/mbedtls-~A.tar.bz2" version) *vendor*)))
    (when (probe-file (merge-pathnames "library/ssl_tls.c" srcdir))
      (return-from ensure-source srcdir))
    (ensure-directories-exist tarball)
    (unless (probe-file tarball)
      (format t "~&Fetching ~A~%" url)
      (let ((fetcher (which "curl" "wget")))
        (unless fetcher (error "Need curl or wget to fetch the mbedTLS source."))
        (if (string= fetcher "curl")
            (run "curl" (list "-sSL" "--fail" "-o" (namestring tarball) url))
            (run "wget" (list "-q" "-O" (namestring tarball) url)))))
    ;; TRUST-ON-FIRST-USE, VERIFIED EVERY TIME AFTER. The pin turns a silent substitution
    ;; into a loud failure; it does not turn the first fetch into a trusted one.
    (let ((actual (sha256-of tarball)))
      (unless (string-equal actual expected-sha)
        ;; Delete it. A bad tarball left on disk is one a later run would find cached, and
        ;; the only thing standing between that and a silent accept is this line.
        (delete-file tarball)
        ;; One FORMAT directive per line, never a `~<newline>' continuation: on a CRLF
        ;; checkout the character after `~' is #\Return, an illegal directive that fails at
        ;; COMPILE time rather than where it is used (AGENTS.md).
        (error "mbedTLS tarball checksum mismatch.~%  expected ~A~%  actual   ~A~%The tarball has been deleted. Either upstream was substituted, or mbedtls.pin is stale."
               expected-sha actual)))
    (format t "~&  sha256 ok~%")
    ;; WHICH tar, and what it can decompress, printed before it runs. On Windows it is the
    ;; bsdtar in System32, by absolute path, so a GNU tar earlier on PATH (Git's, which reads
    ;; "D:/..." as a remote host) cannot be picked up instead.
    (let ((tar (tar-program)))
      (format t "~&  ~A~%"
              (or (ignore-errors (%run-bounded (list tar "--version") :capture t :timeout 30))
                  "(tar --version printed nothing)"))
      (run tar (list "xjf" (namestring tarball) "-C"
                     (namestring (merge-pathnames "src/" *vendor*)))
           :timeout 600))
    srcdir))

(defun tar-program ()
  (if (uiop:os-windows-p)
      (let ((system32 (merge-pathnames "System32/tar.exe"
                                       (uiop:ensure-directory-pathname
                                        (or (uiop:getenv "SystemRoot") "C:\\Windows")))))
        (if (probe-file system32) (uiop:native-namestring system32) "tar"))
      "tar"))

(defun verify-sources (srcdir)
  "Refuse to build a source set that is not the set mbedtls.sources records.

THE POINT OF THE PIN'S THIRD FIELD. The tarball sha256 proves we got the bytes we expected;
this proves the SET WE COMPILE is the set we transcribed. mbedTLS 4.x does not name its
sources -- six object libraries each glob their own *.c -- so there is no upstream list to
diff and the only available question is whether the set moved. It does move: 4.1.1 has one
more file under tf-psa-crypto/ than 4.2.0.

mbedtls-sources.lisp also checks the manifest against mbedtls.pin's sources-count and
sources-digest, so a stale pin fails here too rather than in a reader's head."
  (let ((script (merge-pathnames "scripts/mbedtls-sources.lisp" *root*)))
    (multiple-value-bind (out code)
        (%run-bounded (list "sbcl" "--script" (namestring script) (namestring srcdir))
                      :ignore-error-status t :timeout 300)
      (declare (ignore out))
      (unless (zerop code)
        (error "The mbedTLS source set does not match mbedtls.sources. See above.")))))

(defun sources-in (srcdir)
  (let ((manifest (merge-pathnames "mbedtls.sources" *root*)))
    (with-open-file (in manifest)
      (loop for line = (read-line in nil nil)
            while line
            for tr = (string-trim '(#\Space #\Tab #\Return) line)
            unless (or (zerop (length tr)) (char= #\# (char tr 0)))
              collect (namestring (merge-pathnames tr srcdir))))))

(defun include-args (srcdir prefix &key quote)
  "The -I/\"/I\" arguments, one per *include-dirs* entry."
  (mapcar (lambda (d)
            (let ((path (no-trailing-separator
                         (uiop:native-namestring
                          (merge-pathnames (concatenate 'string d "/") srcdir)))))
              (if quote
                  (format nil "~A\"~A\"" prefix path)
                  (format nil "~A~A" prefix path))))
          *include-dirs*))

;;; ------------------------------------------------------------ the MSVC toolchain
;;;
;;; Discovery is build-libuv.lisp's, verbatim in behaviour: vswhere at its fixed location,
;;; the C++ component required specifically, and the compile run through vcvarsall.bat so
;;; INCLUDE/LIB/PATH are set without "open a Developer Command Prompt first".
;;;
;;; The COMPILE is where the two scripts part company -- see the header.

(defun vcvarsall-arch ()
  (let ((machine (string-upcase (machine-type))))
    (cond ((search "ARM64" machine) "arm64")
          ((search "X86-64" machine) "x64")
          ((search "AMD64" machine) "x64")
          (t "x86"))))

(defun find-vswhere ()
  (let ((base (or (uiop:getenv "ProgramFiles(x86)") "C:\\Program Files (x86)")))
    (probe-file (merge-pathnames "Microsoft Visual Studio/Installer/vswhere.exe"
                                 (uiop:ensure-directory-pathname base)))))

(defun find-msvc ()
  "VCVARSALL-PATH, or NIL. Requires the C++ tools component specifically -- a Visual Studio
carrying only the .NET workload answers vswhere but cannot compile this."
  (let ((vswhere (find-vswhere)))
    (when vswhere
      (let* ((path (string-trim
                    '(#\Space #\Tab #\Newline #\Return)
                    (or (%run-bounded
                         (list (namestring vswhere) "-latest" "-products" "*"
                               "-requires" "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
                               "-property" "installationPath")
                         :capture t :ignore-error-status t :timeout 60)
                        "")))
             (install (when (plusp (length path)) (uiop:ensure-directory-pathname path))))
        (when install
          (probe-file (merge-pathnames "VC/Auxiliary/Build/vcvarsall.bat" install)))))))

(defun no-msvc-error ()
  (error "No MSVC C++ toolchain found.~%Install the Build Tools (about 2 GB, no IDE):~%  winget install --id Microsoft.VisualStudio.2022.BuildTools --override \"--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended\"~%MSYS2/MinGW is deliberately NOT used here (ECOSYSTEM decisions log)."))

(defun require-toolchain ()
  "Refuse NOW if this machine cannot compile, BEFORE anything is downloaded (pre-publication issue 128). A
prerequisite is a thing to check before you begin, not after a 5 MB fetch and a SHA-256."
  (ecase (toolchain)
    (:cc (unless (which "cc" "gcc" "clang")
           (error "No C compiler found (looked for cc, gcc, clang).")))
    (:msvc (unless (find-msvc) (no-msvc-error)))))

(defun msvc-command (inner)
  "INNER wrapped in the MSVC environment: a cmd.exe line that sources vcvarsall.bat first.

vswhere's own directory is prepended to PATH because VCVARSALL ITSELF SHELLS OUT TO
vswhere.exe by bare name and prints `'vswhere.exe' is not recognized' when it is not there."
  (let ((vcvarsall (find-msvc))
        (installer (find-vswhere)))
    (format nil "set \"PATH=%PATH%;~A\" && call \"~A\" ~A >nul && ~A"
            (no-trailing-separator
             (uiop:native-namestring (uiop:pathname-directory-pathname installer)))
            (uiop:native-namestring vcvarsall)
            (vcvarsall-arch)
            inner)))

(defun %msvc-run (inner &key capture (timeout *command-timeout*))
  "INNER in the MSVC environment, from vendor/mbedtls/. Returns (values OUTPUT CODE), OUTPUT
only when CAPTURE is true."
  (%run-bounded (msvc-command inner) :directory *vendor* :capture capture
                                     :ignore-error-status t :timeout timeout))

(defun %write-response-file (path lines)
  ;; Response file rather than a command line: 110 absolute source paths plus flags runs to
  ;; several kilobytes and cmd.exe truncates at 8191 characters, turning "too long" into a
  ;; syntax error deep in the argument list.
  (with-open-file (out path :direction :output :if-exists :supersede
                            :external-format :latin-1)
    (dolist (l lines) (write-line l out)))
  path)

(defun %msvc-generate-def (def-path)
  "Write DEF-PATH listing every external symbol our objects DEFINE, mbedTLS's own only.

THIS IS THE STEP THAT HAS NO COUNTERPART IN build-libuv.lisp. libuv marks its public API
with __declspec(dllexport) under BUILDING_UV_SHARED; mbedTLS marks nothing, ships no .def,
and does not set WINDOWS_EXPORT_ALL_SYMBOLS, so a /LD build of it exports an empty table.
CMake solves this for upstream by reading the object symbol tables and synthesising a .def.
That is what this does.

A dumpbin /symbols row for a defined external looks like

  008 00000000 SECT3  notype ()    External     | mbedtls_ssl_handshake

and for one merely referenced, SECT3 reads UNDEF. We take External + not-UNDEF, then keep
the prefixes in *EXPORT-PREFIXES* so we are not exporting the CRT's symbols along with ours.
A 32-bit build decorates cdecl names with a leading underscore; a .def wants the
undecorated name, so one is stripped if present."
  (let ((out (%msvc-run "dumpbin /nologo /symbols obj\\*.obj" :capture t :timeout 300))
        (seen (make-hash-table :test #'equal))
        (names '()))
    (with-input-from-string (in (or out ""))
      (loop for line = (read-line in nil nil)
            while line
            do (let ((bar (position #\| line)))
                 (when (and bar
                            (search " External " line)
                            (not (search "UNDEF" line)))
                   (let* ((raw (string-trim '(#\Space #\Tab #\Return)
                                            (subseq line (1+ bar))))
                          (name (if (and (plusp (length raw)) (char= #\_ (char raw 0)))
                                    (subseq raw 1)
                                    raw)))
                     (when (and (plusp (length name))
                                (%exported-name-p name)
                                (not (gethash name seen)))
                       (setf (gethash name seen) t)
                       (push name names)))))))
    (when (null names)
      (error "dumpbin /symbols yielded no mbedtls_/psa_/ouranos_tls_ externals. The .def would be empty and the DLL would export nothing -- see this file's header, item 1."))
    (setf names (sort names #'string<))
    (with-open-file (out-file def-path :direction :output :if-exists :supersede
                                       :external-format :latin-1)
      (write-line "EXPORTS" out-file)
      (dolist (n names) (format out-file "    ~A~%" n)))
    (format t "~&  generated mbedtls.def (~D exports)~%" (length names))
    (length names)))

(defun compile-with-msvc (srcdir)
  "Compile to objects, synthesise the export list, link. Three steps where the Unix path
has one, for the reason in the header."
  (unless (find-msvc) (no-msvc-error))
  (let* ((libdir (merge-pathnames "lib/" *vendor*))
         (objdir (merge-pathnames "obj/" *vendor*))
         (out (merge-pathnames (output-name) libdir))
         (sources (sources-in srcdir)))
    (ensure-directories-exist libdir)
    (ensure-directories-exist objdir)
    (%write-response-file
     (merge-pathnames "msvc-compile.rsp" *vendor*)
     (append (list "/nologo" "/O2"
                   ;; /MT, not /MD. A /MD build needs vcruntime140.dll on the target, which
                   ;; a clean Windows install does not have -- ADR-0011's failure in a new
                   ;; costume. Asserted in `verify-built', not just intended here.
                   "/MT"
                   "/c"
                   "/Foobj\\"
                   (format nil "/D~A" *config-define*)
                   (format nil "/I\"~A\"" (no-trailing-separator
                                           (uiop:native-namestring *shim-dir*))))
             (include-args srcdir "/I" :quote t)
             (mapcar (lambda (s) (format nil "\"~A\"" (uiop:native-namestring s)))
                     (append sources (list (shim-source))))))
    (format t "~&  compiling ~D sources and ouranos_tls.c with MSVC cl.exe (~A)~%"
            (length sources) (vcvarsall-arch))
    (finish-output)
    ;; 111 files, one cl.exe, no /MP: the slowest step on the slowest leg, so it gets more
    ;; than the default.
    (let ((code (nth-value 1 (%msvc-run "cl @msvc-compile.rsp" :timeout 1800))))
      (unless (zerop code)
        (error "cl.exe failed with exit code ~D (arguments in vendor/mbedtls/msvc-compile.rsp)."
               code)))
    (%msvc-generate-def (merge-pathnames "mbedtls.def" *vendor*))
    (%write-response-file
     (merge-pathnames "msvc-link.rsp" *vendor*)
     (append (list "/nologo" "/DLL" "/DEF:mbedtls.def"
                   (format nil "/OUT:lib\\~A" (output-name))
                   "obj\\*.obj")
             *windows-libs*))
    (let ((code (nth-value 1 (%msvc-run "link @msvc-link.rsp"))))
      (unless (zerop code)
        (error "link.exe failed with exit code ~D (arguments in vendor/mbedtls/msvc-link.rsp)."
               code)))
    out))

;;; -------------------------------------------------------------- the Unix compile

(defun compile-with-cc (srcdir)
  (let* ((cc (or (which "cc" "gcc" "clang")
                 (error "No C compiler found (looked for cc, gcc, clang).")))
         (libdir (merge-pathnames "lib/" *vendor*))
         (out (merge-pathnames (output-name) libdir))
         (sources (sources-in srcdir))
         (args (append
                ;; -pthread because ouranos_tls_config.h selects MBEDTLS_THREADING_PTHREAD.
                (list "-shared" "-fPIC" "-O2" "-pthread" "-o" (namestring out)
                      (format nil "-D~A" *config-define*)
                      (format nil "-I~A" (no-trailing-separator (namestring *shim-dir*))))
                ;; The built file must BE the soname: the loader resolves the soname, not
                ;; the path it was linked from. This is also what keeps pre-publication issue 329 inapplicable.
                (ecase (platform)
                  (:linux (list (format nil "-Wl,-soname,~A" (output-name))))
                  (:macos (list "-install_name" (namestring out))))
                (include-args srcdir "-I")
                sources
                (list (shim-source)))))
    (ensure-directories-exist libdir)
    (format t "~&  compiling ~D sources and ouranos_tls.c with ~A~%" (length sources) cc)
    (finish-output)
    (run cc args)
    out))

(defun compile-library (srcdir)
  (ecase (toolchain)
    (:cc (compile-with-cc srcdir))
    (:msvc (compile-with-msvc srcdir))))

;;; ------------------------------------------------------------------ verification

(defun %exported-symbols (library)
  "The names LIBRARY exports, undecorated, or NIL if the platform's tool is unavailable.

The tools disagree, so this is per-platform rather than one command with a flag:
  Linux    GNU nm, -D reads the DYNAMIC table (the only one that survives a strip).
  macOS    Apple's nm has neither -D nor --defined-only; -g is external, -U defined-only.
           Mach-O prefixes C symbols with `_', stripped here so callers compare like
           for like and cannot be fooled by the decoration.
  Windows  dumpbin /exports, which is inside the toolchain environment, not on PATH."
  (flet ((lines (cmd)
           (let ((out (ignore-errors
                       (%run-bounded (list "sh" "-c" cmd)
                                     :capture t :ignore-error-status t :timeout 120))))
             (when out (uiop:split-string out :separator '(#\Newline))))))
    (ecase (platform)
      (:linux
       (loop for l in (lines (format nil "nm -D --defined-only ~A"
                                     (uiop:native-namestring library)))
             for name = (car (last (uiop:split-string
                                    (string-trim '(#\Space #\Tab #\Return) l))))
             when (and name (plusp (length name))) collect name))
      (:macos
       (loop for l in (lines (format nil "nm -gU ~A" (uiop:native-namestring library)))
             for name = (car (last (uiop:split-string
                                    (string-trim '(#\Space #\Tab #\Return) l))))
             when (and name (plusp (length name)))
               collect (if (char= #\_ (char name 0)) (subseq name 1) name)))
      (:windows
       (let ((out (%msvc-run (format nil "dumpbin /nologo /exports \"~A\""
                                     (uiop:native-namestring library))
                             :capture t :timeout 300)))
         (when out
           (loop for l in (uiop:split-string out :separator '(#\Newline))
                 for fields = (remove "" (uiop:split-string
                                          (string-trim '(#\Space #\Tab #\Return) l))
                                      :test #'string=)
                 ;; An exports row is `ordinal hint rva name'; the name is last and, for
                 ;; this library, always starts with one of *EXPORT-PREFIXES*.
                 for name = (car (last fields))
                 when (and name (= 4 (length fields)) (%exported-name-p name))
                   collect name)))))))

(defun verify-built (library)
  "Assert the artifact is usable, not merely present.

A file existing proves the compiler exited 0. These checks prove the loader will find it
under the name it asks for, and that the entry points we are about to bind are in it."
  (format t "~&~%Verifying ~A~%" (namestring library))
  (let ((size (with-open-file (s library :element-type '(unsigned-byte 8)) (file-length s))))
    (format t "  size ~:D bytes~%" size)
    (when (< size 100000)
      (error "The built library is implausibly small (~:D bytes)." size)))
  (when (eq (platform) :linux)
    (let ((soname (ignore-errors
                   (%run-bounded (list "sh" "-c"
                                       (format nil "readelf -d ~A | grep -i soname"
                                               (uiop:native-namestring library)))
                                 :capture t :ignore-error-status t :timeout 60))))
      (when (and soname (plusp (length soname)))
        (format t "  ~A~%" (string-trim '(#\Space #\Tab) soname))
        (unless (search (output-name) soname)
          (error "SONAME does not name ~A -- the loader would ask for a name that is not the file that landed (pre-publication issue 329)."
                 (output-name))))))
  (let ((exports (%exported-symbols library)))
    (when (null exports)
      (error "Could not read any exported symbol from ~A. On Windows that is the expected shape of a missing export table; elsewhere it usually means nm is absent."
             (file-namestring library)))
    (format t "  exports ~:D symbols~%" (length exports))
    (dolist (sym *required-symbols*)
      (unless (member sym exports :test #'string=)
        (error "The built library does not export ~A." sym))
      (format t "  exports ~A~%" sym)))
  (when (eq (toolchain) :msvc)
    ;; The bundling claim, checked rather than asserted: a /MD build names vcruntime140.dll
    ;; here and dies on a clean machine, which is exactly ADR-0011's failure again.
    (let ((deps (%msvc-run (format nil "dumpbin /nologo /dependents \"~A\""
                                   (uiop:native-namestring library))
                           :capture t :timeout 300)))
      (when deps
        (if (search "VCRUNTIME" (string-upcase deps))
            (error "The DLL depends on the VC++ runtime -- /MT did not take effect. It would fail on a clean machine.")
            (format t "  self-contained: no VC++ redistributable needed~%")))))
  library)

;;; ------------------------------------------------------------------------- main

(defun main ()
  (let ((args (uiop:command-line-arguments)))
    (when (member "--where" args :test #'string=)
      (format t "~A~%" (namestring (library-path)))
      (uiop:quit 0))
    (when (member "--clean" args :test #'string=)
      (format t "~&removing ~A~%" (namestring *vendor*))
      (uiop:delete-directory-tree *vendor* :validate t :if-does-not-exist :ignore)
      (uiop:quit 0))
    (let ((version (pin-field "version"))
          (url (pin-field "url"))
          (sha (pin-field "sha256"))
          (force (member "--force" args :test #'string=)))
      (unless (and version url sha)
        (format *error-output* "build-mbedtls: mbedtls.pin is missing version, url or sha256.~%")
        (uiop:quit 1))
      (format t "~&mbedTLS ~A (~A) -> ~A~%" version (platform) (namestring *vendor*))
      ;; AN EXISTING LIBRARY IS VERIFIED, NOT TRUSTED. One built before ouranos_tls.c existed
      ;; is a file of the right name that lacks every symbol aion/tls needs, and "already
      ;; built" would have accepted it. It passes VERIFY-BUILT or it is rebuilt.
      (when (and (probe-file (library-path)) (not force))
        (handler-case
            (progn (verify-built (library-path))
                   (format t "~&  already built: ~A~%  (--force to rebuild)~%"
                           (namestring (library-path)))
                   (uiop:quit 0))
          (error (e)
            (format t "~&  the library already there fails verification, so it is rebuilt:~%  ~A~%" e))))
      (handler-case
          (progn
            ;; BEFORE the fetch. A machine with no compiler should not spend a download and
            ;; a SHA-256 to reach a refusal it could have been given immediately (pre-publication issue 128).
            (require-toolchain)
            (let ((srcdir (ensure-source version url sha)))
              (verify-sources srcdir)
              (verify-built (compile-library srcdir))
              (format t "~&~%Built vendor/mbedtls/lib/~A~%" (output-name))
              (uiop:quit 0)))
        (error (e)
          (format *error-output* "~&build-mbedtls: ~A~%" e)
          (uiop:quit 1))))))

(main)
