;;;; clack-handler-uv-tests.lisp --- Clack's handler cases, run against :uv (#373, ADR-0020).
;;;;
;;;; Each test below is a case from Clack 2.1.0's own handler suite, src/test/suite.lisp in
;;;; clack-20250622-git (the pinned Quicklisp dist of 2026-01-01), which is what Woo and
;;;; Hunchentoot are tested with. The suite itself is not loaded: it is written in rove, it
;;;; depends on clack-handler-hunchentoot, and it skips its streaming case for any handler not
;;;; on a list :uv is not on (ADR-0020). So the cases are copied here, each naming the group and
;;;; title it came from, with the request and the checks as the suite has them. Where a case is
;;;; changed, its docstring says how and why.
;;;;
;;;; The fixture files are read from the clack release directory, as the suite reads them, and
;;;; each is checked to be the file the case expects before it is used.

(defpackage #:hyperion/clack-handler-uv/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:uvh #:clack.handler.uv)
                    (#:srv #:hyperion/server-uv))
  (:export #:run-tests))

(in-package #:hyperion/clack-handler-uv/tests)

(def-suite clack-handler-uv :description "Clack's handler cases on :uv (#373, ADR-0020).")
(in-suite clack-handler-uv)

(defun run-tests ()
  (let ((results (run 'clack-handler-uv)))
    (explain! results)
    (results-status results)))

;;; --- the harness: Clack's TESTING-APP, and its fixtures ---------------------

(defun %free-port ()
  "A port nothing is listening on, from Clack's range for its tests."
  (loop for port = (+ 50000 (random 10000))
        when (handler-case (let ((s (usocket:socket-listen "127.0.0.1" port :reuse-address t)))
                             (usocket:socket-close s)
                             t)
               (error () nil))
          return port))

(defun %listening-p (port)
  (handler-case (let ((s (usocket:socket-connect "127.0.0.1" port)))
                  (usocket:socket-close s)
                  t)
    (error () nil)))

(defmacro testing-app ((port app &rest clackup-args) &body body)
  "Clack's TESTING-APP: serve APP with (clack:clackup app :server :uv ...) on a free PORT, run
BODY, and stop the handler with CLACK:STOP, as the suite does."
  (let ((handler (gensym "HANDLER")))
    `(let* ((,port (%free-port))
            (,handler (clack:clackup ,app :server :uv :port ,port :use-thread t :silent t
                                          ,@clackup-args)))
       (unwind-protect
            (progn
              (loop repeat 100 until (%listening-p ,port) do (sleep 0.05))
              (let ((dex:*use-connection-pool* nil)) ,@body))
         (clack:stop ,handler)))))

(defun localhost (port &optional (path "/")) (format nil "http://127.0.0.1:~D~A" port path))

(defun get-header (headers name) (gethash (string-downcase name) headers))

(defun %status-of (thunk)
  "The status of the response THUNK receives, including one dexador signals for."
  (handler-case (nth-value 1 (funcall thunk))
    (dex:http-request-failed (e) (dex:response-status e))))

(defun fixture (name size)
  "The file NAME in the clack release's tmp/ directory, after checking it is where the suite
keeps it and SIZE octets long. A missing or different clack release then fails here, loudly,
instead of a case passing on the wrong file."
  (let* ((dir (asdf:system-source-directory "clack"))
         (file (merge-pathnames (concatenate 'string "tmp/" name) dir)))
    (is-true (probe-file file) "clack fixture ~A is not at ~A" name file)
    (is (eql 0 (search (namestring dir) (namestring (truename file))))
        "fixture ~A is not under the clack release directory ~A" name dir)
    (is (= size (with-open-file (in file :element-type '(unsigned-byte 8)) (file-length in)))
        "fixture ~A is not the ~D-octet file the case expects" name size)
    file))

(defun file-octets (file)
  (with-open-file (in file :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence v in)
      v)))

(defun read-all (stream)
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop for b = (read-byte stream nil nil) while b do (vector-push-extend b out))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun octets->string (octets) (sb-ext:octets-to-string octets :external-format :utf-8))

(defun raw-request (port head-lines &optional (body #()))
  "Send HEAD-LINES (strings, without their CRLFs) and the octets BODY to PORT on one connection
that closes after the response, and return the response's body as a string, its status and its
headers (lowercased names, repeated fields joined with \", \"), in that order, as DEX:GET does.

For the cases dexador cannot send the same way on every OS. On Windows dexador uses WinHTTP,
which refuses a 96,000-octet header value and a chunked body with no length (ERROR 87, \"The
parameter is incorrect\"), and sends only the last of two fields with one name. Those were
failures of the client, measured on the Windows CI leg of #384, not of the server. These bytes
are what Clack's cases send, on every OS."
  (let ((socket (usocket:socket-connect "127.0.0.1" port :element-type '(unsigned-byte 8))))
    (unwind-protect
         (let ((stream (usocket:socket-stream socket))
               (crlf (coerce '(#\Return #\Newline) 'string)))
           (write-sequence (sb-ext:string-to-octets
                            (format nil "~{~A~A~}~A" (loop for l in (append head-lines (list "Connection: close"))
                                                           append (list l crlf))
                                    crlf)
                            :external-format :latin-1)
                           stream)
           (write-sequence body stream)
           (force-output stream)
           (let* ((all (read-all stream))
                  (text (sb-ext:octets-to-string all :external-format :latin-1))
                  (end (search (concatenate 'string crlf crlf) text))
                  (lines (uiop:split-string (subseq text 0 end) :separator (string #\Newline)))
                  (headers (make-hash-table :test 'equal)))
             (dolist (line (rest lines))
               (let* ((line (string-right-trim '(#\Return) line))
                      (c (position #\: line)))
                 (when c
                   (let ((name (string-downcase (subseq line 0 c)))
                         (value (string-trim " " (subseq line (1+ c)))))
                     (setf (gethash name headers)
                           (let ((prior (gethash name headers)))
                             (if prior (concatenate 'string prior ", " value) value)))))))
             (values (octets->string (subseq all (+ end 4)))
                     (parse-integer (first lines) :start 9 :end 12)
                     headers)))
      (usocket:socket-close socket))))

(defun %chunked (octets size)
  "OCTETS as a chunked body, in chunks of SIZE, with its last chunk and final CRLF."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (flet ((emit (string) (loop for b across (sb-ext:string-to-octets string :external-format :latin-1)
                                do (vector-push-extend b out))))
      (loop for start from 0 below (length octets) by size
            for end = (min (length octets) (+ start size))
            do (emit (format nil "~X~C~C" (- end start) #\Return #\Newline))
               (loop for i from start below end do (vector-push-extend (aref octets i) out))
               (emit (format nil "~C~C" #\Return #\Newline)))
      (emit (format nil "0~C~C~C~C" #\Return #\Newline #\Return #\Newline)))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defparameter +big-chunk+
  (with-output-to-string (s) (dotimes (i 12000) (write-string "abcdefgh" s)))
  "The 96,000-character string several request cases send.")

;;; --- response-tests ----------------------------------------------------------

(test response-list
  "Clack suite, response-tests: \"list\"."
  (testing-app (port (lambda (env) (declare (ignore env))
                       '(200 (:content-type "text/plain") ("Hello" "World"))))
    (multiple-value-bind (body status) (dex:get (localhost port))
      (is (eql 200 status))
      (is (equal "HelloWorld" body)))))

(test response-pathname-plain-text
  "Clack suite, response-tests: \"pathname (plain/text)\"."
  (let ((file (fixture "file.txt" 25)))
    (testing-app (port (lambda (env) (declare (ignore env))
                         `(200 (:content-type "text/plain; charset=utf-8") ,file)))
      (multiple-value-bind (body status headers) (dex:get (localhost port))
        (is (eql 200 status))
        (is (equal "text/plain; charset=utf-8" (get-header headers :content-type)))
        (is (search "This is a text for test." body))))))

(test response-pathname-binary
  "Clack suite, response-tests: \"pathname (binary)\"."
  (let ((file (fixture "redhat.png" 12155)))
    (testing-app (port (lambda (env) (declare (ignore env))
                         `(200 (:content-type "image/png" :content-length 12155) ,file)))
      (multiple-value-bind (body status headers) (dex:get (localhost port "/redhat.png"))
        (is (eql 200 status))
        (is (equal "image/png" (get-header headers :content-type)))
        (is-true (get-header headers :content-length))
        (is (eql 12155 (length body)))))))

(test response-bigger-file
  "Clack suite, response-tests: \"bigger file\"."
  (let ((file (fixture "jellyfish.jpg" 139616)))
    (testing-app (port (lambda (env) (declare (ignore env))
                         `(200 (:content-type "image/jpeg" :content-length 139616) ,file)))
      (multiple-value-bind (body status headers) (dex:get (localhost port "/jellyfish.jpg"))
        (is (eql 200 status))
        (is (equal "image/jpeg" (get-header headers :content-type)))
        (is-true (get-header headers :content-length))
        (is (eql 139616 (length body)))))))

(test response-multi-headers
  "Clack suite, response-tests: \"multi headers (response)\". Deviates from Clack's case only
in being stricter: Clack matches the regex foo,\\s*bar,\\s*baz, and cl-ppcre is not in this tree,
so this compares the exact joined value."
  (testing-app (port (lambda (env) (declare (ignore env))
                       '(200 (:content-type "text/plain; charset=utf-8"
                              :x-foo "foo" :x-foo "bar, baz")
                         ("hi"))))
    (let ((value (get-header (nth-value 2 (dex:get (localhost port))) :x-foo)))
      (is (equal "foo, bar, baz" value)))))

(test response-no-entity-headers-on-304
  "Clack suite, response-tests: \"no entity headers on 304\"."
  (testing-app (port (lambda (env) (declare (ignore env)) '(304 nil nil)))
    (multiple-value-bind (body status headers) (dex:get (localhost port))
      (is (eql 304 status))
      (is (equalp #() body))
      (is (null (nth-value 1 (get-header headers :content-type))) "No Content-Type")
      (is (null (nth-value 1 (get-header headers :content-length))) "No Content-Length")
      (is (null (nth-value 1 (get-header headers :transfer-encoding))) "No Transfer-Encoding"))))

(test response-crlf-output
  "Clack suite, response-tests: \"CRLF output\"."
  (let ((text (format nil "Foo: Bar~A~A~A~AHello World" #\Return #\Newline #\Return #\Newline)))
    (testing-app (port (lambda (env) (declare (ignore env))
                         `(200 (:content-type "text/plain; charset=utf-8") (,text))))
      (multiple-value-bind (body status headers) (dex:get (localhost port))
        (is (eql 200 status))
        (is (null (get-header headers :foo)))
        (is (equal text body))))))

(test response-test-404
  "Clack suite, response-tests: \"test 404\"."
  (testing-app (port (lambda (env) (declare (ignore env))
                       '(404 (:content-type "text/plain; charset=utf-8") ("Not Found"))))
    (multiple-value-bind (body status)
        (handler-bind ((dex:http-request-not-found #'dex:ignore-and-continue))
          (dex:get (localhost port)))
      (is (eql 404 status))
      (is (equal "Not Found" body)))))

(test response-content-length-0-is-not-set-transfer-encoding
  "Clack suite, response-tests: \"Content-Length 0 is not set Transfer-Encoding\"."
  (testing-app (port (lambda (env) (declare (ignore env))
                       '(200 (:content-length 0 :content-type "text/plain") (""))))
    (multiple-value-bind (body status headers) (dex:get (localhost port))
      (is (eql 200 status))
      (is (null (get-header headers :client-transfer-encoding)))
      (is (equal "" body)))))

;;; --- env-tests ---------------------------------------------------------------

(defun %echo (key)
  "An app answering the printed value of env KEY."
  (lambda (env)
    `(200 (:content-type "text/plain; charset=utf-8") (,(princ-to-string (getf env key))))))

(test env-script-name
  "Clack suite, env-tests: \"SCRIPT-NAME\"."
  (testing-app (port (lambda (env)
                       `(200 (:content-type "text/plain; charset=utf-8") (,(getf env :script-name)))))
    (is (member (dex:get (localhost port)) '(nil "") :test #'equal))))

(test env-url-scheme
  "Clack suite, env-tests: \"url-scheme\"."
  (testing-app (port (%echo :url-scheme))
    (multiple-value-bind (body status headers) (dex:post (localhost port))
      (is (eql 200 status))
      (is (equal "text/plain; charset=utf-8" (get-header headers :content-type)))
      (is (equal "http" body)))))

(test env-handle-http-header
  "Clack suite, env-tests: \"handle HTTP-Header\"."
  (testing-app (port (lambda (env)
                       `(200 (:content-type "text/plain; charset=utf-8")
                             (,(gethash "foo" (getf env :headers))))))
    (multiple-value-bind (body status headers)
        (dex:get (localhost port "/foo/?ediweitz=weitzedi") :headers '(("Foo" . "Bar")))
      (is (eql 200 status))
      (is (equal "text/plain; charset=utf-8" (get-header headers :content-type)))
      (is (equal "Bar" body)))))

(test env-validate-env
  "Clack suite, env-tests: \"validate env\"."
  (testing-app (port (lambda (env)
                       `(200 (:content-type "text/plain; charset=utf-8")
                             (,(with-output-to-string (str)
                                 (loop for h in '(:request-method :path-info :query-string
                                                  :server-name :server-port)
                                       do (format str "~A:~S~%" h (getf env h))))))))
    (multiple-value-bind (body status headers) (dex:get (localhost port "/foo/?ediweitz=weitzedi"))
      (is (eql 200 status))
      (is (equal "text/plain; charset=utf-8" (get-header headers :content-type)))
      (is (equal (format nil "~{~A~%~}"
                         (list "REQUEST-METHOD::GET" "PATH-INFO:\"/foo/\""
                               "QUERY-STRING:\"ediweitz=weitzedi\"" "SERVER-NAME:\"127.0.0.1\""
                               (format nil "SERVER-PORT:~D" port)))
                 body)))))

(test env-validate-env-must-be-integer
  "Clack suite, env-tests: \"validate env (must be integer)\"."
  (testing-app (port (lambda (env)
                       `(200 (:content-type "text/plain; charset=utf-8")
                             (,(with-output-to-string (str)
                                 (loop for h in '(:server-port :remote-port :content-length)
                                       do (format str "~A:~A~%" h
                                                  (typep (getf env h) '(or integer null)))))))))
    (multiple-value-bind (body status headers)
        (dex:post (localhost port) :content '(("name" . "eitaro")))
      (is (eql 200 status))
      (is (equal "text/plain; charset=utf-8" (get-header headers :content-type)))
      (is (equal (format nil "SERVER-PORT:T~%REMOTE-PORT:T~%CONTENT-LENGTH:T~%") body)))))

(test env-percent-encoding-in-path-info
  "Clack suite, env-tests: \"% encoding in PATH-INFO\"."
  (testing-app (port (%echo :path-info))
    (is (equal "/foo/bar,baz" (dex:get (localhost port "/foo/bar%2cbaz"))))))

(test env-percent-double-encoding-in-path-info
  "Clack suite, env-tests: \"% double encoding in PATH-INFO\"."
  (testing-app (port (%echo :path-info))
    (is (equal "/foo/bar%2cbaz" (dex:get (localhost port "/foo/bar%252cbaz"))))))

(test env-percent-encoding-outside-uri-characters
  "Clack suite, env-tests: \"% encoding in PATH-INFO (outside of URI characters)\"."
  (testing-app (port (%echo :path-info))
    (is (equal (format nil "/foo~C" (code-char #x3042)) (dex:get (localhost port "/foo%E3%81%82"))))))

(test env-invalid-utf-8-encoded-path-info
  "Clack suite, env-tests: \"Invalid UTF-8 encoded PATH-INFO\"."
  (testing-app (port (%echo :path-info))
    (is (eql 0 (search (format nil "/~C~C" (code-char #x3042) #\Replacement_Character)
                       (dex:get (localhost port "/%E3%81%82%BF%27%22%28")))))))

(test env-server-protocol-is-required
  "Clack suite, env-tests: \"SERVER-PROTOCOL is required\"."
  (testing-app (port (lambda (env)
                       `(200 (:content-type "text/plain; charset=utf-8")
                             (,(prin1-to-string (getf env :server-protocol))))))
    (multiple-value-bind (body status headers) (dex:get (localhost port "/foo/?ediweitz=weitzedi"))
      (is (eql 200 status))
      (is (equal "text/plain; charset=utf-8" (get-header headers :content-type)))
      (is (member body '(":HTTP/1.1" ":HTTP/1.0") :test #'equal)))))

(test env-script-name-should-not-be-nil
  "Clack suite, env-tests: \"SCRIPT-NAME should not be nil\"."
  (testing-app (port (lambda (env)
                       `(200 (:content-type "text/plain; charset=utf-8")
                             (,(princ-to-string (not (null (getf env :script-name))))))))
    (is (equal (string t) (dex:get (localhost port "/foo/?ediweitz=weitzedi"))))))

(test env-do-not-set-cookie
  "Clack suite, env-tests: \"Do not set COOKIE\"."
  (testing-app (port (lambda (env)
                       `(200 (:content-type "text/plain; charset=utf-8"
                              :x-cookie ,(not (null (getf env :cookie))))
                             (,(gethash "cookie" (getf env :headers))))))
    (multiple-value-bind (body status headers)
        (dex:get (localhost port) :headers '(("Cookie" . "foo=bar")))
      (is (eql 200 status))
      (is (null (get-header headers :x-cookie)))
      (is (equal "foo=bar" body)))))

(test env-request-uri-is-set
  "Clack suite, env-tests: \"REQUEST-URI is set\"."
  (testing-app (port (%echo :request-uri))
    (is (equal "/foo/bar%20baz%73?x=a" (dex:get (localhost port "/foo/bar%20baz%73?x=a"))))))

;;; --- request-tests -------------------------------------------------------------

(test request-get
  "Clack suite, request-tests: \"GET\"."
  (testing-app (port (lambda (env)
                       `(200 (:content-type "text/plain; charset=utf-8")
                             (,(format nil "Hello, ~A" (getf env :query-string))))))
    (multiple-value-bind (body status headers) (dex:get (localhost port "/?name=fukamachi"))
      (is (eql 200 status))
      (is (equal "text/plain; charset=utf-8" (get-header headers :content-type)))
      (is (equal "Hello, name=fukamachi" body)))))

(test request-post
  "Clack suite, request-tests: \"POST\"."
  (testing-app (port (lambda (env)
                       (let ((body (make-array 11 :element-type '(unsigned-byte 8))))
                         (read-sequence body (getf env :raw-body))
                         `(200 (:content-type "text/plain; charset=utf-8"
                                :client-content-length ,(getf env :content-length)
                                :client-content-type ,(getf env :content-type))
                               (,(format nil "Hello, ~A" (octets->string body)))))))
    (multiple-value-bind (body status headers)
        (dex:post (localhost port) :content '(("name" . "eitaro")))
      (is (eql 200 status))
      (is (equal "11" (get-header headers :client-content-length)))
      (is (equal "application/x-www-form-urlencoded" (get-header headers :client-content-type)))
      (is (equal "Hello, name=eitaro" body)))))

(test request-big-post
  "Clack suite, request-tests: \"big POST\"."
  (testing-app (port (lambda (env)
                       (let ((body (make-array (getf env :content-length)
                                               :element-type '(unsigned-byte 8))))
                         (read-sequence body (getf env :raw-body))
                         `(200 (:content-type "text/plain; charset=utf-8"
                                :client-content-length ,(getf env :content-length)
                                :client-content-type ,(getf env :content-type))
                               (,(octets->string body))))))
    (multiple-value-bind (body status headers)
        (dex:post (localhost port)
                  :headers `((:content-type . "application/octet-stream")
                             (:content-length . ,(length +big-chunk+)))
                  :content +big-chunk+)
      (is (eql 200 status))
      (is (equal (princ-to-string (length +big-chunk+)) (get-header headers :client-content-length)))
      (is (eql (length +big-chunk+) (length body))))))

(test request-big-post-chunked
  "Clack suite, request-tests: \"big POST (chunked)\". The body is sent with
Transfer-Encoding: chunked, which server-uv decodes since #374. Deviates from Clack's case in
its client: the request is written over a raw socket, in 1,024-octet chunks, because WinHTTP,
dexador's client on Windows, refuses to send a chunked body with no length (see RAW-REQUEST)."
  (testing-app (port (lambda (env)
                       `(200 (:content-type "text/plain; charset=utf-8"
                              :client-content-length ,(getf env :content-length)
                              :client-content-type ,(getf env :content-type))
                             (,(octets->string (read-all (getf env :raw-body)))))))
    (multiple-value-bind (body status headers)
        (raw-request port (list "POST / HTTP/1.1" "Host: 127.0.0.1"
                                "Content-Type: application/octet-stream"
                                "Transfer-Encoding: chunked")
                     (%chunked (sb-ext:string-to-octets +big-chunk+) 1024))
      (is (eql 200 status))
      (is (null (get-header headers :client-content-length)))
      (is (eql (length +big-chunk+) (length body))))))

(test request-multi-headers
  "Clack suite, request-tests: \"multi headers (request)\". Deviates from Clack's case in being
stricter: Clack matches the regex ^bar,\\s*baz$; this compares the exact joined value. And in
its client: the two Foo fields are written over a raw socket, because WinHTTP, dexador's client
on Windows, sends only the last of them (see RAW-REQUEST)."
  (testing-app (port (lambda (env)
                       `(200 (:content-type "text/plain; charset=utf-8")
                             (,(gethash "foo" (getf env :headers))))))
    (is (equal "bar, baz" (raw-request port (list "GET / HTTP/1.1" "Host: 127.0.0.1"
                                                  "Foo: bar" "Foo: baz"))))))

(test request-a-big-header-value
  "Clack suite, request-tests: \"a big header value > 128 bytes\". Its header value is 96,000
octets, over server-uv's default *MAX-HEAD-OCTETS* of 65,536 (#375), so the case raises the
setting to 200,000 while it runs; the next test checks the default still refuses it. Deviates
from Clack's case in its client: the request is written over a raw socket, because WinHTTP,
dexador's client on Windows, refuses a header value this long (see RAW-REQUEST)."
  (let ((saved srv:*max-head-octets*))
    (setf srv:*max-head-octets* 200000)
    (unwind-protect
         (testing-app (port (lambda (env)
                              `(200 (:content-type "text/plain; charset=utf-8")
                                    (,(gethash "x-foo" (getf env :headers))))))
           (multiple-value-bind (body status)
               (raw-request port (list "GET / HTTP/1.1" "Host: 127.0.0.1"
                                       (concatenate 'string "X-Foo: " +big-chunk+)))
             (is (eql 200 status))
             (is (equal +big-chunk+ body))))
      (setf srv:*max-head-octets* saved))))

(test at-the-default-head-limit-a-big-header-value-is-431
  "Not a Clack case: the other half of the one above. At the default *MAX-HEAD-OCTETS* the same
request is refused with 431, which is the decision on #375. Written over a raw socket for the
reason the case above is."
  (is (= 65536 srv:*max-head-octets*))
  (testing-app (port (lambda (env) (declare (ignore env)) '(200 () ("never"))))
    (is (eql 431 (nth-value 1 (raw-request port (list "GET / HTTP/1.1" "Host: 127.0.0.1"
                                                      (concatenate 'string "X-Foo: " +big-chunk+))))))))

(test request-input-seekable
  "Clack suite, request-tests: \"request -> input seekable\"."
  (testing-app (port (lambda (env)
                       (let ((body (make-array 4 :element-type '(unsigned-byte 8))))
                         (read-sequence body (getf env :raw-body))
                         `(200 (:content-type "text/plain; charset=utf-8") (,(octets->string body))))))
    (is (equal "body" (dex:post (localhost port) :content "body")))))

(test request-handle-authorization-header
  "Clack suite, request-tests: \"handle Authorization header\"."
  (testing-app (port (lambda (env)
                       `(200 (:content-type "text/plain; charset=utf-8"
                              :x-authorization ,(not (null (gethash "authorization" (getf env :headers)))))
                             (,(gethash "authorization" (getf env :headers) "")))))
    (multiple-value-bind (body status headers)
        (dex:get (localhost port) :headers '(("Authorization" . "Basic XXXX")))
      (is (eql 200 status))
      (is (equal (string t) (get-header headers :x-authorization)))
      (is (equal "Basic XXXX" body)))
    (multiple-value-bind (body status headers) (dex:get (localhost port))
      (is (eql 200 status))
      (is (null (get-header headers :x-authorization)))
      (is (member body '(nil "") :test #'equal)))))

(test request-repeated-slashes
  "Clack suite, request-tests: \"repeated slashes\"."
  (testing-app (port (%echo :path-info))
    (multiple-value-bind (body status headers) (dex:get (localhost port "/foo///bar/baz"))
      (is (eql 200 status))
      (is (equal "text/plain; charset=utf-8" (get-header headers :content-type)))
      (is (equal "/foo///bar/baz" body)))))

(defun %upload-app ()
  "Answers \"ok\" when the request's raw body holds, in one piece, the octets of the file named
by its x-expect header, and \"ng\" otherwise."
  (lambda (env)
    (let* ((raw (read-all (getf env :raw-body)))
           (expected (file-octets (gethash "x-expect" (getf env :headers)))))
      `(200 (:content-type "text/plain") (,(if (search expected raw) "ok" "ng"))))))

(test request-file-upload
  "Clack suite, request-tests: \"file upload\". Deviates from Clack's case: Clack's app parses
the multipart body with http-body and compares the file part; this one checks that the file's
octets arrive intact inside the raw body. Delivering the octets is the server's job, and
parsing multipart is the application's or a library's, so this checks what the server does
without adding a multipart parser to the tree. The test also sends an X-Expect header naming
the file, so the app knows what to look for."
  (let ((file (fixture "file.txt" 25)))
    (testing-app (port (%upload-app))
      (multiple-value-bind (body status)
          (dex:post (localhost port) :headers `(("X-Expect" . ,(namestring file)))
                                     :content `(("file" . ,file)))
        (is (eql 200 status))
        (is (equal "ok" body))))))

(test request-large-file-upload
  "Clack suite, request-tests: \"large file upload\". Deviates from Clack's case as \"file
upload\" does, for the same reason: Clack's app compares the SHA-1 of the parsed file part
with the fixture's; this one checks that the fixture's octets arrive intact in the raw body."
  (let ((file (fixture "jellyfish.jpg" 139616)))
    (testing-app (port (%upload-app))
      (multiple-value-bind (body status)
          (dex:post (localhost port) :headers `(("X-Expect" . ,(namestring file)))
                                     :content `(("file" . ,file)))
        (is (eql 200 status))
        (is (equal "ok" body))))))

(test request-streaming
  "Clack suite, request-tests: \"streaming\". The suite runs this only for :hunchentoot, :toot,
:wookie and :woo, and skips it for :uv (ADR-0020), so here it runs."
  (testing-app (port (lambda (env)
                       (declare (ignore env))
                       (lambda (res)
                         (let ((writer (funcall res '(200 (:content-type "text/plain")))))
                           (loop for i from 0 to 2
                                 do (sleep 1)
                                    (funcall writer (format nil "~S~%" i)))
                           (funcall writer "" :close t)))))
    (multiple-value-bind (body status) (dex:get (localhost port))
      (is (eql 200 status))
      (is (equal (format nil "0~%1~%2~%") body)))))

;;; --- debug-tests ---------------------------------------------------------------

(test debug-do-not-crash-when-the-app-dies
  "Clack suite, debug-tests: \"Do not crash when the app dies\"."
  (let ((*error-output* (make-broadcast-stream)))
    (testing-app (port (lambda (env) (declare (ignore env))
                         (error "Throwing an exception from app handler. Server shouldn't crash."))
                       :debug nil)
      (is (eql 500 (%status-of (lambda () (dex:get (localhost port))))))
      (is (eql 500 (%status-of (lambda () (dex:get (localhost port)))))
          "and the server still answers the next request"))))

;;; --- not Clack cases: the delayed response and the adapter --------------------

(test a-delayed-response-may-give-the-whole-response-at-once
  (testing-app (port (lambda (env)
                       (declare (ignore env))
                       (lambda (respond)
                         (funcall respond '(201 (:content-type "text/plain" :x-none nil) ("made"))))))
    (multiple-value-bind (body status headers) (dex:post (localhost port))
      (is (eql 201 status))
      (is (equal "made" body))
      (is (null (nth-value 1 (gethash "x-none" headers))) "a header whose value is NIL is not sent"))))

(test a-writer-honours-start-and-end-and-takes-octets
  (testing-app (port (lambda (env)
                       (declare (ignore env))
                       (lambda (respond)
                         (let ((writer (funcall respond '(200 (:content-type "text/plain")))))
                           (funcall writer "xxabcxx" :start 2 :end 5)
                           (funcall writer (sb-ext:string-to-octets "de") :close t)))))
    (is (equal "abcde" (dex:get (localhost port))))))

(test a-delayed-response-that-fails-before-its-head-is-a-500
  (let ((*error-output* (make-broadcast-stream)))
    (testing-app (port (lambda (env)
                         (declare (ignore env))
                         (lambda (respond)
                           (declare (ignore respond))
                           (error "the app failed before responding"))))
      (is (eql 500 (%status-of (lambda () (dex:get (localhost port)))))))))

(test worker-num-is-accepted-as-woos-handler-takes-it
  "(clackup app :server :woo :worker-num n) runs unchanged with :server :uv."
  (testing-app (port (lambda (env) (declare (ignore env)) '(200 (:content-type "text/plain") ("ok")))
                     :worker-num 2)
    (is (equal "ok" (dex:get (localhost port))))))

(test clack-stop-leaves-no-listener
  "CLACK:STOP destroys the thread RUN blocks in; RUN stops server-uv on the way out."
  (let* ((port (%free-port))
         (handler (clack:clackup (lambda (env) (declare (ignore env)) '(200 () ("ok")))
                                 :server :uv :port port :use-thread t :silent t)))
    (loop repeat 100 until (%listening-p port) do (sleep 0.05))
    (is-true (%listening-p port))
    (clack:stop handler)
    (loop repeat 100 while (%listening-p port) do (sleep 0.05))
    (is-false (%listening-p port))))

(defun %stop-during-start-check (&rest clackup-args)
  "A CLACK:STOP that arrives while RUN is still starting the server still stops it (#444). The
port listens before SUV:START returns, and a thread kill landing between that and RUN's
UNWIND-PROTECT used to leave the server running. The window is widened here: SUV:START is
wrapped to pause 0.3 s after it returns, and the thread is stopped as soon as the port
listens, which lands the kill inside the pause. Any server that is left running is stopped
at the end, so a failure does not leave a listener for later tests. CLACKUP-ARGS go to
CLACK:CLACKUP, for the same check with several loops."
  (let* ((port (%free-port))
         (started (list nil))
         (handler nil))
    (sb-int:encapsulate 'srv:start 'slow-start
                        (lambda (f &rest args)
                          (let ((server (apply f args)))
                            (setf (car started) server)
                            (sleep 0.3)
                            server)))
    (unwind-protect
         (progn
           (setf handler (apply #'clack:clackup (lambda (env) (declare (ignore env)) '(200 () ("ok")))
                                :server :uv :port port :use-thread t :silent t clackup-args))
           (loop repeat 200 until (%listening-p port) do (sleep 0.005))
           (is-true (%listening-p port))
           (clack:stop handler)
           (loop repeat 100 while (%listening-p port) do (sleep 0.05))
           (is-false (%listening-p port) "the server started while CLACK:STOP arrived is still listening"))
      (sb-int:unencapsulate 'srv:start 'slow-start)
      (when (car started) (ignore-errors (srv:stop (car started)))))))

(test clack-stop-as-soon-as-the-port-listens-leaves-no-listener
  (%stop-during-start-check))

#-win32
(test clack-stop-as-soon-as-the-port-listens-leaves-no-listener-on-any-of-four-loops
  "The same with four loops (#463). Under :SHARED, the default on macOS, every loop listens on a
copy of one socket, and under :REUSEPORT each has its own: the port stops answering only when
every loop's listener is closed."
  (%stop-during-start-check :loops 4))

#-win32
(test clack-stop-leaves-no-listener-on-any-of-four-loops
  "CLACK:STOP on a handler running four loops closes every loop's listener and ends every loop's
thread (#463)."
  (let* ((loop-threads (lambda ()
                         (count-if (lambda (th) (uiop:string-prefix-p "aion/uv loop" (sb-thread:thread-name th)))
                                   (sb-thread:list-all-threads))))
         (before (funcall loop-threads))
         (port (%free-port))
         (handler (clack:clackup (lambda (env) (declare (ignore env)) '(200 () ("ok")))
                                 :server :uv :port port :use-thread t :silent t :loops 4)))
    (loop repeat 100 until (%listening-p port) do (sleep 0.05))
    (is-true (%listening-p port))
    ;; No Content-Type in the response, so dexador returns the body as octets.
    (is (equal "ok" (let ((body (dex:get (localhost port))))
                      (if (stringp body) body (sb-ext:octets-to-string body)))))
    (clack:stop handler)
    (loop repeat 100 while (%listening-p port) do (sleep 0.05))
    (is-false (%listening-p port))
    (loop repeat 100 until (= before (funcall loop-threads)) do (sleep 0.05))
    (is (= before (funcall loop-threads)) "~D loop threads before, ~D after CLACK:STOP"
        before (funcall loop-threads))))

(test the-path-is-percent-decoded-as-utf-8
  (is (equal "/foo/bar,baz" (uvh::%decode-path "/foo/bar%2cbaz")))
  (is (equal "/foo/bar%2cbaz" (uvh::%decode-path "/foo/bar%252cbaz")) "decoded once, not twice")
  (is (equal (format nil "/~C~C" (code-char #x3042) #\Replacement_Character)
             (uvh::%decode-path "/%E3%81%82%BF")) "an invalid sequence becomes U+FFFD")
  (is (equal "/50%" (uvh::%decode-path "/50%")) "a % without two hex digits is kept")
  (is (equal "/%zz" (uvh::%decode-path "/%zz"))))

(test the-host-header-gives-the-server-name
  (is (equal "example.test" (uvh::%host-name "example.test:8080" "d")))
  (is (equal "example.test" (uvh::%host-name "example.test" "d")))
  (is (equal "::1" (uvh::%host-name "[::1]:8080" "d")))
  (is (equal "d" (uvh::%host-name nil "d"))))
