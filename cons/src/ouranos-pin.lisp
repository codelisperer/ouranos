;;;; ouranos-pin.lisp --- ouranos.pin: the Ouranos release an app was made from (#716)
;;;;
;;;; The maintainer decided on 2026-11-24 that every app records this ("ouranos.pin yes", #716).
;;;; AGENTS.md says apps pin a framework release; before this file nothing in an app recorded
;;;; which one, so no tool could tell an app what had changed since it was made.
;;;;
;;;; The file, written by `cons init' and by `cons conform' when it is missing:
;;;;
;;;;   # comment lines
;;;;   release v0.1.7
;;;;   commit  9e2915f1...
;;;;
;;;; `release' is the newest v* tag at or before the framework commit; `commit' is that commit,
;;;; in full. An app built against a checkout past its last release still gets the release it
;;;; is past, and the commit says exactly where.

(in-package #:cons/ouranos-pin)

(defparameter +pin-file+ "ouranos.pin")

(defvar *framework* nil
  "When set, the framework root to use instead of the tree cons was loaded from. The tests bind
it to a fixture repository whose tags they made, because a CI checkout has no tags.")

(defun framework-root ()
  "The root of the Ouranos tree cons was loaded from, the directory above cons/'s, or
*FRAMEWORK* when it is set."
  (or *framework*
      (let ((cons-dir (ignore-errors (asdf:system-source-directory "cons"))))
        (and cons-dir (uiop:pathname-parent-directory-pathname cons-dir)))))

(defun %git (dir &rest args)
  "Trimmed stdout of git ARGS run in DIR, or NIL on any failure: no git, not a repository,
nothing matched. Never signals."
  (handler-case
      (multiple-value-bind (out err code)
          (uiop:run-program (append (list "git" "-C" (uiop:native-namestring dir)) args)
                            :output '(:string :stripped t) :error-output nil
                            :ignore-error-status t)
        (declare (ignore err))
        (and (eql code 0) (plusp (length out)) out))
    (error () nil)))

(defun framework-release (&optional (root (framework-root)))
  "(values release commit) for the framework checkout at ROOT: the newest v* tag at or before
HEAD, and HEAD in full. NIL for either that git cannot tell."
  (when root
    (values (%git root "describe" "--tags" "--match" "v[0-9]*" "--abbrev=0")
            (%git root "rev-parse" "HEAD"))))

(defun pin-text (release commit)
  "The text of an ouranos.pin naming RELEASE and COMMIT."
  (format nil "# The Ouranos release this app was made from, written by `cons init' or `cons conform'.~%# `cons outdated' compares it with the framework checkout and with the newest release (#716).~%# Change it when the app moves to a newer release.~%~%release ~A~%commit  ~A~%"
          release commit))

(defun write-ouranos-pin (root &key force (framework (framework-root)))
  "Write ROOT/ouranos.pin naming the release and commit of FRAMEWORK, unless the file exists
and FORCE is false. Returns :created, :exists, or :unknown when git cannot tell the release;
then nothing is written and a line says why."
  (let ((path (merge-pathnames +pin-file+ root)))
    (cond ((and (probe-file path) (not force))
           (format t "  skip   ~A (exists)~%" +pin-file+)
           :exists)
          (t
           (multiple-value-bind (release commit) (framework-release framework)
             (cond ((and release commit)
                    (with-open-file (s path :direction :output :if-exists :supersede
                                            :if-does-not-exist :create :external-format :utf-8)
                      (write-string (pin-text release commit) s))
                    (format t "  create ~A (~A, ~A)~%" +pin-file+ release (subseq commit 0 (min 8 (length commit))))
                    :created)
                   (t
                    (format t "  skip   ~A: cannot tell which Ouranos release this is (~A is not a git checkout with a v* tag)~%"
                            +pin-file+ (if framework (uiop:native-namestring framework) "the framework"))
                    :unknown)))))))

(defun read-ouranos-pin (root)
  "The release and commit ROOT/ouranos.pin names, as (values release commit), or NIL when there
is no file. A field the file lacks is NIL."
  (let ((path (merge-pathnames +pin-file+ root)))
    (when (probe-file path)
      (let ((release nil) (commit nil))
        (with-open-file (in path :external-format :utf-8)
          (loop for line = (read-line in nil nil)
                while line
                do (let* ((trimmed (string-trim '(#\Space #\Tab #\Return) line))
                          (words (remove "" (uiop:split-string trimmed :separator '(#\Space #\Tab))
                                         :test #'string=)))
                     (when (and words (not (char= #\# (char trimmed 0))))
                       (cond ((string= (first words) "release") (setf release (second words)))
                             ((string= (first words) "commit") (setf commit (second words))))))))
        (values release commit)))))
