;;;; markdown.lisp --- Markdown -> HTML rendering.
;;;;
;;;; Wraps 3bmd. SAFE by default: raw HTML in the Markdown source is not passed through,
;;;; so user-authored / untrusted content can't inject markup or scripts -- one concrete
;;;; instance of the framework's XSS-prevention posture (output is escaped unless explicitly
;;;; trusted). Pass :allow-html t only for content you trust. Fenced code blocks are
;;;; supported.
;;;;
;;;; HOW THE SAFE MODE WORKS (#559). Every `<' and `>' in the source is replaced by a
;;;; placeholder character before 3bmd parses it, so the parser finds no raw HTML, no HTML
;;;; block and no autolink: each of those needs a real `<'. After parsing, the placeholders
;;;; are turned back into `<' and `>' in the document, and 3bmd's printer escapes them once,
;;;; with the rest of the text. Until #559 the source was escaped to `&lt;' and `&gt;'
;;;; instead, and the printer escaped code spans, indented code and colourised fenced blocks
;;;; a second time, so `(< a b)' in inline code reached the reader as `(&lt; a b)'. `&' is
;;;; left as written, so an entity such as `&amp;' or `&copy;' renders as its character;
;;;; 3bmd's grammar reads an entity only as `&' followed by letters or digits and `;'.
;;;;
;;;; LINK AND IMAGE URLS ARE CHECKED AND ESCAPED HERE, NOT BY 3BMD (#66). Escaping the
;;;; source stops raw HTML, but a Markdown link is not raw HTML: `[x](javascript:...)'
;;;; became `<a href="javascript:...">', and 3bmd writes a URL into its attribute with no
;;;; escaping at all, so `[x](http://a"onmouseover="...)' closed the attribute and added
;;;; an event handler. Both were measured on main before this change. So the document is
;;;; parsed, every link, image and reference definition is rewritten, and only then
;;;; printed: see %SAFE-URL for the rule.

(in-package #:hyperion/markdown)

(defun escape-html (string)
  "Escape &, <, > in STRING for safe use as HTML text content."
  (with-output-to-string (out)
    (loop for c across string
          do (case c
               (#\& (write-string "&amp;" out))
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (t   (write-char c out))))))

;;; --- URLs ---------------------------------------------------------------------

(defparameter +allowed-schemes+ '("http" "https" "mailto")
  "The only URL schemes a rendered link or image may use. Deliberately short: a scheme not
listed is refused, so a scheme nobody thought about is refused too. A URL with no scheme
at all (relative, or `//host/path') is allowed.")

(defparameter +named-references+
  '(("amp" . #\&) ("lt" . #\<) ("gt" . #\>) ("quot" . #\") ("apos" . #\')
    ("colon" . #\:) ("sol" . #\/) ("period" . #\.) ("comma" . #\,) ("num" . #\#)
    ("quest" . #\?) ("equals" . #\=) ("lpar" . #\() ("rpar" . #\))
    ("Tab" . #\Tab) ("NewLine" . #\Newline) ("nbsp" . #\No-break_space))
  "The named character references decoded before a URL is checked. A browser knows many
more, but only these can spell a scheme, its separator or the whitespace a browser ignores
inside one.")

(defun %decode-references (string)
  "STRING with HTML character references decoded, as a browser decodes an attribute value:
decimal (&#106;) and hex (&#x6A;) references with or without the closing semicolon, and the
named ones in +NAMED-REFERENCES+ with it. Anything else is left as written."
  (with-output-to-string (out)
    (let ((i 0) (n (length string)))
      (loop while (< i n)
            do (let ((c (char string i)))
                 (if (char/= c #\&)
                     (progn (write-char c out) (incf i))
                     (let ((decoded nil) (next i))
                       (cond
                         ;; Numeric: &#123 or &#x7B, the semicolon optional.
                         ((and (< (1+ i) n) (char= (char string (1+ i)) #\#))
                          (let* ((hex (and (< (+ i 2) n) (char-equal (char string (+ i 2)) #\x)))
                                 (start (+ i (if hex 3 2)))
                                 (end start))
                            (loop while (and (< end n) (digit-char-p (char string end) (if hex 16 10)))
                                  do (incf end))
                            (when (> end start)
                              (let ((code (parse-integer string :start start :end end
                                                                :radix (if hex 16 10))))
                                (setf decoded (if (< code char-code-limit) (code-char code) #\?)
                                      next (if (and (< end n) (char= (char string end) #\;))
                                               (1+ end) end))))))
                         ;; Named: &colon; and friends, the semicolon required.
                         (t
                          (let ((semi (position #\; string :start i)))
                            (when semi
                              (let ((hit (assoc (subseq string (1+ i) semi) +named-references+
                                                :test #'string=)))
                                (when hit (setf decoded (cdr hit) next (1+ semi))))))))
                       (if decoded
                           (progn (write-char decoded out) (setf i next))
                           (progn (write-char c out) (incf i))))))))))

(defun %url-scheme (url)
  "The scheme of URL, lowercased, or NIL if it has none. URL is already decoded. Control
characters and spaces are dropped first, as a browser drops tab, CR and LF inside a URL and
trims the rest from its ends, so `java<TAB>script:' is read as `javascript:'. A URL has a
scheme only when a colon comes before the first slash, question mark or hash."
  (let* ((compact (remove-if (lambda (c) (<= (char-code c) 32)) url))
         (colon (position #\: compact))
         (stop (position-if (lambda (c) (member c '(#\/ #\? #\#))) compact)))
    (when (and colon (or (null stop) (< colon stop)))
      (string-downcase (subseq compact 0 colon)))))

(defun %escape-attribute (string)
  "STRING escaped for a double-quoted HTML attribute."
  (with-output-to-string (out)
    (loop for c across string
          do (case c
               (#\& (write-string "&amp;" out))
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (#\" (write-string "&quot;" out))
               (#\' (write-string "&#39;" out))
               (t   (write-char c out))))))

(defun %safe-url (source)
  "SOURCE ready to be written into an href or src attribute, or NIL if it must not be.

The check is on the URL as the browser will read it: references decoded, and control
characters and spaces ignored in the scheme. A scheme other than those in
+ALLOWED-SCHEMES+ is refused. An allowed URL is returned decoded and then re-escaped for
the attribute, so a quote cannot end the attribute and an entity cannot be re-formed after
the check."
  (when (stringp source)
    (let* ((decoded (string-trim '(#\Space #\Tab #\Newline #\Return #\Page)
                                 (%decode-references source)))
           (scheme (%url-scheme decoded)))
      (when (or (null scheme) (member scheme +allowed-schemes+ :test #'string=))
        (%escape-attribute decoded)))))

;;; --- the document ---------------------------------------------------------------

(defun %references (doc)
  "Reference definitions in DOC, by label, keyed as 3bmd keys them for lookup."
  (let ((table (make-hash-table :test #'equalp)))
    (dolist (node doc table)
      (when (and (consp node) (eq (car node) :reference))
        (setf (gethash (3bmd::print-label-to-string (getf (cdr node) :label)) table)
              (getf (cdr node) :source))))))

(defun %sanitize (elements references)
  "ELEMENTS (a list of 3bmd document nodes and strings) with every link, image and
reference definition made safe. A link or reference link whose URL %SAFE-URL refuses is
replaced by its label, and an image by its alt text, so the words stay and the URL goes."
  (loop for e in elements
        nconc (if (and (consp e) (keywordp (car e)))
                  (%sanitize-node e references)
                  (list (if (consp e) (%sanitize e references) e)))))

(defun %sanitize-node (node references)
  "A list of nodes to put in place of NODE. See %SANITIZE."
  (let ((tag (car node)) (rest (cdr node)))
    (case tag
      (:explicit-link
       (let ((label (%sanitize (getf rest :label) references))
             (url (%safe-url (getf rest :source))))
         (if url
             (list (list* :explicit-link :label label :source url
                          (loop for (k v) on rest by #'cddr
                                unless (member k '(:label :source)) nconc (list k v))))
             label)))
      (:image
       ;; (:image (:explicit-link :label ... :source ... :title ...))
       (let* ((link (cdr (first rest)))
              (label (%sanitize (getf link :label) references))
              (url (%safe-url (getf link :source))))
         (if url
             (list (list :image (list* :explicit-link :label label :source url
                                       (loop for (k v) on link by #'cddr
                                             unless (member k '(:label :source))
                                               nconc (list k v)))))
             label)))
      (:reference-link
       (let* ((label (getf rest :label))
              (key (3bmd::print-label-to-string (or (getf rest :definition) label)))
              (source (gethash key references)))
         (if (and source (%safe-url source))
             (list node)
             ;; Refused, or undefined: the label as text. An undefined one would have
             ;; printed as text anyway, with a warning.
             (%sanitize label references))))
      (:reference
       (let ((url (%safe-url (getf rest :source))))
         (list (list* :reference :source (or url "")
                      (loop for (k v) on rest by #'cddr
                            unless (eq k :source) nconc (list k v))))))
      (:link
       ;; An autolink, <http://...>: its text is the URL.
       (let ((url (%safe-url (first rest))))
         (if url (list (list :link url)) (list (first rest)))))
      (t (list (cons tag (%sanitize rest references)))))))

(defparameter +less-than+ (code-char #xFDD0)
  "Stands for `<' in the source while 3bmd parses it in the safe mode. A Unicode
noncharacter, so text does not use it; any found in the source is replaced first.")

(defparameter +greater-than+ (code-char #xFDD1)
  "Stands for `>' in the source while 3bmd parses it in the safe mode.")

(defun %quote-markers (markdown)
  "The positions in MARKDOWN of each `>' that marks a block quote: at the start of a line after
up to three spaces, and again after such a marker, its optional space and up to three more
spaces, for a nested quote (#574)."
  (let ((n (length markdown))
        (markers '()))
    (flet ((skip-spaces (i most)
             (loop while (and (< i n) (< 0 most) (char= #\Space (char markdown i)))
                   do (incf i) (decf most))
             i))
      (loop with line = 0
            while (< line n)
            do (loop with i = (skip-spaces line 3)
                     while (and (< i n) (char= #\> (char markdown i)))
                     do (push i markers)
                        (setf i (skip-spaces (1+ i) 4)))
               (setf line (let ((newline (position #\Newline markdown :start line)))
                            (if newline (1+ newline) n)))))
    (nreverse markers)))

(defun %hide-brackets (markdown)
  "MARKDOWN with each < and > replaced by its placeholder, and each placeholder character
already in it replaced by U+FFFD, so that only this function's placeholders become brackets. A
`>' that marks a block quote is left for 3bmd to read (#574). It cannot form HTML, because every
`<' is hidden, and 3bmd escapes a `>' wherever it prints one as text or code."
  (let ((markers (%quote-markers markdown)))
    (with-output-to-string (out)
      (loop for c across markdown
            for i from 0
            do (write-char (cond ((and markers (= i (first markers))) (pop markers) c)
                                 ((char= c #\<) +less-than+)
                                 ((char= c #\>) +greater-than+)
                                 ((or (char= c +less-than+) (char= c +greater-than+))
                                  (code-char #xFFFD))
                                 (t c))
                           out)))))

(defun %restore-brackets (string)
  (substitute #\> +greater-than+ (substitute #\< +less-than+ string)))

(defun %language-name-p (lang)
  "Whether LANG, a fenced block's info string, is a language name: letters, digits and
+ - _ . # only, and not empty. 3bmd writes a fenced block's language into a class attribute
without escaping it under some renderers, so any other info string is dropped (#559)."
  (and (stringp lang) (plusp (length lang))
       (every (lambda (c) (or (alphanumericp c) (find c "+-_.#"))) lang)))

(defun %escaping-renderer-p (lang)
  "Whether the current 3bmd code-block renderer escapes `&' in a fenced block named LANG.
:NOHIGHLIGHT does not: it uses 3bmd's ESCAPE-PRE-STRING, which escapes only < and >. :COLORIZE
escapes a block it colours, and sends any other block through ESCAPE-PRE-STRING. :PYGMENTS and
:CHROMA hand the code to an external program that writes escaped HTML, so they do. A renderer an
app defines is assumed to escape its output, as those two do. This follows RENDER-CODE-BLOCK's
own choice, and the markdown suite checks each case."
  (case 3bmd-code-blocks::*renderer*
    (:nohighlight nil)
    (:colorize (and (or (and lang (3bmd-code-blocks::find-coloring-type lang))
                        (and (zerop (length (or lang "")))
                             3bmd-code-blocks:*code-blocks-default-colorize*))
                    t))
    (t t)))

(defun %restore-code-block (rest)
  "A fenced block's plist REST with its brackets restored, its language dropped unless it is a
language name, and its content escaped for `&' when the renderer will not do that itself."
  (let* ((lang (let ((l (getf rest :lang)))
                 (and l (%language-name-p (%restore-brackets l)) (%restore-brackets l))))
         (content (getf rest :content))
         (content (and content
                       (%restore-brackets
                        (if (%escaping-renderer-p lang)
                            content
                            (with-output-to-string (out)
                              (loop for c across content
                                    do (if (char= c #\&)
                                           (write-string "&amp;" out)
                                           (write-char c out)))))))))
    (list* :lang lang :content content
           (loop for (k v) on rest by #'cddr
                 unless (member k '(:lang :content))
                   nconc (list k (if (stringp v) (%restore-brackets v) v))))))

(defun %restore (tree)
  "TREE, a 3bmd document or part of one, with the safe mode's placeholders turned back into
< and >. 3bmd's printer escapes them, with all other text."
  (cond ((stringp tree) (%restore-brackets tree))
        ((and (consp tree) (eq (car tree) '3bmd-code-blocks::code-block))
         (cons (car tree) (%restore-code-block (cdr tree))))
        ((consp tree) (cons (%restore (car tree)) (%restore (cdr tree))))
        (t tree)))

(defun render (markdown &key allow-html)
  "Render MARKDOWN (a string) to an HTML string. SAFE by default: raw HTML in the
source is shown as text (suitable for user/untrusted content), and the text of code spans
and code blocks is escaped once (#559). ALLOW-HTML t passes raw HTML through -- trusted
content only. Returns \"\" for NIL/empty input.

Link and image URLs are checked in both modes (#66). Only http, https and mailto are
allowed, plus URLs with no scheme (relative, or `//host/path'); the list is deliberately
short. The check reads the URL as a browser will: character references decoded, and tabs,
newlines and other control characters inside the scheme ignored, so `jav&#x61;script:' and
`java<TAB>script:' are both refused. A refused link renders as its text with no href, and a
refused image as its alt text. An allowed URL is written into its attribute escaped, which
3bmd does not do itself."
  (if (and markdown (plusp (length markdown)))
      (let ((3bmd-code-blocks:*code-blocks* t)
            ;; NIL in the safe mode: each of these makes 3bmd print some text without escaping
            ;; it, which the safe mode's escaping relies on not happening (#559). :ALLOW-HTML T
            ;; keeps the app's values, as it did before #559.
            (3bmd:*smart-quotes* (and allow-html 3bmd:*smart-quotes*))
            (3bmd:*generate-header-ids* (and allow-html 3bmd:*generate-header-ids*))
            (3bmd-code-blocks:*render-code-spans*
              (and allow-html 3bmd-code-blocks:*render-code-spans*))
            ;; Emit plain <pre><code> (no server-side colorize) -- avoids the
            ;; colorize/HyperSpec console noise; client-side highlighting can be
            ;; layered on later if wanted.
            (3bmd-code-blocks:*code-blocks-default-colorize* nil))
        (let* ((source (if allow-html markdown (%hide-brackets markdown)))
               ;; What 3BMD:PARSE-STRING-AND-PRINT-TO-STREAM does, split in two so the
               ;; document can be rewritten between parsing and printing.
               (parsed (3bmd-grammar::parse-doc (3bmd::expand-tabs source :add-newlines t)))
               (doc (if allow-html parsed (%restore parsed))))
          (with-output-to-string (out)
            (3bmd:print-doc-to-stream (%sanitize doc (%references doc)) out))))
      ""))
