;;;; packages.lisp --- the hades/open package (#820).

(defpackage #:hades/open
  (:use #:cl)
  (:documentation "Show a file or directory in the system file manager, and open a web URL in
the default browser, without a shell (hades ADR-0001, #820).")
  (:export #:reveal-path #:open-url
           #:path-not-found #:path-not-found-path
           #:unsupported-url #:unsupported-url-url))
