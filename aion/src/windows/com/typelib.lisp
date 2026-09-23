;;;; typelib.lisp --- constants read out of a server and emitted as a package (pre-publication issue 181).
;;;;
;;;; Automating Excel through the generic accessor means a string in each hand:
;;;;
;;;;     (com:invoke range "End" -4162)              ; -4162 is xlUp. Obviously.
;;;;     (com:invoke range "End" xl:+xl-up+)         ; this, instead
;;;;
;;;; The numbers are not documented anywhere convenient, they differ between libraries, and a
;;;; wrong one is a legal argument that quietly does something else. They are, however, IN THE
;;;; SERVER -- every automation library carries its own enums, with names and help text, and
;;;; ITypeLib will read them out. So the wrapper does not get written. It gets emitted.
;;;;
;;;; ==============================================================================
;;;; THE FASL CARRIES THE VALUES. THAT IS THE WHOLE POINT.
;;;; ==============================================================================
;;;;
;;;; DEFINE-TYPELIB-CONSTANTS runs the reader AT MACROEXPANSION TIME and expands into literal
;;;; DEFCONSTANT forms holding literal integers. So the machine that COMPILES the file needs
;;;; the server installed, and the machine that LOADS the compiled file needs nothing at all.
;;;; A built application ships the constants inside its own fasls and never touches ITypeLib
;;;; again -- which matters because a released desktop app cannot assume Excel is present, and
;;;; must not fail to start on a machine where it is not.
;;;;
;;;; The cost of that is stated rather than hidden: the values are a SNAPSHOT of the developer
;;;; machine's server. See VERSION SKEW below.
;;;;
;;;; ==============================================================================
;;;; FLAT PER LIBRARY, NOT GROUPED BY ENUM -- and this was measured, not assumed
;;;; ==============================================================================
;;;;
;;;; The obvious design is one package (or one prefix) per enum: XlDirection::xlUp. Reading
;;;; the Scripting Runtime typelib says no. Of its seven enums, SIX are named like this:
;;;;
;;;;     __MIDL___MIDL_itf_scrrun_0001_0001_0002
;;;;
;;;; They are anonymous enums in the IDL, and MIDL generated those names. Their MEMBERS are
;;;; the useful, documented, publicly-known constants -- WindowsFolder, SystemFolder,
;;;; TemporaryFolder, ReadOnly, Hidden -- but the enum they belong to has no name a human has
;;;; ever seen or would ever type. Grouping by enum would file the constants people actually
;;;; use under identifiers nobody can guess.
;;;;
;;;; So constants are flat within one package per LIBRARY, which is also how VBA exposes them
;;;; and therefore how every existing example and every MSDN page is written. The enum name is
;;;; kept in the docstring, where it is informative and harmless.
;;;;
;;;; ==============================================================================
;;;; DUPLICATE NAMES: TWO KINDS, ONLY ONE OF WHICH IS A PROBLEM
;;;; ==============================================================================
;;;;
;;;; Flattening means two enums can contribute the same name. That is only sometimes wrong,
;;;; and the difference matters:
;;;;
;;;;   SAME NAME, SAME VALUE     -- emitted once. Common and harmless: libraries repeat a
;;;;                                constant across related enums. The Scripting Runtime does
;;;;                                it in one enum alone (TristateUseDefault and TristateMixed
;;;;                                are both -2), which is not even a name clash.
;;;;   SAME NAME, DIFFERENT VALUE -- SIGNALLED. There is no defensible choice between them:
;;;;                                picking either silently gives some call site the other
;;;;                                enum's number, which is a legal argument that does
;;;;                                something else. The house rule is loudly, so it is loudly.
;;;;
;;;; The case-insensitive reader makes this sharper than it looks: xlUp and xlUP are distinct
;;;; in COM and the SAME SYMBOL here. That is a real hazard in a large Office typelib and it is
;;;; exactly what the check catches (docs/coalton-patterns.md s4 records the same collision
;;;; class biting from the Coalton side).
;;;;
;;;; ==============================================================================
;;;; VERSION SKEW (pre-publication issue 181, Q2)
;;;; ==============================================================================
;;;;
;;;; Constants are baked at compile time, so a wrapper built against one version of a server
;;;; can be loaded on a machine running another. Three options were available: fail to load,
;;;; degrade silently, or record and check. Failing to load is wrong -- the app must start on
;;;; a machine with no Office at all -- and degrading silently is the thing this tree keeps
;;;; catching.
;;;;
;;;; So the generated package RECORDS the library it was built from, and CHECK-TYPELIB-VERSION
;;;; compares that record against the installed server WHEN THE APP ASKS. That puts the check
;;;; where the app knows it is about to automate something, rather than at load time where the
;;;; server may legitimately be absent. It is opt-in on purpose, and it signals rather than
;;;; returning a flag, because a silently mismatched constant table is the failure being
;;;; guarded against.

