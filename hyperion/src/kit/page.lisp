;;;; page.lisp --- the page header, breadcrumbs and empty state of a collection page (#981)
;;;;
;;;; Generic components only: each takes its text and links from the app and knows nothing of
;;;; what the page lists. Each writes into SPINNERET:*HTML*, the way hyperion/list's pager
;;;; does, so it composes inside any page body. The stylesheet is (hyperion/assets:url :kit),
;;;; and it is coloured with the --hy-* tokens of hyperion/appearance.

(cl:defpackage #:hyperion/kit/page
  (:use #:cl)
  (:local-nicknames (#:spin #:spinneret))
  (:documentation
   "The page header (PAGE-HEADER), breadcrumbs (BREADCRUMBS) and empty state (EMPTY-STATE)
    of a collection page, written with Spinneret.")
  (:export #:page-header #:breadcrumbs #:empty-state))

(in-package #:hyperion/kit/page)

(defun %link (href hx-target class body)
  "An <a> to HREF holding BODY. With HX-TARGET, htmx loads HREF into it and pushes the URL,
the way hyperion/list's links do; without one it is an ordinary link."
  (spin:with-html
    (:a :href href :class class
        :hx-get (and hx-target href) :hx-target hx-target
        :hx-swap (and hx-target "outerHTML") :hx-push-url (and hx-target "true")
        body)))

(defun breadcrumbs (items &key (label "Breadcrumb") hx-target)
  "Write breadcrumbs for ITEMS, a list of (LABEL . HREF) from the outermost page to the
current one, into SPINNERET:*HTML*. They are an ordered list in a <nav> named LABEL. The
last item is the current page: it has aria-current=\"page\" and is not a link. An earlier
item with a NIL HREF is text. The separators are drawn by the stylesheet, so a screen reader
does not read them."
  (spin:with-html
    (:nav :class "hy-breadcrumbs" :aria-label label
      (:ol
        (loop for ((text . href) . more) on items
              do (spin:with-html
                   (:li (cond ((null more) (:span :aria-current "page" text))
                              (href (%link href hx-target nil text))
                              (t (:span text))))))))))

(defun page-header (title &key subtitle breadcrumbs actions (breadcrumbs-label "Breadcrumb")
                                hx-target)
  "Write a page header into SPINNERET:*HTML*: BREADCRUMBS (as for the function BREADCRUMBS)
when given, TITLE as the page's <h1>, SUBTITLE as one line under it, and ACTIONS, a function
of no arguments that writes the page's action buttons into SPINNERET:*HTML*."
  (spin:with-html
    (:header :class "hy-page-header"
      (when breadcrumbs
        (breadcrumbs breadcrumbs :label breadcrumbs-label :hx-target hx-target))
      (:div :class "hy-page-header-row"
        (:div :class "hy-page-heading"
          (:h1 :class "hy-page-title" title)
          (when subtitle (:p :class "hy-page-subtitle" subtitle)))
        (when actions
          (:div :class "hy-page-actions" (funcall actions)))))))

(defun empty-state (title &key text action-label action-href hx-target (heading-level 2))
  "Write an empty state into SPINNERET:*HTML*: TITLE as a heading at HEADING-LEVEL (2 by
default), TEXT as one line, and, when both ACTION-LABEL and ACTION-HREF are given, one link
styled as a primary button. With HX-TARGET, htmx loads the link into it."
  (check-type heading-level (integer 1 6))
  (spin:with-html
    (:div :class "hy-empty-state"
      (case heading-level
        (1 (:h1 :class "hy-empty-title" title))
        (2 (:h2 :class "hy-empty-title" title))
        (3 (:h3 :class "hy-empty-title" title))
        (4 (:h4 :class "hy-empty-title" title))
        (5 (:h5 :class "hy-empty-title" title))
        (6 (:h6 :class "hy-empty-title" title)))
      (when text (:p :class "hy-empty-text" text))
      ;; In a <div>, not after the <p> alone: Spinneret leaves out </p>, and a browser would
      ;; then put the link inside the paragraph.
      (when (and action-label action-href)
        (:div :class "hy-empty-actions"
          (%link action-href hx-target "button is-primary hy-empty-action" action-label))))))
