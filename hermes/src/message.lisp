;;;; message.lisp --- the neutral messages + delivery result.
;;;;
;;;; A message is a plain value (EMAIL, SMS or TELEGRAM-MESSAGE), vendor-independent. DELIVER (protocol.lisp)
;;;; dispatches on provider + message; the vendor wire format lives only in each backend.

(cl:in-package #:hermes)

(defstruct (attachment (:constructor %make-attachment
                           (filename content-type content disposition content-id)))
  "A file sent with an EMAIL (#366). FILENAME is the name the recipient sees. CONTENT-TYPE is
the full media type, parameters included, for example \"text/calendar; charset=utf-8;
method=REQUEST\". CONTENT is a string, sent as UTF-8, or a vector of octets. DISPOSITION is
:ATTACHMENT, or :INLINE for a part the HTML body shows, which then needs CONTENT-ID, the name
the HTML refers to it by. Built with MAKE-ATTACHMENT, which checks each of them."
  filename content-type content disposition content-id)

(defun %header-safe-p (string)
  "True for a non-empty string with no control character, so it cannot end a header early."
  (and (stringp string) (plusp (length string))
       (notany (lambda (ch) (< (char-code ch) 32)) string)))

(defun make-attachment (&key filename content-type content (disposition :attachment) content-id)
  "An ATTACHMENT, checked: FILENAME and CONTENT-TYPE are non-empty strings with no control
characters, CONTENT is a string or an octet vector, DISPOSITION is :ATTACHMENT or :INLINE, and an
inline attachment has a CONTENT-ID. Signals INVALID-MESSAGE otherwise, before anything is sent."
  (flet ((bad (what) (error 'invalid-message :problem (format nil "it needs ~A" what))))
    (unless (%header-safe-p filename) (bad "an attachment's :filename (a non-empty string with no control characters)"))
    (unless (%header-safe-p content-type) (bad "an attachment's :content-type (for example \"text/calendar; method=REQUEST\")"))
    (unless (or (stringp content) (typep content '(vector (unsigned-byte 8))))
      (bad "an attachment's :content (a string or a vector of octets)"))
    (unless (member disposition '(:attachment :inline))
      (bad "an attachment's :disposition (:attachment or :inline)"))
    (when (and (eq disposition :inline) (not (%header-safe-p content-id)))
      (bad "an inline attachment's :content-id"))
    (%make-attachment filename content-type content disposition content-id)))

(defun attachment-octets (attachment)
  "ATTACHMENT's content as octets: a string's UTF-8 encoding, or the octets it was given."
  (let ((content (attachment-content attachment)))
    (if (stringp content)
        (sb-ext:string-to-octets content :external-format :utf-8)
        (coerce content '(simple-array (unsigned-byte 8) (*))))))

(defstruct (email (:constructor %make-email
                      (&key to from subject text html reply-to attachments headers)))
  "A provider-neutral email. TO and FROM are address strings; TEXT is the plain body; HTML is
an optional rich body; REPLY-TO is optional. ATTACHMENTS is a list of ATTACHMENTs (#366), empty
by default. HEADERS is an alist of extra header names and values, (NAME . VALUE), empty by
default (#106)."
  (to nil :type (or null string))
  (from nil :type (or null string))
  (subject "" :type string)
  (text "" :type string)
  (html nil :type (or null string))
  (reply-to nil :type (or null string))
  (attachments '() :type list)
  (headers '() :type list))

(defun reserved-email-headers ()
  "The header names an email's :HEADERS may not set (#106), as a fresh list, so a caller cannot
change the list MAKE-EMAIL checks against. The first four are set from MAKE-EMAIL's own
arguments, and the rest are set by hermes or by the provider when the message is built and
signed; SendGrid refuses all of them in its headers object. Compared without regard to case."
  (list "To" "From" "Subject" "Reply-To" "Cc" "Bcc" "Content-Type" "Content-Transfer-Encoding"
        "MIME-Version" "Received" "DKIM-Signature" "X-SG-ID" "X-SG-EID"))

(defconstant +max-header-line+ 998
  "The most characters RFC 5322 allows on one line of a message, CRLF not counted. MAKE-EMAIL
refuses a header whose \"Name: value\" is longer, because hermes does not fold long headers.")

(defun %header-name-p (name)
  "True for a header field name RFC 5322 allows: one or more printable US-ASCII characters
other than the colon."
  (and (stringp name) (plusp (length name))
       (every (lambda (ch) (and (char<= #\! ch #\~) (char/= ch #\:))) name)))

(defun %header-value-p (value)
  "True for a header value hermes can send as it is: a string of printable US-ASCII characters
and tabs. A carriage return or line feed would end the header and let the value start one of
its own. Other control characters are refused with them, the C1 controls (U+0080 to U+009F,
NEL among them) and the line and paragraph separators U+2028 and U+2029 included. Every other
non-ASCII character is refused too, because a raw non-ASCII header is not valid without RFC
2047 encoding, which hermes does not do."
  (and (stringp value)
       (every (lambda (ch) (or (char= ch #\Tab) (char<= #\Space ch #\~))) value)))

(defun %check-email-headers (headers)
  "Signal INVALID-MESSAGE unless HEADERS is a list of (NAME . VALUE) conses that MAKE-EMAIL
accepts: each NAME a field name (%HEADER-NAME-P) that is not reserved and not given twice, each
VALUE a string of printable ASCII and tabs (%HEADER-VALUE-P), and \"Name: value\" no longer
than +MAX-HEADER-LINE+. A carriage return or line feed in a name or value is refused because it
would let the value end the header and add one of its own (header injection)."
  (flet ((bad (format &rest args)
           (error 'invalid-message :problem (apply #'format nil format args))))
    (unless (and (listp headers) (every #'consp headers))
      (bad ":headers must be a list of (name . value) conses"))
    (let ((seen '()))
      (dolist (header headers)
        (destructuring-bind (name . value) header
          (unless (%header-name-p name)
            (bad "a header name must be a non-empty string of printable ASCII characters other than a colon, with no line break; got ~S" name))
          (when (member name (reserved-email-headers) :test #'string-equal)
            (bad "the ~A header is set by hermes or the provider, not through :headers" name))
          (when (member name seen :test #'string-equal)
            (bad "the ~A header is given twice in :headers" name))
          (unless (%header-value-p value)
            (bad "the ~A header's value must be a string of printable ASCII characters and tabs, with no line break, control character or other non-ASCII character" name))
          (when (> (+ (length name) 2 (length value)) +max-header-line+)
            (bad "the ~A header is longer than the ~D characters a line of email may have" name +max-header-line+))
          (push name seen))))))

(defun make-email (&rest keys &key to from subject text html reply-to attachments headers)
  "A provider-neutral EMAIL. ATTACHMENTS, when given, is a list of values from MAKE-ATTACHMENT;
anything else in it signals INVALID-MESSAGE.

HEADERS, when given, is an alist of extra headers, (NAME . VALUE) with both strings, sent as
they are (#106). Values are printable ASCII; hermes does not encode non-ASCII text in a header.
For example, one-click unsubscribe (RFC 8058), which Gmail and Yahoo expect
from bulk senders:

  (make-email :to ... :from ... :subject ... :text ...
              :headers '((\"List-Unsubscribe\" . \"<https://app.example/u/abc>\")
                         (\"List-Unsubscribe-Post\" . \"List-Unsubscribe=One-Click\")))

A name that is not a valid field name, a reserved name (see RESERVED-EMAIL-HEADERS), a name
given twice, a value with anything but printable ASCII and tabs, or a header longer than
+MAX-HEADER-LINE+ signals INVALID-MESSAGE before anything is sent."
  (declare (ignore to from subject text html reply-to))
  (unless (and (listp attachments) (every #'attachment-p attachments))
    (error 'invalid-message :problem ":attachments must be a list of values from MAKE-ATTACHMENT"))
  (%check-email-headers headers)
  (apply #'%make-email keys))

(defstruct (sms (:constructor make-sms (&key to from text)))
  "A provider-neutral SMS. TO/FROM are E.164 phone strings (FROM may come from the provider's
default); TEXT is the message body."
  (to nil :type (or null string))
  (from nil :type (or null string))
  (text "" :type string))

(defun %telegram-chat-p (chat)
  "True for a Telegram chat: an integer chat id, or a public username written \"@name\" with 5 to
32 letters, digits and underscores, starting with a letter and not ending with an underscore."
  (flet ((ascii-letter-p (ch) (and (char< ch (code-char 128)) (alpha-char-p ch))))
    (or (integerp chat)
        (and (stringp chat)
             (<= 6 (length chat) 33)
             (char= (char chat 0) #\@)
             (ascii-letter-p (char chat 1))
             (char/= (char chat (1- (length chat))) #\_)
             (every (lambda (ch) (or (char= ch #\_) (ascii-letter-p ch) (digit-char-p ch)))
                    (subseq chat 1))))))

(defstruct (telegram-message (:constructor %make-telegram-message
                                 (chat text parse-mode link-preview photo)))
  "A message for a Telegram chat (#778). CHAT is an integer chat id or an \"@username\". TEXT is
the message, or the caption when PHOTO is given. PARSE-MODE is NIL (plain text), :HTML or
:MARKDOWN-V2; text in those modes must be escaped with ESCAPE-TELEGRAM-HTML or
ESCAPE-MARKDOWN-V2. LINK-PREVIEW is :SHOW or :HIDE. PHOTO, when given, is an HTTP URL or a
Telegram file_id, and the message is sent as a photo with TEXT as its caption. Built with
MAKE-TELEGRAM-MESSAGE, which checks each of them.

TEXT's length is not checked here. Telegram allows 4096 characters of text and 1024 of caption,
counted after it has parsed the markup out, so the length of the string sent is not the length
Telegram checks; a message over the limit is refused by Telegram with a DELIVERY-FAILURE."
  chat text parse-mode link-preview photo)

(defun make-telegram-message (&key chat (text "") parse-mode (link-preview :show) photo)
  "A TELEGRAM-MESSAGE, checked: CHAT is an integer or an \"@username\", TEXT is a string that is
not empty unless PHOTO is given, PARSE-MODE is NIL, :HTML or :MARKDOWN-V2, LINK-PREVIEW is :SHOW
or :HIDE, and PHOTO is NIL or a non-empty string with no control characters. Signals
INVALID-MESSAGE otherwise, before anything is sent."
  (flet ((bad (what) (error 'invalid-message :problem (format nil "it needs ~A" what))))
    (unless (%telegram-chat-p chat)
      (bad "a Telegram :chat (an integer chat id, or \"@\" and 5 to 32 letters, digits or underscores)"))
    (unless (stringp text) (bad "a string :text"))
    (unless (or photo (plusp (length text))) (bad "a non-empty :text, or a :photo"))
    (unless (member parse-mode '(nil :html :markdown-v2))
      (bad "a :parse-mode of NIL, :HTML or :MARKDOWN-V2"))
    (unless (member link-preview '(:show :hide)) (bad "a :link-preview of :SHOW or :HIDE"))
    (unless (or (null photo) (%header-safe-p photo))
      (bad "a :photo that is a URL or file_id (a non-empty string with no control characters)"))
    (%make-telegram-message chat text parse-mode link-preview photo)))

(defun %check-edit (text parse-mode link-preview part)
  "Signal INVALID-MESSAGE unless the arguments of an EDIT-SENT-MESSAGE are ones it can send:
PART :TEXT or :CAPTION, TEXT a string (not empty for :TEXT), PARSE-MODE and LINK-PREVIEW as for
MAKE-TELEGRAM-MESSAGE."
  (flet ((bad (what) (error 'invalid-message :problem (format nil "it needs ~A" what))))
    (unless (member part '(:text :caption)) (bad "a :part of :TEXT or :CAPTION"))
    (unless (stringp text) (bad "a string text"))
    (when (and (eq part :text) (zerop (length text))) (bad "a non-empty text"))
    (unless (member parse-mode '(nil :html :markdown-v2))
      (bad "a :parse-mode of NIL, :HTML or :MARKDOWN-V2"))
    (unless (member link-preview '(:show :hide)) (bad "a :link-preview of :SHOW or :HIDE"))))

;;; --- Facebook Page posts (#822) ---------------------------------------------

(defun %facebook-page-id-p (page)
  "True for a Facebook Page id: a positive integer, or a string of ASCII digits."
  (or (and (integerp page) (plusp page))
      (and (stringp page) (plusp (length page)) (<= (length page) 32)
           (every (lambda (ch) (char<= #\0 ch #\9)) page))))

(defun %facebook-group-address-p (page)
  "True for something that names a Facebook Group rather than a Page: a URL with /groups/ in it,
or a \"group:\" prefix. A numeric Group id cannot be told from a Page id here; Facebook refuses a
post to one, which arrives as FACEBOOK-NOT-PERMITTED."
  (and (stringp page)
       (or (search "/groups/" (string-downcase page))
           (and (>= (length page) 6) (string-equal "group:" page :end2 6)))))

(defun %http-url-p (url)
  "True for an http or https URL: a string starting with the scheme, with no space or control
character."
  (and (stringp url)
       (or (and (> (length url) 8) (string-equal "https://" url :end2 8))
           (and (> (length url) 7) (string-equal "http://" url :end2 7)))
       (notany (lambda (ch) (<= (char-code ch) 32)) url)))

(defstruct (facebook-post (:constructor %make-facebook-post (page link message image-url)))
  "A post to a Facebook Page (#822). PAGE is the Page's id, as a string of digits. LINK is the
URL the post shares, or NIL; Facebook builds the link card from the target page's Open Graph
tags, and refuses the post when it cannot fetch LINK (a page behind a sign-in, or not public).
MESSAGE is the post's text, or NIL. IMAGE-URL, when given, is an http(s) URL of a photo, and the
post is made as a photo with MESSAGE and LINK as its caption. Built with MAKE-FACEBOOK-POST,
which checks each of them."
  page link message image-url)

(defun make-facebook-post (&key page link message image-url)
  "A FACEBOOK-POST, checked: PAGE is a Page id (a positive integer or a string of digits), LINK
and IMAGE-URL are NIL or http(s) URLs, MESSAGE is NIL or a string, and LINK or MESSAGE is given.
A PAGE that names a Facebook Group (a URL with /groups/ in it, or \"group:...\") signals
FACEBOOK-GROUPS-UNSUPPORTED: Meta removed apps' access to Groups on 2024-04-22. Anything else
that is wrong signals INVALID-MESSAGE, before anything is sent."
  (flet ((bad (what) (error 'invalid-message :problem (format nil "it needs ~A" what))))
    (when (%facebook-group-address-p page)
      (error 'facebook-groups-unsupported :page page))
    (unless (%facebook-page-id-p page)
      (bad "a Facebook :page id (a positive integer or a string of digits)"))
    (unless (or (null link) (%http-url-p link)) (bad "a :link that is an http or https URL"))
    (unless (or (null image-url) (%http-url-p image-url))
      (bad "an :image-url that is an http or https URL"))
    (unless (or (null message) (stringp message)) (bad "a string :message"))
    (unless (or link (plusp (length (or message "")))) (bad "a :link or a non-empty :message"))
    (%make-facebook-post (princ-to-string page) link message image-url)))

(defparameter +markdown-v2-special+ "\\_*[]()~`>#+-=|{}.!"
  "The characters Telegram's MarkdownV2 requires to be escaped with a backslash in ordinary
text, the backslash itself included.")

(defun escape-markdown-v2 (text)
  "TEXT with a backslash before each character MarkdownV2 treats as markup, so Telegram shows it
as written. For ordinary text; text inside a pre or code entity has its own, shorter rule."
  (with-output-to-string (out)
    (loop for ch across text
          do (when (find ch +markdown-v2-special+) (write-char #\\ out))
             (write-char ch out))))

(defun escape-telegram-html (text)
  "TEXT with &, <, > and \" replaced by the entities Telegram's HTML parse mode accepts, so
Telegram shows it as written."
  (with-output-to-string (out)
    (loop for ch across text
          do (case ch
               (#\& (write-string "&amp;" out))
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (#\" (write-string "&quot;" out))
               (t (write-char ch out))))))

(defstruct (delivery-result (:constructor make-delivery-result
                                (&key provider id status raw destination)))
  "The neutral outcome of a successful DELIVER: which PROVIDER handled it, the provider's
message ID (for later status/webhook correlation), a normalized STATUS keyword, and the RAW
provider response for escape-hatch access. DESTINATION is where the provider says the message
went, when that is needed to refer to it again; the Telegram backend fills it with the chat id,
which EDIT-SENT-MESSAGE and DELETE-SENT-MESSAGE need with ID (#778). It is NIL for the other
backends."
  (provider nil :type (or null keyword))
  (id nil :type (or null string))
  (status nil :type (or null keyword))
  (raw nil)
  (destination nil))
