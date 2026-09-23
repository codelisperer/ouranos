# Versioning and pinning

*How Ouranos names a version of itself, and how a consuming app pins a coherent set of
everything underneath it. 2026-07-29 — a proposal, not yet decided; it depends on Ouranos
having a version number, which pre-publication issue 91 has
not yet settled.*

---

## The problem

`coalton.pin` fixed one axis: which Coalton commit the tree is built against. But a Coalton
SHA is only meaningful **against the version of Ouranos that corresponds to it**. Upgrading
an app's Ouranos should move its Coalton too, and today nothing couples them.

The state that motivates this is not hypothetical drift — it is measured:

- `scripts/versions.env` declares `SBCL_VERSION=2.6.6`. The macOS dev machine runs
  **2.6.5**, and did so through a full tree rebuild and two green verification passes. A
  declared version that nothing checks is decoration.
- Every framework `.asd` says `:version "0.0.0"` — except `praxeon`, which says `0.0.1`.
  Neither number means anything.
- **Ouranos has no version and no git tags.** There is nothing for an app to pin.
- Consuming apps therefore each hardcode a Coalton SHA in their own build files, which is
  the drift `coalton.pin` exists to prevent, one level out.

## Where Common Lisp is actually behind

Worth splitting, because the ecosystem is weak in one half and adequate in the other — and
the design should lean on the adequate half.

**Family (a) — solver + lockfile.** Cargo, npm, Bundler, Poetry/uv. Declared *ranges* → a
resolver → an exact lockfile. This requires a registry with **trustworthy version metadata**,
and CL does not have one. Coalton reports ASDF `:version` `0.0.1` for every commit in the
range we care about (see [`coalton-upstream.md`](coalton-upstream.md)); ASDF supports
`(:version …)` constraints and almost nobody honors them rigorously. A solver with nothing
reliable to solve over is theatre.

**Family (b) — curated snapshot / resolver.** Stack's LTS resolvers, Nix flakes, and
**Quicklisp dists**. One name resolves to a large set of mutually-tested versions. No ranges,
no backtracking, no conflict explanation — a human curates the set and CI proves it.

**We already do (b) without naming it.** `QUICKLISP_DIST=2026-01-01` *is* a resolver;
`coalton.pin` is the one thing outside it. The gap is not a missing lockfile. It is that
nothing binds those to a version of Ouranos.

## The decision: Ouranos publishes the combination; an app pins one thing

The tempting shape is a `dependencies.pin` in each app listing compatible combinations.
**Invert it.** A release of Ouranos ships a manifest:

```
ouranos     0.1.0
coalton     7915fad0        repo: coalton-lang/coalton
quicklisp   2026-01-01
sbcl        >= 2.6.5
```

and an app's lock is one line — `ouranos 0.1.0` — with `cons` resolving the rest
transitively.

Three reasons this beats per-app combination files:

1. **The combination is knowledge Ouranos has and an app does not.** Here it is *tested* by
   Ouranos CI; in an app it is an assertion nobody verifies — which is exactly what
   `versions.env` is today.
