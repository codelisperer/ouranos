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
   ;; files
   #:create-file-w #:+generic-read+ #:+generic-write+ #:+open-always+
   #:+file-attribute-normal+ #:+error-sharing-violation+
   ;; the layout table
   #:*layouts* #:register-layout #:verify-layouts #:layout-report
   #:pointer-width #:layout-column #:layout-mismatch #:layout-mismatch-details
   ;; structs the foundation owns (IID/CLSID are typedefs of GUID)
   #:filetime #:guid
   ;; certificate chains (#536)
   #:cert-enhkey-usage #:c-usage-identifier #:rgpsz-usage-identifier
   #:cert-usage-match #:dw-type #:usage
   #:cert-chain-para #:cb-size #:requested-usage
   #:ssl-extra-cert-chain-policy-para #:dw-auth-type #:fdw-checks #:pwsz-server-name
   #:cert-chain-policy-para #:pv-extra-policy-para   ; dw-flags is exported with startupinfo-w
   #:cert-chain-policy-status #:dw-error #:l-chain-index #:l-element-index
   #:pv-extra-policy-status
   #:+x509-asn-encoding+ #:+cert-store-prov-memory+ #:+cert-store-add-always+
   #:+cert-chain-policy-ssl+ #:+authtype-server+ #:+usage-match-type-and+
   #:cert-create-certificate-context #:cert-free-certificate-context #:cert-open-store
   #:cert-add-encoded-certificate-to-store #:cert-close-store #:cert-get-certificate-chain
   #:cert-free-certificate-chain #:cert-verify-certificate-chain-policy
   ;; Credential Manager (#357)
   #:credential-w #:flags #:target-name #:comment #:last-written
   #:credential-blob-size #:credential-blob #:persist #:attribute-count #:attributes
   #:target-alias #:user-name
   #:cred-write-w #:cred-read-w #:cred-delete-w #:cred-free
   #:+cred-type-generic+ #:+cred-persist-local-machine+ #:+cred-max-credential-blob-size+
   #:+error-not-found+
   ;; job objects (#599)
   #:jobobject-basic-limit-information #:io-counters #:jobobject-extended-limit-information
   #:limit-flags #:basic-limit-information
   #:create-job-object-w #:open-process #:set-information-job-object
   #:assign-process-to-job-object #:terminate-job-object
   #:+job-object-extended-limit-information+ #:+job-object-limit-kill-on-job-close+
   #:+process-terminate+ #:+process-set-quota+
   ;; starting a process (#700)
   #:security-attributes #:n-length #:lp-security-descriptor #:b-inherit-handle
   #:startupinfo-w #:cb #:dw-flags #:h-std-input #:h-std-output #:h-std-error
   #:startupinfoex-w #:startup-info #:lp-attribute-list
   #:process-information #:h-process #:h-thread #:dw-process-id #:dw-thread-id
   #:set-handle-information #:initialize-proc-thread-attribute-list
   #:update-proc-thread-attribute #:delete-proc-thread-attribute-list
   #:create-process-w #:resume-thread #:terminate-process #:wait-for-single-object
   #:get-exit-code-process
   #:+create-suspended+ #:+create-unicode-environment+ #:+extended-startupinfo-present+
   #:+create-no-window+ #:+startf-usestdhandles+ #:+handle-flag-inherit+
   #:+proc-thread-attribute-handle-list+ #:+file-append-data+ #:+file-share-read+
   #:+file-share-write+ #:+wait-object-0+ #:+wait-timeout+ #:+infinite+ #:+still-active+
   ;; a message box before any window exists (#819)
   #:message-box-w #:get-current-process-id #:process-id-to-session-id
   #:+mb-ok+ #:+mb-iconerror+ #:+mb-iconwarning+ #:+mb-iconinformation+
   #:+mb-setforeground+ #:+mb-topmost+
   ;; the Windows directory, and opening a URL with its registered program (#820)
   #:get-system-windows-directory-w #:shell-execute-w #:+sw-shownormal+
   #:co-initialize-ex #:co-uninitialize
   #:+coinit-apartmentthreaded+ #:+coinit-disable-ole1dde+))

(cl:defpackage #:aion/windows
  (:use #:common-lisp)
  ;; Re-exported from aion/fs, which holds the one GetFileAttributesW binding (#349).
  (:import-from #:aion/fs #:file-attributes #:file-attributes-error #:file-attributes-error-code)
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
   #:handle-valid-p #:close-handle #:with-handle
   ;; job objects (#599)
   #:make-kill-on-close-job #:assign-process-to-job #:terminate-job
   ;; starting a process in a job, with no console window (#700)
   #:spawn-in-job #:default-job-function #:find-executable
   ;; the Windows directory, and opening a URL with its registered program (#820)
   #:system-windows-directory #:shell-open
   ;; a TLS server's certificate chain, judged by Windows (#536)
   #:verify-server-certificate-chain
   #:quote-windows-argument #:windows-command-line
   #:process-not-started #:process-not-started-program #:process-not-started-reason
   #:job-process #:job-process-p #:job-process-pid #:job-process-job
   #:job-process-input #:job-process-output #:job-process-error
   #:job-process-alive-p #:job-process-exit-code #:job-process-status #:job-process-wait
   #:job-process-terminate #:job-process-close
   ;; file attributes, from aion/fs
   #:file-attributes #:file-attributes-error #:file-attributes-error-code))
