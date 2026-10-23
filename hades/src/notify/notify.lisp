;;;; notify.lisp --- a notice to the user before an app has a window (#819)
;;;;
;;;; The common case is a second launch refused by hades/single-instance: the app should say
;;;; that it is already running and exit. A macOS .app or a Linux desktop launch has no
;;;; console, so writing to standard error there tells nobody anything.
;;;;
;;;; NOTIFY-USER shows a blocking, modal notice with one OK button:
;;;;
;;;;   - Windows: MessageBoxW, bound in aion/windows.
;;;;   - macOS: /usr/bin/osascript running "display alert". It shows the alert from osascript
;;;;     itself and sends no Apple event to another app, so it needs no permission prompt.
;;;;   - Linux and other Unix: zenity, else kdialog, found on PATH.
;;;;
;;;; Where no notice can be shown, it writes the notice to standard error instead and returns
;;;; :STDERR, so a caller can tell the difference (ADR-0001's consequence for notifications:
;;;; a contract that can say "unavailable"). The cases are: CI (CI is set), an SSH session
;;;; (SSH_CONNECTION or SSH_TTY is set), Windows session 0 (services; no desktop a user can
;;;; see), Linux with neither DISPLAY nor WAYLAND_DISPLAY, Linux with neither program, the
;;;; app asking for it (*NOTIFY-BACKEND* :STDERR, for example under --self-test), and a
;;;; native notice that failed. None of those waits for anything.
;;;;
;;;; What happens is decided by %PLAN, which returns the decision as data and does nothing.
;;;; The tests check every platform's decision on every platform from that, without showing
;;;; a window; only %PERFORM shows one.

(in-package #:hades/notify)

(defvar *notify-backend* :auto
  "How NOTIFY-USER shows a notice.

:AUTO (the default) shows a native notice unless the process is in CI or an SSH session, or
the platform has no way to show one. :NATIVE skips the CI and SSH checks; it is for a manual
test of the native notice. :STDERR always writes to standard error; an app binds it under
--self-test or any other run where nobody is at the screen.")

(deftype notice-level () '(member :info :warning :error))

(defun %notice-text-p (x)
  (and (stringp x) (not (find (code-char 0) x))))

(deftype notice-text ()
  "A string with no NUL character. A NUL would end the text early in MessageBoxW and cannot
be passed in a program argument at all."
  '(and string (satisfies %notice-text-p)))

;;; --- the decision, as data -------------------------------------------------------------

(defun %platform ()
  #+win32 :windows
  #+darwin :macos
  #-(or win32 darwin) :linux)

(defun %set-p (getenv name)
  (let ((value (funcall getenv name)))
    (and value (plusp (length value)))))

(defun %session-id ()
  "The Windows session this process runs in, or NIL when it is not known or not Windows."
  #+win32
  (handler-case
      (cffi:with-foreign-object (id 'ffi:dword)
        (if (zerop (ffi:process-id-to-session-id (ffi:get-current-process-id) id))
            nil
            (cffi:mem-ref id 'ffi:dword)))
    (error () nil))
  #-win32 nil)

(defun %osascript-arguments (title message level)
  ;; The text goes in as arguments, never into the script, so nothing in it is read as
  ;; AppleScript. "--" ends osascript's own options, so a title that starts with "-" is
  ;; still the first argument.
  (list "-e" "on run argv"
        "-e" (concatenate 'string "display alert (item 1 of argv) message (item 2 of argv) as "
                          (ecase level
                            (:info "informational")
                            (:warning "warning")
                            (:error "critical")))
        "-e" "end run"
        "--" title message))

(defun %zenity-arguments (title message level)
  ;; --no-markup, because zenity otherwise reads the text as Pango markup.
  (list (ecase level (:info "--info") (:warning "--warning") (:error "--error"))
        "--no-markup"
        (concatenate 'string "--title=" title)
        (concatenate 'string "--text=" message)))

(defun %kdialog-arguments (title message level)
  (list "--title" title
        (ecase level (:info "--msgbox") (:warning "--sorry") (:error "--error"))
        message))

(defun %plan (title message level &key (backend *notify-backend*) (platform (%platform))
                                       (getenv #'uiop:getenv)
                                       (find-program #'hades/program:find-program)
                                       (session-id #'%session-id))
  "What NOTIFY-USER will do, without doing it. Returns one of:

  (:STDERR reason)            write to standard error; REASON says why
  (:MESSAGE-BOX level)        MessageBoxW
  (:PROGRAM path arguments)   run PATH with ARGUMENTS, no shell

GETENV, FIND-PROGRAM and SESSION-ID are the process's own unless a test passes others."
  (check-type backend (member :auto :native :stderr))
  (flet ((env-p (name) (%set-p getenv name)))
    (cond ((eq backend :stderr) (list :stderr :requested))
          ((and (eq backend :auto) (env-p "CI")) (list :stderr :ci))
          ((and (eq backend :auto) (or (env-p "SSH_CONNECTION") (env-p "SSH_TTY")))
           (list :stderr :ssh))
          (t
           (ecase platform
             (:windows
              ;; Checked under :NATIVE too: a message box in session 0 never gets its click.
              (if (eql 0 (funcall session-id))
                  (list :stderr :session-0)
                  (list :message-box level)))
             (:macos
              (list :program "/usr/bin/osascript" (%osascript-arguments title message level)))
             (:linux
              (let ((zenity (funcall find-program "zenity"))
                    (kdialog (funcall find-program "kdialog")))
                (cond ((not (or (env-p "DISPLAY") (env-p "WAYLAND_DISPLAY")))
                       (list :stderr :no-display))
                      (zenity (list :program zenity (%zenity-arguments title message level)))
                      (kdialog (list :program kdialog (%kdialog-arguments title message level)))
                      (t (list :stderr :no-program))))))))))

;;; --- doing it -------------------------------------------------------------------------

(defun %write-stderr (title message level)
  ;; A Windows GUI app may have no standard error at all; writing there must not fail.
  (handler-case
      (progn
        (format *error-output* "~A~@[ (~(~A~))~]: ~A~%"
                title (unless (eq level :info) level) message)
        (finish-output *error-output*))
    (error () nil)))

(defun %run-dialog (program arguments)
  "Run PROGRAM with ARGUMENTS, no shell, and wait. True when it exited with status 0."
  (handler-case
      (zerop (nth-value 2 (uiop:run-program (cons program arguments)
                                            :ignore-error-status t
                                            :input nil :output nil :error-output nil)))
    (error () nil)))

(defun %message-box (title message level)
  "Show MessageBoxW and wait for OK. True when it was shown."
  #-win32 (declare (ignore title message level))
  #+win32
  (handler-case
      (aion/windows:with-wide-string (text message)
        (aion/windows:with-wide-string (caption title)
          (plusp (ffi:message-box-w (cffi:null-pointer) text caption
                                    (logior ffi:+mb-ok+
                                            (ecase level
                                              (:info ffi:+mb-iconinformation+)
                                              (:warning ffi:+mb-iconwarning+)
                                              (:error ffi:+mb-iconerror+))
                                            ;; With no window of its own, the box would
                                            ;; otherwise open behind whatever has focus.
                                            ffi:+mb-setforeground+
                                            ffi:+mb-topmost+)))))
    (error () nil))
  #-win32 nil)

(defun %perform (plan title message level)
  (flet ((fallback (reason)
           (%write-stderr title message level)
           (values :stderr reason)))
    (destructuring-bind (kind &rest details) plan
      (ecase kind
        (:stderr (fallback (first details)))
        (:message-box (if (%message-box title message level)
                          (values :native nil)
                          (fallback :failed)))
        (:program (if (%run-dialog (first details) (second details))
                      (values :native nil)
                      (fallback :failed)))))))

(defun notify-user (title message &key (level :info))
  "Show a blocking, modal notice with one OK button, and return when the user has closed it.
It needs no window, so an app can call it before its UI exists, for example when
hades/single-instance refuses a second launch.

TITLE and MESSAGE are strings without a NUL character. LEVEL is :INFO, :WARNING or :ERROR and
picks the icon.

Returns two values. The first is :NATIVE when the notice was shown, or :STDERR when it was
written to standard error instead; the second is NIL, or the reason for :STDERR: :REQUESTED
(*NOTIFY-BACKEND* is :STDERR), :CI, :SSH, :SESSION-0, :NO-DISPLAY, :NO-PROGRAM or :FAILED (the
native notice could not be shown). It does not signal on any of those, and in none of them
does it wait. A wrong argument, or a *NOTIFY-BACKEND* other than :AUTO, :NATIVE or :STDERR,
signals a TYPE-ERROR before anything is shown or written."
  (check-type title notice-text)
  (check-type message notice-text)
  (check-type level notice-level)
  (%perform (%plan title message level) title message level))
