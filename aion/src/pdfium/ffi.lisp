;;;; ffi.lisp --- the pdfium functions aion/pdfium calls (#997).
;;;;
;;;; Bound with CFFI:DEFCFUN, which looks a function up when it is first called, never when
;;;; this file is loaded, so loading aion/pdfium does not need the library (LIBRARY.LISP loads
;;;; it on first use). Every name is recorded in *ENTRY-POINTS*, and LOAD-PDFIUM refuses a
;;;; library that does not define them all.
;;;;
;;;; The signatures are pdfium's public C API (fpdfview.h), as in the pinned release's
;;;; include/. FPDF_CALLCONV is the platform's C convention on 64-bit Windows, macOS and Linux.

(in-package #:aion/pdfium)

(defvar *entry-points* '()
  "The C names this file binds. LOAD-PDFIUM checks each resolves to the library it loaded.")

(defmacro %defpdf ((c-name lisp-name) return-type &body arguments)
  `(progn (pushnew ,c-name *entry-points* :test #'string=)
          (cffi:defcfun (,c-name ,lisp-name) ,return-type ,@arguments)))

(%defpdf ("FPDF_InitLibrary" %init-library) :void)
(%defpdf ("FPDF_DestroyLibrary" %destroy-library) :void)
(%defpdf ("FPDF_GetLastError" %last-error) :unsigned-long)
(%defpdf ("FPDF_LoadMemDocument64" %load-mem-document) :pointer
  (data :pointer) (size :size) (password :string))
(%defpdf ("FPDF_CloseDocument" %close-document) :void (document :pointer))
(%defpdf ("FPDF_GetPageCount" %page-count) :int (document :pointer))
(%defpdf ("FPDF_LoadPage" %load-page) :pointer (document :pointer) (index :int))
(%defpdf ("FPDF_ClosePage" %close-page) :void (page :pointer))
(%defpdf ("FPDF_GetPageWidthF" %page-width) :float (page :pointer))
(%defpdf ("FPDF_GetPageHeightF" %page-height) :float (page :pointer))
(%defpdf ("FPDFBitmap_CreateEx" %bitmap-create) :pointer
  (width :int) (height :int) (format :int) (first-scan :pointer) (stride :int))
(%defpdf ("FPDFBitmap_FillRect" %bitmap-fill-rect) :int
  (bitmap :pointer) (left :int) (top :int) (width :int) (height :int) (color :unsigned-long))
(%defpdf ("FPDF_RenderPageBitmap" %render-page-bitmap) :void
  (bitmap :pointer) (page :pointer) (start-x :int) (start-y :int) (size-x :int) (size-y :int)
  (rotate :int) (flags :int))
(%defpdf ("FPDFBitmap_GetBuffer" %bitmap-buffer) :pointer (bitmap :pointer))
(%defpdf ("FPDFBitmap_GetStride" %bitmap-stride) :int (bitmap :pointer))
(%defpdf ("FPDFBitmap_Destroy" %bitmap-destroy) :void (bitmap :pointer))

(defconstant +bitmap-gray+ 1 "FPDFBitmap_Gray: one byte per pixel.")
(defconstant +bitmap-bgra+ 4 "FPDFBitmap_BGRA: four bytes per pixel, blue first.")
(defconstant +render-annotations+ #x01 "FPDF_ANNOT: draw the page's annotations too.")

(defparameter +errors+
  '((1 . :unknown) (2 . :file) (3 . :format) (4 . :password) (5 . :security) (6 . :page))
  "FPDF_GetLastError's codes (FPDF_ERR_*), as the reasons PDF-REFUSED gives.")
