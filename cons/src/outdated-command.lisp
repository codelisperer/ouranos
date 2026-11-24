;;;; outdated-command.lisp --- `cons outdated': is an app current? (#716, point 4)
;;;;
;;;; Run from an app's directory. Three sections, each a list of lines with a status:
;;;;
;;;;   framework   the release in the app's ouranos.pin against the newest release, the
;;;;               CHANGELOG's "An app may have to act" entries in between, and whether the
;;;;               framework checkout is at the pinned commit
;;;;   toolchain   the running SBCL, the Coalton that loads and the Quicklisp dist against
;;;;               the framework's own pins (scripts/versions.env, coalton.pin)
;;;;   app pins    the app's own upstream.sexp, checked as scripts/check-upstream.lisp checks
;;;;               this tree's, through cons/inventory
;;;;
;;;; Offline by default. --online asks git for the newest release tag and, through the system
;;;; cons/outdated (loaded at run time, never a dependency of core cons), each upstream.sexp
;;;; entry's upstream. Exit 0 whatever it finds; --strict exits 1 on any gap (the hub's ruling
;;;; on #716). A NOTE is never a gap.

(in-package #:cons/outdated-command)

(defparameter *gap-statuses* '(:behind :unknown :differs :problem :retired)
  "The statuses --strict fails on. :current, :held, :manual and :note never fail.")

;;; --- the pure parts ---------------------------------------------------------------------------

(defun release< (a b)
  "Is release tag A (v0.1.6) older than B (v0.1.7)?"
  (inv:version< a b))

(defun %bullet-title (line more)
  "The bold title of a CHANGELOG bullet that starts with LINE (`- **title** ...'). A title that
