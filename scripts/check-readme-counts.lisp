;;;; check-readme-counts.lisp --- prove README.md's check counts against a verify-tree log.
;;;;
;;;;   sbcl --script scripts/check-readme-counts.lisp --from verify.log
;;;;       compare against a log someone already produced (what CI does)
;;;;   sbcl --dynamic-space-size 4096 --script scripts/check-readme-counts.lisp
;;;;       run the gate first, then compare
;;;;   sbcl --script scripts/check-readme-counts.lisp --from verify.log --update
;;;;       write the gate's numbers into README.md instead of reporting them
;;;;
;;;; Exit 0 in sync, 1 on drift, 2 if the log cannot be trusted to answer the question.
;;;;
;;;; IT WRITES TO THE CHECKOUT YOU ARE STANDING IN, AND REFUSES IF THAT IS NOT ITS OWN
;;;; (pre-publication issue 450). The root used to come from `*load-truename*' alone, so running one checkout's
;;;; copy from another rewrote the SCRIPT's README and left the caller's untouched -- while
;;;; reporting `VERDICT: UPDATED', because from where the script sat nothing had gone wrong.
;;;; It dirtied the hub's tree exactly that way. The caller's tree staying clean is the half
;;;; that makes it hard to notice: there is no local diff to look at.
;;;;
;;;; `*load-truename*' answers *where does this code live*, which is not the question a
;;;; writer has to answer. The question is *which README did you mean*, and only the working
;;;; directory expresses that. So cwd decides, and a disagreement between the two is refused
;;;; rather than resolved -- nothing here can tell which was meant, and picking either is how
;;;; it picked wrong before. The resolver is shared: scripts/tree-root.lisp (pre-publication issue 480).
;;;;
;;;; THE READERS HAVE IT TOO, as of pre-publication issue 480. It started here because a wrong write is not
;;;; recoverable, but `a wrong report can be read twice' did not survive contact with how a
;;;; green checker is actually treated, which is that nobody reads it at all.
;;;;
;;;; REBASE FIRST, THEN DERIVE. Against an un-rebased branch this reports every number that
;;;; moved between the branch point and main -- including work somebody else merged in the
;;;; meantime. Those are true of the MERGE RESULT and false of your diff, and committing them
;;;; puts a change in your diff that your diff did not cause, leaving the next reader to work
;;;; out which numbers were yours. (Found on pre-publication PR 338: it correctly wanted praxeon 115 -> 130
;;;; alongside that branch's own aion +9, because pre-publication PR 256 landed after the branch was cut.
;;;; Rebasing first gave the 9 alone.)
;;;;
;;;; FEEDING IT A CI LOG: `gh run view --log` does not always label the step -- one run
;;;; returned `UNKNOWN STEP` on every line -- so an extraction that greps for a step name
;;;; works until it silently does not. %STRIP-LOG-PREFIX takes what follows the last TAB and
;;;; drops a leading ISO timestamp, which is label-independent: pipe the whole job log in and
;;;; let it do that. An empty extraction exits 2 rather than reporting an empty tree as drift.
;;;;
;;;; WHY THIS EXISTS. The Status table's counts were corrected three times in three days by
;;;; two sessions, and were stale again within the hour each time -- because every merge
;;;; invalidates them and nothing checked. Same shape as docs/dependencies.md being a
;;;; serialisation point (#118): a hand-maintained number duplicating what a script already
;;;; computes. The fix is the same one -- keep the number in one place and check the copy.
;;;;
;;;; IT DERIVES THE NUMBERS AND NOT THE PROSE, deliberately. The "Where it is" column is
;;;; judgement -- what is alpha, what is *(in progress)*, which caveat a reader needs -- and
;;;; a generator would flatten it into an inventory, which is the mistake #118 warns against
;;;; for the dependency manifest. Only the Checks column and the total are mechanical.
;;;;
;;;; THE COUNTS ARE PLATFORM-SPECIFIC, SO ONE HOST HAS TO BE CANONICAL. The same tree at the
;;;; same commit gives different totals per host by design: a Mac cannot run
;;;; AION/WINDOWS/COM/TESTS, and HYPERION/UPDATE/TESTS is 217 on darwin against 261 on
;;;; windows despite carrying no platform in its name. The canonical host is the Linux CI
;;;; leg, because it is the only one that runs on every pull request AND every push to main
;;;; (verify.yml's matrix include), and it sets OURANOS_WITH_UV=1 -- so it is the one number
;;;; a reader can reproduce by clicking the badge. This script does not enforce that choice;
;;;; it prints the host it read, and the README says which host it quotes.

(require :uiop)

;;; Captured at load time and passed explicitly: `*load-truename*' is bound while this file
;;; loads and MAIN runs during that load, but reading it from inside a function ties the
;;; answer to when the function happens to be called.
(defparameter *script* (or *load-truename* *load-pathname*))
(load (merge-pathnames "tree-root.lisp" (uiop:pathname-directory-pathname *script*)))

;;; --- reading the gate's output ---------------------------------------------

(defun %strip-log-prefix (line)
  "LINE with a CI log wrapper removed, if it has one.

`gh run view --log' prefixes every line with `<job>\t<step>\t<ISO timestamp> '. A TAB is a
sound discriminator here rather than a guess: verify-tree emits no tab characters at all --
its column alignment is `~34t', which FORMAT fills with spaces -- so a tab in the stream
came from the log wrapper and nothing else. Named and applied uniformly, with the
reconciliation in MAIN as the independent check that it did not eat anything real."
  (let* ((tab (position #\Tab line :from-end t))
         (rest (if tab (subseq line (1+ tab)) line))
         (space (position #\Space rest)))
    (if (and space
             (find #\T rest :end space)
             (char= #\Z (char rest (1- space)))
             (digit-char-p (char rest 0)))
        (subseq rest (1+ space))
        rest)))

(defun %verdict (lines)
  "verify-tree's OWN verdict -- the last `VERDICT: PASS' or `VERDICT: FAIL' in LINES.

The last, and matched exactly, because it is not the only verdict in a CI log: the pin
checker the workflow runs first prints `VERDICT: the Coalton that LOADS is the pinned one.'
Taking the first match read that one, and a green run would have been rejected as unusable
with a message about the wrong script."
  (let (found)
    (dolist (l lines found)
      (let ((trimmed (string-trim " " l)))
        (when (or (string= trimmed "VERDICT: PASS") (string= trimmed "VERDICT: FAIL"))
          (setf found trimmed))))))

(defun %labelled-integer (lines label)
  "The integer following LABEL on the first line containing it, or NIL."
  (dolist (l lines nil)
    (let ((p (search label l)))
      (when p
        (let* ((tail (string-left-trim " " (subseq l (+ p (length label)))))
               (digits (or (position-if-not #'digit-char-p tail) (length tail))))
          (return (when (plusp digits) (parse-integer tail :end digits))))))))

(defun %labelled-string (lines label)
  "The text after LABEL on the first line that BEGINS with it, or NIL (pre-publication issue 385).

Anchored at position 0 on purpose: `total checks executed: 4400 (axes: base+uv)' contains
`axes: ' too, and a search that matched it would read the human sentence rather than the
machine line. NIL and a value are different answers -- a log predating these lines has
UNKNOWN coverage, which is not the same as known-full and must not be treated as it."
  (dolist (l lines nil)
    (let ((p (search label l)))
      (when (eql p 0)
        (return (string-trim " " (subseq l (length label))))))))

(defun %host (lines)
  "The host the gate reported, from its `PLATFORM (host: darwin)' banner."
  (dolist (l lines "unknown")
    (let ((p (search "PLATFORM (host: " l)))
      (when p
        (let* ((start (+ p (length "PLATFORM (host: ")))
               (end (position #\) l :start start)))
          (return (if end (subseq l start end) "unknown")))))))

(defun %suite-line (line)
  "For a passing suite line, return (values SUITE-NAME CHECKS); otherwise NIL.

Matches `  ok      HYPERION/TESTS          809 checks' and tolerates the `(N skipped)' the
gate appends. Only `ok' lines are read, and that is sound ONLY because this script refuses
a log whose verdict is not PASS: verify-tree also adds a WARN suite's and a partially
failing suite's checks to its grand total, so on a red log an ok-only sum would be short --
silently, and in the direction that looks like a README that is merely out of date. The
reconciliation in MAIN is what makes that refusal verifiable rather than asserted."
  (let ((trimmed (string-trim " " line)))
    (when (and (> (length trimmed) 3) (string= "ok " trimmed :end2 3))
      (let* ((rest (string-left-trim " " (subseq trimmed 3)))
             (space (position #\Space rest)))
        (when space
          (let* ((name (subseq rest 0 space))
                 (tail (string-left-trim " " (subseq rest space)))
                 (digits (or (position-if-not #'digit-char-p tail) (length tail))))
            ;; The LOADING section prints `  ok      AION' with no count. No space after the
            ;; name means no number, which is how a system line is told from a suite line.
            (when (plusp digits)
              (values name (parse-integer tail :end digits)))))))))

