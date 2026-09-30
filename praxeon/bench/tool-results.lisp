;;;; tool-results.lisp --- a tool-heavy task run with and without keeping results outside the
;;;; prompt (#319).
;;;;
;;;; Load praxeon, then this file, then call (praxeon/bench/tool-results:run-benchmark).
;;;;
;;;; THE TASK. The agent is asked for the code written on one of PAGES pages. It fetches every
;;;; page with a `fetch' tool; each page is about 1,500 estimated tokens and has one line
;;;; "code: XXXX" at a random place. Then it answers. The task succeeds when the answer holds
;;;; that page's code.
;;;;
;;;; THE CONFIGURATIONS. :FULL keeps every result in the prompt, as praxeon did before #319.
;;;; :OFFLOAD keeps results over a threshold outside the prompt, with a stand-in. :CLEAR keeps
;;;; each result whole when it arrives and clears older ones once the prompt passes a budget.
;;;;
;;;; WHAT IS MEASURED, AND HOW. Input tokens are the sum, over every request of the task, of the
;;;; estimated tokens of the messages sent (PRAXEON/PROMPT:MESSAGES-TOKENS), so they are an
;;;; estimate, not a provider's count. The cached share is SIMULATED: a request's cached tokens
;;;; are those of the longest run of messages it shares, from the start, with the request
;;;; before it, which is what a provider's prefix cache could reuse. Success is read from the
;;;; answer.
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
                    (#:prompt #:praxeon/prompt))
  (:export #:run-benchmark #:+configurations+))

(in-package #:praxeon/bench/tool-results)

(defparameter +configurations+
  '((:full)
    (:offload :threshold 500)
    (:clear :threshold nil :clear-budget 3000 :keep-recent 1))
  "Each configuration's name and the keyword arguments given to OFFLOAD-TOOL-RESULTS; :FULL
calls it not at all. :CLEAR keeps every result in the conversation when it arrives and clears
older ones in batches. Offloading and clearing together are not a separate configuration here:
every page of this task is over the offload threshold, so with both there is nothing left to
clear, and the figures are :OFFLOAD's.")

;;; --- the pages -----------------------------------------------------------------

(defun %code (random) (format nil "~36R" (+ 1000000 (random 50000000 random))))

(defun %page (index code random)
  "About 6,000 characters of numbered filler lines, with \"code: CODE\" on one of them."
  (let ((at (random 90 random)))
    (format nil "~{~A~^~%~}"
            (loop for line from 0 below 100
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

(defun %run-task (configuration pages random provider)
  (destructuring-bind (name &rest keys) configuration
    (let* ((codes (loop repeat pages collect (%code random)))
           (texts (loop for i from 1 to pages for c in codes collect (%page i c random)))
           (target (1+ (random pages random)))
           (model (or provider (make-instance 'scripted-reader :pages pages :target target)))
           (agent (actor:make-agent :provider model :history-budget nil))
           (requests '()))
      (actor:register-means agent "fetch" "Fetch a page by its number, from 1."
                            (lambda (args) (nth (1- (gethash "page" args)) texts)))
      (unless (eq name :full)
        (apply #'actor:offload-tool-results agent (res:make-memory-result-store) keys))
      (let ((answer (handler-case
                        (actor:run-turn agent
                                        (format nil "Fetch pages 1 to ~D with the fetch tool, one at a time, and then tell me the code written on page ~D." pages target)
                                        :max-steps (+ pages 4))
                      (error (e) (format nil "error: ~A" e)))))
        (setf requests (if provider '() (reverse (reader-requests model))))
        (let* ((input (loop for r in requests sum (prompt:messages-tokens r)))
               (cached (loop for previous = nil then r
                             for r in requests
                             sum (%shared-prefix-tokens previous r))))
          (list :success (and (stringp answer) (search (nth (1- target) codes) answer) t)
                :requests (length requests)
                :input-tokens input
                :cached-tokens cached))))))

;;; --- the benchmark -------------------------------------------------------------

(defun run-benchmark (&key (tasks 20) (pages 6) (seed 316) provider
                           (configurations +configurations+) (stream *standard-output*))
  "Run TASKS tasks of PAGES pages under each of CONFIGURATIONS and report, for each, how many
succeeded, the input tokens and the cached share. Returns one plist per configuration.

With PROVIDER NIL a scripted model drives the task; see this file's commentary for what its
numbers can and cannot say. With a real PROVIDER, the token figures are not collected here:
read them from the :USAGE events or the provider's own counts."
  (let ((rows
          (loop for configuration in configurations
                collect (let ((random (sb-ext:seed-random-state seed))
                              (runs '()))
                          (dotimes (i tasks) (push (%run-task configuration pages random provider) runs))
                          (let ((input (reduce #'+ runs :key (lambda (r) (getf r :input-tokens))))
                                (cached (reduce #'+ runs :key (lambda (r) (getf r :cached-tokens)))))
                            (list :configuration (first configuration)
                                  :tasks tasks
                                  :succeeded (count-if (lambda (r) (getf r :success)) runs)
                                  :input-tokens input
                                  :cached-share (if (plusp input) (/ cached input) 0)))))))
    (format stream "~&~A tasks of ~A pages, seed ~A, ~:[scripted model; tokens are estimates and the cache is simulated~;real provider~]~%"
            tasks pages seed provider)
    (format stream "~&~16A ~10A ~14A ~12A~%" "configuration" "succeeded" "input tokens" "cached share")
    (dolist (r rows)
      (format stream "~&~16A ~3D of ~3D ~14D ~11,1F%~%"
              (string-downcase (getf r :configuration)) (getf r :succeeded) (getf r :tasks) (getf r :input-tokens)
              (* 100 (float (getf r :cached-share)))))
    rows))
