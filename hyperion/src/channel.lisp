;;;; channel.lisp --- a broadcast log with per-reader cursors, over a bounded window
;;;;
;;;; The fan-out substrate for live updates. Unlike a queue drained once (where
;;;; concurrent readers steal each other's items -- the bug behind "Elise thinking
;;;; -> no response" when a second browser shared the session), a CHANNEL is read
;;;; NON-destructively by absolute index. Every reader sees every item. PUBLISH
;;;; appends; SINCE is the stateless read (a poller carries its own index);
;;;; SUBSCRIBE/POLL is a stateful in-process cursor.
;;;;
;;;; Generic infra (no domain, no HTTP): praxeon builds its per-conversation bubble
;;;; stream on this, and any live-updating Hyperion app can too.
;;;;
;;;; A LOG THAT NEVER FORGETS MUST SAY WHAT BOUNDS IT (#231). This used to be one
;;;; VECTOR-PUSH-EXTEND with no removal anywhere in the file, so it promised "every
;;;; message, forever" -- BY ACCIDENT, because nobody had ever written down that it
;;;; did. At a conversation's pace that is bounded by the conversation, which is the
;;;; case it was written for. At the rate #210 measured on a real market feed -- 424
;;;; msg/sec sustained -- it is a memory leak with a publication schedule.
;;;;
;;;; So the window is a DECISION at construction:
;;;;
;;;;   (make-channel)                  ; *DEFAULT-CAPACITY* items, oldest evicted
;;;;   (make-channel :capacity 100)    ; a smaller window
;;;;   (make-channel :capacity nil)    ; unbounded -- and you had to type it
;;;;
;;;; `:capacity nil' still means forever. What changed is that it is now something a
;;;; caller CHOSE and a reader can see, rather than the shape the file happened to
;;;; have. The every-message-in-order guarantee is legitimate and is not being taken
;;;; away; it is being given a stated extent.
;;;;
;;;; A CURSOR THAT FALLS OUT OF THE WINDOW IS TOLD, and this matters more than the
;;;; bound. Eviction without it would be strictly worse than the leak: SINCE clamps
;;;; its index, so a reader asking for item 5 after 5 was evicted would silently
;;;; receive item 500 and believe it had missed nothing. Silent gaps in an audit trail
;;;; are the failure this primitive exists to prevent. So it signals
;;;; CURSOR-BEHIND-WINDOW, with a RESYNC restart for callers that would rather have
;;;; the oldest still held than an error.
;;;;
;;;; NOT hyperion/feed, and the choice between them is easy to get wrong in a way that
;;;; fails silently either way (ADR-0016):
;;;;
;;;;   channel -- every reader sees EVERY item, in order, within the window. Right when
;;;;              a skipped value is a defect: a transcript, an audit trail, a sequence
;;;;              of commands. Memory is the window.
;;;;   feed    -- every reader sees the LATEST item per key, no more often than it asked.
;;;;              Right for prices, progress, positions, presence -- anything where an
;;;;              intermediate value has no standing once superseded. Memory is the
;;;;              number of distinct KEYS.
;;;;
;;;; If your source is fast and your values supersede one another, this is the wrong file.

(cl:in-package #:hyperion/channel)

(defparameter *default-capacity* 1024
  "How many items a channel retains when its capacity is not given.

A number rather than NIL, because the previous default was unbounded and nobody had
decided that -- see the file header. 1024 is chosen to be generous for the case this
primitive was written for (a conversation's bubbles, a job's log lines) while being a
bound rather than a hope. An application whose readers can fall a long way behind should
raise it deliberately; one that genuinely wants forever passes :CAPACITY NIL.")

;;; --- the ring ------------------------------------------------------------
;;;
;;; A ring rather than a vector trimmed from the front: eviction is then O(1) instead of
;;; shifting every retained item on every publish. At 424 msg/sec against a 1024 window
;;; that is the difference between 434k element moves a second and none.
;;;
;;; BASE is the absolute index of the oldest item still held, so the indices callers hold
;;; keep their meaning across eviction -- they are positions in the whole history, not
;;; offsets into storage. That is what makes "your index is before the window" a question
;;; that can be answered at all.

(defstruct (channel (:constructor %make-channel) (:conc-name channel-))
  "A broadcast log over a bounded window: a ring of items, the absolute index of the
oldest one retained, and a lock. Readers consume by absolute index, non-destructively
(fan-out to many subscribers)."
  (store (make-array 16))
  (head 0 :type unsigned-byte)          ; index in STORE of the oldest item
  (count 0 :type unsigned-byte)         ; how many items are held
  (base 0 :type unsigned-byte)          ; absolute index of that oldest item
  (capacity nil)                        ; NIL = unbounded (grow); integer = evict oldest
  (lock (bt:make-lock "hyperion-channel")))

(defun make-channel (&key (capacity *default-capacity*))
  "A fresh, empty broadcast channel retaining CAPACITY items.

CAPACITY NIL means unbounded: every item is kept for the channel's lifetime. That is a
legitimate choice for a short-lived or slow channel and an unbounded memory commitment for
any other, which is why it must be typed rather than defaulted to (#231)."
  (check-type capacity (or null (integer 1)))
  ;; THE STORE STARTS AT MIN(16, CAPACITY), and that is load-bearing rather than a
  ;; micro-optimisation. Eviction advances HEAD modulo the store's length, so the ring
  ;; arithmetic is only correct once the store is EXACTLY capacity long. Starting at a
  ;; flat 16 with a capacity of 3 puts items at head+0..head+2 in a 16-slot store while
  ;; overwriting at head -- two different notions of "next", and the reader sees NILs.
  (%make-channel :capacity capacity
                 :store (make-array (if capacity (min 16 capacity) 16))))

(defun channel-earliest (channel)
  "The absolute index of the oldest item CHANNEL still holds. 0 until eviction begins."
  (bt:with-lock-held ((channel-lock channel)) (channel-base channel)))

(defun channel-window (channel)
  "CHANNEL's retention, in items: an integer, or NIL when it is unbounded."
  (channel-capacity channel))

(defun %grow (channel)
  "Double CHANNEL's storage, re-laying the ring out from index 0. Bounded channels never
grow past their capacity; that is where eviction takes over instead."
  (let* ((old (channel-store channel))
         (n (length old))
         (cap (channel-capacity channel))
         (size (if cap (min (* 2 n) cap) (* 2 n)))
         (new (make-array size)))
    (dotimes (i (channel-count channel))
      (setf (svref new i) (aref old (mod (+ (channel-head channel) i) n))))
    (setf (channel-store channel) new
          (channel-head channel) 0)))

(defun publish (channel item)
  "Append ITEM to CHANNEL; return the index just past it -- i.e. the index a reader
should ask for next.

When a bounded channel is full this EVICTS the oldest item. Readers holding an index that
has just left the window learn about it on their next read, not silently."
  (bt:with-lock-held ((channel-lock channel))
    (let ((cap (channel-capacity channel)))
      (cond
        ((and cap (= (channel-count channel) cap))
         (let ((n (length (channel-store channel))))
           (setf (svref (channel-store channel) (channel-head channel)) item
                 (channel-head channel) (mod (1+ (channel-head channel)) n))
           (incf (channel-base channel))))
        (t
         (when (= (channel-count channel) (length (channel-store channel)))
           (%grow channel))
         (let ((n (length (channel-store channel))))
           (setf (svref (channel-store channel)
                        (mod (+ (channel-head channel) (channel-count channel)) n))
                 item))
         (incf (channel-count channel)))))
    (+ (channel-base channel) (channel-count channel))))

(defun channel-length (channel)
  "The index just past the newest item -- the total ever published, not the number
retained. It keeps meaning across eviction, which is the point of absolute indices."
  (bt:with-lock-held ((channel-lock channel))
    (+ (channel-base channel) (channel-count channel))))

(defun channel-retained (channel)
  "How many items CHANNEL is actually holding -- its memory, in items."
  (bt:with-lock-held ((channel-lock channel)) (channel-count channel)))

;;; --- falling out of the window -------------------------------------------

(define-condition cursor-behind-window (error)
  ((channel :initarg :channel :reader cursor-behind-window-channel)
   (requested :initarg :requested :reader cursor-behind-window-requested)
   (earliest :initarg :earliest :reader cursor-behind-window-earliest))
  (:report
   (lambda (c stream)
     ;; One line, no ~<newline> continuation: on a CRLF checkout that becomes an illegal
     ;; ~<Return> directive (AGENTS.md, house style).
     (format stream "hyperion/channel: index ~D has been evicted; the oldest item still retained is ~D. ~D item~:P were missed. Use the RESYNC restart to continue from ~D, or raise the channel's :CAPACITY."
             (cursor-behind-window-requested c)
             (cursor-behind-window-earliest c)
             (- (cursor-behind-window-earliest c) (cursor-behind-window-requested c))
             (cursor-behind-window-earliest c))))
  (:documentation
   "Signalled when a reader asks for an index that has left the channel's window.

An ERROR rather than a warning, and rather than quietly returning what is left, because
this channel's whole promise is that a reader sees every item in order. Having missed some
is exactly the thing a caller must not be allowed to not notice -- SINCE clamps its index,
so the silent version would hand back a much later item and look correct."))

(defun %read-from (channel index)
  "Items from absolute INDEX to the newest, and the index just past them. Caller holds
the lock. INDEX must be within the window."
  (let* ((n (length (channel-store channel)))
         (end (+ (channel-base channel) (channel-count channel)))
         (start (max (channel-base channel) (min index end))))
    (values (loop for i from start below end
                  for off = (- i (channel-base channel))
                  collect (svref (channel-store channel)
                                 (mod (+ (channel-head channel) off) n)))
            end)))

(defun since (channel index)
  "Return (values ITEMS NEXT-INDEX): the items at or after INDEX, and the index just past
them. Stateless fan-out -- every reader passes its own INDEX and sees every item; nothing
is consumed.

A negative INDEX means the earliest available, as it always has. An INDEX that has been
EVICTED signals CURSOR-BEHIND-WINDOW, with a RESYNC restart that reads from the oldest
item still retained."
  ;; THE CONDITION IS SIGNALLED WITH THE LOCK RELEASED, and that is the whole shape of
  ;; this function rather than a detail of it. A handler runs on the signalling thread, so
  ;; signalling under the mutex puts ARBITRARY CALLER CODE inside this critical section --
  ;; and the very first thing a real handler does is ask the channel something. SBCL then
  ;; replaces the condition with "Recursive lock attempt" and the caller never sees
  ;; CURSOR-BEHIND-WINDOW at all.
  ;;
  ;; What makes it worse than an ordinary deadlock is WHICH callers it hits: the report
  ;; says to raise :CAPACITY and offers RESYNC, so the handler this condition invites is
  ;; "log how far behind I am, move the cursor, carry on" -- and both CHANNEL-EARLIEST and
  ;; (reset-cursor cur :start) take this mutex. The designed recovery path was the one
  ;; that broke.
  ;;
  ;; A recursive mutex would silence it and is the wrong fix: it would make running caller
  ;; code inside our critical section LEGAL rather than merely survivable.
  ;;
  ;; So: read BASE under the lock, drop it, signal, re-acquire and RE-CHECK -- a publisher
  ;; can evict more while the handler runs, so the BASE the handler was told is already
  ;; historical. ACCEPT-GAP rather than re-signalling on the second pass, because RESYNC
  ;; means "give me the oldest you have now"; re-signalling would livelock against a fast
  ;; publisher, which is exactly the channel a reader falls behind on.
  ;;
  ;; A NEGATIVE INDEX ASKS FOR THE EARLIEST AVAILABLE, so it can never be behind the
  ;; window and must never signal. It is a request ("whatever you still have"), not a
  ;; position, and it was that before the window existed -- when 0 was always the oldest.
  ;; Eviction is what pulled the two apart: clamping to 0 and then comparing against BASE
  ;; would signal CURSOR-BEHIND-WINDOW at a caller who asked for exactly what it got.
  ;; ACCEPT-GAP is already the flag for "no error, give me the oldest you have", and
  ;; %READ-FROM clamps 0 up to BASE, so the answer is right without a second path.
  (let ((want (max 0 index))
        (accept-gap (minusp index)))
    (loop
      (let ((base nil))
        (bt:with-lock-held ((channel-lock channel))
          (setf base (channel-base channel))
          (when (or accept-gap (>= want base))
            (return (%read-from channel want))))   ; %READ-FROM clamps up to BASE
        (restart-case
            (error 'cursor-behind-window :channel channel :requested want :earliest base)
          (resync ()
            :report "Read from the oldest item still retained, accepting the gap."
            (setf accept-gap t)))))))

;;; --- a stateful cursor, for in-process readers ---------------------------
(defstruct (cursor (:constructor %make-cursor) (:conc-name cursor-))
  "A reader's position in a CHANNEL (an absolute index that POLL advances)."
  (channel nil)
  (at 0 :type unsigned-byte))

(defun %resolve-index (where channel)
  "Resolve WHERE -- :start, :end, or an integer -- to an absolute index.

:START is the oldest item STILL RETAINED rather than 0, because 0 may long since have been
evicted and asking for it would signal rather than replay."
  (cond ((integerp where) (max 0 where))
        ((eq where :start) (channel-earliest channel))
        ((eq where :end) (channel-length channel))
        (t (error "Expected :start, :end, or an integer index; got ~S" where))))

(defun subscribe (channel &key (from :end))
  "A CURSOR over CHANNEL. FROM is :end (default -- only items published after now),
:start (everything still retained), or an integer index."
  (%make-cursor :channel channel :at (%resolve-index from channel)))

(defun poll (cursor)
  "The new items on CURSOR's channel since the last POLL (a list); advances CURSOR
past them. Two cursors on one channel never steal from each other.

Signals CURSOR-BEHIND-WINDOW if this cursor has fallen out of the window while it was
away. Invoking RESYNC advances it to the oldest item still retained."
  (multiple-value-bind (items next) (since (cursor-channel cursor) (cursor-at cursor))
    (setf (cursor-at cursor) next)
    items))

(defun reset-cursor (cursor &optional (to :start))
  "Move CURSOR to :start (the oldest retained), :end (past the newest), or an integer
index; return it."
  (setf (cursor-at cursor) (%resolve-index to (cursor-channel cursor)))
  cursor)
