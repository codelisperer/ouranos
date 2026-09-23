;;;; uv-process.lisp --- tests for aion/uv/process.
;;;;
;;;; Real child processes, over a real libuv, on POSIX and Windows both. Process creation
;;;; is the most divergent part of libuv's API, so every child program lives in one block
;;;; below ("the child programs, per platform") and each test names a constant from it --
;;;; the alternative, a #+windows beside each spawn, buries the interesting part of a test
;;;; under its plumbing. See aion/docs/uv-process-design.md.
;;;;
;;;; TWO THINGS WINDOWS CANNOT DO, rather than does differently, both verified against
;;;; libuv 1.52.1 (#119): a process cannot raise a signal at ITSELF -- uv_kill answers
;;;; ENOSYS -- so the two self-signalling tests skip there with that reason; and there is
;;;; no stock byte-exact `cat`, so the relay child is another SBCL (see CAT-PROGRAM).
;;;;
;;;;     sbcl --script scripts/build-libuv.lisp
;;;;
;;;; Run: (asdf:test-system :aion/uv/process)

(defpackage #:aion/uv/process/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:uv #:aion/uv)
                    (#:net #:aion/uv/net)
                    (#:proc #:aion/uv/process)
                    (#:types #:aion/uv/process/types))
  (:export #:run-tests #:uv-process))

(in-package #:aion/uv/process/tests)

(def-suite uv-process :description "aion/uv/process: spawn, streamed stdio, signals.")
(in-suite uv-process)

(defun run-tests ()
  (let ((results (run 'uv-process)))
    (explain! results)
    (results-status results)))

(defun pump (loop &key (until (constantly nil)) (limit 4000))
  (loop repeat limit
        until (funcall until)
        do (uv:run loop :mode :nowait)
           (sleep 0.001))
  (funcall until))

(defun text (octets) (sb-ext:octets-to-string octets :external-format :utf-8))

(defun collect-into (place-fn)
  (lambda (data connection)
    (declare (ignore connection))
    (funcall place-fn data)))

;;; --- the child programs, per platform ------------------------------------------------
;;;
;;; Unix runs these through /bin/sh and a few coreutils. Windows has none of them and its
;;; shell speaks a different language, so everything platform-dependent is gathered HERE
;;; and the tests below read identically on both. The Unix values are unchanged from when
;;; this was a POSIX-only suite, deliberately: a green Linux run still means what it meant.
;;;
;;; Each Windows equivalent was MEASURED rather than assumed (#119). Two that look obvious
;;; and are wrong: `findstr "^"` drops a final line that has no terminator, and `more`
;;; appends a CRLF -- so neither can stand in for `cat` where the assertion is exact.

(defparameter +shell+ #+windows "cmd.exe" #-windows "/bin/sh")

(defun shell-args (command)
  "ARGUMENTS that make +SHELL+ run COMMAND."
  (list #+windows "/c" #-windows "-c" command))

(defparameter +cmd-exit-0+ "exit 0")
(defparameter +cmd-exit-7+ "exit 7")
(defparameter +cmd-echo+ "echo hello from a child")
(defparameter +cmd-echo-void+ "echo into the void")

(defparameter +cmd-two-streams+
  #+windows "echo to-stdout& echo to-stderr 1>&2"
  #-windows "echo to-stdout; echo to-stderr >&2")

(defparameter +cmd-slow-output+
  ;; cmd.exe has no sub-second sleep; `ping -n 2` waits about a second, which is well
  ;; inside this test's own limit. `timeout` would be the obvious choice and cannot be
  ;; used: it reads the console directly and fails outright when stdin is a pipe.
  #+windows "echo one& ping -n 2 127.0.0.1 >nul& echo two"
  #-windows "echo one; sleep 0.4; echo two")

(defparameter +cmd-sleep-long+
  #+windows "ping -n 31 127.0.0.1 >nul"
  #-windows "sleep 30")

(defparameter +cmd-cwd-and-env+
  #+windows "cd& echo %AION_UV_TEST%"
  #-windows "pwd; echo $AION_UV_TEST")

(defparameter +cmd-produce-400-lines+
  #+windows (format nil "for /l %i in (1,1,400) do @echo ~A"
                    (make-string 50 :initial-element #\a))
  #-windows "i=0; while [ $i -lt 400 ]; do echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; i=$((i+1)); done")

(defparameter +eol-width+ #+windows 2 #-windows 1
  "Bytes a shell `echo` puts at the end of each line: CRLF on Windows, LF elsewhere.")

(defparameter +child-cwd+
  #+windows (namestring (uiop:temporary-directory))
  #-windows "/tmp")

(defparameter +child-cwd-marker+
  #+windows (car (last (pathname-directory (uiop:temporary-directory))))
  #-windows "/tmp"
  "What the child's own `print the working directory` prints that we can look for. On
Windows the separators and case would not survive a literal comparison, so this is the
final directory component rather than the whole path.")

(defun child-env ()
  "The environment for the cwd/env test. Windows needs SystemRoot: cmd.exe will not start
without it, so a minimal environment there would test our error handling, not the child's."
  #+windows `(("AION_UV_TEST" . "reached")
              ("SystemRoot" . ,(or (uiop:getenv "SystemRoot") "C:\\Windows"))
              ("PATH" . ,(or (uiop:getenv "PATH") "")))
  #-windows '(("AION_UV_TEST" . "reached")
              ("PATH" . "/usr/bin:/bin")))

(defun cat-program ()
  "(values PROGRAM ARGUMENTS) for a child that copies stdin to stdout BYTE FOR BYTE.
Windows ships no such tool (see the note above), and weakening the assertion to tolerate
one would give up exactly what this test checks. SBCL is already present and is exact, so
there the child is another SBCL running a six-line copy loop."
  #-windows (values "/bin/cat" '())
  #+windows
  (let ((script (merge-pathnames "aion-uv-cat.lisp" (uiop:temporary-directory))))
    (with-open-file (out script :direction :output :if-exists :supersede)
      ;; Byte streams over the fds SBCL already opened, rather than the character streams:
      ;; a relay must not re-encode. The fd comes FROM the existing stream -- hardcoding 0
      ;; and 1 fails on Windows with "Access is denied", because there an fd number is not
      ;; the handle. The literal 0/1 version is the obvious one and does not work.
      (write-string "(let* ((in (sb-sys:make-fd-stream (sb-sys:fd-stream-fd sb-sys:*stdin*)
                                  :element-type '(unsigned-byte 8) :input t))
       (out (sb-sys:make-fd-stream (sb-sys:fd-stream-fd sb-sys:*stdout*)
                                   :element-type '(unsigned-byte 8) :output t))
       (buf (make-array 4096 :element-type '(unsigned-byte 8))))
  (loop for n = (read-sequence buf in) while (plusp n)
        do (write-sequence buf out :end n))
  (finish-output out))" out))
    (values (namestring sb-ext:*runtime-pathname*)
            (list "--script" (namestring script)))))

;;; --- the typed core (pure, no processes involved) ---------------------------------

(test termination-reads-both-numbers-together
  ;; The trap this type exists to close: a process killed by a signal reports exit
  ;; status ZERO, so status alone says it succeeded.
  (is (string= "exited-0" (types:termination-tag 0 0)))
  (is (string= "exited-3" (types:termination-tag 3 0)))
  (is (string= "killed-SIGTERM" (types:termination-tag 0 15)))
  (is (string= "killed-SIGKILL" (types:termination-tag 0 9))))

(test a-killed-process-did-not-succeed
  (is-true (types:terminated-well? 0 0))
  (is-false (types:terminated-well? 1 0))
  ;; Exit status 0 AND killed: the case that fools a status-only check.
  (is-false (types:terminated-well? 0 15)))

(test signal-names-and-numbers-round-trip
  (is (= 15 (types:signal-number "term")))
  (is (= 2 (types:signal-number "int")))
  (is (= 9 (types:signal-number "kill")))
  (is (string= "SIGTERM" (types:signal-name 15)))
  (is (string= "SIGINT" (types:signal-name 2)))
  ;; A name this table does not carry returns 0 rather than a guess -- the CL shell
  ;; turns that into an error instead of passing 0 to kill(2), where it would silently
  ;; mean "just check the process exists".
  (is (= 0 (types:signal-number "usr1")))
  (is (string= "signal-99" (types:signal-name 99))))

;;; --- spawning ----------------------------------------------------------------------

(test a-child-exits-and-reports-how
  (uv:with-loop (l)
    (let ((process (proc:spawn l +shell+ :arguments (shell-args +cmd-exit-0+))))
      (is-true (pump l :until (lambda () (not (proc:process-running-p process)))))
      (is (= 0 (proc:exit-status process)))
      (is (= 0 (proc:term-signal process)))
      (is (string= "exited-0" (proc:termination process)))
      (is-true (proc:succeeded-p process))
      (is (plusp (proc:process-pid process)))
      (proc:close-process process))))

(test a-nonzero-exit-is-not-a-condition
  ;; A process that starts and fails is an ordinary outcome, not an error to signal.
  (uv:with-loop (l)
    (let ((process (proc:spawn l +shell+ :arguments (shell-args +cmd-exit-7+))))
      (is-true (pump l :until (lambda () (not (proc:process-running-p process)))))
      (is (= 7 (proc:exit-status process)))
      (is-false (proc:succeeded-p process))
      (is (string= "exited-7" (proc:termination process)))
      (proc:close-process process))))

(test a-missing-program-signals-rather-than-exiting-nonzero
  ;; Failing to START is different in kind from starting and failing.
  (uv:with-loop (l)
    (signals proc:spawn-failed
      (proc:spawn l "/definitely/not/a/program"))))

(test stdout-arrives-as-a-stream
  (uv:with-loop (l)
    (let* ((collected (make-array 0 :element-type '(unsigned-byte 8)))
           (ended nil)
           (process (proc:spawn l +shell+ :arguments (shell-args +cmd-echo+))))
      (net:start-reading (proc:process-stdout process)
                         (collect-into (lambda (data)
                                         (setf collected
                                               (concatenate '(vector (unsigned-byte 8))
                                                            collected data))))
                         :on-end (lambda (c) (declare (ignore c)) (setf ended t)))
      (is-true (pump l :until (lambda () (and ended
                                              (not (proc:process-running-p process))))))
      (is (string= "hello from a child" (string-trim '(#\Newline #\Return) (text collected))))
      (is-true (proc:succeeded-p process))
      (proc:close-process process))))

(test stdout-and-stderr-are-separate
  (uv:with-loop (l)
    (let ((out (make-array 0 :element-type '(unsigned-byte 8)))
          (err (make-array 0 :element-type '(unsigned-byte 8)))
          (out-done nil) (err-done nil)
          (process nil))
      (setf process (proc:spawn l +shell+ :arguments (shell-args +cmd-two-streams+)))
      (net:start-reading (proc:process-stdout process)
                         (collect-into (lambda (d)
                                         (setf out (concatenate
                                                    '(vector (unsigned-byte 8)) out d))))
                         :on-end (lambda (c) (declare (ignore c)) (setf out-done t)))
      (net:start-reading (proc:process-stderr process)
                         (collect-into (lambda (d)
                                         (setf err (concatenate
                                                    '(vector (unsigned-byte 8)) err d))))
                         :on-end (lambda (c) (declare (ignore c)) (setf err-done t)))
      (is-true (pump l :until (lambda () (and out-done err-done))))
      (is (search "to-stdout" (text out)))
      (is (search "to-stderr" (text err)))
      ;; Crossed streams would be the bug: each must carry only its own.
      (is-false (search "to-stderr" (text out)))
      (is-false (search "to-stdout" (text err)))
      (proc:close-process process))))

(test stdin-is-writable-and-the-child-sees-it
  ;; The direction words are from the CHILD's point of view, so this also tests that
  ;; stdin was given UV_READABLE_PIPE rather than the other one.
  (uv:with-loop (l)
    (let ((out (make-array 0 :element-type '(unsigned-byte 8)))
          (ended nil)
          (process nil))
      (setf process (multiple-value-bind (program arguments) (cat-program)
                      (proc:spawn l program :arguments arguments)))
      (net:start-reading (proc:process-stdout process)
                         (collect-into (lambda (d)
                                         (setf out (concatenate
                                                    '(vector (unsigned-byte 8)) out d))))
                         :on-end (lambda (c) (declare (ignore c)) (setf ended t)))
      (net:write-bytes (proc:process-stdin process) "round trip through cat")
      ;; cat runs until its stdin closes, so the half-close is what ends the test.
      (net:shutdown-write (proc:process-stdin process))
      (is-true (pump l :until (lambda () (and ended
                                              (not (proc:process-running-p process))))))
      (is (string= "round trip through cat" (text out)))
      (is-true (proc:succeeded-p process))
      (proc:close-process process))))

(test output-streams-while-the-child-is-still-running
  ;; The motivation for the whole sub-system: a long-running target's output must arrive
  ;; as it is produced, not in a lump at exit. Asserted by observing the first chunk
  ;; while the process is still alive.
  (uv:with-loop (l)
    (let ((first-chunk-while-running nil)
          (chunks 0)
          (process nil))
      (setf process (proc:spawn l +shell+ :arguments (shell-args +cmd-slow-output+)))
      (net:start-reading (proc:process-stdout process)
                         (lambda (data connection)
                           (declare (ignore data connection))
                           (incf chunks)
                           (when (and (= chunks 1) (proc:process-running-p process))
                             (setf first-chunk-while-running t))))
      (is-true (pump l :until (lambda () (not (proc:process-running-p process)))
                       :limit 8000))
      (is-true first-chunk-while-running)
      (proc:close-process process))))

(test a-child-can-be-killed-and-says-so
  (uv:with-loop (l)
    (let ((process (proc:spawn l +shell+ :arguments (shell-args +cmd-sleep-long+))))
      (pump l :limit 50)
      (proc:kill process :term)
      (is-true (pump l :until (lambda () (not (proc:process-running-p process)))))
      ;; Exit status is 0 for a killed process, which is exactly why SUCCEEDED-P must
      ;; not consult it alone.
      (is (= 15 (proc:term-signal process)))
      (is (string= "killed-SIGTERM" (proc:termination process)))
      (is-false (proc:succeeded-p process))
      (proc:close-process process))))

(test an-unknown-signal-name-is-refused
  (uv:with-loop (l)
    (let ((process (proc:spawn l +shell+ :arguments (shell-args +cmd-sleep-long+))))
      (pump l :limit 50)
      ;; :usr1 is deliberately absent from the table -- its number differs between Linux
      ;; and macOS -- so it must be refused rather than given a plausible number.
      (signals uv:uv-error (proc:kill process :usr1))
      (proc:kill process :kill)
      (pump l :until (lambda () (not (proc:process-running-p process))))
      (proc:close-process process))))

(test cwd-and-env-reach-the-child
  (uv:with-loop (l)
    (let ((out (make-array 0 :element-type '(unsigned-byte 8)))
          (ended nil)
          (process nil))
      (setf process (proc:spawn l +shell+ :arguments (shell-args +cmd-cwd-and-env+)
                                       :cwd +child-cwd+ :env (child-env)))
      (net:start-reading (proc:process-stdout process)
                         (collect-into (lambda (d)
                                         (setf out (concatenate
                                                    '(vector (unsigned-byte 8)) out d))))
                         :on-end (lambda (c) (declare (ignore c)) (setf ended t)))
      (is-true (pump l :until (lambda () ended)))
      (is (search +child-cwd-marker+ (text out)))
      (is (search "reached" (text out)))
      (proc:close-process process))))

(test stdio-can-be-ignored
  (uv:with-loop (l)
    (let ((process (proc:spawn l +shell+ :arguments (shell-args +cmd-echo-void+)
                                       :stdout :ignore :stderr :ignore)))
      (is-true (pump l :until (lambda () (not (proc:process-running-p process)))))
      (is-true (proc:succeeded-p process))
      (is (null (proc:process-stdout process)))
      (proc:close-process process))))

;;; --- backpressure reaches the child ------------------------------------------------

(test a-childs-output-can-be-piped-with-backpressure
  ;; PIPE-INTO over subprocess stdio: the whole reason this sub-system depends on
  ;; aion/uv/net rather than reimplementing streams.
  (uv:with-loop (l)
    (let ((sunk (make-array 0 :element-type '(unsigned-byte 8)))
          (finished nil)
          (listener nil) (producer nil))
      (setf listener
            (net:listen-tcp l "127.0.0.1" 0
                            :on-connection
                            (lambda (conn)
                              (net:start-reading
                               conn
                               (collect-into
                                (lambda (d)
                                  (setf sunk (concatenate '(vector (unsigned-byte 8))
                                                          sunk d))))
                               :on-end (lambda (c)
                                         (uv:close-handle c)
                                         (setf finished t))))))
      (multiple-value-bind (host port) (net:listener-address listener)
        ;; A child that produces far more than one read buffer's worth.
        (setf producer (proc:spawn l +shell+ :arguments (shell-args +cmd-produce-400-lines+)))
        (net:connect-tcp
         l host port
         :on-connect (lambda (sink)
                       (net:pipe-into (proc:process-stdout producer) sink
                                      :high-water-mark 4096 :low-water-mark 1024)))
        (is-true (pump l :until (lambda () finished) :limit 20000))
        (is (= (* 400 (+ 50 +eol-width+)) (length sunk)))
        (proc:close-process producer)
        (net:close-listener listener)))))

;;; --- signals -------------------------------------------------------------------------

;;; SIGWINCH throughout, deliberately. libuv restores SIG_DFL when the last handle for a
;;; signal stops, so a test that unwatches and then sends SIGINT or SIGTERM would kill the
;;; test runner rather than assert anything. SIGWINCH's default action is to IGNORE, which
;;; makes it the one signal safe to send at ourselves in either state.

(defmacro skip-on-windows (reason &body body)
  "Run BODY, except on Windows, where the suite records REASON and skips.
A skip is not a pass: fiveam counts it separately, so the report says plainly that this
platform did not check this."
  (declare (ignorable reason))
  #+windows `(progn ,@(and nil body) (skip ,reason))
  #-windows `(progn ,@body))

(test a-signal-handle-delivers-on-the-loop-thread
  (skip-on-windows "no self-signalling on Windows: uv_kill answers ENOSYS for SIGWINCH, and the three signals it does accept (TERM/KILL/INT) are all TerminateProcess -- aimed at ourselves they would end the test run rather than deliver anything"
  (uv:with-loop (l)
    (let ((seen nil)
          (watcher nil))
      (setf watcher (proc:watch-signal l :winch (lambda (name w)
                                                  (declare (ignore w))
                                                  (setf seen name))))
      ;; Signal ourselves; libuv turns it into an ordinary loop callback, which is the
      ;; entire point -- a handler on a real Lisp stack rather than in a signal context.
      (proc:kill-pid (sb-unix:unix-getpid) :winch)
      (is-true (pump l :until (lambda () seen)))
      (is (string= "SIGWINCH" seen))
      (proc:unwatch-signal watcher)))))

(test a-started-signal-handle-holds-the-loop-open
  ;; The classic "why will my process not exit?", and the introspection that answers it.
  (uv:with-loop (l)
    (let ((watcher (proc:watch-signal l :winch (lambda (n w) (declare (ignore n w))))))
      (let* ((handles (uv:loop-handles l))
             (found (find :signal handles :key #'uv:handle-info-kind)))
        (is-true found)
        (is-true (uv:handle-info-referenced found))
        (is (eq 'proc:signal-watcher (type-of (uv:handle-info-owner found)))))
      (proc:unwatch-signal watcher))))

(test unwatching-a-signal-stops-delivery
  (skip-on-windows "no self-signalling on Windows (see a-signal-handle-delivers-on-the-loop-thread): with no way to raise SIGWINCH at ourselves, `nothing was delivered` would hold whether unwatch worked or not"
  (uv:with-loop (l)
    (let ((hits 0))
      (let ((watcher (proc:watch-signal l :winch (lambda (n w) (declare (ignore n w))
                                                   (incf hits)))))
        (proc:unwatch-signal watcher))
      (proc:kill-pid (sb-unix:unix-getpid) :winch)
      (pump l :limit 200)
      (is (zerop hits))))))
