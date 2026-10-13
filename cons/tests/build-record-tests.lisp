;;;; build-record-tests.lisp --- bin/cons says when it is older than its source (#526)

(in-package #:cons/tests)

(in-suite all)

(defun %dates-from (alist)
  (lambda (file) (cdr (assoc file alist :test #'string=))))

(test changed-files-finds-a-newer-file-and-a-missing-one
  (let ((record '(:commit nil :time 1000 :files ("a.lisp" "b.lisp" "c.asd"))))
    (multiple-value-bind (changed missing)
        (cons/build-record:changed-files
         record (%dates-from '(("a.lisp" . 900) ("b.lisp" . 1001) ("c.asd" . nil))))
      (is (equal '("b.lisp") changed))
      (is (equal '("c.asd") missing)))
    ;; The control: every file older than the build, or as old, is nothing to report.
    (multiple-value-bind (changed missing)
        (cons/build-record:changed-files
         record (%dates-from '(("a.lisp" . 900) ("b.lisp" . 1000) ("c.asd" . 10))))
      (is (null changed))
      (is (null missing)))))

(test the-image-files-are-the-tree-files-of-the-loaded-systems
  "cons is loaded from this tree in the test image, so its own files are recorded, relative to
the root, and nothing from outside the tree is."
  (let* ((root (%tree-root))
         (files (cons/build-record:image-files root)))
    (is (member "cons/cons.asd" files :test #'string=))
    (is (member "cons/src/build-record.lisp" files :test #'string=))
    (is (every (lambda (f) (probe-file (merge-pathnames f root))) files)
        "every recorded file is under the root")
    (is (notany (lambda (f) (or (search ".." f) (search "quicklisp" f))) files))))

(test the-bootstrap-inputs-are-bootstrap-lisp-and-the-scripts-it-loads
  "Copilot's review of #660: files bootstrap.lisp loads without ASDF go into the binary too."
  (let ((files (cons/build-record:bootstrap-inputs (%tree-root))))
    (dolist (f '("bootstrap.lisp" "scripts/dump-image.lisp" "scripts/heap-guard.lisp"
                 "scripts/human-path.lisp"))
      (is (member f files :test #'string=) "~A is not among ~S" f files))
    (is (every (lambda (f) (probe-file (merge-pathnames f (%tree-root)))) files))))

(test binary-root-is-the-tree-only-for-a-binary-in-its-bin-directory
  (tempdir:with-temporary-directory (dir "build-record")
    (let ((bin (merge-pathnames "bin/cons.exe" dir)))
      (ensure-directories-exist bin)
      ;; No bootstrap.lisp: not a tree.
      (is (null (cons/build-record:binary-root bin)))
      (with-open-file (o (merge-pathnames "bootstrap.lisp" dir) :direction :output)
        (write-line ";; a tree" o))
      (is (equal (namestring (truename dir))
                 (namestring (truename (cons/build-record:binary-root bin)))))
      ;; Beside bootstrap.lisp rather than in bin/: not a binary this tree built.
      (is (null (cons/build-record:binary-root (merge-pathnames "cons.exe" dir)))))))

(test check-reports-a-changed-file-once-and-is-silent-otherwise
  (tempdir:with-temporary-directory (dir "build-record")
    (let ((file (merge-pathnames "cons/src/x.lisp" dir)))
      (ensure-directories-exist file)
      (with-open-file (o file :direction :output) (write-line "(in-package :cl-user)" o))
      (let* ((date (file-write-date file))
             (stale (list :commit "0123456789abcdef0123456789abcdef01234567"
                          :time (1- date) :files '("cons/src/x.lisp")))
             (fresh (list :commit nil :time date :files '("cons/src/x.lisp"))))
        (let ((text (with-output-to-string (s)
                      (cons/build-record:check :record stale :root dir :stream s))))
          (is (search "cons/src/x.lisp has changed" text) "it said ~S" text)
          (is (search "from 0123456789ab" text) "it said ~S" text)
          (is (search "bootstrap.lisp --cons-only" text) "it said ~S" text))
        ;; The control: built after the file was written, so nothing is said.
        (is (string= "" (with-output-to-string (s)
                          (cons/build-record:check :record fresh :root dir :stream s))))
        ;; No record, as in an image bootstrap.lisp did not dump: nothing is compared.
        (is (null (cons/build-record:check :record nil :root dir)))))))

(test describe-build-names-the-commit-and-time
  (is (null (cons/build-record:describe-build :record nil)))
  (let ((line (cons/build-record:describe-build
               :record '(:commit "abc" :time 0 :files ()))))
    (is (search "built from abc at 1900-01-01 00:00:00 UTC" line) "it said ~S" line)))
