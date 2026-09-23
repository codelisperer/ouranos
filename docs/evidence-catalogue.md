# Evidence catalogue — how green runs lied, and what caught them

*Reference, not rules. The one-line rules live in [`AGENTS.md`](../AGENTS.md); this file is the
case history behind each one — read it when a rule seems wrong for your case, or when a
failure looks like one of these. Newest entries at the bottom of each section. Not loaded
into any session by default.*

## Green is not evidence — know what actually ran

**A passing signal is worthless until you know which work produced it.** Three separate
defects in two days shared exactly this shape, and none was a bug in the code — each was a
bug in the *evidence*:

- **A suite that ran nothing.** A test system with no `:perform (test-op …)` makes
  `asdf:test-system` load the files, run nothing, and exit 0. Aion was reported green
  through an entire Coalton upgrade having executed **zero** checks (pre-publication issue 116).

  Three more instances landed in two days, by three different mechanisms: a `def-suite`
  without `:in all`, so `run-tests` never reached it — it reported success having executed
  none of four tests, and **all four were failing**, one of them a real design bug; a new
  test file appended to a file that existed only on another branch, so it was never
  registered and never compiled — 382/382 green with the whole suite absent; and a lane
  running `hyperion/tests` (691, unchanged) over a diff only `hyperion/http1/tests` covers.

  **fiveam and ASDF fail silently in the same direction: an unregistered suite, an unrun
  suite and a passing suite are indistinguishable at the exit code.** This is a different
  blindness from a check that ran and answered wrongly — here the test itself is fine and
  its *registration* is what is missing, so reading the test tells you nothing. So: **a new
  suite's first commit must move the total check count, and you must say by how much.**
  Naming the delta (657 → 679, 3167, 3177) is what caught two of these three.

  **A green suite that could not have seen your change is not weak evidence, it is none —
  and the worst version runs, executes checks, and passes them all on an empty body.** A
  streaming test harness framed responses by `Content-Length`, which a chunked response
  deliberately lacks, so every streaming assertion would have been *vacuously* green: the
  suite ran, the checks executed, each one passed against nothing. **The harness had to be
  able to see the failure before the failure could be asserted** — reading to the terminator
  *or* end of stream is also the only way a test can tell a truncated stream from a complete
  one (pre-publication issue 117).
- **A checker that never asked.** `scripts/verify-tree.lisp` did not load `praxeon/web`, so
  a green run said nothing whatever about a commit that changed only that file. Coverage of
  the checker matters as much as the checker.
- **A failure only a cold build shows.** Coalton reports an unused binding as a full
  `WARNING` and ASDF escalates that to a build failure — but muffling hides it, and once a
  fasl exists the file is only *loaded*, so it passes locally forever and fails on someone
  else's fresh clone ([`docs/coalton-patterns.md`](docs/coalton-patterns.md) §8a).

So, before claiming anything works:

