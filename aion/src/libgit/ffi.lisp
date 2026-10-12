;;;; ffi.lisp --- the raw binding: one Lisp function per libgit2 function aion/libgit calls.
;;;;
;;;; Nothing is interpreted here. Return codes come back as libgit2's integers and objects as
;;;; foreign pointers. The struct layouts and constants are copied from the libgit2 1.9.7
;;;; headers, with the header named at each. LIBRARY.LISP refuses any library that is not
;;;; 1.9, so these layouts are the ones in force.
;;;;
;;;; SCRIPTS/BUILD-LIBGIT2.LISP LISTS EVERY FUNCTION BOUND HERE in *REQUIRED-SYMBOLS*, and
;;;; refuses a build that does not export one of them. A function added here goes there too;
;;;; the aion/libgit suite checks that the two lists agree.
;;;;
;;;; Every function is bound with %DEFGIT, which records its C name in *ENTRY-POINTS*.
;;;; LIBRARY.LISP checks, for each of them, that the name resolves to the library it loaded,
;;;; because on SBCL a foreign call is resolved across the whole process, not in one library.

(in-package #:aion/libgit)

;;; --- constants ---------------------------------------------------------------------

;;; include/git2/errors.h
(defconstant +git-enotfound+ -3)
(defconstant +git-euser+ -7)
(defconstant +git-eunbornbranch+ -9)
(defconstant +git-enonfastforward+ -11)
(defconstant +git-econflict+ -13)
(defconstant +git-eauth+ -16)
(defconstant +git-error-http+ 34)  ; git_error_t GIT_ERROR_HTTP
(defconstant +git-passthrough+ -30)
(defconstant +git-iterover+ -31)

;;; include/git2/remote.h
(defconstant +redirect-none+ 1)
(defconstant +redirect-initial+ 2)
(defconstant +redirect-all+ 4)
(defconstant +fetch-options-version+ 1)
(defconstant +push-options-version+ 1)

;;; include/git2/credential.h
(defconstant +credential-userpass-plaintext+ 1)

;;; include/git2/common.h. GIT_FEATURE_SHA256 is set only by a build with
;;; GIT_EXPERIMENTAL_SHA256, whose git_oid is a type byte and 32 bytes rather than 20
;;; (src/libgit2/libgit2.c, git_libgit2_features).
(defconstant +feature-threads+ 1)
(defconstant +feature-sha256+ 2048)

;;; include/git2/types.h
(defconstant +object-commit+ 1)
(defconstant +object-blob+ 3)

;;; include/git2/revwalk.h
(defconstant +sort-topological+ 1)
(defconstant +sort-time+ 2)

;;; include/git2/diff.h
(defconstant +diff-format-patch+ 1)
(defconstant +diff-find-options-version+ 1)
(defconstant +diff-find-renames+ 1)

;;; include/git2/oid.h: 20 bytes, because this build leaves experimental SHA-256 off (a
;;; build with it on is named libgit2-experimental, which LIBRARY.LISP never loads).
(defconstant +oid-size+ 20)

;;; --- structs -----------------------------------------------------------------------

;;; include/git2/errors.h
(cffi:defcstruct git-error-struct
  (message :pointer)
  (klass :int))

;;; include/git2/types.h
(cffi:defcstruct git-time
  (time :int64)
  (offset :int)
  (sign :char))

(cffi:defcstruct git-signature
  (name :pointer)
  (email :pointer)
  (when (:struct git-time)))

;;; include/git2/diff.h
(cffi:defcstruct git-diff-find-options
  (version :unsigned-int)
  (flags :uint32)
  (rename-threshold :uint16)
  (rename-from-rewrite-threshold :uint16)
  (copy-threshold :uint16)
  (break-rewrite-threshold :uint16)
  (rename-limit :size)
  (metric :pointer))

;;; include/git2/buffer.h
(cffi:defcstruct git-buf
  (ptr :pointer)
  (reserved :size)
  (size :size))

;;; include/git2/strarray.h
(cffi:defcstruct git-strarray
  (strings :pointer)
  (count :size))

;;; include/git2/proxy.h
(cffi:defcstruct git-proxy-options
  (version :unsigned-int)
  (type :int)
  (url :pointer)
  (credentials :pointer)
  (certificate-check :pointer)
  (payload :pointer))

;;; include/git2/remote.h, as built: without GIT_DEPRECATE_HARD, so update_tips and
;;; resolve_url are function pointers. Every member after VERSION is a pointer either way.
(cffi:defcstruct git-remote-callbacks
  (version :unsigned-int)
  (sideband-progress :pointer)
  (completion :pointer)
  (credentials :pointer)
  (certificate-check :pointer)
  (transfer-progress :pointer)
  (update-tips :pointer)
  (pack-progress :pointer)
  (push-transfer-progress :pointer)
  (push-update-reference :pointer)
  (push-negotiation :pointer)
  (transport :pointer)
  (remote-ready :pointer)
  (payload :pointer)
  (resolve-url :pointer)
  (update-refs :pointer))

;;; include/git2/remote.h. The enums are ints.
(cffi:defcstruct git-fetch-options
  (version :int)
  (callbacks (:struct git-remote-callbacks))
  (prune :int)
  (update-fetchhead :unsigned-int)
  (download-tags :int)
  (proxy-opts (:struct git-proxy-options))
  (depth :int)
  (follow-redirects :int)
  (custom-headers (:struct git-strarray)))

(cffi:defcstruct git-push-options
  (version :unsigned-int)
  (pb-parallelism :unsigned-int)
  (callbacks (:struct git-remote-callbacks))
  (proxy-opts (:struct git-proxy-options))
  (follow-redirects :int)
  (custom-headers (:struct git-strarray))
  (remote-push-options (:struct git-strarray)))

;;; --- the binding macro -------------------------------------------------------------

(defvar *entry-points* '()
  "The C name of every libgit2 function bound below, in no particular order.")

(defmacro %defgit ((c-name lisp-name) return-type &body arguments)
  "CFFI:DEFCFUN, recording C-NAME in *ENTRY-POINTS*."
  `(progn
     (pushnew ,c-name *entry-points* :test #'string=)
     (cffi:defcfun (,c-name ,lisp-name) ,return-type ,@arguments)))

;;; --- the library -------------------------------------------------------------------

(%defgit ("git_libgit2_init" %init) :int)
(%defgit ("git_libgit2_shutdown" %shutdown) :int)
(%defgit ("git_libgit2_version" %version) :int
  (major :pointer) (minor :pointer) (rev :pointer))
(%defgit ("git_libgit2_features" %features) :int)
(%defgit ("git_error_last" %error-last) :pointer)

;;; --- repositories and the index ----------------------------------------------------

(%defgit ("git_repository_init" %repository-init) :int
  (out :pointer) (path (:string :encoding :utf-8)) (is-bare :unsigned-int))
(%defgit ("git_repository_open" %repository-open) :int
  (out :pointer) (path (:string :encoding :utf-8)))
(%defgit ("git_repository_free" %repository-free) :void (repo :pointer))
(%defgit ("git_repository_workdir" %repository-workdir) :pointer (repo :pointer))
(%defgit ("git_repository_index" %repository-index) :int (out :pointer) (repo :pointer))

(%defgit ("git_index_add_bypath" %index-add-bypath) :int
  (index :pointer) (path (:string :encoding :utf-8)))
(%defgit ("git_index_remove_bypath" %index-remove-bypath) :int
  (index :pointer) (path (:string :encoding :utf-8)))
(%defgit ("git_index_read" %index-read) :int (index :pointer) (force :int))
(%defgit ("git_index_write" %index-write) :int (index :pointer))
(%defgit ("git_index_write_tree" %index-write-tree) :int (out :pointer) (index :pointer))
(%defgit ("git_index_free" %index-free) :void (index :pointer))

;;; --- commits -----------------------------------------------------------------------

(%defgit ("git_signature_new" %signature-new) :int
  (out :pointer) (name (:string :encoding :utf-8)) (email (:string :encoding :utf-8))
  (time :int64) (offset :int))
(%defgit ("git_signature_free" %signature-free) :void (sig :pointer))

(%defgit ("git_reference_name_to_id" %reference-name-to-id) :int
  (out :pointer) (repo :pointer) (name (:string :encoding :utf-8)))

(%defgit ("git_commit_create" %commit-create) :int
  (id :pointer) (repo :pointer) (update-ref :pointer) (author :pointer) (committer :pointer)
  (message-encoding :pointer) (message (:string :encoding :utf-8)) (tree :pointer)
  (parent-count :size) (parents :pointer))
(%defgit ("git_commit_lookup" %commit-lookup) :int
  (out :pointer) (repo :pointer) (id :pointer))
(%defgit ("git_commit_free" %commit-free) :void (commit :pointer))
(%defgit ("git_commit_id" %commit-id) :pointer (commit :pointer))
(%defgit ("git_commit_message" %commit-message) :pointer (commit :pointer))
(%defgit ("git_commit_author" %commit-author) :pointer (commit :pointer))
(%defgit ("git_commit_time" %commit-time) :int64 (commit :pointer))
(%defgit ("git_commit_tree" %commit-tree) :int (out :pointer) (commit :pointer))
(%defgit ("git_commit_parentcount" %commit-parentcount) :unsigned-int (commit :pointer))
(%defgit ("git_commit_parent" %commit-parent) :int
  (out :pointer) (commit :pointer) (n :unsigned-int))

;;; --- trees, blobs and objects ------------------------------------------------------

(%defgit ("git_tree_lookup" %tree-lookup) :int (out :pointer) (repo :pointer) (id :pointer))
(%defgit ("git_tree_free" %tree-free) :void (tree :pointer))
(%defgit ("git_tree_entry_bypath" %tree-entry-bypath) :int
  (out :pointer) (root :pointer) (path (:string :encoding :utf-8)))
(%defgit ("git_tree_entry_id" %tree-entry-id) :pointer (entry :pointer))
(%defgit ("git_tree_entry_filemode" %tree-entry-filemode) :int (entry :pointer))
(%defgit ("git_tree_entry_free" %tree-entry-free) :void (entry :pointer))

(%defgit ("git_blob_lookup" %blob-lookup) :int (out :pointer) (repo :pointer) (id :pointer))
(%defgit ("git_blob_rawcontent" %blob-rawcontent) :pointer (blob :pointer))
(%defgit ("git_blob_rawsize" %blob-rawsize) :uint64 (blob :pointer))
(%defgit ("git_blob_free" %blob-free) :void (blob :pointer))

(%defgit ("git_revparse_single" %revparse-single) :int
  (out :pointer) (repo :pointer) (spec (:string :encoding :utf-8)))
(%defgit ("git_object_peel" %object-peel) :int
  (out :pointer) (object :pointer) (target-type :int))
(%defgit ("git_object_free" %object-free) :void (object :pointer))

;;; --- history and diffs -------------------------------------------------------------

(%defgit ("git_revwalk_new" %revwalk-new) :int (out :pointer) (repo :pointer))
(%defgit ("git_revwalk_sorting" %revwalk-sorting) :int (walk :pointer) (mode :unsigned-int))
(%defgit ("git_revwalk_push" %revwalk-push) :int (walk :pointer) (id :pointer))
(%defgit ("git_revwalk_next" %revwalk-next) :int (out :pointer) (walk :pointer))
(%defgit ("git_revwalk_free" %revwalk-free) :void (walk :pointer))

(%defgit ("git_diff_tree_to_tree" %diff-tree-to-tree) :int
  (out :pointer) (repo :pointer) (old-tree :pointer) (new-tree :pointer) (options :pointer))
(%defgit ("git_diff_to_buf" %diff-to-buf) :int
  (out :pointer) (diff :pointer) (format :int))
(%defgit ("git_diff_free" %diff-free) :void (diff :pointer))
(%defgit ("git_diff_find_options_init" %diff-find-options-init) :int
  (options :pointer) (version :unsigned-int))
(%defgit ("git_diff_find_similar" %diff-find-similar) :int (diff :pointer) (options :pointer))
(%defgit ("git_buf_dispose" %buf-dispose) :void (buf :pointer))

;;; --- references --------------------------------------------------------------------

(%defgit ("git_reference_lookup" %reference-lookup) :int
  (out :pointer) (repo :pointer) (name (:string :encoding :utf-8)))
(%defgit ("git_reference_symbolic_target" %reference-symbolic-target) :pointer (ref :pointer))
(%defgit ("git_reference_create" %reference-create) :int
  (out :pointer) (repo :pointer) (name (:string :encoding :utf-8)) (id :pointer) (force :int)
  (log-message (:string :encoding :utf-8)))
(%defgit ("git_reference_free" %reference-free) :void (ref :pointer))
(%defgit ("git_repository_set_head" %repository-set-head) :int
  (repo :pointer) (refname (:string :encoding :utf-8)))
(%defgit ("git_graph_descendant_of" %graph-descendant-of) :int
  (repo :pointer) (commit :pointer) (ancestor :pointer))
(%defgit ("git_checkout_tree" %checkout-tree) :int
  (repo :pointer) (treeish :pointer) (options :pointer))

;;; --- remotes -----------------------------------------------------------------------

(%defgit ("git_remote_lookup" %remote-lookup) :int
  (out :pointer) (repo :pointer) (name (:string :encoding :utf-8)))
(%defgit ("git_remote_create" %remote-create) :int
  (out :pointer) (repo :pointer) (name (:string :encoding :utf-8))
  (url (:string :encoding :utf-8)))
(%defgit ("git_remote_set_url" %remote-set-url) :int
  (repo :pointer) (remote (:string :encoding :utf-8)) (url (:string :encoding :utf-8)))
(%defgit ("git_remote_set_pushurl" %remote-set-pushurl) :int
  (repo :pointer) (remote (:string :encoding :utf-8)) (url (:string :encoding :utf-8)))
(%defgit ("git_remote_free" %remote-free) :void (remote :pointer))
(%defgit ("git_remote_url" %remote-url) :pointer (remote :pointer))
(%defgit ("git_fetch_options_init" %fetch-options-init) :int
  (options :pointer) (version :unsigned-int))
(%defgit ("git_push_options_init" %push-options-init) :int
  (options :pointer) (version :unsigned-int))
(%defgit ("git_remote_fetch" %remote-fetch) :int
  (remote :pointer) (refspecs :pointer) (options :pointer) (reflog-message :pointer))
(%defgit ("git_remote_push" %remote-push) :int
  (remote :pointer) (refspecs :pointer) (options :pointer))
(%defgit ("git_credential_userpass_plaintext_new" %credential-userpass-plaintext-new) :int
  (out :pointer) (username (:string :encoding :utf-8)) (password (:string :encoding :utf-8)))
