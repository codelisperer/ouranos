;;;; app.lisp --- the clean-room probe for a bundled native library (ADR-0013).
;;;;
;;;; This exists to be DUMPED and then RUN ON A MACHINE THAT HAS NEVER SEEN THIS REPO:
;;;;
;;;;     sbcl --script scripts/build-libuv.lisp
;;;;     sbcl --dynamic-space-size 4096 --script scripts/build-desktop-app.lisp \
;;;;          --system aion/examples/uv-probe --entry aion/examples/uv-probe:main \
;;;;          --name uv-probe --version 0.0.0
;;;;     scripts/verify-bundle.sh dist/uv-probe-0.0.0-linux-x86-64
;;;;
;;;; A desktop app is the wrong subject for that test: it wants a window, a display and the
;;;; whole WebKitGTK stack, none of which is what ADR-0013 decides. This probe wants exactly
;;;; one thing -- a libuv that is not installed on the machine -- so when it fails, the
;;;; native-dependency question is the only thing that can have failed.
;;;;
;;;; It exercises the boundary rather than merely touching it: resolve the library, check the
;;;; ABI, then run a real event loop with a timer callback and a filesystem round trip. A
;;;; wrongly carried or wrongly resolved library dies at the first of those; a mismatched one
;;;; dies at the second.

(defpackage #:aion/examples/uv-probe
  (:use #:cl)
  (:local-nicknames (#:uv #:aion/uv)
                    (#:ffi #:aion/uv/ffi))
  (:export #:main))

(in-package #:aion/examples/uv-probe)

(defun report (label value)
  (format t "~&~A: ~A~%" label value)
  (finish-output))

(defun probe ()
  "Every step prints, so a failure names itself in the log rather than in a backtrace."
  (report "libuv-version" (uv:version))
  (report "libuv-path" (or ffi:*libuv-path* "(none)"))
  (report "abi" (if (ffi:verify-abi) "ok" "MISMATCH"))

  ;; A timer proves the loop actually runs and calls back into Lisp -- the part that would
  ;; still be broken if we had carried a library that merely loads.
  (let ((fired 0))
    (uv:with-loop (l)
      (let ((timer (uv:make-timer l (lambda (tm) (declare (ignore tm)) (incf fired)))))
        (uv:start-timer timer :after 5)
        (uv:run l :mode :default)
        (uv:close-handle timer)))
    (report "timer-fired" fired)
    (unless (= 1 fired)
      (error "the event loop did not run the timer callback")))

  ;; A filesystem round trip through libuv's own fs calls, not CL's.
  (let ((path (format nil "/tmp/uv-probe-~D.txt" (get-universal-time))))
    (uv:write-file path "hello from a bundled libuv")
    (let ((back (uv:read-file path :as :string)))
      (report "fs-roundtrip" back)
      (uv:delete-file* path)
      (unless (string= back "hello from a bundled libuv")
        (error "filesystem round trip returned ~S" back))))
  t)

(defun main ()
  (handler-case
      (progn (probe)
             (report "probe" "PASS")
             (uiop:quit 0))
    (error (e)
      (format t "~&probe: FAIL~%~A~%" e)
      (finish-output)
      (uiop:quit 1))))
