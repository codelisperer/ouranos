;;;; retrieval/terms.lisp --- the tokenizer BM25 keyword search indexes and queries with (#316).
;;;;
;;;; #316 says the tokenizer decides whether BM25 is worth having. What it does:
;;;;
;;;;   - lowercases;
;;;;   - keeps an identifier such as TS-999, PRAXEON_EMBED_MODEL or v1.2.3 whole AND split into
;;;;     its parts, so a query for the whole identifier matches it exactly and a query for one
;;;;     part still finds it. The characters that join an identifier's parts are - _ . / and
;;;;     the apostrophes ' and ’;
;;;;   - drops the stop words of the text's language, when *STOP-WORDS* has a list for it;
;;;;   - drops a term longer than +MAX-TERM-LENGTH+ characters, which is an encoded blob, not a
;;;;     word anyone searches for.
;;;;
;;;; No stemming yet, as #316 allows: "refunds" and "refund" are different terms.
;;;;
;;;; The same function tokenizes a chunk for the index and a query at search time. Changing
;;;; what it does changes +TOKENIZER-ID+, which every chunk records, so the chunks indexed by
;;;; the old version count as not indexed until INDEX-PENDING rewrites them.
;;;;
;;;; Pure: no IO, and nothing here reads the database.

(in-package #:praxeon/retrieval/corpus)

(defparameter +tokenizer-id+ "terms/1"
  "The name and version of TOKENIZE, recorded with every chunk's terms.")

(defparameter +max-term-length+ 64
  "The longest term kept, in characters.")

(defun %joiner-p (ch)
  (member ch '(#\- #\_ #\. #\/ #\' #\RIGHT_SINGLE_QUOTATION_MARK)))

(defun %word-char-p (ch)
  (or (alphanumericp ch) (%joiner-p ch)))

(defparameter +english-stop-words+
  '("a" "about" "above" "after" "again" "against" "all" "am" "an" "and" "any" "are" "as" "at"
    "be" "because" "been" "before" "being" "below" "between" "both" "but" "by"
    "can" "could" "d" "did" "do" "does" "doing" "down" "during"
    "each" "few" "for" "from" "further" "had" "has" "have" "having" "he" "her" "here" "hers"
    "herself" "him" "himself" "his" "how" "i" "if" "in" "into" "is" "it" "its" "itself"
    "just" "ll" "m" "me" "more" "most" "my" "myself" "no" "nor" "not" "now"
    "of" "off" "on" "once" "only" "or" "other" "our" "ours" "ourselves" "out" "over" "own"
    "re" "s" "same" "she" "should" "so" "some" "such" "t" "than" "that" "the" "their" "theirs"
    "them" "themselves" "then" "there" "these" "they" "this" "those" "through" "to" "too"
    "under" "until" "up" "ve" "very" "was" "we" "were" "what" "when" "where" "which" "while"
    "who" "whom" "why" "will" "with" "would" "you" "your" "yours" "yourself" "yourselves")
  "English stop words: pronouns, articles, auxiliaries, prepositions and conjunctions, plus
the fragments an apostrophe leaves (the s of it's, the t of don't).")

(defun %word-set (words)
  (let ((set (make-hash-table :test #'equal)))
    (dolist (w words set) (setf (gethash w set) t))))

(defvar *stop-words* (let ((table (make-hash-table :test #'equal)))
                       (setf (gethash "en" table) (%word-set +english-stop-words+))
                       table)
  "Language subtag (\"en\") -> a set of stop words, as an EQUAL hash table. Only English has a
list so far; text in a language with no entry keeps every word. An app adds a language with
REGISTER-STOP-WORDS.")

(defun register-stop-words (language words)
  "Use WORDS, lowercase strings, as the stop words of LANGUAGE, a language subtag such as
\"es\". Changes what TOKENIZE drops for that language from then on; chunks already indexed
keep their terms until they are indexed again."
  (setf (gethash (string-downcase language) *stop-words*) (%word-set words))
  language)

(defun %language (locale)
  "The language subtag of LOCALE: \"en\" for \"en-GB\" or \"en_GB\". NIL for NIL."
  (and locale
       (string-downcase (subseq locale 0 (or (position-if (lambda (c) (member c '(#\- #\_))) locale)
                                             (length locale))))))

(defun %split-on-joiners (word)
  (loop with start = 0
        for i from 0 to (length word)
        when (or (= i (length word)) (%joiner-p (char word i)))
          when (> i start) collect (subseq word start i) end
          and do (setf start (1+ i))))

(defun tokenize (text &key locale)
  "The terms of TEXT, in order, repeats included, for BM25 (#316). LOCALE, such as \"en\" or
\"en-GB\", chooses the stop words to drop; NIL drops none. See the file header for the rules."
  (let ((stop (and locale (gethash (%language locale) *stop-words*)))
        (terms '()))
    (flet ((keep (term)
             (when (and (plusp (length term))
                        (<= (length term) +max-term-length+)
                        (not (and stop (gethash term stop))))
               (push term terms))))
      (loop with n = (length text)
            with i = 0
            while (< i n)
            do (if (not (%word-char-p (char text i)))
                   (incf i)
                   (let* ((end (or (position-if-not #'%word-char-p text :start i) n))
                          (word (string-downcase
                                 (string-trim '(#\- #\_ #\. #\/ #\' #\RIGHT_SINGLE_QUOTATION_MARK)
                                              (subseq text i end))))
                          (parts (%split-on-joiners word)))
                     (when (rest parts) (keep word))
                     (mapc #'keep parts)
                     (setf i end)))))
    (nreverse terms)))

(defun term-counts (text &key locale)
  "TEXT's terms with how often each occurs, as an alist (term . count) in first-occurrence
order, and as a second value the number of terms in all, which is BM25's document length."
  (let ((counts (make-hash-table :test #'equal))
        (order '())
        (total 0))
    (dolist (term (tokenize text :locale locale))
      (incf total)
      (unless (gethash term counts) (push term order))
      (incf (gethash term counts 0)))
    (values (mapcar (lambda (term) (cons term (gethash term counts))) (nreverse order))
            total)))
