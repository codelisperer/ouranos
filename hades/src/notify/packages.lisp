;;;; packages.lisp --- the hades/notify package (#819).

(defpackage #:hades/notify
  (:use #:cl)
  #+win32 (:local-nicknames (#:ffi #:aion/windows/ffi))
  (:documentation "A modal notice with one OK button that works before an app has a window,
and that writes to standard error where no notice can be shown (hades ADR-0001, #819).")
  (:export #:notify-user #:*notify-backend*))
