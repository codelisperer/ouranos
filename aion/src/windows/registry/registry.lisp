;;;; registry.lisp --- reading one registry value, in a NAMED bitness view (#132).
;;;;
;;;; DELIBERATELY NOT A REGISTRY API. Read only -- no writes, no deletes, no key creation --
;;;; and no more surface than one question needs: does this key have a default value in
;;;; THIS view? A registry writer is a different decision with a different blast radius and
;;;; is not in this one.
;;;;
;;;; THE VIEW IS THE WHOLE FEATURE. Under WOW64 the registry is redirected, so a 64-bit
;;;; process asking whether a class is registered gets a different answer than a 32-bit one
;;;; -- and `CoCreateInstance' cannot tell you which, because a class registered only for
;;;; the other bitness returns REGDB_E_CLASSNOTREG, the same HRESULT as never installed.
;;;; Those two want OPPOSITE advice: install it, against you already have it, install the
;;;; other build. A binding that cannot name the view reproduces the bug it exists to
;;;; diagnose, so KEY-DEFAULT-VALUE takes the view and has no default for it.
;;;;
;;;; Measured motivation, on an ordinary machine with nothing broken:
;;;;
;;;;   Microsoft.Jet.OLEDB.4.0  CLSID {dee35070-...}
;;;;     64-bit view: ABSENT
;;;;     32-bit view: C:\Windows\SysWOW64\msjetoledb40.dll
;;;;
;;;; There is no 64-bit Jet and never was. A probe that only resolves the ProgID answers
;;;; YES for a provider a 64-bit process can never create.

(in-package #:aion/windows/registry)

;;; --- the flat FFI ------------------------------------------------------------------

(defconstant +hkey-classes-root+ #x80000000
  "HKEY_CLASSES_ROOT, as the 32-bit constant Windows documents.

NOT usable as a pointer directly on x64 -- see %ROOT-POINTER, which is where the sign
extension lives and why.")

(defun %root-pointer ()
  "HKEY_CLASSES_ROOT as an HKEY.

SIGN-EXTENDED, and this is not a detail. winreg.h defines it as

    ((HKEY)(ULONG_PTR)((LONG)0x80000000))

-- a LONG first, so the cast to a 64-bit pointer sign-extends it to
#xFFFFFFFF80000000. Handing RegOpenKeyEx the bare #x80000000 on x64 passes an address
that is not HKEY_CLASSES_ROOT, and the call fails with a plain ERROR_FILE_NOT_FOUND
that looks exactly like an absent key. Found by the tests below, which skipped every
real-machine case while reporting green -- a lookup that answers NIL for everything
satisfies every test that only asks about absence."
  (cffi:make-pointer
   (if (= 8 (cffi:foreign-type-size :pointer))
       (logior #xFFFFFFFF00000000 +hkey-classes-root+)
       +hkey-classes-root+)))

(defconstant +key-read+ #x20019)
(defconstant +key-wow64-64key+ #x0100)
(defconstant +key-wow64-32key+ #x0200)

(defconstant +error-success+ 0)
(defconstant +error-file-not-found+ 2)

;;; REG_SZ and REG_EXPAND_SZ are the two a class registration uses. EXPAND_SZ carries
;;; %SystemRoot%-style references that the caller must expand; it is reported rather than
;;; expanded here, because expanding is a policy question (whose environment?) and this
;;; file is deliberately mechanism only.
(defconstant +reg-sz+ 1)
(defconstant +reg-expand-sz+ 2)

(cffi:defcfun ("RegOpenKeyExW" %reg-open-key-ex) :int32
  (key :pointer) (sub-key :pointer) (options :uint32) (desired :uint32) (result :pointer))

(cffi:defcfun ("RegQueryValueExW" %reg-query-value-ex) :int32
  (key :pointer) (value-name :pointer) (reserved :pointer)
  (type :pointer) (data :pointer) (data-size :pointer))

(cffi:defcfun ("RegCloseKey" %reg-close-key) :int32
  (key :pointer))

;;; --- the one question -----------------------------------------------------------------

(deftype registry-view () '(member :32 :64))

(defun %view-flag (view)
  (ecase view
    (:32 +key-wow64-32key+)
    (:64 +key-wow64-64key+)))

(defun key-default-value (subkey view)
  "The default value of HKEY_CLASSES_ROOT\SUBKEY as seen in VIEW, or NIL.

VIEW is :32 or :64 and has NO DEFAULT -- see the header. The answer differs by view and a
caller that has not thought about which one it means is asking the wrong question.

Returns (values string type) on success, NIL otherwise. TYPE is +REG-SZ+ or
+REG-EXPAND-SZ+; an expandable string is returned UNEXPANDED and says so, because whose
environment to expand it in is the caller's question and not this file's.

NEVER SIGNALS FOR AN ABSENT KEY. Absence is the common answer and the one the caller is
usually asking about -- a predicate built on something that signals cannot be asked."
  (check-type view registry-view)
  (cffi:with-foreign-object (hkey :pointer)
    (w:with-wide-string (sub subkey)
      (let ((rc (%reg-open-key-ex (%root-pointer)
                                  sub 0
                                  (logior +key-read+ (%view-flag view))
                                  hkey)))
        (unless (= rc +error-success+)
          (return-from key-default-value nil))))
    (let ((handle (cffi:mem-ref hkey :pointer)))
      (unwind-protect
           (cffi:with-foreign-objects ((type :uint32) (size :uint32))
             ;; TWO CALLS, which is the documented shape: the first asks how many bytes,
             ;; the second reads them. Passing a guessed buffer and hoping is how a
             ;; registry read becomes a truncation bug on the one machine with a long path.
             (setf (cffi:mem-ref size :uint32) 0)
             (let ((rc (%reg-query-value-ex handle (cffi:null-pointer) (cffi:null-pointer)
                                            type (cffi:null-pointer) size)))
               (unless (= rc +error-success+)
                 (return-from key-default-value nil))
               (let ((bytes (cffi:mem-ref size :uint32)))
                 (when (zerop bytes)
                   (return-from key-default-value nil))
                 (cffi:with-foreign-pointer (buf bytes)
                   (setf (cffi:mem-ref size :uint32) bytes)
                   (let ((rc (%reg-query-value-ex handle (cffi:null-pointer) (cffi:null-pointer)
                                                  type buf size)))
                     (unless (= rc +error-success+)
                       (return-from key-default-value nil))
                     ;; RegQueryValueEx does not promise a terminating NUL, so the length
                     ;; is authoritative. It is in BYTES and these are UTF-16 code units.
                     (let* ((chars (floor (cffi:mem-ref size :uint32) 2))
                            (s (cffi:foreign-string-to-lisp
                                buf :encoding :utf-16le :count (* 2 chars))))
                       (values (string-right-trim '(#\Nul) s)
                               (cffi:mem-ref type :uint32))))))))
        (%reg-close-key handle)))))

(defun class-inproc-server (clsid view)
  "The InprocServer32 path registered for CLSID in VIEW, or NIL.

CLSID is the braced string form, e.g. \"{dee35070-506b-11cf-b1aa-00aa00b8de95}\"."
  (key-default-value (format nil "CLSID\\~A\\InprocServer32" clsid) view))

(defun prog-id-clsid (prog-id view)
  "The CLSID registered for PROG-ID in VIEW, or NIL."
  (key-default-value (format nil "~A\\CLSID" prog-id) view))
