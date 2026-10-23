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

(test only-the-characters-rfc-3986-allows-are-accepted-in-a-url
  (dolist (c (list #\" #\< #\> #\\ #\^ #\| #\{ #\} #\` #\Tab (code-char 127) (code-char #xE9)))
    (let ((url (format nil "https://example.com/a~Cb" c)))
      (is (null (recording-plans (lambda () (signals o:unsupported-url (o:open-url url)))))
          "~S" url)))
  (dolist (url '("https://example.com/a-b._~c?d=e&f=g+h;i=j,k#l"
                 "http://[::1]:8080/p@q/!$'()*=%20"
                 "https://user@example.com:8443/a/b/"))
    (is-true (o::%url-p url) "~S" url)))

(test an-unsupported-url-is-not-printed
  (let ((text (handler-case (progn (o:open-url "https://example.com/?token=SECRET x") "")
                (o:unsupported-url (c) (princ-to-string c)))))
    (is (plusp (length text)))
    (is (null (search "SECRET" text)) "~A" text)))

;;; --- every platform's command ---------------------------------------------------------

(test windows-selects-with-explorer-and-opens-with-shell-execute
  (let ((windows-directory (constantly "D:\\Win"))
        (getenv (env :|SystemRoot| "bin")))
    (is (equal '(:launch-raw "D:\\Win\\explorer.exe" "/select,\"C:\\Users\\a b,c\\d.txt\"")
               (o::%reveal-plan "C:\\Users\\a b,c\\d.txt" "C:\\Users\\a b,c\\" t
                                :platform :windows :getenv getenv :windows-directory windows-directory))
        "explorer.exe's command line is written here, with the path in quotes, so a space or a comma in it is part of the path.")
    (is (equal '(:shell-open "C:\\Users\\a b,c\\")
               (o::%reveal-plan "C:\\Users\\a b,c\\d.txt" "C:\\Users\\a b,c\\" nil
                                :platform :windows :getenv getenv :windows-directory windows-directory)))
    (is (equal '(:shell-open "https://example.com/?a=1&b=2")
               (o::%url-plan "https://example.com/?a=1&b=2" :platform :windows :getenv getenv))
        "The URL goes to ShellExecuteW, so & is not a command separator.")
    (signals o:path-not-found
      (o::%reveal-plan "C:\\a\"b" "C:\\" t :platform :windows :windows-directory windows-directory))))

(test the-windows-directory-does-not-come-from-systemroot
  ;; On Windows the default is GetSystemWindowsDirectoryW; elsewhere a fixed C:\Windows, used
  ;; only by tests like this one.
  (let ((plan (o::%reveal-plan "C:\\a" "C:\\" t :platform :windows :getenv (env :|SystemRoot| "."))))
    (is (eq :launch-raw (first plan)))
    (is (uiop:string-suffix-p (second plan) "\\explorer.exe"))
    (is (and (> (length (second plan)) 3) (char= #\: (char (second plan) 1)))
        "An absolute path: ~S" (second plan))))

(test macos-always-uses-open-with-r
  (is (equal '(:launch "/usr/bin/open" ("-R" "/Users/a/b c.txt"))
             (o::%reveal-plan "/Users/a/b c.txt" "/Users/a/" t :platform :macos)))
  (is (equal '(:launch "/usr/bin/open" ("-R" "/Users/a/b c.txt"))
             (o::%reveal-plan "/Users/a/b c.txt" "/Users/a/" nil :platform :macos)))
  (is (equal '(:launch "/usr/bin/open" ("-R" "/Applications/Example.app"))
             (o::%reveal-plan "/Applications/Example.app" "/Applications/Example.app/" nil :platform :macos))
      "A directory is never given to open without -R, which would launch an app bundle.")
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
            (is (equal (list "-R" (concatenate 'string root "a file.txt")) (args (second plans))))
            (is (equal (list "-R" (string-right-trim "/" root)) (args (third plans)))
                "A directory is selected by its name, with no trailing separator.")
            (is (equal (list "-R" (string-right-trim "/" root)) (args (fourth plans)))
                "A directory named without a separator."))
          #+win32
          (progn
            (is (equal (format nil "/select,\"~Aa file.txt\"" root) (args (first plans))))
            (is (equal (list :shell-open root) (second plans)) "A file without :SELECT opens its directory.")
            (is (equal (format nil "/select,\"~A\"" (string-right-trim "\\" root)) (args (third plans))))
            (is (equal (list :shell-open root) (fourth plans)) "A directory named without a separator."))
          #-(or darwin win32)
          (dolist (plan plans)
            (is (member (first plan) '(:not-available :try :launch)) "~S" plan)))))))

(test reveal-path-gives-the-plan-the-item-and-the-directory-to-open
  (with-temp-dir (dir)
    (let* ((file (merge-pathnames "a file.txt" dir))
           (root (uiop:native-namestring (truename dir)))
           (item (string-right-trim "/\\" root))
           (calls '()))
      (with-open-file (s file :direction :output) (write-line "x" s))
      (sb-int:encapsulate 'o::%reveal-plan 'record
                          (lambda (f native directory select &rest keys)
                            (declare (ignore f keys))
                            (push (list native directory select) calls)
                            '(:not-available :recorded)))
      (unwind-protect
           (progn (o:reveal-path file :select t)
                  (o:reveal-path file)
                  (o:reveal-path dir))
        (sb-int:unencapsulate 'o::%reveal-plan 'record))
      (is (equal (list (list (concatenate 'string root "a file.txt") root t)
                       (list (concatenate 'string root "a file.txt") root nil)
                       (list item root nil))
                 (reverse calls))
          "A file's directory is the one holding it; a directory is its own."))))

;;; A string is a native file name, so [ ] * ? are not wildcards and \\ on Unix is a character.
(test a-string-path-is-read-as-a-native-file-name
  (with-temp-dir (dir)
    (let ((names (list "report[1].pdf" #-win32 "a*b" #-win32 "a?b" #-win32 "a\\b"))
          (root (uiop:native-namestring (truename dir))))
      (dolist (name names)
        (with-open-file (s (uiop:parse-native-namestring (concatenate 'string root name))
                           :direction :output)
          (write-line "x" s)))
      (let ((plans (recording-plans
                    (lambda ()
                      (dolist (name names)
                        (o:reveal-path (concatenate 'string root name) :select t))))))
        (is (= (length names) (length plans)))
        (loop for name in names
              for plan in plans
              for item = (concatenate 'string root name)
              do #+darwin (is (equal (list "-R" item) (car (last plan))) "~S" name)
                 #+win32 (is (equal (format nil "/select,\"~A\"" item) (car (last plan))) "~S" name)
                 #-(or darwin win32) (is (member (first plan) '(:not-available :try :launch)) "~S" plan))
        (is (null (recording-plans
                   (lambda ()
                     (signals o:path-not-found
                       (o:reveal-path (concatenate 'string root "report[2].pdf")))))))))))

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

#-win32
(test the-windows-only-steps-report-failure-elsewhere
  (is (equal '(:not-available :failed) (perform (list :launch-raw "/no/such/program-820" "--version"))))
  (is (equal '(:not-available :failed) (perform (list :shell-open "https://example.com/")))))

#+win32
(test launch-raw-starts-the-program-with-the-command-line-as-written
  (is (equal '(:opened nil)
             (perform (list :launch-raw (uiop:native-namestring sb-ext:*runtime-pathname*) "--version"))))
  (is (equal '(:not-available :failed) (perform (list :launch-raw "C:\\no\\such\\program-820.exe" "")))))

(test launch-reports-whether-the-program-started
  (is (equal '(:opened nil) (perform (cons :launch (sbcl "--version")))))
  (is (equal '(:not-available :failed) (perform (list :launch "/no/such/program-820" '()))))
  (is (equal '(:not-available :no-display) (perform '(:not-available :no-display)))))

(test a-file-uri-escapes-everything-but-unreserved-characters-and-slashes
  (is (string= "file:///" (o::%file-uri "/")))
  (is (string= "file:///a-b_c.d~e/F9" (o::%file-uri "/a-b_c.d~e/F9")))
  (is (string= "file:///%23%3F%25%27%22%3B%26" (o::%file-uri "/#?%'\";&"))))
