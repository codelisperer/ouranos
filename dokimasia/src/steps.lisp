;;;; steps.lisp --- running one step in the browser (#1028, dokimasia ADR-0001, point 2).
;;;;
;;;; %RUN-STEP runs a step and the checks made after every step, and returns how it ended: passed,
;;;; failed with a reason, or not run with a reason. After an action (:VISIT, :FILL, :CLICK,
;;;; :SELECT) it first waits for the page to settle, with the target's settle check. Any error
;;;; from the browser, such as a selector that matches nothing in time, fails the step with that
;;;; error's text; it does not end the run.

(in-package #:dokimasia)

(defparameter +viewports+
  '((:desktop :width 1280 :height 800 :scale 1 :mobile nil)
    (:phone :width 390 :height 844 :scale 2 :mobile t))
  "The viewports a run can take screenshots at: :DESKTOP and :PHONE.")

(defparameter +max-screenshot-height+ 16384
  "The tallest viewport a screenshot grows to, in CSS pixels.")

(defstruct (run-context (:constructor %make-run-context))
  suite target browser out viewports schemes dcase row-id (step-number 0))

(defvar *run* nil "The run in progress, while a row runs.")

(define-condition step-failure (error)
  ((reason :initarg :reason :reader step-failure-reason))
  (:report (lambda (c s) (write-string (step-failure-reason c) s))))

(defun %fail (control &rest args)
  (error 'step-failure :reason (apply #'format nil control args)))

