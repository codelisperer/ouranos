# Research: Desktop packaging — Ceramic vs Tauri (+ SBCL↔Rust interop)

*Researched 2026-07-16. Sources cited inline; unverified items flagged.*

## Recommendation

> **Do not build on Ceramic (archived, Electron 5.0.2, broken on modern
> SBCL/macOS). For a desktop shell, adopt the CL-native system-webview path
> first: `clogframe` (or `cl-webview`) pointing at the in-process Hyperion
> localhost server.** Keep **Tauri** as a *secondary, heavier* option for teams
> that want its native tooling — but know it adds a Rust toolchain and gives
> Hyperion almost nothing beyond a window (its IPC/Rust value-add is bypassed
> when the webview just talks HTTP to SBCL). **Do not pursue deep SBCL↔Rust FFI**
> for this; a process boundary is the correct interop model.

**Why this ordering:** the desktop surface is nearly *free* if the web surface
exists — it is the web renderer in a native window. The only decision is *which
window*, and the option that best preserves Hyperion's live-image / hot-reload
thesis is the one that keeps the **CL image in-process** with the UI and points a
webview at `http://127.0.0.1:PORT/`.

---

## 1. Ceramic — archived legacy, but architecturally instructive

- **Status: dead.** [ceramic/ceramic](https://github.com/ceramic/ceramic) (Fernando
  Borretti / eudoxia0) last shipped code **2019-10-13** and was **archived
  read-only on 2025-10-21** (382 stars, 432 commits, no releases — Quicklisp-only).
- **`rabbibotton/ceramic` does not exist** (404) — that premise was wrong. David
  Botton's real repo is [`elect`](https://github.com/rabbibotton/elect) (last
  touched 2024-07-11, a README edit) — an *unmodified-Ceramic + CLOG demo*, not a
  fork. His engineered desktop path is **CLOG Frame**, not Electron.
