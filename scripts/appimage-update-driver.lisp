;;;; appimage-update-driver.lisp --- run the real Linux apply path once (#251)
;;;;
;;;;   APPIMAGE=<installed AppImage> sbcl --script scripts/appimage-update-driver.lisp \
;;;;     --dist DIR --product P --installed-version 1.0.0 --app-name A --public-key K [--control]
;;;;
;;;; Called by scripts/verify-appimage-update.sh, which builds the installation and the signed
;;;; release this reads. The Linux counterpart of appdata-survival-driver.lisp (#111).
;;;;
;;;; WHAT IS REAL: the manifest and payload signatures (a key made for the run), the check,
;;;; the staging, the `appimage' strategy that replaces the file and starts the new one, and
;;;; the way the client finds the installation -- through $APPIMAGE, which the AppImage
;;;; runtime sets, and which the harness sets here instead. `*appimage-path*' is NOT set: a
;;;; harness that handed the client its answer would be testing the harness.
;;;;
;;;; WHAT IS SUBSTITUTED: the source is a directory rather than HTTP, and the process exit
;;;; after the hand-off is a no-op, so this driver can report what happened.
;;;;
;;;; --control: after the real strategy has replaced the file and started it, make the file
;;;; mode 644, which is what an apply that forgot `chmod +x' would leave. The harness must
;;;; then FAIL; if it passes, it cannot see that defect.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (read-from-string "ql:quickload") '(:hyperion/update) :silent t)

(defpackage #:appimage-update-driver
  (:use #:common-lisp)
  (:local-nicknames (#:up #:hyperion/update)))
(in-package #:appimage-update-driver)

(defun arg (name &optional default)
  (let ((tail (member name (rest sb-ext:*posix-argv*) :test #'string=)))
    (or (second tail) default)))

(defun flag (name) (and (member name (rest sb-ext:*posix-argv*) :test #'string=) t))

(defun die (fmt &rest args)
  (format *error-output* "~&driver: ~?~%" fmt args)
  (finish-output *error-output*)
  (sb-ext:quit :unix-status 2))

(defun require-arg (name) (or (arg name) (die "~A is required" name)))

(when (flag "--control")
  (defmethod up:launch-installer :around ((format (eql :appimage)) installer install-dir)
    (declare (ignore installer install-dir))
    (prog1 (call-next-method)
      (sb-posix:chmod (up:appimage-path) #o644)
      (format t "~&CONTROL: the installed AppImage was made mode 644 after the apply~%"))))

(let ((dist (uiop:ensure-directory-pathname (require-arg "--dist")))
      (product (require-arg "--product"))
      (channel (arg "--channel" "stable"))
      (installed (require-arg "--installed-version"))
      (app (require-arg "--app-name"))
      (public (require-arg "--public-key")))
  (setf up:*installed-version* installed
        up:*public-key* public
        up:*app-name* app
        up:*install-directory* nil       ; found from $APPIMAGE, as in a real AppImage
        up:*before-apply* nil
        up:*launch-installer* nil        ; the real strategy
        up:*exit-after-handoff* (lambda () nil))
  (let ((source (make-instance 'up:directory-source :path dist)))
    (format t "~&installed-version : ~A~%" installed)
    (format t "APPIMAGE          : ~A~%" (or (up:appimage-path) "<NOT SET>"))
    (unless (up:appimage-path) (die "APPIMAGE is not set"))
    (format t "install-directory : ~A~%" (up:install-directory))
    (let ((status (up:check-for-update :source source :channel channel :product product)))
      (format t "check             : ~S~%" status)
      (unless (string= "available" (getf status :status))
        (die "the check did not offer an update: ~S" status)))
    (let ((state (handler-case (up:apply-update :source source :channel channel :product product)
                   (error (e) (die "apply-update signalled: ~A" e)))))
      (format t "apply             : ~S~%" state)
      (finish-output)
      (sb-ext:quit :unix-status (if (string= "applying" (getf state :status)) 0 3)))))
