;;;; check-upstream.lisp --- every pinned version in the tree has an entry in upstream.sexp, and
;;;; every entry still finds its pin (#716).
;;;;
;;;;     sbcl --script scripts/check-upstream.lisp                     ; offline, deterministic
;;;;     sbcl --script scripts/check-upstream.lisp --online [--markdown FILE]
;;;;     sbcl --script scripts/check-upstream.lisp --self-test         ; the comparison rules
;;;;
;;;; Exit 0 when the inventory and the tree agree, 1 when they do not, 2 when upstream.sexp
;;;; cannot be read at all, so a misread inventory is never reported as a clean one.
;;;;
;;;; WHAT IT CHECKS, all without the network:
;;;;
;;;;   1. Every entry in upstream.sexp is well formed: a unique name, a known category, at
;;;;      least one place in :WHERE, a known :UPSTREAM form, and a :REVIEWED date or :NEVER
;;;;      when the upstream is :MANUAL.
;;;;   2. Every place an entry names still yields a value, and all of them yield the same one.
;;;;      A pin that moved, or a second copy of a version that was not updated with the first
;;;;      (such as ASSETS.pin and assets.lisp), fails here.
;;;;   3. Every pin in the tree has an entry: each identity line of each *.pin file (`version'
;;;;      or `sha', or an ASSETS.pin-style `NAME VERSION sha256 HASH' line), each *_VERSION key
;;;;      and QUICKLISP_DIST in scripts/versions.env, and each `uses: ACTION@' in each workflow.
;;;;      A pin added without an entry fails here, in the commit that added it.
;;;;
;;;; WITH --ONLINE it then asks each entry's upstream for its latest release and prints, per
;;;; entry, current, behind, held (behind on purpose, with the reason and issue), manual (an API
;;;; version checked by hand, with its review date), or unknown (the source could not be reached
;;;; or read; never reported as current). It exits 0 whatever it finds. It needs the network, so
;;;; it runs in .github/workflows/upstream.yml and never in the gate (docs/versioning-and-pinning.md).

(require :uiop)
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; how a path is printed (#168)

(defparameter *root* (uiop:pathname-parent-directory-pathname
                      (uiop:pathname-directory-pathname *load-truename*)))

(defparameter *categories* '(:toolchain :quicklisp :native :asset :api :ci :container))

(defparameter *upstream-kinds*
  '(:github-release :github-commit :github-tag :npm :nuget :quicklisp-dist :docker :manual))

(defvar *problems* '()
  "Each finding, as a string, newest first.")

(defun problem (control &rest args)
  (push (apply #'format nil control args) *problems*))

;;; --- reading -------------------------------------------------------------------------------

(defun read-inventory (path)
  "Every form in PATH, read with *READ-EVAL* off. Signals when PATH cannot be read."
  (with-open-file (in path :external-format :utf-8)
    (with-standard-io-syntax
      ;; WITH-STANDARD-IO-SYNTAX reads into CL-USER, so NIL is NIL and :NAME is a keyword.
      (let ((*read-eval* nil))
        (loop for form = (read in nil in)
              until (eq form in)
              collect form)))))

(defun file-lines (relative)
  "The lines of the file RELATIVE to the tree, without carriage returns, or NIL when there is no
such file."
  (let ((path (merge-pathnames relative *root*)))
    (when (probe-file path)
      (with-open-file (in path :external-format :utf-8)
        (loop for line = (read-line in nil nil)
              while line
              collect (string-right-trim '(#\Return) line))))))

(defun words (line)
  (remove "" (uiop:split-string line :separator '(#\Space #\Tab)) :test #'string=))

(defun comment-line-p (line)
  (let ((trimmed (string-left-trim '(#\Space #\Tab) line)))
    (or (zerop (length trimmed))
        (char= (char trimmed 0) #\#)
        (char= (char trimmed 0) #\;))))

(defun top-level-line-p (line)
  "True for a line that starts in the first column and is not a comment: a field or an asset
line of a .pin file, not a continuation."
  (and (plusp (length line))
       (not (member (char line 0) '(#\Space #\Tab)))
       (not (comment-line-p line))))

;;; --- places --------------------------------------------------------------------------------

(defun up-to-space (string)
  (subseq string 0 (or (position-if (lambda (c) (member c '(#\Space #\Tab))) string)
                       (length string))))

(defun place-values (place)
  "The values PLACE yields, one per occurrence, as (values list error-string). An error string
says why the place could not be read at all."
  (case (first place)
    (:env
     (destructuring-bind (file key) (rest place)
       (let ((lines (file-lines file))
             (prefix (format nil "~A=" key)))
         (if (null lines)
             (values nil (format nil "no file ~A" file))
             (values (loop for line in lines
                           when (and (>= (length line) (length prefix))
                                     (string= prefix line :end2 (length prefix)))
                             collect (string-trim " " (subseq line (length prefix))))
                     nil)))))
    (:field
     (destructuring-bind (file name) (rest place)
       (let ((lines (file-lines file)))
         (if (null lines)
             (values nil (format nil "no file ~A" file))
             (values (loop for line in lines
                           for w = (words line)
                           when (and (top-level-line-p line) (string= name (first w)) (second w))
                             collect (second w))
                     nil)))))
    (:text
     (destructuring-bind (file before after) (rest place)
       (let ((lines (file-lines file)))
         (if (null lines)
             (values nil (format nil "no file ~A" file))
             (values (loop for line in lines
                           append (loop with start = 0
                                        for at = (search before line :start2 start)
                                        while at
                                        collect (let* ((from (+ at (length before)))
                                                       (rest (subseq line from)))
                                                  (if after
                                                      (let ((end (search after rest)))
                                                        (if end (subseq rest 0 end) :unterminated))
                                                      (up-to-space rest)))
                                        do (setf start (1+ at))))
                     nil)))))
    (:concat
     (destructuring-bind (separator &rest parts) (rest place)
       (let ((values '()))
         (dolist (part parts)
           (multiple-value-bind (found error) (place-values part)
             (cond (error (return-from place-values (values nil error)))
                   ((null found) (return-from place-values (values nil nil)))
                   ((rest (remove-duplicates found :test #'equal))
                    (return-from place-values
                      (values nil (format nil "~S gives different values: ~{~A~^, ~}" part found))))
                   (t (push (first found) values)))))
         ;; Joined with WRITE-STRING, never by splicing SEPARATOR into a FORMAT control string:
         ;; upstream.sexp is data, and a ~/pkg:fn/ directive in it would call a function
         ;; (the hub's review of #737).
         (values (list (with-output-to-string (out)
                         (loop for (v . more) on (reverse values)
                               do (write-string v out)
                                  (when more (write-string separator out)))))
                 nil))))
    (t (values nil (format nil "unknown place ~S" place)))))

(defun place-file (place)
  (if (eq (first place) :concat)
      (place-file (third place))
      (second place)))

;;; --- entries -------------------------------------------------------------------------------

(defun date-p (x)
  (and (stringp x) (= 10 (length x))
       (every (lambda (i) (digit-char-p (char x i))) '(0 1 2 3 5 6 8 9))
       (char= #\- (char x 4)) (char= #\- (char x 7))))

(defun check-entry (entry)
  "Record every problem with ENTRY. Returns its value, or NIL when it has none."
  (let ((name (getf entry :name)))
    (unless (stringp name)
      (problem "an entry has no :name: ~S" entry)
      (return-from check-entry nil))
    (unless (member (getf entry :category) *categories*)
      (problem "~A: unknown :category ~S" name (getf entry :category)))
    (let ((upstream (getf entry :upstream)))
      (unless (and (consp upstream) (member (first upstream) *upstream-kinds*))
        (problem "~A: unknown :upstream ~S" name upstream))
      (when (and (consp upstream) (eq (first upstream) :manual))
        (let ((reviewed (getf entry :reviewed)))
          (unless (or (eq reviewed :never) (date-p reviewed))
            (problem "~A: a :manual upstream needs :reviewed YYYY-MM-DD or :never, not ~S" name reviewed)))))
    (let ((held (getf entry :held)))
      (when (and held (not (and (stringp (getf held :reason)) (integerp (getf held :issue)))))
        (problem "~A: :held needs a :reason string and an :issue number: ~S" name held)))
    (let ((where (getf entry :where))
          (seen '()))
      (when (null where)
        (problem "~A: no :where" name))
      (dolist (place where)
        (multiple-value-bind (found error) (place-values place)
          (cond (error (problem "~A: ~A" name error))
                ((null found) (problem "~A: ~S no longer finds its pin" name place))
                ((member :unterminated found)
                 (problem "~A: ~S finds its start but not its end" name place))
                (t (dolist (v found) (pushnew v seen :test #'equal))))))
      (when (rest seen)
        (problem "~A: its places disagree: ~{~A~^, ~}" name (reverse seen)))
      (first seen))))

;;; --- coverage ------------------------------------------------------------------------------

(defun relative (path)
  (enough-namestring path *root*))

(defun pin-files ()
  "Every *.pin file in the tree, outside .git."
  (sort (remove-if (lambda (p) (search "/.git/" (namestring p)))
                   (directory (merge-pathnames "**/*.pin" *root*)))
        #'string< :key #'namestring))

(defun pinned-items ()
  "Every pin the tree has, as (kind file key): an identity line of a *.pin file, a version key
of scripts/versions.env, and an action a workflow uses."
  (append
   (loop for path in (pin-files)
         for file = (relative path)
         append (loop for line in (file-lines file)
                      for w = (words line)
                      when (and (top-level-line-p line)
                                (or (member (first w) '("version" "sha") :test #'string=)
                                    (equal (third w) "sha256")))
                        collect (list :field file (first w))))
   (loop for line in (file-lines "scripts/versions.env")
         for key = (let ((eq (position #\= line))) (and eq (not (comment-line-p line)) (subseq line 0 eq)))
         when (and key (or (string= key "QUICKLISP_DIST")
                           (let ((suffix "_VERSION"))
                             (and (> (length key) (length suffix))
                                  (string= suffix key :start2 (- (length key) (length suffix)))))))
           collect (list :env "scripts/versions.env" key))
   (loop for path in (sort (directory (merge-pathnames ".github/workflows/*.yml" *root*))
                           #'string< :key #'namestring)
         for file = (relative path)
         append (remove-duplicates
                 (loop for line in (file-lines file)
                       for at = (search "uses: " line)
                       for spec = (and at (not (comment-line-p line)) (up-to-space (subseq line (+ at 6))))
                       for sign = (and spec (position #\@ spec))
                       when sign
                         collect (list :text file (format nil "uses: ~A@" (subseq spec 0 sign))))
                 :test #'equal))))

(defun covers-p (entries item)
  "Does some place of some entry name ITEM?"
  (flet ((places (entry)
           (loop for place in (getf entry :where)
                 append (if (eq (first place) :concat) (cddr place) (list place)))))
    (some (lambda (entry)
            (some (lambda (place)
                    (and (eq (first place) (first item))
                         (equal (second place) (second item))
                         (equal (third place) (third item))))
                  (places entry)))
          entries)))

;;; --- versions -------------------------------------------------------------------------------

(defun version-numbers (string)
  "The runs of digits in STRING, as integers: \"v7.0.1\" => (7 0 1), \"0.8.6-pg18\" => (0 8 6 18)."
  (let ((numbers '()) (current nil))
    (loop for c across string
          do (if (digit-char-p c)
                 (setf current (+ (* 10 (or current 0)) (digit-char-p c)))
                 (when current (push current numbers) (setf current nil))))
    (when current (push current numbers))
    (nreverse numbers)))

(defun version-shape (string)
  "STRING with each run of digits replaced by #: \"0.8.6-pg18\" => \"#.#.#-pg#\". Two versions are
compared only when they have the same shape, so a pg18 image is not compared with a pg17 one."
  (with-output-to-string (out)
    (let ((in-digits nil))
      (loop for c across string
            do (cond ((digit-char-p c) (unless in-digits (write-char #\# out)) (setf in-digits t))
                     (t (write-char c out) (setf in-digits nil)))))))

(defun version< (a b)
  "Is version string A older than B, comparing their numbers in order?"
  (loop for x in (version-numbers a)
        for y in (version-numbers b)
        do (cond ((< x y) (return t)) ((> x y) (return nil)))
        finally (return (< (length (version-numbers a)) (length (version-numbers b))))))

(defun newest (versions)
  (first (sort (copy-list versions) (lambda (a b) (version< b a)))))

(defun stable-p (version)
  "No pre-release marker: rc, alpha, beta, pre, preview, dev or next."
  (let ((v (string-downcase version)))
    (notany (lambda (marker) (search marker v)) '("rc" "alpha" "beta" "pre" "dev" "next"))))

(defun compare-pin (pinned latest)
  "(values status detail) for PINNED against LATEST. Only as many numbers as PINNED has are
compared, so a CI action pinned to its major tag v7 is current while the latest release is
v7.0.1, and behind once v8 exists."
  (let* ((p (version-numbers pinned))
         (l (subseq (version-numbers latest) 0 (min (length p) (length (version-numbers latest))))))
    (cond ((or (null p) (null l)) (values :unknown (format nil "cannot compare ~A with ~A" pinned latest)))
          ((equal p l) (values :current nil))
          ((version< (format nil "~{~D~^.~}" p) (format nil "~{~D~^.~}" l))
           (values :behind (format nil "latest is ~A" latest)))
          (t (values :current (format nil "pinned ~A is newer than the latest release ~A" pinned latest))))))

;;; --- online --------------------------------------------------------------------------------
;;;
;;; Loaded only with --online, so the offline check the gate runs needs nothing but SBCL. Every
;;; failure to reach or read a source is UNKNOWN, never current: a lookup that could not be made
;;; says nothing about whether the pin is behind. Each API's base URL can be set from the
;;; environment, which is also how the test points one at a port where nothing listens.

(defun base (variable default)
  (let ((v (uiop:getenv variable))) (if (and v (plusp (length v))) v default)))

(defun github-api () (base "CHECK_UPSTREAM_GITHUB_API" "https://api.github.com"))
(defun npm-registry () (base "CHECK_UPSTREAM_NPM_REGISTRY" "https://registry.npmjs.org"))
(defun nuget-api () (base "CHECK_UPSTREAM_NUGET_API" "https://api.nuget.org"))
(defun quicklisp-site () (base "CHECK_UPSTREAM_QUICKLISP" "https://beta.quicklisp.org"))
(defun docker-hub () (base "CHECK_UPSTREAM_DOCKER_HUB" "https://hub.docker.com"))

(defun load-online-dependencies ()
  "Quicklisp, this tree's aion/http-client and jzon. The tree is registered with ASDF the way
bootstrap.lisp's drop-in registers it, so the client is this tree's own."
  (require :asdf)
  (load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
  (funcall (read-from-string "asdf:initialize-source-registry")
           `(:source-registry (:tree ,*root*) :inherit-configuration))
  (funcall (read-from-string "ql:quickload") '(:aion/http-client :com.inuoe.jzon) :silent t))

(defun sym (package name) (symbol-function (find-symbol name package)))

(defun get-json (url)
  "Fetch URL and parse its body as JSON. Signals on any failure."
  (let* ((headers (append '(("Accept" . "application/json") ("User-Agent" . "ouranos-check-upstream"))
                          (let ((token (uiop:getenv "GITHUB_TOKEN")))
                            (when (and token (plusp (length token)) (search "api.github.com" url))
                              (list (cons "Authorization" (format nil "Bearer ~A" token)))))))
         (request (funcall (sym "AION/HTTP-CLIENT" "MAKE-REQUEST")
                           :method :get :url url :headers headers
                           :connect-timeout 10 :read-timeout 30))
         (response (funcall (sym "AION/HTTP-CLIENT" "SEND-REQUEST") request
                            (list (funcall (sym "AION/HTTP-CLIENT" "ENSURE-2XX") "check-upstream")))))
    (funcall (sym "COM.INUOE.JZON" "PARSE") (funcall (sym "AION/HTTP-CLIENT" "RESPONSE-BODY") response))))

(defun get-text (url)
  (let* ((request (funcall (sym "AION/HTTP-CLIENT" "MAKE-REQUEST")
                           :method :get :url url :headers '(("User-Agent" . "ouranos-check-upstream"))
                           :connect-timeout 10 :read-timeout 30))
         (response (funcall (sym "AION/HTTP-CLIENT" "SEND-REQUEST") request
                            (list (funcall (sym "AION/HTTP-CLIENT" "ENSURE-2XX") "check-upstream")))))
    (funcall (sym "AION/HTTP-CLIENT" "RESPONSE-BODY") response)))

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
    (list (getf entry :name) (getf entry :category) value latest status detail)))

