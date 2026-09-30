;;;; msvc.lisp --- find MSVC and run a command inside its environment (#98).
;;;;
;;;; Loaded by path by scripts/build-libuv.lisp, which compiles libuv with cl.exe, and by
;;;; scripts/build-desktop-app.lisp, which compiles the Windows launcher
;;;; (scripts/windows-launcher.c). The code was in build-libuv.lisp, which runs its build
;;;; when it is loaded, so the desktop build could not reuse it from there.
;;;; scripts/build-mbedtls.lisp still has its own copy of FIND-VSWHERE, FIND-MSVC and
;;;; MSVC-COMMAND (#410).
;;;;
;;;; cl.exe is not on PATH by default, and a script must not assume a developer prompt, so the
;;;; install is located with vswhere.exe (a fixed path under %ProgramFiles(x86)%) and a
;;;; command runs through that install's vcvarsall.bat. OURANOS_MSVC_PATH names an install
;;;; instead; see MSVC-OVERRIDE.

(require :asdf)

(defpackage #:ouranos-msvc
  (:use #:cl)
  (:export #:vcvarsall-arch #:find-vswhere #:find-msvc-via-vswhere #:msvc-override
           #:find-msvc #:msvc-command #:no-trailing-separator))

(in-package #:ouranos-msvc)

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

(defun no-trailing-separator (namestring)
  "NAMESTRING without a trailing separator: `/I\"C:\\x\\inc\\\"` would have the backslash
escape the closing quote, which is how a path with a space in it silently becomes garbage."
  (string-right-trim '(#\\ #\/) namestring))
