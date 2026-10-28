;;;; missing-natives.lisp --- what build-desktop-app.lisp does about a native file it should carry
;;;; and cannot find (#956)
;;;;
;;;; scripts/missing-natives.lisp decides, with no I/O, whether a file is carried, not needed,
;;;; refused or allowed to be missing. These tests check every case of that decision, the option
;;;; that allows a missing file, and the summary line. A real build that stops, and one that goes on
;;;; with the option, are shown on #956's pull request: each loads a whole desktop app, and the
;;;; refusal needs a tree whose hyperion-view is not built, which a CI leg that builds it is not.

(in-package #:checkers/tests)

;;; FiveAM's current suite does not carry over from one file to the next (see dump-image.lisp).
(in-suite checkers)

;;; At compile time too: the tests below name the package it defines.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames "missing-natives.lisp" *scripts*)))

(test a-missing-native-file-the-bundle-needs-stops-the-build-unless-allowed
  "#956: hyperion-view, or a library the runtime links against, that the bundle needs and that is
not there is refused, which stops the build. With --allow-missing-natives it is allowed and the
build goes on. A file that is there is carried either way."
  (is (eq :refuse (ouranos-missing-natives:decide :needed t :present nil :allow nil)))
  (is (eq :allowed-missing (ouranos-missing-natives:decide :needed t :present nil :allow t)))
  (is (eq :carry (ouranos-missing-natives:decide :needed t :present t :allow nil)))
  (is (eq :carry (ouranos-missing-natives:decide :needed t :present t :allow t))))

(test a-native-file-the-bundle-does-not-need-is-not-refused
  "#956: an app that does not load hyperion/desktop opens no window, so a missing hyperion-view is
not refused, with or without the option. That is the case of the sqlite and uv probes."
  (dolist (present '(nil t))
    (dolist (allow '(nil t))
      (is (eq :not-needed (ouranos-missing-natives:decide :needed nil :present present
                                                          :allow allow))
          "present ~S, allow ~S" present allow))))

(test only-the-exact-option-allows-a-missing-native
  (is-true (ouranos-missing-natives:allow-missing-p
            '("--system" "x" "--allow-missing-natives" "--name" "y")))
  (is-false (ouranos-missing-natives:allow-missing-p '("--system" "x" "--name" "y")))
  (is-false (ouranos-missing-natives:allow-missing-p '("--allow-missing-native"))
            "a misspelling is not the option")
  (is-false (ouranos-missing-natives:allow-missing-p '("--name" "--allow-missing-natives-x"))))

(test the-refusal-names-the-file-where-it-was-looked-for-and-the-command-that-builds-it
  "#963's review: the message the build stops with names the missing file, the path it looked
at, the command that builds it, and the option that lets a build go on without it. The message
for a build that goes on names the file and the option."
  (let ((refusal (ouranos-missing-natives:refusal-message
                  "hyperion-view" "C:/tree/hyperion/hyperion-view/hyperion-view.exe"
                  "powershell -File hyperion/hyperion-view/build.ps1")))
    (is (search "hyperion-view is missing at C:/tree/hyperion/hyperion-view/hyperion-view.exe." refusal)
        "~A" refusal)
    (is (search "Build it first:" refusal) "~A" refusal)
    (is (search "  powershell -File hyperion/hyperion-view/build.ps1" refusal) "~A" refusal)
    (is (search "pass --allow-missing-natives." refusal) "~A" refusal))
  (let ((allowed (ouranos-missing-natives:allowed-message "libzstd.1.dylib" "/opt/lib/libzstd.1.dylib")))
    (is (search "libzstd.1.dylib is missing at /opt/lib/libzstd.1.dylib; going on without it" allowed)
        "~A" allowed)
    (is (search "as --allow-missing-natives asks" allowed) "~A" allowed)))

(test the-summary-line-counts-and-names-what-is-missing
  (is (search "no native file" (ouranos-missing-natives:missing-summary '())))
  (let ((one (ouranos-missing-natives:missing-summary '("hyperion-view"))))
    (is (search "1 native file the bundle needs is missing" one) "~A" one)
    (is (search "--allow-missing-natives: hyperion-view." one) "~A" one))
  (let ((two (ouranos-missing-natives:missing-summary '("hyperion-view" "libzstd.1.dylib"))))
    (is (search "2 native files the bundle needs are missing" two) "~A" two)
    (is (search "hyperion-view, libzstd.1.dylib." two) "~A" two)))
