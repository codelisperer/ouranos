;;;; run.lisp --- execute a build-spec target.
;;;;
;;;; Two execution modes, chosen per invocation:
;;;;
;;;;   IN-PROCESS (default) -- do the work in cons's own warm image. bin/cons is a
;;;;   dumped SBCL image that already has Quicklisp loaded and a 4 GB heap baked in
;;;;   (bootstrap.lisp: --dynamic-space-size 4096 + :save-runtime-options t), precisely
;;;;   so `cons build` can quickload Coalton-heavy systems here. Fast, and needs no
;;;;   sbcl on PATH -- cons IS sbcl. Interactive targets (dev/repl) then drop into a
;;;;   REPL so the watcher/web-server background threads keep running.
;;;;
;;;;   SUBPROCESS (`cons --fresh <target>`, or a target's :isolate t) -- build an sbcl
;;;;   command line and run it, exactly as the interim Makefile does. Isolated and
;;;;   robust, but slower (cold sbcl + quicklisp reload) and needs sbcl on PATH. :sh
;;;;   targets are ALWAYS a subprocess -- required for save-lisp-and-die, which cannot
;;;;   run in-image (dumping exits the process).
;;;;
;;;; Quicklisp is reached via (uiop:symbol-call :ql ...) so cons keeps no compile-time
;;;; dependency on it (it stays dependency-light).

(in-package #:cons/run)

;;; --- params ---------------------------------------------------------------

(defun %kw (name) (intern (string-upcase (string name)) :keyword))

(defun %param-map (spec cli)
  "A hash NAME(downcased string) -> VALUE(string): the declared param defaults,
overlaid by the CLI alist (NAME . VALUE)."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (p (spec:spec-params spec))
      (setf (gethash (string-downcase (string (spec:param-name p))) h)
            (spec:param-default p)))
    (loop for (k . v) in cli
          do (setf (gethash (string-downcase k) h) v))
    h))

(defun %param (name params)
  "Two values: the value of param NAME in PARAMS, and whether it was present."
  (gethash (string-downcase (string name)) params))

;;; --- argument + string resolution -----------------------------------------

(defun %resolve-args (args params)
  "Resolve a :call arg list: keywords pass through, a bare symbol resolves to its
declared param value (error if undeclared), other literals pass through."
  (mapcar (lambda (a)
            (cond ((keywordp a) a)
                  ((symbolp a)
                   (multiple-value-bind (v found) (%param a params)
                     (unless found
                       (error "target references unknown param ~A" (string-downcase (string a))))
                     v))
                  (t a)))
          args))

