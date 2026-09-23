# CLAUDE.md — hermes

Tree-wide rules are in the root `CLAUDE.md`/`AGENTS.md`, loaded with this file. Only
hermes-specific notes here.

## What this is

External integrations behind thin neutral protocols. A satellite leaf library: depends only
on `aion` and external libs (dexador, jzon, base64, ironclad); never on hyperion, mnemosyne
or praxeon, and nothing in the DAG depends on it.

## Design facts

- **All app messaging is one `deliver`/`send` protocol.** Shipped: email (SendGrid) and SMS
  (Twilio) plus a dev transport; inbound via a signature-verified Twilio webhook. New
  channels (push, in-app, voice) are **new backends, not new APIs**.
- **Payments** is a separate module under the same doctrine — shipped, not planned.
  ADR-0001 (neutral protocol, own system) and ADR-0002 (Stripe hosted Checkout only; the
  PCI posture that follows) are accepted. There is no card-number operation, by design.
- **Ads** (#262) is the next channel: a consuming app builds it and it is promoted. Build
  against the neutral vocabulary in that ticket, not against Meta's nouns.
- `hermes/blob` follows mnemosyne's rule: no `cl+ssl` dependency of its own.

## Gotchas

- Secrets in `.env` (gitignored), keys documented in `.env.example`, loaded with
  `cons/env:load-dotenv`.
- Money is minor units, never a float — reuse the payments representation.
- Coalton arrives transitively via `aion/log`; hermes' own typed boundary (provider status
  strings, webhook event kinds, amounts) is planned, per `../aion/docs/coalton-story.md`.
