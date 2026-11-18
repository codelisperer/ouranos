;;;; launch.lisp --- finding a browser, its command line, and its process (#1028).
;;;;
;;;; The browser is started headless, with a fresh profile in a temporary directory, and is
;;;; reached in one of two ways (dokimasia ADR-0001, step (c)):
;;;;
;;;; - :PIPE, the default: --remote-debugging-pipe. The browser gets two pipes as its descriptors
;;;;   3 and 4, and no debugging port is opened, so no other local process can reach it. On Linux
;;;;   and macOS it is started through aion/uv/process. On Windows it is started by
;;;;   aion/windows:spawn-in-job, which passes the pipes as C runtime descriptors and keeps the
;;;;   browser in its kill-on-close job from before it runs.
;;;; - :PORT: --remote-debugging-port=0, so the operating system picks a free port. The browser
;;;;   writes the port and its WebSocket path into DevToolsActivePort in the profile, and
;;;;   LAUNCH-BROWSER reads them from there. Two runs on one machine cannot race for a port.
;;;;
;;;; The process cannot outlive a crashed image: on Windows it runs in a kill-on-close job
;;;; object, and on Linux it is started through `setpriv --pdeathsig KILL' when setpriv is
;;;; installed, as hyperion/sidecar does. macOS has neither; CLOSE-BROWSER and WITH-BROWSER end
;;;; it there.

(cl:in-package #:aion/cdp)

(defvar *default-timeout* 30
  "Seconds a command, a wait or a browser's start may take when no :TIMEOUT is given.")

;;; --- finding a browser ---------------------------------------------------------

(defparameter +browser-names-on-path+
  '("google-chrome" "google-chrome-stable" "chromium" "chromium-browser" "microsoft-edge"
    #+win32 "chrome" #+win32 "msedge")
  "The executable names FIND-BROWSER looks for in PATH, in order.")

(defparameter +browser-install-locations+
  '(#+darwin "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    #+darwin "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
    #+win32 "C:/Program Files/Google/Chrome/Application/chrome.exe"
    #+win32 "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe"
    #+win32 "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
    #+win32 "C:/Program Files/Microsoft/Edge/Application/msedge.exe")
  "Where Chrome and Edge are installed when they are not on PATH, checked in order.")

(defun %on-path (name)
  "The native name of the first file called NAME in a directory on PATH, or NIL."
  #+win32 (aion/windows:find-executable name)
  #-win32
  (dolist (dir (uiop:split-string (or (uiop:getenv "PATH") "") :separator ":"))
    (when (plusp (length dir))
      (let ((p (probe-file (uiop:parse-native-namestring
                            (concatenate 'string (string-right-trim "/" dir) "/" name)))))
        (when (and p (pathname-name p))
          (return (uiop:native-namestring p)))))))

(defun find-browser ()
  "The browser executable to run, as a native name, or NIL when there is none.

OURANOS_BROWSER is used first and HYPERION_SMOKE_BROWSER second, when either is set and not
empty; the name is returned as it is, and LAUNCH-BROWSER signals BROWSER-NOT-FOUND if it does
not exist. Otherwise the names in +BROWSER-NAMES-ON-PATH+ are looked for in PATH, and then
the install locations in +BROWSER-INSTALL-LOCATIONS+."
  (flet ((env (name)
           (let ((v (uiop:getenv name))) (and v (plusp (length v)) v))))
    (or (env "OURANOS_BROWSER")
        (env "HYPERION_SMOKE_BROWSER")
        (some #'%on-path +browser-names-on-path+)
        (let ((found (some (lambda (p) (probe-file (uiop:parse-native-namestring p)))
                           +browser-install-locations+)))
          (and found (uiop:native-namestring found))))))

;;; --- the command line ------------------------------------------------------------

(defparameter +refused-switches+
  '("headless" "remote-debugging-" "user-data-dir" "profile-directory" "password-store")
  "Prefixes of the switch names an extra argument to LAUNCH-BROWSER may not have: they would
change the headless mode, the debugging port or pipe, the profile, or which credential store
the browser opens.")

(defparameter +keychain-switches+
  '(#+darwin "--use-mock-keychain"
    #+linux "--password-store=basic")
  "Switches that keep the browser out of the operating system's credential store. Chrome reads
its Safe Storage key from the macOS Keychain even when headless, and on a new profile that can
show a Keychain permission dialog; on Linux it can ask the desktop keyring to unlock. A mock
Keychain on macOS and the basic password store on Linux open no dialog.")

(defun %switch-name (argument)
  "The name of the switch ARGUMENT sets, lowercased and without its value, or NIL when ARGUMENT
is not a switch. Chromium reads a switch after --, after -, and on Windows after / too."
  (let ((start (cond ((and (>= (length argument) 2) (string= "--" argument :end2 2)) 2)
                     ((and (plusp (length argument))
                           (or (char= (char argument 0) #\-)
                               #+win32 (char= (char argument 0) #\/)))
                      1))))
    (and start
         (string-downcase (subseq argument start (position #\= argument :start start))))))

(defun check-browser-arguments (arguments)
  "Signal an error unless ARGUMENTS, the extra arguments given to LAUNCH-BROWSER, is a list of
strings none of which sets the headless mode, the remote-debugging port or pipe, the profile
directory or the profile, or the password store, or is the -- that ends Chromium's
switches. Returns ARGUMENTS."
  (unless (and (listp arguments) (every #'stringp arguments))
    (error "Browser arguments are a list of strings; got ~S." arguments))
  (dolist (argument arguments arguments)
    (let ((name (%switch-name argument)))
      (when (equal argument "--")
        (error "The browser argument -- is refused: switches after it are not checked."))
      (when (and name (some (lambda (prefix)
                              (and (>= (length name) (length prefix))
                                   (string= prefix name :end2 (length prefix))))
                            +refused-switches+))
        (error "The browser argument ~S is refused: aion/cdp sets the headless mode, the debugging connection and the profile itself, and no argument may change them."
               argument)))))

(defun fixed-browser-switches ()
  "The switches every start of Chrome or Edge in this tree passes, whatever starts it: no
first-run page, no default-browser check, and +KEYCHAIN-SWITCHES+, so the browser opens no
credential-store dialog on the machine it runs on. BROWSER-COMMAND-LINE uses it, and so do the
tests that run a browser themselves, so a switch added here reaches every launch site."
  (append (list "--no-first-run" "--no-default-browser-check") +keychain-switches+))

(defparameter +default-transport+ :pipe
  "The transport LAUNCH-BROWSER uses when it is given none: :PIPE, on Linux, macOS and Windows.")

(defun browser-command-line (executable profile &key arguments (transport +default-transport+))
  "The command line LAUNCH-BROWSER runs, as a list of strings starting with EXECUTABLE. It
includes FIXED-BROWSER-SWITCHES, so the browser opens no credential-store dialog. TRANSPORT is
:PIPE for --remote-debugging-pipe or :PORT for --remote-debugging-port=0.

PROFILE is the profile directory, as a native name. ARGUMENTS are the caller's extra arguments,
checked by CHECK-BROWSER-ARGUMENTS. They come before the switches this function sets, because
when Chromium is given a switch twice the last one counts."
  (check-browser-arguments arguments)
  (append (list executable)
          arguments
          (list "--headless=new"
                (ecase transport
                  (:pipe "--remote-debugging-pipe")
                  (:port "--remote-debugging-port=0"))
                (concatenate 'string "--user-data-dir=" profile))
          (fixed-browser-switches)
          (list "about:blank")))

;;; --- the process ------------------------------------------------------------------

(defvar *setpriv* :unknown
  "The native name of setpriv on Linux, NIL when it is not installed or not Linux, :UNKNOWN
until first looked for.")

(defun %setpriv ()
  (when (eq *setpriv* :unknown)
    (setf *setpriv* (and (string-equal (software-type) "Linux") (%on-path "setpriv")))
    (when (and (string-equal (software-type) "Linux") (null *setpriv*))
      (log:warn "aion/cdp: setpriv is not installed, so a browser can outlive an image that is killed")))
  *setpriv*)

(defun %spawn (command-line stderr-file)
  "Start COMMAND-LINE with standard input and output discarded and standard error appended to
STDERR-FILE. Returns the platform's process object."
  #+win32
  (aion/windows:spawn-in-job (first command-line) (rest command-line)
                             :input nil :output nil
                             :error (uiop:native-namestring stderr-file)
                             :if-no-job :error)
  #-win32
  (let* ((setpriv (%setpriv))
         (line (if setpriv
                   (list* setpriv "--pdeathsig" "KILL" "--" command-line)
                   command-line)))
    (sb-ext:run-program (first line) (rest line)
                        :wait nil :input nil :output nil
                        :error stderr-file :if-error-exists :append)))

#-win32
(defstruct (piped-process (:constructor %make-piped-process (process loop)))
  "A browser started for the pipe transport: its aion/uv/process PROCESS, and the event LOOP,
with its own thread, that started it and reports its exit."
  process loop)

#-win32
(defun %pipe-pair ()
  "A new pipe, as its read and write descriptors, both closed on exec, so a process this image
starts later does not inherit them. The browser gets its ends through uv_spawn, which makes the
copy it hands the child without that flag."
  (multiple-value-bind (read write) (sb-posix:pipe)
    (dolist (fd (list read write))
      (sb-posix:fcntl fd sb-posix:f-setfd 1))   ; FD_CLOEXEC is 1 on Linux and macOS
    (values read write)))

#+win32
(defun %pipe-pair ()
  "A new pipe, as its read and write handles. SB-UNIX:UNIX-PIPE calls CreatePipe with no security
attributes, so neither handle is inheritable, and a process this image starts later does not get
them. SPAWN-IN-JOB makes the browser's ends inheritable for its own call only."
  (sb-unix:unix-pipe))

#+win32
(defun %spawn-piped (command-line stderr-file)
  "Start COMMAND-LINE, which has --remote-debugging-pipe, in a kill-on-close job with standard
input and output discarded, standard error appended to STDERR-FILE, and two new pipes as its C
runtime descriptors 3 and 4. Returns the JOB-PROCESS, the handle to write commands to, and the one
to read answers from."
  (let ((handles '()) (spawned nil))
    (unwind-protect
         (multiple-value-bind (child-read our-write) (%pipe-pair)
           (push child-read handles) (push our-write handles)
           (multiple-value-bind (our-read child-write) (%pipe-pair)
             (push our-read handles) (push child-write handles)
             (let ((process (aion/windows:spawn-in-job
                             (first command-line) (rest command-line)
                             :input nil :output nil
                             :error (uiop:native-namestring stderr-file)
                             :inherit-handles (list child-read child-write)
                             :if-no-job :error)))
               (setf spawned process
                     handles (list child-read child-write))
               (values process our-write our-read))))
      ;; The child's ends are the child's now, or nobody's.
      (dolist (h handles) (ignore-errors (sb-unix:unix-close h))))))

#-win32
(defun %spawn-piped (command-line stderr-file)
  "Start COMMAND-LINE, which has --remote-debugging-pipe, with standard input and output
discarded, standard error appended to STDERR-FILE, and two new pipes as its descriptors 3 and 4.
Returns a PIPED-PROCESS, the descriptor to write commands to, and the one to read answers from.
On Linux the browser is started through setpriv, as %SPAWN does; setpriv execs the browser, which
keeps the descriptors. The kernel sends --pdeathsig's signal when the thread that started the
process ends, and that thread is the loop thread here, so the browser is killed if the loop
thread stops while it runs, as well as when this process exits. %RELEASE stops the loop thread
only after the browser has exited."
  (let* ((setpriv (%setpriv))
         (line (if setpriv
                   (list* setpriv "--pdeathsig" "KILL" "--" command-line)
                   command-line))
         (loop (handler-case (uv:make-loop)
                 (aion/uv/ffi:libuv-not-found (c)
                   (error "aion/cdp's pipe transport starts the browser through libuv, which was not found. Build it with scripts/build-libuv.lisp, or pass :TRANSPORT :PORT to LAUNCH-BROWSER.~%~A"
                          c))))
         (fds '()) (spawned nil))
    (unwind-protect
         (multiple-value-bind (child-read our-write) (%pipe-pair)
           (push child-read fds) (push our-write fds)
           (multiple-value-bind (our-read child-write) (%pipe-pair)
             (push our-read fds) (push child-write fds)
             (let ((stderr (sb-posix:open (uiop:native-namestring stderr-file)
                                          (logior sb-posix:o-wronly sb-posix:o-creat
                                                  sb-posix:o-append)
                                          #o600))
                   (future (uv:make-future)))
               (push stderr fds)
               (sb-posix:fcntl stderr sb-posix:f-setfd 1)
               (uv:start-loop-thread loop :name "aion/cdp browser process")
               (uv:submit loop
                          (lambda ()
                            (handler-case
                                (uv:fulfill future
                                            (proc:spawn loop (first line)
                                                        :arguments (rest line)
                                                        :stdin :ignore :stdout :ignore
                                                        :stderr stderr
                                                        :inherit-fds (list child-read child-write)))
                              (error (e) (uv:fail-future future e)))))
               (let ((process (uv:await future :timeout 30)))
                 (setf spawned (%make-piped-process process loop)
                       fds (list child-read child-write stderr))
                 (values spawned our-write our-read)))))
      ;; The child's ends and the stderr file are the child's now, or nobody's.
      (dolist (fd fds) (ignore-errors (sb-posix:close fd)))
      (unless spawned (%release-loop loop)))))

#-win32
(defun %release-loop (loop)
  (ignore-errors (uv:stop-loop-thread loop))
  (ignore-errors (uv:close-loop loop)))

(defun %pid (p)
  #+win32 (aion/windows:job-process-pid p)
  #-win32 (if (piped-process-p p)
              (proc:process-pid (piped-process-process p))
              (sb-ext:process-pid p)))

(defun %alive-p (p)
  #+win32 (aion/windows:job-process-alive-p p)
  #-win32 (if (piped-process-p p)
              (proc:process-running-p (piped-process-process p))
              (sb-ext:process-alive-p p)))

(defun %exit-code (p)
  #+win32 (aion/windows:job-process-exit-code p)
  #-win32 (cond ((%alive-p p) nil)
                ((piped-process-p p) (proc:exit-status (piped-process-process p)))
                (t (sb-ext:process-exit-code p))))

(defun %wait-for-exit (p seconds)
  "Wait up to SECONDS for P to exit. Returns whether it has."
  #+win32 (aion/windows:job-process-wait p seconds)
  #-win32
  (let ((deadline (+ (get-internal-real-time)
                     (round (* seconds internal-time-units-per-second)))))
    (loop (unless (%alive-p p) (return t))
          (when (> (get-internal-real-time) deadline) (return nil))
          (sleep 0.05))))

(defun %kill (p)
  "End P now, and release what holds it."
  #+win32 (progn (ignore-errors (aion/windows:job-process-terminate p))
                 (aion/windows:job-process-close p))
  #-win32 (progn (when (%alive-p p)
                   (if (piped-process-p p)
                       (let ((process (piped-process-process p)))
                         (ignore-errors
                          (uv:submit (piped-process-loop p)
                                     (lambda () (ignore-errors (proc:kill process :kill))))))
                       (ignore-errors (sb-ext:process-kill p 9))))
                 (%wait-for-exit p 5)
                 (%release p)))

(defun %release (p)
  "Release what holds P, which has exited."
  #+win32 (aion/windows:job-process-close p)
  #-win32 (if (piped-process-p p)
              (%release-loop (piped-process-loop p))
              (sb-ext:process-close p)))

(defun %file-tail (path &optional (octets 2000))
  "The last OCTETS octets of the file at PATH, as text, or an empty string."
  (or (ignore-errors
       (with-open-file (in path :element-type '(unsigned-byte 8) :if-does-not-exist nil)
         (when in
           (let* ((size (file-length in))
                  (start (max 0 (- size octets)))
                  (buf (make-array (- size start) :element-type '(unsigned-byte 8))))
             (file-position in start)
             (let ((n (read-sequence buf in)))
               (string-trim '(#\Newline #\Return #\Space)
                            (sb-ext:octets-to-string buf :end n :external-format
                                                     '(:utf-8 :replacement #\?))))))))
      ""))

(defun %read-active-port (profile)
  "The port and the browser's WebSocket path from DevToolsActivePort in PROFILE, as two
values, or NIL while the file is missing or not yet complete. The browser writes the port on
the first line and the path on the second."
  (let ((text (ignore-errors
               (with-open-file (in (merge-pathnames "DevToolsActivePort" profile)
                                   :if-does-not-exist nil :external-format :latin-1)
                 (and in (let ((s (make-string (file-length in))))
                           (subseq s 0 (read-sequence s in))))))))
    (when text
      (let* ((nl (position #\Newline text))
             (port (and nl (parse-integer text :end nl :junk-allowed t)))
             (rest (and nl (string-trim '(#\Newline #\Return #\Space) (subseq text (1+ nl))))))
        (when (and port (< 0 port 65536) rest (plusp (length rest)) (char= (char rest 0) #\/))
          (values port rest))))))
