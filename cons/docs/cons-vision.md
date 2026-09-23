# cons — Vision & Open Questions

*A working alignment doc, mirroring the siblings' vision files. Claude asks pointed
questions; you answer fully and candidly. Answers re-order `docs/roadmap.md`.*

**Status:** interview open (started 2026-07-15).

> Decided (from the Praxeon session): `cons` is cargo/npm/go-tool for CL — a thin,
> opinionated front-end that delegates (ASDF for build, ql/ocicl for deps) and adds
> DX; a neutral **dependency-source protocol** (Quicklisp + ocicl backends now, a
> native resolver later to obsolete both); `cons new` scaffolding as the MVP;
> distributed as a `bin/cons` binary.

> **Founder note (2026-07-16) — `cons init`:** an early feature to run the
> *from-scratch* environment setup a new user needs to run the stack — install
> **SBCL** + **Quicklisp** + **ocicl**, and (**if they opt in to contributing**)
> download **all the sibling projects** into a dir of their choosing for local dev.
> It is the ecosystem-wide replacement for each repo's hand-rolled
> `scripts/setup.{sh,ps1}` (SBCL/Quicklisp/Coalton checks + local-projects links),
> collapsing them into one command. Distinct from `cons new` (project scaffolding);
> ties into §7 (distribution / bootstrap). *To be fleshed out over in the cons
> project.*

---

## 1. Coalton, or lean? (the bootstrapping tension)

The other siblings have a Coalton typed core. But `cons` is the tool that
*eliminates* setup friction — if `cons` itself needs the Coalton-checkout + big-heap
ritual, that's ironic and makes it hard to install. **Should `cons` use Coalton**
(e.g., to type the dependency graph / version constraints as ADTs), or stay
**pure-CL and dependency-light** so `bin/cons` is trivial to ship? (My lean:
pure-CL core first; introduce Coalton only for a genuinely typed sub-part later.)

> **A:** Collections/data-structure choices are an **aion** concern (the
> functional-stdlib foundation), not cons's — decided in
> [`aion/docs/aion-vision.md` §8](../../aion/docs/aion-vision.md). `cons` stays
> lean and just consumes whatever aion (or plain Alexandria + hash-tables)
> provides; it doesn't pick a collections lib of its own.

## 2. The native dependency source — what's the model?

When `cons` grows its own resolver (to obsolete ql/ocicl), what's the **source
model**: a package **registry** (like crates.io), **git** refs, **OCI** artifacts
(as ocicl does), or several behind the protocol? What does the **lockfile** look
like, and what's the **version/constraint** scheme (SemVer? something CL-native)?

> **A:**

## 3. MVP scope — `cons new` only, or more in v1?

Ship **scaffolding first** and grow into deps/tasks, or aim for `new` + `add` +
`build` + `test` + `run` in the first cut? Which **templates** out of the gate —
`lib`, `cli`, `web` (hyperion), `agent` (praxeon)?

**Prior art to borrow from (the scaffolding wheel is already invented):**

- **cl-project** (fukamachi; the **40ants fork** is more actively maintained) —
  the closest existing thing to `cons new`. Template-directory driven: a
  `skeleton/` dir rendered through a templating pass → system + test system +
  README + `.gitignore` (+ CI/changelog/docs in the 40ants fork). Its layout is a
  de-facto standard for "what a CL project skeleton looks like." *Study this one.*
- **quickproject** (Zach Beane) — the minimal, dependency-light generator
  (`.asd`, `package.lisp`, one source file, README). Best base for the *lean*
  default template; less opinionated than cl-project.
- **Roswell `ros init <template>`** — worth stealing the **named-template
  registry** model (templates as resolvable, pluggable things) so `lib`/`cli`/
  `web`/`agent` map to sibling-provided templates via the dependency-source
  protocol, not hardcoded strings.
- **caveman2** (`make-project`, same skeleton mechanism as cl-project) and
  **Radiance** module scaffolding — the framework-specific skeleton shape for a
  `cons new web` (hyperion) template.

**Lean takeaway:** don't write a generator from scratch — adopt cl-project's
template-directory + rendering approach (or reimplement it but *match its skeleton
conventions* so generated projects look native), and adopt Roswell's named,
pluggable template registry. Keep generation and dep-management as separate
concerns internally (the way qlot/CLPM stay separate from the scaffolders); `cons`
is the front-end unifying both. Caveat: cl-project pulls a templating dep + a test
-framework opinion — for the truly-lean bootstrap, base the *default* template on
quickproject's zero-ceremony skeleton and reserve cl-project-style richness for the
framework templates.

> **A:**

## 4. Project manifest — reuse `.asd`, or a `cons` manifest?

