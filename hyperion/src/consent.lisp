;;;; consent.lisp --- Cookie / tracking consent (GDPR, ePrivacy, CCPA).
;;;;
;;;; The machinery for lawful cookie/tracking consent, factored the same way as
;;;; i18n: a small taxonomy, a pluggable STORE protocol (cookie now; a
;;;; mnemosyne-backed consent LOG later -- accountability wants an audit trail),
;;;; request seams, and an HTMX-first banner. The framework owns the taxonomy,
;;;; persistence seam, and wiring; the app owns copy, routes, look, and the store.
;;;;
;;;; Principles baked in (see docs/compliance-design.md):
;;;;   - Necessary categories are exempt from opt-in and can never be rejected.
;;;;   - Optional categories default to OFF until an explicit, affirmative choice
;;;;     (opt-in, not opt-out) -- GDPR/ePrivacy require this.
;;;;   - A version bump re-prompts everyone (policy changed => fresh consent).

(in-package #:hyperion/consent)

;;; --- taxonomy -----------------------------------------------------------

(defparameter *necessary-categories* '(:necessary)
  "Categories exempt from consent -- strictly necessary for the service to function
(session, security, load-balancing, locale choice). Always granted; cannot be
rejected. GDPR/ePrivacy do not require opt-in for these.")

(defparameter *consent-categories* '(:necessary :preferences :analytics :marketing)
  "The consent taxonomy, necessary first. The framework only tracks which categories
are granted; the app presents labels/copy. Everything not in *NECESSARY-CATEGORIES*
is optional and requires explicit opt-in.")

(defparameter *consent-version* 1
  "The policy version encoded in the stored consent. Bump when the cookie policy
materially changes: older stored consent is then treated as undecided, re-prompting.")

(defun consent-category-p (x)
  "True if X is a known consent category keyword."
  (and (member x *consent-categories*) t))

(defun optional-categories ()
  "The categories a visitor may accept or reject (all but the necessary set), in
declaration order."
  (remove-if (lambda (c) (member c *necessary-categories*)) *consent-categories*))

;;; --- consent values -----------------------------------------------------
;;; A consent value is a list of granted category keywords (necessary always
;;; included). The sentinel :UNDECIDED means no affirmative choice yet.

(defun normalize-consent (categories)
  "Canonicalize granted CATEGORIES: necessary always included, unknown dropped,
deduped, ordered by *CONSENT-CATEGORIES*."
  (let ((granted (union (copy-list *necessary-categories*)
                        (remove-if-not #'consent-category-p categories))))
    (remove-if-not (lambda (c) (member c granted)) *consent-categories*)))

(defun consent-allows-p (consent category)
  "True if CATEGORY is permitted under CONSENT (a granted-keyword list). Necessary
categories are always allowed; under :UNDECIDED/NIL only necessary is allowed (so
optional cookies stay off until opt-in)."
  (or (and (member category *necessary-categories*) t)
      (and (listp consent) (member category consent) t)))

;;; --- (de)serialization --------------------------------------------------

(defun %split (string char)
  "Split STRING on CHAR into a list of substrings (empties dropped)."
  (loop with start = 0
        for pos = (position char string :start start)
        for part = (subseq string start (or pos (length string)))
        unless (string= part "") collect part
        while pos do (setf start (1+ pos))))

(defun %serialize (categories)
  "Granted CATEGORIES -> cookie value, e.g. \"v1:necessary,analytics\"."
  (format nil "v~D:~{~(~A~)~^,~}" *consent-version* (normalize-consent categories)))

(defun %parse (string)
  "Parse a consent cookie value -> granted keyword list, or :UNDECIDED if it is
absent, malformed, or from a different policy version (forcing re-consent)."
  (if (or (null string) (string= string ""))
      :undecided
      (let ((colon (position #\: string)))
        (if (and colon (char= (char string 0) #\v))
            (let ((ver (ignore-errors (parse-integer string :start 1 :end colon)))
                  (body (subseq string (1+ colon))))
              (if (eql ver *consent-version*)
                  (normalize-consent
                   (mapcar (lambda (s) (intern (string-upcase s) :keyword))
                           (%split body #\,)))
                  :undecided))
            :undecided))))

;;; --- store protocol -----------------------------------------------------
;;; Same shape as i18n's locale-store: READ from the request, PERSIST to response
;;; headers. A cookie backend ships here; a session/DB (mnemosyne) consent log is
;;; an app/data-layer concern later.

(defgeneric read-consent (store request)
  (:documentation "The visitor's granted categories from STORE for REQUEST, or the
sentinel :UNDECIDED when no affirmative choice has been recorded."))

(defgeneric persist-consent (store categories)
  (:documentation "Return response header plist persisting granted CATEGORIES (e.g.
(:set-cookie ...)). Appendable to a Clack response's headers."))

(defparameter *consent-cookie-name* "hy_consent"
  "Cookie name for the default cookie-consent store.")

(defparameter *consent-max-age* (* 60 60 24 180)
  "Consent cookie lifetime in seconds (~6 months); after it lapses the banner
returns and the visitor re-consents.")

(defclass cookie-consent-store ()
  ((name    :initarg :name    :reader store-name    :initform *consent-cookie-name*)
   (max-age :initarg :max-age :reader store-max-age :initform *consent-max-age*))
  (:documentation "Stores the consent decision in a first-party cookie -- a strictly
necessary cookie itself (it records a legal choice), so it needs no consent."))

(defun make-cookie-consent-store (&key (name *consent-cookie-name*)
                                       (max-age *consent-max-age*))
  "A cookie-backed consent store."
  (make-instance 'cookie-consent-store :name name :max-age max-age))

(defmethod read-consent ((store cookie-consent-store) request)
  (%parse (http:cookie request (store-name store))))

(defmethod persist-consent ((store cookie-consent-store) categories)
  (list :set-cookie
        (format nil "~A=~A; Path=/; Max-Age=~D; SameSite=Lax"
                (store-name store) (%serialize categories) (store-max-age store))))

;;; --- request seam -------------------------------------------------------

(defun consent-decided-p (store request)
  "True once the visitor has made an affirmative choice (so the banner can hide)."
  (not (eq :undecided (read-consent store request))))

(defun resolve-consent (store request)
  "The granted categories in effect for REQUEST: the stored decision, or a
necessary-only list while undecided (optional stays off until opt-in)."
  (let ((c (read-consent store request)))
    (if (eq c :undecided) (copy-list *necessary-categories*) c)))

;;; --- the banner (HTMX-first component) ----------------------------------

(defun consent-banner (&key action-href policy-href message
                            accept-label reject-label
                            (policy-label "Cookie Policy")
                            (target-id "hy-consent-banner"))
  "Render (as an HTML string) an HTMX cookie-consent banner. The app shows it only
while consent is undecided (see CONSENT-DECIDED-P). Two explicit, equally-weighted
choices -- accept optional categories, or necessary-only -- plus a link to the
cookie policy; there is no pre-ticked default (opt-in, not opt-out). Both buttons
hx-post to ACTION-HREF with a `consent` field (\"all\" or \"necessary\"); the app
persists via PERSIST-CONSENT and returns an empty body to remove the banner. All
copy and URLs are app-supplied so i18n and routing stay in the app; the app styles
`.hy-consent-banner*` (framework ships markup + wiring, not a theme)."
  (let ((sel (format nil "#~A" target-id)))
    (spin:with-html-string
      (:div :id target-id :class "hy-consent-banner" :role "dialog"
            :aria-live "polite" :aria-label "Cookie consent"
        (:p :class "hy-consent-banner__message"
          message
          (when policy-href
            (:span " "
              (:a :class "hy-consent-banner__policy" :href policy-href policy-label))))
        (:div :class "hy-consent-banner__actions"
          (:button :type "button"
                   :class "hy-consent-banner__btn hy-consent-banner__btn--reject"
                   :hx-post action-href :hx-vals "{\"consent\": \"necessary\"}"
                   :hx-target sel :hx-swap "outerHTML"
            reject-label)
          (:button :type "button"
                   :class "hy-consent-banner__btn hy-consent-banner__btn--accept"
                   :hx-post action-href :hx-vals "{\"consent\": \"all\"}"
                   :hx-target sel :hx-swap "outerHTML"
            accept-label))))))
