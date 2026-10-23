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
;;;; Every failure signals LINK-ERROR, or LINK-NOT-PERMITTED when Windows refuses the privilege,
;;;; and each function checks with LINK-P that what it made is a link before it returns.
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
                     (uiop:native-namestring (file-error-pathname c))
                     (and (link-error-target c) (uiop:native-namestring (link-error-target c)))
                     (link-error-operation c) (link-error-code c))))
  (:documentation "MAKE-DIRECTORY-LINK or MAKE-FILE-LINK could not make the link (#825). PATHNAME is
the link, TARGET what it was to point to, OPERATION the step that failed, and CODE the operating
system's error code or a keyword such as :EXISTS, :TARGET-MISSING or :TARGET-NOT-A-DIRECTORY.
Nothing is left at the link's path."))

(define-condition link-not-permitted (link-error) ()
  (:documentation "Windows refused to make a symbolic link because the process lacks the
symbolic-link privilege and Developer Mode is off (ERROR_PRIVILEGE_NOT_HELD). A directory link
never signals this: MAKE-DIRECTORY-LINK makes a junction, which needs no privilege."))

(defun %link-error (link target operation code)
  (error (if (eql code 1314) 'link-not-permitted 'link-error)
         :pathname link :target target :operation operation :code code))

(defun %absolute (path)
  "PATH made absolute against the current directory, as a pathname."
  (let ((p (if (stringp path) (uiop:parse-native-namestring path) path)))
    (if (uiop:absolute-pathname-p p) p (merge-pathnames p (uiop:getcwd)))))

(defun %check-link-place (link target kind)
  "Signal LINK-ERROR unless LINK does not exist yet and TARGET exists and is of KIND, :DIRECTORY
or :FILE. Neither is followed if it is itself a link."
  (unless (eq :missing (%kind link))
    (%link-error link target :check :exists))
  (let ((have (%kind target)))
    (case have
      (:missing (%link-error link target :check :target-missing))
      ((:link-directory :link-file) nil)        ; a link to a link is allowed, as with mklink
      (t (unless (eq have kind)
           (%link-error link target :check (if (eq kind :directory)
                                               :target-not-a-directory
                                               :target-not-a-file)))))))

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
    "The REPARSE_DATA_BUFFER that makes a directory a junction to TARGET, an absolute native path
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
    "Make the junction LINK to the directory TARGET, both native paths. On any failure the
directory made for it is removed again and LINK-ERROR is signalled."
    (when (zerop (%create-directory link))
      (%link-error link target :create-directory (%last-error)))
    (let ((handle (%open-reparse-point link))
          (code nil)
          (operation nil))
      (if (= handle +invalid-handle-value+)
          (setf code (%last-error) operation :create-file)
          (unwind-protect
               (unless (%set-reparse-point handle (%mount-point-buffer target))
                 (setf code (%last-error) operation :set-reparse-point))
            (%close-handle handle)))
      (when code
        (sb-alien:alien-funcall
         (sb-alien:extern-alien "RemoveDirectoryW"
                                (function sb-alien:int (sb-alien:c-string :external-format :utf-16le)))
         link)
        (%link-error link target operation code))))

  (defun %make-symlink (link target)
    "Make the file symbolic link LINK to TARGET, both native paths, asking Windows to allow it
without the privilege when Developer Mode is on."
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
  "Signal LINK-ERROR unless LINK is now a link: the last check that nothing failed quietly."
  (unless (link-p link)
    (%link-error link target :verify :not-a-link)))

(defun make-directory-link (link target)
  "Make LINK, which must not exist yet, a link to the directory TARGET, and return LINK.

On Windows the link is a junction, which needs no administrator rights and no Developer Mode;
on macOS and Linux it is a symbolic link. LINK-P is true of the result, and DELETE-LINK removes
it without touching TARGET. Both paths are made absolute against the current directory, and
TARGET must exist and be a directory or a link to one.

Signals LINK-ERROR, with nothing left at LINK, when LINK already exists, when TARGET is missing or
not a directory, or when the operating system refuses."
  (let* ((link (%absolute link))
         (target (%absolute target))
         (l (%native link))
         (tg (%native target)))
    (%check-link-place l tg :directory)
    #+win32 (%make-junction l tg)
    #-win32 (%make-symlink l tg)
    (%made l tg)
    link))

(defun make-file-link (link target)
  "Make LINK, which must not exist yet, a symbolic link to the file TARGET, and return LINK.

On Windows a symbolic link needs Developer Mode or the symbolic-link privilege; without either it
signals LINK-NOT-PERMITTED, a LINK-ERROR. Otherwise it signals LINK-ERROR, with nothing left at
LINK, as MAKE-DIRECTORY-LINK does."
  (let* ((link (%absolute link))
         (target (%absolute target))
         (l (%native link))
         (tg (%native target)))
    (%check-link-place l tg :file)
    (%make-symlink l tg)
    (%made l tg)
    link))
