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
- The shared `PRAXEON_LLM_*` settings apply only to the provider `PRAXEON_LLM_IMPL`
  names. Any other provider (for example one a role selects, §8) takes its settings
  from its role's or its own variables.
- Embeddings are configured separately, with their own variables (§8, "Embeddings").
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
The shared level applies only when the role's provider is the one `PRAXEON_LLM_IMPL`
names. A role that selects a different provider (`PRAXEON_<ROLE>_IMPL`) gets its
settings from `PRAXEON_<ROLE>_<VAR>` or `PRAXEON_<IMPL>_<VAR>`. When that provider is
a hosted one (`anthropic`, `openrouter`) and neither key variable is set, building it
signals `praxeon/conditions:missing-provider-key`, which names both variables.
So one process runs several agents, each on its own model/vendor:

```sh
PRAXEON_LLM_MODEL=claude-sonnet-5                  # shared default (any role)
PRAXEON_ELISE_MODEL=claude-opus-4-8                # Elise deliberates (therapist)
PRAXEON_TRANSLATE_MODEL=claude-haiku-4-5-20251001  # the translator agent
# PRAXEON_SCRIBE_MODEL=...                          # a future agent: just add a var
```

In code, an agent asks for its role's provider — NIL role = the old global default:

```lisp
(praxeon/llm:make-provider-from-env :role :elise)      ; PRAXEON_ELISE_* -> PRAXEON_<IMPL>_* -> PRAXEON_LLM_*
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

### The output limit (`:max-tokens`)

Each model call of a turn may generate at most a set number of output tokens. The text, the
arguments of a tool call and a thinking model's thinking all count. The limit is `:max-tokens`
on `run-turn` (or `run-turn-through`), else the agent's `max-tokens` slot, else
`praxeon/llm:*default-max-tokens*`, which is 8,192. It is a ceiling, not a charge: a provider
bills the tokens the model generates.

```lisp
(praxeon/actor:make-agent :provider p :max-tokens 16000)   ; every turn of this agent
(praxeon/actor:run-turn agent "Summarise the report." :max-tokens 32000)  ; this turn only
```

A step that reaches the limit before the model has finished is not used (#326). Its tool calls
are not run and its text is not returned as the answer. `run-turn` emits a `:truncated` event and
signals `praxeon/conditions:output-truncated`, which names the step and the limit. It is a
`deliberation-failure`, so with no handler the turn ends there with an error. A handler picks one
of three restarts:

- `retry-with-max-tokens` asks the model again with a larger limit, for the rest of the turn. The
  retry counts against `:max-steps`.
- `accept-truncated` ends the turn with the cut-off text. `run-turn` returns it with a second
  value, `:truncated`.
- `abandon-turn` ends the turn with no answer. `run-turn` returns NIL and `:abandoned`.

This handler retries once at 32,000 tokens and, if the step is cut off again, accepts the text
and says it is incomplete:

```lisp
(multiple-value-bind (text mark)
    (handler-bind ((praxeon/conditions:output-truncated
                     (lambda (c)
                       (if (< (praxeon/conditions:output-truncated-max-tokens c) 32000)
                           (praxeon/conditions:retry-with-max-tokens 32000 c)
                           (praxeon/conditions:accept-truncated c)))))
      (praxeon/actor:run-turn agent "Write the full plan on the whiteboard."))
  (if (eq mark :truncated)
      (format nil "~A~%~%(The answer was too long and was cut off.)" text)
      text))
