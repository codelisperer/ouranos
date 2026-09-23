# Onboarding — zero to productive

*The path from "I know nothing about Common Lisp and have none of the tooling" to "I can
build high-quality apps with this — and better still, deliberately with an AI." Written
2026-08-04. Positioning input for pre-publication issue 91;
the gaps map to existing issues at the end.*

> **Who this is for, precisely: experienced engineers who have heard of Lisp and never seen
> a reason to get past the parentheses.** Not novices. They do not need programming
> explained, they need the trade explained — and they will evaluate it in minutes and
> leave. Every choice below follows from that: no tutorials, no history, no advocacy. Show
> the thing that is hard elsewhere working here, and make the syntax stop being the
> conversation.

---

## 1. There are two users, and we currently serve one

This is the structural problem, and it is easy to miss because the path we exercise daily
is the one that works.

| | **Contributor** — works *on* Ouranos | **App developer** — builds *with* Ouranos |
|---|---|---|
| Wants | the monorepo, the frameworks, the tests | one command, a project, a running app |
| Today | `git clone` → `setup.sh` → `bootstrap.lisp` → `bin/cons`. **Works.** | …also has to clone the framework monorepo. **This is not a path, it is a workaround.** |
| Analogue | contributing to Rust | `cargo new` |

`cons init` exists and scaffolds `lib` / `cli` / `web` / `agent` projects — but you obtain
`cons` by cloning Ouranos and bootstrapping it. **No app developer should ever see the
framework monorepo**, any more than a Rust programmer clones `rust-lang/rust`. That is
[#34](https://github.com/codelisperer/ouranos/issues/34) (distribute the `cons` binary,
make it self-hosting), and this doc is the argument for its priority: it is not a
convenience, it is the entire app-developer on-ramp.

## 2. The bar

What "zero to running app" costs elsewhere, on a machine with nothing installed:

| | Command | Prereq | Time |
|---|---|---|---|
| Node | `npx create-next-app@latest` | Node installed | ~60s |
| Rust | `curl …rustup.rs \| sh` then `cargo new` | none | ~2 min |
| Python | `curl …astral.sh/uv \| sh` then `uv init` | none — **uv installs Python itself** | ~1 min |
| Deno | one binary; TS built in | none | ~30s |

Two patterns worth stealing:

- **rustup / uv solve the chicken-and-egg with a non-target-language installer.** A tiny
  shell/PowerShell script fetches a prebuilt binary, which then manages the toolchain.
  **`scripts/setup.{sh,ps1}` is already exactly this shape** — it is not a stopgap, it is
  the right architecture.
- **uv installs the language runtime.** The closest analogue to what `cons` should be: a
  single artifact that provisions SBCL, the dependency source, and the pinned Coalton.
  `setup.sh` already does all three.

## 3. Where we actually are — and the README now says so

`scripts/setup.sh` installs, idempotently and without sudo on Linux: **SBCL** at the pinned
version, **Quicklisp** with a pinned dist snapshot, and **Coalton** as a git checkout at
`coalton.pin`. `setup.ps1` does the Windows equivalent.

So the true bare-machine path is already:

```sh
git clone https://github.com/codelisperer/ouranos.git && cd ouranos
./scripts/setup.sh
sbcl --dynamic-space-size 4096 --script bootstrap.lisp
bin/cons init myapp --template web
```

**FIXED (pre-publication issue 227).** The README used to tell readers this was *"planned; until it lands,
install those two yourself"* — understating what works, which costs exactly the readers who
bounce at "install SBCL and Quicklisp yourself" and never find out that a script does it.
It now documents `scripts/setup.sh` directly. This paragraph is kept rather than deleted
because the *shape* of the mistake is the lesson: we were arguing against ourselves in the
one document a first reader judges the project by.

**VERIFIED (pre-publication issue 88, closed).** This paragraph used to say none of it had run on a machine
without a working tree. `scripts/verify-clean-machine.sh` now provisions a container that
has none of it — CI cannot cover this, because runners arrive with a toolchain. First-run
failure is still unrecoverable, so the verifier is the thing that keeps it honest.

## 4. The first-win moment

Getting a toolchain installed is not a win. A win is the thing on screen sixty seconds in
that makes someone want to keep going.

