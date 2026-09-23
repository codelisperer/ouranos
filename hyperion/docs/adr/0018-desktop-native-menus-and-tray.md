# ADR-0018 — Desktop native menus: declared by the app, rendered by the launcher

**Status:** Proposed
**Date:** 2026-09-13
**Context:** pre-publication issue 271 (the macOS menu bar defect that prompted this), pre-publication issue 276 (hyperion-view has no
automated coverage), ADR-0008 (out-of-process webview), ADR-0011 (no native library on every
desktop image)

## Context

A Hyperion desktop app is a Hyperion server on `127.0.0.1:<port>` plus `hyperion-view`, a
small C++ launcher over `webview.h`, as a **separate process** (ADR-0008). pre-publication issue 271 showed the
cost of that process having no native menu: it takes
`NSApplicationActivationPolicyRegular`, so it *owns* the macOS menu bar, and it installed
nothing into it — no Apple menu access, no ⌘Q, and no ⌘V inside the web view, because on
macOS those are menu-item key equivalents.

That is fixed. The question this ADR answers is the general one behind it: **can an app
define its own menus, About box, and (on Windows) tray icon — and how do menu actions reach
the server?**

## The wiring question dissolves

The launcher already holds the server's URL — it is the same URL the web view points at,
and the launcher can make HTTP requests to it exactly as the page does.

**So a menu action does not need an IPC bridge. It needs a URL.** There is no new protocol
to design, no socket, no pipe, no JS↔native binding. The launcher is a browser with a menu
attached.

`webview.h` 0.10 provides everything the design needs, all public API:

| | |
|---|---|
| `webview_navigate(url)` | whole-window action |
| `webview_eval(js)` | trigger an HTMX request — a server-rendered fragment |
| `webview_dispatch(fn)` | run on the GUI thread from another thread — the reverse channel |
| `webview_get_window()` | real `HWND` / `NSWindow` / `GtkWindow` |
| `webview_bind(name, fn)` | JS → native, if ever needed |

## Decision

**1. The menu is data the application serves; the launcher is a dumb renderer.**

At startup the launcher GETs a well-known endpoint (`/.well-known/desktop-menu`), receives
JSON, and builds the native menu. One C++ implementation; every app declares its own menu in
Lisp. No app ships its own launcher, and no menu change requires a rebuild.

This is the same rule the tree already applies elsewhere: queries are data
(`mnemosyne`), the event vocabulary is data (`hermes/payments`), the build spec is data
(`cons.lisp`). A menu is UI vocabulary, and UI vocabulary belongs to the app.

**2. Three action kinds, all over the existing transport.**

- `navigate` → `webview_navigate`. Switch view.
- `eval` → `webview_eval` of an HTMX call. Open a modal, refresh a region.
- `post` → the launcher issues an HTTP POST itself. A command with no page change.

**3. The About box is a page, not a dialog.** A route (`/about`) rendered by the app's own
templates and opened as an HTMX modal — styled like the rest of the app, identical on three
platforms, written once in Spinneret. macOS's `orderFrontStandardAboutPanel:` stays as the
zero-config default for apps that declare nothing.

**4. The platforms get different things, because they are different.**

| | what ships | why |
|---|---|---|
| **macOS** | full menu bar | The app owns the bar whether or not it fills it (pre-publication issue 271). Not optional. |
| **Windows** | **tray icon**, not a menu bar | Windows has no application-owned system menu bar. An in-window `SetMenu` on a web-view-filling window is dated and fights the layout. `Shell_NotifyIcon` needs a window proc for its callback messages; `webview_get_window()` returns the real `HWND`, so `SetWindowSubclass` reaches it. |
| **Linux** | nothing | GTK4 dropped per-window icons (already documented in our icon code), GNOME has no tray without extensions, and app menus are deprecated. `libayatana-appindicator` would put a **native library on the load path of every desktop image** — the exact shape ADR-0011 exists to prevent, after libev. |

Explicitly **not** one cross-platform menu API. A menu on macOS and a tray on Windows are
different features serving the same intent, and a single abstraction over them would satisfy
neither idiom.

## Consequences

- An app with no menu declaration keeps exactly today's behaviour: the macOS default menu
  from pre-publication issue 271, nothing elsewhere. The feature is opt-in and additive.
- The launcher gains an HTTP client and a JSON parser. Both are small; neither is a new
  external dependency on the Lisp side.
- A menu that is fetched at startup is static for the session. Enable/disable, checkmarks and
  dynamic items need a reverse channel — `webview_dispatch` makes it possible and a JSON-line
  protocol on the launcher's **stdin** is the cheapest transport, since `run-app` already owns
  the subprocess. **Deferred until something needs it.**
- **Every line of this lands in the file with the least test coverage in the tree.**
  `hyperion-view` has no automated coverage at all (pre-publication issue 276) and two open hand-found defects
  (pre-publication issue 268, #116). pre-publication issue 276 should land first, or this grows the untested surface.

## Alternatives considered

- **Menus defined in C++ per app.** Rejected: every app would ship its own launcher, and a
  menu change would be a rebuild. It also puts application vocabulary in the framework's
  native layer, which is the sideways dependency `docs/vocabulary-and-layers.md` describes.
- **A JS↔native bridge via `webview_bind`.** Rejected as the primary mechanism: it exists and
  works, but it introduces a second transport alongside HTTP for no gain — the server is
  already reachable, and ADR-0008 chose out-of-process precisely to avoid an in-process
  bridge.
- **A native About dialog on every platform.** Rejected: three implementations of a box the
  app cannot restyle, when the app already knows how to render a page.
- **An in-window menu bar on Windows and Linux** (`SetMenu`, `GtkMenuBar`). Rejected: it is
  the wrong idiom on both, and on Linux it reintroduces the chrome GTK4 is removing.

## Provenance

The prompt was a user-visible defect — a frozen menu bar and a dead ⌘Q on two desktop apps
(pre-publication issue 271) — and the maintainer's own framing, that a menu is clearly worth it on macOS and that
Windows probably wants a tray rather than a menu bar. That instinct is what the platform
table records; the measurement only confirmed it.

The design question as posed was "how do we wire actions to the server", and the answer is
that there is nothing to wire: reading `webview.h`'s API against ADR-0008's architecture
showed the launcher already has the URL. The interesting work was establishing that the
problem did not exist, rather than solving it.
