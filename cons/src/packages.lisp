;;;; packages.lisp --- cons package definitions.
;;;;
;;;; Package-per-module; :local-nicknames over long prefixes. As the tool grows,
;;;; expect packages like:
;;;;   cons/cli     -- the command surface (new / add / build / test / run / repl)
;;;;   cons/new     -- project scaffolding + templates
;;;;   cons/deps    -- the dependency-source protocol
;;;;   cons/deps/ql, cons/deps/ocicl, cons/deps/native -- source backends
;;;;
;;;; The package is named CONS; since it :use CL, the symbol `cons` inside it is
;;;; simply CL:CONS (inherited) -- no conflict.

(cl:defpackage #:cons
  (:use #:cl)
  (:documentation "cons the magnificent: project & dev tooling for Common Lisp.")
  ;; `project` is the build-spec macro a cons.lisp file writes; defined in spec.lisp
  ;; (homed here so it reads as `cons:project`), it expands to a cons/spec call.
  (:export #:version #:project))

;;; cons/env now lives in its OWN system (see cons.asd) so a scaffolded app can depend
;;; on the .env loader without depending on the whole build tool. Its package is defined
;;; in src/env-package.lisp, alongside it.

(cl:defpackage #:cons/env-scan
  (:use #:cl)
  (:documentation
   "Which configuration keys does this project actually need? Every framework ships its
    own .env.example listing only ITS keys; nothing assembled them for the app depending
    on them, so apps hand-transcribed and drifted. Walks the ASDF dependency graph
    TRANSITIVELY -- an app declares hyperion and it is hermes, two levels down, that wants
    a SendGrid key -- reads each system's .env.example, and attributes every key to the
    system that declared it, preserving required-vs-optional and the explaining comment.
    REPORT is `cons env`; the same scan feeds the app-level .env.example generator, so the
    report and the file cannot disagree.")
  (:export #:scan #:scan-systems #:report #:parse-example #:key-status #:render #:sync
           #:existing-keys
           #:declared-key #:declared-key-p #:declared-key-name #:declared-key-system
           #:declared-key-requiredp #:declared-key-comment
           #:*example-name*))

;;; --- project: locate the project root + point ASDF at it, at runtime -----
(cl:defpackage #:cons/project
  (:use #:cl)
  (:documentation
   "Runtime project-root discovery + source-registry init -- the keystone under
    build/test/serve/run. Walk up from the current directory to the nearest marker
    (`.git` today; a cons manifest later) and (re)initialize ASDF's `(:tree)` source
    registry from THAT root, so `cons` resolves systems from the current checkout
    rather than the path baked into bin/cons at bootstrap -- and works on any project
    it is pointed at. Format-agnostic; the build spec layers on top. uiop-only.")
  (:export #:find-root #:project-root #:ensure-source-registry #:system-name
           #:*root-markers*))

;;; --- setup: put a project on the ASDF path (drop-in), the monorepo way ----
(cl:defpackage #:cons/toolchain
  (:use #:cl)
  (:documentation
   "Is the Lisp under us the one we think it is? A `Don't know how to REQUIRE SB-POSIX`
    names a contrib and points nowhere near the cause, which is that contribs resolve
    against SBCL_HOME and SBCL_HOME does not. Asks the CAPABILITY (can a contrib be
    required?) rather than comparing the variable -- a healthy SBCL overwrites SBCL_HOME
    with its own answer, so the variable agrees precisely when it does not matter. Also
    names the quieter case: an SBCL upgrade leaves a dumped bin/cons working but stale,
    while `--fresh` targets run under the new sbcl. DIAGNOSE is pure over gathered FACTS,
    so the fatal branch is testable on a machine where it is false. uiop-only.")
  (:export #:check #:diagnose #:facts #:report #:fatal-p #:sbcl-on-path-version
           #:*probe-contrib*))

(cl:defpackage #:cons/setup
  (:use #:cl)
  (:local-nicknames (#:project #:cons/project))
  (:documentation
   "`cons setup`: the generalized, cross-OS form of what bootstrap.lisp does for
    ouranos -- write this project's source-registry `(:tree)` drop-in (via
    uiop:xdg-config-home, so it lands where ASDF reads on every OS) so
    `(ql:quickload :it)` resolves from the current checkout. Run inside any consumer
    repo (a consuming app). Notes a stale pre-drop-in local-projects
    self-symlink if found. uiop-only.")
  (:export #:setup))

;;; --- init: scaffold a new project (the "just works" skeleton) ------------
(cl:defpackage #:cons/init
  (:use #:cl)
  (:documentation
   "`cons init`: generate a new project's founding layout -- .asd, package-per-module
    src/, tests/, hardened .gitignore, committed .env.example (closing the loop with
    cons/env), .vscode Alive config, cons.lisp build spec, README/CLAUDE.

    Two axes, deliberately separate (cons/docs/templates-design.md): a TEMPLATE is the
    files you start with, and the TARGET KIND it declares is what cons's verbs do with
    them. `cli` and `agent` are one kind and two templates; a SaaS app and a landing page
    will be another such pair. Pure file emission (uiop-only).")
  (:export #:scaffold #:*default-author*
           #:*templates* #:templates #:find-template #:template-names
           #:resolve-template #:load-template #:template-directory
           #:template-files-root #:builtin-template-directory
           #:template #:template-p #:template-name #:template-target-kind
           #:template-dependencies #:template-description #:template-kind
           #:*target-kinds* #:find-target-kind #:target-kind-names
           #:target-kind #:target-kind-p #:target-kind-name
           #:target-kind-executable-p #:target-kind-implemented-p
           #:dev-port #:+dev-port-base+ #:+dev-port-span+))

;;; --- template: author and validate project templates --------------------
(cl:defpackage #:cons/tempdir
  (:use #:cl)
  (:documentation
   "Private scratch directories that are CREATED, never chosen and hoped for (#204).

    MAKE-TEMPORARY-DIRECTORY and WITH-TEMPORARY-DIRECTORY. Its own module because five
    call sites across src and tests had each open-coded the same unsafe idiom, and a
    pattern copied five times is a pattern the sixth caller will copy too.

    NOT AN ENTROPY FIX, which is the thing most likely to be misread here. The defect was
    never that the name was guessable; it was that the code chose a name and then wrote
    through whatever was already at it. See the commentary on %CREATE-EXCLUSIVELY.")
  (:export #:make-temporary-directory #:with-temporary-directory
           #:temporary-directory-error #:*attempts*))

(cl:defpackage #:cons/template
  (:use #:cl)
  (:local-nicknames (#:tempdir #:cons/tempdir))
  (:documentation
   "`cons template`: the authoring side of scaffolding. CHECK generates a template into a
    temporary directory and BUILDS the result in a cold sbcl -- a template that has never
    been generated and built is a template that does not work, and once templates are
    authored outside this repo that check is the only thing between published and rotted
    (cons/docs/templates-design.md §5).")
  (:export #:check #:check-all #:*check-project-name*))

;;; --- conform: install the AI-conformance pack into a project ------------
(cl:defpackage #:cons/upstream
  (:use #:cl)
  (:documentation
   "Is the framework checkout a consuming app builds against current? (#240)

    Advisory only -- printed before a target runs, never a gate, never a network call.
    The count alone would be non-evidence: `git rev-list --count HEAD..@{u}' compares
    against the last FETCH, so a consumer who never fetches is told \"0 behind\" while
    being arbitrarily far behind. The age of the comparison is reported with it.")
  (:export #:report #:checkout-advisory #:drift-lines #:packages-touched
           #:framework-directory #:*stale-fetch-seconds*))

(cl:defpackage #:cons/db
  (:use #:cl)
  (:local-nicknames (#:sec #:aion/secret))
  (:documentation
   "`cons db-repl` / `cons db-url`: open a database session against a named environment,
    resolving the URL from .env (cons/env's domain) and picking the client from the URL's
    scheme -- psql for Postgres, sqlite3 for a file. Adds no database code; mnemosyne owns
    connections, cons owns config. The password is passed through the child's ENVIRONMENT,
    never argv (argv is world-readable via ps); non-dev environments are confirmed by name
    and open read-only unless asked otherwise.")
  (:export #:db-repl #:db-url #:resolve-url #:parse-target
           #:db-target #:db-target-kind #:db-target-url #:db-target-display
           #:db-repl-error #:db-repl-error-message #:*default-env*))

(cl:defpackage #:cons/conform
  (:use #:cl)
  (:documentation
   "`cons conform`: install the codelisperer AI-conformance pack into a project (new or
    existing) so an IDE assistant -- Claude, Codex, Cursor -- generates spec-conformant
    code. Writes a tool-neutral AGENTS.md (the canonical spec: the DAG, the typed-core/
    effectful-shell split, the Coalton gotchas, the mnemosyne/hyperion patterns, build/test),
    plus .cursor/rules and .claude/skills that point back at it, and optionally a CLAUDE.md
    that imports it. Pure file emission (uiop-only); existing files are skipped unless forced.")
  (:export #:install-conformance #:*tools*))

;;; --- spec: read a project's `cons.lisp` build spec -----------------------
(cl:defpackage #:cons/spec
  (:use #:cl)
  (:documentation
   "Read a project's root `cons.lisp` build spec -- a declarative, Lispy manifest of
    targets (build/test/run/serve/dev/...) and params. The `cons:project` macro
    captures target forms as DATA (never evaluated), so a target may name a not-yet-
    loaded framework function by string (`\"praxeon/elise:dev\"`) with no read-time
    package error. FIND-SPEC walks up from the cwd to the nearest cons.lisp (a lookup
    SEPARATE from the ASDF source-registry root, which stays the .git monorepo tree);
    LOAD-SPEC loads it and returns the parsed SPEC. uiop-only.")
  (:export #:install-spec #:find-spec #:load-spec #:*current-spec*
           ;; spec + accessors
           #:spec #:spec-name #:spec-system #:spec-dss #:spec-env #:spec-params
           #:spec-default #:spec-targets #:spec-file #:spec-dir
           ;; target + accessors
           #:target #:target-name #:target-doc #:target-load #:target-test
           #:target-call #:target-sh #:target-eval #:target-cwd
           #:target-interactive #:target-isolate #:target-steps
           ;; param + accessors
           #:param #:param-name #:param-default #:param-doc))

;;; --- run: execute a build-spec target (warm image, or subprocess sbcl) ----
(cl:defpackage #:cons/run
  (:use #:cl)
  (:local-nicknames (#:spec #:cons/spec))
  (:documentation
   "Execute a build-spec target. Default is IN-PROCESS in cons's warm image (which
    already carries Quicklisp + a 4 GB heap baked in by bootstrap.lisp): quickload the
    target's :load systems and :call its function, or :sh a program. Interactive
    targets (dev/repl) drop into a REPL so background threads keep serving. A global
    --fresh flag (or per-target :isolate) instead runs the Lisp work in a subprocess
    sbcl (the Makefile model) -- required implicitly by save-lisp-and-die targets,
    which use :sh. Quicklisp is reached via (uiop:symbol-call :ql ...) so cons keeps no
    compile-time dep on it.")
  (:export #:run #:cli-run #:list-targets))

;;; --- cons-user: the package a cons.lisp manifest is read in ---------------
(cl:defpackage #:cons-user
  (:use #:cl)
  (:import-from #:cons #:project)
  (:documentation
   "The package LOAD-SPEC binds *package* to while reading a cons.lisp manifest, so
    both `(cons:project ...)` and a bare `(project ...)` resolve. Bare target/param
    names (build, host, ...) intern here harmlessly; cons/run matches params by
    symbol-name, so their home package does not matter."))

;;; NB: the CLI package (cons/cli) is defined in cli.lisp, which lives in the
;;; separate cons/cli system so the core library never pulls clingon.
