;;;; appearance.lisp --- theme, contrast and look: the visitor's choice, and the tokens (#981)
;;;;
;;;; Three settings decide how a hyperion page looks, and each is an attribute on <html>:
;;;;
;;;;   data-theme     light | dark       absent: the system's prefers-color-scheme decides
;;;;   data-contrast  normal | high      absent: the system's prefers-contrast: more decides
;;;;   data-look      flat | gradient    absent: flat
;;;;
;;;; This file has two parts.
;;;;
;;;; The first is the visitor's choice: an APPEARANCE value, a store protocol
;;;; (READ-APPEARANCE, PERSIST-APPEARANCE) with a cookie store, and HTML-ATTRIBUTES, which
;;;; turns a choice into the attributes for <html>. An app that already persists the choice
;;;; somewhere else supplies its own store with the same two methods. A desktop app renders
;;;; the same pages, so it uses the same attributes, and its store can write a file.
;;;;
;;;; The second is the tokens. An app writes one table of token values per colour scheme,
;;;; APPEARANCE-CSS turns it into CSS for every combination of the three settings, and
;;;; APPEARANCE-CONTRAST-FAILURES checks every text token against its background in every
;;;; combination, by WCAG's contrast formula, and the focus ring against every surface it can be
;;;; drawn on, at 3:1. Token names are the same in both looks; only
;;;; the values differ. In the flat look a background token is a colour; in the gradient look
;;;; it may be a linear gradient, so components use `background:', never `background-color:'.