```

### Embeddings

An embedding provider turns text into a vector (`praxeon/llm:embed`,
`praxeon/llm:embed-batch`). It is configured with its own variables and never reads the
chat ones: not `PRAXEON_<ROLE>_<VAR>`, and not `PRAXEON_LLM_<VAR>`.

**There is no default embedding provider.** `make-embedding-provider-from-env` returns a
provider only when `PRAXEON_<ROLE>_EMBED_IMPL` or `PRAXEON_EMBED_IMPL` names one.
Otherwise it signals `praxeon/conditions:no-embedding-provider` before any request is made,
and an app that can work without embeddings handles that condition and uses exact search.
Impls: `openai`, `ollama`, `openrouter`, `voyage`.

Retrieval code embeds stored text with `embed-documents` and a search with `embed-query`.
A service that treats the two differently (Voyage) is told which one it is getting; for the
others the two calls send the same request. Both split their texts into as many requests as
the service's limits require, and keep the results in input order.

For embedding backend `X`, each setting resolves most-specific-first:

1. `PRAXEON_<ROLE>_EMBED_<SETTING>`, when a role is being resolved;
2. `PRAXEON_EMBED_<SETTING>`;
3. `X`'s own variable: `PRAXEON_<X>_API_KEY` and `PRAXEON_<X>_BASE_URL` for the key and
   the endpoint; `PRAXEON_<X>_EMBED_MODEL` and `PRAXEON_<X>_EMBED_DIMENSIONS` for the model
   and the width, because `PRAXEON_<X>_MODEL` is the chat model of a backend that serves both;
4. `X`'s built-in default. There are defaults for the endpoint, the model and the width,
   never for a key.

| Setting | Role level | Process level | Backend's own | Default (`openai`) |
|---|---|---|---|---|
| backend | `PRAXEON_<ROLE>_EMBED_IMPL` | `PRAXEON_EMBED_IMPL` | — | none |
| key | `PRAXEON_<ROLE>_EMBED_API_KEY` | `PRAXEON_EMBED_API_KEY` | `PRAXEON_<X>_API_KEY` | none |
| endpoint | `PRAXEON_<ROLE>_EMBED_BASE_URL` | `PRAXEON_EMBED_BASE_URL` | `PRAXEON_<X>_BASE_URL` | `http://localhost:11434/v1` |
| model | `PRAXEON_<ROLE>_EMBED_MODEL` | `PRAXEON_EMBED_MODEL` | `PRAXEON_<X>_EMBED_MODEL` | `text-embedding-3-small` |
| width | `PRAXEON_<ROLE>_EMBED_DIMENSIONS` | `PRAXEON_EMBED_DIMENSIONS` | `PRAXEON_<X>_EMBED_DIMENSIONS` | `1536` |

`openrouter` defaults its endpoint to `https://openrouter.ai/api/v1` and, being hosted,
signals `missing-provider-key` when no key variable is set.

