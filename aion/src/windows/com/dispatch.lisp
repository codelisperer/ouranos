;;;; dispatch.lisp --- creating objects and calling them through IDispatch.
;;;;
;;;; THE ARGUMENT ARRAY IS IN REVERSE ORDER. DISPPARAMS.rgvarg[0] is the LAST argument.
;;;; This is not a convention anyone would guess and it is the single most common way to
;;;; write a COM call that works with one argument and silently misbehaves with two -- which
;;;; is also, separately, exactly the case the VARIANT sizing defect broke. Both failure
;;;; modes converge on "one argument is fine, two are wrong", so the multi-argument test is
;;;; worth more than any other single check in this system.
;;;;
;;;; REFERENCE COUNTING. Every interface pointer that arrives here has had AddRef called on
;;;; it by whoever produced it, and owes exactly one Release. COM-OBJECT owns one such
;;;; reference and RELEASE spends it; releasing twice would decrement a count that may
;;;; already have reached zero, freeing an object another holder still points at. So RELEASE
;;;; is idempotent for the same reason CLOSE-HANDLE is.
;;;;
;;;; EVERY CALL RUNS IN THE APARTMENT. A COM object belongs to the apartment that created
;;;; it; calling it from another thread is either a silent marshalling proxy or an outright
;;;; failure, depending on the object. So the public entry points wrap their work in
;;;; IN-APARTMENT rather than trusting the caller to be on the right thread -- and this
;;;; reaches consumers, which is why ADR-0003 s6 notes an ADO-backed mnemosyne connection
;;;; would have thread affinity none of its other backends have.

