;;;; template-tests.lisp --- `cons template check`: does the check actually check?
;;;;
;;;; These spawn a cold sbcl, so they are the slowest tests in the suite by a wide margin.
;;;; They earn it. `check` exists to be the thing that stops published templates rotting
;;;; (cons/docs/templates-design.md §5), and a check that cannot fail is worse than no
;;;; check -- it converts "nobody looked" into "it passed".

(in-package #:cons/tests)
(in-suite all)

(defmacro with-temp-template ((dir) &body body)
  "Create an empty template directory, bind DIR to it, and remove it afterwards.

Over CONS/TEMPDIR rather than a hand-rolled name, and not only for tidiness: the tests are
where an idiom gets copied from, so an unsafe one here outlives every fix in src (#204)."
  `(tempdir:with-temporary-directory (,dir "check")
     (ensure-directories-exist (merge-pathnames "files/src/" ,dir))
     ,@body))

(defun %write-template-file (dir relpath content)
  (let ((path (merge-pathnames relpath dir)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string content out))))

(defun %quiet-check (designator)
  "CHECK with its report swallowed -- the return value is what these tests are about."
  (cons/template:check designator :stream (make-broadcast-stream)))

(test a-built-in-template-generates-and-builds
  ;; The positive case, on the smallest built-in: no dependencies, so a failure here is
  ;; the scaffolding rather than the network or a framework.
  (is-true (%quiet-check :lib)))

(test the-check-fails-when-the-generated-project-does-not-build
  ;; The test that gives the other one meaning. A template whose .asd names a source file
  ;; it does not ship generates perfectly happily -- files appear, markers fill -- and
  ;; produces a project that cannot load. Only building catches it.
  (with-temp-template (dir)
    (%write-template-file dir "template.lisp" "(:name \"broken\" :target-kind :lib)")
    (%write-template-file dir "files/{{name}}.asd"
                          "(defsystem \"{{name}}\"
  :components ((:module \"src\" :components ((:file \"nonexistent\")))))")
    (is-false (%quiet-check dir))))

(test the-check-fails-on-a-generated-file-that-does-not-compile
  ;; The other half: the .asd is fine and the Lisp is not. Inspecting the tree cannot see
  ;; this; loading it cannot miss it.
  (with-temp-template (dir)
    (%write-template-file dir "template.lisp" "(:name \"syntaxerror\" :target-kind :lib)")
    (%write-template-file dir "files/{{name}}.asd"
                          "(defsystem \"{{name}}\"
  :components ((:module \"src\" :components ((:file \"{{name}}\")))))")
    (%write-template-file dir "files/src/{{name}}.lisp"
                          "(defun broken (")   ; unbalanced: fails to read
    (is-false (%quiet-check dir))))
