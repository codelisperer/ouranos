;;;; server-uv-template-tests.lisp --- the cons web template starts on :uv and serves (#472).
;;;;
;;;; `cons template check' builds a template but does not start it, and cons/tests cannot load
;;;; hyperion (cons is to the left of it). So this suite, which already needs libuv, scaffolds
;;;; the web template with cons/init:scaffold, loads the generated project in a fresh sbcl
;;;; (server-uv-template-child.lisp), calls its START, and sends one request over a real
;;;; socket. The child prints one line per fact, and the test reads those lines: which backend
;;;; START chose, how many workers that server's pool has, the response's status line, and
;;;; whether the page is the scaffolded one.
;;;;
;;;; A fresh image, because the point is what the generated .asd pulls in on its own. This image
;;;; has hyperion/server-uv loaded whatever the template says, so here :uv would be available
;;;; even for a template that did not declare it.

(in-package #:hyperion/server-uv/tests)
(in-suite server-uv)

(defparameter +template-project+ "uvplate"
  "The name the web template is scaffolded under. Not the name of anything this image loads.")

(defun %template-field (output key)
  "The rest of the line in OUTPUT that starts with KEY and a space, or NIL."
  (let ((prefix (format nil "~A " key)))
    (dolist (line (uiop:split-string output :separator '(#\Newline #\Return)))
      (when (uiop:string-prefix-p prefix line)
        (return (subseq line (length prefix)))))))

(defun %run-template-child (root)
  "Run server-uv-template-child.lisp in a fresh sbcl on the project at ROOT.
Returns (values STDOUT STDERR EXIT-CODE)."
  (uiop:run-program
   ;; Neither init file: what the child loads is what the generated .asd asks for.
   (list "sbcl" "--dynamic-space-size" "4096" "--non-interactive" "--no-sysinit" "--no-userinit"
         "--eval" (format nil "(defparameter cl-user::*project-root* ~S)" (uiop:native-namestring root))
         "--eval" (format nil "(defparameter cl-user::*project-name* ~S)" +template-project+)
         "--load" (uiop:native-namestring
                   (asdf:system-relative-pathname :hyperion/server-uv/tests
                                                  "tests/server-uv-template-child.lisp")))
   :output :string :error-output :string :ignore-error-status t))

(test the-cons-web-template-starts-on-uv-with-workers-and-serves-its-page
  "A project scaffolded from the cons web template, loaded in a fresh image, starts on :uv with 2
workers and answers GET / with 200 and its own page (#472)."
  (cons/tempdir:with-temporary-directory (work "uvplate")
    (let ((root (let ((*standard-output* (make-broadcast-stream)))
                  (cons/init:scaffold +template-project+ :template :web :target work))))
      (multiple-value-bind (output error-output code) (%run-template-child root)
        (let ((context (format nil "exit ~A~%--- stdout~%~A~%--- stderr (last 3000)~%~A" code output
                               (subseq error-output (max 0 (- (length error-output) 3000))))))
          (is (eql 0 code) "the child sbcl exited 0: ~A" context)
          (is (equal "UV" (%template-field output "TEMPLATE-BACKEND"))
              "START chose the :uv backend: ~A" context)
          (is (equal "PREFERRED" (%template-field output "TEMPLATE-REASON"))
              "default-server chose :uv because it is preferred and libuv loaded: ~A" context)
          (is (search "server chosen" (concatenate 'string output error-output))
              "START logged the server it chose and why (#711): ~A" context)
          (is (search "reason=preferred" (concatenate 'string output error-output))
              "the log line carries the reason: ~A" context)
          (is (equal "2" (%template-field output "TEMPLATE-WORKERS"))
              "the :uv server has a pool of 2 workers: ~A" context)
          (is (equal "HTTP/1.1 200 OK" (%template-field output "TEMPLATE-STATUS"))
              "GET / answered 200: ~A" context)
          (is (equal "T" (%template-field output "TEMPLATE-PAGE"))
              "the page is the scaffolded one: ~A" context))))))

;;; --- the generated project's own tests pass (#711) ------------------------------------------
;;;
;;; `cons init' writes a tests/ suite into the web project. These tests scaffold the plain web
;;; template, web --db sqlite and web --db postgres, and run each project's own suite in a fresh
;;; sbcl (template-suite-child.lisp), which prints how many checks passed, failed and were
;;; skipped. The Postgres project's suite runs against MNEMOSYNE_TEST_PG_URL, the URL the gate
;;; gives the mnemosyne suites, on every leg where that is set; where it is not set the test is
;;; skipped, and so is counted as a skip rather than as a pass.

(defun %run-suite-child (root)
  "Run template-suite-child.lisp in a fresh sbcl on the project at ROOT.
Returns (values STDOUT STDERR EXIT-CODE)."
  (uiop:run-program
   (list "sbcl" "--dynamic-space-size" "4096" "--non-interactive" "--no-sysinit" "--no-userinit"
         "--eval" (format nil "(defparameter cl-user::*project-root* ~S)"
                          (uiop:native-namestring root))
         "--eval" (format nil "(defparameter cl-user::*project-name* ~S)" +template-project+)
         "--load" (uiop:native-namestring
                   (asdf:system-relative-pathname :hyperion/server-uv/tests
                                                  "tests/template-suite-child.lisp")))
   :output :string :error-output :string :ignore-error-status t))

(defun %check-generated-suite (options checks &key (skipped 0))
  "Scaffold the web template with OPTIONS, run the project's own suite in a fresh sbcl, and check
that it ran CHECKS checks, of which SKIPPED were skipped and the rest passed."
  (cons/tempdir:with-temporary-directory (work "uvsuite")
    (let ((root (let ((*standard-output* (make-broadcast-stream)))
                  (cons/init:scaffold +template-project+ :template :web :target work
                                                         :options options))))
      (multiple-value-bind (output error-output code) (%run-suite-child root)
        (let ((context (format nil "exit ~A~%--- stdout~%~A~%--- stderr (last 3000)~%~A"
                               code output
                               (subseq error-output (max 0 (- (length error-output) 3000))))))
          (flet ((field= (expected key)
                   (equal (princ-to-string expected) (%template-field output key))))
            (is (eql 0 code) "the child sbcl exited 0: ~A" context)
            (is (field= checks "SUITE-CHECKS") "the project's suite ran ~D checks: ~A"
                checks context)
            (is (field= (- checks skipped) "SUITE-PASSED") "~D passed: ~A"
                (- checks skipped) context)
            (is (field= 0 "SUITE-FAILED") "none failed: ~A" context)
            (is (field= skipped "SUITE-SKIPPED") "~D skipped: ~A" skipped context)))))))

(test the-web-projects-own-tests-pass
  "The plain web project's suite starts the app, checks server-uv answered GET /, and checks
that a second START is refused: 4 checks."
  (%check-generated-suite nil 4))

(test the-web-sqlite-projects-own-tests-pass
  "web --db sqlite: the page from server-uv; two visits counted in a session that the database
holds, through the one pool; a second START refused with the pool still open; a START that
fails closes the pool it opened; a user store that recovers from an error keeps the pool open;
a store that cannot be made leaves the database closed (#944); and a pool that cannot be closed
keeps the store's error and is still forgotten (#1006): 27 checks."
  (%check-generated-suite '(:db :sqlite) 27))

(defparameter +default-store-tables+
  (format nil "~{~A~^,~}" '("hyperion_sessions" "hyperion_users" "hyperion_role_events"
                           "hyperion_email_tokens" "hyperion_email_events"))
  "The tables a generated Postgres project's stores create, under their default names.")

(test the-web-postgres-project-builds-and-its-own-tests-pass
  "web --db postgres is scaffolded and built on every leg. Against the gate's Postgres its suite
runs the same 27 checks as SQLite. Without a Postgres URL, the project's eight tests skip
themselves, which this checks, and then this test records a skip."
  (let ((url (uiop:getenv "MNEMOSYNE_TEST_PG_URL")))
    (if (and url (plusp (length url)))
        ;; The child drops the default-named tables that were not there before it ran.
        (%with-environment `(("DATABASE_URL" . ,url)
                             ("TEMPLATE_DROP_NEW_TABLES" . ,+default-store-tables+))
                           (lambda () (%check-generated-suite '(:db :postgres) 27)))
        (progn
          (%with-environment '(("DATABASE_URL" . nil))
                             (lambda () (%check-generated-suite '(:db :postgres) 8 :skipped 8)))
          (skip (concatenate 'string "MNEMOSYNE_TEST_PG_URL is not set -- the Postgres project "
                             "was built, and its tests were not run"))))))

;;; --- cons bin carries libuv, and the binary serves away from the tree (#513) --------------
;;;
;;; The generated scripts/build-<name>.lisp, which `cons bin' runs, dumps bin/<name>. It now
;;; copies the libuv the image loads into bin/ and sets aion/platform:*search-source-tree* to NIL
;;; in the image. This test runs that script in a fresh sbcl, copies bin/ to a new temporary
;;; directory, which is not under the tree, starts the binary there, and asks it for /. While it
;;; runs, the test reads which libuv file the process has mapped, and checks that it is the copy
;;; beside the binary. AION_UV_LIBRARY is cleared, and the tree is not searched. The Linux and
;;; macOS CI runners have a system libuv and Windows runners do not, so the mapped-file check is
;;; what shows the copy was used on every leg; the run without the copy is skipped where a system
;;; libuv would be found (review of #524).

(defun %unsetenv (name)
  "Remove NAME from this process's environment. Through sb-posix, which UIOP's own (SETF GETENV)
already requires on SBCL, on Windows too; a child process then sees NAME as not defined."
  (uiop:symbol-call :sb-posix :unsetenv name))

(defun %with-environment (bindings thunk)
  "Call THUNK with each (NAME . VALUE) in BINDINGS set in this process's environment, which
the processes it starts inherit, and put the previous values back afterwards. A VALUE of NIL
sets the variable to the empty string, which the loaders here treat as unset. A variable that
was not set before is unset again afterwards, not left as the empty string (#564)."
  (let ((previous (mapcar (lambda (b) (cons (car b) (uiop:getenv (car b)))) bindings)))
    (unwind-protect
         (progn (dolist (b bindings) (setf (uiop:getenv (car b)) (or (cdr b) "")))
                (funcall thunk))
      (dolist (b previous)
        (if (cdr b)
            (setf (uiop:getenv (car b)) (cdr b))
            (%unsetenv (car b)))))))

(test with-environment-unsets-a-variable-that-was-not-set
  "%WITH-ENVIRONMENT puts back each variable as it found it: a value that was set is restored,
and a variable that was not set is removed, so a later test that asks whether it is set at all
gets the true answer (#564). This tells the fix from the old code only on Linux and macOS: on
Windows, setting a variable to the empty string removes it, so the old code's empty string
already left it unset there."
  (let ((unset "OURANOS_TEST_564_UNSET")
        (set "OURANOS_TEST_564_SET"))
    (%unsetenv unset)
    (setf (uiop:getenv set) "before")
    (unwind-protect
         (progn
           (%with-environment `((,unset . "during") (,set . nil))
                              (lambda ()
                                (is (equal "during" (uiop:getenv unset)))
                                ;; Windows removes a variable that is set to the empty
                                ;; string, so there it reads as unset.
                                (is (member (uiop:getenv set) '(nil "") :test #'equal))))
           (is (null (uiop:getenv unset)) "a variable that was not set is not set afterwards")
           (is (equal "before" (uiop:getenv set)) "a variable that was set has its value back"))
      (%unsetenv unset)
      (%unsetenv set))))

(defun %copy-directory (from to)
  "Copy FROM's files, and those of its subdirectories, into TO."
  (dolist (file (uiop:directory-files from))
    (uiop:copy-file file (merge-pathnames (file-namestring file) (ensure-directories-exist to))))
  (dolist (sub (uiop:subdirectories from))
    (%copy-directory sub (merge-pathnames (format nil "~A/" (car (last (pathname-directory sub))))
                                          to))))

(defun %bin-executable (bin)
  (or (probe-file (merge-pathnames (format nil "~A.exe" +template-project+) bin))
      (probe-file (merge-pathnames +template-project+ bin))))

(defun %mapped-libuv (pid)
  "The libuv files the process PID has mapped, as native namestrings: read from /proc/PID/maps
on Linux, from lsof on macOS, and from the process's module list on Windows."
  (flet ((libuv-p (path) (search "libuv" (file-namestring (uiop:parse-native-namestring path)))))
    (remove-duplicates
     (cond
       ((uiop:os-windows-p)
        (remove-if-not
         #'libuv-p
         (uiop:split-string
          (uiop:run-program
           (list "powershell" "-NoProfile" "-NonInteractive" "-Command"
                 (format nil "(Get-Process -Id ~D).Modules | ForEach-Object { $_.FileName }" pid))
           :output :string :ignore-error-status t)
          :separator '(#\Newline #\Return))))
       ((uiop:os-macosx-p)
        (loop for line in (uiop:split-string
                           (uiop:run-program (list "lsof" "-p" (princ-to-string pid) "-Fn")
                                             :output :string :ignore-error-status t)
                           :separator '(#\Newline))
              when (and (uiop:string-prefix-p "n/" line) (libuv-p (subseq line 1)))
                collect (subseq line 1)))
       (t
        (with-open-file (in (format nil "/proc/~D/maps" pid) :if-does-not-exist nil)
          (when in
            (loop for line = (read-line in nil) while line
                  for slash = (position #\/ line)
                  when (and slash (libuv-p (subseq line slash)))
                    collect (subseq line slash))))))
     :test #'string=)))

(defun %run-binary (exe port log)
  "Start EXE with AION_UV_LIBRARY and HYPERION_SERVER cleared, and wait up to 60 seconds for it to
answer GET / on PORT or to exit. Returns (values RESPONSE OUTPUT MAPPED), where RESPONSE is the
response, :EXITED, or NIL, OUTPUT is what the binary printed, and MAPPED is the list of libuv
files the process had mapped when it answered (%MAPPED-LIBUV). The process is stopped before this
returns.

The working directory is the parent of EXE's directory. On macOS DYLD_LIBRARY_PATH is cleared,
because a libuv in a directory it names would be found first (Copilot's review of train 28), and
DYLD_FALLBACK_LIBRARY_PATH
is an empty directory. Otherwise the loader could find a libuv in the working directory or in
Homebrew's lib directory, and the run would pass without using the copy beside EXE (review of
#524, where the hub tested this on macOS)."
  (let* ((directory (uiop:pathname-parent-directory-pathname (uiop:pathname-directory-pathname exe)))
         (process (%with-environment
                   (append '(("AION_UV_LIBRARY" . nil) ("HYPERION_SERVER" . nil))
                           (when (uiop:os-macosx-p) '(("DYLD_LIBRARY_PATH" . nil)
                                                      ("DYLD_FALLBACK_LIBRARY_PATH" . "/var/empty"))))
                   (lambda ()
                     (uiop:launch-program (list (uiop:native-namestring exe))
                                          :directory directory :output log :error-output :output
                                          :if-output-exists :supersede))))
         (response nil)
         (mapped nil))
    (unwind-protect
         (progn
           (setf response
                 (%wait-until (lambda ()
                                (or (ignore-errors (get* port "GET / HTTP/1.1" "Host: x"))
                                    (and (not (uiop:process-alive-p process)) :exited)))
                              :seconds 60))
           (when (and response (not (eq response :exited)))
             (setf mapped (ignore-errors (%mapped-libuv (uiop:process-info-pid process))))))
      (ignore-errors (uiop:terminate-process process :urgent t))
      (ignore-errors (uiop:wait-process process)))
    (values response (if (probe-file log) (uiop:read-file-string log) "") mapped)))

(defun %system-libuv-p ()
  "Whether a binary without its own libuv could still find one, started as %RUN-BINARY starts
it. On Linux: one that ldconfig lists, or one in a directory on LD_LIBRARY_PATH. On Windows: a
libuv.dll in a directory on PATH. On macOS, NIL: %RUN-BINARY empties DYLD_FALLBACK_LIBRARY_PATH,
which is where Homebrew's copy would be found. Where ldconfig cannot be run, T, so that the run
is skipped rather than failed for a reason this test cannot see."
  (flet ((on-path-p (variable name)
           (some (lambda (dir)
                   (and (plusp (length dir))
                        (probe-file (merge-pathnames name (uiop:ensure-directory-pathname
                                                           (uiop:parse-native-namestring dir))))))
                 (uiop:split-string (or (uiop:getenv variable) "")
                                    :separator (if (uiop:os-windows-p) ";" ":")))))
    (cond ((uiop:os-windows-p) (and (on-path-p "PATH" "libuv.dll") t))
          ((uiop:os-macosx-p) nil)
          (t (let ((out (ignore-errors (uiop:run-program (list "ldconfig" "-p") :output :string
                                                         :ignore-error-status t))))
               (or (null out)
                   (and (search "libuv.so.1" out) t)
                   (and (on-path-p "LD_LIBRARY_PATH" "libuv.so.1") t)))))))

(test the-cons-bin-build-script-carries-libuv-and-the-moved-binary-serves-with-that-copy
  "The web template's build script, run as `cons bin' runs it, copies libuv beside bin/<name>.
The binary, moved to a directory outside the tree, answers GET / with 200 and its page, and the
libuv it has mapped is the copy beside it. Where no system libuv would be found, the binary
without that copy stops with LIBUV-NOT-FOUND instead of using the tree's (#513, #524)."
  (cons/tempdir:with-temporary-directory (work "uvplate-bin")
    (cons/tempdir:with-temporary-directory (away "uvplate-away")
      (let* ((root (let ((*standard-output* (make-broadcast-stream)))
                     (cons/init:scaffold +template-project+ :template :web :target work)))
             (tree (uiop:pathname-parent-directory-pathname
                    (asdf:system-source-directory :hyperion)))
             (registry (format nil "(:source-registry (:tree ~S) (:tree ~S) :inherit-configuration)"
                               (uiop:native-namestring root) (uiop:native-namestring tree)))
             (bin (merge-pathnames "bin/" root)))
        ;; Build, as `cons bin' does: the generated script, in the project's directory.
        (multiple-value-bind (out err code)
            (%with-environment
             `(("CL_SOURCE_REGISTRY" . ,registry) ("AION_UV_LIBRARY" . nil))
             (lambda ()
               (uiop:run-program
                (list "sbcl" "--dynamic-space-size" "4096" "--non-interactive" "--no-sysinit"
                      "--no-userinit" "--load"
                      (uiop:native-namestring
                       (merge-pathnames (format nil "scripts/build-~A.lisp" +template-project+) root)))
                :directory root :output :string :error-output :string :ignore-error-status t)))
          (is (eql 0 code) "the build script exited 0: exit ~A~%~A~%~A" code
              (subseq out (max 0 (- (length out) 3000))) (subseq err (max 0 (- (length err) 3000)))))
        (let ((carried (remove-if-not (lambda (f) (uiop:string-prefix-p "libuv" (file-namestring f)))
                                      (uiop:directory-files bin))))
          (is-true carried "libuv is in bin/: ~S" (mapcar #'file-namestring (uiop:directory-files bin)))
          (is-true (uiop:directory-files (merge-pathnames "LICENSES/" bin))
                   "with its license under bin/LICENSES/"))
        (is-true (%bin-executable bin) "and the binary was dumped")
        ;; Run it from somewhere else. UIOP:COPY-FILE does not keep the execute bit on Unix
        ;; (cp -r, which a person would use, does), so it is set again on the copy.
        (%copy-directory bin away)
        (let ((exe (%bin-executable away)))
          (when (and exe (not (uiop:os-windows-p)))
            (uiop:run-program (list "chmod" "755" (uiop:native-namestring exe)))))
        (let ((exe (%bin-executable away))
              (port (cons/init::dev-port +template-project+))
              (log (merge-pathnames "run.log" work)))
          ;; The binary always serves on its dev port. Another run of this suite, in another
          ;; worktree on this machine, would answer there too, and this test would read its
          ;; answer (review of #524).
          (is (null (ignore-errors (get* port "GET / HTTP/1.1" "Host: x")))
              "nothing answers on 127.0.0.1:~D before the binary starts; another run of this suite may be using the port" port)
          (when exe
            (multiple-value-bind (response output mapped) (%run-binary exe port log)
              (is (and response (not (eq response :exited)) (= 200 (status-of response)))
                  "the moved binary answered GET / with 200: ~S~%~A" response output)
              (is (and response (not (eq response :exited))
                       (search (format nil "~A is running" +template-project+) (body-of response)))
                  "with its page")
              (is (search "path=/ status=200" output)
                  "and the binary's own log has the request, so the answer came from it: ~A" output)
              (is (and (= 1 (length mapped))
                       (uiop:pathname-equal
                        (uiop:pathname-directory-pathname (truename (uiop:parse-native-namestring (first mapped))))
                        (truename away)))
                  "the libuv the binary mapped is the copy beside it in ~A: ~S"
                  (uiop:native-namestring away) mapped))
            ;; Without the carried copy it must not fall back to the tree's vendor/, which this
            ;; machine has: the image was dumped with *search-source-tree* NIL (review of #524).
            ;; Where a system libuv is installed, the binary may load that instead, and this run
            ;; shows nothing either way, so it is skipped.
            ;; Retried: on a Windows runner the DLL stayed locked for a moment after the first
            ;; run was stopped ("Access is denied", run 36955970876), though not here.
            (dolist (file (uiop:directory-files away))
              (when (uiop:string-prefix-p "libuv" (file-namestring file))
                (is-true (%wait-until (lambda () (ignore-errors (delete-file file) t)) :seconds 20)
                         "the carried ~A could be deleted for the second run" (file-namestring file))))
            (if (%system-libuv-p)
                (skip "A system libuv is installed here, so a binary without its own copy can load that one")
                (multiple-value-bind (response output) (%run-binary exe port log)
                  (is (eq :exited response)
                      "without the carried libuv the binary does not serve: ~S~%~A" response output)
                  (is (search "LIBUV-NOT-FOUND" output)
                      "and stops with LIBUV-NOT-FOUND, not finding the tree's vendor/ copy: ~A"
                      output)))))))))
