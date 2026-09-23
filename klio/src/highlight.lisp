;;;; highlight.lisp --- a small Common Lisp highlighter, applied at content-load time.
;;;;
;;;; pre-publication issue 359 Q3, ruled: a small CL highlighter, Lisp only, at content-load time; other languages
;;;; render as plain `<pre>`. The argument that decided it is worth keeping next to the code:
;;;; a site whose whole claim is "CL all the way down" that ships JavaScript to colour its
;;;; Lisp makes the opposite argument on every page. A general highlighter was the other
;;;; option, and it buys coverage for languages the site does not use.
;;;;
;;;; WHAT WAS ALREADY THERE, because it changes what this file had to do. 3bmd's default
;;;; renderer IS `colorize', and a ```lisp fence was already being coloured server-side --
;;;; contradicting `hyperion/markdown''s own comment, which says it emits "plain <pre><code>
;;;; (no server-side colorize)". That comment is true only for an UNLABELLED fence. The
;;;; colorize path also prints "could not find hyperspec map file" to standard output while
;;;; rendering, which is console noise in whatever process happens to load content.
;;;;
;;;; So klio renders through 3bmd's `:nohighlight' renderer, which emits
;;;; `<pre class="LANG"><code>escaped</code></pre>' -- plain, and RECORDING THE LANGUAGE,
;;;; which is the one thing a post-pass needs. Then this file re-marks the blocks whose
;;;; language is a Lisp. Everything else is left exactly as it arrived.
;;;;
;;;; THE CLASSES ARE STRUCTURAL, NOT A VOCABULARY. Comments, strings, characters, numbers and
;;;; keywords are lexical facts; the `operator' class is the symbol in the head position of a
;;;; form, which is a fact about where it sits rather than a list of names somebody has to
;;;; maintain. A highlighter with a list of "known" operators is a list that is wrong the
;;;; first time a site writes a macro.
;;;;
;;;; This produces CLASSES, not colours. The stylesheet is the site's, like every other
;;;; question of how a page looks.

