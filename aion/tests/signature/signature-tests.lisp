;;;; signature-tests.lisp --- the primitive, and the ways it must fail.
;;;;
;;;; A verification test that only checks "a good signature verifies" is worth very little:
;;;; a VERIFY that returned T unconditionally would pass it. Most of what is below is the
;;;; other direction -- the specific things that must come back NIL, and the specific things
;;;; that must signal instead.

(in-package #:aion/signature/tests)

(def-suite all :description "Ed25519 detached signatures over bytes.")
(in-suite all)

(defun bytes (string)
  (sb-ext:string-to-octets string :external-format :utf-8))

;;; --- the happy path, briefly -----------------------------------------------

(test a-signature-verifies
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (let* ((message (bytes "the quick brown fox"))
           (signature (sig:sign private message)))
      (is (= sig:+signature-length+ (length signature)))
      (is-true (sig:verify public message signature)))))

(test verify-returns-a-boolean-not-a-truthy-object
  "Callers write (if (verify ...)), and a leaked internal object would still be true --
until the day it is not."
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (let ((s (sig:sign private (bytes "x"))))
      (is (eq t (sig:verify public (bytes "x") s))))))

;;; --- the failures that must be NIL, not conditions --------------------------

(test a-tampered-message-does-not-verify
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (let ((s (sig:sign private (bytes "transfer 100"))))
      (is-false (sig:verify public (bytes "transfer 900") s)))))

(test a-single-flipped-bit-does-not-verify
  "The whole point. If this passes with a flipped bit the signature is decorative."
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (let* ((message (bytes "release-1.2.3"))
           (s (copy-seq (sig:sign private message))))
      (setf (aref s 0) (logxor (aref s 0) 1))
      (is-false (sig:verify public message s)))))

(test another-key-does-not-verify
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (declare (ignore public))
    (multiple-value-bind (other-private other-public) (sig:generate-key-pair)
      (declare (ignore other-private))
      (let ((s (sig:sign private (bytes "hello"))))
        (is-false (sig:verify other-public (bytes "hello") s))))))

