;;;; build-desktop-app.lisp --- dump a Hyperion desktop app to a native binary.
;;;;
;;;;     sbcl --dynamic-space-size 4096 --script scripts/build-desktop-app.lisp \
;;;;          --system hyperion/examples/coalton-repl \
;;;;          --entry  hyperion/examples/coalton-repl:main \
;;;;          --name   coalton-repl \
;;;;          --version 0.1.0 \
;;;;          [--out dist] [--icon path/to/app.ico]
;;;;
;;;; --icon is used on Windows only: see "Windows: the executable's icon" below.
;;;;
;;;; The command is IDENTICAL on Linux / macOS / Windows -- which is the whole point:
;;;; SBCL cannot cross-compile (save-lisp-and-die dumps an image for the HOST platform
;;;; only), so every OS builds its own on a native CI runner, and the only way that stays
;;;; maintainable is if the three runners invoke exactly the same thing.
;;;; See hyperion/docs/desktop-distribution-design.md and ADR-0010.
;;;;
;;;; Output: <out>/<name>-<version>-<os>-<arch>/ containing the dumped image, the native
;;;; hyperion-view beside it (where hyperion/desktop:default-launcher looks), and a
;;;; VERSION file. That directory is what the per-OS installer packages.
;;;;
;;;; This is scripting, not framework: `cons desktop build` absorbs it (ADR-0007).

(require :asdf)

