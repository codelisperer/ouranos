;;;; htmx-smoke-tests.lisp --- the vendored htmx, run by a real browser against a real server (#717).
;;;;
;;;; The rest of this suite proves the bytes of htmx.min.js are the pinned ones and arrive over
;;;; HTTP intact. Neither says that the file, run by a browser, does what hyperion's pages rely
;;;; on. A version bump can keep every byte check green and still change behaviour: htmx 2
;;;; sends the parameters of a DELETE in the query string, where 1.9.12 sent them in the body.
;;;;
;;;; So this file serves a page that loads the vendored htmx, runs it in a headless Chrome or
;;;; Edge with --dump-dom, and reads the resulting DOM. The page exercises the attributes the
;;;; tree and its apps use most: a load trigger with an outerHTML swap, hx-target with an
;;;; innerHTML swap, an out-of-band swap, the HX-Trigger response header, a revealed trigger,
;;;; polling, and where an hx-delete sends its parameters.
;;;;
;;;; SKIPS, NOT FAILURES, WHEN NO BROWSER IS FOUND. The gate runs on machines with no browser,
;;;; and the GitHub runners for all three operating systems have Chrome installed, so CI is
;;;; where this runs. HYPERION_SMOKE_BROWSER names a browser executable to use instead of the
;;;; search below.

(in-package #:hyperion/assets/tests)

(in-suite hyperion-assets)

(defparameter +smoke-budget+ 5000
  "Milliseconds of virtual time the browser runs the page for before dumping the DOM. Virtual
time does not advance while a request is pending, so this bounds the page's timers (the poll),
not the server's speed.")

(defparameter +smoke-timeout+ 90
  "Seconds of real time the browser may take before the test kills it and fails.")

(defun %on-path (name)
  "The first file called NAME in a directory on PATH, or NIL."
  (dolist (dir (uiop:split-string (or (uiop:getenv "PATH") "")
                                  :separator (if (uiop:os-windows-p) ";" ":")))
    (let ((p (and (plusp (length dir))
                  (probe-file (concatenate 'string (string-right-trim "/\\" dir) "/" name)))))
      (when p (return p)))))

(defun %smoke-browser ()
  "The browser executable to run, as a native namestring, or NIL when there is none."
  (let ((override (uiop:getenv "HYPERION_SMOKE_BROWSER")))
    (if (and override (plusp (length override)))
        override
        (let ((found (or (some #'%on-path '("google-chrome" "google-chrome-stable" "chromium"
                                            "chromium-browser" "microsoft-edge"))
                         (some #'probe-file
                               '(#+darwin "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                                 #+darwin "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
                                 #+win32 "C:/Program Files/Google/Chrome/Application/chrome.exe"
                                 #+win32 "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe"
                                 #+win32 "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe")))))
          (and found (uiop:native-namestring found))))))

(defvar *smoke-polls* (list 0)
  "How many times the page's poll has reached the server, in the car, for ATOMIC-INCF.")

(defun %html (body &rest headers)
  (list 200 (list* :content-type "text/html; charset=utf-8" headers) (list body)))

(defun %smoke-page ()
  (format nil "<!doctype html>
<html><head><meta charset=\"utf-8\"><script src=\"~A\"></script></head>
<body>
<p id=\"ver\">no-htmx</p>
<p id=\"ev\">no-event</p>
<div id=\"a\" hx-get=\"/frag/a\" hx-trigger=\"load\" hx-swap=\"outerHTML\">waiting-a</div>
<div hx-get=\"/frag/b\" hx-trigger=\"load\" hx-target=\"#b\" hx-swap=\"innerHTML\"></div>
<div id=\"b\">waiting-b</div>
<div id=\"oob\">waiting-oob</div>
<div id=\"r\" hx-get=\"/frag/r\" hx-trigger=\"revealed\" hx-swap=\"innerHTML\">waiting-r</div>
<div id=\"p\" hx-get=\"/frag/p\" hx-trigger=\"every 1s\" hx-swap=\"innerHTML\">poll-0</div>
<div id=\"d\" hx-delete=\"/item\" hx-vals='{\"k\": \"v\"}' hx-trigger=\"load\" hx-swap=\"innerHTML\">waiting-d</div>
<script>
document.body.addEventListener(\"smoke-event\", function () {
  document.getElementById(\"ev\").textContent = \"event-ok\";
});
if (window.htmx) { document.getElementById(\"ver\").textContent = \"htmx-\" + htmx.version; }
</script>
</body></html>"
          (assets:url :htmx)))

(defun %smoke-app ()
  (router:to-app
   (router:router
    (assets:mount)
    (router:route :get "/smoke" (lambda (env) (declare (ignore env)) (%html (%smoke-page))))
    (router:route :get "/frag/a"
                  (lambda (env) (declare (ignore env))
                    (%html "<div id=\"a\">swapped-outer</div>" :hx-trigger "smoke-event")))
    (router:route :get "/frag/b"
                  (lambda (env) (declare (ignore env))
                    (%html "into-target<div id=\"oob\" hx-swap-oob=\"true\">oob-done</div>")))
    (router:route :get "/frag/r"
                  (lambda (env) (declare (ignore env)) (%html "revealed-ok")))
    (router:route :get "/frag/p"
                  (lambda (env) (declare (ignore env))
                    (%html (format nil "poll-~D" (sb-ext:atomic-incf (car *smoke-polls*))))))
    (router:route :delete "/item"
                  (lambda (env)
                    (%html (format nil "delete query=~A body=~D"
                                   (or (getf env :query-string) "")
                                   (length (or (http:body-string env) "")))))))))

(defun %run-browser (browser url)
  "Run BROWSER headless on URL and return what --dump-dom printed, or signal on a timeout."
  (let* ((profile (uiop:ensure-directory-pathname
                   (merge-pathnames (format nil "hyperion-smoke-~36R/" (random (expt 36 8)
                                                                               (make-random-state t)))
                                    (uiop:temporary-directory))))
         (out (merge-pathnames "dom.html" profile)))
    (ensure-directories-exist profile)
    (unwind-protect
         (let ((process (sb-ext:run-program
                         browser
                         (list "--headless" "--disable-gpu" "--no-sandbox" "--no-first-run"
                               "--no-default-browser-check"
                               (format nil "--user-data-dir=~A" (uiop:native-namestring profile))
                               (format nil "--virtual-time-budget=~D" +smoke-budget+)
                               "--dump-dom" url)
                         :search t :wait nil :input nil :error nil
                         :output (uiop:native-namestring out) :if-output-exists :supersede)))
           (loop with deadline = (+ (get-universal-time) +smoke-timeout+)
                 while (sb-ext:process-alive-p process)
                 do (when (> (get-universal-time) deadline)
                      (sb-ext:process-kill process 9)
                      (error "~A did not finish within ~D seconds" browser +smoke-timeout+))
                    (sleep 0.2))
           (uiop:read-file-string out))
      (uiop:delete-directory-tree profile :validate t :if-does-not-exist :ignore))))

(defmacro %with-smoke-server ((port) &body body)
  "Run BODY against a live server for the smoke page, with PORT bound to its port."
  (let ((handler (gensym "HANDLER")))
    `(let* ((app (%smoke-app))
            (,port nil)
            (,handler (ports:call-with-port
                       (lambda (p)
                         (prog1 (hyperion/server:start app :port p :host "127.0.0.1" :log nil)
                           (setf ,port p))))))
       (unwind-protect (progn ,@body)
         (ignore-errors (hyperion/server:stop ,handler))
         (is (ports:await-released ,port)
             "the port was still accepting after teardown")))))

(defun %element-text (dom id)
  "The text between the element with ID's opening tag and the next tag, or NIL."
  (let* ((key (format nil "id=\"~A\"" id))
         (at (search key dom))
         (open-end (and at (position #\> dom :start at)))
         (close (and open-end (position #\< dom :start open-end))))
    (and close (subseq dom (1+ open-end) close))))

(test the-vendored-htmx-swaps-in-a-real-browser
  (let ((browser (%smoke-browser)))
    (if (null browser)
        (skip "No Chrome or Edge found; set HYPERION_SMOKE_BROWSER to run the htmx smoke page")
        (progn
          (setf *smoke-polls* (list 0))
          (%with-smoke-server (port)
            (let ((dom (%run-browser browser (format nil "http://127.0.0.1:~D/smoke" port))))
              (is (equal (format nil "htmx-~A" (assets:asset-version (assets:asset :htmx)))
                         (%element-text dom "ver"))
                  "the page ran the vendored htmx: ~S" (%element-text dom "ver"))
              (is (equal "swapped-outer" (%element-text dom "a")) "load + outerHTML")
              (is (equal "into-target" (%element-text dom "b")) "hx-target + innerHTML")
              (is (equal "oob-done" (%element-text dom "oob")) "hx-swap-oob")
              (is (equal "event-ok" (%element-text dom "ev")) "the HX-Trigger response header")
              (is (equal "revealed-ok" (%element-text dom "r")) "the revealed trigger")
              ;; A poll can reach the server after the DOM is dumped, so the page shows an
              ;; answer the server gave, not necessarily the last one.
              (let* ((text (%element-text dom "p"))
                     (n (and text (> (length text) 5) (parse-integer text :start 5 :junk-allowed t))))
                (is (and n (<= 2 n (car *smoke-polls*)))
                    "a poll's answer is on the page: ~S of ~D" text (car *smoke-polls*)))
              ;; The behaviour hyperion/csrf's hx-delete header exists for: htmx 2 puts a
              ;; DELETE's parameters in the URL and sends no body.
              (is (equal "delete query=k=v body=0" (%element-text dom "d"))
                  "hx-delete: ~S" (%element-text dom "d"))))))))
