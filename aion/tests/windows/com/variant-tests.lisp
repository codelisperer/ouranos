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

;;; --- the edges of dates and money (#127) ---------------------------------------
;;;
;;; Before 1899-12-30 an OLE date's integer part counts days backwards and its fraction still
;;; counts the time of day forwards, so -1.25 is 1899-12-29 06:00. DECODE-UNIVERSAL-TIME
;;; rejects the negative universal times these dates give, so the expected values below are
;;; the seconds, worked out by hand: universal time 0 is 1900-01-01 00:00.

(test dates-before-the-ole-epoch-count-the-time-of-day-forwards
  (dolist (case '((0.0d0   -172800)        ; 1899-12-30 00:00
                  (1.0d0   -86400)         ; 1899-12-31 00:00
                  (1.5d0   -43200)         ; 1899-12-31 12:00
                  (0.5d0   -129600)        ; 1899-12-30 12:00
                  (-0.5d0  -129600)        ; the same instant: OLE writes it both ways
                  (-1.0d0  -259200)        ; 1899-12-29 00:00
                  (-1.25d0 -237600)        ; 1899-12-29 06:00, not 1899-12-28 18:00
                  (-1.75d0 -194400)))      ; 1899-12-29 18:00
    (destructuring-bind (ole expected) case
      (is (= expected (com:ole-date-to-universal-time ole))
          "OLE ~S gave universal time ~S, expected ~S" ole (com:ole-date-to-universal-time ole)
          expected))))

(test dates-before-the-ole-epoch-round-trip
  "The inverse has to write the same odd encoding back: 1899-12-29 06:00 is -1.25, and an
inverse that treated the value as an ordinary number line would write -1.75."
  (dolist (case '((-237600 -1.25d0) (-194400 -1.75d0) (-259200 -1.0d0) (-172800 0.0d0)))
    (destructuring-bind (ut ole) case
      (is (= ole (com:universal-time-to-ole-date ut))
          "universal time ~S gave OLE ~S, expected ~S" ut (com:universal-time-to-ole-date ut) ole))))

(test midnight-is-exactly-midnight
  (let ((ut (com:ole-date-to-universal-time 36526.0d0)))          ; 2000-01-01 00:00:00
    (is (= 3155673600 ut))
    (multiple-value-bind (s m h) (decode-universal-time ut 0)
      (is (and (= 0 s) (= 0 m) (= 0 h)) "midnight decoded as ~D:~D:~D" h m s))))

(test the-part-of-a-second-rounding-drops-is-returned-exactly
  "OLE-DATE-TO-UNIVERSAL-TIME rounds to the nearest second and returns what rounding left out
as its second value, so the two together are the instant the double encodes. 1/2^20 of a day
is exactly representable, which makes the expected remainder exact too: 86400/2^20 seconds."
  (let ((ole (+ 25569 (/ 1d0 (expt 2 20)))))
    (multiple-value-bind (ut rest) (com:ole-date-to-universal-time ole)
      (is (= 2208988800 ut))
      (is (rationalp rest) "the remainder came back as ~S, a ~A" rest (type-of rest))
      (is (= (/ 86400 (expt 2 20)) rest))
      (is (= (* (- (rational ole) 2) 86400) (+ ut rest))
          "universal time plus remainder must be the exact instant"))))

(test a-vt-date-variant-carries-the-remainder-too
  (with-typed-variant (v ffi:+vt-date+)
    (setf (cffi:mem-ref (payload v) :double) (+ 25569 (/ 1d0 (expt 2 20))))
    (multiple-value-bind (ut rest) (com:variant-to-lisp v)
      (is (= 2208988800 ut))
      (is (= (/ 86400 (expt 2 20)) rest)))))

(defun %parts (ole) (multiple-value-list (com:ole-date-to-parts ole)))

(test ole-date-parts-are-the-calendar-date-and-time
  (dolist (case '((0.0d0      (1899 12 30 0 0 0 0))
                  (-1.25d0    (1899 12 29 6 0 0 0))
                  (-1.75d0    (1899 12 29 18 0 0 0))
                  (36526.0d0  (2000 1 1 0 0 0 0))
                  (36585.0d0  (2000 2 29 0 0 0 0))            ; a leap day
                  (60.0d0     (1900 2 28 0 0 0 0))            ; OLE has no 1900-02-29:
                  (61.0d0     (1900 3 1 0 0 0 0))             ; day 61 is March 1st
                  (-657434.0d0 (100 1 1 0 0 0 0))             ; the earliest OLE date
                  (2958465.0d0 (9999 12 31 0 0 0 0))          ; the last day of the range
                  (25569.5d0  (1970 1 1 12 0 0 0))))
    (destructuring-bind (ole expected) case
      (is (equal expected (%parts ole)) "OLE ~S gave ~S, expected ~S" ole (%parts ole) expected))))

