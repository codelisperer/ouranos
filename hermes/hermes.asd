;;;; hermes.asd --- system definition for hermes.
;;;;
;;;; hermes: the codelisperer external-integrations framework -- neutral protocols over
;;;; third-party services (à la praxeon's LLM seam). First module: delivery (email + SMS)
;;;; behind a neutral DELIVER protocol (SendGrid + Twilio backends, plus a dev/log
;;;; transport); plus INBOUND SMS (a signature-verified Twilio webhook emitting a neutral
;;;; event). A dependency-light leaf: dexador/jzon/base64 for the wire, ironclad for the
;;;; inbound signature. Consumable by any app; hermes is "the messenger".

(defsystem "hermes"
  :description "External-integrations framework: neutral email + SMS delivery and inbound (SendGrid/Twilio)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("aion/http-client"  ; the interceptor-shaped client, shared (#202)
               "dexador"           ; still direct for hermes/blob's streaming needs
               "com.inuoe.jzon"    ; JSON (SendGrid body, Twilio response)
               "cl-base64"         ; Twilio Basic auth + inbound-signature encoding
               "ironclad"          ; HMAC-SHA1 for X-Twilio-Signature verification
               "aion/log")         ; framework logging facade (send attempts/failures)
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "conditions") ; the failure protocol
                             (:file "message")    ; neutral EMAIL / SMS / DELIVERY-RESULT
                             (:file "protocol")   ; PROVIDER + DELIVER + env selection
                             (:file "dev")        ; the dev/log transport (render, don't send)
                             (:file "sendgrid")   ; SendGrid email backend
                             (:file "twilio")     ; Twilio SMS backend (outbound)
                             (:file "inbound")    ; inbound SMS: neutral event + Twilio webhook
                             (:file "hermes"))))
  :in-order-to ((test-op (test-op "hermes/tests"))))

(defsystem "hermes/tests"
  :description "Test suite for hermes."
  :depends-on ("hermes" "aion/http-client" "fiveam")  ; hermes.lisp calls http: directly
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "hermes"))))
  :perform (test-op (o c) (uiop:symbol-call :hermes/tests :run-tests)))

;;; The blob store. Bytes belong in object storage; a row holds a key and metadata, never
;;; the payload. One neutral protocol, two backends -- filesystem for dev and tests,
;;; S3-compatible for deployment -- so a new provider is a new class plus one
;;; REGISTER-STORE, not a new API.
;;;
;;; It lives in HERMES rather than mnemosyne (#164) for two reasons. Nothing about object
;;; storage is SQL, and hermes is chartered for exactly this -- external integrations behind
;;; one neutral protocol. And hermes is a satellite depending only on aion, so code at ANY
;;; point in the DAG can store a file; under mnemosyne, a praxeon agent or a databaseless
;;; hyperion app pulled CL-DBI and two drivers to write one.
;;;
;;; The S3 backend also adds NO new external dependency here: ironclad (HMAC-SHA256),
;;; cl-base64 and dexador are already hermes' own, for Twilio and SendGrid.
;;; hermes/payments --- the neutral payments protocol (#48).
;;;
;;; A SEPARATE system, though it adds no dependency hermes core does not already have
;;; (dexador, jzon, ironclad are all present). The reason is not dependencies but load
;;; path: an application that wants email should not compile a payments protocol it will
;;; never call, and a payments module is the last thing that should be reachable by
;;; accident.
(defsystem "hermes/payments"
  :description "A neutral payments protocol: hosted checkout, subscriptions, normalized webhooks."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("hermes"            ; conditions and the messaging doctrine
               "aion/http-client"  ; the shared outbound client (#202) -- direct, not via hermes
               "coalton"           ; the normalized event vocabulary
               "aion/secret/types" ; api key + webhook secret as opaque fields (#209)
               "com.inuoe.jzon"
               "ironclad"          ; HMAC-SHA256 webhook signatures
               "aion/log")
  :serial t
  :components ((:module "src/payments"
                :serial t
                :components ((:file "packages")
                             (:file "kind")      ; the closed event vocabulary (Coalton)
                             (:file "money")     ; typed amount + provider config (Coalton)
                             (:file "events")    ; the records an event carries (CL)
                             (:file "protocol")  ; provider + operations + env selection
                             (:file "dev")       ; the in-memory provider; no vendor, no money
                             (:file "stripe"))))  ; the first real backend (#47)
  :in-order-to ((test-op (test-op "hermes/payments/tests"))))

(defsystem "hermes/payments/tests"
  :description "Tests for the neutral payments protocol."
  :depends-on ("hermes/payments" "aion/secret" "aion/http-client" "fiveam")  ; payments.lisp calls http:
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "payments"))))
  :perform (test-op (o c) (uiop:symbol-call :hermes/payments/tests :run-tests)))

(defsystem "hermes/blob"
  :description "Neutral blob store: filesystem + S3-compatible, behind one protocol."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("aion/clock" ; new-id names the filesystem backend's temp files
               "aion/log"   ; the framework logging facade -- already hermes core's
               "coalton"    ; the key/visibility core is typed
               "dexador"    ; the S3 backend's only transport
               "ironclad")  ; SHA-256 checksums on the way past, HMAC for SigV4
  :serial t
  :components ((:module "blob"
                :pathname "src/blob"
                :serial t
                :components ((:file "packages")
                             (:file "key")        ; what a key may be + visibility (Coalton)
                             (:file "conditions") ; the failure protocol (CL)
                             (:file "protocol")   ; the store seam, streaming, sweep (CL)
                             (:file "filesystem") ; local disk -- the zero-config default (CL)
                             (:file "s3"))))      ; any S3-compatible provider (CL)
  :in-order-to ((test-op (test-op "hermes/blob/tests"))))

(defsystem "hermes/blob/tests"
  :description "Test suite for the blob store."
  :depends-on ("hermes/blob" "aion/clock" "aion/log" "fiveam")  ; blob.lisp calls both directly
  :serial t
  :components ((:module "blob-tests"
                :pathname "tests"
                :serial t
                :components ((:file "blob"))))
  :perform (test-op (o c) (uiop:symbol-call :hermes/blob/tests :run-tests)))
