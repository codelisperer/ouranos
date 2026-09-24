;;;; human-path.lisp --- how a script prints a path for a person to read (#168)
;;;;
;;;; Loaded by every script in this directory that prints a path in a message. The rule:
;;;;
;;;;   - An ABSOLUTE path is printed in the operating system's own spelling
;;;;     (`uiop:native-namestring'): `C:\Users\...' on Windows, `/home/...' elsewhere. That
;;;;     is the form a person pastes into a shell or a file manager.
;;;;   - A RELATIVE path, whether relative to the tree root or as someone typed it, is
;;;;     printed with forward slashes, the way git prints one
;;;;     (`hyperion/src/update/client.lisp'), on every operating system.
;;;;   - A path passed to another program is not printed for a person, and this file has
;;;;     nothing to say about it.
;;;;
;;;; Why it needs saying. On Windows, SBCL prints a pathname with forward slashes both
;;;; through `namestring' and when the pathname object itself is given to a `~A'
;;;; directive, so `C:/Users/...'. On Linux and macOS the two spellings are the same, so a
;;;; script can print either for years and nobody sees a difference. Before this file,
;;;; tree-root.lisp printed the native spelling and tree-deps.lisp printed the other one,
;;;; and a test matching those messages had to know which script each assertion was aimed
;;;; at to pick the matching function.

(require :uiop)

(defpackage #:human-path
  (:use #:cl)
  (:export #:human-path))

(in-package #:human-path)

(defun human-path (path &key relative-to)
  "PATH as a message should print it for a person.

PATH is a pathname or a namestring. With RELATIVE-TO (a directory, normally the tree root)
and PATH inside it, the result is the part below RELATIVE-TO with forward slashes, as git
prints it. An absolute PATH otherwise comes out whole, in the operating system's spelling.
A relative PATH, such as `dist/' as someone typed it, comes out with forward slashes, the
same on every operating system.

A namestring is parsed as a native one, so `C:/x' and `C:\\x' both come out as `C:\\x' on
Windows. NIL is returned as NIL, so a message can print a path that may be absent."
  (when path
    (let ((p (if (pathnamep path) path (uiop:parse-native-namestring path))))
      (cond ((and relative-to (uiop:subpathp p (uiop:ensure-directory-pathname relative-to)))
             (uiop:unix-namestring (uiop:enough-pathname p (uiop:ensure-directory-pathname relative-to))))
            ((uiop:absolute-pathname-p p) (uiop:native-namestring p))
            (t (uiop:unix-namestring p))))))
