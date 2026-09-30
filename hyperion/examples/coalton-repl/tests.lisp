;;;; tests.lisp --- the Coalton REPL example's answers to (exit), a long evaluation and a cancel (#355).
;;;;
;;;; The handlers are called directly, with the request body already cached, so no server and
;;;; no window are started. That RUN-APP returns once REQUEST-CLOSE is called is tested in
;;;; hyperion/tests (desktop-window-tests.lisp).

(cl:defpackage #:hyperion/examples/coalton-repl/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:app #:hyperion/examples/coalton-repl)
                    (#:http #:hyperion/http)
                    (#:repl #:cons/coalton-repl))
  (:export #:run-tests))
(cl:in-package #:hyperion/examples/coalton-repl/tests)

(def-suite coalton-repl-app :description "The desktop Coalton REPL example (#355).")
(in-suite coalton-repl-app)

(defun run-tests () (run! 'coalton-repl-app))

(defun %post (input)
  "The body of the /eval response for INPUT."
  (let ((response (app::%handle-eval
                   (http:cache-body-string '() (format nil "input=~A" (quri:url-encode input))))))
    (values (apply #'concatenate 'string (third response)) (first response))))

(defmacro %with-fresh-session (&body body)
  "BODY with the app's global session and exit handler replaced, and put back afterwards.
SETF rather than LET, because the cancel test evaluates on another thread."
  `(let ((old-session app::*session*) (old-exit app::*on-exit-request*))
     (setf app::*session* (repl:make-session))
     (unwind-protect (progn ,@body)
       (setf app::*session* old-session app::*on-exit-request* old-exit))))

(test exit-closes-the-desktop-app
  (%with-fresh-session
    (let ((closed 0))
      (setf app::*on-exit-request* (lambda () (incf closed)))
      (dolist (in '("(exit)" "(quit)" "(lisp (-> Integer) () (sb-ext:exit))"))
        (multiple-value-bind (body status) (%post in)
          (is (= 200 status))
          (is (search "Closing the REPL" body) "~S answered: ~A" in body)))
      (is (= 3 closed) "the exit handler ran once per request, got ~D" closed))))

(test exit-is-refused-when-the-repl-is-served-over-the-network
  (%with-fresh-session
    (setf app::*on-exit-request* nil)
    (let ((body (%post "(exit)")))
      (is (search "refused" body) "answered: ~A" body)
      (is (null (search "Closing" body))))
    (is (search "42" (%post "(* 6 7)")) "the REPL still evaluates afterwards")))

(test a-long-evaluation-is-stopped-by-the-time-limit
  (%with-fresh-session
    (let ((app::*eval-time-limit* 1))
      (let ((body (%post "(lisp (-> Integer) () (cl:loop (cl:sleep 0.02)))")))
        (is (search "time limit" body) "answered: ~A" body)))
    (is (search "42" (%post "(* 6 7)")))))

(test the-cancel-route-stops-the-running-evaluation
  (%with-fresh-session
    (let* ((body nil)
           ;; THREAD-LIFETIME: independent -- stands in for the request thread that is waiting
           ;; on /eval while the test posts /cancel; joined before the test ends.
           (thread (sb-thread:make-thread
                    (lambda () (setf body (%post "(lisp (-> Integer) () (cl:loop (cl:sleep 0.02)))"))))))
      (unwind-protect
           (progn
             (sleep 1)
             (is (= 204 (first (app::%handle-cancel '()))))
             (sb-thread:join-thread thread :default nil :timeout 10)
             (is (and body (search "cancelled" body)) "answered: ~A" body))
        (when (sb-thread:thread-alive-p thread)
          (repl:cancel-evaluation app::*session*)
          (sb-thread:join-thread thread :default nil :timeout 10))))))

(test the-page-can-cancel-and-notices-a-lost-backend
  (let ((page (app::%page)))
    (is (search "hx-request" page) "the form sets a request timeout")
    (is (search (format nil "~D" (* 1000 (+ app::*eval-time-limit* 15))) page))
    (is (search "/cancel" page) "the page script posts to /cancel")
    (is (search "htmx:sendError" page))
    (is (search "htmx:timeout" page))))
