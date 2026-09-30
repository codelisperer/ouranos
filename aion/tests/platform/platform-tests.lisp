;;;; platform-tests.lisp --- the spelling table, checked rather than assumed.
;;;;
;;;; The failure this guards against is silent and permanent: a client whose key disagrees
;;;; with the manifest's misses the lookup and reports itself UP TO DATE FOREVER. There is no
;;;; error to notice and nobody reports that something did not happen.
;;;;
;;;; So the table is tested across values this machine cannot produce. NORMALIZE-ARCH and
;;;; PLATFORM-KEY both take the architecture as an argument for exactly that reason -- a suite
;;;; that only checked the host it runs on would assert two thirds of the table and check one.

(in-package #:aion/platform/tests)

(def-suite all :description "The platform key, and the spellings it must absorb.")
(in-suite all)

;;; --- the spellings, measured from real implementations -------------------------

(test every-known-spelling-of-x86-64-normalises
  "The values that actually occur. :X64 is SBCL on Windows and :X86-64 is SBCL on Linux --
the same machine, two spellings, and the difference is the entire bug."
  (dolist (spelling '(:x64 :x86-64 "x86_64" "amd64" "X64" "AMD64"))
    (is (string= "x86-64" (plat:normalize-arch spelling))
        "~S normalised to ~S" spelling (plat:normalize-arch spelling))))

(test every-known-spelling-of-arm64-normalises
  (dolist (spelling '(:arm64 :aarch64 "ARM64" "aarch64"))
    (is (string= "arm64" (plat:normalize-arch spelling))
        "~S normalised to ~S" spelling (plat:normalize-arch spelling))))

(test thirty-two-bit-spellings-normalise
  (dolist (spelling '(:x86 "i386" "i686"))
    (is (string= "x86" (plat:normalize-arch spelling)))))

(test nil-falls-back-to-machine-type
  "SBCL on Apple silicon returns NIL from UIOP:ARCHITECTURE. Falling back to MACHINE-TYPE is
what makes macos-arm64 derivable at all -- and on this host the fallback must still produce
the host's own answer rather than an error."
  (is (string= (plat:normalize-arch (machine-type)) (plat:normalize-arch nil))))

(test an-unknown-architecture-passes-through-named
  "Deliberately wider than the platforms anyone builds for. An unverified host should reach
the allow-list with a NAMED key to be refused by, rather than a mystery string flowing onward
into a bundle directory name."
  (is (string= "sparc64" (plat:normalize-arch :sparc64))))

;;; --- the key itself -------------------------------------------------------------

(test the-key-is-os-dash-arch
  (is (string= (format nil "~A-x86-64" (plat:host-os-name)) (plat:platform-key :x64)))
  (is (string= (format nil "~A-arm64" (plat:host-os-name)) (plat:platform-key :aarch64))))

(test windows-and-linux-agree-despite-reporting-differently
  "THE BUG, STATED DIRECTLY. SBCL says :X64 on Windows and :X86-64 on Linux for the same
architecture. If those produced different keys, an update built on one would be invisible to
the other -- which is precisely what happened when the client derived its own."
  (is (string= (plat:normalize-arch :x64) (plat:normalize-arch :x86-64))))

(test this-host-produces-a-key-in-the-manifest-vocabulary
  (let ((key (plat:platform-key)))
    (is (find #\- key) "~S does not look like <os>-<arch>" key)
    (is-true (member (plat:host-os-name) '("windows" "macos" "linux") :test #'string=))))

;;; --- the allow-list ---------------------------------------------------------------

(test the-verified-set-is-exactly-the-release-matrix
  "It is checked against .github/workflows/desktop-release.yml by hand today. Pinned here so
a change to either is a change someone made rather than a drift someone did not notice."
  (is (equal '("linux-x86-64" "windows-x86-64" "macos-arm64") plat:*verified-platforms*)))

(test verified-platform-p-answers-for-every-entry
  (dolist (p plat:*verified-platforms*)
    (is-true (plat:verified-platform-p p))))

(test the-platforms-nobody-has-built-are-refused
  "windows-arm64 is the live case: derivable, plausible, and never once executed."
  (dolist (p '("windows-arm64" "linux-arm64" "macos-x86-64" "" "windows"))
    (is-false (plat:verified-platform-p p) "~S should not be a verified platform" p)))

(test every-verified-platform-is-something-the-key-could-produce
  "An allow-list entry the key generator can never emit is a typo that nothing would catch:
the guard would refuse a host it was written to permit."
  (dolist (p plat:*verified-platforms*)
    (let* ((dash (position #\- p))
           (os (subseq p 0 dash))
           (arch (subseq p (1+ dash))))
      (is-true (member os '("windows" "macos" "linux") :test #'string=)
               "~S has an OS half ~S that HOST-OS-NAME never returns" p os)
      (is (string= arch (plat:normalize-arch arch))
          "~S has an arch half ~S that NORMALIZE-ARCH would rewrite to ~S"
          p arch (plat:normalize-arch arch)))))

;;; --- where this executable lives (pre-publication issue 335) --------------------------------------
;;;
;;; MACOS-APP-BUNDLE is the half that can be tested from any image, because it is a pure
;;; function of a pathname. EXECUTABLE-DIRECTORY and the install-directory it feeds cannot
;;; be: they answer a question about the RUNNING image, and this suite runs in a dev image
;;; where the honest answer is "SBCL's own bin". Asserting against a constructed path here
;;; would be a producer verifying its own output -- the fixture would build the path the
;;; same way the code does and agree with itself on a machine where the real answer is
;;; different. That direction is verified against a dumped executable instead; see pre-publication issue 335.

(test a-mac-app-bundle-is-recognised-by-its-ancestry
  "The shape scripts/build-dmg.sh produces: the bundle copied verbatim into
Contents/MacOS, so the install location is the .app the image sits inside."
  (if (uiop:os-macosx-p)
      (is (equal #P"/Applications/Foo.app/"
                 (plat:macos-app-bundle "/Applications/Foo.app/Contents/MacOS/")))
      (is-false (plat:macos-app-bundle "/Applications/Foo.app/Contents/MacOS/")
                "off macOS there is no .app to find")))

(test a-plain-bundle-directory-is-not-a-mac-app
  "The shape scripts/build-desktop-app.lisp produces. Returning a .app here would name a
directory that does not exist, which is worse than returning nothing."
  (is-false (plat:macos-app-bundle "/Users/x/dist/coalton-repl-0.1.0-macos-arm64/")))

(test the-ancestry-test-requires-every-component
  "Both directions of the check, because a test that only feeds it real bundles cannot see
an over-match -- and an over-match names a parent directory an updater would replace."
  (dolist (near '("/Users/x/Contents/MacOS/"          ; Contents/MacOS, no .app above
                  "/Applications/Foo.app/MacOS/"      ; .app, no Contents
                  "/Applications/Foo.app/Contents/"   ; stops short of MacOS
                  "/Applications/Foo/Contents/MacOS/" ; not a .app, just a directory
                  "/Applications/Foo.app/Contents/MacOS/nested/"))
    (is-false (plat:macos-app-bundle near)
              "~S is not a bundle the image sits directly inside" near)))

(test executable-directory-is-absolute-when-it-answers-at-all
  "The weak assertion this image can honestly make. The STRONG one -- that the path is
where the running executable actually is -- needs a dumped executable and is verified
against one in pre-publication issue 335, because a dev image's honest answer is SBCL's own bin."
  (let ((d (plat:executable-directory)))
    (when d
      (is-true (uiop:absolute-pathname-p d))
      (is-true (null (pathname-name d)) "a directory, not a file"))))

;;; --- is this a shipped build, and where is it (#416) ---------------------------------------
;;;
;;; These two tests were hyperion/update's while the rule was private to it.

(test a-shipped-build-is-one-file-or-a-macos-app-with-sbcl-core-beside-its-runtime
  "#98: a macOS build is a launcher, the runtime `sbcl' and `sbcl.core' in a bundle's
Contents/MacOS, so the runtime and core paths differ. Without the second rule the updater took
it for a developer's REPL and found no install directory. Everything else with a core beside
its runtime must still read as a REPL, or an update could be applied into SBCL's own
installation: Windows' installer keeps sbcl.exe and sbcl.core in one directory."
  (flet ((shipped (runtime core &key macos)
           (plat:shipped-image-p :runtime runtime :core core :macos macos :windows nil)))
    (is-true (shipped "/Applications/Foo.app/Contents/MacOS/foo"
                      "/Applications/Foo.app/Contents/MacOS/foo")
             "one dumped file, on any platform")
    (is-true (shipped "/Applications/Foo.app/Contents/MacOS/sbcl"
                      "/Applications/Foo.app/Contents/MacOS/sbcl.core" :macos t)
             "the macOS .app")
    (is-false (shipped "/Applications/Foo.app/Contents/MacOS/sbcl"
                       "/Applications/Foo.app/Contents/MacOS/sbcl.core" :macos nil)
              "the same paths are not a shipped shape off macOS")
    (is-false (shipped "C:/Program Files/Steel Bank Common Lisp/sbcl.exe"
                       "C:/Program Files/Steel Bank Common Lisp/sbcl.core" :macos nil)
              "Windows' SBCL installation")
    (is-false (shipped "/opt/homebrew/Cellar/sbcl/2.6.8/libexec/bin/sbcl"
                       "/opt/homebrew/Cellar/sbcl/2.6.8/lib/sbcl/sbcl.core" :macos t)
              "Homebrew's SBCL")
    (is-false (shipped "/opt/sbcl/bin/sbcl" "/opt/sbcl/bin/sbcl.core" :macos t)
              "a hand-built SBCL on macOS with its core beside the runtime")
    (is-false (shipped "/tmp/dist/foo-1.0.0-macos-arm64/sbcl"
                       "/tmp/dist/foo-1.0.0-macos-arm64/sbcl.core" :macos t)
              "the raw bundle directory the build writes, which is not shipped")
    (is-false (shipped "/Applications/Foo.app/Contents/MacOS/sbcl"
                       "/Applications/Foo.app/Contents/MacOS/other.core" :macos t)
              "a core under another name")
    (is-false (shipped "/Applications/Foo.app/Contents/MacOS/sbcl"
                       "/Applications/Bar.app/Contents/MacOS/sbcl.core" :macos t)
              "sbcl.core in another bundle")
    (is-false (shipped nil nil :macos t))))

(test a-windows-build-is-sbcl-runtime-exe-with-sbcl-core-beside-it
  "#98: a Windows build is <name>.exe (a launcher), sbcl-runtime.exe and sbcl.core in one
directory, so the runtime and core paths differ. SBCL's own Windows installation also keeps a
runtime and sbcl.core together, as sbcl.exe, and must still read as a REPL, or an update could
be applied into SBCL's directory."
  (flet ((shipped (runtime core &key (windows t))
           (plat:shipped-image-p :runtime runtime :core core :macos nil :windows windows)))
    (is-true (shipped "C:/Users/me/AppData/Local/Programs/Foo/sbcl-runtime.exe"
                      "C:/Users/me/AppData/Local/Programs/Foo/sbcl.core")
             "the installed Windows build")
    (is-true (shipped "C:/Users/me/AppData/Local/Programs/Foo/SBCL-Runtime.EXE"
                      "c:/users/me/appdata/local/programs/foo/sbcl.core")
             "Windows paths compare without regard to case")
    (is-false (shipped "C:/Program Files/Steel Bank Common Lisp/sbcl.exe"
                       "C:/Program Files/Steel Bank Common Lisp/sbcl.core")
              "SBCL's own installation")
    (is-false (shipped "C:/Users/me/AppData/Local/Programs/Foo/sbcl-runtime.exe"
                       "C:/Users/me/AppData/Local/Programs/Bar/sbcl.core")
              "sbcl.core in another directory")
    (is-false (shipped "C:/Users/me/AppData/Local/Programs/Foo/sbcl-runtime.exe"
                       "C:/Users/me/AppData/Local/Programs/Foo/other.core")
              "a core under another name")
    (is-false (shipped "C:/Users/me/AppData/Local/Programs/Foo/sbcl-runtime.exe"
                       "D:/Users/me/AppData/Local/Programs/Foo/sbcl.core")
              "the same directory names on another drive")
    (is-false (shipped "/opt/foo/sbcl-runtime.exe" "/opt/foo/sbcl.core" :windows nil)
              "the Windows shape is not a shipped build off Windows")))

(test the-core-equals-runtime-rule-misreads-both-split-layouts
  "#416's control: an app without the updater compared *CORE-PATHNAME* with *RUNTIME-PATHNAME*,
the rule for a one-file image, and a real macOS or Windows bundle failed it. SHIPPED-IMAGE-P
answers true for the same two pairs."
  (let ((pairs '(("/Applications/Foo.app/Contents/MacOS/sbcl"
                  "/Applications/Foo.app/Contents/MacOS/sbcl.core" :macos)
                 ("C:/Users/me/AppData/Local/Programs/Foo/sbcl-runtime.exe"
                  "C:/Users/me/AppData/Local/Programs/Foo/sbcl.core" :windows))))
    (loop for (runtime core os) in pairs
          do (is-false (equal runtime core) "the old rule says ~A is not shipped" os)
             (is-true (plat:shipped-image-p :runtime runtime :core core
                                            :macos (eq os :macos) :windows (eq os :windows))
                      "SHIPPED-IMAGE-P says the ~A bundle is shipped" os))))

(test a-development-image-is-not-shipped-and-has-no-shipped-directory
  "This suite runs in a development SBCL, whose runtime and core are SBCL's own files."
  (is-false (plat:shipped-image-p))
  (is (null (plat:shipped-image-directory))))
