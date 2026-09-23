;;;; update-ui.lisp --- the visible half of the updater (Hyperion aux system, pre-publication issue 333).
;;;;
;;;; `hyperion/update' decides; this renders. Until now only the first half existed: the
;;;; measurement in pre-publication issue 333 was that `grep -rln "_hyperion/update"' returned ONE file and the
;;;; hit was inside a docstring. The classification existed, the surface did not, and the
;;;; surface is the half a user experiences.
;;;;
;;;; ITS OWN ASDF SYSTEM, for the reason session-db has one. `hyperion/update' depends on
;;;; aion and jzon and NOT on hyperion -- it is usable from a CLI or a service with no HTTP
;;;; server in the image. Putting routes and Spinneret in it would put a web framework on
;;;; the load path of every consumer that only wanted the check. So this is the aux system
;;;; that depends on both, and nothing depends on it.
;;;;
;;;; GENERIC, PER HYPERION'S RULE. The framework ships markup, wiring and the poll; the app
;;;; supplies copy, the mount point, the stylesheet and the restart. Same split as
;;;; `hyperion/consent': the app styles `.hy-update-banner*' and the framework ships no
;;;; theme.
;;;;
;;;; --------------------------------------------------------------------------------
;;;; THE EMPTINESS IS NOT AN EMPTY RESPONSE, and this is the one place the design document
;;;; cannot be followed literally.
;;;;
;;;; Design section 8 says `GET /_hyperion/update/status' returns "nothing at all when up
;;;; to date (an empty swap removes the banner)". Take that literally with the element it
;;;; also specifies --
;;;;
;;;;     (:div :id "update-banner" :hx-get "..." :hx-trigger "load, every 6h"
;;;;           :hx-swap "outerHTML")
;;;;
;;;; -- and the first quiet poll REMOVES THE POLLER. `outerHTML' replaces the element that
;;;; carries the trigger, so swapping in nothing deletes the thing that would have asked
;;;; again. The banner never returns, in the one state that is overwhelmingly the common
;;;; case, and the failure is invisible: the app looks exactly like an app with no update.
;;;;
;;;; So a quiet status renders THE SHELL AND NO CHILDREN -- visually nothing at all, which
;;;; is what `+quiet-statuses+' requires, while the element that polls survives its own
;;;; response. `banner-worthy-p' still makes the decision; this file does not re-decide it,
;;;; it only declines to delete the clock along with the message.
;;;;
;;;; THE SECOND HALF OF THE SAME HAZARD: `load' must not appear in the trigger of anything
;;;; the ROUTE returns. `hx-trigger="load"' fires whenever the element enters the DOM, and
;;;; every swap inserts a new element -- so a response carrying `load' re-requests itself
;;;; immediately, forever, as fast as the server answers. `update-mount' carries
;;;; "load, every 6h" because the app renders it once into a page; `update-banner' carries
;;;; "every 6h" because the route renders it into its own reply. `route-response-has-no-
;;;; load-trigger' in the suite is the assertion, because this is a defect a human reading
;;;; the diff would agree with and a browser would discover at several hundred requests a
;;;; second.
;;;; --------------------------------------------------------------------------------
;;;;
;;;; NO PROGRESS BAR, AND THAT IS THE TYPED CORE'S INSTRUCTION RATHER THAN AN OMISSION.
;;;; Design section 8 wants download progress streamed over SSE from `hyperion/channel'.
;;;; `state.lisp' overrules it for the state that would need it, in the docstring on
;;;; `Applying':
;;;;
;;;;   "PROGRESS IS UNREPORTABLE FROM HERE BY CONSTRUCTION, not by omission: section 7
;;;;    hands the Windows payload to NSIS with /S and exits immediately so nothing is
;;;;    locked, which means the process that would report progress is the one being
;;;;    replaced. ... A state, because a progress bar that cannot advance is worse than a
;;;;    sentence that explains why."
;;;;
;;;; A bar that cannot move is a lie about liveness, so `applying' renders that sentence.
;;;; The download phase inside `apply-update' IS reportable in principle, but the function
;;;; is synchronous and has no progress seam to subscribe to; adding one changes
;;;; `hyperion/update' rather than this file. Recorded so the absence is not read as
;;;; forgetfulness and re-added by someone with the design document open.

