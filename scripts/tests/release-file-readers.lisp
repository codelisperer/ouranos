;;;; release-file-readers.lisp --- the installer and the dmg script read the bundle's RELEASE file (#408)
;;;;
;;;; build-desktop-app.lisp writes RELEASE into the bundle when it is given --product,
;;;; --display-name or --default-channel (release-settings.lisp, tested in release-settings.lisp
;;;; here). scripts/build-installer.ps1 and scripts/build-dmg.sh read it:
;;;;
;;;;   - a product or version in RELEASE must be the one the bundle itself gives (the directory's
;;;;     name on Windows; the launcher and VERSION on macOS), or the script stops, because an app
;;;;     packaged under another name is a second app to its updater;
;;;;   - build-dmg.sh takes the .app's display name from RELEASE when --display-name is not given.
;;;;
;;;; The tests run the real scripts in their describe mode (-Describe, --describe), which checks
;;;; the bundle, prints what it would build, and exits before packaging, so neither a packager nor
;;;; macOS is needed. The bundles are made here, with only the files each script checks for.
;;;; build-installer.ps1 runs where Windows is, and build-dmg.sh where it is not; each test on the
;;;; other kind of host is a skip that says so.

(in-package #:checkers/tests)

(in-suite checkers)

(defparameter +rf-app+ "ouranos-rel"
  "The fixture app's name: its launcher's name and the product its RELEASE names.")

(defun %rf-write (path text)
  (with-open-file (out path :direction :output :if-exists :supersede :if-does-not-exist :create)
    (write-string text out))
  path)

(defun %rf-release (bundle text)
  "Write TEXT as BUNDLE's RELEASE file, unless TEXT is NIL."
  (when text (%rf-write (merge-pathnames "RELEASE" bundle) text)))

(defun %rf-windows-bundle (release)
  "A fresh Windows bundle directory for version 1.2.3, holding the launcher, hyperion-view.exe
and, unless RELEASE is NIL, a RELEASE file holding RELEASE."
  (let ((bundle (uiop:ensure-directory-pathname
                 (merge-pathnames (format nil "~A-1.2.3-windows-x86-64" +rf-app+) (%fresh-tree)))))
    (ensure-directories-exist bundle)
    (%rf-write (merge-pathnames (format nil "~A.exe" +rf-app+) bundle) "")
    (%rf-write (merge-pathnames "hyperion-view.exe" bundle) "")
    (%rf-release bundle release)
    bundle))

(defun %rf-macos-bundle (release)
  "A fresh macOS bundle directory with VERSION 1.2.3: the launcher, sbcl and sbcl.core, which
build-dmg.sh checks for, and, unless RELEASE is NIL, a RELEASE file holding RELEASE."
  (let ((bundle (uiop:ensure-directory-pathname
                 (merge-pathnames (format nil "~A-1.2.3-macos-arm64" +rf-app+) (%fresh-tree)))))
    (ensure-directories-exist bundle)
    (%rf-write (merge-pathnames +rf-app+ bundle) (format nil "#!/bin/sh~%"))
    (%rf-write (merge-pathnames "sbcl" bundle) "")
    (%rf-write (merge-pathnames "sbcl.core" bundle) "")
    (%rf-write (merge-pathnames "VERSION" bundle) (format nil "1.2.3~%"))
    (uiop:run-program (list "chmod" "755" (uiop:native-namestring (merge-pathnames +rf-app+ bundle))
                            (uiop:native-namestring (merge-pathnames "sbcl" bundle))))
    (%rf-release bundle release)
    bundle))

(defun %rf-run (argv)
  "Run ARGV. (values EXIT-CODE OUTPUT), with standard error in OUTPUT."
  (multiple-value-bind (out err code)
      (uiop:run-program argv :output :string :error-output :output :ignore-error-status t)
    (declare (ignore err))
    (values code out)))

(defun %rf-installer (bundle)
  "build-installer.ps1 -Describe on BUNDLE."
  (%rf-run (list "pwsh" "-NoProfile" "-NonInteractive" "-File"
                 (uiop:native-namestring (merge-pathnames "build-installer.ps1" *scripts*))
                 (uiop:native-namestring bundle) "-Describe")))

(defun %rf-dmg (bundle &rest options)
  "build-dmg.sh --describe on BUNDLE, with OPTIONS."
  (%rf-run (list* "sh" (uiop:native-namestring (merge-pathnames "build-dmg.sh" *scripts*))
                  (uiop:native-namestring bundle) "--describe" options)))

(defmacro %rf-on-windows (&body body)
  `(if (uiop:os-windows-p)
       (progn ,@body)
       (skip "build-installer.ps1 is the Windows installer; its RELEASE check is tested on Windows")))

(defmacro %rf-off-windows (&body body)
  `(if (uiop:os-windows-p)
       (skip "build-dmg.sh is a POSIX shell script; its RELEASE check is tested on macOS and Linux")
       (progn ,@body)))

;;; --- build-installer.ps1 ---------------------------------------------------------------------

(test the-installer-describes-a-bundle-without-release
  "The control: a bundle from before RELEASE existed is described from its directory's name, as
it was built from before."
  (%rf-on-windows
    (multiple-value-bind (code output) (%rf-installer (%rf-windows-bundle nil))
      (is (= 0 code) "exit ~D, expected 0:~%~A" code output)
      (is (search (format nil "product ~A" +rf-app+) output) "no product line:~%~A" output)
      (is (search "version 1.2.3" output) "no version line:~%~A" output))))

(test the-installer-accepts-a-release-that-matches-the-bundle
  (%rf-on-windows
    (multiple-value-bind (code output)
        (%rf-installer (%rf-windows-bundle
                        (format nil "product ~A~%version 1.2.3~%channel stable~%" +rf-app+)))
      (is (= 0 code) "exit ~D, expected 0:~%~A" code output)
      (is (search (format nil "product ~A" +rf-app+) output) "no product line:~%~A" output))))

(test the-installer-refuses-a-release-naming-another-product
  "The registry key the installer writes is the name hyperion/update looks for, so an installer
built under a name other than RELEASE's product would install an app that cannot find itself."
  (%rf-on-windows
    (multiple-value-bind (code output)
        (%rf-installer (%rf-windows-bundle (format nil "product other-app~%version 1.2.3~%")))
      (is (= 1 code) "exit ~D, expected 1:~%~A" code output)
      (is (and (search "'other-app'" output) (search (format nil "'~A'" +rf-app+) output))
          "the refusal does not name both products:~%~A" output))))

(test the-installer-refuses-a-release-naming-another-version
  (%rf-on-windows
    (multiple-value-bind (code output)
        (%rf-installer (%rf-windows-bundle (format nil "product ~A~%version 1.2.4~%" +rf-app+)))
      (is (= 1 code) "exit ~D, expected 1:~%~A" code output)
      (is (and (search "'1.2.4'" output) (search "'1.2.3'" output))
          "the refusal does not name both versions:~%~A" output))))

;;; --- build-dmg.sh ----------------------------------------------------------------------------

(test the-dmg-script-names-the-app-after-its-launcher-without-release
  "The control: with no RELEASE and no --display-name, the .app is named after the launcher, as
it was before."
  (%rf-off-windows
    (multiple-value-bind (code output) (%rf-dmg (%rf-macos-bundle nil))
      (is (= 0 code) "exit ~D, expected 0:~%~A" code output)
      (is (search (format nil "display-name ~A" +rf-app+) output) "no display-name line:~%~A" output))))

(test the-dmg-script-takes-the-display-name-from-release
  (%rf-off-windows
    (multiple-value-bind (code output)
        (%rf-dmg (%rf-macos-bundle
                  (format nil "product ~A~%display-name Ouranos Rel~%version 1.2.3~%" +rf-app+)))
      (is (= 0 code) "exit ~D, expected 0:~%~A" code output)
      (is (search "display-name Ouranos Rel" output) "RELEASE's display name was not used:~%~A" output))))

(test the-dmg-script-prefers-display-name-given-on-its-command-line
  (%rf-off-windows
    (multiple-value-bind (code output)
        (%rf-dmg (%rf-macos-bundle
                  (format nil "product ~A~%display-name Ouranos Rel~%version 1.2.3~%" +rf-app+))
                 "--display-name" "From Flag")
      (is (= 0 code) "exit ~D, expected 0:~%~A" code output)
      (is (search "display-name From Flag" output) "--display-name did not win:~%~A" output))))

(test the-dmg-script-refuses-a-release-naming-another-product
  (%rf-off-windows
    (multiple-value-bind (code output)
        (%rf-dmg (%rf-macos-bundle (format nil "product other-app~%version 1.2.3~%")))
      (is (= 2 code) "exit ~D, expected 2:~%~A" code output)
      (is (and (search "'other-app'" output) (search (format nil "'~A'" +rf-app+) output))
          "the refusal does not name both products:~%~A" output))))

(test the-dmg-script-refuses-a-release-naming-another-version
  "RELEASE written without a final newline, as a hand edit may leave it: the last line is still
read."
  (%rf-off-windows
    (multiple-value-bind (code output)
        (%rf-dmg (%rf-macos-bundle (format nil "product ~A~%version 9.9.9" +rf-app+)))
      (is (= 2 code) "exit ~D, expected 2:~%~A" code output)
      (is (and (search "'9.9.9'" output) (search "'1.2.3'" output))
          "the refusal does not name both versions:~%~A" output))))
