;;;; naming-tests.lisp --- the COM-to-Lisp spelling transform, and what it must refuse.
;;;;
;;;; PURE. Every test here runs on a table of strings with no COM anywhere, which is the point:
;;;; the transform is the part of the generator that can be wrong on a machine where the live
;;;; tests all pass. A collision between xlUp and xlUP does not need Excel to be reasoned about
;;;; and must not need Excel to be caught.
;;;;
;;;; The cases below are real names from real type libraries, not invented ones. CDRom, StdIn
;;;; and TristateUseDefault were read out of the Scripting Runtime by the spike that produced
;;;; this file; the xl* names are Excel's.

(in-package #:aion/windows/com/tests)

(def-suite naming :description "COM identifiers rendered as Lisp names." :in all)
(in-suite naming)

(defun entry (com-name value &optional enum)
  (list :com-name com-name :value value :enum enum))

;;; --- the transform ---------------------------------------------------------------

(test camel-case-becomes-kebab-case
  (dolist (case '(("BinaryCompare"      . "binary-compare")
                  ("ForReading"         . "for-reading")
                  ("TristateUseDefault" . "tristate-use-default")
                  ("xlUp"               . "xl-up")
                  ("wdReplaceAll"       . "wd-replace-all")))
    (is (string= (cdr case) (com:com-name-to-lisp-name (car case)))
        "~S became ~S" (car case) (com:com-name-to-lisp-name (car case)))))

(test a-run-of-capitals-stays-together-until-the-word-ends
  "The clause that is easy to omit. Splitting before EVERY capital turns CDRom into c-d-rom
and StdIn into std-in only by luck; the run has to end one character before the next word
starts. CDRom and RamDisk are both in the Scripting Runtime, and they are the two shapes."
  (is (string= "cd-rom" (com:com-name-to-lisp-name "CDRom")))
  (is (string= "std-in" (com:com-name-to-lisp-name "StdIn")))
  (is (string= "ram-disk" (com:com-name-to-lisp-name "RamDisk")))
  (is (string= "html-document" (com:com-name-to-lisp-name "HTMLDocument"))))

(test a-digit-binds-to-what-precedes-it
  "The rule with a real choice in it, pinned on the names that forced it. A digit is NOT a
word boundary, so R1C1 and 3D survive as units. The first draft split after a digit, which
gave xl-r1-c1 and xl3-d-pie -- both cutting a name through the middle of the thing it is
named after. All four of these are real Excel constants."
  (is (string= "xl-a1" (com:com-name-to-lisp-name "xlA1")))
  (is (string= "xl-r1c1" (com:com-name-to-lisp-name "xlR1C1")))
  (is (string= "xl3d-pie" (com:com-name-to-lisp-name "xl3DPie")))
  (is (string= "xl-pie3d" (com:com-name-to-lisp-name "xlPie3D"))))

(test underscores-inside-a-name-become-single-separators
  (is (string= "a-b" (com:com-name-to-lisp-name "a___b")))
  (is (string= "trailing" (com:com-name-to-lisp-name "trailing__"))))

(test a-leading-underscore-survives-as-a-percent-sign
  "MEASURED ON EXCEL, and it is not a style question. Excel's XlBuiltInDialog enum defines
BOTH of these:

    xlDialogPhonetic  = 656        _xlDialogPhonetic = 538

The underscore is the server marking a member internal. Trimming it -- which the first draft
did, along with the leading dashes MIDL names produce -- turned two different constants with
two different values into ONE symbol. Of 2328 constants in the Excel type library exactly two
carry a leading underscore, and they were exactly the two collisions."
  (is (string= "%xl-dialog-phonetic" (com:com-name-to-lisp-name "_xlDialogPhonetic")))
  (is (string= "xl-dialog-phonetic" (com:com-name-to-lisp-name "xlDialogPhonetic")))
  (is (string= "%midl-itf-scrrun" (com:com-name-to-lisp-name "__MIDL_itf_scrrun"))))

(test the-two-excel-dialog-constants-no-longer-collide
  "THE REGRESSION. This exact pair made the Excel type library ungeneratable -- the headline
target of the whole ticket -- and it was the transform's fault rather than an ambiguity in the
library. Both must survive, with both values."
  (let ((out (com::%resolve-collisions
              (list (entry "xlDialogPhonetic" 656 "XlBuiltInDialog")
                    (entry "_xlDialogPhonetic" 538 "XlBuiltInDialog")
                    (entry "xlDialogChartSourceData" 540 "XlBuiltInDialog")
                    (entry "_xlDialogChartSourceData" 541 "XlBuiltInDialog")))))
    (is (= 4 (length out)) "expected all four to survive, got ~D" (length out))
    (is (equal '("+XL-DIALOG-PHONETIC+" "+%XL-DIALOG-PHONETIC+"
                 "+XL-DIALOG-CHART-SOURCE-DATA+" "+%XL-DIALOG-CHART-SOURCE-DATA+")
               (mapcar (lambda (e) (com:constant-symbol-name (getf e :com-name))) out)))))

(test an-already-lower-case-name-is-left-alone
  (is (string= "count" (com:com-name-to-lisp-name "count"))))

;;; --- the emitted symbol name ------------------------------------------------------

(test a-constant-is-spelled-with-plus-signs
  (is (string= "+XL-UP+" (com:constant-symbol-name "xlUp")))
  (is (string= "+FOR-READING+" (com:constant-symbol-name "ForReading"))))

