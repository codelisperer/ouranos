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
  (:export #:page-header #:breadcrumbs #:empty-state #:safe-href-p))

(in-package #:hyperion/kit/page)

(defparameter +allowed-schemes+ '("http" "https")
  "The schemes an href may name. An href with no scheme, a relative path, is allowed too.")

(defun %url-scheme (url)
  "The scheme of URL, lowercased, or NIL if it has none. A URL has a scheme only when a colon
comes before the first slash, question mark or hash. Spaces and control characters are kept,
so ` javascript:' and `java<TAB>script:', which a browser reads as javascript:, have schemes
that are not on the allowed list and are refused. hyperion/markdown drops those characters
before it compares; here the list of schemes is short enough that keeping them can only refuse
an href, never allow one."
  (let ((colon (position #\: url))
        (stop (position-if (lambda (c) (member c '(#\/ #\? #\#))) url)))
    (when (and colon (or (null stop) (< colon stop)))
      (string-downcase (subseq url 0 colon)))))

(defun safe-href-p (href)
  "True when HREF is a string whose scheme is http or https, or which has no scheme. Every kit
component that writes an app's href into the page checks it with this first. A
character reference cannot hide a colon from this check, because Spinneret escapes the
ampersand, so the browser reads `&#58;' as those five characters."
  (and (stringp href)
       (let ((scheme (%url-scheme href)))
         (or (null scheme) (member scheme +allowed-schemes+ :test #'string=)))))

(defun %link (href hx-target class body)
  "An <a> to HREF holding BODY. With HX-TARGET, htmx loads HREF into it and pushes the URL,
the way hyperion/list's links do; without one it is an ordinary link.

An HREF with a scheme other than http or https, such as javascript: or data:, is not written
into the page: BODY is written as plain text in a <span>, with no link and no CLASS, so it
does not look like something that can be pressed. Nothing is signalled, because the HREF
usually comes from data the app stores, and a page that fails to render over one bad value is
worse than a missing link."
  (if (safe-href-p href)
      (spin:with-html
        (:a :href href :class class
            :hx-get (and hx-target href) :hx-target hx-target
            :hx-swap (and hx-target "outerHTML") :hx-push-url (and hx-target "true")
            body))
      (spin:with-html (:span body))))

(defun breadcrumbs (items &key (label "Breadcrumb") hx-target)
  "Write breadcrumbs for ITEMS, a list of (LABEL . HREF) from the outermost page to the
current one, into SPINNERET:*HTML*. They are an ordered list in a <nav> named LABEL. The
last item is the current page: it has aria-current=\"page\" and is not a link. An earlier
item with a NIL HREF is text, and so is one whose HREF names a scheme other than http or https
(see %LINK). The separators are drawn by the stylesheet, so a screen reader
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
styled as a primary button. With HX-TARGET, htmx loads the link into it. An ACTION-HREF that
names a scheme other than http or https is not written: ACTION-LABEL is shown as plain text
instead (see %LINK)."
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
