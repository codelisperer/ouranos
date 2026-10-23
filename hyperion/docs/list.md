# hyperion/list

Paging, sorting and filtering a list from the query string (#488). An app declares a list
once. For each request, `hyperion/list`:

- reads the request's state against that declaration;
- gives the `:order-by`, `:limit` and `:offset` for a mnemosyne query;
- builds the links that change one part of the state;
- renders a pager, sortable column headings and a page-size choice.

`hyperion/list-db` adds `fetch-page`, which runs the page and counts the total.

The systems are `hyperion/list` (no database) and `hyperion/list-db` (depends on mnemosyne),
both opt-in, in `hyperion/src/list.lisp` and `hyperion/src/list-db.lisp`.

## The request only chooses

mnemosyne writes a string identifier into SQL exactly as given, and does not check an ORDER BY
direction (#860). So nothing from the request ever becomes an identifier here. These are the
only things a request can pick:
- one of the declared sort keys, compared by name and never interned;
- `asc` or `desc`;
- a page and a page size, both checked;
- filter values, checked against their declaration.

Every column in the clauses comes from the spec. A value that does not fit falls back to the
default, and `list-state-adjusted` lists the parameters that were replaced. This includes an
unknown sort key, a page that is not 1 to 9 digits, a page size not in `:page-sizes`, and a
filter value outside its set.

## Declaring a list

```lisp
(defparameter *contacts*
  (hyperion/list:make-list-spec
   :id "contacts"
   :sorts '((:name  :column :name)
            (:added :column :created_at :direction :desc))
   :default-sort :added
   :tiebreak :id                                 ; keeps rows with equal sort values in one order
   :filters '((:status :values ("open" "closed") :column :status)
              (:q :text t :max-length 100))
   :page-size 25 :page-sizes '(25 50 100)        ; the largest is the most a page can hold
   :hx-target "#contacts"))                      ; optional: links also update in place
```

The query parameters are `page`, `size`, `sort`, `dir` and each filter's name, for example
`?status=open&sort=name&dir=desc&page=2`. With `:prefix "contacts."`, they become
`contacts.page` and so on, so two lists on one page don't share their parameters.

## A handler

```lisp
(defun contacts-page (env)
  (let ((state (hyperion/list:read-list-state *contacts* env)))
    (multiple-value-bind (rows total state)
        (hyperion/list-db:fetch-page *db* state
                                     :select '(:id :name :status) :from '(:contacts)
                                     :where (hyperion/list:filter-where state))
      (let ((table (spinneret:with-html-string
                     (:div :id "contacts"
                       (:table (:thead (:tr (hyperion/list:sort-heading state :name "Name")
                                            (hyperion/list:sort-heading state :added "Added")))
                               (:tbody (dolist (r rows) (:tr (:td (getf r :name))))))
                       (hyperion/list:pager state total)))))
        (if (hyperion/http:htmx-request-p env)
            (list 200 '(:content-type "text/html" :vary "HX-Request") (list table))
            (render-whole-page table))))))
```

`fetch-page` counts first and brings the page within the pages that exist, so a page past the
end shows the last page. A filter becomes SQL in the app's `:where`:
- `filter-where` gives `(:= column value)` for the `:values` filters that declare a `:column`;
- for anything else, `filter-value` gives the checked value, which the app passes as a value
  and never as an identifier.

## Links

`(list-href state :page 3)`, `(list-href state :sort :name)`, `(list-href state :size 50)` and
`(list-href state :filters '(:status "closed"))` link to the current path with that change.
- Every parameter the list does not own is kept, such as a tab the app keeps in the query.
- Choosing the current sort key again reverses the direction.
- Changing the sort, the size or a filter goes back to page 1.
- Values equal to their defaults are left out, so the first page of the default view is the
  bare path.

## The components

Each writes into `spinneret:*html*` and takes `:locale` and `:source`, a hyperion/i18n
translation source that defaults to the request's. Text is under the `list` section, with
English for a missing key: `showing` ("Showing {from}–{to} of {total}"), `empty`, `previous`,
`next`, `pages`, `page` ("Page {page}") and `page-size`.

- **`pager`** writes:
  - the rows shown;
  - previous and next;
  - the pages within `:window` (2) of the current one, plus the first and last, with gaps
    marked.

  The current page carries `aria-current="page"`. Previous on the first page and next on the
  last are text, not links.
- **`sort-heading`** writes a `<th>` with a link that sorts by its key. The current sort's
  heading carries `aria-sort`.
- **`page-size-choice`** writes a link for each allowed size, with the current one as text.

Every link is a real `href`, so a list works without JavaScript. When a target is given, in
the spec or as `:hx-target`, the links also carry `hx-get`, `hx-target`, `hx-swap="outerHTML"`
and `hx-push-url="true"`. A handler uses `hyperion/http:htmx-request-p` to return only the
list for htmx, and sends `Vary: HX-Request` so a cache does not serve one as the other.

## Remembering a list's state

`read-list-state` takes `:store`, an object with methods for `load-list-state` and
`save-list-state`.
- When the request carries none of the list's parameters, the stored ones are used. They are
  checked like a request, so a stored value that no longer fits is dropped.
- Otherwise the request's checked parameters are saved.
- With a store, links always name the page, so the first page of the default view stays
  reachable.

`make-session-list-store` keeps the state in the request's session. That is per session, not
per account, and it needs `wrap-session`. For per-account state, an app implements the two
generics over its own table.

## Not covered

- Keyset ("seek") paging: `OFFSET` gets slower on deep pages.
- The cost of `COUNT(*)` on very large tables.
- User-chosen sorts on several columns, and saved views.

An app with these needs can still use `read-list-state` and `list-href`, and count some other
way.
