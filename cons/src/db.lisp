;;;; db.lisp --- `cons db-repl` / `cons db-url`: a database session per environment.
;;;;
;;;; Config is already cons's domain (cons/env owns .env), and every app on the stack needs
;;;; the same thing: open a shell against the database an environment is *actually* using,
;;;; without anyone reciting hostnames, ports, sslmode and credentials from memory -- or
;;;; pasting a production URL into a terminal where it lands in shell history.
;;;;
;;;; This adds no database code. It resolves a URL, picks the right client binary, and
;;;; execs it. mnemosyne owns connections; cons owns config.
;;;;
;;;; Two things here are security decisions, not conveniences:
;;;;
;;;; 1. The password is NEVER in the child's argv. `psql "postgres://u:pw@host/db"` puts the
;;;;    credential in the process table, where any user on the machine can read it with ps.
;;;;    We strip it from the URL and hand it over through PGPASSWORD in the child's
;;;;    environment instead -- inherited by the child, invisible to ps, and gone when the
;;;;    process exits. No temp file, because a temp file outlives the session that made it.
;;;;
;;;; 2. Anything that is not dev is confirmed by typing the environment's name, and is
;;;;    read-only unless you ask otherwise. The cost of the prompt is two seconds; the cost
;;;;    of an UPDATE without a WHERE against prod is your afternoon.

(in-package #:cons/db)

(define-condition db-repl-error (error)
  ((message :initarg :message :reader db-repl-error-message))
  (:report (lambda (c s) (format s "cons db-repl: ~A" (db-repl-error-message c))))
  (:documentation "A recoverable failure resolving or opening a database session."))

(defun %fail (fmt &rest args)
  (error 'db-repl-error :message (apply #'format nil fmt args)))

;;; --- resolving the URL for an environment ---------------------------------

(defparameter *default-env* "dev"
  "The environment used when none is named.")

(defun %env-var-names (env)
  "The environment-variable names consulted for ENV, most specific first.

`dev` reads plain DATABASE_URL so the common case needs no suffix, and every environment
also accepts an explicit suffixed form -- DATABASE_URL_PROD wins over DATABASE_URL when you
ask for prod, so a developer's local default can never be mistaken for production."
  (let ((up (string-upcase env)))
    (if (string-equal env "dev")
        (list "DATABASE_URL_DEV" "DATABASE_URL")
        (list (format nil "DATABASE_URL_~A" up)))))

(defun resolve-url (&key (env *default-env*) (dotenv t))
  "The database URL for ENV, from the process environment (after loading .env when DOTENV).
Signals DB-REPL-ERROR naming the variables it looked for when none is set."
  (when dotenv (ignore-errors (cons/env:load-dotenv)))
  (let ((names (%env-var-names env)))
    (or (loop for n in names
              for v = (uiop:getenv n)
              when (and v (plusp (length v))) return v)
        (%fail "no database URL for environment ~S.~%  Looked for: ~{~A~^, ~}~%~
                Set it in .env (gitignored) or the platform's secrets."
               env names))))

;;; --- parsing (only as far as we need) -------------------------------------

(defstruct (db-target (:constructor %make-db-target (kind url password display)))
  "A resolved target: which client to run, the URL to hand it with the password REMOVED,
the password (a SECRET, passed through the environment and never argv), and a redacted
form for display.

The password is wrapped rather than stored as a String because this struct was ALREADY
careful in two ways -- the URL it carries has the password stripped out, and DISPLAY is a
separately redacted form -- and still disclosed it, because SBCL prints a structure by
printing its slots and a backtrace prints the frame's arguments (#209). Handling a
credential carefully in every path you think of does not cover printing, which is the
path nobody thinks of."
  (kind :postgres :type keyword)
  (url "" :type string)
  (password nil :type (or null sec:secret))
  (display "" :type string))

(defun %scheme (url)
  (let ((p (search "://" url)))
    (and p (string-downcase (subseq url 0 p)))))

