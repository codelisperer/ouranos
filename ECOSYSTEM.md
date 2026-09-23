# Ouranos — the codelisperer ecosystem

*The shared brain. This file is **committed**, so it travels with the repo to every
machine and every fresh editor/agent session — the durable, cross-machine source of
truth. (Per-machine private notes live in `~/.claude`; they do **not** sync. Anything
that must survive a new machine goes here or in a project's `CLAUDE.md`.)*

Ouranos is a **monorepo of six co-evolving Common Lisp / Coalton core frameworks plus
hermes, a satellite leaf-lib** (the
[codelisperer](https://github.com/codelisperer) org). Named for the primordial sky —
**father of the Titans** (Hyperion, Mnemosyne, …), the source these all descend from.

## Thesis

**CL all the way down.** A reaction to **JVM/Node dependency sprawl** (the maintainer
loves Clojure the language, not its ecosystem weight). The frameworks are **few,
cohesive, co-versioned, house-owned**; only true external services sit behind thin
neutral protocols. Coalton is treated as a **first-class modern, typed Lisp** — a
typed core AI and humans can both reason about, without losing REPL-driven rapid
iteration. **SBCL-exclusive and optimizing for it** (as Coalton does) — embraced, not
hedged; `sb-ext:save-lisp-and-die`, threads, `--script`, `--dynamic-space-size` are
fair game. `sbcl --script` *is* our Babashka.

## The six core frameworks (+ hermes) + the one hard rule

**Strict dependency order (low → high), a DAG that ASDF enforces:**

```
aion → cons → mnemosyne → elenchon → hyperion → praxeon
```

**A framework to the LEFT must never depend on one to the RIGHT** (ASDF errors on
cycles). The order binds **core** systems; a repo may ship an **auxiliary** system
that reaches right (e.g. `praxeon/web → hyperion`, `elenchon/web → hyperion`,
`hyperion/testing → elenchon`) as long as the *system-level* graph stays acyclic.
Apps/examples combining frameworks live in the **highest** one they need.

| Dir | Framework | Role | Status |
|---|---|---|---|
| `aion/` | **Aion** (Αἰών) | functional stdlib + the native boundary — `aion/log`, `aion/csv`, `aion/uv` (libuv). Coalton-first collections core still to write | **mixed** — 758 checks (+60 opt-in `aion/uv`) |
| `cons/` | **cons** | dev tooling / project manager ("cargo for Lisp"): init/build/test/serve/run + deps | **alpha** — 420 checks; bootstrap seed + task runner work, the full CLI does not |
| `mnemosyne/` | **Mnemosyne** | data/persistence — Ecto-like, pluggable backends behind a neutral protocol | **alpha** — 397 checks; DDL-as-data + CL-DBI shell. Six design questions open |
| `elenchon/` | **Elenchon** (ἔλεγχος) | Requirements-Based Testing via Cause-Effect Graphs (pure CEG engine → min decision table ≈ MC/DC) | **design only** — 46 checks; typed CEG ADT + 5 ADRs, no reasoning engine yet |
| `hyperion/` | **Hyperion** | full-stack HTMX-first web framework (Spinneret, Parenscript, i18n, static, sessions, channel, typed interceptor pipeline) | **alpha** — 982 checks; the most built. Desktop app ships on three OSes |
| `praxeon/` | **Praxeon** | praxeological agentic-AI framework (actors/means/ends, provider-neutral LLM, workflow) | **alpha** — 111 checks; actor loop, translator, per-agent models, web/REST |

*Maturity and check counts are kept in step with the [README](README.md) status table —
if these two ever disagree, the README is the one a reader sees first. Counts come from
`sbcl --script scripts/verify-tree.lisp`, which fails on any suite that runs zero checks.*

Outside the line, **satellite leaf-libs** (depend leftward into the line + external libs; nothing
in the DAG depends on them):

| Dir | Framework | Role | Status |
|---|---|---|---|
| `hermes/` | **hermes** | **all the messaging an app needs** — one `deliver`/`send` protocol across every channel (email + SMS today; push/in-app next), plus other third-party services (payments) behind the same neutral-protocol doctrine | **alpha** — 434 checks; email/SMS shipped and payments (Stripe) shipped; push planned |
| `hades/` | **Hades** | **the OS ergonomics layer** — makes each platform's own features pleasant to use and porting between them a non-event, over aion's raw bindings. Two contracts kept distinct: **portable facades** where every supported OS has a real counterpart, and **platform-scoped packages** (`hades/windows`, …) where one does not. **Windows first**, being furthest from POSIX | **planned** — no code; chartered in [hades ADR-0001](hades/docs/adr/0001-charter.md), over the binding in [aion ADR-0003](aion/docs/adr/0003-windows-platform-binding.md) |

**Consolidation is REVERSED (settled).** Older hyperion docs said it "absorbs aion/cons
for now" — convenience under time pressure. The Ouranos monorepo settles it the other
way: the six core are conceptually distinct frameworks, each in its own top-level dir with its
own `.asd`, and **cons owns all project tooling** (hyperion is a *library*, not a CLI).
See hyperion `docs/adr/0007` (supersedes ADR-0001). Continue **migrating each piece to its
conceptual home** (CSV → aion, persistence → mnemosyne, RBT → elenchon); bias to **clean
design over convenience** unless the maintainer flags time pressure.

## Cross-cutting decisions (the log)

- **Monorepo (Ouranos)** — history-preserved subtree merge of the six; the originals
  are being retired. **A consuming app stays a SEPARATE repo** (proprietary).
- **New integrations are built in an app first, then promoted** (maintainer, 2026-09-16).
  Marketing and social-network integrations are built **in the consuming app**, layered so
  the reusable part can move into a framework once the whole thing is known to work
  together. Not a new rule — `hermes/CLAUDE.md` already said a consuming app builds ads and
  it is promoted — but it is now general, and it is stated here because **the tree drifted
  from it and nobody noticed**: an eight-platform survey, a design sketch and a two-network
  spike were built in `hermes` before any app had built the feature.
  The cost of that drift is specific: a framework vocabulary derived from one network's
  documentation rather than from a working consumer, which is the exact
  app-shape-versus-framework-shape failure the ads design note was written to prevent. The
  survey caught one instance in its own recommendation (only country-level geo ports; *age*,
  proposed as universal, does not).
  **The promotion direction also makes the refactor cheap and the reverse expensive** — code
  extracted from a working app has a caller proving its shape; code written into a framework
  first has only its author's model of one.
  **The maintainer's own reason is the sharper one, and it inverts the usual argument.**
  Separating framework from app concerns at the outset was the original intent; what changed
  it was the size of Meta's API and *the plethora of similar-but-different alternatives*. A
  field of near-identical platforms is normally the case **for** abstracting early — many
  consumers, one vocabulary. It is the opposite here, because the similarity is superficial:
  eight platforms that look alike diverge in exactly the details a neutral type must encode,
  so a vocabulary derived a priori from one of them is wrong for all of them and looks right
  until the second arrives. Measured, not assumed — of a proposed neutral core of *geo, age,
  language*, only country-level geo ported. Abstract after something works, not before.
- **Build with zero external tools** — `sbcl --dynamic-space-size 4096 --script
  bootstrap.lisp` builds `bin/cons` (WORKS today); the target is **`cons
  build/test/serve/run`** from one root build spec (IN PROGRESS — cons currently does
  `init`/`setup`/`conform`/`env`/`db-repl`/`db-url`/`template check`/`version`), plus a
  bare-machine `scripts/setup.{sh,ps1}` (PRESENT and working — see the root CLAUDE.md).
  Each framework now ships a root `cons.lisp` build spec driven by `cons <target>`,
  replacing the per-framework `Makefile`s (removed).
  **No make / just / nmake anywhere** (this killed the Windows Borland/nmake pain).
  `bin/cons` is a warm image, so ecosystem-aware Lisp scripting is instant.
- **System discovery = one ASDF `(:tree)` drop-in, not symlinks** — `bootstrap.lisp`
  writes `~/.config/common-lisp/source-registry.conf.d/50-ouranos.conf` covering every
  framework in the tree at once; this replaces the old per-project symlink into
  `~/quicklisp/local-projects` and `(push … asdf:*central-registry*)`. A **consuming repo**
  (e.g. a consuming app, a separate repo) onboards the same way — its own
  `NN-<name>.conf` `(:tree <its-root>)` drop-in (`conf.d` is additive, so cross-repo deps
  resolve). Generalizing that drop-in write is what `cons setup` does today.
- **Desktop apps = CL-native, out-of-process OS webview (not Tauri/Electron)** — a
  desktop app boots Hyperion on `127.0.0.1:<port>` in-process and `uiop:launch-program`s
  a small per-OS `webview.h` shim (WebView2/WKWebView/WebKitGTK) pointed at it;
  HTMX-over-HTTP means **no in-process JS↔native bridge** (which also dodges the webview
  main-thread/`ldb` hazard). Keeps *CL all the way down* — one small, unavoidable C shim,
  ~30–50 MB vs Electron's ~150–200. Hyperion owns the capability; `cons` scaffolds a
  `desktop` target; apps consume. Decided in **hyperion ADR-0008 (Provisional)**; the
  visual Coalton REPL is the first example. Owned up front: we reimplement Tauri's
  non-rendering glue (updater / installers / code-signing+notarization). **Tauri is the
  documented fallback** if time-to-ship outranks purity for a given app.
- **API-first, multi-UX: one core, many faces (not one UX)** — a product exposes web,
  desktop, CLI, native mobile, and a pure programmatic API, each a **thin adapter** (the
  GitHub / GitHub-Desktop / `gh` pattern). Two edge APIs over one domain core: an
  **application/hypermedia API** (HTML fragments, UI-shaped, un-versioned) for web +
  desktop-webview, and a **data API** (JSON, stable, versioned) for mobile/CLI/3rd-party/
  pure-API. The data contract is **Coalton-typed** (DTOs → generated JSON codecs + OpenAPI),
  extending the typed-core thesis to the edge. `cons` scaffolds each surface (cons-vision
  §10). Decided in **hyperion ADR-0009 (Provisional)**; the forcing function is the first
  real SaaS product. This is the payoff: **Hyperion apps are born multi-UX.**
- **The public repo starts from a fresh commit — the development history stays private**
  (decided 2026-08-04, issue #90). An audit before publication found client/product names in
  **188 diff lines and 12 commit messages**, spread from the first commit through the
  subtree-merged originals — including a merge commit whose title names a client org.
  Rewriting 217 commits would preserve provenance nobody reads, invalidate every SHA, and
  have to be redone immediately before the flip; leaving it would publish client names
  permanently, since history cannot be redacted after forks exist. So the public repo is
  **one initial commit of the reviewed tree** (`scripts/publish-public.sh`), and this repo
  remains private as the full historical record. Consequence to accept: no public
  provenance, blame, or contributor history before v0.1.0 — and the working tree must be
  clean at publication, because it *is* the published artifact.
- **Line endings = LF everywhere, enforced** — a repo-root `.gitattributes`
  (`* text=auto eol=lf`; `*.ps1/.bat/.cmd` keep CRLF; binaries marked `binary`)
  forces LF in every working tree on every OS, so `core.autocrlf=true` on Windows
  can't hand SBCL a CRLF-mangled source. Why it bites: a `FORMAT ~<newline>`
  continuation becomes an illegal `~<Return>` directive on a CRLF checkout, and
  SBCL's *compile-time* format-string parser raises it as a confusing
  "macroexpansion" error (it broke `praxeon/llm` then `praxeon/actor`, one file at
  a time, as commits reintroduced the pattern). Belt-and-suspenders: source also
  **avoids `FORMAT ~<newline>` continuations entirely** — fold the control string
  onto one line — so a stray CRLF (zip download, misconfigured editor) can't break
  the build regardless. Do not reintroduce either the setting gap or the pattern.
- **Native code: never on the LOAD path, and only the OS vendor's own toolchain on the
  BUILD path** — the two halves of why CL is harder to adopt on Windows than it should be.
  **(a) No grovel.** `cffi-grovel` compiles a C program at build time to read struct layouts
  and constants, which puts a **C toolchain on the load path of every dependent system** —
  so a Windows user typing `quickload` hits a C build they never asked for. `aion/uv` is
  therefore hand-written CFFI, not a fork of the grovel-based `cl-libuv`: libuv exports
  `uv_loop_size`/`uv_handle_size`/`uv_req_size` precisely so bindings need not know its
  layouts, and the hardcoded enum constants are **verified at load** against
  `uv_handle_type_name`, so an upstream reorder fails loudly instead of silently sizing a
  handle wrong. **(b) No MSYS2/MinGW.** When a C toolchain genuinely is needed — building
  libuv itself, an explicit opt-in step — it is the platform's **own first-party** compiler:
  Xcode CLT `cc` on macOS, the distro's gcc on Linux, **MSVC `cl.exe`** on Windows. Requiring
  a Unix-emulation layer is one more thing to acquire before anything works, and it is a tax
  Unix maintainers rarely feel. Together: **a C toolchain is never required to load anything,
  and where one is required to build something optional, it is the one the OS already
  ships.** This is also why `scripts/build-libuv.lisp` drives the compiler from Lisp with **no
  CMake, no autotools, no make** — 37 sources, one invocation, transcribed from libuv's
  `CMakeLists.txt`. Windows support for that script is the open half (#107). **The full libuv
  picture starts at [`aion/docs/adr/0002`](aion/docs/adr/0002-libuv-integration-strategy.md)**
  (strategy: why bind at all, what is never bound, sequencing, exit conditions), which
  cross-references the founding decisions in `aion/docs/uv-design.md` and the stream contract
  in `aion/docs/adr/0001`.
- **Native bindings follow the DAG; abstractions over them follow the domain** (decided
  2026-08-04, #117). The **thin, faithful 1:1 binding** of a native library lives in **aion**,
  because everything that wants a socket sits to aion's right: `cons` wants `uv_spawn` for
  build/test runs, `hermes` depends on `aion` *only* by design and will want its own HTTP
  client, and mnemosyne's Postgres wire is a named libuv target. Put TCP in hyperion and
  every one of those becomes a DAG violation — there is no version where transport lives at
  position 5. **Higher-level abstractions live wherever they naturally belong**: HTTP
  parsing and the request/response model in hyperion, subprocess orchestration in cons.
  The line is *binding vs. decision* — a binding's specification is the C library's own
  documentation; an abstraction makes a choice the C library does not make for you. It is
  the same line `aion/docs/coalton-story.md` already draws: **aion owns the boundary**,
  where an untyped external vocabulary becomes typed values. Granularity comes from
  **sub-systems, not from splitting the binding across frameworks** — `aion/uv` (loop, fs,
  timers, watch), `aion/uv/net` (streams, DNS), `aion/uv/process` (spawn, signals) — so a
  consumer takes only what it needs and the shared loop, handle registry, error decoding
  and thread-ownership rules are never duplicated. Accepted cost: **aion must now be
  correct on all three platforms**, and it is leftmost. Mitigated by these staying opt-in —
  core aion remains `coalton` + `alexandria`.
- **Windows is a first-class platform, and it lands in three homes** (decided 2026-08-10).
  The goal is not a COM library — it is that **open-source Lisp becomes first-class for rapid
  development on Windows**, which means the Windows-specific API surface generally: the SCM,
  the registry, security and elevation, the shell, the event log, with OLE/COM as one
  subsystem. Taking `cl-win32ole` as a dependency was the plan until it was *run* rather than
  surveyed: it did not load, its `CoInitialize` ran once on the loading thread (apartments are
  per-thread), and its `VARIANT` was sized 16 bytes — right on x86, wrong on x64 where it is
  24 — silently corrupting **every call with two or more arguments**. Written ourselves
  instead, and the split follows the #117 rule exactly: the **raw binding is `aion/windows`**
  (+ `/com`, `/service`, `/registry`, `/security`, `/shell`, opt-in and platform-exclusive —
  a new category, since `aion/uv` is opt-in but portable); the **ergonomic layer is Hades**
  (a satellite — only a consuming app depends on it, never a framework);
  **scaffolding is cons** (service install/uninstall). An **ADO backend belongs to mnemosyne**,
  not to any of them —
  ADO is an ordinary COM consumer needing no new FFI, so it is pure abstraction over
  `aion/windows/com`; its one novelty is that a COM object belongs to the apartment that
  created it, so an ADO connection has **thread affinity no other mnemosyne backend has**, and
  the pool must respect or marshal around it. Named `windows`, not `win64`: SBCL pushes
  `:win32` and not `:win64` on x86-64, so every conditional reads `#+win32` regardless, and no
  "Win64 API" exists to name. Two constraints worth knowing before they bite — **a service
  cannot automate Office** (Session 0 isolation; unsupported by Microsoft), and **a COM STA
  thread cannot also run a uv loop** (a message pump and an event loop cannot share a thread).
  Unlike `aion/uv`, **no C toolchain is ever needed** — the DLLs ship with the OS. Full
  reasoning in [aion ADR-0003](aion/docs/adr/0003-windows-platform-binding.md).
- **Hades is the OS ergonomics layer, not a Windows library** (decided 2026-08-10). Its job is
  to make each platform's own features pleasant *and* porting between them a non-event —
  Windows is merely where the pain concentrates today, being the one platform furthest from
  the POSIX world the rest of the tree assumes. That is **two contracts, and blurring them is
  the failure mode**: a **portable facade** (one API, per-OS implementations) is offered only
  where every supported OS has a genuine counterpart — run-at-login as a Run key / launchd
  plist / systemd user unit, known folders, single-instance locks, desktop notifications;
  whereas a feature with no counterpart elsewhere (Office automation, NT services, the macOS
  keychain) gets a **platform-scoped package** — `hades/windows`, `hades/darwin`,
  `hades/linux` — that **fails loudly off-platform and never silently no-ops**. A facade that
  quietly degrades is worse than no facade, because the defect surfaces on the OS nobody was
  testing. Structurally Hades mirrors aion: the core loads everywhere, only its platform
  packages are exclusive, and it depends leftward on `aion` alone per the satellite rule.
  **On hermes's exact terms**: nothing in the DAG depends on Hades, and the only thing that
  does is a client app — which depends on it *alongside* the frameworks, not through them.
  So `cons` calls `aion/windows/service` directly for install/uninstall and never links
  Hades; the image cons emits dispatches to an **app-supplied entry point**, and it is the app
  that reaches `hades/windows` for the service lifecycle
  ([ADR-0003 §3](aion/docs/adr/0003-windows-platform-binding.md)).
  **`bootstrap.lisp` compiles the host OS's platform package** — `hades/windows` on Windows,
  `hades/darwin` on macOS — rather than leaving it opt-in the way `aion/uv` is. Opt-in there
  was *bought* by the C-toolchain requirement; a Hades platform package has none (ADR-0003
  §8), so deferring it buys nothing and costs the one thing that matters: a subsystem that
  goes uncompiled on the only OS where it can be compiled at all. The same argument applies
  to `aion/windows`, and it is what makes its absence on a Windows run a **defect rather than
  a skip**.
- **AI attribution: where it matters, not in every commit** (decided 2026-08-04). No
  `Co-Authored-By` trailers for an assistant — they say nothing about *how* the work was
  done, and the public repo starts from a fresh commit (#90), so they would not survive to
  be read. Instead: one statement in the README pointing at
  [`docs/working-with-ai.md`](docs/working-with-ai.md), and a **`Provenance`** section on an
  ADR or design doc when the *process* shaped the outcome — a measurement that contradicted an
  assumption, a counterargument that landed, a lean abandoned. ADR-0011 is the worked
  example: a hunch turned into a benchmark found a 44 ms bug in our own request path, and the
  maintainer then rejected the ADR's *framing* rather than its answer, which is how `aion/uv`
  and #117 exist. **The maintainer owns every decision**; assisted research often shapes what
  the choices even are, and recording that is the honest and useful part. Binding on every
  assistant via [`AGENTS.md`](AGENTS.md) (always loaded), and propagated to consuming apps by
  `cons conform`, which carries its own copy of the spec.
- **Desktop packaging: declare the platform webview, carry only what we build, and build on
  the oldest supported base** (decided 2026-08-05, #94). Researched against Tauri and Wails
  rather than guessed. **(a) WebKitGTK is declared, not bundled.** Tauri splits by format —
  `.deb`/`.rpm` declare `libwebkit2gtk`, the AppImage bundles it at ~10 MB → ~100 MB — and the
  deciding factor is not size: a declared dependency means **the distro ships WebKit security
  patches**, whereas a bundled browser engine freezes every user at our build date and makes
  WebKit CVE response permanently ours. With no update pipeline yet (#76, #77) that is a
  liability we decline. The cost accepted: the AppImage is not quite "download one file and
  run." **(b) Build on Ubuntu 22.04** — glibc is forward- but not backward-compatible, so the
  build base *is* the oldest system the artifact runs on. 22.04 is Tauri's own baseline and
  the oldest still providing WebKitGTK 4.1. Building on a current release, as CI did, produced
  an artifact requiring a glibc almost nobody has. `verify-bundle.sh`'s `OURANOS_CLEANROOM_IMAGE`
  already anticipated this; the build base was the half nobody had decided.
- **Packaging tools are not build drivers** (decided 2026-08-05). The rule is *`sbcl --script`
  is the only **build driver*** — no make, no cmake, no nmake compiling our code. It does not
  forbid a tool that **assembles a finished artifact**: `appimagetool`, NSIS, `create-dmg`.
  The line is whether it compiles or packages. Each such tool is **pinned by version +
  checksum** (`appimagetool` 1.9.1 by sha256 in `scripts/versions.env`, on the same
  trust-on-first-use doctrine as `libuv.pin` and never a `continuous` tag). Written down
  because this is exactly the distinction that erodes into "well, cmake is just a build
  helper."
- **Third-party servers are an APPLICATION choice, never a framework dependency** (decided
  2026-08-05, #139). `hyperion` declares no HTTP backend; an app that wants Woo or Hunchentoot
  adds it itself. ADR-0011 said desktop bundles use Hunchentoot and it was never implemented,
  so `hyperion` still pulled `clack-handler-woo` → `libev` and Linux bundles died at startup.
  Swapping one permanent third-party server for another was rejected: **Hunchentoot is a
  stop-gap, and the destination is the native libuv server (#117), after which both are
  removed.** #117 is therefore **escalated** — it is the path off third-party servers
  entirely, not a nice-to-have. Anything built meanwhile should assume a third-party server is
  temporary and make that assumption cheap to withdraw.
- **Papers build without make** — each `<fw>/paper/` ships `build.sh` + `build.ps1`
  (latexmk under the hood), not a Makefile: LaTeX-on-Windows was the original make
  dealbreaker, and document tooling stays **out of cons's scope**.
- **Coalton is PINNED, not merely tracked** — Coalton is consumed as a **git checkout**
  of `coalton-lang/coalton` `main`, not a Quicklisp release. That is right (Coalton moves
  fast) but it means **every machine tracks upstream independently**, and a divergence in
  the *compiler* changes typechecking, representation, and optimization — surfacing as
  "works on mine, not on yours" with no visible cause. This machine had silently drifted
  18 days. Nothing short of vendoring makes two machines identical, but **divergence can
  be made detectable, and silent divergence is the real enemy**. So the repo declares its
  Coalton: **`coalton.pin`** at the root records the adopted SHA, and adoption is an
  ordinary commit that propagates through git like every other cross-machine fact — one
  machine adopts, rebuilds, runs every suite, updates the pin, commits; every other
  machine follows the pin. The checkout is located via
  `(asdf:system-source-directory :coalton)`, **never a hard-coded path** (that is what
  makes it work on Windows). Cadence, triage classes, and the adoption record live in
  [`docs/coalton-upstream.md`](docs/coalton-upstream.md); build-time enforcement is
  [issue #105](https://github.com/codelisperer/ouranos/issues/105). **Currently pinned:
  `7915fad0`** (adopted 2026-07-29; 9/9 systems, 506 checks, 0 failures).
- **Publishing (future)** — **Ultralisp** (rolling, fast) for reach + **ocicl** (OCI,
  pinned/reproducible) for consumption. Independent per-lib release, if ever needed,
  via **`git subtree split`** mirrors (the monorepo layout is already split-ready).
- **Data (Mnemosyne)** — **SQLite → Postgres → XTDB 2**, over **CL-DBI** (SQLite→PG is
  a connection change; XTDB 2 a later adapter). DuckDB is OLAP → an analytics backend
  later, not the transactional core. Embedded-first = zero-ops dev + on-prem.
- **Auth (a consuming app)** — session cookie (pages) + JWT (API) on **Lack middleware** for
  the MVP; migrate onto the typed interceptor pipeline later. `ironclad` for hashing.
- **Sessions** — `hyperion/session` (cookie identity + pluggable STORE, in-memory now)
  + `hyperion/channel` (broadcast log + per-reader cursors, fan-out). Mnemosyne will
  provide a DBI-backed session STORE. Two layers: HTTP session (hyperion) vs
  agent/conversation session (praxeon).
- **Fates naming family** — **Clotho** = the client view layer (Spinneret s-expr →
  `React.createElement`, Reagent-style, React **vendored** — no npm/JVM/asset-pipeline;
  a minifier, if ever needed, is a single Go/Rust binary, never Closure/JVM);
  **Atropos** = a *simple* start/stop lifecycle (ordered alloc/dealloc, Integrant-lite,
  not a reimplementation); **Lachesis** = TBD. All pair with **Spinneret**.
- **Hermes — external-service integrations** (a **satellite leaf lib**, not one of the six
  core frameworks) — true third-party services behind **thin neutral protocols** (the
  praxeon-LLM template). **Messaging shipped first**: neutral **email + SMS** — a
  `deliver`/`send` protocol with **SendGrid** + **Twilio** backends and a dev/log transport,
  plus **signature-verified inbound SMS** webhooks (`hermes/inbound`, HMAC-SHA1 on
  `X-Twilio-Signature`) — ported from a consuming app's `courier` prototype. **Payments**
  next (**Stripe**; then BTCPay/crypto, then a merchant-of-record for global tax). Owns only
  the provider protocol + client + webhook verify; persistence → mnemosyne, web endpoints →
  hyperion, both app-driven. Depends leftward only (`aion/log` + dexador, jzon, cl-base64,
  ironclad); never on hyperion/mnemosyne/praxeon. See `hermes/docs/roadmap.md`.
  **Status: email + SMS shipped; payments (Stripe) shipped (#47); push planned.**
- **Typed interceptor pipeline** (`hyperion/interceptor`, Coalton) — Pedestal-style,
  parametric over context; `execute` (pure) + `execute-effect` (effects at the edge).
  Serves HTTP and agentic contexts. Elise's crisis guardrail is the first real chain.
- **i18n** (`hyperion/i18n`) — per-request locale, drop-a-`<code>.json`-file to add a
  language; flat `:section/key`; `{named}` interpolation; a generator hook so praxeon
  can inject an LLM translator (machinery below, LLM above — respects dep order).
- **HTML → Spinneret importer** (`hyperion/import`, Plump) — port existing HTML to
  s-exprs; DOM-faithful round-trip.
- **Licensing** — audited: no strong copyleft; a few weak-copyleft **LLGPL** transitive
  deps (via `trivia`) — safe to use unmodified. Frameworks **MIT**; consuming apps proprietary.
- **Why MUMPS/globals, which looks like a retro choice and is not** — the motivation
  behind #108/#113/#114, recorded because it is the kind of "why" that evaporates between
  sessions and makes the work look arbitrary later. First met on a large contract at the
  **US Dept of Veterans Affairs**, whose EHR (VistA) runs on it. Two claims, one strong
  and one needing care:
  1. **Globals are the database equivalent of s-expressions.** A MUMPS global is a sparse,
     hierarchical, schema-free array addressed by a *list of subscripts* —
     `^Patient("123","name")`. It imposes no paradigm: relational, graph, key-value and
     document models are all things you *build on it*, exactly as cons cells are the
     substrate other data structures are built from. And because the key is a **list**,
     it meets Lisp with no impedance mismatch at all — no ORM, no row-to-object mapping.
     That affinity is the actual reason this is interesting, not nostalgia.
  2. **But it is a storage engine, not a whole database.** YottaDB gives real
     infrastructure — ACID, journalling, replication, locking — and *not* a query planner,
     secondary indexes, or constraints. Those are ours to build. So the honest framing is:
     the substrate is unusually well matched to Lisp, and Lisp is an unusually good
     language in which to build the missing layers. Anyone reading this later should hold
     both halves; "you can build any paradigm on it" is true of every low-level substrate,
     and the work always lives in the layers.
  Not obscure, either, which is worth saying because it reads as niche: MUMPS quietly runs
  a large share of healthcare (Epic, the biggest EHR vendor, sits on InterSystems) — an
  under-marketed incumbent rather than a revival. This also **answers mnemosyne's open
  neutrality question** (#108 blocker 2, #42): if globals are a first-class backend, the
  neutral protocol has to be *narrower* than SQL — get/put/traverse — with SQL layered
  above for the SQL backends, not the other way round.
- **First public release (#91, 2026-08-24)** — `0.1.0`, all seven frameworks public with
  honest per-framework maturity, explicitly **not** offering support. The decision that
  matters here is not the scope, it is the reframe that produced it: *"what does v0.1
  cover"* is a **goal** question wearing a scope question's clothes. Three goals were
  available — attract **users**, attract **contributors**, establish the **thesis** — and
  they are not simultaneous. They order by risk, and the order runs backwards from the
  instinct: **establishing the thesis is what makes contributors possible, and
  contributors are what make users survivable.** Launching straight at users, with seven
  frameworks and one maintainer, is the failure mode — people arrive with expectations, the
  issue queue goes stale, and a stale queue reads as abandonware, which is *worse than
  never launching*. So: aim at the thesis, badge the maturity honestly, and say plainly in
  the README that this is a working research stack rather than a supported product. That
  one paragraph is what keeps users from arriving uninvited.
  Consequences worth recording, because each looks like a corner cut if you do not know the
  goal: **CI (#87) and clean-machine bootstrap (#88) follow the launch rather than gate
  it** — they are evidence for *contributors*, and contributors are not what this release
  is aimed at. **`docs/launch/` publishes** — a project that names its own credibility gaps
  is harder to dismiss than one that hides them. And **history is not cleaned, it is
  abandoned**: `publish-public.sh` archives the tracked tree into a fresh `git init` and
  commits once, so the 237 commits carrying `Co-Authored-By` and the ~12 naming a client
  are simply never published. No rewrite, no invalidated SHAs, nothing to miss.

## Apps (not frameworks)

- **Elise** (`praxeon/examples/elise`) — reflective companion evolving into a
  **clinical-intake demoware** PoC: structured history-taking, a background **Scribe**
  agent holding assessment notes *never shown to the patient*, multilingual (translator
  agent, English pivot), **prominent DEMOWARE disclaimers** + crisis guardrail. App
  logic (participants, join flow, couples-therapy shape) stays in Elise, **not**
  framework-core.
- **ChatRBT** (`praxeon/examples/chat-rbt`) — Elenchon's motivating example: NL
  requirement → converse/disambiguate → Cause-Effect Graph → test cases. Hosted in
  praxeon (deps stay acyclic).
- **Consuming products** (separate repos, dogfood the frameworks): **a consuming app** (the
  first — a port of a prior Clojure/Kit web app; drives hyperion + mnemosyne + auth), a marketing
  site, and a writing-assistant app.

## How we work

- **Parallelism = git worktrees.** `git worktree add ../ouranos-<track> -b work/<track>`
  → open each as its own window/agent on its own branch, isolated; merge to `main` when
  green. The main checkout is the integration hub. (Claude Code's Agent tool also has
  `isolation: "worktree"`.)
- **Memory model** — this file + per-project `CLAUDE.md` (+ `docs/`) are the
  **cross-machine** brain (committed). `~/.claude` auto-memory is **machine-local,
  private** (personal motivation, gotchas). Durable → commit it here.
- **House style** — typed Coalton core + effectful CL/CLOS shell; pluggable backends
  behind neutral protocols; REPL-driven hot-reload; condition system over return codes;
  small pure functions, effects at the edges, ADTs over booleans; docs-as-handoff;
  package-per-module with `:local-nicknames`; 2-space indent, no trailing whitespace.

## Where to look next
- Each framework's `CLAUDE.md` (per-project detail); status → the
  [Roadmap board](https://github.com/orgs/codelisperer/projects/1) / issues
  (`label:pkg:<framework>`); narrative → `docs/wiki/Framework-<Name>.md`.
- `mnemosyne/docs/first-milestone.md` — the persistence layer a consuming app's auth needs.
- `hyperion/docs/interceptors-design.md`, `hyperion/docs/hyperion-vision.md` (universal
  views, the effect model, the client "flip").
- `bootstrap.lisp` (the seed) + the coming root `cons` build spec.
