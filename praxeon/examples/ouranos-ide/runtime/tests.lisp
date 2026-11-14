;;;; tests.lisp --- the runtime client against a real child SBCL (#1218).
;;;;
;;;; Every test starts its own child that loads Coalton's `mine/runtime`, and kills it. No
;;;; window, no browser and no network beyond 127.0.0.1. The suite needs the Coalton checkout
;;;; to contain the `mine` directory and `sbcl` to be on the search path.

(cl:defpackage #:praxeon/examples/ouranos-ide/runtime/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:rt #:praxeon/examples/ouranos-ide/runtime))
  (:export #:run-tests))

(cl:in-package #:praxeon/examples/ouranos-ide/runtime/tests)

(def-suite ouranos-ide-runtime
  :description "A client for Coalton's mine/runtime server in a child SBCL (#1218).")
(in-suite ouranos-ide-runtime)

(defun run-tests () (run! 'ouranos-ide-runtime))

(defun %process-exists-p (pid)
  "True when the operating system still lists a process with PID. A killed child that nobody
waited for is still listed, so this is false only once the child is gone entirely. The
Windows branch has not been run."
  #+unix
  (zerop (nth-value 2 (uiop:run-program (list "ps" "-p" (princ-to-string pid))
                                        :ignore-error-status t :output nil :error-output nil)))
  #+win32
  (not (null (search (princ-to-string pid)
                     (uiop:run-program (list "tasklist" "/NH" "/FI" (format nil "PID eq ~D" pid))
                                       :ignore-error-status t :output :string)))))

(defun %kill-pid (pid)
  "Kill PID whatever the client did. Used so a failing test leaves no child behind."
  (when (%process-exists-p pid)
    #+unix (uiop:run-program (list "kill" "-9" (princ-to-string pid)) :ignore-error-status t)
    #+win32 (uiop:run-program (list "taskkill" "/F" "/PID" (princ-to-string pid))
                              :ignore-error-status t)))

(defmacro %with-runtime ((runtime) &body body)
  "BODY with RUNTIME bound to a started runtime. The child is gone when the form returns."
  (let ((pid (gensym "PID")))
    `(let* ((,runtime (rt:start-runtime))
            (,pid (rt:runtime-pid ,runtime)))
       (unwind-protect (progn ,@body)
         (ignore-errors (rt:runtime-stop ,runtime))
         (%kill-pid ,pid)))))

(defun %lines (&rest lines)
  (format nil "~{~A~^~%~}" lines))

;;; --- diagnostics -------------------------------------------------------------------------

(test a-type-error-gets-a-diagnostic-at-the-string
  ;; The first line holds four two-byte characters. A position counted in bytes would be 4
  ;; too large, so the expected offsets also check that positions count characters.
  (%with-runtime (runtime)
    (let* ((code (%lines ";; λλλλ"
                         "(declare spike-bad (Integer -> Integer))"
                         "(define (spike-bad x) (+ x \"a\"))"))
           (at (search "\"a\"" code))
           (reply (rt:runtime-compile-string runtime code))
           (diagnostics (rt:reply-diagnostics reply)))
      (is (eq :error (rt:reply-status reply)))
      (is (= 1 (length diagnostics)))
      (let ((diagnostic (first diagnostics)))
        (is (eq :error (rt:diagnostic-severity diagnostic)))
        (is (equal "Type mismatch" (rt:diagnostic-summary diagnostic)))
        (is (search "Integer" (rt:diagnostic-label diagnostic)))
        (is (search "String" (rt:diagnostic-label diagnostic)))
        (is (eql at (rt:diagnostic-start diagnostic)))
        (is (eql (+ at 3) (rt:diagnostic-end diagnostic))))
      ;; The server entered its debugger for the failed compile and the client left it.
      (is (search "Type mismatch" (rt:reply-condition reply)))
      ;; The runtime answers afterwards, so the debugger is not still waiting.
      (is-true (rt:runtime-ping runtime)))))

(test a-diagnostic-position-includes-the-snippets-offset-in-the-document
  (%with-runtime (runtime)
    ;; The declaration matters: without it Coalton reports "Ambiguous predicate Num String"
    ;; at the `+`, a different error at a different place.
    (let* ((code (%lines "(declare spike-offset (Integer -> Integer))"
                         "(define (spike-offset x) (+ x \"a\"))"))
           (at (search "\"a\"" code))
           (reply (rt:runtime-compile-string runtime code :position 1000 :document "buffer-1"))
           (diagnostic (first (rt:reply-diagnostics reply))))
      (is (eql (+ 1000 at) (rt:diagnostic-start diagnostic)))
      (is (equal "buffer-1" (getf diagnostic :file))))))

(test a-valid-snippet-compiles-clean-and-is-defined-afterwards
  (%with-runtime (runtime)
    ;; Not defined before the compile, so the type after it comes from this compile.
    (is (null (rt:runtime-coalton-type-of runtime "spike-good")))
    (let ((reply (rt:runtime-compile-string
                  runtime (%lines "(declare spike-good (Integer -> Integer))"
                                  "(define (spike-good x) (+ x 1))"))))
      (is (eq :ok (rt:reply-status reply)))
      (is (null (rt:reply-diagnostics reply)))
      (is (null (rt:reply-condition reply))))
    (is (equal "Integer → Integer" (rt:runtime-coalton-type-of runtime "spike-good")))
    (let ((reply (rt:runtime-eval runtime "(spike-good 41)")))
      (is (eq :ok (rt:reply-status reply)))
      (is (search "\"42\"" (rt:reply-value reply))))))

;;; --- completion and types ----------------------------------------------------------------

(test completing-fol-returns-fold-with-its-type
  (%with-runtime (runtime)
    (let* ((matches (rt:runtime-complete runtime "fol"))
           (fold (find "fold" matches :key #'first :test #'string=)))
      (is-true fold)
      (is (equal "fn" (second fold)))
      (is (search "Foldable" (third fold)))
      (is (every (lambda (match) (eql 0 (search "fol" (first match)))) matches))
      (is (= 1 (length (rt:runtime-complete runtime "fol" :limit 1)))))))

(test coalton-type-of-map-is-the-functor-signature
  (%with-runtime (runtime)
    (let ((type (rt:runtime-coalton-type-of runtime "map")))
      (is (stringp type))
      (is (search "Functor" type))
      (is (search "→" type)))
    (is (null (rt:runtime-coalton-type-of runtime "no-such-symbol-anywhere")))
    ;; The Lisp argument list of a Coalton function is the compiled function's, with the
    ;; class dictionary first. It is recorded here because it is not what an editor shows.
    (is (search "DICT" (rt:runtime-arglist runtime "fold")))
    (is (equal "(FUNCTION LIST &REST MORE-LISTS)"
               (rt:runtime-arglist runtime "mapcar" :package "CL-USER")))))

;;; --- interrupt ---------------------------------------------------------------------------

(test an-endless-loop-is-interrupted
  (%with-runtime (runtime)
    (let* ((reply nil)
           (thread (sb-thread:make-thread
                    (lambda ()
                      (setf reply (ignore-errors
                                   (rt:runtime-eval runtime "(loop)" :package "CL-USER"
                                                                     :coalton nil :timeout 60))))
                    :name "ouranos-ide-runtime-loop-test"))
           (interrupted nil))
      ;; The server refuses an interrupt for a request it has not started, so try until it
      ;; accepts one, for at most ten seconds.
      (loop :repeat 100
            :until (setf interrupted (rt:runtime-interrupt runtime))
            :do (sleep 0.1))
      (is-true interrupted)
      (unless interrupted
        ;; Killing the child ends the evaluation, so the thread below can be joined.
        (rt:runtime-stop runtime))
      (is (not (eq :timed-out (sb-thread:join-thread thread :timeout 15 :default :timed-out))))
      (is-true reply)
      (when reply
        (is (eq :error (rt:reply-status reply)))
        (is (search "nterrupt" (rt:reply-condition reply))))
      (when interrupted
        ;; The same child still evaluates, so the interrupt ended the request and not the server.
        (let ((after (rt:runtime-eval runtime "(+ 1 2)" :package "CL-USER" :coalton nil)))
          (is (search "\"3\"" (rt:reply-value after))))))))

;;; --- the child process -------------------------------------------------------------------

(test stopping-leaves-no-child-process
  (let* ((runtime (rt:start-runtime))
         (pid (rt:runtime-pid runtime)))
    (unwind-protect
         (progn
           (is-true (rt:runtime-alive-p runtime))
           (is-true (%process-exists-p pid))
           (is (eql pid (rt:runtime-stop runtime)))
           (is-false (rt:runtime-alive-p runtime))
           (is-false (%process-exists-p pid))
           ;; A second stop is harmless, and a request after it fails instead of hanging.
           (is (eql pid (rt:runtime-stop runtime)))
           (signals rt:runtime-closed (rt:runtime-ping runtime)))
      (%kill-pid pid))))

(test the-child-exits-when-its-standard-input-closes
  ;; The parent holds the other end of the child's standard input. Closing it is what the
  ;; operating system does when the parent dies, so this stands in for a crashed IDE.
  (%with-runtime (runtime)
    (let ((pid (rt:runtime-pid runtime)))
      (close (sb-ext:process-input (rt::runtime-process runtime)))
      (loop :repeat 100
            :while (rt:runtime-alive-p runtime)
            :do (sleep 0.1))
      (is-false (rt:runtime-alive-p runtime))
      ;; Wait for the exit only when there was one; waiting on a child that is still
      ;; running would hang the suite.
      (unless (rt:runtime-alive-p runtime)
        (sb-ext:process-wait (rt::runtime-process runtime))
        (is-false (%process-exists-p pid))))))

(test a-child-that-cannot-start-is-reported-and-not-left-running
  (signals rt:runtime-start-failed
    (rt:start-runtime :program "ouranos-no-such-sbcl-program"))
  ;; A real SBCL given no time to load: the timeout is reported and that child is killed.
  (let ((failure (handler-case (progn (rt:start-runtime :timeout 0.05) nil)
                   (rt:runtime-start-failed (c) c))))
    (is-true failure)
    (when failure
      (is (search "no port line" (princ-to-string failure)))
      (is (integerp (rt:start-failure-pid failure)))
      (is-false (%process-exists-p (rt:start-failure-pid failure))))))
