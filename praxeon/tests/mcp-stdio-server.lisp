;;;; mcp-stdio-server.lisp --- a local MCP server for praxeon/mcp's stdio tests (#527, part 5)
;;;;
;;;; The tests start it as a child process:
;;;;
;;;;   sbcl --script mcp-stdio-server.lisp MODE QUICKLISP-SETUP RECORD-FILE
;;;;
;;;; It is never loaded into the test image. It loads jzon through Quicklisp, reads one JSON-RPC
;;;; message per line on stdin, and writes one per line on stdout. Everything it reads, and what
;;;; happens to it, is appended to RECORD-FILE, which the test reads back: "start", then "env"
;;;; with the values of PRAXEON_MCP_SECRET and PRAXEON_MCP_TEST, then "in" and each line read,
;;;; then "eof", "SIGTERM" or "exiting". MODE is one of:
;;;;
;;;;   modern         the 2026-07-28 revision: answers server/discover, and refuses a request
;;;;                  whose _meta does not carry that version
;;;;   legacy           an initialize-based server that answers server/discover with -32601
;;;;   legacy-invalid   the same, but it answers server/discover with -32600
;;;;   legacy-silent    the same, but it does not answer server/discover at all
;;;;   legacy-no-init   legacy, but it does not answer initialize
;;;;   unsupported      a current-era server that refuses 2026-07-28 with -32022, supporting
;;;;                    only 2099-01-01
;;;;   unsupported-list a current-era server whose DiscoverResult lists only 2099-01-01
;;;;   no-versions      a current-era server whose DiscoverResult has no supportedVersions
;;;;   crash            exits with status 1 as soon as it starts
;;;;   garbage          modern, and before each tool result it writes a line that is not JSON, a
;;;;                    line of 10000 characters, a JSON line of 1500 three-octet characters,
;;;;                    and a line with a byte that is not UTF-8
;;;;   ping             legacy, and it sends a ping request before it answers tools/list
;;;;   ignore-eof       modern, and it keeps running after its stdin ends, until a signal
;;;;   ignore-term      ignore-eof, and SIGTERM is recorded but does not end it
;;;;   stall            modern, with a sixth tool, stall, which stops reading stdin for 5 seconds
;;;;                    and then answers
;;;;   orphan           modern, with a sixth tool, exit-leaving-child, which starts /bin/sleep 6
;;;;                    with this process's stdout, then exits with status 3
;;;;
;;;; Every request also writes a line to stderr. Tools: echo, fail (isError), slow (30 s),
;;;; slow-a (0.5 s) and exit (the process exits with status 3), two per tools/list page.

(defvar *mode* (second sb-ext:*posix-argv*))
(defvar *record* (fourth sb-ext:*posix-argv*))

(let ((*standard-output* *error-output*))
  (load (third sb-ext:*posix-argv*))
  (funcall (intern "QUICKLOAD" "QL") :com.inuoe.jzon :silent t))

(defvar *lock* (sb-thread:make-mutex :name "stdio server"))

(defun record (control &rest arguments)
  (sb-thread:with-mutex (*lock*)
    (with-open-file (s *record* :direction :output :if-exists :append :if-does-not-exist :create)
      (format s "~?~%" control arguments))))

(defun obj (&rest keys-and-values)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on keys-and-values by #'cddr do (setf (gethash k h) v))
    h))

(defun parse (line) (funcall (intern "PARSE" "COM.INUOE.JZON") line))
(defun stringify (object) (funcall (intern "STRINGIFY" "COM.INUOE.JZON") object))

(defun send (object)
  (sb-thread:with-mutex (*lock*)
    (write-line (stringify object) *standard-output*)
    (finish-output *standard-output*)))

(defun send-raw (line)
  (sb-thread:with-mutex (*lock*)
    (write-line line *standard-output*)
    (finish-output *standard-output*)))

