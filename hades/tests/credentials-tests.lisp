;;;; credentials-tests.lisp --- the credential store round-trips, and the value never shows (#357).
;;;;
;;;; Every item uses a service name unique to the run and is deleted afterwards. The value is a
;;;; marker unique to the run, so a search of any text for it can only find a leak.

(defpackage #:hades/credentials/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:cred #:hades/credentials) (#:sec #:aion/secret))
  (:export #:run-tests))

(in-package #:hades/credentials/tests)

(def-suite all :description "hades/credentials.")
(in-suite all)

(defun run-tests () (fiveam:run! 'all))

(defun %token ()
  (format nil "~36R" (random (expt 36 12) (make-random-state t))))

(defun %service () (concatenate 'string "hades-credentials-test/" (%token)))

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

#+win32
(progn
  (test a-credential-round-trips-and-is-deleted
    (let ((service (%service)) (value (%marker)) (second (%marker)))
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
        (ignore-errors (cred:delete-credential service "user")))))

  (test names-with-non-ascii-characters-round-trip
    (let ((service (concatenate 'string (%service) (string (code-char #x6587))))
          (account (concatenate 'string "b" (string (code-char #xF6)) "b"))
          (value (%marker)))
      (unwind-protect
           (progn
             (cred:store-credential service account (sec:make-secret value))
             (is (string= value (sec:reveal (cred:fetch-credential service account)))))
        (ignore-errors (cred:delete-credential service account)))))

  (test the-value-never-appears-in-output-or-a-condition
    (let* ((service (%service)) (value (%marker))
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
        (ignore-errors (cred:delete-credential service "user"))))))

#-win32
(test with-no-backend-every-call-signals-and-nothing-is-stored
  ;; No file fallback: the store refuses, and a fetch afterwards does not find anything either.
  (let ((service (%service)))
    (signals cred:credential-store-unavailable
      (cred:store-credential service "user" (sec:make-secret (%marker))))
    (signals cred:credential-store-unavailable (cred:fetch-credential service "user"))
    (signals cred:credential-store-unavailable (cred:delete-credential service "user"))))

(test empty-names-are-refused
  (signals error (cred:fetch-credential "" "user"))
  (signals error (cred:fetch-credential "service" "")))
