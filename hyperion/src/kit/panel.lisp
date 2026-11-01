;;;; panel.lisp --- a list's rows and the properties panel they open (#981)
;;;;
;;;; A master/detail page: choosing a row loads that item's properties into a panel beside the
;;;; list, and the list stays where it is. The app writes its own rows, because what a row
;;;; shows is domain logic; SELECTABLE-ROW gives the attributes that make one choosable, for
;;;; Spinneret's :attrs, and ROW-ACTIVATOR writes the button, in the row's first cell, that
;;;; chooses it. The button is what a keyboard or a screen reader uses: it is a tab stop, Enter
;;;; and Space press it, and it is announced as a button. A click anywhere else in the row
;;;; chooses it too, for a pointer, except a click on a link, button or form field inside the
;;;; row, which does only what that control does. Either loads PANEL-HREF into the PANEL-REGION
;;;; with htmx. The chosen row has aria-current="true".
;;;;
;;;; PROPERTIES-PANEL is what PANEL-HREF answers with: an <aside> named by its title, with a
;;;; close button. PANEL-JS, included once per page, moves aria-current to the row that was
;;;; chosen, and closes the panel on its close button or on Escape inside it. Closing empties
;;;; the region and returns focus to the chosen row's button.

(cl:defpackage #:hyperion/kit/panel
  (:use #:cl)
  (:local-nicknames (#:spin #:spinneret)
                    (#:out #:hyperion/output))
  (:import-from #:parenscript #:chain #:@)
  (:documentation
   "SELECTABLE-ROW, the attributes of a list row that opens a properties panel, ROW-ACTIVATOR,
    the button in it that opens the panel, PANEL-REGION and PROPERTIES-PANEL, and PANEL-JS, the
    script behind them.")
  (:export #:selectable-row #:row-activator #:panel-region #:properties-panel #:*panel-id*
           #:panel-js))

(in-package #:hyperion/kit/panel)

(defparameter *panel-id* "hy-panel"
  "The id PANEL-REGION gives its element by default, and where SELECTABLE-ROW loads a panel.")

(defparameter +row-click-trigger+
  "click[!target.closest('a, button, input, select, textarea, label, summary')]"
  "The row's htmx trigger: a click that did not come from a control inside the row. The row's
button is one of those controls, so a click on it sends one request, the button's.")

(defun selectable-row (item-id panel-href &key selected (panel-id *panel-id*))
  "The attributes, as a plist for Spinneret's :attrs, of a row that opens the properties of the
item ITEM-ID: (:tr :attrs (selectable-row id href) (:td (row-activator id href title)) ...).
The row's id is \"row-\" followed by ITEM-ID. A click on the row loads PANEL-HREF into the
region PANEL-ID, unless it came from a link, button or form field inside the row. The row is
not a tab stop and has no role of its own: ROW-ACTIVATOR's button is the control a keyboard
reaches. SELECTED marks the row that is chosen when the page is written; after that, PANEL-JS
moves the mark."
  (check-type panel-href string)
  (list :id (format nil "row-~A" item-id)
        :class "hy-row"
        :data-hy-row "true"
        :aria-controls panel-id
        :aria-current (and selected "true")
        :hx-get panel-href
        :hx-target (format nil "#~A" panel-id)
        :hx-swap "innerHTML"
        :hx-trigger +row-click-trigger+))

(defun row-activator (item-id panel-href label &key (panel-id *panel-id*) (class "hy-row-activator"))
  "Write the button that opens the properties of the item ITEM-ID, labelled LABEL, into
SPINNERET:*HTML*. It goes in the first cell of the row SELECTABLE-ROW made for the same item and
PANEL-HREF, and loads PANEL-HREF into the region PANEL-ID. Its id is \"row-\", ITEM-ID and
\"-open\". CLASS styles it; the default looks like the row's text, not like a button."
  (check-type panel-href string)
  (spin:with-html
    (:button :type "button" :id (format nil "row-~A-open" item-id) :class class
             :data-hy-row-activator "true"
             :aria-controls panel-id
             :hx-get panel-href
             :hx-target (format nil "#~A" panel-id)
             :hx-swap "innerHTML"
      label)))

(defun panel-region (&key (id *panel-id*) (label "Properties"))
  "Write the empty region the properties panel is loaded into, into SPINNERET:*HTML*. LABEL
names it as a landmark, so it can be found before anything is loaded."
  (spin:with-html
    (:section :id id :class "hy-panel-region" :aria-label label)))

(defun properties-panel (title &key body (close-label "Close") (id "hy-properties"))
  "Write the properties panel for one item into SPINNERET:*HTML*: an <aside> named by TITLE,
its <h2>, through aria-labelledby, with a close button labelled CLOSE-LABEL. BODY is a
function that writes the item's properties. This is the response to a SELECTABLE-ROW's
PANEL-HREF."
  (let ((title-id (format nil "~A-title" id)))
    (spin:with-html
      (:aside :id id :class "hy-properties" :aria-labelledby title-id
        (:div :class "hy-properties-head"
          (:h2 :id title-id :class "hy-properties-title" title)
          (:button :type "button" :class "delete hy-properties-close" :aria-label close-label
                   :data-hy-panel-close "true"))
        (:div :class "hy-properties-body"
          (when body (funcall body)))))))

(defun panel-js ()
  "Compiled JS for every selectable row and properties panel on the page, installed once on
the document. Include it once with (:script (:raw (panel-js)))."
  (out:js-string
   '(funcall
     (lambda ()
       (unless (@ window hy-kit-panel)
         (setf (@ window hy-kit-panel) t)
         ;; LET* because CLOSE-PANEL calls CHOSEN-ROW: Parenscript renames a parallel LET's
         ;; bindings.
         (let* ((find-up (lambda (el selector)
                           (if (and el (@ el closest)) (chain el (closest selector)) nil)))
                (chosen-row (lambda (region)
                              (chain document
                                     (query-selector
                                      (+ "[data-hy-row][aria-current=true][aria-controls='"
                                         (@ region id) "']")))))
                (close-panel (lambda (region)
                               (setf (@ region inner-h-t-m-l) "")
                               (let ((row (chosen-row region)))
                                 (when row
                                   ;; The row's button, which is a tab stop; the row is not.
                                   (let ((button (chain row (query-selector
                                                             "[data-hy-row-activator]"))))
                                     (chain (or button row) (focus))))))))
           ;; A row about to load its panel, from a click on it or from its button, becomes the
           ;; chosen one.
           (chain document
                  (add-event-listener
                   "htmx:beforeRequest"
                   (lambda (e)
                     (let* ((elt (@ e detail elt))
                            ;; Only the row and its button: another htmx control in the row
                            ;; does not choose it.
                            (row (and elt (@ elt has-attribute)
                                      (or (chain elt (has-attribute "data-hy-row"))
                                          (chain elt (has-attribute "data-hy-row-activator")))
                                      (find-up elt "[data-hy-row]"))))
                       (when row
                         (chain *array
                                (from (chain document
                                             (query-selector-all
                                              (+ "[data-hy-row][aria-controls='"
                                                 (chain row (get-attribute "aria-controls"))
                                                 "']"))))
                                (for-each (lambda (r) (chain r (remove-attribute "aria-current")))))
                         (chain row (set-attribute "aria-current" "true")))))))
           (chain document
                  (add-event-listener
                   "click"
                   (lambda (e)
                     (let ((closer (find-up (@ e target) "[data-hy-panel-close]")))
                       (when closer
                         (let ((region (find-up closer ".hy-panel-region")))
                           (when region (close-panel region))))))))
           (chain document
                  (add-event-listener
                   "keydown"
                   (lambda (e)
                     (when (equal (@ e key) "Escape")
                       (let ((region (find-up (@ e target) ".hy-panel-region")))
                         (when (and region (chain region (query-selector ".hy-properties")))
                           (chain e (prevent-default))
                           (close-panel region)))))))))))))
