;;;; layout.lisp --- struct layouts are DATA, asserted at load (ADR-0003 s4).
;;;;
;;;; THE ONE PLACE "NO GROVEL" HAS NO EXISTING ANSWER. aion/uv escapes hand-written layouts
;;;; because libuv EXPORTS uv_handle_size, so the library itself can be asked. Windows
;;;; exports no equivalent: nothing in kernel32 or oleaut32 will tell you sizeof(VARIANT).
;;;; So the sizes and offsets are written down from Microsoft's documentation, per pointer
;;;; width, and checked at load against what CFFI actually computed.
;;;;
;;;; WHY THIS EXISTS AT ALL, precisely. cl-win32ole sized VARIANT at 16 bytes: correct on
;;;; x86, wrong on x64 where it is 24. The argument array was under-allocated and strode 16
;;;; bytes per element, so argument 0 landed correctly and EVERY CALL WITH TWO OR MORE
;;;; ARGUMENTS read garbage as pointers -- faults at #x0, #x8, #xFFFFFFFFFFFFFFFF. Silent,
;;;; architecture-specific memory corruption on the core data path, in a library with no
;;;; test asserting a single struct size. One assertion would have caught it on the first
;;;; run on a 64-bit image.
;;;;
;;;; ================================================================================
;;;; THE TAUTOLOGY TRAP, and why the structs are declared the way they are.
;;;; ================================================================================
;;;;
;;;; It is tempting to declare an opaque struct of the documented size:
;;;;
;;;;     (defcstruct variant (bytes :uint8 :count 24))      ; DO NOT
;;;;
;;;; and then assert that its size is 24. That assertion CANNOT FAIL. It compares a number
;;;; against itself with extra steps, and it would have passed cheerfully in cl-win32ole
;;;; too -- the value 16 asserted against the constant 16.
;;;;
;;;; So every struct here is declared STRUCTURALLY -- its real members, in order -- and the
;;;; table states the documented size INDEPENDENTLY. CFFI then computes a size from the
;;;; member list, including the padding and alignment rules it applies for this platform,
;;;; and the check compares two numbers that were arrived at by different routes. A
;;;; mis-declared member, a forgotten reserved field, a wrong integer width or an alignment
;;;; assumption that does not hold now has somewhere to show up.
;;;;
;;;; That is the difference between a test that can fail and one that cannot, which is the
;;;; same standard the rest of this tree's gates are held to (AGENTS.md, "Green is not
;;;; evidence"). A layout check that cannot fail is worse than none, because it reports
;;;; success.
;;;;
;;;; REGISTRATION IS OPEN. The foundation owns the mechanism; each subsystem registers its
;;;; own structs next to where it declares them, and calls VERIFY-LAYOUTS at load. The table
;;;; is therefore never a central list someone has to remember to update in another file.

(in-package #:aion/windows/ffi)

;;; --- what this machine is ---------------------------------------------------

(defun pointer-width ()
  "8 on x64, 4 on x86 -- ASKED, not assumed.

Read from CFFI rather than from *FEATURES* on purpose. The bug this file exists to prevent
was an assumption about pointer width that was true on the machine it was written on, and a
feature test is the same class of assumption one level up. This asks the FFI that will
actually do the marshalling."
  (cffi:foreign-type-size :pointer))

(defun layout-column ()
  "The key into a documented (:x86 n :x64 m) pair for this machine."
  (ecase (pointer-width)
    (4 :x86)
    (8 :x64)))

;;; --- the table --------------------------------------------------------------

(defvar *layouts* '()
  "Registered struct layouts, newest first. Each entry is a plist:

  :name    a label for reports -- what MSDN calls it
  :type    the CFFI type specifier, e.g. (:struct variant)
  :size    (:x86 n :x64 m), from Microsoft's documentation
  :slots   ((slot-name :offset (:x86 n :x64 m)) ...), documented offsets
  :source  where the numbers came from, so a future reader can re-check them")

(defun register-layout (&key name type size slots source)
  "Record a documented layout to be checked by VERIFY-LAYOUTS.

Called by each subsystem beside its own DEFCSTRUCT, so the documented numbers live next to
the declaration they constrain rather than in a central list that drifts."
  (setf *layouts*
        (cons (list :name name :type type :size size :slots slots :source source)
              (remove name *layouts* :key (lambda (e) (getf e :name)) :test #'equal)))
  name)

;;; --- the check --------------------------------------------------------------

(define-condition layout-mismatch (error)
  ((details :initarg :details :initform '() :reader layout-mismatch-details))
  (:report
   (lambda (c stream)
     (format stream "aion/windows: struct layout does not match Microsoft's documented layout on this platform.~%~%~{  - ~A~%~}~%This is the cl-win32ole defect class: a wrong struct size corrupts every call that marshals through it, silently, and only on the architecture that disagrees. Refusing to load is the correct outcome."
             (layout-mismatch-details c))))
  (:documentation "A declared struct does not have its documented size or offsets."))

(defun %documented (spec)
  "The value of a (:x86 n :x64 m) pair for this machine, or NIL if unspecified."
  (when spec (getf spec (layout-column))))

(defun verify-layouts (&optional (layouts *layouts*))
  "Check every registered layout against what CFFI computed. Signals LAYOUT-MISMATCH.

Collects EVERY problem before signalling rather than dying on the first. A layout table is
usually wrong in more than one place at once -- the same wrong assumption about a type width
propagates -- and reporting one at a time turns a five-minute fix into five rebuild cycles.
Same reasoning as VERIFY-ABI in aion/uv."
  (let ((problems '())
        (column (layout-column)))
    (dolist (entry layouts)
      (let* ((name (getf entry :name))
             (type (getf entry :type))
             (want-size (%documented (getf entry :size)))
             (got-size (ignore-errors (cffi:foreign-type-size type))))
        (cond
          ((null got-size)
           (push (format nil "~A: CFFI cannot size ~S at all -- the struct is not declared"
                         name type)
                 problems))
          ((and want-size (/= want-size got-size))
           (push (format nil "~A: documented size on ~(~A~) is ~D bytes, CFFI computed ~D"
                         name column want-size got-size)
                 problems)))
        ;; Offsets, only when the struct sized at all -- otherwise every slot repeats the
        ;; same finding and buries it.
        (when got-size
          (loop for (slot . spec) in (getf entry :slots)
                for want = (%documented (getf spec :offset))
                for got = (ignore-errors (cffi:foreign-slot-offset type slot))
                do (cond
                     ((null got)
                      (push (format nil "~A: ~S has no slot ~A" name type slot) problems))
                     ((and want (/= want got))
                      (push (format nil "~A.~A: documented offset on ~(~A~) is ~D, CFFI computed ~D"
                                    name slot column want got)
                            problems)))))))
    (when problems
      (error 'layout-mismatch :details (nreverse problems)))
    t))

(defun layout-report ()
  "Every registered layout and what it measured, as a list of plists.

For the REPL and for the suite's evidence: a gate that says PASS should be able to show the
numbers it passed on."
  (let ((column (layout-column)))
    (mapcar (lambda (entry)
              (let ((type (getf entry :type)))
                (list :name (getf entry :name)
                      :column column
                      :documented (%documented (getf entry :size))
                      :computed (ignore-errors (cffi:foreign-type-size type))
                      :source (getf entry :source))))
            (reverse *layouts*))))
