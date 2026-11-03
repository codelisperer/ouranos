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
                                               report-existing also (recursive t) path)
  "Make a fresh folder, call SETUP with it, watch it, and call FUNCTION with the folder and a
function that returns the events reported so far, oldest first, as (KIND NAME SIZE). ALSO, when
given, is called on the loop thread with each event and the FOLDER-WATCHER after the event is
recorded; the watcher is passed because *WATCHER* is bound on the test's thread only. PATH, when
given, is called with the folder and returns what to watch instead of the folder."
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
                   (fw:watch-folder loop (if path (funcall path dir) dir)
                                    (lambda (e)
                                      (sb-thread:with-mutex (lock)
                                        (push (list (fw:folder-event-kind e)
                                                    (fw:folder-event-name e)
                                                    (fw:folder-event-size e))
                                              events))
                                      (when also (funcall also e (car watcher-box))))
                                    :settle settle :ignore ignore :recursive recursive
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

;;; --- Copilot's review of #1074 -----------------------------------------------------------

(test a-folder-renamed-inside-the-watched-folder-reports-old-names-removed-and-new-settled
  "Renaming a populated subfolder can be one event per name, for the folders only. The new name
is scanned, and each reported file under the old name is reported removed."
  (with-watched-folder (dir events :report-existing t
                                   :setup (lambda (d) (%write d "sub/a.txt" "a") (%write d "sub/b.txt" "bb")))
    (%wait events (lambda (e) (= 2 (length e))))
    (uv:rename-path (%native dir "sub") (%native dir "moved"))
    (let ((seen (%wait events (lambda (e) (= 6 (length e))))))
      (sleep (* 3 +settle+))
      (setf seen (subseq (funcall events) 2))
      (is (equal '((:removed "sub/a.txt" nil) (:removed "sub/b.txt" nil)
                   (:settled "moved/a.txt" 1) (:settled "moved/b.txt" 2))
                 (sort (copy-list seen)
                       (lambda (x y) (string< (format nil "~A ~A" (first x) (second x))
                                              (format nil "~A ~A" (first y) (second y))))))
          "~S" seen))))

(test events-with-no-filename-do-not-hold-back-a-file-that-is-settling
  "Copilot's review of #1074: a backend that sends events with no filename made every rescan
restart the quiet period of each file waiting to settle, so while other files kept changing it
never settled. Here a rescan runs on the loop every 0.2 s for 3 s, with SETTLE 1 s; the file is
reported before the rescans stop."
  (with-watched-folder (dir events :settle 1.0)
    (%write dir "steady.txt" "steady")
    (let ((watcher *watcher*)
          (stop (+ (get-internal-real-time) (* 3 internal-time-units-per-second)))
          (reported-at nil))
      (loop while (< (get-internal-real-time) stop)
            do (%on-loop (lambda () (fw::%rescan watcher)))
               (when (and (null reported-at) (%settled (funcall events) "steady.txt"))
                 (setf reported-at (get-internal-real-time)))
               (sleep 0.2))
      (is-true reported-at "settled while the rescans went on: ~S" (funcall events)))))

