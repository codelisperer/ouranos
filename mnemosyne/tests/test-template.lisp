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
  ;; Copies read the template's connection, so one copy is made at a time.
  (lock (sb-thread:make-mutex :name "sqlite template")))

(defmacro %closing-unless-returned ((var connection) &body body)
  "Bind VAR to CONNECTION and run BODY. When BODY does not return normally, disconnect VAR."
  (let ((done (gensym "DONE")))
    `(let ((,var ,connection) (,done nil))
       (unwind-protect (multiple-value-prog1 (progn ,@body) (setf ,done t))
         (unless ,done (conn:disconnect ,var))))))

(defun make-sqlite-template (migrations)
  "Open an in-memory SQLite database, apply MIGRATIONS (mnemosyne/backend:Migration values) to
it with mnemosyne/migrate:migrate, and return it as a SQLITE-TEMPLATE. Do this once per test
run, and close it with CLOSE-SQLITE-TEMPLATE when the run is over."
  (%closing-unless-returned (c (conn:connect (be:make-sqlite ":memory:")))
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
    ;; copy is complete; _finish releases the backup either way and reports any error.
    (let ((step (cffi:foreign-funcall "sqlite3_backup_step" :pointer backup :int -1 :int))
          (finish (cffi:foreign-funcall "sqlite3_backup_finish" :pointer backup :int)))
      (unless (and (= step 101) (zerop finish))
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
      (%backup (sqlite-template-connection template) c))
    c))

(defmacro with-sqlite-template-copy ((var template) &body body)
  "Run BODY with VAR bound to a connection from COPY-SQLITE-TEMPLATE, and disconnect it after."
  `(let ((,var (copy-sqlite-template ,template)))
     (unwind-protect (progn ,@body)
       (conn:disconnect ,var))))

(defun close-sqlite-template (template)
  "Disconnect TEMPLATE's database. Copies already made are not affected."
  (conn:disconnect (sqlite-template-connection template))
  nil)
