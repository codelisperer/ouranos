# Meta: what an operator actually has to set up

**Observed 2026-09-15** against Meta's own documentation. Ad APIs move; re-read the App
Dashboard rather than trusting a step here that contradicts it. Companion to
[`ads-design-sketch.md`](ads-design-sketch.md); the *why* lives there, the *clicks* live here.

## There are two credential relationships, and they are not variants of one

This is the thing to get straight before touching a dashboard, because the setups differ, the
token types differ, the failure modes differ, and **only one of them spends your own money**.

| | **First-party** | **Brokered for a member** | **On behalf of a member** |
|---|---|---|---|
| Whose ad account | the platform's own | **the platform's own** | the member's |
| Who pays the network | you | **you** | they do |
| Who is billed | nobody | **the member, cost + markup** | nobody |
| How many | one | one account, many members | one per connected member |
| Credential | a **System User** on your own business | **the same one** | issued by **Facebook Login for Business** |
| Set up by | you, once, in Business Settings | you — nothing for the member to connect | the member, by clicking Connect |
| Needs App Review | **no** | **no** | **yes** |
| Who may use it | superadmins only | members, as a paid service | the member |
| Fails by | 90 days of app inactivity → `Needs-Heartbeat-By` | same | member revokes / leaves → `Needs-Human-Reauth` |

**The middle column is the one that surprises people.** Brokered advertising shares a
credential with first-party and a beneficiary with on-behalf-of, and is the same as neither.
Two consequences it alone carries:

- **Spend must be attributable at creation time.** Billing a member for their share means
  knowing which spend was theirs, and **no network will tell you retroactively** — there is no
  field to ask. The attribution has to be written into what is sent. Retrofitting it is not
  expensive, it is *impossible*: campaigns that already ran cannot be re-labelled.
- **The blast radius is shared.** A member's policy violation lands on **your** ad account, and
  a restricted account takes down **every brokered member at once**. First-party risk is your
  own conduct; brokered risk is everyone's conduct, pooled. That is a product decision, not a
  code one — but it should be made deliberately rather than discovered.

**A useful sequencing consequence:** brokered runs on your own credential, so it needs **no App
Review**. If members-advertising is wanted before the review clears, the brokered path can ship
first and the on-behalf-of path can follow — which also means the first-party integration is
not merely a warm-up, it is the foundation of two of the three.

A system user token reaches **only assets your business owns**. It cannot touch a member's ad
account, and no amount of permission-granting changes that. If the first thing you build is
the first-party path — which is reasonable, since it needs no review — do not expect it to
generalise to members by adding a parameter.

---

## Path A — first-party, for the platform's own advertising

No App Review. Nothing to wait for. Roughly ten minutes.

**Ads Manager is the wrong surface and has none of this.** API settings live in two other
places, and the order matters because token generation asks which app it is for.

1. **Create the app** — <https://developers.facebook.com/apps/> → Create App → add the
   **Marketing API** product. Adding the product grants the entry access tier immediately.
2. **Copy the credentials** — Settings → Basic. The **App Secret is shown once**; losing it
   means deleting and recreating the app.
3. **Business Settings → Users → System Users** —
   <https://business.facebook.com/settings/system-users> → Add. *You must be a Business admin
   to see this section at all*; a missing menu is a permissions problem, not a navigation one.
4. **Assign two assets to the system user**: the **App**, and the **Ad account** at the
   view/analyze level. The read path needs nothing more, and a credential that cannot mutate
   is worth more than a policy saying it should not.
5. **Generate New Token** → select the app → tick **`ads_read`** only → Generate. **Copy it
   before closing the dialog.**
6. **Verify** at the [Access Token Debugger](https://developers.facebook.com/tools/debug/accesstoken/):
   you want **`Expires: Never`** and **`Scopes: ads_read`**. A 60-day expiry means you have a
   *user* token, not a system user token — catch that now rather than in two months.

**Then keep it alive.** A system user token does not expire on a clock, but **90 days with no
API call, no user login and no webhook invalidates every token the app holds**, and recovery
needs an admin in the App Dashboard. One call per 90 days is enough. This is why
`Credential-State` carries `Needs-Heartbeat-By` rather than leaving it to a cron job somebody
has to remember.

---

## Path B — members connecting their own ad accounts

**Members do not become developers.** One app — yours — and each member connects through
**Facebook Login for Business**, which Meta describes as the path for "tech providers building
integrations with Meta's business tools".

### The gate, stated in Meta's own words

> "If your app will be used by anyone without a Role on the app or a role in a Business that
> has claimed the app, it must first undergo App Review."

and

> "unapproved permissions can only be requested from app users who have a role on the
> requesting app"

Read the second one carefully, because it is the trap: **without App Review, the only people
who can grant your app `ads_read` are people you have added to the app** — which is the
"every member is a developer" outcome, arrived at by omission. App Review is what makes this a
product rather than a developer tool.

What review wants, from the survey: screencasts, **at least one successful call per permission
in the 30 days before submitting** (so the first-party path above is a prerequisite in
practice, not just a warm-up), and **Business Verification**, which is a separate process.
Decision is stated as about a week. It is calendar time you cannot compress — start it before
you need it.

### The configuration choice that decides your token lifecycle

Facebook Login for Business lets you choose what the flow issues, and the two are very
different products:

- **User access token** — the member logs in with a personal Facebook account. About 60 days,
  then re-consent. Forever, for every member.
- **System-user access token** — the member logs in with their **business portfolio**, whose
  business provisions a system user for your app. Meta: *"System-user access tokens are only
  required if this configuration needs continuous access to business assets, such as Facebook
  Pages, ad accounts or Instagram accounts."*

Continuous access to a member's ad account is exactly the stated case. **Choose the second.**
The first works in a demo and becomes a re-consent treadmill in production.

### What the app must treat as ordinary

A member's connection ending is **not an error**. They change agency, leave the business,
revoke access in their own settings, or their business removes your partner access. The UI
renders `Needs-Human-Reauth` and offers a Connect button. An integration that treats
revocation as an exception will log it as a fault and surface it as a 500.

---

## Gotchas worth knowing before they cost you a day

- **`read_insights` is not ads insights.** It is Pages, apps and web domains. The permission
  you want for reporting is **`ads_read`**; `ads_management` is the superset that can mutate.
  Picking the wrong one passes review and then returns nothing useful.
- **The access tier names are in flux.** Some Meta pages say Standard/Advanced, others
  Limited/Full, and two pages dated a day apart contradicted each other during the survey.
  Read whatever the App Dashboard says; do not trust a tier name in any document, this one
  included.
- **The docs tree is mid-migration** between `/docs/` and `/documentation/ads-commerce/`. Both
  are live and their contents differ — reference pages were on v26.0 while guides still showed
  v25.0 examples.
- **Nothing is a sandbox by default.** Calls on any access level are against production data.
  A sandbox ad account exists (one per app) but Meta's own pages disagree about whether ad
  creation and insights work in it.
- **An empty read is indistinguishable from a broken one.** With no campaign that has ever
  delivered, a correct integration returns nothing. The first live call proves something only
  against an account with delivery history.
