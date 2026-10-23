;;;; links.lisp --- make a directory link or a file link (#825).
;;;;
;;;; aion/fs could find a link (LINK-P) and remove one without following it (DELETE-LINK), but
;;;; not make one, so every test of link-safe code shelled out to `mklink /J' or `ln -s', and a
;;;; shell-out that failed quietly made such a test pass without testing anything.
;;;;
;;;; MAKE-DIRECTORY-LINK makes a junction on Windows and a symbolic link elsewhere. A junction
;;;; needs no privilege and no Developer Mode, where a Windows symbolic link needs one or the
;;;; other. It is made the way `mklink /J' makes it: create an empty directory, open it as a
;;;; reparse point, and set a mount-point reparse buffer naming the target. MAKE-FILE-LINK makes
;;;; a symbolic link; on Windows that needs Developer Mode or the symbolic-link privilege.
;;;;
;;;; PATHS. On Windows both paths go through GetFullPathNameW, which resolves . and .. and makes a
;;;; relative path absolute against the current directory, before anything is made: a junction's
;;;; target is an NT path, and NT does not resolve .. in it, so \??\C:\cur\..\sib would be a
;;;; junction to nothing. A target already in \\?\ form has that prefix taken off, and a UNC
;;;; target (\\server\share) is refused, because a junction can only point at a local volume.
;;;;
;;;; FAILURE. Every failure signals LINK-ERROR, or LINK-NOT-PERMITTED when Windows refuses the
;;;; privilege, and leaves nothing at the link's path: a directory made for a junction that then
;;;; fails is removed, and each function checks with LINK-P that what it made is a link, removing
;;;; it before signalling when it is not.
;;;;
;;;; As in delete-tree.lisp, Windows is reached through SB-ALIEN, not CFFI: this system must load
;;;; where only UIOP does.

(in-package #:aion/fs)

(define-condition link-error (file-error)
  ((target :initarg :target :initform nil :reader link-error-target)
   (operation :initarg :operation :reader link-error-operation)
   (code :initarg :code :reader link-error-code))
  (:report (lambda (c s)
             (format s "could not make the link ~A to ~A: ~A failed (~A)"
                     (let ((p (file-error-pathname c))) (if (stringp p) p (uiop:native-namestring p)))
                     (let ((p (link-error-target c))) (if (stringp p) p (and p (uiop:native-namestring p))))
                     (link-error-operation c) (link-error-code c))))
  (:documentation "MAKE-DIRECTORY-LINK or MAKE-FILE-LINK could not make the link (#825). PATHNAME is
the link, TARGET what it was to point to, OPERATION the step that failed, and CODE the operating
system's error code or one of :EXISTS, :TARGET-MISSING, :TARGET-NOT-A-DIRECTORY,
:TARGET-NOT-A-FILE, :TARGET-UNC and :NOT-A-LINK. Nothing is left at the link's path."))

(define-condition link-not-permitted (link-error) ()
  (:documentation "Windows refused to make a symbolic link because the process lacks the
symbolic-link privilege and Developer Mode is off (ERROR_PRIVILEGE_NOT_HELD). A directory link
never signals this: MAKE-DIRECTORY-LINK makes a junction, which needs no privilege."))

(defparameter +exists-codes+ '(80 183 17)
  "The errors that mean the link's path was taken between the check and the make: Windows'
ERROR_FILE_EXISTS (80) and ERROR_ALREADY_EXISTS (183), and POSIX EEXIST (17). Reported as
:EXISTS, the same as when the check finds the path taken.")

(defun %link-error (link target operation code)
  (error (if (eql code 1314) 'link-not-permitted 'link-error)
         :pathname link :target target :operation operation
         :code (if (member code +exists-codes+) :exists code)))

(defun %checked-kind (path link target)
  "%KIND of PATH, with an operating-system error turned into LINK-ERROR (operation :CHECK) rather
than the DELETE-TREE-ERROR %KIND signals, such as a parent that is a file or cannot be read."
  (handler-case (%kind path)
    (delete-tree-error (e)
      (%link-error link target :check (delete-tree-error-code e)))))

;;; --- paths -----------------------------------------------------------------------------

#+win32
(progn
  (defun %full-path (path)
    "PATH, a native string, as GetFullPathNameW makes it: absolute, with . and .. resolved, and
without a trailing separator. NIL when Windows cannot make it into a full path."
    (let ((size 1024))
      (loop
        (let ((buffer (sb-alien:make-alien (sb-alien:unsigned 16) size)))
          (unwind-protect
               (let ((n (sb-alien:alien-funcall
                         (sb-alien:extern-alien "GetFullPathNameW"
                                                (function (sb-alien:unsigned 32)
                                                          (sb-alien:c-string :external-format :utf-16le)
                                                          (sb-alien:unsigned 32)
                                                          sb-alien:system-area-pointer
                                                          (sb-alien:unsigned 64)))
                         path size (sb-alien:alien-sap buffer) 0)))
                 (cond ((zerop n) (return nil))
                       ((< n size)
                        (return (%native (map 'string (lambda (i) (code-char (sb-alien:deref buffer i)))
                                              (loop for i below n collect i)))))
                       (t (setf size (1+ n)))))
            (sb-alien:free-alien buffer))))))

  (defun %resolve (path link target)
    "PATH, a native string, as a full local path: a leading \\\\?\\ is taken off, a UNC path is
refused with LINK-ERROR :TARGET-UNC, and the rest goes through %FULL-PATH."
    (let* ((p (if (and (>= (length path) 4) (string= "\\\\?\\" path :end2 4)) (subseq path 4) path)))
      (when (or (and (>= (length p) 4) (string-equal "UNC\\" p :end2 4))
                (and (>= (length p) 2) (string= "\\\\" p :end2 2)))
        (%link-error link target :check :target-unc))
      (or (%full-path p) (%link-error link target :get-full-path-name (%last-error))))))

#-win32
(defun %resolve (path link target)
  "PATH, a native string, made absolute against the current directory. The kernel resolves .. in a
symbolic link's target when it is followed, so it is not resolved here."
  (declare (ignore link target))
  (if (uiop:absolute-pathname-p (uiop:parse-native-namestring path))
      path
      (concatenate 'string (%native (uiop:getcwd)) "/" path)))

(defun %native-input (path)
  "PATH, a pathname or a native string, as a native string without a trailing separator."
  (%native path))

;;; --- what the target resolves to --------------------------------------------------------

#+win32
(defun %resolved-kind (path link target)
  "What PATH is once a link is followed, as :DIRECTORY, :FILE or :MISSING. On Windows a
directory junction or symbolic link reports the directory attribute, and a file symbolic link
does not, so the link's own attributes say which it resolves to."
  (ecase (%checked-kind path link target)
    (:missing :missing)
    ((:directory :link-directory) :directory)
    ((:file :link-file) :file)))

#-win32
(defun %resolved-kind (path link target)
  "What PATH is once links are followed, as :DIRECTORY, :FILE or :MISSING, by stat."
  (handler-case
      (let ((mode (logand (sb-posix:stat-mode (sb-posix:stat path)) #o170000)))
        (if (= mode #o040000) :directory :file))
    (sb-posix:syscall-error (e)
      (if (= (sb-posix:syscall-errno e) sb-posix:enoent)
          :missing
          (%link-error link target :check (sb-posix:syscall-errno e))))))

(defun %check-link-place (link target kind)
  "Signal LINK-ERROR unless LINK does not exist yet and TARGET exists and, once any link is
followed, is of KIND, :DIRECTORY or :FILE."
  (unless (eq :missing (%checked-kind link link target))
    (%link-error link target :check :exists))
  (let ((have (%resolved-kind target link target)))
    (cond ((eq have :missing) (%link-error link target :check :target-missing))
          ((not (eq have kind))
           (%link-error link target :check (if (eq kind :directory)
                                               :target-not-a-directory
                                               :target-not-a-file))))))

;;; --- Windows: a junction, or a symbolic link ----------------------------------------------

#+win32
(progn
  (defconstant +generic-write+ #x40000000)
  (defconstant +open-existing+ 3)
  (defconstant +file-flag-open-reparse-point+ #x00200000)
  (defconstant +file-flag-backup-semantics+ #x02000000)
  (defconstant +fsctl-set-reparse-point+ #x000900A4)
  (defconstant +io-reparse-tag-mount-point+ #xA0000003)
  (defconstant +invalid-handle-value+ #xFFFFFFFFFFFFFFFF)
  (defconstant +symbolic-link-flag-allow-unprivileged-create+ #x2)

  (defun %utf-16 (string)
    (sb-ext:string-to-octets string :external-format :utf-16le))

  (defun %mount-point-buffer (target)
    "The REPARSE_DATA_BUFFER that makes a directory a junction to TARGET, a full local path
without a trailing separator, as an octet vector. The substitute name is TARGET in NT form,
\\??\\TARGET, and the print name is TARGET; each is followed by a NUL in the path buffer, and
the lengths exclude it."
    (let* ((target (if (and (= 2 (length target)) (char= #\: (char target 1)))
                       (concatenate 'string target "\\") ; a drive root keeps its separator
                       target))
           (substitute (%utf-16 (concatenate 'string "\\??\\" target)))
           (print (%utf-16 target))
           (path-bytes (+ (length substitute) 2 (length print) 2))
           (data-length (+ 8 path-bytes))
           (buffer (make-array (+ 8 data-length) :element-type '(unsigned-byte 8)
                                                 :initial-element 0)))
      (flet ((u16 (at v) (setf (aref buffer at) (ldb (byte 8 0) v)
                               (aref buffer (1+ at)) (ldb (byte 8 8) v)))
             (u32 (at v) (loop for i below 4 do (setf (aref buffer (+ at i)) (ldb (byte 8 (* 8 i)) v)))))
        (u32 0 +io-reparse-tag-mount-point+)
        (u16 4 data-length)                       ; ReparseDataLength; Reserved stays 0
        (u16 8 0)                                 ; SubstituteNameOffset
        (u16 10 (length substitute))              ; SubstituteNameLength, in bytes
        (u16 12 (+ (length substitute) 2))        ; PrintNameOffset
        (u16 14 (length print))                   ; PrintNameLength
        (replace buffer substitute :start1 16)
        (replace buffer print :start1 (+ 16 (length substitute) 2)))
      buffer))

  (defun %create-directory (path)
    (sb-alien:alien-funcall
     (sb-alien:extern-alien "CreateDirectoryW"
                            (function sb-alien:int (sb-alien:c-string :external-format :utf-16le)
                                      (sb-alien:unsigned 64)))
     path 0))

  (defun %remove-empty-directory (path)
    "Remove the empty directory PATH. True when it was removed."
    (not (zerop (sb-alien:alien-funcall
                 (sb-alien:extern-alien "RemoveDirectoryW"
                                        (function sb-alien:int (sb-alien:c-string :external-format :utf-16le)))
                 path))))

  (defun %open-reparse-point (path)
    (sb-alien:alien-funcall
     (sb-alien:extern-alien "CreateFileW"
                            (function (sb-alien:unsigned 64)
                                      (sb-alien:c-string :external-format :utf-16le)
                                      (sb-alien:unsigned 32) (sb-alien:unsigned 32)
                                      (sb-alien:unsigned 64) (sb-alien:unsigned 32)
                                      (sb-alien:unsigned 32) (sb-alien:unsigned 64)))
     path +generic-write+ 0 0 +open-existing+
     (logior +file-flag-open-reparse-point+ +file-flag-backup-semantics+) 0))

  (defun %close-handle (handle)
    (sb-alien:alien-funcall
     (sb-alien:extern-alien "CloseHandle" (function sb-alien:int (sb-alien:unsigned 64)))
     handle))

  (defun %set-reparse-point (handle octets)
    "Set OCTETS, a REPARSE_DATA_BUFFER, on HANDLE. True when it succeeded."
    (let ((in (sb-alien:make-alien (sb-alien:unsigned 8) (length octets)))
          (returned (sb-alien:make-alien (sb-alien:unsigned 32))))
      (unwind-protect
           (progn
             (loop for i below (length octets)
                   do (setf (sb-alien:deref in i) (aref octets i)))
             (not (zerop (sb-alien:alien-funcall
                          (sb-alien:extern-alien
                           "DeviceIoControl"
                           (function sb-alien:int (sb-alien:unsigned 64) (sb-alien:unsigned 32)
                                     sb-alien:system-area-pointer (sb-alien:unsigned 32)
                                     (sb-alien:unsigned 64) (sb-alien:unsigned 32)
                                     sb-alien:system-area-pointer (sb-alien:unsigned 64)))
                          handle +fsctl-set-reparse-point+ (sb-alien:alien-sap in) (length octets)
                          0 0 (sb-alien:alien-sap returned) 0))))
        (sb-alien:free-alien in)
        (sb-alien:free-alien returned))))

  (defun %make-junction (link target)
    "Make the junction LINK to the directory TARGET, both full local paths. The reparse buffer
is built first, so nothing is made when it cannot be. On any later failure the directory made
for the junction is removed, and LINK-ERROR names the step that failed; when the directory
cannot be removed either, the operation is :REMOVE-DIRECTORY, so the caller knows one is left."
    (let ((buffer (%mount-point-buffer target)))
      (when (zerop (%create-directory link))
        (%link-error link target :create-directory (%last-error)))
      (let ((handle (%open-reparse-point link))
            (code nil)
            (operation nil))
        (if (= handle +invalid-handle-value+)
            (setf code (%last-error) operation :create-file)
            (unwind-protect
                 (unless (%set-reparse-point handle buffer)
                   (setf code (%last-error) operation :set-reparse-point))
              (%close-handle handle)))
        (when code
          (unless (%remove-empty-directory link)
            (%link-error link target :remove-directory (%last-error)))
          (%link-error link target operation code)))))

  (defun %make-symlink (link target)
    "Make the file symbolic link LINK to TARGET, both full local paths, asking Windows to allow
it without the privilege when Developer Mode is on."
    (when (zerop (sb-alien:alien-funcall
                  (sb-alien:extern-alien "CreateSymbolicLinkW"
                                         (function (sb-alien:unsigned 8)
                                                   (sb-alien:c-string :external-format :utf-16le)
                                                   (sb-alien:c-string :external-format :utf-16le)
                                                   (sb-alien:unsigned 32)))
                  link target +symbolic-link-flag-allow-unprivileged-create+))
      (%link-error link target :create-symbolic-link (%last-error)))))

#-win32
(defun %make-symlink (link target)
  (handler-case (sb-posix:symlink target link)
    (sb-posix:syscall-error (e)
      (%link-error link target :symlink (sb-posix:syscall-errno e)))))

(defun %made (link target)
  "Signal LINK-ERROR unless LINK is now a link: the last check that nothing failed quietly. What
was made is removed first, so nothing is left at LINK."
  (unless (handler-case (link-p link) (delete-tree-error () nil))
    (ignore-errors
     (case (%kind link)
       (:directory #+win32 (%remove-empty-directory link) #-win32 (sb-posix:rmdir link))
       (:file (%remove-file link))))
    (%link-error link target :verify :not-a-link)))

(defun %make-link (link target kind maker)
  (let* ((l (%native-input link))
         (tg (%native-input target))
         (l (%resolve l l tg))
         (tg (%resolve tg l tg)))
    (%check-link-place l tg kind)
    (funcall maker l tg)
    (%made l tg)
    (if (eq kind :directory)
        (uiop:ensure-directory-pathname (uiop:parse-native-namestring l))
        (uiop:parse-native-namestring l))))

(defun make-directory-link (link target)
  "Make LINK, which must not exist yet, a link to the directory TARGET, and return LINK as an
absolute directory pathname.

On Windows the link is a junction, which needs no administrator rights and no Developer Mode;
on macOS and Linux it is a symbolic link. LINK-P is true of the result, and DELETE-LINK removes
it without touching TARGET. A relative path is taken against the current directory, and . and ..
are resolved on Windows, where a junction's target must be a full local path; a UNC target is
refused. TARGET must exist and be a directory once any link is followed.

Signals LINK-ERROR, with nothing left at LINK, when LINK already exists, when TARGET is missing or
not a directory, or when the operating system refuses."
  (%make-link link target :directory #+win32 #'%make-junction #-win32 #'%make-symlink))

(defun make-file-link (link target)
  "Make LINK, which must not exist yet, a symbolic link to the file TARGET, and return LINK as an
absolute pathname. TARGET must exist and be a file once any link is followed; paths are taken as
for MAKE-DIRECTORY-LINK.

On Windows a symbolic link needs Developer Mode or the symbolic-link privilege; without either it
signals LINK-NOT-PERMITTED, a LINK-ERROR. Otherwise it signals LINK-ERROR, with nothing left at
LINK, as MAKE-DIRECTORY-LINK does."
  (%make-link link target :file #'%make-symlink))
