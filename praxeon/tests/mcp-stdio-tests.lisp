;;;; mcp-stdio-tests.lisp --- praxeon/mcp against local servers over stdio (#527, part 5)
;;;;
;;;; Each test starts tests/mcp-stdio-server.lisp as the client's child process, with this
;;;; image's SBCL, so nothing here uses the network. The server appends what it reads, and what
;;;; happens to it, to a record file of the test's own, which the test reads back.
;;;;
;;;; Every signal a test causes goes to that test's own child, through CLOSE-CLIENT, which sends
;;;; it only to the child's process group after checking that the child leads it.

(cl:in-package #:praxeon/mcp/tests)

(in-suite mcp)

(defparameter *stdio-server*
  (asdf:system-relative-pathname :praxeon "tests/mcp-stdio-server.lisp"))

(defun %quicklisp-setup ()
  (namestring (merge-pathnames "setup.lisp"
                               (symbol-value (find-symbol "*QUICKLISP-HOME*" "QL")))))

(defun %fresh-record ()
  "A path no earlier test or run has used."
  (merge-pathnames (format nil "praxeon-mcp-stdio-~36R.log"
                           (random (expt 36 10) (make-random-state t)))
                   (uiop:temporary-directory)))

(defun %passed-through ()
  "Variables the server's SBCL needs to find its core and its compiled jzon, when they are set
here. The fixed set leaves them out, so the tests pass them as an app would. On Windows, ASDF's
default source registry includes the all-users application data folder, which it finds through
ALLUSERSAPPDATA or ALLUSERSPROFILE; without either, the entry is invalid and loading Quicklisp
fails."
  (loop for name in '("SBCL_HOME" "XDG_CACHE_HOME" "ASDF_OUTPUT_TRANSLATIONS"
                      "ALLUSERSAPPDATA" "ALLUSERSPROFILE")
        for value = (sb-ext:posix-getenv name)
        when value collect (cons name value)))

(defun %stdio-connection (mode record &rest keys &key environment &allow-other-keys)
  (apply #'mcp:make-connection
         :name "local"
         :command (list (namestring sb-ext:*runtime-pathname*)
                        "--core" (namestring sb-ext:*core-pathname*)
                        "--script" (namestring *stdio-server*)
                        mode (%quicklisp-setup) (namestring record))
         :environment (if (eq environment :inherit)
                          :inherit
                          (append environment (%passed-through)))
         (loop for (key value) on keys by #'cddr
               unless (eq key :environment) append (list key value))))

(defun %print-server-stderr (mode file)
  "Print FILE, a test server's stderr, to this image's error output, each line marked as the
server's. The gate's summary of a failing suite leads with the first line that holds
\"Unhandled \", so the server's own is written in lower case, and the summary still shows this
image's error."
  (format *error-output* "~&;; the stderr of the ~A test server:~%" mode)
  (dolist (line (ignore-errors (uiop:read-file-lines file)))
    (let ((at (search "Unhandled " line)))
      (format *error-output* ";;   ~A~%"
              (if at (concatenate 'string (subseq line 0 at) "u" (subseq line (1+ at))) line)))))

(defmacro with-stdio-client ((client record mode &rest keys) &body body)
  "Run BODY with CLIENT on a local test server in MODE, recording to RECORD, and close it. Unless
KEYS give :STDERR, the server's stderr goes to a file of the test's own, which is printed when
the server never recorded its start or when BODY does not finish, so a server that dies says why
in the log."
  (let ((stderr (gensym "STDERR"))
        (finished (gensym "FINISHED")))
    `(let* ((,record (%fresh-record))
            (,stderr (%fresh-record))
            (,finished nil)
            (,client (mcp:make-client
                      (%stdio-connection ,mode ,record
                                         ,@(if (loop for key in keys by #'cddr
                                                     thereis (eq key :stderr))
                                               keys
                                               (list* :stderr stderr keys))))))
       (unwind-protect (multiple-value-prog1 (progn ,@body) (setf ,finished t))
         (mcp:close-client ,client)
         (when (and (or (not ,finished) (zerop (%recorded-count ,record "start")))
                    (probe-file ,stderr))
           (%print-server-stderr ,mode ,stderr))
         (ignore-errors (delete-file ,stderr))
         (ignore-errors (delete-file ,record))))))

(defun %recorded (record)
  (if (probe-file record) (uiop:read-file-lines record) '()))

(defun %recorded-count (record prefix)
  (count-if (lambda (line) (uiop:string-prefix-p prefix line)) (%recorded record)))

(defun %received (record)
  "The messages the server read, parsed."
  (loop for line in (%recorded record)
        when (uiop:string-prefix-p "in " line)
          collect (jzon:parse (subseq line 3))))

(defun %received-method (record method)
  (remove-if-not (lambda (m) (equal method (gethash "method" m))) (%received record)))

(defun %wait-for (thunk &optional (seconds 10))
  (loop repeat (* seconds 50)
        until (funcall thunk)
        do (sleep 0.02))
  (funcall thunk))

(defun %tool-named (client name)
  (find name (mcp:list-tools client) :key #'mcp:tool-name :test #'equal))

(defmacro with-captured-log ((stream) &body body)
  "Run BODY with the log at :INFO going to STREAM, then put back the appenders, level and layout
that were there before."
  (let ((appenders (gensym "APPENDERS")) (level (gensym "LEVEL")) (layout (gensym "LAYOUT")))
    `(let ((,appenders (copy-list (log4cl:logger-appenders log4cl:*root-logger*)))
           (,level (log4cl:logger-log-level log4cl:*root-logger*))
           (,layout aion/log:*layout*))
       (unwind-protect
            (progn (aion/log:setup :env :dev :level :info :stream ,stream)
                   ,@body)
         (log4cl:remove-all-appenders log4cl:*root-logger*)
         (dolist (appender ,appenders)
           (log4cl:add-appender log4cl:*root-logger* appender))
         (log4cl:set-log-level log4cl:*root-logger* ,level)
         (setf aion/log:*layout* ,layout)))))

(defun %text (text)
  (let ((h (make-hash-table :test #'equal)))
    (setf (gethash "text" h) text)
    h))

(defun %failure-of (thunk)
  (handler-case (progn (funcall thunk) nil)
    (cnd:tool-error-result (e) e)))

;;; --- connections --------------------------------------------------------------------------

(test make-connection-refuses-what-a-local-server-cannot-use
  "A local server takes its credentials from its environment, so a token source or per-user
tokens are refused with :COMMAND, as are both a URL and a command, a command that is not a list
of strings, and an environment that is neither :INHERIT nor an alist of strings."
  (flet ((refused-p (&rest keys)
           (handler-case (progn (apply #'mcp:make-connection :name "x" keys) nil)
             (error () t))))
    (is-true (refused-p :url "http://127.0.0.1:1/mcp" :command '("server")))
    (is-true (refused-p :command '("server") :token-source (lambda (c p) (declare (ignore c p)) "t")))
    (is-true (refused-p :command '("server") :per-user t))
    (is-true (refused-p :command "server"))
    (is-true (refused-p :command '("server") :environment '(("A" . 1))))
    (is-true (refused-p :url "http://127.0.0.1:1/mcp" :environment '(("A" . "1"))))
    (is-false (refused-p :command '("server") :environment :inherit))
    (is-false (refused-p :command '("server") :environment '(("A" . "1"))))))

(test a-local-server-gets-the-fixed-environment-and-what-the-app-adds
  "Without :INHERIT, the server's environment is +STDIO-ENVIRONMENT+ from this process, then the
app's variables, which win for a name in both."
  (let* ((connection (mcp:make-connection :name "x" :command '("server")
                                          :environment '(("PATH" . "/only/this")
                                                         ("PRAXEON_MCP_TEST" . "yes"))))
         (environment (praxeon/mcp::%child-environment connection))
         (names (mapcar (lambda (entry) (subseq entry 0 (position #\= entry))) environment)))
    (is (equal '("/only/this")
               (loop for entry in environment
                     when (uiop:string-prefix-p "PATH=" entry) collect (subseq entry 5)))
        "PATH was ~S" environment)
    (is (member "PRAXEON_MCP_TEST=yes" environment :test #'equal))
    (is (subsetp names (append mcp:+stdio-environment+ '("PRAXEON_MCP_TEST")) :test #'equal)
        "the environment had ~S" names)
    (is (equal (sb-ext:posix-environ)
               (praxeon/mcp::%child-environment
                (mcp:make-connection :name "x" :command '("server") :environment :inherit))))))

(test the-default-environment-is-the-sdk-s-list-plus-lang-and-tmpdir
  "+STDIO-ENVIRONMENT+ is the MCP TypeScript SDK's DEFAULT_INHERITED_ENV_VARS, and on Linux and
macOS also LANG and TMPDIR (#604). Each of them that is set here, to a value that does not start
with \"()\", is passed to the server."
  (is (equal #+win32 '("APPDATA" "COMSPEC" "HOMEDRIVE" "HOMEPATH" "LOCALAPPDATA" "PATH" "PATHEXT"
                       "PROCESSOR_ARCHITECTURE" "PROGRAMDATA" "PROGRAMFILES" "PROGRAMFILES(X86)"
                       "PROGRAMW6432" "SYSTEMDRIVE" "SYSTEMROOT" "TEMP" "USERNAME" "USERPROFILE"
                       "WINDIR")
             #-win32 '("HOME" "LOGNAME" "PATH" "SHELL" "TERM" "USER" "LANG" "TMPDIR")
             mcp:+stdio-environment+))
  (let ((environment (praxeon/mcp::%child-environment
                      (mcp:make-connection :name "x" :command '("server")))))
    ;; One check, whichever of the variables this host sets, so the count is the same on every
    ;; host.
    (is (null (loop for name in mcp:+stdio-environment+
                    for value = (sb-ext:posix-getenv name)
                    when (and value (not (uiop:string-prefix-p "()" value))
                              (not (member (format nil "~A=~A" name value) environment
                                           :test #'equal)))
                      collect name))
        "the environment was ~S" environment)))

#-win32
(test a-variable-whose-value-is-a-bash-function-is-not-passed
  "A listed variable whose value starts with \"()\" is an exported bash function, and is left
out, as the SDK leaves it out (#604)."
  (let ((before (sb-ext:posix-getenv "TERM")))
    (flet ((setenv (value)
             (sb-alien:alien-funcall
              (sb-alien:extern-alien "setenv" (function sb-alien:int sb-alien:c-string
                                                        sb-alien:c-string sb-alien:int))
              "TERM" value 1)))
      (unwind-protect
           (flet ((term ()
                    (find-if (lambda (entry) (uiop:string-prefix-p "TERM=" entry))
                             (praxeon/mcp::%child-environment
                              (mcp:make-connection :name "x" :command '("server"))))))
             (setenv "() { :; }; echo")
             (is (null (term)) "TERM was passed as ~S" (term))
             (setenv "xterm-praxeon")
             (is (equal "TERM=xterm-praxeon" (term))))
        (if before
            (setenv before)
            (sb-alien:alien-funcall
             (sb-alien:extern-alien "unsetenv" (function sb-alien:int sb-alien:c-string))
             "TERM"))))))

#-win32
(test a-local-server-process-does-not-get-this-process-s-other-variables
  "A variable set in this process reaches the server only with :ENVIRONMENT :INHERIT."
  (flet ((setenv (name value)
           (sb-alien:alien-funcall
            (sb-alien:extern-alien "setenv" (function sb-alien:int sb-alien:c-string
                                                      sb-alien:c-string sb-alien:int))
            name value 1))
         (unsetenv (name)
           (sb-alien:alien-funcall
            (sb-alien:extern-alien "unsetenv" (function sb-alien:int sb-alien:c-string))
            name)))
    (setenv "PRAXEON_MCP_SECRET" "s3cret")
    (unwind-protect
         (progn
           (with-stdio-client (client record "modern"
                                      :environment '(("PRAXEON_MCP_TEST" . "yes")))
             (mcp:list-tools client)
             (is (member "env PRAXEON_MCP_SECRET=none PRAXEON_MCP_TEST=yes" (%recorded record)
                         :test #'equal)
                 "the server recorded ~S" (%recorded record)))
           (with-stdio-client (client record "modern" :environment :inherit)
             (mcp:list-tools client)
             (is (member "env PRAXEON_MCP_SECRET=s3cret PRAXEON_MCP_TEST=none" (%recorded record)
                         :test #'equal)
                 "the server recorded ~S" (%recorded record))))
      (unsetenv "PRAXEON_MCP_SECRET"))))

;;; --- eras ---------------------------------------------------------------------------------

(test a-local-server-on-the-current-revision-gives-its-tools
  "The client probes with server/discover, then sends each request with its version in _meta.
tools/list follows the server's pages, and a tool's arguments keep a newline inside one line."
  (with-stdio-client (client record "modern")
    (let ((tools (mcp:list-tools client)))
      (is (equal '("echo" "fail" "slow" "slow-a" "exit") (mapcar #'mcp:tool-name tools)))
      (is (eq :modern (mcp:client-era client)))
      (is (= 3 (length (%received-method record "tools/list"))) "three pages were not read")
      (is (equal (format nil "one~%two")
                 (mcp:call-tool client (find "echo" tools :key #'mcp:tool-name :test #'equal)
                                (let ((h (make-hash-table :test #'equal)))
                                  (setf (gethash "text" h) (format nil "one~%two"))
                                  h))))
      (let ((received (%received record)))
        (is (equal "server/discover" (gethash "method" (first received))))
        (is (null (%received-method record "initialize")))))))

(test a-legacy-local-server-is-found-when-it-refuses-discover
  "A server that answers server/discover with an error that is not the current revision's gets
the initialize handshake."
  (with-stdio-client (client record "legacy")
    (is (= 5 (length (mcp:list-tools client))))
    (is (eq :legacy (mcp:client-era client)))
    (is (equal "2025-11-25" (mcp:client-protocol-version client)))
    (is (= 1 (length (%received-method record "initialize"))))
    (is (= 1 (length (%received-method record "notifications/initialized"))))))

(test a-legacy-local-server-is-found-whatever-error-it-gives-discover
  "The fallback is not keyed to -32601: a server that answers server/discover with -32600 gets
the initialize handshake too."
  (with-stdio-client (client record "legacy-invalid")
    (is (= 5 (length (mcp:list-tools client))))
    (is (eq :legacy (mcp:client-era client)))
    (is (= 1 (length (%received-method record "initialize"))))))

(test a-legacy-local-server-that-does-not-answer-initialize-gets-no-other-request
  "A handshake that fails leaves the server without an era, so the next request starts it again
and does the handshake again, rather than sending to a server that was never initialized."
  (with-stdio-client (client record "legacy-no-init" :timeout 2)
    (is-true (%failure-of (lambda () (mcp:list-tools client))))
    (is-true (%failure-of (lambda () (mcp:list-tools client))))
    (is (= 2 (%recorded-count record "start")))
    (is (= 2 (length (%received-method record "initialize"))))
    (is (null (%received-method record "tools/list")))))

(test a-local-server-whose-handshake-fails-is-stopped-at-once
  "With :RESTART NIL, a server whose handshake failed is not started again, so it is stopped when
the handshake fails rather than left running until CLOSE-CLIENT."
  (with-stdio-client (client record "legacy-no-init" :timeout 2 :restart nil)
    (is-true (%failure-of (lambda () (mcp:list-tools client))))
    (let ((process (praxeon/mcp::child-process (praxeon/mcp::client-child client))))
      (is-false (sb-ext:process-alive-p process)))
    (is (= 1 (%recorded-count record "eof")))
    (let ((e (%failure-of (lambda () (mcp:list-tools client)))))
      (is (eq :not-run (and e (cnd:tool-error-result-outcome e)))))
    (is (= 1 (%recorded-count record "start")))))

(test a-replaced-server-whose-handshake-fails-leaves-the-client-without-an-era
  "CLIENT-ERA and CLIENT-PROTOCOL-VERSION describe the server that is running. When a server exits
and the one started in its place turns out to be unsupported, both are NIL, not the first
server's values (#610)."
  (with-stdio-client (client record "modern-then-unsupported")
    (is (= 5 (length (mcp:list-tools client))))
    (is (eq :modern (mcp:client-era client)))
    (is-true (%failure-of (lambda () (mcp:call-tool client (%tool-named client "exit") nil))))
    (let ((e (%failure-of (lambda () (mcp:list-tools client)))))
      (is (eq :not-run (and e (cnd:tool-error-result-outcome e)))))
    (is (= 2 (%recorded-count record "start")))
    (is (null (mcp:client-era client)))
    (is (null (mcp:client-protocol-version client)))))

(test a-legacy-local-server-is-found-when-it-does-not-answer-discover
  "No answer to server/discover within the connection's timeout also means a legacy server."
  (with-stdio-client (client record "legacy-silent" :timeout 5)
    (is (= 5 (length (mcp:list-tools client))))
    (is (eq :legacy (mcp:client-era client)))))

(test a-local-server-without-the-current-revision-is-refused
  "A current-era server that does not support 2026-07-28 fails the request as not run, naming
what it supports, and gets no initialize."
  (with-stdio-client (client record "unsupported")
    (let ((e (%failure-of (lambda () (mcp:list-tools client)))))
      (is-true e)
      (is (eq :not-run (and e (cnd:tool-error-result-outcome e))))
      (is-true (and e (search "2099-01-01" (cnd:tool-error-result-text e)))))
    (is (null (%received-method record "initialize")))))

(test a-local-server-whose-versions-leave-out-the-current-revision-is-refused
  "A DiscoverResult whose supportedVersions does not list 2026-07-28 fails the request as not
run, naming what the server supports, and the server gets no other request."
  (with-stdio-client (client record "unsupported-list")
    (let ((e (%failure-of (lambda () (mcp:list-tools client)))))
      (is (eq :not-run (and e (cnd:tool-error-result-outcome e))))
      (is-true (and e (search "2099-01-01" (cnd:tool-error-result-text e)))))
    (is (null (%received-method record "initialize")))
    (is (null (%received-method record "tools/list")))))

(test a-discover-result-without-supported-versions-is-not-taken-for-a-legacy-server
  "Any DiscoverResult means the current era, so one with no supportedVersions is refused as
unsupported, and the server gets no initialize."
  (with-stdio-client (client record "no-versions")
    (let ((e (%failure-of (lambda () (mcp:list-tools client)))))
      (is (eq :not-run (and e (cnd:tool-error-result-outcome e)))))
    (is (null (%received-method record "initialize")))))

(test a-legacy-local-server-gets-an-answer-to-its-ping
  "A legacy server may ping the client, which answers with an empty result."
  (with-stdio-client (client record "ping")
    (is (= 5 (length (mcp:list-tools client))))
    (is (= 1 (%recorded-count record "pong")))
    (let ((answer (find "server-ping" (%received record)
                        :key (lambda (m) (gethash "id" m)) :test #'equal)))
      (is (and answer (hash-table-p (gethash "result" answer))
               (zerop (hash-table-count (gethash "result" answer))))))))

;;; --- calls --------------------------------------------------------------------------------

(test a-tool-error-from-a-local-server-is-a-tool-error
  (with-stdio-client (client record "modern")
    (signals mcp:tool-error (mcp:call-tool client (%tool-named client "fail") nil))))

(test concurrent-calls-to-a-local-server-get-their-own-replies
  "Replies share one stdout and come back in the order the server finishes: the slow call is
answered after the fast one, and each caller gets its own."
  (with-stdio-client (client record "modern")
    (let* ((slow (%tool-named client "slow-a"))
           (echo (%tool-named client "echo"))
           (lock (sb-thread:make-mutex :name "finished"))
           (finished '())
           (slow-result nil)
           (thread (sb-thread:make-thread
                    ;; THREAD-LIFETIME: scoped -- one call for this test, joined below.
                    (lambda ()
                      (setf slow-result (mcp:call-tool client slow nil))
                      (sb-thread:with-mutex (lock) (push :slow finished))))))
      ;; The slow call is sent first.
      (is-true (%wait-for (lambda () (%received-method record "tools/call"))))
      (let ((echo-result (mcp:call-tool client echo (%text "fast"))))
        (sb-thread:with-mutex (lock) (push :fast finished))
        (sb-thread:join-thread thread :default nil :timeout 10)
        (is (equal "fast" echo-result))
        (is (equal "a" slow-result))
        (is (equal '(:fast :slow) (reverse finished)))
        (is (equal '("slow-a" "echo")
                   (mapcar (lambda (m) (gethash "name" (gethash "params" m)))
                           (%received-method record "tools/call"))))))))

(test a-local-server-that-does-not-answer-gets-a-cancellation
  "A call past its deadline fails with an unknown outcome, and the client sends
notifications/cancelled with the call's id. The server stays up for the next call."
  (with-stdio-client (client record "modern" :call-timeout 2)
    (let ((e (%failure-of (lambda () (mcp:call-tool client (%tool-named client "slow") nil)))))
      (is-true e)
      (is (eq :unknown (and e (cnd:tool-error-result-outcome e)))))
    (is-true (%wait-for (lambda () (%received-method record "notifications/cancelled"))))
    (let ((call (first (%received-method record "tools/call")))
          (cancel (first (%received-method record "notifications/cancelled"))))
      (is (and call cancel
               (equal (gethash "id" call) (gethash "requestId" (gethash "params" cancel))))))
    (is (equal "after" (mcp:call-tool client (%tool-named client "echo")
                                      (let ((h (make-hash-table :test #'equal)))
                                        (setf (gethash "text" h) "after")
                                        h))))))

(test a-request-that-times-out-before-it-is-written-is-never-sent
  "A server that stops reading its stdin leaves requests queued. One whose deadline passes in the
queue fails as not run, and is not sent once the server reads again, so an app that retries it
does not run it twice."
  (with-stdio-client (client record "stall" :call-timeout 3)
    (let* ((tools (mcp:list-tools client))
           (stall (find "stall" tools :key #'mcp:tool-name :test #'equal))
           (echo (find "echo" tools :key #'mcp:tool-name :test #'equal))
           (threads '()))
      (push (sb-thread:make-thread
             ;; THREAD-LIFETIME: scoped -- one call for this test, joined below.
             (lambda () (%failure-of (lambda () (mcp:call-tool client stall nil)))))
            threads)
      ;; The server reads nothing for 5 seconds from here.
      (is-true (%wait-for (lambda () (%received-method record "tools/call"))))
      ;; A line longer than any pipe's buffer, so the writer is held inside it.
      (push (sb-thread:make-thread
             ;; THREAD-LIFETIME: scoped -- one call for this test, joined below.
             (lambda ()
               (%failure-of (lambda ()
                              (mcp:call-tool client echo
                                             (%text (make-string (* 1024 1024)
                                                                 :initial-element #\b)))))))
            threads)
      (sleep 0.5)
      (let ((e (%failure-of (lambda () (mcp:call-tool client echo (%text "never-sent"))))))
        (is (eq :not-run (and e (cnd:tool-error-result-outcome e)))))
      (dolist (thread threads) (sb-thread:join-thread thread :default nil :timeout 15))
      ;; Both earlier calls timed out after they were written, so each gets a cancellation,
      ;; queued after the line that was not sent.
      (is-true (%wait-for (lambda ()
                            (= 2 (length (%received-method record "notifications/cancelled"))))
                          15))
      (is (= 2 (length (%received-method record "tools/call"))))
      (is (notany (lambda (line) (search "never-sent" line)) (%recorded record))))))

(test lines-a-local-server-should-not-write-are-dropped
  "A line that is not JSON, a line over MAX-BODY-BYTES, and a byte that is not UTF-8 neither end
the reader nor fail the call, and the dropped lines are counted in the log by reason."
  (let ((log (make-string-output-stream)))
    (with-captured-log (log)
      (with-stdio-client (client record "garbage" :max-body-bytes 4096)
        (is (equal "kept" (mcp:call-tool client (%tool-named client "echo") (%text "kept"))))))
    (let ((logged (get-output-stream-string log)))
      (is-true (search "not-json=1" logged) "the log said ~S" logged)
      ;; The line of 10000 characters, the one of 1500 characters in 4500 octets, and the one
      ;; of 4500 octets of malformed UTF-8 that decodes to fewer octets' worth (#610).
      (is-true (search "too-long=3" logged) "the log said ~S" logged))))

(test a-local-server-s-stderr-is-discarded-or-written-to-its-file-and-never-logged
  "The server writes to stderr on every request. That neither fails a call nor reaches the log;
with :STDERR it is appended to the app's file."
  (let ((log (make-string-output-stream))
        (stderr (%fresh-record)))
    (with-captured-log (log)
      (with-stdio-client (client record "modern" :stderr nil)
        (is (= 5 (length (mcp:list-tools client)))))
      (with-stdio-client (client record "modern" :stderr stderr)
        (is (= 5 (length (mcp:list-tools client))))))
    (let ((logged (get-output-stream-string log)))
      (is-true (search "local server started" logged) "nothing was logged: ~S" logged)
      (is-false (search "stderr:" logged)))
    (is-true (some (lambda (line) (uiop:string-prefix-p "stderr: a request for" line))
                   (%recorded stderr)))
    (ignore-errors (delete-file stderr))))

;;; --- exits, restarts and closing ----------------------------------------------------------

(test a-local-server-that-exits-is-started-again
  "A server that exits during a call fails that call with an unknown outcome. With :RESTART T,
the default, the next request starts it again and finds its era again."
  (with-stdio-client (client record "modern")
    (let ((e (%failure-of (lambda () (mcp:call-tool client (%tool-named client "exit") nil)))))
      (is (eq :unknown (and e (cnd:tool-error-result-outcome e)))))
    (is (= 5 (length (mcp:list-tools client))))
    (is (= 2 (%recorded-count record "start")))
    (is (= 2 (length (%received-method record "server/discover"))))))

#-win32
(test a-local-server-that-exits-while-its-stdout-stays-open-is-started-again
  "A server can exit while a process it started still holds its stdout, so its output does not
end. The next request sees that the process has exited and starts the server again. The old
reader ends on its own once the other process exits. That process, /bin/sleep 6, is not
signalled by anything here, and can outlive the test by up to 6 seconds."
  (with-stdio-client (client record "orphan" :call-timeout 2)
    (let* ((tool (%tool-named client "exit-leaving-child"))
           (reader (praxeon/mcp::child-reader (praxeon/mcp::client-child client)))
           (e (%failure-of (lambda () (mcp:call-tool client tool nil)))))
      (is (eq :unknown (and e (cnd:tool-error-result-outcome e))))
      (is (= 6 (length (mcp:list-tools client))))
      (is (= 2 (%recorded-count record "start")))
      (is-true (%wait-for (lambda () (not (sb-thread:thread-alive-p reader))) 15)))))

#-win32
(test a-write-blocked-on-an-exited-server-is-ended-and-its-pipes-closed
  "A server exits while a process it started holds its stdin and reads nothing, and a long
request is still being written to it. When the client finishes that server, it ends the
blocked writer thread, so the pipes are closed once, right then, and are not kept until the
image exits (#601). The server started next gets only whole JSON lines. The shell holding the
old stdin is not signalled, and can outlive the test by up to 6 seconds. The test checks that
the old server was finished less than 5 seconds after the exit call, before that shell reads its
stdin; on a run slower than that the writer could finish by itself, and the test fails instead
of passing without having ended it."
  (with-stdio-client (client record "hold-stdin" :timeout 3 :call-timeout 1)
    (let* ((exit-tool (%tool-named client "exit-holding-stdin"))
           (echo (%tool-named client "echo"))
           (old (praxeon/mcp::client-child client))
           (in (sb-ext:process-input (praxeon/mcp::child-process old)))
           ;; Before the exit call is made, so the time measured below is not less than the
           ;; time the shell has been sleeping, however this thread is scheduled (#628).
           (started (get-internal-real-time))
           (exiting (sb-thread:make-thread
                     ;; THREAD-LIFETIME: scoped -- one call for this test, joined below.
                     (lambda () (%failure-of (lambda () (mcp:call-tool client exit-tool nil))))
                     :name "praxeon/mcp test exit-holding-stdin")))
      ;; The server has read the exit call, and reads nothing more from here.
      (is-true (%wait-for (lambda () (%received-method record "tools/call"))))
      ;; About 1 MB, far more than a pipe holds, so the writer blocks. :UNKNOWN means the
      ;; writer took the request; :NOT-RUN would mean it never did, and nothing would block.
      (let ((e (%failure-of (lambda ()
                              (mcp:call-tool client echo
                                             (%text (make-string 1000000
                                                                 :initial-element #\x)))))))
        (is (eq :unknown (and e (cnd:tool-error-result-outcome e)))))
      (is-true (aion/test-threads:join exiting))
      ;; Both calls can time out before the server exits, so wait until its output has ended.
      (is-true (%wait-for (lambda () (praxeon/mcp::child-exited old))))
      ;; This finishes the old server, then starts the next one. The shell has not read yet.
      (is (equal "after" (mcp:call-tool client echo (%text "after"))))
      ;; The shell reads its stdin 6 seconds after it starts, and the writer would then finish
      ;; without being ended. Under 5 seconds, the checks below are about the ending.
      (let ((seconds (/ (- (get-internal-real-time) started) internal-time-units-per-second)))
        (is (< seconds 5) "the old server was finished ~,1F seconds after the exit call" seconds))
      (is-false (sb-thread:thread-alive-p (praxeon/mcp::child-writer old)))
      (is-false (open-stream-p in))
      (is (= 1 (praxeon/mcp::child-closes old)))
      (is (equal "later" (mcp:call-tool client echo (%text "later"))))
      (is (= 2 (%recorded-count record "start")))
      (let* ((lines (%recorded record))
             (after (rest (member "start" (rest (member "start" lines :test #'equal))
                                  :test #'equal)))
             (bad (loop for line in after
                        when (and (uiop:string-prefix-p "in " line)
                                  (not (hash-table-p (ignore-errors
                                                      (jzon:parse (subseq line 3))))))
                          collect (subseq line 0 (min 60 (length line))))))
        (is (null bad) "the second server read ~S" bad)))))

#-win32
(test ending-a-blocked-writer-closes-the-server-s-stdin
  "A server exits while a process it started holds both its stdin and its stdout, reads nothing
for 6 seconds, and then reads stdin until its end, and a long request is still being written.
The client ends the blocked writer, and ending it closes the server's stdin, so the holder
reads to the end and exits, the reader reaches the end of stdout, and the pipes are closed
once (#628). The holder is not signalled. It exits about 6 seconds after it starts, and the
test waits for that, so it leaves no process running. CONTROL: without the close, the holder
waits for the end of stdin until a read takes 20 seconds, the reader is still running when
the test has waited 15 seconds for it, and the last two checks fail."
  (with-stdio-client (client record "hold-both" :timeout 3 :call-timeout 1)
    (let* ((exit-tool (%tool-named client "exit-holding-both"))
           (echo (%tool-named client "echo"))
           (old (praxeon/mcp::client-child client))
           (reader (praxeon/mcp::child-reader old))
           (exiting (sb-thread:make-thread
                     ;; THREAD-LIFETIME: scoped -- one call for this test, joined below.
                     (lambda () (%failure-of (lambda () (mcp:call-tool client exit-tool nil))))
                     :name "praxeon/mcp test exit-holding-both")))
      (is-true (%wait-for (lambda () (%received-method record "tools/call"))))
      ;; About 1 MB, so the writer blocks, as in the test above.
      (let ((e (%failure-of (lambda ()
                              (mcp:call-tool client echo
                                             (%text (make-string 1000000
                                                                 :initial-element #\x)))))))
        (is (eq :unknown (and e (cnd:tool-error-result-outcome e)))))
      (is-true (aion/test-threads:join exiting))
      ;; Its output does not end while the holder has it, so wait for the process instead.
      (is-true (%wait-for (lambda ()
                            (not (sb-ext:process-alive-p (praxeon/mcp::child-process old))))))
      ;; Finishes the old server, which ends the blocked writer, and starts the next one.
      (is (equal "after" (mcp:call-tool client echo (%text "after"))))
      (is-false (sb-thread:thread-alive-p (praxeon/mcp::child-writer old)))
      (is-true (%wait-for (lambda () (not (sb-thread:thread-alive-p reader))) 15))
      (is (= 1 (praxeon/mcp::child-closes old))))))

(test with-restart-nil-a-local-server-that-exits-stays-down
  "With :RESTART NIL, every request after the server exits fails as not run, and nothing is
started again. The client then has no era, since no server is running (#610)."
  (with-stdio-client (client record "modern" :restart nil)
    (%failure-of (lambda () (mcp:call-tool client (%tool-named client "exit") nil)))
    (dotimes (i 2)
      (let ((e (%failure-of (lambda () (mcp:list-tools client)))))
        (is (eq :not-run (and e (cnd:tool-error-result-outcome e))))))
    (is (= 1 (%recorded-count record "start")))
    (is (null (mcp:client-era client)))
    (is (null (mcp:client-protocol-version client)))))

(test a-local-server-that-keeps-exiting-is-not-started-a-fifth-time-in-a-minute
  "The first start and three restarts happen; the fifth request fails as not run without
starting anything."
  (with-stdio-client (client record "crash")
    (let ((failures (loop repeat 5 collect (%failure-of (lambda () (mcp:list-tools client))))))
      (is (every #'identity failures))
      (is (eq :not-run (cnd:tool-error-result-outcome (fifth failures))))
      (is-true (search "exited 4 times" (cnd:tool-error-result-text (fifth failures)))
               "the fifth failure said ~A" (cnd:tool-error-result-text (fifth failures))))
    (is (= 4 (%recorded-count record "start")))))

(test closing-a-client-closes-the-server-s-stdin-and-it-exits
  "A server that exits when its stdin ends is never signalled, and a request after closing fails
as not run."
  (with-stdio-client (client record "modern")
    (mcp:list-tools client)
    (let ((process (praxeon/mcp::child-process (praxeon/mcp::client-child client))))
      (mcp:close-client client)
      (is-false (sb-ext:process-alive-p process))
      (is (eql 0 (sb-ext:process-exit-code process))))
    (is (= 1 (%recorded-count record "eof")))
    (is (= 0 (%recorded-count record "SIGTERM")))
    (let ((e (%failure-of (lambda () (mcp:list-tools client)))))
      (is (eq :not-run (and e (cnd:tool-error-result-outcome e)))))))

(test after-close-client-the-client-has-no-era
  "CLIENT-ERA and CLIENT-PROTOCOL-VERSION describe the server that is running, so after
CLOSE-CLIENT both are NIL (#601)."
  (with-stdio-client (client record "modern")
    (mcp:list-tools client)
    (is (eq :modern (mcp:client-era client)))
    (mcp:close-client client)
    (is (null (mcp:client-era client)))
    (is (null (mcp:client-protocol-version client)))))

(test a-local-server-that-ignores-its-closed-stdin-is-ended
  "A server still running *STDIO-CLOSE-SECONDS* after its stdin closed is sent SIGTERM, to its
own process group, which the client checks it leads first; on Windows it is ended with
TerminateProcess."
  (let ((mcp:*stdio-close-seconds* 1))
    (with-stdio-client (client record "ignore-eof")
      (mcp:list-tools client)
      (let* ((process (praxeon/mcp::child-process (praxeon/mcp::client-child client)))
             (pid (sb-ext:process-pid process)))
        #-win32 (is (eql pid (praxeon/mcp::%getpgid pid))
                    "the server does not lead its own process group")
        (mcp:close-client client)
        (is-false (sb-ext:process-alive-p process))
        (is (= 1 (%recorded-count record "eof")))
        #-win32 (is (= 1 (%recorded-count record "SIGTERM")))))))

#-win32
(test a-local-server-that-ignores-sigterm-is-killed
  "A server still running *STDIO-TERM-SECONDS* after SIGTERM is sent SIGKILL, to its own process
group, which the client checks it leads first."
  (let ((mcp:*stdio-close-seconds* 0.5)
        (mcp:*stdio-term-seconds* 0.5))
    (with-stdio-client (client record "ignore-term")
      (mcp:list-tools client)
      (let* ((process (praxeon/mcp::child-process (praxeon/mcp::client-child client)))
             (pid (sb-ext:process-pid process)))
        (is (eql pid (praxeon/mcp::%getpgid pid)) "the server does not lead its own process group")
        (mcp:close-client client)
        (is-false (sb-ext:process-alive-p process))
        (is (= 1 (%recorded-count record "SIGTERM")))
        (is (eq :signaled (sb-ext:process-status process)))
        (is (eql 9 (sb-ext:process-exit-code process)))))))
