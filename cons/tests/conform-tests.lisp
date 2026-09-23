;;;; conform-tests.lisp --- tests for `cons conform` (the AI-conformance pack installer).

(in-package #:cons/tests)

(def-suite conform :description "The AI-conformance pack installer." :in all)
(in-suite conform)

(defmacro with-temp-dir ((var) &body body)
  "Bind VAR to a fresh, uniquely-named temp directory pathname; remove it after."
  (let ((name (gensym)))
    `(let* ((,name (format nil "cons-conform-~A/" (symbol-name (gensym "T"))))  ; unique per call
            (,var (ensure-directories-exist
                   (merge-pathnames ,name (uiop:temporary-directory)))))
       (unwind-protect (progn ,@body)
         (uiop:delete-directory-tree ,var :validate t :if-does-not-exist :ignore)))))

(defun %exists (root rel) (probe-file (merge-pathnames rel root)))
(defun %slurp (root rel) (uiop:read-file-string (merge-pathnames rel root)))

(test installs-all-tools
  (with-temp-dir (root)
    (cons/conform:install-conformance root :name "widget" :with-claude t)
    (is (%exists root "AGENTS.md"))
    (is (%exists root ".cursor/rules/codelisperer.mdc"))
    (is (%exists root ".claude/skills/coalton-core/SKILL.md"))
    (is (%exists root ".claude/skills/mnemosyne-data/SKILL.md"))
    (is (%exists root "CLAUDE.md"))))

(test agents-md-has-the-spec
  (with-temp-dir (root)
    (cons/conform:install-conformance root)
    (let ((agents (%slurp root "AGENTS.md")))
      (is (search "dependency DAG" agents))                    ; the DAG rule
      (is (search "No IO in Coalton" agents))                  ; the core split
      (is (search "(A * B -> C)" agents))                      ; the Coalton gotcha
      (is (search "data, not macros" agents))                  ; the query convention
      (is (search "No aphorisms" agents)))))                   ; the writing rule

(test claude-md-imports-agents-and-fills-name
  (with-temp-dir (root)
    (cons/conform:install-conformance root :name "widget" :with-claude t)
    (let ((claude (%slurp root "CLAUDE.md")))
      (is (search "@AGENTS.md" claude))                        ; DRY import
      (is (search "widget" claude)))))                         ; name filled

(test tool-selection-is-respected
  (with-temp-dir (root)
    (cons/conform:install-conformance root :tools '(:codex))   ; AGENTS.md only
    (is (%exists root "AGENTS.md"))
    (is (not (%exists root ".cursor/rules/codelisperer.mdc")))
    (is (not (%exists root ".claude/skills/coalton-core/SKILL.md")))))

(test skips-existing-without-force
  (with-temp-dir (root)
    (with-open-file (s (merge-pathnames "AGENTS.md" root) :direction :output)
      (write-string "KEEP ME" s))
    (cons/conform:install-conformance root :tools '(:codex))       ; no force -> skip
    (is (string= "KEEP ME" (%slurp root "AGENTS.md")))
    (cons/conform:install-conformance root :tools '(:codex) :force t)  ; force -> overwrite
    (is (search "codelisperer" (%slurp root "AGENTS.md")))))

;;; --- the no-AI-trailer rule ------------------------------------------------
;;;
;;; This is the one house rule an agent harness actively works AGAINST: it injects the
;;; trailer and instructs the model to keep it, so a line in a document loses to the
;;; system prompt that contradicts it. The pack therefore ships a hook, and the hook is
;;; exercised in BOTH directions -- one that refuses everything and one that refuses
;;; nothing are indistinguishable if you only ever run the failing case.
;;;
;;; `uiop:os-unix-p' is a RUNTIME test on purpose. A reader conditional would be fine here,
;;; but the executable bit is checked by running `test -x' rather than by naming an
;;; sb-posix symbol, for the reason packages.lisp gives: a literal sb-posix symbol is
;;; resolved by the READER and takes the whole test system with it on a build without it.

(defun %hook-path (root) (merge-pathnames ".githooks/commit-msg" root))

(defun %run-hook (root message)
  "Run the installed commit-msg hook over MESSAGE; return its exit code."
  (let ((msg-file (merge-pathnames "COMMIT_EDITMSG" root)))
    (with-open-file (s msg-file :direction :output :if-exists :supersede
                                :if-does-not-exist :create)
      (write-string message s))
    (nth-value 2 (uiop:run-program (list (uiop:native-namestring (%hook-path root))
                                         (uiop:native-namestring msg-file))
                                   :ignore-error-status t
                                   :output nil :error-output nil))))

(test agents-md-forbids-ai-commit-trailers
  (with-temp-dir (root)
    (cons/conform:install-conformance root)
    (let ((agents (%slurp root "AGENTS.md")))
      (is (search "Co-Authored-By" agents))
      ;; The clause that makes the rule survive contact with a harness that says otherwise.
      (is (search "harness" agents))
      (is (search "even when your" agents)))))

(test the-commit-msg-hook-ships-with-the-spec-and-is-executable
  (with-temp-dir (root)
    (cons/conform:install-conformance root)
    (is (%exists root ".githooks/commit-msg"))
    (if (uiop:os-unix-p)
        (is (= 0 (nth-value 2 (uiop:run-program
                               (list "test" "-x" (uiop:native-namestring (%hook-path root)))
                               :ignore-error-status t)))
            "a hook without the executable bit is skipped by git in silence: no hook at all")
        (skip "the executable bit is a POSIX notion; Git for Windows runs hooks through sh"))))

(test the-hook-refuses-an-ai-trailer-and-passes-everything-else
  (if (not (uiop:os-unix-p))
      (skip "running the hook needs a POSIX sh and an executable bit")
      (with-temp-dir (root)
        (cons/conform:install-conformance root)
        ;; Passes: an ordinary message.
        (is (= 0 (%run-hook root (format nil "feat: a clean message~%"))))
        ;; Refuses: whatever the assistant is called, in whatever case.
        (is (= 1 (%run-hook root (format nil "feat: work~%~%Co-Authored-By: Claude <x@anthropic.com>~%"))))
        (is (= 1 (%run-hook root (format nil "fix: work~%~%co-authored-by: GPT-5 <x@openai.com>~%"))))
        ;; The `^' anchor earns its keep: prose ABOUT the rule is not a trailer.
        (is (= 0 (%run-hook root (format nil "docs: say why we add no Co-Authored-By trailer~%")))))))


