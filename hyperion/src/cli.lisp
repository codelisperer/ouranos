;;;; cli.lisp --- the `hyperion` command-line tool (cargo-for-Lisp).
;;;;
;;;; Consolidation decision (see CLAUDE.md / roadmap): Hyperion is a library AND a
;;;; CLI, and for now it also hosts the project-manager/tooling concerns that would
;;;; eventually live in `cons` -- until a clear reason to split them out emerges.
;;;; This is the subcommand skeleton:
;;;;
;;;;   hyperion init NAME    scaffold a new project           (real)
;;;;   hyperion repl         REPL with quicklisp + locals      (real: launches SBCL)
;;;;   hyperion build        compile the current project       (real: quickload)
;;;;   hyperion test         run the current project's tests   (real: test-system)
;;;;   hyperion add PKG      add a dependency                  (planned)
;;;;   hyperion serve        run the dev server + hot-reload   (planned)
;;;;   hyperion deploy       build + ship a binary/image       (planned)
;;;;   hyperion version      print the version                 (real)
;;;;
;;;; The "planned" handlers are honest stubs; grow them in place. Lives in its own
;;;; system (hyperion/cli) so the library never pulls the CLI deps (clingon).

(in-package :cl-user)
(defpackage #:hyperion/cli
  (:use #:cl)
  (:local-nicknames (#:hn #:hyperion))
  (:export #:main))
(in-package #:hyperion/cli)

;;; --- helpers --------------------------------------------------------------
(defun %ql-setup ()
  (namestring (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))

(defun %project-system ()
  "Name of the ASDF system in the current directory (first *.asd), or NIL."
  (let ((asd (first (directory (merge-pathnames "*.asd" (uiop:getcwd))))))
    (when asd (pathname-name asd))))

(defun %sbcl (&rest sbcl-args)
  "Run SBCL with SBCL-ARGS, inheriting this terminal. Returns the exit code."
  (nth-value 2
    (uiop:run-program (list* "sbcl" sbcl-args)
                      :input :interactive :output :interactive
                      :error-output :interactive :ignore-error-status t)))

(defun %planned (name description)
  (format t "hyperion ~A — planned.~%  ~A~%  (not yet implemented; tracked on the roadmap.)~%"
          name description))

;;; --- project scaffolding (hyperion init) ----------------------------------
(defun %write-file (path contents)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede
                          :if-does-not-exist :create)
    (write-string contents s))
  (format t "  create ~A~%" (enough-namestring path)))

(defun scaffold-project (name)
  "Create a minimal CL/ASDF project skeleton under ./NAME/."
  (let ((root (ensure-directories-exist
               (merge-pathnames (format nil "~A/" name) (uiop:getcwd)))))
    (format t "Scaffolding ~A in ~A~%" name root)
    (%write-file (merge-pathnames (format nil "~A.asd" name) root)
                 (format nil ";;;; ~A.asd~%~%(defsystem \"~A\"~%  :description \"\"~%  :version \"0.0.0\"~%  :depends-on (\"hyperion\")~%  :serial t~%  :components ((:module \"src\"~%                :serial t~%                :components ((:file \"packages\")~%                             (:file \"~A\")))))~%"
                         name name name))
    (%write-file (merge-pathnames "src/packages.lisp" root)
                 (format nil ";;;; packages.lisp~%~%(cl:defpackage #:~A~%  (:use #:cl)~%  (:export))~%" name))
    (%write-file (merge-pathnames (format nil "src/~A.lisp" name) root)
                 (format nil ";;;; ~A.lisp~%~%(in-package #:~A)~%" name name))
    (%write-file (merge-pathnames "README.md" root)
                 (format nil "# ~A~%~%A Hyperion project.~%" name))
    (%write-file (merge-pathnames ".gitignore" root)
                 (format nil "*.fasl~%bin/~%.qlot/~%"))
    (format t "Done. Next: cd ~A && hyperion build~%" name)))

;;; --- handlers -------------------------------------------------------------
(defun version/handler (cmd)
  (declare (ignore cmd))
  (format t "hyperion ~A~%" (hn:version)))

(defun init/handler (cmd)
  (let ((name (first (clingon:command-arguments cmd))))
    (if name
        (scaffold-project name)
        (progn (format *error-output* "hyperion init: NAME required~%")
               (uiop:quit 1)))))

(defun repl/handler (cmd)
  (declare (ignore cmd))
  (uiop:quit (%sbcl "--load" (%ql-setup) "--eval" "(ql:register-local-projects)")))

(defun build/handler (cmd)
  (declare (ignore cmd))
  (let ((sys (%project-system)))
    (unless sys
      (format *error-output* "hyperion build: no .asd found in ~A~%" (uiop:getcwd))
      (uiop:quit 1))
    (format t "Building ~A…~%" sys)
    (uiop:quit
     (%sbcl "--dynamic-space-size" "4096" "--non-interactive"
            "--load" (%ql-setup)
            "--eval" "(ql:register-local-projects)"
            "--eval" (format nil "(ql:quickload :~A)" sys)
            "--eval" "(uiop:quit 0)"))))

(defun test/handler (cmd)
  (declare (ignore cmd))
  (let ((sys (%project-system)))
    (unless sys
      (format *error-output* "hyperion test: no .asd found in ~A~%" (uiop:getcwd))
      (uiop:quit 1))
    (format t "Testing ~A…~%" sys)
    (uiop:quit
     (%sbcl "--dynamic-space-size" "4096" "--non-interactive"
            "--load" (%ql-setup)
            "--eval" "(ql:register-local-projects)"
            "--eval" (format nil "(ql:quickload :~A)" sys)
            "--eval" (format nil "(asdf:test-system :~A)" sys)
            "--eval" "(uiop:quit 0)"))))

(defun add/handler (cmd)
  (%planned "add" (format nil "add a dependency (~{~A~^ ~}) to the project's .asd + install it"
                          (or (clingon:command-arguments cmd) '("PKG")))))

(defun serve/handler (cmd)
  (declare (ignore cmd))
  (%planned "serve" "run the dev server with hot-reload (wraps hyperion/server + hyperion/dev)"))

(defun deploy/handler (cmd)
  (declare (ignore cmd))
  (%planned "deploy" "build a save-lisp-and-die binary/image and ship it (Docker/host)"))

;;; --- command tree ---------------------------------------------------------
(defun subcommand (name description handler)
  (clingon:make-command :name name :description description :handler handler))

(defun hyperion-command ()
  (clingon:make-command
   :name "hyperion"
   :version (hn:version)
   :description "Hyperion: a full-stack CL web framework and project tool."
   :handler (lambda (cmd) (clingon:print-usage-and-exit cmd t))
   :sub-commands
   (list (subcommand "init"    "scaffold a new project (NAME)"       #'init/handler)
         (subcommand "repl"    "start a REPL with quicklisp + locals" #'repl/handler)
         (subcommand "build"   "compile the current project"          #'build/handler)
         (subcommand "test"    "run the current project's tests"      #'test/handler)
         (subcommand "add"     "add a dependency (planned)"           #'add/handler)
         (subcommand "serve"   "run the dev server (planned)"         #'serve/handler)
         (subcommand "deploy"  "build + ship a binary (planned)"      #'deploy/handler)
         (subcommand "version" "print the hyperion version"           #'version/handler))))

(defun main ()
  "Entry point for the `hyperion` executable."
  (clingon:run (hyperion-command)))
