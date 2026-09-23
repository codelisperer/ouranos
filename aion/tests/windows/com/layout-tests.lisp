;;;; layout-tests.lisp --- the cl-win32ole defect, reproduced and caught.
;;;;
;;;; ADR-0003 s4 exists because of one bug: VARIANT sized at 16 bytes, right on x86 and
;;;; wrong on x64 where it is 24, which under-allocated the argument array and made every
;;;; call with two or more arguments read garbage as pointers.
;;;;
;;;; A test asserting `sizeof(VARIANT) = 24' is necessary but is not the interesting part --
;;;; it passes on a correct declaration and says nothing about whether the mechanism would
;;;; have CAUGHT the historical mistake. So this file reproduces the mistake: it declares a
;;;; VARIANT whose union omits BRECORD, exactly the plausible-looking declaration an author
;;;; writes when they list the members automation actually uses, and shows that
;;;;
;;;;   (a) it computes 16 on x64 -- the historical wrong number, arrived at honestly, and
;;;;   (b) VERIFY-LAYOUTS rejects it against the documented 24.
;;;;
;;;; That is the difference between a regression test and a demonstration that the guard
;;;; works. The first would have passed in cl-win32ole too.

(in-package #:aion/windows/com/tests)

(def-suite com-layout :description "COM struct layouts, and the defect that motivated them." :in all)
(in-suite com-layout)

;;; The wrong declaration, written the way it gets written: every member an automation
;;; caller touches, and none it does not. BRECORD is the omission.
(cffi:defcunion variant-value-without-brecord
  (ll-val :int64)
  (l-val :int32)
  (dbl-val :double)
  (bool-val :int16)
  (bstr-val :pointer)
  (p-disp-val :pointer)
  (p-unk-val :pointer))

(cffi:defcstruct variant-without-brecord
  (vt wffi:word)
  (w-reserved1 wffi:word)
  (w-reserved2 wffi:word)
  (w-reserved3 wffi:word)
  (value (:union variant-value-without-brecord)))

(test the-real-variant-is-twenty-four-bytes-on-x64
  "The number cl-win32ole got wrong. On x86 it is 16 and that is also correct -- the defect
was using one number on both architectures."
  (let ((size (cffi:foreign-type-size '(:struct ffi:variant))))
    (is (= size (ecase (wffi:pointer-width) (8 24) (4 16)))
        "sizeof(VARIANT) is ~D on a ~D-byte-pointer machine" size (wffi:pointer-width))))

(test the-variant-payload-starts-at-offset-eight
  "vt plus three reserved WORDs. If the union started anywhere else, every value read or
written through a VARIANT would be off by the difference."
  (is (= 0 (cffi:foreign-slot-offset '(:struct ffi:variant) 'ffi::vt)))
  (is (= 8 (cffi:foreign-slot-offset '(:struct ffi:variant) 'ffi::value))))

(test omitting-brecord-reproduces-the-historical-size
  "THE DEFECT, REPRODUCED. A VARIANT declared with only the members automation uses computes
16 on x64 -- cl-win32ole's number -- because BRECORD (two pointers) is what widens the union.
This is not a hypothetical: it is the most natural wrong declaration to write."
  (when (= 8 (wffi:pointer-width))
    (is (= 16 (cffi:foreign-type-size '(:struct variant-without-brecord)))
        "expected the truncated declaration to reproduce the historical 16 bytes")
    (is (= 24 (cffi:foreign-type-size '(:struct ffi:variant)))
        "and the real one to be 24")))

(test the-layout-gate-catches-the-historical-defect
  "AND THE GUARD CATCHES IT. Registering the truncated struct against VARIANT's documented
size must signal -- which is the whole claim ADR-0003 s4 makes."
  (when (= 8 (wffi:pointer-width))
    (signals wffi:layout-mismatch
      (wffi:verify-layouts
       (list (list :name "VARIANT (truncated union)"
                   :type '(:struct variant-without-brecord)
                   :size '(:x86 16 :x64 24)
                   :slots '()
                   :source "the cl-win32ole declaration, reproduced"))))))

(test the-mismatch-report-names-the-two-numbers
  "The report has to say what was documented and what was computed, or the reader cannot
tell which side is wrong -- the table or the declaration."
  (when (= 8 (wffi:pointer-width))
    (let ((details (handler-case
                       (progn (wffi:verify-layouts
                               (list (list :name "VARIANT (truncated union)"
                                           :type '(:struct variant-without-brecord)
                                           :size '(:x86 16 :x64 24) :slots '())))
                              nil)
                     (wffi:layout-mismatch (c) (wffi:layout-mismatch-details c)))))
      (is (= 1 (length details)))
      (is-true (search "24" (first details)) "should name the documented 24: ~S" details)
      (is-true (search "16" (first details)) "should name the computed 16: ~S" details))))

(test dispparams-and-excepinfo-match-their-documented-layouts
  "DISPPARAMS carries the argument array on every Invoke, and EXCEPINFO is how a server
reports a scripting error. Both are on the call path and neither is exercised by a simple
one-argument round trip."
  (is-true (wffi:verify-layouts))
  (is (= (cffi:foreign-type-size '(:struct ffi:dispparams))
         (ecase (wffi:pointer-width) (8 24) (4 16))))
  (is (= (cffi:foreign-type-size '(:struct ffi:excepinfo))
         (ecase (wffi:pointer-width) (8 64) (4 32)))))
