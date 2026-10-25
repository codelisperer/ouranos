;;;; {{name}}-tests.lisp --- {{name}}'s test suite.
;;;;
;;;; `cons test` runs it. Each test starts the app as `cons serve` does and sends requests over a
;;;; real socket. The first checks that hyperion's own server, server-uv, answered: the handler
;;;; START returned is server-uv's, and the request went to that handler's port. The second
;;;; checks that a session is kept in the database, through the one pool src/db.lisp makes.
;;;;
;;;; The database: DATABASE_URL when it is set. Otherwise a SQLite app uses a new file in the
;;;; temporary directory, deleted afterwards, and a Postgres app skips these tests.

(cl:defpackage #:{{name}}/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:uv #:hyperion/server-uv)
                    (#:srv #:hyperion/server)
                    (#:session #:hyperion/session))
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

(defun %with-env (name value function)
  "Call FUNCTION with the environment variable NAME set to VALUE, and restore it afterwards."
  (let ((before (uiop:getenv name)))
    (setf (uiop:getenv name) value)
    (unwind-protect (funcall function)
      (setf (uiop:getenv name) (or before "")))))

(defun call-with-database (function)
  "Call FUNCTION with a database to use: DATABASE_URL when it is set, a new SQLite file for a
SQLite app, or else skip."
  (let ((set (uiop:getenv "DATABASE_URL")))
    (cond ((and set (plusp (length set))) (funcall function))
          ((eq {{name}}::+dialect+ :sqlite)
           (let ((file (uiop:native-namestring
                        (merge-pathnames (format nil "{{name}}-test-~36R.db"
                                                 (random (expt 2 40) (make-random-state t)))
                                         (uiop:temporary-directory)))))
             (unwind-protect
                  (%with-env "DATABASE_URL" (concatenate 'string "sqlite://" file) function)
               (dolist (suffix '("" "-wal" "-shm" "-journal"))
                 (uiop:delete-file-if-exists (concatenate 'string file suffix))))))
          (t (skip "DATABASE_URL is not set, so the tests that need the database do not run")))))

(defun call-with-app (function)
  "Start the app on a free port with HYPERION_SERVER unset and a database to use, call FUNCTION
with the handler START returned, and stop the app."
  (call-with-database
   (lambda ()
     (%with-env "HYPERION_SERVER" ""
                (lambda ()
                  (let ((handler ({{name}}:start :port 0)))
                    (unwind-protect (funcall function handler)
                      ({{name}}:stop))))))))

(defun %session-cookie (reply)
  "The NAME=VALUE pair of the session cookie REPLY sets, or NIL."
  (let* ((prefix (format nil "Set-Cookie: ~A=" session:*cookie-name*))
         (start (search prefix reply :test #'char-equal)))
    (when start
      (let ((value (+ start (length "Set-Cookie: "))))
        (subseq reply value (position-if (lambda (c) (member c '(#\; #\Newline))) reply
                                         :start value))))))

(test server-uv-answers-a-request-for-the-page
  (call-with-app
   (lambda (handler)
     (is (uv:server-p handler) "START returned server-uv's handler, not another server's")
     (when (uv:server-p handler)
       (let ((reply (http-get (uv:server-port handler))))
         (is (uiop:string-prefix-p "HTTP/1.1 200" reply) "GET / answered 200")
         (is (search "{{name}} is running" reply) "the page is this app's"))))))

(test the-session-is-kept-in-the-database
  "Two requests with the session cookie count two visits, and the session store, which reads
the database through the pool, holds the session with that count."
  (call-with-app
   (lambda (handler)
     (let* ((port (srv:handler-port handler))
            (first (http-get port))
            (cookie (%session-cookie first)))
       (is (search "Visits from this browser: 1" first) "the first visit")
       (is (stringp cookie) "the first reply set a session cookie")
       (when cookie
         (is (search "Visits from this browser: 2" (http-get port :cookie cookie))
             "the second visit, with the cookie")
         (let ((stored (session:store-ref {{name}}:*sessions*
                                          (subseq cookie (1+ (position #\= cookie))))))
           (is (and stored (eql 2 (session:session-get stored :visits)))
               "the database holds the session with two visits")))))))
