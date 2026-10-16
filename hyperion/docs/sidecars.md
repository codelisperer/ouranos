# Dev sidecars

A dev sidecar is a program an app needs running next to its development server, and only while
that server runs. Examples are the Stripe CLI's webhook forwarder, a local mail catcher, a tunnel
and an asset watcher. `hyperion/sidecar` starts the sidecars an app names when the dev server
starts, gives the app any value a sidecar prints, and stops them when the dev server stops (#700).

Sidecars are for development only. `hyperion/dev:serve`, `hyperion/dev:watch` and
`hyperion/desktop:run-app` take a `:sidecars` argument. `hyperion/server:serve-forever`, which a
production server runs, does not, and a shipped desktop image ignores the argument with a warning.

## Worked example: the Stripe CLI webhook forwarder

`stripe listen --forward-to <url>` receives your Stripe account's test-mode events and posts each
one to `<url>`. When it starts it prints a line like this:

```
> Ready! Your webhook signing secret is whsec_1a2b3c... (^C to quit)
```

Stripe signs the forwarded events with that secret, not with the endpoint secret shown in the
dashboard. So during development the app must verify webhooks with the secret this run of the
forwarder printed.

### Declare the sidecar

```lisp
(hyperion/sidecar:define-sidecar :stripe
  :command '("stripe" "listen" "--forward-to" "localhost:{port}/webhooks/stripe")
  :environment `(("STRIPE_API_KEY" . ,(uiop:getenv "STRIPE_TEST_SECRET_KEY")))
  :ready (hyperion/sidecar:token-after "webhook signing secret is ")
  :ready-timeout 30
  :secret t)
```

- `:command` is the program and its arguments. `{port}` is replaced with the port the dev server
  actually bound, so this works when the port comes from configuration or is chosen when the
  server starts.
- `:environment` is added to the image's environment. Here it passes a test-mode key. Without it
  the Stripe CLI uses the account from `stripe login`. Names and values must be strings, so the
  declaration signals an error when `STRIPE_TEST_SECRET_KEY` is not set, rather than passing a
  wrong value.
- `:ready` is a function of one line of the sidecar's output (standard output or standard
  error) that returns the value to capture, or NIL. `token-after` returns the text after the
  marker up to the next space. Any function of a line works.
- `:secret t` keeps the captured value as an `aion/secret`, which prints as
  `#<SECRET REDACTED>`.

Put the declaration in the file that defines the app's dev entry point. Declaring the same name
again replaces the declaration.

### Start it with the dev server

```lisp
(hyperion/dev:serve #'make-app :system "my-app" :port 4242 :sidecars '(:stripe))
```

The server binds its port first. Then the forwarder starts, and `serve` returns once it has
printed its secret. If it has not done so within `:ready-timeout` seconds, or it exits first,
the dev server is stopped and `hyperion/sidecar:sidecar-not-ready` is signalled with the
sidecar's name and the reason.

### Verify webhooks with the forwarder's secret

```lisp
(defun stripe-webhook-secret ()
  "The secret to verify Stripe webhooks with: the forwarder's during development, the
configured one otherwise."
  (let ((dev (hyperion/sidecar:sidecar-value :stripe)))
    (if dev
        (aion/secret:reveal dev)
        (config-value :stripe-webhook-secret))))
```

`sidecar-value` returns NIL when the sidecar is not running, so the same code serves production.

### When the Stripe CLI is not installed

A developer without the `stripe` program on PATH gets the server and one warning in the log:

```
hyperion/sidecar: sidecar :stripe not started: stripe not found on PATH
```

Declare the sidecar `:required t` to make that an error instead
(`hyperion/sidecar:sidecar-not-started`, reason `:not-found`).

## Lifecycle

- **Reloads.** The dev server restarts its listener on every reload. The sidecars keep running
  across those restarts. A sidecar whose command uses `{port}` is restarted only if the
  restarted server is on a different port.
- **Stopping.** `hyperion/dev:unwatch`, the end of a blocking `serve`, and the end of
  `run-app` stop the sidecars. On Linux and macOS a sidecar is sent SIGTERM, then SIGKILL after
  `hyperion/sidecar:*stop-seconds*` (2 by default). Each signal goes to the sidecar's process
  group, so a process it started is stopped too, unless that process made a process group of its
  own. On Windows its job object is terminated, which ends everything the sidecar started.
- **Exit hooks.** A normal image exit stops every sidecar still running.
- **Restarts.** A sidecar declared `:restart t` that exits by itself is started again after 1
  second, then 2, 4 and so on up to 30 seconds, without a limit on attempts. Each attempt is
  logged at warn. After a run that stayed up for a minute, the delay goes back to 1 second. Its
  `:ready` function runs again, and `sidecar-value` returns the new value once it is ready.
- **Status.** `(hyperion/sidecar:sidecar-status :stripe)` returns `:starting`, `:ready`,
  `:exited` or `:not-started`, and the exit code as a second value. It never returns the
  captured value, so it is safe to show on a diagnostics page.

## When the image is killed

A killed image runs no exit hooks. What ends its sidecars depends on the operating system:

- **Windows.** Each sidecar is started suspended inside a kill-on-close job object, then
  resumed (`aion/windows:spawn-in-job`). Windows ends everything in the job, including processes
  the sidecar started, when the image ends for any reason. A sidecar that Windows cannot put in a
  job object is not started (`sidecar-not-started`, reason `:no-job`), because nothing else would
  end it. Sidecars run with no console window.
- **Linux.** Each sidecar is started through `setpriv --pdeathsig KILL` from util-linux, so the
  kernel kills it when the image goes away. Processes the sidecar itself starts are not covered.
  If `setpriv` is not installed, a warning is logged and the macOS method below is used, and a
  sidecar whose state file cannot be written is not started (reason `:no-state-file`).
- **macOS.** There is no equivalent mechanism. Each sidecar's pid and program are written to a
  file under `~/.cache/hyperion-sidecars/`. The next `start-sidecars`, in any image, ends a
  recorded sidecar whose image is no longer running and which still runs the recorded program,
  then deletes the record. So a sidecar left behind by a crash runs until the next dev server
  starts. The state files are written on Linux too.

## What is logged

Each sidecar's start, readiness, exit, exit code and restarts are logged through `aion/log` at
info or warn. At debug level each line of its output is logged by its length and stream, never its
text, because a sidecar's output can contain secrets; turn it on with `(aion/log:level! :debug)`
to see whether a sidecar is printing anything.
Conditions and log fields never include a sidecar's arguments or a captured value.

## Limits

- On Windows the program must be an `.exe` or `.com` file. Batch files (`.bat`, `.cmd`) are
  refused, because `cmd.exe` parses the arguments by different rules. Name the program the batch
  file runs instead.
- Readiness is read line by line. A program that prints its value without a newline is seen
  only when it prints one.
