# praxeon-claude-code: a report on tool-output tokens, and a hook that summarises large search outputs

`praxeon-claude-code` is an executable built from `praxeon/claude-code` (#452). It has two
commands:

- **`report`** reads your Claude Code session transcripts and prints how much of what your
  sessions read came from large tool outputs, and how much of that the hook would replace. Run
  it first: whether the hook is worth installing depends on your own sessions.
- **`hook`** is a Claude Code `PostToolUse` hook. When a search command or an MCP tool returns
  a large output, it asks a second model for a short list of facts from it, checks the list
  against the output, and replaces what the main model reads with the list and the path of the
  saved original. When anything goes wrong it prints nothing, so the original output goes
  through unchanged.

## Why a large output costs more than its size

A tool result stays in the conversation. Every later model call reads it again, usually from
the prompt cache, until the session compacts or ends. So a 30,000-token search result read by
the next 80 calls costs 2.4 million cache-read tokens, and replacing it with a 1,500-token list
removes most of that. How much this saves depends entirely on how often your sessions produce
large search outputs, which is what `report` measures.

## Building

From the repository root:

```sh
sbcl --non-interactive --load praxeon/scripts/build-claude-code.lisp
```

This writes `bin/praxeon-claude-code`, a saved SBCL image (about 95 MB) that starts in about
10 ms. It needs no SBCL or Quicklisp to run. The image is saved uncompressed on purpose: a
compressed image is decompressed on every start, and the hook starts once per matching tool
call.

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
  largest summary it accepts, how many fewer tokens the later calls would read, as a share of
  all their input-side tokens;
- why the large outputs the hook would not replace were passed through;
- the categories most read again: the tool's name, or `Bash:` and the command's first word.

It prints no text of any message or result and no path, including the project directories'
names.

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
- a Bash command whose first word is not a search (`rg`, `grep`, `find`, `fd`), and a search
  with any of `cat`, `sed`, `head`, `tail`, `git`, `gh`, `diff`, `jq` and similar in its pipeline;
- outputs under the threshold (3,500 tokens by default);
- a failed or interrupted command, and anything that wrote to stderr;
- an output containing a diff;
- an output that looks like it carries a credential (a private key, a token prefix such as
  `ghp_` or `sk-ant-`, `password=`, `Authorization:`, and similar). Such an output is never sent to
  the second model;
- an output carrying a SHA-like token (7 to 64 hexadecimal characters with both digits and
  letters) or a run-id-like one (10 or more digits). In this repository that keeps gate output,
  CI logs and `git log` out even when a search is run over a saved copy of them, because
  AGENTS.md requires SHAs and run ids to be read from the raw output.

## The check on the summary

The second model's list is refused, and the original passes through, when:

- any file path, identifier-shaped token (with `_`, `::`, a dot between names, letters and
  digits together, or camelCase) or hexadecimal identifier in it does not occur verbatim in the
  raw output, or any run of digits in it does not occur there as a whole run;
- it is over the size budget (1,800 tokens by default);
- it is less than 30% smaller than the original.

Markdown's backtick and asterisk are ignored on both sides, a possessive `'s` is removed, and
`name:line` is checked as the name and the number separately. Nothing else is relaxed.

What the check does not catch: a real name, path or number attached to the wrong thing. A line
number is refused when it occurs nowhere in the output, not when it occurs only beside another
path. It catches invention, not misattribution.

The replacement starts with one line saying it is a summary, its size, the model that wrote it,
and where the original is:

```
[praxeon-claude-code: a summary of 3,868 tokens of output in 812 tokens, written by claude-sonnet-5-5. The full output is in /home/you/.cache/praxeon-claude-code/archive/<sha256>.txt]
- docs/ci.md:7 says ...
```

## Settings

All environment variables, so they can be set in the hook's `command`:

| variable | default | meaning |
|---|---|---|
| `PRAXEON_CC_BACKEND` | `claude` | `claude`: the `claude` CLI in print mode, which uses your Claude Code login. `praxeon`: a `praxeon/llm` provider resolved with the role `compressor` (`PRAXEON_COMPRESSOR_*`, falling back to `PRAXEON_LLM_*`), for the Anthropic API with a key or an OpenAI-compatible server, including a local one |
| `PRAXEON_CC_MODEL` | `sonnet` | the model, for the `claude` backend |
| `PRAXEON_CC_EFFORT` | `medium` | the effort, for the `claude` backend |
| `PRAXEON_CC_CLAUDE` | `claude` | the `claude` program |
| `PRAXEON_CC_THRESHOLD` | 3500 | outputs under this many tokens pass through |
| `PRAXEON_CC_SUMMARY_BUDGET` | 1800 | the largest summary accepted, in tokens |
| `PRAXEON_CC_TIMEOUT` | 90 | seconds the summarizer may take; set the hook's own `timeout` above it |
| `PRAXEON_CC_ARCHIVE_DAYS` | 7 | archived originals older than this are deleted |
| `PRAXEON_CC_CACHE_DIR` | `$XDG_CACHE_HOME/praxeon-claude-code/` or `~/.cache/praxeon-claude-code/` | the archive and the log |

The `claude` backend's call cannot run this hook, a tool or an MCP server:
`claude -p --tools "" --strict-mcp-config --no-session-persistence --setting-sources ""
--settings '{"disableAllHooks": true}'`, with `--json-schema` for the list and
`CLAUDE_CODE_PROMPT_CACHE_TTL=5m`, since a one-shot call never reads a longer-lived cache back.
`--bare` is not used because it ignores the Claude Code login.

## The log

One JSON line per event in `<cache dir>/hook.log`, with counts only: the category, the raw
tokens, the tokens sent to the model when it was replaced, the decision and its reason, the
backend, the time taken, and for a backend failure the condition's type
(`summarizer-timeout`, `summarizer-exit` or `summarizer-bad-reply`). To see your own rejection
rate:

```sh
grep -c '"decision":"replace"' ~/.cache/praxeon-claude-code/hook.log
grep -o '"reason":"[a-z-]*"' ~/.cache/praxeon-claude-code/hook.log | sort | uniq -c
```

## What the first measurements show

These are from one machine (WSL2, Claude Code 2.1.270, the `claude` backend with Sonnet at
medium effort), on 2026-09-30, and are a starting point rather than a result.

- On a 7,656-token `rg -n "defun %"` listing over two frameworks, four attempts were all
  refused: twice over the budget (4,280 and 2,870 tokens), and twice for tokens not in the
  output, including a placeholder path `src/handler_N.lisp` and line numbers written as `L26`.
- On a 3,868-token `rg -n -i windows docs`, with the facts bounded in the schema (at most 20, of
  at most 300 characters), the summaries were 790 to 930 tokens. One of the last three attempts
  was accepted; the other two were refused for words the model joined with a slash, such as
  `macOS/Linux`, which the output writes as `macOS / Linux`.
- In every refused case the original went through, and the main model answered from it.

The check refuses often. A refused summary costs the second model's call and nothing else,
because the original goes through; an accepted wrong one would cost a wrong answer later.
