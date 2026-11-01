;;;; folder-watch.lisp --- watching a folder for files that have settled, over aion/uv (#996).
;;;;
;;;; aion/uv's WATCH reports what the operating system reports: one save can arrive as one to
;;;; three events, the filename can be NIL, and nothing says when a file has finished being
;;;; written. An app that imports files from a folder a sync client writes to (Dropbox, OneDrive,
;;;; Google Drive, Proton Drive) needs to know when a file is complete, and needs to skip the
;;;; temporary and conflict files those clients and editors leave. This system does both, so each
;;;; app does not write its own debouncer, and none of them reads a half-written file.
;;;;
;;;; WHAT A CALLER GETS. WATCH-FOLDER calls the caller's function, on the loop thread, with one
;;;; FOLDER-EVENT per change: :SETTLED when a file exists and its size and modification time have
;;;; not changed for SETTLE seconds, and :REMOVED when a file that was reported, or was waiting to
;;;; settle, has been gone for that long. A rename is :REMOVED for the old name and :SETTLED for
;;;; the new one. Directories are not reported.
;;;;
;;;; HOW A FILE SETTLES. A raw event that names a file puts it in the pending table with its size
;;;; and modification time. A raw event with no filename rescans the folder, and every file that
;;;; differs from what was last reported is put in the table. A repeating aion/uv timer stats
;;;; each pending file: a change, or a new raw event for it, starts its quiet period again, and a
;;;; file quiet for SETTLE seconds is reported. The size and modification time of each reported
;;;; file are remembered, so the several raw events of one save, or an event for a file that did
;;;; not change, report nothing new. A missing file is treated the same way, so a save that
;;;; writes a temporary file and renames it over the target, which leaves the target missing for
;;;; a moment, is one :SETTLED and no :REMOVED. The timer stops when the table is empty.
;;;;
;;;; aion/uv's FILE-INFO gives the modification time in whole seconds. A file rewritten with the
;;;; same size within the same second as the stat that reported it is therefore not reported
;;;; again, unless a later change differs. With SETTLE of a second or more this cannot happen,
;;;; since a file is reported at least SETTLE seconds after its last change.
;;;;
;;;; THE IGNORE FILTER. Each pattern is a string, with * and ? as wildcards, matched without case
;;;; against each component of the file's path relative to the watched folder, or a function of
;;;; that relative path. A pattern that matches a directory therefore ignores everything under
;;;; it, and a scan does not descend into it. +SYNC-LITTER+ is the default list.
;;;;
;;;; NOT YET (#996's later steps). On Linux, inotify is not recursive and libuv watches only the
;;;; named folder, so changes in subfolders are not seen there until step 2 adds a watch per
;;;; directory; a scan (REPORT-EXISTING, or a raw event with no filename) still descends. There
;;;; is no polling fallback yet (step 3), and a placeholder file a sync client has not downloaded
;;;; is not told apart (step 4): FOLDER-EVENT-PLACEHOLDER is :UNKNOWN for now.

(cl:defpackage #:aion/folder-watch
  (:use #:cl)
  (:local-nicknames (#:uv #:aion/uv))
  (:documentation "Watching a folder for files that have settled, with an ignore filter for the
files sync clients and editors leave behind (#996). Built on aion/uv's WATCH and timers.")
  (:export #:watch-folder #:stop-folder-watch #:folder-watcher
           #:folder-event #:folder-event-kind #:folder-event-path #:folder-event-name
           #:folder-event-size #:folder-event-modified #:folder-event-placeholder
           #:+sync-litter+ #:ignored-p #:glob-match-p))

(in-package #:aion/folder-watch)

;;; --- the ignore filter --------------------------------------------------------------------

(defparameter +sync-litter+
  '(;; Dropbox: a conflicted copy is named "name (Someone's conflicted copy 2026-11-01).ext", and
    ;; the cache holds partial downloads.
    "* (*conflicted copy*" ".dropbox.cache"
    ;; OneDrive and Office: Office's owner file ~$name.docx, and temporary files.
    "~$*" "*.tmp"
    ;; Google Drive's upload and download staging.
    ".driveupload" ".tmp.drivedownload"
    ;; Editors: vim's swap files and its write probe 4913, Emacs backups, LibreOffice locks.
    "*.swp" "*.swx" ".*.swp" "*~" "4913" ".~lock.*#"
    ;; The operating systems' own.
    ".DS_Store" "desktop.ini" "Thumbs.db")
  "The default ignore patterns: files that sync clients, editors and operating systems write
next to the files an app wants. See this file's header for how a pattern is matched.")

(defun glob-match-p (pattern name)
  "Whether NAME matches PATTERN, where * matches any run of characters (or none) and ? any one
character. Compared without case."
  (let ((pn (length pattern)) (nn (length name)))
    (labels ((match (p n)
               (cond ((= p pn) (= n nn))
                     ((char= (char pattern p) #\*)
                      (loop for k from n to nn thereis (match (1+ p) k)))
                     ((= n nn) nil)
                     ((or (char= (char pattern p) #\?) (char-equal (char pattern p) (char name n)))
                      (match (1+ p) (1+ n)))
                     (t nil))))
      (match 0 0))))

(defun %components (name)
  "NAME, a path relative to the watched folder with / between components, as a list."
  (loop with start = 0
        for slash = (position #\/ name :start start)
        collect (subseq name start slash)
        while slash do (setf start (1+ slash))))

(defun ignored-p (name patterns)
  "Whether NAME, a path relative to the watched folder with / between components, is ignored by
PATTERNS: a string pattern that matches any one of its components, or a function pattern that
returns true for NAME."
  (let ((parts (%components name)))
    (some (lambda (pattern)
            (if (functionp pattern)
                (funcall pattern name)
                (some (lambda (part) (glob-match-p pattern part)) parts)))
          patterns)))

(defun %patterns (ignore)
  "IGNORE as a list of patterns: :DEFAULTS is +SYNC-LITTER+, and :DEFAULTS inside a list adds it."
  (cond ((eq ignore :defaults) +sync-litter+)
        ((listp ignore)
         (loop for p in ignore
               if (eq p :defaults) append +sync-litter+
               else if (or (stringp p) (functionp p)) collect p
               else do (error "aion/folder-watch: an ignore pattern is a string or a function, not ~S" p)))
        (t (error "aion/folder-watch: IGNORE is :DEFAULTS or a list of patterns, not ~S" ignore))))

;;; --- events and the watcher ---------------------------------------------------------------

(defstruct folder-event
  "One change WATCH-FOLDER reports. KIND is :SETTLED or :REMOVED. PATH is the file's native
path, and NAME the path relative to the watched folder with / between components. SIZE and
MODIFIED (a universal time) come from the stat that settled the file, and are NIL for :REMOVED.
PLACEHOLDER is :UNKNOWN until #996's step 4."
  kind path name size modified (placeholder :unknown))

(defstruct (folder-watcher (:constructor %make-folder-watcher))
  loop root function settle patterns recursive
  watcher timer
  (pending (make-hash-table :test #'equal))   ; name -> %pending
  (reported (make-hash-table :test #'equal))  ; name -> (size . mtime) last reported
  (timer-running nil)
  (stopped nil))

(defstruct %pending
  state          ; (size . mtime), or :missing
  changed-at)    ; internal real time of the last change or raw event

(defconstant +unix-epoch+ (encode-universal-time 0 0 0 1 1 1970 0))

(defun %separator () (if (uiop:os-windows-p) #\\ #\/))

(defun %native (fw name)
  (concatenate 'string (folder-watcher-root fw) (substitute (%separator) #\/ name)))

(defun %state (fw name)
  "NAME's current (SIZE . MTIME), :MISSING, or :DIRECTORY."
  (handler-case
      (let ((info (uv:file-info (%native fw name))))
        (if (eq (uv:file-info-kind info) :file)
            (cons (uv:file-info-size info) (uv:file-info-mtime info))
            :directory))
    (uv:file-not-found () :missing)
    (uv:not-a-directory () :missing)))

(defun %now () (get-internal-real-time))

(defun %quiet-p (fw pending)
  (>= (- (%now) (%pending-changed-at pending))
      (* (folder-watcher-settle fw) internal-time-units-per-second)))

(defun %tick-ms (fw)
  (max 50 (round (* 1000 (folder-watcher-settle fw)) 4)))

(defun %ensure-timer (fw)
  "Start the timer unless it is running. Before WATCH-FOLDER has made it, do nothing: WATCH-FOLDER
starts it after its first scan when that scan left files pending."
  (when (and (folder-watcher-timer fw) (not (folder-watcher-timer-running fw)))
    (setf (folder-watcher-timer-running fw) t)
    (uv:start-timer (folder-watcher-timer fw) :after (%tick-ms fw) :every (%tick-ms fw))))

(defun %touch (fw name)
  "Note that NAME may have changed: put it in the pending table with its current state, and
start its quiet period again."
  (let ((state (%state fw name)))
    (unless (eq state :directory)
      (let ((pending (gethash name (folder-watcher-pending fw))))
        (if pending
            (setf (%pending-state pending) state
                  (%pending-changed-at pending) (%now))
            (setf (gethash name (folder-watcher-pending fw))
                  (make-%pending :state state :changed-at (%now)))))
      (%ensure-timer fw))))

(defun %emit (fw kind name &optional state)
  (funcall (folder-watcher-function fw)
           (make-folder-event :kind kind :path (%native fw name) :name name
                              :size (and (consp state) (car state))
                              :modified (and (consp state) (+ +unix-epoch+ (cdr state))))))

(defun %tick (fw)
  "The timer's work: stat each pending file, and report each one that has been quiet for the
settle period."
  (let ((pending (folder-watcher-pending fw))
        (reported (folder-watcher-reported fw))
        (done '()))
    (when (folder-watcher-stopped fw) (return-from %tick))
    (maphash (lambda (name entry)
               (let ((state (%state fw name)))
                 (cond ((eq state :directory) (push name done))
                       ((not (equal state (%pending-state entry)))
                        (setf (%pending-state entry) state
                              (%pending-changed-at entry) (%now)))
                       ((%quiet-p fw entry)
                        (push name done)
                        (cond ((eq state :missing)
                               (when (nth-value 1 (gethash name reported))
                                 (remhash name reported)
                                 (%emit fw :removed name)))
                              ((not (equal state (gethash name reported)))
                               (setf (gethash name reported) state)
                               (%emit fw :settled name state)))))))
             pending)
    (dolist (name done) (remhash name pending))
    (when (and (zerop (hash-table-count pending)) (folder-watcher-timer-running fw))
      (setf (folder-watcher-timer-running fw) nil)
      (uv:stop-timer (folder-watcher-timer fw)))))

(defun %scan (fw function &optional (prefix ""))
  "Call FUNCTION with the relative name of every regular file under the watched folder that is
not ignored, descending into subfolders that are not ignored when the watch is recursive."
  (let ((entries (handler-case (uv:list-directory (%native fw prefix))
                   (uv:uv-error () '()))))
    (dolist (entry entries)
      (let ((name (concatenate 'string prefix (car entry))))
        (unless (ignored-p name (folder-watcher-patterns fw))
          (case (cdr entry)
            (:file (funcall function name))
            (:directory (when (folder-watcher-recursive fw)
                          (%scan fw function (concatenate 'string name "/"))))))))))

(defun %rescan (fw)
  "A raw event with no filename: something under the folder changed. Every file whose state
differs from what was last reported, and every reported file now missing, is touched."
  (let ((seen (make-hash-table :test #'equal)))
    (%scan fw (lambda (name)
                (setf (gethash name seen) t)
                (unless (equal (%state fw name) (gethash name (folder-watcher-reported fw)))
                  (%touch fw name))))
    (maphash (lambda (name state) (declare (ignore state))
               (unless (gethash name seen) (%touch fw name)))
             (folder-watcher-reported fw))))

(defun %on-raw-event (fw events filename)
  (declare (ignore events))
  (unless (folder-watcher-stopped fw)
    (if (null filename)
        (%rescan fw)
        ;; Windows reports a file under a subfolder of a recursive watch with backslashes.
        (let ((name (substitute #\/ #\\ filename)))
          (unless (ignored-p name (folder-watcher-patterns fw))
            (%touch fw name))))))

(defun %root (path)
  "PATH as a native directory string ending in a separator."
  (let ((native (uiop:native-namestring (uiop:ensure-directory-pathname path))))
    (if (find (char native (1- (length native))) "/\\")
        native
        (concatenate 'string native (string (%separator))))))

(defun watch-folder (loop path function &key (recursive t) (settle 1.5) (ignore :defaults)
                                              report-existing)
  "Watch the folder PATH on LOOP and call FUNCTION, on the loop thread, with a FOLDER-EVENT for
each file that settles or is removed; see this file's header. Returns a FOLDER-WATCHER for
STOP-FOLDER-WATCH.

SETTLE is the number of seconds a file's size and modification time must stay the same before
it is reported. IGNORE is :DEFAULTS (+SYNC-LITTER+) or a list of patterns, strings or functions
of the relative name, which may include :DEFAULTS. RECURSIVE watches subfolders too, where the
operating system can (macOS and Windows; see this file's header for Linux). With REPORT-EXISTING,
every file already in the folder is reported once it is quiet for SETTLE seconds; otherwise
those files are only remembered, and reported when they change.

As with AION/UV:WATCH, call this before the loop thread runs or on the loop thread."
  (check-type settle (real (0)))
  (let* ((fw (%make-folder-watcher :loop loop :root (%root path) :function function
                                   :settle settle :patterns (%patterns ignore)
                                   :recursive recursive)))
    (%scan fw (lambda (name)
                (if report-existing
                    (%touch fw name)
                    (let ((state (%state fw name)))
                      (when (consp state)
                        (setf (gethash name (folder-watcher-reported fw)) state))))))
    (setf (folder-watcher-timer fw) (uv:make-timer loop (lambda (timer)
                                                          (declare (ignore timer))
                                                          (%tick fw))))
    ;; REPORT-EXISTING's scan filled the table before the timer existed.
    (when (plusp (hash-table-count (folder-watcher-pending fw)))
      (%ensure-timer fw))
    (setf (folder-watcher-watcher fw)
          (uv:watch loop (folder-watcher-root fw)
                    (lambda (events filename watcher)
                      (declare (ignore watcher))
                      (%on-raw-event fw events filename))
                    ;; libuv honours :RECURSIVE on macOS and Windows only (aion/uv/watch.lisp).
                    :recursive (and recursive (or (uiop:os-macosx-p) (uiop:os-windows-p)))))
    fw))

(defun stop-folder-watch (fw)
  "Stop FW: no more events are reported, and its watch and timer are closed. Call it on the loop
thread, or after the loop thread has stopped."
  (unless (folder-watcher-stopped fw)
    (setf (folder-watcher-stopped fw) t)
    (when (folder-watcher-watcher fw) (uv:close-handle (folder-watcher-watcher fw)))
    (when (folder-watcher-timer fw) (uv:close-handle (folder-watcher-timer fw))))
  fw)
