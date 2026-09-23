;;;; i18n.lisp --- locale dictionaries, resolution, persistence, and the switcher.
;;;;
;;;; App-neutral internationalization, split into pluggable pieces so an app supplies
;;;; only hooks:
;;;;   - a TRANSLATION SOURCE protocol (TRANSLATE / SUPPORTED-LOCALES / DEFAULT-LOCALE)
;;;;     with a built-in JSON dictionary backend (MAKE-JSON-SOURCE / LOAD-DICTIONARY);
;;;;     a DB-backed source is app-supplied later behind the same protocol.
;;;;   - a LOCALE STORE protocol (READ-LOCALE / PERSIST-LOCALE) with a COOKIE-STORE
;;;;     backend; a session/DB store is app-supplied later.
;;;;   - RESOLVE-LOCALE: the request seam (?lang= > store > Accept-Language > default),
;;;;     with `xx-YY` -> `xx` fallback and q-weight ordering.
;;;;   - LANGUAGE-SWITCHER: an HTMX-first Spinneret component + a generic, app-overridable
;;;;     locale display reference (endonym + flag).
;;;; The app owns: which languages, how translations are obtained, which store, and the
;;;; dictionaries themselves. See docs/i18n-design.md, ADR-0006, and
;;;; docs/i18n-pluggable-spec.md (the hyperion/consuming-app split).

