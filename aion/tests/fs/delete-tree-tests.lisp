;;;; delete-tree-tests.lisp --- a link inside or at the root of a tree does not take the outside with it.
;;;;
;;;; Every fixture plants a real link -- a junction made by `mklink /J' on Windows, a symbolic
;;;; link made by `ln -s' elsewhere -- pointing at a directory OUTSIDE the tree, and checks the
;;;; files there survive. The control runs uiop:delete-directory-tree over the same fixture and
;;;; must lose them, or the fixture is not planting a link the way the defect needs.

(defpackage #:aion/fs/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:fs #:aion/fs))
  (:export #:run-tests))

(in-package #:aion/fs/tests)

(def-suite all :description "aion/fs.")
(in-suite all)

(defun run-tests () (fiveam:run! 'all))

(defun %fresh ()
  (ensure-directories-exist
   (merge-pathnames (format nil "aion-fs-~36R/" (random (expt 36 10) (make-random-state t)))
                    (uiop:temporary-directory))))

(defun %write (path text)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede) (write-string text s))
  path)

(defun %link (link target)
  "Make LINK, a directory link to the directory TARGET: a junction on Windows, which needs no
privilege, and a symbolic link elsewhere."
  (let ((l (string-right-trim "/\\" (uiop:native-namestring link)))
        (tg (string-right-trim "/\\" (uiop:native-namestring target))))
    (if (uiop:os-windows-p)
        (uiop:run-program (list "cmd" "/c" "mklink" "/J" l tg) :output nil)
        (uiop:run-program (list "ln" "-s" tg l) :output nil))
    (assert (fs:link-p link) () "the fixture did not make a link at ~A" l)))

(defun %fixture ()
  "A base directory holding outside/precious.txt and tree/, where tree/ has a nested file and a
link, tree/sub/escape, to outside/. Returns (values BASE TREE OUTSIDE)."
  (let* ((base (%fresh))
         (outside (merge-pathnames "outside/" base))
         (tree (merge-pathnames "tree/" base)))
    (%write (merge-pathnames "precious.txt" outside) "keep")
    (%write (merge-pathnames "sub/deeper/a.txt" tree) "a")
    (%write (merge-pathnames "b.txt" tree) "b")
    (%link (merge-pathnames "sub/escape/" tree) outside)
    (values base tree outside)))

(defun %cleanup (base)
  ;; Through the function under test, which the tests below have shown safe on this fixture.
  (ignore-errors (fs:delete-tree base :if-does-not-exist :ignore)))

(test a-link-inside-the-tree-is-removed-and-its-target-survives
  (multiple-value-bind (base tree outside) (%fixture)
    (unwind-protect
         (progn
           (is (eq t (fs:delete-tree tree)))
           (is (null (probe-file tree)) "the tree must be gone")
           (is (probe-file (merge-pathnames "precious.txt" outside))
               "a file outside the tree, reached through a link inside it, must survive"))
      (%cleanup base))))

(test uiop-delete-directory-tree-loses-the-outside-file-through-the-same-link
  "The control: the same fixture through uiop:delete-directory-tree. On Windows it follows the
junction and deletes the outside file, which is #347. Elsewhere a symbolic link inside the tree
is not followed, so this checks the fixture only on Windows."
  (multiple-value-bind (base tree outside) (%fixture)
    (unwind-protect
         (progn
           (ignore-errors (uiop:delete-directory-tree tree :validate t))
           (if (uiop:os-windows-p)
               (is (null (probe-file (merge-pathnames "precious.txt" outside)))
                   "uiop must lose the outside file through the junction, or the fixture cannot show #347")
               (pass "a symbolic link inside a tree is not followed by uiop on this system")))
      (%cleanup base))))

(test a-root-that-is-a-link-is-refused-and-nothing-is-deleted
  (let* ((base (%fresh))
         (outside (merge-pathnames "outside/" base))
         (root (merge-pathnames "root-link/" base)))
    (unwind-protect
         (progn
           (%write (merge-pathnames "precious.txt" outside) "keep")
           (%link root outside)
           (signals fs:link-root-refused (fs:delete-tree root))
           (is (probe-file (merge-pathnames "precious.txt" outside)) "the target's file must survive")
           (is (fs:link-p root) "the link itself is left for the caller"))
      (%cleanup base))))

(test uiop-delete-directory-tree-empties-a-link-root
  "The control for the test above, on every system: uiop:delete-directory-tree given a link as
the root deletes the target's files."
  (let* ((base (%fresh))
         (outside (merge-pathnames "outside/" base))
         (root (merge-pathnames "root-link/" base)))
    (unwind-protect
         (progn
           (%write (merge-pathnames "precious.txt" outside) "keep")
           (%link root outside)
           (ignore-errors (uiop:delete-directory-tree root :validate t))
           (is (null (probe-file (merge-pathnames "precious.txt" outside)))
               "uiop must delete through a link root, or this fixture cannot show #347"))
      (%cleanup base))))

(test a-plain-tree-is-removed-with-read-only-files
  (let* ((base (%fresh))
         (tree (merge-pathnames "tree/" base))
         (ro (merge-pathnames "x/y/ro.txt" tree)))
    (unwind-protect
         (progn
           (%write ro "read-only")
           (if (uiop:os-windows-p)
               (uiop:run-program (list "attrib" "+R" (uiop:native-namestring ro)) :output nil)
               (uiop:run-program (list "chmod" "a-w" (uiop:native-namestring ro)) :output nil))
           (is (eq t (fs:delete-tree tree)))
           (is (null (probe-file tree))))
      (%cleanup base))))

(test a-link-whose-target-is-gone-is-removed-with-the-tree
  ;; UIOP:DIRECTORY-FILES and CL:DIRECTORY leave out a POSIX symbolic link whose target does
  ;; not exist, so a walk built on them never removed it, and the RMDIR of its directory failed
  ;; with ENOTEMPTY. Found by hyperion/view/tests, whose window-icon fixture holds such a link.
  ;; On Windows the dangling link is a junction; the file-symlink case needs a privilege that
  ;; mklink /J does not, so it is only planted on Linux and macOS.
  (let* ((base (%fresh))
         (tree (merge-pathnames "tree/" base))
         (gone (merge-pathnames "gone/" base))
         (dir-link (merge-pathnames "sub/dangling-dir/" tree)))
    (unwind-protect
         (progn
           (%write (merge-pathnames "b.txt" tree) "b")
           (%write (merge-pathnames "keep.txt" gone) "x")
           (ensure-directories-exist (merge-pathnames "sub/" tree))
           (%link dir-link gone)
           #-win32
           (let ((file-target (%write (merge-pathnames "file-target.txt" base) "t")))
             ;; A name with wildcard characters, since the POSIX walk parses each name itself.
             (%write (merge-pathnames (uiop:parse-native-namestring "a*b[1].txt") tree) "w")
             (uiop:run-program (list "ln" "-s" (uiop:native-namestring file-target)
                                     (uiop:native-namestring (merge-pathnames "dangling-file" tree)))
                               :output nil)
             (delete-file file-target)
             (is (null (uiop:directory-files tree "dangling-file"))
                 "the precondition: UIOP does not list a symbolic link whose target is gone"))
           (fs:delete-tree gone)
           (is (fs:link-p dir-link) "the precondition: the directory link is still there, dangling")
           (is (eq t (fs:delete-tree tree)))
           (is (null (probe-file tree)) "the tree must be gone, dangling links included"))
      (%cleanup base))))

(test a-missing-root-is-an-error-unless-ignored
  (let ((missing (merge-pathnames "not-there/" (%fresh))))
    (signals fs:delete-tree-error (fs:delete-tree missing))
    (is (null (fs:delete-tree missing :if-does-not-exist :ignore)))))

(test a-relative-root-is-refused
  ;; A filesystem root is refused by the same check, and deliberately not exercised here: if
  ;; the check were broken, the test would be deleting a drive.
  (signals error (fs:delete-tree #p"relative/dir/")))
