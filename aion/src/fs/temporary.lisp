;;;; temporary.lisp --- a new temporary directory no other process can be given (#515).
;;;;
;;;; THE PATTERN THIS REPLACES. Several test fixtures made a temporary directory by asking
;;;; UIOP:TMPIZE-PATHNAME for a unique FILE, deleting it, and creating a directory of the same
;;;; name. Between the delete and the create the name is free, and two fresh SBCL images draw
;;;; the same random suffixes in the same order, so a second suite starting at the same moment
;;;; on the same machine could take the name in that gap: "Can't create directory ... a file
;;;; with the same name already exists" (#515). Others named the directory by the time and a
;;;; counter, which two processes started in the same second share, and then both use one
;;;; directory without any error.
;;;;
;;;; HERE THE NAME CARRIES THE PROCESS ID and a counter of this process's own, so no other live
;;;; process can be given it, and the directory counts as made only when this call created it.
;;;; A directory of that name left by a dead process whose id was reused is passed over for the
;;;; next number.

(in-package #:aion/fs)

(defvar *temporary-count* 0
  "How many temporary directory names this process has tried; the last part of each name.")

(defvar *temporary-lock* (sb-thread:make-mutex :name "aion/fs temporary directories"))

(defun %process-id ()
  #+win32 (sb-alien:alien-funcall
           (sb-alien:extern-alien "GetCurrentProcessId" (function sb-alien:unsigned-long)))
  #-win32 (sb-unix:unix-getpid))

(defun make-temporary-directory (prefix &key (in (uiop:temporary-directory)))
  "Create a new, empty directory under IN (by default the system's temporary directory) and
return its pathname. It is named PREFIX-PID-N, where PID is this process's id and N a counter
of this process's own, so no other process running now and no other call in this process is
given the same directory. A name that already exists is passed over for the next N. The caller
deletes the directory when it is done, for instance with DELETE-TREE."
  (check-type prefix string)
  (loop
    (let* ((n (sb-thread:with-mutex (*temporary-lock*) (incf *temporary-count*)))
           (dir (uiop:ensure-directory-pathname
                 (merge-pathnames (format nil "~A-~D-~D" prefix (%process-id) n)
                                  (uiop:ensure-directory-pathname in)))))
      (multiple-value-bind (path created) (ensure-directories-exist dir)
        (when created (return path))))))
