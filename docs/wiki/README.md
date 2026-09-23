# docs/wiki — the narrative home

The **whole kit and kaboodle**: onboarding, the ecosystem story, and the per-framework design
narrative. Start at [Home](Home.md).

These pages are written as **GitHub Wiki pages** and named accordingly (`Home.md`,
`Framework-Aion.md`, …). They live in the repo rather than the wiki for one reason: GitHub
does not offer wikis on **private** repositories under a Free-plan org. If this repo ever goes
public — or the org moves to Team — publishing is a single push of this folder to
`ouranos.wiki.git`, because the filenames already match wiki page names. Only this `README.md`
is repo-specific and would be left behind (a wiki's front page is `Home.md`).

Internal links are written as relative markdown (`[Getting Started](Getting-Started.md)`) so
they work on GitHub *and* survive the move — the wiki resolves them the same way.

## What lives where

| Surface | Holds |
|---|---|
| **`docs/wiki/`** (here) | Narrative: why things are the way they are, design reasoning, trade-offs, rejected alternatives, onboarding. |
| **GitHub issues + [the board](https://github.com/orgs/codelisperer/projects/1)** | Everything actionable — features, tasks, bugs, research questions. Filter by package with the `pkg:*` labels. |
| **Repo `docs/`, `*/docs/`, ADRs, `papers/`** | Specs and records that must version with the code: ADRs, design specs, dependency manifests, whitepapers. |
| **`README.md` / `CLAUDE.md` / `AGENTS.md`** | The short, always-loaded constitution for humans and AI assistants. |

The rule of thumb: **if it is a decision or a story, it belongs here; if it is work to be done,
it belongs in an issue; if it is a contract the code must honour, it stays beside the code.**
