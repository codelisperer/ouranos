;;;; ratelimit-tests.lisp --- hyperion/ratelimit, the limiter for authentication routes (#297).
;;;;
;;;; Every test drives the clock through *CLOCK-MS* instead of sleeping, so the times below
;;;; are exact. Requests are built by hand; nothing adds an address or a form field unless
;;;; the test names it.

(in-package #:hyperion/tests)

(def-suite ratelimit :description "Rate limiting for authentication routes." :in hyperion)
(in-suite ratelimit)

(defvar *rl-now* 0 "The time the test clock reports, in milliseconds.")

(defmacro %rl-quietly (&body forms)
  "FORMS with logging turned down: every refusal warns, which would bury the suite."
  `(unwind-protect (progn (aion/log:level! :error) ,@forms)
     (aion/log:level! :warn)))

(defmacro %with-rl-clock ((&optional (start 0)) &body body)
  `(let* ((*rl-now* ,start)
          (rl:*clock-ms* (lambda () *rl-now*)))
     (%rl-quietly ,@body)))

(defun %rl-advance (seconds) (incf *rl-now* (round (* 1000 seconds))))

(defun %rl-env (&key (method :post) (path "/sign-in") addr email)
  (let ((env (list :request-method method :path-info path
                   :headers (make-hash-table :test #'equal))))
    (when addr (setf env (list* :remote-addr addr env)))
    (when email
      (setf env (http:cache-body-string env (format nil "email=~A&password=x" email))))
    env))

(defun %rl-app ()
  "WRAP-RATE-LIMIT's app: records how many times it ran and the email it read from the
body. Returns (values app calls-box)."
  (let ((calls (list 0 nil)))
    (values (lambda (env)
              (incf (first calls))
              (setf (second calls) (http:form-param (http:body-string env) "email"))
              (list 200 (list :content-type "text/plain") (list "ok")))
            calls)))

(defun %rl-status (app env) (first (funcall app env)))

(defun %rl-by-address (&key (capacity 3) (per 60) paths)
  (rl:make-limit :sign-in-address :capacity capacity :per per
                 :key (rl:by-address) :paths paths))

(defun %rl-by-account (&key (capacity 2))
  (rl:make-limit :sign-in-account :capacity capacity :per 60
                 :key (rl:by-form-field "email")))

;;; --- the bucket -------------------------------------------------------------

(test a-bucket-allows-its-capacity-then-refuses-until-a-token-refills
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-address)))))
      ;; capacity 3 per 60 s: one token every 20 s.
      (is (equal '(200 200 200)
                 (loop repeat 3 collect (%rl-status app (%rl-env :addr "10.0.0.1")))))
      (let ((refused (funcall app (%rl-env :addr "10.0.0.1"))))
        (is (= 429 (first refused)))
        (is (string= "20" (getf (second refused) :retry-after))))
      (%rl-advance 19)
      (is (= 429 (%rl-status app (%rl-env :addr "10.0.0.1")))
          "one second short of a token")
      (%rl-advance 1)
      (is (= 200 (%rl-status app (%rl-env :addr "10.0.0.1"))))
      (is (= 429 (%rl-status app (%rl-env :addr "10.0.0.1")))))))

(test a-bucket-never-refills-past-its-capacity
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-address)))))
      (%rl-advance 3600)
      (is (equal '(200 200 200 429)
                 (loop repeat 4 collect (%rl-status app (%rl-env :addr "10.0.0.1"))))))))

(test retry-after-is-whole-seconds-rounded-up
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app)
                                   :limits (list (%rl-by-address :capacity 1 :per 60)))))
      (%rl-status app (%rl-env :addr "a"))
      (%rl-advance 0.5)
      (is (string= "60" (getf (second (funcall app (%rl-env :addr "a"))) :retry-after))
          "59.5 seconds to wait is reported as 60"))))

(test each-address-has-its-own-bucket
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-address :capacity 1)))))
      (is (= 200 (%rl-status app (%rl-env :addr "10.0.0.1"))))
      (is (= 429 (%rl-status app (%rl-env :addr "10.0.0.1"))))
      (is (= 200 (%rl-status app (%rl-env :addr "10.0.0.2")))))))

;;; --- what the middleware applies to ------------------------------------------

(test a-get-and-another-path-are-not-counted
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app)
                                   :limits (list (%rl-by-address :capacity 1
                                                                 :paths '("/sign-in"))))))
      (is (= 200 (%rl-status app (%rl-env :addr "a"))))
      (is (= 200 (%rl-status app (%rl-env :addr "a" :method :get)))
          "the GET that renders the form is not counted")
      (is (= 200 (%rl-status app (%rl-env :addr "a" :path "/other"))))
      (is (= 429 (%rl-status app (%rl-env :addr "a")))))))

(test a-refused-request-never-reaches-the-app
  (%with-rl-clock ()
    (multiple-value-bind (inner calls) (%rl-app)
      (let ((app (rl:wrap-rate-limit inner :limits (list (%rl-by-address :capacity 1)))))
        (funcall app (%rl-env :addr "a"))
        (funcall app (%rl-env :addr "a"))
        (funcall app (%rl-env :addr "a"))
        (is (= 1 (first calls)))))))

