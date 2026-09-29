;;;; fs.lisp --- load aion/fs by path, for a script that runs before Quicklisp or ASDF's
;;;; source registry knows this tree (#347).
;;;;
;;;; aion/fs needs nothing but UIOP, and sb-posix on Unix, so its two files load directly. A
;;;; script that removes a directory tree uses aion/fs:delete-tree, which never follows a
;;;; junction or symbolic link out of the tree, rather than uiop:delete-directory-tree.

(require :asdf)
#+unix (require :sb-posix)
(let ((fs (merge-pathnames "../aion/src/fs/"
                           (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*)))))
  (unless (find-package "AION/FS")
    (load (merge-pathnames "packages.lisp" fs))
    (load (merge-pathnames "delete-tree.lisp" fs))))
