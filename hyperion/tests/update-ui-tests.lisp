;;;; update-ui-tests.lisp --- the update surface exists and behaves (pre-publication issue 333).
;;;;
;;;; WHY THIS SUITE EXISTS. pre-publication issue 333's measurement was that `grep -rln "_hyperion/update"'
;;;; returned one file and the hit was in a docstring: no route, no handler, no banner. The
;;;; typed core's suites were green throughout, because they are about the decision and say
;;;; nothing about whether anything renders it. A system that exports a surface needs a
;;;; suite that uses it -- review cannot see an absence, and this one sat inside a P0
;;;; marked In Review for weeks.
;;;;
;;;; NOTHING HERE REACHES THE NETWORK. Every router is built with :CHECK NIL, and every
;;;; status is a plist handed in by the test -- the same shape `update-status' returns. The
;;;; two POST routes are driven with `*restart*' and the platform refusal, neither of which
;;;; needs a server.
;;;;
;;;; THE TWO TESTS THAT MATTER ARE THE ONES ABOUT THE POLL, and both assert a property no
;;;; reader would question and a browser would discover immediately:
;;;;
;;;;   quiet-status-keeps-the-poller  -- a quiet reply must still carry hx-get. Section 8
;;;;     says the quiet response is empty; an empty outerHTML swap deletes the element that
;;;;     holds the trigger, so following the document literally stops the updater forever
;;;;     in its commonest state, invisibly.
;;;;   route-response-has-no-load-trigger -- `load' fires whenever an element enters the
;;;;     DOM, so a reply carrying it re-requests itself as fast as the server answers.
;;;;     The MOUNT needs `load'; a REPLY must not have it. One word, two opposite
;;;;     requirements, no visible difference in review.

