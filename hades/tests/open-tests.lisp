;;;; open-tests.lisp --- show a path in the file manager, open a URL in the browser (#820).
;;;;
;;;; Nothing here opens a file manager or a browser. Every platform's command is checked on
;;;; every platform through %REVEAL-PLAN and %URL-PLAN, and REVEAL-PATH's own path handling is
;;;; checked with %PERFORM replaced by a function that records the plan. The part that starts
;;;; programs is checked with the SBCL runtime in place of the file manager.

(defpackage #:hades/open/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:o #:hades/open))
  (:export #:run-tests))

(in-package #:hades/open/tests)

(def-suite all :description "hades/open, with nothing opened.")
(in-suite all)

(defun run-tests () (fiveam:run! 'all))

(defun env (&rest pairs)
  (lambda (name) (getf pairs (intern name :keyword))))

(defun programs (&rest names)
  (lambda (name) (when (member name names :test #'string=) (concatenate 'string "/usr/bin/" name))))

(defun recording-plans (fn)
  "Call FN with %PERFORM replaced by a function that records each plan and opens nothing.
Returns the plans in order."
  (let ((plans '()))
    (sb-int:encapsulate 'o::%perform 'record
                        (lambda (f plan) (declare (ignore f)) (push plan plans) (values :opened nil)))
    (unwind-protect (funcall fn)
      (sb-int:unencapsulate 'o::%perform 'record))
    (reverse plans)))

(defmacro with-temp-dir ((dir) &body body)
  "Bind DIR to a new, empty directory, deleted afterwards."
  `(let ((,dir (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "hades-open-~36R/" (random (expt 36 8) (make-random-state t)))
                                 (uiop:temporary-directory)))))
     (ensure-directories-exist ,dir)
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,dir :validate t))))

;;; --- refusals ---------------------------------------------------------------------------

(test a-missing-path-signals-and-opens-nothing
  (with-temp-dir (dir)
    (let* ((missing (merge-pathnames "no-such-file.txt" dir))
           (condition nil)
           (plans (recording-plans
                   (lambda () (handler-case (o:reveal-path missing :select t)
                                (o:path-not-found (c) (setf condition c)))))))
      (is (typep condition 'o:path-not-found))
      (is (equal missing (o:path-not-found-path condition)))
      (is (null plans) "Nothing was started.")))
  (signals type-error (o:reveal-path 42)))

(test only-http-and-https-urls-are-opened
  (dolist (url (list "file:///etc/passwd" "javascript:alert(1)" "ftp://example.com/"
                     "x-app://open" "http://" "https://" "http://exa mple.com"
                     (format nil "https://example.com/~C" #\Newline) "" 42 nil))
    (is (null (recording-plans (lambda () (signals o:unsupported-url (o:open-url url)))))
        "~S" url))
  (is-true (o::%url-p "HTTPS://example.com/a?b=c") "An upper-case scheme is accepted.")
  (is-true (o::%url-p "http://localhost:8080/")))

(test an-unsupported-url-is-not-printed
  (let ((text (handler-case (progn (o:open-url "https://example.com/?token=SECRET x") "")
                (o:unsupported-url (c) (princ-to-string c)))))
    (is (plusp (length text)))
    (is (null (search "SECRET" text)) "~A" text)))

;;; --- every platform's command ---------------------------------------------------------

(test windows-uses-explorer-from-the-windows-directory
  (let ((getenv (env :|SystemRoot| "D:\\Win")))
    (is (equal '(:launch "D:\\Win\\explorer.exe" ("/select,C:\\Users\\a b\\c.txt"))
               (o::%reveal-plan "C:\\Users\\a b\\c.txt" "C:\\Users\\a b\\" t :platform :windows :getenv getenv)))
    (is (equal '(:launch "D:\\Win\\explorer.exe" ("C:\\Users\\a b\\"))
               (o::%reveal-plan "C:\\Users\\a b\\c.txt" "C:\\Users\\a b\\" nil :platform :windows :getenv getenv)))
    (is (equal '(:launch "D:\\Win\\System32\\rundll32.exe" ("url.dll,FileProtocolHandler" "https://example.com/?a=1&b=2"))
               (o::%url-plan "https://example.com/?a=1&b=2" :platform :windows :getenv getenv))
        "The URL is one argument, so & is not a command separator."))
  (is (equal "C:\\Windows\\explorer.exe"
             (second (o::%reveal-plan "C:\\a" "C:\\" nil :platform :windows :getenv (env))))
      "Without SystemRoot, the usual Windows directory."))

(test macos-uses-open-with-r-to-select
  (is (equal '(:launch "/usr/bin/open" ("-R" "/Users/a/b c.txt"))
             (o::%reveal-plan "/Users/a/b c.txt" "/Users/a/" t :platform :macos)))
  (is (equal '(:launch "/usr/bin/open" ("/Users/a/"))
             (o::%reveal-plan "/Users/a/b c.txt" "/Users/a/" nil :platform :macos)))
  (is (equal '(:launch "/usr/bin/open" ("https://example.com/"))
             (o::%url-plan "https://example.com/" :platform :macos))))

(test linux-asks-the-file-manager-over-dbus-then-falls-back-to-xdg-open
  (let ((display (env :display ":0"))
        (native (format nil "/home/u/a b,c/~C.txt" (code-char #xFC))))
    (is (equal `(:try ("/usr/bin/dbus-send"
                       ("--session" "--print-reply" "--reply-timeout=2000"
                        "--dest=org.freedesktop.FileManager1" "--type=method_call"
                        "/org/freedesktop/FileManager1" "org.freedesktop.FileManager1.ShowItems"
                        "array:string:file:///home/u/a%20b%2Cc/%C3%BC.txt" "string:"))
                      ("/usr/bin/xdg-open" ("/home/u/a b,c/")))
               (o::%reveal-plan native "/home/u/a b,c/" t :platform :linux :getenv display
                                                          :find-program (programs "dbus-send" "xdg-open")))
        "The comma is escaped, because dbus-send splits an array at commas.")
    (is (equal '(:launch "/usr/bin/xdg-open" ("/home/u/"))
               (o::%reveal-plan "/home/u/x" "/home/u/" t :platform :linux :getenv display
                                                         :find-program (programs "xdg-open")))
        "Without dbus-send, the directory is opened.")
    (is (equal '(:launch "/usr/bin/xdg-open" ("/home/u/"))
               (o::%reveal-plan "/home/u/x" "/home/u/" nil :platform :linux :getenv display
                                                           :find-program (programs "dbus-send" "xdg-open")))
        "Without :SELECT, no D-Bus call.")
    (is (eq nil (third (o::%reveal-plan "/home/u/x" "/home/u/" t :platform :linux :getenv display
                                                                 :find-program (programs "dbus-send"))))
        "dbus-send with no xdg-open to fall back to.")
    (is (equal '(:not-available :no-program)
               (o::%reveal-plan "/home/u/x" "/home/u/" nil :platform :linux :getenv display
                                                           :find-program (programs "dbus-send"))))
    (is (equal '(:launch "/usr/bin/xdg-open" ("https://example.com/"))
               (o::%url-plan "https://example.com/" :platform :linux :getenv display
                                                    :find-program (programs "xdg-open"))))
    (is (equal '(:not-available :no-program)
               (o::%url-plan "https://example.com/" :platform :linux :getenv display))))
  (is (equal '(:not-available :no-display)
             (o::%reveal-plan "/home/u/x" "/home/u/" t :platform :linux :getenv (env :display "")
                                                       :find-program (programs "dbus-send" "xdg-open"))))
  (is (eq :try (first (o::%reveal-plan "/home/u/x" "/home/u/" t :platform :linux
                                                                :getenv (env :wayland_display "wayland-0")
                                                                :find-program (programs "dbus-send" "xdg-open")))))
  (is (equal '(:not-available :no-display)
             (o::%url-plan "https://example.com/" :platform :linux :getenv (env)
                                                  :find-program (programs "xdg-open")))))

;;; --- reveal-path's own path handling, with nothing opened -------------------------------

(test reveal-path-passes-an-absolute-path-and-its-directory
  (with-temp-dir (dir)
    (let ((file (merge-pathnames "a file.txt" dir))
          (root (uiop:native-namestring (truename dir))))
      (with-open-file (s file :direction :output) (write-line "x" s))
      (let ((plans (recording-plans
                    (lambda ()
                      (o:reveal-path file :select t)
                      (o:reveal-path file)
                      (o:reveal-path dir :select t)
                      (o:reveal-path (string-right-trim "/\\" (uiop:native-namestring dir)))))))
        (is (= 4 (length plans)))
        (flet ((args (plan) (car (last plan))))
          #+darwin
          (progn
            (is (equal (list "-R" (concatenate 'string root "a file.txt")) (args (first plans))))
            (is (equal (list root) (args (second plans))) "A file without :SELECT opens its directory.")
            (is (equal (list "-R" (string-right-trim "/" root)) (args (third plans)))
                "A directory is selected by its name, with no trailing separator.")
            (is (equal (list root) (args (fourth plans))) "A directory named without a separator."))
          #+win32
          (progn
            (is (equal (list (concatenate 'string "/select," root "a file.txt")) (args (first plans))))
            (is (equal (list root) (args (second plans))))
            (is (equal (list (concatenate 'string "/select," (string-right-trim "\\" root))) (args (third plans))))
            (is (equal (list root) (args (fourth plans)))))
          #-(or darwin win32)
          (dolist (plan plans)
            (is (member (first plan) '(:not-available :try :launch)) "~S" plan)))))))

;;; --- starting programs, with SBCL standing in -------------------------------------------

(defun sbcl (&rest arguments)
  (list (uiop:native-namestring sb-ext:*runtime-pathname*)
        (list* "--core" (uiop:native-namestring sb-ext:*core-pathname*) "--noinform" arguments)))

(defun sbcl-exiting (code)
  (sbcl "--non-interactive" "--no-sysinit" "--no-userinit"
        "--eval" (format nil "(sb-ext:exit :code ~D :abort t)" code)))

(defun perform (plan) (multiple-value-list (o::%perform plan)))

(test the-try-step-falls-back-only-when-the-first-program-fails
  (is (equal '(:opened nil) (perform (list :try (sbcl-exiting 0) (list "/no/such/program-820" '())))))
  (is (equal '(:opened nil) (perform (list :try (sbcl-exiting 4) (sbcl "--version"))))
      "The first failed, the second started.")
  (is (equal '(:not-available :failed) (perform (list :try (sbcl-exiting 4) nil))))
  (is (equal '(:not-available :failed) (perform (list :try (sbcl-exiting 4) (list "/no/such/program-820" '()))))))

(test launch-reports-whether-the-program-started
  (is (equal '(:opened nil) (perform (cons :launch (sbcl "--version")))))
  (is (equal '(:not-available :failed) (perform (list :launch "/no/such/program-820" '()))))
  (is (equal '(:not-available :no-display) (perform '(:not-available :no-display)))))

(test a-file-uri-escapes-everything-but-unreserved-characters-and-slashes
  (is (string= "file:///" (o::%file-uri "/")))
  (is (string= "file:///a-b_c.d~e/F9" (o::%file-uri "/a-b_c.d~e/F9")))
  (is (string= "file:///%23%3F%25%27%22%3B%26" (o::%file-uri "/#?%'\";&"))))
