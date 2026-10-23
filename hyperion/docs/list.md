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
end shows the last page. Links are relative (`?page=2`), so they stay right under a mounted
router, and nothing from the request's path is written into them. A filter becomes SQL in the app's `:where`:
- `filter-where` gives `(:= column value)` for the `:values` filters that declare a `:column`;
- for anything else, `filter-value` gives the checked value, which the app passes as a value
  and never as an identifier.

A `:text` filter has its control characters removed (Postgres refuses a NUL in a text value)
and is cut to `:max-length`.

### Searching with LIKE

A text filter used in `LIKE` needs its own `%`, `_` and escape character escaped. Otherwise a
user's `%` or `_` is a wildcard: `q=%_%_%_` matches every row, and a pattern full of wildcards
makes the scan slower. `mnemosyne/query:like-contains` builds the pattern, and `:escape` on
`:like` or `:ilike` tells the database which character escapes (#862):

```lisp
(hyperion/list-db:fetch-page *db* state :select '(:id :name) :from '(:contacts)
  :where (let ((q (hyperion/list:filter-value state :q)))
           (and q (list :like :name (mnemosyne/query:like-contains q) :escape "\\"))))
```

With `:escape`, a `%`, `_` or backslash in the term matches only itself, on SQLite (which has
no default escape character) and on Postgres alike. The escape character is bound as a
parameter, like the pattern.

Case still differs: SQLite's LIKE ignores the case of ASCII letters and Postgres's does not.
For the same matches on both, compare `(:lower :name)` with
`(:lower (mnemosyne/query:like-contains q))`, keeping in mind that each database's LOWER folds
its own set of characters. On Postgres alone, `:ilike` with the same `:escape` also works.

## Links

`(list-href state :page 3)`, `(list-href state :sort :name)`, `(list-href state :size 50)` and
`(list-href state :filters '(:status "closed"))` give a relative link, `?` and a query string,
to the current page with that change.
- Every parameter the list does not own is kept, such as a tab the app keeps in the query.
- Choosing the current sort key again reverses the direction.
- Changing the sort, the size or a filter goes back to page 1.
- Values equal to their defaults are left out, so the first page of the default view is `?`.
- A value from code that is not one of the spec's choices signals an error: an unknown sort
  key or size, a filter value outside its set, or a text value too long or with control
  characters.

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

`:tiebreak` is required whenever a list has sort keys. Without a unique column at the end of
`ORDER BY`, rows with equal sort values can come back in a different order on each query, so a
row can appear on two pages or on none.

An app with these needs can still use `read-list-state` and `list-href`, and count some other
way.
