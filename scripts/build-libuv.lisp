;;;; build-libuv.lisp --- fetch, verify and build the pinned libuv. No make, no cmake.
;;;;
;;;;     sbcl --script scripts/build-libuv.lisp            # build if missing
;;;;     sbcl --script scripts/build-libuv.lisp --force     # rebuild unconditionally
;;;;     sbcl --script scripts/build-libuv.lisp --clean     # remove vendor/libuv entirely
;;;;     sbcl --script scripts/build-libuv.lisp --where     # print the library path, build nothing
;;;;
;;;; On a machine carrying SEVERAL MSVC installs, `vswhere -latest' silently picks the
;;;; newest and there is otherwise no way to see which or to choose another:
;;;;
;;;;     sbcl --script scripts/vswhere-probe.lisp            # which install will be used?
;;;;     OURANOS_MSVC_PATH=<install root> sbcl --script scripts/build-libuv.lisp
;;;;
;;;; That override is an instrument for the person VERIFYING a toolchain, not a convenience
;;;; and not a way to ship past a broken one -- see `msvc-override' for why it announces
;;;; itself and why it refuses rather than falling back.
;;;;
;;;; Exit 0 on success, 1 on failure. Produces vendor/libuv/lib/<the platform soname>,
;;;; which `aion/uv` loads in preference to any system libuv.
;;;;
;;;; WHY THIS EXISTS AT ALL, rather than `apt install libuv1-dev`:
;;;; ADR-0011. Woo bound libev at load time, so every Linux/macOS desktop bundle CI
;;;; produced was dead on arrival on a clean machine -- "libev.so.4: cannot open shared
;;;; object file". A native dependency you do not build is one you cannot bundle, and the
;;;; failure lands on the user rather than on us. Building it ourselves also gives all
;;;; three platforms ONE version instead of whatever apt/brew/MSYS2 happen to carry.
;;;;
;;;; WHY NO CMAKE: the house rule is that `sbcl --script` is the only build driver in this
;;;; tree (no make / just / nmake). Building libuv does not actually need a build system --
;;;; it is one compiler invocation over a known list of C files. That list, the -D defines
;;;; and the link libraries below are transcribed from libuv's own CMakeLists.txt for the
;;;; pinned version; re-check them when bumping libuv.pin.
;;;;
;;;; THE PREREQUISITE RULE: nothing beyond the platform's OWN first-party toolchain.
;;;;   macOS   -- Xcode Command Line Tools (`cc`)
;;;;   Linux   -- the distro's gcc/clang
;;;;   Windows -- MSVC `cl.exe` (Visual Studio Build Tools)
;;;;
;;;; Explicitly NOT MSYS2/MinGW, even though libuv builds fine under it. Requiring a
;;;; Unix-emulation layer is one more thing a Windows developer must acquire before
;;;; anything works, and the point of driving the compile from Lisp is that there is
;;;; nothing to acquire but a compiler. Each platform uses the compiler its own vendor
;;;; ships; that is a rule, not a fallback list.
;;;;
;;;; TOOLCHAINS. The source list and the defines are shared; only the ARGV differs, so the
;;;; flag construction is per-toolchain (`:cc` and `:msvc`) rather than per-platform:
;;;; MSVC speaks /LD for -shared, /Fe: for -o, /I, /D, /O2, and has no -fPIC or soname.
;;;; `cl.exe` is not on PATH by default and this script must not assume a developer
;;;; prompt, so the install is located with `vswhere.exe` (a fixed path under
;;;; %ProgramFiles(x86)%) and the compile runs through that install's `vcvarsall.bat`.
;;;;
;;;; TWO WINDOWS-ONLY FACTS, both learned by the build failing without them:
;;;;   BUILDING_UV_SHARED must be defined. libuv's UV_EXTERN expands to
;;;;   __declspec(dllexport) only under it -- gcc exports everything by default, so the
;;;;   Unix builds never needed it, and without it the DLL links fine and exports NOTHING.
;;;;   /MT, not /MD. A /MD build needs vcruntime140.dll on the target machine, which is
;;;;   not present on a clean Windows install -- exactly the ADR-0011 failure this script
;;;;   exists to prevent, in a new costume. /MT statically links the CRT into libuv.dll,
;;;;   so a bundle carries one self-contained file.
;;;;
;;;; ON MIXING C RUNTIMES (verified, not assumed -- see #84). The official Windows SBCL is
;;;; MinGW-built and links msvcrt.dll; an MSVC-built libuv.dll carries its own statically
;;;; linked CRT. Two allocators in one process is safe here for one reason only: NOTHING IS
;;;; FREED ACROSS THE BOUNDARY. Every cffi:foreign-alloc in aion/src/uv is released by
;;;; cffi:foreign-free, every allocation libuv makes is released by uv_fs_req_cleanup, and
;;;; the strings libuv returns (uv_strerror, uv_err_name, uv_fs_get_ptr) are COPIED with
;;;; foreign-string-to-lisp, never freed. File descriptors from uv_fs_open are likewise
;;;; passed only back to uv_fs_* -- a libuv fd is an index into libuv's CRT table and would
;;;; be meaningless to SBCL's. If a future binding frees a libuv pointer, hands a libuv fd
;;;; to CL file I/O, or binds an ownership-transferring call (uv_cpu_info, uv_setup_args,
;;;; uv_interface_addresses), that invariant breaks and this pairing stops being safe.

(require :asdf)
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; how a path is printed (#168)

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*)))
  "The monorepo root -- this script lives in scripts/.")

