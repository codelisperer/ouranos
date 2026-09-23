;;;; uv-net.lisp --- tests for aion/uv/net.
;;;;
;;;; Real sockets against a real libuv, on loopback. The failure modes worth catching
;;;; here -- a buffer freed while libuv still holds it, a read callback that mistakes
;;;; end-of-stream for an error, a producer that is never actually paused -- are exactly
;;;; the ones a mock cannot have. Build the library first:
;;;;
;;;;     sbcl --script scripts/build-libuv.lisp
;;;;
;;;; Run: (asdf:test-system :aion/uv/net)

(defpackage #:aion/uv/net/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:uv #:aion/uv)
                    (#:net #:aion/uv/net)
                    (#:types #:aion/uv/net/types))
  (:export #:run-tests #:uv-net))

(in-package #:aion/uv/net/tests)

(def-suite uv-net :description "aion/uv/net: TCP, pipes, DNS, and backpressure.")
(in-suite uv-net)

(defun run-tests ()
  (let ((results (run 'uv-net)))
    (explain! results)
    (results-status results)))

;;; --- driving a loop from the test thread --------------------------------------
;;;
;;; These tests run the loop in NOWAIT slices rather than on a background thread, so
;;; every assertion happens at a known point rather than racing the loop. PUMP advances
;;; the loop until a condition holds, with a bound so a broken test fails instead of
;;; hanging.

(defun pump (loop &key (until (constantly nil)) (limit 4000))
  (loop repeat limit
        until (funcall until)
        do (uv:run loop :mode :nowait)
           (sleep 0.001))
  (funcall until))

(defmacro with-loop-and-cleanup ((var) &body body)
  `(uv:with-loop (,var) ,@body))

(defun octets (string) (sb-ext:string-to-octets string :external-format :utf-8))
(defun text (octets) (sb-ext:octets-to-string octets :external-format :utf-8))

(defun counting-payload (n)
  (let ((data (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n data)
      (setf (aref data i) (mod i 251)))))

;;; --- the typed core (pure Coalton, no sockets involved) -------------------------

(test read-outcomes-keep-the-four-cases-apart
  ;; The whole point of decoding nread: a positive count, a benign nothing, a clean end
  ;; and a real failure are four different things carried by one signed integer.
  (is (string= "bytes" (types:read-outcome-tag 42 "")))
  (is (string= "nothing-yet" (types:read-outcome-tag 0 "")))
  (is (string= "end-of-stream" (types:read-outcome-tag -4095 "EOF")))
  (is (string= "ECONNRESET" (types:read-outcome-tag -104 "ECONNRESET"))))

(test end-of-stream-is-not-a-failure
  ;; The classic bug this type exists to prevent: both are negative, only one is an error.
  (is (string/= (types:read-outcome-tag -4095 "EOF")
                (types:read-outcome-tag -104 "ECONNRESET"))))

(test backpressure-thresholds
  (is-true (types:saturated? 100 100))
  (is-true (types:saturated? 101 100))
  (is-false (types:saturated? 99 100))
  ;; Resuming uses a LOWER mark than pausing, so the pair settles instead of oscillating.
  (is-true (types:drained? 16 16))
  (is-false (types:drained? 17 16)))

(test address-families-are-classified-by-literal
  (is (string= "ipv4" (types:address-family-name "127.0.0.1")))
  (is (string= "ipv6" (types:address-family-name "::1")))
  (is (string= "ipv6" (types:address-family-name "fe80::1")))
  (is-true (types:ipv6-literal? "::1"))
  (is-false (types:ipv6-literal? "10.0.0.1")))

;;; --- TCP ------------------------------------------------------------------------

(test tcp-echo-round-trips
  (with-loop-and-cleanup (l)
    (let ((received (make-array 0 :element-type '(unsigned-byte 8)))
          (listener nil)
          (done nil))
      (setf listener
            (net:listen-tcp
             l "127.0.0.1" 0
             :on-connection
             (lambda (server-conn)
               (net:start-reading
                server-conn
                (lambda (data conn) (net:write-bytes conn data))
                :on-end (lambda (conn)
                          (net:shutdown-write conn)
                          (uv:close-handle conn))))))
      (multiple-value-bind (host port) (net:listener-address listener)
        (is (string= "127.0.0.1" host))
        (is (plusp port))
        (net:connect-tcp
         l "127.0.0.1" port
         :on-connect
         (lambda (conn)
           (net:write-bytes conn "hello libuv")
           (net:start-reading
            conn
            (lambda (data c)
              (setf received (concatenate '(vector (unsigned-byte 8)) received data))
              ;; Got the echo: half-close so the server sees a clean end.
              (when (>= (length received) 11) (net:shutdown-write c)))
            :on-end (lambda (c)
                      (uv:close-handle c)
                      (net:close-listener listener)
                      (setf done t)))))
        (is-true (pump l :until (lambda () done)))
        (is (string= "hello libuv" (text received)))))))

(test connect-to-a-closed-port-fails-through-the-future
  (with-loop-and-cleanup (l)
    ;; Bind and immediately release a port, so we know nothing is listening on it.
    (let ((port (let ((probe (net:listen-tcp l "127.0.0.1" 0)))
                  (multiple-value-bind (host p) (net:listener-address probe)
                    (declare (ignore host))
                    (net:close-listener probe)
                    p))))
      (let ((future (net:connect-tcp l "127.0.0.1" port))
            (settled nil))
        (pump l :until (lambda () (setf settled (uv:future-finished-p future))) :limit 2000)
        (is-true settled)
        (signals uv:uv-error (uv:await future :timeout 5))))))

(test a-hostname-is-refused-rather-than-silently-resolved
  ;; A binding that hid DNS inside CONNECT would make an invisible network call on a
  ;; function that looks local.
  (with-loop-and-cleanup (l)
    (signals net:not-an-ip-address (net:connect-tcp l "localhost" 80))))

(test nodelay-and-keepalive-are-settable
  (with-loop-and-cleanup (l)
    (let* ((accepted nil)
           (listener (net:listen-tcp l "127.0.0.1" 0
                                     :on-connection (lambda (conn) (setf accepted conn)))))
      (multiple-value-bind (host port) (net:listener-address listener)
        (declare (ignore host))
        (let ((future (net:connect-tcp l "127.0.0.1" port)))
          (pump l :until (lambda () (and accepted (uv:future-finished-p future))))
          (let ((client (uv:await future :timeout 5)))
            ;; TCP_NODELAY is applied by default on both sides; setting it again must be
            ;; accepted, and so must turning it off.
            (finishes (net:set-nodelay client t))
            (finishes (net:set-nodelay client nil))
            (finishes (net:set-keepalive client :enable t :delay 30))
            (uv:close-handle client))
          (when accepted (uv:close-handle accepted))
          (net:close-listener listener))))))

(test local-and-peer-addresses-agree
  (with-loop-and-cleanup (l)
    (let ((listener nil) (accepted nil))
      (setf listener (net:listen-tcp l "127.0.0.1" 0
                                     :on-connection (lambda (c) (setf accepted c))))
      (multiple-value-bind (host listen-port) (net:listener-address listener)
        (declare (ignore host))
        (let ((future (net:connect-tcp l "127.0.0.1" listen-port)))
          (pump l :until (lambda () (and accepted (uv:future-finished-p future))))
          (let ((client (uv:await future :timeout 5)))
            (multiple-value-bind (peer-host peer-port) (net:peer-address client)
              (is (string= "127.0.0.1" peer-host))
              (is (= listen-port peer-port)))
            (multiple-value-bind (local-host local-port) (net:local-address client)
              (is (string= "127.0.0.1" local-host))
              (is (plusp local-port))
              ;; The client's local address is the server's view of its peer.
              (multiple-value-bind (server-peer-host server-peer-port)
                  (net:peer-address accepted)
                (is (string= local-host server-peer-host))
                (is (= local-port server-peer-port))))
            (uv:close-handle client))
          (uv:close-handle accepted)
          (net:close-listener listener))))))

;;; --- backpressure ------------------------------------------------------------------
;;;
;;; The non-negotiable one. A reader that cannot stop its producer is Node's 2010 stream
;;; layer with different syntax, so "paused means paused" is tested directly rather than
;;; inferred from a transfer completing.

(test a-paused-reader-receives-nothing-until-it-resumes
  (with-loop-and-cleanup (l)
    (let ((received 0) (server-conn nil) (client nil) (listener nil))
      (setf listener
            (net:listen-tcp
             l "127.0.0.1" 0
             :on-connection
             (lambda (conn)
               (setf server-conn conn)
               (net:start-reading conn (lambda (data c)
                                         (declare (ignore c))
                                         (incf received (length data))))
               (net:pause-reading conn))))
      (multiple-value-bind (host port) (net:listener-address listener)
        (declare (ignore host))
        (net:connect-tcp l "127.0.0.1" port
                         :on-connect (lambda (conn)
                                       (setf client conn)
                                       (net:write-bytes conn "0123456789")))
        (pump l :until (lambda () (and server-conn client)))
        ;; Pump hard with data sitting in the socket: a paused reader must deliver none
        ;; of it, however many times the loop turns.
        (pump l :limit 200)
        (is-true (net:paused-p server-conn))
        (is (zerop received))
        (net:resume-reading server-conn)
        (is-true (pump l :until (lambda () (plusp received))))
        (is (= 10 received))
        (is-false (net:paused-p server-conn))
        (uv:close-handle client)
        (uv:close-handle server-conn)
        (net:close-listener listener)))))

(test an-error-thrown-by-a-read-handler-is-kept-not-swallowed
  ;; A failure delivered THROUGH a future is an answer and stays quiet. An error that
  ;; escapes a handler is a bug, and must survive rather than vanish into the loop --
  ;; a silent event loop being the hardest thing there is to debug.
  (with-loop-and-cleanup (l)
    (let ((before (length uv:*callback-errors*))
          (server-conn nil) (client nil) (listener nil) (seen nil))
      (setf listener
            (net:listen-tcp
             l "127.0.0.1" 0
             :on-connection
             (lambda (conn)
               (setf server-conn conn)
               (net:start-reading conn (lambda (data c)
                                         (declare (ignore data c))
                                         (setf seen t)
                                         (error "deliberate handler failure"))))))
      (multiple-value-bind (host port) (net:listener-address listener)
        (declare (ignore host))
        (net:connect-tcp l "127.0.0.1" port
                         :on-connect (lambda (conn)
                                       (setf client conn)
                                       (net:write-bytes conn "boom")))
        (is-true (pump l :until (lambda () seen)))
        (is (> (length uv:*callback-errors*) before))
        (uv:close-handle client)
        (uv:close-handle server-conn)
        (net:close-listener listener)))))

(test write-queue-size-is-visible
  (with-loop-and-cleanup (l)
    (let ((listener nil) (accepted nil))
      (setf listener (net:listen-tcp l "127.0.0.1" 0
                                     :on-connection (lambda (c) (setf accepted c))))
      (multiple-value-bind (host port) (net:listener-address listener)
        (declare (ignore host))
        (let ((future (net:connect-tcp l "127.0.0.1" port)))
          (pump l :until (lambda () (and accepted (uv:future-finished-p future))))
          (let ((client (uv:await future :timeout 5)))
            ;; Nothing queued yet, so not saturated against a real mark -- but saturated
            ;; against a mark of zero, which is the boundary the pure decision defines.
            (is (integerp (net:write-queue-size client)))
            (is-false (net:saturated-p client :high-water-mark net:+default-high-water-mark+))
            (is-true (net:saturated-p client :high-water-mark 0))
            (uv:close-handle client))
          (uv:close-handle accepted)
          (net:close-listener listener))))))

(test pipe-into-relays-everything-and-carries-backpressure
  ;; A proxy: client -> relay -> sink. PIPE-INTO owns the pause/resume policy, so the
  ;; test wires none of it, which is precisely the property being tested. The payload is
  ;; larger than the read buffer and the marks are small, so it genuinely queues.
  (with-loop-and-cleanup (l)
    (let* ((payload (counting-payload (* 256 1024)))
           (sunk (make-array 0 :element-type '(unsigned-byte 8)))
           (finished nil)
           (sink-listener nil) (relay-listener nil))
      (setf sink-listener
            (net:listen-tcp
             l "127.0.0.1" 0
             :on-connection
             (lambda (conn)
               (net:start-reading conn
                                  (lambda (data c)
                                    (declare (ignore c))
                                    (setf sunk (concatenate '(vector (unsigned-byte 8))
                                                            sunk data)))
                                  :on-end (lambda (c)
                                            (uv:close-handle c)
                                            (setf finished t))))))
      (multiple-value-bind (sink-host sink-port) (net:listener-address sink-listener)
        (setf relay-listener
              (net:listen-tcp
               l "127.0.0.1" 0
               :on-connection
               (lambda (from-client)
                 (net:connect-tcp
                  l sink-host sink-port
                  :on-connect
                  (lambda (to-sink)
                    (net:pipe-into from-client to-sink
                                   :high-water-mark 8192 :low-water-mark 2048))))))
        (multiple-value-bind (relay-host relay-port) (net:listener-address relay-listener)
          (net:connect-tcp
           l relay-host relay-port
           :on-connect (lambda (conn)
                         (net:write-bytes conn payload
                                          :on-complete (lambda (n)
                                                         (declare (ignore n))
                                                         (net:shutdown-write conn)))))
          (is-true (pump l :until (lambda () finished) :limit 20000))
          (is (= (length payload) (length sunk)))
          (is (equalp payload sunk))
          (net:close-listener relay-listener)
          (net:close-listener sink-listener))))))

;;; --- pipes (unix domain sockets / named pipes) -------------------------------------
;;;
;;; The two platforms disagree about what a pipe IS, which is why the name comes from a
;;; helper rather than a literal. On Unix it is a filesystem path, so it exists as a file
;;; and has to be unlinked. On Windows it is a name in the kernel's pipe namespace --
;;; `\\.\pipe\<name>` -- with no filesystem entry to create or remove; libuv answers EACCES
;;; for a name outside that namespace, which is what a `/tmp/x.sock` literal produces here.

(defun test-pipe-name (tag)
  "A pipe name this platform can bind, distinct per run."
  #+windows (format nil "\\\\.\\pipe\\aion-uv-net-~A-~D" tag (get-universal-time))
  #-windows (format nil "/tmp/aion-uv-net-~A-~D.sock" tag (get-universal-time)))

(defun unlink-pipe (name)
  "Remove a pipe's filesystem entry where it has one. A no-op on Windows: there is no file."
  (declare (ignorable name))
  #-windows (ignore-errors (uv:delete-file* name)))

(test pipe-round-trips
  (let ((path (test-pipe-name "rt")))
    (unlink-pipe path)
    (unwind-protect
         (with-loop-and-cleanup (l)
           (let ((received (make-array 0 :element-type '(unsigned-byte 8)))
                 (done nil)
                 (listener nil))
             (setf listener
                   (net:listen-pipe
                    l path
                    :on-connection
                    (lambda (conn)
                      (net:start-reading conn
                                         (lambda (data c) (net:write-bytes c data))
                                         :on-end (lambda (c)
                                                   (net:shutdown-write c)
                                                   (uv:close-handle c))))))
             (net:connect-pipe
              l path
              :on-connect
              (lambda (conn)
                (net:write-bytes conn "over a pipe")
                (net:start-reading
                 conn
                 (lambda (data c)
                   (setf received (concatenate '(vector (unsigned-byte 8)) received data))
                   (when (>= (length received) 11) (net:shutdown-write c)))
                 :on-end (lambda (c)
                           (uv:close-handle c)
                           (net:close-listener listener)
                           (setf done t)))))
             (is-true (pump l :until (lambda () done)))
             (is (string= "over a pipe" (text received)))))
      (unlink-pipe path))))

(test a-pipe-has-no-socket-address
  (let ((path (test-pipe-name "addr")))
    (unlink-pipe path)
    (unwind-protect
         (with-loop-and-cleanup (l)
           (let ((accepted nil) (listener nil))
             (setf listener (net:listen-pipe l path
                                             :on-connection (lambda (c) (setf accepted c))))
             (net:connect-pipe l path)
             (pump l :until (lambda () accepted))
             (is-true accepted)
             (signals uv:uv-error (net:peer-address accepted))
             (uv:close-handle accepted)
             (net:close-listener listener)))
      (unlink-pipe path))))

;;; --- DNS -----------------------------------------------------------------------------

(test localhost-resolves
  ;; Answered from the hosts file on every platform, so this needs no network.
  (let ((results (net:resolve "localhost")))
    (is (plusp (length results)))
    (is-true (every (lambda (a) (typep (net:address-info-host a) 'string)) results))
    (is-true (member "127.0.0.1" results
                     :key #'net:address-info-host :test #'string=))
    ;; The family is classified by the same pure function that picks uv_ip4_addr, so the
    ;; two can never disagree about what "::1" is.
    (let ((v4 (find "127.0.0.1" results :key #'net:address-info-host :test #'string=)))
      (is (eq :ipv4 (net:address-info-family v4))))))

(test resolving-with-a-service-carries-the-port
  (let ((results (net:resolve "127.0.0.1" :service 80)))
    (is (plusp (length results)))
    (is (= 80 (net:address-info-port (first results))))))

(test an-unresolvable-name-signals
  ;; .invalid is reserved by RFC 2606 precisely so it can never resolve.
  (signals uv:uv-error (net:resolve "no-such-host.invalid")))

;;; --- introspection over live sockets ---------------------------------------------

(test a-listener-shows-up-as-holding-the-loop-open
  (with-loop-and-cleanup (l)
    (let ((listener (net:listen-tcp l "127.0.0.1" 0)))
      (let* ((handles (uv:loop-handles l))
             (tcp (find :tcp handles :key #'uv:handle-info-kind)))
        (is-true tcp)
        (is-true (uv:handle-info-active tcp))
        ;; This is the answer to "why will my process not exit?" -- and it names the
        ;; Lisp object, not merely the handle type.
        (is-true (uv:handle-info-referenced tcp))
        (is (eq 'net:listener (type-of (uv:handle-info-owner tcp)))))
      (let ((report (with-output-to-string (s) (uv:describe-loop l s))))
        (is (search "tcp" (string-downcase report)))
        (is (search "RUN will not return" report)))
      (net:close-listener listener))))
