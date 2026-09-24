;;;; spec.lisp --- read a project's `cons.lisp` build spec.
;;;;
;;;; A `cons.lisp` file holds ONE top-level form -- `(cons:project NAME ...)` -- a
;;;; declarative manifest of build targets and params. cons LOADs it (with *package*
;;;; bound to CONS-USER) so the macro runs and registers a parsed SPEC in
;;;; *CURRENT-SPEC*. The macro captures the target forms as *data*: a target names a
;;;; framework function by STRING (`"praxeon/elise:dev"`), never as a literal symbol,
;;;; so reading the manifest never touches a not-yet-loaded package. Params are bare
;;;; symbols, resolved by name at run time (see cons/run).
;;;;
;;;; This module only PARSES the spec. Executing targets is cons/run. Finding the
;;;; spec is a lookup SEPARATE from the ASDF source-registry root (cons/project):
;;;; the registry stays the whole .git monorepo tree; the spec is the nearest
;;;; cons.lisp walking up from the cwd.

(in-package #:cons/spec)

(defvar *current-spec* nil
  "Bound to NIL by LOAD-SPEC; the (cons:project ...) form installs the parsed SPEC
here via INSTALL-SPEC.

DELIBERATELY NOT CARRIED ACROSS A THREAD BOUNDARY (#158), and not registered with
aion/dynamic. It exists only for the length of LOAD-SPEC, as the place the (cons:project ...)
form in a loaded cons.lisp leaves its result; LOAD-SPEC then RETURNS the spec. Code that
needs the spec, on any thread, takes that return value.")

;;; --- the parsed shapes ----------------------------------------------------

(defstruct param
  "A declared build-spec parameter. NAME (keyword), DEFAULT (string or NIL), DOC."
  name default doc)

(defstruct target
  "One parsed build target. NAME is a keyword. The clauses (all optional):
LOAD  -- list of ASDF system name strings to quickload;
TEST  -- a test-system name string (asdf:test-system convenience);
CALL  -- (FN-STRING . ARGS): call PACKAGE:NAME after loading (see cons/run);
SH    -- (PROGRAM . ARGS): run a subprocess (always out-of-image);
EVAL  -- a Lisp form as a STRING, read+eval'd after LOAD (${PARAM} interpolated);
CWD   -- working directory for SH, relative to the spec dir;
INTERACTIVE -- after CALL/EVAL, drop into a REPL to keep the process alive;
ISOLATE     -- force this target into a subprocess even in in-process mode;
STEPS -- list of other target keywords to run in sequence."
  name doc load test call sh eval cwd interactive isolate steps)

(defstruct spec
  "A parsed cons.lisp: NAME, primary SYSTEM, DSS (dynamic-space-size for subprocess
targets), ENV (.env file names), PARAMS, DEFAULT (target keywords), TARGETS, and the
FILE / DIR it was read from."
  name system dss env params default targets file dir)

;;; --- parsing --------------------------------------------------------------

(defun %as-list (x)
  "NIL -> NIL; a list -> itself; an atom -> a one-element list."
  (cond ((null x) nil) ((listp x) x) (t (list x))))

(defun %kw (name)
  "Intern NAME (symbol/string) as an upcased keyword -- the canonical target/param key."
  (intern (string-upcase (string name)) :keyword))

(defun %parse-param (form)
  "Parse a :params entry -- (NAME &optional DEFAULT &key DOC), or a bare NAME."
  (destructuring-bind (name &optional default &key doc) (%as-list form)
    (make-param :name (%kw name) :default default :doc doc)))

(defun %parse-target (form)
  "Parse a :targets entry -- (NAME &key doc load test call sh eval cwd interactive
isolate steps)."
  (destructuring-bind (name &key doc load test call sh eval cwd
                            interactive isolate steps)
      form
    (make-target
     :name (%kw name) :doc doc
     :load (mapcar #'string (%as-list load))
     :test (when test (string test))
     :call call
     :sh (mapcar #'string (%as-list sh))
     :eval eval
     :cwd (when cwd (string cwd))
     :interactive interactive
     :isolate isolate
     :steps (mapcar #'%kw (%as-list steps)))))

(defun install-spec (name options)
  "Parse a project manifest -- NAME plus the OPTIONS plist (as captured by the
`cons:project` macro) -- into a SPEC and store it in *CURRENT-SPEC*. Returns the spec."
  (setf *current-spec*
        (make-spec
         :name (string name)
         :system (getf options :system)
         :dss (getf options :dynamic-space-size)
         :env (mapcar #'string (%as-list (getf options :env)))
         :params (mapcar #'%parse-param (getf options :params))
         :default (mapcar #'%kw (%as-list (getf options :default)))
         :targets (mapcar #'%parse-target (getf options :targets)))))

;;; --- the manifest macro (homed in the CONS package) -----------------------

(in-package #:cons)

(defmacro project (name &rest options)
  "Declare a build spec in a `cons.lisp` file: NAME plus a plist of :system,
:dynamic-space-size, :env, :params, :default and :targets. Everything is captured as
DATA (quoted) and parsed by cons/spec:install-spec, so a target may reference a
framework function by string without its package existing at read time."
  `(cons/spec:install-spec ',name ',options))

(in-package #:cons/spec)

;;; --- discovery + load -----------------------------------------------------

(defparameter *spec-file* "cons.lisp"
  "The build-spec filename cons looks for, walking up from the current directory.")

(defun find-spec (&optional (start (uiop:getcwd)))
  "Walk upward from START (default the cwd) to the nearest ancestor directory that
directly contains a *SPEC-FILE*; return that file's pathname, or NIL if the filesystem
root is reached with none. Independent of the ASDF source-registry root."
  (labels ((up (dir)
             (let ((f (merge-pathnames *spec-file* dir)))
               (cond ((probe-file f) f)
                     (t (let ((parent (uiop:pathname-parent-directory-pathname dir)))
                          (if (equal (namestring parent) (namestring dir)) ; hit fs root
                              nil
                              (up parent))))))))
    (up (uiop:ensure-directory-pathname (truename start)))))

(defun load-spec (&optional (start (uiop:getcwd)))
  "Find and LOAD the nearest cons.lisp (see FIND-SPEC); return the parsed SPEC with its
FILE/DIR filled in, or NIL when there is none. Loaded with *package* bound to
CONS-USER so `(cons:project ...)` and bare `(project ...)` both resolve."
  (let ((file (find-spec start)))
    (when file
      (let ((*current-spec* nil)
            (*package* (or (find-package '#:cons-user) *package*)))
        (load file)
        (when *current-spec*
          (setf (spec-file *current-spec*) file
                (spec-dir *current-spec*) (uiop:pathname-directory-pathname file))
          *current-spec*)))))
