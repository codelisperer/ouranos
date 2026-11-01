;;;; test-template.lisp --- migrate one SQLite database per test run and copy it for each test.
;;;;
;;;; A test fixture that opens a fresh in-memory SQLite database for every test runs the whole
;;;; migration list every time. A consuming app with about 300 migrations measured about 90 ms
;;;; per test for that alone (#1047). MAKE-SQLITE-TEMPLATE runs the migrations once, into an
;;;; in-memory database; COPY-SQLITE-TEMPLATE gives a test its own in-memory database with the
;;;; same contents, copied with SQLite's online backup API (sqlite3_backup_init, _step and
;;;; _finish). The copy is a separate database: what a test writes is not seen by the template
;;;; or by any other copy.
;;;;
;;;; Test support, not part of mnemosyne's core API, so an app loads it only in its test
;;;; system. SQLite only for now; Postgres would use CREATE DATABASE ... TEMPLATE, or a
;;;; transaction rolled back after each test.

(cl:defpackage #:mnemosyne/test-template
  (:use #:cl)
  (:local-nicknames (#:conn #:mnemosyne/conn)
                    (#:be #:mnemosyne/backend)
                    (#:mig #:mnemosyne/migrate))
  (:export #:sqlite-template #:make-sqlite-template #:sqlite-template-applied
           #:copy-sqlite-template #:with-sqlite-template-copy #:close-sqlite-template))

(in-package #:mnemosyne/test-template)

(defstruct (sqlite-template (:constructor %make-sqlite-template (connection applied))
                            (:copier nil))
  "An in-memory SQLite database with the migrations applied, from MAKE-SQLITE-TEMPLATE.
APPLIED is the list of migration ids MIGRATE applied to it."
  connection
  (applied '() :type list)
  ;; Copies read the template's connection, so one copy is made at a time, and closing waits
  ;; for a copy in progress. CLOSED is read and set only while LOCK is held.
  (lock (sb-thread:make-mutex :name "sqlite template"))
  (closed nil))

(defmacro %closing-unless-returned ((var connection) &body body)
  "Bind VAR to CONNECTION and run BODY. When BODY does not return normally, disconnect VAR."
  (let ((done (gensym "DONE")))
    `(let ((,var ,connection) (,done nil))
       (unwind-protect (multiple-value-prog1 (progn ,@body) (setf ,done t))
         (unless ,done (conn:disconnect ,var))))))

(defun make-sqlite-template (migrations &key setup)
  "Open an in-memory SQLite database, apply MIGRATIONS (mnemosyne/backend:Migration values) to
it with mnemosyne/migrate:migrate, and return it as a SQLITE-TEMPLATE. Do this once per test
run, and close it with CLOSE-SQLITE-TEMPLATE when the run is over.

SETUP, when given, is called with the new connection before MIGRATE, for settings the app
makes on its own connections and its migrations rely on, such as PRAGMA foreign_keys = ON
so that a migration's deletes cascade. Settings of this kind belong to the connection: a copy
does not have them, and a test that needs them sets them on its copy."
  (%closing-unless-returned (c (conn:connect (be:make-sqlite ":memory:")))
    (when setup (funcall setup c))
    (%make-sqlite-template c (mig:migrate (be:make-sqlite ":memory:") c migrations))))

(defun %sqlite-handle (connection)
  "The sqlite3 database pointer behind a mnemosyne SQLite CONNECTION. cl-sqlite keeps it in a
slot it does not export, as mnemosyne/conn's %SQLITE-AUTOCOMMIT-P also reads it."
  (slot-value (dbi:connection-handle connection) 'sqlite::handle))

(defun %backup (from to)
  "Copy the whole main database of the connection FROM into the connection TO, replacing TO's
contents. Signals a mnemosyne/conn:db-error naming the SQLite result code when it fails."
  (let* ((dest (%sqlite-handle to))
         (backup (cffi:foreign-funcall "sqlite3_backup_init"
                                       :pointer dest :string "main"
                                       :pointer (%sqlite-handle from) :string "main"
                                       :pointer)))
    (when (cffi:null-pointer-p backup)
      (error 'conn:db-error
             :message (format nil "copying an SQLite template: backup init failed, code ~D"
                              (cffi:foreign-funcall "sqlite3_errcode" :pointer dest :int))))
    ;; -1 copies every page in one step. SQLITE_DONE (101) is the only result that means the
    ;; copy is complete. _finish releases the backup and reports any error; it runs from the
    ;; cleanup, so a non-local exit between init and finish does not leave the backup open.
    (let ((step nil) (finish nil))
      (unwind-protect
           (setf step (cffi:foreign-funcall "sqlite3_backup_step" :pointer backup :int -1 :int))
        (setf finish (cffi:foreign-funcall "sqlite3_backup_finish" :pointer backup :int)))
      (unless (and (eql step 101) (eql finish 0))
        (error 'conn:db-error
               :message (format nil "copying an SQLite template: backup step ~D, finish ~D"
                                step finish))))))

(defun copy-sqlite-template (template)
  "A new connection to an in-memory SQLite database holding a copy of TEMPLATE's database:
its tables, its rows and its schema_migrations. The copy is independent, so nothing written
to it is seen by TEMPLATE or by another copy. The caller disconnects it, or uses
WITH-SQLITE-TEMPLATE-COPY."
  (%closing-unless-returned (c (conn:connect (be:make-sqlite ":memory:")))
    (sb-thread:with-mutex ((sqlite-template-lock template))
      (when (sqlite-template-closed template)
        (error 'conn:db-error :message "copying an SQLite template: the template is closed"))
      (%backup (sqlite-template-connection template) c))
    c))

(defmacro with-sqlite-template-copy ((var template) &body body)
  "Run BODY with VAR bound to a connection from COPY-SQLITE-TEMPLATE, and disconnect it after."
  `(let ((,var (copy-sqlite-template ,template)))
     (unwind-protect (progn ,@body)
       (conn:disconnect ,var))))

(defun close-sqlite-template (template)
  "Disconnect TEMPLATE's database, after any copy in progress finishes. Copies already made are
not affected; a later COPY-SQLITE-TEMPLATE signals mnemosyne/conn:db-error. Closing twice
does nothing the second time."
  (sb-thread:with-mutex ((sqlite-template-lock template))
    (unless (sqlite-template-closed template)
      (setf (sqlite-template-closed template) t)
      (conn:disconnect (sqlite-template-connection template))))
  nil)
