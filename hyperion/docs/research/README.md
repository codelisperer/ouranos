# Research notes

Standalone research reports feeding roadmap decisions. Each leads with a clear
recommendation and a "Roadmap implications" section. Researched 2026-07-16.

| Report | One-line recommendation |
|---|---|
| [desktop-ceramic-vs-tauri.md](desktop-ceramic-vs-tauri.md) | Not Ceramic (archived). Ship a CL-native system-webview shell (`clogframe`) at the in-process server first; Tauri optional/heavier; SBCL↔Rust only as Lisp→Rust FFI, else process boundary. |
| [live-repl-and-dynamic-compilation.md](live-repl-and-dynamic-compilation.md) | Embed Slynk (Swank-compatible, dev-gated, localhost) + a generic HTMX browser REPL; generalize praxeon's hot-reload loop into a pluggable asset-source protocol (local dir + S3/zs3). |
| [multi-target-ux.md](multi-target-ux.md) | One keystone: a CLOS `render` generic per target over a Coalton-typed vocabulary. Build web → desktop → terminal REPL; treat TUI-components, Coalton→TS, native-mobile as staged/speculative. |
| [htmx-v4.md](htmx-v4.md) | Target v4 (still beta; window open). Spec the typed vocabulary against v4 now; **verify the request-header changes against four.htmx.org before encoding.** |

## Cross-cutting keystone

Three of the four reports converge on the same architectural decision: a **CLOS
`render` generic specialized per target over a Coalton-typed, backend-neutral
HTMX/component vocabulary**, with a **process boundary** as the integration
contract wherever external code meets the SBCL image (Tauri sidecar, untrusted
eval, Rust interop). Design that seam now — it costs nothing and every surface
leans on it.
