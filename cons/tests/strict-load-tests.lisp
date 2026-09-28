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

(defun %strict-name (tag)
  (format nil "strictfix-~A-~36R" tag (random (expt 36 8))))

(defun %strict-project (dir name source &key depends-on test-source)
  "Write system NAME into DIR: one file holding SOURCE, depending on DEPENDS-ON. With
TEST-SOURCE, also NAME/tests holding it, named by NAME's test-op. Returns DIR."
  (with-open-file (out (merge-pathnames (format nil "~A.asd" name) dir)
                       :direction :output :if-exists :supersede)
    (format out "(asdf:defsystem ~S :depends-on ~S :components ((:file \"a\"))~@[ :in-order-to ((asdf:test-op (asdf:test-op ~S)))~])~%"
            name depends-on (and test-source (format nil "~A/tests" name)))
    (when test-source
      (format out "(asdf:defsystem ~S :depends-on (~S) :components ((:file \"t\")))~%"
              (format nil "~A/tests" name) name)))
  (with-open-file (out (merge-pathnames "a.lisp" dir) :direction :output :if-exists :supersede)
    (write-line source out))
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
