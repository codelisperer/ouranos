;;;; shell.lisp --- the Windows directory, and opening a URL with its registered program (#820).
;;;;
;;;; SYSTEM-WINDOWS-DIRECTORY is where explorer.exe and System32 live. It is read from
;;;; GetSystemWindowsDirectoryW rather than the SystemRoot environment variable, because a
;;;; process can be started with SystemRoot set to anything, and a relative value would make a
;;;; program in the current directory run in place of explorer.exe.
;;;;
;;;; SHELL-OPEN hands a target to ShellExecuteW with the "open" verb, which opens it with the
;;;; program registered for it: an http or https URL opens in the default browser. No command
;;;; line is built and no shell runs, so characters such as & and | in the target are not
;;;; syntax. The caller decides what it is willing to open; hades/open:open-url accepts http and
;;;; https URLs only, because the same call opens a file: URL or a custom scheme with whatever
;;;; program is registered for it.

(in-package #:aion/windows)

(defun system-windows-directory ()
  "The Windows directory, usually \"C:\\Windows\", with no trailing separator.
Signals WIN32-ERROR when GetSystemWindowsDirectoryW fails."
  (let ((size 261))
    (loop
      (cffi:with-foreign-object (buffer :uint16 size)
        (let ((written (check-win32 (ffi:get-system-windows-directory-w buffer size)
                                    :operation "GetSystemWindowsDirectoryW"
                                    :predicate #'plusp)))
          ;; A value at least SIZE is the size needed, NUL included; try again with it.
          (if (< written size)
              (return (wide-string-to-lisp buffer :max-chars written))
              (setf size written)))))))

(defun %shell-execute (target)
  "Call ShellExecuteW with the open verb on TARGET from a COM apartment. The value it returned,
as an integer."
  (let ((initialized (ffi:co-initialize-ex (cffi:null-pointer)
                                           (logior ffi:+coinit-apartmentthreaded+
                                                   ffi:+coinit-disable-ole1dde+))))
    (unwind-protect
         (with-wide-string (verb "open")
           (with-wide-string (file target)
             (cffi:pointer-address
              (ffi:shell-execute-w (cffi:null-pointer) verb file (cffi:null-pointer)
                                   (cffi:null-pointer) ffi:+sw-shownormal+))))
      ;; S_OK and S_FALSE both need a matching CoUninitialize; a failure does not.
      (when (hresult-succeeded-p initialized)
        (ffi:co-uninitialize)))))

(defun shell-open (target)
  "Open TARGET, a string, with the program registered for it, through ShellExecuteW and the
\"open\" verb. An http or https URL opens in the default browser. It does not wait for that
program.

Returns T when ShellExecuteW reported success. Otherwise returns NIL, with ShellExecuteW's
error code (32 or below, an SE_ERR_* value) or :ERROR as the second value. TARGET is passed as
it is: the caller decides which targets it is willing to open."
  (check-type target string)
  (let ((result nil))
    ;; THREAD-LIFETIME: joined before SHELL-OPEN returns; it ends when ShellExecuteW does.
    ;; ShellExecuteW can start a shell extension through COM, so it needs an apartment. A thread
    ;; of its own gets one without changing the apartment of the caller's thread.
    (sb-thread:join-thread
     (sb-thread:make-thread
      (lambda ()
        (aion/dynamic:unblock-interrupts)
        (setf result (handler-case (%shell-execute target)
                       (error () :error))))
      :name "aion/windows shell-open"))
    (if (and (integerp result) (> result 32))
        t
        (values nil result))))
