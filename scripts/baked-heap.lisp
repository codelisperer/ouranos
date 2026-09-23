;;;; baked-heap.lisp --- what heap was this binary born with? (pre-publication issue 88)
;;;;
;;;;     sbcl --script scripts/baked-heap.lisp bin/cons dist/*/coalton-repl
;;;;
;;;; SAVE-LISP-AND-DIE HAS NO HEAP PARAMETER. A dumped image inherits the heap of the
;;;; process that dumped it, and `:save-runtime-options t' -- which every executable in this
;;;; tree uses, because without it the binary parses SBCL's runtime flags instead of passing
;;;; them to the program -- then freezes that choice: the binary cannot be given a different
;;;; heap afterwards, because `bin/cons --dynamic-space-size 4096' is read as a `cons'
;;;; argument.
;;;;
;;;; So the heap a shipped artifact has is decided by how the machine that built it happened
;;;; to invoke SBCL, permanently, and nothing about the artifact announces it. That is not a
;;;; hypothetical: bootstrapping without the documented flag produced a working `bin/cons'
;;;; with a quarter of the intended headroom, and the only symptom was a memory ceiling
;;;; arriving much later, far from the cause.
;;;;
;;;; This exists so that question has an answer. It applies to `bin/cons' and equally to the
;;;; desktop bundles, which `scripts/build-desktop-app.lisp' dumps the same way -- a shipped
;;;; app carries whatever heap CI was invoked with.
;;;;
;;;; HOW IT READS IT. SBCL stores the saved runtime options in the core, introduced by
;;;; RUNTIME_OPTIONS_MAGIC (#x31EBF355) as a little-endian machine word; the dynamic-space
;;;; size is the word 16 bytes past the magic. Searching for the magic rather than seeking a
;;;; fixed offset is what makes this work on any image regardless of its size -- the offset
;;;; differs between a 39 MB probe and a 47 MB `cons'.
;;;;
;;;; Verified before it was trusted: two probe images dumped at known heaps (1024 MB and
;;;; 4096 MB) read back as 1024 and 4096.

(defconstant +runtime-options-magic+ #x31EBF355)
(defconstant +word-size+ 8)

(defun %read-word (bytes offset)
  "The little-endian 64-bit word at OFFSET."
  (loop for i from 0 below +word-size+
        sum (ash (aref bytes (+ offset i)) (* 8 i))))

(defun %find-magic (bytes)
  "The offset of RUNTIME_OPTIONS_MAGIC, or NIL if this image saved no runtime options."
  (loop for i from 0 to (- (length bytes) (* 3 +word-size+))
        when (= (%read-word bytes i) +runtime-options-magic+)
          return i))

(defun baked-heap-bytes (path)
  "The dynamic-space size frozen into the executable at PATH, or NIL.

NIL means the image was dumped WITHOUT :save-runtime-options, in which case it takes its
heap from the command line at run time like any other SBCL -- which is a different and
perfectly fine arrangement, just not the one this tree's executables use."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence bytes in)
      (let ((at (%find-magic bytes)))
        (when at
          (%read-word bytes (+ at (* 2 +word-size+))))))))

(let ((paths (rest sb-ext:*posix-argv*))
      (problems 0))
  (when (null paths)
    (format t "~&usage: sbcl --script scripts/baked-heap.lisp <executable>...~%")
    (sb-ext:quit :unix-status 2))
  (dolist (path paths)
    (cond
      ((not (probe-file path))
       (format t "~&  ~40A  no such file~%" path)
       (incf problems))
      (t
       (let ((size (baked-heap-bytes path)))
         (if size
             (format t "~&  ~40A  ~D MB~%" path (round size (* 1024 1024)))
             (format t "~&  ~40A  no saved runtime options (heap is chosen at run time)~%"
                     path))))))
  (sb-ext:quit :unix-status (if (plusp problems) 1 0)))
