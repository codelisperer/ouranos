;;;; appdata-survival-driver.lisp --- run a REAL apply, for #224's harness.
;;;;
;;;;     sbcl --script scripts/appdata-survival-driver.lisp \
;;;;          --dist DIR --product NAME --channel stable \
;;;;          --installed-version 1.0.0 --app-name APP --public-key BASE64
;;;;
;;;; Driven by `scripts/verify-appdata-survives.ps1'; not useful on its own.
;;;;
;;;; THE POINT IS THAT ALMOST NOTHING IS SUBSTITUTED. `hyperion/update/tests' covers the
;;;; client with `*launch-installer*' stubbed, which is the right thing for a suite and is
;;;; evidence about the client only -- the installer is the half that can delete a
;;;; directory. Here the generic runs for real: `apply-update' re-checks, verifies the
;;;; manifest signature over the bytes the generator wrote, refuses unless the state is
;;;; `available', finds the install directory THROUGH THE REGISTRY the installer wrote,
;;;; probes it for writability, downloads and verifies the payload, and hands the staged
;;;; installer to NSIS or Inno with the flags the manifest's `format' selects.
;;;;
;;;; TWO THINGS ARE STILL SUBSTITUTED, AND BOTH ARE NAMED HERE RATHER THAN DISCOVERED:
;;;;
;;;;   THE SOURCE is a directory rather than HTTP. `fetch-manifest'/`fetch-artifact' are a
;;;;   documented protocol with pluggable backends (design §5) and this is one -- the same
;;;;   standing as `null-source'. It is deliberate: a local HTTP server would add a way for
;;;;   the harness to fail that has nothing to do with whether a user's data survives, and
;;;;   the fetch path has its own coverage. The base URL is `.invalid', so anything that
;;;;   did reach for the network would fail loudly instead of quietly succeeding.
;;;;
;;;;   THE PROCESS EXIT is a no-op, because this driver has to survive to report. On a real
;;;;   machine the app exits here so nothing holds the bundle; here the driver is not IN the
;;;;   bundle and holds no handle on it, so the installer meets the same empty directory it
;;;;   would meet after a real exit. What that does mean is that this harness says nothing
;;;;   about the shutdown ORDERING -- that is `*before-apply*' and #76 measured it
;;;;   separately.
;;;;
;;;; THE MANIFEST IS READ AS `<channel>.json', which is what `hyperion/update' asks an HTTP
;;;; source for. The generator wrote `latest.json' until #77 and the harness renamed it by
;;;; hand; both the rename and the disagreement are gone.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (read-from-string "ql:quickload") '(:hyperion/update) :silent t)

(defpackage #:appdata-survival-driver
  (:use #:common-lisp)
  (:local-nicknames (#:up #:hyperion/update)))
(in-package #:appdata-survival-driver)

(defun arg (name &optional default)
  (let ((tail (member name (rest sb-ext:*posix-argv*) :test #'string=)))
    (or (second tail) default)))

(defun die (fmt &rest args)
  (format *error-output* "~&driver: ~?~%" fmt args)
  (finish-output *error-output*)
  (sb-ext:quit :unix-status 2))

(defun require-arg (name) (or (arg name) (die "~A is required" name)))

(defun file-bytes (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence bytes in)
      bytes)))

;;; --- the source ------------------------------------------------------------
;;;
;;; `hyperion/update:directory-source' -- promoted into the framework under #77, because
;;; the release gate needs exactly the same thing and two copies of a source is two chances
;;; to disagree with the client about where a file lives. It is a documented backend of the
;;; `fetch-manifest'/`fetch-artifact' protocol (design section 5), the same standing as
;;; `null-source', and it has its own tests in the suite.

;;; --- the run ---------------------------------------------------------------

(let ((dist (uiop:ensure-directory-pathname (require-arg "--dist")))
      (product (require-arg "--product"))
      (channel (arg "--channel" "stable"))
      (installed (require-arg "--installed-version"))
      (app (require-arg "--app-name"))
      (public (require-arg "--public-key")))
  (setf up:*installed-version* installed
        up:*public-key* public
        up:*app-name* app
        ;; NOT set: `*install-directory*'. Leaving it NIL is the point -- the client must
        ;; find the install through HKCU\Software\<APPNAME>\InstallDir, the value the
        ;; installer itself wrote. That contract is what #206 was about, and a harness that
        ;; handed the answer in would be testing the harness.
        up:*install-directory* nil
        up:*before-apply* nil
        ;; The real generic. This is the whole reason the harness exists.
        up:*launch-installer* nil
        up:*exit-after-handoff* (lambda () nil))
  (let ((source (make-instance 'up:directory-source :path dist)))
    (format t "~&installed-version : ~A~%" installed)
    (format t "app-name          : ~A~%" app)
    (let ((found (up:install-directory)))
      (format t "install-directory : ~A~%" (or found "<NOT FOUND>"))
      (unless found
        (die "the client could not find the install directory -- did the installer write HKCU\\Software\\~A\\InstallDir?" app)))
    (let ((status (up:check-for-update :source source :channel channel :product product)))
      (format t "check             : ~S~%" status)
      (unless (string= "available" (getf status :status))
        (die "the check did not offer an update: ~S" status)))
    (let ((state (handler-case (up:apply-update :source source :channel channel
                                                :product product)
                   (error (e)
                     (die "apply-update signalled: ~A" e)))))
      (format t "apply             : ~S~%" state)
      (finish-output)
      (sb-ext:quit :unix-status (if (string= "applying" (getf state :status)) 0 3)))))
