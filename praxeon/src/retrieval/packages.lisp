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
                    (#:log #:aion/log)
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
   #:retrieve-whole #:corpus-size #:corpus-effective-strategy #:start-backfill #:corpora-table
   #:*whole-limit* #:corpus-strategy #:corpus-whole-limit #:corpus-expected-tokens
   #:corpus-contextualizer #:corpus-backfill #:sync-report-size #:sync-report-strategy
   #:passage-context
   ;; keyword retrieval, BM25 (#316)
   #:tokenize #:term-counts #:register-stop-words #:*stop-words* #:+tokenizer-id+
   #:terms-table #:index-pending #:retrieve-keyword #:*bm25-k1* #:*bm25-b* #:passage-score
   ;; conditions
   #:retrieval-error #:invalid-section #:invalid-section-section #:invalid-section-problem
   #:embedding-width-changed #:embedding-width-changed-table
   #:embedding-width-changed-stored #:embedding-width-changed-configured
   #:recreate-embedding-column))

;;; Reciprocal rank fusion, the typed and pure part of hybrid retrieval (#316).
(cl:defpackage #:praxeon/retrieval/fusion
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:list #:coalton-library/list))
  (:documentation "Reciprocal rank fusion of ranked lists of chunk ids (#316). Pure.")
  (:export #:fused-ids #:fused-scores #:rrf-score))

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
   #:retrieve-whole #:corpus-size #:corpus-effective-strategy #:start-backfill #:corpora-table
   #:*whole-limit* #:corpus-strategy #:corpus-whole-limit #:corpus-expected-tokens
   #:corpus-contextualizer #:corpus-backfill #:sync-report-size #:sync-report-strategy
   #:passage-context
   #:tokenize #:term-counts #:register-stop-words #:*stop-words* #:+tokenizer-id+
   #:terms-table #:index-pending #:retrieve-keyword #:*bm25-k1* #:*bm25-b* #:passage-score
   #:retrieval-error #:invalid-section #:invalid-section-section #:invalid-section-problem
   #:embedding-width-changed #:embedding-width-changed-table
   #:embedding-width-changed-stored #:embedding-width-changed-configured
   #:recreate-embedding-column)
  (:local-nicknames (#:rc #:praxeon/retrieval/corpus)
                    (#:fusion #:praxeon/retrieval/fusion)
                    (#:boundary #:aion/boundary)
                    (#:llm #:praxeon/llm)
                    (#:actor #:praxeon/actor)
                    (#:ceiling #:praxeon/ceiling)
                    (#:log #:aion/log)
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
   ;; hybrid retrieval and its evaluation (#316)
   #:retrieve-hybrid #:*hybrid-candidates* #:*rrf-k*
   #:eval-question #:make-eval-question #:eval-question-query #:eval-question-document-id
   #:eval-question-section-id #:evaluate-retrieval
   ;; a context for each chunk (#316)
   #:contextualizer #:make-contextualizer #:contextualizer-id #:contextualizer-provider
   #:contextualizer-instruction #:contextualizer-max-tokens #:*context-instruction*
   #:context-messages #:contextualize-pending
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
   #:retrieve-whole #:corpus-size #:corpus-effective-strategy #:start-backfill #:corpora-table
   #:*whole-limit* #:corpus-strategy #:corpus-whole-limit #:corpus-expected-tokens
   #:corpus-contextualizer #:corpus-backfill #:sync-report-size #:sync-report-strategy
   #:passage-context
   #:tokenize #:term-counts #:register-stop-words #:*stop-words* #:+tokenizer-id+
   #:terms-table #:index-pending #:retrieve-keyword #:*bm25-k1* #:*bm25-b* #:passage-score
   #:retrieval-error #:invalid-section #:invalid-section-section #:invalid-section-problem
   #:embedding-width-changed #:embedding-width-changed-table
   #:embedding-width-changed-stored #:embedding-width-changed-configured
   #:recreate-embedding-column))
