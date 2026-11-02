;;;; path.lisp --- the name the operating system takes for a path, given as a string or a pathname (#1103).
;;;;
;;;; A string is the operating system's name for a file already, and is used as written. Parsing
;;;; it as a Lisp namestring, which CL:PATHNAME, CL:NAMESTRING and MERGE-PATHNAMES all do, reads
;;;; [ ] * ? as wildcard syntax, and on Linux and macOS reads a backslash as an escape and drops
;;;; it, so a file named a[1].txt or a\b.txt could not be used (#1093, #1096). A pathname is given
;;;; its native name with UIOP:NATIVE-NAMESTRING, after a logical pathname is translated.
;;;;
;;;; aion/fs, aion/uv, aion/libgit and aion/windows each carried a copy of this rule; they call
;;;; this module now. It needs nothing but UIOP, because aion/fs uses it, and the build scripts
;;;; load aion/fs by path before Quicklisp is set up (scripts/fs.lisp).

(defpackage #:aion/path
  (:use #:cl)
  (:documentation "The operating system's name for a path given as a native string or as a
pathname, and a directory pathname built from it without parsing the name as a Lisp
namestring (#1103).")
  (:export #:native-name #:directory-pathname #:separator-p #:separators #:native-separator))

(in-package #:aion/path)

(defun native-name (path)
  "PATH as the operating system takes it. A string is returned unchanged: it is already the
operating system's name for the file. A pathname is converted with UIOP:NATIVE-NAMESTRING, after a
logical pathname is translated to a physical one. A wild pathname, one with * or ? in it as a
pattern, names no single file, so it is refused with an error. Anything else, NIL included, is a
TYPE-ERROR."
  (etypecase path
    (string path)
    (pathname
     (let ((physical (translate-logical-pathname path)))
       (when (wild-pathname-p physical)
         (error "aion/path: ~S is a wild pathname, which names no single file." path))
       (uiop:native-namestring physical)))))

(defun separators ()
  "The characters that separate the parts of a native path: / and a backslash on Windows, / alone
on Linux and macOS, where a backslash is an ordinary character in a name."
  #+win32 "/\\"
  #-win32 "/")

(defun native-separator ()
  "The separator written between the parts of a native path: a backslash on Windows, / on Linux
and macOS."
  #+win32 "\\"
  #-win32 "/")

(defun separator-p (char)
  "Whether CHAR separates the parts of a native path; see SEPARATORS."
  (and (find char (separators)) t))

(defun directory-pathname (path)
  "PATH, a native string or a pathname naming a directory, as a directory pathname. It is made by
parsing PATH's native name, with its trailing separators replaced by one, as a native name. It is
not made with UIOP:ENSURE-DIRECTORY-PATHNAME: that takes the last name from FILE-NAMESTRING,
which escapes [ ] * ?, and on Linux and macOS a backslash too, so a folder named a[1] became one
named a\\[1] (#1096).

Two names are not given a separator, because one would make them a filesystem root (the hub's
review of #1123):
- An empty name, the string \"\" or the pathname #P\"\", is the current folder. The result is a
  pathname with no parts, which merges with *DEFAULT-PATHNAME-DEFAULTS*.
- On Windows, a drive with nothing after it, such as C:, is that drive's current folder, not its
  root C:\\. The result is a pathname with that device and no other parts.
A name made only of separators, such as /, is the root."
  (let ((native (native-name path)))
    (cond ((string= native "") (make-pathname))
          #+win32
          ((and (= (length native) 2) (char= #\: (char native 1)))
           (uiop:parse-native-namestring native))
          (t (uiop:parse-native-namestring
              (concatenate 'string (string-right-trim (separators) native) (native-separator)))))))
