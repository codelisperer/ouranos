;;;; conditions.lisp --- what aion/cdp signals (#1028).

(cl:in-package #:aion/cdp)

(define-condition cdp-condition (error) ()
  (:documentation "The parent of every condition aion/cdp signals about a browser."))

(define-condition browser-not-found (cdp-condition)
  ((executable :initarg :executable :initform nil :reader browser-not-found-executable))
  (:report (lambda (c s)
             (if (browser-not-found-executable c)
                 (format s "The browser ~A does not exist." (browser-not-found-executable c))
                 (format s "No Chrome or Edge was found. Set OURANOS_BROWSER to a browser executable."))))
  (:documentation "No browser to launch: FIND-BROWSER found none, or the one named does not exist."))

(define-condition browser-exited (cdp-condition)
  ((code :initarg :code :initform nil :reader browser-exited-code)
   (output :initarg :output :initform "" :reader browser-exited-output))
  (:report (lambda (c s)
             (format s "The browser exited~@[ with code ~A~] before it was ready.~@[~%Its last output:~%~A~]"
                     (browser-exited-code c)
                     (let ((o (browser-exited-output c))) (and (plusp (length o)) o)))))
  (:documentation "The browser process ended while it was being started or used. OUTPUT is the end
of what it wrote to standard error."))

(define-condition cdp-error (cdp-condition)
  ((method :initarg :method :initform nil :reader cdp-error-method)
   (code :initarg :code :initform nil :reader cdp-error-code)
   (message :initarg :message :initform "" :reader cdp-error-message))
  (:report (lambda (c s)
             (format s "~@[~A: ~]~A~@[ (CDP error ~A)~]"
                     (cdp-error-method c) (cdp-error-message c) (cdp-error-code c))))
  (:documentation "The browser answered a command with an error. CODE and MESSAGE are the
protocol's own error object."))

(define-condition evaluation-error (cdp-error) ()
  (:documentation "JavaScript run by EVALUATE threw, or its promise was rejected. MESSAGE is the
exception's description."))

(define-condition element-not-found (cdp-error)
  ((selector :initarg :selector :reader element-not-found-selector))
  (:report (lambda (c s)
             (format s "No element matches the selector ~S." (element-not-found-selector c))))
  (:documentation "A command that acts on an element found no element for its selector."))

(define-condition cdp-timeout (cdp-condition)
  ((what :initarg :what :reader cdp-timeout-what)
   (seconds :initarg :seconds :reader cdp-timeout-seconds))
  (:report (lambda (c s)
             (format s "~A did not finish within ~A seconds."
                     (cdp-timeout-what c) (cdp-timeout-seconds c))))
  (:documentation "A command, a wait, or the browser's start took longer than its timeout."))

(define-condition target-crashed (cdp-condition)
  ((target-id :initarg :target-id :initform nil :reader target-crashed-target-id))
  (:report (lambda (c s)
             (format s "The page~@[ ~A~] crashed." (target-crashed-target-id c))))
  (:documentation "The page's renderer crashed. Every later command on the page signals this."))

(define-condition connection-closed (cdp-condition)
  ((reason :initarg :reason :initform "" :reader connection-closed-reason))
  (:report (lambda (c s)
             (format s "The connection to the browser is closed: ~A" (connection-closed-reason c))))
  (:documentation "The connection to the browser ended, so no command can be answered."))
