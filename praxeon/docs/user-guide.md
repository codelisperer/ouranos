# Praxeon User Guide

How to get Praxeon running and talk to **Elise**, the reflective-companion demo
agent — plus configuring a provider, inspecting agents with the studio, and
troubleshooting.

> Elise is a demonstration of the Praxeon actor model, **not** a therapist and
> not a substitute for professional care. She includes a lightweight guardrail
> that surfaces crisis resources.

## Quick start (fresh machine)

Praxeon is one of six core frameworks in the [Ouranos monorepo](../../README.md) —
plus `hermes`, a satellite leaf-lib for external integrations (email/SMS, later
payments) — and you build the whole tree once, not this directory alone. After
installing **SBCL** and **Quicklisp**, from a clone of the monorepo run the repo-root
bootstrap:

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons
```

`bootstrap.lisp` points ASDF at the whole tree (writing a source-registry drop-in),
so every REPL finds the frameworks with no symlinking. Then edit `.env` with a
provider key (§1) and jump to [Talk to Elise](#4-talk-to-elise). The sections below
explain each piece for when you want to set things up by hand or need to troubleshoot.

(The framework-local `scripts/setup.sh` still works as an **interim** convenience —
it clones Coalton, seeds `.env`, and with `--test` compiles + runs the suite — but
discovery now comes from the bootstrap drop-in, not a `local-projects` symlink.)

## Prerequisites

- **SBCL** + **Quicklisp**.
- **`libev`** — the C library Woo (the web server) builds on. **Required**, because
  `praxeon/elise` depends on `praxeon/web`, so even the CLI loads Woo. Install it
  before first load: macOS `brew install libev`; Debian/Ubuntu
  `sudo apt-get install libev-dev`. (Symptom if missing: `quickload :praxeon/elise`
  or `cons dev` fails loading Woo.)
- **Coalton** — a local git checkout at `~/common-lisp/coalton/` (ASDF finds it
  on its default source-registry). Praxeon's typed core is written in Coalton.
- Dependencies (pulled by Quicklisp): `alexandria`, `dexador`, `com.inuoe.jzon`,
  `fiveam`, plus the web layer's `clack`, `woo`, `quri`, `spinneret`.
- An **LLM provider**: an Anthropic API key with credits, an OpenRouter key, or
  a local Ollama/LM Studio endpoint.
- **Optional**: a **Tavily** API key (`TAVILY_API_KEY`) to give agents web search.

> If loading fails with `Bug in readtable iterators or concurrent access?`, that's
> a dependency/toolchain issue, not Praxeon — see [Troubleshooting](#troubleshooting).

## 1. Configure a provider (`.env`)

Praxeon reads `PRAXEON_LLM_*` from the environment. The convenient way is a
project-local, git-ignored `.env`. Copy the template and edit it:

```sh
cp .env.example .env
```

Minimum to talk to Elise via **Anthropic**:

```sh
PRAXEON_LLM_IMPL=anthropic
PRAXEON_ANTHROPIC_MODEL=claude-sonnet-5        # or claude-opus-4-8
PRAXEON_ANTHROPIC_API_KEY=sk-ant-...
```

…or via **OpenRouter** (cheap, tool-capable):

```sh
PRAXEON_LLM_IMPL=openrouter
PRAXEON_OPENROUTER_MODEL=openai/gpt-4o-mini
PRAXEON_OPENROUTER_API_KEY=sk-or-...
```

Notes:

- Impls: `anthropic`, `openai`, `ollama`, `openrouter`.
- Every var can be **shared** (`PRAXEON_LLM_MODEL`, `PRAXEON_LLM_API_KEY`, …) or
  **per-provider** (`PRAXEON_<IMPL>_MODEL`, `PRAXEON_<IMPL>_API_KEY`, …). The
  per-provider form wins, so you can keep several providers configured and switch
  by changing **only** `PRAXEON_LLM_IMPL`.
- Inline `# comments` after a value are fine.
- `.env` is git-ignored — **never commit real keys.**

