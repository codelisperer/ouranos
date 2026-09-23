;;;; tests/entity.lisp --- fiveam suite for mnemosyne/id + mnemosyne/entity.
;;;;
;;;; Pins the Clojure-style touch! (create/update on a hash-table) and the typed DTO path
;;;; (touch on a struct that implements the trait). The Coalton support type TEST-PERSON
;;;; below is also the reference for implementing DTO on your own type.
;;;;
;;;; The CLOCK's guarantees are no longer tested here: the monotonic counter and the v6
;;;; assembly moved to aion/clock (#96), and so did the tests that hammer them. What
;;;; remains on that front is one check that the seam is a re-export and not a copy.

;;; --- Coalton support: a type that implements the DTO trait -----------------
(cl:defpackage #:mnemosyne/tests-entity
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:e #:mnemosyne/entity))
  (:export #:Test-Person #:mk-person #:touch-person
           #:person-name #:person-touched? #:person-id #:person-vid
           #:person-created-by #:person-modified-by))
(cl:in-package #:mnemosyne/tests-entity)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel
  (define-type Test-Person
    "A struct that carries a name and (once touched) entity Meta."
    (Test-Person String (Optional e:Meta)))

  ;; Implementing DTO is exactly this: say how to read/replace the Meta slot.
  (define-instance (e:DTO Test-Person)
    (define (e:get-meta p) (match p ((Test-Person _ m) m)))
    (define (e:with-meta p meta) (match p ((Test-Person n _) (Test-Person n (Some meta))))))

  ;; A typeclass-constrained function (touch) can't be called from CL directly -- it needs
  ;; the DTO dictionary. Expose a MONOMORPHIC wrapper (resolved at compile time) as the CL
  ;; boundary. This is the pattern a real app writes for its own entity type.
  (declare touch-person (e:Stamp * String * Test-Person -> Test-Person))
  (define (touch-person stamp who p) (e:touch stamp who p))

  ;; CL-facing helpers so the fiveam (CL) tests can build/inspect a person.
  (declare mk-person (String -> Test-Person))
  (define (mk-person n) (Test-Person n None))
  (declare person-name (Test-Person -> String))
  (define (person-name p) (match p ((Test-Person n _) n)))
  (declare person-touched? (Test-Person -> Boolean))
  (define (person-touched? p) (match (e:get-meta p) ((Some _) True) ((None) False)))
  (declare person-id (Test-Person -> String))
  (define (person-id p) (match (e:get-meta p) ((Some m) (e:meta-id m)) ((None) "")))
  (declare person-vid (Test-Person -> Integer))
  (define (person-vid p) (match (e:get-meta p) ((Some m) (e:meta-vid m)) ((None) 0)))
  (declare person-created-by (Test-Person -> String))
  (define (person-created-by p) (match (e:get-meta p) ((Some m) (e:meta-created-by m)) ((None) "")))
  (declare person-modified-by (Test-Person -> String))
  (define (person-modified-by p) (match (e:get-meta p) ((Some m) (e:meta-modified-by m)) ((None) ""))))

;;; --- the fiveam tests (CL) -------------------------------------------------
(cl:in-package #:mnemosyne/tests)

(in-suite mnemosyne)

(defun %v6-p (s)
  "T if S is a canonical v6 UUID string (version nibble 6, variant 8/9/a/b)."
  (and (stringp s) (= (length s) 36)
       (char= (char s 14) #\6)                       ; version
       (member (char s 19) '(#\8 #\9 #\a #\b))))      ; variant

(test the-id-seam-is-aion-clock-itself
  "The clock moved to aion/clock (#96) and its guarantees are tested THERE -- shape,
strict monotonicity under six threads, and v6 lexical sort order. What is mnemosyne's to
prove is that the seam did not become a copy: MNEMOSYNE/ID:NEW-ID must be aion's symbol,
not a forwarding function that could drift from it. EQ on the symbols is the only
assertion that actually says so; calling both and comparing results would pass just as
well against two independent clocks, which is the failure worth catching."
  (is (eq 'mnemosyne/id:new-id 'aion/clock:new-id))
  (is (eq 'mnemosyne/id:next-vid 'aion/clock:next-vid))
  (is (eq 'mnemosyne/id:vid->instant 'aion/clock:vid->instant))
  ;; And it is still callable under the mnemosyne name every consumer uses.
  (multiple-value-bind (uuid vid instant) (mnemosyne/id:new-id)
    (is (%v6-p uuid) "uuid ~S is not a v6" uuid)
    (is (integerp vid))
    (is (stringp instant))))

(test new-stamp-packages-an-identity-for-the-typed-core
  "NEW-STAMP is the part that stayed: it turns aion's three CL scalars into the Coalton
STAMP that mnemosyne/entity:touch consumes."
  (let ((s (mnemosyne/id:new-stamp)))
    (is (%v6-p (mnemosyne/entity:stamp-uuid s)))
    (is (integerp (mnemosyne/entity:stamp-vid s)))
    (is (stringp (mnemosyne/entity:stamp-instant s)))))

;;; --- touch! on a hash-table (the Clojure-style "universal object") ---------
(test touch!-create
  (let ((h (make-hash-table)))
    (mnemosyne/id:touch! h "alice")
    (is (%v6-p (gethash :_id h)))
    (is (integerp (gethash :vid h)))
    (is (stringp (gethash :utc-time-created h)))
    (is (equal "alice" (gethash :created-by h)))
    (is (equal "alice" (gethash :modified-by h)))
    (is (equal (gethash :utc-time-created h) (gethash :utc-time-modified h)))))

(test touch!-update
  (let ((h (make-hash-table)))
    (mnemosyne/id:touch! h "alice")             ; create
    (let ((id0 (gethash :_id h)) (v0 (gethash :vid h)) (c0 (gethash :utc-time-created h)))
      (mnemosyne/id:touch! h "bob")             ; update
      (is (equal id0 (gethash :_id h)) "_id must be preserved on update")
      (is (> (gethash :vid h) v0) "vid must bump on update")
      (is (equal c0 (gethash :utc-time-created h)) "created instant preserved")
      (is (equal "alice" (gethash :created-by h)) "created-by preserved")
      (is (equal "bob" (gethash :modified-by h)) "modified-by updated"))))

(test touch!-default-who
  (let ((h (make-hash-table)))
    (mnemosyne/id:touch! h)
    (is (equal "System" (gethash :created-by h)))))

;;; --- typed touch on a DTO struct (pure, immutable) -------------------------
(test typed-touch-create
  (let* ((p0 (mnemosyne/tests-entity:mk-person "Ann"))
         (p1 (mnemosyne/tests-entity:touch-person (mnemosyne/id:new-stamp) "alice" p0)))
    (is (not (mnemosyne/tests-entity:person-touched? p0)) "touch must not mutate the original")
    (is (mnemosyne/tests-entity:person-touched? p1))
    (is (%v6-p (mnemosyne/tests-entity:person-id p1)))
    (is (equal "alice" (mnemosyne/tests-entity:person-created-by p1)))
    (is (equal "alice" (mnemosyne/tests-entity:person-modified-by p1)))
    (is (equal "Ann" (mnemosyne/tests-entity:person-name p1)) "domain fields preserved")))

(test typed-touch-update
  (let* ((p1 (mnemosyne/tests-entity:touch-person (mnemosyne/id:new-stamp) "alice"
                                                  (mnemosyne/tests-entity:mk-person "Ann")))
         (p2 (mnemosyne/tests-entity:touch-person (mnemosyne/id:new-stamp) "bob" p1)))
    (is (equal (mnemosyne/tests-entity:person-id p1) (mnemosyne/tests-entity:person-id p2))
        "_id preserved on update")
    (is (> (mnemosyne/tests-entity:person-vid p2) (mnemosyne/tests-entity:person-vid p1))
        "vid bumps on update")
    (is (equal "alice" (mnemosyne/tests-entity:person-created-by p2)) "created-by preserved")
    (is (equal "bob" (mnemosyne/tests-entity:person-modified-by p2)) "modified-by updated")))
