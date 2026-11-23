;;;; command.lisp --- running a suite from the command line, for the `acceptance' target of
;;;; dokimasia/cons.lisp (#1028).
;;;;
;;;; cons passes a target's parameters as strings. COMMAND-LINE-EXIT-CODE takes them as strings,
;;;; checks them, loads the app's system, runs the suite and returns an exit code. The exit code
;;;; is read from the report, so a row that was not run counts against the run: a run with no
;;;; browser, or whose browser could not start, does not exit 0.
;;;;
;;;;   0  every row passed;
;;;;   1  a row failed or was not run, or the suite has no rows;
;;;;   2  a parameter is wrong, the system could not be loaded, or no suite has the name.
;;;;
;;;; RUN-FROM-COMMAND-LINE quits the image with that code. cons runs the target in its own sbcl
;;;; (the target is :isolate), so quitting ends only that process.

(in-package #:dokimasia)

(define-condition command-line-error (error)
  ((reason :initarg :reason :reader command-line-error-reason))
  (:report (lambda (c s) (write-string (command-line-error-reason c) s))))

(defun %command-line-error (control &rest args)
  (error 'command-line-error :reason (apply #'format nil control args)))

(defun %split-names (text)
  "TEXT's comma-separated items, each with spaces trimmed, without the empty ones."
  (let ((items '()) (start 0))
    (loop for comma = (position #\, text :start start)
          do (let ((item (string-trim " " (subseq text start comma))))
               (unless (string= item "") (push item items)))
             (if comma (setf start (1+ comma)) (return)))
    (nreverse items)))

(defun %parse-names (parameter text allowed)
  "TEXT, a comma-separated list of names from ALLOWED (keywords), as a list of those keywords.
Signals COMMAND-LINE-ERROR naming PARAMETER when TEXT is empty or a name is not allowed."
  (let ((names (%split-names (or text ""))))
    (unless names
      (%command-line-error "~A is empty; give one or more of ~{~(~A~)~^, ~}, separated by commas"
                           parameter allowed))
    (loop for name in names
          collect (or (find name allowed :test #'string-equal)
                      (%command-line-error "~A: ~S is not one of ~{~(~A~)~^, ~}"
                                           parameter name allowed)))))

(defun parse-viewports (text)
  "TEXT, such as \"desktop,phone\", as a list of viewport keywords for RUN."
  (%parse-names "VIEWPORTS" text (mapcar #'first +viewports+)))

(defun parse-schemes (text)
  "TEXT, such as \"light,dark\", as a list of colour-scheme keywords for RUN."
  (%parse-names "SCHEMES" text '(:light :dark)))

(defun %required (parameter text)
  (let ((value (string-trim " " (or text ""))))
    (when (string= value "")
      (%command-line-error "~A is empty; it is required" parameter))
    value))

(defun %load-app-system (system)
  "Load SYSTEM, through Quicklisp when it is loaded, so missing libraries are fetched."
  (handler-case
      (if (find-package '#:ql)
          (uiop:symbol-call '#:ql '#:quickload system :silent t)
          (asdf:load-system system))
    (error (c)
      (%command-line-error "the system ~A could not be loaded: ~A" system c))))

(defun %report-counts (out)
  "The passed, failed and not-run counts in OUT's report.json, as three values."
  (let ((report (jzon:parse (uiop:read-file-string (merge-pathnames "report.json" out)
                                                   :external-format :utf-8))))
    (values (gethash "passed" report) (gethash "failed" report) (gethash "not-run" report))))

(defun command-line-exit-code (&key system suite (viewports "desktop") (schemes "light") out)
  "Load SYSTEM, run the suite SUITE in it, and return the exit code described in this file's
header. Every argument is a string, as cons passes it. VIEWPORTS and SCHEMES are comma-separated
names (desktop, phone; light, dark). OUT is the directory for the report and screenshots; when it
is empty or NIL, RUN's default, *DEFAULT-OUT*, is used. Problems with the arguments are printed to
*ERROR-OUTPUT*, and the report's path to *STANDARD-OUTPUT*."
  (handler-case
      (let* ((viewports (parse-viewports viewports))
             (schemes (parse-schemes schemes))
             (suite-name (%required "SUITE" suite))
             (system (%required "SYSTEM" system))
             (out (uiop:ensure-directory-pathname
                   (merge-pathnames (if (and out (string/= (string-trim " " out) ""))
                                        (string-trim " " out)
                                        *default-out*)))))
        (%load-app-system system)
        (unless (find-suite suite-name)
          (%command-line-error "the system ~A defines no suite named ~A" system suite-name))
        (let ((report (nth-value 1 (run suite-name :out out :viewports viewports
                                                   :schemes schemes :explain nil))))
          (format t "~&dokimasia: the report is ~A~%" (namestring report))
          (multiple-value-bind (passed failed not-run) (%report-counts out)
            (format t "dokimasia: ~D passed, ~D failed, ~D not run~%" passed failed not-run)
            (if (and (plusp passed) (zerop failed) (zerop not-run)) 0 1))))
    (command-line-error (c)
      (format *error-output* "~&dokimasia: ~A~%" (command-line-error-reason c))
      2)
    (invalid-definition (c)
      (format *error-output* "~&dokimasia: ~A~%" (invalid-definition-reason c))
      2)))

(defun run-from-command-line (&rest arguments &key system suite viewports schemes out)
  "Quit the image with COMMAND-LINE-EXIT-CODE of the same arguments. The `acceptance' target of
dokimasia/cons.lisp calls this in an sbcl of its own."
  (declare (ignore system suite viewports schemes out))
  (finish-output)
  (let ((code (apply #'command-line-exit-code arguments)))
    (finish-output)
    (finish-output *error-output*)
    (uiop:quit code)))