continues onto the following lines, MORE, is joined with them up to its closing `**'."
  (let ((text (subseq line 4)))
    (loop until (search "**" text)
          while more
          do (setf text (concatenate 'string text " " (string-trim " " (pop more)))))
    (let ((end (search "**" text)))
      (string-right-trim " " (if end (subseq text 0 end) text)))))

(defun act-entries-after (lines release &key (until nil) (unreleased nil))
  "From a CHANGELOG's LINES, the titles of the \"An app may have to act\" entries in every
release section newer than RELEASE (and no newer than UNTIL, when given), plus the Unreleased
section when UNRELEASED is true. Returns a list of (section-heading . titles), newest first."
  (let ((result '()) (section nil) (wanted nil) (in-act nil) (titles '()))
    (flet ((flush ()
             (when (and section wanted titles)
               (push (cons section (reverse titles)) result))
             (setf titles '() in-act nil)))
      (loop for (line . more) on lines
            do (cond ((and (> (length line) 3) (string= "## " line :end2 3))
               (flush)
               (setf section (string-trim " " (subseq line 3)))
               (let ((tag (first (uiop:split-string section :separator '(#\Space)))))
                 (setf wanted (if (string-equal tag "Unreleased")
                                  unreleased
                                  (and (> (length tag) 1) (char= #\v (char tag 0))
                                       (or (null release) (release< release tag))
                                       (or (null until) (not (release< until tag))))))))
              ((and (> (length line) 4) (string= "### " line :end2 4))
               (setf in-act (search "An app may have to act" line)))
              ((and in-act wanted (> (length line) 4) (string= "- **" line :end2 4))
               (push (%bullet-title line (subseq more 0 (min 6 (length more)))) titles))))
      (flush))
    (nreverse result)))

;;; --- reading the framework and the machine ----------------------------------------------------

(defun %git (dir &rest args)
  (handler-case
      (multiple-value-bind (out err code)
          (uiop:run-program (append (list "git" "-C" (uiop:native-namestring dir)) args)
                            :output '(:string :stripped t) :error-output nil :ignore-error-status t)
        (declare (ignore err))
        (and (eql code 0) out))
    (error () nil)))

(defun %env-value (file key)
  "The value of KEY=value in FILE, or NIL."
  (when (probe-file file)
    (with-open-file (in file :external-format :utf-8)
      (loop for line = (read-line in nil nil)
            while line
            do (let ((prefix (format nil "~A=" key)))
                 (when (and (>= (length line) (length prefix)) (string= prefix line :end2 (length prefix)))
                   (return (string-trim '(#\Space #\Return) (subseq line (length prefix))))))))))

(defun %pin-field (file name)
  "The second word of FILE's line whose first word is NAME, or NIL."
  (when (probe-file file)
    (with-open-file (in file :external-format :utf-8)
      (loop for line = (read-line in nil nil)
            while line
            do (let ((w (remove "" (uiop:split-string (string-right-trim '(#\Return) line)
                                                      :separator '(#\Space #\Tab))
                                :test #'string=)))
                 (when (and w (string= (first w) name)) (return (second w))))))))

(defun newest-release (framework &key online)
  "The newest v* release tag: from the checkout's own tags, or with ONLINE from its remote."
  (let* ((text (if online
                   (%git framework "ls-remote" "--tags" "--refs" "origin" "v*")
                   (%git framework "tag" "-l" "v[0-9]*")))
         (tags (loop for line in (and text (uiop:split-string text :separator '(#\Newline)))
                     for name = (let ((slash (position #\/ line :from-end t)))
                                  (string-trim " " (if slash (subseq line (1+ slash)) line)))
                     when (and (> (length name) 1) (char= #\v (char name 0)) (inv:stable-p name))
                       collect name)))
    (and tags (inv:newest tags))))

;;; --- the three sections -----------------------------------------------------------------------

(defun pin-gaps (app framework &key online)
  "The framework section's lines, as (status . text)."
  (multiple-value-bind (release commit) (pin:read-ouranos-pin app)
    (multiple-value-bind (here-release here-commit) (pin:framework-release framework)
      (let ((newest (newest-release framework :online online))
            (lines '()))
        (flet ((line (status fmt &rest args) (push (cons status (apply #'format nil fmt args)) lines)))
          (cond
            ((null release)
             (line :unknown "no ~A here, so the release this app was made from is unknown. Run `cons conform' to write one."
                   pin:+pin-file+))
            ((and newest (release< release newest))
             (line :behind "made from ~A; the newest release is ~A~:[~; (asked the remote)~]" release newest online)
             (let ((changelog (and framework (merge-pathnames "CHANGELOG.md" framework))))
               (when (and changelog (probe-file changelog))
                 (dolist (section (act-entries-after (uiop:read-file-lines changelog) release :until newest))
                   (line :note "\"An app may have to act\" in ~A:" (car section))
                   (dolist (title (cdr section)) (line :note "  - ~A" title))))))
            (t (line :current "made from ~A~@[, the newest release~*~]" release newest)))
          (when (and release commit here-commit (not (string= commit here-commit)))
            (line :differs "the framework checkout is at ~@[~A, ~]~A, not the pinned commit ~A"
                  here-release (subseq here-commit 0 (min 8 (length here-commit)))
                  (subseq commit 0 (min 8 (length commit)))))
          (dolist (advice (and framework (ignore-errors (upstream:checkout-advisory framework))))
            (line :note "~A" advice)))
        (nreverse lines)))))

