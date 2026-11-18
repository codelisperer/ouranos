;;;; watch.lisp --- what the page did while a row ran (#1028, dokimasia ADR-0001, point 2).
;;;;
;;;; The page's events, which aion/cdp keeps in order, are read after and during every step. From
;;;; them this file keeps the requests in flight, which the settle check waits on; the requests
;;;; made to each URL during the step, which catch a fetch, poll or resubmit loop; same-origin
;;;; responses of 500 or more; and console errors, uncaught exceptions and log errors, which
;;;; include Content-Security-Policy violations. Each of the last three fails the step it
;;;; happened in, unless the suite lists a console message as known, or the log error is about the
;;;; request for /favicon.ico that the browser makes by itself for a page that links no icon.

(in-package #:dokimasia)

(defvar *settle-timeout* 10
  "Seconds the page may take to settle after an action before the step fails.")

(defvar *step-timeout* 10
  "Seconds a step that waits, such as :EXPECT-SCREEN, waits when it has no :TIMEOUT of its own.")

(defvar *quiet-period* 0.3
  "Seconds with no request in flight after which the network check calls the page settled.")

(defstruct (row (:constructor %make-row))
  page base-url origin target suite user inputs
  (in-flight (make-hash-table :test 'equal))
  (last-activity (get-internal-real-time))
  (step-requests (make-hash-table :test 'equal))
  (step-problems '())
  (console '())
  (network '())
  (artifacts '())
  (events-dropped 0))

(setf (documentation 'row-page 'function)
      "The aion/cdp PAGE the current row runs in."
      (documentation 'row-base-url 'function)
      "The base URL of the target the current row runs against.")

(defvar *row* nil
  "The row being run, while a step, a settle check or a probe runs. Read its page with ROW-PAGE.")

(defparameter +unwatched-request-types+ '("EventSource" "WebSocket")
  "Request types that stay open by design, so the settle check does not wait for them.")

(defun %origin (url)
  "The scheme, host and port of URL, or NIL when URL has no authority."
  (let ((p (search "://" url)))
    (when p
      (let ((end (or (position #\/ url :start (+ p 3)) (length url))))
        (string-downcase (subseq url 0 end))))))

(defun %without-fragment (url)
  (subseq url 0 (or (position #\# url) (length url))))

(defun %elapsed-ms (since)
  (round (* 1000 (- (get-internal-real-time) since)) internal-time-units-per-second))

(defun %console-text (params)
  "The text of a Runtime.consoleAPICalled event: its arguments' values joined by spaces."
  (let ((args (cdp:json-get params "args")))
    (format nil "~{~A~^ ~}"
            (map 'list (lambda (a)
                         (let ((v (cdp:json-get a "value")))
                           (cond ((stringp v) v)
                                 (v (princ-to-string v))
                                 (t (or (cdp:json-get a "description")
                                        (cdp:json-get a "type") "")))))
                 (or args #())))))

(defun %ignored-p (row message)
  (some (lambda (known) (search known message)) (suite-ignore-console (row-suite row))))

(defun %console-finding (row kind message)
  (let ((ignored (%ignored-p row message)))
    (push (list :kind kind :message message :ignored (and ignored t)) (row-console row))
    (unless ignored
      (push (format nil "~A: ~A" kind message) (row-step-problems row)))))

(defparameter +page-links-an-icon+
  "document.querySelector('link[rel~=\"icon\" i]') ? 'linked' : 'none'"
  "An expression that is \"none\" when the page has no <link rel=\"icon\">.")

(defun %browser-favicon-request-p (row url)
  "True when URL is the request for /favicon.ico at the target's origin that the browser makes by
itself, which it does only for a page that links no icon. Nothing in the request's events tells it
apart from a request the page made (both have the initiator type \"other\"), so this reads the
page: when the page links an icon, a request for /favicon.ico came from the page and is checked
like any other. When the page cannot be read, the request is checked too."
  (and (stringp url)
       (row-origin row)
       (string-equal (subseq url 0 (or (position-if (lambda (c) (member c '(#\? #\#))) url)
                                       (length url)))
                     (format nil "~A/favicon.ico" (row-origin row)))
       (row-page row)
       (equal "none" (ignore-errors (cdp:evaluate (row-page row) +page-links-an-icon+ :timeout 2)))))

(defun %handle-event (row event)
  (let ((method (cdp:event-method event))
        (params (cdp:event-params event)))
    (cond
      ((string= method "Network.requestWillBeSent")
       (let ((id (cdp:json-get params "requestId"))
             (url (cdp:json-get params "request" "url"))
             (type (cdp:json-get params "type")))
         (setf (row-last-activity row) (get-internal-real-time))
         (when (and id url (not (member type +unwatched-request-types+ :test #'equal))
                    (not (uiop:string-prefix-p "data:" url)))
           (setf (gethash id (row-in-flight row)) url))
         (when url
           (incf (gethash (%without-fragment url) (row-step-requests row) 0)))))
      ((member method '("Network.loadingFinished" "Network.loadingFailed") :test #'string=)
       (setf (row-last-activity row) (get-internal-real-time))
       (remhash (cdp:json-get params "requestId") (row-in-flight row))
       (when (and (string= method "Network.loadingFailed")
                  (not (cdp:json-get params "canceled")))
         (push (list :kind "failed" :message (or (cdp:json-get params "errorText") "")
                     :request-id (cdp:json-get params "requestId"))
               (row-network row))))
      ((string= method "Network.responseReceived")
       (let ((status (cdp:json-get params "response" "status"))
             (url (cdp:json-get params "response" "url")))
         (when (and (integerp status) (>= status 500) url)
           (push (list :kind "server-error" :status status :url url) (row-network row))
           (when (equal (%origin url) (row-origin row))
             (push (format nil "the response to ~A had the status ~D" url status)
                   (row-step-problems row))))))
      ((string= method "Runtime.consoleAPICalled")
       (when (member (cdp:json-get params "type") '("error" "assert") :test #'equal)
         (%console-finding row "console error" (%console-text params))))
      ((string= method "Runtime.exceptionThrown")
       (%console-finding row "uncaught exception"
                         (or (cdp:json-get params "exceptionDetails" "exception" "description")
                             (cdp:json-get params "exceptionDetails" "text")
                             "")))
      ((string= method "Log.entryAdded")
       (when (equal (cdp:json-get params "entry" "level") "error")
         (let ((kind (format nil "log error (~A)"
                             (or (cdp:json-get params "entry" "source") "unknown")))
               (text (or (cdp:json-get params "entry" "text") "")))
           (if (and (equal (cdp:json-get params "entry" "source") "network")
                    (%browser-favicon-request-p row (cdp:json-get params "entry" "url")))
               ;; Kept in the report, but it fails no step: the app did not ask for it.
               (push (list :kind kind :message text :ignored t
                           :why "the browser's own request for /favicon.ico; the page links no icon")
                     (row-console row))
               (%console-finding row kind text))))))))

(defun %pump (row)
  "Read ROW's page's events since the last call into ROW."
  (dolist (event (cdp:drain-events (row-page row)))
    (%handle-event row event))
  (let ((dropped (cdp:page-events-dropped (row-page row))))
    (when (> dropped (row-events-dropped row))
      (push (format nil "~D page events were dropped because the buffer was full, so this step's checks are incomplete"
                    (- dropped (row-events-dropped row)))
            (row-step-problems row))
      (setf (row-events-dropped row) dropped))))

(defun %begin-step (row)
  "Clear what ROW counts per step, after reading the events that came before it."
  (%pump row)
  (clrhash (row-step-requests row))
  (setf (row-step-problems row) '()))

(defun %end-step-problems (row)
  "The problems the checks made after every step found in the step just run, oldest first."
  (%pump row)
  (let ((limit (suite-max-requests-per-url (row-suite row))))
    (maphash (lambda (url n)
               (when (> n limit)
                 (push (format nil "~D requests to ~A in one step; the limit is ~D" n url limit)
                       (row-step-problems row))))
             (row-step-requests row)))
  (reverse (row-step-problems row)))

(defmethod target-settle ((target target) page timeout)
  (declare (ignore page))
  (let ((row *row*)
        (deadline (+ (get-internal-real-time) (round (* timeout internal-time-units-per-second))))
        (quiet (round (* *quiet-period* internal-time-units-per-second))))
    (loop
      (%pump row)
      (let ((now (get-internal-real-time)))
        (when (and (zerop (hash-table-count (row-in-flight row)))
                   (>= (- now (row-last-activity row)) quiet))
          (return nil))
        (when (> now deadline)
          (let ((urls '()))
            (maphash (lambda (k v) (declare (ignore k)) (push v urls)) (row-in-flight row))
            (return (format nil "the page did not settle within ~A seconds: ~D request~:P still in flight~@[, such as ~{~A~^, ~}~]"
                            timeout (length urls) (subseq urls 0 (min 3 (length urls)))))))
        (sleep 0.05)))))
