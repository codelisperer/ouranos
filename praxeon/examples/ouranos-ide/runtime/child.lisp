;;;; child.lisp --- what the child SBCL loads to become a Coalton runtime server (#1218).
;;;;
;;;; This file is not compiled into the IDE's image. The client in client.lisp starts a second
;;;; SBCL with `--load` of this file. The child loads Coalton's `mine/runtime` system, which is
;;;; the evaluation server of `mine`, and calls its protocol server directly. It does not call
;;;; `mine/runtime/server-main:main`, because that function belongs to the `mine` binary: it
;;;; clears the "mine" system, and it sets the debugger hook that this file sets itself below.
;;;;
;;;; Standard output carries two lines the parent reads: a line starting with
;;;; "OURANOS-RUNTIME-READY", written here, and then the TCP port, written by
;;;; `mine/protocol/server:start-server`. Everything before those two lines is load output.

(require :asdf)

(in-package #:cl-user)

;;; `mine/runtime` declares a dependency on `coalton/xmath`, which needs the Quicklisp
;;; library `computable-reals`. No file of `mine/runtime` uses xmath; the dependency makes
;;; xmath available to code a user evaluates. When `computable-reals` is not installed, the
;;; dependency is removed from the system object in this image only, so the server still
;;; loads. The READY line says which case applied.
(defvar *xmath*
  (cond ((asdf:find-system "computable-reals" nil) "declared")
        (t (let ((system (asdf:find-system "mine/runtime")))
             (setf (asdf:component-sideway-dependencies system)
                   (remove "coalton/xmath" (asdf:component-sideway-dependencies system)
                           :test #'equal))
             "removed"))))

(asdf:load-system "mine/runtime")

;;; The parent holds the write end of this process's standard input and never writes to it.
;;; End of file there means the parent closed it or died, and the child exits. Without this,
;;; a child whose parent died before connecting would wait in `accept` with nobody to stop it.
(sb-thread:make-thread
 (lambda ()
   (let ((input (sb-ext:symbol-global-value '*standard-input*)))
     (loop :while (ignore-errors (read-line input nil nil))))
   (sb-ext:exit :code 0 :abort t))
 :name "ouranos-runtime-parent-watch")

;;; An unhandled error in a thread outside a request is reported and that thread is aborted,
;;; as `server-main:main` arranges for `mine`. Without it, `--non-interactive` would end the
;;; whole process on such an error.
(setf sb-ext:*invoke-debugger-hook* 'mine/protocol/server::report-unhandled-error)

(format t "~&OURANOS-RUNTIME-READY xmath=~A~%" *xmath*)
(finish-output)

(mine/protocol/server:start-server 0)

(sb-ext:exit :code 0 :abort t)
