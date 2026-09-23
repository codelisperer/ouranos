# Praxeon — Vision & Priorities

*A working alignment doc. Claude asks pointed questions; you answer **fully and
candidly** — what you actually want, not what sounds reasonable. Your answers
re-order `docs/roadmap.md`. We'll fill this in conversationally; answers can go
inline here or in chat (Claude will transcribe).*

**Status:** interview in progress (started 2026-07-12).

> Context Claude is carrying in: we've built the provider-neutral core + tool-use
> loop, `praxeon/web` (HTMX chat + REST), a Figwheel-style hot-reload dev loop, a
> Tavily web-search Means, and confirmed MCP is reachable. Open threads in the
> roadmap: MCP, Hyperion (typesafe HTMX), Markdown chat, session model,
> Kairos/observational memory, growing the Coalton core, live-reload layer 3
> (conditions over the wire), a graphical studio, LLM-consumability.

---

## 1. What is Praxeon *for*? — the question the rest depends on

Which is **primary** (it can be several, but rank them): (a) an **OSS framework**
others build agentic systems on; (b) your **personal research/craft** vehicle;
(c) the **substrate for a specific product** (Elise? something at Apex Data
Solutions?); (d) a **portfolio/paper** artifact. This one answer changes
everything downstream — API stability, who the docs serve, polish vs. exploration.

> **A:**

## 2. Who writes code *against* Praxeon — humans, LLMs, or both?

You flagged "LLM-consumability" early. Is the intended author of Praxeon-based
apps primarily an LLM (Claude/Copilot generating code from the core), a human CL
dev, or both equally? Drives API shape, naming, and how much we invest in the
machine-readable docs thread.

> **A:**

## 3. Elise — throwaway PoC, or a product you intend to ship?

Is Elise a scaffold to exercise the framework (disposable), or a real reflective-
companion app you'd put in front of users? If real, safety / persistence /
multi-user / the crisis-guardrail seriousness all move way up.

> **A:**

## 4. The endgame thesis: is "a custom LLM built with Praxeon" literal or a north star?

Very early you wanted the abstraction extensible to "any custom LLM someday built
from scratch using Praxeon." Is that a genuine goal you're steering toward, or the
aspirational framing that keeps the abstractions honest?

> **A:**

## 5. If Praxeon has ONE differentiator — its *soul* — what is it?

Candidates from our work: the **live studio / hot-reload DX**; the **condition-
system recovery** (restarts as first-class agent recovery); **bitemporal context +
observational memory** (Kairos); the **typed Coalton core**; the **MCP/tool
ecosystem**; **provider-neutrality**. Which is the thing that, if we nailed only
it, would make Praxeon matter?

> **A:**

## 6. How load-bearing is the Coalton typed core, *really*?

Today it type-checks but is inert (skeleton). Do you want it to become a real
typed engine — typed `Plan` execution, `Valued` instances, the ontology actually
driving the runtime — or is a minimal, elegant *statement* enough, with CL doing
the heavy lifting at the edges?

> **A:**

## 7. Is "as a service" (multi-user, hosted, persistent) a near-term goal?

This gates the session model, persistence, auth, and the XSS/sanitization work.
Or is single-user / local / REPL-driven the real home for the foreseeable future,
with "service" a someday-maybe?

> **A:**

## 8. Memory & context: how central is Kairos / observational memory?

You called it "the headline want." Is **context/token economy** the differentiator
you care most about — the scarce resource the whole praxeology framing is built
around — or one feature among many?

> **A:**

## 9. Rank the live threads — "most fun" vs. "most important" (they may differ)

Threads: MCP tool ecosystem · Hyperion (typesafe HTMX) · Markdown / richer chat ·
session model · Kairos / observational memory · grow the Coalton core ·
live-reload layer 3 (conditions-over-the-wire) · graphical studio ·
LLM-consumability of the code/docs. Give a **top 3 for excitement** and a **top 3
for strategic importance**.

> **A (fun):**
>
> **A (important):**

## 10. What does success look like at 3 / 6 / 12 months?

Concrete even if rough — a paper, an OSS release with real users, Elise shipped, a
talk, "I deeply understand X," a company adoption at Apex. Any **real deadlines**
(the paper? a talk? a work milestone)?

> **A:**

## 11. Non-negotiables beyond provider-neutrality

What else is load-bearing and would you reject even if convenient? (Lisp-only?
minimal deps? FP purity? the praxeology vocabulary as the public API? no external
services in the core?) Provider-neutrality is already sacred — what joins it?

> **A:**

## 12. What am I not asking?

The question I *should* have asked — your own framing of where this goes, or a
constraint/ambition none of the above surfaced.

> **A:**

---

## Synthesis (Claude fills after your answers)

*Once answered: a short restatement of the vision in your own terms, a re-ordered
top-of-roadmap, and any threads to explicitly de-prioritize or drop.*