(defun %replace-substring (line old new)
  "LINE with the first occurrence of OLD replaced by NEW, or LINE unchanged."
  (let ((p (search old line)))
    (if p (concatenate 'string (subseq line 0 p) new (subseq line (+ p (length old)))) line)))

(defun %framework-of (suite)
  "The framework a suite belongs to: everything before the first slash, downcased."
  (let ((slash (position #\/ suite)))
    (string-downcase (if slash (subseq suite 0 slash) suite))))

(defun gate-totals (lines)
  "An alist of (framework . checks) summed over the passing suite lines in LINES."
  (let ((per (make-hash-table :test #'equal)))
    (dolist (l lines)
      (multiple-value-bind (name checks) (%suite-line l)
        (when name (incf (gethash (%framework-of name) per 0) checks))))
    (let (alist)
      (maphash (lambda (k v) (push (cons k v) alist)) per)
      (sort alist #'string< :key #'car))))

;;; --- reading the README ----------------------------------------------------

(defun readme-rows (lines)
  "Alist of (framework checks . line-index) for the Status table's rows.

A row is `| **name** | prose | N |'. Taking the SECOND-TO-LAST cell rather than the third
keeps a prose cell that contains a pipe from shifting the column. The prose itself is read
by nothing here and written by nothing here."
  (let (rows (i -1))
    (dolist (l lines (nreverse rows))
      (incf i)
      (let ((trimmed (string-trim " " l)))
        (when (and (plusp (length trimmed)) (char= #\| (char trimmed 0)))
          (let* ((cells (uiop:split-string trimmed :separator "|"))
                 (name (and (> (length cells) 3) (string-trim " *" (second cells))))
                 (last (and (> (length cells) 3)
                            (string-trim " " (nth (- (length cells) 2) cells)))))
            (when (and name last (plusp (length last)) (every #'digit-char-p last))
              (push (list* (string-downcase name) (parse-integer last) i) rows))))))))

(defun readme-total (lines)
  "(values N line-index) for the README's headline `**N checks**', or NIL."
  (loop for l in lines
        for idx from 0 do
    (let ((p (search "**" l)))
      (loop while p do
        (let* ((tail (subseq l (+ p 2)))
               (digits (or (position-if-not #'digit-char-p tail) (length tail))))
          (when (and (plusp digits) (search " checks**" tail :start2 digits :end2 (min (length tail) (+ digits 9))))
            (return-from readme-total (values (parse-integer tail :end digits) idx))))
        (setf p (search "**" l :start2 (+ p 2)))))))

(defun %replace-last-integer (line new)
  "LINE with its LAST run of digits replaced by NEW.

The last run, not the first, because a row's prose legitimately contains numbers -- issue
references like (pre-publication issue 172) and version strings like Bulma 1.x sit in the same line as the count.
The count is always the final cell, so the final digit run is the one to touch, and the
prose is returned byte-for-byte either side of it."
  (let ((end (position-if #'digit-char-p line :from-end t)))
    (when end
      (let ((start (1+ (or (position-if-not #'digit-char-p line :from-end t :end end) -1))))
        (concatenate 'string (subseq line 0 start) (princ-to-string new)
                     (subseq line (1+ end)))))))

(defparameter +leg-names+
  '(("linux" "linux")
    ("darwin" "macos" "darwin" "mac")
    ("windows" "windows"))
  "Host key -> the words a README headline might use for that leg.")

(defun headline-leg (line)
  "The platform the README's headline CLAIMS its figure came from, or NIL.

Reading the prose is the point. pre-publication issue 330 made the headline name its leg -- \"on the Linux CI
leg\" -- which fixed a number that was silently platform-specific. But the label is prose and
the figure is derived, and until this function nothing checked that the two agreed: a macOS
gate could be written straight into a line claiming Linux, producing a number that is wrong
in a NEW way and looks more trustworthy than the one it replaced. Found by doing exactly
that."
  (let ((low (string-downcase line)))
    (loop for (host . words) in +leg-names+
          when (some (lambda (w) (search w low)) words)
            do (return host))))

(defun gate-commit (lines)
  "The commit the GATE ran at, read from its own output, or NIL.

Read from the log rather than from `git rev-parse' because the two are routinely different
and only one of them is true: --from takes a CI log produced on another machine at another
commit, and stamping the README with whatever the local checkout happens to be at would
manufacture provenance rather than record it. Older logs carry no such line, and the caller
falls back to local HEAD and says so."
  (dolist (l lines)
    (let ((p (search "commit: " l)))
      (when (and p (zerop p))
        (let ((v (string-trim " " (subseq l (+ p 8)))))
          (when (and (plusp (length v)) (string/= v "unknown"))
            (return-from gate-commit v))))))
  nil)

(defun provenance-index (lines)
  "Index of the line carrying the measured-at clause, or NIL.

Anchored on its own opening words rather than on the headline count, because the count is
gone (pre-publication issue 330's successor) and because \"CI leg\" appears twice in README.md -- once in the
paragraph explaining which leg is canonical, once here. Anchoring on the ambiguous substring
would stamp the explanation."
  (loop for l in lines
        for idx from 0
        when (search "Counts above are from" l) do (return idx)))

(defun headline-sha (line)
  "The commit the headline's count was MEASURED AT, or NIL when it carries none.

A count without its commit is a rumour (AGENTS.md): a reader whose own number differs cannot
tell whether the cause is the host, the tree, or a real defect. Platform was already recorded
(pre-publication issue 330); this is the other half."
  (let ((p (search " at `" line)))
    (when p
      (let* ((start (+ p 5))
             (end (position #\` line :start start)))
        (when end (subseq line start end))))))

(defun set-headline-sha (line sha)
  "LINE with its measured-at commit set to SHA, inserting the clause if absent.

NOTE WHAT THIS CLAIM DOES NOT DO: it does not go stale. It says the figure was measured at
that commit, which stays true forever. So it is rewritten only when a count actually changes
-- stamping every commit would be the contention this script exists to avoid, and would buy
nothing, because a number that has not moved since it was measured is still that number."
  (let ((p (search " at `" line)))
    (if p
        (let* ((start (+ p 5))
               (end (position #\` line :start start)))
          (if end
              (concatenate 'string (subseq line 0 start) sha (subseq line end))
              line))
        (let ((leg (search "CI leg" line)))
          (if leg
              (let ((after (+ leg (length "CI leg"))))
                (concatenate 'string (subseq line 0 after)
                             (format nil " at `~a`" sha)
                             (subseq line after)))
              line)))))

(defun write-counts (readme lines rows gate claimed-total total-index prov-index grand sha)
  ;; SHA is NIL when the gate log does not record one -- see the caller.
  "Rewrite README's numbers in place from the gate. Returns the number of lines changed.

It edits ONLY the digit runs it was asked to edit -- no reflowing, no regeneration. The
prose in every row is judgement (#118) and a rewriter that touched it would be the very
generator this script exists not to be."
  (let ((out (copy-seq lines)) (changed 0))
    (dolist (row rows)
      (let* ((fw (first row)) (claimed (second row)) (idx (cddr row))
             (actual (cdr (assoc fw gate :test #'string=))))
        (when (and actual (/= actual claimed))
          (let ((new (%replace-last-integer (nth idx out) actual)))
            (when new (setf (nth idx out) new) (incf changed))))))
    ;; The headline reads `**4108 checks**, each suite in its own image.' -- the LAST digit
    ;; run on that line is not the count, so it is replaced by name rather than by position.
    (when (and total-index claimed-total (/= claimed-total grand))
      (setf (nth total-index out)
            (%replace-substring (nth total-index out)
                                (format nil "**~D checks**" claimed-total)
                                (format nil "**~D checks**" grand)))
      (incf changed))
    ;; STAMPED WHENEVER THIS RUNS, not only when a count moved (pre-publication issue 438). It used to require
    ;; `(plusp changed)' or an absent clause, on the reasoning that "measured at X" stays true
    ;; and rewriting it every commit is churn. That reasoning is sound for the CHECK and wrong
    ;; for the WRITE, and the difference cost a false line on #159:
    ;;
    ;;   two count-changing PRs measured at different commits merge; the second rebases; its
    ;;   rows are now IN SYNC with the merged tree, so nothing drifted, so the clause was left
    ;;   naming the OTHER PR's commit -- a run that measured the tree WITHOUT this change. The
    ;;   rows were verified at b488d02 under a line saying 404fedb, and CI passed.
    ;;
    ;; The failure is green and it misleads in the one direction that matters: a reader
    ;; reconciling the figure checks out the named commit, runs the gate, gets a lower number,
    ;; and concludes the README drifted. The README was right and the pointer was wrong.
    ;;
    ;; There is no churn to avoid here, because `--update' is not run on every commit -- it is
    ;; run deliberately, by a lane whose counts are moving or which has just rebased. A run of
    ;; `--update' that leaves this clause naming a different commit than the log it just read
    ;; IS the defect. The CHECK still treats a mismatch as "measured earlier, still true",
    ;; correctly: it holds one log, from this run, and cannot obtain one from the named commit,
    ;; so failing on the difference would enforce a claim nothing can verify.
    ;;
    ;; Stamp ONLY with a commit the gate itself reported. A log that records none leaves the
    ;; clause alone rather than borrowing whatever the local checkout is at -- that would
    ;; manufacture provenance instead of recording it, which is the failure this clause
    ;; exists to prevent, committed by the tool meant to prevent it.
    (when (and prov-index sha)
      (let ((new (set-headline-sha (nth prov-index out) sha)))
        (when (and new (string/= new (nth prov-index out)))
          (setf (nth prov-index out) new)
          (incf changed))))
    (with-open-file (s readme :direction :output :if-exists :supersede)
      (write-string (format nil "~{~a~^~%~}" out) s))
    changed))

;;; --- the report ------------------------------------------------------------

(defun die (code fmt &rest args)
  (format *error-output* "~&check-readme-counts: ~?~%" fmt args)
  (uiop:quit code))

(defun main ()
  (let* ((args (uiop:command-line-arguments))
         (from (second (member "--from" args :test #'string=)))
         (update (and (member "--update" args :test #'string=) t))
         (root (tree-root:resolve-or-die *script* "check-readme-counts"))
         (readme (merge-pathnames "README.md" root))
         (log-text
           (if from
               (uiop:read-file-string from)
               (progn
                 (format t "~&Running the gate (minutes, one image per system and suite)...~%")
                 (with-output-to-string (s)
                   (uiop:run-program
                    (list "sbcl" "--dynamic-space-size" "4096" "--script"
                          (uiop:native-namestring (merge-pathnames "scripts/verify-tree.lisp" root)))
                    :output s :error-output s :ignore-error-status t)))))
         (lines (mapcar #'%strip-log-prefix
                        (uiop:split-string log-text :separator '(#\Newline))))
         (verdict (%verdict lines))
         (host (%host lines))
         (grand (%labelled-integer lines "total checks executed:"))
         (axes (%labelled-string lines "axes: "))
         (declined (%labelled-string lines "axes-declined: ")))

    ;; Four ways a log cannot answer the question, each a different mistake to make.
    (unless grand
      (die 2 "the log has no `total checks executed' line -- it is not a completed ~
verify-tree run, and nothing can be derived from it."))
    (unless (equal verdict "VERDICT: PASS")
      (die 2 "the log's verdict is ~a. A red tree's counts are not the tree's counts: a ~
partially failing suite still contributes to the grand total, so publishing from this log ~
would record numbers no green run will reproduce. Fix the tree, then re-check."
           (or verdict "missing")))
    ;; A PARTIAL log is the same mistake as a red one, one axis over (pre-publication issue 385). A run that
    ;; declined an axis is green and correct and its total is simply not the tree's total:
    ;; 4065 and 4400 were both true of d0547d1, differing only by OURANOS_WITH_UV. This
    ;; script WRITES those figures into the README, so it is the last place the difference
    ;; can be caught before a smaller tree's number becomes the published one -- which then
    ;; reads as drift to everyone who measures the real tree afterwards.
    ;;
    ;; TWO refusals, not one message with a conditional clause, because they are different
    ;; claims and only one of them is knowable. A log that SAYS it declined uv is a measured
    ;; smaller tree. A log with no axes lines is UNKNOWN coverage -- it may well be a full
    ;; run from before pre-publication issue 385 -- and saying "smaller" about it would be the same overclaim
    ;; this whole change exists to stop, made by the code that stops it.
    ;; Both messages below are ONE line each, not `~'-continued strings: on a CRLF checkout
    ;; the character after `~' is #\Return, an illegal directive that fails at COMPILE time
    ;; (CLAUDE.md). The nine pre-existing continuations elsewhere in this file are #146 and
    ;; are deliberately left alone here -- rewriting other people's message text is not this
    ;; change's business, and #146 wants a per-file review rather than a sweep.
    ;; NEITHER MESSAGE NAMES THE AXES ANY MORE (pre-publication issue 410). Both used to end "re-run the gate with
    ;; every axis enabled (OURANOS_WITH_UV=1 for uv)", which was complete for exactly as long
    ;; as uv was the only axis. pre-publication PR 395 created a second one -- the native launcher -- and that
    ;; advice then pointed a reader whose log declined `view' at an unrelated variable. AN
    ;; ENUMERATION OF KNOWN AXES CANNOT REPORT AN AXIS ADDED LATER, which is the defect pre-publication issue 385
    ;; fixed in the gate's own output, reappearing one consumer over.
    ;;
    ;; So the reader is sent to the log's OWN `NOT COVERED' block. The gate builds that from
    ;; its axis registry, so it describes every axis that existed when the log was written --
    ;; including why each was off and how to enable it -- and it stays correct here without
    ;; anyone maintaining this sentence.
    (unless declined
      (die 2 "the log has no `axes-declined:' line, so its coverage is UNKNOWN (pre-publication issue 385). It may be a full run predating that line or a partial one; nothing in it distinguishes those, and treating unknown as full is the assumption that produced pre-publication issue 385. Re-run the gate with every axis enabled; its own `NOT COVERED' block names each one and says how."))
    (unless (equal declined "none")
      (die 2 "the log declined: ~a (coverage `~a'). Its total is a real measurement of a SMALLER tree, so publishing it would record counts that no full run reproduces -- indistinguishable, afterwards, from a README that drifted. Re-run with those axes enabled; the log's own `NOT COVERED' block says why each was off and how to enable it."
           declined (or axes "unstated")))

    (let* ((gate (gate-totals lines))
           (summed (reduce #'+ gate :key #'cdr :initial-value 0)))
      ;; The parser checks itself against the gate's own arithmetic. Without this, a change
      ;; to verify-tree's output format would make this script quietly report a smaller tree
      ;; -- which reads exactly like a README that drifted, and would be "fixed" by writing
      ;; the wrong numbers down. A producer verifying its own output cannot see that; the
      ;; gate's independently computed total can.
      (unless (= summed grand)
        (die 2 "parsed ~:D check~:P across ~D framework~:P but the gate reports ~:D. ~
This script is misreading the log, not finding drift -- verify-tree's suite-line format ~
has probably changed. Nothing was compared."
             summed (length gate) grand)))

    (let* ((readme-lines (uiop:split-string (uiop:read-file-string readme) :separator '(#\Newline)))
           (rows (readme-rows readme-lines))
           (claimed-total nil) (total-index nil) (prov-index nil)
           (gate (gate-totals lines))
           (logged-sha (gate-commit lines))
           (sha (or logged-sha
                    (string-trim '(#\Newline #\Space #\Return)
                                 (uiop:run-program '("git" "rev-parse" "--short" "HEAD")
                                                   :output :string :ignore-error-status t))))
           (drift '())
           (was nil))
      (multiple-value-setq (claimed-total total-index) (readme-total readme-lines))
      (setf prov-index (provenance-index readme-lines))
      (setf was (and prov-index (headline-sha (nth prov-index readme-lines))))
      (when (null rows)
        (die 2 "found no `| **name** | prose | N |' rows in README.md's Status table."))

      ;; Refuse before writing, not after: the wrong number in a README outlives the run.
      (let ((leg (and total-index (headline-leg (nth total-index readme-lines)))))
        (when (and leg (string/= leg host))
          (die 2 "this gate ran on ~a and README's headline claims the ~a leg.~%~
Writing it would put a ~a figure behind a ~a label -- wrong in a way that reads as more~%~
trustworthy than the number it replaced, because it now carries a platform. Derive from the~%~
~a leg's log, or change what the headline claims." host leg host leg leg)))
      (format t "~&gate: host=~a  total=~D  commit=~a~a~%~%" host grand sha
              (if logged-sha "" "  (from local HEAD -- this log records no commit)"))
      ;; Counted here, PRINTED WITH THE TABLE below. The first version pushed this drift
      ;; and then rendered a table of counts that could not contain it: every visible line
      ;; matched, the verdict said one line drifted, and the reader had nothing to act on
      ;; -- while the remedy text told them to write a gate column that was already correct.
      ;; A count drift is self-describing once the table prints; a PROVENANCE drift is
      ;; invisible unless the report names both sides, which is the object this clause
      ;; exists to make checkable. Found in review, not by the tool.
      (when (and prov-index (null was) logged-sha)
        (push (list "(measured-at)" "absent" sha) drift))
      (format t "~14a ~8@a ~8@a~%" "framework" "README" "gate")
      (dolist (row rows)
        (let* ((fw (car row))
               (claimed (cadr row))
               (actual (cdr (assoc fw gate :test #'string=))))
          (cond
            ;; Absent and zero are different answers, and the README may only claim the
            ;; second. hades ships no suite at all, so 0 is its honest figure. But a row
            ;; claiming checks that no suite on this host produced is drift of the worst
            ;; kind -- either the number was taken on another host, or the suite silently
            ;; stopped running -- and "no suite ran" must not read as a pass for it.
            ((and (null actual) (zerop claimed))
             (format t "~14a ~8@a ~8@a   no suite ships~%" fw claimed "--"))
            ((null actual)
             (push (list fw claimed 0) drift)
             (format t "~14a ~8@a ~8@a   <-- DRIFT: no suite ran on ~a~%" fw claimed "--" host))
            ((= actual claimed)
             (format t "~14a ~8@a ~8@a~%" fw claimed actual))
            (t
             (push (list fw claimed actual) drift)
             (format t "~14a ~8@a ~8@a   <-- DRIFT~%" fw claimed actual)))))
      (let ((row-sum (reduce #'+ rows :key #'cadr :initial-value 0)))
        ;; THE HEADLINE IS OPTIONAL, AND ITS ABSENCE IS THE STRONGER STATE. A stored total is
        ;; a second copy of the Checks column, so it could disagree with the rows AND every
        ;; merge moving any row forced every open branch to edit one shared line -- a
        ;; collision carrying no information. Removed (pre-publication issue 330's successor), and what replaces
        ;; it is better evidence: with nothing stored, the rows are summed and compared
        ;; against THE GATE'S OWN grand total rather than against themselves restated.
        ;;
        ;; The comparison must not quietly weaken to nothing when the headline goes. That is
        ;; the specific hazard flagged before this change landed: a checker passing because
        ;; it has nothing to check, on the one file it exists to guard. So the (total) row is
        ;; ALWAYS printed and always compared -- only its left-hand side changes, from a
        ;; number the file stored to a number the file implies.
        (if claimed-total
            (progn
              (format t "~14a ~8@a ~8@a~a~%" "(total)" claimed-total grand
                      (if (eql claimed-total grand) "" "   <-- DRIFT"))
              (unless (eql claimed-total grand)
                (push (list "(total)" claimed-total grand) drift))
              (unless (= row-sum claimed-total)
                (format t "~%NOTE: the table's rows sum to ~:D, not the ~:D it claims.~%"
                        row-sum claimed-total)))
            (progn
              (format t "~14a ~8@a ~8@a~a   (rows summed; no total stored)~%"
                      "(total)" row-sum grand (if (eql row-sum grand) "" "   <-- DRIFT"))
              (unless (eql row-sum grand)
                (push (list "(total)" row-sum grand) drift))))
        ;; The provenance row. Always printed, so "DRIFT in N lines" always corresponds to
        ;; N lines a reader can see.
        (cond
          ;; NO PROVENANCE LINE AT ALL. Before the headline was removed this could not
          ;; happen -- the clause lived on the count's own line, so the line always existed.
          ;; Decoupling them made it deletable, and silence here would be the same defect
          ;; the headline removal was careful to avoid, one level down: every count present
          ;; and correct, attributed to nothing, and the checker green for having nothing to
          ;; check. Found by exercising the no-headline path rather than by review.
          ((and (null prov-index) logged-sha)
           (push (list "(measured-at)" "no line" sha) drift)
           (format t "~14a ~8@a ~8@a   <-- DRIFT: no line carries the measured-at clause~%"
                   "(measured-at)" "no line" sha)
           (format t "~%Restore a line beginning `Counts above are from the Linux CI leg`, ~
then re-run with --update to stamp it. A count without its commit is a rumour.~%"))
          ((null prov-index))
          ((null logged-sha)
           (format t "~14a ~8@a ~8@a   this log records no commit; none will be written~%"
                   "(measured-at)" (or was "absent") "--"))
          ((null was)
           (format t "~14a ~8@a ~8@a   <-- DRIFT: a count without its commit is a rumour~%"
                   "(measured-at)" "absent" sha))
          ((string= was sha)
           (format t "~14a ~8@a ~8@a~%" "(measured-at)" was sha))
          (t
           ;; NOT drift. "Measured at X" stays true; it is simply older than this run, and
           ;; rewriting it on every commit is the churn this script exists to avoid.
           (format t "~14a ~8@a ~8@a   measured earlier, still true~%" "(measured-at)" was sha))))

      (format t "~%")
      (cond ((and drift update)
             ;; Writing is what makes this DERIVED rather than merely enforced. Enforcing a
             ;; hand-maintained number removes the staleness and adds contention: every
             ;; count-moving PR must now edit README.md, so two of them conflict by
             ;; construction -- the docs/dependencies.md cost (#118) landing on a hotter
             ;; file. Deriving removes the staleness AND the thinking; the edit is still a
             ;; commit, but nobody computes or transcribes a number. (Raised by the macOS
             ;; lane after this branch itself went red three times in one afternoon.)
             (let ((n (write-counts readme readme-lines rows gate claimed-total total-index prov-index grand logged-sha)))
               (format t "VERDICT: UPDATED ~D line~:P from the ~a gate.~%" n host)
               (format t "Review the diff and commit it with the change that moved the count.~%")
               (uiop:quit 0)))
            (drift
             (format t "VERDICT: DRIFT in ~D line~:P~%" (length drift))
             (format t "Re-run with --update to write the gate column above, or write it by~%")
             (format t "hand and quote it with its host: ~a.~%" host)
             (uiop:quit 1))
            (update
             ;; IN SYNC ON THE COUNTS IS NOT NOTHING TO DO (pre-publication issue 438). The provenance clause can
             ;; still name a commit other than the one this log came from -- which is exactly
             ;; the state a rebase onto another count-changing PR produces -- so the write runs
             ;; and reports whether it found anything.
             (let ((n (write-counts readme readme-lines rows gate claimed-total total-index
                                    prov-index grand logged-sha)))
               (if (plusp n)
                   (progn
                     (format t "VERDICT: UPDATED ~D line~:P from the ~a gate -- every count was~%" n host)
                     (format t "already in sync; what moved is the measured-at commit.~%")
                     (format t "Review the diff and commit it with the change that was measured.~%"))
                   (format t "VERDICT: IN SYNC (~a) -- nothing to update.~%" host))
               (uiop:quit 0)))
            (t
             (format t "VERDICT: IN SYNC (~a)~%" host)
             (uiop:quit 0))))))

(main)
