;;;; feed.lisp --- latest-value-per-key, delivered at a subscription's rate (ADR-0016)
;;;;
;;;; The back-pressure primitive for server->client streams. A FEED holds the LATEST value
;;;; per key and nothing else; a SUBSCRIPTION declares how often it wants to hear. A slow
;;;; consumer therefore gets FEWER UPDATES, never a backlog -- which is the whole decision,
;;;; because the alternative fails as a silently growing queue that presents as a slow
;;;; browser and sends you looking at the wrong component.
;;;;
;;;; NOT hyperion/channel, and the two are easy to reach for interchangeably:
;;;;
;;;;   channel -- every reader sees EVERY item. An append-only log. Right for a chat
;;;;              transcript, an audit trail, anything where a skipped value is a defect.
;;;;              It never trims, so its memory is the number of items published.
;;;;   feed    -- every reader sees the LATEST item per key. Right for prices, progress,
;;;;              positions, presence -- anything where an intermediate value has no
;;;;              standing once superseded. Memory is the number of distinct KEYS.
;;;;
;;;; Choosing wrongly fails silently in both directions: a lost intermediate value, or
;;;; unbounded memory. So each names the other, here and in channel.lisp.
;;;;
;;;; INTERMEDIATE VALUES ARE LOST, BY DESIGN. Publishing a key twice between two TAKEs
;;;; leaves the second. That is coalescing, and it is the data structure rather than a
;;;; policy layered on one: there is nowhere for a skipped value to be, so there is no
;;;; queue to grow.
;;;;
;;;; ONE THING THIS DOES NOT SOLVE, stated rather than half-built: a key is never removed,
;;;; so memory is bounded by the number of keys EVER published, not the number currently
;;;; live. For a fixed key space -- 30 symbols, a set of job ids, a room's occupants --
;;;; that is the bound ADR-0016 claims. For an unbounded key space it is not, and the
;;;; missing piece is not a REMOVE function but a way to DELIVER a removal to subscribers
;;;; that have not seen it. A remove that subscribers cannot observe is a worse gap than
;;;; no remove at all, so there is none.

