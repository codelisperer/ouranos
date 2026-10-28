;;;; desktop-dialogs-tests.lisp --- the dialog call a page renders, checked as hyperion-view checks it (#986).
;;;;
;;;; These build the JSON and the onclick a page carries and never start hyperion-view. The checks
;;;; hyperion-view makes on the same request are in hyperion/view/tests.

(in-package #:hyperion/tests)

(def-suite desktop-dialogs :description "hyperion/desktop: the native dialogs' request (#986)." :in hyperion)
(in-suite desktop-dialogs)

(test dialog-request-json-writes-what-hyperion-view-reads
  (is (equal "{\"kind\":\"open\"}" (hyperion/desktop:dialog-request-json)))
  (is (equal "{\"kind\":\"save\",\"title\":\"Save as\",\"folder\":\"C:\\\\Users\",\"name\":\"a.txt\",\"filters\":[[\"Text\",\"*.txt;*.md\"],[\"All files\",\"*\"]]}"
             (hyperion/desktop:dialog-request-json
              :kind :save :title "Save as" :folder "C:\\Users" :name "a.txt"
              :filters '(("Text" "*.txt" "*.md") ("All files" "*")))))
  (is (equal "{\"kind\":\"open-many\"}" (hyperion/desktop:dialog-request-json :kind :open-many)))
  (is (equal "{\"kind\":\"folder\"}" (hyperion/desktop:dialog-request-json :kind :folder))))

(test dialog-request-json-escapes-so-it-can-sit-in-an-attribute-or-a-script
  (is (equal "{\"kind\":\"open\",\"title\":\"a\\\"b\\\\c\\u003c/script\\u003e\\u0026\\u0027\"}"
             (hyperion/desktop:dialog-request-json :title "a\"b\\c</script>&'")))
  (is (equal (format nil "{\"kind\":\"open\",\"title\":\"caf~C\"}" (code-char #xe9))
             (hyperion/desktop:dialog-request-json :title (format nil "caf~C" (code-char #xe9))))
      "a character past ASCII is written as itself, which hyperion-view reads as UTF-8"))

(test dialog-request-json-refuses-what-hyperion-view-would-refuse
  (flet ((refused (&rest request)
           (signals error (apply #'hyperion/desktop:dialog-request-json request))))
    (refused :kind :delete)
    (refused :kind "open")
    (refused :title (format nil "a~Cb" #\Tab))
    (refused :title (format nil "a~Cb" (code-char 127)))
    (refused :title (make-string 201 :initial-element #\a))
    (refused :title (make-string 101 :initial-element (code-char #xe9)))   ; 202 bytes
    (refused :title 12)
    (refused :folder (make-string 4097 :initial-element #\a))
    ;; A network share: opening the dialog there would send the user's credentials to its host.
    (refused :folder "\\\\server\\share")
    (refused :folder "//server/share")
    (refused :folder "/\\server")
    (refused :filters (list (list "Odd" (format nil "*.~C" (code-char #x212A)))))   ; KELVIN SIGN
    (refused :kind :open :name "a.txt")
    (refused :kind :save :name "dir/a.txt")
    (refused :kind :save :name "dir\\a.txt")
    (refused :kind :folder :filters '(("All" "*")))
    (refused :filters "*.txt")
    (refused :filters '("*.txt"))
    (refused :filters (loop repeat 33 collect '("All" "*")))
    (refused :filters '(("" "*")))
    (refused :filters '((nil "*")))
    (refused :filters '(("All")))
    (refused :filters (list (cons "Many" (loop for i below 33 collect (format nil "*.e~D" i)))))
    (dolist (pattern '("*." "a.txt" "*.t t" "*.*" "*.12345678901234567"))
      (refused :filters (list (list "Odd" pattern)))))
  (is (stringp (hyperion/desktop:dialog-request-json :folder "C:\\Users\\me" :filters '(("K" "*.K")))))
  (is (stringp (hyperion/desktop:dialog-request-json :folder "/home/me")))
  (is (stringp (hyperion/desktop:dialog-request-json
                :kind :save :name "a.txt" :title (make-string 200 :initial-element #\a)
                :filters (list (cons "Many" (loop for i below 32 collect (format nil "*.e~D" i))))))
      "and takes what is at each limit"))

(test dialog-onclick-shows-the-dialog-and-posts-the-choice
  (let ((js (hyperion/desktop:dialog-onclick "/import" :kind :open
                                             :filters '(("Databases" "*.accdb")))))
    (is (search "window.hyperionDialog({\"kind\":\"open\",\"filters\":[[\"Databases\",\"*.accdb\"]]})" js) "~A" js)
    (is (search "htmx.ajax('POST',\"/import\",{target:el," js) "~A" js)
    ;; Inside .then(function(r){...}), `this' is the window, so the button is taken first.
    (is (eql 0 (search "var el=this;" js)) "the button is taken before anything else: ~A" js)
    (is (null (search "target:this" js)) "and `this' is not used inside the promise: ~A" js)
    (is (search "{path:r.path}" js) "a single choice is posted as the field path: ~A" js)
    (is (search "{paths:JSON.stringify(r.paths)}" js) "several as the field paths: ~A" js)
    (is (search "if(window.hyperionDialog)" js) "and with no dialog it does nothing: ~A" js))
  (is (search "target:\"#result\""
              (hyperion/desktop:dialog-onclick "/import" :target "#result"))
      "a selector TARGET is a JSON string")
  (is (search "\"/a\\u0027b\""
              (hyperion/desktop:dialog-onclick "/a'b"))
      "the route is escaped too")
  (signals error (hyperion/desktop:dialog-onclick "/import" :kind :folder :filters '(("All" "*")))
    "a bad request is refused where the page is built"))

(test the-launcher-is-asked-for-dialogs-only-when-run-app-wants-them
  (is (equal '("--dialogs") (hyperion/desktop::%dialog-arguments t)))
  (is (null (hyperion/desktop::%dialog-arguments nil)))
  (is (eq #+win32 t #-win32 nil (hyperion/desktop::%dialog-platform-p))
      "only Windows shows a dialog in this change; macOS and Linux answer unavailable")
  (is-false (hyperion/desktop:dialogs-available-p) "with no window running, the page has no dialog"))
