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
;;;; - a 200 that adds a success notice out of band with NOTICE-OOB;
;;;; - a request that times out: :notice/timeout is shown. htmx 2.0.11 fires htmx:timeout from
;;;;   xhr.ontimeout. A server that never answers cannot time a request out here, because headless
;;;;   Chrome's --virtual-time-budget stops virtual time, and so the XHR's timeout timer, while a
;;;;   request is in flight. So the page's own script makes the XHR for /n/timeout call its
;;;;   ontimeout handler instead of sending, and htmx's handler does the rest;
;;;; - a Dismiss click on a notice the page was written with removes it.
;;;;
;;;; The page is served with Content-Security-Policy: script-src 'nonce-smoke980', and every script
;;;; on it carries that nonce, the region's through NOTICE-REGION :NONCE. So everything above also
;;;; shows it works under a nonce policy; an inline onclick on the Dismiss button would be refused
;;;; there (the hub's review of #1004).

(in-package #:hyperion/assets/tests)

(in-suite hyperion-assets)

(defun %notice-html (status body)
  (list status (list :content-type "text/html; charset=utf-8") (list body)))

(defparameter +notice-nonce+ "smoke980")

(defun %notice-page ()
  (format nil "<!doctype html>
<html><head><meta charset=\"utf-8\"><script nonce=\"~A\" src=\"~A\"></script></head>
<body>
<script nonce=\"~A\">
htmx.config.selfRequestsOnly = false;
(function () {
  var open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, url) { this.smokeUrl = String(url); return open.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function () {
    var x = this;
    if (x.smokeUrl.indexOf('/n/timeout') >= 0) { setTimeout(function () { x.ontimeout(); }, 0); return; }
    return send.apply(this, arguments);
  };
})();
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
<div id=\"ttimeout\" hx-get=\"/n/timeout\" hx-trigger=\"load\" hx-swap=\"innerHTML\">ttimeout-untouched</div>
<script nonce=\"~A\">
document.querySelector('#hyperion-notices-status .hyperion-notice-dismiss').click();
</script>
</body></html>"
          +notice-nonce+ (assets:url :htmx) +notice-nonce+
          (spinneret:with-html-string
            (hyperion/notice:notice-region :nonce +notice-nonce+
                                           :notices '((:warning "Dismiss this."))))
          +notice-nonce+))

(defun %notice (severity message)
  (spinneret:with-html-string (hyperion/notice:notice severity message)))

(defun %notice-app ()
  (router:to-app
   (router:router
    (assets:mount)
    (router:route :get "/notices"
                  (lambda (env)
                    (declare (ignore env))
                    (list 200 (list :content-type "text/html; charset=utf-8"
                                    :content-security-policy
                                    (format nil "script-src 'nonce-~A'" +notice-nonce+))
                          (list (%notice-page)))))
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
                      (unreachable (getf hyperion/notice::+english+ :notice/unreachable))
                      (timeout (getf hyperion/notice::+english+ :notice/timeout)))
                 (is (search "Name taken." alert) "a 422's notice is shown, in the assertive container: ~A" alert)
                 (is (equal "t422-untouched" (%element-text dom "t422")) "and its target is left alone")
                 (is (search failed alert) "a 500 with no notice in its body shows :notice/failed: ~A" alert)
                 (is (search unreachable alert) "a request with no response shows :notice/unreachable: ~A" alert)
                 (is (search timeout alert) "a request that timed out shows :notice/timeout: ~A" alert)
                 (is (equal "ttimeout-untouched" (%element-text dom "ttimeout")) "and its target is left alone")
                 (is (eql 4 (%count "data-hyperion-notice=\"error\"" alert))
                     "four error notices, and no more: ~A" alert)
                 (is (null (search "Dismiss this." dom))
                     "a Dismiss click removed its notice, under a nonce Content-Security-Policy: ~A" status)
                 (is (null (search "Off." dom)) "nothing is shown for an element under data-hyperion-notices=off")
                 (is (equal "mine-swapped" (%element-text dom "tmine"))
                     "a 422 the page's own listener swaps is swapped")
                 (is (null (search "mine-swapped" alert)) "and not shown as a notice")
                 (is (equal "ok-done" (%element-text dom "tok")) "a 200 is swapped as usual")
                 (is (search "Saved." status) "and its out-of-band notice is in the polite container: ~A" status)
                 (is (search "data-hyperion-notice=\"success\"" status) "~A" status))
            (ignore-errors (hyperion/server:stop handler))
            (is (ports:await-released port) "the port was still accepting after teardown"))))))
