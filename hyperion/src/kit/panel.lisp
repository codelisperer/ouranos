;;;; panel.lisp --- a list's rows and the properties panel they open (#981)
;;;;
;;;; A master/detail page: choosing a row loads that item's properties into a panel beside the
;;;; list, and the list stays where it is. The app writes its own rows, because what a row
;;;; shows is domain logic; SELECTABLE-ROW gives the attributes that make one choosable, for
;;;; Spinneret's :attrs. The row loads PANEL-HREF into the PANEL-REGION with htmx, on a click
;;;; or on Enter, and is a tab stop so Enter can reach it. The chosen row has
;;;; aria-current="true".
;;;;
;;;; PROPERTIES-PANEL is what PANEL-HREF answers with: an <aside> named by its title, with a
;;;; close button. PANEL-JS, included once per page, moves aria-current to the row that was
;;;; chosen, and closes the panel on its close button or on Escape inside it. Closing empties
;;;; the region and returns focus to the chosen row.

(cl:defpackage #:hyperion/kit/panel
  (:use #:cl)
  (:local-nicknames (#:spin #:spinneret)
                    (#:out #:hyperion/output))
  (:import-from #:parenscript #:chain #:@)
  (:documentation
   "SELECTABLE-ROW, the attributes of a list row that opens a properties panel, PANEL-REGION
    and PROPERTIES-PANEL, and PANEL-JS, the script behind them.")
  (:export #:selectable-row #:panel-region #:properties-panel #:*panel-id* #:panel-js))

(in-package #:hyperion/kit/panel)

(defparameter *panel-id* "hy-panel"
  "The id PANEL-REGION gives its element by default, and where SELECTABLE-ROW loads a panel.")

(defun selectable-row (item-id panel-href &key selected (panel-id *panel-id*))
  "The attributes, as a plist for Spinneret's :attrs, of a row that opens the properties of the
item ITEM-ID: (:tr :attrs (selectable-row id href) ...). The row's id is \"row-\" followed by
ITEM-ID. A click or Enter on it loads PANEL-HREF into the region PANEL-ID. SELECTED marks the
row that is chosen when the page is written; after that, PANEL-JS moves the mark."
  (check-type panel-href string)
  (list :id (format nil "row-~A" item-id)
        :class "hy-row"
        :tabindex "0"
        :data-hy-row "true"
        :aria-controls panel-id
        :aria-current (and selected "true")
        :hx-get panel-href
        :hx-target (format nil "#~A" panel-id)
        :hx-swap "innerHTML"
        ;; Enter on the row itself, not on a control inside it.
        :hx-trigger "click, keydown[key=='Enter' && target.hasAttribute('data-hy-row')]"))

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
                                 (when row (chain row (focus)))))))
           ;; A row about to load its panel becomes the chosen one.
           (chain document
                  (add-event-listener
                   "htmx:beforeRequest"
                   (lambda (e)
                     (let ((row (@ e detail elt)))
                       (when (and row (@ row has-attribute)
                                  (chain row (has-attribute "data-hy-row")))
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
