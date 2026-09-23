;;;; typelib-tests.lisp --- constants read out of a real server, with known answers.
;;;;
;;;; The Scripting Runtime again, for the reason live-tests.lisp gives: it ships with every
;;;; Windows install and needs nothing added. For THIS file it has a second qualification --
;;;; its constants are small, stable, publicly documented and, crucially, SIGNED:
;;;;
;;;;     ForReading = 1   ForWriting = 2   ForAppending = 8
;;;;     TristateTrue = -1                 TristateUseDefault = -2
;;;;
;;;; TristateTrue is the check worth having. A VARDESC value read as unsigned gives 65535 or
;;;; 4294967295 instead of -1 -- a plausible-looking number, no error anywhere, and every call
;;;; using it silently wrong. It is the VARIANT_BOOL problem one layer down, and it is why the
;;;; assertions here are exact values rather than `is an integer'.
;;;;
;;;; ForAppending = 8 does a smaller job: 1, 2, 8 is not 1, 2, 3, so a reader that returned
;;;; ordinals rather than values would pass on the first two and fail here.

(in-package #:aion/windows/com/tests)

(def-suite typelib :description "Reading a type library from a live COM server." :in all)
(in-suite typelib)

(defparameter *scripting* "Scripting.FileSystemObject")

(defun constant-named (constants com-name)
  (find com-name constants :key (lambda (e) (getf e :com-name)) :test #'string=))

(defun value-of (constants com-name)
  (getf (constant-named constants com-name) :value))

;;; --- the library describes itself ------------------------------------------------

(test a-live-server-yields-its-type-library
  "IDispatch::GetTypeInfo then ITypeInfo::GetContainingTypeLib -- the route that describes
the server COM would actually activate, rather than whatever the registry lists."
  (let ((info (com:typelib-information :object *scripting*)))
    (is (string= "Scripting" (getf info :name)) "library name was ~S" (getf info :name))
    (is (integerp (getf info :major)))
    (is (plusp (getf info :type-count))
        "GetTypeInfoCount returned ~S" (getf info :type-count))))

(test get-type-info-count-is-read-as-a-count-not-an-hresult
  "ITypeLib::GetTypeInfoCount returns UINT directly, unlike IDispatch::GetTypeInfoCount which
returns HRESULT through an out-parameter. Reading this one as an HRESULT makes a non-empty
library look like a failure and an empty one look like success. The Scripting Runtime has
about thirty types; anything that looks like 0 or like an HRESULT is the bug."
  (let ((n (getf (com:typelib-information :object *scripting*) :type-count)))
    (is (< 1 n 1000) "a plausible type count is not ~D" n)))

;;; --- the constants themselves -----------------------------------------------------

(test the-documented-constants-come-back-with-their-documented-values
  (let ((constants (com:typelib-constants :object *scripting*)))
    (is (= 1 (value-of constants "ForReading")))
    (is (= 2 (value-of constants "ForWriting")))
    (is (= 8 (value-of constants "ForAppending"))
        "1, 2, 8 -- a reader returning ordinals passes the first two and fails here")
    (is (= 0 (value-of constants "BinaryCompare")))
    (is (= 1 (value-of constants "TextCompare")))))

(test a-negative-constant-is-negative
  "THE HEADLINE. Read as unsigned, TristateTrue is 65535 and TristateUseDefault is 65534 --
both plausible integers, no error, and every call using them quietly wrong. Same class as
VARIANT_TRUE being -1, one layer further down."
  (let ((constants (com:typelib-constants :object *scripting*)))
    (is (= -1 (value-of constants "TristateTrue")))
    (is (= -2 (value-of constants "TristateUseDefault")))
    (is (= 0 (value-of constants "TristateFalse")))))

(test constants-from-anonymous-enums-are-still-read
  "Six of the Scripting Runtime's seven enums are unnamed in the IDL, so MIDL called them
__MIDL___MIDL_itf_scrrun_0001_0001_0002. Their members are the ordinary documented constants
everyone uses. A generator that grouped by enum name, or skipped enums whose names looked
generated, would lose most of the library -- which is why constants are flat per library."
  (let ((constants (com:typelib-constants :object *scripting*)))
    (is (= 0 (value-of constants "WindowsFolder")))
    (is (= 1 (value-of constants "SystemFolder")))
    (is (= 2 (value-of constants "TemporaryFolder")))
    (is (= 2 (value-of constants "Hidden")))
    (is (null (getf (constant-named constants "WindowsFolder") :enum))
        "an enum name MIDL generated should not be reported as one")
    (is (string= "Tristate" (getf (constant-named constants "TristateTrue") :enum))
        "a REAL enum name should be kept -- it is the useful half of the docstring")))

(test the-reader-returns-a-substantial-number-of-constants
  "Guards the silently-empty result. If VARDESC.varkind lands on padding -- which is what a
mis-sized ELEMDESC does -- every variable stops looking like a constant, the reader returns
NIL and nothing anywhere reports that something did not happen."
  (let ((constants (com:typelib-constants :object *scripting*)))
    (is (< 20 (length constants))
        "expected the Scripting Runtime's ~30 constants, got ~D" (length constants))))

;;; --- reading from a file ------------------------------------------------------------

(test a-type-library-can-be-read-from-a-file-without-registering-it
  "The other source. LoadTypeLibEx under REGKIND_DEFAULT would WRITE to HKEY_CLASSES_ROOT --
inspecting a file must not install it, and on a non-elevated session the attempt fails rather
than silently doing nothing, so a wrong REGKIND is visible here."
  (let ((scrrun (probe-file (concatenate 'string (or (uiop:getenv "SystemRoot") "C:/Windows")
                                         "/System32/scrrun.dll"))))
    (if scrrun
        (let ((info (com:typelib-information :file scrrun)))
          (is (string= "Scripting" (getf info :name))
              "reading ~A gave library ~S" scrrun (getf info :name)))
        (skip "scrrun.dll is not present on this machine"))))

;;; --- the largest library on the machine, if it is here ---------------------------------

(defparameter *excel*
  "C:/Program Files/Microsoft Office/root/Office16/EXCEL.EXE"
  "Excel carries its own type library, so this reads Excel's whole constant surface WITHOUT
starting Excel. Measured on this machine: 0.11s from the file against 2.19s for Word from a
live object, and Excel from a live object did not finish in ten minutes -- every name costs a
cross-process call when the server is out-of-process, and there are thousands.")

(test the-excel-type-library-generates-without-a-collision
  "THE HEADLINE TARGET, end to end on real data. 2328 constants across 1036 types, including
the xlDialogPhonetic / _xlDialogPhonetic pair that made this library ungeneratable until the
transform stopped trimming a leading underscore.

Skipped where Office is not installed, which is honest rather than convenient: it is the only
library on hand big enough for scale and collisions to be real rather than argued about."
  (let ((excel (probe-file *excel*)))
    (if (null excel)
        (skip "Excel is not installed at ~A" *excel*)
        (multiple-value-bind (info raw) (com:typelib-contents :file excel)
          (is (string= "Excel" (getf info :name)))
          (is (< 500 (getf info :type-count))
              "expected ~1000 types, got ~D" (getf info :type-count))
          (is (< 2000 (length raw)) "expected ~2300 constants, got ~D" (length raw))
          ;; The collision check must PASS here -- it is not merely that it fires correctly.
          (let ((resolved (com::%resolve-collisions raw)))
            (is (< 2000 (length resolved))))
          (is (= -4162 (getf (constant-named raw "xlUp") :value))
              "xlUp is the constant every Excel example on the internet uses")
          ;; both halves of the pair, with both values
          (is (= 656 (getf (constant-named raw "xlDialogPhonetic") :value)))
          (is (= 538 (getf (constant-named raw "_xlDialogPhonetic") :value)))
          ;; AND THE FLAG IS NOT THE SAME SIGNAL, which is the reason the fix had to be in the
          ;; transform. Not one of Excel's 2328 constants sets VARFLAG_FHIDDEN -- so filtering
          ;; hidden members, the obvious other way to make the collision go away, would have
          ;; filtered nothing at all and left Excel exactly as ungeneratable as before.
          ;; (Access does use the flag, on 141 of its constants, and underscores none of them.
          ;; The two markers are independent, so neither substitutes for the other.)
          (is (= 0 (count-if (lambda (e) (getf e :hidden)) raw))
              "Excel marks no constant hidden; if that changed, re-read the note above")))))

;;; --- the macro ------------------------------------------------------------------------

(test the-macro-defines-a-package-of-real-constants
  "Expanded and evaluated here rather than at this file's compile time, so that a failure is
a failing TEST rather than a file that will not compile -- and so the suite reports it as one
result among many instead of taking the whole system down with it."
  (let ((*package* (find-package :aion/windows/com/tests)))
    (eval (com:expand-typelib-constants "AION-TYPELIB-TEST-SCRIPTING" *scripting* nil nil nil)))
  (let ((package (find-package "AION-TYPELIB-TEST-SCRIPTING")))
    (is-true package "the macro did not define the package")
    (when package
      (is (= 1 (symbol-value (find-symbol "+FOR-READING+" package))))
      (is (= 8 (symbol-value (find-symbol "+FOR-APPENDING+" package))))
      (is (= -1 (symbol-value (find-symbol "+TRISTATE-TRUE+" package))))
      (is (= 2 (symbol-value (find-symbol "+TEMPORARY-FOLDER+" package)))))))

(test the-generated-constants-are-exported-and-documented
  (let ((package (find-package "AION-TYPELIB-TEST-SCRIPTING")))
    (if (null package)
        (skip "the generating test did not run")
        (multiple-value-bind (symbol status) (find-symbol "+FOR-READING+" package)
          (is (eq :external status) "+FOR-READING+ is ~S, not external" status)
          (let ((doc (documentation symbol 'variable)))
            (is-true doc "a generated constant should carry a docstring")
            (is-true (search "ForReading" doc)
                     "the docstring should give the COM spelling, which is what MSDN uses: ~S"
                     doc))))))

(test the-generated-package-does-not-use-common-lisp
  "It must be able to hold a constant named for anything a server calls a thing. See
naming-tests: Count, Union and Replace are all Office constants."
  (let ((package (find-package "AION-TYPELIB-TEST-SCRIPTING")))
    (if (null package)
        (skip "the generating test did not run")
        (is (null (package-use-list package))
            "the generated package uses ~S" (package-use-list package)))))

(test only-generates-a-narrow-package
  "The Excel typelib is enormous, and generating all of it is sometimes not what is wanted
(pre-publication issue 181, Q5). :ONLY is the answer, and it is checked here against a filter that keeps two
of about thirty constants."
  (let ((*package* (find-package :aion/windows/com/tests)))
    (eval (com:expand-typelib-constants "AION-TYPELIB-TEST-NARROW" *scripting* nil
                                        '("ForReading" "ForWriting") nil)))
  (let ((package (find-package "AION-TYPELIB-TEST-NARROW")))
    (is-true package)
    (when package
      (is (= 1 (symbol-value (find-symbol "+FOR-READING+" package))))
      (is-false (find-symbol "+FOR-APPENDING+" package)
                ":ONLY let through a constant it did not name")
      ;; *TYPELIB* is exported too, so the count is the constants plus that one record.
      (is (= 3 (let ((n 0)) (do-external-symbols (s package n) (declare (ignore s)) (incf n))))
          "expected two constants and the *TYPELIB* record"))))

;;; --- values that are not integers ---------------------------------------------------

(test a-string-valued-constant-is-emitted-as-a-variable-not-a-constant
  "MEASURED, NOT HYPOTHETICAL. Of 10272 constants across seven type libraries on this machine,
30 are strings -- Access alone defines A_FORMATRTF = \"Rich Text Format (*.rtf)\".

DEFCONSTANT requires the new value to be EQL to the old on every re-evaluation. Recompiling
reads a FRESH string object with the same contents, and two distinct strings are never EQL
however equal they look -- so the redefinition signals, in the middle of generated code nobody
wrote. Numbers, characters and symbols survive re-evaluation EQL and stay real constants;
anything else is emitted as a DEFPARAMETER."
  (let* ((info '(:name "Fake" :major 1 :minor 0))
         (form (com::%expand-constants "AION-TYPELIB-TEST-VALUE-KINDS" info
                                       (list (entry "aFormatRtf" "Rich Text Format (*.rtf)")
                                             (entry "xlUp" -4162))
                                       nil "fake.tlb" nil nil))
         (definers (loop for sub in form
                         when (and (consp sub) (member (first sub) '(defconstant defparameter))
                                   (search "+" (string (second sub))))
                           collect (cons (string (second sub)) (first sub)))))
    (is (eq 'defparameter (cdr (assoc "+A-FORMAT-RTF+" definers :test #'string=)))
        "the string constant was emitted as ~S" (assoc "+A-FORMAT-RTF+" definers :test #'string=))
    (is (eq 'defconstant (cdr (assoc "+XL-UP+" definers :test #'string=)))
        "an integer constant should still be a real constant")))

;;; --- version skew (pre-publication issue 181, Q2) --------------------------------------------------

(test the-generated-package-records-what-it-was-built-from
  (let ((package (find-package "AION-TYPELIB-TEST-SCRIPTING")))
    (if (null package)
        (skip "the generating test did not run")
        (let ((record (symbol-value (find-symbol "*TYPELIB*" package))))
          (is (string= "Scripting" (getf record :name)))
          (is (integerp (getf record :major)))))))

(test a-matching-version-passes-the-check
  (let ((package (find-package "AION-TYPELIB-TEST-SCRIPTING")))
    (if (null package)
        (skip "the generating test did not run")
        (let ((record (symbol-value (find-symbol "*TYPELIB*" package))))
          (finishes (com:check-typelib-version record :object *scripting*))))))

(test a-different-major-version-signals-rather-than-degrading
  "The constants are baked into the fasl, so an app can load them beside a server they were
not generated from. The house rule is loudly: this must not return a flag that a caller can
forget to look at."
  (let ((record (list :name "Scripting" :major 99 :minor 0)))
    (signals com:typelib-version-mismatch
      (com:check-typelib-version record :object *scripting*))))

(test a-minor-version-difference-is-tolerated
  "A minor bump adds constants without renumbering existing ones. Refusing on it would fail
the common harmless case and teach whoever hit it to stop calling this."
  (let* ((found (com:typelib-information :object *scripting*))
         (record (list :name "Scripting" :major (getf found :major)
                       :minor (+ 50 (getf found :minor)))))
    (finishes (com:check-typelib-version record :object *scripting*))))

;;; --- the servers that have nothing to generate from -----------------------------------

(test a-bad-prog-id-fails-at-creation-not-silently
  (signals error (com:typelib-information :object "No.Such.Server.At.All")))

(test asking-for-neither-source-is-an-error
  "Both arguments default to NIL, so a caller who mistypes the keyword gets an error rather
than a mysterious null-pointer failure inside COM."
  (signals com:typelib-error (com:typelib-information))
  (signals com:typelib-error (com:typelib-information :object *scripting* :file "x.tlb")))
