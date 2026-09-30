# ADR-0002 — How a running site is told to reload its content in production

**Status:** Proposed — 2026-09-29. Recorded for #353, and not built. The hub ruled on #353
that the production trigger is built when a deployment first reloads content at runtime.

## Context

In development, `watch-site` reloads a site when a file in its content directory changes
(#353). Production needs something else. Content reaches a production server from outside the
process, for example by a `git pull` on the server, and the process then has to be told to
reload. Polling the directory would work there too, but it reloads whenever a file changes,
including halfway through a pull, and a deploy wants one reload after the pull has finished,
with a result it can act on. ADR-0001 says why: a reload that reports errors has to be a failed
deploy, which is what `reload-or-fail` is for.

Whether production needs a runtime reload at all is not decided. The personal site's hosting is
still open with the maintainer, and the products PM expects a CI build that bakes the content
into the image and replaces the process, which needs no reload. This record exists so that the
choice below is made once, with its reasons, when a deployment does need one.

## Options

### A. An HTTP endpoint that requires a secret

`POST /-/reload`, answered only when the request carries a secret the site was configured with,
compared in constant time. It calls `reload-or-fail` and answers 200 with the number of
documents, or 409 with the files that failed and why. The site keeps serving the last good
tree either way.

- A deploy script, a CI job or a git hook on another machine can call it, with `curl`.
- The response carries the outcome, so the caller can fail the deploy on a 409, which is
  ADR-0001's first consequence.
- It is a network surface. A secret that leaks lets anyone make the site reload, which costs
  CPU but publishes nothing that is not already in the content directory. The endpoint must be
  rate limited (`hyperion/ratelimit`) and must never be served in development mode's absence of
  a configured secret: no secret configured means no endpoint at all, not an open one.
- The path must not collide with a content key. A key cannot start with `-/`, because content
  files are named by their path, so reserving `-/` for the engine is safe.

### B. A signal the process handles

`SIGHUP` makes the process call `reload`. The deploy runs `kill -HUP <pid>` or
`systemctl reload <unit>` after the pull.

- No network surface, and nothing to configure.
- The caller does not learn the outcome. A signal handler cannot answer, so a refused reload is
  only in the log, and a deploy script that sends the signal and exits zero is the silent
  partial deploy ADR-0001 exists to prevent. Closing that gap needs a second channel, such as
  a status file the process writes after each reload and the deploy script reads, which is
  most of the work of option A done a second time.
- Only a process on the same machine, with the right to signal it, can trigger it.
- Windows has no `SIGHUP`, and hyperion's signal handling is already backend-dependent: on Woo
  a supervisor's SIGTERM is not delivered (`hyperion/docs/signals-and-shutdown.md`).

### C. No runtime reload: the content is in the image

The deploy builds an image containing the content and replaces the running process. `boot`
already refuses to start on a bad tree, so a bad deploy fails before the new process serves
anything, as long as the deploy waits for the new process to answer before retiring the old one.

- Nothing to build in klio.
- Every content change is a full build and deploy, which is slower than a pull and a reload.
- It is what the products PM expects for the personal site.

## Recommendation

C while the personal site deploys by building an image. When a deployment first pulls content
into a running process, build A: it is the option whose caller learns the outcome, which is the
property ADR-0001 requires of a deploy, and B would need a status channel to reach the same
place. Record the choice by changing this ADR's status then.
