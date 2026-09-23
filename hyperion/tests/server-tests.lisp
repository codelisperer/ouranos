;;;; server-tests.lisp --- the blocking foreground entry (pre-publication issue 124).
;;;;
;;;; A blocking function is awkward to test by definition: the obvious test starts it and
;;;; then has nothing to do but wait. REQUEST-SHUTDOWN is what makes it tractable -- the
;;;; test runs SERVE-FOREVER on a background thread, exercises the real socket, and ends it
;;;; deterministically. Nothing here sleeps hoping the server came up; it polls for the
;;;; port, so the suite is not slower than it has to be and does not flake on a loaded
;;;; machine.
;;;;
;;;; Helpers are %SRV-prefixed: every *-tests.lisp shares the one HYPERION/TESTS package.

(in-package #:hyperion/tests)

(def-suite server :description "The blocking foreground server entry." :in hyperion)
(in-suite server)

(defun %srv-await (predicate &key (timeout 5) (interval 0.02))
  "Poll PREDICATE until true or TIMEOUT seconds elapse. Returns what it last saw."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop for v = (funcall predicate)
          when v return v
          when (> (get-internal-real-time) deadline) return nil
          do (sleep interval))))

(defun %srv-spawn-serve-forever (out &rest options)
  "Run SERVE-FOREVER on a new thread, printing to OUT, on a candidate port. Returns
(values THREAD PORT SESSION) once ON-READY has fired, or with SESSION NIL if it did not
within 10 seconds.

The port may have been taken since it was chosen (#159). START then signals PORT-IN-USE on
the server's thread, so the handler below catches it THERE -- unhandled on that thread it
would end the whole test image -- and another candidate is tried, up to PORTS:+ATTEMPTS+.
OPTIONS go to SERVE-FOREVER; this helper supplies :PORT, :LOG and :ON-READY."
  (loop for attempt from 1
        do (let* ((port (ports:candidate-port))
                  (ready (sb-thread:make-semaphore :name "test-ready"))
                  (session nil)
                  (failure nil)
                  (thread (sb-thread:make-thread
                           (lambda ()
                             (let ((*standard-output* out))
                               (handler-case
                                   (apply #'srv:serve-forever (%srv-ok-app)
                                          :port port :log nil
                                          :on-ready (lambda (s)
                                                      (setf session s)
                                                      (sb-thread:signal-semaphore ready))
                                          options)
                                 (srv:port-in-use (c)
                                   (setf failure c)
                                   (sb-thread:signal-semaphore ready)))))
                           :name "hyperion-test-server")))
             (sb-thread:wait-on-semaphore ready :timeout 10)
             (cond (session (return (values thread port session)))
                   (failure
                    (sb-thread:join-thread thread :timeout 10 :default nil)
                    (when (>= attempt ports:+attempts+) (error failure)))
                   (t (return (values thread port nil)))))))

(defmacro %srv-with-globals (bindings &body body)
  "Like LET over special variables, but by SETF-and-restore rather than dynamic binding.

SERVE-FOREVER runs on a background thread in these tests, and in SBCL a dynamic binding is
THREAD-LOCAL -- a LET here would be invisible over there, and the server would quietly use
the global value while the test asserted against its own. That is a real trap for any test
that configures a special variable and then exercises it on another thread."
  (let ((saved (loop for (place nil) in bindings collect (gensym))))
    `(let ,(loop for s in saved for (place nil) in bindings collect `(,s ,place))
       (unwind-protect
            (progn ,@(loop for (place value) in bindings collect `(setf ,place ,value))
                   ,@body)
         ,@(loop for s in saved for (place nil) in bindings collect `(setf ,place ,s))))))

(defun %srv-ok-app ()
  (lambda (env) (declare (ignore env))
    (list 200 (list :content-type "text/plain") (list "ok"))))

