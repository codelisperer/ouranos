;;;; fs.lisp --- filesystem operations, synchronous and asynchronous.
;;;;
;;;; The split is libuv's, not ours. Every uv_fs_* function takes a callback as its last
;;;; argument:
;;;;
;;;;   callback == NULL  ->  libuv runs the operation INLINE on the calling thread and
;;;;                         returns the result. It registers nothing with the loop and
;;;;                         mutates no loop state (see the POST macro in src/unix/fs.c),
;;;;                         which is why our synchronous calls need no loop at all and
;;;;                         are safe from any thread -- even while another thread is
;;;;                         running a loop.
;;;;   callback != NULL  ->  libuv queues the work on its threadpool and delivers
;;;;                         completion ON THE LOOP THREAD. So a loop is required, and
;;;;                         the answer arrives later.
;;;;
;;;; Node exposes the same two, and names the synchronous one with a Sync suffix because
;;;; in JavaScript blocking is the exceptional, dangerous choice. We invert that: SBCL
;;;; has real threads, blocking is ordinary, so the plain name is the direct one and
;;;; -ASYNC marks the specialised form.

(in-package #:aion/uv)

;;; ------------------------------------------------------------- the sync loop
;;;
;;; Synchronous calls still need a uv_loop_t* argument, though they never touch it. We
;;; use libuv's default loop and initialise it once, under a lock: uv_default_loop()
;;; initialises lazily on first call, so two threads racing to make the first
;;; synchronous call could otherwise initialise it twice.

(defvar %default-loop nil)
(defvar %default-loop-lock (sb-thread:make-mutex :name "aion/uv default loop"))

(defun default-loop-pointer ()
  (or %default-loop
      (sb-thread:with-mutex (%default-loop-lock)
        (or %default-loop
            (setf %default-loop (ffi:uv-default-loop))))))

;;; ------------------------------------------------------------------- requests

(defmacro with-fs-req ((var) &body body)
  "Allocate a uv_fs_t, run BODY, then clean and free it.

uv_fs_req_cleanup is not optional: for stat/scandir/realpath libuv allocates memory that
hangs off the request, and it is libuv's to free -- never ours."
  `(let ((,var (cffi:foreign-alloc :char :count (ffi:uv-req-size ffi:+uv-fs+))))
     (unwind-protect (progn ,@body)
       (ffi:uv-fs-req-cleanup ,var)
       (cffi:foreign-free ,var))))

(defun %null () (cffi:null-pointer))

;;; --------------------------------------------------------------- open flags

(defun open-flags (direction if-exists)
  "Translate CL-flavoured keywords into the platform's open(2) flags."
  (logior
   (ecase direction
     (:input ffi:o-rdonly)
     (:output ffi:o-wronly)
     (:io ffi:o-rdwr))
   (if (eq direction :input)
       0
       (ecase if-exists
         (:supersede (logior ffi:o-creat ffi:o-trunc))
         (:append (logior ffi:o-creat ffi:o-append))
         (:error (logior ffi:o-creat ffi:o-excl))
         (:overwrite ffi:o-creat)))))

;;; ------------------------------------------------------------------- file-info

(defstruct (file-info (:constructor %make-file-info))
  "The portable stat libuv normalises for us -- the same shape on every platform."
  (size 0 :type unsigned-byte)
  (kind :unknown)
  (mode 0)
  (nlink 0)
  (inode 0)
  (atime 0)
  (mtime 0)
  (ctime 0))

;;; S_IFMT bits. POSIX fixes these values and Windows' CRT uses the same for the
;;; subset it supports, so unlike the O_* flags they need no per-platform table.
(defconstant +s-ifmt+   #o170000)
(defconstant +s-ifreg+  #o100000)
(defconstant +s-ifdir+  #o040000)
(defconstant +s-iflnk+  #o120000)
(defconstant +s-ifsock+ #o140000)
(defconstant +s-ififo+  #o010000)
(defconstant +s-ifchr+  #o020000)
(defconstant +s-ifblk+  #o060000)

(defun mode-kind (mode)
  (case (logand mode +s-ifmt+)
    (#.+s-ifreg+ :file)
    (#.+s-ifdir+ :directory)
    (#.+s-iflnk+ :symlink)
    (#.+s-ifsock+ :socket)
    (#.+s-ififo+ :fifo)
    (#.+s-ifchr+ :character-device)
    (#.+s-ifblk+ :block-device)
    (t :unknown)))

(defun statbuf->file-info (statbuf)
  (flet ((timespec-seconds (field)
           ;; The slot symbol belongs to the FFI package -- unqualified, it would read
           ;; as AION/UV::TV-SEC and no such slot exists.
           (cffi:foreign-slot-value field '(:struct ffi::uv-timespec-t) 'ffi::tv-sec)))
    (cffi:with-foreign-slots ((ffi::st-size ffi::st-mode ffi::st-nlink ffi::st-ino)
                              statbuf (:struct ffi::uv-stat-t))
      (%make-file-info
       :size ffi::st-size
       :kind (mode-kind ffi::st-mode)
       :mode ffi::st-mode
       :nlink ffi::st-nlink
       :inode ffi::st-ino
       :atime (timespec-seconds
               (cffi:foreign-slot-pointer statbuf '(:struct ffi::uv-stat-t) 'ffi::st-atim))
       :mtime (timespec-seconds
               (cffi:foreign-slot-pointer statbuf '(:struct ffi::uv-stat-t) 'ffi::st-mtim))
       :ctime (timespec-seconds
               (cffi:foreign-slot-pointer statbuf '(:struct ffi::uv-stat-t) 'ffi::st-ctim))))))

;;; ----------------------------------------------------------- synchronous API

(defun file-info (path &key (follow-symlinks t))
  "Return a FILE-INFO for PATH. Signals FILE-NOT-FOUND if it does not exist."
  (ensure-available)
  (let ((path (namestring path)))
    (with-fs-req (req)
      (check (if follow-symlinks
                 (ffi:uv-fs-stat (default-loop-pointer) req path (%null))
                 (ffi:uv-fs-lstat (default-loop-pointer) req path (%null)))
             :operation :file-info :path path)
      (statbuf->file-info (ffi:uv-fs-get-statbuf req)))))

(defun %open-file (path flags mode operation)
  (with-fs-req (req)
    (check (ffi:uv-fs-open (default-loop-pointer) req path flags mode (%null))
           :operation operation :path path)))

(defun %close-file (fd)
  (with-fs-req (req)
    (ffi:uv-fs-close (default-loop-pointer) req fd (%null))))

(defun %read-fd (fd size path)
  "Read up to SIZE bytes from FD, returning an octet vector. Loops until EOF, because a
single read is permitted to return fewer bytes than asked for."
  (let ((result (make-array size :element-type '(unsigned-byte 8)))
        (total 0))
    (cffi:with-foreign-object (bufs '(:struct ffi::uv-buf-t))
      (let ((chunk (cffi:foreign-alloc :unsigned-char :count (max size 1))))
        (unwind-protect
             (loop
               (setf (cffi:foreign-slot-value bufs '(:struct ffi::uv-buf-t) 'ffi::base)
                     (cffi:inc-pointer chunk 0)
                     (cffi:foreign-slot-value bufs '(:struct ffi::uv-buf-t) 'ffi::len)
                     (- size total))
               (when (zerop (- size total)) (return))
               (let ((n (with-fs-req (req)
                          (check (ffi:uv-fs-read (default-loop-pointer) req fd bufs 1
                                                 total (%null))
                                 :operation :read-file :path path))))
                 (when (zerop n) (return))
                 (dotimes (i n)
                   (setf (aref result (+ total i))
                         (cffi:mem-aref chunk :unsigned-char i)))
                 (incf total n)
                 (when (>= total size) (return))))
          (cffi:foreign-free chunk))))
    (if (= total size) result (subseq result 0 total))))

(defun read-file (path &key (as :octets) (external-format :utf-8))
  "Read PATH completely and return its contents.

AS is :OCTETS (default) or :STRING. Synchronous: libuv does the work on this thread and
no event loop is involved."
  (ensure-available)
  (let* ((path (namestring path))
         (fd (%open-file path ffi:o-rdonly 0 :read-file)))
    (unwind-protect
         (let* ((size (with-fs-req (req)
                        (check (ffi:uv-fs-fstat (default-loop-pointer) req fd (%null))
                               :operation :read-file :path path)
                        (file-info-size (statbuf->file-info (ffi:uv-fs-get-statbuf req)))))
                (octets (%read-fd fd size path)))
           (ecase as
             (:octets octets)
             (:string (decode-octets octets external-format))))
      (%close-file fd))))

(defun decode-octets (octets external-format)
  "Decode OCTETS to a string using SBCL's own converter -- no encoding dependency added."
  (sb-ext:octets-to-string octets :external-format external-format))

(defun encode-string (string external-format)
  (sb-ext:string-to-octets string :external-format external-format))

(defun write-file (path contents &key (if-exists :supersede) (external-format :utf-8))
  "Write CONTENTS (a string or octet vector) to PATH. Returns the byte count.

IF-EXISTS is :SUPERSEDE (default, truncate), :APPEND, :OVERWRITE (write in place without
truncating) or :ERROR (refuse if the path exists)."
  (ensure-available)
  (let* ((path (namestring path))
         (octets (if (stringp contents)
                     (encode-string contents external-format)
                     (coerce contents '(vector (unsigned-byte 8)))))
         (size (length octets))
         (fd (%open-file path (open-flags :output if-exists) #o644 :write-file)))
    (unwind-protect
         (let ((chunk (cffi:foreign-alloc :unsigned-char :count (max size 1))))
           (unwind-protect
                (progn
                  (dotimes (i size)
                    (setf (cffi:mem-aref chunk :unsigned-char i) (aref octets i)))
                  (cffi:with-foreign-object (bufs '(:struct ffi::uv-buf-t))
                    (setf (cffi:foreign-slot-value bufs '(:struct ffi::uv-buf-t) 'ffi::base)
                          chunk
                          (cffi:foreign-slot-value bufs '(:struct ffi::uv-buf-t) 'ffi::len)
                          size)
                    ;; Offset -1 means "wherever the file position is", which is what
                    ;; makes :APPEND work rather than overwriting from zero.
                    (with-fs-req (req)
                      (check (ffi:uv-fs-write (default-loop-pointer) req fd bufs 1 -1
                                              (%null))
                             :operation :write-file :path path))))
             (cffi:foreign-free chunk)))
      (%close-file fd))
    size))

(defun make-directory (path &key (mode #o755) parents)
  "Create directory PATH. With PARENTS, create missing intermediate directories and do
not complain if it already exists."
  (ensure-available)
  (let ((path (string-right-trim "/\\" (namestring path))))
    (flet ((mkdir (p)
             (with-fs-req (req)
               (let ((code (ffi:uv-fs-mkdir (default-loop-pointer) req p mode (%null))))
                 (if (and parents (minusp code)
                          (string= (ffi:uv-err-name code) "EEXIST"))
                     0
                     (check code :operation :make-directory :path p))))))
      (if parents
          (let ((so-far nil))
            (dolist (component (split-path path) path)
              (setf so-far (if so-far
                               (concatenate 'string so-far "/" component)
                               component))
              (unless (string= so-far "")
                (mkdir so-far))))
          (progn (mkdir path) path)))))

(defun split-path (path)
  "Split PATH on / into components, keeping a leading empty component for an absolute
path so that rejoining reproduces the root."
  (let ((parts '())
        (start 0))
    (loop for i from 0 below (length path)
          when (char= (char path i) #\/)
            do (push (subseq path start i) parts)
               (setf start (1+ i)))
    (push (subseq path start) parts)
    (nreverse parts)))

(defun delete-file* (path)
  "Delete the file at PATH. Named with a trailing * to avoid clashing with CL:DELETE-FILE."
  (ensure-available)
  (let ((path (namestring path)))
    (with-fs-req (req)
      (check (ffi:uv-fs-unlink (default-loop-pointer) req path (%null))
             :operation :delete-file :path path))
    t))

(defun delete-directory (path)
  "Remove the (empty) directory at PATH."
  (ensure-available)
  (let ((path (namestring path)))
    (with-fs-req (req)
      (check (ffi:uv-fs-rmdir (default-loop-pointer) req path (%null))
             :operation :delete-directory :path path))
    t))

(defun rename-path (from to)
  "Rename FROM to TO."
  (ensure-available)
  (let ((from (namestring from)) (to (namestring to)))
    (with-fs-req (req)
      (check (ffi:uv-fs-rename (default-loop-pointer) req from to (%null))
             :operation :rename-path :path from))
    t))

(defun real-path (path)
  "Resolve PATH to a canonical absolute path."
  (ensure-available)
  (let ((path (namestring path)))
    (with-fs-req (req)
      (check (ffi:uv-fs-realpath (default-loop-pointer) req path (%null))
             :operation :real-path :path path)
      (cffi:foreign-string-to-lisp (ffi:uv-fs-get-ptr req)))))

(defun list-directory (path)
  "List PATH. Returns a list of (NAME . KIND), where KIND is :FILE, :DIRECTORY,
:SYMLINK, ... -- libuv reports the kind during the scan, so no extra stat is needed."
  (ensure-available)
  (let ((path (namestring path)))
    (with-fs-req (req)
      (let ((count (check (ffi:uv-fs-scandir (default-loop-pointer) req path 0 (%null))
                          :operation :list-directory :path path))
            (entries '()))
        (declare (ignorable count))
        (cffi:with-foreign-object (dirent '(:struct ffi::uv-dirent-t))
          ;; scandir_next returns UV_EOF when the listing is exhausted -- an expected
          ;; terminator, not a failure, so it must not go through CHECK.
          (loop for code = (ffi:uv-fs-scandir-next req dirent)
                until (minusp code)
                do (cffi:with-foreign-slots ((ffi::name ffi::kind) dirent
                                             (:struct ffi::uv-dirent-t))
                     (push (cons ffi::name
                                 (if (< -1 ffi::kind (length ffi:+dirent-kinds+))
                                     (aref ffi:+dirent-kinds+ ffi::kind)
                                     :unknown))
                           entries))))
        (nreverse entries)))))


;;; ---------------------------------------------------------- asynchronous API
;;;
;;; An asynchronous whole-file read is four chained libuv operations (open, fstat, read,
;;; close), each completing on the loop thread. The state for the chain lives in a Lisp
;;; struct held in the registry, keyed by the request pointer -- never in the request's
;;; `data` field, because SBCL's GC moves Lisp objects and a pointer parked in foreign
;;; memory would go stale.
;;;
;;; Two invariants, both of which are easy to get wrong and impossible to debug later:
;;;
;;;   * EVERY request is freed exactly once. When libuv accepts an operation the
;;;     callback frees it; when libuv REJECTS one synchronously the callback never runs,
;;;     so the issuing code must free it instead. %ISSUE is the only place either
;;;     happens.
;;;   * A short read is normal. uv_fs_read may return fewer bytes than asked for, so the
;;;     read step re-issues from the new offset until the file is consumed.

(defstruct (fs-op (:constructor %make-fs-op))
  future operation path loop
  (fd nil) (size 0) (buffer nil) (octets nil) (filled 0) (step :open)
  on-success on-error)

(defun %settle (op value &key errorp)
  "Complete OP's future and run its callback. Both happen ON THE LOOP THREAD."
  (let ((future (fs-op-future op)))
    (if errorp
        (progn (fail-future future value)
               (when (fs-op-on-error op) (funcall (fs-op-on-error op) value)))
        (progn (fulfill future value)
               (when (fs-op-on-success op) (funcall (fs-op-on-success op) value))))))

(defun %free-op-buffer (op)
  (when (fs-op-buffer op)
    (cffi:foreign-free (fs-op-buffer op))
    (setf (fs-op-buffer op) nil)))

(defun %fail (op code)
  "Abandon OP with libuv error CODE, releasing anything it still holds."
  (%free-op-buffer op)
  (when (fs-op-fd op)
    ;; Close synchronously and best-effort: an error path must not leak a descriptor.
    (ignore-errors (%close-file (fs-op-fd op)))
    (setf (fs-op-fd op) nil))
  (%settle op
           (make-condition (uv-error-class (ffi:uv-err-name code))
                           :code code :name (ffi:uv-err-name code)
                           :message (ffi:uv-strerror code)
                           :operation (fs-op-operation op) :path (fs-op-path op))
           :errorp t))

(defun %issue (op callback function)
  "Allocate a request bound to OP, hand it to FUNCTION, and account for the outcome.

FUNCTION receives (req callback) and returns libuv's code. If that code is negative the
operation was rejected outright and no callback will ever fire, so the request is freed
and OP fails here; otherwise the request now belongs to the callback."
  (let ((req (%new-req op)))
    (let ((code (funcall function req callback)))
      (when (minusp code)
        (deregister req)
        (cffi:foreign-free req)
        (%fail op code))
      code)))

(defun %new-req (op)
  "Allocate a uv_fs_t and bind it to OP for the duration of one operation."
  (let ((req (cffi:foreign-alloc :char :count (ffi:uv-req-size ffi:+uv-fs+))))
    (register req op)
    req))

(defmacro with-completed-request ((op req) &body body)
  "Shared prologue/epilogue for every fs completion callback: find the owning op, run
BODY, then clean and free the request exactly once."
  `(with-callback-guard
     (let ((,op (lookup ,req)))
       (deregister ,req)
       (unwind-protect (when ,op ,@body)
         (ffi:uv-fs-req-cleanup ,req)
         (cffi:foreign-free ,req)))))

;;; --- reading -----------------------------------------------------------------

(cffi:defcallback %read-callback :void ((req :pointer))
  (with-completed-request (op req)
    (let ((result (ffi:uv-fs-get-result req))
          (pointer (loop-pointer (fs-op-loop op))))
      (if (minusp result)
          (%fail op result)
          (ecase (fs-op-step op)
            (:open
             (setf (fs-op-fd op) result
                   (fs-op-step op) :fstat)
             (%issue op (cffi:callback %read-callback)
                     (lambda (r cb) (ffi:uv-fs-fstat pointer r (fs-op-fd op) cb))))
            (:fstat
             (let ((size (file-info-size
                          (statbuf->file-info (ffi:uv-fs-get-statbuf req)))))
               (setf (fs-op-size op) size
                     (fs-op-filled op) 0
                     (fs-op-octets op) (make-array size :element-type '(unsigned-byte 8))
                     (fs-op-step op) :read
                     (fs-op-buffer op) (cffi:foreign-alloc :unsigned-char
                                                           :count (max size 1)))
               (%read-chunk op pointer)))
            (:read
             ;; A short read is legal, so accumulate and re-issue until the file is
             ;; consumed or the descriptor reports EOF with a zero-length read.
             (dotimes (i result)
               (setf (aref (fs-op-octets op) (+ (fs-op-filled op) i))
                     (cffi:mem-aref (fs-op-buffer op) :unsigned-char i)))
             (incf (fs-op-filled op) result)
             (if (or (zerop result) (>= (fs-op-filled op) (fs-op-size op)))
                 (progn
                   (%free-op-buffer op)
                   (setf (fs-op-step op) :close)
                   (%issue op (cffi:callback %read-callback)
                           (lambda (r cb) (ffi:uv-fs-close pointer r (fs-op-fd op) cb))))
                 (%read-chunk op pointer)))
            (:close
             (setf (fs-op-fd op) nil)
             (let ((octets (fs-op-octets op)))
               (%settle op (if (= (fs-op-filled op) (fs-op-size op))
                               octets
                               (subseq octets 0 (fs-op-filled op)))))))))))

(defun %read-chunk (op pointer)
  "Issue one read from the current offset into the op's buffer."
  (let ((remaining (- (fs-op-size op) (fs-op-filled op))))
    (cffi:with-foreign-object (bufs '(:struct ffi::uv-buf-t))
      (setf (cffi:foreign-slot-value bufs '(:struct ffi::uv-buf-t) 'ffi::base)
            (fs-op-buffer op)
            (cffi:foreign-slot-value bufs '(:struct ffi::uv-buf-t) 'ffi::len)
            remaining)
      (%issue op (cffi:callback %read-callback)
              (lambda (r cb)
                (ffi:uv-fs-read pointer r (fs-op-fd op) bufs 1 (fs-op-filled op) cb))))))

(defun read-file-async (loop path &key on-success on-error)
  "Begin reading PATH on LOOP. Returns a FUTURE immediately.

The answer arrives either by AWAIT, or through ON-SUCCESS / ON-ERROR, which are invoked
ON THE LOOP THREAD -- so they should hand work off rather than block."
  (ensure-available)
  (let* ((path (namestring path))
         (op (%make-fs-op :future (%make-future) :operation :read-file-async
                          :path path :loop loop :step :open
                          :on-success on-success :on-error on-error)))
    (%issue op (cffi:callback %read-callback)
            (lambda (r cb)
              (ffi:uv-fs-open (loop-pointer loop) r path ffi:o-rdonly 0 cb)))
    (fs-op-future op)))

;;; --- stat --------------------------------------------------------------------

(cffi:defcallback %stat-callback :void ((req :pointer))
  (with-completed-request (op req)
    (let ((result (ffi:uv-fs-get-result req)))
      (if (minusp result)
          (%fail op result)
          (%settle op (statbuf->file-info (ffi:uv-fs-get-statbuf req)))))))

(defun file-info-async (loop path &key on-success on-error)
  "Stat PATH on LOOP. Returns a FUTURE that yields a FILE-INFO."
  (ensure-available)
  (let* ((path (namestring path))
         (op (%make-fs-op :future (%make-future) :operation :file-info-async
                          :path path :loop loop :step :stat
                          :on-success on-success :on-error on-error)))
    (%issue op (cffi:callback %stat-callback)
            (lambda (r cb) (ffi:uv-fs-stat (loop-pointer loop) r path cb)))
    (fs-op-future op)))

;;; --- writing -----------------------------------------------------------------

(cffi:defcallback %write-callback :void ((req :pointer))
  (with-completed-request (op req)
    (let ((result (ffi:uv-fs-get-result req))
          (pointer (loop-pointer (fs-op-loop op))))
      (if (minusp result)
          (%fail op result)
          (ecase (fs-op-step op)
            (:open
             (let* ((size (fs-op-size op))
                    (chunk (cffi:foreign-alloc :unsigned-char :count (max size 1))))
               (dotimes (i size)
                 (setf (cffi:mem-aref chunk :unsigned-char i)
                       (aref (fs-op-octets op) i)))
               (setf (fs-op-fd op) result
                     (fs-op-buffer op) chunk
                     (fs-op-filled op) 0
                     (fs-op-step op) :write)
               (%write-chunk op pointer)))
            (:write
             (incf (fs-op-filled op) result)
             (if (>= (fs-op-filled op) (fs-op-size op))
                 (progn
                   (%free-op-buffer op)
                   (setf (fs-op-step op) :close)
                   (%issue op (cffi:callback %write-callback)
                           (lambda (r cb) (ffi:uv-fs-close pointer r (fs-op-fd op) cb))))
                 (%write-chunk op pointer)))
            (:close
             (setf (fs-op-fd op) nil)
             (%settle op (fs-op-size op))))))))

(defun %write-chunk (op pointer)
  "Issue one write of whatever remains, from the current offset."
  (let ((remaining (- (fs-op-size op) (fs-op-filled op))))
    (cffi:with-foreign-object (bufs '(:struct ffi::uv-buf-t))
      (setf (cffi:foreign-slot-value bufs '(:struct ffi::uv-buf-t) 'ffi::base)
            (cffi:inc-pointer (fs-op-buffer op) (fs-op-filled op))
            (cffi:foreign-slot-value bufs '(:struct ffi::uv-buf-t) 'ffi::len)
            remaining)
      (%issue op (cffi:callback %write-callback)
              (lambda (r cb)
                (ffi:uv-fs-write pointer r (fs-op-fd op) bufs 1 (fs-op-filled op) cb))))))

(defun write-file-async (loop path contents &key (external-format :utf-8)
                                                 on-success on-error)
  "Write CONTENTS to PATH on LOOP. Returns a FUTURE that yields the byte count.

Note the ordering guarantee this does NOT make: two concurrent writes to one path are
two independent chains and may interleave. Serialise them yourself if that matters."
  (ensure-available)
  (let* ((path (namestring path))
         (octets (if (stringp contents)
                     (encode-string contents external-format)
                     (coerce contents '(vector (unsigned-byte 8)))))
         (op (%make-fs-op :future (%make-future) :operation :write-file-async
                          :path path :loop loop :step :open
                          :size (length octets) :octets octets
                          :on-success on-success :on-error on-error)))
    (%issue op (cffi:callback %write-callback)
            (lambda (r cb)
              (ffi:uv-fs-open (loop-pointer loop) r path
                              (open-flags :output :supersede) #o644 cb)))
    (fs-op-future op)))
