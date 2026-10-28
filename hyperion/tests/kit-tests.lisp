;;;; kit-tests.lisp --- hyperion/kit's components, read back from the markup they write (#981)
;;;;
;;;; The markup is parsed with Plump rather than searched as a string, so a test asks for an
;;;; element and its attributes, the way assistive technology reads them, and does not depend
;;;; on whether Spinneret quoted an attribute value.

(cl:defpackage #:hyperion/kit/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:page #:hyperion/kit/page)
                    (#:toggle #:hyperion/kit/toggle)
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

(test every-button-is-its-own-tab-stop
  "Buttons take Enter and Space without script. Nothing takes a button out of the tab
order."
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
