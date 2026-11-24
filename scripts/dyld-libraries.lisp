;;;; dyld-libraries.lisp --- which libraries a macOS process really had loaded, read from the
;;;; output of DYLD_PRINT_LIBRARIES (#783).
;;;;
;;;; scripts/verify-bundle-macos.sh runs an app with DYLD_PRINT_LIBRARIES=1 and judges where its
;;;; libraries came from. dyld prints one line for each image it maps, of the form
;;;;
;;;;     dyld[PID]: <UUID> PATH
;;;;
;;;; and, on current macOS, a line of the form
;;;;
;;;;     dyld[PID]: move loaded to delayed: NAME
;;;;     dyld[PID]: move delayed to loaded: NAME
;;;;
;;;; when it moves a library from the shared cache out of, or back into, use. NAME is the file
;;;; name of the image's path. A process that never uses Apple's /usr/lib/libssl.48.dylib still
;;;; gets a PATH line for it, followed by `move loaded to delayed'; a process that does use it,
;;;; directly or through a system framework such as WebKit, gets `move delayed to loaded' after
;;;; that. Measured on macOS 26.6 (#783) with a C program that only called dlopen. So whether a
;;;; library was in use is its LAST state, and a check that matches PATH lines alone reports a
;;;; library the process never used. That is what verify-bundle-macos.sh reported on #781.
;;;;
;;;; A move names only a file name, and two images in one process can share it: a bundle's own
;;;; libsqlite3.dylib and Apple's /usr/lib/libsqlite3.dylib (#899). A move applies to the image
;;;; with that name that is in the state it moves FROM, which is the only one it can apply to.
;;;; Measured on macOS 26.6 with the same C program: dlopen of the bundle's copy printed its PATH
;;;; line and no move; dlopen of /usr/lib/libsqlite3.dylib after it printed `move delayed to
;;;; loaded: libsqlite3.dylib', which is the cache copy's.
;;;;
;;;; THE PROCESS. The first PATH line a process prints is its main executable. A launcher that
;;;; execs another program keeps its PID, and dyld then prints a new list, starting with the new
;;;; executable. So a PATH line that names neither a .dylib nor anything under /usr/lib/ or
;;;; /System/ starts a new process under the same PID. The images that follow belong to it.
;;;;
;;;; APPLE'S OPENSSL AND SECURITY.FRAMEWORK (#905). On macOS, aion/http-client checks a server's
;;;; certificate with Security.framework. Opening it maps, among Apple's own libraries, its
;;;; libcurl's /usr/lib/libssl.48.dylib and /usr/lib/libcrypto.46.dylib, and the system's
;;;; /usr/lib/libsqlite3.dylib. Measured on Darwin 27.2 with praxeon/examples/sqlite-probe run
;;;; with --https. Apple's OpenSSL is on every Mac, so a bundle does not depend on the build
;;;; machine for it, and the rule below accepts exactly /usr/lib/libssl.*.dylib and
;;;; /usr/lib/libcrypto.*.dylib in any process; a CL+SSL package in the image is checked
;;;; separately. Apple's libsqlite3 is WAIVED, not accepted: aion/darwin opens Security with
;;;; RTLD_LOCAL, so its libsqlite3 does not take part in a global symbol lookup, but the dyld log
;;;; cannot show how an image was opened. So the waiver applies only to /usr/lib/<the carried
;;;; file name>, only in a process that also has Security.framework loaded, and it is printed on
;;;; every run as a WAIVED line. What the waiver gives up is checked from the app's own report
;;;; instead: REPORTED-LIBRARY-FINDINGS reads the `SQLITE-LIBRARY: <version> <path>' line that
;;;; the sqlite-probe prints, the path of the library whose sqlite3_open the image calls.
;;;;
;;;; scripts/check-dyld-log.lisp is the command-line half, which verify-bundle-macos.sh runs.

(defpackage #:ouranos-dyld-libraries
  (:use #:cl)
  (:export #:parse-dyld-log #:loaded-images #:image-pid #:image-process #:image-path
           #:image-state #:openssl-findings #:carried-findings #:reported-library-findings))

(in-package #:ouranos-dyld-libraries)

(defstruct (image (:constructor %make-image (pid process path state)))
  "One image a process mapped: its PID, its process's executable name, its path, and its
last state, :LOADED or :DELAYED."
  pid process path state)

(defun %file-name (path)
  "The part of PATH after its last slash."
  (subseq path (1+ (or (position #\/ path :from-end t) -1))))

(defun %main-executable-p (path)
  "Whether PATH, from a PATH line, starts a new process: it is not a .dylib, not under
/usr/lib/ or /System/, and not inside a .framework."
  (not (or (let ((n (length path))) (and (> n 6) (string= ".dylib" path :start2 (- n 6))))
           (eql 0 (search "/usr/lib/" path))
           (eql 0 (search "/System/" path))
           (search ".framework/" path))))

(defun %dyld-line (line)
  "LINE split into its PID and the text after `dyld[PID]: ', or NIL when it is not a dyld
line. The prefix may be preceded by other output on the same line."
  (let* ((start (search "dyld[" line))
         (close (and start (position #\] line :start start))))
    (when (and close
               (< (1+ close) (length line))
               (string= "]: " line :start2 close :end2 (min (length line) (+ close 3))))
      (let ((pid (ignore-errors (parse-integer line :start (+ start 5) :end close))))
        (when pid (values pid (subseq line (+ close 3))))))))

(defun parse-dyld-log (text)
  "The images in TEXT, the output of a run with DYLD_PRINT_LIBRARIES=1, as a list of IMAGE in
the order dyld first printed them, each with its last state. Lines that are not dyld's are
ignored, so the app's own output may be mixed in."
  (let ((images '())
        (current (make-hash-table)))   ; pid -> process name
    (with-input-from-string (in text)
      (loop for line = (read-line in nil)
            while line
            do (multiple-value-bind (pid rest) (%dyld-line (string-right-trim '(#\Return) line))
                 (when pid
                   (cond
                     ;; <UUID> PATH
                     ((and (plusp (length rest)) (char= #\< (char rest 0)))
                      (let* ((gt (position #\> rest))
                             (path (and gt (string-left-trim " " (subseq rest (1+ gt))))))
                        (when (and path (plusp (length path)))
                          (when (or (null (gethash pid current)) (%main-executable-p path))
                            (setf (gethash pid current) (%file-name path)))
                          (push (%make-image pid (gethash pid current) path :loaded) images))))
                     ;; move loaded to delayed: NAME / move delayed to loaded: NAME
                     ((eql 0 (search "move " rest))
                      (let* ((colon (position #\: rest))
                             (name (and colon (string-trim " " (subseq rest (1+ colon)))))
                             (state (cond ((search "to delayed" rest) :delayed)
                                          ((search "to loaded" rest) :loaded))))
                        (when (and name state)
                          (let* ((process (gethash pid current))
                                 (from (if (eq state :loaded) :delayed :loaded))
                                 (image (find-if (lambda (i)
                                                   (and (eql pid (image-pid i))
                                                        (equal process (image-process i))
                                                        (eq from (image-state i))
                                                        (string= name (%file-name (image-path i)))))
                                                 images)))
                            (when image (setf (image-state image) state)))))))))))
    (nreverse images)))

(defun loaded-images (images)
  "The images in IMAGES whose last state is :LOADED."
  (remove :delayed images :key #'image-state))

(defun %openssl-p (path)
  "Whether PATH names a libssl or libcrypto."
  (let ((name (%file-name path)))
    (or (eql 0 (search "libssl." name)) (eql 0 (search "libcrypto." name)))))

(defun %inside-p (path directory)
  "Whether PATH is in DIRECTORY, a path without a trailing slash."
  (let ((dir (string-right-trim "/" directory)))
    (and (> (length path) (1+ (length dir)))
         (string= dir path :end2 (length dir))
         (char= #\/ (char path (length dir))))))

(defun %apples-openssl-p (path)
  "Whether PATH is exactly /usr/lib/libssl.*.dylib or /usr/lib/libcrypto.*.dylib: Apple's own
copy, directly in /usr/lib, not in a directory below it."
  (and (%inside-p path "/usr/lib")
       (not (find #\/ path :start (length "/usr/lib/")))
       (%openssl-p path)
       (let ((name (%file-name path)))
         (string= ".dylib" name :start2 (max 0 (- (length name) 6))))))

(defun openssl-findings (images bundle-directory)
  "A list of (VERDICT PROCESS PID PATH), one for each loaded libssl or libcrypto in IMAGES.
VERDICT is :CARRIED when PATH is in BUNDLE-DIRECTORY; :WEBKIT when the process is
hyperion-view and PATH is under /usr/lib/, because WebKit loads Apple's own copy through
Apple's libcurl and the app has no say in it; :APPLE when PATH is exactly
/usr/lib/libssl.*.dylib or /usr/lib/libcrypto.*.dylib in any other process, Apple's own copy,
which every Mac has and which Security.framework loads (#905); :FAIL otherwise, which is a copy
from outside the bundle that is not Apple's, such as Homebrew's that cl+ssl opens."
  (loop for image in (loaded-images images)
        for path = (image-path image)
        when (%openssl-p path)
          collect (list (cond ((%inside-p path bundle-directory) :carried)
                              ((and (eql 0 (search "hyperion-view" (image-process image)))
                                    (eql 0 (search "/usr/lib/" path)))
                               :webkit)
                              ((%apples-openssl-p path) :apple)
                              (t :fail))
                        (image-process image) (image-pid image) path)))

(defun %security-framework-loaded-p (images pid process)
  "Whether Security.framework is loaded in the process PROCESS with PID."
  (find-if (lambda (i)
             (and (eql pid (image-pid i))
                  (string= process (image-process i))
                  (eql 0 (search "/System/Library/Frameworks/Security.framework/"
                                 (image-path i)))))
           (loaded-images images)))

(defun carried-findings (images bundle-directory file-name)
  "A list of (VERDICT PROCESS PID PATH), one for each loaded image in IMAGES whose file name is
FILE-NAME, a library the bundle carries. VERDICT is :CARRIED when PATH is in BUNDLE-DIRECTORY;
:WEBKIT when the process is hyperion-view and PATH is under /usr/lib/, as for OPENSSL-FINDINGS;
:SECURITY-FRAMEWORK, a waiver that is printed, when PATH is exactly /usr/lib/FILE-NAME and
Security.framework is loaded in the same process (#905, see the top of this file); :FAIL
otherwise.

A :FAIL beside a :CARRIED is the case this exists for (#899). cl-sqlite's functions are looked
up globally, and a global lookup returns the first library loaded that has the symbol, so an
app process that loaded Apple's libsqlite3 before the bundle's copy may run on Apple's
although the bundle's copy was loaded too."
  (loop for image in (loaded-images images)
        for path = (image-path image)
        when (string= file-name (%file-name path))
          collect (list (cond ((%inside-p path bundle-directory) :carried)
                              ((and (eql 0 (search "hyperion-view" (image-process image)))
                                    (eql 0 (search "/usr/lib/" path)))
                               :webkit)
                              ((and (string= path (concatenate 'string "/usr/lib/" file-name))
                                    (%security-framework-loaded-p images (image-pid image)
                                                                  (image-process image)))
                               :security-framework)
                              (t :fail))
                        (image-process image) (image-pid image) path)))

(defun reported-library-findings (text bundle-directory)
  "A list of (VERDICT VERSION PATH), one for each `SQLITE-LIBRARY: <version> <path>' line in
TEXT, the line praxeon/examples/sqlite-probe prints for the library its image calls (#905).
VERDICT is :CARRIED when PATH is in BUNDLE-DIRECTORY and :FAIL otherwise. The prefix is
matched at the start of a line, after any spaces."
  (with-input-from-string (in text)
    (loop for line = (read-line in nil)
          while line
          for tr = (string-left-trim '(#\Space #\Tab) (string-right-trim '(#\Return) line))
          when (eql 0 (search "SQLITE-LIBRARY: " tr))
            collect (let* ((rest (subseq tr (length "SQLITE-LIBRARY: ")))
                           (space (position #\Space rest))
                           (version (subseq rest 0 space))
                           (path (if space (subseq rest (1+ space)) "")))
                      (list (if (%inside-p path bundle-directory) :carried :fail)
                            version path)))))
