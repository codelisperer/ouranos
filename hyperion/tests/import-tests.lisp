;;;; import-tests.lisp --- hyperion/import (HTML -> Spinneret).

(in-package #:hyperion/tests)

;; Suite name is HTML-IMPORT (not IMPORT -- that symbol is CL:IMPORT).
(def-suite html-import :description "HTML -> Spinneret conversion." :in hyperion)
(in-suite html-import)

(defun %forms (html &rest args)
  (apply #'imp:html->spinneret-forms html args))

(defun %read-all (string)
  "Every top-level form read from STRING."
  (with-input-from-string (s string)
    (loop for form = (read s nil :eof)
          until (eq form :eof) collect form)))

;;; --- elements, text, nesting ----------------------------------------------
(test element-with-text
  (is (equal '((:p "Hello")) (%forms "<p>Hello</p>"))))

(test nested-structure
  (is (equal '((:div :class "card"
                (:header :class "h" "T")
                (:p "body")))
             (%forms "<div class=\"card\"><header class=\"h\">T</header><p>body</p></div>"))))

(test multiple-top-level-nodes
  (is (equal '((:h1 "a") (:h2 "b")) (%forms "<h1>a</h1><h2>b</h2>"))))

;;; --- attributes -----------------------------------------------------------
(test attributes-normalized-class-id-first
  ;; class, then id, then the rest alphabetically (data-k < href).
  (is (equal '((:a :class "z" :id "y" :data-k "v" :href "/x" "go"))
             (%forms "<a href=\"/x\" id=\"y\" class=\"z\" data-k=\"v\">go</a>"))))

(test hx-attributes-become-keywords
  (is (equal '((:button :class "button is-primary" :hx-post "/ui/go" :hx-target "#main" "Send"))
             (%forms "<button class=\"button is-primary\" hx-post=\"/ui/go\" hx-target=\"#main\">Send</button>"))))

(test boolean-attribute-empty-value
  (is (equal '((:input :autofocus t :type "text"))
             (%forms "<input type=\"text\" autofocus>"))))

(test boolean-attribute-value-equals-name
  (is (equal '((:option :selected t "One"))
             (%forms "<option selected=\"selected\">One</option>"))))

;;; --- void / raw / doctype / comments --------------------------------------
(test void-element-has-no-children
  (is (equal '((:img :alt "x" :src "a.png")) (%forms "<img src=\"a.png\" alt=\"x\">"))))

(test script-content-is-raw-not-escaped
  ;; The angle brackets / ampersands must survive verbatim inside (:raw ...).
  (is (equal '((:script (:raw "if (a < b && c > 0) { x(); }")))
             (%forms "<script>if (a < b && c > 0) { x(); }</script>"))))

(test style-content-is-raw
  (is (equal '((:style (:raw ".x{color:red}"))) (%forms "<style>.x{color:red}</style>"))))

(test doctype
  (is (equal '((:doctype)) (%forms "<!DOCTYPE html>"))))

(test comments-dropped
  (is (equal '((:div "hi")) (%forms "<div><!-- a note -->hi</div>"))))

;;; --- whitespace -----------------------------------------------------------
(test collapse-drops-insignificant-whitespace
  (is (equal '((:ul (:li "a") (:li "b")))
             (%forms (format nil "<ul>~%  <li>a</li>~%  <li>b</li>~%</ul>")))))

(test collapse-runs-within-text
  (is (equal '((:p "a b c")) (%forms (format nil "<p>a   b~%  c</p>")))))

(test preserve-keeps-whitespace
  (is (equal '((:p " a ")) (%forms "<p> a </p>" :whitespace :preserve))))

;;; --- string output --------------------------------------------------------
(test html->spinneret-string-rereads-to-forms
  ;; The pasteable source must read back to exactly the forms it came from.
  (let ((html "<div class=\"box\"><button hx-post=\"/go\">Send</button></div>"))
    (is (equal (imp:html->spinneret-forms html)
               (%read-all (imp:html->spinneret html))))))

;;; --- round-trip through Spinneret -----------------------------------------
(test round-trips-through-spinneret
  ;; Converted forms, rendered by Spinneret, reproduce the salient markup.
  (let* ((forms (imp:html->spinneret-forms
                 "<div class=\"box\"><button hx-post=\"/ui/go\">Send</button><img src=\"/x.png\" alt=\"p\"></div>"))
         (out (eval `(spinneret:with-html-string ,@forms))))
    (is (search "hx-post=\"/ui/go\"" out))
    (is (search ">Send<" out))
    (is (search "/x.png" out))))
