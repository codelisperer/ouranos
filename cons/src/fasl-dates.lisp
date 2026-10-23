;;;; fasl-dates.lisp --- a fasl dated the same second as its source is compiled again (#573).
;;;;
;;;; ASDF keeps a fasl when its write date is equal to or later than its source's
;;;; (COMPUTE-ACTION-STAMP compares with STAMP<=). FILE-WRITE-DATE has a resolution of one
;;;; second on every operating system this tree runs on, so a source file rewritten within the
;;;; second after its last compile has the same date as its fasl, and ASDF loads the previous
;;;; code with no error and no warning. A build then ships that code. Measured with plain ASDF on
;;;; Linux, macOS and Windows; see #573.
;;;;
;;;; This is its own system, with no dependency beyond ASDF, so that every entry point that
;;;; compiles can load it first: bootstrap.lisp, and so the bin/cons image; the cons loader; the
;;;; generated apps' build scripts, which find the tree through cons/env; build-desktop-app.lisp;
;;;; and the gate. cons/tests/fasl-dates-tests.lisp checks that each of them does.

(cl:defpackage #:cons/fasl-dates
  (:use #:cl)
  (:documentation
   "Makes ASDF compile a Lisp source file again when its fasl has the same write date as the
    source, instead of loading that fasl (#573). Loading this system is all an entry point does
    with it.")
  (:export #:same-second-p #:*wait-for-a-later-second*))

(in-package #:cons/fasl-dates)

(defun same-second-p (operation component)
  "True when COMPONENT's source file and the first output file of OPERATION on it both exist
and have the same write date."
  (let ((source (ignore-errors (file-write-date (asdf:component-pathname component))))
        (output (let ((file (first (asdf:output-files operation component))))
                  (and file (ignore-errors (file-write-date file))))))
    (and source output (= source output))))

(defvar *wait-for-a-later-second* t
  "When true, a compile of a source file written in the current second waits until the clock has
passed that second, so the fasl it writes is dated after its source. With NIL, such a fasl can
have its source's date, and the method below then compiles the file again on the next load.")

(defun %wait-past (date)
  "Return once the clock has passed DATE, a universal time, when DATE is the current second or
the next one, so that a fasl written afterwards is dated after DATE. That takes up to about one
second when DATE is the current second, and up to about two when it is the next one. A source
dated further in the future, from clock skew or an archive, is not waited for: the wait would be
as long as the skew."
  (when (<= 0 (- date (get-universal-time)) 1)
    (loop while (<= (get-universal-time) date)
          do (sleep 0.05))))

(defmethod asdf:operation-done-p :around ((operation asdf:compile-op)
                                          (component asdf:cl-source-file))
  "A compile is not done when the fasl has the same write date as its source (#573). The source
may have been rewritten in the second after the fasl was written, and the dates cannot tell.

The PERFORM method below makes the fasl a compile writes dated after its source, so a file is
compiled at most once more because of this method.

This applies to every CL-SOURCE-FILE compiled in this image once the system is loaded, Quicklisp
libraries included, not only to this tree's and the app's own files. That is acceptable for two
reasons. A file is compiled again only when its dates are equal, and the new fasl's date then
differs. And a library from Quicklisp is unpacked once and then not written, so its fasls are
dated later than its sources, and the method does nothing for it.

Only the file's own source and its own fasl are compared. Comparing a fasl with the fasls of the
files it depends on, which ASDF also does, would compile again every file that was compiled in
the same second as one it depends on, which is most files of a system."
  (and (call-next-method)
       (not (same-second-p operation component))))

(defmethod asdf:perform :before ((operation asdf:compile-op) (component asdf:cl-source-file))
  "Before compiling a source file written in the current second, wait until the clock has passed
that second (*WAIT-FOR-A-LATER-SECOND*), at most one second. The fasl is then dated after its
source. Without the wait, a fasl written in the same second as its source has its date, and every
load in that second compiles it again (Copilot's review of #657). A file written earlier, which is
nearly every file, is compiled with no wait."
  (when *wait-for-a-later-second*
    (let ((source (ignore-errors (file-write-date (asdf:component-pathname component)))))
      (when source (%wait-past source)))))
