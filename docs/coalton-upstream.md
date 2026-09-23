# Tracking Coalton upstream

*How Ouranos stays current with `coalton-lang/coalton`. Aion owns this relationship —
it is the framework closest to the language, and the one whose scope shrinks every time
upstream closes a gap.*

## The setup, and why it matters

Coalton is **not** consumed as a Quicklisp release. It is a **git checkout** at
`~/common-lisp/coalton`, tracking `main` from `git@github.com:coalton-lang/coalton.git`.

That is the right choice — Coalton moves fast, and a Quicklisp dist would leave us months
behind — but it makes currency a *decision we make*, not one made for us. Drift is
silent: nothing warns you that a gap you are about to spend a week filling closed
upstream last month.

That is not hypothetical. The founding gap analysis listed **`Monoid` as a genuine gap**
and scoped work to build it. `Monoid` is in `library/classes.ct`, with `mempty`,
`mempty?`, `mconcat`, `mconcatmap`, and instances across ten modules. Nobody had
re-checked in the interval. **A stale gap list is a plan to write code that already
exists.**

## The cadence

**Check monthly, and before starting any Aion module.** The second half matters more than
the first: the moment before you build a gap-fill is exactly when the gap list needs to be
true.

```bash
cd ~/common-lisp/coalton && git fetch origin && git log --oneline HEAD..origin/main
```

## Triage — adopt fast, but classify first

Default to **adopting promptly**. Falling behind compounds: the longer the gap, the larger
the diff, and the harder it is to attribute a breakage. Waiting needs a reason.

| Class | Examples | Action |
|---|---|---|
| **Additive** | new instances, new library functions, new modules | **Adopt immediately.** Cannot break us; may close a gap. |
| **Fixes** | compiler bug fixes, type-checker corrections | Adopt promptly. Note that a *fix* can surface a latent error in our code that previously compiled — that is a real find, not a regression. |
| **Behavioral** | changes to inference, representation, or optimization | Adopt deliberately: rebuild the tree, run all suites, in **both** compilation modes. |
| **Breaking** | removed/renamed exports, changed signatures | Read the diff first, then adopt on a branch with the call-site fixes in the same commit. |

Good reasons to wait — they should be recorded, not just felt:

- A framework is mid-refactor and a rebuild would confuse attribution.
- The commit is explicitly marked experimental upstream.
- It lands during a release freeze.

"We haven't got around to it" is not one, and is how eighteen days becomes eight months.

## Two traps when verifying a pin

Both were hit independently by different sessions, which is why they are written down rather
than left as folklore.

**1. Coalton's ASDF `:version` is useless as an identifier — always compare the git SHA.**
`(asdf:component-version (asdf:find-system :coalton))` reads `VERSION.txt`, which has been
`0.0.1` across every commit in the range we care about. It returns `0.0.1` for the old pin
and the new one alike. Anything asking "are we on the right Coalton?" **must** compare commit
ids, and [`scripts/check-coalton.lisp`](../scripts/check-coalton.lisp) does. Do not later
"simplify" it into a version check — it would pass unconditionally and verify nothing.

**2. A local `--platform linux/amd64` container build on Apple Silicon proves nothing.**
It runs under QEMU, which mis-emulates SBCL's compile-time 64-bit overflow folding and
produces **spurious** failures in `library/math/bounded` — *"Signed value overflowed 64
bits."* The failure is an emulation artifact, not a real incompatibility, so a red local
amd64 build is not evidence against a pin and a green one is not evidence for it. **The only
meaningful amd64 gate is a native run** (GitHub Actions `ubuntu-latest`) — see
pre-publication issue 87.

## Where a pin has and has not been validated

A pin is only as blessed as the architectures it has actually been built on. Track this
honestly; "it works" usually means "it works where I happened to run it."

| Pin | arm64 macOS | WSL / Windows | **native amd64** |
|---|---|---|---|
| `7915fad0` | ✅ 506 checks, whole tree · ✅ 583 checks incl. a consuming app, cold rebuild from a cleared fasl cache (~86s) | ✅ suites green | ❌ **never** |

The amd64 gap closes when pre-publication issue 87 lands,
and until then no pin should be described as fully validated.

## Consuming apps (separate repos)

**Unsolved.** Apps that consume the frameworks live in their own repos and currently each
hardcode a Coalton SHA in their own build files — which is the same drift the pin exists to
remove, one level out. `coalton.pin` is authoritative *inside* Ouranos; a consuming repo
needs a way to read it rather than copy it, analogous to how it already onboards with its own
ASDF `(:tree)` source-registry drop-in (see [`../ECOSYSTEM.md`](../ECOSYSTEM.md)). Generalizing
that is naturally `cons setup`'s job. Until then, a consuming app copying the SHA should at
least cite this file as the source.

