;;;; results.lisp --- tool results kept outside the prompt, read back by handle (#319).
;;;;
;;;; In an agent that calls tools repeatedly, tool results soon make up most of the prompt, and
;;;; most of them stop mattering a few steps after they arrive. The turn loop (actor.lisp) can
;;;; keep a result here and put a short stand-in in the conversation instead, and the agent reads
;;;; the part it needs back with the `read-result' means. This file is the store and the pure
;;;; functions that read a stored text; actor.lisp decides when a result is stored, offloaded or
;;;; cleared.
;;;;
;;;; WHAT IS READ BACK IS THE STORED TEXT EXACTLY. A range of lines or characters is a SUBSEQ of
;;;; the text the tool returned, never a summary, so anything the agent quotes from it is what
;;;; the tool said.
;;;;
;;;; CHARACTERS, NOT BYTES. #319 asks for ranges of lines or bytes. A byte range of UTF-8 text can
;;;; begin or end inside a character, and the part of a character that falls inside the range is
;;;; not text at all, so it could not be returned exactly as a string. A character range can be.
;;;;
;;;; RESULTS BELONG TO A CONVERSATION and are erased with it (#150): a fetched page or a record
;;;; can hold personal data. Every read names the conversation, so a handle from one
;;;; conversation reads nothing in another. FORGET-CONVERSATION-RESULTS erases them all.

(in-package #:praxeon/results)

;;; --- a stored result -------------------------------------------------------

(defstruct (stored-result (:constructor make-stored-result
                              (&key handle conversation name arguments text created-at)))
  "One tool result as stored. HANDLE names it within CONVERSATION. NAME is the means that
produced it and ARGUMENTS the arguments it was called with, as the model sent them. TEXT is the
result exactly as the means returned it. CREATED-AT is universal time."
  handle conversation name arguments text created-at)

;;; --- the protocol ----------------------------------------------------------

(defclass result-store () ()
  (:documentation "Where tool results are kept outside the prompt. MAKE-MEMORY-RESULT-STORE is
the one in this system; praxeon/results-db keeps them in a database through mnemosyne."))

(defgeneric put-result (store conversation name arguments text)
  (:documentation "Keep TEXT, the result of the means NAME called with ARGUMENTS, in
CONVERSATION (a non-empty string). Returns the new result's handle, a string."))

(defgeneric find-result (store conversation handle)
  (:documentation "The STORED-RESULT HANDLE names in CONVERSATION, or NIL. A handle from another
conversation finds nothing."))

(defgeneric forget-conversation-results (store conversation)
  (:documentation "Erase every result kept for CONVERSATION. Returns how many were erased."))

(defun new-handle ()
  "A new result handle: \"res-\" and 16 random hex digits. Random rather than counted, so that two
processes writing to one database store do not both issue the same handle."
  (format nil "res-~(~{~2,'0x~}~)" (coerce (ironclad:random-data 8) 'list)))

(defun %check-conversation (conversation)
  (unless (and (stringp conversation) (plusp (length conversation)))
    (error "praxeon/results: a conversation must be a non-empty string, not ~S" conversation))
  conversation)

;;; --- the in-memory store ---------------------------------------------------

(defclass memory-result-store (result-store)
  ((by-conversation :initform (make-hash-table :test #'equal) :reader %by-conversation)
   (lock :initform (bt:make-lock "praxeon-results") :reader %lock))
  (:documentation "Results in this process's memory, gone when the process ends. Safe to share
between threads."))

(defun make-memory-result-store ()
  "A new, empty MEMORY-RESULT-STORE."
  (make-instance 'memory-result-store))

(defmethod put-result ((store memory-result-store) conversation name arguments text)
  (%check-conversation conversation)
  (check-type text string)
  (let ((handle (new-handle)))
    (bt:with-lock-held ((%lock store))
      (let ((table (or (gethash conversation (%by-conversation store))
                       (setf (gethash conversation (%by-conversation store))
                             (make-hash-table :test #'equal)))))
        (setf (gethash handle table)
              (make-stored-result :handle handle :conversation conversation :name name
                                  :arguments arguments :text text
                                  :created-at (get-universal-time)))))
    handle))

(defmethod find-result ((store memory-result-store) conversation handle)
  (bt:with-lock-held ((%lock store))
    (let ((table (gethash conversation (%by-conversation store))))
      (and table (gethash handle table)))))

(defmethod forget-conversation-results ((store memory-result-store) conversation)
  (bt:with-lock-held ((%lock store))
    (let ((table (gethash conversation (%by-conversation store))))
      (remhash conversation (%by-conversation store))
      (if table (hash-table-count table) 0))))

;;; --- reading a stored text -------------------------------------------------

(defun line-starts (text)
  "The character position where each line of TEXT begins, in order. A line ends after a newline,
which belongs to it; the last line may have none."
  (cons 0 (loop for i from 0 below (length text)
                when (and (char= (char text i) #\Newline) (< (1+ i) (length text)))
                  collect (1+ i))))

(defun line-count (text)
  "How many lines TEXT has. The empty text has none."
  (if (zerop (length text)) 0 (length (line-starts text))))

(defun lines-of (text first last)
  "Lines FIRST to LAST of TEXT, counted from 1 and inclusive, as the exact characters of TEXT that
hold them, newlines included. LAST beyond the end is the end. Returns the text and the line
range actually covered, or NIL and NIL when FIRST is past the end."
  (let* ((starts (coerce (line-starts text) 'vector))
         (n (line-count text)))
    (unless (and (integerp first) (<= 1 first))
      (error "praxeon/results: the first line must be a positive integer, not ~S" first))
    (unless (and (integerp last) (<= first last))
      (error "praxeon/results: the last line must be an integer no smaller than ~D, not ~S"
             first last))
    (if (> first n)
        (values nil nil)
        (let ((last (min last n)))
          (values (subseq text (aref starts (1- first))
                          (if (< last n) (aref starts last) (length text)))
                  (list first last))))))

(defun characters-of (text start end)
  "Characters START (inclusive, from 0) to END (exclusive) of TEXT, exactly. END beyond the end
is the end."
  (unless (and (integerp start) (<= 0 start))
    (error "praxeon/results: the start must be a non-negative integer, not ~S" start))
  (unless (and (integerp end) (<= start end))
    (error "praxeon/results: the end must be an integer no smaller than ~D, not ~S" start end))
  (subseq text (min start (length text)) (min end (length text))))

(defun search-lines (text needle &key (limit 20) case-sensitive)
  "The lines of TEXT that contain NEEDLE, as a list of (LINE-NUMBER . LINE), in order, at most
LIMIT of them, and as a second value how many lines matched in all. LINE is the line's exact
text without its newline. Case is ignored unless CASE-SENSITIVE."
  (check-type needle string)
  (when (zerop (length needle))
    (error "praxeon/results: the string to search for is empty"))
  (let ((test (if case-sensitive #'char= #'char-equal))
        (found '())
        (total 0))
    (loop for start in (line-starts text)
          for number from 1
          for end = (or (position #\Newline text :start start) (length text))
          do (when (search needle text :start2 start :end2 end :test test)
               (incf total)
               (when (< (length found) limit)
                 (push (cons number (subseq text start end)) found))))
    (values (nreverse found) total)))
