;;;; bench/recall-scan.lisp --- how long praxeon/memory-db's RECALL-SIMILAR takes on SQLite (#425).
;;;;
;;;;   sbcl --dynamic-space-size 4096 --non-interactive --load praxeon/bench/recall-scan.lisp
;;;;
;;;; On SQLite, RECALL-SIMILAR reads the subject's current observations with their embeddings and
;;;; ranks them by cosine distance in Lisp: an exact scan over one subject. This measures it for one
;;;; subject holding N observations, at the sizes in *SIZES*, with 1024-wide vectors, in a fresh
;;;; SQLite file in the temporary directory, deleted afterwards. The observations are written through
;;;; MEM:REMEMBER, the way an app writes them, with an embedder that returns a random vector, and a
;;;; second subject holds as many again, which the scan has to filter out. It prints the median and
;;;; the slowest of the timed RECALL-SIMILAR calls (limit 20), after warm-up calls.
;;;;
;;;; It uses only the store's API, so the same file measures a build from before #425's step 1.
;;;; Not part of any suite: its numbers depend on the host.

(ql:quickload '(:praxeon/memory-db) :silent t)

(defpackage #:praxeon/bench/recall-scan
  (:use #:cl)
  (:local-nicknames (#:mdb #:praxeon/memory-db)
                    (#:mem #:praxeon/memory)
                    (#:llm #:praxeon/llm)
                    (#:conn #:mnemosyne/conn)
                    (#:be #:mnemosyne/backend)))

(in-package #:praxeon/bench/recall-scan)

(defparameter *width* 1024)
(defparameter *sizes* '(1000 5000 20000))
(defparameter *warm-up* 3)
(defparameter *runs* 21)

(defclass random-embedder (llm:embedding-provider)
  ((state :initform (sb-ext:seed-random-state 425) :reader embedder-state)))
(defmethod llm:embedding-dimensions ((p random-embedder)) *width*)
(defmethod llm:embedding-model-of ((p random-embedder)) "bench")
(defmethod llm:embed ((p random-embedder) text)
  (declare (ignore text))
  (let ((v (make-array *width* :element-type 'double-float)))
    (dotimes (i *width* v) (setf (aref v i) (- (random 2d0 (embedder-state p)) 1d0)))))

(defun median (xs) (let ((s (sort (copy-list xs) #'<))) (nth (floor (length s) 2) s)))

(defun measure (c n)
  (let* ((table (format nil "bench_recall_~D" n))
         (embedder (make-instance 'random-embedder))
         (store (mdb:make-db-memory-store c :embedder embedder :table table :dialect :sqlite :ensure t))
         (provenance (mem:make-provenance "bench" 1))
         (query (llm:embed embedder "query"))
         (fill-start (get-internal-real-time)))
    (dolist (subject '("measured" "other"))
      (dotimes (i n)
        (mem:remember store subject (format nil "Observation ~D about ~A." i subject) :provenance provenance)))
    (let ((fill-seconds (/ (- (get-internal-real-time) fill-start) internal-time-units-per-second)))
      (dotimes (i *warm-up*) (mem:recall-similar store "measured" query :limit 20 :budget 100000))
      (let ((times (loop repeat *runs*
                         collect (let ((start (get-internal-real-time)))
                                   (mem:recall-similar store "measured" query :limit 20 :budget 100000)
                                   (/ (* 1000.0 (- (get-internal-real-time) start))
                                      internal-time-units-per-second)))))
        (format t "~&N=~D observations for the subject (~D in the table), width ~D, SQLite~%"
                n (* 2 n) *width*)
        (format t "  recall-similar, ~D timed runs: median ~,1F ms, slowest ~,1F ms~%"
                *runs* (median times) (reduce #'max times))
        (format t "  returned ~D observations; writing them took ~,1F s~%"
                (length (mem:recall-similar store "measured" query :limit 20 :budget 100000))
                fill-seconds)))))

(let* ((file (namestring (merge-pathnames (format nil "praxeon-bench-recall-~36R.db"
                                                  (random (expt 2 40) (make-random-state t)))
                                          (uiop:temporary-directory))))
       (c (conn:connect (be:make-sqlite file))))
  (unwind-protect
       (progn
         (format t "~&SQLite ~A~%" (mnemosyne/sqlite-library:describe-loaded-library))
         (dolist (n *sizes*) (measure c n)))
    (conn:disconnect c)
    (dolist (suffix '("" "-journal" "-wal" "-shm"))
      (let ((f (probe-file (concatenate 'string file suffix)))) (when f (delete-file f))))))