(test ole-date-parts-keep-the-fraction-of-a-second-exactly
  (destructuring-bind (y mo d h mi s fraction) (%parts (+ 25569 (/ 1d0 (expt 2 20))))
    (is (equal '(1970 1 1 0 0 0) (list y mo d h mi s)))
    (is (= (/ 86400 (expt 2 20)) fraction) "fraction ~S" fraction)))

(test currency-at-the-limits-of-its-64-bits
  "VT_CY's range is the signed 64-bit integer divided by 10,000. The extremes must come back
exactly, which a double cannot do: it has 53 bits of mantissa."
  (dolist (case (list (list (- (expt 2 63)) (/ (- (expt 2 63)) 10000))
                      (list (1- (expt 2 63)) (/ (1- (expt 2 63)) 10000))
                      (list 1 1/10000)
                      (list 0 0)))
    (destructuring-bind (scaled expected) case
      (with-typed-variant (v ffi:+vt-cy+)
        (setf (cffi:mem-ref (payload v) :int64) scaled)
        (is (eql expected (com:variant-to-lisp v)))))))

(test decimal-at-the-limits-of-its-96-bits-and-scale
  (with-decimal-variant (v 0 0 #xFFFFFFFF #xFFFFFFFFFFFFFFFF)       ; the largest magnitude
    (is (= (1- (expt 2 96)) (com:variant-to-lisp v))))
  (with-decimal-variant (v 28 0 #xFFFFFFFF #xFFFFFFFFFFFFFFFF)      ; the same, at the largest scale
    (is (= (/ (1- (expt 2 96)) (expt 10 28)) (com:variant-to-lisp v))))
  (with-decimal-variant (v 28 0 0 1)                                ; the smallest positive value
    (is (= (/ 1 (expt 10 28)) (com:variant-to-lisp v))))
  (with-decimal-variant (v 28 #x80 #xFFFFFFFF #xFFFFFFFFFFFFFFFF)   ; the most negative
    (is (= (- (/ (1- (expt 2 96)) (expt 10 28))) (com:variant-to-lisp v))))
  (with-decimal-variant (v 2 #x80 0 0)                              ; negative zero is zero
    (is (eql 0 (com:variant-to-lisp v)))))

(test the-largest-ole-date-is-the-last-second-of-9999
  "OLE's range ends at 9999-12-31 23:59:59. That instant must arrive as the right universal
time, and the parts accessor must name it."
  (let ((ole (+ 2958465 (/ 86399 86400d0))))
    (is (= (encode-universal-time 59 59 23 31 12 9999 0) (com:ole-date-to-universal-time ole)))
    (is (equal '(9999 12 31 23 59) (subseq (%parts ole) 0 5)))))

(test ole-date-parts-agree-with-decode-universal-time-where-both-apply
  "Where universal time can represent the date, the two readings of one double must agree."
  (dolist (ut (list 0 (encode-universal-time 0 0 0 29 2 2000 0) 2208988800
                    (encode-universal-time 59 59 23 31 12 2099 0) 3800000000))
    (let ((ole (com:universal-time-to-ole-date ut)))
      (multiple-value-bind (s mi h d mo y) (decode-universal-time ut 0)
        (destructuring-bind (py pmo pd ph pmi ps fraction) (%parts ole)
          ;; The double may sit a hair either side of the second; compare to the nearest one.
          (let ((pseconds (+ (* 3600 ph) (* 60 pmi) ps (round fraction))))
            (is (equal (list y mo d (+ (* 3600 h) (* 60 mi) s)) (list py pmo pd pseconds))
                "universal time ~D: decode says ~S, parts say ~S" ut
                (list y mo d h mi s) (%parts ole))))))))

(test a-decimal-zero-is-zero
  (with-decimal-variant (v 0 0 0 0)
    (is (eql 0 (com:variant-to-lisp v)))))
