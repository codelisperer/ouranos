;;;; toolbar.lisp --- the search, filter, sort and trash controls above a list (#981)
;;;;
;;;; LIST-TOOLBAR is built on hyperion/list: it reads the list's state and its spec, and the
;;;; requests it makes carry the same parameters LIST-HREF writes for the same change. It is a
;;;; GET form with role="search", so it works without JavaScript: submitting it loads the page
;;;; with the form's fields as the query string. The other parameters of the list, and the
;;;; page's own parameters, ride along as hidden fields; the page is left out, so a new search
;;;; starts on page 1, as LIST-HREF does.
;;;;
;;;; With htmx the form re-requests the list 300ms after typing stops, at once when a select
;;;; changes, and on submit. TOOLBAR-JS, included once per page, makes those requests match
;;;; LIST-HREF's links exactly: it sends them to the page's own path, drops empty fields (a
;;;; filter set to "All") and the default sort key, as LIST-HREF does, and drops the direction
;;;; when the sort key changes, so the new key uses its default direction.
;;;;
;;;; Render the toolbar inside the element the list's htmx target replaces, so its hidden
;;;; fields follow every change the pager, the sort headings and the trash toggle make. The
;;;; search field keeps its value and focus across those swaps (hx-preserve, and htmx puts
;;;; focus back on an element with the same id).

(cl:defpackage #:hyperion/kit/toolbar
  (:use #:cl)
  (:local-nicknames (#:spin #:spinneret)
                    (#:out #:hyperion/output)
                    (#:list #:hyperion/list)
                    (#:toggle #:hyperion/kit/toggle))
  ;; Parenscript matches its own macros by symbol identity, so these are the real ones.
  (:import-from #:parenscript #:chain #:@ #:getprop)
  (:documentation
   "LIST-TOOLBAR, the search, filter, sort and trash controls above a hyperion/list list, and
    TOOLBAR-JS, the script that makes its requests match LIST-HREF.")
  (:export #:list-toolbar #:toolbar-js))

(in-package #:hyperion/kit/toolbar)

(defparameter +trigger+
  "input[target.type=='search'] delay:300ms, change[target.tagName=='SELECT'], submit"
  "When the toolbar's form re-requests the list: 300ms after typing in the search field stops,
when a select changes, and on submit. The filters keep the search field's change event, which
comes when it loses focus, from sending a second request.")

(defun %check-filter (spec name kind)
  "NAME's options when it is a filter of SPEC of KIND, :text or :values; otherwise signal."
  (let ((options (rest (assoc name (list:list-spec-filters spec)))))
    (unless options
      (error "hyperion/kit/toolbar: ~S is not a filter of list ~S" name (list:list-spec-id spec)))
    (unless (if (eq kind :text) (getf options :text) (getf options :values))
      (error "hyperion/kit/toolbar: ~S must be a ~(~A~) filter of list ~S"
             name kind (list:list-spec-id spec)))
    options))

(defun list-toolbar (state &key search (search-label "Search") search-placeholder
                                filters sorts (sort-label "Sort by") (all-label "All")
                                trash (trash-value "trash") (trash-labels '("Active" "Trash"))
                                (view-label "View")
                                hx-target (label "List controls") (id "hy-toolbar"))
  "Write the controls above the list whose STATE is given into SPINNERET:*HTML*. Each argument
names part of the list's spec, and leaving it out leaves out that control.

SEARCH names a :text filter, shown as a search field labelled SEARCH-LABEL. FILTERS is a list
of (NAME LABEL [VALUE-LABELS]) for :values filters, each shown as a select with an ALL-LABEL
option first; VALUE-LABELS is an alist from each value to its text, which defaults to the
value. SORTS is a list of (KEY LABEL) for sort keys, shown as one select labelled SORT-LABEL.
TRASH names a :values filter with TRASH-VALUE among its values, shown as a segmented control
named VIEW-LABEL with the two TRASH-LABELS, the active view and the trash. LABEL names the search landmark.

HX-TARGET is the element the list's htmx requests replace; it defaults to the spec's. ID is
the form's id, and the controls' ids start with it. Include TOOLBAR-JS once on the page.
Signals when a name is not a filter or sort key of the right kind."
  (let* ((spec (list:list-state-spec state))
         (target (or hx-target (list:list-spec-hx-target spec)))
         (search-name (and search (progn (%check-filter spec search :text)
                                         (list:list-param-name spec search))))
         (filter-names (loop for (name) in filters
                             do (%check-filter spec name :values)
                             collect (list:list-param-name spec name)))
         (sort-name (and sorts (list:list-param-name spec "sort")))
         (trash-name (and trash
                          (let ((options (%check-filter spec trash :values)))
                            (unless (member trash-value (getf options :values) :test #'string=)
                              (error "hyperion/kit/toolbar: ~S is not a value of filter ~S"
                                     trash-value trash))
                            (list:list-param-name spec trash))))
         (shown (remove nil (append (list search-name sort-name trash-name) filter-names))))
    (loop for (key) in sorts
          unless (assoc key (list:list-spec-sorts spec))
            do (error "hyperion/kit/toolbar: ~S is not a sort key of list ~S"
                      key (list:list-spec-id spec)))
    (spin:with-html
      (:div :class "hy-toolbar"
        (:form :id id :class "hy-toolbar-form" :role "search" :aria-label label
               :method "get" :data-hy-toolbar "true"
               ;; TOOLBAR-JS replaces this path with the page's own.
               :hx-get (and target "?") :hx-target target
               :hx-swap (and target "outerHTML") :hx-push-url (and target "true")
               :hx-trigger (and target +trigger+)
          (let ((dir (list:list-param-name spec "dir")))
            (dolist (pair (list:list-carried-params state :except shown))
              (:input :type "hidden" :name (car pair) :value (cdr pair)
                      :data-hy-dir (and (string= (car pair) dir) "true"))))
          (when search-name
            (:input :type "search" :id (format nil "~A-search" id) :class "input hy-toolbar-search"
                    :name search-name :aria-label search-label :placeholder search-placeholder
                    :value (or (list:filter-value state search) "")
                    :hx-preserve "true"))
          (loop for (name text value-labels) in filters
                for field in filter-names
                for current = (list:filter-value state name)
                do (:label :class "hy-toolbar-field"
                     (:span :class "hy-toolbar-label" text)
                     (:span :class "select"
                       (:select :name field :id (format nil "~A-~(~A~)" id name)
                         (:option :value "" :selected (null current) all-label)
                         (dolist (value (getf (%check-filter spec name :values) :values))
                           (:option :value value :selected (equal value current)
                                    (or (cdr (assoc value value-labels :test #'string=))
                                        value)))))))
          (when sorts
            (:label :class "hy-toolbar-field"
              (:span :class "hy-toolbar-label" sort-label)
              (:span :class "select"
                ;; LIST-HREF leaves the default key out, so the script drops it too.
                (:select :name sort-name :id (format nil "~A-sort" id) :data-hy-sort "true"
                         :data-hy-default (format nil "~(~A~)" (list:list-spec-default-sort spec))
                  (loop for (key text) in sorts
                        do (:option :value (format nil "~(~A~)" key)
                                    :selected (eq key (list:list-state-sort state))
                                    text))))))
          (:button :type "submit" :class "button hy-toolbar-submit" search-label))
        (when trash-name
          (let ((in-trash (equal trash-value (list:filter-value state trash))))
            (toggle:segmented-control
             view-label
             (list (list "active" (first trash-labels)
                         (list:list-href state :filters (list trash nil)))
                   (list trash-value (second trash-labels)
                         (list:list-href state :filters (list trash trash-value))))
             :selected (if in-trash trash-value "active")
             :hx-target (or target "body"))))))))

(defun toolbar-js ()
  "Compiled JS that makes every LIST-TOOLBAR's htmx requests match LIST-HREF's links, installed
once on the document. Include it once with (:script (:raw (toolbar-js)))."
  (out:js-string
   '(funcall
     (lambda ()
       (unless (@ window hy-kit-toolbar)
         (setf (@ window hy-kit-toolbar) t)
         (chain document
                (add-event-listener
                 "htmx:configRequest"
                 (lambda (e)
                   (let ((form (@ e detail elt))
                         (params (@ e detail parameters)))
                     (when (and form (@ form has-attribute)
                                (chain form (has-attribute "data-hy-toolbar")))
                       ;; The page's own path, with no query string: the form's fields are the
                       ;; whole query.
                       (setf (@ e detail path) (@ location pathname))
                       (let ((trigger (and (@ e detail triggering-event)
                                           (@ e detail triggering-event target))))
                         ;; A new sort key takes its own default direction, as in LIST-HREF.
                         (when (and trigger (@ trigger has-attribute)
                                    (chain trigger (has-attribute "data-hy-sort")))
                           (let ((dir (chain form (query-selector "[data-hy-dir]"))))
                             (when dir (delete (getprop params (@ dir name)))))))
                       ;; An empty field is a filter set to All, and a field at its default is
                       ;; the default sort key; LIST-HREF leaves both out.
                       (let ((names (chain *array (from (chain form (query-selector-all "[name]"))))))
                         (chain names
                                (for-each
                                 (lambda (field)
                                   (when (or (equal (@ field value) "")
                                             (equal (@ field value)
                                                    (chain field (get-attribute "data-hy-default"))))
                                     (delete (getprop params (@ field name))))))))))))))))))
