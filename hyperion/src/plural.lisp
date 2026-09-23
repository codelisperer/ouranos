;;;; plural.lisp --- CLDR plural categories: the operand model and the rule evaluator.
;;;;
;;;; A string with a count in it can only be authored one way per locale, and one way is
;;;; not enough for most of them (pre-publication issue 135). English needs two forms; Russian and Ukrainian
;;;; need three on one set of boundaries, Polish three on different ones, Arabic six.
;;;; CL's `~:P` pluralizes in English regardless of locale, so every non-English
;;;; dictionary either read wrong at most counts or had to reword around the construction.
;;;;
;;;; THE RULES ARE NOT WRITTEN HERE. They are generated from CLDR into
;;;; vendor/cldr-plurals.lisp -- all 224 locales, pinned by version and sha256 (PLURALS.pin,
;;;; the same doctrine as libuv.pin and ASSETS.pin). Hand-writing the families we happen to
;;;; ship would be wrong for the first locale nobody anticipated, and wrong SILENTLY: a
;;;; missing rule falls back to `other`, which reads as a bad translation rather than a
;;;; missing rule.
;;;;
;;;; WHAT IS WRITTEN HERE is the part that is actually work: the OPERAND MODEL. Every CLDR
;;;; rule is expressed over a fixed set of operands derived from the number and how it is
;;;; being displayed. Implement those once and every locale's rule is data.
;;;;
;;;;   n  the absolute value
;;;;   i  its integer digits
;;;;   v  how many fraction digits are VISIBLE, counting trailing zeros
;;;;   w  how many are visible, NOT counting trailing zeros
;;;;   f  those visible fraction digits as an integer, with trailing zeros
;;;;   t  the same, without trailing zeros
;;;;   c  the compact-decimal exponent (e is its older spelling)
;;;;
;;;; v is why this cannot be a function of the number alone. In English "1 day" is `one`
;;;; and "1.0 days" is `other` -- same value, different category, because one of them is
;;;; being shown with a decimal place. A caller that formats to a fixed number of places
;;;; says so with :DIGITS; the common case is an integer, where every fraction operand is 0.

