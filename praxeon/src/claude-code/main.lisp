;;;; claude-code/main.lisp --- the praxeon-claude-code executable's command line (#452).

(in-package #:praxeon/claude-code)

(defparameter +usage+
  "usage: praxeon-claude-code report [--days N] [--threshold TOKENS] [--projects DIR]
       praxeon-claude-code hook

report  Read your Claude Code transcripts from the last N days (default 30) and print how much
        of what your sessions read came from large tool outputs, and how much the hook would
        replace. Prints counts only.
hook    A PostToolUse hook: reads the event on stdin and prints a replacement, or nothing.
        See praxeon/docs/claude-code-hook.md for installing it.
")

(defun %option (args name)
  (let ((tail (member name args :test #'string=)))
    (and tail (second tail))))

(defun %integer-option (args name default)
  (let ((v (%option args name)))
    (if v
        (or (ignore-errors (parse-integer v))
            (error "praxeon-claude-code: ~A takes a whole number, not ~S" name v))
        default)))

(defun run (args)
  "Run the command ARGS names. Returns the process exit status."
  (let ((command (first args)))
    (cond
      ((equal command "hook")
       (hook:run-hook)
       0)
      ((equal command "report")
       (handler-case
           (progn
             (report:report :days (%integer-option args "--days" report:*default-days*)
                            :threshold (%integer-option args "--threshold"
                                                        praxeon/claude-code/rules:*threshold-tokens*)
                            :projects-directory
                            (let ((d (%option args "--projects")))
                              (if d
                                  (uiop:ensure-directory-pathname d)
                                  (merge-pathnames ".claude/projects/" (user-homedir-pathname)))))
             0)
         (error (e)
           (format *error-output* "~A~%" e)
           1)))
      (t (write-string +usage+ (if (member command '("-h" "--help" "help") :test #'equal)
                                    *standard-output* *error-output*))
         (if (member command '("-h" "--help" "help") :test #'equal) 0 2)))))

(defun main ()
  "The executable's toplevel. The hook exits 0 whatever happens, so a failure never blocks a
tool result."
  (let ((status (handler-case (run (rest sb-ext:*posix-argv*))
                  (error () (if (equal (second sb-ext:*posix-argv*) "hook") 0 1)))))
    (finish-output *standard-output*)
    (sb-ext:exit :code status :abort t)))
