;;;; delete-tree.lisp --- remove a directory tree without following a link out of it (#347).
;;;;
;;;; `uiop:delete-directory-tree' does not treat links specially, and measured on SBCL 2.6.8:
;;;;
;;;;   - Windows: a directory junction inside the tree is traversed, and the files in its target,
;;;;     outside the tree, are deleted. The same when the root is a junction. Neither TRUENAME nor
;;;;     SBCL's file kind shows a junction; only FILE_ATTRIBUTE_REPARSE_POINT does.
;;;;   - Linux and macOS: a symbolic link inside the tree is not followed, but a root that is a
;;;;     symbolic link to a directory is, and the target's files are deleted before the call fails.
;;;;     `uiop:subdirectories' lists such a link as a subdirectory.
;;;;
;;;; DELETE-TREE asks the operating system about each entry before touching it:
;;;;   - a link (a Windows reparse point of any kind, or a POSIX symbolic link) is removed as a
;;;;     link, with RemoveDirectoryW or DeleteFileW, or unlink, and nothing inside it is looked at;
;;;;   - a directory that is not a link is emptied the same way and then removed;
;;;;   - anything else is deleted as a file;
;;;;   - a ROOT that is a link is refused, because the caller asked to remove a tree and a link is
;;;;     not one.
;;;;
;;;; The calls are made through SB-ALIEN on Windows and SB-POSIX elsewhere, not through CFFI or
;;;; aion/windows: this system must load where only UIOP does (the build scripts load it before
;;;; Quicklisp) and cons depends on it, and cons does not carry CFFI.
;;;;
;;;; What this does not cover: another process changing the tree while it is being removed, such
;;;; as replacing a directory with a link between the check and the descent. A caller removing a
;;;; directory someone else can write into has to establish ownership first; hyperion/update's
;;;; staging sweep checks the owner before it calls this.

(in-package #:aion/fs)

(define-condition link-root-refused (file-error)
  ()
  (:report (lambda (c s)
             (format s "refusing to delete ~A: it is a link, not a directory tree, and deleting through it would remove what it points to"
                     (uiop:native-namestring (file-error-pathname c)))))
  (:documentation "Signalled by DELETE-TREE when the root it was given is a junction, reparse point
or symbolic link."))

(define-condition delete-tree-error (file-error)
  ((operation :initarg :operation :reader delete-tree-error-operation)
   (code :initarg :code :reader delete-tree-error-code))
  (:report (lambda (c s)
             (format s "delete-tree: ~A of ~A failed (error ~A)"
                     (delete-tree-error-operation c)
                     (uiop:native-namestring (file-error-pathname c))
                     (delete-tree-error-code c))))
  (:documentation "An entry DELETE-TREE could not remove. The tree is left partly removed."))

(defun %native (path)
  "PATH's native namestring without a trailing separator, which Windows and POSIX both need to
name a directory, or a link to one, as the entry itself."
  (string-right-trim "/\\" (uiop:native-namestring path)))

;;; --- asking the operating system -------------------------------------------------------

#+win32
(progn
  (defconstant +invalid-file-attributes+ #xFFFFFFFF)
  (defconstant +file-attribute-readonly+ #x1)
  (defconstant +file-attribute-directory+ #x10)
  (defconstant +file-attribute-reparse-point+ #x400)
  (defconstant +error-file-not-found+ 2)
  (defconstant +error-path-not-found+ 3)

  (defun %attributes (path)
    (sb-alien:alien-funcall
     (sb-alien:extern-alien "GetFileAttributesW"
                            (function (sb-alien:unsigned 32) (sb-alien:c-string :external-format :utf-16le)))
     (%native path)))

  (defun %last-error ()
    (sb-alien:alien-funcall (sb-alien:extern-alien "GetLastError" (function (sb-alien:unsigned 32)))))

  (defmacro %win-call (name path operation)
    "Call the Win32 function NAME, a literal string, on PATH; signal DELETE-TREE-ERROR when it
returns FALSE. A macro because EXTERN-ALIEN takes the function's name literally."
    (let ((p (gensym "PATH")))
      `(let ((,p ,path))
         (when (zerop (sb-alien:alien-funcall
                       (sb-alien:extern-alien ,name (function sb-alien:int (sb-alien:c-string :external-format :utf-16le)))
                       (%native ,p)))
           (error 'delete-tree-error :pathname ,p :operation ,operation :code (%last-error))))))

  (defun %clear-readonly (path attributes)
    ;; A read-only file cannot be deleted on Windows; git's object store is read-only, which is
    ;; the case that made uiop:delete-directory-tree raise under a git checkout.
    (when (logtest attributes +file-attribute-readonly+)
      (sb-alien:alien-funcall
       (sb-alien:extern-alien "SetFileAttributesW"
                              (function sb-alien:int (sb-alien:c-string :external-format :utf-16le)
                                        (sb-alien:unsigned 32)))
       (%native path)
       (logandc2 attributes +file-attribute-readonly+))))

  (defun %kind (path)
    "One of :MISSING, :LINK-DIRECTORY, :LINK-FILE, :DIRECTORY, :FILE for PATH, without following
a link."
    (let ((a (%attributes path)))
      (cond ((= a +invalid-file-attributes+)
             (let ((code (%last-error)))
               (if (member code (list +error-file-not-found+ +error-path-not-found+))
                   :missing
                   (error 'delete-tree-error :pathname path :operation :get-file-attributes :code code))))
            ((logtest a +file-attribute-reparse-point+)
             (if (logtest a +file-attribute-directory+) :link-directory :link-file))
            ((logtest a +file-attribute-directory+) :directory)
            (t :file))))

  (defun %remove-directory (path) (%win-call "RemoveDirectoryW" path :remove-directory))

  (defun %remove-file (path)
    (%clear-readonly path (%attributes path))
    (%win-call "DeleteFileW" path :delete-file)))

#-win32
(progn
  (defun %kind (path)
    (handler-case
        (let ((mode (logand (sb-posix:stat-mode (sb-posix:lstat (%native path))) #o170000)))
          (cond ((= mode #o120000) :link-file)
                ((= mode #o040000) :directory)
                (t :file)))
      (sb-posix:syscall-error (e)
        (if (= (sb-posix:syscall-errno e) sb-posix:enoent)
            :missing
            (error 'delete-tree-error :pathname path :operation :lstat
                                      :code (sb-posix:syscall-errno e))))))

  (defun %posix-call (fn path operation)
    (handler-case (funcall fn (%native path))
      (sb-posix:syscall-error (e)
        (error 'delete-tree-error :pathname path :operation operation
                                  :code (sb-posix:syscall-errno e)))))

  (defun %remove-directory (path) (%posix-call #'sb-posix:rmdir path :rmdir))
  (defun %remove-file (path) (%posix-call #'sb-posix:unlink path :unlink)))

(defun link-p (path)
  "True when PATH is a link: a Windows junction or other reparse point, or a POSIX symbolic link.
Unlike TRUENAME and SBCL's file kind, this sees a Windows junction."
  (and (member (%kind path) '(:link-directory :link-file)) t))

;;; --- removing a link ----------------------------------------------------------------------

(defun delete-link (path)
  "Remove the link PATH itself -- a junction, reparse point or symbolic link -- and nothing it
points to. Signals DELETE-TREE-ERROR when PATH is not a link, so it cannot be used to delete a
real directory or file by mistake."
  (ecase (%kind path)
    (:link-directory (%remove-directory path) t)
    (:link-file (%remove-file path) t)
    ((:missing :directory :file)
     (error 'delete-tree-error :pathname path :operation :delete-link :code :not-a-link))))

;;; --- the walk --------------------------------------------------------------------------

(defun %entries (directory)
  "Every entry in DIRECTORY, which is known not to be a link, as pathnames: files as file
pathnames and subdirectories (including links to directories) as directory pathnames. Listed
without resolving links, so a link appears under its own name."
  (append (uiop:directory-files directory)
          (uiop:subdirectories directory)))

(defun %delete-entry (path)
  (ecase (%kind path)
    (:missing nil)
    (:link-directory (%remove-directory path))     ; Windows: removes the junction, not its target
    (:link-file (%remove-file path))               ; a file link, or any POSIX symbolic link
    (:file (%remove-file path))
    (:directory
     (let ((dir (uiop:ensure-directory-pathname path)))
       (dolist (entry (%entries dir)) (%delete-entry entry))
       (%remove-directory dir)))))

(defun delete-tree (root &key (if-does-not-exist :error))
  "Delete the directory ROOT and everything in it, without following a link out of it.

A link inside the tree -- a Windows junction or other reparse point, or a symbolic link -- is
removed as a link, and nothing it points to is touched. A ROOT that is itself a link signals
LINK-ROOT-REFUSED and deletes nothing. ROOT must be an absolute directory pathname that is not a
filesystem root. IF-DOES-NOT-EXIST is :ERROR (the default) or :IGNORE.

An entry that cannot be removed signals DELETE-TREE-ERROR, and the tree is left partly removed.
Returns T when it removed the tree, NIL when ROOT did not exist and that was allowed."
  (let ((root (uiop:ensure-directory-pathname root)))
    (unless (and (uiop:absolute-pathname-p root)
                 (rest (pathname-directory root)))
      (error "delete-tree: ~A must be an absolute directory that is not a filesystem root" root))
    (ecase (%kind root)
      (:missing
       (ecase if-does-not-exist
         (:ignore nil)
         (:error (error 'delete-tree-error :pathname root :operation :delete-tree :code :missing))))
      ((:link-directory :link-file)
       (error 'link-root-refused :pathname root))
      (:file
       (error 'delete-tree-error :pathname root :operation :delete-tree :code :not-a-directory))
      (:directory
       (%delete-entry root)
       t))))
