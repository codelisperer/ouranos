;;;; open.lisp --- show a path in the file manager, open a URL in the browser (#820)
;;;;
;;;; Desktop apps offer "Show in folder" and "Open data directory", and each wrote its own
;;;; switch over explorer, open and xdg-open. REVEAL-PATH is that switch, written once:
;;;;
;;;;   - Windows: explorer.exe from the Windows directory with /select,"<path>" to select an
;;;;     item; ShellExecuteW with the "open" verb to open a directory.
;;;;   - macOS: /usr/bin/open -R, which shows the item selected in the folder holding it. It is
;;;;     used with and without SELECT, because /usr/bin/open on a directory that is an app
;;;;     bundle or another package launches it instead of showing it.
;;;;   - Linux: to select an item, the org.freedesktop.FileManager1 ShowItems call through
;;;;     dbus-send, when dbus-send is installed and a file manager answers it; otherwise, and to
;;;;     open a directory, xdg-open on the directory.
;;;;
;;;; OPEN-URL opens an http or https URL in the default browser: ShellExecuteW on Windows,
;;;; /usr/bin/open on macOS, xdg-open on Linux. Any other scheme is refused, because these also
;;;; open file: URLs and custom schemes, which start other programs. So is any character outside
;;;; the set RFC 3986 allows in a URL, which leaves out the space, " < > \ ^ | { } and the
;;;; backtick.
;;;;
;;;; No shell is involved anywhere. On macOS and Linux each program gets the path or URL as one
;;;; argument. explorer.exe does not read its command line by the rules SBCL quotes arguments
;;;; for, and splits /select at commas, so its command line is written here instead:
;;;; /select,"<path>", which is unambiguous because Windows does not allow " in a file name.
;;;; The path is made absolute first, so it can never be read as an option. The file manager and
;;;; the browser are started and not waited for; dbus-send is waited for, for at most two
;;;; seconds, because its answer says whether a file manager took the request.
;;;;
;;;; Both return :OPENED, or :NOT-AVAILABLE with a reason as the second value: :NO-DISPLAY
;;;; (Linux with neither DISPLAY nor WAYLAND_DISPLAY), :NO-PROGRAM (Linux with no xdg-open) or
;;;; :FAILED (the program could not be started). As in hades/notify, %PLAN returns the decision
;;;; as data and does nothing, so the tests check every platform's decision on every platform
;;;; without opening anything.

(in-package #:hades/open)

(define-condition path-not-found (error)
  ((path :initarg :path :reader path-not-found-path))
  (:report (lambda (c s) (format s "no file or directory at ~A" (path-not-found-path c))))
  (:documentation "Signalled by REVEAL-PATH when nothing exists at the path."))

(define-condition unsupported-url (error)
  ((url :initarg :url :reader unsupported-url-url))
  (:report (lambda (c s)
             (declare (ignore c))
             ;; The URL is not printed: it can carry a token in its query.
             (write-string "OPEN-URL takes an http or https URL with only the characters" s)
             (write-string " RFC 3986 allows" s)))
  (:documentation "Signalled by OPEN-URL for a URL that is not http or https, or that holds a
character RFC 3986 does not allow in a URL."))

;;; --- the decision, as data -------------------------------------------------------------

(defun %platform ()
  #+win32 :windows
  #+darwin :macos
  #-(or win32 darwin) :linux)

(defun %set-p (getenv name)
  (let ((value (funcall getenv name)))
    (and value (plusp (length value)))))

(defun %windows-directory ()
  "The Windows directory, from GetSystemWindowsDirectoryW and never from SystemRoot, which the
process that started this one can set to anything."
  #+win32 (aion/windows:system-windows-directory)
  ;; Reached only by a test that plans for Windows on another platform without passing
  ;; :WINDOWS-DIRECTORY.
  #-win32 "C:\\Windows")

(defun %file-uri (native)
  "A file: URI for the absolute path NATIVE, every byte outside the unreserved set and / escaped.
dbus-send splits an array argument at commas, so an escaped comma is the only safe one."
  (with-output-to-string (s)
    (write-string "file://" s)
    (loop for byte across (sb-ext:string-to-octets native :external-format :utf-8)
          for c = (code-char byte)
          do (if (or (char<= #\a c #\z) (char<= #\A c #\Z) (char<= #\0 c #\9)
                     (find c "-._~/"))
                 (write-char c s)
                 (format s "%~2,'0X" byte)))))

(defun %dbus-show-items (dbus-send native)
  (list dbus-send
        (list "--session" "--print-reply" "--reply-timeout=2000"
              "--dest=org.freedesktop.FileManager1" "--type=method_call"
              "/org/freedesktop/FileManager1" "org.freedesktop.FileManager1.ShowItems"
              (concatenate 'string "array:string:" (%file-uri native))
              "string:")))

(defun %display-p (getenv)
  (or (%set-p getenv "DISPLAY") (%set-p getenv "WAYLAND_DISPLAY")))

(defun %reveal-plan (native directory select &key (platform (%platform)) (getenv #'uiop:getenv)
                                                   (find-program #'hades/program:find-program)
                                                   (windows-directory #'%windows-directory))
  "What REVEAL-PATH will do, without doing it. NATIVE is the item's absolute native namestring
and DIRECTORY the directory to open (NATIVE itself, or the one holding it). Returns one of:

  (:NOT-AVAILABLE reason)
  (:LAUNCH program arguments)                     start it, do not wait
  (:LAUNCH-RAW program command-line)              Windows: start it with COMMAND-LINE after
                                                  its name, as it is, and do not wait
  (:SHELL-OPEN target)                            Windows: ShellExecuteW, open verb
  (:TRY (program arguments) (program arguments))  run the first and wait; if it does not exit
                                                  with 0, start the second and do not wait

Signals PATH-NOT-FOUND for a Windows path containing a double quote, which no Windows file
name can contain and which would end the quoted path early."
  (ecase platform
    (:windows
     (cond ((find #\" native) (error 'path-not-found :path native))
           (select
            (list :launch-raw (concatenate 'string (funcall windows-directory) "\\explorer.exe")
                  (format nil "/select,\"~A\"" native)))
           (t (list :shell-open directory))))
    (:macos
     (list :launch "/usr/bin/open" (list "-R" native)))
    (:linux
     (let ((xdg-open (funcall find-program "xdg-open"))
           (dbus-send (funcall find-program "dbus-send")))
       (cond ((not (%display-p getenv)) (list :not-available :no-display))
             ((and select dbus-send xdg-open)
              (list :try (%dbus-show-items dbus-send native) (list xdg-open (list directory))))
             ((and select dbus-send) (list :try (%dbus-show-items dbus-send native) nil))
             (xdg-open (list :launch xdg-open (list directory)))
             (t (list :not-available :no-program)))))))

(defun %url-plan (url &key (platform (%platform)) (getenv #'uiop:getenv)
                           (find-program #'hades/program:find-program))
  "What OPEN-URL will do, without doing it, in the shapes %REVEAL-PLAN returns."
  (ecase platform
    (:windows (list :shell-open url))
    (:macos (list :launch "/usr/bin/open" (list url)))
    (:linux
     (let ((xdg-open (funcall find-program "xdg-open")))
       (cond ((not (%display-p getenv)) (list :not-available :no-display))
             (xdg-open (list :launch xdg-open (list url)))
             (t (list :not-available :no-program)))))))

;;; --- doing it -------------------------------------------------------------------------

(defun %launch (program arguments)
  "Start PROGRAM with ARGUMENTS, no shell, and do not wait. True when it started."
  (handler-case
      (let ((process (uiop:launch-program (cons program arguments)
                                          :input nil :output nil :error-output nil)))
        ;; THREAD-LIFETIME: ends when PROGRAM exits. On Unix a child nobody waits for stays a
        ;; zombie until it is reaped; this waits for it, so the app does not have to.
        (sb-thread:make-thread (lambda ()
                                 (aion/dynamic:unblock-interrupts)
                                 (ignore-errors (uiop:wait-process process)))
                               :name "hades/open reaper")
        t)
    (error () nil)))

(defun %launch-raw (program command-line)
  "Windows: start PROGRAM with COMMAND-LINE after its name, unquoted, no shell, and do not
wait. True when it started."
  #-win32 (declare (ignore program command-line))
  #+win32
  (handler-case
      (let ((process (sb-ext:run-program program (list command-line)
                                         :wait nil :search nil :escape-arguments nil
                                         :input nil :output nil :error nil)))
        ;; THREAD-LIFETIME: ends when PROGRAM exits, as in %LAUNCH.
        (sb-thread:make-thread (lambda ()
                                 (aion/dynamic:unblock-interrupts)
                                 (ignore-errors (sb-ext:process-wait process)))
                               :name "hades/open reaper")
        t)
    (error () nil))
  #-win32 nil)

(defun %shell-open (target)
  "Windows: open TARGET with ShellExecuteW and the open verb. True when it reported success."
  #-win32 (declare (ignore target))
  #+win32 (values (aion/windows:shell-open target))
  #-win32 nil)

(defun %run (program arguments)
  "Run PROGRAM with ARGUMENTS, no shell, and wait. True when it exited with status 0."
  (handler-case
      (zerop (nth-value 2 (uiop:run-program (cons program arguments)
                                            :ignore-error-status t
                                            :input nil :output nil :error-output nil)))
    (error () nil)))

(defun %perform (plan)
  (flet ((result (ok) (if ok (values :opened nil) (values :not-available :failed))))
    (destructuring-bind (kind &rest details) plan
      (ecase kind
        (:not-available (values :not-available (first details)))
        (:launch (result (%launch (first details) (second details))))
        (:launch-raw (result (%launch-raw (first details) (second details))))
        (:shell-open (result (%shell-open (first details))))
        (:try (destructuring-bind (first-step &optional second-step) details
                (cond ((%run (first first-step) (second first-step)) (values :opened nil))
                      (second-step (result (%launch (first second-step) (second second-step))))
                      (t (values :not-available :failed)))))))))

(defun reveal-path (path &key select)
  "Show PATH, a file or directory, in the system file manager. With SELECT true, open the
directory holding PATH with PATH selected; otherwise open PATH if it is a directory, or the
directory holding it.

On macOS the item is always shown selected in the folder holding it, with or without SELECT,
because opening a directory that is an app bundle or another package would launch it.

A string is read as a native file name, so [ ] * ? and \\ in it are ordinary characters.

Returns :OPENED, or :NOT-AVAILABLE with the reason as a second value (:NO-DISPLAY, :NO-PROGRAM
or :FAILED). It does not wait for the file manager. Signals PATH-NOT-FOUND when nothing exists
at PATH, and a TYPE-ERROR when PATH is not a string or pathname."
  (check-type path (or string pathname))
  (let ((found (probe-file (if (stringp path) (uiop:parse-native-namestring path) path))))
    (unless found (error 'path-not-found :path path))
    (let* ((directory-p (uiop:directory-exists-p found))
           (item (uiop:native-namestring
                  (if directory-p
                      (uiop:ensure-directory-pathname found)
                      found)))
           (native (if directory-p (string-right-trim "/\\" item) item))
           (directory (uiop:native-namestring
                       (if directory-p
                           (uiop:ensure-directory-pathname found)
                           (uiop:pathname-directory-pathname found)))))
      ;; A root directory trims to nothing; it is its own item.
      (%perform (%reveal-plan (if (plusp (length native)) native item) directory select)))))

(defun %url-char-p (c)
  "True for a character RFC 3986 allows in a URL: unreserved, reserved, or % for an escape."
  (or (char<= #\a c #\z) (char<= #\A c #\Z) (char<= #\0 c #\9)
      (find c "-._~:/?#[]@!$&'()*+,;=%")))

(defun %url-p (url)
  (and (stringp url)
       (let ((lower (string-downcase url)))
         (or (and (> (length lower) 7) (string= "http://" lower :end2 7))
             (and (> (length lower) 8) (string= "https://" lower :end2 8))))
       (every #'%url-char-p url)))

(defun open-url (url)
  "Open URL, an http or https URL, in the default browser, and do not wait for it.

Returns :OPENED, or :NOT-AVAILABLE with the reason as a second value, as REVEAL-PATH does.
Signals UNSUPPORTED-URL for any other scheme (file:, javascript: and custom schemes start other
programs) and for a URL with a character RFC 3986 does not allow, such as a space, a control
character, \" < > \\ ^ | { } or the backtick. Escape those with %."
  (unless (%url-p url) (error 'unsupported-url :url url))
  (%perform (%url-plan url)))
