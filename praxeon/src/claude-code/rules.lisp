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
;;;; quoted from a summary is a guess. The command list keeps git and gh out. The content rule
;;;; refuses any output in which the matched lines carry a SHA-like token (7 to 64 hexadecimal
;;;; characters with digits and letters) or a run-id-like one (10 or more digits), whichever
;;;; command produced it. That covers a search over a saved log only when the lines it matched
;;;; carry one: the gate prints SHAs in its provenance block, so a search that matches only its
;;;; suite lines is not refused by this rule.

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
          (let* ((word (string-trim "\"'" word))
                 (slash (position-if (lambda (c) (member c '(#\/ #\\))) word :from-end t)))
            (return (if slash (subseq word (1+ slash)) word))))))))

(defun tool-category (tool input)
  "The category a result of TOOL, called with INPUT (a hash table or NIL), is counted under in
the report and the hook's log: \"Bash:<word>\" for Bash, \"mcp\" for any MCP tool, and the
tool's name otherwise.

NO PATH OR PRIVATE NAME, because the report is what a user will paste into an issue. A command
word is its base name only (BASH-CATEGORY), and one with a dot in it, such as tool.exe or
export.sh, is counted as \"script\", since a script's name can name a client or a project. An
MCP tool's name carries its server's name, so every MCP tool is \"mcp\"."
  (cond ((string= tool "Bash")
         (let* ((command (and (hash-table-p input) (gethash "command" input)))
                (word (if (stringp command) (bash-category command) "")))
           (format nil "Bash:~A" (if (find #\. word) "script" word))))
        ((and (> (length tool) (length *mcp-prefix*))
              (string= *mcp-prefix* tool :end2 (length *mcp-prefix*)))
         "mcp")
        (t tool)))

;;; --- the command -------------------------------------------------------------------------

(defparameter +exact-words+
  '("cat" "tac" "nl" "bat" "sed" "awk" "perl" "head" "tail" "less" "more" "view" "strings" "od"
    "xxd" "hexdump" "git" "gh" "diff" "patch" "jq" "yq" "sbcl" "make" "python" "python3" "node"
    "npm" "curl" "wget" "xargs" "while" "for" "do" "until" "sh" "bash" "zsh" "eval" "source")
  "Words that, anywhere in a Bash command, mean its output is read exactly or is not a list of
matches: a read or print command (cat, sed -n, head, ...), git and gh, which print SHAs and run
ids, a program's own output, and xargs, loops and shells, which run some other command on what
the search found.")

(defparameter +exact-flags+
  '("-exec" "-execdir" "-ok" "-okdir" "--passthru" "--passthrough" "-v" "--invert-match"
    "-f" "--file" "-z" "--null-data")
  "Arguments that make a search print whole files or run a command: find's -exec and -ok, rg's
--passthru, grep -v, patterns read from a file, and whole-file records.")

(defparameter +whole-file-patterns+ '("" "^" "$" "." ".*" "^.*" ".*$" "^.*$")
  "Patterns that match every line, so a search with one prints whole files.")

(defun %shell-words (command)
  "COMMAND's words, split at unquoted whitespace and at | ; & ( ), with quotes removed. A quoted
empty string is a word of its own, \"\", so rg '' file is seen as a search for the empty pattern."
  (let ((words '()) (word (make-string-output-stream)) (in-word nil) (quote nil))
    (flet ((finish ()
             (when in-word (push (get-output-stream-string word) words) (setf in-word nil))))
      (loop for c across command
            do (cond (quote (if (char= c quote) (setf quote nil) (write-char c word)))
                     ((member c '(#\' #\")) (setf quote c in-word t))
                     ((member c '(#\Space #\Tab #\Newline #\| #\; #\& #\( #\))) (finish))
                     (t (write-char c word) (setf in-word t))))
      (finish))
    (nreverse words)))

(defun %command-words (command)
  "The first word of every segment of COMMAND, with variable assignments and directory changes
skipped, as BASH-CATEGORY finds the first."
  (loop for segment in (%segments command)
        for word = (bash-category segment)
        when (plusp (length word)) collect word))

(defun %search-pattern (words)
  "The pattern a search command's WORDS give it: the value after -e or --regexp, or else the
first word after the command that is not a flag. NIL for find, which takes no pattern. Only the
pattern is compared with +WHOLE-FILE-PATTERNS+, since a path such as . is not one."
  (let ((command (first words)) (args (rest words)))
    (when (member command '("rg" "grep" "fd") :test #'string=)
      (let ((e (or (member "-e" args :test #'string=) (member "--regexp" args :test #'string=))))
        (if e
            (second e)
            (find-if (lambda (w) (or (zerop (length w)) (char/= (char w 0) #\-))) args))))))

(defun command-eligible-p (command)
  "Whether a Bash COMMAND is one whose output may be replaced: its first command is in
*SEARCH-COMMANDS*, no word anywhere in it is in +EXACT-WORDS+ or +EXACT-FLAGS+, and no word is a
pattern in +WHOLE-FILE-PATTERNS+. Returns the reason as a second value when it is not:
:NOT-SEARCH or :EXACT. A word is compared by its last path component, so /bin/cat is cat."
  (let ((words (mapcar (lambda (w) (let ((slash (position #\/ w :from-end t)))
                                     (if (and slash (< slash (1- (length w)))) (subseq w (1+ slash)) w)))
                       (%shell-words command))))
    (cond ((not (member (first (%command-words command)) *search-commands* :test #'string=))
           (values nil :not-search))
          ((some (lambda (w) (or (member w +exact-words+ :test #'string=)
                                 (member w +exact-flags+ :test #'string=)))
                 words)
           (values nil :exact))
          ((let ((pattern (%search-pattern words)))
             (and pattern (member pattern +whole-file-patterns+ :test #'string=)))
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
  '("-----BEGIN" "PRIVATE KEY" "AKIA" "ASIA" "ghp_" "gho_" "ghs_" "ghu_" "ghr_" "github_pat_"
    "glpat-" "xoxb-" "xoxp-" "xoxa-" "xoxs-" "hooks.slack.com/services/" "sk-ant-" "sk-proj-"
    "sk_live_" "sk_test_" "rk_live_" "pk_live_" "AIza" "hf_" "npm_" "_authToken" "Bearer "
    "Authorization:" "aws_secret" "aws_session_token" "password" "passwd" "pwd=" "api_key"
    "apikey" "api-key" "secret" "token=" "token:" "_token" "private_key" "credentials"
    "machine " "eyJ")
  "Substrings that mark text as possibly carrying a credential, matched without regard to
case: key prefixes of common services, header and assignment names, a Slack webhook's path, a
.netrc line (machine ... password), and the start of a JWT (eyJ). They err towards matching,
since a false match only passes the output through.")

(defun %url-with-password-p (text)
  "Whether TEXT holds a URL with a password in it, scheme://user:password@host."
  (loop for at = (search "://" text) then (search "://" text :start2 (1+ at))
        while at
        thereis (let* ((start (+ at 3))
                       (end (or (position-if (lambda (c) (member c '(#\Space #\Tab #\Newline #\/ #\" #\')))
                                             text :start start)
                                (length text)))
                       (colon (position #\: text :start start :end end))
                       (sign (position #\@ text :start start :end end)))
                  (and colon sign (< colon sign)))))

(defun credential-like-p (text)
  "Whether TEXT contains one of +CREDENTIAL-MARKERS+, ignoring case, or a URL with a password."
  (or (some (lambda (m) (search m text :test #'char-equal)) +credential-markers+)
      (%url-with-password-p text)))

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
    ;; THE COMMAND TOO, because it goes into the summarizer's prompt: GITHUB_TOKEN=ghp_... rg x
    ;; would otherwise send the token.
    (when (or (credential-like-p text)
              (and (hash-table-p input) (stringp (gethash "command" input))
                   (credential-like-p (gethash "command" input))))
      (pass :credential))
    (when (identifier-like-p text) (pass :identifiers))
    :replace))
