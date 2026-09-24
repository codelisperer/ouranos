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