## 2. Make Praxeon loadable (one-time)

System discovery is automatic: `bootstrap.lisp` writes an ASDF `(:tree)` drop-in at
`~/.config/common-lisp/source-registry.conf.d/50-ouranos.conf` covering the whole
tree — the six core frameworks plus `hermes`. No symlinking into
`~/quicklisp/local-projects`, no `asdf:*central-registry*`. Run the repo-root bootstrap once (Quick start above) and
`:praxeon` loads from **any** REPL, in **any** directory.

## 3. Start a REPL and load Praxeon

```sh
rlwrap sbcl --dynamic-space-size 4096   # rlwrap = history/line-editing; plain `sbcl` works too
```

The `--dynamic-space-size 4096` matters on the **first** load: compiling Coalton
from source is memory-hungry and can exhaust SBCL's 1 GB default heap
(`Heap exhausted, game over`). The repo-root `bootstrap.lisp`, the `cons`
targets, and `setup.sh` already pass this (via `PRAXEON_DYNAMIC_SPACE_SIZE`); pass it
yourself when starting SBCL by hand.

```lisp
(ql:quickload :praxeon/elise)   ; first load compiles Coalton (~30-60s; cached after)
```

If Quicklisp isn't wired into your `~/.sbclrc`, run `(load "~/quicklisp/setup.lisp")`
first. `make-elise` finds the project's `.env` automatically (resolved via ASDF),
so you can run from any working directory.

## 4. Talk to Elise

```lisp
(praxeon/elise:start)     ; interactive session
```

End the session with `:quit`, `exit`, `quit`, `bye`, `q`, or **Ctrl-D**.

Then just chat. Example:

```
you> I have had a busy week and feel a bit worn out.
Elise> It sounds like you've had a lot on your plate. What's been keeping you so busy?
```

## 5. Talk to Elise in a browser (web server)

Elise also runs as a small web app — an HTMX + Bulma chat page with live
progress — served by `praxeon/web`. The same agent, the same provider config
(`.env`), just a different surface. From a REPL:

```lisp
(ql:quickload :praxeon/elise)   ; first web load pulls Clack/Woo/Spinneret

(defparameter *h* (praxeon/elise:start-web))   ; non-blocking; returns the handler
```

`start-web` builds the real Elise (reading your provider from `.env`), starts the
server on a background thread, and hands back the Clack handler. Then open:

```
http://127.0.0.1:8080
```

Type a message and hit **Send**: your bubble appears immediately, the status line
under the chat shows `… thinking` (and `→ using <tool>` if a means fires) while
the turn runs, and Elise's reply appears when it's ready. Stop the server with:

```lisp
(praxeon/web:stop *h*)
```

Notes:

- **Keep the REPL alive** — the server runs in a background thread of that Lisp
  image; quitting the REPL stops it.
- **Port**: pass `:port` (e.g. `(praxeon/elise:start-web :port 9000)`); default 8080.
  (Port 5000 is a bad default on macOS — the AirPlay Receiver squats on it.)
