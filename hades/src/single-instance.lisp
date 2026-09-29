;;;; single-instance.lisp --- one running copy of an app per user and data directory (#305)
;;;;
;;;; Two copies of a desktop app writing the same data directory overwrite each other's writes;
;;;; a consuming app measured lost updates this way. This is the portable facade hades
;;;; ADR-0001 chartered: a lock the operating system holds for the process, so it is released
;;;; when the process ends, however it ends.
;;;;
;;;; The charter's rule is "flock, never a lock file", and the file below is not a lock file in
;;;; the sense it forbids. A lock file is one whose EXISTENCE means "locked": a crash leaves it
;;;; behind, and the app locks itself out of its next start. Here the file is only something to
;;;; hold a lock on. It is created if missing and never deleted, and whether it exists says
;;;; nothing:
;;;;
;;;;   - Windows: CreateFileW with share mode 0. While the handle is open, no other open of the
;;;;     file succeeds (ERROR_SHARING_VIOLATION). Windows closes the handle when the process
;;;;     ends. The handle is not inheritable, so a child process does not hold it.
;;;;   - Linux and macOS: an fcntl write lock over the whole file, through sb-posix. The kernel
;;;;     releases it when the process ends.
;;;;
;;;; Two differences between those, and what this file does about each:
;;;;
;;;;   - An fcntl lock belongs to the process, so a second attempt from the same process
;;;;     succeeds, where a second CreateFileW fails. A table of the locks this process holds
;;;;     makes a second acquire in the same process report :BUSY on every system.
;;;;   - An fcntl lock is released when the process closes ANY descriptor for the file. So the
;;;;     app must not open the lock file for anything else; it is named <name>.lock and holds
;;;;     nothing.
;;;;
;;;; The lock is scoped to a directory, which is the app's data directory by default
;;;; (UIOP:XDG-DATA-HOME of the name, per user), so two users, or one user with two data
;;;; directories, each get their own.
;;;;
;;;; Handing the second launch's arguments to the first copy, or focusing its window, is not
;;;; here yet (#305 lists it as later work).

(in-package #:hades/single-instance)

(defstruct (single-instance-lock (:constructor %make-lock (path os-object)))
  "A held single-instance lock. PATH is the file the lock is held on."
  (path nil :read-only t)
  (os-object nil)
  (released nil))

(define-condition single-instance-busy (error)
  ((name :initarg :name :reader single-instance-busy-name)
   (path :initarg :path :reader single-instance-busy-path))
  (:report (lambda (c s)
             (format s "another copy of ~A is running: it holds ~A"
                     (single-instance-busy-name c)
                     (uiop:native-namestring (single-instance-busy-path c)))))
  (:documentation "Signalled by WITH-SINGLE-INSTANCE when another process, or this one, holds
the lock and no ON-BUSY function was given."))

;;; --- the locks this process holds --------------------------------------------------

(defvar *held* (make-hash-table :test #'equal)
  "Key (see %KEY) -> the SINGLE-INSTANCE-LOCK this process holds on that file.")

(defvar *held-lock* (sb-thread:make-mutex :name "hades/single-instance held locks"))

(defun %key (path)
  "PATH as a table key. Windows compares file names without regard to case."
  (let ((s (uiop:native-namestring path)))
    (if (uiop:os-windows-p) (string-downcase s) s)))

;;; --- the operating system's lock -----------------------------------------------------

#+win32
(defun %os-acquire (path)
  "An exclusive handle on PATH, or :BUSY when another handle has it open."
  (aion/windows:with-wide-string (p (uiop:native-namestring path))
    (let* ((raw (aion/windows/ffi:create-file-w
                 p (logior aion/windows/ffi:+generic-read+ aion/windows/ffi:+generic-write+)
                 0 (cffi:null-pointer) aion/windows/ffi:+open-always+
                 aion/windows/ffi:+file-attribute-normal+ (cffi:null-pointer)))
           (code (aion/windows:last-error))
           (handle (aion/windows:wrap-handle raw :kind :single-instance)))
      (cond ((aion/windows:handle-valid-p handle) handle)
            ((= code aion/windows/ffi:+error-sharing-violation+) :busy)
            (t (error 'aion/windows:win32-error
                      :code code
                      :message (aion/windows:error-message-for code)
                      :operation :create-file))))))

#+win32
(defun %os-release (handle)
  (aion/windows:close-handle handle))

#-win32
(defun %os-acquire (path)
  "A descriptor on PATH holding an fcntl write lock, or :BUSY when another process holds one."
  (let ((fd (sb-posix:open (uiop:native-namestring path)
                           (logior sb-posix:o-rdwr sb-posix:o-creat)
                           #o600)))
    (handler-case
        (let ((lock (make-instance 'sb-posix:flock
                                   :type sb-posix:f-wrlck :whence sb-posix:seek-set
                                   :start 0 :len 0)))
          (sb-posix:fcntl fd sb-posix:f-setlk lock)
          fd)
      (sb-posix:syscall-error (e)
        (sb-posix:close fd)
        (if (member (sb-posix:syscall-errno e) (list sb-posix:eagain sb-posix:eacces))
            :busy
            (error e))))))

#-win32
(defun %os-release (fd)
  (sb-posix:close fd))

;;; --- the facade ------------------------------------------------------------------------

(defun %check-name (name)
  (unless (and (stringp name) (plusp (length name))
               (notany (lambda (c) (find c "/\\:*?\"<>|")) name))
    (error "hades/single-instance: ~S is not a usable name; give a plain file name such as the app's name"
           name)))

(defun lock-path (name &key directory)
  "The file the lock for NAME is held on: <directory>/<name>.lock. DIRECTORY defaults to the
app's per-user data directory, UIOP:XDG-DATA-HOME of NAME."
  (%check-name name)
  (merge-pathnames (make-pathname :name name :type "lock")
                   (uiop:ensure-directory-pathname
                    (or directory (uiop:xdg-data-home (concatenate 'string name "/"))))))

(defun acquire-single-instance (name &key directory)
  "Take the single-instance lock for NAME, scoped to DIRECTORY (see LOCK-PATH).

Returns a SINGLE-INSTANCE-LOCK, or :BUSY when another process holds it, or this process
already does. The operating system releases the lock when the process ends, however it
ends; RELEASE-SINGLE-INSTANCE releases it earlier."
  (let ((path (lock-path name :directory directory)))
    (ensure-directories-exist path)
    (sb-thread:with-mutex (*held-lock*)
      (if (gethash (%key path) *held*)
          :busy
          (let ((os (%os-acquire path)))
            (if (eq os :busy)
                :busy
                (setf (gethash (%key path) *held*) (%make-lock path os))))))))

(defun release-single-instance (lock)
  "Release LOCK. Releasing it again does nothing. The file stays: it holds nothing, and
deleting it would let a second process lock a new file while the first still holds the old."
  (sb-thread:with-mutex (*held-lock*)
    (unless (single-instance-lock-released lock)
      (setf (single-instance-lock-released lock) t)
      (remhash (%key (single-instance-lock-path lock)) *held*)
      (%os-release (single-instance-lock-os-object lock))))
  nil)

(defmacro with-single-instance ((name &key directory on-busy) &body body)
  "Run BODY holding the single-instance lock for NAME, and release it when BODY exits.

When another copy holds it, BODY does not run: ON-BUSY, a function of no arguments, is called
and its values returned, or, with no ON-BUSY, SINGLE-INSTANCE-BUSY is signalled."
  (let ((lock (gensym "LOCK")) (n (gensym "NAME")) (d (gensym "DIRECTORY")))
    `(let* ((,n ,name) (,d ,directory)
            (,lock (acquire-single-instance ,n :directory ,d)))
       (if (eq ,lock :busy)
           ,(if on-busy
                `(funcall ,on-busy)
                `(error 'single-instance-busy :name ,n :path (lock-path ,n :directory ,d)))
           (unwind-protect (progn ,@body)
             (release-single-instance ,lock))))))
