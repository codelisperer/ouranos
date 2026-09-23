# Research: Embedded live REPLs + runtime CL compilation

*Researched 2026-07-16. Where code is cited, it was read from source cloned into
`~/common-lisp/` (`slime/`, `sly/`, `Parenscript/`, `clog/`, `zs3/`,
`alive-lsp/`) — ground truth. Web claims cited with URLs.*

## Recommendation

> **Embed Slynk (Swank-compatible) as the primary remote REPL, gated behind an
> env flag and localhost-only. Add a generic HTMX browser REPL as a secondary,
> dev-gated surface. For dynamic compilation, generalize praxeon's existing
> hot-reload loop into a pluggable *asset-source protocol* (local dir + S3 via
> zs3) feeding `compile-file`/`ps-compile-file` with atomic live swaps.** Treat
> all authored resources as **trusted**; untrusted eval needs a separate confined
> process, never in-image tricks.

---

## Part A — Live REPLs in a running web app

### A.1 Swank/Slynk embeds trivially — but a REPL port is a root shell

One call starts a listener in the *same live image* as the web server:

```lisp
(defun start-dev-repl (&key (port 4005))
  (require :slynk)
  (slynk:create-server :port port
                       :style :spawn        ; each connection = its own thread
                       :interface "localhost"
                       :dont-close t))      ; keep listening for reconnects
```

Connect from Emacs (`M-x sly-connect`/`slime-connect`) and redefine handlers,
inspect state, `C-c C-c` a changed function — the next HTTP request uses it.

**The facts that matter (verified in `slime/swank.lisp`, `sly/slynk/slynk.lisp`):**

- **`:dont-close` defaults to `nil`** — without `:dont-close t` the socket closes
  after the *first* connection (the classic "can't reconnect after Emacs drops").
  Always pass `t`.
- **Binds `localhost` by default** — *not* remotely reachable. Reach prod via an
  **SSH tunnel** (`ssh -L 4005:localhost:4005 host`). **Never bind `0.0.0.0`.**
- **Auth is opt-in and weak** — a shared secret is checked *only if*
  `~/.slime-secret` exists, sent essentially in the clear. No TLS, no
  per-user auth.
- **No sandbox** — a connected client has full `eval` (can `run-program`, read
  secrets, mutate any global). **Treat the port as a root shell on the image.**
- **Threading:** `:spawn` eval runs on worker threads concurrently with in-flight
  HTTP requests over shared mutable state — the power and the danger.

**Prod posture:** off by default, behind `HYPERION_REPL_PORT`, localhost-only,
SSH-tunnel documented, optionally require `~/.slime-secret`. (Mirrors how the
ecosystem already selects backends via env, e.g. `HYPERION_SERVER`.)

### A.2 Slynk (SLY) vs Swank (SLIME) — target Slynk

