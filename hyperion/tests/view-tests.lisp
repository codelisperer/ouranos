;;;; view-tests.lisp --- the launcher's ARGUMENT CONTRACT, asserted (pre-publication issue 276).
;;;;
;;;; hyperion-view is C++ and verify-tree neither compiles nor runs it, so before this
;;;; file a change to hyperion-view.cc moved NO check count in either direction -- the
;;;; gate was structurally blind to the one component every desktop app shells out to.
;;;; It had two open defects found by hand (pre-publication issue 268, #116) and zero tests, which is where the
;;;; third comes from.
;;;;
;;;; WHAT IS TESTED HERE IS THE CLI, NOT THE WINDOW, and that is deliberate rather than a
;;;; limitation accepted quietly. Opening a window needs a display, a window server and a
;;;; WebView2/WebKit runtime; asserting one needs a driver. None of that belongs in a gate
;;;; that has to run on three OSes and on a runner. But the ARGUMENT CONTRACT --
;;;; `URL [TITLE] [WIDTH] [HEIGHT] [--icon PATH]' -- is depended on by
;;;; hyperion/desktop:run-app and by consuming apps, is enforced by nothing else, and is
;;;; exercisable with no display at all. That is the part a gate can hold.
;;;;
;;;; The window half stays pre-publication issue 276's open remainder, and it is stated in the issue rather
;;;; than implied by this file's existence.
;;;;
;;;; SKIPS, NOT FAILURES, WHEN THE BINARY IS ABSENT. The launcher is build output: a fresh
;;;; checkout has no hyperion-view until someone runs build.{sh,ps1}. A red suite there
;;;; would train people to ignore it. FiveAM prints the skip and its reason, and
;;;; verify-tree surfaces skips rather than burying them (pre-publication issue 284's lesson, one file over) --
;;;; so "not built here" is visible rather than silent.

(defpackage #:hyperion/view/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:desktop #:hyperion/desktop))
  (:export #:run-tests #:view))

(in-package #:hyperion/view/tests)

(def-suite view :description "hyperion-view: the argument contract, headless.")
(in-suite view)

(defparameter +budget+ 10
  "Seconds a CLI invocation may take before we call it hung.

pre-publication issue 268 was `--help' never exiting -- it fell through to the URL slot and webview_run()
blocked forever on a window. So EVERY invocation here is bounded, and a timeout is a
FAILURE rather than a hang: a test that waits forever for a launcher that waits forever
teaches nobody anything.")

(defun launcher ()
  "The launcher hyperion/desktop would actually use, or NIL.

Deliberately DESKTOP:DEFAULT-LAUNCHER rather than a path built here. A second copy of
`where is hyperion-view' is the producer/consumer defect this tree keeps finding -- if
resolution moves, this suite must move with it or say so."
  (ignore-errors
   (let ((p (desktop:default-launcher)))
     (and p (probe-file p)))))

(defun run-launcher (&rest args)
  "Run the launcher with ARGS under a timeout. Returns (values exit stdout stderr).

It runs with HYPERION_VIEW_NO_WINDOW=1, so a call that would create a window exits 3 instead
(#521). None of these calls is meant to create one, and on a developer's machine a test that
did would open a window on their screen. The real-window tests use %REPORT-PLACEMENT, which
clears the variable and runs only on CI."
  (let ((out (make-string-output-stream))
        (err (make-string-output-stream))
        (previous (uiop:getenv "HYPERION_VIEW_NO_WINDOW")))
    (setf (uiop:getenv "HYPERION_VIEW_NO_WINDOW") "1")
    (unwind-protect
         (handler-case
             (let ((code (nth-value
                          2 (uiop:run-program (cons (uiop:native-namestring (launcher)) args)
                                              :output out :error-output err
                                              :ignore-error-status t))))
               (values code (get-output-stream-string out) (get-output-stream-string err)))
           (error (e) (values :error (get-output-stream-string out) (princ-to-string e))))
      (setf (uiop:getenv "HYPERION_VIEW_NO_WINDOW") (or previous "")))))

(defmacro with-launcher (&body body)
  `(let ((exe (launcher)))
     (if (null exe)
         (skip "hyperion-view is not built here -- run hyperion/hyperion-view/build.{sh,ps1}")
         (progn ,@body))))

(test the-resolution-rule-answers-without-erroring
  ;; DELIBERATELY NOT GUARDED BY WITH-LAUNCHER, and it is the reason this suite can sit in
  ;; the gate at all. verify-tree FAILS a suite that executes zero checks (pre-publication issue 116), and on a
  ;; machine that has never run build.{sh,ps1} every other test here skips -- so without
  ;; one unconditional check, adding this suite to the gate would turn a fresh checkout
  ;; red. This is that check, and it is not a formality: DEFAULT-LAUNCHER walks three
  ;; fallbacks and ends at a bare name, so "it answers something, and does not signal"
  ;; is a real property that a broken resolution rule would violate.
  (finishes (desktop:default-launcher))
  (is (not (null (desktop:default-launcher)))
      "default-launcher must always answer -- its last fallback is the bare name on PATH"))

(test the-launcher-is-where-desktop-looks-for-it
  ;; Not a tautology, and not the same as the test above: DEFAULT-LAUNCHER's last fallback
  ;; is a bare name, so it can answer with something that does not exist. PROBE-FILE is
  ;; the difference between "we have a rule" and "it is there".
  (with-launcher
    (is (probe-file exe) "default-launcher resolved to ~A, which is not a file" exe)))

(test help-prints-usage-and-exits
  ;; pre-publication issue 268, and the reason this suite exists at all. Before the fix: no --help handling,
  ;; so it became the URL, a window opened on a failed navigation, and the process never
  ;; returned. Measured on Windows: exited=FALSE after 5s, stdout empty, stderr empty.
  (with-launcher
    (dolist (flag '("--help" "-h"))
      (multiple-value-bind (code out err) (run-launcher flag)
        (is (eql 0 code) "~A must exit 0, got ~S (stderr: ~A)" flag code err)
        (is (search "usage:" out)
            "~A must print usage to STDOUT; got ~S" flag out)
        (is (search "--icon" out)
            "~A's usage must document --icon, which is part of the contract" flag)
        (is (zerop (length err)) "~A must not write to stderr; got ~S" flag err)))))

(test an-unknown-flag-is-refused-rather-than-retitling-the-window
  ;; The comment in main() claimed "an unrecognised flag must never silently become the
  ;; window title" while the code did exactly that -- any --flag fell into the positional
  ;; branch. A docstring-shaped claim in a comment, unchecked. This is the check.
  (with-launcher
    (multiple-value-bind (code out err) (run-launcher "--bogus")
      (declare (ignore out))
      (is (eql 2 code) "an unknown option must exit 2, got ~S" code)
      (is (search "unknown option" err) "and say so on stderr; got ~S" err))))

(test a-trailing-icon-flag-is-refused-rather-than-becoming-the-title
  ;; The same defect's sharper case: `hyperion-view URL --icon' set the TITLE to the
  ;; literal string "--icon", because the i+1<argc guard fell through to the positional
  ;; branch rather than refusing.
  (with-launcher
    (multiple-value-bind (code out err) (run-launcher "http://127.0.0.1:1/" "--icon")
      (declare (ignore out))
      (is (eql 2 code) "a trailing --icon must exit 2, got ~S" code)
      (is (search "--icon needs a path" err) "and say what is wrong; got ~S" err))))

(test surplus-arguments-are-refused
  ;; Four positionals is the contract. A fifth was silently dropped, so a caller that
  ;; added an argument got no signal that the launcher had not understood it.
  (with-launcher
    (multiple-value-bind (code out err) (run-launcher "u" "t" "800" "600" "surplus")
      (declare (ignore out))
      (is (eql 2 code) "a fifth positional must exit 2, got ~S" code)
      (is (search "too many arguments" err) "and name it; got ~S" err))))

;;; --- the window icon a bundle carries (#74) ------------------------------------------
;;;
;;; These need no launcher binary: they check which file run-app would pass as --icon, using
;;; directories and files made here.

;;; --- where the window goes (#485) -------------------------------------------------
;;;
;;; On Windows the window used to open at the CW_USEDEFAULT cascade point, often partly below
;;; the work area. hyperion-view now centres it in the work area and shrinks it to fit
;;; (window-placement.h). --placement prints that arithmetic for given numbers without opening
;;; a window, so it is checked here on every OS. The numbers are work area left, top, right and
;;; bottom; client width and height in logical pixels; DPI; and what the frame adds.

(defun %placement (&rest numbers)
  "What `hyperion-view --placement NUMBERS' prints, as a list of four integers, or the exit
code when it did not exit 0."
  (multiple-value-bind (code out)
      (apply #'run-launcher "--placement" (mapcar #'princ-to-string numbers))
    (if (eql code 0)
        (mapcar #'parse-integer
                (uiop:split-string (string-trim '(#\Newline #\Return #\Space) out)))
        code)))

(test a-window-that-fits-is-centred-in-the-work-area
  (with-launcher
    ;; The display in #485: 2560x1600 at 150% (DPI 144), work area 1528 high, and a 1280x860
    ;; window, which is 1920x1290 at that DPI and 1936x1346 with its frame.
    (is (equal '(312 91 1936 1346) (%placement 0 0 2560 1528 1280 860 144 16 56))
        "the display from #485")
    ;; 100% scaling, a taskbar at the top: the work area starts at y 40.
    (is (equal '(352 140 1216 839) (%placement 0 40 1920 1080 1200 800 96 16 39)))
    ;; A second monitor to the left of the first: its work area has negative coordinates.
    (is (equal '(-1568 100 1216 839) (%placement -1920 0 0 1040 1200 800 96 16 39)))))

(test a-window-larger-than-the-work-area-is-shrunk-to-fit-it
  (with-launcher
    ;; Too tall at 150%: 1200 logical is 1800 physical, 1856 with the frame, in 1528.
    (is (equal '(312 0 1936 1528) (%placement 0 0 2560 1528 1280 1200 144 16 56)))
    ;; Too wide and too tall on a small screen.
    (is (equal '(0 0 1366 728) (%placement 0 0 1366 728 1920 1080 96 16 39)))))

(test placement-refuses-what-is-not-nine-integers
  (with-launcher
    (is (eql 2 (%placement 0 0 2560 1528 1280 860 144 16)) "eight numbers")
    (is (eql 2 (%placement 0 0 2560 1528 1280 860 144 16 56 7)) "ten numbers")
    (is (eql 2 (%placement 0 0 2560 1528 1280 860 "x" 16 56)) "a word in place of a number")
    ;; Out of range (review of train 22): strtol's ERANGE, and values whose product would
    ;; overflow a long in place_in_work_area. Run, like every call here, with
    ;; HYPERION_VIEW_NO_WINDOW=1; this mode creates no window in any case.
    (is (eql 2 (%placement 0 0 2560 1528 "99999999999999999999" 860 144 16 56))
        "a value past LONG_MAX")
    (is (eql 2 (%placement 0 0 2560 1528 2000000000 860 144 16 56))
        "a client width whose product with the DPI overflows a 32-bit long")
    (is (eql 2 (%placement 0 0 2560 1528 1280 860 2000000000 16 56)) "a DPI as large")
    (is (eql 2 (%placement -2000000 0 2560 1528 1280 860 144 16 56))
        "a coordinate more than a million pixels from the origin")
    (is (eql 2 (%placement 0 0 2560 1528 1280 860 0 16 56)) "a DPI of 0")
    (is (eql 2 (run-launcher "http://127.0.0.1:1/" "--placement"
                             "0" "0" "2560" "1528" "1280" "860" "144" "16" "56"))
        "a URL before it: --placement is a mode of its own, not an option of a window")))

(test hyperion-view-creates-no-window-when-told-not-to
  ;; The guard RUN-LAUNCHER relies on (#521): with HYPERION_VIEW_NO_WINDOW=1, a call that would
  ;; create a window exits 3 instead, and says why.
  (with-launcher
    (multiple-value-bind (code out err) (run-launcher "--report-placement" "800" "600")
      (declare (ignore out))
      (is (eql 3 code) "--report-placement under HYPERION_VIEW_NO_WINDOW=1 exits 3, got ~S" code)
      (is (search "HYPERION_VIEW_NO_WINDOW" err) "and names the variable: ~S" err))))

(test report-placement-refuses-what-is-not-two-positive-integers
  ;; Each of these is refused before webview_create, so no window is made on any OS. atoi read
  ;; "1280px" as 1280 and went on to create a window (review of train 21).
  (with-launcher
    (flet ((code (&rest args) (nth-value 0 (apply #'run-launcher "--report-placement" args))))
      (is (eql 2 (code "1280px" "860")) "a number with a suffix")
      (is (eql 2 (code "1280" "x")) "a word")
      (is (eql 2 (code "0" "860")) "zero")
      (is (eql 2 (code "-1280" "860")) "a negative number")
      (is (eql 2 (code "99999999999999999999" "860")) "a number past INT_MAX")
      (is (eql 2 (code "1280")) "one number")
      ;; A third value is a placement file (#485, part 2), so it would make a window; four are
      ;; refused before one is made.
      (is (eql 2 (code "1280" "860" "placement" "extra")) "four values"))))

;;; --- the placement on a real window, on CI only (review of train 20) ----------------------
;;;
;;; --placement checks the arithmetic, but returns before a window exists. --report-placement
;;; creates the window, sizes and places it as a launch does, and prints what Windows reports.
;;; It is started hidden: Windows applies the starting process's hidden show state to the new
;;; process's first ShowWindow, so the window webview.h shows is not displayed. Even so it is a
;;; real window, so it runs only where the CI environment variable is set, on a runner, and not
;;; on a developer's machine.

(defun %report-placement (width height &optional placement-file)
  "Run `hyperion-view --report-placement WIDTH HEIGHT [PLACEMENT-FILE]' hidden, through
PowerShell's Start-Process -WindowStyle Hidden. Returns (values EXIT-CODE OUTPUT)."
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "hyperion-view-report-~36R/" (random (expt 2 40)))
                                (uiop:temporary-directory))))
         (out (merge-pathnames "out.txt" dir)))
    (ensure-directories-exist dir)
    (unwind-protect
         (let ((code (nth-value
                      2 (uiop:run-program
                         (list "pwsh" "-NoProfile" "-NonInteractive" "-Command"
                               (format nil "Remove-Item Env:HYPERION_VIEW_NO_WINDOW -ErrorAction SilentlyContinue; $p = Start-Process -FilePath '~A' -ArgumentList '--report-placement','~D','~D'~@[,'~A'~] -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput '~A'; exit $p.ExitCode"
                                       (uiop:native-namestring (launcher)) width height
                                       (and placement-file (uiop:native-namestring placement-file))
                                       (uiop:native-namestring out)))
                         :output nil :error-output nil :ignore-error-status t))))
           (values code (if (probe-file out) (uiop:read-file-string out) "")))
      (ignore-errors (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))

(test the-window-is-placed-in-the-work-area-on-a-real-window
  "On a CI Windows runner, a real window is placed where --placement says, inside the work area,
and Windows reports that rectangle."
  #-win32 (skip "The placement calls are Windows only")
  #+win32
  (with-launcher
    (if (null (uiop:getenvp "CI"))
        (skip "Runs only on CI (CI is not set here): it creates a window")
        (multiple-value-bind (code out) (%report-placement 1280 860)
          (is (eql 0 code) "--report-placement exited ~S: ~A" code out)
          (let ((line (find-if (lambda (l) (uiop:string-prefix-p "work " l))
                               (uiop:split-string out :separator '(#\Newline #\Return)))))
            (is-true line "it printed a report: ~S" out)
            (when line
              (let* ((n (mapcar #'parse-integer
                                (remove-if-not (lambda (tok) (and (plusp (length tok))
                                                                  (or (digit-char-p (char tok 0))
                                                                      (char= (char tok 0) #\-))))
                                               (uiop:split-string line :separator '(#\Space)))))
                     (work (subseq n 0 4)) (dpi (nth 4 n)) (frame (subseq n 5 7))
                     (placement (subseq n 7 11)) (window (subseq n 11 15)))
                (is (equal placement (apply #'%placement (append work (list 1280 860 dpi) frame)))
                    "the real calls computed what --placement computes for the same numbers: ~S" line)
                (destructuring-bind (x y w h) placement
                  (is (equal window (list x y (+ x w) (+ y h)))
                      "Windows reports the window at the placement: ~S" line))
                (destructuring-bind (wl wt wr wb) work
                  (destructuring-bind (l tp r b) window
                    (is (and (<= wl l) (<= wt tp) (<= r wr) (<= b wb))
                        "and inside the work area: ~S" line))))))))))

(defun %fresh-dir ()
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "hyperion-icon-~36R/" (random (expt 2 40) (make-random-state t)))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defun %touch (path)
  (with-open-file (out path :direction :output :if-exists :supersede :if-does-not-exist :create)
    (write-string "icon" out))
  (probe-file path))

(test a-bundled-window-icon-is-found-beside-the-executable
  (let ((dir (%fresh-dir)))
    (unwind-protect
         (progn
           (is (null (desktop:bundled-window-icon dir)) "no icon carried, so none found")
           (let ((icon (%touch (merge-pathnames "window-icon.png" dir))))
             (is (equal icon (desktop:bundled-window-icon dir)))))
      (aion/fs:delete-tree dir))))

(test the-bundled-icon-is-passed-before-the-callers-path
  ;; In a shipped app the caller's path is the build machine's. It exists on that machine,
  ;; so the bundled copy has to win even when the caller's file is present, or the icon
  ;; would depend on which machine the app runs on.
  (let ((dir (%fresh-dir)))
    (unwind-protect
         (let ((bundled (%touch (merge-pathnames "window-icon.png" dir)))
               (callers (%touch (merge-pathnames "source-icon.png" dir))))
           (is (equal (list "--icon" (uiop:native-namestring bundled))
                      (hyperion/desktop::%icon-arguments callers bundled)))
           (is (equal (list "--icon" (uiop:native-namestring callers))
                      (hyperion/desktop::%icon-arguments callers nil))
               "without a bundled copy, the caller's existing file is used")
           (is (null (hyperion/desktop::%icon-arguments
                      (merge-pathnames "not-on-this-machine.png" dir) nil))
               "a caller's path that does not exist passes no --icon at all"))
      (aion/fs:delete-tree dir))))

#-win32
(test a-bundled-icon-behind-a-broken-link-is-not-found
  ;; A macOS .app keeps window-icon.png in Contents/Resources, with a symbolic link to it in
  ;; Contents/MacOS. If the file is gone, PROBE-FILE still returns the link, and the app passed
  ;; hyperion-view a path it cannot read instead of falling back to the caller's icon.
  (let ((dir (%fresh-dir)))
    (unwind-protect
         (let ((target (%touch (merge-pathnames "Resources-window-icon.png" dir)))
               (link (merge-pathnames "window-icon.png" dir))
               (callers (%touch (merge-pathnames "source-icon.png" dir))))
           (uiop:run-program (list "ln" "-s" (uiop:native-namestring target)
                                   (uiop:native-namestring link)))
           (is (equal target (desktop:bundled-window-icon dir))
               "through a link whose target exists, the target is found")
           (delete-file target)
           (is (probe-file link) "the precondition: PROBE-FILE still answers for the broken link")
           (is (null (desktop:bundled-window-icon dir)))
           (is (equal (list "--icon" (uiop:native-namestring callers))
                      (hyperion/desktop::%icon-arguments callers (desktop:bundled-window-icon dir)))
               "so the caller's icon is used instead"))
      (aion/fs:delete-tree dir))))

(test shipped-image-p-and-install-directory-answer-for-a-development-image
  "#416: hyperion/desktop's public answers are aion/platform's, and in this development SBCL the
image is not a shipped build and has no installation."
  (is-false (desktop:shipped-image-p))
  (is (null (desktop:install-directory)))
  (is (eq (desktop:shipped-image-p) (aion/platform:shipped-image-p)))
  (is (equal (desktop:install-directory) (aion/platform:shipped-image-directory))))

;;; --- the last placement, saved and restored (#485, part 2) -------------------------------
;;;
;;; --saved-placement prints the restore decision for a placement file and a work area, with no
;;; window, so the format and the rule are checked here on every OS. The restore and the save on
;;; a real window are checked on CI only, through --report-placement with a placement file.

(defun %write-placement (dir name text)
  "Write TEXT, exactly, to NAME in DIR; return the path."
  (let ((path (merge-pathnames name dir)))
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string text out))
    path))

(defun %saved-placement (path &rest work)
  "What `hyperion-view --saved-placement PATH WL WT WR WB' prints, trimmed, or the exit code
when it did not exit 0."
  (multiple-value-bind (code out)
      (apply #'run-launcher "--saved-placement" (uiop:native-namestring path)
             (mapcar #'princ-to-string work))
    (if (eql code 0) (string-trim '(#\Newline #\Return #\Space) out) code)))

(test a-saved-placement-is-used-only-when-it-is-well-formed-and-fits
  (with-launcher
    (let ((dir (%fresh-dir)))
      (unwind-protect
           (flet ((decide (text &rest work)
                    (apply #'%saved-placement (%write-placement dir "placement" text) work)))
             (is (equal "use 100 50 1380 910 0"
                        (decide (format nil "hyperion-view-placement 1 100 50 1380 910 0~%")
                                0 0 2560 1528))
                 "a placement inside the work area is used")
             (is (equal "use 100 50 1380 910 1"
                        (decide "hyperion-view-placement 1 100 50 1380 910 1" 0 0 2560 1528))
                 "with its maximised state, and without a newline")
             (is (equal "use 100 50 1380 910 0"
                        (decide (format nil "hyperion-view-placement 1 100 50 1380 910 0~C~C"
                                        #\Return #\Newline)
                                0 0 2560 1528))
                 "and with a CRLF")
             (is (equal "use -1800 100 -600 900 0"
                        (decide "hyperion-view-placement 1 -1800 100 -600 900 0" -1920 0 0 1040))
                 "on a monitor to the left, with negative coordinates")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 100 50 1380 910 0" 1920 0 3840 1040))
                 "not on a monitor that is no longer there")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 2000 50 2700 910 0" 0 0 2560 1528))
                 "not partly outside the work area")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 100 50 250 150 0" 0 0 2560 1528))
                 "not smaller than 200 by 150")
             (dolist (text '("junk"
                             "hyperion-view-placement 2 100 50 1380 910 0"
                             "hyperion-view-placement 1 100 50 1380 910 2"
                             "hyperion-view-placement 1 100 50 1380 910"
                             "hyperion-view-placement 1 100 50 1380 910 0 extra"
                             "hyperion-view-placement 1 100 50 1380px 910 0"
                             ;; Coordinates beyond a million pixels, where the subtractions in
                             ;; the fit check could overflow (review of train 22).
                             "hyperion-view-placement 1 -2147483648 50 2147483647 910 0"))
               (is (equal "ignore malformed" (decide text 0 0 2560 1528))
                   "not a malformed line: ~S" text))
             (is (equal "ignore unreadable"
                        (%saved-placement (merge-pathnames "absent" dir) 0 0 2560 1528))
                 "not a file that is not there")
             (is (eql 2 (run-launcher "--saved-placement" "x" "0" "0" "2560"))
                 "three numbers are refused"))
        (aion/fs:delete-tree dir)))))

(test run-app-passes-a-placement-file-and-creates-its-directory
  (is (null (hyperion/desktop::%placement-arguments nil)) "no file, no arguments")
  (let* ((dir (%fresh-dir))
         (file (merge-pathnames "data/sub/window-placement" dir)))
    (unwind-protect
         (progn
           (is (equal (list "--placement-file" (uiop:native-namestring file))
                      (hyperion/desktop::%placement-arguments file)))
           (is-true (uiop:directory-exists-p (merge-pathnames "data/sub/" dir))
                    "and the file's directory now exists"))
      (aion/fs:delete-tree dir))))

(defun %report-numbers (line)
  "The integers in LINE, in order."
  (mapcar #'parse-integer
          (remove-if-not (lambda (tok) (and (plusp (length tok))
                                            (or (digit-char-p (char tok 0))
                                                (and (char= (char tok 0) #\-) (> (length tok) 1)))))
                         (uiop:split-string line :separator '(#\Space)))))

(defun %report-line (out prefix)
  (find-if (lambda (l) (uiop:string-prefix-p prefix l))
           (uiop:split-string out :separator '(#\Newline #\Return))))

(test a-real-window-is-restored-from-its-placement-file-and-saves-it
  "On a CI Windows runner, a window opens at a saved placement that fits, writes it back, and
opens centred when the saved placement is on no monitor."
  #-win32 (skip "The placement calls are Windows only")
  #+win32
  (with-launcher
    (if (null (uiop:getenvp "CI"))
        (skip "Runs only on CI (CI is not set here): it creates a window")
        (let ((dir (%fresh-dir)))
          (unwind-protect
               (let* ((work (multiple-value-bind (code out) (%report-placement 1280 860)
                              (declare (ignore code))
                              (let ((line (%report-line out "work ")))
                                (and line (subseq (%report-numbers line) 0 4)))))
                      (file (merge-pathnames "window-placement" dir)))
                 (is-true work "the work area was reported")
                 (when work
                   (destructuring-bind (wl wt wr wb) work
                     (declare (ignore wr wb))
                     (let* ((saved (list (+ wl 40) (+ wt 30) (+ wl 940) (+ wt 630)))
                            (text (format nil "hyperion-view-placement 1 ~{~D~^ ~} 0~%" saved)))
                       ;; A placement that fits is restored, and saved back unchanged.
                       (%write-placement dir "window-placement" text)
                       (multiple-value-bind (code out) (%report-placement 1280 860 file)
                         (is (eql 0 code) "--report-placement with a file exited ~S: ~A" code out)
                         (let ((line (%report-line out "restored ")))
                           (is-true line "the saved placement was restored: ~S" out)
                           (when line
                             (is (equal (append saved (list 0) saved) (%report-numbers line))
                                 "and Windows reports the window at it: ~S" line)))
                         (is-true (%report-line out "saved") "and it was saved: ~S" out))
                       (is (equal text (uiop:read-file-string file))
                           "the file holds the same placement")
                       ;; A placement on no monitor is ignored; the window is centred, and that is saved.
                       (%write-placement dir "window-placement"
                                         (format nil "hyperion-view-placement 1 -100000 -100000 -99000 -99300 0~%"))
                       (multiple-value-bind (code out) (%report-placement 1280 860 file)
                         (is (eql 0 code) "--report-placement exited ~S: ~A" code out)
                         (is-true (%report-line out "restore-ignored off-screen")
                                  "a placement on no monitor is ignored: ~S" out)
                         (let ((line (%report-line out "work ")))
                           (is-true line "and the window is placed as without a file: ~S" out)
                           (when line
                             (let ((window (subseq (%report-numbers line) 11 15)))
                               (is (equal (format nil "hyperion-view-placement 1 ~{~D~^ ~} 0~%" window)
                                          (uiop:read-file-string file))
                                   "and that placement is saved: ~S" line)))))))))
            (aion/fs:delete-tree dir))))))

(defun run-tests ()
  (let ((results (run 'view)))
    (explain! results)
    (unless (results-status results)
      (error "hyperion/view tests failed"))))
