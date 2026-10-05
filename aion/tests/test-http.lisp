;;;; test-http.lisp --- test support: a small HTTP/1.1 server on 127.0.0.1 for a test to talk to
;;;;
;;;; Moved out of aion/http-client's tests (#527) so that the tests of aion/oauth and
;;;; praxeon/mcp can run their own servers in the test image too, with no network.
;;;;
;;;; One request per connection: the server reads the request head and, when the head has a
;;;; Content-Length, the body; calls the handler; and closes the connection. The handler writes
;;;; the whole response itself, which lets a test send an event stream, a slow reply or no
;;;; reply at all.

(cl:defpackage #:aion/test-http
  (:use #:cl)
  (:export #:server #:server-port #:server-heads #:server-requests
           #:start-server #:stop-server #:with-server #:server-url
           #:request #:request-method #:request-path #:request-head #:request-body
           #:request-header #:request-body-string
           #:write-response #:write-head))

(cl:in-package #:aion/test-http)

(defstruct request
  "One request the server read. METHOD and PATH come from the request line, HEAD is the whole
head as a string, and BODY the octets of the body (empty when the head has no
Content-Length)."
  (method "" :type string)
  (path "" :type string)
  (head "" :type string)
  (body (make-array 0 :element-type '(unsigned-byte 8))))

(defun request-header (request name)
  "The value of the header NAME in REQUEST, or NIL. NAME is compared without regard to case."
  (loop for line in (uiop:split-string (request-head request) :separator (string #\Newline))
        for colon = (position #\: line)
        when (and colon (string-equal (string-trim " " (subseq line 0 colon)) name))
          return (string-trim '(#\Space #\Return) (subseq line (1+ colon)))))

(defun request-body-string (request)
  "REQUEST's body decoded as UTF-8."
  (sb-ext:octets-to-string (request-body request) :external-format :utf-8))

(defun %read-head (stream)
  "The request head from STREAM, up to the blank line, as a string (Latin-1)."
  (let ((bytes (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop for b = (read-byte stream nil nil)
          while b
          do (vector-push-extend b bytes)
          until (and (>= (length bytes) 4)
                     (equalp (subseq bytes (- (length bytes) 4)) #(13 10 13 10))))
    (sb-ext:octets-to-string bytes :external-format :latin-1)))

(defun %read-request (stream)
  (let* ((head (%read-head stream))
         (line (subseq head 0 (or (position #\Return head) (length head))))
         (words (uiop:split-string line :separator " "))
         (request (make-request :method (or (first words) "") :path (or (second words) "")
                                :head head))
         (length (let ((value (request-header request "Content-Length")))
                   (and value (parse-integer value :junk-allowed t)))))
    (when (and length (plusp length))
      (let* ((body (make-array length :element-type '(unsigned-byte 8)))
             (got (read-sequence body stream)))
        (setf (request-body request) (subseq body 0 got))))
    request))

(defun write-head (stream status headers)
  "Write a response's status line and HEADERS, an alist of (name . value), ending the head."
  (write-sequence
   (sb-ext:string-to-octets
    (with-output-to-string (s)
      (format s "HTTP/1.1 ~D X~C~C" status #\Return #\Newline)
      (loop for (k . v) in headers do (format s "~A: ~A~C~C" k v #\Return #\Newline))
      (format s "~C~C" #\Return #\Newline))
    :external-format :latin-1)
   stream)
  (finish-output stream))

(defun write-response (stream status headers body &key (content-length t))
  "Write a whole response: STATUS, HEADERS (an alist), a Content-Length unless CONTENT-LENGTH
is NIL, Connection: close, and BODY, a string (sent as UTF-8) or octets."
  (let ((body (if (stringp body) (sb-ext:string-to-octets body :external-format :utf-8) body)))
    (write-head stream status
                (append headers
                        (when content-length (list (cons "Content-Length" (length body))))
                        (list (cons "Connection" "close"))))
    (write-sequence body stream)
    (finish-output stream)))

(defstruct server port heads requests listener thread stop)

(defun start-server (handler &key tls-certificate tls-key (name "aion/test-http server"))
  "Start a server on 127.0.0.1, on a port the system chooses, and return it. HANDLER is a
function of (REQUEST STREAM) that writes the response. Every request is recorded, and so is
its head (SERVER-HEADS, newest first). With TLS-CERTIFICATE and TLS-KEY, pathnames of PEM
files, the server speaks TLS; not on Windows, where nothing in the tree loads OpenSSL."
  #+os-windows (when tls-certificate (error "aion/test-http: TLS is not available on Windows"))
  (let* ((listener (usocket:socket-listen "127.0.0.1" 0 :reuse-address t
                                                        :element-type '(unsigned-byte 8)))
         (server (make-server :port (usocket:get-local-port listener) :heads '()
                              :requests '() :listener listener))
         (lock (bt:make-lock)))
    (setf (server-thread server)
          (bt:make-thread
           (lambda ()
             ;; WAIT, THEN ACCEPT, AND CHECK THE STOP FLAG BETWEEN WAITS. A thread blocked in
             ;; accept() is not woken when another thread closes the listening socket on SBCL,
             ;; so a server that simply looped on SOCKET-ACCEPT could never be joined, and every
             ;; test using it hung in its cleanup.
             (loop
               (when (server-stop server) (return))
               (let ((conn (handler-case
                               (and (usocket:wait-for-input listener :timeout 0.1 :ready-only t)
                                    (usocket:socket-accept listener))
                             (error () (return)))))
                 (when conn
                   (unwind-protect
                        (ignore-errors
                         (let ((stream (usocket:socket-stream conn)))
                           #-os-windows
                           (when tls-certificate
                             (setf stream (uiop:symbol-call
                                           :cl+ssl :make-ssl-server-stream stream
                                           :certificate (namestring tls-certificate)
                                           :key (namestring tls-key))))
                           (let ((request (%read-request stream)))
                             (bt:with-lock-held (lock)
                               (push (request-head request) (server-heads server))
                               (push request (server-requests server)))
                             (funcall handler request stream))))
                     (ignore-errors (usocket:socket-close conn)))))))
           :name name))
    server))

(defun stop-server (server)
  "Stop SERVER and wait for its thread."
  (setf (server-stop server) t)
  (ignore-errors (aion/test-threads:join (server-thread server)))
  (ignore-errors (usocket:socket-close (server-listener server))))

(defmacro with-server ((var handler &rest options) &body body)
  "Run BODY with VAR bound to a server started with HANDLER and OPTIONS, and stop it after."
  `(let ((,var (start-server ,handler ,@options)))
     (unwind-protect (progn ,@body) (stop-server ,var))))

(defun server-url (server path &key (host "127.0.0.1") (scheme "http"))
  "The URL of PATH on SERVER."
  (format nil "~A://~A:~D~A" scheme host (server-port server) path))
