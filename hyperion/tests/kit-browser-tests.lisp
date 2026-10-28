;;;; kit-browser-tests.lisp --- hyperion/kit's dialogs and notices, run by a real browser (#981)
;;;;
;;;; Focus and Escape exist only in a browser, so this file serves a page with each kind of
;;;; dialog and an undo notice, runs it in the same headless Chrome or Edge as the htmx smoke
;;;; page, and reads back what the page recorded. A script on the page presses the controls
;;;; in order and writes what it saw into #results after each step: whether a dialog is open,
;;;; which element has focus, the order of the confirm's buttons, and what reached the server.
;;;;
;;;; Escape is sent as a keydown event from the page's own script. A browser does not run its
;;;; built-in cancel for an event a script made, so this checks hyperion's Escape handler,
;;;; which is the one every route to closing goes through.
;;;;
;;;; Each opener is clicked with nothing focused, as in Safari and Firefox on macOS, where
;;;; clicking a button does not focus it. Chrome returns focus on close to whatever had it when
;;;; the dialog opened, so a focused opener would get focus back from Chrome alone, and the
;;;; test could not see whether DIALOG-JS returns it. Where focus went is read in the step
;;;; after the one that closed the dialog, so a focus change made by the close event, which
;;;; the browser fires as a separate task, is counted too.
;;;;
;;;; Like the smoke page, it SKIPS when no browser is found.

(in-package #:hyperion/assets/tests)

(in-suite hyperion-assets)

(defparameter *kit-scenario* "
var r = [];
function log(k, v) { r.push(k + '=' + v); document.getElementById('results').textContent = r.join(' '); }
function act() { var a = document.activeElement; return a ? (a.id || a.tagName.toLowerCase()) : 'none'; }
function esc() { document.activeElement.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true, cancelable: true})); }
function byId(id) { return document.getElementById(id); }
function press(id) { if (document.activeElement) { document.activeElement.blur(); } byId(id).click(); }
function notices() { return byId('hy-notices').querySelectorAll('[data-hy-notice]').length; }
var steps = [
  function () { press('open-create');
    log('create-open', byId('create').open); log('create-focus', act()); esc();
    log('create-esc-closed', !byId('create').open); },
  function () { log('create-esc-return', act());
    press('open-create'); byId('create').querySelector('[data-hy-dialog-close]').click();
    log('create-x-closed', !byId('create').open); },
  function () { log('create-x-return', act()); },
  function () { press('open-loaded'); log('loaded-waits', !byId('loaded').open); },
  function () { log('loaded-open', byId('loaded').open); log('loaded-focus', act()); esc();
    log('loaded-esc-closed', !byId('loaded').open); },
  function () { log('loaded-return', act()); },
  function () { press('open-confirm'); log('confirm-focus', act());
    var b = byId('confirm').querySelectorAll('form button');
    log('confirm-order', b[0].id + ',' + b[b.length - 1].id); byId('confirm-action').click(); },
  function () { log('confirm-closed', !byId('confirm').open); log('confirm-return', act());
    log('confirm-posted', byId('posted').textContent); },
  function () { byId('trash').click(); },
  function () { log('notice-count', notices()); log('notice-region-role', byId('hy-notices').getAttribute('role'));
    var n = byId('hy-notices').querySelector('[data-hy-dismiss]'); if (n) { n.click(); }
    log('notice-dismissed', notices()); byId('trash').click(); },
  function () { var u = byId('hy-notices').querySelector('.hy-undo'); if (u) { u.click(); } },
  function () { log('undo-removed', notices()); log('undone', byId('posted').textContent);
    log('htmx', !!window.htmx); log('done', 'yes'); }
];
var i = 0;
function next() {
  if (i < steps.length) {
    try { steps[i++](); } catch (e) { log('error-' + i, e.message.replace(/ /g, '_')); }
    setTimeout(next, 300);
  }
}
document.addEventListener('DOMContentLoaded', function () { setTimeout(next, 100); });
"
  "The steps the kit page runs. Each step's results are logged as key=value, read back by
%KIT-RESULTS.")

(defun %kit-page ()
  (spinneret:with-html-string
    (:doctype)
    (:html
      (:head (:meta :charset "utf-8")
             (:script :src (assets:url :htmx))
             (:script (:raw (hyperion/kit/dialog:dialog-js))))
      (:body
        (hyperion/kit/dialog:dialog-opener "create" "New draft" :id "open-create")
        (hyperion/kit/dialog:dialog
         "create" "New draft"
         :body (lambda ()
                 (spinneret:with-html
                   (:form (:input :id "create-name" :name "name" :autofocus t)
                          (:input :id "create-other" :name "other")))))
        (hyperion/kit/dialog:dialog-opener "loaded" "Load and open" :id "open-loaded"
                                           :href "/frag/dialog-body")
        (hyperion/kit/dialog:dialog "loaded" "Loaded")
        (hyperion/kit/dialog:dialog-opener "confirm" "Delete" :id "open-confirm")
        (hyperion/kit/dialog:confirm-dialog "confirm" "Delete 3 drafts?" "They go to the trash."
                                            :action-href "/confirm"
                                            :action-label "Delete 3 drafts"
                                            :hx-target "#posted" :hx-swap "innerHTML")
        (:button :type "button" :id "trash" :hx-post "/trash" :hx-swap "none" "Trash")
        (:p :id "posted" "nothing")
        (hyperion/kit/dialog:notice-region)
        (:pre :id "results")
        (:script (:raw *kit-scenario*))))))

