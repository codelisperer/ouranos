;;;; program.lisp --- find a program on PATH, for the hades facades that run one (#819, #820).

(defpackage #:hades/program
  (:use #:cl)
  (:documentation "Finding a program on PATH for hades/notify and hades/open, which run
zenity, kdialog, dbus-send and xdg-open on Linux.")
  (:export #:find-program))

(in-package #:hades/program)

#-win32
(defun find-program (name &optional (path (uiop:getenv "PATH")))
  "The first regular, executable file called NAME in the directories of PATH, as a native
namestring, or NIL. Only absolute directories are searched: an empty entry, \".\" or \"bin\"
would name a directory relative to the current one, where a file called NAME could be anyone's."
  (loop for dir in (uiop:split-string (or path "") :separator ":")
        for file = (concatenate 'string dir "/" name)
        when (and (plusp (length dir))
                  (char= #\/ (char dir 0))
                  (handler-case
                      (and (sb-posix:s-isreg (sb-posix:stat-mode (sb-posix:stat file)))
                           (progn (sb-posix:access file sb-posix:x-ok) t))
                    (sb-posix:syscall-error () nil)))
          return file))

#+win32
(defun find-program (name &optional path)
  "NIL on Windows, where the hades facades run programs from the system directory by their full
path and never search PATH."
  (declare (ignore name path))
  nil)
