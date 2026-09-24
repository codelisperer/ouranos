;;;; init-tests.lisp --- cons init: target kinds, templates, and what gets generated.
;;;;
;;;; `cons init` had no tests at all, which is why this file starts by pinning the
;;;; BEHAVIOUR of the four built-ins rather than the shape of the code that produces them:
;;;; the templates work is a sequence of refactors (cons/docs/templates-design.md §7), and
;;;; a refactor with no regression net is a rewrite with extra steps.
;;;;
;;;; Everything here scaffolds into a temporary directory and deletes it afterwards.

(in-package #:cons/tests)
(in-suite all)

(defmacro with-scaffold ((root name &rest scaffold-args) &body body)
  "Scaffold NAME into a fresh temporary directory, bind ROOT to the project root, run
BODY, and remove the directory however BODY exits."
  (let ((tmp (gensym "TMP")))
    `(tempdir:with-temporary-directory (,tmp "init-tests")
       (let ((,root nil))
         (let ((*standard-output* (make-broadcast-stream))) ; the report is not the artifact
           (setf ,root (cons/init:scaffold ,name :target ,tmp ,@scaffold-args)))
         (let ((*standard-output* *terminal-io*))
           ,@body)))))

(defun %file (root relpath)
  "The contents of ROOT/RELPATH, or NIL if it does not exist."
  (let ((path (merge-pathnames relpath root)))
    (when (probe-file path) (uiop:read-file-string path))))

;;; --- the two axes ----------------------------------------------------------

(test every-template-declares-a-known-target-kind
  ;; The failure this prevents is a template naming a kind that does not exist, which
  ;; would otherwise surface as a broken generated project rather than a bad template.
  ;; (templates), not *templates*: the latter is a lazily-filled cache, so iterating it
  ;; before anything has scaffolded would check nothing and pass.
  (is (plusp (length (cons/init:templates))))
  (dolist (template (cons/init:templates))
    (is-true (cons/init:template-kind template)
             "template ~S declares unknown kind ~S"
             (cons/init:template-name template)
             (cons/init:template-target-kind template))))

(test two-templates-can-share-one-target-kind
  ;; The whole point of the split: `agent` and `cli` build and run identically and differ
  ;; only in what they depend on. Under the old ecase this had to be spelled out twice,
  ;; and a landing page next to a SaaS app could not be expressed at all.
  (let ((cli (cons/init:find-template :cli))
        (agent (cons/init:find-template :agent)))
    (is (eq (cons/init:template-target-kind cli)
            (cons/init:template-target-kind agent)))
    (is (not (equal (cons/init:template-dependencies cli)
                    (cons/init:template-dependencies agent))))))

(test an-unknown-template-is-refused-by-name
  (signals error (cons/init:scaffold "nope" :template :no-such-template
                                            :target (uiop:temporary-directory))))

;;; --- templates are data, not code ------------------------------------------

(test the-built-ins-are-ordinary-templates-on-disk
  ;; "Built-ins stop being special" is the step-2 claim, and this is what it means: each
  ;; one is a directory with a manifest and a files/ tree, found by looking rather than by
  ;; being listed in the source.
  (dolist (template (cons/init:templates))
    (let ((dir (cons/init:template-directory template)))
      (is-true (probe-file (merge-pathnames "template.lisp" dir))
               "~(~A~) has no manifest" (cons/init:template-name template))
      (is-true (uiop:directory-exists-p (cons/init:template-files-root template))
               "~(~A~) has no files/" (cons/init:template-name template)))))

(test a-template-can-live-anywhere
  ;; The seam third-party authoring arrives through (#32 resolves a URL to a directory;
  ;; this is the other half already working). Nothing about cons/templates/ is privileged.
  (tempdir:with-temporary-directory (tmp "tmpl")
       (ensure-directories-exist (merge-pathnames "files/src/" tmp))
       (with-open-file (out (merge-pathnames "template.lisp" tmp) :direction :output)
         (write-string "(:name \"tiny\" :target-kind :lib :dependencies (\"alexandria\"))" out))
       (with-open-file (out (merge-pathnames "files/{{name}}.asd" tmp) :direction :output)
         (write-string "(defsystem \"{{name}}\" :depends-on ({{deps}}))" out))
       (let ((template (cons/init:load-template tmp)))
         (is (eq :tiny (cons/init:template-name template)))
         (is (eq :lib (cons/init:template-target-kind template)))
         (is (equal '("alexandria") (cons/init:template-dependencies template))))
       ;; And it generates: the marker in the FILE NAME is filled too.
       (let ((out-dir (merge-pathnames "out/" tmp)))
         (let ((*standard-output* (make-broadcast-stream)))
           (cons/init:scaffold "mine" :template tmp :target out-dir))
         (let ((asd (%file (merge-pathnames "mine/" out-dir) "mine.asd")))
           (is-true asd "the {{name}}.asd file name was not substituted")
           (is-true (search "\"alexandria\"" asd))))))

(test a-tmpl-suffix-is-dropped-from-the-written-name
  ;; #108. A template names its system definition `{{name}}.asd.tmpl' so that ASDF does not
  ;; find it inside the template; the project it generates must still get `mine.asd'.
  (tempdir:with-temporary-directory (tmp "tmpl")
       (ensure-directories-exist (merge-pathnames "files/" tmp))
       (with-open-file (out (merge-pathnames "template.lisp" tmp) :direction :output)
         (write-string "(:name \"tiny\" :target-kind :lib :dependencies ())" out))
       (with-open-file (out (merge-pathnames "files/{{name}}.asd.tmpl" tmp) :direction :output)
         (write-string "(defsystem \"{{name}}\")" out))
       (let ((out-dir (merge-pathnames "out/" tmp)))
         (let ((*standard-output* (make-broadcast-stream)))
           (cons/init:scaffold "mine" :template tmp :target out-dir))
         (let ((root (merge-pathnames "mine/" out-dir)))
           (is (equal "(defsystem \"mine\")" (%file root "mine.asd"))
               "mine.asd was not written from {{name}}.asd.tmpl")
           (is (null (probe-file (merge-pathnames "mine.asd.tmpl" root)))
               "the .tmpl file was written under its own name as well")))))

(test asdf-finds-no-template-system-in-this-repository
  ;; #108. With the repository on the source registry as a (:tree ...), ASDF found the four
  ;; built-in templates' `{{name}}.asd' and warned about the duplicates in any session whose
  ;; first source-registry scan happened inside a REQUIRE, such as the second run of
  ;; bootstrap.lisp. This walks the repository with the function ASDF's own
  ;; :tree scan uses, so what it checks is what ASDF would find.
  (let* ((root (uiop:pathname-parent-directory-pathname (asdf:system-source-directory :cons)))
         (found '()))
    (asdf/source-registry:collect-sub*directories-asd-files
     root :collect (lambda (asd) (push asd found)))
    ;; The scan has to be shown to reach the tree, or an empty result would pass. One file at
    ;; the top of a framework and one nested three directories down.
    (dolist (rel '("cons/cons.asd" "mnemosyne/examples/contacts/contacts.asd"))
      (is (find (namestring (merge-pathnames rel root)) found :key #'namestring :test #'string=)
          "the scan did not find ~A under ~A" rel root))
    (is (null (remove-if-not (lambda (asd) (search "{{" (namestring asd))) found))
        "ASDF would find template systems: ~{~A~^, ~}"
        (mapcar #'namestring (remove-if-not (lambda (asd) (search "{{" (namestring asd))) found)))))

(test a-manifest-cannot-execute-code
  ;; Declarative by construction, not by convention: the moment templates resolve by URL,
  ;; a manifest that can run code is a supply-chain problem (design §4).
  (tempdir:with-temporary-directory (tmp "tmpl")
       (ensure-directories-exist (merge-pathnames "files/" tmp))
       (with-open-file (out (merge-pathnames "template.lisp" tmp) :direction :output)
         (write-string "(:name \"evil\" :target-kind :lib
 :dependencies #.(error \"read-eval ran\"))" out))
       (signals error (cons/init:load-template tmp))))

(test a-manifest-must-declare-what-it-needs-to
  (tempdir:with-temporary-directory (tmp "tmpl")
       (ensure-directories-exist (merge-pathnames "files/" tmp))
       ;; No :target-kind -- refused, because the alternative is a generated project
       ;; whose cons.lisp is missing its targets for no visible reason.
       (with-open-file (out (merge-pathnames "template.lisp" tmp) :direction :output)
         (write-string "(:name \"partial\")" out))
       (signals error (cons/init:load-template tmp))))

;;; --- what the built-ins generate -------------------------------------------

(test every-built-in-scaffolds-the-common-skeleton
  (dolist (template (cons/init:template-names))
    (with-scaffold (root "demo" :template template)
      (dolist (relpath '("demo.asd" "src/packages.lisp" "src/demo.lisp" "cons.lisp"
                         ".gitignore" ".env.example" "README.md" "CLAUDE.md"
                         ".vscode/settings.json" "AGENTS.md"))
        (is-true (%file root relpath) "~(~A~): missing ~A" template relpath)))))

(test a-library-has-no-entry-point-and-no-binary
  (with-scaffold (root "demo" :template :lib)
    (is (null (search "main" (%file root "src/demo.lisp"))))
    (is (null (search "(bin " (%file root "cons.lisp"))))
    (is (null (%file root "scripts/build-demo.lisp")))
    ;; The HOST knob belongs to the web kind alone; a library's spec has no :params.
    (is (null (search ":params" (%file root "cons.lisp"))))
    ;; :depends-on () -- a library starts with nothing.
    (is-true (search ":depends-on ()" (%file root "demo.asd")))))

(test an-executable-kind-gets-main-a-bin-target-and-a-dump-script
  (dolist (template '(:cli :agent))
    (with-scaffold (root "demo" :template template)
      (is-true (search "(defun main ()" (%file root "src/demo.lisp")))
      (is-true (search "#:main" (%file root "src/packages.lisp")))
      (is-true (search "(run " (%file root "cons.lisp")))
      (is-true (search "(bin " (%file root "cons.lisp")))
      (is-true (%file root "scripts/build-demo.lisp")))))

(test the-web-kind-serves-rather-than-runs
  (with-scaffold (root "demo" :template :web)
    (let ((spec (%file root "cons.lisp")))
      (is-true (search "(serve " spec))
      (is-true (search "(dev " spec))
      (is-true (search "(bin " spec))
      ;; A web project gets a HOST knob; nothing else does.
      (is-true (search ":params ((host " spec)))
    (is-true (search "hyperion" (%file root "demo.asd")))
    ;; The web file set is a real app, not the generic stub.
    (is-true (search "hyperion/server" (%file root "src/packages.lisp")))
    (is-true (search "(defun serve " (%file root "src/demo.lisp")))))

(test only-the-web-template-carries-web-dependencies
  (is (equal '("cons/env" "clingon")
             (cons/init:template-dependencies (cons/init:find-template :cli))))
  (is (equal '("cons/env" "praxeon")
             (cons/init:template-dependencies (cons/init:find-template :agent))))
  (is (equal '("cons/env" "hyperion" "spinneret" "clack-handler-hunchentoot")
             (cons/init:template-dependencies (cons/init:find-template :web))))
  (is (null (cons/init:template-dependencies (cons/init:find-template :lib)))))

(test every-template-with-an-entry-point-depends-on-the-env-loader
  ;; Load-bearing, not descriptive -- which is why it is separate from the list above.
  ;; A scaffolded entry point must load .env as its FIRST act (pre-publication issue 120), and it cannot do
  ;; that without the loader declared. `lib` is deliberately exempt: a library has no
  ;; entry point, so loading the environment is not its call to make.
  (dolist (kind '(:cli :agent :web))
    (is (member "cons/env" (cons/init:template-dependencies (cons/init:find-template kind))
                :test #'string=)
        "the ~A template must declare cons/env" kind))
  (is (not (member "cons/env" (cons/init:template-dependencies (cons/init:find-template :lib))
                   :test #'string=))
      "a library must not load the environment on its consumer's behalf"))

(test the-web-template-declares-an-http-backend
  ;; Not folded into the test above, because this one is load-bearing rather than
  ;; descriptive: hyperion declares no HTTP server (pre-publication issue 139), so a scaffolded web app that
  ;; names no Clack handler COMPILES and then dies at SRV:START with NO-SERVER-BACKEND --
  ;; a failure `cons template check` cannot see, since building is not starting.
  (let ((deps (cons/init:template-dependencies (cons/init:find-template :web))))
    (is-true (find-if (lambda (d) (search "clack-handler-" d)) deps)
             "the web template must name a Clack handler; hyperion supplies none")))

(test the-project-name-reaches-every-generated-file
  ;; The substitution pass is the one thing every template depends on, and a missed marker
  ;; is invisible until someone tries to build the result.
  (with-scaffold (root "widget" :template :cli :author "T <t@example.com>")
    (dolist (relpath '("widget.asd" "src/packages.lisp" "src/widget.lisp" "cons.lisp"
                       "README.md" "CLAUDE.md" ".vscode/settings.json"))
      (let ((content (%file root relpath)))
        (is-true content "missing ~A" relpath)
        (is (null (search "{{" content)) "~A still carries an unfilled marker" relpath)))
    (is-true (search "T <t@example.com>" (%file root "widget.asd")))))

;;; --- .env is the first act of a scaffolded entry point (pre-publication issue 120) -------------
;;;
;;; Checked STATICALLY, by reading the template source, rather than by generating and
;;; building. `cons template check` builds only :lib in this suite -- deliberately, since
;;; each check is a cold sbcl and building all four would add a minute to every gate run --
;;; so a break in the three templates that DO have entry points would not surface here.
;;; Reading the file catches the regression this is actually about (someone edits a
;;; template and the load-first call quietly goes away) for the cost of an OPEN.

(defun %template-src (kind)
  "Every .lisp file under KIND's template `files/src/`, concatenated.

All of them, not the first: the entry point and the package definition are separate files
and both matter -- the call lives in one, the nickname it is written with in the other --
and DIRECTORY makes no promise about order."
  (let ((dir (cons/init:template-directory (cons/init:find-template kind))))
    (with-output-to-string (out)
      (dolist (file (directory (merge-pathnames "files/src/*.lisp" dir)))
        (write-string (uiop:read-file-string file) out)))))

(test a-scaffolded-entry-point-loads-dotenv-before-anything-reads-the-environment
  ;; The bug behind pre-publication issue 120 was ORDERING: a consuming app loaded .env while building its web
  ;; handler, but its start path had already opened a database and sent mail. One symptom
  ;; blamed the library ("missing required configuration: <KEY>" for a key sitting in
  ;; .env); one was silent (a stray database in the wrong directory).
  (dolist (kind '(:cli :agent :web))
    (let ((src (%template-src kind)))
      (is (search "load-project-env" src)
          "the ~A template's entry point must load .env" kind)
      (is (search "cons/env" src)
          "the ~A template must nickname the loader it calls" kind))))

(test the-lib-template-does-not-load-the-environment
  ;; A library has no entry point, and loading the environment on its consumer's behalf
  ;; would be exactly the surprising action pre-publication issue 120 is trying to remove.
  (is (not (search "load-project-env" (%template-src :lib)))))

;;; --- what a generated project depends on (pre-publication issue 361) ----------------------------
;;;
;;; `cons init` writes an .asd into someone else's project, and until this test nothing
;;; checked what that .asd asked for. The four externals it ships were all documented, but
;;; only because this tree happens to depend on the same ones -- not because anything
;;; compared them. Add one dependency to a template that the tree does not itself use and
;;; it would reach every scaffolded project undocumented.
;;;
;;; THIS SCAFFOLDS AND READS THE GENERATED FILE rather than reading the template manifest.
;;; A manifest test compares the list we wrote against the list we wrote. It cannot see
;;; substitution going wrong, and it cannot see `fiveam', which is a literal in the .asd
;;; template and appears in no `template.lisp' at all. `fiveam' is the reason the rule in
;;; AGENTS.md says to read the real artefact the generator writes.
;;;
;;; The generated `:depends-on' spans several lines, so this reads the file with the Lisp
;;; reader. A line-based parser appears to work and under-reports: grepping for the
;;; `:depends-on' line returns only the first entry of a multi-line list, which for three
;;; of the four templates is `cons/env' and nothing else.

(defun %asd-dependencies (root)
  "Every name in every :DEPENDS-ON of the .asd in ROOT, as lowercase strings.

Read with the Lisp reader, in a package where the symbols cannot collide with ours and with
*READ-EVAL* off -- this is parsing a file, not loading it."
  (let* ((asd (first (directory (merge-pathnames "*.asd" root))))
         (names '()))
    (is-true asd "the scaffolded project has no .asd file at all")
    (when asd
      (let ((pkg (make-package (gensym "ASD-READ") :use '())))
        (unwind-protect
             (with-open-file (in asd)
               (let ((*package* pkg) (*read-eval* nil))
                 (loop for form = (read in nil :eof)
                       until (eq form :eof)
                       do (let ((deps (getf (cddr form) :depends-on)))
                            (dolist (d deps)
                              (let ((n (typecase d
                                         (string d)
                                         (symbol (string-downcase (symbol-name d)))
                                         (t nil))))
                                (when n (pushnew n names :test #'string-equal))))))))
          (delete-package pkg))))
    names))

(defun %shipped-table ()
  "docs/dependencies.md's `Shipped into generated projects' rows, as (dependency . templates).

Reads only that section. The table above it lists what this tree depends on, which is a
different claim, and folding the two together is what let the template dependencies read as
documented when nothing had checked them."
  (let* ((path (merge-pathnames "docs/dependencies.md"
                                ;; The repo root is the PARENT of cons/, not cons/ itself.
                                ;; Merging "../docs/..." against cons/docs/ produced a
                                ;; path with a literal ".." in it that TRUENAME refused.
                                (uiop:pathname-parent-directory-pathname
                                 (asdf:system-source-directory :cons))))
         (lines (uiop:split-string (uiop:read-file-string path)
                                   :separator '(#\Newline)))
         (in-section nil)
         (rows '()))
    (dolist (line lines (nreverse rows))
      (cond
        ((search "### Shipped into generated projects" line) (setf in-section t))
        ((and in-section (> (length line) 3) (string= "###" (subseq line 0 3)))
         (return (nreverse rows)))
        ((and in-section (plusp (length line)) (char= #\| (char line 0)))
         (let* ((cells (uiop:split-string line :separator '(#\|)))
                (name (string-trim '(#\Space #\`) (or (second cells) "")))
                (tpls (string-trim " " (or (third cells) ""))))
           (when (and (plusp (length name))
                      (not (string-equal name "dependency"))
                      (not (find #\- name :test #'char= :end (min 2 (length name)))))
             (push (cons (string-downcase name)
                         (mapcar (lambda (s) (string-trim " " s))
                                 (uiop:split-string tpls :separator '(#\,))))
                   rows))))))))

(test every-generated-dependency-is-documented-as-shipped
  "Scaffold each template for real and check the .asd the user would receive.

Both directions: a dependency the generator emits must appear in the shipped table, AND a
row in that table must still name the template it claims. The second half is what stops the
table becoming a list of things that used to be true."
  (let ((table (%shipped-table))
        (seen (make-hash-table :test #'equal)))
    (is (plusp (length table)) "the shipped-dependencies table is empty or unparsed")
    (dolist (template (cons/init:templates))
      (let ((tname (string-downcase (string (cons/init:template-name template)))))
        (with-scaffold (root (format nil "demo~A" tname)
                             :template (cons/init:template-name template))
          (dolist (dep (%asd-dependencies root))
            ;; The project's own name and its own test system are not dependencies of it.
            (unless (search "demo" dep)
              (setf (gethash (list tname dep) seen) t)
              (let ((row (assoc dep table :test #'string-equal)))
                (is-true row
                         "template ~A ships ~S, which is absent from the shipped-dependencies table in docs/dependencies.md"
                         tname dep)
                (when row
                  (is-true (member tname (cdr row) :test #'string-equal)
                           "template ~A ships ~S, but the table lists only ~{~A~^, ~}"
                           tname dep (cdr row)))))))))
    ;; The other direction: nothing in the table claims a template that no longer ships it.
    (dolist (row table)
      (dolist (tname (cdr row))
        (is-true (gethash (list tname (car row)) seen)
                 "docs/dependencies.md says template ~A ships ~S, and the scaffolded project does not"
                 tname (car row))))))