(in-package #:hyperion/appearance)

;;; --- the visitor's choice ---------------------------------------------------

(defparameter *themes* '(:light :dark))
(defparameter *contrasts* '(:normal :high))
(defparameter *looks* '(:flat :gradient))

(defstruct (appearance (:constructor %make-appearance (theme contrast look)))
  "A visitor's appearance settings. Each slot is a keyword, or NIL. The default for theme
and for contrast is the system: NIL follows prefers-color-scheme and prefers-contrast, so
contrast is normal unless the operating system asks for more. The default for look is
flat."
  (theme nil :read-only t)
  (contrast nil :read-only t)
  (look nil :read-only t))

(defun %check-setting (name value allowed)
  (unless (or (null value) (member value allowed))
    (error "~S is not a valid ~A; expected NIL or one of ~S." value name allowed))
  value)

(defun make-appearance (&key theme contrast look)
  "An appearance. THEME is :LIGHT or :DARK, CONTRAST :NORMAL or :HIGH, LOOK :FLAT or
:GRADIENT; NIL leaves the setting to the system or the default. Signals on any other value."
  (%make-appearance (%check-setting "theme" theme *themes*)
                    (%check-setting "contrast" contrast *contrasts*)
                    (%check-setting "look" look *looks*)))

(defun %setting-from-string (string allowed)
  "The keyword in ALLOWED whose name is STRING, ignoring case, or NIL."
  (and (stringp string)
       (find string allowed :test #'string-equal)))

(defun appearance-from-strings (&key theme contrast look)
  "An appearance from strings, such as the fields of a form or the parts of a cookie. A
string that names no allowed value gives NIL for that setting, so a forged or stale value
falls back to the system or the default and never signals."
  (%make-appearance (%setting-from-string theme *themes*)
                    (%setting-from-string contrast *contrasts*)
                    (%setting-from-string look *looks*)))

(defun html-attributes (appearance)
  "The attributes for <html> as a plist, such as (:DATA-THEME \"dark\" :DATA-LOOK
\"gradient\"). A setting left to the system or the default is omitted, which is what lets
the CSS follow the system preference."
  (loop for (key value) in (list (list :data-theme (appearance-theme appearance))
                                 (list :data-contrast (appearance-contrast appearance))
                                 (list :data-look (appearance-look appearance)))
        when value append (list key (string-downcase (symbol-name value)))))

;;; --- store protocol ----------------------------------------------------------

(defgeneric read-appearance (store request)
  (:documentation
   "The appearance STORE holds for REQUEST (the Clack env). A store that holds nothing for
the request returns an appearance with every setting NIL."))

(defgeneric persist-appearance (store appearance)
  (:documentation
   "Persist APPEARANCE through STORE. Returns response headers as a plist, such as
(:SET-COOKIE \"...\"), for the caller to merge into its response."))

(defstruct (cookie-appearance-store (:constructor %make-cookie-appearance-store))
  (name "appearance") (path "/") (max-age 31536000))

(defun make-cookie-appearance-store (&key (name "appearance") (path "/") (max-age 31536000))
  "A store that keeps the appearance in one cookie, NAME (default \"appearance\"), for
MAX-AGE seconds (default one year). The value is three words joined by dots, theme then
contrast then look, with \"system\" for a setting left to the system: \"dark.system.flat\"."
  (%make-cookie-appearance-store :name name :path path :max-age max-age))

(defun %cookie-word (value)
  (if value (string-downcase (symbol-name value)) "system"))

(defun appearance-cookie-value (appearance)
  "APPEARANCE as the cookie store writes it."
  (format nil "~A.~A.~A"
          (%cookie-word (appearance-theme appearance))
          (%cookie-word (appearance-contrast appearance))
          (%cookie-word (appearance-look appearance))))

(defun parse-appearance-cookie (value)
  "The appearance in cookie VALUE. A missing, malformed or unknown part gives NIL for that
setting."
  (let ((parts (if (stringp value) (uiop:split-string value :separator ".") '())))
    (appearance-from-strings :theme (first parts)
                             :contrast (second parts)
                             :look (third parts))))

(defmethod read-appearance ((store cookie-appearance-store) request)
  (parse-appearance-cookie (http:cookie request (cookie-appearance-store-name store))))

(defmethod persist-appearance ((store cookie-appearance-store) appearance)
  (list :set-cookie
        (format nil "~A=~A; Path=~A; Max-Age=~D; SameSite=Lax"
                (cookie-appearance-store-name store) (appearance-cookie-value appearance)
                (cookie-appearance-store-path store) (cookie-appearance-store-max-age store))))

;;; --- tokens -----------------------------------------------------------------

(defparameter *token-pairs*
  '((:surface-text . :surface)
    (:surface-raised-text . :surface-raised)
    (:header-text . :header)
    (:button-text . :button)
    (:button-primary-text . :button-primary)
    (:button-danger-text . :button-danger))
  "Each text token and the background token it is drawn on. Every pair is checked against
WCAG AA in every combination of theme, contrast and look.")

(defparameter *ring-backgrounds* '(:surface :surface-raised :header)
  "The background tokens the focus ring is checked against, at 3:1 (WCAG 2 non-text contrast):
the surfaces a focused control sits on. A button's own fill is not one of them, because the ring
is drawn outside the button.")

(defparameter *colour-tokens*
  (append (mapcar #'car *token-pairs*) '(:focus-ring))
  "The tokens that must be a colour in every look, never a gradient: the text tokens and the
focus ring.")

(defparameter *tokens*
  (append (loop for (text . background) in *token-pairs* append (list background text))
          '(:focus-ring))
  "Every appearance token, as keywords. Each becomes the custom property --hy-<name>.")

(defparameter *default-spacing* '("4px" "8px" "12px" "16px" "24px" "32px" "48px")
  "The seven spacing steps, --hy-space-1 to --hy-space-7, on a 4px base.")

(defparameter *default-type-scale*
  '(:caps "0.6875rem" :meta "0.75rem" :dense "0.8125rem" :body "0.875rem"
    :heading "1rem" :title "1.25rem" :prose "1.0625rem")
  "The font size of each text role, --hy-text-<role>: caps (small capitals labels), meta
(timestamps and counts), dense (tables and lists), body, heading, title, and prose (long
reading text, in the prose font). Bulma's own sizes, --bulma-size-1 to 7, are separate and
unchanged.")

(defparameter *default-fonts*
  '(:ui "system-ui, -apple-system, \"Segoe UI\", Roboto, \"Helvetica Neue\", Arial, sans-serif"
    :prose "Georgia, \"Iowan Old Style\", \"Times New Roman\", serif")
  "The two font families: --hy-font-ui for controls and most text, and --hy-font-prose, a serif,
for long reading text.")

(defparameter *default-schemes*
  '(:light
    (:surface "#ffffff" :surface-text "#2b2f36"
     :surface-raised "#f5f6f8" :surface-raised-text "#2b2f36"
     :header "#eef0f4" :header-text "#1f2329"
     :button "#ffffff" :button-text "#2b2f36"
     :button-primary "#00d1b2" :button-primary-text "#14161a"
     :button-danger "#cc0f35" :button-danger-text "#ffffff"
     :focus-ring "#485fc7"
     :gradient
     (:surface (:gradient "#ffffff" "#f3f4f7")
      :surface-raised (:gradient "#fafbfc" "#eef0f4")
      :header (:gradient "#f5f7fa" "#e2e6ec")
      :button (:gradient "#ffffff" "#eceef2")
      :button-primary (:gradient "#2ee6c9" "#00c4a7")
      :button-danger (:gradient "#d8173e" "#b30c2d")))
    :dark
    (:surface "#14161a" :surface-text "#e6e8eb"
     :surface-raised "#1d2026" :surface-raised-text "#e6e8eb"
     :header "#23272e" :header-text "#f0f2f5"
     :button "#2a2e36" :button-text "#e6e8eb"
     :button-primary "#00d1b2" :button-primary-text "#0b0c0e"
     :button-danger "#f14668" :button-danger-text "#0b0c0e"
     :focus-ring "#7a9cff"
     :gradient
     (:surface (:gradient "#181a1f" "#111317")
      :surface-raised (:gradient "#22252c" "#1a1d22")
      :header (:gradient "#2a2e36" "#1f2228")
      :button (:gradient "#343943" "#272b33")
      :button-primary (:gradient "#2ee6c9" "#00c4a7")
      :button-danger (:gradient "#f6728c" "#f14668")))
    :light-high
    (:surface "#ffffff" :surface-text "#000000"
     :surface-raised "#ffffff" :surface-raised-text "#000000"
     :header "#ffffff" :header-text "#000000"
     :button "#ffffff" :button-text "#000000"
     :button-primary "#00574b" :button-primary-text "#ffffff"
     :button-danger "#8f0022" :button-danger-text "#ffffff"
     :focus-ring "#0033cc"
     :gradient
     (:surface (:gradient "#ffffff" "#f4f4f4")
      :surface-raised (:gradient "#ffffff" "#f0f0f0")
      :header (:gradient "#ffffff" "#ebebeb")
      :button (:gradient "#ffffff" "#ededed")
      :button-primary (:gradient "#006356" "#004a40")
      :button-danger (:gradient "#9e0026" "#7a001d")))
    :dark-high
    (:surface "#000000" :surface-text "#ffffff"
     :surface-raised "#000000" :surface-raised-text "#ffffff"
     :header "#000000" :header-text "#ffffff"
     :button "#000000" :button-text "#ffffff"
     :button-primary "#5cf2db" :button-primary-text "#000000"
     :button-danger "#ff8fa6" :button-danger-text "#000000"
     :focus-ring "#ffd400"
     :gradient
     (:surface (:gradient "#0a0a0a" "#000000")
      :surface-raised (:gradient "#121212" "#000000")
      :header (:gradient "#161616" "#000000")
      :button (:gradient "#161616" "#050505")
      :button-primary (:gradient "#7af5e2" "#5cf2db")
      :button-danger (:gradient "#ffa3b6" "#ff8fa6"))))
  "Hyperion's own token values, one plist per scheme. Each plist gives every token for the
flat look, and its :GRADIENT plist gives the values the gradient look changes.")

(defstruct (appearance-table (:constructor %make-appearance-table
                                  (schemes spacing type-scale fonts)))
  "Token values for the four schemes (light, dark, and the high-contrast form of each), the
spacing steps, the font size of each text role, and the two font families."
  (schemes nil :read-only t)
  (spacing nil :read-only t)
  (type-scale nil :read-only t)
  (fonts nil :read-only t))

(defun %merge-scheme (defaults overrides)
  "DEFAULTS with every key in OVERRIDES replaced. The :GRADIENT sub-plists merge the same
way, so an app can change one gradient token and keep the rest."
  (let ((out (copy-list defaults)))
    (loop for (key value) on overrides by #'cddr
          do (setf (getf out key)
                   (if (eq key :gradient)
                       (%merge-scheme (getf defaults :gradient) value)
                       value)))
    out))

(defun %check-value (value where)
  (flet ((hex-p (s)
           (and (stringp s) (= 7 (length s)) (char= #\# (char s 0))
                (every (lambda (c) (digit-char-p c 16)) (subseq s 1)))))
    (unless (or (hex-p value)
                (and (consp value) (eq :gradient (first value))
                     (>= (length (rest value)) 2)
                     (every #'hex-p (rest value))))
      (error "~A: ~S is not a \"#rrggbb\" colour or a (:GRADIENT \"#rrggbb\" ...) with at least two stops."
             where value))))

(defun %check-scheme (name scheme)
  (dolist (token *tokens*)
    (let ((flat (getf scheme token)))
      (%check-value flat (format nil "~(~A~) ~(~A~)" name token))
      (when (and (consp flat) (member token *colour-tokens*))
        (error "~(~A~) ~(~A~): a text token or the focus ring must be a colour, not a gradient."
               name token))))
  (loop for (token value) on (getf scheme :gradient) by #'cddr
        do (unless (member token *tokens*)
             (error "~(~A~) gradient: ~S is not an appearance token." name token))
           (%check-value value (format nil "~(~A~) gradient ~(~A~)" name token))
           (when (and (consp value) (member token *colour-tokens*))
             (error "~(~A~) gradient ~(~A~): a text token or the focus ring must be a colour, not a gradient."
                    name token)))
  (loop for (token) on scheme by #'cddr
        do (unless (or (eq token :gradient) (member token *tokens*))
             (error "~(~A~): ~S is not an appearance token." name token))))

(defun %merge-fixed (what defaults given)
  "DEFAULTS, a plist of CSS values, with each key in GIVEN replaced. Signals on a key DEFAULTS
does not have, and on a value that is not a non-empty string or that holds a character that
would end the declaration or the rule it is written into."
  (let ((out (copy-list defaults)))
    (loop for (key value) on given by #'cddr
          do (unless (getf defaults key)
               (error "~A: ~S is not one of ~S." what key
                      (loop for (k) on defaults by #'cddr collect k)))
             (unless (and (stringp value) (plusp (length value))
                          (not (find-if (lambda (c) (find c (format nil ";{}<~%"))) value)))
               (error "~A ~(~A~): ~S is not a CSS value." what key value))
             (setf (getf out key) value))
    out))

(defun make-appearance-table (&key light dark light-high dark-high (spacing *default-spacing*)
                                   type-scale fonts)
  "A token table. LIGHT, DARK, LIGHT-HIGH and DARK-HIGH are plists of token values, merged
over hyperion's defaults, so an app gives only the tokens it changes. A value is a colour,
\"#rrggbb\", or for a background token a gradient, (:GRADIENT \"#rrggbb\" \"#rrggbb\" ...). A
scheme's :GRADIENT plist gives the values the gradient look changes. SPACING is the seven
spacing steps as CSS lengths. TYPE-SCALE and FONTS are plists merged over *DEFAULT-TYPE-SCALE*
and *DEFAULT-FONTS*. Signals on an unknown token, role or font, a malformed value, or a gradient
given for a text token or the focus ring."
  (unless (and (= 7 (length spacing)) (every #'stringp spacing))
    (error "SPACING must be seven CSS lengths, not ~S." spacing))
  (let ((schemes
          (loop for (name given) in (list (list :light light) (list :dark dark)
                                          (list :light-high light-high)
                                          (list :dark-high dark-high))
                for merged = (%merge-scheme (getf *default-schemes* name) given)
                do (%check-scheme name merged)
                append (list name merged))))
    (%make-appearance-table schemes (copy-list spacing)
                            (%merge-fixed "TYPE-SCALE" *default-type-scale* type-scale)
                            (%merge-fixed "FONTS" *default-fonts* fonts))))

(defun %scheme-name (theme contrast)
  (ecase contrast
    (:normal theme)
    (:high (ecase theme (:light :light-high) (:dark :dark-high)))))

(defun token-values (table theme contrast look)
  "Every token's value for one combination, as a plist."
  (let ((scheme (getf (appearance-table-schemes table) (%scheme-name theme contrast))))
    (loop for token in *tokens*
          append (list token
                       (or (and (eq look :gradient) (getf (getf scheme :gradient) token))
                           (getf scheme token))))))

;;; --- CSS --------------------------------------------------------------------

(defun %css-value (value)
  (if (consp value)
      (format nil "linear-gradient(180deg, ~{~A~^, ~})" (rest value))
      value))

(defun %declarations (out table theme contrast look &key fixed)
  "The declarations of TABLE's tokens for one combination, and with FIXED the tokens that are the
same in every combination: spacing, the text roles and the fonts."
  (loop for (token value) on (token-values table theme contrast look) by #'cddr
        do (format out "  --hy-~(~A~): ~A;~%" token (%css-value value)))
  (when fixed
    (loop for step in (appearance-table-spacing table)
          for i from 1
          do (format out "  --hy-space-~D: ~A;~%" i step))
    (loop for (role size) on (appearance-table-type-scale table) by #'cddr
          do (format out "  --hy-text-~(~A~): ~A;~%" role size))
    (loop for (font family) on (appearance-table-fonts table) by #'cddr
          do (format out "  --hy-font-~(~A~): ~A;~%" font family))))

(defun %rule (out table theme contrast look theme-explicit contrast-explicit)
  "One rule for one combination. A setting given on <html> is matched by attribute; a
setting left to the system is matched by the attribute's absence inside a media query, so
the two kinds of rule never match the same page."
  (let ((selector
          (format nil ":root~A~A~A"
                  (if theme-explicit
                      (format nil "[data-theme=\"~(~A~)\"]" theme)
                      ":not([data-theme])")
                  (if contrast-explicit
                      (format nil "[data-contrast=\"~(~A~)\"]" contrast)
                      ":not([data-contrast])")
                  (if (eq look :gradient)
                      "[data-look=\"gradient\"]"
                      ":not([data-look=\"gradient\"])")))
        (media
          (remove nil
                  (list (unless theme-explicit
                          (if (eq theme :dark)
                              "(prefers-color-scheme: dark)"
                              "not all and (prefers-color-scheme: dark)"))
                        (unless contrast-explicit
                          (if (eq contrast :high)
                              "(prefers-contrast: more)"
                              "not all and (prefers-contrast: more)"))))))
    (dolist (m media) (format out "@media ~A {~%" m))
    (format out "~A {~%" selector)
    (%declarations out table theme contrast look)
    (write-line "}" out)
    (dolist (m media) (declare (ignore m)) (write-line "}" out))))

(defparameter *gradient-targets*
  '((".button.is-primary:not(.is-outlined):not(.is-light):not(.is-inverted)" :button-primary)
    (".button.is-danger:not(.is-outlined):not(.is-light):not(.is-inverted)" :button-danger)
    (".navbar" :header ".navbar-item" ".navbar-link")
    (".modal-card-head" :header ".modal-card-title")
    (".card-header" :header ".card-header-title")
    (".box" :surface-raised)
    (".card" :surface-raised))
  "Bulma classes the gradient look applies its tokens to: the selector, the background
token, and descendants that carry their own text colour and must take the token's text
colour too. A button's outlined, light and inverted variants keep Bulma's own colours,
because they are not filled with the button's colour. Hover is left to Bulma.")

(defparameter *gradient-buttons* '(:button-primary :button-danger)
  "The background tokens in *GRADIENT-TARGETS* that fill a button, which get hover, press and
focus rules.")

(defparameter *hover-overlay* "rgba(128, 128, 128, 0.14)"
  "The layer drawn over a button's background on hover. Grey, so it darkens a light button and
lightens a dark one.")

(defun %gradient-targets (out)
  (loop for (selector token . children) in *gradient-targets*
        for scope = (format nil ":root[data-look=\"gradient\"] ~A" selector)
        ;; `background:', because an app may give a plain colour as a gradient-look value, and
        ;; `background-image:' with a colour is invalid, which would leave Bulma's background
        ;; under the token's text colour.
        do (format out "~A {~%  background: var(--hy-~(~A~));~%  color: var(--hy-~(~A~)-text);~%}~%"
                   scope token token)
           (when children
             (format out "~{~A~^, ~} {~%  color: var(--hy-~(~A~)-text);~%}~%"
                     (mapcar (lambda (c) (format nil "~A ~A" scope c)) children)
                     token))
           ;; A button's `background:' above replaces the background colour Bulma changes on
           ;; hover, so hover, press and focus are given here: a translucent grey layer over the
           ;; token, which works on a colour or a gradient, and the focus ring.
           (when (member token *gradient-buttons*)
             (format out "~A:hover {~%  background: linear-gradient(~A, ~A), var(--hy-~(~A~));~%}~%"
                     scope *hover-overlay* *hover-overlay* token)
             (format out "~A:active {~%  filter: brightness(0.92);~%}~%" scope)
             (format out "~A:focus-visible {~%  outline: 2px solid var(--hy-focus-ring);~%  outline-offset: 2px;~%}~%"
                     scope))))

(defun appearance-css (&optional (table (make-appearance-table)))
  "CSS defining every --hy-* token for every combination of theme, contrast and look, from
TABLE (hyperion's defaults when omitted). A bare :root rule gives the light, normal-contrast,
flat values, for a browser that matches no other rule, and the tokens that do not change with
the settings: the spacing steps (--hy-space-1 to 7), the text roles (--hy-text-caps, -meta,
-dense, -body, -heading, -title and -prose) and the fonts (--hy-font-ui and --hy-font-prose).

Serve it after Bulma. Bulma's own sizes, --bulma-size-1 to 7, which HYPERION/ASSETS:THEME
sets, stay as they are; the text roles are separate tokens beside them.

A browser that does not support the prefers-contrast media feature (Chrome before 96,
Firefox before 101) matches none of the rules that leave contrast to the system, so on a
page without data-contrast it shows the bare :root rule's light, flat look."
  (with-output-to-string (out)
    (write-line ":root {" out)
    (%declarations out table :light :normal :flat :fixed t)
    (write-line "}" out)
    (dolist (theme *themes*)
      (dolist (contrast *contrasts*)
        (dolist (look *looks*)
          (dolist (theme-explicit '(t nil))
            (dolist (contrast-explicit '(t nil))
              (%rule out table theme contrast look theme-explicit contrast-explicit))))))
    (%gradient-targets out)))

;;; --- contrast check ------------------------------------------------------------

(defun %channels (hex)
  (list (parse-integer hex :start 1 :end 3 :radix 16)
        (parse-integer hex :start 3 :end 5 :radix 16)
        (parse-integer hex :start 5 :end 7 :radix 16)))

(defun relative-luminance (hex)
  "WCAG 2 relative luminance of HEX, \"#rrggbb\"."
  (destructuring-bind (r g b)
      (mapcar (lambda (c)
                (let ((s (/ c 255d0)))
                  (if (<= s 0.03928d0) (/ s 12.92d0) (expt (/ (+ s 0.055d0) 1.055d0) 2.4d0))))
              (%channels hex))
    (+ (* 0.2126d0 r) (* 0.7152d0 g) (* 0.0722d0 b))))

(defun contrast-ratio (a b)
  "WCAG 2 contrast ratio between colours A and B, from 1 to 21."
  (let ((la (relative-luminance a)) (lb (relative-luminance b)))
    (/ (+ (max la lb) 0.05d0) (+ (min la lb) 0.05d0))))

(defun %mix (a b fraction)
  (format nil "#~{~2,'0X~}"
          (mapcar (lambda (x y) (round (+ x (* fraction (- y x)))))
                  (%channels a) (%channels b))))

(defun background-samples (value)
  "The colours to check text against on background VALUE: the colour itself, or for a
gradient every stop and 19 colours between each pair of stops, interpolated in sRGB as a
browser draws a gradient by default."
  (if (consp value)
      (let ((stops (rest value)))
        (cons (first stops)
              (loop for (a b) on stops while b
                    append (append (loop for k from 1 to 19 collect (%mix a b (/ k 20)))
                                   (list b)))))
      (list value)))

(defun %worst-sample (text background)
  "The sample of BACKGROUND with the lowest contrast against TEXT, and that contrast, as a
cons."
  (let ((worst nil))
    (dolist (sample (background-samples background) worst)
      (let ((ratio (contrast-ratio text sample)))
        (when (or (null worst) (< ratio (cdr worst)))
          (setf worst (cons sample ratio)))))))

(defparameter *minimum-contrast* 4.5d0
  "WCAG 2 level AA for normal-size text.")

(defparameter *minimum-ring-contrast* 3d0
  "WCAG 2 level AA for the focus ring, a non-text indicator.")

(defun appearance-contrast-failures (&optional (table (make-appearance-table)))
  "Every pair in TABLE that falls below WCAG AA, in any of the eight combinations of theme,
contrast and look: each text token against its background at 4.5:1, and the focus ring against
each of *RING-BACKGROUNDS* at 3:1. Each failure is a plist (:THEME :CONTRAST :LOOK :TEXT
:BACKGROUND :COLOUR :RATIO :REQUIRED), where :TEXT is the text token or :FOCUS-RING, :COLOUR is
the darkest or lightest sample of the background that failed, and :REQUIRED the ratio it had to
reach. NIL means every pair passes. An app calls this in its own tests on its own table."
  (let ((failures '()))
    (dolist (theme *themes*)
      (dolist (contrast *contrasts*)
        (dolist (look *looks*)
          (let ((values (token-values table theme contrast look)))
            (loop for (fg-token background required)
                    in (append (loop for (text . background) in *token-pairs*
                                     collect (list text background *minimum-contrast*))
                               (loop for background in *ring-backgrounds*
                                     collect (list :focus-ring background
                                                   *minimum-ring-contrast*)))
                  for worst = (%worst-sample (getf values fg-token) (getf values background))
                  when (< (cdr worst) required)
                    do (push (list :theme theme :contrast contrast :look look
                                   :text fg-token :background background
                                   :colour (car worst) :ratio (cdr worst) :required required)
                             failures))))))
    (nreverse failures)))
