;;;; dialog.lisp --- dialogs, the destructive confirm, and the undo notice (#981)
;;;;
;;;; A dialog is the browser's own <dialog>, opened with showModal(). The browser then makes
;;;; the rest of the page inert, keeps focus inside the dialog, and focuses the element marked
;;;; autofocus. DIALOG-JS adds the behaviour hyperion pages rely on and that browsers do not
;;;; all give:
;;;;
;;;;   - a dialog whose contents htmx loads opens only after they have settled, so the
;;;;     autofocus element the browser focuses is the loaded one;
;;;;   - Escape closes it;
;;;;   - closing it, by any route, returns focus to the control that opened it. The browser
;;;;     returns focus to whatever had it when the dialog opened, and clicking a button does
;;;;     not focus it in every browser (Safari and Firefox on macOS), so that is not always
;;;;     the opener.
;;;;
;;;; DIALOG-JS is one set of listeners on the document, installed once however many times a
;;;; page includes it, so dialogs that htmx loads later need nothing extra.
;;;;
;;;; The destructive confirm has one fixed layout: Cancel on the left with the initial focus,
;;;; so Enter does not destroy anything, and on the right the action, named by what it does
;;;; and styled as danger. The undo notice goes into a NOTICE-REGION, a role="status" live
;;;; region that is on the page before any notice arrives, so screen readers announce it. It
;;;; has no timer: it stays until it is dismissed, undone or replaced.

(cl:defpackage #:hyperion/kit/dialog
  (:use #:cl)
  (:local-nicknames (#:spin #:spinneret)
                    (#:out #:hyperion/output))
  ;; Parenscript matches its own macros by symbol identity, so these are the real ones, as
  ;; in hyperion/js.
  (:import-from #:parenscript #:chain #:@)
  (:documentation
   "Dialogs (DIALOG, DIALOG-OPENER), the destructive confirm (CONFIRM-DIALOG), the undo
    notice (UNDO-NOTICE, NOTICE-REGION), and the Parenscript behind them (DIALOG-JS).")
  (:export #:dialog #:dialog-opener #:confirm-dialog
           #:notice-region #:undo-notice #:*notice-region-id*
           #:dialog-js))

(in-package #:hyperion/kit/dialog)

(defun %title-id (id) (format nil "~A-title" id))
(defun %body-id (id) (format nil "~A-body" id))

(defun dialog (id title &key body (close-label "Close"))
  "Write a dialog into SPINNERET:*HTML*: a closed <dialog> with ID, named by TITLE through
aria-labelledby, with a close button labelled CLOSE-LABEL. BODY is a function that writes
the dialog's contents. Leave BODY out for a dialog whose contents htmx loads: DIALOG-OPENER
with an HREF loads them into the element whose id is ID followed by \"-body\".

Mark the field to focus first with autofocus; the browser focuses it when the dialog opens.
Include DIALOG-JS once on the page."
  (spin:with-html
    (:dialog :id id :class "hy-dialog" :aria-labelledby (%title-id id)
      (:div :class "hy-dialog-head"
        (:h2 :id (%title-id id) :class "hy-dialog-title" title)
        (:button :type "button" :class "delete hy-dialog-close" :aria-label close-label
                 :data-hy-dialog-close "true"))
      (:div :id (%body-id id) :class "hy-dialog-body"
        (when body (funcall body))))))

(defun dialog-opener (dialog-id label &key href id (class "button"))
  "Write a button that opens the dialog DIALOG-ID into SPINNERET:*HTML*. With HREF, htmx
first loads HREF into the dialog's body, and the dialog opens when the contents have
settled, so the autofocus field it focuses is the loaded one. ID is the button's own id."
  (spin:with-html
    (:button :type "button" :id id :class class
             :aria-haspopup "dialog" :aria-controls dialog-id
             :data-hy-dialog-open dialog-id
             :hx-get href
             :hx-target (and href (format nil "#~A" (%body-id dialog-id)))
             :hx-swap (and href "innerHTML")
      label)))

(defun confirm-dialog (id title text &key action-href action-label (cancel-label "Cancel")
                                          (close-label "Close") hx-target hx-swap)
  "Write a destructive-action confirm into SPINNERET:*HTML*: a dialog with ID and TITLE, TEXT
as one paragraph, and two buttons in a fixed order. Cancel, labelled CANCEL-LABEL, is on the
left and has the initial focus, so Enter cancels. The action is on the right: a submit
button labelled ACTION-LABEL, which names what it does (\"Delete 3 drafts\", never \"OK\"),
styled as danger.

The action posts to ACTION-HREF with htmx and closes the dialog when the request succeeds.
It is disabled while its request is in flight, so a double click posts once.
HX-TARGET receives the response, swapped by HX-SWAP (\"outerHTML\" by default); with no
HX-TARGET the response is not swapped anywhere. Signals unless ACTION-HREF and ACTION-LABEL
are given."
  (unless (and (stringp action-href) (stringp action-label))
    (error "A confirm needs ACTION-HREF and ACTION-LABEL, the request it sends and the words that name it."))
  (dialog id title
          :close-label close-label
          :body (lambda ()
                  (spin:with-html
                    (:p :class "hy-confirm-text" text)
                    (:form :class "hy-confirm-actions" :method "post" :action action-href
                           :hx-post action-href :hx-target hx-target
                           :hx-swap (or hx-swap (if hx-target "outerHTML" "none"))
                           ;; The form sends the request, so the submit button is found from
                           ;; it. A disabled button cannot be pressed again while the request
                           ;; is in flight, so a double click posts once.
                           :hx-disabled-elt "find [type=submit]"
                           :data-hy-close-on-success "true"
                      (:button :type "button" :id (format nil "~A-cancel" id) :class "button"
                               :data-hy-dialog-close "true" :autofocus t
                        cancel-label)
                      (:button :type "submit" :id (format nil "~A-action" id)
                               :class "button is-danger"
                        action-label))))))

(defparameter *notice-region-id* "hy-notices"
  "The id NOTICE-REGION gives its element by default, and where UNDO-NOTICE sends a notice.")

(defun notice-region (&key (id *notice-region-id*))
  "Write the region notices go into, into SPINNERET:*HTML*: an empty role=\"status\" live
region. Put it on the page once, before any notice arrives. A live region that is added
together with its message is not announced reliably, which is why it is separate."
  (spin:with-html
    (:div :id id :class "hy-notices" :role "status" :aria-live "polite")))

(defun undo-notice (text &key undo-href (undo-label "Undo") (dismiss-label "Dismiss")
                              (region *notice-region-id*) oob)
  "Write an undo notice into SPINNERET:*HTML*: TEXT, an Undo button, and a dismiss button. Undo
posts to UNDO-HREF with htmx, and the response replaces the notice, so a response with no
content removes it. Dismiss removes the notice. Neither needs a timer.

With OOB, the notice is wrapped so that htmx appends it to REGION, the NOTICE-REGION's id,
from any response: the handler that moved something to the trash returns its own content
plus this notice."
  (flet ((notice ()
           (spin:with-html
             (:div :class "hy-undo-notice" :data-hy-notice "true"
               (:span :class "hy-undo-text" text)
               (when undo-href
                 (:button :type "button" :class "button is-small hy-undo"
                          :hx-post undo-href :hx-target "closest [data-hy-notice]"
                          :hx-swap "outerHTML"
                   undo-label))
               (:button :type "button" :class "delete hy-undo-dismiss" :aria-label dismiss-label
                        :data-hy-dismiss "true")))))
    (if oob
        ;; htmx appends the CHILDREN of an element swapped with beforeend, so the notice is
        ;; wrapped in one.
        (spin:with-html
          (:div :hx-swap-oob (format nil "beforeend:#~A" region) (notice)))
        (notice))))

(defun dialog-js ()
  "Compiled JS for every dialog, opener, confirm and notice on the page, installed once on
the document. Include it once with (:script (:raw (dialog-js)))."
  (out:js-string
   '(funcall
     (lambda ()
       (unless (@ window hy-kit-dialogs)
         (setf (@ window hy-kit-dialogs) t)
;; LET* because CLOSE-DIALOG calls RETURN-FOCUS: Parenscript renames a parallel LET's
         ;; bindings, and the call would name a function that does not exist.
         (let* ((find-up (lambda (el selector)
                          (if (and el (@ el closest)) (chain el (closest selector)) nil)))
               ;; showModal() focuses the dialog's autofocus element itself.
               (open-dialog (lambda (d)
                              (unless (@ d open) (chain d (show-modal)))))
               (return-focus (lambda (d)
                               (let ((o (@ d hy-opener)))
                                 (setf (@ d hy-pending) nil)
                                 (when (and o (@ o is-connected))
                                   (chain o (focus))))))
               ;; The routes this script owns return focus straight after close(). The close
               ;; event is fired later, as a separate task, and catches the routes it does not
               ;; own, such as a form with method="dialog".
               (close-dialog (lambda (d)
                               (chain d (close))
                               (return-focus d))))
           ;; An opener records itself on its dialog. One with hx-get waits for htmx to
           ;; settle the loaded contents before the dialog opens.
           (chain document
                  (add-event-listener
                   "click"
                   (lambda (e)
                     (let ((opener (find-up (@ e target) "[data-hy-dialog-open]"))
                           (closer (find-up (@ e target) "[data-hy-dialog-close]"))
                           (dismiss (find-up (@ e target) "[data-hy-dismiss]")))
                       (when opener
                         (let ((d (chain document
                                         (get-element-by-id
                                          (chain opener (get-attribute "data-hy-dialog-open"))))))
                           (when d
                             (setf (@ d hy-opener) opener)
                             (if (chain opener (has-attribute "hx-get"))
                                 (setf (@ d hy-pending) t)
                                 (open-dialog d)))))
                       (when closer
                         (let ((d (find-up closer "dialog")))
                           (when d (close-dialog d))))
                       (when dismiss
                         (let ((n (find-up dismiss "[data-hy-notice]")))
                           (when n (chain n (remove)))))))))
           ;; Escape closes the open dialog it was pressed in. Handled here rather than left
           ;; to the browser's cancel, so every route to closing is the same one.
           (chain document
                  (add-event-listener
                   "keydown"
                   (lambda (e)
                     (when (equal (@ e key) "Escape")
                       (let ((d (find-up (@ e target) "dialog[open]")))
                         (when d
                           (chain e (prevent-default))
                           (close-dialog d)))))))
           ;; close does not bubble, so this listens in the capture phase.
           (chain document
                  (add-event-listener
                   "close"
                   (lambda (e)
                     (let ((d (@ e target)))
                       ;; Only when focus is still inside the closed dialog, or nowhere, so a
                       ;; late event does not take focus back from where the visitor has moved.
                       (when (or (not (@ document active-element))
                                 (eq (@ document active-element) (@ document body))
                                 (chain d (contains (@ document active-element))))
                         (return-focus d))))
                   t))
           (chain document
                  (add-event-listener
                   "htmx:afterSettle"
                   (lambda (e)
                     (let ((d (find-up (@ e target) "dialog")))
                       (when (and d (@ d hy-pending))
                         (setf (@ d hy-pending) nil)
                         (open-dialog d))))))
           (chain document
                  (add-event-listener
                   "htmx:afterRequest"
                   (lambda (e)
                     (let ((el (@ e target)))
                       (when (and (@ e detail successful)
                                  (@ el has-attribute)
                                  (chain el (has-attribute "data-hy-close-on-success")))
                         (let ((d (find-up el "dialog[open]")))
                           (when d (close-dialog d))))))))))))))
