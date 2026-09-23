;;;; project-tests.lisp --- cons/project runtime root discovery.

(in-package #:cons/tests)
(in-suite all)

(defmacro with-temp-tree ((root nested) &body body)
  "Bind ROOT to a fresh empty temp directory and NESTED to a deep subdir under it
(both created), run BODY, then delete the tree. No .git marker is created -- BODY adds
markers as it needs them."
  `(let* ((,root (uiop:ensure-directory-pathname
                  (merge-pathnames (format nil "cons-project-test-~d/" (get-universal-time))
                                   (uiop:temporary-directory))))
          (,nested (uiop:ensure-directory-pathname (merge-pathnames "a/b/c/" ,root))))
     (declare (ignorable ,root ,nested))
     (unwind-protect
          (progn (ensure-directories-exist ,nested) ,@body)
       (uiop:delete-directory-tree ,root :validate (constantly t)
                                         :if-does-not-exist :ignore))))

(test find-root-walks-up-to-marker
  "FIND-ROOT returns the nearest ancestor holding a root marker; PROJECT-ROOT returns
the same."
  (with-temp-tree (root nested)
    (ensure-directories-exist (merge-pathnames ".git/" root)) ; the marker
    (is (equal (namestring (truename root))
               (namestring (cons/project:find-root nested))))
    (is (equal (namestring (truename root))
               (namestring (cons/project:project-root nested))))))

(test find-root-nil-and-fallback-when-no-marker
  "With no marker anywhere up the tree, FIND-ROOT is NIL and PROJECT-ROOT falls back
to the start directory."
  (with-temp-tree (root nested)
    (let ((cons/project:*root-markers* '(".cons-no-such-marker-xyz")))
      (is (null (cons/project:find-root nested)))
      (is (equal (namestring (truename nested))
                 (namestring (cons/project:project-root nested)))))))

(test ensure-source-registry-points-at-root
  "ENSURE-SOURCE-REGISTRY returns the (directory) root it registered and does not error."
  (with-temp-tree (root nested)
    (unwind-protect
         ;; ensure-source-registry does not truename its arg, so compare to the raw
         ;; root (not (truename root) -- macOS /var vs /private/var would differ).
         (is (equal (namestring (uiop:ensure-directory-pathname root))
                    (namestring (cons/project:ensure-source-registry root))))
      ;; restore ambient discovery -- don't leave ASDF pointed at a temp dir that
      ;; with-temp-tree is about to delete.
      (asdf:clear-source-registry))))
