# cons — Editor Setup

Get Claude plus the Common Lisp dev stack working in VS Code, Emacs, or Neovim.
This mirrors the shared setup across the `cons` / `hyperion` / `aion` / `praxeon` /
`elenchon` ecosystem.
(cons is pure-CL and dependency-light — no Coalton/libev, so setup is lighter.)

## VS Code (primary)

1. Install the **Claude Code** extension (or run `claude` in the integrated
   terminal and accept the IDE prompt). `CLAUDE.md` and `.claude/` are picked up
   automatically.
2. For Lisp, install **Alive** — `rheller.alive` ("Alive: The Average Lisp VSCode
   Environment"). It drives **SBCL directly** (no Roswell / `cl-lsp` / swank).
   `.vscode/extensions.json` already recommends it.
   **Do not** use `ailisp.commonlisp-vscode`: it depends on the unmaintained,
   Roswell-based `cl-lsp`, whose TCP mode crashes under Linedit on modern SBCL, so
   its language server times out (*"Connection to lsp times out"*).
3. **Launch VS Code from a terminal** — `cd cons && code .`. VS Code inherits your
   shell `PATH`, so Alive can find `sbcl` (e.g. `/opt/homebrew/bin`). Launched from
   the Dock/Finder, the GUI environment often lacks it and Alive can't start.
4. The committed `.vscode/settings.json` overrides Alive's `startCommand` to
   **load the system into the LSP image on start** — so `(in-package #:cons/…)`
   resolves and completion/xref see the real code (no *"does not designate any
   package"* nag). cons is light, so boot is fast.

## Emacs

`M-x sly` (or SLIME) with swank. `C-c C-k` compiles a file, `C-c C-c` a form.

## Neovim

`vlime` (a SWANK client) or `conjure`: start SWANK from SBCL, then connect.

## Gotchas

- `.vscode/alive/` (Alive's per-project compile scratch) is gitignored — don't
  commit it.
- (No Coalton heap concern here — cons stays pure-CL. If that changes, start SBCL
  with `--dynamic-space-size 4096`, as the siblings do.)

## See also
- `docs/user-guide.md` · `docs/roadmap.md` · `docs/cons-vision.md` · `CLAUDE.md`.
