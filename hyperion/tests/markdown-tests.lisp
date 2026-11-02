;;;; markdown-tests.lisp --- link and image URLs in rendered Markdown (#66).
;;;;
;;;; hyperion/markdown:render renders chat messages and site content, some of it written by
;;;; someone other than the reader. Raw HTML was already escaped, but a Markdown link is not
;;;; raw HTML: before #66's fix `[x](javascript:alert(1))' rendered as a working
;;;; javascript: link, and a double quote in an ordinary URL closed the href attribute.
;;;; These tests run both directions: URLs that must be refused, and URLs that must still
;;;; render as links and images.

(in-package #:hyperion/tests)

(def-suite markdown :description "Link and image URLs in rendered Markdown (#66)." :in hyperion)
(in-suite markdown)

(defun %attribute-values (html attribute)
  "Every value of ATTRIBUTE (\"href\" or \"src\") in HTML, as written in the markup."
  (let ((needle (format nil "~A=\"" attribute)) (found '()) (start 0))
    (loop for at = (search needle html :start2 start)
          while at
          do (let* ((from (+ at (length needle)))
                    (to (position #\" html :start from)))
               (push (subseq html from to) found)
               (setf start to)))
    (nreverse found)))

(defparameter +test-named-references+
  '(("&amp;" . #\&) ("&colon;" . #\:) ("&Tab;" . #\Tab) ("&NewLine;" . #\Newline)))

(defun %browser-decode (value)
  "VALUE with the character references a browser decodes in an attribute: decimal and hex,
with or without the semicolon, and the few named ones above. Written separately from the
renderer's decoder, so the two can disagree."
  (with-output-to-string (o)
    (let ((i 0) (n (length value)))
      (loop while (< i n)
            do (let ((named (and (char= (char value i) #\&)
                                 (find-if (lambda (pair)
                                            (let ((name (car pair)))
                                              (and (<= (+ i (length name)) n)
                                                   (string= name value :start2 i
                                                                       :end2 (+ i (length name))))))
                                          +test-named-references+))))
                 (cond
                   (named (write-char (cdr named) o) (incf i (length (car named))))
                   ((and (char= (char value i) #\&) (< (1+ i) n) (char= (char value (1+ i)) #\#))
                    (let* ((hex (and (< (+ i 2) n) (char-equal (char value (+ i 2)) #\x)))
                           (s (+ i (if hex 3 2)))
                           (e (or (position-if-not (lambda (c) (digit-char-p c (if hex 16 10)))
                                                   value :start s)
                                  n)))
                      (if (> e s)
                          (progn
                            (write-char (code-char (parse-integer value :start s :end e
                                                                        :radix (if hex 16 10)))
                                        o)
                            (setf i (if (and (< e n) (char= (char value e) #\;)) (1+ e) e)))
                          (progn (write-char #\& o) (incf i)))))
                   (t (write-char (char value i) o) (incf i))))))))

(defun %browser-scheme (value)
  "The scheme a browser would take from attribute VALUE, lowercased, or NIL if none."
  (let* ((compact (remove-if (lambda (c) (<= (char-code c) 32)) (%browser-decode value)))
         (colon (position #\: compact))
         (stop (position-if (lambda (c) (find c "/?#")) compact)))
    (when (and colon (or (null stop) (< colon stop)))
      (string-downcase (subseq compact 0 colon)))))

(defun %no-script-url-p (html)
  "True if no href or src in HTML would reach a scheme other than http, https or mailto."
  (every (lambda (v) (member (%browser-scheme v) '(nil "http" "https" "mailto") :test #'equal))
         (append (%attribute-values html "href") (%attribute-values html "src"))))

(defparameter +refused-links+
  (list "[click](javascript:alert(1))"
        "[click](JaVaScRiPt:alert(1))"
        "[click]( javascript:alert(1))"
        "[click](data:text/html,x)"
        "[click](vbscript:msgbox(1))"
        (format nil "[r][1]~%~%[1]: javascript:alert(1)"))
  "Links that must render without an href, in the default (untrusted) mode.")

(defparameter +refused-trusted-links+
  (list "[e](&#106;avascript:alert(1))"
        "[e](&#x6A;avascript:alert(1))"
        "[e](&#106avascript:alert(1))"
        "[e](javascript&colon;alert(1))"
        "[e](java&Tab;script:alert(1))"
        "[e](java&NewLine;script:alert(1))")
  "Links spelled with character references. They matter under :ALLOW-HTML T, where the
source is not escaped first, so a browser would decode them into a javascript: URL.")

(test script-urls-are-refused-in-links
  (dolist (src +refused-links+)
    (let ((html (md:render src)))
      (is (null (%attribute-values html "href")) "~S rendered an href: ~S" src html)
      (is (%no-script-url-p html) "~S reached a script URL: ~S" src html))))

(test script-urls-are-refused-in-images
  (let ((html (md:render "![a picture](javascript:alert(1))")))
    (is (null (%attribute-values html "src")) "an image kept its src: ~S" html)
    (is (search "a picture" html) "a refused image must leave its alt text: ~S" html)))

(test a-refused-link-keeps-its-words
  (let ((html (md:render "see [the docs](javascript:alert(1)) here")))
    (is (search "the docs" html) "the label must stay: ~S" html)
    (is (null (search "javascript" html)) "the URL must go: ~S" html)))

(test references-spelling-a-script-url-are-refused-in-both-modes
  "Under :allow-html t the source is not escaped, so the check has to decode character
references the way a browser does."
  (dolist (src +refused-trusted-links+)
    (let ((html (md:render src :allow-html t)))
      (is (%no-script-url-p html) "~S reached a script URL in trusted mode: ~S" src html)))
  (dolist (src +refused-trusted-links+)
    (let ((html (md:render src)))
      (is (%no-script-url-p html) "~S reached a script URL in the default mode: ~S" src html))))

(test a-quote-in-a-url-cannot-close-the-attribute
  "3bmd writes a URL into its attribute unescaped, so a double quote used to end the href
and let the rest of the URL become new attributes."
  (let ((html (md:render "[q](http://a\"onmouseover=\"alert(1))")))
    (is (null (search "\"onmouseover" html)) "the quote closed the attribute: ~S" html)
    (is (search "&quot;" html) "the quote must be escaped: ~S" html)))

(test ordinary-urls-still-render
  "The positive controls: a filter that refused every URL would pass every test above."
  (dolist (case '(("[a](https://example.com/a?b=1&c=2)" "https://example.com/a?b=1&amp;c=2")
                  ("[a](http://example.com)" "http://example.com")
                  ("[a](mailto:someone@example.com)" "mailto:someone@example.com")
                  ("[a](/docs/page#part)" "/docs/page#part")
                  ("[a](page.html)" "page.html")
                  ("[a](//example.com/path)" "//example.com/path")))
    (destructuring-bind (src want) case
      (is (equal (list want) (%attribute-values (md:render src) "href"))
          "~S should link to ~S: ~S" src want (md:render src))))
  (is (equal '("https://example.com/i.png")
             (%attribute-values (md:render "![p](https://example.com/i.png)") "src")))
  (is (equal '("https://example.com")
             (%attribute-values (md:render (format nil "[r][1]~%~%[1]: https://example.com"))
                                "href"))))

;;; --- code and entities are escaped once (#559) ----------------------------------------------
;;;
;;; Until #559 the safe mode escaped the whole source before 3bmd parsed it, and 3bmd escaped
;;; code spans, indented code and colourised fenced blocks again, so the reader saw `&lt;' where
;;; the author wrote `<'. Each case is checked in both modes, with <, > and & in it.

(defun %safe-and-trusted (src)
  (list (md:render src) (md:render src :allow-html t)))

(test an-inline-code-span-is-escaped-once
  (dolist (html (%safe-and-trusted "Use `(< a b) & (> c d)` here."))
    (is (search "<code>(&lt; a b) &amp; (&gt; c d)</code>" html) "got ~S" html)))

(test an-inline-code-span-is-plain-code-when-the-app-turned-on-code-span-colouring
  "With 3bmd's *RENDER-CODE-SPANS* true, 3bmd sends a code span to the code-block renderer, which
under :nohighlight prints it unescaped. The safe mode binds it to NIL, so a span stays <code>.
:ALLOW-HTML T keeps the app's value, as before #559, and so prints the span as 3bmd does."
  (let ((3bmd-code-blocks:*render-code-spans* t)
        (3bmd-code-blocks:*render-code-spans-lang* :common-lisp)
        (3bmd-code-blocks:*renderer* :nohighlight))
    (let ((safe (md:render "Use `(< a b) & (> c d)` here."))
          (trusted (md:render "Use `(< a b) & (> c d)` here." :allow-html t)))
      (is (search "<p>Use <code>(&lt; a b) &amp; (&gt; c d)</code> here.</p>" safe) "got ~S" safe)
      (is (search "<code>(< a b) & (> c d)</code>" trusted) "got ~S" trusted))))

(test the-safe-mode-turns-off-3bmd-settings-that-print-unescaped-text-and-trusted-keeps-them
  "Smart quotes and generated header ids make 3bmd print text it does not escape, so the safe mode
turns them off. :ALLOW-HTML T keeps the app's values, as it did before #559."
  (let ((3bmd:*generate-header-ids* t)
        (3bmd:*smart-quotes* t)
        (src (format nil "# A head~%~%\"quoted\" text~%")))
    (let ((safe (md:render src))
          (trusted (md:render src :allow-html t)))
      (is (search "<h1>A head</h1>" safe) "got ~S" safe)
      (is (search "<p>&quot;quoted&quot; text</p>" safe) "got ~S" safe)
      (is (search "<h1 id=\"a_head\">A head</h1>" trusted) "got ~S" trusted)
      (is (search "&ldquo;quoted&rdquo;" trusted) "got ~S" trusted))))

(test a-fenced-block-is-escaped-for-ampersand-only-under-a-renderer-that-does-not
  ":PYGMENTS and :CHROMA hand the code to an external program that writes escaped HTML, so the
safe mode leaves & for them to escape. This checks the rewrite of the parsed block for each
renderer; it does not run pygments or chroma."
  (flet ((content (renderer lang)
           (let ((3bmd-code-blocks:*renderer* renderer)
                 (3bmd-code-blocks:*code-blocks-default-colorize* nil))
             (getf (md::%restore-code-block (list :lang lang :content "a & b")) :content))))
    (is (equal "a &amp; b" (content :nohighlight "python")))
    (is (equal "a &amp; b" (content :colorize nil)) "colorize leaves an unlabelled block plain")
    (is (equal "a & b" (content :colorize "python")) "colorize escapes a block it colours")
    (is (equal "a & b" (content :pygments "python")))
    (is (equal "a & b" (content :chroma "python")))
    (is (equal "a & b" (content :chroma nil)))))

(test an-entity-renders-as-its-character
  (dolist (html (%safe-and-trusted "Tom &amp; Jerry &copy; 2026."))
    (is (search "Tom &amp; Jerry &copy; 2026." html) "got ~S" html)
    (is (null (search "&amp;amp;" html)))))

(test a-bare-ampersand-and-brackets-in-text-are-escaped-once-in-the-safe-mode
  (is (search "<p>a &amp; b &lt; c &gt; d</p>" (md:render "a & b < c > d"))))

(test an-indented-code-block-is-escaped-once
  (dolist (html (%safe-and-trusted (format nil "Text.~%~%    (< a b) & (> c d)~%")))
    (is (search "<pre><code>(&lt; a b) &amp; (&gt; c d)" html) "got ~S" html)))

(test a-fenced-block-is-escaped-once-whether-or-not-it-is-colourised
  "An unlabelled block goes through 3bmd's ESCAPE-PRE-STRING, which escapes only < and >, so the
safe mode escapes & itself; a block in a language colorize knows is escaped by colorize. An
`&lt;' the author wrote in the code is code, and shows as `&lt;'."
  (let ((plain (md:render (format nil "```~%(< a b) & (> c d) &lt;~%```~%")))
        (coloured (md:render (format nil "```python~%a < b & c > d &lt;~%```~%"))))
    (is (search "<pre><code>(&lt; a b) &amp; (&gt; c d) &amp;lt;</code></pre>" plain) "got ~S" plain)
    ;; With :allow-html t the source reaches ESCAPE-PRE-STRING as written: < and > are escaped
    ;; once, and & is left as written, as before #559.
    (is (search "<pre><code>(&lt; a b) & (&gt; c d) &lt;</code></pre>"
                (md:render (format nil "```~%(< a b) & (> c d) &lt;~%```~%") :allow-html t)))
    (is (search "a &lt; b &amp; c &gt; d &amp;lt;" coloured) "got ~S" coloured)
    (is (search "<span class=\"code\">" coloured) "python is colourised, so this is the other path")
    (is (search "a &lt; b &amp; c &gt; d &amp;lt;"
                (md:render (format nil "```python~%a < b & c > d &lt;~%```~%") :allow-html t)))))

(test raw-html-is-still-text-in-the-safe-mode
  (let ((html (md:render (format nil "<script>alert(1)</script> <b>x</b> <http://x.org>~%~%<div>~%y~%</div>~%"))))
    (is (null (search "<script" html)))
    (is (null (search "<b>" html)))
    (is (null (search "<div" html)))
    (is (null (search "<a " html)) "an autolink stays text, as before")
    (is (search "&lt;script&gt;alert(1)&lt;/script&gt;" html))))

(defun %count-of (needle haystack)
  (loop for p = (search needle haystack) then (search needle haystack :start2 (1+ p))
        while p count t))

(test a-block-quote-renders-in-the-safe-mode-and-other-brackets-stay-text
  "Before #574 the safe mode hid every > from 3bmd, so `> quoted' was a paragraph that began with
&gt;. A > at the start of a line, and again after such a marker, now marks a block quote. Every
other > and every < is escaped once, and raw HTML inside a quote is still text."
  (let ((html (md:render (format nil "> quoted <b>x</b> & y~%"))))
    (is (search "<blockquote>" html) "got ~S" html)
    (is (search "<p>quoted &lt;b&gt;x&lt;/b&gt; &amp; y</p>" html) "got ~S" html)
    (is (null (search "<b>" html))))
  (let ((html (md:render (format nil "> outer~%>~%> > inner~%"))))
    (is (= 2 (%count-of "<blockquote>" html)) "a nested quote: ~S" html)
    (is (search "<p>inner</p>" html)))
  (let ((html (md:render (format nil ">> close~%"))))
    (is (= 2 (%count-of "<blockquote>" html)) "markers with no space between them: ~S" html))
  ;; 3bmd does not read an indented > as a marker, in either mode; it shows it as text, escaped
  ;; once.
  (dolist (html (%safe-and-trusted (format nil "   > three spaces~%")))
    (is (search "<p>&gt; three spaces</p>" html) "got ~S" html))
  (let ((html (md:render (format nil "> ```~%> (< a b) & (> c d)~%> ```~%~%>     <x> > y~%"))))
    (is (search "<blockquote>" html))
    (is (search "<pre><code>(&lt; a b) &amp; (&gt; c d)</code></pre>" html)
        "a fenced block in a quote is code, escaped once: ~S" html)
    (is (search "<pre><code>&lt;x&gt; &gt; y" html) "an indented block in a quote: ~S" html))
  (let ((html (md:render (format nil "a > b~%c >> d~%~%    > code~%"))))
    (is (null (search "<blockquote>" html)) "a > inside a line, or in indented code, is text: ~S" html)
    (is (search "<p>a &gt; b" html))
    (is (search "c &gt;&gt; d</p>" html))
    (is (search "<pre><code>&gt; code" html)))
  (let ((html (md:render (format nil "```lisp~%> (foo)~%```~%~%```~%> <b> &~%```~%"))))
    (is (null (search "<blockquote>" html)) "a > at the start of a line in a fence is code: ~S" html)
    (is (search "<span class=\"code\">&gt; " html) "a colourised block escapes it once: ~S" html)
    (is (search "<pre><code>&gt; &lt;b&gt; &amp;</code></pre>" html) "so does a plain block: ~S" html))
  (let ((html (md:render (format nil "~C> not a quote~%" #\\))))
    (is (null (search "<blockquote>" html)) "an escaped > is text: ~S" html)))

(test a-block-quote-in-a-list-item-renders-in-the-safe-mode-as-in-the-trusted-mode
  "3bmd parses a list item's text again as its own document, so `- > x' is a block quote inside
the item. Before #584 the safe mode marked a > only at the start of a line or after other
markers, so it rendered `- > x' as an item reading &gt; x."
  (dolist (src (list (format nil "- > quoted~%")
                     (format nil "- a~%    > b~%")
                     (format nil "> - > x~%")
                     (format nil "1. > one~%")
                     (format nil "- a~%~%    > b~%")
                     (format nil "- a > b~%")))
    (destructuring-bind (safe trusted) (%safe-and-trusted src)
      (is (string= trusted safe) "~S: the safe mode gave ~S, the trusted mode ~S" src safe trusted)))
  (let ((html (md:render (format nil "- > quoted~%"))))
    (is (search "<li><blockquote>" html) "got ~S" html))
  (let ((html (md:render (format nil "- a~%    > b~%"))))
    (is (search "<blockquote>" html) "a quote on an item's continuation line: ~S" html))
  (let ((html (md:render (format nil "> - > x~%"))))
    (is (= 2 (%count-of "<blockquote>" html)) "a quote in an item in a quote: ~S" html))
  (let ((html (md:render (format nil "- a > b~%"))))
    (is (null (search "<blockquote>" html)) "a > after an item's first word is text: ~S" html)
    (is (search "<li>a &gt; b</li>" html) "got ~S" html))
  (let ((html (md:render (format nil "- > <b>x</b> & y~%"))))
    (is (search "<li><blockquote>" html) "got ~S" html)
    (is (search "&lt;b&gt;x&lt;/b&gt; &amp; y" html) "raw HTML in the quote is text: ~S" html)
    (is (null (search "<b>" html)))))

(test a-placeholder-character-in-the-source-does-not-become-a-bracket
  "The safe mode stands U+FDD0 and U+FDD1 in for < and > while 3bmd parses. One already in the
source is replaced with U+FFFD, so it cannot turn into a bracket."
  (let ((html (md:render (format nil "a~Cb~Cc" (code-char #xFDD0) (code-char #xFDD1)))))
    (is (search (format nil "a~Cb~Cc" (code-char #xFFFD) (code-char #xFFFD)) html) "got ~S" html)))

(test a-fenced-language-that-is-not-a-name-is-dropped-in-the-safe-mode
  "Under 3bmd's :nohighlight renderer the language is written into a class attribute without
escaping a double quote, so the safe mode keeps it only when it is a name."
  (let ((3bmd-code-blocks:*renderer* :nohighlight))
    (is (search "<pre><code>code</code></pre>"
                (md:render (format nil "```x\" onclick=\"a~%code~%```~%"))))
    (is (search "<pre class=\"c++\"><code>code</code></pre>"
                (md:render (format nil "```c++~%code~%```~%"))))))

;;; --- a render mode for untrusted text (#1119) ---------------------------------------------
;;;
;;; An image is fetched as soon as it is rendered, with no click, so a reply holding an image
;;; URL makes the reader's machine send that request and whatever the URL carries with it. In a
;;; desktop webview with no Content-Security-Policy nothing stops it, and following a link
;;; replaces the app's own page. :IMAGES NIL and :LINKS :TEXT are for text the app did not write.

(defun %untrusted (markdown)
  (hyperion/markdown:render markdown :images nil :links :text))

(test untrusted-render-emits-no-image-element-and-no-href
  "#1119: in the untrusted mode no form of image or link reaches the output as markup. Each case
asserts the ABSENCE of the markup and the PRESENCE of the text that replaces it, because a mode
that produced nothing at all would satisfy the first half on its own."
  (dolist (case '(("![alt text](https://elsewhere.example/?d=secret)" . "alt text")
                  ("![a](/local.png)" . "a")
                  ("![a](//host.example/i.png)" . "a")
                  ("[click me](https://elsewhere.example/p)" . "click me")
                  ("[mail](mailto:a@b.example)" . "mail")
                  ("[rel](/page)" . "rel")
                  ("text with ![an image](https://elsewhere.example/i.png) inside" . "an image")
                  ("text with [a link](https://elsewhere.example/p) inside" . "a link")))
    (let ((out (%untrusted (car case))))
      (is-false (search "<img" out) "~S emits no img element: ~A" (car case) out)
      (is-false (search "href" out) "~S emits no href: ~A" (car case) out)
      (is-false (search "elsewhere.example" out)
                "~S does not carry the URL into the output at all: ~A" (car case) out)
      (is-true (search (cdr case) out)
               "~S keeps its text ~S: ~A" (car case) (cdr case) out)))
  ;; A reference link, whose URL lives in a definition elsewhere in the document.
  ;; A DISTINCTIVE LABEL, because "r" appears in almost any HTML this could produce -- in `<p>',
  ;; in `href', in any English word -- so searching for it proved nothing about the label
  ;; surviving (the review of #1120).
  (let ((out (%untrusted (format nil "[zqlabel][1]~%~%  [1]: https://elsewhere.example/p"))))
    (is-false (search "href" out) "a reference link emits no href: ~A" out)
    (is-false (search "elsewhere.example" out) "and does not carry its URL: ~A" out)
    (is-true (search "zqlabel" out) "but keeps its text: ~A" out))
  ;; An autolink. In the safe mode 3bmd does not make one at all -- the angle brackets are
  ;; escaped -- so this asserts the absence rather than claiming the option did the work.
  (let ((out (%untrusted "<https://elsewhere.example/p>")))
    (is-false (search "href" out) "an autolink emits no href: ~A" out)))

(test the-default-render-is-unchanged-by-the-untrusted-mode
  "THE CONTROL for #1119, and the reason the options are opt-in: everything that renders trusted
content must be untouched. Each case is the same input as the untrusted test above, asserting
that the default still produces the markup."
  (dolist (case '(("![alt text](https://elsewhere.example/i.png)" "<img" "alt text")
                  ("![a](/local.png)" "<img" "/local.png")
                  ("[click me](https://elsewhere.example/p)" "href" "click me")
                  ("[mail](mailto:a@b.example)" "href" "mailto:a@b.example")
                  ("[rel](/page)" "href" "/page")))
    (destructuring-bind (markdown markup text) case
      (let ((out (hyperion/markdown:render markdown)))
        (is-true (search markup out) "~S still renders ~A: ~A" markdown markup out)
        (is-true (search text out) "and keeps ~S: ~A" text out))))
  ;; A reference link still renders as a link by default.
  (let ((out (hyperion/markdown:render
              (format nil "[zqlabel][1]~%~%  [1]: https://elsewhere.example/p"))))
    (is-true (search "href" out) "a reference link still renders by default: ~A" out)
    (is-true (search "zqlabel" out) "with its label: ~A" out))
  ;; And the refusals #66 added are untouched by the new arguments, in both modes.
  (dolist (markdown '("[x](javascript:alert(1))" "![x](javascript:alert(1))"))
    (dolist (out (list (hyperion/markdown:render markdown) (%untrusted markdown)))
      (is-false (search "javascript" out) "~S is still refused: ~A" markdown out))))

(test the-untrusted-render-arguments-refuse-a-value-they-cannot-honour
  "#1119: the default is the permissive one, so a typo in a security argument must not read as
`render everything'. And :ALLOW-HTML T cannot be combined with either mode: raw HTML is not
parsed into the tree these options filter, so an IMG or HREF written directly in the source
survives them -- measured, before the combination was refused."
  ;; THE NAMED CONDITION, not just ERROR: an app has to be able to catch this misuse and nothing
  ;; else, so the tests name it (the review of #1120).
  (dolist (bad '(:maybe :no "nil" 0))
    (signals hyperion/markdown:render-option-error
      (hyperion/markdown:render "x" :images bad)))
  (dolist (bad '(:texts :plain "text" nil-is-fine))
    (signals hyperion/markdown:render-option-error
      (hyperion/markdown:render "x" :links bad)))
  ;; And it carries which argument was at fault and what it was given, so a report can say.
  (let ((c (handler-case (progn (hyperion/markdown:render "x" :links :texts) nil)
             (hyperion/markdown:render-option-error (e) e))))
    (is (eq :links (hyperion/markdown:render-option-error-argument c)))
    (is (eq :texts (hyperion/markdown:render-option-error-value c)))
    (is-true (search ":LINKS" (princ-to-string c)) "and prints readably: ~A" c))
  ;; The four accepted combinations are exercised with real markup in
  ;; EACH-OPTION-ACTS-ON-ITS-OWN-KIND-OF-MARKUP below, not here: rendering "x" showed only that a
  ;; string came back, which is what let the reference-link bypass survive (the review of #1120).
  (is-true (stringp (hyperion/markdown:render "x" :images t :links t)))
  ;; The combination that cannot be honoured.
  (signals hyperion/markdown:render-option-error
    (hyperion/markdown:render "x" :allow-html t :images nil))
  (signals hyperion/markdown:render-option-error
    (hyperion/markdown:render "x" :allow-html t :links :text))
  (signals hyperion/markdown:render-option-error
    (hyperion/markdown:render "x" :allow-html t :images nil :links :text))
  ;; The control: :ALLOW-HTML T on its own still works, and still passes raw HTML through, which
  ;; is why the combination above is refused rather than quietly ignored.
  (let ((out (hyperion/markdown:render "<img src=\"https://elsewhere.example/i.png\">"
                                       :allow-html t)))
    (is-true (search "<img" out) "control: raw HTML still passes with :allow-html t alone: ~A" out)))

(test each-option-acts-on-its-own-kind-of-markup
  "The review of #1120, and the bypass it found. The mixed combinations were only ever rendered
with the input \"x\", so nothing checked what each option does on its own -- and the untrusted
tests always set BOTH, so :LINKS :TEXT masked an image surviving :IMAGES NIL.

THE BYPASS: an accepted reference link was returned whole, so its label was never walked. With
:IMAGES NIL and the default :LINKS T, `[![alt](https://tracker.example/i.png)][r]' kept the
image and would still have fetched it. Measured before the fix:

  :images nil, :links t -> <p><a href=\"...\"><img src=\"https://tracker.example/i.png\" ...></a></p>

Each row below is one input under all four accepted combinations, asserting what each option is
responsible for rather than that something came back."
  (let ((image "![alt](https://img.example/i.png)")
        (link "[words](https://link.example/p)")
        (ref-with-image (format nil "[![alt](https://img.example/i.png)][r]~%~%  [r]: https://link.example/p")))
    (flet ((out (markdown images links)
             (hyperion/markdown:render markdown :images images :links links)))
      ;; An image: governed by :IMAGES alone, whatever :LINKS says.
      (dolist (links '(t :text))
        (is-true (search "<img" (out image t links))
                 ":images t keeps the image with :links ~S" links)
        (is-false (search "<img" (out image nil links))
                  ":images nil drops it with :links ~S" links)
        (is-true (search "alt" (out image nil links))
                 "and leaves the alt text with :links ~S" links))
      ;; A link: governed by :LINKS alone, whatever :IMAGES says.
      (dolist (images '(t nil))
        (is-true (search "href" (out link images t))
                 ":links t keeps the href with :images ~S" images)
        (is-false (search "href" (out link images :text))
                  ":links :text drops it with :images ~S" images)
        (is-true (search "words" (out link images :text))
                 "and leaves the text with :images ~S" images))
      ;; AN IMAGE INSIDE AN ACCEPTED REFERENCE LINK'S LABEL -- the bypass. The link is allowed
      ;; here, so this is the case where only :IMAGES can stop the fetch.
      (is-true (search "<img" (out ref-with-image t t))
               "control: the default keeps both the link and the image")
      (is-true (search "href" (out ref-with-image nil t))
               ":links t keeps the reference link")
      (is-false (search "<img" (out ref-with-image nil t))
                "but :images nil drops the image inside its label: ~A" (out ref-with-image nil t))
      (is-false (search "img.example" (out ref-with-image nil t))
                "and the image URL does not reach the output: ~A" (out ref-with-image nil t))
      (is-true (search "alt" (out ref-with-image nil t))
               "while the alt text stays")
      ;; THE LOOKUP KEY SURVIVES THE SANITISING. The label is rewritten, so the original is kept
      ;; as the definition; without that the key would change and the href would not resolve.
      (is-true (search "link.example/p" (out ref-with-image nil t))
               "the reference still resolves to its definition: ~A" (out ref-with-image nil t))
      ;; And with links off too, nothing of either remains.
      (dolist (o (list (out ref-with-image nil :text) (out ref-with-image t :text)))
        (is-false (search "href" o) "no href with :links :text: ~A" o))
      (is-false (search "<img" (out ref-with-image nil :text))
                "and no image with both off"))))

(defun %attribute-value (name html)
  "The value of the first NAME=\"...\" attribute in HTML, read to the next double quote, or NIL.

READ EXACTLY AS A BROWSER'S TOKENIZER WOULD END IT -- at the first quote, not at the last one on
the line. That is the whole point of #1132: the injected markup's own quote ended the attribute
early, and a test that took the value as everything up to the final quote would see one long
harmless-looking string and miss it."
  (let ((start (search (concatenate 'string name "=\"") html)))
    (when start
      (let* ((from (+ start (length name) 2))
             (end (position #\" html :start from)))
        (and end (subseq html from end))))))

(test an-image-inside-an-image-alt-cannot-add-attributes-to-it
  "#1132, found by the hub's review of #1120, and ON MAIN WITH THE DEFAULT OPTIONS -- not only in
the untrusted mode, which is what makes it the more serious half of this work.

3bmd renders an image's alt label to HTML and writes the result into alt=\"...\" without escaping
it, so a nested element put its own markup inside the attribute. Measured at 052737ea:

  ![![x](onerror=alert(1))](outer.png)
  -> <img src=\"outer.png\" alt=\"<img src=\"onerror=alert(1)\" alt=\"x\" />\" />

The alt value ends at the inner src's first quote and the rest is read as attributes of the
outer image: ONERROR, with the unquoted value ALERT(1). %SAFE-URL passes that source because it
is a relative URL, and the outer source then fails to load, which runs the handler.

THE ASSERTION IS ABOUT THE ATTRIBUTE, not about the string ONERROR. An alt text may legitimately
contain the characters `onerror=alert(1)' as text -- `![![x onerror=alert(1)](i.png)](outer.png)'
does, harmlessly, inside the quoted value -- so a test grepping the output for ONERROR would
both miss the real case and fail on a safe one. What must hold is that the alt value ends where
3bmd meant it to end: no quote and no < inside it, and exactly one IMG in the output."
  (let ((cases (list "![![x](onerror=alert(1))](outer.png)"
                     "![![x](i.png)](outer.png)"
                     "![![x](i.png \"ttl\")](outer.png)"
                     "![![x](i.png)![y](j.png)](outer.png)"
                     "![![x onerror=alert(1)](i.png)](outer.png)"
                     "![a *b* ![n](m.png)](outer.png)"
                     "![![<script>alert(1)</script>](i.png)](outer.png)"
                     ;; An entity is written into the attribute raw, so it is worth asserting
                     ;; that it cannot end one: a character reference is not a quote to the
                     ;; tokenizer, whatever it decodes to.
                     "![a &quot; b](o.png)"
                     "![![a &quot; b](i.png)](outer.png)")))
    (dolist (md cases)
      ;; The default options first: this is reached without asking for anything.
      ;; :ALLOW-HTML T goes through this same branch and had no test of its own (the review of
      ;; #1133). It cannot be combined with the untrusted options -- that is refused -- so it is
      ;; its own entry rather than a third axis.
      (dolist (options '(() (:allow-html t)
                         (:images t :links t) (:images t :links :text)
                         (:images nil :links t) (:images nil :links :text)))
        (let* ((html (apply #'hyperion/markdown:render md options))
               (images-on (let ((v (getf options :images :unsupplied)))
                            (or (eq v :unsupplied) v)))
               (imgs (%count-of "<img" html))
               (alt (%attribute-value "alt" html)))
          (if images-on
              (progn
                (is (= 1 imgs) "exactly one IMG for ~S with ~S: ~A" md options html)
                (is-true alt "and it has an alt value for ~S with ~S: ~A" md options html)
                (is-false (and alt (find #\" alt))
                          "whose value holds no quote for ~S with ~S: ~A" md options html)
                (is-false (and alt (find #\< alt))
                          "and no < for ~S with ~S: ~A" md options html))
              (is (= 0 imgs) "no IMG at all with :images nil for ~S: ~A" md html))
          ;; Whatever the options, nothing may close the outer tag early and leave a stray
          ;; fragment behind as content. The injected markup ended with `/>\"', so the quote
          ;; was left in the document text.
          (is-false (search "/>\"" html)
                    "no stray fragment after an early tag close for ~S with ~S: ~A"
                    md options html))))))

(test an-alt-label-keeps-its-entities-and-its-word-breaks
  "The review of #1133, which found two things the alt flattening lost. Both are regressions
against what #1132 was fixing, so both have a control here.

AN ENTITY WAS ESCAPED TWICE. %LABEL-TEXT wrote the (:ENTITY \"&copy;\") node's text as plain text
and 3bmd then escaped the ampersand, so alt=\"a &copy; b\" became alt=\"a &amp;copy; b\" and the
reader saw the markup instead of the character.

A HARD LINE BREAK CONTRIBUTED NOTHING, so the words on either side of one were joined:
alt=\"line1line2\". It cannot stay a BR -- an attribute cannot hold markup, and writing a literal
<br/> into the attribute is what the code did BEFORE #1132, measured at 052737ea. A space is what
is left, because they are separate words.

The emphasis case is here to record a loss that IS intended: an alt attribute cannot hold markup,
so emphasis and code inside one become their text."
  (let ((entities (md:render "![a &copy; &quot; b](o.png)"))
        (broken (md:render (format nil "![line1  ~%line2](o.png)")))
        (marked (md:render "![a *b* `c` d](o.png)")))
    (is (equal "a &copy; &quot; b" (%attribute-value "alt" entities))
        "an entity reaches the alt as itself: ~A" entities)
    (is-false (search "&amp;copy;" entities)
              "and is not escaped a second time: ~A" entities)
    (is (equal "line1 line2" (%attribute-value "alt" broken))
        "a hard line break separates the words: ~A" broken)
    (is-false (search "<br" broken)
              "and does not put a BR in the attribute: ~A" broken)
    (is (equal "a b c d" (%attribute-value "alt" marked))
        "while emphasis and code become their text, which an attribute cannot hold: ~A" marked)))
