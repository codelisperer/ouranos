;;;; web-tests.lisp --- praxeon/web's own suite.
;;;;
;;;; WHY THIS FILE EXISTS AT ALL, which is the finding behind pre-publication issue 151.
;;;;
;;;; `praxeon/web' exports a surface and NOTHING LOADED IT. `praxeon/tests' depends on
;;;; "praxeon" and "praxeon/web-search"; the two existing tests that mention praxeon/web
;;;; (pre-publication issue 139/pre-publication issue 218's backend-declaration pair) read its .asd with `asdf:find-system' rather
;;;; than loading the system -- which is why they pass without a handler in the image, and
;;;; why nobody noticed there was no suite underneath them.
;;;;
;;;; That absence is the reason elise's hand-rolled `(loop (sleep 3600))' survived. A layer
;;;; no suite loads cannot report that its consumers are working around it, and review does
;;;; not see absences.
;;;;
;;;; SEPARATE SYSTEM, NOT AN EXTRA FILE IN `praxeon/tests', because driving a real server
;;;; needs a real Clack handler, and WHICH HANDLER IS THE APPLICATION'S CHOICE (pre-publication issue 139,
;;;; ADR-0011, applied to praxeon/web by pre-publication issue 218). `praxeon/web' must keep declaring none. A
;;;; test system is an application for this purpose, so it declares hunchentoot -- the
;;;; backend that answers SIGTERM -- exactly as `praxeon/elise' does, and the core suite
;;;; stays free of an HTTP server it has no use for.

(cl:defpackage #:praxeon/web/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:web #:praxeon/web)
                    (#:srv #:hyperion/server)
                    (#:out #:hyperion/output)
                    (#:actor #:praxeon/actor))
  (:export #:praxeon-web))

(cl:in-package #:praxeon/web/tests)

(def-suite praxeon-web :description "praxeon/web: the blocking entry, and the surface.")
(in-suite praxeon-web)

;;; --- helpers ---------------------------------------------------------------
;;;
;;; The same shape as hyperion/tests/server-tests.lisp's. Deliberately not shared: that file
;;; belongs to another system's test suite, and reaching into it would make this system's
;;; suite depend on hyperion's being loaded.

(defun free-port ()
  "An unused TCP port, obtained by binding one and letting go."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
                (sb-bsd-sockets:socket-bind s #(127 0 0 1) 0)
                (nth-value 1 (sb-bsd-sockets:socket-name s)))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(defun listening-p (port)
  "True if something accepts a TCP connection on PORT right now."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (handler-case (progn (sb-bsd-sockets:socket-connect s #(127 0 0 1) port) t)
           (error () nil))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(defun await (predicate &key (timeout 10) (interval 0.02))
  "Poll PREDICATE until true or TIMEOUT seconds elapse. Returns what it last saw."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop for v = (funcall predicate)
          when v return v
          when (> (get-internal-real-time) deadline) return nil
          do (sleep interval))))

(defun quiet-agent ()
  "An agent that never reaches a model. These tests are about the ENTRY POINT -- whether it
blocks, serves and stops -- so a turn that called out would only add a network dependency to
a question that has nothing to do with the network."
  (actor:make-agent :name "web-suite"))

;;; --- the blocking entry ----------------------------------------------------

(test serve-forever-blocks-serves-and-stops-on-request
  ;; The claim pre-publication issue 151 turns on. `praxeon/web:serve-forever' must actually BLOCK (so it is a
  ;; usable `main'), actually SERVE (so it is not just sleeping), and RETURN when asked (so
  ;; the hand-roll it replaces is not needed). All three, because the hand-rolled version
  ;; satisfied the first two and failed only the third.
  (let* ((port (free-port))
         (session nil)
         (ready (sb-thread:make-semaphore :name "px-web-ready"))
         (returned nil)
         (banner (make-string-output-stream))
         (thread (sb-thread:make-thread
                  (lambda ()
                    (let ((*standard-output* banner))
                      (web:serve-forever
                       :agent (quiet-agent) :agent-name "Test Agent"
                       :port port :log nil
                       :on-ready (lambda (s)
                                   (setf session s)
                                   (sb-thread:signal-semaphore ready)))
                      ;; Reached only if it RETURNED rather than being killed.
                      (setf returned t)))
                  :name "praxeon-web-test-server")))
    (unwind-protect
         (progn
           (is (sb-thread:wait-on-semaphore ready :timeout 10)
               "praxeon/web:serve-forever never became ready")
           (is (srv:server-session-p session)
               "on-ready did not receive a server session")
           ;; Poll: on-ready fires when START returns, i.e. when the handler exists. Clack
           ;; runs the backend on its own thread, so the socket can be a moment behind.
           (is (await (lambda () (listening-p port)))
               "nothing was accepting connections on the port it said it was serving")
           ;; IT WAS STILL BLOCKED. Without this the test would pass against a function
           ;; that started a server and returned immediately -- which is `start', not
           ;; `serve-forever', and is the whole difference between them.
           (is-false returned "serve-forever returned while it was supposed to be blocking")
           (web:request-shutdown session)
           (is (await (lambda () (not (listening-p port))))
               "the port was not released after request-shutdown")
           (sb-thread:join-thread thread :timeout 10)
           (is-true returned "serve-forever did not return after request-shutdown"))
      (when session (ignore-errors (web:request-shutdown session)))
      (ignore-errors (sb-thread:join-thread thread :timeout 10)))
    ;; The banner is the operator's only signal that the app came up, and :name defaults to
    ;; AGENT-NAME rather than to Praxeon -- an app called Elise should not announce itself
    ;; as something else.
    (let ((text (get-output-stream-string banner)))
      (is (search "Test Agent" text)
          "the banner did not carry the agent's name: ~S" text)
      (is (search (princ-to-string port) text)
          "the banner did not name the port actually bound: ~S" text))))

;;; --- the surface -----------------------------------------------------------

(test the-blocking-entry-and-its-stop-are-both-exported
  ;; A blocking entry without the thing that stops it is half a surface: an app that has
  ;; SERVE-FOREVER and not REQUEST-SHUTDOWN still has to reach past praxeon/web into
  ;; hyperion/server, which is the reaching this was added to remove.
  (dolist (name '("SERVE-FOREVER" "REQUEST-SHUTDOWN" "START" "STOP" "MAKE-APP"))
    (multiple-value-bind (symbol status) (find-symbol name (find-package "PRAXEON/WEB"))
      (is (eq status :external)
          "praxeon/web does not export ~A (status ~S)" name status)
      (is-true (fboundp symbol) "praxeon/web:~A is exported but not fbound" name))))

;;; --------------------------------------------------------------------------
;;; The output style is the app's, not the image's (pre-publication issue 469)
;;; --------------------------------------------------------------------------

(in-suite praxeon-web)

(defun %bubble-from-turn (style)
  "Run one turn on a conversation rendering in STYLE and return the bubble it produced.

Drives `%run-turn-async' directly rather than going through HTTP, because the property under
test is that the TURN THREAD renders in the app's style -- and that thread is the thing HTTP
would hide behind a poll."
  (let ((conv (web::make-conversation
               :agent-name "Test"
               :output-style style
               :responder (lambda (agent message locale)
                            (declare (ignore agent message locale))
                            "hello"))))
    (sb-thread:join-thread (web::%run-turn-async conv "hi" nil))
    (format nil "~{~A~}" (web::%drain-bubbles conv))))

