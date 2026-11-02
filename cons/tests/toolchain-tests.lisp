;;;; toolchain-tests.lisp --- the SBCL_HOME / stale-image diagnosis (pre-publication issue 161).
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
  ;; The entire point of pre-publication issue 161. The bare error says "Don't know how to REQUIRE SB-POSIX",
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
  ;; It still works while the old install's contribs are on disk (no :contrib-version here
  ;; says otherwise), so refusing to run would block work over a mismatch that often bites
  ;; nothing. But `--fresh` targets run
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

;;; --- contribs on disk from another SBCL (#701) ----------------------------

(test contribs-compiled-by-another-sbcl-are-fatal-and-say-why
  "#701: SBCL 2.6.9 was installed over 2.6.8, and bin/cons, built by 2.6.8, warned and carried
on, then failed at the first REQUIRE of a contrib it had not baked in. With the contribs on
disk read as 2.6.9, the finding is fatal, names both versions and the directory, and gives the
rebuild. The stale-image warning is not repeated alongside it."
  (let ((findings (cons/toolchain:diagnose
                   (%facts :dumped-image-p t :runtime-version "2.6.8" :path-version "2.6.9"
                           :contrib-version "2.6.9"
                           :contrib-directory "C:\\Program Files\\SBCL\\contrib\\"))))
    (is (equal '(:stale-contribs) (%codes findings)))
    (is (cons/toolchain:fatal-p findings))
    (let ((text (%text findings)))
      (is (search "2.6.8" text) "the version cons runs")
      (is (search "2.6.9" text) "the version the contribs came from")
      (is (search "C:\\Program Files\\SBCL\\contrib\\" text) "where they are")
      (is (search "bootstrap.lisp" text) "and the rebuild"))))

(test contribs-of-the-image-s-own-version-keep-the-warning
  "The control for the test above: the same upgrade with the old install still on disk, so the
contribs are 2.6.8. bin/cons still works, so it is the warning, not a refusal."
  (let ((findings (cons/toolchain:diagnose
                   (%facts :dumped-image-p t :runtime-version "2.6.8" :path-version "2.6.9"
                           :contrib-version "2.6.8"))))
    (is (equal '(:stale-image) (%codes findings)))
    (is (not (cons/toolchain:fatal-p findings)))))

(test no-contrib-file-is-not-a-finding
  "A shipped bin/cons on a machine with no SBCL has no contrib directory, and most targets never
need a contrib it did not bake in. No version read is not evidence of a mismatch."
  (is (null (cons/toolchain:diagnose
             (%facts :dumped-image-p t :runtime-version "2.6.8" :path-version nil
                     :contrib-version nil)))))

(test the-warning-says-the-contribs-match-only-when-it-read-a-matching-version
  "#701: the old warning said a dumped image carries its own contribs, which is true only of
the ones bootstrap.lisp baked in. The review of #1097: it may say the contribs on disk are
still its own only when it read their version and it matches. In bin/cons on macOS and Linux
it usually has no contrib directory at all, because SBCL_HOME is not exported."
  (flet ((warning-text (&rest overrides)
           (%text (cons/toolchain:diagnose
                   (apply #'%facts (append overrides
                                           (list :dumped-image-p t :runtime-version "2.6.8"
                                                 :path-version "2.6.9")))))))
    (let ((matching (warning-text :contrib-directory "/sbcl/contrib/" :contrib-version "2.6.8"))
          (no-home (warning-text :contrib-directory nil :contrib-version nil))
          (unread (warning-text :contrib-directory "/sbcl/contrib/" :contrib-version nil)))
      (is (search "still SBCL 2.6.8's" matching))
      (is (search "no SBCL home" no-home) "~A" no-home)
      (is (search "SBCL_HOME" no-home))
      (is (search "could not read" unread) "~A" unread)
      (dolist (text (list matching no-home unread))
        (is (not (search "carries its own" text))))
      (is (not (search "still SBCL" no-home)) "a version it did not read is not claimed")
      (is (not (search "still SBCL" unread)) "a version it did not read is not claimed"))))

(test fasl-header-version-reads-the-version-line
  (let ((header (format nil "#!/x/sbcl --script~%# FASL~%  compiled from \"X\"~%~A~%~C~C"
                        "  using SBCL version 2.6.9" (code-char 255) (code-char 5))))
    (is (equal "2.6.9" (cons/toolchain:fasl-header-version header))))
  (is (null (cons/toolchain:fasl-header-version "not a fasl at all")))
  (is (null (cons/toolchain:fasl-header-version "  using SBCL version 2.6.9"))
      "a header cut off before the end of the line is not read as a version"))

(defun %fasl-from-another-version (dir)
  "A real fasl compiled here, whose version is changed to one this image is not, and that
version. Returns (values PATHNAME OTHER-VERSION)."
  (let* ((source (merge-pathnames "c.lisp" dir))
         (fasl (merge-pathnames "c.fasl" dir))
         (own (lisp-implementation-version))
         (other (concatenate 'string (subseq own 0 (1- (length own)))
                             (if (char= (char own (1- (length own))) #\0) "1" "0"))))
    (ensure-directories-exist source)
    (with-open-file (out source :direction :output :if-exists :supersede)
      (write-line "(defun c701 () 1)" out))
    (let ((*error-output* (make-broadcast-stream)) (*standard-output* (make-broadcast-stream)))
      (compile-file source :output-file fasl))
    ;; Same length, so every offset in the file stays where it was.
    (let* ((bytes (with-open-file (in fasl :element-type '(unsigned-byte 8))
                    (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
                      (subseq v 0 (read-sequence v in)))))
           (from (map '(vector (unsigned-byte 8)) #'char-code own))
           (to (map '(vector (unsigned-byte 8)) #'char-code other)))
      (loop for at = (search from bytes) while at
            do (replace bytes to :start1 at))
      (with-open-file (out fasl :direction :output :if-exists :supersede
                                :element-type '(unsigned-byte 8))
        (write-sequence bytes out)))
    (values fasl other)))

(test a-fasl-from-another-version-is-read-and-recognised
  "Against a real fasl rather than a description of one: its header gives the other version,
and loading it signals the condition CONTRIB-LOAD-FAILURE-P recognises. The control is the
same fasl's header before the change, which gives this image's version."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cons-701-~36R/" (random (expt 2 40)
                                                                     (make-random-state t)))
                               (uiop:temporary-directory)))))
    (unwind-protect
         (multiple-value-bind (fasl other) (%fasl-from-another-version dir)
           (is (equal other (cons/toolchain:fasl-header-version
                             (uiop:read-file-string fasl :external-format :latin-1))))
           (is (equal other (cons/toolchain:contrib-version-in dir "c"))
               "the gatherer reads the other version from the file (review of #1097)")
           (let ((condition (handler-case (progn (load fasl) nil) (error (e) e))))
             (is (typep condition 'error) "loading another version's fasl must fail")
             (is (cons/toolchain:contrib-load-failure-p condition))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(test the-gatherer-reads-this-sbcl-s-own-fasl-as-its-own-version
  "The control for the altered fasl: one compiled here and left alone reads as this image's
version. No file, and no directory, read as no version."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cons-701-own-~36R/" (random (expt 2 40)
                                                                         (make-random-state t)))
                               (uiop:temporary-directory)))))
    (unwind-protect
         (let ((source (merge-pathnames "c.lisp" dir)))
           (ensure-directories-exist source)
           (with-open-file (out source :direction :output :if-exists :supersede)
             (write-line "(defun c701-own () 1)" out))
           (let ((*error-output* (make-broadcast-stream))
                 (*standard-output* (make-broadcast-stream)))
             (compile-file source :output-file (merge-pathnames "c.fasl" dir)))
           (is (equal (lisp-implementation-version) (cons/toolchain:contrib-version-in dir "c")))
           (is (null (cons/toolchain:contrib-version-in dir "no-such-contrib")))
           (is (null (cons/toolchain:contrib-version-in nil))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(test an-absent-contrib-is-recognised-and-other-errors-are-not
  (is (cons/toolchain:contrib-load-failure-p
       (handler-case (progn (require :cons-701-no-such-contrib) nil) (error (e) e))))
  (is (cons/toolchain:contrib-load-failure-p
       (handler-case (progn (asdf:find-system "sb-cons-701-no-such" t) nil) (error (e) e)))
      "ASDF not finding a system named like a contrib, as a :depends-on on one gives")
  (is (not (cons/toolchain:contrib-load-failure-p
            (handler-case (progn (asdf:find-system "cons-701-no-such" t) nil) (error (e) e))))
      "control: a missing system that is not named like a contrib")
  (is (not (cons/toolchain:contrib-load-failure-p (make-condition 'simple-error
                                                                  :format-control "other")))))

(test quicklisp-not-finding-a-contrib-is-recognised
  "A cons target loads through Quicklisp when it is present, and Quicklisp reports a missing
system as its own SYSTEM-NOT-FOUND. This is the condition the dumped cons met when sb-sprof's
file was absent."
  (if (not (find-package "QUICKLISP-CLIENT"))
      (skip "Quicklisp is not loaded in this image")
      (flet ((failure (name)
               (handler-case (progn (uiop:symbol-call "QUICKLISP-CLIENT" "QUICKLOAD" name
                                                      :silent t)
                                    nil)
                 (error (e) e))))
        (is (cons/toolchain:contrib-load-failure-p (failure "sb-cons-701-no-such")))
        (is (not (cons/toolchain:contrib-load-failure-p (failure "cons-701-no-such")))
            "control: a missing system that is not named like a contrib"))))

(test a-contrib-failure-during-a-target-names-the-cause
  "Item 2 of #701: when a contrib fails to load during a target, the lines printed name the
stale contribs when the facts show them, and otherwise where contribs are loaded from."
  (let ((stale (format nil "~{~A~^ ~}"
                       (cons/toolchain:contrib-failure-lines
                        (%facts :dumped-image-p t :runtime-version "2.6.8"
                                :contrib-version "2.6.9" :contrib-directory "/sbcl/contrib/")
                        "Don't know how to REQUIRE SB-SPROF.")))
        (healthy (format nil "~{~A~^ ~}"
                         (cons/toolchain:contrib-failure-lines
                          (%facts :contrib-directory "/sbcl/contrib/")
                          "Don't know how to REQUIRE SB-SPROF."))))
    (is (search "Don't know how to REQUIRE SB-SPROF." stale))
    (is (search "compiled by SBCL 2.6.9" stale))
    (is (search "/sbcl/contrib/" healthy))
    (is (search "bootstrap.lisp" healthy))
    (is (not (search "compiled by SBCL" healthy)))))

(test with-no-sbcl-home-a-contrib-failure-does-not-say-rebuild-alone
  "Review of #1097: with no SBCL home, a rebuilt bin/cons fails the same way, so the lines say
to export SBCL_HOME or to bake the contrib in. The control is the case with a contrib
directory, which suggests the rebuild."
  (let ((no-home (format nil "~{~A~^ ~}"
                         (cons/toolchain:contrib-failure-lines
                          (%facts :dumped-image-p t :contrib-directory nil :contrib-version nil)
                          "Don't know how to REQUIRE SB-SPROF.")))
        (with-home (format nil "~{~A~^ ~}"
                           (cons/toolchain:contrib-failure-lines
                            (%facts :dumped-image-p t :contrib-directory "/sbcl/contrib/")
                            "Don't know how to REQUIRE SB-SPROF."))))
    (is (search "Export SBCL_HOME" no-home) "~A" no-home)
    (is (search "SBCL_HOME is not set or has no contrib/ directory" no-home)
        "an SBCL_HOME without contrib/ is ignored by SBCL, so the lines say so: ~A" no-home)
    (is (search "add the contrib to the list bootstrap.lisp bakes in" no-home))
    (is (not (search "Export SBCL_HOME" with-home)))
    (is (search "rebuild: sbcl" with-home))))

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
    (is (member (getf facts :dumped-image-p) '(t nil)))
    ;; Only when there is a contrib directory: bin/cons with SBCL_HOME unset has none, and
    ;; reads no version (review of #1097).
    (if (getf facts :contrib-directory)
        (is (equal (lisp-implementation-version) (getf facts :contrib-version))
            "this image's own contribs, read from their header (#701)")
        (is (null (getf facts :contrib-version))
            "no contrib directory, so no version was read"))))

(test this-image-diagnoses-clean
  ;; The control on the whole feature: whatever machine this is, running the real gatherer
  ;; through the real diagnosis must be silent -- otherwise every cons command is about to
  ;; start printing at the user.
  (is (null (cons/toolchain:diagnose (cons/toolchain:facts)))))
