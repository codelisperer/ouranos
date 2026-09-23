;;;; entity.lisp --- typed entity metadata: the DTO trait + pure touch (Coalton core).
;;;;
;;;; The typesafe half of the MPP db/core port. An entity carries METADATA (id, version,
;;;; timestamps, audit) -- in Clojure that was assoc'd onto any map; here a DTO typeclass
;;;; makes it compile-time-checked: only a type that implements DTO can be touched, and
;;;; TOUCH is a pure function (create vs update) that returns an updated value. The fresh
;;;; identity comes from the CL shell as a STAMP (mnemosyne/id:new-stamp); this core never
;;;; does IO. The dynamic, hash-table "universal object" variant (touch!) lives in
;;;; mnemosyne/id for code that isn't a typed struct.

(cl:in-package #:mnemosyne/entity)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- a freshly generated identity (built by the CL shell) --------------
  (define-type Stamp
    "One fresh time-ordered identity from mnemosyne/id:new-stamp: the v6 UUID string, its
monotonic VID (the UUID's embedded Gregorian-100ns timestamp -- a version/serial), and the
UTC INSTANT (ISO-8601). IO produces it; the pure TOUCH applies it."
    (Stamp String Integer String))            ; uuid, vid, instant

  (declare stamp-uuid (Stamp -> String))
  (define (stamp-uuid s) (match s ((Stamp u _ _) u)))
  (declare stamp-vid (Stamp -> Integer))
  (define (stamp-vid s) (match s ((Stamp _ v _) v)))
  (declare stamp-instant (Stamp -> String))
  (define (stamp-instant s) (match s ((Stamp _ _ i) i)))

  ;; CL-facing constructor: mnemosyne/id builds a STAMP from CL scalars.
  (declare make-stamp (String * Integer * String -> Stamp))
  (define (make-stamp uuid vid instant) (Stamp uuid vid instant))

  ;;; --- the metadata touch stamps onto an entity --------------------------
  (define-type Meta
    "What TOUCH records on an entity: _id (uuid), VID (version = the monotonic timestamp),
UTC created/modified instants, and created-by/modified-by audit."
    (Meta String Integer String String String String))
    ;;   id     vid     created modified created-by modified-by

  (declare meta-id (Meta -> String))
  (define (meta-id m) (match m ((Meta x _ _ _ _ _) x)))
  (declare meta-vid (Meta -> Integer))
  (define (meta-vid m) (match m ((Meta _ x _ _ _ _) x)))
  (declare meta-created (Meta -> String))
  (define (meta-created m) (match m ((Meta _ _ x _ _ _) x)))
  (declare meta-modified (Meta -> String))
  (define (meta-modified m) (match m ((Meta _ _ _ x _ _) x)))
  (declare meta-created-by (Meta -> String))
  (define (meta-created-by m) (match m ((Meta _ _ _ _ x _) x)))
  (declare meta-modified-by (Meta -> String))
  (define (meta-modified-by m) (match m ((Meta _ _ _ _ _ x) x)))

  ;; CL-facing constructor + total accessors above (read a Meta back into the CL shell).
  (declare make-meta (String * Integer * String * String * String * String -> Meta))
  (define (make-meta id vid created modified created-by modified-by)
    (Meta id vid created modified created-by modified-by))

  ;;; --- the DTO trait: "carries entity metadata, typesafely" --------------
  (define-class (DTO :a)
    "A type that carries entity metadata. GET-META is None until first touch; WITH-META
returns a copy with META set. Implement it for any struct with a meta slot to make the
type touchable -- the compile-time-checked upgrade over Clojure's assoc-onto-any-map."
    (get-meta (:a -> (Optional Meta)))
    (with-meta (:a * Meta -> :a)))

  ;;; --- pure touch: create vs update --------------------------------------
  (declare touch ((DTO :a) => Stamp * String * :a -> :a))
  (define (touch stamp who entity)
    "Stamp ENTITY with a fresh identity from STAMP, attributed to WHO. If it already carries
Meta it is an UPDATE -- bump the version (new vid + modified instant/by) while preserving
_id, created instant, and created-by. Otherwise a CREATE -- full stamp. Pure: returns an
updated entity, never mutates. (Fixes the MPP original's create-branch bug that dropped the
uuid into _id as an empty string.)"
    (match (get-meta entity)
      ((Some m)
       (with-meta entity
         (Meta (meta-id m) (stamp-vid stamp) (meta-created m)
               (stamp-instant stamp) (meta-created-by m) who)))
      ((None)
       (with-meta entity
         (Meta (stamp-uuid stamp) (stamp-vid stamp) (stamp-instant stamp)
               (stamp-instant stamp) who who))))))
