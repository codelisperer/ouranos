;;;; cldr-plurals.lisp --- GENERATED. Do not edit.
;;;;
;;;; CLDR 48.2.1, plurals.json sha256 6c0a48e9bcfc25856f90202f703c2c7f89c105d6868f7712a943a6ed2dcbe8f4
;;;; Regenerate: sbcl --script scripts/fetch-cldr-plurals.lisp --write
;;;;
;;;; 224 locales. Each entry is (locale (category . condition) ...) where a
;;;; condition is (:OR (:AND (:REL operand modulus :EQ|:NEQ ((lo . hi) ...)) ...) ...)
;;;; and NIL means `always`. Categories are in CLDR precedence order;
;;;; `other` is the fallback and carries no test.

(in-package #:hyperion/plural)

(defparameter +cldr-plural-rules+
  '(("af" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ak" (:ONE :OR (:AND (:REL :N NIL :EQ ((0 . 1))))))
    ("am" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
           (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("an" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ar" (:ZERO :OR (:AND (:REL :N NIL :EQ ((0 . 0))))) (:ONE :OR
                                                          (:AND
                                                           (:REL :N NIL :EQ
                                                            ((1 . 1))))) (:TWO
                                                                          :OR
                                                                          (:AND
                                                                           (:REL
                                                                            :N
                                                                            NIL
                                                                            :EQ
                                                                            ((2
                                                                              . 2))))) (:FEW
                                                                                        :OR
                                                                                        (:AND
                                                                                         (:REL
                                                                                          :N
                                                                                          100
                                                                                          :EQ
                                                                                          ((3
                                                                                            . 10))))) (:MANY
                                                                                                       :OR
                                                                                                       (:AND
                                                                                                        (:REL
                                                                                                         :N
                                                                                                         100
                                                                                                         :EQ
                                                                                                         ((11
                                                                                                           . 99))))))
    ("ars" (:ZERO :OR (:AND (:REL :N NIL :EQ ((0 . 0))))) (:ONE :OR
                                                           (:AND
                                                            (:REL :N NIL :EQ
                                                             ((1 . 1))))) (:TWO
                                                                           :OR
                                                                           (:AND
                                                                            (:REL
                                                                             :N
                                                                             NIL
                                                                             :EQ
                                                                             ((2
                                                                               . 2))))) (:FEW
                                                                                         :OR
                                                                                         (:AND
                                                                                          (:REL
                                                                                           :N
                                                                                           100
                                                                                           :EQ
                                                                                           ((3
                                                                                             . 10))))) (:MANY
                                                                                                        :OR
                                                                                                        (:AND
                                                                                                         (:REL
                                                                                                          :N
                                                                                                          100
                                                                                                          :EQ
                                                                                                          ((11
                                                                                                            . 99))))))
    ("as" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
           (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("asa" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ast" (:ONE :OR
            (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("az" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("bal" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("be" (:ONE :OR
           (:AND (:REL :N 10 :EQ ((1 . 1))) (:REL :N 100 :NEQ ((11 . 11))))) (:FEW
                                                                              :OR
                                                                              (:AND
                                                                               (:REL
                                                                                :N
                                                                                10
                                                                                :EQ
                                                                                ((2
                                                                                  . 4)))
                                                                               (:REL
                                                                                :N
                                                                                100
                                                                                :NEQ
                                                                                ((12
                                                                                  . 14))))) (:MANY
                                                                                             :OR
                                                                                             (:AND
                                                                                              (:REL
                                                                                               :N
                                                                                               10
                                                                                               :EQ
                                                                                               ((0
                                                                                                 . 0))))
                                                                                             (:AND
                                                                                              (:REL
                                                                                               :N
                                                                                               10
                                                                                               :EQ
                                                                                               ((5
                                                                                                 . 9))))
                                                                                             (:AND
                                                                                              (:REL
                                                                                               :N
                                                                                               100
                                                                                               :EQ
                                                                                               ((11
                                                                                                 . 14))))))
    ("bem" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("bez" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("bg" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("bho" (:ONE :OR (:AND (:REL :N NIL :EQ ((0 . 1))))))
    ("blo" (:ZERO :OR (:AND (:REL :N NIL :EQ ((0 . 0))))) (:ONE :OR
                                                           (:AND
                                                            (:REL :N NIL :EQ
                                                             ((1 . 1))))))
    ("bm")
    ("bn" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
           (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("bo")
    ("br" (:ONE :OR
           (:AND (:REL :N 10 :EQ ((1 . 1)))
            (:REL :N 100 :NEQ ((11 . 11) (71 . 71) (91 . 91))))) (:TWO :OR
                                                                  (:AND
                                                                   (:REL :N 10
                                                                    :EQ
                                                                    ((2 . 2)))
                                                                   (:REL :N 100
                                                                    :NEQ
                                                                    ((12 . 12)
                                                                     (72 . 72)
                                                                     (92
                                                                      . 92))))) (:FEW
                                                                                 :OR
                                                                                 (:AND
                                                                                  (:REL
                                                                                   :N
                                                                                   10
                                                                                   :EQ
                                                                                   ((3
                                                                                     . 4)
                                                                                    (9
                                                                                     . 9)))
                                                                                  (:REL
                                                                                   :N
                                                                                   100
                                                                                   :NEQ
                                                                                   ((10
                                                                                     . 19)
                                                                                    (70
                                                                                     . 79)
                                                                                    (90
                                                                                     . 99))))) (:MANY
                                                                                                :OR
                                                                                                (:AND
                                                                                                 (:REL
                                                                                                  :N
                                                                                                  NIL
                                                                                                  :NEQ
                                                                                                  ((0
                                                                                                    . 0)))
                                                                                                 (:REL
                                                                                                  :N
                                                                                                  1000000
                                                                                                  :EQ
                                                                                                  ((0
                                                                                                    . 0))))))
    ("brx" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("bs" (:ONE :OR
           (:AND (:REL :V NIL :EQ ((0 . 0))) (:REL :I 10 :EQ ((1 . 1)))
            (:REL :I 100 :NEQ ((11 . 11))))
           (:AND (:REL :F 10 :EQ ((1 . 1))) (:REL :F 100 :NEQ ((11 . 11))))) (:FEW
                                                                              :OR
                                                                              (:AND
                                                                               (:REL
                                                                                :V
                                                                                NIL
                                                                                :EQ
                                                                                ((0
                                                                                  . 0)))
                                                                               (:REL
                                                                                :I
                                                                                10
                                                                                :EQ
                                                                                ((2
                                                                                  . 4)))
                                                                               (:REL
                                                                                :I
                                                                                100
                                                                                :NEQ
                                                                                ((12
                                                                                  . 14))))
                                                                              (:AND
                                                                               (:REL
                                                                                :F
                                                                                10
                                                                                :EQ
                                                                                ((2
                                                                                  . 4)))
                                                                               (:REL
                                                                                :F
                                                                                100
                                                                                :NEQ
                                                                                ((12
                                                                                  . 14))))))
    ("ca" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))) (:MANY
                                                                            :OR
                                                                            (:AND
                                                                             (:REL
                                                                              :E
                                                                              NIL
                                                                              :EQ
                                                                              ((0
                                                                                . 0)))
                                                                             (:REL
                                                                              :I
                                                                              NIL
                                                                              :NEQ
                                                                              ((0
                                                                                . 0)))
                                                                             (:REL
                                                                              :I
                                                                              1000000
                                                                              :EQ
                                                                              ((0
                                                                                . 0)))
                                                                             (:REL
                                                                              :V
                                                                              NIL
                                                                              :EQ
                                                                              ((0
                                                                                . 0))))
                                                                            (:AND
                                                                             (:REL
                                                                              :E
                                                                              NIL
                                                                              :NEQ
                                                                              ((0
                                                                                . 5))))))
    ("ce" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ceb" (:ONE :OR
            (:AND (:REL :V NIL :EQ ((0 . 0)))
             (:REL :I NIL :EQ ((1 . 1) (2 . 2) (3 . 3))))
            (:AND (:REL :V NIL :EQ ((0 . 0)))
             (:REL :I 10 :NEQ ((4 . 4) (6 . 6) (9 . 9))))
            (:AND (:REL :V NIL :NEQ ((0 . 0)))
             (:REL :F 10 :NEQ ((4 . 4) (6 . 6) (9 . 9))))))
    ("cgg" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("chr" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ckb" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("cs" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))) (:FEW
                                                                            :OR
                                                                            (:AND
                                                                             (:REL
                                                                              :I
                                                                              NIL
                                                                              :EQ
                                                                              ((2
                                                                                . 4)))
                                                                             (:REL
                                                                              :V
                                                                              NIL
                                                                              :EQ
                                                                              ((0
                                                                                . 0))))) (:MANY
                                                                                          :OR
                                                                                          (:AND
                                                                                           (:REL
                                                                                            :V
                                                                                            NIL
                                                                                            :NEQ
                                                                                            ((0
                                                                                              . 0))))))
    ("csw" (:ONE :OR (:AND (:REL :N NIL :EQ ((0 . 1))))))
    ("cv" (:ZERO :OR (:AND (:REL :N NIL :EQ ((0 . 0))))) (:ONE :OR
                                                          (:AND
                                                           (:REL :N NIL :EQ
                                                            ((1 . 1))))))
    ("cy" (:ZERO :OR (:AND (:REL :N NIL :EQ ((0 . 0))))) (:ONE :OR
                                                          (:AND
                                                           (:REL :N NIL :EQ
                                                            ((1 . 1))))) (:TWO
                                                                          :OR
                                                                          (:AND
                                                                           (:REL
                                                                            :N
                                                                            NIL
                                                                            :EQ
                                                                            ((2
                                                                              . 2))))) (:FEW
                                                                                        :OR
                                                                                        (:AND
                                                                                         (:REL
                                                                                          :N
                                                                                          NIL
                                                                                          :EQ
                                                                                          ((3
                                                                                            . 3))))) (:MANY
                                                                                                      :OR
                                                                                                      (:AND
                                                                                                       (:REL
                                                                                                        :N
                                                                                                        NIL
                                                                                                        :EQ
                                                                                                        ((6
                                                                                                          . 6))))))
    ("da" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))
           (:AND (:REL :T NIL :NEQ ((0 . 0)))
            (:REL :I NIL :EQ ((0 . 0) (1 . 1))))))
    ("de" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("doi" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
            (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("dsb" (:ONE :OR
            (:AND (:REL :V NIL :EQ ((0 . 0))) (:REL :I 100 :EQ ((1 . 1))))
            (:AND (:REL :F 100 :EQ ((1 . 1))))) (:TWO :OR
                                                 (:AND
                                                  (:REL :V NIL :EQ ((0 . 0)))
                                                  (:REL :I 100 :EQ ((2 . 2))))
                                                 (:AND
                                                  (:REL :F 100 :EQ ((2 . 2))))) (:FEW
                                                                                 :OR
                                                                                 (:AND
                                                                                  (:REL
                                                                                   :V
                                                                                   NIL
                                                                                   :EQ
                                                                                   ((0
                                                                                     . 0)))
                                                                                  (:REL
                                                                                   :I
                                                                                   100
                                                                                   :EQ
                                                                                   ((3
                                                                                     . 4))))
                                                                                 (:AND
                                                                                  (:REL
                                                                                   :F
                                                                                   100
                                                                                   :EQ
                                                                                   ((3
                                                                                     . 4))))))
    ("dv" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("dz")
    ("ee" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("el" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("en" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("eo" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("es" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))) (:MANY :OR
                                                         (:AND
                                                          (:REL :E NIL :EQ
                                                           ((0 . 0)))
                                                          (:REL :I NIL :NEQ
                                                           ((0 . 0)))
                                                          (:REL :I 1000000 :EQ
                                                           ((0 . 0)))
                                                          (:REL :V NIL :EQ
                                                           ((0 . 0))))
                                                         (:AND
                                                          (:REL :E NIL :NEQ
                                                           ((0 . 5))))))
    ("et" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("eu" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("fa" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
           (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ff" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0) (1 . 1))))))
    ("fi" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("fil" (:ONE :OR
            (:AND (:REL :V NIL :EQ ((0 . 0)))
             (:REL :I NIL :EQ ((1 . 1) (2 . 2) (3 . 3))))
            (:AND (:REL :V NIL :EQ ((0 . 0)))
             (:REL :I 10 :NEQ ((4 . 4) (6 . 6) (9 . 9))))
            (:AND (:REL :V NIL :NEQ ((0 . 0)))
             (:REL :F 10 :NEQ ((4 . 4) (6 . 6) (9 . 9))))))
    ("fo" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("fr" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0) (1 . 1))))) (:MANY :OR
                                                                 (:AND
                                                                  (:REL :E NIL
                                                                   :EQ
                                                                   ((0 . 0)))
                                                                  (:REL :I NIL
                                                                   :NEQ
                                                                   ((0 . 0)))
                                                                  (:REL :I
                                                                   1000000 :EQ
                                                                   ((0 . 0)))
                                                                  (:REL :V NIL
                                                                   :EQ
                                                                   ((0 . 0))))
                                                                 (:AND
                                                                  (:REL :E NIL
                                                                   :NEQ
                                                                   ((0 . 5))))))
    ("fur" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("fy" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("ga" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))) (:TWO :OR
                                                         (:AND
                                                          (:REL :N NIL :EQ
                                                           ((2 . 2))))) (:FEW
                                                                         :OR
                                                                         (:AND
                                                                          (:REL
                                                                           :N
                                                                           NIL
                                                                           :EQ
                                                                           ((3
                                                                             . 6))))) (:MANY
                                                                                       :OR
                                                                                       (:AND
                                                                                        (:REL
                                                                                         :N
                                                                                         NIL
                                                                                         :EQ
                                                                                         ((7
                                                                                           . 10))))))
    ("gd" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1) (11 . 11))))) (:TWO :OR
                                                                   (:AND
                                                                    (:REL :N
                                                                     NIL :EQ
                                                                     ((2 . 2)
                                                                      (12
                                                                       . 12))))) (:FEW
                                                                                  :OR
                                                                                  (:AND
                                                                                   (:REL
                                                                                    :N
                                                                                    NIL
                                                                                    :EQ
                                                                                    ((3
                                                                                      . 10)
                                                                                     (13
                                                                                      . 19))))))
    ("gl" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("gsw" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("gu" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
           (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("guw" (:ONE :OR (:AND (:REL :N NIL :EQ ((0 . 1))))))
    ("gv" (:ONE :OR
           (:AND (:REL :V NIL :EQ ((0 . 0))) (:REL :I 10 :EQ ((1 . 1))))) (:TWO
                                                                           :OR
                                                                           (:AND
                                                                            (:REL
                                                                             :V
                                                                             NIL
                                                                             :EQ
                                                                             ((0
                                                                               . 0)))
                                                                            (:REL
                                                                             :I
                                                                             10
                                                                             :EQ
                                                                             ((2
                                                                               . 2))))) (:FEW
                                                                                         :OR
                                                                                         (:AND
                                                                                          (:REL
                                                                                           :V
                                                                                           NIL
                                                                                           :EQ
                                                                                           ((0
                                                                                             . 0)))
                                                                                          (:REL
                                                                                           :I
                                                                                           100
                                                                                           :EQ
                                                                                           ((0
                                                                                             . 0)
                                                                                            (20
                                                                                             . 20)
                                                                                            (40
                                                                                             . 40)
                                                                                            (60
                                                                                             . 60)
                                                                                            (80
                                                                                             . 80))))) (:MANY
                                                                                                        :OR
                                                                                                        (:AND
                                                                                                         (:REL
                                                                                                          :V
                                                                                                          NIL
                                                                                                          :NEQ
                                                                                                          ((0
                                                                                                            . 0))))))
    ("ha" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("haw" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("he" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))
           (:AND (:REL :I NIL :EQ ((0 . 0))) (:REL :V NIL :NEQ ((0 . 0))))) (:TWO
                                                                             :OR
                                                                             (:AND
                                                                              (:REL
                                                                               :I
                                                                               NIL
                                                                               :EQ
                                                                               ((2
                                                                                 . 2)))
                                                                              (:REL
                                                                               :V
                                                                               NIL
                                                                               :EQ
                                                                               ((0
                                                                                 . 0))))))
    ("hi" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
           (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("hnj")
    ("hr" (:ONE :OR
           (:AND (:REL :V NIL :EQ ((0 . 0))) (:REL :I 10 :EQ ((1 . 1)))
            (:REL :I 100 :NEQ ((11 . 11))))
           (:AND (:REL :F 10 :EQ ((1 . 1))) (:REL :F 100 :NEQ ((11 . 11))))) (:FEW
                                                                              :OR
                                                                              (:AND
                                                                               (:REL
                                                                                :V
                                                                                NIL
                                                                                :EQ
                                                                                ((0
                                                                                  . 0)))
                                                                               (:REL
                                                                                :I
                                                                                10
                                                                                :EQ
                                                                                ((2
                                                                                  . 4)))
                                                                               (:REL
                                                                                :I
                                                                                100
                                                                                :NEQ
                                                                                ((12
                                                                                  . 14))))
                                                                              (:AND
                                                                               (:REL
                                                                                :F
                                                                                10
                                                                                :EQ
                                                                                ((2
                                                                                  . 4)))
                                                                               (:REL
                                                                                :F
                                                                                100
                                                                                :NEQ
                                                                                ((12
                                                                                  . 14))))))
    ("hsb" (:ONE :OR
            (:AND (:REL :V NIL :EQ ((0 . 0))) (:REL :I 100 :EQ ((1 . 1))))
            (:AND (:REL :F 100 :EQ ((1 . 1))))) (:TWO :OR
                                                 (:AND
                                                  (:REL :V NIL :EQ ((0 . 0)))
                                                  (:REL :I 100 :EQ ((2 . 2))))
                                                 (:AND
                                                  (:REL :F 100 :EQ ((2 . 2))))) (:FEW
                                                                                 :OR
                                                                                 (:AND
                                                                                  (:REL
                                                                                   :V
                                                                                   NIL
                                                                                   :EQ
                                                                                   ((0
                                                                                     . 0)))
                                                                                  (:REL
                                                                                   :I
                                                                                   100
                                                                                   :EQ
                                                                                   ((3
                                                                                     . 4))))
                                                                                 (:AND
                                                                                  (:REL
                                                                                   :F
                                                                                   100
                                                                                   :EQ
                                                                                   ((3
                                                                                     . 4))))))
    ("hu" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("hy" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0) (1 . 1))))))
    ("ia" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("id")
    ("ie" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("ig")
    ("ii")
    ("io" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("is" (:ONE :OR
           (:AND (:REL :T NIL :EQ ((0 . 0))) (:REL :I 10 :EQ ((1 . 1)))
            (:REL :I 100 :NEQ ((11 . 11))))
           (:AND (:REL :T 10 :EQ ((1 . 1))) (:REL :T 100 :NEQ ((11 . 11))))))
    ("it" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))) (:MANY
                                                                            :OR
                                                                            (:AND
                                                                             (:REL
                                                                              :E
                                                                              NIL
                                                                              :EQ
                                                                              ((0
                                                                                . 0)))
                                                                             (:REL
                                                                              :I
                                                                              NIL
                                                                              :NEQ
                                                                              ((0
                                                                                . 0)))
                                                                             (:REL
                                                                              :I
                                                                              1000000
                                                                              :EQ
                                                                              ((0
                                                                                . 0)))
                                                                             (:REL
                                                                              :V
                                                                              NIL
                                                                              :EQ
                                                                              ((0
                                                                                . 0))))
                                                                            (:AND
                                                                             (:REL
                                                                              :E
                                                                              NIL
                                                                              :NEQ
                                                                              ((0
                                                                                . 5))))))
    ("iu" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))) (:TWO :OR
                                                         (:AND
                                                          (:REL :N NIL :EQ
                                                           ((2 . 2))))))
    ("ja")
    ("jbo")
    ("jgo" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("jmc" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("jv")
    ("jw")
    ("ka" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("kab" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0) (1 . 1))))))
    ("kaj" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("kcg" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("kde")
    ("kea")
    ("kk" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("kkj" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("kl" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("km")
    ("kn" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
           (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ko")
    ("kok" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
            (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("kok-Latn" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
                 (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ks" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ksb" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ksh" (:ZERO :OR (:AND (:REL :N NIL :EQ ((0 . 0))))) (:ONE :OR
                                                           (:AND
                                                            (:REL :N NIL :EQ
                                                             ((1 . 1))))))
    ("ku" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("kw" (:ZERO :OR (:AND (:REL :N NIL :EQ ((0 . 0))))) (:ONE :OR
                                                          (:AND
                                                           (:REL :N NIL :EQ
                                                            ((1 . 1))))) (:TWO
                                                                          :OR
                                                                          (:AND
                                                                           (:REL
                                                                            :N
                                                                            100
                                                                            :EQ
                                                                            ((2
                                                                              . 2)
                                                                             (22
                                                                              . 22)
                                                                             (42
                                                                              . 42)
                                                                             (62
                                                                              . 62)
                                                                             (82
                                                                              . 82))))
                                                                          (:AND
                                                                           (:REL
                                                                            :N
                                                                            1000
                                                                            :EQ
                                                                            ((0
                                                                              . 0)))
                                                                           (:REL
                                                                            :N
                                                                            100000
                                                                            :EQ
                                                                            ((1000
                                                                              . 20000)
                                                                             (40000
                                                                              . 40000)
                                                                             (60000
                                                                              . 60000)
                                                                             (80000
                                                                              . 80000))))
                                                                          (:AND
                                                                           (:REL
                                                                            :N
                                                                            NIL
                                                                            :NEQ
                                                                            ((0
                                                                              . 0)))
                                                                           (:REL
                                                                            :N
                                                                            1000000
                                                                            :EQ
                                                                            ((100000
                                                                              . 100000))))) (:FEW
                                                                                             :OR
                                                                                             (:AND
                                                                                              (:REL
                                                                                               :N
                                                                                               100
                                                                                               :EQ
                                                                                               ((3
                                                                                                 . 3)
                                                                                                (23
                                                                                                 . 23)
                                                                                                (43
                                                                                                 . 43)
                                                                                                (63
                                                                                                 . 63)
                                                                                                (83
                                                                                                 . 83))))) (:MANY
                                                                                                            :OR
                                                                                                            (:AND
                                                                                                             (:REL
                                                                                                              :N
                                                                                                              NIL
                                                                                                              :NEQ
                                                                                                              ((1
                                                                                                                . 1)))
                                                                                                             (:REL
                                                                                                              :N
                                                                                                              100
                                                                                                              :EQ
                                                                                                              ((1
                                                                                                                . 1)
                                                                                                               (21
                                                                                                                . 21)
                                                                                                               (41
                                                                                                                . 41)
                                                                                                               (61
                                                                                                                . 61)
                                                                                                               (81
                                                                                                                . 81))))))
    ("ky" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("lag" (:ZERO :OR (:AND (:REL :N NIL :EQ ((0 . 0))))) (:ONE :OR
                                                           (:AND
                                                            (:REL :I NIL :EQ
                                                             ((0 . 0) (1 . 1)))
                                                            (:REL :N NIL :NEQ
                                                             ((0 . 0))))))
    ("lb" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("lg" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("lij" (:ONE :OR
            (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("lkt")
    ("lld" (:ONE :OR
            (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))) (:MANY
                                                                             :OR
                                                                             (:AND
                                                                              (:REL
                                                                               :E
                                                                               NIL
                                                                               :EQ
                                                                               ((0
                                                                                 . 0)))
                                                                              (:REL
                                                                               :I
                                                                               NIL
                                                                               :NEQ
                                                                               ((0
                                                                                 . 0)))
                                                                              (:REL
                                                                               :I
                                                                               1000000
                                                                               :EQ
                                                                               ((0
                                                                                 . 0)))
                                                                              (:REL
                                                                               :V
                                                                               NIL
                                                                               :EQ
                                                                               ((0
                                                                                 . 0))))
                                                                             (:AND
                                                                              (:REL
                                                                               :E
                                                                               NIL
                                                                               :NEQ
                                                                               ((0
                                                                                 . 5))))))
    ("ln" (:ONE :OR (:AND (:REL :N NIL :EQ ((0 . 1))))))
    ("lo")
    ("lt" (:ONE :OR
           (:AND (:REL :N 10 :EQ ((1 . 1))) (:REL :N 100 :NEQ ((11 . 19))))) (:FEW
                                                                              :OR
                                                                              (:AND
                                                                               (:REL
                                                                                :N
                                                                                10
                                                                                :EQ
                                                                                ((2
                                                                                  . 9)))
                                                                               (:REL
                                                                                :N
                                                                                100
                                                                                :NEQ
                                                                                ((11
                                                                                  . 19))))) (:MANY
                                                                                             :OR
                                                                                             (:AND
                                                                                              (:REL
                                                                                               :F
                                                                                               NIL
                                                                                               :NEQ
                                                                                               ((0
                                                                                                 . 0))))))
    ("lv" (:ZERO :OR (:AND (:REL :N 10 :EQ ((0 . 0))))
           (:AND (:REL :N 100 :EQ ((11 . 19))))
           (:AND (:REL :V NIL :EQ ((2 . 2))) (:REL :F 100 :EQ ((11 . 19))))) (:ONE
                                                                              :OR
                                                                              (:AND
                                                                               (:REL
                                                                                :N
                                                                                10
                                                                                :EQ
                                                                                ((1
                                                                                  . 1)))
                                                                               (:REL
                                                                                :N
                                                                                100
                                                                                :NEQ
                                                                                ((11
                                                                                  . 11))))
                                                                              (:AND
                                                                               (:REL
                                                                                :V
                                                                                NIL
                                                                                :EQ
                                                                                ((2
                                                                                  . 2)))
                                                                               (:REL
                                                                                :F
                                                                                10
                                                                                :EQ
                                                                                ((1
                                                                                  . 1)))
                                                                               (:REL
                                                                                :F
                                                                                100
                                                                                :NEQ
                                                                                ((11
                                                                                  . 11))))
                                                                              (:AND
                                                                               (:REL
                                                                                :V
                                                                                NIL
                                                                                :NEQ
                                                                                ((2
                                                                                  . 2)))
                                                                               (:REL
                                                                                :F
                                                                                10
                                                                                :EQ
                                                                                ((1
                                                                                  . 1))))))
    ("mas" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("mg" (:ONE :OR (:AND (:REL :N NIL :EQ ((0 . 1))))))
    ("mgo" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("mk" (:ONE :OR
           (:AND (:REL :V NIL :EQ ((0 . 0))) (:REL :I 10 :EQ ((1 . 1)))
            (:REL :I 100 :NEQ ((11 . 11))))
           (:AND (:REL :F 10 :EQ ((1 . 1))) (:REL :F 100 :NEQ ((11 . 11))))))
    ("ml" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("mn" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("mo" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))) (:FEW
                                                                            :OR
                                                                            (:AND
                                                                             (:REL
                                                                              :V
                                                                              NIL
                                                                              :NEQ
                                                                              ((0
                                                                                . 0))))
                                                                            (:AND
                                                                             (:REL
                                                                              :N
                                                                              NIL
                                                                              :EQ
                                                                              ((0
                                                                                . 0))))
                                                                            (:AND
                                                                             (:REL
                                                                              :N
                                                                              NIL
                                                                              :NEQ
                                                                              ((1
                                                                                . 1)))
                                                                             (:REL
                                                                              :N
                                                                              100
                                                                              :EQ
                                                                              ((1
                                                                                . 19))))))
    ("mr" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ms")
    ("mt" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))) (:TWO :OR
                                                         (:AND
                                                          (:REL :N NIL :EQ
                                                           ((2 . 2))))) (:FEW
                                                                         :OR
                                                                         (:AND
                                                                          (:REL
                                                                           :N
                                                                           NIL
                                                                           :EQ
                                                                           ((0
                                                                             . 0))))
                                                                         (:AND
                                                                          (:REL
                                                                           :N
                                                                           100
                                                                           :EQ
                                                                           ((3
                                                                             . 10))))) (:MANY
                                                                                        :OR
                                                                                        (:AND
                                                                                         (:REL
                                                                                          :N
                                                                                          100
                                                                                          :EQ
                                                                                          ((11
                                                                                            . 19))))))
    ("my")
    ("nah" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("naq" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))) (:TWO :OR
                                                          (:AND
                                                           (:REL :N NIL :EQ
                                                            ((2 . 2))))))
    ("nb" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("nd" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ne" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("nl" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("nn" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("nnh" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("no" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("nqo")
    ("nr" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("nso" (:ONE :OR (:AND (:REL :N NIL :EQ ((0 . 1))))))
    ("ny" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("nyn" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("om" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("or" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("os" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("osa")
    ("pa" (:ONE :OR (:AND (:REL :N NIL :EQ ((0 . 1))))))
    ("pap" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("pcm" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
            (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("pl" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))) (:FEW
                                                                            :OR
                                                                            (:AND
                                                                             (:REL
                                                                              :V
                                                                              NIL
                                                                              :EQ
                                                                              ((0
                                                                                . 0)))
                                                                             (:REL
                                                                              :I
                                                                              10
                                                                              :EQ
                                                                              ((2
                                                                                . 4)))
                                                                             (:REL
                                                                              :I
                                                                              100
                                                                              :NEQ
                                                                              ((12
                                                                                . 14))))) (:MANY
                                                                                           :OR
                                                                                           (:AND
                                                                                            (:REL
                                                                                             :V
                                                                                             NIL
                                                                                             :EQ
                                                                                             ((0
                                                                                               . 0)))
                                                                                            (:REL
                                                                                             :I
                                                                                             NIL
                                                                                             :NEQ
                                                                                             ((1
                                                                                               . 1)))
                                                                                            (:REL
                                                                                             :I
                                                                                             10
                                                                                             :EQ
                                                                                             ((0
                                                                                               . 1))))
                                                                                           (:AND
                                                                                            (:REL
                                                                                             :V
                                                                                             NIL
                                                                                             :EQ
                                                                                             ((0
                                                                                               . 0)))
                                                                                            (:REL
                                                                                             :I
                                                                                             10
                                                                                             :EQ
                                                                                             ((5
                                                                                               . 9))))
                                                                                           (:AND
                                                                                            (:REL
                                                                                             :V
                                                                                             NIL
                                                                                             :EQ
                                                                                             ((0
                                                                                               . 0)))
                                                                                            (:REL
                                                                                             :I
                                                                                             100
                                                                                             :EQ
                                                                                             ((12
                                                                                               . 14))))))
    ("prg" (:ZERO :OR (:AND (:REL :N 10 :EQ ((0 . 0))))
            (:AND (:REL :N 100 :EQ ((11 . 19))))
            (:AND (:REL :V NIL :EQ ((2 . 2))) (:REL :F 100 :EQ ((11 . 19))))) (:ONE
                                                                               :OR
                                                                               (:AND
                                                                                (:REL
                                                                                 :N
                                                                                 10
                                                                                 :EQ
                                                                                 ((1
                                                                                   . 1)))
                                                                                (:REL
                                                                                 :N
                                                                                 100
                                                                                 :NEQ
                                                                                 ((11
                                                                                   . 11))))
                                                                               (:AND
                                                                                (:REL
                                                                                 :V
                                                                                 NIL
                                                                                 :EQ
                                                                                 ((2
                                                                                   . 2)))
                                                                                (:REL
                                                                                 :F
                                                                                 10
                                                                                 :EQ
                                                                                 ((1
                                                                                   . 1)))
                                                                                (:REL
                                                                                 :F
                                                                                 100
                                                                                 :NEQ
                                                                                 ((11
                                                                                   . 11))))
                                                                               (:AND
                                                                                (:REL
                                                                                 :V
                                                                                 NIL
                                                                                 :NEQ
                                                                                 ((2
                                                                                   . 2)))
                                                                                (:REL
                                                                                 :F
                                                                                 10
                                                                                 :EQ
                                                                                 ((1
                                                                                   . 1))))))
    ("ps" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("pt" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 1))))) (:MANY :OR
                                                         (:AND
                                                          (:REL :E NIL :EQ
                                                           ((0 . 0)))
                                                          (:REL :I NIL :NEQ
                                                           ((0 . 0)))
                                                          (:REL :I 1000000 :EQ
                                                           ((0 . 0)))
                                                          (:REL :V NIL :EQ
                                                           ((0 . 0))))
                                                         (:AND
                                                          (:REL :E NIL :NEQ
                                                           ((0 . 5))))))
    ("pt-PT" (:ONE :OR
              (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))) (:MANY
                                                                               :OR
                                                                               (:AND
                                                                                (:REL
                                                                                 :E
                                                                                 NIL
                                                                                 :EQ
                                                                                 ((0
                                                                                   . 0)))
                                                                                (:REL
                                                                                 :I
                                                                                 NIL
                                                                                 :NEQ
                                                                                 ((0
                                                                                   . 0)))
                                                                                (:REL
                                                                                 :I
                                                                                 1000000
                                                                                 :EQ
                                                                                 ((0
                                                                                   . 0)))
                                                                                (:REL
                                                                                 :V
                                                                                 NIL
                                                                                 :EQ
                                                                                 ((0
                                                                                   . 0))))
                                                                               (:AND
                                                                                (:REL
                                                                                 :E
                                                                                 NIL
                                                                                 :NEQ
                                                                                 ((0
                                                                                   . 5))))))
    ("rm" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ro" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))) (:FEW
                                                                            :OR
                                                                            (:AND
                                                                             (:REL
                                                                              :V
                                                                              NIL
                                                                              :NEQ
                                                                              ((0
                                                                                . 0))))
                                                                            (:AND
                                                                             (:REL
                                                                              :N
                                                                              NIL
                                                                              :EQ
                                                                              ((0
                                                                                . 0))))
                                                                            (:AND
                                                                             (:REL
                                                                              :N
                                                                              NIL
                                                                              :NEQ
                                                                              ((1
                                                                                . 1)))
                                                                             (:REL
                                                                              :N
                                                                              100
                                                                              :EQ
                                                                              ((1
                                                                                . 19))))))
    ("rof" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ru" (:ONE :OR
           (:AND (:REL :V NIL :EQ ((0 . 0))) (:REL :I 10 :EQ ((1 . 1)))
            (:REL :I 100 :NEQ ((11 . 11))))) (:FEW :OR
                                              (:AND (:REL :V NIL :EQ ((0 . 0)))
                                               (:REL :I 10 :EQ ((2 . 4)))
                                               (:REL :I 100 :NEQ ((12 . 14))))) (:MANY
                                                                                 :OR
                                                                                 (:AND
                                                                                  (:REL
                                                                                   :V
                                                                                   NIL
                                                                                   :EQ
                                                                                   ((0
                                                                                     . 0)))
                                                                                  (:REL
                                                                                   :I
                                                                                   10
                                                                                   :EQ
                                                                                   ((0
                                                                                     . 0))))
                                                                                 (:AND
                                                                                  (:REL
                                                                                   :V
                                                                                   NIL
                                                                                   :EQ
                                                                                   ((0
                                                                                     . 0)))
                                                                                  (:REL
                                                                                   :I
                                                                                   10
                                                                                   :EQ
                                                                                   ((5
                                                                                     . 9))))
                                                                                 (:AND
                                                                                  (:REL
                                                                                   :V
                                                                                   NIL
                                                                                   :EQ
                                                                                   ((0
                                                                                     . 0)))
                                                                                  (:REL
                                                                                   :I
                                                                                   100
                                                                                   :EQ
                                                                                   ((11
                                                                                     . 14))))))
    ("rwk" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("sah")
    ("saq" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("sat" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))) (:TWO :OR
                                                          (:AND
                                                           (:REL :N NIL :EQ
                                                            ((2 . 2))))))
    ("sc" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("scn" (:ONE :OR
            (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))) (:MANY
                                                                             :OR
                                                                             (:AND
                                                                              (:REL
                                                                               :E
                                                                               NIL
                                                                               :EQ
                                                                               ((0
                                                                                 . 0)))
                                                                              (:REL
                                                                               :I
                                                                               NIL
                                                                               :NEQ
                                                                               ((0
                                                                                 . 0)))
                                                                              (:REL
                                                                               :I
                                                                               1000000
                                                                               :EQ
                                                                               ((0
                                                                                 . 0)))
                                                                              (:REL
                                                                               :V
                                                                               NIL
                                                                               :EQ
                                                                               ((0
                                                                                 . 0))))
                                                                             (:AND
                                                                              (:REL
                                                                               :E
                                                                               NIL
                                                                               :NEQ
                                                                               ((0
                                                                                 . 5))))))
    ("sd" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("sdh" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("se" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))) (:TWO :OR
                                                         (:AND
                                                          (:REL :N NIL :EQ
                                                           ((2 . 2))))))
    ("seh" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ses")
    ("sg")
    ("sgs" (:ONE :OR
            (:AND (:REL :N 10 :EQ ((1 . 1))) (:REL :N 100 :NEQ ((11 . 11))))) (:TWO
                                                                               :OR
                                                                               (:AND
                                                                                (:REL
                                                                                 :N
                                                                                 NIL
                                                                                 :EQ
                                                                                 ((2
                                                                                   . 2))))) (:FEW
                                                                                             :OR
                                                                                             (:AND
                                                                                              (:REL
                                                                                               :N
                                                                                               NIL
                                                                                               :NEQ
                                                                                               ((2
                                                                                                 . 2)))
                                                                                              (:REL
                                                                                               :N
                                                                                               10
                                                                                               :EQ
                                                                                               ((2
                                                                                                 . 9)))
                                                                                              (:REL
                                                                                               :N
                                                                                               100
                                                                                               :NEQ
                                                                                               ((11
                                                                                                 . 19))))) (:MANY
                                                                                                            :OR
                                                                                                            (:AND
                                                                                                             (:REL
                                                                                                              :F
                                                                                                              NIL
                                                                                                              :NEQ
                                                                                                              ((0
                                                                                                                . 0))))))
    ("sh" (:ONE :OR
           (:AND (:REL :V NIL :EQ ((0 . 0))) (:REL :I 10 :EQ ((1 . 1)))
            (:REL :I 100 :NEQ ((11 . 11))))
           (:AND (:REL :F 10 :EQ ((1 . 1))) (:REL :F 100 :NEQ ((11 . 11))))) (:FEW
                                                                              :OR
                                                                              (:AND
                                                                               (:REL
                                                                                :V
                                                                                NIL
                                                                                :EQ
                                                                                ((0
                                                                                  . 0)))
                                                                               (:REL
                                                                                :I
                                                                                10
                                                                                :EQ
                                                                                ((2
                                                                                  . 4)))
                                                                               (:REL
                                                                                :I
                                                                                100
                                                                                :NEQ
                                                                                ((12
                                                                                  . 14))))
                                                                              (:AND
                                                                               (:REL
                                                                                :F
                                                                                10
                                                                                :EQ
                                                                                ((2
                                                                                  . 4)))
                                                                               (:REL
                                                                                :F
                                                                                100
                                                                                :NEQ
                                                                                ((12
                                                                                  . 14))))))
    ("shi" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
            (:AND (:REL :N NIL :EQ ((1 . 1))))) (:FEW :OR
                                                 (:AND
                                                  (:REL :N NIL :EQ ((2 . 10))))))
    ("si" (:ONE :OR (:AND (:REL :N NIL :EQ ((0 . 0) (1 . 1))))
           (:AND (:REL :I NIL :EQ ((0 . 0))) (:REL :F NIL :EQ ((1 . 1))))))
    ("sk" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))) (:FEW
                                                                            :OR
                                                                            (:AND
                                                                             (:REL
                                                                              :I
                                                                              NIL
                                                                              :EQ
                                                                              ((2
                                                                                . 4)))
                                                                             (:REL
                                                                              :V
                                                                              NIL
                                                                              :EQ
                                                                              ((0
                                                                                . 0))))) (:MANY
                                                                                          :OR
                                                                                          (:AND
                                                                                           (:REL
                                                                                            :V
                                                                                            NIL
                                                                                            :NEQ
                                                                                            ((0
                                                                                              . 0))))))
    ("sl" (:ONE :OR
           (:AND (:REL :V NIL :EQ ((0 . 0))) (:REL :I 100 :EQ ((1 . 1))))) (:TWO
                                                                            :OR
                                                                            (:AND
                                                                             (:REL
                                                                              :V
                                                                              NIL
                                                                              :EQ
                                                                              ((0
                                                                                . 0)))
                                                                             (:REL
                                                                              :I
                                                                              100
                                                                              :EQ
                                                                              ((2
                                                                                . 2))))) (:FEW
                                                                                          :OR
                                                                                          (:AND
                                                                                           (:REL
                                                                                            :V
                                                                                            NIL
                                                                                            :EQ
                                                                                            ((0
                                                                                              . 0)))
                                                                                           (:REL
                                                                                            :I
                                                                                            100
                                                                                            :EQ
                                                                                            ((3
                                                                                              . 4))))
                                                                                          (:AND
                                                                                           (:REL
                                                                                            :V
                                                                                            NIL
                                                                                            :NEQ
                                                                                            ((0
                                                                                              . 0))))))
    ("sma" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))) (:TWO :OR
                                                          (:AND
                                                           (:REL :N NIL :EQ
                                                            ((2 . 2))))))
    ("smi" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))) (:TWO :OR
                                                          (:AND
                                                           (:REL :N NIL :EQ
                                                            ((2 . 2))))))
    ("smj" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))) (:TWO :OR
                                                          (:AND
                                                           (:REL :N NIL :EQ
                                                            ((2 . 2))))))
    ("smn" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))) (:TWO :OR
                                                          (:AND
                                                           (:REL :N NIL :EQ
                                                            ((2 . 2))))))
    ("sms" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))) (:TWO :OR
                                                          (:AND
                                                           (:REL :N NIL :EQ
                                                            ((2 . 2))))))
    ("sn" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("so" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("sq" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("sr" (:ONE :OR
           (:AND (:REL :V NIL :EQ ((0 . 0))) (:REL :I 10 :EQ ((1 . 1)))
            (:REL :I 100 :NEQ ((11 . 11))))
           (:AND (:REL :F 10 :EQ ((1 . 1))) (:REL :F 100 :NEQ ((11 . 11))))) (:FEW
                                                                              :OR
                                                                              (:AND
                                                                               (:REL
                                                                                :V
                                                                                NIL
                                                                                :EQ
                                                                                ((0
                                                                                  . 0)))
                                                                               (:REL
                                                                                :I
                                                                                10
                                                                                :EQ
                                                                                ((2
                                                                                  . 4)))
                                                                               (:REL
                                                                                :I
                                                                                100
                                                                                :NEQ
                                                                                ((12
                                                                                  . 14))))
                                                                              (:AND
                                                                               (:REL
                                                                                :F
                                                                                10
                                                                                :EQ
                                                                                ((2
                                                                                  . 4)))
                                                                               (:REL
                                                                                :F
                                                                                100
                                                                                :NEQ
                                                                                ((12
                                                                                  . 14))))))
    ("ss" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ssy" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("st" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("su")
    ("sv" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("sw" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("syr" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ta" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("te" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("teo" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("th")
    ("ti" (:ONE :OR (:AND (:REL :N NIL :EQ ((0 . 1))))))
    ("tig" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("tk" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("tl" (:ONE :OR
           (:AND (:REL :V NIL :EQ ((0 . 0)))
            (:REL :I NIL :EQ ((1 . 1) (2 . 2) (3 . 3))))
           (:AND (:REL :V NIL :EQ ((0 . 0)))
            (:REL :I 10 :NEQ ((4 . 4) (6 . 6) (9 . 9))))
           (:AND (:REL :V NIL :NEQ ((0 . 0)))
            (:REL :F 10 :NEQ ((4 . 4) (6 . 6) (9 . 9))))))
    ("tn" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("to")
    ("tpi")
    ("tr" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ts" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("tzm" (:ONE :OR (:AND (:REL :N NIL :EQ ((0 . 1))))
            (:AND (:REL :N NIL :EQ ((11 . 99))))))
    ("ug" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("uk" (:ONE :OR
           (:AND (:REL :V NIL :EQ ((0 . 0))) (:REL :I 10 :EQ ((1 . 1)))
            (:REL :I 100 :NEQ ((11 . 11))))) (:FEW :OR
                                              (:AND (:REL :V NIL :EQ ((0 . 0)))
                                               (:REL :I 10 :EQ ((2 . 4)))
                                               (:REL :I 100 :NEQ ((12 . 14))))) (:MANY
                                                                                 :OR
                                                                                 (:AND
                                                                                  (:REL
                                                                                   :V
                                                                                   NIL
                                                                                   :EQ
                                                                                   ((0
                                                                                     . 0)))
                                                                                  (:REL
                                                                                   :I
                                                                                   10
                                                                                   :EQ
                                                                                   ((0
                                                                                     . 0))))
                                                                                 (:AND
                                                                                  (:REL
                                                                                   :V
                                                                                   NIL
                                                                                   :EQ
                                                                                   ((0
                                                                                     . 0)))
                                                                                  (:REL
                                                                                   :I
                                                                                   10
                                                                                   :EQ
                                                                                   ((5
                                                                                     . 9))))
                                                                                 (:AND
                                                                                  (:REL
                                                                                   :V
                                                                                   NIL
                                                                                   :EQ
                                                                                   ((0
                                                                                     . 0)))
                                                                                  (:REL
                                                                                   :I
                                                                                   100
                                                                                   :EQ
                                                                                   ((11
                                                                                     . 14))))))
    ("und")
    ("ur" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("uz" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("ve" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("vec" (:ONE :OR
            (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))) (:MANY
                                                                             :OR
                                                                             (:AND
                                                                              (:REL
                                                                               :E
                                                                               NIL
                                                                               :EQ
                                                                               ((0
                                                                                 . 0)))
                                                                              (:REL
                                                                               :I
                                                                               NIL
                                                                               :NEQ
                                                                               ((0
                                                                                 . 0)))
                                                                              (:REL
                                                                               :I
                                                                               1000000
                                                                               :EQ
                                                                               ((0
                                                                                 . 0)))
                                                                              (:REL
                                                                               :V
                                                                               NIL
                                                                               :EQ
                                                                               ((0
                                                                                 . 0))))
                                                                             (:AND
                                                                              (:REL
                                                                               :E
                                                                               NIL
                                                                               :NEQ
                                                                               ((0
                                                                                 . 5))))))
    ("vi")
    ("vo" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("vun" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("wa" (:ONE :OR (:AND (:REL :N NIL :EQ ((0 . 1))))))
    ("wae" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("wo")
    ("xh" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("xog" (:ONE :OR (:AND (:REL :N NIL :EQ ((1 . 1))))))
    ("yi" (:ONE :OR
           (:AND (:REL :I NIL :EQ ((1 . 1))) (:REL :V NIL :EQ ((0 . 0))))))
    ("yo")
    ("yue")
    ("zh")
    ("zu" (:ONE :OR (:AND (:REL :I NIL :EQ ((0 . 0))))
           (:AND (:REL :N NIL :EQ ((1 . 1))))))))

(defparameter +cldr-version+ "48.2.1")
