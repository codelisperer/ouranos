;;;; dynamic.lisp --- tests for aion/dynamic, and the tree-wide spawn sweep (#158).

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
        (aion/test-threads:join thread)))
    (is (eq :global seen)
        "the child reads the GLOBAL value, not the binding that was live when it spawned")))

(test inheriting-carries-a-registered-binding-onto-the-child
  (dyn:register-inheritable '*test-var*)
  (unwind-protect
       (let ((seen nil))
         (let ((*test-var* :bound))
           (let ((thread (sb-thread:make-thread
                          (dyn:inheriting (lambda () (setf seen *test-var*))))))
             (aion/test-threads:join thread)))
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
        (aion/test-threads:join thread)))
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
           (aion/test-threads:join thread))
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
        (aion/test-threads:join thread)))
    (is (string= id seen) "the child sees the request-id the seam bound")))

(test the-same-field-is-absent-without-the-wrapper
  "The before half of the same measurement, in one file with the after half so neither can
drift away from the other."
  (let ((id (format nil "req-~D" (random 100000)))
        (seen :unset))
    (log:with-context (:request-id id)
      (let ((thread (sb-thread:make-thread
                     (lambda () (setf seen (getf log:*context* :request-id))))))
        (aion/test-threads:join thread)))
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
             (aion/test-threads:join thread)))
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
           (aion/test-threads:join thread))
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

