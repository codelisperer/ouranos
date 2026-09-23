;;;; http-tests.lisp --- urlencoded parameter reading (#136).
;;;;
;;;; The bug these pin is silent, partial data loss: FORM-PARAM returned the first value of
;;;; a repeated field and there was no error and no empty value to notice, so a checkbox
;;;; group that recorded one of three ticks looked exactly like a working form. Tests here
;;;; assert the plural reader returns everything, AND that the singular one keeps its
;;;; documented first-wins behaviour rather than signalling -- because the body is
;;;; client-supplied and a reader that signalled would be a remote way to break any handler.

(in-package #:hyperion/tests)

(def-suite http :description "Raw-Clack request helpers: urlencoded params." :in hyperion)
(in-suite http)

(defun %http-env (&key query body headers)
  "A minimal Clack env carrying a query string and/or headers."
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on headers by #'cddr do (setf (gethash (string-downcase k) h) v))
    (list :query-string query :headers h :raw-body body)))

;;; --- the repeated field, which is the whole issue --------------------------

(test form-params-returns-every-value-of-a-repeated-field
  ;; What an HTML checkbox group actually posts.
  (is (equal '("alpha" "beta" "gamma")
             (http:form-params "community=alpha&community=beta&community=gamma" "community"))))

(test form-params-keeps-document-order
  ;; Order is meaningful for <select multiple> and for anything the user ranked.
  (is (equal '("c" "a" "b") (http:form-params "x=c&x=a&x=b" "x"))))

(test form-params-picks-out-only-the-named-field
  (is (equal '("1" "2")
             (http:form-params "other=z&n=1&mid=q&n=2&last=w" "n"))))

(test form-params-is-nil-for-an-absent-field
  (is (null (http:form-params "a=1&b=2" "missing")))
  (is (null (http:form-params "" "a")))
  (is (null (http:form-params nil "a"))))

(test form-param-takes-the-first-and-does-not-signal
  ;; The deliberate decision: total over client-supplied input. A repeated name must not be
  ;; a way for anyone posting a form to raise an unhandled condition in a handler.
  (is (string= "alpha" (http:form-param "community=alpha&community=beta" "community")))
  (finishes (http:form-param "x=1&x=2&x=3" "x"))
  (is (null (http:form-param "a=1" "nope"))))

;;; --- decoding --------------------------------------------------------------

(test values-are-url-decoded-including-plus-as-space
  ;; `+` for space is what application/x-www-form-urlencoded actually sends; a reader that
  ;; only handled %20 would corrupt every multi-word field.
  (is (equal '("hello world") (http:form-params "q=hello+world" "q")))
  (is (equal '("hello world") (http:form-params "q=hello%20world" "q")))
  (is (equal '("café") (http:form-params "q=caf%C3%A9" "q")))
  ;; a value containing an encoded separator must survive intact
  (is (equal '("a&b=c") (http:form-params "q=a%26b%3Dc" "q"))))

(test an-empty-value-is-the-empty-string-not-absence
  ;; A cleared text input posts `name=`; that is a value, and losing the distinction
  ;; between "" and absent is how a form silently stops clearing fields.
  (is (equal '("") (http:form-params "name=" "name")))
  (is (string= "" (http:form-param "name=" "name")))
  (is (null (http:form-params "name=" "other"))))

(test a-pair-without-an-equals-sign-is-skipped
  ;; Long-standing behaviour, preserved deliberately: a bare `?debug` reads as ABSENT.
  ;; Making it read as "" would flip every (when (query-param env "debug") ...) in existing
  ;; code from false to true, which is a larger change than #136 and not part of it.
  (is (null (http:form-params "debug" "debug")))
  (is (equal '("1") (http:form-params "debug&x=1" "x"))))

;;; --- one parser, shared ----------------------------------------------------

(test form-alist-walks-the-body-once-and-keeps-repeats
  ;; The accessor for a handler reading several fields: one pass, not one per field.
  (let ((alist (http:form-alist "a=1&b=2&a=3")))
    (is (= 3 (length alist)))
    (is (equal '("a" "b" "a") (mapcar #'car alist)))
    (is (equal '("1" "2" "3") (mapcar #'cdr alist)))))

(test the-singular-and-plural-readers-agree
  ;; They must not drift: the singular IS the first of the plural, by construction.
  (dolist (body '("x=1" "x=1&x=2" "a=0&x=9&x=8" "x=" ""))
    (is (equal (http:form-param body "x") (first (http:form-params body "x")))
        "disagreement on ~S" body)))

;;; --- query strings get the same treatment ----------------------------------

(test query-params-reads-repeated-query-keys
  ;; ?tag=a&tag=b is as legal as a repeated form field, and had the same bug.
  (let ((env (%http-env :query "tag=a&tag=b&page=2")))
    (is (equal '("a" "b") (http:query-params env "tag")))
    (is (string= "a" (http:query-param env "tag")))
    (is (string= "2" (http:query-param env "page")))
    (is (null (http:query-params env "missing")))))

(test query-params-tolerates-a-missing-query-string
  (let ((env (%http-env)))
    (is (null (http:query-params env "tag")))
    (is (null (http:query-param env "tag")))))

;;; --- neighbours that share the module --------------------------------------

(test request-header-is-case-insensitive
  (let ((env (%http-env :headers '("X-Request-Id" "abc123"))))
    (is (string= "abc123" (http:request-header env "x-request-id")))
    (is (string= "abc123" (http:request-header env "X-Request-Id")))
    (is (null (http:request-header env "absent")))))

(test cookie-reads-one-value-from-the-cookie-header
  (let ((env (%http-env :headers '("Cookie" "lang=ru; hyperion-session=abc; theme=dark"))))
    (is (string= "ru" (http:cookie env "lang")))
    (is (string= "abc" (http:cookie env "hyperion-session")))
    (is (string= "dark" (http:cookie env "theme")))
    (is (null (http:cookie env "missing")))))

(test wants-json-reads-accept-or-content-type
  (is (http:wants-json (%http-env :headers '("Accept" "application/json"))))
  (is (not (http:wants-json (%http-env :headers '("Accept" "text/html")))))
  (is (not (http:wants-json (%http-env)))))

;;; --- the request body has a ceiling (#211) ---------------------------------
;;;
;;; BODY-STRING allocated exactly what Content-Length claimed, before reading a byte. So an
;;; unauthenticated request consisting of a HEADER AND NO BODY could allocate arbitrarily
;;; much -- the cheapest possible request buying the largest possible allocation.
;;;
;;; On a default SBCL image (1 GB dynamic space) that is fatal rather than merely wasteful.
;;; Measured while fixing it: the allocation can SUCCEED under memory overcommit and the
;;; process then dies as the pages are touched, and a large enough length aborts outright.
;;; So "it allocates a lot" understates it -- the failure mode is a dead worker.
;;;
;;; It is also the defect I made visible: #143 put a ceiling on the multipart path fifteen
;;; lines below this one and did not extend it here. A bound on one body reader and none on
;;; its neighbour is worse than neither, because the presence of a limit reads as the
;;; question having been asked.

(defun %body-env (octets &key content-length)
  "A Clack env whose raw body is OCTETS, with CONTENT-LENGTH claiming whatever we like --
which is the point: the header is attacker-controlled and the body may not match it."
  (list :raw-body (flexi-streams:make-in-memory-input-stream octets)
        :content-length (or content-length (length octets))))

(defun %octets (string)
  (sb-ext:string-to-octets string :external-format :utf-8))

(test a-body-within-the-ceiling-reads-normally
  (let ((env (%body-env (%octets "name=ada&role=admin"))))
    (is (string= "name=ada&role=admin" (http:body-string env)))))

(test a-content-length-over-the-ceiling-is-refused-before-the-stream-is-touched
  ;; The cheap attack is a header. Refusing on the claim is the cheap defence, and it must
  ;; happen before anything is allocated or read.
  (let ((env (%body-env (%octets "x") :content-length 2000000000)))
    (signals http:body-too-large (http:body-string env))))

(test the-condition-reports-both-the-limit-and-the-claim
  ;; An operator seeing this needs to know what was asked for as well as what is allowed.
  (handler-case
      (progn (http:body-string (%body-env (%octets "x") :content-length 999999999))
             (fail "should have signalled"))
    (http:body-too-large (c)
      (is (= http:*max-body-size* (http:body-too-large-limit c)))
      (is (= 999999999 (http:body-too-large-claimed c))))))

(test A-LYING-CONTENT-LENGTH-COSTS-THE-ATTACKER-AND-THE-SERVER-NOTHING
  ;; THE test. Capping alone is not enough: if the allocation still sizes itself from the
  ;; header, a client that claims the maximum and sends one byte gets the maximum allocation
  ;; for free. Reading in chunks makes the cost proportional to what was actually sent.
  ;;
  ;; A claim just under the ceiling, with a one-byte body. Before the fix this allocated
  ;; nearly 20 MB; now it allocates in 8 KB steps and stops when the stream does.
  (let ((env (%body-env (%octets "x") :content-length (1- http:*max-body-size*))))
    (is (string= "x" (http:body-string env))
        "the real body is returned, and the claim bought nothing")))

(test a-body-that-exceeds-the-ceiling-while-streaming-is-refused
  ;; The other direction: an honest-looking small header with a body that keeps coming.
  ;; Chunked reading has to notice mid-stream rather than only at the start.
  (let* ((big (make-array (+ 1024 (* 64 1024)) :element-type '(unsigned-byte 8)
                                               :initial-element 65))
         (env (list :raw-body (flexi-streams:make-in-memory-input-stream big)
                    :content-length 10)))
    (let ((http:*max-body-size* (* 32 1024)))
      (signals http:body-too-large (http:body-string env)))))

(test the-ceiling-is-adjustable-per-call-and-globally
  (let ((env (%body-env (%octets "hello"))))
    (signals http:body-too-large (http:body-string env :max-size 2))
    (is (string= "hello" (http:body-string (%body-env (%octets "hello")) :max-size 1000))))
  (let ((http:*max-body-size* 2))
    (signals http:body-too-large (http:body-string (%body-env (%octets "hello"))))))

(test an-absent-body-is-still-nil-rather-than-an-error
  ;; A GET has no body. The ceiling must not turn that into a failure.
  (is (null (http:body-string (list :raw-body nil :content-length nil))))
  (is (null (http:body-string (%body-env (%octets "") :content-length 0)))))

(test the-multipart-ceiling-and-the-body-ceiling-are-now-the-same-knob
  ;; The inconsistency that made this findable: one reader bounded, its neighbour not.
  (is (integerp http:*max-body-size*))
  (is (= (* 20 1024 1024) http:*max-body-size*)
      "one default, governing every body reader"))
