;;;; toolchain-tests.lisp --- the SBCL_HOME / stale-image diagnosis (#161).
;;;;
;;;; The interesting states are ones a working machine is not in: a runtime whose contribs
;;;; cannot be loaded, and a dumped image left behind by an upgrade. That is exactly why
;;;; CONS/TOOLCHAIN:DIAGNOSE is a pure function over a plist of facts rather than a routine
;;;; that goes and looks -- the broken cases are reachable here by describing them, without
;;;; breaking the machine running the suite, and without a test that can only ever assert
;;;; "nothing is wrong" on a tree where nothing is wrong.
;;;;
;;;; The fact-GATHERING half is checked separately and lightly: it is thin, and on a healthy
;;;; tree there is exactly one true answer it can give, which the last tests here pin.

(in-package #:cons/tests)

(def-suite toolchain :description "SBCL_HOME / contrib coherence diagnosis." :in all)
(in-suite toolchain)

(defun %facts (&rest overrides)
  "A coherent, healthy set of facts, with OVERRIDES applied -- so each test states only the
one thing it is making wrong."
  (append overrides
          (list :runtime-version "2.6.7"
                :home "/opt/homebrew/Cellar/sbcl/2.6.7/lib/sbcl"
                :home-exists t
                :contrib-available t
                :path-version "2.6.7"
                :dumped-image-p nil)))

(defun %codes (findings) (mapcar (lambda (f) (getf f :code)) findings))

(defun %text (findings)
  "All of FINDINGS' lines as one string, for asking what the user would actually read."
  (format nil "~{~A~^ ~}" (loop for f in findings append (getf f :lines))))

;;; --- the healthy case ------------------------------------------------------

(test a-coherent-toolchain-says-nothing
  ;; Silence is the whole point: this runs before every cons command, so it must be mute
  ;; unless something is actually wrong.
  (is (null (cons/toolchain:diagnose (%facts))))
  (is (not (cons/toolchain:fatal-p (cons/toolchain:diagnose (%facts))))))

(test a-matching-version-on-path-is-not-a-finding
  (is (null (cons/toolchain:diagnose (%facts :dumped-image-p t :path-version "2.6.7")))))

;;; --- the fatal case: contribs unreachable ---------------------------------

(test unloadable-contribs-are-fatal-and-name-sbcl-home-not-the-contrib
  ;; The entire point of #161. The bare error says "Don't know how to REQUIRE SB-POSIX",
  ;; which sends the reader after a missing dependency. The diagnosis must put SBCL_HOME in
  ;; front of them instead.
  (let ((findings (cons/toolchain:diagnose (%facts :contrib-available nil))))
    (is (equal '(:contribs-unavailable) (%codes findings)))
    (is (cons/toolchain:fatal-p findings))
    (let ((text (%text findings)))
      (is (search "SBCL_HOME" text) "the cause has to be named")
      (is (search "2.6.7" text) "and which runtime is complaining")
      (is (search "bootstrap.lisp" text) "and what to do about it"))))

(test the-message-distinguishes-a-missing-home-from-an-empty-one
  ;; Three genuinely different situations, three different next actions -- so they must not
  ;; collapse into one sentence.
  (let ((absent (%text (cons/toolchain:diagnose
                        (%facts :contrib-available nil :home nil :home-exists nil))))
        (gone   (%text (cons/toolchain:diagnose
                        (%facts :contrib-available nil :home "/old/sbcl" :home-exists nil))))
        (empty  (%text (cons/toolchain:diagnose
                        (%facts :contrib-available nil :home "/some/sbcl" :home-exists t)))))
    (is (search "unset" absent))
    (is (search "does not exist" gone))
    (is (search "/old/sbcl" gone) "name the path that is wrong, not just that one is")
    (is (search "no usable contribs" empty))
    (is (search "/some/sbcl" empty))))

;;; --- the quiet case: a dumped image left behind by an upgrade -------------

(test a-stale-dumped-image-warns-but-is-not-fatal
  ;; It still works -- a dumped image carries its own runtime and contribs -- so refusing to
  ;; run would block work over a mismatch that often bites nothing. But `--fresh` targets run
  ;; under the PATH sbcl, so one build can span two compilers, and that is worth saying.
  (let ((findings (cons/toolchain:diagnose
                   (%facts :dumped-image-p t :runtime-version "2.6.5" :path-version "2.6.7"))))
    (is (equal '(:stale-image) (%codes findings)))
    (is (not (cons/toolchain:fatal-p findings)) "a stale image must not stop the command")
    (let ((text (%text findings)))
      (is (search "2.6.5" text) "the version it was built by")
      (is (search "2.6.7" text) "and the one now on PATH")
      (is (search "bootstrap.lisp" text) "and the rebuild"))))

(test a-stock-sbcl-is-never-stale-however-the-versions-compare
  ;; Only a DUMPED image can be left behind: a stock sbcl is the sbcl on PATH by definition,
  ;; and reporting a mismatch there would be noise on every run under a wrapper.
  (is (null (cons/toolchain:diagnose
             (%facts :dumped-image-p nil :runtime-version "2.6.5" :path-version "2.6.7")))))

(test an-unaskable-path-is-not-a-finding
  ;; `sbcl` may simply not be on PATH -- normal for a shipped binary. Absence of an answer is
  ;; not evidence of a mismatch, and must not be reported as one.
  (is (null (cons/toolchain:diagnose
             (%facts :dumped-image-p t :path-version nil :runtime-version "2.6.5")))))

;;; --- ordering and shape ----------------------------------------------------

(test the-fatal-finding-is-reported-first
  ;; A caller showing only the head must show the one that matters.
  (let ((findings (cons/toolchain:diagnose
                   (%facts :contrib-available nil :dumped-image-p t
                           :runtime-version "2.6.5" :path-version "2.6.7"))))
    (is (= 2 (length findings)))
    (is (eq :contribs-unavailable (getf (first findings) :code)))
    (is (eq :stale-image (getf (second findings) :code)))))

(test every-finding-carries-lines-not-an-embedded-newline-string
  ;; Deliberate: a FORMAT control string continued with `~` at end of line becomes an illegal
  ;; `~<Return>` directive on a CRLF checkout (root CLAUDE.md). Lines make that unwritable,
  ;; and let the reporter own the `cons:` prefix.
  (dolist (facts (list (%facts :contrib-available nil)
                       (%facts :dumped-image-p t :runtime-version "2.6.5"
                               :path-version "2.6.7")))
    (dolist (f (cons/toolchain:diagnose facts))
      (let ((lines (getf f :lines)))
        (is (listp lines))
        (is (every #'stringp lines))
        (dolist (l lines)
          (is (null (find #\Newline l)) "a line must not contain a newline: ~S" l))))))

;;; --- reporting -------------------------------------------------------------

(test report-prefixes-every-line-and-answers-whether-it-was-fatal
  (let* ((findings (cons/toolchain:diagnose (%facts :contrib-available nil)))
         (out (make-string-output-stream))
         (fatal (cons/toolchain:report findings :stream out))
         (text (get-output-stream-string out)))
    (is (eq t fatal))
    (is (search "cons: " text))
    ;; every line is prefixed, so the block reads as one speaker
    (let ((lines (remove "" (uiop:split-string text :separator '(#\Newline)) :test #'string=)))
      (is (plusp (length lines)))
      (is (every (lambda (l) (eql 0 (search "cons: " l))) lines)))))

(test report-on-a-healthy-toolchain-prints-nothing-at-all
  (let ((out (make-string-output-stream)))
    (is (not (cons/toolchain:report (cons/toolchain:diagnose (%facts)) :stream out)))
    (is (string= "" (get-output-stream-string out)))))

;;; --- the gathering half, against this actual machine ----------------------

(test facts-describe-the-running-image
  ;; Thin, but it is the seam between the pure diagnosis and reality, so it should not be
  ;; assumed. On any machine able to run this suite, contribs load and a version exists.
  (let ((facts (cons/toolchain:facts)))
    (is (stringp (getf facts :runtime-version)))
    (is (eq t (getf facts :contrib-available))
        "the suite itself could not have loaded without contribs")
    (is (member (getf facts :dumped-image-p) '(t nil)))))

(test this-image-diagnoses-clean
  ;; The control on the whole feature: whatever machine this is, running the real gatherer
  ;; through the real diagnosis must be silent -- otherwise every cons command is about to
  ;; start printing at the user.
  (is (null (cons/toolchain:diagnose (cons/toolchain:facts)))))
