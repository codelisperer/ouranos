# Hyperion — Editor Setup

Get Claude plus the Common Lisp / Coalton dev stack working in VS Code, Emacs, or
Neovim. This mirrors the shared setup across the ecosystem.

**Assumed stack for general users: VS Code + Alive + Calva/Joyride.** *Alive* drives
SBCL for the Common Lisp side; *Calva* + *Joyride* bring a Lisp (ClojureScript) for
scripting the editor itself — *if you can't use CL in VS Code, at least you can use a
Lisp.* Emacs and Vim/Neovim are fully supported for the Lisp work (below); we will
add equivalent editor niceties there over time.

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
3. **Launch VS Code from a terminal** — `cd hyperion && code .`. VS Code inherits
   your shell `PATH`, so Alive can find `sbcl` (e.g. `/opt/homebrew/bin`). Launched
   from the Dock/Finder, the GUI environment often lacks it and Alive can't start.
4. The committed `.vscode/settings.json` overrides Alive's `startCommand` to
   **load the system into the LSP image on start** — so `(in-package #:hyperion/…)`
   resolves and completion/xref see the real code (no *"does not designate any
   package"* nag). **First boot is slower**: it loads Hyperion and compiles Coalton
   if cold (a minute-ish; cached after). If Alive seems to hang on open, that's the
   load, not a crash.

## VS Code — editor scripting (Calva + Joyride)

To script VS Code *itself* in a Lisp, install **Calva**
(`betterthantomorrow.calva`) and **Joyride** (`betterthantomorrow.joyride`) —
Joyride runs ClojureScript against the VS Code API (SCI). We use it for editor
niceties that don't yet exist natively.

**`fill_paragraph.cljs` (Emacs `M-q` / vim `gwip`).** Reflows the paragraph at the
cursor to `editor.wordWrapColumn`, honoring Markdown blockquote/list prefixes.

- **User-level** (works everywhere): the script lives at
  `~/.config/joyride/scripts/fill_paragraph.cljs`, bound to **Alt+Q** in your user
  `keybindings.json` via `joyride.runUserScript`.
- **Per-project:** each repo also ships it at `.joyride/scripts/fill_paragraph.cljs`
  (a workspace script) so contributors have it. Keybindings are user-level in VS
  Code, so each dev binds **Alt+Q** once — to `joyride.runWorkspaceScript` to use the
  project's copy:
  ```json
  { "key": "alt+q", "command": "joyride.runWorkspaceScript",
    "args": "fill_paragraph.cljs", "when": "editorTextFocus" }
  ```

## Emacs

`M-x sly` (or SLIME) with swank. `C-c C-k` compiles a file, `C-c C-c` a form.
Coalton's `coalton-toplevel` forms compile like ordinary CL forms.

## Neovim

`vlime` (a SWANK client) or `conjure`: start SWANK from SBCL, then connect.

## Gotchas

- **`Heap exhausted, game over`** on the first load — Coalton's first compile needs
  more than SBCL's 1 GB default. The repo-root `sbcl --dynamic-space-size 4096
  --script bootstrap.lisp` and the committed `.vscode` start command pass the big
  heap; a bare hand-started `sbcl` needs the flag too. (`cons repl` passes it as
  well.)
- `.vscode/alive/` (Alive's per-project compile scratch) is gitignored — don't
  commit it.

## See also
- `docs/user-guide.md` · `docs/roadmap.md` · `docs/hyperion-vision.md` · `CLAUDE.md`.
