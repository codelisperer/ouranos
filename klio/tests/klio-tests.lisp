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

;;; --- request-time scheduling (pre-publication issue 359 Part 2, item 1) --------------------------
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

;;; --- front-matter: the typed core and `extra' (pre-publication issue 359 Q1, answer B) -----------

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

;;; --- the search index (pre-publication issue 359 Part 2, item 6) ---------------------------------

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

;;; --- markdown (pre-publication issue 359 Part 2, item 4) -----------------------------------------

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

;;; --- dev mode (pre-publication issue 359 Part 2, item 3) -----------------------------------------

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
         (ignore-errors (aion/fs:delete-tree ,dir))))))

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
the real pre-publication issue 446: CI runners set TEMP to the aliased spelling. POSIX has no such thing, so a
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
  "pre-publication issue 446. A key is one namestring SUBTRACTED from another, so it holds only while the caller
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
         (skip "the walk preserved the spelling it was given, so subtraction cannot fail here -- this is the Windows 8.3 case (pre-publication issue 446) and only that leg exercises it"))
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
;;; over a socket. klio declares no HTTP backend (pre-publication issue 139, ADR-0011): the SITE picks one, and a
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

;;; --- a small CL highlighter, at content-load time (pre-publication issue 359 Q3) -----------------
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

;;; --- collections, for a site's theme (#353) ------------------------------------
;;;
;;; The shape the personal site's CV needs, with invented content: a directory of roles, each
;;; with a start date and bullets carrying metric maps in `extra', rendered newest first.

(defun %role (title start &key draft (metric 10))
  (format nil "---~%title: \"~A\"~@[~%start: \"~A\"~]~@[~%draft: ~A~]~%bullets:~%  - text: \"Did a thing.\"~%    metrics:~%      - value: ~D~%        unit: percent~%---~%~%# ~A~%"
          title start (and draft "true") metric title))

