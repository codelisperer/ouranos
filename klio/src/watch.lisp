;;;; watch.lisp --- reload a site when its content changes, for development (#353).
;;;;
;;;; An author edits a Markdown file and wants to see the page. WATCH-SITE starts a thread that
;;;; looks at the content directory every INTERVAL seconds and calls RELOAD when anything in it
;;;; has changed: a file edited, added or removed.
;;;;
;;;; POLLING, NOT FILESYSTEM EVENTS. inotify, FSEvents and ReadDirectoryChangesW are three native
;;;; interfaces with three failure modes, for a directory of a few hundred small files that one
;;;; person edits. Reading it once a second costs nothing a developer would notice.
;;;;
;;;; A CHANGE IS JUDGED BY CONTENT, NOT ONLY BY DATE. A file's write date has a resolution of one
;;;; second on some filesystems, so an edit saved in the same second as the previous one, with
;;;; the same length (a one-letter typo fixed), would look unchanged. The snapshot therefore
;;;; includes a hash of each file's text.
;;;;
;;;; A CHANGE IS RELOADED ONCE TWO POLLS IN A ROW SEE IT (#534). A file saved in place is opened
;;;; with O_TRUNC, so it is empty from the open until the close writes the new text. A poll that
;;;; lands in that window used to reload the empty file and publish it: a document with no front
;;;; matter, served with no title, until the next poll. Waiting for a second poll to see the same
;;;; snapshot skips a write that finishes within one interval, which an editor's save does. A
;;;; write held open for longer than an interval still looks settled while it is empty, and is
;;;; reloaded; the change is then reloaded again when the write finishes. The cost is one more
;;;; interval before an edit is served.
;;;;
;;;; RELOAD, NOT RELOAD-OR-FAIL. A bad edit must not end the watcher: RELOAD keeps serving the
;;;; last good tree and reports the failures, which are logged, and the next save that fixes
;;;; the file publishes it. That is ADR-0001's reload rule, which is what an author wants while
;;;; typing. A deploy uses RELOAD-OR-FAIL; this is not a deploy.
;;;;
;;;; FOR DEVELOPMENT. How production content is updated is recorded in
;;;; docs/adr/0002-reload-in-production.md.

(in-package #:klio)

(defun content-snapshot (directory)
  "What WATCH-SITE compares: every content file under DIRECTORY with its size, write date and
a hash of its text, in CONTENT-FILES order."
  (mapcar (lambda (path)
            (let ((text (handler-case (uiop:read-file-string path :external-format :utf-8)
                          ;; A file being written, or removed between the listing and the
                          ;; read. The next poll sees it settled.
                          (error () nil))))
              (list (namestring path)
                    (ignore-errors (file-write-date path))
                    (and text (length text))
                    (and text (sxhash text)))))
          (content-files directory)))

(defun %watch-start (directory)
  "The state a watcher of DIRECTORY starts from: (values SEEN PENDING) for %WATCH-STEP, the
directory's snapshot with no change pending."
  (values (content-snapshot directory) :none))

(defun %watch-step (seen pending now)
  "One poll's decision. SEEN is the snapshot last reloaded, PENDING the change the previous poll
saw (:NONE when none), NOW this poll's snapshot. Returns (values RELOAD-P SEEN PENDING), the
last two for the next poll: a change is reloaded only when NOW equals PENDING, so two polls in
a row have seen it.

:NONE, not NIL, marks no pending change, because NIL is a snapshot: the one of a directory with
no content files left. With NIL, the first poll to see the last file removed reloaded at once
(Copilot's review of #535)."
  (cond ((equal now seen) (values nil seen :none))
        ((and (not (eq pending :none)) (equal now pending)) (values t now :none))
        (t (values nil seen now))))

(defstruct (watcher (:constructor %make-watcher) (:copier nil))
  (site nil :read-only t)
  (thread nil)
  (stop (sb-thread:make-semaphore :name "klio-watcher-stop") :read-only t)
  (reloads 0))

(defun %report-reload (outcome failures)
  (if (eq outcome :published)
      (log:info "klio: content changed, reloaded" :warnings (length failures))
      (log:warn "klio: content changed, reload refused; still serving the last good content"
                :failures (length failures)
                :files (format nil "~{~A~^, ~}" (mapcar #'load-failure-file failures)))))

(defun watch-site (site &key (interval 1) on-reload)
  "Start a thread that reloads SITE whenever a file in its content directory changes, checking
every INTERVAL seconds. A change is reloaded once two polls in a row have seen it, so a file
read while it is being written is not published. Returns a WATCHER; STOP-WATCHING stops it.

ON-RELOAD, when given, is called with RELOAD's two values (the outcome and the failures) after
each reload, on the watcher's thread; the outcome and the failing files are also logged. A bad
edit leaves the last good content published (see RELOAD), and the watcher keeps running."
  (check-type interval (real (0)))
  (let* ((watcher (%make-watcher :site site))
         (directory (site-directory site))
         ;; THE BASELINE IS TAKEN HERE, before the thread exists. Taken on the thread, it
         ;; could be taken after the caller's first edit, which would then be the baseline
         ;; and never be seen as a change.
         (baseline (multiple-value-list (%watch-start directory))))
    (setf (watcher-thread watcher)
          ;; THREAD-LIFETIME: independent -- runs until STOP-WATCHING, which joins it.
          (sb-thread:make-thread
           (lambda ()
             (destructuring-bind (seen pending) baseline
               (loop until (sb-thread:wait-on-semaphore (watcher-stop watcher) :timeout interval)
                     do (multiple-value-bind (reload-p next-seen next-pending)
                            (%watch-step seen pending (content-snapshot directory))
                          (setf seen next-seen pending next-pending)
                          (when reload-p
                            (multiple-value-bind (outcome failures) (reload site)
                              (incf (watcher-reloads watcher))
                              (%report-reload outcome failures)
                              (when on-reload
                                (handler-case (funcall on-reload outcome failures)
                                  (error (e)
                                    (log:warn "klio: the watcher's on-reload signalled"
                                              :condition (type-of e)))))))))))
           :name "klio-content-watcher"))
    watcher))

(defun stop-watching (watcher)
  "Stop WATCHER's thread and wait for it to end. Idempotent."
  (let ((thread (watcher-thread watcher)))
    (when thread
      (sb-thread:signal-semaphore (watcher-stop watcher))
      (sb-thread:join-thread thread :default nil)
      (setf (watcher-thread watcher) nil))
    watcher))
