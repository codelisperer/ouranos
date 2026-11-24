;;;; report.lisp --- report.json and report.txt (#1028, dokimasia ADR-0001, point 2).
;;;;
;;;; For each case and row: the verdict, the step that decided it and why, each step with its
;;;; duration, the console and network findings, the files written, and the requirement id.
;;;; report.txt starts with one line per case and row, failures first and then rows not run, so a
;;;; person can read the result of a run without opening the JSON.

(in-package #:dokimasia)

(defstruct (row-report (:constructor %make-row-report))
  case-name row-id requirement user verdict decided-at decided-label reason
  steps console network artifacts duration-ms)

(defun %row-report (dcase row-id user steps)
  "The report of a row of DCASE whose steps ended as STEPS, a list of plists with :LABEL,
:OUTCOME, :REASON and :MS, in order. The verdict comes from dokimasia/core."
  (flet ((checked (list type argument)
           (boundary:check-elements list type :function 'core:make-row-results
                                              :argument argument)))
    (let* ((results (core:make-row-results
                     (checked (mapcar (lambda (s) (getf s :label)) steps) 'string 'labels)
                     (checked (mapcar (lambda (s) (getf s :outcome)) steps) 'string 'kinds)
                     (checked (mapcar (lambda (s) (getf s :reason)) steps) 'string 'reasons)
                     (checked (mapcar (lambda (s) (getf s :ms)) steps)
                              '(and fixnum unsigned-byte) 'durations)))
           (verdict (core:row-verdict results))
           (kind (core:verdict-kind verdict)))
      (%make-row-report
       :case-name (dcase-name dcase) :row-id row-id :requirement (dcase-requirement dcase)
       :user user :verdict kind
       :decided-at (and (string/= kind "passed") (plusp (core:row-step-count results))
                        (1+ (core:verdict-step-index verdict)))
       :decided-label (core:verdict-step-label verdict)
       :reason (core:verdict-reason verdict)
       :steps steps :duration-ms (core:total-duration-ms results)))))

(defun %verdict-word (kind)
  (cond ((string= kind "passed") "PASSED")
        ((string= kind "failed") "FAILED")
        (t "NOT RUN")))

(defun %verdict-rank (kind)
  (cond ((string= kind "failed") 0) ((string= kind "not-run") 1) (t 2)))

(defun %row-title (r)
  (format nil "~A ~A~@[ [~A]~]" (row-report-case-name r) (row-report-row-id r)
          (row-report-requirement r)))

(defun %summary-line (r)
  (format nil "~8A ~A~@[: step ~D ~A: ~A~]"
          (%verdict-word (row-report-verdict r)) (%row-title r)
          (row-report-decided-at r)
          (row-report-decided-label r) (row-report-reason r)))

(defun %counts (reports)
  (list (count "passed" reports :key #'row-report-verdict :test #'string=)
        (count "failed" reports :key #'row-report-verdict :test #'string=)
        (count "not-run" reports :key #'row-report-verdict :test #'string=)))

(defun write-report-text (reports info stream)
  "Write report.txt for REPORTS, a list of ROW-REPORT in run order, to STREAM. INFO is a plist
with :SUITE, :BASE-URL, :BROWSER, :VIEWPORTS and :SCHEMES."
  (destructuring-bind (passed failed not-run) (%counts reports)
    (format stream "dokimasia: the suite ~A against ~A~%" (getf info :suite)
            (or (getf info :base-url) "no target"))
    (format stream "~D row~:P: ~D passed, ~D failed, ~D not run.~@[ Browser: ~A.~] Viewports: ~{~(~A~)~^, ~}. Schemes: ~{~(~A~)~^, ~}.~%~%"
            (length reports) passed failed not-run (getf info :browser)
            (getf info :viewports) (getf info :schemes)))
  (dolist (r (stable-sort (copy-list reports) #'< :key (lambda (r) (%verdict-rank (row-report-verdict r)))))
    (format stream "~A~%" (%summary-line r)))
  (format stream "~%--- each row~%")
  (dolist (r reports)
    (format stream "~%~A  ~(~A~)  ~D ms~@[  signed in as ~A~]~%" (%row-title r)
            (%verdict-word (row-report-verdict r)) (row-report-duration-ms r) (row-report-user r))
    (loop for s in (row-report-steps r)
          for i from 1
          do (format stream "  ~2D ~8A ~6D ms  ~A~@[~%              ~A~]~%" i
                     (%verdict-word (getf s :outcome)) (getf s :ms) (getf s :label)
                     (let ((why (getf s :reason))) (and (plusp (length why)) why))))
    (dolist (c (row-report-console r))
      (format stream "  console: ~A: ~A~:[~; (listed as known, so not a failure)~]~%"
              (getf c :kind) (%clip (getf c :message) 300) (getf c :ignored)))
    (dolist (n (row-report-network r))
      (if (getf n :status)
          (format stream "  network: ~A answered ~D~%" (getf n :url) (getf n :status))
          (format stream "  network: a request failed: ~A~%" (getf n :message))))
    (dolist (a (row-report-artifacts r))
      (format stream "  file: ~A~%" a))))

(defun %json-plist (plist)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on plist by #'cddr
          do (setf (gethash (string-downcase (symbol-name k)) h)
                   (cond ((eq v t) t)
                         ((null v) 'null)
                         ((and (listp v) (every #'listp v) (keywordp (first (first v))))
                          (map 'vector #'%json-plist v))
                         ((listp v) (coerce v 'vector))
                         ((symbolp v) (string-downcase (symbol-name v)))
                         (t v))))
    h))

(defun report-json (reports info)
  "report.json for REPORTS and INFO, as a string."
  (destructuring-bind (passed failed not-run) (%counts reports)
    (jzon:stringify
     (%json-plist
      (list :suite (getf info :suite) :base-url (getf info :base-url)
            :browser (getf info :browser)
            :viewports (mapcar (lambda (v) (string-downcase (symbol-name v))) (getf info :viewports))
            :schemes (mapcar (lambda (v) (string-downcase (symbol-name v))) (getf info :schemes))
            :passed passed :failed failed :not-run not-run
            :rows (mapcar (lambda (r)
                            (list :case (row-report-case-name r) :row (row-report-row-id r)
                                  :requirement (row-report-requirement r)
                                  :user (row-report-user r)
                                  :verdict (row-report-verdict r)
                                  :decided-at-step (row-report-decided-at r)
                                  :decided-by (let ((l (row-report-decided-label r)))
                                                (and (plusp (length l)) l))
                                  :reason (let ((why (row-report-reason r)))
                                            (and (plusp (length why)) why))
                                  :duration-ms (row-report-duration-ms r)
                                  :steps (or (row-report-steps r) #())
                                  :console (or (row-report-console r) #())
                                  :network (or (row-report-network r) #())
                                  :artifacts (or (row-report-artifacts r) #())))
                          reports)))
     :pretty t)))

(defun write-report (reports info out)
  "Write report.json and report.txt for REPORTS into the directory OUT. Returns report.txt's path."
  (let ((json (merge-pathnames "report.json" out))
        (text (merge-pathnames "report.txt" out)))
    (ensure-directories-exist json)
    (with-open-file (s json :direction :output :if-exists :supersede :external-format :utf-8)
      (write-string (report-json reports info) s))
    (with-open-file (s text :direction :output :if-exists :supersede :external-format :utf-8)
      (write-report-text reports info s))
    text))
