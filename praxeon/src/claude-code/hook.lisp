;;;; claude-code/hook.lisp --- a PostToolUse hook that replaces a large search output with a checked summary (#452).
;;;;
;;;; THE EVENT, AS CLAUDE CODE 2.1.270 SENDS IT (recorded 2026-09-30; the recordings are the
;;;; suite's fixtures). One JSON object on stdin with `tool_name', `tool_input' and
;;;; `tool_response'. For Bash, `tool_response' is an object with `stdout', `stderr',
;;;; `interrupted', `isImage' and `noOutputExpected'. For an MCP tool it is an array of content
;;;; blocks, [{"type":"text","text":...}].
;;;;
;;;; THE REPLACEMENT HAS THE TOOL'S OWN SHAPE. The hook prints
;;;; {"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":X}}. Measured with
;;;; that release: for Bash, X as an object {stdout, stderr, interrupted, isImage} replaced what
;;;; the model read, and X as a plain string was ignored, so the model read the original. For an
;;;; MCP tool an array of text blocks replaced it. So X is built in the shape the event had.
;;;;
;;;; FAIL OPEN. Anything unexpected -- input that is not the event, a field missing, a backend
;;;; that errs, times out or answers with something the check refuses -- ends with nothing on
;;;; stdout and exit status 0, and Claude Code then passes the original output through.
;;;;
;;;; THE SUMMARY IS CHECKED AGAINST THE RAW TEXT (CHECK-SUMMARY). A schema accepts any string,
;;;; including a file name the summarizer invented. Here every path, number and identifier-shaped
;;;; token in the summary has to occur verbatim in the raw output, or the summary is refused.

(in-package #:praxeon/claude-code/hook)

;;; --- settings --------------------------------------------------------------------------

(defun %env-integer (name default)
  (let ((v (uiop:getenv name)))
    (or (and v (ignore-errors (parse-integer v))) default)))

(defun %env (name default)
  (let ((v (uiop:getenv name))) (if (and v (plusp (length v))) v default)))

(defparameter *timeout-seconds* 90
  "How long the summarizer may take (PRAXEON_CC_TIMEOUT). Claude Code's own default timeout for a
command hook is 600 seconds; this is shorter so the hook fails open well before that.")

(defparameter *archive-days* 7
  "Archived raw outputs older than this many days are deleted (PRAXEON_CC_ARCHIVE_DAYS).")

(defun cache-directory ()
  "Where the hook keeps its archive and log: PRAXEON_CC_CACHE_DIR, or
$XDG_CACHE_HOME/praxeon-claude-code/, or ~/.cache/praxeon-claude-code/."
  (let ((explicit (uiop:getenv "PRAXEON_CC_CACHE_DIR")))
    (uiop:ensure-directory-pathname
     (cond ((and explicit (plusp (length explicit))) explicit)
           (t (merge-pathnames "praxeon-claude-code/"
                               (uiop:ensure-directory-pathname
                                (or (let ((x (uiop:getenv "XDG_CACHE_HOME")))
                                      (and x (plusp (length x)) x))
                                    (merge-pathnames ".cache/" (user-homedir-pathname))))))))))

;;; --- the event -------------------------------------------------------------------------

(defstruct (event (:constructor %make-event))
  (tool "" :type string)
  input                              ; the tool_input hash table
  (shape :bash)                      ; :BASH or :MCP, the shape of tool_response
  (text "" :type string)             ; the output the model would read
  (stderr "")
  (interrupted nil)
  (image nil))

(defun parse-event (json)
  "An EVENT from the hook's stdin, JSON (a string), or NIL when it is not a PostToolUse event
for Bash or an MCP tool with a text result. NIL is the fail-open answer: nothing is replaced."
  (let ((e (ignore-errors (jzon:parse json))))
    (when (hash-table-p e)
      (let ((tool (gethash "tool_name" e))
            (input (gethash "tool_input" e))
            (response (gethash "tool_response" e)))
        (when (and (equal (gethash "hook_event_name" e) "PostToolUse") (stringp tool))
          (cond
            ((and (string= tool "Bash") (hash-table-p response)
                  (stringp (gethash "stdout" response)))
             (%make-event :tool tool :input input :shape :bash
                          :text (gethash "stdout" response)
                          :stderr (let ((s (gethash "stderr" response))) (if (stringp s) s ""))
                          :interrupted (eq t (gethash "interrupted" response))
                          :image (eq t (gethash "isImage" response))))
            ((and (vectorp response) (not (stringp response)) (plusp (length response))
                  (every (lambda (b) (and (hash-table-p b) (equal (gethash "type" b) "text")
                                          (stringp (gethash "text" b))))
                         response))
             (%make-event :tool tool :input input :shape :mcp
                          :text (format nil "~{~A~^~%~}"
                                        (map 'list (lambda (b) (gethash "text" b)) response))))))))))

(defun %command-of (event)
  "EVENT's command for Bash, its tool name for an MCP tool."
  (let ((c (and (hash-table-p (event-input event)) (gethash "command" (event-input event)))))
    (if (stringp c) c (event-tool event))))

(defun event-eligibility (event)
  "RULES:ELIGIBILITY for EVENT."
  (if (event-image event)
      (values :pass :failed)
      (rules:eligibility (event-tool event) (event-input event) (event-text event)
                         :stderr (event-stderr event) :interrupted (event-interrupted event))))

;;; --- the summary check ----------------------------------------------------------------------

(defun %strip (token)
  "TOKEN without surrounding brackets, quotes and punctuation, and without a possessive 's."
  (let ((s (string-trim "()[]{}<>\"'`,;!?*" (string-right-trim ".:" (string-trim "()[]{}<>\"'`,;!?*" token)))))
    (if (and (> (length s) 2)
             (member (subseq s (- (length s) 2)) '("'s" "’s") :test #'string=))
        (subseq s 0 (- (length s) 2))
        s)))

(defun %split-colons (text)
  "TEXT with each single colon replaced by a space, and :: left alone. A summary writes
name:line or path:line, and each side is checked on its own: the name and the path verbatim,
the line number as a digit run."
  (let ((out (copy-seq text)) (n (length text)))
    (loop for i from 0 below n
          when (and (char= (char text i) #\:)
                    (not (and (> i 0) (char= (char text (1- i)) #\:)))
                    (not (and (< (1+ i) n) (char= (char text (1+ i)) #\:))))
            do (setf (char out i) #\Space))
    out))

(defun %tokens (text)
  (let ((text (%split-colons text)) (out '()) (start nil))
    (loop for i from 0 to (length text)
          for c = (and (< i (length text)) (char text i))
          do (if (or (null c) (member c '(#\Space #\Tab #\Newline #\Return)))
                 (when start (push (subseq text start i) out) (setf start nil))
                 (unless start (setf start i))))
    (nreverse out)))

(defun %path-like-p (token)
  "A token that names a file or directory: it contains / or \\, or it is NAME.EXT with an
extension of 1 to 8 letters or digits."
  (or (find #\/ token) (find #\\ token)
      (let ((dot (position #\. token :from-end t)))
        (and dot (> dot 0) (< dot (1- (length token)))
             (<= (- (length token) dot 1) 8)
             (every #'alphanumericp (subseq token (1+ dot)))
             (some #'alpha-char-p (subseq token (1+ dot)))))))

(defun %abbreviation-p (token)
  "Single letters joined by dots, such as e.g and i.e: prose, not a name."
  (and (> (length token) 1)
       (loop for i from 0 below (length token)
             always (if (evenp i) (alpha-char-p (char token i)) (char= (char token i) #\.)))))

(defun %identifier-like-p (token)
  "A token shaped like a name in code rather than a word: it contains _ or ::, a dot between
two word characters, letters and digits together, or a lowercase letter followed by an
uppercase one. An abbreviation such as e.g is not one."
  (let ((n (length token)))
    (and (not (%abbreviation-p token))
    (or (find #\_ token)
        (search "::" token)
        (loop for i from 1 below (1- n)
              thereis (and (char= (char token i) #\.)
                           (alphanumericp (char token (1- i))) (alphanumericp (char token (1+ i)))))
        (and (some #'alpha-char-p token) (some #'digit-char-p token))
        (loop for i from 1 below n
              thereis (and (lower-case-p (char token (1- i))) (upper-case-p (char token i))))))))

(defun %digit-runs (text)
  (let ((out '()) (n (length text)) (i 0))
    (loop while (< i n)
          do (if (digit-char-p (char text i))
                 (let ((end (or (position-if-not #'digit-char-p text :start i) n)))
                   (push (subseq text i end) out) (setf i end))
                 (incf i)))
    (nreverse out)))

(defun %digit-run-in-p (run text)
  "Whether RUN occurs in TEXT as a whole run of digits, not inside a longer one."
  (loop for start = (search run text) then (search run text :start2 (1+ start))
        while start
        thereis (and (or (= start 0) (not (digit-char-p (char text (1- start)))))
                     (let ((end (+ start (length run))))
                       (or (= end (length text)) (not (digit-char-p (char text end))))))))

(defun %without-markup (text)
  "TEXT without Markdown's ` and * characters, which mark formatting rather than content, so
`GetLastError`/HRESULT in a document matches GetLastError/HRESULT in a summary."
  (remove-if (lambda (c) (member c '(#\` #\*))) text))

(defun unsupported-tokens (summary raw)
  "The tokens of SUMMARY that a summary may only contain when they occur verbatim in RAW, and do
not: paths, identifier-shaped tokens and hexadecimal identifiers, compared as whole strings,
and every run of digits, compared as a whole run, which covers line numbers and counts. Both
sides are compared without Markdown's ` and * (%WITHOUT-MARKUP); nothing else is relaxed.

WHAT THIS DOES NOT CHECK: which token goes with which. A line number is refused when it occurs
nowhere in RAW, not when it occurs only beside another path; in a long listing most small
numbers occur somewhere. It catches an invented name, path or number, not a real one attached
to the wrong thing."
  (let ((missing '())
        (summary (%without-markup summary))
        (raw (%without-markup raw)))
    (dolist (word (%tokens summary))
      (let ((token (%strip word)))
        (when (and (plusp (length token))
                   (not (%abbreviation-p token))
                   (or (%path-like-p token) (%identifier-like-p token))
                   (not (search token raw)))
          (pushnew token missing :test #'string=))))
    (dolist (run (%digit-runs summary))
      (unless (%digit-run-in-p run raw)
        (pushnew run missing :test #'string=)))
    (nreverse missing)))

(defun check-summary (summary raw &key (budget rules:*summary-budget*))
  "Whether SUMMARY may replace RAW. Returns T, or NIL and the reason as a second value:
:EMPTY, :OVER-BUDGET (more than BUDGET tokens), :TOO-LITTLE-SMALLER (less than
*MINIMUM-REDUCTION* smaller than RAW), or :UNSUPPORTED, with the offending tokens as a third
value."
  (let ((s (rules:estimate-tokens (length summary)))
        (r (rules:estimate-tokens (length raw))))
    (cond ((zerop (length (string-trim '(#\Space #\Tab #\Newline) summary))) (values nil :empty))
          ((> s budget) (values nil :over-budget))
          ((> s (* r (- 1 rules:*minimum-reduction*))) (values nil :too-little-smaller))
          (t (let ((missing (unsupported-tokens summary raw)))
               (if missing (values nil :unsupported missing) t))))))

;;; --- the replacement ------------------------------------------------------------------------

(defun replacement-text (facts raw model archive)
  "What the model reads in place of RAW: one line saying it is a summary, with the raw and
summary sizes, the MODEL that wrote it and the ARCHIVE path of the raw output, then FACTS, one
per line."
  (let ((body (format nil "~{- ~A~%~}" facts)))
    (format nil "[praxeon-claude-code: a summary of ~:D tokens of output in ~:D tokens, written by ~A. The full output is in ~A]~%~A"
            (rules:estimate-tokens (length raw)) (rules:estimate-tokens (length body))
            model (uiop:native-namestring archive) body)))

(defun hook-output (event text)
  "The JSON the hook prints to replace EVENT's output with TEXT, in the tool's own shape."
  (let ((h (make-hash-table :test #'equal))
        (specific (make-hash-table :test #'equal)))
    (setf (gethash "hookEventName" specific) "PostToolUse"
          (gethash "updatedToolOutput" specific)
          (ecase (event-shape event)
            (:bash (let ((o (make-hash-table :test #'equal)))
                     (setf (gethash "stdout" o) text (gethash "stderr" o) ""
                           (gethash "interrupted" o) nil (gethash "isImage" o) nil)
                     o))
            (:mcp (vector (let ((b (make-hash-table :test #'equal)))
                            (setf (gethash "type" b) "text" (gethash "text" b) text)
                            b))))
          (gethash "hookSpecificOutput" h) specific)
    (jzon:stringify h)))

;;; --- the prompt -----------------------------------------------------------------------------

(defparameter *instructions*
  "Another assistant ran the command below while working on a task, and will read your list instead of its output. List the facts from the output that the assistant is likely to need: which files matched, where, and what the matches say.

Rules:
- Copy every file path, function or variable name and identifier exactly as it appears in the output. Do not shorten, correct or complete them. Use / only inside a path that appears in the output, and never join two names or words with /: write \"macOS and Linux\", not \"macOS/Linux\".
- Write a line number the way the output writes it, as path:line, for example src/a.lisp:12. Never write L12 or line12.
- Do not count, add up or estimate anything. Do not write any number that is not in the output.
- Do not add anything that is not in the output, and never write a pattern or a placeholder such as file_N.lisp. Write only names that appear in the output.
- Write at most 20 facts, each one sentence of at most 40 words, and the whole list under ~D words. A fact states what several lines say; it is not a copy of a line. When the output is a long listing, say which files it covers and name a few representative entries from each, exactly.

The command: ~A
----------
"
  "The summarizer's instructions; the raw output follows the dashes.")

(defun prompt (raw &optional (command ""))
  "The summarizer's prompt for RAW, the output of COMMAND (a string, or \"\" when unknown)."
  (concatenate 'string
               (format nil *instructions* (floor (* rules:*summary-budget* 2) 5) command)
               raw))

;;; --- backends -------------------------------------------------------------------------------

(define-condition summarizer-failure (error) ()
  (:documentation "A backend could not produce facts. The hook logs the subtype's name and
passes the original output through."))

(define-condition summarizer-timeout (summarizer-failure)
  ((seconds :initarg :seconds :reader summarizer-timeout-seconds))
  (:report (lambda (c s) (format s "the summarizer took longer than ~D s" (summarizer-timeout-seconds c)))))

(define-condition summarizer-exit (summarizer-failure)
  ((status :initarg :status :reader summarizer-exit-status))
  (:report (lambda (c s) (format s "the summarizer exited with status ~A" (summarizer-exit-status c)))))

(define-condition summarizer-bad-reply (summarizer-failure) ()
  (:report "the summarizer's reply had no list of facts"))

(defgeneric summarize (backend prompt timeout)
  (:documentation "Ask BACKEND for the facts in PROMPT within TIMEOUT seconds. Returns a list of
strings and the model's name, or signals an error. Every error is caught by RUN-HOOK, which then
passes the original output through."))

(defclass claude-cli ()
  ((program :initarg :program :initform "claude" :reader cli-program)
   (model :initarg :model :initform "sonnet" :reader cli-model)
   (effort :initarg :effort :initform "medium" :reader cli-effort))
  (:documentation "The `claude' CLI in print mode, which uses the Claude Code login."))

(defparameter +facts-schema+
  "{\"type\":\"object\",\"properties\":{\"facts\":{\"type\":\"array\",\"maxItems\":20,\"items\":{\"type\":\"string\",\"maxLength\":300}}},\"required\":[\"facts\"],\"additionalProperties\":false}"
  "The shape of the summarizer's answer: at most 20 facts of at most 300 characters each. The
bounds are in the schema so that the summarizer is held to them, not only asked; the size is
checked again in CHECK-SUMMARY.")

(defun cli-arguments (backend)
  "The arguments for BACKEND's call. No tools, no MCP servers, no settings files, hooks off, no
session kept, so the call cannot run this hook or anything else."
  (list "-p" "--tools" "" "--strict-mcp-config" "--no-session-persistence"
        "--setting-sources" "" "--settings" "{\"disableAllHooks\": true}"
        "--json-schema" +facts-schema+ "--output-format" "json"
        "--model" (cli-model backend) "--effort" (cli-effort backend)))

(defun %run-with-timeout (program arguments input timeout &key environment)
  "Run PROGRAM with ARGUMENTS, INPUT on its stdin, and return its stdout. Signals
SUMMARIZER-TIMEOUT if it has not finished within TIMEOUT seconds, after killing it, and
SUMMARIZER-EXIT if it exits with a status other than 0.

THE READER IS JOINED BEFORE THE STREAMS ARE CLOSED, and it catches its own errors. Closing the
child's stdout while the reader thread is still reading it made that thread's read fail (select
on a closed descriptor, seen on macOS), and an error no handler takes in another thread ends the
whole process with status 1, which is not failing open. On a timeout the whole process group is
killed (%KILL-GROUP) and the reader is given a second to see the end of its input."
  (let* ((out (make-string-output-stream))
         (process (sb-ext:run-program program arguments :search t :wait nil
                                      :input :stream :output :stream :error nil
                                      :environment environment))
         ;; THREAD-LIFETIME: scoped -- it only copies the child's stdout into a string, needs
         ;; none of the caller's bindings, and is joined below before this function returns.
         (reader (sb-thread:make-thread
                  (lambda ()
                    (ignore-errors
                     (let ((s (sb-ext:process-output process)))
                       (loop for line = (read-line s nil) while line
                             do (write-line line out))))))))
    (unwind-protect
         (progn
           (ignore-errors
            (with-open-stream (in (sb-ext:process-input process))
              (write-string input in)))
           (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
             (loop while (sb-ext:process-alive-p process)
                   do (when (> (get-internal-real-time) deadline)
                        (%kill-group process)
                        (sb-thread:join-thread reader :default nil :timeout 1)
                        (error 'summarizer-timeout :seconds timeout))
                      (sleep 0.05)))
           (sb-thread:join-thread reader :default nil :timeout 5)
           (unless (eql 0 (sb-ext:process-exit-code process))
             (error 'summarizer-exit :status (sb-ext:process-exit-code process)))
           (get-output-stream-string out))
      (when (sb-ext:process-alive-p process) (%kill-group process))
      (sb-thread:join-thread reader :default nil :timeout 1)
      (sb-ext:process-close process))))

(defun %kill-group (process)
  "Kill PROCESS and every process in its group. A child of the child, such as one the claude CLI
starts, would otherwise keep the output pipe open and the reader waiting after PROCESS is gone.
Falls back to PROCESS alone where there is no process group."
  (or (ignore-errors (sb-ext:process-kill process 9 :process-group))
      (ignore-errors (sb-ext:process-kill process 9))))

(defmethod summarize ((backend claude-cli) prompt timeout)
  (let* ((environment (cons "CLAUDE_CODE_PROMPT_CACHE_TTL=5m"
                            (remove-if (lambda (e) (uiop:string-prefix-p "CLAUDE_CODE_PROMPT_CACHE_TTL=" e))
                                       (sb-ext:posix-environ))))
         (reply (handler-case (jzon:parse (%run-with-timeout (cli-program backend) (cli-arguments backend)
                                                             prompt timeout :environment environment))
                  (jzon:json-parse-error () (error 'summarizer-bad-reply))))
         (facts (and (hash-table-p reply)
                     (gethash "facts" (or (gethash "structured_output" reply) (make-hash-table)))))
         (usage (gethash "modelUsage" reply)))
    (unless (and (vectorp facts) (every #'stringp facts))
      (error 'summarizer-bad-reply))
    (values (coerce facts 'list)
            (or (and (hash-table-p usage)
                     (loop for k being the hash-keys of usage return k))
                (cli-model backend)))))

(defclass praxeon-provider ()
  ((provider :initarg :provider :reader backend-provider))
  (:documentation "Any praxeon/llm provider, resolved from the environment with :ROLE :COMPRESSOR."))

(defun %facts-spec ()
  (let ((schema (jzon:parse +facts-schema+)))
    (llm:make-tool-spec :name "record_facts"
                        :description "Record the facts from the output that the assistant will need."
                        :schema schema)))

(defmethod summarize ((backend praxeon-provider) prompt timeout)
  (let* ((result nil) (failure nil)
         ;; THREAD-LIFETIME: continues the hook's one call, and is joined or ended below before
         ;; this returns. It runs a praxeon model call, which reads praxeon's registered dynamic
         ;; bindings (#158), so it carries them.
         (thread (sb-thread:make-thread
                  (aion/dynamic:inheriting
                   (lambda ()
                     (handler-case
                         (setf result (llm:generate-structured
                                       (backend-provider backend)
                                       (list (llm:msg :user prompt)) (%facts-spec)
                                       :max-tokens (* 2 rules:*summary-budget*) :attempts 1))
                       (error (e) (setf failure e))))))))
    (unless (sb-thread:join-thread thread :default nil :timeout timeout)
      (ignore-errors (sb-thread:terminate-thread thread))
      (error 'summarizer-timeout :seconds timeout))
    (when failure (error failure))
    (let ((facts (and (hash-table-p result) (gethash "facts" result))))
      (unless (and (vectorp facts) (every #'stringp facts))
        (error 'summarizer-bad-reply))
      (values (coerce facts 'list)
              (or (ignore-errors (llm:model-of (backend-provider backend))) "a praxeon provider")))))

(defun backend-from-env ()
  "The backend PRAXEON_CC_BACKEND names: `claude' (the default), the claude CLI with
PRAXEON_CC_MODEL (default sonnet) and PRAXEON_CC_EFFORT (default medium); or `praxeon', the
praxeon/llm provider PRAXEON_COMPRESSOR_* or PRAXEON_LLM_* configure."
  (let ((name (string-downcase (%env "PRAXEON_CC_BACKEND" "claude"))))
    (cond ((string= name "claude")
           (make-instance 'claude-cli :program (%env "PRAXEON_CC_CLAUDE" "claude")
                                      :model (%env "PRAXEON_CC_MODEL" "sonnet")
                                      :effort (%env "PRAXEON_CC_EFFORT" "medium")))
          ((string= name "praxeon")
           (make-instance 'praxeon-provider
                          :provider (llm:make-provider-from-env :role :compressor)))
          (t (error "praxeon-claude-code: unknown PRAXEON_CC_BACKEND ~S" name)))))

;;; --- archive and log ------------------------------------------------------------------------

(defun sha256-hex (text)
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence :sha256 (sb-ext:string-to-octets text :external-format :utf-8))))

(defun archive (raw &key (directory (cache-directory)) (days *archive-days*))
  "Write RAW to DIRECTORY/archive/<sha256>.txt, delete archives older than DAYS days, and return
the path."
  (let* ((dir (merge-pathnames "archive/" directory))
         (path (merge-pathnames (format nil "~A.txt" (sha256-hex raw)) dir))
         (cutoff (- (get-universal-time) (* days 86400))))
    (ensure-directories-exist dir)
    (with-open-file (out path :direction :output :if-exists :supersede :external-format :utf-8)
      (write-string raw out))
    (dolist (old (directory (merge-pathnames "*.txt" dir)))
      (when (< (or (ignore-errors (file-write-date old)) cutoff) cutoff)
        (ignore-errors (delete-file old))))
    path))

(defun log-event (fields &key (directory (cache-directory)))
  "Append FIELDS, a plist of counts and keywords, as one JSON line to DIRECTORY/hook.log. Never
the output or the summary."
  (ignore-errors
   (let ((h (make-hash-table :test #'equal)))
     (loop for (k v) on fields by #'cddr
           do (setf (gethash (string-downcase (symbol-name k)) h)
                    (if (keywordp v) (string-downcase (symbol-name v)) v)))
     (ensure-directories-exist directory)
     (with-open-file (out (merge-pathnames "hook.log" directory) :direction :output
                          :if-exists :append :if-does-not-exist :create :external-format :utf-8)
       (write-line (jzon:stringify h) out)))))

;;; --- the hook -------------------------------------------------------------------------------

(defun decide (json backend &key (timeout *timeout-seconds*) (directory (cache-directory)))
  "The hook's work for one event, JSON (the stdin text): returns the JSON to print, or NIL to
print nothing, and a plist of what happened for the log. Signals nothing; every failure is a
NIL with its reason."
  (let* ((started (get-internal-real-time))
         (event (ignore-errors (parse-event json)))
         (fields (list :category (if event (rules:tool-category (event-tool event) (event-input event)) "")
                       :raw-tokens (if event (rules:estimate-tokens (length (event-text event))) 0))))
    (flet ((done (output decision reason &rest more)
             (return-from decide
               (values output (append fields (list :decision decision :reason reason
                                                   :ms (round (* 1000 (- (get-internal-real-time) started))
                                                              internal-time-units-per-second))
                                      more)))))
      (unless event (done nil :pass :not-an-event))
      (multiple-value-bind (decision reason) (event-eligibility event)
        (unless (eq decision :replace) (done nil :pass reason)))
      (let ((raw (event-text event)))
        (multiple-value-bind (facts model)
            (handler-case (summarize backend (prompt raw (%command-of event)) timeout)
              ;; The error's type, not its message: a message can quote the output.
              (error (e) (done nil :pass :backend-failed :backend (string-downcase (type-of backend))
                               :error (string-downcase (princ-to-string (type-of e))))))
          ;; CHECKED BEFORE IT IS ARCHIVED, so a refused summary leaves nothing behind.
          (multiple-value-bind (ok why) (check-summary (format nil "~{~A~%~}" facts) raw)
            (unless ok
              (done nil :pass why :backend (string-downcase (type-of backend)))))
          (let* ((path (or (ignore-errors (archive raw :directory directory))
                           (done nil :pass :archive-failed)))
                 (text (replacement-text facts raw model path)))
            (done (hook-output event text) :replace nil
                  :sent-tokens (rules:estimate-tokens (length text))
                  :backend (string-downcase (type-of backend)))))))))

(defun run-hook (&key (input *standard-input*) (output *standard-output*))
  "Read one event from INPUT, print the replacement to OUTPUT or nothing, log a line, and return.
Never signals: any error prints nothing. The settings come from the environment:
PRAXEON_CC_THRESHOLD, PRAXEON_CC_SUMMARY_BUDGET, PRAXEON_CC_TIMEOUT, PRAXEON_CC_ARCHIVE_DAYS,
PRAXEON_CC_CACHE_DIR, and those BACKEND-FROM-ENV reads."
  (ignore-errors
   (let ((rules:*threshold-tokens* (%env-integer "PRAXEON_CC_THRESHOLD" rules:*threshold-tokens*))
         (rules:*summary-budget* (%env-integer "PRAXEON_CC_SUMMARY_BUDGET" rules:*summary-budget*))
         (*archive-days* (%env-integer "PRAXEON_CC_ARCHIVE_DAYS" *archive-days*))
         (json (with-output-to-string (s)
                 (loop for line = (read-line input nil) while line do (write-line line s)))))
     (multiple-value-bind (out fields)
         (decide json (or (ignore-errors (backend-from-env))
                          (return-from run-hook nil))
                 :timeout (%env-integer "PRAXEON_CC_TIMEOUT" *timeout-seconds*))
       (log-event fields)
       (when out
         (write-string out output)
         (terpri output)
         (finish-output output)))))
  nil)
