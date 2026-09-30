;;;; claude-code/report.lisp --- whether large tool outputs are a large share of a user's reads (#452).
;;;;
;;;; A TOOL RESULT IS READ AGAIN ON EVERY LATER CALL. It stays in the conversation, so each model
;;;; call after it reads it once more, usually from the prompt cache, until the session compacts
;;;; or ends. So what a result costs is its size times that number of calls, and that product is
;;;; what the report sums as "read again". Replacing a result with a summary saves its size less
;;;; the summary's, on every one of those calls.
;;;;
;;;; THE SAVING IS STATED AS A BOUND, NOT A PREDICTION. For each result the hook would replace,
;;;; it assumes the largest summary the hook's check accepts (the smaller of the summary budget
;;;; and 70% of the original), and that every such summary is accepted. The hook's own log gives
;;;; the rejection rate once it runs.
;;;;
;;;; COUNTS ONLY. The report prints numbers and categories: a tool's name, or `Bash:' and a
;;;; command's first word. It prints no text of any message or result and no path, including
;;;; the project directories' names, which are paths.

(in-package #:praxeon/claude-code/report)

(defparameter *default-days* 30 "How many days of transcripts REPORT reads by default.")

(defparameter *top* 15 "How many categories the report lists.")

(defun %largest-accepted-summary (tokens)
  (min rules:*summary-budget* (floor (* tokens (- 1 rules:*minimum-reduction*)))))

(defstruct (row (:constructor %make-row (category)))
  category
  (results 0) (tokens 0) (read-again 0)
  (above 0) (above-tokens 0) (above-read-again 0)
  (replace 0) (replace-tokens 0) (saving 0))

(defun summarize (sessions)
  "Aggregates over SESSIONS, a list of TR:SESSIONs, as a plist: the call totals, a ROW for all
results under :ALL, a list of ROWs by category under :ROWS (most read again first), and under
:PASS-REASONS an alist of (reason . count) for results above the threshold that the hook would
pass through."
  (let ((by (make-hash-table :test #'equal))
        (all (%make-row "all"))
        (reasons (make-hash-table))
        (calls 0) (input 0) (output 0) (cache-read 0) (cache-write 0))
    (dolist (s sessions)
      (dolist (c (tr:session-calls s))
        (incf calls)
        (incf input (tr:call-input c)) (incf output (tr:call-output c))
        (incf cache-read (tr:call-cache-read c)) (incf cache-write (tr:call-cache-write c)))
      (dolist (r (tr:session-results s))
        (let* ((tokens (tr:result-tokens r))
               (again (* tokens (tr:later-calls s r)))
               (above (>= tokens rules:*threshold-tokens*))
               (replace (eq (tr:result-decision r) :replace))
               (saving (if replace
                           (* (- tokens (%largest-accepted-summary tokens)) (tr:later-calls s r))
                           0))
               (row (or (gethash (tr:result-category r) by)
                        (setf (gethash (tr:result-category r) by)
                              (%make-row (tr:result-category r))))))
          (when (and above (not replace))
            (incf (gethash (tr:result-reason r) reasons 0)))
          (dolist (x (list row all))
            (incf (row-results x)) (incf (row-tokens x) tokens) (incf (row-read-again x) again)
            (when above
              (incf (row-above x)) (incf (row-above-tokens x) tokens)
              (incf (row-above-read-again x) again))
            (when replace
              (incf (row-replace x)) (incf (row-replace-tokens x) tokens)
              (incf (row-saving x) saving))))))
    (list :sessions (length sessions) :calls calls
          :input input :output output :cache-read cache-read :cache-write cache-write
          :all all
          :rows (sort (loop for r being the hash-values of by collect r) #'> :key #'row-read-again)
          :pass-reasons (sort (loop for k being the hash-keys of reasons using (hash-value v)
                                    collect (cons k v))
                              #'> :key #'cdr))))

(defun %share (part whole)
  (if (plusp whole) (format nil "~,1F%" (* 100 (/ part whole))) "-"))

(defparameter +reason-text+
  '((:tool . "not Bash or an MCP tool")
    (:not-search . "a Bash command that is not a search")
    (:exact . "a command that reads exactly (cat, sed, head, git, gh, ...)")
    (:failed . "failed, interrupted or wrote to stderr")
    (:diff . "contains a diff")
    (:credential . "looks like it carries a credential")
    (:identifiers . "carries a SHA-like or run-id-like token")))

(defun print-report (summary &key (stream *standard-output*) days)
  "Print SUMMARY, from SUMMARIZE, to STREAM."
  (let* ((all (getf summary :all))
         (read-side (+ (getf summary :input) (getf summary :cache-read) (getf summary :cache-write))))
    (format stream "praxeon-claude-code report~@[: the last ~D days~]~%" days)
    (format stream "~D transcripts (sessions and subagents), ~:D model calls.~%~%"
            (getf summary :sessions) (getf summary :calls))
    (format stream "Tokens in those calls, from their usage fields:~%")
    (format stream "  input ~:D, cache writes ~:D, cache reads ~:D, output ~:D~%~%"
            (getf summary :input) (getf summary :cache-write) (getf summary :cache-read)
            (getf summary :output))
    (format stream "Tool results (tokens estimated as characters / 4):~%")
    (format stream "  all:                        ~:D results, ~:D tokens, read again ~:D tokens~%"
            (row-results all) (row-tokens all) (row-read-again all))
    (format stream "  above ~:D tokens:           ~:D results, ~:D tokens, read again ~:D tokens (~A of all read again)~%"
            rules:*threshold-tokens* (row-above all) (row-above-tokens all)
            (row-above-read-again all) (%share (row-above-read-again all) (row-read-again all)))
    (format stream "  the hook would replace:     ~:D results, ~:D tokens~%"
            (row-replace all) (row-replace-tokens all))
    (format stream "~%If every one of those were replaced by the largest summary the hook accepts, the later calls~%")
    (format stream "would read ~:D fewer tokens: ~A of the ~:D input, cache-write and cache-read tokens above.~%"
            (row-saving all) (%share (row-saving all) read-side) read-side)
    (let ((reasons (getf summary :pass-reasons)))
      (when reasons
        (format stream "~%Results above ~:D tokens that the hook would pass through, by reason:~%"
                rules:*threshold-tokens*)
        (loop for (reason . n) in reasons
              do (format stream "  ~6:D  ~A~%" n (or (cdr (assoc reason +reason-text+)) reason)))))
    (format stream "~%By category, most read again first (top ~D):~%" *top*)
    (format stream "  ~32A ~8@A ~12@A ~8@A ~8@A ~14@A~%"
            "category" "results" "tokens" "above" "replace" "read again")
    (loop for r in (getf summary :rows)
          for i below *top*
          do (format stream "  ~32A ~8:D ~12:D ~8:D ~8:D ~14:D~%"
                     (let ((c (row-category r))) (if (> (length c) 32) (subseq c 0 32) c))
                     (row-results r) (row-tokens r) (row-above r) (row-replace r)
                     (row-read-again r)))
    summary))

(defun report (&key (projects-directory (merge-pathnames ".claude/projects/" (user-homedir-pathname)))
                    (days *default-days*) (threshold rules:*threshold-tokens*)
                    (stream *standard-output*))
  "Read the transcripts under PROJECTS-DIRECTORY from the last DAYS days and print their
aggregates. Returns the summary plist."
  (let* ((since (- (get-universal-time) (* days 86400)))
         (rules:*threshold-tokens* threshold)
         (sessions (mapcar (lambda (f) (tr:read-session f :since since))
                           (tr:session-files projects-directory :since since))))
    (print-report (summarize sessions) :stream stream :days days)))