(defun %names-a-maker-p (line makers)
  "Whether LINE names one of MAKERS (strings such as \"make-thread\") as a whole symbol: after a
(, a :, a ', whitespace or the start of the line, and followed by whitespace, a ), or the end of
the line. A plain substring search took a name that only contains one, such as
%MAKE-THREAD-MEMORY, for a spawn site (#908's review)."
  (some (lambda (maker)
          (loop for at = (search maker line) then (search maker line :start2 (1+ at))
                while at
                thereis (and (or (zerop at) (find (char line (1- at)) "(:' ")
                                 (char= (char line (1- at)) #\Tab))
                             (let ((after (+ at (length maker))))
                               (or (= after (length line))
                                   (find (char line after) " )")
                                   (char= (char line after) #\Tab))))))
        makers))

(defun %undecided-in-lines (lines)
  "Line numbers in LINES that spawn a thread without recording a decision.

Separate from `%undecided-spawn-sites' so the control tests can drive THIS function over a
file they construct. A control that reimplemented the matching inline would be checking a
copy of the logic, and would keep passing after the real one changed."
  (let ((found '()))
    (loop for line in lines
          for n from 1
          when (%names-a-maker-p line '("make-thread"))
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

;;; --- a new thread's signal mask (#541) -----------------------------------------

(test the-sbcl-internal-unblock-interrupts-calls-exists
  "UNBLOCK-INTERRUPTS calls SBCL's internal SB-UNIX::UNBLOCK-DEFERRABLE-SIGNALS, found by name.
If a new SBCL renames or removes it, UNBLOCK-INTERRUPTS does nothing and every long-lived thread
made while its creator had an interrupt deferred stops being interruptible again. This is the
test that says so."
  (let ((symbol (find-symbol "UNBLOCK-DEFERRABLE-SIGNALS" "SB-UNIX")))
    (is-true symbol "SBCL ~A has no SB-UNIX::UNBLOCK-DEFERRABLE-SIGNALS, so AION/DYNAMIC:UNBLOCK-INTERRUPTS does nothing; find what this SBCL calls it and update aion/src/dynamic/dynamic.lisp (#541)" (lisp-implementation-version))
    (is-true (and symbol (fboundp symbol)) "SB-UNIX::UNBLOCK-DEFERRABLE-SIGNALS exists in SBCL ~A but is not a function, so AION/DYNAMIC:UNBLOCK-INTERRUPTS does nothing (#541)" (lisp-implementation-version))
    (is-true dyn::*unblock-deferrable-signals* "AION/DYNAMIC found no function to call when it was loaded (#541)")))

(defun %thread-made-in-a-step (body &key (defer t))
  "Make a thread running BODY from inside SB-SYS:WITHOUT-INTERRUPTS. With DEFER, another thread
interrupts this one inside the step first, and the step waits 0.2 s for that interrupt to arrive
and be deferred, so the new thread starts with the deferrable signals blocked. Returns the new
thread once the step has ended and the deferred interrupt has run."
  (let ((thread nil))
    (sb-sys:without-interrupts
      (when defer
        (let ((me sb-thread:*current-thread*))
          (sb-thread:join-thread
           (sb-thread:make-thread (lambda () (sb-thread:interrupt-thread me (lambda () nil)))
                                  :name "aion/dynamic test interrupter"))
          (sleep 0.2)))
      ;; THREAD-LIFETIME: scoped -- the test's own thread, stopped and joined by the caller.
      ;; INTERRUPTS: BODY decides; that is what these tests compare.
      (setf thread (sb-thread:make-thread body :name "aion/dynamic test thread")))
    thread))

(defun %interruptible-p (thread &optional (timeout 2))
  "Whether an INTERRUPT-THREAD sent to THREAD runs within TIMEOUT seconds."
  (let ((ran (sb-thread:make-semaphore)))
    (sb-thread:interrupt-thread thread (lambda () (sb-thread:signal-semaphore ran)))
    (and (sb-thread:wait-on-semaphore ran :timeout timeout) t)))

(defun %interruptible-thread-check (body &key (defer t))
  "Make a thread running BODY with %THREAD-MADE-IN-A-STEP, check whether it can be interrupted,
then stop it. Returns whether the interrupt arrived."
  (let* ((stop (sb-thread:make-semaphore))
         (thread (%thread-made-in-a-step (lambda () (funcall body) (sb-thread:wait-on-semaphore stop :timeout 30))
                                         :defer defer)))
    (unwind-protect (%interruptible-p thread)
      (sb-thread:signal-semaphore stop)
      (sb-thread:join-thread thread :default nil :timeout 30))))

(test a-thread-that-unblocks-interrupts-first-can-be-interrupted
  "A thread made inside a step while an interrupt to its creator was deferred, whose first form is
UNBLOCK-INTERRUPTS, receives an INTERRUPT-THREAD."
  (is-true (%interruptible-thread-check #'dyn:unblock-interrupts)))

(test a-thread-made-in-the-step-without-it-cannot-be-interrupted
  "The control for the test above, and the defect: the same thread without UNBLOCK-INTERRUPTS
inherits the blocked mask and never receives the interrupt.

Not on a :SB-SAFEPOINT build (SBCL for Windows): there a new thread does not take its creator's
signal mask, so the defect does not exist and the same thread can be interrupted. The test
asserts that instead, so a change in either platform's behaviour is seen."
  #-sb-safepoint
  (is-false (%interruptible-thread-check (lambda () nil))
            "this SBCL no longer passes a blocked mask to a new thread; UNBLOCK-INTERRUPTS may no longer be needed")
  #+sb-safepoint
  (is-true (%interruptible-thread-check (lambda () nil))
           "on this :SB-SAFEPOINT build a new thread now takes its creator's blocked mask, which the other platforms do"))

(test a-thread-made-with-no-deferred-interrupt-can-be-interrupted
  "The second control: with no interrupt deferred in the step, the same thread without
UNBLOCK-INTERRUPTS can be interrupted, so the test above fails because of the deferred
interrupt and not because of how it checks."
  (is-true (%interruptible-thread-check (lambda () nil) :defer nil)))

;;; --- the sweep: every spawn site has decided about interrupts (#541) ------------

(defun %first-form-after-lambda (code)
  "The text of the first form after the lambda list of the first LAMBDA in CODE, up to its first
closing parenthesis, or NIL. CODE has its comments removed, so a comment between the lambda list
and the form is skipped."
  (let* ((at (search "(lambda" code))
         (open (and at (position #\( code :start (+ at 7))))
         (n (length code)))
    (when open
      (let ((i open) (depth 0))
        (loop while (< i n)
              do (case (char code i) (#\( (incf depth)) (#\) (decf depth)))
                 (incf i)
              until (zerop depth))
        (let* ((start (position-if-not (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return)))
                                       code :start (min i n)))
               (end (and start (position #\) code :start start))))
          (and end (subseq code start (1+ end))))))))

(defun %unblock-decided-p (lines n)
  "Has the spawn site on line N (1-based) of LINES decided about its signal mask?

Decided when the first form of the thread's body -- the first form after the lambda list of the
first LAMBDA in the spawn line and the six lines after it, comments ignored -- is a call to
UNBLOCK-INTERRUPTS, or when a comment in the five lines above it or on it starts INTERRUPTS: and
says why not. Six lines because a thread body may open with a comment, as aion/uv's loop thread
does. The first form, because the call does not protect a body that has already taken a lock or
entered SB-SYS:WITHOUT-INTERRUPTS (see UNBLOCK-INTERRUPTS). The comment is matched as \";;
INTERRUPTS:\", so a comment that mentions WITHOUT-INTERRUPTS: does not count."
  (let ((after (subseq lines (1- n) (min (length lines) (+ n 6))))
        (before (subseq lines (max 0 (- n 6)) n)))
    (or (let ((form (%first-form-after-lambda (%code-and-comments after))))
          (and form
               (char= #\( (char form 0))
               (not (find #\Space form))
               (uiop:string-suffix-p form "unblock-interrupts)")))
        (search ";; INTERRUPTS:" (nth-value 1 (%code-and-comments before))))))

(defparameter +thread-makers+ '("make-thread" "make-ephemeral-thread" "sb-ext:make-timer")
  "What starts a thread, as the sweep looks for it. SB-EXT:MAKE-TIMER is here because a timer made
with :THREAD T starts a thread each time it fires; one made without it is still listed, and its
site says INTERRUPTS: why not.")

(defun %unblocking-undecided-in-lines (lines)
  "Line numbers in LINES that spawn a thread without having decided about interrupts."
  (loop for line in lines
        for n from 1
        when (and (%names-a-maker-p line +thread-makers+)
                  (not (%unblock-decided-p lines n)))
          collect n))

(defun %spawn-sites-without-unblock ()
  (let ((found '()))
    (dolist (path (%sweep-files) (nreverse found))
      (let ((lines (uiop:read-file-lines path)))
        (dolist (n (%unblocking-undecided-in-lines lines))
          (push (format nil "~A:~D" (enough-namestring path (asdf:system-relative-pathname :aion "../")) n) found))))))

(test every-thread-spawn-site-unblocks-interrupts-or-says-why-not
  "A thread a framework here creates may be created while its creator has an interrupt deferred,
and then cannot be interrupted for its whole life unless its body calls UNBLOCK-INTERRUPTS
first (#541). So every spawn site either calls it within the first lines of the body or carries
an INTERRUPTS: comment that says why not."
  (let ((undecided (%spawn-sites-without-unblock)))
    (is (null undecided)
        "these spawn sites neither call aion/dynamic:unblock-interrupts first nor say INTERRUPTS: why not (#541): ~{~%  ~A~}" undecided)))

(test the-interrupt-sweep-sees-a-spawn-without-the-call
  "The control: a spawn whose body does not call it is found; so is one where only a comment
names the function, one that calls it after another form, one whose comment only mentions
WITHOUT-INTERRUPTS:, and a timer that starts a thread."
  (let ((bare (list "(sb-thread:make-thread (lambda () 1))"))
        (named (list ";; this thread should call unblock-interrupts" "(sb-thread:make-thread (lambda () 1))"))
        (late (list "(sb-thread:make-thread" "  (lambda ()" "    (sb-thread:with-mutex (m)" "      (aion/dynamic:unblock-interrupts))))"))
        (word (list ";; see SB-SYS:WITHOUT-INTERRUPTS: below" "(sb-thread:make-thread (lambda () 1))"))
        (timer (list "(sb-ext:make-timer (lambda () 1) :thread t)")))
    (is (equal '(1) (%unblocking-undecided-in-lines bare)))
    (is (equal '(2) (%unblocking-undecided-in-lines named)))
    (is (equal '(1) (%unblocking-undecided-in-lines late)) "the call must be the first form")
    (is (equal '(2) (%unblocking-undecided-in-lines word)) "WITHOUT-INTERRUPTS: is not an INTERRUPTS: reason")
    (is (equal '(1) (%unblocking-undecided-in-lines timer)))))

(test the-interrupt-sweep-accepts-the-call-and-a-reason
  "The other direction: the call as the body's first form decides a site, and so does an
INTERRUPTS: comment above it."
  (is (null (%unblocking-undecided-in-lines
             (list "(sb-thread:make-thread" "  (lambda ()" "    (aion/dynamic:unblock-interrupts)" "    1))"))))
  (is (null (%unblocking-undecided-in-lines
             (list ";; INTERRUPTS: joined at once, and nothing interrupts it." "(sb-thread:make-thread (lambda () 1))")))))

(test (the-sweeps-match-a-maker-as-a-whole-symbol :suite aion-dynamic)
  "A name that only contains a maker's name, such as %MAKE-THREAD-MEMORY, is not a spawn site; a
call to SB-THREAD:MAKE-THREAD, BT:MAKE-THREAD or MAKE-THREAD is."
  (is (null (%undecided-in-lines (list "(defstruct (thread-memory (:constructor %make-thread-memory)))"))))
  (is (null (%unblocking-undecided-in-lines (list "        (%make-thread-memory :store store)"))))
  (is (equal '(1) (%undecided-in-lines (list "(sb-thread:make-thread (lambda () 1))"))))
  (is (equal '(1) (%undecided-in-lines (list "  (bt:make-thread #'f)"))))
  (is (equal '(1) (%unblocking-undecided-in-lines (list "(make-thread (lambda () 1) :name \"x\")")))))