(defun reply (id result) (send (obj "jsonrpc" "2.0" "id" id "result" result)))

(defun fail (id code message &optional data)
  (send (obj "jsonrpc" "2.0" "id" id
             "error" (if data
                         (obj "code" code "message" message "data" data)
                         (obj "code" code "message" message)))))

(defun text-result (text &optional error-p)
  (obj "content" (vector (obj "type" "text" "text" text)) "isError" (if error-p t nil)))

(defparameter +tools+
  (append '("echo" "fail" "slow" "slow-a" "exit")
          (cond ((equal *mode* "stall") '("stall"))
                ((equal *mode* "orphan") '("exit-leaving-child")))))

(defun send-bytes (octets)
  "Write OCTETS to stdout as they are, after what the character stream holds."
  (sb-thread:with-mutex (*lock*)
    (finish-output *standard-output*)
    (let ((out (sb-sys:make-fd-stream 1 :output t :element-type '(unsigned-byte 8)
                                        :buffering :full)))
      (write-sequence octets out)
      (finish-output out))))

(defun tools-page (cursor)
  (let* ((start (if (stringp cursor) (parse-integer cursor) 0))
         (names (subseq +tools+ start (min (length +tools+) (+ start 2)))))
    (obj "tools" (map 'vector (lambda (name)
                                (obj "name" name "description" (format nil "The ~A tool." name)
                                     "inputSchema" (obj "type" "object")))
                      names)
         "nextCursor" (if (< (+ start 2) (length +tools+))
                          (princ-to-string (+ start 2))
                          'null))))

(defun call-tool (id params)
  (let ((name (gethash "name" params))
        (arguments (or (gethash "arguments" params) (obj))))
    (when (equal *mode* "garbage")
      (send-raw "this line is not JSON")
      (send-raw (make-string 10000 :initial-element #\x))
      ;; 1500 characters, 4500 octets: under a limit of 4096 only when characters are counted.
      (send-raw (format nil "{\"x\": \"~A\"}" (make-string 1500 :initial-element (code-char #x20AC))))
      ;; {"x": "<FF>"} and a newline: valid JSON but for one byte that is not UTF-8.
      (send-bytes (concatenate '(vector (unsigned-byte 8))
                               (map 'vector #'char-code "{\"x\": \"") #(255)
                               (map 'vector #'char-code "\"}") #(10))))
    (cond ((equal name "echo")
           (send (obj "jsonrpc" "2.0" "method" "notifications/message"
                      "params" (obj "level" "info" "data" "echoing")))
           (reply id (text-result (or (gethash "text" arguments) ""))))
          ((equal name "fail") (reply id (text-result "it failed" t)))
          ((equal name "slow") (sleep 30) (reply id (text-result "slow")))
          ((equal name "slow-a") (sleep 0.5) (reply id (text-result "a")))
          ((equal name "exit") (record "exiting") (sb-ext:exit :code 3 :abort t))
          ((equal name "exit-leaving-child")
           (sb-ext:run-program "/bin/sleep" '("6") :input nil :output t :error nil :wait nil)
           (record "exiting")
           (sb-ext:exit :code 3 :abort t))
          (t (fail id -32602 "Unknown tool")))))

(defvar *initialized* nil)
(defvar *held-list* nil "A tools/list id waiting for the answer to the server's ping.")

(defun legacy-p ()
  (member *mode* '("legacy" "legacy-invalid" "legacy-silent" "legacy-no-init" "ping")
          :test #'equal))

(defun handle-request (id method params)
  (format *error-output* "stderr: a request for ~A~%" method)
  (finish-output *error-output*)
  (cond
    ((equal method "server/discover")
     (cond ((member *mode* '("legacy" "legacy-no-init" "ping") :test #'equal)
            (fail id -32601 "Method not found"))
           ((equal *mode* "legacy-invalid") (fail id -32600 "Invalid Request"))
           ((equal *mode* "legacy-silent"))   ; no answer at all
           ((equal *mode* "no-versions")
            (reply id (obj "capabilities" (obj "tools" (obj)) "ttlMs" 0)))
           ((equal *mode* "unsupported-list")
            (reply id (obj "supportedVersions" (vector "2099-01-01")
                           "capabilities" (obj "tools" (obj)) "ttlMs" 0)))
           ((equal *mode* "unsupported")
            (fail id -32022 "Unsupported protocol version"
                  (obj "supported" (vector "2099-01-01") "requested" "2026-07-28")))
           (t (reply id (obj "supportedVersions" (vector "2026-07-28")
                             "capabilities" (obj "tools" (obj)) "ttlMs" 0)))))
    ((legacy-p)
     (cond ((and (equal method "initialize") (equal *mode* "legacy-no-init")))
           ((equal method "initialize")
            (reply id (obj "protocolVersion" "2025-11-25" "capabilities" (obj "tools" (obj))
                           "serverInfo" (obj "name" "test" "version" "1"))))
           ((not *initialized*) (fail id -32600 "Not initialized"))
           ((and (equal method "tools/list") (equal *mode* "ping") (null *held-list*))
            (setf *held-list* (cons id params))
            (send (obj "jsonrpc" "2.0" "id" "server-ping" "method" "ping")))
           ((equal method "tools/list") (reply id (tools-page (gethash "cursor" params))))
           ((equal method "tools/call")
            (sb-thread:make-thread (lambda () (call-tool id params))))
           (t (fail id -32601 "Method not found"))))
    (t
     (let ((version (and (hash-table-p (gethash "_meta" params))
                         (gethash "io.modelcontextprotocol/protocolVersion"
                                  (gethash "_meta" params)))))
       (cond ((not (equal version "2026-07-28"))
              (fail id -32022 "Unsupported protocol version"
                    (obj "supported" (vector "2026-07-28") "requested" (or version 'null))))
             ((equal method "tools/list") (reply id (tools-page (gethash "cursor" params))))
             ((and (equal method "tools/call") (equal (gethash "name" params) "stall"))
              ;; On this thread, so that stdin is not read meanwhile.
              (sleep 5)
              (reply id (text-result "stalled")))
             ((equal method "tools/call")
              (sb-thread:make-thread (lambda () (call-tool id params))))
             (t (fail id -32601 "Method not found")))))))

(defun handle (line)
  (record "in ~A" line)
  (let* ((message (parse line))
         (method (gethash "method" message))
         (params (or (gethash "params" message) (obj))))
    (cond ((null method)
           ;; A response: only the answer to this server's ping.
           (when (and *held-list* (equal "server-ping" (gethash "id" message)))
             (record "pong")
             (destructuring-bind (id . params) *held-list*
               (reply id (tools-page (gethash "cursor" params))))))
          ((nth-value 1 (gethash "id" message))
           (handle-request (gethash "id" message) method params))
          ((equal method "notifications/initialized") (setf *initialized* t)))))

(record "start")
(record "env ~{~A=~:[none~;~:*~A~]~^ ~}"
        (loop for name in '("PRAXEON_MCP_SECRET" "PRAXEON_MCP_TEST")
              collect name collect (sb-ext:posix-getenv name)))
#-win32
(sb-sys:enable-interrupt sb-unix:sigterm
                         (lambda (&rest arguments)
                           (declare (ignore arguments))
                           (record "SIGTERM")
                           (unless (equal *mode* "ignore-term")
                             (sb-ext:exit :code 0 :abort t))))
(when (equal *mode* "crash")
  (sb-ext:exit :code 1 :abort t))
(loop for line = (read-line *standard-input* nil)
      while line
      do (handle line))
(record "eof")
(when (member *mode* '("ignore-eof" "ignore-term") :test #'equal)
  (loop (sleep 1)))
(sb-ext:exit :code 0 :abort t)
