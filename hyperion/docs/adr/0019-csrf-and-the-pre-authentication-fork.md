# ADR-0019 — CSRF: one mechanism, central on both sides, and a session before sign-in

**Status:** Proposed — 2026-09-14. Answers the design fork in
pre-publication issue 280, which the maintainer ruled a
**launch blocker** — *"a sine qua non for going live with anything."* Implements the CSRF
half of the `secure-app` wrapper in
[`hyperion/docs/middleware-security.md`](../middleware-security.md), which records its own
status as *"Captured; **not built** except the escape-by-default output posture"*; the
headers half is [#119](https://github.com/codelisperer/ouranos/issues/119) and lands
independently.

## Context

The post-authentication case is settled practice: a token in the session, compared against
one the request carries. The decision is the **pre-authentication** case. Sign-in, sign-up
and password-reset POST *before the visitor has authenticated*, so there is no
post-authentication session to hold a token — and leaving those three unprotected is not an
option, because login CSRF is real: an attacker who can forge a sign-in POST logs the victim
into the *attacker's* account, and everything the victim then does happens in it.

Two shapes were on the table: mint a session for anonymous visitors so the ordinary
mechanism applies, or issue a stateless signed double-submit cookie for the pre-auth forms
only.

**The reported objection to the first does not survive reading the code.** A pre-session was
said to collide with [`hyperion/consent`](../../src/consent.lisp). It does not.
`*necessary-categories*` names exactly this case:

> Categories exempt from consent — strictly necessary for the service to function
> (**session, security**, load-balancing, locale choice). Always granted; cannot be rejected.

and `consent-allows-p` (`consent.lisp:53`) returns true for a necessary category
unconditionally — *"under `:UNDECIDED`/NIL only necessary is allowed."* A session cookie
carrying a CSRF token is a security cookie, is `:necessary`, and needs no consent under
GDPR/ePrivacy or under this framework's own taxonomy. There is no collision to design around.

Note for whoever implements this: the *value* of `*necessary-categories*` is `'(:necessary)`.
It is the **docstring** that enumerates session and security, so grepping the source for
`:security` finds nothing.

One correction while we are here: `session-db.lisp` does **not** reserve a csrf slot. Its
header lists "user id, roles, csrf token, flash" as examples of ordinary session contents.
Nothing needs un-reserving, and nothing exists yet.

## Decision

1. **One mechanism, not two.** The CSRF token lives in the session, pre- and
   post-authentication alike. A visitor who reaches a protected form gets a session in the
   `:necessary` consent category; sign-in then rotates it (below) rather than creating one.
2. **Mint at response assembly, not per request and not at render.** *(Corrected
   2026-09-14 — see Provenance; the first draft said "at render" and that does not survive
   the streaming path.)* A session is created when the handler returns a response that needs
   a token. For a buffered response that is the same moment as render; for a **streamed**
   body it is the only moment that exists, because `server-uv` puts the head on the wire
   (`server-uv.lisp:487`) *before* the body closure runs (`:498`), so a cookie minted during
   render can never reach the client — and would fail silently, token in the session, browser
   holding no id. Today `wrap-session` (`session.lisp:309`) takes `ensure-session`'s default
   and mints on **every** request, so this is a reversal of current behaviour that strictly
   reduces the store's growth. `wrap-session` needs restructuring rather than a keyword: it
   reads `(session-id session)` at entry to detect rotation at exit, which `:create nil`
   breaks.
3. **Both halves central.** The check refuses **before routing**, against an app-supplied
   exemption list; the token is injected into every posting form **at the response
   boundary**. Neither half depends on a handler or a form author remembering. This is
   ADR-0011's `wrap-content-length`-inside-`start` argument applied again: the framework
   sells the property that *a form written next month is protected without its author
   knowing the mechanism exists*.
4. **Accept either carrier**: a `_csrf` form field or an `X-CSRF-Token` header, so HTMX and
   ordinary form posts share one path.
5. **Constant-time comparison**, and the token minted from `aion/random` — the same CSPRNG
   that mints session ids (pre-publication issue 95), not `random`. The token source is already carried
   (`new-id` is `rnd:random-hex`, `session.lisp:154`); **constant-time comparison is not** —
   nothing in `aion/src` or `hyperion/src` does it today. It must be built, not reached for.
6. **Rotate the token with the session id at every privilege change.** This ties to
   [#120](https://github.com/codelisperer/ouranos/issues/120): a `sign-in!` that rotates by
   construction means the privilege change and both rotations cannot be separated.

## Consequences

- **Pre-auth and post-auth are the same code path.** No second token format, no second
  verification path, and no class of bug that exists only on the login page — which is the
  page that matters most.
- **Anonymous visitors can hold a session.** Bounded by (2): only form-bearing responses
  mint one. The store still needs an expiry for never-authenticated sessions; without it the
  lazy mint is a slow storage leak rather than a fast one.
- **An app's exemption list becomes deletable.** The acceptance criterion for pre-publication issue 280 is
  exactly that: a consuming app currently exempts sign-in, sign-up, reset and its newsletter
  with the reason recorded in source and a test pinning the exemption. When this lands, that
  list is the thing that goes away.
- **Refusing before routing means the refusal cannot be bypassed by a handler**, and it is
  the only placement where an exemption list is auditable in one spot.
- **The composition mechanism is not what the design doc says.**
  `middleware-security.md` proposes composing `secure-app` "via `lack.builder`", and the
  tree composes middleware by plain function wrapping. **Clack has not been dropped** —
  [ADR-0015](0015-ring-calling-convention-without-clack.md) decision (3) says `clack` leaves
  `hyperion.asd` *in M4*, "after the native path has earned trust, not before," and it is
  still declared at `hyperion.asd:19`. So the line is wrong about the mechanism, not about
  the dependency. Compose it the way the tree composes middleware now.
- **No new dependency.** HMAC, if a future stateless variant is ever wanted, is already
  available through `ironclad`. Note that `aion/signature` is Ed25519 — asymmetric, for
  signed spend grants — and is the wrong primitive here.

## Alternatives considered

- **Signed double-submit cookie for the pre-auth forms.** Stateless and avoids minting a
  session, which was its appeal while the consent collision was believed to be real. Rejected
  now that it is not: it is a *second* mechanism, with its own signing key, its own
  verification path and its own failure modes, covering exactly the three forms where a
  mistake is worst. Double-submit is also the weaker construction — an attacker who can set
  a cookie on a sibling subdomain can forge both halves of the pair, and this stack has no
  standing guarantee about subdomains.
- **Exempt the pre-auth forms.** Rejected: that is the unprotected sign-in, and login CSRF
  is the specific attack it enables.
- **Per-form token injection.** Rejected on the field measurement reported against pre-publication issue 280 —
  60 edits in one consuming app, and opt-in protection thereafter. Opt-in protection is
  protection that a new form does not have.

## Testing this, specifically

Three traps found in the field, all of which produced green suites over broken code, and all
of which apply to hyperion's own suite:

- **A forgery test whose helper forges nothing.** A `%post-without-csrf` helper routed
  through a request builder that had just been taught to attach a token to any POST carrying
  a cookie; every forgery test passed while the protection was untested. The fixture needs
  an explicit opt-out, and the suite needs a control proving the forgery is actually
  unsigned.
- **A fixation test whose setup never fires.** Where sessions are minted only at sign-in, an
  anonymous GET used to obtain a "pre-login session" returns none, so the assertions sit
  behind a condition that never holds. Assert that the setup happened before asserting what
  it implies. Note that decision (2) above *changes* this: a form-bearing response does mint,
  so the test must obtain its pre-session the same way a visitor does.
- **A form sweep that agrees with the bug.** "Every posting form carries a token" catches a
  real miss only when the test's rule is written independently of the implementation's. A
  shared predicate agrees with itself.
- **A refusal reachable only through the injector is not a refusal.** If the check and the
  injection are composed into one `secure-app` wrapper, a test that exercises both cannot
  distinguish a working check from one that only ever sees requests the injector has already
  blessed. The check needs a test that builds the request by hand, with no injector in the
  image — and the natural home for it is a suite that does not load the injection half at
  all. That is the existing precondition rule, applied to a wrapper instead of a system.

## Open: how injection reaches a form

Decision (3)'s *check* half has a clear seam; its *injection* half does not. hyperion has no
render-side form helper — `http.lisp:32/53/61` are request-side parsers — so "inject at the
response boundary" means **rewriting rendered HTML on every response**, which is far larger
than the sentence implies and is where an implementation is most likely to go wrong. The
alternative, a form component apps must call, is cheap but **opt-in**, which weakens exactly
the property (3) exists to sell.

**Decided 2026-09-14: the injector is a Spinneret `deftag` on `:form`.** This was an open
question and is now tested rather than reasoned about. hyperion owns its HTML DSL, and
`deftag` *can* shadow a standard tag: `parse-html` calls `deftag-expand` (`compile.lisp:31`)
**before** the `valid?` standard-tag check (`:35`), and the escape from infinite recursion is
that `parse-html` does not descend into `with-tag` (`:22`). The working shape, with app code
unchanged:

**Corrected 2026-09-14 from inside the implementation.** The shape first recorded here
expanded to `spinneret::with-tag` with an inner `with-html` around the children. That works,
and it reaches for a **private symbol**: `WITH-TAG` is `INTERNAL` to `spinneret`, and the
inner `with-html` existed only to work around `parse-html` not descending into a `with-tag`
form. `DYNAMIC-TAG` is **EXTERNAL**, emits by name at *runtime*, and therefore cannot
re-enter the deftag — so the recursion never arises and the workaround is unnecessary. Same
output, public API, no gymnastics. Build it on `dynamic-tag`.

The first shape was the first thing that worked, not the best thing, and the difference was
only visible from inside the implementation — which is the argument for sweeping a Proposed
ADR against the code **twice**: once before implementing it, and once from within.

**Three known holes, two of them silent:**

1. **Compile order.** A template compiled *before* the deftag loads emits an unprotected form
   and says nothing. With ASDF fasl caching an app can hold a stale fasl compiled against an
   older hyperion, and "protected without its author knowing" inverts into *unprotected*
   without its author knowing.
2. **Runtime-named tags bypass it.** `dynamic-tag` emits by name at runtime and never
   consults the deftag; `interpret.lisp:33` routes `interpret-html-tree` through it, so both
   data-driven paths are unprotected.
3. ~~**GET forms get a token**~~ — **CLOSED in the implementation.** The method's *value* is
   read at runtime while its *presence* is decided at expansion, so a computed method is
   honoured and a form with no `method` is GET by HTML default and gets nothing.

   **And the case this ADR never mentioned, which is the one that would have bitten:** an
   `hx-post` form has **no `method` attribute at all**. `hx-post` *is* the verb in hyperion's
   idiom, so a method-only rule would have left the framework's own house style as the single
   shape the injector missed. It is handled. Recorded because the next person will write the
   method-only rule.

`deftag`'s namespace is also global to the image, so shadowing `:form` affects every
Spinneret user in the process, not only the app. **This has already happened and is
intended:** `praxeon/src/web.lisp:277` renders `(:form :hx-post "/api/message" …)`, and
`praxeon/web` depends on `hyperion` — so praxeon's chat form now routes through the injector
and carries a token wherever `hyperion/csrf` is loaded, without praxeon asking for it. That
is the property this decision sells, working; it is recorded so it is known rather than
discovered.

**Why this is still the right option, and the argument that settles it: all three holes are
availability bugs rather than security bugs, provided the check half is authoritative.** If
the check refuses a state-changing POST without a valid token, a form that missed injection
does not silently lose protection — its POST is refused and the form visibly breaks. A silent
vulnerability becomes a loud functional failure. That is fail-closed, and it is why the check
half is not merely shippable first but is *what makes the injector's imperfections
survivable*. The opt-in form component is not better: it has the same three holes plus an API
an author must remember.

**The corollary is the one to carry into review: the exemption list is the dangerous surface,
not the injector.** An exempted route with a missed token fails **open**, and nothing
anywhere complains. Review attention belongs there.

## Provenance

The fork was escalated rather than guessed, by a consuming app that was building CSRF
app-side under launch pressure and stopped at exactly the line where an app should stop. It
built the post-authentication half, put sign-in, sign-up, reset and its newsletter on a
written exemption list with the reason in source, and **pinned the exemption with a test** so
that closing it upstream would be a deliberate change rather than a surprise regression. The
recommendation in (3) is its field measurement, not a preference.

**Corrected 2026-09-14, after the implementing lane swept this ADR against the code as a
carried / not-carried checklist.** Four claims did not survive, and the pattern in them is
worth naming: every one was written from the hub by reading a *signature* or a *docstring*
rather than the call site. `ensure-session :create nil` exists, but its only caller reads
`session-id` at entry and breaks under it; `consent-allows-p` is the real symbol, not
`allowed?`; `*necessary-categories*` names session and security only in its docstring; and
ADR-0015 schedules Clack's removal for M4 rather than having performed it. The largest miss
was the streaming path: since M2 a body may be a closure that runs *after* the head is
framed, so mint-at-render cannot set a cookie at all. An ADR written above the code is worth
having, and is worth sweeping against the code before anyone implements it.

**The decisive input was the objection failing.** The pre-session option was reported as
colliding with `hyperion/consent`, which made the stateless cookie look necessary rather than
merely different. Reading `consent.lisp` showed the opposite: security cookies are
`:necessary` and exempt by construction, so the simpler option was available the whole time.
The report was reasonable — a consent module and a cookie for anonymous visitors *sound* like
they interact — and checking cost minutes. It is recorded because the next person will have
the same intuition.
