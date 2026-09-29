;;;; retrieval/packages.lisp --- the two packages of praxeon/retrieval (#138).
;;;;
;;;; PRAXEON/RETRIEVAL/CORPUS holds everything that needs no embedding provider: sections,
;;;; chunkers, the chunk store, corpora, sync, and exact retrieval. It has no nickname for
;;;; praxeon/llm, so nothing in it can embed. PRAXEON/RETRIEVAL adds embedding and similarity
;;;; retrieval, and imports and re-exports the corpus package's symbols, so an app uses that
;;;; one package.

(cl:defpackage #:praxeon/retrieval/corpus
  (:use #:cl)
  (:local-nicknames (#:q #:mnemosyne/query)
                    (#:conn #:mnemosyne/conn)
                    (#:param #:mnemosyne/param)
                    (#:schema #:mnemosyne/schema)
                    (#:ddl #:mnemosyne/ddl)
                    (#:der #:mnemosyne/derived)
                    (#:mig #:mnemosyne/migrate)
                    (#:ctx #:praxeon/context)
                    (#:bt #:bordeaux-threads))
  (:export
   ;; sections, as the app hands them in
   #:section #:make-section #:section-p #:section-id #:section-document-id
   #:section-document-version #:section-locator #:section-locale #:section-locale-role
   #:section-derived-from #:section-source-fingerprint #:section-text
   #:section-fingerprint
   ;; chunkers
   #:chunk #:make-chunk #:chunk-text #:chunk-sub-locator #:chunk-boundary
   #:chunk-section #:chunker-id #:section-chunker
   #:paragraph-chunker #:chunker-long-section #:chunker-target
   ;; the store and its corpora
   #:chunk-store #:make-chunk-store #:store-connection #:store-table #:store-dimensions
   #:ensure-schema #:check-vector-extension #:*table*
   #:corpus #:make-corpus #:corpus-name #:corpus-store #:corpus-chunker #:corpus-where
   #:with-corpus-lock #:call-with-corpus-lock
   ;; sync
   #:sync-document #:sync-corpus
   #:sync-report #:sync-report-added #:sync-report-replaced #:sync-report-updated
   #:sync-report-unchanged #:sync-report-removed
   ;; results
   #:passage #:passage-text #:passage-provenance #:passage-distance
   #:provenance #:provenance-corpus #:provenance-document-id #:provenance-document-version
   #:provenance-section-id #:provenance-locator #:provenance-sub-locator
   #:provenance-locale #:provenance-locale-role #:provenance-derived-from
   #:provenance-translation #:provenance-chunker #:provenance-boundary
   #:complete #:complete-p #:make-complete
   #:truncated #:truncated-p #:make-truncated #:truncated-reason #:truncated-pending
   #:retrieval-result #:retrieval-result-passages #:retrieval-result-completeness
   #:passage->ctx-item
   ;; exact retrieval
   #:retrieve-exact
   ;; conditions
   #:retrieval-error #:invalid-section #:invalid-section-section #:invalid-section-problem
   #:embedding-width-changed #:embedding-width-changed-table
   #:embedding-width-changed-stored #:embedding-width-changed-configured
   #:recreate-embedding-column))

(cl:defpackage #:praxeon/retrieval
  (:use #:cl)
  ;; Imported by name rather than :USE, so that a checker reading this package sees which
  ;; symbols come from where (scripts/check-source-deps.lisp).
  (:import-from #:praxeon/retrieval/corpus
   #:section #:make-section #:section-p #:section-id #:section-document-id
   #:section-document-version #:section-locator #:section-locale #:section-locale-role
   #:section-derived-from #:section-source-fingerprint #:section-text
   #:section-fingerprint
   #:chunk #:make-chunk #:chunk-text #:chunk-sub-locator #:chunk-boundary
   #:chunk-section #:chunker-id #:section-chunker
   #:paragraph-chunker #:chunker-long-section #:chunker-target
   #:chunk-store #:make-chunk-store #:store-connection #:store-table #:store-dimensions
   #:ensure-schema #:check-vector-extension #:*table*
   #:corpus #:make-corpus #:corpus-name #:corpus-store #:corpus-chunker #:corpus-where
   #:with-corpus-lock #:call-with-corpus-lock
   #:sync-document #:sync-corpus
   #:sync-report #:sync-report-added #:sync-report-replaced #:sync-report-updated
   #:sync-report-unchanged #:sync-report-removed
   #:passage #:passage-text #:passage-provenance #:passage-distance
   #:provenance #:provenance-corpus #:provenance-document-id #:provenance-document-version
   #:provenance-section-id #:provenance-locator #:provenance-sub-locator
   #:provenance-locale #:provenance-locale-role #:provenance-derived-from
   #:provenance-translation #:provenance-chunker #:provenance-boundary
   #:complete #:complete-p #:make-complete
   #:truncated #:truncated-p #:make-truncated #:truncated-reason #:truncated-pending
   #:retrieval-result #:retrieval-result-passages #:retrieval-result-completeness
   #:passage->ctx-item
   #:retrieve-exact
   #:retrieval-error #:invalid-section #:invalid-section-section #:invalid-section-problem
   #:embedding-width-changed #:embedding-width-changed-table
   #:embedding-width-changed-stored #:embedding-width-changed-configured
   #:recreate-embedding-column)
  (:local-nicknames (#:rc #:praxeon/retrieval/corpus)
                    (#:llm #:praxeon/llm)
                    (#:actor #:praxeon/actor)
                    (#:ctx #:praxeon/context)
                    (#:q #:mnemosyne/query)
                    (#:cs #:mnemosyne/changeset)
                    (#:conn #:mnemosyne/conn)
                    (#:param #:mnemosyne/param))
  (:documentation "Document retrieval over corpora of an app's sections (#138). Sync and exact
retrieval need no embedding provider; EMBED-PENDING and RETRIEVE-SIMILAR take one as an
argument.")
  (:export
   ;; embedding and similarity
   #:embed-pending #:ingest #:retrieve-similar #:deriver-of
   ;; the agent-facing search
   #:retrieve #:register-corpus-search #:*search-description*
   ;; re-exported from praxeon/retrieval/corpus
   #:section #:make-section #:section-p #:section-id #:section-document-id
   #:section-document-version #:section-locator #:section-locale #:section-locale-role
   #:section-derived-from #:section-source-fingerprint #:section-text
   #:section-fingerprint
   #:chunk #:make-chunk #:chunk-text #:chunk-sub-locator #:chunk-boundary
   #:chunk-section #:chunker-id #:section-chunker
   #:paragraph-chunker #:chunker-long-section #:chunker-target
   #:chunk-store #:make-chunk-store #:store-connection #:store-table #:store-dimensions
   #:ensure-schema #:check-vector-extension #:*table*
   #:corpus #:make-corpus #:corpus-name #:corpus-store #:corpus-chunker #:corpus-where
   #:with-corpus-lock #:call-with-corpus-lock
   #:sync-document #:sync-corpus
   #:sync-report #:sync-report-added #:sync-report-replaced #:sync-report-updated
   #:sync-report-unchanged #:sync-report-removed
   #:passage #:passage-text #:passage-provenance #:passage-distance
   #:provenance #:provenance-corpus #:provenance-document-id #:provenance-document-version
   #:provenance-section-id #:provenance-locator #:provenance-sub-locator
   #:provenance-locale #:provenance-locale-role #:provenance-derived-from
   #:provenance-translation #:provenance-chunker #:provenance-boundary
   #:complete #:complete-p #:make-complete
   #:truncated #:truncated-p #:make-truncated #:truncated-reason #:truncated-pending
   #:retrieval-result #:retrieval-result-passages #:retrieval-result-completeness
   #:passage->ctx-item
   #:retrieve-exact
   #:retrieval-error #:invalid-section #:invalid-section-section #:invalid-section-problem
   #:embedding-width-changed #:embedding-width-changed-table
   #:embedding-width-changed-stored #:embedding-width-changed-configured
   #:recreate-embedding-column))
