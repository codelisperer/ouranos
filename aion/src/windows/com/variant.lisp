;;;; variant.lisp --- Lisp values across the VARIANT boundary, with ownership stated.
;;;;
;;;; A VARIANT is a tagged union: `vt' says which member of the union is live. Reading the
;;;; wrong member is not a type error, it is a reinterpretation of the same bytes -- an
;;;; IDispatch* read as an integer, or an integer read as a pointer and dereferenced. So
;;;; every read here dispatches on vt and nothing assumes.
;;;;
;;;; OWNERSHIP IS THE OTHER HALF, and it is the half that leaks. A VARIANT holding a BSTR
;;;; owns that string; a VARIANT holding an IDispatch* holds a REFERENCE that has been
;;;; AddRef'd. VariantClear is what releases either, and it is correct for every vt --
;;;; including the ones that own nothing, where it is a cheap no-op. So the rule is: every
;;;; VARIANT this file allocates is cleared on the way out, unconditionally, and
;;;; WITH-VARIANT is how that is guaranteed across a non-local exit.
;;;;
;;;; VT_BOOL is not a C bool. VARIANT_TRUE is -1 (all bits set), not 1, and a server that
;;;; receives 1 for true will usually treat it as true and occasionally not. It is written
;;;; as -1 here and read as "non-zero is true".

(in-package #:aion/windows/com)

(defconstant +variant-true+ -1)
(defconstant +variant-false+ 0)

(defmacro with-variant ((var) &body body)
  "Bind VAR to a fresh, initialised VARIANT for BODY, and VariantClear it on any exit.

VariantInit before use is required: a VARIANT is a union, and an uninitialised one has a
random vt, so the first VariantClear would try to release whatever that vt named."
  `(cffi:with-foreign-object (,var '(:struct ffi:variant))
     (ffi:variant-init ,var)
     (unwind-protect (progn ,@body)
       (ffi:variant-clear ,var))))

(defmacro with-variants ((&rest vars) &body body)
  "WITH-VARIANT for several at once."
  (if (null vars)
      `(progn ,@body)
      `(with-variant (,(first vars))
         (with-variants ,(rest vars) ,@body))))

(defun %set-vt (variant vt)
  (setf (cffi:foreign-slot-value variant '(:struct ffi:variant) 'ffi::vt) vt))

(defun %vt (variant)
  (cffi:foreign-slot-value variant '(:struct ffi:variant) 'ffi::vt))

(defun %value-pointer (variant)
  "The address of the union, which every typed accessor below reads or writes through."
  (cffi:foreign-slot-pointer variant '(:struct ffi:variant) 'ffi::value))

