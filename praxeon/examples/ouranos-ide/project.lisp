;;;; project.lisp --- a project folder: confined file access, the tree, buffers and tabs (#1228).
;;;;
;;;; The IDE opens one folder as a project. Every path the page sends is relative to that
;;;; folder, its root, and is refused unless the file it resolves to is inside the root. The
;;;; check is made on the resolved path, after `..' and symbolic links have been followed, so a
;;;; link inside the project that points outside it is refused like `../secret'.
;;;;
;;;; The file has two halves.
;;;;
;;;;   - Pure functions, which do no IO: splitting a relative path, the prefix test that decides
;;;;     whether a resolved path is inside the root, which tree entries are hidden by default,
;;;;     the editor's tabs and their buffers, and the decisions a save and a close make. The
;;;;     tests call these directly.
;;;;   - The shell, which reads and writes files: opening a project, resolving a path in it,
;;;;     listing a folder, reading a file into a buffer, saving one, and making a file or a
;;;;     folder. A save writes a temporary file in the same folder and renames it over the
;;;;     original, so a write that fails leaves the original as it was and no partial file.
;;;;
;;;; WINDOWS. SBCL's TRUENAME follows a symbolic link on Linux and macOS but does not see a
;;;; Windows junction (aion/fs, delete-tree.lisp). On Windows a path is therefore resolved
;;;; without the operating system: `.' and `..' are removed from the text, and a path that
;;;; passes through a junction or any other link is refused, whether the link points inside the
;;;; project or not.
;;;;
;;;; NOT COVERED. A path is checked and then opened as two steps, so another process that
;;;; replaces a folder of the project with a link between the two can still direct one read or
;;;; write outside the root. The project is the user's own folder, and the IDE runs code from the
;;;; page anyway; the check is there so the file tree and the tabs cannot reach outside the
;;;; folder by accident or through a link the project contains.

(cl:defpackage #:praxeon/examples/ouranos-ide/project
  (:use #:cl)
  (:local-nicknames (#:fs #:aion/fs))
  (:export
   ;; pure
   #:relative-parts #:inside-root-p #:hidden-entry-p #:visible-entries
   #:*ignored-directory-names* #:*ignored-file-types*
   #:buffer #:buffer-id #:buffer-project #:buffer-path #:buffer-text #:buffer-stamp
   #:buffer-generation #:buffer-modified-p
   #:tabs #:make-tabs #:tabs-buffers #:tabs-active #:tabs-next-id
   #:tabs-find #:tabs-find-path #:tabs-open #:tabs-close #:tabs-activate #:tabs-replace
   #:save-decision #:close-decision
   ;; shell
   #:project #:open-project #:project-root #:project-name
   #:path-refused #:path-refused-path #:path-refused-reason
   #:resolve #:list-folder #:read-buffer #:file-stamp #:save-buffer #:reload-buffer
   #:atomic-write-file #:make-file #:make-folder
   #:*file-size-limit*))

(cl:in-package #:praxeon/examples/ouranos-ide/project)

;;; ==========================================================================================
;;; Pure functions
;;; ==========================================================================================

;;; --- paths --------------------------------------------------------------------------------

(defun %separator-p (char)
  "True for a character that separates the parts of a path the page sends: / everywhere, and a
backslash as well on Windows, where it is the native separator."
  (or (char= char #\/)
      #+win32 (char= char #\\)))

(defun relative-parts (text)
  "TEXT, a path relative to the project's root as the page sends it, split into its parts.
Returns the list of parts and NIL, or NIL and a reason string when TEXT cannot name anything
inside a project. An empty TEXT, or one of only separators, is the root itself, and gives the
empty list.

Refused here, before anything is looked up: an absolute path (one that starts with a
separator), a path containing a NUL character, and on Windows a path containing a colon, which
Windows reads as a drive (C:) or a stream. `.' parts are
dropped. `..' parts are kept: whether they leave the root is decided on the resolved path."
  (cond ((and (plusp (length text)) (%separator-p (char text 0)))
         (values nil "it is an absolute path; give a path relative to the project's folder"))
        ((find #\Nul text)
         (values nil "it contains a NUL character"))
        #+win32
        ((find #\: text)
         (values nil "it contains a colon, which Windows reads as a drive or a stream"))
        (t
         (values (loop with start = 0
                       for end = (position-if #'%separator-p text :start start)
                       for part = (subseq text start (or end (length text)))
                       unless (or (string= part "") (string= part ".")) collect part
                       while end
                       do (setf start (1+ end)))
                 nil))))

(defun inside-root-p (root resolved)
  "True when RESOLVED, a resolved native path, is the folder ROOT itself or a path under it.
ROOT is the root's resolved native path, written with a trailing separator, as a directory's
native name is. The comparison is of characters, case included: a path that differs from the
root only in case is refused, which on a case-insensitive file system refuses more than it
needs to and never less."
  (let ((bare (string-right-trim "/\\" root)))
    (or (string= resolved root)
        (string= resolved bare)
        (and (> (length resolved) (length root))
             (string= root resolved :end2 (length root))))))

;;; --- the file tree ------------------------------------------------------------------------

(defparameter *ignored-directory-names* '("node_modules" "fasl" "fasls" "__pycache__")
  "Names of folders the tree leaves out unless hidden entries are shown. A name that starts
with a dot, such as .git or .cache, is left out as well, by HIDDEN-ENTRY-P.")

(defparameter *ignored-file-types*
  '("fasl" "fas" "ufasl" "dx64fsl" "lx64fsl" "dx32fsl" "lx32fsl" "wx64fsl" "x86f" "cfsl")
  "File types, without the dot and in lower case, of compiled Lisp files the tree leaves out
unless hidden entries are shown.")

(defun %file-type (name)
  (let ((dot (position #\. name :from-end t)))
    (and dot (plusp dot) (string-downcase (subseq name (1+ dot))))))

(defun hidden-entry-p (name kind)
  "True when the tree leaves out the entry NAME by default. KIND is :DIRECTORY or :FILE. Left
out: any name that starts with a dot (.git, .DS_Store), a folder in *IGNORED-DIRECTORY-NAMES*
(node_modules), and a file whose type is in *IGNORED-FILE-TYPES* (compiled Lisp)."
  (or (and (plusp (length name)) (char= #\. (char name 0)))
      (and (eq kind :directory)
           (member name *ignored-directory-names* :test #'string=)
           t)
      (and (eq kind :file)
           (member (%file-type name) *ignored-file-types* :test #'equal)
           t)))

(defun visible-entries (entries &key show-hidden)
  "ENTRIES, a list of (NAME . KIND) with KIND :DIRECTORY or :FILE, as the tree shows them:
folders first, then files, each group sorted by name ignoring case. Entries HIDDEN-ENTRY-P
names are left out unless SHOW-HIDDEN is true. A new list; ENTRIES is not changed."
  (stable-sort (copy-list (if show-hidden
                              entries
                              (remove-if (lambda (e) (hidden-entry-p (car e) (cdr e))) entries)))
               (lambda (a b)
                 (if (eq (cdr a) (cdr b))
                     (string-lessp (car a) (car b))
                     (eq (cdr a) :directory)))))

;;; --- buffers and tabs ---------------------------------------------------------------------
;;;
;;; A buffer is the editor's copy of one file. Its TEXT is the file's text as it was last
;;; read or saved, and its STAMP the file's bytes at that moment, which a save compares with
;;; the bytes on disk to find a change made by someone else. What the user has typed since is
;;; in the page, not here: the page sends it with a save or a close.
;;;
;;; The tabs are a value: every function below returns a new TABS and leaves its argument as
;;; it was. A window keeps the current value in its data and replaces it.

(defstruct (buffer (:constructor %make-buffer))
  (id 0 :type integer :read-only t)
  (project nil :read-only t)
  (path "" :type string :read-only t)
  (text "" :type string :read-only t)
  (stamp nil :read-only t)
  (generation 0 :type integer :read-only t))

(setf (documentation 'buffer 'type)
      "One open file. ID numbers it among the tabs. PROJECT is the project it belongs to and
PATH its path relative to that project's root, with / between parts. TEXT is the file's text
when it was last read or saved, STAMP the file's bytes then, and GENERATION counts the times it
was read again from disk, so the page builds a new editor for it when it changes.")

(defun buffer-modified-p (buffer content)
  "True when CONTENT, the text the page holds for BUFFER, differs from what was last read or
saved."
  (string/= content (buffer-text buffer)))

(defstruct (tabs (:constructor %make-tabs))
  (buffers '() :type list :read-only t)
  (active nil :read-only t)
  (next-id 1 :type integer :read-only t))

(setf (documentation 'tabs 'type)
      "The editor's open files, in the order their tabs are shown. ACTIVE is the id of the
buffer shown, or NIL when the editor shows its scratch buffer. NEXT-ID is the id the next
buffer opened is given.")

(defun make-tabs ()
  "No open files."
  (%make-tabs))

(defun tabs-find (tabs id)
  "The buffer of TABS numbered ID, or NIL."
  (find id (tabs-buffers tabs) :key #'buffer-id))

(defun tabs-find-path (tabs project path)
  "The buffer of TABS for PATH in PROJECT, or NIL."
  (find-if (lambda (b) (and (eq project (buffer-project b)) (string= path (buffer-path b))))
           (tabs-buffers tabs)))

(defun tabs-open (tabs project path text stamp)
  "TABS with PATH of PROJECT open and active, and the buffer. A file that already has a tab is
not opened twice: its tab is made active, and its buffer is returned as it is."
  (let ((existing (tabs-find-path tabs project path)))
    (if existing
        (values (tabs-activate tabs (buffer-id existing)) existing)
        (let ((buffer (%make-buffer :id (tabs-next-id tabs) :project project :path path
                                    :text text :stamp stamp)))
          (values (%make-tabs :buffers (append (tabs-buffers tabs) (list buffer))
                              :active (buffer-id buffer)
                              :next-id (1+ (tabs-next-id tabs)))
                  buffer)))))

(defun tabs-activate (tabs id)
  "TABS with the buffer ID shown. NIL shows the scratch buffer. An id TABS does not have
leaves TABS as it is."
  (if (or (null id) (tabs-find tabs id))
      (%make-tabs :buffers (tabs-buffers tabs) :active id :next-id (tabs-next-id tabs))
      tabs))

(defun tabs-close (tabs id)
  "TABS without the buffer ID. When it was the active one, the tab after it becomes active,
or the one before it when it was the last, or the scratch buffer when no tab is left."
  (let* ((buffers (tabs-buffers tabs))
         (position (position id buffers :key #'buffer-id)))
    (if (null position)
        tabs
        (let* ((rest (remove id buffers :key #'buffer-id))
               (active (if (eql id (tabs-active tabs))
                           (let ((next (or (nth position rest) (car (last rest)))))
                             (and next (buffer-id next)))
                           (tabs-active tabs))))
          (%make-tabs :buffers rest :active active :next-id (tabs-next-id tabs))))))

(defun tabs-replace (tabs buffer &key text stamp reloaded)
  "TABS with BUFFER's TEXT and STAMP replaced, after a save or a reload. RELOADED true adds one
to its generation, so the page builds a new editor with the text read from disk."
  (let ((new (%make-buffer :id (buffer-id buffer) :project (buffer-project buffer)
                           :path (buffer-path buffer)
                           :text (or text (buffer-text buffer))
                           :stamp (or stamp (buffer-stamp buffer))
                           :generation (+ (buffer-generation buffer) (if reloaded 1 0)))))
    (values (%make-tabs :buffers (substitute new buffer (tabs-buffers tabs))
                        :active (tabs-active tabs) :next-id (tabs-next-id tabs))
            new)))

;;; --- what a save and a close do -----------------------------------------------------------

(defun save-decision (buffer disk-stamp overwrite)
  "What saving BUFFER does, given DISK-STAMP, the file's bytes now (or :MISSING when the file
is gone), and OVERWRITE, true when the user has already agreed to replace a changed file.
:WRITE, or :CONFLICT when the file on disk is no longer what was read or last saved, which the
page then asks about."
  (if (or overwrite (equalp disk-stamp (buffer-stamp buffer)))
      :write
      :conflict))

(defun close-decision (buffer content confirmed)
  "What closing BUFFER's tab does, given CONTENT, the text the page holds for it, and
CONFIRMED, true when the user has already agreed to lose unsaved changes. :CLOSE, or :ASK when
the content has changes that were not saved."
  (if (or confirmed (not (buffer-modified-p buffer content)))
      :close
      :ask))

;;; ==========================================================================================
;;; The shell: everything here reads or writes files
;;; ==========================================================================================

(defparameter *file-size-limit* (* 4 1024 1024)
  "The largest file, in bytes, the editor opens.")

(defclass project ()
  ((root :initarg :root :reader project-root
         :documentation "The folder's resolved path, a directory pathname.")
   (root-native :initarg :root-native :reader %root-native
                :documentation "ROOT's native name, with a trailing separator."))
  (:documentation "A folder opened as a project. Create one with OPEN-PROJECT."))

(defmethod print-object ((p project) stream)
  (print-unreadable-object (p stream :type t)
    (write-string (%root-native p) stream)))

(define-condition path-refused (error)
  ((path :initarg :path :reader path-refused-path)
   (reason :initarg :reason :reader path-refused-reason))
  (:report (lambda (c s)
             (format s "The path ~S was refused: ~A." (path-refused-path c) (path-refused-reason c))))
  (:documentation "A path the page sent could not be used: it resolves outside the project,
names nothing, or is not the kind of entry the operation needs. The report is safe to show on
the page; it names only the path the page sent."))

(defun %refuse (path reason &rest arguments)
  (error 'path-refused :path path :reason (apply #'format nil reason arguments)))

(defun %native-directory (pathname)
  "PATHNAME, a directory pathname, as a native name with a trailing separator."
  (uiop:native-namestring (uiop:ensure-directory-pathname pathname)))

(defun open-project (folder)
  "FOLDER, a pathname or a native path string, opened as a project. Its root is the folder's
resolved path. Signals PATH-REFUSED when FOLDER is not an existing folder."
  (let* ((given (if (stringp folder)
                    (uiop:ensure-directory-pathname (uiop:parse-native-namestring folder))
                    (uiop:ensure-directory-pathname folder)))
         (root (and (uiop:directory-pathname-p given) (probe-file given))))
    (unless (and root (uiop:directory-pathname-p root))
      (%refuse (princ-to-string folder) "it is not an existing folder"))
    (make-instance 'project :root root :root-native (%native-directory root))))

(defun project-name (project)
  "The name of PROJECT's folder."
  (car (last (pathname-directory (project-root project)))))

#-win32
(defun %physical (project parts)
  "The resolved path of PARTS under PROJECT's root, with `..' and links followed by the
operating system, or NIL when nothing exists there."
  (let ((native (format nil "~A~{~A~^/~}" (%root-native project) parts)))
    (probe-file (uiop:parse-native-namestring native))))

#+win32
(defun %physical (project parts)
  "On Windows, TRUENAME does not see a junction, so PARTS are resolved by text: `..' removes
the part before it, and a `..' above the root refuses the path. Every step is then checked
with AION/FS:LINK-P, and a path through a link is refused. NIL when nothing exists there."
  (let ((kept '()))
    (dolist (part parts)
      (if (string= part "..")
          (if kept
              (pop kept)
              (%refuse (format nil "~{~A~^/~}" parts) "it leads outside the project's folder"))
          (push part kept)))
    (let ((native (%root-native project)))
      (dolist (part (reverse kept))
        (setf native (concatenate 'string native part))
        (when (fs:link-p native)
          (%refuse (format nil "~{~A~^/~}" parts)
                   "it passes through a link, which the IDE does not follow on Windows"))
        (setf native (concatenate 'string native "\\")))
      (probe-file (uiop:parse-native-namestring (string-right-trim "\\" native))))))

(defun resolve (project relative &key (must-exist t))
  "The resolved pathname of RELATIVE, a path relative to PROJECT's root, once `..' and links
are followed. Signals PATH-REFUSED when RELATIVE is not a relative path (RELATIVE-PARTS), or
when the resolved path is not inside the root (INSIDE-ROOT-P on the resolved path).

With MUST-EXIST true, the path must name an existing file or folder. With MUST-EXIST NIL it
may name an entry that does not exist yet, for a new file or folder: its folder must exist and
is resolved instead, its last part must be a plain name, and the pathname returned is that
name in the resolved folder."
  (multiple-value-bind (parts reason) (relative-parts relative)
    (when reason (%refuse relative "~A" reason))
    (let ((found (%physical project parts)))
      (cond (found
             (%check-inside project relative found))
            (must-exist
             (%refuse relative "nothing exists at that path"))
            ((null parts)
             (%refuse relative "it names the project's folder itself"))
            (t
             (let ((name (car (last parts))))
               (when (string= name "..")
                 (%refuse relative "the new entry's name is .."))
               (let ((folder (%physical project (butlast parts))))
                 (unless (and folder (uiop:directory-pathname-p folder))
                   (%refuse relative "its folder does not exist"))
                 (%check-inside project relative folder)
                 (uiop:parse-native-namestring
                  (concatenate 'string (%native-directory folder) name)))))))))

(defun %check-inside (project relative resolved)
  "RESOLVED when it is inside PROJECT's root; otherwise signal PATH-REFUSED for RELATIVE."
  (if (inside-root-p (%root-native project) (uiop:native-namestring resolved))
      resolved
      (%refuse relative "it resolves outside the project's folder")))

(defun %entry-name (pathname)
  (if (uiop:directory-pathname-p pathname)
      (car (last (pathname-directory pathname)))
      (file-namestring pathname)))

(defun list-folder (project relative)
  "The entries of the folder RELATIVE in PROJECT, as a list of (NAME . KIND), KIND :DIRECTORY
or :FILE, unsorted and unfiltered (see VISIBLE-ENTRIES). Links are listed as their own names
and not followed; opening one resolves it and is refused when it leads outside the project.
Signals PATH-REFUSED when RELATIVE is not a folder inside the project."
  (let ((folder (resolve project relative)))
    (unless (uiop:directory-pathname-p folder)
      (%refuse relative "it is not a folder"))
    (append (mapcar (lambda (p) (cons (%entry-name p) :directory))
                    (uiop:subdirectories folder))
            (mapcar (lambda (p) (cons (%entry-name p) :file))
                    (uiop:directory-files folder)))))

(defun %read-octets (pathname)
  "The bytes of the file PATHNAME. The count READ-SEQUENCE returns is checked against the
length, so a file that shrinks while it is read is an error and not a short buffer."
  (with-open-file (in pathname :element-type '(unsigned-byte 8))
    (let* ((octets (make-array (file-length in) :element-type '(unsigned-byte 8)))
           (count (read-sequence octets in)))
      (unless (= count (length octets))
        (error "Read ~D of ~D bytes of ~A." count (length octets) pathname))
      octets)))

(defun file-stamp (project relative)
  "The bytes of the file RELATIVE in PROJECT now, or :MISSING when no file is there. Compared
with a buffer's stamp by SAVE-DECISION."
  (let ((pathname (handler-case (resolve project relative)
                    (path-refused () nil))))
    (if (and pathname (not (uiop:directory-pathname-p pathname)))
        (%read-octets pathname)
        :missing)))

(defun read-buffer (project relative)
  "Read the file RELATIVE in PROJECT for the editor. Returns its text, decoded as UTF-8, and its
stamp. Signals PATH-REFUSED when it is not a file inside the project, is larger than
*FILE-SIZE-LIMIT*, or is not UTF-8 text."
  (let ((pathname (resolve project relative)))
    (when (uiop:directory-pathname-p pathname)
      (%refuse relative "it is a folder"))
    (let ((size (with-open-file (in pathname :element-type '(unsigned-byte 8)) (file-length in))))
      (when (> size *file-size-limit*)
        (%refuse relative "the file is ~:D bytes, larger than the editor opens (~:D)"
                 size *file-size-limit*)))
    (let* ((octets (%read-octets pathname))
           (text (handler-case (sb-ext:octets-to-string octets :external-format :utf-8)
                   (error () (%refuse relative "the file is not UTF-8 text")))))
      (values text octets))))

(defvar *temporary-count* 0
  "How many temporary file names ATOMIC-WRITE-FILE has tried in this process.")

(defvar *temporary-lock* (sb-thread:make-mutex :name "ouranos-ide temporary files"))

(defun %temporary-sibling (pathname)
  "A pathname in PATHNAME's folder for a temporary file, not yet created. Its name starts with a
dot and carries this process's id and a counter, so the tree hides it and two saves do not
pick the same name."
  (let ((n (sb-thread:with-mutex (*temporary-lock*) (incf *temporary-count*))))
    (uiop:parse-native-namestring
     (format nil "~A.~A.~D-~D.tmp"
             (%native-directory (uiop:pathname-directory-pathname pathname))
             (file-namestring pathname)
             #+win32 (sb-alien:alien-funcall
                      (sb-alien:extern-alien "GetCurrentProcessId" (function sb-alien:unsigned-long)))
             #-win32 (sb-unix:unix-getpid)
             n))))

(defun %rename-over (from to)
  "Rename the file FROM to TO, replacing TO. On Linux and macOS this is rename(2), which
replaces TO in one step. On Windows it is SBCL's RENAME-FILE, which replaces an existing file
with MoveFileEx."
  #-win32 (sb-posix:rename (uiop:native-namestring from) (uiop:native-namestring to))
  #+win32 (rename-file from to))

(defun atomic-write-file (pathname writer)
  "Replace the file PATHNAME with what WRITER writes, so that it is never seen half written.
WRITER is called with an output stream of UTF-8 characters, open on a new temporary file in
PATHNAME's folder. When WRITER returns, the stream is finished and closed and the temporary
file is renamed over PATHNAME. When WRITER, or the close, or the rename signals an error, the
temporary file is deleted and the error is passed on, and PATHNAME is left as it was. Returns
PATHNAME."
  (let ((temporary (%temporary-sibling pathname))
        (done nil))
    (unwind-protect
         (progn
           (with-open-file (out temporary :direction :output :if-exists :error
                                          :if-does-not-exist :create :external-format :utf-8)
             (funcall writer out)
             (finish-output out))
           (%rename-over temporary pathname)
           (setf done t)
           pathname)
      (unless done
        (ignore-errors (delete-file temporary))))))

(defun save-buffer (buffer content &key overwrite)
  "Save CONTENT, the text the page holds for BUFFER, to BUFFER's file, through
ATOMIC-WRITE-FILE. Returns :SAVED and the new stamp. When the file on disk changed since BUFFER
was read or last saved, nothing is written and :CONFLICT is returned instead, unless OVERWRITE
is true (SAVE-DECISION). The path is resolved again at the save, so a link put in its way since
the file was opened is refused with PATH-REFUSED."
  (let* ((project (buffer-project buffer))
         (relative (buffer-path buffer))
         (pathname (resolve project relative :must-exist nil)))
    (ecase (save-decision buffer (file-stamp project relative) overwrite)
      (:conflict :conflict)
      (:write
       (atomic-write-file pathname (lambda (out) (write-string content out)))
       (values :saved (%read-octets pathname))))))

(defun reload-buffer (buffer)
  "Read BUFFER's file again. Returns its text and stamp, as READ-BUFFER does."
  (read-buffer (buffer-project buffer) (buffer-path buffer)))

(defun %check-new-name (relative)
  "Signal PATH-REFUSED unless the last part of RELATIVE is a usable name for a new entry."
  (multiple-value-bind (parts reason) (relative-parts relative)
    (when reason (%refuse relative "~A" reason))
    (let ((name (car (last parts))))
      (when (or (null name) (string= name ".."))
        (%refuse relative "it does not end in a name")))))

(defun make-file (project relative)
  "Create the empty file RELATIVE in PROJECT. Its folder must exist. Signals PATH-REFUSED when
the path is refused or something is already there. Returns the pathname."
  (%check-new-name relative)
  (let ((pathname (resolve project relative :must-exist nil)))
    (when (probe-file pathname)
      (%refuse relative "something with that name already exists"))
    (with-open-file (out pathname :direction :output :if-exists :error :if-does-not-exist :create)
      (declare (ignore out)))
    pathname))

(defun make-folder (project relative)
  "Create the folder RELATIVE in PROJECT. The folder it goes in must exist. Signals
PATH-REFUSED when the path is refused or something is already there. Returns the pathname."
  (%check-new-name relative)
  (let* ((pathname (resolve project relative :must-exist nil))
         (folder (uiop:ensure-directory-pathname pathname)))
    (when (or (probe-file pathname) (probe-file folder))
      (%refuse relative "something with that name already exists"))
    #-win32 (sb-posix:mkdir (string-right-trim "/" (uiop:native-namestring folder)) #o777)
    #+win32 (ensure-directories-exist folder)
    folder))
