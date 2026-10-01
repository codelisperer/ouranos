;;;; server-uv-template-tests.lisp --- the cons web template starts on :uv and serves (#472).
;;;;
;;;; `cons template check' builds a template but does not start it, and cons/tests cannot load
;;;; hyperion (cons is to the left of it). So this suite, which already needs libuv, scaffolds
;;;; the web template with cons/init:scaffold, loads the generated project in a fresh sbcl
;;;; (server-uv-template-child.lisp), calls its START, and sends one request over a real
;;;; socket. The child prints one line per fact, and the test reads those lines: which backend
;;;; START chose, whether that server has a worker pool, the response's status line, and
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
   (list "sbcl" "--dynamic-space-size" "4096" "--non-interactive" "--no-userinit"
         "--eval" (format nil "(defparameter cl-user::*project-root* ~S)" (uiop:native-namestring root))
         "--eval" (format nil "(defparameter cl-user::*project-name* ~S)" +template-project+)
         "--load" (uiop:native-namestring
                   (asdf:system-relative-pathname :hyperion/server-uv/tests
                                                  "tests/server-uv-template-child.lisp")))
   :output :string :error-output :string :ignore-error-status t))

(test the-cons-web-template-starts-on-uv-with-workers-and-serves-its-page
  "A project scaffolded from the cons web template, loaded in a fresh image, starts on :uv with a
worker pool and answers GET / with 200 and its own page (#472)."
  (cons/tempdir:with-temporary-directory (work "uvplate")
    (let ((root (let ((*standard-output* (make-broadcast-stream)))
                  (cons/init:scaffold +template-project+ :template :web :target work))))
      (multiple-value-bind (output error-output code) (%run-template-child root)
        (let ((context (format nil "exit ~A~%--- stdout~%~A~%--- stderr (last 3000)~%~A" code output
                               (subseq error-output (max 0 (- (length error-output) 3000))))))
          (is (eql 0 code) "the child sbcl exited 0: ~A" context)
          (is (equal "UV" (%template-field output "TEMPLATE-BACKEND"))
              "START chose the :uv backend: ~A" context)
          (is (equal "T" (%template-field output "TEMPLATE-WORKERS"))
              "the :uv server has a worker pool: ~A" context)
          (is (equal "HTTP/1.1 200 OK" (%template-field output "TEMPLATE-STATUS"))
              "GET / answered 200: ~A" context)
          (is (equal "T" (%template-field output "TEMPLATE-PAGE"))
              "the page is the scaffolded one: ~A" context))))))
