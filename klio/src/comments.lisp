;;;; comments.lisp --- HTML comments are removed from a document's Markdown when it is loaded (#556).
;;;;
;;;; Authors write `<!-- ... -->' in Markdown to keep a note in the file that readers do not see.
;;;; klio renders with raw HTML escaped, so before #556 such a comment appeared on the page as
;;;; visible text, and search.json and the search index carried it too. LOAD-DOCUMENT now removes
;;;; every comment from the body before anything renders or indexes it.
;;;;
;;;; A comment written inside code is kept, because it is part of what the code shows. What
;;;; counts as code is what klio's own renderer, RENDER-MARKDOWN, puts inside <code>, so this
;;;; file does not parse Markdown itself. It renders a copy of the body with a marker after each
;;;; `<!--', and keeps a comment only when every copy of its marker comes out inside <code>.
;;;; Every other comment is removed, including one whose marker the renderer drops or places
;;;; anywhere else: when it is unclear whether a comment is code, keeping a note private matters
;;;; more than showing a comment in code. Removing a comment can change how the text around it
;;;; renders, so the body is rendered again until a pass keeps every comment that is left.
;;;;
;;;; The markers are Unicode noncharacters. They are only in the copy given to the renderer, and
;;;; the body keeps its own text, so they reach neither the page, nor search.json, nor the index.
;;;; A body that already contains one of them has every comment removed, because a marker could
;;;; not be told from the author's character.

(in-package #:klio)

(defparameter +marker-open+ (code-char #xFDD2))
(defparameter +marker-close+ (code-char #xFDD3))
(defparameter +marker-digit-0+ #xFDE0
  "The code of the noncharacter that stands for hexadecimal digit 0 in a marker; 1 to F follow.")

(defun %marker-digit-p (c)
  (<= +marker-digit-0+ (char-code c) (+ +marker-digit-0+ 15)))

(defun %marker-char-p (c)
  (or (char= c +marker-open+) (char= c +marker-close+) (%marker-digit-p c)))

(defun %marker (n)
  "The marker for comment N: the open character, N in hexadecimal digits, the close character."
  (with-output-to-string (out)
    (write-char +marker-open+ out)
    (loop for c across (format nil "~X" n)
          do (write-char (code-char (+ +marker-digit-0+ (digit-char-p c 16))) out))
    (write-char +marker-close+ out)))

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

(defun %text-with-code-flags (html)
  "The text of HTML with its tags left out, as (values STRING FLAGS): FLAGS has one element for
each character of STRING, true when the character is inside a <code> element. Highlighting
splits code into <span>s, and the text is read across them."
  (let ((text (make-string-output-stream))
        (flags (make-array 0 :adjustable t :fill-pointer t))
        (depth 0)
        (i 0)
        (n (length html)))
    (loop while (< i n)
          do (let ((c (char html i)))
               (if (char= c #\<)
                   (let ((close (or (position #\> html :start i) (1- n))))
                     (cond ((and (< (+ i 5) n)
                                 (string-equal "<code" html :start2 i :end2 (+ i 5))
                                 (member (char html (+ i 5)) '(#\> #\Space)))
                            (incf depth))
                           ((string-equal "</code>" html :start2 i :end2 (min n (+ i 7)))
                            (setf depth (max 0 (1- depth)))))
                     (setf i (1+ close)))
                   (progn (write-char c text)
                          (vector-push-extend (plusp depth) flags)
                          (incf i)))))
    (values (get-output-stream-string text) flags)))

(defun %comments-in-code (html count)
  "A vector of COUNT booleans: element N is true when the marker of comment N appears in HTML at
least once, and every time inside <code>."
  (let ((seen (make-array count :initial-element nil))
        (outside (make-array count :initial-element nil)))
    (multiple-value-bind (text flags) (%text-with-code-flags html)
      (loop with i = 0
            for open = (position +marker-open+ text :start i)
            for close = (and open (position +marker-close+ text :start open))
            while close
            do (let ((n (%marker-number (subseq text (1+ open) close))))
                 (when (and n (< n count))
                   (setf (aref seen n) t)
                   (unless (and (aref flags open) (aref flags close))
                     (setf (aref outside n) t))))
               (setf i (1+ close))))
    (map 'vector (lambda (s o) (and s (not o))) seen outside)))

(defun %marked (text openings)
  "TEXT with the marker of comment N after the `<!--' at the Nth of OPENINGS."
  (with-output-to-string (out)
    (loop with from = 0
          for p in openings
          for n from 0
          do (write-string text out :start from :end (+ p 4))
             (write-string (%marker n) out)
             (setf from (+ p 4))
          finally (write-string text out :start from))))

(defun %strip-pass (text in-code)
  "TEXT with each comment that IN-CODE does not mark as code removed, from its `<!--' to the next
`-->'. Returns (values TEXT REMOVED UNCLOSED): how many were removed, and true when one had no
`-->' and the rest of TEXT went with it. IN-CODE NIL removes every comment."
  (let ((out (make-string-output-stream))
        (cursor 0)
        (removed 0))
    (loop for p in (%comment-openings text)
          for n from 0
          do (when (and (>= p cursor) (not (and in-code (aref in-code n))))
               (write-string text out :start cursor :end p)
               (incf removed)
               ;; <!--> and <!---> are whole comments (CommonMark 0.31.2, section 6.6), so the
               ;; end is searched for from the second dash.
               (let ((end (search "-->" text :start2 (+ p 2))))
                 (unless end
                   (return-from %strip-pass (values (get-output-stream-string out) removed t)))
                 (setf cursor (+ end 3)))))
    (write-string text out :start cursor)
    (values (get-output-stream-string out) removed nil)))

(defun strip-html-comments (markdown &key (render #'render-markdown))
  "MARKDOWN with every HTML comment, from `<!--' to the next `-->', removed, except a comment
that RENDER, klio's renderer by default, shows inside <code> (see the commentary at the top of
this file). `\\<!--', which Markdown writes as literal text, is not a comment.

A comment that is never closed removes everything after its `<!--', so a note is not published
because its end was forgotten. The second value is true in that case, for the loader to warn."
  (when (some #'%marker-char-p markdown)
    (multiple-value-bind (text removed unclosed) (%strip-pass markdown nil)
      (declare (ignore removed))
      (return-from strip-html-comments (values text unclosed))))
  ;; Each pass removes at least one comment or ends the loop, so there is at most one pass more
  ;; than there are comments.
  (let ((text markdown)
        (unclosed nil))
    (loop for openings = (%comment-openings text)
          while openings
          do (multiple-value-bind (next removed gone)
                 (%strip-pass text (%comments-in-code (funcall render (%marked text openings))
                                                      (length openings)))
               (when gone (setf unclosed t))
               (when (zerop removed) (return))
               (setf text next)))
    (values text unclosed)))
