;;;; packages.lisp --- aion/tls: TLS over the mbedTLS this tree builds (#125).

(cl:defpackage #:aion/tls
  (:use #:cl)
  (:documentation
   "TLS for the framework, over the mbedTLS that scripts/build-mbedtls.lisp builds from
    mbedtls.pin, with our aion/src/tls/c/ compiled into the same library. Opt-in: nothing
    that loads aion gets a native library from this unless it loads aion/tls.

    An ENGINE runs one TLS connection over memory buffers and never touches a socket:
    ciphertext goes in with ENGINE-FEED and comes out with ENGINE-TAKE-OUTPUT, and the
    caller moves it. The server (hyperion/server-uv) drives engines over libuv; TLS-STREAM
    drives one over any Lisp binary stream, blocking, for a client such as a Postgres
    connection.")
  (:export
   ;; the library
   #:load-mbedtls #:unload-mbedtls #:mbedtls-loaded-p #:mbedtls-path #:ensure-loaded
   #:mbedtls-not-found #:mbedtls-not-found-searched
   #:mbedtls-mismatch #:mbedtls-mismatch-path #:mbedtls-mismatch-reason
   #:+shim-version+
   ;; errors
   #:tls-error #:tls-error-code #:tls-error-operation #:tls-error-description
   #:tls-verify-error #:tls-verify-error-flags
   ;; keys and certificates
   #:private-key #:make-private-key #:generate-private-key #:private-key-pem
   #:free-private-key
   #:certificate-chain #:make-certificate-chain #:certificate-chain-der
   #:certificate-chain-matches-key-p #:free-certificate-chain
   #:issue-certificate
   ;; configurations
   #:config #:make-server-config #:make-client-config #:free-config
   #:config-endpoint #:config-ciphersuites
   #:+tls-1.2+ #:+tls-1.3+ #:*ciphersuites* #:ciphersuite-name
   ;; the engine
   #:engine #:make-engine #:free-engine #:engine-feed #:engine-take-output
   #:engine-output-pending-p #:engine-handshake #:engine-handshake-done-p
   #:engine-read #:engine-write #:engine-close-notify
   #:engine-version #:engine-ciphersuite #:engine-peer-certificate-der
   ;; the blocking stream
   #:tls-stream #:make-tls-stream #:tls-stream-engine))
