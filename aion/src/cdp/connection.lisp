;;;; connection.lisp --- one WebSocket connection to a browser, and its reader thread (#1028).
;;;;
;;;; Every read happens on the reader thread, the opening handshake included, so every wait in
;;;; the calling thread is a CONDITION-WAIT with a timeout and nothing blocks in a socket call
;;;; that a timeout cannot end. Closing the connection shuts the socket down, which ends the
;;;; reader's receive.
;;;;
;;;; Writes are made under WRITE-LOCK, so frames from two threads never interleave. The state
;;;; the reader and the callers share (pending commands, sessions, the closed reason) is
;;;; guarded by LOCK, and every change to it is announced on QUEUE.

(cl:in-package #:aion/cdp)

(defvar *max-message-octets* (* 256 1024 1024)
  "The largest message accepted from the browser. A full-page screenshot is one message.")

(defvar *max-buffered-events* 10000
  "How many events a page keeps before it drops the oldest. PAGE-EVENTS-DROPPED counts them.")

;;; --- JSON ---------------------------------------------------------------------------

(defun json-object (&rest keys-and-values)
  "A JSON object for SEND, from alternating string keys and values. A value is a string, a
number, T (true), NIL (false), :NULL, a vector (an array), or another JSON-OBJECT."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on keys-and-values by #'cddr
          do (setf (gethash k h) (if (eq v :null) 'null v)))
    h))

(defun json-get (object &rest keys)
  "The value at the path KEYS in OBJECT, a parsed JSON object, or NIL when any step is missing.
A string key reads an object, an integer key an array. JSON null reads as NIL."
  (let ((v object))
    (dolist (k keys)
      (setf v (cond ((and (stringp k) (hash-table-p v)) (gethash k v))
                    ((and (integerp k) (vectorp v) (not (stringp v)) (< -1 k (length v)))
                     (aref v k))
                    (t nil))))
    (if (eq v 'null) nil v)))

;;; --- the connection -----------------------------------------------------------------

(defstruct (connection (:constructor %make-connection (socket key)))
  socket
  key
  (write-lock (sb-thread:make-mutex :name "aion/cdp write"))
  (lock (sb-thread:make-mutex :name "aion/cdp state"))
  (queue (sb-thread:make-waitqueue :name "aion/cdp state"))
  (state :handshake)                  ; :HANDSHAKE, :OPEN or :CLOSED
  (close-reason nil)
  (next-id 0)
  (pending (make-hash-table))         ; id -> :WAITING, or the parsed response
  (sessions (make-hash-table :test 'equal)) ; session id -> PAGE
  (browser-events '())                ; events with no session, newest first
  thread)

(defun %deadline (seconds)
  (+ (get-internal-real-time) (round (* seconds internal-time-units-per-second))))

(defun %remaining (deadline)
  (/ (- deadline (get-internal-real-time)) internal-time-units-per-second))

(defun %wait-on (connection seconds)
  "Wait up to SECONDS on CONNECTION's queue, holding its state lock before and after.
SB-THREAD:CONDITION-WAIT returns NIL without the lock when it times out, so a loop that waits
again, or a WITH-MUTEX that releases on the way out, would act on a lock it no longer holds and
signal \"The current thread is not holding\" (seen on the Linux CI legs). This takes the lock
back in that case. Returns true when woken, NIL when the time ran out."
  (let ((lock (connection-lock connection)))
    (or (sb-thread:condition-wait (connection-queue connection) lock :timeout seconds)
        (progn (unless (sb-thread:holding-mutex-p lock) (sb-thread:grab-mutex lock))
               nil))))

(defun %send-octets (connection octets)
  "Write all of OCTETS to CONNECTION's socket, under its write lock."
  (sb-thread:with-mutex ((connection-write-lock connection))
    (let ((socket (connection-socket connection)) (at 0) (n (length octets)))
      (loop while (< at n)
            do (let ((sent (sb-bsd-sockets:socket-send
                            socket (if (zerop at) octets (subseq octets at)) (- n at))))
                 (unless (and sent (plusp sent))
                   (error 'connection-closed :reason "the socket refused a write"))
                 (incf at sent))))))

(defun %send-frame (connection opcode payload)
  (%send-octets connection (ws:encode-frame opcode payload
                                            :mask-key (aion/random:random-octets 4))))

(defun %close-connection (connection reason)
  "Mark CONNECTION closed with REASON, wake every waiter, and shut its socket down, which ends
the reader's receive. Idempotent; the first reason is kept."
  (let ((first nil))
    (sb-thread:with-mutex ((connection-lock connection))
      (unless (eq (connection-state connection) :closed)
        (setf (connection-state connection) :closed
              (connection-close-reason connection) reason
              first t)
        (sb-thread:condition-broadcast (connection-queue connection))))
    (when first
      (let ((socket (connection-socket connection)))
        (ignore-errors (sb-bsd-sockets:socket-shutdown socket :direction :io))
        (ignore-errors (sb-bsd-sockets:socket-close socket))))
    nil))

;;; --- what the reader does with a message ---------------------------------------------

(defstruct (event (:constructor make-event (method params)))
  "One CDP event: its METHOD, such as \"Runtime.consoleAPICalled\", and its PARAMS, a parsed
JSON object."
  (method "" :read-only t)
  (params nil :read-only t))

;;; A page is defined here, before the reader that appends to it.

(defstruct (page (:constructor %make-page (browser target-id session-id)))
  "One tab, attached to with its own CDP session. Made by NEW-PAGE."
  (browser nil :read-only t)
  (target-id "" :read-only t)
  (session-id "" :read-only t)
  (events '())                 ; newest first; guarded by the connection's lock
  (event-count 0)
  (events-dropped 0)
  (crashed-p nil)
  (detached-p nil))

(defun %page-event (page event)
  "Append EVENT to PAGE's buffer, dropping the oldest when the buffer is full. Called with the
connection's lock held."
  (let ((method (event-method event)))
    (cond ((or (string= method "Inspector.targetCrashed")
               (string= method "Target.targetCrashed"))
           (setf (page-crashed-p page) t))
          ((string= method "Inspector.detached")
           (setf (page-detached-p page) t))))
  (push event (page-events page))
  (incf (page-event-count page))
  (when (> (page-event-count page) *max-buffered-events*)
    (setf (page-events page) (subseq (page-events page) 0 *max-buffered-events*)
          (page-event-count page) *max-buffered-events*)
    (incf (page-events-dropped page))))

(defun %dispatch (connection message)
  "Hand MESSAGE, a parsed JSON object from the browser, to the caller waiting for it, or append
it to its page's events."
  (let ((id (json-get message "id"))
        (method (json-get message "method"))
        (session (json-get message "sessionId")))
    (sb-thread:with-mutex ((connection-lock connection))
      (cond
        ((integerp id)
         (when (gethash id (connection-pending connection))
           (setf (gethash id (connection-pending connection)) message)
           (sb-thread:condition-broadcast (connection-queue connection))))
        ((stringp method)
         (let ((event (make-event method (json-get message "params")))
               (page (and session (gethash session (connection-sessions connection)))))
           (cond (page (%page-event page event))
                 ((string= method "Target.detachedFromTarget")
                  (let ((p (gethash (json-get message "params" "sessionId")
                                    (connection-sessions connection))))
                    (when p (setf (page-detached-p p) t))))
                 ((string= method "Target.targetCrashed")
                  (let ((target (json-get message "params" "targetId")))
                    (loop for p being the hash-values of (connection-sessions connection)
                          when (equal (page-target-id p) target)
                            do (setf (page-crashed-p p) t))))
                 (t (push event (connection-browser-events connection)))))
         (sb-thread:condition-broadcast (connection-queue connection)))))))

(defun %handle-frame (connection assembler frame)
  "Take FRAME into ASSEMBLER and act on what it completes. Returns NIL to stop reading."
  (multiple-value-bind (kind a b) (ws:assemble assembler frame)
    (ecase kind
      (:none t)
      (:text
       (let ((message (handler-case (jzon:parse a)
                        (error () nil))))
         (if (hash-table-p message)
             (progn (%dispatch connection message) t)
             (progn (%close-connection connection "the browser sent a message that is not a JSON object")
                    nil))))
      (:binary t)
      (:ping (ignore-errors (%send-frame connection ws:+pong+ a)) t)
      (:pong t)
      (:close
       (ignore-errors (%send-frame connection ws:+close+ (ws:encode-close-payload ws:+normal-closure+)))
       (%close-connection connection (format nil "the browser closed the connection (~A~@[ ~A~])"
                                             a (and (plusp (length b)) b)))
       nil)
      (:error
       (ignore-errors (%send-frame connection ws:+close+ (ws:encode-close-payload a)))
       (%close-connection connection (format nil "the browser broke the WebSocket protocol: ~A" b))
       nil))))

(defun %read-loop (connection)
  "The reader thread's body: the response head, then frames, until the connection ends."
  (let* ((socket (connection-socket connection))
         (chunk (make-array 65536 :element-type '(unsigned-byte 8)))
         (buf (make-array 65536 :element-type '(unsigned-byte 8)))
         (fill 0)
         (assembler (ws:make-assembler :max-message-octets *max-message-octets*)))
    (flet ((consume (next)
             (replace buf buf :start2 next :end2 fill)
             (decf fill next))
           (fail (reason) (%close-connection connection reason) (return-from %read-loop)))
      (loop
        (multiple-value-bind (data n)
            (handler-case (sb-bsd-sockets:socket-receive socket chunk nil)
              (error () (fail "the connection to the browser ended")))
          (declare (ignore data))
          (when (or (null n) (zerop n))
            (fail "the browser closed the connection"))
          ;; On Windows, SBCL's socket-receive can return recv's -1 read as an unsigned 32-bit
          ;; count, 4294967295, instead of signalling, when the socket is shut down while the
          ;; reader waits on it. Without this check the buffer below grew to that size and the
          ;; heap ran out on the Windows CI leg (#1028). Any count the chunk cannot hold means
          ;; the receive failed.
          (unless (and (integerp n) (<= 1 n (length chunk)))
            (fail (format nil "the connection to the browser ended (receive returned ~S)" n)))
          (when (> (+ fill n) (length buf))
            (let ((bigger (make-array (max (* 2 (length buf)) (+ fill n))
                                      :element-type '(unsigned-byte 8))))
              (replace bigger buf :end2 fill)
              (setf buf bigger)))
          (replace buf chunk :start1 fill :end2 n)
          (incf fill n))
        (when (eq (connection-state connection) :handshake)
          (multiple-value-bind (outcome status headers next)
              (ws:parse-response-head buf :end fill)
            (case outcome
              (:incomplete)
              (:error (fail (format nil "the browser's answer to the WebSocket request: ~A" status)))
              (:head
               (multiple-value-bind (verdict reason)
                   (ws:check-server-handshake status headers (connection-key connection))
                 (when (eq verdict :refuse)
                   (fail (format nil "the browser refused the WebSocket connection: ~A" reason))))
               (consume next)
               (sb-thread:with-mutex ((connection-lock connection))
                 (setf (connection-state connection) :open)
                 (sb-thread:condition-broadcast (connection-queue connection)))))))
        (when (eq (connection-state connection) :open)
          (loop
            (multiple-value-bind (outcome a b)
                (ws:parse-frame buf :end fill :masked nil :max-payload *max-message-octets*)
              (ecase outcome
                (:incomplete (return))
                (:error
                 (ignore-errors (%send-frame connection ws:+close+ (ws:encode-close-payload a)))
                 (fail (format nil "the browser broke the WebSocket protocol: ~A" b)))
                (:frame
                 (consume b)
                 (unless (%handle-frame connection assembler a)
                   (return-from %read-loop)))))))
        (when (eq (connection-state connection) :closed)
          (return-from %read-loop))))))

;;; --- opening ------------------------------------------------------------------------

(defun %loopback-address (host)
  "The IPv4 address to connect to for HOST, as a vector of four octets, or NIL when HOST is not
a loopback address. localhost is taken as 127.0.0.1 rather than looked up."
  (cond ((string-equal host "localhost") (vector 127 0 0 1))
        (t (let ((parts (uiop:split-string host :separator ".")))
             (when (and (= 4 (length parts))
                        (every (lambda (p) (and (plusp (length p)) (<= (length p) 3)
                                                (every #'digit-char-p p)))
                               parts))
               (let ((octets (map 'vector #'parse-integer parts)))
                 (and (every (lambda (o) (<= 0 o 255)) octets)
                      (= 127 (aref octets 0))
                      octets)))))))

(defun %open-connection (host port path timeout)
  "Connect to the browser at HOST and PORT, a loopback address, and complete the WebSocket
handshake for PATH within TIMEOUT seconds. Returns the open CONNECTION."
  (let* ((address (or (%loopback-address host)
                      (error "aion/cdp connects only to a loopback address; ~S is not one." host)))
         (socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
         (key (ws:client-key (aion/random:random-octets 16)))
         (connection (%make-connection socket key))
         (ok nil))
    (unwind-protect
         (progn
           (handler-case (sb-bsd-sockets:socket-connect socket address port)
             (error (e)
               (error 'connection-closed
                      :reason (format nil "could not connect to ~A:~D: ~A" host port e))))
           (%send-octets connection
                         (sb-ext:string-to-octets
                          (ws:client-request-head (format nil "~A:~D" host port) path key)
                          :external-format :latin-1))
           (setf (connection-thread connection)
                 ;; THREAD-LIFETIME: independent. The reader lives as long as the connection,
                 ;; which outlives the call that opened it, and carries no caller's context.
                 (sb-thread:make-thread
                  (lambda ()
                    (aion/dynamic:unblock-interrupts)
                    (%read-loop connection))
                  :name "aion/cdp reader"))
           (let ((deadline (%deadline timeout)))
             (sb-thread:with-mutex ((connection-lock connection))
               (loop while (eq (connection-state connection) :handshake)
                     do (let ((left (%remaining deadline)))
                          (when (<= left 0) (return))
                          (%wait-on connection left)))))
           (case (connection-state connection)
             (:open (setf ok t) connection)
             (:handshake (error 'cdp-timeout :what "The WebSocket handshake with the browser"
                                             :seconds timeout))
             (t (error 'connection-closed :reason (connection-close-reason connection)))))
      (unless ok
        (%close-connection connection "the connection could not be opened")))))

(defun %shutdown-connection (connection)
  "Send a close frame, close CONNECTION, and wait briefly for its reader to end."
  (when (eq (connection-state connection) :open)
    (ignore-errors (%send-frame connection ws:+close+
                                (ws:encode-close-payload ws:+normal-closure+))))
  (%close-connection connection "closed by this process")
  (let ((thread (connection-thread connection)))
    (when (and thread (not (eq thread sb-thread:*current-thread*)))
      (handler-case (sb-thread:join-thread thread :timeout 5 :default nil)
        (error () nil)))))

;;; --- commands -----------------------------------------------------------------------

(defun %command (connection method params session-id timeout)
  "Send METHOD with PARAMS (a JSON object or NIL) on CONNECTION, to the session SESSION-ID or
to the browser when it is NIL, and wait up to TIMEOUT seconds for the answer. Returns the
result object, or signals CDP-ERROR, CDP-TIMEOUT or CONNECTION-CLOSED."
  (let ((id nil)
        (lock (connection-lock connection)))
    (sb-thread:with-mutex (lock)
      (unless (eq (connection-state connection) :open)
        (error 'connection-closed :reason (or (connection-close-reason connection) "not open")))
      (setf id (incf (connection-next-id connection))
            (gethash id (connection-pending connection)) :waiting))
    (unwind-protect
         (let ((message (json-object "id" id "method" method
                                     "params" (or params (json-object)))))
           (when session-id (setf (gethash "sessionId" message) session-id))
           (%send-frame connection ws:+text+ (ws:encode-utf8 (jzon:stringify message)))
           (let ((deadline (%deadline timeout))
                 (answer nil))
             (sb-thread:with-mutex (lock)
               (loop
                 (setf answer (gethash id (connection-pending connection)))
                 (unless (eq answer :waiting) (return))
                 (unless (eq (connection-state connection) :open) (return))
                 (let ((left (%remaining deadline)))
                   (when (<= left 0) (return))
                   (%wait-on connection left))))
             (cond ((hash-table-p answer)
                    (let ((err (json-get answer "error")))
                      (if err
                          (error 'cdp-error :method method :code (json-get err "code")
                                            :message (or (json-get err "message") ""))
                          (or (json-get answer "result") (json-object)))))
                   ((not (eq (connection-state connection) :open))
                    (error 'connection-closed :reason (connection-close-reason connection)))
                   (t (error 'cdp-timeout :what method :seconds timeout)))))
      (sb-thread:with-mutex (lock)
        (remhash id (connection-pending connection))))))