(cl:defpackage #:hyperion/update-ui/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:ui #:hyperion/update-ui)
                    (#:up #:hyperion/update)
                    (#:router #:hyperion/router))
  (:export #:run-tests))

(in-package #:hyperion/update-ui/tests)

(def-suite hyperion-update-ui
  :description "The updater's visible half: routes, banner, and the poll that must survive.")
(in-suite hyperion-update-ui)

(defun run-tests () (run! 'hyperion-update-ui))

;;; --- fixtures ---------------------------------------------------------------

(defun %status (name &key (version "") (block "") (detail ""))
  "A status plist of exactly the shape `up:update-status' returns."
  (list :status name :version version :block block :detail detail))

(defun %env (method path)
  (list :request-method method :path-info path
        :headers (make-hash-table :test #'equal)))

(defun %body (response)
  "The single body string out of a Clack response."
  (first (third response)))

(defun %dispatch (r method path)
  (router:dispatch r (%env method path)))

(defun %squeeze (s)
  "S with every run of whitespace collapsed to one space.

SPINNERET PRETTY-PRINTS, and it wraps at a fill column -- inside the text of a <p>, mid
sentence. So a literal SEARCH for a phrase fails whenever the renderer happened to break a
line inside it, which is a property of the formatter and not of the page. Two assertions in
this file failed that way before this existed, on markup that was entirely correct. Same
hazard AGENTS.md records for grepping documents: a line wrap splits the phrase and hides
the instance."
  (with-output-to-string (out)
    (let ((in-space nil))
      (loop for c across s
            do (if (member c '(#\Space #\Tab #\Newline #\Return #\Linefeed))
                   (progn (unless in-space (write-char #\Space out))
                          (setf in-space t))
                   (progn (write-char c out) (setf in-space nil)))))))

(defun %contains (haystack needle)
  (and (search (%squeeze needle) (%squeeze haystack)) t))

;;; --- the control: the statuses really are classified as we think ------------

(test quiet-and-loud-are-the-classification-not-our-opinion
  "The control for everything below. Before asserting that a quiet status renders nothing,
prove these statuses ARE the quiet ones -- as hyperion/update classifies them, not as this
file assumes. If `+quiet-statuses+' ever changes, this fails first and the rest of the
suite stops being about the wrong set."
  (dolist (name up:+quiet-statuses+)
    (is (not (up:banner-worthy-p (%status name)))
        "~S is in +quiet-statuses+ but banner-worthy-p called it loud." name))
  (dolist (name '("available" "staged" "applying" "pending-confirmation" "blocked"))
    (is (up:banner-worthy-p (%status name))
        "~S should be loud; banner-worthy-p called it quiet." name)))

;;; --- the banner -------------------------------------------------------------

(test loud-status-renders-its-sentence
  (let ((html (ui:update-banner (%status "available" :version "1.4.0"))))
    (is (%contains html "1.4.0"))
    (is (%contains html "hy-update-banner--available"))
    (is (%contains html "hy-update-banner__message"))))

(test quiet-status-renders-no-message-and-no-controls
  "Visually nothing at all, which is what +quiet-statuses+ requires."
  (let ((html (ui:update-banner (%status "up-to-date" :version "1.4.0"))))
    (is (not (%contains html "hy-update-banner__message")))
    (is (not (%contains html "hy-update-banner__actions")))
    (is (not (%contains html "<button")))
    ;; Not even the version leaks: a quiet state says nothing, not nothing-much.
    (is (not (%contains html "1.4.0")))))

(test quiet-status-keeps-the-poller
  "THE DESIGN DOCUMENT CANNOT BE FOLLOWED LITERALLY HERE, and this is the assertion.

Section 8 says the quiet reply is `nothing at all (an empty swap removes the banner)'. The
element it also specifies carries hx-get/hx-trigger and swaps outerHTML -- so an empty
reply removes the POLLER, and the updater never checks again. That failure is invisible:
the app looks exactly like an app with no update available, which is what it was told to
look like."
  (let ((html (ui:update-banner (%status "up-to-date"))))
    (is (%contains html "hx-get"))
    (is (%contains html "/_hyperion/update/status"))
    (is (%contains html "hx-trigger"))
    (is (%contains html "hy-update-banner"))))

(test available-offers-apply-and-staged-offers-restart
  "Each loud state offers the control that state can actually act on, and not the other."
  (let ((available (ui:update-banner (%status "available" :version "2.0.0")))
        (staged (ui:update-banner (%status "staged" :version "2.0.0"))))
    (is (%contains available "/_hyperion/update/apply"))
    (is (not (%contains available "/_hyperion/update/restart")))
    (is (%contains staged "/_hyperion/update/restart"))
    (is (not (%contains staged "/_hyperion/update/apply")))))

(test applying-states-get-a-sentence-and-no-button
  "state.lisp: `a progress bar that cannot advance is worse than a sentence that explains
why'. The sentence, then, and no control -- there is nothing left to press."
  (let ((html (ui:update-banner (%status "applying" :version "2.0.0"))))
    (is (%contains html "hy-update-banner__message"))
    (is (%contains html "2.0.0"))
    (is (not (%contains html "<button")))
    ;; Not an empty actions container either: a <div> with nothing in it is a styling
    ;; hazard the app cannot see coming, and it was there until this test asked.
    (is (not (%contains html "hy-update-banner__actions")))))

(test blocked-shows-its-own-reason-not-the-generic-label
  "Every block reason carries a sentence (client.lisp). Rendering the generic label over
the specific one would throw away the only part the user can act on."
  (let ((html (ui:update-banner
               (%status "blocked" :block "not-writable"
                        :detail "C:\\Program Files\\App was installed for all users"))))
    (is (%contains html "was installed for all users"))))

(test detail-is-escaped
  "The detail reaches the page from a DOWNLOADED MANIFEST. Spinneret escapes text content;
this asserts it rather than trusting that it always will."
  (let ((html (ui:update-banner
               (%status "blocked" :detail "<script>alert(1)</script>"))))
    (is (not (%contains html "<script>alert(1)</script>")))
    (is (%contains html "&lt;script&gt;"))))

(test labels-are-app-supplied
  "Copy is where i18n lives, and i18n lives in the app."
  (let ((html (ui:update-banner (%status "available" :version "3.1")
                                :labels '(:available "Neue Version ~A"
                                          :apply "Jetzt aktualisieren"))))
    (is (%contains html "Neue Version 3.1"))
    (is (%contains html "Jetzt aktualisieren"))))

;;; --- the poll's one-word hazard ---------------------------------------------

(test mount-triggers-on-load
  "The app renders this once into a page, so the first check must happen when the page
opens. This is the ONLY place `load' may appear."
  (is (%contains (ui:update-mount) "load")))

(test route-response-has-no-load-trigger
  "`load' fires whenever an element enters the DOM, and every hx-swap inserts a new one. A
reply carrying `load' re-requests itself immediately, forever, as fast as the server can
answer -- a request storm that no unit test would otherwise see and that looks, in review,
exactly like the mount it was copied from."
  (let* ((r (ui:update-router :check nil))
         (html (%body (%dispatch r :get "/status"))))
    (is (%contains html "hx-trigger"))
    (is (not (%contains html "load"))
        "The status route's reply carries a `load' trigger; it will re-request itself forever.")))

;;; --- the routes exist -------------------------------------------------------

(test the-three-routes-are-routable
  "pre-publication issue 333's measurement was that none of these existed. This is the direct answer to it."
  (let ((names (mapcar #'router:route-name (router:routes (ui:update-router :check nil)))))
    (is (member :update-status names))
    (is (member :update-apply names))
    (is (member :update-restart names))))

(test status-route-renders-the-current-state
  "With :CHECK NIL the route reports the last known state rather than reaching a network."
  (let ((up::*update-state* (%status "available" :version "9.9.9")))
    (let ((response (%dispatch (ui:update-router :check nil) :get "/status")))
      (is (= 200 (first response)))
      (is (%contains (%body response) "9.9.9")))))

(test unknown-path-under-the-prefix-is-a-404
  "The router claims three paths and not the whole prefix."
  (is (= 404 (first (%dispatch (ui:update-router :check nil) :get "/nope")))))

(test status-route-rejects-a-post
  "GET /status is a read. A 405 with an Allow header is the router's job; this asserts the
route was declared with a method rather than catching anything that arrives."
  (is (= 405 (first (%dispatch (ui:update-router :check nil) :post "/status")))))

;;; --- restart: refusing is the framework's correct answer --------------------

(test restart-without-a-handler-states-the-refusal
  "*RESTART* is NIL by default because hyperion cannot know how to relaunch an AppImage,
a signed .app and an NSIS install. A button that silently does nothing would be worse than
one that says why it cannot."
  (let ((ui:*restart* nil)
        (up::*update-state* (%status "staged" :version "2.0.0")))
    (let ((html (%body (%dispatch (ui:update-router :check nil) :post "/restart"))))
      (is (%contains html "hy-update-banner--blocked"))
      (is (%contains html "restart handler")))))

(test restart-calls-the-app-supplied-handler
  (let* ((called 0)
         (ui:*restart* (lambda () (incf called)))
         (up::*update-state* (%status "staged" :version "2.0.0")))
    (%dispatch (ui:update-router :check nil) :post "/restart")
    (is (= 1 called))))

(test a-failing-restart-handler-becomes-a-blocked-banner-not-a-500
  "An app's restart can fail. The user gets the reason; the server does not get a stack
trace rendered at them."
  (let ((ui:*restart* (lambda () (error "the relauncher exploded")))
        (up::*update-state* (%status "staged" :version "2.0.0")))
    (let ((response (%dispatch (ui:update-router :check nil) :post "/restart")))
      (is (= 200 (first response)))
      (is (%contains (%body response) "the relauncher exploded")))))

;;; --- apply ------------------------------------------------------------------

(test apply-on-a-platform-with-no-apply-strategy-explains-itself
  "APPLY-UPDATE signals `update-not-implemented' wherever the apply strategy is not written
(#251) -- today macOS. That is an ordinary answer with a sentence attached, and the route
renders the sentence rather than letting the condition escape as a 500.

The status is deliberately NOT `available' here, so the refusal this exercises is the one
APPLY-UPDATE reaches first. What is asserted is the route's handling, which is the same for
either refusal."
  (let ((up::*update-state* (%status "up-to-date")))
    (let ((response (%dispatch (ui:update-router :check nil) :post "/apply")))
      (is (= 200 (first response)))
      (is (%contains (%body response) "hy-update-banner--blocked")))))

;;; --- csrf -------------------------------------------------------------------

(test a-csrf-token-reaches-the-controls
  "An app wrapping this router in WRAP-CSRF refuses POSTs without a token, and both
controls are POSTs."
  (let ((html (ui:update-banner (%status "available" :version "1.0")
                                :csrf-token "tok-abc")))
    (is (%contains html "hx-headers"))
    (is (%contains html "tok-abc"))))

(test a-csrf-thunk-is-called-per-request-not-per-router
  "A token baked in when the router was built would be one session's token handed to
every later visitor. The thunk is re-called per request, and this is the test that can
tell the two apart: two requests, two different tokens."
  (let* ((n 0)
         (r (ui:update-router :check nil
                              :csrf-token (lambda () (format nil "tok-~D" (incf n)))))
         (up::*update-state* (%status "available" :version "1.0")))
    (let ((first (%body (%dispatch r :get "/status")))
          (second (%body (%dispatch r :get "/status"))))
      (is (%contains first "tok-1"))
      (is (%contains second "tok-2")))))

;;; --- the channel and product reach both routes (#301) -----------------------
;;;
;;; These use the client suite's fixtures, which sign a real manifest with a real key, so the
;;; product and channel checks run exactly as they do for an app. The source records every
;;; channel it is asked for, which is what shows that Apply fetched beta and not stable.

(defclass recording-source (hyperion/update/client-tests::fixed-source)
  ((asked :initform nil :accessor source-asked))
  (:documentation "A signed fixed source that records each channel it is asked for, in order."))

(defmethod up:fetch-manifest :before ((source recording-source) channel)
  (setf (source-asked source) (append (source-asked source) (list channel))))

(defun %recording-source (&rest manifest-args)
  "A RECORDING-SOURCE serving a signed manifest built from MANIFEST-ARGS."
  (change-class (hyperion/update/client-tests::signed-source
                 (apply #'hyperion/update/client-tests::manifest-json manifest-args))
                'recording-source))

(defmacro %with-update-client ((source app-name) &body body)
  "BODY with a build that carries the test key, is installed at 1.0.0, uses SOURCE as its
update source and APP-NAME as its *APP-NAME*."
  `(hyperion/update/client-tests::with-client ()
     (let ((up:*update-source* ,source)
           (up:*app-name* ,app-name)
           (up::*update-state* nil))
       ,@body)))

(test the-status-route-checks-the-channel-it-was-given
  (let ((source (%recording-source :channel "beta" :version "2.0.0")))
    (%with-update-client (source "testapp")
      (%dispatch (ui:update-router :channel "beta") :get "/status")
      (is (equal '("beta") (source-asked source)))
      (is (string= "available" (getf (up:update-status) :status))))))

(test apply-fetches-the-channel-the-router-was-given-even-with-check-nil
  ;; SoloFlow's case: the app checks on beta itself and mounts the router with :CHECK NIL.
  ;; Apply re-checks, and before #301 that re-check asked for stable. The channel is given
  ;; as a function of the env, the per-user form. The offered version equals the installed
  ;; one, so Apply stops at its re-check with "no update to apply" instead of installing.
  (let ((source (%recording-source :channel "beta" :version "1.0.0")))
    (%with-update-client (source "testapp")
      (let ((response (%dispatch (ui:update-router :check nil
                                                   :channel (lambda (env)
                                                              (declare (ignore env))
                                                              "beta"))
                                 :post "/apply")))
        (is (= 200 (first response)))
        (is (equal '("beta") (source-asked source))
            "Apply asked for ~S; it must ask for beta and nothing else" (source-asked source))))))

(test without-a-channel-the-routes-use-stable
  ;; The control for the two tests above: the recording shows what an unconfigured router
  ;; asks for, so "beta" there came from the argument.
  (let ((source (%recording-source :channel "stable" :version "2.0.0")))
    (%with-update-client (source "testapp")
      (%dispatch (ui:update-router) :get "/status")
      (is (equal '("stable") (source-asked source))))))

(test a-manifest-for-another-product-is-refused-by-the-status-route
  (let ((source (%recording-source :product "otherapp" :version "2.0.0")))
    (%with-update-client (source "testapp")
      (let ((response (%dispatch (ui:update-router) :get "/status")))
        (is (string= "manifest-mismatch" (getf (up:update-status) :block)))
        (is (%contains (%body response) "hy-update-banner--blocked"))))))

(test a-manifest-for-another-product-is-refused-by-the-apply-route
  (let ((source (%recording-source :product "otherapp" :version "2.0.0")))
    (%with-update-client (source "testapp")
      (let ((response (%dispatch (ui:update-router :check nil) :post "/apply")))
        (is (= 200 (first response)))
        (is (string= "manifest-mismatch" (getf (up:update-status) :block))
            "Apply's re-check must refuse the manifest, not install it")
        (is (%contains (%body response) "hy-update-banner--blocked"))))))

(test the-routers-product-overrides-app-name
  (let ((source (%recording-source :product "testapp" :version "2.0.0")))
    (%with-update-client (source "somethingelse")
      (%dispatch (ui:update-router :product "testapp") :get "/status")
      (is (string= "available" (getf (up:update-status) :status))))))

;;; --- the poll interval is one htmx reads as meant (#422) --------------------------
;;;
;;; The default was "6h". htmx 1.9.12 knows ms, s and m, and reads anything else with
;;; parseFloat, so "6h" was 6 ms: every page with the banner asked for its status many times a
;;; second, and it helped make the maintainer's machine unresponsive. The route test above
;;; guarded the trigger against `load'; nothing guarded its interval.

(defun %htmx-source ()
  (uiop:read-file-string
   (asdf:system-relative-pathname :hyperion "assets/vendor/htmx.min.js")))

(test the-vendored-htmx-knows-only-ms-s-and-m
  "The check below is written against this parser. If htmx is upgraded and learns another unit,
this fails, and the check should be revisited rather than trusted."
  (let ((src (%htmx-source)))
    (is (search "version:\"1.9.12\"" src) "the vendored htmx is 1.9.12")
    (is (search "if(e.slice(-2)==\"ms\"){t=parseFloat(e.slice(0,-2))}else if(e.slice(-1)==\"s\"){t=parseFloat(e.slice(0,-1))*1e3}else if(e.slice(-1)==\"m\"){t=parseFloat(e.slice(0,-1))*1e3*60}else{t=parseFloat(e)}"
                src)
        "the interval parser still reads ms, s and m, and parseFloat for anything else")))

(test the-default-poll-interval-is-six-hours-in-minutes
  (is (string= "360m" ui:*poll-interval*))
  (is (%contains (ui:update-mount) "load, every 360m"))
  (is (%contains (ui:update-banner (%status "up-to-date")) "every 360m")))

(test a-poll-interval-htmx-would-misread-is-refused
  (dolist (bad '("6h" "5000" "1d" "m" "1.2.3m" "-5m" "5 m" ""))
    (let ((ui:*poll-interval* bad))
      (signals ui:invalid-poll-interval (ui:update-mount))
      (signals ui:invalid-poll-interval (ui:update-banner (%status "up-to-date"))))))

(test a-poll-interval-below-a-second-is-refused
  (dolist (fast '("500ms" "0.5s" "0s"))
    (let ((ui:*poll-interval* fast))
      (signals ui:invalid-poll-interval (ui:update-mount))))
  (dolist (ok '("1s" "1000ms" "0.5m" "90s" "360m"))
    (let ((ui:*poll-interval* ok))
      (is (%contains (ui:update-mount) (format nil "load, every ~A" ok))
          "~S is accepted" ok))))

(test the-refusal-names-the-value-and-what-to-use
  (let ((ui:*poll-interval* "6h"))
    (handler-case (progn (ui:update-mount) (fail "6h was not refused"))
      (ui:invalid-poll-interval (e)
        (is (equal "6h" (ui:invalid-poll-interval-value e)))
        (let ((text (princ-to-string e)))
          (is (search "\"6h\"" text))
          (is (search "360m" text)))))))

(test without-the-check-6h-reaches-the-page
  "The control: the refusal above comes from CHECKED-POLL-INTERVAL. With it replaced by the
identity, the same value renders, and the page would poll every 6 ms."
  (let ((original (fdefinition 'ui:checked-poll-interval))
        (ui:*poll-interval* "6h"))
    (unwind-protect
         (progn
           (setf (fdefinition 'ui:checked-poll-interval)
                 (lambda (&optional (value ui:*poll-interval*)) value))
           (is (%contains (ui:update-mount) "load, every 6h")))
      (setf (fdefinition 'ui:checked-poll-interval) original))))
