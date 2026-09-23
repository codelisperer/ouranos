;;;; packages.lisp --- aion/uv package definitions.
;;;;
;;;; Two packages, one seam:
;;;;
;;;;   aion/uv/ffi -- the raw binding. One Lisp function per C function, named after it
;;;;                  (uv_fs_open -> uv-fs-open), no interpretation, no conveniences.
;;;;                  Nothing above this layer should ever see a foreign pointer it did
;;;;                  not get from here.
;;;;   aion/uv     -- the idiomatic CL face: loops, conditions, sync + async operations,
;;;;                  keyword arguments, RAII-style macros.
;;;;
;;;; The typed Coalton layer lives in aion/uv/types (see types.lisp) and is pure -- it
;;;; decodes integers into ADTs and nothing else. No IO in Coalton, per the house rule.

(cl:defpackage #:aion/uv/ffi
  (:use #:cl)
  (:documentation
   "Raw CFFI bindings to libuv. Mechanical, one-to-one with the C API.

Deliberately grovel-free: struct SIZES come from libuv's own accessor functions
(uv_loop_size, uv_handle_size, uv_req_size) rather than from a C compiler run at
build time, so this system needs no toolchain to LOAD -- only to build the shim.
The handful of struct LAYOUTS defined here (uv_buf_t, uv_stat_t, uv_dirent_t) are
libuv's own portable structs, not the platform's, which is what makes hand-writing
them safe.")
  (:export
   ;; library management
   #:load-libuv #:unload-libuv #:libuv-loaded-p #:libuv-not-found #:*libuv-path*
   ;; The sonames a shipped bundle must present. EXPORTED because the bundler has to
   ;; agree with them: it copies a library in under a name, and this is the list of
   ;; names anything looking for it will ask for (pre-publication issue 329). It was reachable only by
   ;; FIND-SYMBOL, which is a workaround for a missing export, not a boundary.
   #:*library-names*
   #:verify-abi #:libuv-abi-mismatch
   ;; version + introspection
   #:uv-version #:uv-version-string #:uv-handle-type-name #:uv-req-type-name
   #:uv-handle-size #:uv-req-size #:uv-loop-size
   ;; errors
   #:uv-strerror #:uv-err-name
   ;; loop
   #:uv-default-loop #:uv-loop-init #:uv-loop-close #:uv-loop-alive
   #:uv-run #:uv-stop #:uv-now #:uv-hrtime
   ;; handles
   #:uv-close #:uv-is-active #:uv-is-closing #:uv-ref #:uv-unref
   #:uv-has-ref #:uv-handle-get-type #:uv-walk
   ;; async
   #:uv-async-init #:uv-async-send
   ;; timers
   #:uv-timer-init #:uv-timer-start #:uv-timer-stop #:uv-timer-again
   #:uv-timer-set-repeat #:uv-timer-get-repeat
   ;; fs
   #:uv-fs-req-cleanup #:uv-fs-get-result #:uv-fs-get-ptr #:uv-fs-get-path
   #:uv-fs-get-statbuf #:uv-fs-get-type #:uv-fs-get-system-error
   #:uv-fs-open #:uv-fs-close #:uv-fs-read #:uv-fs-write
   #:uv-fs-unlink #:uv-fs-mkdir #:uv-fs-rmdir #:uv-fs-rename
   #:uv-fs-stat #:uv-fs-fstat #:uv-fs-lstat #:uv-fs-realpath
   #:uv-fs-scandir #:uv-fs-scandir-next
   ;; fs events
   #:uv-fs-event-init #:uv-fs-event-start #:uv-fs-event-stop #:uv-fs-event-getpath
   ;; structs and base types
   #:uv-buf-t #:uv-stat-t #:uv-timespec-t #:uv-dirent-t #:ssize
   ;; constants
   #:+uv-run-default+ #:+uv-run-once+ #:+uv-run-nowait+
   #:+uv-rename+ #:+uv-change+
   #:+uv-fs-event-watch-entry+ #:+uv-fs-event-stat+ #:+uv-fs-event-recursive+
   #:+uv-timer+ #:+uv-async+ #:+uv-fs-event+ #:+uv-fs+
   ;; Handle and request types the sub-systems allocate against (aion/uv/net, and
   ;; aion/uv/process next). Exported rather than duplicated: the enum values are ABI
   ;; and are verified once, by VERIFY-ABI, for the whole binding.
   #:+uv-tcp+ #:+uv-named-pipe+ #:+uv-stream+ #:+uv-signal+ #:+uv-process+
   #:+uv-connect+ #:+uv-write+ #:+uv-shutdown+ #:+uv-getaddrinfo+
   #:o-rdonly #:o-wronly #:o-rdwr #:o-creat #:o-trunc #:o-append #:o-excl
   #:+dirent-kinds+))

(cl:defpackage #:aion/uv/types
  (:use #:coalton #:coalton-prelude)
  (:documentation
   "The typed core of aion/uv, in Coalton: what libuv's integers MEAN.

Pure by construction -- it decodes bitmasks and error names into ADTs and renders
them back, and performs no IO whatsoever. That is the house split: Coalton owns the
checked value, the CL shell owns the effects. It is also the honest place to put this
work, because decoding is exactly the part where a stray integer becomes a silent bug
and a type makes it unspellable.

Each ADT has a monomorphic CL-callable renderer beside it, per the pure-CL face
pattern in docs/coalton-patterns.md -- callers that never write Coalton still get the
benefit of the decoding having been checked.")
  (:export
   #:FileEvent #:Renamed #:Changed
   #:decode-file-events #:file-event->string #:file-event-strings
   #:UvErrorKind #:NotFound #:PermissionDenied #:AlreadyExists #:NotDirectory
   #:IsDirectory #:NotEmpty #:Interrupted #:WouldBlock #:TimedOut #:OtherError
   #:classify-error #:error-kind->string #:error-recoverable?
   #:classify-error-name #:error-name-recoverable?
   #:RunMode #:RunDefault #:RunOnce #:RunNoWait #:run-mode->code
   #:DirentKind #:EntryFile #:EntryDirectory #:EntrySymlink #:EntryFifo
   #:EntrySocket #:EntryCharDevice #:EntryBlockDevice #:EntryUnknown
   #:decode-dirent-kind #:dirent-kind->string))

(cl:defpackage #:aion/uv
  (:use #:cl)
  (:local-nicknames (#:ffi #:aion/uv/ffi))
  (:documentation
   "libuv for Common Lisp: an event loop, asynchronous and synchronous filesystem
operations, timers, and filesystem watching.

Two faces, as in Node -- but with the CL default inverted. Node makes async the
unsuffixed name because JavaScript has no threads and blocking would freeze the
world; SBCL has real threads, so blocking is an ordinary thing to do and the plain
name is the one most callers want:

  (uv:read-file \"/etc/hostname\")               ; synchronous. No loop, no setup.
  (uv:read-file-async loop \"/etc/hostname\")    ; returns a FUTURE; AWAIT or attach a callback.

The synchronous forms are not emulated -- libuv itself runs uv_fs_* inline on the
calling thread when no callback is supplied, touching no loop state, so they are
safe to call from any thread even while another thread runs a loop.")
  (:export
   ;; library
   #:version #:library-path #:ensure-available
   ;; conditions
   #:uv-error #:uv-error-code #:uv-error-name #:uv-error-message
   #:uv-error-operation #:uv-error-path
   #:file-not-found #:permission-denied #:file-exists #:not-a-directory
   #:is-a-directory #:directory-not-empty #:await-timeout #:loop-closed
   ;; loop
   #:event-loop #:make-loop #:close-loop #:with-loop #:run #:stop #:loop-alive-p
   #:start-loop-thread #:stop-loop-thread #:submit #:loop-thread-p
   ;; futures
   #:future #:await #:future-finished-p #:future-value #:future-error
   ;; synchronous fs
   #:read-file #:write-file #:file-info #:list-directory
   #:make-directory #:delete-file* #:delete-directory #:rename-path #:real-path
   ;; file-info accessors
   #:file-info-size #:file-info-kind #:file-info-mode #:file-info-mtime
   #:file-info-atime #:file-info-ctime #:file-info-inode #:file-info-nlink
   ;; asynchronous fs
   #:read-file-async #:write-file-async #:file-info-async
   ;; timers
   #:timer #:make-timer #:start-timer #:stop-timer #:close-handle
   ;; watching
   #:watcher #:watch #:unwatch #:watch-path
   ;; introspection -- what is alive, and what is holding the loop open
   #:handle-info #:handle-info-address #:handle-info-kind #:handle-info-active
   #:handle-info-closing #:handle-info-referenced #:handle-info-owner
   #:loop-handles #:describe-loop #:holds-loop-p
   ;; --- the sub-system substrate -------------------------------------------------
   ;;
   ;; Not for application code. These are the seam that lets aion/uv/net and
   ;; aion/uv/process add handle types WITHOUT duplicating the loop, the pointer
   ;; registry, the callback guard or the error decoding -- which the ECOSYSTEM
   ;; decisions log (2026-08-04, pre-publication issue 117) names as the reason granularity comes from
   ;; sub-systems rather than from splitting the binding across frameworks. A shared
   ;; substrate has to be nameable to be shared; this is that name.
   #:check #:signal-uv-error #:uv-error-class
   #:with-callback-guard #:note-callback-error #:*callback-errors*
   #:register #:deregister #:lookup #:close-pointer
   #:loop-pointer #:loop-owned #:make-future #:fulfill #:fail-future))
