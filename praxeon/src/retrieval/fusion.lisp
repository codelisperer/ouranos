;;;; retrieval/fusion.lisp --- reciprocal rank fusion, the merge of two rankings (#316).
;;;;
;;;; Hybrid retrieval ranks a corpus's chunks twice, by embedding similarity and by BM25, and
;;;; merges the two rankings here. Reciprocal rank fusion gives each chunk the sum, over the
;;;; rankings it appears in, of 1 / (K + its rank), counting ranks from 1; a chunk missing from a
;;;; ranking gets nothing from it. K = 60 is the usual constant and #316's. The merge uses only
;;;; ranks, so a similarity distance and a BM25 score, which are on unrelated scales, never have
;;;; to be compared.
;;;;
;;;; Pure, and in Coalton as #316 asks. The CL shell calls FUSED-IDS and FUSED-SCORES with chunk
;;;; ids, strings, and gets back a list of strings and a list of doubles, the two
;;;; representations Coalton promises across the boundary (docs/coalton-patterns.md §7).
;;;;
;;;; THE ORDER IS TOTAL. Chunks with equal scores are ordered by where they first appear,
;;;; reading the rankings in the order given and each from its top. COALTON/LIST:SORTBY wraps
;;;; CL:SORT, which is not stable, so the tie-break is part of the comparison rather than left to
;;;; the sort.

(cl:in-package #:praxeon/retrieval/fusion)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  (declare %reciprocal (UFix -> F64))
  (define (%reciprocal n)
    (lisp (-> F64) (n) (cl:/ 1d0 n)))

  (declare %first-occurrences ((List String) -> (List String)))
  (define (%first-occurrences xs)
    "XS without repeats, each kept where it first appears."
    (list:reverse
     (fold (fn (acc x) (if (list:member x acc) acc (Cons x acc)))
           Nil
           xs)))

  (declare rrf-score (UFix * (List (List String)) * String -> F64))
  (define (rrf-score k rankings id)
    "ID's reciprocal-rank-fusion score over RANKINGS: the sum of 1 / (K + rank), ranks counted
from 1, over the rankings that contain ID. Its first position counts if a ranking repeats it."
    (fold (fn (acc ranking)
            (match (list:elemIndex id ranking)
              ((Some position) (+ acc (%reciprocal (+ k (+ position 1)))))
              ((None) acc)))
          0
          rankings))

  (declare %position (String * (List String) -> UFix))
  (define (%position id ids)
    (match (list:elemIndex id ids)
      ((Some i) i)
      ((None) 0)))

  (declare %fused ((List (List String)) * UFix -> (List (Tuple String F64))))
  (define (%fused rankings k)
    (let ((ids (%first-occurrences (list:concat rankings))))
      (list:sortBy
       (fn (a b)
         (match (Tuple a b)
           ((Tuple (Tuple id-a score-a) (Tuple id-b score-b))
            (if (== score-a score-b)
                (<=> (%position id-a ids) (%position id-b ids))
                (<=> score-b score-a)))))
       (map (fn (id) (Tuple id (rrf-score k rankings id))) ids))))

  (declare fused-ids (UFix * (List (List String)) -> (List String)))
  (define (fused-ids k rankings)
    "Every id in RANKINGS once, best fused score first. See the file header for ties."
    (map fst (%fused rankings k)))

  (declare fused-scores (UFix * (List (List String)) -> (List F64)))
  (define (fused-scores k rankings)
    "The fused scores of FUSED-IDS, in the same order."
    (map snd (%fused rankings k))))
