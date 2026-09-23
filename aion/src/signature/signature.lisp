;;;; signature.lisp --- verify a detached Ed25519 signature over bytes.
;;;;
;;;; THE ONE DESIGN DECISION WORTH READING BEFORE THE CODE:
;;;;
;;;;   A BAD SIGNATURE IS DATA. A BAD KEY IS A BUG.
;;;;
;;;; VERIFY returns NIL for anything that fails to verify -- a forged signature, a truncated
;;;; one, a signature over different bytes, arbitrary garbage. It does not signal, because a
;;;; caller must be able to write `(if (verify ...) ...)' without a handler around it. A
;;;; verification path where the failure case can arrive as either NIL or a condition is one
;;;; where somebody eventually handles only one of them, and the half they miss is the half
;;;; that lets a bad artifact through.
;;;;
;;;; A MALFORMED KEY signals instead. A 31-byte public key is not "a signature that did not
;;;; verify" -- it is a configuration or build error, and returning NIL for it would make
;;;; "this key is broken so nothing can ever verify" indistinguishable from "this artifact
;;;; was tampered with". The first needs someone to fix a deployment; the second needs
;;;; someone to sound an alarm. They must not look the same.
;;;;
;;;; That asymmetry is the whole of this file's opinion. Everything else is plumbing.

(in-package #:aion/signature)

(defconstant +key-length+ 32
  "Ed25519 keys are 32 bytes, public and private alike.")

(defconstant +signature-length+ 64
  "Ed25519 signatures are 64 bytes. Checked before the library sees them so a truncated
signature is a clean NIL rather than whatever ironclad decides to do with it.")

;;; --- conditions ---------------------------------------------------------------

(define-condition signature-error (error) ()
  (:documentation "Base of the errors this module signals. A failed VERIFY is not one."))

(define-condition malformed-key (signature-error)
  ((detail :initarg :detail :initform nil :reader malformed-key-detail))
  (:report (lambda (c stream)
             (format stream "aion/signature: ~A" (malformed-key-detail c))))
  (:documentation "A key was not what a key has to be. Deliberately an ERROR and not a NIL
return: a broken key means nothing can ever verify, which is a different emergency from a
signature that did not check out."))

;;; --- keys ----------------------------------------------------------------------
;;;
;;; Wrapped rather than passing ironclad's objects around. Two reasons, both small and both
;;; real: a caller reading a key from configuration should get a check at the point of
;;; DECODING rather than at first use, and the wrapper keeps ironclad out of every consumer's
;;; type declarations, so replacing it later is this file's problem rather than everyone's.

(defstruct (public-key (:constructor %make-public-key (object bytes)) (:copier nil))
  "An Ed25519 public key. Verifies; cannot sign."
  (object nil :read-only t)
  (bytes nil :read-only t))

(defstruct (private-key (:constructor %make-private-key (object bytes public)) (:copier nil))
  "An Ed25519 private key, with its public half.

Printed opaquely on purpose -- see the PRINT-OBJECT method below."
  (object nil :read-only t)
  (bytes nil :read-only t)
  (public nil :read-only t))

(defmethod print-object ((k private-key) stream)
  "Never print the key material.

A private key reaching a log, a REPL transcript or a backtrace is a disclosure, and the
default structure printer would put all 32 bytes of it in any of those. This is the cheapest
possible mitigation and it costs nothing at a REPL, where the useful information is that the
object IS a private key rather than what it contains."
  (print-unreadable-object (k stream :type t)
    (format stream "~A" "[redacted]")))

(defun %check-bytes (bytes what)
  "BYTES as a fresh octet vector, or a signalled MALFORMED-KEY.

THE ELEMENT TYPE IS CHECKED, NOT JUST THE LENGTH, and that is not pedantry. A 32-character
STRING is a sequence of length 32, so a length-only check passes it and the COERCE below
signals a bare TYPE-ERROR -- not the MALFORMED-KEY every caller of this module was promised.

And a 32-character string is not a hypothetical input. It is what you have when you hand
base64 TEXT to PUBLIC-KEY-FROM-BYTES instead of to DECODE-PUBLIC-KEY, which is the single
easiest mistake to make with this API. It has to arrive as the condition that says so."
  (unless (typep bytes 'sequence)
    (error 'malformed-key
           :detail (format nil "~A must be ~D bytes, got ~A"
                           what +key-length+ (type-of bytes))))
  (unless (= (length bytes) +key-length+)
    (error 'malformed-key
           :detail (format nil "~A must be ~D bytes, got ~D"
                           what +key-length+ (length bytes))))
  (or (ignore-errors (coerce bytes '(vector (unsigned-byte 8))))
      (error 'malformed-key
             :detail (format nil "~A must be ~D BYTES; got ~D elements of ~A, which are not bytes"
                             what +key-length+ (length bytes) (type-of bytes)))))

(defun public-key-from-bytes (bytes)
  "A public key from its 32 raw bytes. Signals MALFORMED-KEY if they are not 32."
  (let ((b (%check-bytes bytes "a public key")))
    (%make-public-key (ironclad:make-public-key :ed25519 :y b) b)))

(defun private-key-from-bytes (bytes)
  "A private key from its 32 raw seed bytes. Signals MALFORMED-KEY if they are not 32.

The public half is DERIVED rather than accepted alongside. Taking both would allow a caller
to supply a mismatched pair, which produces signatures that verify against nothing and a very
confusing afternoon."
  (let* ((b (%check-bytes bytes "a private key"))
         (private (ironclad:make-private-key :ed25519 :x b))
         (public-bytes (ironclad:ed25519-key-y private)))
    (%make-private-key private b (public-key-from-bytes public-bytes))))

(defun generate-key-pair ()
  "A fresh key pair, as (values PRIVATE-KEY PUBLIC-KEY).

Here so a signing side -- CI minting a release key, a test -- does not have to reach into
ironclad. It is NOT key management: where the private key then goes, how it is stored and
when it is rotated are the caller's, and differ per consumer."
  (multiple-value-bind (private public) (ironclad:generate-key-pair :ed25519)
    (declare (ignore public))
    (let ((k (private-key-from-bytes (ironclad:ed25519-key-x private))))
      (values k (private-key-public k)))))

(defun public-key-of (private-key)
  "The public half of PRIVATE-KEY."
  (private-key-public private-key))

;;; --- text encoding --------------------------------------------------------------
;;;
;;; ONE encoding, not a choice of several. Keys travel as text -- a CI secret, a manifest
;;; field, an environment variable -- and base64 is what those carry. Offering hex as well
;;; would mean every consumer decides, every decoder guesses, and a key pasted in the wrong
;;; form fails somewhere less obvious than here. Standard base64: 32 bytes is 44 characters
;;; with one `=' of padding, which is also a cheap eyeball check.

