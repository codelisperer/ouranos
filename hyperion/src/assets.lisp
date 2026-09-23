;;;; assets.lisp --- vendored browser assets, embedded in the image.
;;;;
;;;; htmx, Alpine.js and Bulma, compiled INTO the fasl as literal octet vectors and
;;;; served from memory. The bytes, their versions and their checksums are pinned in
;;;; `assets/vendor/ASSETS.pin`; `scripts/check-assets.lisp` proves the files on disk
;;;; still match, and that the fingerprints below still match the files.
;;;;
;;;; WHY EMBEDDED RATHER THAN READ FROM DISK. ADR-0013 established that
;;;; `asdf:system-source-directory` resolves to the BUILD machine's path inside a dumped
;;;; image -- which is why a native library has to be copied next to the binary. An asset
;;;; read from `assets/vendor/` at run time would hit exactly that, and the desktop
;;;; bundle is the very thing this fixes (#123). A `.so` cannot be embedded; 770K of text
;;;; can, so it is. There is no path to get wrong, no file to forget to copy into the
;;;; `.app`, and no ordering dependency on the installer.
;;;;
;;;; WHY NOT A CDN, which is what every example did before. It contradicts the thesis --
;;;; "no Node, no bundler, no asset pipeline" is hard to credit while the flagship demo
;;;; fetches its JavaScript from npm -- but the deciding reason is plainer: an installed
;;;; desktop application that renders nothing without internet is broken.
;;;;
;;;; This system is OPT-IN (`hyperion/assets`) rather than part of `hyperion`, because
;;;; ~770K in every image is not a cost to impose on an app that ships its own CSS.
;;;;
;;;; URLs are content-addressed -- `/_hyperion/assets/htmx-449317ad.min.js` -- so they can
;;;; be served `immutable` for a year. The fingerprint is the head of the sha256 in the
;;;; pin file, so the URL changes exactly when the bytes do.

(cl:defpackage #:hyperion/assets
  (:use #:cl)
  (:local-nicknames (#:static #:hyperion/static)
                    (#:router #:hyperion/router))
  (:documentation
   "Vendored browser assets (htmx, Alpine.js, Bulma) embedded in the image and served
    from memory under a mountable router, plus Bulma theming as CSS custom properties.
    Nothing here touches the network or the filesystem at run time.")
  (:export #:asset #:assets #:asset-key #:asset-version #:asset-filename
           #:asset-fingerprint #:asset-bytes #:asset-content-type
           #:*prefix* #:url #:handler #:mount #:routes #:serve
           #:theme #:hsl #:*default-theme*))

(in-package #:hyperion/assets)

;;; --- embedding ---------------------------------------------------------------

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %slurp (relative)
    "RELATIVE's bytes, read at COMPILE time from the source tree."
    (with-open-file (in (asdf:system-relative-pathname "hyperion" relative)
                        :element-type '(unsigned-byte 8))
      (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
        (read-sequence v in)
        v))))

(defmacro %embed (relative)
  "Expand to RELATIVE's contents as a literal octet vector. The bytes land in the fasl,
so the loaded image carries them and never consults the source tree again."
  (%slurp relative))

(defstruct (asset (:constructor %asset) (:copier nil))
  "One vendored file: its identity, its pinned version, and its bytes."
  (key nil :type keyword :read-only t)
  (version "" :type string :read-only t)
  (filename "" :type string :read-only t)
  ;; Head of the sha256 in ASSETS.pin. Content-addresses the URL; verified against the
  ;; file by scripts/check-assets.lisp, so a stale fingerprint is a build failure rather
  ;; than a silently wrong cache key.
  (fingerprint "" :type string :read-only t)
  (bytes #() :type (simple-array (unsigned-byte 8) (*)) :read-only t))

(defun asset-content-type (asset)
  "Content-Type for ASSET, from its extension."
  (static:content-type-for (asset-filename asset)))

(defparameter *assets*
  (list (%asset :key :htmx :version "1.9.12" :filename "htmx.min.js"
                :fingerprint "449317ad"
                :bytes (%embed "assets/vendor/htmx.min.js"))
        (%asset :key :alpine :version "3.14.1" :filename "alpine.min.js"
                :fingerprint "358d9afb"
                :bytes (%embed "assets/vendor/alpine.min.js"))
        (%asset :key :bulma :version "1.0.4" :filename "bulma.min.css"
                :fingerprint "67fa26df"
                :bytes (%embed "assets/vendor/bulma.min.css")))
  "Every vendored asset. See assets/vendor/ASSETS.pin for provenance and licences.")

(defun assets ()
  "The vendored assets, as a list."
  (copy-list *assets*))

(defun asset (key)
  "The asset named KEY (:htmx :alpine :bulma), or NIL."
  (find key *assets* :key #'asset-key))

(defun %require (key)
  (or (asset key)
      (error "No vendored asset ~S. Known: ~{~S~^ ~}."
             key (mapcar #'asset-key *assets*))))

;;; --- serving -----------------------------------------------------------------

(defparameter *prefix* "/_hyperion/assets"
  "URL prefix the assets are served under. Underscored to stay out of an app's namespace.
Bind it before calling URL and MOUNT -- both read it, so they cannot disagree.")

(defun %url-name (asset)
  "FILENAME with the fingerprint spliced before the extension: htmx-449317ad.min.js."
  (let* ((name (asset-filename asset))
         (dot (position #\. name)))
    (format nil "~a-~a~a"
            (subseq name 0 dot) (asset-fingerprint asset) (subseq name dot))))

(defun url (key)
  "The content-addressed URL for asset KEY. Changes when, and only when, the bytes do."
  (format nil "~a/~a" *prefix* (%url-name (%require key))))

(defun %respond (asset)
  ;; The body is the octet vector ITSELF, not a list containing it (#148). A Clack body
  ;; is a list of STRINGS, a pathname, a stream, or a byte vector -- and the list form
  ;; is the one that reads most naturally here, which is exactly why this was wrong:
  ;; `(list bytes)` is a list whose single element is a vector, so the handler writes
  ;; nothing while :content-length still promises the bytes. The client then waits for a
  ;; body that is never coming -- Hunchentoot closes short (curl: "transfer closed with
  ;; outstanding read data"), Woo hangs. htmx and Bulma both silently failed to load.
  ;;
  ;; Measured on both backends before choosing (payload "hé" = 68 c3 a9):
  ;;   (list bytes)                     -> empty, both
  ;;   bytes                            -> 68 c3 a9, both      <- this
  ;;   (list (map 'string #'code-char)) -> 68 c3 83 c2 a9      <- latin-1 then UTF-8: corrupt
  ;;   (list (octets-to-string :utf-8)) -> 68 c3 a9, but only for valid UTF-8
  ;; The vector stays binary-exact and assumes no encoding, so a future binary asset
  ;; (a font, an icon) needs no special case.
  (list 200
        (list :content-type (asset-content-type asset)
              :content-length (length (asset-bytes asset))
              :cache-control static:*immutable-cache-control*)
        (asset-bytes asset)))

(defun handler (asset)
  "A Clack handler serving ASSET. Immutable caching is safe: the URL is its checksum."
  (lambda (env)
    (declare (ignore env))
    (%respond asset)))

(defun routes ()
  "A router serving every vendored asset at its content-addressed name, relative to the
mount point. Combine with MOUNT rather than using directly."
  (apply #'router:router
         (mapcar (lambda (a)
                   (router:route :get (format nil "/~a" (%url-name a))
                                 (handler a)
                                 :name (asset-key a)))
                 *assets*)))

(defun mount ()
  "A router MOUNT contributing the vendored assets under *PREFIX*. Drop it into an app's
route table and every URL returned by URL resolves:

    (router:router (router:route :get \"/\" #'home)
                   (assets:mount))"
  (router:mount *prefix* (routes)))

(defun serve (env)
  "Serve the vendored asset ENV asks for, or NIL if it is asking for something else.

The NIL-means-not-mine convention is `hyperion/static:file-response`'s, so this drops
into a hand-rolled dispatch the same way -- as one clause that falls through:

    (cond ((assets:serve env))
          ((and (eq method :get) (string= path \"/\")) ...)
          (t (list 404 ...)))

Use MOUNT instead when the app already has a router; this exists so an app does not
need one just to serve htmx."
  (let ((path (getf env :path-info))
        (prefix *prefix*))
    (when (and (stringp path)
               (eq :get (getf env :request-method))
               (> (length path) (length prefix))
               (string= prefix path :end2 (length prefix))
               (eql #\/ (char path (length prefix))))
      (let ((name (subseq path (1+ (length prefix)))))
        (let ((hit (find name *assets* :key #'%url-name :test #'string=)))
          (when hit (%respond hit)))))))

;;; --- Bulma theming ------------------------------------------------------------
;;;
;;; Bulma 1.x is themed with CSS CUSTOM PROPERTIES, and that is the whole reason we are
;;; on 1.x rather than the 0.9.4 the examples used. 0.9.4's palette is baked into its
;;; compiled CSS: recolouring it means editing Sass variables and running dart-sass,
;;; i.e. Node, i.e. the asset pipeline this stack exists to avoid. 1.x derives every
;;; colour from `--bulma-<name>-h/-s/-l`, so a theme is a handful of declarations on
;;; `:root` -- plain text we can generate from Lisp, with no build step at all.
;;;
;;; Dark mode comes free and is not our code: Bulma 1.x ships both a
;;; `prefers-color-scheme: dark` block and a `[data-theme=dark]` selector, so a theme
;;; set in hue/saturation/lightness terms follows the OS automatically, and
;;; `<html data-theme="dark">` forces it.

(defun hsl (hex)
  "HEX (\"#7048e8\" or \"7048e8\") as (VALUES HUE-DEGREES SATURATION-% LIGHTNESS-%),
which is the form Bulma 1.x wants. Signals on anything that is not six hex digits."
  (let ((s (string-left-trim "#" hex)))
    (unless (and (= 6 (length s)) (every (lambda (c) (digit-char-p c 16)) s))
      (error "~S is not a six-digit hex colour." hex))
    (flet ((chan (i) (/ (parse-integer s :start i :end (+ i 2) :radix 16) 255.0d0)))
      (let* ((r (chan 0)) (g (chan 2)) (b (chan 4))
             (hi (max r g b)) (lo (min r g b))
             (delta (- hi lo))
             (l (/ (+ hi lo) 2))
             (sat (if (zerop delta)
                      0.0d0
                      (/ delta (- 1 (abs (- (* 2 l) 1))))))
             (hue (cond ((zerop delta) 0.0d0)
                        ((= hi r) (* 60 (mod (/ (- g b) delta) 6)))
                        ((= hi g) (* 60 (+ 2 (/ (- b r) delta))))
                        (t        (* 60 (+ 4 (/ (- r g) delta)))))))
        (values hue (* 100 sat) (* 100 l))))))

(defparameter *default-theme*
  '(:primary "#00d1b2" :link "#485fc7")
  "Bulma's own primary/link, as a starting point a generated project can edit.")

(defun %colour-vars (name hex)
  (multiple-value-bind (h s l) (hsl hex)
    (format nil "  --bulma-~(~a~)-h: ~,1Fdeg;~%  --bulma-~(~a~)-s: ~,1F%;~%  --bulma-~(~a~)-l: ~,1F%;~%"
            name h name s name l)))

(defun theme (&rest plist &key &allow-other-keys)
  "A `<style>`-ready CSS string setting Bulma custom properties on `:root`.

Keys naming a Bulma colour (:primary :link :info :success :warning :danger, and the
scheme base :scheme) take a hex string and are expanded to the -h/-s/-l triple Bulma
derives its shades from. Any other key is emitted verbatim as `--bulma-<key>: <value>`,
which covers the non-colour knobs:

    (theme :primary \"#7048e8\" :link \"#1d72aa\"
           :family-primary \"Inter, system-ui, sans-serif\"
           :radius-large \"8px\")

Returns CSS only -- no tag -- so a caller can inline it in a <style> element, serve it
as a file, or write it to disk at scaffold time. Dark mode needs nothing extra: Bulma
1.x resolves these same properties under `prefers-color-scheme` and `[data-theme]`."
  (let ((colours '(:primary :link :info :success :warning :danger :scheme)))
    (with-output-to-string (out)
      (write-line ":root {" out)
      (loop for (key value) on plist by #'cddr
            do (write-string
                (if (member key colours)
                    (%colour-vars key value)
                    (format nil "  --bulma-~(~a~): ~a;~%" key value))
                out))
      (write-line "}" out))))
