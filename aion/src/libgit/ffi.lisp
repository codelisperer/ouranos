;;;; ffi.lisp --- the raw binding: one Lisp function per libgit2 function aion/libgit calls.
;;;;
;;;; Nothing is interpreted here. Return codes come back as libgit2's integers and objects as
;;;; foreign pointers. The struct layouts and constants are copied from the libgit2 1.9.7
;;;; headers, with the header named at each. LIBRARY.LISP refuses any library that is not
;;;; 1.9, so these layouts are the ones in force.
;;;;
;;;; SCRIPTS/BUILD-LIBGIT2.LISP LISTS EVERY FUNCTION BOUND HERE in *REQUIRED-SYMBOLS*, and
;;;; refuses a build that does not export one of them. A function added here goes there too.

(in-package #:aion/libgit)

;;; --- constants ---------------------------------------------------------------------

;;; include/git2/errors.h
(defconstant +git-enotfound+ -3)
(defconstant +git-eunbornbranch+ -9)
(defconstant +git-iterover+ -31)

;;; include/git2/common.h
(defconstant +feature-threads+ 1)

;;; include/git2/types.h
(defconstant +object-commit+ 1)
(defconstant +object-blob+ 3)

;;; include/git2/revwalk.h
(defconstant +sort-topological+ 1)
(defconstant +sort-time+ 2)

;;; include/git2/diff.h
(defconstant +diff-format-patch+ 1)

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

;;; include/git2/buffer.h
(cffi:defcstruct git-buf
  (ptr :pointer)
  (reserved :size)
  (size :size))

;;; --- the library -------------------------------------------------------------------

(cffi:defcfun ("git_libgit2_init" %init) :int)
(cffi:defcfun ("git_libgit2_shutdown" %shutdown) :int)
(cffi:defcfun ("git_libgit2_version" %version) :int
  (major :pointer) (minor :pointer) (rev :pointer))
(cffi:defcfun ("git_libgit2_features" %features) :int)
(cffi:defcfun ("git_error_last" %error-last) :pointer)

;;; --- repositories and the index ----------------------------------------------------

(cffi:defcfun ("git_repository_init" %repository-init) :int
  (out :pointer) (path (:string :encoding :utf-8)) (is-bare :unsigned-int))
(cffi:defcfun ("git_repository_open" %repository-open) :int
  (out :pointer) (path (:string :encoding :utf-8)))
(cffi:defcfun ("git_repository_free" %repository-free) :void (repo :pointer))
(cffi:defcfun ("git_repository_workdir" %repository-workdir) :pointer (repo :pointer))
(cffi:defcfun ("git_repository_index" %repository-index) :int (out :pointer) (repo :pointer))

(cffi:defcfun ("git_index_add_bypath" %index-add-bypath) :int
  (index :pointer) (path (:string :encoding :utf-8)))
(cffi:defcfun ("git_index_remove_bypath" %index-remove-bypath) :int
  (index :pointer) (path (:string :encoding :utf-8)))
(cffi:defcfun ("git_index_write" %index-write) :int (index :pointer))
(cffi:defcfun ("git_index_write_tree" %index-write-tree) :int (out :pointer) (index :pointer))
(cffi:defcfun ("git_index_free" %index-free) :void (index :pointer))

;;; --- commits -----------------------------------------------------------------------

(cffi:defcfun ("git_signature_new" %signature-new) :int
  (out :pointer) (name (:string :encoding :utf-8)) (email (:string :encoding :utf-8))
  (time :int64) (offset :int))
(cffi:defcfun ("git_signature_free" %signature-free) :void (sig :pointer))

(cffi:defcfun ("git_reference_name_to_id" %reference-name-to-id) :int
  (out :pointer) (repo :pointer) (name (:string :encoding :utf-8)))

(cffi:defcfun ("git_commit_create" %commit-create) :int
  (id :pointer) (repo :pointer) (update-ref :pointer) (author :pointer) (committer :pointer)
  (message-encoding :pointer) (message (:string :encoding :utf-8)) (tree :pointer)
  (parent-count :size) (parents :pointer))
(cffi:defcfun ("git_commit_lookup" %commit-lookup) :int
  (out :pointer) (repo :pointer) (id :pointer))
(cffi:defcfun ("git_commit_free" %commit-free) :void (commit :pointer))
(cffi:defcfun ("git_commit_id" %commit-id) :pointer (commit :pointer))
(cffi:defcfun ("git_commit_message" %commit-message) :pointer (commit :pointer))
(cffi:defcfun ("git_commit_author" %commit-author) :pointer (commit :pointer))
(cffi:defcfun ("git_commit_tree" %commit-tree) :int (out :pointer) (commit :pointer))
(cffi:defcfun ("git_commit_parentcount" %commit-parentcount) :unsigned-int (commit :pointer))
(cffi:defcfun ("git_commit_parent" %commit-parent) :int
  (out :pointer) (commit :pointer) (n :unsigned-int))

;;; --- trees, blobs and objects ------------------------------------------------------

(cffi:defcfun ("git_tree_lookup" %tree-lookup) :int (out :pointer) (repo :pointer) (id :pointer))
(cffi:defcfun ("git_tree_free" %tree-free) :void (tree :pointer))
(cffi:defcfun ("git_tree_entry_bypath" %tree-entry-bypath) :int
  (out :pointer) (root :pointer) (path (:string :encoding :utf-8)))
(cffi:defcfun ("git_tree_entry_id" %tree-entry-id) :pointer (entry :pointer))
(cffi:defcfun ("git_tree_entry_free" %tree-entry-free) :void (entry :pointer))

(cffi:defcfun ("git_blob_lookup" %blob-lookup) :int (out :pointer) (repo :pointer) (id :pointer))
(cffi:defcfun ("git_blob_rawcontent" %blob-rawcontent) :pointer (blob :pointer))
(cffi:defcfun ("git_blob_rawsize" %blob-rawsize) :uint64 (blob :pointer))
(cffi:defcfun ("git_blob_free" %blob-free) :void (blob :pointer))

(cffi:defcfun ("git_revparse_single" %revparse-single) :int
  (out :pointer) (repo :pointer) (spec (:string :encoding :utf-8)))
(cffi:defcfun ("git_object_peel" %object-peel) :int
  (out :pointer) (object :pointer) (target-type :int))
(cffi:defcfun ("git_object_free" %object-free) :void (object :pointer))

;;; --- history and diffs -------------------------------------------------------------

(cffi:defcfun ("git_revwalk_new" %revwalk-new) :int (out :pointer) (repo :pointer))
(cffi:defcfun ("git_revwalk_sorting" %revwalk-sorting) :int (walk :pointer) (mode :unsigned-int))
(cffi:defcfun ("git_revwalk_push" %revwalk-push) :int (walk :pointer) (id :pointer))
(cffi:defcfun ("git_revwalk_next" %revwalk-next) :int (out :pointer) (walk :pointer))
(cffi:defcfun ("git_revwalk_free" %revwalk-free) :void (walk :pointer))

(cffi:defcfun ("git_diff_tree_to_tree" %diff-tree-to-tree) :int
  (out :pointer) (repo :pointer) (old-tree :pointer) (new-tree :pointer) (options :pointer))
(cffi:defcfun ("git_diff_to_buf" %diff-to-buf) :int
  (out :pointer) (diff :pointer) (format :int))
(cffi:defcfun ("git_diff_free" %diff-free) :void (diff :pointer))
(cffi:defcfun ("git_buf_dispose" %buf-dispose) :void (buf :pointer))
