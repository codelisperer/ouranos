;;;; packages.lisp --- aion/pdfium: render a PDF page to an image (#997).

(defpackage #:aion/pdfium
  (:use #:cl)
  (:documentation
   "Open a PDF, count its pages, and render a page to a PNG at a given DPI, through pdfium, a
    native library this tree fetches pinned (scripts/fetch-pdfium.lisp). Optional: core aion
    never loads it, and the library is loaded on first use, not when the system is.")
  (:export
   ;; documents
   #:open-pdf #:close-pdf #:with-pdf #:pdf-document #:page-count #:render-page
   ;; limits
   #:*max-pdf-bytes* #:*max-pdf-pages* #:*max-render-pixels*
   ;; conditions
   #:pdf-refused #:pdf-refused-reason #:pdf-refused-detail
   #:pdfium-not-found #:pdfium-not-found-searched #:pdfium-not-found-reason
   #:pdfium-mismatch #:pdfium-mismatch-path #:pdfium-mismatch-reason
   ;; the library
   #:load-pdfium #:unload-pdfium #:pdfium-loaded-p #:pdfium-path #:ensure-loaded
   #:*library-names* #:*path*))
