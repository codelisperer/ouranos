;;;; ffi.lisp --- the raw layer. Windows spellings survive here on purpose.
;;;;
;;;; A reader with an MSDN page open should be able to search for the identifier in front of
;;;; them, so LPWSTR, dwFlags and HRESULT are not renamed to something more Lispy until they
;;;; cross into AION/WINDOWS. Same rule aion/uv/ffi follows.
;;;;
;;;; TYPES. Windows' typedef zoo reduces to very little once the aliases are unwound:
;;;;   DWORD    32-bit unsigned          HRESULT  32-bit SIGNED (the sign bit is the
;;;;   WORD     16-bit unsigned                   failure flag, so it must not be unsigned)
;;;;   BOOL     32-bit signed int        HANDLE   pointer-width opaque
;;;;   LPWSTR   pointer to UTF-16LE      WCHAR    16-bit code unit
;;;;
;;;; HRESULT being signed is not a detail. `FAILED(hr)' is `hr < 0', and reading it as
;;;; unsigned turns every failure into a large positive number that tests as success.

(in-package #:aion/windows/ffi)

;;; --- primitive types --------------------------------------------------------

(cffi:defctype dword :uint32)
(cffi:defctype word :uint16)
(cffi:defctype wide-char :uint16)
(cffi:defctype hresult :int32)          ; SIGNED -- see the header note
(cffi:defctype hmodule :pointer)
(cffi:defctype hwnd :pointer)

;;; --- structs, declared structurally so the layout check has teeth -----------
;;;
;;; See layout.lisp's "tautology trap" note: these are declared by their real members, and
;;; the documented sizes below were arrived at independently from Microsoft's documentation.
;;; CFFI computing the same number from the member list is the check.

(cffi:defcstruct filetime
  (low-date-time  dword)
  (high-date-time dword))

(register-layout
 :name "FILETIME"
 :type '(:struct filetime)
 ;; Two DWORDs, no padding, identical on both widths.
 :size '(:x86 8 :x64 8)
 :slots '((low-date-time  :offset (:x86 0 :x64 0))
          (high-date-time :offset (:x86 4 :x64 4)))
 :source "MSDN FILETIME (minwinbase.h)")

(cffi:defcstruct guid
  (data1 dword)
  (data2 word)
  (data3 word)
  (data4 :uint8 :count 8))

(register-layout
 :name "GUID"
 :type '(:struct guid)
 ;; 16 bytes on both widths: 4 + 2 + 2 + 8, alignment 4, no tail padding.
 :size '(:x86 16 :x64 16)
 :slots '((data1 :offset (:x86 0 :x64 0))
          (data2 :offset (:x86 4 :x64 4))
          (data3 :offset (:x86 6 :x64 6))
          (data4 :offset (:x86 8 :x64 8)))
 :source "MSDN GUID (guiddef.h); IID and CLSID are typedefs of it")

;;; --- errors -----------------------------------------------------------------

