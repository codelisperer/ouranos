# klio

A git-backed content engine: Markdown files with front matter, loaded into an immutable tree
that is published all at once, and served by a hyperion site or exported to static files.

## Using klio from a site

```lisp
(defparameter *site* (klio:make-site #p"content/" :known-extra '("start" "bullets")))
(klio:boot *site*)                                   ; refuses to start if any file fails

;; In a theme function: every readable role, newest first, with its nested front matter.
(klio:collection *site* "roles" :sort-by "start" :order :descending)
(klio:document-field role "bullets")                 ; lists of maps, as written
(klio:document-by-slug *site* "skills")              ; another page, if a reader may see it

;; Served by hyperion, or written out for a static host.
(hyperion/server:start (klio:site-app *site* :page-theme #'my-page :index-theme #'my-index))
(klio:export-site *site* #p"public/" :page-theme #'my-page :index-theme #'my-index :clean t)
```

A collection is a directory under the content directory. A theme reads collections and other
pages from the same tree its request, or the export, is using, so a reload during a request
cannot mix two versions on one page. `export-site` writes `index.html`, `404.html` and one file
per readable page (`roles/a.html` for the page served at `/roles/a`, or `roles/a/index.html`
with `:layout :directory`). It writes nothing if any page fails to render, and it refuses a
non-empty directory unless given `:clean t`. The site copies its own static assets.

A controlled list, such as skills, is declared once and checked on every load: a page that
refers to a label that is not in the list fails to load, naming both files.

```lisp
(klio:make-site #p"content/"
  :known-extra '("groups" "skills" "bullets")
  :vocabularies (list (klio:make-vocabulary "skills" :source "skills" :entries '("groups" "skills")
                                            :references '(("skills") ("bullets" "skills")))))
(klio:vocabulary-entry-p *site* "skills" "C#")       ; in a theme
```

`site-app` and `export-site` take the same options (`make-site-options`): the themes, `:per-page`
to paginate the index and each tag's listing (`/page/2/`, `/tags/<tag>/page/2/`), `:base-url` to
turn on the RSS and Atom feeds (`/feed.xml`, `/atom.xml`, with `:feed-collection` such as
`"posts"`), and the paths of all of these and of the search index, `/search.json`, a JSON array
of every readable page for a search box. A tag's URL is its slug (`C#` is `/tags/c-sharp/`). A
listing theme gets `*page-number*` and `*page-count*`, and `page-url` and `tag-url` for links.
`publish-at` takes an ISO 8601 date, and a scheduled page appears when its time comes.

In development, `(klio:watch-site *site*)` reloads when a content file changes and keeps
serving the last good content when an edit breaks a file; `stop-watching` stops it. How a
production server is told to reload is recorded, not yet built, in
`docs/adr/0002-reload-in-production.md`.

## Develop

    cons build   # compile
    cons test    # run tests
    cons repl    # SBCL REPL with the tree on the path
    cons serve   # run the web app on http://127.0.0.1:8080
    cons bin     # dump a native bin/klio
    cons         # list all targets

Tasks are declared in `cons.lisp` (the cross-OS Makefile replacement). Config/env:
copy `.env.example` to `.env` and fill it in -- it loads via `cons/env:load-dotenv`
(the host environment wins in prod).

## Commits

No `Co-Authored-By` trailers naming an AI assistant -- see `AGENTS.md` (Attribution) for
where AI's role is recorded instead. A `commit-msg` hook enforces it; wire it once, after
`git init`:

    git config core.hooksPath .githooks

Scaffolded by `cons init`.
