;;;; fetch-pdfium.lisp --- fetch, verify and unpack the pinned prebuilt pdfium (#997).
;;;;
;;;;     sbcl --script scripts/fetch-pdfium.lisp            # fetch if missing
;;;;     sbcl --script scripts/fetch-pdfium.lisp --force    # fetch again unconditionally
;;;;     sbcl --script scripts/fetch-pdfium.lisp --clean    # remove vendor/pdfium entirely
;;;;     sbcl --script scripts/fetch-pdfium.lisp --where    # print the library path, fetch nothing
;;;;
;;;; Exit 0 on success, 1 on failure. Produces vendor/pdfium/lib/<name> (pdfium.dll on Windows,
;;;; libpdfium.so on Linux, libpdfium.dylib on macOS), vendor/pdfium/LICENSE and
;;;; vendor/pdfium/licenses/, the licences of the libraries built into pdfium.
;;;;
;;;; FETCHED, NOT BUILT. Every other native library in vendor/ is built from source here
;;;; (ADR-0011). pdfium's build needs Chromium's toolchain and a checkout of several gigabytes,
;;;; so pdfium.pin names a release of bblanchon/pdfium-binaries, which builds it from pdfium's
;;;; own sources, and the sha256 of each platform's archive, computed when the pin was reviewed.
;;;; The archive is checked against it every time, including one already here.
;;;;
;;;; The archive for this machine is chosen from the operating system and the processor:
;;;; win, linux or mac, and x64 or arm64.
;;;;
;;;; Self-contained on purpose, like the build scripts, so it can be run alone on a bare
;;;; machine: the helpers below are build-sqlite.lisp's.

(require :asdf)
(require :uiop)
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; how a path is printed (#168)
(load (merge-pathnames "fs.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; aion/fs:delete-tree (#347)

(defparameter *root* (uiop:pathname-parent-directory-pathname
                      (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))
(defparameter *vendor* (merge-pathnames "vendor/pdfium/" *root*))

(defparameter *releases* "https://github.com/bblanchon/pdfium-binaries/releases/download/"
  "Where a release's archives are: this, the pin's version (a tag such as chromium/8100), a
slash, and the archive's name. Built from the version, so the pin names it once.")

(defun pin-field (name)
  "The value of NAME in pdfium.pin, or NIL. Lines are `name value', # comments."
  (with-open-file (in (merge-pathnames "pdfium.pin" *root*) :if-does-not-exist nil)
    (when in
      (loop for line = (read-line in nil nil)
            while line
            for tr = (string-trim '(#\Space #\Tab #\Return) line)
            unless (or (zerop (length tr)) (char= #\# (char tr 0)))
              do (let ((sp (position-if (lambda (c) (member c '(#\Space #\Tab))) tr)))
                   (when (and sp (string= name (subseq tr 0 sp)))
                     (return (string-trim '(#\Space #\Tab) (subseq tr sp)))))))))

;;; -------------------------------------------------------------------- helpers

(defparameter *command-timeout* 600
  "Seconds any external command may run before it is stopped.")

(defun %describe (command)
  (let ((text (if (stringp command) command (format nil "~{~A~^ ~}" command))))
    (if (> (length text) 160) (concatenate 'string (subseq text 0 160) " ...") text)))

(defun %run-bounded (command &key directory capture (timeout *command-timeout*)
                                  ignore-error-status)
  "Run COMMAND and return (values OUTPUT CODE). Signals on a non-zero exit unless
IGNORE-ERROR-STATUS, and after TIMEOUT seconds, having stopped it."
  (uiop:with-temporary-file (:pathname out :type "txt")
    (let ((process (uiop:launch-program command :directory directory :input nil
                                                :output (if capture out :interactive)
                                                :if-output-exists :supersede
                                                :error-output :interactive))
          (deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
      (loop while (uiop:process-alive-p process)
            do (when (> (get-internal-real-time) deadline)
                 (ignore-errors (uiop:terminate-process process :urgent t))
                 (error "This command did not finish within ~D seconds and was stopped:~%  ~A"
                        timeout (%describe command)))
               (sleep 0.05))
      (let ((code (uiop:wait-process process)))
        (unless (or ignore-error-status (eql code 0))
          (error "This command exited with code ~A:~%  ~A" code (%describe command)))
        (values (when capture
                  (string-right-trim '(#\Space #\Tab #\Return #\Newline)
                                     (uiop:read-file-string out :external-format :latin-1)))
                code)))))

(defun which (&rest candidates)
  "First of CANDIDATES on PATH, or NIL."
  (dolist (c candidates)
    (let ((found (ignore-errors
                  (%run-bounded (if (uiop:os-windows-p)
                                    (list "where" c)
                                    (list "sh" "-c" (format nil "command -v ~A" c)))
                                :capture t :ignore-error-status t :timeout 30))))
      (when (and found (plusp (length found))) (return c)))))

(defun run (program args &key (timeout *command-timeout*))
  (format t "~&  ~A ~{~A~^ ~}~%" program args)
  (finish-output)
  (%run-bounded (cons program args) :timeout timeout))

(defun sha256-of (file)
  (flet ((first-word (s) (subseq s 0 (or (position #\Space s) (length s)))))
    (cond
      ((which "sha256sum")
       (first-word (%run-bounded (list "sha256sum" (namestring file)) :capture t :timeout 120)))
      ((which "shasum")
       (first-word (%run-bounded (list "shasum" "-a" "256" (namestring file))
                                 :capture t :timeout 120)))
      ((and (uiop:os-windows-p) (which "certutil"))
       (let* ((out (%run-bounded (list "certutil" "-hashfile" (namestring file) "SHA256")
                                 :capture t :timeout 120))
              (lines (uiop:split-string out :separator '(#\Newline))))
         (string-downcase (remove #\Space (or (second lines) "")))))
      (t (error "No sha256 tool found (looked for sha256sum, shasum, certutil).")))))

(defun tar-program ()
  (if (uiop:os-windows-p)
      (let ((system32 (merge-pathnames "System32/tar.exe"
                                       (uiop:ensure-directory-pathname
                                        (or (uiop:getenv "SystemRoot") "C:\\Windows")))))
        (if (probe-file system32) (uiop:native-namestring system32) "tar"))
      "tar"))

;;; ------------------------------------------------------------------ the archive

(defun asset ()
  "This machine's archive name without .tgz: pdfium-<os>-<cpu>, such as pdfium-win-x64."
  (format nil "pdfium-~A-~A"
          (cond ((uiop:os-windows-p) "win") ((uiop:os-macosx-p) "mac") (t "linux"))
          #+(or arm64 aarch64) "arm64" #-(or arm64 aarch64) "x64"))

(defun output-name ()
  (cond ((uiop:os-windows-p) "pdfium.dll")
        ((uiop:os-macosx-p) "libpdfium.dylib")
        (t "libpdfium.so")))

(defun library-path ()
  (merge-pathnames (concatenate 'string "lib/" (output-name)) *vendor*))

(defun ensure-archive (url expected-sha)
  "The archive at URL in vendor/pdfium/archive/, fetched if needed and checked against
EXPECTED-SHA every time."
  (let ((archive (merge-pathnames (format nil "archive/~A" (subseq url (1+ (position #\/ url :from-end t))))
                                  *vendor*)))
    (ensure-directories-exist archive)
    (unless (probe-file archive)
      (format t "~&Fetching ~A~%" url)
      (let ((fetcher (which "curl" "wget")))
        (unless fetcher (error "Need curl or wget to fetch pdfium."))
        (if (string= fetcher "curl")
            ;; https only, redirects included; the sha256 below is the real check.
            (run "curl" (list "-sSL" "--fail" "--proto" "=https" "--proto-redir" "=https"
                              "-o" (uiop:native-namestring archive) url))
            (run "wget" (list "-q" "--https-only" "-O" (uiop:native-namestring archive) url)))))
    (let ((actual (sha256-of archive)))
      (unless (string-equal actual expected-sha)
        (delete-file archive)
        (error "pdfium archive checksum mismatch.~%  expected ~A~%  actual   ~A~%The archive has been deleted. Either upstream was substituted, or pdfium.pin is stale."
               expected-sha actual)))
    (format t "~&  sha256 ok~%")
    archive))

(defun unpack (archive)
  "Unpack ARCHIVE into vendor/pdfium/, and on Windows copy bin/pdfium.dll to lib/, where the
other platforms' archives put their library and where the loader looks."
  (run (tar-program) (list "-xzf" (uiop:native-namestring archive)
                           "-C" (uiop:native-namestring *vendor*))
       :timeout 300)
  (when (uiop:os-windows-p)
    (let ((dll (merge-pathnames "bin/pdfium.dll" *vendor*)))
      (unless (probe-file dll) (error "The archive has no bin/pdfium.dll."))
      (uiop:copy-file dll (ensure-directories-exist (library-path)))))
  (unless (probe-file (library-path))
    (error "The archive has no lib/~A." (output-name)))
  (unless (probe-file (merge-pathnames "LICENSE" *vendor*))
    (error "The archive has no LICENSE.")))

;;; ------------------------------------------------------------------- the stamp

(defun stamp-path () (merge-pathnames "BUILT-FROM" *vendor*))

(defun stamp-text (version asset sha)
  (format nil "version ~A~%asset ~A~%sha256 ~A~%" version asset (string-downcase sha)))

(defun stamp-matches-p (version asset sha)
  (let ((path (probe-file (stamp-path))))
    (and path (string= (uiop:read-file-string path) (stamp-text version asset sha)))))

;;; ------------------------------------------------------------------------- main

(defun main ()
  (let ((args (uiop:command-line-arguments)))
    (when (member "--where" args :test #'string=)
      (format t "~A~%" (human-path:human-path (library-path)))
      (uiop:quit 0))
    (when (member "--clean" args :test #'string=)
      (format t "~&removing ~A~%" (human-path:human-path *vendor*))
      (aion/fs:delete-tree *vendor* :if-does-not-exist :ignore)
      (uiop:quit 0))
    (let* ((version (pin-field "version"))
           (asset (asset))
           (sha (pin-field (format nil "sha256-~A" (subseq asset (length "pdfium-")))))
           (force (member "--force" args :test #'string=)))
      (unless (and version sha)
        (format *error-output* "fetch-pdfium: pdfium.pin has no version, or no sha256 line for ~A.~%" asset)
        (uiop:quit 1))
      (format t "~&pdfium ~A (~A) -> ~A~%" version asset (human-path:human-path *vendor*))
      (when (and (not force) (probe-file (library-path)) (stamp-matches-p version asset sha)
                 (probe-file (merge-pathnames "LICENSE" *vendor*)))
        (format t "~&  already here: ~A~%  (--force to fetch again)~%" (human-path:human-path (library-path)))
        (uiop:quit 0))
      (handler-case
          (progn
            (when (probe-file *vendor*)
              (aion/fs:delete-tree *vendor* :if-does-not-exist :ignore))
            (let ((archive (ensure-archive (format nil "~A~A/~A.tgz" *releases* version asset) sha)))
              (unpack archive)
              (with-open-file (out (stamp-path) :direction :output :if-exists :supersede)
                (write-string (stamp-text version asset sha) out))
              (format t "~&~%Unpacked vendor/pdfium/lib/~A~%" (output-name))
              (uiop:quit 0)))
        (error (e)
          (format *error-output* "~&fetch-pdfium: ~A~%" e)
          (uiop:quit 1))))))

(main)