(defparameter *vendor* (merge-pathnames "vendor/libuv/" *root*)
  "Everything this script produces lives here, and nothing here is committed.")

;;; ---------------------------------------------------------------- the pin

(defun pin-field (name)
  "Return the value of NAME in libuv.pin, or NIL. Lines are `name value', # comments."
  (with-open-file (in (merge-pathnames "libuv.pin" *root*) :if-does-not-exist nil)
    (when in
      (loop for line = (read-line in nil)
            while line
            do (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
                 (when (and (> (length trimmed) (length name))
                            (string= name trimmed :end2 (length name))
                            (member (char trimmed (length name)) '(#\Space #\Tab)))
                   (return (string-trim '(#\Space #\Tab)
                                        (subseq trimmed (length name))))))))))

;;; ------------------------------------------------------- platform knowledge
;;;
;;; Transcribed from libuv's CMakeLists.txt. `uv_sources` is common to every platform;
;;; the rest is selected by OS. Verified against 1.52.1.

(defparameter *common-sources*
  '("src/fs-poll.c" "src/idna.c" "src/inet.c" "src/random.c" "src/strscpy.c"
    "src/strtok.c" "src/thread-common.c" "src/threadpool.c" "src/timer.c"
    "src/uv-common.c" "src/uv-data-getter-setters.c" "src/version.c"))

(defparameter *unix-sources*
  '("src/unix/async.c" "src/unix/core.c" "src/unix/dl.c" "src/unix/fs.c"
    "src/unix/getaddrinfo.c" "src/unix/getnameinfo.c" "src/unix/loop-watcher.c"
    "src/unix/loop.c" "src/unix/pipe.c" "src/unix/poll.c" "src/unix/process.c"
    "src/unix/random-devurandom.c" "src/unix/signal.c" "src/unix/stream.c"
    "src/unix/tcp.c" "src/unix/thread.c" "src/unix/tty.c" "src/unix/udp.c"))

(defparameter *linux-sources*
  '("src/unix/linux.c" "src/unix/procfs-exepath.c" "src/unix/random-getrandom.c"
    "src/unix/random-sysctl-linux.c" "src/unix/proctitle.c"))

(defparameter *darwin-sources*
  ;; fsevents.c dlopens CoreServices at runtime rather than link-depending on it, so no
  ;; -framework flags are needed here. If a mac build ever fails to link, that is the
  ;; first thing to revisit.
  '("src/unix/darwin-proctitle.c" "src/unix/darwin.c" "src/unix/fsevents.c"
    "src/unix/proctitle.c" "src/unix/bsd-ifaddrs.c" "src/unix/kqueue.c"
    "src/unix/random-getentropy.c"))

