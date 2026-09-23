# Blog drafts

Posts are **written here and published on Hashnode** — see the writing decision in
[`../launch/sites-and-cms.md`](../launch/sites-and-cms.md) §0. `codelisperer.org` is a docs and
community site, not a blog engine; it may link to posts but must not duplicate them.

Convention:

- One file per post, `YYYY-MM-DD-slug.md`.
- YAML front matter (`title`, `date`, `status`, `tags`, `summary`, `series`, `canonical_url`) so
  a draft ports to Hashnode, a static generator, or a Hyperion-served page without rework.
  `status: draft` until published; add `url:` when it is.
- **`series` is a field, not a vendor feature.** Two Hashnode series ("Diary of a CONS Artist",
  "Getting Hy on Python") vanished when the plan or the platform changed — because the grouping
  lived in someone else's database. In this model a series is a string in front matter: it
  cannot evaporate, it survives a change of publisher, and it can be rebuilt anywhere from
  `grep`.
- Drafts are drafts. They are kept in git for the same reason the design docs are — so the
  reasoning survives a new machine and a fresh session.
- **Claims must be real.** Every number in a published post should be traceable to something we
  measured (`hyperion/bench/`, a CI run, an ADR). No rounded-for-effect figures.
