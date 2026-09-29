;;;; woo-tests.lisp --- responses served through a real Woo server (#372).
;;;;
;;;; Every check starts HYPERION/SERVER:START with :SERVER :WOO on a loopback port, sends a request
;;;; over a TCP socket, and reads back the raw octets, so what is checked is what a client
;;;; receives: the status line, the headers and the body. #372 was a 429 that the app logged and
;;;; the client received as an empty 500, which only a check at this level can see.

(cl:defpackage #:hyperion/woo/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:srv #:hyperion/server)
                    (#:rl #:hyperion/ratelimit)
                    (#:ports #:hyperion/test-ports)
                    (#:sock #:sb-bsd-sockets))
  (:export #:run-tests))

(in-package #:hyperion/woo/tests)

(def-suite woo :description "Hyperion served by Woo, checked over a socket (#372).")
(in-suite woo)

(defun run-tests ()
  "Run the suite; return T on success (for asdf:test-system)."
  (run! 'woo))

;;; --- a client that reads what Woo sends ----------------------------------------------

(defun %crlf () (format nil "~C~C" (code-char 13) (code-char 10)))

(defun %split (string separator)
  (loop with start = 0
        for at = (search separator string :start2 start)
        collect (subseq string start at)
        while at
        do (setf start (+ at (length separator)))))

(defun %dechunk (body)
  "BODY, sent with Transfer-Encoding: chunked, as the data it carries."
  (with-output-to-string (out)
    (loop with start = 0
          for eol = (search (%crlf) body :start2 start)
          while eol
          do (let ((size (parse-integer body :start start :end eol :radix 16 :junk-allowed t)))
               (when (or (null size) (zerop size)) (return))
               (write-string body out :start (+ eol 2) :end (+ eol 2 size))
               (setf start (+ eol 2 size 2))))))

(defun %get (port path)
  "Send GET PATH to the server on PORT with Connection: close, and return its response as three
values: the status line exactly as sent, an alist of lowercased header names to values, and the
body."
  (let ((socket (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn
           (sock:socket-connect socket #(127 0 0 1) port)
           (let ((stream (sock:socket-make-stream socket :input t :output t
                                                         :element-type '(unsigned-byte 8)
                                                         :buffering :full :timeout 10)))
             (write-sequence (sb-ext:string-to-octets
                              (format nil "GET ~A HTTP/1.1~AHost: 127.0.0.1~AConnection: close~A~A"
                                      path (%crlf) (%crlf) (%crlf) (%crlf))
                              :external-format :latin-1)
                             stream)
             (finish-output stream)
             (let* ((octets (coerce (loop for b = (read-byte stream nil) while b collect b)
                                    '(vector (unsigned-byte 8))))
                    (text (sb-ext:octets-to-string octets :external-format :utf-8))
                    (split (search (format nil "~A~A" (%crlf) (%crlf)) text))
                    (head (%split (subseq text 0 (or split (length text))) (%crlf)))
                    (body (if split (subseq text (+ split 4)) ""))
                    (headers (loop for line in (rest head)
                                   for colon = (position #\: line)
                                   when colon
                                     collect (cons (string-downcase (subseq line 0 colon))
                                                   (string-trim " " (subseq line (1+ colon)))))))
               (values (first head)
                       headers
                       (if (equalp (cdr (assoc "transfer-encoding" headers :test #'string=))
                                   "chunked")
                           (%dechunk body)
                           body)))))
      (ignore-errors (sock:socket-close socket)))))

(defun %header (name headers)
  (cdr (assoc name headers :test #'string=)))

(defun call-with-woo (app function)
  "Start APP on Woo on a free loopback port, call FUNCTION with the port, and stop the server."
  (let (server port)
    (unwind-protect
         (progn
           (ports:call-with-port
            (lambda (candidate)
              (setf server (srv:start app :server :woo :port candidate :log nil)
                    port candidate)))
           (funcall function port))
      (when server
        (srv:stop server)
        (ports:await-released port)))))

(defmacro with-woo ((port app) &body body)
  `(call-with-woo ,app (lambda (,port) ,@body)))

(defun %status-app (env)
  "Answers /status/N with status N, a Retry-After of 7 and the body \"status N\"."
  (let* ((path (getf env :path-info))
         (code (parse-integer path :start (length "/status/"))))
    (let ((body (format nil "status ~D" code)))
      (list code
            (list :content-type "text/plain; charset=utf-8" :retry-after "7"
                  :content-length (length body))
            (list body)))))

;;; --- the checks ----------------------------------------------------------------------

(test a-429-arrives-as-429-with-its-retry-after-and-its-body
  "#372: before the fix this was HTTP/1.1 500 with an empty body."
  (with-woo (port #'%status-app)
    (multiple-value-bind (status headers body) (%get port "/status/429")
      (is (string= "HTTP/1.1 429 Too Many Requests" status))
      (is (equal "7" (%header "retry-after" headers)))
      (is (string= "status 429" body)))))

(test every-registered-code-woo-lacked-arrives-with-its-status
  "The registered codes Woo's table had no line for, and a code nobody registered, which is sent
with an empty reason phrase."
  (with-woo (port #'%status-app)
    (loop for (code . line) in '((425 . "HTTP/1.1 425 Too Early")
                                 (428 . "HTTP/1.1 428 Precondition Required")
                                 (431 . "HTTP/1.1 431 Request Header Fields Too Large")
                                 (511 . "HTTP/1.1 511 Network Authentication Required")
                                 (599 . "HTTP/1.1 599 "))
          do (multiple-value-bind (status headers body) (%get port (format nil "/status/~D" code))
               (declare (ignore headers))
               (is (string= line status) "~D: got ~S" code status)
               (is (string= (format nil "status ~D" code) body) "~D: got ~S" code body)))))

(test a-code-woo-already-had-is-sent-as-before
  "Control: 404 and 200 were never affected, and their lines are Woo's own."
  (with-woo (port #'%status-app)
    (is (string= "HTTP/1.1 404 Not Found" (%get port "/status/404")))
    (is (string= "HTTP/1.1 200 OK" (%get port "/status/200")))))

(test a-wrap-rate-limit-refusal-reaches-the-client-on-woo
  "The case #372 was found with: the second request inside the window is refused by
WRAP-RATE-LIMIT's default refusal, a 429 with Retry-After and a body."
  (let ((app (rl:wrap-rate-limit
              (lambda (env) (declare (ignore env)) (list 200 '(:content-type "text/plain") '("ok")))
              :limits (list (rl:make-limit :sign-in :capacity 1 :per 60 :methods '(:get)
                                                    :key (lambda (env) (declare (ignore env)) "one"))))))
    (with-woo (port app)
      (is (string= "HTTP/1.1 200 OK" (%get port "/sign-in")))
      (multiple-value-bind (status headers body) (%get port "/sign-in")
        (is (string= "HTTP/1.1 429 Too Many Requests" status))
        (is (plusp (parse-integer (or (%header "retry-after" headers) "0") :junk-allowed t)))
        (is (search "Too many requests" body))))))

(test woo-s-table-is-completed-without-changing-its-own-lines
  "After a Woo server has started, every code from 100 to 599 has a line, a line Woo had is
byte-identical to Woo's own, and completing the table again adds nothing. The registered codes
Woo's list lacks are named, so that a Woo upgrade that adds them shows up here."
  (with-woo (port #'%status-app)
    (declare (ignorable port))
    (let* ((table (srv::%woo-status-table))
           (woo-text (find-symbol "STATUS-CODE-TO-TEXT" "WOO.RESPONSE"))
           (woo-line (find-symbol "HTTP/1.1" "WOO.RESPONSE")))
      (is (hash-table-p table))
      (is (loop for code from 100 to 599 always (gethash code table)))
      (is (null (srv:complete-woo-status-lines)) "nothing is left to add")
      (is (loop for code from 100 to 510
                for text = (funcall woo-line code)
                always (or (null text)
                           (equalp (gethash code table)
                                   (sb-ext:string-to-octets text :external-format :utf-8)))))
      (is (equal '(103 104 425 428 429 431 511)
                 (loop for (code) in srv::+registered-reason-phrases+
                       unless (funcall woo-text code) collect code))))))