(in-package #:aion/windows/com)

;;; --- conditions ---------------------------------------------------------------

(define-condition typelib-error (com-error) ()
  (:documentation "A failure reading a type library."))

(define-condition no-type-information (typelib-error)
  ((source :initarg :source :initform nil :reader no-type-information-source))
  (:report
   (lambda (c stream)
     (format stream "COM: ~A has no type information.

A server may implement IDispatch without shipping a type library -- GetTypeInfoCount returns
zero and there is nothing to generate from. Such a server can still be automated through the
generic accessor (COM:INVOKE with a member name), which is why that path is not going away."
             (or (no-type-information-source c) "the object"))))
  (:documentation "The server implements IDispatch but exposes no ITypeInfo."))

(define-condition typelib-name-collision (typelib-error)
  ((clashes :initarg :clashes :initform '() :reader typelib-name-collision-clashes))
  (:report
   (lambda (c stream)
     (format stream "COM: ~D constant name~:P flatten to one Lisp symbol with DIFFERENT values.~%~%"
             (length (typelib-name-collision-clashes c)))
     (loop for (symbol . entries) in (typelib-name-collision-clashes c)
           do (format stream "  ~A~%" symbol)
              (loop for e in entries
                    ;; ~S rather than ~D: a value can be a string, and `A_FORMATRTF =
                    ;; Rich Text Format (*.rtf)' in a report about ambiguity is its own small
                    ;; ambiguity. (~D would not ERROR on one -- it falls back to ~A -- it would
                    ;; just quietly drop the quotes.)
                    do (format stream "      ~A = ~S~@[  (enum ~A)~]~%"
                               (getf e :com-name) (getf e :value) (getf e :enum))))
     (format stream "~%Lisp's reader is case-insensitive, so xlUp and xlUP are one symbol here. Emitting either value would give some call site the other's number -- a legal argument that quietly does something else. Exclude one with :EXCEPT, or narrow the generation with :ONLY.")))
  (:documentation "Two constants flattened to one Lisp symbol with different values.

Reports EVERY clash rather than the first, for the reason VERIFY-LAYOUTS does: they arrive in
families, and one per rebuild turns a five-minute fix into an afternoon."))

(define-condition typelib-version-mismatch (typelib-error)
  ((library :initarg :library :initform nil :reader typelib-version-mismatch-library)
   (built :initarg :built :initform nil :reader typelib-version-mismatch-built)
   (found :initarg :found :initform nil :reader typelib-version-mismatch-found))
  (:report
   (lambda (c stream)
     (format stream "COM: ~A ~A is installed, but these constants were generated against ~A.

The constant values compiled into this image may not be the ones this server uses. Rebuild
against the installed version, or verify the constants you rely on are unchanged."
             (typelib-version-mismatch-library c)
             (typelib-version-mismatch-found c)
             (typelib-version-mismatch-built c))))
  (:documentation "The installed type library is not the one the constants were built from."))

;;; --- reading strings back out --------------------------------------------------

(defun %bstr-to-lisp (pointer)
  "A BSTR to a Lisp string, FREEING IT. NIL for a null pointer.

Every BSTR out-parameter in ITypeLib and ITypeInfo is allocated by the server and owned by
the caller. Reading a large typelib touches thousands of them, so leaking here is not a
rounding error."
  (unless (cffi:null-pointer-p pointer)
    (prog1 (cffi:foreign-string-to-lisp pointer :encoding :utf-16le
                                                :count (* 2 (ffi:sys-string-len pointer)))
      (ffi:sys-free-string pointer))))

(defun %documentation-name (kind this id)
  "The NAME field of GetDocumentation on ITypeLib (KIND :lib) or ITypeInfo (KIND :info).

Only the name is requested; the help string and help file are asked for as null pointers,
which both interfaces accept and which saves allocating and freeing two BSTRs per member on a
path that runs once per constant."
  (cffi:with-foreign-object (p-name :pointer)
    (setf (cffi:mem-ref p-name :pointer) (cffi:null-pointer))
    (let ((hr (ecase kind
                (:lib (ffi:itypelib-get-documentation
                       this id p-name (cffi:null-pointer)
                       (cffi:null-pointer) (cffi:null-pointer)))
                (:info (ffi:itypeinfo-get-documentation
                        this id p-name (cffi:null-pointer)
                        (cffi:null-pointer) (cffi:null-pointer))))))
      (when (w:hresult-succeeded-p hr)
        (%bstr-to-lisp (cffi:mem-ref p-name :pointer))))))

;;; --- getting hold of a type library ---------------------------------------------

(defun %typelib-of-object (object prog-id)
  "The ITypeLib describing OBJECT. Caller releases it, AND MUST KEEP OBJECT ALIVE -- see
%CALL-WITH-TYPELIB, which is the only caller for exactly that reason.

Routed through a LIVE OBJECT -- IDispatch::GetTypeInfo, then ITypeInfo::GetContainingTypeLib
-- rather than through the registry. That is deliberate: it reads the description of the
server that would actually answer a call, so it cannot describe a version that is registered
but is not the one COM would activate."
  (cffi:with-foreign-object (pp-info :pointer)
    (setf (cffi:mem-ref pp-info :pointer) (cffi:null-pointer))
    (let ((hr (ffi:idispatch-get-type-info (com-object-pointer object) 0 0 pp-info)))
      (unless (and (w:hresult-succeeded-p hr)
                   (not (cffi:null-pointer-p (cffi:mem-ref pp-info :pointer))))
        (error 'no-type-information :source prog-id)))
    (let ((info (cffi:mem-ref pp-info :pointer)))
      (unwind-protect
           (cffi:with-foreign-objects ((pp-lib :pointer) (p-index :uint32))
             (setf (cffi:mem-ref pp-lib :pointer) (cffi:null-pointer))
             (let ((hr (ffi:itypeinfo-get-containing-type-lib info pp-lib p-index)))
               (unless (w:hresult-succeeded-p hr)
                 (error 'no-type-information :source prog-id)))
             (cffi:mem-ref pp-lib :pointer))
        (ffi:iunknown-release info)))))

(defun %typelib-from-file (path)
  "The ITypeLib in the file at PATH -- a .tlb, or a .dll or .exe with one bound in.

Loaded with REGKIND_NONE. See the constant's docstring: the default would REGISTER the library
machine-wide, which is a write to HKEY_CLASSES_ROOT that reading a description has no business
performing and that would need elevation to succeed."
  (cffi:with-foreign-object (pp-lib :pointer)
    (setf (cffi:mem-ref pp-lib :pointer) (cffi:null-pointer))
    (w:with-wide-string (w (uiop:native-namestring path))
      (w:check-hresult (ffi:load-type-lib-ex w ffi:+regkind-none+ pp-lib)
                       :operation :load-type-lib))
    (cffi:mem-ref pp-lib :pointer)))

(defun %call-with-typelib (prog-id file function)
  "Call FUNCTION with an ITypeLib pointer, releasing it -- and anything acquired to get it --
however FUNCTION exits.

============================================================================
THE OBJECT IS HELD FOR THE WHOLE READ, AND THAT IS NOT BOOKKEEPING.
============================================================================

An ITypeLib reference does NOT keep alive the object it was obtained from, and at least one
major server empties its type information when the object goes away. Measured, on Excel:

  object released first, then the library read   ->  GetTypeInfoCount = 0,    0 constants
  object held while the library is read          ->  GetTypeInfoCount = 1036, thousands

Every call returns S_OK in both cases. Nothing fails; the library simply describes nothing,
and a generator built on it emits an empty package for the single most important target it
has. An earlier draft of this file released the object as soon as it had the ITypeLib, on the
reasonable-sounding grounds that the reference had been handed over -- and Word tolerated it,
which is how the bug survived the first round of testing.

So the object outlives the read, and the ordering is enforced HERE rather than left to each
caller to remember."
  (cond
    ((and prog-id file)
     (error 'typelib-error :detail "give :OBJECT or :FILE, not both"))
    (prog-id
     (with-com-object (object (object-from-prog-id prog-id))
       (let ((lib (%typelib-of-object object prog-id)))
         (unwind-protect (funcall function lib)
           (ffi:iunknown-release lib)))))
    (file
     (let ((lib (%typelib-from-file file)))
       (unwind-protect (funcall function lib)
         (ffi:iunknown-release lib))))
    (t (error 'typelib-error :detail "give one of :OBJECT or :FILE"))))

(defmacro %with-typelib ((var &key object file) &body body)
  "Bind VAR to an ITypeLib pointer for BODY, releasing it however BODY exits.

Runs inside the apartment: a type library obtained from a live object belongs to the thread
that created the object, exactly as the object does."
  `(in-apartment ()
     (%call-with-typelib ,object ,file (lambda (,var) ,@body))))

;;; --- what a library says about itself ---------------------------------------------

(defun %information (lib)
  "LIB's own description, from a borrowed ITypeLib pointer."
  (cffi:with-foreign-object (pp-attr :pointer)
    (setf (cffi:mem-ref pp-attr :pointer) (cffi:null-pointer))
    (w:check-hresult (ffi:itypelib-get-lib-attr lib pp-attr) :operation :get-lib-attr)
    (let ((attr (cffi:mem-ref pp-attr :pointer)))
      (unwind-protect
           (list :name (%documentation-name :lib lib ffi:+typelib-index-self+)
                 :major (cffi:foreign-slot-value attr '(:struct ffi:tlibattr) 'ffi::w-major-ver-num)
                 :minor (cffi:foreign-slot-value attr '(:struct ffi:tlibattr) 'ffi::w-minor-ver-num)
                 :type-count (ffi:itypelib-get-type-info-count lib))
        (ffi:itypelib-release-tlib-attr lib attr)))))

(defun typelib-information (&key object file)
  "A plist describing the type library: :NAME, :MAJOR, :MINOR, :TYPE-COUNT.

The record a generated package keeps so CHECK-TYPELIB-VERSION has something to compare."
  (%with-typelib (lib :object object :file file) (%information lib)))

;;; --- reading the constants -----------------------------------------------------

(defun %constants-of-type-info (info enum-name)
  "Every VAR_CONST in INFO, as plists. INFO is borrowed, not released here."
  (cffi:with-foreign-object (pp-attr :pointer)
    (setf (cffi:mem-ref pp-attr :pointer) (cffi:null-pointer))
    (w:check-hresult (ffi:itypeinfo-get-type-attr info pp-attr) :operation :get-type-attr)
    (let ((attr (cffi:mem-ref pp-attr :pointer)))
      (unwind-protect
           (loop with n = (cffi:foreign-slot-value attr '(:struct ffi:typeattr) 'ffi::c-vars)
                 for i below n
                 append (cffi:with-foreign-object (pp-var :pointer)
                          (setf (cffi:mem-ref pp-var :pointer) (cffi:null-pointer))
                          (w:check-hresult (ffi:itypeinfo-get-var-desc info i pp-var)
                                           :operation :get-var-desc)
                          (let ((var (cffi:mem-ref pp-var :pointer)))
                            (unwind-protect
                                 (when (= ffi:+var-const+
                                          (cffi:foreign-slot-value var '(:struct ffi:vardesc)
                                                                   'ffi::varkind))
                                   (let ((memid (cffi:foreign-slot-value
                                                 var '(:struct ffi:vardesc) 'ffi::memid))
                                         (value (cffi:foreign-slot-value
                                                 var '(:struct ffi:vardesc) 'ffi::value))
                                         (flags (cffi:foreign-slot-value
                                                 var '(:struct ffi:vardesc) 'ffi::w-var-flags)))
                                     (list (list :com-name (%documentation-name :info info memid)
                                                 :value (variant-to-lisp value)
                                                 :enum enum-name
                                                 ;; REPORTED, NOT FILTERED -- and it is NOT the
                                                 ;; same signal as a leading underscore. Measured:
                                                 ;; Excel sets this on 0 of 2328 constants and
                                                 ;; underscores 2; Access sets it on 141 of 1736
                                                 ;; and underscores none. Two independent markers,
                                                 ;; so filtering on this one would not have fixed
                                                 ;; the Excel collision that COM-NAME-TO-LISP-NAME
                                                 ;; describes. Dropping members would also make
                                                 ;; the reader lossy for a caller with a reason
                                                 ;; to want them.
                                                 :hidden (logtest flags
                                                                  (logior ffi:+varflag-fhidden+
                                                                          ffi:+varflag-frestricted+))))))
                              (ffi:itypeinfo-release-var-desc info var)))))
        (ffi:itypeinfo-release-type-attr info attr)))))

(defun %anonymous-enum-p (name)
  "True for a name MIDL generated for an unnamed enum, e.g.
__MIDL___MIDL_itf_scrrun_0001_0001_0002. Six of the Scripting Runtime's seven enums are
these; their members are ordinary documented constants regardless."
  (and (stringp name) (>= (length name) 2) (string= "__" (subseq name 0 2))))

(defun typelib-constants (&key object file)
  "Every enum and module constant in a type library, as a list of plists.

Each entry has :COM-NAME (the server's own spelling), :VALUE, and :ENUM (the type it came
from, or NIL when MIDL generated that name for an unnamed enum).

THE RUNTIME HALF, usable on its own. DEFINE-TYPELIB-CONSTANTS is a thin layer over this, so
the reading can be exercised, printed and diffed at a REPL without expanding a macro or
defining anything -- which is also how the suite tests it."
  (%with-typelib (lib :object object :file file) (%constants lib)))

(defun typelib-contents (&key object file)
  "(values INFORMATION CONSTANTS) from ONE acquisition of the library.

Exists because the two are wanted together and acquiring by :OBJECT means CoCreateInstance.
Calling TYPELIB-INFORMATION and TYPELIB-CONSTANTS in sequence against Excel STARTS EXCEL
TWICE -- two out-of-process servers launched and torn down at compile time, which is slow
enough to notice and leaves twice as much to go wrong on the cleanup path that #109 is
already about."
  (%with-typelib (lib :object object :file file)
    (values (%information lib) (%constants lib))))

(defun %constants (lib)
  "Every enum and module constant in a borrowed ITypeLib pointer."
  (loop with n = (ffi:itypelib-get-type-info-count lib)
          for i below n
          append (cffi:with-foreign-object (p-kind :int)
                   (when (w:hresult-succeeded-p (ffi:itypelib-get-type-info-type lib i p-kind))
                     ;; TKIND_MODULE as well as TKIND_ENUM: some libraries put their constants
                     ;; in a module rather than an enum, and a reader that only looked at enums
                     ;; would return a short list rather than an error.
                     (when (member (cffi:mem-ref p-kind :int)
                                   (list ffi:+tkind-enum+ ffi:+tkind-module+))
                       (cffi:with-foreign-object (pp-info :pointer)
                         (setf (cffi:mem-ref pp-info :pointer) (cffi:null-pointer))
                         (when (w:hresult-succeeded-p (ffi:itypelib-get-type-info lib i pp-info))
                           (let ((info (cffi:mem-ref pp-info :pointer)))
                             (unwind-protect
                                  (let ((name (%documentation-name :info info ffi:+memberid-nil+)))
                                    (%constants-of-type-info
                                     info (unless (%anonymous-enum-p name) name)))
                               (ffi:iunknown-release info))))))))))

;;; --- COM spelling to Lisp spelling ------------------------------------------------

(defun %tidy-dashes (string)
  "Collapse runs of dashes and trim them from both ends, so a leading underscore or an
embedded run does not produce --FOO-- or a symbol whose name begins with a dash."
  (let ((out (make-string-output-stream))
        (pending nil)
        (any nil))
    (loop for c across string
          do (if (char= c #\-)
                 (when any (setf pending t))
                 (progn (when pending (write-char #\- out) (setf pending nil))
                        (write-char c out)
                        (setf any t))))
    (get-output-stream-string out)))

(defun com-name-to-lisp-name (name)
  "The kebab-case rendering of a COM identifier: xlUp -> \"xl-up\", CDRom -> \"cd-rom\".

A break goes before a capital that either FOLLOWS A LOWER-CASE LETTER or PRECEDES one.

The second clause keeps runs of capitals together: without it CDRom is c-d-rom, and with it
the run ends one character before the next word starts, which is where it actually ends.

The first clause says LOWER-CASE rather than `not upper-case', which is the same thing except
after a DIGIT -- and the difference decides several real Excel names. Binding a digit to what
precedes it gives xl-r1c1 and xl3d-pie; treating a digit as a word boundary gives xl-r1-c1 and
xl3-d-pie, splitting `R1C1' and `3D' down the middle. Neither reading is forced by the
characters, so it is settled on the names that exist.

A LEADING UNDERSCORE SURVIVES, AS `%'. It is the one piece of punctuation in a COM name that
carries meaning: an underscore-prefixed member is the server marking it internal. Excel's
XlBuiltInDialog enum defines BOTH xlDialogPhonetic (656) and _xlDialogPhonetic (538), and an
early draft of this function trimmed the underscore and produced one symbol for two different
constants. % is what this codebase already spells `internal' with, and it keeps the two names
apart -- which is the point, because they are two names.

STILL NOT INJECTIVE, and that is why COM-NAME is carried alongside every constant rather than
recomputed: xlUp and xlUP both land here, Lisp's reader cannot tell them apart, and the
collision check in %RESOLVE-COLLISIONS is what turns that from a silent overwrite into a
report naming both."
  (let* ((first-real (or (position #\_ name :test #'char/=) (length name)))
         (internal (plusp first-real))
         (bare (subseq name first-real))
         (out (make-string-output-stream))
         (n (length bare)))
    (dotimes (i n)
      (let ((c (char bare i)))
        (cond
          ((or (char= c #\_) (char= c #\Space)) (write-char #\- out))
          ((and (upper-case-p c)
                (plusp i)
                (or (lower-case-p (char bare (1- i)))
                    (and (< (1+ i) n) (lower-case-p (char bare (1+ i))))))
           (write-char #\- out)
           (write-char (char-downcase c) out))
          (t (write-char (char-downcase c) out)))))
    (concatenate 'string (if internal "%" "")
                 (%tidy-dashes (get-output-stream-string out)))))

(defun constant-symbol-name (com-name)
  "The symbol name a constant is emitted under: xlUp -> \"+XL-UP+\".

WRAPPED IN PLUS SIGNS, which is the house spelling for a constant and, not incidentally, makes
a collision with COMMON-LISP impossible. A large Office typelib defines Count, Union, Replace,
Search and Length; the Scripting Runtime alone defines Normal, System, Directory and Alias.
Every one of those would be a package-lock violation emitted bare into a package that used CL,
and +NORMAL+ is none of them."
  (string-upcase (format nil "+~A+" (com-name-to-lisp-name com-name))))

;;; --- flattening, and the collisions it can cause ------------------------------------

(defun %resolve-collisions (constants)
  "CONSTANTS with duplicates removed, or a signalled TYPELIB-NAME-COLLISION.

Same symbol and same value is a duplicate and is dropped. Same symbol and a DIFFERENT value is
an ambiguity with no defensible resolution -- see this file's header -- so it is reported with
both original spellings and both enums, which is what someone needs in order to choose."
  (let ((by-symbol (make-hash-table :test #'equal))
        (kept '()))
    (dolist (entry constants)
      (let* ((symbol-name (constant-symbol-name (getf entry :com-name)))
             (seen (gethash symbol-name by-symbol)))
        (cond
          ((null seen)
           (setf (gethash symbol-name by-symbol) (list entry))
           (push (cons symbol-name entry) kept))
          ;; Same symbol, same value: the same constant said twice. Dropped, not reported.
          ;; EQUAL RATHER THAN EQL, because a value may be a STRING. Two constants read from
          ;; two enums are two distinct string objects even when they spell the same thing, and
          ;; EQL would call that a disagreement -- turning a harmless repeat into a refusal to
          ;; generate the library at all. EQUAL still compares numbers with EQL, so the common
          ;; case is unchanged.
          ((find (getf entry :value) seen :key (lambda (e) (getf e :value)) :test #'equal))
          ;; Same symbol, different value: no defensible choice. Collected for the report.
          (t (push entry (gethash symbol-name by-symbol))))))
    (let ((clashes (loop for name being the hash-keys of by-symbol using (hash-value entries)
                         when (rest entries)
                           collect (cons name (reverse entries)))))
      (when clashes
        (error 'typelib-name-collision :clashes (sort clashes #'string< :key #'car))))
    (nreverse (mapcar #'cdr kept))))

(defun %select (constants only except)
  "CONSTANTS filtered by the :ONLY and :EXCEPT lists of COM names, which are matched
case-insensitively because that is how everyone types them."
  (let ((keep (remove-if-not
               (lambda (e)
                 (and (or (null only)
                          (member (getf e :com-name) only :test #'string-equal))
                      (not (member (getf e :com-name) except :test #'string-equal))))
               constants)))
    ;; A filter that selects nothing is almost always a typo in the filter, and it would
    ;; otherwise produce an empty package with no complaint -- the silent-empty failure this
    ;; whole path is written to avoid.
    (when (and only (null keep))
      (error 'typelib-error
             :detail (format nil "the :ONLY list matched none of the ~D constants read"
                             (length constants))))
    keep))

;;; --- the macro -------------------------------------------------------------------

(defun expand-typelib-constants (package-name object file only except)
  "The expansion, as a function so it can be called and READ at a REPL.

A macro whose interesting half is only reachable by expanding it is a macro nobody debugs."
  (multiple-value-bind (info raw) (typelib-contents :object object :file file)
    (%expand-constants package-name info raw object file only except)))

(defun %expand-constants (package-name info raw object file only except)
  (let* ((constants (%resolve-collisions (%select raw only except)))
         (package-string (string package-name))
         (names (mapcar (lambda (e) (constant-symbol-name (getf e :com-name))) constants)))
    (when (null constants)
      (error 'typelib-error
             :detail (format nil "~A has a type library but no enum or module constants in it"
                             (or object file))))
    ;; THE PACKAGE IS CREATED HERE, DURING EXPANSION, not by the expansion. The emitted
    ;; DEFCONSTANT forms name symbols, and a symbol cannot be interned in a package that does
    ;; not exist yet -- so it has to exist before the forms are built. The DEFPACKAGE in the
    ;; expansion then states the same package for the compile-time and load-time environments,
    ;; which is what makes the fasl loadable in a fresh image that never ran this macro.
    (let* ((package (or (find-package package-string)
                        (make-package package-string :use '())))
           (symbols (mapcar (lambda (n) (intern n package)) names))
           (record (intern "*TYPELIB*" package)))
      `(progn
         (eval-when (:compile-toplevel :load-toplevel :execute)
           (defpackage ,package-string
             ;; :USE NOTHING. See CONSTANT-SYMBOL-NAME: the +...+ spelling already makes a
             ;; clash with COMMON-LISP impossible, and this keeps that true for the method
             ;; wrappers that will share the package later, where Count, Union and Replace are
             ;; not hypothetical.
             (:use)
             (:documentation ,(format nil "Constants read from the ~A type library ~D.~D."
                                      (getf info :name) (getf info :major) (getf info :minor)))
             (:export "*TYPELIB*" ,@names)))
         (defparameter ,record ',info
           "The type library these constants were generated from.

Pass it to COM:CHECK-TYPELIB-VERSION to compare against the installed server -- the constants
below are a snapshot of the machine that COMPILED this file.")
         ,@(loop for entry in constants
                 for symbol in symbols
                 ;; DEFCONSTANT ONLY WHERE RE-EVALUATION IS EQL-SAFE. Almost every automation
                 ;; constant is an I4, but a type library may legally hold a VT_BSTR one.
                 ;;
                 ;; DEFCONSTANT requires the new value to be EQL to the old one on every
                 ;; re-evaluation. Recompiling this file reads a FRESH string object with the
                 ;; same contents, and two distinct strings are never EQL however equal they
                 ;; look -- so the redefinition is an error, in the middle of generated code
                 ;; nobody wrote. (A string IS of course EQL to itself; it is the second object
                 ;; that is the problem, which is why the fix is about which DEFINER to use
                 ;; rather than about comparing more loosely.)
                 ;;
                 ;; Numbers, characters and symbols are EQL across re-evaluation, so they stay
                 ;; real constants. Everything else becomes a variable that simply rebinds.
                 collect `(,(if (typep (getf entry :value) '(or number character symbol))
                                'defconstant
                                'defparameter)
                           ,symbol ,(getf entry :value)
                            ,(format nil "~A = ~S~@[, from enum ~A~].~:[~; Marked internal by the server.~] ~A type library ~D.~D."
                                     (getf entry :com-name) (getf entry :value)
                                     (getf entry :enum) (getf entry :hidden)
                                     (getf info :name)
                                     (getf info :major) (getf info :minor))))
         ',(intern package-string :keyword)))))

(defmacro define-typelib-constants (package-name (&key object file only except))
  "Read a type library at COMPILE TIME and define PACKAGE-NAME holding its constants.

  (com:define-typelib-constants #:scripting (:object \"Scripting.FileSystemObject\"))
  scripting:+for-reading+  =>  1

OBJECT is a ProgID; the library is read from a live instance, so it describes the server COM
would actually activate. FILE is a path to a .tlb, .dll or .exe carrying one. ONLY and EXCEPT
are lists of COM names, matched case-insensitively.

The values are baked into the fasl -- see this file's header. The compiling machine needs the
server; the machine that loads the result does not, which is what lets a shipped application
start on a computer with no Office installed.

PREFER :FILE FOR A LARGE OUT-OF-PROCESS SERVER. Both routes give the same answer, and for
Office the difference is not small. Measured on one machine:

  Excel, from EXCEL.EXE          0.11s     1036 types, 2328 constants
  Word,  from MSWORD.OLB         0.01s      767 types, 3756 constants
  Word,  from Word.Application   2.19s      the same 3756
  Excel, from Excel.Application  did not finish in ten minutes

Every name costs a cross-process call when the server is out-of-process, and there are
thousands of them. WORSE, AND THE PART THAT SURPRISES PEOPLE: creating an Office server to
read its description leaves an EXCEL.EXE or WINWORD.EXE running with no window, one per build,
because releasing an interface does not make an out-of-process server quit (#109). Office
binaries carry their own type libraries, so :FILE reads the identical description in-process,
starts nothing and leaves nothing behind.

:OBJECT stays the better route for in-process servers and for anything where WHICH
registration COM would activate is the question being asked."
  (expand-typelib-constants package-name object file only except))

;;; --- the version check the app opts into -------------------------------------------

(defun check-typelib-version (recorded &key object file)
  "Compare RECORDED -- a generated package's *TYPELIB* plist -- against the installed library.

Signals TYPELIB-VERSION-MISMATCH when the MAJOR version differs. Returns the installed
library's plist otherwise, so a caller that wants to log what it found can.

MAJOR ONLY. A minor bump adds constants and does not renumber existing ones, so refusing on it
would fail on the common, harmless case and teach whoever hit it to stop calling this."
  (let ((found (typelib-information :object object :file file)))
    (unless (eql (getf recorded :major) (getf found :major))
      (error 'typelib-version-mismatch
             :library (or (getf found :name) (getf recorded :name))
             :built (format nil "~D.~D" (getf recorded :major) (getf recorded :minor))
             :found (format nil "~D.~D" (getf found :major) (getf found :minor))))
    found))
