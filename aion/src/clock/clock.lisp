;;;; clock.lisp --- a monotonic Gregorian-100ns clock, and v6 ids on top of it.
;;;;
;;;; "The best serial ID generator is time itself": NEW-ID mints an RFC-9562 **v6** UUID
;;;; whose embedded 60-bit timestamp IS the VID -- a monotonic, sortable version/serial --
;;;; plus the UTC INSTANT. The load-bearing guarantee is the clock: a locked,
;;;; strictly-increasing counter (clj-uuid's trick) that bumps by one within a coarse
;;;; real-clock tick, so no two ids share a vid even under concurrent burst generation
;;;; (thousands+/sec). The frugal-uuid library's default v6 does NOT give this -- its
;;;; timestamp field collides en masse -- so the clock is owned here and the 16-octet v6
;;;; assembled by hand. Pure bit-work, no dependency.
;;;;
;;;; Extracted intact from mnemosyne/id (pre-publication issue 96). It is not a persistence concern: the
;;;; sortability comes from a clock, and a clock is a floor primitive. mnemosyne/id keeps
;;;; TOUCH! and NEW-STAMP, which are about entity metadata and column names, and calls
;;;; NEW-ID from here rather than owning one.

(in-package #:aion/clock)

(defconstant +gregorian-offset+ 122192928000000000
  "100-ns intervals from 1582-10-15 (the UUID/Gregorian epoch) to 1970-01-01 (Unix).")
(defconstant +unix-universal-offset+ 2208988800
  "Seconds from 1900-01-01 (CL universal-time epoch) to 1970-01-01 (Unix epoch).")

(defvar *clock-lock* (sb-thread:make-mutex :name "aion-clock"))
(defvar *last-vid* 0 "The last vid issued; the monotonic clock never repeats or goes back.")
(defun %uuid-entropy ()
  "62 unpredictable bits for a v6 UUID's clock-seq (14) and node (48), as one integer.

ONE draw of 8 octets rather than two calls: NEW-ID is minted per ROW in mnemosyne, and each
draw is a read from the OS generator. 62 of the 64 bits are used and the spare two are
dropped rather than reused -- carving overlapping fields out of one draw is how a clever
implementation ends up correlating them.

WHY A CSPRNG HERE AT ALL, given that a v6 UUID is PARTLY PREDICTABLE BY DESIGN -- its high
bits are a monotonic timestamp, which is the entire feature:

  A guessable timestamp does not make the rest free. clock-seq and node are 62 bits in
  EVERY id, and v6 ids are PUBLISHED by design -- entity ids in URLs, APIs and logs. Under
  `cl:random' (MT19937) that is 62 bits of RECOVERABLE generator state handed out on every
  row; once recovered, clock-seq and node are predictable too, and an observer can
  CONSTRUCT a plausible future id rather than merely recognise one.

  Whether that is exploitable depends on something this file cannot know: whether an id is
  ever treated as a capability, or whether a predicted id could force a collision in a
  store keyed on it. Neither is demonstrated. It is cheap to remove the question entirely,
  so it is removed.

AND THE RULE THAT SURVIVES IT, because a strong generator here must not be read as a
promise this format cannot make:

  A TIME-ORDERED ID IS NOT A SECRET. The timestamp half stays guessable no matter what
  seeds the rest. If you need an unguessable value, use AION/RANDOM directly.

(pre-publication issue 95. The first pass left this on `cl:random', arguing a CSPRNG \"would change nothing an
attacker cares about\". That was overstated -- 62 bits per published id is not nothing --
and it is the note above that carries the not-a-secret meaning, not a weaker generator.)"
  (let ((octets (rnd:random-octets 8)))
    (loop with acc = 0
          for b across octets
          do (setf acc (+ (ash acc 8) b))
          finally (return acc))))

(defun %wall-100ns ()
  "Wall-clock time in 100-ns ticks since the Unix epoch (microsecond real resolution)."
  (multiple-value-bind (sec usec) (sb-ext:get-time-of-day)
    (+ (* sec 10000000) (* usec 10))))

(defun next-vid ()
  "A strictly-increasing Gregorian-100ns tick -- the VID -- thread-safe. Within a coarse
real-clock tick it bumps by 1, so successive calls never collide even at burst rates. This
is the uniqueness/monotonicity guarantee the whole scheme rests on."
  (sb-thread:with-mutex (*clock-lock*)
    (let ((greg (+ (%wall-100ns) +gregorian-offset+)))
      (setf *last-vid* (if (> greg *last-vid*) greg (1+ *last-vid*))))))

(defun %assemble-v6 (vid clock-seq node)
  "Assemble a 16-octet RFC-9562 v6 UUID from a 60-bit VID, a 14-bit CLOCK-SEQ, and a 48-bit
NODE. v6 puts the timestamp most-significant, so lexical order == time order."
  (let ((b (make-array 16 :element-type '(unsigned-byte 8)))
        (thi  (ldb (byte 32 28) vid))
        (tmid (ldb (byte 16 12) vid))
        (tlow (ldb (byte 12 0)  vid)))
    (setf (aref b 0) (ldb (byte 8 24) thi)  (aref b 1) (ldb (byte 8 16) thi)
          (aref b 2) (ldb (byte 8 8) thi)   (aref b 3) (ldb (byte 8 0) thi)
          (aref b 4) (ldb (byte 8 8) tmid)  (aref b 5) (ldb (byte 8 0) tmid)
          (aref b 6) (logior #x60 (ldb (byte 4 8) tlow))       ; version 6 + top nibble time_low
          (aref b 7) (ldb (byte 8 0) tlow)
          (aref b 8) (logior #x80 (ldb (byte 6 8) clock-seq))  ; variant 10 + top 6 bits clock_seq
          (aref b 9) (ldb (byte 8 0) clock-seq))
    (loop for i below 6 do (setf (aref b (+ 10 i)) (ldb (byte 8 (* 8 (- 5 i))) node)))
    b))

(defun %format-uuid (b)
  "The 16 octets B as a canonical lowercase 8-4-4-4-12 UUID string."
  (string-downcase
   (with-output-to-string (s)
     (loop for i below 16 do
       (when (member i '(4 6 8 10)) (write-char #\- s))
       (format s "~2,'0X" (aref b i))))))

(defun vid->instant (vid)
  "The UTC instant of VID as an ISO-8601 string with 100-ns precision (YYYY-MM-DDTHH:MM:SS.fffffffZ)."
  (let* ((unix-100ns (- vid +gregorian-offset+))
         (unix-sec (floor unix-100ns 10000000))
         (frac (mod unix-100ns 10000000)))
    (multiple-value-bind (s m h d mon y) (decode-universal-time
                                          (+ unix-sec +unix-universal-offset+) 0)  ; 0 = UTC
      (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0D.~7,'0DZ" y mon d h m s frac))))

(defun new-id ()
  "Mint a fresh time-ordered identity. Returns (VALUES uuid vid instant):
- UUID    -- an RFC-9562 v6 whose embedded timestamp IS the vid (so it is sortable/unique),
- VID     -- the monotonic Gregorian-100ns tick, a big integer version/serial,
- INSTANT -- the UTC time as an ISO-8601 string (…​.fffffffZ).
Unique and strictly monotonic even under concurrent burst generation."
  (let* ((vid (next-vid))
         (bits (%uuid-entropy))
         (clock-seq (ldb (byte 14 0) bits))
         (node (logior #x010000000000 (ldb (byte 48 14) bits)))  ; set multicast bit: random node
         (uuid (%format-uuid (%assemble-v6 vid clock-seq node))))
    (values uuid vid (vid->instant vid))))
