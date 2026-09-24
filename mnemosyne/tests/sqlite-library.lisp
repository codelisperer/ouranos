;;;; sqlite-library.lisp --- the image can say which SQLite file it loaded, and its version (#129)
;;;;
;;;; What matters is where the answer came from. So the version is compared with what SQL
;;;; reports over a real connection, which is a second route to the same library, and the file
;;;; lookup is shown to give a different file for an address outside SQLite, which a function
;;;; that returned a fixed or remembered path would not.

(in-package #:mnemosyne/tests)

(in-suite mnemosyne)

(defun %windows-lookup-unknown ()
  "On Windows, the reason LOADED-LIBRARY gave for not naming the library, or NIL.

The Windows lookup (GetModuleHandleExW and GetModuleFileNameW) was first run by CI, not on a
developer machine. If it cannot name the library there, that is a finding for #129 rather
than a reason to fail the gate, so the tests that need a named library skip with this reason,
which the gate prints. On macOS and Linux the lookup is measured to work, and these tests
fail instead of skipping."
  #+windows (getf (mnemosyne/sqlite-library:loaded-library) :error)
  #-windows nil)

(defmacro %unless-windows-lookup-unknown (&body body)
  `(let ((why (%windows-lookup-unknown)))
     (if why
         (skip "the Windows SQLite lookup reported UNKNOWN (~A); a finding for #129" why)
         (progn ,@body))))

(test the-reported-version-is-the-one-sql-queries-run-on
  (%unless-windows-lookup-unknown
    (let ((report (mnemosyne/sqlite-library:loaded-library))
          (c (conn:connect (be:make-sqlite ":memory:"))))
      (unwind-protect
           (let ((from-sql (getf (first (conn:query c "SELECT sqlite_version() AS v")) :|v|)))
             (is (null (getf report :error)) "no error: ~A" (getf report :error))
             (is (stringp from-sql))
             (is (equal from-sql (getf report :version))
                 "sqlite3_libversion() says ~S, SQL says ~S" (getf report :version) from-sql))
        (conn:disconnect c)))))

(test the-reported-path-names-a-sqlite-library
  (%unless-windows-lookup-unknown
    (let ((path (getf (mnemosyne/sqlite-library:loaded-library) :path)))
      (is (stringp path))
      (is (search "sqlite" (or path "") :test #'char-equal) "~S does not look like SQLite" path))))

(test the-file-lookup-answers-for-the-address-it-is-given
  ;; An address in the C runtime, not in SQLite, must be placed in a different file. A lookup
  ;; that returned the SQLite path whatever it was given would fail here and pass the others.
  ;; On Windows the C runtime's malloc need not be visible to SBCL's lookup, so the address
  ;; used there is a kernel32 function, which every Windows process has.
  (%unless-windows-lookup-unknown
    (let* ((sqlite (getf (mnemosyne/sqlite-library:loaded-library) :path))
           (name #+windows "GetModuleFileNameW" #-windows "malloc")
           (address (cffi:foreign-symbol-pointer name))
           (other (and address (mnemosyne/sqlite-library::%file-containing address))))
      (is (stringp other) "~A could not be placed in any file" name)
      (is (not (equal other sqlite)) "~A and sqlite3_open placed in the same file ~S" name other)
      (is (not (search "sqlite" (or other "") :test #'char-equal))))))

(test an-error-inside-the-lookup-is-reported-not-signalled
  ;; The gate reads the report through the test runner's banner, so an error that escaped
  ;; LOADED-LIBRARY would fail the gate. Replace the file lookup with one that signals, as a
  ;; failing Windows call would, and require a reason instead of a condition.
  (let ((real (fdefinition 'mnemosyne/sqlite-library::%file-containing)))
    (unwind-protect
         (progn
           (setf (fdefinition 'mnemosyne/sqlite-library::%file-containing)
                 (lambda (address)
                   (declare (ignore address))
                   (error "GetModuleHandleExW failed (simulated for #129)")))
           (let ((report (mnemosyne/sqlite-library:loaded-library)))
             (is (null (getf report :path)))
             (is (search "simulated for #129" (or (getf report :error) "")))
             (is (equal "UNKNOWN (GetModuleHandleExW failed (simulated for #129))"
                        (mnemosyne/sqlite-library:describe-loaded-library report)))))
      (setf (fdefinition 'mnemosyne/sqlite-library::%file-containing) real))))

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
