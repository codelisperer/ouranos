;;;; desktop-dialogs.lisp --- native open, save-as and folder dialogs for a desktop app (#986).
;;;;
;;;; hyperion-view shows the dialog, owned by its window, when the app's page calls
;;;; window.hyperionDialog(request); the page receives the chosen path and posts it to one of the
;;;; app's routes. This file renders that call for a page and checks its arguments, with the same
;;;; limits hyperion-view applies (hyperion/hyperion-view/dialog-request.h), so a mistake is a Lisp
;;;; error where the page is built rather than a refusal in the user's window.
;;;;
;;;; THE PAGE RECEIVES THE PATH. A file path says something about the user's machine, and the
;;;; page's own script gets it. hyperion-view offers the function only to the app's own origin, in
;;;; the top-level frame, and only during a user action where the webview can tell. An app that
;;;; shows third-party content in its window should still run with RUN-APP :DIALOGS NIL.

(in-package #:hyperion/desktop)

;;; --- checking a request -------------------------------------------------------------------

(defparameter +dialog-kinds+ '(:open :open-many :save :folder))

(defun %dialog-refuse (control &rest args)
  (error "hyperion/desktop: ~?" control args))

(defun %dialog-text (what text max)
  (unless (stringp text) (%dialog-refuse "~A must be a string, not ~S" what text))
  (when (> (length (sb-ext:string-to-octets text :external-format :utf-8)) max)
    (%dialog-refuse "~A is longer than ~D bytes" what max))
  (when (find-if (lambda (c) (let ((code (char-code c))) (or (< code 32) (= code 127)))) text)
    (%dialog-refuse "~A holds a control character" what))
  text)

(defun %dialog-pattern-p (pattern)
  "\"*\", or \"*.\" and 1 to 16 letters, digits, _, + or -."
  (and (stringp pattern)
       (or (string= pattern "*")
           (and (<= 3 (length pattern) 18)
                (string= "*." (subseq pattern 0 2))
                (every (lambda (c) (or (and (char<= #\a (char-downcase c) #\z)) (char<= #\0 c #\9)
                                       (find c "_+-")))
                       (subseq pattern 2))))))

(defun %check-dialog-request (kind title filters folder name)
  (unless (member kind +dialog-kinds+)
    (%dialog-refuse "the dialog KIND must be one of ~{~S~^, ~}, not ~S" +dialog-kinds+ kind))
  (when title (%dialog-text "the dialog's TITLE" title 200))
  (when folder (%dialog-text "the dialog's FOLDER" folder 4096))
  (when name
    (unless (eq kind :save) (%dialog-refuse "NAME is for a :SAVE dialog only"))
    (%dialog-text "the dialog's NAME" name 260)
    (when (find-if (lambda (c) (find c "/\\")) name)
      (%dialog-refuse "NAME is a file name, not a path: ~S" name)))
  (when filters
    (when (eq kind :folder) (%dialog-refuse "a :FOLDER dialog takes no FILTERS"))
    (unless (and (listp filters) (<= (length filters) 32))
      (%dialog-refuse "FILTERS must be a list of at most 32 filters"))
    (dolist (filter filters)
      (destructuring-bind (label &rest patterns)
          (if (consp filter) filter (%dialog-refuse "a filter is (LABEL PATTERN ...), not ~S" filter))
        (unless (and (stringp label) (plusp (length label)))
          (%dialog-refuse "a filter's LABEL must be a non-empty string, not ~S" label))
        (%dialog-text "a filter's LABEL" label 100)
        (unless (and patterns (<= (length patterns) 32) (every #'%dialog-pattern-p patterns))
          (%dialog-refuse "a filter's patterns must be 1 to 32 of \"*\" or \"*.EXT\", not ~S" patterns))))))

;;; --- rendering the call -------------------------------------------------------------------

(defun %json-string (text)
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for c across text
          for code = (char-code c)
          do (cond ((char= c #\") (write-string "\\\"" out))
                   ((char= c #\\) (write-string "\\\\" out))
                   ;; < and > as escapes too, so the JSON can sit inside an HTML attribute or a
                   ;; script element without closing either.
                   ((or (< code 32) (char= c #\<) (char= c #\>) (char= c #\&) (char= c #\'))
                    (format out "\\u~(~4,'0x~)" code))
                   (t (write-char c out))))
    (write-char #\" out)))

(defun dialog-request-json (&key (kind :open) title filters folder name)
  "The request object WINDOW.HYPERIONDIALOG takes, as JSON, after checking it.

KIND is :OPEN, :OPEN-MANY, :SAVE or :FOLDER. TITLE is the dialog's title. FILTERS is a list of
(LABEL PATTERN ...), each PATTERN \"*\" or \"*.EXT\", such as ((\"Databases\" \"*.accdb\" \"*.mdb\")
(\"All files\" \"*\")); a :FOLDER dialog takes none. FOLDER is where it opens; without it, the
folder last used for that KIND, else Documents. NAME is a :SAVE dialog's suggested file name.
Signals an error for anything hyperion-view would refuse."
  (%check-dialog-request kind title filters folder name)
  (with-output-to-string (out)
    (format out "{\"kind\":~A" (%json-string (string-downcase (symbol-name kind))))
    (when title (format out ",\"title\":~A" (%json-string title)))
    (when folder (format out ",\"folder\":~A" (%json-string folder)))
    (when name (format out ",\"name\":~A" (%json-string name)))
    (when filters
      (format out ",\"filters\":[~{~A~^,~}]"
              (mapcar (lambda (f)
                        (format nil "[~A,~A]" (%json-string (first f))
                                (%json-string (format nil "~{~A~^;~}" (rest f)))))
                      filters)))
    (write-char #\} out)))

(defun dialog-onclick (post &rest request &key (kind :open) title filters folder name
                                               (target "this"))
  "JavaScript for a button's onclick: show the dialog REQUEST describes (see DIALOG-REQUEST-JSON)
and, when the user chooses, post the choice to the app's route POST with htmx, swapping the
answer into TARGET (a CSS selector, or \"this\"). The route receives the field `path`, or for
:OPEN-MANY the field `paths`, a JSON array of paths. Nothing is posted on cancel. When the page
has no dialog (see DIALOGS-AVAILABLE-P), the handler does nothing, so render a pasted-path field
for that case.

THE PAGE RECEIVES THE PATH; see this file's header."
  (declare (ignore kind title filters folder name))
  (let ((json (apply #'dialog-request-json (loop for (k v) on request by #'cddr
                                                 unless (eq k :target) append (list k v)))))
    (format nil "if(window.hyperionDialog){window.hyperionDialog(~A).then(function(r){if(r&&(r.path||r.paths)){htmx.ajax('POST',~A,{target:~A,values:r.paths?{paths:JSON.stringify(r.paths)}:{path:r.path}});}});}"
            json (%json-string post)
            (if (string= target "this") "this" (%json-string target)))))
