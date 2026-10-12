;;;; remote.lisp --- remotes: fetch, fast-forward pull and push (#429, step four).
;;;;
;;;; THE CREDENTIAL IS AN ARGUMENT. aion is the bottom of the framework line, so nothing here
;;;; looks a credential up. The app, or a system above aion such as hades/credentials, finds
;;;; it and passes it in, as a CREDENTIAL or as a function that returns one.
;;;;
;;;; TWO ADVISORIES THAT UPSTREAM HAS NOT FIXED, recorded in libgit2.pin, are handled here:
;;;;
;;;;   GHSA-2889-x8f6-mc4x  FOLLOW-REDIRECTS defaults to :NONE, which libgit2 reads as
;;;;                        GIT_REMOTE_REDIRECT_NONE. A redirect to the same host is still
;;;;                        followed. A redirect to another host is refused, so a credential
;;;;                        meant for the remote is never sent to a different host.
;;;;   GHSA-h7gc-w2gg-p9xp  On Linux, where libgit2 uses OpenSSL for HTTPS, an https remote
;;;;                        whose host is an IP address is refused with INSECURE-REMOTE before
;;;;                        any connection is made. macOS and Windows use the system's TLS,
;;;;                        which the advisory does not concern.
;;;;
;;;; LISP CODE THAT LIBGIT2 CALLS never unwinds through libgit2's frames. Each callback catches
;;;; any error, keeps it, and returns GIT_EUSER, and the operation signals the kept error after
;;;; libgit2 has returned and cleaned up.

(in-package #:aion/libgit)

;;; --- conditions --------------------------------------------------------------------

(defun %redact-url (url)
  "URL without the user name and password it may carry before the host."
  (let* ((start (search "://" url))
         (authority (and start (+ start 3)))
         (end (and start (or (position-if (lambda (c) (member c '(#\/ #\? #\#))) url
                                          :start authority)
                             (length url))))
         (at (and start (position #\@ url :start authority :end end :from-end t))))
    (if at
        (concatenate 'string (subseq url 0 authority) (subseq url (1+ at)))
        url)))

(define-condition authentication-failed (git-error)
  ((url :initarg :url :initform nil :reader authentication-failed-url))
  (:report
   (lambda (c stream)
     (format stream "The remote ~@[at ~A ~]asked for a credential, and ~A."
             (authentication-failed-url c)
             (if (eql (git-error-code c) +git-eauth+)
                 "none was given or it was refused"
                 "refused the one given"))))
  (:documentation "A remote asked for a credential and none was given, or it refused the one
given. URL is the remote's address without any user name or password in it. A credential is
offered at most once per operation, so a refused one is not retried."))

(define-condition insecure-remote (error)
  ((url :initarg :url :reader insecure-remote-url)
   (advisory :initarg :advisory :reader insecure-remote-advisory))
  (:report
   (lambda (c stream)
     (format stream "~A ~A"
             (format nil "Refusing the remote at ~A: its host is an IP address, and libgit2's OpenSSL check of an IP address's certificate is wrong (~A)."
                     (insecure-remote-url c) (insecure-remote-advisory c))
             "Use the host's name.")))
  (:documentation "Signalled on Linux, before any connection, for an https remote whose host
is an IP address, because of the libgit2 advisory ADVISORY. URL carries no user name or
password."))

(define-condition not-fast-forward (error)
  ((branch :initarg :branch :reader not-fast-forward-branch)
   (local :initarg :local :reader not-fast-forward-local)
   (remote :initarg :remote :reader not-fast-forward-remote))
  (:report
   (lambda (c stream)
     (format stream "~A cannot be fast-forwarded to the remote's ~A: each has commits the other lacks."
             (not-fast-forward-branch c) (not-fast-forward-remote c))))
  (:documentation "PULL found that BRANCH has commits the remote's branch does not, so taking
the remote's would lose them. LOCAL and REMOTE are the two commit ids. Nothing local was
changed except the remote-tracking branch."))

(define-condition push-rejected (error)
  ((reference :initarg :reference :reader push-rejected-reference)
   (reason :initarg :reason :reader push-rejected-reason))
  (:report (lambda (c stream)
             (format stream "The push of ~A was rejected: ~A."
                     (push-rejected-reference c) (push-rejected-reason c))))
  (:documentation "PUSH-BRANCH's update of REFERENCE on the remote was refused, because it
was not a fast-forward or because the remote refused it, with REASON."))

(define-condition checkout-conflict (git-error) ()
  (:documentation "PULL would have overwritten a change in the working directory or the index
that is not committed, or a file that is not tracked. Nothing was written, and the branch was
not moved."))

(define-condition detached-head (error)
  ((repository :initarg :repository :reader detached-head-repository))
  (:report (lambda (c stream)
             (format stream "HEAD in ~A is not on a branch, so there is no branch to pull or push."
                     (repository-workdir (detached-head-repository c)))))
  (:documentation "PULL or PUSH-BRANCH was asked for HEAD's branch while HEAD names a commit
rather than a branch."))

(define-condition branch-not-checked-out (error)
  ((branch :initarg :branch :reader branch-not-checked-out-branch)
   (head :initarg :head :reader branch-not-checked-out-head))
  (:report (lambda (c stream)
             (format stream "PULL can update ~A only when it is HEAD's branch, or HEAD has no commits yet; HEAD is ~A."
                     (branch-not-checked-out-branch c) (branch-not-checked-out-head c))))
  (:documentation "PULL was given a BRANCH that is not HEAD's, while HEAD has commits."))

;;; --- credentials -------------------------------------------------------------------

(defstruct (credential (:constructor make-credential (user token)))
  "A user name and a token or password for a remote over HTTPS. TOKEN is a string or an
aion/secret:secret, and is revealed only when libgit2 asks for it."
  (user nil :read-only t)
  (token nil :read-only t))

(defmethod print-object ((c credential) stream)
  (print-unreadable-object (c stream :type t)
    (format stream "~A" (credential-user c))))

(defun %reveal (token)
  (etypecase token
    (string token)
    (aion/secret:secret (aion/secret:reveal token))))

;;; --- one operation's state, which the callbacks read and write ---------------------

(defstruct (%operation (:constructor %make-operation (credentials)))
  credentials
  (offered nil)       ; a credential has been given to libgit2 once
  (refused nil)       ; libgit2 asked again after it was given, so the remote refused it
  (url nil)           ; the address libgit2 asked for a credential for, redacted
  (kept nil)          ; an error a callback caught, signalled once libgit2 returns
  (rejected '()))     ; (reference . reason) for each update the remote refused

(defvar *operation* nil
  "The fetch or push running on this thread. libgit2 calls the callbacks on the thread that
called it, so a special binding reaches them.")

(defmacro %guarded (&body body)
  "Run BODY in a callback. An error is kept for the operation to signal, and GIT_EUSER is
returned to libgit2 in place of a non-local exit through its frames."
  `(handler-case (progn ,@body)
     (error (e)
       (when *operation* (setf (%operation-kept *operation*) e))
       +git-euser+)))

(cffi:defcallback %credentials-callback :int
    ((out :pointer) (url :pointer) (username-from-url :pointer) (allowed :unsigned-int)
     (payload :pointer))
  (declare (ignore payload))
  (%guarded
    (let ((op *operation*))
      (when op (setf (%operation-url op) (%redact-url (or (%string url) ""))))
      (cond ((or (null op) (zerop (logand allowed +credential-userpass-plaintext+)))
             +git-passthrough+)
            ((%operation-offered op)
             ;; Asked again: the remote refused what was given. Offering it again would only
             ;; repeat the refusal, so libgit2 is told there is nothing to give.
             (setf (%operation-refused op) t)
             +git-passthrough+)
            (t
             (let* ((given (%operation-credentials op))
                    (credential (if (functionp given)
                                    (funcall given (%operation-url op) (%string username-from-url))
                                    given)))
               (setf (%operation-offered op) t)
               (cond ((null credential) +git-passthrough+)
                     (t (check-type credential credential)
                        (%check "git_credential_userpass_plaintext_new"
                                (%credential-userpass-plaintext-new
                                 out (credential-user credential)
                                 (%reveal (credential-token credential))))
                        0))))))))

(cffi:defcallback %push-update-reference-callback :int
    ((reference :pointer) (status :pointer) (data :pointer))
  (declare (ignore data))
  (%guarded
    (unless (or (null *operation*) (cffi:null-pointer-p status))
      (push (cons (%string reference) (%string status)) (%operation-rejected *operation*)))
    0))

(defun %redirect-mode (follow-redirects)
  (ecase follow-redirects
    (:none +redirect-none+)
    (:initial +redirect-initial+)
    (:all +redirect-all+)))

(defun %set-callbacks (callbacks)
  (setf (cffi:foreign-slot-value callbacks '(:struct git-remote-callbacks) 'credentials)
        (cffi:callback %credentials-callback)
        (cffi:foreign-slot-value callbacks '(:struct git-remote-callbacks) 'push-update-reference)
        (cffi:callback %push-update-reference-callback)))

(defun %finish-operation (operation name code)
  "Signal what OPERATION, the state of the libgit2 call NAME that returned CODE, ended with:
an error a callback kept, AUTHENTICATION-FAILED, or GIT-ERROR. CODE when it is not negative."
  (cond ((%operation-kept operation) (error (%operation-kept operation)))
        ((and (minusp code) (or (= code +git-eauth+) (%operation-refused operation)))
         (multiple-value-bind (class message) (%last-error)
           (error 'authentication-failed :operation name :code code :class class
                                         :message message :url (%operation-url operation))))
        (t (%check name code))))

;;; --- the IP-address check for GHSA-h7gc-w2gg-p9xp -----------------------------------

(defun %url-host (url)
  "The host in URL as written, with the brackets of an IPv6 address kept, or NIL when URL
has no scheme://."
  (let ((start (search "://" url)))
    (when start
      (let* ((from (+ start 3))
             (end (or (position-if (lambda (c) (member c '(#\/ #\? #\#))) url :start from)
                      (length url)))
             (authority (subseq url from end))
             (at (position #\@ authority :from-end t))
             (host-port (if at (subseq authority (1+ at)) authority)))
        (if (and (plusp (length host-port)) (char= #\[ (char host-port 0)))
            (subseq host-port 0 (1+ (or (position #\] host-port) (1- (length host-port)))))
            (subseq host-port 0 (or (position #\: host-port) (length host-port))))))))

(defun %ip-literal-https-url-p (url)
  "Whether URL is an https URL whose host is an IP address. libgit2's OpenSSL stream treats a
host as one when inet_pton accepts it as IPv4 or IPv6. This answers yes for any host in
brackets, which is how a URL writes an IPv6 address, and for any four dot-separated runs of
digits, so it refuses at least every host inet_pton accepts as an address."
  (and (>= (length url) 8)
       (string-equal "https://" url :end2 8)
       (let ((host (%url-host url)))
         (and host
              (plusp (length host))
              (or (char= #\[ (char host 0))
                  (let ((parts (uiop:split-string host :separator ".")))
                    (and (= 4 (length parts))
                         (every (lambda (p) (and (plusp (length p)) (every #'digit-char-p p)))
                                parts))))))))

(defun %refuse-insecure (url)
  "Signal INSECURE-REMOTE for URL on Linux when it is https and its host is an IP address."
  #+linux (when (and url (%ip-literal-https-url-p url))
            (error 'insecure-remote :url (%redact-url url) :advisory "GHSA-h7gc-w2gg-p9xp"))
  #-linux (progn url nil))

;;; --- remotes -----------------------------------------------------------------------

(defmacro %with-remote ((var repo name) &body body)
  "Run BODY with VAR bound to the git_remote NAME in REPO, freed however BODY exits. libgit2
applies the url.<base>.insteadOf rewrites from the configuration when it looks the remote up,
so its URLs are the ones it will connect to."
  (let ((out (gensym "OUT")))
    `(cffi:with-foreign-object (,out :pointer)
       (%check "git_remote_lookup" (%remote-lookup ,out ,repo ,name))
       (let ((,var (cffi:mem-ref ,out :pointer)))
         (unwind-protect (progn ,@body)
           (%remote-free ,var))))))

(defun set-remote (repository name url)
  "Make NAME a remote of REPOSITORY that fetches from and pushes to URL, and return NAME. A new
remote gets git's default fetch refspec, +refs/heads/*:refs/remotes/NAME/*. For a remote that
exists, only its URL changes. URL is anything git accepts: an https:// or http:// address, a
file:// URL, or the path of a local repository."
  (%with-repository-pointer (repo repository)
    (cffi:with-foreign-object (out :pointer)
      (let ((code (%remote-lookup out repo name)))
        (cond ((zerop code)
               (%remote-free (cffi:mem-ref out :pointer))
               (%check "git_remote_set_url" (%remote-set-url repo name url)))
              ((= code +git-enotfound+)
               (%check "git_remote_create" (%remote-create out repo name url))
               (%remote-free (cffi:mem-ref out :pointer)))
              (t (%check "git_remote_lookup" code))))))
  name)

(defun remote-url (repository name)
  "The URL REPOSITORY fetches from for the remote NAME, after any insteadOf rewrite, or NIL
when it has no remote of that name."
  (%with-repository-pointer (repo repository)
    (cffi:with-foreign-object (out :pointer)
      (let ((code (%remote-lookup out repo name)))
        (if (= code +git-enotfound+)
            nil
            (let ((remote (progn (%check "git_remote_lookup" code) (cffi:mem-ref out :pointer))))
              (unwind-protect (%string (%remote-url remote))
                (%remote-free remote))))))))

(defun %fetch (remote credentials follow-redirects)
  (%refuse-insecure (%string (%remote-url remote)))
  (cffi:with-foreign-object (options '(:struct git-fetch-options))
    (%check "git_fetch_options_init" (%fetch-options-init options +fetch-options-version+))
    (%set-callbacks (cffi:foreign-slot-pointer options '(:struct git-fetch-options) 'callbacks))
    (setf (cffi:foreign-slot-value options '(:struct git-fetch-options) 'follow-redirects)
          (%redirect-mode follow-redirects))
    (let ((*operation* (%make-operation credentials)))
      (%finish-operation *operation* "git_remote_fetch"
                         (%remote-fetch remote (cffi:null-pointer) options
                                        (cffi:null-pointer))))))

(defun fetch (repository remote &key credentials (follow-redirects :none))
  "Fetch the branches of REMOTE, a remote's name, into REPOSITORY's refs/remotes/REMOTE/, as
git fetch REMOTE does. Nothing else changes: no branch moves and no file is written.

CREDENTIALS is a CREDENTIAL, a function of the remote's URL and the user name in it (or NIL)
that returns a CREDENTIAL or NIL, or NIL for none. It is used only if the remote asks for one,
and at most once: a remote that refuses it signals AUTHENTICATION-FAILED.

FOLLOW-REDIRECTS is :NONE (the default), :INITIAL or :ALL. With :NONE, a redirect to the same
host is followed and one to another host is refused (GHSA-2889-x8f6-mc4x).

Signals INSECURE-REMOTE on Linux for an https remote whose host is an IP address, and
GIT-ERROR for anything else libgit2 reports."
  (%with-repository-pointer (repo repository)
    (%with-remote (r repo remote)
      (%fetch r credentials follow-redirects)))
  (values))

(defun %head-branch (repository repo)
  "The full name of the branch HEAD is on, such as refs/heads/main, even when that branch has
no commits yet. Signals DETACHED-HEAD when HEAD names a commit."
  (cffi:with-foreign-object (out :pointer)
    (%check "git_reference_lookup" (%reference-lookup out repo "HEAD"))
    (let ((head (cffi:mem-ref out :pointer)))
      (unwind-protect
           (or (%string (%reference-symbolic-target head))
               (error 'detached-head :repository repository))
        (%reference-free head)))))

(defun %short-branch (reference)
  (if (eql 0 (search "refs/heads/" reference)) (subseq reference 11) reference))

(defun %reference-id (repo name oid)
  "Write the commit id the reference NAME points at to OID and return T, or return NIL when
there is no such reference."
  (let ((code (%reference-name-to-id oid repo name)))
    (cond ((zerop code) t)
          ((= code +git-enotfound+) nil)
          (t (%check "git_reference_name_to_id" code)))))

(defun %descendant-p (repo commit ancestor)
  (plusp (%check "git_graph_descendant_of" (%graph-descendant-of repo commit ancestor))))

(defun %oid-equal (a b)
  (dotimes (i +oid-size+ t)
    (unless (= (cffi:mem-aref a :uint8 i) (cffi:mem-aref b :uint8 i)) (return nil))))

(defun %reread-index (repo)
  "Re-read REPO's index from disk, for the reason STAGE gives."
  (cffi:with-foreign-object (out :pointer)
    (%check "git_repository_index" (%repository-index out repo))
    (let ((index (cffi:mem-ref out :pointer)))
      (unwind-protect (%check "git_index_read" (%index-read index 0))
        (%index-free index)))))

(defun pull (repository remote &key branch credentials (follow-redirects :none))
  "Fetch REMOTE as FETCH does, then fast-forward a local branch to the remote's branch of the
same name and check it out. The branch is HEAD's, or BRANCH (a short name such as main) when
HEAD has no commits yet, in which case HEAD is moved onto BRANCH. That is how a new, empty
repository takes a remote's branch whatever its own default branch is called.

Returns :FAST-FORWARDED or :UP-TO-DATE, and the branch's commit id as a second value. A branch
that already contains the remote's commit, including one with commits the remote lacks, is
:UP-TO-DATE.

Signals NOT-FAST-FORWARD when the branch and the remote's branch have each got commits the
other lacks, and CHECKOUT-CONFLICT when the new commit would overwrite a change that is not
committed or a file that is not tracked. In both cases only the remote-tracking branch has
changed. Signals BRANCH-NOT-CHECKED-OUT for a BRANCH that is not HEAD's while HEAD has commits,
DETACHED-HEAD when HEAD is not on a branch, and GIT-ERROR when the remote has no such branch.
CREDENTIALS and FOLLOW-REDIRECTS are as for FETCH."
  (%with-repository-pointer (repo repository)
    (let* ((head (%head-branch repository repo))
           (target (if branch (format nil "refs/heads/~A" branch) head))
           (short (%short-branch target)))
      (cffi:with-foreign-objects ((local :uint8 +oid-size+) (theirs :uint8 +oid-size+)
                                  (out :pointer))
        (let ((head-born (%head-id repo local)))
          (when (and head-born (string/= target head))
            (error 'branch-not-checked-out :branch short :head (%short-branch head))))
        (%with-remote (r repo remote)
          (%fetch r credentials follow-redirects))
        (let ((tracking (format nil "refs/remotes/~A/~A" remote short)))
          ;; GIT_ENOTFOUND here means the remote has no branch of that name.
          (%check "git_reference_name_to_id" (%reference-name-to-id theirs repo tracking)))
        (let ((local-p (%reference-id repo target local)))
          (when (and local-p (or (%oid-equal local theirs) (%descendant-p repo local theirs)))
            (return-from pull (values :up-to-date (%oid-hex local))))
          (when (and local-p (not (%descendant-p repo theirs local)))
            (error 'not-fast-forward :branch short :local (%oid-hex local)
                                     :remote (%oid-hex theirs)))
          (%reread-index repo)
          (%check "git_commit_lookup" (%commit-lookup out repo theirs))
          (let ((commit (cffi:mem-ref out :pointer)))
            (unwind-protect
                 (let ((code (%checkout-tree repo commit (cffi:null-pointer))))
                   (when (= code +git-econflict+)
                     (multiple-value-bind (class message) (%last-error)
                       (error 'checkout-conflict :operation "git_checkout_tree" :code code
                                                 :class class :message message)))
                   (%check "git_checkout_tree" code))
              (%commit-free commit)))
          (%check "git_reference_create"
                  (%reference-create out repo target theirs 1
                                     (format nil "pull: fast-forward from ~A" remote)))
          (%reference-free (cffi:mem-ref out :pointer))
          (when (string/= target head)
            (%check "git_repository_set_head" (%repository-set-head repo target)))
          (values :fast-forwarded (%oid-hex theirs)))))))

(defun push-branch (repository remote &key branch credentials (follow-redirects :none))
  "Push a branch to the branch of the same name on REMOTE, as git push REMOTE BRANCH does,
and return the commit id pushed. The branch is HEAD's unless BRANCH, a short name such as
main, is given. On success refs/remotes/REMOTE/BRANCH is updated too.

Signals PUSH-REJECTED when the remote's branch has commits this one lacks, or the remote
refuses the update, and DETACHED-HEAD when no BRANCH is given and HEAD is not on a branch.
The push URL is checked as FETCH checks the URL. CREDENTIALS and FOLLOW-REDIRECTS are as for
FETCH. (Named PUSH-BRANCH because PUSH is Common Lisp's.)"
  (%with-repository-pointer (repo repository)
    (let* ((target (if branch
                       (format nil "refs/heads/~A" branch)
                       (%head-branch repository repo)))
           (refspec (format nil "~A:~A" target target)))
      (%with-remote (r repo remote)
        (%refuse-insecure (or (%string (%remote-pushurl r)) (%string (%remote-url r))))
        (cffi:with-foreign-objects ((options '(:struct git-push-options))
                                    (refspecs '(:struct git-strarray))
                                    (strings :pointer 1)
                                    (oid :uint8 +oid-size+))
          (%check "git_reference_name_to_id" (%reference-name-to-id oid repo target))
          (%check "git_push_options_init" (%push-options-init options +push-options-version+))
          (%set-callbacks (cffi:foreign-slot-pointer options '(:struct git-push-options)
                                                     'callbacks))
          (setf (cffi:foreign-slot-value options '(:struct git-push-options) 'follow-redirects)
                (%redirect-mode follow-redirects))
          (cffi:with-foreign-string (spec refspec :encoding :utf-8)
            (setf (cffi:mem-aref strings :pointer 0) spec
                  (cffi:foreign-slot-value refspecs '(:struct git-strarray) 'strings) strings
                  (cffi:foreign-slot-value refspecs '(:struct git-strarray) 'count) 1)
            (let* ((*operation* (%make-operation credentials))
                   (code (%remote-push r refspecs options)))
              (when (= code +git-enonfastforward+)
                (error 'push-rejected :reference target :reason "not a fast-forward"))
              (%finish-operation *operation* "git_remote_push" code)
              (let ((rejected (first (%operation-rejected *operation*))))
                (when rejected
                  (error 'push-rejected :reference (car rejected) :reason (cdr rejected))))))
          (%oid-hex oid))))))
