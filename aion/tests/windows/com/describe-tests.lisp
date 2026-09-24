;;;; describe-tests.lisp --- which COM references are still held, and where each came from (#109).
;;;;
;;;; Scripting.FileSystemObject and Scripting.Dictionary on purpose: every Windows has them and
;;;; the CI runner has no Office. The Office measurements that motivate this are on #109.
;;;;
;;;; Other tests in this suite may leave objects of their own in the table, so these tests only
;;;; ever ask about the objects they made, never about the table's size.

(in-package #:aion/windows/com/tests)

(def-suite describe-objects :description "LIVE-COM-OBJECTS and DESCRIBE-COM-OBJECTS." :in all)
(in-suite describe-objects)

(defun %live-p (object) (and (member object (com:live-com-objects)) t))

(defun %described ()
  (with-output-to-string (s) (com:describe-com-objects s)))

(test a-created-object-is-listed-with-its-prog-id-until-released
  (let ((fso (com:create-object "Scripting.FileSystemObject")))
    (unwind-protect
         (progn
           (is (string= "Scripting.FileSystemObject" (com:com-object-origin fso)))
           (is-true (%live-p fso) "a created object is missing from LIVE-COM-OBJECTS"))
      (com:release fso))
    (is-false (%live-p fso) "a released object is still listed as live")))

(test a-child-from-a-property-is-named-by-its-parent-and-member
  "The case #109 is about: an object nobody assigned, returned by a property, that keeps its
server alive. It has to be listed, and listed by where it came from."
  (let* ((fso (com:create-object "Scripting.FileSystemObject"))
         (drives (com:get-property fso "Drives")))
    (unwind-protect
         (progn
           (is-true (com:com-object-p drives) "Drives did not come back as an object")
           (is (string= "Scripting.FileSystemObject -> Drives" (com:com-object-origin drives)))
           (is-true (%live-p drives))
           (let ((text (%described)))
             (is (search "Scripting.FileSystemObject -> Drives" text)
                 "DESCRIBE-COM-OBJECTS did not name the unreleased child: ~A" text))
           (com:release drives)
           (is-false (%live-p drives) "releasing the child did not remove it")
           (is-true (%live-p fso) "releasing the child removed the parent too"))
      (com:release drives)
      (com:release fso))
    (is-false (%live-p fso))))

(test describe-returns-the-live-objects-and-counts-them
  (let ((a (com:create-object "Scripting.Dictionary"))
        (b (com:create-object "Scripting.Dictionary")))
    (unwind-protect
         (let* ((listed nil)
                (text (with-output-to-string (s) (setf listed (com:describe-com-objects s)))))
           (is (subsetp (list a b) listed) "the returned list lacks objects that are live")
           (is (search "unreleased COM reference" text))
           (is (< (position a listed) (position b listed)) "not listed oldest first"))
      (com:release a)
      (com:release b))))

(test releasing-twice-leaves-the-table-consistent
  (let ((d (com:create-object "Scripting.Dictionary")))
    (is-true (com:release d))
    (is-false (com:release d) "a second RELEASE claimed to release again")
    (is-false (%live-p d))))

(test a-release-from-another-thread-really-releases
  "The table is touched from every thread, and RELEASE may be called from any of them: it
runs the Release in the apartment. Asserted on the reference count, not only on the table,
because a release that removed the entry and skipped the Release would pass a table check.

An extra reference is taken first, so the object stays valid throughout. AddRef returns the
count with it (N). After the other thread's RELEASE and our own Release, the count must be
N - 2; had the other thread's RELEASE done nothing, it would be N - 1."
  (let* ((d (com:create-object "Scripting.Dictionary"))
         (p (com:com-object-pointer d))
         (n (com:in-apartment () (ffi:iunknown-add-ref p)))
         (result :not-run))
    (let ((thread (sb-thread:make-thread (lambda () (setf result (com:release d)))
                                         :name "describe-tests releaser")))
      (sb-thread:join-thread thread))
    (is (eq t result) "RELEASE from another thread returned ~S" result)
    (is-false (%live-p d) "released from another thread, but still listed")
    (is (= (- n 2) (com:in-apartment () (ffi:iunknown-release p)))
        "the other thread's RELEASE did not reach the object's reference count")))

(test concurrent-creates-and-releases-leave-nothing-behind
  "Four threads creating and releasing at once. Without the lock, SBCL's hash table can lose
or keep entries under concurrent writers."
  (let* ((made (make-array 4 :initial-element nil))
         (threads (loop for i below 4
                        collect (let ((i i))
                                  (sb-thread:make-thread
                                   (lambda ()
                                     (dotimes (k 20)
                                       (let ((d (com:create-object "Scripting.Dictionary")))
                                         (push d (aref made i))
                                         (com:release d))))
                                   :name "describe-tests worker")))))
    (mapc #'sb-thread:join-thread threads)
    (let ((all (loop for v across made append v)))
      (is (= 80 (length all)))
      (is (= 80 (length (remove-duplicates (mapcar #'com:com-object-serial all))))
          "two objects got the same serial number")
      (is (notany #'%live-p all) "released objects are still listed after concurrent use"))))

(test wrap-interface-records-the-origin-it-is-given
  (let* ((d (com:create-object "Scripting.Dictionary"))
         (p (com:com-object-pointer d)))
    (com:in-apartment () (ffi:iunknown-add-ref p))
    (let ((named (com:wrap-interface p :origin "my own Dictionary")))
      (is (string= "my own Dictionary" (com:com-object-origin named)))
      (is-true (%live-p named))
      (com:release named)
      (is-false (%live-p named)))
    (com:release d))
  (let ((empty (com:wrap-interface (cffi:null-pointer))))
    (is-false (%live-p empty) "a null pointer owns no reference, so it must not be listed")))