(cl:in-package #:hyperion/feed)

;;; --- the clock, injectable because a rate limiter is untestable without it -----------
;;;
;;; Effects at the edges: everything below reads the time through *CLOCK-MS* rather than
;;; calling GET-INTERNAL-REAL-TIME, so a test can drive a rate limiter deterministically
;;; instead of sleeping and hoping. A suite that sleeps is slow AND flaky, and the flake
;;; arrives on someone else's loaded machine rather than here.

(defparameter *clock-ms*
  (lambda ()
    (values (floor (* 1000 (get-internal-real-time)) internal-time-units-per-second)))
  "How the current time in milliseconds is obtained. Rebind to drive rate limiting in a
test; the default is a monotonic-ish real-time clock.")

(declaim (inline %now))
(defun %now () (funcall *clock-ms*))

;;; --- the feed ------------------------------------------------------------------------

(defstruct (feed (:constructor %make-feed) (:conc-name feed-))
  "The latest value per key, plus a monotonically increasing VERSION.

The version is what makes 'what changed since you last looked' answerable without keeping a
per-subscriber queue: each entry records the version at which it was written, each
subscription remembers the version it last saw, and the difference is computed on read. So
a subscriber costs one integer, whatever the publish rate."
  (entries (make-hash-table :test 'equal))
  (version 0 :type unsigned-byte)
  (lock (bt:make-lock "hyperion-feed")))

(defun make-feed ()
  "A fresh, empty feed."
  (%make-feed))

(defun publish (feed key value)
  "Set KEY's latest value in FEED to VALUE; return the feed's new version.

Publishing the same key again before any subscriber reads REPLACES the value. Nothing
accumulates and nothing is dropped-on-the-floor -- there was never a second slot."
  (bt:with-lock-held ((feed-lock feed))
    (let ((v (incf (feed-version feed))))
      (setf (gethash key (feed-entries feed)) (cons v value))
      v)))

(defun feed-version-now (feed)
  "FEED's current version -- the number of publishes it has accepted."
  (bt:with-lock-held ((feed-lock feed)) (feed-version feed)))

(defun feed-ref (feed key &optional default)
  "The latest value under KEY in FEED, or DEFAULT."
  (bt:with-lock-held ((feed-lock feed))
    (let ((e (gethash key (feed-entries feed))))
      (if e (cdr e) default))))

(defun feed-count (feed)
  "How many distinct keys FEED holds -- its whole memory footprint, by design."
  (bt:with-lock-held ((feed-lock feed)) (hash-table-count (feed-entries feed))))

(defun feed-alist (feed)
  "Every key and its latest value, as an alist. Order unspecified."
  (bt:with-lock-held ((feed-lock feed))
    (loop for k being the hash-keys of (feed-entries feed) using (hash-value e)
          collect (cons k (cdr e)))))

;;; --- subscriptions -------------------------------------------------------------------

(define-condition rate-required (error)
  ()
  (:report (lambda (c stream)
             (declare (ignore c))
             (format stream "hyperion/feed: SUBSCRIBE needs :HZ. A subscription that ~
declares no rate is an unthrottled one, which is the shape ADR-0016 exists to refuse -- ~
pass a large :HZ if you genuinely want every change as fast as you can take it.")))
  (:documentation
   "Signalled when SUBSCRIBE is called without a rate. There is deliberately no default:
an omitted rate would silently reproduce the unbounded case the ADR rejects, and a default
is exactly how a policy nobody chose becomes the one in production."))

(defstruct (subscription (:constructor %make-subscription) (:conc-name subscription-))
  "One reader's view of a feed: where it has read up to, and how often it wants to hear."
  (feed nil)
  (seen 0 :type unsigned-byte)
  (interval-ms 0 :type unsigned-byte)
  (next-at 0 :type unsigned-byte))

(defun subscribe (feed &key hz (from :start))
  "A SUBSCRIPTION to FEED emitting at most HZ times per second.

HZ IS REQUIRED. See the RATE-REQUIRED condition for why there is no default.

FROM is :START -- the current snapshot arrives on the first TAKE, which is what a browser
connecting to a live view wants -- or :END, meaning only what changes after now. The two
keywords are `channel''s, and mean the same thing there: everything this primitive holds,
or nothing yet. The DEFAULT differs (channel defaults to :END) because a log's history is
usually not wanted on connect and a snapshot of current state usually is."
  (unless (and hz (realp hz) (plusp hz)) (error 'rate-required))
  (%make-subscription
   :feed feed
   :seen (ecase from (:start 0) (:end (feed-version-now feed)))
   :interval-ms (max 1 (round 1000 hz))
   :next-at 0))

(defun take (subscription)
  "Return (values CHANGES READY-P): the (key . value) pairs that changed since this
subscription last emitted, and whether the rate allowed an emission at all.

Three outcomes, and they are three because a caller must be able to tell them apart:

  (nil   nil)  too soon -- the rate said no. Wait; do not send anything.
  (nil   t)    allowed, but nothing changed. Idle: a good moment for a keep-alive.
  (pairs t)    allowed, and here is the coalesced change set.

THE CLOCK ONLY ADVANCES ON AN ACTUAL EMISSION. An idle feed does not accumulate a debt of
missed intervals, so the first change after a quiet period goes out immediately rather than
waiting out a window that bought nothing. A rate limits how often you MAY speak, not how
often you must."
  (let* ((feed (subscription-feed subscription))
         (now (%now)))
    (if (< now (subscription-next-at subscription))
        (values nil nil)
        (let ((changes
                (bt:with-lock-held ((feed-lock feed))
                  (let ((seen (subscription-seen subscription)))
                    (prog1 (loop for k being the hash-keys of (feed-entries feed)
                                   using (hash-value e)
                                 when (> (car e) seen) collect (cons k (cdr e)))
                      (setf (subscription-seen subscription) (feed-version feed)))))))
          (when changes
            (setf (subscription-next-at subscription)
                  (+ now (subscription-interval-ms subscription))))
          (values changes t)))))

(defun subscription-hz (subscription)
  "The rate SUBSCRIPTION was created with, as emissions per second."
  (/ 1000 (subscription-interval-ms subscription)))