;;; --- argv -------------------------------------------------------------------
(defun argv-value (name &optional default)
  (let ((tail (member name (rest sb-ext:*posix-argv*) :test #'string=)))
    (or (second tail) default)))

(defparameter *system*  (or (argv-value "--system")  (error "build-desktop-app: --system is required")))
(defparameter *entry*   (or (argv-value "--entry")   (error "build-desktop-app: --entry is required")))
(defparameter *name*    (or (argv-value "--name")    (error "build-desktop-app: --name is required")))
(defparameter *version* (or (argv-value "--version") "0.0.0"))
(defparameter *out*     (argv-value "--out" "dist"))

;; The repo root -- the PARENT of scripts/. NB: pathname-directory-pathname is idempotent
;; on a directory, so applying it twice does NOT go up a level; parent-directory-pathname does.
(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

;;; --- macOS: the runtime's OWN linked libraries (ADR-0014) -----------------------
;;;
;;; ADR-0013 covers libraries the IMAGE opens with dlopen: they are resolved in Lisp, by
;;; absolute path, from beside the running image. It states that macOS needs no
;;; `install_name_tool`, and for that class it is right.
;;;
;;; It does not cover the libraries the SBCL RUNTIME ITSELF is linked against. A Homebrew
;;; SBCL carries `LC_LOAD_DYLIB /opt/homebrew/opt/zstd/lib/libzstd.1.dylib` (zstd, for core
;;; compression), and `save-lisp-and-die` prepends that runtime verbatim -- so every image
;;; we dump inherits a hard dependency on a Homebrew path. It is not weak and not lazy:
;;; dyld resolves it at process start, so a Mac without Homebrew zstd never reaches `main`.
;;; Invisible on any developer's Mac, which is exactly the shape of the libev bug.
;;;
;;; The obvious fix does not work. `install_name_tool` REFUSES a dumped image --
;;; "the __LINKEDIT segment does not cover the end of the file" -- because
;;; save-lisp-and-die appends the Lisp core past the end of the Mach-O. Nor does binding
;;; `sb-ext:*runtime-pathname*`: that is a Lisp special, while the prepended bytes come
;;; from the C runtime's own path.
;;;
;;; So we patch the runtime that PERFORMS the dump, before it dumps. A bare runtime is an
;;; ordinary Mach-O, so `install_name_tool` accepts it; the image then inherits
;;; `@executable_path/<lib>` and finds the copy we carry beside it. Verified in both
;;; directions: with the dylib present it runs, and with it removed dyld reports
;;; `Library not loaded: @executable_path/libzstd.1.dylib`.
;;;
;;; `install_name_tool`/`otool`/`codesign` are Xcode Command Line Tools -- the platform's
;;; own first-party toolchain, which the house rule allows on the BUILD path (it excludes
;;; third-party build drivers like patchelf, and anything on the LOAD path).

(defun run-capturing (program &rest args)
  "PROGRAM's stdout as a string, or NIL if it cannot be run."
  (handler-case
      (uiop:run-program (cons program args) :output :string :error-output nil)
    (error () nil)))

(defun non-system-linked-libraries (binary)
  "Absolute paths of BINARY's LC_LOAD_DYLIB entries that are not OS-provided.
/usr/lib and /System are present on every Mac by definition (and live in the dyld shared
cache); anything else came from the machine that built this SBCL and will not be there."
  (let ((out (run-capturing "otool" "-L" (namestring binary)))
        (found '()))
    (when out
      (with-input-from-string (in out)
        (read-line in nil)                      ; the file's own name
        (loop for line = (read-line in nil)
              while line
              do (let* ((trimmed (string-trim '(#\Space #\Tab #\Return) line))
                        (space (position #\Space trimmed))
                        (path (subseq trimmed 0 (or space (length trimmed)))))
                   (when (and (plusp (length path))
                              (eql #\/ (char path 0))
                              (not (uiop:string-prefix-p "/usr/lib/" path))
                              (not (uiop:string-prefix-p "/System/" path)))
                     (pushnew path found :test #'string=))))))
    (nreverse found)))

(defun patch-runtime (runtime dependencies target)
  "Copy RUNTIME to TARGET with each of DEPENDENCIES repointed at @executable_path, and
re-sign it. Returns TARGET, or NIL if any step failed.

Re-signing is not optional on Apple silicon: install_name_tool invalidates the signature,
and macOS refuses to execute an arm64 binary whose signature does not verify. Ad-hoc
(`-s -`) is what SBCL itself ships with."
  (ensure-directories-exist target)
  (when (probe-file target) (delete-file target))
  (uiop:copy-file runtime target)
  ;; copy-file carries neither the write bit (install_name_tool needs it) nor the execute
  ;; bit (we are about to run this thing).
  (uiop:run-program (list "chmod" "u+wx" (namestring target)) :ignore-error-status t)
  (handler-case
      (progn
        (dolist (dep dependencies)
          (uiop:run-program (list "install_name_tool" "-change" dep
                                  (format nil "@executable_path/~A" (file-namestring dep))
                                  (namestring target))
                            :error-output nil))
        (uiop:run-program (list "codesign" "--force" "--sign" "-" (namestring target))
                          :error-output nil)
        ;; The patched runtime now resolves these against ITS OWN directory, and we are
        ;; about to execute it -- so they have to sit beside it here too, not only in the
        ;; finished bundle.
        (dolist (dep dependencies)
          (let ((source (probe-file dep)))          ; resolve the symlink, keep its name
            (when source
              (uiop:copy-file source (merge-pathnames (file-namestring dep) target)))))
        target)
    (error (e)
      (warn "build-desktop-app: could not patch the runtime (~A); the image will keep its build-machine library paths." (type-of e))
      nil)))

;;; THE PATCHED RUNTIME IS A BUILD INTERMEDIATE (#270). Both re-runs below, macOS's for linked
;;; libraries and Windows's for the icon, build under a copy of the runtime in <out>/.runtime.
;;; The dump copies that runtime INTO the image, so nothing reads the copy once the child has
;;; exited. Left in <out> it rode along in every release artifact, which uploads all of dist/
;;; (2,404,352 bytes on Windows), and in any dist/ someone packaged by hand. So the parent
;;; removes it after the child exits, whatever the child's result.
(defun %remove-patched-runtime (patched)
  "Delete the .runtime directory holding PATCHED. A failure is reported, not raised: the build
itself already finished, and its exit code is what the caller returns."
  (let ((dir (uiop:pathname-directory-pathname patched)))
    (handler-case
        (progn
          (uiop:delete-directory-tree dir :if-does-not-exist :ignore
                                          :validate (lambda (d) (equal ".runtime" (car (last (pathname-directory d))))))
          (format t "~&build-desktop-app: removed the patched runtime (~A)~%" (uiop:native-namestring dir)))
      (error (e)
        (format t "~&build-desktop-app: could not remove the patched runtime ~A (~A); delete it before packaging ~A~%"
                (uiop:native-namestring dir) e *out*)))
    (finish-output)))

;;; --- the heap this bundle is born with (pre-publication issue 88) ---------------------------------
;;;
;;; A SHIPPED artifact, which is what makes this worse here than in bootstrap.lisp. The
;;; dumped app inherits the heap of the process that dumped it and cannot be given another
;;; afterwards, so every user of every bundle gets whatever heap CI happened to invoke SBCL
;;; with -- permanently, and with nothing about the artifact announcing it.
;;;
;;; desktop-release.yml passes --dynamic-space-size 4096 today, and an audit of the shipped
;;; macOS bundles confirmed 4096 MB in all three. So this is not a defect being fixed; it is
;;; a dependency on a flag in a workflow file that nobody checks. Drop it from that file and
;;; every published app silently gets 1 GB.
;;;
;;; DELIBERATELY BEFORE the patched-runtime re-exec below. That path already passes the
;;; right heap to its child, so macOS was incidentally covered while Windows and Linux --
;;; where *runtime-linked-deps* is empty and no re-exec happens -- were not. Running the
;;; heap guard first also means the expensive Coalton compile still happens exactly once, in
;;; whichever child ends up doing the work.
(load (merge-pathnames "heap-guard.lisp"
                       (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(ouranos-heap:ensure-heap (or *load-truename* *load-pathname*)
                          :reexec-var "OURANOS_DESKTOP_REEXEC"
                          :what "the app bundle")

;;; Set in the re-exec'd child so it does not patch and re-exec again.
(defparameter *patched-runtime-p* (uiop:getenv "OURANOS_PATCHED_RUNTIME"))

(defparameter *runtime-linked-deps*
  (when (and (uiop:os-macosx-p) (not *patched-runtime-p*))
    (non-system-linked-libraries sb-ext:*runtime-pathname*)))

(when *runtime-linked-deps*
  ;; Re-exec the whole build under a patched runtime. This happens BEFORE the system is
  ;; loaded, so the expensive Coalton compile runs exactly once, in the child.
  (let* ((patched (merge-pathnames (format nil "~A/.runtime/sbcl" *out*) *root*))
         (core (namestring sb-ext:*core-pathname*))
         (home (uiop:pathname-directory-pathname sb-ext:*core-pathname*)))
    (format t "~&build-desktop-app: the SBCL runtime links ~D non-system librar~:@P:~%"
            (length *runtime-linked-deps*))
    (dolist (d *runtime-linked-deps*) (format t "~&    ~A~%" d))
    (format t "~&build-desktop-app: re-running the build under a patched runtime so the dumped~%")
    (format t "~&                   image points at @executable_path instead (ADR-0014).~%")
    (finish-output)
    (if (patch-runtime sb-ext:*runtime-pathname* *runtime-linked-deps* patched)
        (let ((code (nth-value
                     2 (uiop:run-program
                        (append (list (namestring patched) "--core" core
                                      "--dynamic-space-size" (princ-to-string ouranos-heap:*wanted-heap-mb*)
                                      "--script" (namestring (or *load-truename* *load-pathname*)))
                                (list "--system" *system* "--entry" *entry*
                                      "--name" *name* "--version" *version* "--out" *out*))
                        :output t :error-output t :ignore-error-status t
                        ;; The child's own runtime now says @executable_path, so it cannot
                        ;; rediscover which files to carry -- it is told.
                        :environment (append (list (format nil "OURANOS_PATCHED_RUNTIME=~A" (namestring patched))
                                                   (format nil "OURANOS_CARRY_DYLIBS=~{~A~^:~}" *runtime-linked-deps*)
                                                   (format nil "SBCL_HOME=~A" (namestring home)))
                                             (remove-if (lambda (e)
                                                          (some (lambda (p) (uiop:string-prefix-p p e))
                                                                '("OURANOS_PATCHED_RUNTIME=" "OURANOS_CARRY_DYLIBS=" "SBCL_HOME=")))
                                                        (sb-ext:posix-environ)))))))
          (%remove-patched-runtime patched)
          (sb-ext:exit :code code))
        (format t "~&build-desktop-app: continuing UNPATCHED -- this bundle will not run on a Mac without those libraries.~%"))))

;;; --- Windows: the executable's icon (#72) ----------------------------------------
;;;
;;; The icon Explorer, the taskbar and shortcuts show for an .exe is a resource inside the
;;; file. It cannot be added to the dumped image: the Win32 resource-update API rewrites the
;;; file without the Lisp core that save-lisp-and-die appends after the PE, and the image
;;; then dies at start with "Can't find sbcl.core" (measured; windows-set-icon.ps1 has the
;;; numbers). So this does what the macOS block above does: put the change into a copy of
;;; the runtime and re-run the build under that copy, because the dump copies the running
;;; runtime into the image byte for byte.
;;;
;;; On Linux and macOS the icon belongs to the package rather than the binary, so
;;; build-appimage.sh and build-dmg.sh take it, and --icon here is ignored with a note.
(defparameter *icon* (argv-value "--icon"))

(when (and *icon* (not *patched-runtime-p*))
  (let ((icon (probe-file *icon*)))
    (unless icon
      (error "build-desktop-app: no such icon file: ~A" *icon*))
    (if (not (uiop:os-windows-p))
        (format t "~&build-desktop-app: --icon applies on Windows only; on this OS build-appimage.sh or build-dmg.sh sets it.~%")
        (let* ((patched (merge-pathnames (format nil "~A/.runtime/sbcl.exe" *out*) *root*))
               (helper (merge-pathnames "scripts/windows-set-icon.ps1" *root*))
               (core (namestring sb-ext:*core-pathname*))
               (home (uiop:pathname-directory-pathname sb-ext:*core-pathname*))
               (ready (handler-case
                          (progn
                            (ensure-directories-exist patched)
                            (when (probe-file patched) (delete-file patched))
                            (uiop:copy-file sb-ext:*runtime-pathname* patched)
                            (uiop:run-program (list "powershell" "-NoProfile" "-ExecutionPolicy" "Bypass"
                                                    "-File" (namestring helper)
                                                    (namestring patched) (namestring icon))
                                              :output t :error-output t)
                            t)
                        (error (e)
                          (format t "~&build-desktop-app: could not set the icon on a copy of the runtime (~A).~%" e)
                          nil))))
          (cond
            (ready
             (format t "~&build-desktop-app: re-running the build under a runtime that carries ~A,~%" (file-namestring icon))
             (format t "~&                   so the dumped image has it as its icon (#72).~%")
             (finish-output)
             (let ((code (nth-value
                     2 (uiop:run-program
                        (list (namestring patched) "--core" core
                              "--dynamic-space-size" (princ-to-string ouranos-heap:*wanted-heap-mb*)
                              "--script" (namestring (or *load-truename* *load-pathname*))
                              "--system" *system* "--entry" *entry*
                              "--name" *name* "--version" *version* "--out" *out*)
                        :output t :error-output t :ignore-error-status t
                        ;; The copy sits in <out>/.runtime, away from SBCL's own directory,
                        ;; so it is told where its contribs are.
                        :environment (append (list (format nil "OURANOS_PATCHED_RUNTIME=~A" (namestring patched))
                                                   (format nil "SBCL_HOME=~A" (namestring home)))
                                             (remove-if (lambda (e)
                                                          (some (lambda (p) (uiop:string-prefix-p p e))
                                                                '("OURANOS_PATCHED_RUNTIME=" "SBCL_HOME=")))
                                                        (sb-ext:posix-environ)))))))
               (%remove-patched-runtime patched)
               (sb-ext:exit :code code)))
            (t
             (format t "~&build-desktop-app: continuing WITHOUT an icon -- the executable will show the default one.~%")))))))


;;; --- the platform key, from the library that also serves the client (pre-publication issue 206) -------
;;;
;;; NOT DEFINED HERE. The key names the artifact this script produces and the update client
;;; looks that name up; the two must agree exactly or no update is ever delivered. When this
;;; script owned the definition, a consuming app -- which cannot load a build script -- wrote
;;; a second copy, and the two halves of one contract drifted with nothing comparing them.
;;;
;;; The naive derivation is wrong in a way that is silent and permanent: UIOP:ARCHITECTURE
;;; says :X64 on SBCL/Windows and :X86-64 on Linux, so a client computing its own key gets
;;; `windows-x64' against a manifest keyed `windows-x86-64', misses, and reports itself up
;;; to date forever.
;;;
;;; The source registry is initialised HERE, earlier than it used to be, precisely so this
;;; can be loaded before the platform guard below runs. aion/platform depends on nothing but
;;; UIOP, so it loads without Quicklisp.
;;; --- discovery + load ---------------------------------------------------------
(asdf:initialize-source-registry
 `(:source-registry (:tree ,*root*) :inherit-configuration))
(asdf:load-system "aion/platform")

;;; --- refusing an unverified platform (pre-publication issue 145) -------------------------------------
;;;
;;; THE ALLOW-LIST IS NOT DEFINED HERE ANY MORE. It lives beside the key generator, in
;;;
;;;     aion/src/platform/platform.lisp  ->  aion/platform:*verified-platforms*
;;;
;;; and that is the ONLY place to edit it. The binding below is a local alias, so the rest
;;; of this script reads as it always did; editing it HERE would move this build's answer
;;; without moving the client's, which is precisely the split pre-publication issue 206 exists to close -- the
;;; builder and the updater disagreeing about what a platform is called, silently, with the
;;; client concluding it is up to date forever.
;;;
;;; Only those keys are BUILT and VERIFIED: they are exactly the desktop-release matrix
;;; (.github/workflows/desktop-release.yml), and no other key has ever been produced by a
;;; real build. normalize-arch is deliberately WIDER than the list -- it maps every
;;; plausible spelling an unverified host might report, so such a host arrives here with a
;;; NAMED key to be refused by, rather than a mystery string that flows onward into a
;;; bundle directory name.
(defparameter *verified-platforms* aion/platform:*verified-platforms*)

;;; A platform key is a PROMISE, not a label. It names the bundle directory, it is what
;;; the update manifest keys on, and it is what a client matches itself against to decide
;;; that an update applies to it. So emitting a key we have never built on is worse than
;;; refusing to build: the artifact is indistinguishable from a tested one at every point
;;; downstream -- it packages, it is published, and it is offered as an update to real
;;; machines -- and the first thing that reports the difference is a user whose app does
;;; not start.
;;;
;;; windows-arm64 is the live case. platform-key would happily emit it, SBCL has shipped
;;; an official arm64 Windows MSI since 2.6.2, and NOTHING on that path has been run:
;;; not MSVC discovery (every vswhere query here asks for the x64 component), not libuv,
;;; not hyperion-view, not signing. CI cannot close it either -- the runners are x86-64.
;;; linux-arm64 and macos-x86-64 are in the same position and refused for the same reason.
;;;
;;; The escape hatch is for the person doing the verifying, not a way to ship past this:
;;; set OURANOS_ALLOW_UNVERIFIED_PLATFORM=1, work the checklist in pre-publication issue 145, and then
;;; MOVE THE KEY INTO *verified-platforms* so the next person does not need the override.
(defun die-unverified-platform (key)
  (let ((*standard-output* *error-output*))
    (format t "~&build-desktop-app: refusing to build for ~A -- an UNVERIFIED platform.~%~%" key)
    (format t "Verified platforms: ~{~A~^, ~}~%" *verified-platforms*)
    (format t "This host reports: (uiop:architecture) = ~S, (machine-type) = ~S~%~%"
            (uiop:architecture) (machine-type))
    (format t "Nothing on the ~A path has ever been run -- not toolchain discovery, not~%" key)
    (format t "libuv, not hyperion-view, not signing. A bundle built here would carry a~%")
    (format t "platform key that the update manifest treats exactly like a tested one.~%~%")
    (format t "If you are the one verifying it: set OURANOS_ALLOW_UNVERIFIED_PLATFORM=1,~%")
    (format t "work the checklist in pre-publication issue 145, then add ~S to *verified-platforms* in~%" key)
    (format t "scripts/build-desktop-app.lisp so the next person needs no override.~%")
    (finish-output))
  (sb-ext:exit :code 2))

;;; The override is read AFFIRMATIVELY, not for mere presence. `uiop:getenv` returns ""
;;; for a name that is exported with an empty value, and "" is true in Lisp -- so a bare
;;; `(uiop:getenv "OURANOS_ALLOW_UNVERIFIED_PLATFORM")` is switched OFF by
;;; OURANOS_ALLOW_UNVERIFIED_PLATFORM= and by =0 alike, which is the opposite of what the
;;; refusal message four lines above promises. The realistic accident is not someone
;;; typing =0: it is a CI expression or a shell that exports the name with an empty value,
;;; which is routine. This guard exists precisely to not be bypassed silently, so it
;;; accepts only what the message documents. (`uiop:getenvp` closes the empty case and is
;;; the tree's usual idiom -- see bootstrap.lisp -- but it still treats "0" as true.)
(defun env-affirmative-p (name)
  "True only for an explicit affirmative. A guard that can be switched off by an
empty string or by \"0\" is a guard that will be switched off by accident."
  (let ((v (uiop:getenv name)))
    (and v
         (member (string-downcase (string-trim " " v))
                 '("1" "true" "yes" "on")
                 :test #'string=)
         t)))

;;; Computed HERE, before the contribs and the multi-minute quickload below, so an
;;; unsupported host is told in a second rather than after the Coalton compile.
(defparameter *platform* (aion/platform:platform-key))
(defparameter *platform-verified-p*
  (aion/platform:verified-platform-p *platform*))

(unless (or *platform-verified-p* (env-affirmative-p "OURANOS_ALLOW_UNVERIFIED_PLATFORM"))
  (die-unverified-platform *platform*))

(format t "~&build-desktop-app: platform ~A~A~%" *platform*
        (if *platform-verified-p*
            ""
            " -- UNVERIFIED, OURANOS_ALLOW_UNVERIFIED_PLATFORM override in effect"))

;;; --- contribs ---------------------------------------------------------------
;;; A dumped STANDALONE executable cannot pull contribs from SBCL_HOME at runtime, so
;;; bake in everything the stack loads on demand NOW, while they are still reachable.
;;; (bootstrap.lisp does the same for bin/cons and explains the failure mode: a later
;;; in-image `(require :sb-cltl2)` fails with "System sb-cltl2 not found".) A Coalton app
;;; needs sb-cltl2 in particular, and the Coalton REPL compiles code at RUNTIME.
(dolist (contrib '(:sb-cltl2 :sb-bsd-sockets :sb-posix :sb-rotate-byte
                   :sb-md5 :sb-introspect :sb-concurrency))
  (ignore-errors (require contrib)))

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(format t "~&build-desktop-app: loading ~A (first Coalton compile takes minutes)~%" *system*)
(finish-output)
(funcall (read-from-string "ql:quickload") *system*)

;;; --- the bundle ---------------------------------------------------------------
(defparameter *bundle*
  (merge-pathnames (format nil "~A/~A-~A-~A/" *out* *name* *version* *platform*) *root*))
(ensure-directories-exist *bundle*)

;;; The native webview launcher belongs BESIDE the image -- that is the first place
;;; hyperion/desktop:default-launcher looks in a shipped app. Built separately, per OS,
;;; by hyperion/hyperion-view/build.{sh,ps1} (which CI runs before this script).
(let* ((exe (if (uiop:os-windows-p) "hyperion-view.exe" "hyperion-view"))
       (src (merge-pathnames (format nil "hyperion/hyperion-view/~A" exe) *root*))
       (dst (merge-pathnames exe *bundle*)))
  (if (probe-file src)
      (progn (uiop:copy-file src dst)
             ;; copy-file does not carry the executable bit on Unix.
             (unless (uiop:os-windows-p)
               (ignore-errors (uiop:run-program (list "chmod" "+x" (namestring dst))
                                                :ignore-error-status t)))
             (format t "~&build-desktop-app: launcher -> ~A~%" dst))
      (warn "build-desktop-app: no hyperion-view at ~A -- run hyperion/hyperion-view/build.{sh,ps1} first; the app will not open a window." src)))

;;; --- native libraries (ADR-0013) ----------------------------------------------
;;; A dumped image is self-contained Lisp, not self-contained native code: every CFFI
;;; binding resolves a shared library BY NAME on the user's machine. That is how the first
;;; Linux bundle shipped and died with `Error opening shared object "libev.so.4"`.
;;;
;;; The rule is: WE CARRY WHAT WE BUILD. A library under vendor/ was produced by this tree
;;; from a pinned source (libuv.pin), so we know its version, provenance and license -- it
;;; goes beside the binary, where the running image looks for it. Platform libraries (libc,
;;; the CRT) are present everywhere by definition. System libraries with their own packaging
;;; story -- WebKitGTK, reached by hyperion-view rather than by the image -- belong to the
;;; packaging layer (the AppImage, the .app, the installer), not in here.
;;;
;;; Everything loaded is REPORTED either way, carried or not, with the reason. "Did we bundle
;;; everything?" should be answerable by reading this log, not by shipping and waiting.

(defparameter *lazy-natives*
  '(("AION/UV/FFI" "LOAD-LIBUV" "UNLOAD-LIBUV" "*LIBUV-PATH*" "*LIBRARY-NAMES*"))
  "Foreign libraries this tree loads LAZILY, and the pair of functions that wake and release
each one. Lazy loading is deliberate (ADR-0011: binding at load time is what made a missing
library unloadable rather than merely unavailable), but it means nothing is open yet when we
come to look -- so the bundler asks each one to resolve itself, using the tree's OWN search
order rather than CFFI's, which is the only way we learn the vendored path instead of
whatever the build machine happens to have installed.

Named as strings and resolved at run time: this script must keep working for an app that
does not load aion/uv at all.")

(defun %fn (package name)
  (let* ((p (find-package package))
         (s (and p (find-symbol name p))))
    (and s (fboundp s) (fdefinition s))))

(defun %var (package name)
  "The value of PACKAGE:NAME, or NIL if the package, symbol or binding is absent."
  (let* ((p (find-package package))
         (sym (and p (find-symbol name p))))
    (and sym (boundp sym) (symbol-value sym))))

(defun wake-lazy-natives ()
  "Resolve every lazily-loaded native library, so the inventory below is real.

A FAILURE HERE IS FATAL, and it did not used to be (pre-publication issue 274). The old text said a library that
will not load \"means this build machine cannot carry it, and the report says so\" -- true,
and the wrong conclusion drawn from it. The IMAGE still needs the library: the package is
present, so something in this app loads aion/uv, so the running app WILL call into libuv and
signal on the user's machine. Dumping that bundle produces an artifact that works on every
developer box and fails on every user's -- ADR-0011's libev story verbatim, and the reason
pre-publication issue 274 exists.

THE DISTINCTION THE OLD CODE COULD NOT MAKE, and this one does: a waker whose PACKAGE IS
ABSENT is an app that does not use the library at all, and that is silence, not a warning. A
waker whose package IS present and whose library will not resolve is a bundle that must not
be built. Those are two different right answers and they shared a code path."
  (loop for (package loader nil) in *lazy-natives*
        for fn = (%fn package loader)
        if fn
          do (handler-case (funcall fn)
               (error (e)
                 (let ((*standard-output* *error-output*))
                   (format t "~&build-desktop-app: ~A:~A FAILED -- ~A~%~%" package loader
                           (substitute #\Space #\Newline (princ-to-string e)))
                   (format t "This image LOADS ~A, so the app calls into that library at run~%" package)
                   (format t "time -- and the bundle cannot carry what will not resolve here.~%")
                   (format t "Shipping it would produce an artifact that works on every build~%")
                   (format t "machine and fails on every user's (ADR-0011, #72, #78).~%~%")
                   (format t "Build the library first:  sbcl --script scripts/build-libuv.lisp~%")
                   (finish-output))
                 (sb-ext:exit :code 3)))
        else
          do (format t "~&build-desktop-app: ~A is not in this image -- nothing to wake.~%"
                     package)))

(defun release-lazy-natives ()
  "Close what WAKE-LAZY-NATIVES opened, before the dump. SBCL records open shared objects and
reopens them at image startup; a handle left open here points at the BUILD machine's path,
which is precisely the path the shipped app does not have."
  (loop for (package nil unloader) in *lazy-natives*
        for fn = (%fn package unloader)
        when fn do (ignore-errors (funcall fn))))

(defparameter *vendor* (merge-pathnames "vendor/" *root*))

(defun %resolved-library-path (path)
  "PATH as the file it actually names, or NIL when it cannot be shown to name one here.

*LIBUV-PATH* holds the CANDIDATE STRING the tree's own search order accepted, and a bare
soname is one of those candidates -- aion/uv hands it to the OS loader, which searches its
own paths and never reports where it landed. A bare name is therefore not a path to
resolve: TRUENAME merges it against the current directory and either errors (which is what
it did, taking the refusal below with it) or, worse, names a file that has nothing to do
with the library that got loaded."
  (and (or (find #\/ path) (find #\\ path))
       (ignore-errors (truename path))))

(defun lazy-native-sonames ()
  "((requested-path . (soname ...)) ...) for every lazy native this image loaded.

Read from each module's OWN exported list rather than restated here. A second copy of
`*library-names*' in this script would be a list to keep in sync with the one that decides
what the shipped app searches for -- and the copy that drifts is discovered by an app that
does not start, on a machine that is not ours (pre-publication issue 329)."
  (loop for (package loader nil path-var names-var) in *lazy-natives*
        for present = (and (find-package package) (%fn package loader))
        for path = (and present path-var (%var package path-var))
        for names = (and present names-var (%var package names-var))
        when (and path names) collect (cons path names)))

(defun verify-carried-name-is-asked-for (path carried-name)
  "Refuse a bundle that carries a library under a name nothing will look for.

OPTION C names the copy correctly; this is what makes it CHECKED rather than merely correct.
Without it the property holds because someone got it right, and the next person to touch the
naming has nothing telling them what it was for -- the failure is silent, ships, and only
shows up as an app that cannot start on a machine without its own copy."
  ;; Compare RESOLVED paths, not the values as they arrive. `path' reaches here as a
  ;; PATHNAME from CFFI and the module records its candidate as a STRING, so `equal' between
  ;; them is always false -- which made the first version of this guard match nothing and
  ;; pass everything. It looked like a working check and was inert; caught by running the
  ;; control that was supposed to trip it.
  (let* ((key (ignore-errors (truename path)))
         (expected (loop for (requested . names) in (lazy-native-sonames)
                         for r = (ignore-errors (truename requested))
                         when (and key r (equal key r)) return names)))
    (when (and expected (not (member carried-name expected :test #'string=)))
      (let ((*standard-output* *error-output*))
        (format t "~&build-desktop-app: carried ~A under a name nothing will ask for.~%~%" carried-name)
        (format t "  requested: ~A~%" path)
        (format t "  carried as: ~A~%" carried-name)
        (format t "  searched for: ~{~A~^, ~}~%~%" expected)
        (format t "The shipped app looks beside its own executable for those names. A file~%")
        (format t "under any other name is not found, the search falls through to the OS~%")
        (format t "loader, and the bundle runs only on a machine that already has its own~%")
        (format t "copy -- which is every developer's and no user's (pre-publication issue 329, ADR-0011).~%"))
      (sb-ext:exit :code 3))))

(defun verify-natives-will-be-carried ()
  "Refuse to build a bundle whose lazily-loaded libraries will not travel with it.

A SEPARATE PASS FROM WAKE-LAZY-NATIVES, and the separation is the fix rather than tidiness.
Waking asks \"does this resolve on the build machine\". Shipping asks \"will the bundle carry
it\". Those are the same question only on a host with no system copy installed -- which is
every Windows box and every CI runner we verify on, and is exactly why this hole survived
pre-publication PR 310's three-direction check and shipped (pre-publication issue 325).

What it cost: with vendor/libuv absent and Homebrew's libuv present, the waker fell through
to the bare soname, the OS loader found Homebrew's copy, CARRY-NATIVE-LIBRARIES had no path
to copy, the build exited 0, and the bundle contained no libuv at all. That artifact
runs on the machine that built it and dies everywhere else -- the outcome WAKE-LAZY-NATIVES'
own refusal message describes.

THREE OUTCOMES, not two: carried (pass), resolved outside *VENDOR* (refuse here, naming the
path), unresolvable (refused earlier by the waker).

Only *LAZY-NATIVES* entries are subject, and that is what makes the check safe: libssl and
libcrypto are legitimate system dependencies that are never carried, and they are not lazy
natives, so they never reach this pass."
  (loop with vendor = (or (ignore-errors (truename *vendor*)) *vendor*)
        for (package loader nil path-var) in *lazy-natives*
        for present = (and (find-package package) (%fn package loader))
        for path = (and present path-var (%var package path-var))
        for resolved = (and path (%resolved-library-path path))
        when present do
          (cond
            ((null path)
             ;; The waker ran without error but recorded nothing. Not a case we have seen;
             ;; refusing is the safe reading, since we cannot show the library will travel.
             (let ((*standard-output* *error-output*))
               (format t "~&build-desktop-app: ~A woke but recorded no library path.~%" package)
               (format t "Cannot show the bundle will carry it, so refusing (pre-publication issue 325).~%"))
             (sb-ext:exit :code 3))
            ((and resolved (uiop:subpathp resolved vendor))
             (format t "~&  will carry  ~A  <- ~A~%" package path))
            (t
             (let ((*standard-output* *error-output*))
               (format t "~&build-desktop-app: ~A resolved to a SYSTEM library.~%~%" package)
               (format t "  ~A~%~%" path)
               (if resolved
                   (format t "That path is outside vendor/, so CARRY-NATIVE-LIBRARIES will not copy it.~%")
                   (format t "That is a bare soname: the OS loader found a copy of its own and never~%said where, so CARRY-NATIVE-LIBRARIES has no path to copy.~%"))
               (format t "~%The bundle would ship without the library and run only on machines~%")
               (format t "that happen to have their own copy. It works on this build machine~%")
               (format t "and fails on every user's (ADR-0011, #72, #78).~%~%")
               (format t "Build the vendored library first:~%")
               (format t "  sbcl --script scripts/build-libuv.lisp~%")
               (format t "~%Then rebuild. The tree's search prefers vendor/ over the system copy,~%")
               (format t "so no other change is needed.~%"))
             (sb-ext:exit :code 3)))))

(defun loaded-foreign-libraries ()
  "((name . pathname-or-soname) ...) for every foreign library CFFI currently has open, or
NIL if this app pulled in no FFI at all."
  (let ((list-libs (%fn "CFFI" "LIST-FOREIGN-LIBRARIES"))
        (lib-path  (%fn "CFFI" "FOREIGN-LIBRARY-PATHNAME"))
        (lib-name  (%fn "CFFI" "FOREIGN-LIBRARY-NAME")))
    (when (and list-libs lib-path lib-name)
      (loop for lib in (funcall list-libs :loaded-only t)
            collect (cons (funcall lib-name lib) (funcall lib-path lib))))))

(defun vendor-package-directory (library-path)
  "vendor/<pkg>/lib/<file> -> vendor/<pkg>/ -- the vendored package a carried library came from."
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname library-path)))

(defun vendor-package-name (library-path)
  (car (last (pathname-directory (vendor-package-directory library-path)))))

(defun license-files (library-path)
  "The license texts shipped with that package. We carry the code, so we carry the license."
  (let ((pkg (vendor-package-directory library-path)))
    (append (directory (merge-pathnames "LICENSE*" pkg))
            (directory (merge-pathnames "src/*/LICENSE*" pkg)))))

(defun carry-native-libraries ()
  "Copy every vendored native library the image has open into the bundle, and report the rest.

Assumes WAKE-LAZY-NATIVES and VERIFY-NATIVES-WILL-BE-CARRIED have already run -- see the
build sequence below. It used to wake them itself, which is how the shipping check came to
be missing from a step named for waking."
  (let ((libraries (loaded-foreign-libraries))
        (carried 0))
    (if (null libraries)
        (format t "~&build-desktop-app: no foreign libraries loaded -- nothing to carry.~%")
        (dolist (lib libraries)
          (destructuring-bind (name . path) lib
            (let ((truename (and path (probe-file path))))
              (cond
                ((and truename (uiop:subpathp truename *vendor*))
                 ;; NAME FROM `path', NOT `truename' (pre-publication issue 329). PATH is what the tree's own
                 ;; search order accepted -- the name the consumer will ask for. TRUENAME is
                 ;; where the bytes live, which on a conventional install is a versioned file
                 ;; behind a soname symlink: libuv.1.dylib -> libuv.1.0.0.dylib. Naming from
                 ;; the resolved end lands the bytes under `libuv.1.0.0.dylib', a name
                 ;; aion/uv's beside-the-image search never asks for, and the shipped app
                 ;; falls through to whatever the user's machine happens to have.
                 ;;
                 ;; This makes both carry functions name from the same end, which is what
                 ;; dissolves the disagreement rather than documenting it:
                 ;; CARRY-RUNTIME-LINKED-LIBRARIES already names from the symlink because the
                 ;; load command does, and its docstring stops being an exception.
                 (let ((dst (merge-pathnames (file-namestring path) *bundle*)))
                   (uiop:copy-file truename dst)
                   (unless (uiop:os-windows-p)
                     (ignore-errors (uiop:run-program (list "chmod" "+x" (namestring dst))
                                                      :ignore-error-status t)))
                   (verify-carried-name-is-asked-for path (file-namestring dst))
                   (incf carried)
                   ;; NAME is CFFI's synthetic symbol for a library loaded by path
                   ;; (LIBUV.SO.1-459) -- true and useless. Report the files.
                   (format t "~&  carry     ~A  <- ~A~%" (file-namestring dst) truename)
                   (dolist (license (license-files truename))
                     (let ((dst (merge-pathnames
                                 (format nil "LICENSES/~A-~A"
                                         (vendor-package-name truename)
                                         (file-namestring license))
                                 *bundle*)))
                       (ensure-directories-exist dst)
                       (uiop:copy-file license dst)
                       (format t "~&            + LICENSES/~A~%" (file-namestring dst))))))
                (truename
                 (format t "~&  system    ~A (~A) -- not ours to carry~%" name truename))
                (t
                 (format t "~&  system    ~A -- resolved by the OS loader, not carried~%"
                         name)))))))
    (format t "~&build-desktop-app: ~D native librar~:@P carried into the bundle.~%" carried)
    (release-lazy-natives)))

(defun carry-runtime-linked-libraries ()
  "Copy the libraries the RUNTIME links against into the bundle (macOS, ADR-0014).

The image's load commands were rewritten to `@executable_path/<name>` before the dump, so
each file must land beside the binary under exactly the name in the load command -- which
is the SYMLINK's name (libzstd.1.dylib), while the bytes come from its target
(libzstd.1.5.7.dylib). Copying the resolved file under the resolved name would satisfy
nothing."
  (let ((spec (uiop:getenv "OURANOS_CARRY_DYLIBS")))
    (when (and spec (plusp (length spec)))
      (dolist (dep (uiop:split-string spec :separator ":"))
        (let ((source (probe-file dep)))            ; resolves the symlink
          (cond
            ((null source)
             (format t "~&  MISSING   ~A -- linked by the runtime but not on this machine~%" dep))
            (t
             (let ((dst (merge-pathnames (file-namestring dep) *bundle*)))
               (uiop:copy-file source dst)
               (uiop:run-program (list "chmod" "+x" (namestring dst)) :ignore-error-status t)
               (format t "~&  carry     ~A  <- ~A~%" (file-namestring dst) source)
               ;; Homebrew keeps the license at the formula prefix: <prefix>/lib/x.dylib
               ;; -> <prefix>/LICENSE*. We ship the code, so we ship the license.
               (let* ((prefix (uiop:pathname-parent-directory-pathname
                               (uiop:pathname-directory-pathname dep)))
                      (licenses (append (directory (merge-pathnames "LICENSE*" prefix))
                                        (directory (merge-pathnames "COPYING*" prefix)))))
                 (dolist (license licenses)
                   (let ((ldst (merge-pathnames
                                (format nil "LICENSES/~A-~A"
                                        (pathname-name (pathname (file-namestring dep)))
                                        (file-namestring license))
                                *bundle*)))
                     (ensure-directories-exist ldst)
                     (uiop:copy-file license ldst)
                     (format t "~&            + LICENSES/~A~%" (file-namestring ldst)))))))))))))

(format t "~&build-desktop-app: native libraries~%")
;; wake -> verify -> carry, each step named for the one thing it does. The verify pass is
;; separate because a step called `wake-lazy-natives' is a step about waking, and hanging
;; the shipping gate off it is how the missing check hid inside a step named for the check
;; we wanted (pre-publication issue 325).
(wake-lazy-natives)
(verify-natives-will-be-carried)
(carry-native-libraries)
(carry-runtime-linked-libraries)

;;; VERSION is what a fresh install reports before the app has ever run, and what the
;;; installer reads. The authoritative value is the one baked into the image by the app
;;; itself; this file exists for the installer's and the updater's benefit.
(with-open-file (out (merge-pathnames "VERSION" *bundle*)
                     :direction :output :if-exists :supersede :if-does-not-exist :create)
  (format out "~A~%" *version*))

;;; --- dump ---------------------------------------------------------------------
;;; :save-runtime-options t so the app's OWN argv reaches it (without it SBCL parses its
;;; runtime flags first) and the heap size in effect here is baked in.
(let ((bin (merge-pathnames (if (uiop:os-windows-p)
                                (format nil "~A.exe" *name*)
                                *name*)
                            *bundle*)))
  (format t "~&build-desktop-app: dumping ~A -> ~A~%" *entry* bin)
  (finish-output)
  (sb-ext:save-lisp-and-die
   bin
   :toplevel (fdefinition (read-from-string *entry*))
   :executable t
   :save-runtime-options t))
