# hyperion/notice

In-page notices, and htmx 2 error responses shown in them instead of dropped (#980). A notice tells
the user, on the page they are on, that something failed, needs attention, or worked. It is not
stored and does not follow the user to another page; the notification list in #792 is that.

The code is `hyperion/src/notice.lisp`, package `hyperion/notice`, in core `hyperion`.

## Writing a notice

```lisp
(notice-region)                         ; once per page, where notices should appear
(notice :error "The file was not saved because the disk is full. Free some space and save again.")
(notice-oob :success "The draft was saved.")   ; inside a response htmx swaps elsewhere
```

There are three severities. `:error` means something the user asked for did not happen.
`:warning` means it happened, or can still happen, but the user should know something first.
`:success` means it happened.

Write the message as one or two plain sentences: what happened, then what the user can do, if
anything. A success says what was done. Leave out error codes, a bare "Error!", and exclamation
marks. Where the notice appears and how it is styled already show its severity.

Each notice is a `div` with `data-hyperion-notice` set to its severity. It has the classes
`hyperion-notice` and `hyperion-notice-<severity>`, a `p` holding the message, and a button that
removes it. The app styles these classes; hyperion ships no stylesheet for them.

## The region

`notice-region` writes `div#hyperion-notices`, which holds two containers:

| Container | Attributes | Holds |
|---|---|---|
| `div#hyperion-notices-alert` | `role="alert" aria-live="assertive"` | `:error` notices |
| `div#hyperion-notices-status` | `role="status" aria-live="polite"` | `:warning` and `:success` notices |

A screen reader announces what is added to a live region that was already in the page, so the
containers are written with the page and stay empty until a notice arrives. The role and
`aria-live` are on the containers and not on each notice: some screen readers announce a live
region inside another live region twice.

`:notices` takes a list of `(severity message)` pairs to show when the page loads. The fixed texts
are `:notice/failed`, `:notice/unreachable` and `:notice/dismiss`. They come from `:locale` and
`:source` like the list component's text, in English when a key is missing.

## htmx error responses

htmx 2 does not swap a 4xx or 5xx response. Its default `htmx.config.responseHandling` has
`{code: "[45]..", swap: false, error: true}`. So a server that answers an htmx request with an
error and an explanation shows the user nothing, unless the app does something about it.

`notice-region` also writes a script, which listens for `htmx:beforeSwap`. When the status is 400
or more and htmx is not going to swap the response (`detail.shouldSwap` is false), the script does
one of two things:

- if the response holds notices, written by `notice`, they are added to the region;
- otherwise a notice with `:notice/failed` is added. This covers an empty body, or a server's whole
  HTML error page.

The script also listens for `htmx:sendError`, which htmx fires when no response arrived, and adds
`:notice/unreachable`.

So to explain an error to the user, return the notice as the body of the error response:

```lisp
(list 422 '(:content-type "text/html; charset=utf-8")
      (list (spinneret:with-html-string (notice :error "That name is taken. Choose another."))))
```

### Why an event listener and not `responseHandling`

`responseHandling` can send an error response to a target, but it has three limits:

- it swaps whatever the body is, so it cannot put a fixed message in place of an empty body or an
  error page;
- it cannot send an error and a warning to different containers;
- it is a single array, so setting it here would replace an app's own setting.

The listener acts only where htmx decided not to swap. An app that already swaps an error response
keeps that behaviour. This covers, for example, a 422 form re-rendered with its errors through its
own `responseHandling`, or its own `htmx:beforeSwap` listener that runs first and sets
`shouldSwap`.

### Turning it off

- `(notice-region :htmx-errors nil)` writes the region without the script.
- An element with `data-hyperion-notices="off"`, or inside one, is left to the app: its error
  responses are not shown in the region.
- For a Content-Security-Policy with nonces, pass `:nonce`. For one that allows scripts only from
  the app's origin or by hash, serve `(notices-script)` from a route or hash it, and pass
  `:htmx-errors nil`.

## There is no page shell

hyperion has no page shell that every page goes through. The default is therefore attached to
`notice-region`: a page that writes the region gets the script, and a page without the region is
unchanged.

## Tests

- `hyperion/tests`, suite `notice`: the markup, the containers' roles and `aria-live`, where each
  severity goes, the script and its opt-out, the nonce, and translation.
- `hyperion/assets/tests`, `the-notice-region-shows-htmx-error-responses-in-a-real-browser`: a page
  with the vendored htmx 2.0.11 and the region, run in a headless Chrome or Edge. It checks the six
  cases above:
  - a 422 notice;
  - a 500 error page;
  - a refused connection;
  - the opt-out;
  - an app's own swap;
  - a 200 with `notice-oob`.

  It skips where no browser is found. The GitHub runners for all three operating systems have
  Chrome.
