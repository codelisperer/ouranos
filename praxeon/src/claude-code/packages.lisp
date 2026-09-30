;;;; claude-code/packages.lisp --- packages of praxeon/claude-code (#452).

(cl:defpackage #:praxeon/claude-code/rules
  (:use #:cl)
  (:documentation
   "Which tool outputs the hook may replace with a summary, as pure functions of the tool, its
    input and its output (#452). The report uses the same decision.")
  (:export #:eligibility #:command-eligible-p #:identifier-like-p #:credential-like-p
           #:diff-like-p #:estimate-tokens #:bash-category #:tool-category
           #:*threshold-tokens* #:*summary-budget* #:*minimum-reduction*
           #:*search-commands* #:*mcp-prefix*))

(cl:defpackage #:praxeon/claude-code/transcript
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon)
                    (#:rules #:praxeon/claude-code/rules))
  (:documentation
   "Reading Claude Code session transcripts (~/.claude/projects/*/*.jsonl) into counts.

    A transcript is one JSON object per line. What is read from it: each model call's
    `usage', counted once per message id, since one call is written as several records; each
    tool result's size and category, from the tool_use block it answers; and the compaction
    boundaries. Nothing here keeps or returns the text of a message or a result.")
  (:export
   ;; one session, as counts
   #:session #:session-calls #:session-results #:session-compactions
   #:call #:call-index #:call-input #:call-output #:call-cache-read #:call-cache-write
   #:result #:result-index #:result-category #:result-tokens #:result-tool #:result-error-p
   #:result-decision #:result-reason
   #:read-session #:parse-session-lines #:session-files #:later-calls))

(cl:defpackage #:praxeon/claude-code/report
  (:use #:cl)
  (:local-nicknames (#:tr #:praxeon/claude-code/transcript)
                    (#:rules #:praxeon/claude-code/rules))
  (:documentation
   "The `report' command: aggregates over a user's transcripts, so they can see whether large
    tool outputs are a large share of what their sessions read. Prints counts only, never
    content or paths.")
  (:export #:summarize #:print-report #:report
           #:*default-days*))

(cl:defpackage #:praxeon/claude-code/hook
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon)
                    (#:rules #:praxeon/claude-code/rules)
                    (#:llm #:praxeon/llm))
  (:documentation
   "The `hook' command: a Claude Code PostToolUse hook that replaces a large search output with
    a list of facts a second model wrote, after checking the list against the raw text. On any
    failure it prints nothing, so the original output goes through.")
  (:export #:run-hook #:decide #:parse-event #:event #:event-tool #:event-shape #:event-text
           #:event-eligibility #:check-summary #:unsupported-tokens #:replacement-text
           #:hook-output #:prompt #:summarize #:claude-cli #:praxeon-provider #:cli-arguments
           #:backend-from-env #:archive #:log-event #:cache-directory #:sha256-hex
           #:summarizer-failure #:summarizer-timeout #:summarizer-exit #:summarizer-bad-reply
           #:*timeout-seconds* #:*archive-days*))

(cl:defpackage #:praxeon/claude-code
  (:use #:cl)
  (:local-nicknames (#:report #:praxeon/claude-code/report)
                    (#:hook #:praxeon/claude-code/hook))
  (:documentation "The praxeon-claude-code executable's entry point: `report' and `hook'.")
  (:export #:main))