- **Electron 5.0.2 hardcoded** (`src/setup.lisp`), released May 2019 (Chromium 73),
  **x64/ia32 only** — no Apple-Silicon arm64 (Rosetta at best). Download URL still
  points at the dead `atom/electron` repo path, so a clean `setup` generally fails
  today. Corroborated by [lisp-journey (Dec 2024)](https://lisp-journey.gitlab.io/blog/three-web-views-for-common-lisp--cross-platform-guis/)
  and [vindarel (Feb 2024)](https://dev.to/vindarel/common-lisp-gui-with-electron-how-to-28fj),
  both of which say "broken out of the box; bypass it."

### How it embeds Electron (worth stealing the pattern)

SBCL and Electron are **two separate OS processes** — no in-process V8, no native
binding:

1. `ceramic:setup` downloads a prebuilt Electron into `~/.ceramic/`, strips the
   default app, injects Ceramic's own `main.js` + `ws` module.
2. `ceramic:start` stands up a **WebSocket server** (`remote-js`) on localhost and
   spawns Electron, passing it the WS address/port as argv.
3. Electron's `main.js` connects back as a WS **client**; every Ceramic op is a
   **string of JavaScript** shipped over the socket, where `main.js` does
   `eval(js)`. Async = fire-and-forget; sync wraps in `Ceramic.syncEval(uuid, fn)`
   and the JS side returns `JSON.stringify({id, result})`, which Lisp matches on
   UUID to unblock the caller.
4. It runs **no HTTP server** — `make-window :url "http://localhost:PORT/"` points
   at *any* server you started in the same image (or any remote URL). Bundling
   (`ceramic:bundle`) is a separate, optional concern only for shipping.

This "separate SBCL server + webview pointed at localhost + JS-over-socket
control" shape is *exactly* Hyperion's model. The idea is sound; the
implementation is abandoned.

**CL implementations:** effectively **SBCL only** (CI tested `sbcl-bin`; no
version floor documented — inferred). OS: macOS/Linux/Windows.

---

## 2. Tauri v2 — viable, but works against its own grain here

- **[Tauri 2.0 stable, 2024-10-02](https://v2.tauri.app/blog/tauri-20/).** Rust
  **Core** process hosts the OS webview (WebView2 / WKWebView / WebKitGTK via
  `wry`); small binaries because the webview isn't bundled.
- **Embedding an SBCL server = the [sidecar](https://v2.tauri.app/develop/sidecar/)
  pattern:** bundle the SBCL executable as an `externalBin` (per-platform
  target-triple suffix required, e.g. `-aarch64-apple-darwin`), have it bind
  `127.0.0.1:PORT`, and point the whole webview at it via `frontendDist = URL`
  ([config ref](https://v2.tauri.app/reference/config/)). This is a **real, used
  pattern** for Python/FastAPI, Go, Bun/Deno backends
  ([dieharders example](https://github.com/dieharders/example-tauri-v2-python-server-sidecar),
  [Evil Martians](https://evilmartians.com/chronicles/making-desktop-apps-with-revved-up-potential-rust-tauri-sidecar)).
- **No CL/SBCL precedent exists — you'd be first.** The mechanism is
  language-agnostic, so it's low *technical* risk, but greenfield.

### Four sourced risks before committing to Tauri

1. **macOS notarization is broken with *any* sidecar** — [tauri#11992](https://github.com/tauri-apps/tauri/issues/11992)
   (open as of research): adding `externalBin` fails notarization with "signature
   of the binary is invalid." **Material risk for shipping on macOS.** Re-check
   status before relying on it.
2. **Startup race** — the webview loads before SBCL is ready. No turnkey
   "wait-for-server" in Tauri; you build it (server prints ready/port on stdout,
   Rust blocks until received).
3. **Dynamic port** — hardcoded ports collide; robust pattern binds `127.0.0.1:0`
   and passes the OS-assigned port to the sidecar via env. **SBCL must accept a
   `PORT` arg.**
4. **Windows AV false-positives** on a localhost-server sidecar; mitigated only by
   an **EV code-signing cert**.

**Maintainers' own view:** replacing Tauri's frontend delivery with an external
HTTP server "removes the entire benefit of using Tauri" ([discussion #6529](https://github.com/tauri-apps/tauri/discussions/6529)).
For Hyperion the trade is deliberate (Tauri = window + packaging only), but be
clear-eyed that its Rust/IPC layer buys you little in this config.

- **`save-lisp-and-die :executable t`** gives the single self-contained binary to
  bundle (~30–60 MB; `:compression t` shrinks the core). Single-process, so the
  `child.kill()` lifecycle is cleaner than PyInstaller's bootloader — **unverified
  for SBCL specifically.**
- **Tauri mobile (iOS/Android) is real in v2 but does NOT help** — it will not run
  an SBCL sidecar (no SBCL on mobile; sandboxes forbid spawning arbitrary
  binaries). Tauri's mobile advantage is only an advantage *if you leave SBCL
  behind*.

---

## 3. The CL-native middle path (recommended first step)

Every option reduces to "keep SBCL serving localhost, open a webview at it." The
lightest shipping-today choices, from Lisp:

| Option | What it is | Maturity | Notes |
|---|---|---|---|
| **CLOG Frame** (`clogframe`) | ~197 KB C++ `webview.h` wrapper; `uiop:launch-program "clogframe" title port w h` | **Shipping, battle-tested** (CLOG Builder) | Cross-platform; works with **any** CL server, not just CLOG. Best pragmatic choice today. [repo](https://github.com/rabbibotton/clog/tree/main/clogframe) |
| **cl-webview** | In-process CFFI to [`webview/webview`](https://github.com/webview/webview) | **Early** (~3 stars) | Cleaner architecture; but single-window + no clean teardown (upstream webview issues). Long-term bet if fixed. [repo](https://github.com/li-yiyang/cl-webview) |
| **cl-webkit** | WebKitGTK bindings | Mature but **Linux-only** | Engine under Nyxt. No macOS/Windows. [repo](https://github.com/joachifm/cl-webkit) |
| **Electron directly** | Spawn SBCL as child from `main.js`, point `BrowserWindow` at localhost | Electron itself is most mature | ~150 MB bundle; no maintained CL glue (Ceramic *was* that glue). |

**Shipped CL-desktop precedent:** **Neomacs** (Ceramic/Electron), **Nyxt**
(cl-webkit — and **Nyxt 4.0 is adding an Electron renderer**, a signal that
WebKitGTK-only was a portability dead-end), **CLOG Builder** (CLOG Frame).

---

## 4. SBCL ↔ Rust interop — how far it can go

- **SBCL → Rust `cdylib` (C ABI): solved, production-viable.** It's "CFFI calls
  C." Hazards are generic C-ABI ones: **Rust panics across the boundary are UB**
  (wrap bodies in `catch_unwind` or use `extern "C-unwind"`); `#[repr(C)]`
  mandatory; **symmetric alloc/free via opaque handles** (CFFI's GC won't free
  Rust allocations); CFFI `:string` is dynamic-extent (use-after-free if Rust
  stashes the pointer). [veer66 worked example, 2021](https://dev.to/veer66/calling-rust-from-common-lisp-45c5).
- **Rust → SBCL: possible since ~2022 but sharp.** Needs a **custom SBCL build**
  (`libsbcl.so`, ≥ 2.1.11) with `sb-ext:save-lisp-and-die :callable-exports` +
  `sb-alien:define-alien-callable`. GC relocation forces **fixnum-handle
  indirection** ([mstmetent, 2022](https://mstmetent.blogspot.com/2022/04/using-lisp-libraries-from-other.html)).
  The killer for Rust specifically: SBCL **"cannot run Lisp code in foreign
  threads"** and has no clean deinit — which collides head-on with Tokio/Rayon
  multithreading. [`sbcl-librarian`](https://github.com/quil-lang/sbcl-librarian)
  (Rigetti) is the one maintained abstraction.
- **No mature off-the-shelf CL↔Rust generator exists.** (Beware name collisions:
  `rust_lisp`, `LIR` etc. are *Lisp interpreters written in Rust* — unrelated.)

**Verdict:** in-process FFI *only* for **Lisp→Rust** (pull a Rust crate — crypto,
parsing, perf — into the SBCL host; this matches Hyperion's shape). For any
**Rust-hosts-Lisp** scenario, use a **process boundary** (stdio/socket/HTTP).
Corollary: if Hyperion ever ships on Tauri, the **sidecar (process-boundary)
model is also the correct interop model** — deep FFI would buy nothing.

---

## Roadmap implications

- **Now / near-term:** add a **generic desktop shell** capability — a
  `hyperion:open-desktop-window` that launches `clogframe` (default) or
  `cl-webview` against the in-process server. Keep it a *pluggable backend behind
  a neutral protocol*, same as the web-server backend. **Small, high-leverage,
  preserves hot-reload.**
- **Optional / later:** a Tauri packaging target for teams wanting native
  tooling — but gate it behind the four risks above (esp. macOS notarization
  #11992) and treat it as "window + installer," not an interop layer.
- **Explicitly de-scope:** deep SBCL↔Rust FFI as a desktop mechanism; Ceramic as a
  dependency.

## Flagged / unverified

- No SBCL-in-Tauri precedent; `child.kill()` lifecycle for a single-process SBCL
  binary is inferred, not tested.
- macOS notarization #11992 may have progressed after this research — re-check.
- No documented SBCL version floor for Ceramic; inferred ~2019-era.
