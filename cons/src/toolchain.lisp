;;;; toolchain.lisp --- is the Lisp under us the one we think it is? (pre-publication issue 161)
;;;;
;;;; When the runtime and its contrib tree disagree, the failure surfaces as:
;;;;
;;;;     Unhandled SB-INT:EXTENSION-FAILURE: Don't know how to REQUIRE SB-POSIX.
;;;;
;;;; which names a contrib, so the reader goes hunting for a missing dependency or a broken
;;;; Quicklisp. The actual cause is that contribs are found relative to SBCL_HOME, and
;;;; SBCL_HOME does not resolve. Nothing in the message says so. It is reached by ordinary
;;;; routes -- an SBCL upgrade that leaves a dumped image behind, a runtime copied out of its
;;;; install tree (which is exactly what ADR-0014's build does), a checkout whose environment
;;;; was set up for a different install -- and each time it points away from the answer.
;;;;
;;;; ONE THING MEASURED FIRST, because it decides the shape. A healthy SBCL OVERWRITES the
;;;; SBCL_HOME it was given with the home it resolves for itself:
;;;;
;;;;     $ SBCL_HOME=/nonexistent sbcl --eval '(princ (sb-posix:getenv "SBCL_HOME"))'
;;;;     /opt/homebrew/Cellar/sbcl/2.6.7/lib/sbcl
;;;;
;;;; So a "wrong" SBCL_HOME is not, by itself, the fault: SBCL ignores it whenever it can
;;;; find its own tree, and only falls back to the variable when it cannot. Comparing the
;;;; variable against the version -- the obvious implementation, and the one the issue
;;;; suggests -- would therefore report agreement in exactly the cases where SBCL had already
;;;; reconciled it, and stay silent in the case that actually breaks.
;;;;
;;;; What is diagnostic is the CAPABILITY: can a contrib be required at all? That is the
;;;; thing that fails, so that is what gets asked -- and SBCL_HOME is then reported as the
;;;; place the answer came from, rather than being used as the test.
;;;;
;;;; The diagnosis is a pure function of facts gathered elsewhere (DIAGNOSE over a plist), so
;;;; every branch is reachable from a test without breaking the machine the test runs on --
;;;; which matters here, since the fatal branch is by definition not true of a working tree.

(in-package #:cons/toolchain)

(defparameter *probe-contrib* :sb-posix
  "The contrib REQUIRE is tried on. Any would do; this is the one in the error people meet.")

;;; --- gathering the facts (the effectful half) -----------------------------

(defun %sbcl-home ()
  "SBCL_HOME as this process sees it, or NIL. Read AFTER SBCL has had its say -- see the
header: on a healthy install this is SBCL's own answer, not whatever was exported."
  (let ((h (uiop:getenv "SBCL_HOME")))
    (when (and h (plusp (length h))) h)))

(defun %contrib-available-p (&optional (contrib *probe-contrib*))
  "True when CONTRIB is loadable. Already-present counts: a dumped executable bakes its
contribs in at save time and needs no SBCL_HOME to reach them, which is why bin/cons keeps
working across an upgrade that would break a plain `sbcl --script`."
  (handler-case (progn (require contrib) t)
    (error () nil)))

(defun %dumped-image-p ()
  "True when running as a saved executable (bin/cons) rather than a stock sbcl.

SAVE-LISP-AND-DIE with :EXECUTABLE T appends the core to the runtime, so the two pathnames
become the same file; under stock sbcl they are the binary and sbcl.core separately."
  (and sb-ext:*core-pathname* sb-ext:*runtime-pathname*
       (equal (namestring sb-ext:*core-pathname*)
              (namestring sb-ext:*runtime-pathname*))))

(defun sbcl-on-path-version ()
  "The version of the `sbcl` on PATH, or NIL if it cannot be asked.

Deliberately a different question from (LISP-IMPLEMENTATION-VERSION): in bin/cons that
reports the SBCL that DUMPED the image, which an upgrade leaves behind."
  (handler-case
      (let ((out (uiop:run-program '("sbcl" "--version")
                                   :output '(:string :stripped t)
                                   :error-output nil :ignore-error-status t)))
        (let ((space (position #\Space out)))   ; "SBCL 2.6.7"
          (when space
            (let ((v (string-trim '(#\Space #\Newline #\Return) (subseq out (1+ space)))))
              (when (plusp (length v)) v)))))
    (error () nil)))

(defun facts ()
  "Everything DIAGNOSE reasons over, gathered from the live process.

Asks PATH for its version ONLY when running as a dumped image: that is the sole case the
answer can matter, and it costs a subprocess, which is not worth paying on every single
`cons` invocation to learn something already known."
  (let* ((home (%sbcl-home))
         (dumped (%dumped-image-p)))
    (list :runtime-version (lisp-implementation-version)
          :home home
          :home-exists (and home (probe-file (uiop:ensure-directory-pathname home)) t)
          :contrib-available (%contrib-available-p)
          :path-version (and dumped (sbcl-on-path-version))
          :dumped-image-p dumped)))

;;; --- the diagnosis (pure) -------------------------------------------------
;;;
;;; A finding carries its message as a LIST OF LINES rather than one embedded-newline string.
;;; That is not a style preference: a FORMAT control string continued with `~` at end of line
;;; becomes an illegal `~<Return>` directive on a CRLF checkout, which SBCL reports as a
;;; compile-time macroexpansion error (see the root CLAUDE.md). Lines also let the reporter
;;; own the `cons:` prefix instead of every message hand-repeating it.

(defun %home-clause (home home-exists)
  (cond ((null home) "SBCL_HOME is unset.")
        (home-exists (format nil "SBCL_HOME is ~A, which exists but has no usable contribs."
                             home))
        (t (format nil "SBCL_HOME is ~A, which does not exist." home))))

(defun diagnose (facts)
  "FACTS (as from FACTS) -> a list of findings, worst first.

A finding is (:severity :fatal|:warning :code <keyword> :lines <list of strings>). An empty
list means the toolchain is coherent."
  (destructuring-bind (&key runtime-version home home-exists contrib-available
                            path-version dumped-image-p)
      facts
    (let ((findings '()))
      ;; 1. The fatal one: contribs are unreachable, so anything needing one dies with a
      ;;    message naming the contrib and not the cause.
      (unless contrib-available
        (push (list :severity :fatal :code :contribs-unavailable
                    :lines
                    (list (format nil "this image is SBCL ~A, but its contribs cannot be loaded."
                                  runtime-version)
                          (%home-clause home home-exists)
                          (format nil "Contribs (~(~A~), sb-cltl2, ...) are found relative to SBCL_HOME, so nothing that needs one will start."
                                  *probe-contrib*)
                          "Re-run bootstrap.lisp, or set SBCL_HOME to the tree matching this runtime."))
              findings))
      ;; 2. The quiet one the issue also names. bin/cons is a dumped image carrying its own
      ;;    runtime and contribs, so an SBCL upgrade leaves it working but stale -- while a
      ;;    `--fresh` target runs under the NEW sbcl from PATH. The two halves of one command
      ;;    then disagree about the compiler, which is a worse thing to debug than a refusal.
      (when (and dumped-image-p path-version runtime-version
                 (not (string= path-version runtime-version)))
        (push (list :severity :warning :code :stale-image
                    :lines
                    (list (format nil "this cons was built by SBCL ~A, but SBCL ~A is now on PATH."
                                  runtime-version path-version)
                          "It still runs -- a dumped image carries its own runtime and contribs -- but `--fresh` targets run under the PATH sbcl, so one build can span two compilers."
                          "Rebuild: sbcl --dynamic-space-size 4096 --script bootstrap.lisp"))
              findings))
      ;; Worst first, so a caller showing only the head shows the one that matters.
      (stable-sort (nreverse findings) #'<
                   :key (lambda (f) (if (eq (getf f :severity) :fatal) 0 1))))))

(defun fatal-p (findings)
  "True when any finding is fatal -- i.e. the toolchain cannot work, not merely disagrees."
  (and (some (lambda (f) (eq (getf f :severity) :fatal)) findings) t))

;;; --- reporting (the effectful edge) ---------------------------------------

(defun report (findings &key (stream *error-output*))
  "Print FINDINGS as `cons:`-prefixed lines. Returns T if any was fatal."
  (dolist (f findings)
    (dolist (line (getf f :lines))
      (format stream "~&cons: ~A~%" line)))
  (fatal-p findings))

(defun check (&key (stream *error-output*) (facts (facts)))
  "Diagnose the toolchain once, print anything wrong, and return the findings.

Called early from CONS/CLI:MAIN. A fatal finding is reported but NOT quit on: `cons version`
and `cons help` still answer on a broken toolchain, which is exactly when you want to ask
them. The caller decides what a fatal finding costs."
  (let ((findings (diagnose facts)))
    (report findings :stream stream)
    findings))
