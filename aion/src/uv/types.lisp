;;;; types.lisp --- the typed core of aion/uv, in Coalton.
;;;;
;;;; libuv speaks in integers: a bitmask says what changed about a file, a negative
;;;; number says what went wrong. Integers are where silent bugs live -- nothing stops
;;;; you comparing an error code against an event mask, and nothing complains when you
;;;; forget that a value can be BOTH rename and change at once. This layer turns each of
;;;; those integers into a type, once, at the boundary.
;;;;
;;;; It is pure. No IO happens here and none may: decoding is a function from a number
;;;; to a meaning, and that is precisely the part of a binding worth type-checking. The
;;;; effects -- opening files, running loops, calling back into C -- all live in the CL
;;;; shell next door.
;;;;
;;;; Every ADT is paired with a monomorphic renderer that CL can call directly, because
;;;; a typeclass-constrained function cannot be called from CL (docs/coalton-patterns.md
;;;; §5). Callers who never write a line of Coalton still get decoding that was checked.

(cl:in-package #:aion/uv/types)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- What happened to a watched file -------------------------------------
  ;;;
  ;;; libuv delivers UV_RENAME (1) and UV_CHANGE (2) as a BITMASK, so both can be set
  ;;; at once. A list of events models that honestly; a single enum would have to
  ;;; invent a "both" case or silently drop one.

  (define-type FileEvent
    "A single thing libuv observed about a watched path."
    Renamed
    Changed)

  (declare file-event->string (FileEvent -> String))
  (define (file-event->string e)
    (match e
      ((Renamed) "rename")
      ((Changed) "change")))

  (declare decode-file-events (Integer -> (List FileEvent)))
  (define (decode-file-events mask)
    "Decode libuv's fs_event bitmask. Both bits may be set, so the result is a list.

Tested with MOD rather than bit operations so this file needs nothing beyond the
prelude (coalton/bits would do, at the cost of an import for two bits). UV_RENAME is
bit 0, UV_CHANGE is bit 1; masking with 4 keeps the test exact if libuv ever defines
a third."
    ;; NB the bindings are named with a trailing ? deliberately: Coalton is
    ;; case-insensitive, so a variable `renamed` would BE the constructor `Renamed`
    ;; and this function would quietly infer (List Boolean).
    (let ((renamed? (== 1 (mod mask 2)))
          (changed? (>= (mod mask 4) 2)))
      (cond
        ((and renamed? changed?) (Cons Renamed (Cons Changed Nil)))
        (renamed? (Cons Renamed Nil))
        (changed? (Cons Changed Nil))
        (True Nil))))

  (declare file-event-strings (Integer -> (List String)))
  (define (file-event-strings mask)
    "The CL-callable form: a bitmask in, a list of names out."
    (map file-event->string (decode-file-events mask)))

  ;;; --- What went wrong ------------------------------------------------------
  ;;;
  ;;; Dispatch is on libuv's error NAME, not its number. The numbers are platform
  ;;; errnos and differ between Linux, macOS and Windows; the names do not. Binding
  ;;; behaviour to the numbers is how a wrapper works on the machine it was written on
  ;;; and misbehaves everywhere else.

  (define-type UvErrorKind
    "A libuv failure, classified into the cases callers actually branch on."
    NotFound
    PermissionDenied
    AlreadyExists
    NotDirectory
    IsDirectory
    NotEmpty
    Interrupted
    WouldBlock
    TimedOut
    (OtherError String))

  (declare classify-error (String -> UvErrorKind))
  (define (classify-error name)
    "Classify a libuv error name such as \"ENOENT\"."
    (cond
      ((== name "ENOENT") NotFound)
      ((== name "EACCES") PermissionDenied)
      ((== name "EPERM") PermissionDenied)
      ((== name "EEXIST") AlreadyExists)
      ((== name "ENOTDIR") NotDirectory)
      ((== name "EISDIR") IsDirectory)
      ((== name "ENOTEMPTY") NotEmpty)
      ((== name "EINTR") Interrupted)
      ((== name "EAGAIN") WouldBlock)
      ((== name "ETIMEDOUT") TimedOut)
      (True (OtherError name))))

  (declare error-kind->string (UvErrorKind -> String))
  (define (error-kind->string k)
    (match k
      ((NotFound) "not-found")
      ((PermissionDenied) "permission-denied")
      ((AlreadyExists) "already-exists")
      ((NotDirectory) "not-a-directory")
      ((IsDirectory) "is-a-directory")
      ((NotEmpty) "not-empty")
      ((Interrupted) "interrupted")
      ((WouldBlock) "would-block")
      ((TimedOut) "timed-out")
      ((OtherError name) name)))

  ;;; The two CL-callable forms. A CL caller has a STRING at runtime, and feeding a
  ;;; runtime CL value into a Coalton expression otherwise means a `lisp` escape at
  ;;; every call site; a monomorphic String -> String wrapper is the documented way to
  ;;; hand the typed core to callers who never write Coalton (coalton-patterns.md §5).
  (declare classify-error-name (String -> String))
  (define (classify-error-name name)
    "Classify a libuv error name and render the classification. CL-callable."
    (error-kind->string (classify-error name)))

  (declare error-name-recoverable? (String -> Boolean))
  (define (error-name-recoverable? name)
    "True if retrying after this libuv error could plausibly succeed. CL-callable."
    (error-recoverable? (classify-error name)))

  (declare error-recoverable? (UvErrorKind -> Boolean))
  (define (error-recoverable? k)
    "True when retrying the identical call could plausibly succeed.

Only EINTR and EAGAIN qualify: the operation was interrupted or the resource was
momentarily unavailable, and nothing about the request itself was wrong. A missing
file does not become present because you asked twice."
    (match k
      ((Interrupted) True)
      ((WouldBlock) True)
      (_ False)))

  ;;; --- How to run a loop -----------------------------------------------------

  (define-type RunMode
    "The three ways libuv will run a loop."
    RunDefault
    RunOnce
    RunNoWait)

  (declare run-mode->code (RunMode -> Integer))
  (define (run-mode->code m)
    (match m
      ((RunDefault) 0)
      ((RunOnce) 1)
      ((RunNoWait) 2)))

  ;;; --- What a directory entry is ---------------------------------------------

  (define-type DirentKind
    "The kind of a directory entry, as reported during a scan."
    EntryUnknown
    EntryFile
    EntryDirectory
    EntrySymlink
    EntryFifo
    EntrySocket
    EntryCharDevice
    EntryBlockDevice)

  (declare decode-dirent-kind (Integer -> DirentKind))
  (define (decode-dirent-kind n)
    "Decode uv_dirent_type_t by ordinal."
    (cond
      ((== n 1) EntryFile)
      ((== n 2) EntryDirectory)
      ((== n 3) EntrySymlink)
      ((== n 4) EntryFifo)
      ((== n 5) EntrySocket)
      ((== n 6) EntryCharDevice)
      ((== n 7) EntryBlockDevice)
      (True EntryUnknown)))

  (declare dirent-kind->string (DirentKind -> String))
  (define (dirent-kind->string k)
    (match k
      ((EntryUnknown) "unknown")
      ((EntryFile) "file")
      ((EntryDirectory) "directory")
      ((EntrySymlink) "symlink")
      ((EntryFifo) "fifo")
      ((EntrySocket) "socket")
      ((EntryCharDevice) "character-device")
      ((EntryBlockDevice) "block-device"))))
