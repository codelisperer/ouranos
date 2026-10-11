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
