;;;; random-tests.lisp --- aion/random (#95).
;;;;
;;;; A random source is awkward to test: every output is legal, so nothing can be asserted
;;;; about one value. What CAN be asserted is shape, range, the absence of the specific
;;;; biases a careless implementation introduces, and -- the point of the ticket -- that
;;;; output does not repeat. None of that proves cryptographic strength; that rests on the
;;;; OS generator, which is the reason for using it rather than rolling one.

(cl:defpackage #:aion/random/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:rnd #:aion/random))
  (:export #:run-tests))

(in-package #:aion/random/tests)

(def-suite random :description "aion/random: a CSPRNG that cannot be confused with cl:random (#95).")
(in-suite random)

(defun run-tests () (run! 'random))

(test octets-have-the-requested-shape
  (dolist (n '(1 8 16 32 64))
    (let ((v (rnd:random-octets n)))
      (is (= n (length v)) "asked for ~D octets" n)
      (is (equal '(unsigned-byte 8) (array-element-type v))))))

(test zero-octets-is-empty-not-an-error
  (is (= 0 (length (rnd:random-octets 0)))))

(test hex-is-exactly-as-wide-as-the-entropy-it-claims
  ;; A string shorter than its nibble count would silently overstate its entropy, which is
  ;; the exact failure this ticket is about one level up: a number in a docstring that the
  ;; value does not have.
  (dolist (bits '(8 64 128 256))
    (let ((s (rnd:random-hex bits)))
      (is (= (/ bits 4) (length s)) "~D bits must be ~D hex chars" bits (/ bits 4))
      (is-true (every (lambda (c) (find c "0123456789abcdef")) s)
               "must be lowercase hex: ~S" s))))

(test hex-refuses-a-width-it-cannot-represent-honestly
  ;; 130 bits is 32.5 nibbles. Rendering 33 would imply 132 bits. Refuse rather than round.
  (signals error (rnd:random-hex 130))
  (signals error (rnd:random-hex 0))
  (signals error (rnd:random-hex -8)))

(test hex-is-zero-padded
  ;; The failure this guards is a leading zero byte rendering as one nibble, shortening the
  ;; string. It shows up in roughly 1 value in 16 per leading octet, so a single sample
  ;; would usually pass; take many.
  (let ((widths (loop repeat 400 collect (length (rnd:random-hex 32)))))
    (is (every (lambda (w) (= w 8)) widths)
        "every 32-bit id must be 8 chars, got widths ~S" (remove-duplicates widths))))

(test integers-stay-in-range
  (dolist (bound '(1 2 3 7 256 257 1000000))
    (let ((seen (loop repeat 200 collect (rnd:random-integer bound))))
      (is-true (every (lambda (n) (and (<= 0 n) (< n bound))) seen)
               "bound ~D produced something out of range" bound)
      (is-true (every #'integerp seen)))))

(test a-bound-of-one-is-always-zero
  (is (every #'zerop (loop repeat 20 collect (rnd:random-integer 1)))))

(test integers-are-not-obviously-biased-low
  ;; Rejection sampling vs modulo. With BOUND = 3 over one byte, `(mod b 3)' biases 0 and 1
  ;; upward -- 86/86/84 of 256 -- which is small but real and lands on the values an
  ;; attacker tries first. This will not detect a subtle bias, and is not meant to: it
  ;; detects an implementation that forgot entirely, which is the mistake that actually
  ;; happens.
  (let* ((n 3000)
         (counts (make-array 3 :initial-element 0)))
    (dotimes (i n) (incf (aref counts (rnd:random-integer 3))))
    (loop for c across counts
          do (is-true (< (abs (- c (/ n 3))) (* 0.15 n))
                      "bucket counts ~S look skewed over ~D draws" counts n))))

(test output-does-not-repeat
  ;; THE ticket, reduced to something checkable. 128-bit ids colliding in 2000 draws would
  ;; mean the generator is not what it says it is.
  (let ((ids (loop repeat 2000 collect (rnd:random-hex 128))))
    (is (= 2000 (length (remove-duplicates ids :test #'string=)))
        "128-bit ids must not repeat")))

(test successive-values-differ-across-every-width
  ;; Guards the degenerate implementation that returns a constant, which every test above
  ;; except the last would happily pass.
  (dolist (n '(1 4 16))
    (let ((a (rnd:random-octets n)) (b (rnd:random-octets n)))
      (is-false (equalp a b) "two draws of ~D octets were identical" n))))

(test the-weak-generator-is-unavailable-not-merely-unused
  ;; #95's second requirement. Inside aion/random, `random' is shadowed and signals, so the
  ;; file whose subject is unpredictability cannot reach MT19937 by reflex. CL:RANDOM still
  ;; works when written out, which makes reaching for it a visible decision.
  (signals error (funcall (find-symbol "RANDOM" (find-package "AION/RANDOM")) 100))
  (is-false (eq (find-symbol "RANDOM" (find-package "AION/RANDOM"))
                (find-symbol "RANDOM" (find-package "COMMON-LISP")))
            "aion/random::random must not BE cl:random"))

(test nothing-called-random-is-exported
  ;; The public surface offers no short weak path: a caller sees RANDOM-OCTETS / RANDOM-HEX
  ;; / RANDOM-INTEGER and nothing else.
  (let ((exported '()))
    (do-external-symbols (sym (find-package "AION/RANDOM")) (push (symbol-name sym) exported))
    (is-false (member "RANDOM" exported :test #'string=)
              "aion/random must not EXPORT a symbol named RANDOM; exports are ~S" exported)))
