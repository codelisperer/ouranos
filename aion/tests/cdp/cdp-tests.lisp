;;;; cdp-tests.lisp --- aion/cdp without a browser (#1028).
;;;;
;;;; The command line and its refusals, finding a browser, and the connection: a CDP server
;;;; written here answers over a real loopback socket, so the handshake, the routing of answers
;;;; by id, errors, timeouts, events and the end of a connection are tested on every machine,
;;;; browser or not. The server's frames are parsed with aion/websocket in server mode, and its
;;;; handshake is checked with aion/websocket's CHECK-HANDSHAKE, the server's half, which the
;;;; client code does not use.

(cl:defpackage #:aion/cdp/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:cdp #:aion/cdp)
                    (#:ws #:aion/websocket)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:run-tests))

(in-package #:aion/cdp/tests)

(def-suite cdp :description "aion/cdp: the browser driver (#1028).")
(in-suite cdp)

(defun run-tests ()
  "Run the suite; return T on success (for asdf:test-system)."
  (run! 'cdp))

;;; --- the command line -------------------------------------------------------------

(defparameter +keychain+
  '(#+darwin "--use-mock-keychain" #+linux "--password-store=basic")
  "Written out here rather than read from the driver, so a change to them shows in this file.")

(defparameter +default-debugging-switch+ "--remote-debugging-pipe"
  "The pipe, on Linux, macOS and Windows (#1028, step (c)).")

(test the-command-line-is-headless-with-a-fresh-profile-and-the-pipe-by-default
  (is (equal `("/b/chrome" "--lang=en"
               "--headless=new" ,+default-debugging-switch+ "--user-data-dir=/tmp/p"
               "--no-first-run" "--no-default-browser-check" ,@+keychain+ "about:blank")
             (cdp:browser-command-line "/b/chrome" "/tmp/p" :arguments '("--lang=en"))))
  (is (equal `("/b/chrome"
               "--headless=new" "--remote-debugging-port=0" "--user-data-dir=/tmp/p"
               "--no-first-run" "--no-default-browser-check" ,@+keychain+ "about:blank")
             (cdp:browser-command-line "/b/chrome" "/tmp/p" :transport :port)))
  (is (equal `("/b/chrome"
               "--headless=new" "--remote-debugging-pipe" "--user-data-dir=/tmp/p"
               "--no-first-run" "--no-default-browser-check" ,@+keychain+ "about:blank")
             (cdp:browser-command-line "/b/chrome" "/tmp/p" :transport :pipe)))
  (signals error (cdp:browser-command-line "/b/chrome" "/tmp/p" :transport :socket))
  #+darwin (is (member "--use-mock-keychain" (cdp:browser-command-line "/b/c" "/p") :test #'equal)
               "on macOS the browser never opens the real Keychain")
  #+linux (is (member "--password-store=basic" (cdp:browser-command-line "/b/c" "/p") :test #'equal)
              "on Linux the browser never asks the desktop keyring"))

(test arguments-that-would-change-headless-the-port-or-the-profile-are-refused
  (dolist (argument '("--headless" "--headless=old" "--HEADLESS=old" "-headless" "--headless=false"
                      "--remote-debugging-port=9222" "--remote-debugging-pipe"
                      "--remote-debugging-address=0.0.0.0" "--user-data-dir=/home/me/.config/chrome"
                      "--profile-directory=Default" "--password-store=gnome-libsecret" "--"))
    (signals error (cdp:check-browser-arguments (list "--lang=en" argument))
      "~S" argument))
  (signals error (cdp:check-browser-arguments "--lang=en") "a string, not a list")
  (signals error (cdp:check-browser-arguments '(:headless)) "a keyword, not a string")
  (signals error (cdp:browser-command-line "/b/chrome" "/tmp/p" :arguments '("--headless=old"))))

(test other-arguments-are-allowed
  (let ((ok '("--lang=en" "--window-size=800,600" "--disable-gpu" "https://example.com/"
              "--force-color-profile=srgb")))
    (is (equal ok (cdp:check-browser-arguments ok)))))

(test launch-browser-checks-its-arguments-before-anything-else
  (signals error (cdp:launch-browser :executable "/no/such/browser" :arguments '("--headless=old")))
  (handler-case (progn (cdp:launch-browser :executable "/no/such/browser" :arguments '("--headless=old"))
                       (fail "no error"))
    (cdp:browser-not-found () (fail "the executable was looked for before the arguments were checked"))
    (error () (pass))))

(test launch-browser-names-a-missing-executable
  (signals cdp:browser-not-found (cdp:launch-browser :executable "/no/such/browser")))

(test launch-browser-refuses-an-unknown-transport
  (signals error (cdp:launch-browser :executable "/no/such/browser" :transport :socket))
  ;; Both transports are accepted on every platform, so the missing executable is what is reported.
  (signals cdp:browser-not-found
    (cdp:launch-browser :executable "/no/such/browser" :transport :pipe)))

(defmacro with-env ((&rest names-and-values) &body body)
  "Run BODY with each environment variable set to its value (\"\" for unset), restoring them."
  (let ((saved (gensym)))
    `(let ((,saved (list ,@(loop for (name) on names-and-values by #'cddr
                                 collect `(cons ,name (or (uiop:getenv ,name) ""))))))
       (unwind-protect
            (progn ,@(loop for (name value) on names-and-values by #'cddr
                           collect `(setf (uiop:getenv ,name) ,value))
                   ,@body)
         (loop for (name . value) in ,saved do (setf (uiop:getenv name) value))))))

(test find-browser-reads-ouranos-browser-then-hyperion-smoke-browser
  (with-env ("OURANOS_BROWSER" "/first" "HYPERION_SMOKE_BROWSER" "/second")
    (is (equal "/first" (cdp:find-browser))))
  (with-env ("OURANOS_BROWSER" "" "HYPERION_SMOKE_BROWSER" "/second")
    (is (equal "/second" (cdp:find-browser)) "an empty OURANOS_BROWSER counts as unset")))

(test devtools-active-port-is-read-only-once-complete
  (let ((dir (aion/fs:make-temporary-directory "aion-cdp-test")))
    (unwind-protect
         (flet ((write-file (text)
                  (with-open-file (out (merge-pathnames "DevToolsActivePort" dir)
                                       :direction :output :if-exists :supersede)
                    (write-string text out))))
           (is (null (aion/cdp::%read-active-port dir)) "no file yet")
           (write-file (format nil "41234~%"))
           (is (null (aion/cdp::%read-active-port dir)) "the port, but no path yet")
           (write-file (format nil "41234~%/devtools/browser/abc-123~%"))
           (is (equal '(41234 "/devtools/browser/abc-123")
                      (multiple-value-list (aion/cdp::%read-active-port dir))))
           (write-file (format nil "0~%/devtools/browser/x~%"))
           (is (null (aion/cdp::%read-active-port dir)) "port 0 is not a port"))
      (aion/fs:delete-tree dir))))

(test only-loopback-addresses-are-accepted
  (is (equalp #(127 0 0 1) (aion/cdp::%loopback-address "127.0.0.1")))
  (is (equalp #(127 0 0 1) (aion/cdp::%loopback-address "localhost")))
  (is (equalp #(127 1 2 3) (aion/cdp::%loopback-address "127.1.2.3")))
  (dolist (host '("10.0.0.1" "0.0.0.0" "example.com" "127.0.0" "127.0.0.256" "127.0.0.1.5"
                  "::1" "" "128.0.0.1"))
    (is (null (aion/cdp::%loopback-address host)) "~S" host))
  (signals error (cdp:attach-browser "ws://example.com:9222/devtools/browser/x"))
  (signals error (cdp:attach-browser "ws://10.0.0.1:9222/devtools/browser/x"))
  (signals error (cdp:attach-browser "http://127.0.0.1:9222/json/version"))
  (signals error (cdp:attach-browser "ws://127.0.0.1/devtools/browser/x") "no port"))

(test json-helpers
  (let ((o (jzon:parse "{\"a\": {\"b\": [10, 20, null]}, \"f\": false}")))
    (is (= 20 (cdp:json-get o "a" "b" 1)))
    (is (null (cdp:json-get o "a" "b" 2)) "null reads as NIL")
    (is (null (cdp:json-get o "a" "b" 3)) "past the end")
    (is (null (cdp:json-get o "a" "c" 0)) "a missing key")
    (is (null (cdp:json-get o "f"))))
  (is (equal "{\"x\":1,\"y\":true,\"z\":false,\"n\":null,\"v\":[1,2]}"
             (jzon:stringify (cdp:json-object "x" 1 "y" t "z" nil "n" :null "v" #(1 2))))))

;;; --- a CDP server written here ------------------------------------------------------
;;;
;;; It accepts one connection, checks the handshake with the server's CHECK-HANDSHAKE, and then
;;; answers each command with what HANDLER returns: a list of messages (JSON objects) to send,
;;; in order, so a test can put events before or after an answer, or send nothing.

(defstruct fake
  listener port thread
  (received '())                      ; methods received, newest first
  (pongs 0)
  (lock (sb-thread:make-mutex))
  handler
  (accept-key-function #'ws:accept-key))

(defun %octets-of (string) (sb-ext:string-to-octets string :external-format :latin-1))

(defun %send-server-frame (socket opcode payload)
  (let ((octets (ws:encode-frame opcode payload)))
    (sb-bsd-sockets:socket-send socket octets (length octets))))

(defun %read-head (socket)
  "Read octets from SOCKET until the end of an HTTP head; return the head as text."
  (let ((buf (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer t))
        (chunk (make-array 4096 :element-type '(unsigned-byte 8))))
    (loop
      (multiple-value-bind (data n) (sb-bsd-sockets:socket-receive socket chunk nil)
        (declare (ignore data))
        ;; A count the chunk cannot hold is a failed receive (Windows; see %READ-LOOP).
        (unless (and (integerp n) (<= 1 n (length chunk))) (return nil))
        (loop for i below n do (vector-push-extend (aref chunk i) buf))
        (let ((end (search #(13 10 13 10) buf)))
          (when end (return (map 'string #'code-char (subseq buf 0 end)))))))))

(defun %serve (fake client)
  (let* ((head (%read-head client))
         (lines (uiop:split-string head :separator (string #\Newline)))
         (headers (make-hash-table :test #'equal)))
    (dolist (l (rest lines))
      (let* ((l (string-right-trim (string #\Return) l))
             (colon (position #\: l)))
        (when colon
          (setf (gethash (string-downcase (subseq l 0 colon)) headers)
                (string-trim " " (subseq l (1+ colon)))))))
    (multiple-value-bind (verdict key)
        (ws:check-handshake (if (search "GET " (first lines)) :get :other) :http/1.1 headers)
      (unless (eq verdict :accept) (return-from %serve))
      (let ((answer (format nil "HTTP/1.1 101 Switching Protocols~C~CUpgrade: websocket~C~CConnection: Upgrade~C~CSec-WebSocket-Accept: ~A~C~C~C~C"
                            #\Return #\Newline #\Return #\Newline #\Return #\Newline
                            (funcall (fake-accept-key-function fake) key)
                            #\Return #\Newline #\Return #\Newline)))
        (sb-bsd-sockets:socket-send client (%octets-of answer) (length answer))))
    (let ((buf (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer t))
          (chunk (make-array 65536 :element-type '(unsigned-byte 8)))
          (assembler (ws:make-assembler)))
      (loop
        (multiple-value-bind (data n) (sb-bsd-sockets:socket-receive client chunk nil)
          (declare (ignore data))
          (unless (and (integerp n) (<= 1 n (length chunk))) (return))
          (loop for i below n do (vector-push-extend (aref chunk i) buf)))
        (loop
          (let ((octets (coerce buf '(simple-array (unsigned-byte 8) (*)))))
            (multiple-value-bind (outcome frame next) (ws:parse-frame octets :masked t)
              (unless (eq outcome :frame) (return))
              (let ((rest (subseq octets next)))
                (setf (fill-pointer buf) 0)
                (loop for o across rest do (vector-push-extend o buf)))
              (multiple-value-bind (kind a) (ws:assemble assembler frame)
                (case kind
                  (:pong (sb-thread:with-mutex ((fake-lock fake)) (incf (fake-pongs fake))))
                  (:close (ignore-errors (%send-server-frame client ws:+close+ (ws:encode-close-payload 1000)))
                   (return-from %serve))
                  (:text
                   (let* ((message (jzon:parse a))
                          (method (gethash "method" message)))
                     (sb-thread:with-mutex ((fake-lock fake)) (push method (fake-received fake)))
                     (dolist (out (funcall (fake-handler fake) fake client message))
                       (if (eq out :close)
                           (%send-server-frame client ws:+close+ (ws:encode-close-payload 1001 "going"))
                           (%send-server-frame client ws:+text+
                                               (ws:encode-utf8 (jzon:stringify out))))))))))))))))

(defun answer (message &rest keys-and-values)
  "The answer to MESSAGE with a result object of KEYS-AND-VALUES."
  (cdp:json-object "id" (gethash "id" message) "result" (apply #'cdp:json-object keys-and-values)))

(defun session-event (method &rest keys-and-values)
  (cdp:json-object "method" method "sessionId" "S1" "params" (apply #'cdp:json-object keys-and-values)))

(defun default-handler (fake client message)
  (declare (ignore fake client))
  (let ((method (gethash "method" message))
        (params (gethash "params" message)))
    (cond
      ((string= method "Browser.getVersion") (list (answer message "product" "Fake/1.0")))
      ((string= method "Target.createTarget") (list (answer message "targetId" "T1")))
      ((string= method "Target.attachToTarget") (list (answer message "sessionId" "S1")))
      ((string= method "Test.error")
       (list (cdp:json-object "id" (gethash "id" message)
                              "error" (cdp:json-object "code" -32000 "message" "boom"))))
      ((string= method "Test.silent") '())
      ((string= method "Test.close") (list :close))
      ((string= method "Test.events")
       (list (session-event "Runtime.consoleAPICalled" "type" "log" "n" 1)
             (session-event "Log.entryAdded" "n" 2)
             (answer message)
             (session-event "Network.requestWillBeSent" "n" 3)))
      ((string= method "Page.navigate")
       (if (string= (gethash "url" params) "http://refused.invalid/")
           (list (answer message "frameId" "F" "errorText" "net::ERR_CONNECTION_REFUSED"))
           (list (answer message "frameId" "F" "loaderId" "L2")
                 (session-event "Page.lifecycleEvent" "name" "load" "loaderId" "L1")
                 (session-event "Page.lifecycleEvent" "name" "DOMContentLoaded" "loaderId" "L2")
                 (session-event "Page.lifecycleEvent" "name" "load" "loaderId" "L2"))))
      ((string= method "Runtime.evaluate")
       (let ((expression (gethash "expression" params)))
         (cond ((string= expression "throw")
                (list (answer message "result" (cdp:json-object "type" "object")
                              "exceptionDetails" (cdp:json-object "text" "Uncaught"
                                                                  "exception" (cdp:json-object "description" "Error: no")))))
               (t (list (answer message "result" (cdp:json-object "type" "number" "value" 42)))))))
      (t (list (answer message))))))

(defun start-fake (&key (handler #'default-handler) (accept-key-function #'ws:accept-key))
  (let* ((listener (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
         (fake (make-fake :listener listener :handler handler
                          :accept-key-function accept-key-function)))
    (setf (sb-bsd-sockets:sockopt-reuse-address listener) t)
    (sb-bsd-sockets:socket-bind listener #(127 0 0 1) 0)
    (sb-bsd-sockets:socket-listen listener 1)
    (setf (fake-port fake) (nth-value 1 (sb-bsd-sockets:socket-name listener)))
    (setf (fake-thread fake)
          (sb-thread:make-thread
           (lambda ()
             (let ((client (ignore-errors (sb-bsd-sockets:socket-accept listener))))
               (when client
                 (unwind-protect (ignore-errors (%serve fake client))
                   (ignore-errors (sb-bsd-sockets:socket-close client))))))
           :name "aion/cdp test server"))
    fake))

(defun stop-fake (fake)
  (ignore-errors (sb-bsd-sockets:socket-close (fake-listener fake)))
  (ignore-errors (sb-thread:join-thread (fake-thread fake) :timeout 5 :default nil)))

(defun fake-url (fake) (format nil "ws://127.0.0.1:~D/devtools/browser/fake" (fake-port fake)))

(defmacro with-fake ((fake browser &rest keys) &body body)
  `(let* ((,fake (start-fake ,@keys))
          (,browser nil))
     (unwind-protect
          (progn (setf ,browser (cdp:attach-browser (fake-url ,fake) :timeout 5))
                 ,@body)
       (when ,browser (cdp:close-browser ,browser))
       (stop-fake ,fake))))

(test attach-completes-the-handshake-and-reads-the-version
  (with-fake (fake browser)
    (is (equal "Fake/1.0" (cdp:browser-version browser)))
    (is (not (cdp:browser-launched-p browser)))
    (is (null (cdp:browser-pid browser)))))

(test a-refused-handshake-is-reported
  (let ((fake (start-fake :accept-key-function (lambda (key) (declare (ignore key))
                                                 "AAAAAAAAAAAAAAAAAAAAAAAAAAA="))))
    (unwind-protect
         (handler-case (progn (cdp:attach-browser (fake-url fake) :timeout 5) (fail "attached"))
           (cdp:connection-closed (e)
             (is (search "Sec-WebSocket-Accept" (princ-to-string e)))))
      (stop-fake fake))))

(test answers-errors-and-timeouts
  (with-fake (fake browser)
    (is (equal "Fake/1.0" (cdp:json-get (cdp:send browser "Browser.getVersion") "product")))
    (handler-case (progn (cdp:send browser "Test.error") (fail "no error"))
      (cdp:cdp-error (e)
        (is (= -32000 (cdp:cdp-error-code e)))
        (is (equal "boom" (cdp:cdp-error-message e)))
        (is (equal "Test.error" (cdp:cdp-error-method e)))))
    (signals cdp:cdp-timeout (cdp:send browser "Test.silent" :timeout 0.3))
    (is (equal "Fake/1.0" (cdp:json-get (cdp:send browser "Browser.getVersion") "product"))
        "the connection still works after a timeout")))

(test a-timed-out-wait-still-holds-the-state-lock
  "SB-THREAD:CONDITION-WAIT gives up the lock when it times out. %WAIT-ON must take it back, or the
caller's next wait or its WITH-MUTEX acts on a lock it does not hold."
  (let* ((connection (cdp::%make-connection nil "test"))
         (lock (cdp::connection-lock connection)))
    (sb-thread:with-mutex (lock)
      (let ((results (loop repeat 50
                           collect (list (cdp::%wait-on connection 0.0001)
                                         (sb-thread:holding-mutex-p lock)))))
        (is (every #'null (mapcar #'first results)) "nothing woke it, so each wait timed out")
        (is (every #'second results) "the lock is held after every timed-out wait")))
    (is (not (sb-thread:holding-mutex-p lock)) "WITH-MUTEX released it on the way out")))

(test events-reach-their-page-in-order-and-drain
  (with-fake (fake browser)
    (let ((page (cdp:new-page browser :timeout 5)))
      (cdp:drain-events page)
      (cdp:send page "Test.events")
      ;; The last event follows the answer, so wait for it rather than assume it has arrived.
      (let ((methods (loop with events = '()
                           repeat 100
                           do (setf events (append events (cdp:drain-events page)))
                           until (>= (length events) 3)
                           do (sleep 0.02)
                           finally (return (mapcar #'cdp:event-method events)))))
        (is (equal '("Runtime.consoleAPICalled" "Log.entryAdded" "Network.requestWillBeSent")
                   methods)))
      (is (null (cdp:drain-events page)) "a drained buffer is empty"))))

(test navigate-waits-for-the-load-of-its-own-document
  (with-fake (fake browser)
    (let ((page (cdp:new-page browser :timeout 5)))
      (is (null (cdp:navigate page "http://example.test/" :timeout 5)))
      (signals cdp:cdp-error (cdp:navigate page "http://refused.invalid/" :timeout 5)))))

(test evaluate-returns-values-and-signals-exceptions
  (with-fake (fake browser)
    (let ((page (cdp:new-page browser :timeout 5)))
      (is (= 42 (cdp:evaluate page "6 * 7")))
      (handler-case (progn (cdp:evaluate page "throw") (fail "no error"))
        (cdp:evaluation-error (e) (is (equal "Error: no" (cdp:cdp-error-message e))))))))

(test pings-are-answered
  (with-fake (fake browser
                   :handler (lambda (fake client message)
                              (declare (ignore fake))
                              (%send-server-frame client ws:+ping+ (%octets-of "p"))
                              (default-handler nil client message)))
    (cdp:send browser "Browser.getVersion")
    (loop repeat 100 until (plusp (fake-pongs fake)) do (sleep 0.02))
    (is (plusp (fake-pongs fake)))))

(test a-closed-connection-fails-the-next-command
  (with-fake (fake browser)
    (signals cdp:connection-closed (cdp:send browser "Test.close" :timeout 5))
    (signals cdp:connection-closed (cdp:send browser "Browser.getVersion" :timeout 5))))

(test closing-an-attached-browser-closes-its-pages-and-not-the-browser
  (with-fake (fake browser)
    (cdp:new-page browser :timeout 5)
    (cdp:close-browser browser)
    (cdp:close-browser browser)
    (let ((received (sb-thread:with-mutex ((fake-lock fake)) (reverse (fake-received fake)))))
      (is (member "Target.closeTarget" received :test #'equal))
      (is (not (member "Browser.close" received :test #'equal))))))
