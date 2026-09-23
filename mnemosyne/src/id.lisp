;;;; id.lisp --- entity stamping over aion/clock (effectful CL shell).
;;;;
;;;; The clock is NOT here any more. The monotonic Gregorian-100ns counter and the v6
;;;; assembly moved to aion/clock (pre-publication issue 96): the sortability of an id comes from a clock, a
;;;; clock is a floor primitive, and requiring a data layer in order to obtain one is the
;;;; coupling aion exists to prevent. NEW-ID, NEXT-VID and VID->INSTANT are re-exported
;;;; from there by the package definition, so every existing call site is untouched.
;;;;
;;;; What stays is what is actually about rows: NEW-STAMP, which packages an identity as a
;;;; typed mnemosyne/entity STAMP, and TOUCH!, the dynamic hash-table "universal object"
;;;; analog of Clojure's touch! -- whose _id / vid / utc-time-* keys are mnemosyne's entity
;;;; metadata convention. The typed, pure counterpart is mnemosyne/entity:touch.

(in-package #:mnemosyne/id)

(defun new-stamp ()
  "A fresh identity as a Coalton STAMP (mnemosyne/entity) for the typed, pure TOUCH."
  (multiple-value-bind (uuid vid instant) (clock:new-id)
    (entity:make-stamp uuid vid instant)))

;;; --- the Clojure-style dynamic touch! (a hash-table "universal object") ---
(defun touch! (entity &optional (who "System"))
  "Stamp ENTITY -- a hash-table with keyword keys, the CL analog of a Clojure map -- with
identity + audit metadata, mirroring MPP's touch!. No :_id yet => CREATE (full stamp: _id,
vid, utc-time-created/modified, created-by, modified-by). Has an :_id => UPDATE (new vid +
utc-time-modified + modified-by, preserving _id/created). MUTATES and returns ENTITY (the CL
idiom for a `!` op; copy the table first if you want Clojure's persistent semantics -- or use
the pure mnemosyne/entity:touch on a typed DTO struct)."
  (multiple-value-bind (uuid vid instant) (clock:new-id)
    (cond
      ((gethash :_id entity)                                  ; UPDATE
       (setf (gethash :vid entity) vid
             (gethash :utc-time-modified entity) instant
             (gethash :modified-by entity) who))
      (t                                                      ; CREATE
       (setf (gethash :_id entity) uuid
             (gethash :vid entity) vid
             (gethash :utc-time-created entity) instant
             (gethash :utc-time-modified entity) instant
             (gethash :created-by entity) who
             (gethash :modified-by entity) who)))
    entity))
