# Editor setup for Praxeon

You use **VS Code** for convenience and drop into **Emacs** or **Neovim** when
hand-coding in the zone. This gets Claude working in all three, plus the Common
Lisp / Coalton dev stack.

## How project context is picked up

Any Claude-enabled editor that runs the **Claude Code CLI** reads this repo's
`CLAUDE.md` (the always-on constitution) and everything under `.claude/`
(project skills in `.claude/skills/`, slash commands in `.claude/commands/`,
settings in `.claude/settings.json`) automatically when the CLI starts with this
folder as its working directory. Nothing editor-specific is required for that —
the three integrations below are just different front-ends onto the same CLI.

Prerequisites for all editors:

- **Claude Code CLI** installed and on `PATH` (`claude --version` should work).
- **SBCL** and **Quicklisp** for running the code.
- An LLM provider key for Elise, via the `PRAXEON_LLM_*` / `.env` config surface
  (see `docs/user-guide.md` §1; not needed to load/test).

---

## VS Code (primary)

1. Install the **Claude Code** extension from the Marketplace (or run `claude`
   once in the integrated terminal and accept the IDE-integration prompt).
2. Open the `praxeon/` folder. `CLAUDE.md` and `.claude/` are picked up
   automatically; selection and diagnostics are shared with Claude.
3. For Lisp itself, install the **Alive** extension (`rheller.alive`,
   "Alive: The Average Lisp VSCode Environment") for an SBCL REPL, inline eval,
   and paren handling. Alive drives **SBCL directly** — no Roswell, `cl-lsp`, or
   swank. (Avoid `ailisp.commonlisp-vscode`: it depends on the unmaintained,
   Roswell-based `cl-lsp`, whose TCP mode crashes under Linedit on modern SBCL,
   so its language server times out.)

---

## Neovim

Use the official **[`coder/claudecode.nvim`](https://github.com/coder/claudecode.nvim)**
— pure Lua, and it speaks the same WebSocket/MCP IDE protocol as the VS Code
extension (shared selection, in-editor diffs). Config via **lazy.nvim**:

```lua
-- ~/.config/nvim/lua/plugins/claude.lua
return {
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },  -- terminal + pickers
  config = true,
  keys = {
    { "<leader>ac", "<cmd>ClaudeCode<cr>",        desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>",   desc = "Focus Claude" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>",    mode = "v", desc = "Send selection" },
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>",   desc = "Reject diff" },
  },
}
```

`:ClaudeCode` opens Claude in a split; visual-mode `<leader>as` sends the
selection as context. If you use **LazyVim**, `:LazyExtras` → enable
`ai.claudecode` instead of the above.

For Common Lisp editing, pair it with **[vlime](https://github.com/vlime/vlime)**
(a SWANK client) or **[conjure](https://github.com/Olical/conjure)**:

```lua
{ "vlime/vlime", ft = "lisp" },  -- start SWANK from SBCL, then :VlimeConnect
```

---

## Emacs

Use **[`manzaltu/claude-code-ide.el`](https://github.com/manzaltu/claude-code-ide.el)**
— native Claude Code integration over MCP that also exposes Emacs back to Claude
(xref, imenu, project.el, treesit). Requires **Emacs 28.1+** and the Claude Code
CLI on `PATH`. With `use-package` + a package manager (MELPA or straight):

```elisp
;; ~/.emacs.d/init.el  (or your literate config)
(use-package vterm)  ; recommended terminal backend

(use-package claude-code-ide
  :vc (:url "https://github.com/manzaltu/claude-code-ide.el" :rev :newest)
  :bind ("C-c C-'" . claude-code-ide-menu)   ; transient menu of actions
  :config
  (claude-code-ide-emacs-tools-setup))       ; expose xref/imenu/etc. to Claude
```

Per-project sessions are automatic (buffer `*claude-code[praxeon]*`);
`claude-code-ide-list-sessions` switches between them.

For Common Lisp, use **[Sly](https://github.com/joaotavora/sly)** (or SLIME):

```elisp
(use-package sly
  :init (setq inferior-lisp-program "sbcl")
  :config (require 'sly-quicklisp nil t))
```

`M-x sly` starts SBCL; `C-c C-k` compiles a file, `C-c C-c` a form. Coalton's
`coalton-toplevel` forms compile like ordinary CL forms, so Sly's normal
compile/eval keys work on the typed core.

---

## The Lisp dev loop (all editors)

See `.claude/skills/repl-workflow` for the canonical commands. In short:

```lisp
;; discovery is automatic once the repo-root bootstrap.lisp has run — it writes an
;; ASDF (:tree) source-registry drop-in, so no symlink and no asdf:*central-registry*
(ql:quickload :praxeon)
(asdf:test-system :praxeon)
```

Then develop REPL-first: edit, recompile the buffer/form, re-run. Let Coalton
type errors guide edits to the core rather than working around them.

---

## Want these applied to your real configs?

The Neovim and Emacs snippets above are ready to paste. If you'd like, grant me
access to `~/.config/nvim/` and/or your Emacs config directory and I'll wire them
in directly (merging with your existing setup rather than overwriting).
