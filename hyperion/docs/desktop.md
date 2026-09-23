# Hyperion desktop capability — design

**Status:** **M1 built & proven — 2026-07-25.** Implements
[ADR-0008](adr/0008-desktop-shell-cl-native-webview.md) (CL-native, out-of-process OS
webview). `hyperion/desktop:run-app` + the native `hyperion-view/` + the visual Coalton
REPL example (`hyperion/examples/coalton-repl`, engine `cons/coalton-repl`) run end-to-end
in a native WebView2 window on Windows. Launcher build: `build.sh` (Linux/macOS) and
`build.ps1` (Windows — MSVC *or* mingw-w64, native PowerShell, no MSYS2 needed); both take
`--check`/`-Check`, a prerequisite doctor that names what is missing and how to install it.
**All three platforms verified** (Windows 11 / MSVC + mingw-w64, macOS / Apple clang, Ubuntu
26.04 / WebKitGTK 4.1). M2+ (dialogs, cons `desktop` scaffold, updater/installer) below.

**Distribution & self-update** — the pattern that makes a desktop app maintainable (the app
notices a build for its own OS, fetches, verifies, swaps, relaunches) is designed in
[`desktop-distribution-design.md`](desktop-distribution-design.md), decided in
[ADR-0010](adr/0010-desktop-distribution-and-self-update.md): native-runner CI matrix (SBCL
cannot cross-compile), a signed manifest per channel, Ed25519 over artifact *and* manifest,
per-user install locations, stage-and-swap per OS, and an HTMX-native update UI.

## What this is

The capability that turns a Hyperion web app into a **native desktop app** without Tauri
or Electron. A dumped SBCL image runs the Hyperion server **in-process** on localhost and
launches a tiny **out-of-process** native webview pointed at it. The webview is a pure
renderer; all interaction is HTMX-over-HTTP to the local server — which already has full
OS/filesystem access because *it is the native process*.

Desktop is **one UX surface among several** (web, desktop, CLI, native mobile, pure API)
over a single core — see [ADR-0009](adr/0009-api-first-multi-ux.md). So the embedded local
server is the **default, not a hardcode**: a desktop app can equally be a thin client over
a *remote* Hyperion backend (the GitHub-Desktop model) — see Backends below.

```
  ┌─────────────────────────── one dumped SBCL image ───────────────────────────┐
  │  bin/<app>                                                                   │
  │    ├─ Hyperion / Woo|Hunchentoot  → serves HTMX on 127.0.0.1:<free port>     │
  │    └─ uiop:launch-program ─────────────────────────────────────────────┐    │
  └────────────────────────────────────────────────────────────────────────┼────┘
                                                                            │ argv: url title w h
                                                       ┌────────────────────▼─────────────────┐
                                                       │ hyperion-view  (own process,        │
                                                       │  own GUI main thread)                  │
                                                       │  WebView2 / WKWebView / WebKitGTK      │
                                                       │  ── HTMX/HTTP ──▶ 127.0.0.1:<port>     │
                                                       └────────────────────────────────────────┘
```

**Why out-of-process** (the crux, per ADR-0008): `webview_run()` must own the GUI main
thread and blocks; in-process it collides with SBCL's main thread and crashes macOS
AppKit calls into `ldb`. Because HTMX means we need **no in-process JS↔native bridge**,
the webview lives in its own process and the hazard disappears.

## System shape (DAG-respecting)

A new **aux ASDF system `hyperion/desktop`** (same pattern as `hyperion/session-db`) so
Hyperion **core stays webview-free** — only apps that want desktop pull the FFI.

- `hyperion/desktop` — depends on `hyperion` + `usocket` + `uiop`. Public API: `run-app`
  + lifecycle. (No CFFI yet — the launcher is a subprocess, not in-image FFI.)
- `hyperion/desktop/dialog` — `tinyfiledialogs` CFFI (file/save/folder/message). **M2.**
- Distribution (the auto-updater) is **cons's**, not here — see Open decisions.