(defconstant +format-message-allocate-buffer+ #x00000100)
(defconstant +format-message-ignore-inserts+  #x00000200)
(defconstant +format-message-from-system+     #x00001000)

(cffi:defcfun ("GetLastError" get-last-error) dword)

;;; FormatMessageW with ALLOCATE_BUFFER treats lpBuffer as an LPWSTR* -- Windows allocates
;;; and we LocalFree. Declared :pointer for that reason; passing a plain buffer here is a
;;; classic way to corrupt the stack.
(cffi:defcfun ("FormatMessageW" format-message-w) dword
  (dw-flags dword)
  (lp-source :pointer)
  (dw-message-id dword)
  (dw-language-id dword)
  (lp-buffer :pointer)
  (n-size dword)
  (arguments :pointer))

(cffi:defcfun ("LocalFree" local-free) :pointer
  (h-mem :pointer))

(cffi:defcfun ("CoTaskMemFree" co-task-mem-free) :void
  (pv :pointer))

;;; --- handles ----------------------------------------------------------------

(cffi:defcfun ("CloseHandle" %close-handle) :int32
  (h-object :pointer))

;;; --- files ------------------------------------------------------------------
;;;
;;; CreateFileW, for a caller that needs what CL:OPEN does not offer: a share mode. SBCL opens
;;; files so that other processes may read and write them too. A share mode of 0 makes the open
;;; handle exclusive, so a second CreateFileW on the same file, from any process, fails with
;;; ERROR_SHARING_VIOLATION until the handle is closed, and Windows closes it when the process
;;; ends. hades/single-instance is built on that.
;;;
;;; The failure return is INVALID_HANDLE_VALUE, (HANDLE)-1, not NULL; AION/WINDOWS:WRAP-HANDLE
;;; and HANDLE-VALID-P treat both as invalid. A NULL security-attributes pointer makes the
;;; handle non-inheritable, so a child process does not keep the file open.

(defconstant +generic-read+ #x80000000)
(defconstant +generic-write+ #x40000000)
(defconstant +open-always+ 4)
(defconstant +file-attribute-normal+ #x80)
(defconstant +error-sharing-violation+ 32)

(cffi:defcfun ("CreateFileW" create-file-w) :pointer
  (lp-file-name :pointer)
  (dw-desired-access dword)
  (dw-share-mode dword)
  (lp-security-attributes :pointer)
  (dw-creation-disposition dword)
  (dw-flags-and-attributes dword)
  (h-template-file :pointer))

;;; --- Credential Manager (#357) --------------------------------------------------
;;;
;;; A generic credential: a blob of up to CRED_MAX_CREDENTIAL_BLOB_SIZE bytes stored under a
;;; target name, protected per user by DPAPI. CredReadW allocates the CREDENTIALW it returns,
;;; and the caller frees it with CredFree, which is why that is bound too.

(defconstant +cred-type-generic+ 1)
(defconstant +cred-persist-local-machine+ 2)  ; this user, this machine, across logons
(defconstant +cred-max-credential-blob-size+ 2560)  ; 5 * 512 bytes
(defconstant +error-not-found+ 1168)

(cffi:defcstruct credential-w
  (flags dword)
  (type dword)
  (target-name :pointer)
  (comment :pointer)
  (last-written (:struct filetime))
  (credential-blob-size dword)
  (credential-blob :pointer)
  (persist dword)
  (attribute-count dword)
  (attributes :pointer)
  (target-alias :pointer)
  (user-name :pointer))

(register-layout
 :name "CREDENTIALW"
 :type '(:struct credential-w)
 ;; x64: two DWORDs, then pointers at 8 and 16, FILETIME at 24, the blob size at 32 and
 ;; four bytes of padding so the blob pointer is aligned at 40; then two DWORDs at 48 and
 ;; 52 and three pointers at 56, 64 and 72. 80 bytes. x86: every pointer is 4 bytes, so
 ;; nothing pads and the struct is 52 bytes.
 :size '(:x86 52 :x64 80)
 :slots '((flags                :offset (:x86 0  :x64 0))
          (type                 :offset (:x86 4  :x64 4))
          (target-name          :offset (:x86 8  :x64 8))
          (comment              :offset (:x86 12 :x64 16))
          (last-written         :offset (:x86 16 :x64 24))
          (credential-blob-size :offset (:x86 24 :x64 32))
          (credential-blob      :offset (:x86 28 :x64 40))
          (persist              :offset (:x86 32 :x64 48))
          (attribute-count      :offset (:x86 36 :x64 52))
          (attributes           :offset (:x86 40 :x64 56))
          (target-alias         :offset (:x86 44 :x64 64))
          (user-name            :offset (:x86 48 :x64 72)))
 :source "MSDN CREDENTIALW (wincred.h)")

(cffi:defcfun ("CredWriteW" cred-write-w) :int32
  (credential :pointer)
  (flags dword))

(cffi:defcfun ("CredReadW" cred-read-w) :int32
  (target-name :pointer)
  (type dword)
  (flags dword)
  (credential :pointer))                ; PCREDENTIALW* -- Windows allocates

(cffi:defcfun ("CredDeleteW" cred-delete-w) :int32
  (target-name :pointer)
  (type dword)
  (flags dword))

(cffi:defcfun ("CredFree" cred-free) :void
  (buffer :pointer))

;;; --- job objects (#599) -----------------------------------------------------
;;;
;;; A job object groups processes so they can be ended together. With
;;; JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE set, Windows ends every process in the job when the last
;;; handle to the job is closed, which includes the case where the process holding that handle
;;; exits or is killed. A process started by a process in the job is in the job too, so the
;;; whole tree is ended. praxeon/mcp puts each local MCP server in one.
;;;
;;; The limit flags are set through JOBOBJECT_EXTENDED_LIMIT_INFORMATION, because
;;; KILL_ON_JOB_CLOSE is one of the flags the basic structure alone does not accept.

(defconstant +job-object-extended-limit-information+ 9)  ; JOBOBJECTINFOCLASS
(defconstant +job-object-limit-kill-on-job-close+ #x2000)
(defconstant +process-terminate+ #x0001)
(defconstant +process-set-quota+ #x0100)

(cffi:defcstruct jobobject-basic-limit-information
  (per-process-user-time-limit :int64)  ; LARGE_INTEGER
  (per-job-user-time-limit :int64)
  (limit-flags dword)
  (minimum-working-set-size :size)      ; SIZE_T
  (maximum-working-set-size :size)
  (active-process-limit dword)
  (affinity :uintptr)                   ; ULONG_PTR
  (priority-class dword)
  (scheduling-class dword))

(register-layout
 :name "JOBOBJECT_BASIC_LIMIT_INFORMATION"
 :type '(:struct jobobject-basic-limit-information)
 ;; x64: two 8-byte LARGE_INTEGERs, the flags at 16 and 4 bytes of padding so the SIZE_Ts sit
 ;; at 24 and 32; the process limit at 40 and 4 bytes of padding so the ULONG_PTR sits at 48;
 ;; two DWORDs at 56 and 60. 64 bytes. x86: SIZE_T and ULONG_PTR are 4 bytes, so nothing pads
 ;; until the end, where 44 rounds up to 48 for the 8-byte alignment of LARGE_INTEGER.
 :size '(:x86 48 :x64 64)
 :slots '((per-process-user-time-limit :offset (:x86 0  :x64 0))
          (per-job-user-time-limit     :offset (:x86 8  :x64 8))
          (limit-flags                 :offset (:x86 16 :x64 16))
          (minimum-working-set-size    :offset (:x86 20 :x64 24))
          (maximum-working-set-size    :offset (:x86 24 :x64 32))
          (active-process-limit        :offset (:x86 28 :x64 40))
          (affinity                    :offset (:x86 32 :x64 48))
          (priority-class              :offset (:x86 36 :x64 56))
          (scheduling-class            :offset (:x86 40 :x64 60)))
 :source "MSDN JOBOBJECT_BASIC_LIMIT_INFORMATION (winnt.h)")

(cffi:defcstruct io-counters
  (read-operation-count :uint64)
  (write-operation-count :uint64)
  (other-operation-count :uint64)
  (read-transfer-count :uint64)
  (write-transfer-count :uint64)
  (other-transfer-count :uint64))

(register-layout
 :name "IO_COUNTERS"
 :type '(:struct io-counters)
 ;; Six ULONGLONGs, identical on both widths.
 :size '(:x86 48 :x64 48)
 :slots '((read-operation-count :offset (:x86 0  :x64 0))
          (other-transfer-count :offset (:x86 40 :x64 40)))
 :source "MSDN IO_COUNTERS (winnt.h)")

(cffi:defcstruct jobobject-extended-limit-information
  (basic-limit-information (:struct jobobject-basic-limit-information))
  (io-info (:struct io-counters))
  (process-memory-limit :size)
  (job-memory-limit :size)
  (peak-process-memory-used :size)
  (peak-job-memory-used :size))

(register-layout
 :name "JOBOBJECT_EXTENDED_LIMIT_INFORMATION"
 :type '(:struct jobobject-extended-limit-information)
 ;; The basic structure, then IO_COUNTERS, then four SIZE_Ts: 64 + 48 + 32 = 144 on x64, and
 ;; 48 + 48 + 16 = 112 on x86.
 :size '(:x86 112 :x64 144)
 :slots '((basic-limit-information  :offset (:x86 0   :x64 0))
          (io-info                  :offset (:x86 48  :x64 64))
          (process-memory-limit     :offset (:x86 96  :x64 112))
          (job-memory-limit         :offset (:x86 100 :x64 120))
          (peak-process-memory-used :offset (:x86 104 :x64 128))
          (peak-job-memory-used     :offset (:x86 108 :x64 136)))
 :source "MSDN JOBOBJECT_EXTENDED_LIMIT_INFORMATION (winnt.h)")

;;; Both return NULL on failure, not INVALID_HANDLE_VALUE.
(cffi:defcfun ("CreateJobObjectW" create-job-object-w) :pointer
  (lp-job-attributes :pointer)
  (lp-name :pointer))

(cffi:defcfun ("OpenProcess" open-process) :pointer
  (dw-desired-access dword)
  (b-inherit-handle :int32)
  (dw-process-id dword))

(cffi:defcfun ("SetInformationJobObject" set-information-job-object) :int32
  (h-job :pointer)
  (job-object-information-class :int32)
  (lp-job-object-information :pointer)
  (cb-job-object-information-length dword))

(cffi:defcfun ("AssignProcessToJobObject" assign-process-to-job-object) :int32
  (h-job :pointer)
  (h-process :pointer))

(cffi:defcfun ("TerminateJobObject" terminate-job-object) :int32
  (h-job :pointer)
  (u-exit-code :uint32))

;;; --- starting a process (#700) ------------------------------------------------
;;;
;;; CreateProcessW, for what SB-EXT:RUN-PROGRAM cannot pass: CREATE_SUSPENDED, so a process is
;;; put in its job before it runs and every process it starts is in the job too, and
;;; CREATE_NO_WINDOW, so a console program started from a GUI image opens no console window.
;;;
;;; The handles the child inherits are named in a PROC_THREAD_ATTRIBUTE_HANDLE_LIST, passed in a
;;; STARTUPINFOEXW. Without the list the child inherits every inheritable handle in this image,
;;; including the pipe ends of another child started at the same moment, and a pipe end held by
;;; the wrong process keeps that pipe open after its own child has exited.

(defconstant +create-suspended+ #x00000004)
(defconstant +create-unicode-environment+ #x00000400)
(defconstant +extended-startupinfo-present+ #x00080000)
(defconstant +create-no-window+ #x08000000)
(defconstant +startf-usestdhandles+ #x00000100)
(defconstant +handle-flag-inherit+ #x00000001)
(defconstant +proc-thread-attribute-handle-list+ #x00020002)
(defconstant +file-append-data+ #x0004)
(defconstant +file-share-read+ #x1)
(defconstant +file-share-write+ #x2)
(defconstant +wait-object-0+ 0)
(defconstant +wait-timeout+ #x102)
(defconstant +infinite+ #xFFFFFFFF)
(defconstant +still-active+ 259)

(cffi:defcstruct security-attributes
  (n-length dword)
  (lp-security-descriptor :pointer)
  (b-inherit-handle :int32))

(register-layout
 :name "SECURITY_ATTRIBUTES"
 :type '(:struct security-attributes)
 ;; x64: the DWORD at 0 and 4 bytes of padding, the pointer at 8, the BOOL at 16, padded to 24.
 ;; x86: three 4-byte members, 12.
 :size '(:x86 12 :x64 24)
 :slots '((n-length               :offset (:x86 0 :x64 0))
          (lp-security-descriptor :offset (:x86 4 :x64 8))
          (b-inherit-handle       :offset (:x86 8 :x64 16)))
 :source "MSDN SECURITY_ATTRIBUTES (minwinbase.h)")

(cffi:defcstruct startupinfo-w
  (cb dword)
  (lp-reserved :pointer)
  (lp-desktop :pointer)
  (lp-title :pointer)
  (dw-x dword)
  (dw-y dword)
  (dw-x-size dword)
  (dw-y-size dword)
  (dw-x-count-chars dword)
  (dw-y-count-chars dword)
  (dw-fill-attribute dword)
  (dw-flags dword)
  (w-show-window word)
  (cb-reserved2 word)
  (lp-reserved2 :pointer)
  (h-std-input :pointer)
  (h-std-output :pointer)
  (h-std-error :pointer))

(register-layout
 :name "STARTUPINFOW"
 :type '(:struct startupinfo-w)
 ;; x64: cb, 4 bytes of padding, three pointers at 8, 16 and 24, eight DWORDs from 32 to 60, two
 ;; WORDs at 64 and 66, 4 bytes of padding, then four pointers at 72, 80, 88 and 96. 104 bytes.
 ;; x86: every pointer is 4 bytes and nothing pads. 68 bytes.
 :size '(:x86 68 :x64 104)
 :slots '((cb           :offset (:x86 0  :x64 0))
          (lp-reserved  :offset (:x86 4  :x64 8))
          (dw-flags     :offset (:x86 44 :x64 60))
          (w-show-window :offset (:x86 48 :x64 64))
          (lp-reserved2 :offset (:x86 52 :x64 72))
          (h-std-input  :offset (:x86 56 :x64 80))
          (h-std-output :offset (:x86 60 :x64 88))
          (h-std-error  :offset (:x86 64 :x64 96)))
 :source "MSDN STARTUPINFOW (processthreadsapi.h)")

(cffi:defcstruct startupinfoex-w
  (startup-info (:struct startupinfo-w))
  (lp-attribute-list :pointer))

(register-layout
 :name "STARTUPINFOEXW"
 :type '(:struct startupinfoex-w)
 ;; STARTUPINFOW and one pointer: 104 + 8 and 68 + 4.
 :size '(:x86 72 :x64 112)
 :slots '((startup-info      :offset (:x86 0  :x64 0))
          (lp-attribute-list :offset (:x86 68 :x64 104)))
 :source "MSDN STARTUPINFOEXW (winbase.h)")

(cffi:defcstruct process-information
  (h-process :pointer)
  (h-thread :pointer)
  (dw-process-id dword)
  (dw-thread-id dword))

(register-layout
 :name "PROCESS_INFORMATION"
 :type '(:struct process-information)
 ;; Two handles, then two DWORDs: 8 + 8 + 4 + 4 on x64, 16 bytes on x86.
 :size '(:x86 16 :x64 24)
 :slots '((h-process     :offset (:x86 0  :x64 0))
          (h-thread      :offset (:x86 4  :x64 8))
          (dw-process-id :offset (:x86 8  :x64 16))
          (dw-thread-id  :offset (:x86 12 :x64 20)))
 :source "MSDN PROCESS_INFORMATION (processthreadsapi.h)")

(cffi:defcfun ("SetHandleInformation" set-handle-information) :int32
  (h-object :pointer)
  (dw-mask dword)
  (dw-flags dword))

;;; Called twice: once with a NULL list to learn the size, which fails with
;;; ERROR_INSUFFICIENT_BUFFER by design, then with a buffer of that size.
(cffi:defcfun ("InitializeProcThreadAttributeList" initialize-proc-thread-attribute-list) :int32
  (lp-attribute-list :pointer)
  (dw-attribute-count dword)
  (dw-flags dword)
  (lp-size :pointer))                   ; PSIZE_T

(cffi:defcfun ("UpdateProcThreadAttribute" update-proc-thread-attribute) :int32
  (lp-attribute-list :pointer)
  (dw-flags dword)
  (attribute :uintptr)                  ; DWORD_PTR
  (lp-value :pointer)
  (cb-size :size)
  (lp-previous-value :pointer)
  (lp-return-size :pointer))

(cffi:defcfun ("DeleteProcThreadAttributeList" delete-proc-thread-attribute-list) :void
  (lp-attribute-list :pointer))

(cffi:defcfun ("CreateProcessW" create-process-w) :int32
  (lp-application-name :pointer)
  (lp-command-line :pointer)            ; must be writable: CreateProcessW may modify it
  (lp-process-attributes :pointer)
  (lp-thread-attributes :pointer)
  (b-inherit-handles :int32)
  (dw-creation-flags dword)
  (lp-environment :pointer)
  (lp-current-directory :pointer)
  (lp-startup-info :pointer)
  (lp-process-information :pointer))

;;; Returns the thread's previous suspend count, or (DWORD)-1 on failure.
(cffi:defcfun ("ResumeThread" resume-thread) dword
  (h-thread :pointer))

(cffi:defcfun ("TerminateProcess" terminate-process) :int32
  (h-process :pointer)
  (u-exit-code :uint32))

(cffi:defcfun ("WaitForSingleObject" wait-for-single-object) dword
  (h-handle :pointer)
  (dw-milliseconds dword))

(cffi:defcfun ("GetExitCodeProcess" get-exit-code-process) :int32
  (h-process :pointer)
  (lp-exit-code :pointer))

;;; --- a message box before any window exists (#819) --------------------------
;;;
;;; hades/notify shows a modal notice with MessageBoxW. Session 0 is where services run and
;;; has no desktop a user can see, so a message box there waits for a click that cannot
;;; happen; hades/notify asks ProcessIdToSessionId first.

(defconstant +mb-ok+ #x00000000)
(defconstant +mb-iconerror+ #x00000010)
(defconstant +mb-iconwarning+ #x00000030)
(defconstant +mb-iconinformation+ #x00000040)
(defconstant +mb-setforeground+ #x00010000)
(defconstant +mb-topmost+ #x00040000)

;;; Returns the button pressed (IDOK = 1 here), or 0 on failure.
(cffi:defcfun ("MessageBoxW" message-box-w) :int32
  (h-wnd hwnd)
  (lp-text :pointer)
  (lp-caption :pointer)
  (u-type :uint32))

(cffi:defcfun ("GetCurrentProcessId" get-current-process-id) dword)

(cffi:defcfun ("ProcessIdToSessionId" process-id-to-session-id) :int32
  (dw-process-id dword)
  (p-session-id :pointer))

;;; --- the Windows directory, and opening a URL with its registered program (#820) --------
;;;
;;; hades/open runs explorer.exe from the Windows directory, and opens a browser with
;;; ShellExecuteW. GetSystemWindowsDirectoryW and not GetWindowsDirectoryW: on a terminal
;;; server, GetWindowsDirectoryW can return a per-user directory, and explorer.exe is not in it.
;;; ShellExecuteW may start a shell extension through COM, which is why ole32's CoInitializeEx is
;;; bound here as well as in aion/windows/com: SHELL-OPEN calls it on a thread of its own.

;;; Returns the length written, without the terminating NUL; when the buffer is too small, the
;;; size needed, with it; 0 on failure.
(cffi:defcfun ("GetSystemWindowsDirectoryW" get-system-windows-directory-w) :uint32
  (lp-buffer :pointer)
  (u-size :uint32))

(defconstant +sw-shownormal+ 1)

;;; Returns an HINSTANCE that is not a handle: a value above 32 means success, and 32 or below
;;; is an error code (SE_ERR_*).
(cffi:defcfun ("ShellExecuteW" shell-execute-w) :pointer
  (h-wnd hwnd)
  (lp-operation :pointer)
  (lp-file :pointer)
  (lp-parameters :pointer)
  (lp-directory :pointer)
  (n-show-cmd :int32))

(defconstant +coinit-apartmentthreaded+ #x2)
(defconstant +coinit-disable-ole1dde+ #x4)

(cffi:defcfun ("CoInitializeEx" co-initialize-ex) hresult
  (pv-reserved :pointer)
  (dw-co-init dword))

(cffi:defcfun ("CoUninitialize" co-uninitialize) :void)

;;; --- the layout gate --------------------------------------------------------
;;;
;;; Run at LOAD, and deliberately fatal. ADR-0003 s4: "built in from the first commit". A
;;; struct whose size we have wrong corrupts memory rather than returning a wrong answer, so
;;; refusing to finish loading is the only honest response -- the alternative is an image
;;; that works until someone passes two arguments.
(verify-layouts)
