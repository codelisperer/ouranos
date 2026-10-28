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
    log('confirm-order', b[0].id + ',' + b[b.length - 1].id);
    byId('confirm-action').click(); byId('confirm-action').click(); },
  function () { log('confirm-closed', !byId('confirm').open); log('confirm-return', act());
    log('confirm-posted', byId('posted').textContent); },
  function () { byId('trash').click(); },
  function () { log('notice-count', notices()); log('notice-region-role', byId('hy-notices').getAttribute('role'));
    var n = byId('hy-notices').querySelector('[data-hy-dismiss]'); if (n) { n.click(); }
    log('notice-dismissed', notices()); byId('trash').click(); },
  function () { var u = byId('hy-notices').querySelector('.hy-undo'); if (u) { u.click(); u.click(); } },
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
  "The page's routes. /confirm and /undo answer with how many times each has been posted, so the
page shows a second post of a double click."
  (let ((confirms 0) (undos 0))
    (router:to-app
     (router:router
      (assets:mount)
      (router:route :get "/kit" (lambda (env) (declare (ignore env)) (%html (%kit-page))))
      (router:route :get "/frag/dialog-body"
                    (lambda (env) (declare (ignore env))
                      (%html "<form><input id=\"loaded-field\" name=\"x\" autofocus></form>")))
      (router:route :post "/confirm"
                    (lambda (env) (declare (ignore env)) (%html (format nil "deleted-~D" (incf confirms)))))
      (router:route :post "/trash"
                    (lambda (env) (declare (ignore env))
                      (%html (spinneret:with-html-string
                               (hyperion/kit/dialog:undo-notice "Moved to trash"
                                                                :undo-href "/undo" :oob t)))))
      (router:route :post "/undo"
                    (lambda (env) (declare (ignore env))
                      (%html (format nil "<p id=\"posted\" hx-swap-oob=\"true\">restored-~D</p>"
                                     (incf undos)))))))))

(defun %unescape (text)
  "TEXT with the character references a DOM dump writes in text turned back into characters."
  (loop for (from to) in '(("&lt;" "<") ("&gt;" ">") ("&quot;" "\"") ("&#39;" "'") ("&amp;" "&"))
        do (setf text (uiop:frob-substrings text (list from) to)))
  text)

