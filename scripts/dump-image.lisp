;;;; dump-image.lisp --- dump an executable that reads its environment when it starts (#107)
;;;;
;;;; Loaded by path by bootstrap.lisp (for bin/cons) and scripts/build-desktop-app.lisp (for
;;;; every desktop app). Both used to call `sb-ext:save-lisp-and-die' directly, and that
;;;; froze three things at the values they had on the machine that did the dump:
;;;;
;;;;   - ASDF's output translations, so fasls went to the build machine's cache whatever
;;;;     XDG_CACHE_HOME said at run time;
;;;;   - `uiop:*user-cache*', which those translations are computed from;
;;;;   - `uiop:temporary-directory', so TEMP at run time was ignored too.
;;;;
;;;; UIOP expects an image to run two lists of hooks, and a bare `save-lisp-and-die' runs
;;;; neither. `uiop:*image-dump-hook*' (ASDF's CLEAR-CONFIGURATION) is meant to run before
;;;; the dump, so ASDF computes its configuration again the first time the new process needs
;;;; it. `uiop:*image-restore-hook*' (COMPUTE-USER-CACHE, SETUP-TEMPORARY-DIRECTORY, the
;;;; command-line arguments and the standard streams) is meant to run when the image starts.
;;;; Running only one of them is not enough: #107 measured the restore hook alone leaving
;;;; the translations pointing at the old cache, because they had already been computed.
;;;;
;;;; What it cost, measured on #107: a desktop app dumped on a machine whose TEMP was
;;;; `C:\Users\runneradmin\AppData\Local\Temp' and run by another user reported that
;;;; directory as its temporary directory, and the updater's staging step failed with
;;;; "Can't create directory C:\Users\runneradmin".
;;;;
;;;; This is `uiop:dump-image' and `uiop:restore-image' in two lines, written out rather
;;;; than called, because the dump needs `:save-runtime-options t': with it the runtime does
;;;; not parse its own flags from the command line, so every argument reaches the program,
;;;; and the heap size in effect at the dump is kept.
;;;;
;;;; DUMP-CORE is the macOS and Windows form (#98, #332): the core alone, with no runtime in
;;;; front of it, so the runtime can be signed. `:save-runtime-options' does nothing without
;;;; `:executable t' (measured again on Windows for #98), so the heap and the end of
;;;; runtime-option processing come from the launcher instead, scripts/macos-launcher.c or
;;;; scripts/windows-launcher.c, which starts the runtime with them.

(require :asdf)

(defpackage #:ouranos-dump
  (:use #:cl)
  (:export #:dump-executable #:dump-core))

(in-package #:ouranos-dump)

(defun %toplevel (entry debugger)
  "The dumped image's toplevel: unless DEBUGGER, turn SBCL's debugger off; then run UIOP's
restore hook and ENTRY.

THE DEBUGGER IS OFF UNLESS ASKED FOR (#495). With it off, an unhandled error prints its message
and a backtrace to standard error and exits with code 1. With it on, the error waits for input
at the debugger's prompt, and a desktop app on Windows, whose runtime is given the launcher's
standard input and no window, would wait there for ever. Every image this file dumped already
had the debugger off, but only because the dumping process ran with --script or
--non-interactive, which turn it off, and the dumped core keeps that setting. This makes it a
property of the dump instead of the command line. It is turned off before the restore hook, so
an error there, a library that cannot be reopened for instance, is covered too.

An image that runs SBCL's own REPL, or otherwise wants the debugger, passes :DEBUGGER T to
DUMP-EXECUTABLE or DUMP-CORE, or turns it back on with SB-EXT:ENABLE-DEBUGGER where it needs it,
as bin/cons does for its REPL targets."
  (lambda ()
    (unless debugger (sb-ext:disable-debugger))
    (uiop:call-image-restore-hook)
    (funcall entry)))

(defun dump-executable (path entry &key compression debugger)
  "Dump this image to PATH as an executable that calls ENTRY, a function designator, when it
starts. Does not return: `save-lisp-and-die' ends this process.

UIOP's dump hook runs first, and the new image runs UIOP's restore hook before ENTRY, so the
executable takes its temporary directory, its fasl cache and ASDF's configuration from the
environment it runs in rather than the one it was dumped in.

COMPRESSION, when true, is passed to `save-lisp-and-die' as :COMPRESSION, for an SBCL built
with core compression; it is not passed at all otherwise (#287).

DEBUGGER, false by default, keeps SBCL's debugger in the image; see %TOPLEVEL (#495)."
  (uiop:call-image-dump-hook)
  (apply #'sb-ext:save-lisp-and-die
         path
         :toplevel (%toplevel entry debugger)
         :executable t
         :save-runtime-options t
         (and compression (list :compression compression))))

(defun dump-core (path entry &key debugger)
  "Dump this image to PATH as a core with no runtime in it, which calls ENTRY when it starts.
Does not return. The same hooks as DUMP-EXECUTABLE, and the same DEBUGGER argument. The heap and
the command line are the launcher's to set: see this file's header."
  (uiop:call-image-dump-hook)
  (sb-ext:save-lisp-and-die
   path
   :toplevel (%toplevel entry debugger)
   :executable nil))
