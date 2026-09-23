# Scaffolding: templates, target kinds, and how a third party adds one

*Design for `cons`'s project-generation story. 2026-08-05. Consolidates thinking scattered
across [`cons-vision.md`](cons-vision.md) §10, [#37](https://github.com/codelisperer/ouranos/issues/37)
(service target), [#73](https://github.com/codelisperer/ouranos/issues/73) (desktop scaffold),
[#32](https://github.com/codelisperer/ouranos/issues/32) (dependency-source protocol) and
hyperion ADR-0009 (multi-UX) — rather than adding an eighth opinion.*

---

## 1. What is wrong today

`cons init` supports four templates — `:lib`, `:cli`, `:web`, `:agent`. They are
`defparameter *templates*` plus an `ecase` over dependency lists in `init.lisp`.

**Templates are code, not data.** Adding one means editing `cons` and shipping a new `cons`.
So the concrete thing wanted — *take the site tree that evolved in a real application, swap
the logo and palette, and make it available as a SaaS starter* — cannot be done at all,
by anyone, without patching the tool. That is the gap.

Every ecosystem we are measured against solved this years ago: `cargo generate` takes a git
URL, `clj-new` takes a Maven coordinate, `dotnet new -i` installs a template package,
`npx create-<anything>` is just a package. **In each, a third party authors a template
without touching the tool.** That is the bar.

## 2. The conflation to undo

`cons init --template web` bundles two independent decisions into one word, and the
proposed app list is exactly what pulls them apart:

> CLI (with options and a readline-like REPL) · Web SaaS · Web landing page · Desktop ·
> Service (including a real NT service)

A SaaS app and a landing page are **the same target kind** and completely different
templates. A desktop app and a service may share a template and behave nothing alike. So:

| | **Target kind** | **Template** |
|---|---|---|
| Answers | *what `cons build` / `run` / `ship` do* | *what files you start with* |
| Owned by | `cons` (and the frameworks) | anyone, including third parties |
| Count | small, closed, versioned with `cons` | open-ended, growing, external |
| Examples | `lib` `cli` `web` `desktop` `service` | `saas` `landing` `admin` `agent-worker` |

**A template declares its target kind.** `saas` and `landing` both declare `web`; they
differ in files, not in build semantics.

Mapping the list:

| Wanted | Target kind | Template |
|---|---|---|
| CLI with options + readline REPL | `cli` | `cli` (default) |
| Web SaaS | `web` | `saas` ← the one to extract |
| Web landing page | `web` | `landing` |
| Desktop | `desktop` | `desktop` |
| Service, incl. NT service | `service` | `service` |

## 3. Target kinds — what each actually changes

A target kind is not a label; it is a set of `cons` verbs and an artifact shape.

| Kind | `cons run` | `cons ship` | Owns |
|---|---|---|---|
| `lib` | REPL | — | nothing special |
| `cli` | run in terminal | single binary (`save-lisp-and-die`) | argv parsing, terminal I/O, a command loop ([#91](https://github.com/codelisperer/ouranos/issues/91)) |
| `web` | `serve` on a port | binary + assets | the blocking `serve` (pre-publication issue 124) |
| `desktop` | native window | per-OS installer | webview launcher, bundling ([#78](https://github.com/codelisperer/ouranos/issues/78)), installers ([#72](https://github.com/codelisperer/ouranos/issues/72)), updater (pre-publication issue 76) |
| `service` | foreground | OS unit + registration | SCM / launchd / systemd ([#37](https://github.com/codelisperer/ouranos/issues/37)) |
| `shared-lib` | — (nothing to run) | `.dll` / `.so` / `.dylib` + a C header | the exported C ABI, runtime lifecycle, thread registration (§3a) |

Two things follow. **Target kinds are where the platform pain lives** — #37 already
specifies the NT service in detail (the SCM dispatcher, `advapi32`, START_PENDING →
RUNNING with checkpoints, and the open question of whether the dispatcher can live in
SBCL's main thread). Nothing here re-derives that; it places it.

### 3a. `shared-lib` — the one that points outward

The other five produce something a *user* runs. This one produces something **another
language links against**: a `.dll`, `.so` or `.dylib` with a C ABI, built via SBCL's
`save-lisp-and-die :callable-exports` — which the **`librarian`** library wraps.

**It inverts the adoption argument, and that is why it matters more than its size
suggests.** Every other target kind asks someone to adopt Common Lisp. This one asks
nothing: a Python, Rust, Go or C# team calls into Ouranos without writing a line of Lisp
or knowing it is there. Elenchon is the obvious case — a team wanting a minimal
MC/DC-covering test set from a formalized requirement does not want a Lisp; they want a
library. *"You do not have to adopt Lisp to use this"* is a materially easier sell than
anything on the parenthesis page, and it is available to us cheaply because SBCL already
supports it.

Constraints, recorded now because they shape the scaffold rather than being discovered
inside it:

- **Own the binding; do not depend on `librarian`.** It is not in the Quicklisp dist, so it
  would be a git-sourced dependency needing its own pin
  ([#86](https://github.com/codelisperer/ouranos/issues/86)) — and, worse, a **shipped**
  dependency of every library built this way. The house precedent decides it: we rejected
  `cl-libuv` and hand-wrote CFFI because a grovel-based binding puts a C toolchain on the
  load path, and we build libuv from source rather than take a distro package. The pattern
  is **borrow the engine, own the boundary.** Here SBCL is the engine and `librarian` is the
  boundary — so by the same rule it is ours.

  **Read it first anyway.** Not to vendor the code (that raises a licence question we do not
  need), but because it encodes per-platform link flags and lifecycle sequencing that cost
  real time to rediscover. Understand the technique, write our own thin layer, credit it.
  The decision to reverse this is "it turned out to be far more than a thin wrapper" —
  which is a finding, not a guess, and should be recorded either way.

- **Verify SBCL's shared-library support before committing to the target kind at all.**
  `save-lisp-and-die :callable-exports` exists, but producing a *loadable shared library*
  (rather than an executable) depends on how the SBCL in use was built — a linkable runtime
  is not universal. Confirm on all three platforms, at the pinned SBCL, **before** any
  scaffold promises it. Spike first, exactly as [#37](https://github.com/codelisperer/ouranos/issues/37)
  requires for the NT service.
- **Lifecycle is the caller's problem and must be made obvious.** The runtime is initialized
  once before any exported call and finalized after; **one SBCL image per process.** A
  scaffold that does not put this in the generated header and README will produce a library
  that crashes on second use.
- **A foreign thread calling in must be registered with the GC.** The caller's threads are
  not ours.
- **No Lisp condition may unwind into the caller.** Exactly the rule `aion/uv` already
  established for callbacks ([`aion/docs/uv-design.md`](../../aion/docs/uv-design.md) §5),
  now at the outermost boundary: every exported entry point wraps its body and returns a
  status, because unwinding through a foreign frame is undefined behaviour rather than an
  error message.
- **Only C-representable types cross** — stricter than Coalton's promised representations
  ([`docs/coalton-patterns.md`](../../docs/coalton-patterns.md) §7), and the same discipline
  one level out.
- **The artifact is per-OS**, with macOS's `install_name` problem — which is
  [#78](https://github.com/codelisperer/ouranos/issues/78) inverted. There we are consuming a
  native dependency; here **we are the native dependency someone else has to ship.** The two
  should share an answer, and #78's ADR should be written knowing this is coming.

There is a pleasing symmetry with the Coalton thesis. `aion/docs/coalton-story.md` says the
typed layer is where untyped external vocabularies become typed values, decoded once at the
edge. **A C ABI is the most untyped boundary in the system** — and `shared-lib` is where that
rule faces outward instead of in.

And **most of the target kinds are currently half-built**. That is fine — but it means the
template system should not wait for them. A template declaring `service` today can scaffold
files and say the ship path is unimplemented, which is more honest than not existing.

## 4. Templates as data

A template is a **directory plus a manifest**, not Lisp in `cons`:

```
saas/
  template.lisp        ; the manifest: name, target-kind, parameters, dependencies
  files/               ; the tree, with substitution markers
```

Three properties, each chosen against a failure we have already had elsewhere:

**Declarative, not a program.** A template that can run arbitrary code is a supply-chain
problem the moment templates are resolvable by URL. Substitution and conditional inclusion
cover the cases; anything more wants a real reason.

**Resolvable through the dependency-source protocol** ([#32](https://github.com/codelisperer/ouranos/issues/32)).
A template name resolves the same way a dependency does — a built-in, a git URL, later an
OCI artifact. **This is the whole "make it available to `cons`" answer**, and it means the
registry is not a new subsystem, it is a second consumer of one we already need.

**Pinned like everything else.** `cons new` records the template's source and version in
the generated project. A scaffold you cannot identify later is a scaffold you cannot update
or audit — and this tree already treats unpinned things as a defect
([`docs/versioning-and-pinning.md`](../../docs/versioning-and-pinning.md)).

## 5. Authoring — the part that makes the SaaS request possible

Generation is the easy half. **A template system nobody can author from is just a longer
`ecase`.**

```
cons template new <name>            # empty skeleton
cons template from <project-dir>    # extract a template FROM a working app
cons template check <dir>           # generate into a temp dir and build it
```

`cons template from` is the one that matters here. Taking a real application's tree and
turning it into a starter is the actual request, and it has a shape worth getting right:

- **Mark, do not guess.** The tool cannot know which files are skeleton and which are the
  app. A `.consignore`-style manifest in the source project says what travels — reviewed by
  a human, because the failure mode is leaking application content into a public template.
- **Identify substitutions explicitly.** Project name, package prefix, and *branding* —
  logo path, palette — are parameters. That is precisely the "different logo, different
  palette" case, and §5a below is now the concrete mechanism for the palette half.
- **Confidentiality is a first-class check.** Extracting from a private application into a
  shareable template is exactly where a client name escapes. `cons template from` should
  refuse on the [`AGENTS.md`](../../AGENTS.md) name list unless overridden, and say why.

### 5a. Colour scheme is a scaffold parameter, not a styling exercise

*Added 2026-08-05, once the mechanism existed (pre-publication issue 123).*

"Change the colours" has to be a one-line answer for a generated project, or every app
built with `cons` looks like Bulma's demo. **It now is, and the reason is a decision that
was made for a different purpose.**

Vendoring the browser assets forced a version choice, and Bulma **0.9.4 cannot be recoloured
without a build step** — its palette is compiled into the CSS, so changing it means editing
Sass variables and running dart-sass. That is Node, and the asset pipeline this whole stack
exists to avoid. Bulma **1.x derives every colour from CSS custom properties**
(`--bulma-primary-h/-s/-l` and 1400-odd others), so a theme is a handful of declarations on
`:root` — text we generate from Lisp, at scaffold time or at run time, with no toolchain
whatsoever. The tree is on 1.0.4 for that reason.

The mechanism is [`hyperion/assets:theme`](../../hyperion/src/assets.lisp):

```lisp
(assets:theme :primary "#7048e8" :link "#1d72aa"
              :family-primary "Inter, system-ui, sans-serif"
              :radius-large "8px")
;; :root {
;;   --bulma-primary-h: 255.0deg;  --bulma-primary-s: 77.7%;  --bulma-primary-l: 59.6%;
;;   --bulma-link-h: 203.8deg;     --bulma-link-s: 70.9%;     --bulma-link-l: 39.0%;
;;   --bulma-family-primary: Inter, system-ui, sans-serif;
;;   --bulma-radius-large: 8px;
;; }
```

Hex in, HSL out, because HSL is the form Bulma derives its shades from — pass a brand
colour and every tint, shade, and `is-primary` variant follows. Non-colour knobs (fonts,
radii, spacing) pass through verbatim.

What this asks of the template system:

- **A `theme` parameter on any template declaring the `web` or `desktop` target kind**,
  defaulting to Bulma's own palette. `cons new --theme-primary '#7048e8'` should be enough
  to make a generated app not look generic.
- **Generate a `theme.lisp` holding the call, not a `theme.css` holding the output.** The
  parameters stay legible and editable after generation; a wall of computed HSL does not.
  This is the same reason the CSS DSL exists rather than a checked-in stylesheet.
- **Dark mode needs no parameter.** Bulma 1.x ships `prefers-color-scheme` and
  `[data-theme=dark]`; a theme set in hue/saturation/lightness terms follows the OS for
  free. A scaffold should not invent a knob for something already handled.

Note what this does *not* need: no Sass, no PostCSS, no watcher, no build step, and no
choice for the user to make about any of them. That is the claim the stack makes generally,
and theming is where a reader would most expect it to break down.

`cons template check` is the honest half: a template that has never been generated *and
built* is a template that does not work. Same principle as everywhere else in this tree —
the check must run the thing, not inspect it.

## 6. What we deliberately do not build

**A component/composition system.** The tempting model is `saas = web + auth + db +
payments`, composed. Yeoman sub-generators and Rails engines do this; both are substantially
harder than they look, because composed fragments must agree about file layout, config
merging, and ordering. **Monolithic templates, composable target kinds** is the ratio that
works: a template is a whole tree, and the reusable behaviour lives in the target kind and
in the frameworks. Revisit when there are ten templates and a demonstrated duplication
problem, not before.

**A hosted registry.** Resolvable URLs are a registry. A curated index is a product with an
operator, and there is one maintainer.

**Template versioning semantics beyond a pin.** Record what generated the project; do not
attempt migration-on-update. `cargo generate` does not either.

## 7. Sequencing

1. **Split target kind from template** in `cons init`, keeping the four built-ins working.
   Pure refactor, no new capability, and everything else depends on it.
2. **Template manifest + resolution from a directory.** Built-ins move from `ecase` to data
   and stop being special.
3. **`cons template check`** — before external templates exist, because it is what stops
   them rotting.
4. **Resolution via #32**, so a git URL works. This is when third-party authoring becomes real.
5. **`cons template from`** and the `saas` extraction.
6. Target kinds fill in on their own schedule — pre-publication issue 124, #78/#72, #37.

Steps 1–3 are the ones that unblock everything and touch no platform code.

## 8. Why this is competitive rather than catch-up

The comparison is not `cl-project`. It is `cargo generate` and `dotnet new`, and on the
template axis alone we would be matching, not beating.

The differences worth having are the two things adjacent to scaffolding that those tools do
*not* do:

- **`cons conform` ships the framework spec into the generated project** — a tool-neutral
  `AGENTS.md` plus `CLAUDE.md`, `.cursor/rules` and `.claude/skills`, so the assistant
  working on a brand-new app is held to the house rules from the first commit.
  `create-next-app` does not teach your assistant Next.js. **Scaffolding should run
  `conform` by default**, not as a separate verb someone must discover.
  The pack also ships a **check**, not only a spec: `.githooks/commit-msg` refuses a
  `Co-Authored-By` trailer naming an AI assistant. That is the one house rule an agent
  harness actively works against — it injects the trailer and instructs the model to keep
  it — so a line in a document loses to the system prompt contradicting it, and an
  invariant nothing checks is not an invariant. The hook is inert until the project runs
  `git config core.hooksPath .githooks`, which the installer prints.
- **`service` as a first-class target kind, with a real NT service.** No CL tool offers it,
  and few tools in any ecosystem make it a scaffold rather than a deployment afterthought.

That is the honest pitch: parity on templates, and two things above the line.
