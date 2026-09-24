;;;; security-headers.lisp --- default HTTP security headers on every response (#119)
;;;;
;;;; hyperion/docs/middleware-security.md lists the headers a server-rendered app should send
;;;; as defense in depth behind escape-by-default output. Until #119 none were sent unless an
;;;; application wrote them itself, and an application finds a missing one from an incident
;;;; report. WRAP-SECURITY-HEADERS sends them, and HYPERION/SERVER:START applies it by default.
;;;;
;;;; WHAT THE DEFAULTS ARE, AND WHY THE CSP IS NARROW.
;;;;
;;;;   X-Content-Type-Options: nosniff
;;;;       The browser must not sniff a response into a type it was not sent as -- a user upload
;;;;       served as text/plain must not run as HTML.
;;;;   X-Frame-Options: DENY, and CSP frame-ancestors 'none'
;;;;       No page can be framed by another site, so an account page with a destructive button
;;;;       cannot be clickjacked. Both, because older browsers read only X-Frame-Options.
;;;;   Referrer-Policy: strict-origin-when-cross-origin
;;;;       A cross-origin request carries the origin only, never the path, so a
;;;;       capability-bearing URL (an invite or reset link) does not leak to a third party.
;;;;   Content-Security-Policy: frame-ancestors 'none'; base-uri 'self'; object-src 'none'
;;;;       Only directives that do not depend on the page's markup. There is deliberately NO
;;;;       script-src or style-src by default: every page in this tree (the three hyperion
;;;;       examples and praxeon/web) inlines its compiled Parenscript in a <script> element, two
;;;;       examples load Alpine, whose standard build evaluates expressions at run time, and
;;;;       hyperion/dev injects an inline poller. A default of script-src 'self' would break
;;;;       every one of them. An application that emits no inline script sets
;;;;       *CONTENT-SECURITY-POLICY*, or passes :CONTENT-SECURITY-POLICY, with its own policy.
;;;;   Strict-Transport-Security: not sent unless asked for (*HSTS*, :HSTS, HSTS-VALUE)
;;;;       Deployment-shaped: it binds the browser to HTTPS for the whole host for as long as
;;;;       max-age says, and hyperion does not terminate TLS itself (#125), so it cannot know
;;;;       the deployment is HTTPS-only. `preload' is a separate opt-in because a preload-list
;;;;       entry is close to irreversible.
;;;;
;;;; OVERRIDING. Each header has a special variable and a keyword argument of the same name
;;;; (without earmuffs). A string replaces the default; NIL turns the header off. A header the
;;;; application sets on its own response is never replaced, so a single route can loosen or
;;;; tighten one header without the wrapper knowing about the route.

(in-package #:hyperion/security-headers)

(defvar *content-type-options* "nosniff"
  "The X-Content-Type-Options value WRAP-SECURITY-HEADERS sends, or NIL for none.")

(defvar *frame-options* "DENY"
  "The X-Frame-Options value WRAP-SECURITY-HEADERS sends, or NIL for none.")

(defvar *referrer-policy* "strict-origin-when-cross-origin"
  "The Referrer-Policy value WRAP-SECURITY-HEADERS sends, or NIL for none.")

(defvar *content-security-policy* "frame-ancestors 'none'; base-uri 'self'; object-src 'none'"
  "The Content-Security-Policy WRAP-SECURITY-HEADERS sends, or NIL for none. It has no
script-src or style-src; see this file's header for why, and set a full policy here for an
application that emits no inline script.")

(defvar *hsts* nil
  "The Strict-Transport-Security value WRAP-SECURITY-HEADERS sends, or NIL (the default) for
none. Build one with HSTS-VALUE.")

(defun hsts-value (&key (max-age 31536000) (include-subdomains t) preload)
  "A Strict-Transport-Security value. MAX-AGE is in seconds (default one year). PRELOAD is off
unless given, because a preload-list entry is close to irreversible."
  (format nil "max-age=~D~:[~;; includeSubDomains~]~:[~;; preload~]"
          max-age include-subdomains preload))

(defun %header-present-p (headers key)
  "Whether the response HEADERS plist already carries KEY, compared without regard to case so
an application that spelled it differently is still respected."
  (loop for (k nil) on headers by #'cddr
        thereis (and (or (symbolp k) (stringp k))
                     (string-equal (string k) (string key)))))

(defun wrap-security-headers (app &key (content-type-options *content-type-options*)
                                       (frame-options *frame-options*)
                                       (referrer-policy *referrer-policy*)
                                       (content-security-policy *content-security-policy*)
                                       (hsts *hsts*))
  "Ring middleware adding security headers to every response APP returns as (status headers
body), including a streamed body. Each keyword takes a string to send or NIL to omit; the
defaults come from the special variables of the same names, read when this is called. A header
already on the response is left as the application set it. Any other response shape is passed
through unchanged."
  (let ((add (remove nil
                     (list (and content-type-options (cons :x-content-type-options content-type-options))
                           (and frame-options (cons :x-frame-options frame-options))
                           (and referrer-policy (cons :referrer-policy referrer-policy))
                           (and content-security-policy
                                (cons :content-security-policy content-security-policy))
                           (and hsts (cons :strict-transport-security hsts))))))
    (lambda (env)
      (let ((res (funcall app env)))
        (if (and (consp res) (= (length res) 3) (listp (second res)))
            (destructuring-bind (status headers body) res
              (list status
                    (append headers
                            (loop for (key . value) in add
                                  unless (%header-present-p headers key)
                                    append (list key value)))
                    body))
            res)))))