- **Server backend** is configurable via Clack — **Woo** on Unix/macOS, **Hunchentoot**
  on Windows (Woo doesn't build there), or force one with `PRAXEON_WEB_SERVER=hunchentoot`.
- **Live progress uses HTMX polling, not SSE** — an intentional choice driven by
  Woo's async model; see [`docs/wiki/Framework-Praxeon.md`](../../docs/wiki/Framework-Praxeon.md)
(the Studio / live-image section) for the rationale.
- **REST endpoint** — the same `POST /api/message` answers JSON for a program:
  ```sh
  curl -s localhost:8080/api/message \
       -H 'content-type: application/json' \
       -d '{"message":"I feel stuck"}'
  # -> {"reply":"…"}
  ```

**Or run it without a REPL** — the standalone binary serves the web app too (`cons`
runs the tasks from the framework's root `cons.lisp` build spec):

```sh
cons elise                 # build bin/elise (once)
bin/elise --server         # web app on http://127.0.0.1:8080
bin/elise --server --port 9000
bin/elise                  # (no flag) the interactive CLI, as before
```

For development without building, `cons serve` runs the web app straight from
source (equivalent to `(praxeon/elise:serve)`). The web page is Elise-specific —
its own **localized** title, intro disclaimer, and crisis-resources footer — built
by passing `:dictionary` + `:intro`/`:footer`/`:responder` to `praxeon/web:start`,
which is how any client app customizes the generic chat UI. The turn runs through
Elise's `respond`, so the **crisis guardrail applies in the browser exactly as in
the CLI**.

### Talk to Elise in your language

Elise ships an i18n dictionary (`examples/elise/resources/i18n/{en,es,ru}.json`) —
**drop a `<code>.json` file to add a language**. The chat page shows a small
language switcher (**EN · ES · RU**); the choice rides a `lang` cookie (and honors
`?lang=ru` or the browser's `Accept-Language`).

Beyond the chrome, Elise **converses in the selected locale**: a **translator
agent** renders your message into English for Elise and her reply back into your
language — Elise always deliberates in English, so her history and the (English)
crisis cues stay in one language, and localized crisis resources are appended in
yours. The translator is its own agent with its own model — point it at a fast,
multilingual model (see §8, `PRAXEON_TRANSLATE_MODEL`) while Elise thinks on a
stronger one. (This is the interceptor "edge effect" — `translate-in → run-turn →
translate-out` — see Hyperion's *Interceptors, reimagined*.)

### Hot-swap development (edit code, see it live)

The easy path is one call — **`(praxeon/elise:dev)`**. It keeps a *persistent*
Elise agent, serves the web app with `:dev t` on port 8080, and watches the source
tree. Edit a file, save, and the browser refreshes with your change — **and the
conversation is preserved.**

```lisp
(ql:quickload :praxeon/elise)
(praxeon/elise:dev)          ; persistent Elise + watcher; open http://127.0.0.1:8080
;; ... edit src/*.lisp or examples/elise/elise.lisp, save, keep chatting ...
(praxeon/web:unwatch)        ; stop the watcher + server
```

On each save you'll see `[dev] reloaded <file>` in the REPL — or `[dev] compile
failed: …` / `[dev] reload error: …` if you introduce an error, in which case the
server keeps running on the last good code so nothing is lost. From a shell,
`cons dev` does the same and drops you into the REPL with it running.

**Stopping it.** Call **`(praxeon/web:unwatch)`** — with no arguments it stops both
the watcher thread *and* the server it manages (it defaults to the active session).
Note the asymmetry: `dev` lives in `praxeon/elise` (it's Elise-specific), but the
stopper is the generic `praxeon/web:unwatch`, because the watcher is framework-level.
The server stops at once; the poll thread exits on its next tick (~½ s). To restart,
just call `(praxeon/elise:dev)` again. To tear down the whole image (which kills
everything, since it all lives in that one REPL), press **Ctrl-D** — that's also the
reliable hammer if `unwatch` ever seems wedged.

#### How the watcher works

`praxeon/elise:dev` calls the generic `praxeon/web:watch`, handing it a *builder*
thunk that starts the server around a persistent agent. `watch` then:

1. **Snapshots** the modification time (`file-write-date`) of every `.lisp` file
   under the watched roots (`src/` and `examples/elise/`), and starts a background
   poll thread.
2. **Polls** every ~0.5 s: re-reads those times and diffs them against the
   snapshot. When one is new or newer, it calls `reload!`.
3. **`reload!`** recompiles the changed file(s) (`compile-file` + `load`). On a
   **clean compile** it stops the old server, calls the builder again to start a
   fresh one — *reusing the same agent* — and bumps a reload epoch. On a **compile
   error** it leaves the running server untouched and records/prints the error.
4. Pages served with `:dev t` embed a tiny poller of `GET /api/reload-epoch`; when
   the epoch changes, the page calls `location.reload()` — so the tab refreshes
   itself.

The crucial property: **the agent lives in the builder's closure, *outside* the
server**, so rebuilding the server never touches the conversation. *State ≠
server.* (Caveats: `file-write-date` has 1-second resolution, so two saves within
the same second may wait for the next poll; and run one server per image — Woo's
libev doesn't like two at once.)

#### Finer control (any app, or single-`defun` swaps)

Without the watcher you can drive it by hand — start non-blocking with
`(praxeon/elise:start-web :dev t)`, recompile just the changed `defun` (`C-c C-c`
in SLIME/Sly; "Load File" or inline-eval in VS Code Alive — **in the same image as
the server**), then `(praxeon/web:mark-reloaded)` to refresh tabs. Render/handler
**functions** hot-swap this way because the server calls them by name; values
captured at start (`title`, `intro`, `port`) and the route set need the server
rebuilt — which `reload!` does for you, reusing the agent. The **repl-workflow**
skill has the full rules and the two Lisp gotchas behind them.

## 6. Inspect with the studio

Instead of the built-in loop, drive an agent yourself and watch it — the studio
renders the live image (all provider-neutral):

```lisp
(defparameter *e* (praxeon/elise:make-elise))
(praxeon/studio:describe-agent *e*)                 ; provider, model, budget, means
(praxeon/actor:run-turn *e* "I've been feeling overwhelmed.")
(praxeon/studio:show-transcript *e*)                ; the whole conversation, rendered
```

For an agent that has **tools** (means), `(praxeon/studio:trace-turn agent "…")`
prints one turn's `deliberate → act → result → answer` steps. `agent-summary`
returns the same data as a plist (the hook a future graphical/REST studio uses).

**Live progress** — to report what an agent is doing *between* request and
response (a CLI status line), bind a `status-observer` around the turn:

```lisp
(praxeon/event:with-observer ((praxeon/studio:status-observer))
  (praxeon/actor:run-turn *e* "add 2 and 3"))
;;   … thinking
;;   → add(a=2, b=3)
;;   ← 5
;;   … thinking
```

The loop emits neutral events (`:deliberating` / `:tool-call` / `:tool-result` /
`:answer`); the observer renders them. Elise's `start` already does this. Because
the events are plain data, a web client can render the same stream over SSE.

## 7. Watch the studio live (editor-connected REPL)

The studio functions are **on-demand** — you call them to look. To watch an agent
*while* you work with it, use a **shared live image**: run a Swank/Slynk server in
the SBCL process and connect your editor (Emacs **SLIME/Sly**, VS Code **Alive**).
One image, two views — a chat/eval REPL and your editor's inspector — over the
*same* agent.

A second plain terminal does **not** work: each `sbcl` is a separate image and
can't see an agent living in another process. (And `(elise:start)`'s loop blocks
on input, so you can't interleave studio calls with it either.)

1. Start the server (many keep a `swankd`-style shell alias for this):
   ```lisp
   (ql:quickload :swank)
   (swank:create-server :port 4005 :dont-close t)
   ```
2. Connect your editor — Emacs: `M-x slime-connect` → `localhost` / `4005`.
3. In the connected REPL, load Praxeon and keep the agent in a **global**:
   ```lisp
   (ql:quickload :praxeon/elise)
   (defparameter *e* (praxeon/elise:make-elise))
   ```
4. Chat and inspect the same agent, interleaved — this *is* the live studio:
   ```lisp
   (praxeon/actor:run-turn *e* "I've had a rough week.")
   (praxeon/studio:show-transcript *e*)     ; watch it grow
   (praxeon/studio:describe-agent *e*)
   ```
   In SLIME you can also `M-x slime-inspect` the agent to browse its history,
   provider, and means interactively.

**Skip `(elise:start)` here** — that blocking loop is for a bare terminal. In a
connected image the REPL *is* the interface, and the global `*e*` is always
inspectable. (To run the chat loop *and* inspect concurrently, run it in a thread:
`(sb-thread:make-thread (lambda () (praxeon/elise:start)))`.)

> A continuous, streamed trace (events emitted as the loop runs) is a roadmap
> item — the studio "live-trace events." Today the studio is on-demand.

## 8. Switch providers or models

With per-provider vars set (step 1), switching is one line in `.env`:

```sh
PRAXEON_LLM_IMPL=anthropic        # <-> openrouter, ollama, openai
```

### Per-agent models (roles)

Model config is **not global** — each agent resolves its own provider by **role**.
Resolution is most-specific-first: `PRAXEON_<ROLE>_<VAR>` > `PRAXEON_<IMPL>_<VAR>` >
the shared `PRAXEON_LLM_<VAR>` (for `MODEL`, `IMPL`, `API_KEY`, `AUTH`, `BASE_URL`).
So one process runs several agents, each on its own model/vendor:

```sh
PRAXEON_LLM_MODEL=claude-sonnet-5                  # shared default (any role)
PRAXEON_ELISE_MODEL=claude-opus-4-8                # Elise deliberates (therapist)
PRAXEON_TRANSLATE_MODEL=claude-haiku-4-5-20251001  # the translator agent
# PRAXEON_SCRIBE_MODEL=...                          # a future agent: just add a var
```

In code, an agent asks for its role's provider — NIL role = the old global default:

```lisp
(praxeon/llm:make-provider-from-env :role :elise)      ; PRAXEON_ELISE_* -> PRAXEON_LLM_*
(praxeon/translate:make-translator)                    ; role :translate, by default
(praxeon/llm:model-of (praxeon/llm:make-provider-from-env :role :scribe))  ; check it
```

In a **fresh** REPL this is automatic. To pick up an edited `.env` in a
**running** REPL, force a reload (env vars already set are not overwritten by
default), then rebuild the agent:

```lisp
(praxeon/config:load-dotenv :override t)
(defparameter *e* (praxeon/elise:make-elise))
```

## 9. Coordinate multiple agents (delegation + workflow)

Praxeon runs several agents together two complementary ways — and each agent keeps
its own provider, so its own model/vendor (see §8, roles). `actor` =
`praxeon/actor`, `wf` = `praxeon/workflow`; both are network-free tested.

**Delegation (model-driven)** — register one agent as another's *means*. The
coordinator's model decides to call it; the sub-agent runs its *own* turn and its
answer returns as the tool result:

```lisp
(actor:register-agent-as-means coordinator translator)  ; sub advertised by its name
;; now the coordinator's model can delegate a subtask to `translator`, which
;; deliberates on its own provider and hands back its answer.
```

**Workflow (code-driven)** — sequence agents through ordered steps (and `parallel`
fan-out groups) toward a shared goal, threading each output through a shared
blackboard:

```lisp
(defvar *flow*
  (wf:make-workflow :report "Produce a report"
    (wf:step :research researcher "find sources on X")
    (wf:parallel                                   ; fan-out: independent, isolated
      (wf:step :pro pro "argue for")
      (wf:step :con con "argue against"))
    (wf:step :write writer                         ; a prompt fn reads the blackboard
      (lambda (bb) (format nil "Write using: ~A / ~A"
                           (wf:bb-result bb :pro) (wf:bb-result bb :con))))))

(let ((bb (wf:run-workflow *flow*)))
  (wf:bb-final bb))                                ; the last step's answer
```

Delegation is the model's choice; a workflow is your deterministic plan. See
[`docs/wiki/Framework-Praxeon.md`](../../docs/wiki/Framework-Praxeon.md) (multi-agent
coordination). (This is the substrate for Elise's future "Scribe" and for
ChatRBT — a background agent producing structured artifacts alongside the chat.)

## 10. Put a spend ceiling on an agent (`praxeon/ceiling`)

An agent endpoint anyone can reach is billed to one API key. Before exposing one, give it a
ceiling — and give it the kind that **refuses before spending**, not the kind that discovers
the limit afterwards.

### Two ceilings, and only one of them is the framework's

- **The runaway cap** — *one person with `curl` and a loop*. Per session, bounded by tokens
  and by calls. **This is praxeon's job**, and it is what this module does.
- **The monthly tier quota** — *what this membership tier includes*. **This is your
  application's job**, enforced when it mints a grant, because your application is what holds
  the ledger and the pricing model.

Splitting them is what lets the agent hold no database credential.

### The grant

Your application signs a grant with an **Ed25519 private key**. Praxeon verifies it with the
**public** key, so this side can check a grant and cannot issue one — compromising the agent
host does not yield unlimited-budget grants.

```json
{ "principal": "user-42", "group": "acme",
  "capabilities": ["search"],
  "token_cap": 50000, "call_cap": 20,
  "expires_at": 3960000000, "audience": "my-agent" }
```

```lisp
(defvar *verifier* (ceiling:make-ed25519-verifier *app-public-key* :audience "my-agent"))

(let* ((grant  (ceiling:verify-grant *verifier* payload signature))
       (ledger (ceiling:make-ledger grant)))
  ...)
```

`verify-grant` signals `grant-invalid` — with a reason — on a bad signature, an expired
grant, or one minted for a different audience. The signature is checked **before** anything
in the payload is believed, including its expiry.

### Enforcement is a stage, so a refusal costs nothing

```lisp
(turn:run-chain (list (ceiling:budget-guard ledger :estimate 1200)
                      (ceiling:capability-guard ledger "search")
                      (ceiling:meter ledger :model "claude-x"
                                            :input-fn       (lambda () (llm:completion-input-tokens c))
                                            :output-fn      (lambda () (llm:completion-output-tokens c))
                                            :cache-read-fn  (lambda () (llm:completion-cache-read-tokens c))
                                            :cache-write-fn (lambda () (llm:completion-cache-write-tokens c))))
                effect
                (turn:make-turn user-input "en"))
```

The guards are **enter** stages: a refusal halts the chain and the model call never happens.
The meter is a **leave** stage, so a refused turn is not billed for the budget it was
refused by.

**Wire all four counts** (#417). A provider reports base input, output, tokens *read* from a
cached prefix and tokens *written* to one, and `input_tokens` is the input that was **not**
served from cache. A meter given only the first two charges nothing for a cached prefix —
measured before the fix, a turn reporting `input 10 / output 40 / cache-read 5000` charged
**50**, and ten such turns against a 1000-token cap left the guard still permitting more
after the session had reported 50500. Omitting the two cache readers still compiles and still
runs; it just under-counts, in the direction that reads as headroom.

All four counts are recorded **separately** in the usage line, with `:charged` beside them:
`NIL` means the provider reported nothing and `0` means it reported a miss, and a line that
folded a cache read into `input` could bound a runaway but could not explain a bill.

What the guard *charges* is `ceiling:chargeable-tokens` under `ceiling:*token-weights*`,
which is **parity by default** — one chargeable token per reported token, whatever kind. The
cap is denominated in tokens, not money, and a guard should over-count a cheap token rather
than under-count it. A host that wants cost-shaped accounting binds `*token-weights*`; its
docstring carries the provider's price ratios with the date they were read, because those are
a vendor fact that changes.

One consequence for `budget-guard`: since the cached prefix is now charged, **the estimate has
to include it**. The `1200` above was written when a cache read cost the ledger nothing; a
workload of short turns against a large shared prefix should pass an estimate that includes
the prefix size.

### Reading the ceiling before you hit it

```lisp
(ceiling:remaining-tokens ledger)   ; => 48800
(ceiling:remaining-calls  ledger)   ; => 19
(ceiling:affordable-p ledger 1200)  ; => T
```

Render *"you have N left this month"* from these. A ceiling you can only discover by hitting
it is not much of a ceiling.

### Refusals are hard, and deliberately so

```lisp
(let ((tn (turn:run-chain chain effect (turn:make-turn input "en"))))
  (if (turn:turn-halted tn)
      (render-refusal (turn:turn-note tn))   ; say so, in the user's language
      (render-reply (turn:turn-reply tn))))
```

There is **no silent degradation** anywhere in this design — no quiet switch to a cheaper
model when the budget runs low. Unpredictable output quality is a compliance problem in a
regulated-adjacent product, not merely a worse experience, so the failure mode is a legible
refusal that a caller can distinguish from an answer without parsing text.

### Metering, and why the agent needs no database

```lisp
(ceiling:usage-report ledger)
;; => ((:principal "user-42" :group "acme" :model "claude-x" :means "search"
;;      :input 900 :output 300 :at 3960000123) ...)
```

Per model, per **(user, group)** — a single org-level counter answers neither *what does this
tier cost us* nor *what did this group consume*. Return this **in-band** with your reply and
write it into your own ledger. That is what keeps the agent free of a database credential;
had the agent written to a store, the credential cost would have been paid anyway.

### Still open

**Rate limiting** beyond the per-session call cap — a refused caller can ask for another
session, and stopping that is your minting decision.

The **prompt-injection posture** of #122 that used to be listed here has landed: `agent-means-for`
assembles the tool table from the caller's authority, `grant-permit-fn` turns a signed grant into
the predicate it needs, and `act` re-checks at call time, so a means the caller may not use is
absent rather than filtered by prompt. See §11 for the shape. #122 remains open for its other
halves (co-hosting postures, service-contract details).

## 11. Let an agent answer questions from your database (`#400`, ADR-0002)

The obvious reading is generated SQL: hand the model your schema and let it write the query.
**Don't.** The pattern is **a means per query, parameterised** — the model *selects* a question and
supplies arguments; it never composes the query.

```lisp
(defun %one-required-string (name description)
  (let ((prop (make-hash-table :test 'equal))
        (props (make-hash-table :test 'equal))
        (schema (make-hash-table :test 'equal)))
    (setf (gethash "type" prop) "string"
          (gethash "description" prop) description)
    (setf (gethash name props) prop)
    (setf (gethash "type" schema) "object"
          (gethash "properties" schema) props
          (gethash "required" schema) (vector name))
    schema))

;; ONE registration serves every caller. The asker is closed over by the host, not
;; supplied by the model.
(defun register-data-means (agent asker)
  (actor:register-means
   agent "contacts-at-company"
   "Find contacts at a company, limited to what the asker may see."
   (lambda (args)
     (let ((company (gethash "company" args)))
       (format nil "~{~A~^, ~}"
               ;; a FIXED query shape; the value binds (mnemosyne/query returns
               ;; (values sql params) and asserts that in its own suite)
               (my-app:contacts-for :asker asker :company company))))
   :schema (%one-required-string "company" "The company name to search for.")
   :capability "read:contacts"))
```

Four properties follow, and each is one generated SQL does not have:

| property | why |
|---|---|
| **A knowable blast radius** | the runnable set is `agent-means-for`, enumerable at runtime. With generated SQL it is whatever the model emits |
| **Authorization as an argument** | the asker is supplied by the *host* and is not in the schema, so a model cannot widen its own authority by choosing arguments |
| **An audit trail that means something** | `:tool-call` carries the means name and its arguments — what was *intended*, not just what ran |
| **Evidence for what to build next** | the logs say which questions are actually asked, and which means deserve an index |

**A means the caller may not use is absent from the tool table, not filtered afterwards.** Pass a
permit — `(ceiling:grant-permit-fn grant)` turns a signed grant into one — and it travels to both
halves of the loop: the table the model is shown, and the check at the moment of use.

```lisp
(actor:run-turn agent question :permit (ceiling:grant-permit-fn grant))
```

`act` re-checks at call time as well as at advertisement time, because a model can name a tool it
was never offered — from its training, from an injected instruction, from a stale history.

> **`run-turn` gained `:permit` in #400.** Before that it took none and passed none, so a
> capability-bearing means — which is what this whole pattern recommends — was invisible and
> uninvocable through the framework's main entry point, and an app could only reach one by driving
> `deliberate` and `act` by hand. Found by writing this section's example and watching the turn
> loop refuse the means the section recommends. `run-turn-through` and a delegated sub-agent carry
> it too; a subtask that silently lost the permit would be the same hole one level down.

**Why not generated SQL, stated plainly:** it is three surfaces at once — exfiltration (the model
reads what the *schema* permits, not what the *asker* permits), injection (the prompt is
attacker-reachable wherever user content enters context), and unbounded cost (a join nobody
predicted). None is mitigated by prompting; all three are mitigated by the model not writing the
query. A single `query` means taking a structured `(:select …)` is the same problem in
parentheses: data is not the safety property, *a fixed shape with bound values* is.

The reasoning, the rejected alternatives (including a read-only replica with row-level security)
and the ordering against #372's semantic-search seam are in
[`docs/adr/0002-data-access-through-means.md`](adr/0002-data-access-through-means.md).

## 12. Run the tests

Network-free (uses a scripted provider, no API key needed):

```lisp
(ql:quickload :praxeon/tests)     ; pulls fiveam
(asdf:test-system :praxeon)       ; runs the fiveam suite
```

## Building (`cons` targets)

> A root `cons.lisp` build spec drives these tasks; run `cons <target>` from the
> framework's directory (bare `cons` lists them). This replaced the top-level
> `Makefile`, which has been removed.

The build spec ties the pieces together (bare `cons` lists everything):

```sh
cons check      # compile + test (the quick cycle)
cons elise      # build a standalone bin/elise executable (no SBCL needed to run it)
cons paper      # compile paper/main.pdf
cons all        # system + tests + binary + paper
cons run        # run Elise interactively in the CLI (dev; no build)
cons serve      # run Elise as a web app on :8080 (dev; no build)
```

(To clean up, remove `bin/` and the paper artifacts manually — there's no clean
target yet.)

`bin/elise` reads its provider config from the environment or a `.env` in the
directory you run it from, so you can drop it on your `PATH` and run `elise`
anywhere.

## Troubleshooting

- **`Heap exhausted, game over.`** on the first load — compiling Coalton from
  source needs more than SBCL's 1 GB default heap. Start SBCL with a bigger heap:
  `sbcl --dynamic-space-size 4096`. The repo-root `bootstrap.lisp`, the `cons`
  targets, and `scripts/setup.sh` already do this (override via
  `PRAXEON_DYNAMIC_SPACE_SIZE`); only a hand-started bare `sbcl` misses it. Once
  Coalton is compiled and cached, later loads are cheap.
- **`no LLM impl registered for PRAXEON_LLM_IMPL=…`** — the impl value is
  unrecognized. Valid: `anthropic`, `openai`, `ollama`, `openrouter`.
- **HTTP 400 (with a body)** — the error now includes the provider's response
  body; read it. Common causes: a bad model id, or no credits.
- **`Your credit balance is too low`** — add API credits to the org your key
  belongs to (Anthropic Console → **Plans & Billing**). A Pro/Max **subscription
  does not fund the raw API**; only prepaid API credits do.
- **Elise has no provider / `.env` isn't read** — you didn't start SBCL from the
  repo root. Either `cd` there first, or run
  `(praxeon/config:load-dotenv :path "/abs/path/.env")` before `make-elise`.
- **`Bug in readtable iterators or concurrent access?` on load** — an
  `fset` / `named-readtables` incompatibility, typically from the **Ultralisp**
  dist on a very new SBCL. Fix: disable Ultralisp
  (`(ql-dist:disable (ql-dist:find-dist "ultralisp"))`), update the Quicklisp
  dist, and clear stale fasls (`rm -rf ~/.cache/common-lisp/`).

## See also

- `docs/editor-setup.md` — VS Code / Neovim / Emacs + SBCL REPL wiring (the
  closest thing to a rich, Rebel-Readline-style REPL).
- `docs/roadmap.md` — where Praxeon is headed.
- `README.md` — the thesis and architecture.
