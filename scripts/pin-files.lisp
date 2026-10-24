;;;; pin-files.lisp --- which *.pin files a checker reads. LOADed by check-pins.lisp and
;;;; check-upstream.lisp, so both walk the same tree (#808).
;;;;
;;;; Left out:
;;;;   - anything under a .git directory;
;;;;   - the top-level build output .gitignore names: vendor/, dist/ and dist-*/. Only at the
;;;;     top: hyperion/assets/vendor/ASSETS.pin and hyperion/src/vendor/PLURALS.pin are real
;;;;     pins in directories that happen to be called vendor;
;;;;   - another checkout nested inside this one, such as a git worktree made under the tree.
;;;;     Its pins belong to its own tree, and reading them here reports that tree's state.

(defpackage #:pin-files
  (:use #:cl)
  (:export #:pin-files))
(in-package #:pin-files)

(defun %top-level-excluded-p (first-directory)
  "Is FIRST-DIRECTORY, a path's first directory below the root, build output .gitignore names?"
  (or (member first-directory '("vendor" "dist") :test #'string=)
      (and (> (length first-directory) 5) (string= "dist-" first-directory :end2 5))))

(defun %checkout-p (directory)
  "Does DIRECTORY hold a .git, a directory in a clone or a file in a worktree?"
  (or (uiop:file-exists-p (merge-pathnames ".git" directory))
      (uiop:directory-exists-p (merge-pathnames ".git/" directory))))

(defun %excluded-p (path root)
  "Should PATH, a file under ROOT, be left out of the walk?"
  (let ((directories (rest (pathname-directory (enough-namestring path root)))))
    (or (member ".git" directories :test #'string=)
        (and directories (%top-level-excluded-p (first directories)))
        ;; A nested checkout: some directory between ROOT and PATH holds its own .git.
        (loop for depth from 1 to (length directories)
              thereis (%checkout-p (merge-pathnames
                                    (make-pathname :directory (cons :relative (subseq directories 0 depth)))
                                    root))))))

(defun pin-files (root)
  "Every *.pin file under ROOT that a checker reads, sorted by path."
  (sort (remove-if (lambda (p) (%excluded-p p root))
                   (directory (merge-pathnames "**/*.pin" root)))
        #'string< :key #'namestring))
