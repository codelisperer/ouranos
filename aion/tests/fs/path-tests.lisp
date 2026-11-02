;;;; path-tests.lisp --- aion/path: a path's native name, and a directory pathname built from it (#1103).
;;;;
;;;; aion/path has no suite of its own: aion/fs depends on it, so its tests run here. The folder
;;;; tests use %FRESH, %CLEANUP, %NATIVE-IN, %NATIVE-FOLDER and +ODD-NAMES+ from
;;;; delete-tree-tests.lisp, so each name is made on disk as a string that is never parsed, and the
;;;; pathname under test is checked against that folder.

(in-package #:aion/fs/tests)

;; A file's tests join the suite current when it is loaded, so name it here rather than rely on
;; the file before.
(in-suite all)

(test native-name-passes-a-string-through-and-converts-a-pathname
  (let ((odd (format nil "dir~Ca*b?[1].txt" #\\)))
    (is (eq odd (aion/path:native-name odd)) "a string is returned as it is, not reparsed"))
  (let ((p (uiop:parse-native-namestring
            (concatenate 'string (uiop:native-namestring (uiop:temporary-directory)) "x.txt"))))
    (is (string= (uiop:native-namestring p) (aion/path:native-name p)))))

(test native-name-refuses-what-names-no-single-file
  (signals type-error (aion/path:native-name nil))
  (signals type-error (aion/path:native-name 42))
  (signals simple-error (aion/path:native-name (make-pathname :name :wild :type "txt"
                                                              :directory '(:absolute "tmp")))))

(test native-name-translates-a-logical-pathname
  (let ((host "AIONPATHTESTS")
        (base (uiop:temporary-directory)))
    (setf (logical-pathname-translations host)
          `(("**;*.*.*" ,(merge-pathnames (make-pathname :directory '(:relative :wild-inferiors)
                                                         :name :wild :type :wild :version :wild)
                                          base))))
    (unwind-protect
         (is (string-equal (uiop:native-namestring (merge-pathnames "logical.txt" base))
                           (aion/path:native-name (logical-pathname (format nil "~A:LOGICAL.TXT" host)))))
      (setf (logical-pathname-translations host) nil))))

(test separator-p-follows-the-platform
  (is-true (aion/path:separator-p #\/))
  (is (eq (uiop:os-windows-p) (aion/path:separator-p #\\))
      "a backslash separates only on Windows")
  (is-false (aion/path:separator-p #\a)))

(test directory-pathname-names-the-folder-a-native-string-names
  "Each odd name is made on disk as a native string, then given to DIRECTORY-PATHNAME as that string
and as a pathname parsed from it with no trailing separator, which is the case
UIOP:ENSURE-DIRECTORY-PATHNAME got wrong (Copilot's review of #1109). Each result must be a
directory pathname whose native name is the folder's, and that folder must exist."
  (let ((base (%fresh)))
    (unwind-protect
         (dolist (name +odd-names+)
           (let* ((native (%native-folder (%native-in base name)))
                  (expected (concatenate 'string native (%sep))))
             (dolist (input (list native
                                  (concatenate 'string native (%sep))
                                  (uiop:parse-native-namestring native)))
               (let ((dir (aion/path:directory-pathname input)))
                 (is (null (pathname-name dir)) "~S gives a directory pathname: ~S" input dir)
                 (is (string= expected (uiop:native-namestring dir))
                     "~S gives ~S, not ~S" input (uiop:native-namestring dir) expected)
                 (is-true (uiop:directory-exists-p dir) "~S names the folder made" input)))))
      (%cleanup base))))

(test directory-pathname-keeps-a-filesystem-root
  (let ((root (if (uiop:os-windows-p) "C:\\" "/")))
    (is (string= root (uiop:native-namestring (aion/path:directory-pathname root))))))

(test a-temporary-directory-is-made-in-a-folder-given-as-a-native-string
  "MAKE-TEMPORARY-DIRECTORY passed IN through UIOP:ENSURE-DIRECTORY-PATHNAME, so a folder named
a[1] given as a string was parsed as a Lisp namestring (#1103)."
  (let ((base (%fresh)))
    (unwind-protect
         (let* ((in (%native-folder (%native-in base "a[1]")))
                (made (fs:make-temporary-directory "path-test" :in in)))
           (is (string= (concatenate 'string in (%sep))
                        (uiop:native-namestring (uiop:pathname-parent-directory-pathname made)))
               "made in ~S: ~S" in made)
           (is-true (uiop:directory-exists-p made)))
      (%cleanup base))))

(test link-p-and-delete-tree-take-a-logical-pathname
  "Through AION/PATH:NATIVE-NAME, LINK-P and DELETE-TREE translate a logical pathname. Before #1103
they gave the pathname to UIOP:NATIVE-NAMESTRING, which refuses a logical pathname with an error."
  (let ((base (%fresh))
        (host "AIONFSPATHTESTS"))
    (setf (logical-pathname-translations host)
          `(("**;*.*.*" ,(merge-pathnames (make-pathname :directory '(:relative :wild-inferiors)
                                                         :name :wild :type :wild :version :wild)
                                          base))))
    (unwind-protect
         (let* ((logical (logical-pathname (format nil "~A:DOOMED;" host)))
                (physical (translate-logical-pathname logical)))
           (%write (merge-pathnames "in.txt" physical) "x")
           (is-true (uiop:directory-exists-p physical) "the fixture made ~S" physical)
           (is-false (fs:link-p logical) "a folder is not a link")
           (is-true (fs:delete-tree logical))
           (is-false (uiop:directory-exists-p physical) "~S is gone" physical))
      (setf (logical-pathname-translations host) nil)
      (%cleanup base))))
