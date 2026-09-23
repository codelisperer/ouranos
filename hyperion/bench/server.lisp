;;;; server.lisp --- the benchmark subject: one Hyperion app, either backend.
;;;;
;;;;     HYPERION_SERVER=hunchentoot sbcl --dynamic-space-size 4096 --script hyperion/bench/server.lisp 8099
;;;;     HYPERION_SERVER=woo         sbcl --dynamic-space-size 4096 --script hyperion/bench/server.lisp 8099
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

;;; hyperion.asd pulls clack-handler-WOO on Unix and clack-handler-HUNCHENTOOT only on
;;; Windows, so asking for Hunchentoot on Linux otherwise dies with "... is unknown handler".
;;; Loading it explicitly here is exactly the .asd-level change the desktop decision implies
;;; -- the handler is baked in at build time, so it is not something HYPERION_SERVER alone
;;; can switch in a dumped image.
(let ((want (string-downcase (or (uiop:getenv "HYPERION_SERVER") ""))))
  (when (string= want "hunchentoot")
    (funcall (read-from-string "ql:quickload") :clack-handler-hunchentoot)))

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
      ((string= path "/quit")  (setf *stop* t)
                               (list 200 '(:content-type "text/plain") (list "bye")))
      (t (list 404 '(:content-type "text/plain") (list "not found"))))))

(let* ((port (or (ignore-errors (parse-integer (second sb-ext:*posix-argv*))) 8099))
       (backend (srv:default-server))
       (handler (srv:start #'app :port port :host "127.0.0.1" :server backend)))
  (format t "~&bench: ~A listening on 127.0.0.1:~D  (tile ~D B, board ~D B)~%"
          backend port (length *tile*) (length *board*))
  (finish-output)
  (unwind-protect
       (loop until *stop* do (sleep 0.1))
    (ignore-errors (srv:stop handler))
    (format t "~&bench: stopped.~%")
    (finish-output)))
