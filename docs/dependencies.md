# Dependency manifest — Ouranos

The external dependency surface of the six core frameworks + **hermes** (the satellite
leaf-lib), so we can hold it to a **conscious
minimum** (the "few, cohesive, house-owned" thesis — see [`../ECOSYSTEM.md`](../ECOSYSTEM.md)).
**Checked, not asserted.** Run

```sh
sbcl --dynamic-space-size 4096 --script scripts/check-deps.lisp
```

It asks ASDF (not a regex) what every system in the tree actually depends on, compares
that to the tables below, and **exits 1 if anything in the code is missing from this
file**. `--list` prints the real set without checking. Last verified in sync
**2026-08-04**; the check is what keeps that date meaningful, since a hand-maintained
inventory of something that changes silently is a claim with a shelf life. `cons deps`
should call it.

Scope: the **frameworks** (this monorepo). Consuming products (a consuming app, the website) are
separate repos with their own — not counted here.

## Headline

- **25** ASDF systems defined across the six core frameworks + hermes (incl. `/tests`,
  `/cli`, aux) — hermes adds 2 (`hermes`, `hermes/tests`).
- **28** distinct **external** (third-party / Quicklisp) deps — 3 are foundation/test
  (`coalton`, `alexandria`, `fiveam`), **~13 are hyperion's web stack**, **3 are the
  mnemosyne data layer** (CL-DBI + two drivers), and **2 arrived with hermes** (`cl-base64`,
  `ironclad` — see the hermes section below; `ironclad` and `dexador` are reused by `hermes/blob`, which adds NO new external dep (#164)). One (`lass`) is example-only.
- **3** SBCL contribs (`sb-concurrency`, `sb-bsd-sockets`, `sb-posix` — ship with SBCL, zero install cost).
- Every framework **except hyperion and mnemosyne** (the two that inherently carry a
  surface — web, DB) runs on just **2–4** external libs (hermes, the integrations leaf, is
  the 4).

## External deps by role

| Dep | Role | Used by | Note |
|---|---|---|---|
| `coalton` | typed core (the language) | aion, elenchon, hyperion, mnemosyne, praxeon | Foundation, not "sprawl" — treated as the language (see below). |
| `alexandria` | CL utilities | all six core (not hermes) | De-facto CL stdlib; tiny, ubiquitous. |
| `fiveam` | test framework | all `*/tests` | **Test-only.** |
| `flexi-streams` | in-memory octet streams | `hyperion/tests` | **Test-only.** Hands `body-string` a body without a socket (#211). Already present transitively via clack; declared rather than assumed. |
| `clingon` | CLI arg parsing | cons/cli, hyperion/cli | hyperion/cli is being retired (ADR-0007) → collapses to **cons only**. |
| `com.inuoe.jzon` | JSON | hyperion, praxeon(+web,+web-search) | **One** JSON lib across the tree — no duplication. |
| `dexador` | HTTP client | **aion/http-client** (the shared client), hermes/blob | Wrapped once by `aion/http-client` (#202) and reached through it by hermes and praxeon; `hermes/blob` still calls it directly for streaming. **Shared** — and now shared through one client rather than three call styles. |
| `ironclad` | crypto (SHA-256, HMAC, Ed25519, **OS CSPRNG**) | hermes, hermes/blob, praxeon, **aion/random** | Twilio's inbound `X-Twilio-Signature`; blob checksums + S3 SigV4; **Ed25519 verification of signed spend grants** in `praxeon/ceiling` (#172); and since #95 the **OS random source** behind `aion/random` (`/dev/urandom`, `CryptGenRandom`) that mints session ids. **Shared** — arrived with hermes and reused each time rather than duplicated; #95 added a fourth consumer and **no new dependency**. |
| `clack` | HTTP server abstraction | hyperion | Web. |
| `woo` | HTTP server (Unix/macOS) | praxeon/web | Pulled by `clack-handler-woo`. **No framework declares it** — see the two rows below. |
| `hunchentoot` | HTTP server (Windows) | praxeon/web, hyperion examples | Pulled by `clack-handler-hunchentoot`. Likewise app-declared. |
| `clack-handler-woo` | Clack↔Woo adapter | praxeon/web (Unix) | The system an app actually declares; it pulls `woo`. Binds **libev at load time**, so an image that loads it cannot be shipped as a desktop bundle without carrying libev. |
| `clack-handler-hunchentoot` | Clack↔Hunchentoot adapter | praxeon/web (Windows), all three hyperion examples, **`praxeon/web/tests`** | Pure CL, every platform, nothing to install — which is why the desktop example uses it. `praxeon/web/tests` declares it because a suite that drives a real server is an *application* for the #139 rule: `praxeon/web` must keep declaring none, so its suite cannot live in `praxeon/tests` (#151). |
| `log4cl` | logging engine | `aion/log` (and via it: every framework) | The engine behind the `aion/log` facade. Confined to the opt-in `aion/log` system; core aion never pulls it. *Previously documented only in prose here — added as a row 2026-08-04 by `scripts/check-deps.lisp`.* |
| `lass` | CSS as s-expressions | `hyperion/examples/coalton-repl` | **Example-only** — no framework depends on it. Kept because the house CSS-DSL story (ADR-0003 §4) is dogfooded in the desktop demo. |
| `spinneret` | HTML as s-expressions | hyperion(+examples), praxeon/web | The HTML DSL — core to the thesis. |
| `parenscript` | CL → JavaScript | hyperion | No Node. |
| `quri` | URI parsing | hyperion, mnemosyne | Web; and percent-decoding a `DATABASE_URL` in `mnemosyne/url` (#147). Already in the tree, so mnemosyne adds no new external dep — and percent-decoding is not hand-rollable safely, since an escape may encode one byte of a multi-byte UTF-8 sequence. mnemosyne uses it for decoding ONLY: quri rejects `postgres://user@[::1]/db` outright, so the authority split is ours. |
| `bordeaux-threads` | portable threads | hyperion, praxeon | Session-store locks; the per-session spend ledger in `praxeon/ceiling` (#172). **See watch #2** (we're SBCL-only). |
| `3bmd` | Markdown → HTML | hyperion | `hyperion/markdown`. |
| `3bmd-ext-code-blocks` | Markdown code blocks | hyperion | Pairs with `3bmd`. |
| `plump` | HTML parsing | hyperion/import | The HTML→Spinneret importer — **aux system only** (core hyperion never pulls it). |
| `dbi` (CL-DBI) | DB-independent API | mnemosyne | The neutral SQL substrate — one API over SQLite + Postgres. |
| `dbd-postgres` | PostgreSQL **wire** driver | mnemosyne | Via `cl-postgres` (pure Lisp, no libpq); XTDB 2 rides it later. |
| `dbd-sqlite3` | SQLite driver | mnemosyne | Local-dev backend; via `cl-sqlite` (FFI to the system `libsqlite3`). |
| `cffi` | C FFI | `aion/uv` (aux only) | **New (2026-08-03).** The binding layer for libuv. Already present transitively (woo and cl-sqlite both pull it), so this makes an existing dependency explicit rather than adding a new one to the tree. Confined to the opt-in `aion/uv` and the Windows-only `aion/windows` (#170) — core aion stays `coalton` + `alexandria`. **`aion/windows` adds no new dependency at all**: `cffi` was already here, and its threads come from `sb-thread` rather than `bordeaux-threads`, since a portability shim over threads buys nothing in a system that is Windows-only inside an SBCL-only tree. |

### Shipped into generated projects

The table above lists what **this tree** depends on. This one lists what `cons init` puts
into **someone else's** project. They are different obligations to different people: a
dependency we take is a decision we made for ourselves, and a dependency we generate is one
the user inherits without choosing it, often without reading the `.asd` we wrote for them.

A row here does not mean the tree depends on it, and a row in the table above does not
excuse one here. `fiveam` is in both and for different reasons.

| dependency | templates that ship it | notes |
|---|---|---|
| `fiveam` | agent, cli, lib, web | The generated `<name>/tests` system. Written as a literal in the `.asd` template, **not** in any `template.lisp` manifest, so a check that read the manifests would never see it. Every scaffolded project gets a test system and therefore this. |
| `cons/env` | agent, cli, web | In-tree, not third-party — listed because the generated project depends on Ouranos being available, which is a fact its author needs. `lib` does not ship it. |
| `clingon` | cli | CLI argument parsing for the generated command-line entry point. |
| `praxeon` | agent | In-tree. |
| `hyperion` | web | In-tree. |
| `spinneret` | web | HTML as s-expressions, in the generated page. |
| `clack-handler-hunchentoot` | web | The Clack adapter the generated server starts. Pure CL on every platform, which is why the templates use it rather than `clack-handler-woo`. |

**This table is checked, not maintained by hand.** `cons/tests/init-tests.lisp` scaffolds
each template into a temporary directory, reads the `.asd` the generator actually wrote, and
fails if a dependency in it is missing here or if a row here names a template that no longer
ships it. It reads the emitted file rather than `template.lisp` because the manifest only
says what we intended to substitute; the generated file says what a user got. That is how
`fiveam` was found (#361).

### Native (non-Lisp) dependencies

Tracked separately because they fail differently: a missing Lisp system is a clear ASDF
error, a missing shared library is a loader failure at some unrelated later moment.

| Dep | Role | Used by | How it is obtained |
|---|---|---|---|
| `libuv` 1.52.1 | event loop, async/sync fs, timers, fs watching | `aion/uv` (opt-in) | **Built from source** by `scripts/build-libuv.lisp` against the root `libuv.pin` (version + sha256 + url). Not a distro package: see below. |
| `libsqlite3` | SQLite engine | mnemosyne, via `cl-sqlite` | The system's copy, whatever it is. **Unpinned and unbundled** — the same exposure ADR-0011 found with libev, still outstanding (#94). Vendoring it would make it carried automatically, since the bundler carries what this tree builds (ADR-0013). |
| `libev` | Woo's event loop | only an app that declares `clack-handler-woo` | **No longer reachable from a framework** (#139): hyperion used to declare the Woo handler, so every image loading hyperion held an open libev handle and every Linux desktop bundle died at startup. Now it is an application's deliberate choice, and an application that makes it owns bundling it. |
| OpenSSL (via `cl+ssl`) | TLS for a Postgres connection | only an app that declares `cl+ssl` | **Deliberately NOT a mnemosyne dependency** (#146), on exactly the reasoning of the row above. `cl-postgres` resolves cl+ssl at *connect* time rather than at load time, so an application that needs `sslmode=require` adds `cl+ssl` itself and mnemosyne keeps OpenSSL off the load path of every image that touches a database — including desktop bundles. `mnemosyne/conn` degrades `prefer` to plaintext with a warning when it is absent, and REFUSES `require`/`verify-*` rather than downgrading silently. |

**Why libuv is built rather than installed.** Three reasons, in order of how much they
cost when ignored: (1) ADR-0011 — Woo bound libev at load time and every Linux/macOS
desktop bundle died on a clean machine, because a native dep you do not build is one you
cannot bundle; (2) one version everywhere, instead of Ubuntu's 1.51.0 and whatever brew
and MSYS2 carry; (3) it is the same artifact CI publishes and installers will ship (#94).
The build needs only a C compiler — no cmake, no make — so the "no external build tools"
rule survives intact.

### SBCL contrib (free — ships with SBCL)
| Dep | Role | Used by |
|---|---|---|
| `sb-concurrency` | thread-safe mailbox | praxeon/web (SSE channel) |
| `sb-bsd-sockets` | port probing / socket checks | `hyperion/desktop` (localhost lifecycle) |
| `sb-posix` | `mkdir` — atomic create-or-fail | `cons` (`cons/tempdir`, **Unix only**: `(:feature :unix …)`) |

`sb-posix` is there for exactly one call. A scratch directory must be **created**, never
chosen-then-written-to, and `mkdir` is the only atomic create-or-fail CL exposes — it refuses
a path already occupied, **including by a symlink**, which is the attack (#204). The guard is
on `:unix` rather than on `:sbcl` because SBCL's Windows `sb-posix` is thinner, and naming a
symbol it lacks is a READ error rather than a run-time one.

## Per-framework external footprint (runtime; excludes `fiveam` test dep + the internal DAG)

| Framework | External deps | Count |
|---|---|---|
| **aion** | coalton, alexandria (+ `cffi` and native libuv in the opt-in `aion/uv`; log4cl via `aion/log`, which the opt-in `aion/pool` now depends on so a job that signals cannot be discarded in silence (#117 M2); **ironclad + bordeaux-threads in the opt-in `aion/random`, which `aion/clock` now uses for the non-timestamp bits of a v6 id (#95)**; `aion/csv` has none; **`aion/secret` has none and is Coalton-free — `aion/secret/types` is the opt-in Coalton view, #209**; **`aion/dynamic` has none** — it carries declared dynamic bindings across a thread boundary and owns no threading, #430) | 2 core |
| **cons** | alexandria (+ clingon in `cons/cli`; `sb-posix` on Unix, an SBCL contrib, for `mkdir` in `cons/tempdir` — #204; intra-tree `aion/secret`, which has **no** external deps and **no** Coalton — #209) | 2 |
| **mnemosyne** | coalton, alexandria, dbi, dbd-postgres, dbd-sqlite3, quri (+ `aion/log` → log4cl; `aion/clock` → `aion/random` → **ironclad** (#95, pure CL: load time only, no native dep); dexador + ironclad in the opt-in `hermes/blob`) | 6 core (+ transitive `cl-postgres` = PG wire, `sqlite`/cl-sqlite = SQLite FFI) |
| **elenchon** | coalton, alexandria | 2 |
| **praxeon** | coalton, alexandria, dexador, com.inuoe.jzon, ironclad, bordeaux-threads (+ `aion/log` → log4cl, `aion/interceptor` → none, `cons` → none; spinneret, sb-concurrency, woo\|hunchentoot in `praxeon/web`) | ~6 core |
| **hyperion** | coalton, alexandria, bordeaux-threads, clack, spinneret, parenscript, quri, com.inuoe.jzon, 3bmd, 3bmd-ext-code-blocks, woo\|hunchentoot (+ `aion/random` → **ironclad** for session ids (#95); `aion/log` → log4cl; plump in `/import`, clingon in `/cli`; `aion/dynamic` in core so the request context and request id cross into a thread the request spawns (#430 -- **no new external dep**); `aion/platform` in `/desktop` for the one resolver that answers where the running executable lives (#335 -- **no new external dep**, and it REPLACES a second copy of that walk rather than adding one); `aion/signature` + `aion/platform` + `aion/http-client` + `cl-base64` in the opt-in `hyperion/update` (#76; dexador was dropped from that line in #332 once #223 moved the binary-body contract into `aion/http-client` — it arrives through the shared client now, declared where it is used) -- **no new external dep**, every one already in the tree; `cl-base64` because a detached `.sig` is base64 TEXT, which is the same reason `aion/signature` carries it) | ~11 (+ `sb-bsd-sockets`, an SBCL **contrib**, for the #238 port preflight — previously reaching core only transitively via clack/usocket and now declared) |
| **hermes** (satellite) | dexador, com.inuoe.jzon, cl-base64, ironclad (+ `aion/log` → log4cl **and coalton**; `hermes/payments` adds coalton for the event vocabulary, plus `aion/secret/types` for opaque credentials (#209) — NO new external dep either way) | 4 |

The web framework and the data layer carry the surface; everything else is lean by construction.

**`aion/secret` is deliberately the counter-example to the paragraph below.** It is the second
system in the tree (after `aion/csv`) declared `:depends-on ()`, and for the same reason: `cons`
consumes it, and `cons`'s core stays Coalton-free and trivial to install. Credentials are held
opaquely by `mnemosyne` (the DB password), `hermes/payments` (API key + webhook secret) and
`cons` (the `db-repl` password) — three frameworks, one mechanism, zero new external libraries.
The Coalton half lives in the separate `aion/secret/types`, which only the frameworks that
already compile Coalton ever load.

**One consequence worth stating plainly:** `aion/log` now depends on **coalton**, because its
Level/Layout/Event core is Coalton (see [`../aion/docs/coalton-story.md`](../aion/docs/coalton-story.md)).
Five of the seven already depended on Coalton directly; **hermes did not**, and it consumes
`aion/log`, so the satellite leaf-lib now pulls Coalton transitively. No new *external*
library — Coalton was already in the tree — only a first-load compile cost if hermes is ever
built alone.

That is early arrival rather than unwanted weight: **hermes's own abstractions are headed for
Coalton types too** (the neutral delivery protocol and the payments core are exactly the
"untyped external vocabulary at a boundary" the thesis describes — provider status strings,
webhook event kinds, currency and amount). Every framework in the tree will depend on Coalton
directly in the end; hermes simply gets there through its logger first.

## Watch list — conscious-minimum opportunities

1. **Server backend = 2 libs, 1 role.** `woo` (Unix) + `hunchentoot` (Windows) sit behind
   hyperion's neutral server protocol. Fine as-is, but it's one capability — revisit if the
   Windows/`hunchentoot` half isn't earning its keep.
2. **`bordeaux-threads` vs SBCL-native.** hyperion uses `bordeaux-threads` (a portability
   layer) while praxeon/web uses `sb-concurrency` directly. We're **SBCL-exclusive**, so the
   portability layer is arguably droppable — standardizing on `sb-thread`/`sb-concurrency`
   would remove one external dep. **Candidate to prune.**
3. **Markdown pair.** `3bmd` + `3bmd-ext-code-blocks` are core-hyperion today; if markdown
   isn't universally needed, moving `hyperion/markdown` to an aux system keeps the core
   lighter (as `hyperion/import`/`plump` already does).
4. **`plump`** is already isolated to the `hyperion/import` aux system — good; the pattern to
   keep for optional capabilities.
5. **`clingon` collapses to one place** once `hyperion/cli` is retired (ADR-0007).
6. **JSON is already singular** (`com.inuoe.jzon`) — keep it that way; reject any second JSON lib.
7. **mnemosyne data layer (landed).** **CL-DBI** + `dbd-postgres` (PG **wire** via
   `cl-postgres`, no libpq) + `dbd-sqlite3` (local dev). The neutral protocol holds — the
   drivers sit behind `mnemosyne/backend` (typed) + `mnemosyne/conn` (IO), no driver shape
   leaks above it. Note SQLite pulls a **system C lib** (`libsqlite3`, via `cl-sqlite`'s FFI);
   Postgres is pure-wire (zero C). Keep it at these two drivers + XTDB-2-over-PG-wire; reject a
   third SQL client.

## On Coalton

`coalton` is counted above for completeness but is treated as **the language**, not a
dependency to minimize — it's the typed core the whole ecosystem is built on, deliberately
SBCL-optimized. The minimization goal targets the *other* libraries.

## Versions (pinned) — snapshot 2026-07-22

Environment:

- **SBCL** `2.6.5-85913ede1`
- **Quicklisp dist** `2026-01-01` — **the reproducibility anchor**: pinning this one line
  reproduces every version below. All deps (incl. Coalton) currently resolve from Quicklisp,
  *not* the `~/common-lisp` Coalton checkout the old setup scripts cloned.
- ⚠️ **Ultralisp dist** `20250820215500` is **also enabled** — a *rolling* dist (not
  reproducible), and the source of the past `fset`/`named-readtables` fork-shadowing breakage.
  Recommend **disabling it (or pinning)** so Quicklisp `2026-01-01` is the single source.

| Dep | Pinned release (Quicklisp) | Version |
|---|---|---|
| `coalton` | `coalton-20260101-git` | 0.0.1 |
| `alexandria` | `alexandria-20241012-git` | 1.0.1 |
| `bordeaux-threads` | `bordeaux-threads-v0.9.4` | 0.9.4 |
| `clack` | `clack-20250622-git` | 2.1.0 |
| `clingon` | `clingon-20260101-git` | 0.5.0 |
| `dbi` / `dbd-postgres` / `dbd-sqlite3` | `cl-dbi-20260101-git` | 0.11.1 |
| `cl-postgres` (PG wire; transitive) | `postmodern-20260101-git` | 1.33.11 |
| `sqlite` (cl-sqlite; transitive) | `cl-sqlite-20190813-git` | 0.2.1 |
| `com.inuoe.jzon` | `jzon-v1.1.4` | 1.1.4 |
| `dexador` | `dexador-20260101-git` | 0.9.15 |
| `fiveam` | `fiveam-20241012-git` | 1.4.3 |
| `hunchentoot` | `hunchentoot-v1.3.1` | 1.3.1 |
| `parenscript` | `parenscript-20250622-git` | — |
| `plump` | `plump-20260101-git` | 2.0.0 |
| `quri` | `quri-20260101-git` | 0.7.0 |
| `spinneret` | `spinneret-20260101-git` | 3.0 |
| `woo` | `woo-20241012-git` | 0.12.0 |
| `3bmd` / `3bmd-ext-code-blocks` | `3bmd-20250622-git` | — |

`sb-concurrency` ships with SBCL `2.6.5`.

**Reproducibility (hardening).** The pin today *is* the Quicklisp dist date above. The plan
(see [`../ECOSYSTEM.md`](../ECOSYSTEM.md)) is to lock it explicitly — a Quicklisp dist pin in
bootstrap/setup, or move to **ocicl** with a committed lockfile — and to pin **Coalton** to a
known-good release given the Ultralisp history.

## hermes (the satellite leaf lib — outside the core DAG)

Added 2026-07-26. hermes (external integrations: email + SMS delivery/receive) is a leaf that
depends only leftward + external — never on hyperion/mnemosyne/praxeon. Its external surface:

| Dep | Role | Note |
|---|---|---|
| `dexador` | HTTP client | **Shared** — already praxeon's; the one outbound effect. |
| `com.inuoe.jzon` | JSON | **Shared** — the one JSON lib across the tree. |
| `cl-base64` | Base64 | **New.** Twilio Basic auth + inbound-signature encoding. **Also `aion/signature` (#208)**, which moves it LEFTMOST: keys travel as text in CI secrets and manifests, and one canonical encoding beats each consumer choosing. Already loaded wherever ironclad is, so this widens where it is used rather than what is pulled in. |
| `ironclad` | crypto (HMAC-SHA1) | **New.** Verifies the inbound `X-Twilio-Signature`. |
| `aion/log` (→ `log4cl`) | logging facade | Framework logging across the tree: hyperion (request id + one line per request), mnemosyne (SQL/migrations at :debug), praxeon (LLM metadata at :debug), hermes (send attempts/failures). One shared facade so an app configures logging once — see [`logging.md`](logging.md). |

So hermes adds **two** genuinely new external libs (`cl-base64`, `ironclad`) plus the
`aion/log`→`log4cl` chain. The headline counts above include it.

## Vendored browser assets (not ASDF dependencies)

Added 2026-08-05 (#123). A third category, listed here because it is a dependency surface
even though nothing in the `.asd` files mentions it and `scripts/check-deps.lisp` cannot
see it.

Before this, every example and `praxeon/src/web.lisp` fetched htmx, Alpine and Bulma from
unpkg/jsdelivr **at run time**. That is a runtime dependency on a third party, pinned by URL
only — and it made the Coalton REPL *desktop app*, which we ship as an installer, render
nothing without internet. The bytes now live in `hyperion/assets/vendor/` and are compiled
**into the image** by the opt-in `hyperion/assets` system.

| Asset | Version | Size | Licence |
|---|---|---|---|
| htmx | 1.9.12 | 48K | Zero-Clause BSD |
| Alpine.js | 3.14.1 | 44K | MIT |
| Bulma | 1.0.4 | 678K | MIT |

- **Pinned by version + sha256** in [`hyperion/assets/vendor/ASSETS.pin`](../hyperion/assets/vendor/ASSETS.pin),
  same doctrine as `libuv.pin`. `scripts/check-assets.lisp` proves the files on disk still
  match; the `hyperion/assets` suite proves the bytes *in the image* do.
- **Embedded, not shipped beside the binary.** ADR-0013 established that
  `asdf:system-source-directory` resolves to the build machine's path in a dumped image. A
  native library must therefore be copied next to the executable; a small text asset can
  simply be a literal in the fasl, and then there is no path to get wrong.
- **Opt-in**, so an app shipping its own CSS pays nothing.
- **Bulma is 1.0.4, not the 0.9.4 the examples used**, and the reason is theming rather
  than currency: 0.9.4 has zero CSS custom properties, so recolouring it requires dart-sass
  (Node). 1.x exposes 1412, so `hyperion/assets:theme` generates a palette as plain text
  with no build step. Verified non-breaking: all 49 Bulma classes used in this tree exist
  in 1.0.4.
- **No new ASDF dependency.** `ironclad` appears against `hyperion/assets/tests` above only
  because the suite hashes the embedded bytes; the shipped system uses no crypto.

## Regenerating

Hand-verified snapshot: the dependency graph from the `.asd` files, versions from `ql-dist`
(release prefix + ASDF `component-version`). This should become **`cons deps`** (list /
quantify / diff / pin the dependency surface) so it stays current automatically.