#-win32
(test a-backslash-in-a-name-is-part-of-the-name-off-windows
  "Copilot's review of #1074: a backslash is an ordinary character in a Unix name, so it is not
turned into a folder separator there. The file is made from a native name, because SBCL reads a
backslash in a Lisp namestring as an escape, so %WRITE would make draftfinal.txt instead."
  (with-watched-folder (dir events)
    (with-open-file (out (uiop:parse-native-namestring
                          (concatenate 'string (uiop:native-namestring dir) "draft\\final.txt"))
                         :direction :output :external-format :utf-8)
      (write-string "kept" out))
    (let ((seen (%wait events (lambda (e) (%settled e "draft\\final.txt")))))
      (is (equal '((:settled "draft\\final.txt" 4)) seen) "~S" seen))))

(test a-folder-that-cannot-be-listed-is-tried-again-not-taken-for-empty
  "Copilot's review of #1074, as the hub read it: a listing that failed for any reason but the
folder having gone was taken for an empty folder, so REPORT-EXISTING could leave files out
without a word. The folder is now kept pending and tried again; its files are reported once it
can be listed, and WATCH-FOLDER itself does not fail. The listing of locked/ fails for 1.5 s."
  (let ((original fw::*%list-directory*)
        (until (+ (get-internal-real-time) (* 1.5 internal-time-units-per-second))))
    (unwind-protect
         (progn
           (setf fw::*%list-directory*
                 (lambda (path)
                   (if (and (search "locked" path) (< (get-internal-real-time) until))
                       (error 'uv:permission-denied :code -13 :name "EACCES" :message "denied"
                                                    :operation :list-directory :path path)
                       (funcall original path))))
           (with-watched-folder (dir events :report-existing t
                                            :setup (lambda (d) (%write d "locked/a.txt" "a")
                                                     (%write d "open.txt" "o")))
             (let ((seen (%wait events (lambda (e) (%settled e "locked/a.txt")) :timeout 10)))
               (is (%settled seen "open.txt") "the readable file: ~S" seen)
               (is (%settled seen "locked/a.txt") "and the folder's file, once listed: ~S" seen))))
      (setf fw::*%list-directory* original))))

(test an-ignore-function-that-signals-at-start-leaves-nothing-running
  "The hub's re-review of #1074: when the first scan signals, here from the caller's own ignore
function, the caller gets no watcher to stop, so WATCH-FOLDER closes its watch and timer itself."
  (let ((dir (aion/fs:make-temporary-directory "folder-watch-test"))
        (loop (uv:make-loop)))
    (unwind-protect
         (progn
           (%write dir "a.txt" "a")
           (signals error
             (fw:watch-folder loop dir (lambda (e) (declare (ignore e)))
                              :ignore (list (lambda (name) (error "refusing ~A" name)))))
           (uv:start-loop-thread loop)
           (sleep 0.2)
           ;; The loop thread's own :ASYNC handle stays; the watcher's are a watch and a timer.
           (is (null (remove-if-not (lambda (h) (and (member (uv:handle-info-kind h) '(:fs-event :timer))
                                                    (uv:handle-info-active h)
                                                    (not (uv:handle-info-closing h))))
                                    (uv:loop-handles loop)))
               "no watch or timer left running: ~S" (uv:loop-handles loop)))
      (uv:close-loop loop)
      (ignore-errors (aion/fs:delete-tree dir)))))

(test a-watch-that-is-not-recursive-does-not-report-a-folder-moved-in
  "The hub's re-review of #1074: with :RECURSIVE NIL a directory event scanned the folder anyway,
though the first scan does not. The control is the same move with a recursive watch, in
a-folder-moved-in-reports-each-file-in-it, and a file at the top level here, which is reported."
  (let ((source (aion/fs:make-temporary-directory "folder-watch-source")))
    (unwind-protect
         (with-watched-folder (dir events :recursive nil)
           (%write (merge-pathnames "batch/" source) "one.txt" "one")
           (uv:rename-path (%native source "batch") (%native dir "batch"))
           (%write dir "top.txt" "top")
           (let ((seen (%wait events (lambda (e) (%settled e "top.txt")))))
             (sleep (* 3 +settle+))
             (setf seen (funcall events))
             (is (equal '((:settled "top.txt" 3)) seen) "only the top-level file: ~S" seen)))
      (ignore-errors (aion/fs:delete-tree source)))))

;;; --- the hub's second review of #1074 -------------------------------------------------------

(defun %subfolder (dir name)
  "The native name of the folder NAME inside DIR, ending in a separator."
  (concatenate 'string (uiop:native-namestring dir) name (string (fw::%separator))))

(test a-folder-whose-name-has-brackets-is-watched-by-that-name
  "A string path was parsed as a Lisp namestring, which took the brackets for a wildcard and
signalled. The string is now used as written."
  (with-watched-folder (dir events :report-existing t
                                   :setup (lambda (d)
                                            (let ((sub (%subfolder d "Photos [2026]")))
                                              (uv:make-directory sub :parents t)
                                              (uv:write-file (concatenate 'string sub "a.txt") "a")))
                                   :path (lambda (d) (%subfolder d "Photos [2026]")))
    (let ((seen (%wait events (lambda (e) (%settled e "a.txt")))))
      (is (equal '((:settled "a.txt" 1)) seen) "~S" seen))))

(defun %pathname-without-separator (native)
  "The pathname UIOP:PARSE-NATIVE-NAMESTRING gives for NATIVE without its trailing separator: the
last folder is then the pathname's name, which is the form UIOP:ENSURE-DIRECTORY-PATHNAME escaped
(#1112)."
  (uiop:parse-native-namestring
   (string-right-trim (if (uiop:os-windows-p) "/\\" "/") native)))

(test a-folder-given-as-a-pathname-whose-name-has-brackets-is-watched-by-that-name
  "Copilot's review of #1109 (#1112): a pathname went through UIOP:ENSURE-DIRECTORY-PATHNAME, which
escaped the brackets, so on Windows Photos ^[2026] was watched and WATCH-FOLDER signalled
FILE-NOT-FOUND."
  (with-watched-folder (dir events :report-existing t
                                   :setup (lambda (d)
                                            (let ((sub (%subfolder d "Photos [2026]")))
                                              (uv:make-directory sub :parents t)
                                              (uv:write-file (concatenate 'string sub "a.txt") "a")))
                                   :path (lambda (d)
                                           (%pathname-without-separator
                                            (%subfolder d "Photos [2026]"))))
    (let ((seen (%wait events (lambda (e) (%settled e "a.txt")))))
      (is (equal '((:settled "a.txt" 1)) seen) "~S" seen))))

#-win32
(test a-folder-given-as-a-pathname-whose-name-has-a-backslash-is-watched-by-that-name
  "As the test above, for w\\z given as a pathname on Linux and macOS, with wz beside it. Only
w\\z's file may be reported (#1112)."
  (with-watched-folder (dir events
                        :report-existing t
                        :setup (lambda (d)
                                 (let ((odd (%subfolder d (format nil "w~Cz" #\\))))
                                   (uv:make-directory odd :parents t)
                                   (uv:write-file (concatenate 'string odd "inside.txt") "in"))
                                 (%write d "wz/other.txt" "other"))
                        :path (lambda (d)
                                (%pathname-without-separator
                                 (%subfolder d (format nil "w~Cz" #\\)))))
    (let ((seen (%wait events (lambda (e) (%settled e "inside.txt")))))
      (sleep (* 2 +settle+))
      (setf seen (funcall events))
      (is (equal '((:settled "inside.txt" 2)) seen) "~S" seen))))

#-win32
(test a-folder-whose-name-has-a-backslash-is-watched-by-that-name
  "On Linux and macOS a string path with a backslash in a folder's name lost the backslash, so
w\z/ was watched as wz/. Both folders exist here, and only w\z's file may be reported."
  (with-watched-folder (dir events
                        :report-existing t
                        :setup (lambda (d)
                                 (let ((odd (%subfolder d (format nil "w~Cz" #\\))))
                                   (uv:make-directory odd :parents t)
                                   (uv:write-file (concatenate 'string odd "inside.txt") "in"))
                                 (%write d "wz/other.txt" "other"))
                        :path (lambda (d) (%subfolder d (format nil "w~Cz" #\\))))
    (let ((seen (%wait events (lambda (e) (%settled e "inside.txt")))))
      (sleep (* 2 +settle+))
      (setf seen (funcall events))
      (is (equal '((:settled "inside.txt" 2)) seen) "~S" seen))))

(test watching-a-folder-that-does-not-exist-signals-and-leaves-nothing-open
  "The hub's review of #1074: the timer made before the watch was left on the loop when the watch
failed, and with the handle freed too early in aion/uv, closing the loop aborted the process."
  (let ((dir (aion/fs:make-temporary-directory "folder-watch-test"))
        (loop (uv:make-loop)))
    (unwind-protect
         (progn
           (signals uv:file-not-found
             (fw:watch-folder loop (%subfolder dir "not-here")
                              (lambda (e) (declare (ignore e)))))
           ;; Open, not only active: the timer is made before the watch and not started, so a
           ;; leaked one is inactive but still open on the loop.
           (is (null (remove-if-not (lambda (h) (and (member (uv:handle-info-kind h)
                                                            '(:fs-event :timer))
                                                    (not (uv:handle-info-closing h))))
                                    (uv:loop-handles loop)))
               "no watch or timer left open: ~S" (uv:loop-handles loop))
           (let ((left-unfreed nil))
             (handler-bind ((uv:loop-left-unfreed
                              (lambda (w) (setf left-unfreed w) (muffle-warning w))))
               (uv:close-loop loop))
             (is (null left-unfreed) "the loop was left unfreed: ~A" left-unfreed)))
      (ignore-errors (uv:close-loop loop))
      (ignore-errors (aion/fs:delete-tree dir)))))

(test an-entry-that-can-never-be-statted-does-not-keep-the-timer-running
  "The hub's review of #1074: a link that loops (ELOOP) stayed :UNKNOWN and pending for good, so
the timer woke every SETTLE/4 seconds forever. It is now taken as missing. The stat of loop.txt is
made to fail with ELOOP."
  (let ((original fw::*%file-info*))
    (unwind-protect
         (progn
           (setf fw::*%file-info*
                 (lambda (path)
                   (if (search "loop.txt" path)
                       (error 'uv:uv-error :code -40 :name "ELOOP" :message "too many links"
                                           :operation :file-info :path path)
                       (funcall original path))))
           (with-watched-folder (dir events :report-existing t
                                            :setup (lambda (d) (%write d "loop.txt" "x")
                                                     (%write d "plain.txt" "plain")))
             (let ((watcher *watcher*))
               (%wait events (lambda (e) (%settled e "plain.txt")))
               (sleep (* 2 +settle+))
               (is (equal '((:settled "plain.txt" 5)) (funcall events)) "~S" (funcall events))
               (is (zerop (hash-table-count (fw::folder-watcher-pending watcher)))
                   "nothing left pending")
               (is-false (fw::folder-watcher-timer-running watcher) "the timer stopped"))))
      (setf fw::*%file-info* original))))

(test a-link-or-an-entry-of-unknown-kind-is-statted-by-a-scan
  "The hub's review of #1074: a scan acted only on files and folders, so a link, or an entry on a
filesystem that does not give the kind, was skipped by a scan but reported from a raw event. The
listing here gives link.txt as a link and odd.txt and odd/ as unknown."
  (let ((original fw::*%list-directory*))
    (unwind-protect
         (progn
           (setf fw::*%list-directory*
                 (lambda (path)
                   (mapcar (lambda (entry)
                             (cond ((string= (car entry) "link.txt") (cons (car entry) :symlink))
                                   ((member (car entry) '("odd.txt" "odd") :test #'string=)
                                    (cons (car entry) :unknown))
                                   (t entry)))
                           (funcall original path))))
           (with-watched-folder (dir events :report-existing t
                                            :setup (lambda (d) (%write d "link.txt" "l")
                                                     (%write d "odd.txt" "oo")
                                                     (%write d "odd/inner.txt" "iii")))
             (let ((seen (%wait events (lambda (e) (= 3 (length e))))))
               (sleep (* 2 +settle+))
               (setf seen (funcall events))
               (is (equal '((:settled "link.txt" 1) (:settled "odd.txt" 2)
                            (:settled "odd/inner.txt" 3))
                          (sort (copy-list seen) #'< :key #'third))
                   "~S" seen))))
      (setf fw::*%list-directory* original))))

;;; --- a file that cannot be read, and stopping --------------------------------------------

(test a-file-that-cannot-be-read-stays-pending-and-does-not-stop-the-others
  "The hub's review of #1074: a stat that fails with anything but not-found, such as a sharing
violation while a writer holds the file on Windows, escaped and stopped every later tick, so no
other file settled. The stat is made to fail for locked.txt for 1.5 s: free.txt settles in the
meantime, and locked.txt settles once it can be read."
  (let ((original fw::*%file-info*)
        ;; Locked until this is set, 1.5 s after the watch is running (the hub's review of #1074:
        ;; set before the setup, the window could be over before the test looked).
        (until nil))
    (unwind-protect
         (progn
           (setf fw::*%file-info*
                 (lambda (path)
                   (if (and (search "locked.txt" path)
                            (or (null until) (< (get-internal-real-time) until)))
                       (error 'uv:permission-denied :code -13 :name "EACCES"
                                                    :message "held by another program"
                                                    :operation :file-info :path path)
                       (funcall original path))))
           (with-watched-folder (dir events)
             (setf until (+ (get-internal-real-time) (* 1.5 internal-time-units-per-second)))
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
