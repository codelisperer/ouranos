;;;; server.lisp --- the benchmark subject: one Hyperion app, on any backend.
;;;;
;;;;     HYPERION_SERVER=hunchentoot sbcl --dynamic-space-size 4096 --script hyperion/bench/server.lisp 8099
;;;;     HYPERION_SERVER=woo         sbcl --dynamic-space-size 4096 --script hyperion/bench/server.lisp 8099
;;;;     HYPERION_SERVER=uv          sbcl --dynamic-space-size 4096 --script hyperion/bench/server.lisp 8099
;;;;
;;;; HYPERION_WORKERS, when set, is the worker count START gives the backend: :worker-num for
;;;; Woo, :workers for :uv, and nothing for Hunchentoot, which runs a thread per connection
;;;; (#413). Request logging is off on every backend, so a comparison measures the servers and
;;;; not the logger.
;;;;
;;;; Exists to settle one decision with numbers instead of reasoning: can Hunchentoot carry
;;;; a DESKTOP app's live-feed rendering, so desktop bundles can drop Woo -- and with it
;;;; libev, a CFFI load-time dependency that makes every Linux/macOS bundle fail on a clean
;;;; machine (issue #72). Woo is Unix-only, so this only compares on Linux/macOS.
;;;;
;;;; Endpoints, chosen to mirror what an HTMX live feed actually does:
;;;;   GET /tile    one server-rendered fragment (~1-2 KB) -- the polling case
;;;;   GET /board   40 fragments in one response -- the OOB fan-out case
;;;;   GET /ping    a few bytes -- isolates framing cost from rendering cost
;;;;   GET /cpu     CPU seconds used so far: "process=<s> loop=<s>", read by compare.py before
;;;;                and after each load run. loop= is the :uv loop thread's own CPU time, and
;;;;                "-" on other backends, which have no single loop thread to measure.
;;;;   GET /quit    stop the server (the harness uses it; keeps runs scriptable)

(require :asdf)

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-parent-directory-pathname
    (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*)))))