(defparameter +role-extra+ '("start" "bullets"))

(defun %titles (documents)
  (mapcar (lambda (d) (k:document-field d "title")) documents))

(test a-collection-is-the-readable-documents-under-a-directory-sorted-by-a-field
  (with-content-dir (dir ("roles/a.md" . (%role "Alpha" "2019-03-01"))
                         ("roles/b.md" . (%role "Beta" "2023-06-01" :metric 42))
                         ("roles/c.md" . (%role "Gamma" nil))
                         ("roles/d.md" . (%role "Delta" "2021-01-01" :draft t))
                         ("roles/older/e.md" . (%role "Epsilon" "2010-01-01"))
                         ("rolesish.md" . (%role "Not a role" "2030-01-01"))
                         ("about.md" . +good+))
    (let ((tree (k:load-tree dir :known-extra +role-extra+)))
      (is (equal '("Beta" "Alpha" "Epsilon" "Gamma")
                 (%titles (k:tree-collection tree "roles" :sort-by "start" :order :descending)))
          "newest first; the one without a start last; the draft absent; a subdirectory
included; a file whose name only begins with the collection's name is not a member")
      (is (equal '("Epsilon" "Alpha" "Beta" "Gamma")
                 (%titles (k:tree-collection tree "roles/" :sort-by "start")))
          "ascending, and a trailing slash on the name changes nothing")
      (let ((beta (first (k:tree-collection tree "roles" :sort-by "start" :order :descending))))
        (is (= 42 (cdr (assoc "value" (first (cdr (assoc "metrics" (first (k:document-field beta "bullets"))
                                                           :test #'string=)))
                              :test #'string=)))
            "the nested front matter comes through as data a theme can read a metric from"))
      (k:with-dev-mode ()
        (is (member "Delta" (%titles (k:tree-collection tree "roles")) :test #'equal)
            "the control: in dev mode the draft is a member")))))

(test a-collection-sorts-by-a-core-field-and-keeps-key-order-for-ties
  (with-content-dir (dir ("notes/b.md" . (format nil "---~%title: \"Same\"~%date: 2024-01-01~%---~%x~%"))
                         ("notes/a.md" . (format nil "---~%title: \"Same\"~%date: 2024-01-01~%---~%y~%"))
                         ("notes/c.md" . (format nil "---~%title: \"Early\"~%date: 2020-01-01~%---~%z~%")))
    (let ((tree (k:load-tree dir)))
      (is (equal '("notes/c" "notes/a" "notes/b")
                 (mapcar #'k:document-key (k:tree-collection tree "notes" :sort-by "date")))
          "a and b tie on date and stay in key order")
      (is (equal '("notes/a" "notes/b" "notes/c")
                 (mapcar #'k:document-key (k:tree-collection tree "notes")))
          "unsorted is key order")
      (is (typep (nth-value 1 (ignore-errors (k:tree-collection tree "notes" :order :sideways)))
                 'type-error)))))

(test a-document-is-found-by-its-slug-only-when-a-reader-may-see-it
  (with-content-dir (dir ("skills.md" . (format nil "---~%title: \"Skills\"~%slug: \"toolbox\"~%---~%x~%"))
                         ("secret.md" . +draft+))
    (let* ((site (k:make-site dir)))
      (k:boot site)
      (is (equal "Skills" (k:document-field (k:document-by-slug site "toolbox") "title"))
          "the front matter's slug, not the file name")
      (is (null (k:document-by-slug site "skills")))
      (is (null (k:document-by-slug site "secret")) "a draft is not found, so a link cannot reveal it")
      (k:with-dev-mode ()
        (is (not (null (k:document-by-slug site "secret"))) "the control: in dev mode it is")))))

(test document-field-reads-core-fields-and-extra-keys
  (with-content-dir (dir ("roles/a.md" . (%role "Alpha" "2019-03-01")))
    (let ((d (k:tree-document (k:load-tree dir :known-extra +role-extra+) "roles/a")))
      (is (equal "Alpha" (k:document-field d "title")))
      (is (equal "a" (k:document-field d "slug")) "the resolved slug")
      (is (equal "2019-03-01" (k:document-field d "start")) "an extra key")
      (is (null (k:document-field d "nope"))))))

(test a-theme-reads-its-collection-from-the-requests-tree-even-when-a-reload-lands
  "The collection half of ADR-0001's atomicity. The index theme below publishes a tree with a
third role before it asks for the collection, which is what a reload landing mid-request does.
It must still list the two roles of the tree the request started with."
  (with-content-dir (dir ("roles/a.md" . (%role "Alpha" "2019-03-01"))
                         ("roles/b.md" . (%role "Beta" "2023-06-01")))
    (let* ((site (k:make-site dir :known-extra +role-extra+))
           (seen nil)
           (app (k:site-app site
                            :index-theme
                            (lambda (site documents)
                              (declare (ignore documents))
                              (with-open-file (out (merge-pathnames "roles/c.md" dir)
                                                   :direction :output :if-exists :supersede)
                                (write-string (%role "Gamma" "2024-01-01") out))
                              (k:reload site)
                              (setf seen (%titles (k:collection site "roles" :sort-by "start")))
                              "ok"))))
      (k:boot site)
      (%get app "/")
      (is (equal '("Alpha" "Beta") seen) "the request's tree, not the one published mid-request")
      (is (= 3 (length (k:collection site "roles")))
          "the control: outside a request, CURRENT-TREE is the newly published tree"))))

;;; --- the static export (#353) ------------------------------------------------------------

(defmacro with-export-dir ((dir) &body body)
  "A fresh directory name, not created, deleted afterwards."
  `(let ((,dir (uiop:ensure-directory-pathname
                (uiop:tmpize-pathname (merge-pathnames "klio-export" (uiop:temporary-directory))))))
     (ignore-errors (delete-file (string-right-trim "/" (namestring ,dir))))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree ,dir :validate t)))))

(defun %file-text (dir relative)
  (uiop:read-file-string (merge-pathnames relative dir) :external-format :utf-8))

(test the-export-writes-every-readable-page-through-the-sites-themes
  (with-content-dir (src ("one.md" . +good+) ("roles/two.md" . +also-good+) ("secret.md" . +draft+))
    (with-export-dir (out)
      (let ((site (k:make-site src)))
        (k:boot site)
        (let ((written (k:export-site site out
                                      :page-theme (lambda (site d) (declare (ignore site))
                                                    (format nil "PAGE ~A" (k:document-key d))))))
          (is (equal '("404.html" "index.html" "one.html" "roles/two.html" "search.json")
                     (sort (copy-list written) #'string<))
              "no feeds without a base URL, and no tag pages without tags")
          (is (equal "PAGE roles/two" (%file-text out "roles/two.html")) "the site's page theme")
          (is (search "A post" (%file-text out "index.html")) "the index theme lists what a reader may see")
          (is (not (search "Unfinished" (%file-text out "index.html"))))
          (is (not (probe-file (merge-pathnames "secret.html" out))) "a draft is not exported"))))))

(test the-directory-layout-writes-an-index-file-per-page
  (with-content-dir (src ("roles/two.md" . +also-good+))
    (with-export-dir (out)
      (let ((site (k:make-site src)))
        (k:boot site)
        (k:export-site site out :layout :directory)
        (is (probe-file (merge-pathnames "roles/two/index.html" out)))))))

(test a-theme-that-fails-writes-nothing
  (with-content-dir (src ("one.md" . +good+) ("two.md" . +also-good+))
    (with-export-dir (out)
      (let ((site (k:make-site src)))
        (k:boot site)
        (is (typep (nth-value 1 (ignore-errors
                                 (k:export-site site out
                                                :page-theme (lambda (site d) (declare (ignore site))
                                                              (if (string= "two" (k:document-key d))
                                                                  (error "a theme bug")
                                                                  "fine")))))
                   'simple-error))
        (is (not (uiop:directory-exists-p out)) "not even the pages that rendered")))))

(test an-export-refuses-a-directory-that-holds-files-unless-told-to-clean-it
  (with-content-dir (src ("one.md" . +good+))
    (with-export-dir (out)
      (let ((site (k:make-site src))
            (stale (merge-pathnames "deleted-post.html" out)))
        (k:boot site)
        (ensure-directories-exist stale)
        (with-open-file (s stale :direction :output) (write-string "old" s))
        (is (typep (nth-value 1 (ignore-errors (k:export-site site out))) 'k:export-refused))
        (is (probe-file stale) "nothing was touched")
        (k:export-site site out :clean t)
        (is (not (probe-file stale)) "with :clean, an earlier export's page is gone")
        (is (probe-file (merge-pathnames "one.html" out)))))))

(test an-export-refuses-to-clean-the-content-directory-or-its-parent
  ;; THE PARENT IS A DIRECTORY THIS TEST MADE. If the guard regressed, :CLEAN would delete the
  ;; directory it was pointed at, so the test must never point it at anything it does not own,
  ;; such as the system's temporary directory.
  (with-export-dir (outer)
    (let* ((content (merge-pathnames "content/" outer))
           (file (merge-pathnames "one.md" content)))
      (ensure-directories-exist file)
      (with-open-file (s file :direction :output) (write-string +good+ s))
      (let ((site (k:make-site content)))
        (k:boot site)
        (is (typep (nth-value 1 (ignore-errors (k:export-site site content :clean t)))
                   'k:export-refused)
            "the content directory itself")
        (is (typep (nth-value 1 (ignore-errors (k:export-site site outer :clean t)))
                   'k:export-refused)
            "a directory that contains it")
        (is (probe-file file) "the content is still there")))))

(test an-export-needs-published-content
  (with-content-dir (src ("one.md" . +good+))
    (with-export-dir (out)
      (is (typep (nth-value 1 (ignore-errors (k:export-site (k:make-site src) out)))
                 'k:export-refused)))))

(test an-exported-theme-reads-collections-from-the-exported-tree
  (with-content-dir (src ("roles/a.md" . (%role "Alpha" "2019-03-01"))
                         ("roles/b.md" . (%role "Beta" "2023-06-01")))
    (with-export-dir (out)
      (let ((site (k:make-site src :known-extra +role-extra+)))
        (k:boot site)
        (k:export-site site out
                       :index-theme (lambda (site documents)
                                      (declare (ignore documents))
                                      (format nil "~{~A~^,~}"
                                              (%titles (k:collection site "roles" :sort-by "start"
                                                                                  :order :descending)))))
        (is (equal "Beta,Alpha" (%file-text out "index.html")))))))

;;; --- a controlled vocabulary (#353) ------------------------------------------------------
;;;
;;; The personal site's shape, with invented labels: `groups', each with a `name' and a list
;;; of `skills', in one file; references in a page's `skills' and in a bullet's `skills'.

(defparameter +skills+
  (format nil "---~%title: \"Skills\"~%groups:~%  - name: \"Languages\"~%    skills: [\"C#\", \"C++\", \"Common Lisp\"]~%  - name: \"Platforms\"~%    skills: [\".NET\", \"Serverless functions\"]~%---~%~%Skills.~%"))

(defun %skilled-role (title page-skills bullet-skills)
  (format nil "---~%title: \"~A\"~%skills: [~{\"~A\"~^, ~}]~%bullets:~%  - text: \"Did a thing.\"~%    skills: [~{\"~A\"~^, ~}]~%---~%~%x~%"
          title page-skills bullet-skills))

(defparameter +skills-vocabulary+
  (k:make-vocabulary "skills" :source "skills" :entries '("groups" "skills")
                              :references '(("skills") ("bullets" "skills"))))

(defparameter +skills-extra+ '("groups" "skills" "bullets"))

(defun %load-with-skills (dir)
  (k:load-tree dir :known-extra +skills-extra+ :vocabularies (list +skills-vocabulary+)))

(test references-to-known-labels-load-and-labels-match-exactly
  (with-content-dir (dir ("skills.md" . +skills+)
                         ("roles/a.md" . (%skilled-role "A" '("C#" ".NET") '("C++"))))
    (multiple-value-bind (tree failures) (%load-with-skills dir)
      (is (null failures))
      (is (not (null tree)))
      (is (equal '("C#" "C++" "Common Lisp" ".NET" "Serverless functions")
                 (gethash "skills" (k:content-tree-vocabularies tree)))
          "every group's skills, in the order the file lists them"))))

(test an-unknown-label-is-a-load-failure-naming-both-files
  (with-content-dir (dir ("skills.md" . +skills+)
                         ("roles/a.md" . (%skilled-role "A" '("c#") '("C++")))
                         ("roles/b.md" . (%skilled-role "B" '("C#") '("Cobol"))))
    (multiple-value-bind (tree failures) (%load-with-skills dir)
      (is (null tree) "nothing is published")
      (is (equal '("roles/a" "roles/b") (sort (mapcar #'k:load-failure-file failures) #'string<))
          "the referring files, one failure each: lowercase c# is not C#, and a bullet's
reference is checked like the page's")
      (let ((reason (k:load-failure-reason (find "roles/b" failures :key #'k:load-failure-file
                                                                   :test #'string=))))
        (is (search "\"Cobol\"" reason) "the label")
        (is (search "bullets > skills" reason) "where it was")
        (is (search "in skills" reason) "and the file that holds the list")))
    (is (typep (nth-value 1 (ignore-errors
                             (k:boot (k:make-site dir :known-extra +skills-extra+
                                                      :vocabularies (list +skills-vocabulary+)))))
               'k:content-load-failed)
        "at boot the site refuses to start")))

(test a-bad-reference-at-reload-keeps-the-last-good-tree
  (with-content-dir (dir ("skills.md" . +skills+)
                         ("roles/a.md" . (%skilled-role "A" '("C#") '())))
    (let ((site (k:make-site dir :known-extra +skills-extra+ :vocabularies (list +skills-vocabulary+))))
      (k:boot site)
      (with-open-file (out (merge-pathnames "roles/a.md" dir) :direction :output :if-exists :supersede)
        (write-string (%skilled-role "A edited" '("Fortran") '()) out))
      (is (eq :refused (k:reload site)))
      (is (equal "A" (k:document-field (k:tree-document (k:site-tree site) "roles/a") "title"))
          "the edit that broke the reference is not served"))))

(test a-missing-or-empty-vocabulary-source-is-a-failure
  (with-content-dir (dir ("roles/a.md" . (%skilled-role "A" '("C#") '())))
    (let ((failures (nth-value 1 (%load-with-skills dir))))
      (is (find "skills" failures :key #'k:load-failure-file :test #'string=)
          "no skills document at all")))
  (with-content-dir (dir ("skills.md" . +good+))
    (let ((failures (nth-value 1 (%load-with-skills dir))))
      (is (search "finds no entries" (k:load-failure-reason (first failures)))
          "a skills document with nothing at the declared path"))))

(test a-theme-looks-up-vocabulary-entries-from-the-requests-tree
  (with-content-dir (dir ("skills.md" . +skills+))
    (let* ((site (k:make-site dir :known-extra +skills-extra+ :vocabularies (list +skills-vocabulary+)))
           (seen nil)
           (app (k:site-app site :index-theme
                            (lambda (site documents)
                              (declare (ignore documents))
                              (setf seen (list (k:vocabulary-entry-p site "skills" ".NET")
                                               (k:vocabulary-entry-p site "skills" "Cobol")
                                               (length (k:vocabulary-entries site "skills"))))
                              "ok"))))
      (k:boot site)
      (%get app "/")
      (is (equal '(t nil 5) seen))
      (is (null (k:vocabulary-entries site "tools")) "a vocabulary the site did not declare"))))

(test make-vocabulary-refuses-a-malformed-declaration
  (is (typep (nth-value 1 (ignore-errors (k:make-vocabulary "x" :source "" :entries '("a")))) 'error))
  (is (typep (nth-value 1 (ignore-errors (k:make-vocabulary "x" :source "s" :entries "a"))) 'error))
  (is (typep (nth-value 1 (ignore-errors (k:make-vocabulary "x" :source "s" :entries '("a")
                                                               :references '("skills"))))
             'error)
      "a reference is a path, a list of keys, not a key"))

;;; --- reloading on change, for development (#353) ----------------------------------------

(defun %await (predicate &key (seconds 10))
  "Call PREDICATE every 20 ms until it is true or SECONDS pass; return its last value."
  (loop with deadline = (+ (get-internal-real-time) (* seconds internal-time-units-per-second))
        for value = (funcall predicate)
        until (or value (> (get-internal-real-time) deadline))
        do (sleep 0.02)
        finally (return value)))

(defun %write-content (dir name text)
  (with-open-file (out (merge-pathnames name dir) :direction :output :if-exists :supersede
                                                  :if-does-not-exist :create)
    (write-string text out)))

(defun %served-title (site key)
  (let ((d (k:tree-document (k:site-tree site) key)))
    (and d (k:document-field d "title"))))

(test the-watcher-reloads-an-edit-and-keeps-the-last-good-tree-on-a-bad-one
  (with-content-dir (dir ("one.md" . +good+))
    (let* ((site (k:make-site dir))
           (outcomes '())
           (lock (sb-thread:make-mutex))
           (watcher nil))
      (k:boot site)
      (unwind-protect
           (progn
             (setf watcher (k:watch-site site :interval 0.05
                                              :on-reload (lambda (outcome failures)
                                                           (declare (ignore failures))
                                                           (sb-thread:with-mutex (lock)
                                                             (push outcome outcomes)))))
             (%write-content dir "one.md" (format nil "---~%title: \"Edited\"~%---~%~%x~%"))
             (is (%await (lambda () (equal "Edited" (%served-title site "one"))))
                 "an edited file is served after the next poll")
             (%write-content dir "one.md" +bad+)
             (is (%await (lambda () (sb-thread:with-mutex (lock) (eq :refused (first outcomes)))))
                 "a malformed edit is refused")
             (is (equal "Edited" (%served-title site "one")) "and the last good version is still served")
             (%write-content dir "two.md" +also-good+)
             (%write-content dir "one.md" (format nil "---~%title: \"Fixed\"~%---~%~%x~%"))
             (is (%await (lambda () (equal "Fixed" (%served-title site "one"))))
                 "fixing it publishes again, the watcher having kept running")
             (is (equal "Another" (%served-title site "two")) "a new file is picked up"))
        (when watcher (k:stop-watching watcher))))))

(test a-same-length-edit-in-the-same-second-is-still-seen
  ;; A write date can have one-second resolution, so the snapshot includes a hash of the text.
  (with-content-dir (dir ("one.md" . (format nil "---~%title: \"Aaaa\"~%---~%~%x~%")))
    (let ((before (k:content-snapshot dir)))
      (%write-content dir "one.md" (format nil "---~%title: \"Bbbb\"~%---~%~%x~%"))
      (is (not (equal before (k:content-snapshot dir)))))))

(test stop-watching-ends-the-watcher
  (with-content-dir (dir ("one.md" . +good+))
    (let* ((site (k:make-site dir))
           (watcher (progn (k:boot site) (k:watch-site site :interval 0.05)))
           (thread (klio::watcher-thread watcher)))
      (is (sb-thread:thread-alive-p thread) "control: it is running")
      (k:stop-watching watcher)
      (is (not (sb-thread:thread-alive-p thread)))
      (k:stop-watching watcher)
      (is (= 0 (k:watcher-reloads watcher)) "and nothing changed, so nothing was reloaded"))))

;;; --- dates, and scheduling through the handler (#359) -------------------------------------

(test iso-dates-parse-to-universal-times-in-utc
  (let ((midnight (encode-universal-time 0 0 0 1 1 2030 0)))
    (is (= midnight (k:parse-iso-date "2030-01-01")) "a date is midnight UTC")
    (is (= (+ midnight (* 9 3600)) (k:parse-iso-date "2030-01-01T09:00:00Z")))
    (is (= (+ midnight (* 9 3600)) (k:parse-iso-date "2030-01-01 09:00")) "a space, no seconds, no zone")
    (is (= (+ midnight (* 7 3600)) (k:parse-iso-date "2030-01-01T09:00:00+02:00"))
        "09:00 at +02:00 is 07:00 UTC")
    (dolist (bad '("2030-13-01" "2030-01-01T25:00" "01/01/2030" "2030-01-01T09:00:00+2" "soon" ""))
      (is (typep (nth-value 1 (ignore-errors (k:parse-iso-date bad))) 'k:invalid-date)
          "~S is refused" bad))))

(test feed-dates-are-written-as-rss-and-atom-require
  (let ((time (encode-universal-time 5 4 3 2 1 2030 0)))
    (is (string= "Wed, 02 Jan 2030 03:04:05 GMT" (k:rfc-822-date time)))
    (is (string= "2030-01-02T03:04:05Z" (k:rfc-3339-date time)))))

(defparameter +scheduled+ (format nil "---~%title: \"Later\"~%publish-at: 2030-01-01~%---~%~%x~%"))

(test a-scheduled-document-waits-for-its-time-through-the-handler
  (with-content-dir (dir ("later.md" . +scheduled+) ("now.md" . +good+))
    (let ((site (k:make-site dir)))
      (k:boot site)
      (let ((app (k:site-app site)))
        (is (= 404 (%get app "/later")) "with no clock given, the request's own time is used")
        (is (not (search "Later" (nth-value 1 (%get app "/")))) "and the index does not list it"))
      (let ((app (k:site-app site :now (encode-universal-time 0 0 0 2 1 2030 0))))
        (is (= 200 (%get app "/later")) "once its time has come, it is served")))))

(test a-malformed-publish-at-fails-the-load-instead-of-publishing
  (with-content-dir (dir ("later.md" . (format nil "---~%title: \"Later\"~%publish-at: next Tuesday~%---~%x~%")))
    (multiple-value-bind (tree failures) (k:load-tree dir)
      (is (null tree))
      (is (search "publish-at" (k:load-failure-reason (first failures)))))))

(test a-date-that-is-not-iso-is-a-warning-and-still-displays
  (with-content-dir (dir ("p.md" . (format nil "---~%title: \"P\"~%date: \"Spring 2024\"~%---~%x~%")))
    (let* ((tree (k:load-tree dir))
           (d (k:tree-document tree "p")))
      (is (equal "Spring 2024" (k:document-field d "date")))
      (is (null (k:content-meta-timestamp (k:document-meta d))))
      (is (find-if (lambda (w) (search "not an ISO 8601 date" w)) (k:content-tree-warnings tree))))))

;;; --- feeds (#353) ---------------------------------------------------------------------------

(defun %post (title date &key tags draft)
  (format nil "---~%title: \"~A\"~@[~%date: ~A~]~@[~%tags: [~{\"~A\"~^, ~}]~]~@[~%draft: ~A~]~%---~%~%Body of ~A & more.~%"
          title date tags (and draft "true") title))

(defun %xml (text) (plump:parse text))

(defun %xml-texts (root tag)
  (mapcar #'plump:text (plump:get-elements-by-tag-name root tag)))

(test the-rss-feed-is-rss-2-with-absolute-links-newest-first
  (with-content-dir (dir ("posts/a.md" . (%post "Old & first" "2024-01-01"))
                         ("posts/b.md" . (%post "New" "2025-06-01"))
                         ("posts/c.md" . (%post "Undated" nil))
                         ("posts/d.md" . (%post "Draft" "2025-07-01" :draft t))
                         ("about.md" . (%post "About" "2025-08-01")))
    (let ((site (k:make-site dir)))
      (k:boot site)
      (let ((app (k:site-app site :base-url "https://example.org/" :feed-collection "posts"
                                  :feed-title "Example")))
        (multiple-value-bind (status body headers) (%get app "/feed.xml")
          (is (= 200 status))
          (is (search "application/rss+xml" (getf headers :content-type)))
          (let* ((root (%xml body))
                 (rss (first (plump:get-elements-by-tag-name root "rss"))))
            (is (equal "2.0" (plump:attribute rss "version")))
            (is (= 1 (length (plump:get-elements-by-tag-name root "channel"))))
            (is (equal '("Example" "New" "Old & first") (%xml-texts root "title"))
                "the channel's title, then each item's, the ampersand unescaped by the parser")
            ;; GUID rather than LINK: plump parses as HTML, where <link> is a void element and
            ;; its text is lost. Each item's guid is its absolute link.
            (is (equal '("https://example.org/posts/b" "https://example.org/posts/a")
                       (%xml-texts root "guid"))
                "absolute item links, newest first; the undated post, the draft and the page outside
the collection are absent")
            (is (equal '("Sun, 01 Jun 2025 00:00:00 GMT" "Mon, 01 Jan 2024 00:00:00 GMT")
                       (%xml-texts root "pubDate")))))))))

(test the-atom-feed-has-what-atom-requires
  (with-content-dir (dir ("posts/a.md" . (%post "One" "2024-01-01")))
    (let ((site (k:make-site dir)))
      (k:boot site)
      (multiple-value-bind (status body) (%get (k:site-app site :base-url "https://example.org")
                                               "/atom.xml")
        (is (= 200 status))
        (let* ((root (%xml body))
               (feed (first (plump:get-elements-by-tag-name root "feed")))
               (entry (first (plump:get-elements-by-tag-name root "entry"))))
          (is (equal "http://www.w3.org/2005/Atom" (plump:attribute feed "xmlns")))
          (dolist (required '("id" "title" "updated"))
            (is (plump:get-elements-by-tag-name entry required) "an entry has ~A" required))
          (is (equal "https://example.org/posts/a"
                     (plump:text (first (plump:get-elements-by-tag-name entry "id")))))
          (is (equal "2024-01-01T00:00:00Z"
                     (plump:text (first (plump:get-elements-by-tag-name entry "updated"))))))))))

(test there-are-no-feeds-without-a-base-url
  (with-content-dir (dir ("posts/a.md" . (%post "One" "2024-01-01")))
    (let ((site (k:make-site dir)))
      (k:boot site)
      (is (= 404 (%get (k:site-app site) "/feed.xml")) "relative links would be unfollowable")
      (is (= 404 (%get (k:site-app site) "/atom.xml"))))))

;;; --- tags and pagination (#353) ------------------------------------------------------------

(test tag-slugs-keep-c-sharp-and-c-plus-plus-apart
  (is (equal "common-lisp" (k:tag-slug "Common Lisp")))
  (is (equal "c-sharp" (k:tag-slug "C#")))
  (is (equal "c-plus-plus" (k:tag-slug "C++")))
  (is (equal "net" (k:tag-slug ".NET")))
  (is (equal "c" (k:tag-slug "C"))))

(defun %titles-listed (html titles)
  (remove-if-not (lambda (title) (search title html)) titles))

(test a-tag-has-a-page-and-listings-paginate-at-stable-urls
  (with-content-dir (dir ("posts/a.md" . (%post "Alpha" "2024-01-01" :tags '("Lisp" "C#")))
                         ("posts/b.md" . (%post "Beta" "2024-02-01" :tags '("Lisp")))
                         ("posts/c.md" . (%post "Gamma" "2024-03-01" :tags '("Lisp")))
                         ("posts/d.md" . (%post "Delta" "2024-04-01" :tags '("Lisp") :draft t)))
    (let* ((site (k:make-site dir))
           (pages '())
           (app (k:site-app site :per-page 2
                                 :index-theme (lambda (site documents) (declare (ignore site))
                                                (push (list k:*page-number* k:*page-count*) pages)
                                                (format nil "~{~A ~}" (mapcar (lambda (d) (k:document-field d "title")) documents))))))
      (k:boot site)
      (let ((titles '("Alpha" "Beta" "Gamma" "Delta")))
        (is (equal '("Alpha" "Beta") (%titles-listed (nth-value 1 (%get app "/")) titles)) "page 1 is /")
        (is (equal '("Gamma") (%titles-listed (nth-value 1 (%get app "/page/2/")) titles)) "page 2")
        (is (equal '((2 2) (1 2)) pages) "the theme is told which page of how many")
        (is (= 404 (%get app "/page/3/")) "past the end")
        (is (= 404 (%get app "/page/1/")) "page 1 has one URL, /")
        (is (= 404 (%get app "/page/2")) "and a listing URL ends in a slash")
        (is (equal '("Alpha" "Beta") (%titles-listed (nth-value 1 (%get app "/tags/lisp/")) titles))
            "a tag's page, paginated the same way; the draft is not counted")
        (is (equal '("Gamma") (%titles-listed (nth-value 1 (%get app "/tags/lisp/page/2/")) titles)))
        (is (equal '("Alpha") (%titles-listed (nth-value 1 (%get app "/tags/c-sharp/")) titles)))
        (is (= 404 (%get app "/tags/cobol/")) "an unknown tag")
        (let ((k:*site-options* (k:make-site-options)))
          (is (equal "/tags/c-sharp/" (k:tag-url "C#")))
          (is (equal "/tags/lisp/page/2/" (k:page-url 2 "Lisp")))
          (is (equal "/page/3/" (k:page-url 3))))))))

(test without-per-page-a-listing-is-one-page
  (with-content-dir (dir ("a.md" . (%post "Alpha" nil)) ("b.md" . (%post "Beta" nil)))
    (let ((site (k:make-site dir)))
      (k:boot site)
      (is (= 404 (%get (k:site-app site) "/page/2/"))))))

;;; --- the search index (#353) ---------------------------------------------------------------

(test the-search-index-is-json-of-readable-documents
  (with-content-dir (dir ("posts/a.md" . (%post "Alpha" "2024-01-01" :tags '("Lisp")))
                         ("posts/d.md" . (%post "Draft" nil :draft t)))
    (let ((site (k:make-site dir)))
      (k:boot site)
      (multiple-value-bind (status body headers) (%get (k:site-app site) "/search.json")
        (is (= 200 status))
        (is (search "application/json" (getf headers :content-type)))
        (let ((entries (coerce (com.inuoe.jzon:parse body) 'list)))
          (is (= 1 (length entries)) "the draft is not in it")
          (let ((e (first entries)))
            (is (equal "/posts/a" (gethash "url" e)))
            (is (equal "Alpha" (gethash "title" e)))
            (is (equal '("Lisp") (coerce (gethash "tags" e) 'list)))
            (is (search "Body of Alpha" (gethash "text" e)))))))))

;;; --- the export writes the same pages (#353) ------------------------------------------------

(test the-export-writes-tag-pages-listing-pages-feeds-and-the-index
  (with-content-dir (src ("posts/a.md" . (%post "Alpha" "2024-01-01" :tags '("Lisp")))
                         ("posts/b.md" . (%post "Beta" "2024-02-01" :tags '("Lisp")))
                         ("posts/c.md" . (%post "Gamma" "2024-03-01")))
    (with-export-dir (out)
      (let ((site (k:make-site src)))
        (k:boot site)
        (let ((written (k:export-site site out :per-page 2 :base-url "https://example.org")))
          (is (equal '("404.html" "atom.xml" "feed.xml" "index.html" "page/2/index.html"
                       "posts/a.html" "posts/b.html" "posts/c.html" "search.json"
                       "tags/lisp/index.html")
                     (sort (copy-list written) #'string<))
              "every path the handler answers, at the file a static host serves it from")
          (is (search "https://example.org/posts/c" (%file-text out "feed.xml"))))))))

(test a-scheduled-document-waits-when-no-caller-gives-a-clock
  ;; The handler passes its request's time; this is every other caller, such as a theme or a
  ;; REPL listing a tree with no :now (#359).
  (with-content-dir (dir ("later.md" . +scheduled+) ("now.md" . +good+))
    (let ((tree (k:load-tree dir)))
      (is (equal '("now") (mapcar #'k:document-key (k:tree-readable-documents tree))))
      (is (equal '("later" "now")
                 (mapcar #'k:document-key
                         (k:tree-readable-documents tree :now (encode-universal-time 0 0 0 2 1 2030 0))))
          "the control: at a time after it, it is readable"))))
