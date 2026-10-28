;;;; notice.lisp --- in-page notices, and htmx 2 error responses shown in them (#980).
;;;;
;;;; A notice tells the user, on the page they are on, that something failed, needs attention, or
;;;; worked. It is not stored and does not follow the user to another page; the notification list
;;;; in #792 is that. NOTICE-REGION writes the place notices appear, NOTICE writes one, and
;;;; NOTICE-OOB writes one for an htmx response to add to the region out of band.
;;;;
;;;; THE REGION. Two containers, one per politeness: errors in role="alert" aria-live="assertive",
;;;; warnings and successes in role="status" aria-live="polite". A screen reader announces what is
;;;; added to a live region that was already in the page, so the containers are written with the
;;;; page and stay empty until a notice arrives. The roles and aria-live are on the containers and
;;;; not on each notice, because a live region inside another live region is announced twice by
;;;; some screen readers.
;;;;
;;;; HTMX ERROR RESPONSES. htmx 2 does not swap a 4xx or 5xx response: the default
;;;; htmx.config.responseHandling has {code: "[45]..", swap: false, error: true}. A server that
;;;; answers an htmx request with an error and an explanation therefore shows the user nothing.
;;;; NOTICE-REGION also writes a script (+NOTICES-SCRIPT+) that listens for htmx:beforeSwap. When
;;;; the response's status is 400 or more and htmx is not going to swap it, the script adds the
;;;; response's notices (elements with data-hyperion-notice, as NOTICE writes them) to the region,
;;;; or, when it has none, a notice with a fixed message. It also listens for htmx:sendError, which
;;;; htmx fires when no response arrived, and shows a second fixed message.
;;;;
;;;; WHY AN EVENT LISTENER AND NOT htmx.config.responseHandling. responseHandling can send an error
;;;; response to a target, but it swaps whatever the body is: it cannot put a fixed message in place
;;;; of an empty body or a server's whole HTML error page, and it cannot send an error notice and a
;;;; warning to different containers. It is also one array, so setting it from here would replace
;;;; an app's own setting. The listener acts only when htmx's own decision was not to swap
;;;; (detail.shouldSwap is false), so an app that already swaps an error response, such as a 422
;;;; form re-rendered with its errors through responseHandling or its own htmx:beforeSwap listener
;;;; that runs first, keeps that behaviour. The detail fields used here are the ones htmx 2.0.11,
;;;; the version hyperion/assets vendors, passes to htmx:beforeSwap: xhr, elt, shouldSwap and
;;;; serverResponse.
;;;;
;;;; TURNING IT OFF. NOTICE-REGION :HTMX-ERRORS NIL writes the region without the script. An
;;;; element with data-hyperion-notices="off", or inside one, is left to the app: its error
;;;; responses are not shown here.

(in-package #:hyperion/notice)

(defparameter +severities+ '(:error :warning :success)
  "The three severities. :ERROR: something the user asked for did not happen. :WARNING: it
happened, or can still happen, but the user should know something first. :SUCCESS: it happened.")

(defparameter +region-id+ "hyperion-notices")
(defparameter +alert-id+ "hyperion-notices-alert")
(defparameter +status-id+ "hyperion-notices-status")

(defparameter +english+
  '(:notice/failed "That did not work. Please try again."
    :notice/unreachable "The server could not be reached. Check the connection and try again."
    :notice/dismiss "Dismiss")
  "The English text for every key this package looks up; used when there is no source, or when
the source has the key in neither the requested nor its default locale.")

(defun %text (locale key source)
  (if (and source (i18n:translation-exists-p source locale key))
      (i18n:translate source locale key)
      (getf +english+ key)))

(defun %check-severity (severity)
  (unless (member severity +severities+)
    (error "hyperion/notice: SEVERITY must be one of ~{~S~^, ~}, not ~S" +severities+ severity))
  severity)

(defun %container-id (severity)
  (if (eq severity :error) +alert-id+ +status-id+))

(defparameter +notices-script+
  "(function(){if(window.hyperionNotices)return;window.hyperionNotices=true;function region(){return document.getElementById('hyperion-notices');}function off(elt){return !!(elt&&elt.closest&&elt.closest('[data-hyperion-notices=\"off\"]'));}function place(nodes){for(var i=0;i<nodes.length;i++){var n=nodes[i];var id=n.getAttribute('data-hyperion-notice')==='error'?'hyperion-notices-alert':'hyperion-notices-status';var box=document.getElementById(id);if(box)box.appendChild(n);}}function fixed(r,key){var n=document.createElement('div');n.className='hyperion-notice hyperion-notice-error';n.setAttribute('data-hyperion-notice','error');var p=document.createElement('p');p.textContent=r.getAttribute(key)||'';n.appendChild(p);var b=document.createElement('button');b.type='button';b.className='hyperion-notice-dismiss';b.textContent=r.getAttribute('data-dismiss')||'';b.setAttribute('onclick',\"this.closest('[data-hyperion-notice]').remove()\");n.appendChild(b);return [n];}document.addEventListener('htmx:beforeSwap',function(e){var d=e.detail,x=d.xhr,r=region();if(!r||!x||x.status<400||d.shouldSwap||off(d.elt))return;var t=document.createElement('template');t.innerHTML=typeof d.serverResponse==='string'?d.serverResponse:'';var found=Array.prototype.slice.call(t.content.querySelectorAll('[data-hyperion-notice]'));place(found.length?found:fixed(r,'data-failed'));});document.addEventListener('htmx:sendError',function(e){var r=region();if(!r||off(e.detail.elt))return;place(fixed(r,'data-unreachable'));});})();"
  "The script NOTICE-REGION writes with :HTMX-ERRORS T; see this file's header. The fixed
messages and the dismiss label come from the region's data-failed, data-unreachable and
data-dismiss attributes, so the script itself holds no text to translate.")

(defun notices-script ()
  "The script NOTICE-REGION writes with :HTMX-ERRORS T, as a string. For an app whose
Content-Security-Policy allows scripts only from its own origin or by hash: serve this from a
route, or hash it, and call NOTICE-REGION with :HTMX-ERRORS NIL."
  +notices-script+)

(defun notice (severity message &key (locale "en") (source i18n:*translation-source*))
  "Write one notice into SPINNERET:*HTML*: MESSAGE, with a button that removes it. SEVERITY is
:ERROR, :WARNING or :SUCCESS (see +SEVERITIES+). The notice carries data-hyperion-notice, set to
the severity, and the classes hyperion-notice and hyperion-notice-SEVERITY; the app styles them.

Write MESSAGE as one or two plain sentences: what happened, then what the user can do, if
anything. \"The file was not saved because the disk is full. Free some space and save again.\"
A success says what was done: \"The draft was saved.\" No error codes, no \"Error!\" on its own,
and no exclamation marks; the severity is already shown by where the notice appears and how it
is styled.

To show a notice from an htmx response: for an error response (status 400 or more), return the
notice as the body, and NOTICE-REGION's script adds it to the region. For a response htmx swaps,
add it with NOTICE-OOB. On a page rendered whole, pass it to NOTICE-REGION as :NOTICES."
  (%check-severity severity)
  (let ((name (string-downcase (symbol-name severity))))
    (spin:with-html
      (:div :class (format nil "hyperion-notice hyperion-notice-~A" name)
            :data-hyperion-notice name
        (:p message)
        (:button :type "button" :class "hyperion-notice-dismiss"
                 :onclick "this.closest('[data-hyperion-notice]').remove()"
          (%text locale :notice/dismiss source))))))

(defun notice-oob (severity message &rest options &key locale source)
  "Write NOTICE for SEVERITY and MESSAGE wrapped for an htmx out-of-band swap, so a response
htmx swaps somewhere else also adds the notice to the region. htmx 2 swaps the wrapper's contents,
the notice, into the region's container for SEVERITY with beforeend; the wrapper is dropped."
  (declare (ignore locale source))
  (%check-severity severity)
  (spin:with-html
    (:div :hx-swap-oob (format nil "beforeend:#~A" (%container-id severity))
      (apply #'notice severity message options))))

(defun notice-region (&key notices (htmx-errors t) nonce (locale "en")
                           (source i18n:*translation-source*))
  "Write the place notices appear into SPINNERET:*HTML*, once per page, where they should show.
It is a div#hyperion-notices holding two containers: div#hyperion-notices-alert, role=\"alert\"
and aria-live=\"assertive\", for :ERROR notices, and div#hyperion-notices-status, role=\"status\"
and aria-live=\"polite\", for :WARNING and :SUCCESS ones.

NOTICES is a list of (SEVERITY MESSAGE) to show when the page loads, each written with NOTICE.

With HTMX-ERRORS true, the default, it also writes +NOTICES-SCRIPT+, which shows an htmx error
response here instead of letting htmx 2 drop it; see this file's header. The fixed messages are
:notice/failed and :notice/unreachable from LOCALE and SOURCE, in English when a key is missing.
NONCE, when given, is written on the script for a Content-Security-Policy that uses nonces."
  (spin:with-html
    (:div :id +region-id+ :class "hyperion-notices"
          :data-failed (%text locale :notice/failed source)
          :data-unreachable (%text locale :notice/unreachable source)
          :data-dismiss (%text locale :notice/dismiss source)
      (:div :id +alert-id+ :role "alert" :aria-live "assertive"
        (loop for (severity message) in notices
              when (eq (%check-severity severity) :error)
                do (notice severity message :locale locale :source source)))
      (:div :id +status-id+ :role "status" :aria-live "polite"
        (loop for (severity message) in notices
              unless (eq severity :error)
                do (notice severity message :locale locale :source source))))
    (when htmx-errors
      (:script :nonce nonce (:raw +notices-script+)))))
