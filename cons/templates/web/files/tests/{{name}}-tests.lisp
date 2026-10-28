;;;; {{name}}-tests.lisp --- {{name}}'s test suite.
;;;;
;;;; `cons test` runs it. The first test starts the app as `cons serve` does, sends one request
;;;; over a real socket, and checks that hyperion's own server, server-uv, answered it: the
;;;; handler START returned is server-uv's, and the request went to that handler's port.

(cl:defpackage #:{{name}}/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:uv #:hyperion/server-uv))
  (:export #:{{name}} #:http-get #:call-with-app))

(cl:in-package #:{{name}}/tests)

(def-suite {{name}} :description "{{name}}'s tests.")
(in-suite {{name}})

(defun http-get (port &key (path "/") cookie)
  "Send GET PATH to 127.0.0.1:PORT with Connection: close, and with COOKIE as the Cookie header
when it is given. Return the whole reply as a string."
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
        (crlf (coerce (list (code-char 13) (code-char 10)) 'string)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-connect socket #(127 0 0 1) port)
           (let ((stream (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                             :element-type 'character
                                                             :external-format :utf-8
                                                             :timeout 30)))
             (write-string (concatenate 'string
                                        "GET " path " HTTP/1.1" crlf
                                        "Host: 127.0.0.1" crlf
                                        (if cookie (concatenate 'string "Cookie: " cookie crlf) "")
                                        "Connection: close" crlf crlf)
                           stream)
             (finish-output stream)
             (with-output-to-string (out)
               (loop for line = (read-line stream nil)
                     while line
                     do (write-line (string-right-trim '(#\Return) line) out)))))
      (sb-bsd-sockets:socket-close socket))))

(defun call-with-app (function)
  "Start the app on a free port with HYPERION_SERVER unset, call FUNCTION with the handler START
returned, and stop the app."
  (let ((chosen (uiop:getenv "HYPERION_SERVER")))
    (setf (uiop:getenv "HYPERION_SERVER") "")
    (unwind-protect
         (let ((handler ({{name}}:start :port 0)))
           (unwind-protect (funcall function handler)
             ({{name}}:stop)))
      ;; Put it back as it was: the value it had, or unset.
      (if chosen
          (setf (uiop:getenv "HYPERION_SERVER") chosen)
          (uiop:symbol-call :sb-posix :unsetenv "HYPERION_SERVER")))))

(test server-uv-answers-a-request-for-the-page
  (call-with-app
   (lambda (handler)
     (is (uv:server-p handler) "START returned server-uv's handler, not another server's")
     (when (uv:server-p handler)
       (let ((reply (http-get (uv:server-port handler))))
         (is (uiop:string-prefix-p "HTTP/1.1 200" reply) "GET / answered 200")
         (is (search "{{name}} is running" reply) "the page is this app's"))))))

(test a-second-start-is-refused
  (call-with-app
   (lambda (handler)
     (declare (ignore handler))
     (signals error ({{name}}:start :port 0)))))
