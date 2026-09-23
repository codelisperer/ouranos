;;;; ffi.lisp --- the raw libuv binding. One Lisp function per C function.
;;;;
;;;; No interpretation happens here: return codes come back as the negative integers
;;;; libuv produced, buffers as foreign pointers, structs as CFFI structs. Everything
;;;; friendly lives above, in aion/uv.
;;;;
;;;; ON NOT GROVELLING (the load-bearing design decision):
;;;;
;;;; The usual way to bind a C library is to run a C compiler at build time to learn
;;;; struct sizes and offsets (cffi-grovel). We do not, because that would put a C
;;;; toolchain on the LOAD path of a system that six frameworks may depend on. Instead:
;;;;
;;;;   * SIZES come from libuv itself at runtime -- uv_loop_size(), uv_handle_size(type),
;;;;     uv_req_size(type). libuv exports these functions precisely so that bindings in
;;;;     other languages need not know its layouts. We allocate by asking.
;;;;   * LAYOUTS are only written out for the few structs libuv defines ITSELF rather
;;;;     than inheriting from the platform (uv_buf_t, uv_stat_t, uv_dirent_t). uv_stat_t
;;;;     in particular is libuv's own normalisation of stat(2) -- twelve uint64_t and four
;;;;     uv_timespec_t on every platform -- which is exactly why it is safe to hand-write
;;;;     and would not be if it were the OS's struct stat.
;;;;   * ENUM VALUES are hardcoded (they are ABI, appended to but never reordered) and
;;;;     then VERIFIED at load time against uv_handle_type_name/uv_req_type_name. If
;;;;     upstream ever does reorder, we fail loudly at load instead of silently sizing a
;;;;     handle wrong, which is the failure mode that would otherwise corrupt memory.
;;;;
;;;; MEMORY RULE, absolute: whatever WE allocate, we free; whatever LIBUV allocates, its
;;;; own cleanup frees (uv_fs_req_cleanup, uv_freeaddrinfo). Nothing is ever freed across
;;;; that boundary. On Windows a mingw-built libuv and SBCL may not share a C runtime, so
;;;; a cross-boundary free is not a leak but a crash.

