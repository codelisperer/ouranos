;;;; i18n-tests.lisp --- hyperion/i18n.

(in-package #:hyperion/tests)

(def-suite i18n :description "Locale dictionaries + resolution." :in hyperion)
(in-suite i18n)

(defun %ht (&rest kvs)
  "A string-keyed hash-table from alternating KEY VALUE pairs."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

(defun %dict ()
  "A small two-locale dictionary, built in memory (no file IO)."
  (i18n:make-dictionary
   (%ht "en" (%ht "home" (%ht "hi" "Hello" "greet" "Hi {name}!")
                  "menu" (%ht "about" "About"))
        "ru" (%ht "home" (%ht "hi" "Привет")
                  "menu" (%ht "about" "О нас")))
   :default :en))

;;; --- lookup ---------------------------------------------------------------
(test translate-basic
  (is (string= "Hello" (i18n:translate (%dict) :en :home/hi)))
  (is (string= "Привет" (i18n:translate (%dict) :ru :home/hi)))
  (is (string= "О нас" (i18n:translate (%dict) :ru :menu/about))))

(test flat-key-accepts-keyword-or-string
  (is (string= "Hello" (i18n:translate (%dict) :en :home/hi)))
  (is (string= "Hello" (i18n:translate (%dict) :en "home/hi"))))

(test locale-accepts-keyword-or-string
  (is (string= "Привет" (i18n:translate (%dict) :ru :home/hi)))
  (is (string= "Привет" (i18n:translate (%dict) "ru" :home/hi))))

(test fallback-to-default-locale
  ;; ru lacks home/greet -> falls back to the en value.
  (is (string= "Hi {name}!" (i18n:translate (%dict) :ru :home/greet))))

(test missing-key-shows-marker
  (is (string= "[home/nope]" (i18n:translate (%dict) :en :home/nope)))
  (is (string= "[a/b/c]"     (i18n:translate (%dict) :en :a/b/c))))

;;; --- interpolation --------------------------------------------------------
(test interpolation
  (is (string= "Hi Bob!" (i18n:translate (%dict) :en :home/greet :name "Bob")))
  (is (string= "Hi 3!"   (i18n:translate (%dict) :en :home/greet :name 3))))

(test interpolate-standalone
  (is (string= "a X b Y" (i18n:interpolate "a {x} b {y}" '(:x "X" :y "Y"))))
  (is (string= "no placeholders" (i18n:interpolate "no placeholders" '(:x "X")))))

;;; --- supported / resolution ----------------------------------------------
(test supported-locales
  (let ((d (%dict)))
    (is (member :en (i18n:supported-locales d)))
    (is (member :ru (i18n:supported-locales d)))
    (is (i18n:locale-supported-p d :en))
    (is (i18n:locale-supported-p d "ru"))
    (is (not (i18n:locale-supported-p d :fr)))))

;; The pure priority resolver is NEGOTIATE-LOCALE (param > user-pref > cookie >
;; accept-language, NIL if nothing matches); RESOLVE-LOCALE is now the request-level
;; wrapper (source/store/request). Test the pure logic here, supplying the default via OR.
(test negotiate-locale-priority
  (let ((supported '(:en :ru)) (default :en))
    (flet ((neg (&rest args) (or (apply #'i18n:negotiate-locale supported args) default)))
      ;; param wins
      (is (eq :ru (neg :param "ru" :cookie "en")))
      ;; user-pref beats cookie/accept
      (is (eq :ru (neg :user-pref "ru" :cookie "en" :accept-language "en")))
      ;; cookie beats accept-language
      (is (eq :en (neg :cookie "en" :accept-language "ru,en")))
      ;; accept-language, first supported
      (is (eq :ru (neg :accept-language "fr-FR,fr;q=0.9,ru;q=0.8")))
      ;; nothing supported -> default
      (is (eq :en (neg :param "es")))
      (is (eq :en (neg))))))

(test lang-cookie
  (let ((c (i18n:lang-cookie :ru)))
    (is (search "lang=ru" c))
    (is (search "Path=/" c))
    (is (search "SameSite=Lax" c))))

;;; --- text direction (RTL) --------------------------------------------------
;;; Direction is the other half of localization: resolving Arabic translations is useless
;;; if the document still renders left-to-right. These pin the mapping and the two places
;;; an app consumes it -- the page shell's attributes and the switcher's markup.

(test seeded-rtl-locales-need-no-registration
  (dolist (loc '(:ar :he :fa :ur :ps :sd :yi :dv :ckb :ug))
    (is (eq :rtl (i18n:locale-direction loc)) "~A should be RTL" loc)
    (is (i18n:rtl-p loc))))

(test legacy-iso-codes-for-rtl-languages
  ;; Some browsers still send the pre-1989 codes in Accept-Language.
  (is (eq :rtl (i18n:locale-direction :iw)))   ; Hebrew (now :he)
  (is (eq :rtl (i18n:locale-direction :ji))))  ; Yiddish (now :yi)

(test ltr-is-the-default-including-for-unknown-locales
  (is (eq :ltr (i18n:locale-direction :en)))
  (is (eq :ltr (i18n:locale-direction :ru)))
  ;; An unrecognised locale renders left-to-right rather than signalling -- a missing
  ;; entry must never take a page down.
  (is (eq :ltr (i18n:locale-direction :zz)))
  (is (not (i18n:rtl-p :zz))))

(test a-regional-tag-inherits-its-language-direction
  ;; An app should not have to register every region to get Arabic right.
  (is (eq :rtl (i18n:locale-direction :|ar-EG|)))
  (is (eq :rtl (i18n:locale-direction "ar-SA")))
  (is (eq :ltr (i18n:locale-direction :|en-GB|))))

(test direction-can-be-registered-and-overridden
  (unwind-protect
       (progn
         (i18n:register-locale-display :xx :endonym "Xhosa-ish" :direction :rtl)
         (is (eq :rtl (i18n:locale-direction :xx)))
         ;; re-registering another field must not silently reset direction
         (i18n:register-locale-display :xx :flag "🏴")
         (is (eq :rtl (i18n:locale-direction :xx)))
         (is (string= "🏴" (i18n:locale-flag :xx)))
         (is (string= "Xhosa-ish" (i18n:locale-endonym :xx))))
    (remhash :xx i18n::*locale-display*)))

(test dir-attribute-and-lang-attributes
  (is (string= "rtl" (i18n:dir-attribute :ar)))
  (is (string= "ltr" (i18n:dir-attribute :en)))
  ;; returned together so a page shell cannot emit lang without dir -- a document
  ;; claiming Arabic while still rendering ltr is the bug this prevents
  (multiple-value-bind (lang dir) (i18n:lang-attributes :ar)
    (is (string= "ar" lang))
    (is (string= "rtl" dir)))
  (multiple-value-bind (lang dir) (i18n:lang-attributes "en-GB")
    (is (string= "en-gb" lang))
    (is (string= "ltr" dir))))

(defun %attr-p (html name value)
  "True if HTML carries NAME=VALUE, quoted or not -- Spinneret omits quotes around values
that do not need them, and that is a rendering detail these tests must not depend on."
  (or (search (format nil "~A=~A" name value) html)
      (search (format nil "~A=\"~A\"" name value) html)))

(test the-switcher-marks-each-option-with-its-own-direction
  ;; A switcher lists every language in its own script, so an RTL endonym sits inside a
  ;; possibly-LTR page; the element must declare its own base direction or the bidi
  ;; algorithm lays it out wrong.
  (let ((html (i18n:language-switcher :current :en :locales '(:en :ar :he))))
    (is (%attr-p html "dir" "rtl"))
    (is (%attr-p html "dir" "ltr"))
    (is (%attr-p html "lang" "ar")))
  ;; and it renders with an RTL locale current
  (let ((html (i18n:language-switcher :current :ar :locales '(:en :ar))))
    (is (%attr-p html "dir" "rtl"))
    (is (search "العربية" html))))
