;;;; layout-tests.lisp --- the headline. These are the checks ADR-0003 s4 exists to demand.
;;;;
;;;; The lesson being encoded: cl-win32ole sized VARIANT at 16 bytes -- right on x86, wrong
;;;; on x64 where it is 24 -- and every call with two or more arguments read garbage as
;;;; pointers, silently, for as long as anyone had run it on a 64-bit image. It had no test
;;;; asserting a single struct size. These are that test.
;;;;
;;;; TWO KINDS OF CHECK HERE, and the second is the one that matters:
;;;;
;;;;   1. the registered layouts agree with CFFI on THIS machine -- the standing assertion,
;;;;      which is also run at load by ffi.lisp so a mismatch refuses to load at all.
;;;;
;;;;   2. VERIFY-LAYOUTS ACTUALLY FAILS when a layout is wrong. Without this, check 1 is
;;;;      indistinguishable from a function that returns T -- and a layout gate that cannot
;;;;      fail is worse than none, because it reports success. So a deliberately wrong
;;;;      layout is fed in and the signal is required.

(in-package #:aion/windows/tests)

(def-suite layout :description "Struct layouts, asserted against the documented table." :in all)
(in-suite layout)

(test pointer-width-is-asked-not-assumed
  "The bug this whole file guards against was an assumption about pointer width. The width
must come from the FFI that will do the marshalling, and must be one of the two real answers."
  (let ((width (ffi:pointer-width)))
    (is (member width '(4 8))
        "pointer width is ~D, which is neither x86 nor x64" width)
    (is (eq (ffi:layout-column) (if (= width 8) :x64 :x86))
        "the layout column must follow the measured pointer width, not a feature test")))

(test registered-layouts-match-cffi
  "Every documented layout agrees with what CFFI computed from the member list.

This also runs at LOAD (ffi.lisp), so on a healthy tree it can only pass here. It is
asserted anyway: the load-time call proves the tree it loaded in, and this proves it as a
recorded check with a count, which is what the gate reads."
  (is-true (ffi:verify-layouts)
           "the registered layouts disagree with CFFI on this machine"))

(test the-registry-is-not-empty
  "A layout table with nothing in it passes every check trivially. ADR-0003 s4 says `built
in from the first commit', so the first commit must have something registered."
  (is (plusp (length ffi:*layouts*))
      "no layouts are registered -- VERIFY-LAYOUTS would then be a function that returns T"))

(test guid-is-sixteen-bytes
  "GUID is what IID and CLSID are typedefs of, so it is on the path of every COM call. 16
bytes on both widths -- if this is wrong, every interface lookup passes the wrong bytes."
  (is (= 16 (cffi:foreign-type-size '(:struct ffi:guid)))
      "sizeof(GUID) is ~D, not 16" (cffi:foreign-type-size '(:struct ffi:guid)))
  (is (= 0 (cffi:foreign-slot-offset '(:struct ffi:guid) 'ffi::data1)))
  (is (= 4 (cffi:foreign-slot-offset '(:struct ffi:guid) 'ffi::data2)))
  (is (= 6 (cffi:foreign-slot-offset '(:struct ffi:guid) 'ffi::data3)))
  (is (= 8 (cffi:foreign-slot-offset '(:struct ffi:guid) 'ffi::data4))))

;;; --- and now the check that gives the others their meaning -------------------

(test verify-layouts-signals-on-a-wrong-size
  "THE CHECK THAT MAKES THE OTHERS EVIDENCE. Feed VERIFY-LAYOUTS a layout whose documented
size is deliberately wrong -- exactly cl-win32ole's 16-instead-of-24 -- and require it to
signal. If this passes silently, every other assertion in this file is decoration."
  (let ((wrong (list (list :name "DELIBERATELY-WRONG"
                           :type '(:struct ffi:guid)
                           ;; GUID is 16 on both. Claim 24, cl-win32ole's error in reverse.
                           :size '(:x86 24 :x64 24)
                           :slots '()
                           :source "a test, not a document"))))
    (signals ffi:layout-mismatch (ffi:verify-layouts wrong))))

(test verify-layouts-signals-on-a-wrong-offset
  "A size can be right while a member sits in the wrong place -- a reordered or missing
reserved field does exactly that, and it is the harder half to notice."
  (let ((wrong (list (list :name "WRONG-OFFSET"
                           :type '(:struct ffi:guid)
                           :size '(:x86 16 :x64 16)
                           :slots '((data2 :offset (:x86 99 :x64 99)))
                           :source "a test, not a document"))))
    (signals ffi:layout-mismatch (ffi:verify-layouts wrong))))

(test verify-layouts-signals-on-an-undeclared-struct
  "A layout registered for a type nobody declared must be a failure and not a silent skip:
that is how a struct gets deleted while its table entry stays behind, reporting success."
  (let ((wrong (list (list :name "NO-SUCH-STRUCT"
                           :type '(:struct no-such-struct-anywhere)
                           :size '(:x86 8 :x64 8)
                           :slots '()
                           :source "a test, not a document"))))
    (signals ffi:layout-mismatch (ffi:verify-layouts wrong))))

(test the-mismatch-report-names-every-problem
  "A layout table is usually wrong in more than one place at once -- one wrong assumption
about a type width propagates -- so reporting one problem per run turns a five-minute fix
into five rebuild cycles."
  (let* ((wrong (list (list :name "A" :type '(:struct ffi:guid)
                            :size '(:x86 99 :x64 99) :slots '())
                      (list :name "B" :type '(:struct ffi:filetime)
                            :size '(:x86 99 :x64 99) :slots '())))
         (details (handler-case (progn (ffi:verify-layouts wrong) nil)
                    (ffi:layout-mismatch (c) (ffi:layout-mismatch-details c)))))
    (is (= 2 (length details))
        "expected both problems reported, got ~S" details)
    (is-true (some (lambda (d) (search "A" d)) details))
    (is-true (some (lambda (d) (search "B" d)) details))))
