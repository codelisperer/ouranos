;;;; definitions.lisp --- screens, cases, suites and probes, as data (#1028).
;;;;
;;;; Each is stored by name in a table of this package. A name is a symbol or a string and is
;;;; compared without regard to case, so :dashboard, 'dashboard and "dashboard" are one screen.
;;;; A definition is checked when it is made: a step of an unknown kind, or of a known kind with
;;;; the wrong arguments, signals INVALID-DEFINITION at load time rather than in the middle of a
;;;; browser run.

(in-package #:dokimasia)

(define-condition invalid-definition (error)
  ((reason :initarg :reason :reader invalid-definition-reason))
  (:report (lambda (c s) (format s "dokimasia: ~A" (invalid-definition-reason c))))
  (:documentation "A screen, case, suite, probe or row file that dokimasia cannot use. REASON
says what is wrong with it, in words."))

(defun %invalid (control &rest args)
  (error 'invalid-definition :reason (apply #'format nil control args)))

(defun %key (name)
  "The table key for NAME, a symbol or a string."
  (etypecase name
    (symbol (symbol-name name))
    (string (string-upcase name))))

(defun %name-string (name)
  "NAME as it is shown in a report: lower case, without a package."
  (string-downcase (%key name)))

;;; --- screens -----------------------------------------------------------------------------

(defstruct (screen (:constructor %make-screen))
  name path path-prefix present absent title)

(defvar *screens* (make-hash-table :test 'equal))

(defun %string-list (value what)
  (let ((list (if (listp value) value (list value))))
    (unless (every #'stringp list)
      (%invalid "~A is a string or a list of strings; got ~S" what value))
    list))

(defmacro define-screen (name &key path path-prefix present absent title)
  "Define the screen NAME: a page whose path is PATH exactly, or starts with PATH-PREFIX; on which
an element matches each CSS selector in PRESENT and none matches any selector in ABSENT; and,
when TITLE is given, whose document title contains it. Every part given must hold. A screen is
defined once and used by every case, in an :EXPECT-SCREEN step."
  `(%define-screen ',name :path ,path :path-prefix ,path-prefix :present ,present
                          :absent ,absent :title ,title))

(defun %define-screen (name &key path path-prefix present absent title)
  (unless (or (symbolp name) (stringp name))
    (%invalid "a screen's name is a symbol or a string; got ~S" name))
  (when (and path path-prefix)
    (%invalid "the screen ~A has both :PATH and :PATH-PREFIX; give one" (%name-string name)))
  (dolist (p (list path path-prefix title))
    (unless (or (null p) (stringp p))
      (%invalid "the screen ~A: :PATH, :PATH-PREFIX and :TITLE are strings; got ~S"
                (%name-string name) p)))
  (let ((present (%string-list present ":PRESENT"))
        (absent (%string-list absent ":ABSENT")))
    (unless (or path path-prefix present absent title)
      (%invalid "the screen ~A says nothing about the page, so every page would match it"
                (%name-string name)))
    (setf (gethash (%key name) *screens*)
          (%make-screen :name (%name-string name) :path path :path-prefix path-prefix
                        :present present :absent absent :title title))
    name))

(defun find-screen (name)
  "The screen defined as NAME, or NIL."
  (gethash (%key name) *screens*))

;;; --- values --------------------------------------------------------------------------------

(defun %value-form-p (form)
  "Whether FORM is a value a step can use: a string, a number, (:INPUT key) for the row's value
of KEY, or (:USER key) for the signed-in user's value of KEY."
  (or (stringp form) (realp form)
      (and (consp form) (member (first form) '(:input :user))
           (= (length form) 2) (or (symbolp (second form)) (stringp (second form))))))

;;; --- steps -------------------------------------------------------------------------------

(defparameter +step-kinds+
  '(:visit :fill :click :select :wait-for :expect-screen :expect-text :expect-stored
    :expect-scroll-kept :screenshot)
  "The kinds of step a case can have.")

(defparameter +action-kinds+ '(:visit :fill :click :select)
  "The kinds of step after which the runner waits for the page to settle.")

(defun %check-options (step options allowed)
  (unless (evenp (length options))
    (%invalid "the step ~S has an odd number of options" step))
  (loop for (k v) on options by #'cddr
        do (unless (member k allowed)
             (%invalid "the step ~S has the option ~S; it accepts ~{~S~^, ~}" step k allowed))
           (when (and (eq k :timeout) (not (and (realp v) (plusp v))))
             (%invalid "the step ~S has the :TIMEOUT ~S; it is a positive number of seconds" step v))))

(defun %check-step (step)
  "Signal INVALID-DEFINITION unless STEP is a step of a known kind with the arguments that kind
takes. Returns STEP."
  (unless (and (consp step) (member (first step) +step-kinds+))
    (%invalid "~S is not a step; a step is a list starting with one of ~{~S~^, ~}"
              step +step-kinds+))
  (destructuring-bind (kind &rest args) step
    (flet ((need (n what)
             (unless (>= (length args) n)
               (%invalid "the step ~S needs ~A" step what)))
           (selector (x)
             (unless (and (stringp x) (plusp (length x)))
               (%invalid "the step ~S needs a CSS selector, a non-empty string, where it has ~S"
                         step x)))
           (value (x)
             (unless (%value-form-p x)
               (%invalid "the step ~S has ~S where a value goes: a string, a number, (:input key) or (:user key)"
                         step x))))
      (ecase kind
        (:visit (need 1 "a path or URL") (value (first args)) (%check-options step (rest args) '()))
        ((:fill :select)
         (need 2 "a selector and a value") (selector (first args)) (value (second args))
         (%check-options step (cddr args) '()))
        (:click (need 1 "a selector") (selector (first args)) (%check-options step (rest args) '()))
        (:wait-for
         (need 1 "a selector or (:expression \"...\")")
         (let ((what (first args)))
           (unless (or (and (stringp what) (plusp (length what)))
                       (and (consp what) (eq (first what) :expression) (= 2 (length what))
                            (stringp (second what))))
             (%invalid "the step ~S waits for ~S; give a selector or (:expression \"...\")" step what)))
         (%check-options step (rest args) '(:timeout)))
        (:expect-screen
         (need 1 "a screen name")
         (unless (or (symbolp (first args)) (%value-form-p (first args)))
           (%invalid "the step ~S needs a screen name or a value naming one" step))
         (%check-options step (rest args) '(:timeout)))
        (:expect-text
         (need 2 "a selector and the text expected in it") (selector (first args))
         (value (second args)) (%check-options step (cddr args) '(:timeout)))
        (:expect-stored
         (need 1 "a probe name")
         (unless (or (symbolp (first args)) (stringp (first args)))
           (%invalid "the step ~S needs a probe name, a symbol or a string" step))
         (mapc #'value (rest args)))
        (:expect-scroll-kept
         (need 1 "an action step")
         (let ((action (first args)))
           (unless (and (consp action) (member (first action) +action-kinds+))
             (%invalid "the step ~S needs an action step (~{~S~^, ~}) first" step +action-kinds+))
           (%check-step action))
         (%check-options step (rest args) '(:pane :scroll))
         (let ((pane (getf (rest args) :pane)) (scroll (getf (rest args) :scroll)))
           (when pane (selector pane))
           (unless (or (null scroll) (and (integerp scroll) (>= scroll 0)))
             (%invalid "the step ~S has the :SCROLL ~S; it is a whole number of pixels" step scroll))))
        (:screenshot
         (need 1 "a name")
         (let ((name (first args)))
           (unless (and (stringp name) (plusp (length name))
                        (every (lambda (c) (or (alphanumericp c) (find c "-_."))) name))
             (%invalid "the step ~S needs a name of letters, digits, -, _ and . for its file" step)))
         (%check-options step (rest args) '())))))
  step)

(defun %unpackaged (form)
  "FORM with each symbol that is not a keyword or NIL replaced by the keyword of its name, so a
report shows bt-home rather than my-app/tests::bt-home."
  (cond ((consp form) (cons (%unpackaged (car form)) (%unpackaged (cdr form))))
        ((and form (symbolp form) (not (keywordp form)) (not (eq form t)))
         (intern (symbol-name form) :keyword))
        (t form)))

(defun step-label (step)
  "A short description of STEP for a report."
  (let ((*print-length* 4) (*print-level* 3) (*print-case* :downcase))
    (let ((text (prin1-to-string (%unpackaged step))))
      (if (> (length text) 120) (concatenate 'string (subseq text 0 117) "...") text))))

;;; --- cases and rows ----------------------------------------------------------------------

(defstruct (dcase (:constructor %make-dcase))
  name requirement user steps rows base-directory)

(defvar *cases* (make-hash-table :test 'equal))
(defvar *case-order* '() "Case keys in the order they were first defined.")

(defmacro define-case (name &key requirement user steps rows)
  "Define the case NAME: STEPS, a list of steps (see dokimasia/README.md), run once for each row of
ROWS, signed in as USER when given. REQUIREMENT is an optional requirement id carried into the
report.

ROWS is a list of plists, one per row, such as ((:email \"a@example.com\" :expected :dashboard)),
or (:FILE \"path\") naming a CSV file whose first line names the columns, or an s-expression
file holding a list of such plists. A relative path is taken from the directory of the file this
form is in. A row's value is used in a step as (:INPUT key). Without ROWS the case runs once.
A row's ID column or key, when present, names the row in the report."
  `(%define-case ',name :requirement ,requirement :user ',user :steps ',steps :rows ',rows
                        :base-directory ,(let ((here (or *compile-file-truename* *load-truename*)))
                                           (and here (namestring
                                                      (make-pathname :name nil :type nil
                                                                     :version nil
                                                                     :defaults here))))))

(defun %define-case (name &key requirement user steps rows base-directory)
  (unless (or (symbolp name) (stringp name))
    (%invalid "a case's name is a symbol or a string; got ~S" name))
  (unless (or (null requirement) (stringp requirement))
    (%invalid "the case ~A: :REQUIREMENT is a string; got ~S" (%name-string name) requirement))
  (unless (or (null user) (symbolp user) (stringp user))
    (%invalid "the case ~A: :USER names a user of the target, a symbol or a string; got ~S"
              (%name-string name) user))
  (unless (and (listp steps) steps)
    (%invalid "the case ~A has no steps" (%name-string name)))
  (mapc #'%check-step steps)
  (unless (or (null rows) (%file-rows-spec-p rows)
              (and (listp rows) (every #'%plist-row-p rows)))
    (%invalid "the case ~A: :ROWS is a list of plists or (:file \"path\"); got ~S"
              (%name-string name) rows))
  (let ((key (%key name)))
    (unless (gethash key *cases*)
      (setf *case-order* (append *case-order* (list key))))
    (setf (gethash key *cases*)
          (%make-dcase :name (%name-string name) :requirement requirement
                       :user (and user (%name-string user)) :steps steps :rows rows
                       :base-directory base-directory))
    name))

(defun find-case (name)
  "The case defined as NAME, or NIL."
  (gethash (%key name) *cases*))

(defun %file-rows-spec-p (rows)
  (and (consp rows) (eq (first rows) :file) (= 2 (length rows)) (stringp (second rows))))

(defun %plist-row-p (row)
  (and (listp row) (evenp (length row))
       (loop for (k) on row by #'cddr always (or (symbolp k) (stringp k)))))

(defun %plist->row (plist)
  "A row as an alist of (lower-case name . value), from PLIST."
  (loop for (k v) on plist by #'cddr collect (cons (%name-string k) v)))

(defun %resolve-file (path base-directory)
  (let ((p (uiop:parse-native-namestring path)))
    (if (or (uiop:absolute-pathname-p p) (null base-directory))
        p
        (merge-pathnames p (uiop:ensure-directory-pathname base-directory)))))

(defun %read-csv-rows (file)
  (let ((rows (mapcar (lambda (r) (coerce r 'list)) (csv:read-file file :external-format :utf-8))))
    (when (null rows)
      (%invalid "the row file ~A is empty; its first line names the columns" file))
    (let ((header (mapcar (lambda (h) (string-downcase (string-trim " " h))) (first rows))))
      (when (some (lambda (h) (zerop (length h))) header)
        (%invalid "the row file ~A has a column with no name in its first line" file))
      (loop for row in (rest rows)
            for line from 2
            unless (every (lambda (f) (zerop (length f))) row)
              collect (progn
                        (unless (= (length row) (length header))
                          (%invalid "line ~D of ~A has ~D field~:P; its first line names ~D column~:P"
                                    line file (length row) (length header)))
                        (mapcar #'cons header row))))))

(defun %read-sexp-rows (file)
  (let ((data (handler-case
                  (with-open-file (in file :external-format :utf-8)
                    (sexp:read-data in :intern-keywords t :comments :skip))
                (sexp:unsafe-data (c)
                  (%invalid "the row file ~A is not plain data: ~A" file c)))))
    (unless (and (listp data) (every #'%plist-row-p data))
      (%invalid "the row file ~A holds ~S; it should hold a list of plists" file
                (if (listp data) (find-if-not #'%plist-row-p data) data)))
    (mapcar #'%plist->row data)))

(defun case-rows (dcase)
  "DCASE's rows, each an alist of (lower-case name . value), in order. Reads a row file each time,
so a file edited between runs is read again. Signals INVALID-DEFINITION for a file that cannot be
used."
  (let ((rows (dcase-rows dcase)))
    (cond ((null rows) (list '()))
          ((%file-rows-spec-p rows)
           (let ((file (%resolve-file (second rows) (dcase-base-directory dcase))))
             (unless (probe-file file)
               (%invalid "the case ~A reads its rows from ~A, which does not exist"
                         (dcase-name dcase) (uiop:native-namestring file)))
             (let ((read (if (string-equal (pathname-type file) "csv")
                             (%read-csv-rows file)
                             (%read-sexp-rows file))))
               (or read (%invalid "the row file ~A has no rows" (uiop:native-namestring file))))))
          (t (mapcar #'%plist->row rows)))))

(defun row-id (row index)
  "The name of ROW, the INDEX-th (from 0) of its case: its id value, or row-N counting from 1."
  (let ((id (cdr (assoc "id" row :test #'string=))))
    (if (and id (plusp (length (princ-to-string id))))
        (princ-to-string id)
        (format nil "row-~D" (1+ index)))))

;;; --- probes ------------------------------------------------------------------------------

(defstruct (probe (:constructor %make-probe)) name local http)

(defvar *probes* (make-hash-table :test 'equal))

(defun define-probe (name &key local http)
  "Register the stored-data probe NAME for :EXPECT-STORED steps.

LOCAL is a function called in the test image with the step's values as arguments; it reads the
app's store directly, so it is used only against a target that runs local probes (a process
target). HTTP is a function called with the row's PAGE, the target's base URL and the step's
values; it checks the stored data through the app's own API, for example with a fetch evaluated
in the page, and is used against any target. Each returns true when the data is as expected, or
NIL and, as a second value, the reason. A step whose probe has no form the target can run is
reported as not run, with that reason, and never as passed."
  (unless (or (symbolp name) (stringp name))
    (%invalid "a probe's name is a symbol or a string; got ~S" name))
  (unless (or local http)
    (%invalid "the probe ~A has neither :LOCAL nor :HTTP" (%name-string name)))
  (dolist (f (list local http))
    (unless (or (null f) (functionp f) (and (symbolp f) (fboundp f)))
      (%invalid "the probe ~A: :LOCAL and :HTTP are functions; got ~S" (%name-string name) f)))
  (setf (gethash (%key name) *probes*)
        (%make-probe :name (%name-string name) :local local :http http))
  name)

(defun find-probe (name) (gethash (%key name) *probes*))

;;; --- suites ------------------------------------------------------------------------------

(defstruct (suite (:constructor %make-suite))
  name cases target sign-in ignore-console mask mask-text max-requests-per-url)

(defvar *suites* (make-hash-table :test 'equal))

(defmacro define-suite (name &key (cases :all) target sign-in ignore-console mask mask-text
                                  (max-requests-per-url 20))
  "Define the suite NAME, which DOKIMASIA:RUN runs.

CASES is a list of case names, or :ALL for every case defined, in the order they were defined.
TARGET is a form evaluated when the suite runs without a :TARGET of its own, returning a target.
SIGN-IN is a list of steps run before a case with a :USER, with (:USER key) giving that user's
values. IGNORE-CONSOLE lists console messages that do not fail a step, each a string matched
anywhere in the message. MASK lists CSS selectors of elements hidden in screenshots, and
MASK-TEXT JavaScript regular expressions whose matches in the page's text are replaced before a
screenshot. A step that makes more than MAX-REQUESTS-PER-URL requests to one URL fails."
  `(%define-suite ',name :cases ',cases :target ,(and target `(lambda () ,target))
                         :sign-in ',sign-in :ignore-console ',ignore-console :mask ',mask
                         :mask-text ',mask-text :max-requests-per-url ,max-requests-per-url))

(defun %define-suite (name &key cases target sign-in ignore-console mask mask-text
                             max-requests-per-url)
  (unless (or (symbolp name) (stringp name))
    (%invalid "a suite's name is a symbol or a string; got ~S" name))
  (unless (or (eq cases :all) (and (listp cases) (every (lambda (c) (or (symbolp c) (stringp c))) cases)))
    (%invalid "the suite ~A: :CASES is :ALL or a list of case names; got ~S" (%name-string name) cases))
  (unless (listp sign-in)
    (%invalid "the suite ~A: :SIGN-IN is a list of steps" (%name-string name)))
  (mapc #'%check-step sign-in)
  (%string-list ignore-console ":IGNORE-CONSOLE")
  (%string-list mask ":MASK")
  (%string-list mask-text ":MASK-TEXT")
  (unless (and (integerp max-requests-per-url) (plusp max-requests-per-url))
    (%invalid "the suite ~A: :MAX-REQUESTS-PER-URL is a positive integer; got ~S"
              (%name-string name) max-requests-per-url))
  (setf (gethash (%key name) *suites*)
        (%make-suite :name (%name-string name) :cases cases :target target :sign-in sign-in
                     :ignore-console ignore-console :mask mask :mask-text mask-text
                     :max-requests-per-url max-requests-per-url))
  name)

(defun find-suite (name)
  "The suite defined as NAME, or NIL."
  (gethash (%key name) *suites*))

(defun suite-dcases (suite)
  "SUITE's cases, in order. Signals INVALID-DEFINITION for a case name with no case."
  (let ((names (if (eq (suite-cases suite) :all) *case-order* (suite-cases suite))))
    (mapcar (lambda (n)
              (or (find-case n)
                  (%invalid "the suite ~A names the case ~A, which is not defined"
                            (suite-name suite) (%name-string n))))
            names)))