(defun cell (x)
  "X as the text of one Markdown table cell: a | inside a tag name or an error would end the cell
early (the hub's review of #738), so it is escaped, and a line break becomes a space."
  (with-output-to-string (out)
    (loop for c across (princ-to-string (or x ""))
          do (case c
               (#\| (write-string "\\|" out))
               ((#\Newline #\Return) (write-char #\Space out))
               (t (write-char c out))))))

(defun write-markdown (rows stream)
  (format stream "Written by `scripts/check-upstream.lisp --online` (#716). Each row is an entry in `upstream.sexp`.~%~%")
  (dolist (group '((:behind "Behind the latest release")
                   (:unknown "Could not be checked")
                   (:held "Behind on purpose")
                   (:manual "Checked by hand")
                   (:current "Current")))
    (let ((these (remove (first group) rows :key #'fifth :test-not #'eq)))
      (when these
        (format stream "## ~A (~D)~%~%| Name | Pinned | Latest | Note |~%|---|---|---|---|~%" (second group) (length these))
        (dolist (r these)
          (format stream "| ~A | ~A | ~A | ~A |~%" (cell (first r)) (cell (third r)) (cell (fourth r)) (cell (sixth r))))
        (terpri stream)))))

;;; --- self-test -----------------------------------------------------------------------------

(defun self-test ()
  "The comparison rules on known inputs. Exit 0 when every case holds."
  (let ((cases '(("2.6.9" "2.6.9" :current) ("2.6.8" "2.6.9" :behind) ("v7" "v7.0.1" :current)
                 ("v6" "v7.0.1" :behind) ("1.9.12" "2.0.11" :behind) ("2026-01-01" "2026-01-01" :current)
                 ("2025-07-01" "2026-01-01" :behind) ("0.8.6-pg18" "0.8.7-pg18" :behind)
                 ("3.10.0" "3.9.4" :current)))
        (failed 0))
    (dolist (c cases)
      (let ((got (compare-pin (first c) (second c))))
        (unless (eq got (third c))
          (incf failed)
          (format t "  FAIL ~A against ~A: ~S, expected ~S~%" (first c) (second c) got (third c)))))
    (unless (and (string= "#.#.#-pg#" (version-shape "0.8.6-pg18")) (string= "#.#" (version-shape "24.04"))
                 (string= "2.0.11" (newest '("2.0.9" "2.0.11" "1.9.12"))) (not (stable-p "4.0.0-beta.1")))
      (incf failed)
      (format t "  FAIL version-shape, newest or stable-p~%"))
    (format t "check-upstream --self-test: ~D case~:P, ~D failed~%" (1+ (length cases)) failed)
    (uiop:quit (if (zerop failed) 0 1))))

;;; --- main ----------------------------------------------------------------------------------

(defun offline-check ()
  "Check upstream.sexp against the tree. Returns a list of (entry . value), and records each
problem in *PROBLEMS*. Exits 2 when upstream.sexp cannot be read."
  (let* ((path (merge-pathnames "upstream.sexp" *root*))
         (entries (handler-case (read-inventory path)
                    (error (e)
                      (format *error-output* "check-upstream: cannot read ~A: ~A~%"
                              (human-path:human-path path) e)
                      (uiop:quit 2))))
         (checked '()))
    (when (null entries)
      (format *error-output* "check-upstream: ~A holds no entries~%" (human-path:human-path path))
      (uiop:quit 2))
    (let ((names '()))
      (dolist (entry entries)
        (let ((name (and (listp entry) (getf entry :name))))
          (when (and name (member name names :test #'equal))
            (problem "~A: two entries have this name" name))
          (push name names)
          (let ((value (and (listp entry)
                            (handler-case (check-entry entry)
                              (error (e) (problem "~A: cannot be checked: ~A" name e) nil)))))
            (when value
              (push (cons entry value) checked)
              (format t "  ~42A ~10A ~A~%" name (string-downcase (getf entry :category)) value))))))
    (let ((items (pinned-items)))
      (dolist (item items)
        (unless (covers-p entries item)
          (problem "~A ~A has no entry in upstream.sexp" (second item) (third item))))
      (format t "~%check-upstream: ~D entr~:@P, ~D pin~:P in the tree, all covered unless listed below.~%"
              (length entries) (length items)))
    (nreverse checked)))

(defun report-problems-and-exit ()
  (dolist (p (reverse *problems*))
    (format t "  PROBLEM ~A~%" p))
  (format t "check-upstream: ~D problem~:P. See upstream.sexp's header.~%" (length *problems*))
  (uiop:quit 1))

(defun online (checked markdown)
  "Compare every checked entry with its upstream and print the result; write it as Markdown to
MARKDOWN when given. Exits 0 whatever is behind: being behind is a fact to act on, not a broken
build."
  (load-online-dependencies)
  (let ((rows (mapcar (lambda (c) (online-row (car c) (cdr c))) checked)))
    (format t "~%~42A ~10A ~22A ~22A ~A~%" "name" "status" "pinned" "latest" "note")
    (dolist (r rows)
      (format t "~42A ~10A ~22A ~22A ~@[~A~]~%" (first r) (string-downcase (fifth r)) (third r) (or (fourth r) "") (sixth r)))
    (format t "~%check-upstream --online: ~{~A~^, ~}~%"
            (loop for s in '(:behind :unknown :held :manual :current)
                  for n = (count s rows :key #'fifth)
                  when (plusp n) collect (format nil "~D ~A" n (string-downcase s))))
    (when markdown
      (with-open-file (out markdown :direction :output :if-exists :supersede :external-format :utf-8)
        (write-markdown rows out)))
    (uiop:quit 0)))

(defun main (args)
  (cond ((member "--self-test" args :test #'string=) (self-test))
        (t
         (let ((checked (offline-check)))
           (when *problems* (report-problems-and-exit))
           (if (member "--online" args :test #'string=)
               (online checked (second (member "--markdown" args :test #'string=)))
               (progn (format t "check-upstream: upstream.sexp and the tree agree.~%")
                      (uiop:quit 0)))))))

(main (rest sb-ext:*posix-argv*))
