# Dynamic resources & hot-reload (design)

*Design capture — not built yet. Prior art & detail:
[research/live-repl-and-dynamic-compilation.md](research/live-repl-and-dynamic-compilation.md)
§B. Extends `hyperion/dev` (the Figwheel loop).*

## Motivation

Hyperion's signature is the live-image hot-reload loop. Today it recompiles
`.lisp` under watched roots and rebuilds the server around *preserved state* —
great for framework + app **source**. But when co-developing an app (e.g. Elise)
with Praxeon **and** Hyperion, we also want **dynamic content areas** that refresh
live without touching the Lisp system: HTML templates authored in pure **Spinneret**,
and client JS authored in pure **Parenscript**. Edit a template or a script file →
it's live on the next request, no full server rebuild.

## Two tiers of hot-reload

### Tier 1 — Source hot-reload (exists)
`hyperion/dev:watch` recompiles changed `.lisp` in watched roots and rebuilds the
server around preserved state; compile errors become the browser overlay. Covers
Spinneret render fns and Parenscript helpers that are **part of the ASDF system**.
- **Near-term gap:** watch *multiple* roots when co-developing (app + `hyperion` +
  resource dirs). See the roadmap "Dev-loop & JS follow-ups" backlog.

### Tier 2 — Resource hot-reload (new — the "dynamic code areas")
Designated resource folders, **decoupled from the ASDF build**, watched with
per-file-type handlers, compiled and swapped atomically:

- **`templates/*.lisp` (Spinneret)** — each file `(define-template name (ctx) …)`
  registers a render fn in a **template registry**. Edit → `compile-file` + `load`
  → the render fn is redefined *in place* (CL redefinition = atomic per request).
  Rendering goes through the registry: `(render-template :name ctx)`. Because
  templates are *code, not string templates*, "hot-load a template" = "recompile a
  function" — strictly more robust than reparsing a template string.
- **`scripts/*.paren` (Parenscript)** — compiled via `ps-compile-file` / `ps*` to a
  JS string, **cached by write-date**, served at `/js/<name>.js` (with an ETag) or
  inlined. Edit → recompile → fresh JS. Honors the output style (ADR-0005): pretty
  in dev, compact in prod.

Both are backed by an **asset-source protocol** (`fetch` / `list` / `stat`) so a
resource root can be a **local directory** now and an **S3 bucket** (via `zs3`)
later — the compile+swap machinery is identical; only the source differs.

## Dev vs prod: one source of truth

**In REPL/dev mode, dynamic resources are external source files that are
`require`d / loaded live** — the file on disk is the single source of truth
("*the source is the source is the source*"). There is **no embedded or generated
duplicate** to drift from; you edit the file and the watcher reloads it. In **prod**
(the built `save-lisp-and-die` binary), those same resources are compiled and
**embedded into the image** so the binary is self-contained.

Same duality as output-style (ADR-0005): dev favors live/editable, prod favors
baked/self-contained — driven off the same dev/prod signal. And it applies
uniformly: framework helpers are *system source* loaded from files; app
templates/scripts are *resource source* loaded from files; **nothing is a
hand-maintained embedded copy.** (This is also why an app's custom JS should be a
`.paren` file loaded live in dev, not a string literal baked into a handler.)

## Integration with `hyperion/dev`

Generalize the watcher from "recompile `.lisp` + rebuild server" to a set of
**resource handlers** keyed by root (and file type):
- a **system-source** root → recompile + rebuild the server (Tier 1, today);
- a **template** root → recompile + redefine the render fn (no rebuild);
- a **script** root → recompile JS + invalidate its cache entry.

The snapshot/poll loop and the compile-error overlay stay; only the per-change
*action* varies by handler.

## Trust

These are **trusted** authored resources (the dev's own files) → full
`compile-file`, with package/readtable hygiene (read into a dedicated app package;
bind a known readtable). Untrusted/user-submitted eval is a separate concern
(research §B.5: `*read-eval* nil`, symbol allow-list, or an OS-confined subprocess)
and out of scope here.

## Open questions

- **Conventions:** `.paren` vs `.lisp` for Parenscript files; a `templates/` marker
  dir vs a manifest; where resource roots are declared (app config).
- **Serving JS:** per-URL endpoint (cacheable, ETag) vs inline; future bundling.
- **Registry home & API:** the template registry and `define-template` macro —
  `hyperion/html`? How templates compose with the Coalton-typed HTMX vocabulary.
- **Granularity/caching:** redefine one template vs rebuild; cache-invalidation keys
  (write-date vs content hash).
- **Coalton in templates:** typed HTMX values inside `define-template`.

## Status & sequencing

Design captured; **not built**. Best driven by **a consuming app**, which is a natural
first consumer — its landing page can become a *template resource* and its
`main.js` a *Parenscript resource* — so the pipeline is shaped by real use once the
initial landing-page port lands. Tier-1 multi-root watch is the cheap, immediate
win; Tier-2 is the larger feature.
