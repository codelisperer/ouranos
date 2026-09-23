# AGENTS.md — Ouranos (monorepo root)

Tool-neutral conformance for the codelisperer monorepo; `CLAUDE.md` `@`-imports it. Thesis
and decisions: [`ECOSYSTEM.md`](ECOSYSTEM.md). Per-framework specifics: each `*/CLAUDE.md`.
Status: the [Roadmap board](https://github.com/orgs/codelisperer/projects/1) / issues
(`label:pkg:<framework>`). Design narrative: [`docs/wiki/`](docs/wiki/Home.md). The case
history behind every rule below: [`docs/evidence-catalogue.md`](docs/evidence-catalogue.md).

## Dependency DAG

`aion → cons → mnemosyne → elenchon → hyperion → praxeon`, plus the satellites `hermes`,
`hades` and `klio`. **A satellite depends leftward into the line and nothing in the line
depends on it** — that is the whole rule. `hermes` and `hades` attach at `aion`; `klio`
attaches at `hyperion`, which is allowed for the same reason and was the case that forced
this sentence to be widened from "depend only on `aion`". A framework never depends on one
to its right; aux systems may reach right if acyclic. Combined examples live in the highest
framework they need.

## House style

- Typed Coalton core + effectful CL/CLOS shell. No IO in Coalton.
- Pluggable backends behind neutral protocols; recoverable failure via the condition system.
- Small pure functions, effects at the edges, ADTs over booleans.
- Package-per-module; `:local-nicknames` over long prefixes. 2-space indent, no trailing
  whitespace. LF everywhere (`.gitattributes`). SBCL-only.
- No `FORMAT ~<newline>` continuations — a CRLF checkout makes them an illegal directive.
- Logging is `aion/log`, CL shell only: structured fields, counts/ids/durations, never
  payloads; correlation id bound once at the outermost seam. [`docs/logging.md`](docs/logging.md).

## Writing

Write prose that is plain and matter-of-fact. This covers commit messages, pull request
titles and bodies, issue text, docstrings, comments, ADRs and documentation.

- Say what happened and what to do about it. Do not compress an explanation into a phrase
  built to be memorable.
- No aphorisms, no metaphors, no clever one-liners. If a sentence needs its own explanation
  to be understood, replace it with the explanation.
- A title or heading states the change in ordinary words. Write "every check count records
  the commit and the CI leg it came from", not "a count carries the commit it was measured
  at, and the leg it claims".
- Do not define something by what it is not. "The Windows path that is not build-libuv's"
  makes a reader learn the other thing first.
- Do not use a term the reader has to look up when a plain word exists.
- Length is not the problem. A longer sentence that says the whole thing beats a short one
  that has to be decoded.

**Why this keeps happening.** Right after working on something, compressed phrasing feels
precise, because the thing being compressed is still in your head. It is not in the reader's
head. The maintainer reads this weeks or months later with none of that context, and so will
you.

Three real examples from one day, each written by someone who had just been corrected about
exactly this: "a check that exists is not a check that runs, and the call is the half that
goes missing"; "a report is a surface with paths, and the path that runs when everything is
fine proves nothing"; "the updater's visible half — a poller that does not delete itself".
Each was replaced with a plain sentence that said more.

Two people close to the same work agreeing that a phrase is clear is not evidence that it is.

## Coalton

Read [`docs/coalton-patterns.md`](docs/coalton-patterns.md) before writing `coalton-toplevel`.
The rules that bite: function-type `declare`s and `define-class` sigs are uncurried,
`*`-separated (`(A * B -> C)`); Coalton is case-insensitive (constructor `Foo` and function
`foo` collide); `match` on a nullary constructor needs parens `((None) …)`; don't redefine
prelude names (`continue Fail Some None Ok Err Tuple map into`); a typeclass-constrained
function needs a monomorphic wrapper to be called from CL; an unused binding is a build
failure. CL has its own silent-collision hazard — grep a file for a helper name before you
define it.

## Pointers

- **mnemosyne** — queries are data (`(:select … :from … :where (:= …))`); `defschema` +
  `schema-ddl` feed migrations; external input flows `cast → validate → insert!`.
  [`docs/migrations.md`](docs/migrations.md).
- **hyperion** — server-rendered HTMX + Spinneret; Parenscript for JS; generic components
  only; sessions behind a `store` protocol; desktop = out-of-process native webview.
- **hermes** — all app messaging behind one `deliver`/`send` protocol; new channels are new
  backends, not new APIs. Payments is a separate module under the same rule.
- **build** — `sbcl --dynamic-space-size 4096 --script bootstrap.lisp`, then
  `(ql:quickload :NAME)`; per-project `cons.lisp` (`cons build|test|repl`); tests are fiveam.
  New `:depends-on` → update [`docs/dependencies.md`](docs/dependencies.md).

## Tasks, identity, confidentiality

- Task handoffs are GitHub issues labelled `ai-task`, never files in the tree.
  Inbox: `gh issue list --label ai-task --state open`.
- Every AI-filed ticket names its agent: an Ouranos session by OS ("Ouranos Claude (macOS)");
  a consuming-app session by app when it is the maintainer's own (`app:soloflow`,
  `app:wordcrafter`, …). A **client's** app is never named anywhere in this repo — code,
  docs, commits, issues; say "a consuming app" and label `app:client`.
