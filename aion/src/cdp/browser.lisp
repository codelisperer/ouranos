;;;; browser.lisp --- launching, attaching, closing, pages, and the commands (#1028).

(cl:in-package #:aion/cdp)

(defstruct (browser (:constructor %make-browser (connection &key process directory stderr)))
  "A browser this process launched or attached to. Made by LAUNCH-BROWSER or ATTACH-BROWSER."
  (connection nil :read-only t)
  (process nil :read-only t)          ; NIL for an attached browser
  (directory nil :read-only t)        ; the temporary directory holding the profile
  (stderr nil :read-only t)
  (version nil)
  (pages '())
  (closed-p nil))

(defun browser-launched-p (browser)
  "Whether this process launched BROWSER, rather than attaching to it."
  (and (browser-process browser) t))

(defun browser-pid (browser)
  "The process id of a browser this process launched, or NIL for an attached one."
  (let ((p (browser-process browser))) (and p (%pid p))))

;;; --- launching ----------------------------------------------------------------------

(defun %delete-directory (dir)
  "Delete DIR and everything in it. A browser that has just exited can still hold a file open
on Windows for a moment, so a failure is retried for up to two seconds, and then logged."
  (loop repeat 40
        do (handler-case (progn (aion/fs:delete-tree dir) (return))
             (error () (sleep 0.05)))
        finally (log:warn "aion/cdp: the browser's temporary directory could not be deleted"
                          :directory (uiop:native-namestring dir))))

(defun launch-browser (&key executable arguments (timeout *default-timeout*) (transport :port))
  "Start a browser headless, with a fresh profile, connect to it, and return a BROWSER.

EXECUTABLE is the browser to run; by default FIND-BROWSER's answer. ARGUMENTS are extra
command-line arguments, checked by CHECK-BROWSER-ARGUMENTS before anything starts: none may
set the headless mode, the debugging port or pipe, or the profile. BROWSER-COMMAND-LINE gives
the exact command line. TIMEOUT is how many seconds the browser has to start and answer.
TRANSPORT is :PORT, the only one until the pipe transport arrives (#1028, step (c)).

Signals BROWSER-NOT-FOUND, BROWSER-EXITED or CDP-TIMEOUT. On any failure the process is ended
and its profile deleted. CLOSE-BROWSER ends a browser that started; WITH-BROWSER calls it."
  (unless (eq transport :port)
    (error "LAUNCH-BROWSER's transport is :PORT; the pipe transport is step (c) of #1028. Got ~S."
           transport))
  (check-browser-arguments arguments)
  (let ((exe (or executable (find-browser) (error 'browser-not-found))))
    (unless (probe-file (uiop:parse-native-namestring exe))
      (error 'browser-not-found :executable exe))
    (let* ((dir (aion/fs:make-temporary-directory "aion-cdp"))
           (profile (merge-pathnames (make-pathname :directory '(:relative "profile")) dir))
           (stderr (merge-pathnames "browser-stderr.log" dir))
           (deadline (%deadline timeout))
           (started (get-internal-real-time))
           (process nil) (connection nil) (browser nil))
      (unwind-protect
           (progn
             (ensure-directories-exist profile)
             (setf process (%spawn (browser-command-line
                                    exe (string-right-trim "/\\" (uiop:native-namestring profile))
                                    :arguments arguments)
                                   stderr))
             (multiple-value-bind (port path)
                 (loop
                   (multiple-value-bind (port path) (%read-active-port profile)
                     (when port (return (values port path))))
                   (unless (%alive-p process)
                     (error 'browser-exited :code (%exit-code process) :output (%file-tail stderr)))
                   (when (<= (%remaining deadline) 0)
                     (error 'cdp-timeout :what "The browser's start" :seconds timeout))
                   (sleep 0.05))
               (setf connection (%open-connection "127.0.0.1" port path
                                                  (max 1 (%remaining deadline))))
               (let ((b (%make-browser connection :process process :directory dir
                                                  :stderr stderr)))
                 (setf (browser-version b)
                       (json-get (%command connection "Browser.getVersion" nil nil
                                           (max 1 (%remaining deadline)))
                                 "product"))
                 (log:info "aion/cdp: browser started" :pid (%pid process)
                                                       :version (browser-version b)
                                                       :ms (round (* 1000 (- (get-internal-real-time) started))
                                                                  internal-time-units-per-second))
                 (setf browser b))))
        (unless browser
          (when connection (%shutdown-connection connection))
          (when process (%kill process))
          (%delete-directory dir))))))

;;; --- attaching ------------------------------------------------------------------------

(defun %parse-ws-url (url)
  "The host, port and path of URL, a ws:// URL with a port, as three values, or NIL."
  (when (and (> (length url) 5) (string-equal "ws://" url :end2 5))
    (let* ((rest (subseq url 5))
           (slash (or (position #\/ rest) (length rest)))
           (authority (subseq rest 0 slash))
           (colon (position #\: authority :from-end t))
           (port (and colon (ignore-errors (parse-integer authority :start (1+ colon))))))
      (when (and port (< 0 port 65536) (plusp colon))
        (values (subseq authority 0 colon) port
                (if (< slash (length rest)) (subseq rest slash) "/"))))))

(defun attach-browser (url &key (timeout *default-timeout*))
  "Connect to a browser already running on this machine, at URL, the ws:// address of its
debugging endpoint (the webSocketDebuggerUrl of its /json/version). Returns a BROWSER.

The host must be a loopback address (127.x.x.x or localhost), because CDP has no
authentication and its port should never be reached over a network. CLOSE-BROWSER on an
attached browser closes the pages this process opened and disconnects; it does not end the
browser, which someone else started."
  (multiple-value-bind (host port path) (%parse-ws-url url)
    (unless host
      (error "ATTACH-BROWSER takes a ws://host:port/path URL; got ~S." url))
    (unless (%loopback-address host)
      (error "ATTACH-BROWSER connects only to a loopback address; ~S is not one." host))
    (let* ((connection (%open-connection host port path timeout))
           (browser (%make-browser connection)))
      (handler-case
          (setf (browser-version browser)
                (json-get (%command connection "Browser.getVersion" nil nil timeout) "product"))
        (error (e) (%shutdown-connection connection) (error e)))
      browser)))

;;; --- closing ---------------------------------------------------------------------------

(defun close-browser (browser)
  "End BROWSER and release what it holds. Idempotent.

A browser this process launched is asked to close (Browser.close), given five seconds to
exit, then killed if it has not, and its profile is deleted. For an attached browser, the
pages this process opened are closed and the connection is ended."
  (unless (browser-closed-p browser)
    (setf (browser-closed-p browser) t)
    (let ((connection (browser-connection browser))
          (process (browser-process browser))
          (ended nil))
      (unwind-protect
           (progn
             (if process
                 (ignore-errors (%command connection "Browser.close" nil nil 5))
                 (dolist (page (browser-pages browser))
                   (ignore-errors (%command connection "Target.closeTarget"
                                            (json-object "targetId" (page-target-id page))
                                            nil 5))))
             (%shutdown-connection connection)
             (when (and process (%wait-for-exit process 5))
               (%release process)
               (setf ended t)))
        (when (and process (not ended))
          (log:warn "aion/cdp: the browser did not exit when asked; killing it"
                    :pid (%pid process))
          (%kill process))
        (when (browser-directory browser)
          (%delete-directory (browser-directory browser))))))
  nil)

(defmacro with-browser ((var &rest launch-arguments) &body body)
  "Run BODY with VAR bound to a browser started by LAUNCH-BROWSER with LAUNCH-ARGUMENTS, and
close it with CLOSE-BROWSER however BODY ends."
  `(let ((,var (launch-browser ,@launch-arguments)))
     (unwind-protect (progn ,@body)
       (close-browser ,var))))

;;; --- pages -------------------------------------------------------------------------------

(defun %page-command (page method params timeout)
  (let ((connection (browser-connection (page-browser page))))
    (when (page-crashed-p page)
      (error 'target-crashed :target-id (page-target-id page)))
    (handler-case (%command connection method params (page-session-id page) timeout)
      ((or cdp-timeout cdp-error) (e)
        (if (page-crashed-p page)
            (error 'target-crashed :target-id (page-target-id page))
            (error e))))))

(defun send (target method &key params (timeout *default-timeout*))
  "Send the CDP command METHOD with PARAMS (a JSON-OBJECT, or NIL for none) to TARGET, a PAGE or
a BROWSER, and return its result, a parsed JSON object (read it with JSON-GET). For any command
this package has no function for."
  (etypecase target
    (page (%page-command target method params timeout))
    (browser (%command (browser-connection target) method params nil timeout))))

(defparameter +page-domains+
  '("Page.enable" "Runtime.enable" "Log.enable" "Network.enable" "Inspector.enable")
  "The CDP domains NEW-PAGE enables, so the page's events arrive.")

(defun new-page (browser &key (url "about:blank") (timeout *default-timeout*))
  "Open a new tab in BROWSER, attach to it, enable its events, navigate it to URL, and return a
PAGE."
  (let* ((connection (browser-connection browser))
         (target-id (json-get (%command connection "Target.createTarget"
                                        (json-object "url" "about:blank") nil timeout)
                              "targetId"))
         (session-id (json-get (%command connection "Target.attachToTarget"
                                         (json-object "targetId" target-id "flatten" t)
                                         nil timeout)
                               "sessionId"))
         (page (%make-page browser target-id session-id)))
    (sb-thread:with-mutex ((connection-lock connection))
      (setf (gethash session-id (connection-sessions connection)) page))
    (push page (browser-pages browser))
    (dolist (method +page-domains+)
      (%page-command page method nil timeout))
    (%page-command page "Page.setLifecycleEventsEnabled" (json-object "enabled" t) timeout)
    (unless (string= url "about:blank")
      (navigate page url :timeout timeout))
    page))

(defun close-page (page &key (timeout *default-timeout*))
  "Close PAGE's tab."
  (let* ((browser (page-browser page))
         (connection (browser-connection browser)))
    (%command connection "Target.closeTarget" (json-object "targetId" (page-target-id page))
              nil timeout)
    (sb-thread:with-mutex ((connection-lock connection))
      (remhash (page-session-id page) (connection-sessions connection)))
    (setf (browser-pages browser) (remove page (browser-pages browser)))
    nil))

(defun drain-events (page)
  "PAGE's events since the last call, oldest first, as a list of EVENT; the buffer is emptied.
PAGE-EVENTS-DROPPED says how many were dropped because the buffer held *MAX-BUFFERED-EVENTS*."
  (let ((connection (browser-connection (page-browser page))))
    (sb-thread:with-mutex ((connection-lock connection))
      (prog1 (reverse (page-events page))
        (setf (page-events page) '()
              (page-event-count page) 0)))))

(defun %wait-for-event (page test timeout what)
  "Wait up to TIMEOUT seconds for an event in PAGE's buffer for which TEST is true, without
removing anything. Signals CDP-TIMEOUT, TARGET-CRASHED or CONNECTION-CLOSED."
  (let* ((connection (browser-connection (page-browser page)))
         (lock (connection-lock connection))
         (deadline (%deadline timeout)))
    (sb-thread:with-mutex (lock)
      (loop
        (when (some test (page-events page)) (return t))
        (when (page-crashed-p page)
          (error 'target-crashed :target-id (page-target-id page)))
        (unless (eq (connection-state connection) :open)
          (error 'connection-closed :reason (connection-close-reason connection)))
        (let ((left (%remaining deadline)))
          (when (<= left 0) (error 'cdp-timeout :what what :seconds timeout))
          (%wait-on connection left))))))

;;; --- commands -------------------------------------------------------------------------------

(defun %js-string (string)
  "STRING as a JavaScript string literal."
  (jzon:stringify string))

(defun navigate (page url &key (timeout *default-timeout*))
  "Navigate PAGE to URL and wait until its load event. Signals CDP-ERROR when the browser
reports the navigation failed, such as a refused connection, and CDP-TIMEOUT when the page does
not load within TIMEOUT seconds."
  (let* ((deadline (%deadline timeout))
         (result (%page-command page "Page.navigate" (json-object "url" url) timeout))
         (error-text (json-get result "errorText"))
         (loader (json-get result "loaderId")))
    (when (and error-text (plusp (length error-text)))
      (error 'cdp-error :method "Page.navigate" :message (format nil "~A: ~A" url error-text)))
    (when loader
      (%wait-for-event page
                       (lambda (e)
                         (and (string= (event-method e) "Page.lifecycleEvent")
                              (equal (json-get (event-params e) "name") "load")
                              (equal (json-get (event-params e) "loaderId") loader)))
                       (max 0 (%remaining deadline))
                       (format nil "Loading ~A" url)))
    nil))

(defun evaluate (page expression &key (timeout *default-timeout*))
  "The value of the JavaScript EXPRESSION in PAGE, as parsed JSON: a string, number, T, NIL for
false, null or undefined, a vector for an array, or a hash table for an object. A promise is
awaited. Signals EVALUATION-ERROR when the expression throws or its promise is rejected."
  (let* ((result (%page-command page "Runtime.evaluate"
                                (json-object "expression" expression
                                             "returnByValue" t
                                             "awaitPromise" t)
                                timeout))
         (exception (json-get result "exceptionDetails")))
    (when exception
      (error 'evaluation-error
             :method "Runtime.evaluate"
             :message (or (json-get exception "exception" "description")
                          (json-get exception "text")
                          "the expression threw")))
    (json-get result "result" "value")))

(defun wait-for (page &key expression selector (timeout *default-timeout*) (interval 0.05))
  "Wait until the JavaScript EXPRESSION is truthy in PAGE, or until an element matches the CSS
SELECTOR; give exactly one. Checked every INTERVAL seconds. A check that fails, as one does
while a new document replaces the old, is tried again. Signals CDP-TIMEOUT after TIMEOUT
seconds, naming the last error a check gave."
  (unless (and (or expression selector) (not (and expression selector)))
    (error "WAIT-FOR takes exactly one of :EXPRESSION and :SELECTOR."))
  (let ((script (if selector
                    (format nil "document.querySelector(~A) !== null" (%js-string selector))
                    (format nil "!!(~A)" expression)))
        (deadline (%deadline timeout))
        (last-error nil))
    (loop
      (handler-case
          (when (evaluate page script :timeout (max 1 (%remaining deadline)))
            (return t))
        (target-crashed (e) (error e))
        (cdp-error (e) (setf last-error e)))
      (when (<= (%remaining deadline) 0)
        (error 'cdp-timeout
               :what (format nil "Waiting for ~A~@[ (the last check failed: ~A)~]"
                             (if selector (format nil "the selector ~S" selector) expression)
                             last-error)
               :seconds timeout))
      (sleep interval))))

(defun query (page selector &key (timeout *default-timeout*))
  "How many elements in PAGE match the CSS SELECTOR."
  (evaluate page (format nil "document.querySelectorAll(~A).length" (%js-string selector))
            :timeout timeout))

(defun text-of (page selector &key (timeout *default-timeout*))
  "The rendered text (innerText) of the first element in PAGE matching SELECTOR, or NIL when
none matches."
  (evaluate page (format nil "(e => e ? e.innerText : null)(document.querySelector(~A))"
                         (%js-string selector))
            :timeout timeout))

(defun attribute-of (page selector name &key (timeout *default-timeout*))
  "The value of the attribute NAME of the first element in PAGE matching SELECTOR, or NIL when
no element matches or it has no such attribute."
  (evaluate page (format nil "(e => e ? e.getAttribute(~A) : null)(document.querySelector(~A))"
                         (%js-string name) (%js-string selector))
            :timeout timeout))

(defun click (page selector &key (timeout *default-timeout*))
  "Scroll the first element matching SELECTOR into view and click its centre with the mouse, as
a user would: a move, a press and a release of the left button. Signals ELEMENT-NOT-FOUND."
  (let ((centre (evaluate page
                          (format nil "(e => { if (!e) return null; e.scrollIntoView({block: 'center', inline: 'center'}); const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })(document.querySelector(~A))"
                                  (%js-string selector))
                          :timeout timeout)))
    (unless centre
      (error 'element-not-found :method "click" :selector selector))
    (let ((x (aref centre 0)) (y (aref centre 1)))
      (%page-command page "Input.dispatchMouseEvent"
                     (json-object "type" "mouseMoved" "x" x "y" y) timeout)
      (dolist (type '("mousePressed" "mouseReleased"))
        (%page-command page "Input.dispatchMouseEvent"
                       (json-object "type" type "x" x "y" y "button" "left" "clickCount" 1)
                       timeout)))
    nil))

(defun type-text (page selector text &key (timeout *default-timeout*))
  "Focus the first element matching SELECTOR and insert TEXT as if typed, which fires the
element's input events. Signals ELEMENT-NOT-FOUND."
  (unless (evaluate page (format nil "(e => { if (!e) return false; e.focus(); return true; })(document.querySelector(~A))"
                                 (%js-string selector))
                    :timeout timeout)
    (error 'element-not-found :method "type-text" :selector selector))
  (%page-command page "Input.insertText" (json-object "text" text) timeout)
  nil)

(defun set-viewport (page width height &key (scale 1) mobile (timeout *default-timeout*))
  "Make PAGE's viewport WIDTH by HEIGHT CSS pixels, with device scale factor SCALE, emulating a
mobile device when MOBILE is true."
  (%page-command page "Emulation.setDeviceMetricsOverride"
                 (json-object "width" width "height" height
                              "deviceScaleFactor" scale "mobile" (and mobile t))
                 timeout)
  nil)

(defun emulate-color-scheme (page scheme &key (timeout *default-timeout*))
  "Make PAGE's prefers-color-scheme media feature SCHEME: :LIGHT, :DARK, or NIL for the
browser's own."
  (check-type scheme (member :light :dark nil))
  (%page-command page "Emulation.setEmulatedMedia"
                 (json-object "features"
                              (vector (json-object "name" "prefers-color-scheme"
                                                   "value" (case scheme
                                                             (:light "light")
                                                             (:dark "dark")
                                                             (t "")))))
                 timeout)
  nil)

(defun screenshot (page &key full-page (timeout *default-timeout*))
  "A PNG of PAGE's viewport, as an octet vector; of the whole page when FULL-PAGE is true."
  (let ((params (json-object "format" "png")))
    (when full-page
      (let ((size (json-get (%page-command page "Page.getLayoutMetrics" nil timeout)
                            "cssContentSize")))
        (setf (gethash "captureBeyondViewport" params) t
              (gethash "clip" params) (json-object "x" 0 "y" 0
                                                   "width" (json-get size "width")
                                                   "height" (json-get size "height")
                                                   "scale" 1))))
    (let* ((data (json-get (%page-command page "Page.captureScreenshot" params timeout) "data"))
           (octets (and (stringp data) (ws:base64-decode data))))
      (or octets
          (error 'cdp-error :method "Page.captureScreenshot"
                            :message "the screenshot was not base64 data")))))
