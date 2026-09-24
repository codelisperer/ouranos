;;;; sqlite-library.lisp --- the image can say which SQLite file it loaded, and its version (#129)
;;;;
;;;; What matters is where the answer came from. So the version is compared with what SQL
;;;; reports over a real connection, which is a second route to the same library, and the file
;;;; lookup is shown to give a different file for an address outside SQLite, which a function
;;;; that returned a fixed or remembered path would not.

(in-package #:mnemosyne/tests)

(in-suite mnemosyne)

(test the-reported-version-is-the-one-sql-queries-run-on
  (let ((report (mnemosyne/sqlite-library:loaded-library))
        (c (conn:connect (be:make-sqlite ":memory:"))))
    (unwind-protect
         (let ((from-sql (getf (first (conn:query c "SELECT sqlite_version() AS v")) :|v|)))
           (is (null (getf report :error)) "no error: ~A" (getf report :error))
           (is (stringp from-sql))
           (is (equal from-sql (getf report :version))
               "sqlite3_libversion() says ~S, SQL says ~S" (getf report :version) from-sql))
      (conn:disconnect c))))

(test the-reported-path-names-a-sqlite-library
  (let ((path (getf (mnemosyne/sqlite-library:loaded-library) :path)))
    (is (stringp path))
    (is (search "sqlite" (or path "") :test #'char-equal) "~S does not look like SQLite" path)))

(test the-file-lookup-answers-for-the-address-it-is-given
  ;; An address in the C runtime, not in SQLite, must be placed in a different file. A lookup
  ;; that returned the SQLite path whatever it was given would fail here and pass the others.
  (let* ((sqlite (getf (mnemosyne/sqlite-library:loaded-library) :path))
         (address (cffi:foreign-symbol-pointer "malloc"))
         (other (and address (mnemosyne/sqlite-library::%file-containing address))))
    (is (stringp other) "malloc could not be placed in any file")
    (is (not (equal other sqlite)) "malloc and sqlite3_open placed in the same file ~S" other)
    (is (not (search "sqlite" (or other "") :test #'char-equal)))))

(test a-missing-library-is-reported-not-signalled
  (let ((report (let ((mnemosyne/sqlite-library::+probe-symbol+ "no_such_symbol_issue_129"))
                  (mnemosyne/sqlite-library:loaded-library))))
    (is (null (getf report :path)))
    (is (null (getf report :version)))
    (is (search "no_such_symbol_issue_129" (or (getf report :error) "")))))

(test the-one-line-description-puts-the-path-last
  (is (equal "3.50.4 C:\\Program Files\\x\\sqlite3.dll"
             (mnemosyne/sqlite-library:describe-loaded-library
              '(:path "C:\\Program Files\\x\\sqlite3.dll" :version "3.50.4" :error nil))))
  (is (equal "UNKNOWN (not loaded)"
             (mnemosyne/sqlite-library:describe-loaded-library
              '(:path nil :version nil :error "not loaded")))))