(test starting-the-surface-does-not-change-the-image-s-output-style
  "pre-publication issue 469. praxeon/web can be started as a SECOND server inside a host app's image, so it must
not publish its own rendering choice to the global every Spinneret renderer in that image
reads. Before the fix `%build-app' did `(setf out:*output-style* ...)' and the host's
rendering changed for the rest of the process."
  ;; `%build-app', NOT `make-app'. The assignment lived in the former, which is what `start'
  ;; and `serve-forever' call; `make-app' never had it. The first version of this test called
  ;; `make-app' and passed with the defect fully restored -- a test that could not fail,
  ;; written for the fix, and found only by running the control.
  ;; EACH CASE PICKS AN IMAGE STYLE THE DEFECT WOULD OVERWRITE. Asserting :pretty survives a
  ;; :dev build is worthless -- the defect writes :pretty there, so that assertion passes with
  ;; the bug fully present. Measured: under the reverted fix this test failed `f.\', one of two.
  ;; So the non-dev case runs against a :pretty image and the dev case against a :compact one.
  (let ((out:*output-style* :pretty))
    (web::%build-app nil "Guest" "Guest" #'identity nil nil nil nil nil nil)
    (is (eq :pretty out:*output-style*)
        "a :pretty host survives a non-dev agent surface, which the defect would set :compact"))
  (let ((out:*output-style* :compact))
    (web::%build-app nil "Guest" "Guest" #'identity nil nil t nil nil nil)
    (is (eq :compact out:*output-style*)
        "and a :compact host survives a :dev one, which the defect would set :pretty")))

(test the-turn-thread-renders-in-the-app-s-style
  "THE TRAP THIS FIX HAD TO AVOID. `%assistant-bubble' runs inside `%run-turn-async', and the
request's WITH-OUTPUT-STYLE wraps the dispatcher on the REQUEST thread. Before pre-publication issue 469 the turn
thread rendered correctly only because the style was a global assigned at startup, so removing
that assignment without carrying the style would have rendered the assistant bubble in the
wrong style -- only in the poller, only for the assistant, and visible as whitespace rather
than as an error."
  (let ((out:*output-style* :compact))   ; the image says compact; the app will say otherwise
    (let ((pretty (%bubble-from-turn :pretty))
          (compact (%bubble-from-turn :compact)))
      (is (string/= pretty compact)
          "the two styles must actually differ, or neither assertion below means anything")
      ;; ELEMENT ADJACENCY, not newline presence. The first version of this asserted that a
      ;; compact bubble had no newline and failed: the markdown body emits one of its own,
      ;; independent of Spinneret. Newlines were a proxy for the property; `><' between two
      ;; tags is the property -- compact puts elements adjacent, pretty separates them.
      (is (search "><div" compact)
          "a :compact app renders elements adjacent ON THE TURN THREAD: ~S" compact)
      (is (not (search "><div" pretty))
          "and a :pretty app separates them, so the first is not merely always-true: ~S" pretty))))
