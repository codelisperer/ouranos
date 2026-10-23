;;;; page-meta-tests.lisp --- Open Graph, Twitter-card and canonical tags (#821).

(in-package #:hyperion/tests)

(def-suite page-meta :in hyperion)
(in-suite page-meta)

(defun %meta-site (&rest args)
  (apply #'meta:make-site :name "Example News" :origin "https://Example.com/"
         :image "/static/card.png" :image-width 1200 :image-height 630
         :image-alt "The Example News logo" :twitter "@examplenews" args))

(defun %tag (entries kind name)
  "The values of the entries in ENTRIES with KIND and NAME."
  (loop for (k n v) in entries
        when (and (eq k kind) (string= n name)) collect v))

(defun %head (&rest args)
  "A whole page rendered with META-TAGS in its head, as a layout would."
  (spin:with-html-string
    (:html (:head (:title "A page") (apply #'meta:meta-tags args))
           (:body (:p "body")))))

(test an-article-gets-every-card-tag-with-absolute-urls
  (let* ((site (%meta-site))
         (entries (meta:page-meta :site site :type :article :title "Rates rise"
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
  (let ((entries (meta:page-meta :site (%meta-site) :title "About")))
    (is (equal '("website") (%tag entries :property "og:type")))
    (is (equal '("https://example.com/static/card.png") (%tag entries :property "og:image")))
    (is (equal '("1200") (%tag entries :property "og:image:width")))
    (is (equal '("The Example News logo") (%tag entries :property "og:image:alt")))
    (is (equal '("summary_large_image") (%tag entries :name "twitter:card")))
    (is (null (%tag entries :property "article:published_time")))
    (is (null (%tag entries :link "canonical")) "No canonical URL is invented from the request."))
  ;; a site with no fallback image: no og:image and a summary card
  (let ((entries (meta:page-meta :site (meta:make-site :name "Bare" :origin "https://bare.example")
                                 :title "About")))
    (is (null (%tag entries :property "og:image")))
    (is (null (%tag entries :name "twitter:image")))
    (is (equal '("summary") (%tag entries :name "twitter:card")))))

(test a-private-or-noindex-page-emits-only-the-site-name-and-fallback
  (dolist (visibility '(:private :noindex))
    (let* ((entries (meta:page-meta :site (%meta-site) :visibility visibility
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
  (dolist (bad '(nil "http://example.com" "https://example.com/app" "https://example.com/?a=b"
                 "https://user@example.com"))
    (signals meta:page-meta-error (meta:make-site :origin bad)))
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
         (entries (meta:page-meta :site (%meta-site) :title "x" :image presigned)))
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
  (signals meta:page-meta-error (meta:page-meta :site (%meta-site) :type :video))
  (signals meta:page-meta-error (meta:page-meta :site (%meta-site) :visibility :hidden))
  (signals meta:page-meta-error (meta:page-meta :site (%meta-site) :image "/a.png" :image-width -1))
  (signals meta:page-meta-error (meta:make-site :origin "https://example.com" :twitter "example")))
