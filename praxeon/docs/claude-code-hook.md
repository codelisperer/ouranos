# praxeon-claude-code: a report on tool-output tokens, and a hook that shortens large search outputs

`praxeon-claude-code` is an executable built from `praxeon/claude-code` (#452). It has two
commands:

- **`report`** reads your Claude Code session transcripts and prints how much of what your
  sessions read came from large tool outputs, and how much of that the hook would replace. Run
  it first: whether the hook is worth installing depends on your own sessions.
- **`hook`** is a Claude Code `PostToolUse` hook. When a search command or an MCP tool returns
  a large output, it replaces what the main model reads with some of the output's lines, copied
  unchanged, and the path of the saved original. For `rg` and `grep` it groups the matches by
  file, with no model call; otherwise a second model chooses which lines to keep (#465). When
  anything goes wrong it prints nothing, so the original output goes through unchanged.

## Why a large output costs more than its size

A tool result stays in the conversation. Every later model call reads it again, usually from
the prompt cache, until the session compacts or ends. So a 30,000-token search result read by
the next 80 calls costs 2.4 million cache-read tokens, and replacing it with 1,500 tokens of its
lines removes most of that. How much this saves depends entirely on how often your sessions produce
large search outputs, which is what `report` measures.

## Building

From the repository root:

```sh
sbcl --non-interactive --load praxeon/scripts/build-claude-code.lisp
```

This writes `bin/praxeon-claude-code`, a saved SBCL image (about 95 MB) that starts in about
10 ms. It is dumped through `scripts/dump-image.lisp`, so it takes its temporary and cache
directories from the environment it runs in, not the build machine's. It needs no SBCL or
Quicklisp to run. On Linux and macOS it opens OpenSSL at start from the path it was built
against, so it runs only on a machine that has that library there. The image is saved
uncompressed on purpose: a compressed image is decompressed on every start, and the hook starts
once per matching tool call.

## `report`

```sh
bin/praxeon-claude-code report              # the last 30 days
bin/praxeon-claude-code report --days 7 --threshold 5000
```

It reads `~/.claude/projects/*/*.jsonl` and the subagent transcripts under
`~/.claude/projects/*/<session>/subagents/`, from files modified in the last `--days` days, and
prints:

- the number of model calls, and their input, cache-write, cache-read and output tokens, from
  each call's `usage` (a call is counted once, although Claude Code writes one record per content
  block);
- tool results: all of them, those above the threshold, and those the hook would replace, each
  with its tokens (estimated as characters / 4) and "read again": its size times the number of
  later calls before a compaction;
- an upper bound on the saving: if every output the hook would replace were replaced by the
  largest replacement it accepts, how many fewer tokens the later calls would read, as a share of
  all their input-side tokens;
- why the large outputs the hook would not replace were passed through;
- the categories most read again: the tool's name, or `Bash:` and the command's base name.

It prints no text of any message or result and no path, including the project directories'
names. A command whose name has a dot in it, such as `tool.exe` or `export.sh`, is counted as
`Bash:script`, and every MCP tool as `mcp`, because a script's or an MCP server's name can name a
client or a project, and the report is what people paste into issues.

On the maintainer's own sessions (15 transcripts, 5,658 calls, measured 2026-09-30), 38 results
were above 3,500 tokens and accounted for 11.2% of all tool-result tokens read again, and the
hook would have replaced none of them: 21 were Bash commands that are not searches, 14 came from
tools such as `Read`, and 3 were searches already narrowed with `head`. That is a workload where
the hook saves nothing. Yours may differ.

## Installing the hook

Installing it changes what the main model reads in every session the settings file covers.
Whether to do that, and where, is your decision.

**For one project**, in that project's `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "if": "Bash(rg *)",   "command": "/path/to/bin/praxeon-claude-code hook", "timeout": 120 },
          { "type": "command", "if": "Bash(grep *)", "command": "/path/to/bin/praxeon-claude-code hook", "timeout": 120 },
          { "type": "command", "if": "Bash(find *)", "command": "/path/to/bin/praxeon-claude-code hook", "timeout": 120 },
          { "type": "command", "if": "Bash(fd *)",   "command": "/path/to/bin/praxeon-claude-code hook", "timeout": 120 }
        ]
      },
      {
        "matcher": "mcp__.*",
        "hooks": [ { "type": "command", "command": "/path/to/bin/praxeon-claude-code hook", "timeout": 120 } ]
      }
    ]
  }
}
```

The `if` field uses permission-rule syntax, so the hook's process starts only for those
commands, not for every Bash call. The hook applies its own rules as well (below), so a broader
matcher is safe, only slower.

**For every project**, the same `hooks` block in `~/.claude/settings.json`.

**To try it without touching your own settings**, make a throwaway directory with its own
`.claude/settings.local.json` as above and start a separate session there, for example
`claude -p "..." --setting-sources local`, so your working session's reads are unchanged.

## What the hook never replaces

- anything other than Bash and MCP tools: `Read`, `Grep`, `Edit` and the rest pass through;
- a Bash command whose first word is not a search (`rg`, `grep`, `find`, `fd`);
- a search that reads or runs something else: any word, anywhere in the command, that is a read
  or print command (`cat`, `sed`, `head`, `tail`, `awk`, `less`, ...), `git` or `gh`, a
  program, `xargs`, a loop or a shell, and any of find's `-exec` and `-ok` or rg's
  `--passthru`, or `grep -v`;
- a search for a pattern that matches every line (`''`, `^`, `$`, `.`, `.*`), which prints whole
  files;
- an output Claude Code has already saved to a file: its event carries `persistedOutputPath`, and
  the model is shown a preview of about 2,000 characters, so a replacement would give it more to
  read, not less. Recorded on 2026-09-30: an output of 205,926 characters arrived with `stdout`
  cut to 29,999, and on two transcripts the model was shown 2,053 and 2,213 characters of
  outputs whose events carried 29,869 and 30,000;
- outputs under the threshold (3,500 tokens by default);
- a failed or interrupted command, and anything that wrote to stderr;
- an output containing a diff;
- an output or a command that looks like it carries a credential: a private key, a service's key
  prefix (`ghp_`, `sk-ant-`, `sk_live_`, `AIza`, `hf_`, `xoxb-`, ...), a JWT, a Slack webhook,
  `Authorization:`, `password`, `secret`, `token=`, `_authToken`, a `.netrc` line, or a URL with
  a password in it. The command is checked because it goes into the second model's prompt.
  Nothing matching is ever sent to the second model. The list errs towards matching, so a search
  over code that mentions `secret` or `password` passes through;
- an output carrying a SHA-like token (7 to 64 hexadecimal characters with both digits and
  letters) or a run-id-like one (10 or more digits) in the lines it matched. In this repository
  that keeps `git log` and CI logs out, because AGENTS.md requires SHAs and run ids to be read
  from the raw output. A search over a saved gate log is refused only when the lines it matched
  carry one; the gate prints SHAs in its provenance block, not on its suite lines.

## How the replacement is made (#465)

Every line of a replacement is either a line of the output, copied whole and unchanged, or a line
the hook writes itself, which starts with `[praxeon-claude-code: `. The hook writes three kinds:
the header, a marker where lines were left out, and, for grouped matches, one line per file. No
model writes any text that the main model reads.

1. **Grouped, with no model.** When the command is `rg` or `grep` and every line of its output
   names a file (`path:line:text` or `path:text`), the matches are grouped by file in the order
   the files first appear. Each file gets one line saying how many lines matched in it, followed
   by its first five matching lines, or fewer when five per file do not fit the budget. If even
   one line per file does not fit, or a line names no file (a heading, a context line, a
   single-file search), this step is skipped.
2. **Chosen by a second model.** Otherwise the output is sent with each line numbered, and the
   model answers only with ranges of line numbers, most important first (at most 40, held to
   that by the reply's schema, which allows no other field). The hook cuts each range to the
   output, drops reversed ones and ones wholly outside it, and takes them in the model's order,
   leaving out any range that would take the replacement over budget. The kept lines are printed
   in the output's order, with `[praxeon-claude-code: N lines omitted]` for every gap.

Either way the replacement is refused, and the original passes through, when it keeps no line of
the output, is over the budget (1,800 tokens by default), or is less than 30% smaller than the
original. A replacement made of copied lines cannot name a file, a line number or an identifier
the output does not contain, so #454's check for invented names is no longer needed and has been
removed.

**An instruction in a tool's output.** Because the model writes nothing, an instruction planted in
an output (a web page, a file, an MCP server's answer) reaches the main model only as that line of
the output, as it would have without the hook. At most it can influence which lines are kept. The
whole output stays in the archive.

The replacement starts with a header saying where its lines came from, for example:

```
[praxeon-claude-code: lines selected by claude-sonnet-5-5 from 5,668 tokens of output, 1,790 tokens kept. Every line that does not start with [praxeon-claude-code: is copied unchanged from the output. The full output is in /home/you/.cache/praxeon-claude-code/archive/<sha256>.txt]
[praxeon-claude-code: 12 lines omitted]
hyperion/src/html.lisp:54:    '("autocomplete")      ; allowed on <textarea> (WHATWG), rejected by Spinneret there
...
```

For grouped matches the header says `lines selected by praxeon-claude-code, grouping the matches
by file`.

## Settings

All environment variables, so they can be set in the hook's `command`:

| variable | default | meaning |
|---|---|---|
| `PRAXEON_CC_BACKEND` | `claude` | `claude`: the `claude` CLI in print mode, which uses your Claude Code login. `praxeon`: a `praxeon/llm` provider resolved with the role `compressor` (`PRAXEON_COMPRESSOR_*`, falling back to `PRAXEON_LLM_*`), for the Anthropic API with a key or an OpenAI-compatible server, including a local one |
| `PRAXEON_CC_MODEL` | `sonnet` | the model, for the `claude` backend |
| `PRAXEON_CC_EFFORT` | `medium` | the effort, for the `claude` backend |
| `PRAXEON_CC_CLAUDE` | `claude` | the `claude` program |
| `PRAXEON_CC_THRESHOLD` | 3500 | outputs under this many tokens pass through |
| `PRAXEON_CC_SUMMARY_BUDGET` | 1800 | the largest replacement accepted, in tokens, not counting its header |
| `PRAXEON_CC_TIMEOUT` | 90 | seconds the second model may take; set the hook's own `timeout` above it |
| `PRAXEON_CC_ARCHIVE_DAYS` | 7 | archived originals older than this are deleted |
| `PRAXEON_CC_CACHE_DIR` | `$XDG_CACHE_HOME/praxeon-claude-code/` or `~/.cache/praxeon-claude-code/` | the archive and the log |

Every whole-number setting must be above zero; anything else is ignored and the default used.

The `claude` backend's call cannot run this hook, a tool or an MCP server:
`claude -p --tools "" --strict-mcp-config --no-session-persistence --setting-sources ""
--settings '{"disableAllHooks": true}'`, with `--json-schema` for the ranges and
`CLAUDE_CODE_PROMPT_CACHE_TTL=5m`, since a one-shot call never reads a longer-lived cache back.
`--bare` is not used because it ignores the Claude Code login. The call runs in the temporary
directory, not the session's: from inside this repository the same call's prompt was 1,175 tokens
larger (8,633 cache-write tokens against 7,458 from an empty directory), because the CLI adds the
working directory's context, and from the temporary directory it was 7,322. `CLAUDE.md` was not
among the extra, since this repository's `CLAUDE.md` and `AGENTS.md` are about 10,000 tokens.

The archive's directory is created 0700 and its files 0600 on Unix, as Claude Code keeps its own
transcripts. A symbolic link where an archive file goes is removed rather than written through,
the age cleanup deletes only regular files, and nothing is logged through a `hook.log` that is a
link.

## The log

One JSON line per event in `<cache dir>/hook.log`, with counts only: the category, the raw
tokens, the tokens sent to the model when it was replaced, the decision and its reason, how the
replacement was made (`grouped` or `selected`), the backend when a model was asked, the time taken, and for a backend failure the condition's type
(`summarizer-timeout`, `summarizer-exit` or `summarizer-bad-reply`). To see your own rejection
rate:

```sh
grep -c '"decision":"replace"' ~/.cache/praxeon-claude-code/hook.log
grep -o '"reason":"[a-z-]*"' ~/.cache/praxeon-claude-code/hook.log | sort | uniq -c
```

## What the measurements show

### With lines copied from the output (#465)

`praxeon/scripts/claude-code-trials.lisp` runs three searches over this repository and asks five
questions of each, fixed before any model run: the lines at 10%, 30%, 50%, 70% and 90% of the
output, each phrased as the question that line answers. A question counts as answered when its
line is in the replacement, whole. Without `PRAXEON_CC_TRIALS=run` the script calls no model.

The searches were chosen to be eligible and inside the band the hook acts on. #454's two
searches no longer are: on the tree of 2026-10-24, `rg -n "defun %" mnemosyne hyperion` printed
67,063 characters, which Claude Code would save to a file, and `rg -n -i windows docs` was
passed through as `credential`. Of 18 searches inside the band tried for the trials, 14 were
passed through as `credential` (two of those judged by a grep for the rule's markers rather than
by the rule itself) and 4 were eligible. The 14 contain the words `secret` (the `aion/secret`
module), `credentials`, `machine` or `_token`, which the rule treats as credentials. On this
repository the credential rule, not the replacement, decides most of what the hook can touch.

Offline results, macOS, at commit 4126aea:

| search | size | how it was replaced | sent | questions answered |
|---|---|---|---|---|
| T1 `rg -n "defun %" klio mnemosyne/src` (24 files) | 4,165 tokens | grouped | 1,869 tokens | 2 of 5 |
| T2 `rg -n -i webview hyperion/docs docs` (21 files) | 4,285 tokens | grouped | 1,824 tokens | 1 of 5 |
| T3 `rg -n -i spinneret hyperion` (46 files) | 5,668 tokens | does not group within the budget; needs the model | | |

Grouping is accepted every time, since it can only copy lines, but it keeps each file's first
lines, so a question about a line further down a file is not answered from it. The main model
then has to read the archived original, which the header names. The model's selection on all
three searches has not been run yet: it uses the Claude Code login of whoever runs the script,
and the maintainer decides when that happens.

### With a list of facts (#454, replaced by #465)

From one machine (WSL2, Claude Code 2.1.270, the `claude` backend with Sonnet at medium effort),
on 2026-09-30. They are a starting point rather than a result.

**The hook acts on a narrow band of sizes.** It replaces nothing under 3,500 tokens (about
14,000 characters), and Claude Code itself saves an output of about 30,000 characters or more to
a file and shows the model a preview of about 2,000 (`persistedOutputPath`), which the hook
passes through. In a real session a 7,476-token search output was already saved that way, and
the hook logged `persisted`. So what the hook can replace is a search output of roughly 14,000 to
30,000 characters.

**The check refuses most summaries.** Two real searches, a 7,641-token `rg -n "defun %"` listing
over mnemosyne and hyperion and a 3,869-token `rg -n -i windows docs`, each summarized
repeatedly, with the facts bounded in the schema (at most 20, of at most 300 characters):

| round (check as of) | listing: accepted | docs search: accepted | why the refused ones were refused |
|---|---|---|---|
| before the review's fixes | 0 of 4 | 1 of 3 | over budget; `src/handler_N.lisp`, `L26`, `macOS/Linux` |
| after the review's fixes | 0 of 1 (1 call failed: `summarizer-exit`) | 0 of 3 | `.lisp`, `19-21`, `build/pass` |
| after reading ranges and extensions | 0 of 2 | 0 of 3 | `*.lisp` (from the command), `clean-room` (the output has `Clean-room`), `./scripts/setup.sh` after `path:line:` |
| after reading the command, case and `path:line:` | 1 of 2 (960 tokens for 7,641) | 0 of 3 | `mnemosyne/tests/`, `source-registry`, `fresh-clone`, `libs/1` |
| final | 0 of 2 | 0 of 3 | `update/signature-verification`, `updates/staging`, `Clack-Hunchentoot`, `built-in` |

The refinements between rounds made the check read a line range as its numbers, an extension
as an extension, a glob from the command as real text, a hyphenated word without regard to
case, a name after `path:line:` as on a boundary, and a trailing `/` as the directory. The
refusals in the final round are all names the output does not contain: invented paths, and words
the model joined or hyphenated itself. Summaries were 640 to 1,033 tokens, 73% to 92% smaller.

In every refused case the original went through, and in the real sessions the main model
answered from it. The check refuses often. A refused summary costs the second model's call and
nothing else; an accepted wrong one would cost a wrong answer later.
