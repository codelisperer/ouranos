;;;; packages.lisp --- aion/uv/process package definitions.
;;;;
;;;; The third sub-system, and the same three layers as its siblings:
;;;;
;;;;   aion/uv/process/ffi   -- uv_spawn, uv_process_kill, uv_signal_*. Raw.
;;;;   aion/uv/process/types -- the typed core, in Coalton. Pure. Decodes how a process
;;;;                            ENDED, which libuv reports as two numbers that must be
;;;;                            read together or not at all.
;;;;   aion/uv/process       -- the idiomatic CL face: spawn, stdio, kill, signals.
;;;;
;;;; ORCHESTRATION IS NOT HERE. Deciding what to run, in what order, and what to do when
;;;; it fails belongs to the consumer -- which is `cons`, at DAG position 2, and therefore
;;;; could not reach a binding that lived any further right. This is the binding only.
;;;;
;;;; It depends on aion/uv/net, and that dependency is the point rather than an accident:
;;;; a child's stdin, stdout and stderr are uv_pipe_t, which is a uv_stream_t, so they
;;;; arrive as ordinary CONNECTIONs with START-READING, WRITE-BYTES and the whole
;;;; backpressure apparatus already attached. Streaming a build's output while it runs is
;;;; then a property of the stream layer rather than something re-solved here.

(cl:defpackage #:aion/uv/process/ffi
  (:use #:cl)
  (:local-nicknames (#:uv-ffi #:aion/uv/ffi))
  (:documentation
   "Raw CFFI bindings to libuv's process and signal surface.

Two of libuv's OWN structs are hand-written here -- uv_process_options_t and
uv_stdio_container_t -- which is allowed on the same terms as uv_buf_t: they are
libuv's, not the platform's, so their shape is libuv's to keep stable. The one place
the platform leaks in is uv_uid_t/uv_gid_t, which libuv defines as unsigned char on
Windows and uid_t/gid_t elsewhere; both are written out.")
  (:export
   ;; spawning
   #:uv-spawn #:uv-process-kill #:uv-kill #:uv-process-get-pid
   #:uv-process-options-t #:uv-stdio-container-t
   ;; process flags
   #:+uv-process-setuid+ #:+uv-process-setgid+ #:+uv-process-detached+
   #:+uv-process-windows-hide+ #:+uv-process-windows-verbatim-arguments+
   ;; stdio flags
   #:+uv-ignore+ #:+uv-create-pipe+ #:+uv-inherit-fd+ #:+uv-inherit-stream+
   #:+uv-readable-pipe+ #:+uv-writable-pipe+ #:+uv-nonblock-pipe+
   ;; signals
   #:uv-signal-init #:uv-signal-start #:uv-signal-start-oneshot #:uv-signal-stop))

(cl:defpackage #:aion/uv/process/types
  (:use #:coalton #:coalton-prelude)
  (:documentation
   "The typed core of aion/uv/process, in Coalton. Pure.

libuv reports how a child ended as TWO numbers -- an exit status and a terminating
signal -- and reading either alone is wrong. A process killed by SIGKILL has an exit
status of 0, so code that checks only the status concludes it succeeded. That is the
same shape of bug as treating end-of-stream as a failure in aion/uv/net, and it gets
the same treatment: one ADT in which the two cases cannot be confused.")
  (:export
   #:Termination #:Exited #:Killed
   #:decode-termination #:termination->string #:termination-tag #:terminated-well?
   #:signal-number #:signal-name))

(cl:defpackage #:aion/uv/process
  (:use #:cl)
  (:local-nicknames (#:ffi #:aion/uv/process/ffi)
                    (#:uv-ffi #:aion/uv/ffi)
                    (#:uv #:aion/uv)
                    (#:net #:aion/uv/net)
                    (#:types #:aion/uv/process/types))
  (:documentation
   "Subprocesses and signals for Common Lisp, over libuv.

The child's stdio is the stream layer's, not a second implementation: STDIN, STDOUT and
STDERR are aion/uv/net CONNECTIONs, so a consumer streams a build's output as it is
produced -- with backpressure -- rather than receiving it in a lump when the process
exits, which is what uiop:run-program gives you today.

HOW A PROCESS ENDED IS ONE VALUE, NOT TWO. A child killed by a signal reports exit
status 0, so EXIT-STATUS alone is not the answer; TERMINATION carries the distinction and
SUCCEEDED-P consults both.

Windows is where this API diverges most across platforms -- process creation there is
genuinely a different model, and the honest position is that nothing here has been run on
it. See aion/docs/uv-process-design.md.")
  (:export
   ;; spawning
   #:process #:process-p #:spawn #:process-pid #:process-stdin #:process-stdout
   #:process-stderr #:process-exit-future #:process-running-p
   ;; how it ended
   #:termination #:exit-status #:term-signal #:succeeded-p #:await-exit
   ;; control
   #:kill #:kill-pid #:close-process
   ;; signals
   #:signal-watcher #:signal-watcher-p #:watch-signal #:unwatch-signal
   ;; conditions
   #:spawn-failed))
