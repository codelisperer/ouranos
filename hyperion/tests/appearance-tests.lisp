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
          (is (= 13 (/ (length flat) 2)) "six background tokens, six text tokens and the ring")
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
    ;; The header text fails, and so does the focus ring, which is also checked on the header.
    (is (equal '(:header-text :focus-ring) (mapcar (lambda (f) (getf f :text)) failures)))
    (let ((f (first failures)))
      (is (eql 4.5d0 (getf f :required)))
      (is (equal '(:dark :normal :gradient :header-text :header)
                 (list (getf f :theme) (getf f :contrast) (getf f :look)
                       (getf f :text) (getf f :background))))
      (is (equal "#D0D0D0" (string-upcase (getf f :colour))))
      (is (< (getf f :ratio) 4.5d0)))))

(test a-button-is-checked-on-hover-and-when-pressed-as-well-as-at-rest
  "White on #767676 passes at rest, at 4.54:1. The hover layer lightens the fill and pressing
dims the text, and each brings it below 4.5:1, which only a check of those states can find."
  (let* ((failures (appr:appearance-contrast-failures
                    (appr:make-appearance-table
                     :light '(:button-primary "#767676" :button-primary-text "#ffffff"))))
         (mine (remove-if-not (lambda (f) (and (eq :button-primary-text (getf f :text))
                                               (eq :light (getf f :theme))
                                               (eq :normal (getf f :contrast))
                                               (eq :flat (getf f :look))))
                              failures)))
    (is (equal '(:hover :pressed) (mapcar (lambda (f) (getf f :state)) mine)) "~S" mine)
    (is (every (lambda (f) (< (getf f :ratio) 4.5d0)) mine))
    (let ((css (appr:appearance-css)))
      (is (search (format nil "linear-gradient(~A, ~A)" appr::*hover-overlay* appr::*hover-overlay*)
                  css)
          "the generated hover rule draws the layer the check models")
      (is (search (format nil "filter: brightness(~,2F);" appr::*pressed-brightness*) css)
          "the generated press rule uses the brightness the check models"))))

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
    ;; The focus ring fails on the same grey; this test is about the text.
    (is (equal '((:light :gradient :surface-text))
               (mapcar (lambda (f) (list (getf f :theme) (getf f :look) (getf f :text)))
                       (remove :focus-ring failures :key (lambda (f) (getf f :text))))))))

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

;;; --- text roles, fonts and the focus ring (#981, comment 6462400814) -----------------

(test the-text-roles-and-fonts-are-written-once-on-the-bare-root-rule
  (let* ((css (appr:appearance-css))
         (root (subseq css 0 (search "}" css))))
    (loop for (role size) in '(("caps" "0.6875rem") ("meta" "0.75rem") ("dense" "0.8125rem")
                               ("body" "0.875rem") ("heading" "1rem") ("title" "1.25rem")
                               ("prose" "1.0625rem"))
          do (is (search (format nil "--hy-text-~A: ~A;" role size) root) "--hy-text-~A" role)
             (is (= 1 (%count-matches css (format nil "--hy-text-~A:" role)))
                 "--hy-text-~A is written more than once" role))
    (is (search "--hy-font-ui: system-ui," root))
    (is-true (let ((at (search "--hy-font-prose:" root)))
               (and at (search "serif;" root :start2 at)))
             "the prose font is not a serif")
    (is (null (search "--bulma-size" css)) "Bulma's sizes are Bulma's, not set here")))

(test an-app-changes-one-text-role-or-font-and-keeps-the-rest
  (let ((css (appr:appearance-css (appr:make-appearance-table
                                   :type-scale '(:body "1rem")
                                   :fonts '(:prose "\"Literata\", serif")))))
    (is (search "--hy-text-body: 1rem;" css))
    (is (search "--hy-text-title: 1.25rem;" css))
    (is (search "--hy-font-prose: \"Literata\", serif;" css))
    (is (search "--hy-font-ui: system-ui," css)))
  (signals error (appr:make-appearance-table :type-scale '(:huge "3rem")))
  (signals error (appr:make-appearance-table :type-scale '(:body 14)))
  (signals error (appr:make-appearance-table :fonts '(:ui "Arial; } body { display: none")))
  ;; A line break of either kind would end the declaration it is written into. The value holds
  ;; nothing else that is refused, so only the line break can be what signals.
  (dolist (break (list #\Newline #\Return))
    (signals error (appr:make-appearance-table
                    :fonts (list :ui (format nil "Arial~Csans-serif" break)))))
  (signals error (appr:make-appearance-table :fonts '(:mono "monospace"))))

(test the-focus-ring-is-defined-in-every-combination
  (let ((table (appr:make-appearance-table))
        (css (appr:appearance-css)))
    (dolist (theme '(:light :dark))
      (dolist (contrast '(:normal :high))
        (dolist (look '(:flat :gradient))
          (is (stringp (getf (appr:token-values table theme contrast look) :focus-ring))
              "~A ~A ~A has no focus ring colour" theme contrast look))))
    (is (= (%count-matches css "--hy-surface:") (%count-matches css "--hy-focus-ring:"))
        "a rule that sets the surface does not set the focus ring")))

(test the-focus-ring-is-checked-at-three-to-one-against-every-surface
  "A ring colour between 3:1 and 4.5:1 on every light surface passes, which shows the ring is
held to 3:1 and not to the text's 4.5:1. One below 3:1 on any surface fails, on each surface it
fails on."
  (let* ((between "#7a7a7a")
         (surfaces (loop for token in appr:*ring-backgrounds*
                         append (appr:background-samples
                                 (getf (appr:token-values (appr:make-appearance-table)
                                                          :light :normal :gradient)
                                       token))))
         (ratios (mapcar (lambda (c) (appr:contrast-ratio between c)) surfaces)))
    (is-true (and (every (lambda (r) (>= r 3d0)) ratios) (some (lambda (r) (< r 4.5d0)) ratios))
             "the test's own colour is not between 3:1 and 4.5:1: ~S" ratios)
    (is (null (appr:appearance-contrast-failures
               (appr:make-appearance-table :light (list :focus-ring between)))))
    (let ((failures (appr:appearance-contrast-failures
                     (appr:make-appearance-table :light '(:focus-ring "#d8dbe0")))))
      (is (equal '(:surface :surface-raised :header :surface :surface-raised :header)
                 (mapcar (lambda (f) (getf f :background)) failures))
          "~S" failures)
      (is-true (every (lambda (f) (and (eq :focus-ring (getf f :text))
                                       (eql 3d0 (getf f :required))))
                      failures))))
  (signals error (appr:make-appearance-table :light '(:focus-ring (:gradient "#000000" "#111111"))))
  (signals error (appr:make-appearance-table
                  :light '(:gradient (:focus-ring (:gradient "#000000" "#111111"))))))

(test gradient-buttons-have-hover-press-and-focus-rules
  "The gradient look's `background:' on a button replaces the colour Bulma changes on hover, so
the look gives hover, press and focus itself. Hover draws a grey layer over the token, which
works whether the token is a colour or a gradient; focus draws the focus ring."
  (let ((css (appr:appearance-css)))
    (dolist (token '("button-primary" "button-danger"))
      (let ((scope (format nil ":root[data-look=\"gradient\"] .button.is-~A:not(.is-outlined):not(.is-light):not(.is-inverted)"
                           (subseq token 7))))
        (is (search (format nil "~A:hover {~%  background: linear-gradient(rgba(128, 128, 128, 0.14), rgba(128, 128, 128, 0.14)), var(--hy-~A);"
                            scope token)
                    css)
            "~A has no hover over its token" token)
        (is (search (format nil "~A:active {" scope) css))
        (is (search (format nil "~A:focus-visible {~%  outline: 2px solid var(--hy-focus-ring);" scope)
                    css)
            "~A has no focus ring" token)))
    (is (null (search ".navbar:hover" css)) "only buttons get hover rules")))
