;;;; update-appimage-tests.lisp --- the Linux apply strategy: replace the AppImage file (#251)
;;;;
;;;; THE REAL STRATEGY RUNS. Unlike the Windows apply tests, nothing here substitutes
;;;; `*launch-installer*': the file is really replaced, really made executable and really
;;;; started again. What stands in for an AppImage is a shell script, because the property
;;;; under test is the file replacement and the relaunch, not the AppImage runtime, and a
;;;; script can be started on any Linux without FUSE. When started, it appends a line to a
;;;; marker file, which is how a test sees that the NEW file was the one launched.
;;;;
;;;; A real AppImage from a desktop-release dry run is applied by
;;;; scripts/verify-appimage-update.sh, which also carries the control.
;;;;
;;;; Linux only: the strategy is `#+linux' in the client's `%host-strategies'.

(in-package #:hyperion/update/client-tests)

(def-suite hyperion-update-appimage
  :description "The Linux apply strategy: replace the AppImage file (#251)."
  :in hyperion-update-client)
(in-suite hyperion-update-appimage)

#+linux
(progn

(defun appimage-script (marker version)
  "The bytes of a stand-in AppImage: a shell script that records its VERSION in MARKER."
  (utf8 (format nil "#!/bin/sh~%echo \"launched version=~A\" >> '~A'~%" version (namestring marker))))

(defun appimage-source (payload &key (sign-payload t) (format-name "appimage") (version "2.0.0"))
  "A source serving a signed manifest for this Linux host, and PAYLOAD as its AppImage."
  (let ((url (format nil "https://example.test/app-~A-x86_64.AppImage" version)))
    (multiple-value-bind (private public-text) (ensure-keys)
      (declare (ignore public-text))
      (let* ((json (utf8 (manifest-json :version version :payload-url url :format-name format-name)))
             (artifacts (make-hash-table :test #'equal)))
        (setf (gethash url artifacts) payload
              (gethash (concatenate 'string url ".sig") artifacts)
              (detached-signature private (if sign-payload payload (utf8 "different bytes entirely"))))
        (make-instance 'fixed-source :body json :signature (detached-signature private json)
                                     :artifacts artifacts)))))

(defun file-mode (path)
  (logand (sb-posix:stat-mode (sb-posix:stat (namestring path))) #o7777))

(defun wait-for-line (path needle &optional (seconds 10))
  "The contents of PATH once they contain NEEDLE, or NIL after SECONDS."
  (loop repeat (* 10 seconds)
        for text = (and (probe-file path) (uiop:read-file-string path))
        when (and text (search needle text)) return text
        do (sleep 0.1)))

(defmacro with-installed-appimage ((dir target marker) &body body)
  "A fresh directory holding TARGET, an installed version-1.0.0 stand-in AppImage (mode 755),
with the update client pointed at it as the running AppImage. The real strategy is used;
only the process exit is replaced."
  `(let* ((,dir (uiop:ensure-directory-pathname
                 (merge-pathnames (format nil "ouranos-appimage-test-~A/" (aion/random:random-hex 8))
                                  (uiop:temporary-directory))))
          (,target (merge-pathnames "app.AppImage" ,dir))
          (,marker (merge-pathnames "marker.txt" ,dir)))
     (ensure-directories-exist ,dir)
     (let ((before (staging-directories)))
       (unwind-protect
            (progn
              (with-open-file (out ,target :direction :output :element-type '(unsigned-byte 8))
                (write-sequence (appimage-script ,marker "1.0.0") out))
              (sb-posix:chmod (namestring ,target) #o755)
              (multiple-value-bind (private public-text) (ensure-keys)
                (declare (ignore private))
                (let ((*exited* nil)
                      (up:*installed-version* "1.0.0")
                      (up:*public-key* public-text)
                      (up:*app-name* "testapp")
                      (up:*install-directory* nil)          ; found from the AppImage path
                      (up:*appimage-path* (uiop:native-namestring ,target))
                      (up:*before-apply* nil)
                      (up:*launch-installer* nil)           ; the real strategy
                      (up:*exit-after-handoff* (lambda () (setf *exited* t))))
                  ,@body)))
         (ignore-errors (sb-posix:chmod (namestring ,dir) #o755))
         (ignore-errors (uiop:delete-directory-tree ,dir :validate t))
         (dolist (d (set-difference (staging-directories) before :test #'equal))
           (ignore-errors (uiop:delete-directory-tree d :validate t)))))))

(test the-install-directory-is-the-appimage-files-directory
  "Inside an AppImage the running image is in a read-only mount; the AppImage file is the
installation, so its directory is what an update writes to."
  (let ((up:*install-directory* nil)
        (up:*appimage-path* "/opt/tools/some app/App.AppImage"))
    (is (equal "/opt/tools/some app/" (up:install-directory)))))

(test an-appimage-update-replaces-the-file-makes-it-executable-and-relaunches-it
  (with-installed-appimage (dir target marker)
    (let* ((old (file-octets target))
           (payload (appimage-script marker "2.0.0"))
           (state (up:apply-update :source (appimage-source payload) :product "testapp")))
      (is (string= "applying" (getf state :status)) "apply-update returned ~S" state)
      (is (equalp payload (file-octets target)) "the AppImage file does not hold the payload")
      (is (= #o755 (file-mode target)) "the new AppImage is mode ~O, not 755" (file-mode target))
      (is (equalp old (file-octets (merge-pathnames "app.AppImage.previous" dir)))
          "the previous AppImage was not kept as app.AppImage.previous")
      (is (null (remove-if-not (lambda (p) (search ".update-" (namestring p)))
                               (uiop:directory-files dir)))
          "a temporary file was left beside the AppImage")
      (is (wait-for-line marker "launched version=2.0.0")
          "the new AppImage was not started (marker: ~S)"
          (and (probe-file marker) (uiop:read-file-string marker)))
      (is-true *exited* "the process did not exit after the relaunch"))))

(test an-appimage-update-leaves-the-data-directory-untouched
  "#111 on Linux: the update replaces one file beside the application and nothing in ~/.<app>."
  (let* ((app (format nil "ouranos-appimage-data-~A" (aion/random:random-hex 8)))
         (data (populate-app-data app)))
    (unwind-protect
         (let ((before (snapshot-tree data)))
           (with-installed-appimage (dir target marker)
             (let ((state (up:apply-update :source (appimage-source (appimage-script marker "2.0.0"))
                                           :product "testapp")))
               (is (string= "applying" (getf state :status)))
               ;; Asserted first: data that survives an update that did not happen proves nothing.
               (is (equalp (appimage-script marker "2.0.0") (file-octets target))
                   "the update did not land, so the data check below would be vacuous")
               ;; The relaunch is asynchronous. Waited for, so the new file has run before
               ;; this test's directory is removed; otherwise it starts on a missing file.
               (wait-for-line marker "launched version=2.0.0")))
           (is-untouched data before))
      (ignore-errors (uiop:delete-directory-tree data :validate t)))))

(test a-read-only-install-is-reported-not-writable-and-left-alone
  (if (zerop (sb-posix:getuid))
      (skip "running as root, which can write a mode-555 directory")
      (with-installed-appimage (dir target marker)
        (let ((old (file-octets target)))
          (sb-posix:chmod (namestring dir) #o555)
          (let ((state (up:apply-update :source (appimage-source (appimage-script marker "2.0.0"))
                                        :product "testapp")))
            (sb-posix:chmod (namestring dir) #o755)
            (is (string= "blocked" (getf state :status)) "apply-update returned ~S" state)
            (is (string= "not-writable" (getf state :block)))
            (is (equalp old (file-octets target)) "the AppImage changed")
            (is-false *exited*))))))

(test a-windows-payload-is-refused-on-linux
  "A format this build knows but this host cannot run is refused before anything is replaced."
  (with-installed-appimage (dir target marker)
    (let ((old (file-octets target)))
      (handler-case
          (progn (up:apply-update :source (appimage-source (appimage-script marker "2.0.0")
                                                           :format-name "nsis")
                                  :product "testapp")
                 (fail "an nsis payload was applied on Linux"))
        (up:update-not-implemented (e)
          (is (search "nsis" (up:update-not-implemented-detail e)))
          (is (search (platform:platform-key) (up:update-not-implemented-detail e)))))
      (is (equalp old (file-octets target)) "the AppImage changed")
      (is-false (probe-file marker) "something was launched")
      (is-false *exited*))))

(test a-payload-whose-signature-does-not-verify-is-not-installed
  (with-installed-appimage (dir target marker)
    (let ((old (file-octets target)))
      (signals up:update-source-error
        (up:apply-update :source (appimage-source (appimage-script marker "2.0.0") :sign-payload nil)
                         :product "testapp"))
      (is (equalp old (file-octets target)) "the AppImage changed")
      (is-false (probe-file marker) "something was launched")
      (is-false *exited*))))

(test the-staging-directory-is-private-to-this-user
  "The payload is written to /tmp, which every user can write to, before it is verified and
copied beside the AppImage. The staging directory is mode 700 and owned by this user."
  (let ((before (staging-directories))
        (dir (up::%staging-directory)))
    (unwind-protect
         (let ((st (sb-posix:stat (namestring dir))))
           (is (= #o700 (logand (sb-posix:stat-mode st) #o7777))
               "staging directory mode ~O" (logand (sb-posix:stat-mode st) #o7777))
           (is (= (sb-posix:getuid) (sb-posix:stat-uid st))))
      (dolist (d (set-difference (staging-directories) before :test #'equal))
        (ignore-errors (uiop:delete-directory-tree d :validate t))))))

) ; #+linux
