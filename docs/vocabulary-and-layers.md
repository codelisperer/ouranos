# Vocabulary and layers: the sideways dependency

The **DAG rule** stops a framework depending *upward* — `aion → cons → mnemosyne → elenchon
→ hyperion → praxeon`, and never rightward. It is checked mechanically: ASDF errors on a
cycle, and `verify-tree.lisp` compiles every system in its own image so an undeclared
dependency fails rather than being satisfied by a sibling.

This note is about the failure the DAG rule does **not** catch, one layer down: a piece of
code depending **sideways**, into whatever implementation happens to be installed underneath
it. Nothing errors. Everything compiles. It is invisible until the implementation is
swapped — which is to say, invisible for exactly as long as the coupling is being written.

## The shape

**A name has a layer, and it is not always the layer of the file it is written in.**

A `condition`, a type, an error code, a status vocabulary — each of these *means* something
at a particular altitude. When the name lives at a different altitude from its meaning, the
two layers are welded together and neither can move.

It shows up in **both directions**, and this tree produced one of each within a single change
(pre-publication issue 202).

### Domain vocabulary living in a transport

hermes' HTTP client — a general-purpose thing, wrapping one outbound call — signalled
`delivery-failure`.

That is a **messaging** condition. A client has no business asserting that a *delivery*
failed; it knows only that a request did. The result was that a perfectly good, well-shaped
client could not be reused by anything that was not sending mail, and it was not: praxeon
reimplemented it as three raw `dex:post` calls with its own error decoding, and a consuming
app hand-rolled a fourth.

The fix is not to widen the condition. It is to give the transport a transport-level failure
(`http-error`, carrying status and body) and let the **messaging framework translate at its
own boundary**, where "delivery" is a word that means something.

### Domain behaviour hostage to a transport

The mirror image, found by the first application to adopt that client.

Its provider-error condition was defined in its **transport** file. Its *reconciliation*
logic — domain logic, about what a stale subscription record means — branched on that
condition to distinguish a 404 from a 500.

So the behaviour of the domain was hostage to a condition owned by whichever transport
happened to be installed. Swapping the transport broke it, and **only** swapping the
transport revealed it: two tests failed, and the cause was not in either of them.

## Why it stays invisible

**With one implementation, the coupling is free.** Nothing exercises the seam, so nothing
reports it. The cost is paid entirely in the future, by whoever tries to introduce the
second implementation — and they experience it not as "a name is in the wrong place" but as
an unrelated-looking test failure in code nobody touched.

That is also why it is written in the first place. Nobody decides to couple a domain to a
transport; they put a condition in the file they were editing.

## The test

Ask of any name:

> **Does this mean anything in the absence of the thing underneath it?**

- `delivery-failure` means nothing without a messaging framework. It is **domain**, and must
  not live in a transport.
- `http-error` means something to anything that makes an HTTP request. It is **transport**,
  and must not be defined per-consumer.
- A condition that a domain *branches on* is domain vocabulary **whatever file it is in** —
  and if it is defined by a transport, the domain has a sideways dependency it did not
  declare.

A blunter version, useful in review:

> **Could this layer be reimplemented against a different thing underneath, without editing
> the layer above it?** If not, some name is at the wrong altitude.

## What to do instead

**Translate at the boundary.** Each layer signals in its own vocabulary, and the layer above
converts. hermes does this in one macro:

```lisp
(as-delivery :sendgrid
  (send-request req (list (add-header …) (ensure-2xx :sendgrid))))
```

`http-error` goes in; `delivery-failure` comes out, carrying the provider, the status, and
the body the provider used to explain itself. The client stays reusable, `deliver`'s contract
is unchanged, and **a caller never has to know an HTTP client is underneath** — which is the
whole point of the layer.

Translation is a few lines, and it is the cheapest place in the system to pay for the
separation. Sharing the vocabulary is free right up until it is very expensive.

## Related rules

- The **DAG** (`AGENTS.md`) — the upward version of the same instinct, mechanically checked.
- **Package-per-module** — a name's home is a decision, not an accident of editing.
- **Pluggable backends behind neutral protocols** — this note is the failure mode that rule
  exists to prevent, described from the inside.
- **A system that exports a surface must have a suite that exercises it** (`AGENTS.md`) —
  related, and for the same underlying reason: both defects hide inside something green.

## Provenance

Both instances came from pre-publication issue 202, and neither was predicted. The outbound one was found while
moving the client out of hermes — it was the single thing that could not move verbatim. The
inbound one was reported by the consuming application that adopted the client, when deleting
its shim broke two tests it had not touched.

Seeing one of them is an anecdote. **Seeing both, in opposite directions, inside one change,
is what made it a rule** — and the symmetry came from the application's report rather than
from the framework side, which is worth recording on its own.
