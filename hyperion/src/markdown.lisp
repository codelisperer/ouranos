;;;; markdown.lisp --- Markdown -> HTML rendering.
;;;;
;;;; Wraps 3bmd. SAFE by default: raw HTML in the Markdown source is neutralized
;;;; (its `< > &` escaped) before rendering, so user-authored / untrusted content
;;;; can't inject markup or scripts -- one concrete instance of the framework's
;;;; XSS-prevention posture (output is escaped unless explicitly trusted). Pass
;;;; :allow-html t only for content you trust. Fenced code blocks are supported.
;;;;
;;;; NB: 3bmd does not double-escape existing entities, so escaping the source first
;;;; is safe; Markdown syntax (* _ ` # - etc.) uses no HTML-special chars, so
;;;; formatting still works after escaping (only raw HTML / autolinks are disabled).

(in-package #:hyperion/markdown)

(defun escape-html (string)
  "Escape &, <, > in STRING for safe use as HTML text content."
  (with-output-to-string (out)
    (loop for c across string
          do (case c
               (#\& (write-string "&amp;" out))
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (t   (write-char c out))))))

(defun render (markdown &key allow-html)
  "Render MARKDOWN (a string) to an HTML string. SAFE by default: raw HTML in the
source is escaped (suitable for user/untrusted content). ALLOW-HTML t passes raw
HTML through -- trusted content only. Returns \"\" for NIL/empty input."
  (if (and markdown (plusp (length markdown)))
      (let ((3bmd-code-blocks:*code-blocks* t)
            ;; Emit plain <pre><code> (no server-side colorize) -- avoids the
            ;; colorize/HyperSpec console noise; client-side highlighting can be
            ;; layered on later if wanted.
            (3bmd-code-blocks:*code-blocks-default-colorize* nil))
        (with-output-to-string (out)
          (3bmd:parse-string-and-print-to-stream
           (if allow-html markdown (escape-html markdown))
           out)))
      ""))