(defun encode-key (key)
  "KEY as base64 text. Accepts a public or a private key."
  (cl-base64:usb8-array-to-base64-string
   (etypecase key
     (public-key (public-key-bytes key))
     (private-key (private-key-bytes key)))))

(defun %decode (text what)
  (let ((bytes (handler-case (cl-base64:base64-string-to-usb8-array text)
                 (error (e)
                   (error 'malformed-key
                          :detail (format nil "~A is not valid base64: ~A" what e))))))
    (%check-bytes bytes what)))

(defun decode-public-key (text)
  "A public key from base64 TEXT. Signals MALFORMED-KEY on anything that is not one."
  (public-key-from-bytes (%decode text "a public key")))

(defun decode-private-key (text)
  "A private key from base64 TEXT. Signals MALFORMED-KEY on anything that is not one."
  (private-key-from-bytes (%decode text "a private key")))

;;; --- the primitive ---------------------------------------------------------------

(defun sign (private-key bytes)
  "The detached Ed25519 signature over BYTES, as 64 bytes.

BYTES is a byte vector, not a string. Encoding a string is an ENVELOPE decision -- which
encoding, whether a trailing newline counts, whether the payload is canonicalised first --
and getting it wrong on one side of a signature produces a verification failure with no clue
in it. So the caller states it, at the point where they know the answer."
  (check-type private-key private-key)
  (ironclad:sign-message (private-key-object private-key)
                         (coerce bytes '(vector (unsigned-byte 8)))))

(defun verify (public-key bytes signature)
  "True when SIGNATURE is a valid Ed25519 signature over BYTES under PUBLIC-KEY.

RETURNS A BOOLEAN AND DOES NOT SIGNAL for any input that simply fails to verify -- a forged
signature, a truncated one, a signature over other bytes, or arbitrary rubbish. See this
file's header: a caller must be able to write `(if (verify ...) ...)' with no handler, or
the failure case eventually arrives by a route somebody did not cover.

A malformed PUBLIC-KEY is the exception, and it signals, because it is not a verification
failure at all -- it is a deployment that can never verify anything, and it must not be
mistaken for a tampered artifact."
  (check-type public-key public-key)
  (let ((sig (ignore-errors (coerce signature '(vector (unsigned-byte 8))))))
    (and sig
         (= (length sig) +signature-length+)
         ;; ironclad signals on some malformed inputs rather than returning NIL. Both mean
         ;; the same thing here and both must arrive as NIL.
         (handler-case
             (and (ironclad:verify-signature (public-key-object public-key)
                                             (coerce bytes '(vector (unsigned-byte 8)))
                                             sig)
                  t)
           (error () nil)))))
