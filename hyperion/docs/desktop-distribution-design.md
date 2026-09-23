# Hyperion desktop: distribution & self-update — design

**Status:** design, 2026-07-26. Decisions recorded in
[ADR-0010](adr/0010-desktop-distribution-and-self-update.md); the shell itself is
[ADR-0008](adr/0008-desktop-shell-cl-native-webview.md) (built, M1 proven).

## The goal, stated once

A Hyperion desktop app **knows when a build for its own OS is available, fetches it,
verifies it, installs it and restarts into it** — one click, no browser, no reinstall.
That pattern (proven in the Tauri world, and in one of the author's Tauri apps) is what makes a
desktop app maintainable at all: without it, every fix strands users on old versions.

Everything below exists to serve that sentence. CI is not the goal — CI is the link that
produces the artifact the updater consumes. The chain, end to end:

```
  git tag v1.3.0
        │
        ▼
  CI matrix (native runners — SBCL cannot cross-compile; see docs/ci.md)
   ubuntu-22.04 ─┐   windows-2022 ─┐   macos-14 ─┐
                 │                 │             │
        per-OS bundle + installer, each Ed25519-signed
                 └────────┬────────┴─────────────┘
                          ▼
              latest.json  (signed manifest)
                          │
            ┌─────────────┴─────────────┐
            ▼                           ▼
     GitHub Releases                 S3 bucket          ← update SOURCES (pluggable)
            └─────────────┬─────────────┘
                          ▼
   installed app polls → "Update available 1.3.0" (HTMX banner)
                          ▼
        download → verify sig → stage → swap → relaunch
```

## 1. What ships

The app is **two files plus metadata** — a dumped SBCL image and the native webview
launcher (ADR-0008). That is the whole payload; there is no runtime, no `node_modules`,
no framework directory. It makes the update mechanics dramatically simpler than
Electron's, and it is worth protecting that simplicity.

```
<App>/                          the bundle, identical on every OS
  <app>[.exe]                   the dumped SBCL image (the entry point)
  hyperion-view[.exe]        the native shell (default-launcher finds it beside argv0)
  VERSION                       "1.3.0" — the installed version, read at startup
  updater.pub                   the Ed25519 PUBLIC key this build trusts (see §4)
```

**Windows: the dumped image is a console binary.** `save-lisp-and-die :executable t` writes
a CUI-subsystem PE, so launching it spawns `conhost.exe` and leaves a black console window
sitting behind the app — instantly non-native-looking. One header field fixes it:
`editbin /SUBSYSTEM:WINDOWS` (MSVC, the same toolchain the launcher build already needs),
run *after* the dump since `save-lisp-and-die` ends the process
(`scripts/windows-gui-subsystem.ps1`). Verified on SBCL 2.6.6: the image still runs and
still launches the webview child. The trade is that stdout/stderr then go nowhere — a
shipping build must log to a file or its own UI, not the terminal.

macOS wraps the same two files in a bundle, because Gatekeeper and the Dock require it:

```
<App>.app/Contents/
  Info.plist                    CFBundleIdentifier, CFBundleShortVersionString, LSMinimumSystemVersion
  MacOS/{<app>, hyperion-view}
  Resources/{VERSION, updater.pub, AppIcon.icns}
```

### Install location — per-user, always

**This is load-bearing for self-update, not a preference.** An app installed to
`C:\Program Files` or `/Applications` cannot rewrite itself without elevation, which
turns one-click update into a UAC/authorization prompt every release — or, worse, into a
privileged updater service. Install per-user, the way Chrome and VS Code do:

| OS | Location |
|----|----------|
| Windows | `%LOCALAPPDATA%\Programs\<App>\` |
| macOS | `~/Applications/<App>.app` (support `/Applications`, but prompt for auth there) |
| Linux | `~/.local/lib/<app>/` with a `~/.local/bin/<app>` symlink, or a single AppImage in `~/Applications` |

Per-machine installs stay possible for managed fleets — they simply get updates from the
deployment tool instead of the in-app updater, which the app detects (§7) and says so
rather than failing.

### The app's own data — `~/.<appname>`

Orthogonal to the bundle and **never touched by an update**: config, databases, exports.
Schema-versioned `config.toml` with a `config_version` key, `load → detect → migrate →
restamp` on startup, unparseable files backed up rather than wiped. This is `cons`'s
scaffold concern; noted here because the update path must guarantee it survives.

**Asserted, not merely promised (#111).** `scripts/verify-appdata-survives.ps1` installs a
real application with a real installer, populates `~/.<appname>`, applies a real signed
update through `hyperion/update` — the real `launch-installer`, the real installer — and
requires the directory to be byte-identical afterwards. It asserts the update *landed*
first, because an installer that silently did nothing leaves the data perfectly intact;
and `-Control` rebuilds the installer with a deliberate `RMDir /r` so the harness has to
be shown catching the loss it exists to catch. Windows, both packagings. **macOS and Linux
are blocked on §7's unwritten strategies (#72) and are openly unrun** — a guarantee kept
on one platform is not a guarantee. The client half of the same claim, covering every
refusal path on every platform, is in `hyperion/tests/update-client-tests.lisp`.

## 2. Versions and channels

- **Semantic versioning**, `MAJOR.MINOR.PATCH`, optional `-beta.N` pre-release suffix.
  Comparison is a pure function — Coalton's job (§6).
- **Channels** are separate manifests, not fields: `stable`, `beta`. An app is built for
  one channel and reads that channel's manifest URL; switching channels is a setting that
  changes the URL. Simpler than filtering one manifest, and a beta build can never be
  offered to a stable user by a manifest bug.
- **Anti-rollback:** the client refuses a manifest whose version is **lower than or equal
  to** the installed one, and refuses a manifest whose `published` timestamp predates the
  installed build's. A stale-manifest replay cannot downgrade an app into a known-bad
  version.

## 3. The manifest

One signed JSON document per channel, at a **permanent URL**. This is the contract
between CI and every installed app; version it (`schema: 1`) from the first release.

```json
{
  "schema": 1,
  "product": "coalton-repl",
  "channel": "stable",
  "version": "1.3.0",
  "published": "2026-07-26T14:02:11Z",
  "notes_url": "https://github.com/codelisperer/ouranos/releases/tag/v1.3.0",
  "minimum_version": "1.0.0",
  "platforms": {
    "windows-x86-64": {
      "format": "nsis",
      "payload":   { "url": "…/coalton-repl-1.3.0-setup.exe",
                     "size": 18234112, "sha256": "…", "sig": "…" },
      "installer": "same"
    },
    "linux-x86-64": {
      "format": "appimage",
      "payload":   { "url": "…/coalton-repl-1.3.0-x86_64.AppImage", … },
      "installer": "same"
    },
    "macos-arm64": {
      "format": "app-targz",
      "payload":   { "url": "…/coalton-repl-1.3.0-macos-arm64.app.tar.gz", … },
      "installer": { "url": "…/coalton-repl-1.3.0-arm64.dmg", "sha256": "…", "sig": "…" }
    }
  }
}
```

- **`format`** tells the client which apply strategy to use (§7). It is explicit in the
  manifest rather than inferred from the OS, so a product can change packaging without
  shipping a new client first.
- **`payload`** is what the *updater* fetches; **`installer`** is what a *human* downloads
  for a first install. On Windows and Linux **they are the same artifact** (`"same"`) — the
  NSIS installer and the AppImage each serve both roles. Only macOS differs, because a
  `.dmg` must be mounted by a human and a `.app` is a directory tree.
- **No zip anywhere, and no archive library.** Windows updates by running its own installer
  silently; Linux replaces one self-contained file; macOS unpacks a `.tar.gz` with the
  system `tar`. That is one artifact per platform to build, sign, publish and test — and
  the user never extracts anything.
- **`minimum_version`** forces a manual reinstall when an in-place update cannot work
  (e.g. the bundle layout changed). The app says so plainly and links the installer.
- Platform keys are `<os>-<arch>` using SBCL's own vocabulary (`windows-x86-64`,
  `linux-x86-64`, `macos-arm64`) so the client derives its key from
  `(uiop:operating-system)` + `(uiop:architecture)` with no mapping table to drift.
- **Only a VERIFIED key may be emitted.** Those three are the whole list: they are the
  `desktop-release` CI matrix, and no other key has ever come out of a real build.
  `scripts/build-desktop-app.lisp` holds them in `*verified-platforms*` and **refuses to
  build** anything else (exit 2) rather than producing a bundle nobody has run. A key is a
  promise — it names the bundle directory, the manifest keys on it, and a client matches
  itself against it to decide an update applies — so an unverified one is indistinguishable
  from a tested one all the way to the user's machine. `windows-arm64` is the live case
  (pre-publication issue 145): derivable, plausible, and never once executed. Whoever verifies a new platform
  sets `OURANOS_ALLOW_UNVERIFIED_PLATFORM=1` to build, works that issue's checklist, then
  adds the key to `*verified-platforms*` — the override is for the verifier, not for CI.
  Only an explicit affirmative (`1`/`true`/`yes`/`on`) counts: a name exported with an
  empty value, or `=0`, leaves the guard armed, since a check that can be switched off
  by an empty CI expression eventually is.

## 4. Signing — Ed25519, in our control

Two independent signatures, because they defend different things:

1. **Each artifact** is signed. Defends against a compromised or MITM'd *host*: a payload
   that does not verify against the baked-in public key is discarded, wherever it came from.
2. **The manifest itself** is signed (detached `latest.json.sig`). Defends against a
   *substituted manifest* — an attacker who can serve a valid old artifact plus a forged
   manifest could otherwise pin users to a vulnerable version.

Verification is [Ironclad](https://github.com/sharplispers/ironclad)'s Ed25519 against
`updater.pub`, which ships **inside the bundle**. Rotating the key is therefore a normal
release: build N trusts key A; build N+1 ships key B and is signed with A. (A build can
carry a *list* of trusted keys to make rotation a two-release, zero-downtime affair.)

**Key custody:** the private key never enters the repo. It lives in the CI secret store
(`OURANOS_UPDATE_SIGNING_KEY`) and in the maintainer's password manager as the only backup —
losing it means every installed app must be reinstalled by hand, so it is the single most
important secret in the project. Signing happens in a dedicated CI job that never runs on
pull requests from forks.

Note what this is **not**: Ed25519 payload signing is *update integrity*. It does not stop
SmartScreen or Gatekeeper warning on first install — that needs OS code-signing (§10),
which is scheduled, not skipped.

## 5. Update sources — a neutral protocol, two backends

Per the ecosystem convention (pluggable backends behind neutral protocols), the client
knows nothing about where updates live:

```lisp
(defgeneric fetch-manifest (source channel))       ; -> the manifest BYTES + its signature
(defgeneric fetch-artifact (source spec stream))   ; -> streams bytes, reports progress
```

> **Amended 2026-09-01.** This first read *"parsed manifest + its signature"*, and that was
> wrong in a way worth recording rather than quietly correcting. **Parsing inside the
> protocol puts the parse before the verification** — the exact ordering this whole module
> exists to prevent, since the signature is over the bytes and anything decoded before it is
> checked is untrusted input already interpreted.
>
> The implementing lane departed from the sketch rather than following it, and said so:
> *a protocol whose signature invites the wrong order eventually gets it.* The generic
> returns bytes; the caller verifies, then decodes, then parses, then interprets.

- **`github-release-source`** — `https://github.com/<org>/<repo>/releases/download/
  <app>-<channel>/<channel>.json`. Zero infrastructure; public repos only (a private repo
  needs a token, which an installed app cannot hold safely).

> **Amended 2026-09-16 (pre-publication issue 332).** This read `/releases/latest/download/<channel>.json`,
> described as *"a permanent redirect to the newest release's asset, so no URL changes
> per version"*. That is true of a repository holding **one** product and false of every
> other, and the release repository holds every desktop app built from this tree.
>
> `latest` resolves **per repository**. Whichever product published most recently owns
> it, so every other product's client asks `latest` for a manifest that is not in that
> release. It gets a 404 — and reads it *correctly*, as "this channel has published
> nothing yet". The failure is therefore **silent**: no error, no log line, updates just
> stop for every product but the most recently released one.
>
> The fix is a per-app, per-channel **pointer release** — tag `<app>-<channel>`, assets
> replaced on each publish — alongside the immutable `<app>-v<version>` release the
> manifest's payload URLs name. Nothing else can take that tag over. Mutability costs
> nothing: the manifest is signed and verified over its exact bytes before it is parsed,
> so replacing an asset is the only way to move a channel and forging one still needs
> the key.
>
> Recorded rather than corrected in place because the reasoning that produced the
> original is sound for the single-product case it assumed, and a reader who knows only
> the verdict will re-derive the original the next time a product gets its own repo.
- **`s3-source`** — `https://<bucket>.s3.<region>.amazonaws.com/updates/<channel>.json`,
  with `updates/*` public-read, plus a permanent human link
  `download/<App>-Setup.exe` that each release overwrites. Costs pennies; works for private
  products; the pattern already proven in the author's Tauri app.

Both are implemented from day one so the protocol is real rather than aspirational, and an
app picks one (or a list, tried in order — a useful fallback when a host is down).

### 5a. Releases are published to this repository, through one variable, `RELEASE_REPO`

Until 2026-09-23, releases were published to
[`codelisperer/ouranos-desktop-releases`](https://github.com/codelisperer/ouranos-desktop-releases),
because this repository was private. The updater client fetches with no credential — an
installed application cannot hold one safely — and GitHub serves a private repository's
release assets only to an authenticated request. A release attached here would have looked
healthy in CI and returned 401/404 to every installed copy, so the assets needed a public
host, and a second repository was the cheapest one.

**That ended when this repository went public.** Releases are now published to this
repository's own releases, using the workflow's built-in `GITHUB_TOKEN`. The second
repository is archived and its publishing token was deleted. Copies of `coalton-repl` 0.1.0
installed from it still poll its channel, which will not move again, so they have to be
reinstalled from a release published here.

**The seam is one environment variable.** `RELEASE_REPO` is set once in
`.github/workflows/desktop-release.yml`, now to `${{ github.repository }}`, and every other
site — the manifest's `--base-url` and `--notes-url`, both `gh release` steps, the channel URL
that `verify-published` fetches — reads `${RELEASE_REPO}`. Both `gh release create` calls pass
`--latest=false`, because this repository's "Latest release" belongs to the framework, and
installed copies never read it anyway: they poll the channel pointer.

**Credential facts, written here so that someone debugging a failed release does not have to
ask.** Publishing uses `GITHUB_TOKEN`, with `contents: write` granted to the `publish` job
only. The manifest is signed with the `OURANOS_SIGNING_KEY` secret, the private half of the
release key. It is verified with the `OURANOS_PUBLIC_KEY` repository variable, the public
half, which builds also put inside the app. Both were set on this repository on 2026-09-23,
with the same key pair the 0.1.0 release used. A release that fails at "Publish the versioned
release" with a 403 points at the job's permissions, since no personal token is involved any
more.

## 6. The client — typed core, effectful shell

Per ADR-0002, the state machine and version algebra are **Coalton** (pure, checked), the
HTTP/file/process work is **CL**.

```lisp
;; hyperion/update (Coalton) — no IO here
(define-type Version (Version Integer Integer Integer (Optional String)))
(define-type Channel Stable Beta)
(define-type UpdateState
  UpToDate
  (Available Version)
  (Downloading Version Progress)      ; Progress = bytes done / bytes total
  (Verifying Version)
  (Staged Version)                    ; on disk, verified, awaiting restart
  (Failed UpdateError))
(define-type UpdateError
  NetworkUnreachable (BadSignature String) (Rollback Version Version)
  (NeedsReinstall Version) NotWritable)      ; NotWritable = per-machine install
```

`NotWritable` is deliberately a *state*, not an exception: an app installed per-machine
must show "an administrator installed this app; ask them to update it", not a stack trace.

The CL shell (`hyperion/update`, an aux system like `hyperion/desktop`) drives it: a check
timer, `dexador` for fetch, Ironclad for verification, staging into
`<install>/.staged-<version>/`, and the apply strategy in §7. **One new dependency:
`ironclad`** — `dexador` is already in the tree via praxeon, and the format choices in §3
mean no archive library is needed at all.

## 7. Applying an update, per OS

One strategy per `format` (§3). Each stages and verifies first; none writes into a live
bundle.

**Windows — `nsis`: hand off to our own installer.** The payload *is* the installer, so
after verifying it: launch it with `/S` (silent) `/D=<install dir>`, then **exit
immediately** so nothing is locked; NSIS replaces the files and `Exec`s the new build on
completion. This sidesteps the locked-exe problem entirely — a running `.exe` cannot be
overwritten, and the process that would be overwritten is gone before the installer starts.
It also keeps shortcuts, the uninstall entry and the install location correct, which a
file-level swap silently drifts away from.

The cost is a brief close-and-reopen (Tauri behaves the same), and that once the installer
is handed control we can no longer report progress — so the UI states "installing…" until
the new process reports its version.

**Windows — `inno`: the same handoff, different flags, and one property that had to be
measured.** Inno Setup is supported alongside NSIS because it signs the installer *and the
uninstaller* from a `SignTool` directive in the script rather than a post-build step
somebody has to remember. The client picks the strategy from the manifest's `format`, so a
product may switch packaging without shipping a new client. Flags: `/VERYSILENT
/SUPPRESSMSGBOXES /NORESTART` and `/DIR=<install dir>` which, unlike NSIS's `/D=`, need not
come last.

**Do not quote `/DIR=` in the client, however a shell spells it.** Inno's own
documentation shows the value quoted, and in a shell it must be; a process spawner handed
an argument *list* quotes each argument itself, so an argument that arrives already quoted
gets a second layer and Inno receives a literal `"` inside the value. The client wrote
`(format nil "/DIR=~S" dir)` — which reads like "quote the path" and is not, `~S` being
the Lisp printer, so it escaped every backslash as well. Measured against a real
installer, one variable at a time:

| argument | result |
|---|---|
| `/DIR="C:\Users\…\Q1"` — hand-quoted, single backslashes | **exit 3, nothing installed** |
| `/DIR=C:\\Users\\…\\Q2` — unquoted, doubled backslashes | exit 0, installed |
| `/DIR=C:\Users\…\has space\Q3` — plain, quoted by the spawner | exit 0, installed |

So it is the quotes and not the backslashes, and the third row is the control that
matters: a path with a space is the case the quoting was reaching for, and the spawner
already handles it. **NSIS never showed the fault**, because `/D=` takes no quotes — the
same defect, in the same module, invisible in the packaging that had been run and fatal in
the one that had not (pre-publication issue 76). Found by §1's #111 harness, which asserts that the installed
version actually changed.

**THE RELAUNCH IS A STATED PROPERTY OF THE UPDATE PATH, AND IT IS NOT FREE.** Inno's
`[Run]` entries carrying `postinstall` are the finish-page checkbox and are **skipped
under `/VERYSILENT`** — which is precisely the install the updater performs. A direct port
of the NSIS installer therefore installs correctly and never restarts the application,
leaving every updating user looking at a closed window. The fix is a second `[Run]` entry
guarded by `Check: WizardSilent`, the analogue of NSIS's `IfSilent`.

Measured both directions against a real 39 MB SBCL executable that writes a marker on
start, installed with `/VERYSILENT`:

| | result |
|---|---|
| with `Check: WizardSilent` | marker written — **relaunched** |
| with that line removed | files installed, **no marker, no relaunch** |

The control also confirms the install itself still succeeds, so the relaunch is the only
difference. Any future packaging added to §3's `format` vocabulary owes the same
demonstration: *the installer ran* and *the user got their application back* are separate
claims, and only the second one is what an update promises.

*Fallback, for a portable install with no installer present:* the rename dance ADR-0008
anticipated — a running `.exe` cannot be deleted or overwritten but **can be renamed**, so
rename `<app>.exe` → `.old`, write the new one, relaunch, delete `.old` at next startup.
Kept in the design because a portable/no-install mode is a plausible future ask, and
because it is the rollback path if an installer run fails midway.

**macOS — `app-targz`.** Replacing files inside a signed `.app` invalidates its signature,
so swap the **whole bundle**: unpack the `.tar.gz` (the system `tar` — no library needed)
to `<App>.app.new` beside the original, `codesign --verify` it,
then `rename()` old → `.old`, new → live (atomic within a volume), relaunch via `open`,
delete `.old`. Two extras that bite: the downloaded zip carries the **quarantine** xattr —
strip it with `xattr -dr com.apple.quarantine` on the staged bundle *before* the swap, or
Gatekeeper re-prompts; and an app in `/Applications` may need authorization, which is where
the per-user install location (§1) earns its keep.

**Linux — `appimage`.** The easiest of the three: one self-contained file. Unlinking a
running binary is fine (the kernel keeps the inode alive for the running process), so
write the new AppImage beside the old, `chmod +x`, `rename()` over it, relaunch. If the app
was installed from a `.deb` or the package manager, the updater detects a read-only or
package-managed path and reports `NotWritable` — "update via your package manager" — rather
than fighting it.

**Common invariants.** Stage-then-swap (never write into the live bundle), verify before
swapping (never after), keep the previous version until the new one has started
successfully once, and treat "relaunch failed" as "roll back on next start".

## 8. The in-app experience — Hyperion's unfair advantage

In Tauri this is a JS plugin talking to a Rust bridge. Here the app **is** an HTTP server
rendering HTMX, so the updater is just another route and component — no bridge, no JS:

```lisp
(:div :id "update-banner"
      :hx-get "/_hyperion/update/status"
      :hx-trigger "load, every 6h"        ; the check itself is the poll
      :hx-swap "outerHTML")
```

- `GET /_hyperion/update/status` → **CORRECTED** (pre-publication issue 333): *not* an empty response. The
  sketch above puts `hx-get` on the element it also swaps `outerHTML`, so replacing it with
  nothing **deletes the poller** — the updater never checks again, in the state that is
  overwhelmingly the common case, and the app then looks exactly like an app with no update
  available. What ships is the shell with no children: visually nothing at all, which is
  what `+quiet-statuses+` requires, while the element that polls survives its own response.
  A loud state fills that shell with the version, the notes link and one control.
  - Consequence for the sketch: `load` belongs in the element the **app renders once**
    (`update-mount`), and must never appear in a **route response**. `hx-trigger="load"`
    fires whenever an element enters the DOM and every swap inserts one, so a reply
    carrying it re-requests itself forever.
- `POST /_hyperion/update/apply` → starts the download. **The SSE progress bar is PLANNED
  and deliberately unbuilt** (pre-publication issue 333). `state.lisp` overrules this line for the state that
  would need it: on `Applying`, "PROGRESS IS UNREPORTABLE FROM HERE BY CONSTRUCTION — the
  process that would report progress is the one being replaced … a progress bar that cannot
  advance is worse than a sentence that explains why." So `applying` renders that sentence.
  The *download* phase is reportable in principle, but `apply-update` is synchronous with no
  progress seam to subscribe to; adding one is a change to `hyperion/update`, not to the UI.
- `POST /_hyperion/update/restart` → performs §7 and relaunches, **via an app-supplied
  `*restart*` thunk** (pre-publication issue 333). The framework cannot know whether it is inside an AppImage, a
  signed `.app` or an NSIS install, and does not guess — the same position `hyperion/update`
  already takes with `*before-apply*` and `*launch-installer*`.

> Implemented in `hyperion/update-ui` (pre-publication issue 333). Where this section and that system disagree,
> the system is the one that was measured; the corrections above say why rather than only
> that.

These are **generic** components (per Hyperion's rule: never domain-specific), themeable
and overridable, mounted by the app under a reserved `/_hyperion/` prefix.

A tempting future: because this is a live SBCL image, a *patch* channel could load new fasls
into the **running** app with no restart at all — the hot-reload machinery
(`hyperion/dev`) pointed at a signed remote payload. Genuinely novel, and genuinely risky
(state/version skew, no clean rollback). Not M1; recorded so we remember it is possible.

## 9. Installers

**One artifact per platform, serving both first install and update** (except macOS, §3) —
so a user never unzips anything, and CI has one thing per OS to build, sign, publish and test.

| OS | Format | Tool | Notes |
|----|--------|------|-------|
| Windows | `.exe` (NSIS) | NSIS via choco on the runner | Per-user install (`%LOCALAPPDATA%\Programs`), no elevation, Start-menu shortcut, uninstaller. Must support `/S` + `/D=` and relaunch on completion — that is also the update path (§7). MSI later if enterprise deployment asks. |
| macOS | `.dmg` (+ `.app.tar.gz`) | `create-dmg` | Drag-to-Applications window for humans; the `.tar.gz` is the updater's payload. The `.app` must be signed + notarized to install cleanly (§10). |
| Linux | `.AppImage` | `appimagetool` (pinned in `scripts/versions.env`) — **built by [`scripts/build-appimage.sh`](../../scripts/build-appimage.sh)** | One self-contained file, and the easiest self-update. It carries what we *build* — the image, the launcher, and the native libraries the bundler copied in (ADR-0013). It does **not** carry `libwebkit2gtk`: that is a full linuxdeploy-style dependency walk plus an LGPL relink question, and is the open row in #78. A `.deb` can follow for Debian/Ubuntu fleets, with updates deferred to the package manager. |

## 10. OS code-signing — the scheduled tax

Not in the first milestone's critical path, but specified now so it is a task with a price
rather than a someday. Ed25519 (§4) keeps *updates* safe regardless; this section is purely
about first-install friction.

**Windows** — SmartScreen shows "unknown publisher" until a certificate earns reputation.
- *Azure Trusted Signing* — ~$10/month, no hardware token, CI-friendly; requires an
  organization with 3+ years of history (or an individual identity check). Cheapest real path.
- *OV certificate* — ~$200–400/year, still shows warnings until reputation accrues.
- *EV certificate* — ~$300–600/year plus a hardware token (awkward in CI), but immediate
  SmartScreen reputation.
- CI: a `sign` step between build and publish; secrets `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`,
  `AZURE_CLIENT_SECRET` (or a `.pfx` + password). Sign **both** binaries and the installer.

**macOS** — Gatekeeper *blocks* unsigned/unnotarized apps by default; this is mandatory for
distribution to anyone but yourself.
- Apple Developer Program — $99/year → a *Developer ID Application* certificate.
- Steps: `codesign --force --options runtime --timestamp --sign "Developer ID Application: …"`
  over both binaries and the `.app`, then `xcrun notarytool submit --wait`, then
  `xcrun stapler staple <App>.app` so it validates offline.
- CI secrets: the `.p12` (base64) + password, and an App Store Connect API key
  (`ISSUER_ID`, `KEY_ID`, the `.p8`) for `notarytool`.
- Note the hard ordering: **notarize the bundle, then build the `.dmg`, then staple**.

**Linux** — no equivalent gate. Optionally sign the AppImage with GPG.

**OS-sign the artefact BEFORE generating the update manifest — never after.**
[`scripts/update-manifest.lisp`](../../scripts/update-manifest.lisp) reads the file's exact
bytes off disk to compute its `sha256` and to produce the detached Ed25519 signature
(`sha256-hex`, `sign-file`), and both Authenticode and `codesign` **mutate the artefact** —
Authenticode embeds the signature in the PE, `codesign` writes into the bundle. Get the order
backwards and the published hash describes a file nobody will ever download: every client
computes a different digest, rejects a perfectly good update, and reports a signature
failure.

That last part is what makes this worth a paragraph rather than a footnote. **The symptom
points at key management and the cause is build order** — the reader goes and checks the
signing key, which is correct, and does not think about a step that ran in the wrong minute.
So the pipeline is: build → OS-sign every binary and installer → *then* `update-manifest.lisp
sign` → publish. This becomes a CI ordering constraint in M2 and should be asserted there,
not remembered.

## 11. Where the code lives

| Piece | Home | Why |
|-------|------|-----|
| Update state machine, version algebra | `hyperion/update` (Coalton core) | Pure, typed, testable without a network. |
| Fetch / verify / stage / swap, HTMX routes + components | `hyperion/update` (CL shell, aux system) | Generic capability; apps mount it. |
| Bundle layout, installers, manifest generation, publish | `cons` (`desktop` target kind) | Project tooling is cons's job (ADR-0007); Hyperion is a library. |
| Toolchain provisioning, the CI matrix | `scripts/setup.{sh,ps1}` + `.github/workflows/` | Shared by every framework, not desktop-specific. **These are the prototype of `cons desktop build` / `cons setup`** — an external app repo cannot reach ouranos's `scripts/`, so the verbs must move into cons before any app can reuse them (cons roadmap §1). |
| Signing keys, channel URLs, app identity | the **app's** repo | Per-product secrets and policy; never in the framework. |

## 12. Milestones

- **M1 — the loop closes.** Per-OS bundle + installer from a tagged CI run; signed manifest
  published to a public release repository; `hyperion/update` checks, downloads, verifies,
  swaps and relaunches on all three OSes; the HTMX banner + progress UI. Proven by the
  `coalton-repl` example updating itself from 0.1.0 to 0.1.1.

  **Status, 2026-09-16 (pre-publication issue 332).** The publish half now exists: `desktop-release.yml` has a
  `publish` job (versioned release + channel pointer, in
  [`codelisperer/ouranos-desktop-releases`](https://github.com/codelisperer/ouranos-desktop-releases))
  and a separate `verify-published` job that fetches the result over the network with no
  credentials, through the client's own code. Until pre-publication issue 332 there was **no publish step at
  all** — the signed manifest was uploaded as a workflow artifact, which is not a URL an
  installed app can reach, so every client-side piece was machinery for consuming a
  release that did not exist.

  The first release, `coalton-repl` 0.1.0, was published on 2026-09-18, while this
  repository was still private, to the separate release repository. A release from this
  repository needs the `OURANOS_SIGNING_KEY` secret and the `OURANOS_PUBLIC_KEY` variable,
  both set on 2026-09-23, and a `coalton-repl-v*` tag; no other credential is involved (5a).
  **S3 is not wired**;
  `s3-source` exists and the client takes a list of sources, so it is additive.
  macOS carries no payload at all — #135, and declared rather than silent via
  `APP_PLATFORMS`.
- **M2 — code-signing.** §10 wired into CI for Windows and macOS; clean first-install on a
  machine that has never seen the app.
- **M3 — `cons desktop`.** Scaffold a new desktop app with the updater, `~/.<appname>`
  config (schema-versioned), icons and installer config already wired; `cons desktop
  build|bundle|publish` drives what CI calls.
- **M4 — fleet concerns.** Beta channel in the UI, staged rollout (percentage gating in the
  manifest), delta payloads if bundle size warrants, and the live-patch experiment (§8).

## 13. Open questions

1. **Where does `VERSION` come from?** A file in the bundle is simple but can desync from
   the image; baking it into the image at dump time (a `+version+` constant, as
   `hyperion.lisp` already does) cannot desync but requires a rebuild to correct. Probably
   both, with the baked-in value authoritative and the file for the installer's benefit.
2. **Check cadence.** Every 6h + on launch is the Chrome-ish default; too eager for an app
   opened all day, and each check is a request per user per interval on someone's bandwidth.
3. **Who owns rollback?** The app can revert to the previous bundle, but deciding a release
   is bad is a human act — does the manifest gain a `revoked` list the client honours?
