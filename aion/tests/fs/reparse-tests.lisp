;;;; reparse-tests.lisp --- REPARSE-KIND tells a link from a cloud placeholder (#1164).
;;;;
;;;; The links are made with MAKE-DIRECTORY-LINK and MAKE-FILE-LINK, so each test reads the tag
;;;; Windows really wrote. A cloud placeholder cannot be made without registering a sync root
;;;; with Windows, so :CLOUD is checked through REPARSE-TAG-KIND on the tags Windows defines.

(in-package #:aion/fs/tests)

;; A file's tests join the suite current when it is loaded, so name it here rather than rely on
;; the file before.
(in-suite all)

(test reparse-tag-kind-names-each-kind-of-tag
  (is (eq :symlink (fs:reparse-tag-kind #xA000000C)) "IO_REPARSE_TAG_SYMLINK")
  (is (eq :junction (fs:reparse-tag-kind #xA0000003)) "IO_REPARSE_TAG_MOUNT_POINT")
  (is (eq :cloud (fs:reparse-tag-kind #x9000001A)) "IO_REPARSE_TAG_CLOUD")
  (is (eq :cloud (fs:reparse-tag-kind #x9000101A)) "IO_REPARSE_TAG_CLOUD_1")
  (is (eq :cloud (fs:reparse-tag-kind #x9000601A)) "IO_REPARSE_TAG_CLOUD_6, which OneDrive uses")
  (is (eq :cloud (fs:reparse-tag-kind #x9000F01A)) "IO_REPARSE_TAG_CLOUD_F")
  (is (eq :other (fs:reparse-tag-kind #x8000001B)) "IO_REPARSE_TAG_APPEXECLINK")
  (is (eq :other (fs:reparse-tag-kind #x80000013)) "IO_REPARSE_TAG_DEDUP")
  (is (eq :other (fs:reparse-tag-kind #x9000001B))
      "a tag one away from IO_REPARSE_TAG_CLOUD is not a cloud tag")
  (is (null (fs:reparse-tag-kind nil))))

(test a-plain-file-and-directory-are-no-kind-of-link
  (let* ((base (%fresh))
         (file (merge-pathnames "plain.txt" base)))
    (unwind-protect
         (progn
           (%write file "x")
           (is (null (fs:reparse-kind file)))
           (is (null (fs:reparse-kind base)))
           (is (null (fs:reparse-tag file)))
           (is (null (fs:reparse-tag base))))
      (%cleanup base))))

(test a-directory-link-is-a-junction-on-windows-and-a-symlink-elsewhere
  "MAKE-DIRECTORY-LINK makes a junction on Windows and a symbolic link elsewhere. The link is in
a folder named with brackets and given as a native string, which REPARSE-KIND must not parse."
  (let* ((base (%fresh))
         (folder (concatenate 'string (%name base) (if (uiop:os-windows-p) "\\" "/") "a [b]"))
         (target (concatenate 'string folder (if (uiop:os-windows-p) "\\" "/") "target"))
         (link (concatenate 'string folder (if (uiop:os-windows-p) "\\" "/") "link")))
    (unwind-protect
         (progn
           (ensure-directories-exist (uiop:parse-native-namestring
                                      (concatenate 'string target (if (uiop:os-windows-p) "\\" "/"))))
           (fs:make-directory-link link target)
           #+win32
           (progn
             (is (eql #xA0000003 (fs:reparse-tag link)) "tag ~@[#x~X~]" (fs:reparse-tag link))
             (is (eq :junction (fs:reparse-kind link))))
           #-win32
           (is (eq :symlink (fs:reparse-kind link)))
           (is (null (fs:reparse-kind target)) "the link's target is not a link")
           (is-true (fs:link-p link) "LINK-P still sees the link"))
      (%cleanup base))))

(test a-junction-made-by-mklink-is-a-junction
  "The same check on a junction made by Windows' own mklink /J (on Linux and macOS, ln -s), so
the tag REPARSE-KIND reads is not only one that aion/fs itself wrote."
  (let* ((base (%fresh))
         (target (ensure-directories-exist (merge-pathnames "target/" base)))
         (link (merge-pathnames "junction/" base)))
    (unwind-protect
         (progn
           (%link link target)
           (is (eq #+win32 :junction #-win32 :symlink (fs:reparse-kind link))))
      (%cleanup base))))

(test a-file-link-is-a-symlink
  (let* ((base (%fresh))
         (target (merge-pathnames "target.txt" base))
         (link (merge-pathnames "link.txt" base)))
    (unwind-protect
         (progn
           (%write target "x")
           (let ((refusal (%refusal (lambda () (fs:make-file-link link target)))))
             (if (typep refusal 'fs:link-not-permitted)
                 (skip "this process may not make a symbolic link (no Developer Mode or privilege)")
                 (progn
                   (is (null refusal) "make-file-link: ~A" refusal)
                   #+win32
                   (is (eql #xA000000C (fs:reparse-tag link)) "tag ~@[#x~X~]" (fs:reparse-tag link))
                   (is (eq :symlink (fs:reparse-kind link)))
                   (is (null (fs:reparse-kind target)))))))
      (%cleanup base))))

(test reparse-kind-signals-for-a-missing-path
  (let* ((missing (merge-pathnames "missing.txt" (%fresh)))
         (e (handler-case (progn (fs:reparse-kind missing) nil)
              (fs:reparse-kind-error (e) e))))
    (is (typep e 'fs:reparse-kind-error))
    (is (member (and e (fs:reparse-kind-error-code e)) '(2 3))
        "ERROR_FILE_NOT_FOUND or ERROR_PATH_NOT_FOUND on Windows, ENOENT elsewhere: ~A" e)))
