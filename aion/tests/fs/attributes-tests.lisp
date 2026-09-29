;;;; attributes-tests.lisp --- FILE-ATTRIBUTES answers for paths attrib.exe could not (#349).

(in-package #:aion/fs/tests)

;;; FiveAM's current suite does not carry over from the file before.
(in-suite all)

(defun %unicode-directory ()
  "A fresh directory whose name has non-ASCII characters and brackets, as a native string."
  (let ((dir (concatenate 'string
                          (uiop:native-namestring (%fresh))
                          (coerce (list (code-char #xC5) (code-char #xF8) #\- #\[ #\1 #\] #\-
                                        (code-char #x6587) (code-char #x66F8))
                                  'string)
                          "\\")))
    (ensure-directories-exist (uiop:parse-native-namestring dir))
    dir))

(test file-attributes-reports-read-only-on-a-non-ascii-path
  ;; The case that failed with attrib.exe: a read-only file whose path is not ASCII.
  #+win32
  (let* ((dir (%unicode-directory))
         (file (concatenate 'string dir "r"
                            (string (code-char #xE9))
                            "sum" (string (code-char #xE9)) "[2].txt")))
    (unwind-protect
         (progn
           (with-open-file (s (uiop:parse-native-namestring file) :direction :output :if-exists :supersede)
             (write-string "x" s))
           (is (not (member :read-only (fs:file-attributes file))) "a new file is not read-only")
           (uiop:run-program (list "attrib" "+R" file) :output nil)
           (is (member :read-only (fs:file-attributes file)) "+R must report :read-only")
           (is (equal (fs:file-attributes file)
                      (fs:file-attributes (uiop:parse-native-namestring file)))
               "a string and a pathname for the same file must give the same answer")
           (is (member :directory (fs:file-attributes dir))))
      (ignore-errors (fs:delete-tree (uiop:parse-native-namestring dir)))))
  #-win32 (skip "Windows attributes"))

(test file-attributes-reports-a-junction-as-a-reparse-point
  #+win32
  (let* ((base (%fresh))
         (target (ensure-directories-exist (merge-pathnames "target/" base)))
         (link (merge-pathnames "junction/" base)))
    (unwind-protect
         (progn
           (%link link target)
           (let ((a (fs:file-attributes link)))
             (is (member :reparse-point a) "a junction must report :reparse-point: ~S" a)
             (is (member :directory a)))
           (is (not (member :reparse-point (fs:file-attributes target))) "its target is not a link"))
      (%cleanup base)))
  #-win32 (skip "Windows attributes"))

(test file-attributes-signals-with-the-windows-error-for-a-missing-path
  #+win32
  (let ((e (handler-case (progn (fs:file-attributes (merge-pathnames "missing.txt" (%fresh))) nil)
             (fs:file-attributes-error (e) e))))
    (is (typep e 'fs:file-attributes-error))
    (is (member (fs:file-attributes-error-code e) '(2 3)) "ERROR_FILE_NOT_FOUND or ERROR_PATH_NOT_FOUND"))
  #-win32 (signals error (fs:file-attributes "/")))

(test attrib-exe-read-as-utf-8-loses-the-non-ascii-path
  "The control for the first test: attrib.exe's output, read as UTF-8 the way the app read it,
does not contain the path it was asked about, so a parser of it finds no line for the file."
  #+win32
  (let* ((dir (%unicode-directory))
         (file (concatenate 'string dir (string (code-char #xE9)) ".txt")))
    (unwind-protect
         (progn
           (with-open-file (s (uiop:parse-native-namestring file) :direction :output :if-exists :supersede)
             (write-string "x" s))
           (let ((out (uiop:run-program (list "attrib" file) :output :string
                                        :external-format '(:utf-8 :replacement #\?)
                                        :ignore-error-status t)))
             (is (not (search file out))
                 "attrib's output read as UTF-8 must not contain the path, or this control shows nothing: ~S" out)))
      (ignore-errors (fs:delete-tree (uiop:parse-native-namestring dir)))))
  #-win32 (skip "attrib.exe is Windows-only"))
