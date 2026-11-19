;;;; suite-status.lisp --- record a leg's failing suites, and compare them with an earlier run (#199)
;;;;
;;;;   sbcl --script scripts/suite-status.lisp write LOG OUT platform=P commit=C run=R event=E
;;;;   sbcl --script scripts/suite-status.lisp diff CURRENT BASELINE
;;;;
;;;; A job's conclusion is one bit, and the job summary (scripts/ci-job-summary.sh, #167) lists
;;;; the suites that failed, but a reader still has to notice that a red leg's list got longer.
;;;; This script records each leg's failing items in a small file, which verify.yml uploads as an
;;;; artifact, and compares the file with the same platform's file from an earlier run on main,
;;;; which scripts/ci-suite-baseline.sh finds and downloads.
;;;;
;;;; WRITE reads LOG, the gate's output (verify.log), and writes OUT:
;;;;
;;;;   platform: macos-arm64
;;;;   commit: <the commit the run checked out>
;;;;   run: <the run id>
;;;;   event: push
;;;;   gate: pass | fail | unfinished
;;;;   failing: <one line per item, sorted>
;;;;
;;;; An item is one reason the gate printed under `VERDICT: FAIL', such as "DOKIMASIA/HYPERION/TESTS
;;;; had failing checks". Those reasons cover failing suites and also the gate's own checks, a
;;;; system that did not compile and a zero check count, which the `  FAIL' lines alone do not.
;;;; A number standing on its own in a reason is written as N, so that "3 suites" and "4 suites"
;;;; are the same item in two runs; a number inside a name, such as IPV6, is kept. The gate is
;;;; `unfinished' when the log has no `VERDICT: PASS' or `VERDICT: FAIL' line.
;;;;
;;;; DIFF reads two such files and prints a Markdown section for the job summary: the items that
;;;; fail in CURRENT and not in BASELINE, the ones that recovered, and the ones still failing. It
;;;; names the baseline's run and commit, so a reader can check what was compared. When BASELINE
;;;; is missing, unreadable, or a one-line note beginning `unavailable:' (written by
;;;; ci-suite-baseline.sh when no earlier run could be read), it prints one line saying so.
;;;;
;;;; It reports and never decides: both modes exit 0 whatever the logs say, and 2 only on a
;;;; usage error. A leg with a newly failing suite is already red, because the gate failed it.

(require :asdf)

(defun %lines-of (path)
  "PATH's lines with carriage returns removed (the Windows leg writes them), or NIL when PATH
cannot be read."
  (ignore-errors
   (with-open-file (s path :external-format '(:utf-8 :replacement #\?))
     (loop for line = (read-line s nil)
           while line
           collect (remove #\Return line)))))

(defun %standalone-numbers-as-n (text)
  "TEXT with each run of digits that is not part of a word replaced by N."
  (with-output-to-string (out)
    (let ((i 0) (n (length text)))
      (loop while (< i n)
            do (let ((c (char text i)))
                 (if (digit-char-p c)
                     (let ((end (or (position-if-not #'digit-char-p text :start i) n)))
                       (if (or (and (> i 0) (alphanumericp (char text (1- i))))
                               (and (< end n) (alphanumericp (char text end))))
                           (write-string text out :start i :end end)
                           (write-char #\N out))
                       (setf i end))
                     (progn (write-char c out) (incf i))))))))

(defun %gate-state (lines)
  "pass, fail or unfinished, from the last verdict line in LINES."
  (let ((last (find-if (lambda (l) (member l '("VERDICT: PASS" "VERDICT: FAIL") :test #'string=))
                       lines :from-end t)))
    (cond ((null last) "unfinished")
          ((string= last "VERDICT: PASS") "pass")
          (t "fail"))))

(defun %failing-items (lines)
  "The sorted, distinct reasons under the last `VERDICT: FAIL' line in LINES."
  (let ((tail (member "VERDICT: FAIL" (reverse lines) :test #'string=)))
    (when tail
      (let* ((after (nthcdr (length tail) lines))
             (items (loop for l in after
                          while (uiop:string-prefix-p "  - " l)
                          collect (%standalone-numbers-as-n
                                   (string-trim " " (subseq l 4))))))
        (sort (remove-duplicates items :test #'string=) #'string<)))))

(defun %write-status (log out fields)
  (let* ((lines (%lines-of log))
         (gate (if lines (%gate-state lines) "unfinished")))
    (ensure-directories-exist out)
    (with-open-file (s out :direction :output :if-exists :supersede :external-format :utf-8)
      (dolist (key '("platform" "commit" "run" "event"))
        (format s "~A: ~A~%" key (or (cdr (assoc key fields :test #'string=)) "unknown")))
      (format s "gate: ~A~%" gate)
      (dolist (item (and (string= gate "fail") (%failing-items lines)))
        (format s "failing: ~A~%" item)))
    (format t "suite-status: wrote ~A (gate ~A)~%" out gate)))

(defun %read-status (path)
  "A status file as an alist (KEY . VALUE), with every `failing' value under :FAILING; or
(:UNAVAILABLE . reason) when PATH is not a readable status file."
  (let ((lines (%lines-of path)))
    (cond
      ((null lines)
       (list (cons :unavailable (format nil "no baseline file at ~A" path))))
      ((uiop:string-prefix-p "unavailable:" (first lines))
       (list (cons :unavailable (string-trim " " (subseq (first lines) 12)))))
      ((not (find-if (lambda (l) (uiop:string-prefix-p "gate: " l)) lines))
       (list (cons :unavailable (format nil "~A is not a suite-status file" path))))
      (t
       (let ((alist '()) (failing '()))
         (dolist (l lines)
           (let ((colon (search ": " l)))
             (when colon
               (let ((key (subseq l 0 colon)) (value (subseq l (+ colon 2))))
                 (if (string= key "failing")
                     (push value failing)
                     (push (cons key value) alist))))))
         (cons (cons :failing (sort failing #'string<)) alist))))))

(defun %field (status key)
  (or (cdr (assoc key status :test #'equal)) "unknown"))

(defun %short-sha (sha)
  (if (>= (length sha) 8) (subseq sha 0 8) sha))

(defun %print-items (heading items)
  (format t "**~A** (~D):~%~%```~%~{~A~%~}```~%~%" heading (length items) items))

(defun %diff (current-path baseline-path)
  (let ((current (%read-status current-path))
        (baseline (%read-status baseline-path)))
    (cond
      ((assoc :unavailable current)
       (format t "**Compared with the previous run on main:** not compared, because this run's own status could not be read (~A).~%~%"
               (cdr (assoc :unavailable current))))
      ((assoc :unavailable baseline)
       (format t "**Compared with the previous run on main:** not compared, because no earlier run's status could be read: ~A~%~%"
               (cdr (assoc :unavailable baseline))))
      ((string= (%field baseline "gate") "unfinished")
       (format t "**Compared with the previous run on main:** not compared, because the gate of run ~A at ~A did not finish.~%~%"
               (%field baseline "run") (%short-sha (%field baseline "commit"))))
      ((string= (%field current "gate") "unfinished")
       (format t "**Compared with the previous run on main:** not compared, because this run's gate did not finish.~%~%"))
      (t
       (let* ((now (cdr (assoc :failing current)))
              (before (cdr (assoc :failing baseline)))
              (new (set-difference now before :test #'string=))
              (recovered (set-difference before now :test #'string=))
              (still (intersection now before :test #'string=)))
         (format t "**Compared with run ~A on main at ~A** (~A, ~A):"
                 (%field baseline "run") (%short-sha (%field baseline "commit"))
                 (%field baseline "platform") (%field baseline "event"))
         (let ((note (cdr (assoc "baseline-note" baseline :test #'equal))))
           (when note (format t " ~A" note)))
         (if (and (null now) (null before))
             (format t " the same, no failing items in either run.~%~%")
             (progn
               (format t "~%~%")
               (if new
                   (%print-items "Newly failing" (sort new #'string<))
                   (format t "Newly failing: none.~%~%"))
               (if recovered
                   (%print-items "Recovered" (sort recovered #'string<))
                   (format t "Recovered: none.~%~%"))
               (when still
                 (%print-items "Still failing" (sort still #'string<))))))))))

(defun %fields (args)
  (loop for a in args
        for eq = (position #\= a)
        when eq collect (cons (subseq a 0 eq) (subseq a (1+ eq)))))

(defun main (args)
  (cond
    ((and (string= (or (first args) "") "write") (>= (length args) 3))
     (%write-status (second args) (third args) (%fields (nthcdr 3 args))))
    ((and (string= (or (first args) "") "diff") (= (length args) 3))
     (%diff (second args) (third args)))
    (t
     (format *error-output* "usage: suite-status.lisp write LOG OUT [platform=P commit=C run=R event=E]~%       suite-status.lisp diff CURRENT BASELINE~%")
     (uiop:quit 2)))
  (finish-output)
  (uiop:quit 0))

(main (rest sb-ext:*posix-argv*))
