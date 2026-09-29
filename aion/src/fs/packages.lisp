;;;; packages.lisp --- aion/fs packages.

(defpackage #:aion/fs
  (:use #:cl)
  (:documentation "Filesystem operations the framework needs and UIOP does not give safely:
a tree delete that never follows a link out of the tree (#347).")
  (:export #:delete-tree #:delete-link #:link-p
           #:file-attributes #:file-attributes-error #:file-attributes-error-code
           #:link-root-refused #:delete-tree-error
           #:delete-tree-error-operation #:delete-tree-error-code))
