;;;; claude-code-tests.lisp --- praxeon/claude-code: the report, the rules, the summary check and the hook (#452).
;;;;
;;;; NOTHING HERE CALLS A MODEL. The summarizer is a stub behind the backend protocol, and the
;;;; claude CLI backend is exercised through a stand-in program, for its timeout. The events are
;;;; the ones Claude Code 2.1.270 sent a capturing hook on 2026-09-30, kept under
;;;; tests/fixtures/claude-code/ with their paths replaced by neutral ones.

(cl:defpackage #:praxeon/claude-code/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:rules #:praxeon/claude-code/rules)
                    (#:tr #:praxeon/claude-code/transcript)
                    (#:report #:praxeon/claude-code/report)
                    (#:hook #:praxeon/claude-code/hook)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:run-tests))

(in-package #:praxeon/claude-code/tests)

(def-suite claude-code :description "praxeon/claude-code (#452).")
(in-suite claude-code)

(defun run-tests () (run! 'claude-code))

;;; --- fixtures ----------------------------------------------------------------------------

(defun fixture (name)
  (uiop:read-file-string
   (asdf:system-relative-pathname :praxeon (format nil "tests/fixtures/claude-code/~A" name))))

(defun %big (&optional (lines 600) (prefix "src/module.lisp"))
  "Search output over the threshold with no SHA-like token: LINES lines of path:line:text."
  (with-output-to-string (s)
    (loop for i from 1 to lines
          do (format s "~A:~D:(defun handle-request (request) (route request :handler))~%" prefix i))))

(defun %bash-event (stdout &key (command "rg -n handle src") (stderr "") (interrupted nil))
  "The recorded Bash event with its command and output replaced: the shape Claude Code sent,
with a large output in it."
  (let ((e (jzon:parse (fixture "bash-event.json"))))
    (setf (gethash "command" (gethash "tool_input" e)) command
          (gethash "stdout" (gethash "tool_response" e)) stdout
          (gethash "stderr" (gethash "tool_response" e)) stderr
          (gethash "interrupted" (gethash "tool_response" e)) interrupted)
    (jzon:stringify e)))

(defun %input (command)
  (let ((h (make-hash-table :test #'equal))) (setf (gethash "command" h) command) h))

(defun %eligibility (command text &rest keys)
  (apply #'rules:eligibility "Bash" (%input command) text keys))

(defun %temporary-directory ()
  (let ((d (uiop:ensure-directory-pathname
            (merge-pathnames (format nil "praxeon-cc-test-~36R/" (random (expt 2 40) (make-random-state t)))
                             (uiop:temporary-directory)))))
    (ensure-directories-exist d)
    d))

(defmacro with-directory ((var) &body body)
  `(let ((,var (%temporary-directory)))
     (unwind-protect (progn ,@body)
       (aion/fs:delete-tree ,var :if-does-not-exist :ignore))))

;;; --- categories -------------------------------------------------------------------------

(test a-bash-command-is-counted-under-the-word-that-does-the-work
  (is (string= "rg" (rules:bash-category "rg -n foo src")))
  (is (string= "rg" (rules:bash-category "cd src && rg foo")) "a cd first is skipped")
  (is (string= "make" (rules:bash-category "FOO=1 make all")) "and a variable assignment")
  (is (string= "rg" (rules:bash-category "timeout 60 rg foo")) "and a wrapper with its argument")
  (is (string= "rg" (rules:bash-category "/usr/bin/rg foo")) "a path is reduced to its name")
  (is (string= "Bash:grep" (rules:tool-category "Bash" (%input "grep -r x ."))))
  (is (string= "mcp__cap__lookup" (rules:tool-category "mcp__cap__lookup" nil))))

;;; --- the never-compress rules, each with its control ----------------------------------------

(test a-large-search-output-is-eligible
  "The control for every rule below: the same large output from a search is replaced."
  (is (eq :replace (%eligibility "rg -n handle src" (%big))))
  (is (eq :replace (rules:eligibility "mcp__cap__lookup" nil (%big))) "and from an MCP tool"))

(test an-output-under-the-threshold-is-passed-through
  (is (equal '(:pass :small) (multiple-value-list (%eligibility "rg x" (%big 10)))))
  (let ((rules:*threshold-tokens* 10))
    (is (eq :replace (%eligibility "rg x" (%big 10))) "control: over a lower threshold it is not")))

(test only-search-commands-and-mcp-tools-are-eligible
  (dolist (command '("cat src/a.lisp" "sed -n 1,400p src/a.lisp" "git log --oneline" "gh run view 1 --log"
                     "ls -R" "python3 script.py"))
    (is (equal '(:pass :not-search) (multiple-value-list (%eligibility command (%big))))
        "~A is not a search" command))
  (is (equal '(:pass :exact) (multiple-value-list (%eligibility "rg x | head -50" (%big))))
      "a search already narrowed by head is read exactly")
  (is (equal '(:pass :not-search) (multiple-value-list (%eligibility "git log | grep fix" (%big))))
      "a pipeline is decided by its first command")
  (dolist (tool '("Read" "Grep" "Edit" "ToolSearch"))
    (is (equal '(:pass :tool) (multiple-value-list (rules:eligibility tool nil (%big))))
        "~A is not eligible" tool)))

(test a-failed-interrupted-or-stderr-output-is-passed-through
  (is (equal '(:pass :failed) (multiple-value-list (%eligibility "rg x" (%big) :error-p t))))
  (is (equal '(:pass :failed) (multiple-value-list (%eligibility "rg x" (%big) :interrupted t))))
  (is (equal '(:pass :failed) (multiple-value-list (%eligibility "rg x" (%big) :stderr "rg: denied"))))
  (is (eq :replace (%eligibility "rg x" (%big) :stderr "")) "control: an empty stderr is no failure"))

(test a-diff-is-passed-through
  (let ((diff (concatenate 'string (%big) (format nil "diff --git a/x b/x~%@@ -1 +1 @@~%"))))
    (is (equal '(:pass :diff) (multiple-value-list (%eligibility "rg x" diff))))))

(test credential-shaped-text-is-passed-through
  (dolist (marker '("ghp_abcdefghijklmnopqrstuvwxyz0123" "-----BEGIN OPENSSH PRIVATE KEY-----"
                    "Authorization: Bearer abc" "password=hunter2" "AKIAIOSFODNN7EXAMPLE"))
    (is (equal '(:pass :credential)
               (multiple-value-list (%eligibility "rg x" (concatenate 'string (%big) marker))))
        "~A" marker)))

(test output-carrying-a-sha-or-a-run-id-is-passed-through
  "The gate's output, CI logs and git log carry commit SHAs and run ids, which AGENTS.md
requires to be read from the raw output. A search over a saved log is refused for the same
reason, whatever the command. Controls: a word of hex letters only, and a short number, are not
identifiers."
  (is (equal '(:pass :identifiers)
             (multiple-value-list
              (%eligibility "rg total verify.log"
                            (concatenate 'string (%big) "gate: host=linux total=8218 commit=a2fd02c")))))
  (is (equal '(:pass :identifiers)
             (multiple-value-list
              (%eligibility "grep -r run logs/"
                            (concatenate 'string (%big) "run 36728183867 attempt 2")))))
  (is (eq :replace (%eligibility "rg x" (concatenate 'string (%big) "deadbeef facade 12345"))))
  (is (rules:identifier-like-p "merged at 4ce06e61dda3f0b2f5b89309bdcc78683c270910"))
  (is-false (rules:identifier-like-p "a cafe and a decade, 2026")))

;;; --- the summary check -------------------------------------------------------------------------

(defparameter +raw+
  (concatenate 'string
               "src/server.lisp:120:(defun %write-response (conn status) ...)
src/server.lisp:337:(defun %stream-response (conn body) ...)
src/http.lisp:55:(defun %read-bounded (stream limit) ...)
" (%big 300 "src/other.lisp")))

(test the-summary-check-refuses-a-path-that-is-not-in-the-output
  "The case a schema check cannot catch: a well-formed summary naming a file that the output
never mentions. Control: the same summary is accepted once that path is in the output."
  (let ((summary "- src/server.lisp:120 defines %write-response; src/router.lisp:42 defines %dispatch"))
    (multiple-value-bind (ok why missing) (hook:check-summary summary +raw+)
      (is-false ok)
      (is (eq :unsupported why))
      (is (member "src/router.lisp" missing :test #'string=)))
    (let ((raw (concatenate 'string +raw+ "src/router.lisp:42:(defun %dispatch (r) ...)")))
      (is (eq t (hook:check-summary summary raw))))))

(defparameter +small-raw+
  "src/server.lisp:120:(defun %write-response (conn status) ...)
src/http.lisp:55:(defun %read-bounded (stream limit) ...)
"
  "Output with only two numbers in it, so a wrong number cannot be found elsewhere by chance.")

(test the-summary-check-refuses-a-directory-that-is-not-in-the-output
  "A path with no dot and no underscore is caught only by the path test, not by the identifier
test, so this is the case that shows the path test is there. Control: a directory the output
does mention."
  (is (equal '("hyperion/lib") (hook:unsupported-tokens "- the helpers live in hyperion/lib" +small-raw+)))
  (is (null (hook:unsupported-tokens "- the helpers live in src/http" +small-raw+))
      "control: src/http occurs in src/http.lisp"))

(test the-summary-check-refuses-a-number-or-identifier-that-is-not-in-the-output
  "A NUMBER IS CHECKED FOR OCCURRENCE, NOT FOR ITS PAIRING with the path beside it: 56 is refused
here because the output has no 56 anywhere, and would be accepted in output that has one on
another line. These use UNSUPPORTED-TOKENS on a two-line output for that reason."
  (is (equal '("56") (hook:unsupported-tokens "- src/http.lisp:56 defines %read-bounded" +small-raw+))
      "a line number off by one")
  (is (null (hook:unsupported-tokens "- src/http.lisp:55 defines %read-bounded" +small-raw+)) "control")
  (is (equal '("3") (hook:unsupported-tokens "- there are 3 definitions" +small-raw+))
      "a count the output does not contain")
  (is (eq :unsupported (nth-value 1 (hook:check-summary "- %read_bounded is in src/http.lisp" +raw+)))
      "an identifier spelled another way")
  (is (eq :unsupported (nth-value 1 (hook:check-summary "- fixed in 4ce06e6" +raw+)))
      "a hex identifier")
  (is (eq :unsupported (nth-value 1 (hook:check-summary "- src/handler_N.lisp has one each" +raw+)))
      "a placeholder path")
  )

(test the-summary-check-reads-prose-as-prose
  "Abbreviations, possessives, Markdown backticks and name:line pairs do not make a token
unsupported when its parts are in the output."
  (is (eq t (hook:check-summary "- e.g. src/http.lisp:55, i.e. %read-bounded's limit" +raw+)))
  (is (eq t (hook:check-summary "- `%stream-response` is at src/server.lisp:337" +raw+)))
  (is (eq t (hook:check-summary "- %write-response:120 and %stream-response:337" +raw+))))

(test the-summary-check-refuses-a-summary-too-large-or-too-little-smaller
  (is (eq :empty (nth-value 1 (hook:check-summary "   " +raw+))))
  (is (eq :over-budget (nth-value 1 (hook:check-summary (%big 300 "src/other.lisp") +raw+ :budget 100))))
  (is (eq :too-little-smaller
          (nth-value 1 (hook:check-summary (%big 290 "src/other.lisp") (%big 300 "src/other.lisp")
                                           :budget 100000)))
      "a summary 3% smaller than the output saves nothing worth the risk"))

;;; --- the events and the replacement, from the recorded events ----------------------------------

(test the-recorded-bash-event-parses-and-its-replacement-keeps-the-tools-shape
  "Claude Code ignored a Bash replacement given as a string and applied one given as the tool's
own object, so the replacement is that object."
  (let ((e (hook:parse-event (fixture "bash-event.json"))))
    (is (eq :bash (hook:event-shape e)))
    (is (string= "Bash" (hook:event-tool e)))
    (is (search "data/notes.txt:1:line 1" (hook:event-text e)))
    (is (equal '(:pass :small) (multiple-value-list (hook:event-eligibility e))))
    (let* ((out (jzon:parse (hook:hook-output e "SUMMARY")))
           (specific (gethash "hookSpecificOutput" out))
           (updated (gethash "updatedToolOutput" specific)))
      (is (string= "PostToolUse" (gethash "hookEventName" specific)))
      (is (hash-table-p updated))
      (is (string= "SUMMARY" (gethash "stdout" updated)))
      (is (string= "" (gethash "stderr" updated)))
      (is (eq nil (gethash "interrupted" updated)))
      (is (eq nil (gethash "isImage" updated))))))

(test the-recorded-mcp-event-parses-and-its-replacement-is-a-list-of-text-blocks
  (let ((e (hook:parse-event (fixture "mcp-event.json"))))
    (is (eq :mcp (hook:event-shape e)))
    (is (string= "result for alpha: found in data/notes.txt lines 1-5" (hook:event-text e)))
    (let ((updated (gethash "updatedToolOutput"
                            (gethash "hookSpecificOutput" (jzon:parse (hook:hook-output e "SUMMARY"))))))
      (is (vectorp updated))
      (is (= 1 (length updated)))
      (is (string= "text" (gethash "type" (aref updated 0))))
      (is (string= "SUMMARY" (gethash "text" (aref updated 0)))))))

(test an-event-that-is-not-bash-or-mcp-text-is-no-event
  (is (null (hook:parse-event (fixture "toolsearch-event.json"))) "ToolSearch's object has no stdout")
  (is (null (hook:parse-event "{not json")) "malformed JSON")
  (is (null (hook:parse-event "[1,2,3]")) "not an object")
  (let ((e (jzon:parse (fixture "bash-event.json"))))
    (remhash "tool_response" e)
    (is (null (hook:parse-event (jzon:stringify e))) "a missing tool_response"))
  (is (hook:parse-event (fixture "bash-event.json")) "control: the recorded event is one"))

(test the-replacement-says-it-is-a-summary-and-where-the-original-is
  (let ((text (hook:replacement-text '("src/http.lisp:55 defines %read-bounded")
                                     +raw+ "claude-sonnet-5-5" #p"/cache/archive/abc.txt")))
    (is (uiop:string-prefix-p "[praxeon-claude-code: a summary of " text))
    (is (search "written by claude-sonnet-5-5" text))
    (is (search (uiop:native-namestring #p"/cache/archive/abc.txt") text)
        "the path as the platform writes it")
    (is (search "- src/http.lisp:55 defines %read-bounded" text))))

;;; --- the hook end to end, with a stub summarizer --------------------------------------------

(defclass stub-backend ()
  ((facts :initarg :facts :reader stub-facts)
   (fail :initarg :fail :initform nil :reader stub-fail)
   (calls :initform 0 :accessor stub-calls)))

(defmethod hook:summarize ((b stub-backend) prompt timeout)
  (declare (ignore prompt timeout))
  (incf (stub-calls b))
  (when (stub-fail b) (error (stub-fail b)))
  (values (stub-facts b) "stub-model"))

(test the-hook-replaces-a-large-search-output-with-a-checked-summary-and-archives-it
  (with-directory (dir)
    (let* ((raw (%big))
           (backend (make-instance 'stub-backend :facts '("src/module.lisp:1 defines handle-request"))))
      (multiple-value-bind (out fields) (hook:decide (%bash-event raw) backend :directory dir)
        (is (stringp out))
        (is (eq :replace (getf fields :decision)))
        (let* ((stdout (gethash "stdout" (gethash "updatedToolOutput"
                                                  (gethash "hookSpecificOutput" (jzon:parse out)))))
               (archive (merge-pathnames (format nil "archive/~A.txt" (hook:sha256-hex raw)) dir)))
          (is (search "written by stub-model" stdout))
          (is (search (uiop:native-namestring archive) stdout))
          (is (string= raw (uiop:read-file-string archive)) "the archive holds the raw output")
          (is (< (getf fields :sent-tokens) (getf fields :raw-tokens))))))))

(test the-hook-passes-the-output-through-when-the-summary-names-something-invented
  (with-directory (dir)
    (let ((backend (make-instance 'stub-backend :facts '("src/invented.lisp:9 defines handle-request"))))
      (multiple-value-bind (out fields) (hook:decide (%bash-event (%big)) backend :directory dir)
        (is (null out))
        (is (eq :unsupported (getf fields :reason)))
        (is (null (directory (merge-pathnames "archive/*.txt" dir)))
            "nothing is archived for a refused summary")))))

(test the-hook-does-not-call-the-summarizer-for-an-output-it-would-not-replace
  (with-directory (dir)
    (let ((backend (make-instance 'stub-backend :facts '("x"))))
      (dolist (event (list (%bash-event (%big) :command "git log")
                           (%bash-event (concatenate 'string (%big) "password=hunter2"))
                           (%bash-event (%big 5))
                           (fixture "bash-event.json")))
        (is (null (hook:decide event backend :directory dir))))
      (is (= 0 (stub-calls backend))
          "a credential-shaped output in particular is never sent to a second model"))))

(test the-hook-fails-open-when-the-summarizer-fails
  (with-directory (dir)
    (multiple-value-bind (out fields)
        (hook:decide (%bash-event (%big))
                     (make-instance 'stub-backend :facts nil :fail 'hook:summarizer-bad-reply)
                     :directory dir)
      (is (null out))
      (is (eq :backend-failed (getf fields :reason)))
      (is (string= "summarizer-bad-reply" (getf fields :error))))
    (is (null (hook:decide "{not json" (make-instance 'stub-backend :facts '("x")) :directory dir)))))

(test the-claude-backend-is-stopped-at-its-timeout
  "The real process path, with a stand-in for claude that sleeps. Control: a stand-in that
answers in time is read. The stand-ins are sh scripts, so this skips on Windows."
  (if (uiop:os-windows-p)
      (skip "the stand-in programs are sh scripts")
  (with-directory (dir)
    (let ((slow (merge-pathnames "slow.sh" dir))
          (quick (merge-pathnames "quick.sh" dir)))
      (with-open-file (s slow :direction :output)
        (format s "#!/bin/sh~%cat > /dev/null~%sleep 30~%"))
      (with-open-file (s quick :direction :output)
        (format s "#!/bin/sh~%cat > /dev/null~%echo '{\"structured_output\":{\"facts\":[\"one\"]},\"modelUsage\":{\"m1\":{}}}'~%"))
      ;; Through SYMBOL-CALL, so the file reads on Windows, where sb-posix is not loaded.
      (uiop:symbol-call :sb-posix :chmod (uiop:native-namestring slow) #o755)
      (uiop:symbol-call :sb-posix :chmod (uiop:native-namestring quick) #o755)
      (let ((start (get-internal-real-time)))
        (signals hook:summarizer-timeout
          (hook:summarize (make-instance 'hook:claude-cli :program (uiop:native-namestring slow))
                          "prompt" 1))
        (is (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 10)
            "it did not wait for the stand-in"))
      (is (equal '(("one") "m1")
                 (multiple-value-list
                  (hook:summarize (make-instance 'hook:claude-cli :program (uiop:native-namestring quick))
                                  "prompt" 10))))))))

(test the-summarizer-call-cannot-run-hooks-or-tools
  "The flags that keep the summarizer's own session from running this hook, any tool or any MCP
server. A change that drops one fails here rather than in a user's session."
  (let ((args (hook:cli-arguments (make-instance 'hook:claude-cli))))
    (is (equal "" (second (member "--tools" args :test #'string=))))
    (is (member "--strict-mcp-config" args :test #'string=))
    (is (member "--no-session-persistence" args :test #'string=))
    (is (equal "" (second (member "--setting-sources" args :test #'string=))))
    (is (search "disableAllHooks" (second (member "--settings" args :test #'string=))))
    (is (member "--json-schema" args :test #'string=))))

(test run-hook-prints-nothing-on-bad-input
  (let ((out (with-output-to-string (o)
               (with-input-from-string (i "garbage")
                 (hook:run-hook :input i :output o)))))
    (is (string= "" out))))

;;; --- the report ----------------------------------------------------------------------------------

(defun %line (&rest pairs)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on pairs by #'cddr do (setf (gethash k h) v))
    (jzon:stringify h)))

(defun %obj (&rest pairs)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on pairs by #'cddr do (setf (gethash k h) v))
    h))

(defun %assistant (id &key tool-use)
  (%line "type" "assistant"
         "message" (%obj "id" id
                         "usage" (%obj "input_tokens" 10 "output_tokens" 5
                                       "cache_read_input_tokens" 1000 "cache_creation_input_tokens" 100)
                         "content" (if tool-use (vector tool-use) (vector (%obj "type" "text" "text" "x"))))))

(defun %use (id command)
  (%obj "type" "tool_use" "id" id "name" "Bash" "input" (%obj "command" command)))

(defun %result-line (id text)
  (%line "type" "user"
         "message" (%obj "content" (vector (%obj "type" "tool_result" "tool_use_id" id "content" text)))))

(defparameter +secret+ "the-private-content-of-a-tool-result")

(defun %transcript ()
  (list (%assistant "m1" :tool-use (%use "t1" "rg -n handle src"))
        (%assistant "m1")                 ; the same call, a second block
        (%result-line "t1" (concatenate 'string +secret+ (%big)))
        (%assistant "m2")
        (%assistant "m3")
        (%line "type" "system" "subtype" "compact_boundary")
        (%assistant "m4")
        "not json at all"))

(test a-call-written-as-several-records-is-counted-once
  (let ((s (tr:parse-session-lines (%transcript))))
    (is (= 4 (length (tr:session-calls s))) "m1 twice, m2, m3, m4")
    (is (= 1 (length (tr:session-results s))))
    (let ((r (first (tr:session-results s))))
      (is (string= "Bash:rg" (tr:result-category r)))
      (is (eq :replace (tr:result-decision r)))
      (is (= 2 (tr:later-calls s r)) "m2 and m3 read it again; the compaction ends that"))))

(test the-report-prints-counts-and-never-content
  (let* ((s (tr:parse-session-lines (%transcript)))
         (text (with-output-to-string (o) (report:print-report (report:summarize (list s)) :stream o))))
    (is (search "4 model calls" text))
    (is (search "Bash:rg" text))
    (is (search "the hook would replace:     1 results" text))
    (is-false (search +secret+ text) "no text of a result")
    (is-false (search "src/module.lisp" text) "no path from a result")))

(test the-report-reads-a-directory-of-transcripts
  (with-directory (dir)
    (let ((project (merge-pathnames "some-project/" dir)))
      (ensure-directories-exist (merge-pathnames "s1/subagents/" project))
      (with-open-file (o (merge-pathnames "s1.jsonl" project) :direction :output)
        (format o "~{~A~%~}" (%transcript)))
      (with-open-file (o (merge-pathnames "s1/subagents/agent-a.jsonl" project) :direction :output)
        (format o "~A~%" (%assistant "sub1")))
      (let ((summary (report:report :projects-directory dir :days 1
                                    :stream (make-broadcast-stream))))
        (is (= 2 (getf summary :sessions)) "the session and its subagent")
        (is (= 5 (getf summary :calls)))))))
