;;;; list-tests.lisp --- hyperion/list: the request only chooses, links keep the rest (#488).
;;;;
;;;; The first group sends a request every value an attacker or a stale link might, one case
;;;; each, and checks two things: the state holds a declared choice or the default, and the SQL
;;;; that mnemosyne renders from LIST-CLAUSES contains only identifiers the spec declared. The
;;;; second assertion is about where the identifiers came from, not only that a query was made.

(cl:defpackage #:hyperion/list/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:list #:hyperion/list)
                    (#:http #:hyperion/http)
                    (#:i18n #:hyperion/i18n)
                    (#:sess #:hyperion/session)
                    (#:query #:mnemosyne/query)
                    (#:spin #:spinneret))
  (:export #:run-tests))

(in-package #:hyperion/list/tests)

(def-suite hyperion-list :description "hyperion/list.")
(in-suite hyperion-list)

(defun run-tests () (run! 'hyperion-list))

(defparameter *spec*
  (list:make-list-spec
   :id "contacts"
   :sorts '((:name :column :name) (:added :column :created_at :direction :desc))
   :default-sort :added
   :tiebreak :id
   :filters '((:status :values ("open" "closed") :column :status) (:q :text t :max-length 5))
   :page-size 25 :page-sizes '(25 50 100)))

(defun %env (query &optional (path "/contacts"))
  (list :path-info path :query-string query))

(defun %state (query &rest options)
  (apply #'list:read-list-state *spec* (%env query) options))

(defun %sql (state)
  "The SQL mnemosyne renders for a select of contacts with STATE's clauses."
  (values (query:sql (append '(:select (:id) :from (:contacts))
                             (list:list-clauses state))
                     :dialect :postgres)))

(defparameter *default-sql*
  "SELECT id FROM contacts ORDER BY created_at DESC, id ASC LIMIT ? OFFSET ?")

;;; --- the request only chooses --------------------------------------------------------

(test no-parameters-give-the-defaults
  (let ((s (%state nil)))
    (is (= 1 (list:list-state-page s)))
    (is (= 25 (list:list-state-page-size s)))
    (is (eq :added (list:list-state-sort s)))
    (is (eq :desc (list:list-state-direction s)))
    (is (null (list:list-state-filters s)))
    (is (null (list:list-state-adjusted s)))
    (is (equal '(:order-by ((:created_at :desc) (:id :asc)) :limit 25 :offset 0)
               (list:list-clauses s)))))

(test declared-choices-are-taken
  (let ((s (%state "sort=name&dir=desc&page=3&size=50&status=open&q=smi")))
    (is (eq :name (list:list-state-sort s)))
    (is (eq :desc (list:list-state-direction s)))
    (is (= 3 (list:list-state-page s)))
    (is (= 50 (list:list-state-page-size s)))
    (is (equal "open" (list:filter-value s :status)))
    (is (equal "smi" (list:filter-value s :q)))
    (is (null (list:list-state-adjusted s)))
    (is (equal '(:order-by ((:name :desc) (:id :asc)) :limit 50 :offset 100)
               (list:list-clauses s)))))

(defparameter *attacks*
  '(("sort=created_at" "sort" "a column name instead of a declared key")
    ("sort=id" "sort" "the tiebreak column")
    ("sort=name%3B%20DROP%20TABLE%20contacts" "sort" "SQL after a declared key")
    ("sort=NAME" "sort" "a declared key in another case")
    ("dir=desc%3B%20DROP%20TABLE%20contacts" "dir" "SQL in the direction")
    ("dir=asc%2C%20(SELECT%20password%20FROM%20users)" "dir" "a subquery in the direction")
    ("dir=DESC" "dir" "a direction in capitals")
    ("page=abc" "page" "a page that is not a number")
    ("page=-1" "page" "a negative page")
    ("page=0" "page" "page zero")
    ("page=1e3" "page" "a page in exponent form")
    ("page=123456789012345678901234567890" "page" "a 30-digit page")
    ("size=1000000" "size" "a page size far over the largest allowed")
    ("size=26" "size" "a page size not in the list")
    ("size=0" "size" "page size zero")
    ("status=pending" "status" "a filter value outside its set")
    ("status=open%27%20OR%20%271%27%3D%271" "status" "SQL in a closed-set filter"))
  "Each attack: the query string, the parameter that must come back as replaced, and what it
tries.")

(test each-attack-falls-back-and-the-sql-holds-only-declared-identifiers
  (dolist (attack *attacks*)
    (destructuring-bind (query param what) attack
      (let ((s (%state query)))
        (is (equal (list param) (list:list-state-adjusted s))
            "~A (~A): adjusted ~S" what query (list:list-state-adjusted s))
        (is (string= *default-sql* (%sql s))
            "~A (~A): ~A" what query (%sql s))
        (is (null (list:list-state-filters s)) "~A: a filter got through" what)))))

(test a-sort-key-from-the-request-is-never-interned
  (let ((name (format nil "NOT-A-KEY-~36R" (random (expt 36 8) (make-random-state t)))))
    (%state (concatenate 'string "sort=" (string-downcase name)))
    (is (null (find-symbol name :keyword)))))

(test page-numbers-at-the-edges
  (is (= 1 (list:list-state-page (%state "page=%D9%A3"))) "an Arabic-Indic digit is not a digit here")
  (is (= 1 (list:list-state-page (%state "page=+1"))) "+1 decodes to \" 1\", which is not digits")
  (is (= 1 (list:list-state-page (%state "page=%2B1"))) "a literal plus sign")
  (is (= 999999999 (list:list-state-page (%state "page=999999999"))) "9 digits")
  (is (= 1 (list:list-state-page (%state "page=1000000000"))) "10 digits")
  (is (equal '("page") (list:list-state-adjusted (%state "page=1000000000")))))

(test control-characters-are-removed-from-a-text-filter
  "Postgres refuses a NUL in a text value with an error; no control character belongs in a
search term."
  (let ((s (%state "q=a%00b%0Ac")))
    (is (equal "abc" (list:filter-value s :q)))
    (is (equal '("q") (list:list-state-adjusted s))))
  (is (null (list:filter-value (%state "q=%00%01") :q)) "nothing left means no filter"))

(test markup-in-a-filter-is-encoded-in-links-and-escaped-in-html
  (let* ((s (%state "q=%3Cs%3E%22"))
         (html (%html (lambda () (list:pager s 60 :hx-target "#c")))))
    (is (equal "<s>\"" (list:filter-value s :q)))
    (is (search "q=%3Cs%3E%22" (list:list-href s :page 2)))
    (is (not (search "<s>" html)) "~A" html)
    (is (search "hx-get=\"?page=2&amp;q=%3Cs%3E%22\"" html) "~A" html)))

(test unknown-parameters-are-ignored-and-a-text-filter-is-cut
  (let ((s (%state "role=admin&q=abcdefgh")))
    (is (equal "abcde" (list:filter-value s :q)))
    (is (equal '("q") (list:list-state-adjusted s)))
    (is (null (assoc :role (list:list-state-filters s))))))

(test filter-where-binds-the-value
  (let ((s (%state "status=closed")))
    (is (equal '(:= :status "closed") (list:filter-where s)))
    (multiple-value-bind (sql params)
        (query:sql (list :select '(:id) :from '(:contacts) :where (list:filter-where s))
                   :dialect :postgres)
      (is (string= "SELECT id FROM contacts WHERE status = ?" sql))
      (is (equal '("closed") params))))
  (is (null (list:filter-where (%state "q=abc"))) "a text filter has no column"))

(test a-malformed-spec-is-refused
  (signals error (list:make-list-spec :id "x" :sorts '((:name))))
  (signals error (list:make-list-spec :id "x" :sorts '((:name :column :n :direction :up))))
  (signals error (list:make-list-spec :id "x" :sorts '((:name :column "n; drop"))))
  (signals error (list:make-list-spec :id "x" :page-size 30 :page-sizes '(25 50)))
  (signals error (list:make-list-spec :id "x" :sorts '((:a :column :a)) :default-sort :b))
  (signals error (list:make-list-spec :id "x" :filters '((:page :values ("1")))))
  (signals error (list:make-list-spec :id "x" :filters '((:q :text t :column :q))))
  (signals error (list:make-list-spec :id "x" :sorts '((:name :column :name)))
    "a list with sort keys needs a tiebreak"))

;;; --- pages ---------------------------------------------------------------------------

(test clamping-brings-a-page-past-the-end-back
  (let ((s (%state "page=40")))
    (is (= 4 (list:list-state-page (list:clamp-page s 76))))
    (is (= 1 (list:list-state-page (list:clamp-page s 0))))
    (let ((fits (%state "page=2")))
      (is (eq fits (list:clamp-page fits 76)) "a page that fits is left as it is"))
    (is (= 4 (list:page-count s 76)))
    (is (= 1 (list:page-count s 0)))))

;;; --- links ---------------------------------------------------------------------------

(test the-default-view-links-to-an-empty-query
  (is (string= "?" (list:list-href (%state "page=2") :page 1))))

(test links-carry-no-path
  "A relative link is right under any mount, and nothing from the request's path reaches it:
a mounted router's sub-path, a decoded %3F, or a leading // that would name another host."
  (dolist (path '("/contacts" "/a?b" "//evil.com" "/"))
    (let ((s (list:read-list-state *spec* (%env "page=2" path))))
      (is (string= "?page=3" (list:list-href s :page 3)) "path ~S: ~A" path
          (list:list-href s :page 3))))
  (let ((html (%html (lambda ()
                       (list:pager (list:read-list-state *spec* (%env "page=2" "//evil.com"))
                                   60 :hx-target "#c")))))
    (is (not (search "evil" html)) "~A" html)))

(test a-mounted-router-gives-links-for-the-mounted-page
  "Under (mount \"/admin\" ...), the router rewrites :path-info to the sub-path. The link is
relative, so the browser keeps /admin."
  (let* ((seen nil)
         (app (hyperion/router:router
               (hyperion/router:mount
                "/admin"
                (hyperion/router:router
                 (hyperion/router:route
                  :get "/contacts"
                  (lambda (env)
                    (setf seen (list (getf env :path-info)
                                     (list:list-href (list:read-list-state *spec* env) :page 2)))
                    '(200 () ("ok")))))))))
    (hyperion/router:dispatch app (list :request-method :get :path-info "/admin/contacts"
                                        :query-string "tab=x"))
    (is (equal "/contacts" (first seen)) "the router rewrote :path-info: ~S" seen)
    (is (string= "?tab=x&page=2" (second seen)) "~S" seen)))

(test links-keep-parameters-the-list-does-not-own
  (let ((s (%state "tab=archived&page=2&sort=name")))
    (is (string= "?tab=archived&page=3&sort=name" (list:list-href s :page 3))
        "~A" (list:list-href s :page 3))))

(test the-same-sort-key-reverses-and-a-new-one-takes-its-default
  (let ((s (%state "sort=name&page=3")))
    (is (string= "?sort=name&dir=desc" (list:list-href s :sort :name)))
    (is (string= "?" (list:list-href s :sort :added)) "the default sort, newest first")
    (is (string= "?dir=asc" (list:list-href s :sort :added :dir :asc)))))

(test a-size-or-filter-change-goes-back-to-page-one
  (let ((s (%state "page=3&status=open")))
    (is (string= "?size=50&status=open" (list:list-href s :size 50)))
    (is (string= "?status=closed" (list:list-href s :filters '(:status "closed"))))
    (is (string= "?" (list:list-href s :filters '(:status nil))))))

(test a-link-reads-back-as-the-state-it-describes
  (let* ((s (%state "sort=name&size=50&status=closed&q=ab"))
         (href (list:list-href s :page 2))
         (back (list:read-list-state *spec* (%env (subseq href (1+ (position #\? href)))))))
    (is (= 2 (list:list-state-page back)))
    (is (= 50 (list:list-state-page-size back)))
    (is (eq :name (list:list-state-sort back)))
    (is (eq :asc (list:list-state-direction back)))
    (is (equal (list:list-state-filters s) (list:list-state-filters back)))))

(test a-link-value-from-code-that-is-not-a-choice-is-an-error
  (let ((s (%state nil)))
    (signals error (list:list-href s :sort :created-at))
    (signals error (list:list-href s :size 30))
    (signals error (list:list-href s :dir :sideways))
    (signals error (list:list-href s :filters '(:role "admin")))
    (signals error (list:list-href s :filters '(:status "pending")) "outside the closed set")
    (signals error (list:list-href s :filters '(:q "abcdefgh")) "longer than :max-length")
    (signals error (list:list-href s :filters (list :q (format nil "a~Cb" (code-char 0)))))
    (signals error (list:list-href s :page 0))))

(test a-prefix-keeps-two-lists-apart
  (let* ((tasks (list:make-list-spec :id "tasks" :prefix "tasks."
                                     :sorts '((:due :column :due)) :tiebreak :id
                                     :page-sizes '(10) :page-size 10))
         (env (%env "page=2&tasks.page=5"))
         (contacts-state (list:read-list-state *spec* env))
         (tasks-state (list:read-list-state tasks env)))
    (is (= 2 (list:list-state-page contacts-state)))
    (is (= 5 (list:list-state-page tasks-state)))
    (is (string= "?page=2&tasks.page=6" (list:list-href tasks-state :page 6)))))

(test query-string-with-replaces-and-removes
  (is (string= "a=1&c=3&b=9" (http:query-string-with "a=1&b=2&c=3&b=4" '(("b" . "9")))))
  (is (string= "a=1" (http:query-string-with "a=1&b=2" '(("b")))))
  (is (string= "" (http:query-string-with nil '(("b")))))
  (is (string= "q=a+b%26c" (http:query-string-with nil '(("q" . "a b&c"))))))

(test htmx-request-p-reads-the-header
  (let ((h (make-hash-table :test 'equal)))
    (is (not (http:htmx-request-p (list :headers h))))
    (setf (gethash "hx-request" h) "true")
    (is (http:htmx-request-p (list :headers h)))))

;;; --- remembered state ----------------------------------------------------------------

(defclass memory-store () ((table :initform (make-hash-table :test 'equal) :reader table)))
(defmethod list:load-list-state ((s memory-store) env id)
  (declare (ignore env))
  (gethash id (table s)))
(defmethod list:save-list-state ((s memory-store) env id q)
  (declare (ignore env))
  (setf (gethash id (table s)) q))

(test a-store-restores-only-when-the-request-names-none-of-the-list-parameters
  (let ((store (make-instance 'memory-store)))
    (%state "sort=name&page=3&tab=x" :store store)
    (is (equal "page=3&sort=name" (gethash "contacts" (table store))))
    (let ((bare (%state "tab=x" :store store)))
      (is (= 3 (list:list-state-page bare)) "a bare request restores")
      (is (eq :name (list:list-state-sort bare))))
    (let ((named (%state "page=1" :store store)))
      (is (= 1 (list:list-state-page named)) "a request that names the page shows that page")
      (is (eq :added (list:list-state-sort named))))))

(test with-a-store-links-always-name-the-page
  "Otherwise the link to the first page of the default view would have no list parameters,
and following it would restore the stored state instead."
  (let ((store (make-instance 'memory-store)))
    (is (string= "?page=1" (list:list-href (%state "page=2" :store store) :page 1)))))

(test a-tampered-stored-value-is-checked-like-a-request
  (let ((store (make-instance 'memory-store)))
    (setf (gethash "contacts" (table store)) "sort=created_at&page=abc&size=999999")
    (let ((s (%state nil :store store)))
      (is (string= *default-sql* (%sql s)))
      (is (equal '("page" "size" "sort") (list:list-state-adjusted s))))))

(test the-session-store-keeps-the-list-in-the-session
  (let* ((session (sess:restore-session "s1"))
         (store (list:make-session-list-store))
         (env (lambda (q) (list :path-info "/contacts" :query-string q
                                sess:+session-key+ session))))
    (list:read-list-state *spec* (funcall env "page=4") :store store)
    (is (equal "page=4" (sess:session-get session "hyperion/list:contacts")))
    (is (= 4 (list:list-state-page (list:read-list-state *spec* (funcall env nil) :store store))))
    (is (= 1 (list:list-state-page (list:read-list-state *spec* (%env nil) :store store)))
        "without a session nothing is remembered")))

;;; --- components ----------------------------------------------------------------------
;;;
;;; Spinneret's :tree style breaks markup over lines and orders attributes its own way, so
;;; %HTML collapses the whitespace and the tests look for each attribute and each element's
;;; text separately.

(defun %collapse (text)
  "TEXT with each run of whitespace containing a newline made one space, and the spaces next to
a tag's angle brackets removed."
  (let ((out (with-output-to-string (o)
               (loop with i = 0
                     while (< i (length text))
                     do (let ((c (char text i)))
                          (if (member c '(#\Space #\Newline #\Tab))
                              (let ((j (position-if-not (lambda (d) (member d '(#\Space #\Newline #\Tab)))
                                                        text :start i)))
                                (write-char #\Space o)
                                (setf i (or j (length text))))
                              (progn (write-char c o) (incf i))))))))
    (loop for (from to) in '(("> " ">") (" <" "<"))
          do (loop for p = (search from out)
                   while p do (setf out (concatenate 'string (subseq out 0 p) to
                                                     (subseq out (+ p (length from)))))))
    out))

(defun %html (thunk)
  (let ((spin:*html-style* :tree))
    (%collapse (spin:with-html-string (funcall thunk)))))

(defun %ht (&rest kvs)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

(defun count-matches (needle haystack)
  (loop with start = 0 for found = (search needle haystack :start2 start)
        while found count t do (setf start (1+ found))))

(test the-pager-in-the-middle
  (let ((html (%html (lambda () (list:pager (%state "page=5") 312)))))
    (is (search ">Showing 101–125 of 312<" html) "~A" html)
    (is (search "<span aria-current=page>5</span>" html) "~A" html)
    (is (search "href=\"?page=4\"" html) "previous: ~A" html)
    (is (search "rel=prev" html))
    (is (search "href=\"?page=6\"" html) "next")
    (is (search "rel=next" html))
    (is (search "<a href=? aria-label=\"Page 1\">1</a>" html)
        "page 1 links to the empty query: ~A" html)
    (is (search "href=\"?page=13\"" html) "the last page is linked")
    (is (= 2 (count-matches "hyperion-pager-gap" html)) "a gap on each side")
    (is (not (search "hx-get" html)) "no htmx attributes without a target")))

(test the-pager-at-the-ends-and-empty
  (let ((first (%html (lambda () (list:pager (%state nil) 60))))
        (last (%html (lambda () (list:pager (%state "page=3") 60))))
        (empty (%html (lambda () (list:pager (%state nil) 0)))))
    (is (search "<span aria-disabled=true>Previous</span>" first) "~A" first)
    (is (not (search "rel=prev" first)))
    (is (search "<span aria-disabled=true>Next</span>" last) "~A" last)
    (is (not (search "rel=next" last)))
    (is (search ">Nothing to show<" empty) "~A" empty)
    (is (not (search "<a" empty)))))

(test the-pager-clamps-a-page-past-the-end
  (let ((html (%html (lambda () (list:pager (%state "page=99") 60)))))
    (is (search "Showing 51–60 of 60" html) "~A" html)))

(test with-a-target-links-carry-the-htmx-attributes
  (let ((html (%html (lambda () (list:pager (%state "page=2") 60 :hx-target "#contacts")))))
    (is (search "hx-get=\"?page=3\"" html) "~A" html)
    (is (search "hx-target=#contacts" html) "~A" html)
    (is (search "hx-swap=outerHTML" html))
    (is (search "hx-push-url=true" html))))

(test sort-headings-say-which-is-sorted
  (let* ((s (%state "sort=name"))
         (active (%html (lambda () (list:sort-heading s :name "Name"))))
         (other (%html (lambda () (list:sort-heading s :added "Added")))))
    (is (search "aria-sort=ascending" active) "~A" active)
    (is (search "href=\"?sort=name&amp;dir=desc\"" active) "~A" active)
    (is (search "aria-hidden=true>▲</span>" active) "~A" active)
    (is (not (search "aria-sort" other)) "~A" other)
    (is (search "<a href=?>Added</a>" other) "~A" other)))

(test the-page-size-choice-marks-the-current-size
  (let ((html (%html (lambda () (list:page-size-choice (%state "page=3&size=50"))))))
    (is (search "<span aria-current=true>50</span>" html) "~A" html)
    (is (search "<a href=?>25</a>" html) "back to page 1 at the default size: ~A" html)
    (is (search "<a href=\"?size=100\">100</a>" html) "~A" html)))

(test the-text-comes-from-the-translation-source
  (let ((source (i18n:make-dictionary
                 (%ht "de" (%ht "list" (%ht "showing" "{from}–{to} von {total}"
                                            "next" "Weiter")))
                 :default :de)))
    (let ((html (%html (lambda () (list:pager (%state nil) 60 :locale "de" :source source)))))
      (is (search ">1–25 von 60<" html) "~A" html)
      (is (search ">Weiter</a>" html) "~A" html)
      (is (search ">Previous</span>" html) "a key the source lacks is English: ~A" html))))
