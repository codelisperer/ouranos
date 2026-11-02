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
  "True when CONTRIB is loadable. Already-present counts: bin/cons bakes the contribs listed
in bootstrap.lisp into the image, so this is true in bin/cons whatever is on disk. A contrib
it did not bake in is loaded from the SBCL installation; see %CONTRIB-VERSION (#701)."
  (handler-case (progn (require contrib) t)
    (error () nil)))

(defun fasl-header-version (header)
  "The SBCL version a fasl was compiled by, from HEADER, the first bytes of the file as text,
or NIL. SBCL writes it as a text line, `  using SBCL version 2.6.9', before the binary part."
  (let* ((marker "using SBCL version ")
         (start (search marker header)))
    (when start
      (let* ((from (+ start (length marker)))
             (end (position-if (lambda (c) (member c '(#\Newline #\Return))) header
                               :start from))
             (version (string-trim " " (subseq header from (or end (length header))))))
        (and end (plusp (length version)) version)))))

(defun %contrib-directory ()
  "The contrib directory REQUIRE loads from in this image, or NIL."
  (let ((home (ignore-errors (sb-int:sbcl-homedir-pathname))))
    (and home (merge-pathnames "contrib/" (uiop:ensure-directory-pathname home)))))

(defun %contrib-version (&optional (contrib *probe-contrib*))
  "The SBCL version that compiled CONTRIB's fasl in the contrib directory, or NIL when there is
no such file or its header cannot be read.

This is the question #701 needed. When an SBCL install is replaced in place, as the Windows
installer does and as Linux packages can, bin/cons's runtime stays the old version and the
contrib directory it loads from holds the new version's fasls. SBCL refuses a fasl from
another version, so the first REQUIRE of a contrib bin/cons did not bake in fails, as an
INVALID-FASL-VERSION or `Don't know how to REQUIRE'. Reading the header answers that without
loading anything."
  (let ((dir (%contrib-directory)))
    (when dir
      (let ((fasl (probe-file (merge-pathnames
                               (format nil "~(~A~).fasl" contrib) dir))))
        (when fasl
          (ignore-errors
           (with-open-file (in fasl :element-type '(unsigned-byte 8))
             (let* ((bytes (make-array 1024 :element-type '(unsigned-byte 8)))
                    (n (read-sequence bytes in)))
               (fasl-header-version (map 'string #'code-char (subseq bytes 0 n)))))))))))

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
          :contrib-directory (let ((d (%contrib-directory))) (and d (uiop:native-namestring d)))
          :contrib-version (%contrib-version)
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
                            contrib-directory contrib-version path-version dumped-image-p)
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
      ;; 2. The contribs on disk were compiled by another SBCL (#701). bin/cons still has the
      ;;    contribs it baked in, but loads any other from the contrib directory, and SBCL
      ;;    refuses a fasl from another version, so the first such REQUIRE fails. Only a
      ;;    version that was READ and differs counts: a shipped bin/cons on a machine with no
      ;;    SBCL has no contrib directory, and most targets never need one.
      (when (and contrib-version runtime-version
                 (not (string= contrib-version runtime-version)))
        (push (list :severity :fatal :code :stale-contribs
                    :lines
                    (list (format nil "this cons runs SBCL ~A, but the contribs in ~A were compiled by SBCL ~A."
                                  runtime-version (or contrib-directory "its contrib directory")
                                  contrib-version)
                          (format nil "The SBCL install it was built from has been replaced. SBCL ~A cannot load another version's fasls, so the first REQUIRE of a contrib it did not bake in (sb-sprof, sb-simple-streams, ...) fails."
                                  runtime-version)
                          "Rebuild: sbcl --dynamic-space-size 4096 --script bootstrap.lisp"))
              findings))
      ;; 3. The quiet one. When the old SBCL install is still on disk, an upgrade leaves
      ;;    bin/cons working, while a `--fresh` target runs under the NEW sbcl from PATH. The
      ;;    two halves of one command then disagree about the compiler. Not said when finding
      ;;    2 is, which already names the mismatch and the rebuild.
      (when (and dumped-image-p path-version runtime-version
                 (not (string= path-version runtime-version))
                 (not (find :stale-contribs findings :key (lambda (f) (getf f :code)))))
        (push (list :severity :warning :code :stale-image
                    :lines
                    (list (format nil "this cons was built by SBCL ~A, but SBCL ~A is now on PATH."
                                  runtime-version path-version)
                          "It still runs, because the contribs on disk are still its own version, but `--fresh` targets run under the PATH sbcl, so one build can span two compilers. Once that install is removed or replaced, a target needing a contrib cons did not bake in will fail."
                          "Rebuild: sbcl --dynamic-space-size 4096 --script bootstrap.lisp"))
              findings))
      ;; Worst first, so a caller showing only the head shows the one that matters.
      (stable-sort (nreverse findings) #'<
                   :key (lambda (f) (if (eq (getf f :severity) :fatal) 0 1))))))

