;;;; attributes.lisp --- a file's Windows attributes, asked of Windows (#349).
;;;;
;;;; An app needs to know whether a file is read-only before writing to it, so it can say so
;;;; plainly. Parsing attrib.exe's output is how one app did it, and on any path with a
;;;; non-ASCII character the output did not decode and the answer came back "not read-only".
;;;; FILE-ATTRIBUTES asks GetFileAttributesW directly, with the path passed as UTF-16.
;;;;
;;;; It shares the one GetFileAttributesW call with DELETE-TREE, which needs the reparse-point
;;;; bit, and is re-exported by aion/windows, where a Windows query is looked for.

(in-package #:aion/fs)

(define-condition file-attributes-error (file-error)
  ((code :initarg :code :reader file-attributes-error-code))
  (:report (lambda (c s)
             (format s "cannot read the attributes of ~A (Windows error ~A)"
                     (let ((p (file-error-pathname c))) (if (stringp p) p (uiop:native-namestring p)))
                     (file-attributes-error-code c))))
  (:documentation "Signalled by FILE-ATTRIBUTES when Windows cannot answer for PATH, for
example because it does not exist (error 2) or a directory on its way does not (error 3)."))

(defparameter +attribute-bits+
  '((#x1 . :read-only) (#x2 . :hidden) (#x4 . :system) (#x10 . :directory) (#x20 . :archive)
    (#x100 . :temporary) (#x200 . :sparse) (#x400 . :reparse-point) (#x800 . :compressed)
    (#x1000 . :offline) (#x2000 . :not-content-indexed) (#x4000 . :encrypted))
  "Windows FILE_ATTRIBUTE_* bits and the keyword FILE-ATTRIBUTES reports for each.")

(defun file-attributes (path)
  "The Windows attributes of PATH, as a list of keywords in this order when present:
:READ-ONLY :HIDDEN :SYSTEM :DIRECTORY :ARCHIVE :TEMPORARY :SPARSE :REPARSE-POINT :COMPRESSED
:OFFLINE :NOT-CONTENT-INDEXED :ENCRYPTED. A plain file with no attribute set gives NIL.

PATH is a pathname, or a string, which is used as the native path without being parsed, so
names with [ ] and non-ASCII characters are passed through as they are. A link is described
itself, not its target: a junction reports :DIRECTORY and :REPARSE-POINT.

Signals FILE-ATTRIBUTES-ERROR, with the Windows error code, when Windows cannot answer.
Windows only: elsewhere it signals an error, since these attributes do not exist there."
  #+win32
  (let ((a (%attributes path)))
    (if (= a +invalid-file-attributes+)
        (error 'file-attributes-error :pathname path :code (%last-error))
        (loop for (bit . name) in +attribute-bits+
              when (logtest a bit) collect name)))
  #-win32
  (error "aion/fs:file-attributes is a Windows query; ~A has no Windows attributes on this system"
         path))
