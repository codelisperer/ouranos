;;;; template.lisp --- `cons template`: validate a template by USING it.
;;;;
;;;; A template that has never been generated *and built* is a template that does not
;;;; work. This exists before third-party templates do, deliberately (design §7 step 3):
;;;; the moment templates are authored outside this repo, the only thing standing between
;;;; "published" and "rotted" is a check that runs them.
;;;;
;;;;   cons template check            # the template in the current directory
;;;;   cons template check ./saas     # a directory
;;;;   cons template check web        # a built-in, by name
;;;;
;;;; The check is deliberately not an inspection. Reading a manifest proves the manifest
;;;; parses; scaffolding proves the markers fill; only loading the result proves the .asd
;;;; it generated is a system Lisp will accept. Same principle as scripts/verify-tree.lisp
;;;; -- "exited 0" is not "the tests ran", and "files appeared" is not "it builds".

(in-package #:cons/template)

(defparameter *check-project-name* "consplate"
  "The project name a check generates under. Deliberately not the template's own name:
this becomes an ASDF system and a package, and colliding with something already loaded in
the image would make the check fail for a reason that has nothing to do with the template.")

(defun %quicklisp-setup ()
  (namestring (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))

(defun %count-files (root)
  "Every file under ROOT, recursively -- the top level alone would report 7 for a project
that has 16, and a number that is quietly wrong is worse than no number."
  (let ((n 0))
    (uiop:collect-sub*directories
     (uiop:ensure-directory-pathname root) t t
     (lambda (dir) (incf n (length (uiop:directory-files dir)))))
    n))

(defun %build-forms (root name)
  "The --eval forms that load the generated project in a fresh image.

The source registry is set from a FORM rather than an environment variable: the env-var
syntax needs a platform-specific separator, and getting that wrong fails as `system not
found`, which reads exactly like the template being broken. :inherit-configuration keeps
the tree's own systems reachable, so a template may depend on hyperion or praxeon."
  (list "--eval" (format nil "(load ~S)" (%quicklisp-setup))
        "--eval" (format nil "(asdf:initialize-source-registry '(:source-registry (:tree ~S) :inherit-configuration))"
                         (namestring root))
        ;; Load the test system too: its defsystem stanza is generated as well, and a typo
        ;; there is invisible until someone first runs the suite.
        "--eval" (format nil "(ql:quickload \"~A\")" name)
        "--eval" (format nil "(ql:quickload \"~A/tests\")" name)
        "--eval" "(uiop:quit 0)"))

(defun check (designator &key (name *check-project-name*) keep (stream *standard-output*))
  "Generate DESIGNATOR into a temporary directory and BUILD what comes out.

Returns (values OK-P ROOT OUTPUT). KEEP leaves the directory in place, which is what you
want the moment it fails. Never signals for a template that simply does not work -- a
failed check is a result, and the caller decides whether that is fatal."
  (let* ((template (cons/init:resolve-template designator))
         ;; CREATED, not chosen: see cons/src/tempdir.lisp. This used to build a name from
         ;; (random ...) and hand it to ENSURE-DIRECTORIES-EXIST, which succeeds on a
         ;; directory that already exists and follows a symlink to it (pre-publication issue 204).
         (work (tempdir:make-temporary-directory
                (string-downcase (cons/init:template-name template))))
         (root (merge-pathnames (format nil "~A/" name) work))
         (ok nil)
         (output ""))
    (unwind-protect
         (progn
           (format stream "~&checking template ~(~A~) (~A)~%"
                   (cons/init:template-name template)
                   (namestring (cons/init:template-directory template)))
           ;; 1. Generate. The scaffold log is noise here; what matters is what it left.
           (let ((*standard-output* (make-broadcast-stream)))
             (cons/init:scaffold name :template designator :target work))
           (format stream "  generated ~D files~%" (%count-files root))
           ;; 2. Build it, in a fresh sbcl. `sbcl` from PATH, as every other cons
           ;; subprocess does -- and a cold image is the point: it proves the generated
           ;; .asd stands on its own rather than benefiting from whatever this image has
           ;; already loaded.
           (multiple-value-bind (out err code)
               (uiop:run-program (append (list "sbcl" "--dynamic-space-size" "4096"
                                               "--noinform" "--non-interactive")
                                         (%build-forms root name))
                                 :directory root
                                 :output '(:string :stripped t)
                                 :error-output '(:string :stripped t)
                                 :ignore-error-status t)
             (setf output (format nil "~A~%~A" out err)
                   ok (zerop code))
             (if ok
                 (format stream "  builds: ~A and ~A/tests load in a cold image~%" name name)
                 (progn
                   (format stream "  FAILED to build (sbcl exited ~D)~%" code)
                   (format stream "~&~A~%" (string-trim '(#\Newline) output)))))
           (values ok root output))
      (if (and keep (not ok))
          (format stream "  left in place: ~A~%" (namestring work))
          (uiop:delete-directory-tree work :validate t :if-does-not-exist :ignore)))))

(defun check-all (&key (stream *standard-output*))
  "Check every built-in template. Returns T when all of them build."
  (let ((failed '()))
    (dolist (template (cons/init:templates))
      (unless (check (cons/init:template-name template) :stream stream)
        (push (cons/init:template-name template) failed)))
    (if failed
        (format stream "~&~D of ~D templates failed: ~{~(~A~)~^ ~}~%"
                (length failed) (length (cons/init:templates)) (reverse failed))
        (format stream "~&all ~D built-in templates build~%" (length (cons/init:templates))))
    (null failed)))
