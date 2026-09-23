# ADR-0001 — What happens when a content file fails to load

**Status:** Accepted — 2026-09-18 by the maintainer. Question 2 of
[#359](https://github.com/codelisperer/ouranos/issues/359).

## Context

klio loads markdown with front-matter from a git tree into the running image, and reloads it
when the tree changes. Some file will fail to parse. A date will be malformed, front-matter
will have a syntax error, a required field will be missing.

Two things have to be decided together, and deciding them apart is what produced the first
two options below.

1. **What happens to the rest of the site when one file fails.**
2. **Whether a reload is atomic** — whether a request can see a tree that is half old and
   half new.

The second is not a detail of the first. It determines whether the first has one answer or
two.

## The deployment model decides more of this than it looks

`docs/launch/sites-and-cms.md` §6 leaves open how content reaches production: a git push that
triggers a rebuild, or a running image that pulls and hot-reloads. It leans to the second.

Under the second, **a deploy and a reload are the same event**. The image is long-lived.
Publishing is a pull plus a reload. Any policy written for "boot" does not run when content is
published, because nothing boots.

## Decision

**Option C.** One rule: validate the whole candidate tree, and if any file fails, do not swap
and report the file and the reason. At boot there is no previous tree, so that means refusing
to start. At reload the site keeps serving the last good tree. Dev mode is the exception —
skip the bad file, report it, carry on.

## Options

### A. Refuse at boot, skip at reload

Refuse to start if any file fails. On reload, keep the last good version of the failing file,
report it, and carry on.

- A running site does not go down for a typo in one post.
- A deploy that cannot load its content fails where someone is watching.
- **This is the option that does not survive the deployment model.** If a deploy is a reload,
  the reload path is what runs when content is published, and that path skips the bad file and
  carries on. The result is a deploy that silently ships without the newest page — the exact
  outcome the boot half was written to prevent. The boot half never executes.

### B. Refuse in both cases

Any file that fails stops the site, at boot and at reload.

- One rule, no gap.
- A typo in one post takes down a running site that was serving fine a second earlier. The
  cost falls on readers, for an error that affects one page.

### C. Validate the whole tree, swap all or nothing *(recommended)*

One rule:

> Validate the whole candidate tree. If any file fails, do not swap. Report the file and the
> reason.

The two outcomes follow from the situation rather than from a second policy:

- **At boot** there is no previous tree, so "do not swap" means refusing to start, naming the
  file.
- **At reload** it means the site keeps serving the last good tree and stays up.

A deploy cannot fall through a gap between two policies, because there is one policy. The
atomicity guarantee is what makes this work: a request sees the old tree or the new one, never
a mixture.

**Dev mode is the documented exception.** Skip the bad file, report it, keep going. Someone
editing wants to see the rest of the page they are working on, and no reader is affected.
Part 2 of #359 already carries a dev-mode flag, so this needs no new concept.

## Consequences of C

- **A reload that reports errors has to be a failed deploy.** If the deploy script pulls,
  reloads, sees the error on stdout and exits zero, the silent partial deploy returns in a
  different place. Whatever ships the deploy path owns this.
- Validation happens before the swap, so loading is two passes over the tree: parse and
  validate all candidates, then publish. On a content tree of a few hundred files this is not
  a cost worth optimising.
- One bad file blocks the publication of every good file in the same reload. That is the
  point, but it should be said plainly: an author fixing a typo is also unblocking everyone
  else's changes in the same pull.
- The report must name every failing file, not the first. Fixing one file and re-running to
  find the next one is a bad loop to put an author in.

## Not decided here

Whether §6's deployment question resolves to pull-and-reload or to push-and-rebuild. This ADR
is written so that C is correct either way: under push-and-rebuild, boot and deploy are the
same event and C still refuses to start on a bad file.

## Provenance

Written by Ouranos Claude (macOS) as Q2 of #359. Options A and B are the two originally
written down. **Option C came from the hub's review**, which found that A assumes boot and
deploy are different events and that the deployment model in the design doc makes them the
same. A is kept here rather than dropped, because the failure is not obvious and the next
person to reason about this will propose it again.