(defparameter *windows-sources*
  '("src/win/async.c" "src/win/core.c" "src/win/detect-wakeup.c" "src/win/dl.c"
    "src/win/error.c" "src/win/fs.c" "src/win/fs-event.c" "src/win/getaddrinfo.c"
    "src/win/getnameinfo.c" "src/win/handle.c" "src/win/loop-watcher.c" "src/win/pipe.c"
    "src/win/thread.c" "src/win/poll.c" "src/win/process.c" "src/win/process-stdio.c"
    "src/win/signal.c" "src/win/snprintf.c" "src/win/stream.c" "src/win/tcp.c"
    "src/win/tty.c" "src/win/udp.c" "src/win/util.c" "src/win/winapi.c"
    "src/win/winsock.c"))

(defun platform ()
  (cond ((uiop:os-windows-p) :windows)
        ((uiop:os-macosx-p) :macos)
        ((uiop:os-unix-p) :linux)
        (t (error "Unsupported platform for libuv build."))))

(defun platform-spec (platform)
  "Return (values sources defines libs output-name) for PLATFORM."
  (ecase platform
    (:linux
     (values (append *common-sources* *unix-sources* *linux-sources*)
             '("_FILE_OFFSET_BITS=64" "_LARGEFILE_SOURCE" "_GNU_SOURCE"
               "_POSIX_C_SOURCE=200112")
             '("-lpthread" "-ldl" "-lrt")
             "libuv.so.1"))
    (:macos
     (values (append *common-sources* *unix-sources* *darwin-sources*)
             '("_FILE_OFFSET_BITS=64" "_LARGEFILE_SOURCE"
               "_DARWIN_UNLIMITED_SELECT=1" "_DARWIN_USE_64_BIT_INODE=1")
             '("-lpthread")
             "libuv.1.dylib"))
    (:windows
     (values (append *common-sources* *windows-sources*)
             '("WIN32_LEAN_AND_MEAN" "_WIN32_WINNT=0x0A00" "_CRT_DECLARE_NONSTDC_NAMES=0")
             '("-lpsapi" "-luser32" "-ladvapi32" "-liphlpapi" "-luserenv" "-lws2_32"
               "-ldbghelp" "-lole32" "-lshell32")
             "libuv.dll"))))

