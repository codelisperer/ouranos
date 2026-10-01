;;;; tree-natives.lisp --- carry the native libraries this tree builds beside a dumped image
;;;;
;;;; Loaded by path by scripts/build-desktop-app.lisp, and by the build script of a project
;;;; that `cons init' generated, which `cons bin' runs (#513). Both dump an image that may load
;;;; libuv or mbedTLS lazily (scripts/lazy-natives.lisp), and both must put the library beside
;;;; the dumped executable, where aion/uv and aion/tls look first, or the executable works on
;;;; the machine that built it, which has the tree's vendor/ copy, and nowhere else.
;;;;
;;;; This was part of build-desktop-app.lisp, which cannot be loaded by anything else because it
;;;; ends in a dump. Moved here unchanged, except that the directory written to (*BUNDLE*), the
;;;; tree's vendor/ directory (*VENDOR*) and the name messages start with (*LABEL*) are
;;;; variables. A failure still ends the process with exit code 3, as it did there: both callers
;;;; are scripts that would otherwise dump a broken image.
;;;;
;;;;   (ouranos-tree-natives:carry-tree-natives #p"bin/" :label "build-myapp")
;;;;
;;;; does the whole sequence for a caller that has nothing else to do between the steps.

(require :asdf)

(load (merge-pathnames "lazy-natives.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(defpackage #:ouranos-tree-natives
  (:use #:cl)
  (:export #:*bundle* #:*vendor* #:*label*
           #:wake-lazy-natives #:verify-natives-will-be-carried #:carry-native-libraries
           #:release-lazy-natives #:lazy-native-sonames #:loaded-foreign-libraries
           #:carry-tree-natives))

(in-package #:ouranos-tree-natives)

(defvar *bundle* nil
  "The directory the dumped executable goes in, where the libraries are copied.")

(defvar *vendor*
  (merge-pathnames "vendor/" (uiop:pathname-parent-directory-pathname
                              (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))
  "This tree's vendor/ directory: a library under it is one this tree built, and is carried.")

(defvar *label* "build-desktop-app"
  "The name every message here starts with: the script that is running.")

(defparameter *lazy-natives* ouranos-lazy-natives:*lazy-natives*
  "The tree's lazily loaded libraries, from scripts/lazy-natives.lisp, which says what each
entry holds and why the names are strings. Named as strings and resolved at run time: this
script must keep working for an app that loads none of them.")

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
  (loop for (package loader nil nil nil build-script) in *lazy-natives*
        for fn = (%fn package loader)
        if fn
          do (handler-case (funcall fn)
               (error (e)
                 (let ((*standard-output* *error-output*))
                   (format t "~&~A: ~A:~A FAILED -- ~A~%~%" *label* package loader
                           (substitute #\Space #\Newline (princ-to-string e)))
                   (format t "This image LOADS ~A, so the app calls into that library at run~%" package)
                   (format t "time -- and the bundle cannot carry what will not resolve here.~%")
                   (format t "Shipping it would produce an artifact that works on every build~%")
                   (format t "machine and fails on every user's (ADR-0011, #72, #78).~%~%")
                   (format t "Build the library first:  sbcl --script scripts/~A~%" build-script)
                   (finish-output))
                 (sb-ext:exit :code 3)))
        else
          do (format t "~&~A: ~A is not in this image -- nothing to wake.~%" *label*
                     package)))

(defun release-lazy-natives ()
  "Close what WAKE-LAZY-NATIVES opened, before the dump. SBCL records open shared objects and
reopens them at image startup; a handle left open here points at the BUILD machine's path,
which is precisely the path the shipped app does not have. So an unloader that fails stops
the build (OURANOS-LAZY-NATIVES:RELEASE-ALL says why it is no longer ignored)."
  (handler-case (ouranos-lazy-natives:release-all *lazy-natives*)
    (ouranos-lazy-natives:release-failed (e)
      (let ((*standard-output* *error-output*))
        (format t "~&~A: ~A~%~%" *label* e)
        (format t "The library may still be open, and an image dumped now would reopen this~%")
        (format t "machine's copy when it starts on the user's machine (ADR-0013). Not dumping.~%")
        (finish-output))
      (sb-ext:exit :code 3))))

(defun %resolved-library-path (path)
  "PATH as the file it actually names, or NIL when it cannot be shown to name one here.

Each module's path variable (aion/uv's *LIBUV-PATH*, aion/tls's *PATH*) holds the CANDIDATE
STRING the tree's own search order accepted, and a bare soname is one of those candidates --
the module hands it to the OS loader, which searches its own paths and never reports where it
landed. A bare name is therefore not a path to
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
        (format t "~&~A: carried ~A under a name nothing will ask for.~%~%" *label* carried-name)
        (format t "  requested: ~A~%" (human-path:human-path path))
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
        for (package loader nil path-var nil build-script) in *lazy-natives*
        for present = (and (find-package package) (%fn package loader))
        for path = (and present path-var (%var package path-var))
        for resolved = (and path (%resolved-library-path path))
        when present do
          (cond
            ((null path)
             ;; The waker ran without error but recorded nothing. Not a case we have seen;
             ;; refusing is the safe reading, since we cannot show the library will travel.
             (let ((*standard-output* *error-output*))
               (format t "~&~A: ~A woke but recorded no library path.~%" *label* package)
               (format t "Cannot show the bundle will carry it, so refusing (pre-publication issue 325).~%"))
             (sb-ext:exit :code 3))
            ((and resolved (uiop:subpathp resolved vendor))
             (format t "~&  will carry  ~A  <- ~A~%" package (human-path:human-path path)))
            (t
             (let ((*standard-output* *error-output*))
               (format t "~&~A: ~A resolved to a SYSTEM library.~%~%" *label* package)
               (format t "  ~A~%~%" (human-path:human-path path))
               (if resolved
                   (format t "That path is outside vendor/, so CARRY-NATIVE-LIBRARIES will not copy it.~%")
                   (format t "That is a bare soname: the OS loader found a copy of its own and never~%said where, so CARRY-NATIVE-LIBRARIES has no path to copy.~%"))
               (format t "~%The bundle would ship without the library and run only on machines~%")
               (format t "that happen to have their own copy. It works on this build machine~%")
               (format t "and fails on every user's (ADR-0011, #72, #78).~%~%")
               (format t "Build the vendored library first:~%")
               (format t "  sbcl --script scripts/~A~%" build-script)
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
        (format t "~&~A: no other foreign libraries are open -- none of this tree's to carry.~%" *label*)
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
                   (format t "~&  carry     ~A  <- ~A~%" (file-namestring dst) (human-path:human-path truename))
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
                 (format t "~&  system    ~A (~A) -- not carried; if the app ships it, pass --carry with that path~%" name (human-path:human-path truename)))
                (t
                 (format t "~&  system    ~A -- resolved by the OS loader, not carried~%"
                         name)))))))
    (format t "~&~A: ~D of this tree's native librar~:@P carried into the bundle.~%" *label* carried)
    (release-lazy-natives)))

(defun carry-tree-natives (bundle &key (label *label*))
  "Wake, check and carry this tree's lazily loaded libraries into BUNDLE, then close them, and
set aion/platform:*search-source-tree* to NIL when aion/platform is loaded, so the dumped image
looks for them beside itself and not in the tree it was built from (#499). Ends the process with
exit code 3, naming the problem, if the image loads one that cannot be carried. Call it last
before the dump."
  (let ((*bundle* (uiop:ensure-directory-pathname bundle))
        (*label* label))
    (ensure-directories-exist *bundle*)
    (wake-lazy-natives)
    (verify-natives-will-be-carried)
    (carry-native-libraries))
  (let ((search (and (find-package "AION/PLATFORM")
                     (find-symbol "*SEARCH-SOURCE-TREE*" "AION/PLATFORM"))))
    (when search (setf (symbol-value search) nil))))
