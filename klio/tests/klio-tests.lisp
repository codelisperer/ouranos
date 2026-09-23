;;;; klio-tests.lisp --- the klio suite.
;;;;
;;;; It exists from commit one, before there is anything interesting to assert, so that the
;;;; system is LOADED by verify-tree from the moment it is registered. An unregistered
;;;; system and a broken one are indistinguishable at the gate, and a satellite nothing
;;;; loads is exactly the kind of thing that rots unnoticed.

(cl:defpackage #:klio/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:k #:klio)))

(cl:in-package #:klio/tests)

(def-suite klio :description "The klio content engine.")
;; A QUOTED SYMBOL in this package, per the tree's convention -- not the keyword. `run! :klio'
;; looks up a different symbol, finds no suite, prints "Didn't run anything...huh?" and
;; RETURNS TRUTHY. A :perform guarding on that return value passes with zero tests, which is
;; the exact shape verify-tree's zero-check rule exists to catch. Caught here first.
(defun run-tests () (run! 'klio))
(in-suite klio)

(test the-system-loads-and-reports-a-version
  (let ((v (k:version)))
    (is (stringp v))
    (is (plusp (length v)))))

;;; --- request-time scheduling (#359 Part 2, item 1) --------------------------
;;; The clock is an argument, so the scheduled case is testable without waiting.

(defparameter +noon+ (encode-universal-time 0 0 12 17 9 2026 0))
(defparameter +an-hour-earlier+ (- +noon+ 3600))
(defparameter +an-hour-later+ (+ +noon+ 3600))

(test a-post-with-no-dates-is-published
  (is (eq :published (k:visibility :now +noon+)))
  (is-true (k:visible-p :now +noon+)))

(test a-draft-is-not-published
  (is (eq :draft (k:visibility :draft t :now +noon+)))
  (is-false (k:visible-p :draft t :now +noon+)))

(test a-future-publish-at-is-scheduled-and-becomes-published-on-its-own
  "The whole of request-time scheduling: the same post, two clocks, no reload between them."
  (is (eq :scheduled (k:visibility :publish-at +an-hour-later+ :now +noon+)))
  (is (eq :published (k:visibility :publish-at +an-hour-later+ :now (+ +an-hour-later+ 1)))))

(test a-past-publish-at-is-published
  (is (eq :published (k:visibility :publish-at +an-hour-earlier+ :now +noon+))))

(test a-draft-with-a-past-date-is-still-a-draft
  "The flag is the author saying not yet. A date is not an argument against it."
  (is (eq :draft (k:visibility :draft t :publish-at +an-hour-earlier+ :now +noon+))))

;;; --- front-matter: splitting -----------------------------------------------

(test a-file-with-no-front-matter-is-all-body
  (multiple-value-bind (fm body) (k:split-front-matter "# Hello")
    (is (null fm))
    (is (string= "# Hello" body))))

(test the-front-matter-block-and-the-body-are-separated
  (multiple-value-bind (fm body)
      (k:split-front-matter (format nil "---~%title: A post~%---~%# Hello~%"))
    (is (search "title: A post" fm))
    (is (search "# Hello" body))))

(test unterminated-front-matter-is-an-error-not-a-file-without-any
  "Treating it as all-body would publish the metadata as prose."
  (signals k:unterminated-front-matter
    (k:split-front-matter (format nil "---~%title: A post~%# Hello~%"))))

;;; --- front-matter: the typed core and `extra' (#359 Q1, answer B) -----------

(defun %meta (yaml &rest args)
  (apply #'k:parse-front-matter yaml args))

(test the-core-keys-are-typed
  (let ((m (%meta (format nil "title: \"A post\"~%slug: a-post~%draft: true~%tags: [lisp, web]~%"))))
    (is (string= "A post" (k:content-meta-title m)))
    (is (string= "a-post" (k:content-meta-slug m)))
    (is-true (k:content-meta-draft m))
    (is (equal '("lisp" "web") (k:content-meta-tags m)))))

(test draft-false-is-not-draft
  "`false' is a value, not a missing key. Treating any present `draft' as true would make
`draft: false' publish nothing."
  (is-false (k:content-meta-draft (%meta "draft: false"))))

(test everything-outside-the-core-goes-to-extra-under-its-own-name
  (let ((m (%meta (format nil "title: \"x\"~%organisation: \"Rover\"~%"))))
    (is (string= "Rover" (k:extra m "organisation")))
    (is (null (k:extra m "title")) "a core key is not duplicated into extra")))

(test extra-carries-nested-values-which-is-what-real-content-needs
  "The CV is the first document klio must load, and a role's bullets are a list of objects
each with an optional list of metric objects. A flat string-to-string `extra' fails on it."
  (let* ((m (%meta (format nil "bullets:~%  - text: \"Reduced code size by 30%.\"~%    metrics:~%      - value: 30~%        unit: percent~%        measured: \"backend code size\"~%  - text: \"No metric here.\"~%")))
         (bullets (k:extra m "bullets")))
    (is (= 2 (length bullets)))
    (is (string= "Reduced code size by 30%."
                 (cdr (assoc "text" (first bullets) :test #'string=))))
    (let ((metric (first (cdr (assoc "metrics" (first bullets) :test #'string=)))))
      (is (= 30 (cdr (assoc "value" metric :test #'string=)))
          "a metric's value is a NUMBER, which is the point of carrying it as data")
      (is (string= "percent" (cdr (assoc "unit" metric :test #'string=)))))
    (is-false (assoc "metrics" (second bullets) :test #'string=)
              "a bullet without metrics carries none rather than an empty one")))

(test an-unknown-key-is-reported-once-naming-the-file-and-the-key
  "A typo'd `tgs:' is otherwise a tag that never appears, with nothing saying so."
  (let ((m (%meta "tgs: lisp" :file "post.md")))
    (is (= 1 (length (k:content-meta-warnings m))))
    (is (search "tgs" (first (k:content-meta-warnings m))))
    (is (search "post.md" (first (k:content-meta-warnings m))))))

(test a-key-the-site-declares-is-not-a-warning
  "The other direction: a site's own vocabulary is expected, not unknown."
  (is (null (k:content-meta-warnings
             (%meta "organisation: Rover" :known-extra '("organisation"))))))

(test warnings-are-returned-rather-than-signalled
  "So the loader can report every file's problems together instead of stopping at the first."
  (let ((m (%meta (format nil "tgs: lisp~%athur: bob~%") :file "post.md")))
    (is (= 2 (length (k:content-meta-warnings m))))))

;;; --- front-matter: what the parser refuses ---------------------------------
;;; It parses a documented subset rather than YAML. Refusing is the safety property: a
;;; parser that guessed at a construct it does not understand would produce content that is
;;; WRONG rather than absent, and nothing downstream could tell.

(test unsupported-constructs-are-refused-by-name
  (dolist (case '(("anchor"      "base: &a value")
                  ("alias"       "copy: *a")
                  ("multi-line"  "text: |")
                  ("folded"      "text: >")
                  ("flow map"    "m: {a: b}")))
    (destructuring-bind (label yaml) case
      (signals k:unsupported-front-matter (%meta yaml)
        "~A should be refused" label))))

(test a-tab-in-the-indentation-is-refused
  "YAML forbids it and the failure is otherwise invisible: the line looks indented."
  (signals k:unsupported-front-matter
    (%meta (format nil "a:~%~C b: c~%" #\Tab))))

(test the-subset-it-does-support-still-parses
  "The other direction, so the refusals above are not simply a parser that rejects everything."
  (let ((m (%meta (format nil "title: \"x\"~%count: 3~%flag: true~%empty: null~%list: [a, b]~%"))))
    (is (string= "x" (k:content-meta-title m)))
    (is (= 3 (k:extra m "count")))
    (is (eq t (k:extra m "flag")))
    (is (null (k:extra m "empty")))
    (is (equal '("a" "b") (k:extra m "list")))))

;;; --- a flow sequence written across lines -----------------------------------
;;;
;;; Found by running the first REAL content tree through the parser rather than a fixture:
;;; 14 of 15 files parsed, and the one that did not was a controlled skills list wrapped over
;;; two lines. YAML allows it, every other reader accepts it, and requiring the `]' on the
;;; opening line refused a construct this subset already understands. The shape below is
;;; that file's, copied rather than simplified -- a one-line fixture would have passed
;;; against the bug.

(test a-flow-sequence-may-be-written-across-lines
  (let* ((m (%meta (format nil "groups:~%  - name: \"AI and software delivery\"~%    skills: [\"Agentic systems\", \"Agent memory\",~%             \"Python\", \"C#\"]~%  - name: \"Data\"~%    skills: [\"PostgreSQL\", \"XTDB\"]~%")))
         (groups (k:extra m "groups")))
    (is (= 2 (length groups)) "the wrap must not end the sequence it is inside")
    (is (equal '("Agentic systems" "Agent memory" "Python" "C#")
               (cdr (assoc "skills" (first groups) :test #'string=)))
        "every item arrives, in order, across the line break")
    (is (string= "AI and software delivery"
                 (cdr (assoc "name" (first groups) :test #'string=)))
        "and the key beside it is unharmed")
    (is (equal '("PostgreSQL" "XTDB")
               (cdr (assoc "skills" (second groups) :test #'string=)))
        "the entry after the wrapped one still parses -- the joiner must consume exactly the
continuation lines and no more")))

(test a-bracket-inside-quotes-does-not-open-a-flow-sequence
  "The control for the joiner: if it counted brackets blindly it would swallow the next line
of any document mentioning one, and `C[++]' is the kind of thing a skills list contains."
  (let ((m (%meta (format nil "note: \"an array is written a[i]\"~%title: \"x\"~%"))))
    (is (string= "an array is written a[i]" (k:extra m "note")))
    (is (string= "x" (k:content-meta-title m))
        "the line after it is still its own line")))

(test a-flow-sequence-that-is-never-closed-is-still-refused
  "Wrapping is now allowed; unclosed is not. Without this the joiner would run off the end of
the front-matter and report something else, or nothing."
  (signals k:unsupported-front-matter
    (%meta (format nil "skills: [\"a\", \"b\",~%title: \"x\"~%"))))

;;; --- the search index (#359 Part 2, item 6) ---------------------------------

(defun %index-of (&rest docs)
  "DOCS are (key :title t :tags ts :body b) lists."
  (let ((index (k:make-search-index)))
    (dolist (d docs index)
      (apply #'k:index-document index (first d) (rest d)))))

(test tokenising-splits-on-anything-that-is-not-a-letter-or-digit
  "`hot-reload' indexes as two words, so either finds it. That is what someone typing into a
search box expects, and it is why the hyphen is a separator rather than part of the word."
  (is (equal '("hot" "reload") (k:tokenize "hot-reload")))
  (is (equal '("a" "b") (k:tokenize "a, b!")))
  (is (equal '("lisp2") (k:tokenize "Lisp2")))
  (is (null (k:tokenize "   ---   "))))

(test a-word-in-the-body-is-found
  (let ((ix (%index-of '("post-1" :title "About" :body "content lives in git"))))
    (is (equal '("post-1") (k:search-index-query ix "git")))))

(test a-word-in-no-document-finds-nothing
  (let ((ix (%index-of '("post-1" :title "About" :body "content lives in git"))))
    (is (null (k:search-index-query ix "mercurial")))))

(test a-title-hit-outranks-a-body-hit
  "The weights are the whole ranking story, so this is the test that they are applied."
  (let ((ix (%index-of '("titled" :title "coalton" :body "nothing relevant")
                       '("mentioned" :title "Something else" :body "a passing coalton mention"))))
    (is (equal '("titled" "mentioned") (k:search-index-query ix "coalton")))))

(test a-tag-hit-outranks-a-body-hit-and-loses-to-a-title
  (let ((ix (%index-of '("titled" :title "lisp" :body "x")
                       '("tagged" :title "x" :tags '("lisp") :body "x")
                       '("bodied" :title "x" :body "lisp"))))
    (is (equal '("titled" "tagged" "bodied") (k:search-index-query ix "lisp")))))

(test every-token-must-match-not-any
  "Two words should narrow the result, not widen it. A document with only one of them is not
an answer to the question that was asked."
  (let ((ix (%index-of '("both" :title "git content" :body "x")
                       '("one" :title "git" :body "x"))))
    (is (equal '("both") (k:search-index-query ix "git content")))))

(test an-empty-query-finds-nothing-rather-than-everything
  (let ((ix (%index-of '("post-1" :title "About" :body "x"))))
    (is (null (k:search-index-query ix "")))
    (is (null (k:search-index-query ix "   ")))))

(test search-is-case-insensitive-in-both-directions
  (let ((ix (%index-of '("post-1" :title "Coalton" :body "x"))))
    (is (equal '("post-1") (k:search-index-query ix "coalton")))
    (is (equal '("post-1") (k:search-index-query ix "COALTON")))))

;;; --- markdown (#359 Part 2, item 4) -----------------------------------------

(test markdown-becomes-html
  (is (search "<em>" (k:render-markdown "*emphasis*"))))

(test raw-html-in-content-is-escaped-by-default
  "The safety property is hyperion/markdown's, and this asserts klio did not lose it by
routing around it. A second path into 3bmd would be a second escaping policy."
  (let ((out (k:render-markdown "<script>alert(1)</script>")))
    (is-false (search "<script>" out))
    (is (search "&lt;script&gt;" out))))

(test trusted-content-can-opt-in-to-raw-html
  "The other direction: the escape is a default, not a wall. A site owner's own content may
legitimately contain markup."
  (is (search "<b>" (k:render-markdown "<b>bold</b>" :allow-html t))))

;;; --- dev mode (#359 Part 2, item 3) -----------------------------------------

(test production-is-the-default
  "A forgotten flag should fail closed. The opposite default makes an oversight a disclosure."
  (is-false (k:dev-mode-p)))

(test a-draft-is-hidden-in-production-and-shown-in-dev
  "The whole of the preview decision: same content, two audiences, no URL that can leak."
  (is-false (k:readable-p :draft t :now +noon+))
  (k:with-dev-mode ()
    (is-true (k:readable-p :draft t :now +noon+))))

(test a-scheduled-post-is-hidden-in-production-and-shown-in-dev
  (is-false (k:readable-p :publish-at +an-hour-later+ :now +noon+))
  (k:with-dev-mode ()
    (is-true (k:readable-p :publish-at +an-hour-later+ :now +noon+))))

(test published-content-is-readable-either-way
  (is-true (k:readable-p :now +noon+))
  (k:with-dev-mode () (is-true (k:readable-p :now +noon+))))

(test dev-mode-does-not-leak-out-of-its-scope
  "WITH-DEV-MODE binds rather than sets. A test or a dev entry point that turned it on
globally would turn it on for a production image in the same process."
  (k:with-dev-mode () (is-true (k:dev-mode-p)))
  (is-false (k:dev-mode-p)))

;;; --- loading a tree, and publishing it all at once (ADR-0001) ---------------
;;;
;;; ADR-0001's rule is one sentence -- validate the whole candidate tree, and if any file
;;; fails do not swap -- and every test below is one consequence of it. The two that matter
;;; most are the ones that assert IDENTITY rather than contents: after a refused reload the
;;; published tree must be the SAME OBJECT it was, because "did not swap" and "swapped
;;; something equivalent" are indistinguishable by value and only the first is atomic.

(defmacro with-content-dir ((dir &rest files) &body forms)
  "A real directory holding real content FILES -- (relative-path . text) -- deleted after.

Real files on a real disk, because the loader's job is to walk a tree and report what it
found there, and a fixture that hands it strings would test everything except that."
  (let ((stamp (gensym "STAMP")) (f (gensym "F")) (path (gensym "PATH")))
    `(let* ((,stamp (uiop:tmpize-pathname
                     (merge-pathnames "klio-content" (uiop:temporary-directory))))
            (,dir (uiop:ensure-directory-pathname ,stamp)))
       (ignore-errors (delete-file ,stamp))
       (ensure-directories-exist ,dir)
       (dolist (,f (list ,@(loop for (name . text) in files
                                 collect `(cons ,name ,text))))
         (let ((,path (merge-pathnames (car ,f) ,dir)))
           (ensure-directories-exist ,path)
           (with-open-file (out ,path :direction :output :if-exists :supersede)
             (write-string (cdr ,f) out))))
       (unwind-protect (progn ,@forms)
         (ignore-errors (uiop:delete-directory-tree ,dir :validate t))))))

(defparameter +good+ (format nil "---~%title: \"A post\"~%---~%~%Some prose.~%"))
(defparameter +also-good+ (format nil "---~%title: \"Another\"~%---~%~%More prose.~%"))
(defparameter +bad+ (format nil "---~%title: \"Broken\"~%m: {a: b}~%---~%~%Prose.~%"))
(defparameter +worse+ (format nil "---~%base: &anchor x~%---~%~%Prose.~%"))

(test a-tree-is-loaded-and-addressed-by-key
  (with-content-dir (dir ("one.md" . +good+) ("roles/two.md" . +also-good+))
    (multiple-value-bind (tree failures) (k:load-tree dir)
      (is (null failures))
      (is (= 2 (length (k:tree-documents tree))))
      (is-true (k:tree-document tree "one") "a file at the root is keyed by its name")
      (is-true (k:tree-document tree "roles/two")
               "and one in a subdirectory by its path, which is what a URL will carry")
      (is (string= "A post" (k:content-meta-title
                             (k:document-meta (k:tree-document tree "one")))))
      (is (search "Some prose" (k:document-html (k:tree-document tree "one")))
          "the body is rendered at load, so a body that cannot be rendered is a LOAD failure
rather than a 500 on one page later"))))

(defun another-name-for (dir)
  "A second, textually different name that resolves to DIR, or NIL if this platform has none.

Windows keeps an 8.3 alias for a long name -- `runneradmin' is also `RUNNER~1' -- and that is
the real #446: CI runners set TEMP to the aliased spelling. POSIX has no such thing, so a
symlink stands in for the nearest equivalent property: two spellings, one directory.

NIL RATHER THAN THE NAME WE WERE GIVEN. 8.3 generation is switched off on many volumes, and
there the short name comes back identical to the long one. Returning it would make the test
below pass while exercising nothing -- a fixture easier than reality, which is the shape the
tree has a rule about. The caller skips on NIL and says so."
  (let ((native (string-right-trim "\\/" (uiop:native-namestring dir))))
    #+win32
    (let ((short (ignore-errors
                  (uiop:run-program
                   (list "powershell" "-NoProfile" "-Command"
                         (format nil "(New-Object -ComObject Scripting.FileSystemObject).GetFolder('~A').ShortPath"
                                 native))
                   :output '(:string :stripped t) :error-output nil
                   :ignore-error-status t))))
      (when (and short (plusp (length short)) (string/= short native))
        (uiop:ensure-directory-pathname short)))
    #-win32
    (let ((link (concatenate 'string native "-by-another-name")))
      (when (zerop (nth-value 2 (uiop:run-program (list "ln" "-s" native link)
                                                  :output nil :error-output nil
                                                  :ignore-error-status t)))
        (uiop:ensure-directory-pathname link)))))

(test a-document-is-found-though-its-tree-was-opened-by-another-name
  "#446. A key is one namestring SUBTRACTED from another, so it holds only while the caller
and the walk spell the directory the same way. They need not: the walk resolves an 8.3 alias
or a symlink and hands back the resolved name, and then nothing is subtracted and every
document is keyed by its whole absolute path.

THE TRAP IS THAT NOTHING LOOKS WRONG. There is no failure, no warning and no signal -- the
tree loads clean, every file parsed and rendered, and answers NIL to every key. It cost two
sessions and eight merges on a red leg before anyone measured it.

IT SKIPS WHERE IT CANNOT FAIL, and that is the point of the guard rather than an apology for
it. The bug needs the walk to hand back a DIFFERENT SPELLING from the one it was given, and
only Windows does that -- measured at 36d3843: on Linux the symlink spelling survives the
walk, subtraction works, and this test passes with the fix reverted. A test that cannot fail
is not evidence, so on a platform that will not produce the disagreement this says so in the
skip line instead of reporting a green it has not earned."
  (with-content-dir (dir ("one.md" . +good+) ("roles/two.md" . +also-good+))
    (let* ((alias (another-name-for dir))
           (walked (and alias (first (klio::content-files alias))))
           ;; THE PRECONDITION, ASKED OF THE FILESYSTEM RATHER THAN ASSUMED FROM THE OS NAME.
           ;; 8.3 can be off on a volume, and some platform may one day start resolving what
           ;; it now preserves; either way what matters is whether these two names actually
           ;; disagree here, today, on this disk.
           (disagrees (and walked
                           (eq :absolute
                               (first (pathname-directory
                                       (parse-namestring (enough-namestring walked alias))))))))
      (cond
        ((null alias)
         (skip "this platform gave the directory no second name: 8.3 aliases may be off on this volume, or `ln -s' is unavailable"))
        ((not disagrees)
         #-win32 (ignore-errors (delete-file alias))
         (skip "the walk preserved the spelling it was given, so subtraction cannot fail here -- this is the Windows 8.3 case (#446) and only that leg exercises it"))
        (t
         (unwind-protect
              (progn
                ;; The control, in the same test: opened by the name it was made with.
                (is-true (k:tree-document (k:load-tree dir) "one")
                         "the control failed -- this tree is not addressable by either name")
                (multiple-value-bind (tree failures) (k:load-tree alias)
                  (is (null failures)
                      "a clean load is the whole difficulty: ~S" failures)
                  (is-true (k:tree-document tree "one")
                           "a document opened by the directory's other name is keyed by ~S instead"
                           (and tree (mapcar #'k:document-key (k:tree-documents tree))))
                  (is-true (k:tree-document tree "roles/two")
                           "and the same holds one directory down, which is what a URL carries")))
           #-win32 (ignore-errors (delete-file alias))))))))

(test one-bad-file-blocks-the-whole-tree
  "The rule itself. The control is the same directory without the bad file."
  (with-content-dir (dir ("one.md" . +good+) ("bad.md" . +bad+))
    (multiple-value-bind (tree failures) (k:load-tree dir)
      (is (null tree) "no tree is returned at all -- a partial tree would make every caller
decide again what ADR-0001 decided once")
      (is (= 1 (length failures)))
      (is (string= "bad" (k:load-failure-file (first failures)))
          "and the report names the file")))
  (with-content-dir (dir ("one.md" . +good+))
    (is-true (k:load-tree dir) "the control: the good file alone publishes")))

(test every-failing-file-is-reported-not-the-first
  "ADR-0001 says so plainly, and the reason is the loop it puts an author in otherwise:
fix one file, re-run, find the next."
  (with-content-dir (dir ("one.md" . +good+) ("bad.md" . +bad+) ("worse.md" . +worse+))
    (multiple-value-bind (tree failures) (k:load-tree dir)
      (is (null tree))
      (is (= 2 (length failures)))
      (is (equal '("bad" "worse") (sort (mapcar #'k:load-failure-file failures) #'string<))))))

(test boot-refuses-to-start-naming-the-files
  "At boot there is no previous tree, so `do not swap' has only one meaning. Refusing is
louder than starting without a page, and at boot someone is watching."
  (with-content-dir (dir ("one.md" . +good+) ("bad.md" . +bad+))
    (let ((site (k:make-site dir)))
      (signals k:content-load-failed (k:boot site))
      (is (null (k:site-tree site)) "nothing was published")
      (handler-case (k:boot site)
        (k:content-load-failed (c)
          (is (eq :boot (k:content-load-failed-phase c)))
          (is (search "bad" (princ-to-string c))
              "the report names the file, in its printed form -- which is what an operator
reads, not the slot")))))
  (with-content-dir (dir ("one.md" . +good+))
    (let ((site (k:make-site dir)))
      (is-true (k:boot site) "the control: a clean tree boots"))))

(test a-refused-reload-keeps-serving-the-same-tree-object
  "Not an equivalent tree -- the SAME one. `did not swap' and `swapped something equal' are
indistinguishable by value, and only the first is what atomicity means."
  (with-content-dir (dir ("one.md" . +good+))
    (let* ((site (k:make-site dir))
           (first-tree (k:boot site)))
      (with-open-file (out (merge-pathnames "bad.md" dir) :direction :output
                                                          :if-exists :supersede)
        (write-string +bad+ out))
      (multiple-value-bind (outcome report) (k:reload site)
        (is (eq :refused outcome))
        (is (= 1 (length report)))
        (is (eq first-tree (k:site-tree site))
            "the published tree is the same object it was before the failed reload")
        (is (= 1 (length (k:tree-documents (k:site-tree site))))
            "and it still serves what it served")))))

(test a-successful-reload-swaps-the-whole-tree-and-leaves-the-old-one-intact
  "The other half of atomicity: a request holding the old tree keeps a consistent snapshot,
because nothing in a published tree is ever mutated."
  (with-content-dir (dir ("one.md" . +good+))
    (let* ((site (k:make-site dir))
           (old (k:boot site)))
      (with-open-file (out (merge-pathnames "two.md" dir) :direction :output
                                                          :if-exists :supersede)
        (write-string +also-good+ out))
      (is (eq :published (k:reload site)))
      (is (not (eq old (k:site-tree site))) "a new tree is published")
      (is (= 2 (length (k:tree-documents (k:site-tree site)))))
      (is (= 1 (length (k:tree-documents old)))
          "and the tree a request was already reading is untouched"))))

(test reload-or-fail-signals-so-a-deploy-cannot-exit-zero-by-forgetting
  "ADR-0001's first consequence: a reload that reports errors has to be a FAILED deploy. A
returned value can be dropped; an unhandled condition exits non-zero on its own."
  (with-content-dir (dir ("one.md" . +good+))
    (let ((site (k:make-site dir)))
      (k:boot site)
      (is (eq :published (k:reload-or-fail site)) "a clean reload returns normally")
      (with-open-file (out (merge-pathnames "bad.md" dir) :direction :output
                                                          :if-exists :supersede)
        (write-string +bad+ out))
      (signals k:content-load-failed (k:reload-or-fail site))
      (handler-case (k:reload-or-fail site)
        (k:content-load-failed (c)
          (is (eq :reload (k:content-load-failed-phase c))
              "and it says which of the two outcomes this was, because the operator's next
move differs: a refused boot means the site is down, a refused reload means it is not"))))))

(test dev-mode-skips-the-bad-file-reports-it-and-publishes-the-rest
  "ADR-0001's documented exception. Someone editing wants to see the rest of the page they
are working on, and no reader is affected."
  (with-content-dir (dir ("one.md" . +good+) ("bad.md" . +bad+))
    (k:with-dev-mode ()
      (multiple-value-bind (tree failures) (k:load-tree dir)
        (is-true tree "dev mode publishes what loaded")
        (is (= 1 (length (k:tree-documents tree))))
        (is (= 1 (length failures)) "the failure is still reported rather than swallowed")
        (is-true (some (lambda (w) (search "bad" w)) (k:content-tree-warnings tree))
                 "and the skipped file is named in the tree's own warnings, so a dev page can
show what is missing from what it is showing")))
    ;; The control, and it is the property that matters: the exception is dev mode's alone.
    (is (null (k:load-tree dir))
        "outside dev mode the same directory publishes nothing")))

(test two-documents-claiming-one-slug-fail-as-a-tree
  "Neither file is wrong on its own -- the conflict exists only between them, which is the
clearest argument for validating the TREE rather than each file. Without the check, one page
silently shadows the other."
  (let ((a (format nil "---~%title: \"A\"~%slug: shared~%---~%~%A.~%"))
        (b (format nil "---~%title: \"B\"~%slug: shared~%---~%~%B.~%")))
    (with-content-dir (dir ("a.md" . a) ("b.md" . b))
      (multiple-value-bind (tree failures) (k:load-tree dir)
        (is (null tree))
        (is (= 2 (length failures)) "both sides of the conflict are named, not one")
        (is-true (search "shared" (k:load-failure-reason (first failures))))))
    (with-content-dir (dir ("a.md" . a))
      (is-true (k:load-tree dir)
               "the control: the same file alone is perfectly good, which is why no
per-file check could have caught this"))))

(test a-site-declares-its-own-vocabulary-once
  "Otherwise every document's `organisation' is reported as a surprise on every load, and a
report that is mostly noise is one nobody reads."
  (let ((role (format nil "---~%title: \"Role\"~%organisation: \"SoftCraft\"~%---~%~%R.~%")))
    (with-content-dir (dir ("r.md" . role))
      (let ((known (k:load-tree dir :known-extra '("organisation")))
            (unknown (k:load-tree dir)))
        (is (null (k:content-tree-warnings known)))
        (is (= 1 (length (k:content-tree-warnings unknown)))
            "the control: undeclared, the same key is reported")))))

;;; --- what is searchable, and why the default is everything ------------------
;;;
;;; Measured on the first real content tree rather than reasoned about: a CV whose roles
;;; carry their bullets as structured front-matter and whose markdown bodies are a heading
;;; and an HTML comment. Indexing the body alone returned ZERO hits for `MUMPS' and
;;; `bitemporal', both of which are in the document. An empty search looks, from the outside,
;;; exactly like a working search over a site with nothing to say.

(defparameter +role+
  (format nil "---~%title: \"Consulting Architect\"~%organisation: \"SoftCraft\"~%bullets:~%  - text: \"Modernised legacy MUMPS and Delphi coding patterns.\"~%    metrics:~%      - value: 75~%        unit: percent~%---~%~%# Consulting Architect~%~%<!-- the bullets live in the front-matter -->~%")
  "The shape of a real role file: the prose is in the front-matter, the body is a heading.")

(defun %hits (tree query)
  (mapcar (lambda (h) (if (consp h) (car h) h))
          (k:search-index-query (k:content-tree-index tree) query)))

(test structured-front-matter-is-searchable-by-default
  (with-content-dir (dir ("roles/r.md" . +role+))
    (let ((tree (k:load-tree dir :known-extra '("organisation" "bullets"))))
      (is (equal '("roles/r") (%hits tree "MUMPS"))
          "a word that appears only in a bullet is findable")
      (is (equal '("roles/r") (%hits tree "Delphi"))))
    ;; THE CONTROL, and it is the measurement that set the default: body-only finds nothing.
    (let ((tree (k:load-tree dir :known-extra '("organisation" "bullets") :index-extra nil)))
      (is (null (%hits tree "MUMPS"))
          "with the front-matter left out, the same word in the same document is unfindable
-- which is what the default was changed to avoid"))))

(test a-front-matter-key-is-not-a-searchable-word
  "`bullets' is a name the author gave a slot, not something the document says. Indexing keys
would make every role match a search for the schema."
  (with-content-dir (dir ("roles/r.md" . +role+))
    (let ((tree (k:load-tree dir :known-extra '("organisation" "bullets"))))
      ;; `metrics' and `unit', not `bullets'. The real file's body comment says "the bullets
      ;; live in this file's front-matter", so the word IS in the document -- asserting its
      ;; absence would have been an assertion about the fixture's prose rather than about
      ;; keys, and it failed for exactly that reason when first written.
      (is (null (%hits tree "metrics")))
      (is (null (%hits tree "unit")))
      (is (equal '("roles/r") (%hits tree "SoftCraft"))
          "the control: the VALUE beside those keys is indexed, so the absence above is
about keys and not about the walk failing to descend"))))

(test index-extra-may-name-the-keys-to-index
  (with-content-dir (dir ("roles/r.md" . +role+))
    (let ((tree (k:load-tree dir :known-extra '("organisation" "bullets")
                                 :index-extra '("bullets"))))
      (is (equal '("roles/r") (%hits tree "MUMPS")) "the named key is indexed")
      (is (null (%hits tree "SoftCraft"))
          "and one that is not named is not -- a key names a top-level entry, so a site can
index its prose without indexing its contact details"))))

;;; --- the tree as an application ---------------------------------------------
;;;
;;; The handler is tested as what it is -- a function from env to response -- rather than
;;; over a socket. klio declares no HTTP backend (#139, ADR-0011): the SITE picks one, and a
;;; suite that pulled one in to make a request would be choosing for every consumer and
;;; putting klio's checks behind a native dependency the gate treats as an opt-in axis. The
;;; end-to-end run over a real server, against the real content, is in the PR.

(defun %get (app path)
  "PATH through APP. Returns (values STATUS BODY HEADERS)."
  (let ((response (funcall app (list :request-method :get :path-info path))))
    (values (first response)
            (let ((body (third response)))
              (if (listp body) (first body) body))
            (second response))))

(defparameter +draft+
  (format nil "---~%title: \"Unfinished\"~%draft: true~%---~%~%Not ready.~%"))

(test the-index-lists-what-a-reader-may-see
  (with-content-dir (dir ("one.md" . +good+) ("secret.md" . +draft+))
    (let* ((site (k:make-site dir))
           (app (k:site-app site)))
      (k:boot site)
      (multiple-value-bind (status body) (%get app "/")
        (is (= 200 status))
        (is-true (search "A post" body) "a published document is listed")
        (is-false (search "Unfinished" body)
                  "a draft is not -- visibility is the request's question, and this is the
request")))))

(test a-document-is-served-at-its-key
  (with-content-dir (dir ("one.md" . +good+) ("roles/two.md" . +also-good+))
    (let* ((site (k:make-site dir))
           (app (k:site-app site)))
      (k:boot site)
      (multiple-value-bind (status body headers) (%get app "/roles/two")
        (is (= 200 status))
        (is-true (search "More prose" body) "the rendered markdown is the page's body")
        (is (string= "text/html; charset=utf-8" (getf headers :content-type))))
      (is (= 404 (%get app "/roles/two/")) "a key is a key; nothing is guessed at")
      (is (= 404 (%get app "/nope")) "and an unknown one is a 404"))))

(test a-draft-is-a-404-in-production-and-a-page-in-dev
  "Not a 403: that a draft EXISTS is itself unpublished information, and the two answers are
distinguishable from outside."
  (with-content-dir (dir ("secret.md" . +draft+))
    (let* ((site (k:make-site dir))
           (app (k:site-app site)))
      (k:boot site)
      (is (= 404 (%get app "/secret")))
      (k:with-dev-mode ()
        (multiple-value-bind (status body) (%get app "/secret")
          (is (= 200 status) "dev mode is where an author reads what they have not published")
          (is-true (search "Not ready" body)))))))

(test one-request-sees-one-tree-even-when-a-reload-lands-mid-render
  "ADR-0001's atomicity, from the consuming side. The theme below publishes a different tree
while the page it is rendering is being built -- which is what a hot reload does to an
in-flight request, without needing two threads to arrange it."
  (with-content-dir (dir ("one.md" . +good+))
    (let* ((site (k:make-site dir))
           (reloaded nil)
           (app (k:site-app site
                             :page-theme
                             (lambda (site document)
                               (unless reloaded
                                 (setf reloaded t)
                                 (with-open-file (out (merge-pathnames "one.md" dir)
                                                      :direction :output :if-exists :supersede)
                                   (write-string
                                    (format nil "---~%title: \"A post\"~%---~%~%REPLACED.~%")
                                    out))
                                 (k:reload site))
                               (k:default-page-theme site document)))))
      (k:boot site)
      (multiple-value-bind (status body) (%get app "/one")
        (is (= 200 status))
        (is-true reloaded "the control: the reload really did happen during the render")
        (is-true (search "Some prose" body)
                 "the request finishes against the tree it started with")
        (is-false (search "REPLACED" body)
                  "and does not pick up the tree that was published underneath it"))
      (multiple-value-bind (status body) (%get app "/one")
        (is (= 200 status))
        (is-true (search "REPLACED" body)
                 "while the NEXT request sees the new tree -- otherwise this test would pass
against a handler that had simply cached the page")))))

(test the-look-belongs-to-the-site
  "A theme is a function, and klio's defaults are plain on purpose. If a site could not
replace them it would be running a look nobody chose, shipped inside the library."
  (with-content-dir (dir ("one.md" . +good+))
    (let* ((site (k:make-site dir))
           (app (k:site-app site
                             :page-theme (lambda (site doc)
                                           (declare (ignore site))
                                           (format nil "<h1>~A, themed</h1>"
                                                   (k:content-meta-title (k:document-meta doc))))
                             :index-theme (lambda (site docs)
                                            (declare (ignore site))
                                            (format nil "<p>~D document(s)</p>" (length docs)))
                             :not-found (lambda (site key)
                                          (declare (ignore site))
                                          (format nil "<p>no ~A here</p>" key)))))
      (k:boot site)
      (multiple-value-bind (status body) (%get app "/one")
        (is (= 200 status))
        (is (string= "<h1>A post, themed</h1>" body)))
      (is (string= "<p>1 document(s)</p>" (nth-value 1 (%get app "/"))))
      (multiple-value-bind (status body) (%get app "/missing")
        (is (= 404 status) "a site's own 404 body is still a 404 status")
        (is (string= "<p>no missing here</p>" body))))))

;;; --- a small CL highlighter, at content-load time (#359 Q3) -----------------
;;;
;;; Ruled: a small CL highlighter, Lisp only, applied at load; other languages plain. The
;;; argument was that a site whose claim is "CL all the way down" should not ship JavaScript
;;; to colour its Lisp.
;;;
;;; What the implementation found: 3bmd's DEFAULT renderer is `colorize', so a ```lisp fence
;;; was already coloured server-side -- which is why klio renders through :nohighlight and
;;; re-marks the Lisp blocks itself. That makes the shape of :nohighlight's output something
;;; klio DEPENDS ON, so it is asserted here: an upgrade that changed it would otherwise stop
;;; highlighting silently, and an unhighlighted page looks exactly like a page with no Lisp.

(defun %md (&rest lines)
  (format nil "~{~A~^~%~}~%" lines))

(test the-code-block-shape-klio-depends-on
  "Provenance, not presence: klio's post-pass keys on `<pre class=\"LANG\"><code>', which is
3bmd's :nohighlight output. If that changes, this fails here rather than in production."
  (let ((html (k:render-markdown (%md "```lisp" "(list 1)" "```"))))
    (is-true (search "<pre class=\"lisp\"><code>" html)
             "the language has to survive into the markup, or nothing downstream can tell
which block is Lisp; got: ~S" html)))

(test lisp-is-highlighted-and-other-languages-are-left-alone
  (let ((lisp (k:render-markdown (%md "```lisp" "(defun f (x) x)" "```")))
        (shell (k:render-markdown (%md "```sh" "ls -l | grep defun" "```"))))
    (is-true (search "code-operator" lisp) "the head of a top-level form is marked")
    (is-true (search "&gt;" (k:render-markdown (%md "```lisp" "(> 1 2)" "```")))
             "and the source is escaped, not passed through")
    (is-false (search "<span" shell)
              "a shell block is plain -- Q3 rejected coverage for languages the site does
not use, and the control is that this block contains the word `defun' and is still plain")))

(test an-unlabelled-fence-stays-a-plain-pre
  (let ((html (k:render-markdown (%md "```" "plain text" "```"))))
    (is-true (search "<pre><code>plain text</code></pre>" html)
             "no empty class attribute: klio's HTML for a plain block should not differ from
every other renderer's for no reason; got ~S" html)))

(test the-lexical-classes-are-the-ones-a-reader-needs
  (let ((html (k:highlight-lisp
               (format nil "(defparameter *x* 42 #\\a :key \"text\") ; trailing~%"))))
    (is-true (search "code-operator" html) "defparameter, in head position")
    (is-true (search "code-number" html) "42")
    (is-true (search "code-char" html) "#\\a")
    (is-true (search "code-keyword" html) ":key")
    (is-true (search "code-string" html) "a string literal")
    (is-true (search "code-comment" html) "a trailing comment")))

(test a-nested-head-is-not-marked-because-a-parameter-list-is-not-a-call
  "`(x)' in (defun f (x) x) is not a call to x. Telling a parameter list from a call needs a
vocabulary of binding forms, which is a list that is wrong the first time a site writes a
macro -- so the claim is narrowed to the head of a TOP-LEVEL form instead of being guessed."
  (let ((html (k:highlight-lisp "(defun f (x) (+ x 1))")))
    (is (= 1 (count-if (lambda (i) (declare (ignore i)) t)
                       (loop with start = 0
                             for pos = (search "code-operator" html :start2 start)
                             while pos collect pos do (setf start (1+ pos)))))
        "exactly one operator span -- the top-level head, nothing deeper")
    (is-true (search "code-operator\">defun" html))))

(test a-trailing-sign-is-not-a-number
  "`1+' is a function. A reader would have caught that; a hand-rolled predicate has to be
told, and this is where it is told."
  (let ((html (k:highlight-lisp "(1+ 41)")))
    (is-false (search "code-number\">1+" html) "1+ is not a number")
    (is-true (search "code-number\">41" html) "the control: 41 is")))

(test a-code-block-is-text-and-is-never-read-or-evaluated
  "Content is untrusted input. The highlighter runs no reader, so a block containing a
read-time evaluation form is a block containing that text."
  (let* ((source "(list #.(+ 1 2) \"<script>\" &rest)")
         (html (k:highlight-lisp source)))
    (is-true (search "#.(" html) "the form is still there, as text")
    (is-false (search "<script>" html) "and the markup in it is escaped")
    (is-true (search "&lt;script&gt;" html))
    (is-true (search "&amp;rest" html) "an ampersand too, exactly once")))

(test an-unterminated-string-in-a-code-block-does-not-fail-the-page
  "Content is prose, not a compilation unit: refusing to render a page over a stray quote in
an illustration would make a typo a content-load failure."
  (let ((html (k:highlight-lisp "(format t \"unclosed")))
    (is-true (search "code-string" html))
    (is-true (search "unclosed" html))))

(test highlighting-happens-at-load-so-a-request-does-no-work
  "Q3 says at content-load time. The rendered HTML is stored on the document, so this is a
property of the tree rather than of a handler."
  (let ((doc (format nil "---~%title: \"Post\"~%---~%~%```lisp~%(defun f () 1)~%```~%")))
    (with-content-dir (dir ("p.md" . doc))
      (let* ((tree (k:load-tree dir))
             (document (k:tree-document tree "p")))
        (is-true (search "code-operator" (k:document-html document))
                 "the spans are in the tree, put there at load")))))
