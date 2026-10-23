;;;; page-meta-tests.lisp --- Open Graph, Twitter-card and canonical tags (#821).

(in-package #:hyperion/tests)

(def-suite page-meta :in hyperion)
(in-suite page-meta)

(defun %meta-site (&rest args)
  (apply #'meta:make-site :name "Example News" :origin "https://Example.com/"
         :image "/static/card.png" :image-width 1200 :image-height 630
         :image-alt "The Example News logo" :twitter "@examplenews" args))

(defun %pm (&rest args)
  "PAGE-META for a public page unless ARGS say otherwise: the first :VISIBILITY wins."
  (apply #'meta:page-meta (append args (list :visibility :public))))

(defun %tag (entries kind name)
  "The values of the entries in ENTRIES with KIND and NAME."
  (loop for (k n v) in entries
        when (and (eq k kind) (string= n name)) collect v))

(defun %head (&rest args)
  "A whole page rendered with META-TAGS in its head, as a layout would."
  (spin:with-html-string
    (:html (:head (:title "A page")
                  (apply #'meta:meta-tags (append args (list :visibility :public))))
           (:body (:p "body")))))

(test an-article-gets-every-card-tag-with-absolute-urls
  (let* ((site (%meta-site))
         (entries (%pm :site site :type :article :title "Rates rise"
                                  :description "The bank raised its rate today."
                                  :url "/news/rates" :image "/img/rates.jpg"
                                  :image-width 1600 :image-height 900 :image-alt "A chart"
                                  :locale :en-gb :alternate-locales '(:en-gb :es)
                                  :published-time (encode-universal-time 5 4 3 2 1 2026 0)
                                  :author '("A. Writer" "B. Editor") :section "Economy")))
    (is (equal '("article") (%tag entries :property "og:type")))
    (is (equal '("Example News") (%tag entries :property "og:site_name")))
    (is (equal '("Rates rise") (%tag entries :property "og:title")))
    (is (equal '("https://example.com/news/rates") (%tag entries :property "og:url")))
    (is (equal '("https://example.com/news/rates") (%tag entries :link "canonical")))
    (is (equal '("https://example.com/img/rates.jpg") (%tag entries :property "og:image")))
    (is (equal '("1600") (%tag entries :property "og:image:width")))
    (is (equal '("900") (%tag entries :property "og:image:height")))
    (is (equal '("A chart") (%tag entries :property "og:image:alt")))
    (is (equal '("en_GB") (%tag entries :property "og:locale")))
    (is (equal '("es") (%tag entries :property "og:locale:alternate")))
    (is (equal '("2026-01-02T03:04:05Z") (%tag entries :property "article:published_time")))
    (is (equal '("A. Writer" "B. Editor") (%tag entries :property "article:author")))
    (is (equal '("Economy") (%tag entries :property "article:section")))
    (is (equal '("summary_large_image") (%tag entries :name "twitter:card")))
    (is (equal '("@examplenews") (%tag entries :name "twitter:site")))
    (is (equal '("https://example.com/img/rates.jpg") (%tag entries :name "twitter:image")))
    (is (equal '("The bank raised its rate today.") (%tag entries :name "description"))))
  ;; and the rendered head carries them
  (let ((html (%head :site (%meta-site) :type :article :title "Rates rise" :url "/news/rates")))
    (is (search "og:title" html))
    (is (%attr-p html "content" "https://example.com/news/rates"))
    (is (%attr-p html "rel" "canonical"))
    (is (%attr-p html "href" "https://example.com/news/rates"))))

(test a-page-with-no-image-uses-the-site-fallback-or-a-summary-card
  (let ((entries (%pm :site (%meta-site) :title "About")))
    (is (equal '("website") (%tag entries :property "og:type")))
    (is (equal '("https://example.com/static/card.png") (%tag entries :property "og:image")))
    (is (equal '("1200") (%tag entries :property "og:image:width")))
    (is (equal '("The Example News logo") (%tag entries :property "og:image:alt")))
    (is (equal '("summary_large_image") (%tag entries :name "twitter:card")))
    (is (null (%tag entries :property "article:published_time")))
    (is (null (%tag entries :link "canonical")) "No canonical URL is invented from the request."))
  ;; a site with no fallback image: no og:image and a summary card
  (let ((entries (%pm :site (meta:make-site :name "Bare" :origin "https://bare.example")
                                 :title "About")))
    (is (null (%tag entries :property "og:image")))
    (is (null (%tag entries :name "twitter:image")))
    (is (equal '("summary") (%tag entries :name "twitter:card")))))

(test a-private-or-noindex-page-emits-only-the-site-name-and-fallback
  (dolist (visibility '(:private :noindex))
    (let* ((entries (%pm :site (%meta-site) :visibility visibility
                                    :title "Ledger for account 4411"
                                    :description "Balance and recent payments"
                                    :url "/accounts/4411" :image "/accounts/4411/chart.png"))
           (html (%head :site (%meta-site) :visibility visibility
                        :title "Ledger for account 4411"
                        :description "Balance and recent payments"
                        :url "/accounts/4411" :image "/accounts/4411/chart.png")))
      (is (equal '("noindex") (%tag entries :name "robots")))
      (is (equal '("Example News") (%tag entries :property "og:site_name")))
      (is (equal '("Example News") (%tag entries :property "og:title")))
      (is (equal '("https://example.com/static/card.png") (%tag entries :property "og:image")))
      (is (null (%tag entries :property "og:url")))
      (is (null (%tag entries :link "canonical")))
      (is (null (%tag entries :name "description")))
      (is (null (search "4411" html)) "Nothing from the page's declaration reaches the head.")
      (is (null (search "Balance" html))))))

(test attribute-values-are-escaped
  (let ((html (%head :site (%meta-site) :title "\"><script>alert(1)</script>"
                     :description "Tom & Jerry's \"best\" bits")))
    (is (null (search "\"><script>" html)))
    ;; Inside a quoted attribute only the quote ends the value, so escaping it (and &) is
    ;; what keeps the markup from breaking out.
    (is (search "&quot;><script>" html) "~A" html)
    (is (search "Tom &amp; Jerry&#39;s &quot;best&quot; bits" html))))

(test urls-are-absolute-https-from-the-configured-origin
  (let ((origin (meta:site-origin (%meta-site))))
    (is (string= "https://example.com" origin))
    (is (string= "https://example.com/a?b=c" (meta:absolute-url "/a?b=c" origin)))
    (is (string= "https://cdn.example.net/x.png"
                 (meta:absolute-url "https://cdn.example.net/x.png" origin)))
    (dolist (bad '("http://example.com/x" "//evil.example/x" "x.png" "javascript:alert(1)" ""))
      (signals meta:page-meta-error (meta:absolute-url bad origin))))
  (is (string= "https://example.com:8443"
               (meta:site-origin (meta:make-site :origin "https://example.com:8443"))))
  ;; Each bad origin is its own assertion, and anything other than PAGE-META-ERROR counts
  ;; as a failure of that assertion rather than ending the test.
  (flet ((outcome (origin)
           (handler-case (progn (meta:make-site :origin origin) :accepted)
             (meta:page-meta-error () :refused)
             (error (e) (list :crashed (type-of e))))))
    (is (eq :refused (outcome nil)))
    (is (eq :refused (outcome "")))
    (is (eq :refused (outcome "http://example.com")))
    (is (eq :refused (outcome "https://example.com/app")))
    (is (eq :refused (outcome "https://example.com/?a=b")))
    (is (eq :refused (outcome "https://example.com/#top")))
    (is (eq :refused (outcome "https://user@example.com")))
    (is (eq :refused (outcome "//example.com"))))
  ;; no site at all
  (let ((meta:*site* nil))
    (signals meta:page-meta-error (meta:page-meta :title "x"))))

(test the-origin-defaults-to-the-environment-variable
  (let ((old (uiop:getenv "HYPERION_PUBLIC_ORIGIN")))
    (unwind-protect
         (progn (setf (uiop:getenv "HYPERION_PUBLIC_ORIGIN") "https://from-env.example")
                (is (string= "https://from-env.example" (meta:site-origin (meta:make-site)))))
      ;; An empty value is refused exactly as an unset one is, and setting it works on
      ;; every platform, where unsetting needs sb-posix.
      (setf (uiop:getenv "HYPERION_PUBLIC_ORIGIN") (or old "")))))

(test an-expiring-image-url-falls-back-to-the-site-image
  (let* ((presigned "https://bucket.s3.amazonaws.com/a.png?X-Amz-Expires=600&X-Amz-Signature=abc")
         (entries (%pm :site (%meta-site) :title "x" :image presigned)))
    (is-true (meta:expiring-url-p presigned))
    (is-false (meta:expiring-url-p "https://cdn.example.net/a.png?v=3"))
    (is (equal '("https://example.com/static/card.png") (%tag entries :property "og:image")))))

(test descriptions-are-collapsed-and-cut-on-a-word-boundary
  (is (string= "one two three" (meta:trim-description (format nil "  one~%~%two	three  "))))
  (let* ((long (format nil "~{~A~^ ~}" (loop repeat 60 collect "word")))
         (cut (meta:trim-description long)))
    (is (<= (length cut) 200))
    (is (char= #\HORIZONTAL_ELLIPSIS (char cut (1- (length cut)))))
    (is (string= "word" (subseq cut (- (length cut) 5) (1- (length cut))))
        "The cut falls after a whole word: ~S" cut))
  ;; one unbroken word longer than the limit is cut inside it
  (is (= 20 (length (meta:trim-description (make-string 50 :initial-element #\a) 20)))))

(test og-locale-takes-hyperion-i18n-locales
  (is (string= "en_GB" (meta:og-locale :en-gb)))
  (is (string= "pt_BR" (meta:og-locale "pt-BR")))
  (is (string= "fr" (meta:og-locale :fr)))
  (is (string= "zh_TW" (meta:og-locale "zh-Hant-TW")))
  (is (string= "es_419" (meta:og-locale "es-419")))
  (is (null (meta:og-locale nil)))
  (is (null (meta:og-locale "not a tag"))))

(test bad-declarations-are-refused
  (signals meta:page-meta-error (%pm :site (%meta-site) :type :video))
  (signals meta:page-meta-error (meta:page-meta :site (%meta-site) :visibility :hidden))
  (signals meta:page-meta-error (%pm :site (%meta-site) :image "/a.png" :image-width -1))
  (signals meta:page-meta-error (meta:make-site :origin "https://example.com" :twitter "example")))

(test a-private-page-does-not-publish-its-own-site-name
  (let ((entries (%pm :site (%meta-site) :visibility :private
                      :site-name "Smith family - custody files" :title "Files")))
    (is (equal '("Example News") (%tag entries :property "og:site_name")))
    (is (equal '("Example News") (%tag entries :property "og:title")))
    (is (null (search "Smith" (format nil "~S" entries)))))
  ;; a public page may still name itself
  (is (equal '("Example Sport")
             (%tag (%pm :site (%meta-site) :site-name "Example Sport") :property "og:site_name"))))

(test the-canonical-url-is-on-the-sites-origin-without-its-query
  (let ((site (%meta-site)))
    (flet ((canonical (&rest args)
             (%tag (apply #'%pm :site site args) :link "canonical")))
      (is (equal '("https://example.com/reset") (canonical :url "/reset?token=abc#top")))
      (is (equal '("https://example.com/reset")
                 (canonical :url "https://EXAMPLE.com:443/reset?token=abc")))
      (is (equal '("https://example.com/search?q=rates")
                 (canonical :url "/search?q=rates#r" :keep-query t)))
      (is (equal '("https://example.com/") (canonical :url "https://example.com")))
      (is (equal (canonical :url "/reset?token=abc")
                 (%tag (%pm :site site :url "/reset?token=abc") :property "og:url")))
      (dolist (bad '("https://evil.example/news" "https://example.com.evil.example/x"
                     "https://example.com:8443/x" "https://user@example.com/x"))
        (signals meta:page-meta-error (canonical :url bad))))
    ;; an image may be on another https host, such as a CDN
    (is (equal '("https://cdn.example.net/a.png")
               (%tag (%pm :site site :image "https://cdn.example.net/a.png") :property "og:image")))))

(test expiring-urls-are-found-in-a-malformed-query-and-for-every-signer
  (is-true (meta:expiring-url-p "https://b.s3.amazonaws.com/a.png?X-Amz-Signature=abc&q=%zz"))
  (is-true (meta:expiring-url-p "https://a.blob.core.windows.net/c/a.png?sv=2024&se=2026-01-01&sig=x"))
  (is-true (meta:expiring-url-p "https://d.cloudfront.net/a.png?Policy=p&Signature=s&Key-Pair-Id=k"))
  (is-true (meta:expiring-url-p "https://storage.googleapis.com/b/a.png?x-goog-signature=s"))
  (is-false (meta:expiring-url-p "https://cdn.example.net/a.png?q=%zz"))
  (is-false (meta:expiring-url-p "https://cdn.example.net/a.png"))
  ;; a malformed query on the page's image does not let the image through
  (is (equal '("https://example.com/static/card.png")
             (%tag (%pm :site (%meta-site) :image "https://b.s3.amazonaws.com/a.png?q=%zz&X-Amz-Expires=60")
                   :property "og:image"))))

(test visibility-must-be-given
  (signals meta:page-meta-error (meta:page-meta :site (%meta-site) :title "x"))
  (signals meta:page-meta-error (meta:meta-tags-string :site (%meta-site) :title "x")))

(test unicode-whitespace-is-collapsed
  (is (string= "a b c d e"
               (meta:trim-description
                (format nil "~Ca~C~Cb~Cc~Cd~Ce~C" (code-char #xA0) (code-char #x2028)
                        (code-char #xA0) (code-char #x3000) (code-char #x2009)
                        (code-char #x202F) (code-char #x3000))))))

(test article-times-are-universal-times-or-iso-8601
  (flet ((published (time)
           (%tag (%pm :site (%meta-site) :type :article :published-time time)
                 :property "article:published_time")))
    (is (equal '("2026-01-02") (published "2026-01-02")))
    (is (equal '("2026-01-02T03:04Z") (published "2026-01-02T03:04Z")))
    (is (equal '("2026-01-02T03:04:05.123+01:00") (published "2026-01-02T03:04:05.123+01:00")))
    (dolist (bad '("yesterday" "2026-1-2" "2026-01-02T03:04:05+0100" "2026-01-02T03:04:05." "2026-01-02 03:04"
                   :now 1.5))
      (signals meta:page-meta-error (published bad)))))
