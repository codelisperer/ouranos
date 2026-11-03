;;;; reparse.lisp --- which kind of Windows reparse point a path is (#1164).
;;;;
;;;; FILE-ATTRIBUTES reports :REPARSE-POINT for every Windows reparse point, and LINK-P is true
;;;; for every one, so an app that refuses links had to refuse a OneDrive files-on-demand
;;;; placeholder too: a folder synced by OneDrive is a reparse point with a cloud tag, and to the
;;;; app it is an ordinary local folder. REPARSE-KIND reads the reparse tag and says whether the
;;;; path is a symbolic link, a junction, a cloud-sync placeholder or another kind.
;;;;
;;;; The tag is read from WIN32_FIND_DATAW.dwReserved0, which FindFirstFileW fills in when the
;;;; entry has FILE_ATTRIBUTE_REPARSE_POINT. FindFirstFileW reads the directory entry and does
;;;; not open the file, so asking about a placeholder does not make the sync client download it.
;;;;
;;;; DELETE-TREE and LINK-P are unchanged: they still treat every reparse point as a link, and
;;;; remove a link without following it.
;;;;
;;;; As in delete-tree.lisp, Windows is reached through SB-ALIEN, not CFFI.

(in-package #:aion/fs)

(define-condition reparse-kind-error (file-error)
  ((code :initarg :code :reader reparse-kind-error-code))
  (:report (lambda (c s)
             (format s "cannot read what kind of entry ~A is (error ~A)"
                     (let ((p (file-error-pathname c))) (if (stringp p) p (uiop:native-namestring p)))
                     (reparse-kind-error-code c))))
  (:documentation "Signalled by REPARSE-TAG and REPARSE-KIND when the operating system cannot
answer for PATH. CODE is the Windows error code, such as 2 (ERROR_FILE_NOT_FOUND) or 3
(ERROR_PATH_NOT_FOUND), or on Linux and macOS the errno from lstat, such as 2 (ENOENT)."))

(defun reparse-tag-kind (tag)
  "The kind of reparse point the Windows reparse tag TAG names:

- :SYMLINK for IO_REPARSE_TAG_SYMLINK (#xA000000C), a symbolic link;
- :JUNCTION for IO_REPARSE_TAG_MOUNT_POINT (#xA0000003), a junction or a volume mount point;
- :CLOUD for IO_REPARSE_TAG_CLOUD (#x9000001A) and IO_REPARSE_TAG_CLOUD_1 to _F (#x9000101A to
  #x9000F01A), the tags of a cloud files placeholder, such as a OneDrive files-on-demand file or
  folder;
- :OTHER for any other tag, such as IO_REPARSE_TAG_APPEXECLINK (#x8000001B) or a tag that a
  deduplication or storage driver sets;
- NIL when TAG is NIL.

This only classifies a number, so it gives the same answer on every operating system."
  (cond ((null tag) nil)
        ((= tag #xA000000C) :symlink)
        ((= tag #xA0000003) :junction)
        ;; The sixteen cloud tags differ only in bits 12 to 15.
        ((= (logand tag #xFFFF0FFF) #x9000001A) :cloud)
        (t :other)))

#+win32
(progn
  (defconstant +find-data-size+ 592
    "The size of WIN32_FIND_DATAW: dwFileAttributes, three FILETIMEs, nFileSizeHigh,
nFileSizeLow, dwReserved0, dwReserved1, cFileName[260] and cAlternateFileName[14] in UTF-16.")
  (defconstant +find-data-reserved0-offset+ 36
    "The byte offset of dwReserved0 in WIN32_FIND_DATAW: 4 for dwFileAttributes, 24 for the three
FILETIMEs, and 8 for the two halves of the file size.")

  (defun %find-reparse-tag (native)
    "dwReserved0 from FindFirstFileW for NATIVE, a native path without a trailing separator, or
the Windows error code as the second value when FindFirstFileW fails."
    (let ((data (sb-alien:make-alien (sb-alien:unsigned 8) +find-data-size+)))
      (unwind-protect
           (let ((handle (sb-alien:alien-funcall
                          (sb-alien:extern-alien "FindFirstFileW"
                                                 (function (sb-alien:unsigned 64)
                                                           (sb-alien:c-string :external-format :utf-16le)
                                                           sb-alien:system-area-pointer))
                          native (sb-alien:alien-sap data))))
             (if (= handle +invalid-handle-value+)
                 (values nil (%last-error))
                 (progn
                   (sb-alien:alien-funcall
                    (sb-alien:extern-alien "FindClose" (function sb-alien:int (sb-alien:unsigned 64)))
                    handle)
                   (sb-sys:sap-ref-32 (sb-alien:alien-sap data) +find-data-reserved0-offset+))))
        (sb-alien:free-alien data)))))

(defun reparse-tag (path)
  "The Windows reparse tag of PATH itself, as an integer, or NIL when PATH is not a reparse
point. A link is not followed: a junction gives IO_REPARSE_TAG_MOUNT_POINT, not anything about
its target. REPARSE-TAG-KIND says what a tag means.

PATH is a pathname, or a string, which is used as the native path without being parsed, so
names with [ ] and non-ASCII characters are passed through as they are.

Signals REPARSE-KIND-ERROR when Windows cannot answer, for example because PATH does not exist.
On Linux and macOS there are no reparse points, and this returns NIL for any path that exists."
  #+win32
  (let* ((native (%native path))
         (a (%attributes native)))
    (cond ((= a +invalid-file-attributes+)
           (error 'reparse-kind-error :pathname path :code (%last-error)))
          ((not (logtest a +file-attribute-reparse-point+)) nil)
          (t (multiple-value-bind (tag code) (%find-reparse-tag native)
               (or tag (error 'reparse-kind-error :pathname path :code code))))))
  #-win32
  (progn (%posix-kind path) nil))

#-win32
(defun %posix-kind (path)
  "PATH's lstat file type bits, or REPARSE-KIND-ERROR with the errno when lstat fails."
  (handler-case (logand (sb-posix:stat-mode (sb-posix:lstat (%native path))) #o170000)
    (sb-posix:syscall-error (e)
      (error 'reparse-kind-error :pathname path :code (sb-posix:syscall-errno e)))))

(defun reparse-kind (path)
  "What kind of link or reparse point PATH itself is, without following it:

- :SYMLINK for a symbolic link;
- :JUNCTION for a Windows junction or volume mount point;
- :CLOUD for a Windows cloud files placeholder, such as a file or folder that OneDrive keeps
  on demand;
- :OTHER for any other kind of Windows reparse point;
- NIL for an entry that is none of these: a plain file or directory.

An app that refuses links can refuse :SYMLINK and :JUNCTION and accept :CLOUD, so a folder that
OneDrive syncs is not refused. On Windows the kind comes from the reparse tag (REPARSE-TAG and
REPARSE-TAG-KIND). On Linux and macOS a symbolic link gives :SYMLINK and anything else NIL.

PATH is a pathname, or a string, which is used as the native path without being parsed.

Signals REPARSE-KIND-ERROR when the operating system cannot answer, for example because PATH
does not exist.

LINK-P and DELETE-TREE are not affected: they treat every reparse point, a cloud placeholder
included, as a link."
  #+win32 (reparse-tag-kind (reparse-tag path))
  #-win32 (and (= (%posix-kind path) #o120000) :symlink))
