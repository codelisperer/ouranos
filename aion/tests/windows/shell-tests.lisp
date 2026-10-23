;;;; shell-tests.lisp --- SYSTEM-WINDOWS-DIRECTORY and SHELL-OPEN (#820).
;;;;
;;;; SHELL-OPEN is not called with a real target here, because that would open a browser or
;;;; another program on the machine running the tests. hades/open's tests check which target it
;;;; is given.

(in-package #:aion/windows/tests)

(def-suite shell :description "The Windows directory, and opening a URL." :in all)
(in-suite shell)

(test the-windows-directory-is-absolute-and-holds-explorer
  (let ((directory (w:system-windows-directory)))
    (is (stringp directory))
    (is (and (> (length directory) 3)
             (char= #\: (char directory 1))
             (char= #\\ (char directory 2)))
        "A drive-letter path: ~S" directory)
    (is (char/= #\\ (char directory (1- (length directory))))
        "No trailing separator: ~S" directory)
    (is (probe-file (uiop:parse-native-namestring
                     (concatenate 'string directory "\\explorer.exe")))
        "explorer.exe is in ~S" directory)))

(test shell-open-takes-a-string
  (signals type-error (w:shell-open 42))
  (signals type-error (w:shell-open nil)))
