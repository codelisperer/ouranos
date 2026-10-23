# Hades

**The OS ergonomics layer.** It makes each platform's own features pleasant to use from Common
Lisp, and porting between platforms a non-event — over the raw bindings aion provides.

*Hades, who rules a realm nobody visits willingly and everybody eventually needs.* Windows is
first, being furthest from POSIX; macOS and Linux are peers, not afterthoughts.

> **Status: four facades.** The charter is [ADR-0001](docs/adr/0001-charter.md).
> `hades/single-instance` (#305) is a per-user, per-directory lock that the operating system
> holds and releases when the process ends; `hades/credentials` (#357) keeps secrets in the
> operating system's store; `hades/notify` (#819) shows a modal notice before an app has a
> window; `hades/open` (#820) shows a path in the file manager and opens a URL in the browser.
> The service lifecycle facade is still blocked on `aion/windows/service`, which does
> not exist yet.

## The two contracts, kept distinct

**Portable facades** (`hades/…`) are offered **only** where every supported OS has a real
counterpart. **Platform-scoped packages** (`hades/windows`, `hades/darwin`, `hades/linux`) are
for everything else, and they **fail loudly off-platform — they never silently no-op.** A facade
that quietly does nothing is worse than no facade, because the caller cannot tell.

Six capabilities were tested against that bar. **Three failed**, which is the useful half:

| facade | | platform-scoped | |
|---|---|---|---|
| paths / known folders | delegates to UIOP | notifications | preconditions differ, silently |
| service / daemon lifecycle | the strongest case | clipboard | semantics differ, not the API |
| single-instance lock | `flock`, never a lock file | autostart | no counterpart when headless |

The pattern is worth more than the list: **the passes are service-shaped and the failures are
desktop/interactive.** The interactive surface is where the platforms genuinely disagree.

## What Hades is not

- **Not a Windows library.** Windows leads because it is hardest, not because Hades is about it.
- **Not the binding.** That is [`aion/windows`](../aion/docs/adr/0003-windows-platform-binding.md).
  `cons` calls `aion/windows/service` **directly** and never links Hades — putting the binding
  here would make a DAG member depend on a satellite.
- **Not a home for portable file formats.** OOXML is not Hades: a `.docx` reader has no OS
  binding and no platform difference. It belongs in aion, by precedent with `aion/csv`.

## Where it sits

**Off the dependency line entirely**, on hermes's terms: nothing in the DAG depends on Hades.
The only thing that does is a consuming application, which depends on it *alongside* the
frameworks rather than through them.

## The single-instance lock

`hades/single-instance` keeps a second copy of an app from running against the same data
directory. The operating system holds the lock for the process and releases it when the
process ends, however it ends, so a crash never locks the app out of its next start. On
Windows it is a `CreateFileW` handle with share mode 0; on Linux and macOS it is an `fcntl`
write lock. The file it is held on, `<directory>/<name>.lock`, holds nothing and is never
deleted.

```lisp
(hades/single-instance:with-single-instance ("wordcrafter" :on-busy (lambda () (uiop:quit 0)))
  (hyperion/desktop:run-app app ...))
```

The lock is scoped to a directory: by default the app's per-user data directory,
`(uiop:xdg-data-home "<name>/")`, or `:directory`. `acquire-single-instance` returns a lock or
`:busy`, and `release-single-instance` releases it early. A second acquire from the same
process is `:busy` too. `hyperion/desktop:run-app` does not take the lock itself, because
nothing in the dependency line may depend on hades; the app takes it around `run-app`.
Handing the second launch's arguments to the first copy is not built yet (#305).

## The credential store

`hades/credentials` keeps a secret, such as a user's API key or database password, in the
operating system's own store, never in a file:

```lisp
(hades/credentials:store-credential "soloflow/anthropic-api-key" "default"
                                    (aion/secret:make-secret key))
(aion/secret:reveal (hades/credentials:fetch-credential "soloflow/anthropic-api-key" "default"))
(hades/credentials:delete-credential "soloflow/anthropic-api-key" "default")
```

`fetch-credential` returns an `aion/secret`, which prints as `#<SECRET REDACTED>`, and signals
`credential-not-found` when nothing is stored. No condition or log line carries the value. On
Windows the store is Credential Manager, per user and encrypted by DPAPI; on macOS, the login
Keychain; on Linux, the Secret Service that GNOME Keyring or KeePassXC provides over D-Bus,
reached through libsecret, which must be installed (`libsecret-1-0` on Debian and Ubuntu). Where
no store can be used (libsecret missing, no D-Bus session bus, nothing providing the Secret
Service) every call signals `credential-store-unavailable` with the reason, rather than storing
anywhere else (#357). A locked keyring may be unlocked by asking the user on a desktop; without a
display, or when the user dismisses the request, the call signals `credential-store-unavailable`
too.

## A notice before the app has a window

`hades/notify:notify-user` shows a blocking, modal notice with one OK button, and needs no window
of the app's own. The case it was written for is a second launch, which on macOS and on a Linux
desktop has no console, so a message on standard error reaches nobody:

```lisp
(hades/single-instance:with-single-instance
    ("wordcrafter" :on-busy (lambda ()
                              (hades/notify:notify-user "Wordcrafter" "Wordcrafter is already running.")
                              (uiop:quit 0)))
  (hyperion/desktop:run-app app ...))
```

| | shows the notice with | writes to standard error instead when |
|---|---|---|
| Windows | `MessageBoxW` | the process is in session 0, where services run |
| macOS | `/usr/bin/osascript` and `display alert`; no permission prompt | |
| Linux | `zenity`, else `kdialog`, from `PATH` | neither `DISPLAY` nor `WAYLAND_DISPLAY` is set, or neither program is installed |

On every system it also writes to standard error when `CI` is set, in an SSH session
(`SSH_CONNECTION` or `SSH_TTY`), when the native notice fails, and when
`hades/notify:*notify-backend*` is `:stderr`, which an app binds under `--self-test`. In none of
those cases does it wait. It returns `:native` or `:stderr`, with the reason for `:stderr` as a
second value (`:requested`, `:ci`, `:ssh`, `:session-0`, `:no-display`, `:no-program` or
`:failed`), so the caller can tell that nobody saw a dialog. The text is passed to `osascript`,
`zenity` and `kdialog` as program arguments, never through a shell or into a script; `zenity` gets
`--no-markup`. `kdialog` shows text that looks like HTML as rich text.

The tests check each platform's decision on every platform without showing a window.
`(hades/notify/tests:run-native-tests)` shows one real notice per level, by hand at a screen
(#819).

## Show a path in the file manager, open a URL in the browser

`hades/open:reveal-path` is the "Show in folder" and "Open data directory" action, and
`hades/open:open-url` opens a web page in the default browser:

```lisp
(hades/open:reveal-path #p"/Users/me/Documents/report.pdf" :select t) ; the folder, with the file selected
(hades/open:reveal-path (uiop:xdg-data-home "wordcrafter/"))          ; the folder itself
(hades/open:open-url "https://codelisperer.com/")
```

| | `reveal-path` | `reveal-path :select t` | `open-url` |
|---|---|---|---|
| Windows | `ShellExecuteW` on the directory | `explorer.exe /select,"<path>"` | `ShellExecuteW` on the URL |
| macOS | `open -R <path>` | `open -R <path>` | `open <url>` |
| Linux | `xdg-open <directory>` | `ShowItems` over D-Bus with `dbus-send`, else `xdg-open <directory>` | `xdg-open <url>` |

No shell is involved. On macOS and Linux each program gets the path or URL as one argument.
`explorer.exe` reads its command line by its own rules and splits `/select` at commas, so
`reveal-path` writes that command line itself, with the path in double quotes; Windows does not
allow `"` in a file name. `explorer.exe` is run from the Windows directory that
`GetSystemWindowsDirectoryW` reports, not from `PATH` or `SystemRoot`. On macOS `open -R` is used
with and without `:select`, because `open` on a directory that is an app bundle launches the app.
A string path is read as a native file name, and the path is made absolute first. Neither function waits for the file manager or the browser. Both return `:opened`, or
`:not-available` with the reason as a second value: `:no-display` (Linux with neither `DISPLAY`
nor `WAYLAND_DISPLAY`), `:no-program` (Linux without `xdg-open`) or `:failed` (the program did
not start). `reveal-path` signals `path-not-found` when nothing exists at the path. `open-url`
signals `unsupported-url` for anything but an http or https URL, because the same programs open
`file:` URLs and custom schemes, which start other programs, and for a URL with a character
RFC 3986 does not allow, such as a space, `"`, `<`, `>`, `\`, `^`, `|`, `{`, `}` or the backtick.
The condition's report does not print the URL, which can carry a token (#820).
