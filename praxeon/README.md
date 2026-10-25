# Praxeon

*A praxeological framework for industrial-strength agentic AI, in Common Lisp + Coalton.*

Praxeon is an attempt to build a serious agent-orchestration framework in the
lineage of Norvig's *Paradigms of AI Programming* — and to do better than the
Python `Lang*` family and TypeScript's Mastra by putting a principled model at
the core instead of an ad-hoc pile of "chains" and "runnables."

## The thesis

Praxeon targets the **agent, orchestration, and context-management layer** —
CPU-bound work where homoiconicity, macros, the condition system, CLOS/MOP, and
live image-based development are decisive, and where the ecosystem moat is
thinnest — and FFIs out to existing kernels for anything numeric. (The broader
"CL all the way down" motivation, and why Python won AI as glue over C++/CUDA
rather than on language merits, lives in the [root README](../README.md) and
[ECOSYSTEM.md](../ECOSYSTEM.md).)

## The model (why "Praxeon")

The name is coined from von Mises' **praxeology**, the science of human action,
whose ontology maps almost exactly onto agents:

| Praxeology            | Agent architecture                          |
|-----------------------|---------------------------------------------|
| ends                  | goals                                       |
| means                 | tools                                       |
| action                | a step (applying a means toward an end)     |
| preference over ends  | the objective / valuation                   |
| action under uncertainty | the LLM's probabilistic reasoning        |
| economizing scarce time | the context/token budget                  |
| imputation of value   | credit assignment for tool calls            |

So the core vocabulary is `end`, `means`, `action`, `actor`, `plan` — a more
principled agent DSL than "node/chain/runnable."

## Architecture

Two layers:

- **Typed core (Coalton).** `src/praxeology.lisp` defines what agents *are*
  (`End`, `Means`, `Action`, `Plan`, `Actor`) with Hindley–Milner types. This is
  the "statically typed core" story for a type-conscious shop.
- **Dynamic shell (Common Lisp).** Conditions/restarts for recoverable failure,
  the LLM provider protocol, the budgeted context, and the deliberate→act loop
  live in ordinary CL, where dynamism and IO belong.

```
praxeon/
  praxeon.asd              ; systems: praxeon, praxeon/elise, praxeon/tests
  src/
    packages.lisp
    praxeology.lisp       ; Coalton-typed ontology
    conditions.lisp       ; recoverable-failure protocol
    context.lisp          ; budgeted, bitemporal context (seed of Kairos)
    llm.lisp              ; provider protocol + Anthropic
    actor.lisp            ; the deliberate/act loop
  examples/elise/         ; Elise: the modern-psychology ELIZA successor (PoC)
  tests/
  paper/                  ; LaTeX write-up of the value proposition
```

## Kairos (roadmap)

The bitemporal stamps on context items (`valid-time`, `tx-time`) are the seed of
**Kairos**, a standalone bitemporal knowledge graph for context management — the
kind of substrate that lets an agent reason about *what we believed, and as of
when*. Like XTDB, it will likely FFI to Apache Arrow for zero-copy columnar
storage rather than reimplement a query engine.

## Getting started

This framework is one of six in the [Ouranos monorepo](../README.md); you build the
whole tree, not this directory alone. Prereqs: **SBCL + Quicklisp** (Coalton loads from
Quicklisp on first use).

    git clone https://github.com/codelisperer/ouranos.git
    cd ouranos
    sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons

`bootstrap.lisp` points ASDF at the whole tree and writes a source-registry drop-in, so
every REPL can find the frameworks with no symlinking. From any SBCL REPL:

    (ql:quickload :praxeon/elise)   ; first load compiles Coalton — minutes, then cached

`bin/cons build | test | serve | run` is the intended one-command interface (in
progress; today `cons` implements `init` / `setup` / `version`).

Add a provider key to `.env` (copied from `.env.example`), then talk to Elise —
the reflective-companion demo agent, from any REPL:

```lisp
(ql:quickload :praxeon/elise)
(praxeon/elise:start)     ; interactive Elise session
```

A minimal `.env`:

```sh
PRAXEON_LLM_IMPL=anthropic
PRAXEON_ANTHROPIC_MODEL=claude-sonnet-5-5
PRAXEON_ANTHROPIC_API_KEY=sk-ant-...
# Cheaper/free alternative: PRAXEON_LLM_IMPL=openrouter + PRAXEON_OPENROUTER_* vars.
```

