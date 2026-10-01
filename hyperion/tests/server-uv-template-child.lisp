;;;; server-uv-template-child.lisp --- run in a fresh sbcl by server-uv-template-tests.lisp (#472).
;;;;
;;;; Not part of any system: the test starts `sbcl --load' on this file, after --eval forms
;;;; that set CL-USER::*PROJECT-ROOT* and CL-USER::*PROJECT-NAME*. It builds the scaffolded
;;;; project, calls its START on an ephemeral port, sends GET / with Connection: close over a
;;;; real socket, prints one TEMPLATE-... line per fact, and stops the server.
;;;;
;;;; Every symbol from a package the project may not have loaded is looked up with FIND-SYMBOL,
;;;; so a template that declares another server still runs to the end and reports what it chose.

(in-package #:cl-user)

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(asdf:initialize-source-registry
 `(:source-registry (:tree ,*project-root*) :inherit-configuration))
(let ((*standard-output* (make-broadcast-stream)))
  (funcall (intern "QUICKLOAD" "QL") *project-name*))
(require :sb-bsd-sockets)

(defun template-symbol (name package)
  (and (find-package package) (find-symbol name package)))

(defun template-get (port)
  "Send GET / to 127.0.0.1:PORT with Connection: close; return the whole reply."
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
        (crlf (coerce (list (code-char 13) (code-char 10)) 'string)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-connect socket #(127 0 0 1) port)
           (let ((stream (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                             :element-type 'character
                                                             :external-format :latin-1
                                                             :timeout 30)))
             (write-string (concatenate 'string "GET / HTTP/1.1" crlf "Host: 127.0.0.1" crlf
                                        "Connection: close" crlf crlf)
                           stream)
             (finish-output stream)
             (with-output-to-string (out)
               (loop for line = (read-line stream nil)
                     while line
                     do (write-line (string-right-trim '(#\Return) line) out)))))
      (sb-bsd-sockets:socket-close socket))))

;; The backend is printed before START, and a START that fails is printed rather than left to
;; end the process, so a template on another server still reports what it chose. (Hunchentoot,
;; the template's server before #472, does not start on port 0 at all: START times out.)
(format t "~&TEMPLATE-BACKEND ~A~%" (funcall (template-symbol "DEFAULT-SERVER" "HYPERION/SERVER")))
(finish-output)

(let* ((package (string-upcase *project-name*))
       (handler (handler-case (funcall (template-symbol "START" package) :port 0)
                  (error (e) (format t "~&TEMPLATE-START-FAILED ~A~%" e) nil)))
       (server-p (template-symbol "SERVER-P" "HYPERION/SERVER-UV"))
       (uv-p (and handler server-p (funcall server-p handler))))
  (format t "~&TEMPLATE-WORKERS ~A~%"
          (and uv-p (funcall (template-symbol "SERVER-WORKERS" "HYPERION/SERVER-UV") handler) t))
  (when uv-p
    (let ((reply (template-get (funcall (template-symbol "SERVER-PORT" "HYPERION/SERVER-UV")
                                        handler))))
      (format t "~&TEMPLATE-STATUS ~A~%"
              (subseq reply 0 (or (position #\Newline reply) (length reply))))
      (format t "~&TEMPLATE-PAGE ~A~%"
              (and (search (format nil "~A is running" *project-name*) reply) t))))
  (when handler (funcall (template-symbol "STOP" package)))
  (finish-output))

(uiop:quit 0)
