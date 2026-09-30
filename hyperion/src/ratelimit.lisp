;;;; ratelimit.lisp --- a rate limiter for authentication routes (#297).
;;;;
;;;; Sign-in, password reset and sign-up are the routes an attacker repeats: guessing a
;;;; password, or making the app send mail. WRAP-RATE-LIMIT refuses a request with 429 and
;;;; Retry-After once a LIMIT's bucket for that request's key is empty.
;;;;
;;;; THE ALGORITHM is a token bucket per (limit, key). A bucket holds up to CAPACITY tokens
;;;; and refills at CAPACITY tokens per PER seconds, continuously rather than in steps. Each
;;;; request takes one token; a request that finds less than one is refused, and Retry-After
;;;; is the time until one token has refilled. So `:capacity 5 :per 60' allows a burst of 5
;;;; and then one more every 12 seconds.
;;;;
;;;; KEYS. A limit's KEY is a function of the env returning a string, or NIL when the limit
;;;; does not apply to that request. BY-ADDRESS keys on the client address; BY-FORM-FIELD
;;;; keys on a submitted field such as the email address. Use both on a sign-in route: the
;;;; address limit stops one client trying many accounts, and the account limit stops many
;;;; clients trying one account.
;;;;
;;;; AN ACCOUNT-KEYED LIMIT DOES NOT REVEAL WHETHER THE ACCOUNT EXISTS. The key is the
;;;; submitted identifier, normalised, and the limiter never looks at the account store, so
;;;; an address that has no account is limited exactly like one that has. The refusal is the
;;;; same response whatever the key was.
;;;;
;;;; A LIMIT THAT COUNTS ONLY SOME REQUESTS (#323). By default every request a limit applies to
;;;; takes a token before the handler runs. A limit made with :COUNT-WHEN instead checks, before
;;;; the handler, that a token is available, and takes one after the handler only when
;;;; COUNT-WHEN says the response should count, such as a failed sign-in. Members of a club
;;;; signing in together from one network then cost nothing, and failed guesses from that
;;;; network are still limited.
;;;;
;;;; STORAGE is a protocol, TAKE-TOKEN, CHECK-TOKEN, DEBIT-TOKEN and FORGET-BUCKET, so a
;;;; deployment with several processes can keep buckets in a shared store. MEMORY-STORE is the default and is right
;;;; for one process. It bounds how many buckets it keeps (MAX-KEYS): an attacker who sends
;;;; a new email address with every request would otherwise grow it without limit.
;;;;
;;;; THE CLIENT ADDRESS is the env's :REMOTE-ADDR, the peer of the TCP connection. Behind a
;;;; reverse proxy every request has the proxy's address, so an address limit becomes one
;;;; bucket for everybody. An app behind a proxy passes its own KEY function that reads the
;;;; address the proxy reports, and only when it trusts that proxy to set the header.

(in-package #:hyperion/ratelimit)

;;; --- the clock --------------------------------------------------------------

(defparameter *clock-ms*
  (lambda ()
    (values (floor (* 1000 (get-internal-real-time)) internal-time-units-per-second)))
  "How the current time in milliseconds is obtained. Rebind it to drive the limiter in a
test without sleeping.")

(defun %now () (funcall *clock-ms*))

;;; --- limits -----------------------------------------------------------------

(defstruct (limit (:constructor %make-limit))
  (name nil :read-only t)
  (capacity 0 :read-only t)
  (per 0 :read-only t)
  (key nil :read-only t)
  (paths nil :read-only t)
  (methods nil :read-only t)
  (count-when nil :read-only t))

(defun make-limit (name &key capacity per key paths (methods '(:post)) count-when)
  "A limit named NAME (a keyword, used in logs and as part of the bucket key): at most
CAPACITY requests at once, refilling at CAPACITY per PER seconds, counted per value of KEY.

KEY is a function of the env returning a string, or NIL when this limit does not apply to
the request. PATHS is a list of exact PATH-INFO strings the limit applies to; NIL means
every path. METHODS defaults to (:POST), since a sign-in or reset is a POST and counting the
GET that renders its form would lock a user out for reloading the page.

COUNT-WHEN, when given, is a function of the env and the response that says whether this
request counts against the limit, for example (UNLESS-STATUS 303) on a sign-in route whose
successful sign-in redirects with 303 (#323). Before the handler runs, the request is refused
only if the bucket is already empty; after it, a token is taken only when COUNT-WHEN returns
true. A handler that signals instead of returning a response is counted, since the limiter
cannot tell that it succeeded. Without COUNT-WHEN every request takes a token before the
handler runs.

What COUNT-WHEN costs: several requests that arrive while the bucket still has a token all
pass the check before any of them is counted. Each is counted afterwards all the same, and the
bucket goes below empty to pay for them, which makes the wait before the next accepted request
longer by the same amount. The overdraft needs no cap: only requests that passed the check
while a token was left can add to it."
  (unless (and (integerp capacity) (plusp capacity))
    (error "make-limit ~S: CAPACITY must be a positive integer, not ~S." name capacity))
  (unless (and (realp per) (plusp per))
    (error "make-limit ~S: PER must be a positive number of seconds, not ~S." name per))
  (unless (functionp key)
    (error "make-limit ~S: KEY must be a function of the env, such as (by-address) or (by-form-field \"email\")." name))
  (unless (or (null count-when) (functionp count-when))
    (error "make-limit ~S: COUNT-WHEN must be a function of the env and the response, such as (unless-status 303), not ~S." name count-when))
  (%make-limit :name name :capacity capacity :per per :key key
               :paths (copy-list paths) :methods (copy-list methods)
               :count-when count-when))

(defun unless-status (&rest statuses)
  "A COUNT-WHEN function that counts a request unless its response's status is one of
STATUSES. On a sign-in route that redirects after a successful sign-in,
(UNLESS-STATUS 302 303) counts every attempt that did not sign in."
  (lambda (env response)
    (declare (ignore env))
    (not (and (consp response) (member (first response) statuses)))))

(defun %refill-ms (limit)
  "Milliseconds for one token to refill."
  (/ (* 1000 (limit-per limit)) (limit-capacity limit)))

(defun %applies-p (limit env)
  (and (member (getf env :request-method) (limit-methods limit))
       (or (null (limit-paths limit))
           (member (or (getf env :path-info) "") (limit-paths limit) :test #'string=))))

;;; --- keys -------------------------------------------------------------------

(defun by-address ()
  "A KEY function returning the client address, :REMOTE-ADDR. See this file's header for
why that is the wrong key behind a reverse proxy."
  (lambda (env)
    (let ((addr (getf env :remote-addr)))
      (and addr (princ-to-string addr)))))

(defun normalise-identifier (value)
  "VALUE trimmed of whitespace and lowercased, so `Bob@X.test ' and `bob@x.test' share a
bucket. NIL for NIL or an empty string."
  (let ((v (and value (string-downcase (string-trim '(#\Space #\Tab #\Newline #\Return) value)))))
    (and v (plusp (length v)) v)))

(defun by-form-field (name)
  "A KEY function returning the submitted form field NAME, normalised with
NORMALISE-IDENTIFIER, or NIL when the request does not carry it. Reads a urlencoded or
multipart body; WRAP-RATE-LIMIT caches the body first so the handler can still read it."
  (lambda (env)
    (normalise-identifier
     (if (http:multipart-p env)
         (let ((parts (getf env http:+multipart-parts-key+)))
           (and (listp parts) parts (http:multipart-param parts name)))
         (http:form-param (http:body-string env) name)))))

;;; --- storage ----------------------------------------------------------------

(defgeneric take-token (store bucket-key capacity refill-ms now-ms)
  (:documentation
   "Take one token from the bucket BUCKET-KEY in STORE, refilling it first for the time
since it was last touched. A new bucket starts full. Returns T, or NIL and the milliseconds
until a token will be available. CAPACITY and REFILL-MS describe the bucket; NOW-MS is the
current time. Must be atomic per bucket: the check and the take are one step.

Used for a limit without COUNT-WHEN. A limit with COUNT-WHEN uses CHECK-TOKEN before the
handler and DEBIT-TOKEN after it instead, so a store must implement all three."))

(defgeneric check-token (store bucket-key capacity refill-ms now-ms)
  (:documentation
   "Whether the bucket BUCKET-KEY in STORE has a token, after refilling it for the time since
it was last touched, without taking one. Returns T, or NIL and the milliseconds until a token
will be available. A bucket that does not exist counts as full, and checking must not create
it: a check happens on every request, including ones that will never be counted."))

(defgeneric debit-token (store bucket-key capacity refill-ms now-ms)
  (:documentation
   "Take one token from the bucket BUCKET-KEY in STORE whether or not one is available,
refilling it first. A new bucket starts full. The count may go below zero, with no lower
bound, so every request that passed CHECK-TOKEN is counted, even when others emptied the
bucket between its check and its debit. Must be atomic per bucket. The return value is not
used."))

(defgeneric forget-bucket (store bucket-key)
  (:documentation "Remove the bucket BUCKET-KEY from STORE, so its next request starts full."))

(defclass memory-store ()
  ((buckets :initform (make-hash-table :test #'equal) :reader %buckets)
   (lock :initform (bt:make-lock "hyperion-ratelimit") :reader %lock)
   (max-keys :initarg :max-keys :reader memory-store-max-keys)
   (sweeps :initform 0 :accessor %sweeps
           :documentation "How many times the store has swept, for the test of how often."))
  (:documentation "Buckets in a hash table in this process. See MAKE-MEMORY-STORE."))

(defun make-memory-store (&key (max-keys 100000))
  "A MEMORY-STORE keeping at most about MAX-KEYS buckets.

When it holds more, it sweeps: it drops the buckets that have refilled completely, which
loses nothing, because a full bucket and a missing one behave the same, and then, if it
still holds more than nine tenths of MAX-KEYS, the buckets touched longest ago until it
holds nine tenths. Dropping a bucket that is not full lets that key start again with a full
bucket, so MAX-KEYS should be well above the number of keys a deployment sees within one
refill period.

A sweep reads every bucket and sorts them, so it must not run on every request. Sweeping
down to nine tenths means the next sweep is at least a tenth of MAX-KEYS new keys away,
which is what keeps a client that sends a new key with every request from making each of
its requests pay for a sort of the whole table."
  (unless (and (integerp max-keys) (plusp max-keys))
    (error "make-memory-store: MAX-KEYS must be a positive integer, not ~S." max-keys))
  (make-instance 'memory-store :max-keys max-keys))

;;; A bucket is a vector #(tokens last-ms capacity refill-ms). CAPACITY and REFILL-MS are
;;; kept so the sweep can tell whether a bucket has refilled without knowing its limit.

(defun %refilled (bucket now-ms)
  (min (aref bucket 2)
       (+ (aref bucket 0) (/ (max 0 (- now-ms (aref bucket 1))) (aref bucket 3)))))

(defun %sweep-target (max)
  "How many buckets a sweep leaves: nine tenths of MAX, and always fewer than MAX."
  (min (1- max) (floor (* 9 max) 10)))

(defun %sweep (store now-ms)
  "When STORE holds more than MAX-KEYS buckets, bring it down to %SWEEP-TARGET. Does nothing
otherwise, so it is cheap to call on every request. Called with the lock held."
  (let ((table (%buckets store))
        (max (memory-store-max-keys store)))
    (when (> (hash-table-count table) max)
      (incf (%sweeps store))
      (let ((target (max 0 (%sweep-target max))))
        (loop for k being the hash-keys of table using (hash-value b)
              when (>= (%refilled b now-ms) (aref b 2))
                collect k into full
              finally (dolist (k full) (remhash k table)))
        (when (> (hash-table-count table) target)
          (let ((by-age (sort (loop for k being the hash-keys of table using (hash-value b)
                                    collect (cons (aref b 1) k))
                              #'< :key #'car)))
            (loop repeat (- (hash-table-count table) target)
                  for (nil . k) in by-age
                  do (remhash k table))))))))

(defmethod take-token ((store memory-store) bucket-key capacity refill-ms now-ms)
  (bt:with-lock-held ((%lock store))
    (let* ((table (%buckets store))
           (bucket (or (gethash bucket-key table)
                       (setf (gethash bucket-key table)
                             (vector capacity now-ms capacity refill-ms))))
           (tokens (%refilled bucket now-ms)))
      (setf (aref bucket 1) now-ms)
      (multiple-value-prog1
          (if (>= tokens 1)
              (progn (setf (aref bucket 0) (- tokens 1)) t)
              (progn (setf (aref bucket 0) tokens)
                     (values nil (ceiling (* (- 1 tokens) refill-ms)))))
        (%sweep store now-ms)))))

(defmethod check-token ((store memory-store) bucket-key capacity refill-ms now-ms)
  (declare (ignore capacity))
  (bt:with-lock-held ((%lock store))
    (let ((bucket (gethash bucket-key (%buckets store))))
      (if (null bucket)
          t
          (let ((tokens (%refilled bucket now-ms)))
            (if (>= tokens 1)
                t
                (values nil (ceiling (* (- 1 tokens) refill-ms)))))))))

(defmethod debit-token ((store memory-store) bucket-key capacity refill-ms now-ms)
  (bt:with-lock-held ((%lock store))
    (let* ((table (%buckets store))
           (bucket (or (gethash bucket-key table)
                       (setf (gethash bucket-key table)
                             (vector capacity now-ms capacity refill-ms)))))
      (setf (aref bucket 0) (- (%refilled bucket now-ms) 1)
            (aref bucket 1) now-ms)
      (%sweep store now-ms)
      t)))

(defmethod forget-bucket ((store memory-store) bucket-key)
  (bt:with-lock-held ((%lock store))
    (remhash bucket-key (%buckets store))))

(defun memory-store-count (store)
  "How many buckets STORE holds."
  (bt:with-lock-held ((%lock store))
    (hash-table-count (%buckets store))))

(defun %bucket-key (limit key)
  (format nil "~A~C~A" (limit-name limit) (code-char 0) key))

(defun reset-limit (store limit key)
  "Forget LIMIT's bucket for KEY in STORE, so the next request with that key starts with a
full bucket. KEY is the string LIMIT's KEY function returns, e.g. a normalised email.

The usual call is after a successful sign-in, so a user who mistyped a password a few times
is not held back afterwards. Only reset the account's bucket, not the address's: resetting
the address bucket on success would let one client that owns a single account reset its own
limit between guesses at other accounts."
  (forget-bucket store (%bucket-key limit key)))

;;; --- the refusal ------------------------------------------------------------

(defun too-many-requests (env retry-after-seconds limit)
  "The default refusal: 429 with Retry-After in whole seconds. The body is the same for
every key, so it says nothing about which key was limited or whether an account exists."
  (declare (ignore env limit))
  (list 429
        (list :content-type "text/plain; charset=utf-8"
              :retry-after (princ-to-string retry-after-seconds))
        (list (format nil "Too many requests. Try again in ~D seconds." retry-after-seconds))))

;;; --- the limiter ------------------------------------------------------------

(defun %release-parts (env)
  "Delete the temp files a multipart parse spilled for ENV. Only on the refusal path, where
no handler runs to delete them; WRAP-CSRF gives the full reasoning."
  (let ((parts (getf env http:+multipart-parts-key+)))
    (when (and parts (listp parts))
      (ignore-errors (http:delete-parts parts)))))

(defun %refuse (env limit wait-ms on-limited)
  (let ((seconds (max 1 (ceiling wait-ms 1000))))
    (log:warn "ratelimit: refused"
              :limit (limit-name limit)
              :method (getf env :request-method)
              :path (getf env :path-info)
              :retry-after seconds)
    (%release-parts env)
    (funcall on-limited env seconds limit)))

(defun %counts-p (limit env response)
  "Whether RESPONSE counts against LIMIT, by its COUNT-WHEN. A COUNT-WHEN that signals counts
the request: the limiter errs toward counting an attempt it cannot judge."
  (handler-case (funcall (limit-count-when limit) env response)
    (error (e)
      (log:warn "ratelimit: count-when signalled, counting the request"
                :limit (limit-name limit) :condition (type-of e))
      t)))

(defun call-with-rate-limit (env handler &key limits store (on-limited #'too-many-requests))
  "Call HANDLER with ENV, unless the bucket of a limit in LIMITS that applies to ENV is empty;
then return ON-LIMITED's response instead. The limiter WRAP-RATE-LIMIT installs, as a function,
so an app can call it where it chooses: inside the bindings it makes for every request, for
example, so that ON-LIMITED builds its refusal with them in effect (#323).

STORE is required here, and must be the same store on every call, since it holds the buckets.
HANDLER is called with the env the limiter passes on, whose body has been read and cached when
a limit applies, and must use that env rather than the one it was given.

See WRAP-RATE-LIMIT for the order limits are taken in, and MAKE-LIMIT for COUNT-WHEN."
  (unless store
    (error "call-with-rate-limit: STORE is required, and must be the same store on every call."))
  (when (null limits)
    (error "call-with-rate-limit: LIMITS is empty, so nothing would be limited."))
  (let ((applicable (remove-if-not (lambda (l) (%applies-p l env)) limits)))
    (if (null applicable)
        (funcall handler env)
        (let ((env (csrf:with-cached-body env))
              (now (%now))
              (after '()))
          (dolist (limit applicable)
            (let ((key (funcall (limit-key limit) env)))
              (when key
                (let ((bucket (%bucket-key limit key)))
                  (multiple-value-bind (ok wait-ms)
                      (if (limit-count-when limit)
                          (check-token store bucket (limit-capacity limit) (%refill-ms limit) now)
                          (take-token store bucket (limit-capacity limit) (%refill-ms limit) now))
                    (unless ok
                      (return-from call-with-rate-limit
                        (%refuse env limit wait-ms on-limited)))
                    (when (limit-count-when limit)
                      (push (cons limit bucket) after)))))))
          (if (null after)
              (funcall handler env)
              (let ((response nil) (returned nil))
                (unwind-protect
                     (progn (setf response (funcall handler env)
                                  returned t)
                            response)
                  (let ((then (%now)))
                    (dolist (entry (reverse after))
                      (destructuring-bind (limit . bucket) entry
                        (when (or (not returned) (%counts-p limit env response))
                          (debit-token store bucket (limit-capacity limit)
                                       (%refill-ms limit) then))))))))))))

(defmacro with-rate-limit ((env-var env &rest options &key limits store on-limited) &body body)
  "Run BODY with ENV-VAR bound to the env CALL-WITH-RATE-LIMIT passes on, unless a limit
refuses ENV; BODY returns the response. OPTIONS are CALL-WITH-RATE-LIMIT's."
  (declare (ignore limits store on-limited))
  `(call-with-rate-limit ,env (lambda (,env-var) ,@body) ,@options))

;;; --- the middleware ---------------------------------------------------------

(defun wrap-rate-limit (app &key limits (store (make-memory-store))
                                 (on-limited #'too-many-requests))
  "Ring middleware refusing a request once the bucket of any LIMIT that applies to it is
empty. LIMITS is a list made with MAKE-LIMIT; STORE defaults to a new MEMORY-STORE.
ON-LIMITED is called with (env retry-after-seconds limit) and returns the response; it
defaults to TOO-MANY-REQUESTS.

Limits are taken in order and the first refusal stops the request, so a request refused by
the first limit takes no token from the later ones. The app is not called for a refused
request. When a limit applies, the body is read once and cached (HYPERION/CSRF's
WITH-CACHED-BODY), so a key read from a form field does not use up the body the handler
reads. A limit made with COUNT-WHEN is checked before the app and counted after it; see
MAKE-LIMIT.

ON-LIMITED runs where this middleware sits in the app's chain. An app that builds its
refusal with bindings it makes for every request puts this middleware inside the middleware
that makes them, or calls CALL-WITH-RATE-LIMIT itself (#323).

Each refusal is logged with the limit's name, method and path. The key is not logged,
because it is often an email address."
  (let ((limits (copy-list limits)))
    (when (null limits)
      (error "wrap-rate-limit: LIMITS is empty, so nothing would be limited."))
    (lambda (env)
      (call-with-rate-limit env app :limits limits :store store :on-limited on-limited))))
