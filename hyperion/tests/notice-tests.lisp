;;;; notice-tests.lisp --- in-page notices and their region (#980).
;;;;
;;;; The markup and the script NOTICE-REGION writes. Whether the script does what it says with a
;;;; real htmx is checked in hyperion/view/tests, on a real window, on CI.

(in-package #:hyperion/tests)

(def-suite notice :description "hyperion/notice: notices, their region, and the htmx error script (#980)." :in hyperion)
(in-suite notice)

(defun %notice-html (fn &rest args)
  (let ((*print-pretty* nil))
    (spin:with-html-string (apply fn args))))

(test a-notice-carries-its-severity-and-a-dismiss-button
  (dolist (severity '(:error :warning :success))
    (let* ((name (string-downcase (symbol-name severity)))
           (html (%notice-html #'hyperion/notice:notice severity "The draft was saved.")))
      (is (search (format nil "data-hyperion-notice=~A" name) html) "~A: ~A" severity html)
      (is (search (format nil "hyperion-notice-~A" name) html) "~A: ~A" severity html)
      (is (search "The draft was saved." html) "~A: ~A" severity html)
      (is (search "hyperion-notice-dismiss" html) "~A: ~A" severity html)
      (is (search ">Dismiss<" html) "~A: ~A" severity html)
      (is (null (search "role=" html))
          "the role is on the region's container, not the notice, so it is not announced twice: ~A" html)))
  (signals error (%notice-html #'hyperion/notice:notice :info "x"))
  (signals error (%notice-html #'hyperion/notice:notice "error" "x")))

(test a-notice-escapes-its-message
  (let ((html (%notice-html #'hyperion/notice:notice :error "<b>a</b> & b")))
    (is (search "&lt;b&gt;a&lt;/b&gt; &amp; b" html) "~A" html)
    (is (null (search "<b>" html)) "~A" html)))

(test the-region-has-an-assertive-container-for-errors-and-a-polite-one-for-the-rest
  (let ((html (%notice-html #'hyperion/notice:notice-region
                            :notices '((:error "It failed.") (:warning "Careful.") (:success "Saved.")))))
    (let ((alert (search "id=hyperion-notices-alert" html))
          (status (search "id=hyperion-notices-status" html)))
      (is-true alert "~A" html)
      (is-true status "~A" html)
      (is (search "id=hyperion-notices-alert role=alert aria-live=assertive" html) "~A" html)
      (is (search "id=hyperion-notices-status role=status aria-live=polite" html) "~A" html)
      (let ((failed (search "It failed." html))
            (careful (search "Careful." html))
            (saved (search "Saved." html)))
        (is (< alert failed status) "the error is in the assertive container: ~A" html)
        (is (< status careful) "the warning is in the polite container: ~A" html)
        (is (< status saved) "the success is in the polite container: ~A" html)))))

(test the-region-writes-the-htmx-error-script-unless-told-not-to
  (let ((html (%notice-html #'hyperion/notice:notice-region)))
    (is (search (hyperion/notice:notices-script) html) "the script is written whole: ~A" html)
    (is (search "data-failed=\"That did not work. Please try again.\"" html) "~A" html)
    (is (search "data-unreachable=" html) "~A" html)
    (is (search "data-dismiss=Dismiss" html) "~A" html))
  (let ((html (%notice-html #'hyperion/notice:notice-region :htmx-errors nil)))
    (is (null (search "<script" html)) "~A" html)
    (is (search "id=hyperion-notices-alert" html) "the region is still written: ~A" html))
  (is (search "<script nonce=abc123>" (%notice-html #'hyperion/notice:notice-region :nonce "abc123"))))

(test the-htmx-error-script-acts-only-where-htmx-would-drop-the-response
  ;; The conditions the script tests, read from the script itself. Whether htmx passes these
  ;; fields is checked against the vendored htmx in hyperion/view/tests.
  (let ((js (hyperion/notice:notices-script)))
    (is (search "addEventListener('htmx:beforeSwap'" js))
    (is (search "x.status<400" js) "only a status of 400 or more")
    (is (search "d.shouldSwap" js) "only when htmx is not going to swap it")
    (is (search "[data-hyperion-notices=\"off\"]" js) "not under data-hyperion-notices=off")
    (is (search "addEventListener('htmx:sendError'" js) "and when no response arrived")
    (is (search "textContent" js) "the fixed messages are written as text")
    (is (null (search "innerHTML=r." js)) "and never as HTML")))

(test notice-oob-adds-the-notice-to-its-severitys-container
  (is (search "hx-swap-oob=beforeend:#hyperion-notices-alert"
              (%notice-html #'hyperion/notice:notice-oob :error "It failed.")))
  (is (search "hx-swap-oob=beforeend:#hyperion-notices-status"
              (%notice-html #'hyperion/notice:notice-oob :warning "Careful.")))
  (is (search "hx-swap-oob=beforeend:#hyperion-notices-status"
              (%notice-html #'hyperion/notice:notice-oob :success "Saved.")))
  (signals error (%notice-html #'hyperion/notice:notice-oob :info "x")))

(test the-fixed-messages-come-from-the-translation-source
  (let ((source (i18n:make-dictionary
                 (%ht "fr" (%ht "notice" (%ht "failed" "Échec, réessayez."
                                              "dismiss" "Fermer")))
                 :default :fr)))
    (let ((html (%notice-html #'hyperion/notice:notice-region :locale "fr" :source source)))
      (is (search "Échec, réessayez." html) "~A" html)
      (is (search "data-dismiss=Fermer" html) "~A" html)
      (is (search "The server could not be reached." html)
          "a key the source lacks falls back to English: ~A" html))))