;;; --- by-reference [out] parameters (pre-publication issue 304) ------------------------------------------
;;;
;;; Automation members routinely hand a result back through an argument rather than the
;;; return value: ADO's `Connection.Execute(CommandText, RecordsAffected, Options)' writes
;;; the row count into its second argument; Find/Replace report what they did that way; so
;;; does much of Shell and WMI. Before this a caller could invoke those members and could
;;; not read what they wrote -- which is the difference between "the statement ran" and
;;; "it changed zero rows", and the difference between a report and a lie.
;;;
;;; A MUTABLE CELL RATHER THAN A PLACE. `(by-ref)' is passed as the argument and read after
;;; the call. A macro taking a setf-able place would read better at the call site and would
;;; have to expand around the invocation, which puts argument evaluation and the call in one
;;; macro -- more machinery, and it hides where the write happens. The write is the whole
;;; point, so it is visible: you read the cell.
;;;
;;; VT_VARIANT|VT_BYREF, not the pointed-to type. Automation declares these parameters as
;;; `VARIANT*' overwhelmingly (ADO's RecordsAffected is one), and a VARIANT* referent lets
;;; the server write whatever type it likes -- which is what it does. Passing VT_I4|VT_BYREF
;;; would work only for a server that writes exactly an I4.
(defstruct (by-ref (:constructor by-ref (&optional value))
                   (:print-object
                    (lambda (o s) (print-unreadable-object (o s :type t) (princ (by-ref-value o) s)))))
  "A cell passed to a COM member as an [out] or [in,out] parameter.

Read BY-REF-VALUE after the call. The value before the call is passed in, so the same cell
serves [in,out] -- `(by-ref 5)' arrives as 5 and holds whatever the server left."
  (value nil))

(defun lisp-to-variant (value variant)
  "Write VALUE into VARIANT, choosing the vt. VARIANT must be initialised.

The mapping is deliberately narrow. Automation accepts far more types than this, and every
one added is another way to be subtly wrong about ownership -- so the set grows when a
caller needs it, not in advance."
  (let ((p (%value-pointer variant)))
    (etypecase value
      (null            (%set-vt variant ffi:+vt-empty+))
      ;; T/NIL cannot both be booleans here: NIL is already VT_EMPTY above, which is what an
      ;; omitted argument means. So only T maps to VT_BOOL true, and a caller wanting an
      ;; explicit false passes :FALSE.
      ((eql t)         (%set-vt variant ffi:+vt-bool+)
                       (setf (cffi:mem-ref p :int16) +variant-true+))
      ((eql :false)    (%set-vt variant ffi:+vt-bool+)
                       (setf (cffi:mem-ref p :int16) +variant-false+))
      (string          (%set-vt variant ffi:+vt-bstr+)
                       (w:with-wide-string (w value)
                         ;; SysAllocString COPIES, so the wide buffer can go; the BSTR is
                         ;; now owned by the VARIANT and released by VariantClear.
                         (setf (cffi:mem-ref p :pointer) (ffi:sys-alloc-string w))))
      (double-float    (%set-vt variant ffi:+vt-r8+)
                       (setf (cffi:mem-ref p :double) value))
      (single-float    (%set-vt variant ffi:+vt-r8+)
                       (setf (cffi:mem-ref p :double) (coerce value 'double-float)))
      (integer
       ;; I4 where it fits, I8 otherwise. Servers written before 64-bit automation reject
       ;; VT_I8, so narrowing when possible is the compatible choice rather than a micro
       ;; optimisation.
       (if (typep value '(signed-byte 32))
           (progn (%set-vt variant ffi:+vt-i4+)
                  (setf (cffi:mem-ref p :int32) value))
           (progn (%set-vt variant ffi:+vt-i8+)
                  (setf (cffi:mem-ref p :int64) value)))))
    variant))

;;; --- dates and money: exact where exactness is the point ---------------------
;;;
;;; A consuming app hit all three of these on its first real database: reading an Access
;;; table of client records, EVERY date column and EVERY currency amount signalled "no Lisp
;;; mapping". It worked around them by rewriting the SELECT to cast them to text, which is
;;; the correct move against a layer that cannot carry them and the wrong thing to have to do.

(defconstant +ole-date-epoch-offset+ 2
  "OLE dates count days from 1899-12-30; CL universal time counts seconds from 1900-01-01.
Those are two days apart, and OLE date 2.0 is universal time 0.")

(defun ole-date-to-universal-time (days)
  "An OLE DATE (days since 1899-12-30, fraction = time of day) as CL universal time.

NO TIMEZONE CONVERSION IS APPLIED, and that is deliberate rather than an omission. An OLE
DATE out of a database is a NAIVE local datetime -- it carries no zone -- so shifting it by
this machine's offset would move a date of birth across midnight for anyone west of GMT and
silently change the day. The value is returned as though it were already UTC, which
round-trips exactly and never changes the calendar date.

BEFORE 1899-12-30 THE ENCODING IS NOT A NUMBER LINE (#127). The integer part counts whole
days, backwards when negative, but the fraction is always the time of day counted FORWARDS
from that day's midnight: -1.25 is 1899-12-29 06:00, not 1899-12-28 18:00. So the value is
split into its whole days and the absolute value of its fraction and rebuilt as one instant.
Arithmetic is done on the exact rational of the double, and only the final seconds are
rounded.

DATES BEFORE 1900-01-01 GIVE NEGATIVE INTEGERS. They are correct offsets from the CL epoch,
but CL defines universal time as non-negative, and DECODE-UNIVERSAL-TIME signals on them. For
those dates, or for the parts of any date without an epoch in the way, use OLE-DATE-TO-PARTS.

Returns two values: the universal time, rounded to the nearest second, and the part of a
second that rounding left out, as an exact rational between -1/2 and 1/2. Their sum is the
instant the double encodes, so nothing is lost."
  (let* ((seconds (%ole-date-seconds days))
         (universal-time (round seconds)))
    (values universal-time (- seconds universal-time))))

(defun %ole-date-instant (days)
  "An OLE DATE as an exact rational count of days since 1899-12-30 on an ordinary number line.
See OLE-DATE-TO-UNIVERSAL-TIME for why a negative date needs rebuilding."
  (let* ((exact (rational days))
         (whole (truncate exact)))
    (+ whole (abs (- exact whole)))))

(defun %ole-date-seconds (days)
  "An OLE DATE as an exact rational count of seconds since the CL epoch, 1900-01-01."
  (* (- (%ole-date-instant days) +ole-date-epoch-offset+) 86400))

(defun %civil-from-days (z)
  "Day Z counted from 1970-01-01 as (values year month day), proleptic Gregorian. The
algorithm is Howard Hinnant's civil_from_days, with FLOOR division so negative days work."
  (let* ((z (+ z 719468))
         (era (floor z 146097))
         (doe (- z (* era 146097)))
         (yoe (floor (- doe (floor doe 1460) (- (floor doe 36524)) (floor doe 146096)) 365))
         (doy (- doe (+ (* 365 yoe) (floor yoe 4) (- (floor yoe 100)))))
         (mp (floor (+ (* 5 doy) 2) 153))
         (day (1+ (- doy (floor (+ (* 153 mp) 2) 5))))
         (month (if (< mp 10) (+ mp 3) (- mp 9)))
         (year (+ yoe (* era 400) (if (<= month 2) 1 0))))
    (values year month day)))

(defun ole-date-to-parts (days)
  "An OLE DATE as (values year month day hour minute second fraction), losing nothing.

This is the date as the database stored it: a naive calendar date and time of day, with no
timezone and no epoch. It works for every OLE date, including those before 1900 that
universal time cannot represent (#127). SECOND is an integer, and FRACTION is the exact
rational part of a second the double carries, from 0 up to but not including 1. Dates are
proleptic Gregorian, as OLE Automation uses; unlike Excel's serial dates, OLE has no
1900-02-29."
  (let* ((instant (%ole-date-instant days))
         (day-number (floor instant))
         (seconds-of-day (* (- instant day-number) 86400)))
    (multiple-value-bind (year month day) (%civil-from-days (- day-number 25569))
      (multiple-value-bind (hour rest) (floor seconds-of-day 3600)
        (multiple-value-bind (minute rest) (floor rest 60)
          (multiple-value-bind (second fraction) (floor rest 1)
            (values year month day hour minute second fraction)))))))

(defun universal-time-to-ole-date (universal-time)
  "The inverse, as a double. Same naive-time caveat.

Before 1899-12-30 it builds the encoding OLE-DATE-TO-UNIVERSAL-TIME reads: the whole day,
counted backwards, minus the time of day as a positive fraction. 1899-12-29 06:00 is -1.25."
  (let* ((instant (+ (/ universal-time 86400) +ole-date-epoch-offset+))
         (day (floor instant))
         (time-of-day (- instant day)))
    (coerce (if (minusp day) (- day time-of-day) (+ day time-of-day)) 'double-float)))

(defun %currency-to-rational (scaled)
  "VT_CY is a 64-bit integer scaled by 10,000. Returned as an EXACT RATIONAL, never a float.

Money in a double is how rounding errors reach an invoice. CL has exact rationals and this is
precisely what they are for -- 12.34 arrives as 617/50 and sums without drift. A caller that
wants a float can ask for one; a caller given a float cannot get the exactness back."
  (/ scaled 10000))

(defun %decimal-to-rational (variant)
  "Read a DECIMAL, which occupies the WHOLE variant rather than its union -- see ffi.lisp.

Also exact: a 96-bit integer over a power of ten is a rational, and converting it to a double
would discard digits the database went to the trouble of storing."
  (let* ((d variant)                    ; DECIMAL starts at offset 0, overlapping vt
         (scale (cffi:foreign-slot-value d '(:struct ffi:decimal) 'ffi::scale))
         (sign (cffi:foreign-slot-value d '(:struct ffi:decimal) 'ffi::sign))
         (hi (cffi:foreign-slot-value d '(:struct ffi:decimal) 'ffi::hi32))
         (lo (cffi:foreign-slot-value d '(:struct ffi:decimal) 'ffi::lo64))
         (magnitude (/ (+ (* hi (expt 2 64)) lo) (expt 10 scale))))
    (if (logtest sign #x80) (- magnitude) magnitude)))

(defun variant-to-lisp (variant)
  "Read VARIANT as a Lisp value. Does not clear it -- the owner does that.

VT_DISPATCH is returned as a COM-OBJECT with its own reference: the pointer inside the
VARIANT dies with the VARIANT, so handing the raw pointer out would be a use-after-free the
moment the caller's WITH-VARIANT exits.

VT_DATE is returned as CL universal time, rounded to the nearest second, with the part of a
second that rounding left out as an exact rational SECOND value (see
OLE-DATE-TO-UNIVERSAL-TIME). A date before 1900-01-01 gives a NEGATIVE integer, which CL does
not define as universal time and DECODE-UNIVERSAL-TIME rejects. For those dates, or for the
calendar date and time with nothing lost, read the double with OLE-DATE-TO-PARTS. VT_CY and
VT_DECIMAL are returned as exact rationals, never floats."
  (let ((vt (%vt variant))
        (p (%value-pointer variant)))
    (cond
      ((= vt ffi:+vt-empty+) nil)
      ((= vt ffi:+vt-null+) nil)
      ((= vt ffi:+vt-bool+) (not (zerop (cffi:mem-ref p :int16))))
      ((= vt ffi:+vt-i2+) (cffi:mem-ref p :int16))
      ((= vt ffi:+vt-i4+) (cffi:mem-ref p :int32))
      ((= vt ffi:+vt-int+) (cffi:mem-ref p :int32))
      ((= vt ffi:+vt-i8+) (cffi:mem-ref p :int64))
      ((= vt ffi:+vt-ui1+) (cffi:mem-ref p :uint8))
      ((= vt ffi:+vt-ui2+) (cffi:mem-ref p :uint16))
      ((= vt ffi:+vt-ui4+) (cffi:mem-ref p :uint32))
      ((= vt ffi:+vt-ui8+) (cffi:mem-ref p :uint64))
      ((= vt ffi:+vt-r4+) (cffi:mem-ref p :float))
      ((= vt ffi:+vt-r8+) (cffi:mem-ref p :double))
      ((= vt ffi:+vt-bstr+)
       (let ((bstr (cffi:mem-ref p :pointer)))
         (unless (cffi:null-pointer-p bstr)
           ;; A BSTR may contain embedded NULs, so its LENGTH is authoritative and a
           ;; scan-to-NUL would silently truncate. SysStringLen answers in characters.
           (cffi:foreign-string-to-lisp bstr
                                        :encoding :utf-16le
                                        :count (* 2 (ffi:sys-string-len bstr))))))
      ((or (= vt ffi:+vt-dispatch+) (= vt ffi:+vt-unknown+))
       (let ((ptr (cffi:mem-ref p :pointer)))
         (unless (cffi:null-pointer-p ptr)
           (ffi:iunknown-add-ref ptr)      ; our own reference, released by RELEASE
           (%make-com-object ptr))))
      ((= vt ffi:+vt-error+) (cffi:mem-ref p :int32))
      ;; A date is a double counting days; see OLE-DATE-TO-UNIVERSAL-TIME for why no zone
      ;; conversion happens. Its second value, the part of a second rounding left out, passes
      ;; through COND and LET, so a caller that wants it gets it (#127). For dates before 1900,
      ;; or the date as calendar parts, a caller reads the double itself with OLE-DATE-TO-PARTS.
      ((= vt ffi:+vt-date+) (ole-date-to-universal-time (cffi:mem-ref p :double)))
      ;; Money, exactly. Both of these return RATIONALS on purpose.
      ((= vt ffi:+vt-cy+) (%currency-to-rational (cffi:mem-ref p :int64)))
      ((= vt ffi:+vt-decimal+) (%decimal-to-rational variant))
      (t
       ;; Named rather than silently returned as NIL: an unhandled vt is a gap in this
       ;; function, and returning NIL for it would look like the server returned nothing.
       (error 'com-error
              :detail (format nil "no Lisp mapping for VARIANT type ~D" vt))))))