`voyage` (Voyage AI, #286) defaults to `https://api.voyageai.com/v1`, model `voyage-4` and
width `1024`, and requires a key, so an app sets only the impl and the key:

```sh
PRAXEON_EMBED_IMPL=voyage
PRAXEON_VOYAGE_API_KEY=pa-...
# PRAXEON_VOYAGE_EMBED_MODEL=voyage-4-large     # or voyage-4-lite
# PRAXEON_VOYAGE_EMBED_DIMENSIONS=512           # 256, 512 or 1024; 2048 cannot be indexed by pgvector
```

Every Voyage request sends `truncation: false`, so a text longer than the model accepts is an
error rather than a vector for its beginning.

```lisp
(handler-case (praxeon/llm:make-embedding-provider-from-env)
  (praxeon/conditions:no-embedding-provider () nil))   ; NIL -> use exact search
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

**Wire all four counts** (pre-publication issue 417). A provider reports base input, output, tokens *read* from a
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

The **prompt-injection posture** of #90 that used to be listed here has landed: `agent-means-for`
assembles the tool table from the caller's authority, `grant-permit-fn` turns a signed grant into
the predicate it needs, and `act` re-checks at call time, so a means the caller may not use is
absent rather than filtered by prompt. See §11 for the shape. #90 remains open for its other
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

> **`run-turn` gained `:permit` in pre-publication issue 400.** Before that it took none and passed none, so a
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
and the ordering against #138's semantic-search seam are in
[`docs/adr/0002-data-access-through-means.md`](adr/0002-data-access-through-means.md).

## 12. Search an app's documents (`praxeon/retrieval`, #138)

`praxeon/retrieval` searches an app's documents, exactly or by similarity, and returns each
passage with where it came from. It needs Postgres with pgvector. Load `praxeon/retrieval`
and use the package of the same name.

**Once per database**, a role with CREATE privilege on the database (on a managed cluster, the
administrator) installs the extension: `CREATE EXTENSION vector;`. praxeon never runs that
itself. `ensure-schema` checks for it and signals `praxeon/conditions:vector-extension-missing`,
naming the database, when it is absent.

**At startup**, make a store and a corpus for each set of documents searched together:

```lisp
(defparameter *embedder*        ; NIL when none is configured: exact search still works
  (handler-case (praxeon/llm:make-embedding-provider-from-env)
    (praxeon/conditions:no-embedding-provider () nil)))

(defparameter *store*
  (praxeon/retrieval:make-chunk-store connection :dimensions 1024 :ensure t))

(defparameter *terms* (praxeon/retrieval:make-corpus *store* "terms"))
```

- One store is one table, `praxeon_chunks` by default, holding every corpus. A corpus is only a
  name, so making one runs no SQL, and an app can create corpora at runtime (one per community,
  one per persona) without a deploy.
- `:dimensions` is the embedding width of the model the app uses. `ensure-schema` compares it
  with the table, and signals `embedding-width-changed` when a new model has another width. The
  `recreate-embedding-column` restart empties the column at the new width, for every corpus in
  the table, and the next `embed-pending` fills it again.
- Statements on one connection run one at a time. An app that ingests while it serves searches
  gives each its own store, on its own connection, naming the same table.

**Hand in the app's sections**, built with `make-section`:

| key | meaning |
|---|---|
| `:id` | the section's stable id in the app |
| `:document-id`, `:document-version` | its document, and the app's version of it (or NIL) |
| `:locator` | where it sits, as a reader cites it: a clause number or a heading |
| `:locale`, `:locale-role` | its language, and `:source` for an original or `:derived` for a translation |
| `:derived-from` | for a translation, the id of the section it translates |
| `:source-fingerprint` | for a translation, `(section-fingerprint original-text)` of the original it was made from |
| `:text` | the section's text |

```lisp
(praxeon/retrieval:sync-corpus *terms* all-sections)           ; at boot
(praxeon/retrieval:sync-document *terms* "doc-7" doc-sections) ; when an operator saves doc-7
(praxeon/retrieval:embed-pending *terms* *embedder*)           ; when there is an embedder
```

A sync makes the corpus hold exactly the sections it was given, and removes the rest in its
scope. Unchanged sections are not touched, so running it at every boot is cheap. It needs no
embedder. `embed-pending` embeds whatever has no embedding from the current model, which
includes everything after a model change. Syncs and `embed-pending` on one corpus run one at a
time, across processes as well (a Postgres advisory lock).

**Search:**

```lisp
(praxeon/retrieval:retrieve-exact *terms* "refund")                 ; no embedder involved
(praxeon/retrieval:retrieve-similar *terms* *embedder* "when is my refund" :limit 5)
```

Both return a `retrieval-result`: the passages, and whether the result is `complete` or
`truncated`. Exact search is truncated when more than `:limit` chunks matched. Similarity
search compares the query with every chunk of the corpus embedded by the same model, and it is
truncated only when some chunks have no such embedding yet (`truncated-pending` says how many).
Each passage carries its `provenance`: corpus, document and version, section, locator, locale,
and for a translation whether it was made from the current original (`:current`,
`:older-original` or `:unknown`). A search never returns another corpus's chunks.

**Keyword and hybrid search (#316):**

```lisp
(praxeon/retrieval:retrieve-keyword *terms* "error TS-999" :locale "en")         ; BM25, no embedder
(praxeon/retrieval:retrieve-hybrid *terms* *embedder* "error TS-999 on renewal" :locale "en")
```

`retrieve-keyword` ranks chunks by BM25, computed by praxeon in one SQL statement, so it works
on any Postgres without an extension. A sync writes each chunk's terms with the chunk. The
tokenizer lowercases, keeps an identifier such as `TS-999` or `PRAXEON_EMBED_MODEL` whole as
well as in parts, and drops the stop words of the chunk's locale (English only so far;
`register-stop-words` adds a language). `:locale` chooses the stop words dropped from the query.
Chunks synced before this existed, or indexed by an older tokenizer, make the result `truncated`
with reason `:not-indexed` until `index-pending` writes their terms; `ingest` calls it.

`retrieve-hybrid` takes up to 150 candidates from each search (`*hybrid-candidates*`) and merges
the two rankings by reciprocal rank fusion, which uses only ranks. A chunk found by both appears
once. Each passage's `passage-score` is its fused score, higher being better; `passage-distance`
is NIL. The result is `truncated` while any chunk lacks an embedding or its terms.

To choose between them on the app's own documents, `evaluate-retrieval` takes a list of
`make-eval-question`s, each a query and the section that answers it, and reports for each
strategy (`:similar`, `:keyword`, `:hybrid`) how often that section is in the top `:k`:

```lisp
(praxeon/retrieval:evaluate-retrieval *terms* *embedder*
  (list (praxeon/retrieval:make-eval-question :query "error TS-999" :document-id "doc-7"
                                              :section-id "4.2"))
  :k 20 :locale "en")
;; => ((:strategy :similar :k 20 :questions 1 :hits 0 :recall 0 :incomplete 0) ...)
```

`passage->ctx-item` turns a passage into a context item, and takes a function that writes the
text the model reads, so the app decides how a citation looks.

**Whole or searched, by the corpus's size (#316).** `retrieve` is the call to make when the app
does not care how a corpus is searched. It follows the corpus's `:strategy`:

- `:whole` returns every chunk in document order (`retrieve-whole`), for the app to put in the
  prompt before a cache marker. The query and `:limit` are not used.
- `:hybrid` returns `retrieve-hybrid` with `:limit` (default 20) and `:locale`, or
  `retrieve-keyword` when the embedder is NIL.
- `:auto`, the default, is `:whole` while the corpus is smaller than `:whole-limit` estimated
  tokens (200,000 by default, `*whole-limit*`) and `:hybrid` from then on.

Anthropic's article on contextual retrieval advises putting a knowledge base smaller than about
200,000 tokens in the prompt rather than searching it. The right limit for an app depends on its
chat model's context window and on what each query may cost, since a cached prompt is still paid
for at the cache-read price on every call, so `make-corpus` takes `:whole-limit`.

Each sync measures the corpus (`corpus-size`: its characters divided by four) and reports the
size and the strategy in `sync-report-size` and `sync-report-strategy`.
`corpus-effective-strategy` says which one `retrieve` follows now. When an `:auto` corpus
changes strategy, the sync logs it once through `aion/log`, with the corpus name and its size.

**A context for each chunk (#316).** A chunk often cannot be understood on its own: "it is sent
on the first business day" does not say what is sent. When a `:hybrid` corpus has a
contextualizer, a chat model writes one or two sentences placing each chunk in its document, and
those sentences are put before the chunk's text when it is embedded and when its BM25 terms are
written. The passage a reader or the model sees is still the chunk's own text; the context is in
`passage-context`.

```lisp
(defparameter *docs*
  (praxeon/retrieval:make-corpus
   *store* "docs"
   :contextualizer (praxeon/retrieval:make-contextualizer
                    (praxeon/llm:make-provider-from-env :role :contextualize))))

(praxeon/retrieval:sync-document *docs* "doc-7" doc-sections)
(praxeon/retrieval:contextualize-pending *docs* :ledger ledger) ; does nothing while :whole
(praxeon/retrieval:embed-pending *docs* *embedder*)             ; embeds context and text
(praxeon/retrieval:retrieve *docs* *embedder* "error TS-999 on renewal" :locale "en")
```

- Each context is one chat call. The whole document comes first in the prompt and carries the
  cache marker, so on a provider with a prompt cache a document is read in full once and from
  the cache for its other chunks. `contextualize-pending` works through one document at a time
  for that reason.
- A context depends on the whole document. A sync that changes, adds, removes or reorders any
  section of a document makes every context of that document stale, so documents that change
  often cost more. Changing the contextualizer's provider, model, `:instruction` or `:max-tokens`
  makes every context stale. A new context makes the chunk's embedding stale, and
  `embed-pending` embeds it again; `ingest` writes contexts before embedding.
- `:ledger`, a `praxeon/ceiling` ledger, bounds the calls: each is charged to it, with its
  cache-read and cache-write counts, and a call it cannot afford signals
  `praxeon/ceiling:budget-exhausted` before it is made. The contexts written before that are
  kept, and the next run carries on.
- `contextualize-pending` returns the number written and, as a second value, `:done`,
  `:no-contextualizer`, `:whole` or `:backfill-not-started`.

**When an `:auto` corpus grows past its limit**, the next `contextualize-pending` has every chunk
to do, and every chunk is embedded again. That backfill is the one large cost of this design. An
app can avoid it by saying at the start that the corpus will be large, with `:strategy :hybrid`
or `:expected-tokens`, so chunks get their context from the first sync. An app can also make the
corpus with `:backfill :explicit`, so that the backfill waits until the app calls
`(start-backfill corpus)`; that is recorded in the database, so it holds for every process.

Whether contexts are worth their cost on an app's documents is a measurement, not a default.
Build one corpus with a contextualizer and one without, sync the same sections into both, and
compare `evaluate-retrieval` on each. praxeon writes no contexts unless the app gives a corpus a
contextualizer.

**Let an agent search.** `register-corpus-search` gives an agent a means that searches one
corpus:

```lisp
(praxeon/retrieval:register-corpus-search
 agent *terms* *embedder*
 (lambda (passage)                    ; the text the model reads for one passage
   (format nil "[~A] ~A"
           (praxeon/retrieval:provenance-locator (praxeon/retrieval:passage-provenance passage))
           (praxeon/retrieval:passage-text passage)))
 :name "search-terms"
 :description "Search the terms and conditions. Returns clauses with their numbers."
 :on-result (lambda (query result) (remember-what-was-shown query result)))
```

- The model passes a `query`, and a `match` of `"meaning"` (the default, through `retrieve`) or
  `"words"` (through `retrieve-exact`, every word required). With a NIL embedder only a search by
  words is offered, and the schema has no `match`.
- The model reads the passages in the order the search returned them, each as the function
  writes it, and one sentence when the result is truncated: more matches than `:limit`, or parts
  of the corpus a search by meaning could not consider yet. It never sees a passage's distance. For a corpus
  whose strategy is `:whole`, a search by meaning returns the whole corpus; an app with such a
  corpus usually puts it in the prompt instead of offering a search.
- `:on-result` is called with the query and the `retrieval-result` before the model sees
  anything, so the app can keep the provenance it cites from. `:limit` and `:capability` are
  optional; a failed search reaches the caller as `means-failure`, as any means does.

Similarity is an exact scan of one corpus in this first build, with no vector index. Measured on
Postgres 18.6 with pgvector 0.8.6 at 1024 dimensions: about 8 ms for a corpus of 2,400 sections
and 32 ms for 10,000 (`praxeon/bench/retrieval-scan.lisp` repeats the measurement).

## 13. Keep large tool results out of the prompt (#319)

A tool result stays in the conversation, and so in the prompt, for every later step. In an agent
that fetches pages or runs queries, results soon make up most of what each step sends.
`offload-tool-results` keeps every result in a result store and lets the agent read back the
part it needs:

```lisp
(praxeon/actor:offload-tool-results
 agent (praxeon/results:make-memory-result-store)
 :conversation "conv-42"        ; results are kept and erased under this id
 :threshold 2000                ; estimated tokens; a larger result goes in as a stand-in
 :clear-budget 60000            ; optional: clear older results once the prompt passes this
 :keep-recent 3                 ; the last three results are never cleared
 :never-clear '("get-order"))   ; nor is any result of these means
```

- A result over `:threshold` goes into the conversation as a **stand-in**: the tool's name, its
  arguments, the result's size, its first lines and a handle such as `res-0a1b2c3d4e5f6a7b`.
- The agent gets a means, `read-result`, which takes the handle and returns a range of lines, a
  range of characters, or the lines that contain a string. What it returns is the stored text
  exactly, never a summary, so anything the agent quotes is what the tool said. A range larger
  than `*read-result-max-characters*` (16,000) is refused with its size, not cut.
- With `:clear-budget`, once the messages a step sends pass the budget, older results are
  replaced by short stand-ins **in what is sent**, oldest first, until the messages are at most
  `:clear-target` (half the budget by default). `agent-history`, the record, still holds them,
  and a cleared result can still be read by its handle. The cleared results stay cleared, so the
  start of the prompt stays the same from one step to the next and a provider's prefix cache
  keeps working; it changes only when a new batch is cleared.
- `(praxeon/actor:forget-agent-results agent)` erases the conversation's stored results. A
  fetched page or a record can hold personal data (#150).
- `praxeon/results-db` keeps results in a database through mnemosyne, for an app that keeps its
  conversations: `(praxeon/results-db:make-db-result-store connection-or-pool :ensure t)`.

**Nothing here is on by default**, and the numbers above are only an example. The maintainer's
rule is that a setting becomes a default only when a measurement with a real model shows the
task still succeeds with it. `praxeon/bench/tool-results.lisp` runs a tool-heavy task under each
configuration and reports task success, input tokens and the share a prefix cache could reuse;
pass `:provider` to run it with a real model. With its scripted model, which knows the task,
the figures on WSL2 Linux were:

```
20 tasks of 6 pages, seed 316, scripted model; tokens are estimates and the cache is simulated
configuration    succeeded  input tokens   cached share
full              20 of  20         613060        71.5%
offload           20 of  20          85479        77.4%
clear             20 of  20         256960        30.0%
```

The scripted model's success says that the tools make the answer reachable, not that a model
finds it. The clearing row shows a setting to avoid: when each result is about half the budget,
a batch runs after almost every result, and each batch changes the start of the prompt, so the
cached share falls.

## 14. Run the tests

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
