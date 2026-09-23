# Cons Roadmap — moved

This file no longer holds the roadmap. It was split in two so each half lives where it
belongs:

- **The work** — every feature, task, research question, and open item — is now **GitHub
  issues**, tracked on the [Ouranos Roadmap board](https://github.com/orgs/codelisperer/projects/1).
  Filter to this framework:
  [`label:pkg:cons`](https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Acons%22).
  The board carries **Package**, **Kind**, **Status**, **Priority**, and **Size** fields; the
  `epic`, `design`, `research`, `infra`, and `coalton` labels cut across packages.

- **The reasoning** — the design narrative, trade-offs, rejected alternatives, and open
  questions that used to live here — moved to the narrative home:
  [`docs/wiki/Framework-Cons.md`](../../docs/wiki/Framework-Cons.md).

Why: roadmap files drifted from reality, collided across parallel sessions, and buried
actionable work inside prose. Issues stay current and filterable; the narrative stays readable.

New work goes in an issue (`gh issue create --label ai-task,pkg:cons …` for AI/system tasks —
see [`AGENTS.md`](../../AGENTS.md)). Durable design reasoning goes in the wiki page.