Is the `.asd` the source of truth (cons reads/augments it), or is there a
`cons.lisp` / `cons.toml`-style manifest that *generates* the `.asd` and holds
cons-specific metadata (deps with versions, scripts, templates)?

> **A:**

## 5. CLI framework

`clingon` (modern, subcommands, from dnaeon), `unix-opts`, or a bespoke parser?
This shapes the whole command surface (`cons <subcommand> …`).

> **A:**

## 6. Roswell — ignore, or interop?

Roswell already does impl install/version-mgmt + script running. Does `cons`
**assume a system SBCL and ignore Roswell**, or interoperate (read its installs,
run its scripts)? And does `cons` manage Lisp *implementations* at all, or just
projects?

> **A:**

## 7. Distribution — how does someone get `cons` without `cons`?

`bin/cons` is a dumped image. Bootstrap path for a new user: a **curl-install
script**, **Homebrew tap**, **build-from-source**, prebuilt release binaries? (This
is the chicken-and-egg the tool has to answer for itself.)

> **A:**

## 8. Success at 3 / 6 / 12 months

`cons new` generating the sibling-quality scaffold? `cons add` over ocicl?
Self-hosting (`cons` managing cons/hyperion/praxeon)? A release binary? Deadlines?

> **A:**

## 9. What am I not asking?

> **A:**

> **Claude surfaces (2026-07-25) — a console-UX layer.** Colorful, *controllable* terminal
> I/O is missing and wanted: styled prompts/output plus a real **line reader** (history,
> in-line editing, completion) instead of bare `read-line`. Raised while building the
> mnemosyne `contacts` console example (`cons init`-scaffolded), whose loop uses `read-line`
> + hand-rolled ANSI. It would serve every `cli`-kind scaffold (§10), the planned `mnemo`
> console, and the §6 interactive Coalton REPL — so it is foundational, not cosmetic. Open:
> **wrap** an existing lib (`cl-readline` FFI to GNU readline, `linedit`, `replic`) vs. a
> small **SBCL-native** reader (no FFI, matches the SBCL-exclusive stance); and does it live
> in `cons` (tooling) or a tiny shared lib the CLI templates depend on? Lean: a dependency-
> light SBCL-native reader + an ANSI style helper, shipped with (or beside) the `cli` template.

## 10. Build targets — one template per project, or multiple named binaries?

Today a scaffolded project picks exactly **one** `--template` (`lib | cli | web |
agent`), which decides whether it's a pure library or an executable *and* of what
kind. That can't express a project that is *both* a library and a CLI, or one that
ships **several** binaries (a CLI + a web server), or that wants control over the
**binary name(s)**. Should the executable target(s) be decoupled from the template
— e.g. an explicit, repeatable target spec at `cons init` time — and what are the
**default binary-naming conventions** when the user doesn't name them?

> **Founder thinking (2026-07-25):** yes — the user identifies at project-gen time
> which target(s) to support, and `cons` scaffolds *all* of them at some minimal
> level, installing any related AI-conformance packs so the user (and their trusty
> AI) can build each out. Absent an explicit name at invocation time, follow
> **compiled-binary naming conventions** by kind:
> - `*-cli` — command-line interfaces
> - `*-desktop` — desktop apps
> - `*-lib` — `librarian`-generated DLLs (shared libraries)
> - `*-web` — web apps
> - the **root project name** — a pure CL/Coalton library
> - …(extend the table as new target kinds appear)
>
> So a target is `(kind [name])`: kind picks the scaffold + conformance pack + the
> default `*-<kind>` binary name; an optional name overrides it. A project may
> declare several. *(Implementation note: the current `%exec-p`/template gating in
> `src/init.lisp` — one `main` + one `bin` target per exec template — is the v0 of
> this; generalize it to a per-target list.)*
>
> The **`desktop`** kind's shell mechanism is decided in Hyperion
> [ADR-0008](../../hyperion/docs/adr/0008-desktop-shell-cl-native-webview.md): a
> CL-native, out-of-process OS webview over a local Hyperion server (not Tauri/Electron).
> The `cons desktop` scaffold emits that launcher wiring + the `~/.<appname>` config +
> the auto-update/installer glue.
>
> **The kinds ARE UX surfaces over one core** (Hyperion
> [ADR-0009](../../hyperion/docs/adr/0009-api-first-multi-ux.md)): `api` · `web` ·
> `desktop` · `cli` · `mobile`, each a thin adapter — the GitHub / GitHub-Desktop / `gh`
> pattern. This is the concrete payoff of "declare several targets": one domain core, and
> `cons` scaffolds each surface (a JSON data API, an HTMX web app, a webview desktop app, a
> CLI, a mobile client) against it. So a SaaS product is *born* multi-UX.

---

## Synthesis (Claude fills after your answers)
