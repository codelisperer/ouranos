;;;; export.lisp --- where finished traces go: the image, or an OTLP/HTTP collector (#1225).

(in-package #:praxeon/trace)

(defgeneric export-spans (exporter spans)
  (:documentation "Take SPANS, a finished trace's spans, root last. Must return promptly: it
is called on the thread that ran the turn, at the end of the turn."))

(defgeneric flush-exporter (exporter &key timeout)
  (:documentation "Wait at most TIMEOUT seconds for EXPORTER to send what it holds. Returns T
when nothing is left to send.")
  (:method (exporter &key timeout)
    (declare (ignore exporter timeout))
    t))

(defgeneric shutdown-exporter (exporter &key timeout)
  (:documentation "Send what EXPORTER holds, waiting at most TIMEOUT seconds, and stop it.")
  (:method (exporter &key timeout)
    (declare (ignore exporter timeout))
    t))

;;; --- in memory -------------------------------------------------------------------------------

(defclass memory-exporter ()
  ((spans :initform '() :accessor %memory-spans)
   (lock :initform (bt:make-lock "praxeon/trace memory exporter") :reader %memory-lock))
  (:documentation "Keeps every exported span in the image, for tests and the REPL."))

(defun make-memory-exporter ()
  "An exporter that keeps spans in the image. Read them with EXPORTED-SPANS."
  (make-instance 'memory-exporter))

(defmethod export-spans ((exporter memory-exporter) spans)
  (bt:with-lock-held ((%memory-lock exporter))
    (setf (%memory-spans exporter) (append (%memory-spans exporter) (copy-list spans))))
  nil)

(defun exported-spans (exporter)
  "Every span EXPORTER has been given, oldest trace first."
  (bt:with-lock-held ((%memory-lock exporter))
    (copy-list (%memory-spans exporter))))

(defun clear-exported (exporter)
  "Forget the spans EXPORTER holds."
  (bt:with-lock-held ((%memory-lock exporter))
    (setf (%memory-spans exporter) '()))
  nil)

;;; --- OTLP JSON encoding ----------------------------------------------------------------------
;;;
;;; The OTLP/HTTP JSON encoding of an ExportTraceServiceRequest
;;; (https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding): trace and span ids as
;;; hex strings, 64-bit integers (times, integer attributes) as decimal strings, enums as
;;; integers.

(defun %object (&rest pairs)
  (let ((table (make-hash-table :test 'equal)))
    (loop for (key value) on pairs by #'cddr do (setf (gethash key table) value))
    table))

(defun %any-value (value)
  "VALUE as an OTLP AnyValue."
  (etypecase value
    (string (%object "stringValue" value))
    (integer (%object "intValue" (princ-to-string value)))
    (real (%object "doubleValue" (coerce value 'double-float)))
    ((eql t) (%object "boolValue" t))
    (list (%object "arrayValue" (%object "values" (map 'vector #'%any-value value))))))

(defun %key-values (attributes)
  (map 'vector (lambda (cell) (%object "key" (car cell) "value" (%any-value (cdr cell))))
       attributes))

(defun %span-kind (kind)
  (ecase kind (:internal 1) (:server 2) (:client 3) (:producer 4) (:consumer 5)))

(defun %status-code (status)
  (ecase status (:unset 0) (:ok 1) (:error 2)))

(defun %otlp-span (span)
  (let ((object (%object "traceId" (span-trace-id span)
                         "spanId" (span-span-id span)
                         "name" (span-name span)
                         "kind" (%span-kind (span-kind span))
                         "startTimeUnixNano" (princ-to-string (span-start span))
                         "endTimeUnixNano" (princ-to-string (or (span-end span) (span-start span)))
                         "attributes" (%key-values (span-attributes span))
                         "status" (%object "code" (%status-code (span-status span))))))
    (when (span-parent-id span)
      (setf (gethash "parentSpanId" object) (span-parent-id span)))
    object))

(defun otlp-document (spans &key (service-name "praxeon"))
  "SPANS as an OTLP ExportTraceServiceRequest, in the hash tables and vectors jzon writes. A
pure function: no IO."
  (%object "resourceSpans"
           (vector
            (%object "resource" (%object "attributes"
                                         (%key-values (list (cons "service.name" service-name))))
                     "scopeSpans"
                     (vector (%object "scope" (%object "name" "praxeon/trace"
                                                       "version" "0.1.0")
                                      "spans" (map 'vector #'%otlp-span spans)))))))

(defun otlp-json (spans &key (service-name "praxeon"))
  "SPANS as the OTLP/HTTP JSON body for /v1/traces."
  (jzon:stringify (otlp-document spans :service-name service-name)))

;;; --- OTLP over HTTP, in batches, from a thread of its own ------------------------------------

(defclass otlp-exporter ()
  ((endpoint :initarg :endpoint :reader otlp-exporter-endpoint)
   (headers :initarg :headers :reader %otlp-headers)
   (service-name :initarg :service-name :reader %otlp-service-name)
   (batch-size :initarg :batch-size :reader %otlp-batch-size)
   (interval :initarg :interval :reader %otlp-interval)
   (max-queue :initarg :max-queue :reader %otlp-max-queue)
   (timeout :initarg :timeout :reader %otlp-timeout)
   (lock :initform (bt:make-lock "praxeon/trace otlp exporter") :reader %otlp-lock)
   (wake :initform (bt:make-condition-variable) :reader %otlp-wake)
   (queue :initform '() :accessor %otlp-queue)
   (queued :initform 0 :accessor %otlp-queued)
   (in-flight :initform 0 :accessor %otlp-in-flight)
   (thread :initform nil :accessor %otlp-thread)
   (stopping :initform nil :accessor %otlp-stopping)
   (flushing :initform nil :accessor %otlp-flushing)
   (sent :initform 0 :accessor otlp-exporter-sent-spans)
   (failed-batches :initform 0 :accessor otlp-exporter-failed-batches)
   (failed-spans :initform 0 :accessor otlp-exporter-failed-spans)
   (dropped :initform 0 :accessor otlp-exporter-dropped-spans))
  (:documentation "Sends spans to an OpenTelemetry collector over OTLP/HTTP with the JSON
encoding. EXPORT-SPANS only queues them; a thread of the exporter's own, started on first use,
sends a batch every INTERVAL seconds, or as soon as BATCH-SIZE spans are waiting. A batch that
fails is logged with a count, through aion/log, and dropped; it is never retried, and a turn
never waits for it. When MAX-QUEUE spans are already waiting, new ones are dropped and counted."))

(defun make-otlp-exporter (&key (endpoint "http://localhost:4318/v1/traces") headers
                                (service-name "praxeon") (batch-size 512) (interval 5)
                                (max-queue 2048) (timeout 10))
  "An exporter that sends spans to the collector at ENDPOINT, the full URL of its /v1/traces.
HEADERS is an alist of (name . value) sent with every request, such as a collector's
Authorization header. SERVICE-NAME is the service.name resource attribute. TIMEOUT, in
seconds, limits one request as a whole. Call SHUTDOWN-EXPORTER when the app stops, so the last
batch is sent."
  (make-instance 'otlp-exporter :endpoint endpoint :headers headers :service-name service-name
                                :batch-size batch-size :interval interval
                                :max-queue max-queue :timeout timeout))

(defun %parse-otlp-headers (text)
  "OTEL_EXPORTER_OTLP_HEADERS' value, key=value pairs separated by commas, as an alist. Values
are percent-decoded, as the OpenTelemetry specification says."
  (loop for pair in (uiop:split-string (or text "") :separator ",")
        for at = (position #\= pair)
        when (and at (plusp at))
          collect (cons (string-trim " " (subseq pair 0 at))
                        (quri:url-decode (string-trim " " (subseq pair (1+ at)))))))

(defun make-otlp-exporter-from-env (&rest options)
  "An OTLP-EXPORTER configured from the OpenTelemetry environment variables:
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT (the full URL), else OTEL_EXPORTER_OTLP_ENDPOINT with
/v1/traces added, else http://localhost:4318/v1/traces; OTEL_EXPORTER_OTLP_TRACES_HEADERS or
OTEL_EXPORTER_OTLP_HEADERS; and OTEL_SERVICE_NAME. OPTIONS are MAKE-OTLP-EXPORTER's, and
override the environment."
  (flet ((env (name) (let ((v (uiop:getenv name))) (and v (plusp (length v)) v))))
    (let ((endpoint (or (env "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
                        (let ((base (env "OTEL_EXPORTER_OTLP_ENDPOINT")))
                          (and base (concatenate 'string (string-right-trim "/" base)
                                                 "/v1/traces")))
                        "http://localhost:4318/v1/traces"))
          (headers (%parse-otlp-headers (or (env "OTEL_EXPORTER_OTLP_TRACES_HEADERS")
                                            (env "OTEL_EXPORTER_OTLP_HEADERS"))))
          (service-name (or (env "OTEL_SERVICE_NAME") "praxeon")))
      (apply #'make-otlp-exporter
             (append options (list :endpoint endpoint :headers headers
                                   :service-name service-name))))))

(defun %otlp-start (exporter)
  "Start EXPORTER's thread unless it runs. Called with the lock held."
  (unless (and (%otlp-thread exporter) (bt:thread-alive-p (%otlp-thread exporter)))
    ;; The exporter outlives any one turn and sends the spans of every turn, so it must not
    ;; inherit the bindings of the turn that happened to start it: above all not
    ;; EVT:*OBSERVER*, or its own work would be reported to that turn's observer, nor the
    ;; turn's aion/log context, which would put one request's id on every later line. It
    ;; unblocks the deferrable signals first, as every long-lived thread here does (#541).
    (setf (%otlp-thread exporter)
          ;; THREAD-LIFETIME: independent of every turn, for the reasons above.
          (bt:make-thread (lambda ()
                            (aion/dynamic:unblock-interrupts)
                            (%otlp-run exporter))
                          :name "praxeon/trace otlp exporter"))))

(defmethod export-spans ((exporter otlp-exporter) spans)
  (let ((dropped 0))
    (bt:with-lock-held ((%otlp-lock exporter))
      (unless (%otlp-stopping exporter)
        (dolist (span spans)
          (if (< (%otlp-queued exporter) (%otlp-max-queue exporter))
              (progn (push span (%otlp-queue exporter))
                     (incf (%otlp-queued exporter)))
              (incf dropped)))
        (incf (otlp-exporter-dropped-spans exporter) dropped)
        (%otlp-start exporter)
        (when (>= (%otlp-queued exporter) (%otlp-batch-size exporter))
          (bt:condition-notify (%otlp-wake exporter)))))
    (when (plusp dropped)
      (log:warn "praxeon/trace: spans dropped, the export queue is full"
                :spans dropped :dropped-total (otlp-exporter-dropped-spans exporter))))
  nil)

(defun %otlp-take (exporter)
  "Up to BATCH-SIZE of the oldest queued spans, removed from the queue. Called with the lock
held."
  (let* ((oldest-first (reverse (%otlp-queue exporter)))
         (n (min (length oldest-first) (%otlp-batch-size exporter)))
         (batch (subseq oldest-first 0 n)))
    (setf (%otlp-queue exporter) (reverse (nthcdr n oldest-first)))
    (decf (%otlp-queued exporter) n)
    batch))

(defun %otlp-send (exporter batch)
  "POST BATCH to the collector. A failure is logged with counts and goes no further."
  (handler-case
      (progn
        (http:send-request
         (http:make-request :method :post :url (otlp-exporter-endpoint exporter)
                            :headers (cons '("content-type" . "application/json")
                                           (%otlp-headers exporter))
                            :content (otlp-json batch :service-name
                                                (%otlp-service-name exporter)))
         (list (http:ensure-2xx "praxeon/trace"))
         :deadline (%otlp-timeout exporter))
        (bt:with-lock-held ((%otlp-lock exporter))
          (incf (otlp-exporter-sent-spans exporter) (length batch))))
    (error (e)
      (let ((batches (bt:with-lock-held ((%otlp-lock exporter))
                       (incf (otlp-exporter-failed-spans exporter) (length batch))
                       (incf (otlp-exporter-failed-batches exporter)))))
        (log:warn "praxeon/trace: export failed"
                  :spans (length batch) :failed-batches batches
                  :status (and (typep e 'http:http-error) (http:http-error-status e))
                  :condition (log:condition-type e))))))

(defun %otlp-run (exporter)
  "The exporter thread: wait for a full batch, a flush, a stop or INTERVAL seconds, then send
everything queued, a batch at a time. Ends when stopped with nothing left to send."
  (let ((lock (%otlp-lock exporter)))
    (loop
      (let ((batch nil))
        (bt:with-lock-held (lock)
          (when (and (%otlp-stopping exporter) (null (%otlp-queue exporter)))
            (return))
          (when (and (< (%otlp-queued exporter) (%otlp-batch-size exporter))
                     (not (%otlp-stopping exporter))
                     (not (and (%otlp-flushing exporter) (%otlp-queue exporter))))
            (bt:condition-wait (%otlp-wake exporter) lock :timeout (%otlp-interval exporter)))
          (setf batch (%otlp-take exporter))
          (when batch (incf (%otlp-in-flight exporter))))
        (when batch
          (unwind-protect (%otlp-send exporter batch)
            (bt:with-lock-held (lock)
              (decf (%otlp-in-flight exporter))
              (when (null (%otlp-queue exporter)) (setf (%otlp-flushing exporter) nil))
              (bt:condition-notify (%otlp-wake exporter)))))))))

(defun %otlp-idle-p (exporter)
  (and (null (%otlp-queue exporter)) (zerop (%otlp-in-flight exporter))))

(defmethod flush-exporter ((exporter otlp-exporter) &key (timeout 30))
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second)))
        (lock (%otlp-lock exporter)))
    (bt:with-lock-held (lock)
      (unless (%otlp-idle-p exporter)
        (setf (%otlp-flushing exporter) t)
        (%otlp-start exporter)
        (bt:condition-notify (%otlp-wake exporter)))
      ;; Waits in short slices, because this thread and the exporter thread wait on the same
      ;; condition variable, and a notify meant for one can wake the other.
      (loop until (or (%otlp-idle-p exporter) (>= (get-internal-real-time) deadline))
            do (bt:condition-wait (%otlp-wake exporter) lock :timeout 0.05))
      (%otlp-idle-p exporter))))

(defmethod shutdown-exporter ((exporter otlp-exporter) &key (timeout 30))
  (let ((done (flush-exporter exporter :timeout timeout))
        (thread nil))
    (bt:with-lock-held ((%otlp-lock exporter))
      (setf (%otlp-stopping exporter) t
            thread (%otlp-thread exporter))
      (bt:condition-notify (%otlp-wake exporter)))
    (when (and thread (bt:thread-alive-p thread))
      (sb-thread:join-thread thread :default nil :timeout (max 1 timeout)))
    done))
