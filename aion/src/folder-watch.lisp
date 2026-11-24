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
;;;; not changed for SETTLE seconds, and :REMOVED when a file that was reported :SETTLED has been
;;;; gone for that long. A file created and deleted before it settled is not reported at all. A
;;;; rename is :REMOVED for the old name and :SETTLED for the new one. Directories themselves are
;;;; not reported: a folder moved into the watched folder reports each file in it, and a folder
;;;; deleted or moved out reports :REMOVED for each reported file that was in it. A writer that
;;;; pauses for longer than SETTLE is reported when it pauses, and reported again when it
;;;; finishes, because nothing outside the writer can tell a pause from the end.
;;;;
;;;; HOW A FILE SETTLES. A raw event that names a file puts it in the pending table with its size
;;;; and modification time. A raw event that names a directory scans it and puts each file in the
;;;; table; one that names a path now missing also puts every reported file under that path in
;;;; the table. A raw event with no filename rescans the folder, and every file that differs from
;;;; what was last reported is put in the table. A repeating aion/uv timer stats each pending
;;;; file: a change, or a new raw event for it, starts its quiet period again, and a file quiet
;;;; for SETTLE seconds is reported. A file that cannot be read at the moment (a sharing
;;;; violation while a writer holds it on Windows, EACCES, EPERM) stays pending and its quiet
;;;; period starts again. The size and modification time of each reported file are remembered,
;;;; so the several raw events of one save, or an event for a file that did not change, report
;;;; nothing new. A missing file is treated the same way, so a save that writes a temporary file
;;;; and renames it over the target, which leaves the target missing for a moment, is one :SETTLED
;;;; and no :REMOVED. The timer stops when the table is empty.
;;;;
;;;; aion/uv's FILE-INFO gives the modification time in whole seconds. A file rewritten with the
;;;; same size within the same second as the stat that reported it is therefore not reported
;;;; again, unless a later change differs. With SETTLE of a second or more this cannot happen,
;;;; since a file is reported at least SETTLE seconds after its last change.
;;;;
;;;; NAMES AND CASE. On Windows and macOS, whose usual volumes ignore case, two names that differ
;;;; only in case are one file here, so renaming a.txt to A.txt reports nothing. A volume set up
;;;; to be case-sensitive there is still treated as ignoring case. On Linux case counts.
;;;;
;;;; THE IGNORE FILTER. Each pattern is a string, with * and ? as wildcards, matched without case
;;;; against each component of the file's path relative to the watched folder, or a function of
;;;; that relative path. A pattern that matches a directory therefore ignores everything under
;;;; it, and a scan does not descend into it. +SYNC-LITTER+ is the default list.
;;;;
;;;; NOT YET (#996's later steps). On Linux, inotify is not recursive and libuv watches only the
;;;; named folder, so changes inside subfolders are not seen there until step 2 adds a watch per
;;;; directory; a scan (REPORT-EXISTING, a folder moved in, or a raw event with no filename)
;;;; still descends. There is no polling fallback yet (step 3), and a placeholder file a sync
;;;; client has not downloaded is not told apart (step 4): FOLDER-EVENT-PLACEHOLDER is :UNKNOWN
;;;; for now.

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
  `(;; Dropbox: conflicted copies, named "name (Someone's conflicted copy 2026-11-01).ext", and
    ;; selective sync conflicts, "name (Selective Sync Conflict).ext"; its marker files, and the
    ;; cache that holds partial downloads.
    "* (*conflicted copy*" "* (Selective Sync Conflict*" ".dropbox" ".dropbox.attr"
    ".dropbox.cache"
    ;; OneDrive and Office: Office's owner file ~$name.docx, and temporary files.
    "~$*" "*.tmp"
    ;; Google Drive's staging folders.
    ".tmp.drivedownload" ".tmp.driveupload"
    ;; Partial browser downloads, which Proton Drive refuses to sync. Proton Drive documents no
    ;; temporary names of its own (#996's review of #1074).
    "*.crdownload" "*.download" "*.partial"
    ;; Editors: vim's swap files and its write probe 4913, Emacs backups, LibreOffice locks.
    "*.swp" "*.swx" "*~" "4913" ".~lock.*#"
    ;; The operating systems' own: macOS's folder and resource-fork files and a folder's custom
    ;; icon ("Icon" and a carriage return), and Windows's folder settings and thumbnails.
    ".DS_Store" "._*" ,(format nil "Icon~C" #\Return) "desktop.ini" "Thumbs.db")
  "The default ignore patterns: files that sync clients, editors and operating systems write
next to the files an app wants. See this file's header for how a pattern is matched.")

(defun glob-match-p (pattern name)
  "Whether NAME matches PATTERN, where * matches any run of characters (or none) and ? any one
character. Compared without case. The greedy match that remembers the last *, so the time is
at most the product of the two lengths, whatever the pattern."
  (let ((pn (length pattern)) (nn (length name))
        (p 0) (n 0) (star nil) (mark 0))
    (loop while (< n nn)
          do (cond ((and (< p pn) (char= (char pattern p) #\*))
                    (setf star p mark n)
                    (incf p))
                   ((and (< p pn) (or (char= (char pattern p) #\?)
                                      (char-equal (char pattern p) (char name n))))
                    (incf p) (incf n))
                   (star
                    (setf p (1+ star))
                    (incf mark)
                    (setf n mark))
                   (t (return-from glob-match-p nil))))
    (loop while (and (< p pn) (char= (char pattern p) #\*)) do (incf p))
    (= p pn)))

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

(defun %case-blind-p () (or (uiop:os-windows-p) (uiop:os-macosx-p)))

(defun %table ()
  "A table keyed by relative name: EQUALP, which ignores case, where names do (this file's
header)."
  (make-hash-table :test (if (%case-blind-p) #'equalp #'equal)))

(defstruct (folder-watcher (:constructor %make-folder-watcher))
  loop root function settle patterns recursive
  watcher timer
  (pending (%table))    ; name -> %pending
  (reported (%table))   ; name -> (size . mtime) last reported
  (unlisted (%table))   ; folder prefix -> T, while it cannot be listed
  (timer-running nil)
  (stopped nil))

(defstruct %pending
  state          ; (size . mtime), :missing or :unknown
  changed-at)    ; internal real time of the last change or raw event

(defconstant +unix-epoch+ (encode-universal-time 0 0 0 1 1 1970 0))

(defvar *%file-info* #'uv:file-info
  "The function %STATE stats a path with. For a test only, which sets it globally, since %STATE
runs on the loop thread, to make a stat fail as a file held open by another program does.")

(defun %separator () (if (uiop:os-windows-p) #\\ #\/))

(defun %native (fw name)
  (concatenate 'string (folder-watcher-root fw) (substitute (%separator) #\/ name)))

(defun %under-p (name prefix)
  "Whether NAME is under the folder PREFIX, which ends in /."
  (and (> (length name) (length prefix))
       (if (%case-blind-p)
           (string-equal prefix name :end2 (length prefix))
           (string= prefix name :end2 (length prefix)))))

(defun %state (fw name)
  "NAME's current (SIZE . MTIME), :MISSING, :DIRECTORY, or :UNKNOWN when it cannot be read now:
any other libuv error, such as a sharing violation or EACCES. :UNKNOWN keeps the file pending
rather than stopping the watcher (the hub's review of #1074)."
  (handler-case
      (let ((info (funcall *%file-info* (%native fw name))))
        (if (eq (uv:file-info-kind info) :file)
            (cons (uv:file-info-size info) (uv:file-info-mtime info))
            :directory))
    (uv:file-not-found () :missing)
    (uv:not-a-directory () :missing)
    ;; A link that loops, or a name too long, will not become readable by waiting, and as
    ;; :UNKNOWN it would keep the timer waking for good (the hub's review of #1074).
    (uv:uv-error (e)
      (if (member (uv:uv-error-name e) '("ELOOP" "ENAMETOOLONG") :test #'equal)
          :missing
          :unknown))))

(defun %now () (get-internal-real-time))

(defun %quiet-p (fw pending)
  (>= (- (%now) (%pending-changed-at pending))
      (* (folder-watcher-settle fw) internal-time-units-per-second)))

(defun %tick-ms (fw)
  (max 50 (round (* 1000 (folder-watcher-settle fw)) 4)))

(defun %ensure-timer (fw)
  "Start the timer unless it is running or the watch is stopped. WATCH-FOLDER makes the timer
before its first scan, so a file that scan puts in the pending table starts it."
  (when (and (folder-watcher-timer fw)
             (not (folder-watcher-timer-running fw))
             (not (folder-watcher-stopped fw)))
    (setf (folder-watcher-timer-running fw) t)
    (uv:start-timer (folder-watcher-timer fw) :after (%tick-ms fw) :every (%tick-ms fw))))

(defun %pend (fw name state)
  "Put NAME in the pending table with STATE, starting its quiet period again."
  (let ((pending (gethash name (folder-watcher-pending fw))))
    (if pending
        (setf (%pending-state pending) state
              (%pending-changed-at pending) (%now))
        (setf (gethash name (folder-watcher-pending fw))
              (make-%pending :state state :changed-at (%now)))))
  (%ensure-timer fw))

(defvar *%list-directory* #'uv:list-directory
  "The function %LIST lists a folder with. For a test only, which sets it globally, to make a
listing fail as an unreadable folder's does.")

(defun %list (fw prefix)
  "The entries of the folder PREFIX. A folder that has gone, or is no longer a folder, has none:
it changed while it was being looked at, and its own event follows. Any other failure, such as
EACCES on a subfolder, is not taken for an empty folder (Copilot's review of #1074), and is not
signalled either, which would let one unreadable folder stop the watch: the folder goes in the
pending table as :UNKNOWN, so each tick tries it again, and its files are reported once it can be
listed. The first failure for a folder is recorded with AION/UV:NOTE-CALLBACK-ERROR, once, so a
folder that stays unreadable is visible without one record per tick."
  (handler-case
      (prog1 (funcall *%list-directory* (%native fw prefix))
        (remhash prefix (folder-watcher-unlisted fw)))
    (uv:file-not-found () '())
    (uv:not-a-directory () '())
    (uv:uv-error (e)
      (unless (gethash prefix (folder-watcher-unlisted fw))
        (setf (gethash prefix (folder-watcher-unlisted fw)) t)
        (uv:note-callback-error e))
      (unless (string= prefix "")
        (%pend fw (subseq prefix 0 (1- (length prefix))) :unknown))
      '())))

(defun %scan (fw function &optional (prefix ""))
  "Call FUNCTION with the relative name of every regular file under the folder PREFIX (relative to
the watched folder, ending in /, or empty for the folder itself) that is not ignored, descending
into subfolders that are not ignored when the watch is recursive."
  (let ((entries (%list fw prefix)))
    (dolist (entry entries)
      (let ((name (concatenate 'string prefix (car entry))))
        (unless (ignored-p name (folder-watcher-patterns fw))
          (case (cdr entry)
            (:file (funcall function name))
            (:directory (when (folder-watcher-recursive fw)
                          (%scan fw function (concatenate 'string name "/"))))
            ;; A link, or an entry whose kind the filesystem did not give, is statted, as a raw
            ;; event's name is (the hub's review of #1074). A link to a folder is not followed,
            ;; because links can form a loop; a folder of unknown kind is.
            ((:symlink :unknown)
             (let ((state (%state fw name)))
               (cond ((eq state :directory)
                      (when (and (eq (cdr entry) :unknown) (folder-watcher-recursive fw))
                        (%scan fw function (concatenate 'string name "/"))))
                     ((eq state :missing))
                     (t (funcall function name)))))))))))

(defun %consider (fw name state)
  "Put NAME in the pending table with STATE, unless nothing has changed: it is pending already with
that state, or it is not pending and STATE is what was last reported. A scan of a folder, and a
rescan after an event with no filename, use this, so they do not restart the quiet period of a
file still settling or put back every unchanged file in a folder (Copilot's and the hub's
reviews of #1074)."
  (let ((pending (gethash name (folder-watcher-pending fw))))
    (unless (if pending
                (equal state (%pending-state pending))
                (equal state (gethash name (folder-watcher-reported fw))))
      (%pend fw name state))))

(defun %touch (fw name)
  "Note that NAME may have changed. A file goes in the pending table. A directory is scanned and
each file in it goes in the table, which is how a folder moved in is reported. A missing path
also puts in the table every reported file under it, which is how a folder deleted or moved out
reports :REMOVED for its files (the hub's review of #1074)."
  (let ((state (%state fw name)))
    (cond ((eq state :directory)
           (remhash name (folder-watcher-pending fw))
           ;; A watch that is not recursive does not look inside subfolders, as its first scan
           ;; does not (the hub's re-review of #1074).
           (when (folder-watcher-recursive fw)
             (%scan fw (lambda (file) (%consider fw file (%state fw file)))
                    (concatenate 'string name "/"))))
          (t
           (%pend fw name state)
           (when (eq state :missing)
             (let ((prefix (concatenate 'string name "/")))
               (maphash (lambda (reported value) (declare (ignore value))
                          (when (%under-p reported prefix) (%pend fw reported :missing)))
                        (folder-watcher-reported fw))))))))

(defun %emit (fw kind name &optional state)
  "Call the caller's function, unless the watch was stopped. An error it signals is recorded
as a callback error and costs only this event."
  (unless (folder-watcher-stopped fw)
    (handler-case
        (funcall (folder-watcher-function fw)
                 (make-folder-event :kind kind :path (%native fw name) :name name
                                    :size (and (consp state) (car state))
                                    :modified (and (consp state) (+ +unix-epoch+ (cdr state)))))
      (error (e) (uv:note-callback-error e)))))

(defun %tick (fw)
  "The timer's work: stat each pending file, and report each one that has been quiet for the
settle period. The table is brought up to date first, and the events are sent after, so an
error from the caller's function cannot leave the table half changed."
  (when (folder-watcher-stopped fw) (return-from %tick))
  (let ((pending (folder-watcher-pending fw))
        (reported (folder-watcher-reported fw))
        (done '()) (directories '()) (events '()))
    (maphash (lambda (name entry)
               (let ((state (%state fw name)))
                 (cond ((eq state :directory) (push name done) (push name directories))
                       ((eq state :unknown)
                        (setf (%pending-state entry) :unknown
                              (%pending-changed-at entry) (%now)))
                       ((not (equal state (%pending-state entry)))
                        (setf (%pending-state entry) state
                              (%pending-changed-at entry) (%now)))
                       ((%quiet-p fw entry)
                        (push name done)
                        (cond ((eq state :missing)
                               (when (nth-value 1 (gethash name reported))
                                 (remhash name reported)
                                 (push (list :removed name) events)))
                              ((not (equal state (gethash name reported)))
                               (setf (gethash name reported) state)
                               (push (list :settled name state) events)))))))
             pending)
    (dolist (name done) (remhash name pending))
    ;; A pending name that turned out to be a directory: scan it, as a raw event for it does.
    ;; %TOUCH does nothing more for it when the watch is not recursive.
    (dolist (name directories) (%touch fw name))
    (dolist (event (nreverse events))
      (apply #'%emit fw event))
    (when (and (zerop (hash-table-count pending))
               (folder-watcher-timer-running fw)
               (not (folder-watcher-stopped fw)))
      (setf (folder-watcher-timer-running fw) nil)
      (uv:stop-timer (folder-watcher-timer fw)))))



(defun %rescan (fw)
  "A raw event with no filename: something under the folder changed. Every file whose state
differs from what was last reported, and every reported file now missing, goes in the pending
table, without restarting the quiet period of one already there unchanged."
  (let ((seen (%table))
        (reported (folder-watcher-reported fw)))
    (%scan fw (lambda (name)
                (setf (gethash name seen) t)
                (%consider fw name (%state fw name))))
    (maphash (lambda (name state) (declare (ignore state))
               (unless (gethash name seen) (%consider fw name :missing)))
             reported)))

(defun %on-raw-event (fw events filename)
  (declare (ignore events))
  (unless (folder-watcher-stopped fw)
    (if (null filename)
        (%rescan fw)
        ;; Windows reports a file under a subfolder of a recursive watch with backslashes.
        ;; Elsewhere a backslash is an ordinary character in a name (Copilot's review of #1074).
        (let ((name (if (uiop:os-windows-p) (substitute #\/ #\\ filename) filename)))
          (unless (ignored-p name (folder-watcher-patterns fw))
            (%touch fw name))))))

(defun %root (path)
  "PATH as a native directory string ending in a separator. A string is used as written, and a
pathname is given its native name, both through AION/UV:NATIVE-PATH; a separator is added when
the name does not end in one. Neither goes through UIOP:ENSURE-DIRECTORY-PATHNAME. For a string
that parses it as a Lisp namestring, which dropped a backslash on Linux and macOS and took brackets
for a wildcard (the hub's review of #1074). For a pathname whose last folder is in its name, such
as one parsed from /tmp/Photos [2026] with no trailing separator, it takes that name from
FILE-NAMESTRING, which escapes the brackets, so another folder was watched (#1112)."
  (let ((native (uv:native-path path)))
    (if (and (plusp (length native))
             (let ((last (char native (1- (length native)))))
               (or (char= last #\/) (and (uiop:os-windows-p) (char= last #\\)))))
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
operating system can (macOS and Windows; see this file's header for Linux). A folder in it that
cannot be listed is tried again on each tick, and its files are reported once it can be. With
REPORT-EXISTING, every file already in the folder is reported once it is quiet for SETTLE
seconds; otherwise those files are only remembered, and reported when they change. A folder
that does not exist signals AION/UV:FILE-NOT-FOUND, and nothing is left on the loop.

The watch is started before the folder is first scanned, so a file created during the scan is
not missed. As with AION/UV:WATCH, call this before the loop thread runs or on the loop thread."
  (check-type settle (real (0)))
  (let ((fw (%make-folder-watcher :loop loop :root (%root path) :function function
                                  :settle settle :patterns (%patterns ignore)
                                  :recursive recursive)))
    (setf (folder-watcher-timer fw) (uv:make-timer loop (lambda (timer)
                                                          (declare (ignore timer))
                                                          (%tick fw))))
    ;; An error from the watch, such as a folder that does not exist, or from the first scan, such
    ;; as from an ignore function the caller gave, reaches the caller, who then has no watcher to
    ;; stop: what was made here is closed first, so a failed WATCH-FOLDER leaves nothing on the
    ;; loop (the hub's reviews of #1074).
    (handler-bind ((error (lambda (e) (declare (ignore e)) (stop-folder-watch fw))))
      (setf (folder-watcher-watcher fw)
            (uv:watch loop (folder-watcher-root fw)
                      (lambda (events filename watcher)
                        (declare (ignore watcher))
                        (%on-raw-event fw events filename))
                      ;; libuv honours :RECURSIVE on macOS and Windows only (aion/uv/watch.lisp).
                      :recursive (and recursive (or (uiop:os-macosx-p) (uiop:os-windows-p)))))
      (%scan fw (lambda (name)
                  (let ((state (%state fw name)))
                    (cond (report-existing (%pend fw name state))
                          ((consp state) (setf (gethash name (folder-watcher-reported fw)) state))
                          ;; Unreadable now: let it settle, and be reported, once it can be read.
                          ((eq state :unknown) (%pend fw name state)))))))
    fw))

(defun stop-folder-watch (fw)
  "Stop FW: no more events are reported, also when this is called from FW's own function, and its
watch and timer are closed. Call it on the loop thread, or after the loop thread has stopped."
  (unless (folder-watcher-stopped fw)
    (setf (folder-watcher-stopped fw) t
          (folder-watcher-timer-running fw) nil)
    (when (folder-watcher-watcher fw) (uv:close-handle (folder-watcher-watcher fw)))
    (when (folder-watcher-timer fw) (uv:close-handle (folder-watcher-timer fw))))
  fw)
