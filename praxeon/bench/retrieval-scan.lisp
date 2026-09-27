;;;; bench/retrieval-scan.lisp --- how long RETRIEVE-SIMILAR's exact scan takes (#138).
;;;;
;;;;   MNEMOSYNE_TEST_PG_URL=postgres://... \
;;;;   sbcl --dynamic-space-size 4096 --non-interactive --load praxeon/bench/retrieval-scan.lisp
;;;;
;;;; The first build of praxeon/retrieval compares a query with every chunk of a corpus, with
;;;; no vector index (#138, ruling 5857190973). This measures that scan at the sizes the first
;;;; app expects, so the size at which an index becomes necessary is a measured figure.
;;;;
;;;; For each corpus size N it makes a fresh table holding two corpora of N chunks each, one
;;;; measured and one that only has to be filtered out, with random 1024-wide vectors. Then it
;;;; runs the real RETRIEVE-SIMILAR (limit 10) with an embedder that returns a fixed query
;;;; vector, so the time is the database's and not a provider's. It prints the median and the
;;;; slowest of the timed runs, after warm-up runs, and Postgres's own execution time for the
;;;; main query from EXPLAIN ANALYZE, with the plan's top line. The table is dropped afterwards.
;;;;
;;;; Not part of any suite: it takes a minute, and its numbers depend on the host.

(ql:quickload '(:praxeon/retrieval) :silent t)

(defpackage #:praxeon/bench/retrieval-scan
  (:use #:cl)
  (:local-nicknames (#:rt #:praxeon/retrieval)
                    (#:llm #:praxeon/llm)
                    (#:conn #:mnemosyne/conn)
                    (#:url #:mnemosyne/url)
                    (#:mig #:mnemosyne/migrate)
                    (#:param #:mnemosyne/param)))

(in-package #:praxeon/bench/retrieval-scan)

(defparameter *width* 1024)
(defparameter *sizes* '(2400 10000))
(defparameter *warm-up* 3)
(defparameter *runs* 21)

(defclass fixed-embedder (llm:embedding-provider)
  ((vector :initarg :vector :reader fixed-vector)))
(defmethod llm:embedding-dimensions ((p fixed-embedder)) *width*)
(defmethod llm:embedding-model-of ((p fixed-embedder)) "bench")
(defmethod llm:embed ((p fixed-embedder) text)
  (declare (ignore text))
  (fixed-vector p))

(defun random-vector (state)
  (let ((v (make-array *width* :element-type 'double-float)))
    (dotimes (i *width* v) (setf (aref v i) (- (random 2d0 state) 1d0)))))

(defun vector-literal (v)
  (with-output-to-string (s)
    (write-char #\[ s)
    (loop for i below (length v)
          do (when (plusp i) (write-char #\, s))
             (format s "~,6F" (aref v i)))
    (write-char #\] s)))

(defun fill-corpus (c table corpus n deriver state)
  "N chunks for CORPUS, embedded, inserted 200 rows per statement."
  (loop for start from 0 below n by 200
        do (conn:exec c (with-output-to-string (s)
                          (format s "INSERT INTO ~A (id, corpus, section_id, locale, chunk_index, document_id, locale_role, chunker, boundary, text, section_fingerprint, embedding, embedding_fingerprint, embedding_deriver) VALUES " table)
                          (loop for i from start below (min n (+ start 200))
                                do (when (> i start) (write-string ", " s))
                                   (format s "('~A-~D', '~A', 's~D', 'en', 0, 'd~D', 'source', 'section/1', 'whole-section', 'Section ~D of ~A, with some ordinary words in it.', 'fp', '~A', 'efp', '~A')"
                                           corpus i corpus i (floor i 20) i corpus
                                           (vector-literal (random-vector state)) deriver))))))

(defun median (xs) (let ((s (sort (copy-list xs) #'<))) (nth (floor (length s) 2) s)))

(defun measure (c n)
  (let* ((table (format nil "praxeon_bench_scan_~D" n))
         (state (sb-ext:seed-random-state 138))
         (embedder (make-instance 'fixed-embedder :vector (random-vector state)))
         (deriver (rt:deriver-of embedder)))
    (conn:exec c (format nil "DROP TABLE IF EXISTS ~A" table))
    (unwind-protect
         (let* ((store (rt:make-chunk-store c :table table :dimensions *width* :ensure t))
                (corpus (rt:make-corpus store "measured")))
           (fill-corpus c table "measured" n deriver state)
           (fill-corpus c table "other" n deriver state)
           (conn:exec c (format nil "ANALYZE ~A" table))
           (dotimes (i *warm-up*) (rt:retrieve-similar corpus embedder "q" :limit 10))
           (let* ((times (loop repeat *runs*
                               collect (let ((start (get-internal-real-time)))
                                         (rt:retrieve-similar corpus embedder "q" :limit 10)
                                         (/ (* 1000.0 (- (get-internal-real-time) start))
                                            internal-time-units-per-second))))
                  (result (rt:retrieve-similar corpus embedder "q" :limit 10))
                  (plan (mapcar #'second
                                (conn:query c (format nil "EXPLAIN (ANALYZE) SELECT text, embedding <=> '~A' AS distance FROM ~A WHERE corpus = 'measured' AND embedding_deriver = '~A' AND embedding IS NOT NULL ORDER BY distance LIMIT 10"
                                                      (vector-literal (fixed-vector embedder))
                                                      table deriver)))))
             (format t "~&N=~D sections per corpus (~D rows in the table), width ~D~%"
                     n (* 2 n) *width*)
             (format t "  retrieve-similar, ~D timed runs: median ~,1F ms, slowest ~,1F ms~%"
                     *runs* (median times) (reduce #'max times))
             (format t "  returned ~D passages, ~A~%"
                     (length (rt:retrieval-result-passages result))
                     (if (rt:complete-p (rt:retrieval-result-completeness result))
                         "COMPLETE" "TRUNCATED"))
             (format t "  EXPLAIN ANALYZE (lines cut at 150 characters):~%~{    ~A~%~}"
                     (mapcar (lambda (line) (subseq line 0 (min 150 (length line)))) plan))))
      (conn:exec c (format nil "DROP TABLE IF EXISTS ~A" table)))))

(let ((pg (uiop:getenv "MNEMOSYNE_TEST_PG_URL")))
  (unless pg (error "Set MNEMOSYNE_TEST_PG_URL to a Postgres with pgvector."))
  (let ((c (conn:connect (url:backend-from-url pg))))
    (unwind-protect
         (progn
           (mig:require-extension c "vector")
           (format t "~&~A~%pgvector ~A~%"
                   (second (first (conn:query c "SELECT version()")))
                   (second (first (conn:query c "SELECT extversion FROM pg_extension WHERE extname = 'vector'"))))
           (dolist (n *sizes*) (measure c n)))
      (conn:disconnect c))))