(in-package #:aion/windows/com)

(define-condition com-error (w:windows-error)
  ((detail :initarg :detail :initform nil :reader com-error-detail))
  (:report (lambda (c stream)
             (format stream "COM: ~A" (or (com-error-detail c) "unspecified failure"))))
  (:documentation "A COM failure that is not simply a failing HRESULT."))

(define-condition unknown-member (com-error)
  ((name :initarg :name :initform nil :reader unknown-member-name))
  (:report (lambda (c stream)
             (format stream "COM: the object has no member named ~S" (unknown-member-name c))))
  (:documentation "GetIDsOfNames could not resolve the name -- usually a typo or a
version difference in the server, not a call that failed."))

(define-condition dispatch-error (com-error)
  ((source :initarg :source :initform nil :reader dispatch-error-source)
   (description :initarg :description :initform nil :reader dispatch-error-description))
  (:report
   (lambda (c stream)
     (format stream "COM: ~@[~A: ~]~A"
             (dispatch-error-source c)
             (or (dispatch-error-description c) "the server reported an error"))))
  (:documentation "DISP_E_EXCEPTION: the SERVER raised, and EXCEPINFO says what.

Distinguished from a failing HRESULT because it means something different: the call reached
the object and the object objected. A bare `0x80020009' tells a caller nothing; the server's
own description usually tells them everything."))

;;; --- objects -------------------------------------------------------------------

(defstruct (com-object (:constructor %make-com-object (pointer)))
  "An IDispatch pointer and the one reference it owns."
  (pointer (cffi:null-pointer) :read-only t)
  (released nil))

(defun wrap-interface (pointer)
  "Adopt an interface POINTER as a COM-OBJECT. THE REFERENCE IS TAKEN OVER, not borrowed.

The mirror of COM-OBJECT-POINTER, and the other half of what extending this binding requires:
a caller who does its own QUERYINTERFACE, or reads an interface out of a structure, holds a raw
pointer carrying one reference and needs it managed like any other. Without this they must
either leak it or reach into this package.

OWNERSHIP: the caller must NOT also release POINTER. Every interface arrives owing exactly one
RELEASE, and after this call the COM-OBJECT owes it. If you need a reference of your own as
well, ADD-REF first -- which is what VARIANT-TO-LISP does when it hands out a VT_DISPATCH,
precisely because the VARIANT it came from will be cleared underneath it."
  (%make-com-object pointer))

(defun release (object)
  "Release OBJECT's reference. Idempotent; returns T when it actually released."
  (when (and (com-object-p object)
             (not (com-object-released object))
             (not (cffi:null-pointer-p (com-object-pointer object))))
    (setf (com-object-released object) t)
    (call-in-apartment (lambda () (ffi:iunknown-release (com-object-pointer object))))
    t))

(defmacro with-com-object ((var form) &body body)
  "Bind VAR to the COM-OBJECT from FORM, releasing it however BODY exits."
  `(let ((,var ,form))
     (unwind-protect (progn ,@body)
       (release ,var))))

(cffi:defcfun ("IIDFromString" %iid-from-string) wffi:hresult
  (lpsz :pointer) (lpiid :pointer))

(defun %with-iid-fn (string fn)
  "Parse STRING as an IID and call FN with a pointer to it.

Parsed by Windows rather than packed by hand. A GUID's first three fields are little-endian
integers and the last is a byte array, so hand-packing gets the byte order right for five of
the sixteen bytes and wrong for none of the rest -- a mistake that produces a valid-looking
GUID that names nothing."
  (cffi:with-foreign-object (iid '(:struct wffi:guid))
    (w:with-wide-string (w string)
      (w:check-hresult (%iid-from-string w iid) :operation :iid-from-string))
    (funcall fn iid)))

(defun object-from-prog-id (prog-id)
  "Create the COM object registered under PROG-ID, e.g. \"Scripting.FileSystemObject\".

Runs in the apartment, so the object belongs to the STA thread from the moment it exists."
  (in-apartment ()
    (cffi:with-foreign-object (clsid '(:struct wffi:guid))
      (w:with-wide-string (w prog-id)
        (w:check-hresult (ffi:clsid-from-prog-id w clsid)
                         :operation :clsid-from-prog-id))
      (cffi:with-foreign-object (ppv :pointer)
        (setf (cffi:mem-ref ppv :pointer) (cffi:null-pointer))
        (%with-iid-fn
         ffi:+iid-idispatch+
         (lambda (iid)
           (w:check-hresult
            (ffi:co-create-instance clsid (cffi:null-pointer)
                                    ffi:+clsctx-server+ iid ppv)
            :operation :co-create-instance)))
        (let ((p (cffi:mem-ref ppv :pointer)))
          (when (cffi:null-pointer-p p)
            (error 'com-error :detail (format nil "CoCreateInstance succeeded but returned NULL for ~S" prog-id)))
          (%make-com-object p))))))

(defun create-object (prog-id)
  "OBJECT-FROM-PROG-ID, under the name the rest of the world uses for it."
  (object-from-prog-id prog-id))

;;; --- is this class actually here? (pre-publication issue 306) --------------------------------------------
;;;
;;; A platform-scoped package is supposed to answer "is this capability present?" BEFORE an
;;; interface offers it. The hades charter says such packages must fail loudly off-platform
;;; and never silently no-op -- and that bar is written for the easy axis. Off-platform is
;;; easy: this system will not even load on a Mac. The hard case is ON platform with the
;;; capability absent, which is where every real deployment lives, and a package that loads
;;; cleanly and fails at the first real call is that same failure one layer up.
;;;
;;; CREATION ALONE CANNOT ANSWER IT, and that is why this is not four lines around
;;; CoCreateInstance. Under WOW64 the registry view is redirected, so a class registered
;;; only for the OTHER bitness is simply not found and the call returns REGDB_E_CLASSNOTREG
;;; -- the same HRESULT as never installed. The predicate would be right and MUTE. The two
;;; cases want opposite advice:
;;;
;;;   not installed               install it
;;;   installed, other bitness    you already have it -- install the other build
;;;
;;; and telling someone to install Access while Access is on their machine is the single
;;; most expensive error in this space. So the registry supplies the distinction the HRESULT
;;; cannot make, and aion/windows/registry (#132) exists for exactly that.
;;;
;;; NOT A HYPOTHETICAL. Microsoft.Jet.OLEDB.4.0 on any ordinary 64-bit Windows: the ProgID
;;; resolves, the CLSID resolves, and there is no InprocServer32 in the 64-bit view because
;;; there is no 64-bit Jet and never was. A probe that stops at the ProgID answers YES for a
;;; provider this process can never create.
;;;
;;; IT NEVER SIGNALS. A predicate that signals cannot be asked, which defeats the point --
;;; the caller is a screen deciding whether to offer a control.
;;;
;;; AND IT REPORTS THE PATH ON SUCCESS, not only on failure. That is the case nobody asks
;;; for and exactly why it matters: mnemosyne reported a green SQLite backend for months on
;;; a DLL an unrelated installation supplied, and every layer that could inspect the check
;;; was honest -- the dishonesty was one level below, in WHICH FILE the loader found (#129).
;;; :PRESENT is a claim about a state; "present at <path>" is a claim someone can check.

(defun %this-view ()
  "The registry view THIS process sees. Not a preference -- it is what WOW64 redirects us to."
  (if (= 8 (cffi:foreign-type-size :pointer)) :64 :32))

(defun %other-view (view) (ecase view (:64 :32) (:32 :64)))

(defun %creatable-p (clsid)
  "Can this process actually create CLSID? Attempts it for IUnknown and releases at once.

IUnknown rather than IDispatch, deliberately: a server that does not implement IDispatch is
still installed, and asking for the automation interface would report a registered,
creatable, non-automatable class as absent. The question here is presence, not usability
from this binding."
  (handler-case
      (in-apartment ()
        ;; %WITH-IID-FN twice, for the CLSID and then the IID. It parses a braced GUID
        ;; string through Windows rather than packing bytes by hand -- see its own note on
        ;; why hand-packing produces a valid-looking GUID that names nothing -- and a CLSID
        ;; is a GUID, so the same helper serves both.
        (%with-iid-fn
         clsid
         (lambda (guid)
           (cffi:with-foreign-object (ppv :pointer)
             (setf (cffi:mem-ref ppv :pointer) (cffi:null-pointer))
             (%with-iid-fn
              ffi:+iid-iunknown+
              (lambda (iid)
                (let ((hr (ffi:co-create-instance guid (cffi:null-pointer)
                                                  ffi:+clsctx-server+ iid ppv)))
                  (when (w:hresult-succeeded-p hr)
                    (let ((p (cffi:mem-ref ppv :pointer)))
                      (unless (cffi:null-pointer-p p)
                        ;; Released IMMEDIATELY. This is a question, not an acquisition,
                        ;; and an out-of-process server left running because somebody asked
                        ;; whether it existed is a side effect a predicate must not have.
                        (ffi:iunknown-release p)
                        t))))))))))
    (error () nil)))

(defun class-available-p (prog-id)
  "Is PROG-ID present and creatable from THIS process? Never signals.

Returns (values available-p reason path):

  T   :present                <path>   registered in this view and it creates
  NIL :other-bitness          <path>   registered for the OTHER bitness -- you have it
  NIL :present-but-unloadable <path>   registered here, and creation failed anyway
  NIL :absent                 NIL      not registered in either view

A caller wanting yes-or-no ignores the extra values; a screen wanting to be useful reads
them. The distinction between :ABSENT and :OTHER-BITNESS is the reason this is not a
wrapper around CoCreateInstance -- see the commentary above."
  (let* ((here (%this-view))
         (there (%other-view here))
         (clsid (or (reg:prog-id-clsid prog-id here)
                    (reg:prog-id-clsid prog-id there))))
    (if (null clsid)
        (values nil :absent nil)
        (let ((mine (reg:class-inproc-server clsid here)))
          (cond
            ((null mine)
             (let ((theirs (reg:class-inproc-server clsid there)))
               (cond
                 (theirs (values nil :other-bitness theirs))
                 ;; A CLSID with no InprocServer32 in either view is not necessarily
                 ;; absent: a LOCAL server registers LocalServer32 instead. Creation is the
                 ;; honest test for that, and it is the one branch where a failed
                 ;; CoCreateInstance means what its HRESULT says.
                 ((%creatable-p clsid) (values t :present nil))
                 (t (values nil :absent nil)))))
            ((%creatable-p clsid) (values t :present mine))
            (t (values nil :present-but-unloadable mine)))))))

;;; --- calling ---------------------------------------------------------------------

(defmacro with-null-iid ((var) &body body)
  "Bind VAR to IID_NULL -- sixteen zero bytes -- for BODY.

Both GetIDsOfNames and Invoke require IID_NULL, and it is BUILT rather than parsed. An
earlier draft ran it through IIDFromString, which is a Win32 call on the hot path of every
single member lookup that produces a value we already know: all zeroes. It is the one GUID
with no string form worth round-tripping."
  `(cffi:with-foreign-object (,var (quote (:struct wffi:guid)))
     (dotimes (i (cffi:foreign-type-size (quote (:struct wffi:guid))))
       (setf (cffi:mem-aref ,var :uint8 i) 0))
     ,@body))

(defun %dispid-of (object name)
  "The DISPID for NAME on OBJECT, or a signalled UNKNOWN-MEMBER."
  (let ((this (com-object-pointer object)))
    (cffi:with-foreign-object (dispid :int32)
      (cffi:with-foreign-object (names :pointer 1)
        (w:with-wide-string (w name)
          (setf (cffi:mem-aref names :pointer 0) w)
          (with-null-iid (null-iid)
            (let ((hr (ffi:idispatch-get-ids-of-names this null-iid names 1 0 dispid)))
              (unless (w:hresult-succeeded-p hr)
                (error 'unknown-member :name name))))))
      (cffi:mem-ref dispid :int32))))

(defun %excepinfo-condition (excepinfo)
  "Turn a filled EXCEPINFO into a DISPATCH-ERROR carrying the server's own words."
  (flet ((bstr (slot)
           (let ((p (cffi:foreign-slot-value excepinfo '(:struct ffi:excepinfo) slot)))
             (unless (cffi:null-pointer-p p)
               (prog1 (cffi:foreign-string-to-lisp
                       p :encoding :utf-16le :count (* 2 (ffi:sys-string-len p)))
                 ;; EXCEPINFO's strings are ours to free once read -- Invoke allocated them
                 ;; and documents the caller as the owner.
                 (ffi:sys-free-string p))))))
    (make-condition 'dispatch-error
                    :source (bstr 'ffi::bstr-source)
                    :description (bstr 'ffi::bstr-description))))

(defun %property-put-p (flags)
  "Is FLAGS a property PUT? Tested by mask rather than EQ: a caller may legitimately pass
PROPERTYPUT together with PROPERTYPUTREF, and Automation servers differ on which they
accept for an object-valued property."
  (plusp (logand flags ffi:+dispatch-property-put+)))

(defun %invoke (object name flags args)
  "GetIDsOfNames then Invoke. Runs on the caller's thread -- callers wrap in the apartment.

BY-REF ARGUMENTS (pre-publication issue 304). An argument that is a BY-REF cell is passed as VT_VARIANT|VT_BYREF
pointing at a referent VARIANT this function owns for the duration of the call; whatever the
server leaves there is read back into the cell before the referents are cleared.

THE CLEARING IS THE SUBTLE PART, and it is why the referents are a separate block rather than
more entries in ARGV. VariantClear on a VT_BYREF variant does NOT free what it points at --
correctly, since the pointer is borrowed -- so clearing ARGV alone would leak whatever the
server allocated into a referent, typically a BSTR. The referents are therefore cleared
explicitly, and they must be cleared AFTER the read-back, which is why that read is not
folded into the cleanup form."
  (let* ((this (com-object-pointer object))
         (dispid (%dispid-of object name))
         (n (length args))
         (refs (remove-if-not #'by-ref-p args))
         (nrefs (length refs)))
    (cffi:with-foreign-objects ((argv '(:struct ffi:variant) (max n 1))
                                (referents '(:struct ffi:variant) (max nrefs 1)))
      (unwind-protect
           (progn
             ;; REVERSE ORDER. rgvarg[0] is the LAST argument. See the header note: this is
             ;; the other reason a call can work with one argument and break with two.
             (loop with j = 0
                   for value in args
                   for i downfrom (1- n)
                   for slot = (cffi:mem-aptr argv '(:struct ffi:variant) i)
                   do (ffi:variant-init slot)
                      (cond
                        ((by-ref-p value)
                         (let ((referent (cffi:mem-aptr referents '(:struct ffi:variant) j)))
                           (ffi:variant-init referent)
                           ;; The cell's current value goes IN, so one cell serves [in,out].
                           (lisp-to-variant (by-ref-value value) referent)
                           (%set-vt slot (logior ffi:+vt-variant+ ffi:+vt-byref+))
                           (setf (cffi:mem-ref (%value-pointer slot) :pointer) referent)
                           (incf j)))
                        (t (lisp-to-variant value slot))))
             (cffi:with-foreign-objects ((params '(:struct ffi:dispparams))
                                         (result '(:struct ffi:variant))
                                         (excepinfo '(:struct ffi:excepinfo))
                                         (arg-err :uint32)
                                         (named-dispids :int32 1))
               (ffi:variant-init result)
               (dotimes (i (cffi:foreign-type-size '(:struct ffi:excepinfo)))
                 (setf (cffi:mem-aref excepinfo :uint8 i) 0))
               (setf (cffi:foreign-slot-value params '(:struct ffi:dispparams) 'ffi::rgvarg)
                     (if (zerop n) (cffi:null-pointer) argv)
                     (cffi:foreign-slot-value params '(:struct ffi:dispparams) 'ffi::c-args)
                     n)
               ;; A PROPERTY PUT IS NOT AN ORDINARY CALL, and this is the whole of why
               ;; setting one never worked (pre-publication issue 306). IDispatch requires the new value to be
               ;; passed as a NAMED argument: rgdispidNamedArgs[0] = DISPID_PROPERTYPUT and
               ;; cNamedArgs = 1. A server handed the value positionally with cNamedArgs 0
               ;; rejects the call -- so the two constants being defined and exported was
               ;; not nearly enough, and neither was the vestigial `if' that used to sit in
               ;; this function with identical branches.
               ;;
               ;; The value lands in rgvarg[0] with no special handling, because rgvarg is
               ;; filled in REVERSE: pass the value LAST and it is element zero, which is
               ;; exactly where a put wants it. For an indexed put, `(set-property o "Item"
               ;; ix v)' puts v at [0] and ix at [1], which is also what the interface says.
               (cond ((%property-put-p flags)
                      (setf (cffi:mem-aref named-dispids :int32 0) ffi:+dispid-property-put+
                            (cffi:foreign-slot-value params '(:struct ffi:dispparams) 'ffi::rgdispid-named-args)
                            named-dispids
                            (cffi:foreign-slot-value params '(:struct ffi:dispparams) 'ffi::c-named-args)
                            1))
                     (t
                      (setf (cffi:foreign-slot-value params '(:struct ffi:dispparams) 'ffi::rgdispid-named-args)
                            (cffi:null-pointer)
                            (cffi:foreign-slot-value params '(:struct ffi:dispparams) 'ffi::c-named-args)
                            0)))
               (with-null-iid (null-iid)
                 (let ((hr (ffi:idispatch-invoke this dispid null-iid 0 flags
                                                 params result excepinfo arg-err)))
                   (unwind-protect
                        (cond
                          ((w:hresult-succeeded-p hr)
                           ;; READ BACK BEFORE THE CLEANUP FORM RUNS. Only on success: a
                           ;; failed Invoke may have written nothing, and reporting a stale
                           ;; or half-written referent as a result would be worse than the
                           ;; error the caller is about to see.
                           (loop for cell in refs
                                 for j from 0
                                 do (setf (by-ref-value cell)
                                          (variant-to-lisp
                                           (cffi:mem-aptr referents '(:struct ffi:variant) j))))
                           (variant-to-lisp result))
                          ;; DISP_E_EXCEPTION: the server raised. Its own description is
                          ;; worth more than the HRESULT, so it is preferred.
                          ((= (logand hr #xFFFFFFFF) #x80020009)
                           (error (%excepinfo-condition excepinfo)))
                          ;; NAME is a string, deliberately. It comes from the SERVER's vocabulary, and
                          ;; interning it would put an arbitrary, caller-supplied name in the KEYWORD
                          ;; package permanently -- keywords are never collected, so a long-lived
                          ;; image automating many objects would grow one symbol per distinct failing
                          ;; member, forever, purely to format an error message.
                          (t (w:check-hresult hr :operation name)))
                     (ffi:variant-clear result))))))
        ;; Every argument VARIANT we filled owns whatever it holds -- a BSTR for every
        ;; string argument. Clearing them is not optional and is why this is UNWIND-PROTECT
        ;; rather than a straight line: the failure path allocates exactly as much as the
        ;; success path.
        (dotimes (i n)
          (ffi:variant-clear (cffi:mem-aptr argv '(:struct ffi:variant) i)))
        ;; And the referents separately, because the clear above did not touch them: a
        ;; VT_BYREF variant borrows its pointer and VariantClear leaves borrowed memory
        ;; alone. Whatever the server allocated into a referent is ours to release.
        (dotimes (j nrefs)
          (ffi:variant-clear (cffi:mem-aptr referents '(:struct ffi:variant) j)))))))

(defun invoke-method (object name &rest args)
  "Call NAME on OBJECT with ARGS, in the apartment."
  (in-apartment () (%invoke object name ffi:+dispatch-method+ args)))

(defun get-property (object name &rest args)
  "Read property NAME from OBJECT. ARGS are indices for an indexed property."
  (in-apartment () (%invoke object name ffi:+dispatch-property-get+ args)))

(defun set-property (object name &rest args)
  "Write property NAME on OBJECT. The NEW VALUE IS THE LAST ARGUMENT.

  (com:set-property doc \"Title\" \"Report\")          ; plain property
  (com:set-property dict \"Item\" \"k\" \"v\")          ; indexed: index first, value last

Value-last rather than value-first because that is the order the interface wants once
rgvarg's reversal is accounted for, and because it reads as an assignment. pre-publication issue 306: there was
no setter at all, so any Automation object configured through properties rather than
arguments -- which is most of Office, ADO's Connection, and every WMI object -- was only
half usable.

PROPERTYPUTREF is not exposed separately. The distinction matters only for properties that
take an object by reference, servers disagree about which flag they accept, and adding a
second entry point ahead of a caller who needs one is the kind of surface that gets
maintained forever on the strength of nobody's requirement."
  (in-apartment () (%invoke object name ffi:+dispatch-property-put+ args)))

(defun invoke (object name &rest args)
  "Call NAME on OBJECT, accepting either a method or a property.

Automation does not reliably distinguish the two -- many members are readable as a property
and callable as a method, and which one a server accepts is a property of that server. So
this tries METHOD|PROPERTYGET together, which is what every scripting host does."
  (in-apartment ()
    (%invoke object name (logior ffi:+dispatch-method+ ffi:+dispatch-property-get+) args)))