(asdf:initialize-source-registry
 `(:source-registry (:tree ,*root*) :inherit-configuration))
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (read-from-string "ql:quickload") :hyperion)

;;; hyperion.asd depends on no Clack handler (#373): an app declares the one it uses. So the
;;; benchmark loads the handler for the backend it was asked for, as an app would.
(let ((want (string-downcase (or (uiop:getenv "HYPERION_SERVER") ""))))
  (when (string= want "hunchentoot")
    (funcall (read-from-string "ql:quickload") :clack-handler-hunchentoot))
  (when (string= want "woo")
    (funcall (read-from-string "ql:quickload") :clack-handler-woo))
  ;; The native server is its own system, and needs a built vendor/libuv (#413).
  (when (string= want "uv")
    (funcall (read-from-string "ql:quickload") :hyperion/server-uv)))

(defpackage #:hyperion/bench
  (:use #:cl)
  (:local-nicknames (#:srv #:hyperion/server) (#:spin #:spinneret)))
(in-package #:hyperion/bench)

;;; A tile shaped like a real one: a symbol, a price, a delta, a sparkline-ish row and
;;; enough class attributes that Spinneret does representative work. Rendering a trivial
;;; "hello" would flatter both servers equally and tell us nothing.
(defun tile (i)
  (spin:with-html-string
    (:div :class "tile is-child box" :id (format nil "sym-~D" i)
          :hx-swap-oob "true"
     (:p :class "heading has-text-grey" (format nil "SYM~2,'0D" i))
     (:p :class "title is-4" (format nil "~,2F" (+ 100 (* i 1.37))))
     (:p :class (if (evenp i) "has-text-success" "has-text-danger")
         ;; NB: params come BEFORE modifiers in a format directive -- ~,2@F, not ~@,2F.
         (format nil "~,2@F%" (* (if (evenp i) 1 -1) (+ 0.1 (* i 0.03)))))
     (:div :class "level is-mobile"
      (dotimes (k 8)
        (:span :class "level-item has-text-grey-light" (format nil "~D" (+ i k))))))))

(defparameter *tile* (tile 1))
(defparameter *board* (with-output-to-string (s) (dotimes (i 40) (write-string (tile i) s))))

(defvar *stop* nil)

(defvar *handler* nil
  "What SRV:START returned: the server, which /cpu asks for its loop under :uv.")

;;; CLOCK_THREAD_CPUTIME_ID, which SB-UNIX does not name: the CPU time of the thread that asks.
;;; compare.py only runs on Linux and macOS.
(defparameter +thread-cputime-id+ #+linux 3 #+darwin 16 #-(or linux darwin) nil)

(defun cpu-seconds (clock)
  (multiple-value-bind (sec nsec) (sb-unix:clock-gettime clock)
    (+ sec (/ nsec 1d9))))

(defun loop-cpu-seconds ()
  "The :uv loop thread's CPU seconds, or NIL on another backend. The clock is read ON the loop
thread, because a thread CPU clock measures whichever thread reads it."
  (let ((uv (find-package "HYPERION/SERVER-UV")))
    (when (and uv +thread-cputime-id+ *handler*
               (funcall (find-symbol "SERVER-P" uv) *handler*))
      (let ((loop (funcall (find-symbol "SERVER-LOOP" uv) *handler*))
            (done (sb-thread:make-semaphore))
            (value nil))
        (if (uiop:symbol-call :aion/uv :loop-thread-p loop)
            (setf value (cpu-seconds +thread-cputime-id+))
            (progn
              (uiop:symbol-call :aion/uv :submit loop
                                (lambda ()
                                  (setf value (cpu-seconds +thread-cputime-id+))
                                  (sb-thread:signal-semaphore done)))
              (sb-thread:wait-on-semaphore done :timeout 5)))
        value))))

(defun cpu-report ()
  (let ((loop (loop-cpu-seconds)))
    (format nil "process=~,3F loop=~:[-~;~:*~,3F~]"
            (cpu-seconds sb-unix:clock-process-cputime-id) loop)))

(defun app (env)
  (let ((path (getf env :path-info)))
    (cond
      ((string= path "/tile")  (list 200 '(:content-type "text/html; charset=utf-8") (list *tile*)))
      ;; Same bytes, but with an explicit Content-Length so the handler can send ONE write
      ;; instead of chunked encoding's separate terminating chunk. If the 44 ms keep-alive
      ;; floor is Nagle sitting on that last small write, this endpoint will not have it --
      ;; which would make it a framework bug, not a reason to change servers.
      ((string= path "/tilecl")
       (list 200 (list :content-type "text/html; charset=utf-8"
                       :content-length (babel:string-size-in-octets *tile* :encoding :utf-8))
             (list *tile*)))
      ((string= path "/board") (list 200 '(:content-type "text/html; charset=utf-8") (list *board*)))
      ((string= path "/ping")  (list 200 '(:content-type "text/plain") (list "ok")))
      ((string= path "/cpu")   (list 200 '(:content-type "text/plain") (list (cpu-report))))
      ((string= path "/quit")  (setf *stop* t)
                               (list 200 '(:content-type "text/plain") (list "bye")))
      (t (list 404 '(:content-type "text/plain") (list "not found"))))))

(let* ((port (or (ignore-errors (parse-integer (second sb-ext:*posix-argv*))) 8099))
       (backend (srv:default-server))
       (workers (ignore-errors (parse-integer (uiop:getenv "HYPERION_WORKERS"))))
       (handler (srv:start #'app :port port :host "127.0.0.1" :server backend
                                 :workers workers :log nil)))
  (setf *handler* handler)
  (format t "~&bench: ~A listening on 127.0.0.1:~D  (tile ~D B, board ~D B, workers ~A, pid ~D)~%"
          backend port (length *tile*) (length *board*) workers (sb-unix:unix-getpid))
  (finish-output)
  (unwind-protect
       (loop until *stop* do (sleep 0.1))
    (ignore-errors (srv:stop handler))
    (format t "~&bench: stopped.~%")
    (finish-output)))
