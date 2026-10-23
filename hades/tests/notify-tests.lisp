;;;; notify-tests.lisp --- a notice to the user before an app has a window (#819).
;;;;
;;;; No test here shows a window. Every platform's decision is checked on every platform
;;;; through %PLAN, with the environment, the programs on PATH and the Windows session passed
;;;; in. The part that runs something is checked with the SBCL runtime standing in for the
;;;; dialog program, so a status of 0 and a failure are both seen without a dialog.
;;;;
;;;; RUN-NATIVE-TESTS shows the real notice, one per level, and waits for OK each time. It is
;;;; never part of ALL; run it by hand at a screen.

(defpackage #:hades/notify/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:n #:hades/notify))
  (:export #:run-tests #:run-native-tests))

(in-package #:hades/notify/tests)

(def-suite all :description "hades/notify, with no window shown.")
(in-suite all)

(defun run-tests () (fiveam:run! 'all))

(defun env (&rest pairs)
  "A GETENV for %PLAN that knows only PAIRS, a plist of name and value."
  (lambda (name) (getf pairs (intern name :keyword))))

(defun programs (&rest names)
  "A FIND-PROGRAM for %PLAN that finds NAMES under /usr/bin."
  (lambda (name) (when (member name names :test #'string=) (concatenate 'string "/usr/bin/" name))))

(defun plan (platform &rest keys &key (getenv (env)) (find-program (programs)) (session-id (constantly 1))
                                      (backend :auto) (level :warning) (title "Example") (message "Example is already running."))
  (declare (ignore keys))
  (n::%plan title message level :backend backend :platform platform :getenv getenv
                                :find-program find-program :session-id session-id))

(defun capture (fn)
  "Call FN with standard error and standard output collected. Returns FN's values as a list,
what it wrote to standard error, and what it wrote to standard output."
  (let ((e (make-string-output-stream)) (o (make-string-output-stream)))
    (let ((values (let ((*error-output* e) (*standard-output* o))
                    (multiple-value-list (funcall fn)))))
      (values values (get-output-stream-string e) (get-output-stream-string o)))))

;;; --- arguments ------------------------------------------------------------------------

(test a-wrong-argument-signals-before-anything-is-written
  ;; :STDERR, so that if a check here were missing, the call could not show a dialog.
  (dolist (call (list (lambda () (let ((n:*notify-backend* :stderr)) (n:notify-user 42 "message")))
                      (lambda () (let ((n:*notify-backend* :stderr)) (n:notify-user "title" nil)))
                      (lambda () (let ((n:*notify-backend* :stderr))
                                    (n:notify-user "title" (format nil "a~Cb" (code-char 0)))))
                      (lambda () (let ((n:*notify-backend* :stderr)) (n:notify-user "title" "message" :level :fatal)))
                      (lambda () (let ((n:*notify-backend* :window)) (n:notify-user "title" "message")))))
    (multiple-value-bind (values err out)
        (capture (lambda () (handler-case (progn (funcall call) :returned) (type-error () :type-error))))
      (is (equal '(:type-error) values))
      (is (string= "" (concatenate 'string err out)) "~S ~S" err out))))

;;; --- the standard-error path -------------------------------------------------------------

(test the-stderr-backend-writes-the-notice-and-says-so
  (let ((n:*notify-backend* :stderr))
    (multiple-value-bind (values err out)
        (capture (lambda () (n:notify-user "Example" "Example is already running." :level :warning)))
      (is (equal '(:stderr :requested) values))
      (is (string= (format nil "Example (warning): Example is already running.~%") err) "~S" err)
      (is (string= "" out) "Nothing goes to standard output."))))

(test an-info-notice-on-stderr-carries-no-level-and-keeps-non-ascii-text
  (let* ((n:*notify-backend* :stderr)
         (title (format nil "Caf~C" (code-char #xE9))))
    (multiple-value-bind (values err) (capture (lambda () (n:notify-user title "ok" :level :info)))
      (is (equal '(:stderr :requested) values))
      (is (string= (format nil "~A: ok~%" title) err) "~S" err))))

;;; --- the decision, on every platform -------------------------------------------------

(test ci-and-ssh-mean-stderr-unless-native-is-asked-for
  (dolist (platform '(:windows :macos :linux))
    (is (equal '(:stderr :ci) (plan platform :getenv (env :ci "true" :display ":0")
                                             :find-program (programs "zenity"))))
    (is (equal '(:stderr :ssh) (plan platform :getenv (env :ssh_connection "10.0.0.1 22 10.0.0.2 22"))))
    (is (equal '(:stderr :ssh) (plan platform :getenv (env :ssh_tty "/dev/ttys001"))))
    (is (equal '(:stderr :requested) (plan platform :backend :stderr :getenv (env :display ":0")
                                                    :find-program (programs "zenity")))))
  (is (equal '(:message-box :warning) (plan :windows :backend :native :getenv (env :ci "true")))
      ":NATIVE skips the CI check.")
  (is (eq :program (first (plan :macos :backend :native :getenv (env :ssh_tty "/dev/ttys001"))))
      ":NATIVE skips the SSH check.")
  (is (equal '(:stderr :ci) (plan :linux :getenv (env :ci "1" :display ":0") :find-program (programs "zenity"))))
  (is (eq :program (first (plan :linux :getenv (env :ci "" :display ":0") :find-program (programs "zenity"))))
      "An empty CI is not set."))

(test windows-shows-a-message-box-except-in-session-0
  (is (equal '(:message-box :error) (plan :windows :level :error)))
  (is (equal '(:message-box :info) (plan :windows :level :info :session-id (constantly nil)))
      "An unknown session is not session 0.")
  (is (equal '(:stderr :session-0) (plan :windows :session-id (constantly 0))))
  (is (equal '(:stderr :session-0) (plan :windows :backend :native :session-id (constantly 0)))
      "Session 0 is checked under :NATIVE too, because a box there is never answered."))

(test macos-runs-osascript-with-the-text-as-arguments
  (destructuring-bind (kind program arguments)
      (plan :macos :title "-e" :message "say \"hi\" & quit" :level :error)
    (is (eq :program kind))
    (is (string= "/usr/bin/osascript" program))
    (is (equal '("-e" "on run argv"
                 "-e" "display alert (item 1 of argv) message (item 2 of argv) as critical"
                 "-e" "end run"
                 "--" "-e" "say \"hi\" & quit")
               arguments)
        "The text follows --, outside the script."))
  (is (search "as informational" (fourth (third (plan :macos :level :info)))))
  (is (search "as warning" (fourth (third (plan :macos :level :warning))))))

(test linux-prefers-zenity-then-kdialog-and-needs-a-display
  (let ((display (env :display ":0")))
    (is (equal '(:program "/usr/bin/zenity" ("--warning" "--no-markup" "--title=Example" "--text=<b>hi</b>"))
               (plan :linux :getenv display :find-program (programs "zenity" "kdialog") :message "<b>hi</b>")))
    (is (equal '(:program "/usr/bin/kdialog" ("--title" "Example" "--sorry" "Example is already running."))
               (plan :linux :getenv display :find-program (programs "kdialog"))))
    (is (equal "--error" (first (third (plan :linux :getenv display :find-program (programs "zenity") :level :error)))))
    (is (equal "--msgbox" (third (third (plan :linux :getenv display :find-program (programs "kdialog") :level :info)))))
    (is (equal '(:stderr :no-program) (plan :linux :getenv display))))
  (is (eq :program (first (plan :linux :getenv (env :wayland_display "wayland-0") :find-program (programs "zenity")))))
  (is (equal '(:stderr :no-display) (plan :linux :find-program (programs "zenity"))))
  (is (equal '(:stderr :no-display) (plan :linux :getenv (env :display "") :find-program (programs "zenity"))))
  (is (equal '(:stderr :no-display) (plan :linux :backend :native :find-program (programs "zenity")))
      "No display is checked under :NATIVE too."))

;;; --- running the dialog program, with SBCL standing in for it ----------------------------

(defun sbcl-plan (&rest arguments)
  (list :program (uiop:native-namestring sb-ext:*runtime-pathname*)
        (list* "--core" (uiop:native-namestring sb-ext:*core-pathname*) "--noinform" arguments)))

(test a-program-that-exits-0-counts-as-shown-and-writes-nothing
  (multiple-value-bind (values err) (capture (lambda () (n::%perform (sbcl-plan "--version") "T" "M" :info)))
    (is (equal '(:native nil) values))
    (is (string= "" err))))

(test a-program-that-fails-falls-back-to-stderr
  (multiple-value-bind (values err)
      (capture (lambda ()
                 (n::%perform (sbcl-plan "--non-interactive" "--no-sysinit" "--no-userinit"
                                         "--eval" "(sb-ext:exit :code 3 :abort t)")
                              "T" "M" :error)))
    (is (equal '(:stderr :failed) values))
    (is (string= (format nil "T (error): M~%") err) "~S" err))
  (multiple-value-bind (values err)
      (capture (lambda () (n::%perform '(:program "/no/such/dialog-819" ()) "T" "M" :info)))
    (is (equal '(:stderr :failed) values) "A program that does not exist.")
    (is (string= (format nil "T: M~%") err) "~S" err))
  #-win32
  (is (equal '(:stderr :failed) (capture (lambda () (n::%perform '(:message-box :info) "T" "M" :info))))
      "Off Windows, a message box cannot be shown."))

(test a-closed-standard-error-does-not-make-the-fallback-signal
  (let ((closed (make-string-output-stream)))
    (close closed)
    (let ((*error-output* closed) (n:*notify-backend* :stderr))
      (is (eq :stderr (n:notify-user "T" "M"))))))

;;; --- finding the program on PATH ----------------------------------------------------

#-win32
(test find-program-takes-only-an-executable-regular-file
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "hades-notify-~36R/" (random (expt 36 8) (make-random-state t)))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (unwind-protect
         (let ((path (string-right-trim "/" (uiop:native-namestring dir))))
           (ensure-directories-exist (merge-pathnames "a-directory/" dir))
           (with-open-file (s (merge-pathnames "plain" dir) :direction :output) (write-line "x" s))
           (with-open-file (s (merge-pathnames "tool" dir) :direction :output) (write-line "x" s))
           (is (null (hades/program:find-program "a-directory" path)) "A directory is not a program.")
           (is (null (hades/program:find-program "plain" path)) "A file without execute permission is not.")
           (is (null (hades/program:find-program "tool" path)))
           (sb-posix:chmod (uiop:native-namestring (merge-pathnames "tool" dir)) #o755)
           (is (equal (concatenate 'string path "/tool")
                      (hades/program:find-program "tool" (concatenate 'string "/no/such/dir::" path)))
               "An empty or missing directory on PATH is passed over.")
           (is (null (hades/program:find-program "tool" ""))))
      (uiop:delete-directory-tree dir :validate t))))

;;; --- by hand only ------------------------------------------------------------------------

(def-suite native :description "hades/notify's real notices. Shows a window per level.")
(in-suite native)

(test each-level-shows-a-native-notice
  (let ((n:*notify-backend* :native))
    (dolist (level '(:info :warning :error))
      (is (equal '(:native nil)
                 (multiple-value-list
                  (n:notify-user (format nil "hades/notify test (~(~A~))" level)
                                 (format nil "A ~(~A~) notice. Press OK." level)
                                 :level level)))))))

(defun run-native-tests ()
  "Show one real notice per level, each waiting for OK. Never part of RUN-TESTS."
  (fiveam:run! 'native))
