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
          (is (equal "2" (%template-field output "TEMPLATE-WORKERS"))
              "the :uv server has a pool of 2 workers: ~A" context)
          (is (equal "HTTP/1.1 200 OK" (%template-field output "TEMPLATE-STATUS"))
              "GET / answered 200: ~A" context)
          (is (equal "T" (%template-field output "TEMPLATE-PAGE"))
              "the page is the scaffolded one: ~A" context))))))

;;; --- cons bin carries libuv, and the binary serves away from the tree (#513) --------------
;;;
;;; The generated scripts/build-<name>.lisp, which `cons bin' runs, dumps bin/<name>. It now
;;; copies the libuv the image loads into bin/ and sets aion/platform:*search-source-tree* to NIL
;;; in the image. This test runs that script in a fresh sbcl, copies bin/ to a new temporary
;;; directory, which is not under the tree, starts the binary there, and asks it for /. With
;;; AION_UV_LIBRARY cleared and the tree not searched, the only libuv it can use is the one
;;; beside it, or a system copy; this machine's CI runners have none.

(defun %with-environment (bindings thunk)
  "Call THUNK with each (NAME . VALUE) in BINDINGS set in this process's environment, which
the processes it starts inherit, and put the previous values back afterwards. A VALUE of NIL
sets the variable to the empty string, which the loaders here treat as unset."
  (let ((previous (mapcar (lambda (b) (cons (car b) (uiop:getenv (car b)))) bindings)))
    (unwind-protect
         (progn (dolist (b bindings) (setf (uiop:getenv (car b)) (or (cdr b) "")))
                (funcall thunk))
      (dolist (b previous) (setf (uiop:getenv (car b)) (or (cdr b) ""))))))

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

(defun %run-binary (exe directory port log)
  "Start EXE in DIRECTORY with AION_UV_LIBRARY and HYPERION_SERVER cleared, and wait up to 60
seconds for it to answer GET / on PORT or to exit. Returns (values RESPONSE OUTPUT), where
RESPONSE is the response, :EXITED, or NIL, and OUTPUT is what the binary printed. The process is
stopped before this returns."
  (let ((process (%with-environment
                  '(("AION_UV_LIBRARY" . nil) ("HYPERION_SERVER" . nil))
                  (lambda ()
                    (uiop:launch-program (list (uiop:native-namestring exe))
                                         :directory directory :output log :error-output :output
                                         :if-output-exists :supersede))))
        (response nil))
    (unwind-protect
         (setf response
               (%wait-until (lambda ()
                              (or (ignore-errors (get* port "GET / HTTP/1.1" "Host: x"))
                                  (and (not (uiop:process-alive-p process)) :exited)))
                            :seconds 60))
      (ignore-errors (uiop:terminate-process process :urgent t))
      (ignore-errors (uiop:wait-process process)))
    (values response (if (probe-file log) (uiop:read-file-string log) ""))))

(defun %system-libuv-p ()
  "Whether this machine has a libuv the operating system's loader would find by name: on Linux
one that ldconfig lists, on macOS one in Homebrew's or /usr/local's lib directory. Windows has no
such place, so NIL there."
  (cond ((uiop:os-windows-p) nil)
        ((uiop:os-macosx-p)
         (or (probe-file "/opt/homebrew/lib/libuv.1.dylib") (probe-file "/usr/local/lib/libuv.1.dylib")))
        (t (let ((out (ignore-errors (uiop:run-program (list "ldconfig" "-p") :output :string
                                                       :ignore-error-status t))))
             (and out (search "libuv.so.1" out) t)))))

(test cons-bin-carries-libuv-and-the-binary-serves-outside-the-tree
  "The web template's build script copies libuv beside bin/<name>, and the binary, moved to a
directory outside the tree, answers GET / with 200 and its page (#513)."
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
          (when exe
            (multiple-value-bind (response output) (%run-binary exe away port log)
              (is (and response (not (eq response :exited)) (= 200 (status-of response)))
                  "the moved binary answered GET / with 200: ~S~%~A" response output)
              (is (and response (not (eq response :exited))
                       (search (format nil "~A is running" +template-project+) (body-of response)))
                  "with its page"))
            ;; Without the carried copy it must not fall back to the tree's vendor/, which this
            ;; machine has: the image was dumped with *search-source-tree* NIL (review of #524).
            ;; Where a system libuv is installed, the binary may load that instead, and this run
            ;; shows nothing either way, so it is skipped.
            (dolist (file (uiop:directory-files away))
              (when (uiop:string-prefix-p "libuv" (file-namestring file))
                (delete-file file)))
            (if (%system-libuv-p)
                (skip "A system libuv is installed here, so a binary without its own copy can load that one")
                (multiple-value-bind (response output) (%run-binary exe away port log)
                  (is (eq :exited response)
                      "without the carried libuv the binary does not serve: ~S~%~A" response output)
                  (is (search "LIBUV-NOT-FOUND" output)
                      "and stops with LIBUV-NOT-FOUND, not finding the tree's vendor/ copy: ~A"
                      output)))))))))
