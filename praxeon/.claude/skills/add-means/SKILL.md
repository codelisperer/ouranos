---
name: add-means
description: How to add a new tool ("means") to a Praxeon agent and wire it into the deliberate/act loop. Use when the user wants to add a tool, register a means, expose a capability to an agent, or give Elise a new action.
---

# Adding a means (tool) to a Praxeon agent

In praxeological terms a tool is a **means** an actor applies toward an **end**.
A means has two parts: a *description* (what it is) and an *effect* (what it
does). The description may live in the Coalton ontology; the effect always lives
in the dynamic CL shell, because it performs IO.

## Steps

1. **(Optional) Describe it in the core.** In `src/praxeology.lisp` a `Means` is
   `(Means name description)`. Add one if you want the ontology to know about it.
   Keep it pure — no IO here.

2. **Register the effect.** The effect is a function of one string returning a
   string. Register it on an agent:

   ```lisp
   (praxeon/actor:register-means
     agent
     "web-search"                      ; name the LLM will refer to
     "search the web for a query"      ; human description
     (lambda (query)
       (my-search-backend query)))     ; the effect (may do IO)
   ```

3. **Let failures signal.** Do not catch-and-return error strings. Let the effect
   signal; `praxeon/actor:act` wraps it in a `means-failure` and establishes the
   `retry-action` / `substitute-result` / `abandon-action` restarts so a handler
   (or a human at the REPL) chooses recovery.

4. **Invoke it.** `(praxeon/actor:act agent "web-search" "some query")` runs the
   means under those restarts.

## Next: dispatch

Automatic tool selection — parsing a chosen means out of the LLM's reply in
`run-turn` and routing it through `act` — is the natural extension point. Keep
the selection logic legible; prefer a small, inspectable protocol over magic.
