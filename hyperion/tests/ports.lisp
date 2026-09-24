;;;; ports.lisp --- choosing a port for a test server, shared by hyperion's test systems.
;;;;
;;;; One copy, because there used to be two identical ones (%FREE-PORT in assets-tests,
;;;; %SRV-FREE-PORT in server-tests) that both promised a free port. Neither could keep the
;;;; promise: the port is released before it is returned, so something else can take it
;;;; before the server binds it (#159). This helper promises only a CANDIDATE, and
;;;; CALL-WITH-PORT is what makes a taken candidate harmless: HYPERION/SERVER:START signals
;;;; PORT-IN-USE in the caller when its bind fails, and CALL-WITH-PORT tries another.

(cl:defpackage #:hyperion/test-ports
  (:use #:cl)
  (:export #:candidate-port #:call-with-port #:listening-p #:await-released
           #:+attempts+))

(in-package #:hyperion/test-ports)

(defparameter +attempts+ 5
  "How many candidate ports CALL-WITH-PORT tries before letting PORT-IN-USE through.")

(defun candidate-port ()
  "A loopback TCP port that was free a moment ago: bind port 0, read what the OS chose,
close. It may be taken by the time a server binds it. Use CALL-WITH-PORT to start a server
on it."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn (sb-bsd-sockets:socket-bind s #(127 0 0 1) 0)
                (nth-value 1 (sb-bsd-sockets:socket-name s)))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(defun call-with-port (function)
  "Call FUNCTION with a candidate port and return what it returns. If it signals
HYPERION/SERVER:PORT-IN-USE, call it again with another candidate, up to +ATTEMPTS+ times.

FUNCTION is expected to start a server on the port and nothing else before that, since it
may run more than once."
  (loop for attempt from 1
        do (handler-case (return (funcall function (candidate-port)))
             (hyperion/server:port-in-use (c)
               (when (>= attempt +attempts+) (error c))))))

(defun listening-p (port &key (host #(127 0 0 1)))
  "True if something accepts a TCP connection on PORT right now."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (handler-case (progn (sb-bsd-sockets:socket-connect s host port) t)
           (error () nil))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(defun await-released (port &key (timeout 10))
  "Wait until nothing accepts on PORT. True if it was released, NIL after TIMEOUT seconds.

A teardown waits on this so that the next test does not meet a listener that is still
closing. HYPERION/SERVER:STOP now waits for the server's thread, so on the Clack path the
socket is closed when STOP returns; this remains the check that says so."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop
      (unless (listening-p port) (return t))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep 0.02))))
