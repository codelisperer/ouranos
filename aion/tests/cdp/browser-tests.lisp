;;;; browser-tests.lisp --- aion/cdp against a real headless Chrome or Edge (#1028).
;;;;
;;;; SKIPPED WHEN NO BROWSER IS FOUND, AND FAILED INSTEAD WHEN OURANOS_REQUIRE_BROWSER=1. CI sets
;;;; it, because the runners for all three operating systems have Chrome, so a skip there would
;;;; mean the driver was never run.

(in-package #:aion/cdp/tests)

(in-suite cdp)

(defun %browser-or-skip ()
  "The browser to run, or NIL after a skip, or a failure when OURANOS_REQUIRE_BROWSER is 1. On
Linux and macOS the default transport, the pipe, needs libuv, so a machine without it skips too."
  (let ((required (equal (uiop:getenv "OURANOS_REQUIRE_BROWSER") "1"))
        (exe (cdp:find-browser))
        (no-libuv #-win32 (handler-case (progn (aion/uv:ensure-available) nil)
                            (error (c) (princ-to-string c)))
                  #+win32 nil))
    (cond ((null exe)
           (if required
               (fail "No Chrome or Edge was found, and OURANOS_REQUIRE_BROWSER=1")
               (skip "No Chrome or Edge found; set OURANOS_BROWSER to run the browser checks"))
           nil)
          (no-libuv
           (if required
               (fail "libuv is not available for the pipe transport, and OURANOS_REQUIRE_BROWSER=1: ~A" no-libuv)
               (skip "libuv is not available for the pipe transport; run scripts/build-libuv.lisp"))
           nil)
          (t exe))))

(defparameter +test-page+
  "<!doctype html><html><head><meta charset='utf-8'><title>cdp</title></head><body>
<h1 id='h'>Hello, browser</h1>
<a id='link' href='/next' data-kind='plain'>next</a>
<ul><li>one</li><li>two</li><li>three</li></ul>
<button id='b' onclick='document.getElementById(\"n\").textContent = String(Number(document.getElementById(\"n\").textContent) + 1)'>add</button>
<span id='n'>0</span>
<input id='i'>
<script>
console.log('loaded', 7);
setTimeout(() => { const p = document.createElement('p'); p.id = 'late'; p.textContent = 'late'; document.body.appendChild(p); }, 200);
setTimeout(() => { throw new Error('thrown later'); }, 50);
</script>
</body></html>")

(defun %data-url (html)
  (format nil "data:text/html;base64,~A" (ws:base64-encode (ws:encode-utf8 html))))

(test a-headless-browser-runs-a-page
  (let ((exe (%browser-or-skip)))
    (when exe
      (cdp:with-browser (browser :executable exe :timeout 60)
        ;; The product name does not say headless under --headless=new, and the browser
        ;; returns its command line only when started with --enable-automation, which the driver
        ;; does not pass. So the operating system is asked what the process was started with.
        #-win32
        (let ((line (uiop:run-program (list "ps" "-o" "command=" "-p"
                                            (princ-to-string (cdp:browser-pid browser)))
                                      :output :string :ignore-error-status t)))
          (is (search "--headless=new" line) "the browser process was started headless: ~A" line)
          #+darwin (is (search "--use-mock-keychain" line) "and with the mock Keychain: ~A" line)
          #+linux (is (search "--password-store=basic" line) "and with the basic password store: ~A" line))
        (is (integerp (cdp:browser-pid browser)))
        (let ((page (cdp:new-page browser)))
          (is (search "HeadlessChrome" (cdp:evaluate page "navigator.userAgent"))
              "the page sees a headless browser")
          (cdp:navigate page (%data-url +test-page+))
          (is (equal "Hello, browser" (cdp:text-of page "#h")))
          (is (null (cdp:text-of page "#absent")))
          (is (= 3 (cdp:query page "li")))
          (is (equal "plain" (cdp:attribute-of page "#link" "data-kind")))
          (is (null (cdp:attribute-of page "#link" "data-none")))
          (cdp:click page "#b")
          (cdp:click page "#b")
          (is (equal "2" (cdp:text-of page "#n")) "two clicks reached the button")
          (signals cdp:element-not-found (cdp:click page "#absent"))
          (cdp:type-text page "#i" "typed text")
          (is (equal "typed text" (cdp:evaluate page "document.getElementById('i').value")))
          (is (cdp:wait-for page :selector "#late" :timeout 10))
          (signals cdp:cdp-timeout (cdp:wait-for page :selector "#never" :timeout 0.5))
          (signals cdp:evaluation-error (cdp:evaluate page "null.x"))
          (is (= 6 (cdp:evaluate page "Promise.resolve(6)")) "a promise is awaited")
          (cdp:set-viewport page 640 480)
          (is (= 640 (cdp:evaluate page "window.innerWidth")))
          (cdp:emulate-color-scheme page :dark)
          (is (eq t (cdp:evaluate page "matchMedia('(prefers-color-scheme: dark)').matches")))
          (cdp:emulate-color-scheme page :light)
          (is (eq nil (cdp:evaluate page "matchMedia('(prefers-color-scheme: dark)').matches")))
          (let ((png (cdp:screenshot page)))
            (is (equalp #(137 80 78 71 13 10 26 10) (subseq png 0 8)) "a PNG signature"))
          (is (> (length (cdp:screenshot page :full-page t)) 8))
          (let ((methods (mapcar #'cdp:event-method (cdp:drain-events page))))
            (is (member "Runtime.consoleAPICalled" methods :test #'equal)
                "the page's console.log was recorded")
            (is (member "Runtime.exceptionThrown" methods :test #'equal)
                "the page's uncaught exception was recorded")))))))

(test close-browser-ends-the-process-and-deletes-the-profile
  (let ((exe (%browser-or-skip)))
    (when exe
      (let* ((browser (cdp:launch-browser :executable exe :timeout 60))
             (process (aion/cdp::browser-process browser))
             (dir (aion/cdp::browser-directory browser)))
        (is (probe-file dir))
        (cdp:close-browser browser)
        (is (not (aion/cdp::%alive-p process)) "the browser process has ended")
        (is (null (probe-file dir)) "the temporary profile is gone")
        (is (null (cdp:close-browser browser)) "a second close does nothing")))))

(defun %launch-and-ask (exe transport)
  "Launch EXE with TRANSPORT, run one page, and return whether the profile had a
DevToolsActivePort while it ran, and the product the browser reported."
  (cdp:with-browser (browser :executable exe :timeout 60 :transport transport)
    (let ((page (cdp:new-page browser)))
      (cdp:navigate page (%data-url "<p id='p'>piped</p>"))
      (is (equal "piped" (cdp:text-of page "#p")) "a page runs over ~S" transport))
    (values (and (probe-file (merge-pathnames "profile/DevToolsActivePort"
                                              (aion/cdp::browser-directory browser)))
                 t)
            (cdp:browser-version browser))))

(test the-default-transport-is-the-pipe-and-opens-no-port
  (let ((exe (%browser-or-skip)))
    (when exe
      (is (eq :pipe aion/cdp::+default-transport+))
      (multiple-value-bind (port-file product) (%launch-and-ask exe :pipe)
        (is (null port-file) "a browser on the pipe writes no DevToolsActivePort")
        (is (stringp product))))))

(test the-port-transport-still-works
  (let ((exe (%browser-or-skip)))
    (when exe
      (multiple-value-bind (port-file product) (%launch-and-ask exe :port)
        (is-true port-file "a browser on the port writes DevToolsActivePort")
        (is (stringp product))))))

(test a-browser-that-exits-at-once-is-reported
  ;; A program that exits at once, standing in for a browser that crashes on start.
  (let ((exe #+win32 (or (ignore-errors (aion/windows:find-executable "whoami")) "C:/Windows/System32/whoami.exe")
             #-win32 (or (probe-file "/usr/bin/false") (probe-file "/bin/false"))))
    (dolist (transport '(:pipe :port))
      (signals cdp:browser-exited
        (cdp:launch-browser :executable (uiop:native-namestring exe) :timeout 20
                            :transport transport)))))

(defun %exit-of (exe transport)
  "The BROWSER-EXITED that launching EXE on TRANSPORT signals, or NIL if it signals none."
  (handler-case (progn (cdp:close-browser (cdp:launch-browser :executable exe :timeout 20
                                                              :transport transport))
                       nil)
    (cdp:browser-exited (c) c)))

#-win32
(test a-browser-killed-by-a-signal-is-reported-as-killed-not-as-exiting-with-code-0
  ;; #1305: a browser that ended on CI was reported as exiting with code 0, with no output.
  ;; libuv reports a process killed by a signal with an exit status of 0, and that status was
  ;; all the report read, so a browser killed by the system read as one that chose to exit.
  ;; The stand-in here kills itself with SIGKILL. Control: a program that exits with status 1
  ;; is reported with its code and no signal, on both transports.
  (let* ((dir (aion/fs:make-temporary-directory "cdp-killed"))
         (script (merge-pathnames "killed-browser" dir)))
    (unwind-protect
         (progn
           (with-open-file (out script :direction :output :if-exists :supersede)
             (format out "#!/bin/sh~%kill -KILL $$~%"))
           (sb-posix:chmod (uiop:native-namestring script) #o700)
           (dolist (transport '(:pipe :port))
             (let ((c (%exit-of (uiop:native-namestring script) transport)))
               (is-true c "~A: the stand-in was not reported as exited" transport)
               (when c
                 (is (eql 9 (cdp:browser-exited-signal c)) "~A: signal ~S" transport
                     (cdp:browser-exited-signal c))
                 (is (null (cdp:browser-exited-code c)) "~A: code ~S" transport
                     (cdp:browser-exited-code c))
                 (is-true (search "killed by signal 9" (princ-to-string c))
                          "~A: ~A" transport c)
                 (is-true (search "wrote nothing to standard error" (princ-to-string c))
                          "~A: ~A" transport c))))
           (let ((false (uiop:native-namestring (or (probe-file "/usr/bin/false")
                                                    (probe-file "/bin/false")))))
             (dolist (transport '(:pipe :port))
               (let ((c (%exit-of false transport)))
                 (is-true c "control, ~A: false was not reported as exited" transport)
                 (when c
                   (is (eql 1 (cdp:browser-exited-code c)) "control, ~A: code ~S" transport
                       (cdp:browser-exited-code c))
                   (is (null (cdp:browser-exited-signal c)) "control, ~A: signal ~S" transport
                       (cdp:browser-exited-signal c))
                   (is-true (search "exited with code 1" (princ-to-string c))
                            "control, ~A: ~A" transport c))))))
      (aion/fs:delete-tree dir))))
