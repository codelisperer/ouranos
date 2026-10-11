;;;; comments.lisp --- HTML comments are removed from a document's Markdown when it is loaded (#556).
;;;;
;;;; Authors write `<!-- ... -->' in Markdown to keep a note in the file that readers do not see.
;;;; klio renders with raw HTML escaped, so before #556 such a comment appeared on the page as
;;;; visible text, and search.json and the search index carried it too. LOAD-DOCUMENT now removes
;;;; every comment from the body before anything renders or indexes it.
;;;;
;;;; A comment written inside code is kept, because it is part of what the code shows. What
;;;; counts as code is what klio's own renderer, RENDER-MARKDOWN, puts inside <code>, so this
;;;; file does not parse Markdown itself. It renders a copy of the body with one marker after each
;;;; `<!--' and another before the `-->' that closes it, and keeps a comment only when each of its
;;;; two markers appears once, both inside the same <code> element, the first before the second.
;;;; The text between two points of one element is inside that element, so the whole comment is
;;;; then shown as code. Every other comment is removed, including one whose `<!--' is code but
;;;; whose `-->' is not, one whose marker the renderer drops or repeats, and one that is never
;;;; closed: when it is unclear whether a comment is code, keeping a note private matters more
;;;; than showing a comment in code.
;;;;
;;;; Removing a comment can change how the text around it renders, and can join the text on
;;;; either side into a new `<!--', so the body is rendered again until a pass removes nothing.
;;;; Each pass that continues removes at least one comment, so the text gets shorter and the loop
;;;; ends; +MAX-PASSES+ bounds it anyway, and when it is reached every comment left is removed.
;;;;
;;;; The markers are Unicode noncharacters. They are only in the copy given to the renderer, and
;;;; the body keeps its own text, so they reach neither the page, nor search.json, nor the index.
;;;; A body that already contains one of them has every comment removed, because a marker could
;;;; not be told from the author's character.
;;;;
;;;; Only the Markdown body is stripped. Front matter is YAML, where a note is a `#' comment, so a
;;;; `<!-- -->' in a front-matter value is kept as written.

(in-package #:klio)

(defparameter +marker-frames+
  (list (list* :open (code-char #xFDD2) (code-char #xFDD3))
        (list* :close (code-char #xFDD4) (code-char #xFDD5)))
  "For each kind of marker, the noncharacters that start and end it. An :OPEN marker follows a
comment's `<!--', and a :CLOSE marker comes before its `-->'.")
(defparameter +marker-digit-0+ #xFDE0
  "The code of the noncharacter that stands for hexadecimal digit 0 in a marker; 1 to F follow.")
(defparameter +max-passes+ 64
  "The most times STRIP-HTML-COMMENTS renders a body before it removes every comment left.")

(defun %marker-digit-p (c)
  (<= +marker-digit-0+ (char-code c) (+ +marker-digit-0+ 15)))