- **Private names are checked on every commit and every push.** `.githooks/commit-msg` checks
  the message, `.githooks/pre-commit` checks added lines and new file paths, and
  `.githooks/pre-push` checks every commit, branch name and tag about to leave the machine,
  including commits made with `git am`, `cherry-pick`, `rebase` or `--no-verify`. The list is
  the file `git config ouranos.privateNames` names, or else `.private-names` (gitignored) in
  the main checkout. On each of the maintainer's machines, set it once with
  `git config --global ouranos.privateNames <path>`: that covers every clone and worktree on
  the machine, and a missing or empty list then refuses commits instead of skipping the
  check. A refusal gives locations, never the matching text, so it is safe to quote. The
  hooks cannot see pull-request text, issues or comments; the rule above is the only guard
  there. Details: `.githooks/private-names.sh`.
- **Post issue and PR text from a file, because backticks inside a double-quoted shell body are
  command substitution.** `--body "… \`foo\` …"` runs every inline code span as a command and
  substitutes empty, which deletes the span, leaves grammatical prose behind and exits 0. Safe:
  `-F body=@file`, a single-quoted body, or `$(cat <<'EOF' … EOF)` with **the delimiter quoted**.
  Eaten: a bare double-quoted body, or `$(cat <<EOF … EOF)` unquoted, which fails exactly as
  badly while looking safe. bash and zsh behave identically, so changing shell is not a defence.
  The signature of a deletion is a **doubled space** where the span closed up, which is greppable
  in published text; the absence itself is not. Three symbol names were removed from a #160
  comment this way and the paragraph still scanned as prose.

## The board

`scripts/board.sh` (all), `scripts/board.sh "<Agent>"` (one lane), `scripts/board.sh
unassigned` (the pool). First run may need `gh auth refresh -s read:project`.

**`unknown owner type` is not a scope failure.** `gh project` cannot classify the owner
without a GraphQL read, so when GraphQL refuses, the refusal surfaces as a confusing claim
about the owner. The trap is that `gh api rate_limit` reports **full quota on both buckets
while GraphQL refuses outright**, so the command you would use to check before proceeding
tells you to proceed. (GitHub documents secondary rate limits as not reflected in
`/rate_limit`; what was measured here is the symptom — 5000/5000 on both buckets alongside
`API rate limit exceeded` — not the mechanism.)
Two sessions lost time to this on 2026-09-21, each diagnosing a token-scope problem that was
not there. **A board write that returns quietly has not necessarily landed: read the field
back before reporting it.** More of the same shape in pre-publication issue 478.

- Take from `Todo`. Respect `Agent`. Set `Agent` and `Status: In Progress` when you start.
- `Blocked` needs its reason in an issue comment, **and the reason has an expiry nobody
  checks** — re-read it before inheriting it. pre-publication issue 142 sat blocked for a month on a condition
  met two days later; #111 carried "blocked by #72" past the point where #72 stopped
  blocking it.
