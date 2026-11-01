;;;; stream.lisp --- a response read as it arrives, and a request another thread can cancel (#984).
;;;;
;;;; SEND-REQUEST returns a response once its whole body has arrived. A model provider that streams
;;;; its reply sends the body a piece at a time for as long as the model is writing, so a caller
;;;; that wants each piece as it comes needs the body as a stream. OPEN-RESPONSE-STREAM returns
;;;; one; READ-EVENT reads it as Server-Sent Events.
;;;;
;;;; CANCELLING. A caller on another thread can stop the request with CANCEL-REQUEST. That shuts
;;;; down the socket, which wakes a read blocked on it, so the server sees the connection close
;;;; and stops sending; a model provider then stops generating. Setting a flag that the reader
;;;; checks would not be enough: the reader can wait on the socket for as long as the server
;;;; takes to send the next byte, and all that time the server goes on generating. The shutdown
;;;; is FETCH-PUBLIC's deadline mechanism (#807), the same %WATCH, so it works on each platform
;;;; that one does.
;;;;
;;;; The connection is opened by %REQUEST-PINNED to the first address the URL's host resolves
;;;; to, because the socket has to be one this client opened to be one it can shut down. Unlike
;;;; FETCH-PUBLIC, no address is refused: the URL is the app's own, such as a provider's endpoint
;;;; or a local model server, not one a user typed.

(in-package #:aion/http-client)

(define-condition request-cancelled (http-error) ()
  (:documentation "The request was cancelled with CANCEL-REQUEST before its response had been
read to the end."))

(defstruct (request-cancel (:constructor make-request-cancel ())
                           (:predicate request-cancel-p))
  "A handle that cancels the requests opened with it (OPEN-RESPONSE-STREAM's :CANCEL). Make one
before the request, give it to the thread that may cancel, and call CANCEL-REQUEST there. One
handle may serve several requests at once, from several threads: each open request has a watch
of its own in WATCHES, and a cancel shuts down every one of them. Every field is read and written
with LOCK held."
  (lock (sb-thread:make-mutex :name "request cancel"))
  (fired nil)
  (watches '()))

(defun cancel-request (cancel)
  "Cancel every request using CANCEL, a REQUEST-CANCEL, from any thread: shut each one's socket
down, so a read blocked on it returns and the server sees the connection close. A request opened
with CANCEL after this is shut down as soon as it connects. Returns T."
  (dolist (watch (sb-thread:with-mutex ((request-cancel-lock cancel))
                   (setf (request-cancel-fired cancel) t)
                   (copy-list (request-cancel-watches cancel))))
    (%fire watch))
  t)

(defun request-cancelled-p (cancel)
  "True once CANCEL-REQUEST has been called on CANCEL."
  (sb-thread:with-mutex ((request-cancel-lock cancel)) (request-cancel-fired cancel)))

(defun %add-watch (cancel watch)
  "Register WATCH, a new request's, with CANCEL. When CANCEL has already fired, fire WATCH now."
  (when (sb-thread:with-mutex ((request-cancel-lock cancel))
          (push watch (request-cancel-watches cancel))
          (request-cancel-fired cancel))
    (%fire watch)))

(defun %remove-watch (cancel watch)
  "Take WATCH, a request's that has ended, back from CANCEL."
  (when cancel
    (sb-thread:with-mutex ((request-cancel-lock cancel))
      (setf (request-cancel-watches cancel) (remove watch (request-cancel-watches cancel))))))

;;; --- the body ------------------------------------------------------------------------------

(defclass %response-stream (sb-gray:fundamental-binary-input-stream)
  ((inner :initarg :inner :reader %inner)
   (watch :initarg :watch :reader %stream-watch)
   (cancel :initarg :cancel :reader %stream-cancel)
   (socket :initarg :socket :reader %stream-socket)
   (closed :initform nil :accessor %stream-closed))
  (:documentation "OPEN-RESPONSE-STREAM's body. Reads come from INNER, the body as the
connection frames it. A read that fails or ends after the request was cancelled signals
REQUEST-CANCELLED instead, so a body cut short by a cancel is never taken for a whole one.
CLOSE takes the socket back from the watch, takes the watch back from CANCEL, the request's
REQUEST-CANCEL or NIL, and then closes the connection."))

(defmethod stream-element-type ((s %response-stream)) '(unsigned-byte 8))

(defun %cancelled-error (s)
  (declare (ignore s))
  (error 'request-cancelled :detail "the request was cancelled"))

(defmethod sb-gray:stream-read-byte ((s %response-stream))
  (when (%fired-p (%stream-watch s)) (%cancelled-error s))
  (let ((b (handler-case (read-byte (%inner s) nil :eof)
             (error (e)
               (if (%fired-p (%stream-watch s))
                   (%cancelled-error s)
                   (error 'http-error :detail (format nil "reading the response: ~A" e)))))))
    (if (and (eq b :eof) (%fired-p (%stream-watch s)))
        (%cancelled-error s)
        b)))

(defmethod close ((s %response-stream) &key abort)
  (declare (ignore abort))
  (unless (%stream-closed s)
    (setf (%stream-closed s) t)
    ;; Taken back before anything is closed: a closed socket's descriptor number can be reused,
    ;; and a cancel after the close must not shut down whatever reused it.
    (let ((*%watch* (%stream-watch s)))
      (%take-back-socket)
      (ignore-errors (close (%inner s))))
    (%remove-watch (%stream-cancel s) (%stream-watch s))
    (when (%stream-socket s) (ignore-errors (usocket:socket-close (%stream-socket s)))))
  t)

(defun open-response-stream (request &key cancel (resolve #'resolve-host))
  "Send REQUEST and return (values BODY STATUS HEADERS) as soon as the response head has
arrived. BODY is a binary input stream of the response body as it arrives, of any status; the
caller reads it and must CLOSE it, which closes the connection. Redirects are not followed.

CANCEL, a REQUEST-CANCEL, lets another thread stop the request (CANCEL-REQUEST). After a cancel,
a read from BODY signals REQUEST-CANCELLED, and so does this function when the cancel came
first. A connect or TLS failure signals HTTP-ERROR.

The request asks for an uncompressed body (Accept-Encoding: identity), so each piece can be
read as it arrives. RESOLVE is for tests."
  (let* ((watch (%make-watch))
         (*%watch* watch)
         (uri (quri:uri (request-url request)))
         (address (or (first (funcall resolve (quri:uri-host uri)))
                      (error 'http-error :detail (format nil "~A does not resolve"
                                                         (quri:uri-host uri)))))
         (req (copy-request request)))
    (setf (request-connect-address req) address
          (request-follow-redirects req) nil
          ;; Set only so %REQUEST-PINNED hands the body back unread; nothing here caps it.
          (request-max-body-bytes req) most-positive-fixnum
          (request-headers req) (cons '("Accept-Encoding" . "identity")
                                      (remove "accept-encoding" (request-headers req)
                                              :key #'car :test #'string-equal)))
    (when cancel (%add-watch cancel watch))
    (let ((opened nil))
      (unwind-protect
           (flet ((cancelled () (error 'request-cancelled :detail "the request was cancelled")))
             (when (%fired-p watch) (cancelled))
             (multiple-value-bind (body status headers)
                 (handler-bind ((error (lambda (e)
                                         (when (and (%fired-p watch)
                                                    (not (typep e 'request-cancelled)))
                                           (cancelled)))))
                   (handler-case (%request-pinned req)
                     (http-error (e) (error e))
                     (error (e) (error 'http-error :detail (format nil "transport error: ~A" e)))))
               (let ((socket (sb-thread:with-mutex ((%watch-lock watch)) (%watch-socket watch))))
                 (multiple-value-prog1
                     (values (make-instance '%response-stream
                                            :inner (if (streamp body)
                                                       body
                                                       (make-instance '%octets-input
                                                                      :octets (%as-octets body)))
                                            :watch watch :cancel cancel :socket socket)
                             status headers)
                   (setf opened t)))))
        ;; The body's CLOSE takes the watch back; with no body, nothing else will.
        (unless opened (%remove-watch cancel watch))))))

(defclass %octets-input (sb-gray:fundamental-binary-input-stream)
  ((octets :initarg :octets :reader %octets)
   (at :initform 0 :accessor %at))
  (:documentation "A body that arrived whole, as a binary input stream."))

(defmethod stream-element-type ((s %octets-input)) '(unsigned-byte 8))

(defmethod sb-gray:stream-read-byte ((s %octets-input))
  (if (< (%at s) (length (%octets s)))
      (prog1 (aref (%octets s) (%at s)) (incf (%at s)))
      :eof))

;;; --- Server-Sent Events ----------------------------------------------------------------------

(defparameter *max-event-octets* (* 4 1024 1024)
  "The most octets READ-EVENT reads for one event, line ends included. An event from a model
provider carries one piece of text or one piece of a tool call's arguments, far below this.")

(defun %octets-text (octets)
  (sb-ext:octets-to-string (coerce octets '(vector (unsigned-byte 8)))
                           :external-format '(:utf-8 :replacement #\?)))

(defun %read-event-line (stream budget)
  "One line from STREAM, decoded as UTF-8, without its line end, and the octets it used. A line
ends at LF; a CR before the LF is dropped. A CR alone does not end a line, though the event-stream
format allows it: seeing it would need a byte of lookahead, and the providers this serves end
lines with LF. Returns NIL at the end of the stream before any octet."
  (let ((octets (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (used 0))
    (loop
      (let ((b (read-byte stream nil nil)))
        (cond ((null b)
               (return (and (plusp used) (values (%octets-text octets) used))))
              ((> (incf used) budget)
               (error 'http-error :detail (format nil "an event is longer than ~D octets"
                                                  *max-event-octets*)))
              ((= b 10)
               (when (and (plusp (fill-pointer octets))
                          (= 13 (aref octets (1- (fill-pointer octets)))))
                 (decf (fill-pointer octets)))
               (return (values (%octets-text octets) used)))
              (t (vector-push-extend b octets)))))))

(defun read-event (stream)
  "The next Server-Sent Event on STREAM, a binary input stream such as OPEN-RESPONSE-STREAM's
body, as (values DATA EVENT ID OCTETS): DATA the event's data lines joined with newlines, EVENT
its event field or NIL, ID its id field or NIL, OCTETS the octets read for it, comments
included. Returns NIL at the end of the stream. An event is complete only when a blank line
follows it, so one the stream ends in the middle of is discarded, as the event-stream format
says: a provider's connection that drops mid-event must not pass for a whole event. Comments
(lines starting with a colon) and events with no data are skipped. Signals HTTP-ERROR when an
event is longer than *MAX-EVENT-OCTETS*."
  (let ((data '()) (event nil) (id nil) (used 0) (saw-data nil))
    (loop
      (multiple-value-bind (line n) (%read-event-line stream (- *max-event-octets* used))
        (cond ((null line) (return nil))
              (t
               (incf used n)
               (cond ((zerop (length line))
                      (when saw-data
                        (return (values (format nil "~{~A~^~%~}" (reverse data)) event id used)))
                      (setf event nil id nil))
                     ((char= #\: (char line 0)))
                     (t
                      (let* ((colon (position #\: line))
                             (field (if colon (subseq line 0 colon) line))
                             (value (if colon (subseq line (1+ colon)) "")))
                        (when (and (plusp (length value)) (char= #\Space (char value 0)))
                          (setf value (subseq value 1)))
                        (cond ((string= field "data") (push value data) (setf saw-data t))
                              ((string= field "event") (setf event value))
                              ((string= field "id") (setf id value))))))))))))
