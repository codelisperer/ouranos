;;;; folder-watch.lisp --- tests for aion/folder-watch (#996), on real temporary folders.
;;;;
;;;; Each test makes a fresh folder with aion/fs:make-temporary-directory, runs a loop thread
;;;; with WATCH-FOLDER on it, changes files from the test's thread, and reads the events the
;;;; watcher reported. SETTLE is short here (0.4 s) so the suite stays quick.

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

(defun %write (dir name text)
  (let ((path (merge-pathnames name dir)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede :external-format :utf-8)
      (write-string text out))
    path))

(defun call-with-watched-folder (function &key setup (settle +settle+) (ignore :defaults)
                                               report-existing)
  "Make a fresh folder, call SETUP with it, watch it, and call FUNCTION with the folder and a
function that returns the events reported so far, oldest first, as (KIND NAME SIZE)."
  (let ((dir (aion/fs:make-temporary-directory "folder-watch-test"))
        (loop (uv:make-loop))
        (events '())
        (lock (sb-thread:make-mutex :name "folder-watch test events")))
    (unwind-protect
         (progn
           (when setup (funcall setup dir))
           (fw:watch-folder loop dir
                            (lambda (e)
                              (sb-thread:with-mutex (lock)
                                (push (list (fw:folder-event-kind e) (fw:folder-event-name e)
                                            (fw:folder-event-size e))
                                      events)))
                            :settle settle :ignore ignore :report-existing report-existing)
           (uv:start-loop-thread loop)
           ;; Give the watch a moment to be armed before changing anything, as aion/uv's own
           ;; watch test does.
           (sleep 0.3)
           (funcall function dir (lambda () (sb-thread:with-mutex (lock) (reverse events)))))
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

;;; --- the ignore filter, without a watch -------------------------------------------------

(test glob-patterns-match-whole-names-without-case
  (is-true (fw:glob-match-p "*.tmp" "Notes.TMP"))
  (is-true (fw:glob-match-p "~$*" "~$report.docx"))
  (is-true (fw:glob-match-p "* (*conflicted copy*" "draft (Bob's conflicted copy 2026-11-01).txt"))
  (is-true (fw:glob-match-p "4913" "4913"))
  (is-true (fw:glob-match-p ".~lock.*#" ".~lock.draft.odt#"))
  (is-true (fw:glob-match-p "a?c" "abc"))
  (is-false (fw:glob-match-p "*.tmp" "notes.tmp.txt") "a pattern matches the whole name")
  (is-false (fw:glob-match-p "a?c" "ac"))
  (is-false (fw:glob-match-p "4913" "49130")))

(test a-pattern-that-matches-a-folder-ignores-everything-under-it
  (is-true (fw:ignored-p ".dropbox.cache/2026/part.bin" fw:+sync-litter+))
  (is-true (fw:ignored-p "drafts/.~lock.chapter.odt#" fw:+sync-litter+))
  (is-false (fw:ignored-p "drafts/chapter.odt" fw:+sync-litter+) "control: a draft is not litter")
  (is-true (fw:ignored-p "a/b.txt" (list (lambda (name) (string= name "a/b.txt"))))
           "a function pattern sees the relative name"))

;;; --- settling -----------------------------------------------------------------------------

(test a-file-written-in-pieces-is-reported-once-after-the-last-piece
  "Four writes, 0.1 s apart and so each inside the settle period, are one :SETTLED, with the last
write's size. Without settling, each write's events would be seen as a finished file."
  (with-watched-folder (dir events)
    (loop for text in '("a" "ab" "abc" "abcd")
          do (%write dir "draft.txt" text) (sleep 0.1))
    (let ((seen (%wait events (lambda (e) (%settled e "draft.txt")))))
      ;; Wait past one more settle period, so a second report would have had time to come.
      (sleep (* 3 +settle+))
      (setf seen (funcall events))
      (is (= 1 (length (%settled seen "draft.txt"))) "~S" seen)
      (is (eql 4 (third (first (%settled seen "draft.txt")))) "the last write's size: ~S" seen))))

(test sync-litter-is-not-reported-and-a-real-file-is
  (with-watched-folder (dir events)
    (dolist (name '("notes.tmp" "~$chapter.docx" "chapter (Bob's conflicted copy 2026-11-01).docx"
                    ".chapter.docx.swp" "4913"))
      (%write dir name "litter"))
    (%write dir "chapter.docx" "draft")
    (let ((seen (%wait events (lambda (e) (%settled e "chapter.docx")))))
      (sleep (* 3 +settle+))
      (setf seen (funcall events))
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
      (let ((seen (%wait events (lambda (e) (= 2 (length (%settled e "doc.txt")))))))
        (sleep (* 3 +settle+))
        (setf seen (funcall events))
        (is (equal '((:settled "doc.txt" 5) (:settled "doc.txt" 11)) seen) "~S" seen)))))

(test report-existing-reports-what-was-there-and-skips-ignored-folders
  "REPORT-EXISTING reports each file already in the folder, including one in a subfolder, and not
one under an ignored folder. The control is the same folder watched without it, which reports
nothing until a file changes."
  (flet ((setup (dir)
           (%write dir "one.txt" "1")
           (%write dir "sub/two.txt" "22")
           (%write dir ".dropbox.cache/partial.bin" "333")))
    (with-watched-folder (dir events :setup #'setup :report-existing t)
      (let ((seen (%wait events (lambda (e) (= 2 (length e))))))
        (sleep (* 3 +settle+))
        (setf seen (funcall events))
        (is (equal '(("one.txt" 1) ("sub/two.txt" 2))
                   (sort (mapcar #'rest seen) #'string< :key #'first))
            "~S" seen)))
    (with-watched-folder (dir events :setup #'setup)
      (sleep (* 3 +settle+))
      (is (null (funcall events)) "control: without it, nothing: ~S" (funcall events)))))
