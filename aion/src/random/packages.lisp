;;;; packages.lisp --- aion/random: unpredictable bytes, from the OS (#95).

(cl:defpackage #:aion/random
  (:use #:cl)
  ;; SHADOWED, not merely unused. Inside this package `random' is OURS and signals, so the
  ;; one file in the tree whose whole subject is unpredictability cannot reach the weak
  ;; generator by reflex or by a merge. Writing CL:RANDOM here still works and is now a
  ;; deliberate, visible act -- which is the distinction #95 asked for.
  (:shadow #:random)
  (:local-nicknames (#:crypto #:ironclad))
  (:documentation
   "A cryptographically secure random source, and NOTHING that looks like `cl:random'.

    WHY THIS EXISTS. `cl:random' on SBCL is MT19937 -- a Mersenne Twister. It is a fine
    general-purpose PRNG and it is not a secret generator: its internal state is
    RECOVERABLE from enough observed output, after which every future value is known. How
    well it was seeded does not matter, because the attack is on the output, not the seed.

    That is fatal for anything an attacker can both OBSERVE and BENEFIT from predicting --
    a session id is the clearest case, since it is handed to the viewer as a cookie by
    design, so the output is public by construction. (#95: hyperion minted session ids
    this way, under a docstring promising 128 bits of entropy.)

    THE API IS NAMED SO THE WEAK ONE CANNOT BE REACHED FOR BY ACCIDENT. There is no
    function called `random' here. Someone wanting \"a random hex string\" finds
    RANDOM-HEX and gets a CSPRNG; there is no shorter path that is wrong. That is the
    point of the naming, not tidiness -- the original defect arrived as a placeholder that
    a comment promised to fix later, and comments do not stop the next person.

    WHERE THE BYTES COME FROM. Ironclad's `:os' PRNG: /dev/urandom on Unix,
    CryptGenRandom on Windows SBCL. The OS generator rather than a userspace one, so
    there is no long-lived state of ours to seed correctly, snapshot into a dumped image,
    or fork across.

    NOT FOR SORTABLE IDS. aion/clock mints time-ordered v6 UUIDs, which are PARTLY
    PREDICTABLE BY DESIGN -- the timestamp half is monotonic and that is the whole feature.
    They must never be used as a secret, and swapping their RNG would not change that; see
    the note in aion/clock. Unpredictability and sortability are different primitives.")
  (:export #:random-octets #:random-hex #:random-integer))
