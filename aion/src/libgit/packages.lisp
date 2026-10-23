;;;; packages.lisp --- aion/libgit: local git repositories over the libgit2 this tree builds
;;;; (#429).

(cl:defpackage #:aion/libgit
  (:use #:cl)
  (:documentation
   "Versioned history for the framework, over the libgit2 that scripts/build-libgit2.lisp
    builds from libgit2.pin. Opt-in: nothing that loads aion gets a native library from this
    unless it loads aion/libgit.

    Local operations: create or open a repository, stage files, commit, list the history of
    the repository or of one path, read a file as it was at a revision, and diff two
    revisions as a patch. Remotes: name a remote, fetch it, fast-forward a branch from it,
    and push a branch to it. A credential is passed in by the caller; this package never
    looks one up. Redirects to another host are refused by default (see libgit2.pin).

    A REPOSITORY is used by one thread at a time. Each operation takes the repository's
    lock, so two threads that share one are serialised rather than corrupting it. Two
    repository objects, even for the same directory, run in parallel.")
  (:export
   ;; the library
   #:load-libgit2 #:unload-libgit2 #:libgit2-loaded-p #:libgit2-path #:libgit2-version
   #:ensure-loaded
   #:libgit2-not-found #:libgit2-not-found-searched
   #:libgit2-mismatch #:libgit2-mismatch-path #:libgit2-mismatch-reason
   ;; errors
   #:git-error #:git-error-operation #:git-error-code #:git-error-class #:git-error-message
   #:repository-closed
   ;; repositories
   #:repository #:init-repository #:open-repository #:close-repository #:with-repository
   #:repository-workdir
   ;; changes
   #:stage #:commit
   ;; reading
   #:commit-info #:commit-info-id #:commit-info-message #:commit-info-author
   #:commit-info-email #:commit-info-time #:commit-info-parents
   #:history #:read-at-revision #:diff-text #:resolve-revision
   ;; remotes
   #:set-remote #:remote-url #:fetch #:pull #:push-branch
   #:credential #:make-credential #:credential-user
   #:authentication-failed #:authentication-failed-url
   #:not-fast-forward #:not-fast-forward-branch #:not-fast-forward-local
   #:not-fast-forward-remote
   #:push-rejected #:push-rejected-reference #:push-rejected-reason
   #:checkout-conflict
   #:detached-head #:detached-head-repository
   #:branch-not-checked-out #:branch-not-checked-out-branch #:branch-not-checked-out-head))