Related: apps have needed a **source-registry shadow** so ASDF resolves `:coalton` to the
pinned checkout rather than a Quicklisp dist release. That is the same hazard
`check-coalton.lisp`'s provenance check exists to catch, found independently from the app
side — the scaffolding should emit the shadow pattern by default rather than have every app
re-derive it.

## After adopting

1. Rebuild from scratch — `bootstrap.lisp`, then load every system. Coalton compiles
   slowly; a stale fasl cache produces confusing failures. Clear `~/.cache/common-lisp`
   when anything looks impossible.
2. Run every framework's fiveam suite.
3. **Re-audit the gap list** — `aion/docs/coalton-gap-analysis.md`. Any gap that closed
   upstream is work Aion should *delete from its plan*, and that deletion is the single
   highest-value output of this whole process.
4. Record the new upstream SHA in the gap analysis header.
5. If anything broke, note it in the decisions log — a pattern of breakage is an argument
   for pinning, and we should only make that argument from evidence.

## Keeping machines in sync — the pin

A git checkout means **every machine tracks upstream independently**. With work happening
on macOS and Windows simultaneously, that is a live reproducibility hazard: two machines
on different Coalton commits produce "works on mine, not on yours" with no visible cause,
and Coalton is the *compiler* — a divergence there can change typechecking, representation,
or optimization.

Nothing short of vendoring can force two machines to be identical. But **divergence can be
made detectable, and silent divergence is the actual enemy.**

**The mechanism: [`coalton.pin`](../coalton.pin) at the repo root** records the SHA this
tree is built and tested against. Adopting a new Coalton becomes an ordinary commit that
propagates through git like everything else — which is exactly the shape the rest of the
cross-machine brain already has.

The flow:

1. **One machine adopts** — pull, rebuild, run every suite (below), update `coalton.pin`,
   commit.
2. **Every other machine follows the repo** — pull the Ouranos change, see the new pin,
   check its Coalton out to that SHA, rebuild.
3. **Mismatch is loud, not silent** — the build should compare the pin against the actual
   checkout and say so.

Locating the checkout must work on every OS, so **resolve it through ASDF, never a
hard-coded path**:

```lisp
(asdf:system-source-directory :coalton)
```

`~/common-lisp/coalton` on this machine is an accident of setup, not something to encode.

Checking out the pin puts Coalton in **detached HEAD**, which is correct — it makes "we
are on a specific commit, not wherever `main` drifted to" explicit rather than
accidental. Moving forward means fetching and checking out the new pin, i.e. a decision,
which is the point.

## The other direction: contribute upstream

Two Aion threads are better as upstream contributions than as local layers, and both are
identified in [`cl-shell-design.md`](../aion/docs/cl-shell-design.md):

- **Transients** need mutable access to the RRB-tree and HAMT internals, which `Seq` and
  `hashmap` do not expose. Building them outside means vendoring the structures — a fork
  of exactly the substrate the gap analysis says not to reimplement.
- **`break`/`continue` in `experimental/loops`**, and the `return`-refers-to-the-enclosing-function
  wart, are documented upstream limitations rather than things to work around locally.

Upstreaming is cheaper than carrying a fork, and it is the relationship a framework built
*on* Coalton should want with it.

## Status

| | |
|---|---|
| **Pinned** ([`coalton.pin`](../coalton.pin)) | **`7915fad0`** — *Add `Optional` & `Result` instances for `Foldable`* |
| Adopted | 2026-07-29, from `03648698` (18 days of drift) |
| Behind `origin/main` | **0** |

### Adoption record — 2026-07-29

Two commits, both **additive**, fast-forwarded cleanly:

- `c8a9f473` — Define `IntoIterator` instance for `FileStream`
- `7915fad0` — Add `Optional` & `Result` instances for `Foldable`

Diff was three library files (`file.ct`, `optional.ct`, `result.ct`), 65 insertions. The
`Foldable` instances are directly useful — that is the shape elenchon's finding-collection
and mnemosyne's result handling keep reaching for.

**Verification: every system loads, every suite passes.**

| | |
|---|---|
| Systems loaded | **9/9** — aion, aion/csv, aion/log, cons, mnemosyne, elenchon, hyperion, praxeon, hermes |
| Suites passed | **6/6** |
| Checks | **506**, 100% pass, 0 fail (cons 80 · mnemosyne 139 · hyperion 203 · praxeon 52 · hermes 32 · aion) |

No fasl-cache clear was needed — ASDF's dependency tracking handled a purely additive
change. Keep the clear in reserve for behavioral or breaking adoptions.

Note this was verified in **development mode** only; per
[`cl-shell-design.md`](../aion/docs/cl-shell-design.md) §3 a release-mode run would be the
stronger check, and is the one that would catch a representation assumption.
