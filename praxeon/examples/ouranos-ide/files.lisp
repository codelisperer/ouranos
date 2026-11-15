;;;; files.lisp --- the project's file tree window and the editor's file tabs (#1228).
;;;;
;;;; THE FILES WINDOW opens a folder as the project (project.lisp) and shows its tree. A folder
;;;; expands or collapses when it is clicked, and a file opens in the editor window when it is
;;;; clicked. Hidden files and build output (.git, compiled Lisp, node_modules) are left out
;;;; until "Show hidden" is pressed. A form at the bottom makes a new file, which is then
;;;; opened, or a new folder.
;;;;
;;;; THE EDITOR WINDOW's tabs. The editor keeps its scratch buffer, the one it had before, as
;;;; its first tab, and one tab per open file after it. Each file's tab holds its own CodeMirror
;;;; editor in an element marked data-ou-preserve, so a pushed body keeps what was typed in
;;;; every tab, shown or not. The page marks a tab whose editor holds text that differs from
;;;; what was last read or saved; the server does not see typing.
;;;;
;;;; Save (the button, or Mod-S in the editor) sends the shown file's text. The server compares
;;;; the file on disk with what it read or last saved; when they differ, it asks whether to
;;;; overwrite, to reload from disk, or to keep editing, and writes nothing until it is told.
;;;; Otherwise it writes the text to a temporary file in the same folder and renames that over
;;;; the file (project.lisp, ATOMIC-WRITE-FILE). Closing a tab sends its text too, and when it
;;;; has changes that were not saved the server asks before closing it.
;;;;
;;;; The questions are answered in the window, with buttons, not with the browser's dialogs.
;;;;
;;;; Tabs, opening, closing and switching change the editor window's body, which is sent to the
;;;; page by hyperion/desktop-ui's push (UI:WINDOW-CHANGED). The answer to the request itself is
;;;; only the status line.

(cl:in-package #:praxeon/examples/ouranos-ide)

(declaim (notinline render-files files-open-project files-toggle files-open files-new-file
                    files-new-folder files-show-hidden editor-save editor-close editor-switch
                    editor-reload editor-dismiss))

;;; --- helpers -----------------------------------------------------------------------------

(defun %json-string (text)
  "TEXT as a JSON string literal, quotes included, for an hx-vals attribute."
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for c across text
          do (case c
               (#\" (write-string "\\\"" out))
               (#\\ (write-string "\\\\" out))
               (t (if (< (char-code c) 32)
                      (format out "\\u~4,'0X" (char-code c))
                      (write-char c out)))))
    (write-char #\" out)))

(defun %vals (&rest pairs)
  "An hx-vals JSON object of PAIRS, names and string values alternating."
  (format nil "{~{~A~^, ~}}"
          (loop for (name value) on pairs by #'cddr
                collect (format nil "~A: ~A" (%json-string name) (%json-string value)))))

(defun %message-html (text &key error)
  (spin:with-html-string (:span :class (if error "ou-error" "ide-type") text)))

(defun %refusal-html (condition)
  "The answer for an error a file operation signalled. A PATH-REFUSED is reported as it is; any
other error is reported by its type and text, and says the file was not changed."
  (%message-html (if (typep condition 'proj:path-refused)
                     (princ-to-string condition)
                     (format nil "The operation failed (~(~A~)): ~A. Nothing was changed."
                             (type-of condition) condition))
                 :error t))

(defun %join-path (folder name)
  (if (string= folder "") name (concatenate 'string folder "/" name)))

;;; --- the files window --------------------------------------------------------------------

(defun %files-window-editor (window)
  "The editor window the files window opens files in."
  (ui:find-window (ui:window-desktop window) (ui:window-datum window :editor "editor")))

(defun files-open-project (window parameters)
  "The files window's action `open-project': open the folder in the form field `folder' as the
project. The tree starts with only the root expanded. Tabs already open stay open, each saving
to the project it was opened from."
  (handler-case
      (let ((project (proj:open-project (or (%field parameters "folder") ""))))
        (setf (ui:window-datum window :project) project
              (ui:window-datum window :expanded) '(""))
        (ui:window-changed window)
        (%message-html (format nil "Opened ~A." (proj:project-name project))))
    (proj:path-refused (c) (%refusal-html c))))

(defun files-toggle (window parameters)
  "The files window's action `toggle': expand the folder in the form field `path', or collapse
it when it is expanded. Collapsing a folder keeps what was expanded inside it, so expanding it
again shows the same tree."
  (let ((path (or (%field parameters "path") "")))
    (sb-thread:with-mutex (*ide-lock*)
      (let ((expanded (ui:window-datum window :expanded '())))
        (setf (ui:window-datum window :expanded)
              (if (member path expanded :test #'string=)
                  (remove path expanded :test #'string=)
                  (cons path expanded)))))
    (ui:window-changed window)
    ""))

(defun files-show-hidden (window parameters)
  "The files window's action `hidden': show the entries the tree leaves out by default, or hide
them again."
  (declare (ignore parameters))
  (setf (ui:window-datum window :show-hidden) (not (ui:window-datum window :show-hidden)))
  (ui:window-changed window)
  "")

(defun open-file (editor project path)
  "Read PATH of PROJECT and show it in a tab of the window EDITOR, or show its tab when it is
open already. Returns the buffer. Signals PROJECT:PATH-REFUSED when the file cannot be opened."
  (sb-thread:with-mutex (*ide-lock*)
    (let ((tabs (ui:window-datum editor :tabs (proj:make-tabs))))
      (multiple-value-bind (new buffer)
          (if (proj:tabs-find-path tabs project path)
              (proj:tabs-open tabs project path "" nil)
              (multiple-value-bind (text stamp) (proj:read-buffer project path)
                (proj:tabs-open tabs project path text stamp)))
        (setf (ui:window-datum editor :tabs) new)
        (ui:window-changed editor)
        buffer))))

(defun %no-project-html ()
  (%message-html "Open a folder first." :error t))

(defun files-open (window parameters)
  "The files window's action `open': open the file in the form field `path' in the editor
window, or show its tab when it is open already."
  (let ((project (ui:window-datum window :project))
        (editor (%files-window-editor window)))
    (cond ((null project) (%no-project-html))
          ((null editor) (%message-html "There is no editor window to open the file in." :error t))
          (t (handler-case (progn (open-file editor project (or (%field parameters "path") ""))
                                  "")
               (error (c) (%refusal-html c)))))))

(defun %new-entry (window parameters maker)
  (let ((project (ui:window-datum window :project))
        (name (string-trim " " (or (%field parameters "name") ""))))
    (if (null project)
        (values nil (%no-project-html))
        (handler-case
            (progn
              (funcall maker project name)
              ;; Expand every folder on the way to the new entry, so it shows.
              (let ((parts (butlast (proj:relative-parts name))))
                (sb-thread:with-mutex (*ide-lock*)
                  (let ((expanded (ui:window-datum window :expanded '())))
                    (loop for i from 0 to (length parts)
                          for folder = (format nil "~{~A~^/~}" (subseq parts 0 i))
                          do (pushnew folder expanded :test #'string=))
                    (setf (ui:window-datum window :expanded) expanded))))
              (ui:window-changed window)
              (values name nil))
          (error (c) (values nil (%refusal-html c)))))))

(defun files-new-file (window parameters)
  "The files window's action `new-file': create the empty file the form field `name' names, a
path relative to the project's folder, and open it in the editor."
  (multiple-value-bind (name refusal) (%new-entry window parameters #'proj:make-file)
    (cond (refusal refusal)
          (t (let ((editor (%files-window-editor window)))
               (when editor
                 (handler-case (open-file editor (ui:window-datum window :project) name)
                   (error (c) (return-from files-new-file (%refusal-html c))))))
             (%message-html (format nil "Made ~A." name))))))

(defun files-new-folder (window parameters)
  "The files window's action `new-folder': create the folder the form field `name' names, a
path relative to the project's folder."
  (multiple-value-bind (name refusal) (%new-entry window parameters #'proj:make-folder)
    (or refusal (%message-html (format nil "Made the folder ~A." name)))))

(defun %tree-html (window project folder show-hidden expanded)
  "The entries of FOLDER, a path relative to PROJECT's root, as a list, with each expanded
folder's own entries inside it."
  (let ((entries (handler-case (proj:visible-entries (proj:list-folder project folder)
                                                     :show-hidden show-hidden)
                   (error (c) (return-from %tree-html (%refusal-html c)))))
        (base (format nil "/window/~A/action/" (ui:window-id window)))
        (status (format nil "#~A" (%dom-id window "status"))))
    (spin:with-html-string
      (:ul :class "ide-tree"
        (dolist (entry entries)
          (let* ((path (%join-path folder (car entry)))
                 (directory-p (eq (cdr entry) :directory))
                 (open-p (and directory-p (member path expanded :test #'string=))))
            (:li
              (:button :type "button" :class (if directory-p "ide-tree-dir" "ide-tree-file")
                       :title path
                       :hx-post (concatenate 'string base (if directory-p "toggle" "open"))
                       :hx-vals (%vals "path" path)
                       :hx-target status :hx-swap "innerHTML"
                       (if directory-p
                           (format nil "~A ~A/" (if open-p "▾" "▸") (car entry))
                           (car entry)))
              (when open-p
                (:raw (%tree-html window project path show-hidden expanded))))))))))

(defun render-files (window)
  "The files window's body: the form that opens a folder, the project's tree, and the form that
makes a new file or folder."
  (let* ((project (ui:window-datum window :project))
         (show-hidden (ui:window-datum window :show-hidden))
         (base (format nil "/window/~A/action/" (ui:window-id window)))
         (status-id (%dom-id window "status"))
         (status (format nil "#~A" status-id)))
    (spin:with-html-string
      (:form :class "ide-files-bar" :hx-post (concatenate 'string base "open-project")
             :hx-target status :hx-swap "innerHTML"
        (:input :type "text" :name "folder" :placeholder "Folder to open" :autocomplete "off"
                :id (%dom-id window "folder") :data-ou-preserve "1")
        (:button :type "submit" "Open folder"))
      (cond ((null project)
             (:p :class "ide-type" "No folder is open."))
            (t
             (:div :class "ide-files-bar"
               (:strong :title (uiop:native-namestring (proj:project-root project))
                        (proj:project-name project))
               (:button :type "button" :hx-post (concatenate 'string base "hidden")
                        :hx-target status :hx-swap "innerHTML"
                        (if show-hidden "Hide hidden" "Show hidden")))
             (if (member "" (ui:window-datum window :expanded '()) :test #'string=)
                 (:raw (%tree-html window project "" show-hidden
                                   (ui:window-datum window :expanded '())))
                 (:button :type "button" :class "ide-tree-dir"
                          :hx-post (concatenate 'string base "toggle") :hx-vals (%vals "path" "")
                          :hx-target status :hx-swap "innerHTML" "▸ show the tree"))
             (:form :class "ide-files-bar"
               (:input :type "text" :name "name" :placeholder "path/to/new-name" :autocomplete "off"
                       :id (%dom-id window "name") :data-ou-preserve "1")
               (:button :type "button" :hx-post (concatenate 'string base "new-file")
                        :hx-include "closest form" :hx-target status :hx-swap "innerHTML"
                        "New file")
               (:button :type "button" :hx-post (concatenate 'string base "new-folder")
                        :hx-include "closest form" :hx-target status :hx-swap "innerHTML"
                        "New folder"))))
      ;; Kept across a pushed body, so a message stays until the next action replaces it.
      (:div :class "ide-status" :id status-id :data-ou-preserve "1"))))

;;; --- the editor window's file tabs --------------------------------------------------------

(defun %editor-tabs (window)
  (ui:window-datum window :tabs (proj:make-tabs)))

(defun %host-id (window buffer)
  "The element id of the editor built for BUFFER. It carries the buffer's generation, so a
reload from disk gives a new element, and the page builds a new editor with the new text,
where a kept element would keep the old one."
  (%dom-id window "buf" (proj:buffer-id buffer) "g" (proj:buffer-generation buffer)))

(defun %tab-id (window buffer)
  (%dom-id window "tab" (proj:buffer-id buffer)))

(defun %buffer-of (window parameters)
  "The buffer of WINDOW's tabs whose id is in the form field `tab', or NIL."
  (let ((id (ignore-errors (parse-integer (or (%field parameters "tab") "")))))
    (and id (proj:tabs-find (%editor-tabs window) id))))

(defun %status-target (window)
  (format nil "#~A" (%dom-id window "status")))

(defun %action-url (window name)
  (format nil "/window/~A/action/~A" (ui:window-id window) name))

(defun %no-tab-html ()
  (%message-html "That tab is not open." :error t))

(defun editor-switch (window parameters)
  "The editor window's action `switch': show the tab whose buffer id is in the form field
`tab', or the scratch buffer when the field is empty."
  (let ((id (ignore-errors (parse-integer (or (%field parameters "tab") "")))))
    (sb-thread:with-mutex (*ide-lock*)
      (setf (ui:window-datum window :tabs) (proj:tabs-activate (%editor-tabs window) id)))
    (ui:window-changed window)
    ""))

(defun editor-dismiss (window parameters)
  "The editor window's action `dismiss': clear the status line, which answers a question with
`keep editing'."
  (declare (ignore window parameters))
  "")

(defun %conflict-html (window buffer)
  (let ((host (%host-id window buffer))
        (target (%status-target window)))
    (spin:with-html-string
      (:span :class "ou-error"
             (format nil "~A changed on disk after it was opened or last saved. Nothing was written. "
                     (proj:buffer-path buffer)))
      (:button :type "button" :hx-post (%action-url window "save")
               :hx-vals (format nil "js:{...OuranosEditor.fieldsOf(~A), overwrite: \"1\"}"
                                (%json-string host))
               :hx-target target :hx-swap "innerHTML"
               "Overwrite it with my text")
      (:button :type "button" :hx-post (%action-url window "reload")
               :hx-vals (%vals "tab" (princ-to-string (proj:buffer-id buffer)))
               :hx-target target :hx-swap "innerHTML"
               "Discard my changes and reload it")
      (:button :type "button" :hx-post (%action-url window "dismiss")
               :hx-target target :hx-swap "innerHTML"
               "Keep editing"))))

(defun editor-save (window parameters)
  "The editor window's action `save'. The form field `tab' is the buffer's id and `content' the
text the page holds for it. When the file on disk is what was read or last saved, or the field
`overwrite' is 1, the text is written (PROJECT:SAVE-BUFFER) and the answer carries
data-ou-saved, which tells the page the tab is no longer modified. When the file changed on
disk, nothing is written and the answer asks what to do."
  (let ((content (or (%field parameters "content") "")))
    (sb-thread:with-mutex (*ide-lock*)
      (let ((buffer (%buffer-of window parameters)))
        (cond
          ((null buffer)
           (if (string= "" (or (%field parameters "tab") ""))
               (%message-html "The scratch buffer is not a file. Open a file from the files window to save it." :error t)
               (%no-tab-html)))
          (t
           (handler-case
              (multiple-value-bind (outcome stamp)
                  (proj:save-buffer buffer content
                                    :overwrite (equal "1" (%field parameters "overwrite")))
                (ecase outcome
                  (:conflict (%conflict-html window buffer))
                  (:saved
                   (setf (ui:window-datum window :tabs)
                         (proj:tabs-replace (%editor-tabs window) buffer :text content :stamp stamp))
                   (spin:with-html-string
                     (:span :class "ide-type" :data-ou-saved (%host-id window buffer)
                            (format nil "Saved ~A." (proj:buffer-path buffer)))))))
             (error (c) (%refusal-html c)))))))))

(defun editor-reload (window parameters)
  "The editor window's action `reload': read the tab's file from disk again, dropping the text
in its editor, and give it a new editor holding what was read."
  (sb-thread:with-mutex (*ide-lock*)
    (let ((buffer (%buffer-of window parameters)))
      (if (null buffer)
          (%no-tab-html)
          (handler-case
              (multiple-value-bind (text stamp) (proj:reload-buffer buffer)
                (setf (ui:window-datum window :tabs)
                      (proj:tabs-replace (%editor-tabs window) buffer
                                         :text text :stamp stamp :reloaded t))
                (ui:window-changed window)
                (%message-html (format nil "Reloaded ~A from disk." (proj:buffer-path buffer))))
            (error (c) (%refusal-html c)))))))

(defun editor-close (window parameters)
  "The editor window's action `close'. The form field `tab' is the buffer's id and `content'
the text the page holds for it. When that text has changes that were not saved and the field
`confirm' is not 1, the tab stays open and the answer asks whether to discard them."
  (let ((buffer (%buffer-of window parameters)))
    (if (null buffer)
        (%no-tab-html)
        ;; A request without `content' is asked about too, since the server cannot tell
        ;; whether the page holds changes.
        (ecase (let ((content (%field parameters "content"))
                     (confirmed (equal "1" (%field parameters "confirm"))))
                 (if (and (null content) (not confirmed))
                     :ask
                     (proj:close-decision buffer (or content "") confirmed)))
          (:ask
           (let ((target (%status-target window)))
             (spin:with-html-string
               (:span :class "ou-error"
                      (format nil "~A has changes that were not saved. " (proj:buffer-path buffer)))
               (:button :type "button" :hx-post (%action-url window "close")
                        :hx-vals (%vals "tab" (princ-to-string (proj:buffer-id buffer)) "confirm" "1")
                        :hx-target target :hx-swap "innerHTML"
                        "Close it and lose them")
               (:button :type "button" :hx-post (%action-url window "dismiss")
                        :hx-target target :hx-swap "innerHTML"
                        "Keep it open"))))
          (:close
           (sb-thread:with-mutex (*ide-lock*)
             (setf (ui:window-datum window :tabs)
                   (proj:tabs-close (%editor-tabs window) (proj:buffer-id buffer))))
           (ui:window-changed window)
           "")))))

(defun %tab-bar-html (window panes-id)
  "The editor's tab bar: the scratch buffer, then one tab per open file, then the Save button.
A file's tab is a button that shows it and a button that closes it. The page marks a tab whose
text differs from what was last read or saved with data-ou-modified."
  (let* ((tabs (%editor-tabs window))
         (active (proj:tabs-active tabs))
         (target (%status-target window)))
    (spin:with-html-string
      (:div :class "ide-tabs" :role "tablist"
        (:span :class "ide-tab" :data-ou-active (if (null active) "1" nil)
          (:button :type "button" :role "tab" :hx-post (%action-url window "switch")
                   :hx-vals (%vals "tab" "") :hx-target target :hx-swap "innerHTML"
                   "scratch"))
        (dolist (buffer (proj:tabs-buffers tabs))
          (let ((id (princ-to-string (proj:buffer-id buffer)))
                (path (proj:buffer-path buffer)))
            (:span :class "ide-tab" :id (%tab-id window buffer)
                   :data-ou-active (if (eql active (proj:buffer-id buffer)) "1" nil)
              (:button :type "button" :role "tab" :title path
                       :hx-post (%action-url window "switch") :hx-vals (%vals "tab" id)
                       :hx-target target :hx-swap "innerHTML"
                       (subseq path (1+ (or (position #\/ path :from-end t) -1))))
              (:button :type "button" :class "ide-tab-close" :title (format nil "Close ~A" path)
                       :hx-post (%action-url window "close")
                       :hx-vals (format nil "js:{tab: ~A, ...OuranosEditor.contentOf(~A)}"
                                        (%json-string id) (%json-string (%host-id window buffer)))
                       :hx-target target :hx-swap "innerHTML"
                       "×"))))
        (:button :type "button" :class "ide-save" :id (%dom-id window "save")
                 :hx-post (%action-url window "save")
                 :hx-vals (format nil "js:{...OuranosEditor.activeFields(~A)}" (%json-string panes-id))
                 :hx-target target :hx-swap "innerHTML"
                 :title "Save the file shown (Mod-S)"
                 "Save")))))

(defun %file-panes-html (window form-id)
  "One pane per open file, each holding the element its editor is built in. Only the active
tab's pane is shown. The panes are rendered again on every push; the editor elements inside
them are kept by the page."
  (let ((tabs (%editor-tabs window)))
    (spin:with-html-string
      (dolist (buffer (proj:tabs-buffers tabs))
        (:div :class "ide-pane" :hidden (not (eql (proj:tabs-active tabs) (proj:buffer-id buffer)))
          (:div :class "ide-editor" :id (%host-id window buffer)
                :data-ou-preserve "1" :data-ou-editor "1" :data-ou-editor-form form-id
                :data-ou-editor-save (%dom-id window "save")
                :data-ou-editor-tab (%tab-id window buffer)
                :data-ou-editor-buffer (princ-to-string (proj:buffer-id buffer))
                :data-ou-editor-doc (proj:buffer-text buffer)))))))