;;; --- arming (#the hook that refuses nothing) --------------------------------
;;;
;;; A WRITTEN HOOK IS NOT AN ARMED HOOK. `core.hooksPath' is per-clone, is not carried by
;;; git, and defaults to `.git/hooks' -- so until it is set, `.githooks/commit-msg' is a
;;; file that reads as enforcement and refuses nothing. The installer used to PRINT the
;;; command and leave it to a human, which is how the rule broke in a satellite project
;;; while every doc in it said the right thing. These tests are about the wiring, not the
;;; text: the text was already correct when the rule broke.

(defun %git-in (root &rest args)
  "Run git in ROOT; return (values trimmed-output exit-code)."
  (let* ((out (make-string-output-stream))
         (code (nth-value 2 (uiop:run-program
                             (append (list "git" "-C" (uiop:native-namestring root)) args)
                             :output out :error-output nil :ignore-error-status t))))
    (values (string-trim '(#\Space #\Newline #\Return) (get-output-stream-string out)) code)))

(defun %init-repo (root)
  (%git-in root "init" "-q")
  root)

(defun %touch-hook (root)
  "Create .githooks/commit-msg, the precondition %ARM-HOOKS now insists on.

The installer always writes the file before arming, so a test that armed without one was
testing a call that cannot happen -- and once %ARM-HOOKS grew the guard, four of them were
asserting the old answer. The fixture has to match the real caller's order."
  (let ((path (merge-pathnames ".githooks/commit-msg" root)))
    (ensure-directories-exist path)
    (with-open-file (s path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
      (write-string "#!/bin/sh" s))
    path))

(test installing-into-a-git-repo-arms-the-hook
  ;; The control is the CONFIG, not the file: the file was always written. What changed is
  ;; whether git has been told to look at it.
  (with-temp-dir (root)
    (%init-repo root)
    (is (string= "" (%git-in root "config" "--get" "core.hooksPath"))
        "precondition: a fresh repo points at .git/hooks")
    (cons/conform:install-conformance root)
    (is (string= ".githooks" (%git-in root "config" "--get" "core.hooksPath"))
        "the installer must arm the hook, not print how to arm it")))

(test arming-is-idempotent-and-reports-which-case-it-was
  (with-temp-dir (root)
    (%touch-hook root)
    (%init-repo root)
    (is (eq :armed (cons/conform::%arm-hooks root)))
    (is (eq :already (cons/conform::%arm-hooks root)))
    (is (string= ".githooks" (%git-in root "config" "--get" "core.hooksPath")))))

(test arming-refuses-to-hijack-another-hook-manager
  ;; Another hooksPath is a decision someone made. Redirecting it would disable THEIR
  ;; guards to install ours -- a worse outcome than leaving this one unenforced and saying
  ;; so. The assertion that matters is that the existing value survives.
  (with-temp-dir (root)
    (%touch-hook root)
    (%init-repo root)
    (%git-in root "config" "core.hooksPath" ".husky")
    (multiple-value-bind (status detail) (cons/conform::%arm-hooks root)
      (is (eq :foreign status))
      (is (string= ".husky" detail)))
    (is (string= ".husky" (%git-in root "config" "--get" "core.hooksPath"))
        "the foreign value must survive untouched")))

(test arming-before-the-hook-exists-is-refused
  ;; Git does not validate core.hooksPath. Pointed at a directory that is not there it
  ;; finds no hooks, says nothing, AND stops consulting .git/hooks -- so arming early is
  ;; strictly worse than not arming: the repo reads as enforced, refuses nothing, and has
  ;; lost whatever hooks it had. The assertion that matters is the SECOND one, that the
  ;; config was not written; :NO-HOOK alone would be satisfied by a function that returned
  ;; the right keyword and armed anyway.
  (with-temp-dir (root)
    (%init-repo root)
    (is (eq :no-hook (cons/conform::%arm-hooks root)))
    (is (string= "" (%git-in root "config" "--get" "core.hooksPath"))
        "an unarmed repo must stay unarmed, not point at a directory that does not exist")))

(test arming-outside-a-repo-says-so-instead-of-claiming-success
  ;; :NO-REPO and :ARMED must not be the same silence. `cons conform' runs before `git
  ;; init' often enough that this is the common path, and a project whose installer said
  ;; nothing would carry an inert hook with no way to notice.
  (with-temp-dir (root)
    (%touch-hook root)
    (is (eq :no-repo (cons/conform::%arm-hooks root)))))

(test arming-will-not-write-to-a-parent-repository
  ;; A generated project nested inside another checkout: `git rev-parse' succeeds there and
  ;; reports the PARENT. Arming would then edit a repo this installer was never pointed at,
  ;; and would silently take over its hooks.
  (with-temp-dir (root)
    (%touch-hook root)
    (%init-repo root)
    (let ((child (ensure-directories-exist (merge-pathnames "child/" root))))
      (%touch-hook child)
      (is (eq :no-repo (cons/conform::%arm-hooks child)))
      (is (string= "" (%git-in root "config" "--get" "core.hooksPath"))
          "the parent repo's config must be untouched"))))

(test a-message-that-describes-the-rule-is-not-a-message-that-breaks-it
  ;; The footer pattern was unanchored, so the commit introducing the hook was refused by
  ;; the hook, for saying what it refuses. A guard that cannot tell description from
  ;; violation punishes exactly the people who write the documentation.
  (if (uiop:os-windows-p)
      (skip "running the hook needs a POSIX sh and an executable bit")
      (with-temp-dir (root)
        (cons/conform:install-conformance root)
        (is (= 0 (%run-hook root (format nil "docs: explain why we strip the Generated with [Claude Code] footer~%"))))
        (is (= 0 (%run-hook root (format nil "docs: a commit must not carry Co-Authored-By for an AI~%"))))
        ;; ...and the real footer, at the start of a line, still refused.
        (is (= 1 (%run-hook root (format nil "feat: work~%~%Generated with [Claude Code](https://claude.com/claude-code)~%")))))))

(test the-hook-refuses-the-harness-pull-request-boilerplate-too
  ;; The trailer is not the only thing a harness injects; it also appends a `Generated
  ;; with Claude Code' line to pull-request bodies, which lands in a commit message
  ;; whenever someone squash-merges with the PR body as the message.
  (if (uiop:os-windows-p)
      (skip "running the hook needs a POSIX sh and an executable bit")
      (with-temp-dir (root)
        (cons/conform:install-conformance root)
        (is (= 1 (%run-hook root (format nil "feat: work~%~%Generated with [Claude Code](https://claude.com/claude-code)~%"))))
        ;; Both directions: a human co-author is not an AI, and must still commit.
        (is (= 0 (%run-hook root (format nil "feat: work~%~%Co-Authored-By: Bob Calco <bob@example.com>~%")))))))

(test claude-md-stays-light-and-defers-to-agents-md
  ;; CLAUDE.md is always loaded, so it carries pointers rather than a second copy of the
  ;; spec. This is the check that catches the two files drifting back together.
  (with-temp-dir (root)
    (cons/conform:install-conformance root :name "widget" :with-claude t)
    (let ((claude (%slurp root "CLAUDE.md")))
      (is (< (count #\Newline claude) 30))
      (is (not (search "2-space indent" claude)))    ; AGENTS.md owns house style
      (is (not (search "(A * B -> C)" claude))))))   ; AGENTS.md owns the Coalton gotchas

;;; --- the data doctrine the pack teaches (pre-publication issue 353) -----------------------------
;;; The generated text told every scaffolded project to write through `insert!'. Nothing in
;;; the tree called it, because `insert!' cannot stamp entity metadata yet (#93). The
;;; maintainer ruled that the text should say what is true today. These assert the generated
;;; files, not the source that generates them, because the file is what a reader gets.

(defun %doctrine-files ()
  "The three generated files that teach the changeset doctrine."
  (list "AGENTS.md"
        ".cursor/rules/codelisperer.mdc"
        ".claude/skills/mnemosyne-data/SKILL.md"))

(test the-pack-still-teaches-cast-and-validate
  "The doctrine is right and must not be deleted to make the discrepancy go away. `cast',
`validate-*' and `insert!' exist, are exported and are tested; what was missing was a caller."
  (with-temp-dir (root)
    (cons/conform:install-conformance root :name "widget" :with-claude t)
    (dolist (f (%doctrine-files))
      (let ((text (%slurp root f)))
        (is (search "cast" text) "~A should still teach cast" f)
        (is (search "validate" text) "~A should still teach validate" f)))))

(test the-pack-does-not-tell-a-reader-to-write-through-insert
  "The unqualified rule. Every mention of `insert!' must now carry the qualification, so a
scaffolded project is not handed a rule the framework does not keep."
  (with-temp-dir (root)
    (cons/conform:install-conformance root :name "widget" :with-claude t)
    (dolist (f (%doctrine-files))
      (let ((text (%slurp root f)))
        (is-false (search "validate -> insert!" text)
                  "~A states the unqualified rule" f)
        (is-false (search "then `insert!`" text)
                  "~A states the unqualified rule" f)))))

(test every-mention-of-insert-says-why-it-is-not-the-default
  "A qualification that appears in one file and not another is the same defect one copy over."
  (with-temp-dir (root)
    (cons/conform:install-conformance root :name "widget" :with-claude t)
    (dolist (f (%doctrine-files))
      (let ((text (%slurp root f)))
        (when (search "insert!" text)
          (is (search "#93" text)
              "~A mentions insert! without naming what blocks it" f))))))

(test the-pack-names-the-builder-as-the-write-path
  (with-temp-dir (root)
    (cons/conform:install-conformance root :name "widget" :with-claude t)
    (dolist (f (%doctrine-files))
      ;; "builder", not "query builder": the generated files are hard-wrapped, so a
      ;; two-word phrase can land across a line break and the search fails while the text
      ;; is correct. AGENTS.md wrapped exactly there on the first run.
      (is (search "builder" (%slurp root f))
          "~A should name the builder as today's write path" f))))
