;;;; tests/hermes.lisp --- fiveam suite for hermes (delivery + inbound).
;;;;
;;;; No network: the SendGrid/Twilio HTTP paths aren't exercised here (that needs live creds);
;;;; we test the neutral protocol, env-based provider selection, the dev transport (renders,
;;;; never sends), the failure protocol (ensure-2xx), and the inbound Twilio webhook's
;;;; signature verification (valid accepted, forged rejected) + neutral event + emit.

(cl:defpackage #:hermes/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:h #:hermes) (#:in #:hermes/inbound))
  (:export #:run-tests))
(cl:in-package #:hermes/tests)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (ignore-errors (require :sb-posix)))

(def-suite hermes :description "hermes delivery + inbound.")
(defun run-tests () (run! 'hermes))
(in-suite hermes)

;;; --- writing the environment, without a read-time dependency on sb-posix ---
;;;
;;; SBCL's Windows sb-posix is thinner than the POSIX one. A literal `sb-posix:setenv'
;;; is resolved by the READER, so on a build lacking that symbol this file dies with a
;;; package error and takes the whole suite with it — and the gate now runs every system
;;; in its own image and fails on any warning, so that is a hard failure rather than
;;; something you notice and route around. Look the symbol up at RUNTIME instead, so the
;;; blast radius is the tests that need it, which then skip and say why.
;;;
;;; No Lisp-side fallback is possible: the code under test reads `uiop:getenv', i.e. the
;;; real C environment. Nor is `(setf uiop:getenv)' one — it expands to the same call.
;;; Provider selection also distinguishes "" from unset, so unsetenv must be the real one.

(defun %env-fn (name)
  "The SB-POSIX function NAME, or NIL when this build has no such thing."
  (let* ((package (find-package "SB-POSIX"))
         (symbol (and package (find-symbol name package))))
    (and symbol (fboundp symbol) symbol)))

(defun env-writable-p ()
  "True when this build can mutate the C environment that `uiop:getenv' reads."
  (and (%env-fn "SETENV") (%env-fn "UNSETENV") t))

(defun set-env (name value) (funcall (%env-fn "SETENV") name value 1))
(defun unset-env (name) (funcall (%env-fn "UNSETENV") name))

(defmacro with-env (bindings &body body)
  "Set env vars for BODY, restoring after. BINDINGS: ((\"NAME\" value-or-nil) ...) — NIL unsets.
Skips when the build cannot write the environment — see ENV-WRITABLE-P."
  (let ((saves (gensym)))
    `(if (not (env-writable-p))
         (skip "no sb-posix:setenv in this build — env selection is unexercised here")
         (let ((,saves (mapcar (lambda (b) (cons (car b) (uiop:getenv (car b)))) ',bindings)))
           (unwind-protect
                (progn ,@(mapcar (lambda (b)
                                   (if (second b)
                                       `(set-env ,(first b) ,(second b))
                                       `(ignore-errors (unset-env ,(first b)))))
                                 bindings)
                       ,@body)
             (dolist (s ,saves)
               (if (cdr s) (set-env (car s) (cdr s))
                   (ignore-errors (unset-env (car s))))))))))

;;; --- protocol -------------------------------------------------------------
(test unsupported-message-signalled
  ;; a bare email-provider asked to deliver an SMS hits the default method
  (signals h:unsupported-message
    (h:deliver (make-instance 'h:email-provider) (h:make-sms :to "+15550000000" :text "hi"))))

(test env-selection-defaults
  (with-env (("HERMES_TRANSPORT" nil) ("HERMES_EMAIL_IMPL" nil) ("HERMES_SMS_IMPL" nil))
    (is (typep (h:email-provider-from-env) 'h:sendgrid))
    (is (typep (h:sms-provider-from-env) 'h:twilio))))

(test env-transport-dev-overrides-both
  (with-env (("HERMES_TRANSPORT" "dev"))
    (is (typep (h:email-provider-from-env) 'h:dev-transport))
    (is (typep (h:sms-provider-from-env) 'h:dev-transport)))
  (with-env (("HERMES_TRANSPORT" nil) ("HERMES_EMAIL_IMPL" "dev"))
    (is (typep (h:email-provider-from-env) 'h:dev-transport))))

;;; --- dev transport --------------------------------------------------------
(test dev-transport-renders-not-sends
  (let* ((out (make-string-output-stream))
         (p (h:make-dev-transport :stream out))
         (r (h:deliver p (h:make-email :to "a@x.io" :from "b@y.io" :subject "Verify"
                                       :text "click http://app/verify/abc123"))))
    (is (eq :dev (h:delivery-result-provider r)))
    (is (eq :logged (h:delivery-result-status r)))
    (let ((s (get-output-stream-string out)))
      (is (search "a@x.io" s))
      (is (search "http://app/verify/abc123" s) "the link must be visible in dev output"))))

(test send-uses-env-provider
  (with-env (("HERMES_TRANSPORT" "dev"))
    (let ((*standard-output* (make-broadcast-stream)))          ; swallow the dev render
      (is (eq :dev (h:delivery-result-provider
                    (h:send (h:make-email :to "a@x" :from "b@y" :subject "S" :text "T")))))
      (is (eq :dev (h:delivery-result-provider
                    (h:send (h:make-sms :to "+15551230000" :from "+15559990000" :text "hi"))))))))

;;; --- the boundary with aion/http-client (pre-publication issue 202) ----------------------------
;;;
;;; The HTTP client moved to aion, and with it the ensure-2xx behaviour this file used to
;;; test directly -- covered now by aion/http-client/tests, where the code lives.
;;;
;;; What is hermes' OWN responsibility after the move is the translation: the shared client
;;; signals HTTP-ERROR, which is deliberately not a messaging condition, and DELIVER's
;;; contract promises DELIVERY-FAILURE. AS-DELIVERY is the seam that restores the meaning,
;;; and it is the thing that would silently break the contract if it regressed.

(test a-transport-failure-arrives-as-a-delivery-failure
  ;; DELIVER promises DELIVERY-FAILURE. A caller must not have to know that an HTTP client
  ;; sits underneath, nor catch a condition from a different framework.
  (signals h:delivery-failure
    (hermes::as-delivery :sendgrid
      (error 'aion/http-client:http-error :detail "transport error: connection refused"))))

(test the-provider-and-status-survive-the-translation
  ;; The status and the provider's own body are what make a failure actionable; losing them
  ;; in translation would turn a legible refusal back into an opaque one.
  (handler-case
      (progn (hermes::as-delivery :twilio
               (error 'aion/http-client:http-error :status 400 :body "invalid To number"))
             (fail "should have signalled"))
    (h:delivery-failure (c)
      (is (eq :twilio (h:delivery-failure-provider c)))
      (is (= 400 (h:delivery-failure-status c)))
      (is (search "invalid To number" (h:delivery-failure-detail c))
          "the provider's explanation must survive"))))

(test a-successful-call-passes-through-untouched
  (is (= 42 (hermes::as-delivery :sendgrid 42))))

;;; --- inbound: Twilio webhook signature ------------------------------------
(defparameter +tok+ "test-auth-token-0123456789")
(defparameter +url+ "https://app.example/hooks/twilio/sms")
(defparameter +params+ '(("From" . "+15551234567") ("To" . "+15557654321")
                         ("Body" . "hello there") ("MessageSid" . "SM0123")))

(test twilio-signature-accept-and-reject
  (let ((sig (hermes/inbound::%twilio-signature +url+ +params+ +tok+)))
    (is (in:verify-twilio-signature +url+ +params+ sig :auth-token +tok+))            ; valid
    (is (not (in:verify-twilio-signature +url+ +params+ "forged==" :auth-token +tok+))) ; forged
    (is (not (in:verify-twilio-signature +url+ +params+ sig :auth-token "wrong-token"))) ; wrong key
    (is (not (in:verify-twilio-signature +url+ +params+ nil :auth-token +tok+)))))       ; missing

(test twilio-webhook-emits-on-valid-rejects-forged
  (let* ((sig (hermes/inbound::%twilio-signature +url+ +params+ +tok+))
         (received '())
         (sub (in:subscribe (lambda (m) (push m received)))))
    (unwind-protect
         (progn
           (let ((msg (in:twilio-webhook +url+ +params+ sig :auth-token +tok+)))
             (is (string= "+15551234567" (in:inbound-message-from msg)))
             (is (string= "hello there" (in:inbound-message-body msg)))
             (is (eq :twilio (in:inbound-message-provider msg)))
             (is (string= "SM0123" (in:inbound-message-provider-id msg)))
             (is (= 1 (length received)) "valid webhook emits to subscribers"))
           (signals in:signature-required
             (in:twilio-webhook +url+ +params+ "forged==" :auth-token +tok+))
           (is (= 1 (length received)) "a forged webhook does not emit"))
      (in:unsubscribe sub))))

(test parse-twilio-inbound-normalizes
  (let ((m (in:parse-twilio-inbound '(("From" . "15551112222") ("To" . "+15553334444")
                                      ("Body" . "b") ("MessageSid" . "SMx")))))
    (is (string= "+15551112222" (in:inbound-message-from m)) "bare digits get a leading +")
    (is (string= "+15553334444" (in:inbound-message-to m)))
    (is (string= "SMx" (in:inbound-message-provider-id m)))))

(test twiml-message-escapes
  (let ((x (in:twiml-message "a & b < c > d \"e\"")))
    (is (search "<Response><Message>" x))
    (is (search "&amp;" x))
    (is (search "&lt;" x))
    (is (search "&quot;" x))))

;;; --- attachments (#366) -----------------------------------------------------

(defparameter +invite-ics+
  (format nil "BEGIN:VCALENDAR~C~CVERSION:2.0~C~CMETHOD:REQUEST~C~CSUMMARY:Café review~C~CEND:VCALENDAR~C~C"
          #\Return #\Linefeed #\Return #\Linefeed #\Return #\Linefeed
          #\Return #\Linefeed #\Return #\Linefeed)
  "A small calendar file, with a non-ASCII character so the UTF-8 encoding is exercised.")

(test an-email-without-attachments-serialises-exactly-as-before
  "The two JSON strings are what hermes produced for these emails before #366, captured from
main at 3ab171b."
  (is (string= "{\"personalizations\":[{\"to\":[{\"email\":\"a@x.com\"}]}],\"from\":{\"email\":\"b@x.com\"},\"subject\":\"Hi\",\"content\":[{\"type\":\"text/plain\",\"value\":\"Body\"}]}"
               (com.inuoe.jzon:stringify
                (hermes::%sendgrid-body (h:make-email :to "a@x.com" :from "b@x.com"
                                                      :subject "Hi" :text "Body")))))
  (is (string= "{\"personalizations\":[{\"to\":[{\"email\":\"a@x.com\"}]}],\"from\":{\"email\":\"b@x.com\"},\"subject\":\"Hi\",\"content\":[{\"type\":\"text/plain\",\"value\":\"Body\"},{\"type\":\"text/html\",\"value\":\"<p>Body</p>\"}],\"reply_to\":{\"email\":\"r@x.com\"}}"
               (com.inuoe.jzon:stringify
                (hermes::%sendgrid-body (h:make-email :to "a@x.com" :from "b@x.com"
                                                      :subject "Hi" :text "Body"
                                                      :html "<p>Body</p>" :reply-to "r@x.com"))))))

(test a-text-and-an-octet-attachment-go-to-sendgrid-in-base64-with-their-type-name-and-disposition
  (let* ((octets (coerce #(0 1 2 250 251 255) '(vector (unsigned-byte 8))))
         (m (h:make-email :to "a@x.com" :from "b@x.com" :subject "Invite" :text "See the file."
                          :attachments
                          (list (h:make-attachment
                                 :filename "invite.ics"
                                 :content-type "text/calendar; charset=utf-8; method=REQUEST"
                                 :content +invite-ics+)
                                (h:make-attachment :filename "logo.png" :content-type "image/png"
                                                   :content octets :disposition :inline
                                                   :content-id "logo"))))
         (entries (gethash "attachments" (hermes::%sendgrid-body m))))
    (is (= 2 (length entries)))
    (let ((ics (aref entries 0)) (png (aref entries 1)))
      (is (string= "invite.ics" (gethash "filename" ics)))
      (is (string= "text/calendar; charset=utf-8; method=REQUEST" (gethash "type" ics))
          "the content type is sent with its parameters")
      (is (string= "attachment" (gethash "disposition" ics)))
      (is (null (nth-value 1 (gethash "content_id" ics))))
      (is (string= +invite-ics+
                   (sb-ext:octets-to-string (cl-base64:base64-string-to-usb8-array (gethash "content" ics))
                                            :external-format :utf-8))
          "a string is sent as its UTF-8 bytes, in base64")
      (is (equalp octets (cl-base64:base64-string-to-usb8-array (gethash "content" png)))
          "an octet vector is sent as those octets")
      (is (string= "inline" (gethash "disposition" png)))
      (is (string= "logo" (gethash "content_id" png))))))

(test the-dev-transport-shows-and-keeps-the-attachments-of-the-last-email
  (let* ((out (make-string-output-stream))
         (p (h:make-dev-transport :stream out))
         (invite (h:make-attachment :filename "invite.ics"
                                    :content-type "text/calendar; method=CANCEL"
                                    :content +invite-ics+)))
    (h:deliver p (h:make-email :to "a@x.io" :from "b@y.io" :subject "Cancelled" :text "Off."
                               :attachments (list invite)))
    (is (equal (list invite) (h:email-attachments (h:dev-last-email p)))
        "a test can read the attachments of the last email sent")
    (let ((s (get-output-stream-string out)))
      (is (search (format nil "invite.ics (text/calendar; method=CANCEL, ~D bytes)"
                          (length (sb-ext:string-to-octets +invite-ics+ :external-format :utf-8)))
                  s)
          "the render names the file, its type and its size in bytes")
      (is (not (search "BEGIN:VCALENDAR" s)) "and not its content"))))

(test an-attachment-that-cannot-be-sent-is-refused-when-it-is-made
  (signals h:invalid-message (h:make-attachment :content-type "text/plain" :content "x"))
  (signals h:invalid-message (h:make-attachment :filename (format nil "a~Cb" #\Newline)
                                                :content-type "text/plain" :content "x"))
  (signals h:invalid-message (h:make-attachment :filename "a" :content-type "text/plain" :content 42))
  (signals h:invalid-message (h:make-attachment :filename "a" :content-type "text/plain" :content "x"
                                                :disposition :inline))
  (signals h:invalid-message (h:make-email :to "a" :from "b" :attachments (list "not an attachment")))
  (is (h:attachment-p (h:make-attachment :filename "a.txt" :content-type "text/plain" :content ""))
      "an empty file is still a file"))

;;; --- extra email headers (#106) ----------------------------------------------

(defun %sendgrid-headers (m)
  "The headers object of the SendGrid request for M, or NIL when there is none."
  (gethash "headers" (hermes::%sendgrid-body m)))

(test list-unsubscribe-reaches-sendgrid-as-given
  (let* ((value "<https://app.example/u/abc>, <mailto:unsubscribe@app.example?subject=u-abc>")
         (headers (%sendgrid-headers
                   (h:make-email :to "a@x.com" :from "b@x.com" :subject "News" :text "Hi"
                                 :headers (list (cons "List-Unsubscribe" value))))))
    (is (string= value (gethash "List-Unsubscribe" headers))
        "the value is sent exactly as given, both URIs included")
    (is (= 1 (hash-table-count headers)) "and nothing else is added")))

(test list-unsubscribe-post-reaches-sendgrid-beside-list-unsubscribe
  ;; RFC 8058: one-click needs both headers, and an https URI in List-Unsubscribe.
  (let ((headers (%sendgrid-headers
                  (h:make-email :to "a@x.com" :from "b@x.com" :subject "News" :text "Hi"
                                :headers '(("List-Unsubscribe" . "<https://app.example/u/abc>")
                                           ("List-Unsubscribe-Post" . "List-Unsubscribe=One-Click"))))))
    (is (string= "List-Unsubscribe=One-Click" (gethash "List-Unsubscribe-Post" headers)))
    (is (string= "<https://app.example/u/abc>" (gethash "List-Unsubscribe" headers)))))

(test an-email-without-headers-sends-no-headers-object
  (is (null (nth-value 1 (gethash "headers" (hermes::%sendgrid-body
                                             (h:make-email :to "a@x.com" :from "b@x.com"
                                                           :subject "Hi" :text "Body"))))))
  (is (null (h:email-headers (h:make-email :to "a@x.com" :from "b@x.com")))))

(test a-line-break-in-a-header-name-or-value-is-refused
  ;; Header injection: a CR or LF would end the header and let the value add one of its own.
  (dolist (break (list (string #\Return) (string #\Linefeed) (format nil "~C~C" #\Return #\Linefeed)))
    (signals h:invalid-message
      (h:make-email :to "a" :from "b"
                    :headers (list (cons "List-Unsubscribe"
                                         (format nil "<https://a.example/u>~ABcc: victim@example.com" break)))))
    (signals h:invalid-message
      (h:make-email :to "a" :from "b"
                    :headers (list (cons (format nil "X-Campaign~ABcc" break) "x"))))))

(test a-header-hermes-or-the-provider-sets-cannot-be-given
  (dolist (name '("To" "from" "SUBJECT" "Reply-To" "Bcc" "Content-Type" "DKIM-Signature"))
    (signals h:invalid-message
      (h:make-email :to "a" :from "b" :headers (list (cons name "x"))))))

(test other-bad-headers-are-refused-and-good-ones-kept
  (signals h:invalid-message (h:make-email :to "a" :from "b" :headers '(("" . "x"))))
  (signals h:invalid-message (h:make-email :to "a" :from "b" :headers '(("X Campaign" . "x"))))
  (signals h:invalid-message (h:make-email :to "a" :from "b" :headers '(("X-Campaign:" . "x"))))
  (signals h:invalid-message (h:make-email :to "a" :from "b" :headers '(("X-Campaign" . 42))))
  (signals h:invalid-message (h:make-email :to "a" :from "b" :headers '(("X-A" . "1") ("x-a" . "2"))))
  (signals h:invalid-message (h:make-email :to "a" :from "b" :headers '("X-A: 1")))
  (signals h:invalid-message (h:make-email :to "a" :from "b" :headers "X-A: 1"))
  (let ((headers (list (cons "X-Campaign" (format nil "spring~Csale" #\Tab)) (cons "X-Empty" ""))))
    (is (equal headers (h:email-headers (h:make-email :to "a" :from "b" :headers headers)))
        "a tab and an empty value are allowed, and the alist is kept as given")))

(test a-header-value-outside-printable-ascii-is-refused
  ;; NEL (U+0085) and the line separator (U+2028) end a line for some parsers; a non-ASCII
  ;; letter is not valid in a raw header, and hermes does not RFC 2047-encode one.
  (dolist (ch (list (code-char #x85) (code-char #x9B) (code-char #x2028) (code-char #xE9)
                    (code-char 127) (code-char 0)))
    (signals h:invalid-message
      (h:make-email :to "a" :from "b"
                    :headers (list (cons "X-Campaign" (format nil "spring~Csale" ch)))))))

(test a-header-longer-than-an-email-line-is-refused
  ;; "X-Long: " is 8 characters, so a 990-character value makes a 998-character line.
  (is (h:email-headers (h:make-email :to "a" :from "b"
                                     :headers (list (cons "X-Long" (make-string 990 :initial-element #\a)))))
      "998 characters is allowed")
  (signals h:invalid-message
    (h:make-email :to "a" :from "b"
                  :headers (list (cons "X-Long" (make-string 991 :initial-element #\a))))))

(test the-reserved-header-list-cannot-be-changed-by-a-caller
  (let ((list (h:reserved-email-headers)))
    (setf (first list) "X-Not-Reserved")
    (is (member "To" (h:reserved-email-headers) :test #'string=) "a fresh list each time")
    (signals h:invalid-message (h:make-email :to "a" :from "b" :headers '(("To" . "x"))))))

(test the-dev-transport-shows-the-headers-of-the-last-email
  (let* ((out (make-string-output-stream))
         (p (h:make-dev-transport :stream out)))
    (h:deliver p (h:make-email :to "a@x.io" :from "b@y.io" :subject "News" :text "Hi"
                               :headers '(("List-Unsubscribe" . "<https://app.example/u/abc>")
                                          ("List-Unsubscribe-Post" . "List-Unsubscribe=One-Click"))))
    (let ((s (get-output-stream-string out)))
      (is (search "List-Unsubscribe: <https://app.example/u/abc>" s))
      (is (search "List-Unsubscribe-Post: List-Unsubscribe=One-Click" s)))))

(test an-email-s-headers-cannot-be-replaced-after-the-checks
  "#969: the checks run in MAKE-EMAIL, so a header list that could be swapped in afterwards would
reach SendGrid unchecked. The slot is read-only, and the body builder checks again for a struct
made inside hermes without MAKE-EMAIL."
  (is (not (fboundp '(setf h:email-headers)))
      "there is no (SETF EMAIL-HEADERS), so the checked list cannot be replaced")
  (let ((m (hermes::%make-email :to "a@x.com" :from "b@x.com" :subject "Hi" :text "Body"
                                :headers (list (cons "List-Unsubscribe"
                                                     (format nil "<https://a.example/u>~C~CBcc: victim@example.com"
                                                             #\Return #\Linefeed))))))
    (signals h:invalid-message (hermes::%sendgrid-body m))
    "a struct built without MAKE-EMAIL is refused where it becomes a request")
  (let ((m (hermes::%make-email :to "a@x.com" :from "b@x.com" :subject "Hi" :text "Body"
                                :headers '(("Bcc" . "victim@example.com")))))
    (signals h:invalid-message (hermes::%sendgrid-body m)))
  (let ((m (h:make-email :to "a@x.com" :from "b@x.com" :subject "Hi" :text "Body"
                         :headers '(("X-Campaign" . "spring")))))
    (is (string= "spring" (gethash "X-Campaign" (gethash "headers" (hermes::%sendgrid-body m))))
        "control: a checked header still reaches the request")))

(test an-improper-headers-list-is-an-invalid-message-not-a-type-error
  ;; #969: EVERY on an improper list signals TYPE-ERROR, which is not hermes's refusal protocol.
  (signals h:invalid-message (h:make-email :to "a" :from "b" :headers '(("X-A" . "1") . "tail")))
  (signals h:invalid-message (h:make-email :to "a" :from "b" :headers '("X-A" . "1"))))