(test a-truncated-signature-does-not-verify-and-does-not-signal
  "An attacker supplies the signature, so its length is untrusted input. A wrong length
must be a clean NIL -- if it signalled, a caller who wrote (if (verify ...)) would get a
crash where they expected a decision."
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (let ((s (sig:sign private (bytes "hello"))))
      (is-false (sig:verify public (bytes "hello") (subseq s 0 32)))
      (is-false (sig:verify public (bytes "hello") #())))))

(test rubbish-in-the-signature-slot-does-not-signal
  "Every one of these is something a hostile or broken input could supply."
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (declare (ignore private))
    (dolist (junk (list #() (make-array 64 :initial-element 0) "not bytes at all" nil 42))
      (finishes (sig:verify public (bytes "hello") junk))
      (is-false (sig:verify public (bytes "hello") junk)
                "~S should not verify" junk))))

(test rubbish-in-the-message-slot-does-not-signal-either
  "The contract is about VERIFY as a whole, not only about its signature argument. BYTES is
just as much untrusted input -- it is whatever the caller believes was signed -- and a caller
who wrote (if (verify ...)) must not get a condition from either slot.

Stated separately because the two arguments take different paths through the function and a
refactor could easily fix one and reintroduce signalling on the other."
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (let ((s (sig:sign private (bytes "hello"))))
      (dolist (junk (list "not bytes at all" 42 nil (list 1 2 999) #(1000 2000)))
        (finishes (sig:verify public junk s))
        (is-false (sig:verify public junk s) "~S should not verify" junk)))))

(test an-empty-message-still-signs-and-verifies
  "Zero bytes is a legitimate message and an easy off-by-one."
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (let ((s (sig:sign private #())))
      (is-true (sig:verify public #() s))
      (is-false (sig:verify public (bytes "x") s)))))

;;; --- the failures that must SIGNAL, not return NIL --------------------------

(test a-malformed-key-signals-rather-than-failing-quietly
  "THE DESIGN DECISION THIS MODULE MAKES. A 31-byte key means nothing can ever verify --
a deployment that is broken -- and returning NIL would make it indistinguishable from an
artifact that was tampered with. One needs a fix; the other needs an alarm."
  (signals sig:malformed-key (sig:public-key-from-bytes (make-array 31 :initial-element 0)))
  (signals sig:malformed-key (sig:public-key-from-bytes (make-array 33 :initial-element 0)))
  (signals sig:malformed-key (sig:private-key-from-bytes #()))
  (signals sig:malformed-key (sig:public-key-from-bytes 42)))

(test a-key-of-the-right-length-but-the-wrong-element-type-signals
  "THE CASE A LENGTH CHECK LETS THROUGH. A 32-character string IS a sequence of length 32, so
checking only the length passes it and COERCE then signals a bare TYPE-ERROR -- which is not
the condition this module tells its callers to handle.

It is also the likeliest real mistake with this API: base64 TEXT handed to
PUBLIC-KEY-FROM-BYTES rather than to DECODE-PUBLIC-KEY. 44 characters would be caught by the
length check; a 32-character key file read as a string would not."
  (signals sig:malformed-key
    (sig:public-key-from-bytes (make-string 32 :initial-element #\a)))
  (signals sig:malformed-key
    (sig:private-key-from-bytes (make-string 32 :initial-element #\a)))
  ;; a list of 32 numbers that are not bytes is the same class of wrong
  (signals sig:malformed-key
    (sig:public-key-from-bytes (make-list 32 :initial-element 999)))
  ;; and the control: 32 real bytes in a plain list is FINE, so the test above is about the
  ;; element type rather than about rejecting anything that is not a vector.
  (finishes (sig:public-key-from-bytes (make-list 32 :initial-element 7))))

(test a-malformed-key-says-what-was-wrong
  "The report has to be actionable -- someone reads it in a CI log with no debugger."
  (handler-case (progn (sig:public-key-from-bytes (make-array 31 :initial-element 0)) nil)
    (sig:malformed-key (c)
      (let ((text (princ-to-string c)))
        (is-true (search "32" text) "should say the expected length: ~S" text)
        (is-true (search "31" text) "should say what it got: ~S" text)))))

(test bad-base64-signals-as-a-malformed-key
  (signals sig:malformed-key (sig:decode-public-key "this is not base64 !!!"))
  (signals sig:malformed-key (sig:decode-public-key "c2hvcnQ=")))   ; valid base64, 5 bytes

;;; --- encoding ---------------------------------------------------------------

(test keys-round-trip-through-base64
  "The form a key travels in: a CI secret, a manifest field, an environment variable."
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (let ((pub (sig:decode-public-key (sig:encode-key public)))
          (priv (sig:decode-private-key (sig:encode-key private))))
      (is (equalp (sig:public-key-bytes public) (sig:public-key-bytes pub)))
      (is (equalp (sig:private-key-bytes private) (sig:private-key-bytes priv)))
      ;; and the round-tripped pair still works together
      (is-true (sig:verify pub (bytes "hi") (sig:sign priv (bytes "hi")))))))

(test an-encoded-public-key-is-44-characters
  "32 bytes in standard base64. Stated because it is the cheapest eyeball check that
somebody has pasted a key rather than a fingerprint or half of one."
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (declare (ignore private))
    (is (= 44 (length (sig:encode-key public))))))

(test keys-round-trip-through-raw-bytes
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (let ((pub (sig:public-key-from-bytes (sig:public-key-bytes public)))
          (priv (sig:private-key-from-bytes (sig:private-key-bytes private))))
      (is-true (sig:verify pub (bytes "hi") (sig:sign priv (bytes "hi")))))))

(test the-public-half-is-derived-not-supplied
  "PRIVATE-KEY-FROM-BYTES derives the public key rather than accepting one, so a mismatched
pair -- which signs things that verify against nothing -- cannot be constructed."
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (let ((rebuilt (sig:private-key-from-bytes (sig:private-key-bytes private))))
      (is (equalp (sig:public-key-bytes public)
                  (sig:public-key-bytes (sig:public-key-of rebuilt)))))))

;;; --- disclosure -------------------------------------------------------------

(test a-private-key-does-not-print-its-material
  "A private key reaching a log, a REPL transcript or a backtrace is a disclosure, and the
default structure printer would put all 32 bytes into any of them."
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (declare (ignore public))
    (let ((printed (princ-to-string private))
          (raw (sig:private-key-bytes private)))
      (is-true (search "redacted" printed) "printed as: ~A" printed)
      ;; no byte of the key should appear as a number in the printed form
      (is-false (search (princ-to-string (aref raw 0)) printed)
                "the printed form contains key material: ~A" printed))))