(in-package #:hyperion/i18n)

(defvar *default-locale* :en
  "Fallback locale when resolution finds nothing supported.")

;;; --- small helpers --------------------------------------------------------
(defun %replace-all (string part replacement)
  (with-output-to-string (out)
    (loop with plen = (length part)
          for pos = 0 then (+ found plen)
          for found = (search part string :start2 pos)
          do (write-string string out :start pos :end (or found (length string)))
          while found do (write-string replacement out))))

(defun %name (x)
  "The string name of a keyword/symbol/string X."
  (if (symbolp x) (symbol-name x) x))

(defun %loc-string (locale)
  "LOCALE (keyword or string) -> its lowercase code string (e.g. :en -> \"en\")."
  (string-downcase (%name locale)))

(defun %to-locale (x)
  "X (a locale code string or keyword) -> a locale keyword, or NIL."
  (let ((s (and x (%name x))))
    (when (and s (plusp (length s)))
      (intern (string-upcase s) :keyword))))

(defun %key-path (key)
  "Flat KEY (:section/key or \"section/key\") -> a list of lowercase segments."
  (uiop:split-string (string-downcase (%name key)) :separator "/"))

;;; =========================================================================
;;; Translation source protocol
;;; =========================================================================
;;; A SOURCE answers three questions; the built-in JSON DICTIONARY is one backend, a
;;; DB-backed source (app-supplied) is another. Effects (file/DB IO) live in the
;;; backend's methods; the protocol is neutral.

(defgeneric translate (source locale key &rest args)
  (:documentation
   "The string for flat KEY (:section/key) in LOCALE (keyword or code string) from
SOURCE. Falls back to SOURCE's default locale, then to a visible \"[section/key]\"
marker so a missing key is obvious. Trailing ARGS are a plist for {named}
interpolation."))

(defgeneric translate-plural (source locale key count &rest args)
  (:documentation
   "The plural-agreeing string for KEY at COUNT in LOCALE.

Looks up KEY suffixed with the CLDR plural category COUNT falls into for LOCALE --
`trial/days-left.one`, `.few`, `.many`, `.other` -- falling back to `KEY.other` and then to
the unsuffixed KEY, so a dictionary that has not been pluralised yet keeps working.

{count} is interpolated automatically; further ARGS are a plist as for TRANSLATE.

SEPARATE FROM TRANSLATE ON PURPOSE. TRANSLATE is a total function with a settled meaning and
callers throughout every app; adding a count-sensitive mode to it would change what an
existing call does. Same reasoning as FORM-PARAM keeping its meaning while FORM-PARAMS
carried the new one (#136)."))

(defgeneric supported-locales (source)
  (:documentation "The list of locale keywords SOURCE provides."))

(defgeneric default-locale (source)
  (:documentation "SOURCE's fallback locale (a keyword)."))

(defun interpolate (string args)
  "Replace {name} placeholders in STRING with values from ARGS, a plist with keyword
keys: (interpolate \"Hi {name}!\" '(:name \"Bob\")) => \"Hi Bob!\"."
  (let ((result string))
    (loop for (k v) on args by #'cddr
          do (setf result (%replace-all result
                                        (format nil "{~A}" (string-downcase (%name k)))
                                        (princ-to-string v))))
    result))

;;; --- The built-in JSON dictionary source ---------------------------------
(defstruct (dictionary (:constructor %make-dictionary) (:predicate dictionary-p))
  (data (make-hash-table :test 'equal))  ; locale-code string -> nested hash-table
  (default :en)                          ; default locale keyword
  (supported nil))                       ; list of locale keywords present

(defun make-dictionary (data &key (default *default-locale*))
  "Build a DICTIONARY from DATA: a hash-table mapping locale-code strings to nested
(section -> key -> string) hash-tables (as produced by jzon:parse)."
  (%make-dictionary :data data :default default
                    :supported (loop for k being the hash-keys of data
                                     collect (intern (string-upcase k) :keyword))))

(defun load-dictionary (dir &key (default *default-locale*))
  "Load a dictionary from DIR, a directory of `<locale>.json` files -- each file is one
locale, the file name is the locale code. Adding a language is just adding a file; the
supported locales follow from what's present."
  (let ((data (make-hash-table :test 'equal)))
    (dolist (file (directory (merge-pathnames "*.json" dir)))
      (setf (gethash (string-downcase (pathname-name file)) data)
            (jzon:parse file)))
    (make-dictionary data :default default)))

(defun make-json-source (dir &key (default *default-locale*))
  "The built-in JSON translation source: per-locale `<code>.json` files under DIR. An
alias for LOAD-DICTIONARY -- the DICTIONARY *is* the JSON source (implements the
translation-source protocol). Swap it for an app-supplied DB source later; only this
call changes."
  (load-dictionary dir :default default))

(defun %walk (data locale-string path)
  "Walk PATH (string segments) into DATA under LOCALE-STRING; NIL if any step is absent
(or the node isn't a map)."
  (let ((node (gethash locale-string data)))
    (dolist (seg path node)
      (unless (hash-table-p node) (return nil))
      (setf node (gethash seg node)))))

(defmethod translate ((source dictionary) locale key &rest args)
  (let ((raw (or (%walk (dictionary-data source) (%loc-string locale) (%key-path key))
                 (%walk (dictionary-data source) (%loc-string (dictionary-default source))
                        (%key-path key)))))
    (cond ((not (stringp raw)) (format nil "[~A]" (string-downcase (%name key))))
          (args (interpolate raw args))
          (t raw))))

(defun plural-key (key category)
  "KEY suffixed with CATEGORY: (:trial/days-left :few) -> \"trial/days-left.few\".

The convention is a suffix rather than a nested object so dictionaries stay FLAT: a
translator sees `trial/days-left.few` beside `trial/days-left.one` in the same file, and the
locale's plural logic stays in CLDR where it belongs rather than being encoded in the shape
of the translation data."
  (format nil "~A.~A" (string-downcase (%name key)) (string-downcase (symbol-name category))))

(defmethod translate-plural ((source dictionary) locale key count &rest args)
  (let* ((category (plural:plural-category locale count))
         (all (list* :count count args)))
    ;; TWO fallback axes, and the nesting between them is the whole design.
    ;;
    ;; Within a locale: KEY.<category>, then KEY.other, then bare KEY. The last step is what
    ;; lets a dictionary be pluralised one string at a time instead of all at once.
    ;;
    ;; ACROSS locales: only once the requested locale has no form at all. Category is the
    ;; INNER loop because a slightly-off form in the right language beats a correct one in
    ;; the wrong language -- a German dictionary carrying only `other` should read "1 Tage",
    ;; not switch that one string to English. `other` is the language's default form, which
    ;; is exactly the right thing to reach for when the exact category is missing.
    (flet ((in-locale (loc)
             (let ((code (%loc-string loc)))
               (dolist (k (list (plural-key key category) (plural-key key :other) key))
                 (let ((raw (%walk (dictionary-data source) code (%key-path k))))
                   (when (stringp raw) (return raw)))))))
      (let ((raw (or (in-locale locale)
                     (in-locale (dictionary-default source)))))
        (if raw
            (interpolate raw all)
            (format nil "[~A.~A]" (string-downcase (%name key))
                    (string-downcase (symbol-name category))))))))

(defmethod supported-locales ((source dictionary)) (dictionary-supported source))
(defmethod default-locale ((source dictionary)) (dictionary-default source))

(defun locale-supported-p (source locale)
  "True when SOURCE provides LOCALE (a keyword or code string)."
  (and (member (%to-locale locale) (supported-locales source)) t))

;;; =========================================================================
;;; Locale store protocol (persistence)
;;; =========================================================================
;;; Where the chosen locale is remembered. COOKIE-STORE now; a session/DB store is
;;; app-supplied later behind the same two methods.

(defgeneric read-locale (store request)
  (:documentation
   "The locale tag STORE has persisted for REQUEST (the Clack env), or NIL."))

(defgeneric persist-locale (store locale)
  (:documentation
   "Persist LOCALE via STORE; return response headers (a plist, e.g.
(:set-cookie \"...\")) for the caller to merge into the Clack response."))

(defstruct (cookie-store (:constructor %make-cookie-store))
  (name "lang") (path "/") (max-age 31536000))

(defun make-cookie-store (&key (name "lang") (path "/") (max-age 31536000))
  "A locale store that persists the choice in a cookie (NAME, default \"lang\"; MAX-AGE
default 1 year)."
  (%make-cookie-store :name name :path path :max-age max-age))

(defmethod read-locale ((store cookie-store) request)
  (http:cookie request (cookie-store-name store)))

(defmethod persist-locale ((store cookie-store) locale)
  (list :set-cookie
        (format nil "~A=~A; Path=~A; Max-Age=~D; SameSite=Lax"
                (cookie-store-name store) (%loc-string locale)
                (cookie-store-path store) (cookie-store-max-age store))))

(defun lang-cookie (locale &key (path "/") (max-age 31536000))
  "A Set-Cookie header value persisting LOCALE in the `lang` cookie (default: 1 year).
Kept for callers not using a store; PERSIST-LOCALE is the protocol form."
  (format nil "lang=~A; Path=~A; Max-Age=~D; SameSite=Lax"
          (%loc-string locale) path max-age))

;;; =========================================================================
;;; Resolution (the request seam)
;;; =========================================================================
(defun %primary-subtag (x)
  "The primary language subtag of a locale code (\"en-GB\" -> \"en\")."
  (let ((s (%name x)))
    (and s (plusp (length s)) (first (uiop:split-string s :separator "-")))))

(defun %best-supported (supported raw)
  "A locale keyword in SUPPORTED for RAW (a BCP-47-ish code/keyword): try the FULL tag
first, then its primary language subtag; NIL if neither is supported. So a request for
`en-GB` matches an `en-gb` locale when present, else falls back to `en`."
  (when raw
    (let ((full (%to-locale raw))
          (prim (%to-locale (%primary-subtag raw))))
      (cond ((and full (member full supported)) full)
            ((and prim (member prim supported)) prim)))))

(defun %accept-language-tags (header)
  "The locale tags of an Accept-Language HEADER, in descending q-weight order, with the
region kept: \"fr;q=0.8,en-GB,en;q=0.9\" -> (\"en-GB\" \"en\" \"fr\")."
  (when header
    (let ((tags (loop for part in (uiop:split-string header :separator ",")
                      for pieces = (uiop:split-string (string-trim " " part) :separator ";")
                      for tag = (string-trim " " (first pieces))
                      for q = (loop for p in (rest pieces)
                                    for kv = (uiop:split-string p :separator "=")
                                    when (string-equal (string-trim " " (first kv)) "q")
                                      return (or (ignore-errors
                                                  (let ((*read-eval* nil))
                                                    (read-from-string (second kv) nil 1)))
                                                 1)
                                    finally (return 1))
                      when (plusp (length tag)) collect (cons tag q))))
      (mapcar #'car (stable-sort tags #'> :key #'cdr)))))

(defun negotiate-locale (supported &key param user-pref cookie accept-language)
  "Pure resolver over a SUPPORTED locale-keyword list: PARAM > USER-PREF > COOKIE >
ACCEPT-LANGUAGE, each tried as a full tag then its primary subtag. NIL if nothing
matches (the caller supplies the default). RESOLVE-LOCALE is the request-level wrapper."
  (flet ((ok (x) (%best-supported supported x)))
    (or (ok param) (ok user-pref) (ok cookie)
        (loop for tag in (%accept-language-tags accept-language) thereis (ok tag)))))

(defun resolve-locale (source store request &key param)
  "Resolve a supported locale (a keyword) for REQUEST (the Clack env): the ?lang= query
(or an explicit PARAM) > the STORE's persisted choice > Accept-Language > SOURCE's
default. SOURCE supplies the supported set; STORE reads the persisted choice. Each
candidate may be a full BCP-47-ish tag; resolution tries the full tag then its primary
subtag."
  (or (negotiate-locale (supported-locales source)
                        :param (or param (http:query-param request "lang"))
                        :cookie (read-locale store request)
                        :accept-language (http:request-header request "accept-language"))
      (default-locale source)))

;;; =========================================================================
;;; Locale display reference + the language switcher (HTMX-first)
;;; =========================================================================
;;; Direction is a property of the LANGUAGE, not of any one app's content -- the same
;;; mapping is right for every consuming app -- so it lives here beside the endonym and
;;; flag rather than being re-derived (and drifting) in each app.

(defparameter +rtl-languages+
  '(:ar   ; Arabic
    :he :iw   ; Hebrew (:iw is the legacy ISO code some browsers still send)
    :fa   ; Persian/Farsi
    :ur   ; Urdu
    :ps   ; Pashto
    :sd   ; Sindhi
    :yi :ji   ; Yiddish (:ji legacy)
    :dv   ; Dhivehi/Maldivian
    :ckb  ; Central Kurdish (Sorani)
    :ug)  ; Uyghur
  "Languages written right-to-left. Seeded so an app gets correct behaviour for these
without registering anything; REGISTER-LOCALE-DISPLAY overrides per locale.")

(defstruct (locale-display (:constructor %make-locale-display (endonym flag direction)))
  "Display metadata for one locale: its own name, a flag emoji, and text DIRECTION
(:LTR or :RTL)."
  (endonym "" :type string)
  (flag "" :type string)
  (direction :ltr :type keyword))

(defparameter *locale-display*
  (let ((h (make-hash-table :test 'eq)))
    (dolist (e '((:en "English" "🇬🇧") (:ru "Русский" "🇷🇺") (:fr "Français" "🇫🇷")
                 (:es "Español" "🇪🇸") (:de "Deutsch" "🇩🇪") (:it "Italiano" "🇮🇹")
                 (:pt "Português" "🇵🇹") (:nl "Nederlands" "🇳🇱") (:pl "Polski" "🇵🇱")
                 (:uk "Українська" "🇺🇦") (:zh "中文" "🇨🇳") (:ja "日本語" "🇯🇵")
                 (:ko "한국어" "🇰🇷") (:ar "العربية" "🇸🇦") (:he "עברית" "🇮🇱")
                 (:fa "فارسی" "🇮🇷") (:ur "اردو" "🇵🇰")))
      (setf (gethash (first e) h)
            (%make-locale-display (second e) (third e)
                                  (if (member (first e) +rtl-languages+) :rtl :ltr))))
    h)
  "Generic locale display reference: locale keyword -> a LOCALE-DISPLAY (endonym, flag,
direction). App-overridable via REGISTER-LOCALE-DISPLAY (hyperion ships common languages;
the app adds or corrects its own).")

(defun %display-for (locale)
  "The LOCALE-DISPLAY registered for LOCALE, or NIL. A regional tag falls back to its
primary subtag -- :AR-EG is Arabic, and an app should not have to register every region
to get that right."
  (let ((k (%to-locale locale)))
    (or (gethash k *locale-display*)
        (let ((primary (%to-locale (%primary-subtag k))))
          (and primary (not (eq primary k)) (gethash primary *locale-display*))))))

(defun register-locale-display (locale &key endonym flag direction)
  "Add or override the display for LOCALE: its ENDONYM, FLAG, and/or text DIRECTION
\(:LTR or :RTL). Unsupplied parts keep any previously registered value; a locale that has
never been registered defaults to its uppercased code, no flag, and the direction implied
by +RTL-LANGUAGES+."
  (let* ((k (%to-locale locale))
         (cur (gethash k *locale-display*)))
    (setf (gethash k *locale-display*)
          (%make-locale-display
           (or endonym (and cur (locale-display-endonym cur)) (string-upcase (%name locale)))
           (or flag (and cur (locale-display-flag cur)) "")
           (or direction
               (and cur (locale-display-direction cur))
               (if (member (%to-locale (%primary-subtag k)) +rtl-languages+) :rtl :ltr))))))

(defun locale-endonym (locale)
  "The language's own name for LOCALE (\"Русский\"), or its uppercased code if unknown."
  (let ((d (%display-for locale)))
    (if d (locale-display-endonym d) (string-upcase (%name locale)))))

(defun locale-flag (locale)
  "A flag emoji for LOCALE, or \"\" if unknown."
  (let ((d (%display-for locale)))
    (if d (locale-display-flag d) "")))

(defun locale-direction (locale)
  "Text direction for LOCALE: :RTL or :LTR (the default for anything unknown -- an
unrecognised locale renders left-to-right rather than signalling)."
  (let ((d (%display-for locale)))
    (cond (d (locale-display-direction d))
          ((member (%to-locale (%primary-subtag locale)) +rtl-languages+) :rtl)
          (t :ltr))))

(defun rtl-p (locale)
  "True when LOCALE is written right-to-left."
  (eq :rtl (locale-direction locale)))

(defun dir-attribute (locale)
  "LOCALE's direction as the HTML attribute value: \"rtl\" or \"ltr\"."
  (string-downcase (symbol-name (locale-direction locale))))

(defun lang-attributes (locale)
  "The `lang` and `dir` attribute values for LOCALE, as two values -- what a page shell
needs for `<html lang=... dir=...>`:

    (multiple-value-bind (lang dir) (i18n:lang-attributes locale)
      (spin:with-html (:html :lang lang :dir dir ...)))

Returned together so an app never emits one without the other: a page whose `lang` says
Arabic while its `dir` still says ltr is the exact bug this prevents."
  (values (%loc-string (%to-locale locale)) (dir-attribute locale)))

(defun %switch-href (code) (format nil "?lang=~A" code))

(defun language-switcher (&key current locales (href-fn #'%switch-href))
  "Render (as an HTML string) a language switcher: the CURRENT locale (flag + endonym)
and a menu of LOCALES to switch to. Each option is a plain link to the same page with
the new locale -- a switch changes the WHOLE document (the <html lang> attribute, the
<head>, and every string), which only a real navigation re-renders, so this is
deliberately NOT an HTMX partial swap. The server resolves ?lang=, persists via the
store, and re-renders the page. LOCALES is the app's supported set (e.g.
(supported-locales source)); HREF-FN maps a locale code string to the switch URL
(default \"?lang=<code>\" -- override to preserve other query params). An app wanting
snappier switching can boost these links by putting hx-boost on an ancestor; they still
degrade to real navigation. (nav is marked data-no-boost so an app-wide hx-boost does
not silently turn the switch into a body-only swap that leaves <html lang> stale.)"
  (let ((cur (%to-locale current)))
    (spin:with-html-string
      ;; Each entry carries BOTH lang and dir for the locale it names. A switcher shows
      ;; every language in its own script, so an Arabic or Hebrew endonym is a run of RTL
      ;; text sitting inside a page that may be LTR (and vice versa). Without dir on the
      ;; element the browser applies the page's direction to it, and mixed-script labels --
      ;; anything with a bracket, digit, or slash -- reorder visibly wrong. The bidi
      ;; algorithm needs the element to declare its own base direction; nothing else fixes
      ;; it, including CSS.
      (:nav :class "language-switcher" :aria-label "Language" :data-no-boost "true"
        (:span :class "language-switcher__current"
               :lang (%loc-string cur) :dir (dir-attribute cur)
          (:span :class "language-switcher__flag" (locale-flag cur))
          (:span :class "language-switcher__name" (locale-endonym cur)))
        (:ul :class "language-switcher__menu"
          (dolist (loc locales)
            (let* ((k (%to-locale loc))
                   (code (%loc-string k))
                   (currentp (eq k cur)))
              (:li
               (:a :href (funcall href-fn code)
                   :lang code
                   :dir (dir-attribute k)
                   :aria-current (if currentp "true" "false")
                   :class (if currentp
                              "language-switcher__option is-current"
                              "language-switcher__option")
                   (:span :class "language-switcher__flag" (locale-flag k))
                   (:span :class "language-switcher__name" (locale-endonym k)))))))))))
