;;;; platform.lisp --- <os>-<arch>, spelled one way.

(in-package #:aion/platform)

(defun normalize-arch (arch)
  "One spelling per architecture, from whatever this implementation calls it.

UIOP:ARCHITECTURE returns a keyword whose name VARIES BY PLATFORM, which is the whole reason
this function exists:

    SBCL on Windows        :X64
    SBCL on Linux          :X86-64
    SBCL on Apple silicon  NIL      -- falls back to (MACHINE-TYPE), which says \"ARM64\"

A manifest's platform keys must not wobble with that. Deliberately WIDER than the set of
platforms anyone builds for: an unverified host should arrive at the allow-list below with a
NAMED key to be refused by, rather than a mystery string flowing onward into a directory name."
  (let ((a (string-downcase (string (or arch (machine-type))))))
    (cond ((member a '("x64" "x86-64" "x86_64" "amd64") :test #'string=) "x86-64")
          ((member a '("arm64" "aarch64") :test #'string=) "arm64")
          ((member a '("x86" "i386" "i686") :test #'string=) "x86")
          (t a))))

(defun host-os-name ()
  "\"windows\", \"macos\" or \"linux\" -- the OS half of a platform key."
  (cond ((uiop:os-windows-p) "windows")
        ((uiop:os-macosx-p)  "macos")
        (t                   "linux")))

(defun platform-key (&optional (arch (uiop:architecture)))
  "This host's key: \"windows-x86-64\", \"macos-arm64\", \"linux-x86-64\".

The vocabulary the update manifest is keyed on. ARCH is a parameter so the mapping can be
tested for platforms this machine is not -- otherwise two thirds of the table is asserted
rather than checked, on whichever host happens to run the suite."
  (format nil "~A-~A" (host-os-name) (normalize-arch arch)))

;;; --- who may produce a build (pre-publication issue 145) -------------------------------------------
;;;
;;; Lives here rather than in the build script because it is part of the same vocabulary: the
;;; allow-list and the key that is checked against it should not be able to drift either.

(defparameter *verified-platforms* '("linux-x86-64" "windows-x86-64" "macos-arm64")
  "The platforms that are BUILT and VERIFIED -- exactly the desktop-release matrix.

A platform key is a PROMISE, not a label: it names the bundle directory, the update manifest
keys on it, and a client matches itself against it to decide an update applies. So emitting a
key nothing has ever been built on is worse than refusing to build -- the artifact is
indistinguishable from a tested one all the way to a user's machine, and the first thing that
reports the difference is an app that does not start.")

(defun verified-platform-p (key)
  "True when KEY names a platform this project actually builds and verifies."
  (and (member key *verified-platforms* :test #'string=) t))

;;; --- where this executable lives (pre-publication issue 335) ---------------------------------------
;;;
;;; A platform fact rather than a desktop one, which is why it sits here: hyperion/desktop
;;; needs it to find its sibling launcher, and hyperion/update needs it to answer where this
;;; build is installed. Two consumers of one OS question, and ADR-0014's packaging argument
;;; rests on all of them agreeing -- "there is nothing here that can disagree with the
;;; resolver" is only true while there is one resolver.

(defun executable-directory ()
  "The directory the RUNNING executable lives in, as an absolute pathname (or NIL).

Why not (uiop:argv0): argv0 is whatever the OS handed us, which routinely carries NO
directory component (`coalton-repl.exe', not `C:/.../coalton-repl.exe'). Merging a bare name
yields a RELATIVE pathname, and in a dumped image PROBE-FILE then resolves it against
*DEFAULT-PATHNAME-DEFAULTS* -- which was baked in at BUILD time (the build machine's repo
root), not the install directory. A shipped bundle therefore never found its own sibling
launcher: verified on macOS and Windows both, where a bundled app silently used the in-tree
dev copy and, with no source tree present, would have failed outright.

sb-ext:*runtime-pathname* is the runtime's own absolute path, resolved by the C runtime at
startup -- the right question to ask. SBCL-only, which this stack already is."
  (flet ((dir-of (p)
           (when p (uiop:pathname-directory-pathname
                    (uiop:ensure-absolute-pathname p #'uiop:getcwd nil)))))
    (or (ignore-errors (dir-of sb-ext:*runtime-pathname*))
        (ignore-errors (dir-of (uiop:argv0))))))

(defun macos-app-bundle (&optional (dir (executable-directory)))
  "The `.app' DIR sits inside, or NIL when it does not sit inside one.

macOS has TWO shapes and the difference is not cosmetic. `scripts/build-desktop-app.lisp'
produces a plain bundle directory holding the image, the launcher and the carried libraries;
`scripts/build-dmg.sh' copies that directory verbatim into `Foo.app/Contents/MacOS/'
(ADR-0014: packaging is a copy, not a re-layout). Both run, and a caller asking where this
build is INSTALLED wants the `.app' in the second case -- that is the unit a user drags to
Applications and the unit an updater would replace -- and the bundle directory in the first.

Detected by ancestry rather than by a flag, because nothing writes a flag: the running image
knows only where it is. Requires BOTH trailing components -- a directory merely named
`Contents/MacOS' somewhere else is not a bundle, and `Foo.app/MacOS' is not one either."
  (when (and dir (uiop:os-macosx-p))
    (let ((parts (rest (pathname-directory (uiop:ensure-directory-pathname dir)))))
      (when (and (>= (length parts) 3)
                 (string= (first (last parts)) "MacOS")
                 (string= (first (last parts 2)) "Contents")
                 (let ((app (first (last parts 3))))
                   (and (> (length app) 4)
                        (string-equal ".app" (subseq app (- (length app) 4))))))
        (make-pathname :directory (append '(:absolute) (butlast parts 2))
                       :name nil :type nil :defaults dir)))))
