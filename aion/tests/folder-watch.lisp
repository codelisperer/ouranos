;;;; folder-watch.lisp --- tests for aion/folder-watch (#996), on real temporary folders.
;;;;
;;;; Each test makes a fresh folder with aion/fs:make-temporary-directory, runs a loop thread
;;;; with WATCH-FOLDER on it, changes files from the test's thread, and reads the events the
;;;; watcher reported. SETTLE is short (0.4 s) where a test only needs a report to come; a test
;;;; that checks a report does NOT come before its time uses about a second, so a pause in the
;;;; test's own thread cannot pass for the settle period.

(defpackage #:aion/folder-watch/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:fw #:aion/folder-watch)
                    (#:uv #:aion/uv))
  (:export #:run-tests))

(in-package #:aion/folder-watch/tests)

(def-suite folder-watch :description "aion/folder-watch: settled files and the ignore filter (#996).")
(in-suite folder-watch)

(defun run-tests ()
  (let ((results (run 'folder-watch)))
    (explain! results)
    (results-status results)))

(defparameter +settle+ 0.4)

(defvar *watcher* nil "The FOLDER-WATCHER of the running WITH-WATCHED-FOLDER.")
(defvar *loop* nil "Its loop.")

(defun %write (dir name text)
  (let ((path (merge-pathnames name dir)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede :external-format :utf-8)
      (write-string text out))
    path))

(defun %native (dir name)
  (uiop:native-namestring (merge-pathnames name dir)))

(defun call-with-watched-folder (function &key setup (settle +settle+) (ignore :defaults)
                                               report-existing also)
  "Make a fresh folder, call SETUP with it, watch it, and call FUNCTION with the folder and a
function that returns the events reported so far, oldest first, as (KIND NAME SIZE). ALSO, when
given, is called on the loop thread with each event and the FOLDER-WATCHER after the event is
recorded; the watcher is passed because *WATCHER* is bound on the test's thread only."
  (let ((dir (aion/fs:make-temporary-directory "folder-watch-test"))
        (loop (uv:make-loop))
        (events '())
        (watcher-box (list nil))
        (lock (sb-thread:make-mutex :name "folder-watch test events")))
    (unwind-protect
         (progn
           (when setup (funcall setup dir))
           (let ((*loop* loop)
                 (*watcher*
                   (fw:watch-folder loop dir
                                    (lambda (e)
                                      (sb-thread:with-mutex (lock)
                                        (push (list (fw:folder-event-kind e)
                                                    (fw:folder-event-name e)
                                                    (fw:folder-event-size e))
                                              events))
                                      (when also (funcall also e (car watcher-box))))
                                    :settle settle :ignore ignore
                                    :report-existing report-existing)))
             (setf (car watcher-box) *watcher*)
             (uv:start-loop-thread loop)
             ;; Give the watch a moment to be armed before changing anything, as aion/uv's own
             ;; watch test does.
             (sleep 0.3)
             (funcall function dir (lambda () (sb-thread:with-mutex (lock) (reverse events))))))
      (uv:close-loop loop)
      (ignore-errors (aion/fs:delete-tree dir)))))

(defmacro with-watched-folder ((dir events &rest keys) &body body)
  `(call-with-watched-folder (lambda (,dir ,events) (declare (ignorable ,dir)) ,@body) ,@keys))

(defun %wait (events predicate &key (timeout 10))
  "Wait until PREDICATE is true of the events so far, or TIMEOUT seconds. Returns the events."
  (loop with deadline = (+ (get-internal-real-time) (* timeout internal-time-units-per-second))
        for now = (funcall events)
        until (or (funcall predicate now) (> (get-internal-real-time) deadline))
        do (sleep 0.05)
        finally (return (funcall events))))

(defun %settled (events name)
  (remove-if-not (lambda (e) (and (eq :settled (first e)) (string= name (second e)))) events))

(defun %on-loop (function)
  "Run FUNCTION on the watched loop's thread and wait for it."
  (let ((done (sb-thread:make-semaphore)))
    (uv:submit *loop* (lambda () (unwind-protect (funcall function) (sb-thread:signal-semaphore done))))
    (sb-thread:wait-on-semaphore done :timeout 10)))

;;; --- the ignore filter, without a watch -------------------------------------------------

(test glob-patterns-match-whole-names-without-case
  (is-true (fw:glob-match-p "*.tmp" "Notes.TMP"))
  (is-true (fw:glob-match-p "~$*" "~$report.docx"))
  (is-true (fw:glob-match-p "* (*conflicted copy*" "draft (Bob's conflicted copy 2026-11-01).txt"))
  (is-true (fw:glob-match-p "4913" "4913"))
  (is-true (fw:glob-match-p ".~lock.*#" ".~lock.draft.odt#"))
  (is-true (fw:glob-match-p "a?c" "abc"))
  (is-true (fw:glob-match-p "*" ""))
  (is-true (fw:glob-match-p "a*b*c" "a-b-b-c"))
  (is-false (fw:glob-match-p "*.tmp" "notes.tmp.txt") "a pattern matches the whole name")
  (is-false (fw:glob-match-p "a?c" "ac"))
  (is-false (fw:glob-match-p "4913" "49130")))

(test a-pattern-with-many-stars-does-not-backtrack-without-bound
  "The hub's review of #1074: a recursive matcher took time exponential in the stars. This one
remembers the last star, so a pattern of nine stars against 2000 characters is quick."
  (let ((start (get-internal-real-time)))
    (is-false (fw:glob-match-p "*a*a*a*a*a*a*a*a*b" (make-string 2000 :initial-element #\a)))
    (is (< (- (get-internal-real-time) start) (* 2 internal-time-units-per-second))
        "it took ~,2F s" (/ (- (get-internal-real-time) start) internal-time-units-per-second))))

(test a-pattern-that-matches-a-folder-ignores-everything-under-it
  (is-true (fw:ignored-p ".dropbox.cache/2026/part.bin" fw:+sync-litter+))
  (is-true (fw:ignored-p "drafts/.~lock.chapter.odt#" fw:+sync-litter+))
  (is-false (fw:ignored-p "drafts/chapter.odt" fw:+sync-litter+) "control: a draft is not litter")
  (is-true (fw:ignored-p "a/b.txt" (list (lambda (name) (string= name "a/b.txt"))))
           "a function pattern sees the relative name"))

(test the-default-list-covers-each-sync-client-and-system
  (dolist (name (list "chapter (Selective Sync Conflict).docx" ".dropbox" ".dropbox.attr"
                      ".tmp.driveupload/1234" ".tmp.drivedownload/5678" "draft.docx.crdownload"
                      "draft.partial" "._chapter.docx" (format nil "Icon~C" #\Return)
                      "desktop.ini" "Thumbs.db" ".DS_Store"))
    (is-true (fw:ignored-p name fw:+sync-litter+) "~S" name))
  (dolist (name '("chapter.docx" "Icon" "notes.txt" "download.txt"))
    (is-false (fw:ignored-p name fw:+sync-litter+) "control: ~S is not litter" name)))

(test the-ignore-argument-takes-defaults-strings-and-functions
  (let ((patterns (fw::%patterns (list :defaults "*.bak" #'identity))))
    (is (subsetp fw:+sync-litter+ patterns :test #'equal) ":defaults inside a list adds the list")
    (is (member "*.bak" patterns :test #'equal))
    (is (member #'identity patterns)))
  (is (equal fw:+sync-litter+ (fw::%patterns :defaults)))
  (is (null (fw::%patterns '())) "an empty list ignores nothing")
  (signals error (fw::%patterns '(42)))
  (signals error (fw::%patterns "*.tmp")))

;;; --- settling -----------------------------------------------------------------------------

(test a-file-written-in-pieces-is-reported-once-after-the-last-piece
  "Four writes, 0.1 s apart and so each inside the settle period, are one :SETTLED, with the last
write's size. Without settling, each write's events would be seen as a finished file. SETTLE is
1 s here, so a pause in this thread cannot pass for it."
  (with-watched-folder (dir events :settle 1.0)
    (loop for text in '("a" "ab" "abc" "abcd")
          do (%write dir "draft.txt" text) (sleep 0.1))
    (%wait events (lambda (e) (%settled e "draft.txt")))
    ;; Wait past two more settle periods, so a second report would have had time to come.
    (sleep 2.0)
    (let ((seen (funcall events)))
      (is (= 1 (length (%settled seen "draft.txt"))) "~S" seen)
      (is (eql 4 (third (first (%settled seen "draft.txt")))) "the last write's size: ~S" seen))))

(test a-file-is-not-reported-before-it-has-settled
  "The other direction: a file just written is not reported until SETTLE seconds after its last
change."
  (with-watched-folder (dir events :settle 1.2)
    (%write dir "fresh.txt" "new")
    (sleep 0.5)
    (is (null (funcall events)) "nothing yet, half a settle period later: ~S" (funcall events))
    (let ((seen (%wait events (lambda (e) (%settled e "fresh.txt")))))
      (is (equal '((:settled "fresh.txt" 3)) seen) "then the file: ~S" seen))))

(test a-file-deleted-before-it-settled-is-not-reported
  (with-watched-folder (dir events :settle 1.0)
    (let ((path (%write dir "brief.txt" "here and gone")))
      (sleep 0.2)
      (delete-file path))
    (sleep 2.5)
    (is (null (funcall events)) "neither :settled nor :removed: ~S" (funcall events))))

(test sync-litter-is-not-reported-and-a-real-file-is
  (with-watched-folder (dir events)
    (dolist (name '("notes.tmp" "~$chapter.docx" "chapter (Bob's conflicted copy 2026-11-01).docx"
                    ".chapter.docx.swp" "4913" "._chapter.docx"))
      (%write dir name "litter"))
    (%write dir "chapter.docx" "draft")
    (%wait events (lambda (e) (%settled e "chapter.docx")))
    (sleep (* 3 +settle+))
    (let ((seen (funcall events)))
      (is (equal '((:settled "chapter.docx" 5)) seen) "only the real file: ~S" seen))))

(test a-removed-file-is-reported-removed
  (with-watched-folder (dir events)
    (let ((path (%write dir "gone.txt" "here")))
      (%wait events (lambda (e) (%settled e "gone.txt")))
      (delete-file path)
      (let ((seen (%wait events (lambda (e) (find :removed e :key #'first)))))
        (is (equal '((:settled "gone.txt" 4) (:removed "gone.txt" nil)) seen) "~S" seen)))))

(test a-rename-is-the-old-name-removed-and-the-new-name-settled
  (with-watched-folder (dir events)
    (let ((old (%write dir "old.txt" "text")))
      (%wait events (lambda (e) (%settled e "old.txt")))
      (rename-file old (merge-pathnames "new.txt" dir))
      (let ((seen (%wait events (lambda (e) (and (%settled e "new.txt")
                                                 (find :removed e :key #'first))))))
        (is (member '(:removed "old.txt" nil) seen :test #'equal) "~S" seen)
        (is (member '(:settled "new.txt" 4) seen :test #'equal) "~S" seen)
        (is (= 3 (length seen)) "nothing else: ~S" seen)))))

(test a-save-through-a-temporary-file-is-one-settled-and-no-removal
  "An editor that writes a temporary file and renames it over the target leaves the target
missing for a moment. That is reported as the target settling with its new content, not as a
removal, and the temporary file, ignored by *.tmp, is not reported."
  (with-watched-folder (dir events)
    (let ((target (%write dir "doc.txt" "first")))
      (%wait events (lambda (e) (%settled e "doc.txt")))
      (let ((tmp (%write dir "doc.txt.tmp" "second save")))
        (delete-file target)
        (rename-file tmp target))
      (%wait events (lambda (e) (= 2 (length (%settled e "doc.txt")))))
      (sleep (* 3 +settle+))
      (let ((seen (funcall events)))
        (is (equal '((:settled "doc.txt" 5) (:settled "doc.txt" 11)) seen) "~S" seen)))))

#+(or win32 darwin)
(test a-rename-that-changes-only-case-is-one-file
  "The hub's review of #1074: on Windows and macOS a name that differs only in case is the same
file, so renaming a.txt to A.txt reports nothing, and a later delete is one :REMOVED, not a
removal for one spelling with the other left behind."
  (with-watched-folder (dir events)
    (let ((path (%write dir "a.txt" "case")))
      (%wait events (lambda (e) (%settled e "a.txt")))
      (rename-file path (merge-pathnames "A.txt" dir))
      (sleep (* 3 +settle+))
      (is (= 1 (length (funcall events))) "the rename reported nothing: ~S" (funcall events))
      (delete-file (merge-pathnames "A.txt" dir))
      (%wait events (lambda (e) (find :removed e :key #'first)))
      (sleep (* 3 +settle+))
      (let ((seen (funcall events)))
        (is (= 1 (count :removed seen :key #'first)) "one removal: ~S" seen)
        (is (= 2 (length seen)) "and nothing else: ~S" seen)))))

;;; --- directories --------------------------------------------------------------------------

(test a-folder-moved-in-reports-each-file-in-it
  "The hub's review of #1074: moving a folder in raises one event, for the folder, so its files
were never reported. A directory event now scans it."
  (let ((source (aion/fs:make-temporary-directory "folder-watch-source")))
    (unwind-protect
         (with-watched-folder (dir events)
           (dolist (name '("one.txt" "two.txt" "three.txt"))
             (%write (merge-pathnames "batch/" source) name name))
           (uv:rename-path (%native source "batch") (%native dir "batch"))
           (let ((seen (%wait events (lambda (e) (= 3 (length e))))))
             (sleep (* 3 +settle+))
             (setf seen (funcall events))
             (is (equal '("batch/one.txt" "batch/three.txt" "batch/two.txt")
                        (sort (mapcar #'second seen) #'string<))
                 "~S" seen)
             (is (every (lambda (e) (eq :settled (first e))) seen) "~S" seen)))
      (ignore-errors (aion/fs:delete-tree source)))))

(test a-folder-deleted-reports-its-files-removed
  "The hub's review of #1074: deleting a subfolder raises an event for the folder, not for each
file, on Linux. Each reported file under a path now missing is reported :REMOVED."
  (with-watched-folder (dir events :report-existing t
                                   :setup (lambda (d) (%write d "sub/x.txt" "x") (%write d "sub/y.txt" "yy")))
    (%wait events (lambda (e) (= 2 (length e))))
    (aion/fs:delete-tree (merge-pathnames "sub/" dir))
    (let ((seen (%wait events (lambda (e) (= 2 (count :removed e :key #'first))))))
      (is (equal '((:removed "sub/x.txt" nil) (:removed "sub/y.txt" nil))
                 (sort (remove :settled seen :key #'first) #'string< :key #'second))
          "~S" seen))))

;;; --- a file that cannot be read, and stopping --------------------------------------------

(test a-file-that-cannot-be-read-stays-pending-and-does-not-stop-the-others
  "The hub's review of #1074: a stat that fails with anything but not-found, such as a sharing
violation while a writer holds the file on Windows, escaped and stopped every later tick, so no
other file settled. The stat is made to fail for locked.txt for 1.5 s: free.txt settles in the
meantime, and locked.txt settles once it can be read."
  (let ((original fw::*%file-info*)
        (until (+ (get-internal-real-time) (* 1.5 internal-time-units-per-second))))
    (unwind-protect
         (progn
           (setf fw::*%file-info*
                 (lambda (path)
                   (if (and (search "locked.txt" path) (< (get-internal-real-time) until))
                       (error 'uv:permission-denied :code -13 :name "EACCES"
                                                    :message "held by another program"
                                                    :operation :file-info :path path)
                       (funcall original path))))
           (with-watched-folder (dir events)
             (%write dir "locked.txt" "held")
             (%write dir "free.txt" "free")
             (let ((seen (%wait events (lambda (e) (%settled e "free.txt")) :timeout 5)))
               (is (%settled seen "free.txt") "the readable file settled: ~S" seen)
               (is (null (%settled seen "locked.txt")) "the held one did not yet: ~S" seen))
             (let ((seen (%wait events (lambda (e) (%settled e "locked.txt")) :timeout 10)))
               (is (equal '(:settled "locked.txt" 4) (first (%settled seen "locked.txt")))
                   "and settled once readable: ~S" seen))))
      (setf fw::*%file-info* original))))

(test stopping-the-watch-stops-its-events
  (with-watched-folder (dir events)
    ;; Captured here: *WATCHER* is bound on this thread, not on the loop's.
    (let ((watcher *watcher*))
      (%on-loop (lambda () (fw:stop-folder-watch watcher))))
    (%write dir "after.txt" "too late")
    (sleep (* 4 +settle+))
    (is (null (funcall events)) "~S" (funcall events))))

(test stopping-from-the-callback-stops-the-rest-of-that-tick
  "The hub's review of #1074: stopping inside the caller's function used to let the rest of the
tick's events through, and then stop a timer already closed."
  (with-watched-folder (dir events :also (lambda (e watcher) (declare (ignore e))
                                           (fw:stop-folder-watch watcher)))
    (dolist (name '("a.txt" "b.txt" "c.txt")) (%write dir name name))
    (sleep (* 4 +settle+))
    (is (= 1 (length (funcall events))) "one event, then stopped: ~S" (funcall events))))