(cl:in-package #:klio)

(defparameter *lisp-languages* '("lisp" "common-lisp" "commonlisp" "cl" "elisp")
  "Fence languages this highlighter claims. Anything else is left as plain <pre>, which is
what Q3 decided: coverage for languages the site does not use is what the general-highlighter
option was rejected for.")

(defparameter *highlight-classes*
  '((:comment . "code-comment") (:string . "code-string") (:char . "code-char")
    (:number . "code-number") (:keyword . "code-keyword") (:operator . "code-operator"))
  "Token class to CSS class. Prefixed, because these spans land in a site's stylesheet beside
its own classes and `string' is a word a site may already be using.")

(defun %class-for (token)
  (or (cdr (assoc token *highlight-classes*)) "code-token"))

(defun %escape (string)
  "STRING as HTML text. The same four characters 3bmd escapes, so a round trip through
%UNESCAPE and back is the identity on anything it produced."
  (with-output-to-string (out)
    (loop for ch across string
          do (case ch
               (#\& (write-string "&amp;" out))
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (#\" (write-string "&quot;" out))
               (t (write-char ch out))))))

(defun %replace-all (string part replacement)
  (with-output-to-string (out)
    (loop with start = 0
          for pos = (search part string :start2 start)
          while pos
          do (write-string string out :start start :end pos)
             (write-string replacement out)
             (setf start (+ pos (length part)))
          finally (write-string string out :start start))))

(defun %unescape (string)
  "The inverse of %ESCAPE, for reading back the text 3bmd put inside a <code> element.

`&amp;' LAST is not an ordering preference, it is the correctness condition: unescaping it
first would turn `&amp;lt;' -- which is how an author writes a literal `&lt;' -- into `&lt;'
and then into `<', producing markup the author did not write."
  (let ((text string))
    (dolist (pair '(("&lt;" . "<") ("&gt;" . ">") ("&quot;" . "\"") ("&#39;" . "'")
                    ("&amp;" . "&"))
                  text)
      (setf text (%replace-all text (car pair) (cdr pair))))))

;;; --- the scanner -------------------------------------------------------------

(defun %terminator-p (ch)
  (or (member ch '(#\Space #\Tab #\Newline #\Return #\( #\) #\" #\; #\'))))

(defun %token-end (source start)
  "The index just past the token beginning at START."
  (let ((n (length source)))
    (loop for i from start below n
          when (%terminator-p (char source i)) return i
          finally (return n))))

(defun %number-token-p (text)
  "Is TEXT a number the way a reader would see it? An optional sign, digits, at most one `.'
or `/', and an optional exponent marker followed by digits.

NO READER, deliberately. READ-FROM-STRING would answer this question more exactly and it
would also INTERN a symbol for every token that is not a number -- unbounded growth driven by
the contents of a content file -- and it evaluates reader macros unless every relevant special
is bound off. A predicate cannot do either, and the cost of getting it slightly wrong is a
number that is not coloured.

`1+' is the case that makes the shape of this matter: it is a FUNCTION, it starts with a
digit, and colouring it as a number is wrong in a way a reader would have caught. So a
trailing sign disqualifies."
  (let ((n (length text)))
    (and (plusp n)
         (let ((i 0) (digits 0) (dots 0) (slashes 0) (exponents 0))
           (when (and (< i n) (find (char text i) "+-")) (incf i))
           (loop while (< i n)
                 do (let ((ch (char text i)))
                      (cond ((digit-char-p ch) (incf digits))
                            ((char= ch #\.) (incf dots))
                            ((char= ch #\/) (incf slashes))
                            ((find ch "eEdDsSfFlL")
                             (incf exponents)
                             ;; an exponent marker must be followed by digits, optionally signed
                             (when (and (< (1+ i) n) (find (char text (1+ i)) "+-")) (incf i))
                             (unless (and (< (1+ i) n) (digit-char-p (char text (1+ i))))
                               (return-from %number-token-p nil)))
                            (t (return-from %number-token-p nil)))
                      (incf i)))
           (and (plusp digits) (<= dots 1) (<= slashes 1) (<= exponents 1)
                (not (zerop (length text)))
                ;; `1+' and `1-' reach here with a trailing sign, which no number has.
                (not (find (char text (1- n)) "+-")))))))

(defun %emit (out class text)
  "Write TEXT into OUT, wrapped in CLASS's span when it has one."
  (when (plusp (length text))
    (if class
        (format out "<span class=\"~A\">~A</span>" (%class-for class) (%escape text))
        (write-string (%escape text) out))))

(defun %string-end (source start)
  "The index just past the string literal beginning at START (which is its opening quote).
An unterminated string ends at the end of the source: content is prose, not a compilation
unit, and refusing to render a page over a stray quote inside a code block would be a
content-load failure for a typo in an illustration."
  (let ((n (length source)))
    (loop with i = (1+ start)
          while (< i n)
          do (let ((ch (char source i)))
               (cond ((char= ch #\\) (incf i 2))
                     ((char= ch #\") (return-from %string-end (1+ i)))
                     (t (incf i)))))
    n))

(defun %block-comment-end (source start)
  "The index just past the #| |# comment beginning at START, honouring nesting."
  (let ((n (length source)) (depth 0) (i start))
    (loop while (< i n)
          do (cond ((and (< (1+ i) n) (char= (char source i) #\#) (char= (char source (1+ i)) #\|))
                    (incf depth) (incf i 2))
                   ((and (< (1+ i) n) (char= (char source i) #\|) (char= (char source (1+ i)) #\#))
                    (decf depth) (incf i 2)
                    (when (zerop depth) (return-from %block-comment-end i)))
                   (t (incf i))))
    n))

(defun highlight-lisp (source)
  "SOURCE as HTML: the text escaped, with spans around the lexical classes.

One pass, no reader, no evaluation. Anything it does not recognise is escaped text, so the
worst outcome for an unusual construct is a block that is correct and uncoloured."
  (let ((n (length source)))
    (with-output-to-string (out)
      (let ((i 0)
            (depth 0)                   ; open parens, so `head' can mean TOP-LEVEL head
            (head nil))                 ; is the next token the head of a top-level form?
        (loop while (< i n)
              do (let ((ch (char source i)))
                   (cond
                     ;; a line comment runs to the end of the line, inclusive of neither
                     ((char= ch #\;)
                      (let ((end (or (position #\Newline source :start i) n)))
                        (%emit out :comment (subseq source i end))
                        (setf i end)))
                     ;; #| ... |#, nested
                     ((and (char= ch #\#) (< (1+ i) n) (char= (char source (1+ i)) #\|))
                      (let ((end (%block-comment-end source i)))
                        (%emit out :comment (subseq source i end))
                        (setf i end)))
                     ((char= ch #\")
                      (let ((end (%string-end source i)))
                        (%emit out :string (subseq source i end))
                        (setf i end)))
                     ;; #\x, including #\Space and friends
                     ((and (char= ch #\#) (< (1+ i) n) (char= (char source (1+ i)) #\\))
                      (let ((end (max (+ i 3) (%token-end source (+ i 2)))))
                        (%emit out :char (subseq source i (min end n)))
                        (setf i (min end n))))
                     ((char= ch #\()
                      (%emit out nil "(")
                      (incf depth)
                      ;; ONLY AT DEPTH 1, and this is the whole of what `operator' claims.
                      ;; The head of a top-level form is a definition or a call, which is what
                      ;; a reader scans for. Deeper, the head position is indistinguishable
                      ;; from a PARAMETER LIST -- `(x)' in (defun f (x) ...) is not a call to
                      ;; x -- and telling them apart needs a vocabulary of binding forms,
                      ;; which is the list this file refuses to keep because it is wrong the
                      ;; first time a site writes a macro.
                      (setf head (= depth 1))
                      (incf i))
                     ((char= ch #\))
                      (%emit out nil ")")
                      (setf depth (max 0 (1- depth)))
                      (setf head nil)
                      (incf i))
                     ((member ch '(#\Space #\Tab #\Newline #\Return))
                      (%emit out nil (string ch))
                      (incf i))
                     (t
                      (let* ((end (%token-end source i))
                             (text (subseq source i (max end (1+ i)))))
                        (cond
                          ((and (plusp (length text)) (char= (char text 0) #\:))
                           (%emit out :keyword text))
                          ((%number-token-p text) (%emit out :number text))
                          (head (%emit out :operator text))
                          (t (%emit out nil text)))
                        (setf head nil)
                        (setf i (max end (1+ i)))))))))
      )))

;;; --- finding the blocks to highlight -----------------------------------------

(defparameter +pre-open+ "<pre class=\""
  "How 3bmd's :nohighlight renderer opens a fenced block that named a language. klio asserts
this shape in its suite rather than trusting it: a library upgrade that changed it would
otherwise stop highlighting silently, and an unhighlighted page looks exactly like a page
with no Lisp on it.")

(defun highlight-code-blocks (html)
  "HTML with every Lisp code block re-marked, and everything else untouched."
  (with-output-to-string (out)
    (loop with start = 0
          for open = (search +pre-open+ html :start2 start)
          while open
          do (let* ((lang-start (+ open (length +pre-open+)))
                    (lang-end (position #\" html :start lang-start))
                    (code-open (and lang-end (search "><code>" html :start2 lang-end)))
                    (body-start (and code-open (+ code-open (length "><code>"))))
                    (body-end (and body-start (search "</code></pre>" html :start2 body-start))))
               (cond
                 ((null body-end)
                  ;; Not a shape we understand: leave the rest exactly as it is rather than
                  ;; rewriting around a guess.
                  (write-string html out :start start)
                  (return-from highlight-code-blocks (get-output-stream-string out)))
                 (t
                  (let ((lang (subseq html lang-start lang-end)))
                    ;; An unlabelled fence reaches the :nohighlight renderer with LANG "" and
                    ;; comes out as `<pre class="">'. Writing the attribute back empty would
                    ;; make klio's HTML for a plain block differ from every other renderer's
                    ;; for no reason, so it is dropped.
                    (if (zerop (length lang))
                        (progn (write-string html out :start start :end open)
                               (write-string "<pre><code>" out))
                        (write-string html out :start start :end body-start))
                    (if (member lang *lisp-languages* :test #'string-equal)
                        (write-string (highlight-lisp (%unescape (subseq html body-start body-end)))
                                      out)
                        (write-string (subseq html body-start body-end) out))
                    (setf start body-end)))))
          finally (write-string html out :start start))))
