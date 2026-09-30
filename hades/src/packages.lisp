;;;; packages.lisp --- hades packages.

(defpackage #:hades/single-instance
  (:use #:cl)
  (:documentation "One running copy of an app per user and data directory, held by the
operating system so that it is released when the process ends (hades ADR-0001, #305).")
  (:export #:acquire-single-instance #:release-single-instance #:with-single-instance
           #:lock-path
           #:single-instance-lock #:single-instance-lock-p #:single-instance-lock-path
           #:single-instance-busy #:single-instance-busy-name #:single-instance-busy-path))
