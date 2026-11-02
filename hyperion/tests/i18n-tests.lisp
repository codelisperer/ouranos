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

;;; --- whether a key has a translation (#490) -----------------------------------

(defun %dict-with-marker-text ()
  "%DICT plus home/marker, whose translation is literally the marker TRANSLATE would print
for it, and trial/days-left with plural forms."
  (i18n:make-dictionary
   (%ht "en" (%ht "home" (%ht "hi" "Hello" "greet" "Hi {name}!" "marker" "[home/marker]")
                  "trial" (%ht "days-left.one" "{count} day left"
                               "days-left.other" "{count} days left"
                               "plain" "no plural forms"))
        "ru" (%ht "home" (%ht "hi" "Привет")))
   :default :en))

(test translation-exists-p-agrees-with-translate
  "Present in the locale, present only in the default locale, and missing. CONTROL: a
translation whose text is exactly the marker counts as present, where comparing TRANSLATE's
result with the marker would call it missing."
  (let ((d (%dict-with-marker-text)))
    (is (eq t (i18n:translation-exists-p d :en :home/hi)))
    (is (eq t (i18n:translation-exists-p d :ru :home/hi)))
    (is (eq t (i18n:translation-exists-p d :ru :home/greet)) "only in the default locale")
    (is (null (i18n:translation-exists-p d :en :home/nope)))
    (is (null (i18n:translation-exists-p d :ru :home/nope)))
    (is (string= "[home/marker]" (i18n:translate d :en :home/marker)))
    (is (eq t (i18n:translation-exists-p d :en :home/marker)))
    (is (null (i18n:translation-exists-p d :en :home))
        "a section is not a translation")))

(test translation-exists-p-with-a-count-follows-translate-plural
  "With :COUNT, by TRANSLATE-PLURAL's fallbacks: the category, then other, then the bare key."
  (let ((d (%dict-with-marker-text)))
    (is (eq t (i18n:translation-exists-p d :en :trial/days-left :count 1)))
    (is (eq t (i18n:translation-exists-p d :en :trial/days-left :count 5)))
    (is (eq t (i18n:translation-exists-p d :ru :trial/days-left :count 3)) "from the default locale")
    (is (eq t (i18n:translation-exists-p d :en :trial/plain :count 2)) "the bare key")
    (is (null (i18n:translation-exists-p d :en :trial/nope :count 2)))))

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

;;; --- the current translation source (#491) ------------------------------------

(test translate-current-uses-the-bound-source
  "TRANSLATE-CURRENT and TRANSLATE-PLURAL-CURRENT with a source bound: the count picks the
plural form and is interpolated, and further arguments are passed on."
  (i18n:with-translation-source ((%dict))
    (is (string= "Привет" (i18n:translate-current :ru :home/hi)))
    (is (string= "Hi Bob!" (i18n:translate-current :en :home/greet :name "Bob"))))
  (i18n:with-translation-source ((i18n:make-dictionary
                                  (%ht "en" (%ht "trial" (%ht "days-left.one" "{count} day left for {name}"
                                                              "days-left.other" "{count} days left for {name}")))
                                  :default :en))
    (is (string= "1 day left for Ann" (i18n:translate-plural-current :en :trial/days-left 1 :name "Ann")))
    (is (string= "5 days left for Ann" (i18n:translate-plural-current :en :trial/days-left 5 :name "Ann")))))

(test translate-current-with-nothing-bound-signals
  "Unbound, it signals NO-TRANSLATION-SOURCE naming the key, rather than rendering markers.
CONTROL: bound, the same call returns the text."
  (let ((i18n:*translation-source* nil))
    (let ((c (handler-case (progn (i18n:translate-current :en :home/hi) nil)
               (i18n:no-translation-source (c) c))))
      (is (typep c 'i18n:no-translation-source))
      (is (eq :home/hi (and c (i18n:no-translation-source-key c)))))
    (signals i18n:no-translation-source (i18n:translate-plural-current :en :home/hi 2)))
  (i18n:with-translation-source ((%dict))
    (is (string= "Hello" (i18n:translate-current :en :home/hi)))))

(test the-current-source-crosses-into-a-thread-the-request-spawns
  "Through AION/DYNAMIC:INHERITING, as hyperion's request context does (#158). CONTROL: a thread
spawned without it does not see the binding, so the first check could tell the difference."
  (i18n:with-translation-source ((%dict))
    ;; An error in the thread is returned as text: left unhandled it would end the test run.
    (flet ((in-thread (fn)
             ;; AION/TEST-THREADS:JOIN gives up after its deadline and names the thread, so a
             ;; stuck thread fails this test instead of hanging the run.
             (aion/test-threads:join
              (sb-thread:make-thread (lambda () (handler-case (funcall fn)
                                                  (error (e) (princ-to-string e))))
                                     :name "i18n current-source test"))))
      (is (string= "Hello"
                   (in-thread (aion/dynamic:inheriting
                               (lambda () (i18n:translate-current :en :home/hi))))))
      (is (null (in-thread (lambda () i18n:*translation-source*)))))))

(test wrap-translation-source-binds-it-per-request
  "A source given directly; a source chosen per request by a function of the environment; and
a streaming body, which runs after the handler has returned. CONTROL: the same streaming body
called outside the middleware signals."
  (let* ((handler (lambda (env)
                    (declare (ignore env))
                    (list 200 '() (list (i18n:translate-current :ru :home/hi)))))
         (direct (i18n:wrap-translation-source handler (%dict))))
    (is (equal '("Привет") (third (funcall direct '(:path-info "/"))))))
  (let* ((other (i18n:make-dictionary (%ht "ru" (%ht "home" (%ht "hi" "Здравствуйте"))) :default :ru))
         (per-request (i18n:wrap-translation-source
                       (lambda (env)
                         (declare (ignore env))
                         (list 200 '() (list (i18n:translate-current :ru :home/hi))))
                       (lambda (env) (if (equal "/a" (getf env :path-info)) (%dict) other)))))
    (is (equal '("Привет") (third (funcall per-request '(:path-info "/a")))))
    (is (equal '("Здравствуйте") (third (funcall per-request '(:path-info "/b"))))))
  (let* ((streaming (lambda (env)
                      (declare (ignore env))
                      (list 200 '()
                            (lambda (writer) (funcall writer (i18n:translate-current :en :home/hi))))))
         (response (funcall (i18n:wrap-translation-source streaming (%dict)) '(:path-info "/")))
         (written '()))
    (funcall (third response) (lambda (s) (push s written)))
    (is (equal '("Hello") written))
    (let ((i18n:*translation-source* nil))
      (signals i18n:no-translation-source
        (funcall (third (funcall streaming '(:path-info "/"))) (lambda (s) (push s written)))))))

;;; --- load-dictionary refuses a directory with no locales (#294) ------------------------

(defmacro with-locale-directory ((dir &rest files) &body body)
  "Bind DIR to a new temporary directory holding FILES, each (NAME CONTENT), and delete it
afterwards."
  `(let ((,dir (aion/fs:make-temporary-directory "hyperion-i18n-test")))
     (unwind-protect
          (progn
            (loop for (name content) in (list ,@(mapcar (lambda (f) `(list ,@f)) files))
                  do (with-open-file (out (merge-pathnames name ,dir) :direction :output)
                       (write-string content out)))
            ,@body)
       (ignore-errors (aion/fs:delete-tree ,dir)))))

(test load-dictionary-reads-each-locale-file
  (with-locale-directory (dir ("en.json" "{\"home\": {\"hi\": \"Hello\"}}")
                              ("es.json" "{\"home\": {\"hi\": \"Hola\"}}"))
    (let ((d (i18n:load-dictionary dir :default :en)))
      (is (equal "Hola" (i18n:translate d :es :home/hi)))
      (is (equal '(:en :es) (sort (copy-list (i18n:supported-locales d)) #'string<))))))

(test load-dictionary-signals-for-an-empty-directory-and-names-it
  (with-locale-directory (dir ("notes.txt" "not a locale"))
    (let ((c (handler-case (progn (i18n:load-dictionary dir) nil)
               (i18n:empty-dictionary (c) c))))
      (is (typep c 'i18n:empty-dictionary) "an empty directory signals")
      (when c
        (is (equal (uiop:native-namestring dir)
                   (uiop:native-namestring (i18n:empty-dictionary-directory c)))
            "the condition names the directory that was searched")
        (is (search (uiop:native-namestring dir) (princ-to-string c))
            "and so does its message: ~A" c)))))

(test load-dictionary-signals-for-a-missing-directory
  (with-locale-directory (dir)
    (let* ((missing (merge-pathnames "no-such-dir/" dir))
           (c (handler-case (progn (i18n:load-dictionary missing) nil)
                (i18n:empty-dictionary (c) c))))
      (is (typep c 'i18n:empty-dictionary))
      (is (search "does not exist" (princ-to-string c)) "the message says so: ~A" c))))

(test load-dictionary-resolves-a-relative-directory-and-says-against-what
  "The consuming app's case: a relative path, resolved against a working directory other than
the one it was written for. The condition gives the absolute directory searched."
  (with-locale-directory (dir)
    (let* ((*default-pathname-defaults* dir)
           (c (handler-case (progn (i18n:load-dictionary #p"resources/i18n/") nil)
                (i18n:empty-dictionary (c) c))))
      (is (typep c 'i18n:empty-dictionary))
      (when c
        (is (equal (uiop:native-namestring (merge-pathnames "resources/i18n/" dir))
                   (uiop:native-namestring (i18n:empty-dictionary-directory c))))
        (is (search "It is relative" (princ-to-string c)) "~A" c)))))

(test load-dictionary-says-when-the-directory-lacks-its-trailing-slash
  (with-locale-directory (dir)
    (let* ((sub (merge-pathnames "i18n/" dir))
           (without-slash (string-right-trim "/\\" (uiop:native-namestring sub))))
      (ensure-directories-exist sub)
      (with-open-file (out (merge-pathnames "en.json" sub) :direction :output)
        (write-string "{}" out))
      (let ((c (handler-case (progn (i18n:load-dictionary without-slash) nil)
                 (i18n:empty-dictionary (c) c))))
        (is (typep c 'i18n:empty-dictionary) "the parent directory has no locale files")
        (is (search "end it with a slash" (princ-to-string c)) "~A" c)))))

(test load-dictionary-warns-when-the-default-locale-is-not-loaded
  (with-locale-directory (dir ("es.json" "{\"home\": {\"hi\": \"Hola\"}}"))
    (signals i18n:default-locale-not-loaded (i18n:load-dictionary dir :default :en))
    (let ((w (handler-case (progn (i18n:load-dictionary dir :default :en) nil)
               (i18n:default-locale-not-loaded (w) (princ-to-string w)))))
      (is (and w (search "no en.json, for the default locale" w) (search "which has es" w))
          "the warning names the missing file once and the locales found: ~A" w))
    (let ((d (handler-bind ((i18n:default-locale-not-loaded #'muffle-warning))
               (i18n:load-dictionary dir :default :en))))
      (is (equal "Hola" (i18n:translate d :es :home/hi)) "the dictionary is still returned")))
  (with-locale-directory (dir ("en.json" "{}"))
    (let ((warned nil))
      (handler-bind ((i18n:default-locale-not-loaded
                       (lambda (w) (setf warned t) (muffle-warning w))))
        (i18n:load-dictionary dir :default :en))
      (is (not warned) "no warning when the default is loaded"))))