## The core API

```lisp
(hyperion/desktop:run-app app
  &key (title "App") (width 1200) (height 800)
       (backend :embedded)                   ; :embedded | (:remote url) | (:hybrid url)
       (port :auto)                          ; :auto → pick a free port; or an integer
       (server (hyperion/server:default-server))
       (shell :webview)                      ; :webview (native) | :browser (dev convenience)
       (launcher (default-launcher))         ; path to the hyperion-view binary
       on-ready on-close)
```

**Backends — the escape hatch (ADR-0009).** The webview needs a URL; where the server
lives is a mode, not a hardcode:
- **`:embedded`** (default) — start Hyperion in-process on a free localhost port (steps
  1–3 below); the one-off, offline-capable app.
- **`(:remote url)`** — no local server; point the webview straight at a **remote**
  Hyperion backend (`app` may be `nil`). This is GitHub-Desktop-over-github.com.
- **`(:hybrid url)`** — a local server for local/native features *and* calls out to the
  remote data API. `app` is the local surface; `url` the remote contract.
For `:remote`, the lifecycle skips port/readiness/stop and just launches the shell at `url`.

**Lifecycle** (grounded in the real `hyperion/server:start`, which takes a fixed port on
a background thread and returns a handler — it does not report a bound ephemeral port, so
we choose the port ourselves):

1. Resolve the port: `:auto` → bind a `usocket` listener to port 0, read the assigned
   port, close it, use that number. (Small TOCTOU window; acceptable for a local app.)
2. `handler ← (hyperion/server:start app :port p :host "127.0.0.1" …)` — background thread.
3. **Readiness poll**: `GET http://127.0.0.1:p/` until 200, bounded by a timeout — closes
   the launch race (don't point the webview at a not-yet-listening server).
4. `(when on-ready (funcall on-ready url))`.
5. Launch the shell:
   - `:webview` → `(uiop:launch-program (list launcher url title (princ-to-string width)
     (princ-to-string height)))` — the native window; owns its own main thread/process.
   - `:browser` → open `url` in the default browser (dev/hot-reload convenience).
6. `(uiop:wait-process proc)` — blocks until the window closes.
7. `(when on-close (funcall on-close))`; `(hyperion/server:stop handler)`; return.

A clean quit from inside the app (a menu "Quit") is a `POST /quit` that closes the
webview (or signals the launcher); the same teardown runs.

## The native launcher (built first — M1 decision)

A ~20-line C program linking the `webview/webview` single-header lib (MIT), which wraps
WebView2 (Windows) / WKWebView (macOS) / WebKitGTK (Linux). ~200 KB per OS.

```c
/* hyperion-view.c   argv: url [title] [width] [height] */
#include "webview.h"
#include <stdlib.h>
int main(int argc, char **argv) {
  webview_t w = webview_create(0, NULL);
  webview_set_title(w, argc > 2 ? argv[2] : "App");
  webview_set_size(w, argc > 3 ? atoi(argv[3]) : 1200,
                      argc > 4 ? atoi(argv[4]) : 800, WEBVIEW_HINT_NONE);
  webview_navigate(w, argc > 1 ? argv[1] : "http://127.0.0.1:8080/");
  webview_run(w);            /* owns this process's main thread; returns on window close */
  webview_destroy(w);
  return 0;
}
```

Built once per OS in CI and bundled beside `bin/<app>`; `default-launcher` resolves it
relative to the app binary. On Windows it needs the Edge **WebView2 runtime** (present on
Win11; bootstrap it in the installer for Win10). `:browser` remains available so the REPL
UI can be developed with Hyperion's hot-reload loop before/while the launcher exists — but
per the M1 decision the native window is stood up **first**, not last.

## Native features (thin, HTML-first — mostly M2+)

| Feature | How |
|---|---|
| File open/save/folder | `hyperion/desktop/dialog` → CFFI `tinyfiledialogs`; an HTMX POST → server calls the picker → returns the path. (macOS main-thread caveat — see Open decisions.) |
| Menus, clipboard, notifications, drag-drop | **In the page** (HTMX / `navigator.clipboard` / `Notification`) — no FFI. |
| System tray, macOS menu bar | Genuinely native per-OS; deferred until an app needs them. |

## cons `desktop` scaffold target (the AiTP playbook, in CL — M3)

`cons init myapp --template desktop` (a `desktop` target kind, [cons-vision §10](../../cons/docs/cons-vision.md))
emits the shippable skeleton:

- the Hyperion app + a `run-app` main; the **VSCode-style shell as Hyperion generic
  components** (Navigation / Properties / Main / AI-Assistant panels — ties to roadmap §1);
- a **`~/.myapp` schema-versioned config** module (AiTP's `config.rs` load→detect→migrate→
  restamp ported to CL; `cons/env` already closes the env loop);
- `hyperion-view/` (the C above + per-OS build recipe);
- `update/` (Ed25519 + `latest.json` publish script) and `installer/` (NSIS/WiX/create-dmg
  + `release.yml`).

## Distribution (M4)

Mirror AiTP's proven pipeline in CL: signed artifacts on S3 (`updates/latest.json` +
a permanent `download/<App>-Setup.exe`), tag-driven CI. The updater: fetch `latest.json`
→ compare version → download the signed artifact → **verify Ed25519 (Ironclad)** → atomic
swap (with the Windows locked-exe rename/`MoveFileEx` dance) → relaunch. Installers via
WiX/NSIS/`create-dmg`/`linuxdeploy` from CI — none require Tauri/Electron.

