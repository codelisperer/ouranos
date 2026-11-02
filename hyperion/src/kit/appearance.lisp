;;;; appearance.lisp --- the control a visitor uses to choose theme, contrast and look (#981)
;;;;
;;;; hyperion/appearance stores the three settings and writes them onto <html>; this is the
;;;; control that changes them. APPEARANCE-PICKER writes a POST form with three labelled groups
;;;; of buttons, one group per setting, each button carrying aria-pressed as the segmented
;;;; control does. A button is a submit button with its setting's name and value, so the form
;;;; works without script: the browser posts the one button pressed, and the app answers with a
;;;; redirect back to the page, which the next render shows through HTML-ATTRIBUTES.
;;;;
;;;; With htmx on the page the form posts with hx-post instead, and swaps nothing. The app
;;;; answers with APPEARANCE-RESPONSE-HEADERS, which persist the choice and carry an HX-Trigger
;;;; event, hy-appearance, naming the new settings. APPLY-APPEARANCE-JS listens for that event,
;;;; sets or removes data-theme, data-contrast and data-look on <html>, and moves aria-pressed in
;;;; every picker on the page, so the page changes without a reload.
;;;;
;;;; A handler, in outline:
;;;;
;;;;   (let ((change (appearance-from-form (http:body-string env))))
;;;;     (if (null change)
;;;;         (list 400 '(:content-type "text/plain") '("bad appearance"))
;;;;         (let ((new (merge-appearance (read-appearance store env) change)))
;;;;           (if (http:htmx-request-p env)
;;;;               (list 204 (appearance-response-headers store new) '())
;;;;               (list 303 (list* :location "/settings" (persist-appearance store new)) '())))))
;;;;
;;;; Every value the form posts is checked against the closed set of values hyperion/appearance
;;;; allows. A form with any other value, or with a setting posted twice, is refused as a whole,
;;;; and nothing from it is written back into the page or a header.

(cl:defpackage #:hyperion/kit/appearance
  (:use #:cl)
  (:local-nicknames (#:spin #:spinneret)
                    (#:out #:hyperion/output)
                    (#:http #:hyperion/http)
                    (#:app #:hyperion/appearance)
                    (#:page #:hyperion/kit/page))   ; SAFE-HREF-P, for the form's action
  ;; Parenscript matches its own macros by symbol identity, so these are the real ones, as in
  ;; hyperion/js and the dialogs.
  (:import-from #:parenscript #:chain #:@)
  (:documentation
   "The appearance picker (APPEARANCE-PICKER), reading its form (APPEARANCE-FROM-FORM,
    MERGE-APPEARANCE), answering it (APPEARANCE-RESPONSE-HEADERS), and the Parenscript that
    applies a new choice without a reload (APPLY-APPEARANCE-JS).")
  (:export #:appearance-picker #:*default-picker-labels*
           #:appearance-from-form #:merge-appearance
           #:appearance-response-headers #:*appearance-event*
           #:apply-appearance-js))

(in-package #:hyperion/kit/appearance)

(defparameter *appearance-event* "hy-appearance"
  "The name of the event APPEARANCE-RESPONSE-HEADERS sends in HX-Trigger and
APPLY-APPEARANCE-JS listens for.")

(defparameter *default-picker-labels*
  '(:picker "Appearance"
    :theme "Theme" :contrast "Contrast" :look "Look"
    :system "System" :light "Light" :dark "Dark" :normal "Normal" :high "High"
    :flat "Flat" :gradient "Gradient")
  "The picker's visible text, by key. An app passes its own plist, such as a translation, as
APPEARANCE-PICKER's LABELS; a key it leaves out takes the text here.")

(defparameter +settings+
  `((:theme "theme" "system" app:*themes* ,#'app:appearance-theme)
    (:contrast "contrast" "system" app:*contrasts* ,#'app:appearance-contrast)
    (:look "look" "flat" app:*looks* ,#'app:appearance-look))
  "Each setting: its key, the form field's name, the value that stands for NIL (the system, or
for look the default, flat), the variable holding the values hyperion/appearance allows, and
the appearance's accessor. \"system\" is a value only of theme and contrast, since look has no
system preference.")

(defun %allowed (setting)
  "The strings SETTING's field may post: its NIL value, then each allowed keyword's name,
without repeating the NIL value (look's default, flat, is also one of its keywords)."
  (remove-duplicates
   (cons (third setting)
         (mapcar (lambda (k) (string-downcase (symbol-name k)))
                 (symbol-value (fourth setting))))
   :test #'string= :from-end t))

(defun %value-string (setting value)
  "The form value for VALUE, a keyword or NIL, of SETTING."
  (if value (string-downcase (symbol-name value)) (third setting)))

(defun %label (labels key)
  (let ((text (or (getf labels key) (getf *default-picker-labels* key))))
    (unless (stringp text)
      (error "The picker's label ~S must be a string, not ~S." key text))
    text))

;;; --- the picker ---------------------------------------------------------------------

(defun appearance-picker (appearance action-href &key (labels *default-picker-labels*) id)
  "Write the appearance picker into SPINNERET:*HTML*: a form that posts to ACTION-HREF, named
by LABELS' :PICKER, holding three groups of buttons, theme (System, Light, Dark), contrast
(System, Normal, High) and look (Flat, Gradient). Each group is role=\"group\" with its name
in aria-label, and each button has aria-pressed; the pressed one in each group is
APPEARANCE's setting, System for a theme or contrast that follows the system, and Flat for
the default look. ID is the form's id.

Each button is a submit button named after its setting, so without script the browser posts
the one pressed, such as theme=dark. With htmx the form posts with hx-post and swaps
nothing: include APPLY-APPEARANCE-JS on the page, and answer with
APPEARANCE-RESPONSE-HEADERS. LABELS is a plist of the visible text, keyed as
*DEFAULT-PICKER-LABELS*; a key it leaves out takes the default.

Signals when ACTION-HREF has a scheme other than http or https (PAGE:SAFE-HREF-P): it is the
form's action, and javascript: there would run as script."
  (unless (page:safe-href-p action-href)
    (error "The picker's ACTION-HREF must be http, https or relative, not ~S." action-href))
  (spin:with-html
    (:form :id id :class "hy-appearance-picker" :method "post" :action action-href
           :aria-label (%label labels :picker)
           :hx-post action-href :hx-swap "none"
      (dolist (setting +settings+)
        (destructuring-bind (key name nil-value var accessor) setting
          (declare (ignore nil-value var))
          (let ((pressed (%value-string setting (funcall accessor appearance))))
            (spin:with-html
              (:div :class "hy-segmented hy-appearance-group" :role "group"
                    :aria-label (%label labels key)
                (dolist (value (%allowed setting))
                  (spin:with-html
                    (:button :type "submit" :class "button" :name name :value value
                             :data-hy-setting name
                             :aria-pressed (if (string= value pressed) "true" "false")
                      (%label labels (intern (string-upcase value) :keyword)))))))))))))

;;; --- reading the form ---------------------------------------------------------------

(defun appearance-from-form (body)
  "The change the picker's form BODY, a urlencoded string, asks for, as a plist of the settings
it posted, such as (:THEME :DARK) or (:CONTRAST NIL), where NIL means follow the system (or,
for look, the default). The picker posts one setting; a body with more is read the same way.
Fields with other names, such as a CSRF token, are ignored.

NIL, refusing the whole form, when it posts no setting, when a setting's value is not one of
the values hyperion/appearance allows for it, or when a setting is posted more than once. A
refused value is not returned or kept, so it cannot reach the page or a header."
  (let ((change '()))
    (dolist (setting +settings+ (and change (nreverse change)))
      (destructuring-bind (key name nil-value var accessor) setting
        (declare (ignore accessor))
        (let ((values (http:form-params body name)))
          (cond ((null values))
                ((or (rest values)
                     (not (member (first values) (%allowed setting) :test #'string=)))
                 (return nil))
                (t (push key change)
                   (push (if (string= (first values) nil-value)
                             nil
                             (find (first values) (symbol-value var)
                                   :key #'symbol-name :test #'string-equal))
                         change))))))))

(defun merge-appearance (old change)
  "OLD, an appearance, with the settings in CHANGE, a plist as APPEARANCE-FROM-FORM returns,
put over it. A setting CHANGE does not name keeps OLD's value."
  (flet ((pick (key current)
           (let ((tail (member key change)))
             (if tail (second tail) current))))
    (app:make-appearance :theme (pick :theme (app:appearance-theme old))
                         :contrast (pick :contrast (app:appearance-contrast old))
                         :look (pick :look (app:appearance-look old)))))

;;; --- answering ----------------------------------------------------------------------

(defun %json-value (value)
  "VALUE, a keyword from hyperion/appearance's closed sets or NIL, as JSON. The keywords are
lower-case letters only, so writing them between quotes needs no escaping."
  (if value (format nil "\"~(~A~)\"" value) "null"))

(defun appearance-response-headers (store appearance)
  "Response headers for an htmx request that changed the appearance to APPEARANCE: the headers
APP:PERSIST-APPEARANCE gives for STORE, and HX-Trigger with the event *APPEARANCE-EVENT*,
whose detail names each setting, null for one that follows the system:

  {\"hy-appearance\": {\"theme\": \"dark\", \"contrast\": null, \"look\": \"flat\"}}

APPLY-APPEARANCE-JS applies it to the page. Answer with status 204, since nothing is swapped."
  (append (app:persist-appearance store appearance)
          (list :hx-trigger
                (format nil "{\"~A\": {\"theme\": ~A, \"contrast\": ~A, \"look\": ~A}}"
                        *appearance-event*
                        (%json-value (app:appearance-theme appearance))
                        (%json-value (app:appearance-contrast appearance))
                        (%json-value (app:appearance-look appearance))))))

;;; --- applying it without a reload ---------------------------------------------------

(defun apply-appearance-js ()
  "Compiled JS that applies the hy-appearance event to the page: for each setting it sets the
attribute on <html> (data-theme, data-contrast, data-look), or removes it when the setting is
null, so the CSS follows the system again; and it sets aria-pressed on every picker button of
that setting. Installed once on the document however many times the page includes it.
Include it once with (:script (:raw (apply-appearance-js)))."
  (out:js-string
   `(funcall
     (lambda ()
       (unless (@ window hy-kit-appearance)
         (setf (@ window hy-kit-appearance) t)
         (chain document
                (add-event-listener
                 ,*appearance-event*
                 (lambda (e)
                   (let ((d (@ e detail))
                         (root (@ document document-element)))
                     (when d
                       (dolist (s (list (list "theme" "system")
                                        (list "contrast" "system")
                                        (list "look" "flat")))
                         (let* ((name (aref s 0))
                                (value (aref d name))
                                (pressed (or value (aref s 1))))
                           ;; Only a value of the closed set reaches the page: the server
                           ;; sends nothing else, and an attribute from anything else would
                           ;; match no rule.
                           (if value
                               (chain root (set-attribute (+ "data-" name) value))
                               (chain root (remove-attribute (+ "data-" name))))
                           (chain (chain document
                                         (query-selector-all
                                          (+ "[data-hy-setting=\"" name "\"]")))
                                  (for-each
                                   (lambda (b)
                                     (chain b (set-attribute
                                               "aria-pressed"
                                               (if (equal (@ b value) pressed)
                                                   "true" "false"))))))))))))))))))
