;;;; client.lisp --- a client for Coalton's `mine/runtime` server in a child SBCL (#1218).
;;;;
;;;; A spike for the IDE's code editor window. It answers one question: can the evaluation
;;;; server of `mine`, Coalton's terminal IDE, run as a child process with no terminal UI and
;;;; answer completion, type and diagnostics requests from this image?
;;;;
;;;; START-RUNTIME starts a second SBCL that loads child.lisp, reads the TCP port the child
;;;; prints, and connects to it on 127.0.0.1. Each RUNTIME-* function sends one request and
;;;; reads frames until the reply to that request arrives. RUNTIME-STOP kills the child.
;;;;
;;;; The wire format is the server's: six uppercase hexadecimal digits giving the length of
;;;; the payload in bytes, then the payload, one s-expression in UTF-8.
;;;;
;;;; This file contains no code from `mine`. `mine` has a client of its own
;;;; (`mine/protocol/client`, `mine/protocol/lifecycle`), written in Coalton with `mine`'s
;;;; request and response types, and using it would load the whole of `mine/runtime` into the
;;;; IDE's image. This client needs only sockets and the reader, so the IDE's image loads
;;;; nothing of `mine`.

(cl:defpackage #:praxeon/examples/ouranos-ide/runtime
  (:use #:cl)
  (:export
   ;; lifecycle
   #:start-runtime #:runtime-stop #:runtime-alive-p #:runtime-busy-p #:runtime-pid #:runtime-port
   #:runtime-start-seconds #:runtime-xmath
   #:runtime-start-failed #:start-failure-pid #:runtime-timeout #:runtime-closed
   ;; requests
   #:runtime-ping #:runtime-heap-info
   #:runtime-complete #:runtime-arglist #:runtime-coalton-type-of
   #:runtime-compile-string #:runtime-eval #:runtime-interrupt
   ;; a reply
   #:reply #:reply-status #:reply-value #:reply-output #:reply-diagnostics
   #:reply-condition #:reply-package
   ;; a diagnostic
   #:diagnostic-severity #:diagnostic-summary #:diagnostic-label #:diagnostic-label-kind
   #:diagnostic-start #:diagnostic-end #:diagnostic-group))

(cl:in-package #:praxeon/examples/ouranos-ide/runtime)

;;; --- conditions --------------------------------------------------------------------------

(define-condition runtime-start-failed (error)
  ((reason :initarg :reason :reader start-failure-reason)
   (output :initarg :output :reader start-failure-output)
   ;; The pid the child had, or NIL when no process was created. The child is dead by the
   ;; time the condition is signalled.
   (pid :initarg :pid :initform nil :accessor start-failure-pid))
  (:report (lambda (c stream)
             (format stream "The Coalton runtime child did not start: ~A~@[~%Its last output:~%~A~]"
                     (start-failure-reason c) (start-failure-output c)))))

(define-condition runtime-timeout (error)
  ((request :initarg :request :reader timeout-request)
   (seconds :initarg :seconds :reader timeout-seconds))
  (:report (lambda (c stream)
             (format stream "The Coalton runtime did not answer ~S within ~A seconds."
                     (timeout-request c) (timeout-seconds c)))))

(define-condition runtime-closed (error)
  ((request :initarg :request :reader closed-request))
  (:report (lambda (c stream)
             (format stream "The connection to the Coalton runtime closed before ~S was answered."
                     (closed-request c)))))

;;; --- the runtime -------------------------------------------------------------------------

(defstruct (runtime (:constructor %make-runtime))
  process                               ; the SB-EXT process of the child
  port                                  ; the TCP port the child listens on
  socket stream                         ; the main connection
  (lock (sb-thread:make-mutex :name "ouranos-ide-runtime"))
  (next-id 0)
  (id-lock (sb-thread:make-mutex :name "ouranos-ide-runtime-ids"))
  (active-id nil)                       ; the request the main connection is waiting on
  (start-seconds nil)                   ; from starting the child to the answered ping
  (xmath nil))                          ; "declared" or "removed"; see child.lisp

(defun runtime-pid (runtime)
  "The process id of RUNTIME's child."
  (sb-ext:process-pid (runtime-process runtime)))

(defun runtime-alive-p (runtime)
  "True while RUNTIME's child process is running."
  (let ((process (runtime-process runtime)))
    (and process (sb-ext:process-alive-p process))))

(defun runtime-busy-p (runtime)
  "True while a request on RUNTIME's main connection is waiting for its reply."
  (not (null (runtime-active-id runtime))))

(defun %child-file ()
  (asdf:system-relative-pathname "praxeon/examples/ouranos-ide/runtime"
                                 "examples/ouranos-ide/runtime/child.lisp"))

(defun %next-id (runtime)
  (sb-thread:with-mutex ((runtime-id-lock runtime))
    (incf (runtime-next-id runtime))))

;;; --- framing -----------------------------------------------------------------------------

(defun %encode (form)
  "FORM as the server reads it: standard syntax, lower case."
  (with-standard-io-syntax
    (let ((*print-case* :downcase))
      (prin1-to-string form))))

(defun %decode (text)
  "The one s-expression in TEXT. The reader evaluates nothing. A reply holds keywords, T, NIL,
strings, integers and lists of those; a symbol outside those would be interned in this
package."
  (with-standard-io-syntax
    (let ((*read-eval* nil)
          (*package* (find-package '#:praxeon/examples/ouranos-ide/runtime)))
      (values (read-from-string text)))))

(defun %write-frame (stream form)
  (let* ((payload (sb-ext:string-to-octets (%encode form) :external-format :utf-8))
         (header (sb-ext:string-to-octets (format nil "~6,'0X" (length payload))
                                          :external-format :utf-8)))
    (when (> (length payload) #xffffff)
      (error "A request of ~D bytes does not fit the six-digit frame length." (length payload)))
    (write-sequence header stream)
    (write-sequence payload stream)
    (finish-output stream)))

(defun %read-octets (stream count)
  "COUNT octets from STREAM, or NIL when the stream ends first. The count READ-SEQUENCE
returns is what decides, not the length the header declared."
  (let* ((octets (make-array count :element-type '(unsigned-byte 8)))
         (read (read-sequence octets stream)))
    (and (= read count) octets)))

(defun %read-frame (stream)
  "The next message on STREAM, or NIL at end of stream."
  (let ((header (%read-octets stream 6)))
    (when header
      (let* ((length (parse-integer (sb-ext:octets-to-string header :external-format :utf-8)
                                    :radix 16))
             (payload (%read-octets stream length)))
        (when payload
          (%decode (sb-ext:octets-to-string payload :external-format :utf-8)))))))

(defun %connect (port)
  "A socket connected to PORT on 127.0.0.1 and its octet stream."
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (handler-case
        (progn
          (sb-bsd-sockets:socket-connect socket #(127 0 0 1) port)
          (values socket
                  (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                            :element-type '(unsigned-byte 8)
                                                            :buffering :full)))
      (error (e)
        (ignore-errors (sb-bsd-sockets:socket-close socket))
        (error e)))))

;;; --- replies -----------------------------------------------------------------------------

(defstruct reply
  "What one request produced. STATUS is :OK or :ERROR and VALUE is the payload or the error
text. OUTPUT is what the request printed. DIAGNOSTICS are the plists of the server's
:diagnostic notifications, in the order sent. CONDITION is the text of the condition when the
server entered its debugger, which this client always leaves with the abort restart. PACKAGE
is the package the server reports after an evaluation."
  status value (output "") diagnostics condition package)

(defun diagnostic-severity (diagnostic) (getf diagnostic :severity))
(defun diagnostic-summary (diagnostic) (getf diagnostic :summary))
(defun diagnostic-label (diagnostic) (getf diagnostic :label))
(defun diagnostic-label-kind (diagnostic) (getf diagnostic :label-kind))
(defun diagnostic-start (diagnostic) (getf diagnostic :start))
(defun diagnostic-end (diagnostic) (getf diagnostic :end))
(defun diagnostic-group (diagnostic) (getf diagnostic :group))

(defun %collect (stream id request-name)
  "Read frames from STREAM until the reply to request ID, and return a REPLY. Notifications
are gathered into it. When the server enters its debugger for ID, answer with :debug-abort,
because nothing here can choose a restart; the reply then arrives as an error."
  (let ((output (make-string-output-stream))
        (diagnostics '())
        (condition nil)
        (package nil))
    (loop
      (let ((message (%read-frame stream)))
        (unless (consp message)
          (error 'runtime-closed :request request-name))
        (case (first message)
          (:return
            (when (eql (second message) id)
              (destructuring-bind (status &optional value) (third message)
                (return (make-reply :status status :value value
                                    :output (get-output-stream-string output)
                                    :diagnostics (nreverse diagnostics)
                                    :condition condition :package package)))))
          (:debug
           (when (eql (second message) id)
             (setf condition (third message))
             (%write-frame stream (list :debug-abort id))))
          (:io-request
           ;; The evaluated code read from standard input. There is nobody to type.
           (%write-frame stream (list :io-abort (second message))))
          (:notify
           (let ((note (second message)))
             (case (first note)
               (:output-chunk (write-string (third note) output))
               (:output (write-line (second note) output))
               (:diagnostic (push (rest note) diagnostics))
               (:package (setf package (third note)))))))))))

(defun %request (runtime name arguments timeout)
  "Send (NAME id . ARGUMENTS) on RUNTIME's main connection and return the REPLY. One request
at a time: the server answers a connection's requests in order. TIMEOUT is kept with
SB-EXT:WITH-TIMEOUT, as in %READ-PORT, because on Windows a deadline does not interrupt a read
blocked on the socket (#1220)."
  (sb-thread:with-mutex ((runtime-lock runtime))
    (let ((stream (runtime-stream runtime))
          (id (%next-id runtime)))
      (unless stream
        (error 'runtime-closed :request name))
      (setf (runtime-active-id runtime) id)
      (unwind-protect
           (handler-case
               (sb-ext:with-timeout timeout
                 (%write-frame stream (list* name id arguments))
                 (%collect stream id name))
             (sb-ext:timeout ()
               (error 'runtime-timeout :request name :seconds timeout))
             (stream-error ()
               (error 'runtime-closed :request name)))
        (setf (runtime-active-id runtime) nil)))))

;;; --- requests ----------------------------------------------------------------------------

(defun runtime-ping (runtime &key (timeout 10))
  "True when RUNTIME answers a ping."
  (eq :pong (reply-value (%request runtime :ping '() timeout))))

(defun runtime-heap-info (runtime &key (timeout 10))
  "Two values: the bytes of dynamic space the child uses, and the size of its dynamic space."
  (let ((value (reply-value (%request runtime :heap-info '() timeout))))
    (values (car value) (cdr value))))

(defun runtime-complete (runtime prefix &key (package "COALTON-USER") (limit 50) (timeout 10))
  "The symbols in PACKAGE that start with PREFIX, at most LIMIT of them. Each is a list
(NAME KIND TYPE): NAME is the text to insert, KIND a short tag such as \"fn\" or \"pkg\", and
TYPE a Coalton type or a Lisp lambda list as a string, empty when there is none."
  (let ((reply (%request runtime :complete (list prefix package limit) timeout)))
    (values (and (eq :ok (reply-status reply)) (reply-value reply)) reply)))

(defun runtime-arglist (runtime function-name &key (package "COALTON-USER") (timeout 10))
  "The argument list of FUNCTION-NAME in PACKAGE as a string, or NIL when the server has none."
  (let ((reply (%request runtime :arglist (list function-name package) timeout)))
    (values (and (eq :ok (reply-status reply)) (reply-value reply)) reply)))

(defun runtime-coalton-type-of (runtime symbol-name &key (package "COALTON-USER") (timeout 10))
  "The Coalton type of SYMBOL-NAME in PACKAGE as a string. For a symbol with no Coalton type
the server answers with its Lisp argument list instead. NIL when the server has neither."
  (let ((reply (%request runtime :coalton-type-of (list symbol-name package) timeout)))
    (values (and (eq :ok (reply-status reply)) (reply-value reply)) reply)))

(defun runtime-compile-string (runtime code &key (package "COALTON-USER") (document "")
                                                 (position 0) (coalton t) (timeout 60))
  "Compile and load CODE in the child, and return the REPLY. Its diagnostics carry :START and
:END, character offsets into CODE plus POSITION, where POSITION is the offset of CODE in the
editor's document. DOCUMENT is a name the server puts in each diagnostic's :FILE. With
COALTON true and PACKAGE a Coalton package, the server wraps a bare Coalton form in
`coalton-toplevel` or `coalton` and subtracts the wrapper's length from the offsets.

The server loads what it compiles: a definition in CODE that compiles stays defined in the
child."
  (%request runtime :compile-string
            (list code document package position 0 (and coalton t))
            timeout))

(defun runtime-eval (runtime form &key (package "COALTON-USER") (coalton t) (timeout 60))
  "Evaluate the text FORM in PACKAGE in the child, and return the REPLY. Its value is the
printed result. An evaluation that runs longer than TIMEOUT signals RUNTIME-TIMEOUT and
leaves the main connection waiting; interrupt it with RUNTIME-INTERRUPT from another thread
before the timeout, or stop the runtime."
  (%request runtime :eval (list form package (and coalton t)) timeout))

(defun runtime-interrupt (runtime &key (timeout 5))
  "Interrupt the request RUNTIME's main connection is waiting on. Call it from a thread other
than the one that is waiting. True when the server interrupted a request; NIL when no request
was waiting or the server had not started it yet. The interrupt goes over a second, short
connection, as `mine` does it, because the main connection is busy with the request."
  (let ((target (runtime-active-id runtime)))
    (when target
      (multiple-value-bind (socket stream) (%connect (runtime-port runtime))
        (unwind-protect
             (let ((id (%next-id runtime)))
               (handler-case
                   ;; WITH-TIMEOUT, as in %REQUEST, so the timeout holds on Windows (#1220).
                   (sb-ext:with-timeout timeout
                     (%write-frame stream (list :interrupt-request id target))
                     (eq :ok (reply-status (%collect stream id :interrupt-request))))
                 (sb-ext:timeout ()
                   (error 'runtime-timeout :request :interrupt-request :seconds timeout))))
          (ignore-errors (close stream :abort t))
          (ignore-errors (sb-bsd-sockets:socket-close socket)))))))

;;; --- starting and stopping ---------------------------------------------------------------

(defun %read-port (process timeout)
  "Two values: the port the child printed, and the xmath word from its READY line. Signals
RUNTIME-START-FAILED when the child exits or TIMEOUT seconds pass first. The last lines the
child wrote go into the condition.

The wait is SB-EXT:WITH-TIMEOUT, not SB-SYS:WITH-DEADLINE. On Windows a deadline does not
interrupt a read that is blocked on the child's output pipe: measured on Windows 11 for #1220, a
read under a deadline of 0.5 seconds waited 4.03 seconds, until the child wrote its line, so a
child that never printed a port was waited for as long as it took to print one. WITH-TIMEOUT
interrupts the thread, and ended the same read at 0.50 seconds."
  (let ((output (sb-ext:process-output process))
        (recent '())
        (xmath nil))
    (flet ((fail (reason)
             (error 'runtime-start-failed
                    :reason reason
                    :output (format nil "~{~A~^~%~}" (reverse (subseq recent 0 (min 15 (length recent))))))))
      (handler-case
          (sb-ext:with-timeout timeout
            (loop
              (let ((line (read-line output nil nil)))
                (cond ((null line)
                       (fail "the child exited before it printed a port"))
                      (xmath
                       (let ((port (ignore-errors (parse-integer line))))
                         (if port
                             (return (values port xmath))
                             (fail (format nil "expected a port after the READY line, read ~S" line)))))
                      ((eql 0 (search "OURANOS-RUNTIME-READY xmath=" line))
                       (setf xmath (subseq line (length "OURANOS-RUNTIME-READY xmath="))))
                      (t (push line recent))))))
        (sb-ext:timeout ()
          (fail (format nil "no port line within ~A seconds" timeout)))))))

(defun %quicklisp-args ()
  "Command-line arguments that make the child load the Quicklisp this image loaded, or NIL when
this image has no Quicklisp. The child needs Quicklisp to find Coalton's own dependencies, and it
is started with --no-userinit, so it cannot rely on ~/.sbclrc to load it."
  (let ((package (find-package "QL")))
    (when package
      (let ((home (symbol-value (find-symbol "*QUICKLISP-HOME*" package))))
        (list "--eval"
              (format nil "(load ~S)"
                      (sb-ext:native-namestring (merge-pathnames "setup.lisp" home))))))))

(defun start-runtime (&key (program "sbcl") (dynamic-space-mb 4096) (timeout 120))
  "Start a child SBCL running the `mine/runtime` server, connect to it, and return the
RUNTIME. PROGRAM is found on the search path. TIMEOUT bounds the wait for the child's port
line; the first start after a Coalton or SBCL change compiles `mine/runtime` and takes
longer than later ones. The child inherits this process's environment, so it finds this
tree's systems through the same CL_SOURCE_REGISTRY. It does not read ~/.sbclrc: when this image
has Quicklisp loaded, the child loads the same Quicklisp setup file explicitly (see
%QUICKLISP-ARGS), so it works on a machine whose ~/.sbclrc does not load Quicklisp, such as a
CI runner. Its standard error is discarded. On any failure the child is killed
before the condition leaves this function."
  (let* ((started (get-internal-real-time))
         (process (handler-case
                      (sb-ext:run-program
                       program
                       (append
                        (list "--dynamic-space-size" (princ-to-string dynamic-space-mb)
                              "--noinform" "--no-userinit" "--non-interactive")
                        (append (%quicklisp-args)
                                (list "--load" (sb-ext:native-namestring (%child-file)))))
                       :search t :wait nil
                       :input :stream :output :stream :error nil)
                    (error (e)
                      (error 'runtime-start-failed
                             :reason (format nil "could not run ~S: ~A" program e)
                             :output nil))))
         (runtime (%make-runtime :process process))
         (ok nil))
    (unwind-protect
         (multiple-value-bind (port xmath)
             (handler-bind ((runtime-start-failed
                              (lambda (c)
                                (setf (start-failure-pid c) (sb-ext:process-pid process)))))
               (%read-port process timeout))
           (setf (runtime-port runtime) port
                 (runtime-xmath runtime) xmath)
           (multiple-value-bind (socket stream) (%connect port)
             (setf (runtime-socket runtime) socket
                   (runtime-stream runtime) stream))
           (unless (runtime-ping runtime)
             (error 'runtime-start-failed :reason "the server did not answer a ping" :output nil))
           (setf (runtime-start-seconds runtime)
                 (/ (- (get-internal-real-time) started)
                    (float internal-time-units-per-second)))
           (setf ok t)
           runtime)
      (unless ok
        (runtime-stop runtime)))))

#+win32
(progn
  (defconstant +synchronize+ #x00100000
    "The access right that lets WaitForSingleObject wait on a process handle.")

  (defun %open-for-waiting (pid)
    "A handle of our own on the process PID that can be waited on, or NIL when it cannot be
opened. SB-EXT's own handle cannot be used for this: SBCL clears it when PROCESS-WAIT returns."
    (let ((handle (sb-alien:alien-funcall
                   (sb-alien:extern-alien "OpenProcess"
                                          (function (sb-alien:unsigned #.sb-vm:n-machine-word-bits)
                                                    (sb-alien:unsigned 32) sb-alien:int
                                                    (sb-alien:unsigned 32)))
                   +synchronize+ 0 pid)))
      (and (plusp handle) handle)))

  (defun %wait-and-close (handle milliseconds)
    "Wait up to MILLISECONDS for the process HANDLE names to end, then close HANDLE.

SB-EXT:PROCESS-WAIT does not wait for this on Windows: right after SB-EXT:PROCESS-KILL the status
is already :EXITED and PROCESS-WAIT returns at once (measured on Windows 11 for #1242), while
TerminateProcess ends the process asynchronously. On a CI runner the killed child was still listed
by tasklist after RUNTIME-STOP returned."
    (unwind-protect
         (sb-alien:alien-funcall
          (sb-alien:extern-alien "WaitForSingleObject"
                                 (function (sb-alien:unsigned 32)
                                           (sb-alien:unsigned #.sb-vm:n-machine-word-bits)
                                           (sb-alien:unsigned 32)))
          handle milliseconds)
      (sb-alien:alien-funcall
       (sb-alien:extern-alien "CloseHandle"
                              (function sb-alien:int (sb-alien:unsigned #.sb-vm:n-machine-word-bits)))
       handle))))

(defun runtime-stop (runtime)
  "Kill RUNTIME's child and wait until the operating system has removed it. Safe to call
twice. Returns the pid the child had. The child is killed, not asked to quit, because it may
be in the middle of an evaluation that would never read the request."
  (let ((process (runtime-process runtime))
        (stream (runtime-stream runtime))
        (socket (runtime-socket runtime)))
    (setf (runtime-stream runtime) nil
          (runtime-socket runtime) nil)
    (when stream (ignore-errors (close stream :abort t)))
    (when socket (ignore-errors (sb-bsd-sockets:socket-close socket)))
    (when process
      (let ((pid (sb-ext:process-pid process)))
        ;; On Windows the handle to wait on is opened before the kill (see %WAIT-AND-CLOSE).
        (let ((waiter #+win32 (ignore-errors (%open-for-waiting pid)) #-win32 nil))
          (declare (ignorable waiter))
          (when (sb-ext:process-alive-p process)
            (ignore-errors (sb-ext:process-kill process 9)))
          (sb-ext:process-wait process)
          #+win32 (when waiter (%wait-and-close waiter 10000)))
        (ignore-errors (sb-ext:process-close process))
        pid))))
