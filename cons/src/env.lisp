;;;; env.lisp --- load a local .env file into the process environment.
;;;;
;;;; Config/env is cons's domain (the project & dev tool owns how a project is
;;;; configured). The contract across these projects is "environment variables"; a
;;;; project-local, git-ignored .env is one convenient SOURCE of them for local dev.
;;;; LOAD-DOTENV reads KEY=VALUE lines into the environment so ordinary env-reading
;;;; paths (provider factories, class initforms) pick them up unchanged. The host
;;;; environment WINS by default (an already-set var is left alone), so production
;;;; sets real vars in the platform and ships no .env.
;;;;
;;;; This is the shared loader every project delegates to (killing the per-project
;;;; copies). `cons init` scaffolds the matching .env.example + .gitignore rules so a
;;;; new project gets the convention for free. uiop-only (cons stays dependency-light
;;;; -- it is a bootstrapping tool).

(in-package #:cons/env)

(defun %unquote (s)
  "Strip a single matching pair of surrounding single or double quotes from S."
  (let ((n (length s)))
    (if (and (>= n 2)
             (member (char s 0) '(#\" #\'))
             (char= (char s 0) (char s (1- n))))
        (subseq s 1 (1- n))
        s)))

(defun %strip-inline-comment (s)
  "Remove a trailing inline comment from an unquoted value S -- a `#` at the start
of the value or preceded by whitespace begins the comment. A quoted value, or a `#`
mid-token (e.g. in a URL or token), is left untouched."
  (if (and (plusp (length s)) (member (char s 0) '(#\" #\')))
      s
      (loop for i from 0 below (length s)
            when (and (char= (char s i) #\#)
                      (or (zerop i)
                          (member (char s (1- i)) '(#\Space #\Tab))))
              do (return (string-right-trim '(#\Space #\Tab) (subseq s 0 i)))
            finally (return s))))

(defun %parse-line (line)
  "Parse one .env LINE into (values KEY VALUE), or NIL for a blank/comment line. An
optional `export ` prefix and surrounding quotes are tolerated; a trailing inline
`# ...` comment on an unquoted value is stripped."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
    (when (and (plusp (length trimmed))
               (char/= (char trimmed 0) #\#))
      (let ((eq (position #\= trimmed)))
        (when eq
          (let ((key (string-trim '(#\Space #\Tab) (subseq trimmed 0 eq)))
                (val (%unquote (%strip-inline-comment
                                (string-trim '(#\Space #\Tab)
                                             (subseq trimmed (1+ eq)))))))
            (when (and (> (length key) 7)
                       (string-equal (subseq key 0 7) "export "))
              (setf key (string-trim '(#\Space #\Tab) (subseq key 7))))
            (when (plusp (length key))
              (values key val))))))))

(defun load-dotenv (&key (path ".env") override)
  "Read KEY=VALUE lines from PATH (default ./.env; an app passes its own
system-relative pathname) into the process environment. Blank lines and #-comments
are skipped; an optional `export ` prefix and surrounding quotes are tolerated. By
default an already-set variable is left untouched -- THE HOST ENVIRONMENT WINS --
so production (real env vars, no .env) works unchanged; pass OVERRIDE non-NIL to
replace. A missing file is not an error. Returns the list of keys applied."
  (let ((file (merge-pathnames path))
        (applied '()))
    (when (probe-file file)
      (with-open-file (in file :external-format :utf-8)
        (loop for line = (read-line in nil nil)
              while line
              do (multiple-value-bind (key val) (%parse-line line)
                   (when (and key (or override (null (uiop:getenv key))))
                     (setf (uiop:getenv key) val)
                     (push key applied))))))
    (nreverse applied)))

;;; --- the entry-point form -------------------------------------------------
;;;
;;; WHY THIS EXISTS SEPARATELY FROM LOAD-DOTENV. A real failure, reported by a consuming
;;; app (pre-publication issue 120): `load-dotenv` was called while building the web handler -- but the app's
;;; start path opened the database and ran a seed that sent mail BEFORE the handler was
;;; constructed. So that work ran against a bare environment.
;;;
;;; One symptom was loud and pointed at the wrong component: a provider raised "missing
;;; required configuration: <KEY>" for a key sitting right there in .env, so the library
;;; looked broken when the app's own ordering was at fault. The other was silent: the
;;; database path fell back to its default and a stray database quietly appeared in the
;;; wrong directory.
;;;
;;; The lesson generalizes to anything scaffolded: .env must be the FIRST ACT of every
;;; entry point, not something done lazily wherever the first consumer happens to sit.
;;; Two properties make that possible to obey without thinking:
;;;
;;;   It resolves the file against the app's OWN system, not the current directory, so it
;;;   works when the binary is run from somewhere else -- which is the normal case.
;;;
;;;   It is IDEMPOTENT, so `main` can call it unconditionally without knowing whether a
;;;   REPL session, a test fixture or `cons run` already did. Re-loading is harmless
;;;   anyway (an already-set variable is left alone), but the record below also makes the
;;;   second call free and, more usefully, answerable.

(defvar *loaded-from* '()
  "Truenames of the .env files LOAD-PROJECT-ENV has already applied, most recent first.
Consulted to keep repeat calls free, and worth printing when a key is not what you expect
-- `which .env did this process actually read` is otherwise a guess.")

(defun dotenv-path (system &key (name ".env"))
  "Where LOAD-PROJECT-ENV would look for SYSTEM's env file: NAME beside its .asd.

SYSTEM is an ASDF system designator (`:myapp`). Resolving against the system rather than
*DEFAULT-PATHNAME-DEFAULTS* is what makes this correct for a built binary, which is
generally run from a directory that has nothing to do with the source tree."
  (asdf:system-relative-pathname system name))

(defun load-project-env (system &key (name ".env") override force)
  "Load SYSTEM's .env into the process environment. THE FIRST LINE OF AN ENTRY POINT.

Returns (values keys path), where KEYS are the variables actually applied and PATH is the
file read, or (values NIL NIL) if there was none -- a missing .env is normal (production
sets real variables and ships no file) and is not an error.

Idempotent: a file already applied in this image is skipped unless :FORCE. The host
environment still wins over the file unless :OVERRIDE, exactly as in LOAD-DOTENV, so
calling this changes nothing that was already configured for real."
  (let ((path (probe-file (dotenv-path system :name name))))
    (cond
      ((null path) (values nil nil))
      ((and (not force) (member path *loaded-from* :test #'equal)) (values nil path))
      (t
       (let ((applied (load-dotenv :path path :override override)))
         (pushnew path *loaded-from* :test #'equal)
         (values applied path))))))
