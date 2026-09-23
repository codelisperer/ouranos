;;;; search.lisp --- the in-memory search index.
;;;;
;;;; Part 2 item 6 of #359: tokenised, field-weighted, no stemming, built at load.
;;;;
;;;; WHAT THIS IS NOT. It is not a ranking engine and does not try to be. Three sites of prose
;;;; is a corpus of a few hundred documents, and the useful question is "which pages mention
;;;; this word", answered fast enough that the box feels instant. Stemming, phrase queries and
;;;; relevance tuning are a later decision, and a bad one to guess at now.
;;;;
;;;; It holds no content. A document is identified by a key the caller chooses, so the index
;;;; does not have to know what a page is -- which is #359 Q1 and is not ruled.

(in-package #:klio)

(defparameter *field-weights* '((:title . 8) (:tags . 4) (:body . 1))
  "How much a hit in each field is worth. Title over tags over body, which is the order a
reader would rank them in themselves.")

(defun tokenize (text)
  "TEXT as a list of downcased word tokens.

Splits on anything that is not a letter or a digit, so punctuation, markdown syntax and
hyphens all separate. `hot-reload' therefore indexes as `hot' and `reload' and is found by
either, which is what someone typing into a search box expects."
  (let ((tokens '()) (current (make-string-output-stream)))
    (flet ((flush ()
             (let ((word (get-output-stream-string current)))
               (when (plusp (length word)) (push (string-downcase word) tokens)))))
      (loop for ch across text
            do (if (alphanumericp ch) (write-char ch current) (flush)))
      (flush))
    (nreverse tokens)))

(defstruct (search-index (:constructor %make-search-index))
  (table (make-hash-table :test #'equal) :read-only t))

(defun make-search-index ()
  "An empty index. Built at load and replaced wholesale, never mutated in place while a
request might be reading it -- the same all-or-nothing rule as the content tree (ADR-0001)."
  (%make-search-index))

(defun index-document (index key &key title tags body)
  "Add one document to INDEX under KEY. TAGS is a list of strings.

Called once per document at load. A key indexed twice accumulates, so callers building a
fresh index for a fresh tree get no residue from the old one."
  (loop for (field . weight) in *field-weights*
        for text = (ecase field
                     (:title (or title ""))
                     (:tags (format nil "~{~A~^ ~}" (or tags '())))
                     (:body (or body "")))
        do (dolist (token (tokenize text))
             (let* ((postings (gethash token (search-index-table index)))
                    (existing (assoc key postings :test #'equal)))
               (if existing
                   (incf (cdr existing) weight)
                   (setf (gethash token (search-index-table index))
                         (cons (cons key weight) postings))))))
  index)

(defun search-index-query (index query)
  "Keys matching QUERY, best first.

Every token must match -- an AND, not an OR. Searching two words and getting pages that
contain either is the behaviour people complain about, and with a corpus this size the narrow
answer is almost always the wanted one. Score is the sum of the field weights across tokens."
  (let ((tokens (tokenize query)))
    (if (null tokens)
        '()
        (let ((scores (make-hash-table :test #'equal))
              (seen (make-hash-table :test #'equal)))
          (dolist (token tokens)
            (dolist (posting (gethash token (search-index-table index)))
              (incf (gethash (car posting) scores 0) (cdr posting))
              (push token (gethash (car posting) seen))))
          (let ((hits '()))
            (maphash (lambda (key score)
                       ;; every token, not any: the count of DISTINCT tokens that hit this
                       ;; key has to equal the number of tokens asked for.
                       (when (= (length (remove-duplicates (gethash key seen) :test #'string=))
                                (length (remove-duplicates tokens :test #'string=)))
                         (push (cons key score) hits)))
                     scores)
            (mapcar #'car (sort hits #'> :key #'cdr)))))))