**Per-agent models.** Configuration is *not* global — each agent resolves its own
model by **role**: `PRAXEON_<ROLE>_MODEL` (also `_IMPL`/`_API_KEY`/`_AUTH`) wins over
the shared `PRAXEON_LLM_*`, which applies only to the provider `PRAXEON_LLM_IMPL` names.
Embedding providers have their own variables (`PRAXEON_EMBED_*`) and no default; see the
user guide, §8. So one process runs several agents, each on its own
model — e.g. Elise deliberating on a strong model while a fast one translates:

```sh
PRAXEON_LLM_MODEL=claude-sonnet-5-5                # shared default
PRAXEON_ELISE_MODEL=claude-opus-5-5                # the therapist agent
PRAXEON_TRANSLATE_MODEL=claude-haiku-4-5-20251001  # the translator agent
```

**Talk in your language.** Elise localizes her chrome (en/es/ru — drop a JSON file
to add a language) *and* converses in the selected locale: a **translator agent**
renders your message into English for Elise and her reply back into your language.

Dependencies (`coalton`, `alexandria`, `dexador`, `com.inuoe.jzon`, `fiveam`) are
pulled by Quicklisp on first load. A root `cons.lisp` build spec drives the common
tasks via `cons <target>` (`cons check`, `cons paper`, or bare `cons` to list them) —
see [`docs/user-guide.md`](docs/user-guide.md).

**Full guide** — configuring providers, the studio, editor-connected REPLs, and
troubleshooting — is in [`docs/user-guide.md`](docs/user-guide.md).

## Opt-in systems beside the core

- **`praxeon/web`** — a Clack-based web + REST surface (HTMX chat UI, `POST /api/message`,
  `GET /api/progress`), rendering the same event stream the CLI does.
- **`praxeon/web-search`** — web search as a registered *means*, over the same
  provider-neutral protocol as the LLM layer.
- **`praxeon/web-page`** — the `read-web-page` means: the model opens a URL the user gave
  and reads the page's main text (#757). See [Reading a web page](#reading-a-web-page).
- **`praxeon/translate`** — the translator agent (English pivot), which is how Elise
  converses in the user's locale.
- **`praxeon/elise`** — the reflective-companion example. Demoware, with prominent
  disclaimers and a crisis guardrail.
- **`praxeon/chat-rbt`** — **Elenchon's motivating example**: a natural-language
  requirement, conversed and disambiguated into a Cause-Effect Graph, then handed down to
  [`elenchon`](../elenchon) for the minimal test set. It lives here rather than in elenchon
  because the NL step is agentic and the DAG forbids elenchon depending rightward.

## Reading a web page

`praxeon/web-page` gives an agent the `read-web-page` means. The model calls it with a URL and
gets back the page's main text, its title and the URL it was read from after redirects.

