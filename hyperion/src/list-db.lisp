;;;; list-db.lisp --- one page of a hyperion/list and its total, through mnemosyne (#488).
;;;;
;;;; Separate from hyperion/list so that a list without a database, or one whose total comes
;;;; from somewhere cheaper than COUNT(*), does not carry mnemosyne.

(cl:defpackage #:hyperion/list-db
  (:use #:cl)
  (:local-nicknames (#:list #:hyperion/list)
                    (#:query #:mnemosyne/query))
  (:documentation "FETCH-PAGE: one page of a hyperion/list and its total, through mnemosyne (#488).")
  (:export #:fetch-page))

(in-package #:hyperion/list-db)

(defun fetch-page (connection state &key (select '(:*)) from join where
                                         (dialect query:*dialect*))
  "One page of rows for STATE, with the total. Returns three values: the rows (a list of
plists, as MNEMOSYNE/QUERY:FETCH returns them), the total number of rows matching FROM, JOIN
and WHERE, and STATE with its page brought within the pages that exist.

Two queries run on CONNECTION. The first counts the rows of FROM, JOIN and WHERE. The second
selects SELECT from the same FROM, JOIN and WHERE, with the ORDER BY, LIMIT and OFFSET of
HYPERION/LIST:LIST-CLAUSES for the page. Counting first means a request for a page past the
end gets the last page, not an empty one.

WHERE is the app's: it is where the list's filters become SQL, with HYPERION/LIST:FILTER-VALUE
passed as values and HYPERION/LIST:FILTER-WHERE for a closed set on one column. Nothing from the
request reaches an identifier: the ORDER BY columns come from the list's spec."
  (let* ((base (append (list :from from)
                       (when join (list :join join))
                       (when where (list :where where))))
         ;; The row's one value, read by position: the backends key a column alias
         ;; differently (SQLite keeps its case and returns :|n|).
         (total (second (first (query:fetch connection
                                            (list* :select '((:as (:count :*) :n)) base)
                                            :dialect dialect))))
         (state (list:clamp-page state total))
         (rows (query:fetch connection
                            (append (list :select select) base (list:list-clauses state))
                            :dialect dialect)))
    (values rows total state)))