(defun %marker-char-p (c)
  (or (<= #xFDD2 (char-code c) #xFDD5) (%marker-digit-p c)))

(defun %marker (kind n)
  "The KIND marker for comment N: its start character, N in hexadecimal digits, its end
character."
  (destructuring-bind (start . end) (cdr (assoc kind +marker-frames+))
    (with-output-to-string (out)
      (write-char start out)
      (loop for c across (format nil "~X" n)
            do (write-char (code-char (+ +marker-digit-0+ (digit-char-p c 16))) out))
      (write-char end out))))

(defun %marker-number (digits)
  "The number DIGITS, a string of marker digits, stands for, or NIL when it is empty or holds
anything else."
  (and (plusp (length digits))
       (every #'%marker-digit-p digits)
       (parse-integer (map 'string (lambda (c) (digit-char (- (char-code c) +marker-digit-0+) 16))
                           digits)
                      :radix 16)))

(defun %comment-openings (text)
  "The positions of each `<!--' in TEXT that a backslash does not escape, in order."
  (loop with start = 0
        for p = (search "<!--" text :start2 start)
        while p
        unless (oddp (loop for i downfrom (1- p) to 0
                           while (char= #\\ (char text i))
                           count t))
          collect p
        do (setf start (1+ p))))

(defun %text-with-code-elements (html)
  "The text of HTML with its tags left out, as (values STRING ELEMENTS): ELEMENTS has one element
for each character of STRING, the number of the outermost <code> element the character is in,
counting from 1, or NIL outside code. Highlighting splits code into <span>s, and the text is
read across them; the text of an attribute is not read."
  (let ((text (make-string-output-stream))
        (elements (make-array 0 :adjustable t :fill-pointer t))
        (depth 0)
        (count 0)
        (i 0)
        (n (length html)))
    (loop while (< i n)
          do (let ((c (char html i)))
               (if (char= c #\<)
                   (let ((close (or (position #\> html :start i) (1- n))))
                     (cond ((and (< (+ i 5) n)
                                 (string-equal "<code" html :start2 i :end2 (+ i 5))
                                 (member (char html (+ i 5)) '(#\> #\Space)))
                            (when (zerop depth) (incf count))
                            (incf depth))
                           ((string-equal "</code>" html :start2 i :end2 (min n (+ i 7)))
                            (setf depth (max 0 (1- depth)))))
                     (setf i (1+ close)))
                   (progn (write-char c text)
                          (vector-push-extend (and (plusp depth) count) elements)
                          (incf i)))))
    (values (get-output-stream-string text) elements)))

(defun %comments-in-code (html count)
  "A vector of COUNT booleans: element N is true when HTML has the :OPEN marker of comment N once
and its :CLOSE marker once, both inside the same <code> element, the :OPEN one first."
  (let ((opens (make-array count :initial-element '()))
        (closes (make-array count :initial-element '())))
    (multiple-value-bind (text elements) (%text-with-code-elements html)
      (loop for i from 0 below (length text)
            for kind = (car (find (char text i) +marker-frames+ :key #'cadr))
            do (when kind
                 (let* ((end (position (cddr (assoc kind +marker-frames+)) text :start i))
                        (n (and end (%marker-number (subseq text (1+ i) end)))))
                   (when (and n (< n count))
                     (push (cons i (aref elements i))
                           (aref (if (eq kind :open) opens closes) n)))))))
    (map 'vector
         (lambda (open close)
           (and (= 1 (length open)) (= 1 (length close))
                (cdar open)
                (eql (cdar open) (cdar close))
                (< (caar open) (caar close))))
         opens closes)))

(defun %comment-end (text p)
  "The position of the `-->' that closes the comment opened at P in TEXT, or NIL. <!--> and
<!---> are whole comments (CommonMark 0.31.2, section 6.6), so the end is searched for from the
second dash."
  (search "-->" text :start2 (+ p 2)))

(defun %marked (text openings)
  "TEXT with the :OPEN marker of comment N after the `<!--' at the Nth of OPENINGS, and its
:CLOSE marker before the `-->' that closes it. The :CLOSE marker of <!--> or <!---> follows the
:OPEN one, because its `-->' overlaps the `<!--'."
  (let ((inserts (sort (loop for p in openings
                             for n from 0
                             for end = (%comment-end text p)
                             collect (list (+ p 4) 0 (%marker :open n))
                             when end
                               collect (list (max end (+ p 4)) 1 (%marker :close n)))
                       (lambda (a b) (or (< (first a) (first b))
                                         (and (= (first a) (first b)) (< (second a) (second b))))))))
    (with-output-to-string (out)
      (loop with from = 0
            for (at nil marker) in inserts
            do (write-string text out :start from :end at)
               (write-string marker out)
               (setf from at)
            finally (write-string text out :start from)))))

(defun %strip-pass (text in-code)
  "TEXT with each comment that IN-CODE does not mark as code removed, from its `<!--' to the
`-->' that closes it. Returns (values TEXT REMOVED UNCLOSED): how many were removed, and true
when one had no `-->' and the rest of TEXT went with it. IN-CODE NIL removes every comment."
  (let ((out (make-string-output-stream))
        (cursor 0)
        (removed 0))
    (loop for p in (%comment-openings text)
          for n from 0
          do (when (and (>= p cursor) (not (and in-code (aref in-code n))))
               (write-string text out :start cursor :end p)
               (incf removed)
               (let ((end (%comment-end text p)))
                 (unless end
                   (return-from %strip-pass (values (get-output-stream-string out) removed t)))
                 (setf cursor (+ end 3)))))
    (write-string text out :start cursor)
    (values (get-output-stream-string out) removed nil)))

(defun %strip-all (text)
  "TEXT with every comment removed, including one that a removal forms by joining the text on
either side, as (values TEXT UNCLOSED)."
  (let ((unclosed nil))
    (loop (multiple-value-bind (next removed gone) (%strip-pass text nil)
            (when gone (setf unclosed t))
            (when (zerop removed) (return (values text unclosed)))
            (setf text next)))))

(defun strip-html-comments (markdown &key (render #'render-markdown))
  "MARKDOWN with every HTML comment, from `<!--' to the next `-->', removed, except a comment
that RENDER, klio's renderer by default, shows whole inside one <code> element (see the
commentary at the top of this file). `\\<!--', which Markdown writes as literal text, is not a
comment.

A comment that is never closed removes everything after its `<!--', so a note is not published
because its end was forgotten. The second value is true in that case, for the loader to warn."
  (when (some #'%marker-char-p markdown)
    (return-from strip-html-comments (%strip-all markdown)))
  (let ((text markdown)
        (unclosed nil))
    (loop for pass from 1
          for openings = (%comment-openings text)
          while openings
          do (when (> pass +max-passes+)
               (multiple-value-bind (stripped gone) (%strip-all text)
                 (return-from strip-html-comments (values stripped (or unclosed gone)))))
             (multiple-value-bind (next removed gone)
                 (%strip-pass text (%comments-in-code (funcall render (%marked text openings))
                                                      (length openings)))
               (when gone (setf unclosed t))
               (when (zerop removed) (return))
               (setf text next)))
    (values text unclosed)))