(defmacro %srv-with-serving ((session-var port-var &rest options) &body body)
  "Run SERVE-FOREVER on a background thread; bind PORT-VAR and the SERVER-SESSION captured
via :on-ready. Shuts down and joins on exit, whatever BODY does."
  (let ((thread (gensym)) (banner (gensym)))
    `(let ((,banner (make-string-output-stream)))
       (multiple-value-bind (,thread ,port-var ,session-var)
           (%srv-spawn-serve-forever ,banner ,@options)
         (unwind-protect
              (progn
                (is-true ,session-var "server never became ready")
                ,@body)
           (when ,session-var (ignore-errors (srv:request-shutdown ,session-var)))
           (ignore-errors (sb-thread:join-thread ,thread :timeout 10))
           ;; AND WAIT FOR THE SOCKET, not just for the thread. Asserted rather than merely
           ;; awaited: a port still accepting ten seconds after shutdown is a leak.
           (is (ports:await-released ,port-var)
               "the port was still accepting after teardown -- the next test's free port is not free"))))))

;;; --- the thing that was missing -------------------------------------------

(test serve-forever-blocks-serves-and-stops-on-request
  ;; The whole point: it does not return while serving, it serves, and asking it to stop
  ;; both returns control AND releases the socket.
  (%srv-with-serving (session port)
    (is (srv:server-session-p session))
    ;; START returns once the port is listening (#159), so this could assert at once. The
    ;; poll is kept because a poll that succeeds immediately costs nothing.
    (is (%srv-await (lambda () (ports:listening-p port)))
        "the server should be accepting connections")
    (srv:request-shutdown session)
    (is (ports:await-released port)
        "the port must be released after shutdown")))

(test the-socket-is-released-even-when-the-body-errors
  ;; UNWIND-PROTECT, not merely a handler on the interrupt. A server that leaks its port on
  ;; an unexpected exit makes the NEXT start fail with "address already in use", which is a
  ;; confusing way to find out about the first failure. ON-READY runs inside the protected
  ;; form, so signalling there exercises exactly that path.
  (let* ((port (ports:candidate-port))
         (thread (sb-thread:make-thread
                  (lambda ()
                    (let ((*standard-output* (make-string-output-stream)))
                      (ignore-errors
                       (srv:serve-forever (%srv-ok-app) :port port :log nil
                                          :on-ready (lambda (s) (declare (ignore s))
                                                      (error "boom"))))))
                  :name "hyperion-test-server-err")))
    (ignore-errors (sb-thread:join-thread thread :timeout 10))
    (is (ports:await-released port)
        "the port must be released even on an unhandled condition")))

(test the-banner-is-printed-and-flushed
  (let ((out (make-string-output-stream)))
    (multiple-value-bind (thread port session)
        (%srv-spawn-serve-forever out :name "Test App")
      (when session (srv:request-shutdown session))
      (ignore-errors (sb-thread:join-thread thread :timeout 10))
      ;; The socket, not just the thread (#433) -- these two teardowns never waited.
      (is (ports:await-released port)
          "the port was still accepting after teardown -- the next test's free port is not free")
      (let ((text (get-output-stream-string out)))
        (is (search "Test App" text) "the NAME should title the banner")
        (is (search (princ-to-string port) text) "the banner should name the port")
        (is (search "Stopped." text) "shutdown should be announced")))))

(test a-nil-banner-prints-nothing-of-its-own
  (let ((out (make-string-output-stream)))
    (multiple-value-bind (thread port session)
        (%srv-spawn-serve-forever out :banner nil)
      (when session (srv:request-shutdown session))
      (ignore-errors (sb-thread:join-thread thread :timeout 10))
      ;; The socket, not just the thread (#433) -- these two teardowns never waited.
      (is (ports:await-released port)
          "the port was still accepting after teardown -- the next test's free port is not free")
      (is (not (search "serving at" (get-output-stream-string out)))))))


;;; --- the control for the teardown guard (#159) ------------------------------

(test the-release-check-reports-a-port-that-is-still-accepting
  "THE CONTROL FOR EVERY TEARDOWN ABOVE. Each one now asserts `ports:await-released', and a
guard that has only ever been seen to pass is indistinguishable from one that cannot fail --
especially this one, whose subject is a race nobody can provoke on demand.

So it is driven the other way: with a server deliberately UP, the check must report NIL rather
than time out into a true. That is deterministic -- no race, no sleep tuned to a machine -- and
it is the only direction of this guard that can be made to happen on purpose."
  (%srv-with-serving (session port)
    (is (srv:server-session-p session))
    (is (%srv-await (lambda () (ports:listening-p port)))
        "the server should be accepting before this asks about release")
    ;; A short timeout on purpose: the question is what it answers while a listener is there,
    ;; and ten seconds of it answering the same thing would only be slower.
    (is (null (ports:await-released port :timeout 0.5))
        "the release check returned true while the port was still accepting")))

;;; --- shutdown hooks --------------------------------------------------------

(test shutdown-hooks-run-after-the-server-stops
  (let ((ran '()))
    (%srv-with-globals ((srv:*shutdown-hooks*
                         (list (lambda () (push :first ran))
                               (lambda () (error "a broken hook"))
                               (lambda () (push :third ran)))))
      (%srv-with-serving (session port)
        (srv:request-shutdown session)
        (%srv-await (lambda () (member :third ran)))))
    ;; a hook that signals must not stop the others -- shutdown is best-effort by design
    (is (member :first ran))
    (is (member :third ran))))

;;; --- the interrupt seam ----------------------------------------------------

(test signal-installation-goes-through-the-seam-and-is-restored
  ;; The seam exists so pre-publication issue 117 can swap uv_signal_t in with one rebinding. Test it as the
  ;; contract it is: called with a thunk, returns a restorer, restorer is invoked.
  (let ((installed 0) (restored 0) (request-stop nil))
    (%srv-with-globals ((srv:*install-signal-handlers*
                         (lambda (thunk)
                           (incf installed)
                           (setf request-stop thunk)
                           (lambda () (incf restored)))))
      (%srv-with-serving (session port)
        (is (= 1 installed) "the seam should be used, not bypassed")
        (is (functionp request-stop) "the seam receives a request-stop thunk")
        ;; and that thunk really does end the server -- this is the SIGTERM path, minus
        ;; the signal
        (funcall request-stop)))
    (is (= 1 restored) "the previous handlers must be restored on exit")))

(test signals-nil-skips-installation-entirely
  (let ((installed 0))
    (%srv-with-globals ((srv:*install-signal-handlers*
                         (lambda (thunk) (declare (ignore thunk))
                           (incf installed) (lambda () nil))))
      (%srv-with-serving (session port :signals nil)
        (srv:request-shutdown session)))
    (is (= 0 installed))))

;;; --- pre-publication issue 238: refuse a port that is already answering ---------------------------
;;;
;;; The collision this prevents does not look like a port problem. A dev window opens onto
;;; a SIBLING application -- its title, its routes, and a 404 for everything yours added --
;;; which reads as a catastrophically broken build, because nothing in the symptom points
;;; anywhere near a port. Two consuming apps independently wrote this same connect-probe
;;; and the same error message, which is the usual sign it belongs one level down.

(defun %listening-socket (port)
  "A real listening socket on PORT, so the probe is tested against the thing it probes."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
    (sb-bsd-sockets:socket-bind s (sb-bsd-sockets:make-inet-address "127.0.0.1") port)
    (sb-bsd-sockets:socket-listen s 5)
    s))

(test port-answering-p-detects-a-listener-and-only-a-listener
  (let* ((port 8899)
         (sock (%listening-socket port)))
    (unwind-protect
         (progn
           (is-true (hyperion/server:port-answering-p "127.0.0.1" port)
                    "a port with a listener on it must read as answering")
           ;; The negative half, on a DIFFERENT port, so the positive result above cannot
           ;; be an artefact of the probe simply always returning true.
           (is-false (hyperion/server:port-answering-p "127.0.0.1" (1+ port))
                     "a port with nothing on it must read as free"))
      (ignore-errors (sb-bsd-sockets:socket-close sock)))))

(test start-refuses-a-port-that-is-already-answering
  (let* ((port 8898)
         (sock (%listening-socket port)))
    (unwind-protect
         (signals hyperion/server:port-in-use
           (hyperion/server:start (lambda (env) (declare (ignore env))
                                    (list 200 '(:content-type "text/plain") '("x")))
                                  :port port))
      (ignore-errors (sb-bsd-sockets:socket-close sock)))))

(test the-refusal-names-the-address-and-how-to-find-the-holder
  ;; A guard that refuses without saying what to do next just moves the confusion.
  (let ((text (princ-to-string
               (make-condition 'hyperion/server:port-in-use :host "127.0.0.1" :port 8080))))
    (is (search "127.0.0.1" text))
    (is (search "8080" text))
    (is (search "check-port nil" text) "it must name its own escape hatch: ~S" text)))

(test the-preflight-is-overridable
  ;; A caller who knows better -- a test harness, a deliberate second binder -- must be
  ;; able to say so. CHECK-PORT NIL must not consult the probe at all.
  (let* ((port 8897)
         (sock (%listening-socket port)))
    (unwind-protect
         ;; Not asserting a successful start (that needs a backend and would bind for real);
         ;; asserting only that the refusal is NOT what comes back.
         (handler-case
             (progn (hyperion/server:start
                     (lambda (env) (declare (ignore env)) nil)
                     :port port :check-port nil)
                    (is-true t "started without consulting the probe"))
           (hyperion/server:port-in-use ()
             (is-true nil ":check-port nil still ran the preflight"))
           (error () (is-true t "failed for some other reason, which is fine here")))
      (ignore-errors (sb-bsd-sockets:socket-close sock)))))

;;; --- the streaming shim, on a real Clack backend (pre-publication issue 117 M2) ------------------
;;;
;;; THIS IS THE HALF THAT WOULD OTHERWISE GO UNTESTED. hyperion's streaming convention is a
;;; FUNCTION in body position -- (status headers (lambda (writer) ...)) -- and the native
;;; server implements it directly. Clack's protocol is a different shape entirely: the
;;; RESPONSE may be a function taking a responder, which returns the writer. Clack's own
;;; HANDLE-NORMAL-RESPONSE has no FUNCTION clause in its body ETYPECASE, so without
;;; WRAP-STREAMING-BODY the same application streams on :uv and dies of a TYPE-ERROR on the
;;; Hunchentoot or Woo it is deployed to -- after being written, tested and shipped.
;;;
;;; So this runs the shim through a REAL backend rather than a fake responder. A stub would
;;; assert that the adapter has the shape we believe Clack wants, which is precisely the
;;; belief under test: whether a two-element responder call returns a writer, and whether
;;; that writer takes :CLOSE, are Clack's answers to give, not ours.

(defun %srv-http-get (port path &key (version "1.0"))
  "GET PATH over a real socket and return the whole response, head included, read to end of
stream. No Content-Length framing: a streamed response has none, which is the point.

VERSION matters for what the answer can PROVE. Over HTTP/1.0 there is no chunked encoding,
so framing is `read until close' and a truncated response is indistinguishable from a
complete one. Over HTTP/1.1 the backend chunks it, and the terminating chunk is then
present or absent -- which is the only way a test can tell the two apart."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (sb-ext:with-timeout 10
           (sb-bsd-sockets:socket-connect s #(127 0 0 1) port)
           (let ((st (sb-bsd-sockets:socket-make-stream s :input t :output t
                                                          :element-type 'character
                                                          :external-format :latin-1)))
             (format st "GET ~A HTTP/~A~C~CHost: 127.0.0.1~C~CConnection: close~C~C~C~C"
                     path version #\Return #\Linefeed #\Return #\Linefeed
                     #\Return #\Linefeed #\Return #\Linefeed)
             (finish-output st)
             (with-output-to-string (out)
               (loop for c = (read-char st nil nil)
                     while c do (write-char c out)))))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(test the-streaming-shim-serves-a-function-body-on-a-clack-backend
  "The whole reason the shim exists: one convention, every backend. HTTP/1.0 is used
deliberately -- it makes the backend close at the end of the body, so reading to end of
stream is exact framing whether the backend chunked the response or not."
  (let* ((app (lambda (env)
                (declare (ignore env))
                (list 200 (list :content-type "text/plain; charset=utf-8")
                      (lambda (writer)
                        (funcall writer "one-")
                        (funcall writer "")     ; the ordinary accident: not the end
                        (funcall writer "two")))))
         (port nil)
         (handler (ports:call-with-port
                   (lambda (p)
                     (prog1 (srv:start app :port p :server :hunchentoot)
                       (setf port p))))))
    (unwind-protect
         (progn
           (is-true (%srv-await (lambda () (ports:listening-p port))) "backend came up")
           (let ((r (%srv-http-get port "/")))
             (is-true (search "200" r) "~S" r)
             (is-true (search "one-two" r)
                      "both chunks arrived, in order, and the empty write did not end it")))
      (ignore-errors (srv:stop handler)))))

(test a-failed-stream-is-reported-as-COMPLETE-by-the-clack-backends
  "A KNOWN DIVERGENCE, asserted so it is documented rather than discovered.

One convention does not buy identical semantics, and this is where the two backends part.
When a streaming body signals mid-flight the native server closes WITHOUT the terminating
chunk, so the client sees a truncated message and knows the response is not to be trusted
(%STREAM-FINISH, and A-BODY-THAT-SIGNALS-MIDSTREAM-TRUNCATES-RATHER-THAN-COMPLETING in the
server-uv suite). Hunchentoot finalises its own chunked stream while unwinding, so the
client is told the response was WHOLE -- a silent truncation the application believes it
delivered.

The shim CANNOT fix this: the backend owns the stream and closes it after the condition has
already left our code. Recording the behaviour in a test rather than a comment is what makes
it a fact that stays true -- and this test failing later is the good outcome, because it
would mean the divergence had closed.

It is also the sharpest argument yet for the native path, and it is not a performance one."
  (let* ((app (lambda (env)
                (declare (ignore env))
                (list 200 (list :content-type "text/plain; charset=utf-8")
                      (lambda (writer)
                        (funcall writer "before")
                        (error "boom")))))
         (port nil)
         (handler (ports:call-with-port
                   (lambda (p)
                     (prog1 (srv:start app :port p :server :hunchentoot)
                       (setf port p))))))
    (unwind-protect
         (progn
           (is-true (%srv-await (lambda () (ports:listening-p port))))
           (let ((r (%srv-http-get port "/" :version "1.1")))
             (is-true (search "before" r) "what was written before the failure was sent")
             (is-true (search "chunked" (string-downcase r))
                      "1.1 with no length: the backend chunked it, so a terminator is a
thing that could have been here")
             (is-true (search (format nil "~C~C0~C~C~C~C" #\Return #\Linefeed
                                      #\Return #\Linefeed #\Return #\Linefeed)
                              r)
                      "Hunchentoot terminated the chunked message ITSELF while unwinding,
so the client is told a failed response was complete. The native server does not -- see the
docstring. Asserted, not wished for.")))
      (ignore-errors (srv:stop handler)))))

(test a-non-streaming-response-is-untouched-by-the-shim
  "The control. WRAP-STREAMING-BODY sits in front of every Clack response, so a bug in its
guard would convert ordinary responses into Clack's function protocol and break every app
that does not stream -- a far larger blast radius than the feature it enables."
  (let ((plain (srv:wrap-streaming-body
                (lambda (env) (declare (ignore env)) (list 200 nil '("hello"))))))
    (is (equal (list 200 nil '("hello")) (funcall plain nil))
        "an ordinary three-list passes through as itself, not as a closure"))
  (let ((odd (srv:wrap-streaming-body (lambda (env) (declare (ignore env)) :not-a-response))))
    (is (eq :not-a-response (funcall odd nil))
        "and a response this wrapper does not understand is passed on, not swallowed")))

;;; --- START knows whether it started (#159) ----------------------------------
;;;
;;; START with a Clack backend used to return before the backend had bound its port. When
;;; the bind then failed, the error was unhandled on the backend's own thread, and under
;;; --disable-debugger that ends the process: the gate lost every suite still to run.

(defun %srv-squat (port)
  "Bind PORT on loopback WITHOUT listening, and return the socket. A port held this way is
invisible to a connect probe, so CHECK-PORT cannot see it and only the bind can fail."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-bind s #(127 0 0 1) port)
    s))

(test start-signals-port-in-use-in-the-caller-when-the-bind-fails
  ;; Before #159 this test could not be written in-process: the bind failure ended the
  ;; image. That this test runs to its end, and the suite continues, is part of what it
  ;; shows.
  (let* ((port (ports:candidate-port))
         (squatter (%srv-squat port)))
    (unwind-protect
         (let ((c (handler-case
                      (let ((h (srv:start (%srv-ok-app) :port port :server :hunchentoot
                                                        :log nil)))
                        (ignore-errors (srv:stop h))
                        :started)
                    (srv:port-in-use (c) c))))
           (is (typep c 'srv:port-in-use)
               "a failed bind must be signalled to the caller, got ~S" c)
           (when (typep c 'srv:port-in-use)
             (is (= port (srv:port-in-use-port c)))
             (is (srv:port-in-use-cause c)
                 "the backend's own error must be kept, not replaced")))
      (sb-bsd-sockets:socket-close squatter))))

(test start-returns-once-the-port-is-listening-and-stop-once-it-is-released
  ;; No poll on either side: START's return means listening, and STOP's return means the
  ;; socket is closed, because STOP now waits for the backend's thread.
  (let* ((port nil)
         (h (ports:call-with-port
             (lambda (p)
               (prog1 (srv:start (%srv-ok-app) :port p :server :hunchentoot :log nil)
                 (setf port p))))))
    (is (ports:listening-p port) "START returned before the port was listening")
    (srv:stop h)
    (is (not (ports:listening-p port)) "STOP returned while the port was still accepting")))

(test start-gives-up-after-its-deadline-and-stops-the-server
  ;; The only way to make readiness never arrive on demand is to replace the probe. The
  ;; server itself does start; START must stop it rather than leave it running.
  (let* ((port (ports:candidate-port))
         (c (let ((srv::*listening-probe* (constantly nil))
                  (srv:*start-timeout* 1))
              (handler-case
                  (progn (srv:start (%srv-ok-app) :port port :server :hunchentoot :log nil)
                         :returned)
                (srv:server-start-timeout (c) c)))))
    (is (typep c 'srv:server-start-timeout) "expected a timeout, got ~S" c)
    (is (ports:await-released port)
        "the server START gave up on must not be left holding the port")))
