;;;; server.lisp --- the configurable Clack server backend + lifecycle.
;;;;
;;;; A capability behind a neutral protocol. START takes an already-built Clack app --
;;;; app construction is the caller's concern -- and clacks it up on a background thread;
;;;; STOP stops it. Extracted from praxeon/src/web.lisp (default-server/start/stop).
;;;;
;;;; HYPERION DECLARES NO BACKEND (pre-publication issue 139; ECOSYSTEM decisions log, 2026-08-05). It used to
;;;; depend on clack-handler-woo (Unix) / clack-handler-hunchentoot (Windows), which meant
;;;; every image loading hyperion also loaded Woo's libev -- and a dumped desktop bundle
;;;; then died at startup on a machine without it. A framework does not get to choose the
;;;; application's HTTP server: the APP declares the handler it wants, and DEFAULT-SERVER
;;;; picks from what is actually in the image.
;;;;
;;;; Neither Woo nor Hunchentoot is a destination. ADR-0011's backend half is a waypoint
;;;; until the native libuv server (pre-publication issue 117), which will arrive here as one more entry in
;;;; +BACKENDS+ rather than as a change to any app.

(in-package #:hyperion/server)

(defparameter *default-port* 8080)

(defparameter +backends+
  '((:woo         . "CLACK.HANDLER.WOO")
    (:hunchentoot . "CLACK.HANDLER.HUNCHENTOOT")
    (:uv          . "HYPERION/SERVER-UV"))
  "Known backends, each paired with the package its system defines.

Presence of the PACKAGE is the test, not presence of the system on disk. `clackup' will
lazily `asdf:load-system' a handler it can find, which is convenient in a REPL and wrong
for an artifact: a dumped image cannot load a system that was never compiled into it, and
a bundle that resolves its server at run time is a bundle that fails at the user. What is
loaded HERE is what will be in the image.

**That same test is what lets :UV be here at all.** HYPERION/SERVER-UV needs a built libuv,
and hyperion core must not need a C toolchain to load -- so core does not depend on it, and
never will. Asking whether the PACKAGE exists costs nothing and is answered correctly in
both directions: an app that declared the system gets the native server as an option, and
one that did not is unaffected. No `:depends-on' anywhere had to move.

ORDER IS PREFERENCE, and :UV is deliberately LAST (pre-publication issue 117, commit 5). It is selectable --
`HYPERION_SERVER=uv', or `:server :uv' -- and not yet selected: making it the default is a
one-line move to the head of this list, and it waits for an app to have actually run it.")

(defparameter +native-backends+ '(:uv)
  "The backends that are OURS rather than Clack handlers.

A list rather than a predicate on the name so that the distinction is data, in one place,
next to the table it qualifies. Everything that must branch on `Clack or not' asks
NATIVE-BACKEND-P; when Clack eventually leaves, what changes is this list and not a dozen
scattered conditionals.")

(defun native-backend-p (server)
  "Is SERVER one of ours -- started and stopped directly, not through Clack?"
  (and (member server +native-backends+) t))

(define-condition no-server-backend (error)
  ((requested :initarg :requested :initform nil :reader no-server-backend-requested))
  (:report
   (lambda (c stream)
     (let ((requested (no-server-backend-requested c)))
       (if requested
           (format stream "hyperion/server: HYPERION_SERVER names ~S, whose Clack handler is not loaded.~%"
                   requested)
           (format stream "hyperion/server: no Clack backend is loaded.~%"))
       (format stream "~%Hyperion deliberately declares no HTTP server (pre-publication issue 139) -- the application chooses.~%")
       (format stream "Add ONE of these to your system's :depends-on:~%")
       (format stream "  \"hyperion/server-uv\"          ; ours -- native, no Clack (needs a built libuv)~%")
       (format stream "  \"clack-handler-hunchentoot\"   ; pure CL, works on every platform~%")
       (format stream "  \"clack-handler-woo\"           ; Unix only, and binds libev at load time~%~%")
       (format stream "For a CLACK backend, depend on the HANDLER system rather than the bare~%")
       (format stream "server: clackup resolves a backend through clack.handler.<name>, which~%")
       (format stream "is what the handler systems provide.~%"))))
  (:documentation "Signalled when no usable Clack backend is present in the image."))

(defun available-servers ()
  "The backends whose handler package is loaded, in preference order."
  (loop for (name . package) in +backends+
        when (find-package package) collect name))

(defun %choose-server (requested available)
  "Which backend to use, given what was REQUESTED (a keyword or NIL) and what is AVAILABLE.

Pure, and separate from DEFAULT-SERVER for that reason: the interesting behaviour is a
handful of cases, and testing it should not mean mutating the environment of the image
running the tests. The rules:

  nothing requested        -> the first available, or NO-SERVER-BACKEND if there is none.
  requested and available  -> honour it.
  requested, KNOWN to us,
    but not loaded         -> NO-SERVER-BACKEND. Never fall back: answering requests on a
                              server the operator did not ask for is worse than not
                              starting, and it is the kind of wrong that shows up in
                              production as a mystery.
  requested, UNKNOWN to us -> pass it through. +BACKENDS+ lists the handlers whose package
                              we can name, not the ones Clack supports; a framework should
                              not veto a backend it has merely never heard of."
  (cond ((null requested)
         (or (first available) (error 'no-server-backend)))
        ((member requested available) requested)
        ((not (assoc requested +backends+)) requested)
        (t (error 'no-server-backend :requested requested))))

(defun default-server ()
  "The backend to use: HYPERION_SERVER (a keyword name) if set, else the first loaded one
in +BACKENDS+ order. Signals NO-SERVER-BACKEND if there is none.

See %CHOOSE-SERVER for the rules; this function is only the part that reads the world."
  (let ((env (uiop:getenv "HYPERION_SERVER")))
    (%choose-server (when (and env (plusp (length env)))
                      (intern (string-upcase env) :keyword))
                    (available-servers))))

(defun utf-8-length (string)
  "Octets STRING occupies in UTF-8, counted without allocating a byte vector.
Deliberately dependency-free (and allocation-free) -- this runs on every response."
  (declare (type string string))
  (let ((n 0))
    (declare (type fixnum n))
    (loop for ch across string
          for c = (char-code ch)
          do (incf n (cond ((< c #x80) 1) ((< c #x800) 2) ((< c #x10000) 3) (t 4))))
    n))

(defun wrap-content-length (app)
  "Add Content-Length to responses whose body is already fully in memory.

Why this exists, measured rather than assumed: without a length header the Clack handler
falls back to CHUNKED encoding, whose terminating zero-length chunk is a SEPARATE small
write. Nagle's algorithm holds that write waiting for an ACK the client will not send until
it has a complete response -- so every request on a keep-alive connection stalls for the
delayed-ACK timer. On Hunchentoot that measured a flat p50 of 44 ms per request; the same
server, same bytes, with Content-Length set: 0.17 ms. See hyperion/bench/ and ADR-0011.

Bodies that are NOT a fully-known sequence -- a function (streamed), a pathname -- are left
strictly alone: they must stay chunked, because their length is not knowable up front. SSE
in particular depends on that."
  (lambda (env)
    (let ((res (funcall app env)))
      (if (and (consp res) (= (length res) 3))
          (destructuring-bind (status headers body) res
            (if (or (getf headers :content-length)
                    (not (listp body))                       ; function/pathname => streamed
                    (notevery #'stringp body))
                res
                (list status
                      (append headers
                              (list :content-length (reduce #'+ body :key #'utf-8-length)))
                      body)))
          res))))

(defun wrap-streaming-body (app)
  "Adapt hyperion's streaming body -- (status headers (lambda (writer) ...)) -- onto Clack's
responder protocol, so the SAME handler streams on every backend.

WITHOUT THIS, THE CONVENTION IS A LOCK-IN WITH A DELAYED ERROR MESSAGE. Clack's
HANDLE-NORMAL-RESPONSE has no FUNCTION clause in its body ETYPECASE, so a streaming app
written against hyperion's convention works in development on the native server and dies of
a TYPE-ERROR on the Woo or Hunchentoot it is deployed to -- after it has been written,
tested and shipped, naming a Clack internal rather than anything its author did. That is
worse than not supporting streaming on those backends at all, which is why the adapter lands
with the convention rather than after it.

Clack's protocol is the other shape: the RESPONSE may be a function taking a responder, and
the responder returns a writer of (chunk &key close). Hyperion keeps the response a
three-list -- so middleware and interceptors destructure one thing and never learn that
streaming exists -- and translates here, in one place, at the only boundary that cares.

THE WRITER IS CLOSED ONLY WHEN THE BODY COMPLETES, and that asymmetry is the point rather
than an oversight. Closing is what writes the terminating chunk, so closing after a failure
would tell the client the response was WHOLE -- a silent truncation the application believes
it delivered, which is the one outcome worse than an error. On the failure path the
condition propagates out of the app and the backend tears the connection down, and the
client sees a message that never ended properly. That is the same distinction %STREAM-FINISH
draws on the native path, and it has to be drawn here too or the two backends disagree about
what a failed stream looks like.

An UNWIND-PROTECT that closed unconditionally is the natural way to write this and is
exactly wrong; it also produced a caught TYPE-ERROR from inside Clack's own writer while
unwinding, which is how the mistake announced itself.

AND IT IS STILL NOT ENOUGH, which is worth knowing before you rely on it. Hunchentoot
finalises its own chunked stream while unwinding, AFTER the condition has left this code, so
on the Clack backends a failed stream still reaches the client as a COMPLETE one. Not
fixable from here -- the backend owns the stream. One convention does not buy identical
semantics, and this is where the two part: the native server truncates a failed stream and
the Clack backends do not. Asserted in
A-FAILED-STREAM-IS-REPORTED-AS-COMPLETE-BY-THE-CLACK-BACKENDS so it is a recorded fact
rather than a discovery, and it is the sharpest argument for the native path that is not a
performance argument."
  (lambda (env)
    (let ((res (funcall app env)))
      (if (and (consp res) (= (length res) 3) (functionp (third res)))
          (destructuring-bind (status headers body) res
            (lambda (responder)
              (let ((writer (funcall responder (list status headers))))
                (funcall body (lambda (chunk)
                                ;; An empty chunk is a no-op, matching the native path: a
                                ;; handler writing "" is an ordinary accident and must not
                                ;; be mistaken for the end of the stream.
                                (when (and chunk (plusp (length chunk)))
                                  (funcall writer chunk))))
                ;; Reached only on normal completion -- see the docstring.
                (funcall writer "" :close t))))
          res))))

(defun %uv-call (name &rest args)
  "Call NAME in HYPERION/SERVER-UV, a system this one deliberately does not depend on.

FIND-SYMBOL rather than a direct reference, and it is a considered trade rather than a
workaround. HYPERION/SERVER-UV needs a built libuv; hyperion core needing a C toolchain in
order to LOAD would be a far worse property than one late-bound call per server start. The
package exists exactly when the application declared the system -- the same test
AVAILABLE-SERVERS already uses to offer the backend at all -- so by the time we are here it
has been answered once already."
  (let* ((pkg (find-package "HYPERION/SERVER-UV"))
         (sym (and pkg (find-symbol name pkg))))
    (unless (and sym (fboundp sym))
      (error 'no-server-backend :requested :uv))
    (apply sym args)))

(defun %uv-server-p (handler)
  "Is HANDLER a native server rather than a Clack one?

FIND-PACKAGE FIRST, and not as a micro-optimisation: FIND-SYMBOL given a package NAME that
does not exist SIGNALS -- `The name \"HYPERION/SERVER-UV\" does not designate any package'
-- rather than returning NIL. Since STOP asks this question about every handler, the
obvious spelling made STOP fail for every CLACK server in every image that had not loaded
the native one, which is nearly all of them.

Worth noting how it was found: the server-uv suite passed 79/79, because there the package
always exists. Only the whole-tree run reached an image where it does not. A test written
where the answer is always yes cannot ask this question."
  (let* ((pkg (find-package "HYPERION/SERVER-UV"))
         (sym (and pkg (find-symbol "SERVER-P" pkg))))
    (and sym (fboundp sym) (funcall sym handler) t)))

(define-condition port-in-use (error)
  ((host :initarg :host :reader port-in-use-host)
   (port :initarg :port :reader port-in-use-port)
   (cause :initarg :cause :initform nil :reader port-in-use-cause
          :documentation "The backend's own error when its bind failed, or NIL when START
refused before binding because the port was already answering."))
  (:report
   (lambda (c stream)
     (let ((host (port-in-use-host c)) (port (port-in-use-port c)))
       (if (port-in-use-cause c)
           (format stream "hyperion/server: could not bind ~A:~D -- the port is taken (~A).~%"
                   host port (port-in-use-cause c))
           (format stream "hyperion/server: ~A:~D is already answering -- something is listening there.~%"
                   host port))
       (format stream "~%This is almost always a sibling application's dev server. The symptom if~%")
       (format stream "it is not caught here is much worse than this error: a window opens onto~%")
       (format stream "the OTHER application -- its title, its routes, and a 404 for everything~%")
       (format stream "yours added -- which reads as a catastrophically broken build rather than~%")
       (format stream "a port collision, because nothing in it points anywhere near a port.~%")
       (format stream "~%Find the holder:~%")
       #+darwin  (format stream "  lsof -nP -iTCP:~D -sTCP:LISTEN~%" port)
       #+linux   (format stream "  ss -lptn 'sport = :~D'~%" port)
       #+win32   (format stream "  netstat -ano | findstr :~D~%" port)
       (format stream "~%Then pick another port, or pass :check-port nil to start anyway.~%"))))
  (:documentation
   "Signalled by START when the requested port is taken: either it was already answering
before START tried to bind it, or the backend's bind failed (#159), in which case CAUSE
holds the backend's error."))

(define-condition server-start-timeout (error)
  ((host :initarg :host :reader server-start-timeout-host)
   (port :initarg :port :reader server-start-timeout-port)
   (seconds :initarg :seconds :reader server-start-timeout-seconds))
  (:report
   (lambda (c stream)
     (format stream "hyperion/server: the server on ~A:~D neither started listening nor reported an error within ~D seconds; it has been stopped."
             (server-start-timeout-host c) (server-start-timeout-port c)
             (server-start-timeout-seconds c))))
  (:documentation
   "Signalled by START when a Clack backend has not started listening within
*START-TIMEOUT* seconds and has not reported an error either. START stops it first."))

(defvar *start-timeout* 10
  "Seconds START waits for a Clack backend to start listening before it gives up and
signals SERVER-START-TIMEOUT.")

(defun port-answering-p (host port &key (timeout 0.5))
  "Is something already listening on HOST:PORT?

ASKED BY CONNECTING, NEVER BY BINDING, and that is the whole point of this function.
On Windows a second bind to a port another process is already listening on CAN SUCCEED --
two servers then hold the same address and the OS hands each connection to one of them,
intermittently. That is strictly worse than a clean failure: the application appears to
work, and then does not, with no error in either direction. A bind-probe would therefore
answer a different question on the one platform where the answer matters most.

Fail-open: anything unexpected reports NIL (not answering), because this guard must never
be the reason a server refuses to start."
  (handler-case
      (sb-sys:with-deadline (:seconds timeout)
        (let ((sock (make-instance 'sb-bsd-sockets:inet-socket
                                   :type :stream :protocol :tcp)))
          (unwind-protect
               (progn (sb-bsd-sockets:socket-connect
                       sock (sb-bsd-sockets:make-inet-address
                             (if (string= host "0.0.0.0") "127.0.0.1" host))
                       port)
                      t)
            (ignore-errors (sb-bsd-sockets:socket-close sock)))))
    (sb-sys:deadline-timeout () nil)
    (error () nil)))

(defun start (app &key (server (default-server)) (port *default-port*)
                       (host "127.0.0.1") debug (log t) (check-port t))
  "Start APP (a Ring handler) and return the running handler; stop it with STOP.
SERVER names the backend (see DEFAULT-SERVER) and may be a Clack handler or ours;
the returned handler differs between the two and STOP takes either.

START RETURNS ONCE THE PORT IS LISTENING, on every backend (#159). A port that is taken
signals PORT-IN-USE here, in the caller, whether START saw it answering beforehand or the
backend's bind failed; with a Clack backend the bind happens on the server's own thread,
and START waits for it. If a Clack backend neither listens nor fails within
*START-TIMEOUT* seconds, START stops it and signals SERVER-START-TIMEOUT. The one case this
does not cover is described above %CLACK-START: another process that starts listening on
the same port in the moment between the check and the bind. DEBUG nil (the
default) returns a 500 on an unhandled error instead of dropping into the debugger
-- right for a server, and the only behaviour the native backend has.

LOG (default T) wraps APP in HYPERION/LOGGING:WRAP, so each request gets a correlation
id and one line at :info -- on by default because a server nobody can see into is the
problem this exists to solve, and the default log level leaves it quiet enough to live
with. Pass :log nil to opt out (or if the app already wraps itself).

CHECK-PORT (default T) refuses to start when PORT is already answering, signalling
PORT-IN-USE. On by default because the failure it prevents does not look like a port
problem: a dev window opens onto a SIBLING application and reads as a catastrophically
broken build (pre-publication issue 238). The probe CONNECTS rather than binding -- see PORT-ANSWERING-P for
why that distinction is not pedantry on Windows. Pass :check-port nil to start anyway."
  (when (and check-port (port-answering-p host port))
    (error 'port-in-use :host host :port port))
  (let ((wrapped (if log (hyperion/logging:wrap app) app)))
    (cond
      ((native-backend-p server)
       ;; DEBUG has no meaning here and is not silently dropped. There is no debugger to
       ;; drop into inside an event-loop callback on a background thread; an application
       ;; error is a 500, always. Saying so beats letting an operator believe :debug t did
       ;; something.
       (when debug
         (warn "hyperion/server: :debug is ignored by the ~S backend -- an application error is always a 500 there, never a break." server))
       ;; NOT WRAP-CONTENT-LENGTH, and that is the interesting part. That wrapper exists
       ;; because a Clack handler with no length header falls back to chunked, whose
       ;; terminating zero-length chunk meets Nagle and the delayed-ACK timer -- 44 ms a
       ;; request, measured (ADR-0011). The native server has no such fallback: it measures
       ;; the body it holds and writes Content-Length from that, and its encoder DROPS a
       ;; caller-supplied one precisely so the framing cannot disagree with the bytes. So
       ;; wrapping here would spend a UTF-8 length pass on every response to compute a
       ;; header that is then thrown away.
       ;; The native backend binds in THIS thread, so a taken port already signals here.
       ;; It is translated so that a caller handles one condition whatever the backend.
       (handler-bind ((error (lambda (e)
                               (when (%address-in-use-p e)
                                 (error 'port-in-use :host host :port port :cause e)))))
         (%uv-call "START" wrapped :port port :host host)))
      (t
       (%clack-start (wrap-content-length (wrap-streaming-body wrapped))
                     server host port debug)))))

;;; --- the Clack path: a start that knows whether it started (#159) ---------
;;;
;;; `clackup :use-thread t' returns as soon as it has created the thread that will bind
;;; the port. The bind happens afterwards, on that thread, so a caller got a handler for a
;;; server that might never exist -- and when the bind failed, the error was unhandled on a
;;; thread nobody was watching, which under --disable-debugger ENDS THE PROCESS. That is
;;; how HYPERION/TESTS aborted whole gate runs with USOCKET:ADDRESS-IN-USE-ERROR, and an
;;; application whose port is taken dies the same way.
;;;
;;; So START runs clackup with :use-thread NIL on a thread of its own, inside a handler that
;;; records the error, and waits until the port answers, the thread records an error, or
;;; the thread ends. A bind failure becomes PORT-IN-USE in the caller.
;;;
;;; THE REMAINING RACE. Readiness is a connect to HOST:PORT, because neither Clack backend
;;; exposes a "now listening" signal to the caller: Clack keeps the Hunchentoot acceptor
;;; inside its own thread, and Woo has no hook. A different process that starts listening
;;; on the same port between CHECK-PORT and our bind would answer that connect, START
;;; would return, and our bind would then fail -- as a recorded error on our thread now,
;;; not a dead process, but after START had already reported success. With CHECK-PORT on,
;;; that needs another process to take the port inside a window of milliseconds.

(defstruct (clack-server (:constructor %make-clack-server) (:copier nil))
  "What START returns for a Clack backend. STOP takes it."
  (thread nil)
  (server nil)
  (host nil)
  (port nil))

(defconstant +eaddrinuse+ #+linux 98 #+darwin 48 #-(or linux darwin) nil
  "EADDRINUSE on this OS. Woo reports a taken port only as an OS-ERROR carrying this errno.")

(defun %errno-slot (condition)
  "The value of CONDITION's slot named CODE, whatever its package, or NIL. Woo's OS-ERROR
keeps the errno there and has no reader for it."
  (let ((slot (find "CODE" (sb-mop:class-slots (class-of condition))
                    :key (lambda (s) (symbol-name (sb-mop:slot-definition-name s)))
                    :test #'string=)))
    (when slot
      (let ((name (sb-mop:slot-definition-name slot)))
        (and (slot-boundp condition name) (slot-value condition name))))))

(defun %address-in-use-p (condition)
  "Whether CONDITION is a backend saying the address is taken. Each backend signals its own
condition: USOCKET:ADDRESS-IN-USE-ERROR under Hunchentoot, an OS-ERROR whose code is
EADDRINUSE under Woo, and a UV-ERROR saying \"address already in use\" under :uv."
  (or (search "ADDRESS-IN-USE" (symbol-name (type-of condition)))
      (search "address already in use" (princ-to-string condition) :test #'char-equal)
      (and +eaddrinuse+ (eql (%errno-slot condition) +eaddrinuse+))))

(defvar *listening-probe* 'port-answering-p
  "How %CLACK-START asks whether the server is listening: a function of HOST and PORT.
Internal; a test binds it to a probe that never answers, which is the only way to make the
timeout path happen on demand.")

(defun %clack-start (app server host port debug)
  "Start APP on a Clack backend and return a CLACK-SERVER once the port answers. Signals
PORT-IN-USE if the bind fails, the backend's own error for any other failure, and
SERVER-START-TIMEOUT if neither readiness nor an error arrives within *START-TIMEOUT*."
  (let* ((failure nil)
         (out *standard-output*)
         (err *error-output*)
         ;; THREAD-LIFETIME: independent -- the server runs for as long as it serves, not
         ;; for the START call that created it; the only bindings it needs, the caller's
         ;; output streams, are passed to it explicitly below.
         (thread
           (sb-thread:make-thread
            (lambda ()
              ;; A dynamic binding does not cross into a new thread, so the caller's
              ;; streams are passed explicitly, as `clackup :use-thread t' did.
              ;; FAILURE is the FIRST error, recorded by HANDLER-BIND before anything
              ;; unwinds. Recording the one HANDLER-CASE catches would be wrong under
              ;; Hunchentoot: when its bind fails, Clack's cleanup calls HUNCHENTOOT:STOP on
              ;; an acceptor that never started, which signals UNBOUND-SLOT on the way out
              ;; and would replace the address-in-use error with one about a slot. The
              ;; HANDLER-BIND is INSIDE the HANDLER-CASE because the innermost handler runs
              ;; first: outside, the HANDLER-CASE would unwind before it was ever asked.
              (let ((*standard-output* out) (*error-output* err))
                (handler-case
                    (handler-bind ((error (lambda (e) (unless failure (setf failure e)))))
                      (clack:clackup app :server server :port port :address host
                                         :use-thread nil :debug debug))
                  (error () nil))))
            :name (format nil "hyperion-server-~(~A~)" server)))
         (deadline (+ (get-internal-real-time)
                      (* *start-timeout* internal-time-units-per-second))))
    (loop
      (cond
        (failure
         (ignore-errors (sb-thread:join-thread thread :timeout 5 :default nil))
         (if (%address-in-use-p failure)
             (error 'port-in-use :host host :port port :cause failure)
             (error failure)))
        ((not (sb-thread:thread-alive-p thread))
         ;; Ended without recording an error: the backend returned without serving.
         (error "hyperion/server: the ~(~A~) backend on ~A:~D stopped before it started listening"
                server host port))
        ((funcall *listening-probe* host port)
         (return (%make-clack-server :thread thread :server server :host host :port port)))
        ((> (get-internal-real-time) deadline)
         (%stop-clack-server thread)
         (error 'server-start-timeout :host host :port port :seconds *start-timeout*))
        (t (sleep 0.02))))))

(defun %stop-clack-server (thread)
  "Stop the thread running a Clack backend and wait for it to end.

Terminating the thread unwinds it, and the backend's own UNWIND-PROTECT closes its socket
on the way out. Waiting for the thread is what makes the socket closed when STOP returns;
`clack:stop' sleeps half a second instead."
  (when (sb-thread:thread-alive-p thread)
    (ignore-errors (sb-thread:terminate-thread thread))
    (ignore-errors (sb-thread:join-thread thread :timeout 10 :default nil))))

(defun stop (handler)
  "Stop a server started by START -- either kind.

Dispatches on the HANDLER, not on a remembered backend name, because the handler is what
callers actually hold: SERVE-FOREVER keeps it in a session, apps keep it in a variable, and
a STOP that also needed the name would be a second value to thread through every one of
them."
  (cond
    ((%uv-server-p handler) (%uv-call "STOP" handler))
    ((clack-server-p handler) (%stop-clack-server (clack-server-thread handler)) t)
    (t (clack:stop handler))))

;;; --- running in the foreground --------------------------------------------
;;;
;;; START is the REPL-friendly primitive: it returns a handler and does not block. Every
;;; DEPLOYED app needs the other half, and until now the framework shipped only the dev
;;; loop -- so the production entry point was the one shape every app had to hand-roll.
;;; Four did (pre-publication issue 124), each independently getting the same five non-obvious things
;;; right, and the fifth would not have.
;;;
;;; What the hand-rolls had to know, none of which is app knowledge:
;;;   - FINISH-OUTPUT after the banner, or the "serving at" line sits in a buffer and the
;;;     app looks hung to whoever just started it
;;;   - SB-SYS:INTERACTIVE-INTERRUPT behind #+sbcl -- Ctrl-C is NOT an ERROR, so a plain
;;;     (handler-case ... (error ...)) never sees it
;;;   - UNWIND-PROTECT, so the socket is released on every exit path and not just Ctrl-C
;;;   - IGNORE-ERRORS around the stop, so a failing shutdown cannot mask the condition
;;;     that caused the shutdown
;;;   - a wait that is actually interruptible

(defvar *shutdown-poll-interval* 0.1
  "Seconds between checks of the stop flag while SERVE-FOREVER is blocked. Bounds how long
any shutdown request takes to be noticed. Ten idle wakeups a second is not measurable next
to serving traffic, and the alternative -- a semaphore -- makes SIGTERM undeliverable.")

(defvar *shutdown-hooks* '()
  "Functions run (in order, errors ignored) after the server stops and before SERVE-FOREVER
returns. For flushing a log, closing a pool, removing a pid file.")

(defun %default-banner (host port)
  (format nil "hyperion serving at http://~A:~D/  (Ctrl-C to stop)" host port))

;;; The interrupt seam.
;;;
;;; SIGTERM is how a process manager, a container runtime and systemd all ask for a clean
;;; exit, and NO app in this tree handles it today -- they are killed mid-request and rely
;;; on the OS to reclaim the socket. #37's `service` target cannot ship without it.
;;;
;;; It does not work yet on this transport either (docs/signals-and-shutdown.md): the
;;; handler is installed and correct, and Woo swallows the signal. That is a reason to
;;; define the seam now, not a reason to leave the shape of the API undecided -- when pre-publication issue 117
;;; lands, every app that already calls SERVE-FOREVER gets working SIGTERM without an edit.
;;;
;;; This is deliberately ONE function behind a variable, because the transport underneath
;;; is going to change. pre-publication issue 117 replaces the Clack server with a native libuv loop, and
;;; aion/uv/process already binds uv_signal_t -- whose whole advantage is that the handler
;;; runs as an ordinary loop callback with a full Lisp stack, rather than in a signal
;;; context where the set of safe operations is small and exceeding it produces no error
;;; message. Swapping to it is then a single rebinding of *INSTALL-SIGNAL-HANDLERS*, and
;;; nothing above this line changes -- which is the point of defining the API on the
;;; current server rather than waiting for the new one.
(defun %install-posix-signal-handlers (request-stop)
  "Route SIGTERM (and SIGINT, for a non-tty parent) to REQUEST-STOP. Returns a thunk that
restores the previous handlers.

The handler does exactly one thing -- release a semaphore -- because it runs in a signal
context. Anything that conses or takes a lock here is a deadlock waiting for the wrong
moment; the actual shutdown work happens on the main thread once it wakes.

WINDOWS HAS NO POSIX SIGNALS, and the guard must say so on the right axis: `#+sbcl` is
TRUE on Windows SBCL, where SB-UNIX:SIGTERM does not exist as a symbol -- so the file
failed to READ, taking hyperion and everything downstream of it with it. A reader
conditional cannot protect a symbol in a package that lacks it unless the condition is on
the platform. Ctrl-C still works there: it arrives as SB-SYS:INTERACTIVE-INTERRUPT, which
SERVE-FOREVER handles separately. A supervisor-initiated stop on Windows is a console
control event or a service STOP, which belongs with the `service` target kind (#37)."
  #+(and sbcl unix)
  (let ((previous '()))
    (dolist (signum (list sb-unix:sigterm sb-unix:sigint))
      (push (cons signum (sb-sys:enable-interrupt signum
                                                  (lambda (&rest _)
                                                    (declare (ignore _))
                                                    (funcall request-stop))))
            previous))
    (lambda ()
      (dolist (pair previous)
        (ignore-errors (sb-sys:enable-interrupt (car pair) (cdr pair))))))
  #-(and sbcl unix) (lambda () nil))

(defvar *install-signal-handlers* #'%install-posix-signal-handlers
  "How SERVE-FOREVER installs signal handling. Called with a REQUEST-STOP thunk; must
return a thunk that restores what was there before. Rebind to swap the mechanism -- a
uv_signal_t handler (pre-publication issue 117), or (constantly (lambda () nil)) to opt out entirely.")

(defstruct (server-session (:constructor %make-server-session) (:copier nil))
  "A running foreground server: the Clack handler, and the flag that ends it."
  (handler nil)
  (stopping nil))

(defun request-shutdown (session)
  "Ask the SERVE-FOREVER running SESSION to shut down. Returns T.

Setting a flag is ALL this does, deliberately, and the reason is worth recording because
the obvious implementation does not work.

A semaphore is the natural choice -- it wakes the waiter instantly instead of on a poll.
But SBCL DEFERS SIGNAL DELIVERY while a thread is blocked in WAIT-ON-SEMAPHORE, even with
a :TIMEOUT: measured here, a SIGTERM sent to a process parked there is never handled at
all, and the process must be SIGKILLed. Which would make this feature ship broken in
exactly the case it exists for. SLEEP, by contrast, is interruptible -- also measured, with
and without the server running.

So the wait is a poll over SLEEP, and both the signal handler and an ordinary caller do the
same safe thing: SETF a slot, no lock, no wakeup primitive. Shutdown is therefore up to
*SHUTDOWN-POLL-INTERVAL* late, which is nothing beside process teardown, and correct on
every path instead of instant on one and broken on the other.

Safe from any thread, and safe from a signal handler."
  (setf (server-session-stopping session) t)
  t)

;;; Kept as a distinct name because a signal handler is a distinct contract -- if this ever
;;; needs to do more than SETF, that extra work belongs here where the constraint is stated,
;;; not in REQUEST-SHUTDOWN where a caller would reasonably add a lock.
(defun request-shutdown-from-signal (session)
  "REQUEST-SHUTDOWN, from a signal context. Must remain lock-free and allocation-free."
  (setf (server-session-stopping session) t)
  t)

(defun serve-forever (app &key (server (default-server)) (port *default-port*)
                               (host "127.0.0.1") debug (log t)
                               name (banner :derive) (signals t) on-ready)
  "Start APP and BLOCK until interrupted or until REQUEST-SHUTDOWN is called. Returns NIL.

The production counterpart to START: same arguments, plus a banner and interrupt handling.
Every `main` in the tree should be a call to this.

  (srv:serve-forever (make-app) :port 8080 :name \"My App\")

NAME titles the derived banner. BANNER replaces the whole line; pass NIL for no banner at
all (the default, :DERIVE, builds one from NAME/host/port).
ON-READY, if given, is called with the SERVER-SESSION once START has returned and the
banner is printed -- the seam a supervisor or a desktop shell hangs off. START returns only
once the port is listening, so by then the socket answers (#159; until then this said the
opposite, because a Clack backend bound its port after START had returned). SIGNALS NIL
skips signal installation, for an app that owns its own.

Shutdown is guaranteed on every exit path: Ctrl-C, SIGTERM, REQUEST-SHUTDOWN, or an
unhandled condition. The socket is released, *SHUTDOWN-HOOKS* run, and the previous signal
handlers are restored -- that last one matters in a REPL, where leaving SIGINT pointing at
a dead server breaks the next thing you run."
  (let* ((session (%make-server-session :handler nil))
         (restore-signals nil)
         handler)
    ;; Installed BEFORE the server starts, so a SIGTERM arriving during startup is handled
    ;; rather than killing a half-built process.
    ;;
    ;; KNOWN LIMITATION, AND IT BELONGS TO ONE BACKEND. On WOO the SIGTERM handler does not
    ;; fire -- not while this function is blocked, and not at toplevel either. Ctrl-C,
    ;; REQUEST-SHUTDOWN and the unwind path all work; a supervisor's SIGTERM does not, and
    ;; the process is killed.
    ;;
    ;; MEASURED, 21 runs, docs/signals-and-shutdown.md and hyperion/bench/signals/run.sh:
    ;; Hunchentoot keeps the signal and so does the native :uv backend, in both modes. Since
    ;; it reproduces OUTSIDE serve-forever, the fault is in the transport (libev, under Woo)
    ;; and nothing here needs to change -- which is also why the uv_signal_t installer that
    ;; doc used to prescribe was never built. The seam below stays, because it is the right
    ;; shape and costs nothing; it simply has no defect left to fix.
    ;;
    ;; So: an app that a supervisor must be able to stop should not declare Woo. That is a
    ;; backend choice, not a change to this function.
    (when signals
      (setf restore-signals
            (funcall *install-signal-handlers*
                     (lambda () (request-shutdown-from-signal session)))))
    (setf handler (start app :server server :port port :host host :debug debug :log log)
          (server-session-handler session) handler)
    ;; BANNER has THREE states, not two, so it cannot be a plain string-or-NIL: derive one
    ;; (the default), print this exact line, or print nothing. With NIL as the default there
    ;; is no way to ask for silence -- :banner nil would be indistinguishable from "not
    ;; supplied" and you would get the default banner anyway. A test caught precisely that.
    (let ((line (case banner
                  (:derive (if name
                               (format nil "~A serving at http://~A:~D/  (Ctrl-C to stop)"
                                       name host port)
                               (%default-banner host port)))
                  ((nil) nil)
                  (t banner))))
      (when line
        ;; FINISH-OUTPUT, not just FORMAT: on a pipe (a container log, a supervisor
        ;; capturing stdout) the stream is block-buffered, and the line an operator is
        ;; waiting for to know the app came up would sit unflushed until something else
        ;; filled the buffer.
        (format t "~&~A~%" line)
        (finish-output)))
    (unwind-protect
         (progn
           (when on-ready (funcall on-ready session))
           (handler-case
               ;; A poll over SLEEP, not (loop (sleep 3600)) and not a semaphore. The
               ;; hand-rolls slept forever because there was nothing to wait ON, so SIGTERM
               ;; could only be answered by killing the process. A semaphore fixes the
               ;; waiting but breaks the signals (see REQUEST-SHUTDOWN). SLEEP is
               ;; interruptible and the flag is checked each tick, so every stop path --
               ;; Ctrl-C, SIGTERM, REQUEST-SHUTDOWN -- works.
               (loop until (server-session-stopping session)
                     do (sleep *shutdown-poll-interval*))
             ;; Ctrl-C at a terminal. Not an ERROR, so it needs its own clause; without it
             ;; the UNWIND-PROTECT still stops the server but the backtrace is printed at
             ;; whoever pressed the key.
             #+sbcl (sb-sys:interactive-interrupt ()
                      (format t "~&Interrupted.~%") (finish-output))))
      (when restore-signals (ignore-errors (funcall restore-signals)))
      ;; IGNORE-ERRORS: if the server is already dead, saying so must not replace the
      ;; condition that killed it with a confusing secondary failure.
      (ignore-errors (stop handler))
      (dolist (hook *shutdown-hooks*) (ignore-errors (funcall hook)))
      (format t "~&Stopped.~%")
      (finish-output))
    nil))