(defun %kit-results (dom)
  "The key=value pairs the page logged in #results, as an alist of strings."
  (let* ((at (search "id=\"results\"" dom))
         (start (and at (1+ (position #\> dom :start at))))
         (end (and start (position #\< dom :start start))))
    (when end
      (loop for pair in (uiop:split-string (%unescape (subseq dom start end)) :separator " ")
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
                   (is (equal "deleted-1" (saw "confirm-posted")) "a double click posts once: ~S"
                       (saw "confirm-posted"))
                   (is (equal "1" (saw "notice-count")) "the notice arrived out of band")
                   (is (equal "status" (saw "notice-region-role")))
                   (is (equal "0" (saw "notice-dismissed")) "dismiss removes it")
                   (is (equal "0" (saw "undo-removed")) "undo replaces it with the response")
                   (is (equal "restored-1" (saw "undone"))
                       "a double click on Undo posts once, because htmx drops a second request from a button whose first is in flight: ~S"
                       (saw "undone"))
                   (is (equal "true" (saw "htmx")) "htmx is still loaded")))
            (ignore-errors (hyperion/server:stop handler))
            (is (ports:await-released port) "the port was still accepting after teardown"))))))

;;; --- the list toolbar and the properties panel --------------------------------------

(defparameter *kit-list-spec*
  (hyperion/list:make-list-spec :id "drafts"
                                :sorts '((:title :column :title)
                                         (:updated :column :id :direction :desc))
                                :tiebreak :id
                                :filters '((:q :text t) (:status :values ("draft" "sent")))
                                :hx-target "#drafts"))

(defparameter *kit-list-start* "sort=updated&dir=asc"
  "The query the list page is first loaded with. It names a direction, so the test can see the
toolbar drop it when the sort key changes.")

(defparameter *kit-drafts*
  '((1 "Memo to staff" "draft") (2 "Meeting notes" "sent") (3 "Menu" "sent") (4 "Budget" "draft")))

(defun %kit-list-section (state)
  "The element the list's requests replace: the toolbar, then the rows."
  (let* ((q (hyperion/list:filter-value state :q))
         (status (hyperion/list:filter-value state :status))
         (rows (remove-if-not (lambda (d) (and (or (null q) (search q (second d)))
                                               (or (null status) (equal status (third d)))))
                              *kit-drafts*))
         (rows (if (eq :title (hyperion/list:list-state-sort state))
                   (sort (copy-list rows) #'string< :key #'second)
                   rows)))
    (spinneret:with-html-string
      (:section :id "drafts"
        (hyperion/kit/toolbar:list-toolbar state :search :q
                                           :filters '((:status "Status"))
                                           :sorts '((:title "Title") (:updated "Updated")))
        (:table
          (:tbody
            (dolist (d rows)
              (let ((href (format nil "/kit/panel/~D" (first d))))
                (:tr :attrs (hyperion/kit/panel:selectable-row (first d) href)
                  (:td (hyperion/kit/panel:row-activator (first d) href (second d)))
                  ;; A control of the row's own, which must not open the panel.
                  (:td (:button :type "button" :id (format nil "star-~D" (first d)) "Star")))))))))))

(defparameter *kit-list-scenario* "
var r = [];
function log(k, v) { r.push(k + '=' + v); document.getElementById('results').textContent = r.join(' '); }
function act() { var a = document.activeElement; return a ? (a.id || a.tagName.toLowerCase()) : 'none'; }
function byId(id) { return document.getElementById(id); }
function q(sel) { return document.querySelector(sel); }
function rows() { return document.querySelectorAll('#drafts tr').length; }
function panelTitle() { var t = q('#hy-panel h2'); return t ? t.textContent.replace(/ /g, '_') : 'none'; }
function current() { var c = q('[data-hy-row][aria-current=true]'); return c ? c.id : 'none'; }
function key(el, k) { el.dispatchEvent(new KeyboardEvent('keydown', {key: k, bubbles: true, cancelable: true})); }
function pick(sel, v) { var s = q(sel); s.value = v; s.dispatchEvent(new Event('change', {bubbles: true})); }
var steps = [
  function () { log('start-rows', rows()); var s = byId('hy-toolbar-search'); s.focus(); s.value = 'Me';
    s.dispatchEvent(new Event('input', {bubbles: true})); },
  function () { },
  function () { log('search-url', location.search); log('search-rows', rows());
    log('search-focus', act()); log('search-value', byId('hy-toolbar-search').value);
    pick('select[name=status]', 'sent'); },
  function () { log('status-url', location.search); log('status-rows', rows()); pick('select[name=sort]', 'title'); },
  function () { log('sort-url', location.search); log('sort-first', q('#drafts tr td').textContent.trim().replace(/ /g, '_'));
    pick('select[name=status]', ''); },
  function () { log('all-url', location.search); byId('row-2').click(); },
  function () { log('click-panel', panelTitle()); log('click-current', current());
    log('row-tabindex', byId('row-1').getAttribute('tabindex'));
    byId('row-1-open').focus(); byId('row-1-open').click(); },
  function () { log('button-panel', panelTitle()); log('button-current', current());
    q('#hy-panel [data-hy-panel-close]').focus(); key(document.activeElement, 'Escape');
    log('esc-empty', !q('#hy-panel .hy-properties')); log('esc-focus', act()); byId('row-2').click(); },
  function () { q('#hy-panel [data-hy-panel-close]').click();
    log('x-empty', !q('#hy-panel .hy-properties')); log('x-focus', act()); byId('star-3').click(); },
  function () { log('star-empty', !q('#hy-panel .hy-properties')); log('star-current', current());
    log('htmx', !!window.htmx); log('done', 'yes'); }
];
var i = 0;
function next() {
  if (i < steps.length) {
    try { steps[i++](); } catch (e) { log('error-' + i, e.message.replace(/ /g, '_')); }
    setTimeout(next, 400);
  }
}
document.addEventListener('DOMContentLoaded', function () { setTimeout(next, 100); });
"
  "The steps the list page runs, logged as key=value for %KIT-RESULTS. The search waits two
steps, for the toolbar's 300ms delay and then the response.")

(defun %kit-list-page (state)
  (spinneret:with-html-string
    (:doctype)
    (:html
      (:head (:meta :charset "utf-8")
             (:script :src (assets:url :htmx))
             (:script (:raw (hyperion/kit/toolbar:toolbar-js)))
             (:script (:raw (hyperion/kit/panel:panel-js))))
      (:body
        (:raw (%kit-list-section state))
        (hyperion/kit/panel:panel-region)
        (:pre :id "results")
        (:script (:raw *kit-list-scenario*))))))



(defun %kit-list-app ()
  (router:to-app
   (router:router
    (assets:mount)
    (router:route :get "/kit/list"
                  (lambda (env)
                    (let ((state (hyperion/list:read-list-state *kit-list-spec* env)))
                      (%html (if (http:request-header env "hx-request")
                                 (%kit-list-section state)
                                 (%kit-list-page state))))))
    (router:route :get "/kit/panel/:id"
                  (lambda (env)
                    (let ((draft (assoc (parse-integer (router:path-param env "id")) *kit-drafts*)))
                      (%html (spinneret:with-html-string
                               (hyperion/kit/panel:properties-panel
                                (second draft)
                                :body (lambda () (spinneret:with-html (:p (third draft)))))))))))))

(defun %query-alist (search)
  "SEARCH, a location.search or a LIST-HREF result, as a sorted alist, so two orders of the
same parameters compare equal."
  (sort (http:form-alist (string-left-trim "?" search)) #'string< :key #'car))

(test the-list-toolbar-and-the-properties-panel-in-a-real-browser
  "The toolbar's requests carry the parameters LIST-HREF writes for the same change, and the
search field keeps focus and its text across the swap; a row loads its panel on a click on the
row and from its button, and becomes the current row, and a click on another control in the row
loads nothing; Escape and the close button empty the panel and put focus back on the current
row's button. The button is a <button>, so the browser presses it on Enter and Space; a script
cannot test that with a keydown it makes, because a browser does not activate a button for one."
  (let ((browser (%smoke-browser)))
    (if (null browser)
        (skip "No Chrome or Edge found; set HYPERION_SMOKE_BROWSER to run the kit list page")
        (let* ((app (%kit-list-app))
               (port nil)
               (handler (ports:call-with-port
                         (lambda (p)
                           (prog1 (hyperion/server:start app :port p :host "127.0.0.1" :log nil)
                             (setf port p))))))
          (unwind-protect
               (let* ((dom (%run-browser browser (format nil "http://127.0.0.1:~D/kit/list?~A"
                                                         port *kit-list-start*)))
                      (results (%kit-results dom))
                      (s0 (hyperion/list:read-list-state *kit-list-spec*
                                                         (list :query-string *kit-list-start*)))
                      (h1 (hyperion/list:list-href s0 :filters '(:q "Me")))
                      (s1 (hyperion/list:read-list-state *kit-list-spec*
                                                         (list :query-string (subseq h1 1))))
                      (h2 (hyperion/list:list-href s1 :filters '(:status "sent")))
                      (s2 (hyperion/list:read-list-state *kit-list-spec*
                                                         (list :query-string (subseq h2 1))))
                      (h3 (hyperion/list:list-href s2 :sort :title))
                      (s3 (hyperion/list:read-list-state *kit-list-spec*
                                                         (list :query-string (subseq h3 1))))
                      (h4 (hyperion/list:list-href s3 :filters '(:status nil))))
                 (flet ((saw (key) (cdr (assoc key results :test #'string=)))
                        (same-query (key href)
                          (equal (%query-alist (or (cdr (assoc key results :test #'string=)) ""))
                                 (%query-alist href))))
                   (is (equal "yes" (saw "done")) "the page ran every step: ~S" results)
                   (is (null (remove-if-not (lambda (p) (search "error" (car p))) results))
                       "a step threw: ~S" results)
                   (is (equal "4" (saw "start-rows")))
                   (is (same-query "search-url" h1) "search: ~S, LIST-HREF ~S" (saw "search-url") h1)
                   (is (equal "3" (saw "search-rows")))
                   (is (equal "hy-toolbar-search" (saw "search-focus")) "focus stayed in the field")
                   (is (equal "Me" (saw "search-value")))
                   (is (same-query "status-url" h2) "status: ~S, LIST-HREF ~S" (saw "status-url") h2)
                   (is (equal "2" (saw "status-rows")))
                   (is (same-query "sort-url" h3) "a new sort key drops the direction: ~S, ~S"
                       (saw "sort-url") h3)
                   (is (equal "Meeting_notes" (saw "sort-first")))
                   (is (same-query "all-url" h4) "All leaves the filter out: ~S, ~S" (saw "all-url") h4)
                   (is (equal "Meeting_notes" (saw "click-panel")))
                   (is (equal "row-2" (saw "click-current")))
                   (is (equal "null" (saw "row-tabindex")) "the row is not a tab stop")
                   (is (equal "Memo_to_staff" (saw "button-panel")) "the row's button loads its panel")
                   (is (equal "row-1" (saw "button-current")) "and makes it the current row")
                   (is (equal "true" (saw "esc-empty")) "Escape closes the panel")
                   (is (equal "row-1-open" (saw "esc-focus")) "focus back on the current row's button")
                   (is (equal "true" (saw "x-empty")) "the close button closes it")
                   (is (equal "row-2-open" (saw "x-focus")))
                   (is (equal "true" (saw "star-empty")) "a control inside a row does not load its panel")
                   (is (equal "row-2" (saw "star-current")) "nor change the current row")
                   (is (equal "true" (saw "htmx")))))
            (ignore-errors (hyperion/server:stop handler))
            (is (ports:await-released port) "the port was still accepting after teardown"))))))
