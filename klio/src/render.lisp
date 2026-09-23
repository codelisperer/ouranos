;;;; render.lisp --- markdown to HTML.
;;;;
;;;; Part 2 item 4 of #359: this goes through `hyperion/markdown' rather than wrapping 3bmd
;;;; again. That module is already safe by default -- raw HTML in the source is escaped, so
;;;; author content cannot inject markup -- and a second path into the same library would be
;;;; a second escaping policy. The one that is wrong is the one nobody is looking at.
;;;;
;;;; klio content is authored by the site owner in their own git repo, so :allow-html is
;;;; defensible for it. It is not the default here, because "trusted" is a property of a
;;;; particular file rather than of the engine, and an engine that assumes it cannot be
;;;; pointed at anything else later.

(in-package #:klio)

(defun render-markdown (markdown &key allow-html (highlight t))
  "MARKDOWN as HTML.

Delegates to `hyperion/markdown:render'. ALLOW-HTML passes through for content the site owner
has decided is trusted; leave it off for anything else.

HIGHLIGHT applies klio's own Lisp highlighter to fenced Lisp blocks (#359 Q3). Two bindings
make that possible and both are deliberate:

  3BMD-CODE-BLOCKS::*RENDERER* :NOHIGHLIGHT -- so a fenced block arrives as
  `<pre class=\"LANG\"><code>escaped</code></pre>': plain, and RECORDING THE LANGUAGE, which is
  the one thing the post-pass needs. The default renderer is `colorize', which already colours
  a ```lisp fence server-side -- so `hyperion/markdown''s comment about emitting plain
  <pre><code> holds only for an UNLABELLED fence -- and prints a `could not find hyperspec
  map file' line to standard output while doing it.

  An INTERNAL symbol, named as such. The exported knobs (*CODE-BLOCKS-DEFAULT-COLORIZE*,
  *COLORIZE-NAME-MAP*, *CODE-BLOCKS-COLORING-TYPE-REMAP*) can all suppress the colouring, and
  every one of them does it by making the language unrecognisable -- which also erases the
  language from the output, leaving nothing to decide on afterwards. The shape this depends on
  is asserted in klio's suite, so a library upgrade that changes it fails there rather than
  quietly serving unhighlighted pages, which look exactly like pages with no Lisp on them."
  (let* ((3bmd-code-blocks::*renderer* (if highlight :nohighlight 3bmd-code-blocks::*renderer*))
         (html (hyperion/markdown:render markdown :allow-html allow-html)))
    (if highlight (highlight-code-blocks html) html)))
