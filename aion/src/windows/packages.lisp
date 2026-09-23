;;;; packages.lisp --- aion/windows: the Windows-specific API surface, bound by us.
;;;;
;;;; Charter: aion/docs/adr/0003-windows-platform-binding.md. This system is the FOUNDATION
;;;; -- what every Windows API needs and what is most expensive to get wrong: UTF-16
;;;; marshalling, GetLastError/HRESULT decoded into conditions, handle lifetime, and the
;;;; struct-layout table asserted at load. Subsystems (com, service, registry, security,
;;;; shell) sit on top, each opt-in, exactly the aion/uv -> aion/uv/net pattern.
;;;;
;;;; TWO PACKAGES, the same split aion/uv uses:
;;;;
;;;;   AION/WINDOWS/FFI  the raw layer -- defcfun, defcstruct, constants. Windows spellings
;;;;                     survive here (LPWSTR, HRESULT, dwFlags) so a reader can search
;;;;                     MSDN for the identifier in front of them.
;;;;   AION/WINDOWS      the Lisp surface -- conditions, wide strings, handles. Windows
;;;;                     naming stops at this boundary.
;;;;
;;;; PLATFORM-EXCLUSIVE, which is a new category for this tree (ADR-0003 Consequences).
;;;; aion/uv is opt-in but cross-platform; this cannot load off-platform at all, and
;;;; scripts/platform-packages.lisp is what makes its absence mean one thing on Windows and
;;;; a different thing everywhere else (pre-publication issue 182).
;;;;
;;;; NO C TOOLCHAIN, EVER (ADR-0003 s8). kernel32, ole32, oleaut32 ship with the OS, so
;;;; unlike aion/uv there is nothing to build and no vendor/ step. That is also why this is
;;;; a :required platform package rather than an opt-in one: deferring it buys nothing.
;;;;
;;;; NO NEW TREE DEPENDENCY. cffi is already declared for aion/uv. Threads come from
;;;; sb-thread rather than bordeaux-threads: the tree is SBCL-exclusive by design, this
;;;; system is Windows-exclusive on top of that, and a portability shim over threads buys
;;;; nothing a system that runs on exactly one implementation and one OS can spend.

(cl:defpackage #:aion/windows/ffi
  (:use #:common-lisp)
  (:documentation "Raw Windows FFI. Windows spellings kept deliberately.")
  (:export
   ;; libraries
   #:load-windows-libraries #:library-available-p
   ;; primitive types
   #:hresult #:hmodule #:hwnd #:dword #:word #:wide-char
   ;; errors
   #:get-last-error #:format-message-w
   #:+format-message-from-system+ #:+format-message-ignore-inserts+
   #:+format-message-allocate-buffer+
   ;; memory
   #:local-free #:co-task-mem-free
   ;; the layout table
   #:*layouts* #:register-layout #:verify-layouts #:layout-report
   #:pointer-width #:layout-column #:layout-mismatch #:layout-mismatch-details
   ;; structs the foundation owns (IID/CLSID are typedefs of GUID)
   #:filetime #:guid))

(cl:defpackage #:aion/windows
  (:use #:common-lisp)
  (:local-nicknames (#:ffi #:aion/windows/ffi))
  (:documentation "The Windows-specific API surface for Ouranos.")
  (:export
   ;; platform
   #:windows-p #:check-windows
   ;; conditions
   #:windows-error #:windows-error-code #:windows-error-message
   #:windows-error-operation
   #:win32-error #:hresult-error #:hresult-error-hresult
   #:not-implemented #:access-denied #:invalid-argument #:out-of-memory
   #:unsupported-platform
   ;; last-error / hresult plumbing
   #:last-error #:error-message-for #:check-win32 #:check-hresult #:hresult-succeeded-p
   ;; wide strings
   #:with-wide-string #:wide-string-to-lisp #:lisp-to-wide-string #:free-wide-string
   ;; handles
   #:handle #:handle-p #:wrap-handle #:handle-pointer #:handle-kind
   #:handle-valid-p #:close-handle #:with-handle))
