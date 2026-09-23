;;;; env-scan.lisp --- which configuration keys does this project actually need? (#120)
;;;;
;;;; Every framework that needs configuration ships its own `.env.example` listing ONLY its
;;;; own keys -- hermes has one, praxeon has one. That is the right shape: the library
;;;; declares what it needs, stores nothing, and reads the process environment at use time.
;;;;
;;;; What was missing is anything that ASSEMBLES those declarations for the app depending on
;;;; them. A consuming app hand-maintained its own .env.example by reading each dependency's
;;;; source, which drifts silently the moment a library adds a key, and gives no signal at
;;;; all when a dependency is added later. The failure mode is bad in a specific way: a
;;;; missing key is not a startup error, it is a runtime configuration-error raised deep
;;;; inside whichever library needed it, far from anything the developer just changed.
;;;;
;;;; This module is the reading half -- walk the ASDF dependency graph, find each system's
;;;; .env.example, parse out the keys, and attribute each to the system that wants it. `cons
;;;; env` reports it; the generator that writes an app-level .env.example builds on the same
;;;; scan, so the report and the generated file can never disagree about who needs what.
;;;;
;;;; REQUIRED vs OPTIONAL is taken from the file's own convention, which every .env.example
;;;; in this tree already follows without having been told to: a live `KEY=` line is a key
;;;; the library expects, a commented `# KEY=` line is an optional override. That is worth
;;;; preserving through the aggregation -- a union of thirty keys is much less useful if it
;;;; cannot say which four actually have to be set.

(in-package #:cons/env-scan)

(defparameter *example-name* ".env.example"
  "The file a system declares its configuration keys in.")

;;; --- reading one declaration file -----------------------------------------

(defstruct (declared-key (:constructor %make-declared-key) (:copier nil))
  "One configuration key, and who asked for it."
  name        ; "SENDGRID_API_KEY"
  system      ; the system that declared it, as a string
  requiredp   ; live KEY= line, vs a commented-out optional override
  comment)    ; the comment block above it, verbatim, if any

(defun %env-var-name-p (name)
  "True for a plausible environment-variable name: SCREAMING_SNAKE_CASE.

Cheap, and it is what keeps prose out of the key list. A .env.example is mostly comments,
and the alternative -- treating every commented line containing `=` as a declaration --
turns a sentence like `# HERMES_TRANSPORT=dev forces the dev transport` into a key with a
paragraph for a value."
  (and (stringp name) (plusp (length name))
       (alpha-char-p (char name 0))
       (every (lambda (c) (or (upper-case-p c) (digit-char-p c) (char= c #\_))) name)))

(defun %commented-key (line)
  "For a `# KEY=value` line, the KEY; else NIL.

An optional override is written commented-out in every .env.example in this tree, so the
comment marker is load-bearing rather than decorative and must survive the scan."
  (let ((body (string-left-trim '(#\Space #\Tab #\#) line)))
    (when (and (plusp (length body))
               (find #\= body)
               ;; prose is not a key: `# Twilio, if you want SMS` has no `=` before its
               ;; first space, and `# Set FOO=bar to enable` has a space before its `=`
               (let ((eq (position #\= body))
                     (sp (position #\Space body)))
                 (and eq (or (null sp) (< eq sp)))))
      (let ((key (nth-value 0 (cons/env::%parse-line body))))
        (and (%env-var-name-p key) key)))))

(defun parse-example (path system)
  "Parse a .env.example at PATH into DECLARED-KEYs attributed to SYSTEM.

Keeps the comment block immediately above each key: that prose is how a library explains
what its key is for, and dropping it in aggregation would produce a wall of names."
  (let ((keys '()) (block '()))
    (with-open-file (in path :external-format :utf-8 :if-does-not-exist nil)
      (when in
        (loop for line = (read-line in nil nil)
              while line
              do (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
                   (cond
                     ;; blank: ends the current comment block
                     ((zerop (length trimmed)) (setf block '()))
                     ;; a live KEY=VALUE -- required
                     ((and (char/= #\# (char trimmed 0))
                           (cons/env::%parse-line trimmed))
                      (push (%make-declared-key
                             :name (cons/env::%parse-line trimmed) :system system
                             :requiredp t
                             :comment (format nil "~{~A~^~%~}" (reverse block)))
                            keys)
                      (setf block '()))
                     ;; a commented KEY= -- optional override
                     ((and (char= #\# (char trimmed 0)) (%commented-key trimmed))
                      (push (%make-declared-key
                             :name (%commented-key trimmed) :system system
                             :requiredp nil
                             :comment (format nil "~{~A~^~%~}" (reverse block)))
                            keys)
                      (setf block '()))
                     ;; prose comment: accumulate, it belongs to whatever key follows
                     ((char= #\# (char trimmed 0)) (push trimmed block))
                     (t (setf block '())))))))
    (nreverse keys)))

;;; --- walking the dependency graph -----------------------------------------

(defun %dependency-closure (system &optional (seen (make-hash-table :test 'equal)))
  "Every system SYSTEM depends on, transitively, as system objects.

Transitive rather than direct on purpose: an app declares `hyperion`, and it is hermes --
two levels down -- that wants a SendGrid key. Direct dependencies alone would answer the
easy half of the question and silently omit the half that actually catches people out.

Unfindable systems are skipped rather than signalled: `cons env` must still be useful in a
checkout where one optional dependency is not installed, and a hard failure there would make
the tool useless exactly when configuration questions are being asked."
  (let ((result '()))
    (labels ((walk (designator)
               (let* ((name (string-downcase (asdf:coerce-name designator))))
                 (unless (gethash name seen)
                   (setf (gethash name seen) t)
                   (let ((system (ignore-errors (asdf:find-system designator nil))))
                     (when system
                       (push system result)
                       (dolist (dep (asdf:system-depends-on system))
                         ;; a dep can be (:version "x" "1.0") or (:feature ...)
                         (let ((d (if (consp dep) (car (last dep)) dep)))
                           (when (or (stringp d) (symbolp d))
                             (ignore-errors (walk d)))))))))))
      (walk system))
    (nreverse result)))

(defun scan-systems (designators)
  "Every configuration key declared by DESIGNATORS or anything they depend on.

Takes a LIST of systems rather than one, because `cons init` has to answer this question
about a project that does not exist yet: the scaffold is written before anything is on the
ASDF path, so there is no system to ask -- only the dependency list the template declared.
SCAN is the same question asked of an existing project.

Returns DECLARED-KEYs deduplicated by name: two libraries wanting the same key is one key,
attributed to the first declarer found, and must not produce two entries in a generated
file."
  (let ((seen (make-hash-table :test 'equalp))
        (out '()))
    (dolist (designator designators)
      (dolist (sys (cons (ignore-errors (asdf:find-system designator nil))
                         (%dependency-closure designator)))
        (when sys
          (let ((path (probe-file (asdf:system-relative-pathname sys *example-name*))))
            (when path
              (dolist (key (parse-example path (asdf:component-name sys)))
                (unless (gethash (declared-key-name key) seen)
                  (setf (gethash (declared-key-name key) seen) t)
                  (push key out))))))))
    (nreverse out)))

(defun scan (system)
  "Every configuration key declared by SYSTEM or anything it depends on."
  (scan-systems (list system)))

;;; --- the report -----------------------------------------------------------

(defun key-status (key)
  "One of :SET, :MISSING (required and absent) or :UNSET (optional and absent)."
  (let ((value (uiop:getenv (declared-key-name key))))
    (cond ((and value (plusp (length value))) :set)
          ((declared-key-requiredp key) :missing)
          (t :unset))))

(defun report (system &key (stream *standard-output*))
  "Print every declared key, who wants it, and whether it is currently set.

Returns the number of REQUIRED keys that are missing, so a caller can exit non-zero. The
point is to turn a runtime configuration-error raised deep inside a library into a
startup-time answer: this is what the app needs, this is who needs it, this is what is not
there yet."
  (let* ((keys (scan system))
         (missing 0))
    (if (null keys)
        (format stream "~&No .env.example found for ~(~A~) or anything it depends on.~%"
                (asdf:coerce-name system))
        (let ((width (reduce #'max keys :key (lambda (k) (length (declared-key-name k)))
                                        :initial-value 3)))
          (format stream "~&Configuration for ~(~A~) and its dependencies:~%~%"
                  (asdf:coerce-name system))
          (dolist (key keys)
            (let ((status (key-status key)))
              (when (eq status :missing) (incf missing))
              (format stream "  ~:[ ~;!~] ~vA  ~10A  ~A~%"
                      (eq status :missing)
                      width (declared-key-name key)
                      (ecase status (:set "set") (:missing "MISSING") (:unset "unset"))
                      (declared-key-system key))))
          (format stream "~%  ~D key~:P declared, ~D set, ~D required and missing.~%"
                  (length keys)
                  (count :set keys :key #'key-status)
                  missing)
          (when (plusp missing)
            (format stream "~%  A missing required key does not fail at startup -- it fails~%")
            (format stream "  later, inside whichever library needed it, far from here.~%"))))
    missing))

;;; --- generating an app-level .env.example ---------------------------------
;;;
;;; APPEND, NEVER REWRITE. The app's own keys, its comments and its ordering are the
;;; author's; a generator that rewrites the file would silently eat them the first time a
;;; dependency changed. So the only write is a block of keys the file does not already
;;; mention, at the end, which is also what makes the delta legible in a diff -- the whole
;;; point of doing this at `cons init` and again when a dependency is added.

(defun existing-keys (path)
  "Every key PATH already mentions, live or commented. NIL if there is no such file.

Both forms count: a key the author deliberately commented out has been decided about, and
re-appending it would be the generator arguing with the author every time it runs."
  (when (probe-file path)
    (mapcar #'declared-key-name (parse-example path "app"))))

(defun render (keys &key (stream *standard-output*))
  "Write KEYS as .env.example lines, grouped by the system that declared them.

Grouped rather than flat so a developer staring at thirty keys can see who wants which --
and so that removing a dependency later makes its keys identifiable rather than leaving
orphans nobody dares delete. Optional keys stay commented out, exactly as their declaring
library wrote them; a required key is emitted live, because it has to be filled in."
  (let ((by-system '()))
    (dolist (key keys)
      (let ((cell (assoc (declared-key-system key) by-system :test #'string=)))
        (if cell
            (push key (cdr cell))
            (push (list (declared-key-system key) key) by-system))))
    (dolist (group (nreverse by-system))
      (format stream "~%# --- ~A ~A~%" (first group)
              (make-string (max 3 (- 68 (length (first group)))) :initial-element #\-))
      (dolist (key (reverse (rest group)))
        (let ((comment (declared-key-comment key)))
          (when (and comment (plusp (length comment)))
            (format stream "~A~%" comment)))
        (format stream "~:[# ~;~]~A=~%" (declared-key-requiredp key) (declared-key-name key))))))

(defun sync (system &key path (dependencies nil dependencies-p) (stream *standard-output*))
  "Append to SYSTEM's .env.example every key its dependencies declare that it does not
already mention. Returns the list of key names added.

PATH defaults to the app's own .env.example; DEPENDENCIES overrides where the keys come
from, which is what `cons init` passes -- at scaffold time the project is not on the ASDF
path, so its dependencies can only be the list the template declared.

The file is created if absent and APPENDED to otherwise -- NEVER rewritten. The app's own
keys, comments and ordering belong to its author; a generator that rewrote the file would
eat them the first time a dependency changed. Appending also puts the delta in a diff,
which is the point of running this again when a dependency is added."
  (let* ((file (or path (asdf:system-relative-pathname system *example-name*)))
         (already (existing-keys file))
         (found (if dependencies-p (scan-systems dependencies) (scan system)))
         (own (ignore-errors (asdf:coerce-name system)))
         ;; only DEPENDENCY keys: the app's own declarations are already in the file, and
         ;; re-emitting them under a heading would duplicate what the author wrote.
         (new (remove-if (lambda (key)
                           (or (member (declared-key-name key) already :test #'string=)
                               (and own (string-equal (declared-key-system key) own))))
                         found)))
    (cond
      ((null new)
       (format stream "~&~A is already up to date with its dependencies.~%"
               (file-namestring file))
       nil)
      (t
       (let ((fresh (not (probe-file file))))
         (with-open-file (out file :direction :output
                                   :if-exists :append :if-does-not-exist :create
                                   :external-format :utf-8)
           (when fresh
             (format out "# ~A --- copy to `.env` (gitignored) and fill in.~%"
                     (string-downcase (princ-to-string system)))
             (format out "#~%# Loaded by the entry point via cons/env:load-project-env, before~%")
             (format out "# anything reads the environment. The host environment wins in prod.~%"))
           (format out "~%# Keys below are declared by dependencies and were added by `cons env --write`.~%")
           (render new :stream out)))
       (format stream "~&Added ~D key~:P to ~A:~%" (length new) (file-namestring file))
       (dolist (key new)
         (format stream "  ~A~28t~A~:[~; (required)~]~%"
                 (declared-key-name key) (declared-key-system key)
                 (declared-key-requiredp key)))
       (mapcar #'declared-key-name new)))))