;;; --- account keys ------------------------------------------------------------

(test an-account-key-is-normalised
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-account)))))
      (is (= 200 (%rl-status app (%rl-env :addr "a" :email "bob@x.test"))))
      (is (= 200 (%rl-status app (%rl-env :addr "b" :email "BOB@X.test"))))
      (is (= 429 (%rl-status app (%rl-env :addr "c" :email "%20Bob@x.test")))
          "case and surrounding space do not make a new bucket")
      (is (= 200 (%rl-status app (%rl-env :addr "d" :email "alice@x.test")))))))

(test the-app-can-still-read-the-body-the-key-was-read-from
  (%with-rl-clock ()
    (multiple-value-bind (inner calls) (%rl-app)
      (let ((app (rl:wrap-rate-limit inner :limits (list (%rl-by-account)))))
        (funcall app (%rl-env :addr "a" :email "bob@x.test"))
        (is (string= "bob@x.test" (second calls)))))))

(test a-request-without-the-field-is-not-counted-by-the-account-limit
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-account :capacity 1)))))
      (is (equal '(200 200 200)
                 (loop repeat 3 collect (%rl-status app (%rl-env :addr "a"))))))))

(test the-refusal-is-the-same-whatever-the-account
  ;; The limiter never looks at an account store, so it cannot behave differently for an
  ;; account that exists. What an attacker can compare is the response, so assert that two
  ;; refusals for different accounts are identical.
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-account :capacity 1)))))
      (funcall app (%rl-env :email "exists@x.test"))
      (funcall app (%rl-env :email "never-registered@x.test"))
      (is (equal (funcall app (%rl-env :email "exists@x.test"))
                 (funcall app (%rl-env :email "never-registered@x.test")))))))

(test address-and-account-limits-together
  ;; One client trying many accounts is stopped by the address limit; many clients trying
  ;; one account are stopped by the account limit.
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app)
                                   :limits (list (%rl-by-address :capacity 3)
                                                 (%rl-by-account :capacity 2)))))
      (is (equal '(200 200 200 429)
                 (loop for i from 1 to 4
                       collect (%rl-status app (%rl-env :addr "one-client"
                                                        :email (format nil "u~D@x.test" i))))))
      (is (equal '(200 200 429)
                 (loop for i from 1 to 3
                       collect (%rl-status app (%rl-env :addr (format nil "client-~D" i)
                                                        :email "target@x.test"))))))))

(test reset-limit-gives-the-key-a-full-bucket
  (%with-rl-clock ()
    (let* ((store (rl:make-memory-store))
           (limit (%rl-by-account :capacity 1))
           (app (rl:wrap-rate-limit (%rl-app) :limits (list limit) :store store)))
      (funcall app (%rl-env :email "bob@x.test"))
      (is (= 429 (%rl-status app (%rl-env :email "bob@x.test"))))
      (rl:reset-limit store limit "bob@x.test")
      (is (= 200 (%rl-status app (%rl-env :email "bob@x.test")))))))

;;; --- the store's bound -------------------------------------------------------

(test the-memory-store-keeps-no-more-than-max-keys
  (%with-rl-clock ()
    (let* ((store (rl:make-memory-store :max-keys 10))
           (app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-account)) :store store)))
      (loop for i from 1 to 25
            do (funcall app (%rl-env :email (format nil "u~D@x.test" i))))
      (is (<= (rl:memory-store-count store) 10)))))

(test the-store-drops-full-buckets-before-partly-drained-ones
  ;; A bucket that has refilled completely behaves exactly like a missing one, so dropping
  ;; it loses nothing. The drained bucket must survive the sweep and still refuse.
  (%with-rl-clock ()
    (let* ((store (rl:make-memory-store :max-keys 3))
           (app (rl:wrap-rate-limit (%rl-app)
                                    :limits (list (%rl-by-account :capacity 1)) :store store)))
      (loop for i from 1 to 2
            do (funcall app (%rl-env :email (format nil "old~D@x.test" i))))
      (%rl-advance 120)                                  ; both refill completely
      (funcall app (%rl-env :email "drained@x.test"))    ; the only bucket not full
      (funcall app (%rl-env :email "new@x.test"))        ; the fourth bucket: sweep runs
      (is (<= (rl:memory-store-count store) 3))
      (is (= 429 (%rl-status app (%rl-env :email "drained@x.test")))
          "the drained bucket must not be the one the sweep dropped"))))

;;; --- construction ------------------------------------------------------------

(test a-limit-refuses-a-nonsense-configuration
  (signals error (rl:make-limit :x :capacity 0 :per 60 :key (rl:by-address)))
  (signals error (rl:make-limit :x :capacity 5 :per 0 :key (rl:by-address)))
  (signals error (rl:make-limit :x :capacity 5 :per 60 :key nil))
  (signals error (rl:wrap-rate-limit (lambda (env) env) :limits nil)))
