;;;; tests/http-client.lisp --- the interceptor-shaped HTTP client (pre-publication issue 202).
;;;;
;;;; Like the interceptor pipeline before it (pre-publication issue 177), this code was written, used in
;;;; production paths by two providers, and moved -- with NO TESTS AT ALL. That is the same
;;;; finding twice: the tree's reusable pieces keep arriving covered by nothing, inside
;;;; systems reporting green.
;;;;
;;;; None of these touch the network. SEND-REQUEST takes its effect as a parameter, which is
;;;; both how it is tested here and how a consuming app stubs it -- the app that reported
;;;; pre-publication issue 202 had independently arrived at the same shape, calling it "an injectable var".

(cl:defpackage #:aion/http-client/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:http #:aion/http-client))
  (:export #:run-tests))
(cl:in-package #:aion/http-client/tests)

(def-suite http-client :description "The interceptor-shaped HTTP client.")
(defun run-tests () (run! 'http-client))
(in-suite http-client)

(defun %ok (&key (status 200) (body "") headers)
  "An effect that answers with a fixed response, ignoring the request."
  (lambda (req) (declare (ignore req))
    (http:make-response :status status :body body :headers headers)))

(defun %echo ()
  "An effect that reports the request it was given, so ENTER stages are observable."
  (lambda (req)
    (http:make-response
     :status 200
     :body (format nil "~A ~A |~{~A=~A~^,~}|"
                   (http:request-method req) (http:request-url req)
                   (loop for (k . v) in (reverse (http:request-headers req))
                         append (list k v))))))

;;; --- stage order -----------------------------------------------------------

(test enter-stages-run-forward-before-the-effect
  (let ((resp (http:send-request
               (http:make-request :method :post :url "https://example.invalid/x")
               (list (http:add-header "A" "1") (http:add-header "B" "2"))
               :perform (%echo))))
    (is (search "A=1" (http:response-body resp)))
    (is (search "B=2" (http:response-body resp)))
    (is (search "POST" (http:response-body resp))
        "the effect sees the built request, not the original")))

(test leave-stages-run-in-reverse-so-the-outermost-wraps
  ;; The property most easily got backwards, and one that still appears to work until a
  ;; stage depends on an outer one having already run.
  (let* ((mark (lambda (s)
                 (http:make-interceptor
                  s :leave (lambda (r)
                             (http:make-response
                              :status (http:response-status r)
                              :body (concatenate 'string (http:response-body r) s))))))
         (resp (http:send-request (http:make-request :url "u")
                                  (list (funcall mark "<a") (funcall mark "<b"))
                                  :perform (%ok :body "body"))))
    (is (string= "body<b<a" (http:response-body resp))
        "inner stage leaves first; got ~S" (http:response-body resp))))

(test a-stage-with-no-leave-is-transparent
  (let ((resp (http:send-request (http:make-request :url "u")
                                 (list (http:add-header "A" "1"))
                                 :perform (%ok :body "unchanged"))))
    (is (string= "unchanged" (http:response-body resp)))))

;;; --- status handling -------------------------------------------------------

(test a-2xx-passes-through-ensure-2xx
  (dolist (status '(200 201 204 299))
    (is (= status (http:response-status
                   (http:send-request (http:make-request :url "u")
                                      (list (http:ensure-2xx))
                                      :perform (%ok :status status)))))))

(test a-non-2xx-signals-and-carries-the-body
  ;; The body is where a service explains its own refusal, and is the part a caller most
  ;; wants in the report -- so it travels with the condition rather than being discarded.
  (handler-case
      (progn (http:send-request (http:make-request :url "u")
                                (list (http:ensure-2xx "acme"))
                                :perform (%ok :status 422 :body "card_declined"))
             (fail "should have signalled"))
    (http:http-error (e)
      (is (= 422 (http:http-error-status e)))
      (is (string= "card_declined" (http:http-error-body e)))
      (is (string= "acme" (http:http-error-label e))
          "the label names which call failed"))))

(test a-non-2xx-without-ensure-2xx-is-just-a-response
  ;; dexador would signal on a 404; capturing it as a response is what lets a LEAVE stage
  ;; decide what a status MEANS, rather than the transport deciding for it.
  (let ((resp (http:send-request (http:make-request :url "u") '()
                                 :perform (%ok :status 404 :body "nope"))))
    (is (= 404 (http:response-status resp)))
    (is (string= "nope" (http:response-body resp)))))

;;; --- what the move changed -------------------------------------------------

(test failure-is-an-http-error-not-a-messaging-condition
  ;; The one thing that could not move verbatim. The original signalled hermes'
  ;; DELIVERY-FAILURE from a general HTTP client, which is precisely what made it
  ;; unreusable -- a client has no business asserting that a *delivery* failed.
  (signals http:http-error
    (http:send-request (http:make-request :url "u") (list (http:ensure-2xx))
                       :perform (%ok :status 500))))

(test timeouts-survive-an-enter-stage
  ;; Added because the client's second consumer needed them and its first did not: praxeon
  ;; hand-rolled dexador partly because this could not express a read timeout. A header
  ;; stage rebuilds the request, so it must carry them or they are silently lost.
  (let ((seen nil))
    (http:send-request
     (http:make-request :url "u" :connect-timeout 3 :read-timeout 42)
     (list (http:add-header "A" "1"))
     :perform (lambda (req) (setf seen req) (http:make-response :status 200)))
    (is (= 3 (http:request-connect-timeout seen)))
    (is (= 42 (http:request-read-timeout seen))
        "a header stage must not reset the timeouts")))

;;; --- helpers ---------------------------------------------------------------

(test header-lookup-is-case-insensitive
  (let ((h (make-hash-table :test #'equal)))
    (setf (gethash "x-message-id" h) "abc")
    (is (string= "abc" (http:header-value h "X-Message-Id")))
    (is (null (http:header-value h "absent")))
    (is (null (http:header-value nil "anything")) "no headers is not an error")))

(test an-empty-chain-is-just-the-effect
  (is (string= "raw" (http:response-body
                      (http:send-request (http:make-request :url "u") '()
                                         :perform (%ok :body "raw"))))))

;;; --- pre-publication issue 223: the bytes that arrived, exactly ----------------------------------
;;;
;;; The client used to decode every body to a UTF-8 string and keep nothing else, so there
;;; was no path to the octets at all. A signed update cannot go through that: the signature
;;; is over the exact bytes of a file, and a decode is the re-encoding that invalidates it
;;; -- at a customer, on a version bump, months after anyone touched the code.

(defparameter +binary+
  (make-array 8 :element-type '(unsigned-byte 8)
                :initial-contents '(#xff #xd8 #xff #xe0 #x00 #x10 #x4a #x46))
  "The first eight bytes of a JPEG. Deliberately NOT valid UTF-8 -- #xff cannot begin a
UTF-8 sequence -- because that is the case the old contract silently destroyed.")

(defun %binary-ok (bytes)
  (lambda (req) (declare (ignore req)) (http:make-response :status 200 :bytes bytes)))

(test the-bytes-that-arrived-survive-byte-for-byte
  (let ((resp (http:send-request (http:make-request :url "https://x.example")
                                 (list (http:ensure-2xx)) :perform (%binary-ok +binary+))))
    (is (equalp +binary+ (http:response-bytes resp))
        "the octets were altered in transit through the client")))

(test the-old-contract-would-have-destroyed-those-bytes
  ;; Not a test of the client -- a test of the CLAIM the client is built on, so that the
  ;; reason for this design is checkable rather than asserted. Decode-then-re-encode is
  ;; exactly what a string-only response body did, and it is not the identity.
  (let ((round-tripped (sb-ext:string-to-octets
                        (sb-ext:octets-to-string
                         +binary+ :external-format '(:utf-8 :replacement #\ufffd))
                        :external-format :utf-8)))
    (is (not (equalp +binary+ round-tripped))
        "if this ever passes, the premise of pre-publication issue 223 is wrong and the design should be revisited")))

(test the-string-view-is-still-available-and-is-total
  ;; RESPONSE-BODY must not signal on bytes that are not UTF-8: ENSURE-2XX puts the body
  ;; into the condition it raises, so a strict decode breaks the error path on exactly the
  ;; responses one most needs reported.
  (let ((resp (http:make-response :status 200 :bytes +binary+)))
    (is (stringp (http:response-body resp)))
    ;; ...and the bytes are untouched by having asked for the lossy view.
    (is (equalp +binary+ (http:response-bytes resp)))))

(test a-non-2xx-with-a-binary-body-is-an-http-error-not-a-decode-error
  ;; The latent bug this contract change also fixes. The old code decoded strictly, INSIDE
  ;; a handler-case handler -- where a signal escapes the handler-case entirely -- so a
  ;; proxy's binary error page raised INVALID-UTF8-STARTER-BYTE instead of describing the
  ;; 502 that actually happened.
  (let ((perform (lambda (req) (declare (ignore req))
                   (http:make-response :status 502 :bytes +binary+))))
    (handler-case
        (progn (http:send-request (http:make-request :url "https://x.example")
                                  (list (http:ensure-2xx)) :perform perform)
               (fail "expected an HTTP-ERROR"))
      (http:http-error (e)
        (is (= 502 (http:http-error-status e)))
        ;; and it must be REPORTABLE -- the whole point of a total decode
        (is (stringp (format nil "~A" e))))
      (error (e)
        (fail "got ~A instead of HTTP-ERROR -- the decode failed, not the request"
              (type-of e))))))

(test a-string-body-still-round-trips-for-every-existing-consumer
  ;; hermes and praxeon pass strings to MAKE-RESPONSE in their stubs and read strings back.
  (let ((resp (http:make-response :status 200 :body "{\"ok\":true}")))
    (is (string= "{\"ok\":true}" (http:response-body resp)))
    (is (equalp (sb-ext:string-to-octets "{\"ok\":true}" :external-format :utf-8)
                (http:response-bytes resp)))))

(test multi-byte-utf-8-decodes-as-utf-8-and-not-as-latin-1
  ;; Guards the decode itself: "€" is three bytes, and a latin-1 reading would give three
  ;; characters rather than one.
  (let* ((text "price: €10")
         (resp (http:make-response :status 200
                                   :bytes (sb-ext:string-to-octets
                                           text :external-format :utf-8))))
    (is (string= text (http:response-body resp)))
    (is (= (length text) (length (http:response-body resp))))))

(test printing-a-response-does-not-dump-the-body
  ;; A response can now legitimately hold an installer; the default structure printer would
  ;; put megabytes of integers into any backtrace unwinding through it.
  (let ((printed (format nil "~S" (http:make-response :status 200 :bytes +binary+))))
    (is (null (search "255" printed)) "the printer dumped the body: ~S" printed)
    (is (search "200" printed))
    (is (search "8 bytes" printed))))
