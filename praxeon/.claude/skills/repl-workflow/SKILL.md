---
name: repl-workflow
description: How to load, compile, hot-reload, and test Praxeon in an SBCL REPL — including live-editing a running web server. Use when the user wants to run the system, quickload, run the fiveam test suite, start Elise, hot-reload code into a live image, or set up Coalton/Quicklisp for this repo.
---

# Praxeon REPL workflow

Praxeon is developed REPL-first. Prefer loading and redefining over restarting.

## One-time setup

System discovery is automatic: the monorepo's repo-root `bootstrap.lisp` writes an
ASDF `(:tree)` drop-in at `~/.config/common-lisp/source-registry.conf.d/50-ouranos.conf`
covering the whole tree — the six core frameworks plus the `hermes` satellite
leaf-lib. No symlinking into `~/quicklisp/local-projects`, no
`asdf:*central-registry*`. Run it once from the monorepo root:

```sh
sbcl --dynamic-space-size 4096 --script bootstrap.lisp
```

Deps (install via Quicklisp if missing): coalton, alexandria, dexador,
com.inuoe.jzon, fiveam.

## Load, test, run

```lisp
(ql:quickload :praxeon)          ; compiles src/ incl. the Coalton core
(asdf:test-system :praxeon)      ; runs the fiveam suite (network-free)
(ql:quickload :praxeon/elise)
(praxeon/elise:start)            ; reads its provider from .env (PRAXEON_LLM_*); :quit to exit
```

Non-interactive from a shell:

```sh
sbcl --non-interactive \
     --eval '(ql:quickload :praxeon/tests)' \
     --eval '(uiop:quit (if (fiveam:run! (quote praxeon/tests:praxeon)) 0 1))'
```

## Hot reload

Recompile the edited file (C-c C-k in SLIME/Sly) or reload the system:

```lisp
(asdf:load-system :praxeon :force '(:praxeon))
```

Coalton `coalton-toplevel` forms re-evaluate like any CL form; a type error on
reload is the checker doing its job — read it and fix the core.

### Live-editing a running web server

**Easiest: the file watcher.** `(praxeon/elise:dev)` keeps a *persistent* agent,
serves with `:dev t` on :8080, and watches `src/` + `examples/elise/`. Edit any
`.lisp`, save, and it recompiles + rebuilds the server *around the same agent* and
refreshes `:dev` tabs — the conversation survives. From a shell, `cons dev` does this
from a shell (`serve`/`bin/elise --server` *block* — don't use those for editing).

```lisp
(ql:quickload :praxeon/elise)
(praxeon/elise:dev)          ; persistent Elise + watcher; open http://127.0.0.1:8080
;; edit src/*.lisp or examples/elise/elise.lisp, save -> [dev] reloaded <file>
(praxeon/web:unwatch)        ; stop watcher + server (no args; defaults to *dev*)
```

`dev` is in `praxeon/elise` (Elise-specific) but the stopper is the generic
`praxeon/web:unwatch` (the watcher is framework-level). Restart with `(dev)` again;
`Ctrl-D` drops the whole image and is the reliable hammer if `unwatch` wedges.

Mechanism (`praxeon/web:watch` + `reload!`): a background thread polls
`file-write-date` of `.lisp` files under the watched roots (~0.5 s); on a change it
`compile-file`+`load`s the changed files, and on a clean compile stops the old
server and calls the *builder* thunk to start a fresh one — the builder closes over
the persistent agent, so **state ≠ server** and memory survives. Then `mark-reloaded`
bumps a counter that `:dev` pages poll (`GET /api/reload-epoch`) to `location.reload()`.
Compile error → running server left as-is, error recorded in `dev-last-error`.
(Caveat: `file-write-date` is 1-second-resolution.)

**Finer control (any app / single-`defun` swaps).** A running server also hot-swaps
**render/handler functions with no restart** on their own: the dispatcher calls them
by name, and SBCL resolves through the function cell each request (no block
compilation by default). So start non-blocking, recompile one defun, bump the epoch:

```lisp
(defparameter *h* (praxeon/elise:start-web :agent (praxeon/elise:make-elise) :dev t))
;;   C-c C-c the changed %page / %assistant-bubble / respond   ; into the running image
(praxeon/web:mark-reloaded)                ; every :dev tab reloads itself
(praxeon/web:stop *h*)
```

Pass `:agent` an agent you keep in a global so `stop`+`start-web` preserves history
(otherwise `start-web` builds a fresh one — that wipes the conversation). Elise's
`start-web` passes the responder *by name* (`(lambda (a m) (respond a m))`), so
recompiling `respond` is live too (see the capture gotcha below). Run **one** Woo
server per image — starting a second concurrently crashes libev.

What does **not** hot-swap — needs `(praxeon/web:stop *h*)` then `start` again
(instant, same image):

- values captured by `start`/`make-app`: `title`, `intro`, `footer`, `port`, the
  `agent`, and a `#'fn`-captured `responder` (see the capture gotcha below);
- the set of **routes** (the dispatch lambda captures their structure).

## Gotchas

- praxeon/llm:*default-model* is a Claude Platform string; confirm the exact API
  id before relying on it.
- If dexador fails to load on TLS, install libssl/openssl dev headers and retry.
- **`in-package` only affects the reader *between* top-level forms.** Every symbol
  in a single already-read form was interned under the package in effect when that
  form was read — so `(progn (in-package :other) (defun foo …))` defines the
  *current* package's `foo`, not `other::foo`. The redefinition silently hits the
  wrong symbol and appears to do nothing. From a script (or any single form),
  redefine another package's function with an explicit `other::foo`, or make the
  `in-package` and the `defun` **separate** top-level forms. Classic symptom: "my
  `C-c C-c`/redefinition had no effect on the running system."
- **Captured function *objects* freeze; by-name calls stay late-bound.** `#'foo`
  evaluates to the function object *now*; stashing it in a struct slot or closure
  means a later redefinition of `foo` is never seen. A plain call `(foo …)` goes
  through the symbol's function cell each time, so it *is* hot-swappable. To keep a
  stored hook redefinable, capture a thunk — `(lambda (x) (foo x))` — or funcall a
  symbol, rather than `#'foo`. (This is exactly why a running server's render fns
  hot-reload but a `:responder #'respond` handed to `start` does not.)
