;;;; dynamic.lisp --- tests for aion/dynamic, and the tree-wide spawn sweep (#430).

(cl:defpackage #:aion/dynamic/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:dyn #:aion/dynamic)
                    (#:log #:aion/log))
  (:export #:run-tests #:aion-dynamic))
(in-package #:aion/dynamic/tests)

(def-suite aion-dynamic
  :description "Dynamic bindings crossing a thread boundary, and the spawn-site sweep.")
(in-suite aion-dynamic)

(defun run-tests () (run! 'aion-dynamic))

(defvar *test-var* :global)

;;; --- the crossing itself ----------------------------------------------------
;;; Each of these creates the crossing rather than asserting that CAPTURE returned the right
;;; plist. Asserting the plist is a producer checking its own output: it passes whether or
;;; not the child ever sees the value, which is the entire defect.

(test a-let-binding-does-not-cross-a-thread-by-itself
  "The defect, demonstrated before the fix is applied to it. Without this the tests below
prove only that the mechanism does something, not that anything needed it."
  (let ((seen nil))
    (let ((*test-var* :bound))
      (let ((thread (sb-thread:make-thread (lambda () (setf seen *test-var*)))))
        (sb-thread:join-thread thread)))
    (is (eq :global seen)
        "the child reads the GLOBAL value, not the binding that was live when it spawned")))

(test inheriting-carries-a-registered-binding-onto-the-child
  (dyn:register-inheritable '*test-var*)
  (unwind-protect
       (let ((seen nil))
         (let ((*test-var* :bound))
           (let ((thread (sb-thread:make-thread
                          (dyn:inheriting (lambda () (setf seen *test-var*))))))
             (sb-thread:join-thread thread)))
         (is (eq :bound seen)
             "a registered variable bound on the parent is visible on the child; saw ~S" seen))
    (dyn:unregister-inheritable '*test-var*)))

(test an-unregistered-variable-does-not-cross
  "The other direction. A mechanism that carried everything would pass the test above while
carrying bindings nobody asked to share."
  (let ((seen nil))
    (let ((*test-var* :bound))
      (let ((thread (sb-thread:make-thread
                     (dyn:inheriting (lambda () (setf seen *test-var*))))))
        (sb-thread:join-thread thread)))
    (is (eq :global seen)
        "an UNregistered variable must not cross; the child should see the global, saw ~S" seen)))

(test the-capture-happens-when-inheriting-is-called-not-when-the-thunk-runs
  "The only moment the binding is visible is on the spawning thread before it spawns. A
wrapper that captured lazily would capture the global value and look correct in a test that
never left the binding."
  (dyn:register-inheritable '*test-var*)
  (unwind-protect
       (let ((wrapped nil) (seen nil))
         (let ((*test-var* :bound))
           (setf wrapped (dyn:inheriting (lambda () (setf seen *test-var*)))))
         ;; the binding is gone here; the wrapper must still carry it
         (let ((thread (sb-thread:make-thread wrapped)))
           (sb-thread:join-thread thread))
         (is (eq :bound seen)
             "the capture is taken where INHERITING was called, not where the thunk ran; saw ~S"
             seen))
    (dyn:unregister-inheritable '*test-var*)))

;;; --- the case this exists for -----------------------------------------------

(test a-log-field-bound-by-with-context-reaches-a-child-thread
  "The live case: hyperion binds :request-id around a request and praxeon/web runs the turn
on another thread. The id asserted here is one this test generated, so its presence cannot
be explained by anything other than the crossing -- a field that matched a global default
would prove nothing."
  (let ((id (format nil "req-~D" (random 100000)))
        (seen nil))
    (log:with-context (:request-id id)
      (let ((thread (sb-thread:make-thread
                     (dyn:inheriting (lambda () (setf seen (getf log:*context* :request-id)))))))
        (sb-thread:join-thread thread)))
    (is (string= id seen) "the child sees the request-id the seam bound")))

(test the-same-field-is-absent-without-the-wrapper
  "The before half of the same measurement, in one file with the after half so neither can
drift away from the other."
  (let ((id (format nil "req-~D" (random 100000)))
        (seen :unset))
    (log:with-context (:request-id id)
      (let ((thread (sb-thread:make-thread
                     (lambda () (setf seen (getf log:*context* :request-id))))))
        (sb-thread:join-thread thread)))
    (is (null seen) "unwrapped, the child's context is empty and the field is simply gone")))

(defvar *other-var* :global-other)

(test a-child-can-inherit-and-still-override-one-member
  "INHERIT, THEN OVERRIDE. praxeon/web's turn thread inherits the request's logging context
and installs its OWN observer for the conversation it reports into. Both have to work at
once: an implementation that established the snapshot inside the thunk, or restored it
afterwards, would break that site while passing every inheritance test."
  (dyn:register-inheritable '*test-var*)
  (dyn:register-inheritable '*other-var*)
  (unwind-protect
       (let ((seen-inherited nil) (seen-overridden nil))
         (let ((*test-var* :from-caller) (*other-var* :from-caller))
           (let ((thread (sb-thread:make-thread
                          (dyn:inheriting
                           (lambda ()
                             ;; the child replaces one member and keeps the other
                             (let ((*other-var* :installed-by-child))
                               (setf seen-inherited *test-var*
                                     seen-overridden *other-var*)))))))
             (sb-thread:join-thread thread)))
         (is (eq :from-caller seen-inherited) "the member it did not touch is inherited")
         (is (eq :installed-by-child seen-overridden) "the member it rebound is its own"))
    (dyn:unregister-inheritable '*test-var*)
    (dyn:unregister-inheritable '*other-var*)))

(test an-override-does-not-leak-back-to-the-caller
  "The other half: the child's replacement is scoped to the child."
  (dyn:register-inheritable '*other-var*)
  (unwind-protect
       (let ((*other-var* :from-caller))
         (let ((thread (sb-thread:make-thread
                        (dyn:inheriting
                         (lambda () (let ((*other-var* :installed-by-child))
                                      (declare (ignorable *other-var*))
                                      nil))))))
           (sb-thread:join-thread thread))
         (is (eq :from-caller *other-var*)
             "the child's rebinding must stay on the child; the caller now sees ~S"
             *other-var*))
    (dyn:unregister-inheritable '*other-var*)))

;;; --- the sweep: every spawn site has made a choice --------------------------
;;;
;;; WHY THIS TEST EXISTS. A registry moves the failure rather than removing it: if no spawn
;;; site captures, every registered variable is lost exactly as before, and now a reader
;;; finds a mechanism and concludes the problem is handled. That is the shape this repo
;;; already has a rule about -- the tree contains `check-pins.lisp', a grep finds it, and
;;; nothing invokes it.
;;;
;;; So the tree is walked, and a thread-spawn site must have DECIDED: either it carries the
;;; caller's bindings, or it says it begins an independent lifetime and why. "Did you
;;; remember to wrap it" is a question about diligence. "Which kind of thread is this" is a
;;; question about the code, which the author can answer and a reviewer can check.

(defparameter +spawn-sweep-roots+
  '("aion" "cons" "mnemosyne" "elenchon" "hyperion" "praxeon" "hermes" "klio" "hades")
  "The trees walked. Named rather than discovered, so adding a framework to the repo without
adding it here is visible in this list rather than silently unswept.")

(defparameter +spawn-sweep-skips+
  '("/tests/" "/bench/")
  "Paths the sweep does not require to choose, and why:

  /tests/  a test's own thread is part of the test, and a test that wanted inherited
           context would be asserting the mechanism rather than using it.
  /bench/  not shipped.

THE SKIP LIST IS PART OF THE CHECK. A sweep that quietly skipped a directory would let the
next bare spawn land where the walker does not look, so the list is here, short, and each
entry carries its reason.")

(defun %sweep-files ()
  (let ((root (asdf:system-relative-pathname :aion "../")))
    (remove-if (lambda (path)
                 (let ((s (namestring path)))
                   (some (lambda (skip) (search skip s)) +spawn-sweep-skips+)))
               (loop for tree in +spawn-sweep-roots+
                     append (directory (merge-pathnames
                                        (format nil "~A/**/*.lisp" tree) root))))))

(defun %comment-start (line)
  "Index of the `;' that begins LINE's comment, or NIL. Skips a `;' inside a string or a
`#\\;' character literal.

IMPRECISE IN THE SAFE DIRECTION. If this misjudges a line it treats too much of it as a
comment, which can only make a spawn site look UNdecided -- a loud failure someone reads --
rather than decided, which would be a silent pass."
  (let ((in-string nil)
        (i 0)
        (n (length line)))
    (loop while (< i n)
          do (let ((c (char line i)))
               (cond ((and in-string (char= c #\\)) (incf i 2))
                     ((char= c #\") (setf in-string (not in-string)) (incf i))
                     ((and (not in-string)
                           (char= c #\#)
                           (< (1+ i) n)
                           (char= (char line (1+ i)) #\\))
                      (incf i 3))
                     ((and (not in-string) (char= c #\;))
                      (return-from %comment-start i))
                     (t (incf i)))))
    nil))

(defun %code-and-comments (lines)
  "LINES split into two strings: the code, and the comments."
  (let ((code '())
        (comments '()))
    (dolist (line lines)
      (let ((c (%comment-start line)))
        (cond (c (push (subseq line 0 c) code)
                 (push (subseq line c) comments))
              (t (push line code)))))
    (values (format nil "~{~A~^~%~}" (nreverse code))
            (format nil "~{~A~^~%~}" (nreverse comments)))))

(defun %decided-p (window)
  "Has the spawn site in WINDOW said whether it inherits?

The two markers are read from DIFFERENT halves of the window on purpose. `inheriting' has to
appear in CODE, because a comment is where someone writes a sentence like \"this thread is not
inheriting the caller's context\" -- which named the mechanism, did not use it, and would have
satisfied a plain substring search over the whole window. THREAD-LIFETIME is the opposite: it
is a comment by design, so it is read only from the comments."
  (multiple-value-bind (code comments) (%code-and-comments window)
    (or (search "inheriting" code)
        (search "THREAD-LIFETIME" comments))))

(defun %undecided-in-lines (lines)
  "Line numbers in LINES that spawn a thread without recording a decision.

Separate from `%undecided-spawn-sites' so the control tests can drive THIS function over a
file they construct. A control that reimplemented the matching inline would be checking a
copy of the logic, and would keep passing after the real one changed."
  (let ((found '()))
    (loop for line in lines
          for n from 1
          when (search "make-thread" line)
            do (let* ((start (max 0 (- n 6)))
                      (window (subseq lines start (min (length lines) (+ n 2)))))
                 (unless (%decided-p window)
                   (push n found))))
    (nreverse found)))

(defun %undecided-spawn-sites ()
  "Files and line numbers where a thread is spawned without a decision recorded.

A site counts as decided when the spawn form carries `inheriting' in code, or when a comment
within the five lines above it says THREAD-LIFETIME. Five because the reason is expected to be
a sentence or two, and a marker with no room for a reason is a box to tick.

The window reaches only two lines PAST the spawn, so `inheriting' has to sit on or next to the
`make-thread' form. A long comment between the two pushes the wrapper out of the window and the
site reads as undecided -- which is how this was found, on a real site."
  (let ((found '()))
    (dolist (path (%sweep-files) found)
      (let ((lines (uiop:read-file-lines path)))
        (dolist (n (%undecided-in-lines lines))
          (push (format nil "~A:~D" (file-namestring path) n) found))))))

(test every-thread-spawn-site-has-decided-whether-it-inherits
  "Fails on a bare make-thread. That is what gives the registry teeth: without this the
mechanism can sit in the tree, greppable and unused, while every registered variable is
still lost across every boundary."
  (let ((undecided (%undecided-spawn-sites)))
    ;; One line, no `~' continuation: AGENTS.md forbids them because a CRLF checkout turns
    ;; `~<newline>' into an illegal `~<Return>' directive that fails at compile time.
    (is (null undecided)
        "these spawn sites have not said whether they inherit: ~{~%  ~A~}" undecided)))

(test the-sweep-can-see-a-bare-spawn
  "The control. A sweep that found nothing because it was looking in the wrong place would
pass exactly as loudly as one that found nothing because there was nothing to find."
  (uiop:with-temporary-file (:stream s :pathname p :suffix ".lisp" :keep t)
    (format s "(sb-thread:make-thread (lambda () 1))~%")
    :close-stream
    (is (equal '(1) (%undecided-in-lines (uiop:read-file-lines p)))
        "the matcher finds an unmarked spawn when there is one")))

(test a-comment-naming-the-mechanism-does-not-decide-a-site
  "The false-negative direction, which the first version of this sweep got wrong. It searched
the whole window for the string `inheriting', so a COMMENT that merely said the word marked the
site as decided. That is a guard satisfied by prose about the guard."
  (uiop:with-temporary-file (:stream s :pathname p :suffix ".lisp" :keep t)
    (format s ";; this thread is not inheriting the caller's context~%")
    (format s "(sb-thread:make-thread (lambda () 1))~%")
    :close-stream
    (is (equal '(2) (%undecided-in-lines (uiop:read-file-lines p)))
        "a comment naming INHERITING must not decide the site; the spawn is still bare")))

(test the-sweep-actually-walks-files
  "And the other half of the control: if the walker returned an empty file list the sweep
above would pass while checking nothing."
  (is (< 50 (length (%sweep-files)))
      "the sweep should be walking the tree, not an empty list"))
