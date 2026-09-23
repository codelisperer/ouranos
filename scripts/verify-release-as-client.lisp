;;;; verify-release-as-client.lisp --- the gate a release passes before anything is uploaded.
;;;;
;;;;   sbcl --script scripts/verify-release-as-client.lisp \
;;;;        --dist DIR      --product NAME --version 1.2.3 --public-key BASE64 [--channel stable]
;;;;   sbcl --script scripts/verify-release-as-client.lisp \
;;;;        --base-url URL  --product NAME --version 1.2.3 --public-key BASE64 [--channel stable]
;;;;        [--source github|s3]
;;;;
;;;; Exit 0 only if `hyperion/update' -- the CLIENT, the actual code installed on the actual
;;;; machines -- can reach this release and get all the way to a staged, verified payload
;;;; for every platform in the manifest.
;;;;
;;;; TWO MODES, AND THEY ANSWER DIFFERENT QUESTIONS.
;;;;
;;;;   --dist      reads a DIRECTORY. Runs BEFORE the upload, on the exact bytes about to
;;;;               be sent, and is the gate that stops a bad release leaving the building.
;;;;   --base-url  reads a URL, over the network, WITH NO CREDENTIALS, exactly as an
;;;;               installed application does. Runs AFTER the upload.
;;;;
;;;; The second is not the first repeated for luck. `--dist' can show only that the
;;;; producer's directory is internally consistent; every question about PUBLISHING lives
;;;; past it, and it cannot see any of them. Was the asset attached at all? Under the name
;;;; the manifest gives? At a URL that resolves WITHOUT A TOKEN -- on a private repository
;;;; it does not, and this entire client was built against one. Does the channel URL still
;;;; point at this application's release, or at another application's? Each of those is
;;;; invisible to a check that reads the producer's own disk, and each of them strands an
;;;; installed app IN SILENCE, because a 404 is how the protocol spells "this channel has
;;;; published nothing yet".
;;;;
;;;; A PUBLISH VERIFIED BY THE THING THAT PUBLISHED IT CANNOT SEE A PRODUCER/CONSUMER
;;;; DISAGREEMENT -- which is the whole failure class of #332, and the same sentence this
;;;; file already carries one layer down about the generator's own reader.
;;;;
;;;; WHY THE PRODUCER CANNOT CHECK ITS OWN WORK. `update-manifest.lisp' already ends by
;;;; verifying every signature it wrote, and the release workflow already had a step called
;;;; "Verify as a client would". Both use `verify-detached' -- the generator's own reader, in
;;;; the generator's own file. They can confirm only that the PRODUCER IS SELF-CONSISTENT,
;;;; and it was self-consistent through every producer/consumer defect this subsystem has
;;;; had:
;;;;
;;;;   #206          the build script computed a platform key; the client recomputed it
;;;;   .sig encoding the generator wrote base64; the client read raw bytes
;;;;   format        the generator hard-coded "nsis"; the client dispatched on the field
;;;;   filename      the generator wrote latest.json; the client asks for <channel>.json
;;;;
;;;; One contract, named twice, in two files that cannot see each other -- four times, in one
;;;; subsystem. That is a statement about the contract, not about four mistakes. A self-check
;;;; that looks conscientious is WORSE than none, because it occupies the slot where the real
;;;; check would go and nobody asks again. The step that could not have caught the `.sig'
;;;; defect was the step named for catching exactly that.
;;;;
;;;; SO THIS SCRIPT USES THE CLIENT'S OWN CODE, internals included, and that is deliberate
;;;; rather than lazy. Reimplementing the checks here would produce a THIRD reader, and a
;;;; third reader is a third thing that can agree with neither of the other two.
;;;;
;;;; `available' IS NOT ENOUGH, and stopping there would have been this file making the same
;;;; mistake it exists to prevent. `check-for-update' proves the manifest parses, its
;;;; signature verifies and the version compares greater -- and every one of those was TRUE
;;;; while the `.sig' encoding defect made the payload undownloadable. The defect lives
;;;; entirely PAST the point where `available' is decided. So the gate stages: it fetches
;;;; each payload, verifies the detached signature over the bytes on disk, and writes it out,
;;;; through `stage-payload', which is the client's own function.
;;;;
;;;; EVERY PLATFORM, NOT ONLY THIS HOST'S. `stage-payload' takes a platform ENTRY, so a
;;;; Windows runner can verify the macOS and Linux payloads too -- and must, because the
;;;; alternative is a matrix where each platform is checked only by a runner that might not
;;;; exist yet.
;;;;
;;;; ORDER MATTERS, AND IT IS THE CALLER'S JOB TO GET RIGHT (design section 10).
;;;; Authenticode signing MUTATES the artifact. If a release is verified and THEN signed, the
;;;; bytes that passed the gate are not the bytes anyone will download, and this script will
;;;; have passed on a file that no longer exists. Run it LAST, on the exact directory about
;;;; to be uploaded. It writes `VERIFIED.sha256' naming every file it actually read, so the
;;;; upload step can assert it is sending those bytes rather than assuming a step order.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (read-from-string "ql:quickload") '(:hyperion/update :ironclad) :silent t)

(defpackage #:verify-release-as-client
  (:use #:common-lisp)
  (:local-nicknames (#:up #:hyperion/update)
                    (#:platform #:aion/platform)))
(in-package #:verify-release-as-client)

(defvar *failures* '())

(defun arg (name &optional default)
  (let ((tail (member name (rest sb-ext:*posix-argv*) :test #'string=)))
    (or (second tail) default)))

(defun require-arg (name)
  (or (arg name)
      (progn (format *error-output* "~&verify-release: ~A is required~%" name)
             (finish-output *error-output*)
             (sb-ext:quit :unix-status 2))))

(defun usage (control &rest args)
  (format *error-output* "~&verify-release: ~?~%" control args)
  (finish-output *error-output*)
  (sb-ext:quit :unix-status 2))

(defun fail (fmt &rest args)
  (let ((text (apply #'format nil fmt args)))
    (push text *failures*)
    (format t "~&FAIL  ~A~%" text)
    (finish-output)))

(defun good (fmt &rest args)
  (format t "~&  ok  ~?~%" fmt args)
  (finish-output))

(defun file-bytes (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence bytes in)
      bytes)))

(defun sha256-hex (bytes)
  (ironclad:byte-array-to-hex-string (ironclad:digest-sequence :sha256 bytes)))

;;; --- the run ----------------------------------------------------------------

(let* ((dist-arg (arg "--dist"))
       (base-url (arg "--base-url"))
       (dist (and dist-arg (uiop:ensure-directory-pathname dist-arg)))
       (product (require-arg "--product"))
       (version (require-arg "--version"))
       (channel (arg "--channel" "stable"))
       (public (require-arg "--public-key"))
       (source
         (cond
           ((and dist base-url)
            (usage "--dist and --base-url name two different releases -- pass one"))
           (base-url
            ;; The class an application would really instantiate, not `http-source'
            ;; itself. They behave identically, and naming the real one keeps this
            ;; check honest about what it is standing in for.
            (make-instance (if (string= "s3" (arg "--source" "github"))
                               'up:s3-source
                               'up:github-release-source)
                           :base-url base-url))
           (dist (make-instance 'up:directory-source :path dist))
           (t (usage "one of --dist or --base-url is required"))))
       (checked '()))

  ;; A previous run's verdict must not outlive it. Deleted before the first check, so a
  ;; failure or a crash cannot leave a passing release's fingerprints behind.
  (when dist
    (ignore-errors (delete-file (merge-pathnames "VERIFIED.sha256" dist))))

  (format t "~&verifying ~A ~A (channel ~A)~%" product version channel)
  ;; PROVENANCE, not decoration. The two modes produce near-identical output and answer
  ;; different questions, so which one a log came from has to be IN the log.
  (if dist
      (format t "source: the directory ~A, BEFORE the upload~%" dist)
      (format t "source: ~A -- over the network, unauthenticated, AFTER the upload~%"
              base-url))
  (format t "as the CLIENT reads it -- hyperion/update, not the generator's own reader~%~%")

  (setf up:*public-key* public
        ;; Strictly older than anything publishable, so the anti-rollback comparison can
        ;; only refuse for a reason that is about the manifest.
        up:*installed-version* "0.0.0"
        up:*installed-published* nil
        up:*update-source* source)

  ;; 1. THE DECISION. Proves the manifest is where the client looks for it, parses, carries
  ;;    a schema this client can read, and is signed over its exact bytes by this key.
  (let ((status (up:check-for-update :source source :channel channel :product product)))
    (cond
      ((string= "available" (getf status :status))
       (good "the client offers an update: ~A" (getf status :version))
       (unless (equal version (getf status :version))
         (fail "the client offers ~A but this release is ~A" (getf status :version) version)))
      (t
       (fail "the client did not offer this release -- it reported ~S~@[ (~A)~]~@[: ~A~]"
             (getf status :status)
             (let ((b (getf status :block))) (and (plusp (length b)) b))
             (let ((d (getf status :detail))) (and (plusp (length d)) d)))
       ;; Nothing below can mean anything if the manifest itself did not come back.
       (format t "~&~%VERDICT: FAIL (~D)~%" (length *failures*))
       (sb-ext:quit :unix-status 1))))

  ;; 2. THE PAYLOADS, one per platform, through the client's own staging path: fetch the
  ;;    artifact, fetch its detached `.sig', verify the signature over those exact bytes,
  ;;    write it out. This is where the `.sig' encoding defect lived, one whole step past
  ;;    the `available' above.
  (multiple-value-bind (bytes signature) (up:fetch-manifest source channel)
    (unless (up::%verified-p bytes signature)
      (fail "the manifest no longer verifies on the second read")
      (format t "~&~%VERDICT: FAIL (~D)~%" (length *failures*))
      (sb-ext:quit :unix-status 1))
    (push (cons (format nil "~A.json" channel) (sha256-hex bytes)) checked)
    ;; AND ITS DETACHED SIGNATURE. It is a file the upload step sends, so design section
    ;; 10 covers it: the list exists so the uploader can assert it is sending the bytes
    ;; that passed rather than assume a step order. Omitting it left the one file whose
    ;; whole job is to authenticate the others as the one file nothing downstream pinned.
    (push (cons (format nil "~A.json.sig" channel) (sha256-hex signature)) checked)
    (let* ((manifest (up::%parse-manifest bytes))
           (platforms (up:manifest-platforms manifest)))
      (when (zerop (hash-table-count platforms))
        (fail "the manifest carries no platforms at all"))
      (loop for key being the hash-keys of platforms
            for entry = (up:manifest-platform manifest key)
            do (format t "~&~A~%" key)
               ;; The strategy the client would choose. An unrecognised format is a refusal
               ;; at the user, on a machine, after a download -- so it is a refusal here.
               (let ((declared (up:platform-format entry)))
                 (if (up::%format-keyword declared)
                     (good "format ~S is a strategy this client has" declared)
                     (fail "~A declares format ~S, which this client would refuse" key declared)))
               (handler-case
                   (let* ((staged (up:stage-payload source entry))
                          ;; Removed before this script exits (#257). The client cannot do
                          ;; it -- it hands off to an installer and exits -- but a gate
                          ;; that runs once per release and stages every platform would
                          ;; otherwise leave a full set of installers behind on every run,
                          ;; on a CI runner or a developer's machine alike.
                          (staged-dir (uiop:pathname-directory-pathname (pathname staged)))
                          (staged-bytes (file-bytes staged))
                          (url (up:platform-payload-url entry))
                          (name (subseq url (1+ (position #\/ url :from-end t)))))
                     (good "staged and signature-verified: ~A (~:D bytes)"
                           name (length staged-bytes))
                     (push (cons name (sha256-hex staged-bytes)) checked)
                     (push (cons (format nil "~A.sig" name)
                                 (sha256-hex (up:fetch-artifact
                                              source (concatenate 'string url ".sig"))))
                           checked)
                     ;; The manifest's own sha256, checked here because the CLIENT never
                     ;; looks at it -- the detached signature is what it trusts. A field no
                     ;; consumer reads is how a field quietly stops being true.
                     (let ((declared (gethash "sha256" (gethash "payload" entry)))
                           (actual (sha256-hex staged-bytes)))
                       (cond ((null declared) (fail "~A carries no sha256" key))
                             ((string-equal declared actual)
                              (good "sha256 matches the bytes the client staged"))
                             (t (fail "~A: manifest sha256 ~A, staged bytes ~A"
                                      key declared actual))))
                     (ignore-errors (uiop:delete-directory-tree staged-dir :validate t)))
                 (error (e)
                   (fail "~A: the client could not stage its payload -- ~A" key e))))))

  ;; 3. THE WHOLE APPLY, for this host, where the host can run one. Adds the writability
  ;;    gate and the strategy dispatch to everything above. The launcher is stubbed: the
  ;;    point is to reach it, not to install anything.
  #+win32
  (let ((dir (merge-pathnames (format nil "ouranos-release-gate-~D/" (get-universal-time))
                              (uiop:temporary-directory)))
        (launched nil))
    (ensure-directories-exist dir)
    (unwind-protect
         (let ((up:*install-directory* (namestring dir))
               (up:*app-name* product)
               (up:*launch-installer* (lambda (strategy installer install-dir)
                                        (declare (ignore installer install-dir))
                                        (setf launched strategy)))
               (up:*exit-after-handoff* (lambda () nil)))
           (handler-case
               (let ((state (up:apply-update :source source :channel channel :product product)))
                 (if (and (string= "applying" (getf state :status)) launched)
                     (good "the full apply path reaches the ~A strategy" launched)
                     (fail "the apply path ended at ~S without launching" (getf state :status))))
             (error (e) (fail "the apply path signalled: ~A" e))))
      (ignore-errors (uiop:delete-directory-tree dir :validate t))))
  #-win32
  (format t "~&  --  the whole-apply check is Windows-only: apply-update refuses on ~A until #74 produces an artifact for it~%"
          (platform:platform-key))

  ;; 4. WHAT WAS ACTUALLY READ. Design section 10: Authenticode MUTATES the artifact, so a
  ;;    release verified before signing is a release verified in a file nobody will download.
  ;;    This names the exact bytes that passed, so the upload step can assert rather than
  ;;    assume that it is sending them.
  ;;    WRITTEN ONLY ON A PASS, and any earlier one is removed before the checks run. A
  ;;    file named for verified bytes, left behind by a run that FAILED, is precisely the
  ;;    artifact a later step would trust -- and a stale one from yesterday's passing run
  ;;    is worse still, because it would name bytes that are no longer there.
  ;; `--dist' MODE ONLY. Over the network there is no upload step after this to hand a
  ;; list of bytes to, and writing the file anyway would invite a later reader to treat a
  ;; post-publish run as the pre-publish gate -- the two are not interchangeable.
  (let ((path (and dist (merge-pathnames "VERIFIED.sha256" dist))))
    (cond
      ((null path)
       (format t "~&~%no VERIFIED.sha256: nothing is about to be uploaded from here~%"))
      (*failures*
       (format t "~&~%not writing ~A: this release did not pass~%" (file-namestring path)))
      (t
       (with-open-file (s path :direction :output :if-exists :supersede
                               :external-format :utf-8)
         (dolist (pair (sort (copy-list checked) #'string< :key #'car))
           (format s "~A  ~A~%" (cdr pair) (car pair))))
       (format t "~&~%wrote ~A -- the upload step must send exactly these bytes~%"
               (namestring path)))))

  (format t "~&~%VERDICT: ~:[PASS~;FAIL~] (~D failure~:P)~%" *failures* (length *failures*))
  (sb-ext:quit :unix-status (if *failures* 1 0)))
