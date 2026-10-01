;;;; repository.lisp --- repositories, staging, commits, history, reading and diffs.
;;;;
;;;; Every foreign object made here is freed in the same function that made it, inside an
;;;; UNWIND-PROTECT, so a GIT-ERROR part way through leaks nothing. Nothing foreign is
;;;; returned to the caller except inside a REPOSITORY, which CLOSE-REPOSITORY frees.

(in-package #:aion/libgit)

;;; --- errors ------------------------------------------------------------------------

(define-condition git-error (error)
  ((operation :initarg :operation :reader git-error-operation)
   (code :initarg :code :reader git-error-code)
   (class :initarg :class :reader git-error-class)
   (message :initarg :message :reader git-error-message))
  (:report
   (lambda (c stream)
     (format stream "libgit2: ~A failed with code ~D (error class ~D): ~A"
             (git-error-operation c) (git-error-code c) (git-error-class c)
             (or (git-error-message c) "no message"))))
  (:documentation "A libgit2 call returned an error. CODE is libgit2's return code (for
example -3, GIT_ENOTFOUND), CLASS is the git_error_t it reported, MESSAGE its text."))

(define-condition repository-closed (error)
  ((repository :initarg :repository :reader repository-closed-repository))
  (:report (lambda (c stream)
             (format stream "The repository at ~A has been closed."
                     (repository-workdir (repository-closed-repository c)))))
  (:documentation "An operation was asked of a repository after CLOSE-REPOSITORY."))

(defun %last-error ()
  "libgit2's last error on this thread, as (values class message)."
  (let ((e (%error-last)))
    (if (cffi:null-pointer-p e)
        (values 0 nil)
        (let ((message (cffi:foreign-slot-value e '(:struct git-error-struct) 'message)))
          (values (cffi:foreign-slot-value e '(:struct git-error-struct) 'klass)
                  (if (cffi:null-pointer-p message)
                      nil
                      (cffi:foreign-string-to-lisp message :encoding :utf-8)))))))

(defun %check (operation code)
  "CODE when it is not negative, else a GIT-ERROR for OPERATION."
  (when (minusp code)
    (multiple-value-bind (class message) (%last-error)
      (error 'git-error :operation operation :code code :class class :message message)))
  code)

;;; --- ids and strings ---------------------------------------------------------------

(defun %oid-hex (oid)
  "The 40-character lowercase hex form of the git_oid at the pointer OID."
  (with-output-to-string (s)
    (dotimes (i +oid-size+)
      (format s "~(~2,'0x~)" (cffi:mem-aref oid :uint8 i)))))

(defun %string (pointer)
  (if (cffi:null-pointer-p pointer)
      nil
      (cffi:foreign-string-to-lisp pointer :encoding :utf-8)))

(defconstant +unix-epoch+ (encode-universal-time 0 0 0 1 1 1970 0))

;;; --- repositories ------------------------------------------------------------------

(defstruct (repository (:constructor %make-repository (pointer workdir)))
  "An open repository. POINTER is libgit2's git_repository, or a null pointer once closed."
  (pointer nil)
  (workdir nil :read-only t)
  (lock (sb-thread:make-mutex :name "aion/libgit repository") :read-only t))

(defmethod print-object ((r repository) stream)
  (print-unreadable-object (r stream :type t)
    (format stream "~A~:[~; (closed)~]" (repository-workdir r)
            (cffi:null-pointer-p (repository-pointer r)))))

(defmacro %with-repository-pointer ((var repository) &body body)
  "Run BODY with VAR bound to REPOSITORY's git_repository, holding its lock. Signals
REPOSITORY-CLOSED if it has been closed."
  (let ((r (gensym "REPOSITORY")))
    `(let ((,r ,repository))
       (sb-thread:with-recursive-lock ((repository-lock ,r))
         (let ((,var (repository-pointer ,r)))
           (when (cffi:null-pointer-p ,var)
             (error 'repository-closed :repository ,r))
           ,@body)))))

(defun %directory-namestring (directory)
  "DIRECTORY as libgit2 takes it: native, and without a trailing separator. libgit2 appends
/.git/ itself, and on Windows it cannot resolve the doubled separator a trailing one leaves
(\"failed to resolve path 'C:/.../dir//.git/'\", #470's first Windows run). POSIX realpath
accepts it, which is why macOS and Linux never showed this. A drive root such as C:\\ keeps
its separator."
  (let ((name (uiop:native-namestring (uiop:ensure-directory-pathname directory))))
    (loop while (and (> (length name) 1)
                     (member (char name (1- (length name))) '(#\/ #\\))
                     (not (and (= (length name) 3) (char= (char name 1) #\:))))
          do (setf name (subseq name 0 (1- (length name)))))
    name))

(defun %wrap (out)
  "A REPOSITORY for the git_repository written to OUT."
  (let ((pointer (cffi:mem-ref out :pointer)))
    (%make-repository pointer (%string (%repository-workdir pointer)))))

(defun init-repository (directory)
  "Create a repository with a working directory at DIRECTORY, creating the directory if it
does not exist, and return it open. On a directory that is already a repository, libgit2
reinitialises it, which changes nothing that is already there."
  (ensure-loaded)
  (let ((path (%directory-namestring directory)))
    (ensure-directories-exist (uiop:ensure-directory-pathname directory))
    (cffi:with-foreign-object (out :pointer)
      (%check "git_repository_init" (%repository-init out path 0))
      (%wrap out))))

(defun open-repository (directory)
  "Open the repository at DIRECTORY. Signals GIT-ERROR, with code -3 (GIT_ENOTFOUND), when
DIRECTORY is not a repository."
  (ensure-loaded)
  (cffi:with-foreign-object (out :pointer)
    (%check "git_repository_open" (%repository-open out (%directory-namestring directory)))
    (%wrap out)))

(defun close-repository (repository)
  "Free REPOSITORY. Closing it again does nothing; any other use signals REPOSITORY-CLOSED."
  (sb-thread:with-recursive-lock ((repository-lock repository))
    (let ((pointer (repository-pointer repository)))
      (unless (cffi:null-pointer-p pointer)
        (setf (repository-pointer repository) (cffi:null-pointer))
        (%repository-free pointer))))
  (values))

(defmacro with-repository ((var form) &body body)
  "Bind VAR to the repository FORM returns, run BODY, and close the repository however BODY
exits. FORM is usually (OPEN-REPOSITORY dir) or (INIT-REPOSITORY dir)."
  `(let ((,var ,form))
     (unwind-protect (progn ,@body)
       (close-repository ,var))))

;;; --- staging -----------------------------------------------------------------------

(defun stage (repository paths)
  "Stage each path in PATHS, which are relative to the working directory and use /. A path
whose file exists is added as it is now; a path whose file is gone is removed from the
index. The index is written once, after every path.

STAGE and COMMIT first re-read the index file if it changed on disk since libgit2 last read
it. libgit2 keeps a repository's index in memory, so without this, a git checkout or git add
run by another process would be overwritten by the copy from before it."
  (%with-repository-pointer (repo repository)
    (cffi:with-foreign-object (out :pointer)
      (%check "git_repository_index" (%repository-index out repo))
      (let ((index (cffi:mem-ref out :pointer)))
        (unwind-protect
             (progn
               (%check "git_index_read" (%index-read index 0))
               (dolist (path paths)
                 (if (probe-file (merge-pathnames path (repository-workdir repository)))
                     (%check "git_index_add_bypath" (%index-add-bypath index path))
                     (%check "git_index_remove_bypath" (%index-remove-bypath index path))))
               (%check "git_index_write" (%index-write index)))
          (%index-free index)))))
  (values))

;;; --- commits -----------------------------------------------------------------------

(defun %head-id (repo oid)
  "Write HEAD's commit id to OID and return T, or return NIL when HEAD is unborn."
  (let ((code (%reference-name-to-id oid repo "HEAD")))
    (cond ((zerop code) t)
          ((or (= code +git-enotfound+) (= code +git-eunbornbranch+)) nil)
          (t (%check "git_reference_name_to_id" code)))))

(defun %ensure-final-newline (message)
  (if (and (plusp (length message)) (char= (char message (1- (length message))) #\Newline))
      message
      (concatenate 'string message (string #\Newline))))

(defun commit (repository message &key (author (error "COMMIT needs :AUTHOR."))
                                        (email (error "COMMIT needs :EMAIL."))
                                        (time (get-universal-time)))
  "Commit the index to HEAD's branch, with HEAD as the parent unless HEAD is unborn, and
return the new commit's id as 40 hex characters. AUTHOR and EMAIL are both the author and
the committer; TIME is a universal time, recorded in UTC. MESSAGE gets a final newline if it
has none, as git commit -m stores it."
  (%with-repository-pointer (repo repository)
    (let ((index nil) (tree nil) (signature nil) (parent nil))
      (cffi:with-foreign-objects ((out :pointer) (tree-id :uint8 +oid-size+)
                                  (parent-id :uint8 +oid-size+) (commit-id :uint8 +oid-size+)
                                  (parents :pointer 1))
        (unwind-protect
             (progn
               (%check "git_repository_index" (%repository-index out repo))
               (setf index (cffi:mem-ref out :pointer))
               (%check "git_index_read" (%index-read index 0))
               (%check "git_index_write_tree" (%index-write-tree tree-id index))
               (%check "git_tree_lookup" (%tree-lookup out repo tree-id))
               (setf tree (cffi:mem-ref out :pointer))
               (%check "git_signature_new"
                       (%signature-new out author email (- time +unix-epoch+) 0))
               (setf signature (cffi:mem-ref out :pointer))
               (when (%head-id repo parent-id)
                 (%check "git_commit_lookup" (%commit-lookup out repo parent-id))
                 (setf parent (cffi:mem-ref out :pointer))
                 (setf (cffi:mem-aref parents :pointer 0) parent))
               (cffi:with-foreign-string (head "HEAD")
                 (%check "git_commit_create"
                         (%commit-create commit-id repo head signature signature
                                         (cffi:null-pointer) (%ensure-final-newline message)
                                         tree (if parent 1 0)
                                         (if parent parents (cffi:null-pointer)))))
               (%oid-hex commit-id))
          (when parent (%commit-free parent))
          (when signature (%signature-free signature))
          (when tree (%tree-free tree))
          (when index (%index-free index)))))))

;;; --- reading -----------------------------------------------------------------------

(defstruct (commit-info (:constructor %make-commit-info))
  "One commit, as HISTORY reports it. TIME is the author time as a universal time. MESSAGE
is as stored, less one final newline. PARENTS are ids, first parent first."
  id message author email time parents)

(defun %peel-commit (repo revision)
  "The git_commit REVISION names, which the caller frees. REVISION is anything
git_revparse_single accepts: an id, a branch, HEAD, HEAD~2 and so on."
  (cffi:with-foreign-objects ((out :pointer) (peeled :pointer))
    (%check "git_revparse_single" (%revparse-single out repo revision))
    (let ((object (cffi:mem-ref out :pointer)))
      (unwind-protect
           (progn (%check "git_object_peel" (%object-peel peeled object +object-commit+))
                  (cffi:mem-ref peeled :pointer))
        (%object-free object)))))

(defmacro %with-commit ((var repo revision) &body body)
  `(let ((,var (%peel-commit ,repo ,revision)))
     (unwind-protect (progn ,@body)
       (%commit-free ,var))))

(defmacro %with-tree ((var commit) &body body)
  (let ((out (gensym "OUT")))
    `(cffi:with-foreign-object (,out :pointer)
       (%check "git_commit_tree" (%commit-tree ,out ,commit))
       (let ((,var (cffi:mem-ref ,out :pointer)))
         (unwind-protect (progn ,@body)
           (%tree-free ,var))))))

(defun %entry (commit path)
  "PATH's entry in COMMIT's tree as (MODE . ID-HEX), or NIL when COMMIT has no PATH. The mode
is part of it because git counts a change of mode alone, such as chmod +x, as a change."
  (%with-tree (tree commit)
    (cffi:with-foreign-object (out :pointer)
      (let ((code (%tree-entry-bypath out tree path)))
        (if (= code +git-enotfound+)
            nil
            (let ((entry (progn (%check "git_tree_entry_bypath" code)
                                (cffi:mem-ref out :pointer))))
              (unwind-protect (cons (%tree-entry-filemode entry)
                                    (%oid-hex (%tree-entry-id entry)))
                (%tree-entry-free entry))))))))

(defun %parent-list (commit)
  "COMMIT's parents as git_commit pointers, which the caller frees."
  (loop for n below (%commit-parentcount commit)
        collect (cffi:with-foreign-object (out :pointer)
                  (%check "git_commit_parent" (%commit-parent out commit n))
                  (cffi:mem-ref out :pointer))))

(defun %oid-octets (oid)
  "The git_oid at the pointer OID, copied into a Lisp octet vector."
  (let ((v (make-array +oid-size+ :element-type '(unsigned-byte 8))))
    (dotimes (i +oid-size+ v) (setf (aref v i) (cffi:mem-aref oid :uint8 i)))))

(defun %lookup-commit (repo octets)
  "The git_commit whose id is the octet vector OCTETS, which the caller frees."
  (cffi:with-foreign-objects ((oid :uint8 +oid-size+) (out :pointer))
    (dotimes (i +oid-size+) (setf (cffi:mem-aref oid :uint8 i) (aref octets i)))
    (%check "git_commit_lookup" (%commit-lookup out repo oid))
    (cffi:mem-ref out :pointer)))

(defun %path-history (repo start path limit)
  "The commits git log START -- PATH lists, newest first, as COMMIT-INFO structures, at most
LIMIT of them. START is a git_commit, which the caller frees.

GIT'S RULE FOR A PATH, with its default history simplification (git help log, \"History
Simplification\"). A commit whose PATH entry, mode and id, equals one of its parents' is
TREESAME to that parent: it is not listed, and the walk follows that parent only, so the other
side of a merge that kept one side's version of PATH is not walked at all. A commit that
differs from every parent is listed, and the walk follows all of them. A root commit is listed
when it has PATH. Commits come out by committer time, newest first, as git log's default order
does."
  (let ((frontier (list (cons (%commit-time start) (%oid-octets (%commit-id start)))))
        (seen (make-hash-table :test #'equalp))
        (found '())
        (count 0))
    (setf (gethash (cdar frontier) seen) t)
    (loop while (and frontier (or (null limit) (< count limit)))
          do (let* ((next (reduce (lambda (a b) (if (> (car b) (car a)) b a)) frontier))
                    (commit (progn (setf frontier (remove next frontier :count 1 :test #'eq))
                                   (%lookup-commit repo (cdr next))))
                    (parents '()))
               (unwind-protect
                    (let* ((mine (progn (setf parents (%parent-list commit))
                                        (%entry commit path)))
                           (same (find-if (lambda (p) (equal mine (%entry p path))) parents))
                           (follow (if same (list same) parents)))
                      (when (if parents (null same) mine)
                        (push (%commit-info commit parents) found)
                        (incf count))
                      (dolist (p follow)
                        (let ((id (%oid-octets (%commit-id p))))
                          (unless (gethash id seen)
                            (setf (gethash id seen) t)
                            ;; Appended, so that among commits with one time the one met
                            ;; first comes out first.
                            (setf frontier (append frontier
                                                   (list (cons (%commit-time p) id))))))))
                 (mapc #'%commit-free parents)
                 (%commit-free commit))))
    (nreverse found)))

(defun %commit-info (commit parents)
  (let* ((author (%commit-author commit))
         (when (cffi:foreign-slot-pointer author '(:struct git-signature) 'when))
         (message (or (%string (%commit-message commit)) "")))
    (%make-commit-info
     :id (%oid-hex (%commit-id commit))
     :message (if (and (plusp (length message))
                       (char= (char message (1- (length message))) #\Newline))
                  (subseq message 0 (1- (length message)))
                  message)
     :author (%string (cffi:foreign-slot-value author '(:struct git-signature) 'name))
     :email (%string (cffi:foreign-slot-value author '(:struct git-signature) 'email))
     :time (+ +unix-epoch+ (cffi:foreign-slot-value when '(:struct git-time) 'time))
     :parents (mapcar (lambda (p) (%oid-hex (%commit-id p))) parents))))

(defun resolve-revision (repository revision)
  "The id of the commit REVISION names, as 40 hex characters. Signals GIT-ERROR when it
names nothing."
  (%with-repository-pointer (repo repository)
    (%with-commit (commit repo revision)
      (%oid-hex (%commit-id commit)))))

(defun history (repository &key path (start "HEAD") limit)
  "The commits reachable from START, newest first, as COMMIT-INFO structures, as git log START
lists them. With PATH, the commits git log START -- PATH lists, including a change of mode
alone and following git's default history simplification at merges (see %PATH-HISTORY). With
LIMIT, at most that many. A repository whose HEAD is unborn has no history, so this returns
NIL for it when START is HEAD."
  (%with-repository-pointer (repo repository)
    (cffi:with-foreign-objects ((out :pointer) (oid :uint8 +oid-size+))
      (when (and (string= start "HEAD") (not (%head-id repo oid)))
        (return-from history nil))
      (when path
        (return-from history
          (%with-commit (start-commit repo start)
            (%path-history repo start-commit path limit))))
      (%check "git_revwalk_new" (%revwalk-new out repo))
      (let ((walk (cffi:mem-ref out :pointer))
            (found '()) (count 0))
        (unwind-protect
             (progn
               (%check "git_revwalk_sorting"
                       (%revwalk-sorting walk (logior +sort-topological+ +sort-time+)))
               (%with-commit (start-commit repo start)
                 (%check "git_revwalk_push" (%revwalk-push walk (%commit-id start-commit))))
               (loop
                 (when (and limit (>= count limit)) (return))
                 (let ((code (%revwalk-next oid walk)))
                   (when (= code +git-iterover+) (return))
                   (%check "git_revwalk_next" code))
                 (%check "git_commit_lookup" (%commit-lookup out repo oid))
                 (let* ((commit (cffi:mem-ref out :pointer))
                        (parents '()))
                   (unwind-protect
                        (progn
                          (setf parents (%parent-list commit))
                          (push (%commit-info commit parents) found)
                          (incf count))
                     (mapc #'%commit-free parents)
                     (%commit-free commit)))))
          (%revwalk-free walk))
        (nreverse found)))))

(defun read-at-revision (repository revision path)
  "The contents of PATH as it was at REVISION, as an octet vector, or NIL when REVISION has
no PATH. Signals GIT-ERROR when REVISION names nothing, or PATH is a directory."
  (%with-repository-pointer (repo repository)
    (%with-commit (commit repo revision)
      (%with-tree (tree commit)
        (cffi:with-foreign-object (out :pointer)
          (let ((code (%tree-entry-bypath out tree path)))
            (unless (= code +git-enotfound+)
              (%check "git_tree_entry_bypath" code)
              (let ((entry (cffi:mem-ref out :pointer)))
                (unwind-protect
                     (progn
                       (%check "git_blob_lookup" (%blob-lookup out repo (%tree-entry-id entry)))
                       (let ((blob (cffi:mem-ref out :pointer)))
                         (unwind-protect
                              (let* ((size (%blob-rawsize blob))
                                     (octets (make-array size :element-type '(unsigned-byte 8)))
                                     (content (%blob-rawcontent blob)))
                                (dotimes (i size octets)
                                  (setf (aref octets i) (cffi:mem-aref content :uint8 i))))
                           (%blob-free blob))))
                  (%tree-entry-free entry))))))))))

(defun %diff-trees (repo old-tree new-tree)
  (cffi:with-foreign-objects ((out :pointer) (buf '(:struct git-buf)))
    (%check "git_diff_tree_to_tree" (%diff-tree-to-tree out repo old-tree new-tree
                                                        (cffi:null-pointer)))
    (let ((diff (cffi:mem-ref out :pointer)))
      (unwind-protect
           (progn
             ;; Rename detection, which git diff does by default and git_diff_tree_to_tree
             ;; does not. Asked for explicitly: left to diff.renames in the repository's
             ;; config, a repository that turns it off would get delete-plus-add here.
             (cffi:with-foreign-object (options '(:struct git-diff-find-options))
               (%check "git_diff_find_options_init"
                       (%diff-find-options-init options +diff-find-options-version+))
               (setf (cffi:foreign-slot-value options '(:struct git-diff-find-options) 'flags)
                     +diff-find-renames+)
               (%check "git_diff_find_similar" (%diff-find-similar diff options)))
             (setf (cffi:foreign-slot-value buf '(:struct git-buf) 'ptr) (cffi:null-pointer)
                   (cffi:foreign-slot-value buf '(:struct git-buf) 'reserved) 0
                   (cffi:foreign-slot-value buf '(:struct git-buf) 'size) 0)
             (%check "git_diff_to_buf" (%diff-to-buf buf diff +diff-format-patch+))
             (unwind-protect
                  (let* ((size (cffi:foreign-slot-value buf '(:struct git-buf) 'size))
                         (ptr (cffi:foreign-slot-value buf '(:struct git-buf) 'ptr))
                         (octets (make-array size :element-type '(unsigned-byte 8))))
                    (dotimes (i size)
                      (setf (aref octets i) (cffi:mem-aref ptr :uint8 i)))
                    (sb-ext:octets-to-string octets
                                             :external-format (list :utf-8 :replacement (code-char #xfffd))))
               (%buf-dispose buf)))
        (%diff-free diff)))))

(defun diff-text (repository from to)
  "The patch from revision FROM to revision TO, as git diff FROM TO prints it without
colour, with renames detected as git diff detects them by default. FROM may be NIL, meaning an empty tree, so the patch adds everything TO has. Bytes
that are not UTF-8 appear as U+FFFD."
  (%with-repository-pointer (repo repository)
    (%with-commit (new repo to)
      (%with-tree (new-tree new)
        (if from
            (%with-commit (old repo from)
              (%with-tree (old-tree old)
                (%diff-trees repo old-tree new-tree)))
            (%diff-trees repo (cffi:null-pointer) new-tree))))))