(defun library-path ()
  (multiple-value-bind (sources defines libs name) (platform-spec (platform))
    (declare (ignore sources defines libs))
    (merge-pathnames (concatenate 'string "lib/" name) *vendor*)))

;;; ------------------------------------------------------------------ helpers

(defun run (program args &key (on-error :signal) output)
  "Run PROGRAM. Returns the exit code; signals on failure unless ON-ERROR is :return."
  (multiple-value-bind (out err code)
      (uiop:run-program (cons program args)
                        :output (or output nil) :error-output t :ignore-error-status t)
    (declare (ignore out err))
    (when (and (/= code 0) (eq on-error :signal))
      (error "~A failed with exit code ~D." program code))
    code))

(defun which (&rest candidates)
  "First of CANDIDATES that exists on PATH, or NIL."
  (loop for c in candidates
        when (ignore-errors
              (zerop (run (if (uiop:os-windows-p) "where" "which") (list c)
                          :on-error :return :output nil)))
          return c))

(defun sha256-of (file)
  "Hex sha256 of FILE, computed by whatever the platform provides."
  (flet ((first-word (s)
           (let ((s (string-trim '(#\Space #\Tab #\Newline #\Return) s)))
             (subseq s 0 (or (position-if (lambda (c) (member c '(#\Space #\Tab))) s)
                             (length s))))))
    (cond
      ((which "sha256sum")
       (first-word (uiop:run-program (list "sha256sum" (namestring file))
                                     :output '(:string :stripped t))))
      ((which "shasum")
       (first-word (uiop:run-program (list "shasum" "-a" "256" (namestring file))
                                     :output '(:string :stripped t))))
      ((and (uiop:os-windows-p) (which "certutil"))
       ;; certutil prints a banner, the hex on line 2, then a trailer.
       (let* ((out (uiop:run-program (list "certutil" "-hashfile" (namestring file) "SHA256")
                                     :output '(:string :stripped t)))
              (lines (uiop:split-string out :separator '(#\Newline))))
         (string-downcase (remove #\Space (or (second lines) "")))))
      (t (error "No sha256 tool found (looked for sha256sum, shasum, certutil).")))))

;;; ---------------------------------------------------------------- toolchain
;;;
;;; Which compiler, and how to reach it. The rule (ECOSYSTEM decisions log): each platform
;;; uses the compiler its OWN vendor ships -- Xcode CLT on macOS, the distro's gcc on
;;; Linux, MSVC on Windows -- and never a Unix-emulation layer. MSYS2/MinGW builds libuv
;;; perfectly well; requiring it is the tax being refused.

(defun toolchain ()
  (if (uiop:os-windows-p) :msvc :cc))

(defun vcvarsall-arch ()
  "The vcvarsall.bat argument for this machine, from the running Lisp's own architecture."
  (let ((machine (string-upcase (machine-type))))
    (cond ((search "ARM64" machine) "arm64")
          ((search "X86-64" machine) "x64")
          ((search "AMD64" machine) "x64")
          (t "x86"))))

(defun find-vswhere ()
  "vswhere.exe, at the fixed location Microsoft guarantees for it. It is the supported way
to find a Visual Studio install: the registry keys moved between versions, the install path
is not fixed, and there may be several side by side."
  (let ((base (or (uiop:getenv "ProgramFiles(x86)") "C:\\Program Files (x86)")))
    (probe-file (merge-pathnames "Microsoft Visual Studio/Installer/vswhere.exe"
                                 (uiop:ensure-directory-pathname base)))))

(defun find-msvc-via-vswhere ()
  "Return (values VCVARSALL-PATH INSTALL-NAME), or NIL if no suitable install exists.
Requires the C++ tools component specifically -- a Visual Studio carrying only, say, the
.NET workload will answer vswhere but cannot compile this."
  (let ((vswhere (find-vswhere)))
    (when vswhere
      (let* ((path (string-trim
                    '(#\Space #\Tab #\Newline #\Return)
                    (uiop:run-program (list (namestring vswhere)
                                            "-latest" "-products" "*"
                                            "-requires" "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
                                            "-property" "installationPath")
                                      :output '(:string :stripped t)
                                      :ignore-error-status t)))
             (install (when (plusp (length path)) (uiop:ensure-directory-pathname path)))
             (vcvarsall (when install
                          (probe-file (merge-pathnames "VC/Auxiliary/Build/vcvarsall.bat"
                                                       install)))))
        (when vcvarsall
          ;; vcvarsall puts cl.exe on PATH for the compile, which is more robust than
          ;; reconstructing VC/Tools/MSVC/<version>/bin/Host<arch>/<arch>/cl.exe by hand --
          ;; that layout is versioned and has changed.
          (values vcvarsall path))))))

(defparameter *msvc-override-announced* nil
  "So the notice prints once. `find-msvc' is called by the early prerequisite check, by the
compile, and twice by dumpbin -- four announcements of one fact reads like four decisions.")

(defun msvc-override ()
  "Return (values VCVARSALL-PATH INSTALL-PATH) for the install named by OURANOS_MSVC_PATH,
or NIL when that variable is unset.

WHY THIS EXISTS, so that the next reader does not mistake it for a convenience.
`find-msvc-via-vswhere' asks vswhere for `-latest'. On a machine carrying one install that
is the whole answer. On a machine carrying several it silently picks the newest and offers
no way to see which it picked, or to choose another -- and that is tolerable right up to
the point where THE CHOICE IS THE QUESTION.

It is the question in pre-publication issue 382. The claim under test there is not `does libuv build on this
box', it is `does libuv build with the BUILD TOOLS' -- the toolchain a user gets from the
winget line in `no-msvc-error', which is what a developer who does not want a 10 GB IDE
installs. A box carrying both a full Visual Studio and a Build Tools install answers only
for the Visual Studio, so the configuration A USER ACTUALLY HAS is the one configuration
that cannot be reached. The alternative was to drive the compile from a separate script,
which would have measured a faithful build of something other than what ships (pre-publication issue 206, pre-publication issue 77).

FOR THE PERSON DOING THE VERIFYING -- not a way to ship past a broken toolchain. Two
properties keep it that way and both are load-bearing:

  IT ANNOUNCES ITSELF, on stdout, in the build's own output. A log from a build whose
  toolchain came from the environment rather than from discovery must not be mistakable
  for a log from a discovered build, because the whole value of pasting the log is that a
  reader can tell which configuration produced it.

  IT REFUSES RATHER THAN FALLS BACK. A path with no vcvarsall.bat under it is an ERROR
  naming the variable and the path -- never a quiet NIL that lets vswhere answer instead.
  A silently-ignored override is strictly worse than no override: it reports the `-latest'
  install's result under the override's name, so the one reader who was trying to
  distinguish two toolchains gets the wrong one and no indication of it."
  (let ((raw (uiop:getenv "OURANOS_MSVC_PATH")))
    (when (and raw (plusp (length (string-trim '(#\Space #\Tab #\") raw))))
      (let* ((path (uiop:ensure-directory-pathname
                    (string-trim '(#\Space #\Tab #\") raw)))
             (vcvarsall (probe-file (merge-pathnames "VC/Auxiliary/Build/vcvarsall.bat"
                                                     path))))
        ;; One long control string: a ~<newline> continuation becomes an illegal ~<Return>
        ;; directive on a CRLF checkout (see CLAUDE.md).
        (unless vcvarsall
          (error "OURANOS_MSVC_PATH=~A has no VC/Auxiliary/Build/vcvarsall.bat under it, so it is not a Visual Studio or Build Tools installation root.~%Refusing rather than falling back to vswhere: a build run under this variable is the install it names, or it is nothing."
                 raw))
        (unless *msvc-override-announced*
          (setf *msvc-override-announced* t)
          (format t "~&  MSVC from OURANOS_MSVC_PATH, NOT from vswhere -latest: ~A~%"
                  (uiop:native-namestring path))
          (finish-output))
        (values vcvarsall (namestring path))))))

(defun find-msvc ()
  "Return (values VCVARSALL-PATH INSTALL-PATH), or NIL if this machine cannot compile.

OURANOS_MSVC_PATH wins when it is set; otherwise vswhere answers. The override is not a
fallback in either direction -- see `msvc-override' for why it refuses instead of
deferring."
  (multiple-value-bind (vcvarsall path) (msvc-override)
    (if vcvarsall
        (values vcvarsall path)
        (find-msvc-via-vswhere))))

(defun msvc-command (inner)
  "Wrap INNER in the MSVC environment: a cmd.exe line that sources vcvarsall.bat first.
That is what replaces `open a Developer Command Prompt' -- vcvarsall sets INCLUDE, LIB and
PATH for the process that calls it, so cl.exe has to run inside the same shell.

vswhere's own directory is prepended to PATH because VCVARSALL ITSELF SHELLS OUT TO
vswhere.exe by bare name, and prints `'vswhere.exe' is not recognized' when it is not on
PATH. Here that turned out to be harmless noise, but it is vcvarsall's own instance
detection failing, and a machine where the fallback does not land as well would produce a
confusing failure rather than a clear one.

IT IS ALSO OPTIONAL NOW, AND WAS NOT BEFORE. `find-msvc' used to require vswhere, so
`installer' could not be NIL by the time this ran. With OURANOS_MSVC_PATH the toolchain is
reachable on a box where vswhere.exe is absent -- and `pathname-directory-pathname' of NIL
is not a path. So the prepend is built conditionally: vcvarsall's own instance detection
degrades to whatever fallback it has, which is the same harmless noise as before, rather
than this function dying on a NIL."
  (let* ((vcvarsall (find-msvc))
         (installer (find-vswhere))
         (path-prefix
           (if installer
               (format nil "set \"PATH=%PATH%;~A\" && "
                       (no-trailing-separator
                        (uiop:native-namestring
                         (uiop:pathname-directory-pathname installer))))
               "")))
    (format nil "~Acall \"~A\" ~A >nul && ~A"
            path-prefix
            (uiop:native-namestring vcvarsall)
            (vcvarsall-arch)
            inner)))

(defun msvc-libs (libs)
  "Translate the shared gcc-style link list (-lws2_32) into MSVC's (ws2_32.lib)."
  (mapcar (lambda (l)
            (concatenate 'string (if (and (> (length l) 2) (string= "-l" l :end2 2))
                                     (subseq l 2)
                                     l)
                         ".lib"))
          libs))

(defun no-trailing-separator (namestring)
  "NAMESTRING without a trailing separator: `/I\"C:\\x\\inc\\\"` would have the backslash
escape the closing quote, which is how a path with a space in it silently becomes garbage."
  (string-right-trim '(#\\ #\/) namestring))

(defun fetch (url destination)
  (let ((curl (which "curl"))
        (wget (which "wget")))
    (cond (curl (run curl (list "-sSL" "--fail" "-o" (namestring destination) url)))
          (wget (run wget (list "-q" "-O" (namestring destination) url)))
          (t (error "Neither curl nor wget is available to fetch ~A." url)))))

;;; -------------------------------------------------------------------- steps

(defun ensure-source (version url expected-sha)
  "Fetch + verify + unpack the pinned tarball. Returns the unpacked source directory."
  (let* ((tarball (merge-pathnames (format nil "libuv-v~A.tar.gz" version) *vendor*))
         (srcdir (merge-pathnames (format nil "src/libuv-v~A/" version) *vendor*)))
    (ensure-directories-exist *vendor*)
    (unless (probe-file tarball)
      (format t "~&  fetching ~A~%" url)
      (finish-output)
      (fetch url tarball))
    (let ((actual (sha256-of tarball)))
      (unless (string-equal actual expected-sha)
        ;; Delete it: a bad tarball left on disk would be "verified" as cached next run.
        (delete-file tarball)
        ;; One long control string: a ~<newline> continuation becomes an illegal
        ;; ~<Return> directive on a CRLF checkout (see CLAUDE.md).
        (error "sha256 MISMATCH for ~A~%  expected ~A~%  actual   ~A~%The tarball has been deleted. Either upstream was substituted, or libuv.pin is stale."
               (file-namestring tarball) expected-sha actual))
      (format t "~&  sha256 verified (~A)~%" (subseq actual 0 16)))
    (unless (probe-file (merge-pathnames "include/uv.h" srcdir))
      (format t "~&  unpacking~%")
      (finish-output)
      (ensure-directories-exist (merge-pathnames "src/" *vendor*))
      ;; tar ships with macOS, every Linux, and Windows 10+ (bsdtar).
      (run "tar" (list "xzf" (namestring tarball)
                       "-C" (namestring (merge-pathnames "src/" *vendor*)))))
    srcdir))

(defun compile-with-cc (srcdir sources defines libs output-name)
  "The Unix toolchains: one gcc-style invocation."
  (let* ((cc (or (which "cc" "gcc" "clang")
                 (error "No C compiler found (looked for cc, gcc, clang). aion/uv needs one; the rest of the tree does not.")))
         (libdir (merge-pathnames "lib/" *vendor*))
         (output (merge-pathnames output-name libdir))
         (args (append
                (list "-shared" "-fPIC" "-O2" "-o" (namestring output))
                ;; The built file must BE the soname: the dynamic loader resolves the
                ;; soname, not the path it was linked from.
                (ecase (platform)
                  (:linux (list (format nil "-Wl,-soname,~A" output-name)))
                  (:macos (list "-install_name" (namestring output)))
                  (:windows '()))
                (list (format nil "-I~A" (namestring (merge-pathnames "include/" srcdir)))
                      (format nil "-I~A" (namestring (merge-pathnames "src/" srcdir))))
                (mapcar (lambda (d) (format nil "-D~A" d)) defines)
                (mapcar (lambda (s) (namestring (merge-pathnames s srcdir))) sources)
                libs)))
    (ensure-directories-exist libdir)
    (format t "~&  compiling ~D sources with ~A~%" (length sources) cc)
    (finish-output)
    (run cc args)
    output))

(defun no-msvc-error ()
  "The one copy of the refusal, so the early check and the late one cannot drift apart."
  (error "No MSVC C++ toolchain found.~%Install the Build Tools (about 2 GB, no IDE):~%  winget install --id Microsoft.VisualStudio.2022.BuildTools --override \"--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended\"~%This is the only prerequisite aion/uv adds, and nothing else in the tree needs it.~%MSYS2/MinGW is deliberately NOT used here (ECOSYSTEM decisions log)."))

(defun require-toolchain ()
  "Refuse NOW if this machine cannot compile, BEFORE anything is downloaded (pre-publication issue 128).

The check used to live only inside `compile-with-msvc', which runs after `ensure-source'
has fetched a tarball, verified its checksum and unpacked it. So a machine with no compiler
did two megabytes of work and a SHA-256 to arrive at a message it could have been given
immediately. Measured on a machine with Visual Studio made invisible:

  libuv 1.52.1 (WINDOWS)
    fetching https://dist.libuv.org/dist/v1.52.1/libuv-v1.52.1.tar.gz
    sha256 verified (66d511b9e6e334c0)
    unpacking
  FAILED: No MSVC C++ toolchain found. ...

Nothing was wrong with the refusal; it simply arrived after the part that made it a waste
of the user's time. A prerequisite is a thing to check before you begin."
  (when (and (eq (toolchain) :msvc) (not (find-msvc)))
    (no-msvc-error)))

(defun compile-with-msvc (srcdir sources defines libs output-name)
  "MSVC: the same sources and defines, cl.exe's vocabulary, one invocation.

The arguments go in a RESPONSE FILE rather than on the command line. 37 absolute source
paths plus flags runs to several kilobytes, cmd.exe truncates at 8191 characters, and the
failure would be a baffling syntax error deep in the argument list rather than an honest
`too long'. cl.exe has read @files since forever, so this costs nothing."
  (let* ((vcvarsall (find-msvc))
         (libdir (merge-pathnames "lib/" *vendor*))
         (objdir (merge-pathnames "obj/" *vendor*))
         (rsp (merge-pathnames "msvc-args.rsp" *vendor*))
         (output (merge-pathnames output-name libdir)))
    (unless vcvarsall (no-msvc-error))
    (ensure-directories-exist libdir)
    (ensure-directories-exist objdir)
    (with-open-file (out rsp :direction :output :if-exists :supersede
                             :external-format :latin-1)
      (flet ((emit (fmt &rest args) (format out "~?~%" fmt args)))
        (emit "/nologo")
        (emit "/O2")
        ;; /MT: static CRT. See the header -- a /MD build needs vcruntime140.dll on the
        ;; target, which a clean Windows box does not have.
        (emit "/MT")
        (emit "/LD")                    ; build a DLL (the /Fe: below names it)
        ;; Paths are RELATIVE because the compile runs with :directory *vendor*: a relative
        ;; path cannot contain a space, so it needs no quoting, and a quoted absolute path
        ;; ending in a separator would escape its own closing quote.
        (emit "/Fe:lib\\~A" output-name)
        (emit "/Foobj\\")               ; objects here, not scattered in the working dir
        (emit "/I\"~A\"" (no-trailing-separator
                          (uiop:native-namestring (merge-pathnames "include/" srcdir))))
        (emit "/I\"~A\"" (no-trailing-separator
                          (uiop:native-namestring (merge-pathnames "src/" srcdir))))
        (dolist (d defines) (emit "/D~A" d))
        ;; Windows-only, and load-bearing: without it UV_EXTERN is a bare `extern` and the
        ;; DLL exports nothing at all. gcc exports by default, which is why the shared
        ;; define list does not carry it.
        (emit "/DBUILDING_UV_SHARED")
        (dolist (s sources)
          (emit "\"~A\"" (uiop:native-namestring (merge-pathnames s srcdir))))
        (emit "/link")
        (dolist (l (msvc-libs libs)) (emit "~A" l))))
    (format t "~&  compiling ~D sources with MSVC cl.exe (~A)~%" (length sources)
            (vcvarsall-arch))
    (finish-output)
    ;; A string command runs through cmd.exe, which is required: vcvarsall.bat sets INCLUDE,
    ;; LIB and PATH for the process that calls it, and those must survive into cl.exe. This
    ;; is what replaces "open a Developer Command Prompt first".
    (let ((code (nth-value 2
                 (uiop:run-program (msvc-command "cl @msvc-args.rsp")
                                   :directory *vendor* :output t :error-output t
                                   :ignore-error-status t))))
      (unless (zerop code)
        (error "cl.exe failed with exit code ~D (arguments in ~A)."
               code (uiop:native-namestring rsp))))
    output))

(defun compile-library (srcdir)
  "Compile SRCDIR into the platform shared library. One compiler invocation."
  (multiple-value-bind (sources defines libs output-name) (platform-spec (platform))
    (ecase (toolchain)
      (:cc (compile-with-cc srcdir sources defines libs output-name))
      (:msvc (compile-with-msvc srcdir sources defines libs output-name)))))

(defun %msvc-dumpbin (library switch)
  "Run dumpbin SWITCH over LIBRARY and return its output, or NIL. dumpbin ships with MSVC
and is only on PATH inside the toolchain environment, so it goes through vcvarsall too."
  (when (find-msvc)
    (ignore-errors
     (uiop:run-program
      (msvc-command (format nil "dumpbin /nologo ~A \"~A\"" switch
                            (uiop:native-namestring library)))
      :output '(:string :stripped t) :error-output nil :ignore-error-status t))))

(defun verify-built (library)
  "Prove the artifact is usable, rather than merely existing on disk."
  (let ((size (with-open-file (s library :element-type '(unsigned-byte 8))
                (file-length s))))
    (format t "~&  built ~A (~:D bytes)~%" (file-namestring library) size)
    (when (zerop size) (error "The built library is empty.")))
  (when (eq (toolchain) :msvc)
    ;; A DLL missing BUILDING_UV_SHARED links cleanly and exports NOTHING, so size alone
    ;; proves nothing on Windows: count the exports and insist the ones we bind are there.
    (let ((exports (%msvc-dumpbin library "/exports")))
      (when exports
        (let ((n (with-input-from-string (in exports)
                   (loop for line = (read-line in nil)
                         while line
                         count (search " uv_" line)))))
          (format t "~&  exports ~D uv_* symbols~%" n)
          (dolist (required '("uv_version" "uv_run" "uv_loop_size"))
            (unless (search required exports)
              (error "The built DLL does not export ~A. BUILDING_UV_SHARED missing?"
                     required))))))
    ;; The bundling claim from ADR-0011, checked rather than asserted: a /MD build would
    ;; name vcruntime140.dll here and die on a clean machine.
    (let ((deps (%msvc-dumpbin library "/dependents")))
      (when deps
        (if (search "VCRUNTIME" (string-upcase deps))
            (error "The DLL depends on the VC++ runtime -- /MT did not take effect. It would fail on a clean machine.")
            (format t "~&  self-contained: no VC++ redistributable needed~%"))))))

;;; --------------------------------------------------------------------- main

(let ((args (uiop:command-line-arguments)))
  (cond
    ((member "--where" args :test #'string=)
     (format t "~A~%" (human-path:human-path (library-path)))
     (uiop:quit 0))

    ((member "--clean" args :test #'string=)
     (format t "~&removing ~A~%" (human-path:human-path *vendor*))
     (uiop:delete-directory-tree *vendor* :validate t :if-does-not-exist :ignore)
     (uiop:quit 0))

    (t
     (let ((version (pin-field "version"))
           (sha (pin-field "sha256"))
           (url (pin-field "url"))
           (force (member "--force" args :test #'string=)))
       (unless (and version sha url)
         (format t "~&libuv.pin is missing version/sha256/url.~%")
         (uiop:quit 1))
       (format t "~&libuv ~A (~A)~%" version (platform))
       (let ((existing (probe-file (library-path))))
         (when (and existing (not force))
           (format t "~&  already built: ~A~%  (--force to rebuild)~%"
                   (human-path:human-path (library-path)))
           (uiop:quit 0)))
       (handler-case
           ;; BEFORE the fetch rather than inside the compile -- see `require-toolchain'.
           (progn
             (require-toolchain)
             (let* ((srcdir (ensure-source version url sha))
                    (library (compile-library srcdir)))
               (verify-built library)
               (format t "~&OK. aion/uv will load this in preference to any system libuv.~%")
               (uiop:quit 0)))
         (error (e)
           (format t "~&FAILED: ~A~%" e)
           (uiop:quit 1)))))))
