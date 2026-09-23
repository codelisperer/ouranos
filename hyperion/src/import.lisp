;;;; import.lisp --- convert HTML snippets to Spinneret s-expressions.
;;;;
;;;; A dev-time porting aid: paste HTML that was written for HTML proper (a Bulma
;;;; template, a component from a CSS kit) and get Spinneret code to drop into a
;;;; `spinneret:with-html`. Parses with Plump (lenient -- handles real-world markup),
;;;; walks the DOM, and emits forms:
;;;;   <div class="box">      -> (:div :class "box" ...)
;;;;   <button hx-post="/x">  -> (:button :hx-post "/x" ...)
;;;;   text nodes             -> "strings" (insignificant whitespace dropped)
;;;;   <script>/<style>       -> (:script (:raw "...")) -- never escaped
;;;;   <!doctype html>        -> (:doctype)
;;;;   <!-- comments -->      -> dropped
;;;; Standalone (Plump only) so converting a snippet doesn't load the whole
;;;; framework. Not a runtime dependency; a tool. See docs/user-guide.md.
;;;;
;;;; Limitations (v1): attribute ORDER is normalized (class/id first, then sorted);
;;;; exotic attribute names (@click, :class, hx-on:click -- Alpine/Vue) emit as
;;;; escaped keywords and may need a hand touch-up; the output is a faithful starting
;;;; point, not a style-perfect hand-transcription.

(cl:defpackage #:hyperion/import
  (:use #:cl)
  (:documentation
   "Convert HTML snippets to Spinneret s-expressions (a porting aid). HTML->SPINNERET
    returns pasteable source; HTML->SPINNERET-FORMS returns the raw forms.")
  (:export #:html->spinneret #:html->spinneret-forms))

(in-package #:hyperion/import)

(defparameter *void-elements*
  '("area" "base" "br" "col" "embed" "hr" "img" "input" "link" "meta"
    "param" "source" "track" "wbr")
  "HTML void elements: no children, no close tag.")

(defparameter *raw-text-elements* '("script" "style")
  "Elements whose text content must NOT be HTML-escaped -> wrapped in (:raw ...).")

(defun %kw (name)
  (intern (string-upcase name) :keyword))

(defun %ws-char-p (ch)
  (member ch '(#\Space #\Tab #\Newline #\Return #\Page)))

(defun %blank-ws-p (s)
  (every #'%ws-char-p s))

(defun %collapse-ws (s)
  "Collapse runs of whitespace in S to a single space (preserving one leading/trailing
space if present, since it can be significant between inline elements)."
  (with-output-to-string (out)
    (let ((prev-space nil))
      (loop for ch across s do
        (cond ((%ws-char-p ch)
               (unless prev-space (write-char #\Space out) (setf prev-space t)))
              (t (write-char ch out) (setf prev-space nil)))))))

(defun %attrs->plist (element)
  "Plump attributes of ELEMENT -> a plist (:keyword value ...), class/id first then
alphabetical. A boolean attribute (empty value, or value = name) becomes :key T."
  (let ((pairs '()))
    (maphash (lambda (name value) (push (cons name value) pairs))
             (plump:attributes element))
    (setf pairs
          (stable-sort pairs
                       (lambda (a b)
                         (flet ((rank (n) (cond ((string-equal n "class") 0)
                                                ((string-equal n "id") 1)
                                                (t 2))))
                           (let ((ra (rank (car a))) (rb (rank (car b))))
                             (if (= ra rb) (string-lessp (car a) (car b)) (< ra rb)))))))
    (loop for (name . value) in pairs
          append (list (%kw name)
                       (if (or (string= value "") (string-equal value name))
                           t                    ; boolean attribute
                           value)))))

(defun %fulltext (element)
  "The raw concatenated text under a script/style ELEMENT."
  (with-output-to-string (s)
    (loop for c across (plump:children element)
          when (plump:text-node-p c) do (write-string (plump:text c) s))))

(defun %node->form (node ws)
  "Convert a Plump NODE to a Spinneret form, or NIL to drop it (blank text, comment)."
  (cond
    ((plump:element-p node)
     (let ((tag (plump:tag-name node)))
       (cond
         ((member tag *raw-text-elements* :test #'string-equal)
          (let ((text (%fulltext node)))
            (append (list* (%kw tag) (%attrs->plist node))
                    (when (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return) text)))
                      (list (list :raw text))))))
         ((member tag *void-elements* :test #'string-equal)
          (list* (%kw tag) (%attrs->plist node)))
         (t (append (list* (%kw tag) (%attrs->plist node))
                    (%children->forms node ws))))))
    ((plump:text-node-p node)
     (let ((text (plump:text node)))
       (if (eq ws :preserve)
           (and (plusp (length text)) text)
           (unless (%blank-ws-p text)
             (let ((c (%collapse-ws text)))
               (and (plusp (length c)) c))))))
    ((plump:doctype-p node) '(:doctype))
    (t nil)))

(defun %children->forms (node ws)
  (loop for c across (plump:children node)
        for form = (%node->form c ws)
        when form collect form))

(defun html->spinneret-forms (html &key (whitespace :collapse))
  "Parse HTML (a string) and return a LIST of Spinneret forms, one per top-level node.
WHITESPACE is :collapse (drop insignificant whitespace, the default) or :preserve."
  (check-type html string)
  (loop for c across (plump:children (plump:parse html))
        for form = (%node->form c whitespace)
        when form collect form))

(defun html->spinneret (html &key (whitespace :collapse))
  "Convert HTML (a string) to Spinneret source CODE (a string) to paste into a
`spinneret:with-html`. Pretty-printed and lowercase; multiple top-level nodes become
sibling forms. See HTML->SPINNERET-FORMS for the raw forms."
  (let ((forms (html->spinneret-forms html :whitespace whitespace))
        (*print-case* :downcase)
        (*print-right-margin* 90)
        (*print-pretty* t)
        (*print-readably* nil))
    (with-output-to-string (out)
      (loop for form in forms
            for firstp = t then nil
            do (unless firstp (terpri out))
               (prin1 form out)
               (terpri out)))))
