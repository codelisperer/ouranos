;;;; plural-tests.lisp --- CLDR plural categories and plural-aware translation (pre-publication issue 135).
;;;;
;;;; Two layers, tested differently on purpose:
;;;;
;;;;   The RULES are generated from CLDR, so testing them by re-transcribing expected
;;;;   answers would just be transcribing the same data twice and would prove nothing about
;;;;   the generator. What is worth pinning is the OPERAND MODEL -- the part that is written
;;;;   here and can be wrong -- plus a spread of languages whose boundaries differ in ways a
;;;;   naive implementation gets wrong (Russian's 11-vs-21, Polish's different boundaries,
;;;;   Arabic's six categories).
;;;;
;;;;   The LOOKUP is ours entirely: the key-suffix convention, the fallback chain, and the
;;;;   promise that TRANSLATE's behaviour is unchanged.
;;;;
;;;; The v operand gets its own tests because it is the one that surprises people: 1 and 1.0
;;;; are the same number and different plural categories in English.

(in-package #:hyperion/tests)

(def-suite plural :description "CLDR plural categories and plural-aware translation." :in hyperion)
(in-suite plural)

;;; --- the operand model, which is the part written by hand -----------------

(test operands-of-an-integer-have-no-fraction-parts
  (let ((o (plural:operands-for 42)))
    (is (= 42 (plural:operands-n o)))
    (is (= 42 (plural:operands-i o)))
    (is (= 0 (plural:operands-v o)))
    (is (= 0 (plural:operands-w o)))
    (is (= 0 (plural:operands-f o)))
    (is (= 0 (plural:operands-tt o)))))

(test v-counts-displayed-digits-and-w-drops-trailing-zeros
  ;; The distinction CLDR draws and most naive implementations miss: v is about how the
  ;; number is DISPLAYED, w about what is significant in it.
  (let ((o (plural:operands-for 1.50 :digits 2)))
    (is (= 1 (plural:operands-i o)))
    (is (= 2 (plural:operands-v o)) "two digits are shown")
    (is (= 1 (plural:operands-w o)) "only one is significant")
    (is (= 50 (plural:operands-f o)) "shown fraction digits, with the zero")
    (is (= 5 (plural:operands-tt o)) "and without it")))

(test operands-take-the-absolute-value
  ;; CLDR's n is |value|; a negative count must not fall into a different category.
  (is (= 3 (plural:operands-n (plural:operands-for -3))))
  (is (eq (plural:plural-category :en 1) (plural:plural-category :en -1)))
  (is (eq (plural:plural-category :ru 21) (plural:plural-category :ru -21))))

(test rounding-into-the-integer-part-carries
  ;; 0.999 shown to two places is "1.00", so i must become 1 -- otherwise the category is
  ;; computed for a number that is not what the user is reading.
  (let ((o (plural:operands-for 999/1000 :digits 2)))
    (is (= 1 (plural:operands-i o)))
    (is (= 0 (plural:operands-f o)))))

;;; --- the categories themselves --------------------------------------------

(test english-has-two-forms-and-a-decimal-is-not-one-of-them
  (is (eq :one (plural:plural-category :en 1)))
  (is (eq :other (plural:plural-category :en 0)))
  (is (eq :other (plural:plural-category :en 2)))
  (is (eq :other (plural:plural-category :en 17)))
  ;; "1.0 days", not "1.0 day" -- same value, different category, because v = 1
  (is (eq :other (plural:plural-category :en 1 :digits 1))))

(test russian-needs-three-forms-and-eleven-is-the-trap
  ;; 1 день / 2 дня / 5 дней, and 11 is MANY while 21 is ONE -- the case a naive
  ;; "last digit" implementation gets wrong.
  (is (eq :one  (plural:plural-category :ru 1)))
  (is (eq :one  (plural:plural-category :ru 21)))
  (is (eq :one  (plural:plural-category :ru 101)))
  (is (eq :few  (plural:plural-category :ru 2)))
  (is (eq :few  (plural:plural-category :ru 4)))
  (is (eq :few  (plural:plural-category :ru 22)))
  (is (eq :many (plural:plural-category :ru 5)))
  (is (eq :many (plural:plural-category :ru 11)) "11 is MANY even though it ends in 1")
  (is (eq :many (plural:plural-category :ru 12)) "12..14 are MANY though they end in 2..4")
  (is (eq :many (plural:plural-category :ru 14)))
  (is (eq :many (plural:plural-category :ru 25))))

(test polish-draws-its-boundaries-differently-from-russian
  ;; Same "three forms" description, different rules -- which is why the families cannot be
  ;; collapsed into one hand-written Slavic case.
  (is (eq :one  (plural:plural-category :pl 1)))
  (is (eq :few  (plural:plural-category :pl 2)))
  (is (eq :few  (plural:plural-category :pl 22)))
  (is (eq :many (plural:plural-category :pl 5)))
  (is (eq :many (plural:plural-category :pl 21)) "21 is MANY in Polish and ONE in Russian"))

(test arabic-uses-all-six-categories
  (is (eq :zero  (plural:plural-category :ar 0)))
  (is (eq :one   (plural:plural-category :ar 1)))
  (is (eq :two   (plural:plural-category :ar 2)))
  (is (eq :few   (plural:plural-category :ar 3)))
  (is (eq :many  (plural:plural-category :ar 11)))
  (is (eq :other (plural:plural-category :ar 100))))

(test a-language-with-one-form-always-says-other
  ;; Japanese, Chinese, Korean, Vietnamese: no plural agreement at all.
  (dolist (locale '(:ja :zh :ko :vi))
    (dolist (n '(0 1 2 5 100))
      (is (eq :other (plural:plural-category locale n))
          "~A ~D should be OTHER" locale n))))

;;; --- locale resolution -----------------------------------------------------

(test a-region-subtag-falls-back-to-its-language
  ;; CLDR carries only two region-qualified cardinal entries, so pt-BR is not a lookup
  ;; failure -- it is Portuguese.
  (is (eq :one (plural:plural-category :|pt-BR| 1)))
  (is (eq (plural:plural-category :pt 2) (plural:plural-category :|pt-BR| 2)))
  (is (eq (plural:plural-category :ru 5) (plural:plural-category :|ru-UA| 5)))
  ;; underscore and case are both tolerated -- locale codes arrive in every spelling
  (is (eq :one (plural:plural-category "pt_br" 1)))
  (is (eq :one (plural:plural-category "EN" 1))))

(test pt-PT-has-its-own-entry-and-is-used
  ;; The exact-match branch: pt-PT is one of the two region-qualified entries CLDR has.
  (is (plural:supported-locale-p :|pt-PT|))
  (is (eq :one (plural:plural-category :|pt-PT| 1))))

(test an-unknown-locale-degrades-to-other-rather-than-signalling
  ;; :OTHER is the one category every language has, so it is always a safe answer. A
  ;; missing locale must not take a page down.
  (is (eq :other (plural:plural-category :zz 1)))
  (is (eq :other (plural:plural-category :zz 5)))
  (is (not (plural:supported-locale-p :zz))))

(test categories-for-reports-what-a-translator-must-supply
  (is (equal '(:one :other) (plural:categories-for :en)))
  (is (equal '(:one :few :many :other) (plural:categories-for :ru)))
  (is (equal '(:other) (plural:categories-for :ja)))
  (is (member :two (plural:categories-for :ar)))
  ;; every language, including an unknown one, has OTHER
  (is (member :other (plural:categories-for :zz))))

;;; --- the vendored data is real ---------------------------------------------

(test the-full-cldr-set-is-vendored-not-a-sample
  ;; The point of generating rather than hand-writing: coverage of locales nobody picked.
  (is (> (length (plural:supported-locales)) 200)
      "the whole CLDR cardinal set should be present, not the families we ship")
  (is (stringp plural:+cldr-version+))
  ;; a spread of languages no one on this project speaks, each with real rules
  (dolist (locale '(:cy :mt :ga :br :lt :lv :ro :he :hi :sl))
    (is (plural:supported-locale-p locale) "~A should be covered" locale)))

(test welsh-has-the-most-categories-of-any-european-language
  ;; A locale nobody would have hand-written, exercised end to end.
  (is (eq :zero (plural:plural-category :cy 0)))
  (is (eq :one  (plural:plural-category :cy 1)))
  (is (eq :two  (plural:plural-category :cy 2)))
  (is (eq :few  (plural:plural-category :cy 3)))
  (is (eq :many (plural:plural-category :cy 6)))
  (is (eq :other (plural:plural-category :cy 4))))

;;; --- plural-aware translation ---------------------------------------------

(defun %plural-dict ()
  (let ((data (make-hash-table :test 'equal)))
    (flet ((locale (code &rest pairs)
             (let ((top (make-hash-table :test 'equal))
                   (section (make-hash-table :test 'equal)))
               (loop for (k v) on pairs by #'cddr do (setf (gethash k section) v))
               (setf (gethash "trial" top) section
                     (gethash code data) top))))
      (locale "en"
              "days-left.one" "{count} day left"
              "days-left.other" "{count} days left"
              "plain" "no plural here")
      (locale "ru"
              "days-left.one" "остался {count} день"
              "days-left.few" "осталось {count} дня"
              "days-left.many" "осталось {count} дней"
              "days-left.other" "осталось {count} дня")
      (locale "de"
              "days-left.other" "{count} Tage"       ; only `other` supplied
              "unpluralised" "Ein Text"))
    (i18n:make-dictionary data :default :en)))

(test translate-plural-picks-the-form-for-the-count
  (let ((d (%plural-dict)))
    (is (string= "1 day left" (i18n:translate-plural d :en :trial/days-left 1)))
    (is (string= "3 days left" (i18n:translate-plural d :en :trial/days-left 3)))
    (is (string= "0 days left" (i18n:translate-plural d :en :trial/days-left 0)))))

(test translate-plural-agrees-in-a-three-form-language
  ;; The case that motivated the issue: a bare day count in Russian.
  (let ((d (%plural-dict)))
    (is (string= "остался 1 день" (i18n:translate-plural d :ru :trial/days-left 1)))
    (is (string= "осталось 2 дня" (i18n:translate-plural d :ru :trial/days-left 2)))
    (is (string= "осталось 5 дней" (i18n:translate-plural d :ru :trial/days-left 5)))
    (is (string= "осталось 11 дней" (i18n:translate-plural d :ru :trial/days-left 11)))
    (is (string= "остался 21 день" (i18n:translate-plural d :ru :trial/days-left 21)))))

(test count-is-interpolated-without-being-passed
  ;; {count} is the one argument every plural string needs, so the caller should not have
  ;; to repeat it as a keyword argument.
  (let ((d (%plural-dict)))
    (is (search "7" (i18n:translate-plural d :en :trial/days-left 7)))))

(test a-missing-category-falls-back-to-other-then-to-the-bare-key
  ;; So a dictionary can be pluralised one string at a time rather than all at once.
  (let ((d (%plural-dict)))
    ;; German here has only `other`
    (is (string= "1 Tage" (i18n:translate-plural d :de :trial/days-left 1)))
    ;; and a key with no plural forms at all still resolves
    (is (string= "no plural here" (i18n:translate-plural d :en :trial/plain 5)))))

(test a-missing-key-is-visibly-missing
  (let ((d (%plural-dict)))
    (is (search "nope" (i18n:translate-plural d :en :trial/nope 1)))))

(test plural-key-builds-the-suffix-convention
  (is (string= "trial/days-left.one" (i18n:plural-key :trial/days-left :one)))
  (is (string= "trial/days-left.many" (i18n:plural-key "trial/days-left" :many))))

(test translate-is-unchanged
  ;; The reason this is a separate function: TRANSLATE is total, settled, and called
  ;; everywhere. Adding a count-sensitive mode to it would change existing calls.
  (let ((d (%plural-dict)))
    (is (string= "no plural here" (i18n:translate d :en :trial/plain)))
    (is (string= "Ein Text" (i18n:translate d :de :trial/unpluralised)))
    ;; and it still does NOT know about plural suffixes, which is the point
    (is (search "days-left" (i18n:translate d :en :trial/days-left)))))
