;;;; dock.lisp --- a panel whose contents are loaded from another route, docked in the page (#67)
;;;;
;;;; A page sometimes shows a second, self-contained view beside its own content: a chat, a
;;;; help pane, a preview. DOCK-PANEL writes the region for it. Its contents come from
;;;; CONTENT-HREF, which htmx loads into it, so the view is served by whatever route the app
;;;; mounts there and this component knows nothing about what it shows.
;;;;
;;;; THE HOST'S CONTAINER. The panel goes inside an element the page already has, such as a
;;;; column, a tab panel or a drawer, and fills it: it has no width, position or overlay of its
;;;; own, so it is as wide as that element and resizes with it. It loads when the page does,
;;;; even inside a tab that is not shown, and stays in the page, so switching tabs does not
;;;; reload it. A panel that may never be opened can instead load the first time it is opened
;;;; (:LOAD :ON-OPEN): DOCK-LAUNCHER's button opens it, and a page's own tab or drawer code can
;;;; do the same by dispatching the event hy-dock-open on the panel.
;;;;
;;;; THE LAUNCHER. DOCK-LAUNCHER writes a button that shows and hides a panel, with
;;;; aria-expanded and aria-controls, for a page that keeps the panel closed until asked.
;;;; DOCK-JS, included once per page, makes it work, and dispatches hy-dock-open on the panel
;;;; each time it is shown.
;;;;
;;;; Loading when shown is done with that event rather than htmx's intersect trigger, because
;;;; intersect depends on the browser reporting the panel's visibility, which headless Chrome
;;;; did not do when a hidden panel was shown, so it could not be tested here.
;;;;
;;;; THE HOST'S SCRIPTS. Nothing here loads a script, defines an AMD or UMD module, or assigns
;;;; window.htmx. The page's own htmx loads the contents, and the contents' htmx attributes are
;;;; processed by it like any other swap.

(cl:defpackage #:hyperion/kit/dock
  (:use #:cl)
  (:local-nicknames (#:spin #:spinneret)
                    (#:out #:hyperion/output)
                    (#:page #:hyperion/kit/page))  ; SAFE-HREF-P, for the panel's content-href
  (:import-from #:parenscript #:chain #:@ #:new)
  (:documentation
   "DOCK-PANEL, a region in the host's own container whose contents htmx loads from a route,
    DOCK-LAUNCHER, a button that shows and hides one, and DOCK-JS, the script behind it.")
  (:export #:dock-panel #:dock-launcher #:dock-js #:*dock-id*))

(in-package #:hyperion/kit/dock)

(defparameter *dock-id* "hy-dock"
  "The id DOCK-PANEL gives its element by default, and the panel DOCK-LAUNCHER controls.")

(defun %load-trigger (load)
  (ecase load
    (:at-once "load")
    ;; `once', so closing and opening the panel again does not reload it.
    (:on-open "hy-dock-open once")))

(defun dock-panel (content-href label &key (id *dock-id*) (load :at-once) hidden
                                           (loading-text "Loading…"))
  "Write the panel into SPINNERET:*HTML*: a <section> named LABEL, whose contents htmx loads from
CONTENT-HREF. Put it inside the element of the page it should fill. LOAD is :AT-ONCE, when the
page loads, which works in a tab that is not shown, or :ON-OPEN, the first time the panel gets
the event hy-dock-open, which DOCK-LAUNCHER's button sends when it opens the panel. HIDDEN writes
it hidden, for a panel DOCK-LAUNCHER opens. Until the contents arrive it shows LOADING-TEXT,
announced politely.

Signals when CONTENT-HREF has a scheme other than http or https (PAGE:SAFE-HREF-P). The panel
is loaded by the host page's htmx, whose settings this does not control, and a data: or
javascript: URL there could be fetched and its script run."
  (check-type content-href string)
  (check-type label string)
  (unless (page:safe-href-p content-href)
    (error "A dock panel's CONTENT-HREF must be http, https or relative, not ~S." content-href))
  (spin:with-html
    (:section :id id :class "hy-dock" :aria-label label :hidden hidden
              :hx-get content-href
              :hx-trigger (%load-trigger load)
              :hx-swap "innerHTML"
      (:p :class "hy-dock-loading" :role "status" loading-text))))

(defun dock-launcher (label &key (dock-id *dock-id*) open (class "button") id)
  "Write a button labelled LABEL that shows and hides the panel DOCK-ID, into SPINNERET:*HTML*.
OPEN says whether the panel starts shown, and must match the panel's HIDDEN. The button's
aria-expanded follows the panel; DOCK-JS changes both."
  (spin:with-html
    (:button :type "button" :id id :class class
             :aria-controls dock-id :aria-expanded (if open "true" "false")
             :data-hy-dock-toggle "true"
      label)))

(defun dock-js ()
  "Compiled JS for every launcher on the page, installed once on the document. Include it once
with (:script (:raw (dock-js))). A click on a launcher shows or hides the panel its
aria-controls names, sets its aria-expanded to match, and dispatches hy-dock-open on a panel it
shows."
  (out:js-string
   '(chain document
     (add-event-listener
      "click"
      (lambda (e)
        (let ((button (and (@ e target closest)
                           (chain e target (closest "[data-hy-dock-toggle]")))))
          (when button
            (let ((dock (chain document (get-element-by-id
                                         (chain button (get-attribute "aria-controls"))))))
              (when dock
                (let ((show (@ dock hidden)))
                  (setf (@ dock hidden) (not show))
                  (chain button (set-attribute "aria-expanded"
                                               (if show "true" "false")))
                  (when show
                    (chain dock (dispatch-event (new (*event "hy-dock-open")))))))))))))))
