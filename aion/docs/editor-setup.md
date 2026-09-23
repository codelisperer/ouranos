# Aion — Editor Setup

Get Claude plus the Common Lisp / Coalton dev stack working in VS Code, Emacs, or
Neovim. This mirrors the shared setup across the Ouranos ecosystem (dependency
order): `aion` → `cons` → `mnemosyne` → `elenchon` → `hyperion` → `praxeon`.

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
3. **Launch VS Code from a terminal** — `cd ouranos && code .` (open the whole
   monorepo, not just `aion/`). VS Code inherits your shell `PATH`, so Alive can
   find `sbcl` (e.g. `/opt/homebrew/bin`). Launched from the Dock/Finder, the GUI
   environment often lacks it and Alive can't start.
4. The committed `.vscode/settings.json` overrides Alive's `startCommand` to
   **load the system into the LSP image on start** — so `(in-package #:aion)`
   resolves and completion/xref see the real code (no *"does not designate any
   package"* nag). **First boot is slower**: it loads Aion and compiles Coalton if
   cold (a minute-ish; cached after). If Alive seems to hang on open, that's the
   load, not a crash.

## Emacs

`M-x sly` (or SLIME) with swank. `C-c C-k` compiles a file, `C-c C-c` a form.
Coalton's `coalton-toplevel` forms compile like ordinary CL forms — handy for the
typed layer.

## Neovim

`vlime` (a SWANK client) or `conjure`: start SWANK from SBCL, then connect.

## Gotchas

- **`Heap exhausted, game over`** on the first load — Coalton's first compile needs
  more than SBCL's 1 GB default. The repo-root `bootstrap.lisp` invocation
  (`sbcl --dynamic-space-size 4096 --script bootstrap.lisp`) passes the flag; a
  bare hand-started `sbcl` needs `--dynamic-space-size 4096` too.
- `.vscode/alive/` (Alive's per-project compile scratch) is gitignored — don't
  commit it.

## See also
- `docs/user-guide.md` · `docs/roadmap.md` · `docs/aion-vision.md` ·
  `docs/coalton-gap-analysis.md` · `CLAUDE.md`.
