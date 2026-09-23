;;;; money.lisp --- a typed amount, and the provider config (pre-publication issue 49).
;;;;
;;;; WHAT THIS ACTUALLY PREVENTS, stated precisely, because the ticket's phrasing promises
;;;; slightly more than is reachable.
;;;;
;;;; pre-publication issue 49 asks for Money/Currency "so amounts cannot mix units". A currency arrives at
;;;; RUNTIME, out of a provider's JSON -- so it cannot be in the type, and no amount of
;;;; Coalton makes a mismatch a compile-time error at that boundary. Phantom-typing the
;;;; currency would work only for amounts written as literals in our own source, which is
;;;; not where payment amounts come from.
;;;;
;;;; What IS reachable, and is what this delivers: an amount CARRIES its currency, and the
;;;; arithmetic REFUSES to combine two that disagree, returning None rather than a wrong
;;;; number. The difference from the two loose slots it replaces (`amount-minor` plus
;;;; `currency`) is that the pair can be separated, passed around half, or silently added to
;;;; a different pair, and a Money cannot. Mixing units stops being possible by accident and
;;;; becomes something you must explicitly discard a None to do.
;;;;
;;;; MINOR UNITS, ALWAYS. 1050, not 10.50. Floating-point money is a bug with a waiting
;;;; period, and providers speak minor units for the same reason. The type carries an
;;;; Integer and there is deliberately no constructor taking a float.

(cl:in-package #:hermes/payments/money)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  (define-type Currency
    "An ISO-4217 code, lower-cased -- the spelling providers use on the wire.

Not an enum. There are ~180 active codes and providers add settlement currencies without
asking us; a closed type would make an unrecognised currency a compile error in a library
that has no business having an opinion about which currencies exist."
    (Currency String))

  (declare currency-code (Currency -> String))
  (define (currency-code c) (match c ((Currency s) s)))

  (declare currency= (Currency * Currency -> Boolean))
  (define (currency= a b) (== (currency-code a) (currency-code b)))

  (define-type Money
    "An amount in MINOR UNITS, carrying its currency. 1050 usd is $10.50."
    (Money Integer Currency))

  (declare make-money (Integer * String -> Money))
  (define (make-money minor code)
    "MINOR units of CODE. The only constructor, and it takes an Integer -- there is
deliberately no float path."
    (Money minor (Currency code)))

  (declare money-minor (Money -> Integer))
  (define (money-minor m) (match m ((Money n _) n)))

  (declare money-currency (Money -> String))
  (define (money-currency m) (match m ((Money _ c) (currency-code c))))

  (declare money-zero? (Money -> Boolean))
  (define (money-zero? m) (== 0 (money-minor m)))

  ;;; --- arithmetic that refuses to lie ---------------------------------------
  ;;;
  ;;; None on a currency mismatch, never a coerced or assumed result. A caller must decide
  ;;; what a mismatch means -- and in a payments context there is no sane default, since the
  ;;; only honest conversion needs a rate this library does not have.

  (declare money+ (Money * Money -> (Optional Money)))
  (define (money+ a b)
    "The sum, or None if the currencies differ."
    (if (== (money-currency a) (money-currency b))
        (Some (make-money (+ (money-minor a) (money-minor b)) (money-currency a)))
        None))

  (declare money- (Money * Money -> (Optional Money)))
  (define (money- a b)
    "The difference, or None if the currencies differ. May be negative -- a refund larger
than a payment is a real state and not this type's business to forbid."
    (if (== (money-currency a) (money-currency b))
        (Some (make-money (- (money-minor a) (money-minor b)) (money-currency a)))
        None))

  (declare money= (Money * Money -> Boolean))
  (define (money= a b)
    "True when both the amount AND the currency match. 100 usd is not 100 eur, and is not
equal to it in any sense this library will endorse."
    (and (== (money-minor a) (money-minor b))
         (== (money-currency a) (money-currency b))))

  (declare money< (Money * Money -> (Optional Boolean)))
  (define (money< a b)
    "Ordering within one currency; None across currencies, because there is no order
between them without a rate."
    (if (== (money-currency a) (money-currency b))
        (Some (< (money-minor a) (money-minor b)))
        None))

  ;;; --- the CL boundary for Optional ----------------------------------------
  ;;;
  ;;; MONEY+ and friends return (Optional Money), which is the right type and is awkward
  ;;; from CL: the shell may not destructure a Coalton value, so it cannot ask None from
  ;;; Some by pattern-matching. These two are the total accessors that make the boundary
  ;;; usable -- ask whether it worked, then take the value with an explicit fallback.
  ;;;
  ;;; Deliberately no "just give me the value" accessor. An amount that silently became
  ;;; zero because two currencies disagreed is exactly the wrong number this type exists
  ;;; to prevent, so the caller has to name the fallback at the call site.

  (declare money-ok? ((Optional Money) -> Boolean))
  (define (money-ok? m)
    "True when an operation produced a value -- i.e. the currencies agreed."
    (match m ((Some _) True) ((None) False)))

  (declare money-or ((Optional Money) * Money -> Money))
  (define (money-or m fallback)
    "The value, or FALLBACK. The fallback is required rather than defaulted, so a currency
mismatch cannot quietly become zero."
    (match m ((Some v) v) ((None) fallback)))

  ;;; --- provider configuration ----------------------------------------------

  (define-type Config
    "What a hosted-checkout provider needs to be reachable: a key, a webhook secret, and
the API base. The two credentials are SECRETs, not Strings: Coalton prints a DEFINE-TYPE
field by field, so a String here would put an API key into any backtrace that unwound
through a frame holding this config -- the defect that reached a deploy log in pre-publication issue 209. The
API base is not a credential and stays printable, which is what makes a redacted config
still worth reading.

Three fields rather than an open map, because a map types nothing and this is the shape
every hosted-checkout provider has actually needed. A provider wanting more carries it on
its own class -- the neutral core does not grow a slot per vendor, which is the same rule
the event vocabulary follows."
    (Config sec:Secret sec:Secret String))

  (declare make-config (String * String * String -> Config))
  (define (make-config api-key webhook-secret api-base)
    "Takes plaintext -- credentials arrive as strings from the environment, so there is
nowhere else for them to come from. What matters is that they do not come back out
without REVEAL being written (pre-publication issue 209): a one-way valve, not an unbreakable one."
    (Config (sec:make-secret api-key) (sec:make-secret webhook-secret) api-base))

  (declare config-api-key (Config -> sec:Secret))
  (define (config-api-key c) (match c ((Config k _ _) k)))

  (declare config-webhook-secret (Config -> sec:Secret))
  (define (config-webhook-secret c) (match c ((Config _ s _) s)))

  (declare config-api-base (Config -> String))
  (define (config-api-base c) (match c ((Config _ _ b) b)))

  (declare config-complete? (Config -> Boolean))
  (define (config-complete? c)
    "True when nothing required is blank. The CL shell turns a False here into a
CONFIGURATION-ERROR at construction, so a missing key is found when the provider is built
rather than on the first charge."
    ;; Compared against the empty string rather than by length: Coalton's `length` is for
    ;; List, and a String is not one.
    ;;
    ;; REVEAL here is a disclosure the grep will find, and it is the right kind: the
    ;; plaintext is compared and discarded inside a pure function that returns a Boolean,
    ;; so nothing printable is produced. Emptiness is the one question about a credential
    ;; that can be answered without handling it.
    (and (not (== "" (sec:reveal (config-api-key c))))
         (not (== "" (sec:reveal (config-webhook-secret c)))))))
