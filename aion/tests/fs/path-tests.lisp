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
  "The pathnames are parsed from names that CL:NAMESTRING writes differently from the native name,
and the test checks that it does, so a NATIVE-NAME that returned CL:NAMESTRING would fail: a name
with brackets, which SBCL escapes, and on Linux and macOS a name with a backslash (the hub's
review of #1123)."
  (let ((odd (format nil "dir~Ca*b?[1].txt" #\\)))
    (is (eq odd (aion/path:native-name odd)) "a string is returned as it is, not reparsed"))
  (dolist (name (list "a[1].txt" #-win32 (format nil "a~Cb.txt" #\\)))
    (let* ((native (concatenate 'string (uiop:native-namestring (uiop:temporary-directory)) name))
           (p (uiop:parse-native-namestring native)))
      (is (string/= native (namestring p))
          "CL:NAMESTRING writes ~S differently, so this case can tell the two apart" native)
      (is (string= native (aion/path:native-name p)) "~S comes back as ~S" native
          (aion/path:native-name p)))))

(test native-name-and-directory-pathname-keep-a-name-with-dots
  "A name with several dots, one that starts with a dot and one that ends with a dot, each given as a
pathname parsed from the native name, and as a folder name."
  (dolist (name '("a.tar.gz" ".hidden" "a.b."))
    (let ((p (uiop:parse-native-namestring name)))
      (is (string= name (aion/path:native-name p)) "~S comes back as ~S" name (aion/path:native-name p))
      (is (string= (concatenate 'string name (%sep))
                   (aion/path:native-name (aion/path:directory-pathname p)))
          "~S as a folder is ~S" name (aion/path:native-name (aion/path:directory-pathname p))))))

(test an-empty-name-is-the-current-folder-not-the-root
  "DIRECTORY-PATHNAME trimmed the separators off a name and added one, so \"\" and #P\"\" became the
root, / (the hub's review of #1123). An empty name is the current folder: a pathname with no
parts, which merges with *DEFAULT-PATHNAME-DEFAULTS*."
  (is (string= "" (aion/path:native-name "")))
  (is (string= "" (aion/path:native-name #p"")))
  (let ((base (uiop:temporary-directory)))
    (dolist (input (list "" #p""))
      (let ((dir (aion/path:directory-pathname input)))
        (is (equal '(nil nil nil nil)
                   (list (pathname-device dir) (pathname-directory dir)
                         (pathname-name dir) (pathname-type dir)))
            "~S gives a pathname with no parts: ~S" input dir)
        (is (equal base (merge-pathnames dir base)) "~S merged with ~S gives ~S" input base
            (merge-pathnames dir base))))))

(test a-temporary-directory-in-an-empty-folder-name-is-made-in-the-current-folder
  "(make-temporary-directory \"x\" :in \"\") made its folder in the current folder before #1123 and
must still. With an empty name made into the root, it was made in /, or failed there."
  (let ((base (%fresh)))
    (unwind-protect
         (let ((made (let ((*default-pathname-defaults* base))
                       (fs:make-temporary-directory "path-test" :in ""))))
           (is (eq :relative (first (pathname-directory made))) "~S is relative" made)
           (is-true (uiop:directory-exists-p (merge-pathnames made base))
                    "~S is made in ~S" made base))
      (%cleanup base))))

#+win32
(test a-drive-with-nothing-after-it-is-that-drives-current-folder
  "On Windows C: names drive C's current folder, and C:\\ its root. DIRECTORY-PATHNAME added a
separator to C: and so gave the root (the hub's review of #1123). C:a, a folder in drive C's
current folder, is kept relative to it."
  (let ((dir (aion/path:directory-pathname "C:")))
    (is (string= "C:" (aion/path:native-name dir)) "C: gives ~S" (aion/path:native-name dir))
    (is (null (pathname-directory dir)) "C: has no folder parts: ~S" dir))
  (is (string= "C:\\" (aion/path:native-name (aion/path:directory-pathname "C:\\"))))
  (dolist (input (list "C:a" "C:a\\" (uiop:parse-native-namestring "C:a")))
    (is (string= "C:a\\" (aion/path:native-name (aion/path:directory-pathname input)))
        "~S gives ~S" input (aion/path:native-name (aion/path:directory-pathname input))))
  (let ((p (uiop:parse-native-namestring "C:a[1]\\b.txt")))
    (is (string= "C:a[1]\\b.txt" (aion/path:native-name p)))))

#+win32
(test a-unc-path-keeps-its-server-and-share
  "A path on a network share, \\\\server\\share\\..., given as a string and as a pathname. Nothing is
read from the share, so no server is needed."
  (let ((file "\\\\server\\share\\d\\a[1].txt")
        (folder "\\\\server\\share\\d"))
    (is (string= file (aion/path:native-name (uiop:parse-native-namestring file))))
    (dolist (input (list folder (concatenate 'string folder "\\")
                         (uiop:parse-native-namestring folder)))
      (is (string= "\\\\server\\share\\d\\" (aion/path:native-name (aion/path:directory-pathname input)))
          "~S gives ~S" input (aion/path:native-name (aion/path:directory-pathname input))))))

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
