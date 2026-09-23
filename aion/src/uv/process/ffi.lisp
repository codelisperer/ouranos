;;;; ffi.lisp --- the raw binding for uv_spawn and uv_signal_t.
;;;;
;;;; TWO HAND-WRITTEN STRUCTS, and why that is allowed here.
;;;;
;;;; The no-grovel rule (aion/uv/ffi) permits writing out a struct that libuv defines
;;;; ITSELF, and forbids guessing at the platform's. uv_process_options_t and
;;;; uv_stdio_container_t are libuv's own -- it invents them to normalise process
;;;; creation across three very different operating systems, which is precisely why their
;;;; shape is libuv's to keep stable. Contrast `struct addrinfo` in aion/uv/net, which is
;;;; the platform's and therefore had to be guarded at runtime.
;;;;
;;;; The one place the platform does leak in is uv_uid_t / uv_gid_t: libuv defines them as
;;;; `unsigned char` on Windows and as uid_t / gid_t (32-bit) everywhere else. Both are
;;;; written out. They are the last two fields, so a mistake there cannot shift anything
;;;; that matters -- but it would be wrong, so it is not left to chance.
;;;;
;;;; NO ACCESSOR EXISTS for uv_process_options_t (unlike uv_fs_t, which has a full set),
;;;; because it is an INPUT struct: we fill it in and hand it over, and libuv never hands
;;;; one back. That asymmetry is what makes hand-writing it low-risk in practice -- a
;;;; mistake produces a failed spawn with a bad argument, not a silent misread of memory
;;;; libuv owns.

(in-package #:aion/uv/process/ffi)

;;; ------------------------------------------------------------------- constants

;;; uv_process_flags. Only the portable and the useful are named; the rest of the
;;; UV_PROCESS_WINDOWS_* family can be added when something needs them.
(defconstant +uv-process-setuid+ 1)
(defconstant +uv-process-setgid+ 2)
(defconstant +uv-process-windows-verbatim-arguments+ 4)
(defconstant +uv-process-detached+ 8
  "Make the child a process-group leader, so it survives its parent and can be signalled
as a group. The only process-group semantics libuv exposes portably.")
(defconstant +uv-process-windows-hide+ 16)

;;; uv_stdio_flags. These compose: a pipe the CHILD reads from is
;;; CREATE_PIPE | READABLE_PIPE, and the direction words are from the CHILD's point of
;;; view, which is the single most confusing thing in this API.
(defconstant +uv-ignore+ 0)
(defconstant +uv-create-pipe+ 1)
(defconstant +uv-inherit-fd+ 2)
(defconstant +uv-inherit-stream+ 4)
(defconstant +uv-readable-pipe+ 16)
(defconstant +uv-writable-pipe+ 32)
(defconstant +uv-nonblock-pipe+ 64)

;;; --------------------------------------------------------------------- structs

(cffi:defcstruct uv-stdio-container-t
  (flags :int)
  ;; A union of `uv_stream_t* stream` and `int fd`. Declared as the wider member; the fd
  ;; case writes an int through the same slot pointer.
  (data :pointer))

(cffi:defcstruct uv-process-options-t
  (exit-cb :pointer)
  (file :pointer)
  (args :pointer)
  (env :pointer)
  (cwd :pointer)
  (flags :uint)
  (stdio-count :int)
  (stdio :pointer)
  #+windows (uid :unsigned-char)
  #+windows (gid :unsigned-char)
  #-windows (uid :uint32)
  #-windows (gid :uint32))

;;; ------------------------------------------------------------------- spawning

(cffi:defcfun ("uv_spawn" uv-spawn) :int
  (loop :pointer) (handle :pointer) (options :pointer))

;;; Signals a running child. uv_kill takes a bare pid instead, which is what reaches a
;;; process GROUP: on unix a negative pid means "the group", and that only means anything
;;; for a child spawned with UV_PROCESS_DETACHED.
(cffi:defcfun ("uv_process_kill" uv-process-kill) :int (handle :pointer) (signum :int))
(cffi:defcfun ("uv_kill" uv-kill) :int (pid :int) (signum :int))
(cffi:defcfun ("uv_process_get_pid" uv-process-get-pid) :int (handle :pointer))

;;; -------------------------------------------------------------------- signals
;;;
;;; uv_signal_t is a handle like any other: it belongs to a loop, fires on the loop
;;; thread, and holds the loop open while started -- which for a supervisor is exactly
;;; what you want and for a one-shot script is exactly what surprises you. Ask
;;; (uv:describe-loop l) when a process will not exit.

(cffi:defcfun ("uv_signal_init" uv-signal-init) :int (loop :pointer) (handle :pointer))
(cffi:defcfun ("uv_signal_start" uv-signal-start) :int
  (handle :pointer) (cb :pointer) (signum :int))
(cffi:defcfun ("uv_signal_start_oneshot" uv-signal-start-oneshot) :int
  (handle :pointer) (cb :pointer) (signum :int))
(cffi:defcfun ("uv_signal_stop" uv-signal-stop) :int (handle :pointer))
