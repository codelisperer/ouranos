;;;; kit-tests.lisp --- hyperion/kit's components, read back from the markup they write (#981)
;;;;
;;;; The markup is parsed with Plump rather than searched as a string, so a test asks for an
;;;; element and its attributes, the way assistive technology reads them, and does not depend
;;;; on whether Spinneret quoted an attribute value.

(cl:defpackage #:hyperion/kit/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:page #:hyperion/kit/page)
                    (#:toggle #:hyperion/kit/toggle)
                    (#:dlg #:hyperion/kit/dialog)
                    (#:spin #:spinneret))
  (:export #:run-tests))

(in-package #:hyperion/kit/tests)

(def-suite kit :description "hyperion/kit: roles, names and pressed state.")
(in-suite kit)

(defun run-tests ()
  "Run the kit suite; true when every check passes."
  (run! 'kit))

(defparameter *closes-p*
  '("address" "article" "aside" "div" "footer" "form" "h1" "h2" "h3" "h4" "h5" "h6"
    "header" "nav" "ol" "p" "section" "table" "ul")
  "Start tags that end an open <p>, from HTML5's rules for optional end tags.")

(defun %close-optional-tags (html)
  "HTML with the </li> and </p> end tags that Spinneret leaves out written back in, by
HTML5's rules: an <li> ends at the next <li> or at its list's end, and a <p> ends at a block
start tag or at its parent's end. Plump does not apply these rules, and without them it
nests the next item inside the open one."
  (let ((stack '()) (out (make-string-output-stream)) (i 0))
    (labels ((close-to (pred)
               ;; Close open li/p elements above the first element satisfying PRED.
               (loop while (and stack (member (first stack) '("li" "p") :test #'string=)
                                (not (funcall pred (first stack))))
                     do (format out "</~A>" (pop stack))))
             (name-of (tag start)
               (let ((end (position-if (lambda (c) (member c '(#\Space #\Newline #\> #\/)))
                                       tag :start start)))
                 (string-downcase (subseq tag start end)))))
      (loop for lt = (position #\< html :start i)
            while lt
            do (write-string html out :start i :end lt)
               (let* ((gt (position #\> html :start lt))
                      (tag (subseq html lt (1+ gt))))
                 (if (char= #\/ (char tag 1))
                     (let ((name (name-of tag 2)))
                       (close-to (lambda (open) (string= open name)))
                       (when (and stack (string= (first stack) name)) (pop stack)))
                     (let ((name (name-of tag 1)))
                       (cond ((string= name "li")
                              (close-to (lambda (open) (member open '("ol" "ul") :test #'string=)))
                              (when (and stack (string= (first stack) "li"))
                                (write-string "</li>" out) (pop stack)))
                             ((member name *closes-p* :test #'string=)
                              (when (and stack (string= (first stack) "p"))
                                (write-string "</p>" out) (pop stack))))
                       (unless (member name '("br" "hr" "img" "input" "meta" "link")
                                       :test #'string=)
                         (push name stack))))
                 (write-string tag out)
                 (setf i (1+ gt))))
      (write-string html out :start i)
      (loop while stack do (let ((open (pop stack)))
                             (when (member open '("li" "p") :test #'string=)
                               (format out "</~A>" open))))
      (get-output-stream-string out))))

(defun %dom (thunk)
  "The Plump document for what THUNK writes into SPINNERET:*HTML*, with the optional end
tags written back in first."
  (plump:parse (%close-optional-tags (spin:with-html-string (funcall thunk)))))

(defun %all (node tag)
  (coerce (plump:get-elements-by-tag-name node tag) 'list))

(defun %one (node tag)
  "The only TAG element under NODE, or NIL when there is none or more than one."
  (let ((found (%all node tag)))
    (and (= 1 (length found)) (first found))))

(defun %attr (element name)
  (and element (plump:attribute element name)))

(defun %text (element)
  (and element (string-trim '(#\Space #\Newline #\Tab) (plump:text element))))

(test the-test-parser-closes-what-spinneret-leaves-open
  "The helper every other test reads through: an unclosed <li> ends at the next one or at
the list's end, and an unclosed <p> ends at a block or at its parent's end."
  (is (equal "<ol><li>a</li><li>b</li></ol>" (%close-optional-tags "<ol><li>a<li>b</ol>")))
  (is (equal "<div><p>t</p><div>x</div><p>u <a href=/>l</a></p></div>"
             (%close-optional-tags "<div><p>t<div>x</div><p>u <a href=/>l</a></div>"))))

;;; --- breadcrumbs ----------------------------------------------------------------

(defun %crumbs (&rest args)
  (%dom (lambda ()
          (apply #'page:breadcrumbs '(("Home" . "/") ("Drafts" . "/drafts") ("Chapter one" . "/drafts/1"))
                 args))))

(test breadcrumbs-are-an-ordered-list-in-a-named-nav
  (let* ((dom (%crumbs))
         (nav (%one dom "nav")))
    (is (equal "Breadcrumb" (%attr nav "aria-label")))
    (is (not (null (%one nav "ol"))))
    (is (= 3 (length (%all nav "li"))))))

(test the-last-breadcrumb-is-the-current-page-and-not-a-link
  (let* ((dom (%crumbs))
         (items (%all dom "li"))
         (last (car (last items))))
    (is (null (%all last "a")))
    (is (equal "page" (%attr (%one last "span") "aria-current")))
    (is (equal "Chapter one" (%text last)))
    (is (= 1 (length (remove-if-not (lambda (e) (%attr e "aria-current")) (%all dom "span"))))
        "only the current page is marked")))

(test earlier-breadcrumbs-are-links-or-text
  (let* ((dom (%dom (lambda ()
                      (page:breadcrumbs '(("Home" . "/") ("Archive" . nil) ("Now" . "/now"))))))
         (items (%all dom "li")))
    (is (equal "/" (%attr (%one (first items) "a") "href")))
    (is (null (%all (second items) "a")) "an item with no href is text")
    (is (null (%attr (%one (second items) "span") "aria-current")))))

(test breadcrumbs-use-htmx-only-with-a-target
  (let ((plain (%one (first (%all (%crumbs) "li")) "a"))
        (hx (%one (first (%all (%crumbs :hx-target "#main") "li")) "a")))
    (is (null (%attr plain "hx-get")))
    (is (equal "/" (%attr hx "hx-get")))
    (is (equal "#main" (%attr hx "hx-target")))
    (is (equal "true" (%attr hx "hx-push-url")))))

;;; An href goes into the page only with http, https or no scheme at all (#1005's review).
(defparameter *unsafe-hrefs*
  (list "javascript:alert(1)" " JavaScript:alert(1)"
        (format nil "java~Cscript:alert(1)" #\Tab)
        "data:text/html,<b>x</b>" "vbscript:msgbox(1)")
  "Hrefs that must not become links, including the spellings a browser reads as javascript:.")

(test a-script-href-is-written-as-text-and-not-as-a-link
  (dolist (href *unsafe-hrefs*)
    (let* ((crumbs (%dom (lambda ()
                           (page:breadcrumbs (list (cons "Home" href) (cons "Now" "/now"))))))
           (empty (%dom (lambda ()
                          (page:empty-state "No drafts" :action-label "New draft"
                                                        :action-href href)))))
      (is (null (%all crumbs "a")) "breadcrumb ~S became a link" href)
      (is (equal "Home" (%text (first (%all crumbs "li")))))
      (is (null (%all empty "a")) "empty-state action ~S became a link" href)
      (is (equal "New draft" (%text (%one empty "span"))))
      (is (null (%attr (%one empty "span") "class"))
          "the text does not keep the button's class"))))

(test http-https-and-relative-hrefs-stay-links
  (dolist (href '("/drafts" "drafts?a=b:c" "#top" "https://example.com/x" "HTTP://example.com"))
    (is (equal href (%attr (%one (%dom (lambda ()
                                         (page:breadcrumbs (list (cons "Home" href)
                                                                 (cons "Now" "/now")))))
                                 "a")
                           "href")))))

(test a-character-reference-in-an-href-stays-five-characters
  "javascript&#58; has no colon for the scheme check to find. It is safe only because
Spinneret writes the ampersand as &amp;, so the browser reads the href as those characters
and not as javascript:."
  (let ((html (spin:with-html-string
                (page:breadcrumbs '(("Home" . "javascript&#58;alert(1)") ("Now" . "/now"))))))
    (is-true (search "javascript&amp;#58;alert(1)" html))
    (is (null (search "javascript&#58;" html)))))

(test breadcrumbs-take-a-translated-label
  (is (equal "Fil d'Ariane" (%attr (%one (%crumbs :label "Fil d'Ariane") "nav") "aria-label"))))

;;; --- page header ----------------------------------------------------------------

(test the-page-header-has-one-h1-and-its-parts
  (let* ((dom (%dom (lambda ()
                      (page:page-header "Drafts"
                                        :subtitle "Everything not yet published"
                                        :breadcrumbs '(("Home" . "/") ("Drafts" . "/drafts"))
                                        :actions (lambda ()
                                                   (spin:with-html
                                                     (:button :class "button" "New draft")))))))
         (header (%one dom "header")))
    (is (equal "Drafts" (%text (%one header "h1"))))
    (is (equal "Everything not yet published" (%text (%one header "p"))))
    (is (equal "New draft" (%text (%one header "button"))))
    (is (equal "Breadcrumb" (%attr (%one header "nav") "aria-label")))))

(test the-page-header-leaves-out-what-it-is-not-given
  (let* ((dom (%dom (lambda () (page:page-header "Drafts"))))
         (header (%one dom "header")))
    (is (not (null (%one header "h1"))))
    (is (null (%all header "nav")))
    (is (null (%all header "p")))
    (is (null (%all header "button")))))

;;; --- empty state ----------------------------------------------------------------

(test the-empty-state-has-a-heading-a-line-and-one-action
  (let* ((dom (%dom (lambda ()
                      (page:empty-state "No drafts yet" :text "Start one to see it here."
                                        :action-label "New draft" :action-href "/drafts/new"))))
         (link (%one dom "a")))
    (is (equal "No drafts yet" (%text (%one dom "h2"))))
    (is (equal "Start one to see it here." (%text (%one dom "p"))))
    (is (equal "/drafts/new" (%attr link "href")))
    (is (equal "New draft" (%text link)))
    (is (search "is-primary" (%attr link "class")))))

(test the-empty-state-heading-level-is-the-app-s-choice
  (is (not (null (%one (%dom (lambda () (page:empty-state "None" :heading-level 3))) "h3"))))
  (signals error (page:empty-state "None" :heading-level 7)))

(test the-empty-state-has-no-action-without-both-label-and-href
  (is (null (%all (%dom (lambda () (page:empty-state "None" :action-label "Add"))) "a")))
  (is (null (%all (%dom (lambda () (page:empty-state "None" :action-href "/add"))) "a"))))

;;; --- segmented control and toggle group ------------------------------------------

(defparameter *views*
  '(("list" "List" "/drafts?view=list")
    ("grid" "Grid" "/drafts?view=grid")
    ("board" "Board" "/drafts?view=board")))

(defun %pressed (dom)
  "The value of every button, with its aria-pressed, in order."
  (mapcar (lambda (b) (list (%attr b "data-value") (%attr b "aria-pressed")))
          (%all dom "button")))

(test a-segmented-control-is-a-named-group-of-buttons
  (let* ((dom (%dom (lambda () (toggle:segmented-control "View" *views* :selected "grid"))))
         (group (%one dom "div")))
    (is (equal "group" (%attr group "role")))
    (is (equal "View" (%attr group "aria-label")))
    (is (= 3 (length (%all group "button"))))
    (is (every (lambda (b) (equal "button" (%attr b "type"))) (%all group "button"))
        "type=button, so a press inside a form does not submit it")))

(test a-segmented-control-presses-exactly-the-selected-option
  (is (equal '(("list" "false") ("grid" "true") ("board" "false"))
             (%pressed (%dom (lambda ()
                               (toggle:segmented-control "View" *views* :selected "grid")))))))

(test a-segmented-control-refuses-a-selection-it-cannot-show
  (signals error (toggle:segmented-control "View" *views* :selected "table"))
  (signals error (toggle:segmented-control "View" *views*))
  (signals error (toggle:segmented-control "View" (cons '("grid" "Grid again" "/g") *views*)
                                           :selected "grid"))
  (signals error (toggle:segmented-control "View" '(("list" "List")) :selected "list"))
  (signals error (toggle:segmented-control "View" '(("list" "List" nil)) :selected "list")
    "an option without an href could not be pressed")
  (signals error (toggle:toggle-group "Show" '((:list "List" "/l")))))

(test no-button-has-a-tabindex-or-is-disabled
  "Nothing takes a button out of the tab order: no button has a tabindex or is disabled.
Enter and Space are the browser's own behaviour for a <button>, which this does not test."
  (let ((dom (%dom (lambda ()
                     (toggle:segmented-control "View" *views* :selected "list")
                     (toggle:toggle-group "Show" *views* :pressed '("grid"))))))
    (is (= 6 (length (%all dom "button"))))
    (is (notany (lambda (b) (%attr b "tabindex")) (%all dom "button")))
    (is (notany (lambda (b) (%attr b "disabled")) (%all dom "button")))))

(test a-button-loads-its-href-into-the-target
  (let* ((body (first (%all (%dom (lambda ()
                                    (toggle:segmented-control "View" *views* :selected "list")))
                            "button")))
         (list (first (%all (%dom (lambda ()
                                    (toggle:segmented-control "View" *views* :selected "list"
                                                              :hx-target "#drafts")))
                            "button"))))
    (is (equal "/drafts?view=list" (%attr body "hx-get")))
    (is (equal "body" (%attr body "hx-target")))
    (is (equal "innerHTML" (%attr body "hx-swap")))
    (is (equal "true" (%attr body "hx-push-url")))
    (is (equal "#drafts" (%attr list "hx-target")))
    (is (equal "outerHTML" (%attr list "hx-swap")))))

(test a-toggle-group-presses-each-option-independently
  (let ((dom (%dom (lambda () (toggle:toggle-group "Show" *views* :pressed '("list" "board"))))))
    (is (equal "group" (%attr (%one dom "div") "role")))
    (is (equal "Show" (%attr (%one dom "div") "aria-label")))
    (is (equal '(("list" "true") ("grid" "false") ("board" "true")) (%pressed dom))))
  (is (equal '(("list" "false") ("grid" "false") ("board" "false"))
             (%pressed (%dom (lambda () (toggle:toggle-group "Show" *views*)))))
      "none pressed is allowed"))


;;; --- escaping -------------------------------------------------------------------

(defparameter *hostile* "<script>alert(1)</script>\" onmouseover=\"x"
  "Text that would add an element, or end an attribute and add another, if it were not
escaped.")

(defun %shown (element)
  "ELEMENT's text as a browser shows it: each run of whitespace is one space. Spinneret
breaks a long text onto a new line, which renders as a space."
  (let ((text (%text element)))
    (and text
         (with-output-to-string (out)
           (loop with gap = nil
                 for c across text
                 do (if (member c '(#\Space #\Newline #\Tab #\Return))
                        (setf gap t)
                        (progn (when gap (write-char #\Space out) (setf gap nil))
                               (write-char c out))))))))

(test text-and-attributes-are-escaped
  "A title, a label and an attribute value come back from the parsed page exactly as given,
and add no element and no attribute."
  (let ((dom (%dom (lambda ()
                     (page:page-header *hostile* :subtitle *hostile*
                                                 :breadcrumbs (list (cons *hostile* "/a")
                                                                    (cons "Now" "/now")))
                     (toggle:segmented-control *hostile*
                                               (list (list "list" *hostile* "/l?q=\"x"))
                                               :selected "list")))))
    (is (null (%all dom "script")))
    (is (equal *hostile* (%shown (%one dom "h1"))) "the title")
    (is (equal *hostile* (%shown (%one dom "p"))) "the subtitle")
    (is (equal *hostile* (%shown (%one dom "a"))) "a breadcrumb's label")
    (is (equal *hostile* (%shown (%one dom "button"))) "an option's label")
    (is (equal *hostile* (%attr (find "group" (%all dom "div")
                                      :key (lambda (d) (%attr d "role")) :test #'equal)
                                "aria-label"))
        "an attribute")
    (is (equal "/l?q=\"x" (%attr (%one dom "button") "hx-get")) "a quote in an href")
    (is (notany (lambda (e) (%attr e "onmouseover"))
                (append (%all dom "a") (%all dom "button") (%all dom "div") (%all dom "h1"))))))

;;; --- dialogs, the confirm and the undo notice ----------------------------------
;;;
;;; What these components do in a browser (focus, Escape, closing on success) is checked by
;;; kit-browser-tests in hyperion/assets/tests. These check the markup that behaviour reads.

(defun %by-id (dom id)
  (plump:get-element-by-id dom id))

(test a-dialog-is-named-by-its-title-and-has-a-named-close-button
  (let* ((dom (%dom (lambda () (dlg:dialog "create" "New draft" :close-label "Fermer"))))
         (d (%one dom "dialog"))
         (close (%one dom "button")))
    (is (equal "create" (%attr d "id")))
    (is (null (%attr d "open")) "a dialog is written closed")
    (is (equal "create-title" (%attr d "aria-labelledby")))
    (is (equal "New draft" (%text (%by-id dom "create-title"))))
    (is (equal "button" (%attr close "type")) "the close button never submits a form")
    (is (equal "Fermer" (%attr close "aria-label")))
    (is (%attr close "data-hy-dialog-close"))
    (is (%by-id dom "create-body") "the body has the id an opener loads into")))

(test a-dialog-writes-the-body-it-is-given
  (let ((dom (%dom (lambda ()
                     (dlg:dialog "create" "New draft"
                                 :body (lambda () (spin:with-html (:input :id "name"))))))))
    (is (eq (%by-id dom "create-body") (plump:parent (%by-id dom "name"))))))

(test an-opener-names-its-dialog-and-loads-only-with-an-href
  (let ((plain (%one (%dom (lambda () (dlg:dialog-opener "create" "New draft"))) "button"))
        (loads (%one (%dom (lambda () (dlg:dialog-opener "create" "New draft" :href "/new")))
                     "button")))
    (is (equal "dialog" (%attr plain "aria-haspopup")))
    (is (equal "create" (%attr plain "aria-controls")))
    (is (equal "create" (%attr plain "data-hy-dialog-open")))
    (is (equal "button" (%attr plain "type")))
    (is (equal "New draft" (%text plain)))
    (is (null (%attr plain "hx-get")) "no href, no request")
    (is (equal "/new" (%attr loads "hx-get")))
    (is (equal "#create-body" (%attr loads "hx-target")))
    (is (equal "innerHTML" (%attr loads "hx-swap")))))

(defun %confirm (&rest args)
  (%dom (lambda ()
          (apply #'dlg:confirm-dialog "confirm" "Delete 3 drafts?" "They go to the trash."
                 (append args '(:action-href "/drafts/delete" :action-label "Delete 3 drafts"))))))

(test the-confirm-puts-cancel-first-with-focus-and-the-named-action-last
  (let* ((dom (%confirm))
         (form (%one dom "form"))
         (buttons (%all form "button"))
         (cancel (first buttons))
         (action (car (last buttons))))
    (is (= 2 (length buttons)))
    (is (equal "confirm-cancel" (%attr cancel "id")))
    (is (equal "button" (%attr cancel "type")) "Cancel never submits")
    (is (%attr cancel "autofocus") "Cancel has the initial focus, so Enter cancels")
    (is (%attr cancel "data-hy-dialog-close"))
    (is (equal "confirm-action" (%attr action "id")))
    (is (equal "submit" (%attr action "type")))
    (is (equal "Delete 3 drafts" (%text action)))
    (is (search "is-danger" (%attr action "class")))
    (is (null (%attr action "autofocus")))
    (is (equal "They go to the trash." (%text (%one dom "p"))))))

(test the-confirm-posts-and-closes-on-success
  (let ((form (%one (%confirm) "form"))
        (targeted (%one (%confirm :hx-target "#drafts") "form"))
        (swapped (%one (%confirm :hx-target "#drafts" :hx-swap "innerHTML") "form")))
    (is (equal "/drafts/delete" (%attr form "hx-post")))
    (is (equal "/drafts/delete" (%attr form "action")) "the form still posts without htmx")
    (is (%attr form "data-hy-close-on-success"))
    (is (equal "none" (%attr form "hx-swap")) "with no target the response goes nowhere")
    (is (equal "#drafts" (%attr targeted "hx-target")))
    (is (equal "outerHTML" (%attr targeted "hx-swap")))
    (is (equal "innerHTML" (%attr swapped "hx-swap")))))

(test the-confirm-refuses-to-be-written-without-its-action
  (signals error (spin:with-html-string
                   (dlg:confirm-dialog "c" "Delete?" "Sure?" :action-href "/d")))
  (signals error (spin:with-html-string
                   (dlg:confirm-dialog "c" "Delete?" "Sure?" :action-label "Delete"))))

(test the-notice-region-is-a-polite-status-region-that-starts-empty
  (let ((region (%one (%dom (lambda () (dlg:notice-region))) "div")))
    (is (equal dlg:*notice-region-id* (%attr region "id")))
    (is (equal "status" (%attr region "role")))
    (is (equal "polite" (%attr region "aria-live")))
    (is (zerop (length (plump:children region))))))

(test an-undo-notice-has-its-text-an-undo-and-a-named-dismiss
  (let* ((dom (%dom (lambda () (dlg:undo-notice "Moved to trash" :undo-href "/undo"
                                                                  :dismiss-label "Fermer"))))
         (notice (find-if (lambda (d) (%attr d "data-hy-notice")) (%all dom "div")))
         (buttons (%all notice "button")))
    (is (search "Moved to trash" (%text notice)))
    (is (= 2 (length buttons)))
    (is (equal "/undo" (%attr (first buttons) "hx-post")))
    (is (equal "closest [data-hy-notice]" (%attr (first buttons) "hx-target")))
    (is (equal "outerHTML" (%attr (first buttons) "hx-swap")))
    (is (equal "Undo" (%text (first buttons))))
    (is (equal "Fermer" (%attr (second buttons) "aria-label")))
    (is (%attr (second buttons) "data-hy-dismiss")))
  (is (= 1 (length (%all (%dom (lambda () (dlg:undo-notice "Saved"))) "button")))
      "no undo href, only the dismiss button"))

(defun %children (node)
  (coerce (plump:child-elements node) 'list))

(test an-out-of-band-undo-notice-is-appended-to-its-region
  (let* ((dom (%dom (lambda () (dlg:undo-notice "Moved" :undo-href "/u" :oob t :region "n2"))))
         (wrapper (first (%children dom))))
    (is (equal "beforeend:#n2" (%attr wrapper "hx-swap-oob")))
    (is (= 1 (length (%children wrapper))))
    (is (%attr (first (%children wrapper)) "data-hy-notice")
        "the notice is the wrapper's one child, which is what beforeend appends"))
  (is (null (%attr (first (%children (%dom (lambda () (dlg:undo-notice "Moved")))))
                   "hx-swap-oob"))))

(test the-dialog-script-is-guarded-and-listens-for-htmx
  "The compiled script sets a window flag before installing its listeners, so a page can
include it twice, and listens for the two htmx events the opener and the confirm need. What
the listeners do is checked in a browser by kit-browser-tests."
  (let ((js (dlg:dialog-js)))
    (is (search "hyKitDialogs" js) "guarded so a page can include it twice")
    (is (search "showModal" js))
    (is (search "htmx:afterSettle" js))
    (is (search "htmx:afterRequest" js))))
