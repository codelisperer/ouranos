;;;; update-manifest.lisp --- generate and sign the release manifest (pre-publication issue 75).
;;;;
;;;;   sbcl --script scripts/update-manifest.lisp keygen
;;;;   sbcl --script scripts/update-manifest.lisp generate --dist dist --product NAME \
;;;;        --version 1.2.3 --base-url URL [--channel stable] [--notes-url URL] \
;;;;        [--windows-format nsis|inno]
;;;;   sbcl --script scripts/update-manifest.lisp sign   --key-file PATH FILE...
;;;;   sbcl --script scripts/update-manifest.lisp verify --public-key BASE64 FILE
;;;;
;;;; THE MANIFEST IS THE CONTRACT between CI and every installed app: one signed JSON
;;;; document per channel at a permanent URL. Its shape is
;;;; hyperion/docs/desktop-distribution-design.md section 3, and the client half is the
;;;; update module in a consuming app today, moving to hyperion/update (pre-publication issue 76).
;;;;
;;;; THE SIGNATURE IS OVER THE EXACT BYTES OF THE FILE, detached, alongside it as `.sig'.
;;;; That is not a stylistic choice. If the signature covered a re-serialisation, then any
;;;; difference in key order, whitespace or number formatting between the generator's JSON
;;;; writer and the client's would break every signature -- and it would break them at the
;;;; customer, on a version bump, months after anyone touched the code. Signing bytes means
;;;; the client verifies what it actually received and never re-encodes anything.
;;;;
;;;; A NOTE ON DRIFT, because this tree has already been bitten by exactly it. The manifest
;;;; field names live here AND in the client's parser, which is two copies of one contract.
;;;; That is the same shape as pre-publication issue 206 (platform-key in a build script the client cannot load),
;;;; where the failure mode is a client that reports itself up to date forever. It is
;;;; tolerable only because the client is being moved into hyperion/update (pre-publication issue 76); when it
;;;; lands, the schema belongs in one place and this script should consume it rather than
;;;; restate it. Recorded here so it is a known debt rather than a discovery.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (read-from-string "ql:quickload") '(:aion/signature :com.inuoe.jzon :ironclad) :silent t)

(defpackage #:update-manifest
  (:use #:common-lisp)
  (:local-nicknames (#:sig #:aion/signature) (#:json #:com.inuoe.jzon)))
(in-package #:update-manifest)

(defparameter *schema* 1 "The manifest schema version. Bump deliberately; clients branch on it.")

;;; --- argv -------------------------------------------------------------------

(defun arg (name &optional default)
  (let ((tail (member name (rest sb-ext:*posix-argv*) :test #'string=)))
    (or (second tail) default)))

(defun require-arg (name)
  (or (arg name) (die "~A is required" name)))

(defun die (fmt &rest args)
  (format *error-output* "~&update-manifest: ~?~%" fmt args)
  (finish-output *error-output*)
  (sb-ext:quit :unix-status 2))

;;; --- hashing ------------------------------------------------------------------

(defun file-bytes (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence bytes in)
      bytes)))

(defun sha256-hex (path)
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence :sha256 (file-bytes path))))

;;; --- keys ---------------------------------------------------------------------

(defun cmd-keygen ()
  "Print a fresh key pair. The PRIVATE half goes to a CI secret and a password manager."
  (multiple-value-bind (private public) (sig:generate-key-pair)
    (format t "~&public  (ships inside the bundle): ~A~%" (sig:encode-key public))
    (format t "private (CI secret + password-manager backup, NEVER committed):~%~A~%"
            (sig:encode-key private))
    ;; Said here rather than in a runbook nobody opens at the moment they need it.
    (format t "~%A LOST PRIVATE KEY STRANDS EVERY INSTALLED APP -- it is the only thing that~%")
    (format t "can sign an update they will accept. Back it up somewhere that survives this~%")
    (format t "machine before you ship anything signed with it.~%")))

(defun read-private-key ()
  "The signing key, from --key-file or the OURANOS_SIGNING_KEY environment variable.

A FILE OR AN ENVIRONMENT VARIABLE, never a command-line argument: argv is visible to every
other process on the machine via the process list, and CI logs echo command lines."
  (let ((file (arg "--key-file"))
        (env (uiop:getenv "OURANOS_SIGNING_KEY")))
    (cond
      (file (sig:decode-private-key (string-trim '(#\Space #\Newline #\Return)
                                                 (uiop:read-file-string file))))
      ((and env (plusp (length env)))
       (sig:decode-private-key (string-trim '(#\Space #\Newline #\Return) env)))
      (t (die "no signing key: pass --key-file PATH or set OURANOS_SIGNING_KEY")))))

;;; --- signing ------------------------------------------------------------------

(defun sign-file (private-key path)
  "Write PATH.sig, a detached signature over PATH's exact bytes. Returns the base64 signature."
  (let* ((signature (sig:sign private-key (file-bytes path)))
         (encoded (cl-base64:usb8-array-to-base64-string signature))
         (out (concatenate 'string (namestring path) ".sig")))
    (with-open-file (s out :direction :output :if-exists :supersede
                           :external-format :utf-8)
      (write-string encoded s)
      (terpri s))
    encoded))

(defun files-to-sign (argv)
  "The FILES in ARGV, with every flag AND ITS VALUE removed.

EVERY FLAG IN THIS SCRIPT TAKES A VALUE, so a token beginning with `-' consumes the token
after it. The old filter dropped only the flag, which meant

    sign --key-file secret.key payload.exe

