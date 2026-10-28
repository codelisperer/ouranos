;;;; missing-natives.lisp --- what build-desktop-app.lisp does about a native file it should carry
;;;; and cannot find (#956)
;;;;
;;;; Two files the bundle should carry used to be reported with a warning while the build went on
;;;; and exited 0: hyperion-view, the window launcher, when hyperion/hyperion-view/build.{sh,ps1}
;;;; had not been run, and on macOS a library the SBCL runtime links against that is not on the
;;;; build machine. A scripted or CI build then succeeded and shipped a bundle that fails on every
;;;; user's machine. The tree's lazily loaded libraries (libuv, mbedTLS, libgit2) and its SQLite
;;;; already stop the build (tree-natives.lisp, carry-natives.lisp).
;;;;
;;;; Now a missing file stops the build too, naming it and the command that builds it, unless
;;;; --allow-missing-natives is given for a build that deliberately does not carry it. The
;;;; decision is here, with no I/O, so scripts/tests/missing-natives.lisp checks every case.

(defpackage #:ouranos-missing-natives
  (:use #:cl)
  (:export #:decide #:allow-missing-p #:+allow-option+ #:missing-summary))

(in-package #:ouranos-missing-natives)

(defparameter +allow-option+ "--allow-missing-natives"
  "The option that lets a build go on without a native file it should carry.")

(defun allow-missing-p (argv)
  "Whether ARGV, the build's arguments, gives --allow-missing-natives."
  (and (member +allow-option+ argv :test #'string=) t))

(defun decide (&key needed present allow)
  "What to do with one native file the bundle may carry, as a keyword:

:CARRY when it is NEEDED and PRESENT; :NOT-NEEDED when it is not NEEDED, whether or not it is
there (an app that does not load hyperion/desktop opens no window, so it needs no launcher);
:REFUSE when it is NEEDED and missing; :ALLOWED-MISSING when it is NEEDED and missing and ALLOW,
from --allow-missing-natives, is true."
  (cond ((not needed) :not-needed)
        (present :carry)
        (allow :allowed-missing)
        (t :refuse)))

(defun missing-summary (missing)
  "The build's summary line about MISSING, the names of the native files it went on without, in
the order they were found: none, or how many and which, with the option that allowed it."
  (if (null missing)
      "build-desktop-app: no native file the bundle needs is missing."
      (format nil "build-desktop-app: ~D native file~:P the bundle needs ~:*~[are~;is~:;are~] missing, allowed by ~A: ~{~A~^, ~}."
              (length missing) +allow-option+ missing)))
