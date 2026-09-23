;;;; clock.lisp --- tests for aion/clock (the monotonic clock and v6 ids on it).
;;;;
;;;; These moved here with the code (#96). The monotonicity guarantee is the whole reason
;;;; this clock is hand-assembled rather than taken from frugal-uuid, so a move that
;;;; carried the code without carrying its proof would be the more dangerous half of the
;;;; refactor -- the code would still compile, still return plausible ids, and quietly
;;;; stop being unique under load.

(cl:defpackage #:aion/clock/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:clock #:aion/clock))
  (:export #:run-tests #:aion-clock))
(in-package #:aion/clock/tests)

(def-suite aion-clock
  :description "The monotonic Gregorian-100ns clock and the v6 ids built on it.")
(in-suite aion-clock)

(defun %v6-p (s)
  "T if S is a canonical v6 UUID string (version nibble 6, variant 8/9/a/b)."
  (and (stringp s) (= (length s) 36)
       (char= (char s 14) #\6)                       ; version
       (member (char s 19) '(#\8 #\9 #\a #\b))))     ; variant

(test new-id-shape
  (multiple-value-bind (uuid vid instant) (clock:new-id)
    (is (%v6-p uuid) "uuid ~S is not a v6" uuid)
    (is (integerp vid))
    (is (plusp vid))
    ;; ISO-8601 UTC with 100-ns precision, e.g. 2026-07-25T15:33:14.3625630Z
    (is (and (= (length instant) 28) (char= (char instant 27) #\Z)
             (char= (char instant 10) #\T)))))

(test vid-unique-and-monotonic
  (let* ((n 20000)
         (vids (loop repeat n collect (nth-value 1 (clock:new-id)))))
    (is (= n (length (remove-duplicates vids))) "vids collided")
    (is (loop for (a b) on vids while b always (< a b)) "vids not strictly increasing")))

(test vid-is-strictly-increasing-under-concurrency
  "Six threads hammering the clock at once. Two separate claims, because they can fail
independently: WITHIN a thread the values must strictly increase (time does not run
backwards for a single caller), and ACROSS all threads no value may ever be issued twice
(the mutex is what makes the read-then-bump atomic). Drop the lock and the first still
passes while the second fails."
  (let* ((per 2000) (threads 6) (lock (sb-thread:make-mutex)) (locals '()))
    (mapc #'sb-thread:join-thread
          (loop repeat threads
                collect (sb-thread:make-thread
                         (lambda ()
                           (let ((mine (loop repeat per collect (clock:next-vid))))
                             (sb-thread:with-mutex (lock) (push mine locals)))))))
    (is (= threads (length locals)) "a thread did not report its vids")
    (dolist (mine locals)
      (is (loop for (a b) on mine while b always (< a b))
          "a thread's own vids were not strictly increasing"))
    ;; A hash table rather than REMOVE-DUPLICATES: the latter is quadratic, and 12000
    ;; bignums is where that stops being free.
    (let ((seen (make-hash-table :test #'eql))
          (total (* per threads)))
      (dolist (mine locals)
        (dolist (v mine) (setf (gethash v seen) t)))
      (is (= total (hash-table-count seen))
          "concurrent vids collided: ~D generated, ~D distinct" total (hash-table-count seen)))))

(test v6-sorts-lexically-in-time-order
  "The reason it is v6 and not v4, and a property no other test here covers: v6 puts the
timestamp in the most-significant bits, so sorting the ID STRINGS -- which is what a
database index or an ORDER BY actually does -- yields time order. If the field layout in
%ASSEMBLE-V6 were wrong, every test above would still pass and this one would not."
  (let* ((n 500)
         (uuids (loop repeat n collect (nth-value 0 (clock:new-id)))))
    (is (equal uuids (sort (copy-list uuids) #'string<))
        "v6 ids did not sort lexically into generation order")))

(test vid->instant-round-trips-to-the-right-second
  "The instant must describe the vid it came from, not merely be a well-formed timestamp."
  (multiple-value-bind (uuid vid instant) (clock:new-id)
    (declare (ignore uuid))
    (is (string= instant (clock:vid->instant vid)))
    ;; Independently reconstruct the second from the vid and check the rendered prefix.
    (let* ((unix-sec (floor (- vid 122192928000000000) 10000000)))
      (multiple-value-bind (s m h d mon y)
          (decode-universal-time (+ unix-sec 2208988800) 0)
        (is (string= (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0D" y mon d h m s)
                     (subseq instant 0 19)))))))

(defun run-tests ()
  "Run the aion/clock suite; return T on success (for `asdf:test-system`).
Named RUN-TESTS, not RUN -- FiveAM already exports RUN."
  (run! 'aion-clock))

;;; --- the non-timestamp bits (#95) ------------------------------------------
;;;
;;; A v6 UUID's high bits are a monotonic timestamp and are guessable by design. Its LOW
;;; bits -- 14 of clock-seq and 48 of node -- are not, and since #95 they come from
;;; aion/random rather than from cl:random. These pin that they are actually varying and
;;; actually random-looking, which is what the switch was for.

(test uuid-low-bits-vary-across-ids
  ;; Under cl:random these varied too, so this is not the interesting assertion on its own
  ;; -- it is the one that would catch the switch being wired to a constant, which is the
  ;; way a generator change usually breaks.
  (let ((tails (loop repeat 200 collect (subseq (aion/clock:new-id) 19))))
    (is (> (length (remove-duplicates tails :test #'string=)) 190)
        "the clock-seq/node half of a v6 id must vary; got ~D distinct of 200"
        (length (remove-duplicates tails :test #'string=)))))

(test the-multicast-bit-is-still-set
  ;; RFC 9562: a randomly generated node must set the multicast bit, so it can never collide
  ;; with a real MAC address. Easy to lose when the surrounding expression is rewritten.
  (dotimes (i 50)
    (let* ((id (aion/clock:new-id))
           (node (parse-integer (remove #\- (subseq id 24)) :radix 16)))
      (is-true (logbitp 40 node)
               "node ~X must have the multicast bit set" node))))

(test clock-entropy-does-not-come-from-cl-random
  ;; The #95 rule for this file, enforced rather than described: the source must contain no
  ;; call to cl:random. Docstrings may DISCUSS it -- and this file's does, at length -- so
  ;; the scan looks for the call form specifically.
  (let ((path (merge-pathnames "src/clock/clock.lisp"
                               (asdf:system-source-directory :aion/clock))))
    (is-true (probe-file path) "clock.lisp must be where this test looks: ~A" path)
    (with-open-file (in path :external-format :utf-8)
      (let ((hits (loop for line = (read-line in nil nil)
                        for n from 1
                        while line
                        when (or (search "(random " line) (search "make-random-state" line))
                          collect n)))
        (is-false hits "clock.lisp must not call cl:random (#95); lines ~S" hits)))))