2. **An app's lock stays one line.** Adding a fourth pinned thing later — libuv
   ([#84](https://github.com/codelisperer/ouranos/issues/84)), a database engine — touches
   zero apps.
3. It is the **Stack-resolver** model, which is the one that works in a language without
   reliable version metadata: a human curates, CI proves, consumers name.

`coalton.pin` becomes one line of this manifest rather than a separate file, so the two
numbers **cannot** be updated independently.

### SBCL is an axis, and it is the one already drifting

Almost certainly a **floor** (`>=`) rather than an exact pin — forcing an exact SBCL is
hostile to contributors and to distro packaging. But a floor that something actually checks,
which `versions.env` currently is not.

## What this forces

**Ouranos must version itself.** No version, no tags today; there is nothing to pin. This is
a hard prerequisite and it belongs to
pre-publication issue 91 (release scope) — `0.1.0`.

**Co-versioned, not independent.** The thesis already answers this: *"few, cohesive,
**co-versioned**, house-owned."* One Ouranos version; the frameworks inherit it. The stray
`praxeon 0.0.1` is the argument for doing it now rather than later, while there is exactly
one inconsistency to clean up.

Independent per-library release stays possible via the `git subtree split` mirrors already
noted in [`../ECOSYSTEM.md`](../ECOSYSTEM.md) — but that is an escape hatch, not the model.

## What we should *not* build

`cons/CLAUDE.md` currently plans "a native `cons` backend later (real version resolver +
lockfiles) that eventually makes both obsolete."

**Resist that.** A real resolver is a large, subtle piece of engineering — backtracking,
yanked versions, comprehensible conflict messages — and its value scales with the size of an
independently-versioned third-party ecosystem with good metadata. Ouranos deliberately holds
its external surface to **21 libraries** and treats that minimalism as a feature. The
snapshot model delivers nearly all the benefit at nearly none of the cost.

**ocicl** already does per-project lockfiles and is the documented direction in
`ECOSYSTEM.md`; **qlot** is the Bundler-shaped alternative. Borrow before building. *"`cons`
is the unified front-end over CL's fragmented tooling"* is a stronger and more defensible
claim than *"`cons` has its own resolver"* — and it is the claim `cons/CLAUDE.md` already
makes everywhere else.

## Security updates for a pinned native

Pinning answers *"which version does this tree build?"*. It does not answer *"is that
version still safe?"*, and for a native library those are different questions with
different failure modes. `libuv.pin` and `coalton.pin` were written for the first one,
because libuv's cadence is sleepy and Coalton has no network surface.

**That stops being enough the moment the tree vendors a crypto library.** A TLS
implementation publishes security releases several times a year, and upgrading is the easy
part — *noticing* is the hard part. A pin that nobody revisits is not a decision that keeps
holding; it is a decision that was true once.

### The rule

**Every `*.pin` declares two fields beyond the version:**

```
advisories https://github.com/libuv/libuv/security/advisories
reviewed   2026-09-15
```

- **`advisories`** — where a human goes to learn that what we build has a hole in it. It
  lives in the pin because the answer is per-library, and looking it up under time pressure
  is exactly the wrong moment to be searching.
- **`reviewed`** — the date somebody last read that page. This is the only thing that
  distinguishes *"no advisory affects us"* from *"nobody has looked"*. From outside those
  two states are identical, and only one of them is fine. **Bump it when you look, even —
  especially — when the answer is "nothing to do".**

`scripts/check-pins.lisp` enforces the fields' presence and is wired into CI. No pin is
exempt: Coalton carries them too, not because it is dangerous but because a pin that opts
out is a pin nobody reviews, and an exemption outlives the reasoning that justified it.

### What is checked mechanically, and what deliberately is not

| | checked | why |
|---|---|---|
| fields present | **fails the build** | deterministic, and only changes when somebody edits a pin — so the failure is attributable to the commit that caused it |
| review age | **reported, never fails** | `--report` prints the age and shouts past 180 days |
| upstream newer than us | **not here** | needs the network |

**Age is deliberately not a build failure.** A check that goes red because a date passed
turns an unrelated PR red on a calendar boundary, and a build that breaks for reasons its
author did not cause is a build people learn to ignore — which costs more than the check
was ever worth.

**The "is upstream ahead of us?" question needs the network**, so it does not belong in a
gate that must be reproducible offline. It belongs in a scheduled job that opens an issue,
which is a thing to build when there is a pin whose cadence justifies it.

### Adopting a new version of a vendored native

`libuv.pin` carries the library-specific steps. Two general ones are easy to miss:

1. **Re-check the transcribed source list.** `scripts/build-libuv.lisp` compiles a list of
   `.c` files copied by hand from upstream's build files — its own header says *"Transcribed
   from libuv's CMakeLists.txt … Verified against 1.52.1."* A new release can add, remove or
   move sources, and the failure mode is not a build error: it is a library missing a file
   it needed, or built without a feature it should have had. **The list is version-specific
   and must be re-verified on every bump**, not just when the build breaks.
2. **Bump `reviewed` in the same commit.** You have just read the release notes; that is the
   review. Leaving it stale after an upgrade is the one moment the field is guaranteed wrong.

### Why the checksum is not the whole story

`libuv.pin` records a sha256 as trust-on-first-use, which turns a silent substitution into a
loud failure. That is integrity, not currency: **a pin can be perfectly verified and
perfectly vulnerable.** The sha256 proves we got the bytes we expected; `reviewed` is the
only field that says anybody asked whether those were still the bytes to want.

## Sequencing

1. **Settle the Ouranos version** — pre-publication issue 91.
   Nothing here can start before it.
2. Publish the manifest from Ouranos; fold `coalton.pin` and `versions.env` into it, so no
   number lives in two files.
3. Make the check real: `setup --check` / `check-coalton.lisp` verify **every** axis,
   including the SBCL floor.
4. `cons` reads the manifest and scaffolds an app lock — the `cons setup` job already
   implied by the ASDF `(:tree)` drop-in generalization.
5. Evaluate ocicl and qlot **before** any native resolver work
   ([#32](https://github.com/codelisperer/ouranos/issues/32)).