(defun %kit-app ()
  (router:to-app
   (router:router
    (assets:mount)
    (router:route :get "/kit" (lambda (env) (declare (ignore env)) (%html (%kit-page))))
    (router:route :get "/frag/dialog-body"
                  (lambda (env) (declare (ignore env))
                    (%html "<form><input id=\"loaded-field\" name=\"x\" autofocus></form>")))
    (router:route :post "/confirm"
                  (lambda (env) (declare (ignore env)) (%html "deleted")))
    (router:route :post "/trash"
                  (lambda (env) (declare (ignore env))
                    (%html (spinneret:with-html-string
                             (hyperion/kit/dialog:undo-notice "Moved to trash"
                                                              :undo-href "/undo" :oob t)))))
    (router:route :post "/undo"
                  (lambda (env) (declare (ignore env))
                    (%html "<p id=\"posted\" hx-swap-oob=\"true\">restored</p>"))))))

(defun %kit-results (dom)
  "The key=value pairs the page logged in #results, as an alist of strings."
  (let* ((at (search "id=\"results\"" dom))
         (start (and at (1+ (position #\> dom :start at))))
         (end (and start (position #\< dom :start start))))
    (when end
      (loop for pair in (uiop:split-string (subseq dom start end) :separator " ")
            for eq = (position #\= pair)
            when eq collect (cons (subseq pair 0 eq) (subseq pair (1+ eq)))))))

(test the-kit-dialogs-and-notices-in-a-real-browser
  "Opening focuses the autofocus field, Escape and the close button close, and focus goes
back to the opener; a dialog loaded by htmx opens after its contents arrive; the confirm
starts on Cancel with the action last, closes when its request succeeds; the undo notice
arrives in the status region, and dismiss and undo remove it."
  (let ((browser (%smoke-browser)))
    (if (null browser)
        (skip "No Chrome or Edge found; set HYPERION_SMOKE_BROWSER to run the kit page")
        (let* ((app (%kit-app))
               (port nil)
               (handler (ports:call-with-port
                         (lambda (p)
                           (prog1 (hyperion/server:start app :port p :host "127.0.0.1" :log nil)
                             (setf port p))))))
          (unwind-protect
               (let* ((dom (%run-browser browser (format nil "http://127.0.0.1:~D/kit" port)))
                      (results (%kit-results dom)))
                 (flet ((saw (key) (cdr (assoc key results :test #'string=))))
                   (is (equal "yes" (saw "done")) "the page ran every step: ~S" results)
                   (is (null (remove-if-not (lambda (p) (search "error" (car p))) results))
                       "a step threw: ~S" results)
                   (is (equal "true" (saw "create-open")))
                   (is (equal "create-name" (saw "create-focus")) "autofocus on opening")
                   (is (equal "true" (saw "create-esc-closed")) "Escape closes")
                   (is (equal "open-create" (saw "create-esc-return")) "focus back after Escape")
                   (is (equal "true" (saw "create-x-closed")) "the close button closes")
                   (is (equal "open-create" (saw "create-x-return")) "focus back after the button")
                   (is (equal "true" (saw "loaded-waits")) "an htmx opener waits for the contents")
                   (is (equal "true" (saw "loaded-open")) "and then opens")
                   (is (equal "loaded-field" (saw "loaded-focus")) "focusing the loaded field")
                   (is (equal "true" (saw "loaded-esc-closed")))
                   (is (equal "open-loaded" (saw "loaded-return")))
                   (is (equal "confirm-cancel" (saw "confirm-focus")) "the confirm starts on Cancel")
                   (is (equal "confirm-cancel,confirm-action" (saw "confirm-order"))
                       "Cancel first, the action last")
                   (is (equal "true" (saw "confirm-closed")) "closed after its request succeeded")
                   (is (equal "open-confirm" (saw "confirm-return")))
                   (is (equal "deleted" (saw "confirm-posted")))
                   (is (equal "1" (saw "notice-count")) "the notice arrived out of band")
                   (is (equal "status" (saw "notice-region-role")))
                   (is (equal "0" (saw "notice-dismissed")) "dismiss removes it")
                   (is (equal "0" (saw "undo-removed")) "undo replaces it with the response")
                   (is (equal "restored" (saw "undone")))
                   (is (equal "true" (saw "htmx")) "htmx is still loaded")))
            (ignore-errors (hyperion/server:stop handler))
            (is (ports:await-released port) "the port was still accepting after teardown"))))))
