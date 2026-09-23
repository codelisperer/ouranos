;;;; library.lisp --- the OS DLLs. There is nothing to build and nothing to ship.
;;;;
;;;; ADR-0003 s8: no C toolchain, ever, for this binding. The OS DLLs ship with Windows and
;;;; live in the system directory, so unlike
;;;; aion/uv there is no vendor/ step, no libuv.pin, no build script, and no bundling
;;;; question when a desktop app is packaged -- the DLLs are already on every machine the
;;;; app can run on.
;;;;
;;;; THIS FILE LOADS FOUR: kernel32 (errors, handles), ole32 and oleaut32 (COM), and user32
;;;; (the STA message pump). ADR-0003 s8 also names advapi32 and shell32 as OS DLLs with
;;;; nothing to build -- they are NOT loaded here, and land with the subsystems that need
;;;; them (`service' and `security' want advapi32, `shell' wants shell32). The list is kept
;;;; to what is actually loaded because this file is the obvious place a reader looks to
;;;; find out what this image opened.
;;;;
;;;; That also means the search-order machinery aion/uv needs (an env override, beside the
;;;; image, vendor/, then the system) has nothing to do here. CFFI's plain name lookup finds
;;;; a system DLL, and if it does not, the machine is not Windows in any sense we can help
;;;; with -- which platform.lisp has already refused.
;;;;
;;;; STILL DEFERRED, NOT SIGNALLED AT LOAD. Loading is separated from the definitions so
;;;; that compiling and inspecting this system never depends on a successful dlopen. That
;;;; is aion/uv's rule and hyperion ADR-0011's lesson, kept for the same reason: a load-time
;;;; foreign-library failure takes the whole image down over a call nobody made.

(in-package #:aion/windows/ffi)

(cffi:define-foreign-library kernel32 (:windows "kernel32.dll"))
(cffi:define-foreign-library ole32    (:windows "ole32.dll"))
(cffi:define-foreign-library oleaut32 (:windows "oleaut32.dll"))
;; user32 is here for the STA MESSAGE PUMP, not for any UI: MsgWaitForMultipleObjects and
;; the PeekMessage/DispatchMessage trio live there, and an apartment that does not pump
;; deadlocks the moment an out-of-process server calls back into it.
(cffi:define-foreign-library user32   (:windows "user32.dll"))

(defvar *loaded* nil "Which of the OS libraries have been loaded into this image.")

(defun load-windows-libraries ()
  "Load the OS DLLs this system binds. Idempotent; returns the list loaded."
  (dolist (lib '(kernel32 ole32 oleaut32 user32) *loaded*)
    (unless (member lib *loaded*)
      (cffi:load-foreign-library lib)
      (push lib *loaded*))))

(defun library-available-p (&optional (lib 'kernel32))
  "True when LIB is loaded in this image."
  (and (member lib *loaded*) t))

;;; Loaded eagerly HERE and not in platform.lisp, because by this point we know we are on
;;; Windows: these three DLLs are part of the OS, so a failure to find them is not the
;;; missing-optional-dependency case aion/uv defends against -- it is a broken installation,
;;; and reporting it at load is more useful than deferring it to a call site.
(load-windows-libraries)