- **A suite that always satisfies a precondition cannot test the absence of that
  precondition.** `hyperion/server-uv/tests` passed 79/79 while `stop` was broken for every
  Clack server in every image that did **not** load `hyperion/server-uv` — because
  `find-symbol` on a package name that does not exist *signals* rather than returning NIL,
  and in that suite the package always exists, so the failing question is unaskable. Only
  the whole-tree run reached an image where it was absent. **The natural home for such a
  test is the suite that does NOT load the thing** — and it should assert the absence
  first, so it cannot quietly stop testing anything. Same shape as the `praxeon/web`
  coverage gap, one level down.

  Its everyday form: **the fixture must not be easier than reality.** `hyperion/update`'s
  suite served signatures as raw bytes held in memory, so **no test had ever read a `.sig`
  the tree's own generator writes** — which is base64 text with a trailing newline. The
  client handed 89 bytes to a verifier requiring exactly 64, and every release the tree
  could produce would have been refused by every installed client, silently and permanently
  (#111). A refused update against a security fix *is* the attack. Where a fixture is
  simpler than the artefact, the seam between producer and consumer is exactly what stops
  being tested — and both sides read correctly on their own.
  And the form that is NOT covered by it: **a fixture must differ in the dimension under
  test, or it cannot see the defect.** A fixture can be perfectly realistic and still blind.
  Three defects in one day, each found only because its fixture varied in the right axis,
  and in every case the *natural* fixture was the blind one:

  | defect | the natural fixture | what makes it see |
  |---|---|---|
  | `supersede` inheriting the superseded observation's provenance (#150) | a correction in the **same** conversation — which is how anyone would write it | `conv-a` turn 1 corrected by `conv-b` turn 9 |
  | an embedding batch paired back by arrival instead of `index` (#138) | rows **in order**, as a real reply usually is | rows deliberately out of order |
  | provenance parsed out of content instead of read from columns (#138) | content and columns **agreeing** | content citing `conv-DECOY` turn 99 while the columns say `conv-real` turn 1 |

  Each natural fixture is realistic, and each passes whether the code is right or wrong. The
  question to ask of a fixture is not only *is this as hard as production* but **would this
  still pass if the thing I am testing were inverted** — and if it would, the fixture does not
  vary in the axis the test is named for.

- **A decided requirement nobody implemented is invisible — read the doc as the contract
  and the code as a claim about it.** Four requirements settled in a committed design doc
  were carried by neither the promoted client nor its reimplementation (pre-publication issue 76), and **all four
  surfaced by accident while doing something else** — including an anti-rollback bypass where
  a valid ISO-8601 fractional-second timestamp sorts *earlier* than the instant it names.
  Nothing was missing from the code's own point of view: the struct's shape read as the
  contract. Tests answer *does the code do what it does*; only the document answers *is this
  all of it*. Sweep the spec deliberately rather than waiting for the remainder to surface
  one at a time: read the section as a **numbered checklist**, mark each line *carried / not
  carried / not applicable*, and treat **"no state can represent this" as not carried even
  when no code is wrong** — which is where three further requirements were found on the
  second pass, every one of them invisible from the code's own point of view.
- **A system that exports a surface must have a suite that exercises it.** Twice now a
  piece has been shipped, exported, documented and reused across frameworks with **zero**
  coverage — `hyperion`'s interceptor pipeline (pre-publication issue 177) and hermes' HTTP client (pre-publication issue 202) — and
  both times the gap was invisible because the *enclosing* system was green. Two instances
  is a pattern, and both were **reusable** pieces, which is the worst place for it: the
  first external consumer is the one who finds out. A non-zero check count for the system
  does not answer whether the exported names are among what ran.

  The reason review cannot substitute: **a review reads the code that exists, so an
  *absence* is invisible to it** — a function with zero call sites, a guard behind the thing
  it guards, a decode step nobody wrote. Only a test that has to **use** the surface can fail
  on what is missing.
- **A doc line added in the same diff as the behaviour is a claim, not a description — and
  "as it always has" is the tell.** `hyperion/channel`'s `since` said only *"INDEX is clamped
  to [0, length]"* — a mechanism, promising nothing about intent. The bounding branch replaced
  it with *"a negative INDEX means the earliest available, **as it always has**"*, and its own
  eviction broke that in the same commit. The behaviour had never been documented; the
  sentence back-dated itself. **A new promise wearing the costume of an old one** is the
  nastiest member of this family, because an appeal to history in a line that has no history
  is exactly what makes a reviewer's eye skip — nobody checks a citation to something they
  believe they already know. Two reviewers read it and neither did; a third-party review tool
  caught it (pre-publication issue 231). Give a docstring changed in the same diff the scrutiny a new assertion
  gets, not the pass a restatement gets. Note the order, too: the meanings had already
  diverged in the author's head — that is *why* the sentence got written — so the doc was the
  first place the divergence was visible, and reading it as background is what cost the catch.
- **When a guard fires somewhere you did not expect, ask what property it is defending
  before you satisfy it.** A lane reached for a seeded MT19937 to fix a *collision* in a
  staging-directory name and pre-publication issue 95's entropy guard went red. The guard was right about
  something larger: that name is a path in a shared directory where a verified installer is
  about to be written **and then executed from**, so the property is not *unique*, it is
  **unguessable** — anyone who can predict it can create it first. *"It is only a temp
  directory name"* was the wrong instinct, and it is exactly why that guard covers all of
  `hyperion/src` rather than the things that look like secrets. **A guard that only fires
  where you already expected it teaches you nothing.**

  It also rejected a **comment** naming the generator — deliberately, since a commented-out
  call is a template waiting to be uncommented. The right response was to reword the prose,
  not to add an allowlist: **the first exception is what turns an absolute rule into a
  judgement call**, and a rule nobody can argue with is the only kind that survives being
  inconvenient.
- **A single-suite loop is a smoke test, not evidence.** That entropy guard lives in
  `hyperion/tests`; the lane had been running `hyperion/update/tests` alone between edits, so
  every cold run it did was blind to it. This is the *"natural home for such a test is the
  suite that does NOT load the thing"* rule met from the receiving end — the whole-tree run
  asks the questions a system's own suite cannot, and that is the point of it rather than a
  side effect.
- **A stale claim and a self-contradiction are different defects and only one of them is
  found by asking "is this still true".** A stale claim was true when written and the code
  moved underneath it — you catch it by comparing the doc against the **code**. A
  self-contradiction was never true — you catch it by comparing the doc against **itself**.
  `docs/wiki/Framework-Hyperion.md` claimed, present tense, that a curated `secure-app`
  stack with CSRF and CSP "is bundled", while listing `secure-app` under *Planned / in
  progress* nine sections earlier and while the design doc still filed the whole thing under
  *Proposed shape* (pre-publication issue 227). Nothing had moved underneath it; **the document contained its own
  refutation.** So sweep for internal consistency as a separate pass, not as a by-product.

  **Why that one survived is the transferable part: it sat immediately beside a *true*
  security sentence.** XSS genuinely is defended at output, Spinneret genuinely auto-escapes.
  **One accurate claim next to an aspirational one makes the pair read as a paragraph
  somebody checked** — the reader's trust is borrowed from the neighbour rather than earned
  by either. Same mechanism as a docstring inheriting credibility from the working code
  around it. Check security claims **individually**, and be most suspicious where the
  paragraph reads well.

  Note also the direction. Nearly every other stale claim in this tree **understates** what
  is built, which is a release-readiness problem. This one **overstates**, about security, in
  the paragraph an enterprise reader reads first. Those are not the same severity and a sweep
  should not report them in one list. And when you correct one, **mark it PLANNED with a
  pointer, do not delete it** — a reader arriving from a security question needs to find the
  answer, not silence. *Planned with a ticket* and *planned* are different claims; say which.
- **Change a status where it is READ, not only where it is DEFINED.** Three ADRs were marked
  `Accepted` in the documents themselves while their own README index tables still advertised
  them as `Proposed` — done by the same person who had written the grep rule an hour earlier.
  A status, a version, a count and a maturity all live in at least two places in this tree.
- **When you find a claim false, grep the phrase across the tree before moving on.** A claim
  pre-publication issue 227's own ledger recorded as *fixed* was still live in `ECOSYSTEM.md`, because the
  correction had landed in `CLAUDE.md` and not in its sibling. **A sweep that fixes one
  instance of a claim leaves the reader exactly where they started** — and worse, leaves a
  ledger saying the claim is dead. Reading files in order can never catch this; the grep
  costs nothing. Measured on one sweep: `cons setup` was called a stub in **seven** files and
  "payments planned" appeared in **nine**.

  **But a phrase-grep produces candidates, not findings — read each hit before claiming it.**
  Grepping `cl:random` returned two hits and *both were correct*: a user guide saying ids come
  from the OS CSPRNG "not `cl:random`", and a wiki page using past tense to explain the fix. A
  rule that treats a mention as a claim manufactures confident noise, which is worse than the
  staleness it was meant to remove. Relatedly: **an assertion written before its evidence is
  not a finding, it is a hope with a command next to it** — a sweep printed *"empty above =
  the phrase is dead tree-wide"* in the same breath as a grep that then listed seven more.
- **A ledger of defects needs retiring as the defects are fixed, or it becomes a second
  source of false claims — and a worse one, because it is written in the confident voice of a
  correction.** `docs/launch/onboarding.md` asserted the README "still tells readers this is
  planned" when it no longer did, and cited an issue as open that was closed with its script
  shipped (pre-publication issue 227). Mark such entries FIXED/VERIFIED rather than deleting them: the shape of the
  original mistake is the lesson, and a deleted correction teaches nobody.
- **A stated invariant with nothing enforcing it decays like any other claim.**
  `ECOSYSTEM.md` said maturity and check counts are kept in step with the README's table, *and
  named which to trust when they disagree* — while they disagreed in six rows and one figure
  read 42 against a real 758. A consistency rule nothing checks is documentation of an
  intention, and this one additionally told the reader which of two wrong numbers to believe.
  Either something checks it, or it should not promise.
- **A step named for the check you want is the best possible hiding place for the check you
  don't have.** The release workflow already had a step called *"Verify as a client would"*,
  and it ran the generator's own reader — the producer marking its own homework, which cannot
  see a producer/consumer disagreement by construction (pre-publication issue 77). It survived review precisely
  because the slot was occupied and the label told every later reader there was nothing to
  look at. Auditing a pipeline by reading its step list is exactly the method this defeats.
- **A negative claim cannot be checked by reading the report — paste the output.** "I looked
  and it is not there" is the one shape a reader cannot verify, weigh, or argue with: a
  positive claim names something someone else can go and find, and a negative names an
  absence that is indistinguishable from a bad search. A lane retracted a *true* statement
  about a label that existed, on the strength of a check it reported rather than showed, and
  the retraction reached two other sessions before it was caught (pre-publication issue 233). **A correction
  carries more authority than the original**, so a wrong one travels further and costs more
  to undo — which makes the shown command cheapest exactly where you are most confident.
- **A safety check reachable only through the thing it guards is not a check.** An
  unknown-packaging-format refusal was written into a generic function's fallback method —
  and the test double for the installer launcher **replaces that generic**, so the refusal
  was unreachable in exactly the configuration meant to exercise it (pre-publication issue 76). The code read
  correctly, the suite was green, and the guard was decorative. Put the refusal where the
  caller must pass through it, not in the layer a test or a backend can swap out.
- **Assert the work, not the absence of failure.** A suite must report a **non-zero check
  count**. `sbcl --script scripts/verify-tree.lisp` fails on zero and is the command to
  use — not a hand-rolled `asdf:test-system` loop. And **an assertion that a value is
  present cannot tell you it came from the right place**: a passing test asserting that an
  unsupported-schema refusal *carried a URL* was satisfied by a URL read out of the very
  manifest the branch had just declared unreadable (pre-publication issue 76). Assert provenance where provenance
  is the property that matters.
- **Confirm the check you ran actually covered what you changed.** If you edited a file,
  something in your verification must have compiled it.
- **Cold and unmuffled before committing Coalton.** Clear the fasls; never wrap loading in
  `muffle-warning` and call the result green.
- **"Exited 0" is not "it worked."** Neither is "it loaded."
- **A cold-cache test must assert that it WAS cold.** Do not rely on whoever runs it to check
  afterwards. Assert a compile count, or a fasl count, or the absence of the cache directory —
  something that fails when the run was warm. A lane nearly filed *"1 GB of heap is fine"* on a
  run that **passed while compiling nothing**: the binary silently ignored the cache
  redirection, loaded warm fasls, and exited 0. What caught it was the fasl count, not the exit
  code. The exit code cannot distinguish *it worked* from *it did no work*, and a cold-cache
  test whose coldness is unverified is measuring the wrong thing in exactly the direction that
  produces a false pass.
- **A red run can be stale too — clear the fasl cache after any control run.** ASDF
  recompiles only on a **strictly newer** source, and reverting a control patch with `cp`
  leaves the source with the same mtime *to the second* as the fasl built from the patch. The
  stale control keeps loading into every fresh image, so the failures **reproduce across
  runs** — which is exactly what a real bug looks like. One lane lost time to 13 reproducible
  failures in already-correct code before clearing the cache returned 301/301.

  Note the direction: everything above this line guards against a warm image reporting
  success it did not earn. This is the inverse, and it is arguably worse, because the
  response to a false failure is to go and change correct code until the symptom moves.
- **Better than clearing the cache: verify from a fresh detached worktree.** Cold **by
  construction** rather than by remembering:

  ```sh
  git worktree add --detach /tmp/v<issue> <sha>
  ```

  ASDF has never compiled that path, so there is no fasl to be stale — the mtime question
  cannot arise at all. `--detach` also sidesteps the branch already being checked out
  elsewhere, so **two sessions can verify the same commit simultaneously** without either
  noticing, which is the one case the one-agent-one-worktree rule would otherwise make
  awkward. Remember `CL_SOURCE_REGISTRY` must point at the new worktree, and that it has no
  `vendor/libuv/` or `dist/`.

**A check that never runs is not a check (pre-publication PR 344, pre-publication issue 346, pre-publication issue 329).** Three instances in one
day, and the generalisation had to be corrected once before it fit all three — which is the
most useful part of the case.

The first framing was *a duplicated fact with no comparator*. That fits two of them:

- **pre-publication PR 344** — `mbedtls.pin` declares a `sources-digest` whose stated purpose is that it "ties
  this pin to that manifest so a version bump cannot quietly keep an old one". Nothing ever
  compared the two: not `mbedtls-sources.lisp`, not `check-pins.lisp` (which only looks for a
  version/sha field), not `verify-tree.lisp` (which did not run `check-pins` at all).
- **pre-publication issue 329 option B** — a proposed `sonames` field on `*lazy-natives*` would have been a second
  hand-maintained copy of `aion/uv/ffi:*library-names*`, in a different system, with nothing
  comparing the copies. Rejected for that reason; the ruling took option C, which makes both
  bundler carry functions name from the requesting end so the rule exists once.

It does **not** fit the third, which is not duplication at all:

- **pre-publication issue 346** — `check-pins.lisp` existed, was correct, and ran on every pull request.
  `verify-tree.lisp`, the gate `AGENTS.md` names as the thing to run cold before claiming
  anything works, had zero references to it. `grep -c "check-pins" scripts/verify-tree.lisp`
  → `0`.

What holds across all three is that **both halves of the guard were present and nothing
connected them**. A working guard is a property, a comparator and a *call*, and every one of
the three was missing the call.

That is why it earns a line in `AGENTS.md` separate from *"an invariant nothing checks is
not an invariant"*. That rule tells you to notice a **missing** check. Here the check is not
missing — it is present, plausibly named, and its presence is exactly what stops anyone
looking. A repo containing `check-pins.lisp` looks, to a grep and to a reviewer, precisely
like a repo that checks its pins.

**The asymmetry in pre-publication issue 346 is the part that explains why it survived.** `check-coalton.lisp` sat
one step above `check-pins.lisp` in the same CI job and was equally absent from the gate —
but a wrong Coalton *fails to compile the tree*, which the gate does do, so it was caught by
accident. A pin whose `advisories`/`reviewed` fields have gone missing compiles perfectly,
and so does an asset whose bytes no longer match `ASSETS.pin`. The checks that had a second
line of defence were the ones that had one.

**Two properties worth copying from the fix (pre-publication PR 348).** The checkers report in their own
`PROVENANCE` section and contribute nothing to `total checks executed`, because that figure
means "assertions the suites ran" and is the number every issue in this repo quotes at every
other. That was asserted in *both* states rather than once: the count reads 3799 in the
passing run **and** in the deliberately failing one, which shows the checkers *cannot*
inflate it rather than that they did not happen to. And a **missing** checker is reported as
a failure, not a skip — absent and passing are identical at the exit code, which is the
defect the whole section is about.

**A defect needs a caller, the same way a check does (#158, pre-publication issue 258).** The rule above says a
check that never runs is not a check, and tells you to find what invokes a named check before
trusting it. The mirror holds and is not written anywhere: **before reporting a defect in a
mechanism, find the code path that reaches it.** A fragile mechanism nothing exercises is
*latent*, and latent and live are different findings with different urgency and different
tests.

Two cases in one afternoon, both the hub's, both caught by a lane checking the tree rather
than reading the report.

- **#158.** Filed as live: *"a child constructing a provider on its own thread reads the global
  NIL rather than the role the caller established"* — a wrong answer rather than a missing one.
  The mechanism really is fragile: a dynamic binding does not cross a thread boundary, and
  `praxeon/llm:*provider-role*` is a `defvar`. But the only binder is `make-provider-from-env`
  itself, and every reader — `%env-for`, the impl lookup, the `(funcall ctor)` that consumes
  them — sits inside that same `let*`. One synchronous dynamic extent, one thread. Nothing
  binds it at an outer seam, so there is no crossing to lose. The lane asked *where does the
  read happen on a different thread from the bind* before writing any code, and the answer was
  nowhere.

- **pre-publication issue 258.** The same substitution twice. First the ticket's body was relayed as a description
  of the tree; it predated pre-publication issue 212 landing and the three breakages it predicted were mostly
  already handled. Then `field-type-from "vector"` yielding `(FT-Vector 0)` was reported as a
  live defect losing the dimension. It is a deliberate backstop, documented at the call site
  and pinned by three tests, one of them named for the property and saying in its docstring
  that it exists so nobody turns it into a default width. The decisive measurement came from
  the consuming app, not from the reasoning: `field-type-from` has **exactly one production
  caller**, `schema.lisp:73`, and it is the *else* branch — line 64 intercepts `"vector"` and
  builds the type from `:dimensions` first. The zero-width path is unreachable from production
  code.

The shared shape is **a true statement about a mechanism presented as a statement about a code
path**. Both reports were accurate about how the thing works and wrong about whether anything
does it. That is the same substitution the section above catalogues from the other side: there,
a check exists and nothing calls it; here, a hazard exists and nothing reaches it.

Why it matters beyond accuracy: **a latent defect fixed without a test that exercises the
crossing is a change nothing verifies.** The fix for the live case is tested by the behaviour
that was already wrong. The fix for the latent case has to construct the caller that does not
exist yet — bind the role, spawn, construct on the child — which is more work than the fix and
is the part that makes it real. Reporting the two as one loses that.

The question is cheap and neither party asks it by default: **is there a caller?**

**An assertion that cannot fail is not evidence (pre-publication issue 437).** Before trusting a new check, ask what
would make it report the other thing. A harness was to assert that a cache marker sat on the
*last* part of a system prompt. With a single-element subject, *marked* and *marked last* are
the same assertion and neither can fail — the check passed, and would have passed against an
implementation that marked the first of several. It became evidence only when driven against a
hand-built two-part system, where it said `NO` on the wrong one and `yes` on the right one.

This is the question almost nobody asks of an assertion they have just written, because a new
assertion that passes feels like a result. Two neighbours of it are already in this file — a
fixture that must not be easier than reality, and a helper that makes the adversarial case
correct by accident — and this is the narrowest form: not a fixture that is too easy, but a
*subject* whose shape makes the claim vacuous.

Two corollaries from the same work, because an instrument is a claim like any other.

**A control can earn its keep on the instrument rather than on the subject.** The unset control
existed to prove that a zero discriminates. What it caught was `(vectorp "abc")` being **true**
in Common Lisp — a string is a vector — so a block-array guard written as `vectorp` admitted
every string and indexed into characters. The defect was in the harness, not in the thing
measured, and nothing else would have surfaced it. This is the answer to anyone who calls a
control bureaucracy: it is not only there to make a pass meaningful, it is there because the
instrument can be broken in ways the subject cannot show you.

**A harness can commit the defect it exists to detect.** In the same file, one comparison
measured what the provider *received* — neutral parts, a list — against *rendered* JSON blocks,
and reported `0 of 5` while meaning nothing. That is the producer/consumer confusion the harness
was built to catch, committed inside the harness. Neither bug changed a verdict, and both were
disclosed with the result rather than after it, which is what made the numbers weighable: a
harness whose bugs go unmentioned is one nobody can judge.

**Formatting output for reading can remove the part that identifies what you are looking
at.** Three instances, all in one evening, all from the same instinct: making a command's
output easier to read, and then reasoning from what survived.

- **The process identification.** A lane ran `ps` and piped it through `cut -c1-120` to keep
  the lines readable. That cut off `(asdf:load-system :alive-lsp)` and `(alive/server:start)`
  from the end of four command lines, leaving four anonymous `sbcl` invocations. It
  characterised them from what was left — orphaned test listeners — cited their 29-hour age as
  evidence of staleness, and was about to ask the maintainer to kill them. They were his editor's
  Common Lisp backends, one per open window, and the 29 hours was when he last restarted the
  editor. The identifying substring was past column 120.
- **The exit status.** `cmd | grep … | head -5` followed by `echo "exit=$?"` reports **head's**
  status, which is 0 whenever head managed to write. A compile that was never attempted and a
  compile that succeeded are identical through that pipe. The same shape appears in this file's
  history as a control test written `if (cd "$p" && git commit … | head -4); then`, which
  tested `head` while reporting on the commit hook.
- **The sampled range.** A count of suite keywords taken from `sed -n '143,160p'` of a list that
  runs longer than line 160 returned 19 against an actual 28, and the 19 was then used to
  dispute a correctly derived total of 83.
- **The shell that ate the symbols.** A comment posted through zsh with an inline body had
  `evt:*observer*` and `aion/log:*context*` glob-expanded out of it, because an earmuffed Lisp
  name is also a glob pattern. The published paragraph read *"… is captured at line 244 and
  re-established inside …"* — grammatical, plausible, and missing the two names the paragraph
  was about. Nothing in the tool's output said a substitution had failed.

The common structure is that **the truncation is invisible in the result.** `cut` does not say it
cut; `head` does not say there was more; a line range does not say the list continued. Each
returns a well-formed answer that looks complete, so nothing in the output prompts the question
*is this all of it*.

This is a different failure from the others catalogued here. It is not a claim about the wrong
object, and it is not a check that never ran — the command ran, against the right object, and
answered honestly about the fragment it was given. The damage was done by the person reading,
to their own evidence, in the name of readability.

**The habit that prevents it:** truncate for *display* and never for *inspection*. When the
question is what something is, read the whole record — then shorten what you quote, not what you
look at. And when a pipeline's exit status matters, take it from the command that matters:
`${PIPESTATUS[0]}`, or do not pipe.

**A surface with no producer, and the query that finds one (#94, #161, pre-publication issue 437).** Three
instances in one framework family, found in one evening, each the same shape: a surface that
is built, exported, documented as load-bearing, covered by a suite — and called from nowhere
but that suite.

- **#94** — `cast → validate → insert!` is mandated in `AGENTS.md` and used by zero examples.
  A missing `:vector` clause in `%cast-value` meant the mandated path could not store an
  embedding *and said something false about why*, and it sat undiscovered because nothing
  walked the path. A real consuming application had independently converged on `q:run` instead.
- **#161** — `praxeon/ceiling`'s `meter`, `budget-guard` and `capability-guard` have exactly
  two callers each, both in their own test file. This is why pre-publication issue 417 survived: `record-usage`
  took two of four available token counts, and no caller ever held four and discovered there
  was nowhere to put two of them.
- **pre-publication issue 437** — the cacheable-prefix marker has four consumers (`pinned-exchange-count` pins it,
  the Anthropic backend translates it, the OpenAI backend drops it, `text-part` constructs it)
  and no producer. `llm.lisp` calls it "the single largest win available".

`AGENTS.md` already says *a system that exports a surface needs a suite that uses it*. All
three have one. **The suite is not the missing thing; a caller is**, and the distinction is
the whole finding: a surface exercised only by tests written alongside it has no evidence
about whether its shape is right, only that it compiles and that its authors agree with it.

**The query that answers it, and the two that do not.** Asked whether anything marks a
cacheable prefix, the hub ran:

```
$ git grep -c ":cache t" -- "*/src"
(no output, exit 0)
```

and reported *zero producers, tree-wide*. The pathspec matches a directory **name**; files
under it need `*/src/*`. The query never read a file, and **an empty result is
indistinguishable from "no matches found"** — so an answer about nothing was relayed to two
lanes and the maintainer as the decisive measurement. The conclusion happened to be right,
which is what would have kept it in place.

Corrected, the keyword grep is still the wrong query: six hits, five of them prose, and the
one code line is inside `text-part` itself — the constructor implementing the option, not a
caller using it. The question is about **call sites of the producer**:

```
$ git grep -n "text-part" -- "*/src/*"
praxeon/src/actor.lisp:205     (llm:text-part (llm:completion-text completion))
praxeon/src/prompt.lisp:268    (llm:text-part text)
praxeon/src/prompt.lisp:272    (llm:text-part content)
praxeon/src/prompt.lisp:276    (llm:text-part text)
```

Four callers, none passing `:cache`. Every caller that passes it is in the test suite. One
query, and it is the same sentence as #161.

So, in the lane's words: **"does anything produce this" is a question about call sites of the
producer, not about occurrences of its keyword.** A keyword grep answers *is this concept
mentioned*, which is what both parties measured first.

**And the narrower form of the docstring rule**, which is the same rule again because
reachability is a question about callers: **a docstring is evidence about intent, never about
reachability.** Both parties quoted a docstring to establish that a port helper was racy; both
were right about the helper and wrong about which suite loaded it (see #159 above). A
docstring cannot tell you whether the code it sits in ran.

**A status is a claim about a system, and gets checked like one (pre-publication issue 212, pre-publication PR 429).** The same
afternoon produced both directions of it. A consuming app's backlog carried *"blocked upstream
on ouranos pre-publication issue 212"* for months **after** pre-publication issue 212 landed. The hub described pre-publication PR 429 as built and shipped
while it sat open — `git show origin/main:praxeon/src/memory.lisp` returned nothing — and the
app read *"you can stop waiting"* as landed and could not have compiled against it. A lane
reported a PR green having checked a local gate pass on a different host, never having run `gh
pr checks`; the PR was failing, on a check the local gate does not run.

Three different people, one error: **a status believed rather than checked**. It escapes the
rules in `AGENTS.md` because a status report does not feel like a claim about a system, and
every rule in this file is about claims about systems. It is one. *Answered* is not *landed*,
*merged* is not *green*, and *green here* is not *green there*.

**There are three states, not two**, and the middle one is invisible from the framework's
side. The consuming app that caught the *shipped-while-open* error named them while doing it:

- **Answered but not landed** — the design question is settled and a branch demonstrates it,
  but nothing is on `main`. pre-publication PR 429 for most of one afternoon.
- **Landed but not pulled** — it is on `main`, and the consumer loads a *working tree* that has
  not fetched it. pre-publication PR 420 was in this state for the app, and for the hub's own checkout, which sat
  three commits behind `origin/main` while the hub reported the merge.
- **In effect** — the consumer's tree has it and compiles against it.

From the framework's side the middle state does not exist: a merged PR looks done. It is the
state a consuming app actually occupies for however long it takes somebody to decide to pull,
and on a feature branch that decision is not always theirs to make. A framework session saying
"it landed" has told a consumer nothing about whether they can use it.

**Read the commit you are making a claim about (pre-publication issue 352).** Two cases in one day, both mine,
both **true readings of a real file**, and both about to become false reports.

**A number.** The README's check-count total was edited against **4108**, read from a local
`main` ten commits stale. `origin/main` said **4132**. Every framework row compared correctly,
which is what made the stale total look like the safe part of the file — the corroborating
detail was real, and it corroborated the wrong commit.

**A line of code, which is the case the existing check-count rule does not cover.** Checking
whether #111 was still blocked, `install-directory` read:

```lisp
#-win32 nil
```

and was one sentence away from being reported as *still returns `NIL` off Windows* — the exact
claim a Windows-lane comment had made a month earlier, so it felt corroborated rather than
suspicious. `git show origin/main:` showed:

```lisp
#-win32 (progn app (%derived-install-dir))
```

pre-publication issue 335 had landed it. The reading was not wrong about the file; it was right about the wrong
commit.

**The direction is what makes it dangerous.** The report would have been *blocked* — an
absence. A stale checkout cannot show you what landed; it can only fail to, and failing to
find something looks identical whether or not it is there. That is the
search-is-a-claim-about-where-you-looked rule with the index being your own working tree.

**Why it is a line separate from the check-count rule.** That rule's subject is a number you
are quoting to someone else, and its remedy is attribution — say the SHA. This one's subject
is a claim you are deriving for yourself, and attribution does not help: you would be
attributing correctly, to the commit you read, and still be wrong about the question you were
asked. The remedy is to go and read the right tree first.

**The remedy is a different command, and switching to the wrong one is how the rule gets lost
(pre-publication issue 489).** `git show <ref>:path` reads a commit. `git grep` reads the checkout. They answer
different questions and nothing about either says so, which makes the second easy to reach for
once the first has become a habit — the question silently changes from *what does this file say*
to *what does `main` say*, and the command does not.

Immediately after merging pre-publication PR 490, the hub ran `git grep "defun %row-get"` and found the
pre-conversion body, and `git grep "defun row-value"` and found nothing. On that evidence the
conversion had not happened and the ledger claim in the merge commit — *two converted, two
deliberately positional* — was false on `main`. It was not. **The hub checkout was three merges
behind**, and `git show origin/main:` showed the converted file. The same session had cited this
rule at a lane twice that day and had written a version of it into `AGENTS.md` that morning.

**What caught it was not the rule.** It was noticing that a function someone had said they wrote
was *implausibly absent* — a categorical absence, the loudest available symptom. A changed
default, an argument dropped from a call site, a docstring that no longer matched: none of those
would have looked implausible, and the finding would have been filed. A false finding against
merged work travels further than the error it alleges, because it arrives with a SHA attached.

So the honest reading is that the documented rule did not fire for the person who had just
documented it, and the shape of the defect did the work instead. That is what the entries here
are for: they do not prevent the error, they make it nameable in the seconds after something
else surfaces it.

**A third instance, one level down, the same day.** There is no `mnemosyne/tests/changeset.lisp`,
and the absence of that file was about to be reported as the absence of a suite. `schema.lisp`
carries **ten** tests over the changeset surface. A tested surface with no caller is a
different problem with a different fix, and the report would have sent someone to write tests
that already existed. File-absence is not test-absence; it is a claim about where you looked.

**A suite can pass, report the right number of checks, and still have compiled with a
warning (pre-publication issue 258).** Three signals that normally agree, disagreeing.

The pgvector execution tests were written into `mnemosyne/tests/query.lisp`. They use
`+PG-URL-VAR+`, which `mnemosyne/tests/backends.lisp` defines — and `mnemosyne.asd` loads
`query` **before** `backends`. So the variable did not exist when the file was compiled:

```
WARN  MNEMOSYNE/TESTS  532 checks
      ; caught WARNING:
      ;   undefined variable: MNEMOSYNE/TESTS::+PG-URL-VAR+
```

`asdf:test-system` reported **532 checks, all passing, nothing skipped** — because the
reference resolves at *run* time, by which point `backends.lisp` has loaded. The suite was
correct. The count was correct. The code was still wrong, and would have broken the moment
anything referenced it during compilation instead.

**Only the gate saw it**, and only because `verify-tree` reads the child's *output* for
`caught WARNING` rather than trusting its exit code. `warnings-in`'s own docstring says why
that was built: SBCL reports some warnings at the end of the compilation unit, past the
point ASDF inspects `compile-file`'s failure flag, so `asdf:load-system` returns cleanly and
the child exits 0. It was written after an unescaped quote in a docstring warned on every
cold build of hyperion for a week while the script reported PASS.

The general form: **running a suite and reading a suite's output are different measurements,
and the second is strictly stronger.** A green summary line is a claim about assertions. It
says nothing about what the compiler thought of the file those assertions live in.

The fix was moving the tests to `mnemosyne/tests/param.lisp`, which loads after `backends`
and is where they belonged anyway. The lesson is not about load order — it is that a suite
agreeing with itself is not evidence, because both halves of the agreement come from the
same run.

**Expand loops before predicting a check-count delta from source (pre-publication issue 276).** A new suite's first
commit must move the total and you should say by how much first — but the prediction is a
measurement too, and it can be a measurement of the wrong object like any other.

`hyperion-view`'s suite reported `7 checks (5 skipped)` because nothing built the launcher. To
predict the delta from enabling it, the five skipped tests were read and their assertions
counted: 1 + 4 + 2 + 2 + 2 = 11, replacing 5 skip markers, so **+6**. The measured answer was
**+10**.

The miss was one test:

```lisp
(test help-prints-usage-and-exits
  (with-launcher
    (dolist (flag '("--help" "-h"))
      (multiple-value-bind (code out err) (run-launcher flag)
        (is (eql 0 code) ...)
        (is (search "usage:" out) ...)
        (is (search "--icon" out) ...)
        (is (zerop (length err)) ...)))))
```

**Four assertion forms; eight assertion executions.** fiveam counts what ran, and the source
counts what was written. Corrected: 2 + 1 + 8 + 2 + 2 + 2 = 17, and 17 − 7 = +10.

Nothing was broken by the wrong prediction — it was caught by the run it was predicting, which
is what predicting is for. It is here because of *who* made it: the same session that had spent
the day cataloguing true measurements of the wrong object made one in the act of cataloguing
them. That is the argument that this failure is **structural rather than a matter of care**. The
discipline that works is not vigilance; it is the habit of writing the prediction down where the
run can contradict it.

The general form: **a count of assertion forms is a claim about the file, and a check count is a
claim about the run.** Anything between them — a loop, a `dolist` over backends, a macro that
expands to several `is` forms — makes the two different numbers. Expand them, or predict a range
and say which it is.

**A term invented or silently dropped survives any number of matching predictions, and does
not survive a sum that has to close (pre-publication issue 432, #138).** The rule above says to write the
prediction down where the run can contradict it, and that is right. But a prediction on its
own has a failure mode: when it matches you learn nothing you did not already believe, and
when it misses the cheap response is to adjust the prediction and move on. What catches a
real defect is **a second computation that has to agree with the first** — AGENTS.md's *two
numbers computed different ways have to meet*.

The worked case. pre-publication issue 432 predicted **+183** mnemosyne checks and the suite delivered exactly that,
so the prediction told nobody anything. The useful moment came later, deriving the README row,
where two figures arrived from different directions:

```
MNEMOSYNE/TESTS   621 -> 804      the suite, measured locally
README mnemosyne  656 -> 839      the row, measured by CI
```

Both deltas are 183, and **both absolute figures disagree by exactly 35**. A reader comparing
the ticket's 804 with the README's 839 sees a discrepancy in a number the whole repo treats as
load-bearing. The reconciliation is that the README row sums **every** `MNEMOSYNE/*` suite, and
`MNEMOSYNE/EXAMPLES/CONTACTS/TESTS` contributes 35 on both sides.

That explanation only exists because two numbers computed different ways were made to meet. The
prediction could not have produced it: +183 was right in both columns and hid the 35 completely.

**The practical form.** After a count moves, find a second route to the same quantity and close
it against the first — a per-suite figure against a row total, a sum of rows against a grand
total, a delta against the parts it is made of. `5226 + 12 + 30 + 21 + 19 = 5308` is that habit
across five merges: each term predicted before its run, and the sum checked against what `main`
actually read. A term invented or silently dropped survives any number of matching predictions
and does not survive a sum that has to close.

**A guard a comment could satisfy, and a control that tested a copy of it (#158).** The sweep
added with the inheritable-bindings registry fails any `make-thread` that has not recorded
whether it carries the caller's dynamic bindings. A site counts as decided if `inheriting`
appears near the spawn, or if a nearby comment says `THREAD-LIFETIME`. Both markers were found
by one substring search over a window of source lines.

Comments are source lines. So a comment reading *"this thread is not inheriting the caller's
context"* marked the site as **decided**: a sentence describing the problem satisfied the check
that existed to catch it, and the site was never reported. The two markers are now read from
different halves of the window — `inheriting` from code only, `THREAD-LIFETIME` from comments
only, which is where it was always meant to live. Measured on the same two lines of input rather
than argued:

```
OLD matcher says decided=T, so it reports: () -- silent pass
NEW matcher reports: (2)
```

**The worse defect was in the control.** `the-sweep-can-see-a-bare-spawn` exists so that a sweep
reporting no undecided sites cannot be confused with a sweep looking in the wrong place. It did
that by writing the matching out again inside the test, over a file it built. So it exercised a
*second implementation* of the matcher rather than the matcher. It agreed with the original by
construction, and it would have kept passing after the real one changed — including through the
fix above, which is the change it most needed to notice.

A control that reimplements the thing it controls is not a control. It is a copy that agrees
with the original because the same person wrote it from the same idea five minutes later. The
matching now lives in one function and both controls call it.

This is *a producer checking its own output cannot find a disagreement between producer and
consumer*, aimed at a test instead of at code, and it is easy to miss there because the
duplication is what makes the test readable. Writing the logic inline is how you show a reader
what is being checked. It is also what destroys the test's independence.

**How it was found matters more than either defect.** Neither was found by review. The sweep
failed on a real site — a spawn added in pre-publication issue 418 hours after the test was written — and the first
fix for that site was correct and still failed, because an eight-line comment between the spawn
and its wrapper pushed `inheriting` outside the match window. The matcher only got read closely
enough for the rest to become visible because a red had to be explained, and the explanation
turned out to be about layout. A check whose window is a fixed number of lines has a rule that
cannot be seen from the outside; that one is now in the function's docstring.

**A related near-miss in the same file.** Four of the suite's twelve checks had no reason string.
fiveam's default reason for a bare `is` begins with a blank line, and `detail-block` in
`verify-tree.lisp` collects failure lines only while they are non-blank — so under the gate a
bare failing check prints nothing *and* truncates every failure after it in that suite. A report
showing two failures may be showing a prefix of twelve. Every check needs a reason string, or a
real failure will show up under the gate as less than the run actually knew.

**The same shape once more, an hour later (pre-publication issue 450).** `check-readme-counts.lisp --update`, invoked
by its path in the main checkout while the shell sat in a worktree, printed `UPDATED 2 lines`
and left `git diff` in the worktree empty. It resolves the README from `*load-truename*`, so it
had written to the hub's tree. Nothing was corrupted and the revert was clean, but the lane sees
a success message, sees no diff of its own, and the hub's tree is now dirty with a change the
hub did not make. It was caught only by checking `git diff` after a tool reported success.

Four findings in one evening, and one sentence covers all of them: **the report was true about
an object other than the one I meant.** A passing substring search about a window that included
comments. A passing control about a copy of the matcher. A passing suite whose printed detail
was a prefix. A successful write to a different checkout. None of these was a false report, and
that is why none of them looked wrong.

**What happened to the person who wrote the paragraph above, two hours later.** Writing this
entry did not stop its author doing it again twice the same evening.

The first was a test for pre-publication issue 452 asserting that a known observation's text and id reached the
model. It was pointed at an existing fixture that records `(:messages <length> :tools
<length> :tool-choice ...)` — counts, not content. The claim was about content, the fixture
holds none, and the test failed for a reason unrelated to what it was checking.

The second came while reporting the first. `validate-against-schema` does not descend into
array items, and the report said this was a documented boundary because the function "says so
in its own docstring". It does not. The caveat about not pretending to be a JSON-schema
implementation belongs to `%json-type-matches-p`, a different function, and is about unknown
type names rather than depth. One function's caveat was credited to another, in the act of
arguing that the code was fine.

**So the entry did not work as inoculation, and that is worth knowing about it.** The
mechanism it describes is not ignorance — it survives knowing it well enough to write it
down, because in the moment the reader's attention is on the thing being checked rather than
on which object the check reads.

What caught each one is the useful part, and neither was care. The test was caught by
**running it**: it could fail, and it did. The docstring claim was caught by **someone else
checking it**, because the person making it had already decided it was true.

That sets what this file is for. Reading it does not prevent the error. It makes the error
nameable in the seconds after something else surfaces it, which is the difference between
fixing one test and noticing the shape. Build the check that can fail, and let someone else
read the claim.

**A control that never ran, and why the rule you already know does not fire (pre-publication issue 466, pre-publication PR 472).** The
gate's checkers had no tests, so each one got a fixture that breaks it and asserts the break
is caught. `check-deps`'s break was to narrow `.asd` discovery to a single file — the pre-publication issue 358
regression that `tree-deps` records as having actually happened.

The suite passed 23 of 23. The obvious reading is that the test is weak: the break was applied
and nothing noticed. The actual reading is that **the edit had not taken**. Applying it again,
this time confirming the changed text was present before running, the intended test failed
`ff` and the other three stayed green.

**The rule that covers this was already in this file** — *confirm the run compiled the file
you changed; a green suite that could not have seen your change is no evidence.* It did not
fire, and the reason is worth more than the instance.

That rule is written for a **fix**, where the colour you want after an edit is green. So the
habit attached to it is *be suspicious of a green you did not earn*. Breaking something
inverts the expectation: after a deliberate break the colour you want is **red**, and a green
is the result you must not believe. The rule is the same and the suspicion does not transfer,
because the suspicion was attached to the colour rather than to the edit.

So a green after a break reads as information — *the test is weak* — when it is the same
unverified edit the rule is about. And the wrong conclusion is one a careful person would act
on: strengthen a test that was already fine, or worse, weaken the claim made for it.

**Verify the break is present before running it**, exactly as you would verify a fix compiled.
The check is the same one; only the colour you are hoping for has moved.

**A checker whose root spans two checkouts reports their union, and the only tell is that
every figure is exactly doubled (pre-publication issue 480, pre-publication PR 479).** `scripts/check-*.lisp` resolve their tree
from their own `*load-truename*` — the parent of `scripts/`. Put a copy where that parent
contains **two** checkouts and the checker walks both, reports the union, and says nothing:
no output names a tree.

Measured, same commit, same host:

```
root = one checkout            check-source-deps: 94 systems, 174 packages
root = a dir with two trees    check-source-deps: 188 systems, 348 packages
```

**The tell is the exact doubling.** A platform difference does not double every figure
cleanly; two trees do. A reader who sees 188 against someone else's 94 has the diagnosis
from the ratio alone, without needing to know the cause — which is why the numbers are
here rather than only the rule.

It is worth the catalogue because of **where it was found**: in the instrument being used to
study the defect. The 188 was pasted into pre-publication PR 479's body as evidence for a *different* run, and
read as a Linux-versus-macOS platform difference. It was neither. The session had run three
variants while establishing what the checker does, and captioned the header line of one with
the description of another — having only ever `tail`ed the run it was describing, so its
header was never seen and there was nothing to notice the mismatch against.

Two habits fall out, and the second is the cheaper one. **Capture the header of the exact run
you are citing, not just the tail** — the header is where tree-spanning shows up and `tail`
hides it. And **a figure that is a clean multiple of someone else's is a tree-count smell,
not a platform smell**; check it before reaching for an explanation that involves an
operating system.

## When the strange thing is the instrument

The entries above are about checks that measure the wrong object. This section is about the
moment you find out, which is usually a result that does not make sense — and about the
reflex that throws it away.

**Two cases in one day, same author, opposite tools.**

A spawn-site sweep failed on a site that had just been fixed. The wrapper was there, the
marker was there, and the sweep still reported it undecided. First read: the site must be
written oddly. Actual cause: the matcher's window reaches two lines past the `make-thread`
form, and an eight-line comment between the spawn and its wrapper pushed the marker outside
it. The check had a positional rule nobody could see from outside it.

An ASDF plan comparison reported 965 differing lines across sixteen systems. Adding detail to
the output — printing each action's operation alongside its component — took that to **zero**.
First read: the extra field must have made things match. It cannot. Adding detail to a
comparison can only reveal differences, never remove them, so the two runs were not comparing
one sequence. Actual cause: `asdf/plan:make-plan` returns the actions still *to do*, the two
runs had different fasl caches, and a warmer cache yields a shorter plan. Cold on both sides,
the answer was 0.

**The mechanism is not that the results were surprising. It is the reflex to explain a
surprising result rather than distrust the instrument.** Both times the first instinct was
*the tool is fine, the input is odd* — and that instinct is correct nearly every time, which
is exactly what makes it expensive on the occasions it is not. A rule like *a cold-cache test
must assert it was cold* is something you follow when you remember it. This is something you
have to notice while you are thinking about something else entirely.

That shape is not confined to instruments. pre-publication issue 442 is the same form in a habit: a pull request
whose workflow never fired looks exactly like one whose run is queued, and *"two of the three
resolve themselves, so waiting is usually correct — which is exactly what trains a lane to
wait in the case where it never will."* A response that is right nearly always is not audited
in the case where it fails, whether the response is waiting for a run or believing a tool.

**The version that nearly happened is the useful part.** Suppose the operation field had taken
965 differing lines to 40 instead of 0. That number moves in the right direction, the
explanation is to hand, and nothing prompts a second look. It would have been written up as
*"the operation field mattered, here is the corrected figure"* — and it would have been wrong
with better evidence than before.

**A correction that improves your confidence without improving your instrument is worse than
the error it replaces**, because the original error was at least visible as a surprise. The
40 would have looked like diligence. The 0 was the only outcome that could not be explained
away, and it was the one that led to the fault.

So the habit is not *be suspicious of your tools*, which nobody can sustain. It is narrower:
**when a result is not merely unexpected but impossible, stop and ask what you are measuring
before you reach for why the subject behaved that way.** Impossible is a much smaller category
than surprising, and it is reliable — a diff that shrinks when detail is added, a count that
falls when a suite is added, a check that passes on a tree you know to be broken. Those are
not findings about the tree. They are findings about the instrument, every time.

## Coordination and process

**A claim that flatters its reader is audited by nobody (pre-publication PR 440).** The hub told a lane, and then
the maintainer, that *"every one of your first runs has failed on the README row and nothing
else"* and that its *"real failure rate on code is zero across four PRs"*.

It was false. pre-publication PR 440's first run failed on code:

```
run 35552183432
  FAIL    AION/DYNAMIC/TESTS      12 checks, some failing
  total checks executed: 4902
  VERDICT: FAIL
```

The README step did not merely lose to a worse failure — it was **skipped**, because the gate
failed first, so there was no row result in that run at all. And the hub had read that run, diagnosed the
failure, told the lane which site to wrap, and written the merge message that credits the
branch's own new test with catching a spawn site added hours after the test was written. Four
pull requests later it compressed the same history into *zero code failures*.

**This is not the failure the rest of this section catalogues, and the difference is the
point.** The others are checks reading the wrong object — a substring search over a window that
included comments, a control over a copy of the matcher, a fixture holding counts asked for
content. Each was *available* to be caught by anyone who looked, and several were.

This one survived because **it was generous**. The reader best placed to check it was the
person it praised, and the reader who wrote it had no reason to doubt a conclusion that made
the evening look tidy. A claim shaped so that verifying it is unrewarding for both parties is
audited by neither. It was caught only because that lane's first reaction to being praised was
to go and read the run — which is not a reliable property of anyone, and the lane said so.

**The accurate version was the stronger one**, which is what makes the error costly rather than
merely wrong. *Three of four first runs failed on the row alone; the fourth failed on a real
defect that the check added in that same pull request caught before a human did.* That survives
somebody opening the run. *Zero code failures* is demolished by one click, and it takes the real
point down with it — and the exception it elided was the best thing in the set.

**And that version names its sample, because this file's own rule applies to this entry.** *Three
of four* is a population claim, and an entry about a claim nobody audited must not contain a
count its reader cannot check. The four are every first CI run on that lane's **count-changing**
pull requests between 00:12 and 12:16 on 2026-09-21, verified individually rather than recalled:

| PR | first run | gate | why it failed |
|---|---|---|---|
| pre-publication PR 440 | 35552183432 | **FAIL** 4902 | `AION/DYNAMIC/TESTS` — the sweep catching `workflow.lisp:249` |
| pre-publication PR 429 | 35546959304 | PASS 4754 | README row only |
| pre-publication PR 453 | 35597664866 | PASS 5002 | README row only |
| pre-publication PR 456 | 35598560795 | PASS 4986 | README row only |

Two further pull requests in that stretch — pre-publication PR 451 and pre-publication PR 455, both docs — changed no counts and
passed first time. They are outside the sample because **a pull request that cannot fail on the
README row is not evidence about failing on it**, and the entry has to say so: a sample that
silently drops the cleanest cases looks chosen from outside, whatever the boundary was.

**That correction runs toward the flattering answer, which is why it needed making.** Naming all
six improves the lane's record rather than damaging it. A reader who assumes the bias in this
entry runs one way will not look at a boundary that happens to understate someone — and the
failure this entry describes is a claim bending toward the comfortable, not toward the harsh.
The direction is incidental; the absence of an audit is the mechanism.

Found in three passes, none available to the person who wrote the sentence: the lane reviewed the
entry and found two things, the hub re-ran the lane's table and found none, and the lane then
found a third by checking the boundary of its own table.

The habit: **when a claim about somebody's work is one that neither party has a reason to
check, that is the moment to open the evidence** — and a claim that flatters its reader is the
commonest case of that, not the whole of it. And prefer the version that concedes the
exception, because a claim that has already survived its own worst case cannot be taken apart
by a reader who finds it.

**That sentence was wrong until the fourth revision, in the ordinary way.** It first read *when
a claim comes out flattering*, which is the weaker rule and would not have caught the scope
error two paragraphs above — that boundary was wrong in the flattering direction *and* nobody
was going to check it, and only the second property explains why it survived. The thesis got
sharper while the closing line stayed as first written, so the entry refuted its own conclusion
and then restated it. A stale claim is found by comparing a document to the code; a
self-contradiction only by comparing a document to itself, and this file asks for both sweeps
because the second kind arrives exactly like this.

**A measurement and an explanation of it, written in the same voice, are indistinguishable to
the next reader — and the explanation is the half that rots (pre-publication issue 478, pre-publication issue 385).** Two instances on
one day, and **the asymmetry between them is the entry**: if both had been wrong this would be
about carelessness and would teach nothing.

**The one that had gone stale.** A note warned that forgetting `OURANOS_WITH_UV=1` drops 335
checks and that *"there is no warning in the output — grep the whole run for `uv` and you get
nothing, because the gate discloses what the PLATFORM axis skipped and not what the uv axis
skipped (pre-publication issue 385)"*.

The measurement was true: 4065 instead of 4400 on `d0547d1`, and it nearly went to the hub as
a discrepancy. The explanation was true when written and **pre-publication issue 385 is the ticket that fixed it**,
so the note cites the cure as the cause. `report-not-covered` is documented *"Printed ALWAYS,
including when nothing was declined"* and `report-uv-declined` emits `off  uv axis  this host
CAN answer these; the caller declined`. The surviving hazard is now *reading past a
disclosure*, which is a different and harder problem than the one the note defended against.

**The one that is probably true.** In the same day's AGENTS.md text: `gh api rate_limit`
reports full quota while GraphQL refuses, *"it answers about the primary limit and cannot see
the secondary one"*. The second clause is GitHub's documented behaviour and is very likely
correct. Nobody ran a control on it. It was written in the same voice as the figures beside it
— `5000/5000` alongside `API rate limit exceeded` — which were measured.

**That the second one is not even wrong is what makes the defect legible.** The problem is not
falsity. It is that a reader inherits the mechanism with the authority of the measurement, and
has no way to tell which half to distrust when the world changes underneath it. Measurements do
not rot: `5000/5000` was observed and stays observed. Explanations do, because they are claims
about a system that is still being changed — and the first instance is precisely one rotting
while its measurement stayed sound.

It is also why this is not covered by *a correction needs its cause*: that rule is about
supplying reasoning, and this is about **labelling** it. Both notes had their reasoning. Neither
said which part had been run.

**The practical form, which is cheap enough to actually do:** when a measurement and an
explanation sit in one paragraph, say which is which. Six words did it —
*"what was measured here is the symptom … not the mechanism"* — and it means the next person
who finds a different cause corrects a sourced claim rather than an anonymous one, instead of
"fixing" it from a private theory.

**A claim that confirms a pattern you have just learned is audited by nobody (#58).** The hub
reported that `create-portal-session` had a generic, an export and a dev-only implementation,
and no method for the real backend — so a consuming app would get a working dev story and a
failure the first time it pointed at production.

It was false. `stripe.lisp:164` implements it, completely, as the very next method after
`create-checkout`.

Two independent faults produced one confident finding. The first grep offered `customer.portal`
as an alternative and never tried plain `portal`, so the pattern could not match
`create-portal-session` at all. The second searched correctly and ended in `head -5`. There
were ten results; the method was the sixth. **The output stopped one line before the thing
that refutes it.**

**What nearly happened is why this is an entry and not a correction.** The lane taking the
ticket opened `stripe.lisp` to match the house style before writing the missing method. In
Common Lisp a duplicate `defmethod` silently replaces the existing one — no warning, no
error. A correct, complete implementation would have been overwritten from a ticket comment,
and the only reason it was not is that the file was opened for an unrelated reason. That is
luck wearing the clothes of method.

**The mechanism is not carelessness, and this is what distinguishes it from the entry above.**
A claim that flatters its reader goes unchecked because neither party gains by checking it.
This one went unchecked because **it confirmed a pattern the reader had just learned and
learned correctly**. A surface with no implementation behind it had turned up three times in
the same day. A fourth instance did not read as a claim; it read as the pattern again.

So the better your model of how this codebase goes wrong, the more readily a wrong instance of
it passes. Both people involved had spent the day finding real cases of exactly that shape,
and that is precisely what made a false one invisible. Being right about the pattern is what
buys the next instance its free pass.

**And the negative claim did carry command output, which made it worse.** AGENTS.md requires
one — *a negative claim needs its command output shown*. The output shown was truncated, so it
looked like the requirement had been met while proving the opposite of what it appeared to.
**Truncated evidence for an absence is weaker than no evidence at all**, because no evidence
invites the question and truncated evidence closes it.

The habit: when a finding matches a shape you have seen several times recently, that is the
moment the claim is least likely to be checked and most likely to be believed. Ask for the
command, and read it to the end.

**A relayed claim loses its container before it loses its content (#159).** The hub quoted a
sentence explaining why half of a known race had been fixed and half deliberately left, and
attributed it to `55cec37`'s merge message. The sentence is not there. `%srv-free-port`
appears in that message twice, both times about the ticket having named the wrong helper.

**The sentence was real.** The Windows lane had written it in a cross-session message, with
the reasoning intact: a port handed out and immediately re-bound is ordinary across test
suites, while a lingering listener is ours. A true statement, by a real author, about the
right thing.

What was false was **where it lived**. And it acquired authority in transit — from *a lane
told me* to *the merge message states* — without anyone deciding to promote it. Nobody
remembers a sentence together with its container; the memory keeps the content and drops the
provenance, which is what memory does.

**The existing rule is written for the opposite failure.** *Relaying a claim makes you its
second author* guards against repeating something **wrong**. The harder case is repeating
something **right** whose origin has been lost, because afterwards nothing about the claim
looks wrong. It reads correctly. It is correct. The only false part is the attribution, and
attribution is the one part a reader cannot check without going to look.

**Two consequences followed, and the second is worse than the first.**

The misattribution was caught only because the claimed location was a commit message, readable
with `git show` while the GitHub API was rate-limited. Had it been attributed to a pull-request
body that hour, there would have been no way to test it, and it would have entered the record
as fact.

And the real problem was underneath: **the reason for leaving half the race was recorded
nowhere a reader lands.** Not in the merge message, not on the ticket — only in one session's
scrollback. A maintainer arriving at `55cec37` to ask why half a race was fixed finds no
explanation, concludes oversight, and files a duplicate. Correctly, on the evidence available
to them.

That is *recorded locally is not filed upstream* applied to a **decision** rather than a
ticket, and it is worse than the ticket case: a missing ticket is visibly missing, while a
decision living in a transcript leaves a half-fix that looks like carelessness.

So when you relay, carry the container: *the Windows lane told me*, not *the record shows*. A
quote whose origin you cannot name in the same sentence is one you have already lost, whether
or not you have noticed.

**Recorded locally is not filed upstream (pre-publication issue 239).** Two careful app sessions nearly lost a defect
because one said "filed" meaning *filed in our ledger* and the other, hearing it, stood down to
avoid a duplicate. Both followed the convention as written; the ambiguity was in the
instruction. A maintainer closing a duplicate costs a minute and yields a second independent
account; a finding dropped because two consumers each deferred to the other costs the whole
finding, silently. So the instinct to avoid duplicates is overridden explicitly.

**Attribution (2026-09-02).** Two lanes diverged on `Co-Authored-By` in one afternoon — one
followed its harness, one followed AGENTS.md — which is worse than either answer, because a
history inconsistent about attribution says less than one uniformly silent. The maintainer
settled it: the file wins over the tool.

**Confidentiality (2026-08-18 → 08-25).** The client-vs-own-product distinction was decided and
recorded only in the gitignored `.private-names`, so for a week the correct policy lived where no
agent reads it while the blanket rule lived in AGENTS.md. A lane generalized its own maintainer's
products to "a consuming app" through several tickets, buying nothing. If a rule is not in the
file agents load, it is not a rule they have.

**A silent CL name collision (pre-publication issue 117).** `%stream-octets` was already the slot reader for
`octet-input-stream`; a chunk helper of the same name broke the *request* body path with no
warning, and surfaced in an unrelated suite as a fall-through `ETYPECASE`. The CL cousin of
Coalton's case-insensitivity hazard: silent collision, symptom elsewhere, message names neither.

**The shape of a failure tells you where to look.** A fresh worktree with `vendor/libuv`'s
*contents* copied into `vendor/` failed four uv suites at once, one of them untouched by the
diff. A suite failing that your diff cannot reach is evidence about your environment.
