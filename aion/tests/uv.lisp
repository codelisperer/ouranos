;;;; uv.lisp --- tests for aion/uv.
;;;;
;;;; These need a real libuv, so they exercise the actual foreign boundary rather than a
;;;; mock -- which is the point. The failure modes worth catching here (a wrong struct
;;;; offset, a request freed twice, a callback that never fires) are exactly the ones a
;;;; mock cannot have. Build the library first:
;;;;
;;;;     sbcl --script scripts/build-libuv.lisp
;;;;
;;;; Run: (asdf:test-system :aion/uv)

(defpackage #:aion/uv/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:uv #:aion/uv)
                    (#:types #:aion/uv/types))
  (:export #:run-tests #:uv))

(in-package #:aion/uv/tests)

(def-suite uv :description "aion/uv: bindings, sync + async fs, timers, watching.")
(in-suite uv)

(defun run-tests ()
  (let ((results (run 'uv)))
    (explain! results)
    (results-status results)))

;;; --- a scratch directory per run ---------------------------------------------

(defvar *scratch* nil)

(defun scratch (name)
  (concatenate 'string *scratch* name))

(defun call-with-scratch (thunk)
  (let ((*scratch* (format nil "/tmp/aion-uv-tests-~D/" (get-universal-time))))
    (uv:make-directory *scratch* :parents t)
    (unwind-protect (funcall thunk)
      (ignore-errors
       (dolist (entry (uv:list-directory *scratch*))
         (when (eq (cdr entry) :file)
           (ignore-errors (uv:delete-file* (scratch (car entry))))))
       (uv:delete-directory *scratch*)))))

(defmacro with-scratch (&body body)
  `(call-with-scratch (lambda () ,@body)))

;;; --- the library itself --------------------------------------------------------

(test library-loads
  (is (stringp (uv:version)))
  (is (stringp (uv:library-path))))

(test a-bundled-copy-outranks-the-source-tree
  ;; ADR-0013: a shipped bundle carries its own libuv BESIDE the executable, and the search
  ;; order is the contract. If the vendored dev-tree path could win, a bundle would prefer a
  ;; library that is not on the user's machine at all -- and nothing here would notice,
  ;; because a developer's box has both.
  (let* ((candidates (aion/uv/ffi::%candidates))
         (beside     (aion/uv/ffi::%beside-image-candidates))
         (vendored   (aion/uv/ffi::%vendored-candidates)))
    (is-true beside "the running image's own directory must always resolve")
    (let ((at-beside   (position (first beside) candidates :test #'string=))
          (at-vendored (when vendored
                         (position (first vendored) candidates :test #'string=))))
      (is-true at-beside)
      (when at-vendored
        (is (< at-beside at-vendored))))
    ;; The bare soname stays last: only after every path-shaped candidate has missed do we
    ;; hand the question to the OS loader.
    (is (string= (first (last aion/uv/ffi::*library-names*))
                 (first (last candidates))))))

(test unload-releases-the-shared-object
  ;; The bundler closes libuv before dumping (ADR-0013), and this is what "closed" has to
  ;; mean: SBCL must no longer be holding the handle. It records every open shared object
  ;; and REOPENS them at image startup, so one left behind here becomes a shipped binary
  ;; that dies before main with the BUILD machine's path in the error. That shipped once,
  ;; from a close that failed silently -- the check is cheap and the failure is not.
  (let ((path (uv:library-path)))
    (aion/uv/ffi:unload-libuv)
    (is-false (aion/uv/ffi:libuv-loaded-p))
    (is-false (find path sb-sys:*shared-objects*
                    :key #'sb-alien::shared-object-namestring :test #'equal))
    ;; ...and it must come back, or the app would only ever work once.
    (is (stringp (uv:version)))
    (is-true (aion/uv/ffi:libuv-loaded-p))))

(test abi-matches-our-assumptions
  ;; The hardcoded enum constants are checked against libuv's own type names. If this
  ;; fails, handles are being allocated at the wrong size and nothing else is trustworthy.
  (is-true (aion/uv/ffi:verify-abi)))

;;; --- the typed core (pure Coalton, no libuv involved) ---------------------------

(test decode-file-events
  (is (equal '("rename") (types:file-event-strings 1)))
  (is (equal '("change") (types:file-event-strings 2)))
  ;; The bitmask can carry both at once -- the case a plain enum would have to fudge.
  (is (equal '("rename" "change") (types:file-event-strings 3)))
  (is (equal '() (types:file-event-strings 0))))

;;; These call the Coalton core directly from CL -- no `coalton` escape, because the
;;; typed layer exposes monomorphic String -> String / String -> Boolean wrappers for
;;; exactly this. That is the pure-CL face working as intended.

(test classify-error-by-name
  (is (string= "not-found" (types:classify-error-name "ENOENT")))
  (is (string= "permission-denied" (types:classify-error-name "EACCES")))
  (is (string= "permission-denied" (types:classify-error-name "EPERM")))
  ;; An unrecognised name is carried through rather than collapsed to "unknown".
  (is (string= "EWEIRD" (types:classify-error-name "EWEIRD"))))

(test only-transient-errors-are-recoverable
  (is-true (types:error-name-recoverable? "EINTR"))
  (is-true (types:error-name-recoverable? "EAGAIN"))
  ;; A missing file does not become present because you asked twice.
  (is-false (types:error-name-recoverable? "ENOENT"))
  (is-false (types:error-name-recoverable? "EACCES")))

;;; --- synchronous filesystem ------------------------------------------------------

(test write-then-read-round-trips
  (with-scratch
    (let ((path (scratch "hello.txt")))
      (is (= 11 (uv:write-file path "hello libuv")))
      (is (string= "hello libuv" (uv:read-file path :as :string)))
      (is (= 11 (length (uv:read-file path)))))))

(test read-returns-octets-by-default
  (with-scratch
    (let ((path (scratch "octets.bin")))
      (uv:write-file path "abc")
      (let ((data (uv:read-file path)))
        (is (typep data '(vector (unsigned-byte 8))))
        (is (equalp #(97 98 99) data))))))

(test append-does-not-truncate
  (with-scratch
    (let ((path (scratch "log.txt")))
      (uv:write-file path "one")
      (uv:write-file path "two" :if-exists :append)
      (is (string= "onetwo" (uv:read-file path :as :string))))))

(test write-if-exists-error-refuses
  (with-scratch
    (let ((path (scratch "once.txt")))
      (uv:write-file path "first")
      (signals uv:file-exists (uv:write-file path "second" :if-exists :error)))))

(test large-file-round-trips
  ;; Bigger than a single read is guaranteed to return, so this exercises the
  ;; short-read loop rather than the happy path.
  (with-scratch
    (let ((path (scratch "big.bin"))
          (data (make-array 300000 :element-type '(unsigned-byte 8))))
      (dotimes (i (length data))
        (setf (aref data i) (mod i 251)))
      (uv:write-file path data)
      (is (equalp data (uv:read-file path))))))

(test unicode-round-trips
  (with-scratch
    (let ((path (scratch "unicode.txt"))
          (text "naïve café — ∑ 日本語"))
      (uv:write-file path text)
      (is (string= text (uv:read-file path :as :string))))))

(test empty-file-round-trips
  (with-scratch
    (let ((path (scratch "empty.txt")))
      (is (= 0 (uv:write-file path "")))
      (is (string= "" (uv:read-file path :as :string)))
      (is (= 0 (uv:file-info-size (uv:file-info path)))))))

(test file-info-reports-size-and-kind
  (with-scratch
    (let ((path (scratch "stat.txt")))
      (uv:write-file path "12345")
      (let ((info (uv:file-info path)))
        (is (= 5 (uv:file-info-size info)))
        (is (eq :file (uv:file-info-kind info)))
        (is (plusp (uv:file-info-mtime info))))
      (is (eq :directory (uv:file-info-kind (uv:file-info *scratch*)))))))

(test missing-file-signals-file-not-found
  (signals uv:file-not-found (uv:read-file "/definitely/not/here"))
  (handler-case (uv:read-file "/definitely/not/here")
    (uv:uv-error (e)
      ;; The name is portable; the numeric code is not, so callers should branch on
      ;; the condition class or the name.
      (is (string= "ENOENT" (uv:uv-error-name e)))
      (is (minusp (uv:uv-error-code e)))
      (is (eq :read-file (uv:uv-error-operation e))))))

(test directories-and-listing
  (with-scratch
    (uv:make-directory (scratch "sub/deep") :parents t)
    (uv:write-file (scratch "a.txt") "a")
    (let ((entries (uv:list-directory *scratch*)))
      (is (member "a.txt" entries :key #'car :test #'string=))
      (is (eq :file (cdr (assoc "a.txt" entries :test #'string=))))
      (is (eq :directory (cdr (assoc "sub" entries :test #'string=)))))
    ;; Cleanup of the nested directories this test made.
    (uv:delete-file* (scratch "a.txt"))
    (uv:delete-directory (scratch "sub/deep"))
    (uv:delete-directory (scratch "sub"))))

(test make-directory-with-parents-is-idempotent
  (with-scratch
    (uv:make-directory (scratch "x/y") :parents t)
    (finishes (uv:make-directory (scratch "x/y") :parents t))
    (uv:delete-directory (scratch "x/y"))
    (uv:delete-directory (scratch "x"))))

(test rename-moves-the-file
  (with-scratch
    (uv:write-file (scratch "from.txt") "content")
    (uv:rename-path (scratch "from.txt") (scratch "to.txt"))
    (is (string= "content" (uv:read-file (scratch "to.txt") :as :string)))
    (signals uv:file-not-found (uv:read-file (scratch "from.txt")))))

;;; --- timers ----------------------------------------------------------------------

(test timer-fires-once
  (uv:with-loop (l)
    (let ((hits 0))
      (let ((timer (uv:make-timer l (lambda (tm) (declare (ignore tm)) (incf hits)))))
        (uv:start-timer timer :after 5)
        (uv:run l :mode :default)
        (uv:close-handle timer))
      (is (= 1 hits)))))

(test repeating-timer-can-stop-itself
  (uv:with-loop (l)
    (let ((hits 0) (timer nil))
      (setf timer (uv:make-timer l (lambda (tm)
                                     (incf hits)
                                     (when (>= hits 3) (uv:stop-timer tm)))))
      (uv:start-timer timer :after 1 :every 1)
      (uv:run l :mode :default)
      (uv:close-handle timer)
      (is (= 3 hits)))))

;;; --- asynchronous filesystem -------------------------------------------------------

(test async-read-yields-the-contents
  (with-scratch
    (let ((path (scratch "async.txt")))
      (uv:write-file path "async content")
      (uv:with-loop (l)
        (let ((future (uv:read-file-async l path)))
          (uv:run l :mode :default)
          (is (string= "async content"
                       (sb-ext:octets-to-string (uv:await future :timeout 10)))))))))

(test async-read-of-a-missing-file-signals-through-the-future
  (uv:with-loop (l)
    (let ((future (uv:read-file-async l "/definitely/not/here")))
      (uv:run l :mode :default)
      (signals uv:file-not-found (uv:await future :timeout 10)))))

(test async-callbacks-fire
  (with-scratch
    (let ((path (scratch "cb.txt")))
      (uv:write-file path "callback")
      (uv:with-loop (l)
        (let ((seen nil))
          (uv:read-file-async l path :on-success (lambda (data) (setf seen (length data))))
          (uv:run l :mode :default)
          (is (= 8 seen)))))))

(test async-write-then-sync-read
  (with-scratch
    (let ((path (scratch "asyncw.txt")))
      (uv:with-loop (l)
        (let ((future (uv:write-file-async l path "written asynchronously")))
          (uv:run l :mode :default)
          (uv:await future :timeout 10)))
      (is (string= "written asynchronously" (uv:read-file path :as :string))))))

(test async-large-round-trip
  (with-scratch
    (let ((path (scratch "asyncbig.bin"))
          (data (make-array 200000 :element-type '(unsigned-byte 8))))
      (dotimes (i (length data))
        (setf (aref data i) (mod i 97)))
      (uv:with-loop (l)
        (let ((write (uv:write-file-async l path data)))
          (uv:run l :mode :default)
          (is (= (length data) (uv:await write :timeout 20))))
        (let ((read (uv:read-file-async l path)))
          (uv:run l :mode :default)
          (is (equalp data (uv:await read :timeout 20))))))))

(test async-file-info
  (with-scratch
    (let ((path (scratch "asyncstat.txt")))
      (uv:write-file path "1234567")
      (uv:with-loop (l)
        (let ((future (uv:file-info-async l path)))
          (uv:run l :mode :default)
          (is (= 7 (uv:file-info-size (uv:await future :timeout 10)))))))))

;;; --- the loop thread, and crossing into it -----------------------------------------

(test submit-runs-on-the-loop-thread
  (let ((l (uv:make-loop)))
    (unwind-protect
         (let ((on-loop-thread :never-ran)
               (done (sb-thread:make-semaphore)))
           (uv:start-loop-thread l)
           ;; SUBMIT is the only safe door into a running loop from another thread.
           (uv:submit l (lambda ()
                          (setf on-loop-thread (uv:loop-thread-p l))
                          (sb-thread:signal-semaphore done)))
           (is-true (sb-thread:wait-on-semaphore done :timeout 10))
           (is-true on-loop-thread))
      (uv:close-loop l))))

(test many-submissions-all-run
  (let ((l (uv:make-loop)))
    (unwind-protect
         (let ((count 0)
               (done (sb-thread:make-semaphore)))
           (uv:start-loop-thread l)
           (dotimes (i 100)
             (uv:submit l (lambda ()
                            (incf count)
                            (when (= count 100) (sb-thread:signal-semaphore done)))))
           (is-true (sb-thread:wait-on-semaphore done :timeout 10))
           (is (= 100 count)))
      (uv:close-loop l))))

;;; --- watching ----------------------------------------------------------------------

(test watcher-observes-a-change
  (with-scratch
    (let ((l (uv:make-loop)))
      (unwind-protect
           (let ((events '())
                 (fired (sb-thread:make-semaphore)))
             (uv:watch l *scratch*
                       (lambda (kinds name watcher)
                         (declare (ignore watcher))
                         (push (cons kinds name) events)
                         (sb-thread:signal-semaphore fired)))
             (uv:start-loop-thread l)
             ;; Give the watch a moment to be armed before provoking it.
             (sleep 0.2)
             (uv:write-file (scratch "watched.txt") "trigger")
             (is-true (sb-thread:wait-on-semaphore fired :timeout 10))
             (is (plusp (length events)))
             ;; Every reported event must be one libuv actually defines.
             (is-true (every (lambda (e) (subsetp (car e) '(:rename :change))) events)))
        (uv:close-loop l)))))

(test unwatch-stops-delivery
  (with-scratch
    (let ((l (uv:make-loop)))
      (unwind-protect
           (let ((hits 0))
             (let ((watcher (uv:watch l *scratch*
                                      (lambda (k n w) (declare (ignore k n w))
                                        (incf hits)))))
               (uv:unwatch watcher)
               (uv:start-loop-thread l)
               (sleep 0.1)
               (uv:write-file (scratch "ignored.txt") "no one is listening")
               (sleep 0.3)
               (is (zerop hits))))
        (uv:close-loop l)))))

;;; --- introspection ------------------------------------------------------------------
;;;
;;; "Why will my process not exit?" answered from the image, which is the thing Node
;;; cannot do: uv_walk gives us the live handles and the registry gives us the Lisp object
;;; each one belongs to.

(test loop-handles-report-what-is-alive-and-what-holds-the-loop
  (uv:with-loop (l)
    (let ((timer (uv:make-timer l (lambda (tm) (declare (ignore tm))))))
      (uv:start-timer timer :after 60000)
      (let* ((handles (uv:loop-handles l))
             (found (find :timer handles :key #'uv:handle-info-kind))
             (async (find :async handles :key #'uv:handle-info-kind)))
        (is-true found)
        (is-true (uv:handle-info-active found))
        (is-true (uv:handle-info-referenced found))
        ;; Not merely "a timer is open" but WHICH timer -- the live-image advantage.
        (is (eq 'uv:timer (type-of (uv:handle-info-owner found))))
        ;; The loop's own wakeup handle is deliberately unreferenced: if it held the loop
        ;; open, RUN would never return even with nothing to do.
        (is-true async)
        (is-false (uv:handle-info-referenced async)))
      (is-true (uv:holds-loop-p timer))
      (uv:stop-timer timer)
      (uv:close-handle timer))))

(test describe-loop-says-what-is-holding-it-open
  (uv:with-loop (l)
    (let ((timer (uv:make-timer l (lambda (tm) (declare (ignore tm))))))
      (uv:start-timer timer :after 60000)
      (let ((report (with-output-to-string (s) (uv:describe-loop l s))))
        (is (search "timer" (string-downcase report)))
        (is (search "RUN will not return" report)))
      (uv:close-handle timer))
    ;; With nothing left running, the report has to say so rather than stay silent.
    (let ((report (with-output-to-string (s) (uv:describe-loop l s))))
      (is (search "Nothing holds this loop open" report)))))

;;; --- lifecycle ------------------------------------------------------------------

(test loops-can-be-opened-and-closed-repeatedly
  ;; Catches the leak-shaped bugs: a handle freed too early crashes here, one never
  ;; freed shows up as growth under repetition.
  (finishes
    (dotimes (i 20)
      (uv:with-loop (l)
        (let ((timer (uv:make-timer l (lambda (tm) (declare (ignore tm))))))
          (uv:start-timer timer :after 1)
          (uv:run l :mode :default)
          (uv:close-handle timer))))))

(test close-loop-is-idempotent
  (let ((l (uv:make-loop)))
    (uv:close-loop l)
    (finishes (uv:close-loop l))))

;;; --- #296: SUBMIT's refusal is a contract, so it gets asserted ----------------------
;;;
;;; The race these defend against is not testable and these do not try. A window that
;;; needs two threads to interleave inside four instructions is not something a green run
;;; says anything about -- the evidence for the race closing is five consecutive runs of
;;; hyperion/server-uv/tests on Windows, where it reliably fired before and does not now.
;;;
;;; What IS testable is the CONTRACT that makes the fix work, and an invariant nothing
;;; checks is not an invariant. Three properties, and the third is the one that keeps the
;;; first two honest: a SUBMIT that refused unconditionally would satisfy both of the
;;; others and break everything.

(test submit-on-a-closed-loop-refuses-and-does-not-queue
  ;; THE QUEUE IS ASSERTED, NOT JUST THE CONDITION. "It signalled" and "it also queued the
  ;; thunk" can both be true, and that combination is the dangerous one: the thunk would
  ;; sit in a queue belonging to a loop whose uv_async_t has been freed.
  (let ((l (uv:make-loop))
        (ran nil))
    (uv:close-loop l)
    (signals uv:loop-closed
      (uv:submit l (lambda () (setf ran t))))
    (is (null ran) "the thunk must not have run")
    (is (null (aion/uv::loop-queue l))
        "a refused SUBMIT must leave nothing behind in the queue")))

(test close-loop-claims-the-flag-once
  ;; The old CLOSE-LOOP read the flag and set it in two steps, so two threads could both
  ;; pass the test and both reach FOREIGN-FREE. Its docstring said "Idempotent" and meant
  ;; it only of SEQUENTIAL calls -- which is not the property a teardown needs. This
  ;; asserts the observable consequence of the claim being atomic: after ANY close, the
  ;; loop refuses work, and a second close is still a no-op.
  (let ((l (uv:make-loop)))
    (uv:close-loop l)
    (is (aion/uv::loop-closed-p l) "the flag is set after the first close")
    (finishes (uv:close-loop l))
    (signals uv:loop-closed (uv:submit l (lambda () nil)))))

(test submit-on-an-open-loop-still-works
  ;; THE CONTROL, and the reason the two above mean anything. A SUBMIT that signalled
  ;; LOOP-CLOSED for every loop, open or shut, would pass both of them.
  (let* ((l (uv:make-loop))
         (ran (sb-thread:make-semaphore)))
    (unwind-protect
         (progn
           (uv:start-loop-thread l)
           (finishes (uv:submit l (lambda () (sb-thread:signal-semaphore ran))))
           (is (sb-thread:wait-on-semaphore ran :timeout 10)
               "the submitted thunk must actually run on the loop thread"))
      (uv:close-loop l))))