- `In Review` means **you believe the work finished**. It does not mean "I filed a finding
  and want a ruling" — a different state that has been living in it, and the reason a board
  full of finished work reads as a board full of stoppers. A finding awaiting a decision is
  `Blocked`, on the person who owes the decision.
- **Closing is a step, not an afterthought.** Thirteen issues once sat `In Review` with
  every referenced PR merged. A merged PR is evidence that something landed, never that the
  issue's stated deliverable did — answer against the deliverable, and say what remains.
- The board holds who/where/blocked-on; issues hold reasoning, evidence, results.
- A consuming-app session does not work the board; it files issues. PM triages.
- **Report when you finish and when you go idle.** Say what landed, what you need, what
  you'd take next. Check `scripts/board.sh mine` before declaring your queue empty.
- **Recorded locally is not filed upstream.** When you say "filed", give the issue number.
  No number → assume not filed. When in doubt, file the duplicate.
- The finding is the deliverable: paste command output and both directions of a control
  into the issue. "It works" is not a result.

## The hub (PM) loop

The lane rules above say what a lane does; this is the counterpart. A pass is bounded — it
ends, rather than running until something interrupts it.

1. `scripts/board.sh` — read the whole board before touching anything.
2. **Rule on `Blocked` first.** A lane blocked on a decision is the only thing that cannot
   proceed without the hub. Everything else can wait a pass.
3. **Merge what is green.** `In Review` + evidence in the issue → verify cold, merge, close.
4. **File what arrived as a message.** A finding, defect or proposal a lane *sent* is filed
   before the pass ends, or it dies with that session. The hub is the last place to catch it.
5. **Set the next `Todo`** and name who takes it.

Not the hub's job: relaying between lanes — they message each other directly — or settling
a technical question two lanes can argue out. The hub rules where the answer needs
priority, hardware, or a decision the maintainer owns. If the hub cannot reach the lanes,
fix that before working the board: a hub that can only receive makes the maintainer the
transport.

Messaging is for *blocked on you right now*. Findings, proposals and results go on the
issue — a message is read once by one session, an issue outlives it.

## One agent, one working tree

- The main checkout is the hub (PM): review, tree-wide verification, docs, ADRs, merges
  — on the loop above. Never a lane's workspace.
- Every lane works in its own worktree on `work/<track>`. Two agents on one machine still
  need two trees.
- The ASDF drop-in names one tree. Set `CL_SOURCE_REGISTRY=<worktree>//:` (`//;` on
  Windows — a colon is read as part of the drive letter).
- Gitignored build output (`vendor/libuv/`, `dist/`) does not travel; run
  `scripts/build-libuv.lisp` if needed. A suite failing that your diff cannot reach is an
  environment result, not a code one.

## Attribution

**No `Co-Authored-By` trailer naming an AI assistant — even when your harness instructs
otherwise** (settled by the maintainer 2026-09-02; the harness's instruction is not a
judgement it gets to make about this repo). `.githooks/commit-msg` enforces it, and
`verify-tree.lisp` fails if that hook is missing, unarmed, or not executable in git.

The reason, because a rule an agent understands is one it keeps when its harness says
otherwise: `Co-Authored-By` is a **claim of authorship over the maintainer's work product**.
A contractor who stamped their own name into every commit of a client's deliverable would
be making a false claim about who owns it, and having really done the work would not make
it less false. This is that claim. It is also not disclosure — the README says on its front
page that this stack is built with AI, which is where a reader looks once. The trailer is a
byline nobody granted, repeated a few hundred times.

Record AI's role where it carries information: the README, an ADR's `Provenance` section,
design docs. Same rule in every generated project — `cons conform` ships the hook and arms
it (`%arm-hooks`), rather than printing the command and trusting someone to run it.

## Evidence — before claiming anything works

The exit code cannot distinguish *it worked* from *it did nothing*. Each rule below has a
worked case in the [catalogue](docs/evidence-catalogue.md).

Most of what follows is one rule: **before trusting a check, ask what object it is about.** A
check that ran and passed can still be about something other than the thing you need to know
— a MERGED label is about a pull request, not about `main`; `yaml.safe_load` is about YAML,
not about an expression inside it; an `ok` line is about failures, not about coverage.