(in-package #:aion/uv/ffi)

(cffi:define-foreign-library libuv
  (t (:default "libuv")))

;;; ---------------------------------------------------------------- base types

;;; ssize_t: pointer-sized and signed. On Win64 `long` is 32 bits, so :long is wrong there.
(cffi:defctype ssize #+windows :int64 #-windows :long)
(cffi:defctype uv-file :int)

;;; uv_buf_t is one of libuv's own structs, but its FIELD ORDER differs by platform --
;;; on Windows it mirrors WSABUF (length first) so it can be passed straight to WSARecv.
(cffi:defcstruct (uv-buf-t :class uv-buf-type)
  #+windows (len :ulong)
  #+windows (base :pointer)
  #-windows (base :pointer)
  #-windows (len :size))

(cffi:defcstruct uv-timespec-t
  (tv-sec :long)
  (tv-nsec :long))

;;; libuv's OWN stat, identical on every platform -- not the OS struct stat.
(cffi:defcstruct uv-stat-t
  (st-dev :uint64)
  (st-mode :uint64)
  (st-nlink :uint64)
  (st-uid :uint64)
  (st-gid :uint64)
  (st-rdev :uint64)
  (st-ino :uint64)
  (st-size :uint64)
  (st-blksize :uint64)
  (st-blocks :uint64)
  (st-flags :uint64)
  (st-gen :uint64)
  (st-atim (:struct uv-timespec-t))
  (st-mtim (:struct uv-timespec-t))
  (st-ctim (:struct uv-timespec-t))
  (st-birthtim (:struct uv-timespec-t)))

;;; The C field is `type`; called `kind` here so the slot symbol is not CL:TYPE, which
;;; would read confusingly at every use site.
(cffi:defcstruct uv-dirent-t
  (name :string)
  (kind :int))

;;; ------------------------------------------------------------------ constants

;;; uv_run_mode
(defconstant +uv-run-default+ 0)
(defconstant +uv-run-once+ 1)
(defconstant +uv-run-nowait+ 2)

;;; uv_fs_event enum: the bitmask delivered to an fs_event callback.
(defconstant +uv-rename+ 1)
(defconstant +uv-change+ 2)

;;; uv_fs_event_flags, passed to uv_fs_event_start.
(defconstant +uv-fs-event-watch-entry+ 1)
(defconstant +uv-fs-event-stat+ 2)
(defconstant +uv-fs-event-recursive+ 4)

;;; uv_handle_type. UV_UNKNOWN_HANDLE = 0, then UV_HANDLE_TYPE_MAP in order, then UV_FILE.
;;; Verified at load time by %verify-enums below -- do not reorder by hand.
(defconstant +uv-async+ 1)
(defconstant +uv-check+ 2)
(defconstant +uv-fs-event+ 3)
(defconstant +uv-fs-poll+ 4)
(defconstant +uv-handle+ 5)
(defconstant +uv-idle+ 6)
(defconstant +uv-named-pipe+ 7)
(defconstant +uv-poll+ 8)
(defconstant +uv-prepare+ 9)
(defconstant +uv-process+ 10)
(defconstant +uv-stream+ 11)
(defconstant +uv-tcp+ 12)
(defconstant +uv-timer+ 13)
(defconstant +uv-tty+ 14)
(defconstant +uv-udp+ 15)
(defconstant +uv-signal+ 16)
(defconstant +uv-file+ 17)

;;; uv_req_type. UV_UNKNOWN_REQ = 0, then UV_REQ_TYPE_MAP in order.
(defconstant +uv-req+ 1)
(defconstant +uv-connect+ 2)
(defconstant +uv-write+ 3)
(defconstant +uv-shutdown+ 4)
(defconstant +uv-udp-send+ 5)
(defconstant +uv-fs+ 6)
(defconstant +uv-work+ 7)
(defconstant +uv-getaddrinfo+ 8)
(defconstant +uv-getnameinfo+ 9)
(defconstant +uv-random+ 10)

(defparameter +dirent-kinds+
  #(:unknown :file :directory :symlink :fifo :socket :character-device :block-device)
  "uv_dirent_type_t, by ordinal.")

;;; Open flags. UV_FS_O_* expand to the PLATFORM's O_* values, so they are the one
;;; constant set that genuinely varies -- and the one thing a groveller would earn its
;;; keep on. SBCL already groveled them when it was built, so we ask sb-posix and fall
;;; back to the documented Windows _O_* values (SBCL's Windows sb-posix is thinner).
(eval-when (:compile-toplevel :load-toplevel :execute)
  (ignore-errors (require :sb-posix)))

(defun %posix-flag (name fallback)
  (let ((symbol (find-symbol (string name) "SB-POSIX")))
    (if (and symbol (boundp symbol)) (symbol-value symbol) fallback)))

(defparameter o-rdonly (%posix-flag '#:o-rdonly 0))
(defparameter o-wronly (%posix-flag '#:o-wronly 1))
(defparameter o-rdwr   (%posix-flag '#:o-rdwr 2))
(defparameter o-creat  (%posix-flag '#:o-creat #+windows 256 #-windows 64))
(defparameter o-trunc  (%posix-flag '#:o-trunc #+windows 512 #-windows 512))
(defparameter o-append (%posix-flag '#:o-append #+windows 8 #-windows 1024))
(defparameter o-excl   (%posix-flag '#:o-excl #+windows 1024 #-windows 128))

;;; ------------------------------------------------------------------- version

(cffi:defcfun ("uv_version" uv-version) :uint)
(cffi:defcfun ("uv_version_string" uv-version-string) :string)
(cffi:defcfun ("uv_handle_type_name" uv-handle-type-name) :string (type :int))
(cffi:defcfun ("uv_req_type_name" uv-req-type-name) :string (type :int))

;;; --------------------------------------------------------------------- sizes

(cffi:defcfun ("uv_loop_size" uv-loop-size) :size)
(cffi:defcfun ("uv_handle_size" uv-handle-size) :size (type :int))
(cffi:defcfun ("uv_req_size" uv-req-size) :size (type :int))

;;; -------------------------------------------------------------------- errors

(cffi:defcfun ("uv_strerror" uv-strerror) :string (err :int))
(cffi:defcfun ("uv_err_name" uv-err-name) :string (err :int))

;;; ---------------------------------------------------------------------- loop

(cffi:defcfun ("uv_default_loop" uv-default-loop) :pointer)
(cffi:defcfun ("uv_loop_init" uv-loop-init) :int (loop :pointer))
(cffi:defcfun ("uv_loop_close" uv-loop-close) :int (loop :pointer))
(cffi:defcfun ("uv_loop_alive" uv-loop-alive) :int (loop :pointer))
(cffi:defcfun ("uv_run" uv-run) :int (loop :pointer) (mode :int))
(cffi:defcfun ("uv_stop" uv-stop) :void (loop :pointer))
(cffi:defcfun ("uv_now" uv-now) :uint64 (loop :pointer))
(cffi:defcfun ("uv_hrtime" uv-hrtime) :uint64)

;;; ------------------------------------------------------------------- handles

(cffi:defcfun ("uv_close" uv-close) :void (handle :pointer) (close-cb :pointer))
(cffi:defcfun ("uv_is_active" uv-is-active) :int (handle :pointer))
(cffi:defcfun ("uv_is_closing" uv-is-closing) :int (handle :pointer))
(cffi:defcfun ("uv_ref" uv-ref) :void (handle :pointer))
(cffi:defcfun ("uv_unref" uv-unref) :void (handle :pointer))

;;; Introspection. uv_has_ref is the one that matters most: a REFERENCED handle keeps
;;; uv_run from returning, which is the entire content of "why will my process not
;;; exit?" -- the most common complaint about Node, and answerable here from a live
;;; REPL because we have one. See introspect.lisp.
(cffi:defcfun ("uv_has_ref" uv-has-ref) :int (handle :pointer))
(cffi:defcfun ("uv_handle_get_type" uv-handle-get-type) :int (handle :pointer))
(cffi:defcfun ("uv_walk" uv-walk) :void (loop :pointer) (cb :pointer) (arg :pointer))

;;; --------------------------------------------------------------------- async
;;;
;;; uv_async_send is the ONLY libuv function safe to call from a thread other than the
;;; one running the loop. Every cross-thread interaction in aion/uv funnels through it.

(cffi:defcfun ("uv_async_init" uv-async-init) :int
  (loop :pointer) (handle :pointer) (cb :pointer))
(cffi:defcfun ("uv_async_send" uv-async-send) :int (handle :pointer))

;;; -------------------------------------------------------------------- timers

(cffi:defcfun ("uv_timer_init" uv-timer-init) :int (loop :pointer) (handle :pointer))
(cffi:defcfun ("uv_timer_start" uv-timer-start) :int
  (handle :pointer) (cb :pointer) (timeout :uint64) (repeat :uint64))
(cffi:defcfun ("uv_timer_stop" uv-timer-stop) :int (handle :pointer))
(cffi:defcfun ("uv_timer_again" uv-timer-again) :int (handle :pointer))
(cffi:defcfun ("uv_timer_set_repeat" uv-timer-set-repeat) :void
  (handle :pointer) (repeat :uint64))
(cffi:defcfun ("uv_timer_get_repeat" uv-timer-get-repeat) :uint64 (handle :pointer))

;;; ------------------------------------------------------------------------ fs
;;;
;;; Every uv_fs_* call takes a callback as its last argument. Pass a null pointer and
;;; libuv runs the operation INLINE on the calling thread and returns the result
;;; directly; pass a real callback and it goes to the threadpool, with completion
;;; delivered on the loop thread. That is the whole sync/async split, and it is libuv's,
;;; not something we emulate.

(cffi:defcfun ("uv_fs_req_cleanup" uv-fs-req-cleanup) :void (req :pointer))
(cffi:defcfun ("uv_fs_get_result" uv-fs-get-result) ssize (req :pointer))
(cffi:defcfun ("uv_fs_get_system_error" uv-fs-get-system-error) :int (req :pointer))
(cffi:defcfun ("uv_fs_get_ptr" uv-fs-get-ptr) :pointer (req :pointer))
(cffi:defcfun ("uv_fs_get_path" uv-fs-get-path) :string (req :pointer))
(cffi:defcfun ("uv_fs_get_statbuf" uv-fs-get-statbuf) :pointer (req :pointer))
(cffi:defcfun ("uv_fs_get_type" uv-fs-get-type) :int (req :pointer))

(cffi:defcfun ("uv_fs_open" uv-fs-open) :int
  (loop :pointer) (req :pointer) (path :string) (flags :int) (mode :int) (cb :pointer))
(cffi:defcfun ("uv_fs_close" uv-fs-close) :int
  (loop :pointer) (req :pointer) (file uv-file) (cb :pointer))
(cffi:defcfun ("uv_fs_read" uv-fs-read) :int
  (loop :pointer) (req :pointer) (file uv-file) (bufs :pointer) (nbufs :uint)
  (offset :int64) (cb :pointer))
(cffi:defcfun ("uv_fs_write" uv-fs-write) :int
  (loop :pointer) (req :pointer) (file uv-file) (bufs :pointer) (nbufs :uint)
  (offset :int64) (cb :pointer))
(cffi:defcfun ("uv_fs_unlink" uv-fs-unlink) :int
  (loop :pointer) (req :pointer) (path :string) (cb :pointer))
(cffi:defcfun ("uv_fs_mkdir" uv-fs-mkdir) :int
  (loop :pointer) (req :pointer) (path :string) (mode :int) (cb :pointer))
(cffi:defcfun ("uv_fs_rmdir" uv-fs-rmdir) :int
  (loop :pointer) (req :pointer) (path :string) (cb :pointer))
(cffi:defcfun ("uv_fs_rename" uv-fs-rename) :int
  (loop :pointer) (req :pointer) (path :string) (new-path :string) (cb :pointer))
(cffi:defcfun ("uv_fs_stat" uv-fs-stat) :int
  (loop :pointer) (req :pointer) (path :string) (cb :pointer))
(cffi:defcfun ("uv_fs_fstat" uv-fs-fstat) :int
  (loop :pointer) (req :pointer) (file uv-file) (cb :pointer))
(cffi:defcfun ("uv_fs_lstat" uv-fs-lstat) :int
  (loop :pointer) (req :pointer) (path :string) (cb :pointer))
(cffi:defcfun ("uv_fs_realpath" uv-fs-realpath) :int
  (loop :pointer) (req :pointer) (path :string) (cb :pointer))
(cffi:defcfun ("uv_fs_scandir" uv-fs-scandir) :int
  (loop :pointer) (req :pointer) (path :string) (flags :int) (cb :pointer))
(cffi:defcfun ("uv_fs_scandir_next" uv-fs-scandir-next) :int (req :pointer) (ent :pointer))

;;; ----------------------------------------------------------------- fs events

(cffi:defcfun ("uv_fs_event_init" uv-fs-event-init) :int
  (loop :pointer) (handle :pointer))
(cffi:defcfun ("uv_fs_event_start" uv-fs-event-start) :int
  (handle :pointer) (cb :pointer) (path :string) (flags :uint))
(cffi:defcfun ("uv_fs_event_stop" uv-fs-event-stop) :int (handle :pointer))
(cffi:defcfun ("uv_fs_event_getpath" uv-fs-event-getpath) :int
  (handle :pointer) (buffer :pointer) (size :pointer))

;;; ------------------------------------------------------- load-time verification

(defparameter +handle-type-checks+
  `((,+uv-async+ . "async") (,+uv-check+ . "check") (,+uv-fs-event+ . "fs_event")
    (,+uv-fs-poll+ . "fs_poll") (,+uv-idle+ . "idle") (,+uv-named-pipe+ . "pipe")
    (,+uv-poll+ . "poll") (,+uv-prepare+ . "prepare") (,+uv-process+ . "process")
    (,+uv-tcp+ . "tcp") (,+uv-timer+ . "timer") (,+uv-tty+ . "tty")
    (,+uv-udp+ . "udp") (,+uv-signal+ . "signal"))
  "Each hardcoded handle-type constant and the name libuv should give it.")

(defparameter +req-type-checks+
  `((,+uv-connect+ . "connect") (,+uv-write+ . "write") (,+uv-shutdown+ . "shutdown")
    (,+uv-udp-send+ . "udp_send") (,+uv-fs+ . "fs") (,+uv-work+ . "work")
    (,+uv-getaddrinfo+ . "getaddrinfo") (,+uv-getnameinfo+ . "getnameinfo"))
  "Likewise for request types.")

(define-condition libuv-abi-mismatch (error)
  ((details :initarg :details :reader libuv-abi-mismatch-details))
  (:report (lambda (c stream)
             (format stream "The loaded libuv does not match this binding's assumptions:~%")
             (dolist (d (libuv-abi-mismatch-details c))
               (format stream "  ~A~%" d))
             ;; One long control string on purpose: a ~<newline> continuation becomes an
             ;; illegal ~<Return> directive on a CRLF checkout (see CLAUDE.md).
             (format stream "~%This binding hardcodes libuv's enum ordering. Upstream appears to have changed it, so the constants in ffi.lisp must be re-derived from uv.h before aion/uv can be used against this library.~%")))
  (:documentation
   "Signalled when the loaded libuv disagrees with our hardcoded enum values.
Better a loud failure at load than a handle allocated at the wrong size."))

(defun verify-abi ()
  "Prove the hardcoded enum constants match the loaded library. Signals on mismatch.

This is what makes hand-written constants safe rather than merely convenient: libuv
tells us the name of each type, so we can check our numbering against the real
library instead of trusting that a header we read once still describes it."
  (let ((problems '()))
    (loop for (value . expected) in +handle-type-checks+
          for actual = (uv-handle-type-name value)
          unless (and actual (string-equal actual expected))
            do (push (format nil "handle type ~D: expected ~S, libuv says ~S"
                             value expected actual)
                     problems))
    (loop for (value . expected) in +req-type-checks+
          for actual = (uv-req-type-name value)
          unless (and actual (string-equal actual expected))
            do (push (format nil "request type ~D: expected ~S, libuv says ~S"
                             value expected actual)
                     problems))
    ;; A handle must be at least as big as the base handle, and nothing sane is huge.
    (let ((timer-size (uv-handle-size +uv-timer+))
          (loop-size (uv-loop-size)))
      (unless (and (plusp timer-size) (< timer-size 4096))
        (push (format nil "uv_handle_size(UV_TIMER) = ~D, which is not credible"
                      timer-size)
              problems))
      (unless (and (plusp loop-size) (< loop-size 65536))
        (push (format nil "uv_loop_size() = ~D, which is not credible" loop-size)
              problems)))
    (when problems
      (error 'libuv-abi-mismatch :details (nreverse problems)))
    t))
