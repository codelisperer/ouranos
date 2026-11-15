;;;; clack-handler-uv-websocket-tests.lisp --- websocket-driver's server on :uv (#376).
;;;;
;;;; websocket-driver is the WebSocket library Clack apps use. Its server writes to the socket
;;;; a Clack handler supplies as :CLACK.IO, so these tests run an ordinary websocket-driver app
;;;; with (clack:clackup app :server :uv) and talk to it with the minimal client of server-uv's
;;;; own WebSocket suite, over a real socket. websocket-driver is a dependency of this suite
;;;; only.

(in-package #:hyperion/clack-handler-uv/tests)

(in-suite clack-handler-uv)

(defun %wsd-app (log)
  "A websocket-driver echo app, as its README writes one, noting each event in LOG (a list in
a cons, guarded by a mutex in its CDR's first element)."
  (lambda (env)
    (if (string= (getf env :path-info) "/http")
        '(200 (:content-type "text/plain") ("plain"))
        (let ((ws (wsd:make-server env)))
          (flet ((note (entry)
                   (sb-thread:with-mutex ((cdr log)) (push entry (car log)))))
            (wsd:on :open ws (lambda () (note '(:open))))
            (wsd:on :message ws (lambda (message)
                                  (note (list :message message))
                                  (if (equal message "close")
                                      (wsd:close-connection ws "asked" 4000)
                                      (wsd:send ws message))))
            (wsd:on :close ws (lambda (&key code reason) (note (list :close code reason)))))
          (lambda (responder)
            (declare (ignore responder))
            (wsd:start-connection ws))))))

(defun %make-wsd-log () (cons '() (sb-thread:make-mutex :name "wsd test log")))

(defun %wsd-entries (log)
  (sb-thread:with-mutex ((cdr log)) (reverse (car log))))

(defun %wsd-entry (log kind)
  (find kind (%wsd-entries log) :key #'first))

(test websocket-driver-echoes-text-and-binary-on-uv
  (let ((log (%make-wsd-log)))
    (testing-app (port (%wsd-app log))
      (wsc:with-client (c port)
        (let ((head (wsc:client-head c)))
          (is (= 101 (wsc:status-of head)))
          ;; The head is websocket-driver's own: server-uv wrote none.
          (is (equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" (wsc:header-of head "Sec-WebSocket-Accept"))))
        (is-true (wsc:wait-until (lambda () (%wsd-entry log :open))))
        (wsc:send-frame c 1 (wsc:utf8 "hello from the client"))
        (let ((f (wsc:read-frame c)))
          (is (= 1 (first f)))
          (is (equalp (wsc:utf8 "hello from the client") (second f))))
        (wsc:send-frame c 2 (wsc:octets 1 2 3 250))
        (let ((f (wsc:read-frame c)))
          (is (= 2 (first f)))
          (is (equalp (wsc:octets 1 2 3 250) (second f))))
        ;; websocket-driver answers a ping itself.
        (wsc:send-frame c 9 (wsc:utf8 "p"))
        (let ((f (wsc:read-frame c)))
          (is (= 10 (first f)))
          (is (equalp (wsc:utf8 "p") (second f))))
        ;; The client closes; websocket-driver answers with a close frame.
        (wsc:send-frame c 8 (wsc:close-payload 1000 "bye"))
        (let ((f (wsc:read-frame c)))
          (is (= 8 (first f)))
          (is (= 1000 (wsc:close-code-of f))))))
    (is (equal '(:message "hello from the client") (%wsd-entry log :message)))))

(test websocket-driver-closes-and-closes-the-socket-on-uv
  ;; The server starts the close: websocket-driver sends its close frame and calls
  ;; CLOSE-SOCKET, which must close the TCP connection after the frame has been written.
  (let ((log (%make-wsd-log)))
    (testing-app (port (%wsd-app log))
      (wsc:with-client (c port)
        (wsc:send-frame c 1 (wsc:utf8 "close"))
        (let ((f (wsc:read-frame c)))
          (is (= 8 (first f)))
          (is (= 4000 (wsc:close-code-of f))))
        (wsc:send-frame c 8 (wsc:close-payload 4000))
        ;; websocket-driver closes the socket once its close frame is written, without
        ;; waiting for the answer, and emits no :CLOSE for a close it started, on Woo as here.
        (is-true (wsc:eof-p c))))))

(test websocket-driver-refuses-an-unmasked-frame-on-uv
  (let ((log (%make-wsd-log)))
    (testing-app (port (%wsd-app log))
      (wsc:with-client (c port)
        (is-true (wsc:wait-until (lambda () (%wsd-entry log :open))))
        (wsc:send-frame c 1 (wsc:utf8 "x") :mask nil)
        ;; websocket-driver's parser, fast-websocket, refuses it with 1003, where
        ;; hyperion/server-uv/websocket sends 1002. The code is websocket-driver's choice; what
        ;; is tested here is that the frame reaches it through the socket and is refused.
        (let ((f (wsc:read-frame c)))
          (is (= 8 (first f)))
          (is (= 1003 (wsc:close-code-of f))))
        (is (null (%wsd-entry log :message)))))))

(test websocket-driver-sockets-do-not-stall-http-on-uv
  (let ((log (%make-wsd-log))
        (clients '()))
    (testing-app (port (%wsd-app log) :workers 4)
      (unwind-protect
           (progn
             (dotimes (i 50) (push (wsc:ws-connect port) clients))
             (is (every (lambda (c) (= 101 (wsc:status-of (wsc:client-head c)))) clients))
             (dotimes (i 5)
               (is (equal "plain" (dex:get (localhost port "/http")))))
             (dolist (c clients) (wsc:send-frame c 1 (wsc:utf8 "ping-pong")))
             (is (every (lambda (c) (equalp (wsc:utf8 "ping-pong") (second (wsc:read-frame c))))
                        clients)))
        (mapc #'wsc:client-close clients)))))

(test a-delayed-response-that-never-responds-and-claims-nothing-still-waits
  ;; The rule for taking the connection over is that the app's function returned AND wrote
  ;; to the socket or set its read callback. One that returns without either is still waiting
  ;; for a responder called later from another thread, as before #376.
  (testing-app (port (lambda (env)
                       (declare (ignore env))
                       (lambda (responder)
                         ;; INTERRUPTS: a test thread that sleeps briefly and responds; nothing interrupts it.
                         ;; THREAD-LIFETIME: ends after one response, well inside the test.
                         (sb-thread:make-thread
                          (lambda () (sleep 0.1) (funcall responder '(200 (:content-type "text/plain") ("later"))))
                          :name "clack-handler-uv test responder")
                         nil)))
    (is (equal "later" (dex:get (localhost port "/"))))))