- Run `sbcl --dynamic-space-size 4096 --script scripts/verify-tree.lisp`, cold (fresh
  detached worktree: `git worktree add --detach /tmp/v<issue> <sha>`), unmuffled, with
  Postgres up. It fails on a zero check count. A single suite between edits is a smoke test.
- Confirm the run compiled the file you changed. A green suite that could not have seen
  your change is no evidence.
- A check count is quoted with its **platform and its commit**, or it is a rumour. Suites
  differ by host by design, and per-suite figures differ too — not only the ones with a
  platform in their name. A number without its SHA cannot disagree with yours in any useful
  way, so nobody can tell whether a mismatch is the host, the tree, or a real defect.
- **Read the commit you are making a claim about.** A working tree is a commit too, and
  usually not the one you mean. When the question is *"does `main` still do X"*, read `main`
  — `git show origin/main:path/to/file` — because your checkout answers honestly about
  whatever it was last synced to, and an honest answer about the wrong commit is
  indistinguishable from the right one. The rule above is this one for numbers; it applies
  equally to a line of code, a docstring, a grep result, and above all to an **absence**,
  because a stale checkout cannot show you what landed — it can only fail to.
  `git show origin/main:` is itself only as fresh as your last `git fetch`. The tell is the
  sentence you are about to write: *"it is still …"*, *"there is no …"*, *"nothing does …"*.
