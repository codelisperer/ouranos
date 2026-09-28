# Rate limiting authentication routes

`hyperion/ratelimit` refuses a request with `429 Too Many Requests` and a `Retry-After` header
once a limit's token bucket for that request is empty (#297). It is meant for the routes an
attacker repeats: sign-in (guessing passwords), password reset and sign-up (making the app send
mail or create accounts).

## How a limit counts

A limit has a **capacity** and a **period**. `:capacity 5 :per 60` allows 5 requests at once,
then refills at 5 per 60 seconds, which is one more every 12 seconds. The refill is continuous,
so there is no moment when a whole window resets at once.

Each limit counts per **key**. The key is a function of the request:

- `(rl:by-address)` is the client address (`:remote-addr`, the peer of the TCP connection).
- `(rl:by-form-field "email")` is a submitted form field, trimmed and lowercased, so
  `Bob@Example.com ` and `bob@example.com` share a bucket. A request without the field is not
  counted by that limit.

A sign-in route wants both. The address limit stops one client trying many accounts; the
account limit stops many clients (a botnet) trying one account.

By default a limit counts only `POST`, so reloading the page that shows the form never locks
anyone out. `:paths` lists the exact paths the limit applies to.

## Counting only failed attempts

By default every request a limit applies to takes a token before the handler runs. On sign-in
that refuses people who did nothing wrong: members who sign in together from one network, such
as a meeting room's Wi-Fi, share one address and use up its bucket with successful sign-ins.

`:count-when` fixes that (#323). It is a function of the env and the response, and a request
counts only when it returns true:

```lisp
(rl:make-limit :sign-in-address :capacity 10 :per 900 :key (rl:by-address)
               :paths '("/sign-in") :count-when (rl:unless-status 303))
```

`(rl:unless-status 303)` counts every sign-in whose response is not a 303, the redirect a
successful sign-in answers with. Before the handler runs, the request is refused only if the
bucket is already empty. After it, a token is taken only for a counted response. A successful
sign-in leaves the bucket as it was: it neither takes a token nor gives one back, so it cannot
be used to clear failures. A handler that signals is counted, because the limiter cannot tell
it succeeded.

Requests that arrive together can all pass the check before any of them is counted. Each is
still counted when it finishes, and the bucket may go below empty to pay for them, down to
minus its capacity, so the wait before the next accepted request grows by the same amount.

**An account limit does not reveal whether an account exists.** The key is whatever was
submitted, and the limiter never reads the account store, so an address with no account is
limited exactly like one with an account, and the 429 response is identical for both.

## Recipe: guarding sign-in, reset and sign-up with `hyperion/auth-db`

```lisp
(defpackage #:my-app
  (:use #:cl)
  (:local-nicknames (#:rl #:hyperion/ratelimit)
                    (#:auth #:hyperion/auth-db)
                    (#:session #:hyperion/session)
                    (#:csrf #:hyperion/csrf)
                    (#:http #:hyperion/http)))

(in-package #:my-app)

(defvar *limits* (rl:make-memory-store))

;; Sign-in: 10 failed tries per address per 15 minutes, and 5 tries per account per 15
;; minutes. The address limit counts only failures, so members signing in from one network
;; are not refused; the handler redirects with 303 after a successful sign-in.
(defparameter +sign-in-by-address+
  (rl:make-limit :sign-in-address :capacity 10 :per 900
                 :key (rl:by-address) :paths '("/sign-in")
                 :count-when (rl:unless-status 303)))
(defparameter +sign-in-by-account+
  (rl:make-limit :sign-in-account :capacity 5 :per 900
                 :key (rl:by-form-field "email") :paths '("/sign-in")))

;; Reset and sign-up send mail: 3 per address per hour, and 3 per account per hour.
(defparameter +mail-by-address+
  (rl:make-limit :mail-address :capacity 3 :per 3600
                 :key (rl:by-address) :paths '("/reset-password" "/sign-up")))
(defparameter +mail-by-account+
  (rl:make-limit :mail-account :capacity 3 :per 3600
                 :key (rl:by-form-field "email") :paths '("/reset-password" "/sign-up")))

;; Outermost first: the session, then the limiter, then the CSRF check, then the routes.
(defun make-app (router session-store)
  (session:wrap-session
   (rl:wrap-rate-limit (csrf:wrap-csrf router)
                       :limits (list +sign-in-by-address+ +sign-in-by-account+
                                     +mail-by-address+ +mail-by-account+)
                       :store *limits*)
   session-store))

;; In the sign-in handler, after a successful AUTH:AUTHENTICATE, give the account a full
;; bucket again so a user who mistyped a few times is not held back afterwards. Reset only
;; the ACCOUNT limit: resetting the address limit on success would let a client that owns
;; one account reset its own limit between guesses at other accounts.
(defun on-signed-in (email)
  (rl:reset-limit *limits* +sign-in-by-account+ (rl:normalise-identifier email)))
```

## Building the refusal inside the app's own bindings

`:on-limited` is called with `(env retry-after-seconds limit)` and returns the refusal. It runs
where the limiter sits. An app that binds something for every request, such as its locale or
its page layout, and wants the refusal built with it, has two ways to get that:

- Put `wrap-rate-limit` inside the middleware that makes the bindings.
- Call the limiter itself, inside the bindings, with `rl:call-with-rate-limit` or
  `rl:with-rate-limit`. Both take the same `:limits`, `:store` and `:on-limited`, and the
  store is required, since it must be the same store on every call:

  ```lisp
  (rl:with-rate-limit (env env :limits *sign-in-limits* :store *limits*
                               :on-limited #'my-refusal)
    (handle-sign-in env))   ; use the ENV the limiter passes on: its body has been read
  ```

The limiter goes **outside** `wrap-csrf`, as above, so a flood of requests is refused before
the CSRF check reads their bodies, and inside `wrap-session`, which `wrap-csrf` needs. It reads a form field through
`hyperion/csrf:with-cached-body`, so the handler can still read the body afterwards.

Every limit in one `wrap-rate-limit` shares the store, and a limit's name is part of each bucket's
key, so give every limit its own name.

## Behind a reverse proxy

Behind a proxy, `:remote-addr` is the proxy's address for every request, so `by-address` puts
everyone in one bucket. Pass a key function that reads the address the proxy reports, and only
if the app trusts that proxy to set the header; a client can put any value in a header the
proxy does not overwrite.

```lisp
(rl:make-limit :sign-in-address :capacity 10 :per 300 :paths '("/sign-in")
               :key (lambda (env) (http:request-header env "x-real-ip")))
```

## Storage

`make-memory-store` keeps buckets in this process and is right for one process. It keeps at
most `:max-keys` buckets (default 100,000). Past that it first drops buckets that have refilled
completely, which changes nothing, and then the ones touched longest ago, which gives those keys
a full bucket again. Keep `:max-keys` well above the number of keys the app sees within one
refill period.

Several processes behind a load balancer each have their own memory store, so each allows the
full capacity. A shared store implements four generic functions; see their docstrings:

- `rl:take-token` checks and takes a token in one atomic step, for a limit without `:count-when`.
- `rl:check-token` says whether a token is available without taking one or creating a bucket,
  and `rl:debit-token` takes one whether or not it is available. A limit with `:count-when`
  uses these, before and after the handler.
- `rl:forget-bucket` removes a bucket, for `rl:reset-limit`.

A database-backed store is not written yet (#307).

## Testing

`rl:*clock-ms*` is the clock, in milliseconds. Bind it to a function returning a variable and
advance the variable, as `hyperion/tests/ratelimit-tests.lisp` does, rather than sleeping.
