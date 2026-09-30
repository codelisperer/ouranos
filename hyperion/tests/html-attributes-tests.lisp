;;;; html-attributes-tests.lisp --- valid HTML Spinneret does not know compiles without a WARNING (#439)
;;;;
;;;; Spinneret checks attribute names while it macroexpands a template, and warns with a full
;;;; WARNING on one it does not know. That fails an ASDF build and, under hyperion/dev, the
;;;; reload of the whole file. `autocomplete' is valid on <textarea> and Spinneret rejects it
;;;; there, so hyperion/html exempts it. The templates are compiled here, at run time, so the
;;;; check runs inside the test rather than when this file was built.

(in-package #:hyperion/tests)

(def-suite html-attributes :description "Spinneret's attribute check and hyperion's exemptions." :in hyperion)
(in-suite html-attributes)

(defun %full-warnings-compiling (template)
  "The full WARNINGs (not STYLE-WARNINGs) signalled while compiling a function that renders
TEMPLATE, a Spinneret form, as their printed text."
  (let ((warnings '()))
    (handler-bind ((warning (lambda (w)
                              (unless (typep w 'style-warning)
                                (push (princ-to-string w) warnings))
                              (muffle-warning w))))
      (let ((*error-output* (make-broadcast-stream)))
        (compile nil `(lambda () (spinneret:with-html-string ,template)))))
    warnings))

(test autocomplete-on-a-textarea-compiles-without-a-warning
  (is (null (%full-warnings-compiling '(:textarea :name "in" :autocomplete "off")))))

(test without-the-exemption-autocomplete-on-a-textarea-warns
  "The control: the refusal the exemption removes is Spinneret's, and it is a full WARNING."
  (let ((spinneret:*unvalidated-attribute-prefixes*
          (remove "autocomplete" spinneret:*unvalidated-attribute-prefixes* :test #'string-equal)))
    (is (plusp (length (%full-warnings-compiling '(:textarea :name "in" :autocomplete "off")))))))

(test an-attribute-that-is-not-html-still-warns
  "The exemption is one attribute, not the validation switched off."
  (is (plusp (length (%full-warnings-compiling '(:textarea :name "in" :not-an-html-attribute "x"))))))