**Honest cost (from ADR-0008):** this glue — updater self-replace, installers, native
FFIs, CI matrix — is the ~90%; the webview is the easy ~10%. **OS code-signing +
notarization** is an unavoidable tax, identical for Tauri/Electron.

## Milestones

- **M1 — Prove the shell. ✓ DONE (2026-07-25).** `hyperion/desktop` aux system +
  `run-app` + free-port + readiness poll; the native `hyperion-view` (built up front,
  proven on Windows/WebView2); the **visual Coalton REPL** as the example app
  (`hyperion/examples/coalton-repl` front-end + `cons/coalton-repl` engine). Runs in a
  native window; validates window + webview + localhost + Hyperion + lifecycle end to end.
- **M2** — `hyperion/desktop/dialog` (`tinyfiledialogs`) + single-instance + hardening.
- **M3** — the `cons desktop` scaffold (config, launcher build, shell components).
- **M4** — distribution: Ed25519 S3 updater + installers + release CI.
- **M5** — a writing-assistant app, fresh on the stack (praxeon agents + this capability).

## Open decisions

1. **Updater home** — a reusable **`cons/dist`** (recommended: serves any `bin/<app>`,
   optional system so Ironclad stays out of cons core) vs `hyperion/desktop/update` vs FFI
   to WinSparkle/Sparkle for native update UIs. *(M4.)*
2. **macOS file dialogs** — `tinyfiledialogs` from the server thread may need the app's
   main thread on macOS; if so, host dialogs in the launcher process instead of the server.
   *(M2.)*
3. **WebView2 bootstrap on Windows 10** — embed the bootstrapper in the installer vs assume
   the runtime. *(M4.)*

## References

- [ADR-0008](adr/0008-desktop-shell-cl-native-webview.md) — the decision + rejected alternatives.
- `webview/webview` (MIT) — the OS-webview shim. `tinyfiledialogs` (MIT) — dialogs.
- The Tauri app playbook + AiTP (`c:\projects\aitp`) — the requirements this mirrors in CL:
  `~/.<app>` config, signed-S3 auto-update, NSIS/MSI installer, the panel shell vocabulary.
