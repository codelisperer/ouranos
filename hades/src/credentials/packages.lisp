;;;; packages.lisp --- the hades/credentials package (#357).

(defpackage #:hades/credentials
  (:use #:cl)
  #+win32 (:local-nicknames (#:ffi #:aion/windows/ffi))
  (:documentation "A credential store over the operating system's own: store, fetch and delete a
secret by service and account. Fetch returns an AION/SECRET (hades ADR-0001, #357).")
  (:export #:store-credential #:fetch-credential #:delete-credential
           #:credential-error #:credential-error-service #:credential-error-account
           #:credential-error-operation #:credential-error-code
           #:credential-not-found #:credential-store-unavailable
           #:credential-store-unavailable-reason
           #:credential-too-large #:credential-too-large-size #:credential-too-large-limit))
