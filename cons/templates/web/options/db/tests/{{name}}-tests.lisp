;;;; {{name}}-tests.lisp --- {{name}}'s test suite.
;;;;
;;;; `cons test` runs it. Each test starts the app as `cons serve` does and sends requests over a
;;;; real socket. The first checks that hyperion's own server, server-uv, answered: the handler
;;;; START returned is server-uv's, and the request went to that handler's port. The second
;;;; checks that a session is kept in the database, through the one pool src/db.lisp makes.
;;;;
;;;; The database: DATABASE_URL when it is set, in the environment or in the project's .env,
;;;; which is loaded first, as START loads it. Otherwise a SQLite app uses a new file in the
;;;; temporary directory, deleted afterwards, and a Postgres app skips these tests.

(cl:defpackage #:{{name}}/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:env #:cons/env)
                    (#:uv #:hyperion/server-uv)
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
  "Call FUNCTION with the environment variable NAME set to VALUE, and put it back afterwards: the
value it had, or unset when it was not set."
  (let ((before (uiop:getenv name)))
    (setf (uiop:getenv name) value)
    (unwind-protect (funcall function)
      (if before
          (setf (uiop:getenv name) before)
          (uiop:symbol-call :sb-posix :unsetenv name)))))

(defun call-with-database (function)
  "Call FUNCTION with a database to use: DATABASE_URL when it is set, a new SQLite file for a
SQLite app, or else skip. The project's .env is loaded first, so a DATABASE_URL set only there
is used, as START would use it."
  (env:load-project-env :{{name}})
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

(test a-second-start-is-refused-and-the-database-stays-open
  (call-with-app
   (lambda (handler)
     (declare (ignore handler))
     (signals error ({{name}}:start :port 0))
     (is (not (null {{name}}:*pool*)) "the running app's pool is still open"))))

(test a-start-that-fails-closes-the-database-it-opened
  "START opens the pool before it starts the server. When the server does not start, here
because HYPERION_SERVER names no server, the pool is closed again."
  (call-with-database
   (lambda ()
     (%with-env "HYPERION_SERVER" "no-such-server"
                (lambda ()
                  (signals error ({{name}}:start :port 0))
                  (is (null {{name}}:*pool*) "the pool START opened was closed"))))))

(defun %with-users-store-made-by (replacement function)
  "Call FUNCTION while HYPERION/AUTH-DB:MAKE-DB-AUTH, the user store's constructor, is replaced
by REPLACEMENT, which is called with the original constructor and its arguments. The original
is put back afterwards."
  (let ((original (fdefinition 'hyperion/auth-db:make-db-auth)))
    (setf (fdefinition 'hyperion/auth-db:make-db-auth)
          (lambda (&rest args) (apply replacement original args)))
    (unwind-protect (funcall function)
      (setf (fdefinition 'hyperion/auth-db:make-db-auth) original))))

(test a-store-that-recovers-from-an-error-keeps-the-pool-open
  "OPEN-DATABASE closes the pool only when a store could not be made. Here the user store's
constructor signals an error, a handler outside OPEN-DATABASE resumes it through a restart, and
the constructor carries on and makes the store, so the pool stays open and usable."
  (call-with-database
   (lambda ()
     (%with-users-store-made-by
      (lambda (original &rest args)
        (restart-case (error "{{name}}: an error the user store recovers from")
          (resume-making-the-store () nil))
        (apply original args))
      (lambda ()
        (unwind-protect
             (progn
               ;; Only the restart the constructor set up for this condition is taken. Any
               ;; other error, such as one from a pool closed under the constructor, is left
               ;; to fail the test.
               (handler-bind ((error (lambda (e)
                                       (let ((restart (find-restart 'resume-making-the-store e)))
                                         (when restart (invoke-restart restart))))))
                 ({{name}}::open-database))
               (is (not (null {{name}}:*pool*)) "the pool is still open")
               (is (not (null {{name}}:*users*)) "the user store was made")
               (is (integerp (session:store-count {{name}}:*sessions*))
                   "the session store reads the database through the pool"))
          ({{name}}::close-database)))))))

(define-condition %users-store-not-made (error) ()
  (:report "{{name}}: the user store cannot be made")
  (:documentation "The error the replaced user-store constructor signals, so that a test can
tell it apart from an error OPEN-DATABASE met before it reached the stores."))

(test a-store-that-cannot-be-made-leaves-the-database-closed
  "When a store cannot be made, OPEN-DATABASE signals, closes the pool it made, and leaves
*POOL*, *SESSIONS* and *USERS* all NIL."
  (call-with-database
   (lambda ()
     (%with-users-store-made-by
      (lambda (original &rest args)
        (declare (ignore original args))
        (error '%users-store-not-made))
      (lambda ()
        (signals %users-store-not-made ({{name}}::open-database))
        (is (null {{name}}:*pool*) "the pool was closed")
        (is (null {{name}}:*sessions*) "no session store is left set")
        (is (null {{name}}:*users*) "no user store is left set"))))))

(define-condition %pool-not-closed (error) ()
  (:report "{{name}}: the pool cannot be closed")
  (:documentation "The error the replaced CLOSE-POOL signals."))

(defun %with-close-pool-failing (function)
  "Call FUNCTION while MNEMOSYNE/CONN:CLOSE-POOL signals %POOL-NOT-CLOSED instead of closing.
Each pool it was asked to close is closed for real afterwards, with the original put back, so
the test leaves no connections open."
  (let ((original (fdefinition 'mnemosyne/conn:close-pool))
        (asked '()))
    (setf (fdefinition 'mnemosyne/conn:close-pool)
          (lambda (pool &rest args)
            (declare (ignore args))
            (push pool asked)
            (error '%pool-not-closed)))
    (unwind-protect (funcall function)
      (setf (fdefinition 'mnemosyne/conn:close-pool) original)
      (dolist (pool asked) (funcall original pool)))))

(test a-pool-that-cannot-be-closed-during-cleanup-keeps-the-store-error
  "#1006: when a store cannot be made and closing the pool then signals too, the caller sees the
store's error, not the pool's, and *POOL*, *SESSIONS* and *USERS* are NIL, so the next
OPEN-DATABASE is not refused. The close failure is logged by its type."
  (call-with-database
   (lambda ()
     (let ((log (make-string-output-stream)))
       (%with-users-store-made-by
        (lambda (original &rest args)
          (declare (ignore original args))
          (error '%users-store-not-made))
        (lambda ()
          (%with-close-pool-failing
           (lambda ()
             (unwind-protect
                  (progn (aion/log:setup :env :prod :level :info :stream log)
                         (signals %users-store-not-made ({{name}}::open-database)))
               (aion/log:setup :env :dev :level :warn :stream *standard-output*))))))
       (is (null {{name}}:*pool*) "the pool is not left set")
       (is (null {{name}}:*sessions*) "no session store is left set")
       (is (null {{name}}:*users*) "no user store is left set")
       (let ((text (get-output-stream-string log)))
         (is (search "%pool-not-closed" text :test #'char-equal) "the close failure is logged by its type: ~S" text)
         (is (null (search "the pool cannot be closed" text)) "and not by its report"))))))

(test a-pool-that-cannot-be-closed-is-still-forgotten
  "#1006: CLOSE-DATABASE called directly signals when closing the pool fails, since its caller
asked to close it, and still leaves *POOL* NIL, so OPEN-DATABASE works again afterwards."
  (call-with-database
   (lambda ()
     (unwind-protect
          (progn
            ({{name}}::open-database)
            (%with-close-pool-failing
             (lambda ()
               (signals %pool-not-closed ({{name}}::close-database))
               (is (null {{name}}:*pool*) "the pool is not left set")))
            (finishes ({{name}}::open-database) "a later OPEN-DATABASE is not refused"))
       ({{name}}::close-database)))))
