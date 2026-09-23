;;;; variant-tests.lisp --- the types a real database actually contains.
;;;;
;;;; These construct VARIANTs directly rather than obtaining them from a server, which makes
;;;; them fast, deterministic, and runnable with no Office and no database installed. The
;;;; conversion is the thing under test; getting a VARIANT is not.
;;;;
;;;; WHY THESE THREE. A consuming app reading an Access table of client records hit all of
;;;; them on its first real query: VT_DATE, VT_CY and VT_DECIMAL all signalled "no Lisp
;;;; mapping for VARIANT type N", which for a financial-services database is every date
;;;; column and every currency amount. It worked around them by rewriting the SELECT to cast
;;;; the columns to text -- the right move against a layer that cannot carry them, and the
;;;; wrong thing to have to do.

(in-package #:aion/windows/com/tests)

(def-suite variants :description "VARIANT conversions, especially dates and money." :in all)
(in-suite variants)

(defmacro with-typed-variant ((var vt) &body body)
  "A VARIANT with VT set and its payload writable at offset 8."
  `(com:with-variant (,var)
     (setf (cffi:foreign-slot-value ,var '(:struct ffi:variant) 'ffi::vt) ,vt)
     ,@body))

(defun payload (v) (cffi:foreign-slot-pointer v '(:struct ffi:variant) 'ffi::value))

;;; --- dates -------------------------------------------------------------------

(test an-ole-date-becomes-universal-time
  "OLE counts days from 1899-12-30; CL counts seconds from 1900-01-01. Two days apart, so
OLE 2.0 is universal time 0 -- the cheapest possible check that the epoch is right."
  (is (= 0 (com:ole-date-to-universal-time 2.0d0))))

(test a-real-date-lands-on-the-right-second
  "1970-01-01 is OLE day 25569. If the epoch offset were wrong by one day this is off by
86400 and every date in a database is a day out -- which is the kind of wrong that gets
noticed by a customer rather than by a test."
  (is (= 2208988800 (com:ole-date-to-universal-time 25569.0d0)))
  (multiple-value-bind (s m h date month year)
      (decode-universal-time (com:ole-date-to-universal-time 25569.0d0) 0)
    (declare (ignore s m h))
    (is (= 1 date)) (is (= 1 month)) (is (= 1970 year))))

(test the-fractional-part-is-the-time-of-day
  "0.5 of a day is noon. A layer that truncated to whole days would pass every date test and
lose every appointment time."
  (multiple-value-bind (s m h)
      (decode-universal-time (com:ole-date-to-universal-time 25569.5d0) 0)
    (declare (ignore s m))
    (is (= 12 h))))

(test dates-round-trip
  (dolist (ut (list 0 2208988800 3800000000))
    (is (= ut (com:ole-date-to-universal-time (com:universal-time-to-ole-date ut)))
        "~D did not survive the round trip" ut)))

(test a-vt-date-variant-converts
  (with-typed-variant (v ffi:+vt-date+)
    (setf (cffi:mem-ref (payload v) :double) 25569.0d0)
    (is (= 2208988800 (com:variant-to-lisp v)))))

;;; --- money, and it must be exact ---------------------------------------------

(test currency-is-exact-not-floating
  "VT_CY is an integer scaled by 10,000. Money in a double is how rounding error reaches an
invoice, so this must be a RATIONAL -- and the test asserts the TYPE, not just the value,
because 12.34d0 would print convincingly and be wrong."
  (with-typed-variant (v ffi:+vt-cy+)
    (setf (cffi:mem-ref (payload v) :int64) 123400)      ; 12.3400
    (let ((x (com:variant-to-lisp v)))
      (is (rationalp x) "currency came back as ~S, a ~A" x (type-of x))
      (is-false (floatp x))
      (is (= 617/50 x))
      (is (= 1234/100 x)))))

(test currency-sums-without-drift
  "The reason exactness is not pedantry: a hundred additions of 0.10 must be exactly 10."
  (let ((cents 1000))                                    ; 0.1000
    (with-typed-variant (v ffi:+vt-cy+)
      (setf (cffi:mem-ref (payload v) :int64) cents)
      (let ((tenth (com:variant-to-lisp v)))
        (is (= 10 (loop repeat 100 sum tenth)))))))

(test negative-currency
  (with-typed-variant (v ffi:+vt-cy+)
    (setf (cffi:mem-ref (payload v) :int64) -50000)
    (is (= -5 (com:variant-to-lisp v)))))

;;; --- DECIMAL, which overlaps the variant itself -------------------------------

(defmacro with-decimal-variant ((var scale sign hi lo) &body body)
  "Build a VT_DECIMAL variant. NOTE THE OFFSETS: a DECIMAL occupies the whole VARIANT, so
its wReserved field IS the vt at offset 0 and the payload starts at 2 -- not at 8 like every
other type. Written out longhand here precisely because that is the trap."
  `(com:with-variant (,var)
     (setf (cffi:mem-ref ,var :uint16) ffi:+vt-decimal+)              ; offset 0 = vt/wReserved
     (setf (cffi:mem-ref (cffi:inc-pointer ,var 2) :uint8) ,scale)    ; offset 2
     (setf (cffi:mem-ref (cffi:inc-pointer ,var 3) :uint8) ,sign)     ; offset 3
     (setf (cffi:mem-ref (cffi:inc-pointer ,var 4) :uint32) ,hi)      ; offset 4
     (setf (cffi:mem-ref (cffi:inc-pointer ,var 8) :uint64) ,lo)      ; offset 8
     ,@body))

(test a-decimal-converts-exactly
  (with-decimal-variant (v 2 0 0 1234)
    (let ((x (com:variant-to-lisp v)))
      (is (rationalp x))
      (is (= 617/50 x)))))

(test a-negative-decimal
  (with-decimal-variant (v 2 #x80 0 1234)
    (is (= -617/50 (com:variant-to-lisp v)))))

(test a-decimal-wider-than-64-bits
  "The whole point of DECIMAL is 96 bits of integer. If Hi32 were ignored this reads as the
low 64 bits alone and is quietly, enormously wrong."
  (with-decimal-variant (v 0 0 1 0)
    (is (= (expt 2 64) (com:variant-to-lisp v)))))

(test a-decimal-keeps-digits-a-double-would-lose
  "18 significant digits: a double carries about 15-16. This is the case where converting to
a float silently discards data the database went to the trouble of storing."
  (with-decimal-variant (v 0 0 0 123456789012345678)
    (is (= 123456789012345678 (com:variant-to-lisp v)))))

;;; --- and the failure mode still fails ----------------------------------------

(test an-unmapped-variant-type-still-signals
  "Adding three types must not turn the honest error into a silent NIL for the fourth."
  (with-typed-variant (v 36)                             ; VT_RECORD -- deliberately unhandled
    (signals com:com-error (com:variant-to-lisp v))))
