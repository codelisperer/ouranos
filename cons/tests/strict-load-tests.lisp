;;;; strict-load-tests.lisp --- a compile WARNING in a project's own code fails the load (#303).
;;;;
;;;; Every fixture is a throwaway project in a fresh temporary directory, with a system name
;;;; unique to the run, so no fasl from an earlier run can be current. That matters here more
;;;; than anywhere: a current fasl is exactly how a warning stays hidden, and a fixture that
;;;; reused one would pass for the wrong reason.

(in-package #:cons/tests)

(in-suite all)

(defparameter *strict-warning-source* "(defun strict-fixture-f () (+ 1 \"not a number\"))"
  "A full WARNING under SBCL: the constant conflicts with the type + asserts.")

(defparameter *strict-style-source* "(defun strict-fixture-g (unused) 1)"
  "A STYLE-WARNING only: an unused variable.")

(defparameter *strict-clean-source* "(defun strict-fixture-h () 1)")

(defparameter *strict-undefined-source* "(defun strict-fixture-u () (+ 1 *strict-fixture-no-such-variable*))"
  "A full WARNING that SBCL defers to the end of the compilation unit (#525).")

(defun %used-before-defined-sources (tag)
  "Two files: the first uses a variable that the second defines. That is the same deferred
WARNING. The variable is named after TAG, because once a copy has loaded, its DEFVAR has made
the variable special in this image and no later copy using that name would warn."
  (values (format nil "(defun strict-fixture-~A () (+ 1 *strict-fixture-~A-later*))" tag tag)
          (format nil "(defvar *strict-fixture-~A-later* 1)" tag)))

(defparameter *strict-warns-at-load-source* "(warn \"a library's warning, signalled when its fasl loads\")"
  "A file that compiles cleanly and signals a full WARNING each time it is loaded.")

(defun %strict-name (tag)
  (format nil "strictfix-~A-~36R" tag (random (expt 36 8))))

(defun %strict-project (dir name source &key depends-on test-source later-source)
  "Write system NAME into DIR: one file holding SOURCE, depending on DEPENDS-ON. With
LATER-SOURCE, a second file holding it, compiled after the first. With TEST-SOURCE, also
NAME/tests holding it, named by NAME's test-op. Returns DIR."
  (with-open-file (out (merge-pathnames (format nil "~A.asd" name) dir)
                       :direction :output :if-exists :supersede)
    (format out "(asdf:defsystem ~S :depends-on ~S :serial t :components ((:file \"a\")~:[~; (:file \"b\")~])~@[ :in-order-to ((asdf:test-op (asdf:test-op ~S)))~])~%"
            name depends-on later-source (and test-source (format nil "~A/tests" name)))
    (when test-source
      (format out "(asdf:defsystem ~S :depends-on (~S) :components ((:file \"t\")))~%"
              (format nil "~A/tests" name) name)))
  (with-open-file (out (merge-pathnames "a.lisp" dir) :direction :output :if-exists :supersede)
    (write-line source out))
  (when later-source
    (with-open-file (out (merge-pathnames "b.lisp" dir) :direction :output :if-exists :supersede)
      (write-line later-source out)))
  (when test-source
    (with-open-file (out (merge-pathnames "t.lisp" dir) :direction :output :if-exists :supersede)
      (write-line test-source out)))
  dir)

(defmacro %with-strict-project ((dir name tag source &rest keys) &body body)
  "BODY with NAME a fresh system in a fresh directory DIR, findable by ASDF."
  `(tempdir:with-temporary-directory (,dir "strict")
     (let* ((,name (%strict-name ,tag))
            (asdf:*central-registry* (cons ,dir asdf:*central-registry*)))
       (%strict-project ,dir ,name ,source ,@keys)
       ,@body)))

(defun %strict-load (name root &rest keys)
  "Call LOAD-SYSTEM-STRICTLY; return (values error-or-nil what-it-printed)."
  (let* ((printed (make-string-output-stream))
         (err (let ((*error-output* printed) (*standard-output* printed))
                (handler-case (progn (apply #'cons/run:load-system-strictly name root keys) nil)
                  (error (e) e)))))
    (values err (get-output-stream-string printed))))

(test a-muffled-load-hides-the-warning-that-strict-loading-refuses
  ;; The control, and the defect: under the handler Quicklisp's quiet mode installs, a file
  ;; with a full WARNING loads without an error. The strict loader, on a separate fresh
  ;; project with the same source, refuses it and prints the warning.
  (%with-strict-project (dir name "muffled" *strict-warning-source*)
    (is (null (handler-case
                  (progn (handler-bind ((warning #'muffle-warning)) (asdf:load-system name)) nil)
                (error (e) e)))
        "the muffled load must succeed, or this test is not showing the defect"))
  (%with-strict-project (dir name "strict" *strict-warning-source*)
    (multiple-value-bind (err printed) (%strict-load name dir)
      (is (typep err 'error) "a full WARNING must fail the strict load")
      (is (search "WARNING" (string-upcase printed))
          "the warning must be printed, not only counted: ~S" printed))))

(test a-style-warning-does-not-fail-the-load
  (%with-strict-project (dir name "style" *strict-style-source*)
    (multiple-value-bind (err printed) (%strict-load name dir)
      (declare (ignore printed))
      (is (null err) "a STYLE-WARNING must not fail the load: ~A" err))))

(test a-warning-in-a-dependency-outside-the-project-does-not-fail-it
  ;; A library's warning is not the app's to fix. LIB sits in its own directory, outside the
  ;; app's ROOT, so it is loaded the quiet way, and the app's clean code loads.
  (tempdir:with-temporary-directory (libdir "strictlib")
    (let* ((lib (%strict-name "lib"))
           (asdf:*central-registry* (cons libdir asdf:*central-registry*)))
      (%strict-project libdir lib *strict-warning-source*)
      (%with-strict-project (dir name "app" *strict-clean-source* :depends-on (list lib))
        (multiple-value-bind (err printed) (%strict-load name dir)
          (declare (ignore printed))
          (is (null err) "a warning in a dependency outside ROOT must not fail: ~A" err))
        (is (equal (list (list name) (list lib))
                   (multiple-value-list (cons/run:load-system-strictly name dir)))
            "the app is own and the library is not")))))

(test a-warning-in-a-dependency-inside-the-project-fails-it
  ;; The same shape with the library under ROOT: it is the project's own code now.
  (%with-strict-project (dir name "app2" *strict-clean-source*)
    (let* ((sub (merge-pathnames "lib/" dir))
           (lib (%strict-name "ownlib")))
      (ensure-directories-exist sub)
      (%strict-project sub lib *strict-warning-source*)
      (%strict-project dir name *strict-clean-source* :depends-on (list lib))
      (let ((asdf:*central-registry* (cons sub asdf:*central-registry*)))
        (is (typep (%strict-load name dir) 'error))))))

(test a-project-reached-through-a-symbolic-link-is-still-the-projects-own
  ;; ASDF reports a system's directory with symbolic links resolved. The project's root is
  ;; given here through a link, so the two spellings differ, as they do for every project in
  ;; the temporary directory on macOS (/var is a link to /private/var). Compared unresolved,
  ;; the system was not the project's own, it was loaded with warnings muffled, and this
  ;; load succeeded. Symbolic links need privileges on Windows, so this runs elsewhere.
  (if (uiop:os-windows-p)
      (skip "creating a symbolic link needs privileges on Windows")
      (%with-strict-project (dir name "link" *strict-warning-source*)
        (let ((link (merge-pathnames (format nil "~A-link/" name) (uiop:temporary-directory))))
          (unwind-protect
               (progn
                 (uiop:run-program (list "ln" "-s" (uiop:native-namestring (truename dir))
                                         (string-right-trim "/" (uiop:native-namestring link))))
                 (is (typep (%strict-load name link) 'error)
                     "the project's own system, reached through a link, must fail on its warning"))
            (uiop:run-program (list "rm" "-f" (string-right-trim "/" (uiop:native-namestring link)))
                              :ignore-error-status t))))))

(test a-current-fasl-hides-the-warning-until-force-own-recompiles-it
  ;; Compile once with the warning muffled, as an older cons did: the fasl is now current,
  ;; so an ordinary strict load does not compile and cannot see it. FORCE-OWN (`cons
  ;; --strict') recompiles and does.
  (%with-strict-project (dir name "warm" *strict-warning-source*)
    (handler-bind ((warning #'muffle-warning)) (asdf:load-system name))
    (is (null (%strict-load name dir))
        "without FORCE-OWN the current fasl is loaded and nothing is compiled")
    (is (typep (%strict-load name dir :force-own t) 'error)
        "FORCE-OWN must recompile the project's own system and see the warning")))

(test with-tests-loads-the-test-system-strictly-too
  ;; `cons test': the warning is in the test system that the main system's test-op names.
  (%with-strict-project (dir name "tests" *strict-clean-source*
                             :test-source *strict-warning-source*)
    (is (null (%strict-load name dir)) "without WITH-TESTS the test system is not loaded")
    (is (typep (%strict-load name dir :with-tests t) 'error))))

(test the-subprocess-text-reads-and-runs-in-a-package-that-knows-nothing-of-cons
  ;; `cons --fresh' passes the loader to a bare sbcl as text. Read it back in CL-USER, as
  ;; that sbcl will, and run it: it must behave as the in-process loader does.
  (%with-strict-project (dir name "text" *strict-warning-source*)
    (let* ((text (cons/run::%load-form-text name dir nil nil))
           (form (let ((*package* (find-package :cl-user))) (read-from-string text))))
      (is (null (search "CONS/RUN" (string-upcase text)))
          "the text must not name cons's own package: ~A" text)
      (is (typep (handler-case (let ((*error-output* (make-broadcast-stream)))
                                 (eval form) nil)
                   (error (e) e))
                 'error)))))

(test a-relative-root-is-resolved-before-it-is-compared
  ;; Review of #331: a caller of LOAD-SYSTEM-STRICTLY can pass #P"./". ASDF's directory for
  ;; the system is absolute, so compared as given, the system was not the project's own and
  ;; its warning was muffled.
  (%with-strict-project (dir name "relative" *strict-warning-source*)
    (let ((*default-pathname-defaults* (truename dir)))
      (is (typep (%strict-load name #P"./") 'error)
          "the project's own system, with the root given as ./, must fail on its warning"))))

;;; --- warnings deferred to the end of the compilation unit (#525) ---------------------
;;;
;;; SBCL reports an undefined variable when the compilation unit ends, after COMPILE-FILE
;;; has returned with FAILURE-P false, so ASDF loads the system without an error. Each test
;;; below that expects a failure first loads a separate fresh copy of the same project with
;;; plain ASDF and nothing muffled, and checks that it succeeds: that is the defect, and
;;; without it the strict failure could be coming from somewhere else.

(defun %plain-load-succeeds-p (name)
  ;; A compilation unit of its own, so the deferred warning is printed here, into the
  ;; discarded output. Under ASDF:TEST-SYSTEM it was otherwise printed when the test run's
  ;; unit ended, and the gate failed CONS/TESTS for a fixture's planted warning.
  (let ((*error-output* (make-broadcast-stream)) (*standard-output* (make-broadcast-stream)))
    (null (handler-case (progn (with-compilation-unit (:override t) (asdf:load-system name)) nil)
            (error (e) e)))))

(test an-undefined-variable-fails-the-strict-load
  (%with-strict-project (dir name "undef-plain" *strict-undefined-source*)
    (is (%plain-load-succeeds-p name)
        "plain ASDF must load it, or this test is not showing the defect"))
  (%with-strict-project (dir name "undef" *strict-undefined-source*)
    (multiple-value-bind (err printed) (%strict-load name dir)
      (declare (ignore printed))
      (is (typep err 'error) "an undefined variable must fail the strict load")
      (is (search "*STRICT-FIXTURE-NO-SUCH-VARIABLE*" (princ-to-string err))
          "the error must name the variable: ~A" err))))

(test a-variable-used-before-a-later-file-defines-it-fails-the-strict-load
  (let ((tag (%strict-name "plain")))
    (multiple-value-bind (uses defines) (%used-before-defined-sources tag)
      (%with-strict-project (dir name "later-plain" uses :later-source defines)
        (is (%plain-load-succeeds-p name)
            "plain ASDF must load it, or this test is not showing the defect"))))
  (let ((tag (%strict-name "strict")))
    (multiple-value-bind (uses defines) (%used-before-defined-sources tag)
      (%with-strict-project (dir name "later" uses :later-source defines)
        (let ((err (%strict-load name dir)))
          (is (typep err 'error) "a variable used before its file defines it must fail")
          (is (search (string-upcase (format nil "*strict-fixture-~A-later*" tag))
                      (princ-to-string err))
              "the error must name the variable: ~A" err))))))

(test an-undefined-variable-fails-the-strict-load-inside-the-callers-compilation-unit
  ;; A caller inside its own compilation unit would otherwise receive the deferred warning
  ;; when its unit ends, after the loader has returned.
  (%with-strict-project (dir name "undef-unit" *strict-undefined-source*)
    (is (typep (with-compilation-unit () (%strict-load name dir)) 'error))))

(test an-undefined-variable-in-a-test-system-fails-with-tests
  (%with-strict-project (dir name "undef-tests" *strict-clean-source*
                             :test-source *strict-undefined-source*)
    (is (typep (%strict-load name dir :with-tests t) 'error))))

(test a-dependency-that-warns-at-load-or-defers-a-warning-does-not-fail-the-project
  ;; Some libraries signal a full WARNING when they load (dbi's "redefining DEFTYPE type to
  ;; be a class"), and a library can carry an undefined variable. Neither is the app's to
  ;; fix. Both libraries sit outside ROOT, and the load runs inside a compilation unit of
  ;; the caller's, where an unfinished one of the library's would end.
  (tempdir:with-temporary-directory (libdir "strictlib")
    (let* ((loads (%strict-name "loadwarn"))
           (undef (%strict-name "libundef"))
           (asdf:*central-registry* (cons libdir asdf:*central-registry*)))
      (ensure-directories-exist (merge-pathnames "u/" libdir))
      (%strict-project libdir loads *strict-warns-at-load-source*)
      (%strict-project (merge-pathnames "u/" libdir) undef *strict-undefined-source*)
      (let ((asdf:*central-registry* (cons (merge-pathnames "u/" libdir) asdf:*central-registry*)))
        (%with-strict-project (dir name "libapp" *strict-clean-source*
                                   :depends-on (list loads undef))
          (let* ((err nil)
                 (printed (with-output-to-string (out)
                            (let ((*error-output* out) (*standard-output* out))
                              (with-compilation-unit ()
                                (setf err (%strict-load name dir)))))))
            (is (null err) "warnings from libraries outside ROOT must not fail the project: ~A" err)
            ;; The library's deferred warning is muffled too. Without a compilation unit of
            ;; its own it was printed when the caller's unit ended, after the loader returned.
            (is (null (search "*STRICT-FIXTURE-NO-SUCH-VARIABLE*" printed))
                "the library's undefined variable must not be printed:~%~A" printed)))))))

;;; --- through the targets, as bin/cons runs them ------------------------------------
;;;
;;; Review of #331: the tests above call LOAD-SYSTEM-STRICTLY directly, so they would stay
;;; green if a target went back to loading through Quicklisp. These run `cons build', `cons
;;; test' and `cons --fresh build' through CLI-RUN in a child SBCL, which is what bin/cons
;;; calls, and read its exit code and what it printed.

(defun %cons-target-in-child (dir target &key fresh strict)
  "Run TARGET of the cons.lisp in DIR through CONS/RUN:CLI-RUN in a child SBCL, which loads
cons from this tree. Returns (values EXIT-CODE OUTPUT). The child, and the sbcl a --fresh
target starts, find the fixture and this tree through CL_SOURCE_REGISTRY."
  (flet ((tree-entry (d) (format nil "~A//" (string-right-trim "/" (namestring (truename d))))))
    (let* ((tree (uiop:pathname-parent-directory-pathname (asdf:system-source-directory :cons)))
           (sep (if (uiop:os-windows-p) ";" ":"))
           (registry (format nil "~A~A~A~A" (tree-entry dir) sep (tree-entry tree) sep)))
      (multiple-value-bind (out err code)
          (uiop:run-program
           (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                 "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                 "--eval" "(require :asdf)"
                 "--eval" (format nil "(load ~S)" (uiop:native-namestring
                                                   (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
                 "--eval" "(let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :cons))"
                 "--eval" (format nil "(cons/run:cli-run (cons/spec:load-spec ~S) (list ~S) :fresh ~S :strict ~S)"
                                  (uiop:native-namestring dir) target fresh strict))
           :output :string :error-output :output :ignore-error-status t :directory dir
           :environment (cons (format nil "CL_SOURCE_REGISTRY=~A" registry)
                              (remove-if (lambda (e) (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e))
                                         (sb-ext:posix-environ))))
        (declare (ignore err))
        (values code out)))))

(defmacro %with-cons-project ((dir name tag source) &body body)
  "BODY with DIR a fresh project whose cons.lisp has a `build' target loading system NAME and
a `test' target testing it; NAME's one file holds SOURCE."
  `(tempdir:with-temporary-directory (,dir "strict-cli")
     ;; Lower case: the source registry the child uses indexes .asd files by their exact
     ;; name, and ASDF looks a system up by its name in lower case.
     (let ((,name (string-downcase (%strict-name ,tag))))
       (%strict-project ,dir ,name ,source)
       (with-open-file (out (merge-pathnames "cons.lisp" ,dir) :direction :output)
         (format out "(cons:project ~S :system ~S :targets ((build :load ~S) (test :test ~S)))~%"
                 ,name ,name ,name ,name))
       ,@body)))

(test cons-build-test-and-fresh-build-fail-on-a-warning-and-print-it
  (%with-cons-project (dir name "cli" *strict-warning-source*)
    (dolist (run '(("build" nil) ("test" nil) ("build" t)))
      (destructuring-bind (target fresh) run
        (multiple-value-bind (code out) (%cons-target-in-child dir target :fresh fresh)
          (is (eql 1 code) "cons ~:[~;--fresh ~]~A must exit 1 on the warning, got ~A:~%~A" fresh target code out)
          (is (search "not a number" out) "cons ~:[~;--fresh ~]~A must print the warning:~%~A" fresh target out))))))

(test cons-strict-build-and-strict-fresh-build-fail-on-an-undefined-variable
  ;; #525 was reported through `cons --strict build'. --strict matters here: the first run
  ;; writes a fasl, because ASDF does not fail the compile, and the second run would load
  ;; that fasl without compiling it if --strict did not recompile the project's systems.
  (%with-cons-project (dir name "cliundef" *strict-undefined-source*)
    (dolist (fresh '(nil t))
      (multiple-value-bind (code out) (%cons-target-in-child dir "build" :fresh fresh :strict t)
        (is (eql 1 code) "cons --strict ~:[~;--fresh ~]build must exit 1 on an undefined variable, got ~A:~%~A" fresh code out)
        (is (search "*STRICT-FIXTURE-NO-SUCH-VARIABLE*" out) "cons --strict ~:[~;--fresh ~]build must name the variable:~%~A" fresh out)))))

(test cons-build-and-fresh-build-pass-a-clean-project
  ;; The control: the same child, the same targets, a project without the warning.
  (%with-cons-project (dir name "clicl" *strict-clean-source*)
    (dolist (fresh '(nil t))
      (multiple-value-bind (code out) (%cons-target-in-child dir "build" :fresh fresh)
        (is (eql 0 code) "cons ~:[~;--fresh ~]build of a clean project must exit 0, got ~A:~%~A" fresh code out)))))
