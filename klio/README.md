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
non-empty directory unless given `:clean t`. `:assets` names a directory of the site's own files
(CSS, images, fonts, `.well-known/`), copied into the export after `:clean` empties it, each at
its path relative to that directory. The export is refused, before anything is written, if an
asset and a page cannot both be written (the same path, or one under the other), if the assets
directory holds a link, or if it holds or is inside the export directory.

In a collection, `:sort-by` names a field, `:order` is `:ascending` (the default) or
`:descending`, and a document without the field comes last. Documents tied on the field keep
ascending key order under either `:order`, because `:descending` reverses the comparison and not
the list. `:then-by` names a second field that orders a tie in the same direction, with a
document lacking it last among the tie. `:then-by` without `:sort-by` is an error:
`(klio:collection *site* "posts" :sort-by "date" :order :descending :then-by "title")`.

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

`/search.json` holds, for every readable page, its URL, title, tags, date and Markdown body, and
anyone can fetch it. Pass `:search-path nil` to `site-app` and `export-site` to have no search
file, or put `search: false` in a page's front-matter to leave that page out of it and out of the
in-memory search index; any value other than `true` leaves the page out. HTML comments
(`<!-- ... -->`) are removed from a page's body when it is loaded, so they reach neither the page,
nor `/search.json`, nor the index. A comment is kept only when klio's own renderer shows all of
it, from `<!--` through `-->`, inside one code element on the page, such as one code span, one
fenced block or one indented block, because it is then part of the code. klio decides this by
rendering the body, not by reading the Markdown itself, so a fence or a block quote that looks
like code but renders as text does not keep a comment, and neither does a comment that starts in
code and ends outside it. `<!-->` and `<!--->` are whole comments, as CommonMark defines them, so
the text after them stays on the page. A comment that is never closed removes the rest of the
body, and the load warns about it. HTML comments are removed from the body only: front matter is
YAML, so write a note there as a YAML `#` comment, because a `<!-- -->` in a front-matter value
is kept and published. Before this, klio showed a comment on the page as escaped text.

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
