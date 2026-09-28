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
application chose to load, exactly like the HTTP server in hyperion (pre-publication issue 139) -- mnemosyne
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

(defvar *sqlite-busy-timeout-ms* 5000
  "Milliseconds a SQLite connection waits for another connection's write lock before failing
with BUSY (\"database is locked\"), or NIL to not wait at all.

SQLite's own default is to wait zero time, and mnemosyne used to leave it there (#223). Two
connections writing to one file at the same moment, such as a web server and a worker, or two
request threads, then failed with BUSY at once instead of waiting a few milliseconds for the
other to commit. Read when CONNECT opens the connection; bind it around CONNECT to change it for
one connection.")

(defvar *sqlite-library-logged* nil
  "True once CONNECT has logged which SQLite library this image uses (#129). Once per image,
because the library cannot change while the image runs.")

(defun %log-sqlite-library-once ()
  "Log, at :info and once per image, the SQLite library file and version the first SQLite
connection runs on. Logged when things work, not only when they fail: a working connection
through the wrong library looks exactly like one through the right library, and this line is
where the difference shows."
  (unless *sqlite-library-logged*
    (setf *sqlite-library-logged* t)
    (destructuring-bind (&key path version error) (sqlite-library:loaded-library)
      (if error
          (log:info "db sqlite library unknown" :reason error)
          (log:info "db sqlite library" :version version :path path)))))

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
         (log:debug "db connect" :backend name :busy-timeout-ms *sqlite-busy-timeout-ms*)
         (%log-sqlite-library-once)
         (dbi:connect :sqlite3
                      :database-name (%ensure-sqlite-directory (be:sqlite-path backend))
                      :busy-timeout *sqlite-busy-timeout-ms*))
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
                        ;; (pre-publication issue 209): the driver needs a String. Everywhere else it stays an
                        ;; opaque SECRET, so no backtrace, log line or printed config can
                        ;; render it. `grep -rn reveal' enumerates the disclosure points.
                        :password      (sec:reveal (be:backend-pg-password backend))
                        :use-ssl       ssl)))
        (t (error 'db-error :message (format nil "unknown backend ~S" name)))))))

(defun disconnect (connection)
  "Close CONNECTION."
  (log:debug "db disconnect")
  (dbi:disconnect connection))

(defmacro with-connection ((var source) &body body)
  "Bind VAR to a connection from SOURCE, run BODY, and give the connection back on exit.

SOURCE is a BACKEND or a POOL (see MAKE-POOL). A backend gives a fresh connection that is
DISCONNECTed on exit, as it always has. A pool lends one of its connections for the extent of
BODY and takes it back afterwards; see CALL-WITH-CONNECTION for what happens to it then."
  `(call-with-connection ,source (lambda (,var) ,@body)))

(defun exec (connection sql &rest params)
  "Execute a statement SQL (DDL/DML) with positional PARAMS (\"?\" placeholders); return
the driver's result (typically the affected-row count). (CL-DBI takes the bind params as
a single list.)"
  (%wrapping-db-errors "exec"
    (let ((start (get-internal-real-time))
          ;; pre-publication issue 165: what NIL, :TRUE and :FALSE mean is mnemosyne's decision, not the
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
          ;; pre-publication issue 165: normalised on the way out here too -- a WHERE clause binds values the
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

;;; --- the pool (#325) ------------------------------------------------------------
;;;
;;; An app that serves requests on more than one thread cannot share one connection: two
;;; threads would interleave statements on one wire, or one would run inside the other's
;;; transaction. The pool holds up to SIZE connections to one backend and lends each to one
;;; thread at a time, for the extent of a WITH-CONNECTION body.
;;;
;;; A CONNECTION GOES BACK ONLY IN A KNOWN STATE. Session state set by one borrower would
;;; otherwise reach the next one, and the case that matters most is a Postgres session-level
;;; advisory lock (praxeon/retrieval's per-corpus lock is one): the lock belongs to the
;;; connection, so a connection returned while holding it would give the lock to whichever
;;; request borrowed it next. So:
;;;
;;;   body exited normally -> %RESET-CONNECTION: roll back any open transaction and, on
;;;                           Postgres, RESET ALL and pg_advisory_unlock_all(). If the reset
;;;                           itself fails, the connection is closed instead.
;;;   body exited by a non-local exit (an error, a THROW, a thread being terminated)
;;;                        -> the connection is closed, not reset. The exit may have come in
;;;                           the middle of a statement, and a wire in that state cannot be
;;;                           reset reliably. The pool opens a new connection when one is
;;;                           next needed.
;;;
;;; SB-THREAD DIRECTLY, as aion/pool does and for its reason: the tree is SBCL-only, and this
;;; wants CONDITION-WAIT with a timeout.

(defvar *checkout-timeout-seconds* 30
  "Seconds a WITH-CONNECTION on a pool waits for a connection when every one is lent out,
before it signals POOL-EXHAUSTED. The default for MAKE-POOL's :CHECKOUT-TIMEOUT.")

(defvar *idle-check-seconds* 30
  "A pooled connection idle for longer than this is pinged before it is lent, and replaced if
the ping fails. The default for MAKE-POOL's :IDLE-CHECK.

Postgres servers, and the proxies in front of managed ones, close connections that have been
idle for a while. Without the check, the first request after a quiet period would fail on a
connection the server had already closed.")

(define-condition pool-exhausted (db-error)
  ((pool :initarg :pool :reader pool-exhausted-pool))
  (:documentation
   "Signalled by WITH-CONNECTION on a pool when no connection became free within the pool's
checkout timeout. A web app answers it with 503."))

(define-condition pool-closed (db-error)
  ((pool :initarg :pool :reader pool-closed-pool))
  (:documentation "Signalled by WITH-CONNECTION on a pool that CLOSE-POOL has closed."))

(defstruct (pool (:constructor %make-pool) (:copier nil) (:predicate poolp))
  "Up to SIZE connections to BACKEND, lent one thread at a time. Make it with MAKE-POOL."
  backend
  (size 1 :type (integer 1))
  (checkout-timeout 30 :type (real 0))
  (idle-check 30 :type (or null (real 0)))
  ;; Everything below is read and written with LOCK held.
  (idle '())                                   ; (connection . internal-real-time-returned)
  (open 0 :type unsigned-byte)                 ; lent + idle + being opened
  (closed nil)
  (lock (sb-thread:make-mutex :name "mnemosyne-pool"))
  (freed (sb-thread:make-waitqueue :name "mnemosyne-pool-freed")))

(defmethod print-object ((pool pool) stream)
  ;; The backend holds the password as an opaque SECRET, but a pool printed in a backtrace
  ;; has no reason to show the backend at all.
  (print-unreadable-object (pool stream :type t :identity t)
    (format stream "~A size ~D" (be:backend-name (pool-backend pool)) (pool-size pool))))

(defun make-pool (backend &key (size 10) (checkout-timeout *checkout-timeout-seconds*)
                               (idle-check *idle-check-seconds*))
  "A pool of up to SIZE connections to BACKEND. Connections are opened when first needed,
not here, so making a pool does no IO.

CHECKOUT-TIMEOUT is how many seconds WITH-CONNECTION waits for a free connection before it
signals POOL-EXHAUSTED. IDLE-CHECK is how many seconds a connection may sit idle before it is
pinged on its way out, or NIL to never ping.

A web server with N worker threads wants SIZE of at least N, or requests wait for each
other's connections. Close the pool with CLOSE-POOL."
  (check-type size (integer 1))
  (check-type checkout-timeout (real 0))
  (check-type idle-check (or null (real 0)))
  (%make-pool :backend backend :size size :checkout-timeout checkout-timeout
              :idle-check idle-check))

(defun pool-open-count (pool)
  "How many connections POOL has open: lent out, idle, or being opened."
  (sb-thread:with-mutex ((pool-lock pool)) (pool-open pool)))

(defun pool-idle-count (pool)
  "How many of POOL's open connections are idle, waiting to be lent."
  (sb-thread:with-mutex ((pool-lock pool)) (length (pool-idle pool))))

(defun %close-quietly (connection)
  "Disconnect CONNECTION, ignoring a failure: it is being thrown away, and a connection the
server already closed fails to close."
  (handler-case (disconnect connection)
    (error (e) (log:debug "db pool close failed" :condition (type-of e)))))

(defun %seconds-since (start)
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(defun %usable-p (connection returned-at pool)
  "Can CONNECTION, idle since RETURNED-AT, be lent? True unless it has been idle longer than
the pool's IDLE-CHECK and a ping says it is dead."
  (let ((check (pool-idle-check pool)))
    (or (null check)
        (<= (%seconds-since returned-at) check)
        (handler-case (and (dbi:ping connection) t)
          (error (e)
            (log:debug "db pool ping failed" :condition (type-of e))
            nil)))))

(defun %release-slot (pool)
  "Forget one open connection that has been closed or never opened, and wake a waiter, who
may now open one."
  (sb-thread:with-mutex ((pool-lock pool))
    (decf (pool-open pool))
    (sb-thread:condition-notify (pool-freed pool))))

(defun %take-or-reserve (pool deadline)
  "With POOL's lock held for its whole extent: return (:IDLE (connection . returned-at)) for an
idle connection, :OPEN when a slot has been reserved for a new connection, :CLOSED when the
pool is closed, or :TIMEOUT when DEADLINE passed with every connection lent out."
  (sb-thread:with-mutex ((pool-lock pool))
    (loop
      (cond
        ((pool-closed pool) (return :closed))
        ((pool-idle pool) (return (list :idle (pop (pool-idle pool)))))
        ((< (pool-open pool) (pool-size pool))
         (incf (pool-open pool))
         (return :open))
        (t
         (let ((left (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)))
           ;; On a timeout CONDITION-WAIT returns NIL WITHOUT the lock held, so nothing after
           ;; it may touch the pool; returning is all that is safe, and WITH-MUTEX allows it.
           (when (or (<= left 0)
                     (not (sb-thread:condition-wait (pool-freed pool) (pool-lock pool)
                                                    :timeout left)))
             (return :timeout))))))))

(defun %open-reserved (pool)
  "Open a connection for a slot %TAKE-OR-RESERVE reserved, releasing the slot if the connect
fails. Outside the lock: a connect is a network round trip, and holding the lock through it
would make every other checkout and return wait for it."
  (let ((connection nil))
    (unwind-protect (setf connection (connect (pool-backend pool)))
      (unless connection (%release-slot pool)))))

(defun %checkout (pool)
  "Take a connection from POOL: an idle one if there is one, a new one if fewer than SIZE are
open, otherwise wait up to the checkout timeout for one to come back. Signals POOL-CLOSED or
POOL-EXHAUSTED."
  (let ((deadline (+ (get-internal-real-time)
                     (round (* (pool-checkout-timeout pool) internal-time-units-per-second)))))
    (loop
      (let ((got (%take-or-reserve pool deadline)))
        (case (if (consp got) (first got) got)
          (:closed
           (error 'pool-closed :pool pool :message "the connection pool is closed"))
          (:timeout
           (error 'pool-exhausted
                  :pool pool
                  :message (format nil "no pooled connection became free within ~A seconds (pool size ~D)"
                                   (pool-checkout-timeout pool) (pool-size pool))))
          (:open (return (%open-reserved pool)))
          (:idle
           (destructuring-bind (connection . returned-at) (second got)
             (when (%usable-p connection returned-at pool)
               (return connection))
             ;; Dead: close it, give its slot back, and go round again. The next pass
             ;; takes another idle connection or opens a new one in the freed slot.
             (%close-quietly connection)
             (%release-slot pool))))))))

(defparameter +postgres-reset+
  '("CLOSE ALL"
    "SET SESSION AUTHORIZATION DEFAULT"
    "RESET ALL"
    "UNLISTEN *"
    "SELECT pg_advisory_unlock_all()"
    "DISCARD PLANS"
    "DISCARD TEMP"
    "DISCARD SEQUENCES")
  "What %RESET-CONNECTION runs on a Postgres connection after the rollback: the statements
Postgres documents DISCARD ALL as equivalent to, without DEALLOCATE ALL. The advisory-lock
release is the one #325 was ranked for.")

(defun %reset-connection (connection)
  "Put CONNECTION back into the state a new connection is in, as far as a later borrower can
tell: no open transaction and, on Postgres, no session settings, role, advisory locks,
temporary tables, LISTEN registrations or open cursors. Signals if it cannot.

On Postgres this is every step of DISCARD ALL except DEALLOCATE ALL. cl-dbi keeps the names of
prepared statements it has yet to deallocate and deallocates them during a later PREPARE on the
same connection; after a DEALLOCATE ALL those names no longer exist, and that later PREPARE,
in the next borrower's unrelated query, would fail. See +POSTGRES-RESET+.

The transaction is rolled back whether or not one is open. On Postgres a ROLLBACK outside a
transaction is answered with a warning, which is muffled here; cl-dbi only knows about
transactions opened by its own WITH-TRANSACTION in the current dynamic extent, so it cannot
be asked. SQLite refuses a ROLLBACK outside a transaction, so there the library's own
autocommit flag is asked first."
  (case (dbi:connection-driver-type connection)
    (:postgres
     (handler-bind ((warning #'muffle-warning))
       (dbi:do-sql connection "ROLLBACK"))
     (dolist (statement +postgres-reset+)
       (dbi:do-sql connection statement)))
    (:sqlite3
     (unless (%sqlite-autocommit-p connection)
       (dbi:do-sql connection "ROLLBACK")))
    (t
     (error "no way to reset a ~S connection for reuse"
            (dbi:connection-driver-type connection)))))

(defun %sqlite-autocommit-p (connection)
  "Is the SQLite CONNECTION outside a transaction? sqlite3_get_autocommit, asked of the
database handle cl-sqlite keeps in a slot it does not export."
  (not (zerop (cffi:foreign-funcall "sqlite3_get_autocommit"
                                    :pointer (slot-value (dbi:connection-handle connection)
                                                         'sqlite::handle)
                                    :int))))

(defun %checkin (pool connection clean-exit)
  "Take CONNECTION back into POOL. See the section header for why a non-local exit closes it."
  (let ((keep (and clean-exit
                   (handler-case (progn (%reset-connection connection) t)
                     (error (e)
                       (log:warn "db pool could not reset a connection, closing it"
                                 :condition (type-of e))
                       nil)))))
    (if (not keep)
        (progn (%close-quietly connection)
               (%release-slot pool))
        (let ((closed nil))
          (sb-thread:with-mutex ((pool-lock pool))
            (if (pool-closed pool)
                (progn (setf closed t) (decf (pool-open pool)))
                (push (cons connection (get-internal-real-time)) (pool-idle pool)))
            (sb-thread:condition-notify (pool-freed pool)))
          (when closed (%close-quietly connection))))))

(defvar *lent* '()
  "The connections lent to this thread, as an alist of (POOL . CONNECTION).

Bound by CALL-WITH-CONNECTION, never set, and a new thread starts with the global value,
empty. So a WITH-CONNECTION nested inside another on the same pool and thread reuses the
outer connection instead of taking a second one; taking a second would deadlock a pool of
one, and would put the inner body outside the outer body's transaction.")

(defgeneric call-with-connection (source function)
  (:documentation
   "Call FUNCTION with a connection from SOURCE, a BACKEND or a POOL, and give it back
afterwards. WITH-CONNECTION is the usual way to call this.")
  (:method ((pool pool) function)
    (let ((outer (cdr (assoc pool *lent* :test #'eq))))
      (if outer
          (funcall function outer)
          (let ((connection (%checkout pool))
                (clean-exit nil))
            (unwind-protect
                 (multiple-value-prog1
                     (let ((*lent* (acons pool connection *lent*)))
                       (funcall function connection))
                   (setf clean-exit t))
              (%checkin pool connection clean-exit))))))
  (:method (backend function)
    (let ((connection (connect backend)))
      (unwind-protect (funcall function connection)
        (disconnect connection)))))

(defun close-pool (pool)
  "Close POOL's idle connections and refuse further checkouts. A connection lent out when
this is called is closed when it comes back. Idempotent."
  (let ((idle '()))
    (sb-thread:with-mutex ((pool-lock pool))
      (setf (pool-closed pool) t
            idle (pool-idle pool)
            (pool-idle pool) '())
      (decf (pool-open pool) (length idle))
      (sb-thread:condition-broadcast (pool-freed pool)))
    (dolist (entry idle) (%close-quietly (car entry)))
    pool))
