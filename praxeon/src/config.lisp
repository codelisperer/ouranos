;;;; config.lisp --- project configuration from a local .env file (delegates to cons).
;;;;
;;;; Praxeon is configured through PRAXEON_LLM_* environment variables (see
;;;; llm.lisp). For local development it is convenient to keep those in a
;;;; project-local, git-ignored .env rather than the global shell profile. The
;;;; dotenv *mechanism* is shared across the codelisperer projects and lives in cons
;;;; (config/env is cons's domain); this delegates to it, keeping praxeon's
;;;; LOAD-DOTENV entry point (callers like Elise are unchanged). The configuration
;;;; contract stays "environment variables"; .env is just one source of them, and
;;;; the host environment wins.

(cl:in-package #:praxeon/config)

(defun load-dotenv (&key (path ".env") override)
  "Read KEY=VALUE lines from PATH (default ./.env) into the process environment,
via cons/env:load-dotenv. Blank lines and #-comments are skipped; an optional
`export ` prefix and surrounding quotes are tolerated. An already-set variable is
left untouched (the host env wins) unless OVERRIDE. A missing file is not an error.
Returns the list of keys applied."
  (cons/env:load-dotenv :path path :override override))
