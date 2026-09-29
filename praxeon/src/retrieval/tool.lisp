;;;; retrieval/tool.lisp --- a means an agent calls to search a corpus (#138).
;;;;
;;;; REGISTER-CORPUS-SEARCH registers one means on an agent. The model passes a QUERY, and, when
;;;; the app gave an embedder, a MATCH of "meaning" or "words":
;;;;
;;;;   "meaning"  RETRIEVE, which follows the corpus's strategy (#316): the whole corpus while
;;;;              it is :WHOLE, and hybrid search once it is :HYBRID. The default.
;;;;   "words"    RETRIEVE-EXACT, with every word of the query required. The only kind offered
;;;;              when the app has no embedder, and it needs none.
;;;;
;;;; What the model reads is each passage as the app's RENDER function writes it, through
;;;; PASSAGE->CTX-ITEM, in the order the retrieval returned them, followed by one sentence when
;;;; the result is TRUNCATED. praxeon does not choose how a citation is written, so RENDER is
;;;; required. The passage's distance is never shown: it means something only relative to other
;;;; distances from the same model, and the order already carries it.
;;;;
;;;; ON-RESULT, when given, is called with the query and the RETRIEVAL-RESULT before the model sees
;;;; anything, so an app can keep the provenance of what the model was shown and cite from it.

(in-package #:praxeon/retrieval)

(defparameter *search-description*
  "Search a collection of documents for passages relevant to a question or topic. Returns the
matching passages, each with where it comes from. Search again with other words if the
passages do not answer the question."
  "The description REGISTER-CORPUS-SEARCH gives the model when the app passes none. An app
should pass one that names what the collection holds.")

(defun %words (query)
  "The words of QUERY, split at whitespace."
  (let ((words '()) (start nil))
    (loop for i from 0 to (length query)
          for ch = (and (< i (length query)) (char query i))
          do (if (and ch (not (member ch '(#\Space #\Tab #\Newline #\Return #\Page))))
                 (unless start (setf start i))
                 (when start
                   (push (subseq query start i) words)
                   (setf start nil))))
    (nreverse words)))

(defun %search-schema (with-meaning)
  "The means' argument schema: a required QUERY, and a MATCH of \"meaning\" or \"words\" when
WITH-MEANING."
  (let ((props (make-hash-table :test 'equal))
        (schema (make-hash-table :test 'equal))
        (query (make-hash-table :test 'equal)))
    (setf (gethash "type" query) "string"
          (gethash "description" query) "What to look for: a question, a term, or a phrase.")
    (setf (gethash "query" props) query)
    (when with-meaning
      (let ((match (make-hash-table :test 'equal)))
        (setf (gethash "type" match) "string"
              (gethash "enum" match) (vector "meaning" "words")
              (gethash "description" match)
              "\"meaning\" (the default) finds passages about the query even when they use other words. \"words\" finds passages containing every word of the query, ignoring case: use it for a defined term, a name or a number.")
        (setf (gethash "match" props) match)))
    (setf (gethash "type" schema) "object"
          (gethash "properties" schema) props
          (gethash "required" schema) (vector "query"))
    schema))

(defun %completeness-note (result)
  "One sentence for the model when RESULT is TRUNCATED, or NIL when it is COMPLETE.

:NOT-EMBEDDED and :NOT-INDEXED get the same sentence. Both come only from a search by meaning
(RETRIEVE), since without an embedder the means offers only \"words\"; and a hybrid result's
PENDING counts every chunk missing either an embedding or its terms (#316), so a sentence
naming one of the two would overstate. A search by words is RETRIEVE-EXACT, which needs
neither. A reason added later gets a general sentence rather than failing the call."
  (let ((c (retrieval-result-completeness result)))
    (when (truncated-p c)
      (case (truncated-reason c)
        (:limit "More passages matched than are shown here. A narrower query would show others.")
        ((:not-embedded :not-indexed)
         (format nil "~D part~:P of this collection could not be searched by meaning yet, so this result may be missing passages. A search with \"match\": \"words\" covers every part."
                 (truncated-pending c)))
        (t "Not every part of this collection could be searched, so this result may be missing passages.")))))

(defun %search-text (result render)
  "What the model reads for RESULT: each passage as RENDER writes it, in order, then the
completeness note."
  (let ((texts (mapcar (lambda (p) (ctx:ctx-item-content (passage->ctx-item p render)))
                       (retrieval-result-passages result)))
        (note (%completeness-note result)))
    (format nil "~:[No passages matched.~;~:*~{~A~^~%~%~}~]~@[~%~%~A~]" texts note)))

(defun %argument (args name)
  (and (hash-table-p args) (gethash name args)))

(defun register-corpus-search (agent corpus embedder render
                               &key (name "search-documents") (description *search-description*)
                                    limit capability on-result reranker)
  "Register on AGENT a means NAME that searches CORPUS and returns the matching passages as text
for the model. Returns NAME.

EMBEDDER is an embedding provider, or NIL when the app has none; with NIL the means offers only
a search by words. RENDER is a function from a PASSAGE to the string the model reads, and is
required. LIMIT caps the passages returned, and NIL leaves it to RETRIEVE and RETRIEVE-EXACT.
CAPABILITY is passed to REGISTER-MEANS. ON-RESULT, a function of the query and the
RETRIEVAL-RESULT, is called before the text is returned. RERANKER, a PRAXEON/LLM:RERANKER, is
passed to RETRIEVE for a search by meaning (#316).

A failed search signals, as any means does, so ACT's restarts apply."
  (check-type corpus corpus)
  (unless (functionp render)
    (error "praxeon/retrieval: REGISTER-CORPUS-SEARCH needs RENDER, a function from a passage to the text the model reads; ~S is not one"
           render))
  (unless (or (null limit) (typep limit '(integer 1)))
    (error "praxeon/retrieval: :limit must be a positive integer or NIL, not ~S" limit))
  (unless (or (null on-result) (functionp on-result))
    (error "praxeon/retrieval: :on-result must be a function or NIL, not ~S" on-result))
  (unless (or (null reranker) (typep reranker 'llm:reranker))
    (error "praxeon/retrieval: :reranker must be a PRAXEON/LLM:RERANKER or NIL, not ~S" reranker))
  (let ((limit-args (append (and limit (list :limit limit))
                            (and reranker (list :reranker reranker)))))
    (actor:register-means
     agent name description
     (lambda (args)
       (let ((query (%argument args "query"))
             (match (or (%argument args "match") "meaning")))
         (unless (and (stringp query) (%words query))
           (error "praxeon/retrieval: the ~A means needs a non-empty \"query\" string, not ~S"
                  name query))
         (let ((result
                 (cond ((and embedder (equal match "meaning"))
                        (apply #'retrieve corpus embedder query limit-args))
                       ((or (equal match "words") (null embedder))
                        (apply #'retrieve-exact corpus (%words query)
                               (and limit (list :limit limit))))
                       (t (error "praxeon/retrieval: the ~A means takes a \"match\" of \"meaning\" or \"words\", not ~S"
                                 name match)))))
           (when on-result (funcall on-result query result))
           (%search-text result render))))
     :schema (%search-schema (and embedder t))
     :capability capability)))
