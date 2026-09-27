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

;; Sign-in: 10 tries per address per 5 minutes, and 5 per account per 15 minutes.
(defparameter +sign-in-by-address+
  (rl:make-limit :sign-in-address :capacity 10 :per 300
                 :key (rl:by-address) :paths '("/sign-in")))
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
full capacity. A shared store implements two generic functions, `rl:take-token` and
`rl:forget-bucket`; see their docstrings. A database-backed store is not written yet.

## Testing

`rl:*clock-ms*` is the clock, in milliseconds. Bind it to a function returning a variable and
advance the variable, as `hyperion/tests/ratelimit-tests.lisp` does, rather than sleeping.