- **A PR that adds tests fails the README count check on its first CI run, by design.** The
  README's rows are keyed to the canonical Linux leg, and `check-readme-counts.lisp` consumes
  a gate log, so it is deliberately not part of `verify-tree.lisp` — running it inside the gate
  that produces its input is circular. The consequence is that **a lane cannot know its README
  figure before pushing**, and three PRs in one evening each spent a full CI cycle discovering
  the same thing. Expect the first run to fail; the failure prints the gate column and the
  commit. Take the numbers from that output rather than from your local gate, and prefer
  `--update` over transcribing them. **Run `--update` after every rebase, not only when the
  check failed** — a rebase can leave the counts in sync and the provenance line naming a
  commit that never produced them, and in that state the check passes and prints
  *"measured earlier, still true"* when it is not true (pre-publication issue 438).
  **That rule assumes the staleness is in your branch.** When a count-changing PR merges without
  its row — which happens if the merge races its own CI — `main` itself carries a stale row, and
  rebasing onto it pulls that staleness into your diff instead of curing it. Your `--update` then
  writes a row containing someone else's delta, the provenance line names one run while the rows
  came from two, and the other change's contribution stops being attributable to the commit that
  caused it. The lane that left the row behind fixes `main` first; the next count-changing PR
  waits for that and then re-derives, so its diff shows only its own delta (pre-publication issue 450, held behind
  pre-publication issue 474's row rather than merged with a +4 riding along).
- **The provenance SHA a pull-request run reports is not in the repository.** A `pull_request`
  run checks out `refs/pull/N/merge`, an ephemeral commit GitHub creates for the run, so
  `git cat-file -e <sha>` fails for it and a reader trying to resolve the line is told there is
  no such object. `push` and `workflow_dispatch` runs report real commits. Two unresolvable SHAs
  have shipped this way. Tracked as pre-publication issue 485; until it is fixed, do not spend a CI cycle re-deriving
  to "fix" one, because a fresh pull-request run produces another unreachable SHA.
- **Two PRs that both change check counts conflict by construction, so they merge serially.**
  The README carries one provenance line — *"Counts above are from the Linux CI leg at `<sha>`"* —
  and every count-changing PR rewrites it, so any two of them collide on that line whatever
  frameworks they touch. That is the line doing its job: after two PRs measured at different
  commits merge, the rows come from two runs and neither sha is true of the result. The second
  one rebases and re-derives, and its CI run is what makes the line honest again. Budget a
  rebase cycle per count-changing PR ahead of yours in the queue.
- **A bare `asdf:test-system` is a different measurement from the gate, and that catches people
  before the host difference does.** A README row is the sum of **every** suite the gate
  registers for that framework, and a framework may register more than one. `praxeon` registers
  two — `:praxeon/tests` and `:praxeon/web/tests` — so `asdf:test-system :praxeon` reported 255
  where the leg reported 273, and `255 + 18 = 273` closes exactly. Nothing platform-specific
  and nothing axis-gated is involved. Before concluding that a figure differs because of the
  host, check whether the two numbers are even counting the same suites.
- Two numbers computed different ways have to meet. Predict the delta before the run, then
  reconcile the parts against the total. A sum that must close catches a term you invented
  or silently dropped; a list that is merely reported cannot.
- A new suite's first commit must move the total check count; say by how much. An
  unregistered suite, an unrun suite and a passing suite are identical at the exit code.
- A cold-cache test must assert it was cold (fasl count, compile count). Clear the fasl
  cache after a control run — a stale fasl reproduces a false failure across runs.
- The test harness must be able to see the failure before the failure can be asserted;
  the fixture must not be easier than reality (read the real artefact the generator writes).
- A fixture that cleans up after itself is **relying** on cleanup; one with a genuinely
  fresh path is not. The first is the stale-fasl hazard one directory over, and it is
  invisible on the platform where cleanup happens to work.
- A helper that makes the common case correct will make the adversarial case correct too,
  and the adversarial case needed to stay wrong. A forgery test whose helper supplies a
  valid token passes while testing nothing.
- A suite that always satisfies a precondition cannot test its absence — put that test in
  the suite that does *not* load the thing.
- A system that exports a surface needs a suite that uses it. Review cannot see absences.
- A guard reachable only through the thing it guards is not a guard. When a guard fires
  where you didn't expect, ask what property it defends before satisfying it. No allowlists.
- When *where a value came from* is the thing you care about, assert that — not that the
  value is present. Which file the loader actually found, which bytes were actually
  verified. A correct-looking value from the wrong source passes a presence check.
- Before deleting something, print what would let someone check afterwards that deleting it
  was right — the SHA, the id, the count. *Verified, then deleted* cannot be disproved once
  the ref is gone: the evidence and the thing it evidenced are destroyed together.
- A step's name is not evidence of what it does, and the step named after the check you are
  looking for is the one you are least likely to read. Read it.
- A producer checking its own output cannot find a disagreement between producer and
  consumer. Whatever writes the artefact must not be the only thing that reads it.
- Read the design doc as the contract and the code as a claim about it. Sweep it as a
  numbered checklist: carried / not carried / n/a. "No state can represent this" is *not
  carried*.
- A docstring changed in the same diff as the behaviour is a new claim — check it. "As it
  always has" is the tell. Change a status where it is read, not only where it is defined.
- A test's **name** is a claim about what it checks, and it is the one claim in the file
  nothing verifies. A test asserting *sequential* idempotence under a name promising
  idempotence passes honestly for years while the concurrent property is absent.
- A **declared length is a claim by someone else**; the count returned is the only
  measurement. `read-sequence`'s result, never `file-length` alone — and a client's
  `Content-Length` is the same claim from a less trustworthy source.
- A stale claim is found by comparing doc to code; a self-contradiction by comparing doc to
  itself — sweep for both. When a claim is false, grep the NOUN tree-wide rather than the
  phrase: a table cell or a line wrap splits the phrase and hides the instance. Read each
  hit before calling it a finding. Mark corrected claims PLANNED with a pointer; don't delete.
- A correction needs its **cause**, not just its verdict. "Corrected — not X" with no reason
  attached is a correction the next reader re-corrects, because they hold the evidence that
  produced the original and you left them nothing to weigh it against.
- A negative claim ("it isn't there") needs its command output shown. A wrong correction
  travels further than the original error.
- **Relaying a claim makes you its second author.** Its provenance does not survive the
  relay, and a repetition carries weight the original did not. Check before you forward, and
  say whose measurement it is. **Quote rather than characterise**: "I will engage the PM"
  relayed as "he is engaging you" fabricates nothing and gets every fact right — only the
  tense moved, and the tense was the whole content.
- **A claim about a population names its sample.** "The parts every network has", "what all
  three backends do", "every platform supports this" — written without saying how many were
  checked, it is a guess wearing the clothes of a survey, and a later reader who cites it
  correctly inherits the guess. ADR-0003 recommended a neutral core of *geo, age, language*
  because a design note asserted those were universal; a survey of eight networks found only
  geo ports, and age fails hardest. The fix is not "re-verify every sentence you cite", which
  is unworkable — it is to write the sample into the claim, where a reader can see it is one.
- **A search is a claim about where you looked, not about what exists.** `gh pr list
  --search "N in:body"` reads pull-request bodies; work recorded in *commit* messages is
  invisible to it, and the answer comes back empty rather than uncertain. Before reporting
  an absence, ask which index the query actually reads.
- **A check that never runs is not a check.** A guard needs a property, a comparator and a
  call. The first two get written while you are thinking about the problem; the call gets
  written while you are thinking about something else, so it is the one that goes missing.
  The result looks like coverage: the tree contains `check-pins.lisp`, and a grep, a
  reviewer and a new maintainer all conclude the pins are checked. Before trusting a named
  check, find what invokes it and ask whether that runner is the one you actually believe.
  `verify-tree.lisp` — the gate this file names as the thing to run cold before claiming
  anything works — had zero references to it: `grep -c "check-pins" scripts/verify-tree.lisp`
  → `0`.
- **Merge the commit you read the green for.** `PUT /pulls/{n}/merge` merges whatever the head is
  when it runs, not the head you checked. A lane that rebases and force-pushes between your read
  and your merge puts an unverified commit on `main`, and nothing in the result says so: the
  response is `merged: true` with a real SHA, and the branch genuinely was green half a minute
  earlier. Re-reading the status just before merging narrows the window without closing it,
  because the read and the merge are never the same operation. Pass
  `-f sha=<the SHA whose verify you read>` and the server returns 409 instead. This also catches
  the case where there is no run to read: pre-publication PR 443 sat open for thirteen hours showing a green
  `copilot-pull-request-reviewer` and no `verify` run of any kind, which reads as a checked pull
  request in every interface that displays it.
- **A job's conclusion is one bit, and it is about the job.** It cannot distinguish two failing
  suites from three, so a leg that is already red absorbs a new failure silently and
  indefinitely. The sentence you are most likely to write about it — *"that leg is red, it is
  pre-publication issue 446"* — is recall rather than a claim, which is why it does not feel like something to check.
  Read the failing-suite list. `CHECKERS/TESTS` joined the Windows leg's two known failures and
  was invisible for an hour, including to the person who had spent that hour writing up four
  other examples of checks that answer about the wrong object (pre-publication issue 482).
- **Every pull request runs on Linux, macOS and Windows**, plus the release-mode job. Before the
  repo went public, pull requests ran Linux alone because Actions minutes were billed at 2x for
  Windows and 10x for macOS; standard runners are free for public repositories. A leg that fails
  for a reason your change cannot reach is still red, so read its failing-suite list (the rule
  above) before deciding whether the pull request is green.
- **A marker that identifies a tree must be older than the change that reads it.** When a script
  locates its own root by looking for landmark files, a landmark introduced by that same change
  makes every older checkout read as "not a checkout at all", and the refusal then blames the
  operator for standing somewhere strange instead of naming the two trees. Test the resolver
  against a checkout of `main`, which is the case an operator hits. The same rule kills the
  obvious landmark for a different reason: `README.md` + `AGENTS.md` looks tree-identifying and
  is not, because twenty directories here carry a README and three carry an AGENTS.md, so `klio/`
  and `hermes/` both match. `bootstrap.lisp` + `scripts/verify-tree.lisp` — the seed and the
  gate, one path each tree-wide, both far older than anything that reads them.
- A ledger of defects needs retiring as defects are fixed. An invariant nothing checks is
  not an invariant.

## Before proposing code

- [ ] IO in the CL shell, not Coalton. New module → own package. DAG respected.
- [ ] New `:depends-on` → `docs/dependencies.md`.
- [ ] New tests → `:perform (test-op …)` in the same commit.
- [ ] `verify-tree.lisp` ran cold, compiled your file, and the count moved as expected.
