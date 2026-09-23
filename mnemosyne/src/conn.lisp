;;;; conn.lisp --- the effectful CL shell: connect / exec / query / transaction.
;;;;
;;;; The IO side of the neutral store protocol, over CL-DBI. A typed BACKEND
;;;; (mnemosyne/backend, Coalton) says WHICH store and how to reach it; here we open
;;;; the CL-DBI connection, run statements and queries, and scope transactions.
;;;; Postgres speaks the WIRE protocol (CL-DBI's :postgres driver is cl-postgres --
;;;; pure Lisp, no libpq); SQLite is a local file or :memory: for zero-ops dev; XTDB 2
;;;; (PG wire) rides the Postgres path later. Recoverable failure is a DB-ERROR
;;;; condition wrapping the driver's -- the condition system, not return codes. No IO
;;;; leaks into the Coalton core; no globals (a future Atropos component owns lifecycle).

(in-package #:mnemosyne/conn)

(define-condition db-error (error)
  ((message :initarg :message :reader db-error-message)
   (cause   :initarg :cause :initform nil :reader db-error-cause))
  (:report (lambda (c s) (format s "mnemosyne: ~A" (db-error-message c))))
  (:documentation
   "A recoverable database failure, wrapping the underlying driver condition (CAUSE).
Signalled by CONNECT / EXEC / QUERY so callers establish restarts around DB work rather
than parsing return codes."))

(defmacro %wrapping-db-errors (context &body body)
  "Run BODY, re-signalling any error as a DB-ERROR tagged with CONTEXT (keeping CAUSE);
an already-DB-ERROR passes through unchanged."
  (let ((e (gensym)))
    `(handler-case (progn ,@body)
       (db-error (,e) (error ,e))
       (error (,e)
         (error 'db-error :message (format nil "~A: ~A" ,context ,e) :cause ,e)))))

(defun %ms-since (start)
  "Milliseconds since START (an internal-real-time reading), rounded."
  (round (* 1000 (- (get-internal-real-time) start)) internal-time-units-per-second))

(defun %ensure-sqlite-directory (path)
  "Create the parent directory of a file-backed SQLite PATH if it does not exist, and
return PATH.

SQLite creates the database *file* but never the *folder*, so an ordinary layout like
\"./data/app.db\" fails a first run with a bare \"unable to open database file\" -- an error
naming neither the path nor the actual cause. Creating the parent is what every consumer
would otherwise write for itself.

The special names (\":memory:\" and SQLite's anonymous-temporary \"\") are not paths and are
left alone. This lives here in the CL shell, NOT in MAKE-SQLITE: that constructor is
Coalton, and the typed core does no IO."
  (if (or (string= path ":memory:") (string= path "")
          (and (> (length path) 5) (string= "file:" (subseq path 0 5))))   ; URI form: leave it
      path
      (let ((dir (uiop:pathname-directory-pathname (uiop:parse-native-namestring path))))
        (when (and dir (not (uiop:directory-exists-p dir)))
          (log:debug "db creating sqlite directory" :dir (namestring dir))
          (ensure-directories-exist dir))
        path)))

(defun %tls-available-p ()
  "Is a TLS implementation loaded in THIS image?

cl-postgres does not depend on cl+ssl; it looks the package up at connect time and
signals \"CL+SSL is not loaded\" if it is absent. So TLS here is a property of what the
application chose to load, exactly like the HTTP server in hyperion (#139) -- mnemosyne
must not drag cl+ssl (and OpenSSL, a native library) into every image that touches a
database, including desktop bundles, where an unvendorable .so is precisely what
ADR-0011 was about."
  (and (find-package '#:cl+ssl) t))

(defun %resolve-ssl (backend &optional (tls-available (%tls-available-p)))
  "The :USE-SSL keyword to hand the Postgres driver, applying the one rule that matters:
an OPPORTUNISTIC mode may quietly degrade; a GUARANTEED one may never.

  prefer, with no TLS library    -> :no, and a warning. `prefer' promises nothing by
                                   definition -- libpq itself falls back when the SERVER
                                   does not offer TLS, and \"this image has no TLS\" is
                                   the same kind of unavailability. Local development
                                   keeps working.
  require/verify-*, no library   -> DB-ERROR. Downgrading here would hand back a
                                   plaintext connection to a caller who asked for an
                                   encrypted one, and it would do so silently, on the
                                   deploy where it matters. An operator who wrote
                                   `sslmode=require' must never get plaintext instead.

TLS-AVAILABLE defaults to probing this image and is an argument so the rule above can be
TESTED rather than asserted -- both branches matter, and which one a test image would
otherwise take depends on whether something else happened to load cl+ssl."
  (let ((mode (be:backend-pg-ssl-driver backend)))
    (cond
      ((string= mode "no") :no)
      (tls-available (intern (string-upcase mode) :keyword))
      ((be:backend-pg-ssl-guaranteed? backend)
       ;; One FORMAT call per line, never a `~' continuation: on a CRLF checkout that
       ;; becomes an illegal `~<Return>' directive and the file fails to compile. See
       ;; AGENTS.md -- this is a rule the tree has already been bitten by.
       (error 'db-error
              :message
              (with-output-to-string (s)
                (format s "sslmode=~A needs TLS, and CL+SSL is not loaded in this image."
                        (be:backend-pg-ssl-mode backend))
                (format s "~%Add \"cl+ssl\" to your application's :depends-on.")
                (format s "~%mnemosyne deliberately does not: that would put OpenSSL on")
                (format s "~% the load path of every image that touches a database.")
                (format s "~%Refusing to connect in plaintext instead."))))
      (t
       (log:warn "db tls unavailable, connecting in plaintext"
                 :requested (be:backend-pg-ssl-mode backend))
       :no))))

(defun connect (backend)
  "Open a CL-DBI connection for BACKEND (a mnemosyne/backend:Backend). Postgres speaks
the wire protocol (cl-postgres, no libpq); SQLite is a local file or \":memory:\" -- and a
file path's parent directory is created if missing (see %ENSURE-SQLITE-DIRECTORY).

TLS follows the backend's own SSL mode; see %RESOLVE-SSL for what happens when the mode
asks for encryption this image cannot provide. Note that the driver's default is
plaintext, so passing nothing here is not neutral -- it actively requests no TLS, which
is why the argument is always supplied."
  (%wrapping-db-errors "connect"
    (let ((name (be:backend-name backend)))
      (cond
        ((string= name "sqlite")
         (log:debug "db connect" :backend name)
         (dbi:connect :sqlite3
                      :database-name (%ensure-sqlite-directory (be:sqlite-path backend))))
        ((string= name "postgres")
         ;; Resolved BEFORE the log line, so the line reports the mode actually used
         ;; rather than the one requested -- a log that says `require' about a plaintext
         ;; connection is worse than no log.
         (let ((ssl (%resolve-ssl backend)))
           (log:debug "db connect" :backend name :sslmode (string-downcase (symbol-name ssl)))
           (dbi:connect :postgres
                        :database-name (be:backend-pg-database backend)
                        :host          (be:backend-pg-host backend)
                        :port          (be:backend-pg-port backend)
                        :username      (be:backend-pg-user backend)
                        ;; The ONE place mnemosyne turns the password back into plaintext
                        ;; (#209): the driver needs a String. Everywhere else it stays an
                        ;; opaque SECRET, so no backtrace, log line or printed config can
                        ;; render it. `grep -rn reveal' enumerates the disclosure points.
                        :password      (sec:reveal (be:backend-pg-password backend))
                        :use-ssl       ssl)))
        (t (error 'db-error :message (format nil "unknown backend ~S" name)))))))

(defun disconnect (connection)
  "Close CONNECTION."
  (log:debug "db disconnect")
  (dbi:disconnect connection))

(defmacro with-connection ((var backend) &body body)
  "Bind VAR to a fresh connection for BACKEND, run BODY, and DISCONNECT on exit
(start/stop-symmetric; no globals). A future Atropos component wraps this in one line."
  `(let ((,var (connect ,backend)))
     (unwind-protect (progn ,@body)
       (disconnect ,var))))

(defun exec (connection sql &rest params)
  "Execute a statement SQL (DDL/DML) with positional PARAMS (\"?\" placeholders); return
the driver's result (typically the affected-row count). (CL-DBI takes the bind params as
a single list.)"
  (%wrapping-db-errors "exec"
    (let ((start (get-internal-real-time))
          ;; #165: what NIL, :TRUE and :FALSE mean is mnemosyne's decision, not the
          ;; driver's -- the drivers disagreed, and one of them corrupted data silently.
          (params (param:to-driver-params params (dbi:connection-driver-type connection))))
      (let ((result (dbi:do-sql connection sql params)))
        ;; SQL text but never PARAMS: bind values are the user data (emails, tokens,
        ;; password hashes) and must not be copied into logs.
        (log:debug "db exec" :sql sql :params (length params)
                             :rows result :ms (%ms-since start))
        result))))

(defun query (connection sql &rest params)
  "Run a SELECT SQL with positional PARAMS and return every row as a plist
(column-keyword -> value)."
  (%wrapping-db-errors "query"
    (let ((start (get-internal-real-time))
          ;; #165: normalised on the way out here too -- a WHERE clause binds values the
          ;; same way an INSERT does, so `(:= :col nil)` must mean the same thing in both.
          (params (param:to-driver-params params (dbi:connection-driver-type connection))))
      (let ((rows (param:from-driver-rows
                   (dbi:fetch-all (dbi:execute (dbi:prepare connection sql) params))
                   (dbi:connection-driver-type connection))))
        (log:debug "db query" :sql sql :params (length params)
                              :rows (length rows) :ms (%ms-since start))
        rows))))

(defmacro with-transaction ((connection) &body body)
  "Run BODY inside a transaction on CONNECTION: commit on normal exit, roll back on a
non-local exit."
  `(dbi:with-transaction ,connection ,@body))
