;;;; random.lisp --- the CSPRNG, in the CL shell because entropy is IO (#95).

(in-package #:aion/random)

(defun random (&rest args)
  "Shadows CL:RANDOM inside this package, and refuses.

Not a joke and not defensive programming: #95 was a placeholder that a comment promised to
replace, and the comment did not stop anyone for months. A name that ERRORS stops the next
person at the moment they reach for it, and says what to use instead in the same breath."
  (declare (ignore args))
  (error "aion/random: CL:RANDOM is not a secret generator -- SBCL's is MT19937, whose ~
state is recoverable from observed output. Use RANDOM-OCTETS, RANDOM-HEX or RANDOM-INTEGER. ~
If you genuinely want a non-cryptographic PRNG, write CL:RANDOM explicitly and say why."))

(defvar *prng* nil
  "The OS PRNG, created on first use.

Lazily rather than at load time so that a dumped image does not carry one: ironclad's
:os generator holds an open /dev/urandom stream on Unix, and a stream captured before
SAVE-LISP-AND-DIE is a closed file descriptor in the restarted image. Every executable in
this tree is dumped, so this is the ordinary case and not a corner one.")

(defvar *prng-lock* (bt:make-lock "aion-random")
  "Guards the lazy creation of *PRNG*. The generator itself is internally locked; this
only stops two threads racing to build one on the first call.")

(defun %prng ()
  (or *prng*
      (bt:with-lock-held (*prng-lock*)
        (or *prng* (setf *prng* (crypto:make-prng :os))))))

(defun random-octets (n)
  "N cryptographically secure random octets, as an (unsigned-byte 8) vector.

The primitive; everything else here is a rendering of it."
  (check-type n (integer 0 *))
  (if (zerop n)
      (make-array 0 :element-type '(unsigned-byte 8))
      (crypto:random-data n (%prng))))

(defun random-hex (bits)
  "BITS of entropy as a lowercase hex string, zero-padded to the full width.

BITS must be a positive multiple of 8, so that the string is exactly the entropy it
claims: asking for 130 bits and rendering 33 nibbles would produce a string whose length
implies 132. A caller who wants an odd width should say which they meant."
  (check-type bits (integer 8 *))
  (unless (zerop (mod bits 8))
    (error "aion/random: BITS must be a multiple of 8 -- got ~D" bits))
  (let ((octets (random-octets (floor bits 8))))
    (string-downcase
     (with-output-to-string (out)
       (loop for b across octets do (format out "~2,'0X" b))))))

(defun random-integer (bound)
  "A uniformly distributed integer in [0, BOUND).

REJECTION SAMPLING, not modulo. Taking `(mod n bound)' over random bytes biases the low
values whenever BOUND is not a power of two -- small, but it is a bias in exactly the
values an attacker would try first, and it costs nothing to avoid."
  (check-type bound (integer 1 *))
  (if (= bound 1)
      0
      (let* ((bits (integer-length (1- bound)))
             (bytes (ceiling bits 8))
             (limit (ash 1 bits)))
        (loop
          (let ((n (logand (1- limit)
                           (loop with acc = 0
                                 for b across (random-octets bytes)
                                 do (setf acc (+ (ash acc 8) b))
                                 finally (return acc)))))
            (when (< n bound) (return n)))))))
