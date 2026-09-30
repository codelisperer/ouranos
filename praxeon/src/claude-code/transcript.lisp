;;;; claude-code/transcript.lisp --- a Claude Code transcript, read as counts (#452).
;;;;
;;;; THE RECORDS THIS READS, as found in Claude Code's own transcripts on 2026-09-30:
;;;;
;;;;   {"type":"assistant","message":{"id":..,"usage":{..},"content":[{"type":"tool_use",
;;;;     "id":..,"name":..,"input":{..}}, ..]}, ..}
;;;;   {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":..,
;;;;     "content": <string or a list of blocks>,"is_error":..}]}, ..}
;;;;   {"type":"system","subtype":"compact_boundary", ..}
;;;;
;;;; ONE MODEL CALL IS SEVERAL RECORDS. Claude Code writes an assistant record per content
;;;; block, each carrying the message's id and the same `usage'. Summing records counts a
;;;; call once per block; on the transcripts this was checked against, 887 calls were 2,039
;;;; records. So a call is counted once, at the first record with its id.
;;;;
;;;; NOTHING KEPT IS TEXT. A result is its size, its category and whether it was an error. The
;;;; category for Bash is a command word (BASH-CATEGORY), which is what the report groups by;
;;;; no argument, path or output survives the read.

(in-package #:praxeon/claude-code/transcript)

(defstruct (call (:constructor %make-call))
  (index 0 :type fixnum)             ; position among this session's calls, from 0
  (input 0 :type integer)
  (output 0 :type integer)
  (cache-read 0 :type integer)
  (cache-write 0 :type integer))

(defstruct (result (:constructor %make-result))
  (index 0 :type fixnum)             ; how many calls this session had made before this result
  (line 0 :type fixnum)              ; its record's position in the transcript, from 0
  (tool "" :type string)             ; the tool's name
  (category "" :type string)         ; TOOL-CATEGORY
  (tokens 0 :type integer)           ; ESTIMATE-TOKENS of the content
  (error-p nil)
  (decision :pass)                   ; RULES:ELIGIBILITY's answer for this result
  (reason nil))                      ; and its reason when :PASS

(defstruct (session (:constructor %make-session))
  (calls '() :type list)             ; CALLs, in order
  (results '() :type list)           ; RESULTs, in order
  (compactions '() :type list))      ; (line . calls-so-far) for each compact_boundary, in order

;;; --- one session -------------------------------------------------------------------------

(defun %get (object &rest keys)
  (let ((v object))
    (dolist (k keys v)
      (setf v (and (hash-table-p v) (gethash k v))))))

(defun %int (x) (if (integerp x) x 0))

(defun %content-text (content)
  "The text of a tool result's CONTENT: a string, or the text blocks of a list, joined. An
image block contributes nothing, since its text size says nothing about what it costs. Used
only while a record is read; it is not kept."
  (cond ((stringp content) content)
        ((vectorp content)
         (with-output-to-string (out)
           (loop for block across content
                 for text = (%get block "text")
                 when (stringp text) do (write-string text out))))
        (t "")))

(defun parse-session-lines (lines &key since)
  "A SESSION from LINES, the lines of one transcript, in order. A line that is not JSON, or not
an object, is skipped. With SINCE (a universal time), records stamped earlier are skipped;
a record with no timestamp is kept."
  (let ((seen (make-hash-table :test #'equal))
        (uses (make-hash-table :test #'equal))
        (calls '()) (results '()) (compactions '()) (n 0) (line-number -1))
    (dolist (line lines)
      (incf line-number)
      (let ((record (and (plusp (length line)) (ignore-errors (jzon:parse line :max-string-length (1- array-dimension-limit))))))
        (when (and (hash-table-p record)
                   (or (null since) (%recent-p record since)))
          (let ((type (gethash "type" record))
                (outcome (gethash "toolUseResult" record)))
            (cond
              ((equal type "assistant")
               (let* ((message (gethash "message" record))
                      (id (%get message "id"))
                      (usage (%get message "usage")))
                 (let ((content (%get message "content")))
                   (when (vectorp content)
                     (loop for block across content
                           when (equal (%get block "type") "tool_use")
                             do (setf (gethash (%get block "id") uses)
                                      (cons (or (%get block "name") "") (%get block "input"))))))
                 (when (and id (hash-table-p usage) (not (gethash id seen)))
                   (setf (gethash id seen) t)
                   (push (%make-call :index n
                                     :input (%int (gethash "input_tokens" usage))
                                     :output (%int (gethash "output_tokens" usage))
                                     :cache-read (%int (gethash "cache_read_input_tokens" usage))
                                     :cache-write (%int (gethash "cache_creation_input_tokens" usage)))
                         calls)
                   (incf n))))
              ((equal type "user")
               (let ((content (%get record "message" "content")))
                 (when (vectorp content)
                   (loop for block across content
                         when (equal (%get block "type") "tool_result")
                           do (let* ((use (gethash (%get block "tool_use_id") uses))
                                     (tool (if (stringp (car use)) (car use) ""))
                                     (text (%content-text (%get block "content")))
                                     (error-p (eq t (%get block "is_error"))))
                                (multiple-value-bind (decision reason)
                                    (rules:eligibility tool (cdr use) text
                                                       :error-p error-p
                                                       :stderr (%get outcome "stderr")
                                                       :interrupted (eq t (%get outcome "interrupted")))
                                  (push (%make-result
                                         :index n :line line-number :tool tool
                                         :category (rules:tool-category tool (cdr use))
                                         :tokens (rules:estimate-tokens (length text))
                                         :error-p error-p :decision decision :reason reason)
                                        results)))))))
              ((and (equal type "system") (equal (gethash "subtype" record) "compact_boundary"))
               (push (cons line-number n) compactions)))))))
    (%make-session :calls (nreverse calls) :results (nreverse results)
                   :compactions (nreverse compactions))))

(defun %parse-timestamp (string)
  "A universal time from an ISO-8601 UTC timestamp such as 2026-09-30T12:58:45.150Z, or NIL."
  (ignore-errors
   (encode-universal-time (parse-integer string :start 17 :end 19)
                          (parse-integer string :start 14 :end 16)
                          (parse-integer string :start 11 :end 13)
                          (parse-integer string :start 8 :end 10)
                          (parse-integer string :start 5 :end 7)
                          (parse-integer string :start 0 :end 4)
                          0)))

(defun %recent-p (record since)
  (let* ((stamp (gethash "timestamp" record))
         (time (and (stringp stamp) (>= (length stamp) 19) (%parse-timestamp stamp))))
    (or (null time) (>= time since))))

(defun read-session (path &key since)
  "The SESSION in the transcript file PATH. See PARSE-SESSION-LINES."
  ;; A bad UTF-8 sequence, such as the half-written last line of a session still running, is
  ;; replaced rather than signalled, so one line cannot stop the report. jzon's default
  ;; 1 MiB limit on a string would skip the largest tool results without notice, so it is lifted.
  (with-open-file (in path :external-format '(:utf-8 :replacement #\?) :element-type 'character)
    (parse-session-lines (loop for line = (read-line in nil) while line collect line)
                         :since since)))

(defun later-calls (session result)
  "How many of SESSION's calls came after RESULT and before the next compaction or the end:
the number of times the model read RESULT again, from its context. The next compaction is the
first recorded after RESULT's own record, so a compaction and a result between the same two
calls are ordered by where they appear."
  (let* ((from (result-index result))
         (next (find-if (lambda (c) (> (car c) (result-line result)))
                        (session-compactions session)))
         (until (if next (cdr next) (length (session-calls session)))))
    (max 0 (- until from))))

(defun session-files (projects-directory &key since)
  "Every transcript under PROJECTS-DIRECTORY: <project>/<session>.jsonl, and the transcripts of
the subagents a session ran, <project>/<session>/subagents/*.jsonl. With SINCE, only files
modified at or after it."
  (let ((files (append (directory (merge-pathnames "*/*.jsonl" projects-directory))
                       (directory (merge-pathnames "*/*/subagents/*.jsonl" projects-directory)))))
    (if since
        (remove-if (lambda (f) (< (or (ignore-errors (file-write-date f)) 0) since)) files)
        files)))
