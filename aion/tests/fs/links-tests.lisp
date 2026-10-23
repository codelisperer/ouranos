;;;; links-tests.lisp --- make-directory-link and make-file-link (#825).
;;;;
;;;; Each round trip makes a link with the function under test, checks that LINK-P sees it and that
;;;; a file in the target can be read through it, removes it with DELETE-LINK, and checks that the
;;;; target and its file are untouched. A refusal must be a LINK-ERROR with nothing left at the
;;;; link's path. The fixtures use %FRESH and %WRITE from delete-tree-tests.lisp.

(in-package #:aion/fs/tests)

;; A file's tests join the suite current when it is loaded, so name it here rather than rely on
;; the file before.
(in-suite all)

(defun %read (path)
  (with-open-file (s path) (read-line s nil "")))

(defun %name (path)
  "PATH's native namestring without a trailing separator, to compare two names for one path."
  (string-right-trim "/\\" (uiop:native-namestring path)))

(defun %refusal (fn)
  "Call FN and return the LINK-ERROR it signals, or NIL when it signals none."
  (handler-case (progn (funcall fn) nil)
    (fs:link-error (c) c)))

(test a-directory-link-round-trips-and-leaves-its-target-intact
  (let* ((base (%fresh))
         (target (merge-pathnames "target/" base))
         (link (merge-pathnames "link/" base)))
    (unwind-protect
         (progn
           (%write (merge-pathnames "keep.txt" target) "keep")
           (is (equal (%name (fs:make-directory-link link target)) (%name link))
               "it returns the link")
           (is-true (fs:link-p link))
           (is (equal "keep" (%read (merge-pathnames "keep.txt" link))) "the target is reached through it")
           #+win32
           (is (member :reparse-point (fs:file-attributes link)) "a junction is a reparse point")
           (is (eq t (fs:delete-link link)))
           (is-false (fs:link-p link))
           (is-false (probe-file (merge-pathnames "keep.txt" link)) "the link is gone")
           (is (equal "keep" (%read (merge-pathnames "keep.txt" target))) "the target is intact"))
      (%cleanup base))))

(test delete-tree-does-not-follow-a-link-make-directory-link-made
  "The case the shell-out fixtures exist for, with the link made by MAKE-DIRECTORY-LINK."
  (let* ((base (%fresh))
         (outside (merge-pathnames "outside/" base))
         (tree (merge-pathnames "tree/" base)))
    (unwind-protect
         (progn
           (%write (merge-pathnames "precious.txt" outside) "keep")
           (%write (merge-pathnames "a.txt" tree) "a")
           (fs:make-directory-link (merge-pathnames "escape/" tree) outside)
           (is (eq t (fs:delete-tree tree)))
           (is-false (probe-file tree))
           (is (equal "keep" (%read (merge-pathnames "precious.txt" outside)))))
      (%cleanup base))))

(test make-directory-link-refuses-and-leaves-nothing-behind
  (let* ((base (%fresh))
         (target (merge-pathnames "target/" base))
         (file (%write (merge-pathnames "plain.txt" base) "x")))
    (unwind-protect
         (progn
           (ensure-directories-exist target)
           (let* ((existing (ensure-directories-exist (merge-pathnames "existing/" base)))
                  (inside (%write (merge-pathnames "inside.txt" existing) "was here"))
                  (c (%refusal (lambda () (fs:make-directory-link existing target)))))
             (is (eq :exists (and c (fs:link-error-code c))) "~S" c)
             (is-false (fs:link-p existing) "the directory that was there is left as it was")
             (is (equal "was here" (%read inside)) "and what it held survives"))
           (let* ((link (merge-pathnames "to-nothing/" base))
                  (c (%refusal (lambda () (fs:make-directory-link link (merge-pathnames "absent/" base))))))
             (is (eq :target-missing (and c (fs:link-error-code c))) "~S" c)
             (is-false (probe-file link)))
           (let* ((link (merge-pathnames "to-a-file/" base))
                  (c (%refusal (lambda () (fs:make-directory-link link file)))))
             (is (eq :target-not-a-directory (and c (fs:link-error-code c))) "~S" c)
             (is-false (probe-file link)))
           (let* ((link (merge-pathnames "no-such-parent/link/" base))
                  (c (%refusal (lambda () (fs:make-directory-link link target)))))
             (is-true c "a link whose parent does not exist is refused, not made quietly")
             (is (integerp (and c (fs:link-error-code c))) "the operating system's own code: ~S" c)
             (is-false (probe-file (merge-pathnames "no-such-parent/" base)))))
      (%cleanup base))))

(test a-file-link-round-trips-or-is-refused-for-want-of-the-privilege
  "On Windows a symbolic link needs Developer Mode or the privilege, so either outcome is right
there, but one of them must happen. Elsewhere the link must be made."
  (let* ((base (%fresh))
         (target (%write (merge-pathnames "target.txt" base) "keep"))
         (link (merge-pathnames "link.txt" base)))
    (unwind-protect
         (let* ((made nil)
                (refusal (%refusal (lambda () (setf made (fs:make-file-link link target))))))
           #-win32 (is-false refusal "~S" refusal)
           (is (or made (typep refusal 'fs:link-not-permitted)) "made ~S, refused ~S" made refusal)
           (cond (made
                  (is-true (fs:link-p link))
                  (is (equal "keep" (%read link)))
                  (is (eq t (fs:delete-link link)))
                  (is-false (probe-file link)))
                 (t (is-false (probe-file link) "nothing is left after a refusal")))
           (is (equal "keep" (%read target)) "the target is intact"))
      (%cleanup base))))

;;; --- the hub's review of #853 -------------------------------------------------------------

(test a-relative-target-with-dot-dot-makes-a-link-that-reaches-it
  "From inside base/here/, the target is ../target and the link is ../link, both relative. On
Windows the junction's target must be a full path with .. resolved, or the junction points at
nothing while LINK-P still says it is a link; reading a file through it is what tells them apart."
  (let* ((base (%fresh))
         (here (ensure-directories-exist (merge-pathnames "here/" base)))
         (target (merge-pathnames "target/" base))
         (link (merge-pathnames "link/" base)))
    (unwind-protect
         (progn
           (%write (merge-pathnames "keep.txt" target) "keep")
           (uiop:with-current-directory (here)
             (fs:make-directory-link (format nil "..~Clink" (if (uiop:os-windows-p) #\\ #\/))
                                     (format nil "..~Ctarget" (if (uiop:os-windows-p) #\\ #\/))))
           (is-true (fs:link-p link))
           (is (equal "keep" (%read (merge-pathnames "keep.txt" link))) "the file is read through it")
           (is (eq t (fs:delete-link link)))
           (is (equal "keep" (%read (merge-pathnames "keep.txt" target)))))
      (%cleanup base))))

(test make-file-link-refuses-and-leaves-nothing-behind
  (let* ((base (%fresh))
         (target (%write (merge-pathnames "target.txt" base) "keep"))
         (taken (%write (merge-pathnames "taken.txt" base) "mine"))
         (directory (ensure-directories-exist (merge-pathnames "a-directory/" base))))
    (unwind-protect
         (progn
           (let ((c (%refusal (lambda () (fs:make-file-link taken target)))))
             (is (eq :exists (and c (fs:link-error-code c))) "~S" c)
             (is (equal "mine" (%read taken)) "the file that was there survives"))
           (let* ((link (merge-pathnames "to-a-directory.txt" base))
                  (c (%refusal (lambda () (fs:make-file-link link directory)))))
             (is (eq :target-not-a-file (and c (fs:link-error-code c))) "~S" c)
             (is-false (probe-file link))))
      (%cleanup base))))

(test a-failed-check-is-a-link-error-not-another-condition
  "The link's parent is a file, so asking the operating system about the link's path fails with
an error other than not-found (ENOTDIR on POSIX, ERROR_PATH_NOT_FOUND or ERROR_DIRECTORY on
Windows). It must come back as LINK-ERROR."
  (let* ((base (%fresh))
         (target (ensure-directories-exist (merge-pathnames "target/" base)))
         (file (%write (merge-pathnames "plain.txt" base) "x")))
    (unwind-protect
         (let ((c (handler-case (progn (fs:make-directory-link
                                        (concatenate 'string (%name file)
                                                     (if (uiop:os-windows-p) "\\l" "/l"))
                                        target)
                                       nil)
                    (error (e) e))))
           (is (typep c 'fs:link-error) "~S" c)
           (is (equal "x" (%read file))))
      (%cleanup base))))

(test a-directory-link-to-a-link-that-reaches-a-file-is-refused
  "A target that is a link is followed to see what it reaches. Where a file link cannot be made
for want of the privilege, there is nothing to test, and the test says so by checking only that."
  (let* ((base (%fresh))
         (file (%write (merge-pathnames "plain.txt" base) "x"))
         (file-link (merge-pathnames "file-link.txt" base)))
    (unwind-protect
         (let ((made (handler-case (fs:make-file-link file-link file)
                       (fs:link-not-permitted () nil))))
           (if made
               (let* ((link (merge-pathnames "dir-link/" base))
                      (c (%refusal (lambda () (fs:make-directory-link link file-link)))))
                 (is (eq :target-not-a-directory (and c (fs:link-error-code c))) "~S" c)
                 (is-false (probe-file link)))
               (is-true #+win32 t #-win32 nil "a file link is refused only on Windows")))
      (%cleanup base))))

#+win32
(test a-windows-target-in-long-form-works-and-a-unc-target-is-refused
  (let* ((base (%fresh))
         (target (merge-pathnames "target/" base))
         (link (merge-pathnames "link/" base)))
    (unwind-protect
         (progn
           (%write (merge-pathnames "keep.txt" target) "keep")
           (fs:make-directory-link link (concatenate 'string "\\\\?\\" (%name target)))
           (is (equal "keep" (%read (merge-pathnames "keep.txt" link)))
               "a \\\\?\\ target loses the prefix and the junction reaches it")
           (fs:delete-link link)
           (let ((c (%refusal (lambda () (fs:make-directory-link link "\\\\server\\share\\dir")))))
             (is (eq :target-unc (and c (fs:link-error-code c))) "~S" c)
             (is-false (probe-file link))))
      (%cleanup base))))