signed `secret.key' as well -- writing a `.sig' beside a private key, and silently signing
the wrong file if a path was ever mistyped. It never failed loudly, because signing a file
that is not meant to be signed looks exactly like signing one that is."
  (let ((files '()))
    (loop while argv
          for token = (pop argv)
          do (if (uiop:string-prefix-p "-" token)
                 (pop argv)              ; the flag's value, never a file
                 (push token files)))
    (nreverse files)))

(defun cmd-sign ()
  (let* ((key-file (arg "--key-file"))
         (key (read-private-key))
         (files (files-to-sign (cddr sb-ext:*posix-argv*))))
    (when (null files) (die "sign: no files given"))
    (dolist (f files)
      (unless (probe-file f) (die "sign: no such file: ~A" f))
      ;; The belt to the parse's braces. If a boolean flag is ever added above, the
      ;; pairing goes wrong quietly -- and the one file that must never be signed is the
      ;; one holding the key doing the signing.
      (when (and key-file (equal (probe-file f) (probe-file key-file)))
        (die "sign: refusing to sign the signing key itself (~A)" f))
      (when (uiop:string-suffix-p f ".sig")
        (die "sign: ~A is already a signature; signing it would write ~A.sig" f f))
      (format t "~&signed ~A -> ~:*~A.sig~%" f)
      (sign-file key f))))

(defun verify-detached (public-key path)
  "True when PATH.sig is a valid signature over PATH's exact bytes under PUBLIC-KEY."
  (let ((sig-file (concatenate 'string (namestring path) ".sig")))
    (and (probe-file sig-file)
         (sig:verify public-key (file-bytes path)
                     (cl-base64:base64-string-to-usb8-array
                      (string-trim '(#\Space #\Newline #\Return)
                                   (uiop:read-file-string sig-file)))))))

(defun cmd-verify ()
  "Verify FILE against FILE.sig with a public key. The check CI should run on its own output."
  (let* ((public (sig:decode-public-key (require-arg "--public-key")))
         (file (or (car (last sb-ext:*posix-argv*)) (die "verify: no file")))
         (sig-file (concatenate 'string file ".sig")))
    (unless (probe-file file) (die "verify: no such file: ~A" file))
    (unless (probe-file sig-file) (die "verify: no signature at ~A" sig-file))
    (let ((ok (verify-detached public file)))
      (format t "~&~A: ~:[DOES NOT VERIFY~;verified~]~%" file ok)
      (sb-ext:quit :unix-status (if ok 0 1)))))

;;; --- the manifest ---------------------------------------------------------------

(defparameter *platforms*
  '(("windows-x86-64" "nsis"      "~A-~A-setup.exe")
    ("linux-x86-64"   "appimage"  "~A-~A-x86_64.AppImage")
    ("macos-arm64"    "app-targz" "~A-~A-macos-arm64.app.tar.gz"))
  "Platform key, apply strategy, and the artifact name the matrix produces for it.

ONE PATTERN PER PLATFORM, and they are not interchangeable -- an earlier draft tried every
pattern and took the first that existed, which happily listed the Windows installer as the
macOS payload. It produced a perfectly well-formed manifest that would have handed every Mac
an .exe. Tests caught it; a release would not have, because nothing downstream checks that an
artifact matches the platform it is filed under.

FORMAT here is the FALLBACK, not the answer. It is explicit rather than inferred by the
client from its own OS, so a product can change packaging without shipping a new client
first (design section 3) -- but a table cannot know which packaging a given build actually
used, and until `detect-format' existed this entry was the answer, hard-coded to \"nsis\".
`build-installer.ps1 -Format inno' writes its artifact under the SAME filename, so an Inno
release was published as `nsis' and every client would have handed Inno NSIS's flags:
`/S /D=', which installs nothing and exits 0. See `windows-format' below.")

(defparameter +format-markers+
  '(("nsis" "NullsoftInst" "Nullsoft Install System")
    ("inno" "Inno Setup Setup Data" "JR.Inno.Setup"))
  "Byte strings that identify a packaging FROM THE ARTIFACT ITSELF.

THE PRODUCER SHOULD MEASURE, NOT BE TOLD. Every producer/consumer defect this subsystem has
had -- the platform key (pre-publication issue 206), the `.sig' encoding, this field -- is one contract named
twice in two places that cannot see each other. A flag would move the drift rather than
remove it: someone would have to remember to pass it, and forgetting is silent. Reading the
artifact makes the manifest a statement about the bytes being published.

MEASURED, both directions, against installers this tree builds from one bundle:

  nsis-setup.exe    NullsoftInst @52232, Nullsoft Install System @51222; no Inno marker
  inno-setup.exe    Inno Setup Setup Data @738060, JR.Inno.Setup @885057; no NSIS marker

Mutually exclusive in both directions, which is the property that makes a contradiction
worth refusing over.")

(defun detect-format (file)
  "The packaging FILE actually is, or NIL when nothing here recognises it.

NIL IS NOT A FAILURE AND NOT A DEFAULT -- it means `this script has never met this
packaging', which is a normal thing for a new one to be. What the caller does about it
depends on the platform, and for Windows the answer is to refuse: see `windows-format'."
  (let ((bytes (file-bytes file)))
    (loop for (name . markers) in +format-markers+
          when (every (lambda (m)
                        (search (sb-ext:string-to-octets m :external-format :latin-1) bytes))
                      markers)
            return name)))

(defun windows-format (file)
  "What to declare for a Windows artifact. Detected, or an explicit `--windows-format'.

NEVER GUESSES, AND NEVER FALLS BACK TO THE TABLE. The table's entry is a real strategy, and
a wrong real strategy is worse than none: the client would run an installer with another
installer's flags, silently, on a user's machine. So an unrecognised Windows artifact stops
the release and asks, and an explicit flag that CONTRADICTS the bytes stops it too --
publishing a manifest that misdescribes its own payload is the whole defect this replaces."
  (let ((detected (detect-format file))
        (declared (arg "--windows-format")))
    (when (and declared (not (member declared '("nsis" "inno") :test #'string=)))
      (die "--windows-format ~A is not a packaging this script knows (nsis, inno)" declared))
    (cond
      ((and declared detected (string/= declared detected))
       (die "--windows-format says ~A but ~A IS ~A -- refusing to publish a manifest that misdescribes its own payload"
            declared (file-namestring file) detected))
      (detected detected)
      (declared
       (format *error-output* "~&  note: ~A matches no known packaging; declaring ~A because you said so~%"
               (file-namestring file) declared)
       declared)
      (t (die "cannot tell what packaging ~A is, and will not guess -- add its marker to +FORMAT-MARKERS+ or pass --windows-format"
              (file-namestring file))))))

(defun artifact-for (dist platform product version)
  "The payload artifact for PLATFORM, or NIL when this release has none.

A missing platform is NORMAL and not an error: a platform can join the matrix a release later
than the others, and the client already treats an absent entry as `nothing for me'."
  (let ((pattern (third (assoc platform *platforms* :test #'string=))))
    (when pattern
      (probe-file (merge-pathnames (format nil pattern product version) dist)))))

(defun cmd-generate ()
  (let* ((dist (uiop:ensure-directory-pathname (require-arg "--dist")))
         (product (require-arg "--product"))
         (version (require-arg "--version"))
         (base-url (string-right-trim "/" (require-arg "--base-url")))
         (channel (arg "--channel" "stable"))
         (notes (arg "--notes-url"))
         (minimum (arg "--minimum-version"))
         (key (read-private-key))
         (platforms (make-hash-table :test #'equal)))
    (loop for (platform fallback-format) in *platforms*
          for file = (artifact-for dist platform product version)
          when file
            do (let ((payload (make-hash-table :test #'equal))
                     ;; Windows is the only platform with two packagings today, and the
                     ;; only one where guessing runs the wrong installer. The others carry
                     ;; the table's value until they have a second packaging to tell apart.
                     (format (if (string= platform "windows-x86-64")
                                 (windows-format file)
                                 fallback-format)))
                 (setf (gethash "url" payload)
                       (format nil "~A/~A" base-url (file-namestring file))
                       (gethash "size" payload) (with-open-file (s file :element-type '(unsigned-byte 8))
                                                  (file-length s))
                       (gethash "sha256" payload) (sha256-hex file)
                       ;; Each artifact is signed too, not only the manifest. The manifest
                       ;; says what the bytes should be; the artifact signature proves the
                       ;; bytes are ours even if they arrived from a mirror or a cache.
                       (gethash "sig" payload) (sign-file key file))
                 (let ((entry (make-hash-table :test #'equal)))
                   (setf (gethash "format" entry) format
                         (gethash "payload" entry) payload
                         (gethash "installer" entry) "same")
                   (setf (gethash platform platforms) entry))
                 (format *error-output* "~&  ~A: ~A (format: ~A)~%"
                         platform (file-namestring file) format)))
    (when (zerop (hash-table-count platforms))
      (die "no artifacts found under ~A for ~A ~A -- refusing to write an empty manifest"
           dist product version))
    (let ((m (make-hash-table :test #'equal)))
      (setf (gethash "schema" m) *schema*
            (gethash "product" m) product
            (gethash "channel" m) channel
            (gethash "version" m) version
            (gethash "published" m) (published-now)
            (gethash "platforms" m) platforms)
      (when notes (setf (gethash "notes_url" m) notes))
      (when minimum (setf (gethash "minimum_version" m) minimum))
      ;; SELF-CHECK, before anything is published. No two platforms may share a payload:
      ;; an earlier draft of ARTIFACT-FOR filed the Windows installer under all three and
      ;; produced a perfectly well-formed manifest that would have handed every Mac an .exe.
      ;; Nothing downstream checks that an artifact matches the platform it is filed under,
      ;; so it is checked here, where the mistake is still cheap.
      (let ((urls (loop for entry being the hash-values of platforms
                        collect (gethash "url" (gethash "payload" entry)))))
        (unless (= (length urls) (length (remove-duplicates urls :test (function string=))))
          (die "two platforms share a payload artifact -- refusing to publish:~{~%    ~A~}" urls)))
      ;; `<channel>.json', which is the name the CLIENT asks an HTTP source for -- design
      ;; section 2, channels are separate manifests rather than a field in one. This wrote
      ;; `latest.json' until pre-publication issue 77: one document with two names, in two files that cannot see
      ;; each other, which is this subsystem's recurring defect. It also meant two channels
      ;; generated into one dist overwrote each other, the name carrying no channel at all.
      (let ((path (merge-pathnames (format nil "~A.json" channel) dist)))
        (with-open-file (s path :direction :output :if-exists :supersede
                                :external-format :utf-8)
          (write-string (json:stringify m :pretty t) s)
          (terpri s))
        (sign-file key path)
        ;; And prove every signature verifies, using the public half of the key that just
        ;; signed them. CI publishing an artifact it has not itself checked is how an
        ;; unverifiable release reaches a customer.
        (let ((public (sig:public-key-of key)))
          (dolist (f (cons path
                           (loop for entry being the hash-values of platforms
                                 collect (merge-pathnames
                                          (file-namestring
                                           (gethash "url" (gethash "payload" entry)))
                                          dist))))
            (unless (verify-detached public f)
              (die "the signature just written for ~A does not verify -- refusing to publish"
                   (file-namestring f)))))
        (format t "~&wrote ~A and ~:*~A.sig (every signature verified)~%" (namestring path))))))

(defun published-now ()
  "RFC-3339 UTC, which is what the client parses."
  (multiple-value-bind (s m h day month year) (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" year month day h m s)))

;;; --- dispatch ---------------------------------------------------------------------

(let ((command (second sb-ext:*posix-argv*)))
  (cond
    ((equal command "keygen") (cmd-keygen))
    ((equal command "generate") (cmd-generate))
    ((equal command "sign") (cmd-sign))
    ((equal command "verify") (cmd-verify))
    (t (format t "~&usage: update-manifest keygen | generate | sign | verify~%")
       (sb-ext:quit :unix-status 2))))
