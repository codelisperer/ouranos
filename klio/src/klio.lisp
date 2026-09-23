;;;; klio.lisp --- the content engine.
;;;;
;;;; WHY THERE IS A SERVER AT ALL, since §1 of docs/launch/sites-and-cms.md argues content
;;;; should NOT be in a database: a klio site is not an SPA, so HTMX fragments are GENERATED
;;;; on demand. Pre-generated fragments could be served statically; anything parameterised --
;;;; search over the boot-built index, filtered pagination, forms -- cannot, and those are
;;;; the ordinary case.
;;;;
;;;; WHERE KLIO STOPS: at the database. No database needed -> klio is enough. A database
;;;; needed -> the site wants a full hyperion web service. That boundary is the product.

(cl:in-package #:klio)

(defparameter +version+ "0.0.0" "klio version.")

(defun version ()
  "Return the klio version string."
  +version+)