(cl:defpackage #:hyperion/update-ui
  (:use #:cl)
  (:local-nicknames (#:up #:hyperion/update)
                    (#:router #:hyperion/router)
                    (#:csrf #:hyperion/csrf)
                    (#:spin #:spinneret))
  (:documentation
   "The updater's visible half: a poll, a banner and two controls, mounted under a reserved
    /_hyperion/update prefix. UPDATE-MOUNT is what an app renders once into its layout;
    UPDATE-ROUTER is what it MOUNTs. The banner is driven by hyperion/update's own
    BANNER-WORTHY-P, so which states are silent stays one decision in one place.

    Generic per Hyperion's rule: the app supplies copy (:LABELS), the release-notes link,
    a CSRF token if it wraps the router in WRAP-CSRF, and *RESTART* -- the framework has no
    portable way to relaunch an application and does not guess at one.")
  (:export
   ;; mounting
   #:update-router #:+update-prefix+
   #:+status-path+ #:+apply-path+ #:+restart-path+ #:+banner-id+
   ;; components
   #:update-mount #:update-banner
   ;; app-supplied
   #:*restart* #:*poll-interval* #:*labels* #:restart-not-supported))

(in-package #:hyperion/update-ui)

;;; --- vocabulary -------------------------------------------------------------

(defparameter +update-prefix+ "/_hyperion/update"
  "The reserved prefix the app MOUNTs the router under. Named here rather than typed twice:
the components emit these URLs and the router answers them, and a disagreement between the
two is a banner whose buttons 404.")

(defparameter +status-path+ "/status")
(defparameter +apply-path+ "/apply")
(defparameter +restart-path+ "/restart")

(defparameter +banner-id+ "hy-update-banner"
  "The element id the banner targets. One id, because every response replaces the element
that issued the request.")

(defparameter *poll-interval* "6h"
  "How often the banner re-checks. Design section 8: the check IS the poll -- there is no
separate schedule, and no state kept between polls beyond hyperion/update's own.")

(defparameter *labels*
  '(:available "A new version (~A) is available."
    :staged "Version ~A is ready to install."
    :applying "Installing version ~A. This window will close."
    :pending-confirmation "Now running version ~A."
    :blocked "This update cannot be installed automatically."
    :apply "Update now"
    :restart "Restart to finish"
    :notes "Release notes")
  "Default copy. An app overrides any subset via UPDATE-BANNER's :LABELS, because copy is
where i18n lives and i18n lives in the app (the same split hyperion/consent makes).

The message entries are FORMAT control strings taking the version. The rest are literals.")

(defvar *restart* nil
  "An app-supplied thunk that relaunches the application, or NIL.

NIL BY DEFAULT AND REFUSING IS THE CORRECT FRAMEWORK BEHAVIOUR, not a gap. Relaunching is
platform- and packaging-specific -- an AppImage re-execs itself, a signed .app is reopened
with `open', an NSIS install is restarted by the installer it already handed off to -- and
hyperion cannot know which of those it is inside. `hyperion/update' takes the same position
with *BEFORE-APPLY*, *LAUNCH-INSTALLER* and *EXIT-AFTER-HANDOFF*: the application drives its
own lifecycle and the updater does not reach into it.

So the restart control renders whenever the state calls for it, and pressing it without
this set produces a stated refusal rather than a button that silently does nothing.")

(define-condition restart-not-supported (error)
  ((detail :initarg :detail :reader restart-not-supported-detail))
  (:report (lambda (c s) (format s "~A" (restart-not-supported-detail c)))))

;;; --- rendering --------------------------------------------------------------

(defun %label (labels key)
  (or (getf labels key) (getf *labels* key)))

(defun %message (status labels)
  "The one sentence this STATUS owes the user, or NIL for the states that owe none."
  (let ((name (getf status :status))
        (version (or (getf status :version) ""))
        (detail (or (getf status :detail) "")))
    (cond
      ;; A block reason always carries its own sentence (client.lisp: "`blocked' is
      ;; deliberately NOT [quiet]. It is the one outcome that owes the user a sentence
      ;; -- and every block reason carries one"). Prefer it over the generic label, which
      ;; exists only for the case where one somehow does not.
      ((string= name "blocked")
       (if (plusp (length detail)) detail (%label labels :blocked)))
      ((member name '("available" "staged" "applying" "pending-confirmation")
               :test #'string=)
       (format nil (%label labels (intern (string-upcase name) :keyword)) version))
      (t nil))))

(defun %hx-headers (csrf-token)
  "The hx-headers attribute carrying a CSRF token, or NIL.

An app that wraps this router in WRAP-CSRF refuses POSTs without one, and the banner's two
controls are POSTs. Supplying the token is the app's job because the token is the app's
session's; omitting this argument in an app that has no CSRF middleware is correct."
  (when (and csrf-token (plusp (length csrf-token)))
    (format nil "{\"~A\": \"~A\"}" csrf:*header-name* csrf-token)))

(defun %render (status &key (prefix +update-prefix+) (id +banner-id+)
                            (trigger (format nil "every ~A" *poll-interval*))
                            labels notes-url csrf-token)
  "The banner element. Always the shell; children only when the state has something to say.

The shell carries the poll, so it survives its own quiet response -- see this file's
header. Spinneret escapes text content, which matters here because :DETAIL reaches this
function from a downloaded manifest."
  (let* ((name (getf status :status))
         (loud (up:banner-worthy-p status))
         (message (and loud (%message status labels)))
         (self (format nil "#~A" id))
         (headers (%hx-headers csrf-token)))
    (spin:with-html-string
      (:div :id id
            :class (format nil "hy-update-banner~@[ hy-update-banner--~A~]"
                           (and loud name))
            :role "status" :aria-live "polite"
            :hx-get (concatenate 'string prefix +status-path+)
            :hx-trigger trigger
            :hx-swap "outerHTML"
        (when message
          (:p :class "hy-update-banner__message" message))
        ;; The actions container only when there is an action. `applying',
        ;; `pending-confirmation' and `blocked' have a sentence and nothing to press, and
        ;; an empty <div> in the markup is a styling hazard the app cannot see coming.
        (when (and loud (or notes-url (member name '("available" "staged")
                                              :test #'string=)))
          (:div :class "hy-update-banner__actions"
            (when notes-url
              (:a :class "hy-update-banner__notes" :href notes-url
                (%label labels :notes)))
            (cond
              ((string= name "available")
               (:button :type "button" :class "hy-update-banner__btn hy-update-banner__btn--apply"
                        :hx-post (concatenate 'string prefix +apply-path+)
                        :hx-target self :hx-swap "outerHTML"
                        :hx-headers headers
                 (%label labels :apply)))
              ((string= name "staged")
               (:button :type "button" :class "hy-update-banner__btn hy-update-banner__btn--restart"
                        :hx-post (concatenate 'string prefix +restart-path+)
                        :hx-target self :hx-swap "outerHTML"
                        :hx-headers headers
                 (%label labels :restart)))
              ;; `applying' and `pending-confirmation' get a sentence and no control:
              ;; there is nothing left for the user to press, and a disabled button that
              ;; explains nothing is worse than no button. `blocked' likewise -- its
              ;; detail already says who to ask.
              (t nil))))))))

(defun update-banner (status &rest args &key prefix id trigger labels notes-url csrf-token)
  "Render the update banner for STATUS (a `hyperion/update:update-status' plist).

Quiet states render an empty, invisible shell rather than an empty response -- the element
carries the poll, and an outerHTML swap of nothing would delete it. Which states are quiet
is `up:banner-worthy-p''s decision and not this function's."
  (declare (ignore prefix id trigger labels notes-url csrf-token))
  (apply #'%render status args))

(defun update-mount (&rest args &key prefix id labels notes-url csrf-token)
  "The element an app renders ONCE into its layout, where the banner should appear.

Its trigger is \"load, every ~A\" -- `load' so the first check happens when the page opens,
which is the only place `load' may appear. Route responses must never carry it: every swap
inserts a new element, so a `load' in a reply re-requests itself forever."
  (declare (ignore prefix id labels notes-url csrf-token))
  (apply #'%render (list :status "unchecked" :version "" :block "" :detail "")
         :trigger (format nil "load, every ~A" *poll-interval*)
         args))

;;; --- the routes -------------------------------------------------------------

(defun %html (body)
  (list 200 '(:content-type "text/html; charset=utf-8") (list body)))

(defun %banner-args (args)
  "The subset of UPDATE-ROUTER's keywords that the banner takes."
  (loop for (k v) on args by #'cddr
        when (member k '(:prefix :id :labels :notes-url :csrf-token))
          append (list k v)))

(defun update-router (&rest args &key (check t) prefix id labels notes-url csrf-token)
  "A router answering the three update routes. MOUNT it under +UPDATE-PREFIX+.

    (router:router (router:mount up-ui:+update-prefix+ (up-ui:update-router)))

CHECK (default T) makes GET /status perform the check rather than report the last one.
Design section 8: \"the check itself is the poll\". Pass NIL for an app that checks on its
own schedule and wants the route to read the cached state -- and for a suite that must not
reach the network.

CSRF-TOKEN is a string or a thunk of no arguments; a thunk is re-called per request, which
is what a per-session token requires."
  (declare (ignore prefix id labels notes-url csrf-token))
  (let ((banner-args (%banner-args args)))
    (flet ((render (status env)
             (declare (ignore env))
             (let ((a (copy-list banner-args)))
               ;; A token that is a thunk is resolved per request: one token baked in at
               ;; router-construction time would be one session's, handed to everybody.
               (let ((tok (getf a :csrf-token)))
                 (when (functionp tok) (setf (getf a :csrf-token) (funcall tok))))
               (%html (apply #'update-banner status a)))))
      (router:router
       (router:route
        :get +status-path+
        (lambda (env)
          (render (if check (up:check-for-update) (up:update-status)) env))
        :name :update-status)
       (router:route
        :post +apply-path+
        (lambda (env)
          ;; APPLY-UPDATE signals `update-not-implemented' on every platform #72 has not
          ;; produced an artifact for, which today is macOS and Linux. That is an ordinary
          ;; answer with a sentence attached, not a 500: render it as a block so the user
          ;; reads the reason instead of a stack trace.
          (render (handler-case (up:apply-update)
                    (up:update-not-implemented (e)
                      (list :status "blocked" :version (getf (up:update-status) :version)
                            :block "not-implemented"
                            :detail (princ-to-string
                                     (up:update-not-implemented-detail e)))))
                  env))
        :name :update-apply)
       (router:route
        :post +restart-path+
        (lambda (env)
          (render (handler-case
                      (progn
                        (unless *restart*
                          (error 'restart-not-supported
                                 :detail "this application did not supply a restart handler"))
                        (funcall *restart*)
                        (up:update-status))
                    (error (e)
                      (list :status "blocked" :version (getf (up:update-status) :version)
                            :block "restart-failed" :detail (princ-to-string e))))
                  env))
        :name :update-restart)))))
