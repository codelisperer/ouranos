;;;; release-settings.lisp --- what a release build sets in the image it dumps (#408)
;;;;
;;;; Loaded by path by scripts/build-desktop-app.lisp. A built app needs four settings of
;;;; hyperion/update, and before this nothing set them outside the test drivers:
;;;;
;;;;   --product NAME          up:*app-name*: the installer's registry key and the manifest's
;;;;                           product. Must equal --name for now.
;;;;   --display-name TEXT     what the user sees. Written to the bundle's RELEASE file; nothing
;;;;                           in the image reads it yet.
;;;;   --public-key-file PATH  up:*public-key*: the key releases are signed with. With --release
;;;;                           and no key file, the variable *PUBLIC-KEY-VARIABLE* names is read.
;;;;   --update-source K=URL   up:*update-source*: K is github or s3. Given more than once, the
;;;;                           sources are tried in the order given.
;;;;   --default-channel NAME  up:*default-channel*.
;;;;   --release               refuse to build without a key and a source, so a release cannot
;;;;                           ship a build that can never update.
;;;;
;;;; A setting is set in the image only when its option is given. An app may set any of these
;;;; variables in its own source, and a build without the option keeps the app's value (hub's
;;;; review of #568: --name used to overwrite an app's own *app-name*).
;;;;
;;;; Its own file, rather than part of build-desktop-app.lisp, because that script ends in a dump
;;;; and nothing can load it; scripts/tests/release-settings.lisp loads this one.
;;;;
;;;; TWO THINGS THE MAINTAINER HAS NOT DECIDED (#408), each kept to one place here so that the
;;;; decision is a small change:
;;;;   - the name of the variable a CI job puts the public key in: *PUBLIC-KEY-VARIABLE*;
;;;;   - whether a build trusts one key or a list, for rotation: %KEYS-FOR-IMAGE. Today a key file
;;;;     may hold only one key, because up:*public-key* holds one.

(require :asdf)

(defpackage #:ouranos-release-settings
  (:use #:cl)
  (:export #:*public-key-variable* #:parse-release-settings #:release-settings-argv
           #:release-settings-refused #:apply-release-settings #:release-file-text
           #:settings-given-p))

(in-package #:ouranos-release-settings)

(defparameter *public-key-variable* "OURANOS_PUBLIC_KEY"
  "The environment variable read for the public key when --public-key-file is not given. The
same name as the repository variable desktop-release.yml already passes to its checks.")

(defparameter *source-kinds* '(("github" . "GITHUB-RELEASE-SOURCE") ("s3" . "S3-SOURCE"))
  "Each --update-source kind and the hyperion/update class it makes.")

(define-condition release-settings-refused (error)
  ((reason :initarg :reason :reader refused-reason))
  (:report (lambda (c s) (format s "~A" (refused-reason c)))))

(defun %refuse (control &rest args)
  (error 'release-settings-refused :reason (apply #'format nil control args)))

(defun %option-values (argv name)
  "Every value given for NAME in ARGV, in order."
  (loop for (option value) on argv
        when (string= option name)
          collect (or value (%refuse "~A needs a value" name))))

(defun %option-value (argv name)
  (let ((values (%option-values argv name)))
    (when (rest values) (%refuse "~A was given more than once" name))
    (first values)))

(defun %product-name-p (text)
  "Letters, digits, dot, dash and underscore, starting with a letter or digit: a name that is
safe as a Windows registry key, a file name and a manifest product."
  (and (plusp (length text)) (<= (length text) 64)
       (alphanumericp (char text 0))
       (every (lambda (c) (and (< (char-code c) 128) (or (alphanumericp c) (find c ".-_")))) text)))

(defun %channel-name-p (text)
  (and (plusp (length text)) (<= (length text) 32)
       (every (lambda (c) (and (< (char-code c) 128)
                               (or (lower-case-p c) (digit-char-p c) (char= c #\-))))
              text)))

(defun %read-keys (path)
  "The non-blank, non-comment lines of the key file at PATH. A path that is missing, a
directory, or a file that cannot be read is refused, with exit code 2 like any bad option
(review of #568)."
  (cond ((uiop:directory-exists-p (uiop:ensure-directory-pathname path))
         (%refuse "--public-key-file ~A is a directory" path))
        ((not (probe-file path))
         (%refuse "--public-key-file ~A does not exist" path)))
  (let ((lines (handler-case (uiop:read-file-lines path)
                 (error (e) (%refuse "--public-key-file ~A cannot be read: ~A" path e)))))
    (loop for line in lines
          for text = (string-trim '(#\Space #\Tab #\Return) line)
          unless (or (zerop (length text)) (char= (char text 0) #\#))
            collect text)))

(defun %public-key-text-p (text)
  "Whether TEXT has the form aion/signature:encode-key gives a public key: 32 bytes as standard
base64, which is 43 characters of the base64 alphabet and one = (44 in all). Checked when the
options are parsed, so a key that is not one stops the build with exit code 2 before anything
is built (review of #568). The image decodes it again before the dump."
  (and (= 44 (length text))
       (char= #\= (char text 43))
       (every (lambda (c) (and (< (char-code c) 128) (or (alphanumericp c) (find c "+/"))))
              (subseq text 0 43))))

(defun %keys-for-image (keys)
  "The value up:*public-key* is set to, from the keys given. ONE KEY, until the maintainer decides
how rotation works (#408): change this, and hyperion/update's %trusted-key, to accept a list."
  (dolist (key keys)
    (unless (%public-key-text-p key)
      (%refuse "~S is not a public key: one is 44 characters of base64, as scripts/update-manifest.lisp keygen prints it" key)))
  (cond ((null keys) nil)
        ((rest keys)
         (%refuse "the key file holds ~D keys; this build trusts one key until rotation is decided (#408)"
                  (length keys)))
        (t (first keys))))

(defun %https-url-problem (url)
  "Why URL cannot be an update source, or NIL when it can: it must be https, with a host. The
host is the part after https:// up to the first /, ? or #, less a :port. It must be a DNS name
(letters, digits, dots and dashes, not starting or ending with a dot or dash), and a port, when
given, 1 to 65535. Credentials before an @ are refused: they would be built into the image.
\"https://\" alone used to pass, and satisfied --release's need for a source (#588)."
  (if (not (uiop:string-prefix-p "https://" url))
      "the URL must start with https://"
      (let* ((rest (subseq url (length "https://")))
             (end (or (position-if (lambda (c) (find c "/?#")) rest) (length rest)))
             (authority (subseq rest 0 end))
             (colon (position #\: authority))
             (host (subseq authority 0 (or colon (length authority))))
             (port (and colon (subseq authority (1+ colon)))))
        (cond ((find #\@ authority) "the URL must not carry credentials before an @")
              ((zerop (length host)) "the URL has no host after https://")
              ((not (and (every (lambda (c) (and (< (char-code c) 128)
                                                 (or (alphanumericp c) (find c ".-"))))
                                host)
                         (not (find (char host 0) ".-"))
                         (not (find (char host (1- (length host))) ".-"))))
               (format nil "the host ~S is not a DNS name" host))
              ((and port (not (and (plusp (length port)) (<= (length port) 5)
                                   (every #'digit-char-p port)
                                   (<= 1 (parse-integer port) 65535))))
               (format nil "the port ~S is not a number from 1 to 65535" port))))))

(defun %update-sources (argv)
  "((class-name . url) ...) from each --update-source, in order."
  (loop for value in (%option-values argv "--update-source")
        for split = (position #\= value)
        for kind = (and split (subseq value 0 split))
        for url = (and split (subseq value (1+ split)))
        for class = (cdr (assoc kind *source-kinds* :test #'string=))
        do (cond ((null split) (%refuse "--update-source ~A is not KIND=URL" value))
                 ((null class) (%refuse "--update-source kind ~S is not one of ~{~A~^, ~}"
                                        kind (mapcar #'car *source-kinds*)))
                 ((%https-url-problem url)
                  (%refuse "--update-source ~A: ~A" value (%https-url-problem url))))
        collect (cons class (if (uiop:string-suffix-p url "/") url (concatenate 'string url "/")))))

(defun parse-release-settings (argv &key name (getenv #'uiop:getenv))
  "The release settings ARGV gives, as a plist: :PRODUCT :DISPLAY-NAME :PUBLIC-KEY :SOURCES
:CHANNEL :RELEASE. Each is NIL when its option is not given, so the image keeps whatever the app
set. NAME is the build's --name, which --product must equal. GETENV reads the environment, so a
test can give it one; the key variable is read only with --release. Signals
RELEASE-SETTINGS-REFUSED, with the reason, for anything it cannot use."
  (let* ((product (%option-value argv "--product"))
         (display-name (%option-value argv "--display-name"))
         (key-file (%option-value argv "--public-key-file"))
         (release (and (member "--release" argv :test #'string=) t))
         (keys (cond (key-file (%read-keys key-file))
                     ;; Only for a release build: a developer's machine with the variable set
                     ;; must not replace a key an app set itself.
                     (release
                      (let ((v (funcall getenv *public-key-variable*)))
                        (and v (plusp (length (string-trim " " v))) (list (string-trim " " v)))))))
         (channel (%option-value argv "--default-channel"))
         (sources (%update-sources argv)))
    (when product
      (unless (%product-name-p product)
        (%refuse "--product ~S must be letters, digits, dot, dash or underscore, at most 64, starting with a letter or digit" product))
      ;; The installer still takes its name from the bundle directory, which --name names. Until
      ;; it reads the product, the two must agree, or the installer registers under one name and
      ;; the app looks for itself under the other.
      (when (and name (string/= product name))
        (%refuse "--product ~A differs from --name ~A; the installer registers under --name, so they must be the same for now (#408)" product name)))
    (when display-name
      (unless (and (plusp (length display-name)) (<= (length display-name) 128)
                   (notany (lambda (c) (< (char-code c) 32)) display-name))
        (%refuse "--display-name must be 1 to 128 characters with no control characters")))
    (when channel
      (unless (%channel-name-p channel)
        (%refuse "--default-channel ~S must be lowercase letters, digits and dashes" channel)))
    (when release
      (unless keys
        (%refuse "--release needs the public key: --public-key-file, or the variable ~A" *public-key-variable*))
      (unless sources
        (%refuse "--release needs at least one --update-source")))
    (list :product product :display-name display-name :public-key (%keys-for-image keys)
          :sources sources :channel channel :release release)))

(defun settings-given-p (argv)
  "Whether ARGV gives any release setting, so the app must load hyperion/update. --product and
--display-name count: each names something hyperion/update holds, so giving one for an app
without it is a mistake to report, not to accept (review of #568)."
  (some (lambda (option) (member option argv :test #'string=))
        '("--product" "--display-name" "--public-key-file" "--update-source" "--default-channel"
          "--release")))

(defun release-settings-argv (argv)
  "The release options in ARGV, to pass on to the Windows child build unchanged."
  (loop for (option value) on argv
        when (member option '("--product" "--display-name" "--public-key-file" "--update-source"
                              "--default-channel")
                     :test #'string=)
          append (list option value)
        when (string= option "--release")
          append (list option)))

(defun release-file-text (settings version)
  "The bundle's RELEASE file, one KEY VALUE line each, for the installer and the dmg script to read
rather than parsing the bundle directory's name: version, and product, display-name and channel
for each that was given. NIL when none of those three was given, and then no file is written, so
the file never names a product or channel the image does not have."
  (when (or (getf settings :product) (getf settings :display-name) (getf settings :channel))
    (with-output-to-string (out)
      (when (getf settings :product) (format out "product ~A~%" (getf settings :product)))
      (when (getf settings :display-name) (format out "display-name ~A~%" (getf settings :display-name)))
      (format out "version ~A~%" version)
      (when (getf settings :channel) (format out "channel ~A~%" (getf settings :channel))))))

(defun %update-symbol (name)
  (let ((package (find-package "HYPERION/UPDATE")))
    (and package (find-symbol name package))))

(defun apply-release-settings (settings &key (given t))
  "Set hyperion/update's variables in this image from SETTINGS, for the dump: only those whose
option was given, so a variable the app set itself keeps its value. When GIVEN, some release
option was given, and an image without hyperion/update is refused. The key is checked with
aion/signature before it is set, so a build carrying a key that cannot be decoded is refused
rather than shipped. Returns true when hyperion/update is in the image."
  (let ((app-name (%update-symbol "*APP-NAME*")))
    (cond
      ((null app-name)
       (when given
         (%refuse "a release option was given, but this app does not load hyperion/update"))
       nil)
      (t
       (when (getf settings :product)
         (setf (symbol-value app-name) (getf settings :product)))
       (when (getf settings :channel)
         (setf (symbol-value (%update-symbol "*DEFAULT-CHANNEL*")) (getf settings :channel)))
       (let ((key (getf settings :public-key)))
         (when key
           (handler-case (uiop:symbol-call "AION/SIGNATURE" "DECODE-PUBLIC-KEY" key)
             (error (e) (%refuse "the public key cannot be decoded: ~A" e)))
           (setf (symbol-value (%update-symbol "*PUBLIC-KEY*")) key)))
       (let ((sources (loop for (class . url) in (getf settings :sources)
                            collect (make-instance (%update-symbol class)
                                                   (intern "BASE-URL" "KEYWORD") url))))
         (when sources
           (setf (symbol-value (%update-symbol "*UPDATE-SOURCE*"))
                 (if (rest sources) sources (first sources)))))
       t))))
