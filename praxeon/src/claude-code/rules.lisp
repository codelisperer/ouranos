;;;; claude-code/rules.lisp --- which tool outputs may be replaced by a summary (#452).
;;;;
;;;; ONE FUNCTION DECIDES, AND BOTH COMMANDS CALL IT. The hook calls ELIGIBILITY on the event it
;;;; is given; the report calls it on each result while reading a transcript, so the share the
;;;; report prints is the share the hook would replace, not an estimate made by other rules.
;;;;
;;;; THE RULES ERR TOWARDS PASSING THE OUTPUT THROUGH. A replaced output that the model needed
;;;; exactly is a wrong answer later; an output passed through costs tokens. So every rule that
;;;; can say no is checked, and the order only decides which reason is reported.
;;;;
;;;; WHAT THIS REPOSITORY NEEDS READ EXACTLY (#452, AGENTS.md "Evidence"): the gate's output, CI
;;;; logs, `git log', and anything carrying a commit SHA or a run id, because a SHA or an id
;;;; quoted from a summary is a guess. The command list keeps git and gh out, and the content
;;;; rules refuse any output that carries a SHA-like or run-id-like token, whichever command
;;;; produced it, so `grep' over a saved gate log is refused as well.

(in-package #:praxeon/claude-code/rules)

(defparameter *threshold-tokens* 3500
  "Outputs estimated below this many tokens (characters / 4) are never replaced.")

(defparameter *summary-budget* 1800
  "The largest summary the hook accepts, in tokens (PRAXEON_CC_SUMMARY_BUDGET). The report
assumes summaries of this size when it bounds the saving.")

(defparameter *minimum-reduction* 3/10
  "The hook refuses a summary less than this fraction smaller than the raw output.")

(defparameter *search-commands* '("rg" "grep" "find" "fd")
  "The Bash command words whose output may be replaced: search commands, whose output is a
list of matches the model will mostly not quote.")

(defparameter *mcp-prefix* "mcp__"
  "An MCP tool's name starts with this; MCP tools' results may be replaced.")

(defun estimate-tokens (characters)
  "Tokens for CHARACTERS characters of text, as #452 estimates them: characters / 4, rounded up."
  (ceiling characters 4))

;;; --- categories ------------------------------------------------------------------------

(defun %words (string)
  (let ((words '()) (start nil))
    (loop for i from 0 below (length string)
          for c = (char string i)
          do (if (member c '(#\Space #\Tab #\Newline #\Return))
                 (when start (push (subseq string start i) words) (setf start nil))
                 (unless start (setf start i))))
    (when start (push (subseq string start) words))
    (nreverse words)))

(defun %segments (command)
  "COMMAND split at `&&', `||', `;' and `|', outside no quoting at all: a category only needs
the first word of each segment, and a quoted separator at worst moves which word that is."
  (let ((segments '()) (start 0) (i 0) (n (length command)))
    (loop while (< i n)
          do (let ((c (char command i)))
               (cond ((and (< (1+ i) n) (member (subseq command i (+ i 2)) '("&&" "||") :test #'string=))
                      (push (subseq command start i) segments)
                      (setf start (+ i 2)) (incf i 2))
                     ((member c '(#\; #\| #\Newline))
                      (push (subseq command start i) segments)
                      (setf start (1+ i)) (incf i))
                     (t (incf i)))))
    (push (subseq command start) segments)
    (nreverse segments)))

(defun bash-category (command)
  "The word a Bash COMMAND is counted under: the first word of its first segment that does not
only change directory or set a variable. `cd x && rg foo' counts as rg, and `FOO=1 make' as
make, because a report that grouped most commands under `cd' would say nothing. A path is
reduced to its last component, so /usr/bin/rg is rg. \"\" when there is no word."
  (dolist (segment (%segments command) "")
    (let ((words (%words segment)))
      (loop while (and words (position #\= (first words))
                       (not (eql 0 (position #\= (first words)))))
            do (pop words))
      ;; A wrapper that runs the command after it is not the command: `timeout 60 rg x' is rg.
      (loop while (and words (member (first words) '("timeout" "time" "env" "nohup" "nice" "exec")
                                     :test #'string=))
            do (pop words)
               (loop while (and words (or (char= (char (first words) 0) #\-)
                                          (every #'digit-char-p (string-right-trim "smhd" (first words)))
                                          (position #\= (first words))))
                     do (pop words)))
      (let ((word (first words)))
        (when (and word (not (member word '("cd" "pushd" "popd" "export" "set" "(" "{")
                                     :test #'string=)))
          (let ((slash (position #\/ word :from-end t)))
            (return (if slash (subseq word (1+ slash)) word))))))))

(defun tool-category (tool input)
  "The category a result of TOOL, called with INPUT (a hash table or NIL), is counted under:
\"Bash:<word>\" for Bash, and the tool's name otherwise, which for an MCP tool is
mcp__<server>__<tool>."
  (if (string= tool "Bash")
      (let ((command (and (hash-table-p input) (gethash "command" input))))
        (format nil "Bash:~A" (if (stringp command) (bash-category command) "")))
      tool))

;;; --- the command -------------------------------------------------------------------------

(defparameter +exact-words+
  '("cat" "sed" "head" "tail" "less" "more" "git" "gh" "diff" "patch" "jq" "sbcl" "make"
    "python" "python3" "node" "npm" "curl" "wget")
  "Command words that, anywhere in a Bash command, mean its output is read exactly or is not a
search: a pipeline through `head' is already narrowed, `git' and `gh' print SHAs and run ids,
and a program's own output is not a list of matches.")

(defun %command-words (command)
  "The first word of every segment of COMMAND, with variable assignments and directory changes
skipped, as BASH-CATEGORY finds the first."
  (loop for segment in (%segments command)
        for word = (bash-category segment)
        when (plusp (length word)) collect word))

(defun command-eligible-p (command)
  "Whether a Bash COMMAND is one whose output may be replaced: its first word is in
*SEARCH-COMMANDS* and none of its segments starts with a word in +EXACT-WORDS+. Returns the
reason as a second value when it is not: :NOT-SEARCH or :EXACT."
  (let ((words (%command-words command)))
    (cond ((not (member (first words) *search-commands* :test #'string=))
           (values nil :not-search))
          ((some (lambda (w) (member w +exact-words+ :test #'string=)) words)
           (values nil :exact))
          (t (values t nil)))))

;;; --- the content -------------------------------------------------------------------------

(defun %hex-digit-p (c) (digit-char-p c 16))

(defun %word-char-p (c) (or (alphanumericp c) (char= c #\_)))

(defun identifier-like-p (text)
  "Whether TEXT carries a token that looks like a commit SHA or a run id: a run of 7 to 64
hexadecimal characters containing both a digit and a letter, or a run of 10 or more digits,
with no letter, digit or underscore on either side."
  (let ((n (length text)) (i 0))
    (loop while (< i n)
          do (if (and (%word-char-p (char text i))
                      (or (= i 0) (not (%word-char-p (char text (1- i))))))
                 (let ((end (or (position-if-not #'%word-char-p text :start i) n)))
                   (let* ((len (- end i))
                          (all-hex (loop for j from i below end always (%hex-digit-p (char text j))))
                          (digits (loop for j from i below end count (digit-char-p (char text j)))))
                     (when (or (and all-hex (<= 7 len 64) (plusp digits) (< digits len))
                               (and (= digits len) (>= len 10)))
                       (return-from identifier-like-p t)))
                   (setf i end))
                 (incf i)))
    nil))

(defparameter +credential-markers+
  '("-----BEGIN" "PRIVATE KEY" "AKIA" "ASIA" "ghp_" "gho_" "ghs_" "ghu_" "github_pat_"
    "glpat-" "xoxb-" "xoxp-" "sk-ant-" "sk-proj-" "Bearer " "Authorization:" "aws_secret"
    "password=" "password:" "passwd" "api_key" "apikey" "api-key" "secret_key" "client_secret"
    "access_token" "refresh_token" "private_key")
  "Substrings that mark text as possibly carrying a credential, matched without regard to
case. Output with one of them is never replaced and never sent to a second model.")

(defun credential-like-p (text)
  "Whether TEXT contains one of +CREDENTIAL-MARKERS+, ignoring case."
  (some (lambda (m) (search m text :test #'char-equal)) +credential-markers+))

(defun %line-starts (text prefix)
  (or (and (>= (length text) (length prefix)) (string= prefix text :end2 (length prefix)))
      (search (concatenate 'string (string #\Newline) prefix) text)))

(defun diff-like-p (text)
  "Whether TEXT contains a unified diff: a line starting with `diff --git', `@@ ' or `+++ '."
  (or (%line-starts text "diff --git") (%line-starts text "@@ ") (%line-starts text "+++ ")))

;;; --- the decision ------------------------------------------------------------------------

(defun eligibility (tool input text &key error-p stderr interrupted (threshold *threshold-tokens*))
  "Whether the output TEXT of TOOL, called with INPUT (a hash table or NIL), may be replaced by
a summary. Returns :REPLACE, or :PASS and the reason as a keyword:

  :TOOL         the tool is not Bash or an MCP tool
  :NOT-SEARCH   a Bash command that is not a search (*SEARCH-COMMANDS*)
  :EXACT        a Bash command that reads exactly or is not a list of matches (+EXACT-WORDS+)
  :FAILED       the call failed, was interrupted, or wrote to stderr
  :SMALL        under THRESHOLD tokens
  :DIFF         the output contains a diff
  :CREDENTIAL   the output looks like it carries a credential
  :IDENTIFIERS  the output carries a SHA-like or run-id-like token"
  (flet ((pass (why) (return-from eligibility (values :pass why))))
    (cond ((string= tool "Bash")
           (let ((command (and (hash-table-p input) (gethash "command" input))))
             (unless (stringp command) (pass :not-search))
             (multiple-value-bind (ok why) (command-eligible-p command)
               (unless ok (pass why)))))
          ((and (> (length tool) (length *mcp-prefix*))
                (string= *mcp-prefix* tool :end2 (length *mcp-prefix*))))
          (t (pass :tool)))
    (when (or error-p interrupted (and (stringp stderr) (plusp (length stderr))))
      (pass :failed))
    (when (< (estimate-tokens (length text)) threshold) (pass :small))
    (when (diff-like-p text) (pass :diff))
    (when (credential-like-p text) (pass :credential))
    (when (identifier-like-p text) (pass :identifiers))
    :replace))
