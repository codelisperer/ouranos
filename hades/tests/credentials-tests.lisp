;;;; credentials-tests.lisp --- the credential store round-trips, and the value never shows (#357).
;;;;
;;;; Every item uses a service name unique to the run and is deleted afterwards. The value is a
;;;; marker unique to the run, so a search of any text for it can only find a leak.
;;;;
;;;; THE LIVE TESTS USE THE REAL STORE. On Windows and macOS they store, read and delete items in
;;;; the Credential Manager or login Keychain of whoever runs them, so they run only when
;;;; OURANOS_TEST_REAL_CREDENTIAL_STORE=1 is set. CI sets it, because a runner's store is thrown
;;;; away with the runner. On a developer's machine the maintainer decides whether to set it.
;;;; RUN-TESTS reports which happened as a BACKEND-CHECKS credential-store line, and
;;;; scripts/verify-tree.lisp fails a skipped run unless OURANOS_ALLOW_NO_CREDENTIAL_STORE=1
;;;; excuses it, as it does for Postgres.
;;;;
;;;; What a live run touches: only items whose service starts with
;;;; "ouranos-test-hades-credentials/", each with a random suffix, so it cannot meet an item it
;;;; did not create. Each test deletes its item when it ends, however it ends. A delete that fails
;;;; is printed, naming the item and never its value, and recorded; the LEFTOVERS suite then
;;;; fails on it, and also checks that every item the run created can no longer be fetched. It
;;;; does not list the store, which would read the names of every credential the user has.

(defpackage #:hades/credentials/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:cred #:hades/credentials) (#:sec #:aion/secret))
  (:export #:run-tests))

(in-package #:hades/credentials/tests)

(def-suite all :description "hades/credentials: the tests that do not touch a credential store.")
(def-suite live :description "hades/credentials: the tests that use this machine's real store.")
(def-suite leftovers :description "hades/credentials: nothing the live tests created remains.")

(defparameter +live-variable+ "OURANOS_TEST_REAL_CREDENTIAL_STORE"
  "The environment variable that lets the live tests use this machine's real store.")

(defun %live-p ()
  (let ((v (uiop:getenv +live-variable+)))
    (and v (member (string-trim " " v) '("1" "true" "yes") :test #'string-equal) t)))

(defvar *created* '()
  "(service . account) for every item a live test has stored, or tried to, in this run.")

(defvar *undeleted* '()
  "(service . account) for every item whose cleanup delete signalled an error in this run.")

(defun run-tests ()
  "Run the tests that touch no store, then, on Windows and macOS, the live tests if
+LIVE-VARIABLE+ allows them, and print a BACKEND-CHECKS credential-store line saying which."
  (fiveam:run! 'all)
  #+(or win32 darwin)
  (if (%live-p)
      (let ((results (fiveam:run 'live)))
        (fiveam:explain! results)
        (format t "~&BACKEND-CHECKS credential-store ~D~%" (length results))
        (fiveam:run! 'leftovers))
      (format t "~&BACKEND-CHECKS credential-store SKIPPED (~A is not set; the live tests use this machine's real credential store)~%"
              +live-variable+)))

(defun %token ()
  (format nil "~36R" (random (expt 36 12) (make-random-state t))))

(defun %service ()
  "A service name unique to the run, recorded in *CREATED* with ACCOUNT by %ITEM."
  (concatenate 'string "ouranos-test-hades-credentials/" (%token)))

(defun %item (service account)
  "Record SERVICE and ACCOUNT as an item this run is about to store, and return SERVICE."
  (push (cons service account) *created*)
  service)

(defun %cleanup (service account)
  "Delete the item SERVICE / ACCOUNT at the end of a test. NIL from DELETE-CREDENTIAL means the
test had already deleted it. An error is printed, naming the item and not its value, and
recorded in *UNDELETED*, rather than ignored."
  (handler-case (cred:delete-credential service account)
    (cred:credential-error (e)
      (push (cons service account) *undeleted*)
      (format *error-output* "~&hades/credentials/tests: could not delete the test item ~S / ~S: ~A~%"
              service account e))))

(defun %marker ()
  "A value to store: unique to the run, with a non-ASCII character, and never printed."
  (concatenate 'string "sk-test-" (%token) (string (code-char #xE9)) (%token)))

(defmacro %capturing ((text) &body body)
  "Run BODY with standard and error output collected, then bind TEXT to what was written."
  (let ((out (gensym "OUT")))
    `(let* ((,out (make-string-output-stream))
            (*standard-output* ,out)
            (*error-output* ,out)
            (*trace-output* ,out))
       (let ((,text (progn ,@body (get-output-stream-string ,out))))
         ,text))))

;;; --- live: this machine's real store -------------------------------------------------------

#+(or win32 darwin)
(progn
  (in-suite live)

  (test a-credential-round-trips-and-is-deleted
    (let ((service (%item (%service) "user")) (value (%marker)) (second (%marker)))
      (unwind-protect
           (progn
             (is (eq t (cred:store-credential service "user" (sec:make-secret value))))
             (let ((got (cred:fetch-credential service "user")))
               (is (sec:secretp got) "fetch must return an aion/secret")
               (is (string= value (sec:reveal got))))
             (cred:store-credential service "user" (sec:make-secret second))
             (is (string= second (sec:reveal (cred:fetch-credential service "user")))
                 "storing again must replace the value")
             (is (eq t (cred:delete-credential service "user")))
             (is (null (cred:delete-credential service "user")) "deleting what is gone returns NIL")
             (signals cred:credential-not-found (cred:fetch-credential service "user")))
        (%cleanup service "user"))))

  (test names-with-non-ascii-characters-round-trip
    (let* ((account (concatenate 'string "b" (string (code-char #xF6)) "b"))
           (service (%item (concatenate 'string (%service) (string (code-char #x6587))) account))
           (value (%marker)))
      (unwind-protect
           (progn
             (cred:store-credential service account (sec:make-secret value))
             (is (string= value (sec:reveal (cred:fetch-credential service account)))))
        (%cleanup service account))))

  (test the-value-never-appears-in-output-or-a-condition
    (let* ((service (%item (%service) "user")) (value (%marker))
           (huge (concatenate 'string value (make-string 3000 :initial-element #\x)))
           (reports '()))
      (unwind-protect
           (let ((text
                   (%capturing (text)
                     (cred:store-credential service "user" (sec:make-secret value))
                     (let ((got (cred:fetch-credential service "user")))
                       (format t "~A ~S~%" got got)
                       (describe got))
                     (handler-case (cred:store-credential service "user" (sec:make-secret huge))
                       (cred:credential-too-large (e) (push (princ-to-string e) reports)))
                     (handler-case (cred:store-credential service "user" value)
                       (type-error (e) (push (princ-to-string e) reports)))
                     (cred:delete-credential service "user")
                     (handler-case (cred:fetch-credential service "user")
                       (cred:credential-not-found (e) (push (princ-to-string e) reports))))))
             (is (= 3 (length reports)) "each refusal must have been signalled: ~S" reports)
             (is (not (search value text)) "the value appeared in printed output")
             (dolist (r reports)
               (is (not (search value r)) "the value appeared in a condition report"))
             ;; The control: the same search does find the value where it is printed on purpose.
             (is (search value (format nil "~A" (sec:reveal (sec:make-secret value))))))
        (%cleanup service "user"))))

  (in-suite leftovers)

  (test every-item-the-live-tests-created-is-gone
    "Each item the live tests stored can no longer be fetched, and no cleanup delete failed. It
fetches by name only the items this run created."
    (is (null *undeleted*) "cleanup could not delete: ~S" *undeleted*)
    (is (plusp (length *created*)) "the live tests recorded no items, so this checked nothing")
    (dolist (item *created*)
      (signals cred:credential-not-found (cred:fetch-credential (car item) (cdr item))))))

;;; --- every platform: nothing here touches a store ------------------------------------------

(in-suite all)

#-(or win32 darwin)
(test with-no-backend-every-call-signals-and-nothing-is-stored
  ;; No file fallback: the store refuses, and a fetch afterwards does not find anything either.
  (let ((service (%service)))
    (signals cred:credential-store-unavailable
      (cred:store-credential service "user" (sec:make-secret (%marker))))
    (signals cred:credential-store-unavailable (cred:fetch-credential service "user"))
    (signals cred:credential-store-unavailable (cred:delete-credential service "user"))))

(test empty-names-are-refused
  ;; Refused before any store is reached, so this runs without the live variable.
  (signals error (cred:fetch-credential "" "user"))
  (signals error (cred:fetch-credential "service" "")))
