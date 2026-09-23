# Launch

The public-release track: what ships, when, how it is positioned, and how it is
evangelized. Everything here is **pre-publication** — this directory is exactly the
material that must be swept before the repo goes public.

The work items live where all work lives — GitHub issues on the
[Roadmap board](https://github.com/orgs/codelisperer/projects/1), label `area:launch`.
This directory carries the *reasoning*, in the house docs-as-handoff style.

| Doc | What it settles |
|---|---|
| [`release-scope.md`](release-scope.md) | What the first public release covers, what it promises, and the blockers that gate any version of it |
| [`open-questions.md`](open-questions.md) | Triage/merge/sequence over the open design questions, plus go-live criticality per instance |
| [`onboarding.md`](onboarding.md) | Zero to productive, for experienced engineers with a parenthesis allergy |
| [`sites-and-cms.md`](sites-and-cms.md) | The three web properties and the CMS engine behind them |
| [`docs-review-plan.md`](docs-review-plan.md) | A resumable test plan for reading all 139 docs + 6 papers before publication |

## Standing constraints

- **The confidentiality rule survives publication.** Per [`AGENTS.md`](../../AGENTS.md),
  no private consuming app or client is named anywhere in this repo — and once the repo
  is public, commit messages and issue text cannot be redacted. Any sweep must cover
  history and issues, not just the working tree.
- **Marketing copy is subject to the same honesty standard as the docs.** If a claim
  cannot survive a reader running the command, it does not ship. The credibility gaps
  inventoried in `release-scope.md` §2 exist because claims drifted ahead of code once;
  the launch track is where that gets caught, not created.