(defun toolchain-gaps (framework)
  "The toolchain section's lines: the running SBCL, the Coalton that loads and the Quicklisp
dist, each against the framework's pin."
  (let ((lines '())
        (versions (and framework (merge-pathnames "scripts/versions.env" framework))))
    (flet ((line (status fmt &rest args) (push (cons status (apply #'format nil fmt args)) lines))
           (compare (what found pinned)
             (cond ((or (null found) (null pinned))
                    (push (cons :unknown (format nil "~A: found ~A, pinned ~A" what (or found "nothing") (or pinned "nothing")))
                          lines))
                   ((string= found pinned) (push (cons :current (format nil "~A ~A, as pinned" what found)) lines))
                   (t (push (cons :differs (format nil "~A ~A, but the framework pins ~A" what found pinned)) lines)))))
      (compare "SBCL" (lisp-implementation-version) (and versions (%env-value versions "SBCL_VERSION")))
      (let* ((pinned (and framework (%pin-field (merge-pathnames "coalton.pin" framework) "sha")))
             (dir (ignore-errors (asdf:system-source-directory "coalton")))
             (head (and dir (%git dir "rev-parse" "HEAD"))))
        (cond ((or (null pinned) (null head))
               (line :unknown "Coalton: found ~A, pinned ~A" (or head "no checkout") (or pinned "nothing")))
              ((and (<= (length pinned) (length head)) (string= pinned head :end2 (length pinned)))
               (line :current "Coalton ~A, as pinned" pinned))
              (t (line :differs "Coalton ~A loads, but the framework pins ~A" (subseq head 0 8) pinned))))
      (let ((distinfo (merge-pathnames "dists/quicklisp/distinfo.txt"
                                       (uiop:ensure-directory-pathname
                                        (or (uiop:getenvp "QUICKLISP_HOME")
                                            (merge-pathnames "quicklisp/" (user-homedir-pathname)))))))
        (compare "Quicklisp dist"
                 (let ((v (%pin-field distinfo "version:"))) v)
                 (and versions (%env-value versions "QUICKLISP_DIST")))))
    (nreverse lines)))

(defun app-pin-gaps (app &key online)
  "The app-pins section: APP's upstream.sexp, offline and with ONLINE online too. The rows the
offline check prints come first; the returned lines are its problems, or a note."
  (let ((path (merge-pathnames "upstream.sexp" app)))
    (cond
      ((not (probe-file path))
       (list (cons :note "no upstream.sexp, so nothing of the app's own is checked. Its format is the Ouranos tree's (#716).")))
      ((null (ignore-errors (inv:read-inventory path)))
       (list (cons :note "upstream.sexp lists nothing yet.")))
      (t
       (let ((inv:*root* app) (inv:*program* "cons outdated") (inv:*problems* '()))
         (handler-case
             (let* ((rows '())
                    (printed (with-output-to-string (*standard-output*)
                               (let ((checked (inv:offline-check)))
                                 (when (and online (null inv:*problems*))
                                   (%load-online)
                                   (setf rows (uiop:symbol-call :cons/outdated :report-online checked nil)))))))
               ;; What the check printed (its rows and summaries) is shown inside this section,
               ;; as notes, rather than before the report's header.
               (append
                (loop for l in (uiop:split-string printed :separator '(#\Newline))
                      for text = (string-trim " " l)
                      when (plusp (length text)) collect (cons :note text))
                (mapcar (lambda (p) (cons :problem p)) (reverse inv:*problems*))
                (loop for row in rows
                      for status = (fifth row)
                      when (member status *gap-statuses*)
                        collect (cons status (format nil "~A: ~A" (first row) (or (sixth row) status))))))
           (inv:inventory-unreadable (c) (list (cons :problem (princ-to-string c))))))))))

(defun %load-online ()
  "Load cons/outdated, which brings aion/http-client and jzon, only now that --online asked."
  (if (find-package "QL")
      (uiop:symbol-call :ql :quickload :cons/outdated :silent t)
      (asdf:load-system "cons/outdated")))

;;; --- the command ------------------------------------------------------------------------------

(defun %print-section (title lines)
  (format t "~%~A~%" title)
  (dolist (l lines)
    (format t "  ~8A ~A~%" (string-downcase (car l)) (cdr l))))

(defun %gaps (sections)
  "How many lines of SECTIONS, a list of (title . lines), have a gap status."
  (loop for (nil . lines) in sections
        sum (count-if (lambda (l) (member (car l) *gap-statuses*)) lines)))

(defun exit-code (sections strict)
  "0, or 1 when STRICT and some line of SECTIONS has a gap status."
  (if (and strict (plusp (%gaps sections))) 1 0))

(defun run (&key (app (uiop:getcwd)) (framework (pin:framework-root)) online strict)
  "Print the three sections for APP and return the exit code: 0, or 1 under STRICT when any
line has a gap status."
  (let* ((app (uiop:ensure-directory-pathname app))
         (sections (list (cons "framework" (pin-gaps app framework :online online))
                         (cons "toolchain" (toolchain-gaps framework))
                         (cons "app pins" (app-pin-gaps app :online online))))
         (gaps (%gaps sections)))
    (format t "cons outdated: ~A~@[ (framework at ~A)~]~%" (uiop:native-namestring app)
            (and framework (uiop:native-namestring framework)))
    (loop for (title . lines) in sections do (%print-section title lines))
    (format t "~%cons outdated: ~D gap~:P~:[~; (--strict: exit 1)~]~%" gaps (and strict (plusp gaps)))
    (exit-code sections strict)))
