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

;;; The dock panel (#67), in a host page that already has htmx: a panel in a 340px column, one in
;;; a tab that is not shown, and one a launcher opens. The page records whether each loaded, how
;;; wide the first is before and after its column is resized, that htmx processed the loaded
;;; contents, and that window.htmx is still the object the page loaded.

(defparameter *dock-scenario* "
var r = [];
function log(k, v) { r.push(k + '=' + v); document.getElementById('results').textContent = r.join(' '); }
function byId(id) { return document.getElementById(id); }
function width(id) { return Math.round(byId(id).getBoundingClientRect().width); }
function show(tab) { byId('tab-a').hidden = tab !== 'a'; byId('tab-b').hidden = tab !== 'b'; }
function state(id) { return byId('open-' + id).getAttribute('aria-expanded') + ',' + byId('dock-' + id).hidden; }
var steps = [
  function () { log('a-loaded', !!byId('a-content')); log('b-loaded-hidden', !!byId('b-content'));
    log('c-waits', !byId('c-content')); log('a-width', width('dock-a')); byId('a-ping').click(); },
  function () { log('a-ping', byId('a-out').textContent); byId('col-a').style.width = '500px'; },
  function () { log('a-resized', width('dock-a')); show('b'); },
  function () { log('b-width', width('dock-b')); show('a'); },
  function () { log('a-kept', !!byId('a-content')); show('b'); },
  function () { log('b-kept', !!byId('b-content')); log('c-before', state('c')); log('c-closed-width', width('dock-c')); byId('open-c').click(); },
  function () { log('c-open', state('c')); },
  function () { log('c-loaded', !!byId('c-content')); byId('open-c').click(); },
  function () { log('c-closed', state('c')); byId('open-c').click(); },
  function () { log('c-reopened', state('c'));
    log('htmx-same', window.htmx === window.hostHtmx && !!window.htmx); log('done', 'yes'); }
];
var i = 0;
function next() {
  if (i < steps.length) {
    try { steps[i++](); } catch (e) { log('error-' + i, e.message.replace(/ /g, '_')); }
    setTimeout(next, 300);
  }
}
document.addEventListener('DOMContentLoaded', function () { setTimeout(next, 300); });
"
  "The steps the dock page runs, logged as key=value and read back by %KIT-RESULTS.")

(defun %dock-page ()
  (spinneret:with-html-string
    (:doctype)
    (:html
      (:head (:meta :charset "utf-8")
             (:link :rel "stylesheet" :href (assets:url :kit))
             (:script :src (assets:url :htmx))
             ;; The host's own reference to its htmx, taken before anything of the dock runs.
             (:script (:raw "window.hostHtmx = window.htmx;"))
             (:script (:raw (hyperion/kit/dock:dock-js))))
      (:body
        (:div :id "tab-a"
          (:div :id "col-a" :style "width:340px;height:300px"
            (hyperion/kit/dock:dock-panel "/frag/dock/a" "Panel A" :id "dock-a")))
        (:div :id "tab-b" :hidden t
          (:div :style "width:340px;height:300px"
            (hyperion/kit/dock:dock-panel "/frag/dock/b" "Panel B" :id "dock-b")))
        (hyperion/kit/dock:dock-launcher "Open C" :dock-id "dock-c" :id "open-c")
        (:div :style "width:340px;height:300px"
          (hyperion/kit/dock:dock-panel "/frag/dock/c" "Panel C" :id "dock-c"
                                        :load :on-open :hidden t))
        (:pre :id "results")
        (:script (:raw *dock-scenario*))))))

(defun %dock-app (loads)
  "The dock page's routes. LOADS is an alist of (name . count), counting how many times each
panel's contents were asked for."
  (flet ((contents (name)
           (lambda (env)
             (declare (ignore env))
             (incf (cdr (assoc name loads :test #'string=)))
             (%html (format nil "<div id=\"~A-content\">~:*~A loaded <button type=\"button\" id=\"~:*~A-ping\" hx-get=\"/frag/ping\" hx-target=\"#~:*~A-out\">ping</button><span id=\"~:*~A-out\"></span></div>" name)))))
    (router:to-app
     (router:router
      (assets:mount)
      (router:route :get "/dock" (lambda (env) (declare (ignore env)) (%html (%dock-page))))
      (router:route :get "/frag/dock/a" (contents "a"))
      (router:route :get "/frag/dock/b" (contents "b"))
      (router:route :get "/frag/dock/c" (contents "c"))
      (router:route :get "/frag/ping" (lambda (env) (declare (ignore env)) (%html "pong")))))))

(test the-dock-panel-in-a-real-browser
  "A panel fills its column and resizes with it, and the contents it loads are live htmx; a
panel in a tab that is not shown loads with the page and stays loaded across tab switches; the
launcher opens and closes its panel, says so in aria-expanded, and loads it on the first open
only; and the page's window.htmx is still the object it loaded."
  (let ((browser (%smoke-browser)))
    (if (null browser)
        (skip "No Chrome or Edge found; set HYPERION_SMOKE_BROWSER to run the dock page")
        (let* ((loads (list (cons "a" 0) (cons "b" 0) (cons "c" 0)))
               (app (%dock-app loads))
               (port nil)
               (handler (ports:call-with-port
                         (lambda (p)
                           (prog1 (hyperion/server:start app :port p :host "127.0.0.1" :log nil)
                             (setf port p))))))
          (unwind-protect
               (let* ((dom (%run-browser browser (format nil "http://127.0.0.1:~D/dock" port)))
                      (results (%kit-results dom)))
                 (flet ((saw (key) (cdr (assoc key results :test #'string=))))
                   (is (equal "yes" (saw "done")) "the page ran every step: ~S" results)
                   (is (null (remove-if-not (lambda (p) (search "error" (car p))) results))
                       "a step threw: ~S" results)
                   (is (equal "true" (saw "a-loaded")))
                   (is (equal "true" (saw "b-loaded-hidden")) "a panel in a hidden tab did not load")
                   (is (equal "true" (saw "c-waits")) "the launcher's panel loaded before it opened")
                   (is (equal "340" (saw "a-width")) "the panel is not as wide as its column")
                   (is (equal "pong" (saw "a-ping")) "htmx did not process the loaded contents")
                   (is (equal "500" (saw "a-resized")) "the panel did not follow its column")
                   (is (equal "340" (saw "b-width")))
                   (is (equal "true" (saw "a-kept")))
                   (is (equal "true" (saw "b-kept")))
                   (is (equal "false,true" (saw "c-before")))
                   (is (equal "0" (saw "c-closed-width")) "a closed panel still takes up space")
                   (is (equal "true,false" (saw "c-open")) "the launcher did not open its panel")
                   (is (equal "true" (saw "c-loaded")) "opening did not load the panel")
                   (is (equal "false,true" (saw "c-closed")) "the launcher did not close it")
                   (is (equal "true,false" (saw "c-reopened")))
                   (is (equal "true" (saw "htmx-same")) "window.htmx was replaced")
                   (is (equal '(("a" . 1) ("b" . 1) ("c" . 1)) loads)
                       "each panel's contents should be asked for once: ~S" loads)))
            (ignore-errors (hyperion/server:stop handler))
            (is (ports:await-released port) "the port was still accepting after teardown"))))))

;;; --- the appearance picker --------------------------------------------------------------

(defparameter *appearance-scenario* "
var r = [];
function log(k, v) { r.push(k + '=' + v); document.getElementById('results').textContent = r.join(' '); }
function root(name) { var v = document.documentElement.getAttribute('data-' + name); return v === null ? 'none' : v; }
function pressed(name) {
  var b = document.querySelectorAll('[data-hy-setting=' + name + '][aria-pressed=true]');
  return b.length === 1 ? b[0].value : b.length; }
function button(name, value) { return document.querySelector('[name=' + name + '][value=' + value + ']'); }
var steps = [
  function () { log('start-theme', root('theme')); log('start-contrast', root('contrast'));
    log('start-pressed', pressed('theme') + ',' + pressed('contrast') + ',' + pressed('look'));
    button('theme', 'dark').click(); },
  function () { log('dark-theme', root('theme')); log('dark-pressed', pressed('theme'));
    log('dark-contrast', root('contrast')); log('dark-cookie', document.cookie);
    button('theme', 'system').click(); },
  function () { log('system-theme', root('theme')); log('system-pressed', pressed('theme'));
    button('look', 'gradient').click(); },
  function () { log('gradient-look', root('look')); log('gradient-pressed', pressed('look'));
    log('gradient-contrast', root('contrast'));
    // The two posts run in sequence and the last logs done, so the dump waits for both.
    fetch('/appearance', {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded', 'HX-Request': 'true'},
                          body: 'theme=purple'})
      .then(function (res) { return res.text().then(function (t) {
        log('forged-status', res.status); log('forged-echo', t.indexOf('purple') >= 0);
        log('forged-trigger', res.headers.get('HX-Trigger') === null); }); })
      .then(function () {
        return fetch('/appearance', {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                                     body: 'contrast=normal', redirect: 'manual'}); })
      .then(function (res) { log('plain-post', res.type); log('final-cookie', document.cookie);
        // Two more presses while the first is in flight, made from htmx:beforeSend, which
        // fires after htmx has sent nothing yet and has disabled the buttons. Timers cannot be
        // used: headless Chrome's virtual time stands still while a request is outstanding, so
        // a timer set during one fires only after the answer.
        var first = true;
        document.addEventListener('htmx:beforeSend', function () {
          if (!first) { return; }
          first = false;
          log('rapid-disabled', button('contrast', 'high').matches(':disabled'));
          log('rapid-focus-during', document.activeElement === button('theme', 'dark'));
          button('contrast', 'high').click(); button('look', 'flat').click(); });
        // Focused first, as a keyboard press would leave it, so the test can see where focus
        // goes when the buttons are disabled and enabled again.
        button('theme', 'dark').focus();
        button('theme', 'dark').click(); })
      .then(function () {
        setTimeout(function () {
          log('rapid', root('theme') + ',' + root('contrast') + ',' + root('look'));
          log('rapid-pressed', pressed('theme') + ',' + pressed('contrast') + ',' + pressed('look'));
          log('rapid-cookie', document.cookie);
          log('rapid-enabled', !button('contrast', 'high').matches(':disabled'));
          log('rapid-focus', document.activeElement === button('theme', 'dark')); log('done', 'yes'); }, 1500); })
      .catch(function (e) { log('error-fetch', String(e).replace(/ /g, '_')); }); }
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
  "The steps the appearance page runs, logged as key=value and read back by %KIT-RESULTS.")

(defparameter *appearance-store* (hyperion/appearance:make-cookie-appearance-store))

(defun %appearance-page (appearance)
  (spinneret:with-html-string
    (:doctype)
    (:html :attrs (hyperion/appearance:html-attributes appearance)
      (:head (:meta :charset "utf-8")
             (:script :src (assets:url :htmx))
             (:script (:raw (hyperion/kit/appearance:apply-appearance-js))))
      (:body
        (hyperion/kit/appearance:appearance-picker appearance "/appearance" :id "picker")
        (:pre :id "results")
        (:script (:raw *appearance-scenario*))))))

(defun %appearance-app ()
  "The appearance page, and the handler the picker posts to, written as the outline in
hyperion/kit/appearance describes: 400 for a refused form, 204 with the trigger for htmx, and a
303 back to the page without it."
  (progn
    (router:to-app
     (router:router
      (assets:mount)
      (router:route :get "/appearance"
                    (lambda (env)
                      (%html (%appearance-page
                              (hyperion/appearance:read-appearance *appearance-store* env)))))
      (router:route :post "/appearance"
                    (lambda (env)
                      (let ((change (hyperion/kit/appearance:appearance-from-form
                                     (http:body-string env))))
                        (if (null change)
                            (list 400 '(:content-type "text/plain") '("bad appearance"))
                            (let ((new (hyperion/kit/appearance:merge-appearance
                                        (hyperion/appearance:read-appearance *appearance-store*
                                                                             env)
                                        change)))
                              (if (http:htmx-request-p env)
                                  (list 204 (hyperion/kit/appearance:appearance-response-headers
                                             *appearance-store* new)
                                        '())
                                  (list 303 (list* :location "/appearance"
                                                   (hyperion/appearance:persist-appearance
                                                    *appearance-store* new))
                                        '())))))))))))

(test the-appearance-picker-in-a-real-browser
  "Pressing Dark posts the form with htmx, and the response's event sets data-theme on <html>,
moves aria-pressed to Dark and stores the choice in the cookie, leaving contrast alone; System
removes data-theme, so the CSS follows the system again; Gradient sets data-look. A forged value
is refused with 400, not echoed and not triggered; a post without htmx is redirected. While a
press is in flight the buttons are disabled, so presses made then have no effect and the page
still shows what was stored, and focus returns to the pressed button afterwards (#1115's
review)."
  (let ((browser (%smoke-browser)))
    (if (null browser)
        (skip "No Chrome or Edge found; set HYPERION_SMOKE_BROWSER to run the appearance page")
        (let* ((app (%appearance-app))
               (port nil)
               (handler (ports:call-with-port
                         (lambda (p)
                           (prog1 (hyperion/server:start app :port p :host "127.0.0.1" :log nil)
                             (setf port p))))))
          (unwind-protect
               (let* ((dom (%run-browser browser (format nil "http://127.0.0.1:~D/appearance" port)))
                      (results (%kit-results dom)))
                 (flet ((saw (key) (cdr (assoc key results :test #'string=))))
                   (is (equal "yes" (saw "done")) "the page ran every step: ~S" results)
                   (is (null (remove-if-not (lambda (p) (search "error" (car p))) results))
                       "a step threw: ~S" results)
                   (is (equal "none" (saw "start-theme")) "a fresh visitor follows the system")
                   (is (equal "system,system,flat" (saw "start-pressed")))
                   (is (equal "dark" (saw "dark-theme")) "the event did not set data-theme")
                   (is (equal "dark" (saw "dark-pressed")) "aria-pressed did not move to Dark")
                   (is (equal "none" (saw "dark-contrast")) "contrast changed with the theme")
                   (is (equal "appearance=dark.system.system" (saw "dark-cookie"))
                       "the choice was not stored: ~S" (saw "dark-cookie"))
                   (is (equal "none" (saw "system-theme")) "System did not remove data-theme")
                   (is (equal "system" (saw "system-pressed")))
                   (is (equal "gradient" (saw "gradient-look")))
                   (is (equal "gradient" (saw "gradient-pressed")))
                   (is (equal "none" (saw "gradient-contrast")))
                   (is (equal "400" (saw "forged-status")) "a forged value was not refused")
                   (is (equal "false" (saw "forged-echo")) "the forged value was echoed")
                   (is (equal "true" (saw "forged-trigger")) "a refused form sent the event")
                   (is (equal "opaqueredirect" (saw "plain-post"))
                       "a post without htmx was not redirected: ~S" (saw "plain-post"))
                   (is (equal "appearance=system.normal.gradient" (saw "final-cookie"))
                       "the redirect did not store the choice: ~S" (saw "final-cookie"))
                   (is (equal "true" (saw "rapid-disabled"))
                       "the buttons were not disabled while the first press was in flight")
                   (is (equal "dark,normal,gradient" (saw "rapid"))
                       "a press made during a request had an effect: ~S" (saw "rapid"))
                   (is (equal "dark,normal,gradient" (saw "rapid-pressed"))
                       "the pressed buttons do not show the settings: ~S" (saw "rapid-pressed"))
                   (is (equal "appearance=dark.normal.gradient" (saw "rapid-cookie"))
                       "the page and the stored choice disagree: ~S" (saw "rapid-cookie"))
                   (is (equal "true" (saw "rapid-enabled")) "the buttons stayed disabled")
                   (is (equal "false" (saw "rapid-focus-during"))
                       "disabling the buttons left focus on the pressed one, so the focus check
below cannot see the restore: ~S" (saw "rapid-focus-during"))
                   (is (equal "true" (saw "rapid-focus"))
                       "focus did not return to the pressed button after the request")))
            (ignore-errors (hyperion/server:stop handler))
            (is (ports:await-released port) "the port was still accepting after teardown"))))))

;;; --- two pickers and a slow response (#1138) ----------------------------------------------
;;;
;;; Two pickers on one page each disabled only their own buttons, so both could send before
;;; either answer came, each request carrying the old cookie, and the later answer undid the
;;; other choice. And when the answer came, focus went back to the pressed button even if the
;;; visitor had moved on. The page here has two pickers and a text field, and its handler waits
;;; before it answers. While picker one's request is outstanding, the page checks that picker
;;; two is disabled, presses it anyway, and moves focus to the field.

(defparameter *two-pickers-scenario* "
var r = [];
function log(k, v) { r.push(k + '=' + v); document.getElementById('results').textContent = r.join(' '); }
function root(name) { var v = document.documentElement.getAttribute('data-' + name); return v === null ? 'none' : v; }
function button(picker, name, value) {
  return document.querySelector('#' + picker + ' [name=' + name + '][value=' + value + ']'); }
function pressed(picker, name) {
  var b = document.querySelectorAll('#' + picker + ' [data-hy-setting=' + name + '][aria-pressed=true]');
  return b.length === 1 ? b[0].value : b.length; }
document.addEventListener('DOMContentLoaded', function () { setTimeout(function () {
  try {
    // From htmx:beforeSend, as in the test above: headless Chrome's timers stand still while
    // a request is outstanding.
    var first = true;
    document.addEventListener('htmx:beforeSend', function () {
      if (!first) { return; }
      first = false;
      log('other-disabled', button('picker-two', 'contrast', 'high').matches(':disabled'));
      button('picker-two', 'contrast', 'high').click();
      document.getElementById('elsewhere').focus();
      log('moved', document.activeElement.id); });
    button('picker-one', 'theme', 'dark').focus();
    button('picker-one', 'theme', 'dark').click();
    setTimeout(function () {
      log('settings', root('theme') + ',' + root('contrast'));
      log('cookie', document.cookie);
      log('other-pressed', pressed('picker-two', 'theme') + ',' + pressed('picker-two', 'contrast'));
      log('focus', document.activeElement.id || document.activeElement.tagName);
      // Focus on a button of picker two while picker one is pressed without taking focus, as
      // a click does in Safari. Disabling every picker moves focus to the body, and it has to
      // come back to picker two's button.
      button('picker-two', 'theme', 'light').focus();
      button('picker-one', 'look', 'gradient').click();
      setTimeout(function () {
        log('look', root('look'));
        log('focus-other', document.activeElement === button('picker-two', 'theme', 'light'));
        log('done', 'yes'); }, 2000); }, 2000);
  } catch (e) { log('error', e.message.replace(/ /g, '_')); }
}, 100); });
"
  "The steps the two-picker page runs, logged as key=value and read back by %KIT-RESULTS.")

(defun %two-pickers-page (appearance)
  (spinneret:with-html-string
    (:doctype)
    (:html :attrs (hyperion/appearance:html-attributes appearance)
      (:head (:meta :charset "utf-8")
             (:script :src (assets:url :htmx))
             (:script (:raw (hyperion/kit/appearance:apply-appearance-js))))
      (:body
        (hyperion/kit/appearance:appearance-picker appearance "/two" :id "picker-one")
        (:input :id "elsewhere" :name "elsewhere")
        (hyperion/kit/appearance:appearance-picker appearance "/two" :id "picker-two")
        (:pre :id "results")
        (:script (:raw *two-pickers-scenario*))))))

(defun %two-pickers-app ()
  "The two-picker page, and a handler that waits half a second before it answers, as the
appearance page's handler does otherwise."
  (router:to-app
   (router:router
    (assets:mount)
    (router:route :get "/two"
                  (lambda (env)
                    (%html (%two-pickers-page
                            (hyperion/appearance:read-appearance *appearance-store* env)))))
    (router:route :post "/two"
                  (lambda (env)
                    (sleep 0.5)
                    (let ((change (hyperion/kit/appearance:appearance-from-form
                                   (http:body-string env))))
                      (if (null change)
                          (list 400 '(:content-type "text/plain") '("bad appearance"))
                          (list 204 (hyperion/kit/appearance:appearance-response-headers
                                     *appearance-store*
                                     (hyperion/kit/appearance:merge-appearance
                                      (hyperion/appearance:read-appearance *appearance-store* env)
                                      change))
                                '()))))))))

(test two-pickers-and-a-slow-response-in-a-real-browser
  "#1138: while picker one's request is outstanding, picker two's buttons are disabled too, so a
press on picker two does nothing, and the stored choice and both pickers show picker one's
choice only. Focus, moved to a text field during the request, stays there when the slow answer
arrives. Then picker one is pressed while focus is on a button of picker two, as a click that
does not take focus leaves it: focus returns to that button when the answer arrives, because
the focused element is kept when it is in any picker, not only the one that sent."
  (let ((browser (%smoke-browser)))
    (if (null browser)
        (skip "No Chrome or Edge found; set HYPERION_SMOKE_BROWSER to run the two-picker page")
        (let* ((app (%two-pickers-app))
               (port nil)
               (handler (ports:call-with-port
                         (lambda (p)
                           (prog1 (hyperion/server:start app :port p :host "127.0.0.1" :log nil)
                             (setf port p))))))
          (unwind-protect
               (let* ((dom (%run-browser browser (format nil "http://127.0.0.1:~D/two" port)))
                      (results (%kit-results dom)))
                 (flet ((saw (key) (cdr (assoc key results :test #'string=))))
                   (is (equal "yes" (saw "done")) "the page ran every step: ~S" results)
                   (is (null (saw "error")) "a step threw: ~S" (saw "error"))
                   (is (equal "true" (saw "other-disabled"))
                       "picker two was not disabled while picker one's request was outstanding")
                   (is (equal "dark,none" (saw "settings"))
                       "the press on picker two had an effect: ~S" (saw "settings"))
                   (is (equal "appearance=dark.system.system" (saw "cookie"))
                       "the stored choice is not picker one's: ~S" (saw "cookie"))
                   (is (equal "dark,system" (saw "other-pressed"))
                       "picker two does not show the stored choice: ~S" (saw "other-pressed"))
                   (is (equal "elsewhere" (saw "moved"))
                       "focus did not move to the field, so the check below cannot see it kept")
                   (is (equal "elsewhere" (saw "focus"))
                       "the slow answer took focus from the field: ~S" (saw "focus"))
                   (is (equal "gradient" (saw "look"))
                       "the second press, on picker one, had no effect: ~S" (saw "look"))
                   (is (equal "true" (saw "focus-other"))
                       "focus did not return to picker two's button after picker one's request")))
            (ignore-errors (hyperion/server:stop handler))
            (is (ports:await-released port) "the port was still accepting after teardown"))))))
