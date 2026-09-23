;;;; watch.lisp --- filesystem watching, over libuv's fs_event handle.
;;;;
;;;; One API over inotify (Linux), FSEvents (macOS) and ReadDirectoryChangesW (Windows).
;;;; This is the surface #107 nominated as the first thing to prove, and deliberately so:
;;;; it is small, it exercises the whole callback path, and it replaces a poller rather
;;;; than a working event-driven design.
;;;;
;;;; WHAT LIBUV DOES NOT PROMISE, and no wrapper can add:
;;;;   * Event coalescing differs per platform. One editor save can arrive as one event
;;;;     or three (write, rename, chmod), because editors write differently -- some
;;;;     truncate in place, some write a temp file and rename over the target.
;;;;   * `recursive` is honoured on macOS and Windows only. On Linux, inotify itself is
;;;;     not recursive, so libuv reports events for the named directory alone. We report
;;;;     that limitation rather than silently walking the tree behind your back.
;;;;   * The filename may be NIL. Some backends only say "something under here changed".
;;;;
;;;; Any consumer that needs "the file settled" semantics -- a hot reloader, say -- must
;;;; debounce on top of this. That belongs to the consumer, because the right quiet
;;;; period depends on what it is watching.

(in-package #:aion/uv)

(defstruct (watcher (:constructor %make-watcher))
  pointer loop function path recursive)

;;; The boundary between the typed core and the shell. aion/uv/types decodes the
;;; bitmask (checked, pure, Coalton); this turns its strings into the keywords a CL
;;; caller expects. Exactly the shape hyperion/html has with hyperion/htmx: Coalton
;;; renders the value, the CL shell consumes it.
(defun file-event-keywords (mask)
  "Decode libuv's fs_event bitmask into a list of :RENAME and/or :CHANGE."
  (mapcar (lambda (name)
            (cond ((string= name "rename") :rename)
                  ((string= name "change") :change)
                  (t (intern (string-upcase name) :keyword))))
          (aion/uv/types:file-event-strings mask)))

(cffi:defcallback %fs-event-callback :void
    ((handle :pointer) (filename :string) (events :int) (status :int))
  (with-callback-guard
    (let ((watcher (lookup handle)))
      (when watcher
        (if (minusp status)
            ;; A watch can fail after it started -- the directory is removed, say.
            (note-callback-error
             (make-condition (uv-error-class (ffi:uv-err-name status))
                             :code status :name (ffi:uv-err-name status)
                             :message (ffi:uv-strerror status)
                             :operation :watch :path (watcher-path watcher)))
            (funcall (watcher-function watcher)
                     ;; The typed decoder in the Coalton layer turns libuv's bitmask
                     ;; into keywords -- see types.lisp. Decoding is pure, so it belongs
                     ;; on that side of the seam.
                     (file-event-keywords events)
                     filename
                     watcher))))))

(defun watch (loop path function &key recursive)
  "Watch PATH on LOOP, calling FUNCTION with (EVENTS FILENAME WATCHER) on each change.

EVENTS is a list of :RENAME and/or :CHANGE. FILENAME is the affected entry when the
platform reports one, otherwise NIL. FUNCTION runs ON THE LOOP THREAD.

RECURSIVE is honoured on macOS and Windows; on Linux libuv watches only the named
directory, so a recursive watch there needs one watcher per subdirectory."
  (ensure-available)
  (let* ((path (namestring path))
         (pointer (cffi:foreign-alloc :char
                                      :count (ffi:uv-handle-size ffi:+uv-fs-event+))))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (cffi:foreign-free pointer))))
      (check (ffi:uv-fs-event-init (loop-pointer loop) pointer)
             :operation :watch :path path))
    (let ((watcher (%make-watcher :pointer pointer :loop loop :function function
                                  :path path :recursive recursive)))
      (register pointer watcher)
      (push pointer (loop-owned loop))
      (handler-bind ((error (lambda (e) (declare (ignore e))
                              (deregister pointer)
                              (setf (loop-owned loop) (remove pointer (loop-owned loop)))
                              (cffi:foreign-free pointer))))
        (check (ffi:uv-fs-event-start pointer (cffi:callback %fs-event-callback) path
                                      (if recursive ffi:+uv-fs-event-recursive+ 0))
               :operation :watch :path path))
      watcher)))

(defun unwatch (watcher)
  "Stop delivering events for WATCHER. The handle stays alive and can be restarted by
WATCH; CLOSE-HANDLE is what disposes of it."
  (when (watcher-pointer watcher)
    (check (ffi:uv-fs-event-stop (watcher-pointer watcher)) :operation :unwatch))
  watcher)

(defmethod close-handle ((watcher watcher))
  (let ((pointer (watcher-pointer watcher)))
    (when pointer
      (ignore-errors (ffi:uv-fs-event-stop pointer))
      (setf (loop-owned (watcher-loop watcher))
            (remove pointer (loop-owned (watcher-loop watcher))))
      (close-pointer pointer)
      (setf (watcher-pointer watcher) nil))))
