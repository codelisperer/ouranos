;;;; client.lisp --- the effectful half: fetch, verify, decide (pre-publication issue 76).
;;;;
;;;; THE ORDER OF OPERATIONS IN `check-for-update' IS THE SECURITY DESIGN, and it is the
;;;; one thing in this file a refactor must not tidy:
;;;;
;;;;     fetch bytes -> VERIFY the bytes -> decode -> parse -> interpret -> decide
;;;;
;;;; Nothing the document says about itself is read until its signature over its exact
;;;; bytes has been checked. Not the schema, not the product, not the version. If the
;;;; schema gate ran first, anyone able to serve us bytes could trip the refusal path with
;;;; unsigned garbage and stop the client updating -- a denial-of-update, which against a
;;;; security fix is the whole attack and costs the attacker nothing.
;;;;
;;;; It is also what makes the fail-opens in the typed core safe. An absent `published'
;;;; does not block, and that is only defensible because a stripped field breaks the
;;;; signature: absence can therefore only come from a legitimately signed manifest that
;;;; genuinely lacks it. Move verification after parsing and that fail-open silently
;;;; becomes attacker-selectable.

(in-package #:hyperion/update)

;;; --- what the application must tell us -------------------------------------

(defvar *installed-version* nil
  "This build's version, as a semver string. THE CONSUMING APPLICATION SETS THIS.

The app/framework seam. A framework cannot know how a build learns its own version -- a
dumped constant, a build-time file, an ASDF system version -- so it is a special the app
sets. NIL means \"I do not know what I am\", which is reported as a block and never
resolved to \"I am current\": an updater that treats unknown as current never offers the
fix that matters.")

(defvar *installed-published* nil
  "When this build was published, in the one accepted spelling: YYYY-MM-DDTHH:MM:SSZ.

The second half of anti-rollback (design section 2) needs both instants. NIL is tolerated
-- a build predating this field must still be able to update -- and the comparison is
simply skipped, which is safe only because of the verify-before-interpret ordering above.")

(defvar *download-url* nil
  "The PERMANENT human download link for this product, or NIL.

Design section 5 requires this to be distinct from the update channel, and each release
overwrites the artifact behind it so the URL itself never changes. It is not the same
thing as a manifest's per-release `installer' URL, and the difference is the whole point:
this one is readable when the manifest is NOT.

WHY THAT MATTERS, AND WHY IT WAS A BUG. The unsupported-schema refusal used to take its
download link out of the manifest -- from `platforms.<key>.installer.url' -- in the very
branch that had just declared it could not read that manifest's schema. A build cannot
coherently say \"I do not understand this document\" and then read a field out of it: in a
schema this build does not know, `installer' may not be a URL, may not be at that path, or
may not mean what this build assumes. The link a user is told to download from must come
from configuration this build was shipped with, not from the document it just refused.

Set by the application; there is no default, for the same reason no source has one.")

(defvar *public-key* nil
  "The Ed25519 public key that signs this product's releases, as text, or NIL.

Ships INSIDE the bundle and is exactly as trusted as the installer that placed it. NIL
disables updating entirely rather than disabling verification -- see `%trusted-key'.")

;;; --- update sources: a protocol, so the back end is a deployment choice -----

(defgeneric fetch-manifest (source channel)
  (:documentation
   "Return (VALUES MANIFEST-BYTES SIGNATURE-BYTES) for CHANNEL from SOURCE.

Return (VALUES NIL NIL) when there is simply nothing -- no channel, no release yet. Signal
`update-source-error' when the source exists but could not be reached; the caller turns
that into a quiet state rather than letting it escape.

RETURNS BYTES, NOT A PARSED MANIFEST, and that is a deliberate departure from the design
document's sketch of this protocol (section 5 says \"parsed manifest + its signature\").
Parsing here would put the parse BEFORE the verification, which is exactly the ordering
this module exists to prevent -- and a protocol whose signature invites the wrong order
will eventually get it. The signature is over the exact bytes of the file, so the bytes
are what the client must hold, verify, and only then interpret. Recorded rather than
silently deviated from.

Generic because where updates live is an operational decision, not an application one.
The client must not know whether it is talking to GitHub Releases or a bucket."))

(defgeneric fetch-artifact (source url)
  (:documentation
   "Return the bytes of the artifact at URL, as an octet vector.

Bytes for the same reason as `fetch-manifest': the payload signature is over exactly what
was served, and an installer decoded as text is not an installer."))

(define-condition update-source-error (error)
  ((detail :initarg :detail :reader update-source-error-detail))
  (:report (lambda (c s)
             (format s "the update source could not be reached: ~A"
                     (update-source-error-detail c)))))

;;; The default. Not a stub that pretends -- "there is no release channel" is the TRUE
;;; answer for a build running from a REPL or a working tree, and answering it honestly is
;;; what keeps the no-update path exercised every day, so the banner's absence is a tested
;;; state rather than an assumption.
(defclass null-source () ()
  (:documentation "The source a development build uses: there is no release channel yet."))

(defmethod fetch-manifest ((source null-source) channel)
  (declare (ignore channel))
  (values nil nil))

(defmethod fetch-artifact ((source null-source) url)
  (declare (ignore url))
  (error 'update-source-error :detail "this build has no release channel"))

(defclass http-source ()
  ((base-url :initarg :base-url :reader source-base-url))
  (:documentation
   "Common behaviour for a source that is an HTTPS prefix. NOT instantiated directly.

There is deliberately NO DEFAULT BASE URL anywhere in this file. A placeholder baked into
framework source is how an application ends up checking a domain nobody owns -- and worse,
a domain someone else may come to own. The release build supplies it."))

(defclass github-release-source (http-source) ()
  (:documentation
   "GitHub Releases. Zero infrastructure, and PUBLIC REPOSITORIES ONLY -- a private repo
serves release assets only to an authenticated request, and an installed application cannot
hold a token safely. A product whose source is private publishes its assets to a separate
public repository (pre-publication issue 332); this is not a limitation to work around, it is the reason that
repository exists.

THE BASE URL IS A RELEASE, AND WHICH ONE MATTERS.

  .../releases/latest/download/       the obvious choice, and WRONG as soon as the
                                      repository holds more than one thing that releases.
                                      `latest' resolves per REPOSITORY, so a second
                                      application -- or, in a monorepo, a framework tag --
                                      becomes `latest' and every other product's manifest
                                      is simply not in it. The client asks, gets a 404, and
                                      reads that CORRECTLY as \"this channel has published
                                      nothing yet\". It then goes quiet. Nothing errors,
                                      nothing logs, and updates stop.

  .../releases/download/<app>-<chan>/ a per-application, per-channel release whose assets
                                      are replaced on each publish. Permanent, and nothing
                                      else can take it over.

The second is what `desktop-release.yml' publishes. Mutability costs nothing here: the
manifest is signed and verified over its exact bytes before it is parsed, so replacing an
asset is the only way to move a channel and forging one still needs the key."))

(defclass s3-source (http-source) ()
  (:documentation
   "An S3 bucket prefix. Suits a private product, and gives a permanent human download
link alongside the versioned manifest. Costs pennies."))

(defun %join-url (base name)
  (concatenate 'string base (if (and (plusp (length base))
                                     (char= #\/ (char base (1- (length base)))))
                                "" "/")
               name))

(defmethod fetch-manifest ((source http-source) channel)
  (let ((manifest-url (%join-url (source-base-url source)
                                 (concatenate 'string channel ".json"))))
    (values (%fetch-bytes manifest-url)
            ;; Detached, alongside the document, exactly as the generator writes it.
            (%fetch-bytes (concatenate 'string manifest-url ".sig")))))

(defmethod fetch-artifact ((source http-source) url)
  (declare (ignore source))
  (%fetch-bytes url))

;;; A DIRECTORY, and not only a test fixture. A mirrored `dist/' on a network share is a
;;; real deployment; so is a managed fleet's staging area. But the reason this exists is
;;; narrower and sharper: it is the directory a release is about to be uploaded FROM.
;;;
;;; `scripts/verify-release-as-client.lisp' points the CLIENT at that directory and requires
;;; it to fetch, verify and stage before anything is published. That is the only check that
;;; can see a producer/consumer disagreement. `update-manifest.lisp' already ends by
;;; verifying every signature it wrote -- with its OWN reader, in its own file -- which can
;;; confirm only that the producer is self-consistent. It was self-consistent through all
;;; three of the defects this backend was added to catch: the platform key (pre-publication issue 206), the
;;; `.sig' encoding, and the packaging field. A self-check that looks conscientious is worse
;;; than none, because it occupies the slot where the real check would go.

(defun %file-bytes (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence bytes in)
      bytes)))

(defclass directory-source ()
  ((path :initarg :path :reader source-path))
  (:documentation
   "A published `dist/' directory on disk, read exactly as the HTTP backend reads a host.

THE FILE NAMES ARE THE CONTRACT, not an implementation detail of this class. A channel is
`<channel>.json' beside its `<channel>.json.sig' (design section 2: channels are separate
manifests, not a field), and an artifact is the last segment of the URL the manifest gives.
Getting either wrong here would make this backend agree with a producer the HTTP backend
would disagree with -- which is the failure it exists to detect, reproduced inside the
detector."))

(defmethod fetch-manifest ((source directory-source) channel)
  (let* ((name (concatenate 'string channel ".json"))
         (doc (merge-pathnames name (source-path source)))
         (sig (merge-pathnames (concatenate 'string name ".sig") (source-path source))))
    (if (and (probe-file doc) (probe-file sig))
        (values (%file-bytes doc) (%file-bytes sig))
        ;; A channel that has not published yet is an ANSWER and not a failure -- the same
        ;; thing the HTTP backend does with a 404.
        (values nil nil))))

(defmethod fetch-artifact ((source directory-source) url)
  "The file URL names, sitting in this directory.

The manifest carries ABSOLUTE urls, because it is written for the host it will be served
from -- and it is signed, so it cannot be rewritten for a local check. Only the last
segment can mean anything here, and that is deliberate: the file about to be uploaded is
looked up under exactly the name the URL will serve it as."
  (let* ((slash (position #\/ url :from-end t))
         (name (if slash (subseq url (1+ slash)) url))
         (file (merge-pathnames name (source-path source))))
    (unless (probe-file file)
      (error 'update-source-error
             :detail (format nil "no artifact named ~A in ~A" name (source-path source))))
    (%file-bytes file)))

;;; A LIST OF SOURCES IS TRIED IN ORDER (design section 5), which is a useful fallback when
;;; one host is down. The first that answers wins; a source that is merely EMPTY -- no
;;; channel yet -- is an answer, not a failure, so it stops the search.
(defmethod fetch-manifest ((sources cons) channel)
  (let ((last-error nil))
    (dolist (source sources
             (if last-error (error last-error) (values nil nil)))
      (handler-case
          (return (fetch-manifest source channel))
        (update-source-error (e) (setf last-error e))))))

(defvar *update-source* (make-instance 'null-source)
  "Where this build looks for updates: one source, or a list tried in order.

A release build replaces this in its build script, not in source, because a channel URL is
deployment configuration.")

;;; --- the one effect --------------------------------------------------------

;;; --- the one effect --------------------------------------------------------
;;;
;;; THERE IS NO LOCAL TRANSPORT ANY MORE, and its removal is the point. This file used to
;;; carry `%binary-perform', a substituted PERFORM that called dexador directly, because
;;; `aion/http-client' decoded every body to a string and kept nothing else -- fatal here
;;; twice over: the manifest signature is over the exact bytes of a file, so a decode and
;;; re-encode invalidates it, and an NSIS installer decoded as UTF-8 is not an installer.
;;; Its own docstring said it was a stopgap and that pre-publication issue 223 belonged to the lane that owns
;;; that client.
;;;
;;; pre-publication issue 223 landed (0c65c72). The shared client now carries the octets that arrived and derives
;;; the string from them, and -- arrived at independently, on the same reasoning -- captures
;;; a non-2xx as a RESPONSE instead of letting dexador signal it. Both halves of the local
;;; workaround are now the shared client's documented behaviour, so keeping it would leave
;;; ONE CONTRACT NAMED TWICE IN TWO FILES THAT CANNOT SEE EACH OTHER, which is the defect
;;; this subsystem has produced four times already. It is deleted rather than kept in step.

(defun %fetch-bytes (url)
  "GET URL and return its body as an octet vector, or NIL on a 404.

A 404 IS NOT AN ERROR HERE. A channel that has not published yet, or a platform that has
not joined the release matrix, both look like this -- and both are ordinary states rather
than failures. Any other non-2xx is a source that is behaving unexpectedly and signals."
  (let ((response (handler-case
                      (http:send-request (http:make-request :method :get :url url) '())
                    ;; Nobody answered at all -- DNS, connection refused, TLS. A status is
                    ;; not an error here; the absence of one is.
                    (http:http-error (e)
                      (error 'update-source-error :detail (princ-to-string e))))))
    (let ((status (http:response-status response)))
      (cond ((= status 404) nil)
            ;; RESPONSE-BYTES, NEVER RESPONSE-BODY. Both are total and the difference is
            ;; invisible until it is catastrophic: BODY is those same bytes decoded as
            ;; UTF-8, which is exactly the re-encoding that invalidates a detached
            ;; signature, and an installer decoded as text is mangled. This line read
            ;; RESPONSE-BODY when the two meant the same thing, and pre-publication issue 223 made them differ.
            ((<= 200 status 299) (http:response-bytes response))
            (t (error 'update-source-error
                      :detail (format nil "~A returned HTTP ~D" url status)))))))

;;; --- verification, which happens before anything is interpreted ------------

(defun %trusted-key ()
  "The public key, decoded, or a signalled refusal.

NO KEY MEANS NO UPDATES, never unverified updates. A build shipped without its key is a
deployment mistake, and the safe reading of a deployment mistake is that nothing may be
installed -- not that everything may be."
  (unless *public-key*
    (error 'update-source-error
           :detail "this build carries no update signing key, so nothing can be verified"))
  (sig:decode-public-key *public-key*))

(defun %signature-bytes (raw)
  "The 64 signature bytes carried by a detached `.sig' artifact, or NIL.

A `.sig' FILE IS BASE64 TEXT, NOT RAW BYTES. `scripts/update-manifest.lisp' writes it with
`cl-base64' plus a trailing newline and reads it back the same way; `aion/signature' encodes
keys the same way for the same reason. This is the client half of that contract, and until
this function existed the two halves disagreed: the fetched bytes went straight to
`sig:verify', which requires exactly 64 of them, so an 89-byte base64 line failed every
single time.

MEASURED, both directions, against a signature this tree's own generator wrote:

  the .sig file as written        89 bytes  ->  verified: NIL
  the same signature, decoded     64 bytes  ->  verified: T

NEITHER SUITE COULD SEE IT. The client's tests serve signatures from memory as raw bytes and
never read a file the generator produced, so the failing question was unaskable -- AGENTS.md,
a suite that always satisfies a precondition cannot test the absence of that precondition. It
is pre-publication issue 206's shape, a producer and a consumer naming one contract twice and apart, with pre-publication issue 206's
consequence: every installed client refuses every real release, silently and forever. A
refused update against a security fix IS the attack.

NIL FOR ANYTHING THAT IS NOT BASE64, which becomes a verification failure rather than a
signalled error. A `.sig' we cannot decode is indistinguishable from one that does not
verify, and both mean exactly: do not install this."
  (when raw
    (ignore-errors
      (let ((text (string-trim '(#\Space #\Tab #\Return #\Newline)
                               (sb-ext:octets-to-string
                                (coerce raw '(vector (unsigned-byte 8)))
                                ;; latin-1 cannot fail on arbitrary bytes. A UTF-8 decode
                                ;; can, and a decode error here would surface as something
                                ;; other than "this does not verify".
                                :external-format :latin-1))))
        (and (plusp (length text))
             (base64:base64-string-to-usb8-array text))))))

(defun %verified-p (bytes signature)
  "True when SIGNATURE is a valid detached signature over exactly BYTES."
  (let ((decoded (%signature-bytes signature)))
    (and bytes decoded (sig:verify (%trusted-key) bytes decoded))))

;;; --- the manifest ----------------------------------------------------------

(defparameter +schema+ 1
  "The manifest schema this build can read. Refuses anything higher -- see
`%read-manifest'. Additive optional fields MUST NOT bump this, and unknown keys are
ignored rather than rejected, because a bump forces a manual reinstall on every older
client in the field. Bump only when an old client reading the document would do something
WRONG, not merely something incomplete.")

(defstruct (manifest (:copier nil))
  "One channel's release manifest, AFTER its signature has been verified.

Only fields something reads are here. `published' is absent from the promoted client's
struct and present here because it is half of anti-rollback; `product' and `channel' are
here because a correctly signed manifest from elsewhere in the same trust domain is a
substitution worth refusing."
  (schema 1 :type integer)
  (product "" :type string)
  (channel "" :type string)
  (version "" :type string)
  (published "" :type string)
  (notes-url nil :type (or null string))
  (minimum-version nil :type (or null string))
  (platforms (make-hash-table :test #'equal) :type hash-table))

(defun %string-field (table key &optional default)
  (let ((v (gethash key table)))
    (if (stringp v) v default)))

(defun %parse-manifest (bytes)
  "Decode and parse verified BYTES into a MANIFEST.

Called ONLY after `%verified-p' has succeeded. Signals `update-source-error' on anything
unreadable; the caller turns that into `Malformed-Manifest', which is deliberately
distinct from a signature failure because it is a release-process bug rather than an attack."
  (handler-case
      (let ((table (json:parse (sb-ext:octets-to-string bytes :external-format :utf-8))))
        (unless (hash-table-p table)
          (error 'update-source-error :detail "the manifest is not a JSON object"))
        (let ((platforms (gethash "platforms" table)))
          (make-manifest
           :schema (let ((s (gethash "schema" table))) (if (integerp s) s 0))
           :product (%string-field table "product" "")
           :channel (%string-field table "channel" "")
           :version (%string-field table "version" "")
           :published (%string-field table "published" "")
           :notes-url (%string-field table "notes_url")
           :minimum-version (%string-field table "minimum_version")
           :platforms (if (hash-table-p platforms) platforms (make-hash-table :test #'equal)))))
    (update-source-error (e) (error e))
    (error (e)
      (error 'update-source-error :detail (format nil "unreadable manifest: ~A" e)))))

(defun manifest-platform (manifest &optional (key (platform:platform-key)))
  "This machine's entry in MANIFEST, or NIL when the release does not cover it.

NIL is ORDINARY. A platform can join the release matrix a release late, and the caller
reports that as its own state rather than as being up to date -- which is the silent shape
pre-publication issue 206 produced."
  (let ((entry (gethash key (manifest-platforms manifest))))
    (when (hash-table-p entry) entry)))

(defun platform-payload-url (entry)
  "The URL the UPDATER fetches for this platform."
  (let ((payload (gethash "payload" entry)))
    (when (hash-table-p payload) (%string-field payload "url"))))

(defun platform-installer-url (entry)
  "The URL a HUMAN downloads for a first install.

\"same\" means the payload doubles as the installer -- true on Windows and Linux, where the
NSIS installer and the AppImage each serve both roles. Only macOS genuinely differs."
  (let ((installer (gethash "installer" entry)))
    (cond ((equal installer "same") (platform-payload-url entry))
          ((hash-table-p installer) (%string-field installer "url"))
          (t nil))))

(defun platform-format (entry)
  "Which apply strategy this platform's payload needs -- `nsis', `appimage', `app-targz'.

Explicit in the manifest rather than inferred from the OS, so a product can change
packaging without shipping a new client first."
  (%string-field entry "format"))

;;; --- the check -------------------------------------------------------------

(defvar *update-state* nil
  "The last result of `check-for-update', or NIL before the first check.
Read it through `update-status'.")

(defun %blocked (reason-name detail)
  "A block the typed core cannot produce, because it arises before any comparison exists.

Rendered as the same four keys `%render' produces, so a caller has one shape to handle
rather than two."
  (list :status "blocked" :version "" :block reason-name :detail detail))

(defun %render (state)
  "A Coalton `Update-State' as a plist of strings -- what a route or a UI reads."
  (list :status (state:state-name state)
        :version (state:state-version-text state)
        :block (state:state-block-name state)
        :detail (state:state-block-detail state)))

(defun update-status ()
  "The current update state as a plist: (:status :version :block :detail).

Before any check it reports `unchecked' rather than inventing an answer -- notably not
`up-to-date', which would be a claim nothing has established."
  (or *update-state* (list :status "unchecked" :version "" :block "" :detail "")))

(defun check-for-update (&key (source *update-source*) (channel "stable") (product nil))
  "Ask SOURCE whether a newer build exists. Updates and returns `update-status'.

NEVER SIGNALS. A failed update check is background noise -- the network is down, the user
is on a plane -- and an application that interrupts someone's work to report that it could
not reach a server has misjudged whose problem that is.

PRODUCT, when given, is the name this build expects the manifest to carry. A correctly
signed manifest for a DIFFERENT product, or for a channel that was not asked for, is a
substitution: signed does not mean addressed to us."
  (setf *update-state*
        (handler-case (%check source channel product)
          (update-source-error (e)
            (list :status "unreachable" :version "" :block ""
                  :detail (princ-to-string (update-source-error-detail e))))
          ;; The catch-all reports the quiet state too. An updater must not be able to take
          ;; an application down by failing, whatever the failure was.
          (error (e)
            (list :status "unreachable" :version "" :block "" :detail (princ-to-string e)))))
  *update-state*)

(defun %check (source channel product)
  "The check proper. The order is the security design -- see this file's header."
  (multiple-value-bind (bytes signature) (fetch-manifest source channel)
    (cond
      ;; No channel, or nothing published yet. The honest answer, and the one a
      ;; working-tree build gets every day.
      ((null bytes)
       (%render (state:decide-from-text (or *installed-version* "") "" t "" "" "" "")))
      ;; FAIL CLOSED on an unsigned manifest: it is exactly what an attacker able to serve
      ;; us bytes would produce, so it is refused rather than merely noted.
      ((null signature)
       (%blocked "bad-signature" "the update manifest was not signed"))
      ((not (%verified-p bytes signature))
       (%blocked "bad-signature"
                 "the update manifest's signature did not verify against this build's key"))
      (t
       ;; VERIFIED. Only now may anything the document says about itself be read.
       (%interpret (%parse-manifest bytes) channel product)))))

(defun %interpret (manifest channel product)
  "Interpret a VERIFIED manifest and decide. Every refusal here is about content."
  (cond
    ;; The schema gate, AFTER verification. A build that cannot read the current channel
    ;; refuses every check forever until a human acts, so it reports calmly and carries the
    ;; permanent download link rather than becoming a red banner people learn to ignore.
    ((> (manifest-schema manifest) +schema+)
     ;; THE LINK COMES FROM CONFIGURATION, NOT FROM THE MANIFEST. Reading a field out of a
     ;; document whose schema this build has just declared unreadable is incoherent -- see
     ;; `*download-url*'. Nothing below this line touches the manifest except its schema
     ;; number, which is the one field the gate is entitled to have read.
     (list :status "blocked" :version "" :block "unsupported-schema"
           :detail (format nil "this build cannot read release manifest schema ~D~@[; download the latest version directly from ~A~]"
                           (manifest-schema manifest) *download-url*)))
    ((< (manifest-schema manifest) 1)
     (%blocked "malformed-manifest" "the manifest declares no usable schema"))
    ;; Signed, but not addressed to us.
    ((and product (string/= product (manifest-product manifest)))
     (%blocked "manifest-mismatch"
               (format nil "the manifest is for ~S, but this build is ~S"
                       (manifest-product manifest) product)))
    ((and (plusp (length (manifest-channel manifest)))
          (string/= channel (manifest-channel manifest)))
     (%blocked "manifest-mismatch"
               (format nil "asked for the ~S channel and got ~S"
                       channel (manifest-channel manifest))))
    ;; A version that is not one. Distinct from an ABSENT version: absent means nothing on
    ;; offer, malformed means the release process produced something unusable.
    ((not (version:valid-version? (manifest-version manifest)))
     (%blocked "malformed-manifest"
               (format nil "the manifest names no valid version: ~S"
                       (manifest-version manifest))))
    ;; A MALFORMED TIMESTAMP MUST NOT INHERIT THE FAIL-OPEN THAT ABSENCE GETS. An empty
    ;; `published' is tolerated by design; a present-but-unreadable one is a defect, and
    ;; passing it through as absence would let mangling the field do what stripping it
    ;; cannot.
    ((and (plusp (length (manifest-published manifest)))
          (not (state:valid-published? (manifest-published manifest))))
     (%blocked "malformed-manifest"
               (format nil "the manifest's published timestamp is not YYYY-MM-DDTHH:MM:SSZ: ~S"
                       (manifest-published manifest))))
    (t
     (let ((entry (manifest-platform manifest)))
       (%render
        (state:decide-from-text
         (or *installed-version* "")
         (manifest-version manifest)
         ;; An entry with no payload URL is not an artifact, whatever else it carries.
         (if (and entry (platform-payload-url entry)) t nil)
         (or (manifest-minimum-version manifest) "")
         (or (and entry (platform-installer-url entry)) "")
         (manifest-published manifest)
         (or *installed-published* "")))))))

;;; --- what the banner may say ------------------------------------------------

(defparameter +quiet-statuses+ '("unchecked" "up-to-date" "no-artifact" "unreachable")
  "The statuses a UI must render as NOTHING AT ALL.

Design section 8: `GET /_hyperion/update/status\' returns nothing when up to date, and the
empty swap REMOVES the banner. Each of these is an ordinary outcome a user cannot act on
and did not ask about:

  unchecked    no check has run yet -- there is no news, not good news.
  up-to-date   the common case, and the one the design names explicitly.
  no-artifact  a platform can join the release matrix a release late. Not the user\'s
               problem and not their decision.
  unreachable  the network is down; the user is on a plane. An application that
               interrupts someone\'s work to report that it could not reach a server has
               misjudged whose problem that is.

`blocked\' is deliberately NOT here. It is the one outcome that owes the user a sentence
-- a stale manifest, a schema this build cannot read, a per-machine install -- and every
block reason carries one.")

(defun banner-worthy-p (&optional (status (update-status)))
  "Should the update banner render at all?

THIS PREDICATE EXISTS SO THE EMPTINESS CANNOT BE RE-DECIDED BY A ROUTE. Section 8 makes
the empty response part of the design rather than an omission, and a route that renders a
friendly \"you are up to date\" instead is wrong by the design while looking like a
feature -- which means nobody would file it as a bug and someone would defend it. Putting
the decision here, with tests, means the next person who wants that banner has to delete
an assertion rather than merely disagree with a docstring.

The route calls this. It does not get to have its own opinion."
  (not (member (getf status :status) +quiet-statuses+ :test #'string=)))

;;; --- applying --------------------------------------------------------------

(define-condition update-not-implemented (error)
  ((detail :initarg :detail :reader update-not-implemented-detail))
  (:report (lambda (c s)
             (format s "this build cannot install updates yet: ~A"
                     (update-not-implemented-detail c)))))

(defvar *before-apply* nil
  "A function the application supplies, called and WAITED ON before anything is swapped.

THE APP DRIVES THE SHUTDOWN, not the updater. A consuming app of `hyperion/desktop' runs an
out-of-process webview child, and on Windows a second process holding a handle on the
bundle is enough to make a replace fail -- invisibly, because the framework's own test apps
do not run a webview during an update. But the updater must not reach into an application's
process tree and start killing children: it does not know what is unsaved, what a clean
shutdown means, or whether the user should be asked first.

So the app supplies this, and a non-NIL return means \"not ready\" -- a reason to ABANDON
the update rather than proceed. That keeps \"what must stop\" an application question,
which is what it is.

THE HAZARD IS NOW MEASURED, on this platform, against a real running executable:

  overwrite a RUNNING .exe in place   -> FAILS, \"because it is being used by another
                                         process\". With nothing running, the same
                                         overwrite succeeds.
  rename a RUNNING .exe aside         -> SUCCEEDS.
  rename the whole install DIRECTORY
    while a child runs inside it      -> SUCCEEDS.

The first line is why this hook exists. An installer replaces files in place, so any
binary in the bundle that is still running -- the webview child above all -- cannot be
replaced, and the update fails for a reason the updater cannot see and the user cannot
interpret. The consuming-app session that reported it was right about the mechanism, and
was right to withdraw the claim that it had a working sequencing to hand over.

The second and third lines are the more interesting result, and they are recorded here
because they bound a FUTURE strategy rather than this one: a stage-beside-and-rename swap
would not need the application to stop at all. That is not what NSIS or Inno do -- both
replace files in place -- so the hook is required for the strategies that exist today.")

;;; --- where this application is installed -----------------------------------

(defvar *app-name* nil
  "The product's install name, as `windows.nsi' -DAPPNAME sees it. The application sets it.

Needed to find the install directory, which is the one thing the Windows apply path must
get exactly right: the installer is handed `/D=' and will happily install a second copy
somewhere else if we guess wrong, leaving the running one untouched and the user
convinced the update silently did nothing.")

(defun %registry-install-dir (app)
  "The install directory NSIS recorded, or NIL.

AUTHORITATIVE, AND NOT A GUESS. `windows.nsi' writes HKCU Software\\<APPNAME>\\InstallDir
at install time and reads it back with InstallDirRegKey, so it is where the app actually
IS -- including when a user chose somewhere else. Deriving the path from a convention
instead would be the platform-key mistake again: the producer records a value and the
consumer recomputes it, and the two drift where nobody looks."
  #+win32
  (handler-case
      (let ((value (uiop:run-program
                    (list "reg" "query" (format nil "HKCU\\Software\\~A" app)
                          "/v" "InstallDir")
                    :output :string :ignore-error-status t)))
        (let ((pos (search "REG_SZ" value)))
          (when pos
            (let ((dir (string-trim '(#\Space #\Tab #\Return #\Newline)
                                    (subseq value (+ pos (length "REG_SZ"))))))
              (when (plusp (length dir)) dir)))))
    (error () nil))
  ;; Only one branch is ever read, so APP is referenced on both paths.
  #-win32 (progn app nil))

(defvar *install-directory* nil
  "Where this build is installed, when the application already knows.

Overrides detection entirely. Not every consumer is NSIS-installed -- a portable build, a
developer running from a tree, or a packaging this framework has not met yet all know
their own location better than any registry lookup does. Detection is the fallback, not
the authority.")

(defun %derived-install-dir ()
  "Where this build is installed, derived from the RUNNING IMAGE, or NIL.

The non-Windows answer, and it is a different KIND of answer from the Windows one above.
`%registry-install-dir' reads a value the installer RECORDED; this derives one from where
the image finds itself. Neither is a guess, but only the first survives the app being moved
by something that also updates the record -- which on macOS nothing does, because there is
no record and moving a `.app' is a thing users simply do.

macOS has two shapes, and both ship today: a plain bundle directory from
`build-desktop-app.lisp', or that same directory copied verbatim into `Foo.app/Contents/MacOS/'
by `build-dmg.sh'. The install location is the `.app' in the second case -- the unit a user
drags and an updater would replace -- and the bundle directory in the first.

ONLY FOR A DUMPED EXECUTABLE. A development image is running SBCL itself, so the
`directory the executable lives in' is SBCL's own bin/ -- true, and the wrong answer to the
question asked. Left underived it let `install-writable-p' return T for a Homebrew
installation of the Lisp, which is a path an apply run would then be willing to write into.
Measured on this machine: a stock REPL has runtime /opt/homebrew/.../bin/sbcl and core
/opt/homebrew/.../lib/sbcl/sbcl.core, while a `save-lisp-and-die :executable t' image
reports the SAME path for both, because the core is embedded in the executable. So the two
being equal is what distinguishes a shipped artifact from a developer's REPL, and it is a
property of the artifact rather than a flag anyone has to remember to set.

Returns a namestring, matching the Windows branch: callers treat this as a string and
`install-writable-p' formats it back into a pathname."
  (when (equal (ignore-errors (namestring sb-ext:*runtime-pathname*))
               (ignore-errors (namestring sb-ext:*core-pathname*)))
    (%derived-install-dir-1)))

(defun %derived-install-dir-1 ()
  "The location itself, once `%derived-install-dir' has established this is a real build."
  (let ((dir (platform:executable-directory)))
    (when dir
      (let ((app (platform:macos-app-bundle dir)))
        (uiop:native-namestring (or app dir))))))

(defun install-directory (&optional (app *app-name*))
  "Where this build is installed, or NIL when it cannot be determined.

On Windows: the registry first, then design section 1's per-user convention. Per-user is
load-bearing rather than a preference: an app under Program Files cannot rewrite itself
without elevation, and `windows.nsi' sets RequestExecutionLevel user precisely so it cannot.

Elsewhere: derived from the running image (see `%derived-install-dir'), which is why this
needs no installer and is not blocked on one (pre-publication issue 335). It returned NIL on every non-Windows
host until then -- no branch at all -- so `install-writable-p' answered NIL for a reason it
could not report, and the Not-Writable path could never be reached off Windows.

APP is unused off Windows: there is no per-application record to look up, only the image's
own location, which is the same answer whatever the app is called.

On Linux, an AppImage comes first (#251): inside one, the running image lives in the
AppImage's read-only mount, so the directory derived from it is not where the application
is installed. The AppImage file is, and its directory is what an update writes to."
  (or *install-directory*
      #+win32
      (when app
        (or (%registry-install-dir app)
            (let ((local (uiop:getenv "LOCALAPPDATA")))
              (when local (format nil "~A\\Programs\\~A" local app)))))
      #-win32 (progn app (or (%appimage-directory) (%derived-install-dir)))))

;;; --- the AppImage this process is running from (#251) ------------------------------
;;;
;;; The AppImage runtime mounts the image and runs the program inside the mount, with
;;; $APPIMAGE set to the absolute path of the AppImage FILE. That file is what an update
;;; replaces; nothing inside the mount can be written.

(defvar *appimage-path* nil
  "Overrides $APPIMAGE: the AppImage file this process counts as its installation. For
tests and harnesses, which run outside an AppImage.")

(defun appimage-path ()
  "The AppImage file this process is running from, as a native namestring, or NIL."
  (let ((path (or *appimage-path* (uiop:getenv "APPIMAGE"))))
    (and path (plusp (length path)) path)))

(defun %appimage-directory ()
  (let ((path (appimage-path)))
    (and path (uiop:native-namestring
               (uiop:pathname-directory-pathname (uiop:parse-native-namestring path))))))

(defun install-writable-p (&optional (dir (install-directory)))
  "Can this process write to its own install directory?

The `Not-Writable' test, and it is a REAL WRITE rather than an inspection of permissions:
an ACL that says yes and a filesystem that says no disagree often enough on Windows --
redirection, a per-machine install, an antivirus lock -- that asking the question the way
the installer will ask it is the only answer worth having."
  (when (and dir (probe-file (pathname (format nil "~A/" dir))))
    (let ((probe (merge-pathnames (format nil ".update-probe-~D" (get-universal-time))
                                  (pathname (format nil "~A/" dir)))))
      (handler-case
          (progn (with-open-file (s probe :direction :output :if-exists :supersede)
                   (write-char #\x s))
                 (ignore-errors (delete-file probe))
                 t)
        (error () nil)))))

;;; --- the payload -----------------------------------------------------------

(defparameter +staging-prefix+ "ouranos-update-"
  "The one place the staging directory's name is spelled. `%staging-directory' creates them
and `%sweep-staging' removes them, and a sweep that disagreed with the creator about the
name would either delete nothing or delete somebody else's directory.")

(defparameter +staging-retention-seconds+ 3600
  "How long a staging directory is left alone before a later update may remove it.

AN HOUR, AND NOT ZERO, because a staging directory may be IN USE by a process this one
cannot see. The installer is a detached child, and a second copy of the application may be
mid-handoff; deleting the installer a live process is about to run would turn a leak into a
failed update. An hour is far longer than any handoff and far shorter than forever.")

(defun %staging-name-time (name)
  "The universal time encoded in a staging directory NAME, or NIL.

NIL FOR ANYTHING WE DID NOT NAME. A sweep that deletes what it cannot parse is a sweep that
deletes a directory some other program happened to leave in the temp directory under a
similar name. Recognise, or leave alone."
  (when (uiop:string-prefix-p +staging-prefix+ name)
    (let* ((rest (subseq name (length +staging-prefix+)))
           (dash (position #\- rest))
           (digits (if dash (subseq rest 0 dash) rest)))
      (and (plusp (length digits))
           (every #'digit-char-p digits)
           (parse-integer digits :junk-allowed t)))))

(defun %sweep-staging (&optional (now (get-universal-time)))
  "Remove staging directories older than the retention window. Returns how many went.

CLEAN BEFORE YOU BEGIN, because there is no afterwards. `apply-update' hands the installer
to a detached process and then EXITS -- design section 7, and the exit is the strategy
rather than housekeeping -- so the moment after a successful stage is the one moment this
code is guaranteed not to reach. A delete-on-success would therefore never run on the path
that actually creates these, which is every applied update.

The leak was real and measured (pre-publication issue 257): 113 MB across 48 directories on one machine in a
day, twelve of them full installers from real updates and the rest from the suite. Nothing
crashed and nobody would have reported it; it surfaces months later as an application that
fills a disk, with no way to connect it to updating.

Errors are swallowed deliberately. A staging directory we cannot remove -- open handle,
permissions, a file somebody locked -- is a smaller problem than an update that refuses to
proceed because it could not tidy up."
  (let ((removed 0))
    (ignore-errors
     (dolist (dir (uiop:subdirectories (uiop:temporary-directory)))
       (let* ((name (car (last (pathname-directory dir))))
              (stamp (and (stringp name) (%staging-name-time name))))
         (when (and stamp (> (- now stamp) +staging-retention-seconds+))
           (when (ignore-errors (uiop:delete-directory-tree dir :validate t) t)
             (incf removed))))))
    removed))


;;; --- the staging directory's permissions (pre-publication issue 264) ----------------------------
;;;
;;; WHAT THIS ASSERTS, AND WHY IT IS NOT WHERE THE TICKET SAID TO LOOK. pre-publication issue 264 described the
;;; staged installer as sitting in "a shared, world-writable location (TEMP on Windows)".
;;; Measured, that is false on Windows. `uiop:temporary-directory' is the PER-USER temp
;;; (%LOCALAPPDATA%\Temp), not C:\Windows\Temp, and a staging directory created there
;;; carries exactly three ACEs -- SYSTEM, Administrators, and the user. The inheritance
;;; chain breaks at the profile root, whose DACL is protected, so the `Users' and `Everyone'
;;; ACEs on C:\Users never reach it. The cross-account writer this is aimed at cannot open
;;; the file at all.
;;;
;;; THE DEFECT IS THAT THE PROPERTY HOLDS BY ACCIDENT OF ENVIRONMENT. Every one of those
;;; ACEs is INHERITED, and the directory is named by an environment variable. A redirected
;;; TEMP, a service account with a machine-wide temp, a container image, a profile on a
;;; share -- each reopens the window, and not one of them announces itself. A precondition
;;; nothing asserts is not a precondition; it is something that happened to be true on the
;;; machine where somebody last looked.
;;;
;;; So the DACL is ESTABLISHED rather than inherited, and then READ BACK AND CHECKED.
;;; Establishing without checking would be the same mistake one step along: icacls fails on
;;; a filesystem with no ACL support, and a grant that silently did nothing is
;;; indistinguishable from a grant that worked if nobody looks afterwards.
;;;
;;; THIS IS DEFENCE IN DEPTH, NOT THE PRIMARY DEFENCE. `%reverify-staged' is the primary
;;; defence and holds regardless of any of this: it re-reads the file and re-checks the
;;; signature immediately before the hand-off. This narrows who can reach the file at all.
;;;
;;; ON POSIX (#251, with the Linux strategy): /tmp is world-writable, and its sticky bit stops
;;; another user REPLACING a file they do not own, which is a different guarantee from the
;;; one established here. So the staging directory is made mode 700 and then CHECKED, as the
;;; DACL is above: `%harden-staging-directory-posix' stats it afterwards and refuses unless
;;; it is owned by this process's user with no group or other access. Establishing without
;;; checking would be the same mistake it is on Windows, one filesystem along.

#+win32
(defparameter +acl-allowed-aliases+ '("BA" "SY")
  "SDDL aliases for Administrators and LocalSystem, which are allowed to hold the staging
directory open.

Not a concession. Both already own the machine: Administrators can take ownership of any
object and rewrite its DACL, and LocalSystem is the OS. Denying them would be theatre --
the DACL that excluded them would be one `takeown' away -- and would break backup and
anti-malware software that legitimately needs to read there.

THIS LIST IS NOT WHERE A NEW ALIAS GOES. When pre-publication issue 446 found the check refusing `LA', adding it
here would have made both symptoms disappear and left the actual defect -- a SID compared
against an alias -- in place for every aliased account. An alias that turns up unexpectedly
is a question about `%principal-sids', not an entry here.")

#+win32
(defparameter +acl-allowed-sids+ '("S-1-5-32-544" "S-1-5-18")
  "The same two principals as `+ACL-ALLOWED-ALIASES+', as the SIDs those aliases denote.

Both lists, because the comparison happens in SID space and the DACL may spell these either
way, and because a host that cannot resolve an alias must still accept what it always did.
These two are absolute -- the same SID on every Windows machine -- which is why they can be
written down here and `LA' cannot.")

#+win32
(defun %run-capture (program args)
  "Run PROGRAM with ARGS and return stdout as a string, or NIL if it could not be run."
  (handler-case
      (uiop:run-program (cons program args) :output '(:string :stripped t)
                        :error-output nil :ignore-error-status t)
    (error () nil)))

#+win32
(defun %current-user-sid ()
  "This process's user SID as a string, or NIL when it cannot be determined.

The SID rather than the name, because the name is not stable to compare against: `whoami'
prints DOMAIN\\user, icacls prints a localised BUILTIN\\..., and the two agree only on the
machine the code was written on."
  (let ((out (%run-capture "whoami" '("/user" "/fo" "csv" "/nh"))))
    (when out
      (let* ((comma (position #\, out))
             (sid (and comma (string-trim '(#\" #\Space #\Tab #\Return #\Newline)
                                          (subseq out (1+ comma))))))
        (when (and sid (uiop:string-prefix-p "S-1-" sid)) sid)))))

#+win32
(defun %acl-path (directory)
  "DIRECTORY as a native namestring WITHOUT its trailing separator -- icacls treats a
trailing backslash as part of a quoted argument and reports the path as not found."
  (string-right-trim '(#\\ #\/) (uiop:native-namestring directory)))

#+win32
(defun %sddl-dacl-principals (sddl)
  "The account of every ACE in SDDL's DACL, as the SDDL spells it: `BA', `SY', `WD', or a
raw `S-1-…'. NIL when there is no DACL section to read.

An SDDL ACE is `(type;flags;rights;object;inherit-object;account)', so the account is the
sixth field. Only the D: section is read -- an S: (audit) section says who is WATCHED, not
who may write, and treating it as a DACL would refuse machines with auditing configured."
  (let* ((d (search "D:" sddl))
         (s (and d (search "S:" sddl :start2 d)))
         (dacl (and d (subseq sddl d (or s (length sddl)))))
         (principals '()))
    (when dacl
      ;; `lparen'/`rparen' rather than the obvious `open'/`close': those name CL functions,
      ;; and a lexical binding that shadows one is the silent-collision hazard this tree has
      ;; a rule about. SBCL happened not to object here; the next reader should not have to
      ;; check whether it would.
      (let ((i 0))
        (loop for lparen = (position #\( dacl :start i)
              while lparen
              do (let ((rparen (position #\) dacl :start lparen)))
                   (unless rparen (return))
                   (let ((fields (uiop:split-string (subseq dacl (1+ lparen) rparen)
                                                    :separator ";")))
                     (when (>= (length fields) 6)
                       (push (string-trim " " (nth 5 fields)) principals)))
                   (setf i (1+ rparen))))))
    (nreverse principals)))

#+win32
(defun %staging-dacl (directory)
  "DIRECTORY's DACL principals, read back from the filesystem. NIL when it could not be read.

NIL MEANS \"COULD NOT LOOK\", NOT \"NOBODY IS GRANTED ANYTHING\", and the caller must not
confuse them -- an empty DACL and an unreadable one are different answers and only one of
them is safe.

icacls PRINTS LOCALISED NAMES: `BUILTIN\\Administrators' is `VORDEFINIERT\\Administratoren'
on a German install, so a check comparing those strings would pass on the machine it was
written on and refuse on every other. `/save' emits SDDL instead, whose well-known aliases
are fixed regardless of locale. It writes UTF-16LE."
  (let ((out (merge-pathnames (format nil "ouranos-acl-~A.sddl" (rand:random-hex 32))
                              (uiop:temporary-directory))))
    (unwind-protect
         (let ((code (nth-value 2
                      (uiop:run-program (list "icacls" (%acl-path directory)
                                              "/save" (uiop:native-namestring out))
                                        :output nil :error-output nil
                                        :ignore-error-status t))))
           (when (and (zerop code) (probe-file out))
             (let ((text (handler-case
                             (uiop:read-file-string out :external-format :utf-16le)
                           (error () nil))))
               (and text (%sddl-dacl-principals text)))))
      (ignore-errors (delete-file out)))))

#+win32
(defun %sddl-alias-p (principal)
  "True when PRINCIPAL is an SDDL alias rather than a SID, and safe to hand to a shell.

THE SECOND HALF IS NOT PARANOIA ABOUT OUR OWN DIRECTORY. This string was parsed out of a
file, and the next caller of `%principal-sids' may hold a DACL from somewhere we did not
create. An allowlist of the characters an SDDL account field can contain is cheaper than
reasoning about where each one came from."
  (and (stringp principal)
       (plusp (length principal))
       (not (uiop:string-prefix-p "S-1-" principal))
       (every (lambda (c) (or (alphanumericp c) (char= c #\-))) principal)))

#+win32
(defun %principal-sids (principals)
  "PRINCIPALS that are SDDL aliases, paired with the SID each one denotes. An alist; an alias
that could not be resolved is simply absent.

WHY THIS IS NEEDED AT ALL (pre-publication issue 446). `%current-user-sid' returns a SID, always. `icacls /save'
emits SDDL, and SDDL spells some accounts with an alias instead of a SID -- the built-in
Administrator is `LA', not `S-1-5-21-…-500'. So the two sides of the comparison are not
in the same alphabet, and a process running as an account that HAS an alias was told its own
staging directory belonged to a stranger. That is what the Windows CI leg had been reporting
since the check landed in pre-publication issue 264: `grants access to LA', where the resolved name printed
directly underneath it was the account the runner was running as.

THE ALIAS IS MACHINE-RELATIVE, WHICH IS WHY THIS ASKS WINDOWS INSTEAD OF TABULATING IT.
`BA' and `SY' are the same SID everywhere; `LA' is the local domain's RID 500 and `DA' the
domain's 512, so a table would have to derive a domain SID -- and deriving it from the
current user's is wrong for exactly the domain-joined machine where it matters.

ABSENT RATHER THAN NIL-MAPPED, so the caller cannot mistake `could not resolve' for
`resolved to nothing' and let something through. Unresolvable stays unexpected."
  (let ((aliases (remove-duplicates (remove-if-not #'%sddl-alias-p principals)
                                    :test #'string-equal)))
    (when aliases
      (let ((out (%run-capture
                  "powershell"
                  (list "-NoProfile" "-Command"
                        (format nil "foreach ($a in ~{'~A'~^,~}) { try { Write-Output ($a + ' ' + (New-Object System.Security.Principal.SecurityIdentifier($a)).Value) } catch { } }"
                                aliases)))))
        (when out
          (loop for line in (uiop:split-string out :separator '(#\Newline #\Return))
                for space = (position #\Space line)
                for alias = (and space (string-trim " " (subseq line 0 space)))
                for sid = (and space (string-trim " " (subseq line (1+ space))))
                when (and alias sid (uiop:string-prefix-p "S-1-" sid))
                  collect (cons alias sid)))))))

#+win32
(defun %unexpected-acl-principals (directory user-sid)
  "The DACL principals of DIRECTORY that are neither USER-SID nor a well-known machine
owner. :UNREADABLE when the DACL could not be read at all.

NAMED IN THE SPELLING THE DACL USED, compared in SIDs. Those are different jobs: the
comparison has to be exact, and the refusal has to be actionable to somebody reading it
without this file in front of them -- which means the string they will see again when they
go and look.

FAILS CLOSED. A principal whose alias could not be resolved is left unexpected, so a machine
where the resolution is unavailable refuses exactly as it did before rather than newly
accepting something."
  (let ((principals (%staging-dacl directory)))
    (if (null principals)
        :unreadable
        (let ((resolved (%principal-sids principals)))
          (flet ((sid-of (p)
                   (if (uiop:string-prefix-p "S-1-" p)
                       p
                       (cdr (assoc p resolved :test #'string-equal)))))
            (remove-if (lambda (p)
                         (let ((sid (sid-of p)))
                           (or
                            ;; The alias spellings, as before. Kept rather than replaced by
                            ;; their SIDs: it costs nothing and it means a host where the
                            ;; resolution cannot run still accepts the two principals that
                            ;; were always accepted, instead of starting to refuse them.
                            (member p +acl-allowed-aliases+ :test #'string-equal)
                            (and sid (member sid +acl-allowed-sids+ :test #'string-equal))
                            (and user-sid (string-equal p user-sid))
                            ;; THE FIX. The user's own ACE, spelled as the alias that
                            ;; `icacls /save' chose for it.
                            (and user-sid sid (string-equal sid user-sid)))))
                       principals))))))

#+win32
(defun %unsafe-staging-allowed-p ()
  "True only when OURANOS_ALLOW_UNSAFE_STAGING says so affirmatively.

AFFIRMATIVE-ONLY: `1', `true', `yes'. An unset variable, an empty one, and a variable
someone set to `0' or `false' meaning to turn it OFF all read as NIL. A check written as
\"is it set to anything\" turns `OURANOS_ALLOW_UNSAFE_STAGING=0' into permission, which is
the opposite of what whoever typed it intended."
  (let ((v (uiop:getenv "OURANOS_ALLOW_UNSAFE_STAGING")))
    (and v (member (string-downcase (string-trim " " v))
                   '("1" "true" "yes") :test #'string=)
         t)))

#+win32
(defun %harden-staging-directory (directory)
  "Replace DIRECTORY's inherited DACL with one of our own, then PROVE it took. Returns
DIRECTORY.

Signals `update-source-error' naming the principal that holds write access, unless
OURANOS_ALLOW_UNSAFE_STAGING is set.

REFUSES RATHER THAN WARNS. A warning on a path that then proceeds to stage and launch an
installer is the shape this whole ticket exists to remove.

THE REFUSAL NAMES THE PRINCIPAL, and prints icacls' own resolved output beside it. The SDDL
alias is what the check compared; the resolved name is what the person reading the message
has to go and change, in their own locale, and they will be reading it without this code in
front of them.

THE OVERRIDE IS AFFIRMATIVE-ONLY AND LOUD, the same shape as
OURANOS_ALLOW_UNVERIFIED_PLATFORM. A locked-down corporate image, a container, or a
filesystem with no ACLs at all can have odd but legitimate permissions, and refusing
outright would mean such a machine can never update -- which is its own security outcome,
since the update it cannot take is the one carrying the fix. An escape hatch on a security
check earns its keep here for two reasons that would not hold elsewhere: `%reverify-staged'
remains the primary defence either way, and anyone who can set this process's environment
already has better options than flipping this flag."
  (let ((sid (%current-user-sid)))
    ;; Without a SID we cannot name ourselves to icacls, and a grant naming only the
    ;; machine owners would lock this process out of its own staging directory.
    (when sid
      (uiop:run-program (list "icacls" (%acl-path directory)
                              "/inheritance:r"
                              "/grant:r" (format nil "*~A:(OI)(CI)F" sid)
                              "/grant:r" "*S-1-5-18:(OI)(CI)F"
                              "/grant:r" "*S-1-5-32-544:(OI)(CI)F")
                        :output nil :error-output nil :ignore-error-status t))
    (let ((unexpected (%unexpected-acl-principals directory sid)))
      (when (or (eq unexpected :unreadable) unexpected)
        (let ((detail
                (if (eq unexpected :unreadable)
                    (format nil "the staging directory's permissions could not be read (~A)"
                            (%acl-path directory))
                    (format nil "the staging directory ~A grants access to ~{~A~^, ~}"
                            (%acl-path directory) unexpected))))
          (if (%unsafe-staging-allowed-p)
              ;; LOUD. An override that proceeds quietly is indistinguishable from the
              ;; check having passed, and the log of a build that staged into a directory
              ;; other people can write must say so.
              (format *error-output*
                      "~&hyperion/update: WARNING -- ~A.~%Proceeding because OURANOS_ALLOW_UNSAFE_STAGING is set. The payload's signature is still re-checked at the hand-off.~%"
                      detail)
              ;; One long control string: a ~<newline> continuation becomes an illegal
              ;; ~<Return> directive on a CRLF checkout (see CLAUDE.md).
              (error 'update-source-error
                     :detail (format nil "~A -- refusing to stage an installer there.~%~A~%Set OURANOS_ALLOW_UNSAFE_STAGING=1 to proceed anyway; the payload's signature is re-checked at the hand-off regardless."
                                     detail
                                     (or (%run-capture "icacls" (list (%acl-path directory)))
                                         ""))))))
      directory)))

#+unix
(defun %harden-staging-directory-posix (directory)
  "Make DIRECTORY mode 700, then check that it is: owned by this user, no group or other bits.
Signals `update-source-error' otherwise, before anything is written into it."
  (let ((name (uiop:native-namestring directory)))
    (sb-posix:chmod name #o700)
    (let ((st (sb-posix:stat name)))
      (unless (and (= (sb-posix:stat-uid st) (sb-posix:getuid))
                   (zerop (logand (sb-posix:stat-mode st) #o077)))
        (error 'update-source-error
               :detail (format nil "the staging directory ~A is not private to this user (mode ~O); nothing was staged"
                               name (logand (sb-posix:stat-mode st) #o7777)))))
    directory))

(defun %staging-directory ()
  "Where a payload is downloaded before it is run. NEVER the live bundle.

THE NAME CARRIES A RANDOM SUFFIX AS WELL AS A TIME, because `get-universal-time' has
one-second resolution and two applies inside one second would otherwise SHARE a directory.
Not hypothetical: one whole-tree run produced `ouranos-update-3997370989' and
`…990' one second apart, and the second directory held two different payloads from two
tests that had landed in the same second (pre-publication issue 257). A name whose uniqueness suffix is not
unique is worse than no suffix, because it reads as a guarantee."
  (%sweep-staging)
  ;; `aion/random', and hyperion's entropy suite is right to insist -- it rejected the
  ;; first version of this line, and the second, which was a COMMENT naming the standard
  ;; generator. The rule is absolute by design (pre-publication issue 95, `tests/entropy-tests.lisp'): prose
  ;; goes around it, never an allowlist.
  ;;
  ;; What it caught was real. SBCL's generator is MT19937 seeded identically at every image
  ;; start, so the "unique" suffix was the SAME in every process -- measured: three
  ;; consecutive suite runs produced `7SXFTE', `XQ0ESU', `TZBQ5U' and `8W3TXJ', in that
  ;; order, every time. Two applications launched in the same second would have collided
  ;; exactly as before, and the suffix would have been decoration.
  ;;
  ;; Seeding it from the clock would have fixed the collision and left the deeper
  ;; problem: this name is a path in a shared-by-convention directory that a VERIFIED
  ;; INSTALLER is about to be written to and then EXECUTED FROM. Anyone who can predict it
  ;; can create it first. That is why pre-publication issue 95's guard covers the whole of `hyperion/src' rather
  ;; than only the things that look like secrets, and it caught this.
  ;;
  ;; The entropy makes the name unguessable; the loop makes it unique. A name is only unique
  ;; if nothing else already holds it, and the only authority on that is the filesystem.
  (loop for candidate = (merge-pathnames
                         (format nil "~A~D-~A/" +staging-prefix+ (get-universal-time)
                                 (rand:random-hex 48))
                         (uiop:temporary-directory))
        unless (probe-file candidate)
          do (ensure-directories-exist candidate)
             ;; BEFORE ANYTHING IS WRITTEN INTO IT. The payload inherits this directory's
             ;; DACL when it is created, so hardening has to happen while the directory is
             ;; still empty -- afterwards would leave the installer carrying the permissions
             ;; we just decided were not good enough. A refusal here has nothing to clean up.
             #+win32 (%harden-staging-directory candidate)
             #+unix (%harden-staging-directory-posix candidate)
             (return candidate)))

(defun %write-bytes (bytes path)
  (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                            :if-exists :supersede)
    (write-sequence bytes out))
  path)

(defun %read-staged-bytes (path)
  "Read PATH back as octets. Returns the bytes actually read, never a declared length.

`file-length' is a claim by the filesystem about a file another writer may be holding open;
`read-sequence's return value is the only measurement of what we got. They disagree exactly
when it matters -- a substitute written between the length query and the read. So the vector
is trimmed to the count read, and a short read becomes short bytes that fail verification
rather than a buffer with a verified prefix and uninitialised tail."
  (with-open-file (in path :element-type '(unsigned-byte 8) :if-does-not-exist nil)
    (unless in
      (error 'update-source-error
             :detail "the staged installer disappeared between staging and launch"))
    (let* ((buffer (make-array (max 1 (file-length in)) :element-type '(unsigned-byte 8)))
           (n (read-sequence buffer in)))
      ;; If the file GREW past the declared length, the rest is not ours either. Read on
      ;; until the stream is done, so a longer substitute cannot be truncated back into
      ;; something that verifies.
      (if (< n (length buffer))
          (subseq buffer 0 n)
          (let ((extra (loop for byte = (read-byte in nil nil)
                             while byte collect byte)))
            (if extra
                (concatenate '(vector (unsigned-byte 8)) buffer extra)
                buffer))))))

(defun %reverify-staged (installer signature)
  "Re-establish, FROM DISK, that the bytes about to be executed are the verified bytes.

WHY THIS EXISTS AND WHAT IT DOES NOT DO (pre-publication issue 264). `stage-payload' verifies the payload's
signature over the bytes it holds IN MEMORY, then writes them and hands `launch-installer'
a PATH. Between the write and the launch the file is an ordinary file, and nothing
re-established that the bytes at that path are the bytes that were verified. The window was
not theorised: driven through the real `apply-update', a second writer replaced the staged
file at the moment of hand-off and what would have executed was 26 bytes of substitute
rather than the 35 verified bytes.

This re-reads the file and re-runs the SAME signature check over what is actually on disk,
immediately before the hand-off. The signature rather than a digest, because the signature
is what the trust chain is made of -- a recomputed digest compared against a number we are
also holding in memory proves only that memory agrees with itself.

IT NARROWS THE WINDOW; IT DOES NOT CLOSE IT. What remains is the interval between this read
and the OS's own open-for-execute, which on Windows is a separate process whose loader does
its own open. Closing it needs either a handle held across the hand-off or #113's
stage-and-rename, where the verified artefact never sits at the path that gets executed.
The Linux strategy (#251) has the same window between this read and its own read of the
staged file; the macOS strategy is not written. Closing the window is #113.

MEASURE THE PRECONDITION BEFORE COSTING THE REST: on Windows the staged file lives under
`uiop:temporary-directory', which is the PER-USER temp (`%LOCALAPPDATA%\\Temp'), not
`C:\\Windows\\Temp'. Measured on a default profile, the only principals holding write access
there are the user, SYSTEM and Administrators -- the profile root's DACL is protected, so
the `Users' and `Everyone' ACEs on `C:\\Users' do not propagate in. A same-user writer is
out of scope (it owns the application anyway) and the other two already own the machine. So
the cross-account writer this guard is aimed at cannot reach the path on a default Windows
desktop. WHAT NOTHING CHECKS IS THAT THIS REMAINS TRUE: every one of those ACEs is
INHERITED, the directory is named by an environment variable, and a redirected TEMP or a
service account with a shared temp reopens the window with nothing reporting it."
  (let ((bytes (%read-staged-bytes installer)))
    (unless (%verified-p bytes signature)
      ;; Same class as a payload that never verified: discard and say so. Not a state the
      ;; caller can shrug off -- reaching here means the file changed under us.
      (error 'update-source-error
             :detail "the staged installer no longer matches its signature -- it was modified after verification, and has NOT been launched"))
    installer))

(defun stage-payload (source entry)
  "Download and VERIFY this platform's payload. Returns (VALUES STAGED-PATH SIGNATURE).

STAGE, THEN VERIFY, THEN (elsewhere) SWAP -- design section 7, in that order and never
another. Verifying after the swap would mean a bad payload has already replaced a working
program, which is the failure the signature exists to prevent rather than to report.

THE SIGNATURE COMES BACK OUT because what is verified here is bytes in memory, and what
gets executed is a path (pre-publication issue 264). `%reverify-staged' has to ask the same question of the file
on disk immediately before the hand-off, and only the caller knows when that moment is.
A second value, so callers wanting just the path are unaffected."
  (let* ((url (or (platform-payload-url entry)
                  (error 'update-not-implemented
                         :detail "the manifest carries no payload for this platform")))
         (bytes (fetch-artifact source url))
         (signature (fetch-artifact source (concatenate 'string url ".sig"))))
    (unless (%verified-p bytes signature)
      ;; NOT a condition the caller can shrug off, and not a state: a payload that does not
      ;; verify is either a compromised host or a corrupted transfer, and the only correct
      ;; response is to discard it and say so.
      (error 'update-source-error
             :detail "the downloaded payload's signature did not verify -- discarded"))
    (values (%write-bytes bytes
                          (merge-pathnames (%payload-filename url) (%staging-directory)))
            signature)))

(defun %discard-staged (installer)
  "Remove the staging directory INSTALLER sits in. Only ever one this code named.

Called when an apply STOPS after staging -- a refusal, or a format nothing can install.
Never called after a hand-off: the installer is about to run, and the process is about to
exit, which is what `%sweep-staging' exists for instead."
  (ignore-errors
   (let* ((parent (uiop:pathname-directory-pathname (pathname installer)))
          (name (car (last (pathname-directory parent)))))
     (when (and (stringp name) (%staging-name-time name))
       (uiop:delete-directory-tree parent :validate t)))))

(defun %payload-filename (url)
  (let ((slash (position #\/ url :from-end t)))
    (if (and slash (< (1+ slash) (length url)))
        (subseq url (1+ slash))
        "update-payload.exe")))

;;; --- applying, on Windows --------------------------------------------------

(defvar *launch-installer* nil
  "The one irreversible step, as a parameter so everything up to it can be tested.

NIL means the real launch. A function of (INSTALLER-PATH INSTALL-DIR) replaces it, which
is how the suite drives the whole apply path -- staging, verification, the shutdown hook,
argument construction -- without running an installer. Same reasoning as
`aion/http-client's PERFORM: the effect at the edge is the part a test must be able to
substitute, and everything else is then genuinely covered rather than assumed.")

(defvar *exit-after-handoff* nil
  "How the application exits once the installer has been launched. NIL means `uiop:quit'.

EXITING IS PART OF THE APPLY STRATEGY, NOT THE CALLER'S HOUSEKEEPING. A running .exe
cannot be overwritten on Windows, so the process that would be replaced must be gone
before the installer reaches it. Leaving that to a caller means the one time somebody
forgets, the update fails in a way that looks like NSIS being broken.")

(define-condition unknown-payload-format (error)
  ((format-name :initarg :format-name :reader unknown-payload-format-name))
  (:report (lambda (c s)
             (format s "this build does not know how to install a ~S payload"
                     (unknown-payload-format-name c)))))

(defun %format-keyword (name)
  "The manifest's `format' string as a keyword this build recognises, or NIL.

NIL FOR ANYTHING UNRECOGNISED, and the caller refuses rather than guessing. `format'
exists (design section 3) so a product can change packaging WITHOUT shipping a new client
first -- which means an old client will meet a format it has never heard of, and the
correct response is the same as for a schema from the future: decline, and say so. A
client that fell back to a default strategy would run an installer with the wrong flags,
silently, against a user's machine."
  (when (stringp name)
    (cond ((string-equal name "nsis") :nsis)
          ((string-equal name "inno") :inno)
          ((string-equal name "appimage") :appimage)
          ((string-equal name "app-targz") :app-targz)
          (t nil))))

;;; THE ARGUMENT VECTORS, built apart from the launch so a test can read them.
;;;
;;; NEVER QUOTE AN ARGUMENT YOU HAND TO A PROCESS SPAWNER AS A LIST. `uiop:launch-program'
;;; given a LIST builds the Windows command line itself and quotes whatever needs quoting;
;;; an argument that arrives already carrying quotes gets a second layer, and the installer
;;; receives a literal `"' inside the value.
;;;
;;; This was `(format nil "/DIR=~S" install-dir)', which reads like "quote the path" and is
;;; not: `~S' is the LISP PRINTER, so it also escapes every backslash. #111's end-to-end
;;; harness caught it -- `apply-update' reported `applying', the installer ran, and three
;;; minutes later the installed bundle was still the old version. Measured against a real
;;; Inno installer, one variable at a time:
;;;
;;;   /DIR="C:\Users\...\Q1"        hand-quoted, single backslashes  -> exit 3, NOTHING installed
;;;   /DIR=C:\\Users\\...\\Q2       unquoted, doubled backslashes    -> exit 0, installed
;;;   /DIR=C:\Users\...\has space\Q3   plain, spawner-quoted         -> exit 0, installed
;;;
;;; So it is the QUOTES, not the backslashes -- and the third line is the control that
;;; matters, because a path with a space is the case someone reached for quoting to solve.
;;; The spawner already handles it, and handles it correctly.
;;;
;;; NSIS never showed the fault because `/D=' takes no quotes: the same defect, in the same
;;; module, was invisible in the packaging that had been run and fatal in the one that had
;;; not. "Installs nothing while exiting 0" is what this file warns about two comments up;
;;; this was that, in our own client, with exit 3.

(defun %nsis-arguments (installer install-dir)
  "NSIS: /S is silent, /D= is the directory.

/D= MUST COME LAST AND MUST NOT BE QUOTED -- that is NSIS's parser, not a style choice. A
quoted /D= is taken literally, quotes and all, and the installer cheerfully creates a
directory with a quotation mark in its name. Anything after /D= is treated as part of the
path, which is why nothing may follow it."
  (list installer "/S" (format nil "/D=~A" install-dir)))

(defun %inno-arguments (installer install-dir)
  "Inno Setup: /VERYSILENT, and /DIR= -- which, unlike NSIS's, may appear anywhere.

  /VERYSILENT       no window at all. /SILENT still shows a progress dialog, which is
                    wrong for an update the user already consented to in-app.
  /SUPPRESSMSGBOXES a silent install that stops on a message box is not silent. Required
                    for /VERYSILENT to be unattended in practice rather than in theory.
  /NORESTART        the updater decides about restarting, not the installer.
  /DIR=             the destination, UNQUOTED here -- see the comment above.

The flags differ from NSIS in every particular, which is exactly why the strategy is chosen
by the manifest rather than by the OS: both are Windows, and handing one the other's
arguments installs nothing while exiting 0."
  (list installer "/VERYSILENT" "/SUPPRESSMSGBOXES" "/NORESTART"
        (format nil "/DIR=~A" install-dir)))

(defgeneric launch-installer (format installer install-dir)
  (:documentation
   "Run the staged INSTALLER for FORMAT, silently, against INSTALL-DIR.

ONE STRATEGY PER FORMAT (design section 7), dispatched on the MANIFEST's declared format
rather than on the host OS -- which is the whole point of the field. A consuming
application that packages some other way adds a method here; it does not edit this file
and does not need a new API. Same doctrine as the update sources: a new backend, not a
new surface."))

(defmethod launch-installer ((format t) installer install-dir)
  "Refuse anything with no strategy. NEVER a fallback."
  (declare (ignore installer install-dir))
  (error 'unknown-payload-format :format-name format))

(defmethod launch-installer ((format (eql :nsis)) installer install-dir)
  (uiop:launch-program (%nsis-arguments installer install-dir)))

(defmethod launch-installer ((format (eql :inno)) installer install-dir)
  "MEASURED END TO END, not reasoned about: #111's harness runs this method against a real
Inno installer and a real per-user install, and asserts the bundle actually changed version
afterwards. Before that assertion existed, this method exited 3 and installed nothing."
  (uiop:launch-program (%inno-arguments installer install-dir)))

;;; --- Linux: replace the AppImage file (#251, design section 7) ---------------------
;;;
;;; The payload IS the new AppImage. Design section 7: write it beside the old one, make it
;;; executable, rename() it over the old one, relaunch. rename() within one directory is
;;; atomic, so the path always names either the old file or the whole new one; and replacing
;;; the file a process is running from is allowed on Linux, because the kernel keeps the old
;;; inode alive until that process exits.
;;;
;;; The previous file is kept, as `<name>.previous', by a hard link made before the rename
;;; (the section's common invariant: keep the previous version until the new one has
;;; started). Nothing yet removes it after a successful start, or rolls back to it after a
;;; failed one; that is recorded on #251.
;;;
;;; THE BYTES WRITTEN ARE READ BACK AND COMPARED before the rename. They come from the staged
;;; file, which APPLY-UPDATE re-verified against the payload's signature immediately before
;;; calling this. What remains between that re-verification and this read is the same window
;;; the Windows strategies have between it and the installer's own open.

#+linux
(defun %appimage-sibling (target suffix)
  (uiop:parse-native-namestring (concatenate 'string (uiop:native-namestring target) suffix)))

#+linux
(defun replace-appimage (staged target)
  "Replace the AppImage file TARGET with the bytes of STAGED. Returns TARGET's pathname.

Leaves the old file as `<TARGET>.previous'. Signals `update-source-error' if what was
written does not read back as what was staged."
  (let* ((target (uiop:parse-native-namestring target))
         (bytes (%read-staged-bytes staged))
         (new (%appimage-sibling target (format nil ".update-~A" (rand:random-hex 16))))
         (previous (%appimage-sibling target ".previous")))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (ignore-errors (delete-file new)))))
      (%write-bytes bytes new)
      (sb-posix:chmod (uiop:native-namestring new) #o755)
      (unless (equalp bytes (%read-staged-bytes new))
        (error 'update-source-error
               :detail "the new AppImage did not read back as the verified payload; it was not installed"))
      (when (probe-file target)
        (when (probe-file previous) (delete-file previous))
        (sb-posix:link (uiop:native-namestring target) (uiop:native-namestring previous)))
      (sb-posix:rename (uiop:native-namestring new) (uiop:native-namestring target)))
    target))

#+linux
(defmethod launch-installer ((format (eql :appimage)) installer install-dir)
  "Replace the AppImage this process runs from with INSTALLER, then start the new one.

INSTALL-DIR is the AppImage's directory, which APPLY-UPDATE has already found writable; the
file replaced is `appimage-path'. The new process inherits this one's standard output and
error, so a terminal or a harness that started the old one sees the new one."
  (declare (ignore install-dir))
  (let ((target (or (appimage-path)
                    (error 'update-not-implemented
                           :detail "this process is not running from an AppImage ($APPIMAGE is not set)"))))
    (replace-appimage installer target)
    (uiop:launch-program (list target) :output :interactive :error-output :interactive)))

(defun %host-strategies ()
  "The payload formats this host can apply."
  #+win32 '(:nsis :inno)
  #+linux '(:appimage)
  #-(or win32 linux) '())

(defun %apply-inputs (source channel product)
  "Re-fetch and re-verify, returning (VALUES SOURCE PLATFORM-ENTRY).

The manifest is fetched a second time rather than cached from the check. That is a
deliberate cost: a cached manifest is a decision made at an earlier moment, and the
window between checking and applying is exactly where a channel gets a security fix."
  (multiple-value-bind (bytes signature) (fetch-manifest source channel)
    (unless (%verified-p bytes signature)
      (error 'update-source-error :detail "the manifest no longer verifies"))
    (let* ((manifest (%parse-manifest bytes))
           (entry (manifest-platform manifest)))
      (when (and product (string/= product (manifest-product manifest)))
        (error 'update-source-error :detail "the manifest is for another product"))
      (unless entry
        (error 'update-not-implemented
               :detail "the manifest carries no artifact for this platform"))
      (values source entry))))

(defun apply-update (&key (source *update-source*) (channel "stable") (product nil))
  "Install the available update.

WINDOWS AND LINUX. macOS refuses, because its apply strategy, `app-targz', is not written
(#251): the release workflow builds its payload, but nothing here unpacks and swaps a
`.app' yet. Each host applies only its own formats (`%host-strategies'): a manifest entry
declaring another platform's packaging is refused rather than handed to the wrong tool.

The order, and every step of it is load-bearing:

  1. Re-check, so the decision is this moment's rather than a stale banner's.
  2. Refuse unless the state is `available'. Applying something the check refused would
     make the check decorative.
  3. Refuse when the install directory is not writable -- a per-machine install, which is
     a STATE meaning \"ask whoever installed this\", not an error to raise at a user who
     cannot act on it.
  4. Download and VERIFY the payload. Stage it outside the live bundle; never verify after.
  5. Ask the application to shut down, and WAIT. A non-NIL answer abandons the update.
  6. Launch the installer silently, then EXIT IMMEDIATELY so nothing holds the bundle."
  (let ((status (check-for-update :source source :channel channel :product product)))
    (unless (string= "available" (getf status :status))
      (error 'update-not-implemented
             :detail (format nil "no update to apply (~A)" (getf status :status))))
    #-(or win32 linux)
    (error 'update-not-implemented
           :detail (format nil "the ~A apply strategy is not written yet (#251)"
                           (platform:platform-key)))
    #+(or win32 linux)
    (let ((dir (install-directory)))
      (unless dir
        (error 'update-not-implemented
               :detail "cannot determine this application's install directory (is *app-name* set?)"))
      (unless (install-writable-p dir)
        (setf *update-state*
              (list :status "blocked" :version (getf status :version)
                    :block "not-writable"
                    :detail (format nil "~A was installed for all users; ask whoever installed it to update it" dir)))
        (return-from apply-update *update-state*))
      (multiple-value-bind (bytes-source entry) (%apply-inputs source channel product)
        (multiple-value-bind (installer signature) (stage-payload bytes-source entry)
         (let (
              ;; EVERY EXIT FROM HERE ON EITHER HANDS OFF OR CLEANS UP. `%sweep-staging'
              ;; handles the hand-off case, because after a hand-off this process exits and
              ;; has no afterwards -- but a refusal after staging DOES have one, and until
              ;; pre-publication issue 257 it left a full installer behind every time. An unrecognised format and
              ;; an application that is not ready to stop are both ordinary outcomes, not
              ;; rare ones, and neither has any reason to leave a payload on the disk.
              (handed-off nil))
          (unwind-protect
               (progn
          ;; THE SHUTDOWN IS THE APPLICATION'S DECISION, and we wait on it. A consuming app
          ;; of hyperion/desktop holds an out-of-process webview child, and on Windows that
          ;; second handle on the bundle is enough to make the replace fail.
          (let ((refusal (when *before-apply* (funcall *before-apply*))))
            (when refusal
              (setf *update-state*
                    (list :status "blocked" :version (getf status :version)
                          :block "not-ready" :detail (princ-to-string refusal)))
              (return-from apply-update *update-state*)))
          ;; THE FORMAT COMES FROM THE MANIFEST, and an unrecognised one refuses. Before
          ;; this the path launched NSIS unconditionally: `platform-format' was defined,
          ;; exported and had ZERO call sites, so a manifest declaring any other packaging
          ;; would have been handed to NSIS with NSIS's flags.
          (let ((strategy (%format-keyword (platform-format entry))))
            ;; THE REFUSAL IS POLICY AND LIVES HERE, not in the strategy. It was in
            ;; `launch-installer''s fallback method first, and the suite caught that
            ;; immediately: `*launch-installer*' REPLACES that generic, so any consumer
            ;; (or test) supplying its own launcher silently lost the guard along with it.
            ;; A safety check reachable only through the thing it guards is not a check.
            (unless strategy
              (error 'unknown-payload-format :format-name (platform-format entry)))
            ;; A format this build knows but this host cannot run: an `nsis' entry reaching
            ;; a Linux client, say. Refused here, before the launch, for the same reason the
            ;; unknown format is -- it is policy, and a replaced `*launch-installer*' must
            ;; not take it away.
            (unless (member strategy (%host-strategies))
              (error 'update-not-implemented
                     :detail (format nil "a `~(~A~)' payload cannot be applied on ~A"
                                     strategy (platform:platform-key))))
            ;; LAST THING BEFORE THE IRREVERSIBLE STEP, and deliberately after the format
            ;; refusal and the application's shutdown -- both of those can take arbitrary
            ;; time, and every moment between the write and the launch is window (pre-publication issue 264). The
            ;; check belongs as late as it can be placed, which is here: the next form hands
            ;; a path to something that will execute it.
            ;;
            ;; Not inside `launch-installer'. `*launch-installer*' REPLACES that generic, so
            ;; a consumer or a test supplying its own launcher would silently lose the check
            ;; along with it -- the same lesson the format refusal above records.
            (%reverify-staged installer signature)
            (funcall (or *launch-installer* #'launch-installer)
                     strategy (namestring installer) dir)
            (setf handed-off t))
          (setf *update-state*
                (list :status "applying" :version (getf status :version)
                      :block "" :detail ""))
          (funcall (or *exit-after-handoff* (lambda () (uiop:quit 0))))
          *update-state*)
            (unless handed-off (%discard-staged installer)))))))))
