;;;; outdated-tests.lisp --- ouranos.pin and `cons outdated' (#716, point 4)
;;;;
;;;; The framework is a fixture repository made here, with tags v0.1.0 and v0.2.0, because the
;;;; release a pin records comes from `git describe --tags', and a CI checkout has no tags.
;;;; CONS/OURANOS-PIN:*FRAMEWORK* points the code at it.

(in-package #:cons/tests)

(def-suite outdated :description "ouranos.pin and cons outdated (#716)." :in all)
(in-suite outdated)

(defparameter +fixture-changelog+
  '("# Changelog" ""
    "## Unreleased" "" "### An app may have to act" "" "- **unreleased change** text" ""
    "## v0.2.0 — 2026-11-01" "" "### An app may have to act" ""
    "- **a title that runs onto" "  a second line** and then text." ""
    "### Fixed" "" "- **not an act entry** text" ""
    "## v0.1.0 — 2026-10-01" "" "### An app may have to act" "" "- **old change** text" ""))

(defun %write-lines (path lines)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede :external-format :utf-8)
    (format s "~{~A~%~}" lines)))

(defun %fixture-framework (dir)
  "A git repository in DIR with a CHANGELOG and tags v0.1.0 and v0.2.0, HEAD at v0.2.0.
Returns DIR."
  (%git! (list "init" "-q" (uiop:native-namestring dir)))
  (%git! '("config" "user.email" "fixture@example.invalid") :dir dir)
  (%git! '("config" "user.name" "fixture") :dir dir)
  (%write-lines (merge-pathnames "CHANGELOG.md" dir) +fixture-changelog+)
  (%git! '("add" "CHANGELOG.md") :dir dir)
  (%git! '("commit" "-q" "-m" "one") :dir dir)
  (%git! '("tag" "v0.1.0") :dir dir)
  (%write-lines (merge-pathnames "README" dir) '("two"))
  (%git! '("add" "README") :dir dir)
  (%git! '("commit" "-q" "-m" "two") :dir dir)
  (%git! '("tag" "v0.2.0") :dir dir)
  dir)

(defun %head (dir)
  (uiop:run-program (list "git" "-C" (uiop:native-namestring dir) "rev-parse" "HEAD")
                    :output '(:string :stripped t)))

;;; --- the pure parts --------------------------------------------------------------------------

(test release-order
  (is-true (cons/outdated-command:release< "v0.1.6" "v0.1.7"))
  (is-true (cons/outdated-command:release< "v0.1.9" "v0.1.10"))
  (is-false (cons/outdated-command:release< "v0.1.7" "v0.1.7")))

(test act-entries-are-those-after-the-pinned-release
  (let ((after-0.1.0 (cons/outdated-command:act-entries-after +fixture-changelog+ "v0.1.0")))
    (is (= 1 (length after-0.1.0)) "one release after v0.1.0: ~S" after-0.1.0)
    (is (search "v0.2.0" (car (first after-0.1.0))))
    (is (equal '("a title that runs onto a second line") (cdr (first after-0.1.0)))
        "the title is joined across its two lines, and the Fixed entry is left out: ~S" after-0.1.0))
  (is (null (cons/outdated-command:act-entries-after +fixture-changelog+ "v0.2.0"))
      "nothing is newer than the newest release")
  (is (null (cons/outdated-command:act-entries-after +fixture-changelog+ "v0.1.0" :until "v0.1.0")))
  (is (equal '("unreleased change")
             (cdr (assoc "Unreleased"
                         (cons/outdated-command:act-entries-after +fixture-changelog+ "v0.2.0" :unreleased t)
                         :test #'string=)))))

(test exit-code-is-1-only-under-strict-with-a-gap
  (let ((clean '(("s" (:current . "x") (:note . "y"))))
        (gap '(("s" (:current . "x") (:unknown . "no pin")))))
    (is (= 0 (cons/outdated-command:exit-code clean nil)))
    (is (= 0 (cons/outdated-command:exit-code clean t)) "a note is never a gap")
    (is (= 0 (cons/outdated-command:exit-code gap nil)) "a gap is only reported without --strict")
    (is (= 1 (cons/outdated-command:exit-code gap t)))))

;;; --- ouranos.pin ------------------------------------------------------------------------------

(test a-pin-reads-back-what-was-written
  (with-temp-dir (app)
    (%write-lines (merge-pathnames "ouranos.pin" app)
                  (list (cons/ouranos-pin:pin-text "v0.1.7" "abc123")))
    (multiple-value-bind (release commit) (cons/ouranos-pin:read-ouranos-pin app)
      (is (equal "v0.1.7" release))
      (is (equal "abc123" commit)))))

(test the-pin-names-the-framework-release-and-is-never-overwritten
  (with-temp-dir (framework)
    (with-temp-dir (app)
      (%fixture-framework framework)
      (let ((cons/ouranos-pin:*framework* framework))
        (is (eq :created (cons/ouranos-pin:write-ouranos-pin app)))
        (multiple-value-bind (release commit) (cons/ouranos-pin:read-ouranos-pin app)
          (is (equal "v0.2.0" release))
          (is (equal (%head framework) commit)))
        (let ((before (uiop:read-file-string (merge-pathnames "ouranos.pin" app))))
          (is (eq :exists (cons/ouranos-pin:write-ouranos-pin app)))
          (is (string= before (uiop:read-file-string (merge-pathnames "ouranos.pin" app)))))))))

(test no-pin-is-written-when-the-framework-is-not-a-repository
  (with-temp-dir (not-a-repo)
    (with-temp-dir (app)
      (let ((cons/ouranos-pin:*framework* not-a-repo))
        (is (eq :unknown (cons/ouranos-pin:write-ouranos-pin app)))
        (is (null (probe-file (merge-pathnames "ouranos.pin" app))))))))

(test conform-adds-a-missing-pin-and-keeps-an-existing-one-even-with-force
  (with-temp-dir (framework)
    (%fixture-framework framework)
    (let ((cons/ouranos-pin:*framework* framework))
      (with-temp-dir (app)
        (cons/conform:install-conformance app :tools '(:codex))
        (is (equal "v0.2.0" (cons/ouranos-pin:read-ouranos-pin app)) "conform wrote the missing pin"))
      (with-temp-dir (app)
        (%write-lines (merge-pathnames "ouranos.pin" app) '("release v0.0.1" "commit  feedface"))
        (cons/conform:install-conformance app :tools '(:codex) :force t)
        (is (equal "v0.0.1" (cons/ouranos-pin:read-ouranos-pin app))
            "--force refreshes the pack, not the release the app recorded")))))

;;; --- cons outdated's framework section --------------------------------------------------------

(test an-app-with-no-pin-is-reported-unknown
  (with-temp-dir (framework)
    (with-temp-dir (app)
      (%fixture-framework framework)
      (let ((lines (cons/outdated-command:pin-gaps app framework)))
        (is (eq :unknown (car (first lines))) "~S" lines)
        (is (search "cons conform" (cdr (first lines))) "it says how to add the file: ~S" lines)))))

(test an-app-made-from-an-older-release-is-behind-with-the-entries-to-read
  (with-temp-dir (framework)
    (with-temp-dir (app)
      (%fixture-framework framework)
      (%write-lines (merge-pathnames "ouranos.pin" app) (list "release v0.1.0" (format nil "commit  ~A" (%head framework))))
      (let* ((lines (cons/outdated-command:pin-gaps app framework))
             (text (format nil "~{~A~%~}" (mapcar #'cdr lines))))
        (is (eq :behind (car (first lines))) "~S" lines)
        (is (search "v0.2.0" (cdr (first lines))))
        (is (search "a title that runs onto a second line" text) "~A" text)
        (is (not (find :differs lines :key #'car)) "the pinned commit is the checkout's: ~S" lines)))))

(test an-app-at-the-newest-release-and-commit-is-current
  (with-temp-dir (framework)
    (with-temp-dir (app)
      (%fixture-framework framework)
      (%write-lines (merge-pathnames "ouranos.pin" app) (list "release v0.2.0" (format nil "commit  ~A" (%head framework))))
      (let ((lines (cons/outdated-command:pin-gaps app framework)))
        (is (eq :current (car (first lines))) "~S" lines)
        (is (notany (lambda (l) (member (car l) '(:behind :unknown :differs))) lines) "~S" lines)))))

;;; --- cons outdated's app-pins section ---------------------------------------------------------

(test an-app-with-an-empty-or-no-upstream-sexp-has-only-a-note
  (with-temp-dir (app)
    (is (equal '(:note) (mapcar #'car (cons/outdated-command:app-pin-gaps app))))
    (%write-lines (merge-pathnames "upstream.sexp" app) '(";; nothing yet"))
    (is (equal '(:note) (mapcar #'car (cons/outdated-command:app-pin-gaps app))))))

(test an-app-upstream-sexp-entry-that-finds-no-pin-is-a-problem
  (with-temp-dir (app)
    (%write-lines (merge-pathnames "upstream.sexp" app)
                  '("(:name \"gone\" :category :native :where ((:field \"missing.pin\" \"version\")) :upstream (:manual \"https://example.org\") :reviewed \"2026-11-24\")"))
    (let ((lines (cons/outdated-command:app-pin-gaps app)))
      (is (find :problem lines :key #'car) "~S" lines))))
