;;;; tool-results.lisp --- a tool-heavy task run with and without keeping results outside the
;;;; prompt (#319).
;;;;
;;;; Load praxeon, then this file, then call (praxeon/bench/tool-results:run-benchmark).
;;;;
;;;; THE TASK. The agent is asked for the code written on one of PAGES pages. It fetches every
;;;; page with a `fetch' tool; each page has one line "code: XXXX" at a random place. Then it
;;;; answers. The task succeeds when the answer holds that page's code. With :TASK :UNIFORM,
;;;; every page is about 1,500 estimated tokens. With :TASK :MIXED, the even-numbered pages are
;;;; about 375 estimated tokens, under the offload threshold, so that offloading and clearing
;;;; together have something to clear.
;;;;
;;;; THE CONFIGURATIONS. :FULL keeps every result in the prompt, as praxeon did before #319.
;;;; :OFFLOAD keeps results over a threshold outside the prompt, with a stand-in. :CLEAR keeps
;;;; each result whole when it arrives and clears older ones once the prompt passes a budget.
;;;; :CLEAR-WIDE is :CLEAR with a larger budget, so that a batch is not cleared after almost every
;;;; result. :OFFLOAD-AND-CLEAR does both; on the uniform task its figures are :OFFLOAD's.
;;;;
;;;; WHAT IS MEASURED, AND HOW. Two sets of token figures, computed different ways.
;;;;
;;;; The estimates. With the scripted model, input tokens are the sum, over every request of the
;;;; task, of the estimated tokens of the messages sent (PRAXEON/PROMPT:MESSAGES-TOKENS), and the
;;;; cached share is SIMULATED: a request's cached tokens are those of the longest run of
;;;; messages it shares, from the start, with the request before it, which is what a provider's
;;;; prefix cache could reuse. With a real provider, the estimate is the sum of each step's
;;;; :ESTIMATED-INPUT from its :USAGE event, and there is no simulated cache share. The actor
;;;; emits :USAGE only for a step whose provider reported a count, so with a provider that
;;;; reports none there is no estimate either.
;;;;
;;;; The provider's counts. The sums of :INPUT, :OUTPUT, :CACHE-READ and :CACHE-WRITE over the
;;;; :USAGE events of every task, as the provider reported them. Each is NIL when no step
;;;; reported it. Anthropic's :INPUT leaves out the tokens read from and written to the cache,
;;;; so the whole input of a request there is the sum of the three; an OpenAI-compatible
;;;; server's :INPUT includes its cached tokens. The benchmark adds nothing up across those
;;;; fields, and prints them as reported.
;;;;
;;;; A PARTIAL SUM IS MARKED. Each figure taken from :USAGE events comes with the number of
;;;; requests that reported it, beside the number of requests made. When fewer reported it than
;;;; were made, the report prints the figure with a `*', because it is the sum over those
;;;; requests only and the rest are unknown.
;;;;
;;;; Success is read from the answer. A task whose turn signalled an error counts as failed, and
;;;; the number of such tasks is reported; the error's text is not, so that nothing a provider
;;;; put in an error message reaches the output. The benchmark does not change logging:
;;;; praxeon/llm logs a failed request at warn with the error's text, as it does outside the
;;;; benchmark. For the Anthropic provider that text is the HTTP status and the response body,
;;;; and the request's headers, where the API key travels, are not in it.
;;;;
;;;; WITH NO PROVIDER, A SCRIPTED MODEL DRIVES THE TASK, and it knows the task: it fetches each
;;;; page, and when the page it needs is a stand-in it calls read-result with a search for
;;;; "code:". Its success rate therefore says that the tools make the answer reachable, and
;;;; nothing about whether a real model finds it. Pass :PROVIDER a real one to measure that;
;;;; the maintainer's rule on #316 and #319 is that a setting becomes a default only if a real
;;;; model's task success holds with it.

(cl:defpackage #:praxeon/bench/tool-results
  (:use #:cl)
  (:local-nicknames (#:actor #:praxeon/actor)
                    (#:llm #:praxeon/llm)
                    (#:res #:praxeon/results)
                    (#:prompt #:praxeon/prompt)
                    (#:evt #:praxeon/event))
  (:export #:run-benchmark #:+configurations+ #:*scripted-usage*))

(in-package #:praxeon/bench/tool-results)

(defparameter +configurations+
  '((:full)
    (:offload :threshold 500)
    (:clear :threshold nil :clear-budget 3000 :keep-recent 1)
    (:clear-wide :threshold nil :clear-budget 6000 :keep-recent 2)
    (:offload-and-clear :threshold 500 :clear-budget 1200 :keep-recent 1))
  "Each configuration's name and the keyword arguments given to OFFLOAD-TOOL-RESULTS; :FULL
calls it not at all. :CLEAR and :CLEAR-WIDE keep every result in the conversation when it
arrives and clear older ones in batches. On the uniform task every page is over the offload
threshold, so :OFFLOAD-AND-CLEAR has nothing left to clear there and its figures are
:OFFLOAD's; run it with :TASK :MIXED.")

(defvar *scripted-usage* nil
  "When true, the scripted model reports usage on each completion: the request's estimated
tokens as :INPUT, less the simulated cached tokens, which it reports as :CACHE-READ, the way
Anthropic counts them. It lets a test check the provider-count path against the estimates
without a real provider. A real provider ignores it.")

;;; --- the pages -----------------------------------------------------------------

(defun %code (random) (format nil "~36R" (+ 1000000 (random 50000000 random))))

(defun %page (index code random &optional (lines 100))
  "LINES numbered filler lines of about 60 characters, with \"code: CODE\" on one of them. 100
lines are about 1,500 estimated tokens."
  (let ((at (random (- lines 10) random)))
    (format nil "~{~A~^~%~}"
            (loop for line from 0 below lines
                  collect (if (= line at)
                              (format nil "code: ~A" code)
                              (format nil "page ~D, line ~D: ~A" index line
                                      (make-string 40 :initial-element #\.)))))))

;;; --- the scripted model --------------------------------------------------------

(defclass scripted-reader (llm:provider)
  ((pages :initarg :pages :reader reader-pages)
   (target :initarg :target :reader reader-target)
   (requests :initform '() :accessor reader-requests))
  (:documentation "A model that fetches every page, then reads the target page's code from the
conversation, or through read-result when the page is a stand-in."))

(defmethod llm:supports-tool-choice-p ((p scripted-reader)) t)

(defun %parts (messages)
  (loop for m in messages
        for c = (llm:content m)
        when (listp c) append c))

(defun %result-for (messages id)
  (getf (find-if (lambda (p) (and (eq (getf p :type) :tool-result)
                                  (equal (getf p :tool-use-id) id)))
                 (%parts messages))
        :content))

(defun %call (id name &rest kvs)
  (let ((args (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k args) v))
    (llm:make-completion :text "" :stop-reason :tool-use
                         :tool-calls (list (llm:make-tool-call :id id :name name :arguments args)))))

(defun %code-in (text)
  (let ((at (search "code: " text)))
    (and at (subseq text (+ at 6) (or (position-if (lambda (ch) (member ch '(#\Newline #\Space #\])))
                                                   text :start (+ at 6))
                                      (length text))))))

(defmethod llm:complete :around ((p scripted-reader) messages &key &allow-other-keys)
  (let ((completion (call-next-method)))
    (when *scripted-usage*
      (let* ((previous (second (reader-requests p)))
             (cached (%shared-prefix-tokens previous messages)))
        (setf (llm:completion-input-tokens completion) (- (prompt:messages-tokens messages) cached)
              (llm:completion-output-tokens completion) (prompt:estimate-tokens (llm:completion-text completion))
              (llm:completion-cache-read-tokens completion) cached
              (llm:completion-cache-write-tokens completion) 0)))
    completion))

(defmethod llm:complete ((p scripted-reader) messages &key system tools max-tokens temperature
                                                         tool-choice)
  (declare (ignore system tools max-tokens temperature tool-choice))
  (push messages (reader-requests p))
  (let* ((fetched (loop for i from 1 to (reader-pages p)
                        while (%result-for messages (format nil "fetch-~D" i))
                        count t))
         (target-id (format nil "fetch-~D" (reader-target p))))
    (cond
      ((< fetched (reader-pages p))
       (%call (format nil "fetch-~D" (1+ fetched)) "fetch" "page" (1+ fetched)))
      (t
       (let* ((page (%result-for messages target-id))
              (read (%result-for messages "read-1"))
              (code (or (and read (%code-in read))
                        (and page (not (search "kept outside the conversation" page))
                             (not (search "cleared to save space" page))
                             (%code-in page)))))
         (cond (code (llm:make-completion :text (format nil "The code is ~A." code) :stop-reason :end))
               ((and page (search "res-" page) (not read))
                (let ((at (search "res-" page)))
                  (%call "read-1" "read-result" "handle" (subseq page at (+ at 20)) "search" "code:")))
               (t (llm:make-completion :text "I could not find it." :stop-reason :end))))))))

;;; --- one task ------------------------------------------------------------------

(defun %shared-prefix-tokens (previous current)
  (if (null previous)
      0
      (loop for a in previous
            for b in current
            while (equal a b)
            sum (prompt:message-tokens b))))

(defun %page-lines (task index)
  (ecase task
    (:uniform 100)
    (:mixed (if (evenp index) 25 100))))

(defun %sum (a b)
  "A plus B where NIL means not reported: NIL only when both are."
  (if (or a b) (+ (or a 0) (or b 0)) nil))

(defparameter +usage-fields+ '(:input :output :cache-read :cache-write :estimated-input)
  "The fields of a :USAGE event the benchmark adds up.")

(defun %tally (tally event)
  "TALLY with EVENT's fields added: for each field, the sum of the values reported and the
number of requests that reported one."
  (loop for key in +usage-fields+
        for (sum . count) = (getf tally key '(nil . 0))
        for value = (evt:event-get event key)
        append (list key (if value (cons (%sum sum value) (1+ count)) (cons sum count)))))

(defun %run-task (configuration task pages random provider)
  (destructuring-bind (name &rest keys) configuration
    (let* ((codes (loop repeat pages collect (%code random)))
           (texts (loop for i from 1 to pages for c in codes
                        collect (%page i c random (%page-lines task i))))
           (target (1+ (random pages random)))
           (model (or provider (make-instance 'scripted-reader :pages pages :target target)))
           (agent (actor:make-agent :provider model :history-budget nil))
           (steps 0) (batches 0)
           (tally '())
           (outer evt:*observer*))
      (actor:register-means agent "fetch" "Fetch a page by its number, from 1."
                            (lambda (args) (nth (1- (gethash "page" args)) texts)))
      (unless (eq name :full)
        (apply #'actor:offload-tool-results agent (res:make-memory-result-store) keys))
      (let ((answer (evt:with-observer
                        ((lambda (event)
                           (case (evt:event-type event)
                             (:deliberating (incf steps))
                             (:results-cleared (incf batches))
                             (:usage (setf tally (%tally tally event))))
                           (when outer (funcall outer event))))
                      (handler-case
                          (actor:run-turn agent
                                          (format nil "Fetch pages 1 to ~D with the fetch tool, one at a time, and then tell me the code written on page ~D." pages target)
                                          :max-steps (+ pages 4))
                        (error () :error)))))
        (let* ((requests (if provider '() (reverse (reader-requests model))))
               (input (if provider
                          (car (getf tally :estimated-input))
                          (loop for r in requests sum (prompt:messages-tokens r))))
               (cached (and (not provider)
                            (loop for previous = nil then r
                                  for r in requests
                                  sum (%shared-prefix-tokens previous r)))))
          (list :success (and (stringp answer) (search (nth (1- target) codes) answer) t)
                :error (eq answer :error)
                :requests steps
                :clear-batches batches
                :input-tokens input
                :input-requests (if provider (cdr (getf tally :estimated-input '(nil . 0))) steps)
                :cached-tokens cached
                :tally tally))))))

;;; --- the benchmark -------------------------------------------------------------

(defun %row (configuration tasks runs)
  (let ((input (reduce #'%sum runs :key (lambda (r) (getf r :input-tokens)) :initial-value nil))
        (cached (and (getf (first runs) :cached-tokens)
                     (reduce #'+ runs :key (lambda (r) (getf r :cached-tokens))))))
    (list* :configuration (first configuration)
           :tasks tasks
           :succeeded (count-if (lambda (r) (getf r :success)) runs)
           :errors (count-if (lambda (r) (getf r :error)) runs)
           :requests (reduce #'+ runs :key (lambda (r) (getf r :requests)))
           :clear-batches (reduce #'+ runs :key (lambda (r) (getf r :clear-batches)))
           :input-tokens input
           :input-requests (reduce #'+ runs :key (lambda (r) (getf r :input-requests)))
           :cached-share (and cached (if (plusp input) (/ cached input) 0))
           (loop for (key name requests) in '((:input :reported-input :reported-input-requests)
                                              (:output :reported-output :reported-output-requests)
                                              (:cache-read :reported-cache-read
                                               :reported-cache-read-requests)
                                              (:cache-write :reported-cache-write
                                               :reported-cache-write-requests))
                 for cells = (mapcar (lambda (r) (getf (getf r :tally) key '(nil . 0))) runs)
                 append (list name (reduce #'%sum cells :key #'car :initial-value nil)
                              requests (reduce #'+ cells :key #'cdr))))))

(defun %field (value reported requests)
  "VALUE as printed: `-' when no request reported it, and marked `*' when fewer than REQUESTS
did, because it is then a partial sum."
  (cond ((null value) "-")
        ((< reported requests) (format nil "~D*" value))
        (t (format nil "~D" value))))

(defun %partial-p (rows)
  (some (lambda (r)
          (or (and (getf r :input-tokens) (< (getf r :input-requests) (getf r :requests)))
              (loop for key in '(:reported-input :reported-cache-read :reported-cache-write
                                 :reported-output)
                    for count in '(:reported-input-requests :reported-cache-read-requests
                                   :reported-cache-write-requests :reported-output-requests)
                    thereis (and (getf r key) (< (getf r count) (getf r :requests))))))
        rows))

(defun %report (rows stream task tasks pages seed provider)
  (format stream "~&~A tasks of ~A pages, task ~(~A~), seed ~A, ~:[scripted model; the estimated cache share is simulated~;real provider~]~%"
          tasks pages task seed provider)
  (format stream "~&~18A ~10A ~6A ~8A ~7A ~11A ~7A~%"
          "configuration" "succeeded" "errors" "requests" "batches" "est. input" "cached")
  (dolist (r rows)
    (format stream "~&~18A ~3D of ~3D ~6D ~8D ~7D ~11@A ~7A~%"
            (string-downcase (getf r :configuration)) (getf r :succeeded) (getf r :tasks)
            (getf r :errors) (getf r :requests) (getf r :clear-batches)
            (%field (getf r :input-tokens) (getf r :input-requests) (getf r :requests))
            (if (getf r :cached-share)
                (format nil "~,1F%" (* 100 (float (getf r :cached-share))))
                "-")))
  (format stream "~&Token counts the provider reported (- where it reported none):~%")
  (format stream "~&~18A ~11A ~11A ~11A ~11A~%" "configuration" "input" "cache read" "cache write" "output")
  (dolist (r rows)
    (format stream "~&~18A ~11A ~11A ~11A ~11A~%"
            (string-downcase (getf r :configuration))
            (%field (getf r :reported-input) (getf r :reported-input-requests) (getf r :requests))
            (%field (getf r :reported-cache-read) (getf r :reported-cache-read-requests)
                    (getf r :requests))
            (%field (getf r :reported-cache-write) (getf r :reported-cache-write-requests)
                    (getf r :requests))
            (%field (getf r :reported-output) (getf r :reported-output-requests)
                    (getf r :requests))))
  (when (%partial-p rows)
    (format stream "~&* Fewer requests reported this figure than were made, so it is the sum over the requests that did.~%")))

(defun run-benchmark (&key (tasks 20) (pages 6) (seed 316) (task :uniform) provider
                           (configurations +configurations+) (stream *standard-output*))
  "Run TASKS tasks of PAGES pages under each of CONFIGURATIONS and report, for each, how many
succeeded, how many signalled an error, the requests, the clearing batches, the estimated input
tokens and the simulated cached share, and the token counts the provider reported. TASK is
:UNIFORM or :MIXED. Returns one plist per configuration.

With PROVIDER NIL a scripted model drives the task; see this file's commentary for what its
numbers can and cannot say. Every configuration starts from the same SEED, so each one is
given the same pages and is asked for the same page."
  (check-type task (member :uniform :mixed))
  (let ((rows
          (loop for configuration in configurations
                collect (let ((random (sb-ext:seed-random-state seed))
                              (runs '()))
                          (dotimes (i tasks)
                            (push (%run-task configuration task pages random provider) runs))
                          (%row configuration tasks (reverse runs))))))
    (%report rows stream task tasks pages seed provider)
    rows))
