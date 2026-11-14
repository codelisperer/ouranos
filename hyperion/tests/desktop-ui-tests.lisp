;;;; desktop-ui-tests.lisp --- hyperion/desktop-ui: state, windows, inspector, routes (#1218).
;;;;
;;;; No server and no window are started. The routes are called as a Clack application, with
;;;; the request body already cached, the way the Coalton REPL example's tests call theirs.
;;;; GET /events answers with a streaming body, a function of a writer; the tests of the push
;;;; feed run that function on a thread with a writer that collects what it is given. The same
;;;; stream is read over a socket from a real server in praxeon/examples/ouranos-ide/tests.

(cl:defpackage #:hyperion/desktop-ui/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:ui #:hyperion/desktop-ui)
                    (#:state #:hyperion/desktop-ui/state)
                    (#:http #:hyperion/http))
  (:export #:run-tests))

(cl:in-package #:hyperion/desktop-ui/tests)

(def-suite desktop-ui :description "hyperion/desktop-ui: a desktop of floating windows (#1218).")
(in-suite desktop-ui)

(defun run-tests () (run! 'desktop-ui))

;;; --- helpers -----------------------------------------------------------------------------

(defun %fields (s)
  "The six fields of a state, as a list."
  (list (state:state-x s) (state:state-y s) (state:state-width s) (state:state-height s)
        (state:state-z s) (state:state-shown? s)))

(defun %get (app path)
  "The status and body of GET PATH."
  (let ((response (funcall app (list :request-method :get :path-info path))))
    (values (first response) (apply #'concatenate 'string (third response)) (second response))))

(defun %post (app path &rest fields)
  "The status, body and headers of POST PATH with the form FIELDS (name value ...)."
  (let* ((body (format nil "~{~A=~A~^&~}" fields))
         (response (funcall app (http:cache-body-string
                                 (list :request-method :post :path-info path) body))))
    (values (first response) (apply #'concatenate 'string (third response)) (second response))))

(defun body-one (window)
  (declare (ignore window))
  "<p>first definition</p>")

(defun body-failing (window)
  (declare (ignore window))
  (error "deliberately broken"))

(defun echo-action (window parameters)
  (setf (ui:window-datum window :said) (cdr (assoc "text" parameters :test #'string=)))
  (format nil "<p>heard ~A</p>" (ui:window-datum window :said)))

(defun %desktop ()
  "A desktop with two windows: `one' at 10,20 and `two' at 300,40."
  (let ((d (ui:make-desktop :title "Test desktop")))
    (ui:open-window d "one" :title "One" :render 'body-one :x 10 :y 20 :width 200 :height 100
                            :actions '(("echo" . echo-action)) :data (list :count 3))
    (ui:open-window d "two" :title "Two" :render 'body-one :x 300 :y 40 :refresh 5)
    d))

;;; --- the Coalton core --------------------------------------------------------------------

(test apply-event-computes-the-next-state
  (let ((s (state:make-state 10 20 200 100 1)))
    (is (equal '(10 20 200 100 1 t) (%fields s)))
    (is (equal '(55 66 200 100 1 t) (%fields (state:apply-event (state:move-event 55 66) s))))
    (is (equal '(10 20 400 300 1 t) (%fields (state:apply-event (state:resize-event 400 300) s))))
    (is (equal '(10 20 200 100 7 t) (%fields (state:apply-event (state:raise-event 7) s))))
    (is (equal '(10 20 200 100 1 nil) (%fields (state:apply-event state:close-event s))))
    (is (equal '(10 20 200 100 1 t)
               (%fields (state:apply-event state:open-event
                                           (state:apply-event state:close-event s)))))
    (is (equal '(10 20 200 100 1 t) (%fields s)) "the original state is unchanged")))

(test apply-event-keeps-a-window-on-the-desktop-and-above-the-minimum-size
  (let ((s (state:make-state 10 20 200 100 5)))
    (is (equal '(0 0) (subseq (%fields (state:apply-event (state:move-event -30 -1) s)) 0 2)))
    (is (equal (list state:minimum-width state:minimum-height)
               (subseq (%fields (state:apply-event (state:resize-event 1 1) s)) 2 4)))
    (is (= 5 (state:state-z (state:apply-event (state:raise-event 2) s)))
        "a raise to a lower z leaves the window where it is")
    (is (equal (list 0 0 state:minimum-width state:minimum-height 1 t)
               (%fields (state:make-state -5 -5 0 0 1)))
        "MAKE-STATE holds a new window to the same limits")))

(test an-event-names-itself-and-lists-its-numbers
  (is (equal '(:name "move" :arguments (3 4)) (ui:inspect-event (state:move-event 3 4))))
  (is (equal '(:name "resize" :arguments (30 40)) (ui:inspect-event (state:resize-event 30 40))))
  (is (equal '(:name "raise" :arguments (9)) (ui:inspect-event (state:raise-event 9))))
  (is (equal '(:name "close" :arguments ()) (ui:inspect-event state:close-event)))
  (is (equal '(:name "open" :arguments ()) (ui:inspect-event state:open-event))))

;;; --- windows and events ------------------------------------------------------------------

(test a-new-window-is-placed-above-the-others
  (let ((d (%desktop)))
    (is (equal '("one" "two") (getf (ui:inspect-desktop d) :windows)))
    (is (= 1 (getf (ui:inspect-window (ui:find-window d "one")) :z)))
    (is (= 2 (getf (ui:inspect-window (ui:find-window d "two")) :z)))
    (is (= 2 (getf (ui:inspect-desktop d) :top-z)))
    (signals error (ui:open-window d "Not Valid" :render 'body-one))))

(test opening-a-window-with-an-existing-id-replaces-it
  (let ((d (%desktop)))
    (ui:open-window d "one" :title "One again" :render 'body-one)
    (is (equal '("two" "one") (getf (ui:inspect-desktop d) :windows)))
    (is (string= "One again" (ui:window-title (ui:find-window d "one"))))))

(test dispatch-event-changes-the-window-and-records-the-event
  (let ((d (%desktop)))
    (ui:dispatch-event d "one" (state:move-event 70 80))
    (ui:dispatch-event d "one" (ui:event-from-parameters d '(("type" . "raise"))))
    (let ((record (ui:inspect-window (ui:find-window d "one"))))
      (is (= 70 (getf record :x)))
      (is (= 80 (getf record :y)))
      (is (= 3 (getf record :z)) "raised above window two, which was at 2")
      (is (equal '((:name "raise" :arguments (3)) (:name "move" :arguments (70 80)))
                 (getf record :events))
          "newest first"))
    (signals ui:unknown-window (ui:dispatch-event d "absent" state:close-event))))

(test a-window-keeps-only-its-most-recent-events
  (let ((d (%desktop)) (ui:*event-history* 3))
    (dotimes (i 5) (ui:dispatch-event d "one" (state:move-event i i)))
    (is (equal '((4 4) (3 3) (2 2))
               (mapcar (lambda (e) (getf e :arguments))
                       (getf (ui:inspect-window (ui:find-window d "one")) :events))))))

(test event-from-parameters-refuses-what-it-does-not-understand
  (let ((d (%desktop)))
    (is (equal '(:name "move" :arguments (5 6))
               (ui:inspect-event
                (ui:event-from-parameters d '(("type" . "move") ("x" . "5") ("y" . "6.5"))))))
    (signals ui:bad-event (ui:event-from-parameters d '(("type" . "explode"))))
    (signals ui:bad-event (ui:event-from-parameters d '(("type" . "move") ("x" . "5"))))
    (signals ui:bad-event
      (ui:event-from-parameters d '(("type" . "move") ("x" . "abc") ("y" . "1"))))))

;;; --- inspecting --------------------------------------------------------------------------

(test inspect-window-returns-plain-data
  (let* ((d (%desktop))
         (record (ui:inspect-window (ui:find-window d "one"))))
    (is (equal '(:id "one" :title "One" :x 10 :y 20 :width 200 :height 100 :z 1
                 :visibility :shown)
               (subseq record 0 16)))
    (is (search "BODY-ONE" (getf record :render)))
    (is (equal "echo" (car (first (getf record :actions)))))
    (is (equal '(:count 3) (getf record :data)))
    (is (null (getf record :refresh)))
    (is (= 5 (getf (ui:inspect-window (ui:find-window d "two")) :refresh)))))

(test inspect-window-shows-an-object-in-the-data-by-its-type-only
  (let* ((d (%desktop))
         (w (ui:find-window d "one")))
    (setf (ui:window-datum w :held) (make-hash-table))
    (setf (ui:window-datum w :text) (make-string 300 :initial-element #\a))
    (let ((data (getf (ui:inspect-window w) :data)))
      (is (search "HASH-TABLE" (getf data :held)))
      (is (stringp (getf data :held)) "the object itself is not in the record")
      (is (= 123 (length (getf data :text))) "a long string is cut to 120 characters and ..."))))

(test inspect-desktop-lists-shown-windows
  (let ((d (%desktop)))
    (ui:dispatch-event d "two" state:close-event)
    (is (equal '(:title "Test desktop" :windows ("one" "two") :shown ("one") :top-z 2)
               (ui:inspect-desktop d)))))

;;; --- rendering and redefinition ----------------------------------------------------------

(test a-window-renders-with-its-position-and-its-body
  (let* ((d (%desktop))
         (html (ui:render-window (ui:find-window d "one"))))
    (is (search "id=win-one" (remove #\" html)))
    (is (search "left:10px;top:20px;width:200px;height:100px;z-index:1" html))
    (is (search "<p>first definition</p>" html))
    (is (null (search "every" html)) "nothing in the window asks again on a timer")
    (is (null (search "every" (ui:render-window (ui:find-window d "two"))))
        "and a refresh interval does not add a polling attribute: the server pushes the body")))

(test redefining-a-render-function-changes-the-next-render
  (let* ((d (%desktop))
         (w (ui:find-window d "one"))
         (original (fdefinition 'body-one)))
    (unwind-protect
         (progn
           (is (search "first definition" (ui:render-window-body w)))
           ;; What a DEFUN typed at a REPL does: the symbol gets a new function. The
           ;; window holds the symbol, so nothing about the window is touched.
           (setf (fdefinition 'body-one)
                 (lambda (window) (format nil "<p>second definition of ~A</p>" (ui:window-id window))))
           (is (search "second definition of one" (ui:render-window-body w)))
           (is (null (search "first definition" (ui:render-window-body w))))
           (is (search "second definition of two"
                       (nth-value 1 (%get (ui:make-app d) "/window/two/body")))
               "an application made before the redefinition serves the new body"))
      (setf (fdefinition 'body-one) original))))

(test redefining-a-desktop-ui-entry-point-reaches-its-compiled-callers
  "RENDER-WINDOW calls RENDER-WINDOW-BODY, and both are declared NOTINLINE. Replacing
RENDER-WINDOW-BODY must change what the already compiled RENDER-WINDOW returns."
  (let* ((d (%desktop))
         (w (ui:find-window d "one"))
         (original (fdefinition 'ui:render-window-body)))
    (unwind-protect
         (progn
           (setf (fdefinition 'ui:render-window-body)
                 (lambda (window) (declare (ignore window)) "<p>replaced entry point</p>"))
           (is (search "replaced entry point" (ui:render-window w))))
      (setf (fdefinition 'ui:render-window-body) original))
    (is (search "first definition" (ui:render-window w)))))

(test an-error-in-a-render-function-is-shown-in-that-window-only
  (let ((d (%desktop)))
    (ui:open-window d "broken" :title "Broken" :render 'body-failing)
    (multiple-value-bind (status body) (%get (ui:make-app d) "/")
      (is (= 200 status))
      (is (search "deliberately broken" body))
      (is (search "first definition" body) "the other windows still render"))))

;;; --- the routes --------------------------------------------------------------------------

(test the-page-holds-every-shown-window-and-the-dock
  (let* ((d (%desktop))
         (app (ui:make-app d)))
    (ui:dispatch-event d "two" state:close-event)
    (multiple-value-bind (status body) (%get app "/")
      (is (= 200 status))
      (is (search "data-window=one" (remove #\" body)))
      (is (null (search "data-window=two" (remove #\" body))) "a closed window is not on the page")
      (is (search "ou-dock" body))
      (is (search "Test desktop" body))
      (is (search "pointerdown" body) "the script is on the page")
      (is (null (search "<" (ui:client-js))) "the script has no angle bracket")
      (is (null (search ">" (ui:client-js)))))))

(test the-event-route-moves-raises-closes-and-opens
  (let* ((d (%desktop))
         (app (ui:make-app d)))
    (is (= 204 (%post app "/window/one/event" "type" "move" "x" "111" "y" "222")))
    (is (search "left:111px;top:222px" (nth-value 1 (%get app "/window/one"))))
    (is (= 204 (%post app "/window/one/event" "type" "resize" "width" "500" "height" "400")))
    (is (search "width:500px;height:400px" (nth-value 1 (%get app "/window/one"))))
    (multiple-value-bind (status body) (%post app "/window/one/event" "type" "raise")
      (is (= 200 status))
      (is (string= "3" body) "the new z, for the page to apply"))
    (is (= 204 (%post app "/window/one/event" "type" "close"))
        "the page learns that it closed from the event stream")
    (is (equal '("two") (getf (ui:inspect-desktop d) :shown)))
    (is (search "ou-hidden" (nth-value 1 (%get app "/dock"))) "the dock offers to open it again")
    (is (= 204 (%post app "/window/one/event" "type" "open")))
    (is (search "left:111px;top:222px" (nth-value 1 (%get app "/window/one")))
        "it comes back where it was")
    (is (equal '("one" "two") (getf (ui:inspect-desktop d) :shown)))))

(test the-event-route-answers-404-and-400
  (let ((app (ui:make-app (%desktop))))
    (is (= 404 (%post app "/window/absent/event" "type" "close")))
    (is (= 400 (%post app "/window/one/event" "type" "explode")))
    (is (= 400 (%post app "/window/one/event" "type" "move" "x" "1")))
    (is (= 404 (%get app "/window/absent")))
    (is (= 404 (%get app "/window/absent/body")))))

(test an-action-is-called-with-the-window-and-the-form
  (let* ((d (%desktop))
         (app (ui:make-app d)))
    (multiple-value-bind (status body) (%post app "/window/one/action/echo" "text" "hello")
      (is (= 200 status))
      (is (string= "<p>heard hello</p>" body)))
    (is (string= "hello" (ui:window-datum (ui:find-window d "one") :said)))
    (is (= 404 (%post app "/window/one/action/absent")))
    (is (= 404 (%post app "/window/two/action/echo")) "window two has no actions")))

(test a-window-added-after-the-application-was-made-is-served
  (let* ((d (%desktop))
         (app (ui:make-app d)))
    (ui:open-window d "late" :title "Late" :render 'body-one)
    (is (= 200 (%get app "/window/late")))
    (is (search "data-window=late" (remove #\" (nth-value 1 (%get app "/")))))))

;;; --- the inspector window ----------------------------------------------------------------

(test the-inspector-shows-the-record-of-the-window-it-is-pointed-at
  (let* ((d (%desktop))
         (app (ui:make-app d)))
    (ui:open-inspector d)
    (let ((body (nth-value 1 (%get app "/window/inspector/body"))))
      (is (search "the desktop" body))
      (is (search "top-z" body) "with no target it shows the desktop's own record"))
    (multiple-value-bind (status body) (%post app "/window/inspector/action/select" "target" "one")
      (is (= 200 status))
      (is (search "BODY-ONE" body))
      (is (search "<th>x<td>10<" (remove #\Space (remove #\Newline body)))))
    (%post app "/window/one/event" "type" "move" "x" "640" "y" "480")
    (let ((body (nth-value 1 (%post app "/window/inspector/action/record"))))
      (is (search "640" body) "the record shows the move")
      (is (search "480" body))
      (is (search "move" body) "and the event that caused it"))
    (is (string= "one" (ui:window-datum (ui:find-window d "inspector") :target)))
    (is (search "INSPECTOR-SELECT"
                (nth-value 1 (%post app "/window/inspector/action/select" "target" "inspector")))
        "the inspector can inspect itself")))

;;; --- the push feed: GET /events ----------------------------------------------------------

(defun body-count (window)
  (format nil "<p>count ~D</p>" (ui:window-datum window :count 0)))

(defun %timer-threads (desktop)
  "The live threads named for DESKTOP's timer."
  (let ((name (format nil "desktop-ui timer: ~A" (ui:desktop-title desktop))))
    (remove-if-not (lambda (thread) (equal name (sb-thread:thread-name thread)))
                   (sb-thread:list-all-threads))))

(defun %call-with-events (desktop function)
  "Read DESKTOP's GET /events on a thread, the way a server would, and call FUNCTION with a
function of no arguments that returns everything written to the stream so far. Before
FUNCTION is called, the stream has written what was published before it connected.
Afterwards the desktop is stopped, and the reading thread must have ended."
  (let* ((app (ui:make-app desktop))
         (response (funcall app (list :request-method :get :path-info "/events")))
         (lock (sb-thread:make-mutex :name "desktop-ui test events"))
         (written (make-string-output-stream))
         (text (lambda ()
                 (sb-thread:with-mutex (lock)
                   (let ((so-far (get-output-stream-string written)))
                     (write-string so-far written)
                     so-far))))
         (thread (sb-thread:make-thread
                  (lambda ()
                    (funcall (third response)
                             (lambda (chunk)
                               (sb-thread:with-mutex (lock) (write-string chunk written))))
                    :returned)
                  :name "desktop-ui test events reader")))
    (unwind-protect
         (progn
           (is (= 200 (first response)))
           (is (search "text/event-stream" (getf (second response) :content-type)))
           (is (%await text ": connected") "the stream opened")
           ;; Longer than one emission interval, so what was published earlier is written.
           (sleep 0.3)
           (funcall function text))
      (is-true (ui:stop-desktop desktop) "stop-desktop ended the stream and the timer")
      (is (eq :returned (sb-thread:join-thread thread :default :still-running :timeout 5))
          "the function that writes the stream returned")
      (when (sb-thread:thread-alive-p thread) (sb-thread:terminate-thread thread)))))

(defun %await (text needle &key (start 0) (timeout 5))
  "Wait until NEEDLE appears in what the function TEXT returns, at or after START. Returns
its position, or NIL after TIMEOUT seconds."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop
      (let ((found (search needle (funcall text) :start2 start)))
        (when found (return found)))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep 0.02))))

(defun %count-after (text needle start)
  "How many times NEEDLE appears in what the function TEXT returns, at or after START."
  (let ((all (funcall text)))
    (loop with count = 0
          for at = (search needle all :start2 start) then (search needle all :start2 (1+ at))
          while at do (incf count)
          finally (return count))))

(test the-page-has-no-polling-attribute-and-opens-the-event-stream
  (let ((d (%desktop)))
    (ui:open-inspector d :target "one")
    (let ((page (nth-value 1 (%get (ui:make-app d) "/"))))
      (is (search "data-window=two" (remove #\" page)) "the window with a refresh interval is there")
      (is (search "data-window=inspector" (remove #\" page)))
      (is (null (search "every" page)) "no hx-trigger asks again on a timer")
      (is (null (search "hx-trigger=ou-dock" (remove #\" page))) "the dock does not fetch itself")
      (is (search "new EventSource('/events')" page)
          "the script opens the event stream, with `new': without it the call throws")
      (is (search "pending[id]" page) "and keeps one request per missing window"))))

(test window-changed-sends-the-body-as-it-is-when-the-event-is-written
  (let* ((d (ui:make-desktop :title "Changed desktop"))
         (w (ui:open-window d "one" :title "One" :render 'body-count :data (list :count 1))))
    (%call-with-events
     d
     (lambda (text)
       (is (search "<p>count 1</p>" (funcall text))
           "a new stream is sent what was published before it connected")
       (let ((mark (length (funcall text))))
         (setf (ui:window-datum w :count) 7)
         (is (null (ui:window-changed w)))
         (is (%await text (format nil "data: html win-one-body~%data: <p>count 7</p>~%~%")
                     :start mark)
             "the body arrives as one event, with the element to put it in")
         (is (%await text "data: window one 360x240 left:40px;top:40px" :start mark)
             "and so does the window's size and position"))))))

(test many-changes-between-two-writes-become-one-event
  (let* ((d (ui:make-desktop :title "Coalescing desktop"))
         (w (ui:open-window d "one" :title "One" :render 'body-count)))
    (%call-with-events
     d
     (lambda (text)
       (let ((mark (length (funcall text))))
         (dotimes (i 200)
           (setf (ui:window-datum w :count) (+ 100 i))
           (ui:window-changed w))
         (is (%await text "<p>count 299</p>" :start mark) "the last change arrives")
         (sleep 0.3)
         (is (<= 1 (%count-after text "data: html win-one-body" mark) 3)
             "200 changes were written as ~D events" (%count-after text "data: html win-one-body" mark)))))))

(test opening-closing-and-removing-a-window-each-send-an-event
  (let ((d (%desktop)))
    (%call-with-events
     d
     (lambda (text)
       (let ((mark (length (funcall text))))
         (ui:open-window d "late" :title "Late" :render 'body-one :x 70 :y 80)
         (is (%await text "data: window late 360x240 left:70px;top:80px" :start mark)
             "a window opened from a REPL is announced to the page")
         (is (%await text (format nil "data: html ou-dock~%") :start mark) "with the dock"))
       (let ((mark (length (funcall text))))
         (ui:dispatch-event d "late" state:close-event)
         (is (%await text (format nil "data: remove late~%") :start mark) "a close removes it")
         (is (%await text "ou-hidden" :start mark) "and the dock offers to open it again"))
       (let ((mark (length (funcall text))))
         (ui:dispatch-event d "late" state:open-event)
         (is (%await text "data: window late " :start mark) "an open shows it again"))
       (let ((mark (length (funcall text))))
         (ui:dispatch-event d "one" (state:move-event 333 222))
         (is (%await text "data: window one 200x100 left:333px;top:222px" :start mark)
             "a move sends the new position"))
       (let ((mark (length (funcall text))))
         (ui:remove-window d "late")
         (is (%await text (format nil "data: remove late~%") :start mark)
             "a removed window is taken off the page")
         (let ((dock (%await text (format nil "data: html ou-dock~%") :start mark)))
           (is-true dock)
           (is (null (search "Late" (funcall text) :start2 (or dock 0)))
               "and off the dock")))))))

(test a-window-with-a-refresh-interval-is-pushed-on-that-schedule
  (let ((d (ui:make-desktop :title "Refresh desktop")))
    (ui:open-window d "still" :title "Still" :render 'body-one)
    (ui:open-window d "ticking" :title "Ticking" :render 'body-count :refresh 0.2)
    (is (null (%timer-threads d)) "no page is connected, so there is no timer thread")
    (%call-with-events
     d
     (lambda (text)
       (is (= 1 (ui:desktop-subscribers d)))
       (is (= 1 (length (%timer-threads d))) "one timer thread while a page is connected")
       (let ((mark (length (funcall text))))
         (is (%await text "data: html win-ticking-body" :start mark)
             "the body arrives with no request and no call to window-changed")
         (let ((first (%await text "data: html win-ticking-body" :start mark)))
           (is (%await text "data: html win-ticking-body" :start (if first (1+ first) mark))
               "and again after another interval"))
         (is (zerop (%count-after text "data: html win-still-body" mark))
             "a window with no refresh interval is not pushed"))))
    (is (zerop (ui:desktop-subscribers d)))
    (is (null (%timer-threads d)) "stop-desktop ended the timer thread")))

(test the-timer-publishes-only-what-is-due
  (let* ((d (ui:make-desktop :title "Tick desktop"))
         (due (make-hash-table :test 'equal))
         (second internal-time-units-per-second)
         (feed (ui::%feed d)))
    (ui:open-window d "fast" :render 'body-one :refresh 1)
    (ui:open-window d "slow" :render 'body-one :refresh 5)
    (ui:open-window d "never" :render 'body-one)
    (flet ((published-by (now)
             (let ((before (hyperion/feed:feed-version-now feed)))
               (ui::%tick d due now)
               (- (hyperion/feed:feed-version-now feed) before))))
      (is (= 0 (published-by 0)) "the first look only notes when each window is due")
      (is (= 0 (published-by (floor second 2))))
      (is (= 1 (published-by second)) "the one-second window is due")
      (is (= 0 (published-by (+ second 1))))
      (is (= 2 (published-by (* 5 second))) "both are due at five seconds")
      (ui:dispatch-event d "fast" state:close-event)
      (is (= 0 (published-by (* 7 second))) "a hidden window is not pushed"))))

(test the-inspector-is-sent-the-record-when-the-window-it-watches-changes
  (let ((d (%desktop)))
    (ui:open-inspector d :target "one")
    (%call-with-events
     d
     (lambda (text)
       (let ((mark (length (funcall text))))
         (ui:dispatch-event d "one" (state:move-event 640 480))
         (let ((at (%await text "data: html win-inspector-record" :start mark)))
           (is-true at "the record is pushed, into the record's own element")
           (is (%await text "640" :start (or at mark)) "and it shows the move")))
       (let ((mark (length (funcall text))))
         (ui:dispatch-event d "two" (state:move-event 5 5))
         (sleep 0.4)
         (is (zerop (%count-after text "data: html win-inspector-record" mark))
             "a change to a window it is not watching sends nothing"))
       (let ((mark (length (funcall text))))
         (setf (ui:window-datum (ui:find-window d "one") :count) 99)
         (ui:window-changed (ui:find-window d "one"))
         (let ((at (%await text "data: html win-inspector-record" :start mark)))
           (is-true at "window-changed pushes the record too")
           (is (%await text "99" :start (or at mark)))))))))

(test event-data-says-what-to-do-about-each-key
  (let ((d (%desktop)))
    (is (string= (format nil "html win-one-body~%<p>first definition</p>")
                 (ui:event-data d '(:body . "one"))))
    (is (string= "window one 200x100 left:10px;top:20px;width:200px;height:100px;z-index:1"
                 (ui:event-data d '(:window . "one"))))
    (is (search "html ou-dock" (ui:event-data d '(:dock))))
    (is (string= "skip" (ui:event-data d '(:record . "one"))) "window one has no record action")
    (ui:dispatch-event d "one" state:close-event)
    (is (string= "remove one" (ui:event-data d '(:window . "one"))) "hidden")
    (is (string= "skip" (ui:event-data d '(:body . "one"))) "a hidden window's body is not sent")
    (is (string= "remove absent" (ui:event-data d '(:window . "absent"))) "gone")
    (ui:open-window d "broken" :render 'body-failing)
    (is (search "deliberately broken" (ui:event-data d '(:body . "broken")))
        "an error in a render function is shown in the window, as on the page")
    (is (null (find #\Return (ui:event-data d '(:dock)))))))

(test a-stopped-desktop-can-be-served-again
  (let* ((d (ui:make-desktop :title "Again desktop"))
         (w (ui:open-window d "one" :render 'body-count :refresh 0.2)))
    (dotimes (round 2)
      (%call-with-events
       d
       (lambda (text)
         (let ((mark (length (funcall text))))
           (setf (ui:window-datum w :count) (+ 40 round))
           (ui:window-changed w)
           (is (%await text (format nil "<p>count ~D</p>" (+ 40 round)) :start mark)
               "round ~D: the stream works" round)
           (is (= 1 (length (%timer-threads d)))))))
      (is (null (%timer-threads d)) "round ~D: no timer thread is left" round))))
