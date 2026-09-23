;;;; channel-tests.lisp --- hyperion/channel (broadcast log + cursors, fan-out).

(in-package #:hyperion/tests)

(def-suite channel :description "Broadcast channel: append-only log + cursors." :in hyperion)
(in-suite channel)

;;; --- stateless read (since) -----------------------------------------------
(test since-returns-items-and-next-index
  (let ((ch (channel:make-channel)))
    (is (= 0 (channel:channel-length ch)))
    (is (= 1 (channel:publish ch :a)))          ; publish returns the new length
    (is (= 2 (channel:publish ch :b)))
    (multiple-value-bind (items next) (channel:since ch 0)
      (is (equal '(:a :b) items))
      (is (= 2 next)))
    (multiple-value-bind (items next) (channel:since ch 2)  ; caught up
      (is (null items))
      (is (= 2 next)))
    ;; index clamps to [0, length]
    (is (equal '(:a :b) (channel:since ch -5)))
    (is (null (channel:since ch 99)))))

;;; --- the regression test for the demo bug: fan-out, no stealing -----------
(test fan-out-two-cursors-both-receive
  "Two cursors on one channel each see the full stream -- one's POLL never consumes
items out from under the other (the single-mailbox bug that dropped a reply onto the
wrong browser)."
  (let ((ch (channel:make-channel)))
    (channel:publish ch :a)
    (let ((c1 (channel:subscribe ch :from :start))
          (c2 (channel:subscribe ch :from :start)))
      (channel:publish ch :b)
      (is (equal '(:a :b) (channel:poll c1)))
      (is (equal '(:a :b) (channel:poll c2)))   ; c2 NOT starved by c1's poll
      (is (null (channel:poll c1)))             ; nothing new
      (channel:publish ch :c)
      (is (equal '(:c) (channel:poll c1)))
      (is (equal '(:c) (channel:poll c2))))))

;;; --- cursor start position ------------------------------------------------
(test subscribe-from-end-is-only-new
  (let ((ch (channel:make-channel)))
    (channel:publish ch :old)
    (let ((c (channel:subscribe ch)))           ; default :end
      (is (null (channel:poll c)))              ; does NOT replay :old
      (channel:publish ch :new)
      (is (equal '(:new) (channel:poll c))))))

(test reset-cursor-replays
  (let ((ch (channel:make-channel)))
    (channel:publish ch :a)
    (channel:publish ch :b)
    (let ((c (channel:subscribe ch :from :end)))
      (is (null (channel:poll c)))
      (channel:reset-cursor c :start)
      (is (equal '(:a :b) (channel:poll c))))))

;;; --- thread safety --------------------------------------------------------
(test concurrent-publishes-are-not-lost
  "Fifty threads each publish once; the lock guarantees all fifty land."
  (let ((ch (channel:make-channel))
        (threads '()))
    (dotimes (i 50)
      (push (bt:make-thread (lambda () (channel:publish ch :x))) threads))
    (aion/test-threads:join-all threads)
    (is (= 50 (channel:channel-length ch)))))

;;; --- the window is a decision, not an accident (pre-publication issue 231) --------------------
;;;
;;; The defect was not that the log grew -- growing is what a log does. It was that
;;; "forever" was the shape the file happened to have rather than anything anyone chose,
;;; and that nothing anywhere said so.

(test eviction-holds-the-window-however-fast-the-publisher-is
  ;; Named for what it asserts. It was "bounded-by-default" while constructing the
  ;; channel with an explicit :CAPACITY 4 -- which is the one thing it does not test;
  ;; THE-DEFAULT-CAPACITY-IS-A-NUMBER-NOT-NIL below is where the default is checked.
  (let ((ch (channel:make-channel :capacity 4)))
    (dotimes (i 10) (channel:publish ch i))
    (is (= 4 (channel:channel-retained ch)) "the window holds, whatever the publish rate")
    (is (= 10 (channel:channel-length ch))
        "and absolute indices keep counting -- they are positions in the history")
    (is (= 6 (channel:channel-earliest ch)))))

(test eviction-keeps-the-newest-in-order
  (let ((ch (channel:make-channel :capacity 3)))
    (dotimes (i 6) (channel:publish ch i))
    (is (equal '(3 4 5) (channel:since ch 3)))
    (is (equal '(5) (channel:since ch 5)) "and an index inside the window still means it")))

(test unbounded-is-still-available-but-must-be-asked-for
  (let ((ch (channel:make-channel :capacity nil)))
    (dotimes (i 5000) (channel:publish ch i))
    (is (null (channel:channel-window ch)))
    (is (= 5000 (channel:channel-retained ch)) "forever, because the caller typed it")
    (is (= 0 (channel:channel-earliest ch)))))

(test a-negative-index-asks-for-the-earliest-available-and-never-signals
  ;; SINCE has always taken a negative index to mean "whatever you still have". It is a
  ;; request, not a position, so eviction cannot put it behind the window -- and clamping
  ;; it to 0 and then comparing against BASE would signal at a caller who asked for
  ;; exactly what it got. Before the window existed 0 WAS the oldest, so the two readings
  ;; agreed and nothing distinguished them; only eviction pulls them apart.
  (let ((ch (channel:make-channel :capacity 3)))
    (dotimes (i 10) (channel:publish ch i))
    (is (equal '(7 8 9) (channel:since ch -1))
        "the oldest retained, not an error about index 0")
    (multiple-value-bind (items next) (channel:since ch -1)
      (declare (ignore items))
      (is (= 10 next) "and it still reports where to read from next"))
    ;; The control, in the other direction: index 0 on the same channel is a POSITION,
    ;; it is behind the window, and it still signals. Without this the test above passes
    ;; on a SINCE that had simply stopped signalling.
    (signals channel:cursor-behind-window (channel:since ch 0))))

(test the-default-capacity-is-a-number-not-nil
  ;; The whole of pre-publication issue 231 in one assertion: a channel built with no opinion is bounded.
  (let ((ch (channel:make-channel)))
    (is (integerp (channel:channel-window ch)))
    (is (= channel:*default-capacity* (channel:channel-window ch)))))

(test a-capacity-of-zero-is-refused
  (signals error (channel:make-channel :capacity 0))
  (signals error (channel:make-channel :capacity -1)))

;;; --- falling out of the window is TOLD, never silent ---------------------

(test an-evicted-index-signals-rather-than-lying
  ;; This is the assertion that matters most. SINCE clamps, so the silent version would
  ;; hand back a much later item and look entirely correct to the caller.
  (let ((ch (channel:make-channel :capacity 3)))
    (dotimes (i 10) (channel:publish ch i))
    (signals channel:cursor-behind-window (channel:since ch 2))
    (handler-case (channel:since ch 2)
      (channel:cursor-behind-window (c)
        (is (= 2 (channel:cursor-behind-window-requested c)))
        (is (= 7 (channel:cursor-behind-window-earliest c))
            "and it says exactly how far behind the reader is")))))

(test resync-continues-from-the-oldest-retained
  (let ((ch (channel:make-channel :capacity 3)))
    (dotimes (i 10) (channel:publish ch i))
    (is (equal '(7 8 9)
               (handler-bind ((channel:cursor-behind-window
                                (lambda (c) (declare (ignore c))
                                  (invoke-restart 'channel:resync))))
                 (channel:since ch 2)))
        "a caller that would rather have the gap than the error can say so")))

(test a-cursor-that-fell-behind-is-told-too
  (let* ((ch (channel:make-channel :capacity 3))
         (cur (channel:subscribe ch :from :start)))
    (channel:publish ch :a)
    (is (equal '(:a) (channel:poll cur)))
    (dotimes (i 10) (channel:publish ch i))
    (signals channel:cursor-behind-window (channel:poll cur))))

(test an-index-inside-the-window-is-unaffected
  (let ((ch (channel:make-channel :capacity 100)))
    (dotimes (i 50) (channel:publish ch i))
    (is (= 50 (length (channel:since ch 0))) "no eviction, no condition, no change")
    (is (equal '(48 49) (channel:since ch 48)))))

(test from-start-means-oldest-retained-not-zero
  ;; :start resolving to 0 would signal on any evicted channel, which would make the
  ;; obvious way to say "give me everything you have" the one that breaks.
  (let ((ch (channel:make-channel :capacity 3)))
    (dotimes (i 10) (channel:publish ch i))
    (let ((cur (channel:subscribe ch :from :start)))
      (is (equal '(7 8 9) (channel:poll cur))))))

;;; --- the handler must be able to touch the channel (pre-publication issue 231 review) ----------
;;;
;;; The suite as first written could not see this defect: SIGNALS and a bare
;;; INVOKE-RESTART are the only two handlers that never re-enter the channel, and they
;;; were the only two it used. A condition whose report says "raise the channel's
;;; :CAPACITY" and whose restart is "resync" INVITES a handler that asks the channel
;;; something -- so the handler that a real caller writes was the one case untested.

(test a-handler-may-ask-the-channel-how-far-behind-it-is
  ;; Signalling under the mutex put arbitrary caller code inside the critical section, and
  ;; SBCL replaced the condition with "Recursive lock attempt" -- so the caller never even
  ;; saw CURSOR-BEHIND-WINDOW.
  (let ((ch (channel:make-channel :capacity 3))
        (seen (list nil)))
    (dotimes (i 10) (channel:publish ch i))
    (handler-case
        (handler-bind ((channel:cursor-behind-window
                         (lambda (c) (declare (ignore c))
                           (setf (car seen) (channel:channel-earliest ch)))))
          (channel:since ch 2))
      (channel:cursor-behind-window () nil))
    (is (= 7 (car seen)) "the handler ran, and the channel answered it")))

(test the-designed-recovery-path-works
  ;; Log the gap, move the cursor, carry on -- the handler this condition's own report
  ;; invites. RESET-CURSOR goes through CHANNEL-EARLIEST, i.e. straight back into the lock.
  (let* ((ch (channel:make-channel :capacity 3))
         (cur (channel:subscribe ch :from :start))
         (gap (list nil)))
    (channel:publish ch :first)
    (channel:poll cur)
    (dotimes (i 10) (channel:publish ch i))
    (handler-bind ((channel:cursor-behind-window
                     (lambda (c)
                       (setf (car gap) (- (channel:cursor-behind-window-earliest c)
                                          (channel:cursor-behind-window-requested c)))
                       (channel:reset-cursor cur :start)
                       (invoke-restart 'channel:resync))))
      (is (equal '(7 8 9) (channel:poll cur))))
    (is (= 7 (car gap)) "and it could measure the gap on the way past")))

(test resync-takes-the-oldest-available-when-more-was-evicted-meanwhile
  ;; BASE is read again after the handler returns, because a publisher can evict more
  ;; while the handler runs -- the BASE the handler was told is already historical.
  ;; Re-signalling instead of accepting would livelock against exactly the fast publisher
  ;; a reader falls behind on.
  (let ((ch (channel:make-channel :capacity 3)))
    (dotimes (i 10) (channel:publish ch i))
    (is (equal '(12 13 14)
               (handler-bind ((channel:cursor-behind-window
                                (lambda (c) (declare (ignore c))
                                  (dotimes (i 5) (channel:publish ch (+ 10 i)))
                                  (invoke-restart 'channel:resync))))
                 (channel:since ch 2)))
        "the oldest available AFTER the handler ran, not the stale figure it was given")))

;;; --- grow, then evict (pre-publication issue 231 review) --------------------------------------

(test a-channel-grows-to-its-capacity-and-then-evicts
  ;; Neither path was exercised: capacities 3 and 4 never grow (the store starts at
  ;; min(16, capacity) = capacity), and 100 and the default never evict. The transition
  ;; between them is the case the source comment calls load-bearing, so it needs an
  ;; assertion rather than a hand-check.
  (let ((ch (channel:make-channel :capacity 20)))
    (dotimes (i 60) (channel:publish ch i))
    (is (= 20 (channel:channel-retained ch)) "grew to 20, then held there")
    (is (= 40 (channel:channel-earliest ch)))
    (is (= 60 (channel:channel-length ch)))
    (is (equal (loop for i from 40 below 60 collect i) (channel:since ch 40))
        "and the survivors are in order -- a ring that grew and then wrapped")))

(test growth-preserves-order-across-the-wrap
  ;; A store that grows re-lays the ring out from index 0; one that then wraps writes
  ;; behind the head. Both at once is where off-by-one lives.
  (let ((ch (channel:make-channel :capacity 17)))     ; not a power of two, on purpose
    (dotimes (i 100) (channel:publish ch i))
    (is (equal (loop for i from 83 below 100 collect i) (channel:since ch 83)))
    (is (= 17 (channel:channel-retained ch)))))
