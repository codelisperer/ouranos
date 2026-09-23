;;;; setup-tests.lisp --- `cons setup`: drop-in write + stale-symlink detection.
;;;; (WITH-TEMP-TREE is defined in project-tests.lisp, same suite.)

(in-package #:cons/tests)
(in-suite all)

(test setup-writes-drop-in
  "SETUP writes <priority>-<name>.conf as a (:tree ROOT) drop-in under the given config
dir, naming it from the project's .asd."
  (with-temp-tree (root nested)
    (with-open-file (o (merge-pathnames "foo.asd" root)
                       :direction :output :if-exists :supersede)
      (write-string "(asdf:defsystem \"foo\")" o))
    (let ((cfg (merge-pathnames "cfg/" root)) (conf nil))
      (with-output-to-string (*standard-output*)
        (setf conf (cons/setup:setup :root root :priority 61 :config-dir cfg
                                     :local-projects nil)))
      (is (probe-file conf))
      (is (string= "61-foo.conf" (file-namestring conf)))
      (let ((text (uiop:read-file-string conf)))
        (is (search "(:tree" text))
        (is (search (substitute #\/ #\\
                                (namestring (uiop:ensure-directory-pathname root)))
                    text))))))

;;; Windows cannot create the symlink this one needs, so it does not run there -- and now
;;; SAYS so. It used to wrap the whole body in `unless`, which executed ZERO checks and still
;;; reported `ok`, so the missing coverage appeared only as an unexplained two-check
;;; difference between platforms and took a three-run reconciliation to account for (pre-publication issue 168).
;;; A SKIP is a result: counted, reasoned, and visible as `Skip: N`. The coverage gap is
;;; legitimate; being unable to see it was not.
;;;
;;; Keep the docstring SHORT. FiveAM prints it in brackets beside the test name in the skip
;;; report, so a paragraph here floods the gate output and buries the reason.

(test setup-detects-stale-self-link
  "%STALE-SELF-LINK flags a link resolving to ROOT, but not a real directory that is ROOT."
  (if (uiop:os-windows-p)
      (skip "symlink creation is Unix-only; %STALE-SELF-LINK is unexercised on Windows")
      (with-temp-tree (root nested)
        (let* ((lp (merge-pathnames "lp/" root))
               (link (merge-pathnames "foo" lp)))
          (ensure-directories-exist lp)
          (uiop:run-program (list "ln" "-s" (namestring root) (namestring link)))
          (is (cons/setup::%stale-self-link "foo" root lp))       ; link -> root: flagged
          (let ((realdir (merge-pathnames "bar/" lp)))
            (ensure-directories-exist realdir)
            (is (null (cons/setup::%stale-self-link "bar" realdir lp))))))))  ; real dir: not