`cons init --template web` scaffolds a runnable Hyperion app — good, and roughly at
parity with `create-next-app`.

**Parity is not the goal.** The striking first win available to us and to nobody else is
a `desktop` template: `cons init myapp --template desktop && cons run` opening a **native
OS window** running a hot-reloading server-rendered app, ~30–50 MB, no Electron, no Node,
no bundler. The desktop Coalton REPL already proves every piece works. There is no
template for it yet ([#73](https://github.com/codelisperer/ouranos/issues/73) is the
adjacent work).

That is a demo people record and post. `create-next-app` cannot answer it.

## 5. The parenthesis objection — answer it by arithmetic, not advocacy

The audience's stated objection is the syntax. Arguing with it loses, every time, because
it is not really an argument — it is a cost estimate, made in five seconds, by someone with
finite patience.

So answer it as a cost estimate. **The parentheses are the price of homoiconicity, and
homoiconicity is what deletes the other syntaxes.** Count what a working TypeScript web
developer holds in their head on a normal day:

| | Typical stack | Ouranos |
|---|---|---|
| Language | TypeScript | CL |
| Markup | JSX | *s-expressions* |
| Styles | CSS / a CSS-in-JS DSL | *s-expressions* (LASS) |
| Client script | TS → transpiled JS | *s-expressions* (Parenscript) |
| Queries | SQL in strings | *s-expressions* |
| Build config | a bundler config DSL | *s-expressions* (`cons.lisp`) |
| **Distinct syntaxes** | **6** | **1** |

That is a number an experienced engineer can evaluate without being persuaded of anything.
The parens are not free — they buy the elimination of five context switches, a build step,
and a class of errors that only exists because a template language cannot see the types
underneath it.

The second half of the answer is mechanical: **you do not type them.** Every serious CL
editor does structural editing (paredit / parinfer); parens are maintained the way `gofmt`
and Prettier maintain formatting — you stop thinking about them within an hour. That makes
editor setup an *adoption-critical* path, not a nicety
([#42](https://github.com/codelisperer/ouranos/issues/42)): a reader who opens a file in a
plain editor and starts counting brackets by hand has been failed by our docs, not by the
language.

Do not make either point in prose before showing something working. This is the answer for
when they ask — not the opening.

## 6. Translate; do not teach

Same audience, same principle: they already have the concepts. What they lack is the
mapping. One page per origin language, each answering the same questions in that
language's vocabulary:

| They know | The bridge |
|---|---|
| `async`/`await` | the loop, futures, and *real threads* — we do not need `nextTick` because we are not single-threaded |
| TypeScript types | Coalton: real Hindley–Milner inference, not gradual annotation — and only where it earns its keep |
| JSX | Spinneret — HTML *is* the data structure, no template language, no compile step |
| `npm run` scripts | `cons` targets from a declarative `cons.lisp` |
| `try`/`catch` | conditions **and restarts** — recovery without unwinding, which has no equivalent in any of these languages |
| REPL notebooks | the live image: redefine a function in a *running* server and the next request uses it |

Two of those rows are places we are genuinely ahead rather than at parity — restarts and the
live image. Lead with them.

## 7. The AI-intentional path — the part nobody else has

`cons conform` already exists and its own header names the move: *"ship the framework SPEC
as dotfiles an IDE assistant reads, so a user building on codelisperer gets
spec-conformant code regardless of which AI they use."* Tool-neutral `AGENTS.md` as the
canonical content, with `CLAUDE.md` and `.cursor/rules` pointing back at it, plus
`.claude/skills` for the error-prone paths.

**Neither Node nor Python ships anything like this.** A scaffolded Next.js app does not
teach your assistant Next.js's house rules; it hopes the model already absorbed them from
training data. Ouranos can hand the assistant the spec.

That inverts the usual objection. *"An LLM won't know your obscure framework"* becomes
**"an LLM does not need to — the framework tells it, in a tool-neutral format, at scaffold
time."** For a young framework that is not a consolation prize, it is a structural
advantage over any framework big enough to be in the training data but too fluid to be
current in it.

**Recommendation: `cons init` should run `conform` by default**, not leave it as a separate
verb someone has to discover. The AI-ready project is the default project.

## 8. The bar, made checkable

The reaction we are aiming for is specific: *"this is as well thought out — developer
ergonomics, modern enterprise, agentic AI — as anything else out there."* That is not a
slogan to write, it is a judgment a senior engineer forms in about ten minutes from
signals they check almost unconsciously. Worth listing them, because most are cheap and we
already pass several that comparable projects fail.

| What they check | Us, honestly |
|---|---|
| README says what this is in 30 seconds | needs work — and it currently *understates* the tooling (§3) |
| First command succeeds | **unverified on a clean machine** (pre-publication issue 88) — the highest-risk item here |
| Tests exist, run, and the count is visible | **594 checks, one command, fails on a suite that runs zero** (pre-publication issue 116) |
| CI green on *their* platform | **missing** (pre-publication issue 87) — the most conspicuous gap |
| Decisions are written down | **11 ADRs + a cross-cutting decisions log.** Genuinely better than most commercial codebases |
| Docs match the code | mostly, and we have caught three drifts this week by looking |
| Licensing unambiguous | MIT, one root `LICENSE`, matching every `.asd` |
| Supply chain | **pinned Coalton SHA, pinned Quicklisp dist, libuv pinned by sha256 and built from source, no grovel on the load path.** Most Node projects cannot say any of that |
| Observability | `aion/log` — structured fields, never interpolated strings, correlation id at the seam |
| Security posture | session ids are 128 bits from the OS CSPRNG (`aion/random`, pre-publication issue 95), rotated at privilege change (pre-publication issue 207); a body-size ceiling and a per-session spend ceiling exist. Still incomplete — see the open `area:launch` items rather than this line |
| Upgrade / deprecation policy | **absent.** An enterprise reader looks for this early |
| Can my AI assistant work in it | **`AGENTS.md` + `cons conform`** — see §7. Nobody else ships this |

Two takeaways. **The engineering-maturity signals are already strong** — ADRs, a decisions
log, pinned everything, a test harness that refuses to report false green. Those are
exactly what "well thought out" is judged on, and they are the hardest to fake. **The gaps
are almost all presentation and verification**, not architecture: CI, a clean-machine run,
a README that tells the truth, a deprecation policy. That is a good position to be in a few
weeks before publishing.

### The line

> **Lisp put AI on the map. AI is returning the favour — putting Common Lisp, with
> Coalton, back on it, ready to compete with the big boys.**

The README already gestures at this; "returning the favour" is the sharper form and it
earns the AI-friendliness work (§7, [#81](https://github.com/codelisperer/ouranos/issues/81))
its place as the headline rather than a feature. It also sets up the §5 answer without
arguing: the reason a 1958 language is worth another look is that the thing which made it
awkward for humans — code as data — is exactly what makes it tractable for machines.

Use it once, near the top, and then spend the rest of the page showing rather than saying.

## 9. The gaps, as work

| Gap | Issue | Cost |
|---|---|---|
| README understates what `setup.sh` already does | *(new)* | minutes — do it now |
| Never run on a clean machine, any OS | pre-publication issue 88 | the highest-value verification we are not doing |
| App developers must clone the monorepo | [#34](https://github.com/codelisperer/ouranos/issues/34) | **the whole app-developer on-ramp** |
| No `desktop` template — the best first win is unreachable | [#73](https://github.com/codelisperer/ouranos/issues/73) | the demo people would share |
| No translate-don't-teach docs (§6) | *(new)* | the fastest adoption lever per hour spent |
| Editor setup is not treated as adoption-critical (§5) | [#42](https://github.com/codelisperer/ouranos/issues/42) | a reader hand-counting brackets has been failed by our docs |
| `conform` is opt-in rather than default | *(new)* | one line in `cons init` |
| No lockfile / per-project isolation (npm, pip, cargo all have it) | [#86](https://github.com/codelisperer/ouranos/issues/86) | table stakes, blocked on pre-publication issue 91 |
| No upgrade / deprecation policy (§8) | *(new)* | an enterprise reader looks for it early |

The first, sixth and seventh rows are hours of work. The second is a day. Together they
move the story further than any feature currently on the board.
