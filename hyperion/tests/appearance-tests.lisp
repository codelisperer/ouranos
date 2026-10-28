;;;; appearance-tests.lisp --- theme, contrast and look, and the --hy-* tokens (#981)

(in-package #:hyperion/tests)

(def-suite appearance :description "Appearance settings, store, tokens and contrast." :in hyperion)
(in-suite appearance)

(defun %app-env (&optional cookie)
  "A Clack env whose Cookie header is COOKIE."
  (let ((headers (make-hash-table :test 'equal)))
    (when cookie (setf (gethash "cookie" headers) cookie))
    (list :request-method :get :path-info "/" :headers headers)))

(defun %settings (a)
  (list (appr:appearance-theme a) (appr:appearance-contrast a) (appr:appearance-look a)))

;;; --- the visitor's choice -------------------------------------------------------

(test make-appearance-takes-the-allowed-values-and-nil
  (is (equal '(:dark :high :gradient)
             (%settings (appr:make-appearance :theme :dark :contrast :high :look :gradient))))
  (is (equal '(nil nil nil) (%settings (appr:make-appearance)))))

(test make-appearance-refuses-any-other-value
  (signals error (appr:make-appearance :theme :sepia))
  (signals error (appr:make-appearance :contrast :more))
  (signals error (appr:make-appearance :look "gradient")))

(test a-string-naming-no-allowed-value-gives-nil
  "Form fields and cookies are visitor input, so a stale or forged value falls back to the
system rather than signalling."
  (is (equal '(:dark :high :gradient)
             (%settings (appr:appearance-from-strings :theme "Dark" :contrast "HIGH"
                                                      :look "gradient"))))
  (is (equal '(nil nil nil)
             (%settings (appr:appearance-from-strings :theme "sepia" :contrast "system"
                                                      :look "<script>")))))

(test html-attributes-omit-a-setting-left-to-the-system
  (is (equal '(:data-theme "dark" :data-look "gradient")
             (appr:html-attributes (appr:make-appearance :theme :dark :look :gradient))))
  (is (equal '(:data-contrast "high")
             (appr:html-attributes (appr:make-appearance :contrast :high))))
  (is (null (appr:html-attributes (appr:make-appearance)))))

;;; --- cookie store -----------------------------------------------------------------

(test the-cookie-store-writes-one-cookie
  (let* ((store (appr:make-cookie-appearance-store))
         (headers (appr:persist-appearance store (appr:make-appearance :theme :dark
                                                                       :look :gradient))))
    (is (equal "appearance=dark.system.gradient; Path=/; Max-Age=31536000; SameSite=Lax"
               (getf headers :set-cookie)))))

(test the-cookie-store-reads-back-what-it-wrote
  (let ((store (appr:make-cookie-appearance-store :name "look")))
    (dolist (a (list (appr:make-appearance :theme :light :contrast :high :look :flat)
                     (appr:make-appearance :contrast :normal)
                     (appr:make-appearance)))
      (let ((value (appr:appearance-cookie-value a)))
        (is (equal (%settings a)
                   (%settings (appr:read-appearance
                               store (%app-env (format nil "other=1; look=~A" value)))))
            "round trip of ~A" value)))))

(test the-cookie-store-reads-a-missing-or-malformed-cookie-as-the-system
  (let ((store (appr:make-cookie-appearance-store)))
    (is (equal '(nil nil nil) (%settings (appr:read-appearance store (%app-env)))))
    (is (equal '(nil nil nil)
               (%settings (appr:read-appearance store (%app-env "appearance=")))))
    (is (equal '(:dark nil nil)
               (%settings (appr:read-appearance store (%app-env "appearance=dark.x")))))))

;;; --- token table ------------------------------------------------------------------

(test a-table-merges-an-app-s-values-over-the-defaults
  (let* ((table (appr:make-appearance-table
                 :light '(:header "#dde3ea" :gradient (:header (:gradient "#ffffff" "#dde3ea")))))
         (flat (appr:token-values table :light :normal :flat))
         (gradient (appr:token-values table :light :normal :gradient))
         (defaults (appr:token-values (appr:make-appearance-table) :light :normal :flat)))
    (is (equal "#dde3ea" (getf flat :header)))
    (is (equal '(:gradient "#ffffff" "#dde3ea") (getf gradient :header)))
    (is (equal (getf defaults :surface) (getf flat :surface)))
    (is (consp (getf gradient :surface)) "the default gradient for a token the app left alone")))

(test both-looks-define-every-token-in-every-scheme
  "The defaults give every token a value in the flat look, and give every background token its
own gradient in the gradient look. TOKEN-VALUES falls back to the flat value for a token the
gradient look does not change, so a gradient value that equals the flat colour would mean the
defaults left that token out of the gradient look."
  (let ((table (appr:make-appearance-table))
        (backgrounds '(:surface :surface-raised :header :button :button-primary :button-danger)))
    (dolist (theme '(:light :dark))
      (dolist (contrast '(:normal :high))
        (let ((flat (appr:token-values table theme contrast :flat))
              (gradient (appr:token-values table theme contrast :gradient)))
          (is (= 12 (/ (length flat) 2)))
          (is (every #'stringp (loop for (nil v) on flat by #'cddr collect v))
              "~A ~A has a flat token that is not a colour" theme contrast)
          (dolist (token backgrounds)
            (is-true (let ((v (getf gradient token))) (and (consp v) (eq :gradient (first v))))
                "~A ~A gives ~A no gradient in the gradient look: ~S"
                theme contrast token (getf gradient token))))))))

(test a-table-refuses-what-it-cannot-check
  (signals error (appr:make-appearance-table :light '(:sidebar "#ffffff")))
  (signals error (appr:make-appearance-table :light '(:header "red")))
  (signals error (appr:make-appearance-table :dark '(:header (:gradient "#000000"))))
  (signals error (appr:make-appearance-table
                  :dark '(:gradient (:header-text (:gradient "#000000" "#111111")))))
  (signals error (appr:make-appearance-table :spacing '("4px"))))

;;; --- CSS ----------------------------------------------------------------------------

(defun %count-matches (text needle)
  (loop with start = 0
        for pos = (search needle text :start2 start)
        while pos count t do (setf start (1+ pos))))

(test the-css-has-one-rule-per-combination-and-source
  "Eight combinations, each with the theme and the contrast either given on <html> or left
to the system: 32 rules, plus the bare :root fallback."
  (let ((css (appr:appearance-css)))
    (is (= 33 (%count-matches css (format nil "  --hy-surface: "))))
    (is (search (format nil ":root[data-theme=\"dark\"][data-contrast=\"high\"][data-look=\"gradient\"] {") css))
    (is (search (format nil ":root[data-theme=\"light\"][data-contrast=\"normal\"]:not([data-look=\"gradient\"]) {") css))))

(test a-setting-left-to-the-system-is-matched-inside-its-media-query
  (let ((css (appr:appearance-css)))
    (is (search (format nil "@media (prefers-color-scheme: dark) {~%@media (prefers-contrast: more) {~%:root:not([data-theme]):not([data-contrast]):not([data-look=\"gradient\"]) {") css))
    (is (search (format nil "@media not all and (prefers-color-scheme: dark) {~%@media not all and (prefers-contrast: more) {~%:root:not([data-theme]):not([data-contrast])[data-look=\"gradient\"] {") css))
    (is (search (format nil "@media (prefers-contrast: more) {~%:root[data-theme=\"light\"]:not([data-contrast]):not([data-look=\"gradient\"]) {") css))))

(test the-css-carries-each-combination-s-own-values
  (let* ((table (appr:make-appearance-table
                 :dark-high '(:header "#101010" :gradient (:header (:gradient "#202020" "#000000")))))
         (css (appr:appearance-css table))
         (flat (search ":root[data-theme=\"dark\"][data-contrast=\"high\"]:not([data-look=\"gradient\"]) {" css))
         (gradient (search ":root[data-theme=\"dark\"][data-contrast=\"high\"][data-look=\"gradient\"] {" css)))
    (is (and flat (search "--hy-header: #101010;" css :start2 flat
                                                       :end2 (position #\} css :start flat))))
    (is (and gradient (search "--hy-header: linear-gradient(180deg, #202020, #000000);" css
                              :start2 gradient :end2 (position #\} css :start gradient))))))

(test the-bare-root-rule-carries-the-spacing-steps
  (let* ((css (appr:appearance-css))
         (root (subseq css 0 (position #\} css))))
    (is (search "--hy-space-1: 4px;" root))
    (is (search "--hy-space-7: 48px;" root))
    (is (search "--hy-surface: #ffffff;" root))))

(test the-gradient-look-applies-the-tokens-to-bulma-s-classes
  (let ((css (appr:appearance-css)))
    (is (search (format nil ":root[data-look=\"gradient\"] .button.is-primary:not(.is-outlined):not(.is-light):not(.is-inverted) {~%  background: var(--hy-button-primary);~%  color: var(--hy-button-primary-text);") css))
    (is (search ":root[data-look=\"gradient\"] .navbar .navbar-item, :root[data-look=\"gradient\"] .navbar .navbar-link {" css))))

;;; --- contrast ----------------------------------------------------------------------

(test contrast-ratio-matches-wcag-s-reference-values
  (is (< 20.99d0 (appr:contrast-ratio "#000000" "#ffffff") 21.01d0))
  (is (< 4.53d0 (appr:contrast-ratio "#767676" "#ffffff") 4.55d0))
  (is (= 1d0 (appr:contrast-ratio "#336699" "#336699"))))

(test a-gradient-is-sampled-between-its-stops
  (let ((samples (appr:background-samples '(:gradient "#000000" "#ffffff" "#000000"))))
    (is (= 41 (length samples)))
    (is (equal "#000000" (first samples)))
    (is (equal "#FFFFFF" (string-upcase (nth 20 samples))))
    (is (equal "#808080" (nth 10 samples))))
  (is (equal '("#123456") (appr:background-samples "#123456"))))

(test the-default-tokens-meet-wcag-aa-in-each-look-in-each-scheme
  "Every text token against its background, in light and dark, normal and high contrast,
flat and gradient: 48 pairs, and for a gradient every sample along it."
  (let ((failures (appr:appearance-contrast-failures)))
    (is (null failures) "~{~S~^~%~}" failures)))

(test the-contrast-check-reports-the-pair-and-the-combination
  (let ((failures (appr:appearance-contrast-failures
                   (appr:make-appearance-table
                    :dark '(:gradient (:header (:gradient "#2a2e36" "#d0d0d0")))))))
    (is (= 1 (length failures)))
    (let ((f (first failures)))
      (is (equal '(:dark :normal :gradient :header-text :header)
                 (list (getf f :theme) (getf f :contrast) (getf f :look)
                       (getf f :text) (getf f :background))))
      (is (equal "#D0D0D0" (string-upcase (getf f :colour))))
      (is (< (getf f :ratio) 4.5d0)))))

(test a-gradient-whose-stops-pass-can-still-fail-between-them
  "#767676 passes on white and on black, and fails on the grey halfway between them, which
only the samples between the stops can find."
  (let ((failures (appr:appearance-contrast-failures
                   (appr:make-appearance-table
                    :light '(:surface-text "#767676"
                             :surface "#ffffff"
                             :gradient (:surface (:gradient "#ffffff" "#000000")))))))
    (is (>= (appr:contrast-ratio "#767676" "#ffffff") 4.5d0))
    (is (>= (appr:contrast-ratio "#767676" "#000000") 4.5d0))
    (is (equal '((:light :gradient :surface-text))
               (mapcar (lambda (f) (list (getf f :theme) (getf f :look) (getf f :text)))
                       failures)))))

(test a-plain-colour-in-the-gradient-look-replaces-bulma-s-background
  "An app may give a plain colour as a gradient-look value. The gradient look's rules set it with
`background:', because `background-image:' with a colour is invalid in a browser: Bulma's own
background would stay under the token's text colour, which the contrast check never saw."
  (let* ((table (appr:make-appearance-table
                 :light '(:gradient (:button-primary "#5b21b6" :button-primary-text "#ffffff"))))
         (css (appr:appearance-css table)))
    (is (search "--hy-button-primary: #5b21b6;" css) "the plain colour is not a token value")
    (is (search (format nil ".button.is-primary:not(.is-outlined):not(.is-light):not(.is-inverted) {~%  background: var(--hy-button-primary);") css))
    (is (null (search "background-image" css)) "a rule still sets background-image")
    (is (null (appr:appearance-contrast-failures table)))))
