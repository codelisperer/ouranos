;;;; page-meta.lisp --- Open Graph, Twitter-card and canonical tags for a page (#821).
;;;;
;;;; A link shared in a chat or a social network shows a preview card only when the
;;;; page's <head> carries og:* and twitter:* tags with absolute URLs. This module turns
;;;; a declaration of the page (title, description, image, canonical URL, type, locale,
;;;; and for an article its times and authors) into those tags.
;;;;
;;;;   - PAGE-META is pure: it returns the tags as a list of (KIND NAME VALUE) entries.
;;;;   - META-TAGS writes them with Spinneret, inside a layout's (:head ...).
;;;;   - A SITE holds what every page shares: the site's name, its public origin, and a
;;;;     fallback image. URLs are built from the origin the app configured, never from
;;;;     the request's Host header, which a client chooses.
;;;;   - A page whose visibility is :PRIVATE (it needs sign-in) or :NOINDEX gets
;;;;     robots noindex plus the site's name and fallback image, and nothing about the
;;;;     page itself. An :UNLISTED page gets the full card plus robots noindex (#947).

(in-package #:hyperion/page-meta)

(define-condition page-meta-error (simple-error) ()
  (:documentation "A page or site declaration that cannot produce correct tags: a URL
that is not https, an origin with a path, an unknown page type or visibility, an image
size that is not a positive integer, or no site to build URLs from."))

(defun %fail (control &rest args)
  (error 'page-meta-error :format-control control :format-arguments args))

;;; --- URLs ------------------------------------------------------------------

(defun %https-url-p (uri)
  (and (equal "https" (quri:uri-scheme uri))
       (plusp (length (or (quri:uri-host uri) "")))))

(defun %parse-origin (origin)
  "ORIGIN (\"https://example.com\") checked and normalised: lowercase scheme and host,
default port and trailing slash dropped. Signals PAGE-META-ERROR for anything else."
  (let ((uri (and (stringp origin) (ignore-errors (quri:uri origin)))))
    (unless (and uri (%https-url-p uri)
                 (member (quri:uri-path uri) '(nil "" "/") :test #'equal)
                 (null (quri:uri-query uri))
                 (null (quri:uri-fragment uri))
                 (null (quri:uri-userinfo uri)))
      (%fail "The site's public origin must be an https origin with no path, query or fragment, such as \"https://example.com\"; got ~S. Set it with MAKE-SITE's :ORIGIN or HYPERION_PUBLIC_ORIGIN."
             origin))
    (let ((port (quri:uri-port uri)))
      (format nil "https://~A~@[:~D~]"
              (string-downcase (quri:uri-host uri))
              (and port (/= port 443) port)))))

(defun absolute-url (url origin)
  "URL as an absolute https URL. A path starting with a single / is joined to ORIGIN, the
site's public origin; an absolute https URL is returned unchanged. Anything else -- http,
another scheme, a relative path, a protocol-relative //host -- signals PAGE-META-ERROR,
because a crawler cannot fetch it as the page meant."
  (cond ((not (stringp url))
         (%fail "A page-meta URL must be a string; got ~S." url))
        ((and (plusp (length url)) (char= #\/ (char url 0))
              (not (and (> (length url) 1) (char= #\/ (char url 1)))))
         (concatenate 'string origin url))
        (t
         (let ((uri (ignore-errors (quri:uri url))))
           (unless (and uri (%https-url-p uri))
             (%fail "A page-meta URL must be an https URL or a path starting with /; got ~S." url))
           url))))

(defun %canonical-url (url origin keep-query)
  "URL, a path or an https URL on ORIGIN, as the page's absolute canonical URL. The query
and fragment are dropped unless KEEP-QUERY, in which case only the fragment is, because a
query often carries a token (a reset link, a session) that must not be published to
crawlers. A URL on any other origin, or with userinfo, signals PAGE-META-ERROR: the
canonical URL says which page this is, and a page cannot claim to be another site's."
  (let* ((absolute (absolute-url url origin))
         (uri (quri:uri absolute))
         (port (quri:uri-port uri))
         (own (format nil "https://~A~@[:~D~]" (string-downcase (quri:uri-host uri))
                      (and port (/= port 443) port))))
    (unless (and (string= own origin) (null (quri:uri-userinfo uri)))
      (%fail "A page's canonical URL must be on the site's own origin ~A; got ~S." origin url))
    (format nil "~A~A~@[?~A~]" origin (or (quri:uri-path uri) "/")
            (and keep-query (quri:uri-query uri)))))

(defparameter +expiring-url-parameters+
  '("x-amz-signature" "x-amz-expires" "x-amz-credential"
    "x-goog-signature" "x-goog-expires" "x-goog-credential"
    "expires" "signature" "policy" "key-pair-id"
    "sig" "se")
  "Query parameters, compared without case, that mark a URL as signed with an expiry: S3
and compatible stores (X-Amz-*), Google Cloud Storage (X-Goog-*), CloudFront (Expires,
Signature, Policy, Key-Pair-Id) and Azure shared access signatures (sig, se).")

(defun %query-keys (query)
  "The parameter names in QUERY, split by hand so that a malformed escape elsewhere in the
query cannot hide them. A name that does not decode is kept as written."
  (loop for pair in (uiop:split-string query :separator "&;")
        for name = (subseq pair 0 (or (position #\= pair) (length pair)))
        unless (string= name "")
          collect (string-downcase (or (ignore-errors (quri:url-decode name)) name))))

(defun expiring-url-p (url)
  "True when URL carries a query parameter that marks it as a presigned URL with an
expiry, and also when URL cannot be parsed, so that a doubt counts as expiring. A crawler
caches a card for days or weeks, so an image behind such a URL breaks once it expires;
serve the image from a stable public URL instead."
  (let ((uri (ignore-errors (quri:uri url))))
    (cond ((null uri) t)
          ((null (quri:uri-query uri)) nil)
          (t (and (some (lambda (name) (member name +expiring-url-parameters+ :test #'string=))
                        (%query-keys (quri:uri-query uri)))
                  t)))))

;;; --- the site ----------------------------------------------------------------

(defstruct (site (:constructor %make-site))
  (name nil :read-only t)
  (origin nil :read-only t)
  (image nil :read-only t)
  (image-width nil :read-only t)
  (image-height nil :read-only t)
  (image-alt nil :read-only t)
  (twitter nil :read-only t))

(defvar *site* nil
  "The site the current app's pages belong to, made with MAKE-SITE. PAGE-META and
META-TAGS use it when no :SITE is passed. Set it once at startup.")

(defun %check-size (what value)
  (unless (or (null value) (and (integerp value) (plusp value)))
    (%fail "~A must be a positive integer; got ~S." what value))
  value)

(defun make-site (&key name (origin (uiop:getenv "HYPERION_PUBLIC_ORIGIN"))
                    image image-width image-height image-alt twitter)
  "The site every page shares.

  NAME     the site's name, emitted as og:site_name.
  ORIGIN   the public https origin URLs are built from, such as \"https://example.com\".
           Defaults to the environment variable HYPERION_PUBLIC_ORIGIN.
  IMAGE    the fallback image for a page that has none, as a path or an https URL,
           with IMAGE-WIDTH, IMAGE-HEIGHT (pixels) and IMAGE-ALT.
  TWITTER  the site's account, such as \"@example\", emitted as twitter:site.

Signals PAGE-META-ERROR when ORIGIN is missing or is not a bare https origin, or when the
fallback image cannot be made absolute."
  (let ((origin (%parse-origin origin)))
    (when image (absolute-url image origin))
    (when (and twitter (not (and (stringp twitter) (> (length twitter) 1)
                                 (char= #\@ (char twitter 0)))))
      (%fail "The site's twitter account must start with @; got ~S." twitter))
    (%make-site :name name :origin origin :image image
                :image-width (%check-size "The site image's width" image-width)
                :image-height (%check-size "The site image's height" image-height)
                :image-alt image-alt :twitter twitter)))

;;; --- text --------------------------------------------------------------------

(defun %space-p (c)
  "True for ASCII and Unicode whitespace: no-break space, the U+2000 spaces, the line and
paragraph separators, the ideographic space and the rest of Unicode's White_Space set."
  (let ((code (char-code c)))
    (or (<= 9 code 13) (= code 32) (= code #x85) (= code #xA0) (= code #x1680)
        (<= #x2000 code #x200A) (= code #x2028) (= code #x2029) (= code #x202F)
        (= code #x205F) (= code #x3000))))

(defun %collapse-whitespace (text)
  (with-output-to-string (out)
    (let ((pending nil) (started nil))
      (loop for c across text
            do (if (%space-p c)
                   (setf pending started)
                   (progn (when pending (write-char #\Space out))
                          (write-char c out)
                          (setf pending nil started t)))))))

(defun trim-description (text &optional (limit 200))
  "TEXT with runs of whitespace (Unicode's included) made single spaces, cut to at most
LIMIT characters. A cut falls on a word boundary when there is one in the second half of
the limit, and ends with an ellipsis (counted in LIMIT).

TEXT is plain text. Markup is not removed: a tag or an entity is written into the
attribute as characters (escaped) and counts toward LIMIT, so pass the page's summary as
text, not its HTML."
  (let ((text (%collapse-whitespace text)))
    (if (<= (length text) limit)
        text
        (let* ((room (1- limit))
               (space (position #\Space text :end (1+ room) :from-end t))
               (cut (if (and space (>= space (floor limit 2))) space room)))
          (concatenate 'string
                       (string-right-trim '(#\Space #\, #\; #\: #\- #\.) (subseq text 0 cut))
                       (string #\HORIZONTAL_ELLIPSIS))))))

(defun %alpha-p (s) (every #'alpha-char-p s))

(defun og-locale (locale)
  "LOCALE, as hyperion/i18n names it (:en-gb, \"pt-BR\", :fr), in the form Open Graph
uses: \"en_GB\", \"pt_BR\", \"fr\". A script subtag is dropped (zh-Hant-TW -> zh_TW). NIL
when LOCALE is not a language tag."
  (when locale
    (let* ((tag (i18n:lang-attributes locale))
           (parts (uiop:split-string (substitute #\- #\_ tag) :separator "-"))
           (language (first parts))
           (region (find-if (lambda (p)
                              (or (and (= 2 (length p)) (%alpha-p p))
                                  (and (= 3 (length p)) (every #'digit-char-p p))))
                            (rest parts))))
      (when (and language (<= 2 (length language) 3) (%alpha-p language))
        (format nil "~A~@[_~A~]" language (and region (string-upcase region)))))))

(defun %iso-8601-p (s)
  "True when S is an ISO 8601 date, or date and time with an optional fraction and an
optional zone: 2026-01-02, 2026-01-02T03:04, 2026-01-02T03:04:05.123Z,
2026-01-02T03:04:05+01:00."
  (flet ((digits (start end)
           (and (<= end (length s)) (every #'digit-char-p (subseq s start end))))
         (at (i c) (and (< i (length s)) (char= c (char s i)))))
    (and (digits 0 4) (at 4 #\-) (digits 5 7) (at 7 #\-) (digits 8 10)
         (or (= (length s) 10)
             (and (at 10 #\T) (digits 11 13) (at 13 #\:) (digits 14 16)
                  (let ((i 16))
                    (when (at i #\:)
                      (unless (digits 17 19) (return-from %iso-8601-p nil))
                      (setf i 19)
                      (when (at i #\.)
                        (let ((end (or (position-if-not #'digit-char-p s :start (1+ i))
                                       (length s))))
                          (when (= end (1+ i)) (return-from %iso-8601-p nil))
                          (setf i end))))
                    (or (= i (length s))
                        (and (at i #\Z) (= (1+ i) (length s)))
                        (and (or (at i #\+) (at i #\-)) (= (+ i 6) (length s))
                             (digits (+ i 1) (+ i 3)) (at (+ i 3) #\:)
                             (digits (+ i 4) (+ i 6)))))))
         t)))

(defun %iso-time (time)
  "TIME, a universal time or an ISO 8601 string, as an ISO 8601 string. A universal time is
written in UTC. Signals PAGE-META-ERROR for anything else."
  (typecase time
    (string (if (%iso-8601-p time)
                time
                (%fail "An article time must be a universal time or an ISO 8601 string; got ~S." time)))
    (integer
     (multiple-value-bind (s mi h d mo y) (decode-universal-time time 0)
       (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h mi s)))
    (t (%fail "An article time must be a universal time or an ISO 8601 string; got ~S." time))))

;;; --- the page ----------------------------------------------------------------

(defun %image-entries (url width height alt)
  (append (list (list :property "og:image" url))
          (when width (list (list :property "og:image:width" (princ-to-string width))))
          (when height (list (list :property "og:image:height" (princ-to-string height))))
          (when alt (list (list :property "og:image:alt" alt)))))

(defun %choose-image (image width height alt site)
  "The image to show, as (VALUES URL WIDTH HEIGHT ALT): the page's own, unless it has none
or it expires, else the site's fallback."
  (let ((origin (site-origin site)))
    (cond ((and image (expiring-url-p image))
           (log:warn "page-meta: the page's image URL expires, so the site's fallback is used"
                     :host (ignore-errors (quri:uri-host (quri:uri image))))
           (%choose-image nil nil nil nil site))
          (image
           (values (absolute-url image origin)
                   (%check-size "The page image's width" width)
                   (%check-size "The page image's height" height)
                   alt))
          ((site-image site)
           (values (absolute-url (site-image site) origin)
                   (site-image-width site) (site-image-height site) (site-image-alt site)))
          (t (values nil nil nil nil)))))

(defun page-meta (&key (site *site*) title description image image-alt image-width
                    image-height url keep-query (type :website) site-name locale
                    alternate-locales published-time modified-time author section visibility)
  "The link-preview tags for one page, as a list of (KIND NAME VALUE): KIND :PROPERTY is
<meta property=NAME content=VALUE>, :NAME is <meta name=NAME content=VALUE>, and :LINK is
<link rel=NAME href=VALUE>. Pass the result to META-TAGS, or call META-TAGS with the same
arguments.

  TITLE, DESCRIPTION   og:title, og:description, twitter:*, and <meta name=description>.
                       The description has its whitespace collapsed and is cut to 200
                       characters on a word boundary.
  IMAGE                a path or https URL, with IMAGE-ALT, IMAGE-WIDTH, IMAGE-HEIGHT.
                       Without one, or when it is a presigned URL that expires (see
                       EXPIRING-URL-P), the site's fallback image is used. With an image
                       the card is summary_large_image, else summary.
  URL                  the canonical URL: og:url and <link rel=canonical>. A path, or an
                       https URL on the site's own origin. Its query and fragment are
                       dropped, because a query often carries a token; KEEP-QUERY true
                       keeps the query. Omitted when NIL; it is never taken from the
                       request.
  TYPE                 :WEBSITE or :ARTICLE.
  SITE-NAME            overrides the site's name.
  LOCALE               the page's locale as hyperion/i18n names it (what
                       I18N:RESOLVE-LOCALE returns), as og:locale; ALTERNATE-LOCALES, the
                       other locales the page is offered in, as og:locale:alternate.
  PUBLISHED-TIME, MODIFIED-TIME, AUTHOR, SECTION
                       for an :ARTICLE only. A time is a universal time or an ISO 8601
                       string; AUTHOR is a string or a list of them.
  VISIBILITY           required: :PUBLIC, :UNLISTED, :NOINDEX or :PRIVATE.
                       :PUBLIC emits the full card. :UNLISTED emits the same full card
                       plus robots noindex, for a page anyone with the link may see and
                       share but that should not be listed in search results.
                       :NOINDEX (public but kept out of search engines) and :PRIVATE
                       (needs sign-in) emit robots noindex, the SITE's name as
                       og:site_name and og:title, the fallback image, and nothing from
                       the page's own declaration, SITE-NAME included. Robots noindex is
                       a request that crawlers may ignore, and they still fetch the card
                       of an :UNLISTED page, so content that must not be seen uses
                       :PRIVATE. There is no default, so a layout that forgets to say a
                       page is private gets an error, not a card.

URLs are made absolute from SITE's origin. Signals PAGE-META-ERROR when SITE is NIL or a
value cannot produce a correct tag."
  (unless (site-p site)
    (%fail "No site to build page-meta URLs from. Set hyperion/page-meta:*site* with MAKE-SITE, or pass :SITE."))
  (unless (member type '(:website :article))
    (%fail "A page's type must be :WEBSITE or :ARTICLE; got ~S." type))
  (unless (member visibility '(:public :unlisted :noindex :private))
    (%fail "A page's :VISIBILITY must be given, as :PUBLIC, :UNLISTED, :NOINDEX or :PRIVATE; got ~S." visibility))
  (let ((twitter (site-twitter site)))
    (if (member visibility '(:public :unlisted))
        (multiple-value-bind (image-url width height alt)
            (%choose-image image image-width image-height image-alt site)
          (let* ((site-name (or site-name (site-name site)))
                 (description (and description (trim-description description)))
                 (canonical (and url (%canonical-url url (site-origin site) keep-query)))
                 (og-locale (og-locale locale))
                 (entries
                   (append
                    (when description (list (list :name "description" description)))
                    (when canonical (list (list :link "canonical" canonical)))
                    (list (list :property "og:type" (string-downcase type)))
                    (when site-name (list (list :property "og:site_name" site-name)))
                    (when title (list (list :property "og:title" title)))
                    (when description (list (list :property "og:description" description)))
                    (when canonical (list (list :property "og:url" canonical)))
                    (when og-locale (list (list :property "og:locale" og-locale)))
                    (loop for l in alternate-locales
                          for o = (og-locale l)
                          when (and o (not (equal o og-locale)))
                            collect (list :property "og:locale:alternate" o))
                    (when image-url (%image-entries image-url width height alt))
                    (when (eq type :article)
                      (append
                       (when published-time
                         (list (list :property "article:published_time" (%iso-time published-time))))
                       (when modified-time
                         (list (list :property "article:modified_time" (%iso-time modified-time))))
                       (loop for a in (if (listp author) author (list author))
                             collect (list :property "article:author" a))
                       (when section (list (list :property "article:section" section)))))
                    (list (list :name "twitter:card"
                                (if image-url "summary_large_image" "summary")))
                    (when twitter (list (list :name "twitter:site" twitter)))
                    (when title (list (list :name "twitter:title" title)))
                    (when description (list (list :name "twitter:description" description)))
                    (when image-url (list (list :name "twitter:image" image-url)))
                    (when (and image-url alt) (list (list :name "twitter:image:alt" alt))))))
            (if (eq visibility :unlisted)
                (cons (list :name "robots" "noindex") entries)
                entries)))
        ;; :NOINDEX or :PRIVATE: nothing from the page's own declaration, not even its
        ;; SITE-NAME, which a page can set to something that names its content.
        (multiple-value-bind (image-url width height alt)
            (%choose-image nil nil nil nil site)
          (let ((site-name (site-name site)))
            (append
             (list (list :name "robots" "noindex"))
             (when site-name
               (list (list :property "og:site_name" site-name)
                     (list :property "og:title" site-name)))
             (when image-url (%image-entries image-url width height alt))
             (list (list :name "twitter:card" (if image-url "summary_large_image" "summary")))
             (when twitter (list (list :name "twitter:site" twitter)))
             (when image-url (list (list :name "twitter:image" image-url)))))))))

(defun %write-tags (entries)
  (dolist (entry entries)
    (destructuring-bind (kind name value) entry
      (ecase kind
        (:property (spin:with-html (:meta :property name :content value)))
        (:name (spin:with-html (:meta :name name :content value)))
        (:link (spin:with-html (:link :rel name :href value)))))))

(defun meta-tags (&rest args)
  "Write the tags PAGE-META returns for ARGS into the Spinneret output, from inside a
layout's head:

  (spin:with-html-string
    (:html (:head (:title title) (meta-tags :title title :url \"/posts/1\" :type :article))
     ...))

Attribute values are escaped by Spinneret."
  (%write-tags (apply #'page-meta args))
  nil)

(defun meta-tags-string (&rest args)
  "The tags META-TAGS writes, as a string, for a layout that does not use Spinneret."
  (spin:with-html-string (apply #'meta-tags args)))
