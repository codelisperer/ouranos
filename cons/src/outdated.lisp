;;;; outdated.lisp --- the online half of the upstream check: ask each entry's upstream for its
;;;; latest release (#716).
;;;;
;;;; Moved from scripts/check-upstream.lisp, which loads this system for --online. It is a
;;;; separate system, cons/outdated, because it needs aion/http-client and jzon and core cons
;;;; must not (the hub's ruling on #716, 2026-11-24). Every failure to reach or read a source is
;;;; UNKNOWN, never current: a lookup that could not be made says nothing about whether the pin
;;;; is behind. Each API's base URL can be set from the environment, which is also how the tests
;;;; point one at a port where nothing listens.

(defpackage #:cons/outdated
  (:use #:cl #:cons/inventory)
  (:local-nicknames (#:http #:aion/http-client) (#:jzon #:com.inuoe.jzon))
  (:export #:online-rows #:report-online))
(in-package #:cons/outdated)

(defun github-api () (base "CHECK_UPSTREAM_GITHUB_API" "https://api.github.com"))
(defun npm-registry () (base "CHECK_UPSTREAM_NPM_REGISTRY" "https://registry.npmjs.org"))
(defun nuget-api () (base "CHECK_UPSTREAM_NUGET_API" "https://api.nuget.org"))
(defun quicklisp-site () (base "CHECK_UPSTREAM_QUICKLISP" "https://beta.quicklisp.org"))
(defun docker-hub () (base "CHECK_UPSTREAM_DOCKER_HUB" "https://hub.docker.com"))

(defun get-json (url)
  "Fetch URL and parse its body as JSON. Signals on any failure."
  (let* ((headers (append '(("Accept" . "application/json") ("User-Agent" . "ouranos-check-upstream"))
                          (let ((token (uiop:getenv "GITHUB_TOKEN")))
                            (when (and token (plusp (length token)) (search "api.github.com" url))
                              (list (cons "Authorization" (format nil "Bearer ~A" token)))))))
         (request (http:make-request :method :get :url url :headers headers
                                     :connect-timeout 10 :read-timeout 30))
         (response (http:send-request request (list (http:ensure-2xx "check-upstream")))))
    (jzon:parse (http:response-body response))))

(defun get-text (url)
  (let* ((request (http:make-request :method :get :url url :headers '(("User-Agent" . "ouranos-check-upstream"))
                                     :connect-timeout 10 :read-timeout 30))
         (response (http:send-request request (list (http:ensure-2xx "check-upstream")))))
    (http:response-body response)))

(defun json (object &rest keys)
  "Follow KEYS (strings for objects, integers for arrays) into a parsed JSON OBJECT."
  (dolist (k keys object)
    (setf object (if (integerp k) (aref object k) (gethash k object)))))

(defun latest (upstream pinned)
  "(values latest-version status detail) for UPSTREAM, or signals when it cannot be read."
  (destructuring-bind (kind &optional id prefix) upstream
    (flet ((versioned (latest) (multiple-value-bind (s d) (compare-pin pinned latest) (values latest s d))))
      (ecase kind
        (:manual (values nil :manual nil))
        (:github-release
         (versioned (json (get-json (format nil "~A/repos/~A/releases/latest" (github-api) id)) "tag_name")))
        (:github-tag
         (let ((names (loop for tag across (get-json (format nil "~A/repos/~A/tags?per_page=100" (github-api) id))
                            for name = (json tag "name")
                            when (and (>= (length name) (length prefix)) (string= prefix name :end2 (length prefix))
                                      (version-numbers (subseq name (length prefix))) (stable-p name))
                              collect (subseq name (length prefix)))))
           (if names (versioned (newest names)) (error "no tag starting ~A" prefix))))
        (:github-commit
         (let* ((branch (json (get-json (format nil "~A/repos/~A" (github-api) id)) "default_branch"))
                (compare (get-json (format nil "~A/repos/~A/compare/~A...~A" (github-api) id pinned branch)))
                (ahead (json compare "ahead_by")))
           ;; AHEAD_BY first: a pin at the branch head has no commits to take the newest from, and
           ;; reading one anyway reported it unknown instead of current (the hub's review of #738).
           (if (zerop ahead)
               (values pinned :current nil)
               (let ((commits (json compare "commits")))
                 (values (subseq (json commits (1- (length commits)) "sha") 0 8)
                         :behind (format nil "~D commit~:P behind ~A" ahead branch))))))
        (:npm (versioned (json (get-json (format nil "~A/~A" (npm-registry) id)) "dist-tags" "latest")))
        (:nuget
         (let ((versions (remove-if-not #'stable-p
                                        (coerce (json (get-json (format nil "~A/v3-flatcontainer/~A/index.json"
                                                                        (nuget-api) (string-downcase id)))
                                                      "versions")
                                                'list))))
           (versioned (newest versions))))
        (:quicklisp-dist
         (let* ((text (get-text (format nil "~A/dist/quicklisp.txt" (quicklisp-site))))
                (at (search "version: " text)))
           (unless at (error "no version line in quicklisp.txt"))
           (versioned (up-to-space (string-trim '(#\Return #\Newline) (subseq text (+ at 9) (position #\Newline text :start at)))))))
        (:docker
         (let* ((shape (version-shape pinned))
                (names (loop for tag across (json (get-json (format nil "~A/v2/repositories/~A/tags?page_size=100&ordering=last_updated"
                                                                    (docker-hub) id))
                                                  "results")
                             for name = (json tag "name")
                             when (and (string= shape (version-shape name)) (stable-p name)
                                       (or (null prefix)
                                           (and (>= (length name) (length prefix))
                                                (string= prefix name :start2 (- (length name) (length prefix))))))
                               collect name)))
           (if names (versioned (newest names)) (error "no tag shaped like ~A" pinned))))))))

(defun online-row (entry value)
  "(name category pinned latest status detail) for ENTRY, whose pinned value is VALUE."
  (multiple-value-bind (latest status detail)
      (handler-case (latest (getf entry :upstream) value)
        (error (e) (values nil :unknown (format nil "could not be read: ~A"
                                                (substitute #\Space #\Newline (princ-to-string e))))))
    (let ((held (getf entry :held)))
      (when (and held (eq status :behind))
        (setf status :held
              detail (format nil "~@[~A; ~]~A (#~D)" detail (getf held :reason) (getf held :issue)))))
    (when (eq status :manual)
      (let ((r (getf entry :reviewed))
            (held (getf entry :held)))
        ;; A held entry checked by hand shows its hold too, so Stripe's row names #734 (the hub's
        ;; review of #738).
        (setf detail (format nil "check ~A by hand; ~A~@[; held: ~A~]" (second (getf entry :upstream))
                             (if (eq r :never) "never reviewed" (format nil "reviewed ~A" r))
                             (and held (format nil "~A (#~D)" (getf held :reason) (getf held :issue)))))))
    ;; Checked last, so it overrides every other status: an entry whose upstream has stopped
    ;; serving it needs removing whether or not it is current.
    (when (retired-p entry (today))
      (setf status :retired
            detail (format nil "shut down on ~A: remove this entry and what it pins~@[; ~A~]"
                           (getf entry :retires) detail)))
    (list (getf entry :name) (getf entry :category) value latest status detail)))

(defun online-rows (checked)
  "(name category pinned latest status detail) for each (entry . value) in CHECKED."
  (mapcar (lambda (c) (online-row (car c) (cdr c))) checked))

(defun report-online (checked markdown)
  "Compare every checked entry with its upstream and print the result; write it as Markdown to
MARKDOWN when given. Returns the rows. Being behind is a fact to act on, so this never signals
for it; the caller decides what the exit code is."
  (let ((rows (online-rows checked)))
    (format t "~%~42A ~10A ~22A ~22A ~A~%" "name" "status" "pinned" "latest" "note")
    (dolist (r rows)
      (format t "~42A ~10A ~22A ~22A ~@[~A~]~%" (first r) (string-downcase (fifth r)) (third r) (or (fourth r) "") (sixth r)))
    (format t "~%~A --online: ~{~A~^, ~}~%"
            *program*
            (loop for s in '(:retired :behind :unknown :held :manual :current)
                  for n = (count s rows :key #'fifth)
                  when (plusp n) collect (format nil "~D ~A" n (string-downcase s))))
    (when markdown
      (with-open-file (out markdown :direction :output :if-exists :supersede :external-format :utf-8)
        (write-markdown rows out)))
    rows))
