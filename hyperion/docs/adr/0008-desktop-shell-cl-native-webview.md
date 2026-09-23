# ADR-0008 — Desktop shell: CL-native, out-of-process OS webview (no Tauri/Electron)

**Status:** Provisional — 2026-07-25 (accepted direction; unbuilt, revisitable under
time-to-ship pressure — see Alternatives)

## Context

We want to ship **desktop apps** on the stack — the visual Coalton REPL first (see the
[cons roadmap §6](../../../cons/docs/roadmap.md)), a greenfield agentic writing app
(a writing-assistant app) later. The two mainstream shells both violate the *CL-all-the-way-down*
thesis (ECOSYSTEM.md / CLAUDE.md): **Tauri** drags in a Rust toolchain; **Electron**
drags in Node + a bundled Chromium (~150–200 MB). The question raised: can we **embed
what Electron does natively in CL**, "from scratch"? A fresh technical review answered it.

**Precise framing (this is what the review settled).** "From scratch" splits in two:
writing an **HTML renderer** is infeasible (engineer-millennia) and is *not* on the
table; FFI to the **OS-native webview** (WebView2 on Windows, WKWebView on macOS,
WebKitGTK on Linux) plus CL glue **is** feasible and bounded — it is literally *Tauri's
architecture with the Rust layer replaced by CL*. An OS webview is an unavoidable C
dependency in **every** language; the only choice is which small shim to bind, not
whether to bind one.

## Decision

**Adopt an out-of-process, CL-native webview shell** ("Option C"):

- A dumped SBCL image boots **Hyperion/Woo on `127.0.0.1:<ephemeral port>`** (in
  process — the CL server *is* the native process, with full OS/filesystem access), then
  `uiop:launch-program`s a **small per-OS webview launcher** (a `webview.h`-style shim
  over WebView2 / WKWebView / WebKitGTK) pointed at that localhost URL.
- **Out-of-process is the key move.** Because the UI is **HTMX-over-HTTP to localhost**,
  we need *none* of the webview's in-process JS↔native `bind`/`eval` bridge. That lets
  the webview own its own GUI main thread in its own process and dodges the review's
  single biggest SBCL hazard: `webview_run()` blocks the main thread, and macOS AppKit
  crashes off-thread calls into `ldb` (both in-process CL bindings hit exactly this).
- **Native extras, minimized by the HTML-first model:** file pickers via FFI to
  **`tinyfiledialogs`** (one-file C); menus / clipboard / notifications / drag-drop **in
  the page** (HTML/HTMX); macOS system menu bar and tray only for apps that need them.
- **Auto-update:** an Ed25519 self-updater (Ironclad: fetch signed artifact → verify →
  atomic swap → relaunch, incl. the Windows locked-exe replace dance) **or** FFI to
  **WinSparkle/Sparkle**. **Installers** via WiX/NSIS/`create-dmg`/`linuxdeploy` from CI.
- **DAG placement:** **Hyperion** provides the desktop *capability* (launcher + localhost
  lifecycle + the thin native-FFI layer); **cons** scaffolds it via a `desktop` build-
  target kind ([cons-vision §10](../../../cons/docs/cons-vision.md)); **apps** consume it.

## Consequences

- **CL-all-the-way-down stays intact** with exactly one small, unavoidable C shim; the
  footprint is ~30–50 MB (the SBCL image), not Electron's ~150–200 MB.
- **We sign up to reimplement Tauri's non-rendering glue** — the updater self-replace,
  installer scripts, native-feature FFIs, and the CI matrix. The webview is the easy
  ~10%; this glue is the ~90% and is *weeks-to-months* of real work Tauri hands you free.
- **OS code-signing + macOS notarization is an unavoidable tax**, identical for Tauri and
  Electron; the shell choice neither adds nor removes it. Budget for it explicitly.
- **Avoid the WebKitGTK-direct path** (`cl-webkit`): it is Linux-only in practice —
  Nyxt, the flagship pure-CL webview app, is *adding Electron* in 4.0 over WebKitGTK's
  weak macOS/Windows support. The `webview.h` shim uses WebView2/WKWebView natively and
  is the one that actually crosses platforms.
- **First milestone is low-risk:** the visual REPL is local-only (no updater/installer
  needed), so it validates *window + webview + localhost + Hyperion* before we take on
  the glue a shipping app requires.

## Alternatives considered

- **Tauri (Rust).** Rejected on the thesis (not CL) — but the **rational fallback** if
  cross-platform time-to-ship ever outranks purity for a specific app; it gives the
  updater, multi-OS bundler, and tested native layer *today*. Say so up front when it applies.
- **Electron / Ceramic.** Rejected: Node + Chromium; Ceramic is ~5 years unmaintained,
  pinned to Electron 5, coupled to the old Lucerne stack.
- **In-process CFFI to `webview.h`** (harden `cl-webview` / `lisp-webview`). Rejected as
  the default: the main-thread/`ldb` crashes above; out-of-process avoids them for free.
- **`cl-webkit` / WebKitGTK direct.** Rejected: Linux-only in practice (see Consequences).
- **EQL5 (ECL + Qt/QtWebEngine).** Rejected: ECL, not SBCL — a second implementation and
  a Qt/Chromium dependency; abandons the SBCL-exclusive thesis.
- **McCLIM.** Rejected: renders its own widget world; no HTML/CSS/DOM engine, so it
  cannot run a Spinneret/HTMX page.
