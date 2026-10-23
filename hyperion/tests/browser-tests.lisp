;;;; browser-tests.lisp --- the :browser shell opens a URL with no shell, http and https only (#851).
;;;;
;;;; These check what OPEN-IN-BROWSER would do, through %BROWSER-PLAN, and never open a browser:
;;;; a test that opened one would put a window on the machine running the suite.

(in-package #:hyperion/tests)

(def-suite browser :description "hyperion/desktop: the :browser shell's URL check and plan (#851)." :in hyperion)
(in-suite browser)

(defun %plan (url os)
  (hyperion/desktop::%browser-plan url :os os))

(test windows-hands-the-url-to-shellexecute-unchanged
  "The URL that ran a second command through cmd: on Windows it is now one string for
ShellExecuteW, with & and the other characters cmd reads as syntax that RFC 3986 allows, ( ) !
and ', unchanged, and no cmd is named anywhere in the plan."
  (let* ((url "http://127.0.0.1:8080/?a=1&b=(2)&c=!x'y")
         (plan (%plan url :windows)))
    (is (equal (list :shell-open url) plan))
    (is (not (search "cmd" (format nil "~S" plan))) "the plan names cmd: ~S" plan)))

(test macos-and-linux-pass-the-url-as-one-argument
  (let ((url "https://example.test/a?b=1&c=2"))
    (is (equal (list :launch "open" url) (%plan url :macos)))
    (is (equal (list :launch "xdg-open" url) (%plan url :linux)))))

(test only-http-and-https-are-opened
  "ShellExecuteW, open and xdg-open open a file: URL or a custom scheme with whatever program is
registered for it, so those are refused on every platform, before anything is planned."
  (dolist (os '(:windows :macos :linux))
    (dolist (url '("file:///C:/Windows/System32/calc.exe" "javascript:alert(1)"
                   "ms-settings:privacy" "ftp://example.test/" "http:/missing-slash" "http://"
                   "" "HTTP:example"))
      (signals hyperion/desktop:unsupported-browser-url (%plan url os))))
  (is (equal '(:shell-open "HTTPS://Example.test/") (%plan "HTTPS://Example.test/" :windows))
      "the scheme is matched without regard to case"))

(test characters-rfc-3986-does-not-allow-are-refused
  "A space, a double quote, < > \\ ^ | { }, the backtick and control characters are not URL
characters; a URL that needs one escapes it with %."
  (dolist (c (append (coerce " \"<>\\^|{}`" 'list) (list #\Tab #\Newline (code-char 0))))
    (signals hyperion/desktop:unsupported-browser-url
      (%plan (format nil "http://127.0.0.1:8080/?q=~C" c) :windows)))
  (is (equal '(:shell-open "http://127.0.0.1:8080/?q=a%20b%7Cc")
             (%plan "http://127.0.0.1:8080/?q=a%20b%7Cc" :windows))
      "the same characters escaped with % are accepted"))

(test the-refusal-does-not-print-the-url
  "The URL can carry a token in its query, so the condition's report leaves it out; the URL is
still available from the condition's reader."
  (let ((url "file:///secret-token-4f2a"))
    (handler-case (progn (%plan url :linux) (fail "no condition was signalled"))
      (hyperion/desktop:unsupported-browser-url (e)
        (is (not (search "secret-token-4f2a" (princ-to-string e))))
        (is (string= url (hyperion/desktop:unsupported-browser-url-url e)))))))

(test open-in-browser-refuses-before-starting-anything
  "OPEN-IN-BROWSER itself, not only its plan: a refused URL signals before a program starts or
ShellExecuteW is called, so this is safe to run on every platform."
  (signals hyperion/desktop:unsupported-browser-url
    (hyperion/desktop::open-in-browser "file:///C:/Windows/System32/calc.exe")))
