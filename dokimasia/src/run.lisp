;;;; run.lisp --- running a suite: one FiveAM test per case and row (#1028, dokimasia ADR-0001).
;;;;
;;;; RUN reads every case's rows, makes a FiveAM suite with one test per case and row, starts the
;;;; target and a headless browser, runs the FiveAM suite, writes the report, and stops the
;;;; browser and the target however the run ends. Each step of a row is one FiveAM check: a pass,
;;;; a failure, or a skip for a step that was not run. A row stops at its first failed step.
;;;;
;;;; Without a browser every test is skipped with the reason, or fails when
;;;; OURANOS_REQUIRE_BROWSER=1, which CI sets, so a runner without a browser cannot report green.

(in-package #:dokimasia)

(defvar *default-out* #p"build/dokimasia/"
  "Where RUN writes its report and screenshots when given no :OUT, relative to the current
directory.")

(defstruct (run-state (:constructor %make-run-state))
  mode reason context base-url (reports '()))

(defvar *run-state* nil "The state of the RUN in progress, read by the tests it made.")

(defun %require-browser-p ()
  (equal (uiop:getenv "OURANOS_REQUIRE_BROWSER") "1"))

;;; --- one row ---------------------------------------------------------------------------------

(defun %reset-page (page base-url ctx)
  "Clear cookies and the base URL's stored data, so no row sees another's session, and set the
first viewport and scheme."
  (cdp:send page "Network.clearBrowserCookies" :timeout *step-timeout*)
  (cdp:send page "Storage.clearDataForOrigin"
            :params (cdp:json-object "origin" (%origin base-url) "storageTypes" "all")
            :timeout *step-timeout*)
  (%apply-viewport page (first (run-context-viewports ctx)))
  (cdp:emulate-color-scheme page (first (run-context-schemes ctx)) :timeout *step-timeout*))

(defun %step-record (label kind reason ms)
  (list :label label :outcome kind :reason reason :ms ms))

(defun %run-row (state dcase inputs row-id)
  "Run DCASE's steps for the row INPUTS in a new page. Returns a ROW-REPORT."
  (let* ((ctx (run-state-context state))
         (suite (run-context-suite ctx))
         (target (run-context-target ctx))
         (base-url (run-state-base-url state))
         (records '())
         (row (%make-row :base-url base-url :origin (%origin base-url) :target target
                         :suite suite :inputs inputs))
         (user-name (dcase-user dcase)))
    (setf (run-context-dcase ctx) dcase
          (run-context-row-id ctx) row-id
          (run-context-step-number ctx) 0)
    (flet ((record (label kind reason ms)
             (push (%step-record label kind reason ms) records)
             (string/= kind "failed")))
      (block steps
        (let ((page (handler-case (cdp:new-page (run-context-browser ctx) :timeout *step-timeout*)
                      (error (c)
                        (record "opening a page" "failed" (%clip (princ-to-string c) 400) 0)
                        (return-from steps)))))
          (setf (row-page row) page)
          (unwind-protect
               (let ((*row* row) (*run* ctx))
                 (handler-case (%reset-page page base-url ctx)
                   (error (c)
                     (record "clearing the browser's state" "failed" (%clip (princ-to-string c) 400) 0)
                     (return-from steps)))
                 (when user-name
                   (let ((user (%find-user target user-name)))
                     (unless user
                       (record (format nil "signing in as ~A" user-name) "failed"
                               (format nil "the target has no user named ~A" user-name) 0)
                       (return-from steps))
                     (unless (suite-sign-in suite)
                       (record (format nil "signing in as ~A" user-name) "failed"
                               (format nil "the case signs in as ~A, and the suite ~A has no :SIGN-IN steps"
                                       user-name (suite-name suite))
                               0)
                       (return-from steps))
                     (setf (row-user row) user)
                     (dolist (step (suite-sign-in suite))
                       (multiple-value-bind (kind reason ms) (%run-step step)
                         (unless (record (format nil "sign-in: ~A" (step-label step)) kind reason ms)
                           (return-from steps))))))
                 (dolist (step (dcase-steps dcase))
                   (incf (run-context-step-number ctx))
                   (multiple-value-bind (kind reason ms) (%run-step step)
                     (unless (record (step-label step) kind reason ms)
                       (return-from steps)))))
            (ignore-errors (cdp:close-page page :timeout 5))))))
    (let ((report (%row-report dcase row-id user-name (reverse records))))
      (setf (row-report-console report) (reverse (row-console row))
            (row-report-network report) (reverse (row-network row))
            (row-report-artifacts report) (reverse (row-artifacts row)))
      report)))

(defun %not-run-report (dcase row-id reason)
  (%row-report dcase row-id (dcase-user dcase)
               (list (%step-record "starting the run" "not-run" reason 0))))

(defun %failed-report (dcase row-id label reason)
  (%row-report dcase row-id (dcase-user dcase) (list (%step-record label "failed" reason 0))))

(defun %report-checks (report)
  "Make one FiveAM check per step of REPORT."
  (let ((title (%row-title report)))
    (loop for s in (row-report-steps report)
          for i from 1
          do (let ((kind (getf s :outcome)))
               (cond ((string= kind "passed") (fiveam:pass))
                     ((string= kind "failed")
                      (fiveam:fail "~A, step ~D ~A: ~A" title i (getf s :label) (getf s :reason)))
                     (t (fiveam:skip "~A, step ~D ~A was not run: ~A" title i (getf s :label)
                                     (getf s :reason))))))))

(defun %test-row (dcase inputs row-id problem)
  "The body of the FiveAM test for one case and row. PROBLEM is the reason the case's rows could
not be read, or NIL."
  (let ((state *run-state*))
    (cond
      ((null state)
       (fiveam:skip "~A ~A: run it through DOKIMASIA:RUN, which starts the target and the browser"
                    (dcase-name dcase) row-id))
      (problem
       (let ((r (%failed-report dcase row-id "reading the rows" problem)))
         (push r (run-state-reports state))
         (%report-checks r)))
      ((eq (run-state-mode state) :no-browser)
       (push (%not-run-report dcase row-id (run-state-reason state)) (run-state-reports state))
       (if (%require-browser-p)
           (fiveam:fail "~A ~A: ~A, and OURANOS_REQUIRE_BROWSER=1" (dcase-name dcase) row-id
                        (run-state-reason state))
           (fiveam:skip "~A ~A: ~A" (dcase-name dcase) row-id (run-state-reason state))))
      ((eq (run-state-mode state) :not-started)
       (let ((r (%failed-report dcase row-id "starting the target and the browser"
                                (run-state-reason state))))
         (push r (run-state-reports state))
         (%report-checks r)))
      (t
       (let ((r (%run-row state dcase inputs row-id)))
         (push r (run-state-reports state))
         (%report-checks r))))))

;;; --- the FiveAM suite ------------------------------------------------------------------------

(defun %generated (control &rest args)
  (intern (string-upcase (apply #'format nil control args)) '#:dokimasia/generated))

(defun %plan (suite)
  "For each of SUITE's cases and rows, a list (DCASE INPUTS ROW-ID PROBLEM)."
  (loop for dcase in (suite-dcases suite)
        append (handler-case
                   (let ((seen (make-hash-table :test 'equal)))
                     (loop for row in (case-rows dcase)
                           for i from 0
                           collect (let ((id (row-id row i)))
                                     (when (gethash id seen)
                                       (setf id (format nil "~A-~D" id (1+ i))))
                                     (setf (gethash id seen) t)
                                     (list dcase row id nil))))
                 (invalid-definition (c)
                   (list (list dcase '() "rows" (invalid-definition-reason c)))))))

(defun %make-fiveam-suite (suite plan)
  "A new FiveAM suite holding one test per entry of PLAN. Returns its name."
  (let ((suite-name (%generated "~A" (suite-name suite)))
        (*package* (find-package '#:dokimasia/generated)))
    (fiveam:make-suite suite-name :description (format nil "dokimasia suite ~A" (suite-name suite)))
    (dolist (entry plan)
      (destructuring-bind (dcase inputs row-id problem) entry
        (let ((name (%generated "~A/~A/~A" (suite-name suite) (dcase-name dcase) row-id)))
          (eval `(fiveam:def-test ,name (:suite ,suite-name)
                   (%test-row ',dcase ',inputs ',row-id ',problem))))))
    suite-name))

;;; --- run ---------------------------------------------------------------------------------------

(defun run (suite-name &key target out (viewports '(:desktop)) (schemes '(:light))
                         browser-arguments (explain t))
  "Run the suite SUITE-NAME and write its report. Returns true when no step failed, and the path of
report.txt.

TARGET is the target to run against, by default the one the suite's :TARGET form returns. OUT is
the directory for report.json, report.txt and the screenshots, by default *DEFAULT-OUT*.
VIEWPORTS (:DESKTOP, :PHONE) and SCHEMES (:LIGHT, :DARK) are lists; the first of each is the one
the cases run in, and each :SCREENSHOT step captures every combination. BROWSER-ARGUMENTS are
extra arguments for AION/CDP:LAUNCH-BROWSER, which refuses any that would show a window. EXPLAIN
prints FiveAM's account of the run.

Each case and row is one FiveAM test in a suite this function makes, and each step is one check.
Without a browser every test is skipped, or fails when OURANOS_REQUIRE_BROWSER=1."
  (let ((suite (or (find-suite suite-name)
                   (%invalid "no suite is defined as ~A" (%name-string suite-name)))))
    (unless (and viewports (every (lambda (v) (assoc v +viewports+)) viewports))
      (%invalid ":VIEWPORTS is a non-empty list of ~{~S~^, ~}; got ~S"
                (mapcar #'first +viewports+) viewports))
    (unless (and schemes (every (lambda (s) (member s '(:light :dark))) schemes))
      (%invalid ":SCHEMES is a non-empty list of :LIGHT and :DARK; got ~S" schemes))
    (let* ((target (or target
                       (and (suite-target suite) (funcall (suite-target suite)))
                       (%invalid "the suite ~A has no :TARGET, and RUN was given none"
                                 (suite-name suite))))
           (out (uiop:ensure-directory-pathname (merge-pathnames (or out *default-out*))))
           (plan (%plan suite))
           (fiveam-suite (%make-fiveam-suite suite plan))
           (context (%make-run-context :suite suite :target target :out out
                                       :viewports viewports :schemes schemes))
           (state (%make-run-state :context context))
           (executable (cdp:find-browser))
           (results '())
           (browser-version nil))
      (unless (typep target 'target)
        (%invalid "a target is made by URL-TARGET, PROCESS-TARGET or an aux system; got ~S" target))
      (log:info "dokimasia run starting" :suite (suite-name suite) :rows (length plan))
      (flet ((run-tests ()
               (let ((*run-state* state))
                 (setf results (fiveam:run fiveam-suite)))))
        (if (null executable)
            (progn
              (setf (run-state-mode state) :no-browser
                    (run-state-reason state)
                    "no Chrome or Edge was found; set OURANOS_BROWSER to the browser to run")
              (run-tests))
            (let ((started nil))
              (unwind-protect
                   (handler-case
                       (progn
                         (setf (run-state-base-url state) (target-start target)
                               started t)
                         (cdp:with-browser (browser :executable executable
                                                    :arguments browser-arguments :timeout 60)
                           (setf (run-context-browser context) browser
                                 browser-version (cdp:browser-version browser)
                                 (run-state-mode state) :running)
                           (run-tests)))
                     (error (c)
                       (when (null results)
                         (setf (run-state-mode state) :not-started
                               (run-state-reason state) (%clip (princ-to-string c) 400))
                         (run-tests))))
                (when started (target-stop target))))))
      (when explain (fiveam:explain! results))
      (let* ((reports (reverse (run-state-reports state)))
             (path (write-report reports
                                 (list :suite (suite-name suite)
                                       :base-url (run-state-base-url state)
                                       :browser browser-version
                                       :viewports viewports :schemes schemes)
                                 out)))
        (destructuring-bind (passed failed not-run) (%counts reports)
          (log:info "dokimasia run finished" :suite (suite-name suite) :passed passed
                                             :failed failed :not-run not-run))
        (values (and (fiveam:results-status results) t) path)))))