(defun %split-credentials (url)
  "Return (values url-without-password password). Splits on the LAST @ before the host, so a
password containing @ (percent-encoded or not) does not confuse the split."
  (let* ((sep (search "://" url)))
    (if (null sep)
        (values url nil)
        (let* ((start (+ sep 3))
               (at (position #\@ url :from-end t))
               (slash (position #\/ url :start start)))
          (if (and at (or (null slash) (< at slash)))
              (let* ((userinfo (subseq url start at))
                     (colon (position #\: userinfo)))
                (if colon
                    (values (concatenate 'string (subseq url 0 start)
                                         (subseq userinfo 0 colon)
                                         (subseq url at))
                            (subseq userinfo (1+ colon)))
                    (values url nil)))
              (values url nil))))))

(defun %redact (url)
  "URL with any password replaced by ****, safe to print."
  (multiple-value-bind (stripped password) (%split-credentials url)
    (if (null password)
        stripped
        (let* ((sep (search "://" stripped))
               (start (+ sep 3))
               (at (position #\@ stripped :from-end t)))
          (concatenate 'string (subseq stripped 0 start)
                       (subseq stripped start at) ":****" (subseq stripped at))))))

(defun parse-target (url)
  "URL -> a DB-TARGET. Postgres URLs and SQLite (a sqlite: URL or a bare filesystem path --
a local dev database is usually just a path, not a URL)."
  (let ((scheme (%scheme url)))
    (cond
      ((member scheme '("postgres" "postgresql") :test #'equal)
       (multiple-value-bind (stripped password) (%split-credentials url)
         (%make-db-target :postgres stripped
                          (and password (sec:make-secret password))
                          (%redact url))))
      ((member scheme '("sqlite" "sqlite3" "file") :test #'equal)
       ;; sqlite:///abs/path or sqlite://relative -- take everything after the scheme
       (let ((path (subseq url (+ 3 (search "://" url)))))
         (%make-db-target :sqlite (if (and (plusp (length path)) (char= #\/ (char path 0)))
                                      path
                                      path)
                          nil url)))
      ((null scheme) (%make-db-target :sqlite url nil url))   ; a bare path
      (t (%fail "unsupported database URL scheme ~S (postgres and sqlite are supported)"
                scheme)))))

;;; --- the client binary ----------------------------------------------------

(defun %which (program)
  "PROGRAM's path if it is on PATH, else NIL."
  (let ((out (ignore-errors
              (uiop:run-program (list (if (uiop:os-windows-p) "where" "which") program)
                                :output '(:string :stripped t) :ignore-error-status t))))
    (and out (plusp (length out)) (first (uiop:split-string out :separator '(#\Newline))))))

(defun %client-for (kind)
  (let* ((program (ecase kind (:postgres "psql") (:sqlite "sqlite3")))
         (path (%which program)))
    (or path
        (%fail "~A is not on PATH.~%  ~A" program
               (ecase kind
                 (:postgres "Install the PostgreSQL client (macOS: brew install libpq, then link psql; Debian: apt install postgresql-client).")
                 (:sqlite "Install the SQLite CLI (macOS: brew install sqlite; Debian: apt install sqlite3)."))))))

;;; --- guards ---------------------------------------------------------------

(defun %dev-p (env) (string-equal env "dev"))

(defun %confirm-environment (env)
  "Require the operator to type ENV back. Returns T when confirmed.

A yes/no prompt is muscle memory; typing the word `prod` is a deliberate act, and it is the
last thing standing between a distracted afternoon and a production table."
  (format t "~&You are about to open a session against ~:@(~A~).~%" env)
  (format t "Type the environment name to continue (anything else aborts): ")
  (finish-output)
  (let ((typed (string-trim '(#\Space #\Tab #\Return) (or (read-line *standard-input* nil "") ""))))
    (or (string-equal typed env)
        (progn (format t "~&Aborted.~%") nil))))

;;; --- opening the session --------------------------------------------------

(defun %child-environment (extra)
  "The current environment plus EXTRA (a list of \"NAME=VALUE\"). Passing a credential this
way keeps it out of argv -- and therefore out of the process table."
  (append extra (sb-ext:posix-environ)))

(defun %postgres-argv (target read-only extra-args)
  (append (list (%client-for :postgres))
          ;; A URL without a password: the credential rides in PGPASSWORD instead.
          (list (db-target-url target))
          extra-args))

(defun %sqlite-argv (target read-only extra-args)
  (append (list (%client-for :sqlite))
          (when read-only (list "-readonly"))
          (list (db-target-url target))
          extra-args))

(defun db-repl (&key (env *default-env*) extra-args write (confirm t))
  "Open an interactive database session against ENV.

Non-dev environments are CONFIRMed (type the environment name) and are READ-ONLY unless
WRITE is true -- Postgres via default_transaction_read_only, SQLite via -readonly. Extra
arguments are passed through to the client, so `-c \"select 1\"` works.

Returns the client's exit code."
  (let* ((url (resolve-url :env env))
         (target (parse-target url))
         (read-only (and (not (%dev-p env)) (not write))))
    (when (and confirm (not (%dev-p env)))
      (unless (%confirm-environment env) (return-from db-repl 1)))
    ;; Banner: which environment, and the URL with the password removed. Never the password.
    (format t "~&cons db-repl: ~:@(~A~) -- ~A~@[ ~A~]~%"
            env (db-target-display target) (and read-only "[read-only]"))
    (finish-output)
    (let* ((kind (db-target-kind target))
           (argv (ecase kind
                   (:postgres (%postgres-argv target read-only extra-args))
                   (:sqlite   (%sqlite-argv target read-only extra-args))))
           (env-extra (append
                       (when (and (eq kind :postgres) (db-target-password target))
                         ;; The one disclosure point in cons: the child process needs the
                         ;; plaintext in its environment. Still never argv -- ps is
                         ;; world-readable (#209 keeps the wrapper; this line predates it).
                         (list (format nil "PGPASSWORD=~A"
                                       (sec:reveal (db-target-password target)))))
                       (when (and (eq kind :postgres) read-only)
                         ;; Session-wide, so it also covers what you type interactively --
                         ;; unlike passing -c, which would only guard one statement.
                         (list "PGOPTIONS=-c default_transaction_read_only=on")))))
      (let ((process (sb-ext:run-program (first argv) (rest argv)
                                         :environment (%child-environment env-extra)
                                         :input t :output t :error t   ; inherit the terminal
                                         :wait t :search nil)))
        (sb-ext:process-exit-code process)))))

(defun db-url (&key (env *default-env*) reveal)
  "Print the database URL for ENV -- REDACTED unless REVEAL. For scripting.

Redacted by default because the obvious use is pasting the output somewhere, and the
obvious somewhere is a terminal, a ticket, or a chat window."
  (let ((url (resolve-url :env env)))
    (format t "~&~A~%" (if reveal url (%redact url)))
    (finish-output)
    url))