(defun fatal-p (findings)
  "True when any finding is fatal -- i.e. the toolchain cannot work, not merely disagrees."
  (and (some (lambda (f) (eq (getf f :severity) :fatal)) findings) t))

;;; --- a contrib that fails to load during a target (#701) -------------------

(defparameter +not-found-conditions+
  '(("ASDF" "MISSING-COMPONENT" "MISSING-REQUIRES")
    ("QUICKLISP-CLIENT" "SYSTEM-NOT-FOUND" "SYSTEM-NOT-FOUND-NAME"))
  "(package type accessor) for each condition that reports a system it could not find, and
the function that returns that system's name. Quicklisp re-signals ASDF's as its own, and a
cons target loads through Quicklisp when it is present.")

(defun %missing-contrib-system-p (condition)
  "True when CONDITION reports that a system named like an SBCL contrib (sb-...) was not
found. A `:depends-on' naming a contrib whose file is absent fails this way, not through
REQUIRE (measured with a dumped cons whose contrib directory lacks sb-sprof: `System
\"sb-sprof\" not found'). The types are reached by name, since this package uses only UIOP."
  (loop for (package type accessor) in +not-found-conditions+
        for type-symbol = (and (find-package package) (find-symbol type package))
        for accessor-symbol = (and (find-package package) (find-symbol accessor package))
          thereis (and type-symbol accessor-symbol (typep condition type-symbol)
                       (let ((name (ignore-errors (funcall accessor-symbol condition))))
                         (and (stringp name)
                              (uiop:string-prefix-p "sb-" (string-downcase name)))))))

(defun contrib-load-failure-p (condition)
  "True when CONDITION is SBCL failing to load a contrib: a fasl compiled by another SBCL
version; `Don't know how to REQUIRE', which REQUIRE gives for an absent contrib file; or
ASDF not finding a system named like a contrib."
  (or (typep condition 'sb-fasl::invalid-fasl-version)
      (and (typep condition 'sb-int:extension-failure)
           (search "Don't know how to REQUIRE" (princ-to-string condition))
           t)
      (%missing-contrib-system-p condition)))

(defun contrib-failure-lines (facts condition-text)
  "The lines printed when a contrib failed to load during a target, whose error printed as
CONDITION-TEXT. A finding about the contribs, when FACTS give one, says why; otherwise the
lines name the runtime version and where the contribs came from."
  (let ((finding (find-if (lambda (f) (member (getf f :code)
                                              '(:stale-contribs :contribs-unavailable)))
                          (diagnose facts))))
    (cons (format nil "a contrib could not be loaded: ~A"
                  (substitute #\Space #\Newline condition-text))
          (if finding
              (getf finding :lines)
              (list (format nil "This cons runs SBCL ~A and loads any contrib it did not bake in from ~A."
                            (getf facts :runtime-version)
                            (or (getf facts :contrib-directory) "the SBCL installation, which it cannot find"))
                    "If SBCL was upgraded, replaced or removed since bin/cons was built, rebuild: sbcl --dynamic-space-size 4096 --script bootstrap.lisp")))))

(defun explain-contrib-failure (condition &key (stream *error-output*))
  "When CONDITION is a contrib failing to load, print why, once, and return T. Called from a
HANDLER-BIND that then declines, so the original error is still reported after this."
  (when (contrib-load-failure-p condition)
    (dolist (line (contrib-failure-lines (facts) (princ-to-string condition)))
      (format stream "~&cons: ~A~%" line))
    t))

;;; --- reporting (the effectful edge) ---------------------------------------

(defun report (findings &key (stream *error-output*))
  "Print FINDINGS as `cons:`-prefixed lines. Returns T if any was fatal."
  (dolist (f findings)
    (dolist (line (getf f :lines))
      (format stream "~&cons: ~A~%" line)))
  (fatal-p findings))

(defun check (&key (stream *error-output*) (facts (facts)))
  "Diagnose the toolchain once, print anything wrong, and return the findings.

Called early from CONS/CLI:MAIN. A fatal finding is reported but NOT quit on here: `cons
version` and `cons help` still answer on a broken toolchain, which is exactly when you want
to ask them. The caller decides what a fatal finding costs; MAIN refuses to run a build-spec
target on one (#701)."
  (let ((findings (diagnose facts)))
    (report findings :stream stream)
    findings))
