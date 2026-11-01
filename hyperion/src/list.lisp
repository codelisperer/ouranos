;;;; list.lisp --- paging, sorting and filtering a list from the query string (#488).
;;;;
;;;; An app declares a list once, with MAKE-LIST-SPEC: the sort keys it offers and the column
;;;; each one sorts by, its filters, and the page sizes it allows. READ-LIST-STATE reads a
;;;; request's query string against that spec, LIST-CLAUSES turns the result into the
;;;; :order-by, :limit and :offset of a mnemosyne query, LIST-HREF builds links that change
;;;; one part of it, and PAGER, SORT-HEADING and PAGE-SIZE-CHOICE render the controls.
;;;; hyperion/list-db adds FETCH-PAGE, which runs the page and its total.
;;;;
;;;; THE REQUEST ONLY CHOOSES; IT NEVER NAMES. mnemosyne writes a string identifier into SQL as
;;;; it is given and upcases whatever stands in the ORDER BY direction (#860). So every column
;;;; and direction in LIST-CLAUSES comes from the spec. The request picks one of the declared
;;;; sort keys, compared by name and never interned, and one of two directions, and supplies
;;;; two integers that are checked and bounded. A value that is not one of the choices falls
;;;; back to the default, and LIST-STATE-ADJUSTED records which parameters were replaced.
;;;;
;;;; Filters are the app's to turn into SQL, because what a filter means is domain logic.
;;;; FILTER-VALUE gives the validated value, which the app passes as a value, never as an
;;;; identifier. FILTER-WHERE covers the simple case of a closed set of values on one column.
;;;;
;;;; Every link is a real href, so a list works without JavaScript. When the spec or the call
;;;; names an htmx target, the same links also carry hx-get, hx-target, hx-swap and
;;;; hx-push-url, so htmx replaces the list in place and the address bar follows.

(cl:defpackage #:hyperion/list
  (:use #:cl)
  (:local-nicknames (#:spin #:spinneret)
                    (#:i18n #:hyperion/i18n)
                    (#:http #:hyperion/http)
                    (#:session #:hyperion/session))
  (:documentation
   "Paging, sorting and filtering a list from the query string, against a spec the app
    declares (#488). The request chooses among declared sort keys and page sizes and never
    supplies an identifier.")
  (:export
   ;; the spec
   #:make-list-spec #:list-spec #:list-spec-p #:list-spec-id
   #:list-spec-sorts #:list-spec-default-sort #:list-spec-filters #:list-spec-hx-target
   #:list-param-name
   ;; the state
   #:read-list-state #:list-state #:list-state-p #:list-state-spec #:list-state-page
   #:list-state-page-size #:list-state-sort #:list-state-direction #:list-state-filters
   #:list-state-adjusted #:filter-value #:filter-choices #:clamp-page #:page-count
   ;; the query
   #:list-clauses #:filter-where
   ;; links
   #:list-href #:list-params #:list-carried-params
   ;; remembered state
   #:load-list-state #:save-list-state #:session-list-store #:make-session-list-store
   ;; components
   #:pager #:sort-heading #:page-size-choice))

(in-package #:hyperion/list)

;;; --- the spec ------------------------------------------------------------------------

(defstruct (list-spec (:constructor %make-list-spec))
  (id "" :type string)
  (prefix "" :type string)
  (sorts '() :type list)        ; ((key :column column :direction dir) ...)
  (default-sort nil :type symbol)
  (tiebreak nil :type symbol)
  (filters '() :type list)      ; ((name :values (...)|fn :column c) | (name :text t :max-length n))
  (page-size 25 :type (integer 1))
  (page-sizes '(25) :type list)
  (hx-target nil :type (or null string)))

(defun %spec-error (control &rest args)
  (error "hyperion/list: ~?" control args))

(defun %normalise-sort (entry)
  (destructuring-bind (key &key column (direction :asc)) (if (listp entry) entry (list entry))
    (unless (keywordp key) (%spec-error "a sort key must be a keyword, got ~S" key))
    (unless (and column (symbolp column))
      (%spec-error "sort key ~S needs :column, a keyword naming the column, got ~S" key column))
    (unless (member direction '(:asc :desc))
      (%spec-error "sort key ~S has direction ~S; it must be :asc or :desc" key direction))
    (list key :column column :direction direction)))

(defun %normalise-filter (entry)
  (destructuring-bind (name &key values text (max-length 100) column)
      (if (listp entry) entry (list entry))
    (unless (keywordp name) (%spec-error "a filter name must be a keyword, got ~S" name))
    (unless (or values text)
      (%spec-error "filter ~S needs :values (a list of strings, or a function of the request that returns one) or :text t" name))
    (when (and values text) (%spec-error "filter ~S has both :values and :text" name))
    (when values
      (unless (or (functionp values) (and (listp values) (every #'stringp values)))
        (%spec-error "filter ~S: :values must be a list of strings or a function of the request, got ~S" name values)))
    (when (and column (not (symbolp column)))
      (%spec-error "filter ~S: :column must be a keyword, got ~S" name column))
    (when (and column text)
      (%spec-error "filter ~S: :column applies to a :values filter; build a text filter's WHERE in the app" name))
    (unless (typep max-length '(integer 1))
      (%spec-error "filter ~S: :max-length must be a positive integer, got ~S" name max-length))
    (list name :values values :text (and text t) :max-length max-length :column column)))

(defun make-list-spec (&key id (prefix "") sorts default-sort tiebreak filters (page-size 25)
                         page-sizes hx-target)
  "A list's declaration. Called once, by the app, with values from its own code.

ID names the list, for remembered state. PREFIX is put before every parameter name, so two
lists on one page can use \"contacts.\" and \"tasks.\" and not share their page.

SORTS is a list of (KEY :column COLUMN [:direction :asc|:desc]). KEY is the keyword the
request names, by its lowercase name (?sort=name for :name). COLUMN is the keyword mnemosyne
writes into ORDER BY. DIRECTION is the key's default. DEFAULT-SORT is the key used when the
request names none; it defaults to the first. TIEBREAK, a unique column such as :id, is
required when there are sort keys. It is added to every ORDER BY after the chosen column, so
rows with equal sort values keep one order and no row repeats or is skipped between pages.

FILTERS is a list of (NAME :values (STRING ...) [:column COLUMN]), a closed set, or (NAME :text
t [:max-length N]), free text cut to N characters (100 by default). The request names a filter
by NAME's lowercase name. :VALUES may instead be a function of the request (the Clack env) that
returns the list of strings, for a set that changes, such as the projects a user can see.
READ-LIST-STATE calls it once per request, and that one result is what the request's value is
checked against, what FILTER-CHOICES returns and what LIST-HREF accepts.

PAGE-SIZE is the default page size, and PAGE-SIZES the sizes the request may choose from; it
defaults to PAGE-SIZE alone, and its largest member is the most rows a page can have.
HX-TARGET is a CSS selector: when given, the components' links also carry the htmx
attributes that replace that element.

Signals an error for a malformed spec, because a spec is code."
  (unless (stringp id) (%spec-error ":id must be a string, got ~S" id))
  (unless (stringp prefix) (%spec-error ":prefix must be a string, got ~S" prefix))
  (let* ((sorts (mapcar #'%normalise-sort sorts))
         (filters (mapcar #'%normalise-filter filters))
         (page-sizes (or page-sizes (list page-size)))
         (default-sort (or default-sort (first (first sorts)))))
    (unless (and (listp page-sizes) (every (lambda (n) (typep n '(integer 1))) page-sizes))
      (%spec-error ":page-sizes must be positive integers, got ~S" page-sizes))
    (unless (member page-size page-sizes)
      (%spec-error ":page-size ~S is not one of :page-sizes ~S" page-size page-sizes))
    (when (and default-sort (not (assoc default-sort sorts)))
      (%spec-error ":default-sort ~S is not one of the sort keys" default-sort))
    (when (and sorts (not tiebreak))
      (%spec-error ":tiebreak is required when the list has sort keys: name a unique column, such as the primary key, so rows with equal sort values keep one order and none repeats or is skipped between pages"))
    (when (and tiebreak (not (keywordp tiebreak)))
      (%spec-error ":tiebreak must be a keyword naming a column, got ~S" tiebreak))
    (dolist (f filters)
      (when (member (%lower (first f)) '("page" "size" "sort" "dir") :test #'string=)
        (%spec-error "filter ~S uses a name the list itself reads" (first f))))
    (%make-list-spec :id id :prefix prefix :sorts sorts :default-sort default-sort
                     :tiebreak tiebreak :filters filters :page-size page-size
                     :page-sizes (sort (copy-list page-sizes) #'<) :hx-target hx-target)))

(defun %lower (keyword) (string-downcase (symbol-name keyword)))

(defun %param (spec name)
  "The query-parameter name for NAME (a string) in SPEC."
  (concatenate 'string (list-spec-prefix spec) name))

(defun list-param-name (spec name)
  "The query-parameter name the list SPEC reads for NAME: a filter's keyword, or one of the
strings \"page\", \"size\", \"sort\" and \"dir\". It is NAME's lowercase name with the spec's
prefix, so a form field named by it is read as that filter or setting."
  (%param spec (if (stringp name) name (%lower name))))

(defun %sort-entry (spec key) (assoc key (list-spec-sorts spec)))

(defun %sort-default-direction (spec key)
  (or (getf (rest (%sort-entry spec key)) :direction) :asc))

(defun %own-param-names (spec)
  "Every query-parameter name the list reads."
  (append (mapcar (lambda (n) (%param spec n)) '("page" "size" "sort" "dir"))
          (mapcar (lambda (f) (%param spec (%lower (first f)))) (list-spec-filters spec))))

;;; --- the state -----------------------------------------------------------------------

(defstruct (list-state (:constructor %make-list-state))
  spec
  (page 1 :type (integer 1))
  (page-size 25 :type (integer 1))
  (sort nil :type symbol)
  (direction :asc :type (member :asc :desc))
  (filters '() :type list)      ; ((name . validated-string) ...)
  (choices '() :type list)      ; ((name . (string ...)) ...) for every :values filter
  (adjusted '() :type list)     ; parameter names whose value was replaced by a default
  (query-string nil :type (or null string))
  (remembering nil :type boolean))  ; read with a store: links always name the page

(defconstant +max-page-digits+ 9
  "The most digits a page number may have. Larger numbers fall back to page 1 rather than
becoming an offset no database should be asked for.")

(defun %parse-count (text)
  "TEXT as a positive integer when it is 1 to 9 ASCII digits and not zero; otherwise NIL."
  (and (stringp text)
       (<= 1 (length text) +max-page-digits+)
       (every (lambda (c) (char<= #\0 c #\9)) text)
       (let ((n (parse-integer text)))
         (and (plusp n) n))))

(defun %control-char-p (c)
  "True for a C0 control character or DEL. A text filter drops them: Postgres refuses a NUL in
a text value with an error, and none of them belongs in a search term."
  (let ((code (char-code c))) (or (< code 32) (= code 127))))

(defun %resolve-choices (spec env)
  "Each :values filter of SPEC with its choices for the request ENV, as ((NAME . (STRING ...))
...): the list itself, or what the filter's function returns for ENV. Signals when a function
returns anything but a list of strings, because the function is the app's code."
  (loop for (name . options) in (list-spec-filters spec)
        for values = (getf options :values)
        when values
          collect (cons name
                        (if (functionp values)
                            (let ((got (funcall values env)))
                              (unless (and (listp got) (every #'stringp got))
                                (%spec-error "filter ~S: the :values function returned ~S, not a list of strings" name got))
                              got)
                            values))))

(defun %parse-params (spec lookup choices)
  "The validated state for SPEC from LOOKUP, a function from a parameter name to its first
value or NIL, with CHOICES from %RESOLVE-CHOICES. Returns the page, page size, sort, direction,
filters and the names of parameters that were present and replaced."
  (let ((adjusted '()))
    (flet ((raw (name) (funcall lookup (%param spec name)))
           (adjust (name) (push (%param spec name) adjusted)))
      (let* ((page-text (raw "page"))
             (page (or (%parse-count page-text) (progn (when page-text (adjust "page")) 1)))
             (size-text (raw "size"))
             (size (let ((n (%parse-count size-text)))
                     (if (and n (member n (list-spec-page-sizes spec)))
                         n
                         (progn (when size-text (adjust "size")) (list-spec-page-size spec)))))
             (sort-text (raw "sort"))
             (sort (or (and sort-text
                            (first (find sort-text (list-spec-sorts spec)
                                         :key (lambda (e) (%lower (first e)))
                                         :test #'string=)))
                       (progn (when sort-text (adjust "sort")) (list-spec-default-sort spec))))
             (dir-text (raw "dir"))
             (direction (cond ((equal dir-text "asc") :asc)
                              ((equal dir-text "desc") :desc)
                              (t (when dir-text (adjust "dir"))
                                 (if sort (%sort-default-direction spec sort) :asc))))
             (filters
               (loop for (name . options) in (list-spec-filters spec)
                     for text = (raw (%lower name))
                     for value = (cond ((null text) nil)
                                       ((getf options :values)
                                        (or (find text (cdr (assoc name choices)) :test #'string=)
                                            (progn (adjust (%lower name)) nil)))
                                       (t (let* ((clean (remove-if #'%control-char-p text))
                                                 (cut (subseq clean 0 (min (length clean)
                                                                           (getf options :max-length)))))
                                            (when (< (length cut) (length text))
                                              (adjust (%lower name)))
                                            (and (plusp (length cut)) cut))))
                     when value collect (cons name value))))
        (values page size sort direction filters (nreverse adjusted))))))

(defun %first-value-function (query-string)
  (let ((alist (http:form-alist query-string)))
    (lambda (name) (cdr (assoc name alist :test #'string=)))))

(defun read-list-state (spec env &key store)
  "The list's state for the request ENV, read from its query string against SPEC.

Every value is checked against the spec, and one that does not fit is replaced by the
default: an unknown sort key, a direction other than asc or desc, a page that is not 1 to 9
digits, a page size not in :page-sizes, a filter value outside its set. A filter whose
:values is a function is called once with ENV, and its value is checked against that result. A text filter loses
its control characters and is cut to its :max-length. LIST-STATE-ADJUSTED lists the parameters
that were replaced, cleaned or cut.

STORE, when given, is a remembered-state store (LOAD-LIST-STATE, SAVE-LIST-STATE). When the
request carries none of the list's parameters, the stored ones are read instead, checked
the same way, so a stored value that no longer fits the spec is dropped. Otherwise the
request's checked parameters are saved. A link that names the list's parameters therefore
always shows what it says."
  (let* ((query-string (getf env :query-string))
         (alist (http:form-alist query-string))
         (own (%own-param-names spec))
         (request-has-own (some (lambda (pair) (member (car pair) own :test #'string=)) alist))
         (stored (and store (not request-has-own)
                      (load-list-state store env (list-spec-id spec))))
         (source (if (stringp stored) stored query-string))
         (choices (%resolve-choices spec env)))
    (multiple-value-bind (page size sort direction filters adjusted)
        (%parse-params spec (%first-value-function source) choices)
      (let ((state (%make-list-state :spec spec :page page :page-size size :sort sort
                                     :direction direction :filters filters :choices choices
                                     :adjusted adjusted
                                     :query-string query-string
                                     :remembering (and store t))))
        (when (and store request-has-own)
          (save-list-state store env (list-spec-id spec)
                           (http:form-urlencode (list-params state))))
        state))))

(defun filter-value (state name)
  "The validated value of filter NAME in STATE, a string, or NIL when the request gave none
or gave one that did not fit."
  (cdr (assoc name (list-state-filters state))))

(defun filter-choices (state name)
  "The values the :values filter NAME accepts for STATE's request, a list of strings: the
spec's list, or what its function returned when READ-LIST-STATE read the request. Signals
when NAME is not a :values filter of the list."
  (let ((entry (assoc name (list-state-choices state))))
    (unless entry
      (%spec-error "~S is not a :values filter of list ~S" name (list-spec-id (list-state-spec state))))
    (cdr entry)))

(defun page-count (state total)
  "How many pages TOTAL rows make at STATE's page size; at least 1."
  (max 1 (ceiling total (list-state-page-size state))))

(defun clamp-page (state total)
  "STATE with its page brought within 1 .. (PAGE-COUNT STATE TOTAL), so a page past the end
shows the last page. Returns STATE itself when the page already fits."
  (let ((last (page-count state total)))
    (if (<= (list-state-page state) last)
        state
        (let ((copy (copy-list-state state)))
          (setf (list-state-page copy) last)
          copy))))

;;; --- the query -----------------------------------------------------------------------

(defun list-clauses (state)
  "The :order-by, :limit and :offset for STATE, as a plist to append to a mnemosyne :select.
Every column comes from the spec; the request contributed only which declared key, which of
two directions, and two bounded integers. The tiebreak column, when declared and different
from the sort column, follows the sort column in ascending order."
  (let* ((spec (list-state-spec state))
         (column (and (list-state-sort state)
                      (getf (rest (%sort-entry spec (list-state-sort state))) :column)))
         (tiebreak (list-spec-tiebreak spec))
         (order (append (when column (list (list column (list-state-direction state))))
                        (when (and tiebreak (not (eq tiebreak column)))
                          (list (list tiebreak :asc))))))
    (append (when order (list :order-by order))
            (list :limit (list-state-page-size state)
                  :offset (* (1- (list-state-page state)) (list-state-page-size state))))))

(defun filter-where (state)
  "A mnemosyne :where expression for the :values filters that declare a :column and have a
value in STATE, as (:= column value) joined by :and; NIL when there are none. The value is a
string, which mnemosyne binds as a parameter."
  (let ((clauses
          (loop for (name . options) in (list-spec-filters (list-state-spec state))
                for column = (getf options :column)
                for value = (filter-value state name)
                when (and column value) collect (list := column value))))
    (cond ((null clauses) nil)
          ((null (rest clauses)) (first clauses))
          (t (cons :and clauses)))))

;;; --- links ---------------------------------------------------------------------------

(defun list-params (state)
  "STATE's parameters as (name . value) strings, leaving out each one that equals its
default, so the first page of the default view has none. The exception is a state read with
a remembered-state store: then the page is always named, because a request that names none
of the list's parameters restores the stored ones, and the default view must stay reachable."
  (let* ((spec (list-state-spec state))
         (sort (list-state-sort state))
         (default-sort (list-spec-default-sort spec)))
    (append
     (when (or (/= 1 (list-state-page state)) (list-state-remembering state))
       (list (cons (%param spec "page") (princ-to-string (list-state-page state)))))
     (when (/= (list-spec-page-size spec) (list-state-page-size state))
       (list (cons (%param spec "size") (princ-to-string (list-state-page-size state)))))
     (when (and sort (not (eq sort default-sort)))
       (list (cons (%param spec "sort") (%lower sort))))
     (when (and sort (not (eq (list-state-direction state) (%sort-default-direction spec sort))))
       (list (cons (%param spec "dir") (%lower (list-state-direction state)))))
     (loop for (name . value) in (list-state-filters state)
           collect (cons (%param spec (%lower name)) value)))))

(defun list-carried-params (state &key except)
  "The (name . value) pairs a GET form for this list carries as hidden fields, so that
submitting it changes only its own fields, as LIST-HREF does: first the request's parameters
that the list does not own, then STATE's own parameters except the page and the names in
EXCEPT, parameter names as LIST-PARAM-NAME gives them. The page is left out, so the form's
request starts on page 1."
  (let* ((spec (list-state-spec state))
         (own (%own-param-names spec))
         (page (%param spec "page")))
    (append
     (remove-if (lambda (pair) (member (car pair) own :test #'string=))
                (http:form-alist (list-state-query-string state)))
     (remove-if (lambda (pair) (or (string= (car pair) page)
                                   (member (car pair) except :test #'string=)))
                (list-params state)))))

(defun list-href (state &rest changes &key (page nil page-p) (size nil size-p)
                                           (sort nil sort-p) (dir nil dir-p) filters)
  "A relative link, \"?\" and the query string, to the current page with STATE changed by
CHANGES, keeping every query parameter the list does not own.

THE LINK CARRIES NO PATH. The browser resolves it against the page the user is on, so it is
right under any mount and needs no path from the request. The env's :PATH-INFO is not usable
here: a mounted router rewrites it to the sub-path, and it is already decoded, so a request
for /a%3Fb or //evil.com would be echoed back as a different link or one to another site.

  (list-href state :page 3)                  page 3, everything else as it is
  (list-href state :sort :name)              sort by :name; the same key again reverses it
  (list-href state :size 50)
  (list-href state :filters '(:status \"open\"))   set a filter; NIL as the value removes it

The result is \"?\" alone for the first page of the default view with no other parameters.

Changing the sort, the size or a filter goes back to page 1 unless :PAGE is also given.
Choosing a different sort key uses that key's default direction unless :DIR is given. A
value that is not one of the spec's choices signals an error, because it comes from the
app's code, not from the request."
  (declare (ignore changes))
  (let* ((spec (list-state-spec state))
         (new (copy-list-state state)))
    (when sort-p
      (unless (%sort-entry spec sort) (%spec-error "~S is not a sort key of list ~S" sort (list-spec-id spec)))
      (setf (list-state-direction new)
            (cond (dir-p dir)
                  ((eq sort (list-state-sort state))
                   (if (eq (list-state-direction state) :asc) :desc :asc))
                  (t (%sort-default-direction spec sort)))
            (list-state-sort new) sort))
    (when (and dir-p (not sort-p))
      (setf (list-state-direction new) dir))
    (unless (member (list-state-direction new) '(:asc :desc))
      (%spec-error "~S is not a direction; use :asc or :desc" (list-state-direction new)))
    (when size-p
      (unless (member size (list-spec-page-sizes spec))
        (%spec-error "~S is not one of the page sizes ~S" size (list-spec-page-sizes spec)))
      (setf (list-state-page-size new) size))
    (when filters
      (loop for (name value) on filters by #'cddr
            for options = (rest (assoc name (list-spec-filters spec)))
            do (unless options (%spec-error "~S is not a filter of list ~S" name (list-spec-id spec)))
               (when value
                 (unless (and (stringp value)
                              (if (getf options :values)
                                  (member value (filter-choices state name) :test #'string=)
                                  (and (<= (length value) (getf options :max-length))
                                       (not (find-if #'%control-char-p value)))))
                   (%spec-error "~S is not a value filter ~S accepts" value name)))
               (setf (list-state-filters new)
                     (append (remove name (list-state-filters new) :key #'car)
                             (when value (list (cons name value)))))))
    (setf (list-state-page new)
          (cond (page-p (or (and (typep page '(integer 1)) page)
                            (%spec-error "~S is not a page number" page)))
                ((or sort-p size-p dir-p filters) 1)
                (t (list-state-page state))))
    (let ((own (%own-param-names spec)))
      (concatenate 'string "?"
                   (http:query-string-with
                    (list-state-query-string state)
                    (append (mapcar (lambda (n) (cons n nil)) own)
                            (list-params new)))))))

;;; --- remembered state ----------------------------------------------------------------

(defgeneric load-list-state (store env list-id)
  (:documentation "The list parameters STORE remembers for LIST-ID in this request's context,
as a query string, or NIL. READ-LIST-STATE checks them against the spec before using them."))

(defgeneric save-list-state (store env list-id query-string)
  (:documentation "Remember QUERY-STRING, the list's checked parameters, for LIST-ID in this
request's context. An empty string means the list is at its defaults."))

(defclass session-list-store () ()
  (:documentation "Remembers each list's parameters in the request's session, under the key
\"hyperion/list:ID\". Per session, not per account, because the session is the only per-user
storage hyperion has; an app that wants it per account implements the two generics over its
own table. Needs the app wrapped in WRAP-SESSION; without a session it remembers nothing."))

(defun make-session-list-store () (make-instance 'session-list-store))

(defun %session-key (list-id) (concatenate 'string "hyperion/list:" list-id))

(defmethod load-list-state ((store session-list-store) env list-id)
  (let ((s (session:request-session env)))
    (and s (session:session-get s (%session-key list-id)))))

(defmethod save-list-state ((store session-list-store) env list-id query-string)
  (let ((s (session:request-session env)))
    (when (and s (not (equal query-string (session:session-get s (%session-key list-id)))))
      (session:session-set s (%session-key list-id) query-string))))

;;; --- translation ---------------------------------------------------------------------

(defparameter +english+
  '(:list/showing "Showing {from}–{to} of {total}"
    :list/empty "Nothing to show"
    :list/previous "Previous"
    :list/next "Next"
    :list/pages "Pages"
    :list/page "Page {page}"
    :list/page-size "Per page")
  "The English text for every key this package looks up; used when there is no source, or
when the source has the key in neither the requested nor its default locale.")

(defun %text (locale key source &rest args)
  (if (and source (i18n:translation-exists-p source locale key))
      (apply #'i18n:translate source locale key args)
      (i18n:interpolate (getf +english+ key) args)))

;;; --- components ----------------------------------------------------------------------

(defun %target (state hx-target)
  (or hx-target (list-spec-hx-target (list-state-spec state))))

(defmacro %link ((href target &rest attributes) &body body)
  "An <a> with HREF, plus hx-get, hx-target, hx-swap and hx-push-url when TARGET is given."
  (let ((h (gensym "HREF")) (tg (gensym "TARGET")))
    `(let ((,h ,href) (,tg ,target))
       (spin:with-html
         (:a :href ,h :hx-get (and ,tg ,h) :hx-target ,tg
             :hx-swap (and ,tg "outerHTML") :hx-push-url (and ,tg "true")
             ,@attributes
             ,@body)))))

(defun %page-window (page last window)
  "The page numbers to show around PAGE, with 1 and LAST, and NIL where pages are left out."
  (let ((shown (remove-duplicates
                (sort (remove-if-not (lambda (n) (<= 1 n last))
                                     (append (list 1 last)
                                             (loop for n from (- page window) to (+ page window)
                                                   collect n)))
                      #'<))))
    (loop for (n next) on shown
          collect n
          when (and next (> next (1+ n))) collect nil)))

(defun pager (state total &key (locale "en") (source i18n:*translation-source*) (window 2)
                              hx-target)
  "Write a pager for STATE when the list has TOTAL rows into SPINNERET:*HTML*: a line saying
which rows are shown, previous and next, and the page numbers within WINDOW of the current
one plus the first and last, with gaps marked. The current page has aria-current=\"page\".
Previous on the first page and next on the last are text, not links. With TOTAL zero it
writes only :list/empty. Text comes from LOCALE and SOURCE under the :list section, with
English when a key is missing."
  (let* ((state (clamp-page state total))
         (page (list-state-page state))
         (size (list-state-page-size state))
         (last (page-count state total))
         (target (%target state hx-target)))
    (spin:with-html
      (:nav :class "hyperion-pager" :aria-label (%text locale :list/pages source)
        (if (zerop total)
            (:p :class "hyperion-pager-showing" (%text locale :list/empty source))
            (progn
              (:p :class "hyperion-pager-showing"
                  (%text locale :list/showing source
                         :from (1+ (* (1- page) size))
                         :to (min total (* page size))
                         :total total))
              (:ul
                (:li (if (> page 1)
                         (%link ((list-href state :page (1- page)) target :rel "prev")
                           (%text locale :list/previous source))
                         (:span :aria-disabled "true" (%text locale :list/previous source))))
                (dolist (n (%page-window page last window))
                  (cond ((null n) (:li :class "hyperion-pager-gap" "…"))
                        ((= n page) (:li (:span :aria-current "page" n)))
                        (t (:li (%link ((list-href state :page n) target
                                        :aria-label (%text locale :list/page source :page n))
                                  n)))))
                (:li (if (< page last)
                         (%link ((list-href state :page (1+ page)) target :rel "next")
                           (%text locale :list/next source))
                         (:span :aria-disabled "true" (%text locale :list/next source)))))))))))

(defun sort-heading (state key label &key hx-target)
  "Write a <th> for sort KEY with LABEL into SPINNERET:*HTML*. Its link sorts by KEY, or
reverses the direction when KEY is already the sort. The heading of the current sort carries
aria-sort, ascending or descending."
  (let ((active (eq key (list-state-sort state)))
        (target (%target state hx-target)))
    (spin:with-html
      (:th :aria-sort (and active (if (eq (list-state-direction state) :asc)
                                      "ascending" "descending"))
        (%link ((list-href state :sort key) target)
          label
          (when active
            (:span :class "hyperion-sort-indicator" :aria-hidden "true"
                   (if (eq (list-state-direction state) :asc) "▲" "▼"))))))))

(defun page-size-choice (state &key (locale "en") (source i18n:*translation-source*) hx-target)
  "Write the page sizes the spec allows into SPINNERET:*HTML*, the current one as text with
aria-current, the others as links that return to page 1."
  (let ((target (%target state hx-target)))
    (spin:with-html
      (:p :class "hyperion-page-size"
        (%text locale :list/page-size source)
        (dolist (n (list-spec-page-sizes (list-state-spec state)))
          (if (= n (list-state-page-size state))
              (:span :aria-current "true" n)
              (%link ((list-href state :size n) target) n)))))))