(defun %interpolate (string params)
  "Replace each ${NAME} in STRING with the value of param NAME (empty if unknown)."
  (with-output-to-string (out)
    (let ((i 0) (n (length string)))
      (loop while (< i n) do
        (let ((d (search "${" string :start2 i)))
          (cond
            ((null d) (write-string string out :start i) (setf i n))
            (t (let ((e (position #\} string :start d)))
                 (write-string string out :start i :end d)
                 (write-string (or (%param (subseq string (+ d 2) e) params) "") out)
                 (setf i (1+ e))))))))))

(defun %split-fn (fn)
  "Split \"PACKAGE:NAME\" (or PACKAGE::NAME) into (values PACKAGE-STRING NAME-STRING),
both upcased for the standard readtable."
  (let ((c (position #\: fn)))
    (unless c (error ":call function ~S must be PACKAGE:NAME" fn))
    (let ((sym-start (if (and (< (1+ c) (length fn)) (char= (char fn (1+ c)) #\:))
                         (+ c 2) (1+ c))))
      (values (string-upcase (subseq fn 0 c))
              (string-upcase (subseq fn sym-start))))))

;;; --- in-process primitives ------------------------------------------------

;;; --- loading a project's systems so a compile WARNING fails the target (#303) ---
;;;
;;; These used to be `ql:quickload'. Quicklisp's quiet mode wraps the whole load in
;;; (handler-bind ((warning #'muffle-warning)) ...) -- quicklisp/impl-util.lisp,
;;; CALL-WITH-QUIET-COMPILATION -- so a full WARNING from COMPILE-FILE in the app's own code
;;; was neither printed nor counted, and `cons build' and `cons test' exited 0 over code
;;; that `asdf:load-system' refuses with COMPILE-FILE-ERROR.
;;;
;;; The loader below splits the load in two:
;;;
;;;   - The project's OWN systems, those whose .asd is under the project directory ROOT,
;;;     are loaded by ASDF directly. Nothing muffles them, so a WARNING is printed and fails
;;;     the load; a STYLE-WARNING is printed and does not.
;;;   - Everything else the own systems depend on (libraries, and on a consuming app the
;;;     framework) is loaded first with warnings muffled, as Quicklisp's quiet mode did. A
;;;     warning inside a library is not the app's to fix, and must not fail the app's build.
;;;
;;; A WARNING that SBCL defers to the end of the compilation unit -- an undefined variable,
;;; including one a later file of the same system defines -- is signalled after COMPILE-FILE
;;; has returned with FAILURE-P false, so ASDF does not fail the load over it (#525). When it
;;; arrives, *COMPILE-FILE-TRUENAME* is NIL and *LOAD-TRUENAME* names whatever file called the
;;; loader, not the file with the mistake, so neither can say whose warning it is. The loader
;;; does not need them to: by the time the own systems load, every other system is already
;;; loaded, so a full WARNING signalled during that load is the project's own. Each load gets
;;; its own compilation unit, with :OVERRIDE T, so that the deferred warnings are signalled
;;; before the load returns even when the caller is inside a compilation unit of its own:
;;; the own systems' inside the handler that counts them, and the others' inside the handler
;;; that muffles them.
;;;
;;; A system Quicklisp has not downloaded yet cannot be found by ASDF; FIND-SYSTEM then
;;; signals MISSING-COMPONENT, and the loader quickloads the missing name and tries again.
;;;
;;; FORCE-OWN recompiles the own systems even when their fasls are current (`cons
;;; --strict'). It exists because a fasl compiled while a warning was being muffled -- by an
;;; older cons, or by a quickload at the REPL -- is current, so ASDF would load it without
;;; compiling and the warning would stay hidden.
;;;
;;; ONE FORM, TWO USES. It is a quoted lambda so the in-process path compiles it and the
;;; subprocess path (`--fresh', :isolate) prints it into an --eval, and the two cannot drift.
;;; That is also why it reaches ASDF and Quicklisp only through UIOP:SYMBOL-CALL: printed,
;;; it contains nothing but CL, UIOP and keyword symbols, which read back the same in a bare
;;; sbcl that has only loaded Quicklisp.

(defparameter +load-form+
  '(lambda (system root force-own with-tests)
     ;; ROOT is resolved with TRUENAME because ASDF reports a system's directory with
     ;; symbolic links resolved. On macOS the temporary directory /var/folders/... is
     ;; /private/var/folders/..., and a project reached through any symbolic link has the same
     ;; problem: compared unresolved, no system was the project's own, and every warning was
     ;; muffled again.
     (let ((root (let ((r (uiop:ensure-directory-pathname root)))
                   (namestring (or (ignore-errors (truename r)) r))))
           (own '())
           (others '())
           (seen (make-hash-table :test (function equal))))
       (labels ((asdf (fn &rest args) (apply (function uiop:symbol-call) :asdf fn args))
                (fetch (name) (uiop:symbol-call :ql :quickload name :silent t))
                (quiet (name)
                  ;; A system ASDF can already find: load it with warnings muffled, which is
                  ;; what Quicklisp's quiet mode does, without asking Quicklisp to look it up.
                  (handler-bind ((warning (function muffle-warning)))
                    (with-compilation-unit (:override t)
                      (asdf :load-system name))))
                (own-load (name)
                  ;; ASDF fails the load itself on a WARNING that COMPILE-FILE reports. The
                  ;; handler is for the ones it does not fail on: those deferred to the end of
                  ;; the unit (see above), and those the project's own files signal when they
                  ;; load, such as a toplevel WARN, which fail the load under #303 as well.
                  ;; Two of ASDF's own warnings are not about the project's code, so they are
                  ;; not counted: COMPILE-WARNED-WARNING reports that a file compiled with
                  ;; style-warnings only, and RECURSIVE-OPERATE that the loader was called from
                  ;; inside an ASDF operation, as it is when cons's own tests run under
                  ;; ASDF:TEST-SYSTEM.
                  (let ((caught '())
                        (recursive (uiop:find-symbol* :recursive-operate :asdf/operate nil)))
                    (handler-bind ((warning (lambda (w)
                                              (unless (or (typep w '(or style-warning
                                                                     uiop:compile-warned-warning))
                                                          (and recursive (typep w recursive)))
                                                (push w caught)))))
                      (with-compilation-unit (:override t)
                        (asdf :load-system name :force (if force-own own nil))))
                    (when caught
                      (error "Loading ~A signalled ~D WARNING~:P that its compilation did not fail on, either when the compilation unit ended or when one of its files was loaded:~{~%  ~A~}"
                             name (length caught) (reverse caught)))))
                (missing-p (c)
                  (typep c (uiop:find-symbol* :missing-component :asdf)))
                (find-sys (name)
                  ;; Retry after fetching whatever was missing. Bounded, and a name that
                  ;; is still missing after it was fetched is re-signalled rather than
                  ;; fetched again.
                  (let ((fetched '()))
                    (loop
                      (handler-case (return (asdf :find-system name))
                        (error (c)
                          (let ((req (and (missing-p c) (asdf :missing-requires c))))
                            (if (or (null req) (member req fetched :test (function equal))
                                    (> (length fetched) 50))
                                (error c)
                                (progn (push req fetched) (fetch req)))))))))
                (own-p (sys)
                  (let ((dir (asdf :system-source-directory sys)))
                    ;; Case-insensitive on Windows, where d:/ and D:/ are one directory.
                    (and dir
                         (let ((d (namestring (or (ignore-errors (truename dir)) dir))))
                           (and (>= (length d) (length root))
                                (if (uiop:os-windows-p)
                                    (string-equal root d :end2 (length root))
                                    (string= root d :end2 (length root))))))))
                (dep-name (spec)
                  ;; A DEPENDS-ON entry: a name, (:version NAME ...), (:feature F SPEC),
                  ;; or (:require NAME), which ASDF resolves itself and is skipped here.
                  (cond ((or (stringp spec) (symbolp spec)) (asdf :coerce-name spec))
                        ((and (consp spec) (eq (first spec) :version)) (dep-name (second spec)))
                        ((and (consp spec) (eq (first spec) :feature))
                         (and (uiop:featurep (second spec)) (dep-name (third spec))))
                        (t nil)))
                (test-systems (sys)
                  ;; The systems TEST-OP loads first: ((test-op (test-op "x/tests")) ...).
                  (loop for (op . deps) in (asdf :component-in-order-to sys)
                        when (string-equal (symbol-name op) "TEST-OP")
                          append (loop for (nil . names) in deps append names)))
                (visit (name)
                  (let ((name (asdf :coerce-name name)))
                    (unless (gethash name seen)
                      (setf (gethash name seen) t)
                      (let ((sys (find-sys name)))
                        (cond ((own-p sys)
                               (push name own)
                               (dolist (d (append (asdf :system-depends-on sys)
                                                  (and with-tests (test-systems sys))))
                                 (let ((n (dep-name d))) (when n (visit n)))))
                              (t (push name others))))))))
         (visit system)
         (dolist (name (reverse others)) (quiet name))
         (own-load system)
         (when with-tests
           (dolist (name (reverse own))
             (own-load name)))
         (values (reverse own) (reverse others)))))
  "The loader, as a form. See the comment above.")

(defvar %loader nil)

(defun load-system-strictly (system root &key force-own with-tests)
  "Load SYSTEM so that a compile WARNING in the project under ROOT fails the load, as
described above. FORCE-OWN recompiles the project's own systems; WITH-TESTS also loads the
systems SYSTEM's test-op names. Returns (values OWN-SYSTEMS OTHER-SYSTEMS)."
  (funcall (or %loader (setf %loader (compile nil +load-form+)))
           system (namestring root) force-own with-tests))

(defun %load-form-text (system root force-own with-tests)
  "The loader as source text for a subprocess --eval, called on these arguments."
  (with-standard-io-syntax
    (let ((*package* (find-package :cons/run))
          (*print-readably* nil))
      (prin1-to-string
       (list 'funcall +load-form+ system (namestring root) force-own with-tests)))))

(defvar *strict* nil
  "True under `cons --strict': recompile the project's own systems on every load.")

(defvar *root* nil
  "The project directory whose systems are the project's own, bound by RUN.")

(defun %ql (system &key with-tests)
  "Load SYSTEM (a name string) into the running image through LOAD-SYSTEM-STRICTLY."
  (load-system-strictly system (or *root* *default-pathname-defaults*)
                        :force-own *strict* :with-tests with-tests))

(defun %invoke (call params)
  "Perform a :call clause (FN-STRING . ARGS) in-process, resolving param args."
  (destructuring-bind (fn &rest args) call
    (multiple-value-bind (pkg sym) (%split-fn fn)
      (apply #'uiop:symbol-call pkg sym (%resolve-args args params)))))

(defun %run-test (system)
  "Convenience :test clause: quickload SYSTEM and run its ASDF test-op. Returns an exit
code (0 ok, 1 on error). NOTE: a suite (e.g. fiveam's default) that reports failures
without signalling still exits 0 here -- for exact exit codes use an :eval clause that
calls uiop:quit on the run status (see praxeon/cons.lisp)."
  (%ql system :with-tests t)
  (handler-case (progn (asdf:test-system system) 0)
    (error (e) (format *error-output* "~&cons test: ~A~%" e) 1)))

(defun %bespoke-repl ()
  "A minimal read-eval-print loop, used if the SBCL toplevel REPL is unavailable.
Keeps the process (and its background threads) alive; :quit or Ctrl-D exits."
  (loop
    (format t "~&cons> ") (finish-output)
    (let ((form (read *standard-input* nil :eof)))
      (when (or (eq form :eof)
                (and (symbolp form) (string-equal (string form) "QUIT")))
        (return))
      (handler-case
          (format t "~&~{~S~^~%~}~%" (multiple-value-list (eval form)))
        (error (e) (format t "~&; ~A~%" e)))))
  (uiop:quit 0))

(defun %enter-repl ()
  "Drop into a REPL so an interactive target's background threads keep serving. Tries
the real SBCL toplevel REPL first; falls back to a minimal loop."
  (finish-output)
  (format t "~&cons: entering the REPL; background tasks keep running. (:quit / Ctrl-D to exit)~%")
  (finish-output)
  (handler-case (uiop:symbol-call :sb-impl :toplevel-repl nil)
    (error () (%bespoke-repl))))

;;; --- subprocess (`--fresh` / :isolate / :sh) ------------------------------

(defun %target-dir (spec tgt)
  "The working directory for a :sh target: the spec dir, or its :cwd subdir."
  (if (spec:target-cwd tgt)
      (merge-pathnames (uiop:ensure-directory-pathname (spec:target-cwd tgt))
                       (spec:spec-dir spec))
      (spec:spec-dir spec)))

(defun %exec (args dir)
  "Run ARGS (a program + argv) in DIR, wired to the terminal; return the exit code."
  ;; Long arguments -- the loader form is one -- are shortened in this echo only.
  (format *error-output* "~&cons: ~{~A~^ ~}~%"
          (mapcar (lambda (a) (if (> (length a) 160) (format nil "~A ...)" (subseq a 0 60)) a))
                  args))
  (nth-value 2
    (uiop:run-program args :directory dir
                           :output :interactive :error-output :interactive
                           :input :interactive :ignore-error-status t)))

(defun %run-sh (spec tgt params)
  "Run a :sh target as a subprocess; return its exit code."
  (%exec (mapcar (lambda (tok) (%interpolate tok params)) (spec:target-sh tgt))
         (%target-dir spec tgt)))

(defun %quicklisp-setup ()
  (namestring (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))

(defun %lisp-literal (x)
  "Render a resolved :call arg as source text for a subprocess --eval form."
  (cond ((keywordp x) (format nil ":~A" (string-downcase (symbol-name x))))
        ((stringp x)  (format nil "~S" x))
        (t (princ-to-string x))))

(defun %subprocess-form (spec tgt params)
  "The Lisp form (as a string) a subprocess runs for TGT."
  (declare (ignore spec))
  (cond
    ((spec:target-eval tgt) (%interpolate (spec:target-eval tgt) params))
    ((spec:target-test tgt) (format nil "(asdf:test-system \"~A\")" (spec:target-test tgt)))
    ((spec:target-call tgt)
     (multiple-value-bind (pkg sym) (%split-fn (first (spec:target-call tgt)))
       (format nil "(~A:~A~{ ~A~})" pkg sym
               (mapcar #'%lisp-literal
                       (%resolve-args (rest (spec:target-call tgt)) params)))))
    (t "(values)")))

(defun %run-subprocess (spec tgt params)
  "Run a Lisp target's work in a fresh sbcl subprocess (the Makefile model). Omits
--non-interactive for interactive targets so sbcl lands in its own REPL."
  (let* ((dss (or (spec:spec-dss spec) 4096))
         (interactive (spec:target-interactive tgt))
         (args (append
                (list "sbcl" "--dynamic-space-size" (princ-to-string dss))
                (unless interactive (list "--non-interactive"))
                (list "--eval" (format nil "(load ~S)" (%quicklisp-setup)))
                ;; The same loader the in-process path uses, printed (see +LOAD-FORM+).
                (loop for s in (spec:target-load tgt)
                      append (list "--eval" (%load-form-text s (spec:spec-dir spec)
                                                             *strict* nil)))
                (when (spec:target-test tgt)
                  (list "--eval" (%load-form-text (spec:target-test tgt) (spec:spec-dir spec)
                                                  *strict* t)))
                (list "--eval" (%subprocess-form spec tgt params))
                (unless interactive (list "--eval" "(uiop:quit 0)")))))
    (%exec args (spec:spec-dir spec))))

;;; --- the dispatcher -------------------------------------------------------

(defun %require-target (spec name)
  "Find target NAME (string/symbol) in SPEC, or signal a helpful error listing the
available targets."
  (or (find (%kw name) (spec:spec-targets spec) :key #'spec:target-name)
      (error "no target ~A~%  available: ~{~A~^ ~}"
             (string-downcase (string name))
             (mapcar (lambda (tt) (string-downcase (string (spec:target-name tt))))
                     (spec:spec-targets spec)))))

(defun %perform (spec tgt params)
  "Do TGT's work IN-PROCESS and return an exit code. An interactive target does not
return -- it enters the REPL, which exits the process itself."
  (cond
    ;; :steps -- run sub-targets in order, short-circuiting on the first failure.
    ((spec:target-steps tgt)
     (dolist (s (spec:target-steps tgt) 0)
       (let ((code (%perform spec (%require-target spec s) params)))
         (unless (zerop code) (return code)))))
    ;; :sh -- always a subprocess.
    ((spec:target-sh tgt) (%run-sh spec tgt params))
    ;; Lisp work: load, then test / call / eval, then maybe a REPL.
    (t
     (dolist (s (spec:target-load tgt)) (%ql s))
     (cond
       ((spec:target-test tgt) (%run-test (spec:target-test tgt)))
       (t
        (when (spec:target-call tgt) (%invoke (spec:target-call tgt) params))
        (when (spec:target-eval tgt)
          (eval (read-from-string (%interpolate (spec:target-eval tgt) params))))
        (when (spec:target-interactive tgt) (%enter-repl))
        0)))))

(defun %lisp-target-p (tgt)
  "True when TGT does Lisp work (so --fresh/:isolate can route it to a subprocess)."
  (and (not (spec:target-sh tgt))
       (not (spec:target-steps tgt))
       (or (spec:target-load tgt) (spec:target-call tgt)
           (spec:target-test tgt) (spec:target-eval tgt))))

(defun %load-env (spec)
  "Load the spec's :env files (relative to the spec dir) into the environment."
  (dolist (f (spec:spec-env spec))
    (cons/env:load-dotenv :path (merge-pathnames f (spec:spec-dir spec)))))

(defun run (spec name params &key fresh strict)
  "Run target NAME (string) of SPEC with PARAMS (a CLI alist NAME . VALUE). Loads the
spec's .env first, then performs the target in-process -- or, with FRESH (or the
target's :isolate) and a Lisp target, in a subprocess sbcl. Quits the process with the
target's exit code; an interactive target instead stays in its REPL.

STRICT recompiles the project's own systems on every load, so a warning hidden in a current
fasl is seen; see LOAD-SYSTEM-STRICTLY."
  (handler-case
      (let ((tgt  (%require-target spec name))
            (pmap (%param-map spec params))
            (*strict* strict)
            (*root* (spec:spec-dir spec)))
        ;; pre-publication issue 240: before doing the work, say whether the framework this app is built
        ;; against has moved. Advisory, fail-open, no network -- see cons/upstream.
        (cons/upstream:report)
        (%load-env spec)
        (uiop:quit
         (if (and (or fresh (spec:target-isolate tgt)) (%lisp-target-p tgt))
             (%run-subprocess spec tgt pmap)
             (%perform spec tgt pmap))))
    (error (e)
      (format *error-output* "~&cons ~A: ~A~%" name e)
      (uiop:quit 1))))

;;; --- listing + CLI entry --------------------------------------------------

(defun list-targets (spec)
  "Print SPEC's targets and params (the `make help` equivalent), then quit 0."
  (format t "~&cons targets  (~A)~%~%" (enough-namestring (spec:spec-file spec)))
  (dolist (tgt (spec:spec-targets spec))
    (format t "  ~(~14A~)~@[~A~]~%"
            (string (spec:target-name tgt)) (spec:target-doc tgt)))
  (when (spec:spec-params spec)
    (format t "~%params  (pass as KEY=VALUE)~%")
    (dolist (p (spec:spec-params spec))
      (format t "  ~(~14A~)~@[~A~]~@[  [default ~A]~]~%"
              (string (spec:param-name p)) (spec:param-doc p) (spec:param-default p))))
  (when (spec:spec-default spec)
    (format t "~%default  ~{~(~A~)~^ ~}~%" (spec:spec-default spec)))
  (uiop:quit 0))

(defun %parse-kvs (args)
  "Parse trailing CLI args into a param alist (NAME . VALUE): KEY=VALUE (make-style),
--key=value, and --key value. Args in no such form are ignored."
  (let ((out '()) (i 0) (n (length args)))
    (loop while (< i n) do
      (let* ((a (nth i args)) (eqpos (position #\= a)))
        (cond
          ((and (> (length a) 2) (string= (subseq a 0 2) "--"))
           (let* ((body (subseq a 2)) (be (position #\= body)))
             (if be
                 (progn (push (cons (subseq body 0 be) (subseq body (1+ be))) out) (incf i))
                 (progn (push (cons body (or (nth (1+ i) args) "")) out) (incf i 2)))))
          (eqpos
           (push (cons (subseq a 0 eqpos) (subseq a (1+ eqpos))) out) (incf i))
          (t (incf i)))))
    (nreverse out)))

(defun cli-run (spec args &key fresh strict)
  "Top of the build-spec surface: ARGS is (TARGET . KEY=VALUE...). With no target,
list the targets; otherwise run it. Always quits the process."
  (let ((name (first args))
        (kvs  (%parse-kvs (rest args))))
    (if (null name)
        (list-targets spec)
        (run spec name kvs :fresh fresh :strict strict))))