(in-package #:hyperion/plural)

(defparameter +categories+ '(:zero :one :two :few :many :other)
  "The six CLDR plural categories, in CLDR's own precedence order. A language uses a subset;
`other` is the only one every language has, which is what makes it the safe fallback.")

;;; --- the operand model ----------------------------------------------------

(defstruct (operands (:constructor %make-operands) (:copier nil))
  "The CLDR operands for one number as it is being displayed."
  (n 0) (i 0) (v 0) (w 0) (f 0) (tt 0) (c 0))

(defun %strip-trailing-zeros (value digits)
  "VALUE is DIGITS fraction digits as an integer; return (values value' digits') with
trailing zeros removed. 250 with 3 digits -> 25 with 2."
  (loop while (and (plusp digits) (zerop (mod value 10)))
        do (setf value (floor value 10)) (decf digits))
  (values value digits))

(defun operands-for (number &key (digits 0) (exponent 0))
  "The CLDR operands for NUMBER shown with DIGITS visible fraction digits.

DIGITS is how the number is being DISPLAYED, not how precise it is: 1 shown as \"1.0\" has
v=1 and is a different plural category from 1 shown as \"1\" in several languages. Callers
formatting to a fixed number of places pass that number; the default 0 is the integer case."
  (let* ((n (abs number))
         (i (floor n))
         (frac (- n i))
         (f (round (* frac (expt 10 digits)))))
    ;; Rounding can carry: 0.999 shown to 2 places is "1.00", so i must follow.
    (when (>= f (expt 10 digits))
      (decf f (expt 10 digits))
      (incf i))
    (multiple-value-bind (tt w) (%strip-trailing-zeros f digits)
      (%make-operands :n n :i i :v digits :w w :f f :tt tt :c exponent))))

(defun %operand-value (name ops)
  (ecase name
    (:n (operands-n ops))
    (:i (operands-i ops))
    (:v (operands-v ops))
    (:w (operands-w ops))
    (:f (operands-f ops))
    (:t (operands-tt ops))
    ((:c :e) (operands-c ops))))

;;; --- evaluating a rule ----------------------------------------------------

(defun %in-ranges-p (value ranges)
  "True when VALUE falls in one of RANGES (inclusive integer ranges).

A NON-INTEGER IS NEVER IN A RANGE, per UTS #35: `n = 1..3` is false for 1.5. Getting this
wrong makes 1.5 read as `one` in English, which is the exact class of bug the operand model
exists to prevent."
  (and (integerp value)
       (loop for (lo . hi) in ranges thereis (and (>= value lo) (<= value hi)))))

(defun %eval-condition (condition ops)
  "Walk a generated rule AST. NIL means `always`."
  (if (null condition)
      t
      (ecase (first condition)
        (:or (loop for clause in (rest condition) thereis (%eval-condition clause ops)))
        (:and (loop for clause in (rest condition) always (%eval-condition clause ops)))
        (:rel
         (destructuring-bind (operand modulus op ranges) (rest condition)
           (let* ((raw (%operand-value operand ops))
                  (value (if modulus (mod raw modulus) raw))
                  (hit (%in-ranges-p value ranges)))
             (ecase op (:eq hit) (:neq (not hit)))))))))

;;; --- locale lookup --------------------------------------------------------

(defun %locale-key (locale)
  (substitute #\- #\_ (string-downcase (if (symbolp locale) (symbol-name locale) locale))))

(defun %primary-subtag (key)
  (let ((sep (position-if (lambda (c) (or (char= c #\-) (char= c #\_))) key)))
    (if sep (subseq key 0 sep) key)))

(defun rules-for (locale)
  "The generated rules for LOCALE, or NIL if CLDR has none.

Tries the full tag, then its primary subtag: CLDR carries only two region-qualified
cardinal entries (pt-PT and kok-Latn), so pt-BR is not a lookup failure -- it is Portuguese,
and falls back to `pt` by design rather than by accident."
  (let ((key (%locale-key locale)))
    (or (cdr (assoc key +cldr-plural-rules+ :test #'string-equal))
        (cdr (assoc (%primary-subtag key) +cldr-plural-rules+ :test #'string-equal)))))

(defun supported-locales ()
  "Every locale code CLDR carries cardinal rules for, sorted -- what an app can pluralise.
Mostly language subtags; CLDR qualifies only a couple by region (pt-PT, kok-Latn), and
anything else region-qualified resolves through its primary subtag (see RULES-FOR)."
  (mapcar #'car +cldr-plural-rules+))

(defun supported-locale-p (locale)
  "True when CLDR has cardinal rules for LOCALE (directly or via its primary subtag)."
  (and (rules-for locale) t))

(defun plural-category (locale number &key (digits 0) (exponent 0))
  "The CLDR plural category of NUMBER in LOCALE: one of :ZERO :ONE :TWO :FEW :MANY :OTHER.

DIGITS is the number of fraction digits being DISPLAYED (see OPERANDS-FOR). An unknown
locale returns :OTHER, which every language has and which is therefore always a safe
answer -- a missing locale degrades to one form rather than to an error.

  (plural-category :en 1)   => :ONE
  (plural-category :en 1 :digits 1)  => :OTHER    ; \"1.0 days\"
  (plural-category :ru 21)  => :ONE               ; 21 день
  (plural-category :ru 5)   => :MANY              ; 5 дней"
  (let ((rules (rules-for locale)))
    (if (null rules)
        :other
        (let ((ops (operands-for number :digits digits :exponent exponent)))
          (or (loop for entry in rules
                    when (%eval-condition (cdr entry) ops) return (car entry))
              :other)))))

(defun categories-for (locale)
  "Every category LOCALE actually uses, in CLDR order -- what a translator must supply.
Always includes :OTHER. :EN => (:ONE :OTHER); :RU => (:ONE :FEW :MANY :OTHER)."
  (append (mapcar #'car (rules-for locale)) (list :other)))
