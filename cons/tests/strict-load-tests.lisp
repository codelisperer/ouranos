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

(test a-strict-load-whose-root-holds-none-of-its-systems-is-refused
  "#960: with a root that is not the project's directory, no system counts as the project's own,
every warning is muffled, and a strict load judged nothing and passed a full WARNING. Under
:FORCE-OWN, which `cons --strict' sets, that is now refused, naming the root. Controls: the same
load without :FORCE-OWN still passes, as a plain load of an outside library must; and the right
root fails the WARNING, as before."
  (%with-strict-project (dir name "wrongroot" *strict-warning-source*)
    (tempdir:with-temporary-directory (elsewhere "elsewhere")
      (multiple-value-bind (err printed) (%strict-load name elsewhere :force-own t)
        (declare (ignore printed))
        (is (typep err 'error) "a strict load under the wrong root must not pass")
        (is (search "found no system of the project" (princ-to-string err)) "~A" err)
        ;; By the directory's own name: the message names the root resolved with TRUENAME, and on
        ;; a Windows runner the temporary directory's path can come back in its short 8.3 form
        ;; (RUNNER~1) on one side and its long form on the other (run 40619640922).
        (is (search (car (last (pathname-directory elsewhere))) (princ-to-string err))
            "the root is named: ~A" err))
      (is (null (%strict-load name elsewhere))
          "control: without :FORCE-OWN the load of a system outside the root passes")))
  (%with-strict-project (dir name "rightroot" *strict-warning-source*)
    (let ((err (%strict-load name dir :force-own t)))
      (is (typep err 'error))
      (is (not (search "found no system of the project" (princ-to-string err)))
          "control: under the right root it fails on the WARNING itself: ~A" err))))

(test a-style-warning-does-not-fail-the-load
  (%with-strict-project (dir name "style" *strict-style-source*)
    (multiple-value-bind (err printed) (%strict-load name dir)
      (declare (ignore printed))
      (is (null err) "a STYLE-WARNING must not fail the load: ~A" err))))

(defun %undefined-call-source (tag defined-p)
  "A function calling STRICT-FIXTURE-<TAG>-CALLEE, which the same file defines when DEFINED-P.
The callee is named after TAG so that a control which defines it cannot define it for a later
test that must find it undefined."
  (format nil "(defun strict-fixture-~A () (strict-fixture-~A-callee 1))~@[~%~A~]"
          tag tag (and defined-p (format nil "(defun strict-fixture-~A-callee (x) x)" tag))))

(test a-call-to-an-undefined-function-fails-the-load
  "#1083: SBCL reports a call to a function that does not exist as a STYLE-WARNING, which the
strict load let through, so the call failed only when it ran (#1066). It now fails the load and
names the function. The control is the same call with the function defined."
  (let ((tag (format nil "u~36R" (random (expt 36 8)))))
    (%with-strict-project (dir name "undefined" (%undefined-call-source tag nil))
      (multiple-value-bind (err printed) (%strict-load name dir)
        (declare (ignore printed))
        (is (typep err 'error) "a call to an undefined function must fail the strict load")
        (is (search (string-upcase (format nil "strict-fixture-~A-callee" tag))
                    (princ-to-string err))
            "the error names the function: ~A" err)))
    (%with-strict-project (dir name "defined" (%undefined-call-source tag t))
      (is (null (%strict-load name dir)) "control: the same call to a defined function passes"))))

(test a-call-to-an-undefined-function-in-a-dependency-does-not-fail-it
  "The rule for a library's warnings holds for this one too: LIB, outside the app's ROOT, calls
an undefined function, and the app that depends on it loads."
  (tempdir:with-temporary-directory (libdir "strictlib")
    (let* ((lib (%strict-name "undeflib"))
           (tag (format nil "l~36R" (random (expt 36 8))))
           (asdf:*central-registry* (cons libdir asdf:*central-registry*)))
      (%strict-project libdir lib (%undefined-call-source tag nil))
      (%with-strict-project (dir name "undefapp" *strict-clean-source* :depends-on (list lib))
        (is (null (%strict-load name dir))
            "an undefined function in a dependency outside ROOT must not fail the app")))))

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

(test a-warning-the-projects-own-file-signals-when-it-loads-fails-the-strict-load
  ;; The same handler sees it, and under #303 the project's own full WARNING fails the load
  ;; whenever it is signalled. The same source in a library is the next test's case.
  (%with-strict-project (dir name "loadwarn-own" *strict-warns-at-load-source*)
    (let ((err (%strict-load name dir)))
      (is (typep err 'error) "a WARNING the project's own file signals at load must fail")
      (is (search "signalled when its fasl loads" (princ-to-string err))
          "the error must carry the warning: ~A" err)
      (is (search "when one of its files was loaded" (princ-to-string err))
          "the error must say a warning can come from a load: ~A" err))))

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

;;; --- #1121: a definition replaced from another file of the project ------------------------
;;;
;;; These run `cons --strict build' in a child image, as the tests above do: inside
;;; ASDF:TEST-SYSTEM, the recompile --strict asks for is a nested ASDF operation with :FORCE,
;;; which ASDF refuses.

(defmacro %with-two-file-cons-project ((dir name a-source b-source) &body body)
  "BODY with DIR a fresh project whose `build' target loads system NAME. NAME's file a.lisp
defines a fresh package and holds A-SOURCE; b.lisp, compiled after it, holds B-SOURCE in that
package. Both sources are FORMAT control strings, given NAME as their one argument."
  (let ((package (gensym "PACKAGE")))
    `(tempdir:with-temporary-directory (,dir "strict-redef")
       (let* ((,name (string-downcase (%strict-name "redef")))
              (,package (string-upcase ,name)))
         (%strict-project ,dir ,name
                          (format nil "(defpackage ~S (:use #:cl))~%(in-package ~S)~%~?"
                                  ,package ,package ,a-source (list ,name))
                          :later-source (format nil "(in-package ~S)~%~?"
                                                ,package ,b-source (list ,name)))
         (with-open-file (out (merge-pathnames "cons.lisp" ,dir) :direction :output)
           (format out "(cons:project ~S :system ~S :targets ((build :load ~S)))~%"
                   ,name ,name ,name))
         ,@body))))

(test a-definition-replaced-from-another-file-fails-cons-strict-build
  "A consuming app's helper in one file was replaced by one with the same name in another file
of the package, and its strict build passed, because SBCL reports that only as a STYLE-WARNING.
`cons --strict build' now fails for each of DEFUN, DEFMACRO, DEFGENERIC and a DEFMETHOD on the
same specializers, naming the kind, the definition and both files. Without --strict the same
build still passes, as it did."
  (loop for (kind a-source b-source)
          in '(("defun" "(defun helper (a b) (list a b))" "(defun helper (a) (list a))")
               ("defmacro" "(defmacro helper (x) x)" "(defmacro helper (x) (list 'quote x))")
               ("defgeneric" "(defgeneric helper (x))" "(defgeneric helper (x))")
               ("defmethod" "(defmethod helper ((x integer)) x)"
                "(defmethod helper ((x integer)) (1+ x))"))
        do (%with-two-file-cons-project (dir name a-source b-source)
             (multiple-value-bind (code out) (%cons-target-in-child dir "build" :strict t)
               (is (eql 1 code) "~A: cons --strict build must exit 1, got ~A:~%~A" kind code out)
               (is (search (format nil "~A ~A::HELPER" kind (string-upcase name)) out)
                   "~A: the output names the kind and the definition:~%~A" kind out)
               ;; In the error's own sentence: the child's compile output names both files
               ;; whether or not the error does.
               (is-true (let ((p (search "b.lisp replaces the one in " out)))
                          (and p (search "a.lisp" out :start2 p)))
                        "~A: the error names both files:~%~A" kind out))))
  (%with-two-file-cons-project (dir name "(defun helper () 1)" "(defun helper () 2)")
    (multiple-value-bind (code out) (%cons-target-in-child dir "build")
      (is (eql 0 code) "control: cons build without --strict must pass, got ~A:~%~A" code out))))

(test one-file-loaded-twice-passes-cons-strict-build
  "The control for the test above. b.lisp loads a.lisp's source again, so its function is
redefined from the same file, and a.lisp's macro is defined twice by SBCL itself, once while
the file compiles and once when it loads. Neither is a definition from another file."
  (%with-two-file-cons-project
      (dir name "(defun helper () 1)~%(defmacro helper-macro (x) x)"
           ;; By the system's directory: when b.lisp's fasl loads, *LOAD-TRUENAME* is the fasl
           ;; in the cache, not the source.
           "(load (merge-pathnames \"a.lisp\" (asdf:system-source-directory ~S)))")
    (multiple-value-bind (code out) (%cons-target-in-child dir "build" :strict t)
      (is (eql 0 code) "a file loaded twice must pass cons --strict build, got ~A:~%~A"
          code out))))

;;; The review of #1128 found two ways the check could be wrong in a real image. These run
;;; their forms in one child image, so that one image builds more than once, or has a setting
;;; an app made, as a REPL or bin/cons would.

(defun %forms-in-child (dir forms)
  "Run FORMS, strings, in order in a child SBCL that has loaded cons from this tree, with DIR
and this tree in its source registry. Returns (values EXIT-CODE OUTPUT)."
  (flet ((tree-entry (d) (format nil "~A//" (string-right-trim "/" (namestring (truename d))))))
    (let* ((tree (uiop:pathname-parent-directory-pathname (asdf:system-source-directory :cons)))
           (sep (if (uiop:os-windows-p) ";" ":"))
           (registry (format nil "~A~A~A~A" (tree-entry dir) sep (tree-entry tree) sep)))
      (multiple-value-bind (out err code)
          (uiop:run-program
           (append (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                         "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                         "--eval" "(require :asdf)"
                         "--eval" (format nil "(load ~S)"
                                          (uiop:native-namestring
                                           (merge-pathnames "quicklisp/setup.lisp"
                                                            (user-homedir-pathname))))
                         "--eval" "(let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :cons))")
                   (loop for f in forms append (list "--eval" f)))
           :output :string :error-output :output :ignore-error-status t :directory dir
           :environment (cons (format nil "CL_SOURCE_REGISTRY=~A" registry)
                              (remove-if (lambda (e) (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e))
                                         (sb-ext:posix-environ))))
        (declare (ignore err))
        (values code out)))))

(defun %strict-build-form (label name dir)
  "A form, as a string, that loads NAME from DIR strictly, as `cons --strict build' does, and
prints LABEL followed by `ok' or by `failed:' and the error."
  (format nil "(handler-case (progn (cons/run:load-system-strictly ~S ~S :force-own t) (format t \"~~&~A ok~~%\")) (error (e) (format t \"~~&~A failed: ~~A~~%\" e)))"
          name (uiop:native-namestring dir) label label))

(defun %write-form (dir file text)
  "A form, as a string, that replaces FILE in DIR with TEXT."
  (format nil "(with-open-file (out ~S :direction :output :if-exists :supersede) (write-string ~S out))"
          (uiop:native-namestring (merge-pathnames file dir)) text))

(test a-function-moved-to-another-file-passes-a-second-strict-build-in-one-image
  "Review of #1128: an image that has built the project once holds its definitions with the
files they came from. When HELPER then moves from a.lisp to b.lisp, the next strict build in
that image replaced the earlier build's HELPER from a.lisp and failed, although no file of the
project defines it twice. That is the state of bin/cons for cons's own code, or of a REPL. It
now passes. The control, a third build in the same image with HELPER in both files, fails."
  (%with-two-file-cons-project (dir name "(defun helper () 1)" "(defun other () 2)")
    (let* ((package (string-upcase name))
           (head (format nil "(defpackage ~S (:use #:cl))~%(in-package ~S)~%" package package))
           (b-head (format nil "(in-package ~S)~%" package)))
      (multiple-value-bind (code out)
          (%forms-in-child
           dir
           (list (%strict-build-form "FIRST" name dir)
                 (%write-form dir "a.lisp" head)
                 (%write-form dir "b.lisp" (format nil "~A(defun other () 2)~%(defun helper () 1)~%"
                                                   b-head))
                 (%strict-build-form "MOVED" name dir)
                 (%write-form dir "a.lisp" (format nil "~A(defun helper () 1)~%" head))
                 (%strict-build-form "BOTH" name dir)))
        (is (eql 0 code) "the child exited ~A:~%~A" code out)
        (is (search "FIRST ok" out) "the first build:~%~A" out)
        (is (search "MOVED ok" out) "the build after the move:~%~A" out)
        (is (search "BOTH failed:" out) "control: both files define HELPER:~%~A" out)
        (is (search (format nil "defun ~A::HELPER in " package) out)
            "control: the error names the definition:~%~A" out)))))

(test the-usual-uninteresting-conditions-do-not-hide-a-redefinition
  "Review of #1128: UIOP:*USUAL-UNINTERESTING-CONDITIONS* lists the redefinition warnings, and
an app that sets UIOP:*UNINTERESTING-CONDITIONS* to it made ASDF muffle every one before the
strict loader or the gate's check saw it. Both now bind the list without them. The child sets
the muffle, then runs a strict build and the gate's CALL-REPORTING-REDEFINITIONS on fresh
copies of a project whose two files both define HELPER."
  (%with-two-file-cons-project (dir name "(defun helper () 1)" "(defun helper () 2)")
    (let ((script (uiop:native-namestring
                   (merge-pathnames "scripts/redefinitions.lisp"
                                    (uiop:pathname-parent-directory-pathname
                                     (asdf:system-source-directory :cons))))))
      (multiple-value-bind (code out)
          (%forms-in-child
           dir
           (list "(setf uiop:*uninteresting-conditions* uiop:*usual-uninteresting-conditions*)"
                 (%strict-build-form "STRICT" name dir)
                 (format nil "(load ~S)" script)
                 ;; The gate's check, with a fresh compile so that the definitions are made
                 ;; again under it, and with DIR as the root its files must be under.
                 (format nil "(ouranos-redefinitions:call-reporting-redefinitions (lambda () (asdf:load-system ~S :force t)) (list ~S))"
                         name (uiop:native-namestring dir))))
        (is (eql 0 code) "the child exited ~A:~%~A" code out)
        (is (search "STRICT failed:" out) "the strict build passed under the muffle:~%~A" out)
        (is (search "OURANOS-REDEFINED defun " out)
            "the gate's check reported nothing under the muffle:~%~A" out)))))

(test a-generic-function-added-to-another-file-fails-under-the-usual-muffle
  "Review of #1128: SB-KERNEL:UNINTERESTING-REDEFINITION, in UIOP's usual list, is a type made of
SATISFIES tests, so a filter that removed the list's subtypes of REDEFINITION-WARNING kept it.
With the muffle set, a.lisp's DEFGENERIC GG reloading from the same file was then hidden, so
this build was not seen to define GG, and b.lisp's DEFGENERIC GG, replacing a definition the
image already had, was not counted. The child builds with GG in a.lisp only, adds it to b.lisp,
and builds again in the same image; the second build fails. The control is the first build. The
gate's CALL-REPORTING-REDEFINITIONS, given the same filter change, then reports GG on a forced
build. That check also passed with the old filter, measured on 2026-11-02, so it guards the
gate's report and is not evidence for the change."
  (%with-two-file-cons-project (dir name "(defun helper () 1)" "(defun other () 2)")
    (let* ((package (string-upcase name))
           (script (uiop:native-namestring
                    (merge-pathnames "scripts/redefinitions.lisp"
                                     (uiop:pathname-parent-directory-pathname
                                      (asdf:system-source-directory :cons)))))
           (head (format nil "(defpackage ~S (:use #:cl))~%(in-package ~S)~%" package package))
           (b-head (format nil "(in-package ~S)~%" package)))
      (multiple-value-bind (code out)
          (%forms-in-child
           dir
           (list "(setf uiop:*uninteresting-conditions* uiop:*usual-uninteresting-conditions*)"
                 (%write-form dir "a.lisp" (format nil "~A(defgeneric gg (x))~%" head))
                 (%strict-build-form "FIRST" name dir)
                 (%write-form dir "b.lisp" (format nil "~A(defun other () 2)~%(defgeneric gg (x))~%"
                                                   b-head))
                 (%strict-build-form "ADDED" name dir)
                 (format nil "(load ~S)" script)
                 (format nil "(ouranos-redefinitions:call-reporting-redefinitions (lambda () (asdf:load-system ~S :force t)) (list ~S))"
                         name (uiop:native-namestring dir))))
        (is (eql 0 code) "the child exited ~A:~%~A" code out)
        (is (search "FIRST ok" out) "control: GG in a.lisp only:~%~A" out)
        (is (search "ADDED failed:" out) "GG added to b.lisp passed under the muffle:~%~A" out)
        (is (search (format nil "defgeneric ~A::GG in " package) out)
            "the error names the generic function:~%~A" out)
        (is (search (format nil "OURANOS-REDEFINED defgeneric ~A::GG " package) out)
            "the gate's check did not report GG under the muffle:~%~A" out)))))

;;; --- #960: --strict and the targets it cannot judge, and fasls written outside cons --------

(test the-targets-strict-cannot-judge-are-the-ones-that-load-nothing
  "#960: a target whose work is :eval, :call or :sh with no :load or :test is one --strict
cannot judge. A target with :load or :test is judged, and a :steps target is judged by the
targets it runs."
  (let* ((spec (cons/spec:install-spec
                "unjudged"
                '(:system "unjudged"
                  :targets
                  ((build :load "unjudged")
                   (test :test "unjudged/tests")
                   (dev :load "unjudged/web" :call ("unjudged/web:dev"))
                   (build-eval :eval "(asdf:load-system \"unjudged\")")
                   (build-call :call ("asdf:load-system" "unjudged"))
                   (dump :sh ("sbcl" "--script" "dump.lisp"))
                   (repl :interactive t)
                   (load-and-sh :load "unjudged" :sh ("sbcl" "--version"))
                   (test-and-sh :test "unjudged/tests" :sh ("sbcl" "--version"))
                   (twice :steps (build-eval build build-eval))
                   (all :steps (build build-eval dump))))))
         (tgt (lambda (name) (find name (cons/spec:spec-targets spec) :key #'cons/spec:target-name))))
    (flet ((unjudged (name) (cons/run::%unjudged-targets spec (funcall tgt name))))
      (dolist (judged '(:build :test :dev :repl))
        (is (null (unjudged judged)) "~S loads what it builds, or does no work" judged))
      (is (equal '((:build-eval :eval)) (unjudged :build-eval)))
      (is (equal '((:build-call :call)) (unjudged :build-call)))
      (is (equal '((:dump :sh)) (unjudged :dump)))
      (is (equal '((:build-eval :eval) (:dump :sh)) (unjudged :all))
          "a :steps target names each step it runs that --strict cannot judge")
      ;; #968's review: cons runs :sh in place of :load and :test, so they never run.
      (is (equal '((:load-and-sh :sh)) (unjudged :load-and-sh)))
      (is (equal '((:test-and-sh :sh)) (unjudged :test-and-sh)))
      (is (equal '((:build-eval :eval)) (unjudged :twice)) "a step run twice is named once"))))

(test a-steps-cycle-is-refused-naming-the-cycle
  "#968's review: :steps that lead back to a target already being run are refused, naming the
cycle, instead of recursing until the stack runs out. Control: a step reached twice by two
paths, which is not a cycle, is accepted."
  (let* ((spec (cons/spec:install-spec
                "cycle"
                '(:system "cycle"
                  :targets
                  ((a :steps (b))
                   (b :steps (c))
                   (c :steps (a))
                   (leaf :load "cycle")
                   (diamond :steps (left right))
                   (left :steps (leaf))
                   (right :steps (leaf))))))
         (tgt (lambda (name) (find name (cons/spec:spec-targets spec) :key #'cons/spec:target-name))))
    (let ((e (handler-case (progn (cons/run::%steps-in-order spec (funcall tgt :a)) nil)
               (error (e) e))))
      (is-true e)
      (is (search "a -> b -> c -> a" (princ-to-string e)) "~A" e))
    (is (= 4 (length (remove-duplicates (cons/run::%steps-in-order spec (funcall tgt :diamond))
                                        :key #'cons/spec:target-name)))
        "control: diamond, left, right and leaf")))

(defmacro %with-cons-targets ((dir name tag source targets-format) &body body)
  "BODY with DIR a fresh project whose system NAME's one file holds SOURCE and whose cons.lisp
has the targets TARGETS-FORMAT gives, a format string applied to NAME."
  `(tempdir:with-temporary-directory (,dir "strict-cli")
     (let ((,name (string-downcase (%strict-name ,tag))))
       (%strict-project ,dir ,name ,source)
       (with-open-file (out (merge-pathnames "cons.lisp" ,dir) :direction :output)
         (format out "(cons:project ~S :system ~S :targets (~A))~%"
                 ,name ,name (format nil ,targets-format ,name ,name ,name)))
       ,@body)))

(test cons-strict-refuses-a-target-that-loads-its-code-in-an-eval
  "#960: an :eval target that loads a system holding a full WARNING. Under --strict it is
refused, exit 1, naming the target and the clause, before it runs. Control: run without
--strict, the same target runs, loads the system with its warnings muffled, as a build step
through Quicklisp's quiet mode does, and exits 0 -- the check --strict could not have made."
  (%with-cons-targets (dir name "evaltarget" *strict-warning-source*
                       "(build-eval :eval \"(handler-bind ((warning (function muffle-warning))) (asdf:load-system \\\"~A\\\"))\") (build :load ~S)")
    (multiple-value-bind (code out) (%cons-target-in-child dir "build-eval" :strict t)
      (is (eql 1 code) "cons --strict build-eval must exit 1, got ~A:~%~A" code out)
      (is (search "target build-eval does its work with :eval" out) "~A" out))
    (multiple-value-bind (code out) (%cons-target-in-child dir "build-eval")
      (is (eql 0 code) "control: cons build-eval without --strict runs and exits 0, got ~A:~%~A" code out))))

(defun %plain-load-in-child (dir name)
  "Load system NAME, found in DIR, in a child SBCL with plain ASDF, its warnings muffled, as a
build step outside cons would: the child compiles the system and writes its fasls."
  (multiple-value-bind (out err code)
      (uiop:run-program
       (list (uiop:native-namestring sb-ext:*runtime-pathname*)
             "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
             "--eval" "(require :asdf)"
             "--eval" (format nil "(push ~S asdf:*central-registry*)" (namestring (truename dir)))
             "--eval" (format nil "(handler-bind ((warning (function muffle-warning))) (asdf:load-system ~S))" name))
       :output :string :error-output :output :ignore-error-status t)
    (declare (ignore err))
    (values code out)))

(test cons-strict-recompiles-fasls-written-outside-cons
  "#960: a step outside cons -- plain ASDF in another process -- compiles a system holding a
full WARNING and writes its fasl. cons --strict build must still fail, because --strict
recompiles the project's own systems instead of loading that fasl. Control: plain cons build
loads the fasl without compiling it and exits 0, which is the silent pass --strict exists to
prevent."
  (%with-cons-targets (dir name "outside" *strict-warning-source* "(build :load ~S)")
    (multiple-value-bind (code out) (%plain-load-in-child dir name)
      (is (eql 0 code) "the plain load outside cons must succeed and write the fasl, got ~A:~%~A" code out))
    (multiple-value-bind (code out) (%cons-target-in-child dir "build")
      (is (eql 0 code) "control: plain cons build loads the warm fasl and exits 0, got ~A:~%~A" code out))
    (multiple-value-bind (code out) (%cons-target-in-child dir "build" :strict t)
      (is (eql 1 code) "cons --strict build must recompile and exit 1, got ~A:~%~A" code out)
      (is (search "not a number" out) "the warning must be printed:~%~A" out))))

(test cons-strict-refuses-a-target-whose-shell-command-replaces-its-load
  "#968's review: a target with :load and :sh. cons runs :sh in place of :load, so the system
holding a full WARNING is never loaded. Under --strict that is refused, exit 1, naming the
target. Control: without --strict the shell command runs, exit 0, and the warning, never loaded,
is not printed."
  (%with-cons-targets (dir name "loadsh" *strict-warning-source*
                       "(build-sh :load ~S :sh (\"sbcl\" \"--version\"))")
    (multiple-value-bind (code out) (%cons-target-in-child dir "build-sh" :strict t)
      (is (eql 1 code) "cons --strict build-sh must exit 1, got ~A:~%~A" code out)
      (is (search "target build-sh runs a shell command (:sh)" out) "~A" out))
    (multiple-value-bind (code out) (%cons-target-in-child dir "build-sh")
      (is (eql 0 code) "control: without --strict the shell command runs and exits 0, got ~A:~%~A" code out)
      (is (null (search "not a number" out)) "control: the :load never ran:~%~A" out))))
