;;;; windows-installer-swap.lisp --- an update installs the whole new version or none of it (#98)
;;;;
;;;; A Windows bundle is a launcher, sbcl-runtime.exe and sbcl.core, and the launcher refuses a
;;;; core it was not built with (#98, step 2). Both installers (scripts/installers/) extract to
;;;; <install>.new, have the staged launcher check the staged core, and swap the directories with
;;;; two renames, so an update that stops part-way leaves the old version whole (#98, step 3).
;;;;
;;;; These tests build real installers with scripts/build-installer.ps1 from small bundles made
;;;; here -- a launcher compiled the way the build compiles it and switched to the GUI subsystem
;;;; as a release is, a stand-in runtime that exits at once, and a core of random bytes -- and
;;;; install them into a fresh directory. Each version's core differs, so which version is
;;;; installed is read from the core's hash, and whether the pair is whole from the installed
;;;; launcher's own check.
;;;;
;;;; THE CONTROL for the interrupted update is the same update left to finish.
;;;;
;;;; Windows only, and only where MSVC and the packager are installed: makensis for NSIS, ISCC
;;;; for Inno, found by build-installer.ps1 -Check, which is how the build finds them. A missing
;;;; one is a skip that says so. The installers write per-user registry keys and a Start menu entry for the app
;;;; name below; each test uninstalls, then removes those keys itself.

(in-package #:checkers/tests)

(in-suite checkers)

(defparameter +swap-app+ "ouranos-swap-test"
  "The fixture app's name: the installers' registry keys and Start menu entry are named for it.")

(defparameter +swap-big-core-bytes+ (* 160 1024 1024)
  "The size of the updated version's core: large enough that its extraction can be stopped
part-way, in about a second on the machines measured.")

(defun %swap-tool (format)
  "True when build-installer.ps1 finds FORMAT's packager. Asked of the script itself, which
looks on PATH, in the registry and in the usual install directories, so that this test skips
exactly when the build could not run."
  (let ((out (ignore-errors
              (uiop:run-program (list "pwsh" "-NoProfile" "-NonInteractive" "-File"
                                      (uiop:native-namestring
                                       (merge-pathnames "build-installer.ps1" *scripts*))
                                      "-Check")
                                :output :string :error-output :string :ignore-error-status t))))
    (and out (search (ecase format (:nsis "makensis (nsis):") (:inno "ISCC (inno):")) out) t)))

(defun %swap-run (argv &key wait)
  "Run ARGV hidden. With WAIT, return its exit code; otherwise return the process."
  (if wait
      (nth-value 2 (uiop:run-program argv :output nil :error-output nil :ignore-error-status t))
      (uiop:launch-program argv :output nil :error-output nil)))

(defun %swap-msvc (tree command)
  "Run COMMAND inside the MSVC environment with TREE as the current directory. True on success."
  (eql 0 (nth-value 2 (uiop:run-program (uiop:symbol-call :ouranos-msvc :msvc-command command)
                                        :directory tree :output nil :error-output nil
                                        :ignore-error-status t))))

(defun %swap-runtime (tree)
  "Compile a stand-in sbcl-runtime.exe into TREE. It never needs to be SBCL: the launcher starts
it when the relaunched app starts, and it writes the file `started' beside itself and exits 0,
so a test can tell that the app was started after an update (%SWAP-WAIT-STARTED)."
  (let ((source (merge-pathnames "runtime.c" tree)))
    (with-open-file (s source :direction :output :if-exists :supersede)
      (dolist (line '("#include <windows.h>"
                      "int main(void) {"
                      "  wchar_t path[MAX_PATH * 4];"
                      "  DWORD n = GetModuleFileNameW(NULL, path, MAX_PATH * 4);"
                      "  wchar_t *slash = wcsrchr(path, L'\\\\');"
                      "  if (n == 0 || slash == NULL) return 1;"
                      "  wcscpy_s(slash + 1, MAX_PATH * 4 - (slash + 1 - path), L\"started\");"
                      "  HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);"
                      "  if (f == INVALID_HANDLE_VALUE) return 1;"
                      "  CloseHandle(f);"
                      "  return 0;"
                      "}"))
        (write-line line s)))
    (and (%swap-msvc tree "cl /nologo runtime.c /Feruntime.exe")
         (merge-pathnames "runtime.exe" tree))))

(defun %swap-wait-started (dir &optional (seconds 20))
  "Wait up to SECONDS for the stand-in runtime in DIR to have written `started'. True when it has.
The caller deletes an earlier one first."
  (let ((marker (merge-pathnames "started" dir)))
    (loop repeat (* seconds 10)
          when (probe-file marker) do (return t)
          do (sleep 0.1)
          finally (return (and (probe-file marker) t)))))

(defun %swap-random-file (path bytes)
  (with-open-file (s path :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
    (let ((chunk (make-array 65536 :element-type '(unsigned-byte 8)))
          (state (make-random-state t)))
      (loop for left = bytes then (- left (length chunk))
            while (plusp left)
            do (dotimes (i (length chunk)) (setf (aref chunk i) (random 256 state)))
               (write-sequence chunk s :end (min left (length chunk))))))
  path)

(defun %swap-bundle (tree version core-bytes runtime)
  "A Windows bundle for VERSION under TREE, as build-installer.ps1 expects it: the launcher, a
copy of RUNTIME as sbcl-runtime.exe, and a core of CORE-BYTES random bytes. Returns (values
BUNDLE-DIRECTORY CORE-SHA256), or NIL when the launcher did not compile."
  (let* ((bundle (merge-pathnames (format nil "~A-~A-windows-x86-64/" +swap-app+ version) tree))
         (launcher (merge-pathnames (format nil "~A.exe" +swap-app+) bundle)))
    (ensure-directories-exist bundle)
    (uiop:copy-file runtime (merge-pathnames "sbcl-runtime.exe" bundle))
    (%swap-random-file (merge-pathnames "sbcl.core" bundle) core-bytes)
    (let ((sha (%sha256-hex (merge-pathnames "sbcl.core" bundle))))
      (and (uiop:symbol-call :ouranos-windows-launcher :compile-launcher
                             launcher 512 (merge-pathnames (format nil "obj-~A/" version) tree) sha)
           ;; A release's launcher is a GUI program (windows-gui-subsystem.ps1), so the silent
           ;; installer's relaunch opens no console window.
           (%swap-msvc bundle (format nil "editbin /nologo /SUBSYSTEM:WINDOWS ~A.exe" +swap-app+))
           (values bundle sha)))))

(defun %swap-installer (bundle format)
  "Build FORMAT's installer for BUNDLE with scripts/build-installer.ps1. Returns its path or NIL."
  (let ((out (merge-pathnames (format nil "setup-~(~A~)-~A.exe" format
                                      (car (last (pathname-directory bundle))))
                              (uiop:pathname-parent-directory-pathname bundle))))
    (%swap-run (list "pwsh" "-NoProfile" "-NonInteractive" "-File"
                     (uiop:native-namestring (merge-pathnames "build-installer.ps1" *scripts*))
                     (uiop:native-namestring bundle) "-Format" (string-downcase format)
                     "-NoWebView2" "-Out" (uiop:native-namestring out))
               :wait t)
    (and (probe-file out) out)))

(defun %swap-install-argv (installer format dir)
  "The arguments hyperion/update gives FORMAT's installer, installing into DIR."
  (let ((dir (string-right-trim "\\" (uiop:native-namestring dir))))
    (ecase format
      (:nsis (list (uiop:native-namestring installer) "/S" (format nil "/D=~A" dir)))
      (:inno (list (uiop:native-namestring installer) "/VERYSILENT" "/SUPPRESSMSGBOXES"
                   "/NORESTART" (format nil "/DIR=~A" dir))))))

(defun %swap-sibling (dir suffix)
  "DIR with SUFFIX added to its last component, as the installers name .new and .old."
  (uiop:ensure-directory-pathname
   (concatenate 'string (string-right-trim "\\" (uiop:native-namestring dir)) suffix)))

(defun %swap-launcher-check (dir)
  "The installed launcher's own check of the installed core: 0 when they are a pair."
  (let ((exe (merge-pathnames (format nil "~A.exe" +swap-app+) dir)))
    ;; Set in a child shell, not in this image, whose later children would inherit it.
    (if (probe-file exe)
        (nth-value 2 (uiop:run-program (format nil "set OURANOS_LAUNCHER_CHECK_ONLY=1&& \"~A\""
                                               (uiop:native-namestring exe))
                                       :force-shell t :output nil :error-output nil
                                       :ignore-error-status t))
        :no-launcher)))

(defun %swap-installed (dir)
  "The SHA-256 of the installed core, or NIL when there is none."
  (let ((core (merge-pathnames "sbcl.core" dir)))
    (and (probe-file core) (%sha256-hex core))))

(defun %swap-wait-gone (dir &optional (seconds 20))
  "Wait up to SECONDS for DIR not to exist. True when it is gone."
  (loop repeat (* seconds 10)
        unless (uiop:directory-exists-p dir) do (return t)
        do (sleep 0.1)
        finally (return (not (uiop:directory-exists-p dir)))))

(defun %swap-taskkill (&rest args)
  "Run taskkill /F with ARGS. Returns (values EXIT-CODE OUTPUT)."
  (multiple-value-bind (out err code)
      (uiop:run-program (list* "taskkill" "/F" args)
                        :output :string :error-output :string :ignore-error-status t)
    (values code (concatenate 'string out err))))

;;; Stopping an installer part-way through its copy has to happen within a fraction of a second:
;;; Inno writes the 160 MB core in about 0.85 s. Asking PowerShell for a process's children took
;;; about a second, and tasklist about a second too, so both missed it. taskkill could not stop
;;; Inno 7.1.0's child at all, by pid tree or by image name: "The operation attempted is not
;;; supported". OpenProcess and TerminateProcess on the child's pid, found here with a Toolhelp
;;; snapshot in milliseconds, stop it (#98).

(defun %swap-children (pid)
  "The pids of the processes whose parent is PID, from a Toolhelp snapshot."
  #-win32 (declare (ignore pid))
  #-win32 (error "Windows only")
  #+win32
  (let ((snapshot (sb-alien:alien-funcall
                   (sb-alien:extern-alien "CreateToolhelp32Snapshot"
                                          (function sb-alien:unsigned-long sb-alien:unsigned-long
                                                    sb-alien:unsigned-long))
                   2 0))                ; TH32CS_SNAPPROCESS
        (entry (make-array 568 :element-type '(unsigned-byte 8) :initial-element 0))
        (children '()))
    ;; PROCESSENTRY32W on x64: dwSize at 0, th32ProcessID at 8, th32ParentProcessID at 32; 568
    ;; bytes in all.
    (flet ((u32 (offset) (logior (aref entry offset) (ash (aref entry (+ offset 1)) 8)
                                 (ash (aref entry (+ offset 2)) 16) (ash (aref entry (+ offset 3)) 24))))
      (setf (aref entry 0) (ldb (byte 8 0) 568) (aref entry 1) (ldb (byte 8 8) 568))
      (sb-sys:with-pinned-objects (entry)
        (loop for more = (sb-alien:alien-funcall
                          (sb-alien:extern-alien "Process32FirstW"
                                                 (function sb-alien:int sb-alien:unsigned-long
                                                           sb-sys:system-area-pointer))
                          snapshot (sb-sys:vector-sap entry))
                then (sb-alien:alien-funcall
                      (sb-alien:extern-alien "Process32NextW"
                                             (function sb-alien:int sb-alien:unsigned-long
                                                       sb-sys:system-area-pointer))
                      snapshot (sb-sys:vector-sap entry))
              while (/= 0 more)
              when (= (u32 32) pid) do (push (u32 8) children)))
      (sb-alien:alien-funcall (sb-alien:extern-alien "CloseHandle"
                                                     (function sb-alien:int sb-alien:unsigned-long))
                              snapshot)
      children)))

(defun %swap-terminate (pid)
  "Terminate the process PID. Returns :TERMINATED, or (:FAILED STEP LAST-ERROR)."
  #-win32 (declare (ignore pid))
  #-win32 (error "Windows only")
  #+win32
  (flet ((last-error () (sb-alien:alien-funcall
                         (sb-alien:extern-alien "GetLastError" (function sb-alien:unsigned-long)))))
    (let ((handle (sb-alien:alien-funcall
                   (sb-alien:extern-alien "OpenProcess"
                                          (function sb-alien:unsigned-long sb-alien:unsigned-long
                                                    sb-alien:int sb-alien:unsigned-long))
                   1 0 pid)))           ; PROCESS_TERMINATE
      (if (zerop handle)
          (list :failed :open (last-error))
          (let ((ok (sb-alien:alien-funcall
                     (sb-alien:extern-alien "TerminateProcess"
                                            (function sb-alien:int sb-alien:unsigned-long
                                                      sb-alien:unsigned-int))
                     handle 1)))
            (prog1 (if (zerop ok) (list :failed :terminate (last-error)) :terminated)
              (sb-alien:alien-funcall
               (sb-alien:extern-alien "CloseHandle" (function sb-alien:int sb-alien:unsigned-long))
               handle)))))))

(defun %swap-kill-tree (process installer)
  "Stop PROCESS and the processes it started, children first: Inno's Setup runs its work in a
child, a copy of INSTALLER named <name>.tmp. What a stopped Setup leaves in its temporary
directory is inside the fixture (%WITH-TEMP-IN). Returns (values KILLED RESULTS): KILLED is
true when every process was terminated."
  (declare (ignore installer))
  (let* ((pid (uiop:process-info-pid process))
         (results (loop for target in (append (%swap-children pid) (list pid))
                        collect (cons target (%swap-terminate target)))))
    (ignore-errors (uiop:wait-process process))
    (values (every (lambda (r) (eq :terminated (cdr r))) results) results)))

(defun %swap-image-at (pid)
  "The image name of the process PID, as tasklist reports it, or NIL."
  (let ((out (uiop:run-program (list "tasklist" "/FI" (format nil "PID eq ~D" pid) "/FO" "CSV" "/NH")
                               :output :string :ignore-error-status t)))
    (and (search (format nil "\"~D\"" pid) out)
         (string-trim "\"" (first (uiop:split-string out :separator '(#\,)))))))

(defun %swap-running (installer)
  "The tasklist lines of every process whose image is INSTALLER or the .tmp copy Inno's Setup
runs its work in, whatever their parent."
  (let ((base (pathname-name installer)))
    (loop for image in (list (format nil "~A.exe" base) (format nil "~A.tmp" base))
          for out = (uiop:run-program (list "tasklist" "/FI" (format nil "IMAGENAME eq ~A" image)
                                            "/FO" "CSV" "/NH")
                                      :output :string :ignore-error-status t)
          append (remove-if-not (lambda (line) (search image line :test #'char-equal))
                                (uiop:split-string out :separator '(#\Newline #\Return))))))

(defun %swap-uninstall (dir format)
  "Uninstall the fixture app from DIR, then remove its registry keys and Start menu entries
directly, so a failed uninstall does not leave them on the machine."
  (ignore-errors
   (ecase format
     (:nsis (let ((u (merge-pathnames "uninstall.exe" dir)))
              (when (probe-file u)
                (%swap-run (list (uiop:native-namestring u) "/S"
                                 (format nil "_?=~A" (string-right-trim "\\" (uiop:native-namestring dir))))
                           :wait t))))
     (:inno (let ((u (merge-pathnames "unins000.exe" dir)))
              (when (probe-file u)
                (%swap-run (list (uiop:native-namestring u) "/VERYSILENT" "/SUPPRESSMSGBOXES"
                                 "/NORESTART")
                           :wait t))))))
  (dolist (key (list (format nil "HKCU\\Software\\~A" +swap-app+)
                     (format nil "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\~A" +swap-app+)
                     (format nil "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\~A_is1" +swap-app+)))
    (%swap-run (list "reg" "delete" key "/f") :wait t))
  (let ((programs (uiop:ensure-directory-pathname
                   (uiop:native-namestring
                    (format nil "~A\\Microsoft\\Windows\\Start Menu\\Programs" (uiop:getenv "APPDATA"))))))
    (ignore-errors (delete-file (merge-pathnames (format nil "~A.lnk" +swap-app+) programs)))
    (ignore-errors (aion/fs:delete-tree (merge-pathnames (format nil "~A/" +swap-app+) programs)
                                        :if-does-not-exist :ignore))))

(defun %swap-copying-p (staged big-core-bytes)
  "True while an installer is part-way through writing a file into STAGED, as far as can be seen
from outside. NSIS writes sbcl.core under its own name, so it is part-written while it is shorter
than BIG-CORE-BYTES. Inno writes each file as is-*.tmp and renames it once complete, so sbcl.core
appears whole (measured: 167,772,160 bytes at its first sighting), and a file of that pattern is
the copy in progress. The listing opens no file, which could itself stop the installer's rename."
  (let ((files (ignore-errors (uiop:directory-files staged))))
    (or (some (lambda (f) (and (uiop:string-prefix-p "is-" (file-namestring f))
                               (equalp "tmp" (pathname-type f))))
              files)
        (let ((core (find "sbcl.core" files :key #'file-namestring :test #'equalp)))
          (and core
               (let ((size (ignore-errors (with-open-file (s core :element-type '(unsigned-byte 8))
                                            (file-length s)))))
                 (and size (plusp size) (< size big-core-bytes))))))))

(defparameter +swap-stop-deadline-seconds+ 120
  "How long %SWAP-STOP-MID-COPY waits for the copy to start before it stops the installer and
reports :TIMED-OUT. An install of the fixture takes about two seconds.")

(defun %swap-stop-mid-copy (installer format dir big-core-bytes)
  "Start INSTALLER into DIR and stop it, with its children, while it is writing a staged file.
Returns a plist: :OUTCOME is :STOPPED, :FINISHED if it ended before any copy was seen in
progress, or :TIMED-OUT if neither happened within +SWAP-STOP-DEADLINE-SECONDS+, in which case
it was stopped; then what shows whether the kill happened -- the image at the pid killed,
taskkill's exit code and output, and every installer process still running afterwards."
  (let* ((staged (%swap-sibling dir ".new"))
         (process (%swap-run (%swap-install-argv installer format dir)))
         (pid (uiop:process-info-pid process))
         (image (progn (sleep 0.05) (%swap-image-at pid)))
         (deadline (+ (get-internal-real-time)
                      (* +swap-stop-deadline-seconds+ internal-time-units-per-second))))
    (loop
      (cond ((> (get-internal-real-time) deadline)
             ;; Neither a copy in progress nor an end: stop it rather than wait for ever.
             (multiple-value-bind (killed output) (%swap-kill-tree process installer)
               (return (list :outcome :timed-out :pid pid :image image :killed killed
                             :taskkill-output output
                             :staged (mapcar #'file-namestring
                                             (ignore-errors (uiop:directory-files staged)))))))
            ((%swap-copying-p staged big-core-bytes)
             (let ((staged-files (mapcar #'file-namestring (ignore-errors (uiop:directory-files staged)))))
               (multiple-value-bind (killed output) (%swap-kill-tree process installer)
                 (return (list :outcome :stopped :pid pid :image image :staged-at-kill staged-files
                               :killed killed :taskkill-output output
                               :alive (uiop:process-alive-p process)
                               :still-running (%swap-running installer))))))
            ((not (uiop:process-alive-p process))
             (return (list :outcome :finished :pid pid :image image))))
      (sleep 0.005))))

(defmacro %with-temp-in ((dir) &body body)
  "Run BODY with TEMP and TMP set to DIR, and set them back afterwards. The installers and
uninstallers run in BODY inherit them, so the is-*.tmp directories Inno's Setup and uninstaller
make, and leave behind when stopped, are inside DIR and are deleted with the fixture. Cleaning
them out of %TEMP% instead could not tell them from another program's (review of #477)."
  (let ((temp (gensym "TEMP")) (tmp (gensym "TMP")))
    `(let ((,temp (uiop:getenv "TEMP")) (,tmp (uiop:getenv "TMP")))
       (ensure-directories-exist ,dir)
       (unwind-protect
            (progn (setf (uiop:getenv "TEMP") (uiop:native-namestring ,dir)
                         (uiop:getenv "TMP") (uiop:native-namestring ,dir))
                   ,@body)
         (setf (uiop:getenv "TEMP") ,temp
               (uiop:getenv "TMP") ,tmp)))))

(defmacro %with-swap-fixture ((format tree v1 v1-sha v2 v2-sha) &body body)
  "Bind TREE to a fresh directory and V1/V2 to FORMAT's installers for a small version 0.0.1
and a large 0.0.2, with their cores' hashes. Skips when a tool is missing; always cleans up."
  (let ((runtime (gensym "RUNTIME")) (b1 (gensym "B1")) (b2 (gensym "B2")))
    `(let ((,tree (%fresh-tree)))
       (unwind-protect
            (progn
              (load (merge-pathnames "windows-launcher.lisp" *scripts*))
              (cond
                ((not (ignore-errors (uiop:symbol-call :ouranos-msvc :find-msvc)))
                 (skip "No MSVC here"))
                ((not (%swap-tool ,format))
                 (skip "build-installer.ps1 -Check finds no ~A" (if (eq ,format :nsis) "makensis" "ISCC")))
                (t
                 (let ((,runtime (%swap-runtime ,tree)))
                   (multiple-value-bind (,b1 ,v1-sha) (%swap-bundle ,tree "0.0.1" 65536 ,runtime)
                     (multiple-value-bind (,b2 ,v2-sha) (%swap-bundle ,tree "0.0.2" +swap-big-core-bytes+ ,runtime)
                       (let ((,v1 (and ,b1 (%swap-installer ,b1 ,format)))
                             (,v2 (and ,b2 (%swap-installer ,b2 ,format))))
                         (is-true (and ,v1 ,v2) "both installers were built")
                         (when (and ,v1 ,v2)
                           (%with-temp-in ((merge-pathnames "temp/" ,tree))
                             ,@body)))))))))
         (%with-temp-in ((merge-pathnames "temp/" ,tree))
           (%swap-uninstall (merge-pathnames "app/" ,tree) ,format))
         (aion/fs:delete-tree ,tree :if-does-not-exist :ignore)))))

(defun %swap-hold-staged-file (dir name)
  "Start a thread that opens NAME in DIR's staged copy (DIR.new) as soon as the installer has
written it, and keeps it open. Returns a function that closes it and returns a plist: :HELD, true
when the file was opened, and :SAW-OLD, true when DIR.old existed while it was open, which is
the first rename having happened."
  (let* ((path (merge-pathnames name (%swap-sibling dir ".new")))
         (old (%swap-sibling dir ".old"))
         (release nil) (held nil) (saw-old nil)
         (thread (sb-thread:make-thread
                  (lambda ()
                    (loop until (or release held)
                          do (let ((s (ignore-errors (open path :element-type '(unsigned-byte 8)))))
                               (if (null s)
                                   (sleep 0.005)
                                   (unwind-protect
                                        (progn (setf held t)
                                               (loop until release
                                                     do (when (uiop:directory-exists-p old)
                                                          (setf saw-old t))
                                                        (sleep 0.05)))
                                     (close s))))))
                  :name "hold a file in the staged copy")))
    (lambda ()
      (setf release t)
      (sb-thread:join-thread thread :default nil)
      (list :held held :saw-old saw-old))))

(defun %swap-scenarios (format)
  "Every case, in order, against FORMAT's installers."
  (%with-swap-fixture (format tree v1 v1-sha v2 v2-sha)
    (let* ((dir (merge-pathnames "app/" tree))
           (new (%swap-sibling dir ".new"))
           (old (%swap-sibling dir ".old")))
      ;; A first install.
      (is (eql 0 (%swap-run (%swap-install-argv v1 format dir) :wait t)) "the first install exits 0")
      (is (equal v1-sha (%swap-installed dir)) "and installs version 1")
      (is (eql 0 (%swap-launcher-check dir)) "as a pair the launcher accepts")
      (is-true (%swap-wait-started dir) "and the silent install started the app")
      (is-true (%swap-wait-gone old) "the relaunched app removed what the swap left")

      ;; An update stopped while it writes the new core leaves version 1 whole.
      ;; The kill is checked before the directory is: a kill that did not happen fails here as
      ;; "not stopped", not below as a swap that went wrong.
      (let ((stop (%swap-stop-mid-copy v2 format dir +swap-big-core-bytes+)))
        (is (eq :stopped (getf stop :outcome))
            "the update was stopped part-way through the copy, not after it: ~S" stop)
        (is (and (getf stop :killed) (not (getf stop :alive))
                 (null (getf stop :still-running)))
            "and nothing of the installer is still running: ~S" stop))
      (let ((found (%swap-installed dir)))
        (is (equal v1-sha found)
            "after the stopped update, version 1 is still installed: found ~A (~A), .new ~A, .old ~A"
            found (cond ((equal found v1-sha) "version 1") ((equal found v2-sha) "version 2") (t "neither"))
            (and (uiop:directory-exists-p new) (mapcar #'file-namestring (uiop:directory-files new)))
            (and (uiop:directory-exists-p old) (mapcar #'file-namestring (uiop:directory-files old)))))
      (is (eql 0 (%swap-launcher-check dir)) "and it is still a pair the launcher accepts")

      ;; The control: the same update left to finish. It also clears what the stopped one left.
      (is (eql 0 (%swap-run (%swap-install-argv v2 format dir) :wait t)) "the update left to finish exits 0")
      (is (equal v2-sha (%swap-installed dir)) "and installs version 2")
      (is (eql 0 (%swap-launcher-check dir)) "as a pair the launcher accepts")
      (is-true (%swap-wait-started dir) "and the silent update started the app")
      (is-false (uiop:directory-exists-p new) "with nothing staged left over")
      (is-true (%swap-wait-gone old) "and the previous version removed once the new one started")

      ;; A process whose current directory is the install directory blocks the rename (#98,
      ;; measured). Released after 4 seconds, the installer's retry outlasts it.
      (let ((holder (uiop:launch-program (list "ping" "-n" "30" "127.0.0.1")
                                         :directory dir :output nil :error-output nil)))
        (let ((install (%swap-run (%swap-install-argv v1 format dir))))
          (sleep 4)
          (%swap-taskkill "/PID" (princ-to-string (uiop:process-info-pid holder)))
          (is (eql 0 (uiop:wait-process install)) "an install that waited for the directory exits 0")))
      (is (equal v1-sha (%swap-installed dir)) "and installed version 1")
      (is-true (%swap-wait-started dir) "and started the app")
      (is-true (%swap-wait-gone old) "and the previous version was removed")

      ;; A file held open in the install directory for longer than the retry: the update fails
      ;; and changes nothing.
      (let ((code nil))
        (with-open-file (s (merge-pathnames "sbcl.core" dir) :element-type '(unsigned-byte 8))
          (declare (ignorable s))
          (setf code (%swap-run (%swap-install-argv v2 format dir) :wait t)))
        (is (not (eql 0 code)) "an update that could never rename the directory fails: exit ~A" code))
      (is (equal v1-sha (%swap-installed dir)) "leaving version 1 installed")
      (is (eql 0 (%swap-launcher-check dir)) "as a pair the launcher accepts")
      (is-false (uiop:directory-exists-p new) "and the staged copy deleted")

      ;; A file held open in the STAGED copy for longer than the retry (review of train 21): the
      ;; first rename succeeds, the second cannot, and the first is undone. That the first rename
      ;; happened is checked, not assumed: .old existed while the file was held.
      (let* ((release (%swap-hold-staged-file dir "sbcl.core"))
             (code (%swap-run (%swap-install-argv v2 format dir) :wait t))
             (hold (funcall release)))
        (is (getf hold :held) "the staged sbcl.core was held open during the update: ~S" hold)
        (is (getf hold :saw-old) "and the first rename happened while it was: ~S" hold)
        (is (eql 2 code) "an update whose second rename never succeeds exits 2: exit ~A" code))
      (is (equal v1-sha (%swap-installed dir)) "and the undo put version 1 back")
      (is (eql 0 (%swap-launcher-check dir)) "as a pair the launcher accepts")
      (is-false (uiop:directory-exists-p old) "with no previous version left beside it")
      ;; The installer deleted what it could of the staged copy; the held file was not deletable.
      (aion/fs:delete-tree new :if-does-not-exist :ignore)

      ;; An update that stopped between its two renames: the install directory is gone, the
      ;; checked copy is beside the previous version. The next run finishes the swap first; left
      ;; as it is, the directory it installs into is missing and a staged copy is in the way.
      (%swap-run (list "cmd" "/c" "move" (string-right-trim "\\" (uiop:native-namestring dir))
                       (string-right-trim "\\" (uiop:native-namestring old)))
                 :wait t)
      (uiop:run-program (list "robocopy" (uiop:native-namestring old) (uiop:native-namestring new) "/E"
                              "/NFL" "/NDL" "/NJH" "/NJS")
                        :output nil :error-output nil :ignore-error-status t)
      (is (eql 0 (%swap-run (%swap-install-argv v2 format dir) :wait t))
          "an install after a swap that stopped between its renames exits 0")
      (is (equal v2-sha (%swap-installed dir)) "and installs version 2")
      (is-true (%swap-wait-started dir) "and starts the app")
      (is-false (uiop:directory-exists-p new) "with nothing staged left over")
      (is-true (%swap-wait-gone old) "and the previous version removed"))))

(test an-nsis-update-installs-the-whole-new-version-or-none-of-it
  #-win32 (skip "The Windows installers are built and run on Windows only")
  #+win32 (%swap-scenarios :nsis))

(test an-inno-update-installs-the-whole-new-version-or-none-of-it
  #-win32 (skip "The Windows installers are built and run on Windows only")
  #+win32 (%swap-scenarios :inno))


;;; --- a bundle with one of sbcl.core and sbcl-runtime.exe (review of train 20) ------------
;;;
;;; The launcher's layout has both files and a one-file image has neither. A bundle with exactly
;;; one of them used to skip the staged check, as if it were a one-file image, and be swapped
;;; in, to fail at launch. Both installers now refuse it while it is staged, and
;;; build-installer.ps1 refuses to build an installer from it. The installers are therefore
;;; compiled here directly, with the defines build-installer.ps1 passes.

(defun %swap-tool-path (format)
  "The full path build-installer.ps1 -Check reports for FORMAT's packager, or NIL."
  (let* ((out (ignore-errors
               (uiop:run-program (list "pwsh" "-NoProfile" "-NonInteractive" "-File"
                                       (uiop:native-namestring
                                        (merge-pathnames "build-installer.ps1" *scripts*))
                                       "-Check")
                                 :output :string :error-output :string :ignore-error-status t)))
         (label (ecase format (:nsis "makensis (nsis):") (:inno "ISCC (inno):")))
         (line (and out (find-if (lambda (l) (search label l))
                                 (uiop:split-string out :separator '(#\Newline #\Return))))))
    (and line (string-trim " " (subseq line (+ (search label line) (length label)))))))

(defun %swap-half-bundle (bundle tree missing)
  "A copy of BUNDLE in TREE without the file MISSING. Returns its directory."
  (let ((copy (merge-pathnames (format nil "half-without-~A/" (pathname-name missing)) tree)))
    (ensure-directories-exist copy)
    (dolist (f (uiop:directory-files bundle))
      (unless (equalp (file-namestring f) missing)
        (uiop:copy-file f (merge-pathnames (file-namestring f) copy))))
    copy))

(defun %swap-installer-direct (bundle format out &key (exe (format nil "~A.exe" +swap-app+)))
  "Compile FORMAT's installer for BUNDLE to OUT with the packager directly, with the defines
build-installer.ps1 passes, and no WebView2 bootstrapper. EXE is the program it starts after a
silent install. Returns OUT, or NIL."
  (let* ((tool (%swap-tool-path format))
         (src (string-right-trim "\\" (uiop:native-namestring bundle)))
         (argv (ecase format
                 (:nsis (list tool "/NOCD" (format nil "/DAPPNAME=~A" +swap-app+) "/DVERSION=0.0.3"
                              "/DVIVERSION=0.0.3.0" (format nil "/DSRCDIR=~A" src)
                              (format nil "/DOUTFILE=~A" (uiop:native-namestring out))
                              (format nil "/DEXENAME=~A" exe)
                              (uiop:native-namestring (merge-pathnames "installers/windows.nsi" *scripts*))))
                 (:inno (list tool (format nil "/DAPPNAME=~A" +swap-app+) "/DVERSION=0.0.3"
                              (format nil "/DSRCDIR=~A" src)
                              (format nil "/DOUTDIR=~A" (string-right-trim "\\" (uiop:native-namestring
                                                                                  (uiop:pathname-directory-pathname out))))
                              (format nil "/DOUTBASE=~A" (pathname-name out))
                              (format nil "/DEXENAME=~A" exe)
                              (uiop:native-namestring (merge-pathnames "installers/windows.iss" *scripts*)))))))
    (when tool
      (%swap-run argv :wait t)
      (and (probe-file out) out))))

(defun %swap-half-bundles-are-refused (format)
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (progn
           (load (merge-pathnames "windows-launcher.lisp" *scripts*))
           (cond
             ((not (ignore-errors (uiop:symbol-call :ouranos-msvc :find-msvc))) (skip "No MSVC here"))
             ((not (%swap-tool-path format))
              (skip "build-installer.ps1 -Check finds no ~A" (if (eq format :nsis) "makensis" "ISCC")))
             (t
              (let* ((runtime (%swap-runtime tree))
                     (dir (merge-pathnames "app/" tree)))
                (multiple-value-bind (b1 v1-sha) (%swap-bundle tree "0.0.1" 65536 runtime)
                  (let ((b3 (%swap-bundle tree "0.0.3" 65536 runtime))
                        (v1 (and b1 (%swap-installer b1 format))))
                    (is-true (and v1 b3) "version 1's installer and version 3's bundle were built")
                    (when (and v1 b3)
                      (%with-temp-in ((merge-pathnames "temp/" tree))
                        (is (eql 0 (%swap-run (%swap-install-argv v1 format dir) :wait t))
                            "version 1 installs")
                        (dolist (missing '("sbcl.core" "sbcl-runtime.exe"))
                          (let* ((half (%swap-half-bundle b3 tree missing))
                                 (installer (%swap-installer-direct
                                             half format
                                             (merge-pathnames (format nil "half-~(~A~)-~A.exe" format
                                                                      (pathname-name missing))
                                                              tree))))
                            (is-true installer "an installer was compiled from the bundle without ~A" missing)
                            (when installer
                              (let ((code (%swap-run (%swap-install-argv installer format dir) :wait t)))
                                (is (eql 2 code) "the bundle without ~A is refused with code 2: ~S"
                                    missing code))
                              (is (equal v1-sha (%swap-installed dir))
                                  "and version 1 is still installed after the bundle without ~A" missing)
                              (is (eql 0 (%swap-launcher-check dir)) "as a pair the launcher accepts")
                              (is-false (uiop:directory-exists-p (%swap-sibling dir ".new"))
                                        "with nothing staged left over"))))))))))))
      (%with-temp-in ((merge-pathnames "temp/" tree))
        (%swap-uninstall (merge-pathnames "app/" tree) format))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(test an-nsis-update-refuses-a-bundle-with-one-of-the-core-and-the-runtime
  #-win32 (skip "The Windows installers are built and run on Windows only")
  #+win32 (%swap-half-bundles-are-refused :nsis))

(test an-inno-update-refuses-a-bundle-with-one-of-the-core-and-the-runtime
  #-win32 (skip "The Windows installers are built and run on Windows only")
  #+win32 (%swap-half-bundles-are-refused :inno))

(test build-installer-refuses-a-bundle-with-one-of-the-core-and-the-runtime
  #-win32 (skip "build-installer.ps1 is run on Windows only")
  #+win32
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (progn
           (load (merge-pathnames "windows-launcher.lisp" *scripts*))
           (if (not (ignore-errors (uiop:symbol-call :ouranos-msvc :find-msvc)))
               (skip "No MSVC here")
               (let* ((runtime (%swap-runtime tree))
                      (bundle (%swap-bundle tree "0.0.4" 65536 runtime)))
                 (dolist (missing '("sbcl.core" "sbcl-runtime.exe"))
                   (let* ((half (%swap-half-bundle bundle tree missing))
                          ;; build-installer.ps1 reads the app and version from the directory name.
                          (named (merge-pathnames
                                  (format nil "~A-0.0.4-windows-x86-64/" +swap-app+)
                                  (merge-pathnames (format nil "named-~A/" (pathname-name missing)) tree))))
                     (ensure-directories-exist named)
                     (dolist (f (uiop:directory-files half))
                       (uiop:copy-file f (merge-pathnames (file-namestring f) named)))
                     (multiple-value-bind (out err code)
                         (uiop:run-program (list "pwsh" "-NoProfile" "-NonInteractive" "-File"
                                                 (uiop:native-namestring
                                                  (merge-pathnames "build-installer.ps1" *scripts*))
                                                 (uiop:native-namestring named) "-NoWebView2"
                                                 "-Out" (uiop:native-namestring
                                                         (merge-pathnames "refused.exe" tree)))
                                           :output :string :error-output :string :ignore-error-status t)
                       (let ((text (concatenate 'string out err)))
                         (is (not (eql 0 code)) "build-installer.ps1 refuses the bundle without ~A: exit ~A"
                             missing code)
                         (is (search "it is incomplete" text) "and says why: ~A" text)
                         (is-false (probe-file (merge-pathnames "refused.exe" tree))
                                   "and writes no installer"))))))))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))


;;; --- an uninstaller that cannot be placed, and an app that cannot be started (review of train 21)
;;;
;;; Each installer puts its uninstaller into <install>.new before the swap. A directory made with
;;; the uninstaller's name, as soon as the installer creates <install>.new, makes that fail: the
;;; update must stop before the swap with exit 2. And a silent update that installed the new
;;; version but could not start the app must exit 3 and keep the new version. A bundle with
;;; neither sbcl.core nor sbcl-runtime.exe skips the staged check, so an installer compiled from
;;; one with a program name the bundle does not have swaps in, then has nothing to start.

(defun %swap-squat-in-staged (dir name)
  "Start a thread that makes a directory NAME inside DIR.new as soon as DIR.new exists. Returns
a function that stops the thread and returns true when the directory was made."
  (let* ((staged (%swap-sibling dir ".new"))
         (squat (uiop:ensure-directory-pathname (merge-pathnames name staged)))
         (stop nil) (made nil)
         (thread (sb-thread:make-thread
                  (lambda ()
                    (loop until (or stop made)
                          do (if (and (uiop:directory-exists-p staged)
                                      (ignore-errors (ensure-directories-exist squat)))
                                 (setf made (and (uiop:directory-exists-p squat) t))
                                 (sleep 0.001))))
                  :name "squat in the staged copy")))
    (lambda ()
      (setf stop t)
      (sb-thread:join-thread thread :default nil)
      made)))

(defun %swap-failure-paths (format)
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (progn
           (load (merge-pathnames "windows-launcher.lisp" *scripts*))
           (cond
             ((not (ignore-errors (uiop:symbol-call :ouranos-msvc :find-msvc))) (skip "No MSVC here"))
             ((not (%swap-tool-path format))
              (skip "build-installer.ps1 -Check finds no ~A" (if (eq format :nsis) "makensis" "ISCC")))
             (t
              (let* ((runtime (%swap-runtime tree))
                     (dir (merge-pathnames "app/" tree))
                     (new (%swap-sibling dir ".new"))
                     (old (%swap-sibling dir ".old")))
                (multiple-value-bind (b1 v1-sha) (%swap-bundle tree "0.0.1" 65536 runtime)
                  ;; Version 2's core is large so that its extraction lasts long enough for the
                  ;; squat below to land before the uninstaller is written; NSIS writes a small
                  ;; bundle and swaps it in within milliseconds.
                  (let ((b2 (%swap-bundle tree "0.0.2" +swap-big-core-bytes+ runtime))
                        (v1 (and b1 (%swap-installer b1 format))))
                    (is-true (and v1 b2) "version 1's installer and version 2's bundle were built")
                    (when (and v1 b2)
                      (%with-temp-in ((merge-pathnames "temp/" tree))
                        (is (eql 0 (%swap-run (%swap-install-argv v1 format dir) :wait t))
                            "version 1 installs")
                        (%swap-wait-gone old)

                        ;; The uninstaller cannot be placed in the staged copy.
                        (let* ((v2 (%swap-installer b2 format))
                               (stop (%swap-squat-in-staged
                                      dir (ecase format (:nsis "uninstall.exe") (:inno "unins000.exe"))))
                               (code (and v2 (%swap-run (%swap-install-argv v2 format dir) :wait t)))
                               (made (funcall stop)))
                          (is-true v2 "version 2's installer was built")
                          (is-true made "a directory with the uninstaller's name was made in the staged copy")
                          (is (eql 2 code) "an update whose uninstaller cannot be placed exits 2: ~S" code))
                        (is (equal v1-sha (%swap-installed dir)) "and version 1 is still installed")
                        (is (eql 0 (%swap-launcher-check dir)) "as a pair the launcher accepts")
                        (is-false (uiop:directory-exists-p new) "with nothing staged left over")

                        ;; The app cannot be started after the swap.
                        (let* ((one-file (merge-pathnames "one-file/" tree))
                               (marker (merge-pathnames "one-file.txt" one-file)))
                          (ensure-directories-exist one-file)
                          (with-open-file (out marker :direction :output :if-exists :supersede)
                            (write-line "a bundle with no sbcl.core and no sbcl-runtime.exe" out))
                          (let ((installer (%swap-installer-direct
                                            one-file format
                                            (merge-pathnames (format nil "no-app-~(~A~).exe" format) tree)
                                            :exe "not-in-the-bundle.exe")))
                            (is-true installer "an installer naming a program the bundle lacks was compiled")
                            (when installer
                              (let ((code (%swap-run (%swap-install-argv installer format dir) :wait t)))
                                (is (eql 3 code) "an update that cannot start the app exits 3: ~S" code))
                              (is-true (probe-file (merge-pathnames "one-file.txt" dir))
                                       "and the new version is installed"))
                              (is-false (uiop:directory-exists-p new) "with nothing staged left over")))))))))))
      (%with-temp-in ((merge-pathnames "temp/" tree))
        (%swap-uninstall (merge-pathnames "app/" tree) format))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(test an-nsis-update-fails-before-the-swap-without-its-uninstaller-and-exits-3-when-the-app-cannot-start
  #-win32 (skip "The Windows installers are built and run on Windows only")
  #+win32 (%swap-failure-paths :nsis))

(test an-inno-update-fails-before-the-swap-without-its-uninstaller-and-exits-3-when-the-app-cannot-start
  #-win32 (skip "The Windows installers are built and run on Windows only")
  #+win32 (%swap-failure-paths :inno))
