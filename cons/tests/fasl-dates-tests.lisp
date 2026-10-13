;;;; fasl-dates-tests.lisp --- a fasl dated the same second as its source is compiled again (#573)
;;;;
;;;; The first test is #573's reproduction, run in fresh SBCL children so that the method this
;;;; image may already hold cannot decide it: a one-file system is compiled, its source is
;;;; rewritten, and the source's write date is set to the fasl's. Without cons/fasl-dates the
;;;; child loads the old code, which is the control; with it, the new code.
;;;;
;;;; The second test checks that every entry point that compiles an app, or the tree for the gate,
;;;; loads cons/fasl-dates. A missing load is the way this fix stops working, and nothing else
;;;; would notice it.

(in-package #:cons/tests)

(in-suite all)

;;; %TREE-ROOT, the directory above cons/, is check-compile-tests.lisp's.

(defun %copy-write-date (from to)
  "Give the file TO the write date of the file FROM, to the precision the file system keeps."
  (if (uiop:os-windows-p)
      (uiop:run-program (list "powershell" "-NoProfile" "-NonInteractive" "-Command"
                              (format nil "(Get-Item -LiteralPath '~A').LastWriteTimeUtc = (Get-Item -LiteralPath '~A').LastWriteTimeUtc"
                                      (uiop:native-namestring to) (uiop:native-namestring from))))
      (uiop:run-program (list "touch" "-r" (uiop:native-namestring from)
                              (uiop:native-namestring to)))))

(defun %fasl-dates-child (dir with-fix)
  "Load the system s573 from DIR/sys/ in a fresh SBCL, with its fasls under DIR/cache/, and
return what its function SAYS returned. Only that directory and this tree's cons/ are in the
source registry. WITH-FIX loads cons/fasl-dates first."
  (let ((form (format nil "(progn (asdf:initialize-output-translations '(:output-translations (t (~S :**/ :*.*.*)) :ignore-inherited-configuration)) (asdf:initialize-source-registry '(:source-registry (:directory ~S) (:directory ~S) :ignore-inherited-configuration)) ~:[~;(asdf:load-system \"cons/fasl-dates\") ~](asdf:load-system \"s573\") (format t \"~~&SAYS ~~A~~%\" (funcall (find-symbol \"SAYS\" :s573))))"
                      (namestring (merge-pathnames "cache/" dir))
                      (namestring (merge-pathnames "sys/" dir))
                      (namestring (merge-pathnames "cons/" (%tree-root)))
                      with-fix)))
    (multiple-value-bind (out err code)
        (uiop:run-program (list (namestring sb-ext:*runtime-pathname*)
                                "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                                "--eval" "(require :asdf)" "--eval" form)
                          :output :string :error-output :output :ignore-error-status t)
      (declare (ignore err))
      (let ((at (search "SAYS " out)))
        (if (and (eql code 0) at)
            (string-trim '(#\Space #\Return #\Newline)
                         (subseq out (+ at 5) (position #\Newline out :start at)))
            (format nil "the child exited ~A:~%~A" code out))))))

(defun %write-s573 (dir version)
  (with-open-file (o (merge-pathnames "sys/a.lisp" dir) :direction :output :if-exists :supersede)
    (format o "(defpackage :s573 (:use :cl)) (in-package :s573) (defun says () ~S)~%" version)))

(test a-source-with-its-fasls-write-date-is-compiled-again
  (tempdir:with-temporary-directory (dir "fasl-dates")
    (let ((sys (merge-pathnames "sys/" dir)))
      (ensure-directories-exist sys)
      (with-open-file (o (merge-pathnames "s573.asd" sys) :direction :output)
        (write-line "(defsystem \"s573\" :components ((:file \"a\")))" o))
      (%write-s573 dir "version-1")
      (is (equal "version-1" (%fasl-dates-child dir nil)))
      (let ((fasl (first (directory (merge-pathnames "cache/**/a.fasl" dir))))
            (source (merge-pathnames "a.lisp" sys)))
        (is-true fasl "the first load wrote no fasl under ~A" dir)
        (when fasl
          (%write-s573 dir "version-2")
          (%copy-write-date fasl source)
          (is (= (file-write-date fasl) (file-write-date source)) "the dates were not made equal")
          ;; The control: ASDF alone keeps the fasl and runs the previous code.
          (is (equal "version-1" (%fasl-dates-child dir nil)))
          (is (equal "version-2" (%fasl-dates-child dir t)))
          ;; Compiled once more, then left alone: the new fasl is dated later than the source.
          (let ((date (file-write-date fasl)))
            (is (> date (file-write-date source)))
            (is (equal "version-2" (%fasl-dates-child dir t)))
            (is (= date (file-write-date fasl)) "the fasl was compiled again a second time")))))))

(defparameter *fasl-dates-entry-points*
  '(("bootstrap.lisp" 3)        ; the bin/cons image, the warm step and the platform packages
    ("cons/src/run.lisp" 1)     ; the cons loader, in process and in the --fresh child
    ("cons/templates/agent/files/scripts/build-{{name}}.lisp" 1)
    ("cons/templates/cli/files/scripts/build-{{name}}.lisp" 1)
    ("cons/templates/web/files/scripts/build-{{name}}.lisp" 1)
    ("scripts/build-desktop-app.lisp" 1)
    ("scripts/verify-tree.lisp" 1)
    ("scripts/check-compile.lisp" 1))
  "Each file that compiles an app or the tree, and how many loads of cons/fasl-dates it makes:
one per image it compiles in.")

(defun %count-loads (text)
  "How many forms in TEXT load cons/fasl-dates, written as quickload or load-system, the name
quoted as a string or a keyword, escaped or not."
  (loop for marker in '(":cons/fasl-dates)" "\"cons/fasl-dates\")" "\\\"cons/fasl-dates\\\")")
        sum (loop with start = 0
                  for at = (search marker text :start2 start)
                  while at
                  count (let ((before (subseq text (max 0 (- at 40)) at)))
                          (or (search "quickload" before) (search "load-system" before)))
                  do (setf start (1+ at)))))

(test every-entry-point-that-compiles-loads-cons-fasl-dates
  (dolist (entry *fasl-dates-entry-points*)
    (destructuring-bind (file wanted) entry
      (let ((path (merge-pathnames file (%tree-root))))
        (is-true (probe-file path) "~A is not in the tree" file)
        (when (probe-file path)
          (let ((found (%count-loads (uiop:read-file-string path))))
            (is (= wanted found) "~A loads cons/fasl-dates ~D time~:P, not ~D" file found wanted)))))))
