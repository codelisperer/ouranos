;;;; feed-tests.lisp --- hyperion/feed (latest-per-key at a subscriber's rate, ADR-0016).

(in-package #:hyperion/tests)

(def-suite feed :in hyperion
  :description "Coalescing feed: latest value per key, rate-limited.")
(in-suite feed)

;;; A DRIVEN CLOCK, not sleeps. A rate limiter tested by sleeping is slow and flaky, and
;;; the flake shows up on someone else's loaded machine rather than here.
(defmacro with-clock ((now-var) &body body)
  "Run BODY with hyperion/feed's clock reading NOW-VAR, which BODY may SETF to travel."
  `(let* ((,now-var 0)
          (feed:*clock-ms* (lambda () ,now-var)))
     (declare (ignorable ,now-var))
     ,@body))

;;; --- coalescing is the data structure ------------------------------------
(test publishing-a-key-twice-leaves-one-value
  (with-clock (now)
    (let* ((f (feed:make-feed))
           (s (feed:subscribe f :hz 1000)))
      (feed:publish f "AAPL" 1)
      (feed:publish f "AAPL" 2)
      (feed:publish f "AAPL" 3)
      (is (= 1 (feed:feed-count f)) "three publishes, one key, one slot")
      (multiple-value-bind (changes ready) (feed:take s)
        (is-true ready)
        (is (equal '(("AAPL" . 3)) changes)
            "the subscriber sees the LATEST, and there is nowhere the other two could be")))))

(test memory-is-keys-not-updates
  ;; The property ADR-0016 actually claims. 3 keys, 3000 publishes.
  (with-clock (now)
    (let ((f (feed:make-feed)))
      (dotimes (i 1000)
        (feed:publish f "a" i) (feed:publish f "b" i) (feed:publish f "c" i))
      (is (= 3 (feed:feed-count f)))
      (is (= 3000 (feed:feed-version-now f)) "every publish was accepted -- none was dropped"))))

(test a-slow-consumer-gets-fewer-updates-not-a-backlog
  ;; The whole decision, as one test. A 1 Hz subscriber against a fast publisher must
  ;; receive ONE coalesced entry per key per second -- not a queue of everything it missed.
  (with-clock (now)
    (let* ((f (feed:make-feed))
           (s (feed:subscribe f :hz 1)))
      (feed:publish f "x" :first)
      (multiple-value-bind (changes ready) (feed:take s)
        (is-true ready)
        (is (equal '(("x" . :first)) changes)))
      (dotimes (i 500) (feed:publish f "x" i))     ; a burst, while the subscriber is silent
      (multiple-value-bind (changes ready) (feed:take s)
        (is (not ready) "still inside the 1 s window -- the rate must refuse")
        (is (null changes)))
      (setf now 1000)
      (multiple-value-bind (changes ready) (feed:take s)
        (is-true ready)
        (is (equal '(("x" . 499)) changes)
            "500 missed publishes arrive as ONE latest value, not as 500")))))

;;; --- the three outcomes of TAKE ------------------------------------------
(test take-distinguishes-too-soon-from-nothing-changed
  (with-clock (now)
    (let* ((f (feed:make-feed))
           (s (feed:subscribe f :hz 10)))
      (feed:publish f "k" 1)
      (multiple-value-bind (changes ready) (feed:take s)
        (is-true ready) (is (equal '(("k" . 1)) changes)))
      ;; too soon
      (multiple-value-bind (changes ready) (feed:take s)
        (is (not ready)) (is (null changes)))
      ;; window open, but nothing new: ALLOWED and empty, which is a keep-alive moment
      (setf now 100)
      (multiple-value-bind (changes ready) (feed:take s)
        (is-true ready "the rate allowed it")
        (is (null changes) "and there was simply nothing to say")))))

(test an-idle-feed-does-not-delay-the-next-change
  ;; The clock advances only on an actual emission, so a quiet period does not leave a
  ;; debt of missed windows for the next change to wait out.
  (with-clock (now)
    (let* ((f (feed:make-feed))
           (s (feed:subscribe f :hz 1)))
      (feed:publish f "k" 1)
      (feed:take s)                       ; emits; next-at = 1000
      (setf now 60000)                    ; a minute of silence
      (feed:publish f "k" 2)
      (multiple-value-bind (changes ready) (feed:take s)
        (is-true ready)
        (is (equal '(("k" . 2)) changes) "immediately, not one interval later")))))

;;; --- fan-out: two rates from one source, and the source knows neither ----
(test two-subscribers-run-at-different-rates-independently
  (with-clock (now)
    (let* ((f (feed:make-feed))
           (fast (feed:subscribe f :hz 10))
           (slow (feed:subscribe f :hz 1)))
      (feed:publish f "p" 1)
      (is (equal '(("p" . 1)) (feed:take fast)))
      (is (equal '(("p" . 1)) (feed:take slow)))
      (setf now 100)
      (feed:publish f "p" 2)
      (multiple-value-bind (changes ready) (feed:take fast)
        (is-true ready) (is (equal '(("p" . 2)) changes) "100 ms is a window at 10 Hz"))
      (multiple-value-bind (changes ready) (feed:take slow)
        (is (not ready) "but not at 1 Hz -- and the publisher did not have to know"))
      (setf now 1000)
      (is (equal '(("p" . 2)) (feed:take slow))))))

(test one-subscriber-does-not-consume-anothers-changes
  (with-clock (now)
    (let* ((f (feed:make-feed))
           (a (feed:subscribe f :hz 1000))
           (b (feed:subscribe f :hz 1000)))
      (feed:publish f "k" :v)
      (is (equal '(("k" . :v)) (feed:take a)))
      (is (equal '(("k" . :v)) (feed:take b))
          "non-destructive, like channel -- readers do not steal from each other"))))

;;; --- :from ---------------------------------------------------------------
(test from-start-gets-the-snapshot-and-from-end-does-not
  (with-clock (now)
    (let ((f (feed:make-feed)))
      (feed:publish f "a" 1)
      (feed:publish f "b" 2)
      (let ((snap (feed:subscribe f :hz 1000 :from :start))
            (new  (feed:subscribe f :hz 1000 :from :end)))
        (is (= 2 (length (feed:take snap))) "a browser connecting wants current state")
        (multiple-value-bind (changes ready) (feed:take new)
          (is-true ready)
          (is (null changes) ":end means only what happens next"))
        (feed:publish f "c" 3)
        (is (equal '(("c" . 3)) (feed:take new)))))))

;;; --- the rate is not optional -------------------------------------------
(test subscribing-without-a-rate-is-refused
  ;; No default, deliberately: an omitted rate would silently reproduce the unbounded
  ;; case ADR-0016 rejects, and a default is how a policy nobody chose reaches production.
  (let ((f (feed:make-feed)))
    (signals feed:rate-required (feed:subscribe f))
    (signals feed:rate-required (feed:subscribe f :hz nil))
    (signals feed:rate-required (feed:subscribe f :hz 0))
    (signals feed:rate-required (feed:subscribe f :hz -5))))

;;; --- inspection ----------------------------------------------------------
(test the-feed-can-be-read-directly
  (let ((f (feed:make-feed)))
    (feed:publish f "a" 1)
    (feed:publish f "a" 2)
    (feed:publish f "b" 3)
    (is (= 2 (feed:feed-ref f "a")))
    (is (eq :none (feed:feed-ref f "missing" :none)))
    (is (= 2 (feed:feed-count f)))
    (is (equal '(("a" . 2) ("b" . 3))
               (sort (feed:feed-alist f) #'string< :key #'car)))))