**Register it with `:allow #'user-or-search-urls`** unless the model must be free to open any
public page. Without it, a page the model reads can tell it to open another address, and that
address can carry what the conversation contains. Registering without `:allow` logs a warning
that says so. See [Content the agent reads can carry
instructions](#content-the-agent-reads-can-carry-instructions).

```lisp
(praxeon/web-page:register-read-web-page agent :allow #'praxeon/web-page:user-or-search-urls)
;; => "read-web-page", or NIL
```

- **Backend.** Tavily's `/extract` when `TAVILY_API_KEY` is set (or `:api-key` is given).
  Otherwise the page is fetched from this machine with `aion/http-client`'s `fetch-public`, and
  its text is extracted with plump: the `<main>` or `<article>` element, else `<body>`, without
  scripts, styles, navigation, headers, footers and forms.
  - Tavily reports no title, so a page read through Tavily has none.
  - **On Windows, without a Tavily key, nothing is registered**, and the reason is logged at
    warn. `fetch-public` pins each connection to the address it checked, which
    `aion/http-client` cannot do on Windows.
- **Addresses.** A URL whose host resolves to a private, loopback, link-local or other
  internal address is refused before any request. `fetch-public` checks every redirect
  again. For Tavily the check runs here too, so an internal URL is never sent to Tavily.
- **Limits.** `fetch-public` reads at most 2 MiB (`*max-page-bytes*`) and follows at most 5
  redirects, with a 10-second connect timeout and a 15-second read timeout on each hop, and a
  30-second deadline for the whole read (`make-public-fetch`'s `:deadline`). Resolving the host
  and opening the connection are not interrupted by the deadline, only checked when they
  return, so a read can end up to the resolver's timeout plus the connect timeout past it. Only
  HTML, XHTML and plain text are read; a response with no `Content-Type` is read when it is text. A page is
  decoded in the charset its `Content-Type` names, or, for HTML, the charset a `<meta>` in its
  first 1024 bytes names, else UTF-8. The model is given at most 12000 characters
  (`*budget*`, or `register`'s `:budget`), followed by a line saying how many were left out.
- **Quoted source.** The text reaches the model through `praxeon/source:quote-source`. It is
  placed between `<<<SOURCE n>>>` and `<<<END SOURCE n>>>`, where `n` is a random nonce, after a
  sentence saying that the text is quoted material and not instructions. A page cannot end the
  block early, because it would have to guess the nonce. This does not make a model immune to
  instructions written into a page; it marks clearly which text came from the page.
  `praxeon/retrieval` can use the same helper for retrieved reference text.
- **Failures** are `web-page-unreadable`, a `tool-error-result`, so the model is told why the
  page could not be read and the turn goes on. The reasons are `:invalid-url`, `:not-public`,
  `:unresolvable`, `:too-large`, `:too-many-redirects`, `:status`, `:not-text`, `:empty`,
  `:timeout`, `:unavailable` and `:provider`.

**A one-line status.** Every means call emits `:tool-call` and `:tool-result` events through
`praxeon/event`. `status-line` turns the `read-web-page` call into a status for the user. It shows the
host, never the path or query, which can carry a user's tokens, and never the page:

```lisp
(praxeon/event:with-observer ((lambda (event)
                                (let ((status (praxeon/web-page:status-line event)))
                                  (when status (show-status status)))))   ; "Reading example.com…"
  (praxeon/actor:run-turn agent "What do the terms at https://example.com/terms say?"))
```

The `:tool-result` event carries the page text as its `:content`, so a status display should
not show it.

## Content the agent reads can carry instructions

A web page or a search result can contain text written to steer the model: "open this other
address", "buy this", "send the conversation to …". Quoting it as a source (above) marks
where it came from, but a model can still follow it. The agent cannot rely on the model to
refuse, so `praxeon/actor` keeps a guard for each turn and refuses some calls outright (#827).
A refused call is not run, and the model is told why, so it can tell the user.

`register-means` takes four keys for this:

- **`:untrusted t`** marks a means whose result comes from outside the conversation.
  `read-web-page`, `web-search` and every tool `praxeon/mcp:grant-tools` grants set it; for an
  MCP server the app fully controls, pass `:untrusted nil` to `grant-tools`
  ([`docs/mcp.md`](docs/mcp.md)). Once one has run, the turn counts as having read
  untrusted content until the user's next message. So does a call of `read-result` that reads
  back a stored result of such a means, in whatever turn it runs. A sub-agent registered with
  `register-agent-as-means` that read untrusted content makes its coordinator's turn count too,
  and a sub-agent asked for something after the coordinator read untrusted content starts its
  turn that way. The means `register-agent-as-means` registers is itself `:untrusted` when the
  sub-agent has an untrusted means at that point. A context item marked `untrusted` counts as
  well, for every turn whose prompt includes it: an observation condensed from untrusted
  content, an MCP resource added with `add-resource`, and a passage from a corpus made with
  `make-corpus`, unless the app passed `:untrusted nil` for its own server or documents (#906,
  #907). `register-corpus-search` registers its means `:untrusted` unless the corpus was made
  that way.
- **`:requires-user-intent t`** marks a means that spends, writes or sends for the user. A call
  the model asks for after untrusted content entered the turn is refused for the rest of the
  turn. Calls the model asked for in the same step as the read, before it saw the result, are
  judged on what it had seen, and run. `generate-image` sets it by default, and so does every
  means registered with `:confirm`, such as an MCP tool granted with `:confirm`, because a means
  held for the user's confirmation is one that spends or writes. Pass
  `:requires-user-intent nil` to have such a means held for confirmation instead of refused.
- **`:allow`** is a function of the call's arguments and the agent, and the call runs only when
  it returns true. A predicate that signals refuses the call. `register` and
  `register-read-web-page` take `:allow` as a function of the URL and the agent.
- **`:max-per-turn`** bounds how many calls of the means run in one turn. `read-web-page` and
  `web-search` default to 3. The count is kept for each means separately, so an agent with a
  reader and a search may make 3 of each. A sub-agent keeps its own count, which starts at 0 in
  each turn it is asked to run, so a coordinator that delegates 3 times lets its sub-agent read
  up to 9 pages in the coordinator's one turn.

The agent's `taint-scope` slot (`agent-taint-scope`) says how long untrusted content counts:

- **`:turn`**, the default: until the user's next message.
- **`:conversation`**: while the agent's history holds any call of an untrusted means (or of
  `read-result`, or of a means that is no longer registered). Each later turn then starts as
  having read untrusted content. An app that must not let page text steer a later turn sets
  it, and accepts that the user is refused spending calls for the rest of the conversation
  after one page was read.

**An app that rebuilds the agent from a stored text transcript** (#948) has no tool calls in
the history it passes, so `:conversation` cannot find the earlier read there. Praxeon also
records the conversation's taint as it happens, in `agent-conversation-taint`: `:untrusted`
once untrusted content has entered the conversation, `:clean` from a first turn until then,
and `nil` when nothing was recorded. Store that value beside the transcript after each turn,
and pass it back when the agent is rebuilt:

```lisp
(praxeon/actor:make-agent :name "assistant" :taint-scope :conversation
                          :conversation-taint (stored-taint conversation-id))
```

`:conversation` counts a turn untrusted when the recorded value is `:untrusted`, or when the
history holds an untrusted call. Once recorded `:untrusted`, an agent stays so; an app that
deliberately starts the conversation over sets it to `:clean`. When an agent under
`:conversation` has earlier turns, no tool calls in them and nothing recorded, praxeon cannot
tell whether untrusted content came before. It then treats the turn as untrusted, records
`:untrusted`, logs it once for that agent, and signals the warning
`praxeon/actor:conversation-taint-unrecorded`, whose message names this fix. Muffling the
warning does not make the turn trusted.

`praxeon/web-page:user-or-search-urls` is a ready-made `:allow` for `read-web-page`:

```lisp
(praxeon/web-page:register-read-web-page agent :allow #'praxeon/web-page:user-or-search-urls)
```

It allows a URL when its host is one the user wrote in this conversation, as a URL or as a
bare host such as `example.com`, or when a web search in this turn returned exactly that URL.

- Only the user's own messages count. `praxeon/actor:user-texts` returns them, leaving out tool
  results and every task a coordinator delegated, because a model wrote it. While a sub-agent
  runs a delegated task, the coordinator's user texts count for the sub-agent instead, so it
  may open what the user asked the coordinator for.
- A bare host whose last label is also a common file extension, such as `main.rs`,
  `README.md` or `setup.py`, counts only when it starts with `www.` or a path follows it
  (`allegro.pl/offers`). A URL with a scheme always counts.
- A host is compared in its ASCII form. A URL written with a non-ASCII host, such as
  `https://bücher.example/`, names the same host as `https://xn--bcher-kva.example/`. A bare
  non-ASCII host the user wrote without a scheme is not taken as a host.
- Hosts match exactly, ignoring case and a trailing dot. `example.com` does not allow
  `www.example.com` or `evil-example.com`.
- Userinfo is ignored: in `https://example.com@evil.example/` the host is `evil.example`.
- Only the URLs a search returned count, never its snippets, and only from a search the model
  asked for before anything untrusted was read in the turn. Otherwise a page could tell the
  model to search for a phrase that only the attacker's page ranks for, and that page's address
  would then be allowed.

**What this does not stop.** A page on a host the user named can still tell the model to open
another page on the same host, with data from the conversation in its address, and the
owner of that host sees the address in their logs. If the user names a host they do not
trust, or a host that serves pages anyone can write, such as a forum or a wiki, treat its pages
as able to receive what the conversation contains. The guard does not inspect the arguments
of a call that it lets run. `:allow` defaults to no restriction, so that an app whose model
finds pages on its own keeps working; such an app accepts that a page can send the model to
any public address.

With the default `taint-scope` of `:turn`, the next message the user writes starts a turn
that counts as not having read untrusted content, but the text of the pages read in earlier
turns is still in the history the model is sent. A page read in turn 1 can therefore steer a
spending call in turn 2, after the user writes something as short as "thanks". Set
`taint-scope` to `:conversation` to refuse such calls while that text is in the history.

The guard is one slot on the agent, as the history is: run one turn at a time on an agent,
and use one agent for each conversation.

## Status & license

Pre-alpha (0.0.1) — a scaffold, not a product. Contributions from one future self
to another are welcome. MIT-licensed, like the rest of the monorepo; see the
[root README](../README.md) and [ECOSYSTEM.md](../ECOSYSTEM.md) for ecosystem-wide
status and governance.