(defun %clip (text &optional (n 200))
  (let ((text (substitute #\Space #\Newline (princ-to-string text))))
    (if (> (length text) n) (concatenate 'string (subseq text 0 (- n 3)) "...") text)))

;;; --- JavaScript ----------------------------------------------------------------------------

(defun %js (value)
  "VALUE as a JavaScript literal: a string, a number, null for NIL, or an array for a list."
  (cond ((null value) "null")
        ((stringp value) (jzon:stringify value))
        ((realp value) (jzon:stringify value))
        ((listp value) (jzon:stringify (coerce value 'vector)))
        (t (error "dokimasia: ~S cannot be passed to JavaScript" value))))

(defun %eval (control &rest args)
  "Evaluate in the row's page the JavaScript made by formatting CONTROL with ARGS, each passed
through %JS."
  (cdp:evaluate (row-page *row*) (apply #'format nil control (mapcar #'%js args))
                :timeout *step-timeout*))

(defun %poll (thunk timeout)
  "Call THUNK every 50 ms until it returns true or TIMEOUT seconds pass. Returns its last value.
A call that signals a browser error, as one does while a new document replaces the old, counts
as false."
  (let ((deadline (+ (get-internal-real-time) (round (* timeout internal-time-units-per-second))))
        (value nil))
    (loop
      (setf value (handler-case (funcall thunk) (cdp:cdp-condition () nil)))
      (when (or value (> (get-internal-real-time) deadline)) (return value))
      (sleep 0.05))))

;;; --- values --------------------------------------------------------------------------------

(defun %value (form)
  "The value of the value form FORM for the current row, as a string."
  (cond ((stringp form) form)
        ((realp form) (princ-to-string form))
        ((eq (first form) :input)
         (let ((cell (assoc (%name-string (second form)) (row-inputs *row*) :test #'string=)))
           (unless cell (%fail "the row has no value for ~A" (%name-string (second form))))
           (princ-to-string (cdr cell))))
        ((eq (first form) :user)
         (let ((user (row-user *row*)))
           (unless user (%fail "(:user ~A) is used, but no user is signed in" (%name-string (second form))))
           (let ((cell (loop for (k v) on user by #'cddr
                             when (string-equal (%name-string k) (%name-string (second form)))
                               return (list v))))
             (unless cell (%fail "the user ~A has no value for ~A"
                                 (%name-string (getf user :name)) (%name-string (second form))))
             (let ((v (first cell)))
               (if (secret:secretp v) (secret:reveal v) (princ-to-string v))))))
        (t (%fail "~S is not a value" form))))

(defun %url (path)
  (if (or (uiop:string-prefix-p "http://" path) (uiop:string-prefix-p "https://" path))
      path
      (concatenate 'string (row-base-url *row*) (if (uiop:string-prefix-p "/" path) "" "/") path)))

(defun %timeout (options) (or (getf options :timeout) *step-timeout*))

;;; --- actions -------------------------------------------------------------------------------

(defun %await-element (selector)
  (unless (%poll (lambda () (plusp (cdp:query (row-page *row*) selector :timeout *step-timeout*)))
                 *step-timeout*)
    (%fail "nothing matched ~A within ~A seconds" selector *step-timeout*)))

(defun %run-action (step)
  "Run the action STEP, then wait for the page to settle."
  (let ((page (row-page *row*)))
    (destructuring-bind (kind &rest args) step
      (ecase kind
        (:visit (cdp:navigate page (%url (%value (first args))) :timeout *settle-timeout*))
        (:fill
         (let ((selector (first args)) (text (%value (second args))))
           (%await-element selector)
           (%eval "(e => { e.focus(); if ('value' in e) e.value = ''; e.dispatchEvent(new Event('input', {bubbles: true})); return true; })(document.querySelector(~A))"
                  selector)
           (when (plusp (length text)) (cdp:type-text page selector text :timeout *step-timeout*))
           (%eval "(e => { e.dispatchEvent(new Event('change', {bubbles: true})); return true; })(document.querySelector(~A))"
                  selector)))
        (:click
         (%await-element (first args))
         (cdp:click page (first args) :timeout *step-timeout*))
        (:select
         (let ((selector (first args)) (value (%value (second args))))
           (%await-element selector)
           (unless (%eval "((e, v) => { if (!e.options || ![...e.options].some(o => o.value === v)) return false; e.value = v; e.dispatchEvent(new Event('input', {bubbles: true})); e.dispatchEvent(new Event('change', {bubbles: true})); return true; })(document.querySelector(~A), ~A)"
                          selector value)
             (%fail "~A has no option with the value ~S" selector value))))))
    (let ((why (target-settle (row-target *row*) page *settle-timeout*)))
      (when why (%fail "~A" why)))))

;;; --- checks --------------------------------------------------------------------------------

(defun %screen-mismatch (screen)
  "Why the page is not SCREEN, or an empty string when it is."
  (%eval "((path, prefix, present, absent, title) => { const p = location.pathname; const why = []; if (path !== null && p !== path) why.push('the path is ' + p + ', not ' + path); if (prefix !== null && !p.startsWith(prefix)) why.push('the path ' + p + ' does not start with ' + prefix); for (const s of present || []) if (!document.querySelector(s)) why.push('nothing matches ' + s); for (const s of absent || []) if (document.querySelector(s)) why.push('something matches ' + s); if (title !== null && !document.title.includes(title)) why.push('the title is ' + JSON.stringify(document.title)); return why.join('; '); })(~A, ~A, ~A, ~A, ~A)"
         (screen-path screen) (screen-path-prefix screen) (screen-present screen)
         (screen-absent screen) (screen-title screen)))

(defun %expect-screen (args)
  (let* ((name (if (and (symbolp (first args)) (not (null (first args))))
                   (first args)
                   (%value (first args))))
         (screen (or (find-screen name) (%fail "no screen is defined as ~A" (%name-string name))))
         (why "the page could not be read"))
    (unless (%poll (lambda ()
                     (let ((w (handler-case (%screen-mismatch screen)
                                (cdp:cdp-condition (c) (setf why (%clip (princ-to-string c) 300)) nil))))
                       (when (stringp w) (setf why w))
                       (equal w "")))
                   (%timeout (rest args)))
      (%fail "the page is not the screen ~A: ~A" (screen-name screen) why))))

(defun %expect-text (args)
  (let ((selector (first args)) (expected (%value (second args))) (seen nil))
    (unless (%poll (lambda ()
                     (setf seen (cdp:text-of (row-page *row*) selector :timeout *step-timeout*))
                     (and (stringp seen) (search expected seen)))
                   (%timeout (cddr args)))
      (if (stringp seen)
          (%fail "the text of ~A does not contain ~S; it is ~S" selector expected (%clip seen))
          (%fail "nothing matches ~A" selector)))))

(defun %wait-for (args)
  (let ((what (first args)) (timeout (%timeout (rest args))))
    (handler-case
        (if (stringp what)
            (cdp:wait-for (row-page *row*) :selector what :timeout timeout)
            (cdp:wait-for (row-page *row*) :expression (second what) :timeout timeout))
      (cdp:cdp-timeout ()
        (%fail "~A did not ~A within ~A seconds"
               (if (stringp what) what (second what))
               (if (stringp what) "match anything" "become true") timeout)))))

(defun %expect-stored (args)
  "Run the probe. Returns :NOT-RUN and a reason when the target cannot run any form it has."
  (let* ((name (first args))
         (probe (or (find-probe name) (%fail "no probe is defined as ~A" (%name-string name))))
         (values (mapcar #'%value (rest args)))
         (target (row-target *row*)))
    (multiple-value-bind (ok why)
        (cond ((and (probe-local probe) (target-runs-local-probes-p target))
               (apply (probe-local probe) values))
              ((probe-http probe)
               (apply (probe-http probe) (row-page *row*) (row-base-url *row*) values))
              (t (return-from %expect-stored
                   (values :not-run
                           (format nil "the probe ~A has no HTTP form, and its local form cannot see the store of a ~(~A~)"
                                   (probe-name probe) (type-of target))))))
      (unless ok
        (%fail "the probe ~A: ~A" (probe-name probe)
               (or why "the stored data is not as expected"))))
    nil))

(defun %scroll-position (pane)
  (if pane
      (or (%eval "(e => e ? e.scrollTop : null)(document.querySelector(~A))" pane)
          (%fail "nothing matches the pane ~A" pane))
      (%eval "window.scrollY")))

(defun %expect-scroll-kept (args)
  (destructuring-bind (action &key pane scroll) args
    (when scroll
      (if pane
          (%eval "((e, y) => { if (e) e.scrollTop = y; return true; })(document.querySelector(~A), ~A)"
                 pane scroll)
          (%eval "(y => { window.scrollTo(0, y); return true; })(~A)" scroll)))
    (let ((before (%scroll-position pane)))
      (%run-action action)
      (let ((after (%scroll-position pane)))
        (when (> (abs (- after before)) 1)
          (%fail "the scroll position of ~A moved from ~A to ~A" (or pane "the window")
                 before after))))))

;;; --- screenshots ---------------------------------------------------------------------------

(defun %path-part (text)
  (map 'string (lambda (c) (if (or (alphanumericp c) (find c "-_.")) (char-downcase c) #\_)) text))

(defun %apply-viewport (page viewport &optional height)
  (let ((spec (rest (assoc viewport +viewports+))))
    (cdp:set-viewport page (getf spec :width) (or height (getf spec :height))
                      :scale (getf spec :scale) :mobile (getf spec :mobile)
                      :timeout *step-timeout*)))

(defun %next-frame ()
  (%eval "new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(true))))"))

(defun %content-height ()
  "The height of the document, or of the tallest scrolling pane's content, whichever is larger."
  (%eval "(() => { let h = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0); for (const e of document.querySelectorAll('*')) { const s = getComputedStyle(e); if (/(auto|scroll)/.test(s.overflowY) && e.scrollHeight > e.clientHeight) { const r = e.getBoundingClientRect(); h = Math.max(h, Math.ceil(r.top + window.scrollY + e.scrollHeight)); } } return h; })()"))

(defun %mask (suite)
  (%eval "((sels, pats) => { const saved = [], texts = []; for (const s of sels) for (const e of document.querySelectorAll(s)) { saved.push([e, e.style.visibility]); e.style.visibility = 'hidden'; } const res = pats.map(p => new RegExp(p, 'g')); if (res.length && document.body) { const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); let n; while ((n = w.nextNode())) { const t = n.nodeValue; let u = t; for (const r of res) u = u.replace(r, '[masked]'); if (u !== t) { texts.push([n, t]); n.nodeValue = u; } } } window.__dokimasiaMask = {saved, texts}; return true; })(~A, ~A)"
         (suite-mask suite) (suite-mask-text suite)))

(defun %unmask ()
  (%eval "(() => { const m = window.__dokimasiaMask; if (!m) return false; for (const [e, v] of m.saved) e.style.visibility = v; for (const [n, t] of m.texts) n.nodeValue = t; delete window.__dokimasiaMask; return true; })()"))

(defun %screenshot (args)
  (let* ((ctx *run*) (page (row-page *row*)) (name (first args))
         (dir (merge-pathnames
               (format nil "~A/~A/" (%path-part (dcase-name (run-context-dcase ctx)))
                       (%path-part (run-context-row-id ctx)))
               (run-context-out ctx))))
    (unwind-protect
         (dolist (viewport (run-context-viewports ctx))
           (dolist (scheme (run-context-schemes ctx))
             (%apply-viewport page viewport)
             (cdp:emulate-color-scheme page scheme :timeout *step-timeout*)
             (%next-frame)
             (let ((height (%content-height)))
               (when (and (integerp height)
                          (> height (getf (rest (assoc viewport +viewports+)) :height)))
                 (%apply-viewport page viewport (min height +max-screenshot-height+))
                 (%next-frame)))
             (let ((file (merge-pathnames
                          (format nil "~2,'0D-~A-~(~A~)-~(~A~).png"
                                  (run-context-step-number ctx) (%path-part name) viewport scheme)
                          dir))
                   (png nil))
               (%mask (run-context-suite ctx))
               (unwind-protect (setf png (cdp:screenshot page :timeout *step-timeout*))
                 (%unmask))
               (ensure-directories-exist file)
               (with-open-file (out file :direction :output :element-type '(unsigned-byte 8)
                                         :if-exists :supersede)
                 (write-sequence png out))
               (push (uiop:native-namestring file) (row-artifacts *row*)))))
      (%apply-viewport page (first (run-context-viewports ctx)))
      (cdp:emulate-color-scheme page (first (run-context-schemes ctx)) :timeout *step-timeout*))))

;;; --- one step ------------------------------------------------------------------------------

(defun %execute (step)
  "Run STEP. Returns NIL, or :NOT-RUN and a reason. Signals STEP-FAILURE or a browser error when
it fails."
  (destructuring-bind (kind &rest args) step
    (ecase kind
      ((:visit :fill :click :select) (%run-action step) nil)
      (:wait-for (%wait-for args) nil)
      (:expect-screen (%expect-screen args) nil)
      (:expect-text (%expect-text args) nil)
      (:expect-stored (%expect-stored args))
      (:expect-scroll-kept (%expect-scroll-kept args) nil)
      (:screenshot (%screenshot args) nil))))

(defun %run-step (step)
  "Run STEP and the checks made after every step, in the current row. Returns the outcome kind,
\"passed\", \"failed\" or \"not-run\", its reason (empty when it passed), and its duration in
milliseconds."
  (let ((start (get-internal-real-time))
        (row *row*))
    (%begin-step row)
    (multiple-value-bind (outcome reason)
        (handler-case (%execute step)
          (step-failure (c) (values :failed (step-failure-reason c)))
          (cdp:cdp-condition (c) (values :failed (%clip (princ-to-string c) 400)))
          (error (c) (values :failed (format nil "~A: ~A" (type-of c) (%clip (princ-to-string c) 400)))))
      (let ((problems (handler-case (%end-step-problems row)
                        (cdp:cdp-condition (c) (list (%clip (princ-to-string c) 400))))))
        (values (cond ((eq outcome :failed) "failed")
                      (problems "failed")
                      ((eq outcome :not-run) "not-run")
                      (t "passed"))
                (cond ((eq outcome :failed)
                       (if problems
                           (format nil "~A; and ~{~A~^; ~}" reason problems)
                           reason))
                      (problems (format nil "~{~A~^; ~}" problems))
                      ((eq outcome :not-run) reason)
                      (t ""))
                (%elapsed-ms start))))))