Same API (`slynk:create-server`, same `:dont-close`/`:style` semantics — verified
line-for-line). Differences: SLY loads Slynk via clean `asdf:load-system` (vs
SLIME's bespoke `swank-loader`); SLY's **mREPL is richer** (result store,
stickers, multiple inspectors, presentations); SLY is the **more actively
developed line in 2026**. **Embed Slynk, document Swank as the compatible
fallback.** Don't load both into one image.

### A.3 Editor-agnostic protocols — the messy 2026 reality

- **There is no mature CL nREPL.** nREPL is a Clojure protocol; the only CL impl
  (`sjl/cl-nrepl`) is bare-bones/dormant. **Don't build on it.**
- **⚠️ Correction — VS Code Alive does NOT use Swank.** The
  [cl-cookbook page](https://lispcookbook.github.io/cl-cookbook/vscode-alive.html)
  says it does; the actual `alive-lsp` source has **no swank/slynk dependency** —
  it's its own **LSP server with custom `$/alive/*` JSON-RPC extensions** over
  usocket, using SBCL introspection directly. **Trust the source, not the
  cookbook.**
- So there are **three incompatible CL REPL wire protocols**: Swank (SLIME),
  Slynk (SLY), Alive-LSP (VS Code). The *de facto* editor-agnostic substrate is
  still **Swank/Slynk**, because the non-Emacs clients that matter speak it:
  **SLIMA** (Pulsar), **vlime** (Neovim), **Lem**. VS Code went its own way.

### A.4 Browser REPL prior art — CLOG is the reference

CLOG's `clog-repl` (`clog-helpers.lisp:103`) serves `/repl`, holds the browser DOM
over a websocket, and binds `clog-user:*body*` so you can `(create-div ...)` from
your Emacs REPL and see it appear live. **No maintained standalone "cl-repl-web"
worth adopting** — CLOG is the living implementation.

### A.5 Recommendation — embed both, cleanly separated

1. **Slynk socket REPL (primary), Swank-compatible.** Dev-gated, localhost-only,
   SSH-tunnel + optional `~/.slime-secret`. Gives Emacs/Neovim/Pulsar/Lem
   connectivity for free — *"web apps have a live REPL connectable via traditional
   CL remote REPL commands."*
2. **Browser REPL (secondary), HTMX-native.** A generic `/_hyperion/repl`
   component: form POSTs a string → server `read`s + `eval`s under strict guards
   (A/B.5) in a chosen package → HTMX-swaps the printed result into a transcript
   div. Rebuilds CLOG's idea on Hyperion's own stack.
3. **Do not** adopt cl-nrepl or build a bespoke nREPL. If VS Code support becomes
   a goal, integrate **alive-lsp** as a separate LSP track — it is not a REPL
   protocol you embed.

---

## Part B — Runtime CL compilation in Hyperion projects

### B.0 You already have the core loop — build on it

`praxeon/src/web.lisp` (the extraction source) already implements the
Figwheel-style loop: `%snapshot` (namestring → `file-write-date`) →
`%changed-files` diff → 0.5s poll → `%recompile` does **`compile-file` (diags
captured into a broadcast stream → browser overlay) then `load`**, stops the old
Clack handler, rebuilds it around **preserved state**, and calls `mark-reloaded`
so `:dev` tabs refresh. **State ≠ server.** Generalize "watch praxeon's `src/`"
into "watch arbitrary user resource roots (local dirs + S3 mirrors)."

### B.1 `compile-file` vs `compile` vs `eval` on SBCL

SBCL is compile-only (even `eval` compiles). So the choice is *unit of work +
file hygiene*, not compiled-vs-interpreted:

- **`compile-file` → `load` (temp fasl):** the workhorse for **file-backed
  resources**. Full file semantics (`eval-when`, reader macros, source locations)
  and compiler warnings as data. What praxeon uses. Cache fasls under an XDG cache
  keyed by `(content-hash . write-date)`.
- **`compile`:** a single already-read lambda, in-memory, no file — "recompile
  *this one* render function."
- **`eval`:** one form; simplest, for the browser-REPL path only (loses
  file-level `eval-when`/clean warning capture).

### B.2 Spinneret templates as hot-swapped `.lisp` scripts

Model a template as a *named render function* looked up indirectly, so
recompiling rebinds the symbol and the next request picks it up — zero restart:

```lisp
;; templates/dashboard.lisp
(in-package :hyperion-user)
(define-template dashboard (ctx)
  (spinneret:with-html
    (:section.card (:h1 (getf ctx :title)) (:p (getf ctx :body)))))
```

`define-template` expands to a `defun` on a symbol in a registry
(`name → fn` hash-table). The watcher's `compile-file`+`load` redefines it in
place (CL's redefinition guarantee → atomic per-request swap). Rendering always
goes through the registry. Because Spinneret templates are *code, not strings*,
"hot-load a template" = "recompile a function" — strictly more robust than
reparsing a template string. (This is the constitution's `render` generic:
"CLOS + Spinneret own rendering; runtime-open.")

### B.3 Parenscript compiled to JS at runtime

**⚠️ Correction — the runtime entry point is `ps*`, not `compile-script`**
(stale naming). Verified in `Parenscript/src/compilation-interface.lisp`:

- **`ps*` (function):** compiles body forms → JS string at runtime. Your runtime
  compiler. `(ps:ps* '(alert "hi"))`.
- **`ps` (macro):** compiles at macro-expansion — for JS baked into the image at
  build time (e.g. Hyperion's own hot-reload poller — a dogfood target).
- **`ps-compile-file` / `ps-compile-stream`:** the `compile-file` analogue for
  `.paren` script files — reads forms, compiles each as by `ps*`, returns a JS
  string; rebinds `*readtable*`/`*package*` around the read (hygiene).

```lisp
(defvar *ps-cache* (make-hash-table :test 'equal))  ; path -> (write-date . js)
(defun compiled-js (path)
  (let ((wd (file-write-date path)) (hit (gethash path *ps-cache*)))
    (if (and hit (= (car hit) wd)) (cdr hit)
        (let ((js (parenscript:ps-compile-file path)))
          (setf (gethash path *ps-cache*) (cons wd js)) js))))
;; serve with Content-Type application/javascript, ETag = write-date/hash
```

### B.4 Resources from user folders or S3 — a virtual asset FS

Define a small **asset-source protocol** (CLOS generic or Coalton-typed
capability — "pluggable backends behind neutral protocols") with `fetch` / `list`
/ `stat` (version/etag token):

- **`local-dir`** — `directory` + `file-write-date`; feeds the existing watcher.
- **`s3`** — backed by **zs3** (mature, maintained; Zach Beane). Verified API in
  `zs3/interface.lisp`: `all-keys` (listing), `get-object`/`get-string` with
  **conditional GET** (`when-modified-since`, `when-etag-matches`) — exactly what
  a cache/invalidation layer wants. Creds in `zs3:*credentials*` (+ STS token).

**S3 pipeline shape:** poll `all-keys` (or S3 event notifications) → compare
etags against cache → `get-object` changed keys into the local fasl/JS cache →
run through B.1/B.3 → atomically swap. **S3 is just a *source*; the compile+swap
machinery is unchanged.** (aws-sdk-lisp exists but is heavier; **zs3 preferred**.
aws-sdk-lisp's 2026 maintenance status is *unverified*.)

### B.5 Safety / sandboxing — trusted vs untrusted

**CL has no language-level sandbox.** Two tiers:

- **Trusted authored resources (normal case — your templates, your Parenscript,
  your bucket):** full `compile-file`/`ps-compile-file`/`load`, with **hygiene**:
  read into a dedicated `:hyperion-user` package (bound `*package*`), bind a known
  `*readtable*`, keep templates effect-free (return Spinneret data, no IO).
- **Untrusted / user-submitted CL (e.g. a public browser REPL):** **mandatory
  `(let ((*read-eval* nil)) (read ...))`** to disable `#.` read-time eval (the #1
  CL RCE); whitelist symbols (best-effort, fragile); eval on a worker thread with
  a timeout and captured output. For anything truly hostile, run in a **separate
  SBCL process under OS limits** (seccomp/container/jail) — in-image guards are
  defense-in-depth, not a sandbox.

**Default:** browser REPL + asset pipeline are **trusted-only and dev-gated**;
untrusted-eval is an explicit, discouraged opt-in that spawns a confined
subprocess.

---

## Recommended architecture

```
            ┌──────────────── Hyperion live SBCL image ────────────────┐
 Emacs ─────┼─► Slynk/Swank socket REPL (localhost:4005, :dont-close t,  │
 Neovim ────┤     SSH-tunnel in prod, ~/.slime-secret, dev-gated)        │
 Pulsar ────┘                                                            │
            │  Browser REPL (/_hyperion/repl, HTMX POST → guarded        │
 Browser ───┼─►  read+eval, *read-eval* nil, :hyperion-user, dev-gated)  │
            │  ┌── Asset-source protocol (neutral, pluggable) ──┐        │
 dirs ──────┼─►│ local-dir: directory + file-write-date          │        │
 S3 ────────┼─►│ s3: zs3 all-keys / get-object (etag-aware)       │        │
            │  └───────────────┬──────────────────────────────────┘        │
            │  watch (0.5s, mutex, %snapshot/%changed)                     │
            │     ├─ .lisp templates → compile-file+load → redefine fn     │
            │     ├─ .paren scripts  → ps-compile-file → *ps-cache* (ETag) │
            │     └─ static assets   → serve (ETag)                        │
            │  atomic swap → next request uses new render / new JS         │
            │  mark-reloaded → :dev tabs HTMX-refresh; error → overlay     │
            └──────────────────────────────────────────────────────────────┘
```

**Build order:** (1) extract praxeon's `watch`/`reload!`/`%recompile` into
Hyperion, swap hardcoded `src/` for the asset-source protocol; (2) template
registry so `.lisp` templates redefine render fns in place; (3) `ps-compile-file`
+ `*ps-cache*` for `.paren`, served with ETags; (4) zs3-backed `s3` source
(etag-mirror → reuse 1–3); (5) embed Slynk with dev/prod gating; (6) generic
HTMX browser REPL, trusted-only, dev-gated, `*read-eval* nil`.

## Roadmap implications

- Threads for the roadmap: **"Dynamic asset pipeline + hot-reload"** (items 1–4)
  and **"Embedded REPLs"** (items 5–6). Item 1 depends on the engine extraction
  already listed as "start here next."
- The asset-source protocol is another instance of the constitution's
  pluggable-backend pattern — design it alongside the web-server backend.

## Flagged / unverified

- **Corrected:** Alive ≠ Swank (own LSP); Parenscript runtime = `ps*` not
  `compile-script`. Both verified in source.
- No mature CL nREPL in 2026.
- aws-sdk-lisp 2026 maintenance unverified (zs3 verified).
- Swank/Slynk security specifics verified directly in cloned source (high
  confidence).
