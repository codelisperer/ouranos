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

(require :asdf)

(defpackage #:ouranos-dump
  (:use #:cl)
  (:export #:dump-executable))

(in-package #:ouranos-dump)

(defun dump-executable (path entry)
  "Dump this image to PATH as an executable that calls ENTRY, a function designator, when it
starts. Does not return: `save-lisp-and-die' ends this process.

UIOP's dump hook runs first, and the new image runs UIOP's restore hook before ENTRY, so the
executable takes its temporary directory, its fasl cache and ASDF's configuration from the
environment it runs in rather than the one it was dumped in."
  (uiop:call-image-dump-hook)
  (sb-ext:save-lisp-and-die
   path
   :toplevel (lambda ()
               (uiop:call-image-restore-hook)
               (funcall entry))
   :executable t
   :save-runtime-options t))