(test the-plus-signs-make-a-common-lisp-clash-impossible
"NOT DECORATION. The Scripting Runtime defines Directory; a large Office library adds Count,
Union, Replace, Search and Length. Emitted bare into a package that used CL, every one of these
is a package-lock violation at compile time. +DIRECTORY+ is not a CL symbol and cannot become
one, which is why the generated package can afford to be indifferent to what a server names
things.

Every name below is asserted to BE a CL symbol as well, so this tests the plus signs rather
than a list of words that were never going to collide."
  (dolist (name '("Directory" "Count" "Union" "Replace" "Length" "Search" "Set" "Values"
                  "Position" "Error" "Warning" "Number" "Read" "Write" "Append" "Remove"
                  "Sort" "Merge" "Map" "Last" "Fill" "Print" "Format" "Class" "Type"
                  "String" "Float" "Integer" "Vector" "Array" "T" "Pi"))
    (let ((emitted (com:constant-symbol-name name)))
      (is-false (find-symbol emitted (find-package :common-lisp))
                "~S emits ~S, which IS a CL symbol" name emitted)
      ;; and the control: the bare name really would have collided, so the assertion above is
      ;; testing the plus signs rather than a list of harmless words.
      (is-true (find-symbol (string-upcase name) (find-package :common-lisp))
               "~S is not a CL symbol, so it does not belong in this list" name))))

;;; --- flattening and collisions ------------------------------------------------------

(test the-same-constant-twice-is-emitted-once
  "Libraries repeat a constant across related enums. Two identical values under one name are
one constant said twice, not an ambiguity, and refusing them would make the generator fail on
ordinary type libraries."
  (let ((out (com::%resolve-collisions
              (list (entry "xlNone" -4142 "XlBorderWeight")
                    (entry "xlNone" -4142 "XlPasteType")
                    (entry "xlUp" -4162 "XlDirection")))))
    (is (= 2 (length out)) "expected 2 constants, got ~D" (length out))
    (is (equal '("xlNone" "xlUp") (mapcar (lambda (e) (getf e :com-name)) out))
        "the first occurrence should survive, in order")))

(test the-same-string-constant-twice-is-one-constant-not-a-conflict
  "EQL VS EQUAL, WITH TEETH. Two enums contributing the same string-valued constant hand back
two DISTINCT string objects, so an EQL comparison calls them a disagreement and refuses to
generate the whole library. COPY-SEQ here guarantees separate objects, which is exactly what
reading two VARDESCs out of a type library gives you.

Not hypothetical: 30 of the 10272 constants across the type libraries on this machine are
strings, and Access carries most of them."
  (let ((out (com::%resolve-collisions
              (list (entry "aFormatRtf" (copy-seq "Rich Text Format (*.rtf)") "E1")
                    (entry "aFormatRtf" (copy-seq "Rich Text Format (*.rtf)") "E2")))))
    (is (= 1 (length out)) "expected one constant, got ~D" (length out)))
  ;; and the control: two DIFFERENT strings under one name are still a real conflict
  (signals com:typelib-name-collision
    (com::%resolve-collisions (list (entry "aFormat" "Rich Text" "E1")
                                    (entry "aFormat" "Plain Text" "E2")))))

(test two-values-under-one-name-is-refused-not-picked
  "THE CHECK THIS FILE EXISTS FOR. Emitting either value gives some call site the other
enum's number -- a legal argument that quietly does the wrong thing, which is the failure mode
that has no error message anywhere."
  (signals com:typelib-name-collision
    (com::%resolve-collisions (list (entry "xlBoth" 1 "XlOne")
                                    (entry "xlBoth" 2 "XlTwo")))))

(test case-only-differences-collide-because-the-reader-is-case-insensitive
  "xlUp and xlUP are DIFFERENT constants in COM and the SAME symbol in Lisp. Nothing about
the COM names looks like a clash; the clash is created by the transform, so the transform is
what has to notice it."
  (signals com:typelib-name-collision
    (com::%resolve-collisions (list (entry "xlUp" -4162 "XlDirection")
                                    (entry "xlUP" 7 "XlSomethingElse")))))

(test every-clash-is-reported-not-only-the-first
  "One per rebuild turns a five-minute fix into an afternoon -- the reason VERIFY-LAYOUTS
collects too."
  (handler-case
      (progn (com::%resolve-collisions (list (entry "aOne" 1 "E1") (entry "aOne" 2 "E2")
                                             (entry "bTwo" 3 "E1") (entry "bTwo" 4 "E2")))
             (is-true nil "expected a collision to be signalled"))
    (com:typelib-name-collision (c)
      (is (= 2 (length (com:typelib-name-collision-clashes c)))
          "expected both clashes, got ~D" (length (com:typelib-name-collision-clashes c)))
      (let ((text (princ-to-string c)))
        (is-true (search "+A-ONE+" text) "the report should name the symbol: ~A" text)
        (is-true (search "aOne" text) "the report should give the COM spelling: ~A" text)
        (is-true (search "E2" text) "the report should name the enum: ~A" text)))))

;;; --- filtering ------------------------------------------------------------------------

(test only-and-except-select-case-insensitively
  (let ((all (list (entry "xlUp" 1) (entry "xlDown" 2) (entry "xlToLeft" 3))))
    (is (= 1 (length (com::%select all '("XLUP") '()))))
    (is (= 2 (length (com::%select all '() '("xlup")))))))

(test a-filter-that-matches-nothing-is-an-error-not-an-empty-package
  "A typo in :ONLY would otherwise produce a package with no constants and no complaint --
the silently-empty result that the layout assertions and pre-publication issue 206 were both about."
  (signals com:typelib-error
    (com::%select (list (entry "xlUp" 1)) '("xlNoSuchConstant") '())))
