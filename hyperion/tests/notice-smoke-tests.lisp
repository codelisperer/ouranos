;;;; notice-smoke-tests.lisp --- the notice region's htmx error script, run by a real browser with the vendored htmx (#980).
;;;;
;;;; hyperion/notice's script relies on what htmx 2 does with an error response: by default it
;;;; does not swap one, and it passes htmx:beforeSwap a detail whose shouldSwap says so. A unit
;;;; test of the script's text cannot show that. This page loads the vendored htmx and the
;;;; region, makes the requests below on load, and the test reads the DOM a headless Chrome or
;;;; Edge dumps, with the helpers of htmx-smoke-tests.lisp. It skips where no browser is found,
;;;; as that test does; the GitHub runners for all three operating systems have Chrome.
;;;;
;;;; The requests:
;;;; - a 422 whose body is a notice: the notice is shown, and its target is left alone;
;;;; - a 500 whose body is a server's own error page: the fixed :notice/failed message is shown;
;;;; - a request that gets no response (a refused connection): :notice/unreachable is shown;
;;;; - a 422 from inside data-hyperion-notices="off": nothing is shown;
;;;; - a 422 the page's own htmx:beforeSwap listener chooses to swap: it is swapped, and nothing
;;;;   is shown, because the script acts only where htmx would drop the response;
;;;; - a 200 that adds a success notice out of band with NOTICE-OOB.

(in-package #:hyperion/assets/tests)

(in-suite hyperion-assets)

(defun %notice-html (status body)
  (list status (list :content-type "text/html; charset=utf-8") (list body)))

(defun %notice-page ()
  (format nil "<!doctype html>
<html><head><meta charset=\"utf-8\"><script src=\"~A\"></script></head>
<body>
<script>
htmx.config.selfRequestsOnly = false;
document.addEventListener('htmx:beforeSwap', function (e) {
  if (e.detail.pathInfo.requestPath === '/n/422-mine') { e.detail.shouldSwap = true; e.detail.isError = false; }
});
</script>
~A
<p id=\"after-region\">after</p>
<div id=\"t422\" hx-get=\"/n/422\" hx-trigger=\"load\" hx-swap=\"innerHTML\">t422-untouched</div>
<div id=\"t500\" hx-get=\"/n/500\" hx-trigger=\"load\" hx-swap=\"innerHTML\">t500-untouched</div>
<div id=\"tdown\" hx-get=\"http://127.0.0.1:1/n/down\" hx-trigger=\"load\" hx-swap=\"innerHTML\">tdown-untouched</div>
<div data-hyperion-notices=\"off\"><div id=\"toff\" hx-get=\"/n/422-off\" hx-trigger=\"load\" hx-swap=\"innerHTML\">toff-untouched</div></div>
<div id=\"tmine\" hx-get=\"/n/422-mine\" hx-trigger=\"load\" hx-swap=\"innerHTML\">tmine-untouched</div>
<div id=\"tok\" hx-get=\"/n/ok\" hx-trigger=\"load\" hx-swap=\"innerHTML\">tok-untouched</div>
</body></html>"
          (assets:url :htmx)
          (spinneret:with-html-string (hyperion/notice:notice-region))))

(defun %notice (severity message)
  (spinneret:with-html-string (hyperion/notice:notice severity message)))

(defun %notice-app ()
  (router:to-app
   (router:router
    (assets:mount)
    (router:route :get "/notices" (lambda (env) (declare (ignore env)) (%notice-html 200 (%notice-page))))
    (router:route :get "/n/422" (lambda (env) (declare (ignore env))
                                  (%notice-html 422 (%notice :error "Name taken."))))
    (router:route :get "/n/500" (lambda (env) (declare (ignore env))
                                  (%notice-html 500 "<html><body><h1>Internal Server Error</h1></body></html>")))
    (router:route :get "/n/422-off" (lambda (env) (declare (ignore env))
                                      (%notice-html 422 (%notice :error "Off."))))
    (router:route :get "/n/422-mine" (lambda (env) (declare (ignore env))
                                       (%notice-html 422 "mine-swapped")))
    (router:route :get "/n/ok" (lambda (env) (declare (ignore env))
                                 (%notice-html 200 (format nil "ok-done~A"
                                                           (spinneret:with-html-string
                                                             (hyperion/notice:notice-oob :success "Saved.")))))))))

(defun %between (dom start end)
  "The text of DOM from START to END, or \"\" when either is missing."
  (let* ((a (search start dom))
         (b (and a (search end dom :start2 a))))
    (if (and a b) (subseq dom a b) "")))

(defun %count (needle haystack)
  (loop with start = 0 for at = (search needle haystack :start2 start)
        while at count t do (setf start (1+ at))))

(test the-notice-region-shows-htmx-error-responses-in-a-real-browser
  (let ((browser (%smoke-browser)))
    (if (null browser)
        (skip "No Chrome or Edge found; set HYPERION_SMOKE_BROWSER to run the notice page")
        (let ((app (%notice-app)) (port nil) (handler nil))
          (setf handler (ports:call-with-port
                         (lambda (p)
                           (prog1 (hyperion/server:start app :port p :host "127.0.0.1" :log nil)
                             (setf port p)))))
          (unwind-protect
               (let* ((dom (%run-browser browser (format nil "http://127.0.0.1:~D/notices" port)))
                      (alert (%between dom "id=\"hyperion-notices-alert\"" "id=\"hyperion-notices-status\""))
                      (status (%between dom "id=\"hyperion-notices-status\"" "id=\"after-region\""))
                      (failed (getf hyperion/notice::+english+ :notice/failed))
                      (unreachable (getf hyperion/notice::+english+ :notice/unreachable)))
                 (is (search "Name taken." alert) "a 422's notice is shown, in the assertive container: ~A" alert)
                 (is (equal "t422-untouched" (%element-text dom "t422")) "and its target is left alone")
                 (is (search failed alert) "a 500 with no notice in its body shows :notice/failed: ~A" alert)
                 (is (search unreachable alert) "a request with no response shows :notice/unreachable: ~A" alert)
                 (is (eql 3 (%count "data-hyperion-notice=\"error\"" alert))
                     "three error notices, and no more: ~A" alert)
                 (is (null (search "Off." dom)) "nothing is shown for an element under data-hyperion-notices=off")
                 (is (equal "mine-swapped" (%element-text dom "tmine"))
                     "a 422 the page's own listener swaps is swapped")
                 (is (null (search "mine-swapped" alert)) "and not shown as a notice")
                 (is (equal "ok-done" (%element-text dom "tok")) "a 200 is swapped as usual")
                 (is (search "Saved." status) "and its out-of-band notice is in the polite container: ~A" status)
                 (is (search "data-hyperion-notice=\"success\"" status) "~A" status))
            (ignore-errors (hyperion/server:stop handler))
            (is (ports:await-released port) "the port was still accepting after teardown"))))))
