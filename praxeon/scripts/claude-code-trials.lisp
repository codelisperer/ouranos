;;;; claude-code-trials.lisp --- the hook's real-output trials for #465, with fixed questions.
;;;;
;;;; Run from the repository root:
;;;;   sbcl --non-interactive --load praxeon/scripts/claude-code-trials.lisp            # offline
;;;;   PRAXEON_CC_TRIALS=run sbcl --non-interactive --load praxeon/scripts/claude-code-trials.lisp
;;;;
;;;; OFFLINE BY DEFAULT. Without PRAXEON_CC_TRIALS=run this calls no model: it runs the three
;;;; searches, checks each is eligible, runs the grouped path (which needs no model), measures it,
;;;; and prints how many model calls the full run would make. With PRAXEON_CC_TRIALS=run it also
;;;; asks the backend BACKEND-FROM-ENV configures (by default the `claude' CLI, which uses the
;;;; Claude Code login of whoever runs it) to select lines, PRAXEON_CC_TRIAL_ROUNDS times (default
;;;; 2) for each search, with the grouping turned off so the model's selection is what is measured.
;;;;
;;;; WHAT IS MEASURED, per search and round: whether the replacement was accepted, the reason when
;;;; it was not, how it was made (grouped or selected), the raw and replacement sizes, and how many
;;;; of the search's five questions the replacement still answers. A question is answered when the
;;;; one line of the output that answers it is in the replacement, whole. The questions were fixed
;;;; on 2026-10-24, before any model run, by taking the lines at 10%, 30%, 50%, 70% and 90% of each
;;;; output, so they were not chosen to suit either path.
;;;;
;;;; Nothing here prints the output or the replacement. The archive goes to a fresh temporary
;;;; directory, which is deleted at the end.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(ql:quickload :praxeon/claude-code :silent t)

(defpackage #:praxeon/claude-code/trials
  (:use #:cl)
  (:local-nicknames (#:hook #:praxeon/claude-code/hook)
                    (#:rules #:praxeon/claude-code/rules)
                    (#:jzon #:com.inuoe.jzon)))

(in-package #:praxeon/claude-code/trials)

(defparameter *searches*
  ;; (name command questions), each question (text path start-of-line).
  '(("T1, a listing of definitions" "rg -n \"defun %\" klio mnemosyne/src"
     (("Where is %check-xtdb defined?" "mnemosyne/src/query.lisp" "(defun %check-xtdb (ctx q)")
      ("Which function reads a SQLite table's columns?" "mnemosyne/src/introspect.lisp"
       "(defun %sqlite-columns (connection table)")
      ("Where is %check-not-xtdb defined, and what does it take?" "mnemosyne/src/ddl.lisp"
       "(defun %check-not-xtdb (dialect operation)")
      ("Which klio function exports one file, and with which arguments?" "klio/src/export.lisp"
       "(defun %export-file (path layout document-keys)")
      ("Where is %strip-all defined?" "klio/src/comments.lisp" "(defun %strip-all (text)")))
    ("T2, a search of prose" "rg -n -i webview hyperion/docs docs"
     (("What does the Hyperion wiki page say the webview does?" "docs/wiki/Framework-Hyperion.md"
       "pointed at that URL. The webview is a pure renderer")
      ("What does desktop.md say about a webview that does not send Sec-Fetch-Site?"
       "hyperion/docs/desktop.md" "  `Sec-Fetch-Site: same-origin` or `none`. A webview that does not")
      ("What status does the launch list give the native desktop Coalton REPL?"
       "docs/launch/open-questions.md" "| **Native desktop Coalton REPL** | Built, runs, installs |")
      ("Which shell does multi-target-ux.md list first?" "hyperion/docs/research/multi-target-ux.md"
       "1. **Webview + native-nav shell (Hotwire-Native pattern), htmx inside.**")
      ("Which operating-system webviews does ADR 0008 name?"
       "hyperion/docs/adr/0008-desktop-shell-cl-native-webview.md"
       "table; FFI to the **OS-native webview** (WebView2 on Windows")))
    ("T3, a mixed search of code and prose" "rg -n -i spinneret hyperion"
     (("Where is the one place that configures how Spinneret formats output?"
       "hyperion/src/packages.lisp" "   \"The single place to configure how rendered output is formatted.")
      ("Which attribute does html.lisp say Spinneret rejects on <textarea>?" "hyperion/src/html.lisp"
       "    '(\"autocomplete\")      ; allowed on <textarea> (WHATWG), rejected by Spinneret there")
      ("Which ADR decides to render everything with Spinneret?"
       "hyperion/docs/adr/0003-all-spinneret-templating.md" "**Render everything with Spinneret**")
      ("Which benchmark gives spinneret the nickname spin?" "hyperion/bench/server.lisp"
       "  (:local-nicknames (#:srv #:hyperion/server) (#:spin #:spinneret)))")
      ("Which test says Spinneret escapes text from a downloaded manifest?"
       "hyperion/tests/update-ui-tests.lisp" "  \"The detail reaches the page from a DOWNLOADED MANIFEST."))))
  "The three searches and their questions. Each was eligible and inside the band the hook acts
on (3,500 tokens up to Claude Code's own cut at about 30,000 characters) on the tree they were
chosen from.")

(defun %answer-line-p (line path start)
  "Whether LINE is the search output line PATH:N:TEXT whose TEXT starts with START."
  (let ((prefix (concatenate 'string path ":")))
    (and (uiop:string-prefix-p prefix line)
         (let ((colon (position #\: line :start (length prefix))))
           (and colon
                (every #'digit-char-p (subseq line (length prefix) colon))
                (uiop:string-prefix-p start (subseq line (1+ colon))))))))

(defun %answered (text questions)
  "The questions TEXT still answers: those with an answer line among TEXT's lines."
  (let ((lines (coerce (hook:output-lines text) 'list)))
    (remove-if-not (lambda (q) (some (lambda (l) (%answer-line-p l (second q) (third q))) lines))
                   questions)))

(defun %event (command raw)
  (let ((e (make-hash-table :test #'equal)) (input (make-hash-table :test #'equal))
        (response (make-hash-table :test #'equal)))
    (setf (gethash "command" input) command
          (gethash "stdout" response) raw (gethash "stderr" response) ""
          (gethash "interrupted" response) nil (gethash "isImage" response) nil
          (gethash "hook_event_name" e) "PostToolUse" (gethash "tool_name" e) "Bash"
          (gethash "tool_input" e) input (gethash "tool_response" e) response)
    (jzon:stringify e)))

(defun %replacement (out)
  (and out (gethash "stdout" (gethash "updatedToolOutput"
                                      (gethash "hookSpecificOutput" (jzon:parse out))))))

(defun %report (label out fields questions)
  (let ((text (%replacement out)))
    (format t "  ~A: ~(~A~)~@[ (~(~A~))~]~@[, ~(~A~)~], ~:D raw tokens~@[, ~:D sent~], ~A ms~@[, answers ~A of 5~]~@[, missing ~{~A~^, ~}~]~%"
            label (getf fields :decision) (getf fields :reason) (getf fields :method)
            (getf fields :raw-tokens) (getf fields :sent-tokens) (getf fields :ms)
            (and text (length (%answered text questions)))
            (and text (loop for q in questions for i from 1
                            unless (member q (%answered text questions)) collect (format nil "Q~D" i))))))

(defun run-trials ()
  (let* ((run (equal (uiop:getenv "PRAXEON_CC_TRIALS") "run"))
         (rounds (or (ignore-errors (parse-integer (uiop:getenv "PRAXEON_CC_TRIAL_ROUNDS"))) 2))
         (dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "praxeon-cc-trials-~36R/" (random (expt 2 40) (make-random-state t)))
                                (uiop:temporary-directory))))
         (offline (make-instance 'hook:claude-cli :program "/nonexistent/no-model-offline"))
         (calls 0))
    (format t "commit ~A~%" (string-trim '(#\Newline) (uiop:run-program '("git" "rev-parse" "HEAD") :output :string)))
    (unwind-protect
         (dolist (s *searches*)
           (destructuring-bind (name command questions) s
             (let* ((raw (uiop:run-program (list "/bin/sh" "-c" command) :output :string :ignore-error-status t))
                    (event (%event command raw))
                    (lines (coerce (hook:output-lines raw) 'list)))
               (format t "~%~A: ~A~%  ~:D characters, ~:D lines~%" name command (length raw) (length lines))
               ;; Each question must have exactly one answer line, or the tree has moved under it.
               (loop for q in questions for i from 1
                     for n = (count-if (lambda (l) (%answer-line-p l (second q) (third q))) lines)
                     unless (= n 1) do (format t "  Q~D has ~D answer lines in this output, not 1~%" i n))
               (multiple-value-bind (decision reason) (hook:event-eligibility (hook:parse-event event))
                 (format t "  eligibility: ~(~A~)~@[ (~(~A~))~]~%" decision reason))
               ;; The grouped path, as the hook runs it. A backend that cannot start stands in for
               ;; the model, so a search that does not group is reported as backend-failed here.
               (multiple-value-bind (out fields) (hook:decide event offline :directory dir)
                 (%report "as the hook runs it, offline" out fields questions))
               (incf calls rounds)
               (when run
                 (let ((backend (hook:backend-from-env)))
                   (loop for round from 1 to rounds
                         do (multiple-value-bind (out fields)
                                (hook:decide event backend :directory dir :group nil)
                              (%report (format nil "model selection, round ~D" round) out fields questions))))))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))
    (format t "~%model calls ~:[this run would make with PRAXEON_CC_TRIALS=run: ~D~;made: ~D~]~%" run calls)))

(run-trials)
