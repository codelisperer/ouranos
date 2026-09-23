;;;; cli.lisp --- the `cons` command-line tool (cargo-for-Lisp).
;;;;
;;;; The command surface. Lives in its own system (cons/cli) so the core library
;;;; never pulls the CLI dep (clingon). Subcommands:
;;;;
;;;;   cons init NAME [--template T]  scaffold a new project        (real)
;;;;   cons template check [DIR]      generate a template and BUILD it (real)
;;;;   cons setup                     bootstrap the Lisp environment (planned)
;;;;   cons conform [--force]         install the AI-conformance pack (real)
;;;;   cons db-repl [env] [-- args]   open a DB session for an environment (real)
;;;;   cons db-url [env]              print that environment's URL, redacted (real)
;;;;   cons version                   print the version
;;;;
;;;; `setup` (SBCL + Quicklisp + editor/Alive config -- zero-to-ready) is an honest
;;;; stub; grow it in place. See docs/roadmap.md.

(in-package :cl-user)
(defpackage #:cons/cli
  (:use #:cl)
  (:local-nicknames (#:init #:cons/init)
                    (#:db #:cons/db)
                    (#:conform #:cons/conform)
                    (#:project #:cons/project)
                    (#:spec #:cons/spec)
                    (#:run #:cons/run)
                    (#:toolchain #:cons/toolchain)
                    (#:env-scan #:cons/env-scan))
  (:export #:main))
(in-package #:cons/cli)

(defun %planned (name description)
  (format t "cons ~A -- planned.~%  ~A~%  (not yet implemented; tracked on the roadmap.)~%"
          name description))

;;; --- handlers -------------------------------------------------------------

(defun version/handler (cmd)
  "Print the cons version, and the SBCL that BUILT this binary.

The SBCL line is not decoration. bin/cons is a dumped image carrying its own runtime, so it
keeps working after an upgrade replaces the sbcl on PATH -- and then `cons version` is the
only place the two can be compared. When they differ, MAIN has already said so on stderr;
this is where you check what it said."
  (declare (ignore cmd))
  (format t "cons ~A~%" (cons:version))
  (format t "sbcl ~A~@[ (PATH: ~A)~]~%"
          (lisp-implementation-version)
          (let ((on-path (toolchain:sbcl-on-path-version)))
            (and on-path (not (string= on-path (lisp-implementation-version))) on-path))))

(defun env/handler (cmd)
  "`cons env [SYSTEM]` -- every configuration key this project needs, and who needs it.

The problem it answers: a missing key is not a startup error. It is a runtime
configuration-error raised deep inside whichever library needed it, far from anything the
developer just changed -- and the app cannot even list what to set without reading each
dependency's source. Exits 1 when a REQUIRED key is missing, so it can gate a deploy."
  (let* ((arg (first (clingon:command-arguments cmd)))
         (system (or arg (project:system-name))))
    (cond
      ((null system)
       (format *error-output* "cons env: no system here -- run inside a project, or name one:~%")
       (format *error-output* "  cons env myapp~%")
       (uiop:quit 1))
      (t
       (project:ensure-source-registry)
       (if (clingon:getopt cmd :write)
           ;; Append-only: the app's own keys, comments and ordering are the author's.
           (progn (env-scan:sync system) (uiop:quit 0))
           (let ((missing (env-scan:report system)))
             (uiop:quit (if (plusp missing) 1 0))))))))

(defun env-options ()
  (list (clingon:make-option
         :flag :key :write :long-name "write"
         :description "append dependency-declared keys to this project's .env.example")))

(defun init/handler (cmd)
  (let ((name (first (clingon:command-arguments cmd)))
        (template (clingon:getopt cmd :template)))
    (unless name
      (format *error-output* "cons init: NAME required~%")
      (uiop:quit 1))
    (handler-case
        (progn
          (init:scaffold name
                         :template (intern (string-upcase template) :keyword))
          (uiop:quit 0))
      (error (e)
        (format *error-output* "cons init: ~A~%" e)
        (uiop:quit 1)))))

(defun template-check/handler (cmd)
  "`cons template check [DIR|NAME]` -- generate and BUILD, defaulting to the current
directory so an author standing in their template can just run it. No argument and no
manifest here means they probably meant the built-ins, so check those."
  (let* ((arg (first (clingon:command-arguments cmd)))
         (here (probe-file (merge-pathnames "template.lisp" (uiop:getcwd))))
         (target (or arg (and here (uiop:getcwd)))))
    (handler-case
        (uiop:quit (if (if target
                          (cons/template:check target :keep t)
                          (cons/template:check-all))
                       0 1))
      (error (e)
        (format *error-output* "cons template check: ~A~%" e)
        (uiop:quit 1)))))

(defun setup/handler (cmd)
  (declare (ignore cmd))
  (handler-case
      (progn (cons/setup:setup) (uiop:quit 0))
    (error (e)
      (format *error-output* "cons setup: ~A~%" e)
      (uiop:quit 1))))

(defun conform/handler (cmd)
  "Install the AI-conformance pack into the current directory (an existing project)."
  (let ((force (and (clingon:getopt cmd :force) t)))
    (handler-case
        (progn (conform:install-conformance (uiop:getcwd) :with-claude t :force force)
               (uiop:quit 0))
      (error (e)
        (format *error-output* "cons conform: ~A~%" e)
        (uiop:quit 1)))))

(defun db-repl/handler (cmd)
  (let ((env (or (first (clingon:command-arguments cmd)) db:*default-env*))
        (extra (rest (clingon:command-arguments cmd))))
    (handler-case
        (uiop:quit (db:db-repl :env env :extra-args extra
                               :write (and (clingon:getopt cmd :write) t)
                               :confirm (not (clingon:getopt cmd :yes))))
      (db:db-repl-error (e) (format *error-output* "~A~%" e) (uiop:quit 1))
      (error (e) (format *error-output* "cons db-repl: ~A~%" e) (uiop:quit 1)))))

(defun db-url/handler (cmd)
  (let ((env (or (first (clingon:command-arguments cmd)) db:*default-env*)))
    (handler-case
        (progn (db:db-url :env env :reveal (and (clingon:getopt cmd :reveal) t)) (uiop:quit 0))
      (db:db-repl-error (e) (format *error-output* "~A~%" e) (uiop:quit 1))
      (error (e) (format *error-output* "cons db-url: ~A~%" e) (uiop:quit 1)))))

;;; --- command tree ---------------------------------------------------------

(defun init-options ()
  (list (clingon:make-option
         :string :description (format nil "project template: ~{~(~A~)~^ | ~}"
                                      (init:template-names))
         :short-name #\t :long-name "template" :initial-value "lib"
         :key :template)))

(defun db-repl-options ()
  (list (clingon:make-option
         :flag :description "allow writes (non-dev opens read-only by default)"
         :long-name "write" :key :write)
        (clingon:make-option
         :flag :description "skip the type-the-environment-name confirmation"
         :short-name #\y :long-name "yes" :key :yes)))

(defun db-url-options ()
  (list (clingon:make-option
         :flag :description "print the password instead of redacting it"
         :long-name "reveal" :key :reveal)))

(defun conform-options ()
  (list (clingon:make-option
         :flag :description "overwrite existing pack files"
         :long-name "force" :key :force)))

(defun subcommand (name description handler &optional options)
  (clingon:make-command :name name :description description
                        :handler handler :options (or options '())))

(defun template-command ()
  (clingon:make-command
   :name "template" :description "author and validate project templates"
   :handler (lambda (cmd) (clingon:print-usage-and-exit cmd t))
   :sub-commands
   (list (subcommand "check"
                     "generate a template into a temp dir and BUILD it ([DIR|NAME]; default: here, else the built-ins)"
                     #'template-check/handler))))

(defun cons-command ()
  (clingon:make-command
   :name "cons"
   :version (cons:version)
   :description "cons the magnificent: project & dev tooling for Common Lisp."
   :handler (lambda (cmd) (clingon:print-usage-and-exit cmd t))
   :sub-commands
   (list (subcommand "init" "scaffold a new project (NAME [--template T])"
                     #'init/handler (init-options))
         (template-command)
         (subcommand "setup" "put this project on the ASDF path (source-registry drop-in)"
                     #'setup/handler)
         (subcommand "conform" "install the AI-conformance pack (AGENTS.md + skills/rules + commit-msg hook)"
                     #'conform/handler (conform-options))
         (subcommand "db-repl" "open a DB session for an environment ([dev|staging|prod] [-- args])"
                     #'db-repl/handler (db-repl-options))
         (subcommand "db-url" "print the DB URL for an environment (redacted)"
                     #'db-url/handler (db-url-options))
         (subcommand "env" "list every config key this project needs, and who needs it"
                     #'env/handler (env-options))
         (subcommand "version" "print the cons version" #'version/handler))))

;;; --- dispatch: built-in commands vs. build-spec targets -------------------

(defparameter *builtin-commands*
  '("init" "template" "setup" "conform" "db-repl" "db-url" "env" "version" "help" "-h" "--help"
    "--version")
  "First-arg tokens that select the built-in clingon surface. Anything else, inside a
project that has a `cons.lisp`, is treated as a build-spec TARGET name.")

(defun %pop-flag (flag args)
  "Return (values PRESENT-P ARGS-without-every-FLAG)."
  (if (member flag args :test #'string=)
      (values t (remove flag args :test #'string=))
      (values nil args)))

(defun main ()
  "Entry point for the `cons` executable. First re-point ASDF at the CURRENT checkout
(the path baked into bin/cons at bootstrap is otherwise stale once the repo moves or
the binary lands elsewhere), so every subcommand resolves systems from the project
`cons` was invoked in.

Then dispatch: a built-in first arg (init/setup/conform/version/help) runs the clingon
surface; otherwise, if the current directory sits under a project with a `cons.lisp`,
the first arg is a build-spec target (`cons dev HOST=0.0.0.0`) and trailing KEY=VALUE
args set its params -- with no target, the targets are listed. A leading `--fresh`
forces the target to run in a subprocess sbcl instead of cons's warm image. With no
`cons.lisp` and no built-in, clingon prints usage."
  ;; Early and once, before anything can meet a bare "Don't know how to REQUIRE SB-POSIX"
  ;; (#161). Reported, not fatal: `cons version` and `cons help` must still answer on a
  ;; broken toolchain, since that is when you need them most.
  (toolchain:check)
  (project:ensure-source-registry)
  (let ((argv (uiop:command-line-arguments)))
    (multiple-value-bind (fresh rest) (%pop-flag "--fresh" argv)
      (let ((first (first rest)))
        (cond
          ((and first (member first *builtin-commands* :test #'string-equal))
           (clingon:run (cons-command) rest))
          (t
           (let ((build-spec
                   (handler-case (spec:load-spec)
                     (error (e)
                       (format *error-output* "cons: error reading cons.lisp: ~A~%" e)
                       (uiop:quit 1)))))
             (if build-spec
                 (run:cli-run build-spec rest :fresh fresh)
                 (clingon:run (cons-command) argv)))))))))
